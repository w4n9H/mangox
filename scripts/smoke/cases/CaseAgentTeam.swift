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
//    · **㉒~㉚ = P3 的结束判据**（②名单 / ⑤回执消费 / ⑨两个只读工具）:
//      【你的队伍】12 行 / ≤700 字 / 职责原文照搬 / 说明不进段、状态五档各自说得清、
//      回执**成功收尾才标**（空回合不标）、一次最多念 5 条、`list_workers` 缺口分两级、
//      `read_worker_ledger` 超长时**砍验收项保尾巴**、三个工具名与源码同源。
//    · **㉛~㉝ = P4 的结束判据**（列表页 · 建与改）: 视图层没有门，所以判的是被抽出来的
//      那三件**纯函数** —— 职责必填**在域层也拦**（不只是保存按钮）、列表行平铺时认得出
//      谁是队长 / 谁是谁的人（worker 不写周期、孤儿写「未归属」）、五档状态各自说得清。
//      ⚠️ 界面本身（竖条画在哪、输入框摆在哪）只归眼睛 —— 见文档 §06 P4 那一行「亮/暗各看一次」。
//
//  ⚠️ 每条判据都同时问**两件事**: 纯判据（`TeamRule` / `DelegationRule` / `TeamPrompt`）给出的
//  **理由与字数**，与真链路（`addScheduled` / `updateScheduled` / `fireDueDelegations` /
//  `beginTurn` / 收口）**真的挡住了 / 真的起跑了 / 真的标了**。只判前者不知道门有没有接上
//  （假门），只判后者分不出是被哪个理由拒的（"拒了"不等于"拒对了"）。
//
//  反例（只写**实测过**的，不编数字）:
//    · `applyTeamCascade` 的 `.disabled` 分支去掉 `guard w.enabled else { return false }`
//      ⇒ ⑧ **实测 1 红**: 手动停掉的那个 worker 会被"启 main"拉起来。
//    · `DelegationRule.check` 去掉 `busy` 那道判（"他手上有活"）⇒ **实测 1 红**: ⑭
//      （实测输出里 `busyReason` 是空串 = 那条单被收下了，正是要抓的那件事）。
//    · `markReceiptsReported` 去掉 `produced` 那道判（空回合也标）⇒ **实测 1 红**: ㉕
//      （读数里 `reported_at` 变成非空 = 那条回执被静默吞了）。
//    · `TeamRule.violation` 去掉 `workerWithoutDuty` 那道判 ⇒ **实测 1 红**: ㉛
//      （读数里 `ok=true` = 空职责的 worker 被建出来了，而它在名单里选不出来）。
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

        // ══════════════════════ P3 注入与只读工具（2026-11-24）══════════════════
        // 本文件的 ㉒~㉚ 对上文档 §06 的结束判据: ㉒㉓ = ②名单 · ㉔㉕㉖ = ⑤回执消费 ·
        // ㉗㉘㉙㉚ = ⑨两个只读工具（+ 工具名与源码同源）。
        //
        // ⚠️ 这一段的判据**全落在纯函数上**（`TeamPrompt`）**加上一条真链路**（回执的
        // 消费点）—— 前者的正文进上下文、必须能断言字数与措辞；后者是"标在哪一刻"，
        // 而标错一格的后果是回执被静默吞掉。

        // ══ ㉒（doc ②）【你的队伍】: 12 行 / 段长 ≤ 700 / 职责原文照搬 / 不含说明 ═══
        let m9 = addMain("第九支队")
        let fullDuty = String(repeating: "查", count: DelegationLimit.maxDescriptionChars)
        let dutyDetail = String(repeating: "细", count: 60)
        for i in 0..<DelegationLimit.maxTeamRows {
            // **12 个都是满格职责 + 60 字说明** —— 这样"说明泄漏进来"会直接把段长顶过 700，
            // 预算那条判据才有牙（半格职责时 12 个人也到不了上限，泄漏也照样绿）。
            _ = addWorker("兵\(i)", under: m9, duty: fullDuty, detail: dutyDetail)
        }
        let roster9 = TeamPrompt.rosterBlock(main: task(m9)!, roster: store.scheduledTasks,
                                            busy: [:], now: Date()) ?? ""
        check(roster9.split(separator: "\n").count == DelegationLimit.maxTeamRows + 1
              && roster9.count <= 700 && roster9.contains(fullDuty)
              && !roster9.contains(dutyDetail),
              "T-TEAM ㉒(doc②)【你的队伍】12 个人 12 行、整段 ≤ 700 字、职责**原文照搬不截断**"
              + "(40 字满格也在)，而职责说明**一个字都不进来** —— 进来的话每轮要多付 "
              + "12×240 = 2880 字，等于每轮先读一篇文档再干活"
              + " (实测 \(roster9.count) 字 / \(roster9.split(separator: "\n").count) 行)")

        // ══ ㉓（doc ②）状态五档各自说得出来 ═══════════════════════════════════
        // 同一份 `stateWord` 三处用（队伍段 / list_workers / 以后的画板）⇒ 只判它一处。
        // 五档不能合并: "已排上 09:31"与"在跑 3 分钟"对模型的含义完全不同（能不能现在派）。
        let wIdle = idOf("兵1"), wRun = idOf("兵2"), wQueued = idOf("兵3"), wOff = idOf("兵4")
        var busy9: [UUID: Delegation] = [:]
        var running9 = delegate(from: m9, to: wRun)
        running9.status = .running
        running9.startedAt = Date().addingTimeInterval(-180)
        busy9[wRun] = running9
        busy9[wQueued] = delegate(from: m9, to: wQueued)
        store.scheduler.setEnabled(wOff, false)
        if let i = store.scheduledTasks.firstIndex(where: { $0.id == wIdle }) {
            store.scheduledTasks[i].lastRunAt = Date().addingTimeInterval(-3 * 86_400)
        }
        let now9 = Date()
        let wordIdleDays = TeamPrompt.stateWord(task(wIdle)!, busy: busy9, now: now9)
        let wordRunning = TeamPrompt.stateWord(task(wRun)!, busy: busy9, now: now9)
        let wordQueued = TeamPrompt.stateWord(task(wQueued)!, busy: busy9, now: now9)
        let wordOff = TeamPrompt.stateWord(task(wOff)!, busy: busy9, now: now9)
        store.scheduler.setEnabled(wOff, true)
        check(wordIdleDays == "空闲 3 天" && wordRunning == "在跑 3 分钟"
              && wordQueued.hasPrefix("已排上 ") && wordOff == "已停用",
              "T-TEAM ㉓(doc②)状态五档: 空闲 N 天(三天没派过活的人要被看见) / 在跑 N 分钟 /"
              + " 已排上 HH:mm / 已停用 —— 四档各自说得清, 且短的优先(停用 ⇒ 在跑 ⇒ 已排上 ⇒ 空闲)"
              + " (实测 \(wordIdleDays) / \(wordRunning) / \(wordQueued) / \(wordOff))")

        // ══ ㉔（doc ⑤）回执: 注入 ⇒ 那一轮**成功收尾**才标 ═════════════════════
        let m10 = addMain("第十支队")
        _ = addWorker("交活的", under: m10)
        let w10b = idOf("交活的")
        let sid10 = UUID()
        let conv10 = ConversationItem(id: sid10, title: "第十支队")
        store.chats.append(conv10)
        try? p.insertChatSession(conv10)
        if let i = store.scheduledTasks.firstIndex(where: { $0.id == m10 }) {
            store.scheduledTasks[i].logSessionId = sid10
            store.updateScheduled(store.scheduledTasks[i])
        }
        var done10 = delegate(from: m10, to: w10b)
        done10.status = .done
        done10.summary = "3 处差异，见台账"
        done10.finishedAt = Date()
        try? p.insertDelegation(done10)
        store.beginTurn(sid: sid10, prompt: "对账有下文吗", ephemeral: false, cwd: nil,
                        unattended: false)
        let injected = mock.lastExtraSystemPrompt ?? ""
        _ = await waitUntil { store.runningTurns.isEmpty }
        let after10 = ((try? p.loadDelegations(toTask: w10b)) ?? []).first { $0.id == done10.id }
        check(!injected.isEmpty && injected.contains("【派活回执】")
              && injected.contains("3 处差异，见台账")
              && after10?.reportedAt != nil,
              "T-TEAM ㉔(doc⑤)回执: 有下文 ⇒ 注入段里有【派活回执】+ 那一行结论;"
              + " 这一轮成功收尾之后才标 `reported_at`(标在注入时, 那一轮崩了回执就永久丢了)"
              + " (实测 注入=\(injected.contains("【派活回执】"))"
              + " 已汇报=\(after10?.reportedAt != nil))")

        // ══ ㉕（doc ⑤）没说出话的那一轮 ⇒ **不标** ═══════════════════════════
        // 丢了回执比重复念一遍坏得多: 空回合那一轮人什么都没看见，标掉等于把这条回执吞了。
        var done10b = delegate(from: m10, to: w10b)
        done10b.status = .done
        done10b.summary = "第二件也完了"
        done10b.finishedAt = Date()
        try? p.insertDelegation(done10b)
        mock.scriptedReply = { _ in "" }          // 空回合
        store.beginTurn(sid: sid10, prompt: "还有吗", ephemeral: false, cwd: nil,
                        unattended: false)
        _ = await waitUntil { store.runningTurns.isEmpty }
        let after10b = ((try? p.loadDelegations(toTask: w10b)) ?? []).first { $0.id == done10b.id }
        check(after10b?.reportedAt == nil,
              "T-TEAM ㉕(doc⑤)空回合(一句话都没说) ⇒ 回执**不标**, 下一轮接着念"
              + " (实测 reported_at=\(String(describing: after10b?.reportedAt)))")
        mock.scriptedReply = { _ in "我看了一眼。" }

        // ══ ㉖（doc ⑤）一次最多念 5 条 —— 没念到的不丢 ═══════════════════════
        let m12 = addMain("第十二支队")
        _ = addWorker("攒活的", under: m12)
        let w12 = idOf("攒活的")
        for i in 0..<(DelegationLimit.maxReceipts + 1) {
            var d = delegate(from: m12, to: w12)
            d.status = .failed
            d.note = "第 \(i) 次没干成"
            d.finishedAt = Date().addingTimeInterval(Double(i))
            try? p.insertDelegation(d)
        }
        let rows12 = store.scheduler.unreportedReceipts(from: m12)
        let block12 = TeamPrompt.receiptBlock(rows12, workers: store.scheduledTasks
            .reduce(into: [UUID: ScheduledTask]()) { $0[$1.id] = $1 }, now: Date()) ?? ""
        check(rows12.count == DelegationLimit.maxReceipts
              && block12.split(separator: "\n").count == DelegationLimit.maxReceipts + 1,
              "T-TEAM ㉖(doc⑤)回执一次最多念 \(DelegationLimit.maxReceipts) 条(最新的在前);"
              + " 第 \(DelegationLimit.maxReceipts + 1) 条**不丢**, 只是排到下一轮"
              + " (实测取到 \(rows12.count) 条 / \(block12.split(separator: "\n").count) 行)")

        // ══ ㉗（doc ⑨）list_workers: 必带状态 + 缺口**分两级**说出来 ═════════════
        // ⚠️ P4 起「没写职责的 worker」**建不出来**了（`TeamViolation.workerWithoutDuty`，
        // 见 ㉛）—— 而这条缺口提示是给**存量坏行**留的（P4 之前建的、手改的配置）。
        // 所以夹具直接构造一行、不经 `addScheduled`：那个写路径现在正是要拒它的地方。
        let m11 = addMain("第十一支队")
        _ = addWorker("有职责没说明的", under: m11, duty: "查发票")
        var bare27 = ScheduledTask(id: UUID(), name: "只有名字的", prompt: "按派活单干",
                                   cron: "0 3 * * *", projectId: projId, continuous: false)
        bare27.kind = .assistant
        bare27.role = .worker
        bare27.parentId = m11
        bare27.description = ""
        let dossier11 = TeamPrompt.dossierBlock(main: task(m11)!, roster: store.scheduledTasks + [bare27],
                                                busy: [:], lastDone: [:], now: Date())
        check(dossier11.contains("（**没有写职责** —— 你只能从名字判断。）")
              && dossier11.contains("（只有一句职责，没有说明。）")
              && dossier11.contains("职责：查发票") && dossier11.contains("| 空闲 |"),
              "T-TEAM ㉗(doc⑨)list_workers: 每行必带状态; 两档缺口**分开说**(没有职责是异常态、"
              + "有职责没说明是信息少) —— 留白会让它把两者都读成「这人没什么特别的」,"
              + "而它们都是可行动的缺口(改派 / 先问人)")

        // ══ ㉘（doc ⑨）read_worker_ledger: 含完成状态 + 最近 20 行 + 1500 字截断 ═══
        // ⚠️ 夹具必须是**长成这样的**台账: 只有"最近 20 行"的短台账根本顶不到 1500 字，
        // 那条上限就成了恒真（第一次写这一格时实测只有 482 字，正是这个坑）。
        // 顶上去的是「完成状态」那一节 —— 它是唯一会随验收项线性变长的一节。
        var items28: [String] = ["- [!] 缺 3 月"]
        for i in 0..<80 { items28.append("- [x] 验收项 \(i) 的原文说明说明说明") }
        let ledgerLong = "## 目标\n对一遍 11 月发票\n\n## 完成状态\n"
            + items28.joined(separator: "\n") + "\n\n## 在跟踪\n- 等财务回信\n"
        let block28 = TeamPrompt.ledgerBlock(workerName: "有职责没说明的", ledger: ledgerLong)
        check(block28.count <= DelegationLimit.maxLedgerChars
              && block28.contains("完成状态") && block28.contains("[!] 缺 3 月")
              && block28.contains("最近 \(DelegationLimit.maxLedgerLines) 行")
              && block28.contains("等财务回信") && block28.contains("…还有"),
              "T-TEAM ㉘(doc⑨)read_worker_ledger: 目标 + 「完成状态」原文(带 [!] 这类标记) +"
              + " 最近 \(DelegationLimit.maxLedgerLines) 行, 总长 ≤ "
              + "\(DelegationLimit.maxLedgerChars) 字; 超长时**砍验收项、保尾巴**"
              + "(从尾部硬截会把最新那条动线藏起来 —— 第一版就是这么错的)"
              + " (实测 \(block28.count) 字 / 尾巴还在=\(block28.contains("等财务回信"))"
              + " / 说了还有几项=\(block28.contains("…还有")))")

        // ══ ㉙（doc ⑨）没台账 ⇒ 直说没有, 不编一份出来 ═══════════════════════
        let empty29 = TeamPrompt.ledgerBlock(workerName: "只有名字的", ledger: nil)
        check(empty29.contains("还没有台账"),
              "T-TEAM ㉙(doc⑨)没台账 ⇒ 说「还没有台账」; 编一份空模板会让 main 以为它跑过、"
              + "什么都没干 (实测「\(empty29)」)")

        // ══ ㉚ 三个工具名与扩展源码同源; dossier 文件名后缀两处同源 ═════════════
        // 前半: 面板那一行会展开工具名, 名字对不上 = 面板说谎。
        // 后半: Swift 写 `<spool>.team.json`、TS 读同一个公式 —— 漂了就是"工具在、数据读不到",
        // 而那种失败**零信号**(工具会回一句"这一轮没有队伍数据")。
        let extSrc = PiRpcTransport.delegateExtensionSource
        check(PiRpcTransport.delegateToolNames.allSatisfy { extSrc.contains("name: \"\($0)\"") }
              && extSrc.contains("const TEAM_SUFFIX = \"" + SchedulerService.teamDossierSuffix + "\""),
              "T-TEAM ㉚\(PiRpcTransport.delegateToolNames.count) 个工具名都能在扩展源码里找到"
              + " `name: \"…\"`; dossier 后缀两处同源(\(SchedulerService.teamDossierSuffix))")

        // ══ ㉛（doc P4）worker 职责必填 —— **域层也拦**，不只是保存按钮 ═══════════
        // 文档 §04: 「worker 必填（域层与保存都拦）」。只在表单拦的代价是 `addScheduled`
        // 这条公开写路径（将来的导入 / 批量编辑 / 飞书指令）能造出一个**选不出来**的人 ——
        // 而"选不出来"在主模型那一侧不报错，它看起来像"这个 worker 什么都能干"。
        let m13 = addMain("第十三支队")
        let bare13 = addWorker("没写职责的", under: m13, duty: "")
        let filled13 = addWorker("写清楚了的", under: m13, duty: "查发票与月度报表")
        check(bare13.ok == false && bare13.why == .workerWithoutDuty
              && !store.scheduledTasks.contains { $0.name == "没写职责的" }
              && filled13.ok && filled13.why == nil
              && store.scheduledTasks.contains { $0.name == "第十三支队" },
              "T-TEAM ㉛(doc P4)worker 职责必填: 没填**域层就拒**、库里没长出行(只在表单拦 ="
              + " 导入与批量编辑能造出一个选不出来的人); 补上就过; 队长选填"
              + " (实测 why=\(String(describing: bare13.why)) ok=\(bare13.ok)"
              + " / 补齐后=\(filled13.ok))")

        // ══ ㉜（doc P4）列表行: 平铺成一行时认得出谁是队长、谁是谁的人 ═══════════
        // 这是 P4 唯一能自动验的那一半（视图层没有门）: 措辞被抽成 `TeamRowText` 的纯函数,
        // 于是"worker 不写周期""孤儿写未归属""竖条只给队长"三件事都点得到。
        let lead13 = task(m13)!
        let worker13 = store.scheduledTasks.first { $0.name == "写清楚了的" }!
        var orphan13 = worker13
        orphan13.parentId = UUID()                    // main 被删之后留下的悬挂值
        var cron13 = lead13
        cron13.kind = .execute                        // 同一条任务换个档, 只借字段
        let lineLead = TeamRowText.identityLine(lead13,
                                                workers: store.scheduler.workerCount(of: lead13.id),
                                                parentName: nil)
        let lineWorker = TeamRowText.identityLine(worker13, workers: 0, parentName: lead13.name)
        let lineOrphan = TeamRowText.identityLine(orphan13, workers: 0, parentName: nil)
        // ⚠️ 人数只判"有这一格"，不判具体几: 具体那个数归 `workerCount`（列表直接用它），
        // 在这里把数字写死会让本条的红色**依赖 ㉛ 的夹具**（实测过: 职责那道判一去掉，
        // 多长出来的那个 worker 会把这里一起染红，而它本身没有错）。
        check(lineLead.contains("main") && lineLead.contains(" 个 worker")
              && lineWorker.hasPrefix("worker") && lineWorker.contains("归 \(lead13.name)")
              // worker 在 tick / 漏跑 / 补跑三处都被排除了 ⇒ cron 对它是占位值,
              // 写出来就是承诺一件永远不会发生的事。
              && !lineWorker.contains("每天")
              && lineOrphan.contains("未归属")
              && TeamRowText.isTeamLead(lead13)
              && !TeamRowText.isTeamLead(worker13)
              // Cron 档在存储上也是 main, 但它在队伍系统外面 —— 竖条给它就等于把
              // "这里有个队长"说给每一条 Cron 任务听。
              && !TeamRowText.isTeamLead(cron13),
              "T-TEAM ㉜(doc P4)列表行: worker 独立一行, 靠「归 X」认人(没有归属就写「未归属」);"
              + " worker 不写周期; 3px 竖条只给队长(\(lineLead) / \(lineWorker) / \(lineOrphan))")

        // ══ ㉝（doc P4）五档状态: 界面版四档各自说得清，「等回执」**不折叠** ═══════
        // 注入面把 `.awaiting` 说成"空闲"（能不能派的角度它确实闲着）; 界面上它必须说出来,
        // 否则"有一张单等我处理"只能靠翻回执才知道。
        let now33 = Date()
        let sRun33 = TeamRowText.stateWord(.running(since: now33.addingTimeInterval(-3 * 60)), now: now33)
        let sQueue33 = TeamRowText.stateWord(.queued(at: now33.addingTimeInterval(600)), now: now33)
        let sAwait33 = TeamRowText.stateWord(.awaiting(since: now33.addingTimeInterval(-5 * 60)), now: now33)
        let sIdle33 = TeamRowText.stateWord(.idle(lastActive: now33.addingTimeInterval(-3 * 86_400)), now: now33)
        check(sRun33 == "在跑 3 分钟" && sQueue33.hasPrefix("已排上 ")
              && sAwait33 == "等回执 5 分钟" && sIdle33 == "空闲 3 天"
              && TeamRowText.stateWord(.idle(lastActive: nil), now: now33) == "空闲"
              && TeamRowText.stateWord(.disabled, now: now33) == "已停用",
              "T-TEAM ㉝(doc P4)五档状态(界面版): 在跑 N 分钟 / 已排上 HH:mm / 等回执 N 分钟 /"
              + " 空闲 [N 天] / 已停用 —— 与注入面**同一判据**(`TeamState.of`)、措辞各写各的"
              + " (\(sRun33) / \(sQueue33) / \(sAwait33) / \(sIdle33))")
    }
}
