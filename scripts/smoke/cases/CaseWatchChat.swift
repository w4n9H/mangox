//
//  CaseWatchChat —— P19 助理的**对话轮**：人在这条会话里说话时，它带的是哪套上下文
//
//  为什么这条要单独立（docs/P19 §03 三种轮）:
//    · 巡检轮与对话轮**同一场会话、同一份 transcript**（2026-11-18 boss 定:
//      「会话 = 助理 = 机器人」，定时轮不是另一条时间线）。从前的 `ephemeral: true` 已作废:
//      它让巡检轮每轮从零开始，而人在这条会话里说过的话它永远看不到 —— 那个"省上下文"的
//      收益是靠**切断连续性**换来的，助理记不住自己上一轮判断过什么，只能靠交接文件复述。
//    · 两轮的**注入段仍然不同**（巡检段说"到点了, 看看"; 对话段说"人在跟你说话" + 还开着的
//      结论）。共享 transcript 不共享注入 —— 这一条才是这个 case 真正守着的东西。
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

        // —— ① 巡检轮: 绑**同一场会话** ——
        store.runScheduledFire(store.scheduledTasks[ai])
        guard let logId = store.scheduledTasks[ai].logSessionId else {
            check(false, "T-WATCHCHAT ①前置: 日志会话已绑"); report()
        }
        // ⚠️ 2026-11-18 这格**翻面了**：从前是 `boundSessionId == nil`（`--no-session`）。
        // 不绑的后果不是"少一点上下文"，是**每轮都从零开始** —— 人在这条会话里说「那个再查查」，
        // 巡检轮既看不到那句话、也看不到自己上一轮判断过什么。
        check(mock.boundSessionId == logId,
              "T-WATCHCHAT ①巡检轮绑的是**这场会话本身**（不绑 ⇒ 定时轮和对话轮是两条时间线）")
        check(mock.lastExtraSystemPrompt?.contains("巡检轮") == true,
              "T-WATCHCHAT ①巡检轮的注入段是「巡检轮」那一套")

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
        // 2026-11-18: 围栏删了。对话轮现在要钉的是「普通活直接做 / 重要操作先说一句」，
        // 以及**必须把"工具级审批是关的"告诉它** —— 不告诉它，它会以为有人在拦着。
        check(ctx.contains("普通活直接做") && ctx.contains("重要操作先说一句再动"),
              "T-WATCHCHAT ②注入里写清两条边界（普通活直接做 / 重要操作先说一句）")
        check(ctx.contains("/.mangox/assistant/"),
              "T-WATCHCHAT ②账本的绝对路径写清（笔往哪写只有一处说法）")
        check(!ctx.contains("只有一支笔") && !ctx.contains("弹卡让人按"),
              "T-WATCHCHAT ②围栏那套话**不许留**（「写别处会弹卡」在审批关着时是假话）")
        check(ctx.contains("【提议】") && ctx.contains("整块不写"),
              "T-WATCHCHAT ②两段契约在: 正文 + **可选**的提议块（每轮都写 = 每轮往收件箱塞待办）")

        // ②b 没有目标的助理（2026-11-17 起编辑器里根本没有目标框）
        //     判据是"**不出现**那一行"，不是"出现空字符串" —— 留一行「你的长期目标：」
        //     比不写更糟: 模型会去猜那后面原本是什么。
        var goalLess = ScheduledTask(id: UUID(), name: "待命助理", prompt: "",
                                     cron: "0 0 1 1 *", projectId: nil)
        goalLess.kind = .assistant
        goalLess.logSessionId = UUID()
        store.scheduler.scheduledTasks.append(goalLess)
        let goalLessCtx = store.scheduler.assistantChatTurn(for: goalLess.logSessionId!)?.prompt ?? ""
        check(goalLessCtx.contains("对话轮"),
              "T-WATCHCHAT ②b 没有目标也照样是对话轮（前置: 下面的否定判据要有东西可否）")
        check(!goalLessCtx.contains("你的长期目标"),
              "T-WATCHCHAT ②b 目标为空 ⇒ **整行不出现**（写一行空的「你的长期目标：」等于让它猜）")

        // —— ③ 人在会话里说话 ⇒ 真加载历史 + 一支笔 ——
        store.beginTurn(sid: logId, prompt: "那个再查查", ephemeral: false,
                        cwd: dir, unattended: false)
        check(mock.boundSessionId == logId,
              "T-WATCHCHAT ③对话轮 `ephemeral: false` ⇒ 绑 session（指代成立的**结构**前提）")
        // 2026-11-18: 账本围栏整层删了 ⇒ 落点与"围栏外怎么办"不再下发。
        // 这里改判**它现在该有的样子**：对话轮的工具级审批恒关（助理线不弹卡）。
        check(mock.lastAskApproval == false,
              "T-WATCHCHAT ③对话轮不弹卡（助理线上改个文件就问他一次是噪音；实际 \(String(describing: mock.lastAskApproval))）")
        check(mock.lastExtraSystemPrompt?.contains("对话轮") == true,
              "T-WATCHCHAT ③且注入段换成对话那一套（不是继承巡检段）")

        // —— ④ 不是助理会话 ⇒ 一个字段都不动 ——
        let plainSid = UUID()
        check(store.scheduler.assistantChatTurn(for: plainSid) == nil,
              "T-WATCHCHAT ④普通会话不注入（否则每场闲聊都会被塞进一个「你的长期目标」）")
        store.beginTurn(sid: plainSid, prompt: "你好", ephemeral: false, cwd: nil, unattended: false)
        check(mock.lastExtraSystemPrompt == nil,
              "T-WATCHCHAT ④普通会话零注入（这是回归格: 上面③若写成无条件, 这里红）")

        // Cron 任务的日志会话同样不算对话轮（它没有"目标"这个概念）
        var cronTask = ScheduledTask(id: UUID(), name: "cron", prompt: "x", cron: "0 9 * * *",
                                     projectId: nil)
        cronTask.kind = .execute
        cronTask.logSessionId = UUID()
        store.scheduler.scheduledTasks.append(cronTask)
        check(store.scheduler.assistantChatTurn(for: cronTask.logSessionId!) == nil,
              "T-WATCHCHAT ④Cron 日志会话不算对话轮（kind 判据, 不是「有没有 logSessionId」）")

        store.scheduler.stopScheduler()

        // —— ⑤ 定时轮撞上在途回合 ⇒ **跳过**（2026-11-18 boss 明写的第二条） ——
        // 两轮同会话之后, "撞车"从"两件不相干的事"变成了**常态**: 人在说话时到点了。
        // 同一条会话里绝不能同时跑两轮 —— pi 侧只有一份 transcript，两个回合交错写会把
        // 半个 tool_call 与另一轮的正文拼在一起。跳过而不是排队: 到点的巡检晚一轮无所谓,
        // 被腰斩的会话是要修的。
        let dir2 = fixtureDir("p19chat2")
        let mock2 = MockTransport()
        let store2 = ChatStore(transport: mock2, dbPath: dir2 + "/p19chat2.db",
                               managedExtensionsDir: dir2 + "/ext")
        store2.scheduler.stopScheduler()
        let proj2 = UUID()
        store2.projects.append(ProjectGroup(id: proj2, title: "看守盘", path: dir2, items: []))
        store2.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                            projectId: proj2, kind: .assistant)
        guard let ai2 = store2.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-WATCHCHAT ⑤前置: 助理任务已建"); report()
        }
        // 先跑一轮把日志会话建出来（`ensureLogSession` 只在 fire 里跑）。
        mock2.scriptedReply = { _ in "结论：达成\n证据：无\n方案：无" }
        store2.runScheduledFire(store2.scheduledTasks[ai2])
        check(await waitUntil { store2.runningTurns.isEmpty },
              "T-WATCHCHAT ⑤前置: 第一次 fire 落定")
        guard let log2 = store2.scheduledTasks[ai2].logSessionId else {
            check(false, "T-WATCHCHAT ⑤前置: 日志会话已绑"); report()
        }
        let runCountBefore = store2.scheduledTasks[ai2].runCount
        // 对话轮占住这场会话（慢回复 = 撑住"在途"，不靠 sleep 猜）
        mock2.scriptedReply = { _ in String(repeating: "慢。", count: 30) }
        store2.beginTurn(sid: log2, prompt: "人在说话", ephemeral: false,
                         cwd: dir2, unattended: false)
        check(store2.runningTurns.contains(log2), "T-WATCHCHAT ⑤前置: 对话轮真的在途")
        let saidBefore = mock2.lastSentPrompt
        store2.runScheduledFire(store2.scheduledTasks[ai2])
        check(mock2.lastSentPrompt == saidBefore,
              "T-WATCHCHAT ⑤定时轮到点撞上在途对话轮 ⇒ **不再发一轮**"
              + "（同一份 transcript 跑两轮 = 两条回合交错写）")
        check(store2.scheduledTasks[ai2].runCount == runCountBefore,
              "T-WATCHCHAT ⑤跳过的那次**不推进 runCount**（推进 ⇒ 漏跑清单以为它真跑过）")
        check(await waitUntil { store2.runningTurns.isEmpty }, "T-WATCHCHAT ⑤对话轮收尾")
        let skipped = store2.replayMessages(for: log2).contains(where: { m in
            guard case .text(let s) = m.content else { return false }
            return s.contains("因冲突跳过")
        })
        check(skipped,
              "T-WATCHCHAT ⑤跳过要**留痕**（「因冲突跳过 (该任务回合在途)」）"
              + "—— 不留痕的话人只看到「到点了没跑」，分不清是跳过还是坏了")
        store2.scheduler.stopScheduler()

        // —— ⑥ 但 **Cron 档一字不动**：它仍然 `--no-session` ——
        // boss 那条只针对助理（"会话 = 助理 = 机器人"）。Cron 的连续性一直靠交接文件，
        // 换掉它等于把"每个 cron 一个 pi transcript"塞进磁盘 —— 那是**另一件事**，没被要求。
        // 这条判据必须单独立：`!task.isAssistant` 若被顺手改成 `false`/`true`，只有它会红。
        let mock3 = MockTransport()
        mock3.scriptedReply = { _ in "结论：达成\n证据：无\n方案：无" }
        let store3 = ChatStore(transport: mock3, dbPath: dir2 + "/p19chat3.db",
                               managedExtensionsDir: dir2 + "/ext")
        store3.scheduler.stopScheduler()
        store3.addScheduled(name: "Cron 跑批", prompt: "跑一下", cron: "0 3 * * *", projectId: nil)
        guard let ci = store3.scheduledTasks.firstIndex(where: { $0.name == "Cron 跑批" }) else {
            check(false, "T-WATCHCHAT ⑥前置: Cron 任务已建"); report()
        }
        check(store3.scheduledTasks[ci].kind == .execute,
              "T-WATCHCHAT ⑥前置: 这一档是 Cron（不是助理 —— 否则下面那条判的是另一件事）")
        store3.runScheduledFire(store3.scheduledTasks[ci])
        check(mock3.boundSessionId == nil,
              "T-WATCHCHAT ⑥Cron fire 仍然 `--no-session`（不绑会话 —— 这条线是定过的「Cron 零改动」）")
        check(mock3.lastExtraSystemPrompt == nil,
              "T-WATCHCHAT ⑥且零助理注入段（Cron 拿到助理的契约就会按 NO_FINDING 答）")
        _ = await waitUntil { store3.runningTurns.isEmpty }
        store3.scheduler.stopScheduler()
    }
}
