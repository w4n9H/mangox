//
//  CasePatrolWrite —— P19.2 S11: 巡检轮的**那一支笔**（工具面 / 围栏位置 / App 退役写盘）
//
//  这是全轮唯一真正让系统变危险的一步。风险不在"多给了 write"，而在**给错地方**：
//    · 工具面多给 `bash` ⇒ 围栏看不见它写哪；
//    · 围栏挪到 `approvalMode.judgesByRisk` 之后 ⇒ 巡检轮恒 unattended ⇒ 那一档直接 Allow
//      ⇒ 一条能往任意路径写、零审批、无人在场的后台回路；
//    · 围栏挪到 `toolCards` 守卫之后 ⇒ 没有卡就 Allow，而无人值守时「没有卡」是常态；
//    · App 与模型**同时**写账本 ⇒ 两份真源，模型刚写的被"回复里复述的那段"覆盖
//      （表现是"账本里的归档总比它说过的少一条"，零红灯）。
//
//  四层判据：
//    ① **工具面**：`patrolToolNames` = 只读五件 + `write`，多一个都不行；`readOnlyToolNames`
//       一个字没动（那是分析段"没有笔"的判据）。
//    ② **决策口**：`ledgerDenyReason` —— 写账本放行、写别处拒、没账本就不管。
//    ③ **位置**：源序断言。行为测试看不见"函数被挪到哪"，而挪一步就是上面那条回路。
//    ④ **退役**：一轮真 fire 之后账本文件**不存在**，且同一份回复里解析器仍能取到
//       「工作日志」段 —— 两件事同时成立才说明"是 App 不写了"，不是"回合没跑"。
//
//  反例（2026-11-17 **实测**，四处一起下 ⇒ **10 红**）：
//    · `patrolToolNames` 加 `bash` ⇒ ①×2（逐字对拍 + 只多一个）；
//    · `readOnlyToolNames` 顺手加 `write` ⇒ T-WATCHFACE ①② + ③×2（分析段也拿到了笔）；
//    · 围栏块挪到 `judgesByRisk` 之后 ⇒ ⑤×2（位置）；
//    · 恢复 `saveHandoff(for: task, content: h)` ⇒ ⑦（账本被写了）。
//  ⚠️ 记两个「没红」：②不含 `edit` 那格（反例没加 edit，本来就不该红）与 ④决策口
//     四格（围栏逻辑一个字没动）—— 这六格在这批反例里**不承担认领**，别把它们当证据。
//  ⚠️ 位置那两格**必须单独拨一次**才算验过: 四处一起下时，⑤ 与别的红同时出现，
//     看不出"只挪位置会不会红"。实测单独拨 ⇒ **2 红，正是 ⑤ 两格**。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func casePatrolWrite() async {
        let dir = fixtureDir("p19patrolwrite")

        // ══ ① 工具面 ═══════════════════════════════════════════════════
        let patrol = PiRpcTransport.analysisFace(webSearchPath: nil, canWriteLedger: true)
        check(PiRpcTransport.toolArguments(for: patrol)
              == ["--tools", "read,grep,find,ls,bocha_web_search,write"],
              "T-PATROLWRITE ①巡检轮工具面逐字对拍（只读五件 + write）"
              + " | 实际 \(PiRpcTransport.toolArguments(for: patrol))")
        check(AgentMode.patrolToolNames == AgentMode.readOnlyToolNames + ["write"],
              "T-PATROLWRITE ①patrolToolNames = readOnlyToolNames + [write]（只多一个）")
        check(!patrol.toolNames.contains("bash"),
              "T-PATROLWRITE ②不含 bash（它要写哪，围栏看不见 —— 一个 `echo >` 就绕过所有路径判据）")
        check(!patrol.toolNames.contains("edit"),
              "T-PATROLWRITE ②不含 edit（账本是整篇覆盖语义；多一条「只改某几行」的路没有判据能证）")
        // 回归: 分析段（没有账本）一个字都不能多 —— 这是 S1 的"没有笔"那条不变量
        let readonly = PiRpcTransport.analysisFace(webSearchPath: nil)
        check(readonly.toolNames == AgentMode.readOnlyToolNames
              && !readonly.toolNames.contains("write"),
              "T-PATROLWRITE ③不带账本的分析段仍是纯只读（默认 false ⇒ 老行为）")
        check(AgentMode.readOnlyToolNames == ["read", "grep", "find", "ls", "bocha_web_search"],
              "T-PATROLWRITE ③readOnlyToolNames 一个字没动（它守着「分析段没有笔」）")
        // 四个恒假项在写面同样恒假 —— 有笔不等于能动手
        check(!patrol.startsComputer && !patrol.injectsKnowledge && !patrol.injectsSOP,
              "T-PATROLWRITE ③有笔也不许起 helper / 不注知识 / 不注 SOP")

        // ══ ② 决策口 ═══════════════════════════════════════════════════
        let ledger = dir + "/proj/.mangox/assistant/ABC.md"
        check(PiRpcTransport.ledgerDenyReason(tool: "write", target: ledger,
                                              ledgerPath: ledger, cwd: dir) == nil,
              "T-PATROLWRITE ④写账本 ⇒ 放行（nil = 交给后面的档位判断）")
        let denied = PiRpcTransport.ledgerDenyReason(tool: "write", target: "/tmp/x.md",
                                                     ledgerPath: ledger, cwd: dir)
        check(denied?.hasPrefix(LedgerFence.denyPrefix) == true,
              "T-PATROLWRITE ④写 /tmp/x.md ⇒ 拒（\(denied ?? "nil")）")
        check(PiRpcTransport.ledgerDenyReason(tool: "bash", target: "echo hi > " + ledger,
                                              ledgerPath: ledger, cwd: dir) != nil,
              "T-PATROLWRITE ④bash 想写账本也拒（命令原文判不了路径）")
        check(PiRpcTransport.ledgerDenyReason(tool: "write", target: "/tmp/x.md",
                                              ledgerPath: nil, cwd: dir) == nil,
              "T-PATROLWRITE ④没有账本落点 ⇒ 不管（这一轮不是账本轮，别误伤普通会话）")

        // ══ ③ 位置纪律（源序） ═════════════════════════════════════════
        // 行为测试看不见"这段代码被挪到哪"，而挪一步就是那条无人值守的后台回路。
        // 判据用**源序**而不是行为: 要行为验它，得挂一个真进程跑一轮 RPC，而那种判据
        // 在这个仓里没人会写第二次。
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let srcPath = repo.appendingPathComponent("mangox/Agent/PiRpcTransport.swift").path
        if let src = try? String(contentsOfFile: srcPath, encoding: .utf8) {
            let fence = src.range(of: "if let ledger = ledgerFencePath")
            let card = src.range(of: "guard var card = toolCards[callId]")
            let mode = src.range(of: "guard approvalMode.judgesByRisk")
            check(fence != nil, "T-PATROLWRITE ⑤围栏那一支还在（改名字的话这条红，去更新断言）")
            if let f = fence?.lowerBound, let c = card?.lowerBound, let m = mode?.lowerBound {
                // ⚠️ 两条都必须是 **fence 与别人** 比。写成 `card < mode` 是**恒真**的
                // （那两个 guard 的先后是函数结构的一部分，与围栏在哪无关）——
                // 2026-11-17 实测: 那种写法在"围栏被挪到 judgesByRisk 之后"时照样绿。
                check(f < c,
                      "T-PATROLWRITE ⑤围栏在 **toolCards 守卫之前**（挪到之后 ⇒ 没有卡的 write 直接 Allow，"
                      + "而无人值守时「没有卡」是常态）")
                check(f < m,
                      "T-PATROLWRITE ⑤围栏在 **judgesByRisk 之前**（巡检轮恒 unattended ⇒ 那一档直接 Allow "
                      + "⇒ 一条能往任意路径写、零审批的后台回路）")
            } else {
                check(false, "T-PATROLWRITE ⑤源序锚点没找全（card=\(card != nil) mode=\(mode != nil)）")
            }
        } else {
            check(false, "T-PATROLWRITE ⑤读不到 PiRpcTransport.swift（\(srcPath)）")
        }

        // ══ ④ 退役 App 写盘 ═══════════════════════════════════════════
        let projDir = dir + "/repo"
        try? FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        let mock = MockTransport()
        // 回复里**故意留着**「工作日志」段: 老代码会把它写盘, 新代码必须无视它。
        let reply = """
        结论：没达成，但有一处变化
        证据：CI 第 3 次失败（本地日志里那三行）
        方案：无
        工作日志：这段不该被 App 写进账本
        """
        mock.scriptedReply = { _ in reply }
        let store = ChatStore(transport: mock, dbPath: dir + "/p19pw.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: projDir, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let idx = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-PATROLWRITE ⑥前置: 助理任务已建"); return
        }
        let task = store.scheduledTasks[idx]
        let ledgerPath = store.scheduler.handoffPath(for: task)
        check(ledgerPath.contains("/.mangox/assistant/"),
              "T-PATROLWRITE ⑥账本落点走 S9 的新目录（\(ledgerPath)）")

        store.runScheduledFire(task)
        // ⑥ 下发: 巡检轮的 beginTurn 必须带上账本落点（否则 tools 面与围栏都收不到）
        check(mock.lastLedgerFencePath == ledgerPath,
              "T-PATROLWRITE ⑥巡检轮把账本落点下发给 transport"
              + "（实际 \(mock.lastLedgerFencePath ?? "nil")）")
        // P19.2 S12: 落点与模式是**一次赋值**。巡检轮的配对格是 `deny`（对话轮才是 `ask`）——
        // 两格都存在才能证明"模式真的分开了", 只判对话轮是 ask 的话，一个恒 ask 的实现也全绿。
        check(mock.lastLedgerFenceMode == .deny,
              "T-PATROLWRITE ⑥巡检轮的围栏模式是 deny（无人可问 ⇒ 围栏外直接拒）")
        check(mock.lastSentPrompt != nil, "T-PATROLWRITE ⑥回合真的开了（下面那几格才不是空转）")

        // ⚠️ 不能自己调 `finishWatchFireIfNeeded`: 它一进就 `removeValue(forKey: sid)`,
        // 而 mock 是**逐字流式**回放（每字 18ms）—— 抢在落定之前调，会把那一轮的上下文吃掉，
        // 真正的落定那次就再也拿不到了（结论永远不落库，而"账本不存在"看起来像通过）。
        // 所以等落定，让 ChatStore 自己调。
        let settled = await waitUntil { store.runningTurns.isEmpty }
        check(settled, "T-PATROLWRITE ⑥回合真的落定（不等它的话下面几格全是空转）")
        // ⑦ **先证明收尾真的跑过**，再断言"账本没被写" —— 否则「文件不存在」可能只是没跑。
        store.reloadFindings()
        let happened = !store.findings.isEmpty
        check(happened, "T-PATROLWRITE ⑦夹具: 收尾真的落了结论（下面那格才不是空转）")
        check(!FileManager.default.fileExists(atPath: ledgerPath),
              "T-PATROLWRITE ⑦App **不再写账本**（回复里那段「工作日志」被有意忽略）")
        // ⑧ 但解析器**还认得**那一段 —— 证明"没写"不是"没解析出来"
        check(WatchFindingService.parse(reply).handoff == "这段不该被 App 写进账本",
              "T-PATROLWRITE ⑧解析器仍能取到「工作日志」段（忽略 ≠ 认不出；认不出的话上一格是假绿）")
    }
}
