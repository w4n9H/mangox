//
//  CaseWatchNotify.swift
//  P19 S7 · 结论推送：日预算闸 / 飞书私聊的脱敏与失败路径 / 通知直达 / 登录项文案
//
//  ⚠️ 这一批的判据分三层，缺一层就有一整类"看起来配好了"的静默失败:
//    · **纯函数**（`payload` / `statusText`）—— 回答"内容长什么样";
//    · **真路径**（`deliverFinding` → 私聊推送）—— 回答"它有没有真的接上";
//    · **闸门**（`budgetBlockedReason` + `runScheduledFire`）—— 回答"该不该跑"。
//
//  ⚠️ 2026-11-18 晚：**编辑器里的「触达」卡整张删掉**（boss: 移除触达及相关功能），
//     连带删掉**邮件外发通道**。对应的判据跟着对象一起删：③ 的邮件三格、⑤ 整段（邮件真路径）、
//     ⑥ 里读 `emailAddress` / `isAllOff` 的那两格。**飞书私聊那条保留**（④），它是"人不在
//     电脑前也能批"的唯一入口 —— 删了它，方案级审批就没有投递面。
//     日预算（①②）与 `system` 落库（⑥）原样保留：它们与"怎么叫人"无关。
//
//  ⚠️ 2026-11-17：群 webhook 整条删掉（boss: 群不做了），飞书这一路只剩"推给入口机器人的私聊"。
//     原来 ③④ 里验 URL 脱敏 / 飞书 code / 域名白名单的那批判据**跟着对象一起删** ——
//     验一个已删除功能的判据会让人以为那条通道还在。
//
//  反例预测（改坏之后哪几条该红）:
//    · 预算闸挪到采集之后 ⇒ ② 仍然绿（人看不出差别），但把 `return` 改成放行 ⇒ ② 红；
//    · 账本用覆盖而不是累加 ⇒ ① 红（和等于最后一次）；
//    · `pushFinding` 不看 `botPhase` ⇒ ④「通道没连上」那格红（会把话写进没人读的 stdin）；
//    · 载荷里带上 `finding.body` ⇒ ③④ 红（这是"外发脱敏"唯一守得住的地方）。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseWatchNotify() async {
        print("== T-WATCHNOTIFY P19 S7 触达常驻 (预算闸 / sink 脱敏 / 通知直达 / 登录项) ==")

        let dir = fixtureDir("p19notify")

        // MARK: - ① 日预算：账本与日键

        let day = SchedulerService.dayKey(Date())
        check(day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              "T-WATCHNOTIFY ①日键必须是本地日 yyyy-MM-dd（实际 \(day)）")
        check(SchedulerService.dayKey(Date()) == day, "T-WATCHNOTIFY ①同一时刻两次取键必须相同")
        check(SchedulerService.dayKey(Date().addingTimeInterval(-25 * 3600)) != day,
              "T-WATCHNOTIFY ①隔了一天必须换键（不换 = 预算永远只累加不清零）")

        let store = ChatStore(transport: MockTransport(), dbPath: dir + "/p19notify.db",
                              managedExtensionsDir: dir + "/ext")
        guard let p = store.persistence else {
            check(false, "T-WATCHNOTIFY 前置: 本地库打不开"); report()
        }
        let budgetTaskId = UUID()
        try? p.addTokenUsage(taskId: budgetTaskId, day: day, tokens: 10)
        try? p.addTokenUsage(taskId: budgetTaskId, day: day, tokens: 5)
        try? p.addTokenUsage(taskId: budgetTaskId, day: day, tokens: 0)   // 0 不该改任何东西
        check((try? p.tokenUsage(taskId: budgetTaskId, day: day)) == 15,
              "T-WATCHNOTIFY ①账本必须**累加**（覆盖的话这里会是 0 或 5 —— 而表现是"
              + "「一整天只算最后一次」, 预算永远不触顶）")
        check((try? p.tokenUsage(taskId: budgetTaskId, day: "1999-01-01")) == 0,
              "T-WATCHNOTIFY ①没记过的日子是 0（不是 nil/崩）")

        var t = ScheduledTask(id: budgetTaskId, name: "预算试探", prompt: "x", cron: "0 0 1 1 *")
        t.dailyTokenBudget = 0
        check(store.scheduler.budgetBlockedReason(t) == nil,
              "T-WATCHNOTIFY ①0 = 不设限（既有 Cron 任务全靠这条保持零改动）")
        t.dailyTokenBudget = 20
        check(store.scheduler.budgetBlockedReason(t) == nil,
              "T-WATCHNOTIFY ①已用 15 / 上限 20 ⇒ 还没超，要放行")
        t.dailyTokenBudget = 15
        let blocked = store.scheduler.budgetBlockedReason(t) ?? ""
        check(blocked.contains("日预算已满"),
              "T-WATCHNOTIFY ①已用 15 / 上限 15 ⇒ 必须拦住并说清原因（实际「\(blocked)」）")

        // MARK: - ①b 对话轮**不吃**任务预算（D8 之后「会话 = 助理 = 机器人」）

        // ⚠️ 2026-11-18 review: 原来判据只有 `logSessionId == sid`，而助理的对话轮
        // **就是**那条会话 ⇒ 注释写着"包括助理的对话轮不该吃预算"，代码根本做不到：
        // 人在飞书问两句，今天的巡检就"日预算已满"。
        // 现在的判据 = "这一轮是不是走对话轮进来的"（`dialogueTurns` 里有它），
        // 而记账发生在 `finishDialogueTurnIfNeeded` 认领之前 ⇒ 此刻还在。
        // 两半都要判：只判"对话轮不记"的话，一个什么都不记的实现也全绿。
        let usageTaskId = UUID()
        let usageSid = UUID()
        var usageTask = ScheduledTask(id: usageTaskId, name: "口径试探", prompt: "x", cron: "0 0 1 1 *")
        usageTask.kind = .assistant
        usageTask.logSessionId = usageSid
        store.scheduler.scheduledTasks.append(usageTask)
        var usageMsg = ChatMessage(role: .assistant, content: .text("ok"))
        usageMsg.usage = MessageUsage(totalTokens: 120)
        let usageDay = SchedulerService.dayKey(Date())
        let usageStart = Date().addingTimeInterval(-30)
        _ = store.scheduler.beginDialogueTurn(sid: usageSid)     // 登记成对话轮
        store.scheduler.recordScheduledUsage(sid: usageSid, turnStart: usageStart, projection: [usageMsg])
        let dialogueSpent = (try? p.tokenUsage(taskId: usageTaskId, day: usageDay)) ?? -1
        store.scheduler.finishDialogueTurnIfNeeded(sid: usageSid)   // 认领 ⇒ 回到"巡检轮"口径
        store.scheduler.recordScheduledUsage(sid: usageSid, turnStart: usageStart, projection: [usageMsg])
        let fireSpent = (try? p.tokenUsage(taskId: usageTaskId, day: usageDay)) ?? -1
        check(dialogueSpent == 0 && fireSpent == 120,
              "T-WATCHNOTIFY ①b 对话轮不吃任务预算、巡检轮照记（实际 \(dialogueSpent) → \(fireSpent)）"
              + " —— 只判前半的话，「什么都不记」也能全绿")

        // MARK: - ② 预算闸端到端：超预算 ⇒ 不开回合 + 落痕

        let projDir = dir + "/repo"
        try? FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "构建盘", path: projDir, items: []))
        let mock = MockTransport()
        mock.scriptedReply = { _ in "结论：一切正常\n证据：无\n方案：无" }
        let fireStore = ChatStore(transport: mock, dbPath: dir + "/p19firing.db",
                                  managedExtensionsDir: dir + "/extf")
        fireStore.projects.append(ProjectGroup(id: projId, title: "构建盘", path: projDir, items: []))

        fireStore.addScheduled(name: "超预算的看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                               projectId: projId, kind: .assistant)
        guard let idx = fireStore.scheduledTasks.firstIndex(where: { $0.name == "超预算的看守" }),
              let fp = fireStore.persistence else {
            check(false, "T-WATCHNOTIFY ②前置: 助理任务已建"); report()
        }
        var over = fireStore.scheduledTasks[idx]
        over.dailyTokenBudget = 1
        fireStore.updateScheduled(over)
        try? fp.addTokenUsage(taskId: over.id, day: day, tokens: 1)
        let before = fireStore.scheduledTasks[idx].lastRunAt

        fireStore.runScheduledFire(fireStore.scheduledTasks[idx])

        check(mock.lastSentPrompt == nil,
              "T-WATCHNOTIFY ②超预算**不许开回合**（开了就是白烧一轮 token —— 而人设这个数就是为了不烧）")
        guard let logId = fireStore.scheduledTasks[idx].logSessionId else {
            check(false, "T-WATCHNOTIFY ②早退路径必须把日志会话绑给任务"); report()
        }
        let timeline = fireStore.replayMessages(for: logId).compactMap { m -> String? in
            guard case .text(let s) = m.content else { return nil }
            return s
        }
        check(timeline.contains { $0.contains("日预算已满") },
              "T-WATCHNOTIFY ②跳过必须**落痕**（静默跳过 = 「任务坏了」与「预算到了」长得一模一样）")
        check(fireStore.scheduledTasks[idx].lastRunAt == before,
              "T-WATCHNOTIFY ②跳过不推进 lastRunAt（推进了就等于把这次算成跑过, 补跑窗口也一起吃掉）")

        // 反向: 预算内必须照跑（否则闸就恒关了）
        var under = fireStore.scheduledTasks[idx]
        under.dailyTokenBudget = 100000
        fireStore.updateScheduled(under)
        fireStore.runScheduledFire(fireStore.scheduledTasks[idx])
        check(mock.lastSentPrompt != nil,
              "T-WATCHNOTIFY ②预算内必须照跑（闸恒关的话「日预算」就成了一个摆设开关）")

        // MARK: - ③ 脱敏：三个 sink 共用一份载荷

        let evidence = "证据：a.txt:42 断言过期"
        let body = "正文里那句不该外发的话"
        let finding = AgentFinding(id: UUID(), taskId: over.id, sourceId: projId, sessionId: logId,
                                   title: "CI 连续三次失败", body: body, evidence: evidence,
                                   plan: [], planRev: 1, severity: "action",
                                   fingerprint: "fp-notify", status: .open, createdAt: Date())
        let payload = WatchNotifyService.payload(finding: finding, taskName: "CI 看守")
        check(payload.line == "CI 看守 · CI 连续三次失败",
              "T-WATCHNOTIFY ③载荷 = 任务名 + 标题（实际「\(payload.line)」）")

        // ⚠️ 2026-11-17 这一段的 5 条判据（飞书 text 载荷 / `feishuError` 读 body 里的 code /
        //    `redact` 砍路径段 / `looksLikeFeishuHook`）**跟着 webhook 一起删了**。删的理由不是
        //    "它们不对"，而是**对象没了**：群不做 ⇒ webhook 不做了 ⇒ 没有 URL 要脱敏、
        //    没有 code 要读。留着一堆"验一个已删除功能"的判据，比没有判据更误导人 ——
        //    它会让下一个人以为这条通道还在。飞书现在的出口只有一条：私聊推送（见 ④）。

        // MARK: - ④ 飞书私聊：结论推到跟助理绑的那个机器人

        // 2026-11-17 换掉的是**落点和判据**，不是"删了一个功能"：
        // 原来只有"群 webhook"，现在只有"入口机器人的私聊" —— 四种推不出去的情形各有各的话。
        func isSkipped(_ o: NotifyOutcome) -> Bool { if case .skipped = o { return true }; return false }
        let fake = FakeRemoteLink()
        fireStore.remote.attachLink(fake)

        let noBot = fireStore.remote.pushFinding(payload, taskId: over.id)
        check(isSkipped(noBot) && noBot.text.contains("没绑机器人"),
              "T-WATCHNOTIFY ④没绑机器人 ⇒ 说出来去配（静默跳过 = 「我以为配了」; 实际「\(noBot.text)」）")

        let pushBot = UUID()
        fireStore.addRemoteBot(RemoteBot(id: pushBot, name: "推送号", appId: "cli_push0000000000"))
        _ = fireStore.setRemoteBotSecret("s3cret", for: pushBot)
        fireStore.assignRemoteBot(pushBot, to: over.id)
        let noChat = fireStore.remote.pushFinding(payload, taskId: over.id)
        check(isSkipped(noChat) && noChat.text.contains("跟它说过话"),
              "T-WATCHNOTIFY ④还没人跟它说过话 ⇒ **说清缺什么**（没有 chatId 就没有落点; 实际「\(noChat.text)」）")

        // 一次真实往返：谁跟它说过话 → 通道握手成功
        let pushChat = "oc_push_chat_0001"
        fireStore.touchRemoteBotChat(pushBot, chatId: pushChat)
        fake.emit(.status(botId: pushBot.uuidString, connected: true, note: "ws handshake ok"))
        check(fireStore.remote.phase(for: pushBot) == .up,
              "T-WATCHNOTIFY ④前置: 通道握手成功（后面两格要判「推得出去」）")

        let pushed = fireStore.remote.pushFinding(payload, taskId: over.id)
        check(!isSkipped(pushed) && pushed.text.contains("已推给"),
              "T-WATCHNOTIFY ④连上了 + 有落点 ⇒ 推出去（实际「\(pushed.text)」）")
        check(fake.sent.last?.chatId == pushChat,
              "T-WATCHNOTIFY ④推到**跟它说过话的那个私聊**（`chat_id` 是地址, 不是身份）")
        check(fake.sent.last?.botId == pushBot.uuidString,
              "T-WATCHNOTIFY ④用的是**这个助理绑的那个机器人**（借别的机器人发 = 用错身份说话）")
        // 2026-11-18: 正文 = `payload.line` + **怎么回**。人不在电脑前，收到这一条之后
        // 唯一能做的就是回两个字；不告诉他回什么，这条推送就只是一条通知。
        check(fake.sent.last?.text.hasPrefix(payload.line) == true,
              "T-WATCHNOTIFY ④推送正文以 `payload.line` 打头 —— 脱敏载荷只许有**一处**组装"
              + "（实际「\(fake.sent.last?.text ?? "nil")」）")
        check(fake.sent.last?.text.contains("先别动") == true,
              "T-WATCHNOTIFY ④且写明**怎么回**（回「同意」/「先别动」—— 不写他就只能回 App，而他人不在电脑前）")
        check(!(fake.sent.last?.text.contains(evidence) ?? true)
              && !(fake.sent.last?.text.contains(body) ?? true),
              "T-WATCHNOTIFY ④私聊里同样不许带证据与正文（离开这台机器的地方一律只带标题）")

        // **接线**：上面验的是"这个方法能推"，这一格验"结论产生时真的会调它" ——
        // 只测服务不测接线，等于没测（S7 那版把 webhook 分支写成 `if opts.webhook`，
        // 而默认 false ⇒ 全部静默不发，一个红灯都没有）。
        let beforeSink = fake.sent.count
        if let live = fireStore.scheduledTasks.first(where: { $0.id == over.id }) {
            fireStore.scheduler.deliverFinding(finding, task: live, logId: logId)
        }
        check(fake.sent.count == beforeSink + 1,
              "T-WATCHNOTIFY ④结论产生 ⇒ 外发 sink **真的**推了一条（实际多了 \(fake.sent.count - beforeSink) 条）")

        // ⚠️ 2026-11-18 换的这一格：机器人**没有自己的开关**了（boss: 只留助理的开关）⇒
        //    "推不出去"的第三种理由是"助理关着"，不再是"机器人被关"。判据跟着对象一起换，
        //    否则就是在验一个不存在的状态（那种判据永远绿，也永远不代表任何事）。
        let stoppedBefore = fake.stopped
        fireStore.toggleScheduled(id: over.id)      // 关助理
        check(fake.stopped > stoppedBefore,
              "T-WATCHNOTIFY ④关助理 ⇒ 桥停下（助理那盏开关就是机器人唯一的开关）")
        let botOff = fireStore.remote.pushFinding(payload, taskId: over.id)
        check(isSkipped(botOff) && botOff.text.contains("关着"),
              "T-WATCHNOTIFY ④助理关着 ⇒ 说「助理是关着的」（而不是「通道坏了」; 实际「\(botOff.text)」）")

        fireStore.toggleScheduled(id: over.id)      // 打开回来
        fake.emit(.status(botId: pushBot.uuidString, connected: false, note: "ws failed"))
        let down = fireStore.remote.pushFinding(payload, taskId: over.id)
        check(!isSkipped(down) && down.text.contains("通道没连上"),
              "T-WATCHNOTIFY ④通道没连上 ⇒ **失败**而不是跳过（写进桥的 stdin 是没人读的, 装作发了最坏; 实际「\(down.text)」）")

        // MARK: - ⑥ 配置默认值与落库往返

        let fresh = NotifyOptions()
        check(fresh.system,
              "T-WATCHNOTIFY ⑥默认开系统通知（缺省值一变, 升级上来的每条 Cron 任务都会被顺带改掉）")

        var roundtrip = ScheduledTask(id: UUID(), name: "往返", prompt: "x", cron: "0 0 1 1 *")
        roundtrip.notify = NotifyOptions(system: false, emailTo: "a@b.c")
        roundtrip.dailyTokenBudget = 1234
        roundtrip.logSessionId = nil
        try? p.upsertScheduled(roundtrip)
        let back = (try? p.loadScheduled())?.first { $0.id == roundtrip.id }
        check(back?.notify == roundtrip.notify,
              "T-WATCHNOTIFY ⑥触达配置落库往返（实际 \(String(describing: back?.notify))）")
        check(back?.dailyTokenBudget == 1234,
              "T-WATCHNOTIFY ⑥日预算落库往返（实际 \(String(describing: back?.dailyTokenBudget))）")
        // 2026-11-18 晚: 界面上已经没有"关掉它"的入口了，但**字段必须照旧读得回来** ——
        // 老任务配过的 `system=false` / `emailTo` 原样留在行上（"撤下输入框 ≠ 清空数据"）。
        check(back.map { !$0.notify.system && $0.notify.emailTo == "a@b.c" } == true,
              "T-WATCHNOTIFY ⑥旧行上的触达字段必须照旧读得回来（读不回来 = 一次编辑就静默清空）")

        // 老库: notify 列为 NULL ⇒ 回落默认（宁可多弹一条通知, 也不能让一条任务读不出来）
        var legacy = ScheduledTask(id: UUID(), name: "老行", prompt: "x", cron: "0 0 1 1 *")
        legacy.logSessionId = nil
        try? p.upsertScheduled(legacy)
        check(((try? p.loadScheduled())?.first { $0.id == legacy.id }?.notify ?? .default) == .default,
              "T-WATCHNOTIFY ⑥触达列缺省回落默认")

        // MARK: - ⑦ 通知直达：打开收件箱 + 记住要展开哪条

        let fid = UUID()
        store.focusFinding(fid)
        check(store.showScheduledPanel,
              "T-WATCHNOTIFY ⑦点通知要打开定时页（验收 ⑫「落到收件箱」）")
        check(!store.showKnowledgePanel && !store.showExtensionsPanel,
              "T-WATCHNOTIFY ⑦面板互斥照旧（少关一个 = 侧栏两颗胶囊同时亮）")
        check(store.pendingFindingFocus == fid,
              "T-WATCHNOTIFY ⑦记下要展开的那条（视图此刻可能还没建, 不能直接戳它的 @State）")
        check(store.consumeFindingFocus() == fid, "T-WATCHNOTIFY ⑦视图取走那次请求")
        try? await Task.sleep(nanoseconds: 60_000_000)   // 清空延到下一轮 runloop
        check(store.pendingFindingFocus == nil,
              "T-WATCHNOTIFY ⑦取走后必须清掉（不清 = 每次重进定时页都重新展开那条）")
        check(store.consumeFindingFocus() == nil, "T-WATCHNOTIFY ⑦没有请求时取到 nil")

        // MARK: - ⑧ 登录项：四种状态说四句不同的话

        let onText = LoginItemService.statusText(.on)
        let offText = LoginItemService.statusText(.off)
        let approvalText = LoginItemService.statusText(.requiresApproval)
        let unavailText = LoginItemService.statusText(.unavailable)
        check(onText != offText && offText != approvalText && approvalText != unavailText,
              "T-WATCHNOTIFY ⑧四种状态必须说四句不同的话（说成一样 = 「已开」和「要你批准」分不出来）")
        check(approvalText.contains("批准"),
              "T-WATCHNOTIFY ⑧待批准要指名去哪里点（实际「\(approvalText)」）")
        check(offText.contains("打开 App"),
              "T-WATCHNOTIFY ⑧没开要说真话: 打开 App 才会巡检（不粉饰成「后台常驻」）")
        check(offText.contains("打开 App") && unavailText.contains("打开 App"),
              "T-WATCHNOTIFY ⑧「注册失败」和「没开」的**后果是同一句**（不补一条不可靠的自启路径）")
        // 冒烟二进制没有 bundle id ⇒ 这一层必须自己认出来并挡住, 绝不碰 SMAppService
        check(!LoginItemService.isSupported,
              "T-WATCHNOTIFY ⑧无 bundle id 的进程必须自认不支持（否则 register() 会崩或卡死冒烟）")
        check(LoginItemService.state() == .unavailable,
              "T-WATCHNOTIFY ⑧不支持时状态恒 .unavailable")
        check(LoginItemService.enable() != nil,
              "T-WATCHNOTIFY ⑧不支持时注册要**返回原因**而不是假装成功")
    }
}
