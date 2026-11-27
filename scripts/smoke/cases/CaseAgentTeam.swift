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
        // ⚠️ 界面词（2026-11-25 boss 定）: `管理` / `执行` 是两个身份在列表行上的短形式。
        // 这里判的是"认得出谁是队长、谁是谁的人"，所以只认这两枚**短标记**，不认完整名字
        // （`助理（管理）`那是菜单与身份胶囊的写法，240pt 的行里放不下）。
        check(lineLead.contains("管理") && lineLead.contains(" 个助理")
              && lineWorker.hasPrefix("执行") && lineWorker.contains("归 \(lead13.name)")
              // worker 在 tick / 漏跑 / 补跑三处都被排除了 ⇒ cron 对它是占位值,
              // 写出来就是承诺一件永远不会发生的事。
              && !lineWorker.contains("每天")
              && lineOrphan.contains("未归属")
              && TeamRowText.isTeamLead(lead13)
              && !TeamRowText.isTeamLead(worker13)
              // Cron 档在存储上也是 main, 但它在队伍系统外面 —— 竖条给它就等于把
              // "这里有个队长"说给每一条 Cron 任务听。
              && !TeamRowText.isTeamLead(cron13),
              "T-TEAM ㉜(doc P4)列表行: 执行助理独立一行, 靠「归 X」认人(没有归属就写「未归属」);"
              + " 执行助理不写周期; 3px 竖条只给管理助理(\(lineLead) / \(lineWorker) / \(lineOrphan))")

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

        // ══ ㉞（doc P5）团队页的范围: 全部 / 一支队 / 未归属 ═══════════════════
        // 泳道按状态分列之后，"这个人属于哪个范围"就只剩入口那道过滤在管 —— 三条各有独立的坏法:
        // 全部漏人（有的行哪一列都不进）/ 一支队不含队长本人（左侧写「4」而泳道里只有 3 张卡）/
        // 未归属把正常 worker 也吞进去（残队吞掉整队，而队长还在，于是"他手下没人"）。
        var orphan34 = ScheduledTask(id: UUID(), name: "孤儿", prompt: "按派活单干",
                                     cron: "0 3 * * *", projectId: projId, continuous: false)
        orphan34.kind = .assistant
        orphan34.role = .worker
        orphan34.parentId = UUID()               // main 被删之后留下的悬挂值
        orphan34.description = "查发票"
        let roster34 = [lead13, worker13, orphan34]
        let pAll34 = TeamBoardText.people(.all, all: roster34)
        let pTeam34 = TeamBoardText.people(.team(lead13.id), all: roster34)
        let pOrph34 = TeamBoardText.people(.orphans, all: roster34)
        check(pAll34.count == roster34.count
              && pTeam34.contains { $0.id == lead13.id }
              && pTeam34.contains { $0.id == worker13.id }
              && !pTeam34.contains { $0.id == orphan34.id }
              && pOrph34.map(\.id) == [orphan34.id],
              "T-TEAM ㉞(doc P5)团队页范围: 全部不漏人; 一支队**含队长本人**"
              + "(少了它, 左侧写「4」而泳道里只有 3 张卡); 未归属只装 parent 悬空/为空的 worker"
              + " (实测 全部 \(pAll34.count) / 本队 \(pTeam34.count) / 未归属 \(pOrph34.count))")

        // ══ ㉟（doc P5）列内排序: 不是按名字, 是按「最该被我看见的」 ════════════
        // 五档的键各不相同（起跑/到点/交活/最后动过），但都指向同一句人话。这条塌了的后果
        // 不是"顺序难看": 「三天没派过活」这条信息**只靠排序露面**，顺序一错它就沉底了。
        let now35 = Date()
        func person35(_ name: String, age: TimeInterval) -> ScheduledTask {
            var t = ScheduledTask(id: UUID(), name: name, prompt: "p", cron: "0 3 * * *",
                                  projectId: projId, continuous: false)
            t.kind = .assistant
            t.role = .worker
            t.description = "d"
            t.createdAt = now35.addingTimeInterval(age)   // 同键时的 tiebreaker
            return t
        }
        let rA35 = person35("A", age: -60), rB35 = person35("B", age: -120), rC35 = person35("C", age: -180)
        let runOrder35 = TeamBoardText.order([rA35, rB35, rC35], states: [
            rA35.id: .running(since: now35.addingTimeInterval(-5 * 60)),
            rB35.id: .running(since: now35.addingTimeInterval(-1 * 60)),
            rC35.id: .running(since: now35.addingTimeInterval(-30 * 60)),
        ])
        let qA35 = person35("Q1", age: -60), qB35 = person35("Q2", age: -120)
        let queuedOrder35 = TeamBoardText.order([qA35, qB35], states: [
            qA35.id: .queued(at: now35.addingTimeInterval(600)),
            qB35.id: .queued(at: now35.addingTimeInterval(120)),
        ])
        let aA35 = person35("W1", age: -60), aB35 = person35("W2", age: -120)
        let awaitOrder35 = TeamBoardText.order([aA35, aB35], states: [
            aA35.id: .awaiting(since: now35.addingTimeInterval(-2 * 60)),
            aB35.id: .awaiting(since: now35.addingTimeInterval(-20 * 60)),
        ])
        let iA35 = person35("I1", age: -60), iB35 = person35("I2", age: -120)
        let iC35 = person35("I3", age: -180)
        let idleOrder35 = TeamBoardText.order([iA35, iB35, iC35], states: [
            iA35.id: .idle(lastActive: now35.addingTimeInterval(-3_600)),
            iB35.id: .idle(lastActive: now35.addingTimeInterval(-10 * 86_400)),
            iC35.id: .idle(lastActive: nil),          // 从没跑过 = 最久没动 ⇒ 排最前
        ])
        let dA35 = person35("D1", age: -60), dB35 = person35("D2", age: -120)
        let offOrder35 = TeamBoardText.order([dA35, dB35], states: [
            dA35.id: .disabled, dB35.id: .disabled,
        ])
        // **档位是第一级键**（2026-11-27 泳道退役后新加的）: 混着喂进去，出来的次序必须是
        // 在跑 → 已排上 → 等回执 → 空闲 → 停用。泳道时代这件事由"人站在哪一列"物理保证，
        // 现在列没了，只能靠排序 —— 所以这条必须单独钉，否则同一组里"停用的排在在跑的前面"
        // 也没有任何东西会红。
        var all35: [UUID: TeamState] = [:]
        all35[rA35.id] = .running(since: now35.addingTimeInterval(-5 * 60))
        all35[qA35.id] = .queued(at: now35.addingTimeInterval(600))
        all35[aA35.id] = .awaiting(since: now35.addingTimeInterval(-2 * 60))
        all35[iA35.id] = .idle(lastActive: now35.addingTimeInterval(-3_600))
        all35[dA35.id] = .disabled
        let mixed35 = TeamBoardText.order([dA35, iA35, aA35, qA35, rA35], states: all35)
        check(runOrder35.map(\.name) == ["C", "A", "B"]        // 跑得久的浮上来
              && queuedOrder35.map(\.name) == ["Q2", "Q1"]      // 最快起跑的在上
              && awaitOrder35.map(\.name) == ["W2", "W1"]       // 等最久的在上
              && idleOrder35.map(\.name) == ["I3", "I2", "I1"]  // 最久没动的在上（nil = 从没跑过 ⇒ 最前）
              && offOrder35.map(\.name) == ["D2", "D1"]         // 停用没有停用时刻 ⇒ 按建人顺序（D2 建得早）
              // 混排: 喂进去的次序是 停用/空闲/等回执/已排上/在跑（故意的倒序），
              // 出来必须正过来 —— 这一条要是只靠"各档内部自己排"，永远会绿。
              && mixed35.map(\.name) == ["A", "Q1", "W1", "I1", "D1"],
              "T-TEAM ㉟(P5 定稿)组内排序=最该被看见的在上: **档位是第一级键**"
              + "(在跑→已排上→等回执→空闲→停用, 泳道退役后由排序保证, 原来由列位置保证);"
              + " 同档内: 在跑(跑得久)/已排上(到点早)/等回执(等得久)/空闲(最久没动, `nil` 最前)"
              + "/停用(无停用时刻 ⇒ 按建人顺序); 同键按 createdAt(tiebreaker 一漏, 同键两张卡每 tick 换位)"
              + " (实测 \(runOrder35.map(\.name)) / \(queuedOrder35.map(\.name))"
              + " / \(awaitOrder35.map(\.name)) / \(idleOrder35.map(\.name))"
              + " / 混排 \(mixed35.map(\.name)))")

        // ══ ㊱（定稿 P5）卡列数: **够几个摆几个, 卡片宽度恒定** ══════════════════
        // 2026-11-27 泳道退役，这条从"五列等宽怎么算"改成"一行摆几张"。
        // 判据只有一条: `teamCardWidth` 是**定稿宽度**，永不压缩 —— 宽度不够就少摆一张。
        // 压到 190 就会出现名字被省略号吃掉（"巡检北区"→"巡检北…"），所以列数不能靠挤。
        // 三个数是三个真实窗口算出来的（减侧栏 257、减内边距 32），不是凑的:
        //   1053 最窄 ⇒ 764 可用 ⇒ 3 张；1280 默认 ⇒ 991 ⇒ 4 张；≥1040 ⇒ 5 张（封顶）。
        let cols764 = TeamBoardText.cardColumns(available: 764)
        let cols991 = TeamBoardText.cardColumns(available: 991)
        let colsCap = TeamBoardText.cardColumns(available: 1040)
        let colsJustUnder = TeamBoardText.cardColumns(available: 1039)  // 差 1pt 就掉回 4 张
        let colsWide = TeamBoardText.cardColumns(available: 1400)
        let colsTiny = TeamBoardText.cardColumns(available: 150)        // 极窄：兜底 1，不是 0
        check(cols764 == 3 && cols991 == 4 && colsCap == 5 && colsJustUnder == 4
              && colsWide == 5 && colsTiny == 1
              && Tune.teamCardWidth == 200,
              "T-TEAM ㊱(P5 定稿)一行摆几张: 卡片固定 \(Int(Tune.teamCardWidth))pt **永不压缩**;"
              + " 可用 764(最窄窗口)⇒\(cols764) 张 / 991(默认窗口)⇒\(cols991) 张 /"
              + " 1040⇒\(colsCap) 张(封顶) / 1039⇒\(colsJustUnder) 张(临界就在这 1pt) /"
              + " 1400⇒\(colsWide) 张(不再多摆) / 150⇒\(colsTiny) 张(兜底, 不许是 0)")

        // ══ ㊶（P5 定稿）卡片三格数字与台账的退役 ══════════════════════════════
        // 2026-11-27 boss:「台账计算有点麻烦，能不能换成别的可以从 db 获取的指标」
        // ⇒ 第三格从「台账 · 验收 7/9」换成「交活」（`agent_delegations` 里 status='done' 的条数）。
        // 这条钉的是**格式化档位**（一个独立失败模式: 换档位写错，数字就从小变大或从大变小）:
        // 卡宽只有 200，三格并排每格约 58pt ⇒ 七位数会撑破格子并把邻格挤歪。
        // ⚠️ `0 → "—"` 与 `done → "—"` 是**同一条判据的另一面**（没发生过 ≠ 结果是 0），并在这里。
        let tokLabel = [TeamBoardText.tokenLabel(0), TeamBoardText.tokenLabel(860),
                        TeamBoardText.tokenLabel(1_200), TeamBoardText.tokenLabel(41_200),
                        TeamBoardText.tokenLabel(1_500_000)]
        var doneStat = TeamCardStat()
        let doneZero = doneStat.doneLabel
        doneStat.doneDelegations = 7
        check(tokLabel == ["—", "860", "1.20k", "41.2k", "1.5m"]
              && doneZero == "—" && doneStat.doneLabel == "7",
              "T-TEAM ㊶(P5 定稿)卡片三格: token 按量级换档(0⇒—, 860⇒860, 1200⇒1.20k,"
              + " 41200⇒41.2k, 1500000⇒1.5m)、交活 0⇒— / 7⇒7;"
              + " **第三格已从「台账」换成「交活」**（台账要每人读一次交接文件 + parse，"
              + " 是这一页唯一碰文件系统的地方 ⇒ 三格现在全是 db 聚合）"
              + " (实测 \(tokLabel) / \(doneZero) / \(doneStat.doneLabel))")

        // ══ ㊷（2026-11-27）头像：内置 10 个 emoji，显式优先、组内不重复、与数组顺序无关 ══
        // boss 现场: 助理全叫「助理 X」⇒ 名字首字恒是"助"，三张卡长得一模一样。
        // ⚠️ 这一组判的是**分配算法**（`TeamAvatar.assign`），不是"画出来了没有" ——
        //    算法错了的症状很轻（两张一样的脸），但根因是"某个键用了容器里的位置"或
        //    "用了 hashValue"，两者都不会崩、不会报错，只会静默换脸。
        func person(_ name: String, _ at: TimeInterval, avatar: String? = nil) -> ScheduledTask {
            var t = ScheduledTask(id: UUID(), name: name, prompt: "", cron: "0 9 * * *",
                                  projectId: nil, continuous: false)
            t.createdAt = Date(timeIntervalSince1970: at)
            t.avatar = avatar
            return t
        }
        let ten = (0..<10).map { person("助理\($0)", Double($0)) }
        let tenMap = TeamAvatar.assign(ten)
        let tenFaces = ten.compactMap { tenMap[$0.id] }
        check(TeamAvatar.all.count == 10 && Set(TeamAvatar.all).count == 10
              && tenFaces.count == 10 && Set(tenFaces).count == 10,
              "T-TEAM ㊷头像: 内置正好 10 个且互不相同; **10 个人的组内头像两两不同**"
              + " (越界就顺延而不是撞在一起) (实测 \(tenFaces))")

        // 显式设置优先，且自动的让路 —— 否则"我亲手选了 🐧，它却显示成别的"。
        //
        // ⚠️ **人数必须 ≤ 9**（表只有 10 张脸，钉住一张就剩 9 张）。第一版拿 `ten`（10 个）
        //    再钉一个 ⇒ 11 个人抢 10 张脸，**必然有一张重脸**，断言时红时绿 ——
        //    UUID 是随机的，撞不撞全看运气（2026-11-27 实测翻红：🐧 出现 2 次）。
        //    那是判据写错了，不是算法错了：`assign` 的契约本来就只保证 ≤ 张数时互不相同。
        let six = Array(ten.prefix(6))
        let pinned = person("钉住的", 99, avatar: "🐧")
        let pinnedMap = TeamAvatar.assign(six + [pinned])
        let pinnedAutos = six.compactMap { pinnedMap[$0.id] }
        check(pinnedMap[pinned.id] == "🐧"
              && pinnedMap.values.filter { $0 == "🐧" }.count == 1
              && pinnedAutos.count == 6 && Set(pinnedAutos).count == 6
              // 单张那条路（检查器 / 不在组里）也要认显式值，否则"卡片上是企鹅、检查器里是别的"。
              && TeamAvatar.of(pinned) == "🐧",
              "T-TEAM ㊷头像: 显式设置的那张必须归它, 且自动分配的**不许再撞上去**"
              + " (实测 \(pinnedMap[pinned.id] ?? "nil"), 🐧 出现 "
              + "\(pinnedMap.values.filter { $0 == "🐧" }.count) 次 / 自动 \(pinnedAutos))")

        // 与**数组顺序**无关 —— 团队页那份 `order(_:)` 是按状态排的：
        // 拿它分配的话，"谁在跑"会改变"谁是猫"，而人靠图案认人，图案不许跟着状态跑。
        //
        // ⚠️ 这条**测不出**"用了 hashValue"：Hashable 的随机种子是**每进程一次**的，
        //    同进程内 `hashValue` 稳定，所以单次冒烟永远绿。那半全靠 `TeamAvatar.seed`
        //    上的注释禁止 + 代码评审 —— 别在这里假装守住它。
        //    能守的是"输入顺序不许影响结果"，以及 seed 落在合法区间（防越界崩溃）。
        let reversedMap = TeamAvatar.assign(ten.reversed())
        check(ten.allSatisfy { tenMap[$0.id] == reversedMap[$0.id] }
              && ten.allSatisfy { (0..<TeamAvatar.all.count).contains(TeamAvatar.seed(for: $0.id)) },
              "T-TEAM ㊷头像: 换输入顺序不许换脸 "
              + "(分配只许读任务自己的 id, 不许读它在数组里排第几), seed 必须落在表内")

        // 脏值（老库手改 / 以后删掉某个图案）⇒ 当没设过、回落自动，**不许崩也不许留空**。
        let dirty = person("脏的", 50, avatar: "🦄")
        let dirtyFace = TeamAvatar.assign([dirty])[dirty.id]
        check(dirtyFace != nil && TeamAvatar.isBuiltIn(dirtyFace ?? "")
              && !TeamAvatar.isBuiltIn("🦄"),
              "T-TEAM ㊷头像: 库里存了不认识的图案(🦄)时回落自动分配, 不崩、不留空"
              + " (实测 \(dirtyFace ?? "nil"))")


        // ══ ㊲（doc P5）卡片第二行与统计行: 归属是卡片上唯一还能认出"谁是谁的人"的地方 ══
        // 一支队伍的卡和"未归属"的卡混在一屏里 —— 卡片上不写归属，二十张卡就是认不出。
        //
        // ⚠️ 2026-11-27 出图实测后**归属与状态分家**（这是本条被改写的原因）:
        //    旧 `cardSubtitle` 返回「归属 · 时态」（"管理 · 4 分钟"），而它下面紧接着
        //    还有一行状态「在跑 4 分钟」—— 同一件事在同一张卡上说了两遍，读起来是复读。
        //    现在: 归属行只写归属，时长只在状态行出现一次。
        let subLead37 = TeamBoardText.cardSubtitle(lead13, parentName: nil)
        let subWorker37 = TeamBoardText.cardSubtitle(worker13, parentName: lead13.name)
        let subOrphan37 = TeamBoardText.cardSubtitle(orphan34, parentName: nil)
        // 状态行 = `cardStateLine`，不是 `TeamRowText.stateWord` 直通 —— 差别只在停用那一档:
        // 后者写标签（"已停用"），前者写**后果**（"派了会被拒"）。判据在 `TeamRule`。
        let stateRun37 = TeamBoardText.cardStateLine(
            .running(since: now35.addingTimeInterval(-4 * 60)), now: now35)
        let stateOff37 = TeamBoardText.cardStateLine(.disabled, now: now35)
        let stateIdle37 = TeamBoardText.cardStateLine(.idle(lastActive: nil), now: now35)
        // 统计行改版后是**分块 chip**（要分色），所以断言的是结构不是一句话。
        // ⚠️ 这条同时钉住"只列非零档 / 队伍数 >1 才出现"，以及"颜色只给状态档"——
        //    前两条迁自旧 `statsLine` 的判据，第三条是 chip 化之后新增的（否则 chip 全一个色，
        //    "有几件事在动"就得逐个读字）。
        let chips37 = TeamBoardText.statChips(total: 6, teams: 2, cards: [.running: 2, .idle: 4])
        let chipsOne37 = TeamBoardText.statChips(total: 3, teams: 1, cards: [.idle: 3])
        let chipsText37 = chips37.map { "\($0.value) \($0.label)" }
        let chipsOneText37 = chipsOne37.map { "\($0.value) \($0.label)" }
        // ⚠️ 13 这个**措辞上界**是泳道时代按最窄列宽 118 定的（可用 95pt）。
        // 2026-11-27 卡片固定 200、可用约 176pt ⇒ 能放 18 字左右，上限于是**偏保守**。
        // 没放宽是有意的: 归属行的价值在"一眼认出谁是谁的人"，不是把格子塞满；
        // 而卡宽将来若再收，措辞不用跟着返工。超了就是尾部截断，截掉的恰恰是名字后半截。
        // 留在冒烟里是因为它是一条**能变红的**约束: 谁把措辞写长，这条当场红，不用等人去出图。
        // 状态行给 12 —— 最长的一条是「停用 · 派了会被拒」（10 字）。
        let all37 = [subLead37, subWorker37, subOrphan37]
        let allState37 = [stateRun37, stateOff37, stateIdle37]
        check(subLead37 == "管理"                       // 队长写角色短标记
              && subWorker37 == lead13.name              // 执行助理写归属名（不是"执行"）
              && subOrphan37 == "未归属"                  // 悬挂值（main 被删）说残队，不写角色
              // 归属行**不许再带时长** —— 这是这次改写的全部意义
              && !subLead37.contains("分钟") && !subOrphan37.contains("分钟")
              && all37.allSatisfy { $0.count <= 13 }
              && stateRun37 == "在跑 4 分钟"
              && stateOff37 == "停用 · 派了会被拒"        // 后果，不是 stateWord 的"已停用"
              && stateIdle37 == "空闲"
              && allState37.allSatisfy { $0.count <= 12 }
              && chipsText37 == ["6 个助理", "2 支队伍", "2 在跑", "4 空闲"]
              // 只有一支队伍时不报「1 支队伍」: 那是每个单队伍用户的默认状态，报了就是白占一格。
              && chipsOneText37 == ["3 个助理", "3 空闲"]
              // 颜色只给状态档 —— "7 个助理"是数，不是状态，上色会让"在跑"那格不再突出。
              && chips37.filter { $0.stage != nil }.map(\.label) == ["在跑", "空闲"],
              "T-TEAM ㊲(doc P5)卡片第二行=**只写归属**(队长写「管理」、执行助理写归属名、"
              + " 悬挂写未归属) —— 时态已分家到状态行，同一张卡不说两遍时长;"
              + " 状态行停用那一档写后果「派了会被拒」而不只写标签; 顶栏 chip 只列非零档、"
              + " 队伍数 >1 才出现、颜色只给状态档"
              + " (实测 \(subLead37) / \(subWorker37) / \(subOrphan37)"
              + " / \(stateRun37) / \(stateOff37) / \(stateIdle37) / \(chipsText37))")

        // ══ ㊳（2026-11-25）"自己起的那一轮"也算在跑 —— 补的是**没有派活单**的那条路 ══════
        // boss 实机对比: worker 走满 已排上 → 在跑 → 等回执 → 空闲，而 main 的卡一动不动。
        // 根因: 五档判据只读派活单，而 main 永远不会成为单据的 `to`（域层不许派给 main）。
        // 但事实系统里是有的 —— 它那场日志会话在 `runningTurns` 里（派活闸门用的同一个判据）。
        // 真链路那一半（下面最后一条）判的是**起点落库的顺序**: 起点写在 `runningTurns.insert`
        // 之后的话，`didSet` 那一拍算出来是空闲，而下一次刷新要等到收口 ⇒ 整轮都停在空闲上。
        let liveAt38 = now35.addingTimeInterval(-7 * 60)
        var dRun38 = delegate(from: lead13.id, to: worker13.id)
        dRun38.status = .running
        dRun38.startedAt = liveAt38
        var off38 = lead13
        off38.enabled = false
        // 真链路: 一场助理日志会话起跑 ⇒ 团队页这一刻就该翻到「在跑」（不等收口）
        let log38 = UUID()
        store.scheduler.bindLogSession(taskId: lead13.id, logId: log38)
        store.beginTurn(sid: log38, prompt: "安排一下今天", ephemeral: false, cwd: nil,
                        unattended: false)
        let start38 = store.turnStartedAt(sessionId: log38)
        let wired38 = store.scheduler.teamState(of: lead13.id)
        check(TeamState.of(lead13, busy: [:], awaiting: nil, live: liveAt38)
                == .running(since: liveAt38)
              // 单据优先: worker 被派活时"单据在跑"与"它的会话在跑"同时成立 ⇒ 取单据那个准时刻
              // （`started_at` 从认领那一刻算，`live` 只是"这一轮什么时候起的"）。
              && TeamState.of(worker13, busy: [worker13.id: dRun38], awaiting: nil, live: now35)
                == .running(since: liveAt38)
              // 停用压过一切 —— 它就是「派了会被拒」那一档
              && TeamState.of(off38, busy: [:], awaiting: nil, live: liveAt38) == .disabled
              // 没在自己跑 ⇒ 还是空闲（守"别把 live 写成恒真"那一面）
              && TeamState.of(lead13, busy: [:], awaiting: nil, live: nil)
                == .idle(lastActive: lead13.lastRunAt)
              // 真链路(起跑 ⇒ 刷新 ⇒ 翻档), 起点就是 `beginTurn` 记的那个
              && start38 != nil && wired38 == .running(since: start38!),
              "T-TEAM ㊳(2026-11-25)自己那一轮也算在跑: 无派活单 + 会话在跑 ⇒ 在跑(起点 = 起跑时刻);"
              + " 单据在跑时取单据的时刻; 停用压过在跑; 没跑仍是空闲;"
              + " 真起跑一场 ⇒ 团队页当场翻档(实测 \(wired38))")

        // ══ ㊴（2026-11-25）队伍色: 同队同色 / 没有队伍就没色 / **同屏的队两两不同色** ══════
        // boss: 「不同的团队，应该有颜色区分」。判据里**刻意不含**"某队等于某个色" ——
        // 那是配色不是判据，写进去以后加一个颜色就全红。
        // 第一版按 uuid 哈希取模，六色两支队伍有 1/6 概率撞成同色 ⇒ 改成"同屏排位"，
        // 于是"互不相同"本身可以当判据（撞了就是用户提的那件事没做到）。
        let teamIds39 = (0..<5).map { _ in UUID() }
        let ids39 = [lead13.id] + teamIds39
        let map39 = TeamBoardText.tintIndexMap(teamIds: ids39)
        // 六支（色板也是六）⇒ 六个下标两两不同；超过六支才回绕
        let map39Full = TeamBoardText.tintIndexMap(teamIds: (0..<CodexTheme.teamTints.count).map { _ in UUID() })
        let map39More = TeamBoardText.tintIndexMap(
            teamIds: (0..<(CodexTheme.teamTints.count + 3)).map { _ in UUID() })
        check(TeamBoardText.cardTintIndex(worker13, parentIsAlive: true, tintMap: map39)
                == map39[lead13.id]
              && TeamBoardText.cardTintIndex(lead13, parentIsAlive: false, tintMap: map39)
                == map39[lead13.id]
              // 悬挂的 parentId（main 被删）⇒ 没色，与卡片第二行的「未归属」同一个判据
              && TeamBoardText.cardTintIndex(orphan13, parentIsAlive: false, tintMap: map39) == nil
              // **互不相同**: 队伍数没超色板就该一张脸一个色（守"退化成恒 0 / 撞色"两种改法）
              && Set(map39.values).count == min(ids39.count, CodexTheme.teamTints.count)
              && Set(map39Full.values).count == CodexTheme.teamTints.count
              && map39More.values.allSatisfy { (0..<CodexTheme.teamTints.count).contains($0) }
              // 与**传入顺序**无关（看板按创建序排 `mains`，新建一支不该让别人换色）
              && TeamBoardText.tintIndexMap(teamIds: ids39.reversed()) == map39,
              "T-TEAM ㊴(2026-11-25)队伍色: 下属与队长同色、孤儿无色、"
              + " \(ids39.count) 支队伍 \(Set(map39.values).count) 个互不相同的色"
              + "（色板 \(CodexTheme.teamTints.count) 个）、与传入顺序无关")

        // ══ ㊵（2026-11-25）列表行序 + 分组: 队长在前 / 它的人紧跟 / 孤儿原地不动 ══════════
        // boss 实机: 「助理 Main」被它自己的两个 worker 压在下面。源顺序是
        // `created_at DESC`（新的在上），而 **worker 一定比它的队长晚建** ⇒ 必然排在队长上面，
        // 而它头顶那个 `↳` 说的是"我属于上面那个人" ⇒ 读起来是"归上一个队的最后一行"。
        // 与 ㉜（行**措辞**）/ ㉝ 不同: 这条判的是"谁挨着谁"，措辞一个字都不改。
        // 后来又补了第二半（同一件事）: **只排序不画边界**等于瞎认亲 —— 排完之后队尾那条 cron
        // 紧贴着队员，看起来就是这支队的第三个人（boss:「一个 cron 为什么会在客户回访的 team 里面」）。
        // 所以判据落在**组**上: 组边界才是那 3px 竖条能画出来的东西。
        let raw40 = [worker13, orphan13, lead13]      // 源顺序: 两个 worker 都在队长上面
        let ord40 = TeamRowText.listOrder(raw40)
        let groups40 = TeamRowText.listGroups(raw40)
        check(ord40.map(\.id) == [orphan13.id, lead13.id, worker13.id]
              // 不丢不增: 输出必须是输入的**一个排列**（这条守的是"重排顺手吃掉了行"）
              && Set(ord40.map(\.id)) == Set(raw40.map(\.id)) && ord40.count == raw40.count
              // 空表 / 单行不炸（列表空态与只有一个队长时走同一个 ForEach）
              && TeamRowText.listOrder([]).isEmpty
              && TeamRowText.listOrder([lead13]).map(\.id) == [lead13.id]
              // 组: 第一个恒是队长，除非这一组就它自己一行（独行侠 / cron / 孤儿）
              && groups40.allSatisfy { g in !g.isEmpty && (g.count == 1 || TeamRowText.isTeamLead(g[0])) }
              // 队长的组里**只有他自己的人**，且都在他后面 —— 竖条画的就是这一段
              && groups40.contains { $0.first?.id == lead13.id && $0.dropFirst().map(\.id) == [worker13.id] }
              // 平铺回来必须与 `listOrder` 逐位相同（两个入口、一份判据，不许分叉）
              && groups40.flatMap { $0 }.map(\.id) == ord40.map(\.id),
              "T-TEAM ㊵(2026-11-25)列表行序: 队长在前、它的人紧跟其后、孤儿原地不动;"
              + " 分组: 组首是队长、组尾到此为止（实测 \(ord40.map(\.name).joined(separator: " / "))"
              + " · \(groups40.map { $0.count }.map(String.init).joined(separator: "+")) 行/组）")
    }
}
