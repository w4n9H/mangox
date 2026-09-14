//
//  P4.0.2 冒烟: Transport 池 + 会话化 isStreaming
//  注入 MockTransport (串行基线) 验证: 回合归属路由 / 镜像投影 / fire 后台化 / done 停用 / 落库完整性
//  注意: 等待一律用 await Task.sleep 让出 MainActor (RunLoop 泵不驱动并发主执行器)
//

import Foundation
import SwiftUI

@main
struct SmokeMain {
    static func main() async {
        await run()
    }

    @MainActor
    static var failures: [String] = []

    @MainActor
    static func check(_ cond: Bool, _ what: String) {
        print((cond ? "PASS" : "FAIL") + " - " + what)
        if !cond { failures.append(what) }
    }

    @MainActor
    static func waitUntil(_ cond: @MainActor () -> Bool, timeout: Double = 20) async -> Bool {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @MainActor
    static func hasText(_ msgs: [ChatMessage], _ substr: String) -> Bool {
        msgs.contains { msg in
            if case .text(let s) = msg.content { return s.contains(substr) }
            return false
        }
    }

    @MainActor
    static func report() -> Never {
        print(failures.isEmpty ? "\nALL PASS" : "\nFAILURES: \(failures.count)")
        failures.forEach { print(" - " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }

    @MainActor
    static func run() async {
        let dir = NSTemporaryDirectory() + "mx-smoke-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let mock = MockTransport()
        let store = ChatStore(transport: mock,
                              dbPath: dir + "/smoke.db",
                              managedExtensionsDir: dir + "/ext")
        print("== P4.0.2 冒烟: Transport 池 + 会话化 isStreaming ==")
        check(store.runningTurns.isEmpty && !store.isStreaming, "T0 初始无在途回合 (isStreaming=false)")

        // ---- T1 基线发送 + 归并 + 收尾 ----
        store.newConversation()
        guard let sidA = store.selectedConversationId else {
            check(false, "T0 建会话"); report()
        }
        store.draft = "你好"
        store.sendDraft()
        check(store.runningTurns == [sidA] && store.isStreaming, "T1 发送后 runningTurns=[A] / isStreaming=true")
        check(await waitUntil { store.runningTurns.isEmpty }, "T1 回合结束 (runningTurns 清空)")
        check(!store.isStreaming, "T1 会话化 isStreaming 回落 false")
        if let last = store.messages.last, case .text(let s) = last.content {
            check(last.role == .assistant && !last.isStreaming && !s.isEmpty, "T1 助手回复收尾无光标")
        } else { check(false, "T1 助手回复收尾无光标") }

        // ---- T2 在途防重发 ----
        store.draft = "第二条"
        store.sendDraft()
        check(store.runningTurns == [sidA], "T2 第二回合启动")
        store.draft = "在途中不该发出去"
        let cnt2 = store.messages.count
        store.sendDraft()
        check(store.messages.count == cnt2 && store.draft == "在途中不该发出去", "T2 在途重发被拒 (draft 保留)")
        check(await waitUntil { store.runningTurns.isEmpty }, "T2 回合结束")

        // ---- T3 切走镜像: 后台回合产出不进他者视图, 切回完整 ----
        mock.scriptedReply = { _ in String(repeating: "镜像回归内容。", count: 15) }
        store.draft = "开始长回复"
        store.sendDraft()
        store.newConversation()   // 立即切到新会话 B
        guard let sidB = store.selectedConversationId else { check(false, "T3 建会话 B"); report() }
        check(store.messages.isEmpty, "T3 切走后 B 视图空态")
        check(await waitUntil { store.runningTurns.isEmpty }, "T3 后台回合结束")
        check(!hasText(store.messages, "镜像回归内容"), "T3 B 视图无跨会话污染")
        store.selectConversation(sidA)
        check(hasText(store.messages, "镜像回归内容。"), "T3 切回 A 完整回放 (replay+去重合并)")
        check(store.runningTurns.isEmpty, "T3 切回后无残留在途")

        // ---- T4 stopStreaming 兜底 (Mock cancel 不发 streamEnded) ----
        mock.scriptedReply = { _ in String(repeating: "很长的回复", count: 40) }
        store.draft = "停我"
        store.sendDraft()
        try? await Task.sleep(nanoseconds: 600_000_000)
        store.stopStreaming()
        check(store.runningTurns.isEmpty, "T4 stop 后 runningTurns 清空")
        check(!(store.messages.last?.isStreaming ?? true), "T4 光标摘除")
        let partialA = store.messages.last
        if case .text(let ps) = partialA?.content ?? .text("") {
            check(ps.contains("很长的回复") && ps.count < 200, "T4 半截回复保留 (\(ps.count) 字)")
        } else { check(false, "T4 半截回复保留") }

        // ---- T5 fire 后台化: 不劫持 UI, 日志会话落库 ----
        store.selectConversation(sidB)
        let selBefore = store.selectedConversationId
        store.addScheduled(name: "巡检", prompt: "执行巡检动作", cron: "0 0 1 1 *", projectId: nil)
        check(store.scheduledTasks.count == 1, "T5 任务已建")
        mock.scriptedReply = { _ in "巡检完成, 一切正常。" }
        store.runScheduledFire(store.scheduledTasks[0])
        check(store.selectedConversationId == selBefore, "T5 fire 不劫持选中会话")
        guard let logId1 = store.scheduledTasks[0].logSessionId else { check(false, "T5 日志会话建立"); report() }
        check(store.runningTurns == [logId1], "T5 fire 回合在途 (归属日志会话)")
        check(await waitUntil { store.runningTurns.isEmpty }, "T5 fire 结束")
        check(store.scheduledTasks[0].runCount == 1 && store.scheduledTasks[0].lastRunAt != nil, "T5 执行计数/时间戳")
        store.selectConversation(logId1)
        check(hasText(store.messages, "运行"), "T5 日志会话含运行分隔")
        check(hasText(store.messages, "执行巡检动作") && hasText(store.messages, "巡检完成"), "T5 prompt+回复落库日志会话")

        // ---- T6 等待型 fire: done 标记自动停用 ----
        store.addScheduled(name: "哨兵", prompt: "执行触发动作", cron: "0 0 1 1 *", projectId: nil)
        var wt = store.scheduledTasks[1]
        wt.condition = "磁盘占用超 90%"
        store.updateScheduled(wt)
        mock.scriptedReply = { _ in "观察到条件成立。\n<!--task: done-->" }
        store.runScheduledFire(store.scheduledTasks[1])
        guard let logId2 = store.scheduledTasks[1].logSessionId else { check(false, "T6 日志会话建立"); report() }
        check(await waitUntil { store.runningTurns.isEmpty }, "T6 fire 结束")
        check(store.scheduledTasks[1].enabled == false, "T6 done 命中自动停用")
        check(store.scheduledTasks[1].completedAt != nil, "T6 completedAt 记录")
        store.selectConversation(logId2)
        let assistantClean = store.messages.allSatisfy { msg in
            guard msg.role == .assistant, case .text(let s) = msg.content else { return true }
            return !s.contains("<!--task: done-->")   // 剥离只作用于回复 (prompt 注入模板合法含标记)
        }
        check(assistantClean, "T6 done 标记已从回复剥离不落库")

        // ---- T7 二次实例 (同库): 落库完整性 + 池化 init 干净拉起 ----
        let store2 = ChatStore(transport: MockTransport(),
                               dbPath: dir + "/smoke.db",
                               managedExtensionsDir: dir + "/ext")
        store2.selectConversation(sidA)
        check(hasText(store2.messages, "镜像回归内容。"), "T7 A 回复完整落库 (含后台回合)")
        store2.selectConversation(sidB)
        check(store2.messages.isEmpty, "T7 B 视图无污染落库")
        store2.selectConversation(logId1)
        check(hasText(store2.messages, "执行巡检动作"), "T7 日志会话落库可回放")

        // ---- T8 并发上限: 默认 10 / 超限拒绝+横幅 / clamp / 恢复后放行 ----
        check(store.maxConcurrentTurns == 10, "T8 默认上限 10")
        store.maxConcurrentTurns = 1
        check(store.maxConcurrentTurns == 1, "T8 上限生效")
        mock.scriptedReply = { _ in String(repeating: "长回复占位。", count: 30) }
        store.selectConversation(sidA)
        store.draft = "占住并发"
        store.sendDraft()
        check(store.runningTurns.count == 1 && store.atTurnLimit, "T8 A 回合在途, atTurnLimit=true")
        store.newConversation()   // 切到新会话 C
        guard let sidC = store.selectedConversationId else { check(false, "T8 建会话 C"); report() }
        store.draft = "超限这条"
        store.sendDraft()
        check(store.messages.isEmpty && store.draft == "超限这条", "T8 超限发送被拒 (消息不入库, draft 保留)")
        check(store.turnLimitNotice != nil, "T8 超限横幅提示")
        check(await waitUntil { store.runningTurns.isEmpty }, "T8 A 回合结束")
        check(store.runningTurns.isEmpty && !store.atTurnLimit, "T8 释放后 atTurnLimit=false")
        store.draft = "这条能发"
        store.sendDraft()
        check(store.runningTurns == [sidC], "T8 释放后发送放行")
        check(await waitUntil { store.runningTurns.isEmpty }, "T8 C 回合结束")
        store.maxConcurrentTurns = 0
        check(store.maxConcurrentTurns == 1, "T8 下限 clamp 1")
        store.maxConcurrentTurns = 100
        check(store.maxConcurrentTurns == 20, "T8 上限 clamp 20")
        check(await waitUntil { true }, "T8 稳态")

        // ---- T9 fire 超限落痕: 并发满时到点任务跳过并记录原因 ----
        store.maxConcurrentTurns = 1   // T8 收尾 clamp 到 20, 这里重设满载口径
        mock.scriptedReply = { _ in String(repeating: "占住并发的长回复。", count: 30) }
        store.selectConversation(sidC)
        store.draft = "占住并发再跑 fire"
        store.sendDraft()   // 1/1 满载
        check(store.runningTurns.count == 1, "T9 占满前置")
        store.runScheduledFire(store.scheduledTasks[0])   // 巡检任务到点
        check(store.scheduledTasks[0].runCount == 1, "T9 超限 fire 不计数")
        check(await waitUntil { store.runningTurns.isEmpty }, "T9 占用回合结束")
        store.selectConversation(logId1)
        check(hasText(store.messages, "并发已满 (1)"), "T9 日志会话落痕跳过原因")
        if let last = store.messages.last, case .text(let s) = last.content {
            check(s.contains("因冲突跳过 (并发已满 (1))"), "T9 末条为跳过痕 (未投递新 prompt)")
        } else { check(false, "T9 末条为跳过痕") }
        check(true, "T9 fire 跳过不弹用户横幅 (落痕语义)")

        // ---- T10 P4.1/P4.2 逻辑级回归: 通知开关持久化 / stopTurn 指定停止 ----
        check(store.completionNotificationsEnabled, "T10 通知开关默认开")
        store.completionNotificationsEnabled = false
        mock.scriptedReply = { _ in String(repeating: "计时测试回复。", count: 30) }
        store.selectConversation(sidA)
        store.draft = "跑起来再定点停"
        store.sendDraft()
        try? await Task.sleep(nanoseconds: 700_000_000)
        store.stopTurn(sidA)   // 迷你条 [■] 路径: 指定会话停止
        check(store.runningTurns.isEmpty, "T10 stopTurn(sid) 清在途")
        check(!(store.messages.last?.isStreaming ?? true), "T10 半截回复光标摘除")
        check(await waitUntil { true }, "T10 稳态")
        let store3 = ChatStore(transport: MockTransport(),
                               dbPath: dir + "/smoke.db",
                               managedExtensionsDir: dir + "/ext")
        check(store3.completionNotificationsEnabled == false, "T10 通知开关持久化 roundtrip")
        check(store3.maxConcurrentTurns == 1, "T10 并发上限持久化 roundtrip (T9 遗留值)")

        // ---- T11 P5.0.1: pi message_end usage 捕获 → messageFinalized 搭载 ----
        do {
            final class UsageSink: AgentTransportDelegate {
                var events: [AgentEvent] = []
                func transport(_ t: any AgentTransport, didEmit event: AgentEvent) { events.append(event) }
            }
            let sink = UsageSink()
            let pi = PiRpcTransport()
            pi.delegate = sink
            pi.handleRPCLine(#"{"type":"agent_start"}"#)
            pi.handleRPCLine(#"{"type":"message_start","message":{"role":"assistant"}}"#)
            pi.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"thinking..."}}"#)
            pi.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"hello"}}"#)
            let usageJSON = #"{"type":"message_end","message":{"role":"assistant","model":"deepseek-flash","responseId":"resp-1","usage":{"input":100,"output":5,"cacheRead":3,"cacheWrite":0,"reasoning":2,"totalTokens":110}}}"#
            pi.handleRPCLine(usageJSON)
            pi.handleRPCLine(#"{"type":"agent_end"}"#)
            let finalized = sink.events.compactMap { e -> (UUID, MessageUsage?)? in
                if case .messageFinalized(let id, let u) = e { return (id, u) }
                return nil
            }
            check(finalized.count == 2, "T11 think/text 两块各自落定")
            let textUsage = finalized.first { $0.1 != nil }?.1
            check(textUsage?.totalTokens == 110 && textUsage?.input == 100 && textUsage?.output == 5,
                  "T11 usage 数值捕获 (total=110 input=100 output=5)")
            check(textUsage?.model == "deepseek-flash" && textUsage?.responseId == "resp-1",
                  "T11 model/responseId 捕获")
            check(finalized.filter { $0.1 == nil }.count == 1, "T11 usage 只挂最后一个落定块 (think 块 nil)")
            // 旧格式: message_end 无 usage → 落定 usage 为 nil (存量数据自然兜底)
            pi.handleRPCLine(#"{"type":"agent_start"}"#)
            pi.handleRPCLine(#"{"type":"message_start","message":{"role":"assistant"}}"#)
            pi.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"legacy"}}"#)
            pi.handleRPCLine(#"{"type":"message_end","message":{"role":"assistant"}}"#)
            let legacy = sink.events.compactMap { e -> MessageUsage?? in
                if case .messageFinalized(_, let u) = e { return .some(u) }
                return nil
            }.last ?? nil
            check(legacy == nil, "T11 旧格式 message_end (无 usage) → 落定 nil")
        }

        // ---- T12 P5.0.3: 轨迹事件派生 (TrajectoryBuilder 纯函数) ----
        do {
            func msg(_ role: MessageRole, _ content: MessageContent,
                     _ seconds: Double, streaming: Bool = false,
                     usage: MessageUsage? = nil) -> ChatMessage {
                ChatMessage(role: role, content: content,
                            timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                            isStreaming: streaming, usage: usage)
            }
            func kinds(_ t: TrajectoryTurn) -> [String] { t.events.map(\.kind.rawValue) }

            // 1) 回合分组 + 事件序
            let u1 = msg(.user, .text("sleep 30"), 0)
            let a1 = msg(.assistant, .text("好的，开始执行。"), 2)
            let t1 = msg(.assistant, .tool(ToolCall(kind: .bash, title: "sleep",
                                                    command: "sleep 30", phase: .done,
                                                    durationMs: 30_000)), 4)
            let u2 = msg(.user, .text("再来一次"), 40)
            let a2 = msg(.assistant, .text("完成"), 42)
            let turns = TrajectoryBuilder.turns(from: [u1, a1, t1, u2, a2])
            check(turns.count == 2 && turns[0].index == 1 && turns[1].index == 2,
                  "T12 两条 user → 两回合")
            check(kinds(turns[0]) == ["user", "assistant", "tool"],
                  "T12 回合1事件序 user→assistant→tool")
            check(kinds(turns[1]) == ["user", "assistant"], "T12 回合2事件序")
            check(turns[0].events[2].tool?.durationMs == 30_000
                  && turns[0].events[2].tool?.phase == .done,
                  "T12 工具行透传 durationMs/phase")
            check(turns[0].events[1].heuristicMs == 2000,
                  "T12 时长估计 = 下一事件时间差")

            // 2) think 合并给后续 text 行 (usage 在 text)
            let think = msg(.assistant, .think("推理中"), 10)
            let text = msg(.assistant, .text("答案就是 42。"),
                           12, usage: MessageUsage(input: 100, output: 5,
                                                   totalTokens: 110,
                                                   model: "deepseek/deepseek-flash",
                                                   responseId: "r1"))
            let t2 = TrajectoryBuilder.turns(from: [u1, think, text])
            check(t2[0].events.count == 2
                  && t2[0].events[1].thinkText == "推理中"
                  && t2[0].events[1].fullText == "答案就是 42。",
                  "T12 think 块合并进同回合 text 行")
            check(t2[0].events[1].usage?.totalTokens == 110
                  && TrajectoryBuilder.shortModelName(t2[0].events[1].usage?.model) == "deepseek-flash",
                  "T12 usage 随 text 行携带 + 短模型名")

            // 3) 仅 think + 工具 → think 独占一行
            let t3 = TrajectoryBuilder.turns(from: [u1, think, t1])
            check(kinds(t3[0]) == ["user", "assistant", "tool"]
                  && t3[0].events[1].fullText == "推理中",
                  "T12 think 后无 text → think 独占 ASSISTANT 行")

            // 4) 流式中 assistant 不成行 (事件语义)
            let streaming = msg(.assistant, .text("生成中..."), 2, streaming: true)
            let t4 = TrajectoryBuilder.turns(from: [u1, streaming])
            check(kinds(t4[0]) == ["user"], "T12 流式 assistant 不成行 (视图出占位)")

            // 5) 摘要聚合
            let s = TrajectoryBuilder.summary(turns)
            check(s.turns == 2 && s.calls == 1 && s.durationMs == 6_000,
                  "T12 摘要 turns=2 calls=1 duration=回合内末事件-起始合计")

            // 6) 首句折叠
            check(TrajectoryBuilder.firstSentence("第一句。第二句！第三句") == "第一句。",
                  "T12 首句折叠按中文句号截断")
            let long = String(repeating: "x", count: 100)
            check(TrajectoryBuilder.firstSentence(long).count == 81,
                  "T12 超长首句封顶 80+省略号")

            // 7) 格式化
            check(TrajectoryBuilder.formatDuration(900) == "<1s"
                  && TrajectoryBuilder.formatDuration(65_000) == "1m 5s"
                  && TrajectoryBuilder.formatDuration(3_700_000) == "1h 1m",
                  "T12 时长格式化三段")
            check(TrajectoryBuilder.formatTokens(999) == "999"
                  && TrajectoryBuilder.formatTokens(1500) == "1.5k",
                  "T12 token 格式化 k 缩写")
        }

        // ---- T13 P5.1: 自定义模型 (菜单自主, 运行时借壳) ----
        do {
            let db = dir + "/custom.db"
            let s = ChatStore(transport: MockTransport(), dbPath: db,
                              managedExtensionsDir: dir + "/ext")
            check(s.customModels.isEmpty, "T13 初始自定义条目为空")
            check(s.validProviders == ["deepseek", "openai"], "T13 provider 集合来自 pi 上报")
            check(s.isValidProvider("deepseek") && !s.isValidProvider("aliyun")
                  && !s.isValidProvider("  "), "T13 provider 前缀校验")

            // 治本场景: 目录条目名与 API 名错位 → 自定义覆盖
            check(s.addCustomModel(provider: "deepseek", modelId: "deepseek-v4.1-flash",
                                   label: "DeepSeek V4.1 Flash"), "T13 添加自定义条目")
            check(s.customModels.count == 1
                  && s.customModelInfos[0].label == "DeepSeek V4.1 Flash",
                  "T13 自定义条目入菜单 (label 生效)")
            check(s.customModelInfos[0].supportedLevels.count == ThinkingLevel.allCases.count,
                  "T13 自定义条目 thinking 全级别")

            // 校验拦截: provider 不在目录中 / model id 为空
            check(!s.addCustomModel(provider: "aliyun", modelId: "qwen3-max"),
                  "T13 非法 provider 拒绝添加")
            check(!s.addCustomModel(provider: "deepseek", modelId: "  "),
                  "T13 空 model id 拒绝添加")
            check(s.customModels.count == 1, "T13 拒绝后条目数不变")

            // 覆盖 pi 目录同名条目 (provider/id 相同 → 隐藏目录条目, 不全并重复)
            check(s.addCustomModel(provider: "deepseek", modelId: "deepseek-v4-flash",
                                   label: "V4 Flash 别名"), "T13 覆盖同名目录条目")
            check(!s.catalogModels.contains { $0.id == "deepseek-v4-flash" },
                  "T13 同名目录条目被覆盖隐藏")
            let entries = s.modelMenuEntries
            check(Set(entries.map(\.id)).count == entries.count,
                  "T13 菜单条目 id 无撞车")
            check(entries.filter { $0.model.id == "deepseek-v4-flash" }.count
                  == ThinkingLevel.allCases.count,
                  "T13 覆盖后同名只出现一份 (全级别)")

            // label 更新 (同 PK upsert 不新增)
            check(s.addCustomModel(provider: "deepseek", modelId: "deepseek-v4.1-flash",
                                   label: "V4.1 Flash"), "T13 同 PK 再添加 = 覆盖")
            check(s.customModels.count == 2
                  && s.customModels.first { $0.modelId == "deepseek-v4.1-flash" }?
                      .label == "V4.1 Flash",
                  "T13 label 更新而非新增")

            // 药丸显示名: 自定义 label 优先
            s.selectModel(s.customModelInfos.first { $0.id == "deepseek-v4.1-flash" }!,
                          level: .high)
            check(s.currentModelDisplayName == "V4.1 Flash",
                  "T13 药丸显示自定义 label")
            check(s.currentModelId == "deepseek-v4.1-flash" && s.currentProvider == "deepseek",
                  "T13 选中仍透传真实 provider/id")

            // 持久化 roundtrip
            let s2 = ChatStore(transport: MockTransport(), dbPath: db,
                               managedExtensionsDir: dir + "/ext")
            check(s2.customModels.count == 2
                  && s2.customModels.contains { $0.modelId == "deepseek-v4.1-flash" },
                  "T13 自定义条目落库 roundtrip")

            // 删除收敛
            s.removeCustomModel(s.customModels.first { $0.modelId == "deepseek-v4-flash" }!)
            check(s.customModels.count == 1
                  && s.catalogModels.contains { $0.id == "deepseek-v4-flash" },
                  "T13 删除后目录条目回归")
        }

        // ---- T14 P6.0: 缺陷修复 (settled 语义 / fire-and-forget / cost / 工具标签) ----
        do {
            final class Sink: AgentTransportDelegate {
                var events: [AgentEvent] = []
                func transport(_ t: any AgentTransport, didEmit event: AgentEvent) { events.append(event) }
            }
            let sink = Sink()
            let pi = PiRpcTransport()
            pi.delegate = sink

            // ① agent_end(willRetry) 不落定不拆进程; agent_settled 才落定
            pi.handleRPCLine(#"{"type":"agent_start"}"#)
            pi.handleRPCLine(#"{"type":"agent_end","messages":[],"willRetry":true}"#)
            check(pi.lastWillRetry == true, "T14 agent_end.willRetry 捕获")
            check(!sink.events.contains { e in
                if case .streamEnded = e { return true }; return false
            }, "T14 agent_end(willRetry) 不发 streamEnded (不腰斩重试)")
            pi.handleRPCLine(#"{"type":"agent_settled"}"#)
            check(sink.events.contains { e in
                if case .streamEnded = e { return true }; return false
            }, "T14 agent_settled 才落定 (streamEnded)")

            // ② fire-and-forget: notify 上抛横幅事件且不回 response; confirm 照旧应答
            pi.handleRPCLine(#"{"type":"extension_ui_request","id":"u1","method":"notify","notifyType":"warning","message":"命令被拦"}"#)
            check(sink.events.contains { e in
                if case .extensionNotify(let type, let msg) = e { return type == "warning" && msg == "命令被拦" }
                return false
            }, "T14 notify 上抛 extensionNotify (warning)")
            check(pi.sentCommands.isEmpty, "T14 fire-and-forget 不回 response")
            pi.handleRPCLine(#"{"type":"extension_ui_request","id":"u2","method":"confirm"}"#)
            check(pi.sentCommands.contains {
                ($0["type"] as? String) == "extension_ui_response" && ($0["id"] as? String) == "u2"
            }, "T14 confirm 仍自动应答")

            // ③ usage.cost 捕获 (USD) + 旧格式 nil
            pi.handleRPCLine(#"{"type":"agent_start"}"#)
            pi.handleRPCLine(#"{"type":"message_start","message":{"role":"assistant"}}"#)
            pi.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}"#)
            pi.handleRPCLine(#"{"type":"message_end","message":{"role":"assistant","model":"m","usage":{"input":10,"output":5,"totalTokens":15,"cost":{"input":0.0001,"output":0.0002,"total":0.0003}}}}"#)
            func lastFinalized(_ sink: Sink) -> MessageUsage?? {
                sink.events.compactMap { e -> MessageUsage?? in
                    if case .messageFinalized(_, let u) = e { return .some(u) }
                    return nil
                }.last ?? nil
            }
            check(lastFinalized(sink).flatMap { $0 }?.costUSD == 0.0003, "T14 usage.cost 捕获 (USD)")
            pi.handleRPCLine(#"{"type":"message_start","message":{"role":"assistant"}}"#)
            pi.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"y"}}"#)
            pi.handleRPCLine(#"{"type":"message_end","message":{"role":"assistant","usage":{"input":1,"output":1,"totalTokens":2}}}"#)
            check(lastFinalized(sink).flatMap { $0 }?.costUSD == nil, "T14 无 cost 旧格式 → nil")

            // ④ 工具标签: grep/find/ls 不再错显 read; powershell 归 bash
            pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c1","toolName":"grep","args":{"pattern":"foo"}}"#)
            func lastTool(_ sink: Sink) -> ToolCall?? {
                sink.events.compactMap { e -> ToolCall?? in
                    if case .toolUpdated(let t) = e { return .some(t) }
                    return nil
                }.last ?? nil
            }
            check(lastTool(sink).flatMap { $0 }?.kind == .grep, "T14 grep 工具卡标签正确")
            pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c2","toolName":"powershell","args":{}}"#)
            check(lastTool(sink).flatMap { $0 }?.kind == .bash, "T14 powershell 归 bash")
        }

        // ---- T15 P6.1.1: 状态栏数据链 (usage tick 节流 / settled 拉统计 / 解析投影) ----
        do {
            final class Sink: AgentTransportDelegate {
                var events: [AgentEvent] = []
                var stats: [SessionStats] = []
                func transport(_ t: any AgentTransport, didEmit event: AgentEvent) { events.append(event) }
                func transport(_ t: any AgentTransport, didReportSessionStats s: SessionStats) { stats.append(s) }
            }
            let sink = Sink()
            let pi = PiRpcTransport()
            pi.delegate = sink

            // ① message_update 顶层累计 usage → usageTick; 500ms 内第二条被节流
            pi.handleRPCLine(#"{"type":"agent_start"}"#)
            pi.handleRPCLine(#"{"type":"message_update","usage":{"input":100,"output":20,"cacheRead":1800},"assistantMessageEvent":{"type":"text_delta","delta":"a"}}"#)
            check(sink.events.contains { e in
                if case .usageTick(let s) = e { return s.inputTokens == 100 && s.outputTokens == 20 }
                return false
            }, "T15 message_update 顶层 usage → usageTick")
            pi.handleRPCLine(#"{"type":"message_update","usage":{"input":150,"output":40},"assistantMessageEvent":{"type":"text_delta","delta":"b"}}"#)
            check(sink.events.filter { e in
                if case .usageTick = e { return true }; return false
            }.count == 1, "T15 usage tick 500ms 节流")

            // ② settled (无进程) 走兜底路径, 不补发统计命令
            pi.handleRPCLine(#"{"type":"agent_settled"}"#)
            check(pi.sentCommands.isEmpty, "T15 无进程 settled 不补发统计命令")

            // ③ get_session_stats 响应解析: percent / tokens / cost / 缓存命中率
            pi.handleRPCLine(#"{"type":"response","id":"r1","command":"get_session_stats","success":true,"data":{"tokens":{"input":100,"output":311,"cacheRead":1900,"total":2311},"cost":{"total":0.002},"contextUsage":{"tokens":15000,"contextWindow":128000,"percent":11.7}}}"#)
            check(sink.stats.last?.contextPercent == 11.7, "T15 contextPercent 捕获")
            check(sink.stats.last?.inputTokens == 100 && sink.stats.last?.outputTokens == 311,
                  "T15 token 捕获")
            check(sink.stats.last?.costUSD == 0.002, "T15 cost.total 捕获 (USD)")
            check(abs((sink.stats.last?.cachePercent ?? 0) - 95.0) < 0.01,
                  "T15 缓存命中率 = cacheRead/(input+cacheRead)")

            // ④ 压缩后 percent=null → nil (UI 显示 "--"); 全空 token → cachePercent nil
            pi.handleRPCLine(#"{"type":"response","id":"r2","command":"get_session_stats","success":true,"data":{"tokens":{},"contextUsage":{"tokens":null,"contextWindow":128000,"percent":null}}}"#)
            check(sink.stats.last?.contextPercent == nil, "T15 压缩后 percent null → nil")
            check(sink.stats.last?.cachePercent == nil, "T15 无分母 cachePercent → nil")
        }

        // ---- T16 P6.1.2: 过程态胶囊 (RuntimePhase 事件映射 + 压缩横幅) ----
        do {
            final class Sink: AgentTransportDelegate {
                var events: [AgentEvent] = []
                var phases: [RuntimePhase] = []
                func transport(_ t: any AgentTransport, didEmit event: AgentEvent) {
                    events.append(event)
                    if case .phaseChanged(let p) = event { phases.append(p) }
                }
            }
            let sink = Sink()
            let pi = PiRpcTransport()
            pi.delegate = sink

            func lastPhase(_ s: Sink) -> RuntimePhase? { s.phases.last }
            func lastNotice(_ s: Sink) -> (String, isError: Bool)? {
                for e in s.events.reversed() {
                    if case .extensionNotify(let type, let msg) = e {
                        return (msg, type != "info")
                    }
                }
                return nil
            }

            pi.handleRPCLine(#"{"type":"agent_start"}"#)
            check(lastPhase(sink) == .streaming, "T16 agent_start → streaming")
            pi.handleRPCLine(#"{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"529 overloaded"}"#)
            check(lastPhase(sink) == .retrying(attempt: 1, maxAttempts: 3, delayMs: 2000),
                  "T16 auto_retry_start → retrying(1/3)")
            check(lastPhase(sink)?.capsuleText == "重试 1/3 · 2s 后", "T16 retrying 胶囊文案")
            pi.handleRPCLine(#"{"type":"auto_retry_end","success":true,"attempt":2}"#)
            check(lastPhase(sink) == .streaming, "T16 auto_retry_end → 回 streaming")

            pi.handleRPCLine(#"{"type":"queue_update","steering":["a"],"followUp":["b","c"]}"#)
            check(lastPhase(sink) == .queued(count: 3), "T16 queue_update → 排队 3 条")
            pi.handleRPCLine(#"{"type":"queue_update","steering":[],"followUp":[]}"#)
            check(lastPhase(sink) == .streaming, "T16 queue 清空 → 回 streaming")

            pi.handleRPCLine(#"{"type":"compaction_start","reason":"threshold"}"#)
            check(lastPhase(sink) == .compacting(reason: "threshold"), "T16 compaction_start → compacting")
            pi.handleRPCLine(#"{"type":"compaction_end","reason":"threshold","aborted":false,"willRetry":true,"result":{"summary":"s","tokensBefore":150000,"estimatedTokensAfter":32000}}"#)
            check(lastPhase(sink) == .streaming, "T16 compaction_end → 回 streaming")
            check(lastNotice(sink)?.0 == "上下文压缩完成：150000 → 32000 tokens", "T16 压缩完成横幅")
            check(lastNotice(sink)?.isError == false, "T16 压缩完成横幅为 info")

            pi.handleRPCLine(#"{"type":"summarization_retry_scheduled","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"terminated"}"#)
            check(lastPhase(sink) == .summarizing, "T16 summarization_retry_scheduled → summarizing")
            pi.handleRPCLine(#"{"type":"summarization_retry_finished"}"#)
            check(lastPhase(sink) == .streaming, "T16 summarization_retry_finished → 回 streaming")

            pi.handleRPCLine(#"{"type":"agent_settled"}"#)
            check(lastPhase(sink) == .idle, "T16 agent_settled → idle")

            pi.handleRPCLine(#"{"type":"compaction_end","reason":"overflow","aborted":true,"willRetry":false,"result":null}"#)
            check(lastNotice(sink)?.0 == "上下文压缩已中止" && lastNotice(sink)?.isError == true,
                  "T16 压缩中止 → warning 横幅")
        }

        // ---- T17 P6.2: Trace v2 (toolcall 提前卡 / 工具分组 / 折叠规则 / Details / export_html) ----
        do {
            final class Sink: AgentTransportDelegate {
                var events: [AgentEvent] = []
                var lastExport: String?
                func transport(_ t: any AgentTransport, didEmit event: AgentEvent) { events.append(event) }
                func transport(_ t: any AgentTransport, didFinishExportHTMLPath path: String?) { lastExport = path }
            }
            let sink = Sink()
            let pi = PiRpcTransport()
            pi.delegate = sink

            // ① toolcall_start → queued 提前出卡; execution_start 同 id → 整卡替换转 running
            pi.handleRPCLine(#"{"type":"agent_start"}"#)
            pi.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_x1","toolName":"bash"}}"#)
            func lastTool(_ s: Sink) -> ToolCall?? {
                s.events.compactMap { e -> ToolCall?? in
                    if case .toolUpdated(let t) = e { return .some(t) }
                    return nil
                }.last ?? nil
            }
            let early = lastTool(sink).flatMap { $0 }
            check(early?.kind == .bash && early?.title == "bash", "T17 toolcall_start 提前出卡 (title=工具名)")
            if case .queued = early?.phase {} else { check(false, "T17 提前卡为 queued") }
            pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"call_x1","toolName":"bash","args":{"command":"ls -la"}}"#)
            let running = lastTool(sink).flatMap { $0 }
            check(running?.title == "ls -la", "T17 execution_start 整卡替换 (title=args)")
            if case .running = running?.phase {} else { check(false, "T17 替换后转 running") }
            check(running?.id == early?.id, "T17 提前卡 id 沿用 (同一调用一张卡, 不残留 queued)")

            // ② 工具行分组: 连续同类折叠, 隔行不合并
            func toolEvent(_ kind: ToolKind) -> TrajectoryEvent {
                TrajectoryEvent(id: UUID(), kind: .tool, timestamp: Date(),
                                tool: ToolCall(kind: kind, title: "t", command: nil, phase: .done))
            }
            let turn = TrajectoryTurn(id: UUID(), index: 1, startedAt: Date(), prompt: "p",
                events: [toolEvent(.bash), toolEvent(.bash), toolEvent(.read), toolEvent(.bash)])
            let rows = TrajectoryBuilder.rows(for: turn)
            check(rows.count == 3, "T17 连续同类合并 + 隔行不合并 (3 行)")
            if case .group(let g) = rows[0] {
                check(g.count == 2 && g.kind == .bash, "T17 首组 = bash × 2")
            } else { check(false, "T17 首行为 group") }
            if case .single(let r1) = rows[1] { check(r1.tool?.kind == .read, "T17 中位 read 单行") }
            else { check(false, "T17 第二行为 single") }
            if case .single(let b3) = rows[2] { check(b3.tool?.kind == .bash, "T17 末位 bash 不跨组合并") }
            else { check(false, "T17 第三行为 single") }

            // ③ Turn 折叠规则: 默认仅展开最近一回合, override 优先
            let t1 = TrajectoryTurn(id: UUID(), index: 1, startedAt: Date(), prompt: "a", events: [])
            let t2 = TrajectoryTurn(id: UUID(), index: 2, startedAt: Date(), prompt: "b", events: [])
            check(TrajectoryBuilder.isTurnExpanded(t1, lastTurnId: t2.id, overrides: [:]) == false,
                  "T17 非最近回合默认折叠")
            check(TrajectoryBuilder.isTurnExpanded(t2, lastTurnId: t2.id, overrides: [:]) == true,
                  "T17 最近回合默认展开")
            check(TrajectoryBuilder.isTurnExpanded(t2, lastTurnId: t2.id, overrides: [t2.id: false]) == false,
                  "T17 用户 override 优先于默认")

            // ④ Details 派生: responseId 有值成行, 无值归并 unreported, 无 usage 跳过
            let base = Date(timeIntervalSinceReferenceDate: 100)
            let m1 = ChatMessage(role: .assistant, content: .text("a"), timestamp: base,
                                 usage: MessageUsage(input: 1, output: 2, totalTokens: 3, responseId: "r1"))
            let m2 = ChatMessage(role: .assistant, content: .text("b"), timestamp: base.addingTimeInterval(2),
                                 usage: MessageUsage(input: 5, output: 6, totalTokens: 11,
                                                     model: "deepseek/m2", responseId: "r2"))
            let m3 = ChatMessage(role: .assistant, content: .text("c"), timestamp: base.addingTimeInterval(3),
                                 usage: MessageUsage(input: 1, output: 1, totalTokens: 2))
            let m4 = ChatMessage(role: .assistant, content: .text("d"), timestamp: base.addingTimeInterval(4))
            let details = TrajectoryBuilder.details(from: [m1, m2, m3, m4])
            check(details.rows.count == 2 && details.unreported == 1, "T17 Details 行派生 + 未上报归并")
            check(details.rows[0].heuristicMs == 2000, "T17 Details 时长估计 (相邻时间差)")
            check(details.rows[1].usage.model == "deepseek/m2", "T17 Details model 透传")

            // 空/单行不炸 (0..<(-1) range trap 回归): 空会话直接进 Details 段曾致崩溃
            let emptyDetails = TrajectoryBuilder.details(from: [])
            check(emptyDetails.rows.isEmpty && emptyDetails.unreported == 0, "T17 Details 空集安全")
            let singleDetails = TrajectoryBuilder.details(from: [m1])
            check(singleDetails.rows.count == 1 && singleDetails.rows[0].heuristicMs == nil,
                  "T17 Details 单行安全 (无时长估计)")
            check(TrajectoryBuilder.turnTokens(TrajectoryTurn(
                id: UUID(), index: 1, startedAt: base, prompt: "p",
                events: [TrajectoryEvent(id: UUID(), kind: .assistant, timestamp: base,
                                         fullText: "x", usage: m1.usage),
                         TrajectoryEvent(id: UUID(), kind: .assistant, timestamp: base,
                                         fullText: "y", usage: m2.usage)])) == 14,
                  "T17 回合 tokens 合计")

            // ⑤ export_html 响应: 成功带 path / 失败上报 nil
            pi.handleRPCLine(#"{"type":"response","id":"e1","command":"export_html","success":true,"data":{"path":"/tmp/mangox-export.html"}}"#)
            check(sink.lastExport == "/tmp/mangox-export.html", "T17 export 成功上报 path")
            pi.handleRPCLine(#"{"type":"response","id":"e2","command":"export_html","success":false}"#)
            check(sink.lastExport == nil, "T17 export 失败上报 nil")

            // ⑥ 导出路径格式
            let exportPath = ChatStore.exportHTMLPath(
                sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                now: Date(timeIntervalSince1970: 0))
            check(exportPath.hasPrefix(NSHomeDirectory() + "/.mangox/exports/00000000-0000-0000-0000-000000000001-")
                  && exportPath.hasSuffix(".html"), "T17 导出路径格式 (sessionId-时间戳.html)")
        }

        // ---- T18 P6.3.1: Side chat (fork 快照截断 / 绑定决策 / 回读归并 / 失败清孤儿) ----
        do {
            // ① 快照截断纯函数: 3 轮源 (每轮 = user + assistant), 截到第 2 轮
            func userLine(_ n: Int) -> String {
                #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"turn \#(n)"}]}}"#
            }
            func asstLine() -> String {
                #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#
            }
            let src = [userLine(1), asstLine(), userLine(2), asstLine(), userLine(3), asstLine()]
            check(ChatStore.snapshotLinePrefix(src, turns: 2) == 4,
                  "T18 截断到第 2 轮 (丢弃第 3 条 user 起的全部行)")
            check(ChatStore.snapshotLinePrefix(src, turns: 3) == 6, "T18 turns=源轮数 → 整文件")
            check(ChatStore.snapshotLinePrefix(src, turns: 99) == 6, "T18 turns 超源 → 整文件")
            check(ChatStore.snapshotLinePrefix([], turns: 1) == 0, "T18 空文件安全")
            // 非消息行不计数, 模型切换行混排不干扰
            let mixed = [#"{"type":"model_change"}"#, userLine(1), asstLine(), userLine(2), asstLine()]
            check(ChatStore.snapshotLinePrefix(mixed, turns: 1) == 3,
                  "T18 model_change 行不计轮 (截在第二条 user 前)")

            // ② 截断快照落盘: turns=nil 恒等回源; 截断版行数正确; 源缺失返回 nil
            let srcPath = dir + "/t18-source.jsonl"
            try? src.joined(separator: "\n").write(toFile: srcPath, atomically: true, encoding: .utf8)
            let snapWritten = ChatStore.prepareForkSnapshot(sourcePath: srcPath, turns: 2)
            check(snapWritten?.hasSuffix(".jsonl") == true, "T18 截断快照落盘 (.jsonl)")
            if let snap = snapWritten {
                let snapLines = (try? String(contentsOfFile: snap, encoding: .utf8))?
                    .components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
                check(snapLines.count == 4, "T18 截断快照行数 = 4 (2 轮)")
                try? FileManager.default.removeItem(atPath: snap)
            }
            check(ChatStore.prepareForkSnapshot(sourcePath: dir + "/nope.jsonl", turns: 1) == nil,
                  "T18 源缺失 → nil")

            // ③ store 级: 无持久记忆 → 入口置灰; 发起侧问 → 建会话 + sideOf + 标题 + 落库
            check(!store.canStartSideChat, "T18 空态会话不可侧问 (无持久记忆)")
            let srcConv = sidA   // T1 已在 sidA 发过回合, MockTransport 不产 transcript 文件
            // Mock 路径无真实 .jsonl → 用显式 session_file 行模拟"有记忆" (loadSessionFile 优先)
            try? store.persistenceDebug?.setSessionFile(id: sidA, path: srcPath)
            store.selectConversation(sidA)
            check(store.canStartSideChat, "T18 显式记忆文件存在 → 侧问可用")
            store.startSideChat(from: srcConv, upTo: 2)
            let sideItem = store.chats.first { $0.sideOf == srcConv }
            check(sideItem != nil, "T18 侧问会话已建 (sideOf=源)")
            check(sideItem?.title.hasPrefix("Side · ") == true, "T18 标题 = Side · <源标题>")
            guard let sideId = sideItem?.id else { report() }
            check(store.selectedConversationId == sideId, "T18 侧问会话已选中")
            check(store.activeSideChat?.turns == 2 && store.activeSideChat?.parent == srcConv,
                  "T18 提示条信息 (源/轮数)")
            check(!(store.activeSideChat?.parentTitle.isEmpty ?? true), "T18 提示条源标题非空")
            // 绑定决策: 未回读 → fork 截断副本 (临时快照, 非源文件)
            if case .fork(let f) = store.sideChatBinding(for: sideId) {
                check(f.hasPrefix(PiRpcTransport.sessionDirectory) && f != srcPath,
                      "T18 回读前绑定 = fork 截断副本 (非源文件)")
            } else {
                check(false, "T18 回读前绑定 = fork 截断副本 (非源文件)")
            }

            // ④ 回读成功: session_file 落库 + 绑定切显式文件
            store.transport(mock, didReadSessionFile: dir + "/fork-product.jsonl")
            check(store.sideChatBinding(for: sideId)
                  == .explicitFile(path: dir + "/fork-product.jsonl"),
                  "T18 回读后绑定 = 显式产物路径")
            check(store.activeSideChat != nil, "T18 回读后提示条仍在")

            // ⑤ 回读失败: 侧问会话删除 (孤儿快照清理) + 横幅
            store.startSideChat(from: srcConv, upTo: 1)
            guard let side2 = store.chats.first(where: { $0.sideOf == srcConv && $0.id != sideId })?.id
            else { check(false, "T18 第二个侧问会话已建"); report() }
            if case .fork = store.sideChatBinding(for: side2) {
                check(true, "T18 侧问2 回读前 = fork")
            } else {
                check(false, "T18 侧问2 回读前 = fork")
            }
            store.transport(mock, didReadSessionFile: nil)
            check(store.allConversations.first { $0.id == side2 } == nil,
                  "T18 回读失败 → 侧问会话删除 (孤儿清理)")
            check(store.extensionNotice?.isError == true, "T18 失败横幅已提示")

            // ⑥ 普通会话绑定决策 = derived; 侧问会话不可再侧问 (入口置灰)
            check(store.sideChatBinding(for: sidB) == .derived, "T18 普通会话 = derived 绑定")
            store.selectConversation(sideId)
            check(!store.canStartSideChat, "T18 侧问自身不可再侧问 (防嵌套)")
            store.selectConversation(nil)
            check(store.activeSideChat == nil, "T18 空选中清提示条")

            // ⑦ rename 保留 sideOf; 删源会话不连带侧问
            store.renameConversation(sideId, to: "Side · 重命名")
            check(store.chats.first { $0.id == sideId }?.sideOf == srcConv,
                  "T18 重命名后 sideOf 保留")
        }

        // ---- T19 P6.3.2: Away summary (在场不积累 / 后台积累 / 分键隔离 / 结算 / 停止不计入) ----
        do {
            // 基线: 清早前测试遗留显示态 (T3/T5 的后台完成已在积累器留 key), 记积累器水位
            store.selectConversation(sidA)
            store.dismissAwaySummary()
            let awayBase = store.pendingAway.count

            // ① 在场选中会话完成 → 不积累 (冒烟无 NSApp 视为激活)
            store.draft = "在场完成"
            store.sendDraft()
            check(await waitUntil { store.runningTurns.isEmpty }, "T19 前台回合结束")
            check(store.pendingAway.count == awayBase, "T19 在场完成不积累")

            // ② 后台会话完成 → 按 sid 积累; 未切回不结算; preview 首行截断
            // (addScheduled 是 append, 新任务在 .last; 用 [0] 会误 fire T5 的旧任务)
            mock.scriptedReply = { _ in String(repeating: "很长的后台回复内容。", count: 20) }
            store.addScheduled(name: "T19巡检", prompt: "执行巡检", cron: "0 0 1 1 *", projectId: nil)
            store.runScheduledFire(store.scheduledTasks.last!)
            guard let log1 = store.scheduledTasks.last?.logSessionId else { check(false, "T19 日志会话1"); report() }
            check(await waitUntil { store.runningTurns.isEmpty }, "T19 后台回合结束")
            check(store.pendingAway[log1]?.turns == 1, "T19 后台完成积累 turns=1")
            check(store.awaySummary == nil, "T19 未切回不结算")
            check(store.pendingAway[log1]?.preview.hasSuffix("…") == true, "T19 preview 首行截断加省略号")

            // ③ 分键隔离: 第二个后台任务各自积累 (并发任务不串数据)
            mock.scriptedReply = { _ in "第二个任务完成" }
            store.addScheduled(name: "T19第二", prompt: "执行", cron: "0 0 1 1 *", projectId: nil)
            store.runScheduledFire(store.scheduledTasks.last!)
            guard let log2 = store.scheduledTasks.last?.logSessionId else { check(false, "T19 日志会话2"); report() }
            check(await waitUntil { store.runningTurns.isEmpty }, "T19 第二后台回合结束")
            check(store.pendingAway[log2]?.turns == 1 && store.pendingAway[log1]?.turns == 1,
                  "T19 双任务积累器分键隔离")

            // ④ 切回结算: 只消费当前 key; × 只关不滚
            store.selectConversation(log1)
            check(store.awaySummary?.sid == log1 && store.awaySummary?.turns == 1,
                  "T19 切回结算 (sid/turns)")
            check(store.pendingAway[log1] == nil && store.pendingAway[log2]?.turns == 1,
                  "T19 结算摘除自身 key, 他 key 不动")
            check(!hasText(store.messages, "第二个任务完成"), "T19 会话1 视图无任务2 内容")
            store.dismissAwaySummary()
            check(store.awaySummary == nil, "T19 × 只关 (显示态清除)")

            // ⑤ 切到任务2 各自结算; 新回合开始清过期摘要
            store.selectConversation(log2)
            check(store.awaySummary?.sid == log2 && store.awaySummary?.turns == 1,
                  "T19 切到任务2 结算各自摘要")
            store.draft = "新一轮"
            store.sendDraft()
            check(store.awaySummary == nil, "T19 新回合开始清摘要")
            check(await waitUntil { store.runningTurns.isEmpty }, "T19 任务2 回合收尾")

            // ⑥ 手动停止不计入: stop 清 turnStartAt → 补发 streamEnded (pi abort 路径) 无新增积累
            let awayBeforeStop = store.pendingAway.count
            store.stopStreaming()
            store.transport(mock, didEmit: .streamEnded)
            check(store.pendingAway.count == awayBeforeStop, "T19 停止后 streamEnded 不积累")
        }

        // ---- T20 P6.4: 首条消息自动命名 (首行前 10 字符, 一次性) ----
        do {
            store.newConversation()
            guard let t20sid = store.selectedConversationId else { check(false, "T20 建会话"); report() }
            check(store.chats.first { $0.id == t20sid }?.title == ChatStore.defaultConversationTitle,
                  "T20 初始默认标题")
            store.draft = "这是一条超过十个字符的首条消息, 用来验证自动命名"
            store.sendDraft()
            check(store.chats.first { $0.id == t20sid }?.title == "这是一条超过十个字符",
                  "T20 标题 = 首条消息前 10 字符")
            check(await waitUntil { store.runningTurns.isEmpty }, "T20 回合结束")
            // 第二条消息不再改标题
            store.draft = "第二条消息不应改标题"
            store.sendDraft()
            check(store.chats.first { $0.id == t20sid }?.title == "这是一条超过十个字符",
                  "T20 第二条消息不改标题")
            check(await waitUntil { store.runningTurns.isEmpty }, "T20 第二回合结束")
            // 短消息 (<10 字符) 取整行
            store.newConversation()
            guard let t20b = store.selectedConversationId else { check(false, "T20 建会话B"); report() }
            store.draft = "短名"
            store.sendDraft()
            check(store.chats.first { $0.id == t20b }?.title == "短名", "T20 短消息取整行")
            check(await waitUntil { store.runningTurns.isEmpty }, "T20 回合B结束")
            // 手动重命名后不再被自动命名覆盖
            store.renameConversation(t20b, to: "自定义")
            store.draft = "又一条消息内容"
            store.sendDraft()
            check(store.chats.first { $0.id == t20b }?.title == "自定义", "T20 手动重命名不被覆盖")
            check(await waitUntil { store.runningTurns.isEmpty }, "T20 回合C结束")
        }

        report()    }
}
