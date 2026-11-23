//
//  RemoteChannelService.swift
//  P19.2 S15/S15b —— 飞书通道的**状态机与投递**（桥 / 消息落地 / 回复回流 都在这里收口）。
//
//  ── 四条边界 ────────────────────────────────────────────────────────────────
//  ① **绑定的键是 `bot_id`**（S15b）。`chat_id` 是运行时地址，只用来把回复送回去。
//     "一个机器人只归一个助理"由 `remote_bots.assistant_id` 单值列保证。
//  ② **一个助理只有一场会话**（P19 既有约束）: 消息进来 → 投进那个助理的 `logSessionId`。
//     没有"通道会话"这种第二类会话，所以换通道不会换上下文。
//  ③ **桥是哑的**：要不要回、回给谁，全在这一层判。桥里只有协议。
//  ④ **只回"从飞书来的那一轮"**：`remoteTurns` 记住这一轮是谁、从哪个机器人发起的，收尾时认领。
//     否则你在电脑上随口问一句，飞书那边也会响一声 —— 那是把通道变成噪音源。
//
//  ── 「助理开启 ⇒ 监听开启」，但反过来**不成立** ─────────────────────────────
//  连接跟着「机器人启用 + 配了 secret」走，**不跟助理开关走**。
//  理由是一条实测: 飞书侧一旦没有活着的长连接（也没配 webhook），人在飞书里**根本发不出消息**
//  （输入框变灰「暂时无法给该机器人发消息」）。如果助理一停就断桥，人看到的是"机器人坏了"，
//  而不是"我把助理关了"。所以助理停用时桥照旧连着，只是回一句"先在 MangoX 里把它打开"。
//
//  ── 明写在界面上的前提 ──────────────────────────────────────────────────────
//  · **App 得开着**。桥是 App 的子进程，App 退了它就退。
//  · 飞书没有"列出我的单聊"的接口（实测 `GET /im/v1/chats` 只返回机器人所在的群，且 0 条），
//    所以"谁来找过我"只能靠真的收到过消息 —— 那张表在设置页，是**诊断**，不是绑定的入口
//    （S15b 之后绑定在助理那边选机器人，不再选单聊）。
//

import Foundation

@MainActor
final class RemoteChannelService: ObservableObject {

    /// 冒烟进程**绝不自动起桥** —— 那会 spawn 一个 node 去连真实的飞书租户，
    /// 收到真人消息还会往库里写。与"落盘类测试必须重定向"是同一条纪律。
    /// 注入 `FakeRemoteLink` 的实例不受影响（`link != nil`）。
    #if SMOKE
    static var autostartDisabled = true
    #else
    static var autostartDisabled = false
    #endif

    enum Phase: Equatable {
        case off
        case connecting
        case up
        case failed(String)

        var text: String {
            switch self {
            case .off: return L("未启用")
            case .connecting: return L("正在连接…")
            case .up: return L("通道开着（App 关掉就断）")
            case .failed(let m): return m
            }
        }
    }

    /// 收到过消息、但**不代表任何绑定**的会话记录。S15b 之后它的唯一用途是诊断:
    /// "这个机器人到底通不通、上一次是谁跟它说的、说了什么"。
    struct RemoteChat: Codable, Equatable, Identifiable {
        /// 哪个机器人收到的。`nil` = 旧版落的盘（那时只有一条全局配置）⇒ 显示成"旧版"。
        var botId: String?
        let chatId: String
        var openId: String
        var lastSeen: Date
        var lastText: String

        var id: String { (botId ?? "") + "|" + chatId }

        /// 界面上的短标识。飞书的 `oc_` / `ou_` 都是 30+ 位，全显示会把这一行撑爆，
        /// 而人要靠它区分"是不是同一个会话" ⇒ 取**尾部 6 位**（前缀是固定字母，没信息量）。
        var shortChat: String { "…" + chatId.suffix(6) }
        var shortSender: String { "…" + openId.suffix(6) }
    }

    /// 某个机器人此刻的状态。**不是一个全局灯** —— 三个机器人里有一个 token 过期，
    /// 全局灯写"通着"就是骗人（S15 那版只有一条全局灯，是因为只有一个机器人）。
    @Published private(set) var botPhase: [UUID: Phase] = [:]
    @Published private(set) var botNote: [UUID: String] = [:]
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var lastNote: String?
    @Published private(set) var pendingChats: [RemoteChat] = []

    /// 机器人清单（真源在 `ChatStore.remoteBots`，这里是一份**同步过来的副本**）。
    /// 副本而不是直接读 store: 冒烟可以在没有 ChatStore 的场合单独验这份逻辑。
    private(set) var bots: [RemoteBot] = []

    /// 哪些机器人的 secret 在钥匙串里。**缓存，不在渲染路径上读钥匙串** ——
    /// 设置页每画一行都要问一次"它配齐了吗"，而 `SecItemCopyMatching` 在无签名构建上
    /// 会弹授权框并**同步等答复**（卡住主线程）。缓存只在机器人集合/凭据变化时刷新。
    @Published private(set) var secretPresent: Set<UUID> = []

    private weak var store: ChatStore?
    private let secrets: RemoteSecretStore
    private var link: RemoteLink?
    /// 上一次起桥时的「谁在跑」签名。签名不变就不重起（`syncBots` 每改一次都会调）。
    private var runningSignature: [String] = []
    /// `sid -> (chatId, botId)`：这一轮是从哪条单聊、哪个机器人发起的（收尾时认领，认领即删）。
    private var remoteTurns: [UUID: (chatId: String, botId: String)] = [:]
    /// 从飞书批的那次执行 → 回推目标（`logId` → 私聊）。执行轮落定后认领一次。
    private var execReplies: [UUID: (chatId: String, botId: String)] = [:]
    /// 去重窗口。飞书在客户端网络抖动时会重推**同一个 message_id**，
    /// 不去重就是"同一句话进去两次"，而人只会觉得助理重复回答了。
    private var seenMessageIds: [String] = []
    private let seenLimit = 200
    /// 系统回复（没归/忙/停用）的冷却：同一条单聊 60 秒最多回一句。
    /// 不回不行（人以为发丢了），每句都回也不行（连发五条回来五句"还没归")。
    private var lastNoticeAt: [String: Date] = [:]
    private let noticeCooldown: TimeInterval = 60

    private let chatsFile: String

    /// **进程级**落盘根重定向（冒烟用）。与 `KnowledgeStore.agentRootOverride` 同一套纪律：
    /// 生产侧的 `ChatStore.remote` 不传 `chatsFile` ⇒ 函数级注入管不到它，夹具会写进用户真实的
    /// `~/.mangox/remote-chats.json`，而且**一个红灯都不会有**。
    nonisolated(unsafe) static var chatsFileOverride: String?

    static var defaultChatsFile: String {
        if let o = chatsFileOverride { return o }
        return NSHomeDirectory() + "/.mangox/remote-chats.json"
    }

    /// - Parameters:
    ///   - link: `nil` = 用真实桥；冒烟注入 `FakeRemoteLink`。
    ///   - chatsFile: 待绑定单聊的落盘文件。冒烟必须重定向（不然写进真实的 `~/.mangox`）。
    init(link: RemoteLink? = nil,
         secrets: RemoteSecretStore = KeychainRemoteSecretStore.current,
         chatsFile: String? = nil) {
        self.link = link
        self.secrets = secrets
        self.chatsFile = chatsFile ?? Self.defaultChatsFile
        loadChats()
    }

    func attach(_ store: ChatStore) {
        self.store = store
        syncBots(store.remoteBots, autostart: false)
    }

    /// 冒烟缝：直接换掉桥（生产不调 —— 生产只走 `start()` 建的 `FeishuBridgeLink`）。
    /// 有了它，"`ChatStore` 的收尾点真的会调 `finishRemoteTurn`" 这条**接线**才验得到；
    /// 否则只能验服务自己的逻辑，而接错线的表现是"回复永远不发"。
    func attachLink(_ l: RemoteLink) {
        link = l
        l.onFrame = { [weak self] in self?.handle($0) }
    }

    // MARK: - 机器人清单同步

    /// 汇总状态（设置页标题那一行）。**全部 off 才算 off**，有一个 fail 就亮红。
    var phase: Phase {
        guard !bots.isEmpty else { return .off }
        var sawUp = false
        var sawRun = false
        var failure: String?
        for b in bots {
            switch botPhase[b.id] ?? .off {
            case .up: sawUp = true; sawRun = true
            case .connecting: sawRun = true
            case .failed(let m): sawRun = true; failure = failure ?? m
            case .off: break
            }
        }
        if let failure { return .failed(failure) }
        if sawUp { return .up }
        return sawRun ? .connecting : .off
    }

    func phase(for botId: UUID) -> Phase { botPhase[botId] ?? .off }

    /// 「这个机器人现在到底连不连得上」—— 界面与判据共用这一处，别各自拼条件。
    ///
    /// **三个条件缺一不可**（2026-11-18 起第一条是本条的关键）：
    /// ① 它归给的助理存在且开着 —— 这是机器人**唯一的开关**（见 `RemoteBot` 文件头）；
    /// ② 填了 `app_id`；③ 钥匙串里有 `secret`。
    func isRunnable(_ bot: RemoteBot) -> Bool {
        isLive(bot) && bot.isRunnableCandidate && secretPresent.contains(bot.id)
    }

    /// 归属的助理现在开着吗。`store` 拿不到（冒烟里单独构造服务）时一律判 **false** ——
    /// 宁可少连一个，也不要在没法判的时候默认放行（"判不出来就放过"是权限类判据里最贵的错）。
    func isLive(_ bot: RemoteBot) -> Bool {
        assistant(of: bot)?.enabled ?? false
    }

    private func assistant(of bot: RemoteBot) -> ScheduledTask? {
        guard let id = bot.assistantId, let store else { return nil }
        return store.scheduler.scheduledTasks.first { $0.id == id }
    }

    /// 重新读一遍"谁有 secret"（**只在**集合/凭据变化时调，见 `secretPresent` 的注释）。
    private func refreshSecretPresence() {
        var s = Set<UUID>()
        for b in bots where (secrets.secret(for: b.id)?.isEmpty == false) { s.insert(b.id) }
        secretPresent = s
    }

    /// 由 `ChatStore` 在**任何**机器人变更（增删改 / 开关 / 换 secret）之后调。
    ///
    /// 只有"谁在跑"的签名变了才重起桥 —— 换个名字不该把长连接踢掉。
    /// 签名里含 secret 的哈希: 换凭据必须重连，而这件事**不该靠调用方记得**。
    func syncBots(_ list: [RemoteBot], autostart: Bool = true) {
        bots = list
        refreshSecretPresence()
        // 已经不在表里的机器人不该留着灯。
        let ids = Set(list.map(\.id))
        botPhase = botPhase.filter { ids.contains($0.key) }
        botNote = botNote.filter { ids.contains($0.key) }
        guard autostart else { runningSignature = []; return }
        guard Self.signature(of: list.filter { isRunnable($0) }, secrets: secrets) != runningSignature
        else { return }
        // 冒烟里不自动起（同 `autostart()`）：没人注入 link 时它真的会 spawn 一个 node。
        if Self.autostartDisabled && link == nil { return }
        restart()
    }

    /// 「谁在跑」的签名。`id + app_id + secret` —— 三者任一变了就必须重起桥
    /// （桥是按这份清单建客户端的，secret 也一并下发给它）。
    ///
    /// secret 只以**进程内的哈希**进签名，不把明文留在字符串里; 哈希的随机种子每进程变，
    /// 而这里只做"同一个进程内前后比"，够用。
    private static func signature(of list: [RemoteBot], secrets: RemoteSecretStore) -> [String] {
        list.map { b in
            let s = secrets.secret(for: b.id) ?? ""
            return "\(b.id.uuidString)|\(b.appId)|\(s.hashValue)"
        }.sorted()
    }

    // MARK: - secret 的门面（钥匙串只经服务，别在视图里直接摸）

    /// 记一笔"谁最后跟这个机器人说过话"。
    ///
    /// **刻意不走 `syncBots`**：那条路要重算签名（每个机器人一次钥匙串读），而 `lastChatId`
    /// 既不影响"连不连"也不影响签名 —— 它只决定**结论往哪推**。每收到一条消息都重算签名，
    /// 等于把一次纯内存赋值变成 N 次钥匙串访问。
    ///
    /// 但**必须**同步到这份副本：`pushFinding` 读的是它。漏了这一步，症状是
    /// "人刚跟机器人说完话，这一轮的结论却报「还没有人跟它说过话」"（2026-11-17 实测踩过）。
    func noteChat(botId: UUID, chatId: String) {
        guard let i = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[i].lastChatId = chatId
        bots[i].lastChatAt = Date()
    }

    /// **只判存在，不读出来** —— 读出来就等于把 secret 摆进界面与截图的射程
    /// （同 S7 那条 webhook 的判据）。走缓存，不碰钥匙串。
    func hasSecret(for botId: UUID) -> Bool { secretPresent.contains(botId) }

    /// 写 secret。`nil` / 空串 = 删掉。**不重启桥** —— 调用方知道刚改的是谁，
    /// 由它决定什么时候 `syncBots` / `restart`（存一半就重连会连两次）。
    @discardableResult
    func setSecret(_ secret: String?, for botId: UUID) -> Bool {
        do {
            try secrets.set(secret: secret, for: botId)
            if let s = secret, !s.isEmpty { secretPresent.insert(botId) } else { secretPresent.remove(botId) }
            return true
        } catch {
            lastNote = String(format: L("存钥匙串失败：%@"), error.localizedDescription)
            return false
        }
    }

    func forgetSecret(for botId: UUID) {
        try? secrets.set(secret: nil, for: botId)
        secretPresent.remove(botId)
    }

    // MARK: - 起停

    /// 启动（幂等）。**一个机器人都跑不了不是错误**：没配就是没配。
    ///
    /// ⚠️ 跑不起来的机器人**各自**如实标出来（缺 app_id / 缺 app_secret / 已关），
    /// 而不是一起显示"未启用" —— 后者会让人去翻开关，而真正的问题在凭据那一栏。
    func start() {
        runningSignature = []
        refreshSecretPresence()
        // 一次遍历同时算出状态与下发给桥的清单。**顺序即优先级**: 没归/助理关着 > 缺 app_id > 缺 secret。
        // 没有机器人自己的开关（2026-11-18）—— 下面的 `.off` 只有"它不归任何开着的助理"这一种来源。
        var specs: [RemoteLinkBot] = []
        for b in bots {
            guard isLive(b) else {
                botPhase[b.id] = .off
                botNote[b.id] = b.assistantId == nil
                    ? L("还没归给助理 —— 归了才会连")
                    : L("助理关着 —— 打开助理它才会连")
                continue
            }
            guard b.hasAppId else {
                botPhase[b.id] = .failed(L("缺 app_id"))
                botNote[b.id] = nil
                continue
            }
            guard let secret = secrets.secret(for: b.id), !secret.isEmpty else {
                botPhase[b.id] = .failed(L("缺 app_secret"))
                botNote[b.id] = nil
                continue
            }
            botPhase[b.id] = .connecting
            botNote[b.id] = nil
            specs.append(RemoteLinkBot(id: b.id.uuidString, appId: b.appId, secret: secret))
        }
        guard !specs.isEmpty else {
            link?.stop()
            return
        }
        let usable = bots.filter { isRunnable($0) }

        let l: RemoteLink
        if let existing = link { l = existing } else {
            let real = FeishuBridgeLink()
            link = real
            l = real
        }
        l.onFrame = { [weak self] frame in self?.handle(frame) }
        l.onExit = { [weak self] why in
            guard let self else { return }
            // 退出**不自动重启**: 自动重启会把"它反复崩"藏成一条看不见的重试循环，
            // 而人只看到"消息时有时无"。这里如实置成 failed，让人看见并能重开。
            let note = String(format: L("通道断了（%@），点「重连」"), why)
            for b in self.bots where self.isRunnable(b) { self.botPhase[b.id] = .failed(note) }
            self.lastNote = note
        }
        do {
            try l.start(bots: specs)
            runningSignature = Self.signature(of: usable, secrets: secrets)
        } catch {
            let note = error.localizedDescription
            for b in usable { botPhase[b.id] = .failed(note) }
            lastNote = note
            runningSignature = []
        }
    }

    /// 由 `ChatStore` 的启动序列调 —— 与 `start()` 的差别只在**冒烟里不自动起**。
    func autostart() {
        if Self.autostartDisabled && link == nil {
            phaseAllOff()
            return
        }
        start()
    }

    func stop() {
        link?.stop()
        runningSignature = []
        phaseAllOff()
        remoteTurns.removeAll()
    }

    /// 「重连」按钮：先停再起，并把 secret 重新读一遍（人可能刚改过）。
    func restart() {
        stop()
        start()
    }

    private func phaseAllOff() {
        for b in bots { botPhase[b.id] = .off }
    }

    // MARK: - 收

    private func handle(_ frame: RemoteFrame) {
        switch frame {
        case .status(let botId, let connected, let note):
            guard let id = Self.uuid(botId) else { return }
            if connected {
                botPhase[id] = .up
                botNote[id] = note
            } else if botPhase[id] == .up || botPhase[id] == nil || botPhase[id] == .connecting {
                botPhase[id] = .connecting
                botNote[id] = note
            } else {
                botNote[id] = note
            }
            lastNote = note
        case .error(let msg):
            lastNote = msg
            Log.event("feishu-bridge-error", "msg", msg)
        case .sendResult(let botId, let ok, let id, let msg, let ref):
            if !ok {
                lastNote = msg ?? L("发消息失败")
                if let bid = Self.uuid(botId) { botNote[bid] = msg ?? L("发消息失败") }
            }
            // 2026-11-23: 回执落到「已发消息」那一行（`ref` 就是 `agent_sent.id`）。
            // ⚠️ 对不上就**什么都不做** —— 一条不是我发出去的回执不该改任何记录，
            //    那会让"发没发出去"变成猜的。
            if let ref, let row = UUID(uuidString: ref) {
                try? store?.persistence?.settleSent(id: row,
                                                    status: ok ? .sent : .failed,
                                                    note: ok ? nil : msg)
            }
            Log.event("feishu-send-result", ok ? "ok" : (msg ?? "failed"), id ?? "-")
        case .message(let inbound):
            lastEventAt = Date()
            ingest(inbound)
        }
    }

    /// 收一条消息。**这一层是 S15 的全部产品逻辑**，冒烟直接喂 `RemoteInbound` 测它。
    func ingest(_ inbound: RemoteInbound) {
        let duplicate = seenMessageIds.contains(inbound.messageId) && !inbound.messageId.isEmpty
        if !duplicate && !inbound.messageId.isEmpty {
            seenMessageIds.append(inbound.messageId)
            if seenMessageIds.count > seenLimit { seenMessageIds.removeFirst(seenMessageIds.count - seenLimit) }
        }
        // 先把"这条会话存在"记下来（**早于**路由判断）：这条记录是诊断用的 ——
        // 新增一个机器人之后，人要靠它确认"真的收到了"。
        if inbound.isDirectText || !inbound.text.isEmpty {
            noteChat(inbound)
        }
        let bot = bots.first { Self.uuid(inbound.botId) == $0.id }
        guard let store else { return }
        let task = bot?.assistantId.flatMap { aid in
            store.scheduler.scheduledTasks.first { $0.id == aid }
        }
        let sid = task?.logSessionId
        // "最近一条还开着的结论" = 人回「同意」时指的那一条（推送一次只有一条，见 `pushFinding`）。
        let pending = task.flatMap { t in
            store.findings
                .filter { $0.taskId == t.id && $0.status.isInboxVisible }
                .max { $0.createdAt < $1.createdAt }
        }
        let input = RemoteRouteInput(
            inbound: inbound,
            botKnown: bot != nil,
            boundTaskId: task?.id,
            taskIsAssistant: task?.isAssistant ?? false,
            taskEnabled: task?.enabled ?? false,
            sessionBusy: sid.map { store.runningTurns.contains($0) } ?? false,
            duplicate: duplicate,
            pendingFinding: pending?.id,
            pendingHasPlan: !(pending?.plan.isEmpty ?? true))
        switch RemoteRoute.decide(input) {
        case .ignore(let why):
            // ⚠️ `why` 里那四个字（`not-direct-text`）盖着四条判据（群聊 / 自回声 / 非文本 /
            // **正文取空**）—— 只留它等于归因不了。2026-11-18 真机就是这么卡住的：日志只说
            // "不是私聊文本"，而真相是桥那边把正文取成了空串。字段全带上，**不带正文**。
            Log.event("feishu-ignore", ["why": why,
                                        "bot": String((bot?.name ?? inbound.botId).prefix(12)),
                                        "chat_type": inbound.chatType,
                                        "msg_type": inbound.msgType,
                                        "sender": inbound.senderType,
                                        "len": String(inbound.text.count)])
        case .unbound:
            notice(inbound, L("这个机器人还没归给助理。在 MangoX 里把它绑给一个助理，就能直接说话了。"))
        case .paused:
            notice(inbound, L("这个助理现在是停用状态，先在 MangoX 里把它打开。"))
        case .busy:
            notice(inbound, L("上一个回合还在跑，等它结束再发。"))
        case .noPending:
            // 他要批，但手上没有等着批的事 —— 必须回一句：不回他会以为消息丢了。
            notice(inbound, L("现在没有等你批的事。直接说话就是跟我聊。"), force: true)
        case .noPlan:
            notice(inbound, L("这一条只是问你 / 告诉你，没有可执行的方案 —— 没有「同意」这个动作。回「先别动」可以把它搁置。"), force: true)
        case .approve(_, let findingId):
            approveOnFeishu(findingId, inbound: inbound)
        case .dismiss(_, let findingId):
            store.setFindingStatus(findingId, status: .dismissed)
            notice(inbound, L("已搁置（那条结论本身还在 App 里）。"), force: true)
        case .deliver(let taskId, let prompt):
            deliver(taskId: taskId, prompt: prompt,
                    chatId: inbound.chatId, botId: inbound.botId)
        }
    }

    private func deliver(taskId: UUID, prompt: String, chatId: String, botId: String) {
        guard let store, let task = store.scheduler.scheduledTasks.first(where: { $0.id == taskId })
        else { return }
        guard let sid = store.scheduler.ensureLogSession(for: task) else { return }
        // 建完**当场绑上**：`beginDialogueTurn` 靠 `logSessionId` 反查"这是哪个助理的会话"，
        // 不绑的话这一轮会被当成普通会话跑（没有目标、没有账本、没有只读面）。
        store.scheduler.bindLogSession(taskId: taskId, logId: sid)
        remoteTurns[sid] = (chatId, botId)
        // 记一笔"这个机器人最近被谁找过"（诊断）。
        if let bid = Self.uuid(botId) { store.touchRemoteBotChat(bid, chatId: chatId) }
        // 没跑起来就把这条记录收回去 —— 否则它挂在别人的回合上，那个回合一落定就会把
        // **别人**的回复发到这个单聊里。
        if !store.sendExternal(sid: sid, text: prompt) {
            remoteTurns.removeValue(forKey: sid)
        }
    }

    /// 回合落定的回调（`ChatStore` 两处收尾点调）。**只认领从飞书来的那一轮**。
    func finishRemoteTurn(sid: UUID) {
        guard let turn = remoteTurns.removeValue(forKey: sid) else { return }
        guard let store else { return }
        // ⚠️ spool **无条件**消费掉，哪怕这一轮什么正文都没有 —— 留着它，同一个会话的**下一轮**
        //    会把这个旧文件发出去，而那一轮人问的是别的事。这与 `drain` 的"读即删"同源:
        //    队列只认"这一轮"，没有"下次再试"。
        let queued = RemoteAttachments.drain(sid: sid)
        let text = store.lastAssistantText(sid: sid)
        guard !text.isEmpty else {
            // 一句话都没有（进程崩 / 被停）—— 沉默比"编一句失败"更让人困惑。
            if !queued.files.isEmpty {
                Log.event("feishu-attach-dropped", ["count": "\(queued.files.count)", "why": "empty-text"])
            }
            noticeChat(turn, L("这一轮没有产出（可能被中断了），回 MangoX 里看现场。"), force: true)
            return
        }
        let owner = sentOwner(sid)
        emit(.reply, taskId: owner, sessionId: sid, turn: turn, text: RemoteReply.compose(text))
        deliverAttachments(queued, turn: turn, taskId: owner, sessionId: sid)
    }

    /// S15c: 这一轮要不要挂「发附件」工具（工具名 `feishu_attach`）。
    ///
    /// ⚠️ 判据就是"这一轮是不是从飞书私聊来的" —— **复用这两张已经在用的表**，不新造一张
    ///    "谁允许发文件"的名单。多一张表就多一处会忘记清的入口，而"忘了清"这个错的方向
    ///    恰好是最坏的: 之后每一轮都能往外发文件。
    ///
    /// ⚠️ 已知空洞（有意留着，见 `approveOnFeishu`）: 从飞书**批准执行**的那一轮里
    ///    `execReplies` 是在回合已经开跑之后才写入的 ⇒ 那一轮拿不到这个工具。
    ///    影响只是"执行轮不能顺手发文件"，而"我要文件"这个场景走的是普通私聊（`deliver`）。
    func attachSpoolForTurn(sid: UUID) -> String? {
        guard remoteTurns[sid] != nil || execReplies[sid] != nil else { return nil }
        return RemoteAttachments.spoolPath(sid: sid)
    }

    // MARK: - 出口（唯一）· 已发消息记忆（2026-11-23）

    /// **所有往外发的话都从这里走** —— 它顺手把"模型说过什么"记进 `agent_sent`。
    ///
    /// 三条刻意的边界:
    ///  ① **只记模型说的话**。`notice*` 那一族（"上一个回合还在跑" / "已搁置" / "有文件没能
    ///     发出去"）继续直接调 `link?.send` —— 那是 **App 的话术**，记进来就会在注入段里
    ///     冒充"它自己说过的"。
    ///  ② **先落库、再交给桥**。反过来桥一崩就什么都不剩，而"我以为我说过、其实一个字都
    ///     没出去"正是这个功能要消灭的那件事。
    ///  ③ **回执靠 `ref` 落定**（`id` 就是 ref）：没有它只能知道"最近有一次发送失败了"。
    ///
    /// `taskId == nil`（普通会话 / 对不上任务）时**不记** —— 没归属的记录进不了任何一轮的
    /// 注入段，只会占库。
    private func emit(_ kind: SentKind, taskId: UUID?, sessionId: UUID?,
                      turn: (chatId: String, botId: String),
                      text: String, file: RemoteAttachment? = nil) {
        // 文件那条的正文是空的，记忆里存**文件名** —— "发过哪个文件"才答得出来。
        let body = text.isEmpty ? (file?.name ?? "") : text
        var ref: String?
        if let taskId, !body.isEmpty, let p = store?.persistence {
            let row = SentMessage(taskId: taskId, sessionId: sessionId, kind: kind, text: body)
            try? p.insertSent(row)
            try? p.pruneSent(taskId: taskId)
            ref = row.id.uuidString
        }
        link?.send(botId: turn.botId, chatId: turn.chatId, text: text, file: file, ref: ref)
    }

    /// 这一轮属于哪个助理任务（注入段与记录都按它归属）。**用 `owningTask` 而不是
    /// `logSessionId == sid` 那种自拼查找** —— 那条反查已经有一套回落（对话轮 / 巡检轮 /
    /// 执行轮都在里面），两处各写一遍迟早分叉。
    private func sentOwner(_ sid: UUID) -> UUID? {
        store?.scheduler.owningTask(for: sid)?.id
    }

    /// 把这一轮排队的附件发出去。**文本已经发完了才调这里**。
    ///
    /// ⚠️ 顺序是"文本 → 附件": 人先看到"给你，"，再看到文件。反过来的话文件先弹出、
    ///    说明后到，中间那几秒他不知道这是什么。
    /// ⚠️ 拒绝理由必须**说出来**（`force: true`）: 人刚说"把那个发我"，而助理一个字都不提
    ///    —— 他会以为消息丢了，然后再要一次，然后还是什么都没来。
    private func deliverAttachments(_ queued: (files: [RemoteAttachment], notes: [String]),
                                    turn: (chatId: String, botId: String),
                                    taskId: UUID?, sessionId: UUID?) {
        for file in queued.files {
            // 文件也算"发过的话"（`kind = .file`，正文那一列放文件名）—— 否则助理会忘了
            // 自己昨天已经把那份 pdf 发过去了，今天再发一遍。
            emit(.file, taskId: taskId, sessionId: sessionId, turn: turn, text: "", file: file)
        }
        guard !queued.notes.isEmpty else { return }
        noticeChat(turn, RemoteReply.compose(L("有文件没能发出去：") + "\n"
                                             + queued.notes.joined(separator: "\n")),
                   force: true)
        Log.event("feishu-attach-rejected", ["count": "\(queued.notes.count)",
                                             "note": queued.notes.first ?? ""])
    }

    /// 在飞书上批一条结论：起执行轮，并把结果回推到这个私聊（人不一定回 App 看时间线）。
    ///
    /// ⚠️ 这里**不判**"有没有方案 / 有没有待批的事" —— 那些是 `RemoteRoute.decide` 的活。
    /// 这一层只做一件事：把"人已经批了"落成执行。分成两层是为了让判据能单独对拍。
    private func approveOnFeishu(_ findingId: UUID, inbound: RemoteInbound) {
        guard let store else { return }
        if let why = store.startFindingExecution(findingId) {
            notice(inbound, String(format: L("没执行起来：%@"), why), force: true)
            return
        }
        let taskId = store.findings.first(where: { $0.id == findingId })?.taskId
        if let tid = taskId,
           let logId = store.scheduler.scheduledTasks.first(where: { $0.id == tid })?.logSessionId {
            execReplies[logId] = (inbound.chatId, inbound.botId)
        }
        notice(inbound, L("已采纳，开始执行（起手做快照，跑完能回滚）。结果我发这里。"), force: true)
    }

    /// 执行轮落定 → 把收尾那句话回推到**批准它的那个私聊**。
    ///
    /// 只在"这次执行是从飞书批的"时发（`execReplies` 里有这条会话才发）。没发出去也写日志 ——
    /// "没收到"与"没发"必须长得不一样。
    func reportExecFinished(sid: UUID, line: String) {
        guard let turn = execReplies.removeValue(forKey: sid) else { return }
        // 同 `finishRemoteTurn`: 队列无条件消费（执行轮拿不到工具，这里通常是空的 ——
        // 但"通常是"不能当判据，残留一份就是下一轮的旧文件）。
        let queued = RemoteAttachments.drain(sid: sid)
        let owner = sentOwner(sid)
        emit(.reply, taskId: owner, sessionId: sid, turn: turn, text: line)
        deliverAttachments(queued, turn: turn, taskId: owner, sessionId: sid)
    }

    /// 投递失败（引擎没起来 / 并发到顶）—— 回合**没开始**，但仍要回一句。
    ///
    /// 为什么不是"静默丢弃": 人那边看到的是"消息发出去了"，如果不回，他会以为助理在忙，
    /// 于是再发一条 —— 而真正的原因（引擎没起来）他永远不会知道。
    func reportDeliveryFailure(sid: UUID, _ why: String) {
        guard let turn = remoteTurns.removeValue(forKey: sid) else { return }
        noticeChat(turn, why, force: true)
    }

    /// **结论主动推给入口机器人** —— 这不是回话（这一轮不是飞书发起的）。
    ///
    /// 2026-11-17 boss 的口径：群不用了，飞书只走"跟助理绑定的那个机器人"。
    /// 于是触达里的**群 webhook 整条删掉**，结论改走这条私聊 —— 同一件事只留一条路。
    ///
    /// 三种"推不出去"各有各的话，不能笼统说一句"发送失败"：人要知道是**该配机器人**、
    /// **该把机器人打开**、还是**该先去飞书跟它说一句话**（没有 `chatId` 就没有落点）。
    ///
    /// ⚠️ 传进来的 `p` 必须是 `NotifyPayload`（**脱敏后的最小事实**）—— 外发正文只许一条
    /// 组装路径，多一条就多一次把 `finding.body` / `evidence` 拼进去的机会。
    func pushFinding(_ p: NotifyPayload, taskId: UUID) -> NotifyOutcome {
        guard let bot = bots.first(where: { $0.assistantId == taskId }) else {
            return .skipped(L("没绑机器人 —— 在助理的「入口 · 飞书」里选一个"))
        }
        // 机器人没有自己的开关（2026-11-18）：不推只有一个原因 —— 它归的那个助理关着。
        guard isLive(bot) else {
            return .skipped(L("助理是关着的 —— 打开它才会推"))
        }
        guard let chatId = bot.lastChatId, !chatId.isEmpty else {
            return .skipped(L("还没有人跟它说过话 —— 先在飞书里给它发一句，之后结论就推到这个私聊"))
        }
        guard botPhase[bot.id] == .up else {
            return .failed(L("通道没连上（设置 → 集成 → 飞书机器人 里能看灯）"))
        }
        emit(.push,
             taskId: taskId,
             sessionId: store?.scheduler.scheduledTasks.first { $0.id == taskId }?.logSessionId,
             turn: (chatId: chatId, botId: bot.id.uuidString),
             text: Self.pushText(p))
        return .sent(String(format: L("已推给「%@」的私聊"), bot.displayName))
    }

    /// `force` = 绕过 60 秒冷却。**审批的每一条回答都必须 force** ——
    /// 人回了一句「同意」却没收到任何回应，他会以为消息丢了，于是再发一遍（然后被当成聊天）。
    /// 推送正文 = 一行事实 + **怎么回**。
    ///
    /// 尾巴不是装饰：人不在电脑前，他收到这条之后唯一能做的就是**在飞书里回两个字**。
    /// 不告诉他回什么，这条推送就只是一条通知（2026-11-18 boss: 别让我回 App 去点）。
    static func pushText(_ p: NotifyPayload) -> String {
        let tail = p.actionable
            ? L("回「同意」我就按这份方案去做（起手做快照，跑完能回滚）；回「先别动」就搁置。")
            : L("这条是问你 / 告诉你，不用批。回「先别动」可以把它搁置。")
        return p.line + "\n\n" + tail
    }

    private func notice(_ inbound: RemoteInbound, _ text: String, force: Bool = false) {
        noticeChat((chatId: inbound.chatId, botId: inbound.botId), text, force: force)
    }

    private func noticeChat(_ turn: (chatId: String, botId: String), _ text: String, force: Bool = false) {
        if !force {
            let now = Date()
            if let last = lastNoticeAt[turn.chatId], now.timeIntervalSince(last) < noticeCooldown { return }
            lastNoticeAt[turn.chatId] = now
        }
        link?.send(botId: turn.botId, chatId: turn.chatId, text: text)
    }

    // MARK: - 来找过机器人的会话（诊断）

    private func noteChat(_ inbound: RemoteInbound) {
        if let i = pendingChats.firstIndex(where: { $0.chatId == inbound.chatId && $0.botId == inbound.botId }) {
            pendingChats[i].lastSeen = Date()
            pendingChats[i].lastText = String(inbound.text.prefix(40))
            if !inbound.openId.isEmpty { pendingChats[i].openId = inbound.openId }
        } else {
            pendingChats.append(RemoteChat(botId: inbound.botId,
                                           chatId: inbound.chatId,
                                           openId: inbound.openId,
                                           lastSeen: Date(),
                                           lastText: String(inbound.text.prefix(40))))
        }
        // 只留最近 10 条 —— 这是一张"刚跟我说过话的会话"表，不是通讯录。
        if pendingChats.count > 10 {
            pendingChats.sort { $0.lastSeen > $1.lastSeen }
            pendingChats = Array(pendingChats.prefix(10))
        }
        saveChats()
    }

    private func loadChats() {
        guard let data = FileManager.default.contents(atPath: chatsFile),
              let list = try? JSONDecoder().decode([RemoteChat].self, from: data) else { return }
        pendingChats = list
    }

    private func saveChats() {
        guard let data = try? JSONEncoder().encode(pendingChats) else { return }
        let dir = (chatsFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: chatsFile))
    }

    /// 解 `bot` 字段。`UUID(uuidString:)` 本身**大小写不敏感**（两种写法都收）——
    /// 写成这个薄壳只是为了让"这一帧属于哪个机器人"在代码里只有一处解释。
    private static func uuid(_ s: String) -> UUID? { UUID(uuidString: s) }
}
