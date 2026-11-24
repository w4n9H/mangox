//
//  CaseAgentTeam.swift
//  P20 多助理协作 · **P1 数据与域**（2026-11-24）。
//
//  这一段的判据只属于"没有一行界面也要成立"的那一半：
//    · **① 分级**: 角色缺省恒 main、未知值不降级；worker 与 Cron 档拿不到派活配额；
//      四条域不变量（main 无 parent / worker 必须有 parent / 深度恒 1 / worker 名字唯一）
//      各自能把坏行**拦在库外**（不是"存进去再提示"）。
//    · **①b 数据面**: 六个列三处（SELECT / 构造 / INSERT）真的同步了；派活单能存能读，
//      两个读法各自只取该取的那些行；长文本落库前被截到上限。
//    · **⑦ 连带的域层半边**: 删 main 只停用 worker（parent 留成悬挂值 ⇒ 未归属）、
//      停/启 main 只恢复 `disabledByParent` 的那些、删 worker 把它名下的单子作废**但留着行**
//      （P3 那句"这个活没了"就靠这一行活着）。
//
//  ⚠️ 每条判据都同时问**两件事**: 纯判据（`TeamRule`）给出的**理由**，与写路径（`addScheduled`
//  / `updateScheduled`）**真的挡住了**。只判前者不知道门有没有接上（假门），只判后者分不出
//  是被哪个理由拒的（"拒了"不等于"拒对了"）。
//
//  反例（只写**实测过**的，不编数字）:
//    · `applyTeamCascade` 的 `.disabled` 分支去掉 `guard w.enabled else { return false }`
//      ⇒ ⑧ **实测 1 红**: 手动停掉的那个 worker 会被"启 main"拉起来。
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
    }
}
