//
//  CaseWatchFindings —— P19 助理: 结论解析 / 拒收 / 指纹去重 / 落库
//
//  为什么这些判据非立不可（docs/P19 §04）:
//    ① 输出契约是**自然语言三段**，解析器写错的表现是"结论悄悄没了" —— 而没了不报错；
//    ② "同指纹不重发"是产品与用户之间的**唯一契约**（长程任务天天报同一件事 = 变噪音），
//       而不重发写错的两种方向都不红: 永远发（烦人）与永远不发（哑巴）；
//    ③ 证据里的编号是**可伪造的唯一一面**（source_id 由 App 反推，模型给不了）；
//    ④ 工作日志是 **App 写盘**（2026-11-16 拍板）: 巡检轮没有写工具，让它自己写是做不到的事。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseWatchFindings() async {
        let dir = fixtureDir("p19findings")

        // —— ① 四段齐全的正常回复 ——
        let full = """
        结论：CI 连续三次失败，是 App.swift 里的空集断言挂了。
        影响面：只有 CI, 本地不受影响。
        回滚法：改回上一版即可。
        证据：看到流水线第 3 次失败 [2]；App.swift:42 的断言
        方案：
        1. 改 App.swift 的断言 —— 让空集也算通过
        2. 跑一次 run.sh 确认
        工作日志：
        当前阶段：定位到根因
        已完成：读完流水线日志
        下一步：提交修复
        卡在哪：等授权
        """
        let r = WatchFindingService.parse(full)
        check(r.title == "CI 连续三次失败，是 App.swift 里的空集断言挂了。",
              "T-WATCHFIND ①结论首行做标题（实际「\(r.title)」）")
        check(r.body.contains("影响面") && r.body.contains("回滚法"),
              "T-WATCHFIND ①结论段多行时整段留作正文（首行已做标题，不丢余下）")
        check(r.plan.map(\.n) == [1, 2] && r.plan.first?.text.contains("App.swift") == true,
              "T-WATCHFIND ①方案认编号（实际 \(r.plan.map(\.n))）")
        check(r.handoff?.contains("下一步：提交修复") == true,
              "T-WATCHFIND ①工作日志段独立解出来（它由 App 写盘, 不进 findings）")
        check(!r.isNoFinding && r.parseIssue == nil,
              "T-WATCHFIND ①有结论就不是 NO_FINDING、也没有解析问题")

        // —— ② NO_FINDING 与"解析失败"是两件事 ——
        let noFind = WatchFindingService.parse("NO_FINDING")
        check(noFind.isNoFinding && noFind.title.isEmpty,
              "T-WATCHFIND ②单独一行 NO_FINDING ⇒ 无结论（零通知的那条路）")
        // 正文里提到 NO_FINDING、但真给了结论 ⇒ **不算** NO_FINDING（模型常在解释里提它）
        let explain = WatchFindingService.parse("结论：一切正常。\n本来这一轮可以回 NO_FINDING。")
        check(!explain.isNoFinding && explain.title == "一切正常。",
              "T-WATCHFIND ②有结论段时，正文里提到 NO_FINDING 不算（否则真结论被当成「没事」）")
        let broken = WatchFindingService.parse("我看了看，好像没啥问题。")
        check(broken.parseIssue != nil && !broken.isNoFinding,
              "T-WATCHFIND ②没结论段又没 NO_FINDING ⇒ **解析失败**（不是「没有结论」, 两者对人是两件事）")

        // —— ③ 方案"无" / 空 ——
        check(WatchFindingService.parse("结论：x\n方案：无").plan.isEmpty,
              "T-WATCHFIND ③方案写「无」⇒ 零步骤（不是一步叫「无」）")

        // —— ④ 伪造的观察编号必须拒收 ——
        let allowed: Set<String> = ["1", "2"]
        check(WatchFindingService.forgedCitations("看到 [2] 与 [7]", allowed: allowed) == ["7"],
              "T-WATCHFIND ④本轮没采到 [7] ⇒ 记作伪造引用")
        check(WatchFindingService.forgedCitations("App.swift:42 / [App.swift:42]", allowed: allowed).isEmpty,
              "T-WATCHFIND ④文件:行号不算观察引用（只认纯数字方括号）")
        let task = ScheduledTask(id: UUID(), name: "CI 看守", prompt: "保证 CI 是绿的",
                                 cron: "0 9 * * *", projectId: UUID())
        var forgedReport = r
        forgedReport.evidence = "看到 [9] 说的"
        let forgedPlan = WatchFindingService.plan(report: forgedReport, task: task, sessionId: UUID(),
                                                  sourceId: task.projectId, allowedExternalIds: allowed,
                                                  existing: [], lastNotifyAt: nil, now: Date())
        check(forgedPlan.finding == nil && forgedPlan.summary.contains("拒收"),
              "T-WATCHFIND ④编造证据 ⇒ **整条拒收**（不改写成「部分保留」：半真半假的结论宁可不要）")

        // —— ⑤ 指纹只认结论，不认方案 ——
        let src = task.projectId!
        let fpA = WatchFindingService.fingerprint(taskId: task.id, sourceId: src, title: "CI 挂了")
        let fpB = WatchFindingService.fingerprint(taskId: task.id, sourceId: src, title: "CI   挂了")
        let fpC = WatchFindingService.fingerprint(taskId: task.id, sourceId: src, title: "CI 好了")
        check(fpA == fpB,
              "T-WATCHFIND ⑤同一句话换个空白 ⇒ 同指纹（否则每轮都算「新问题」）")
        check(fpA != fpC, "T-WATCHFIND ⑤结论变了 ⇒ 指纹变")

        // —— ⑥ 同指纹: 方案未变不落库 / 方案变了升级版本但不叫人 ——
        let base = WatchFindingService.plan(report: r, task: task, sessionId: UUID(),
                                            sourceId: src, allowedExternalIds: allowed,
                                            existing: [], lastNotifyAt: nil, now: Date())
        guard let first = base.finding, base.isNew, base.shouldNotify else {
            check(false, "T-WATCHFIND ⑥前置: 首次应当落库并通知"); report()
        }
        let samePlan = WatchFindingService.plan(report: r, task: task, sessionId: UUID(),
                                                sourceId: src, allowedExternalIds: allowed,
                                                existing: [first], lastNotifyAt: nil, now: Date())
        check(samePlan.finding == nil && !samePlan.shouldNotify,
              "T-WATCHFIND ⑥同指纹同方案 ⇒ **不重复落库、不通知**（长程任务天天报同一件事 = 噪音）")

        var revised = r
        revised.plan = [WatchPlanStep(n: 1, text: "换个办法改断言")]
        let upgraded = WatchFindingService.plan(report: revised, task: task, sessionId: UUID(),
                                                sourceId: src, allowedExternalIds: allowed,
                                                existing: [first], lastNotifyAt: nil, now: Date())
        check(upgraded.finding?.planRev == 2 && upgraded.finding?.id == first.id && !upgraded.isNew,
              "T-WATCHFIND ⑥方案变了 ⇒ 更新**同一行**、planRev+1（收件箱里不该堆两行同一件事）")
        check(!upgraded.shouldNotify,
              "T-WATCHFIND ⑥但**不重新叫人**（同指纹不重发: 方案打磨不该变成打扰）")

        // —— ⑦ 冷却: 换个结论也别在 30 分钟内叫人 ——
        var otherReport = r
        otherReport.title = "磁盘只剩 3%"
        let cooling = WatchFindingService.plan(report: otherReport, task: task, sessionId: UUID(),
                                               sourceId: src, allowedExternalIds: allowed,
                                               existing: [first], lastNotifyAt: Date(), now: Date())
        check(cooling.finding != nil && !cooling.shouldNotify,
              "T-WATCHFIND ⑦冷却内**照落库但不通知**（结论不能丢, 只是不吵人）")

        // —— ⑧ 落库往返 ——
        let store = ChatStore(transport: MockTransport(), dbPath: dir + "/p19f.db",
                              managedExtensionsDir: dir + "/ext")
        try? store.persistence?.upsertFinding(first)
        let loaded = (try? store.persistence?.loadFindings()) ?? []
        check(loaded.count == 1 && loaded.first?.fingerprint == first.fingerprint,
              "T-WATCHFIND ⑧落库往返: 指纹在同一条上（实际 \(loaded.count) 条）")
        check(loaded.first?.plan.map(\.n) == [1, 2] && loaded.first?.status == .open,
              "T-WATCHFIND ⑧方案 JSON 与 status 值域往返无损")

        store.reloadFindings()
        check(store.findings.count == 1 && store.findings.filter { $0.status.isInboxVisible }.count == 1,
              "T-WATCHFIND ⑧收件箱数据源 = open 的那条")
        store.setFindingStatus(first.id, status: .dismissed)
        check(store.findings.first?.status == .dismissed
              && store.findings.filter { $0.status.isInboxVisible }.isEmpty,
              "T-WATCHFIND ⑧忽略 ⇒ 状态落库且从收件箱消失（不是删行: 结论本身留着）")
        check(store.findings.first?.decidedAt != nil,
              "T-WATCHFIND ⑧人拍板才写 decided_at（模型自己改状态不算决定）")

        // —— ⑨ 工作日志写盘（App 写，不经模型工具）——
        let logTask = ScheduledTask(id: UUID(), name: "日志盘", prompt: "x", cron: "0 9 * * *",
                                    projectId: nil)
        store.scheduler.scheduledTasks = [logTask]
        let wrote = store.saveHandoff(for: logTask, content: r.handoff ?? "")
        let read = store.readHandoff(for: logTask)
        check(wrote && read?.content.contains("下一步：提交修复") == true,
              "T-WATCHFIND ⑨工作日志由 App 写盘并可读回（巡检轮没有写工具，这条路是唯一落点）")

        // —— ⑩ 超长工作日志: 拒收而不是截断 ——
        // 截断会把「下一步」切掉，留下半句比没有更坏。
        var fat = r
        fat.handoff = String(repeating: "字", count: WatchFindingService.handoffMaxChars + 1)
        let fatPlan = WatchFindingService.plan(report: fat, task: task, sessionId: UUID(),
                                              sourceId: src, allowedExternalIds: allowed,
                                              existing: [], lastNotifyAt: nil, now: Date())
        check(fatPlan.handoff == nil && fatPlan.summary.contains("超过上限"),
              "T-WATCHFIND ⑩超长工作日志 => 不写盘并在日志里说明（截断会切掉「下一步」）")

        store.scheduler.stopScheduler()
    }
}
