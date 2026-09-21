//
//  MailboxSentinelService.swift
//  P10.2a: 邮箱哨兵域 — 驱动 N 个哨兵 (全局串行), 四道闸 + 清洗 + 线程定位 + 编排 fire。
//  对齐 SchedulerService 模式 (timer + attach + 弱 store); P9.1 拆分模式:
//  ChatStore 持 `let mailbox = MailboxSentinelService()` + 同名 facade 转发 + objectWillChange sink。
//
//  纪律: 只 poll INBOX 永不破例 —— 白名单之外, 服务商 SPF/DKIM/DMARC 过滤是免费的第一道闸;
//  一旦改为也看垃圾箱 / All Mail, 这道闸立刻失效 (见 docs/P10-functional-design.md §2.10 铁律④ + §2.11 风险清单)。
//

import Foundation
import Combine

/// 四道闸的裁决 (纯函数产物; 冒烟直接断言, 不经邮件往返)。
enum MailboxGate: Equatable {
    case pass
    /// ① 白名单外 → 标已读 + 移 Trash + 拒收日志, **不回执** (决定 14)
    case notWhitelisted
    /// ② 首封缺 `[MGOX]` 意图标记 → 拒收 + 回执一次
    case missingIntent
    /// ② 密钥闸开着但哨兵侧没有密钥可用 (没配) → 拒收 + 回执一次
    case secretMissing
    /// ② 主题密钥与配置不符 → 拒收 + 回执一次
    case secretMismatch
    /// ③ 首封 Date 超窗 → 静默跳过
    case stale
    /// ④ Message-ID 已处理过 → 静默跳过
    case duplicate

    /// 进拒收日志的原因 (nil = 静默分支, 只有时效/幂等不过)
    var rejectionReason: MailboxRejectionReason? {
        switch self {
        case .notWhitelisted:            return .notWhitelisted
        case .missingIntent:             return .missingIntent
        case .secretMissing:             return .secretMissing
        case .secretMismatch:            return .secretMismatch
        case .pass, .stale, .duplicate:  return nil
        }
    }

    /// 白名单外静默 (不回执); 白名单内的身份闸不过 → 回执一次 (否则自己打错时完全无法自查)。
    var replies: Bool {
        switch self {
        case .missingIntent, .secretMissing, .secretMismatch: return true
        default: return false
        }
    }
}

@MainActor
final class MailboxSentinelService: ObservableObject {

    // MARK: - 状态

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) {
        self.store = store
        reload()
    }

    @Published private(set) var accounts: [MailboxAccount] = []
    @Published private(set) var sentinels: [MailboxSentinel] = []
    @Published private(set) var tasks: [MailboxTask] = []
    /// 底栏横幅 (连接失败 / 解析失败 / 目录不存在)
    @Published private(set) var mailboxNotice: String?
    /// 拒收日志 (跨哨兵, 按时间倒序)。**内存缓存** —— Settings 面板每次重绘都读它, 不能每帧查库;
    /// 落库纪律不变 (每哨兵 200 条由库侧事务裁剪), 内存侧用同一上限同步裁剪。
    @Published private(set) var rejections: [MailboxRejection] = []

    /// 凭据缝 (冒烟注入内存实现; 生产 = Keychain)。
    var credentials: MailboxCredentialStore = KeychainMailboxCredentialStore()

    /// 收件/发件实例工厂 (**按账号实例化**: 连接参数与凭据都挂在账号上)。
    /// **缺省 = 生产 `CurlMailTransport`** (P10.2c); 冒烟置非 nil 覆盖成 `MockMailTransport`。
    /// 构造无害 —— 缺 host / 缺授权码在首次调用时才报错 (落横幅)。
    var makeTransport: ((MailboxAccount) -> (any MailTransport)?)?

    /// 实例缓存 (按 accountId; 对齐 ChatStore.transports 模式)。1:1 绑定下无共用冲突。
    private var transports: [UUID: any MailTransport] = [:]
    /// **全局串行**: 同一时刻只跑一个远程回合 (家里那台 Mac 不是服务器; 也避免多 pi 进程同时写不同目录)。
    private(set) var runningTaskId: UUID?

    /// 待执行回合的全部上下文 —— 入队时暂存, 出队/fire 时消费。
    /// 为什么只在内存: 正文与"回给谁"都是**本运行期**的事 (回合落定即回执), 重启后队列已判失效 (见 reload),
    /// 所以不为此新增表列 (P10.2b 定案)。
    private struct PendingTurn {
        let prompt: String
        let to: String          // 触发邮件的发件人 (回执收件人)
        let inReplyTo: String   // 触发邮件的 Message-ID (回执 In-Reply-To)
    }
    private var queuedTurns: [UUID: PendingTurn] = [:]
    /// 在途回合的上下文 (taskId → 触发邮件与收件人)。落定钩子只拿得到 sid, 靠这张表才知道"回给谁/回哪封"。
    private var pendingTurns: [UUID: PendingTurn] = [:]

    /// 回合结算基线: fire 时快照 (sid → 消息数 / 起始时刻), 落定时用来切出"本回合产出"。
    /// 不用 `store.sessionStats`: 那只归并选中会话的上报, 后台邮件会话拿不到 (详见 MailboxReply.swift)。
    private var turnBaseline: [UUID: Int] = [:]
    private var turnStart: [UUID: Date] = [:]

    private var timer: Timer?
    private var polling = false

    /// 首封时效窗 (拍板 4: 只对首封生效, 收敛泄露暴露期)
    nonisolated static let firstMailWindow: TimeInterval = 7 * 24 * 3600
    /// 身份闸回执限流窗 (同地址 24h 一次)
    nonisolated static let gateReplyWindow: TimeInterval = 24 * 3600
    /// 意图标记 (首封必备)
    nonisolated static let intentMarker = "[MGOX]"

    private var persistence: PersistenceStore? { store?.persistence }

    // MARK: - 装配 / 载入

    func reload() {
        guard let p = persistence else { return }
        accounts = (try? p.loadMailboxAccounts()) ?? []
        sentinels = (try? p.loadMailboxSentinels()) ?? []
        tasks = (try? p.loadMailboxTasks()) ?? []
        // 拒收日志逐哨兵读库合并 (库侧已各留 200 条且按 at 倒序)
        rejections = sentinels.flatMap { p.loadMailboxRejections(sentinelId: $0.id) }
            .sorted { $0.at > $1.at }
        // 排队/在途任务的正文只活在内存 (不落库): 重启后两者都失去了回合上下文, 显式判失败而不是
        // 留幽灵 running —— **幽灵 running 更坏**: `noteTurnFinished` 按 `status == .running` 找任务,
        // 之后用户在那个会话里自己发一条消息, 落定时会命中这条幽灵, 把用户那条回合的产出当回执发出去。
        for i in tasks.indices where tasks[i].status == .queued || tasks[i].status == .running {
            let wasRunning = tasks[i].status == .running
            tasks[i].status = .failed
            tasks[i].blockedReason = wasRunning
                ? "上次退出时回合还在跑, 重启后无法结算"
                : "重启后排队正文已丢失 (回合上下文不落库)"
            tasks[i].updatedAt = Date()
            persistTask(tasks[i])
        }
        startScheduler()
    }

    // MARK: - 账号池 (决定 10: 只管"怎么连")

    /// 绑定该账号的哨兵 (nil = 空闲; 1:1)。
    func sentinel(for accountId: UUID) -> MailboxSentinel? {
        sentinels.first { $0.accountId == accountId }
    }

    /// UI 选择器数据源: 只返回空闲账号; `forSentinel` = 编辑既有哨兵时把自己占的账号排除在外。
    func availableAccounts(forSentinel sentinelId: UUID?) -> [MailboxAccount] {
        var occupied = Set(sentinels.map(\.accountId))
        if let keep = sentinelId, let mine = sentinels.first(where: { $0.id == keep }) {
            occupied.remove(mine.accountId)
        }
        return accounts.filter { !occupied.contains($0.id) }
    }

    func addAccount(_ a: MailboxAccount) {
        accounts.append(a)
        try? persistence?.upsertMailboxAccount(a)
    }

    func updateAccount(_ a: MailboxAccount) {
        guard let i = accounts.firstIndex(where: { $0.id == a.id }) else { return }
        accounts[i] = a
        try? persistence?.upsertMailboxAccount(a)
        invalidateTransport(a.id)   // host/address 变了, 旧实例里的快照作废
    }

    /// 被哨兵引用 → 拒绝 (决定 10: 引用保护; UI 侧禁用按钮 + tooltip "先删除哨兵 <name>")。
    @discardableResult
    func removeAccount(_ id: UUID) -> Bool {
        guard sentinel(for: id) == nil else { return false }
        accounts.removeAll { $0.id == id }
        try? persistence?.deleteMailboxAccount(id: id)
        try? credentials.setAccountAuth(nil, accountId: id)   // Keychain 一并清
        invalidateTransport(id)
        return true
    }

    // MARK: - 哨兵 (策略主体)

    /// 1:1 占用校验: 账号已被别的哨兵绑定 → 拒绝 (返回 false)。
    @discardableResult
    func upsertSentinel(_ s: MailboxSentinel) -> Bool {
        if let occupant = sentinel(for: s.accountId), occupant.id != s.id { return false }
        if let i = sentinels.firstIndex(where: { $0.id == s.id }) { sentinels[i] = s } else { sentinels.append(s) }
        try? persistence?.upsertMailboxSentinel(s)
        startScheduler()   // 首个启用哨兵可能刚出现
        return true
    }

    func toggleSentinel(id: UUID) {
        guard let i = sentinels.firstIndex(where: { $0.id == id }) else { return }
        sentinels[i].enabled.toggle()
        try? persistence?.upsertMailboxSentinel(sentinels[i])
        startScheduler()
    }

    /// 删哨兵: 连带清它的线程与拒收日志 (PersistenceStore 侧事务); 账号回到空闲池 (绑定是配置态, 随哨兵消失)。
    func removeSentinel(id: UUID) {
        sentinels.removeAll { $0.id == id }
        rejections.removeAll { $0.sentinelId == id }
        let dropped = Set(tasks.filter { $0.sentinelId == id }.map(\.id))
        tasks.removeAll { $0.sentinelId == id }
        queuedTurns = queuedTurns.filter { !dropped.contains($0.key) }
        pendingTurns = pendingTurns.filter { !dropped.contains($0.key) }
        if let rid = runningTaskId, dropped.contains(rid) { runningTaskId = nil }
        // 结算基线/计时按 sid 记 (不是 taskId): 清掉已无任务归属的那些
        turnBaseline = turnBaseline.filter { sid, _ in tasks.contains { $0.sessionId == sid } }
        turnStart = turnStart.filter { sid, _ in tasks.contains { $0.sessionId == sid } }
        try? persistence?.deleteMailboxSentinel(id: id)
        try? credentials.setSentinelSecret(nil, sentinelId: id)
    }

    // MARK: - 调度 (每秒 tick, 按各哨兵自有间隔判到期)

    func startScheduler() {
        guard timer == nil, sentinels.contains(where: { $0.enabled }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stopScheduler() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard sentinels.contains(where: { $0.enabled }) else { stopScheduler(); return }
        Task { await pollOnce() }
    }

    /// 单轮 (冒烟直测): 遍历 enabled 且到期的哨兵 → 各自 poll → 逐封走 10 步处理; 收尾补跑队列。
    func pollOnce(force: Bool = false) async {
        guard !polling else { return }   // 上一轮 poll 未收尾 → 不叠
        polling = true
        defer { polling = false }
        let now = Date()
        for sentinel in sentinels where sentinel.enabled {
            guard let account = accounts.first(where: { $0.id == sentinel.accountId }) else {
                setNotice(String(format: L("Inbox「%@」: 绑定的邮箱账号已不存在"), sentinel.name))
                continue
            }
            if !force, let last = sentinel.lastPollAt,
               now.timeIntervalSince(last) < Double(max(sentinel.pollInterval, 5)) { continue }
            await pollSentinel(sentinel, account: account, now: now)
        }
        driveQueue()
    }

    private func pollSentinel(_ sentinel: MailboxSentinel, account: MailboxAccount, now: Date) async {
        guard let transport = transport(for: account) else {
            markPoll(sentinel.id, at: now, error: L("收件实现未接入 (P10.2c)"))
            setNotice(String(format: L("Inbox「%@」: 收件实现未接入 (P10.2c)"), sentinel.name))
            return
        }
        do {
            let mails = try await transport.poll()
            markPoll(sentinel.id, at: now, error: nil)
            for mail in mails {
                await handle(mail, sentinel: sentinel, transport: transport)
            }
        } catch {
            let msg = (error as? MailTransportError)?.label ?? String(describing: error)
            markPoll(sentinel.id, at: now, error: msg)
            setNotice(String(format: L("Inbox「%@」: %@"), sentinel.name, msg))
        }
    }

    func testConnection(accountId: UUID) async -> String {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return L("账号不存在") }
        guard let t = transport(for: account) else { return L("收件实现未接入 (P10.2c)") }
        return await t.testConnection() ?? L("连接正常")
    }

    /// 丢弃该账号的缓存连接实例。**任何改动连接参数 (host / address) 或凭据的写入都必须调用** ——
    /// `CurlMailTransport` 在 init 就把 account 与授权码吃成**快照**, 不丢弃的话"改完配置再测试"
    /// 测的仍是旧配置 (2026-09-18 联调实测: 163 改 QQ 后点测试连接, 仍报 163 时代的错)。
    private func invalidateTransport(_ id: UUID) { transports[id] = nil }

    private func transport(for account: MailboxAccount) -> (any MailTransport)? {
        if let t = transports[account.id] { return t }
        let made = makeTransport?(account)
            ?? CurlMailTransport(account: account, auth: credentials.accountAuth(accountId: account.id))
        transports[account.id] = made
        return made
    }

    // MARK: - 单封邮件的 10 步处理 (§四)

    private func handle(_ mail: RawMail, sentinel: MailboxSentinel, transport: any MailTransport) async {
        let now = Date()
        let secret = credentials.sentinelSecret(sentinelId: sentinel.id)
        let sender = Self.address(of: mail.from)

        // ③ 线程定位必须在身份闸之前 —— 身份闸要判"首封还是后续轮", 而这取决于 References 是否命中 thread_key
        let located = locate(mail, sentinel: sentinel)

        // ①②③④ 四道闸
        let gate = Self.gate(mail: mail, whitelist: sentinel.whitelist,
                             requireSecret: sentinel.requireSecret, secret: secret,
                             isFollowUp: located != nil,
                             alreadySeen: alreadySeen(mail, sentinel: sentinel, located: located),
                             now: now)
        guard gate == .pass else {
            await reject(gate, mail: mail, sentinel: sentinel, secret: secret, transport: transport)
            return
        }

        // ⑥ 清洗 (主题剥 secret → title; 正文引用行截断 → prompt)
        let title = Self.cleanSubject(mail.subject, secret: secret, sender: sender)
        let prompt = Self.cleanBody(mail.body)
        guard !prompt.isEmpty else {
            // 纯 HTML / 空正文: 显式回执 (不静默吞), 但非身份问题 → 不进拒收日志
            await replyOnce("mailbox.body_empty.\(sentinel.id.uuidString).\(sender.lowercased())",
                            mail: mail, sentinel: sentinel, transport: transport, title: title,
                            body: "邮件正文为空 (或只有 HTML): 请以纯文本发送任务内容。")
            return
        }

        // ⑦ 项目快照: 首封写 project_id, 后续轮读列不读哨兵配置 (否则历史线程 cwd 集体漂移)
        var task = located ?? MailboxTask(sentinelId: sentinel.id, threadKey: mail.messageId,
                                          projectId: sentinel.projectId, title: title)
        task.title = title
        task.lastMessageId = mail.messageId
        task.updatedAt = now

        // ⑧ 目录校验 (projectId 非空时; 不过 → FAILED + 回执, 不 fire)
        let cwd: String?
        if let pid = task.projectId {
            let path = store?.projects.first(where: { $0.id == pid })?.path
            guard let path, Self.isDirectory(path) else {
                task.status = .failed
                task.blockedReason = "项目目录不存在: \(path ?? "<未绑定路径>")"
                persistTask(task)
                setNotice(String(format: L("Inbox「%@」: 项目目录不存在, 任务未执行"), sentinel.name))
                await replyOnce("mailbox.dir_missing.\(task.id.uuidString)",
                                mail: mail, sentinel: sentinel, transport: transport, title: title,
                                body: "[MGOX][FAILED] 项目目录不存在: \(path ?? "<未绑定路径>")\n任务未执行。")
                return
            }
            cwd = path
        } else {
            cwd = nil   // 无项目 → PiRpcTransport 回落 NSHomeDirectory() (与 ScheduledTask 同语义)
        }

        try? await transport.markRead(mail)

        // ⑨ 入队 (全局串行)
        let pending = PendingTurn(prompt: prompt, to: sender, inReplyTo: mail.messageId)
        guard runningTaskId == nil else {
            enqueue(task: task, pending: pending, currentlyRunning: runningTaskId)
            return
        }

        // ⑩ fire
        fire(task: task, sentinel: sentinel, pending: pending, cwd: cwd)
    }

    /// ⑩ fire: 新线程建会话 (有项目归入该项目 → 远程会话在 conversations 里天然归组可见),
    /// 续跑沿用 task.sessionId (同 sessionId 的 cwd 恒定 → 永不触发 teardownProcess)。
    private func fire(task: MailboxTask, sentinel: MailboxSentinel, pending: PendingTurn, cwd: String?) {
        guard let store else { return }
        var t = task
        let sessionAlive = t.sessionId.map { sid in store.allConversations.contains { $0.id == sid } } ?? false
        if !sessionAlive {
            let item = ConversationItem(title: "✉ " + t.title)
            if let pid = t.projectId, let g = store.projects.firstIndex(where: { $0.id == pid }) {
                store.projects[g].items.insert(item, at: 0)
                try? store.persistence?.insertChatSession(item, projectId: pid)
            } else {
                store.chats.insert(item, at: 0)
                try? store.persistence?.insertChatSession(item)
            }
            t.sessionId = item.id
        }
        guard let sid = t.sessionId else { return }
        // 该会话已有回合在途 (用户自己正在里面干活) → 让路排队, 不双流
        guard !store.runningTurns.contains(sid) else {
            enqueue(task: t, pending: pending, currentlyRunning: nil)   // 串行位空闲 (调用方已保证), 只是会话被用户占着
            return
        }
        t.status = .running
        t.updatedAt = Date()
        persistTask(t)
        runningTaskId = t.id
        // P10.2b: 结算基线 (本回合产出 = 基线之后的消息) + 回执上下文 (回给谁 / 回哪封)
        turnBaseline[sid] = store.replayMessages(for: sid).count
        turnStart[sid] = Date()
        pendingTurns[t.id] = pending
        // prompt 落屏/落库 (对齐 SchedulerService: beginTurn 只发不落, 会话否则是空的)
        let msg = ChatMessage(role: .user, content: .text(pending.prompt))
        store.persistMessage(msg, sid: sid)
        if store.selectedConversationId == sid { store.messages.append(msg) }
        store.beginTurn(sid: sid, prompt: pending.prompt, ephemeral: false,   // 拍板 5: 真 session, 与 Scheduled 不同路
                        cwd: cwd, unattended: true,
                        modeOverride: sentinel.agentMode,                  // 拍板 7: full (含全部托管扩展)
                        approvalOverride: sentinel.approval)               // 拍板 8: autoJudge (拒且不阻塞)
    }

    /// 入队一个待执行回合 (`currentlyRunning` = 此刻占着串行位的 taskId, 空闲传 nil)。
    /// 两条纪律, 都是 2026-09-20 审多轮路径时踩出来的:
    /// ① **在途任务的状态不许被降级** —— 同线程的追加指令 (用户对回执点「回复」再补一句, 或连发两封)
    ///    会命中 `located` = 正在跑的那个任务。无条件写 `.queued` 会让 `noteTurnFinished` 的
    ///    `status == .running` 查找落空 → 串行位 `runningTaskId` 永不释放 → **整个邮箱域死锁**
    ///    (不只是这一封: 之后所有哨兵的邮件都只进不出)。
    /// ② 同线程连发 → **合并**成一轮 (回执锚定最新那封), 不做"后一封覆盖前一封" —— 覆盖 = 静默丢指令。
    private func enqueue(task: MailboxTask, pending: PendingTurn, currentlyRunning running: UUID?) {
        var t = task
        if running != t.id { t.status = .queued }
        queuedTurns[t.id] = queuedTurns[t.id].map {
            PendingTurn(prompt: $0.prompt + "\n\n" + pending.prompt,
                        to: pending.to, inReplyTo: pending.inReplyTo)
        } ?? pending
        persistTask(t)   // 在途分支也要落: title / lastMessageId (幂等游标) 得更新
    }

    /// 回合落定钩子 (ChatStore 在 streamEnded / stopTurn 处回调):
    /// **结算 → 回执 → 释放串行位 → 补跑队列**。
    /// `blocks` = 本回合被 `autoJudge` 拦下的命令 (`AgentTransport.autoJudgeBlocks`) —— 它是
    /// "blocked 也照样回执"的信息来源 (拍板 8: 用不阻塞的自动裁决替代邮件确认流, 卡点必须让用户看见)。
    func noteTurnFinished(sid: UUID, blocks: [AutoJudgeBlock] = []) {
        guard let i = tasks.firstIndex(where: { $0.sessionId == sid && $0.status == .running }) else {
            driveQueue()   // 不是远程回合 (普通会话): 与我无关, 但仍补一次队列
            return
        }
        let task = tasks[i]
        let sentinel = sentinels.first { $0.id == task.sentinelId }

        // 结算: 本回合产出 = 基线之后的消息 (逐消息 usage 聚合; sessionStats 只覆盖选中会话, 见 MailboxReply)
        let all = store?.replayMessages(for: sid) ?? []
        let base = turnBaseline.removeValue(forKey: sid) ?? 0
        let produced = Array(all.dropFirst(min(base, all.count)))
        let output = MailboxReplyComposer.lastAssistantText(produced)
        let elapsed = turnStart.removeValue(forKey: sid).map { Date().timeIntervalSince($0) } ?? 0
        let stats = MailboxReplyStats.aggregate(produced, elapsed: elapsed)

        // 状态机: 有拦截 → blocked (命令没跑, 但回合正常结束); 无产出 → failed; 其余 → done
        let status: MailboxReplyStatus = !blocks.isEmpty ? .blocked : (output.isEmpty ? .failed : .done)
        tasks[i].status = status == .blocked ? .blocked : (status == .done ? .done : .failed)
        tasks[i].blockedReason = blocks.isEmpty
            ? nil
            : blocks.map { "\($0.command) — \($0.reason)" }.joined(separator: "; ")
        tasks[i].updatedAt = Date()
        persistTask(tasks[i])
        if runningTaskId == task.id { runningTaskId = nil }

        if let sentinel, let pending = pendingTurns.removeValue(forKey: task.id) {
            sendReply(task: tasks[i], sentinel: sentinel, pending: pending,
                      status: status, output: output, stats: stats, blocks: blocks)
        }
        driveQueue()
    }

    /// 会话被删除 (ChatStore.evictTransport 回调): 该会话的线程失去落点 → 判失败, 释放串行位。
    /// 不发回执 (会话都没了, 用户已主动放弃这一线程)。
    func noteSessionEvicted(sid: UUID) {
        turnBaseline[sid] = nil
        turnStart[sid] = nil
        guard let i = tasks.firstIndex(where: { $0.sessionId == sid }) else { return }
        if tasks[i].status == .running || tasks[i].status == .queued {
            tasks[i].status = .failed
            tasks[i].blockedReason = "会话已被删除"
            tasks[i].updatedAt = Date()
            persistTask(tasks[i])
        }
        pendingTurns[tasks[i].id] = nil
        queuedTurns[tasks[i].id] = nil
        if runningTaskId == tasks[i].id { runningTaskId = nil }
        driveQueue()
    }

    /// 队列补跑 (最旧优先)。回合上下文不落库 → 重启后队列已在 reload 里判失败, 这里只跑内存里还有的。
    /// **以 `queuedTurns` 为准而不是 `tasks.status == .queued`**: 在途任务收下的追加指令保持 `running`
    /// 状态 (见 `enqueue` 纪律 ①), 按 status 找会把它整个漏掉 (下一封就再也发不出去了)。
    private func driveQueue() {
        guard runningTaskId == nil,
              let next = queuedTurns.keys.compactMap({ id in tasks.first { $0.id == id } })
                  .min(by: { $0.createdAt < $1.createdAt }),
              let pending = queuedTurns[next.id],
              let sentinel = sentinels.first(where: { $0.id == next.sentinelId }) else { return }
        let cwd = next.projectId.flatMap { pid in store?.projects.first(where: { $0.id == pid })?.path }
        queuedTurns[next.id] = nil
        fire(task: next, sentinel: sentinel, pending: pending, cwd: cwd)
    }

    // MARK: - 回执发送 (P10.2b)

    /// 组装 + 发回执。主题状态机 + 短 id + In-Reply-To/References 由纯函数给出 (MailboxReply.swift)。
    /// 发送是 fire-and-forget (`noteTurnFinished` 在同步的事件归并里调用): 失败落横幅, 不影响回合收尾。
    private func sendReply(task: MailboxTask, sentinel: MailboxSentinel, pending: PendingTurn,
                           status: MailboxReplyStatus, output: String,
                           stats: MailboxReplyStats, blocks: [AutoJudgeBlock]) {
        guard let account = accounts.first(where: { $0.id == sentinel.accountId }),
              let transport = transport(for: account) else {
            setNotice(String(format: L("回执未发出: Inbox「%@」的账号/收件实现不可用"), sentinel.name))
            return
        }
        let mail = OutgoingMail(
            to: pending.to,
            subject: MailboxReplyComposer.subject(status: status, taskId: task.id, title: task.title),
            body: MailboxReplyComposer.body(status: status, output: output, stats: stats, blocks: blocks),
            inReplyTo: pending.inReplyTo,
            references: MailboxReplyComposer.referenceChain(threadKey: task.threadKey,
                                                            inReplyTo: pending.inReplyTo),
            messageId: Self.replyMessageId(taskId: task.id))
        Task { @MainActor in
            do { try await transport.send(mail) }
            catch {
                setNotice(String(format: L("回执发送失败: %@"), (error as? MailTransportError)?.label ?? String(describing: error)))
            }
        }
    }

    // MARK: - 未过闸的分层处理 (决定 14)

    private func reject(_ gate: MailboxGate, mail: RawMail, sentinel: MailboxSentinel,
                        secret: String?, transport: any MailTransport) async {
        let sender = Self.address(of: mail.from)
        if let reason = gate.rejectionReason {
            // 主题摘要 120 字 + 已剥 secret (拒收日志同样受"密钥不扩散"约束)
            let rec = MailboxRejection(sentinelId: sentinel.id, sender: mail.from,
                                       subject: Self.cleanSubject(mail.subject, secret: secret, sender: sender),
                                       reason: reason, messageId: mail.messageId, at: Date())
            recordRejection(rec)
        }
        switch gate {
        case .notWhitelisted:
            // 标已读 + 移 Trash, **不回执** (硬删即永久丢失线索, 故用 Trash)
            try? await transport.markRead(mail)
            try? await transport.moveToTrash(mail)
        case .missingIntent, .secretMissing, .secretMismatch:
            await replyOnce(Self.gateReplyKey(sentinelId: sentinel.id, sender: sender),
                            mail: mail, sentinel: sentinel, transport: transport,
                            title: Self.cleanSubject(mail.subject, secret: secret, sender: sender),
                            body: Self.gateReplyBody(gate))
        case .stale, .duplicate, .pass:
            break   // 静默跳过 (标已见由上游 Message-ID 游标承担)
        }
    }

    /// 回执一次: 主题已剥 secret (硬要求 —— 否则 secret 随回执扩散到锁屏通知/邮件列表/服务商日志);
    /// 同 key 24h 内只发一次。
    private func replyOnce(_ key: String, mail: RawMail, sentinel: MailboxSentinel,
                           transport: any MailTransport, title: String, body: String) async {
        guard canReplyOnce(key: key) else { return }
        let reply = OutgoingMail(to: mail.from, subject: "[MGOX][FAILED] " + title,
                                 body: body, inReplyTo: mail.messageId,
                                 references: [mail.messageId])
        do { try await transport.send(reply) }
        catch { setNotice(String(format: L("回执发送失败: %@"), (error as? MailTransportError)?.label ?? String(describing: error))) }
    }

    private func canReplyOnce(key: String) -> Bool {
        guard let p = persistence else { return true }
        let now = Date().timeIntervalSince1970
        if let raw = p.loadSettingText(key: key), let last = Double(raw),
           now - last < Self.gateReplyWindow { return false }
        p.saveSettingText(key: key, value: String(now))
        return true
    }

    nonisolated static func gateReplyKey(sentinelId: UUID, sender: String) -> String {
        "mailbox.gate_reply.\(sentinelId.uuidString).\(sender.lowercased())"
    }

    nonisolated static func gateReplyBody(_ gate: MailboxGate) -> String {
        switch gate {
        case .missingIntent:
            return "邮件未被受理: 主题缺少 \(intentMarker) 意图标记。\n\n请在主题里加上 \(intentMarker) 后重发 (该 Inbox 若开启密钥闸, 还需带上共享密钥)。"
        case .secretMissing:
            return "邮件未被受理: 该 Inbox 开启了密钥闸, 但 MangoX 侧没有可用的共享密钥。\n\n请在 Scheduled 页打开该 Inbox 重新填写密钥。"
        case .secretMismatch:
            return "邮件未被受理: 主题里的密钥与 MangoX 里配置的不一致。\n\n请核对后重发 (该提示同地址 24 小时内只发一次)。"
        default:
            return "邮件未被受理。"
        }
    }

    // MARK: - 纯函数: 鉴权四道闸 (确定性规则, 模型不参与)

    /// 顺序: ①白名单 → ②身份 (首封: 意图标记 + 密钥闸 / 后续轮: References 命中即过) → ③时效 (只首封) → ④幂等。
    nonisolated static func gate(mail: RawMail, whitelist: [String], requireSecret: Bool, secret: String?,
                     isFollowUp: Bool, alreadySeen: Bool, now: Date = Date()) -> MailboxGate {
        let sender = address(of: mail.from).lowercased()
        guard whitelist.contains(where: { $0.lowercased() == sender }) else { return .notWhitelisted }
        if !isFollowUp {
            guard mail.subject.contains(intentMarker) else { return .missingIntent }
            if requireSecret {
                // 缺 / 错的分界: 哨兵侧无密钥可用 = 配置缺失 (missing); 有密钥但主题对不上 = 写错 (mismatch)。
                // 两者对用户的可操作动作相同 (去核对密钥), 分开只为排查定位。
                guard let secret, !secret.isEmpty else { return .secretMissing }
                guard mail.subject.contains(secret) else { return .secretMismatch }
            }
            if let date = mail.date, now.timeIntervalSince(date) > firstMailWindow { return .stale }
        }
        if alreadySeen { return .duplicate }
        return .pass
    }

    // MARK: - 纯函数: 清洗 (决定 13)

    /// 主题清洗 —— `mailbox_tasks.title` 与**回执主题**共用同一份:
    /// ① 循环剥 `Re:` / `Re[2]:` / `Fwd:` / `Fw:` / `回复:` / `转发:` ② 剥 `[MGOX]`、`[MGOX-<id8>]`
    /// 与**状态 tag 残片** `[DONE]` / `[BLOCKED]` / `[FAILED]` / `[RUNNING]` (多轮里必现) ③ **剥 secret
    /// 子串 (硬要求: 漏掉即随每封回执扩散)** ④ trim + 折叠空白 + 截断 120 字 ⑤ 结果为空 → `来自 <sender>` 占位。
    nonisolated static func cleanSubject(_ subject: String, secret: String?, sender: String) -> String {
        var s = subject
        // 前缀可重复出现 (`Re: Fwd: Re: 任务`) → 循环剥
        let prefixRe = "^\\s*(re|fwd?|回复|答复|转发)(\\[\\d+\\])?\\s*:\\s*"
        while let r = s.range(of: prefixRe, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        s = s.replacingOccurrences(of: intentMarker, with: " ")
        s = s.replacingOccurrences(of: Self.statusTagPattern, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[MGOX-[0-9a-fA-F]{1,8}\\]", with: " ",
                                   options: .regularExpression)
        if let secret, !secret.isEmpty { s = s.replacingOccurrences(of: secret, with: " ") }
        s = collapseWhitespace(s)
        if s.count > 120 { s = String(s.prefix(120)) }
        return s.isEmpty ? "来自 \(sender)" : s
    }

    /// 正文清洗 —— 取消命令模板后它是必做项 (§四): 不截断则第 3 轮 prompt 会内嵌前两轮全文
    /// (context 翻倍 / 语义混乱 / 重复执行上轮动作)。
    /// **边界**: 第 1 行即引用 (整封都是引用块) → 不截断 (用户很可能把引用块本身当任务输入)。
    nonisolated static func cleanBody(_ body: String) -> String {
        let lines = body.components(separatedBy: .newlines)
        // 边界: 首个非空行即引用 → 整封都是引用块 (用户很可能把引用内容本身当任务输入, 如"基于这段配置改写"),
        // 截断会把任务吃掉 → 全文保留。
        if let head = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           isQuoteLine(head) {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var cut: Int?
        for (i, line) in lines.enumerated() where i > 0 {
            if isQuoteLine(line) { cut = i; break }
        }
        let kept = cut.map { Array(lines[0..<$0]) } ?? lines
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 引用行判定 — 覆盖 Gmail / Apple Mail / 163 webmail / **QQ webmail / 通用纯分隔线**。
    /// 认不出来的后果不是"多留几行": 第二轮起的 prompt 会内嵌上一轮全文 (context 翻倍 + agent
    /// 重跑上轮动作), 所以每加一个真机见过的分隔格式就加一条规则。
    nonisolated static func isQuoteLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(">") { return true }
        if t.hasPrefix("-----Original Message-----") { return true }
        if t.hasPrefix("On ") && t.hasSuffix("wrote:") { return true }   // Gmail / Apple Mail
        if t.contains("写道：") || t.contains("写道:") { return true }     // 163 / Apple Mail 中文
        if t.contains("原始邮件") { return true }                        // QQ webmail: `------ 原始邮件 ------`
        if t.count >= 10, t.allSatisfy({ $0 == "-" }) { return true }    // 纯分隔线 (≥10 个 `-`, 不误伤 markdown 的 `---`)
        return false
    }

    /// trim + 折叠连续空白 (含换行) 为单空格 —— 主题是单行。
    nonisolated static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - 纯函数: 线程定位 (§3.3)

    /// 规范化 Message-ID: 去尖括号 + trim (MimeParser 侧已规范, 引用链自行兜一层)。
    nonisolated static func normalizeMessageId(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") { s.removeFirst() }
        if s.hasSuffix(">") { s.removeLast() }
        return s
    }

    /// 回执**状态 tag 的残片**匹配式 (`[DONE]` / `[BLOCKED]` / `[FAILED]` / `[RUNNING]`)。
    /// 回执主题是 `[MGOX][DONE] <title>` (见 MailboxReplyComposer.subject); 用户对回执点「回复」时
    /// 句首的 `[MGOX]` 被上一条剥掉, **只剩 `[DONE]` 留在主题里** —— 不剥它, title 会逐轮累积
    /// (`[DONE] [DONE] … 任务`), 回执主题一路滚长, 会话列表也跟着脏。
    /// 由 `MailboxReplyStatus` 派生: 状态机加档时只改 MailboxReply.swift, 这里不会失配。
    nonisolated static var statusTagPattern: String {
        "\\[(?:" + MailboxReplyStatus.allCases.map { $0.rawValue.uppercased() }.joined(separator: "|") + ")\\]"
    }

    /// 回执自铸 id: `<task-<id8>@mangox.local>` (链路闸的锚点; 用户无需手打)。
    nonisolated static func replyMessageId(taskId: UUID) -> String { "task-\(shortId(taskId))@mangox.local" }

    /// 短 id (8 位小写) —— 主题标记 `[MGOX-<id8>]` 与自铸 Message-ID 共用。
    nonisolated static func shortId(_ taskId: UUID) -> String { String(taskId.uuidString.prefix(8)).lowercased() }

    nonisolated static func shortIdMarker(_ taskId: UUID) -> String { "[MGOX-\(shortId(taskId))]" }

    /// From 头 → 裸地址 (剥 `Name <a@b.c>` 包裹)。
    nonisolated static func address(of from: String) -> String {
        if let l = from.firstIndex(of: "<"), let r = from.firstIndex(of: ">"), l < r {
            return String(from[from.index(after: l)..<r]).trimmingCharacters(in: .whitespaces)
        }
        return from.trimmingCharacters(in: .whitespaces)
    }

    /// `task-<id8>@mangox.local` → id8
    nonisolated static func taskShortId(fromReplyMessageId id: String) -> String? {
        guard id.hasPrefix("task-") else { return nil }
        let rest = id.dropFirst("task-".count)
        guard let at = rest.firstIndex(of: "@") else { return nil }
        let sid = String(rest[rest.startIndex..<at]).lowercased()
        return sid.isEmpty ? nil : sid
    }

    /// 主题里的 `[MGOX-<id8>]` (References 被客户端剥掉时的兜底)
    nonisolated static func shortId(fromSubject subject: String) -> String? {
        guard let r = subject.range(of: "\\[MGOX-([0-9a-fA-F]{1,8})\\]", options: .regularExpression)
        else { return nil }
        return String(subject[r].dropFirst("[MGOX-".count).dropLast()).lowercased()
    }

    /// 线程定位: References / In-Reply-To 命中 thread_key 或回执自铸 id → 后续轮; 主题短 id 兜底。
    /// **先按 sentinel_id 过滤再匹配 thread_key** (线程键只在哨兵内唯一, 不同邮箱天然隔离)。
    private func locate(_ mail: RawMail, sentinel: MailboxSentinel) -> MailboxTask? {
        var candidates = mail.references.map(Self.normalizeMessageId)
        if let r = mail.inReplyTo { candidates.append(Self.normalizeMessageId(r)) }
        for c in candidates where !c.isEmpty {
            if let t = tasks.first(where: { $0.sentinelId == sentinel.id && $0.threadKey == c }) { return t }
            if let sid = Self.taskShortId(fromReplyMessageId: c),
               let t = tasks.first(where: { $0.sentinelId == sentinel.id && Self.shortId($0.id) == sid }) { return t }
        }
        if let sid = Self.shortId(fromSubject: mail.subject),
           let t = tasks.first(where: { $0.sentinelId == sentinel.id && Self.shortId($0.id) == sid }) { return t }
        return nil
    }

    /// 幂等闸: 该 Message-ID 是否已是某线程的游标 (重复投递不重复执行)。
    private func alreadySeen(_ mail: RawMail, sentinel: MailboxSentinel, located: MailboxTask?) -> Bool {
        if let located { return located.lastMessageId == mail.messageId }
        return tasks.contains { $0.sentinelId == sentinel.id && $0.lastMessageId == mail.messageId }
    }

    // MARK: - 落库 / 工具

    private func persistTask(_ t: MailboxTask) {
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
        try? persistence?.upsertMailboxTask(t)
    }

    private func markPoll(_ id: UUID, at now: Date, error: String?) {
        guard let i = sentinels.firstIndex(where: { $0.id == id }) else { return }
        sentinels[i].lastPollAt = now
        sentinels[i].lastError = error
        try? persistence?.upsertMailboxSentinel(sentinels[i])
    }

    private func setNotice(_ s: String?) { mailboxNotice = s }

    private nonisolated static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// 该哨兵的拒收记录 (内存缓存过滤; 时间倒序)。
    func recentRejections(sentinelId: UUID) -> [MailboxRejection] {
        rejections.filter { $0.sentinelId == sentinelId }
    }

    /// 记一条拒收 (落库 + 内存缓存同步裁剪)。**唯一入口** —— 生产路径与冒烟都走它, 避免两套规则漂移。
    func recordRejection(_ rejection: MailboxRejection) {
        try? persistence?.appendMailboxRejection(rejection)
        rejections.append(rejection)
        rejections.sort { $0.at > $1.at }
        trimRejections()
    }

    /// 内存侧每哨兵只留最近 200 条 (与 `PersistenceStore.mailboxRejectionLimit` 同值; 倒序故先来先留)。
    private func trimRejections() {
        var kept: [MailboxRejection] = []
        var counts: [UUID: Int] = [:]
        for rejection in rejections {
            let seen = counts[rejection.sentinelId, default: 0]
            guard seen < PersistenceStore.mailboxRejectionLimit else { continue }
            kept.append(rejection)
            counts[rejection.sentinelId] = seen + 1
        }
        rejections = kept
    }

    // MARK: - P10.2d: Settings 面板支撑

    /// 账号授权码 (Keychain)。**UI 不回显已存值** —— 只显示"已设置/未设置", 保存时留空即不动。
    func accountAuth(accountId: UUID) -> String? { credentials.accountAuth(accountId: accountId) }

    func hasAccountAuth(accountId: UUID) -> Bool {
        !(credentials.accountAuth(accountId: accountId) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    func setAccountAuth(_ value: String?, accountId: UUID) {
        try? credentials.setAccountAuth(nonEmptySecret(value), accountId: accountId)
        invalidateTransport(accountId)   // 授权码同样是实例里的 init 快照
    }

    /// 哨兵共享密钥 (Keychain)。
    func sentinelSecret(sentinelId: UUID) -> String? { credentials.sentinelSecret(sentinelId: sentinelId) }

    func hasSentinelSecret(sentinelId: UUID) -> Bool {
        !(credentials.sentinelSecret(sentinelId: sentinelId) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 关掉密钥闸时**不清密钥** —— 关掉再打开不必重录 (决定 13 的开关只管校验与否)。
    func setSentinelSecret(_ value: String?, sentinelId: UUID) {
        try? credentials.setSentinelSecret(nonEmptySecret(value), sentinelId: sentinelId)
    }

    private func nonEmptySecret(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "测试连接" (§7.1): 跑一遍 IMAP 登录 + 列 INBOX; nil = 成功, 非 nil = 错误文案。
    /// SMTP 不单独握手 —— 两处共用同一授权码, IMAP 通了凭据即可用; host/端口写错会在这里立刻暴露。
    func testConnection(accountId: UUID) async -> String? {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return L("账号不存在") }
        guard let transport = transport(for: account) else { return L("无法建立连接实例") }
        return await transport.testConnection()
    }

    /// 拒收行快捷动作 (§7.3): 直接写进该哨兵白名单 —— 首次配置时补漏加地址的最快路径。
    /// 存发件人原样 (门比较时已大小写不敏感), 重复地址不重复追加。
    func addToWhitelist(sentinelId: UUID, address: String) {
        guard let i = sentinels.firstIndex(where: { $0.id == sentinelId }) else { return }
        let normalized = Self.address(of: address).lowercased()
        guard !normalized.isEmpty else { return }
        guard !sentinels[i].whitelist.contains(where: { Self.address(of: $0).lowercased() == normalized }) else { return }
        sentinels[i].whitelist.append(address)
        try? persistence?.upsertMailboxSentinel(sentinels[i])
    }

    /// 跨哨兵最近拒收 (时间倒序; 内存缓存直读, Settings 面板用)。
    func allRecentRejections(limit: Int = 50) -> [MailboxRejection] {
        Array(rejections.prefix(limit))
    }

    /// 状态行: 排队中 (received/queued) 的任务数。
    var queuedTaskCount: Int {
        tasks.filter { $0.status == .received || $0.status == .queued }.count
    }

    /// 状态行: 正在跑的线程 (全局串行位; nil = 空闲)。
    var runningTask: MailboxTask? {
        guard let id = runningTaskId else { return nil }
        return tasks.first { $0.id == id }
    }

    /// 状态行: 最近一轮 poll 时刻 (取各哨兵 lastPollAt 最新者)。
    var lastPollAt: Date? { sentinels.compactMap(\.lastPollAt).max() }
}
