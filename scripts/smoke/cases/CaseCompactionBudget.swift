//
//  caseCompactionBudget —— 上下文压缩预算: modelOverrides 优先级
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家 + dir→fixturesRoot 等价替换）。
//  原位替换为 `await caseCompactionBudget()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseCompactionBudget() async {
        // ③ ChatStore 侧: 标记入流 + 落库重放 + 百分比即时改写
        let ctxDir = fixtureDir("ctx")
        let ctxMock = MockTransport()
        let ctxStore = ChatStore(transport: ctxMock, dbPath: ctxDir + "/ctx.db",
                                 managedExtensionsDir: ctxDir + "/ext")
        ctxStore.newConversation()
        guard let ctxSid = ctxStore.selectedConversationId else { check(false, "T-CTX 建会话"); report() }
        // 先来一次完整统计 (窗口已知), 再压缩 —— 顺序反了就测不到 B
        ctxStore.transport(ctxMock, didReportSessionStats: SessionStats(
            contextPercent: 75, contextTokens: 150000, contextWindow: 200000,
            contextReserveTokens: 16384, inputTokens: 1000, outputTokens: 50,
            cacheReadTokens: 0, costUSD: nil))
        ctxStore.transport(ctxMock, didEmit: .contextCompacted(tokensBefore: 150000,
                                                               tokensAfter: 32000,
                                                               reason: "threshold"))
        if let last = ctxStore.messages.last, case .compaction(let b, let a, let r) = last.content {
            check(last.role == .system && b == 150000 && a == 32000 && r == "threshold",
                  "T-CTX 压缩成功 → 消息流里一条 .system 常驻标记 (带 reason)")
        } else {
            check(false, "T-CTX 压缩成功 → 消息流里一条 .system 常驻标记 (带 reason)")
        }
        check(abs((ctxStore.sessionStats?.contextPercent ?? 0) - 16) < 0.001,
              "T-CTX 百分比立刻 = 32000/200000 = 16% (不沿用压缩前的 75%)")
        check(ctxStore.sessionStats?.contextTokens == 32000, "T-CTX contextTokens 同步改写")
        // 落库重放: 重启后这条事实必须还在 (否则 A 只是"当次会话内的安慰")
        let replayed = ctxStore.replayMessages(for: ctxSid)
        check(replayed.contains { m in
            if case .compaction(let b, let a, let r) = m.content {
                return b == 150000 && a == 32000 && r == "threshold"
            }
            return false
        }, "T-CTX 常驻标记落库, 重放后 reason 一并回来")
        // reason → 文案: 三档要分得出来, 不认识的值退回"已压缩"(不许猜成自动)
        check(Copy.compactedMarker(reason: "manual", before: 1, after: 2).contains("手动"),
              "T-CTX reason=manual → 「你手动压缩了上下文」")
        check(Copy.compactedMarker(reason: "overflow", before: 1, after: 2).contains("溢出恢复"),
              "T-CTX reason=overflow → 「接近上限/溢出恢复」两档分开")
        check(Copy.compactedMarker(reason: "some-new-reason", before: 1, after: 2).contains("已压缩"),
              "T-CTX 不认识的 reason → 退回「已压缩」(不猜成自动压缩)")
        // 记忆提炼 / dream 的材料**不许**吃进这条 (它是标记, 不是"谁说了什么")
        let material = KnowledgeStore.sessionMaterial(from: [
            ChatMessage(role: .user, content: .text("人说的话")),
            ChatMessage(role: .system,
                        content: .compaction(tokensBefore: 150000, tokensAfter: 32000,
                                             reason: "threshold")),
        ])
        check(material.count == 1 && !material.joined().contains("压缩"),
              "T-CTX 压缩标记不进 sessionMaterial (不污染记忆提炼/dream)")
    }
}
