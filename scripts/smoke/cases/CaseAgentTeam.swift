//
//  CaseAgentTeam.swift
//  P20 多助理协作 —— P1 数据与域 + **P2 派活闭环**（2026-11-24）。
//
//  这一段判的是"没有一行界面也要成立"的那一半：
//    · **① 分级**: 角色缺省恒 main、未知值不降级；worker 与 Cron 档拿不到派活配额；
//      四条域不变量（main 无 parent / worker 必须有 parent / 深度恒 1 / worker 名字唯一）
//      各自能把坏行**拦在库外**（不是"存进去再提示"）。
//    · **①b 数据面**: 六个列三处（SELECT / 构造 / INSERT）真的同步了；派活单能存能读，
//      两个读法各自只取该取的那些行；长文本落库前被截到上限。
//    · **⑦ 连带的域层半边**: 删 main 只停用 worker（parent 留成悬挂值 ⇒ 未归属）、
//      停/启 main 只恢复 `disabledByParent` 的那些、删 worker 把它名下的单子作废**但留着行**
//      （P3 那句"这个活没了"就靠这一行活着）。
//    · **⑫~㉑ = P2 的结束判据**（对照文档 §06: ③拒绝 / ④到期 / ⑥回叫 / ⑧工具面 / ⑩顺延）:
//      七条拒绝理由各自说得出、名单只列自己人且状态三档、到点真起跑、被闸挡住只顺延
//      （不按次数判死）、过了 `due_by` 才作废并回执、交活给 main 一条 0 分钟唤醒且**不占配额**、
//      worker 那一轮没有 `delegate` / `feishu_attach`、main 在跑时派活**顺延**。
//
//  ⚠️ 每条判据都同时问**两件事**: 纯判据（`TeamRule` / `DelegationRule`）给出的**理由**，
//  与真链路（`addScheduled` / `updateScheduled` / `fireDueDelegations` / `beginTurn`）
//  **真的挡住了 / 真的起跑了**。只判前者不知道门有没有接上（假门），只判后者分不出
//  是被哪个理由拒的（"拒了"不等于"拒对了"）。
//
//  反例（只写**实测过**的，不编数字）:
//    · `applyTeamCascade` 的 `.disabled` 分支去掉 `guard w.enabled else { return false }`
//      ⇒ ⑧ **实测 1 红**: 手动停掉的那个 worker 会被"启 main"拉起来。
//    · `DelegationRule.check` 去掉 `busy` 那道判（"他手上有活"）⇒ **实测 1 红**: ⑭
//      （实测输出里 `busyReason` 是空串 = 那条单被收下了，正是要抓的那件事）。
//
//  ⚠️ 这一段**不碰**真实目录: 库走 `dbPath`，与 `CaseFollowUp` 同款（`fixtureDir` + 显式注入）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseAgentTeam() async {
        print("== T-TEAM P1 助理团队: 分级 / 四条不变量 / 连带 ==")

        let dir = fixtureDir("p20team")
        let mock = MockTransport()
        let store = ChatStore(transport: mock, dbPath: dir + "/team.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "仓库运维", path: dir, items: []))
        guard let p = store.persistence else {
            check(false, "T-TEAM ①前置: 库就位")
            return
        }

        func task(_ id: UUID) -> ScheduledTask? { store.scheduledTasks.first { $0.id == id } }
        func idOf(_ name: String) -> UUID {
            store.scheduledTasks.first(where: { $0.name == name })?.id ?? UUID()
        }
        @discardableResult
        func addMain(_ name: String) -> UUID {
            store.addScheduled(name: name, prompt: "盯着这摊事", cron: "0 3 * * *",
                               projectId: projId, kind: .assistant)
            return idOf(name)
        }
        /// 建一个 worker，返回 `(域层收下了没, 纯判据给出的理由)`。
        @discardableResult
        func addWorker(_ name: String, under main: UUID?, duty: String = "查发票与月度报表",
                       detail: String = "", perDay: Int? = nil) -> (ok: Bool, why: TeamViolation?) {
            // 探针与真写入用**同一个形状**（只差 id，而 `TeamRule` 自己按 id 摘自己）。
            var probe = ScheduledTask(id: UUID(), name: name, prompt: "按派活单干",
                                      cron: "0 3 * * *", projectId: projId, continuous: false)
            probe.kind = .assistant
            probe.role = .worker
            probe.parentId = main
            probe.description = duty
            probe.descriptionDetail = detail
            let why = TeamRule.violation(probe, among: store.scheduledTasks)
            let ok = store.addScheduled(name: name, prompt: "按派活单干", cron: "0 3 * * *",
                                        projectId: projId, kind: .assistant,
                                        role: .worker, parentId: main,
                                        description: duty, descriptionDetail: detail)
            if ok, let perDay, let i = store.scheduledTasks.firstIndex(where: { $0.name == name }) {
                store.scheduledTasks[i].delegatesPerDay = perDay
                store.updateScheduled(store.scheduledTasks[i])
            }
            return (ok, why)
        }
        func delegate(from: UUID, to: UUID, minutes: Double = 10) -> Delegation {
            Delegation(id: UUID(), fromTask: from, toTask: to,
                       goal: "对一遍 11 月发票", acceptance: "差异列单号与金额",
                       context: nil, dueAt: Date().addingTimeInterval(minutes * 60), dueBy: nil,
                       status: .queued, attempts: 0, note: nil, summary: nil,
                       reportedAt: nil, createdAt: Date(), startedAt: nil, finishedAt: nil)
        }

        // ══ ① 分级 ═══════════════════════════════════════════════════════════
        // 缺省与未知都必须落到 main：老库的行、所有 Cron 行都从这个口进来。
        // 三件事同源（"没有角色这一说的话，它就是队长"）⇒ 并成一条，分开写只是把一行红变三行。
        let mainId = addMain("仓库队长")
        let decodeOk = TaskRole.decode(nil) == .main && TaskRole.decode("") == .main
            && TaskRole.decode("main") == .main && TaskRole.decode("worker") == .worker
            && TaskRole.decode("supervisor") == .main
        check(decodeOk && task(mainId)?.role == .main && task(mainId)?.parentId == nil,
              "T-TEAM ①角色缺省恒 main: 空 / NULL / 认不出的值都落在 main(把 main 降级成 worker 是"
              + "看不见的能力损失); 新建的任务就是 main 且没有上级"
              + " (实测 decode=\(decodeOk) role=\(task(mainId)?.role.rawValue ?? "?")"
              + " parent=\(String(describing: task(mainId)?.parentId)))")

        // ══ ①b 六个列的落库往返 ══════════════════════════════════════════════
        // 三处（SELECT 列表 / 构造 / INSERT 列与 VALUES）漏任何一处, 这一条就红 —— 它就是这个用途。
        _ = addWorker("财务会计", under: mainId, duty: "查发票与月度报表",
                      detail: "差异要列单号与金额，别只给总数。", perDay: 3)
        let wId = idOf("财务会计")
        let back = ((try? p.loadScheduled()) ?? []).first { $0.id == wId }
        check(back?.role == .worker && back?.parentId == mainId
              && back?.description == "查发票与月度报表"
              && back?.descriptionDetail == "差异要列单号与金额，别只给总数。"
              && back?.delegatesPerDay == 3 && back?.disabledByParent == false,
              "T-TEAM ①b 六列(role/parent_id/description/description_detail/delegate_per_day/"
              + "disabled_by_parent)落库往返一致 (读回 role=\(back?.role.rawValue ?? "?")"
              + " parent=\(back?.parentId.map { String($0.uuidString.prefix(8)) } ?? "-")"
              + " 职责=\(back?.description.count ?? -1)字 说明=\(back?.descriptionDetail.count ?? -1)字"
              + " 配额=\(String(describing: back?.delegatesPerDay)))")

        // ══ ③ 派活配额三态（纯读数口）═══════════════════════════════════════
        // 与 follow-up 同一族的坑: 塌成两态就分不开"他没看过"与"他关掉了"。
        // worker / Cron 恒 0 —— 工具面里根本没有 delegate, 给一个每次都被挡的工具只会让它反复试。
        let workerZero = task(wId)!.effectiveDelegatesPerDay
        var q = task(mainId)!
        let mainFactory = q.effectiveDelegatesPerDay
        q.delegatesPerDay = 0
        let mainOff = q.effectiveDelegatesPerDay
        q.delegatesPerDay = 4
        let mainFour = q.effectiveDelegatesPerDay
        q.kind = .execute
        q.delegatesPerDay = nil
        let cronZero = q.effectiveDelegatesPerDay
        check(workerZero == 0 && mainFactory == ScheduledTask.factoryDelegatesPerDay
              && mainOff == 0 && mainFour == 4 && cronZero == 0,
              "T-TEAM ③配额: worker 恒 0 / main 没配过 ⇒ 出厂 \(ScheduledTask.factoryDelegatesPerDay)"
              + " / 明确关掉 ⇒ 0(不回落出厂) / 配 4 ⇒ 4 / Cron 档恒 0"
              + " (实测 \(workerZero) / \(mainFactory) / \(mainOff) / \(mainFour) / \(cronZero))")

        // ══ ④ 域不变量: main 无上级 / worker 有上级 ═══════════════════════════
        // 一条 check = "角色决定 parent 的有无"这一个事实的两侧。两条都被拒**且库里没长出行**。
        var badMain = task(mainId)!
        badMain.parentId = mainId
        let mainWhy = TeamRule.violation(badMain, among: store.scheduledTasks)
        let mainWithParentRejected = store.updateScheduled(badMain) == false
        let before = store.scheduledTasks.count
        let orphan = addWorker("野生 worker", under: nil)
        check(mainWhy == .mainHasParent && mainWithParentRejected
              && orphan.ok == false && orphan.why == .workerWithoutParent
              && store.scheduledTasks.count == before,
              "T-TEAM ④main 挂上级被拒, worker 没有上级也被拒, 且都**没在库里长出行**"
              + " (实测 \(String(describing: mainWhy)) / \(String(describing: orphan.why))"
              + " 行数 \(before)→\(store.scheduledTasks.count))")

        // ══ ⑤ 深度恒 1 ═══════════════════════════════════════════════════════
        let nested = addWorker("二级 worker", under: wId)
        check(nested.ok == false && nested.why == .parentIsWorker,
              "T-TEAM ⑤worker 下面再挂 worker 被拒 —— 递归硬限 1 级 (实测 \(String(describing: nested.why)))")

        // ══ ⑥ 名字唯一 ═══════════════════════════════════════════════════════
        // 派活单里只写名字 ⇒ 重名等于"两个人叫这个", 而派错的那次从回执上看不出来。
        // 后半句: 同一行不改名再存一次**必须成功**（唯一性判据把自己算进去是极易漏的一侧）。
        let dup = addWorker("财务会计", under: mainId)
        let selfSaveOk = store.updateScheduled(task(wId)!)
        check(dup.ok == false && dup.why == .duplicateName("财务会计") && selfSaveOk,
              "T-TEAM ⑥同名 worker 被拒, 但**同一行不改名再存一次能过**(唯一性不许把自己算成重名)"
              + " (实测 \(String(describing: dup.why)) / 自存 \(selfSaveOk))")

        // ══ ⑦ 连带: 删 main ══════════════════════════════════════════════════
        // 前提: 先派一张单, 才能验证"删 main ⇒ 单子作废但行还在"。
        let d1 = delegate(from: mainId, to: wId)
        try? p.insertDelegation(d1)
        store.deleteScheduled(id: mainId)
        let wAfter = task(wId)
        let dAfter = ((try? p.loadDelegations(fromTask: mainId)) ?? []).first { $0.id == d1.id }
        check(wAfter != nil && wAfter?.enabled == false && wAfter?.parentId == mainId
              && wAfter.map { TeamRule.isOrphan($0, among: store.scheduledTasks) } == true,
              "T-TEAM ⑦删 main: 名下的 worker **只停用不删**, parent 留成悬挂值(落进「未归属」)"
              + " (实测 还在=\(wAfter != nil) enabled=\(String(describing: wAfter?.enabled))"
              + " 孤儿=\(wAfter.map { TeamRule.isOrphan($0, among: store.scheduledTasks) } ?? false))")
        check(dAfter?.status == .cancelled && dAfter?.note == "main 已删除",
              "T-TEAM ⑦删 main: 它派出去的单子作废**但行留着**(P3 那句「这个活没了」就靠这一行,"
              + " 删了就永远到不了) (实测 \(String(describing: dAfter?.status))"
              + " / \(String(describing: dAfter?.note)))")

        // ══ ⑧ 连带: 停 / 启 main 只恢复 disabledByParent 的那些 ═══════════════
        // 整个连带逻辑里**最贵**的一条: 没有它, 启一次 main 会把人自己关掉的 worker 也拉起,
        // 而那种事发生一次, 人就不敢再用那个开关。
        let m2 = addMain("第二支队")
        _ = addWorker("跟着停的", under: m2)
        _ = addWorker("我自己关的", under: m2)
        let followId = idOf("跟着停的")
        let manualId = idOf("我自己关的")
        store.scheduler.setEnabled(manualId, false)          // 人手动关掉一个
        store.scheduler.setEnabled(m2, false)                // 再关整个 main
        let stopped = task(followId)?.enabled == false && task(followId)?.disabledByParent == true
            && task(manualId)?.enabled == false && task(manualId)?.disabledByParent == false
        store.scheduler.setEnabled(m2, true)                 // 打开 main
        let after = task(followId)?.enabled == true && task(followId)?.disabledByParent == false
            && task(manualId)?.enabled == false
        // 落库那一份也要跟着（否则重启之后"启 main"会再拉起那个手动关掉的）
        let persisted = ((try? p.loadScheduled()) ?? []).first { $0.id == manualId }
        check(stopped && after && persisted?.enabled == false && persisted?.disabledByParent == false,
              "T-TEAM ⑧停 main ⇒ 全停(手动关的那个**不打标记**); 启 main ⇒ 只恢复打标记的,"
              + " 手动关的保持关 (实测 停后=\(stopped) 启后=\(after) 库里手动那个"
              + " enabled=\(String(describing: persisted?.enabled)))")

        // ══ ⑨ 连带: 删 worker ════════════════════════════════════════════════
        let m3 = addMain("第三支队")
        _ = addWorker("干完就删的", under: m3)
        let w9 = idOf("干完就删的")
        let d9 = delegate(from: m3, to: w9)
        try? p.insertDelegation(d9)
        store.deleteScheduled(id: w9)
        let d9After = ((try? p.loadDelegations(toTask: w9)) ?? []).first { $0.id == d9.id }
        check(d9After?.status == .cancelled && d9After?.note == "worker 已删除",
              "T-TEAM ⑨删 worker: 名下的单子作废, note 说得清是被删了(不是「没跑」)"
              + " (实测 \(String(describing: d9After?.status)) / \(String(describing: d9After?.note)))")

        // ══ ⑩ 派活单数据面: 往返 + 落库前截断 ═══════════════════════════════
        let m4 = addMain("第四支队")
        _ = addWorker("记账的", under: m4)
        let w10 = idOf("记账的")
        var long = delegate(from: m4, to: w10)
        long.goal = String(repeating: "长", count: DelegationLimit.maxGoalChars + 100)
        try? p.insertDelegation(long)
        let backD = ((try? p.loadDelegations(toTask: w10)) ?? []).first { $0.id == long.id }
        check(backD != nil && backD?.goal.count == DelegationLimit.maxGoalChars + 1
              && backD?.acceptance == "差异列单号与金额" && backD?.fromTask == m4
              && backD?.context == nil && backD?.dueBy == nil,
              "T-TEAM ⑩派活单往返一致, 超长 goal 落库前截到 \(DelegationLimit.maxGoalChars) 字"
              + "(这一段会逐字进 worker 的 prompt ⇒ 没有上限就是没有围栏的注入面)"
              + " (实测 \(backD?.goal.count ?? -1) 字)")

        // ══ ⑪ 三个读法各自只取该取的行 ═══════════════════════════════════════
        // `openDelegations` = "它手上有没有活"（派活前那道硬拒读它，不是读计数）;
        // `dueDelegations` = tick 那一跳（只 queued 且到点 —— running 的不许再被叫一次）。
        let past = delegate(from: m4, to: w10, minutes: -1)     // 已到点
        let future = delegate(from: m4, to: w10, minutes: 120)  // 还没到
        try? p.insertDelegation(past)
        try? p.insertDelegation(future)
        let openNow = (try? p.openDelegations(to: w10)) ?? []
        try? p.startDelegation(id: past.id, at: Date())         // 已到点，但正在跑
        let dueAfterStart = (try? p.dueDelegations(now: Date())) ?? []
        try? p.settleDelegation(id: past.id, status: .done, summary: "3 处差异", note: nil, at: Date())
        let openAfterSettle = (try? p.openDelegations(to: w10)) ?? []
        check(openNow.count == 3 && !dueAfterStart.contains { $0.id == past.id }
              && openAfterSettle.map(\.id) == [long.id, future.id],
              "T-TEAM ⑪未落定的都算「手上有活」(\(openNow.count) 张); 起跑之后**不再被 tick 叫**;"
              + " 落定之后只剩没落定的 (实测 open=\(openAfterSettle.count) 张,"
              + " 到期清单含已起跑那张=\(dueAfterStart.contains { $0.id == past.id }))")

        // ══════════════════════ P2 派活闭环（2026-11-24）══════════════════════
        // 本文件的 ⑫~㉑ 对上文档 §06 的结束判据:
        //   ⑫⑬⑭⑮ = ③拒绝 · ⑯⑰ = ④到期 · ⑱ = ⑥回叫 · ⑲⑳ = ⑧工具面 · ㉑ = ⑩顺延
        //
        // ⚠️ 这一段的判据**全落在 `DelegationRule` / `fireDueDelegations` 上**（纯判据 + 真链路
        // 各一半）。只判纯判据 ⇒ 不知道门有没有接上（假门）; 只判链路 ⇒ 分不出是被哪一条拒的。

        let m5 = addMain("第五支队")
        _ = addWorker("对账的", under: m5)
        let w5 = idOf("对账的")
        let m5Task = task(m5)!
        func ask(_ name: String, after: Int = 10, dueIn: Int? = nil) -> DelegationAsk {
            DelegationAsk(id: UUID(), worker: name, goal: "对一遍 11 月发票",
                          acceptance: "差异列单号与金额", afterMinutes: after,
                          dueInMinutes: dueIn, context: nil)
        }
        /// 纯判据给出的拒绝理由（`nil` = 这一单会被收下）。
        func refusal(_ name: String, busy: [UUID: Delegation] = [:],
                     usedToday: Int = 0, usedThisTurn: Int = 0) -> DelegationRefusal? {
            if case .failure(let w) = DelegationRule.check(ask(name), from: m5Task,
                                                           roster: store.scheduledTasks,
                                                           busy: busy, usedToday: usedToday,
                                                           usedThisTurn: usedThisTurn) {
                return w
            }
            return nil
        }

        // ══ ⑫ 派给谁: 没这个人 / 它自己是队长 / 它被停用 ═══════════════════════
        let rUnknown = refusal("查账的")
        let rIsMain = refusal("第五支队")
        store.scheduler.setEnabled(w5, false)
        let rDisabled = refusal("对账的")
        store.scheduler.setEnabled(w5, true)
        check(rUnknown == .unknownWorker("查账的") && rIsMain == .workerIsMain("第五支队")
              && rDisabled == .workerDisabled("对账的"),
              "T-TEAM ⑫派给谁: 没这个人 / 它自己是队长 / 它被停用 —— 三条各自拒, 且理由里带着**名字**"
              + " (下一轮改得对; 只回一句「不能派」它只能再猜一次)"
              + " (实测 \(String(describing: rUnknown)) / \(String(describing: rIsMain))"
              + " / \(String(describing: rDisabled)))")

        // ══ ⑬ 拒绝时附的那句名单 ═════════════════════════════════════════════
        // 三件事同源（"回给它的名单得能直接用来改"）⇒ 并成一条: 只列**自己名下**的、
        // 不列队长自己、且状态三档各自说得出（空闲 / 已排上几点 / 已停用）。
        let idleLine = DelegationRule.rosterLine(m5Task, roster: store.scheduledTasks, busy: [:])
        var held5 = delegate(from: m5, to: w5)
        held5.startedAt = Date()
        let busyLine = DelegationRule.rosterLine(m5Task, roster: store.scheduledTasks,
                                                 busy: [w5: held5])
        store.scheduler.setEnabled(w5, false)
        let offLine = DelegationRule.rosterLine(m5Task, roster: store.scheduledTasks, busy: [:])
        store.scheduler.setEnabled(w5, true)
        check(idleLine.contains("对账的(空闲)") && busyLine.contains("对账的(已排上 ")
              && offLine.contains("对账的(已停用)")
              && !idleLine.contains("第五支队") && !idleLine.contains("记账的"),
              "T-TEAM ⑬拒绝附的名单: 只列**这个 main 名下**的 worker(别人的队伍列出来等于让它去派"
              + "一个派不了的人), 且状态三档说得清 —— 空闲 / 已排上几点 / 已停用"
              + " (实测「\(idleLine)」「\(busyLine)」「\(offLine)」)")

        // ══ ⑭ 他有空吗 ═══════════════════════════════════════════════════════
        // 硬拒不排队: 一个 worker 同时只做一张单。拒的理由必须带**手上那张是什么、什么时候起的**
        // —— 否则下一轮它还会再派一次（"它忙"不是它能自己推出来的事）。
        // 后半句是反方向: 那张单落定之后同一个人**必须能再派** —— 否则"忙"一次就永久粘住。
        let rBusy = refusal("对账的", busy: [w5: held5])
        let busyReason = rBusy?.reason ?? ""
        let busyOK: Bool
        if case .workerBusy(let n, let g, let st)? = rBusy {
            busyOK = n == "对账的" && g == held5.goal && st == held5.startedAt
                && busyReason.contains(DelegationRefusal.hhmm(held5.startedAt!))
                && busyReason.contains("不会排队")
        } else {
            busyOK = false
        }
        check(busyOK && refusal("对账的") == nil,
              "T-TEAM ⑭手上有活 ⇒ 硬拒不排队, 理由里带**起跑时刻**与它在干什么; 那张单落定之后"
              + "同一个人能再派(判据读的是未落定清单, 不是「派过几次」)"
              + " (实测 \(busyReason)｜落定后 \(String(describing: refusal("对账的"))))")

        // ══ ⑮ 三道额度, 且顺序是「先事实、后额度」 ═══════════════════════════
        // 反例方向: 把额度判据挪到"派给谁"之前 ⇒ 额度用尽时派错人也会报"额度用完",
        // 模型于是以为"等明天就能派成"。
        let rTurn = refusal("对账的", usedThisTurn: DelegationLimit.maxPerTurn)
        let quota = m5Task.effectiveDelegatesPerDay
        let rDay = refusal("对账的", usedToday: quota)
        let rOrder = refusal("查账的", usedToday: 99, usedThisTurn: 99)
        check(rTurn == .turnLimit(DelegationLimit.maxPerTurn)
              && rDay == .dailyLimit(used: quota, quota: quota)
              && rOrder == .unknownWorker("查账的"),
              "T-TEAM ⑮额度三道: 每轮 \(DelegationLimit.maxPerTurn) 条 / 每天 \(quota) 条各自拒得出;"
              + " 而**额度用尽 + 派错人**时报的是派错人(先事实后额度 —— 报额度会让它以为等一天就能成)"
              + " (实测 \(String(describing: rTurn)) / \(String(describing: rDay))"
              + " / \(String(describing: rOrder)))")

        // ══ ⑯ 到点起跑 ═══════════════════════════════════════════════════════
        let m6 = addMain("第六支队")
        _ = addWorker("跑腿的", under: m6)
        let w6 = idOf("跑腿的")
        let d6 = delegate(from: m6, to: w6, minutes: -1)          // 已到点
        try? p.insertDelegation(d6)
        store.scheduler.fireDueDelegations()
        let d6Running = ((try? p.loadDelegations(toTask: w6)) ?? []).first { $0.id == d6.id }
        var sep6 = false
        if let log6 = task(w6)?.logSessionId {
            sep6 = hasText(store.replayMessages(for: log6), "派活 · ")
        }
        check(d6Running?.status == .running && d6Running?.startedAt != nil && sep6,
              "T-TEAM ⑯到点的单真的起跑(`running` + `started_at`), 且日志会话第一行是"
              + "「派活 · 「目标」」—— 与 cron 运行长得一样的话, 人会以为这个 worker 自己跑了一次"
              + " (实测 \(String(describing: d6Running?.status)) / 分隔行=\(sep6))")

        // ══ ⑱ 交活 ⇒ 0 分钟回叫, 不占配额 ═══════════════════════════════════
        // 回执的投递借用 follow-up 的到期机制（`dueAt = now` ⇒ 下一跳就叫），
        // 但 `kind = callBack` ⇒ **不占** main 的回看配额。占的话: 带 5 个 worker 的 main
        // 一天就把配额耗光, 而人会说「我没约过这么多次」。
        _ = await waitUntil { store.runningTurns.isEmpty }
        let d6Done = ((try? p.loadDelegations(toTask: w6)) ?? []).first { $0.id == d6.id }
        let backs = ((try? p.loadFollowUps(taskId: m6, status: .pending)) ?? [])
            .filter { $0.kind == .callBack }
        let quota6 = (try? p.followUpCountSince(
            taskId: m6, since: Calendar.current.startOfDay(for: Date()))) ?? -1
        check(d6Done?.status == .done && d6Done?.summary?.isEmpty == false
              && backs.count == 1 && backs.first!.dueAt <= Date().addingTimeInterval(1)
              && quota6 == 0,
              "T-TEAM ⑱交活 ⇒ 那张单落成 `done`+`summary`, main 拿到的是一条**0 分钟**唤醒"
              + "(`dueAt` 就是现在, 下一跳就叫), 而它**不进**配额口径"
              + " (实测 \(String(describing: d6Done?.status)) / 回叫 \(backs.count) 条"
              + " / 配额口径记 \(quota6) 条)")

        // ══ ⑰ 被闸挡住 ⇒ 顺延（不按次数判死）; 过了 due_by 才作废 ═══════════
        let m7 = addMain("第七支队")
        _ = addWorker("休假的", under: m7)
        let w7 = idOf("休假的")
        let d7 = delegate(from: m7, to: w7, minutes: -1)
        try? p.insertDelegation(d7)
        store.scheduler.setEnabled(w7, false)
        let fired7 = Date()
        store.scheduler.fireDueDelegations(now: fired7)
        let d7After = ((try? p.loadDelegations(toTask: w7)) ?? []).first { $0.id == d7.id }
        let moved = (d7After?.dueAt.timeIntervalSince(fired7) ?? -1)
        check(d7After?.status == .queued && d7After?.attempts == 1
              && moved > 60 && moved < Double(FollowUpLimit.retryStepMinutes) * 60 + 5
              && (d7After?.note ?? "").contains("停着"),
              "T-TEAM ⑰被闸挡住 ⇒ **仍在排队**、`due_at` 往后挪一个步长、`attempts+1`, 理由写清"
              + " (不按次数判死: worker 忙四十分钟是正常的, 判 `failed` 等于把一条活扔掉)"
              + " (实测 \(String(describing: d7After?.status)) / attempts=\(d7After?.attempts ?? -1)"
              + " / 挪了 \(Int(moved))s / \(String(describing: d7After?.note)))")
        // 过了期限才作废 —— 而且**要留一条回执**: 「这个活没了」得送得到 main 面前。
        var d7b = delegate(from: m7, to: w7, minutes: -1)
        d7b.dueBy = Date().addingTimeInterval(-60)
        try? p.insertDelegation(d7b)
        store.scheduler.fireDueDelegations()
        let d7bAfter = ((try? p.loadDelegations(toTask: w7)) ?? []).first { $0.id == d7b.id }
        let d7bBack = ((try? p.loadFollowUps(taskId: m7, status: .pending)) ?? [])
            .filter { $0.kind == .callBack }
        check(d7bAfter?.status == .cancelled && (d7bAfter?.note ?? "").contains("期限")
              && d7bBack.count == 1,
              "T-TEAM ⑰`due_by` 过了 ⇒ 才作废, 且照样给 main 一条回执(作废不等于没人管)"
              + " (实测 \(String(describing: d7bAfter?.status))"
              + " / \(String(describing: d7bAfter?.note)) / 回执 \(d7bBack.count) 条)")

        // ══ ⑲ worker 那一轮的工具面 ═══════════════════════════════════════════
        // 根不变量的落点: worker 没有 `delegate`（递归扇出在结构上不成立）、
        // 没有 `feishu_attach`（外发唯一出口属于 main）、但有 `follow_up`（给自己约个回看是合理的）。
        let m8 = addMain("第八支队")
        _ = addWorker("跑单的", under: m8)
        let w8 = idOf("跑单的")
        let sidW = UUID()
        let convW = ConversationItem(id: sidW, title: "跑单的")
        store.chats.append(convW)
        try? p.insertChatSession(convW)
        if let i = store.scheduledTasks.firstIndex(where: { $0.id == w8 }) {
            store.scheduledTasks[i].logSessionId = sidW
            store.updateScheduled(store.scheduledTasks[i])
        }
        store.beginTurn(sid: sidW, prompt: "干这一单", ephemeral: false, cwd: nil, unattended: false)
        check(mock.lastDelegateSpool == nil && mock.delegateSpoolUpdates > 0
              && mock.lastAttachSpool == nil && mock.lastFollowUpSpool != nil
              && !ChatStore.attachSpoolAllowed(role: .worker)
              && ChatStore.attachSpoolAllowed(role: .main)
              && ChatStore.attachSpoolAllowed(role: nil),
              "T-TEAM ⑲worker 那一轮: 没有 delegate(递归扇出结构上不成立) / 没有 feishu_attach"
              + "(让人收到一条他无法归属的消息, 审批粒度就散了) / 但有 follow_up;"
              + " 附件那条判据**在结构上**为假(`attachSpoolAllowed(.worker) == false`),"
              + " 不是靠飞书轮碰巧没挂 (实测 delegate=\(String(describing: mock.lastDelegateSpool))"
              + " attach=\(String(describing: mock.lastAttachSpool))"
              + " followUp=\(mock.lastFollowUpSpool != nil))")
        _ = await waitUntil { store.runningTurns.isEmpty }

        // ══ ⑳ main 那一轮有 delegate; 之后的手动回合清回 nil ═════════════════
        let sidM = UUID()
        let convM = ConversationItem(id: sidM, title: "第八支队")
        store.chats.append(convM)
        try? p.insertChatSession(convM)
        if let i = store.scheduledTasks.firstIndex(where: { $0.id == m8 }) {
            store.scheduledTasks[i].logSessionId = sidM
            store.updateScheduled(store.scheduledTasks[i])
        }
        store.beginTurn(sid: sidM, prompt: "安排一下今天", ephemeral: false, cwd: nil,
                        unattended: false)
        let mainHasDelegate = mock.lastDelegateSpool != nil
        let mainRunning = store.runningTurns.contains(sidM)

        // ══ ㉑ main 那一场还在跑 ⇒ 派活顺延 ═══════════════════════════════════
        // `ComputerHost` 一个进程一个 scope ⇒ 两场同时要助手会互相 `stop()` 重启,
        // 现象是"微信点了一半助手消失了"。代价明写: 伪实时退化成"main 跑完立刻起"。
        let d8 = delegate(from: m8, to: w8, minutes: -1)
        try? p.insertDelegation(d8)
        let fired8 = Date()
        store.scheduler.fireDueDelegations(now: fired8)
        let d8After = ((try? p.loadDelegations(toTask: w8)) ?? []).first { $0.id == d8.id }
        check(mainRunning && d8After?.status == .queued && d8After?.attempts == 1
              && (d8After?.note ?? "").contains("main"),
              "T-TEAM ㉑main 那一场还在跑 ⇒ 这一单**不顺延起跑**, 只往后挪并说清是等 main"
              + " (判据是 `runningTurns`, 不是猜 -- 实测 main 在跑=\(mainRunning)"
              + " / \(String(describing: d8After?.status))"
              + " / \(String(describing: d8After?.note)))")

        _ = await waitUntil { store.runningTurns.isEmpty }
        let plainSid = UUID()
        let convP = ConversationItem(id: plainSid, title: "普通会话")
        store.chats.append(convP)
        try? p.insertChatSession(convP)
        store.beginTurn(sid: plainSid, prompt: "在吗", ephemeral: false, cwd: nil,
                        unattended: false)
        check(mainHasDelegate && mock.lastDelegateSpool == nil,
              "T-TEAM ⑳`delegate` 只挂在**手上有队伍的 main** 那一轮; 之后的手动回合清回 nil"
              + " (挂着不清 = 普通聊天里也能派活, 而那个 spool 没有任何一轮会去读 ⇒"
              + " 「它说派出去了, 那个活从没开始」) (实测 main 那一轮=\(mainHasDelegate)"
              + " 之后=\(String(describing: mock.lastDelegateSpool)))")
        _ = await waitUntil { store.runningTurns.isEmpty }
    }
}
