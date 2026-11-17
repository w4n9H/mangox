//
//  CaseNag —— P19.2 S14: 「催」（还开着的事过一段时间再提醒一次）
//
//  S14 最容易漏的一条写在正文里: **「催」不能变成第二个 cron** —— 它挂在现有
//  `schedulerTick` 上按条件扫，不另起定时器。这条在判据上的表现是: 催完**不开回合、
//  不推进 `lastRunAt`、不烧 token**（下面 ③ 那三格），而不是"代码里没有 Timer"。
//
//  四层判据：
//    ① **判据表**（纯函数 `WatchNagService.due`）：状态 / 开关 / 上限 / 冷却，一格一条；
//    ② **落库往返**：`nagCount` 与 `lastNaggedAt` 存得进读得出（跨 fire 的"不重复催"靠它）；
//    ③ **端到端**：真扫一次 ⇒ 涨一次、留一行痕、且**没有副作用**；再扫一次 ⇒ 不重复；
//    ④ **snooze 压住它**：不是特殊分支，而是状态机本身（`status != .open` 一律不催）。
//
//  反例（每条都点名它守的是哪一格；红点数是实测，不是推的）：
//    · `due` 去掉 `status == .open` ⇒ **2 红**: ①`snooze` 格 + ①「已忽略 / 已解决」格。
//      ⚠️ ④ **不会**红 —— 那一格 `nagCount` 已到顶，被上限守卫先挡住，与状态机无关
//      （第一版注释写成"① snooze 格 + ④ 红"，实测打脸）。
//    · 冷却锚点只写 `createdAt`（不看 `lastNaggedAt`）⇒ **2 红**: ①「刚催过 5 小时」
//      + ③ 的第二扫。而 ①「21 小时前催过」**仍绿** —— 那一格本来就该是"该催"。
//    · 去掉 `nagCount < limit` ⇒ **2 红**: ①「催满 3 次闭嘴」+ ④。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseNag() async {
        let dir = fixtureDir("p19nag")
        let now = Date()
        var task = ScheduledTask(id: UUID(), name: "CI 看守", prompt: "保证 CI 是绿的",
                                 cron: "0 0 1 1 *", projectId: nil)
        task.kind = .assistant

        func finding(_ status: FindingStatus, nag: Int, last: Date?,
                     createdHoursAgo: Double = 30) -> AgentFinding {
            AgentFinding(id: UUID(), taskId: task.id, sourceId: UUID(), sessionId: UUID(),
                         title: "CI 连续三次失败", body: "…", evidence: nil, plan: [],
                         severity: "action", fingerprint: "fp-\(UUID())", status: status,
                         nagCount: nag, lastNaggedAt: last,
                         createdAt: now.addingTimeInterval(-createdHoursAgo * 3600))
        }

        // ══ ① 判据表 ═══════════════════════════════════════════════════════
        check(WatchNagService.due(finding(.open, nag: 0, last: nil), task: task, now: now),
              "T-NAG ①还开着 + 提出 30h + 一次没催 ⇒ 该催")
        check(!WatchNagService.due(finding(.snooze, nag: 0, last: nil), task: task, now: now),
              "T-NAG ①`snooze` 压住它（压住的不是一条特殊分支，是状态机本身）")
        check(!WatchNagService.due(finding(.dismissed, nag: 0, last: nil), task: task, now: now)
              && !WatchNagService.due(finding(.resolved, nag: 0, last: nil), task: task, now: now),
              "T-NAG ①已忽略 / 已解决都不催")
        check(!WatchNagService.due(finding(.open, nag: 0, last: now.addingTimeInterval(-5 * 3600)),
                                   task: task, now: now),
              "T-NAG ①刚催过 5 小时 ⇒ 冷却内不催")
        check(WatchNagService.due(finding(.open, nag: 0, last: now.addingTimeInterval(-21 * 3600)),
                                  task: task, now: now),
              "T-NAG ①21 小时前催过 ⇒ 冷却已过（锚点是**上次催**，不是 `createdAt`）")
        check(!WatchNagService.due(finding(.open, nag: WatchNagService.limit, last: nil),
                                   task: task, now: now),
              "T-NAG ①催满 \(WatchNagService.limit) 次 ⇒ 闭嘴（第四次开始只是噪音，会让人把整条通道关掉）")
        check(!WatchNagService.due(finding(.open, nag: 0, last: nil, createdHoursAgo: 1),
                                   task: task, now: now),
              "T-NAG ①刚提出 1 小时 ⇒ 先让人看一眼，不催")
        var paused = task
        paused.enabled = false
        check(!WatchNagService.due(finding(.open, nag: 0, last: nil), task: paused, now: now),
              "T-NAG ①任务停用 ⇒ 不催（人明确关掉了这条巡检线）")
        var cron = task
        cron.kind = .execute
        check(!WatchNagService.due(finding(.open, nag: 0, last: nil), task: cron, now: now),
              "T-NAG ①Cron 档不催（只有助理有「等我决定」这件事）")

        // ══ ② 落库往返 ═════════════════════════════════════════════════════
        let mock = MockTransport()
        mock.scriptedReply = { _ in "NO_FINDING" }
        let store = ChatStore(transport: mock, dbPath: dir + "/nag.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: dir, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-NAG ②前置: 助理任务已建"); return
        }
        // 先跑一轮把日志会话建起来（不跑的话下面那条时间线没有落点）
        store.scheduledTasks[ai].notify.system = false   // 冒烟不发真系统通知
        store.runScheduledFire(store.scheduledTasks[ai])
        _ = await waitUntil { store.runningTurns.isEmpty }
        guard let logId = store.scheduledTasks[ai].logSessionId else {
            check(false, "T-NAG ②前置: 日志会话已绑"); return
        }
        // 归属改到真任务上 —— `finding()` 用的是临时 task.id
        var real = finding(.open, nag: 0, last: nil)
        real.taskId = store.scheduledTasks[ai].id
        real.sourceId = projId
        real.sessionId = logId
        try? store.persistence?.upsertFinding(real)
        store.reloadFindings()
        let roundTrip = store.findings.first { $0.id == real.id }
        check(roundTrip?.nagCount == 0 && roundTrip?.lastNaggedAt == nil,
              "T-NAG ②新行的催促字段是 0 / nil（老库升上来也落到这里，不需要迁移脚本）")

        // ══ ③ 端到端：扫一次 = 涨一次 + 留痕 + **没有副作用** ═══════════════
        let runsBefore = store.scheduledTasks[ai].lastRunAt
        store.scheduler.nagWaitingFindings(now: now)
        let nagged = store.findings.first { $0.id == real.id }
        check(nagged?.nagCount == 1 && nagged?.lastNaggedAt != nil,
              "T-NAG ③扫一次 ⇒ `nagCount` 1 且落了时刻（实际 \(nagged?.nagCount ?? -1)）")
        let texts = store.replayMessages(for: logId).compactMap { m -> String? in
            if case .text(let s) = m.content { return s }
            return nil
        }
        check(texts.contains { $0.contains("已催第 1 次") },
              "T-NAG ③日志会话里留了一行痕（第几次、催的是哪条）")
        check(store.scheduledTasks[ai].lastRunAt == runsBefore && store.runningTurns.isEmpty,
              "T-NAG ③⚠️ 催**不开回合、不推进 `lastRunAt`**（它挂在 tick 上，不是第二个 cron）")

        // 同一时刻再扫一次 ⇒ 冷却压住（这一格就是"跨 fire 不重复催"）
        store.scheduler.nagWaitingFindings(now: now)
        check(store.findings.first { $0.id == real.id }?.nagCount == 1,
              "T-NAG ③同一次 tick 再扫不重复催（冷却锚点是刚落的 `lastNaggedAt`）")

        // ══ ④ 到顶就闭嘴 ═══════════════════════════════════════════════════
        var capped = real
        capped.nagCount = WatchNagService.limit
        capped.lastNaggedAt = now.addingTimeInterval(-48 * 3600)
        try? store.persistence?.upsertFinding(capped)
        store.reloadFindings()
        store.scheduler.nagWaitingFindings(now: now)
        check(store.findings.first { $0.id == real.id }?.nagCount == WatchNagService.limit,
              "T-NAG ④催满 \(WatchNagService.limit) 次之后不再涨（哪怕冷却早过了）")
    }
}
