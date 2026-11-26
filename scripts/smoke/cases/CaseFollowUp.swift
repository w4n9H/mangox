//
//  CaseFollowUp.swift
//  follow-up（2026-11-23）—— agent 给自己约定时器。
//
//  这个功能的**全部风险都在边界上**，所以判据也都在边界:
//    · 它必须**不能**变成"一条新任务"（不进任务列表、不推 `lastRunAt` / `runCount`）；
//    · 它必须**只能**属于某个已存在的任务（普通会话拿不到工具 —— 拿了也没人读 spool）；
//    · 到点起不来时，约定要**放回去**而不是被吃掉（否则人永远等不到那次回看）；
//    · 未兑现的条数有上限（没有它，一轮焦虑的巡检能约 20 个时刻，此后每一条 cron 都在
//      叫醒自己里烧 token）。
//
//  五层判据：
//    ① **解析表**（纯函数 `FollowUpSpool.parse`）：形状 / id / 整数 / 闭区间 / why；
//    ② **落库往返**：幂等（同一 id 插两次只算一条）、到期扫描只取 pending 且到点、
//       删任务连它的约定一起删（回收半径）；
//    ③ **归属与配额**：没有归属拿不到工具；配额三态（`nil` / `0` / `n`，Cron 档恒 0）；
//       三道闸各一条（一轮一条 / 每天 N 条 / 未兑现 3 条），且**拒的理由要能说出来**；
//       收口那一下：入库、能取到、spool 删掉；
//    ④ **行为不变量**：回看轮**不推进** `lastRunAt` / `runCount`（它是一次体外唤醒，
//       不是这个任务的一次定时运行 —— 推进会让"该补哪一段"和"跑了多少次"同时变假）；
//    ⑤ **回收半径**：删任务连它的约定一起删。
//
//  反例（每条都点名它守的是哪一格）:
//    · `runScheduledFire` 末尾去掉 `&& followUp == nil` ⇒ **1 红**: ④；
//    · `beginFollowUpTurn` 去掉 `!owner.isLegacyWaiting` ⇒ **1 红**: ③ 的归属格；
//    · `followUpSpoolPath` 改成固定文件名 ⇒ **2 红**: ② 的路径格 + ③（两个任务互相覆盖）；
//    · `insertFollowUpIfAbsent` 改成 `INSERT`（不减幂等）⇒ **1 红**: ② 的幂等格；
//    · `finishFollowUpIfNeeded` 去掉 `inThisTurn` 那道闸 ⇒ **1 红**: ③c；
//    · 去掉 `quotaLeft > 0` 那道闸 ⇒ **1 红**: ③d；
//    · 去掉 `pending < maxPendingPerTask` 那道闸 ⇒ **1 红**: ③e。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseFollowUp() async {
        print("== T-FOLLOWUP agent 给自己约定时器 ==")

        // 守卫 26 的**第二个受守对象**: spool 根必须在冒烟期就被挪出用户真实目录。
        // ⚠️ 这一行不是"保险"，是判据的前置 —— 下面 ② 就直接断言它。
        let dir = fixtureDir("p20followup")
        PiRpcTransport.followUpSpoolRootOverride = dir + "/followup-spool"

        // ══ ① 解析表（纯函数）═══════════════════════════════════════════════
        let good = #"{"id":"11111111-2222-3333-4444-555555555555","after_minutes":30,"why":"构建还在跑"}"#
        let (ok, noneRejected) = FollowUpSpool.parse(good)
        check(ok.count == 1 && ok[0].afterMinutes == 30 && ok[0].why == "构建还在跑"
              && noneRejected.isEmpty,
              "T-FOLLOWUP ①合法行 ⇒ 一条请求, 字段原样 (实测 \(ok.count) / \(noneRejected.count))")

        // 同一来源（"这一行的形状不对"）并进一条: 三个坏形状各拒一次, 且行号指得回去。
        let broken = """
        not json

        {"after_minutes":30,"why":"缺 id"}
        {"id":"11111111-2222-3333-4444-555555555555","after_minutes":3.5,"why":"非整数"}
        """
        let (bItems, bRejects) = FollowUpSpool.parse(broken)
        check(bItems.isEmpty && bRejects.count == 3
              && bRejects.map(\.line) == [1, 3, 4],
              "T-FOLLOWUP ①形状不对的三种(非 JSON / 缺 id / 非整数)都拒, 且**行号指得回去**"
              + " (实测 \(bRejects.map { "\($0.line):\($0.reason)" }))")

        // 闭区间: 两侧越界都拒, 两侧边界都收 —— 一条 check 把"是闭区间"这件事说完。
        func line(_ m: Double, why: String = "等一等") -> String {
            #"{"id":"11111111-2222-3333-4444-555555555555","after_minutes":"#
                + "\(m)" + #","why":"\#(why)"}"#
        }
        let low = FollowUpLimit.minMinutes
        let high = FollowUpLimit.maxMinutes
        let (edgeItems, edgeRejects) = FollowUpSpool.parse(
            [line(Double(low)), line(Double(high)), line(Double(low - 1)), line(Double(high + 1))]
                .joined(separator: "\n"))
        check(edgeItems.count == 2 && edgeRejects.count == 2,
              "T-FOLLOWUP ①\(low) / \(high) 收, 再往外一格就拒 ⇒ 闭区间"
              + " (实测收 \(edgeItems.count) 拒 \(edgeRejects.count))")

        let longWhy = String(repeating: "长", count: FollowUpLimit.maxWhyChars + 40)
        let (wItems, wRejects) = FollowUpSpool.parse(line(30, why: "") + "\n" + line(30, why: longWhy))
        check(wItems.count == 1 && wRejects.count == 1
              && wItems[0].why.count == FollowUpLimit.maxWhyChars + 1,
              "T-FOLLOWUP ①空 why 拒(醒来时它只有这一句话), 超长截到 \(FollowUpLimit.maxWhyChars) 字"
              + " (实测 \(wItems.first?.why.count ?? -1) 字, 拒 \(wRejects.count) 条)")

        // ①b 作废行（2026-11-26）: 与约定同一份 spool，但**不进约定、不吃配额**。
        // 四种形状一起喂，因为"分得清两支"才是这条判据的内容:
        //   合法作废 / 缺 why / op 写错 / **没有 op 的老行**（老扩展写的，必须仍按约定收）。
        let cancelOK = #"{"op":"cancel","id":"11111111-2222-3333-4444-555555555555","why":"用户说搞定了"}"#
        let cancelNoWhy = #"{"op":"cancel","id":"11111111-2222-3333-4444-555555555555"}"#
        let addNoOp = #"{"id":"11111111-2222-3333-4444-555555555555","after_minutes":30,"why":"老扩展写的行"}"#
        let badOp = #"{"op":"cancelx","id":"11111111-2222-3333-4444-555555555555","why":"x"}"#
        let mixed = FollowUpSpool.parseBatch([cancelOK, cancelNoWhy, addNoOp, badOp]
            .joined(separator: "\n"))
        check(mixed.cancels.count == 1 && mixed.items.count == 1 && mixed.rejects.count == 2
              && mixed.cancels.first?.why == "用户说搞定了"
              && mixed.rejects.map(\.line) == [2, 4],
              "T-FOLLOWUP ①b 作废行走另一支(缺 why 拒、op 写错拒), 而**没有 `op` 的老行仍按约定收**"
              + " —— 判成坏行会让磁盘上已有的残留一次性全废"
              + " (实测 作废 \(mixed.cancels.count) / 约定 \(mixed.items.count) / 拒 \(mixed.rejects.count))")

        // ══ ② 落库往返 ═════════════════════════════════════════════════════
        let mock = MockTransport()
        mock.scriptedReply = { _ in "NO_FINDING" }
        let store = ChatStore(transport: mock, dbPath: dir + "/followup.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: dir, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }),
              let p = store.persistence else {
            check(false, "T-FOLLOWUP ②前置: 助理任务与库都就位"); return
        }
        let taskId = store.scheduledTasks[ai].id
        let now = Date()

        // 路径: 一个任务一个文件，且落在**被重定向的**根里（守卫 26 的第二受守对象）。
        let spoolA = PiRpcTransport.followUpSpoolPath(taskId: taskId)
        check(spoolA.hasPrefix(PiRpcTransport.followUpSpoolDir() + "/")
              && spoolA.hasSuffix("\(taskId.uuidString).jsonl")
              && !PiRpcTransport.followUpSpoolDir().hasPrefix(NSHomeDirectory() + "/.mangox"),
              "T-FOLLOWUP ②spool 落在重定向后的根里, 文件名 = 任务 id (实测 \(spoolA))")

        func followUp(_ minutes: Double, why: String = "等一等", id: UUID = UUID(),
                      task: UUID? = nil, createdAt: Date? = nil) -> FollowUp {
            FollowUp(id: id, taskId: task ?? taskId, dueAt: now.addingTimeInterval(minutes * 60),
                     why: why, status: .pending, attempts: 0,
                     createdAt: createdAt ?? now, firedAt: nil, note: nil)
        }
        let first = followUp(-1)   // 已经到点
        let future = followUp(120) // 还没到
        _ = try? p.insertFollowUpIfAbsent(first)
        let insertedAgain = (try? p.insertFollowUpIfAbsent(first)) ?? true
        _ = try? p.insertFollowUpIfAbsent(future)
        check(insertedAgain == false && (try? p.loadFollowUps(taskId: taskId))?.count == 2,
              "T-FOLLOWUP ②同一个 id 插两次**只算一条**(收口崩在落库与删文件之间时靠它兜住)")

        let due = (try? p.dueFollowUps(now: now)) ?? []
        check(due.map(\.id) == [first.id],
              "T-FOLLOWUP ②到期扫描只取 `pending` 且 `due_at <= now` (实测 \(due.count) 条)")

        // 落定之后就不再被扫到 —— "叫过就不再叫"只有这一个保证，没有第二处。
        try? p.settleFollowUp(id: first.id, status: .fired, firedAt: now, note: nil)
        check(((try? p.dueFollowUps(now: now)) ?? []).isEmpty,
              "T-FOLLOWUP ②落定(fired)之后不再进到期清单")
        // `future` 这一条从池子里撤掉（cancelled 也算落定）: 下面的 ③ 要**从干净的零头**
        // 开始数未兑现状 —— 留着它就是"这三条早就在了"，而 ③ 的判据正是"顶到上限。
        try? p.settleFollowUp(id: future.id, status: .cancelled, firedAt: nil, note: "冒烟清池")

        // ══ ③ 归属判据: 没有归属就拿不到工具 ═══════════════════════════════
        // 普通会话（不属于任何任务）拿不到 spool ⇒ 拿不到工具 ⇒ 结构上做不到"聊天时约会"。
        check(store.scheduler.beginFollowUpTurn(sid: UUID(), owner: nil) == nil,
              "T-FOLLOWUP ③普通会话**没有** follow-up 工具 (约定必须有归属才能被叫起来)")
        var legacy = store.scheduledTasks[ai]
        legacy.kind = .legacyWaiting
        check(store.scheduler.beginFollowUpTurn(sid: UUID(), owner: legacy) == nil,
              "T-FOLLOWUP ③旧条件值守(只读归档)也**没有** —— 它连 fire 都不许，更不该能约时间")

        // ══ ③b 配额三态（纯函数）══════════════════════════════════════════
        // `nil` = 没配过（按出厂值）/ `0` = 人明确关掉 / `n` = 上限。合成两态就再也分不开
        // 「他从没看过」和「他关掉了」—— 前者会让将来改出厂值的时候**悄悄改掉他的选择**。
        // 三个读数同源（`effectiveFollowUpsPerDay`），并成一条 —— 分开写只是把一行红变三行。
        var q = store.scheduledTasks[ai]
        let factory = ScheduledTask.factoryFollowUpsPerDay
        let unsetValue = q.effectiveFollowUpsPerDay
        q.followUpsPerDay = 0
        let offIsOff = q.effectiveFollowUpsPerDay
        q.followUpsPerDay = 5
        let fiveIsFive = q.effectiveFollowUpsPerDay
        q.kind = .execute
        q.followUpsPerDay = nil
        let cronZero = q.effectiveFollowUpsPerDay
        check(unsetValue == factory && offIsOff == 0 && fiveIsFive == 5 && cronZero == 0,
              "T-FOLLOWUP ③b 没配过 ⇒ 出厂 \(factory); 明确关掉 ⇒ 0(不回落出厂值); 配 5 ⇒ 5;"
              + " Cron 档**恒 0**(那一档没有这个入口)"
              + " (实测 \(unsetValue) / \(offIsOff) / \(fiveIsFive) / \(cronZero))")

        // ── 三道配额闸: 每道一个**独立任务** ──
        // 日配额与未兑现计数都按 task_id 累加; 共用一个任务会互相污染, 于是"这条是被哪道闸
        // 挡回去的"就说不清了 —— 而这三道闸正是这个功能里唯一会**误伤**的地方。
        func freshAssistant(_ name: String, perDay: Int?) -> ScheduledTask {
            var t = ScheduledTask(id: UUID(), name: name, prompt: "看一件事",
                                  cron: "0 0 1 1 *", projectId: projId, continuous: false)
            t.kind = .assistant
            t.followUpsPerDay = perDay
            store.scheduler.scheduledTasks.append(t)
            try? p.upsertScheduled(t)
            return t
        }
        func freshSession(_ title: String) -> UUID {
            let sid = UUID()
            store.chats.append(ConversationItem(id: sid, title: title))
            try? p.insertChatSession(ConversationItem(id: sid, title: title))
            return sid
        }
        func spoolLine(_ why: String, minutes: Int = 45) -> String {
            #"{"id":"\#(UUID().uuidString)","after_minutes":\#(minutes),"why":"\#(why)"}"#
        }
        /// 跑一轮"它给自己约会": 拿到 spool → 写模型会写的那几行 → 收口。
        /// 每轮一个新 sid —— `followUpFires` 按 sid 记，复用同一个等于第二轮根本开不了闸。
        @discardableResult
        func runFollowUpTurn(owner: ScheduledTask, sid: UUID, lines: [String]) -> String? {
            guard let spool = store.scheduler.beginFollowUpTurn(sid: sid, owner: owner) else {
                return nil
            }
            try? FileManager.default.createDirectory(
                atPath: (spool as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? lines.joined(separator: "\n")
                .write(toFile: spool, atomically: true, encoding: .utf8)
            store.scheduler.finishFollowUpIfNeeded(sid: sid)
            return spool
        }
        func timeline(_ sid: UUID) -> String {
            store.replayMessages(for: sid).compactMap { msg -> String? in
                guard case .text(let s) = msg.content else { return nil }
                return s
            }.joined(separator: "\n")
        }
        func pendingOf(_ id: UUID) -> [FollowUp] {
            store.scheduler.followUps.filter { $0.taskId == id }
        }

        // 闸① 一轮一条: 一轮里冒出两个以上的未来时刻 = 它在给自己排班。
        let g1 = freshAssistant("闸一 一轮一条", perDay: nil)
        let s1 = freshSession("闸一")
        let spool1 = runFollowUpTurn(owner: g1, sid: s1,
                                     lines: [spoolLine("构建该出结果了"),
                                             spoolLine("这条要被挤掉"), "坏行"])
        let got1 = pendingOf(g1.id)
        check(got1.count == 1 && got1.first?.why == "构建该出结果了"
              && timeline(s1).contains("一轮只能约 1 条"),
              "T-FOLLOWUP ③c 闸①: 一轮写两条**只进一条**(留先写的那条), 时间线点名"
              + "'一轮只能约 1 条' (实测进 \(got1.count) 条)")

        // 闸② 每天 N 条: 人手里那个旋钮，拦"每轮都约"。配额 1 ⇒ 用掉一条之后当场就满。
        let g2 = freshAssistant("闸二 每天配额", perDay: 1)
        let s2a = freshSession("闸二甲")
        runFollowUpTurn(owner: g2, sid: s2a, lines: [spoolLine("第一次")])
        let s2b = freshSession("闸二乙")
        runFollowUpTurn(owner: g2, sid: s2b, lines: [spoolLine("第二次")])
        let got2 = pendingOf(g2.id)
        check(got2.count == 1 && timeline(s2b).contains("今天已经约了 1 条（上限 1）"),
              "T-FOLLOWUP ③d 闸②: 配额 1 用完之后**再约被拒**, 且拒的理由说得出是配额(不是"
              + "'形状不对'那种含糊话) (实测进 \(got2.count) 条)")

        // 闸③ 未兑现上限: 拦堆积。⚠️ 按**未兑现**算而不是历史条数 —— 一个跑了很久的助理
        // 不该因为"总共约过 50 次"被禁。这三条用三天前的 `created_at` 塞进去: 这样今日配额
        // 仍是 0，能挡住它的只能是闸③（否则这条判据会被闸②抢先红，测的东西就错了）。
        let g3 = freshAssistant("闸三 未兑现上限", perDay: nil)
        let daysAgo = now.addingTimeInterval(-3 * 86400)
        for i in 0..<FollowUpLimit.maxPendingPerTask {
            _ = try? p.insertFollowUpIfAbsent(
                followUp(360 + Double(i), why: "早就约下的 \(i)", task: g3.id, createdAt: daysAgo))
        }
        let s3 = freshSession("闸三")
        runFollowUpTurn(owner: g3, sid: s3, lines: [spoolLine("第四条")])
        let got3 = pendingOf(g3.id)
        check(got3.count == FollowUpLimit.maxPendingPerTask && timeline(s3).contains("欠 3 条"),
              "T-FOLLOWUP ③e 闸③: 未兑现顶到 \(FollowUpLimit.maxPendingPerTask) 条时**不再接受**"
              + " (实测 \(got3.count) 条)")

        // 收口那一下: 入库 → 取得到 → spool 删掉。三件事同源("这一轮真的消化完了")，
        // 分开写会让"文件还在"和"库里没有"这两种半成品都各自算绿。
        let dueOk = got1.first.map { f in
            f.dueAt > Date() && f.dueAt < Date().addingTimeInterval(47 * 60)
        } ?? false
        check(dueOk && store.scheduler.nextFollowUp(for: g1.id) != nil
              && spool1 != nil && !FileManager.default.fileExists(atPath: spool1!),
              "T-FOLLOWUP ③f 收口: `dueAt` = 约的 45 分钟后(在 App 里算)、能取到下一条、"
              + " spool 文件被删(留着会被下一轮再 ingest 一遍)"
              + " (实测 dueAt \(String(describing: got1.first?.dueAt)))")

        // ══ ④ 行为不变量: 回看轮不算"这个任务的一次运行" ═════════════════════
        // 前提: 先跑一次**普通** cron fire 把日志会话建起来（对照用），再跑一次回看。
        store.scheduledTasks[ai].notify.system = false   // 冒烟不发真系统通知
        store.runScheduledFire(store.scheduledTasks[ai])
        _ = await waitUntil { store.runningTurns.isEmpty }
        let normalRuns = store.scheduledTasks[ai].runCount
        let normalLast = store.scheduledTasks[ai].lastRunAt

        let firing = followUp(-1, why: "该回看了")
        store.runScheduledFire(store.scheduledTasks[ai], followUp: firing)
        let started = await waitUntil { store.runningTurns.isEmpty }
        check(started && store.scheduledTasks[ai].runCount == normalRuns
              && store.scheduledTasks[ai].lastRunAt == normalLast,
              "T-FOLLOWUP ④回看轮**不推进** runCount / lastRunAt"
              + " (实测 \(store.scheduledTasks[ai].runCount) 次 / lastRunAt \(String(describing: store.scheduledTasks[ai].lastRunAt))，"
              + "普通 fire 之后是 \(normalRuns) 次)")
        check(store.scheduledTasks[ai].logSessionId != nil,
              "T-FOLLOWUP ④但日志会话仍然**绑上**了 (回看轮的产出要落在同一场会话里)")

        // 反例方向（**同一条无条件下发的判据**）: 紧接一个不属于任何任务的普通回合，
        // spool 必须被清回 nil。不清的话它会**粘在实例上** —— 之后那次聊天也能给自己约会，
        // 而收口只认「归任务的那一轮」⇒ 表现是"它说约好了，到点没人叫它"。
        // ⚠️ 冒烟里所有会话共用同一个 mock 实例（`injectedTransport`），所以这条观察得到真值。
        let plainSid = UUID()
        store.chats.append(ConversationItem(id: plainSid, title: "普通会话"))
        try? p.insertChatSession(ConversationItem(id: plainSid, title: "普通会话"))
        store.beginTurn(sid: plainSid, prompt: "在吗", ephemeral: false, cwd: nil, unattended: false)
        check(mock.lastFollowUpSpool == nil && mock.followUpSpoolUpdates > 0,
              "T-FOLLOWUP ④普通回合把 spool **清回 nil**(无条件下发)"
              + " (实测 lastFollowUpSpool = \(String(describing: mock.lastFollowUpSpool)))")
        _ = await waitUntil { store.runningTurns.isEmpty }

        // ══ ⑤ 回收半径: 删任务连它的约定一起删 ═══════════════════════════════
        store.deleteScheduled(id: taskId)
        let left = (try? p.loadFollowUps(taskId: taskId)) ?? []
        check(left.isEmpty,
              "T-FOLLOWUP ⑤删任务把它的约定一起删 (留着的话 tick 每分钟扫一次指向不存在任务的 pending,"
              + " 实测剩 \(left.count) 条)")

        // ══ ⑥ 叫停: 「这件事结束了」只撤该任务**还等着叫的**（2026-11-26）════════
        // 三个对象必须同时在场，这条判据才说得清"半径":
        //   甲 两条 pending（要撤）/ 乙 一条 pending（不许牵连）/ 甲 一条已 fired（历史，不许回滚）。
        // 少任何一个，"作废得太宽"或"作废得太窄"都测不出来。
        let stopA = freshAssistant("叫停 甲", perDay: nil)
        let stopB = freshAssistant("叫停 乙", perDay: nil)
        let s6 = freshSession("叫停")
        _ = try? p.insertFollowUpIfAbsent(followUp(120, why: "甲 一", task: stopA.id))
        _ = try? p.insertFollowUpIfAbsent(followUp(180, why: "甲 二", task: stopA.id))
        let firedRow = followUp(60, why: "甲 已叫过", task: stopA.id)
        _ = try? p.insertFollowUpIfAbsent(firedRow)
        try? p.settleFollowUp(id: firedRow.id, status: .fired, firedAt: now, note: nil)
        _ = try? p.insertFollowUpIfAbsent(followUp(120, why: "乙 一", task: stopB.id))

        let n6 = store.scheduler.cancelPendingFollowUps(taskId: stopA.id,
                                                       note: "用户说这件事结束了", sid: s6)
        let aRows = (try? p.loadFollowUps(taskId: stopA.id)) ?? []
        let bPending = (try? p.loadFollowUps(taskId: stopB.id, status: .pending)) ?? []
        let aCancelled = aRows.filter { $0.status == .cancelled }.count
        let aFired = aRows.filter { $0.status == .fired }.count
        check(n6 == 2 && aCancelled == 2 && aFired == 1 && bPending.count == 1
              && timeline(s6).contains("作废了 2 条回看"),
              "T-FOLLOWUP ⑥叫停只撤该任务**还等着叫的**: 两条 pending 变 cancelled、已 fired 的"
              + "**仍是历史**、别的任务一条都不牵连、时间线说得出撤了几条"
              + " (实测 撤 \(n6) / 甲 cancelled \(aCancelled) / 甲 fired \(aFired) / 乙 pending \(bPending.count))")

        // 同一轮里"原来的不用了，改看另一件事" —— 顺序必须是**先撤后约**。
        // 反过来新的那条会被自己的作废扫掉，表现是"它说约好了，到点没人叫它"。
        let stopC = freshAssistant("叫停+新约", perDay: nil)
        _ = try? p.insertFollowUpIfAbsent(followUp(120, why: "旧的", task: stopC.id))
        let s6b = freshSession("叫停+新约")
        runFollowUpTurn(owner: stopC, sid: s6b,
                        lines: [#"{"op":"cancel","id":"\#(UUID().uuidString)","why":"用户说搞定了"}"#,
                                spoolLine("新的那件事")])
        let cPending = pendingOf(stopC.id)
        check(cPending.count == 1 && cPending.first?.why == "新的那件事",
              "T-FOLLOWUP ⑥同一轮里 撤约 + 新约: 旧的作废、**新约活着**(顺序反了新的会被自己扫掉)"
              + " (实测 pending \(cPending.map(\.why)))")

        PiRpcTransport.followUpSpoolRootOverride = nil
    }
}
