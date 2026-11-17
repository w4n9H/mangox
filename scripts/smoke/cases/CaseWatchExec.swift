//
//  CaseWatchExec.swift
//  P19 S6 · 执行段：红线 / 写围栏 / 步骤围栏 / 快照 / 收尾判定
//
//  ⚠️ 这一批的**判据全落在纯函数上，而唯一"真链路"那条在审批桥上** —— 两者都要:
//    · 纯函数（`Redline` / `ExecGate` / `parseResult`）回答"这条规矩是什么"；
//    · 审批桥（`handleExtensionUIRequest`）回答"它有没有真的接上" —— 前者全绿而后者没接，
//      表现是一模一样的绿灯，而 `rm -rf /` 会照跑。
//
//  反例预测（改坏之后哪几条该红）：
//    · 红线判据挪到 `approvalMode.judgesByRisk` 之后 ⇒ ④ 红（全放行档会放行 `rm -rf /`）；
//    · 红线判据挪到 `toolCards` 守卫之后 ⇒ ⑤ 红（没有卡的那条调用会 Allow）；
//    · 去掉"没声明步骤号也算跑偏" ⇒ ⑦ 红；
//    · 收尾判定把 `unclear` 记成 resolved ⇒ ⑨ 红。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseWatchExec() async {
        print("== T-WATCHEXEC P19 执行段 (红线 / 围栏 / 跑偏 / 收尾) ==")

        // 夹具重定向: 绝不能往真实的 ~/.mangox/undo 里写 tar（同 agentRootOverride 那条纪律）
        let dir = fixtureDir("p19exec")
        WatchExecService.undoRootOverride = dir + "/undo"
        defer { WatchExecService.undoRootOverride = nil }

        // MARK: ① 红线（命令级）：命中的一律拒

        let denied = [
            "rm -rf /", "rm -fr /", "rm  -rf   /", "rm -rf ~/work", "sudo ls",
            "csrutil disable", "mkfs.ext4 /dev/disk2", "diskutil eraseDisk APFS x /dev/disk2",
            "shutdown -h now", "git push --force origin main", "git push -f",
            "cat ~/.ssh/id_rsa", "cat /Users/moofs/.aws/credentials",
            ":(){ :|:& };:",
        ]
        for cmd in denied {
            check(Redline.denyReason(forCommand: cmd) != nil,
                  "T-WATCHEXEC ①红线该拒: `\(cmd)` —— 漏掉一条等于给它留了一条无人值守的路")
        }
        // 反方向: 正常命令不许被误伤（误伤的表现是"执行轮什么都干不了"，而人会以为是权限问题）
        let allowed = ["ls -la", "git status", "swift build 2>&1 | tail -5", "rm -rf ./build",
                       "cat Package.swift"]
        for cmd in allowed {
            check(Redline.denyReason(forCommand: cmd) == nil,
                  "T-WATCHEXEC ①正常命令不许误伤: `\(cmd)` 实测被判 "
                  + (Redline.denyReason(forCommand: cmd) ?? "放行"))
        }

        // MARK: ② 写围栏（工具那条路）

        let proj = dir + "/proj"
        try? FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        check(Redline.denyReason(forWrite: proj + "/a.txt", projectPath: proj) == nil,
              "T-WATCHEXEC ②项目内写入放行（不然执行轮连自己项目都改不了）")
        check(Redline.denyReason(forWrite: "a.txt", projectPath: proj) == nil,
              "T-WATCHEXEC ②相对路径按项目根解 ⇒ 放行（执行轮的 cwd 就是项目根）")
        check(Redline.denyReason(forWrite: "../elsewhere.txt", projectPath: proj) != nil,
              "T-WATCHEXEC ②`../` 逃出项目必须拒 —— 这是围栏最容易被绕开的一种写法")
        check(Redline.denyReason(forWrite: "/tmp/other.txt", projectPath: proj) != nil,
              "T-WATCHEXEC ②项目外绝对路径拒")
        check(Redline.denyReason(forWrite: "/usr/local/bin/x", projectPath: proj) != nil,
              "T-WATCHEXEC ②系统目录恒拒（即便人授权过这一份方案）")
        check(Redline.denyReason(forWrite: "~/.ssh/authorized_keys", projectPath: proj) != nil,
              "T-WATCHEXEC ②凭据目录恒拒")

        // MARK: ③ 写围栏（bash 重定向那条路 —— 围栏只管 write 工具就是漏了一半）

        check(Redline.denyReason(forCommand: "echo x > /etc/hosts", projectPath: proj) != nil,
              "T-WATCHEXEC ③`>` 重定向到系统目录必须拒（命令里一个红线词都没有）")
        check(Redline.denyReason(forCommand: "echo x >> ../out.txt", projectPath: proj) != nil,
              "T-WATCHEXEC ③`>>` 也要认（只认 `>` 等于留一个字母的口子）")
        check(Redline.denyReason(forCommand: "swift build > build.log 2>&1",
                                 projectPath: proj) == nil,
              "T-WATCHEXEC ③项目内重定向放行, 且 `2>&1` 不算文件目标（认错就会全线误伤）")

        // MARK: ④ 审批桥真链路: 全放行档也拦得住红线

        let g = ExecutionGuard(projectPath: proj, allowedSteps: [1, 2], findingId: UUID())
        let tFull = PiRpcTransport()
        tFull.updateApprovalMode(.autoAllow)      // **全放行档**: 判据必须照样拒
        tFull.updateExecutionGuard(g)
        tFull.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"第 1 步 清理构建产物\n"}}"#)
        tFull.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c_x1","toolName":"bash","args":{"command":"rm -rf /"}}"#)
        tFull.handleRPCLine(#"{"type":"extension_ui_request","id":"u_x1","method":"select","title":"MANGOX|APPROVE|c_x1|bash|rm -rf /"}"#)
        check(tFull.sentCommands.contains { ($0["type"] as? String) == "extension_ui_response"
                                            && ($0["value"] as? String) == "Deny"
                                            && ($0["id"] as? String) == "u_x1" },
              "T-WATCHEXEC ④红线必须真的回 Deny —— 全放行档也是（§03: 任何档位、任何授权都不放行）")
        check(tFull.execActions[1]?.result == "denied_by_redline",
              "T-WATCHEXEC ④被拦的那条要落痕（实际:\(tFull.execActions[1]?.result ?? "nil")）—— "
              + "收尾靠它判 failed, 没它就变成「模型说做完了」")

        // 对照: 同一条守卫下, 正常命令照样放行（否则"红线生效"是靠"什么都拒"实现的）
        let tOk = PiRpcTransport()
        tOk.updateApprovalMode(.autoAllow)
        tOk.updateExecutionGuard(g)
        tOk.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"第 2 步 跑构建\n"}}"#)
        tOk.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c_x2","toolName":"bash","args":{"command":"swift build"}}"#)
        tOk.handleRPCLine(#"{"type":"extension_ui_request","id":"u_x2","method":"select","title":"MANGOX|APPROVE|c_x2|bash|swift build"}"#)
        check(tOk.execActions[2]?.result == "allowed",
              "T-WATCHEXEC ④对照组: 已授权步骤里的正常命令放行（实际:\(tOk.execActions[2]?.result ?? "nil")）")

        // MARK: ⑤ 没有卡片的调用也拦得住（红线在 toolCards 守卫之前）

        let tNoCard = PiRpcTransport()
        tNoCard.updateApprovalMode(.autoAllow)
        tNoCard.updateExecutionGuard(g)
        tNoCard.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"第 1 步\n"}}"#)
        // ⚠️ 不喂 tool_execution_start ⇒ 没有卡片; 旧代码在这条路上直接 `Allow`
        tNoCard.handleRPCLine(#"{"type":"extension_ui_request","id":"u_x3","method":"select","title":"MANGOX|APPROVE|c_x3|bash|rm -rf ~/Documents"}"#)
        check(tNoCard.sentCommands.contains { ($0["value"] as? String) == "Deny" },
              "T-WATCHEXEC ⑤卡片缺失时也必须拒 —— 那段 `guard let card else { Allow }` 在红线之前 "
              + "就成了一条绕过它的路")

        // MARK: ⑥ 步骤围栏: 声明了没授权的步骤 ⇒ 拒

        let tDrift = PiRpcTransport()
        tDrift.updateApprovalMode(.autoAllow)
        tDrift.updateExecutionGuard(g)     // 只授权了 1、2
        tDrift.handleRPCLine(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"第 3 步 顺手把库也删了\n"}}"#)
        tDrift.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c_x4","toolName":"bash","args":{"command":"echo done"}}"#)
        tDrift.handleRPCLine(#"{"type":"extension_ui_request","id":"u_x4","method":"select","title":"MANGOX|APPROVE|c_x4|bash|echo done"}"#)
        check(tDrift.execActions[3]?.result == "drifted",
              "T-WATCHEXEC ⑥plan 外的步骤号 ⇒ 记跑偏（实际:\(tDrift.execActions[3]?.result ?? "nil")）")

        // MARK: ⑦ 没声明步骤号 = 无法证明在授权内 ⇒ 同样拒

        let tNoStep = PiRpcTransport()
        tNoStep.updateApprovalMode(.autoAllow)
        tNoStep.updateExecutionGuard(g)
        tNoStep.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c_x5","toolName":"bash","args":{"command":"echo hi"}}"#)
        tNoStep.handleRPCLine(#"{"type":"extension_ui_request","id":"u_x5","method":"select","title":"MANGOX|APPROVE|c_x5|bash|echo hi"}"#)
        check(tNoStep.sentCommands.contains { ($0["value"] as? String) == "Deny" },
              "T-WATCHEXEC ⑦没写「第 N 步」也拒 —— `guard let step` 一句话就会把它写成放行")
        check(tNoStep.execActions[0]?.result == "drifted",
              "T-WATCHEXEC ⑦落痕落在第 0 格（没声明步骤）")

        // 对照: 守卫清掉之后同一个实例不再拦（per-turn 不清 = 之后每一轮都带着红线）
        let tClear = PiRpcTransport()
        tClear.updateApprovalMode(.autoAllow)
        tClear.updateExecutionGuard(g)
        tClear.updateExecutionGuard(nil)
        tClear.handleRPCLine(#"{"type":"extension_ui_request","id":"u_x6","method":"select","title":"MANGOX|APPROVE|c_x6|bash|rm -rf /"}"#)
        check(tClear.execActions.isEmpty,
              "T-WATCHEXEC ⑦守卫撤掉后不再拦（这是 per-turn 语义: 清了就是清了）")

        // MARK: ⑧ 收尾判定（纯函数）

        check(WatchExecService.parseResult("做得挺好\nRESULT: DONE\nSUMMARY: 改了断言").verdict == .done,
              "T-WATCHEXEC ⑧认 RESULT: DONE")
        check(WatchExecService.parseResult("RESULT: FAILED\nSUMMARY: 第二步权限不够").verdict == .failed,
              "T-WATCHEXEC ⑧认 RESULT: FAILED")
        check(WatchExecService.parseResult("我做完了（但没有格式）").verdict == .unclear,
              "T-WATCHEXEC ⑧没有 RESULT ⇒ unclear（**不许**从正文里猜「听起来像做完了」）")
        check(WatchExecService.parseResult("RESULT: DONE\nSUMMARY: 好了").summary == "好了",
              "T-WATCHEXEC ⑧摘要要取出来（人复核时看的就是这一行）")

        // MARK: ⑧b 审批扩展的语法门（S6 在这段 JS 里加了围栏与"不给永久批准"）

        // ⚠️ 为什么必须有一条: 这段 JS 是**拼出来的字符串**, 少一个括号编译器一个字都不说,
        // 症状是 pi 加载扩展失败 —— 而失败的样子是"审批卡再也不弹", 不是报错。
        // 用 `runNodeSyntaxCheck`（真解析, 不是 `node --check`），与 computer 扩展同一把尺。
        let extDir = fixtureDir("p19exec-ext")
        let extPath = extDir + "/mangox-approval.ts"
        try? PiRpcTransport.approvalExtensionSource().write(toFile: extPath, atomically: true,
                                                           encoding: .utf8)
        let syntax = runNodeSyntaxCheck(extPath)
        check(syntax.found && syntax.ok,
              "T-WATCHEXEC ⑧b 审批扩展源码语法正确（\(syntax.detail)）—— 解析不了 = 审批卡全不弹")

        // MARK: ⑨ 端到端: 采纳 → 快照 → 开回合（带守卫）→ 收尾回写

        let mock = MockTransport()
        mock.scriptedReply = { _ in "第 1 步 改断言\n第 2 步 跑构建\nRESULT: DONE\nSUMMARY: 改好了" }
        let store = ChatStore(transport: mock, dbPath: dir + "/p19exec.db",
                              managedExtensionsDir: dir + "/ext")
        let projId = UUID()
        let projDir = dir + "/repo"
        try? FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        try? "old".write(toFile: projDir + "/a.txt", atomically: true, encoding: .utf8)
        store.projects.append(ProjectGroup(id: projId, title: "构建盘", path: projDir, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }),
              let logId = store.scheduler.ensureLogSession(for: store.scheduledTasks[ai]) else {
            check(false, "T-WATCHEXEC ⑨前置: 任务与日志会话就位"); return
        }
        let fid = UUID()
        let finding = AgentFinding(id: fid, taskId: store.scheduledTasks[ai].id, sourceId: projId,
                                   sessionId: logId, title: "CI 连续三次失败", body: "断言过期",
                                   evidence: "[1]", plan: [WatchPlanStep(n: 1, text: "改断言 a.txt"),
                                                           WatchPlanStep(n: 2, text: "跑构建")],
                                   planRev: 1, severity: "action", fingerprint: "fp-exec",
                                   status: .open, createdAt: Date())
        try? store.persistence?.upsertFinding(finding)
        store.reloadFindings()
        // Mock 没有审批桥 ⇒ 落痕要注入（真实链路由 ④⑤⑥⑦ 那几条 `PiRpcTransport` 用例覆盖;
        // 这里验的是"落痕 → 表"这一段）
        mock.execActions = [1: ExecAction(step: 1, kind: "edit", target: "a.txt",
                                          result: "allowed", count: 2)]

        let rejected = store.startFindingExecution(fid)
        check(rejected == nil, "T-WATCHEXEC ⑨采纳并执行: 起手成功（实际:\(rejected ?? "nil")）")

        // 快照走后台 + 回合是 mock 的逐字流 ⇒ 轮询等它落定（不 sleep 猜时长）
        var status: FindingStatus = .open
        for _ in 0..<120 {
            status = store.findings.first(where: { $0.id == fid })?.status ?? .open
            if status == .resolved || status == .failed { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        check(mock.lastExecutionGuard?.findingId == fid,
              "T-WATCHEXEC ⑨执行回合必须挂上守卫（挂不上 = 红线与步骤围栏全程没生效, 而界面照跑）")
        check(mock.lastExecutionGuard?.allowedSteps == [1, 2],
              "T-WATCHEXEC ⑨守卫带的是**这份方案**的步骤号")
        check(store.findings.first(where: { $0.id == fid })?.undoPath?.isEmpty == false,
              "T-WATCHEXEC ⑨起手先落快照路径（没有它, 收件箱里的「回滚」就是个空按钮）")
        check(status == .resolved,
              "T-WATCHEXEC ⑨模型说 DONE 且没有硬拦 ⇒ resolved（实际 \(status.rawValue)）")
        let acts = store.actions(for: fid)
        check(acts.count == 1 && acts[0].step == 1 && acts[0].result == "allowed",
              "T-WATCHEXEC ⑨执行落痕按步骤号进表（实际 \(acts.count) 行: "
              + acts.map { "\($0.step)/\($0.result)" }.joined(separator: ",") + "）")

        // ⑨b 红线拦下 + 模型仍说 DONE ⇒ **必须 failed**（这是"模型撒谎"那一半的唯一防线）
        let mock2 = MockTransport()
        mock2.scriptedReply = { _ in "第 1 步 清理\nRESULT: DONE\nSUMMARY: 全部搞定" }
        mock2.execActions = [1: ExecAction(step: 1, kind: "bash", target: "rm -rf /",
                                           result: "denied_by_redline", count: 1)]
        let store2 = ChatStore(transport: mock2, dbPath: dir + "/p19exec2.db",
                               managedExtensionsDir: dir + "/ext2")
        store2.projects.append(ProjectGroup(id: projId, title: "构建盘", path: projDir, items: []))
        store2.addScheduled(name: "CI 看守2", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                            projectId: projId, kind: .assistant)
        guard let ai2 = store2.scheduledTasks.firstIndex(where: { $0.name == "CI 看守2" }),
              let log2 = store2.scheduler.ensureLogSession(for: store2.scheduledTasks[ai2]) else {
            check(false, "T-WATCHEXEC ⑨b前置: 任务与日志会话就位"); return
        }
        let fid2 = UUID()
        try? store2.persistence?.upsertFinding(AgentFinding(
            id: fid2, taskId: store2.scheduledTasks[ai2].id, sourceId: projId, sessionId: log2,
            title: "磁盘要满了", body: "…", evidence: nil,
            plan: [WatchPlanStep(n: 1, text: "清缓存")], planRev: 1, severity: "action",
            fingerprint: "fp-exec2", status: .open, createdAt: Date()))
        store2.reloadFindings()
        _ = store2.startFindingExecution(fid2)
        var status2: FindingStatus = .open
        for _ in 0..<120 {
            status2 = store2.findings.first(where: { $0.id == fid2 })?.status ?? .open
            if status2 == .resolved || status2 == .failed { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        check(status2 == .failed,
              "T-WATCHEXEC ⑨b被红线拦下时**模型说 DONE 也不算数**（实际 \(status2.rawValue)）—— "
              + "resolved 是下一轮巡检的事实来源, 记错一次下一轮就在错误前提上判断")

        // MARK: ⑩ 重复执行被挡（写动作跑两遍 = 双倍破坏）

        let again = store.startFindingExecution(fid)
        check(again != nil, "T-WATCHEXEC ⑩已解决的结论不许再执行(实际:\(again ?? "nil") —— 直接放行)")

        // MARK: ⑪ 进程退出留下的 running 必须收回（否则永久卡死）

        try? store2.persistence?.upsertFinding(AgentFinding(
            id: fid2, taskId: store2.scheduledTasks[ai2].id, sourceId: projId, sessionId: log2,
            title: "磁盘要满了", body: "…", evidence: nil, plan: [WatchPlanStep(n: 1, text: "清缓存")],
            planRev: 1, severity: "action", fingerprint: "fp-exec2",
            status: .running, createdAt: Date()))
        let recovered = store2.scheduler.recoverInterruptedExecutions()
        check(recovered == 1 && store2.findings.first(where: { $0.id == fid2 })?.status == .open,
              "T-WATCHEXEC ⑪上一进程中断的执行收回 open（实际 recovered=\(recovered), "
              + "status=\(store2.findings.first(where: { $0.id == fid2 })?.status.rawValue ?? "nil")）—— "
              + "`running` 属于 blocksExecution 而收件箱只显 open, 不收就是永久卡死")
    }
}
