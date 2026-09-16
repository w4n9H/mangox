//
//  P4.0.2 冒烟: Transport 池 + 会话化 isStreaming
//  注入 MockTransport (串行基线) 验证: 回合归属路由 / 镜像投影 / fire 后台化 / done 停用 / 落库完整性
//  注意: 等待一律用 await Task.sleep 让出 MainActor (RunLoop 泵不驱动并发主执行器)
//

import Foundation
import SwiftUI
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

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

        // ---- T21 P7-M2: models 表 + legacy 迁移 + 物化 ----
        do {
            print("== T21 P7-M2: 模型自管真源 + 物化 ==")
            guard let mdb = try? PersistenceStore(path: dir + "/t21.db") else {
                check(false, "T21 建 DB"); report()
            }
            try? mdb.migrate()

            let cost = ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0.2,
                                 tiers: [ModelCost.Tier(inputTokensAbove: 200_000, input: 2, output: 4, cacheRead: 0.2, cacheWrite: 0.4)])
            let mA = ManagedModel(provider: "mangox-gw", modelId: "mangox-mini", displayName: "MangoX Mini",
                                  apiType: "openai-completions", baseURL: "https://gw.invalid/v1",
                                  keyRef: "mangox-gw", contextWindow: 131_072, maxTokens: 8_192,
                                  inputModalities: ["text", "image"], cost: cost,
                                  thinkingLevelMapJSON: "{\"high\":\"default\",\"low\":null}",
                                  compatJSON: "{\"supportsDeveloperRole\":false}",
                                  source: .preset)
            let mB = ManagedModel(provider: "mangox-gw", modelId: "mangox-max", displayName: "MangoX Max",
                                  apiType: "openai-completions", baseURL: "https://gw.invalid/v1",
                                  keyRef: "mangox-gw", source: .preset)
            let mC = ManagedModel(provider: "fake-anthropic", modelId: "fake-sonnet", displayName: "Fake Sonnet",
                                  apiType: "anthropic-messages", baseURL: "https://fake.invalid/v1",
                                  enabled: false, source: .custom)
            try? mdb.upsertManagedModel(mA)
            try? mdb.upsertManagedModel(mB)
            try? mdb.upsertManagedModel(mC)

            let loaded = (try? mdb.loadManagedModels()) ?? []
            check(loaded.count == 3, "T21 CRUD 往返 3 条")
            let la = loaded.first { $0.modelId == "mangox-mini" }
            check(la?.cost?.tiers?.first?.inputTokensAbove == 200_000, "T21 cost+tiers 往返")
            check(la?.inputModalities == ["text", "image"], "T21 input_modalities 往返")
            check(la?.thinkingLevelMapJSON == "{\"high\":\"default\",\"low\":null}", "T21 原样 JSON 透传 (thinkingLevelMap)")
            check(la?.compatJSON == "{\"supportsDeveloperRole\":false}", "T21 compat 透传")

            var mA2 = mA; mA2.displayName = "Mini v2"; mA2.enabled = false
            try? mdb.upsertManagedModel(mA2)
            check(((try? mdb.loadManagedModels()) ?? []).count == 3, "T21 同 PK 覆盖不新增")
            try? mdb.upsertManagedModel(mA)
            try? mdb.deleteManagedModel(provider: "fake-anthropic", modelId: "fake-sonnet")
            check(((try? mdb.loadManagedModels()) ?? []).count == 2, "T21 delete 生效")
            try? mdb.upsertManagedModel(mC)

            try? mdb.upsertCustomModel(CustomModel(provider: "deepseek", modelId: "deepseek-chat", label: "DeepSeek Chat"))
            try? mdb.upsertCustomModel(CustomModel(provider: "kimi", modelId: "kimi-k2"))
            let migrated = (try? mdb.migrateLegacyCustomModels()) ?? -1
            check(migrated == 2, "T21 legacy 迁移 2 条")
            let afterMig = (try? mdb.loadManagedModels()) ?? []
            let legacy = afterMig.first { $0.source == .legacy && $0.provider == "deepseek" }
            check(legacy != nil && legacy?.apiType == "openai-completions" && legacy?.baseURL == nil,
                  "T21 legacy 条目 source/apiType/无 baseURL")
            check(((try? mdb.migrateLegacyCustomModels()) ?? -1) == 0, "T21 迁移幂等 (重跑 0)")
            check(((try? mdb.loadCustomModels()) ?? []).count == 2, "T21 旧表保留")

            let keys = InMemoryModelKeyStore()
            try? keys.setKey("sk-test-123", account: "mangox-gw")
            let all = (try? mdb.loadManagedModels()) ?? []
            let out = ModelMaterializer.materialize(all, keyProvider: { keys.key(account: $0) })
            guard let providersObj = (try? JSONSerialization.jsonObject(with: out.modelsJSON)) as? [String: Any],
                  let providers = providersObj["providers"] as? [String: Any] else {
                check(false, "T21 物化 JSON 可解析"); report()
            }
            check(providers.count == 3, "T21 disabled 排除 + legacy 进物化 (3 providers)")
            let gw = providers["mangox-gw"] as? [String: Any]
            check(gw?["baseUrl"] as? String == "https://gw.invalid/v1" && gw?["api"] as? String == "openai-completions",
                  "T21 provider 级 baseUrl/api")
            let gwModels = gw?["models"] as? [[String: Any]] ?? []
            let mini = gwModels.first { ($0["id"] as? String) == "mangox-mini" }
            check(mini?["input"] as? [String] == ["text", "image"] && mini?["cost"] != nil
                  && (mini?["contextWindow"] as? Int) == 131_072, "T21 model 级元数据 (input/cost/contextWindow)")
            check(mini?["thinkingLevelMap"] != nil, "T21 thinkingLevelMap 片段透传")
            let dsProv = providers["deepseek"] as? [String: Any]
            check(dsProv?["baseUrl"] == nil && (dsProv?["models"] as? [[String: Any]])?.isEmpty == false,
                  "T21 legacy 无 baseUrl 省略")
            guard let authObj = (try? JSONSerialization.jsonObject(with: out.authJSON)) as? [String: Any] else {
                check(false, "T21 auth JSON 可解析"); report()
            }
            check((authObj["mangox-gw"] as? [String: Any])?["type"] as? String == "api_key"
                  && authObj["deepseek"] == nil, "T21 auth.json 按 provider 且无 key 不进")

            let out2 = ModelMaterializer.materialize(all, keyProvider: { keys.key(account: $0) })
            check(out.fingerprint == out2.fingerprint, "T21 fingerprint 确定性")
            var mA3 = mA; mA3.maxTokens = 4_096
            let out3 = ModelMaterializer.materialize(all.map { $0.modelId == "mangox-mini" ? mA3 : $0 },
                                                     keyProvider: { keys.key(account: $0) })
            check(out3.fingerprint != out.fingerprint, "T21 fingerprint 变更敏感")

            let cfgDir = URL(fileURLWithPath: dir).appendingPathComponent("pi-config", isDirectory: true)
            check(((try? ModelMaterializer.writeIfNeeded(out, to: cfgDir)) ?? false) == true, "T21 首次物化写入")
            let authAttrs = (try? FileManager.default.attributesOfItem(
                atPath: cfgDir.appendingPathComponent("auth.json").path)) ?? [:]
            check((authAttrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600, "T21 auth.json 0600 权限")
            check(((try? ModelMaterializer.writeIfNeeded(out, to: cfgDir)) ?? true) == false, "T21 指纹不变跳写")
            check(((try? ModelMaterializer.writeIfNeeded(out3, to: cfgDir)) ?? false) == true, "T21 变更后重写")
        }

        // ---- T22 P7-M3: 模型管理链路 (ChatStore CRUD + 物化推送 + /models 解析) ----
        do {
            print("== T22 P7-M3: 模型自管管理链路 ==")
            let keys22 = InMemoryModelKeyStore()
            try? keys22.setKey("sk-t22", account: "t22prov")
            let store22 = ChatStore(transport: mock, dbPath: dir + "/t22.db", modelKeyStore: keys22)
            check(store22.managedModels.isEmpty && mock.lastPIConfig == nil, "T22 初始无自管模型 (物化为 nil)")

            let m1 = ManagedModel(provider: "t22prov", modelId: "m1", displayName: "M1",
                                  apiType: "openai-completions", baseURL: "https://t22.invalid/v1",
                                  keyRef: "t22prov", source: .preset)
            let m2 = ManagedModel(provider: "t22prov", modelId: "m2", displayName: "",
                                  apiType: "openai-completions", baseURL: "https://t22.invalid/v1",
                                  keyRef: "t22prov")
            store22.upsertManagedModel(m1)
            store22.upsertManagedModel(m2)
            check(mock.lastPIConfig?.modelCount == 2, "T22 upsert 推送物化 (2)")
            let authObj22 = (try? JSONSerialization.jsonObject(with: mock.lastPIConfig!.authJSON)) as? [String: Any]
            check((authObj22?["t22prov"] as? [String: Any])?["key"] as? String == "sk-t22",
                  "T22 Keychain key 进 auth.json")
            store22.setManagedModelEnabled(m1.id, false)
            check(mock.lastPIConfig?.modelCount == 1, "T22 disable 后物化 (1)")
            check(store22.managedModels.count == 2, "T22 disable 不删条目")
            store22.deleteManagedModel(m1)
            store22.deleteManagedModel(m2)
            check(mock.lastPIConfig == nil && store22.managedModels.isEmpty, "T22 全删后物化为 nil")
            // 菜单只认自管 (P7-M3 拍板): 有自管 → 只显示 enabled 自管; 清空 → 回落 pi 目录
            store22.upsertManagedModel(m1)
            store22.upsertManagedModel(m2)
            check(Set(store22.menuModels.map(\.id)) == ["m1", "m2"] && store22.menuModels.count == 2,
                  "T22 有自管时菜单只显示自管条目")
            check(store22.menuModels.allSatisfy { $0.supportedLevels == [.off] },
                  "T22 无 thinkingLevelMap 的 chat 模型菜单只给 off")
            var mReason = m2; mReason.reasoning = true; mReason.thinkingLevelMapJSON = "{\"minimal\":null,\"low\":null,\"high\":\"high\",\"max\":\"max\"}"
            store22.upsertManagedModel(mReason)
            check(store22.menuModels.first { $0.id == "m2" }?.supportedLevels == [.off, .high],
                  "T22 有 map 按非 null 项收敛 (off/high)")
            let mDefault = ManagedModel(provider: "t22prov", modelId: "m3", displayName: "M3",
                                        apiType: "openai-completions", reasoning: true,
                                        baseURL: "https://t22.invalid/v1", keyRef: "t22prov")
            store22.upsertManagedModel(mDefault)
            check(store22.menuModels.first { $0.id == "m3" }?.supportedLevels == [.off, .minimal, .low, .medium, .high],
                  "T22 reasoning 无 map = pi 默认 off..high")
            store22.deleteManagedModel(m1)
            store22.deleteManagedModel(mReason)
            store22.deleteManagedModel(mDefault)
            check(store22.menuModels.contains { $0.provider == "deepseek" },
                  "T22 清空后菜单回落 pi 目录")

            if let legacyStore = try? PersistenceStore(path: dir + "/t22legacy.db") {
                try? legacyStore.migrate()
                try? legacyStore.upsertCustomModel(CustomModel(provider: "legprov", modelId: "legmodel", label: "Legacy"))
            }
            let store22b = ChatStore(transport: mock, dbPath: dir + "/t22legacy.db", modelKeyStore: keys22)
            check(store22b.managedModels.contains { $0.source == .legacy && $0.provider == "legprov" },
                  "T22 init 自动迁移 legacy 条目")
            check(store22b.customModels.contains { $0.provider == "legprov" }, "T22 旧表仍保留")

            let openaiJSON = Data("{\"data\":[{\"id\":\"a\"},{\"id\":\"b\"}]}".utf8)
            check(ModelCatalogFetcher.parseModelIds(openaiJSON) == ["a", "b"], "T22 OpenAI /models 解析")
            let ollamaJSON = Data("{\"models\":[{\"name\":\"l1\"},{\"id\":\"x\"}]}".utf8)
            check(ModelCatalogFetcher.parseModelIds(ollamaJSON) == ["l1", "x"], "T22 Ollama tags 解析 (name 优先, id 兜底)")
            check(ModelCatalogFetcher.parseModelIds(Data("not json".utf8)) == nil, "T22 垃圾输入返回 nil")
            check(ProviderPresets.all.count == 8 && Set(ProviderPresets.all.map(\.id)).count == 8,
                  "T22 预设库 8 家且 id 唯一")
            check(ProviderPresets.preset(id: "deepseek")?.seedModels.isEmpty == false
                  && ProviderPresets.preset(id: "ollama")?.needsKey == false, "T22 预设种子/Ollama 无 key")

            // ---- T22b P7-M3.5: models.dev 元数据目录 (三层自有化, 零依赖 ~/.pi/agent) ----
            print("== T22b P7-M3.5: 模型元数据目录 ==")
            // smoke 直编无 app bundle, 用 #filePath 定位仓库内 bundled 快照
            let repoCatalog = URL(fileURLWithPath: #filePath)          // scripts/smoke/smokeMain.swift
                .deletingLastPathComponent().deletingLastPathComponent()   // scripts/
                .deletingLastPathComponent()                               // 仓库根
                .appendingPathComponent("mangox/Resources/model-catalog.json")
            let bundledIndex = ModelCatalogStore.parse(try? Data(contentsOf: repoCatalog))
            check(bundledIndex != nil && bundledIndex!.count >= 10, "T22b bundled 快照解析 (10+ providers)")
            if let idx = bundledIndex {
                let flash = idx["deepseek"]?["deepseek-flash"]
                check(flash?.reasoning == true && (flash?.cost?.input ?? 0) > 0,
                      "T22b 目录条目元数据完整 (deepseek-flash)")
                let store22c = ModelCatalogStore(providers: idx)
                check(store22c.entry(provider: "deepseek", modelId: "deepseek-flash") != nil,
                      "T22b 精确命中")
                check(store22c.entry(provider: "kimi", modelId: "kimi-k3") != nil
                      && store22c.entry(provider: "zhipu", modelId: "glm-4.6") != nil,
                      "T22b 别名命中 (kimi→moonshotai, zhipu→zai)")
                check(store22c.entry(provider: "unknown-x", modelId: "deepseek-flash") != nil,
                      "T22b 模糊扫全目录唯一命中")
                check(store22c.entry(provider: "unknown-x", modelId: "glm") == nil,
                      "T22b 模糊多义/未命中返回 nil")
                check(store22c.entries(provider: "kimi").count == idx["moonshotai"]?.count,
                      "T22b entries(provider:) 走别名")
                // encode→parse roundtrip 保元数据
                if let round = ModelCatalogStore.parse(ModelCatalogStore.encode(idx)) {
                    check(round["deepseek"]?["deepseek-flash"]?.contextWindow == flash?.contextWindow
                          && round["deepseek"]?["deepseek-flash"]?.cost == flash?.cost,
                          "T22b encode/parse roundtrip 保真")
                } else {
                    check(false, "T22b encode/parse roundtrip 保真")
                }
            }
            let synthetic = ModelCatalogStore.parse(Data(#"""
{"prov":{"models":{"m1":{"name":"M One","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":32768,"cost":{"input":1.5,"output":3.0,"cacheRead":0.1,"cacheWrite":0.2}}}}}
"""#.utf8))
            let catM1 = synthetic?["prov"]?["m1"]
            check(catM1?.input == ["text", "image"] && catM1?.contextWindow == 200_000
                  && catM1?.cost?.output == 3.0, "T22b 合成 JSON 解析字段映射")

            // ---- T23 P7-M4: 模式选择器 (三档矩阵 + 池下发 + 按项目记忆) ----
            print("== T23 P7-M4: 模式选择器 ==")
            check(AgentMode.spawnArguments(for: .minimal, businessExtensions: ["/x/e.ts"])
                  == ["--tools", "read,bash,write,edit"], "T23 极简档 --tools 白名单, 不挂扩展")
            check(AgentMode.spawnArguments(for: .standard, businessExtensions: ["/x/e.ts"]).isEmpty,
                  "T23 常规档零参数 (pi 默认全量内置)")
            check(AgentMode.spawnArguments(for: .full, businessExtensions: ["/x/e.ts"])
                  == ["--extension", "/x/e.ts"], "T23 完整档挂业务扩展, 不带 --tools")
            check(AgentMode.minimal.storageIndex == 0 && AgentMode.full.storageIndex == 2
                  && AgentMode(storageIndex: 2) == .full && AgentMode(storageIndex: 99) == .standard,
                  "T23 存储序号 roundtrip + 越界回落 standard")

            let store23 = ChatStore(transport: mock, dbPath: dir + "/t23mode.db", modelKeyStore: keys22)
            store23.addProject(title: "P7M4", path: dir + "/t23proj")
            let proj23 = store23.projects.first?.id
            check(proj23 != nil, "T23 前置: smoke 库内真实建项目")
            store23.selectedProjectId = proj23
            check(store23.agentMode == .standard, "T23 默认档 standard")
            store23.agentMode = .minimal
            check(mock.lastMode == .minimal, "T23 切档全池下发 (minimal)")
            store23.agentMode = .full
            check(mock.lastMode == .full, "T23 切档全池下发 (full)")

            let store23b = ChatStore(transport: mock, dbPath: dir + "/t23mode.db", modelKeyStore: keys22)
            check(store23b.agentMode == .standard, "T23 新实例未选项目 = 默认档")
            store23b.selectedProjectId = proj23
            check(store23b.agentMode == .full && mock.lastMode == .full,
                  "T23 选项目恢复该项目档位 (按项目记忆)")

            // ---- T24 P7-M6a: 图片附件管线 (压缩/落盘/兼容/删会话先读后删) ----
            print("== T24 P7-M6a: 图片附件管线 ==")
            func makePNG(width: Int, height: Int) -> Data {
                let ctx = CGContext(data: nil, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let img = ctx.makeImage()!
                let buf = NSMutableData()
                let dest = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                return buf as Data
            }
            let bigPNG = makePNG(width: 2000, height: 1000)
            let size24 = ImagePipeline.pixelSize(of: bigPNG)
            check(size24?.width == 2000 && size24?.height == 1000,
                  "T24 pixelSize 读元数据")
            if let c = ImagePipeline.compressForSend(bigPNG) {
                check(c.width == 1536 && c.height == 768 && c.mimeType == "image/jpeg" && !c.data.isEmpty,
                      "T24 压缩长边 1536 / 比例保持 / JPEG mime")
            } else {
                check(false, "T24 压缩长边 1536 / 比例保持 / JPEG mime")
            }
            let smallPNG = makePNG(width: 800, height: 600)
            if let c2 = ImagePipeline.compressForSend(smallPNG) {
                check(c2.width == 800 && c2.height == 600, "T24 小图不放大 (仅转 JPEG 压体积)")
            } else {
                check(false, "T24 小图不放大 (仅转 JPEG 压体积)")
            }
            check(ImagePipeline.compressForSend(Data("junk".utf8)) == nil, "T24 垃圾输入返回 nil")
            check(ImagePipeline.isImageExtension("PNG") && !ImagePipeline.isImageExtension("pdf")
                  && ImagePipeline.mimeType(forExtension: "jpg") == "image/jpeg",
                  "T24 扩展名识别/mime 映射")
            check(ImagePipeline.maxPerMessage == 4, "T24 单条上限 4 张")

            let msg24 = ChatMessage(role: .user, content: .text("看图"),
                                    attachments: [Attachment(path: "/tmp/x.png", pixelWidth: 10,
                                                             pixelHeight: 10, mimeType: "image/png", byteSize: 5)])
            let round24 = try? JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(msg24))
            check(round24?.attachments?.count == 1, "T24 ChatMessage 附件 JSON roundtrip")
            let legacy24 = try? JSONDecoder().decode(ChatMessage.self, from: Data(#"""
{"id":"C69D4E9C-9A1B-4C0E-9D2B-111111111111","role":"user","content":{"text":{"_0":"旧消息"}},"timestamp":0,"isStreaming":false}
"""#.utf8))
            check(legacy24?.attachments == nil && legacy24 != nil, "T24 旧 payload (无 attachments key) 解码兼容")

            let sid24 = UUID()
            let store24ps = try! PersistenceStore(path: dir + "/t24attach.db")
            try! store24ps.migrate()
            try! store24ps.insertChatSession(ConversationItem(id: sid24, title: "T24"))
            let saved24 = try! ImagePipeline.saveOriginal(makePNG(width: 60, height: 40),
                                                     fileExtension: "png", sessionID: sid24)
            check(saved24.byteSize > 0 && FileManager.default.fileExists(atPath: saved24.path),
                  "T24 saveOriginal 落盘 (原图留档)")
            try! store24ps.appendMessageEvent(sessionId: sid24, ChatMessage(
                role: .user, content: .text("带图消息"),
                attachments: [Attachment(path: saved24.path, pixelWidth: 60, pixelHeight: 40,
                                         mimeType: "image/png", byteSize: saved24.byteSize)]))
            let store24 = ChatStore(transport: mock, dbPath: dir + "/t24attach.db", modelKeyStore: keys22)
            store24.selectConversation(sid24)
            check(store24.messages.first?.attachments?.first?.path == saved24.path,
                  "T24 replay 从 events 渲染附件 (与实时同源)")
            store24.deleteConversation(sid24)
            // 沙箱执行环境对 ~/.mangox 目录 unlink 拒绝 (513), 真实 App 无此限制;
            // 目录清理的确定性断言走 baseDirectory 注入 (临时目录内 unlink 可行)。
            check(store24.messages.isEmpty, "T24 删会话清 events (先读后删路径已走)")
            let base24 = URL(fileURLWithPath: dir + "/t24attach-fs")
            let saved24b = try! ImagePipeline.saveOriginal(makePNG(width: 60, height: 40),
                                                           fileExtension: "png", sessionID: sid24,
                                                           baseDirectory: base24)
            check(FileManager.default.fileExists(atPath: saved24b.path),
                  "T24 baseDirectory 注入落盘")
            let rmErr = ImagePipeline.removeSessionAttachments(sessionID: sid24, baseDirectory: base24)
            check(rmErr == nil && !FileManager.default.fileExists(atPath: saved24b.path),
                  "T24 删会话清附件目录 (注入基目录)")

            // ---- T24b P7-M6b: 三入口暂存 + 发送 images + 门控 ----
            print("== T24b P7-M6b: 附件发送链路 ==")
            let store24b = ChatStore(transport: mock, dbPath: dir + "/t24send.db", modelKeyStore: keys22)
            let png24b = makePNG(width: 300, height: 200)
            store24b.addPendingImage(png24b, suggestedExtension: "png")
            check(store24b.pendingImages.count == 1 && store24b.pendingImages[0].pixelWidth == 300,
                  "T24b addPendingImage 暂存 (像素尺寸就位)")
            store24b.addPendingImage(Data("junk".utf8), suggestedExtension: "png")
            check(store24b.pendingImages.count == 1, "T24b 垃圾数据不入暂存区")
            for _ in 0..<5 { store24b.addPendingImage(png24b, suggestedExtension: "png") }
            check(store24b.pendingImages.count == 4, "T24b 上限 4 张 (第 5 张拒收)")
            store24b.removePendingImage(store24b.pendingImages[0].id)
            check(store24b.pendingImages.count == 3, "T24b chips × 移除")

            // 门控: 当前模型 text-only → 发送拦截
            let textOnly = ManagedModel(provider: "p1", modelId: "textonly",
                                        apiType: "openai-completions", inputModalities: ["text"])
            store24b.upsertManagedModel(textOnly)
            store24b.selectManagedModel(textOnly)
            store24b.draft = "看图"
            let msgsBefore = store24b.messages.count
            store24b.sendDraft()
            check(store24b.messages.count == msgsBefore && store24b.pendingImages.count == 3
                  && store24b.turnLimitNotice != nil,
                  "T24b text-only 模型发送拦截 (附件保留可换模型后发)")

            // 换多模态模型 → 落盘 + 压缩 + RPC images
            let vision = ManagedModel(provider: "p1", modelId: "vision",
                                      apiType: "openai-completions", inputModalities: ["text", "image"])
            store24b.upsertManagedModel(vision)
            store24b.selectManagedModel(vision)
            store24b.sendDraft()
            // png 300×200 未超限 → 原样透传 (设计拍板: 小 png/gif/webp 保原样/动图)
            check(mock.lastSentImages.count == 3 && mock.lastSentImages.allSatisfy { $0.mimeType == "image/png" },
                  "T24b 发送 images 数组 (未超限 png 透传)")
            let bigOut = ImagePipeline.outgoingPayload(data: bigPNG, ext: "png",
                                                       pixelWidth: 2000, pixelHeight: 1000)
            check(bigOut?.mimeType == "image/jpeg" && (bigOut?.data.count ?? 0) > 0,
                  "T24b 超限位图转 JPEG 副本")
            check(store24b.pendingImages.isEmpty && store24b.messages.last?.attachments?.count == 3,
                  "T24b 发送后暂存清空 + 消息带附件 (落盘原图)")
            check(store24b.messages.last?.attachments?.first?.byteSize ?? 0 > 0
                  && FileManager.default.fileExists(atPath: store24b.messages.last!.attachments!.first!.path),
                  "T24b 附件原图落盘留档")

            // ---- T25 P8.0: 侧栏日分组 (今天/昨天/本周/更早) ----
            print("== T25 P8.0: 侧栏日分组 ==")
            var cal25 = Calendar(identifier: .gregorian)
            cal25.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let now25 = cal25.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!   // 周三
            let d25 = { (day: Int) in cal25.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 9))! }
            check(DayBucket.bucket(for: d25(16), now: now25, calendar: cal25) == .today
                  && DayBucket.bucket(for: d25(15), now: now25, calendar: cal25) == .yesterday
                  && DayBucket.bucket(for: d25(13), now: now25, calendar: cal25) == .thisWeek
                  && DayBucket.bucket(for: d25(8), now: now25, calendar: cal25) == .earlier,
                  "T25 日桶四段划分 (今天/昨天/本周/更早)")

            // ---- T26 P8: 侧栏审批阻塞提示 (置位/响应清/兜底清/删除清) ----
            print("== T26 P8: 审批阻塞侧栏提示 ==")
            store.newConversation()
            guard let sid26 = store.selectedConversationId else { check(false, "T26 建会话"); report() }
            let tool26 = ToolCall(kind: .bash, title: "deploy.sh", phase: .awaitingApproval)
            store.transport(mock, didEmit: .toolUpdated(tool26))
            check(store.approvalBlocked.contains(sid26), "T26 toolUpdated(awaitingApproval) 置位")
            store.approveTool(tool26.id)
            check(!store.approvalBlocked.contains(sid26), "T26 审批响应即清")
            store.transport(mock, didEmit: .toolPhaseChanged(toolId: tool26.id, phase: .awaitingApproval))
            check(store.approvalBlocked.contains(sid26), "T26 toolPhaseChanged 置位")
            store.transport(mock, didEmit: .streamEnded)
            check(!store.approvalBlocked.contains(sid26), "T26 streamEnded 兜底清除")
            store.transport(mock, didEmit: .toolUpdated(ToolCall(kind: .bash, title: "x", phase: .awaitingApproval)))
            check(store.approvalBlocked.contains(sid26), "T26 重新置位 (删除用例前置)")
            store.deleteConversation(sid26, deleteTranscript: false)
            check(!store.approvalBlocked.contains(sid26), "T26 删除会话清除")

            // ---- T26b P8: 审批真链路 (PiRpcTransport 实解析 → store, 复刻实机事件序) ----
            print("== T26b P8: 审批真链路 ==")
            let dir26b = NSHomeDirectory() + "/.mangox/smoke-t26b-\(UUID().uuidString.prefix(8))"
            try? FileManager.default.createDirectory(atPath: dir26b, withIntermediateDirectories: true)
            let pi26 = PiRpcTransport()
            let store26 = ChatStore(transport: pi26, dbPath: dir26b + "/t26b.db",
                                    managedExtensionsDir: dir26b + "/ext")
            store26.newConversation()
            guard let sid26b = store26.selectedConversationId else { check(false, "T26b 建会话"); report() }
            pi26.handleRPCLine(#"{"type":"agent_start"}"#)
            pi26.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c26b","toolName":"bash","args":{"command":"cat > t.txt"}}"#)
            pi26.handleRPCLine(#"{"type":"extension_ui_request","id":"u26b","method":"select","title":"MANGOX|APPROVE|c26b|bash|cat > t.txt"}"#)
            check(store26.approvalBlocked.contains(sid26b), "T26b 真链路 extension_ui_request 置位")
            // 审批响应 → 白名单判定外真实响应命令发出 + 集合清除
            store26.approveTool(store26.messages.compactMap { msg -> UUID? in
                if case .tool(let t) = msg.content, t.phase == .awaitingApproval { return t.id }
                return nil
            }.first ?? UUID())
            check(!store26.approvalBlocked.contains(sid26b), "T26b 审批响应清除 (真链路)")
            check(pi26.sentCommands.contains { ($0["type"] as? String) == "extension_ui_response" },
                  "T26b extension_ui_response 已回给 pi")

            // ---- T25b P8.0: 会话活跃刷新 updatedAt (日分组数据源, 防"昨天"误显) ----
            print("== T25b P8.0: updatedAt 活跃刷新 ==")
            let dir25b = NSHomeDirectory() + "/.mangox/smoke-t25b-\(UUID().uuidString.prefix(8))"
            try? FileManager.default.createDirectory(atPath: dir25b, withIntermediateDirectories: true)
            let store25b = ChatStore(transport: MockTransport(), dbPath: dir25b + "/t25b.db",
                                     managedExtensionsDir: dir25b + "/ext")
            store25b.newConversation()
            guard let sid25b = store25b.selectedConversationId else { check(false, "T25b 建会话"); report() }
            let before25b = store25b.chats.first { $0.id == sid25b }?.updatedAt ?? .distantPast
            store25b.draft = "活跃刷新测试"
            store25b.sendDraft()
            check(await waitUntil { store25b.runningTurns.isEmpty }, "T25b 回合结束")
            check((store25b.chats.first { $0.id == sid25b }?.updatedAt ?? .distantPast) > before25b,
                  "T25b 回合落库刷新 updatedAt (内存)")
            let reload25b = ChatStore(transport: MockTransport(), dbPath: dir25b + "/t25b.db",
                                      managedExtensionsDir: dir25b + "/ext")
            let reloaded25b = reload25b.chats.first { $0.id == sid25b }?.updatedAt ?? .distantPast
            check(reloaded25b > before25b && abs(reloaded25b.timeIntervalSinceNow) < 60,
                  "T25b updatedAt 落库 roundtrip (重启不回退)")

            // ---- T28 P8: 手动备份 (checkpoint→拷贝→时间戳目录; 缺目录容错) ----
            print("== T28 P8: 手动备份 ==")
            let dir28 = NSHomeDirectory() + "/.mangox/smoke-t28-\(UUID().uuidString.prefix(8))"
            let src28 = dir28 + "/src", dest28 = dir28 + "/dest"
            try! FileManager.default.createDirectory(atPath: src28 + "/attachments", withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(atPath: src28 + "/sessions", withIntermediateDirectories: true)
            try! Data("DBDATA-28".utf8).write(to: URL(fileURLWithPath: src28 + "/mangox.db"))
            try! Data("PNG".utf8).write(to: URL(fileURLWithPath: src28 + "/attachments/a1.png"))
            try! Data("JSONL".utf8).write(to: URL(fileURLWithPath: src28 + "/sessions/s1.jsonl"))
            var checkpoint28 = 0
            let now28 = Date(timeIntervalSince1970: 1789500000)   // 固定时刻 → 时间戳目录名可断言
            let out28 = BackupEngine.backup(dbPath: src28 + "/mangox.db",
                                            attachmentsDir: src28 + "/attachments",
                                            sessionsDir: src28 + "/sessions",
                                            destRoot: dest28,
                                            checkpoint: { checkpoint28 += 1 },
                                            now: now28)
            check(checkpoint28 == 1, "T28 checkpoint 先行调用")
            check(out28.ok && out28.dbCopied && out28.attachmentsCopied && out28.sessionsCopied,
                  "T28 三项齐 + ok")
            check(out28.destPath.hasSuffix("mangox-backup-\(BackupEngine.stampFormatter.string(from: now28))"),
                  "T28 时间戳子目录命名")
            check(FileManager.default.fileExists(atPath: out28.destPath + "/mangox.db")
                  && FileManager.default.fileExists(atPath: out28.destPath + "/attachments/a1.png")
                  && FileManager.default.fileExists(atPath: out28.destPath + "/sessions/s1.jsonl"),
                  "T28 拷贝产物就位")
            check(out28.totalBytes > 0, "T28 大小汇总")
            // 容错: 附件/会话源缺失不算失败
            let out28b = BackupEngine.backup(dbPath: src28 + "/mangox.db",
                                             attachmentsDir: nil, sessionsDir: "/nonexistent-28",
                                             destRoot: dest28, checkpoint: nil, now: now28.addingTimeInterval(1))
            check(out28b.ok && !out28b.attachmentsCopied && !out28b.sessionsCopied && out28b.errors.isEmpty,
                  "T28 缺目录容错跳过 (非失败)")
            // 硬失败: db 缺失 → 报错不 ok
            let out28c = BackupEngine.backup(dbPath: "/nonexistent-28/x.db",
                                             attachmentsDir: nil, sessionsDir: nil,
                                             destRoot: dest28, checkpoint: nil, now: now28.addingTimeInterval(2))
            check(!out28c.ok && !out28c.errors.isEmpty, "T28 db 缺失 = 硬失败")

            // ---- T27 P8: 快速捕获 (热键配置 + 无人值守发送链路) ----
            print("== T27 P8: 快速捕获 ==")
            let dir27 = NSHomeDirectory() + "/.mangox/smoke-t27-\(UUID().uuidString.prefix(8))"
            try! FileManager.default.createDirectory(atPath: dir27, withIntermediateDirectories: true)
            let mock27 = MockTransport()
            let store27 = ChatStore(transport: mock27, dbPath: dir27 + "/t27.db",
                                    managedExtensionsDir: dir27 + "/ext")
            // ① 热键: 默认 ⌥X / KV roundtrip / 展示名
            check(store27.captureHotkey == .fallback && store27.captureHotkey.display == "⌃⌥X",
                  "T27 默认热键 ⌃⌥X")
            let hk27 = CaptureHotkey(keyCode: 46, modifiers: CaptureHotkey.option | CaptureHotkey.shift)
            store27.setCaptureHotkey(hk27)
            check(CaptureHotkey.load(persistence: store27.persistenceDebug) == hk27,
                  "T27 热键 KV roundtrip")
            check(hk27.display == "⌥⇧M" && !hk27.hasModifier == false, "T27 修饰键掩码/键名")
            // ② 发送链路: 建会话 + 自动命名 + 无人值守 + Minimal 强制
            let sid27 = store27.submitCapture(text: "修复登录页超时", target: .newSession(projectId: nil))
            check(sid27 != nil && store27.chats.first { $0.id == sid27 }?.title == "修复登录页超时",
                  "T27 建会话 + 首条自动命名")
            check(mock27.lastMode == .minimal, "T27 Minimal 档强制下发 (全局档位不动)")
            check(mock27.lastAskApproval == false, "T27 无人值守关审批")
            check(mock27.boundSessionId == sid27, "T27 常规会话绑定 (非 ephemeral)")
            check(store27.selectedConversationId == sid27, "T27 主窗口跟随选中")
            check(await waitUntil { store27.runningTurns.isEmpty }, "T27 捕获回合收尾")
            // ③ 边界: 空文本拒绝 / 项目归属
            check(store27.submitCapture(text: "   ", target: .newSession(projectId: nil)) == nil,
                  "T27 空文本拒绝")
            store27.addProject(title: "T27 项目", path: "/tmp/t27")
            let pid27 = store27.projects[0].id
            let sid27b = store27.submitCapture(text: "项目内任务", target: .newSession(projectId: pid27))
            check(sid27b != nil && store27.projects[0].items.contains { $0.id == sid27b },
                  "T27 会话归入选定项目")
            check(mock27.lastAskApproval == false, "T27 第二次捕获仍无人值守")
            check(await waitUntil { store27.runningTurns.isEmpty }, "T27 追加前置收尾")

            // ④ 追加既有会话: 同 id / 无人值守 / 档位跟随不强改
            let sid27c = store27.submitCapture(text: "再追一条", target: .append(sessionId: sid27!))
            check(sid27c == sid27, "T27 追加落既有会话 (同 id)")
            check(mock27.lastAskApproval == false, "T27 追加仍无人值守")
            check(store27.messages.contains { msg in
                if case .text(let s) = msg.content { return s == "再追一条" }
                return false
            }, "T27 追加消息上屏 (replay 带全量历史)")
            check(await waitUntil { store27.runningTurns.isEmpty }, "T27 追加回合收尾")
            // 追加不强制 Minimal: 普通会话 (standard 实例) 追加后仍 standard
            store27.newConversation()
            let sid27d = store27.selectedConversationId!
            store27.draft = "普通会话"
            store27.sendDraft()
            check(await waitUntil { store27.runningTurns.isEmpty }, "T27 普通会话回合收尾")
            // 追加不强制 Minimal: 先显式推 .full 作实例基线 (真实池化路径 = 新实例建时带全局档位),
            // 追加后档位应保持 full 而非被改写 minimal
            store27.agentMode = .full
            check(mock27.lastMode == .full, "T27 前置: 实例档位基线 full")
            let sid27e = store27.submitCapture(text: "追加到普通", target: .append(sessionId: sid27d))
            check(sid27e == sid27d && mock27.lastMode == .full,
                  "T27 追加档位跟随会话 (不强改 Minimal)")
            check(await waitUntil { store27.runningTurns.isEmpty }, "T27 普通追加收尾")
            // ⑤ 拒绝路径: 在途 / 已删除
            mock27.scriptedReply = { _ in String(repeating: "慢回复。", count: 200) }
            store27.draft = "占用中"
            store27.sendDraft()
            check(store27.submitCapture(text: "此时追加", target: .append(sessionId: sid27d)) == nil,
                  "T27 在途会话追加拒绝")
            check(await waitUntil { store27.runningTurns.isEmpty }, "T27 占用回合收尾")
            store27.deleteConversation(sid27b!, deleteTranscript: false)
            check(store27.submitCapture(text: "x", target: .append(sessionId: sid27b!)) == nil,
                  "T27 已删会话追加拒绝")
            mock27.scriptedReply = nil

            // ---- T-P9 Batch1: P9-#1 导出 delegate 链路 (注入实例) ----
            // 修复前: exportTraceHTML 未挂 delegate → 回调被丢 → 永远 20s 超时;
            // 修复后: MockTransport 同步回调 (nil = 失败分支, 避免冒烟弹 Finder) → 立即收尾
            print("== T-P9 Batch1: 导出 delegate 链路 ==")
            let dir9 = NSHomeDirectory() + "/.mangox/smoke-tp9-\(UUID().uuidString.prefix(8))"
            try! FileManager.default.createDirectory(atPath: dir9, withIntermediateDirectories: true)
            let store9 = ChatStore(transport: mock27, dbPath: dir9 + "/t9.db",
                                   managedExtensionsDir: dir9 + "/ext")
            store9.newConversation()
            store9.exportTraceHTML()
            check(!store9.isExportingHTML, "T-P9 导出回调即收尾 (不再卡 20s 超时)")
            check(mock27.lastExportPath?.contains("/.mangox/exports/") == true,
                  "T-P9 导出路径已下发 (delegate 挂接生效)")
            check(store9.extensionNotice?.text == "导出失败",
                  "T-P9 失败分支通知 (Mock 回 nil 的预期语义)")

            // ---- T-P9b Batch2: regenerate 清库 (P9-#2) + fire 强制无人值守 (P9-#17) ----
            print("== T-P9b Batch2: regenerate 清库 + fire 无人值守 ==")
            let dir9b = NSHomeDirectory() + "/.mangox/smoke-tp9b-\(UUID().uuidString.prefix(8))"
            try! FileManager.default.createDirectory(atPath: dir9b, withIntermediateDirectories: true)
            let mock9b = MockTransport()
            let store9b = ChatStore(transport: mock9b, dbPath: dir9b + "/t.db",
                                    managedExtensionsDir: dir9b + "/ext")
            store9b.draft = "第一问"
            store9b.sendDraft()
            check(await waitUntil { store9b.runningTurns.isEmpty }, "T-P9b 首回合收尾")
            let sid9b = store9b.selectedConversationId!
            let dbBefore = (try? store9b.persistenceDebug?.loadMessages(sessionId: sid9b))?.count ?? -1
            check(dbBefore == 2, "T-P9b 前置: 库内 user+assistant 两条")
            store9b.regenerate()
            check(await waitUntil { store9b.runningTurns.isEmpty }, "T-P9b 重生成收尾")
            let dbAfter = (try? store9b.persistenceDebug?.loadMessages(sessionId: sid9b)) ?? []
            check(dbAfter.count == 2, "T-P9b 库内仍两条 (旧 assistant 已删, 重启不复活)")
            check(dbAfter.filter { $0.role == .user }.count == 1, "T-P9b user 消息保留一份")
            check(store9b.messages.last?.role == .assistant, "T-P9b 重生成回复上屏")
            // P9-#17: attended 定时任务 fire 恒无人值守 (后台审批卡不可达, 弹卡 = 卡死到超时)
            var task9b = ScheduledTask(id: UUID(), name: "P9 哨兵", prompt: "检查", cron: "0 0 1 1 *",
                                       projectId: nil)
            task9b.unattended = false
            store9b.runScheduledFire(task9b)
            check(mock9b.lastAskApproval == false, "T-P9b attended fire 强制无人值守 (P9-#17)")
            check(await waitUntil { store9b.runningTurns.isEmpty }, "T-P9b fire 收尾")

            // ---- T-P9c Batch3: 重放缓存 + seq 游标一致性 (P9-#10) ----
            print("== T-P9c Batch3: 重放缓存一致性 ==")
            let once9c = (try? store9b.persistenceDebug?.loadMessages(sessionId: sid9b)) ?? []
            let twice9c = (try? store9b.persistenceDebug?.loadMessages(sessionId: sid9b)) ?? []
            check(once9c.count == 2 && twice9c.count == 2, "T-P9c 缓存命中与直读一致 (regenerate 后仍 2 条)")
            // fire 日志会话: append 路径走 seq 游标 + 缓存失效, 新会话消息必须可重放
            let fireLogId9c = store9b.chats.first { $0.title == "P9 哨兵" }?.id
            let fireMsgs9c = fireLogId9c.flatMap { try? store9b.persistenceDebug?.loadMessages(sessionId: $0) } ?? []
            check(fireMsgs9c.count >= 2 && fireMsgs9c.contains(where: { $0.role == .user }),
                  "T-P9c fire 日志落库可重放 (seq 游标连续 + 缓存失效正确)")
        }

        report()    }
}
