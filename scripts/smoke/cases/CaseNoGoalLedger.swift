//
//  CaseNoGoalLedger —— P19.2 S13: 无目标 / 无来源的助理照样跑
//
//  这三个判据都是"看起来该省一步、其实会静默坏掉"的地方:
//    ① **无目标**（`task.prompt` 空）—— 空字符串发给引擎 = 一条空 user 消息，
//       而 system 段还在说「看守一个长程目标」⇒ 模型会自己编一个目标出来；
//    ② **无来源** —— `allFailed` 把"没有任何可采集的来源"也算失败，于是无项目助理
//       永远不 spawn。S13 放宽保存校验之后，这条会把整类"待命"助理变成哑巴；
//    ③ **空账本** —— Q2 定的是"不跳过，只改注入"。注入里必须明说"账本还不存在，
//       没有可追踪的目标就回 NO_FINDING"，否则模型收到的是一个没有目标的看守指令。
//
//  ⚠️ 台账**视图**不在这条判据里: 它是视觉产物（门禁管不到），数据那一侧由
//     `CaseAssistantLedger` 的 35 条管着（五节 / 三态 / brief）。
//
//  反例（实测红点，逐条认领）：
//    · `runScheduledFire` 的 `!task.sources.isEmpty` 条件去掉（回到 S13 之前）
//      ⇒ ① **1 红**（无来源又被打成 allFailed ⇒ 不 fire）；
//    · `watchUserPrompt` 去掉空 goal 的 guard ⇒ ① + ③ **2 红**（正文不是出厂常量、
//      user 消息悬空）；
//    · `watchSystemPrompt` 去掉「没有给定目标」那一段 ⇒ ③ **1 红**。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseNoGoalLedger() async {
        let dir = fixtureDir("p19nogal")

        // ══ ① 无项目 + 无来源 + 无目标 ⇒ 照常 spawn，正文是出厂常量 ══════════
        let mock = MockTransport()
        mock.scriptedReply = { _ in "NO_FINDING" }
        let store = ChatStore(transport: mock, dbPath: dir + "/nogal.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        store.addScheduled(name: "待命", prompt: "", cron: "0 0 1 1 *",
                           projectId: nil, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "待命" }) else {
            check(false, "T-NOGOAL ①前置: 无目标助理已建"); return
        }
        store.runScheduledFire(store.scheduledTasks[ai])
        _ = await waitUntil { store.runningTurns.isEmpty }
        check(mock.lastSentPrompt == SchedulerService.assistantNoGoalPrompt,
              "T-NOGOAL ①无目标助理**照常 fire**，正文换成出厂常量（空串 = 一条空 user 消息）")
        check(store.scheduledTasks[ai].logSessionId != nil,
              "T-NOGOAL ①且日志会话照建（跑了就得有地方看得见）")

        // ══ ② 配了来源、但一条都没采到 ⇒ 仍然不 spawn，且留痕 ═══════════════
        // 这一格是**反面**: 放宽的是"没配来源"，不是"配了坏来源"。换一套 store 才能证明
        // "什么都没发"—— 共用前一个 mock 的话，`lastSentPrompt` 上还留着 ① 那一轮的正文。
        let mock2 = MockTransport()
        mock2.scriptedReply = { _ in "NO_FINDING" }
        let store2 = ChatStore(transport: mock2, dbPath: dir + "/nogal2.db",
                               managedExtensionsDir: dir + "/ext")
        store2.scheduler.stopScheduler()
        store2.addScheduled(name: "有来源", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                            projectId: nil, kind: .assistant,
                            sources: [WatchSourceSpec(kind: .mail, name: "收件箱")])
        guard let bi = store2.scheduledTasks.firstIndex(where: { $0.name == "有来源" }) else {
            check(false, "T-NOGOAL ②前置: 带来源的助理已建"); return
        }
        store2.runScheduledFire(store2.scheduledTasks[bi])
        check(mock2.lastSentPrompt == nil,
              "T-NOGOAL ②配了来源但一条都没采到 ⇒ **不 spawn**（配置坏了，不烧一轮 token 看空数据）")
        if let logId = store2.scheduledTasks[bi].logSessionId {
            let lines = store2.replayMessages(for: logId)
                .compactMap { m -> String? in
                    if case .text(let s) = m.content { return s }
                    return nil
                }
            check(lines.contains { $0.contains("没有可用来源") },
                  "T-NOGOAL ②而且留了一行痕（静默不发 = 人以为任务根本没跑）")
        } else {
            check(false, "T-NOGOAL ②跳过的那一轮也要把日志会话绑给任务")
        }

        // ══ ③ 注入文案：无目标 / 空账本各自说清该说什么 ═════════════════════
        let snap = WatchSnapshot(outcomes: [])
        let noGoal = SchedulerService.watchSystemPrompt(
            project: nil, goal: "", handoff: nil, snapshot: snap,
            ledgerPath: "/tmp/ledger-check.md")
        check(noGoal.contains("没有给定目标") && noGoal.contains("NO_FINDING"),
              "T-NOGOAL ③无目标 ⇒ 注入明说「没有给定目标」并给退路（NO_FINDING 不算失败）")
        let withGoal = SchedulerService.watchSystemPrompt(
            project: nil, goal: "保证 CI 是绿的", handoff: nil, snapshot: snap,
            ledgerPath: "/tmp/ledger-check.md")
        check(!withGoal.contains("没有给定目标"),
              "T-NOGOAL ③有目标时**不多这一句**（同一句话写两遍会让人分不清哪个算数）")
        check(withGoal.contains("账本还不存在") && withGoal.contains("NO_FINDING"),
              "T-NOGOAL ③空账本 ⇒ 明说「账本还不存在」+ 没有可追踪的目标就回 NO_FINDING（Q2：不跳过只改注入）")
        check(SchedulerService.watchUserPrompt(goal: "").contains("没有给定目标"),
              "T-NOGOAL ③无目标时 user 消息也不悬空（「本轮巡检目标：」后面什么都没有最糟）")
    }
}
