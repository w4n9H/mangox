//
//  CaseDialogueTurn —— P19.2 S12: 对话轮的**一支笔**、**围栏外弹卡**、**可选的提议块**
//
//  为什么这条要单独立（与 `CaseWatchChat` 分工）:
//    `CaseWatchChat` 管的是「对话轮带哪套上下文」（目标 / 还开着的结论 / 只读面）。
//    这一条管的是 S12 新加的三件事，每一件都有一个"看起来对、其实没有"的写法:
//      ① **模式** —— 对话轮与巡检轮工具面**完全相同**（都是那支笔），差别只在围栏外怎么办。
//         写成"两种模式都拒"或"两种都放"都能让工具面断言全绿。
//      ② **提议块** —— 从聊天正文里捞一段结构化结论。捞错的表现是"每句闲聊都变成一条待办"，
//         漏捞的表现是"它说提了，收件箱里没有"，两种都零红灯。
//      ③ **留痕（D3）** —— 助理删了之后那场会话静默降级。这件事只有在删除那一刻说得清。
//
//  反例口径（2026-11-17 **实测**，四条一起下 ⇒ **4 红**）:
//    · `ledgerDenyReason` 去掉 `mode == .deny` 那半个判断（一律按拒判）⇒ ①×2 红
//      （对话轮写项目文件直接拒，人连按的机会都没有）；
//    · `proposalBlock` 只认 `【提议】` 一种块头 ⇒ ②红（`提议：` 那种写法漏捞）；
//    · 删掉 `deleteScheduled` 里那句留痕 ⇒ ④红。
//  ⚠️ 第三条反例（"整篇喂给正文解析"）**必须另写一次**: 保留 `guard let block` 只把
//     `parse(block)` 换成 `parse(text)` 时它**不红** —— 没有块的那一轮被 guard 提前 return 了，
//     靶子根本没被打到。真正的写法是**去掉块抽取、直接 `parse(text)`** ⇒ 单独下 **1 红**
//     （正是 ③「没有提议块 ⇒ 不落库」那格）。⇒ 反例写成"改哪一行"之前，先确认那一行真的被执行。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseDialogueTurn() async {
        let dir = fixtureDir("p19dialogue")
        let ledger = dir + "/proj/.mangox/assistant/LEDGER.md"

        // ══ ① 围栏模式：同一个输入，deny 拒 / ask 不拒 ═══════════════════════
        // 这一对必须**成对**存在: 只判「ask 返回 nil」的话，一个恒返回 nil 的实现也能全绿。
        let deniedForPatrol = PiRpcTransport.ledgerDenyReason(
            tool: "write", target: "/tmp/x.md", ledgerPath: ledger, cwd: dir, mode: .deny)
        check(deniedForPatrol?.hasPrefix(LedgerFence.denyPrefix) == true,
              "T-DIALOGUE ①围栏外写别处: 巡检轮（deny）⇒ 拒（\(deniedForPatrol ?? "nil")）")
        let askedInDialogue = PiRpcTransport.ledgerDenyReason(
            tool: "write", target: "/tmp/x.md", ledgerPath: ledger, cwd: dir, mode: .ask)
        check(askedInDialogue == nil,
              "T-DIALOGUE ①同一个输入在对话轮（ask）⇒ **不拒**，交给后面的弹卡（人在场，拒等于替人做决定）")
        // 写账本两种模式都放行 —— ask 不改变「账本本身」的结论，只改「账本之外」的后果
        check(PiRpcTransport.ledgerDenyReason(tool: "write", target: ledger,
                                              ledgerPath: ledger, cwd: dir, mode: .ask) == nil
              && PiRpcTransport.ledgerDenyReason(tool: "write", target: ledger,
                                                 ledgerPath: ledger, cwd: dir, mode: .deny) == nil,
              "T-DIALOGUE ①写账本在两种模式下都放行（模式只改「围栏外」的后果）")
        // bash 在 ask 下也不拒（它在对话轮里本来就该走弹卡），但巡检轮仍然拒
        check(PiRpcTransport.ledgerDenyReason(tool: "bash", target: "echo hi > " + ledger,
                                              ledgerPath: ledger, cwd: dir, mode: .ask) == nil,
              "T-DIALOGUE ①bash 在对话轮也交给弹卡（它要写哪判不了 ⇒ 问人）")

        // ══ ② 提议块抽取（纯函数） ═════════════════════════════════════════
        let withBlock = """
        我看了一下，CI 还是红的，应该是时区。
        【提议】
        结论：CI 失败与时区写死有关
        证据：ci/build.sh:42
        方案：1. 改成 UTC
        """
        let block = WatchFindingService.proposalBlock(in: withBlock) ?? ""
        check(block.contains("结论：CI 失败与时区写死有关"),
              "T-DIALOGUE ②末尾的【提议】块被取出（含结论行）")
        check(!block.contains("我看了一下"),
              "T-DIALOGUE ②正文**不进**块（否则闲聊里那句「结论是……」会被当成新 finding）")
        check(WatchFindingService.proposalBlock(in: "CI 还是红的，我再看看。") == nil,
              "T-DIALOGUE ②没有块 ⇒ nil（绝大多数轮次如此，不该每轮都往收件箱塞待办）")
        check(WatchFindingService.proposalBlock(in: "提议：结论：换个思路\n证据：x.swift:1")?
                .hasPrefix("结论：") == true,
              "T-DIALOGUE ②`提议：` 那种块头也认（模型对全角括号的服从度没到只用一种）")
        check(WatchFindingService.proposalBlock(in: "【提议】结论：自带内容")?
                .hasPrefix("结论：") == true,
              "T-DIALOGUE ②块头那一行自带内容也不丢（`【提议】结论：…` 这种写法）")

        // 编造的观察编号: 对话轮**没有采集轮次** ⇒ 任何 `[n]` 都只能是被编的
        let forged = WatchFindingService.parse("""
        结论：CI 一直红
        证据：日志第 3 条 [3]
        方案：无
        """)
        let fakeTask = ScheduledTask(id: UUID(), name: "x", prompt: "p", cron: "0 0 1 1 *",
                                     projectId: UUID())
        let forgedPlan = WatchFindingService.plan(report: forged, task: fakeTask, sessionId: UUID(),
                                                  sourceId: fakeTask.projectId,
                                                  allowedExternalIds: [],
                                                  existing: [], lastNotifyAt: nil, now: Date())
        check(forgedPlan.finding == nil && forgedPlan.summary.contains("拒收"),
              "T-DIALOGUE ②对话轮里 `[3]` 这种引用一律拒收（没有采集轮次，写编号就是编造）")

        // ══ ③ 端到端：一轮对话真的落一条 finding，第二遍去重，没块就不落 ══════
        let projDir = dir + "/proj"
        try? FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        let mock = MockTransport()
        mock.scriptedReply = { _ in "收到。" }
        let store = ChatStore(transport: mock, dbPath: dir + "/p19dialogue.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: projDir, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-DIALOGUE ③前置: 助理任务已建"); return
        }
        store.runScheduledFire(store.scheduledTasks[ai])
        guard let logId = store.scheduledTasks[ai].logSessionId else {
            check(false, "T-DIALOGUE ③前置: 日志会话已绑"); return
        }
        _ = await waitUntil { store.runningTurns.isEmpty }   // 巡检轮先落定，否则下一轮认领不上

        func say(_ text: String) async {
            mock.scriptedReply = { _ in text }
            store.beginTurn(sid: logId, prompt: "怎么办？", ephemeral: false,
                            cwd: projDir, unattended: false)
            _ = await waitUntil { store.runningTurns.isEmpty }
            store.reloadFindings()
        }

        await say(withBlock)
        check(store.findings.contains { $0.title == "CI 失败与时区写死有关" },
              "T-DIALOGUE ③对话轮的提议**真的落库**了（收尾钩子两处都挂了）")
        check(store.findings.last?.sourceId == projId,
              "T-DIALOGUE ③来源 = 任务的项目（与巡检轮「项目隐式来源」同一条口径，实际 "
              + "\(store.findings.last?.sourceId.uuidString.prefix(8) ?? "nil")）")
        let countAfterFirst = store.findings.count

        await say(withBlock)
        check(store.findings.count == countAfterFirst,
              "T-DIALOGUE ③同一件事再说一遍**不重复落库**（指纹去重沿用 `WatchFindingService.plan`）")

        // ⚠️ 这一轮的**正文故意以「结论：」开头**（真实聊天里很常见）——
        // 它是反例③的靶子: 把整篇塞进正文解析的实现，会把这句闲聊落成一条 finding。
        await say("结论：这件事不值得提单。\n我先盯着，有事再喊你。")
        check(store.findings.count == countAfterFirst,
              "T-DIALOGUE ③没有提议块 ⇒ **不落库**（正文里那句「结论：」不算提案）")

        // ══ ④ D3：助理被删 ⇒ 会话里留一行痕，且反查真的失配 ═══════════════
        store.scheduler.deleteScheduled(id: store.scheduledTasks[ai].id)
        check(store.scheduler.assistantChatTurn(for: logId) == nil,
              "T-DIALOGUE ④删掉之后反查**真的失配**（这是 D3 的前提，不是 bug）")
        let tail = store.replayMessages(for: logId).last { msg in
            if msg.role != .user { return false }
            if case .text = msg.content { return true }
            return false
        }.flatMap { msg -> String? in
            if case .text(let s) = msg.content { return s }
            return nil
        } ?? ""
        check(tail.contains("已删除") && tail.contains("普通会话"),
              "T-DIALOGUE ④且**在会话里留了一行痕**（不静默降级；实际「\(tail.suffix(60))」）")

        // ══ ⑤ per-turn 清回：普通会话不能继承对话轮的笔 ═══════════════════════
        store.beginTurn(sid: UUID(), prompt: "你好", ephemeral: false, cwd: nil, unattended: false)
        check(mock.lastLedgerFencePath == nil && mock.lastLedgerFenceMode == .deny,
              "T-DIALOGUE ⑤普通会话把落点与模式**都清回**（谈成 `if let` 的话这里会继承上一轮）")
    }
}
