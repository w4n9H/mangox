//
//  CaseAssistantLifecycle —— P19.2 S15 前置: 助理与它的会话 / 账本**成对**
//
//  这条判据守的是一个**中间态的不存在**: 助理还在、会话没了（或反过来）。
//  那种状态不会当场报错 —— 它表现成"它忽然不认得我了"，而界面上一个字都不变。
//
//  四组（每组一个独立的失败模式，不是同一件事的四种写法）:
//    甲 **删助理 ⇒ 六样一起走**（任务行 / 日志会话 / 账本 / jsonl / 库里的三张表 / 快照目录）。
//       账本要**两份都查**：新位置与 S9 之前的旧位置 —— `readHandoff` 会回落，只删新的等于没删。
//       而且 `deleteSessions: false` 也照样删（那个参数对助理失效）。
//       ⚠️ 后三样是 2026-11-18 补的（boss 报"删助理时 jsonl 不会被删"）：它们的形状
//       **全都不报错** —— 会话行没了文件还躺着（反查不到 = 永久孤儿）、悬空 `task_id`
//       只在收件箱里显示成「未知任务」、`undo/` 目录成了一包没人能回滚的 tar。
//    乙 **删会话 ⇒ 只清指针**：`logSessionId` 变 nil（且**落库**）、助理还在、
//       账本还在。理由: 账本是文件，丢的只是对话历史 —— 杀掉一条在看守的线
//       来防一次失忆，惩罚远大于伤害。
//    丙 **Cron 一个字不动**：删 Cron 保留会话时，会话与交接文件都在。
//    丁 **dream 不可删**：`canDelete` 挡在能力层，不是视图层。
//
//  反例（2026-11-17 **实测**，四次分别下；红点逐条认领）:
//    · `deleteScheduled` 里 `paired ||` 去掉（回到"跟着参数走"）⇒ **2 红**：
//      T-LIFE 甲② + T-DIALOGUE ④（会话留着 ⇒ 中间态回来了）；
//    · `removeAssistantLedger` 只删新位置 ⇒ **1 红**：甲④（旧账本被回落"复活"）；
//    · `deleteConversation` 里去掉 `detachAssistantSession` 调用 ⇒ **2 红**：乙① + 乙①b；
//    · `detachAssistantSession` 只改内存不落库 ⇒ **1 红**：乙①b。
//      ⚠️ 后两条**必须分别下**：只去掉调用会同时盖住"落库"那一格，看不出后者是不是活的。
//
//  反例（2026-11-18 **实测**，删除半径那三样各下一次，逐个认领）:
//    · `deleteConversation(sid)` 去掉 `deleteTranscript: true` ⇒ **1 红**：甲⑤；
//    · DB 层三条 DELETE 全去掉 ⇒ **2 红**：甲⑥ + 甲⑥b；
//    · **只**去掉 token 那条 DELETE ⇒ **1 红**：甲⑥b（⇒ 甲⑥b 是独立的活门，
//      不是甲⑥ 的复述 —— 这正是把它单列的原因）；
//    · 快照目录那一行改成 `_ = d`（读了不删，避开未使用告警）⇒ **1 红**：甲⑦。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseAssistantLifecycle() async {
        let dir = fixtureDir("p19life")
        let fm = FileManager.default

        // ══ 甲 删助理 ⇒ 任务行 / 会话 / 账本两份 一起走 ═══════════════════════
        let mock = MockTransport()
        mock.scriptedReply = { _ in "NO_FINDING" }
        let store = ChatStore(transport: mock, dbPath: dir + "/life.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let projId = UUID()
        let projPath = dir + "/repo"
        try? fm.createDirectory(atPath: projPath, withIntermediateDirectories: true)
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: projPath, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-LIFE 甲前置: 助理已建"); return
        }
        // 跑一轮把日志会话建起来（顺带证明"会话是 fire 建的，不是界面建的"）
        store.runScheduledFire(store.scheduledTasks[ai])
        _ = await waitUntil { store.runningTurns.isEmpty }
        let aTask = store.scheduledTasks[ai]
        guard let aSid = aTask.logSessionId else {
            check(false, "T-LIFE 甲前置: 日志会话已绑"); return
        }
        // 账本两份都写出来 —— 旧的这份是 S9 之前的位置，`readHandoff` 会回落读它
        let newLedger = store.scheduler.handoffPath(for: aTask)
        let oldLedger = projPath + "/.mangox/tasks/\(aTask.id.uuidString).md"
        for p in [newLedger, oldLedger] {
            try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? "## 目标\n保证 CI 是绿的".write(toFile: p, atomically: true, encoding: .utf8)
        }
        check(fm.fileExists(atPath: newLedger) && fm.fileExists(atPath: oldLedger),
              "T-LIFE 甲前置: 账本新旧两份都在（旧的那份才是回落的靶子）")

        // ── 甲⑤~⑦ 的**前提**：删除半径的后半（jsonl / 库里的三张表 / 快照目录） ──────
        // 这三样在旧的删除路径上**一个都没人管**（2026-11-18 实测）：会话行没了但
        // `pi-sessions/<sid>.jsonl` 还躺着（这台机器攒了 3 个，谁也认领不到）、
        // findings / actions / token 日账留下悬空 `task_id`（收件箱显示「未知任务」）、
        // `undo/<findingId>/` 成了永远没人能回滚的一包 tar。
        //
        // ⚠️ **先造后删**：只断言"删完没了"的话，"前提根本没造出来"照样全绿。
        // ⚠️ transcript 根与快照根都是**进程级**重定向（守卫 25/27）—— 不重定向就是拿
        //   用户真实的 `~/.mangox/pi-sessions`、`~/.mangox/undo` 当夹具。
        let piRoot = dir + "/pi-sessions"
        try? fm.createDirectory(atPath: piRoot, withIntermediateDirectories: true)
        let piRootBackup = PiRpcTransport.sessionDirectoryOverride
        PiRpcTransport.sessionDirectoryOverride = piRoot
        let jsonlPath = PiRpcTransport.sessionFilePath(for: aSid)
        try? "{\"role\":\"user\"}\n".write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let undoRoot = dir + "/undo"
        WatchExecService.undoRootOverride = undoRoot
        let findingId = UUID()
        let undoDir = undoRoot + "/" + findingId.uuidString
        try? fm.createDirectory(atPath: undoDir, withIntermediateDirectories: true)
        try? store.persistence?.upsertFinding(AgentFinding(
            id: findingId, taskId: aTask.id, sourceId: UUID(), sessionId: aSid,
            title: "CI 红了", body: "第 12 步失败",
            plan: [WatchPlanStep(n: 1, text: "重跑")],
            fingerprint: "fp-\(findingId.uuidString)",
            undoPath: undoDir, createdAt: .now))
        try? store.persistence?.upsertFindingAction(FindingAction(
            findingId: findingId, step: 1, kind: "bash", target: nil,
            result: "allowed", output: "ok", at: .now))
        let tokenDay = "2026-11-18"
        try? store.persistence?.addTokenUsage(taskId: aTask.id, day: tokenDay, tokens: 42)
        let seedsOK = fm.fileExists(atPath: jsonlPath)
            && fm.fileExists(atPath: undoDir)
            && ((try? store.persistence?.loadFindings().count) ?? 0) == 1
            && ((try? store.persistence?.loadFindingActions().count) ?? 0) == 1
            && ((try? store.persistence?.tokenUsage(taskId: aTask.id, day: tokenDay)) ?? 0) == 42
        check(seedsOK,
              "T-LIFE 甲⑤~⑦ 前置: jsonl / findings+actions / token 日账 / undo 目录 四样都造出来了")

        // **传 false** —— 助理这个参数应当被忽略
        store.deleteScheduled(id: aTask.id, deleteSessions: false)
        check(!store.scheduledTasks.contains { $0.id == aTask.id },
              "T-LIFE 甲① 任务行没了")
        check(!store.allConversations.contains { $0.id == aSid },
              "T-LIFE 甲② 日志会话跟着走了（传 deleteSessions: false 也照样走 —— 那个参数对助理失效）")
        check(!fm.fileExists(atPath: newLedger),
              "T-LIFE 甲③ 账本文件（新位置）删了")
        check(!fm.fileExists(atPath: oldLedger),
              "T-LIFE 甲④ 账本文件（**旧位置**）也删了 —— 只删新位置的话 `readHandoff` 的回落会把旧账本复活")
        check(!fm.fileExists(atPath: jsonlPath),
              "T-LIFE 甲⑤ 会话的 jsonl 跟着删了 —— 漏这一格的形状是「会话行没了、文件还躺着」，"
              + "反查不到会话行 = 永久孤儿（实测这台机器攒了 3 个）")
        let fLeft = ((try? store.persistence?.loadFindings()) ?? []).filter { $0.taskId == aTask.id }
        let aLeft = ((try? store.persistence?.loadFindingActions()) ?? [])
            .filter { $0.findingId == findingId }
        check(fLeft.isEmpty && aLeft.isEmpty,
              "T-LIFE 甲⑥ 结论与执行落痕（findings / finding_actions）跟着删了 —— 悬空 task_id 不报错，"
              + "只在收件箱里显示成「未知任务」")
        // 单列一格：token 日账是**另一张表**，与 findings 不同源（前者记花销、后者记结论）
        // ⇒ 合并断言会让"少认一张表"这半个 bug 藏在另一格的红里。
        check(((try? store.persistence?.tokenUsage(taskId: aTask.id, day: tokenDay)) ?? -1) == 0,
              "T-LIFE 甲⑥b token 日账跟着删了（每天一张行；少认一列 = 库里留垃圾，"
              + "而它只在有人统计「这个助理花了多少」时给出假数）")
        check(!fm.fileExists(atPath: undoDir),
              "T-LIFE 甲⑦ 执行快照目录删了 —— 那条 finding 刚被删 ⇒ 再也没有「回滚」这个动作，"
              + "留着只是一包没人认领的 tar")
        PiRpcTransport.sessionDirectoryOverride = piRootBackup
        WatchExecService.undoRootOverride = nil

        // ══ 乙 删会话 ⇒ 只清指针，不删助理 ═══════════════════════════════════
        let mock2 = MockTransport()
        mock2.scriptedReply = { _ in "NO_FINDING" }
        let store2 = ChatStore(transport: mock2, dbPath: dir + "/life2.db",
                               managedExtensionsDir: dir + "/ext")
        store2.scheduler.stopScheduler()
        store2.projects.append(ProjectGroup(id: projId, title: "看守盘", path: projPath, items: []))
        store2.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                            projectId: projId, kind: .assistant)
        guard let bi = store2.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-LIFE 乙前置: 助理已建"); return
        }
        store2.runScheduledFire(store2.scheduledTasks[bi])
        _ = await waitUntil { store2.runningTurns.isEmpty }
        let bTask = store2.scheduledTasks[bi]
        guard let bSid = bTask.logSessionId else {
            check(false, "T-LIFE 乙前置: 日志会话已绑"); return
        }
        let bLedger = store2.scheduler.handoffPath(for: bTask)
        try? fm.createDirectory(atPath: (bLedger as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? "## 目标\n还没做完的事".write(toFile: bLedger, atomically: true, encoding: .utf8)

        store2.deleteConversation(bSid)
        check(store2.scheduler.scheduledTasks[bi].logSessionId == nil,
              "T-LIFE 乙① 删会话 ⇒ `logSessionId` 清成 nil（不是留一个指向已删会话的**悬空指针**）")
        // **落库**才对：只改内存的话，重启 App 那一列又指回去 —— 而反查在重启后照样失配，
        // 表现与"没清"一模一样（多一次"它为什么不认得我"的排查）。
        let persisted = (try? store2.persistence?.loadScheduled()) ?? []
        check(persisted.first { $0.id == bTask.id }?.logSessionId == nil,
              "T-LIFE 乙①b 清指针**落了库**（只改内存 ⇒ 重启后又指回一个已不存在的会话）")
        check(store2.scheduler.scheduledTasks[bi].isAssistant,
              "T-LIFE 乙② 助理本身还在（杀一条在跑的巡检线来防一次失忆，惩罚远大于伤害）")
        check(fm.fileExists(atPath: bLedger),
              "T-LIFE 乙③ 账本还在 —— 账本是文件，删会话丢的只是对话历史")

        // ══ 丙 Cron 一个字不动 ═════════════════════════════════════════════
        let mock3 = MockTransport()
        mock3.scriptedReply = { _ in "done" }
        let store3 = ChatStore(transport: mock3, dbPath: dir + "/life3.db",
                               managedExtensionsDir: dir + "/ext")
        store3.scheduler.stopScheduler()
        store3.addScheduled(name: "旧 cron", prompt: "每日巡检", cron: "0 9 * * *", projectId: nil)
        guard let ci = store3.scheduledTasks.firstIndex(where: { $0.name == "旧 cron" }) else {
            check(false, "T-LIFE 丙前置: Cron 已建"); return
        }
        store3.runScheduledFire(store3.scheduledTasks[ci])
        _ = await waitUntil { store3.runningTurns.isEmpty }
        let cTask = store3.scheduledTasks[ci]
        guard let cSid = cTask.logSessionId else {
            check(false, "T-LIFE 丙前置: Cron 日志会话已绑"); return
        }
        let cHandoff = store3.scheduler.handoffPath(for: cTask)
        try? fm.createDirectory(atPath: (cHandoff as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? "cron 的交接文件".write(toFile: cHandoff, atomically: true, encoding: .utf8)
        store3.deleteScheduled(id: cTask.id, deleteSessions: false)
        check(!store3.scheduledTasks.contains { $0.id == cTask.id },
              "T-LIFE 丙① 就 Cron 而言，删任务照旧（这一档零改动）")
        check(store3.allConversations.contains { $0.id == cSid }
              && fm.fileExists(atPath: cHandoff),
              "T-LIFE 丙② Cron 默认**保留会话与交接文件**（成对删除只对助理生效）")

        // ══ 丁 dream 不可删 ═════════════════════════════════════════════════
        let dreamBefore = store3.scheduler.scheduledTasks.count
        store3.deleteScheduled(id: SchedulerService.dreamTaskID)
        check(store3.scheduler.scheduledTasks.count == dreamBefore
              && store3.scheduler.scheduledTasks.contains { $0.id == SchedulerService.dreamTaskID },
              "T-LIFE 丁 `canDelete` 挡在**能力层**：dream 删不掉（视图不渲染按钮只是可见性）")

        store.scheduler.stopScheduler()
        store2.scheduler.stopScheduler()
        store3.scheduler.stopScheduler()
    }
}
