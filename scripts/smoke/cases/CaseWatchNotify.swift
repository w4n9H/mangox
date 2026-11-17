//
//  CaseWatchNotify.swift
//  P19 S7 · 触达常驻：日预算闸 / 三个 sink 的脱敏与失败路径 / 通知直达 / 登录项文案
//
//  ⚠️ 这一批的判据分三层，缺一层就有一整类"看起来配好了"的静默失败:
//    · **纯函数**（`feishuBody` / `redact` / `feishuError` / `statusText`）—— 回答"内容长什么样";
//    · **真路径**（`sendEmail` / `sendWebhook`）—— 回答"它有没有真的接上";
//    · **闸门**（`budgetBlockedReason` + `runScheduledFire`）—— 回答"该不该跑"。
//
//  反例预测（改坏之后哪几条该红）:
//    · 预算闸挪到采集之后 ⇒ ② 仍然绿（人看不出差别），但把 `return` 改成放行 ⇒ ② 红；
//    · 账本用覆盖而不是累加 ⇒ ① 红（和等于最后一次）；
//    · 把 `redact` 换成原样返回 ⇒ ③④ 红；
//    · 飞书判成功只看 HTTP 200 ⇒ ④ 的 code≠0 那格红；
//    · 载荷里带上 `finding.body` ⇒ ③ 红（这是"外发脱敏"唯一守得住的地方）。
//

import Foundation

extension SmokeMain {

    /// 只记不发的 webhook 缝 —— 真的往飞书群里发一条是**别人看得见**的动作。
    @MainActor
    final class RecordingWebhook: WebhookSender {
        struct Call { let url: String; let body: String }
        var calls: [Call] = []
        /// 非 nil ⇒ 这一跳抛错（模拟断网）。
        var error: Error?
        /// 服务端返回的 body（飞书对参数错误也回 200）。
        var responseBody = #"{"code":0,"msg":"success"}"#
        var status = 200

        func post(_ url: URL, json: Data) async throws -> (status: Int, body: String) {
            if let error { throw error }
            calls.append(Call(url: url.absoluteString, body: String(data: json, encoding: .utf8) ?? ""))
            return (status, responseBody)
        }
    }

    struct FakeWebhookError: Error {}

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

        let mail = WatchNotifyService.mail(payload, to: "me@example.com", from: "bot@163.com")
        check(mail.to == "me@example.com", "T-WATCHNOTIFY ③收件人是配置的那个")
        check(mail.subject.contains("CI 连续三次失败") && mail.subject.contains("CI 看守"),
              "T-WATCHNOTIFY ③主题带标题与任务名（实际「\(mail.subject)」）")
        check(!mail.body.contains(evidence) && !mail.body.contains(body),
              "T-WATCHNOTIFY ③邮件正文**不许带证据与正文** —— 那是锁屏/离开这台机器都看得见的地方")

        let hook = WatchNotifyService.feishuBody(payload) ?? Data()
        let hookText = String(data: hook, encoding: .utf8) ?? ""
        check(hookText.contains("CI 连续三次失败") && hookText.contains("text"),
              "T-WATCHNOTIFY ③飞书载荷是 text 消息且带标题（实际 \(hookText)）")
        check(!hookText.contains(evidence) && !hookText.contains(body),
              "T-WATCHNOTIFY ③飞书载荷同样不许带证据与正文")

        check(WatchNotifyService.feishuError(#"{"code":0,"msg":"success"}"#) == nil,
              "T-WATCHNOTIFY ③飞书 code=0 ⇒ 成功")
        let feishuFail = WatchNotifyService.feishuError(#"{"code":19021,"msg":"sign match fail"}"#) ?? ""
        check(feishuFail.contains("19021") && feishuFail.contains("sign match fail"),
              "T-WATCHNOTIFY ③飞书**对参数错误也回 200** ⇒ 判据必须读 body 里的 code（实际「\(feishuFail)」）")
        check(WatchNotifyService.feishuError("<html>502</html>") != nil,
              "T-WATCHNOTIFY ③不是 JSON 的响应要判失败（多半是地址错了 / 被网关截了）")

        let rawHook = "https://open.feishu.cn/open-apis/bot/v2/hook/SUPER-SECRET-TOKEN"
        let redacted = WatchNotifyService.redact(rawHook)
        check(!redacted.contains("SUPER-SECRET-TOKEN"),
              "T-WATCHNOTIFY ③脱敏必须砍掉路径段（那一段本身就是凭据；实际「\(redacted)」）")
        check(redacted.contains("open.feishu.cn"),
              "T-WATCHNOTIFY ③脱敏要保留 host —— 人要能从日志看出「我配的是不是那个机器人」")
        check(WatchNotifyService.redact("") == "", "T-WATCHNOTIFY ③空串进、空串出")
        check(!WatchNotifyService.redact("SUPER-SECRET-TOKEN").contains("SUPER-SECRET-TOKEN"),
              "T-WATCHNOTIFY ③连 URL 都解不出时**一个字都不回显**（那时候它可能就是密钥本身）")

        check(WatchNotifyService.looksLikeFeishuHook(rawHook),
              "T-WATCHNOTIFY ③飞书官方域名认得出来")
        check(!WatchNotifyService.looksLikeFeishuHook("http://open.feishu.cn/x"),
              "T-WATCHNOTIFY ③非 https 不算（飞书只收 https）")

        // MARK: - ④ webhook 真路径：失败要说得出话，且绝不回显 URL

        let rec = RecordingWebhook()
        fireStore.scheduler.webhookSender = rec
        let secrets = InMemoryNotifySecretStore()
        fireStore.scheduler.notifySecrets = secrets

        let noURL = await fireStore.scheduler.sendWebhook(payload, taskId: over.id)
        check(noURL.isFailed && noURL.text.contains("没配"),
              "T-WATCHNOTIFY ④没配地址要**说出来**（静默跳过 = 「我以为配了」; 实际「\(noURL.text)」）")

        try? secrets.setWebhookURL("http://open.feishu.cn/open-apis/bot/v2/hook/SUPER-SECRET-TOKEN",
                                   taskId: over.id)
        let badScheme = await fireStore.scheduler.sendWebhook(payload, taskId: over.id)
        check(badScheme.isFailed && !badScheme.text.contains("SUPER-SECRET-TOKEN"),
              "T-WATCHNOTIFY ④地址不合法时**报错文案也不能带 URL**（实际「\(badScheme.text)」）")

        try? secrets.setWebhookURL(rawHook, taskId: over.id)
        let okHook = await fireStore.scheduler.sendWebhook(payload, taskId: over.id)
        check(okHook == .sent("已发送"), "T-WATCHNOTIFY ④正常地址 ⇒ 已发送（实际「\(okHook.text)」）")
        check(rec.calls.count == 1, "T-WATCHNOTIFY ④确实发出了 1 跳（实际 \(rec.calls.count)）")
        check(rec.calls.first?.body.contains("CI 连续三次失败") == true,
              "T-WATCHNOTIFY ④发出去的载荷带标题")

        rec.responseBody = #"{"code":19021,"msg":"sign match fail"}"#
        let rejected = await fireStore.scheduler.sendWebhook(payload, taskId: over.id)
        check(rejected.isFailed && rejected.text.contains("19021"),
              "T-WATCHNOTIFY ④HTTP 200 但 code≠0 必须判失败（这条错了就是「以为发了, 群里什么都没有」）")

        rec.responseBody = #"{"code":0,"msg":"success"}"#
        rec.error = FakeWebhookError()
        let boom = await fireStore.scheduler.sendWebhook(payload, taskId: over.id)
        check(boom.isFailed && !boom.text.contains("SUPER-SECRET-TOKEN"),
              "T-WATCHNOTIFY ④投递抛错也不许把 URL 带进文案（实际「\(boom.text)」）")
        rec.error = nil

        // MARK: - ⑤ 邮件真路径：凭据只从钥匙串取，发件人是"第一个能发的账号"

        let noAccount = await fireStore.scheduler.sendEmail(payload, to: "me@example.com")
        check(noAccount.isFailed && noAccount.text.contains("邮箱账号"),
              "T-WATCHNOTIFY ⑤没有账号时要指名去什么地方配（实际「\(noAccount.text)」）")

        let acct = MailboxAccount(label: "发件箱", address: "bot@163.com", presetId: "163",
                                  imapHost: "imap.163.com:993", smtpHost: "smtp.163.com:465")
        fireStore.addMailboxAccount(acct)
        check(fireStore.firstSendableMailboxAccount() == nil,
              "T-WATCHNOTIFY ⑤有 SMTP 主机但**没有授权码**不算能发（半个配置比没有更坏）")

        let mailMock = MockMailTransport(accountId: acct.id)
        fireStore.scheduler.mailTransportFactory = { _, _ in mailMock }
        fireStore.setMailboxAuth("secret-auth-code", accountId: acct.id)
        check(fireStore.firstSendableMailboxAccount()?.id == acct.id,
              "T-WATCHNOTIFY ⑤主机 + 授权码齐了才算发件账号")

        let sent = await fireStore.scheduler.sendEmail(payload, to: "me@example.com")
        check(sent == .sent("已发给 me@example.com"),
              "T-WATCHNOTIFY ⑤发送成功（实际「\(sent.text)」）")
        check(mailMock.sentMails.count == 1, "T-WATCHNOTIFY ⑤确实投了 1 封（实际 \(mailMock.sentMails.count)）")
        check(mailMock.sentMails.first?.to == "me@example.com",
              "T-WATCHNOTIFY ⑤收件人是配置的那个")
        check(mailMock.sentMails.first?.body.contains("CI 连续三次失败") == true,
              "T-WATCHNOTIFY ⑤正文带标题")
        check(mailMock.sentMails.first?.body.contains(evidence) == false,
              "T-WATCHNOTIFY ⑤正文**不带证据**（脱敏在外发这一层, 不在调用方自觉上）")

        mailMock.sendError = .send("535 Login denied")
        let mailFail = await fireStore.scheduler.sendEmail(payload, to: "me@example.com")
        check(mailFail.isFailed && mailFail.text.contains("535"),
              "T-WATCHNOTIFY ⑤发送失败必须把服务端的原话带出来（「没收到」最难归因）")

        // MARK: - ⑥ 配置默认值与落库往返

        let fresh = NotifyOptions()
        check(fresh.system && fresh.emailAddress == nil && !fresh.webhook,
              "T-WATCHNOTIFY ⑥默认只开系统通知（缺省值一变, 升级上来的每条 Cron 任务都会被顺带改掉）")
        let blank = NotifyOptions(system: false, emailTo: "   ", webhook: false)
        check(blank.emailAddress == nil && blank.isAllOff,
              "T-WATCHNOTIFY ⑥全空白收件人 = 没填")

        var roundtrip = ScheduledTask(id: UUID(), name: "往返", prompt: "x", cron: "0 0 1 1 *")
        roundtrip.notify = NotifyOptions(system: false, emailTo: "a@b.c", webhook: true)
        roundtrip.dailyTokenBudget = 1234
        roundtrip.logSessionId = nil
        try? p.upsertScheduled(roundtrip)
        let back = (try? p.loadScheduled())?.first { $0.id == roundtrip.id }
        check(back?.notify == roundtrip.notify,
              "T-WATCHNOTIFY ⑥触达配置落库往返（实际 \(String(describing: back?.notify))）")
        check(back?.dailyTokenBudget == 1234,
              "T-WATCHNOTIFY ⑥日预算落库往返（实际 \(String(describing: back?.dailyTokenBudget))）")
        check(back.map { !$0.notify.system && $0.notify.webhook } == true,
              "T-WATCHNOTIFY ⑥关掉系统通知这件事必须读得回来（读不回来 = 关不掉）")

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
