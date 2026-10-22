//
//  CaseEmptyTurn.swift
//  空回合的判据 (2026-10-21, `AgentEvent.emptyTurn`)。
//
//  为什么值得断言: 这是生产上一个**零信号**的故障形状 —— 定时任务 pin 的模型下线后
//  API 回 `404 page not found`, pi 把它吃成一个"正常收尾的空回合":
//      agent_start → content 为空的 assistant message_end → agent_settled(aborted:false)
//  进程不退出、不报错、`sawAnyRPC` 为真（启动失败那条判据完全管不着）, 日志会话里
//  除了 prompt 一个字都没有。用户看到的只有"点了没反应"。
//
//  ⚠️ 下面 ① 里那六行 JSONL 是**实测序列**（2026-10-21 A/B 对照里录下来的形状）,
//     断言不许比它更宽: 少喂一条 `agent_start` 就不再是"引擎跑过但什么都没给"。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseEmptyTurn() async {
        print("== T-EMPTYTURN 空回合可见性 (引擎正常收尾却零产出) ==")

        final class Sink: AgentTransportDelegate {
            var events: [AgentEvent] = []
            func transport(_ t: any AgentTransport, didEmit event: AgentEvent) { events.append(event) }
            func transport(_ t: any AgentTransport, didFailEngineWithDiagnosis d: String) {}
        }
        func emptyTurns(_ s: Sink) -> Int {
            s.events.filter { if case .emptyTurn = $0 { return true }; return false }.count
        }
        func emptyTurnModel(_ s: Sink) -> String? {
            for e in s.events { if case .emptyTurn(let m) = e { return m } }
            return nil
        }
        func ended(_ s: Sink) -> Int {
            s.events.filter { if case .streamEnded = $0 { return true }; return false }.count
        }
        func indexOfEmpty(_ s: Sink) -> Int? {
            s.events.firstIndex { if case .emptyTurn = $0 { return true }; return false }
        }
        func indexOfEnded(_ s: Sink) -> Int? {
            s.events.firstIndex { if case .streamEnded = $0 { return true }; return false }
        }

        // ① 实测的空回合序列 ⇒ 恰好一条 emptyTurn, 且点名模型
        let p1 = PiRpcTransport()
        let s1 = Sink()
        p1.delegate = s1
        p1.setModel(provider: "minimax", modelId: "MiniMax-M3.1-Flash-Preview")
        p1.handleRPCLine(#"{"type":"agent_start"}"#)
        p1.handleRPCLine(#"{"type":"message_start","message":{"role":"assistant","content":[]}}"#)
        p1.handleRPCLine(#"{"type":"message_end","message":{"role":"assistant","content":[]}}"#)
        p1.handleRPCLine(#"{"type":"turn_end","turnIndex":0,"message":{"role":"assistant","content":[]},"toolResults":[]}"#)
        p1.handleRPCLine(#"{"type":"agent_end","messages":[],"willRetry":false}"#)
        check(emptyTurns(s1) == 0, "T-EMPTYTURN 未落定前不报空回合 (agent_end ≠ 结束, 还在等 settled)")
        p1.handleRPCLine(#"{"type":"agent_settled"}"#)
        check(emptyTurns(s1) == 1, "T-EMPTYTURN 实测 404 序列 ⇒ 一条空回合事件 (实测 \(emptyTurns(s1)) 条)")
        check(emptyTurnModel(s1) == "minimax/MiniMax-M3.1-Flash-Preview",
              "T-EMPTYTURN 点名本回合真正下发给 pi 的模型 (实测 \(emptyTurnModel(s1) ?? "nil"))")
        check(ended(s1) == 1, "T-EMPTYTURN 空回合仍然正常落定 (不影响既有收尾)")
        // 顺序是**硬要求**: 落定之后 Store 已经丢掉本回合的镜像容器, 后台会话那条提示会无处可去
        if let iE = indexOfEmpty(s1), let iEnd = indexOfEnded(s1) {
            check(iE < iEnd, "T-EMPTYTURN 事件顺序: emptyTurn 在 streamEnded 之前 (实测 \(iE) < \(iEnd))")
        } else {
            check(false, "T-EMPTYTURN 事件顺序: 两个事件都要在")
        }

        // ② 反例: 有正文 ⇒ 不是空回合（判据不能只看"有没有 settled"）
        let p2 = PiRpcTransport()
        let s2 = Sink()
        p2.delegate = s2
        p2.handleRPCLine(#"{"type":"agent_start"}"#)
        p2.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"在"}}"#)
        p2.handleRPCLine(#"{"type":"message_end","message":{"role":"assistant","content":[]}}"#)
        p2.handleRPCLine(#"{"type":"agent_settled"}"#)
        check(emptyTurns(s2) == 0, "T-EMPTYTURN 反例: 出过一个字就不算空回合 (哪怕 message_end 的 content 是空数组)")

        // ③ 反例: 只有思考 / 只有工具卡也算产出
        let p3 = PiRpcTransport()
        let s3 = Sink()
        p3.delegate = s3
        p3.handleRPCLine(#"{"type":"agent_start"}"#)
        p3.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"想"}}"#)
        p3.handleRPCLine(#"{"type":"agent_settled"}"#)
        check(emptyTurns(s3) == 0, "T-EMPTYTURN 反例: 只有思考块不算空回合")

        let p4 = PiRpcTransport()
        let s4 = Sink()
        p4.delegate = s4
        p4.handleRPCLine(#"{"type":"agent_start"}"#)
        p4.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","id":"c1","toolName":"bash"}}"#)
        p4.handleRPCLine(#"{"type":"agent_settled"}"#)
        check(emptyTurns(s4) == 0, "T-EMPTYTURN 反例: 只有工具卡不算空回合")

        // ④ 反例: 用户自己按了停 —— 零产出是**预期**的, 不许报成引擎出错
        //    (与 Store 侧 `elapsed == nil` 排除手动停同一条语义)
        let p5 = PiRpcTransport()
        let s5 = Sink()
        p5.delegate = s5
        p5.handleRPCLine(#"{"type":"agent_start"}"#)
        p5.cancel()
        p5.handleRPCLine(#"{"type":"agent_settled"}"#)
        check(ended(s5) == 1, "T-EMPTYTURN 手动停: 仍然正常落定")
        check(emptyTurns(s5) == 0, "T-EMPTYTURN 手动停: 不报空回合")

        // ⑤ 反例: `handled` disposition —— 引擎说"这一回合根本没有 run"
        //    ⚠️ 这条是**回归哨**: 判据一旦被挂到 `settleTurn` 里（而不是只挂 agent_settled）,
        //    这里立刻变红 —— 那会把"扩展就地吃掉了输入"误报成引擎出错。
        let p6 = PiRpcTransport()
        let s6 = Sink()
        p6.delegate = s6
        p6.handleRPCLine(#"{"type":"agent_start"}"#)
        p6.handleRPCLine(#"{"type":"response","command":"prompt","success":true,"data":{"disposition":"handled"}}"#)
        check(ended(s6) == 1, "T-EMPTYTURN handled: 仍按既有语义主动落定")
        check(emptyTurns(s6) == 0, "T-EMPTYTURN handled: 不报空回合 (那一路本来就没有 run)")

        // ⑥ 模型名缺省: 没下发过模型 ⇒ 事件照发, model 为 nil (文案改走"没有名字可点"那条)
        let p7 = PiRpcTransport()
        let s7 = Sink()
        p7.delegate = s7
        p7.handleRPCLine(#"{"type":"agent_start"}"#)
        p7.handleRPCLine(#"{"type":"agent_settled"}"#)
        check(emptyTurns(s7) == 1 && emptyTurnModel(s7) == nil,
              "T-EMPTYTURN 没下发过模型 ⇒ 仍报空回合, 但 model = nil (不编一个假名字)")

        // ⑦ Store 侧: 事件必须变成**一条落库的、上屏的**记录 —— 判据本身没人看等于没修。
        //    ⚠️ 这里走 `transport(_:didEmit:)` 直接投喂, **不** beginTurn: 注入实例在冒烟里
        //    会真的去 `ensureProcessForCwd()`（这台机器上真装着 pi），不能为了测试拉起真引擎。
        //    后台会话（非选中）那条分支是同两行容器写入（与 `.contextCompacted` 逐字同形），
        //    这里只钉选中的那条路 —— **已知的门禁缺口**, 不假装盖住了。
        let dir = fixtureDir("emptyturn")
        let mock = MockTransport()
        let store = ChatStore(transport: mock, dbPath: dir + "/e.db",
                              managedExtensionsDir: dir + "/ext")
        store.newConversation()
        guard let sid = store.selectedConversationId else {
            check(false, "T-EMPTYTURN 前置: 会话已建"); report()
        }
        check(store.messages.isEmpty, "T-EMPTYTURN 前置: 新会话无消息")

        store.transport(mock, didEmit: .emptyTurn(model: "minimax/MiniMax-M3.1-Flash-Preview"))
        let shown = store.messages.last
        check(shown?.role == .system,
              "T-EMPTYTURN 上屏: 落进消息流且 role = system (不冒充模型说的话)")
        var shownText = ""
        if case .text(let s) = shown?.content ?? .text("") { shownText = s }
        check(shownText.contains("空回合") && shownText.contains("minimax/MiniMax-M3.1-Flash-Preview"),
              "T-EMPTYTURN 上屏文案点名模型 (实测 [\(shownText)])")
        let replayed = store.persistence?.replayMessagesInBackground(sessionId: sid) ?? []
        check(replayed.contains { m in
            if case .text(let s) = m.content { return s == shownText }
            return false
        }, "T-EMPTYTURN 落库: 重启重放能重建这条事实 (实测 \(replayed.count) 条)")

        // 没模型名时走另一条文案 —— 不许把 "nil" 拼进用户看得见的那句话
        store.transport(mock, didEmit: .emptyTurn(model: nil))
        var fallbackText = ""
        if case .text(let s) = store.messages.last?.content ?? .text("") { fallbackText = s }
        check(fallbackText.contains("空回合") && !fallbackText.contains("nil")
                && fallbackText != shownText,
              "T-EMPTYTURN 无模型名的文案走另一条 (实测 [\(fallbackText)])")
    }
}
