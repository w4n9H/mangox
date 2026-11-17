//
//  RemoteChannelService.swift
//  P19.2 S15 —— 飞书通道的**状态机与投递**（a 桥 / b 消息落地 / c 回复回流 三个动作都在这里收口）。
//
//  ── 三条边界 ────────────────────────────────────────────────────────────────
//  ① **一个助理永远和一场会话绑定**（P19 既有约束，不是这里发明的）：
//     消息进来 → 找 `remoteChatId == chat_id` 的那个助理任务 → 投进**它的** `logSessionId`。
//     没有"通道会话"这种第二类会话，所以换通道不会换上下文。
//  ② **桥是哑的**：白名单、绑没绑、要不要回，全在这一层判。桥里只有协议。
//  ③ **只回"从飞书来的那一轮"**：`remoteTurns` 记住这一轮是谁发起的，收尾时认领。
//     否则你在电脑上随口问一句，飞书那边也会响一声 —— 那是把通道变成噪音源。
//
//  ── 明写在界面上的两个前提 ──────────────────────────────────────────────────
//  · **App 得开着**。桥是 App 的子进程，App 退了它就退（Dashboard 上写着这句话）。
//  · **要先在飞书里发一句话**，那个单聊才会出现在"可绑定"列表里 —— 飞书没有
//    "列出我的单聊" 的接口（`GET /im/v1/chats` 只返回机器人所在**群**，实测 0 条）。
//

import Foundation

@MainActor
final class RemoteChannelService: ObservableObject {

    /// 通道总开关（全局，一条）。放 UserDefaults: 它是"我要不要这个入口"，
    /// 与凭据（钥匙串）分开 —— 关掉通道**不该**等于删掉 app_secret。
    static let enabledKey = "remote.feishu.enabled"

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

    /// 收到过消息、但还没绑助理的单聊。绑定的**唯一入口**就是这张表 ——
    /// 见文件头"要先在飞书里发一句话"。
    struct RemoteChat: Codable, Equatable, Identifiable {
        let chatId: String
        var openId: String
        var lastSeen: Date
        var lastText: String

        var id: String { chatId }

        /// 界面上的短标识。飞书的 `oc_` / `ou_` 都是 30+ 位，全显示会把这一行撑爆，
        /// 而人要靠它区分"是不是同一个会话" ⇒ 取**尾部 6 位**（前缀是固定字母，没信息量）。
        var shortChat: String { "…" + chatId.suffix(6) }
        var shortSender: String { "…" + openId.suffix(6) }
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var lastNote: String?
    @Published private(set) var pendingChats: [RemoteChat] = []

    private weak var store: ChatStore?
    private let secrets: RemoteSecretStore
    private var link: RemoteLink?
    /// `sid -> chat_id`：这一轮是从哪个单聊发起的（收尾时认领，认领即删）。
    private var remoteTurns: [UUID: String] = [:]
    /// 去重窗口。飞书在客户端网络抖动时会重推**同一个 message_id**，
    /// 不去重就是"同一句话进去两次"，而人只会觉得助理重复回答了。
    private var seenMessageIds: [String] = []
    private let seenLimit = 200
    /// 系统回复（没绑/忙/停用）的冷却：同一个单聊 60 秒最多回一句。
    /// 不回不行（人以为发丢了），每句都回也不行（连发五条回来五句"还没绑"）。
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

    func attach(_ store: ChatStore) { self.store = store }

    /// 冒烟缝：直接换掉桥（生产不调 —— 生产只走 `start()` 建的 `FeishuBridgeLink`）。
    /// 有了它，"`ChatStore` 的收尾点真的会调 `finishRemoteTurn`" 这条**接线**才验得到；
    /// 否则只能验服务自己的逻辑，而接错线的表现是"回复永远不发"。
    func attachLink(_ l: RemoteLink) {
        link = l
        l.onFrame = { [weak self] in self?.handle($0) }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? start() : stop()
    }

    // MARK: - 起停

    /// 启动（幂等）。**缺凭据不是错误**：没配就是没配，界面显示"未启用"即可。
    func start() {
        guard isEnabled else { phase = .off; return }
        guard let appId = secrets.appId(), let secret = secrets.appSecret(),
              !appId.isEmpty, !secret.isEmpty else {
            phase = .failed(L("还没填 app_id / app_secret"))
            return
        }
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
            if case .failed = self.phase { return }
            self.phase = .failed(String(format: L("通道断了（%@），点「重连」"), why))
        }
        phase = .connecting
        do {
            try l.start(appId: appId, appSecret: secret)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 由 `ChatStore` 的启动序列调 —— 与 `start()` 的差别只在**冒烟里不自动起**。
    func autostart() {
        if Self.autostartDisabled && link == nil { phase = .off; return }
        start()
    }

    func stop() {
        link?.stop()
        phase = .off
        remoteTurns.removeAll()
    }

    /// 「重连」按钮：先停再起，并把凭据重新读一遍（人可能刚改过）。
    func restart() {
        stop()
        start()
    }

    // MARK: - 收

    private func handle(_ frame: RemoteFrame) {
        switch frame {
        case .status(let connected, let note):
            if connected { phase = .up }
            else if phase == .up { phase = .connecting }
            lastNote = note
        case .error(let msg):
            lastNote = msg
            Log.event("feishu-bridge-error", "msg", msg)
        case .sendResult(let ok, let id, let msg):
            if !ok { lastNote = msg ?? L("发消息失败") }
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
        // 先把"这个单聊存在"记下来（**早于**路由判断）：没绑的时候它也要出现在待绑定列表里，
        // 否则人会卡在"我要先绑定 → 列表里没有 → 我绑什么"。
        if inbound.isDirectText || !inbound.text.isEmpty {
            noteChat(inbound)
        }
        guard let store else { return }
        let task = store.scheduler.scheduledTasks.first { $0.remoteChatId == inbound.chatId }
        let sid = task?.logSessionId
        let input = RemoteRouteInput(
            inbound: inbound,
            boundTaskId: task?.id,
            taskIsAssistant: task?.isAssistant ?? false,
            taskEnabled: task?.enabled ?? false,
            sessionBusy: sid.map { store.runningTurns.contains($0) } ?? false,
            duplicate: duplicate)
        switch RemoteRoute.decide(input) {
        case .ignore(let why):
            Log.event("feishu-ignore", ["why": why, "chat": String(inbound.chatId.suffix(6))])
        case .unbound:
            notice(inbound.chatId, L("这个单聊还没绑定助理。在 MangoX 的助理设置里选上它，就能直接说话了。"))
        case .paused:
            notice(inbound.chatId, L("这个助理现在是停用状态，先在 MangoX 里把它打开。"))
        case .busy:
            notice(inbound.chatId, L("上一个回合还在跑，等它结束再发。"))
        case .deliver(let taskId, let prompt):
            deliver(taskId: taskId, prompt: prompt, chatId: inbound.chatId)
        }
    }

    private func deliver(taskId: UUID, prompt: String, chatId: String) {
        guard let store, let task = store.scheduler.scheduledTasks.first(where: { $0.id == taskId })
        else { return }
        guard let sid = store.scheduler.ensureLogSession(for: task) else { return }
        // 建完**当场绑上**：`beginDialogueTurn` 靠 `logSessionId` 反查"这是哪个助理的会话"，
        // 不绑的话这一轮会被当成普通会话跑（没有目标、没有账本、没有只读面）。
        store.scheduler.bindLogSession(taskId: taskId, logId: sid)
        remoteTurns[sid] = chatId
        // 没跑起来就把这条记录收回去 —— 否则它挂在别人的回合上，那个回合一落定就会把
        // **别人**的回复发到这个单聊里（见 `sendExternal` 里那条注释）。
        if !store.sendExternal(sid: sid, text: prompt) {
            remoteTurns.removeValue(forKey: sid)
        }
    }

    /// 回合落定的回调（`ChatStore` 两处收尾点调）。**只认领从飞书来的那一轮**。
    func finishRemoteTurn(sid: UUID) {
        guard let chatId = remoteTurns.removeValue(forKey: sid) else { return }
        guard let store else { return }
        let text = store.lastAssistantText(sid: sid)
        guard !text.isEmpty else {
            // 一句话都没有（进程崩 / 被停）—— 沉默比"编一句失败"更让人困惑。
            notice(chatId, L("这一轮没有产出（可能被中断了），回 MangoX 里看现场。"), force: true)
            return
        }
        link?.send(chatId: chatId, text: RemoteReply.compose(text))
    }

    /// 投递失败（引擎没起来 / 并发到顶）—— 回合**没开始**，但仍要回一句。
    ///
    /// 为什么不是"静默丢弃": 人那边看到的是"消息发出去了"，如果不回，他会以为助理在忙，
    /// 于是再发一条 —— 而真正的原因（引擎没起来）他永远不会知道。
    func reportDeliveryFailure(sid: UUID, _ why: String) {
        guard let chatId = remoteTurns.removeValue(forKey: sid) else { return }
        notice(chatId, why, force: true)
    }

    private func notice(_ chatId: String, _ text: String, force: Bool = false) {        if !force {
            let now = Date()
            if let last = lastNoticeAt[chatId], now.timeIntervalSince(last) < noticeCooldown { return }
            lastNoticeAt[chatId] = now
        }
        link?.send(chatId: chatId, text: text)
    }

    // MARK: - 待绑定的单聊

    private func noteChat(_ inbound: RemoteInbound) {
        if let i = pendingChats.firstIndex(where: { $0.chatId == inbound.chatId }) {
            pendingChats[i].lastSeen = Date()
            pendingChats[i].lastText = String(inbound.text.prefix(40))
            if !inbound.openId.isEmpty { pendingChats[i].openId = inbound.openId }
        } else {
            pendingChats.append(RemoteChat(chatId: inbound.chatId,
                                           openId: inbound.openId,
                                           lastSeen: Date(),
                                           lastText: String(inbound.text.prefix(40))))
        }
        // 只留最近 10 个 —— 这是一张"刚跟我说过话的单聊"表，不是通讯录。
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

    /// 解绑时把那个单聊从"最近"里抹掉？**不抹** —— 它还会继续收到消息（只是没绑），
    /// 抹掉反而让人找不到刚解绑的那个。
}
