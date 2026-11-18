//
//  CaseAssistantApproval —— 助理线的两级审批（2026-11-18）
//
//  背景：账本围栏（"只许写账本这一份"）整层删掉了 —— 助理后续跑在**独立的 Mac 主机**上，
//  那台机器整个就是给它用的，"项目外"这个说法在那边不成立；而围栏把正常干活也堵死了
//  （真机 11:04:49：巡检轮连 `ls` 都被拒）。安全边界改到**人**这一侧，两级：
//    ① 工具级：助理会话**恒不弹卡** —— 改个文件就问一次是噪音，不是保护；
//    ② 方案级：要动手的大事写成带方案的结论，人点「采纳并执行」才起执行轮（起手快照）。
//
//  这一条钉的是"很容易被写回去"的三件事：
//    · 审批开关又被全局值带跑（助理会话必须无视 `store.askApproval`）；
//    · 普通会话被连坐（全局开关不能因为助理而被关掉）；
//    · "没绑项目就不能执行"那道硬门又长回来（独立主机场景根本没有项目目录）。
//
//  反例口径（待本轮实测后回填）：
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseAssistantApproval() async {
        let dir = fixtureDir("p19approval")
        print("== T-ASSISTANTAPPROVAL 助理线两级审批（工具级恒关 / 无项目也能执行）==")

        let mock = MockTransport()
        mock.scriptedReply = { _ in "第 1 步 看看\n第 2 步 收工\nRESULT: DONE\nSUMMARY: 好了" }
        let store = ChatStore(transport: mock, dbPath: dir + "/p19approval.db",
                              managedExtensionsDir: dir + "/ext")

        /// 时间线里出现过几次（`replayMessages` 是真源，别去读别处）。
        func timelineCount(_ needle: String, in sid: UUID, of s: ChatStore) -> Int {
            s.replayMessages(for: sid).reduce(0) { acc, m in
                guard case .text(let t) = m.content else { return acc }
                return acc + (t.contains(needle) ? 1 : 0)
            }
        }

        // 任务**故意不绑项目** —— 正是"独立主机"那种配置。
        store.addScheduled(name: "值班助理", prompt: "盯着 CI", cron: "0 0 1 1 *",
                           projectId: nil, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "值班助理" }),
              let logId = store.scheduler.ensureLogSession(for: store.scheduledTasks[ai]) else {
            check(false, "T-ASSISTANTAPPROVAL 前置: 任务与日志会话就位")
            return
        }
        // ⚠️ `ensureLogSession` **只建会话、不写回 `logSessionId`** —— 真实路径里 fire / 飞书
        // 入口都会紧跟着调一次 `bindLogSession`。漏这一步的话，下面的判据会以为
        // "这只是一场普通会话"（`isAssistantLogSession` 靠任务表的 `logSessionId` 反查）。
        store.scheduler.bindLogSession(taskId: store.scheduledTasks[ai].id, logId: logId)

        // ══ ① 判据本身（纯查表） ══════════════════════════════════════════
        check(store.scheduler.isAssistantLogSession(logId),
              "T-ASSISTANTAPPROVAL ①助理的日志会话认得出 —— 它是「恒不弹卡」的唯一判据，认不出就等于没关")
        check(!store.scheduler.isAssistantLogSession(UUID()),
              "T-ASSISTANTAPPROVAL ①普通会话不许被认成助理会话（认宽了 = 全局审批被人悄悄关掉）")

        // ══ ② 助理会话: 全局开关**开着**，下发的仍然必须是关 ═══════════════
        // 这一对必须成对: 只判"助理是 false"的话，一个恒 false 的实现也能全绿。
        store.askApproval = true
        store.beginTurn(sid: logId, prompt: "在吗", ephemeral: false, cwd: nil, unattended: false)
        check(mock.lastAskApproval == false,
              "T-ASSISTANTAPPROVAL ②助理会话恒不弹卡（全局开关 true 也一样，实际下发 \(String(describing: mock.lastAskApproval))）")

        // ══ ③ 普通会话: 跟随全局（不许被②连坐） ════════════════════════════
        let plain = UUID()
        store.beginTurn(sid: plain, prompt: "你好", ephemeral: false, cwd: nil, unattended: false)
        check(mock.lastAskApproval == true,
              "T-ASSISTANTAPPROVAL ③普通会话照旧跟随开关（实际下发 \(String(describing: mock.lastAskApproval))）")

        // ══ ④ 巡检轮（unattended）仍然关 —— 回归，这条从来没错过 ═══════════
        store.beginTurn(sid: plain, prompt: "到点跑", ephemeral: false, cwd: nil, unattended: true)
        check(mock.lastAskApproval == false,
              "T-ASSISTANTAPPROVAL ④巡检轮恒关（弹卡 = 任务死锁到超时）")

        // ══ ⑤ 没绑项目也能「采纳并执行」 ══════════════════════════════════
        // **换一台 store**：②③ 那几轮的 `runningTurns` 还占着 logId（mock 不自动收尾），
        // `startExecution` 会以"这场任务的回合还在跑"拒 —— 那条拒因和"没绑项目"长得完全
        // 不像，会把人带偏到一个不存在的问题上。
        let mockExec = MockTransport()
        mockExec.scriptedReply = { _ in "第 1 步 看看\n第 2 步 收工\nRESULT: DONE\nSUMMARY: 好了" }
        let storeExec = ChatStore(transport: mockExec, dbPath: dir + "/p19approval-exec.db",
                                  managedExtensionsDir: dir + "/ext-exec")
        storeExec.addScheduled(name: "值班助理2", prompt: "盯着 CI", cron: "0 0 1 1 *",
                               projectId: nil, kind: .assistant)
        guard let ai2 = storeExec.scheduledTasks.firstIndex(where: { $0.name == "值班助理2" }),
              let log2 = storeExec.scheduler.ensureLogSession(for: storeExec.scheduledTasks[ai2])
        else {
            check(false, "T-ASSISTANTAPPROVAL ⑤前置: 第二台 store 的任务与日志会话就位")
            return
        }
        storeExec.scheduler.bindLogSession(taskId: storeExec.scheduledTasks[ai2].id, logId: log2)
        let fid = UUID()
        let finding = AgentFinding(id: fid, taskId: storeExec.scheduledTasks[ai2].id, sourceId: UUID(),
                                   sessionId: log2, title: "CI 连续三次失败", body: "断言过期",
                                   evidence: "[1]", plan: [WatchPlanStep(n: 1, text: "看看日志"),
                                                           WatchPlanStep(n: 2, text: "改断言")],
                                   planRev: 1, severity: "action", fingerprint: "fp-approval",
                                   status: .open, createdAt: Date())
        try? storeExec.persistence?.upsertFinding(finding)
        storeExec.reloadFindings()
        let rejected = storeExec.startFindingExecution(fid)
        check(rejected == nil,
              "T-ASSISTANTAPPROVAL ⑤没绑项目也能起执行（硬门已删；实际拒因: \(rejected ?? "nil")）")

        // 执行轮要真的起来，且守卫带的是这份方案的步骤号
        var status: FindingStatus = .open
        for _ in 0..<120 {
            status = storeExec.findings.first(where: { $0.id == fid })?.status ?? .open
            if status == .resolved || status == .failed { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        check(mockExec.lastExecutionGuard?.findingId == fid,
              "T-ASSISTANTAPPROVAL ⑤执行回合挂上了守卫（挂不上 = 步骤围栏与红线全程没生效，而界面照跑）")
        check(mockExec.lastExecutionGuard?.allowedSteps == [1, 2],
              "T-ASSISTANTAPPROVAL ⑤守卫带的是**这份方案**的步骤号（批了哪几步就只做哪几步）")

        // 没有项目 ⇒ 没有快照。**必须说出来**，否则人点「回滚」时会以为按钮坏了。
        check(storeExec.findings.first(where: { $0.id == fid })?.undoPath == nil,
              "T-ASSISTANTAPPROVAL ⑤没项目就不落快照路径（落一个假路径 = 「回滚」按钮变成谎话）")
        check(timelineCount("这次不做快照", in: log2, of: storeExec) >= 1,
              "T-ASSISTANTAPPROVAL ⑤时间线里明说「这次不做快照、不能整轮回滚」")

        // ══ ⑥ 围栏不许长回来（源码级） ════════════════════════════════════
        // 判据打在**定义**上而不是"行为"上: 删掉的东西被谁顺手加回来，行为断言会跟着一起绿。
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = (try? String(contentsOfFile: repo.appendingPathComponent("mangox/Agent/Redline.swift").path,
                               encoding: .utf8)) ?? ""
        check(!src.contains("围栏：目标落在任务项目之外"),
              "T-ASSISTANTAPPROVAL ⑥写入围栏那句拒绝理由不许回来（助理跑在专属机器上，「项目外」不成立）")
        check(src.contains("红线：凭据目录不许写") && src.contains("红线：系统目录不许写"),
              "T-ASSISTANTAPPROVAL ⑥红线**一条都没放宽**（删围栏不等于删红线 —— 这是最容易混的一步）")
    }
}
