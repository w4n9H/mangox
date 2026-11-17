//
//  CaseWatchChat —— P19 助理的**对话轮**：人在这条会话里说话时，它带的是哪套上下文
//
//  为什么这条要单独立（docs/P19 §03 三种轮）:
//    · 巡检轮 `ephemeral: true` —— **不加载会话原文**。这不是省事, 是判据: 每天几十轮会把
//      上下文撑爆, 还会把闲话当事实。所以"巡检轮读不到这段对话"是**结构性**的, 不是靠自觉;
//    · 对话轮 `ephemeral: false` —— 真加载历史,「那个再查查」才指代得上。两轮的**注入段不同**
//      （巡检段说"到点了, 看看"; 对话段说"人在跟你说话" + 还开着的结论）。
//    两个轮次共用同一份 transport ⇒ 谁在什么时候写哪个字段, 只能靠判据钉住。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseWatchChat() async {
        let dir = fixtureDir("p19chat")
        let mock = MockTransport()
        mock.scriptedReply = { _ in "结论：一切正常。\n证据：无\n方案：无" }
        let store = ChatStore(transport: mock, dbPath: dir + "/p19chat.db",
                              managedExtensionsDir: dir + "/ext")
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: dir, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-WATCHCHAT 前置: 助理任务已建"); report()
        }

        // —— ① 巡检轮: 不绑会话原文 ——
        store.runScheduledFire(store.scheduledTasks[ai])
        check(mock.boundSessionId == nil,
              "T-WATCHCHAT ①巡检轮 `ephemeral` ⇒ 不绑 session（**读不到**人说过的话: 每天几十轮, 撑爆上下文还会把闲话当事实）")
        check(mock.lastExtraSystemPrompt?.contains("巡检轮") == true,
              "T-WATCHCHAT ①巡检轮的注入段是「巡检轮」那一套")
        guard let logId = store.scheduledTasks[ai].logSessionId else {
            check(false, "T-WATCHCHAT 前置: 日志会话已绑"); report()
        }

        // —— ② 会话里的上下文: 目标 + 还开着的结论 ——
        let finding = AgentFinding(id: UUID(), taskId: store.scheduledTasks[ai].id,
                                   sourceId: projId, sessionId: logId,
                                   title: "CI 连续三次失败", body: "…", evidence: "[1]",
                                   plan: [WatchPlanStep(n: 1, text: "改断言")], planRev: 2,
                                   severity: "action",
                                   fingerprint: "fp-chat", status: .open, createdAt: Date())
        try? store.persistence?.upsertFinding(finding)
        store.reloadFindings()
        let ctx = store.scheduler.assistantChatTurn(for: logId)?.prompt ?? ""
        check(ctx.contains("对话轮") && ctx.contains("保证 CI 是绿的"),
              "T-WATCHCHAT ②对话段带**目标**（不然它不知道自己在替谁看什么）")
        check(ctx.contains("CI 连续三次失败") && ctx.contains("第 2 版"),
              "T-WATCHCHAT ②还开着的结论也带（人问「那个再查查」, 它得知道「那个」是哪条）")
        check(!ctx.contains("巡检轮"),
              "T-WATCHCHAT ②两段不能混: 对话轮里出现巡检段 = 它以为自己在做定时巡检")
        // P19.2 S12: 对话轮从「没有写权限」改成「只有一支笔」，这两格是那个翻面的证据
        check(ctx.contains("只有一支笔") && ctx.contains("/.mangox/assistant/"),
              "T-WATCHCHAT ②注入里写清**只许写账本**并给出那个绝对路径（笔往哪写只有一处说法）")
        check(!ctx.contains("没有写权限"),
              "T-WATCHCHAT ②且不再说「没有写权限」—— 那句话在 S12 之后是假的")
        check(ctx.contains("【提议】") && ctx.contains("整块不写"),
              "T-WATCHCHAT ②两段契约在: 正文 + **可选**的提议块（每轮都写 = 每轮往收件箱塞待办）")

        // —— ③ 人在会话里说话 ⇒ 真加载历史 + 只读面 ——
        store.beginTurn(sid: logId, prompt: "那个再查查", ephemeral: false,
                        cwd: dir, unattended: false)
        check(mock.boundSessionId == logId,
              "T-WATCHCHAT ③对话轮 `ephemeral: false` ⇒ 绑 session（指代成立的**结构**前提）")
        check(mock.lastAnalysisReadOnly,
              "T-WATCHCHAT ③对话轮仍然走分析面（不起 computer / 不注知识 / 不注 SOP）")
        // P19.2 S12: 分析面**不等于没有笔** —— 有账本落点就有一支笔，但模式是 ask。
        check(mock.lastLedgerFencePath == store.scheduler.handoffPath(for: store.scheduledTasks[ai]),
              "T-WATCHCHAT ③对话轮把账本落点下发给 transport（实际 \(mock.lastLedgerFencePath ?? "nil")）")
        check(mock.lastLedgerFenceMode == .ask,
              "T-WATCHCHAT ③围栏模式是 ask: 围栏外**弹卡**而不是拒 —— 有人在场, 拒会把「帮我改这行」判死")
        check(mock.lastExtraSystemPrompt?.contains("对话轮") == true,
              "T-WATCHCHAT ③且注入段换成对话那一套（不是继承巡检段）")

        // —— ④ 不是助理会话 ⇒ 一个字段都不动 ——
        let plainSid = UUID()
        check(store.scheduler.assistantChatTurn(for: plainSid) == nil,
              "T-WATCHCHAT ④普通会话不注入（否则每场闲聊都会被塞进一个「你的长期目标」）")
        store.beginTurn(sid: plainSid, prompt: "你好", ephemeral: false, cwd: nil, unattended: false)
        check(!mock.lastAnalysisReadOnly && mock.lastExtraSystemPrompt == nil,
              "T-WATCHCHAT ④普通会话照旧全量工具面、零注入（这是回归格: 上面③若写成无条件, 这里红）")

        // Cron 任务的日志会话同样不算对话轮（它没有"目标"这个概念）
        var cronTask = ScheduledTask(id: UUID(), name: "cron", prompt: "x", cron: "0 9 * * *",
                                     projectId: nil)
        cronTask.kind = .execute
        cronTask.logSessionId = UUID()
        store.scheduler.scheduledTasks.append(cronTask)
        check(store.scheduler.assistantChatTurn(for: cronTask.logSessionId!) == nil,
              "T-WATCHCHAT ④Cron 日志会话不算对话轮（kind 判据, 不是「有没有 logSessionId」）")

        store.scheduler.stopScheduler()
    }
}
