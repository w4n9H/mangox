//
//  CaseWaitingAsk —— 「## 待你决定」必须真的问得出去（P19.4，2026-11-18 boss 提的那条）
//
//  为什么这条非有不可：
//    无人值守下 fire 恒 `unattended` ⇒ 审批卡**根本不发**（`beginTurn` 里 `askApproval: false`），
//    而巡检轮围栏模式是 `deny` ⇒ 围栏外一律拒。所以"重要操作等人确认 / 缺材料问人"这两件事
//    在 fire 轮**没有任何出路**；模型能表达它们的唯一地方是账本「## 待你决定」，而账本**没有
//    触达** —— 人永远不会知道。这一组判据守的就是那条断掉的线。
//
//  三条纪律（都在判据里）：
//    ① 每一行落一条 `info` finding（**无 plan** ⇒ 收件箱里点不了"执行"）：问一句和"怎么动三步"
//       是两件事。落成 finding 之后催/上限/系统通知/飞书全部自动接上。
//    ② **落库全部、外发一条**：一次 fire 五件事就往飞书塞五条，人的反应是把通道关掉。
//    ③ 同任务同指纹**不重复问** —— 所以"模型改写措辞"是有后果的，契约里明写了别改。
//
//  反例（2026-11-18 实测）：去掉 `waitingFindings` 里的同指纹去重 ⇒ ③ 那格红（每轮都新增）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseWaitingAsk() async {
        let dir = fixtureDir("p19waiting")
        let projDir = dir + "/proj"
        try? FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        let mock = MockTransport()
        // 这一组只测「待你决定 → findings」那条线: 让结论那一侧回 NO_FINDING，
        // 否则"外发几次"里会混进结论那一条（实测第一次就红在这上面 —— 数的是 2）。
        mock.scriptedReply = { _ in "NO_FINDING" }
        let store = ChatStore(transport: mock, dbPath: dir + "/p19wait.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: projDir, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let idx = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-WAITASK 前置: 助理任务已建"); report()
        }
        let taskId = store.scheduledTasks[idx].id

        // 账本夹具: 五节齐，「待你决定」由入参给。
        func ledger(_ lines: [String]) -> String {
            let waiting = lines.isEmpty ? "无" : lines.map { "- " + $0 }.joined(separator: "\n")
            return """
            ## 目标
            保证 CI 是绿的
            ## 完成状态
            - [ ] CI 最近三次运行都是绿的
            ## 在跟踪
            - 盯着 CI
            ## 待你决定
            \(waiting)
            ## 已完成（归档）
            无
            """
        }

        /// 跑一轮 fire 并把账本写进去（写盘在 fire 之前 —— 收尾读的是**盘上那一份**）。
        func fire(_ lines: [String]) async -> UUID {
            _ = store.scheduler.saveHandoff(for: store.scheduledTasks[idx], content: ledger(lines))
            store.runScheduledFire(store.scheduledTasks[idx])
            _ = await waitUntil { store.runningTurns.isEmpty }
            store.reloadFindings()
            return store.scheduledTasks[idx].logSessionId ?? UUID()
        }

        func asks() -> [AgentFinding] {
            store.findings.filter { $0.taskId == taskId && $0.severity == "info"
                                    && $0.evidence == WatchFindingService.waitingEvidence }
        }
        func timelineCount(_ needle: String, in sid: UUID) -> Int {
            store.replayMessages(for: sid).reduce(0) { acc, m in
                guard case .text(let s) = m.content else { return acc }
                return acc + (s.contains(needle) ? 1 : 0)
            }
        }

        // —— ① 两行 ⇒ 两条 finding，都是 info、都没有方案 ——
        let askA = "要不要把 .github/workflows 里那个 30 分钟的 job 拆开？· 它今天三次超时 [2] · 回「拆 / 不拆」"
        let askB = "缺 staging 的数据库只读账号 · 观察里只有生产那一个 [1] · 给我一个能连的账号名"
        let sid1 = await fire([askA, askB])
        let first = asks()
        check(first.count == 2, "T-WAITASK ①两行「待你决定」⇒ 落两条（实际 \(first.count) 条）")
        check(first.allSatisfy { $0.severity == "info" },
              "T-WAITASK ①severity 是 info（不是 action —— 问一句不等于「这就是该执行的三步」）")
        check(first.allSatisfy { $0.plan.isEmpty },
              "T-WAITASK ①**没有方案**：收件箱里点不了「执行」（点得动就说明它把问题做成了方案）")
        check(Set(first.map(\.fingerprint)).count == 2,
              "T-WAITASK ①两条不同的问题指纹不同（否则第二行会被第一行吞掉）")

        // —— ② 落库全部、外发一条 ——
        // 冒烟里没绑机器人 ⇒ `pushFinding` 会回 `.skipped` 并写一行时间线。**数它的次数**：
        // 一次 fire 有两条新问题，飞书那条路只该被走一次。这条判据不打在"看起来对不对"上，
        // 打在"打扰了几次"上 —— 五件事塞五条消息，人的反应是把通道整个关掉。
        let pushes = timelineCount("触达 · 飞书私聊", in: sid1)
        check(pushes == 1,
              "T-WAITASK ②一次 fire 里**只外发第一条**（实际走了 \(pushes) 次）"
              + "；其余落库，交给催按冷却一批批盯")

        // —— ③ 账本没变 ⇒ 不重复问 ——
        _ = await fire([askA, askB])
        check(asks().count == 2,
              "T-WAITASK ③同一份账本再跑一轮 ⇒ 不新增（同任务同指纹不重复问；"
              + "实际 \(asks().count) 条）")
        let markedAsked = (store.scheduledTasks[idx].logSessionId.map {
            timelineCount("已经问过，不重复打扰", in: $0)
        } ?? 0) > 0
        check(markedAsked,
              "T-WAITASK ③时间线要写「已经问过，不重复打扰」—— "
              + "不写的话人分不清「这轮没问」还是「问了但被吞了」")

        // —— ④ 新增一行 ⇒ 只增那一条 ——
        let askC = "要不要把老的 staging 环境整个下掉？· 它已经两周没人部署 [3] · 回「下 / 留」"
        let beforeC = asks().count
        _ = await fire([askA, askB, askC])
        let addedC = asks().count - beforeC
        check(addedC == 1, "T-WAITASK ④加一行只该多一条（本轮多了 \(addedC) 条 —— "
              + "多出来的都是被重复问的旧问题）")

        // —— ⑤ 占位的「无」不是问题 ——
        // ⚠️ 判据必须看**本轮增量**，不能看总数 —— 看总数的话这一格会被前面几轮的累积污染
        //    （2026-11-18 实测：反例下它跟着 ③④ 一起红，等于它不是独立判据，认领不了任何东西）。
        let beforeEmpty = asks().count
        _ = await fire([])
        check(asks().count == beforeEmpty,
              "T-WAITASK ⑤「待你决定: 无」不落 finding（把「无」当成一条问题的话，"
              + "每一轮都会问人一次「无」；本轮新增 \(asks().count - beforeEmpty) 条）")

        // —— ⑥ 契约里那几条强约束真的在（它们是这条链路唯一的"教它怎么做"） ——
        let sys = SchedulerService.watchSystemPrompt(
            project: WatchProjectContext(name: "看守盘", path: projDir),
            goal: "保证 CI 是绿的", handoff: ledger([]), snapshot: WatchSnapshot(outcomes: []),
            ledgerPath: "/tmp/x/.mangox/assistant/l.md")
        check(sys.contains("没有人坐在你旁边") && sys.contains("主动发到人的飞书"),
              "T-WAITASK ⑥巡检轮注入说清「没人旁边 / 审批卡不弹 / 要信息写进待你决定」"
              + "（不说的话它会伸手乱动，而没人拦得住它）")
        let contract = SchedulerService.watchLedgerContract
        check(contract.contains("查得到的不要问") && contract.contains("原样保留那一行"),
              "T-WAITASK ⑥账本契约里有「查得到的不要问」与「已有的原样保留」"
              + "（后者是去重的前提：改写措辞 = 新问题 = 再打扰一次）")
        check(contract.contains("只放「要信息」") && contract.contains("方案"),
              "T-WAITASK ⑥且这一节**只放要信息的事**：动手的写进输出契约的「方案」那一段"
              + "（那一份才有人点「采纳并执行」—— 写成这里的问句会让人以为点个头就完了）")

        store.scheduler.stopScheduler()
    }
}
