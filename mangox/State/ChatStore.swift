//
//  ChatStore.swift
//  Centralized in-memory state driving the UI.
//  P3.0: Agent 生成/审批逻辑已下沉到 AgentTransport, 这里只做事件归并 + UI 状态。
//  P9.1a: 自 Mock/MockData.swift 物理迁移改名 (零代码改动)。
//

import Foundation
import SwiftUI
import AppKit
import Combine

/// P5.0.2: 主区底档 (TopBar 胶囊二选一)。
enum CapsuleMode: Hashable {
    case chat, trajectory
}

/// P6.3.2: 离开摘要横幅数据 (结算后的展示态; 纯内存, App 重启即弃 — 库里消息列表才是权威)。
struct AwaySummary: Equatable {
    let sid: UUID
    /// 离开期间完成的回合数。
    let turns: Int
    /// 最近一轮回复的首行前 60 字。
    let preview: String
}

@MainActor
final class ChatStore: ObservableObject {

    /// 会话默认标题 —— **这是存储哨兵, 不是文案**。
    ///
    /// ⚠️ 三个身份叠在一起，所以**不得 `L()` 它**：
    ///   ① 新会话落库的初始值（库里已有大量 `title = 'New chat'` 的行，改值 = 老会话全变"未命名"）；
    ///   ② `autoTitleIfNeeded` 的判据（`item.title == 这个值` 才自动命名）；
    ///   ③ 界面显示文本。
    /// ①② 要求它**不随界面语言变**，③ 要求它随语言变 ⇒ 只能拆开: 存储用本常量,
    /// 显示走 `ConversationItem.displayTitle`（那里把哨兵映射成 `L("新对话")`）。
    /// 值本身住在 `ConversationTitle.defaultValue`（nonisolated —— `displayTitle` 在非隔离上下文里读它）。
    static let defaultConversationTitle = ConversationTitle.defaultValue

    /// P4.0.2 Transport 池: sessionId -> 实例 (每会话一个; 内部仍 per-turn 进程, spawn 即跑完即退)。
    private var transports: [UUID: any AgentTransport] = [:]
    /// 能力探测专用实例 (get_state/get_available_models, 不承载回合; 冒烟注入时复用注入实例)。
    private var capabilityProbe: (any AgentTransport)?
    /// 冒烟/测试注入的单实例: 注入时全会话共用 (串行语义, 保持回归基线)。
    private let injectedTransport: (any AgentTransport)?
    /// spawn 期配置快照: 新实例创建时与每次 send 前下发 (P3.7 注入 / P3.11 扩展)。
    private var currentExtensionPaths: [String] = []
    /// P4.0.2 会话化流式状态: 在途回合的会话集合 (并发数 = 集合大小; 上限治理在 P4.0.4)。
    @Published private(set) var runningTurns: Set<UUID> = [] {
        didSet {
            // 锁屏运行 (2026-10-27): 只有真的有回合在途才按住"别睡"的断言。
            // ⚠️ 这里**每次变动都会调**(并发任务进出很频繁) ⇒ `SleepGuard.apply` 必须幂等。
            SleepGuard.shared.apply(mode: lockScreenMode, busy: !runningTurns.isEmpty)
        }
    }
    /// 兼容视图: 当前选中会话是否有回合在途。
    var isStreaming: Bool {
        selectedConversationId.map { runningTurns.contains($0) } ?? false
    }
    /// P8-T26: 审批阻塞会话集合 (会话级信号) —— awaitingApproval 事件置位,
    /// 审批响应 / streamEnded / 手动停止 / 会话删除清除。
    @Published private(set) var approvalBlocked: Set<UUID> = []
    // P9.1d: 备份域抽离至 BackupService, 同名 facade 转发 (冒烟/视图零改动)
    let backup = BackupService()
    var backupDirectory: String? {
        get { backup.backupDirectory }
        set { backup.backupDirectory = newValue }
    }
    var lastBackupSummary: String? {
        get { backup.lastBackupSummary }
        set { backup.lastBackupSummary = newValue }
    }
    var backupRunning: Bool { backup.backupRunning }
    var backupFailureMessage: String? {
        get { backup.backupFailureMessage }
        set { backup.backupFailureMessage = newValue }
    }
    /// P3.1: SQLite 持久化; 打不开时降级为纯内存 (原 mock 行为)。
    let persistence: PersistenceStore?   // P9.1b: internal — SchedulerService 定时域落库回调
    /// P7-M3: 模型 key 存储 (真源 Keychain; 冒烟注入内存实现)。
    let modelKeyStore: any ModelKeyStore

    // Chat
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    /// P7-M6b: 图片附件暂存区 (随 draft 生命周期, 发送即清; ≤4 张)。
    @Published var pendingImages: [PendingImage] = []
    /// 引擎不可用 (pi CLI 缺失): Release 下不静默降级, UI 横幅明示 + 发送守卫。
    @Published var engineMissing: Bool = false
    /// P12.1a: 引擎**装着的但起不来**的诊断 (启动即退 / 启动后沉默)。
    /// 常驻 (不自清): 这是不可自愈的状态, 8s 横幅会让用户错过; 引擎真正跑通一轮后清空。
    @Published var engineDiagnosis: String? = nil

    // Sidebar (Codex: projects 嵌套 + chats 平铺)
    @Published var projects: [ProjectGroup] = SampleSession.projects
    @Published var chats: [ConversationItem] = SampleSession.chats
    @Published var selectedConversationId: UUID? = SampleSession.initialSelectedId
    /// Composer 上方 "Choose project" 的当前选择 (nil = 未选项目)。
    @Published var selectedProjectId: UUID? = nil {
        didSet { syncWorkspaceContext() }   // 工作区上下文跟随显式选择的项目
    }
    /// Codex "Ask for approval": on = 工具调用走人工审批流 (per-session 实例各持策略, didSet 全池下发)。
    @Published var askApproval: Bool = true {
        didSet {
            injectedTransport?.updateApprovalPolicy(askApproval: askApproval)
            transports.values.forEach { $0.updateApprovalPolicy(askApproval: askApproval) }
            stampSessionConfig()   // P10.3: 写穿当前会话配置
        }
    }
    /// P7-M4 模式档位 (能力预设, 与审批开关正交; 按项目记忆, settings KV)。
    @Published var agentMode: AgentMode = .standard {
        didSet {
            guard oldValue != agentMode else { return }
            injectedTransport?.updateMode(agentMode)
            transports.values.forEach { $0.updateMode(agentMode) }
            saveAgentMode()
            stampSessionConfig()   // P10.3: 写穿当前会话配置
        }
    }

    // MARK: - P4.0.4 并发上限 (在途回合数口径; settings 持久化, 默认 10)

    /// 同时运行回合数上限; 超限 = 用户发送拒绝+横幅提示, fire 落痕跳过 (v1 不排队)。
    @Published var maxConcurrentTurns: Int = 10 {
        didSet {
            let clamped = min(max(maxConcurrentTurns, 1), 20)   // 与 SettingsView Stepper 同域
            if clamped != maxConcurrentTurns { maxConcurrentTurns = clamped; return }   // 触发 didSet 二次进入
            persistence?.saveSetting(key: "max_concurrent_turns", value: clamped)
        }
    }

    // MARK: - 锁屏运行 (2026-10-27: 有回合在途时别让机器睡过去)

    /// 三档: 不保持唤醒 / 熄屏后保持唤醒 / 保持屏幕常亮。
    ///
    /// ⚠️ 它是"上限"不是"开关"：真正持有断言的只有 `runningTurns` 非空那段时间
    /// （见 `SleepGuard` 与 `runningTurns.didSet`）。
    /// ⚠️ 落库存 `rawValue`（小写标识），不存显示文案 —— 改文案不能丢设置。
    @Published var lockScreenMode: LockScreenMode = .dimming {
        didSet {
            guard lockScreenMode != oldValue else { return }
            persistence?.saveSettingText(key: "lock_screen_mode", value: lockScreenMode.rawValue)
            // 正有任务在跑时改设置要**立刻**生效, 不能等下一个回合。
            SleepGuard.shared.apply(mode: lockScreenMode, busy: !runningTurns.isEmpty)
        }
    }
    /// 超限拒绝横幅 (Composer 上方, 8s 自清; 与提炼横幅同语言)。
    @Published var turnLimitNotice: (text: String, isError: Bool)?
    private var turnLimitNoticeTask: Task<Void, Never>?

    /// 主区切换: true = 设置面板 (侧栏 gear 入口)。
    @Published var showSettingsPanel: Bool = false

    /// 「请把设置页切到某一栏」—— 由**别处的入口**放进去, 设置页取走并清空。
    ///
    /// ⚠️ 存 `rawValue` 而不是 `SettingsCategory` 本身: 那是 View 层的枚举, State 层不去
    ///    依赖视图类型 (本仓 `LockScreenMode` 反过来也是出于同一个边界)。
    ///
    /// 来历 (2026-10-28 boss): computer use 的开关原来只在设置页最下面, 被说「藏的太深了」。
    /// 现在输入框那一行的 pill 才是主入口, 它点"选择能读的应用…"时要能**直接落到那一栏** ——
    /// 否则"打开设置"之后还要用户自己在左列找一次, 等于把深度换了个地方。
    @Published var pendingSettingsCategory: String?

    // MARK: - P4.1 回合完成通知 + P4.2 迷你条计时

    /// 通知开关 (settings 持久化, 默认开; 前台不弹 — 触发判定在 streamEnded 路径)。
    @Published var completionNotificationsEnabled: Bool = true {
        didSet {
            persistence?.saveSetting(key: "completion_notifications",
                                     value: completionNotificationsEnabled ? 1 : 0)
        }
    }
    /// 在途回合起点 (耗时显示/完成通知; beginTurn 记, 结束/停止/删除时清)。
    private var turnStartAt: [UUID: Date] = [:]

    /// P4.2: 主窗口 mini 工具台形态 (true = 主窗口缩为任务台; 窗口尺寸切换在 ContentView)。
    @Published var miniMode: Bool = false
    /// P4.2: 最后完成的回合 (mini 台完成闪显用; 前台记录, 手动停止不记, 5s 自清)。
    @Published private(set) var lastCompleted: (sid: UUID, title: String, duration: String)?
    private var lastCompletedTask: Task<Void, Never>?

    /// P5.0.2: 主区底档 (胶囊二选一)。与 workspaceVisible (Work 右列开关) 正交, 互不影响。
    @Published var capsuleMode: CapsuleMode = .chat


    func setTurnLimitNotice(_ text: String, isError: Bool = true) {
        turnLimitNotice = (text, isError)
        turnLimitNoticeTask?.cancel()
        turnLimitNoticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { turnLimitNotice = nil }
        }
    }

    // P6.0②: 扩展 fire-and-forget 通知横幅 (pi extension notify; 同 8s 自清模式)。
    @Published var extensionNotice: (text: String, isError: Bool)?
    private var extensionNoticeTask: Task<Void, Never>?

    func setExtensionNotice(_ text: String, isError: Bool) {
        extensionNotice = (text, isError)
        extensionNoticeTask?.cancel()
        extensionNoticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { extensionNotice = nil }
        }
    }

    /// 在途回合数是否已达上限。
    var atTurnLimit: Bool { runningTurns.count >= maxConcurrentTurns }

    // MARK: - Workspace (P3.4: 仅 project 会话可用)

    /// 当前生效的 project: 显式选择优先, 否则跟随选中会话的归属。
    var activeProject: ProjectGroup? {
        if let pid = selectedProjectId {
            return projects.first { $0.id == pid }
        }
        return projects.first { $0.items.contains { $0.id == selectedConversationId } }
    }

    /// 当前工作目录 (nil = 无项目会话, Work 不可用)。
    var activeProjectPath: String? { activeProject?.path }

    /// Work 胶囊可用性: 仅绑定了目录的 project 会话可用 (§3.4 拍板)。
    var canUseWorkspace: Bool { activeProjectPath != nil }

    /// 第三栏工作区: 默认隐藏, Chat/Work 段控件切换 (对齐 Codex)。
    ///
    /// ⚠️ `willSet` 那个回调**不是可选项**：开面板要把窗口按缺口补宽，而补宽必须发生在
    ///    SwiftUI 按新状态布局**之前** —— 挂在 `.onChange` 上就已经晚了一版，会先按旧窗口宽
    ///    排一次（正文整条重排 200~800ms），补宽后又排一次。见 `WorkspaceWindowFit` 文件头 ②。
    @Published var workspaceVisible: Bool = false {
        willSet {
            if newValue != workspaceVisible { willSetWorkspaceVisible?(newValue) }
        }
        didSet {
            // 无工作目录时强制回 Chat (切换到普通 chat 会话的场景)
            if workspaceVisible, !canUseWorkspace { workspaceVisible = false }
        }
    }

    /// 工作区开关的**前置**回调（窗口层用，视图层装）。非 `@Published`：它不该引起重渲染。
    var willSetWorkspaceVisible: (@MainActor (Bool) -> Void)?

    /// P14: 菜单命令 → 工作区视图的一次性信号。**序号自增 = 新的一次请求**;
    /// 视图只观察变化、不回写清零 (清零会让「连按两次 ⌘R」退化成一 次)。
    /// 存在的理由: git 状态 / 语言构成是视图侧 `@State`, 命令层够不到 ⇒ 把命令转成视图能观察的事件。
    @Published var workspaceRefreshTick = 0
    @Published var workspaceFilterFocusTick = 0
    /// 同上一种信号 —— 「跳到工作区的改动 tab」。轮末账单的小弹窗里有入口。
    /// 同样用**自增**而不是布尔: 连点两次要生效两次。
    @Published private(set) var workspaceChangesTick = 0

    /// 从轮末账单的口子进工作区改动 tab。
    /// 无工作目录时**什么都不做**（也不要 `workspaceVisible = true` —— 那会被 didSet 打回来,
    /// 但先置真再被打回来会闪一下半截布局）。
    func openWorkspaceChanges() {
        guard canUseWorkspace else { return }
        workspaceVisible = true
        workspaceChangesTick &+= 1
    }

    /// 每轮**实测耗时** — sessionId → 该轮**末条正文**的消息 id → 秒。
    ///
    /// ⚠️ 只活在内存里, **不落库**: 重启后重放出来的历史轮次没有这个数, 轮末账单里那一格
    ///    就整段不显示。这是**有意的取舍**, 不是遗漏 —— 落库要么加一张表, 要么把
    ///    "开始流式"的时间戳当成"结束"(见 `TurnBill.elapsed` 的注释: 那会算出一个
    ///    看起来合理的错数, 比没有更糟)。
    @Published private(set) var turnElapsed: [UUID: [UUID: TimeInterval]] = [:]

    func turnElapsed(sid: UUID, messageId: UUID) -> TimeInterval? {
        turnElapsed[sid]?[messageId]
    }

    /// 落定点记一笔耗时。挂载点是「该轮最后一条 assistant 正文」——判据与视图侧**同源**
    /// （`ChatView.projectedChat` 里挑账单宿主用的是同一条件），否则账会挂在一条看不见的行上。
    private func noteTurnElapsed(sid: UUID, projection: [ChatMessage], seconds: TimeInterval) {
        guard let host = projection.last(where: { m in
            guard m.role == .assistant, case .text = m.content else { return false }
            return true
        }) else { return }
        turnElapsed[sid, default: [:]][host.id] = seconds
    }

    /// 全部会话（跨 projects + chats）。
    var allConversations: [ConversationItem] {
        projects.flatMap(\.items) + chats
    }

    /// 顶栏标题: 当前会话名, 无选中则默认标题。
    /// ⚠️ 走 `displayTitle` 而不是 `title` —— 默认标题是**存储哨兵**(`New chat`),
    ///    直接显示会让中文模式下的顶栏一直挂着英文（2026-10-19）。
    var selectedTitle: String {
        allConversations.first { $0.id == selectedConversationId }?.displayTitle ?? L("新对话")
    }

    // Workspace (第三栏, 文件树): 真实目录扫描 (P3.4), 无项目时为空
    @Published var fileTree: [FileNode] = []

    // P6.1.1: 当前选中会话的状态栏统计 (上下文/Token/缓存)。
    // 归并源: usageTick (流式期) + didReportSessionStats (spawn 期/settled 前的 get_session_stats)。
    @Published var sessionStats: SessionStats?
    /// P6.1.2: 当前选中会话的回合过程态 (phaseChanged 归并; 仅前台会话生效)。
    @Published var runtimePhase: RuntimePhase = .idle
    /// P6.2.3: Trace HTML 导出——临时 transport + 超时兜底 + 在途开关。
    private var exportTransport: (any AgentTransport)?
    private var exportTimeout: Task<Void, Never>?
    @Published var isExportingHTML = false

    // P6.3.1: 侧问会话
    /// 当前选中会话的快照信息 (提示条数据源; selectConversation 刷新, 普通会话 nil)。
    @Published private(set) var activeSideChat: SideChatInfo?
    /// 在途回合的 fork 临时快照 (sid → 截断快照文件; 回读后清理磁盘)。
    private var pendingForkTemp: [UUID: String] = [:]

    // P6.3.2: 离开摘要 (Away summary)
    /// 当前选中会话的离开摘要 (悬浮胶囊; 点击/×/新回合清除)。
    @Published private(set) var awaySummary: AwaySummary?
    /// 不在场完成的回合积累器 (sid 分键, 天然隔离并发任务; 结算即摘除)。
    /// 冒烟直读断言, 故 internal。
    private(set) var pendingAway: [UUID: (turns: Int, preview: String)] = [:]

    /// P6.1.2: 状态栏"当前会话 N 轮" = 视图内 user 消息数。
    var currentTurnCount: Int { messages.filter { $0.role == .user }.count }

    // P9.1c: 模型域抽离至 ModelStore, 同名 facade 转发 (冒烟/视图零改动)
    let model = ModelStore()
    var availableModels: [AgentModelInfo] {
        get { model.availableModels }
        set { model.availableModels = newValue }
    }
    var managedModels: [ManagedModel] {
        get { model.managedModels }
        set { model.managedModels = newValue }
    }
    var currentProvider: String {
        get { model.currentProvider }
        set { model.currentProvider = newValue }
    }
    var currentModelId: String {
        get { model.currentModelId }
        set { model.currentModelId = newValue }
    }
    var thinkingLevel: ThinkingLevel {
        get { model.thinkingLevel }
        set { model.thinkingLevel = newValue }
    }
    var userThinkingLevelPinned: Bool {
        get { model.userThinkingLevelPinned }
        set { model.userThinkingLevelPinned = newValue }
    }
    var currentModelSupportsImages: Bool { model.currentModelSupportsImages }

    // P9.1c: 知识域抽离至 KnowledgeStore, 同名 facade 转发
    let knowledge = KnowledgeStore()
    var knowledgeItems: [KnowledgeItem] {
        get { knowledge.knowledgeItems }
        set { knowledge.knowledgeItems = newValue }
    }
    var showKnowledgePanel: Bool {
        get { knowledge.showKnowledgePanel }
        set { knowledge.showKnowledgePanel = newValue }
    }
    var distillRunning: Bool {
        get { knowledge.distillRunning }
        set { knowledge.distillRunning = newValue }
    }
    var distillOutcome: (text: String, isError: Bool)? {
        get { knowledge.distillOutcome }
        set { knowledge.distillOutcome = newValue }
    }
    /// 知识有改动但引擎尚未重启 (注入块仍旧, 需 Composer pill "重启引擎生效")。
    /// 留守 ChatStore: 与 extensionsDirty 同在 restartEngine 清零 (P9.1c)。
    @Published var knowledgeDirty: Bool = false

    private var bashWhitelist: Set<String> = []

    // P9.1b: 定时任务域抽离至 SchedulerService, 同名 facade 转发 (冒烟/视图零改动)
    let scheduler = SchedulerService()
    var scheduledTasks: [ScheduledTask] {
        get { scheduler.scheduledTasks }
        set { scheduler.scheduledTasks = newValue }
    }
    var showScheduledPanel: Bool {
        get { scheduler.showScheduledPanel }
        set { scheduler.showScheduledPanel = newValue }
    }
    /// 子 store 变更转发 (视图仍只订阅 ChatStore)
    private var schedulerCancellable: AnyCancellable?
    private var knowledgeCancellable: AnyCancellable?
    private var modelCancellable: AnyCancellable?
    private var captureCancellable: AnyCancellable?
    private var backupCancellable: AnyCancellable?
    private var mailboxCancellable: AnyCancellable?

    // MARK: - P10.2a 邮箱哨兵 (域逻辑在 MailboxSentinelService, 此处 facade 转发)

    let mailbox = MailboxSentinelService()
    var mailboxAccounts: [MailboxAccount] { mailbox.accounts }
    var mailboxSentinels: [MailboxSentinel] { mailbox.sentinels }
    var mailboxTasks: [MailboxTask] { mailbox.tasks }
    var mailboxNotice: String? { mailbox.mailboxNotice }
    /// 冒烟注入: 收件/发件实例工厂 (缺省 = 生产 `CurlMailTransport`, 见 P10.2c)
    var mailboxTransportFactory: ((MailboxAccount) -> (any MailTransport)?)? {
        get { mailbox.makeTransport }
        set { mailbox.makeTransport = newValue }
    }
    /// 冒烟注入: 凭据缝 (默认 Keychain)
    var mailboxCredentials: MailboxCredentialStore {
        get { mailbox.credentials }
        set { mailbox.credentials = newValue }
    }
    @discardableResult func upsertMailboxSentinel(_ s: MailboxSentinel) -> Bool { mailbox.upsertSentinel(s) }
    func addMailboxAccount(_ a: MailboxAccount) { mailbox.addAccount(a) }
    func updateMailboxAccount(_ a: MailboxAccount) { mailbox.updateAccount(a) }
    @discardableResult func removeMailboxAccount(_ id: UUID) -> Bool { mailbox.removeAccount(id) }
    func removeMailboxSentinel(id: UUID) { mailbox.removeSentinel(id: id) }
    func toggleMailboxSentinel(id: UUID) { mailbox.toggleSentinel(id: id) }
    func availableMailboxAccounts(forSentinel id: UUID?) -> [MailboxAccount] { mailbox.availableAccounts(forSentinel: id) }
    func pollMailboxOnce() async { await mailbox.pollOnce() }

    // P10.2d: Settings 面板读写的 facade (域逻辑在 service)
    var mailboxRejections: [MailboxRejection] { mailbox.allRecentRejections() }
    /// P10.2e: 单个 sparse agent 的拒收 (编辑器内嵌排查段用; 时间倒序)。
    func mailboxRejections(sentinelId: UUID) -> [MailboxRejection] { mailbox.recentRejections(sentinelId: sentinelId) }
    var mailboxQueuedTaskCount: Int { mailbox.queuedTaskCount }
    var mailboxRunningTask: MailboxTask? { mailbox.runningTask }
    var mailboxLastPollAt: Date? { mailbox.lastPollAt }
    func sentinelBoundToken(accountId: UUID) -> MailboxSentinel? { mailbox.sentinel(for: accountId) }
    func testMailboxConnection(accountId: UUID) async -> String? { await mailbox.testConnection(accountId: accountId) }
    func hasMailboxAccountAuth(accountId: UUID) -> Bool { mailbox.hasAccountAuth(accountId: accountId) }
    func setMailboxAccountAuth(_ v: String?, accountId: UUID) { mailbox.setAccountAuth(v, accountId: accountId) }
    func hasMailboxSentinelSecret(sentinelId: UUID) -> Bool { mailbox.hasSentinelSecret(sentinelId: sentinelId) }
    func setMailboxSentinelSecret(_ v: String?, sentinelId: UUID) { mailbox.setSentinelSecret(v, sentinelId: sentinelId) }
    func addMailboxWhitelist(sentinelId: UUID, address: String) { mailbox.addToWhitelist(sentinelId: sentinelId, address: address) }

    // MARK: - P3.11 扩展管理
    @Published var extensions: [ExtensionItem] = []
    @Published var showExtensionsPanel = false
    @Published var extensionsDirty = false   // 启停后未重启引擎
    private var disabledExtensionPaths: Set<String> = []
    /// smoke 注入: 托管扩展目录 (默认 ~/.mangox/extensions)
    private let managedExtensionsDir: String

    /// P10.1b: 博查 API Key 的 Keychain 账号名。与模型 key **共用同一个 store**
    /// （口径 = 服务名, 与"account = provider 名"那条约定同族）。
    /// 三处要用它（扫掠闸门 / 下发 transport / 设置页存取）⇒ 不许写死三次。
    static let bochaKeyAccount = "bocha"

    /// 当前配的博查 key（空串/缺失都算"没配"）。**唯一读数口** —— 面板闸门、下发 transport、
    /// 设置页回显全走它, 免得三处各写一次 `?? ""` 并各自漏掉空串那半边。
    var bochaKey: String? {
        let key = modelKeyStore.key(account: Self.bochaKeyAccount) ?? ""
        return key.isEmpty ? nil : key
    }

    /// P10.1b: 存/清博查 key 的**唯一写口**。`nil` 或空串 = 清除。
    ///
    /// ⚠️ 写完之后**必须**跑一次 `scanExtensions()` —— 这一个动作同时翻三样东西: 面板那一行的
    /// 挂不上胶囊、进入"可挂载"的启用列表、以及把 key 下发到各 transport。漏掉它, 设置页
    /// 会显示"已保存"而插件面板毫无变化（两条真源各说各话, **零红灯**）。
    func setBochaKey(_ key: String?) {
        let trimmed = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? modelKeyStore.deleteKey(account: Self.bochaKeyAccount)
        } else {
            try? modelKeyStore.setKey(trimmed, account: Self.bochaKeyAccount)
        }
        scanExtensions()
    }

    /// 扫描三区扩展并叠加启停状态 (spawn 带 --no-extensions, 自动发现区在 MangoX 内不生效)
    func scanExtensions() {
        let fm = FileManager.default
        var items: [ExtensionItem] = []
        let scanDir = { (dir: String) -> [String] in
            (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? []
        }
        // P10.1b: 博查 key 是自建搜索扩展的**挂载条件**, 每次重扫现读一次 ——
        // 用户在设置里存/清 key 之后, 就是靠这里把状态翻过来的。
        let searchKey = bochaKey
        // P10.1b: 搜索扩展**无条件落地** —— 与 approval 同判据（都是"我们自带的、不可删的"）。
        //
        // ⚠️ 早先写成"有 key 才落地"是错的, 两个理由:
        //   ① 没配 key 的**新用户**在插件面板里根本看不到这一项 ⇒ 找不到"去设置填 Key"这条线索
        //      （`BlockedReason.needsBochaKey` 那颗胶囊与它的 help 文案就成了够不着的死代码）。
        //   ② "有 key 才写"并不能防打地鼠 —— 恰恰相反: 它让文件在**有 key 时**每次重扫都被写回来,
        //      于是"删除"变成点一下又回来。真正的根因是"自动维护的文件不许删", 已在
        //      `ExtensionItem.builtInNames` 里解决（web-search 归自带 ⇒ 删除按钮根本不给）。
        _ = PiRpcTransport.ensureWebSearchExtensionFile(dir: managedExtensionsDir)
        // 没配 key ⇒ 挂不上（原因见 `ExtensionItem.BlockedReason.needsBochaKey`）。
        let searchBlocked: ExtensionItem.BlockedReason? = searchKey == nil ? .needsBochaKey : nil
        // 托管区
        for f in scanDir(managedExtensionsDir) where f.hasSuffix(".ts") || f.hasSuffix(".js") {
            // ⚠️ 判据是**文件名**, 不是"这个托管项注册了工具": 后者会把用户自己导入的第三方
            //    扩展一起卷进"缺 key 就不给开关"里 —— 别人家的扩展不归我们的 key 管。
            let blocked: ExtensionItem.BlockedReason? =
                (f == PiRpcTransport.webSearchExtensionFileName) ? searchBlocked : nil
            items.append(managedItem(name: (f as NSString).deletingPathExtension,
                                     path: managedExtensionsDir + "/" + f,
                                     blockedReason: blocked))
        }
        // P15.7: dream **投影**成一条 —— 它的 `.ts` 只在 dream 那次 fire 才落盘 (双闸门的第一道),
        // 平时磁盘上根本没有这个文件 ⇒ 纯扫描永远列不出它, 于是 `note_proposal` 在哪都没人找得到。
        //
        // ⚠️ **判重不能省**: dream 刚跑过时文件是真在磁盘上的, 上面那个循环已经收了一条,
        //    这里再加就是两条同名项 (一个能点开源码、一个不能 —— 用户只会当成坏了)。
        //    判据在冒烟: 磁盘上有真文件时**不许**重复, 没有时才补这一条。
        // ⚠️ 这是**全列表唯一**「面板有、`ls` 没有」的项, 详情源码走常量 (见 `extensionSource`)。
        if !items.contains(where: { $0.name == "mangox-dream" }) {
            var dream = managedItem(name: "mangox-dream",
                                    path: managedExtensionsDir + "/mangox-dream.ts")
            dream.isSynthetic = true
            items.append(dream)
        }
        // pi 全局自动发现区 (仅终端 pi 生效, 展示 + 可导入托管)
        let globalDir = NSHomeDirectory() + "/.pi/agent/extensions"
        for f in scanDir(globalDir) where f.hasSuffix(".ts") || f.hasSuffix(".js") {
            let path = globalDir + "/" + f
            items.append(ExtensionItem(name: (f as NSString).deletingPathExtension,
                                       path: path, source: .global, enabled: false, isBuiltIn: false))
        }
        // pi 项目自动发现区
        if let root = activeProjectPath {
            let projDir = root + "/.pi/extensions"
            for f in scanDir(projDir) where f.hasSuffix(".ts") || f.hasSuffix(".js") {
                let path = projDir + "/" + f
                items.append(ExtensionItem(name: (f as NSString).deletingPathExtension,
                                           path: path, source: .project, enabled: false, isBuiltIn: false))
            }
        }
        extensions = items
        // 下发 spawn 加载列表 (P4.0.2: 快照 + 池内已有实例同步刷新; 新实例由 transportFor 补发)
        let enabled = items.filter { $0.source == .managed && $0.enabled }.map(\.path)
        currentExtensionPaths = enabled
        // ⚠️ **注入实例（冒烟单实例）也必须收到** —— 它**不在 `transports` 池里**
        // （`transportFor` 对它 early-return）⇒ 只推 `transports.values` 的话,
        // 冒烟里 `MockTransport.lastDesiredExtensions` / `lastWebSearchKey` 永远是 nil,
        // "配置有没有真的推下去"那几条断言就变成**恒假绿**。
        // 同族: `askApproval` / `agentMode` 的 didSet 都推了注入实例, 这里早先漏了。
        injectedTransport?.updateExtensions(enabled)
        transports.values.forEach { $0.updateExtensions(enabled) }
        // P10.1b: key 与扩展列表**同源下发**。只推列表会让 transport 停在旧 key 上,
        // 而 key 是"下次 spawn 才生效"的参数 —— 它得先到 transport, 才谈得上生效。
        // 清 key 时下发 nil（`MockTransport` 会记下来, 冒烟据此断言"清掉不是留旧值"）。
        injectedTransport?.updateWebSearchKey(searchKey)
        transports.values.forEach { $0.updateWebSearchKey(searchKey) }
    }

    /// 构造一条**托管**扩展项 —— 磁盘扫描与 dream 投影走**同一个入口** (P15.7)。
    ///
    /// ⚠️ 为什么必须共用: 「内置的挂载策略与工具名」只能有**一处**赋值。分头写的话, dream 刚跑过
    /// （磁盘上真有那个 `.ts`）会走扫描分支 ⇒ 面板里那一项**从"按需胶囊"变回"恒开开关"**,
    /// 同一个东西两种说法 —— 而且换脸前后**都是绿的**, 冒烟抓不到。
    private func managedItem(name: String, path: String,
                             blockedReason: ExtensionItem.BlockedReason? = nil) -> ExtensionItem {
        let builtIn = ExtensionItem.builtInNames.contains(name)
        // "不给开关"是**另一个**集合（见 `unswitchableNames`）—— web-search 归自带（不可删）
        // 但**可停用** ⇒ 它必须尊重用户的静音选择。
        let noSwitch = ExtensionItem.unswitchableNames.contains(name)
        // ⚠️ 条件不满足时**必须压成 false**: 否则面板会显示"这一项开着"而它其实挂不上 ——
        //    开关比事实说得多（同 P15.6b「在说谎」那条, 只是方向反过来）。
        let on = blockedReason == nil && (noSwitch || !disabledExtensionPaths.contains(path))
        return ExtensionItem(name: name, path: path, source: .managed,
                             enabled: on,
                             isBuiltIn: builtIn,
                             toolNames: ExtensionItem.builtInToolNames[name] ?? [],
                             isSynthetic: false,
                             isOnDemand: ExtensionItem.builtInOnDemand.contains(name),
                             blockedReason: blockedReason)
    }

    /// 启停托管扩展 (生效需重启引擎)
    ///
    /// ⚠️ 守卫用 `unswitchableNames`（**不给开关**）而**不是** `isBuiltIn`（**不可删除**）——
    /// 后者会把 web-search 一起挡住, 而它本来就该能静音（那两个名字分家见 `ExtensionItem`）。
    func toggleExtension(_ item: ExtensionItem) {
        guard item.source == .managed,
              !ExtensionItem.unswitchableNames.contains(item.name) else { return }
        if item.enabled {
            disabledExtensionPaths.insert(item.path)
        } else {
            disabledExtensionPaths.remove(item.path)
        }
        persistence?.saveDisabledExtensions(disabledExtensionPaths)
        extensionsDirty = true
        scanExtensions()
    }

    /// 导入文件/目录到托管区 (拷贝, 默认停用)
    func importExtension(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: managedExtensionsDir, withIntermediateDirectories: true)
        let dest = managedExtensionsDir + "/" + url.lastPathComponent
        try? fm.removeItem(atPath: dest)
        try? fm.copyItem(at: url, to: URL(fileURLWithPath: dest))
        disabledExtensionPaths.insert(dest)
        persistence?.saveDisabledExtensions(disabledExtensionPaths)
        scanExtensions()
    }

    /// 删除托管扩展 —— **内置（MangoX 自带）除外**。
    ///
    /// ⚠️ 守卫是 `isBuiltIn`（= 名字在 `builtInNames` 里, 意思是**不可删除**）: 自带的那几个
    /// 每次重扫 / spawn 都会被重新写回磁盘, 允许删就只是"点一下又回来"。**这与"能不能停用"是两件事**
    /// —— web-search 不可删、但可停用（见 `toggleExtension`）。
    func deleteExtension(_ item: ExtensionItem) {
        guard item.source == .managed, !item.isBuiltIn else { return }
        try? FileManager.default.removeItem(atPath: item.path)
        disabledExtensionPaths.remove(item.path)
        persistence?.saveDisabledExtensions(disabledExtensionPaths)
        extensionsDirty = true
        scanExtensions()
    }

    /// 读取扩展源码 (详情预览)
    func extensionSource(_ item: ExtensionItem) -> String {
        // P15.7: 投影项在磁盘上没有文件 —— 源码从常量取。**不是图省事**: 去读文件只会拿到
        // "无法读取源码", 而面板要显示的正是那份**真会被写出去**的字节 (同一个真源)。
        if item.isSynthetic { return PiRpcTransport.dreamExtensionSource }
        return (try? String(contentsOfFile: item.path, encoding: .utf8)) ?? L("// 无法读取源码")
    }

    func toggleExtensionsPanel() {
        showExtensionsPanel.toggle()
        // 与另外两个 toggle 同一形态 (先 toggle 再在"打开"分支清场) —— 三条对称,
        // 后来者照抄任一条都不会漏掉第三个 flag。
        if showExtensionsPanel {
            showKnowledgePanel = false
            showScheduledPanel = false
            scanExtensions()
        }
    }

    /// 侧栏面板互斥不变量: 主区三块面板 (知识 / 定时 / 插件) **至多一个**为真。
    /// ⚠️ **不含 `showSettingsPanel`** —— P14 起设置是独立窗口, 本来就能与任一主区面板并存。
    /// 由冒烟守卫 (P14): 任何 toggle 之后都必须成立。
    var panelsExclusive: Bool {
        [showKnowledgePanel, showScheduledPanel, showExtensionsPanel].filter { $0 }.count <= 1
    }

    // Layout
    @Published var sidebarCollapsed: Bool = false

    init(transport: (any AgentTransport)? = nil, dbPath: String? = nil,
         managedExtensionsDir: String? = nil, modelKeyStore: (any ModelKeyStore)? = nil) {
        // 默认参数表达式是非隔离上下文, transport 的创建放进来。
        // P3.2: 检测到 pi 二进制 → 真引擎; 缺失时 Release 下不再静默降级 Mock
        // (假数据演戏是发布事故), 置 engineMissing 由 UI 报错; DEBUG 保留 mock 回归基线。
        // P4.0.2: 单实例 → 池。注入实例仅供冒烟/测试 (全会话共用, 串行回归基线);
        // 常规路径只建能力探测实例, 会话实例在首次 send 时按需拉起。
        let probe = transport ?? Self.makeTransport()
        capabilityProbe = probe
        engineMissing = probe is PiRpcTransport && !PiRpcTransport.available()
        // 无默认值的 let 需最先初始化 (两阶段: 赋值前不可访问 self)
        self.injectedTransport = transport
        self.managedExtensionsDir = managedExtensionsDir ?? (NSHomeDirectory() + "/.mangox/extensions")
        // ⚠️ 走 `current`（不是直接 `KeychainModelKeyStore()`）: 冒烟进程靠它整体换成内存实现 ——
        //    否则 `init` 尾部那次 `scanExtensions()` 会去读用户**真实**钥匙串（条目存在时弹窗 +
        //    `SecItemCopyMatching` 一直等答复 ⇒ 冒烟挂死）。见 `KeychainModelKeyStore.current`。
        self.modelKeyStore = modelKeyStore ?? KeychainModelKeyStore.current

        // P3.1: 首启播种 SampleSession, 之后全部从 SQLite 加载; 打不开库则回退纯 mock
        // dbPath: smoke 注入独立库文件用 (默认 ~/.mangox/mangox.db)
        let store = dbPath.flatMap { try? PersistenceStore(path: $0) } ?? (try? PersistenceStore())
        persistence = store
        if let store {
            try? store.migrate()
            if !store.isSeeded() {
                try? store.seed(projects: SampleSession.projects,
                                chats: SampleSession.chats,
                                initialSessionId: UUID(),
                                messages: [])   // mock 演示数据已移除, 首启即空库
            }
            projects = (try? store.loadProjects()) ?? []
            chats = (try? store.loadChats()) ?? []
            knowledgeItems = (try? store.loadKnowledge()) ?? []
            // P11.4: 知识库挂载记录 (用户挂的那批)。固定根(两个笔记根)不落库、由笔记目录现算。
            knowledge.knowledgeBases = (try? store.loadKnowledgeBases()) ?? []
            scheduledTasks = (try? store.loadScheduled()) ?? []
            // P7-M3: custom_models 一次性迁入 models 表 (幂等), 再加载自管真源
            // (P5.1 的自定义模型内存层已于 2026-09-23 删除; 表保留以兼容旧版本库)
            _ = (try? store.migrateLegacyCustomModels()) ?? 0
            managedModels = (try? store.loadManagedModels()) ?? []
            // P10.3v2: 启动恢复 — 先载 App 默认 KV; 选中会话存过配置用自己的,
            // 否则回落 App 默认 (独立于会话, 不吃别的会话的劫持); 首次运行退 last_session_config。
            appDefaultConfig = store.loadAppDefaultConfig()
            if let last = store.loadLastSession(),
               allConversations.contains(where: { $0.id == last }) {
                selectedConversationId = last
                messages = replayMessages(for: last)
                if let cfg = store.loadSessionConfig(id: last) {
                    applySessionConfig(cfg)
                } else if let def = appDefaultConfig {
                    applySessionConfig(def)
                } else if let lastCfg = store.loadLastSessionConfig() {
                    applySessionConfig(lastCfg)
                }
            } else if let def = appDefaultConfig {
                // 无选中会话也恢复默认期望 (重启后新建会话免重选)
                applySessionConfig(def)
            } else if let lastCfg = store.loadLastSessionConfig() {
                applySessionConfig(lastCfg)
            } else {
                selectedConversationId = nil
                messages = []
            }
        } else {
            messages = []   // 库不可用降级: 空态 (mock 演示数据已移除)
        }

        // delegate 挂接必须在全部存储属性初始化之后 (两阶段初始化)
        probe.delegate = self
        if let store {
            bashWhitelist = store.loadBashWhitelist()   // P3.10: 学习白名单恢复
            disabledExtensionPaths = store.loadDisabledExtensions()   // P3.11: 扩展启停恢复
            maxConcurrentTurns = store.loadSetting(key: "max_concurrent_turns", defaultValue: 10)   // P4.0.4
            completionNotificationsEnabled =
                store.loadSetting(key: "completion_notifications", defaultValue: 1) == 1   // P4.1
            backupDirectory = store.loadSettingText(key: "backup_dir")   // P8-T28
            lastBackupSummary = store.loadSettingText(key: "backup_last")
            lockScreenMode = LockScreenMode.resolve(store.loadSettingText(key: "lock_screen_mode"))   // 锁屏运行
            // P18: computer use 的开关与作用域 —— 与其它设置同一张表(能被备份一起带走)。
            // ⚠️ 落盘口子在这里接: 单例自己不持有 persistence, 冒烟里它是 nil ⇒ 只测纯函数。
            ComputerSettings.shared.restore(
                enabledRaw: store.loadSettingText(key: ComputerSettings.enabledKey),
                bundlesRaw: store.loadSettingText(key: ComputerSettings.bundlesKey))
            ComputerSettings.shared.onPersist = { [weak self] key, value in
                self?.persistence?.saveSettingText(key: key, value: value)
            }
            capture.restore(CaptureHotkey.load(persistence: store))   // P8-T27 (P9.1d: 状态随 CaptureService)
        }
        // P9.1b/c/d: 子 store 挂接 + objectWillChange 转发 (两阶段初始化完成后才可引用 self)
        scheduler.attach(self)
        knowledge.attach(self)
        model.attach(self)
        capture.attach(self)
        backup.attach(self)
        mailbox.attach(self)   // P10.2a: 载入账号/哨兵/线程 + 起 tick
        schedulerCancellable = scheduler.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        knowledgeCancellable = knowledge.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        modelCancellable = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        captureCancellable = capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        backupCancellable = backup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        mailboxCancellable = mailbox.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // P15.3: 预置那条 dream 任务 (**默认关**)。放在 attach 之后是因为它要读 `scheduledTasks`
        // (上一行 492 已经载完) 与 settings KV; 摆在 attach 外面是**刻意的** ——
        // `attach` 是纯接线, 种数据不该藏在接线里（同"一件事只有一个地方做"那条）。
        scheduler.seedDreamTaskIfNeeded()
        knowledge.reloadProposals()   // P15.3: 提案列表的首屏数据 (收口处会再刷)
        scanExtensions()   // P3.11: 扫描 + 快照托管扩展列表 (池实例 spawn 期加载)
        syncWorkspaceContext()   // 文件树扫描 (P3.4); cwd 在每次 send 前按实例下发
        // P3.7: 注入块快照 (池实例 spawn 期消费)
        knowledge.refreshSnapshot()
        // P7-M3: 物化产物先于探测拉目录 — probe 首次 spawn 带上 PI_CODING_AGENT_DIR,
        // get_available_models 只报自管模型 (顺序反了会先拉到全量目录)
        refreshPIConfig()
        probe.refreshCapabilities()   // P3.5: 模型/effort 上报 (pi 拉起 + get_state/models)
        scheduler.startScheduler()   // P3.6: 每秒 tick, 分钟对齐检查到期任务

        // WAL 落盘 + 杀在途 pi: 强杀/exit 不跑 deinit, 数据滞留 -wal 会在下次清库时全丢;
        // 在途回合的 pi 若不终止会变孤儿进程继续烧 LLM token
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPersistence()
                self?.capabilityProbe?.shutdown()
                self?.transports.values.forEach { $0.shutdown() }
                self?.scheduler.stopScheduler()   // P17: 停 tick + 交还防 App Nap 的断言
            }
        }
        // P6.3.2: 回到前台 → 结算选中会话的离开摘要 (切走期间落定的回合)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleAwaySummary() }
        }
    }

    /// SQLite WAL → 主文件落盘 (供退出钩子与冒烟测试调用)。
    func flushPersistence() {
        persistence?.checkpoint()
    }

    // MARK: - P8-T28 手动备份 (P9.1d 起逻辑在 BackupService, 此处仅转发)

    /// 记忆备份目录 (Settings 选择时调用)。
    func setBackupDirectory(_ path: String) {
        backup.setBackupDirectory(path)
    }

    /// 手动备份同步版 (冒烟 T28 直测; UI 走 performManualBackupInBackground)。
    @discardableResult
    func performManualBackup(destRoot: String, now: Date = .now) -> BackupOutcome {
        backup.performManualBackup(destRoot: destRoot, now: now)
    }

    /// P9-#11: UI 入口 — checkpoint 后在后台线程拷贝, 大附件库不再冻结主线程。
    func performManualBackupInBackground(destRoot: String, now: Date = .now) {
        backup.performManualBackupInBackground(destRoot: destRoot, now: now)
    }

    /// 冒烟: 持久层直访 (persistence 私有; T18 需直写 session_file 行模拟"有记忆")。
    var persistenceDebug: PersistenceStore? { persistence }

    /// 记录"上一次作业会话" (启动恢复用)。选中会话变化的所有入口都要调。
    private func markLastSession() {
        if let sid = selectedConversationId {
            try? persistence?.saveLastSession(id: sid)
        }
    }

    // MARK: - P8-T27 快速捕获 (P9.1d 起逻辑在 CaptureService, 此处仅转发)

    /// P8-T27: 捕获目标 —— 新会话(归项目) 或 追加到既有会话。
    typealias CaptureTarget = CaptureService.CaptureTarget

    let capture = CaptureService()
    var captureHotkey: CaptureHotkey { capture.captureHotkey }

    /// P8-T27: 改键 (Settings 录制后调用; 重注册由 Settings 层调 Controller)。
    func setCaptureHotkey(_ hk: CaptureHotkey) {
        capture.setCaptureHotkey(hk)
    }

    /// P8-T27: 上次捕获目标 (pill 记忆; KV 文本)。
    var captureMemo: String? { capture.captureMemo }

    func setCaptureMemo(_ raw: String?) {
        capture.setCaptureMemo(raw)
    }

    /// 捕获条发送: 即发即跑 (无人值守关审批)。
    /// 返回目标会话 id; nil = 拒绝 (空文本/引擎缺失/并发满/目标无效, 原因走横幅)。
    @discardableResult
    func submitCapture(text: String, target: CaptureTarget) -> UUID? {
        capture.submitCapture(text: text, target: target)
    }

    // MARK: - Sidebar interactions

    /// Codex 式新建会话：插入 Chats 平铺区顶部并选中, 消息清空。
    func newConversation() {
        let item = ConversationItem(title: Self.defaultConversationTitle)
        chats.insert(item, at: 0)
        selectedConversationId = item.id
        messages = []
        showKnowledgePanel = false   // 从面板发起新会话 → 回会话视图
        showScheduledPanel = false
        showExtensionsPanel = false
        try? persistence?.insertChatSession(item)
        markLastSession()
        stampSessionConfig()   // P10.3: 新会话落生即快照当前配置 (重启恢复有据)
        syncWorkspaceContext()   // 新 chat 无项目 → 工作区清空, Work 回 Chat
    }

    /// 重命名会话（保留 id, 刷新 updatedAt）。
    ///
    /// ⚠️ **落库那一行必须排在两个内存分支之后** —— 2026-10-19 修的一处长期缺陷:
    /// 项目分支原来是 `return` 出函数, 把下面的 `renameSession` 一起跳过了 ⇒
    /// **项目下的会话从来没落过标题**（重启回读仍是 `New chat`, 再发一条消息又"自动命名"一次,
    /// 标题于是每次都跟着最新那条消息漂）。平铺 `chats` 分支没有 `return`, 所以缺陷只在项目区出现;
    /// 而 T20 的断言只看 `store.chats` ⇒ 全程绿灯。现在两个分支都只**改内存**, 落库统一在出口。
    func renameConversation(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let pidx = projects.firstIndex(where: { $0.items.contains { $0.id == id } }),
           let iidx = projects[pidx].items.firstIndex(where: { $0.id == id }) {
            let old = projects[pidx].items[iidx]
            projects[pidx].items[iidx] = ConversationItem(
                id: old.id, title: trimmed,
                updatedAt: .now,
                unreadCount: old.unreadCount,
                sideOf: old.sideOf)   // P6.3.1: 侧问标记保留 (重建构造防丢)
        }
        if let idx = chats.firstIndex(where: { $0.id == id }) {
            let old = chats[idx]
            chats[idx] = ConversationItem(id: old.id, title: trimmed,
                                          updatedAt: .now,
                                          unreadCount: old.unreadCount,
                                          sideOf: old.sideOf)
        }
        try? persistence?.renameSession(id: id, title: trimmed, updatedAt: .now)
    }

    /// 会话在磁盘上留了什么 —— **先探后删**的前一半。
    ///
    /// ⚠️ **必须在删库行之前调**: 侧问的 transcript 路径存在 `sessions.session_file`、
    /// "有没有附件"要从 `events` 解出来 —— 行一删这两样都读不到了。
    private struct SessionDiskFootprint {
        let explicitTranscript: String?
        let hasAttachments: Bool
    }

    private func diskFootprint(of id: UUID) -> SessionDiskFootprint {
        SessionDiskFootprint(
            explicitTranscript: persistence?.loadSessionFile(id: id),
            hasAttachments: (((try? persistence?.loadMessages(sessionId: id)) ?? [])
                .flatMap { $0.attachments ?? [] }.isEmpty) == false)
    }

    /// 后一半: 真去 unlink。**半径只有这一处定义**（删会话 / 删项目共用 —— 同一个动作不该有两种半径）。
    ///
    /// - **图片附件恒删**（2026-10-13 boss 拍板）: 消息行一没它就是孤儿, 谁也引用不到。
    ///   刻意**不给它开关**: 二次确认里那句"保留 AI 记忆文件"说的是 transcript, 不是附件。
    /// - **transcript 按 `deleteTranscript`**: 它是 agent 的对话记忆, 误删不可恢复 ⇒
    ///   留给用户在二次确认里选（P15.8b 之后仍然如此）。
    private func removeSessionFiles(_ id: UUID, _ fp: SessionDiskFootprint, deleteTranscript: Bool) {
        if deleteTranscript {
            if let explicit = fp.explicitTranscript {
                PiRpcTransport.removeSessionFile(atPath: explicit)   // fork 产物 (文件名不可派生)
            } else {
                PiRpcTransport.removeSessionFile(for: id)            // pi 持久 transcript (派生路径)
            }
        }
        if fp.hasAttachments {
            ImagePipeline.removeSessionAttachments(sessionID: id)
        }
    }

    /// 删除会话；删的是当前会话则顺延选中第一个, 全空则回到空态。
    /// deleteTranscript = 连带删除 pi 持久 transcript (<uuid>.jsonl)。
    /// 默认保留: 文件是 agent 的对话记忆, 误删不可恢复 (UI 二次确认里让用户选)。
    func deleteConversation(_ id: UUID, deleteTranscript: Bool = false) {
        evictTransport(id)   // P4.0.2: 逐出池实例 (终止在途 pi + 清回合状态), 无论是否当前选中
        let fp = diskFootprint(of: id)                  // ① 先探 (必须在删行前)
        try? persistence?.deleteSession(id: id)         // ② 删行 (连带清 events)
        removeSessionFiles(id, fp, deleteTranscript: deleteTranscript)   // ③ 再删文件
        for g in projects.indices {
            projects[g].items.removeAll { $0.id == id }
        }
        chats.removeAll { $0.id == id }
        if selectedConversationId == id {
            if let first = allConversations.first {
                selectedConversationId = first.id
                messages = replayMessages(for: first.id)
                markLastSession()
            } else {
                selectedConversationId = nil
                messages = []
            }
            syncWorkspaceContext()   // 选中会话变化 → 工作区上下文跟随
        }
    }

    /// 从 SQLite 重放事件流; 库不可用时降级空态 (mock 演示数据已移除)。
    func replayMessages(for id: UUID) -> [ChatMessage] {   // P9.1b: internal — SchedulerService 交接文件重建
        guard let persistence else { return [] }
        return (try? persistence.loadMessages(sessionId: id)) ?? []
    }

    // MARK: - P10.5: 先切再渲染 (切换零阻塞)

    /// 重放代数: 每次冷切递增, 后台 decode 落地时校验防串台 (X→Y→X 快速反弹丢弃过期结果)。
    private var replayGen = 0

    /// P10.5: 先切再渲染 — 缓存命中同步上屏 (亚毫秒); 未命中先空态 + 在途镜像上屏,
    /// 全量重放挪后台 (只读连接 SELECT + 纯函数投影), 落地校验选中未变再替换。
    private func loadMessagesForSwitch(_ id: UUID) {
        guard let p = persistence else {
            messages = []
            return
        }
        if p.isReplayCached(id) {
            messages = replayMessages(for: id)
            mergeInflightIfRunning(id)
            return
        }
        messages = []
        mergeInflightIfRunning(id)   // 在途产出先上屏, 不等后台 decode
        replayGen += 1
        let gen = replayGen
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = p.replayMessagesInBackground(sessionId: id)
            await MainActor.run { [weak self] in
                guard let self, self.selectedConversationId == id, gen == self.replayGen else { return }
                // 落地合并: decoded 之后追加 decode 期间新增的 (用户新发/在途流式, 整体保留在尾部)
                let known = Set(decoded.map(\.id))
                let extras = self.messages.filter { !known.contains($0.id) }
                self.messages = decoded + extras
                self.mergeInflightIfRunning(id)
            }
        }
    }

    /// 会话回合在途 → 合并实时镜像 (库快照 + 在途产出), 切回不缺半截;
    /// 已落库的 finalized 块 replay 已含 → 按 id 去重。
    private func mergeInflightIfRunning(_ id: UUID) {
        guard runningTurns.contains(id), let live = liveTurns[id] else { return }
        let known = Set(messages.map(\.id))
        messages.append(contentsOf: live.filter { !known.contains($0.id) })
        liveTurns[id] = nil   // 后续事件直接进 messages (已选中)
    }

    /// P10.5: 流式宿主判定 (视图或镜像中存在该消息) —— 通行则丢弃迟到 chunk。
    private func hasStreamingHost(_ id: UUID, sid: UUID) -> Bool {
        if messages.contains(where: { $0.id == id }) { return true }
        return (liveTurns[sid] ?? []).contains { $0.id == id }
    }

    // MARK: - Workspace (P3.4: 文件树扫描 + 项目目录管理)

    /// 重扫文件树 (cwd 在每次 send 前按会话实例下发, P4.0.2 池化)。
    /// P10.5: 根目录未变即跳过 — 消除每次切会话的重复文件系统扫描。
    private var lastSyncedWorkspaceRoot: String?
    private var syncedNilWorkspaceRoot = false
    private func syncWorkspaceContext() {
        let root = activeProjectPath
        if let root {
            guard root != lastSyncedWorkspaceRoot else { return }
            lastSyncedWorkspaceRoot = root
        } else {
            guard !syncedNilWorkspaceRoot else { return }
            syncedNilWorkspaceRoot = true
        }
        if let root {
            fileTree = WorkspaceScanner.scanShallow(root: root)   // lazy: 只扫一层, 展开时按需加载
        } else {
            fileTree = []
        }
        // P3.11: 项目区扩展跟随 cwd, 目录变了重扫 (托管/全局区结果不变, 幂等)
        scanExtensions()
        // P7-M4: 档位按项目记忆, 切项目即恢复该项目档位 (默认 standard)
        restoreAgentMode()
    }

    // MARK: - P7-M4 模式档位持久化 (settings KV, 存 AgentMode.rawValue)
    // ⚠️ P13 之前这里存的是 `allCases` **序号** —— "位置即存储键"。加 codemode 时若沿用,
    //    老库里的 0/1/2 会整体改义 (老用户的 full 静默变 standard, 零红灯)。
    //    现改存 rawValue; 老库的序号值由 `AgentMode.init(storageValue:)` 按**冻结的旧顺序表**反解,
    //    所以不需要一次性数据迁移 (读时反解, 写回时自动变成新形态)。

    /// ⚠️ internal (不是 private): 冒烟要按**真实 key** 往 KV 里种老形态的序号值来验迁移 ——
    ///    在判据里手拼一遍 `"agent_mode.\(pid.uuidString)"` 会让判据**自证** (拼错照样绿)。
    var agentModeKey: String {
        if let pid = selectedProjectId { return "agent_mode.\(pid.uuidString)" }
        return "agent_mode"
    }

    private func saveAgentMode() {
        persistence?.saveSettingText(key: agentModeKey, value: agentMode.storageValue)
    }

    func restoreAgentMode() {
        suppressConfigStamp = true   // P10.3: 项目级档位恢复是程序性写值, 不写穿会话快照
        defer { suppressConfigStamp = false }
        let raw = persistence?.loadSettingText(key: agentModeKey)
            ?? AgentMode.standard.storageValue
        agentMode = AgentMode(storageValue: raw)
    }

    // MARK: - P10.3 会话级配置 (sessions.config 快照 + 跟随选中恢复)

    /// 程序性写值期间抑制 stamp (恢复/应用路径的 didSet 不回写, 防快照被启动默认值污染)。
    private var suppressConfigStamp = false
    /// P10.3v2: App 默认配置 (probe 上报的 pi settings 默认, 独立于任何会话)。
    /// NULL 会话 (无自己的 config 行) 选中时显示它, 不跟随被会话 apply 污染的可变全局。
    private(set) var appDefaultConfig: SessionConfig?

    /// probe 上报 pi settings 默认 → 捕获/刷新 App 默认配置 (每次启动覆盖, 跟踪 pi 默认);
    /// 当前选中会话若无自己的配置, 立即把显示切到默认 (防启动回落值滞留)。
    func captureAppDefault(provider: String, modelId: String, thinkingLevel: String) {
        guard !provider.isEmpty, !modelId.isEmpty else { return }
        let cfg = SessionConfig(provider: provider, modelId: modelId,
                                thinkingLevel: thinkingLevel,
                                agentMode: agentMode.rawValue, askApproval: askApproval)
        appDefaultConfig = cfg
        persistence?.saveAppDefaultConfig(cfg)
        backfillNullSessionConfigs(with: cfg)
        if let sid = selectedConversationId, persistence?.loadSessionConfig(id: sid) == nil {
            applySessionConfig(cfg)   // suppress 在 apply 内, 不写行
        }
    }

    /// 历史会话一次性回填: 无 config 行的统一落 App 默认 (用户拍板: 未正式使用, 模型取默认即可)。
    /// 幂等 — 已有配置的行不动; 回填后改动隔离语义对所有会话生效。
    private func backfillNullSessionConfigs(with cfg: SessionConfig) {
        for item in chats where persistence?.loadSessionConfig(id: item.id) == nil {
            persistence?.saveSessionConfig(id: item.id, config: cfg)
        }
    }

    /// 配置快照写穿: 写当前选中会话行 + last_session_config。调用点 = 用户动作入口
    /// (selectModel / askApproval didSet / agentMode didSet / newConversation 落生)。
    /// 被动浏览 (selectConversation) 永不写行 — 防 NULL 会话被当前全局固化。
    func stampSessionConfig() {
        guard !suppressConfigStamp else { return }
        guard let target = selectedConversationId else { return }
        guard !currentProvider.isEmpty else { return }   // 探测未回填前无有效快照可记
        let cfg = SessionConfig(provider: currentProvider, modelId: currentModelId,
                                thinkingLevel: userThinkingLevelPinned ? thinkingLevel.rawValue : nil,
                                agentMode: agentMode.rawValue, askApproval: askApproval)
        persistence?.saveSessionConfig(id: target, config: cfg)
        persistence?.saveLastSessionConfig(cfg)
    }

    /// 会话配置应用到全局期望。didSet 副作用会同步 transport 池 (v1 全池收敛语义, 与手动拨开关一致);
    /// 模型已不在菜单 (自管删除) → 保留当前模型, 仅恢复其余项。
    func applySessionConfig(_ cfg: SessionConfig) {
        // P10.5: 等值短路 — 同配置会话间切换零 @Published 写/零 didSet/零落库 (渲染减负)
        let sameLevel = cfg.thinkingLevel == nil || cfg.thinkingLevel == thinkingLevel.rawValue
        if currentProvider == cfg.provider, currentModelId == cfg.modelId,
           sameLevel, agentMode.rawValue == cfg.agentMode, askApproval == cfg.askApproval {
            return
        }
        suppressConfigStamp = true
        defer { suppressConfigStamp = false }
        let known = isKnownModel(provider: cfg.provider, modelId: cfg.modelId)
        if known {
            currentProvider = cfg.provider
            currentModelId = cfg.modelId
        }
        if let raw = cfg.thinkingLevel, let level = ThinkingLevel(rawValue: raw) {
            thinkingLevel = level
            userThinkingLevelPinned = true   // 会话存过级别 = 用户钉死, 探测上报不再回写
        }
        if let mode = AgentMode(rawValue: cfg.agentMode) { agentMode = mode }
        askApproval = cfg.askApproval
        // 已存在的实例补推模型期望 (新实例 spawn 经 transportFor 快照, 不主动拉起进程)
        if let sid = selectedConversationId, let t = transports[sid] {
            if known, !currentProvider.isEmpty {
                t.setModel(provider: currentProvider, modelId: currentModelId)
            }
            if let raw = cfg.thinkingLevel { t.setThinkingLevel(raw) }
        }
    }

    /// 工作区列刷新入口 (手动刷新按钮与菜单 ⌘R 共用): 重扫顶层 + **每个已加载过的目录**,
    /// 再与旧树按「同级 + 同名 + 同类型」合并 (不动 cwd 绑定与扩展)。
    ///
    /// ⚠️ **不许整体替换**: `FileNode.id` 是现生成的 `UUID()` (WorkspaceModels.swift:12),
    /// 一棵新树 = 一组新视图身份 ⇒ 用户展开的目录会被收起来。合并把旧节点的 id 与展开态搬过来。
    func refreshFileTree() {
        guard let root = activeProjectPath else { return }
        fileTree = Self.mergeRescan(root: root, old: fileTree)
    }

    /// 菜单 ⌘R: 重扫文件树 + 给工作区视图发一次「重载 git / 语言统计」的信号。
    func refreshWorkspace() {
        refreshFileTree()
        workspaceRefreshTick &+= 1
    }

    /// 菜单 ⌘F: 把焦点送进工作区的文件过滤框。
    /// 口径: MangoX **没有全局搜索** (全仓无 search 实现) ⇒ 对齐 macOS「在当前视图里查找」的惯例,
    /// 不假装是"搜索整个 App"。
    func focusWorkspaceFilter() {
        guard canUseWorkspace else { return }
        workspaceVisible = true
        workspaceFilterFocusTick &+= 1
    }

    /// 重扫并与旧树合并 (递归到所有已加载过的目录)。
    static func mergeRescan(root: String, old: [FileNode]) -> [FileNode] {
        mergeLevel(fresh: WorkspaceScanner.scanShallow(root: root), old: old, relPath: "", root: root)
    }

    /// 逐层合并。匹配键 = **同级 + 同名 + 同类型** —— `isFolder` 也进判据,
    /// 否则同名的目录与文件会互相顶替 (拿到错的身份 = 展开态张冠李戴)。
    private static func mergeLevel(fresh: [FileNode], old: [FileNode],
                                   relPath: String, root: String) -> [FileNode] {
        fresh.map { node in
            guard let match = old.first(where: { $0.name == node.name && $0.isFolder == node.isFolder })
            else { return node }   // 新增节点: 用新身份, 与谁都不冲突
            let childRel = relPath.isEmpty ? node.name : "\(relPath)/\(node.name)"
            var children = node.children
            var loaded = node.childrenLoaded
            if node.isFolder, match.childrenLoaded {
                let dir = URL(fileURLWithPath: root).appendingPathComponent(childRel).path
                children = mergeLevel(fresh: WorkspaceScanner.scanDirectory(dir, depth: node.depth + 1),
                                      old: match.children, relPath: childRel, root: root)
                loaded = true
            }
            return FileNode(id: match.id, name: node.name, isFolder: node.isFolder, depth: node.depth,
                            isExpanded: match.isExpanded, childrenLoaded: loaded, children: children)
        }
    }

    /// lazy 展开: 后台扫描目标目录一层, 回主线程原位插入树 (保留节点 id, 展开态不跳)。
    func loadDirectory(relPath: String) {
        guard let root = activeProjectPath else { return }
        let dir = root + "/" + relPath
        let childDepth = relPath.components(separatedBy: "/").count
        Task.detached {
            let kids = WorkspaceScanner.scanDirectory(dir, depth: childDepth)
            await MainActor.run {
                self.fileTree = Self.inserting(kids, at: relPath, into: self.fileTree)
            }
        }
    }

    /// 按 relPath 定位目录节点, 原位替换 children (保留原 id → ForEach 身份稳定)。
    private static func inserting(_ children: [FileNode], at relPath: String, into nodes: [FileNode]) -> [FileNode] {
        var comps = relPath.components(separatedBy: "/")
        return insertHelper(nodes, &comps, children)
    }

    private static func insertHelper(_ nodes: [FileNode], _ comps: inout [String], _ children: [FileNode]) -> [FileNode] {
        guard let target = comps.first else { return nodes }
        var out: [FileNode] = []
        for node in nodes {
            var n = node
            if n.isFolder && n.name == target {
                if comps.count == 1 {
                    n = FileNode(id: n.id, name: n.name, isFolder: true, depth: n.depth,
                                 isExpanded: true, childrenLoaded: true, children: children)
                } else {
                    comps.removeFirst()
                    n = FileNode(id: n.id, name: n.name, isFolder: true, depth: n.depth,
                                 isExpanded: true, childrenLoaded: n.childrenLoaded,
                                 children: insertHelper(n.children, &comps, children))
                }
            }
            out.append(n)
        }
        return out
    }

    /// 新建 project 并绑定工作目录 (composer "新建项目" 入口)。
    /// Codex 流程: 项目与会话共生——建项目立即在其下开一个新会话并选中。
    func addProject(title: String, path: String) {
        let group = ProjectGroup(title: title, path: path, items: [])
        projects.append(group)
        try? persistence?.insertProject(group, position: Int64(projects.count))
        selectedProjectId = group.id          // 触发工作区扫描 + cwd 绑定
        createSession(in: group.id)
    }

    /// 在指定项目下新建会话并选中 (项目行 "..." 菜单 / 新建项目共用)。
    func createSession(in projectId: UUID) {
        guard projects.contains(where: { $0.id == projectId }) else { return }
        let item = ConversationItem(title: Self.defaultConversationTitle)
        if let g = projects.firstIndex(where: { $0.id == projectId }) {
            projects[g].items.insert(item, at: 0)
        }
        try? persistence?.insertChatSession(item, projectId: projectId)
        selectedProjectId = projectId
        selectedConversationId = item.id
        messages = []
        showKnowledgePanel = false
        showExtensionsPanel = false
        showScheduledPanel = false
        markLastSession()
        syncWorkspaceContext()
    }

    /// 删除项目 (侧栏 "..." → 二次确认后调用): 连带其下所有会话与消息。
    ///
    /// **半径与删会话一致**（2026-10-13 boss: "删项目, 要连带项目下的所有会话都要删除, 所以 db, 或者文件, 也要删除"）:
    /// 行恒删 · 附件恒删 · transcript 按 `deleteTranscript`（由二次确认的两个按钮决定）。
    /// 走的是与 `deleteConversation` **同一对** `diskFootprint` / `removeSessionFiles`,
    /// 而不是在这里再抄一遍清理 —— 抄一遍就又有两个半径, 而"两种半径"正是这次要修的缺陷本身。
    ///
    /// ⚠️ 刻意**不逐会话调 `deleteConversation`**: 那个函数每删一个会话就重选一次,
    /// 一个 10 会话的项目会让侧栏选中项跳 10 次。这里逐会话只清内存态与文件,
    /// 选中项在末尾**统一**处理一次（与改动前同一语义）。
    func deleteProject(_ id: UUID, deleteTranscript: Bool = false) {
        guard let g = projects.firstIndex(where: { $0.id == id }) else { return }
        let removed = projects.remove(at: g)
        // ① 先探全部会话 (必须在删行前; 逐会话读一次库, 项目删除是低频动作, N 小)
        let footprints = removed.items.map { ($0.id, diskFootprint(of: $0.id)) }
        // ② 逐出实例 + 删行 (persistence.deleteProject 连带清其下 sessions / events)
        removed.items.forEach { evictTransport($0.id) }   // P4.0.2: 其下会话实例全部逐出
        try? persistence?.deleteProject(id: id)
        // ③ 再删文件
        for (sid, fp) in footprints {
            removeSessionFiles(sid, fp, deleteTranscript: deleteTranscript)
        }
        if selectedProjectId == id { selectedProjectId = nil }
        // 当前会话在被删项目下 → 回欢迎空态
        if let sid = selectedConversationId,
           removed.items.contains(where: { $0.id == sid }) {
            selectedConversationId = nil
            messages = []
        }
        syncWorkspaceContext()
    }

    /// 为已有 project 设置/更换工作目录 (pill "设置目录" 入口)。
    func setProjectPath(_ id: UUID, to path: String) {
        guard let g = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[g].path = path
        try? persistence?.updateProjectPath(id: id, path: path)
        syncWorkspaceContext()
    }

    /// 工作区文件树扁平化（@ 引用候选）。
    func flattenedFiles() -> [(id: UUID, name: String, path: String)] {
        var out: [(UUID, String, String)] = []
        func walk(_ nodes: [FileNode], prefix: String) {
            for node in nodes {
                let path = prefix.isEmpty ? node.name : "\(prefix)/\(node.name)"
                if node.isFolder {
                    walk(node.children, prefix: path)
                } else {
                    out.append((node.id, node.name, path))
                }
            }
        }
        walk(fileTree, prefix: "")
        return out.map { (id: $0.0, name: $0.1, path: $0.2) }
    }

    // MARK: - P4.0.2 Transport 池 (每会话一个实例; 实例内部仍 per-turn 进程)

    /// 在途回合的实时投影镜像 (sid -> 消息块): 后台会话的事件先进镜像,
    /// 用户切回时 replay(库) + 镜像合并上屏; 回合结束即弃 (库为准)。
    private var liveTurns: [UUID: [ChatMessage]] = [:]
    /// 冒烟注入实例的当前回合归属 (注入单实例共用, 无法按实例路由 → send 时定格)。
    private var injectedTurnSid: UUID?

    /// 取会话实例 (get-or-create): 新实例补发全套 spawn 期配置快照
    /// (审批策略/白名单/扩展/注入块/模型期望)。
    func transportFor(_ sid: UUID) -> any AgentTransport {   // P9.1c: internal — ModelStore.selectModel 回调
        if let injectedTransport { return injectedTransport }   // 冒烟: 全会话共用单实例 (串行基线)
        if let t = transports[sid] { return t }
        let t = Self.makeTransport()
        t.delegate = self
        t.updateApprovalPolicy(askApproval: askApproval)
        t.updateBashWhitelist(bashWhitelist)
        t.updateExtensions(currentExtensionPaths)
        t.updateKnowledgeContext(knowledge.currentKnowledgeBlock)
        t.updateMode(agentMode)   // P7-M4: 档位快照 (新实例补发)
        t.updatePIConfig(model.currentPIConfig)   // P7-M3: 物化产物快照 (缺失 = 会话 spawn 读 ~/.pi/agent → 全量目录泄漏)
        t.updateWebSearchKey(bochaKey)            // P10.1b: 搜索 key 快照 (env 只在 spawn 期定格)
        if !currentProvider.isEmpty {
            t.setModel(provider: currentProvider, modelId: currentModelId)
            t.setThinkingLevel(thinkingLevel.rawValue)
        }
        transports[sid] = t
        return t
    }

    /// 逐出池实例 (会话删除): 终止在途 pi + 清理该会话全部回合状态。
    private func evictTransport(_ sid: UUID) {
        transports[sid]?.shutdown()
        transports[sid] = nil
        runningTurns.remove(sid)
        liveTurns[sid] = nil
        scheduler.clearFireTracking(sid: sid)   // P9.1b: 在途 fire 追踪随会话逐出清理
        mailbox.noteSessionEvicted(sid: sid)    // P10.2a: 绑定该会话的远程线程失去落点 → 判失败
        turnStartAt[sid] = nil
        approvalBlocked.remove(sid)   // P8-T26: 会话删除即清
    }

    /// P9.1c: 物化产物全池下发 (ModelStore.refreshPIConfig 回调)。
    func pushPIConfig(_ output: ModelMaterializer.Output?) {
        injectedTransport?.updatePIConfig(output)
        capabilityProbe?.updatePIConfig(output)
        transports.values.forEach { $0.updatePIConfig(output) }
    }

    /// P9.1c: 注入块全池下发 (KnowledgeStore.applyKnowledgeChange 回调)。
    func pushKnowledgeContext(_ block: String?) {
        transports.values.forEach { $0.updateKnowledgeContext(block) }
    }

    #if DEBUG
    private static func makeTransport() -> any AgentTransport {
        PiRpcTransport.available() ? PiRpcTransport() : MockTransport()
    }
    #else
    private static func makeTransport() -> any AgentTransport { PiRpcTransport() }
    #endif

    func selectConversation(_ id: UUID?) {
        let previous = selectedConversationId
        selectedConversationId = id
        showKnowledgePanel = false   // 点选会话 → 回会话视图
        showScheduledPanel = false
        showExtensionsPanel = false
        // P4.0.2: 切走在途回合会话 → 未落库的流式块/非终态工具卡搬进镜像, 后续事件续投镜像
        if let previous, runningTurns.contains(previous) {
            let inflight = messages.filter { msg in
                if msg.isStreaming { return true }
                if case .tool(let t) = msg.content {
                    switch t.phase {
                    case .done, .error: return false
                    default: return true   // queued/running/awaitingApproval 均未落库
                    }
                }
                return false
            }
            if !inflight.isEmpty {
                var live = liveTurns[previous] ?? []
                for m in inflight where !live.contains(where: { $0.id == m.id }) {
                    live.append(m)
                }
                liveTurns[previous] = live
            }
        }
        guard let id else {
            activeSideChat = nil   // P6.3.1: 空选中清提示条
            awaySummary = nil      // P6.3.2: 空选中清离开摘要
            return
        }
        loadMessagesForSwitch(id)
        markLastSession()
        syncWorkspaceContext()   // 选中会话变化 → 工作区上下文跟随 (P3.4)
        // P6.1.2: 过程态跟随选中会话 (在途 = streaming 粗粒度; 精细相位仅前台会话事件归并)
        runtimePhase = runningTurns.contains(id) ? .streaming : .idle
        refreshSideChatBanner(for: id)
        settleAwaySummary()   // P6.3.2: 切入会话即结算其离开积累 (无则清显示)
        // P10.3v2: 会话配置跟随选中 — 存过 = 应用自己的; 没存过 = 应用 App 默认
        // (不跟随可变全局, 不写行; 被动浏览零写入)
        if let cfg = persistence?.loadSessionConfig(id: id) {
            applySessionConfig(cfg)
        } else if let def = appDefaultConfig {
            applySessionConfig(def)
        }
    }

    // MARK: - Side chat (P6.3.1 侧问会话)

    /// 提示条数据刷新 (选中会话变化时调用; 普通会话/空选中清 nil)。
    private func refreshSideChatBanner(for id: UUID?) {
        guard let id, let info = persistence?.sideChatInfo(id: id) else {
            activeSideChat = nil
            return
        }
        let parentTitle = allConversations.first { $0.id == info.sideOf }?.displayTitle ?? L("已删除的会话")
        activeSideChat = SideChatInfo(parent: info.sideOf, parentTitle: parentTitle,
                                      turns: info.turns, at: info.at)
    }

    /// 侧问入口可用性 (按会话): 非侧问自身 (不嵌套 fork) 且有持久 transcript。
    func canStartSideChat(for sid: UUID) -> Bool {
        guard let item = allConversations.first(where: { $0.id == sid }),
              item.sideOf == nil else { return false }
        return hasSessionFile(for: sid)
    }

    /// 侧问入口可用性 (当前选中会话; 顶栏按钮置灰判定)。
    var canStartSideChat: Bool {
        selectedConversationId.map { canStartSideChat(for: $0) } ?? false
    }

    /// 会话是否有 pi 持久 transcript (显式绑定优先, 否则查派生路径文件)。
    func hasSessionFile(for sid: UUID) -> Bool {
        if let f = persistence?.loadSessionFile(id: sid), !f.isEmpty { return true }
        return FileManager.default.fileExists(atPath: PiRpcTransport.sessionFilePath(for: sid))
    }

    /// 侧问选点的候选（P6.3.3）—— **点了菜单才查**，侧栏悬停/展开不碰它。
    ///
    /// 走 `replayMessages` 而不是库里的聚合: 这一屏要的是**每一轮的首句**（人靠它认哪一轮），
    /// 而首句只存在于消息内容里。代价可接受: 一次点击读一场会话, 与"每次悬停都读"是两件事
    /// （P15.9 的 `由此 Dream` 当初就是栽在后者上）。
    func sideChatTurns(for sid: UUID) -> [SideChatTurn] {
        SideChatTurns.build(from: replayMessages(for: sid))
    }

    /// 派生绑定动作 (beginTurn 下发 + 冒烟断言): 侧问首回合 fork → 后续回合显式文件 → 普通派生。
    enum SideChatBinding: Equatable {
        case fork(sourceFile: String)
        case explicitFile(path: String)
        case derived
    }

    /// 会话绑定决策 (纯逻辑, 冒烟直测): session_file 已回读 = fork 已完成, 后续走显式文件。
    func sideChatBinding(for sid: UUID) -> SideChatBinding {
        guard let info = persistence?.sideChatInfo(id: sid) else { return .derived }
        if let f = persistence?.loadSessionFile(id: sid), !f.isEmpty {
            return .explicitFile(path: f)
        }
        return .fork(sourceFile: info.sourceFile)
    }

    /// 发起侧问: 快照 fork 源会话 (turns = nil 整文件最新态; 指定 = 截断到该轮)。
    /// 新会话进入侧栏 (与源同容器), 首回合 send 时才真正 spawn --fork (per-turn 惯例)。
    func startSideChat(from sourceId: UUID, upTo turns: Int? = nil) {
        guard let item = allConversations.first(where: { $0.id == sourceId }),
              item.sideOf == nil else {
            setTurnLimitNotice(L("无法侧问：源会话无效或已是侧问会话"))
            return
        }
        guard !runningTurns.contains(sourceId) else {
            setTurnLimitNotice(L("源会话回合进行中，结束后再发起侧问"))
            return
        }
        guard let sourceFile = sideChatSourceFile(for: sourceId) else {
            setTurnLimitNotice(L("无法侧问：该会话没有持久记忆文件 (如临时任务会话)"))
            return
        }
        // 截断快照 (轮级入口); 整文件入口直接用源文件, 零拷贝
        var tempSnapshot: String?
        let forkSource: String
        if let turns {
            guard let snap = Self.prepareForkSnapshot(sourcePath: sourceFile, turns: turns) else {
                setTurnLimitNotice(L("侧问快照创建失败：无法读取源会话记忆文件"))
                return
            }
            tempSnapshot = snap
            forkSource = snap
        } else {
            forkSource = sourceFile
        }
        // fork 时源会话的轮数 (提示条 "含 N 轮源会话上下文")
        let sourceTurns = turns ?? replayMessages(for: sourceId).filter { $0.role == .user }.count
        // 新会话进源会话所在容器 (project 组 or Chats 平铺区)
        let side = ConversationItem(title: String(format: L("侧问 · %@"), item.title), sideOf: sourceId)
        var inProject: UUID?
        if let g = projects.firstIndex(where: { $0.items.contains(where: { $0.id == sourceId }) }) {
            projects[g].items.insert(side, at: 0)
            inProject = projects[g].id
        } else {
            chats.insert(side, at: 0)
        }
        try? persistence?.insertChatSession(side, projectId: inProject)
        try? persistence?.markSideChat(id: side.id, sideOf: sourceId,
                                       sourceFile: forkSource, turns: sourceTurns, at: .now)
        if let tempSnapshot { pendingForkTemp[side.id] = tempSnapshot }
        selectConversation(side.id)
    }

    /// 侧问源文件: 显式绑定 (历史侧问做源的场景禁了, 这里兜底) → 派生路径存在性校验。
    private func sideChatSourceFile(for sid: UUID) -> String? {
        if let f = persistence?.loadSessionFile(id: sid), !f.isEmpty { return f }
        let derived = PiRpcTransport.sessionFilePath(for: sid)
        return FileManager.default.fileExists(atPath: derived) ? derived : nil
    }

    // MARK: - 定向 dream (P15.9 `由此 Dream`)

    /// 菜单项可用性 —— **规则在 `SchedulerService.canTargetDream`**, 这里只喂当前状态。
    /// 侧栏也走同一个静态函数（那边喂的是 `SidebarModel` 的投影）, 于是两处不会漂。
    func canTargetDream(for sid: UUID) -> Bool {
        SchedulerService.canTargetDream(sid: sid, running: runningTurns,
                                        tasks: scheduler.scheduledTasks)
    }

    /// 二次确认弹窗的数据。**点了才查**（一条聚合, 不解码事件流）；
    /// 侧栏悬停/展开不碰它 —— 那是 boss 2026-10-21 明确否掉的做法。
    func dreamPreview(from sid: UUID) -> DreamPreview? {
        guard let item = allConversations.first(where: { $0.id == sid }),
              let stats = persistence?.dreamMaterialStats(id: sid) else { return nil }
        let label = SchedulerService.sessionRootLabels(store: self)[sid]
            ?? KnowledgeBase.noteGlobalLabel
        return DreamPreview(id: sid, title: item.displayTitle,
                            materialChars: stats.chars, turns: stats.turns, lines: stats.lines,
                            rootLabel: label, budget: Tune.dreamTargetedMaxChars)
    }

    /// 真正 fire 一次定向 dream。四种结果的**每一种都有话说** —— 静默返回是这里最坏的反馈。
    func startTargetedDream(from sid: UUID) {
        guard let item = allConversations.first(where: { $0.id == sid }) else { return }
        let stats = persistence?.dreamMaterialStats(id: sid) ?? (chars: 0, turns: 0, lines: 0)
        switch scheduler.runTargetedDream(item, stats: stats) {
        case .started:
            setExtensionNotice(String(format: L("已开始 dream：%@"), item.displayTitle), isError: false)
        case .busy:
            setExtensionNotice(L("上一场 dream 还在跑，等它结束再试"), isError: true)
        case .empty:
            setExtensionNotice(L("这一场没有可提炼的正文（只有工具输出）"), isError: true)
        case .noTask:
            setExtensionNotice(L("找不到 dream 任务，去定时页看看"), isError: true)
        }
    }

    /// 定向 dream 收口 —— 由 `SchedulerService.finishDreamFireIfNeeded` 调。
    /// 文案在**这里**成型: `SchedulerService` 在 L10n 的 `EXCLUDE_FILES` 里（恒中文只适用于
    /// 落库的日志时间线），而横幅是界面文案, 必须过词表。
    func notifyTargetedDreamFinished(targetId: UUID, kept: Int) {
        let title = allConversations.first { $0.id == targetId }?.displayTitle ?? L("已删除的会话")
        // 一个字符串只放一个占位符（本仓 L10n 硬规矩）: 拆两段再拼, 语序不由译文决定。
        let head = String(format: L("dream 完成：%lld 条提案待审"), kept)
        setExtensionNotice(head + " · " + title, isError: false)
    }

    /// 从源 session 文件截取前 N 轮快照, 写入临时文件供 --fork。
    /// N = nil 直接返回源路径 (零拷贝); 失败 (源不可读) 返回 nil。
    static func prepareForkSnapshot(sourcePath: String, turns: Int) -> String? {
        guard let lines = try? String(contentsOfFile: sourcePath, encoding: .utf8)
            .components(separatedBy: .newlines) else { return nil }
        // 过滤末尾空行 (components 按分隔符拆分会产生尾空串)
        let content = lines.filter { !$0.isEmpty }
        let prefix = snapshotLinePrefix(content, turns: turns)
        let out = content.prefix(prefix).joined(separator: "\n") + "\n"
        let dir = PiRpcTransport.sessionDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/side-snapshot-" + UUID().uuidString + ".jsonl"
        guard FileManager.default.createFile(atPath: path, contents: out.data(using: .utf8)) else {
            return nil
        }
        return path
    }

    /// 截断点计算 (纯函数, 冒烟直测): 保留到第 turns 轮结束 = 丢弃第 turns+1 条 user 消息起的所有行。
    /// user 消息判定: type=message 且 message.role=user (pi JSONL 语义)。
    /// 注意: 线性前缀截断, 分支树的旁支条目随前缀丢弃 (parentIds 仍自洽)。
    static func snapshotLinePrefix(_ lines: [String], turns: Int) -> Int {
        var userSeen = 0
        for (i, line) in lines.enumerated() {
            if Self.isUserEntry(line) {
                if userSeen == turns { return i }   // 第 turns+1 条 user 起 = 下一轮, 从这里截断
                userSeen += 1
            }
        }
        return lines.count   // turns ≥ 源轮数: 整文件
    }

    private static func isUserEntry(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "message",
              let msg = obj["message"] as? [String: Any] else { return false }
        return msg["role"] as? String == "user"
    }

    /// fork 回读收尾 (成功/失败共用): 临时快照清理。
    private func cleanupForkTemp(sid: UUID) {
        if let tmp = pendingForkTemp.removeValue(forKey: sid) {
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }

    // MARK: - Send (只做入参整理, 生成逻辑在 transport)

    func sendDraft(ephemeral: Bool = false) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingImages.isEmpty else { return }
        // 引擎缺失: 不发请求, 本地给一条说明 (engineMissing 横幅常驻在聊天顶部)
        if engineMissing {
            messages.append(ChatMessage(role: .assistant,
                                        content: .text(L("⚠️ 未找到 pi CLI, 无法发送。请确认已安装 pi 并重启 MangoX (或检查 pi 安装路径)。"))))
            return
        }
        ensureConversationForSend() // 无选中会话时隐式建会话, 消息才有归属
        guard let sid = selectedConversationId,
              !runningTurns.contains(sid) else { return } // P4.0.2: 该会话已有回合在途, 防双流竞争
        // P4.0.4: 并发上限 —— 拒绝 + 横幅提示 (v1 不排队)
        if atTurnLimit {
            draft = trimmed
            setTurnLimitNotice(String(format: L("并发已达上限 (%lld), 请等待任务结束或在设置中调高"), maxConcurrentTurns))
            return
        }
        // P7-M6b 门控: 附件随时可挂, 发送时才拦 (模型不支持图片 → 提示换模型, 附件不白挂)
        var attachments: [Attachment] = []
        var outgoing: [OutgoingImage] = []
        if !pendingImages.isEmpty {
            guard currentModelSupportsImages else {
                setTurnLimitNotice(L("当前模型不支持图片输入, 请在设置中改用多模态模型后再发"))
                return
            }
            for p in pendingImages {
                guard let saved = try? ImagePipeline.saveOriginal(p.data, fileExtension: p.fileExtension,
                                                                  sessionID: sid) else { continue }
                attachments.append(Attachment(path: saved.path, pixelWidth: p.pixelWidth,
                                              pixelHeight: p.pixelHeight, mimeType: p.mimeType,
                                              byteSize: saved.byteSize))
                // 发送字节: png/gif/webp 未超限透传 (保动图), 其余压 JPEG 副本
                if let payload = ImagePipeline.outgoingPayload(data: p.data, ext: p.fileExtension,
                                                               pixelWidth: p.pixelWidth,
                                                               pixelHeight: p.pixelHeight) {
                    outgoing.append(OutgoingImage(data: payload.data, mimeType: payload.mimeType))
                }
            }
        }
        let msg = ChatMessage(role: .user, content: .text(trimmed),
                              attachments: attachments.isEmpty ? nil : attachments)
        messages.append(msg)
        draft = ""
        pendingImages = []
        persistMessage(msg, sid: sid)
        autoTitleIfNeeded(sid: sid, text: trimmed)   // P6.4: 默认标题会话按首条消息自动命名
        // 任务 fire 轮次保持 ephemeral (交接文件注入模板不得滚进持久 transcript)
        beginTurn(sid: sid, prompt: trimmed.isEmpty ? L("请看图") : trimmed, ephemeral: ephemeral,
                  cwd: activeProjectPath, unattended: false, images: outgoing)
    }

    // MARK: - P7-M6b 图片附件暂存 (三入口: 附件按钮/⌘V/拖拽)

    func addPendingImage(_ data: Data, suggestedExtension ext: String) {
        guard ImagePipeline.isImageExtension(ext) || ext.isEmpty else { return }
        guard pendingImages.count < ImagePipeline.maxPerMessage else {
            setTurnLimitNotice(String(format: L("单条消息最多 %lld 张图片, 超出请拆条发送"), ImagePipeline.maxPerMessage))
            return
        }
        guard let size = ImagePipeline.pixelSize(of: data) else {
            setTurnLimitNotice(L("无法识别的图片数据"))
            return
        }
        pendingImages.append(PendingImage(id: UUID(), data: data,
                                          fileExtension: ext.isEmpty ? "png" : ext.lowercased(),
                                          pixelWidth: size.width, pixelHeight: size.height))
    }

    func addPendingImage(at url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            setTurnLimitNotice(L("无法读取图片文件"))
            return
        }
        addPendingImage(data, suggestedExtension: url.pathExtension)
    }

    func removePendingImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    /// 首条消息自动命名: 仍是默认标题 → 取首行前 10 字符 (一次性, 之后用户可随意重命名)。
    func autoTitleIfNeeded(sid: UUID, text: String) {   // P9.1d: internal — CaptureService 回调
        guard let item = allConversations.first(where: { $0.id == sid }),
              item.title == Self.defaultConversationTitle else { return }
        let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !firstLine.isEmpty else { return }
        renameConversation(sid, to: String(firstLine.prefix(10)))
    }

    /// P4.0.2: 回合启动公共路径 (用户会话与定时 fire 共用)。
    /// spawn 期配置在 send 前逐实例下发 (会话绑定/cwd/审批策略)。
    /// modeOverride (P8-T27): 捕获轮强制 Minimal —— 只覆盖该会话实例,
    /// 全局 agentMode 不动 (主窗口其余会话档位不受污染)。
    func beginTurn(sid: UUID, prompt: String, ephemeral: Bool,   // P9.1b: internal — SchedulerService fire 回调
                   cwd: String?, unattended: Bool, images: [OutgoingImage] = [],
                   modeOverride: AgentMode? = nil,
                   approvalOverride: ApprovalMode? = nil,   // P10.2a-0: 邮箱哨兵 = .autoJudge
                   modelOverride: (provider: String, modelId: String, thinking: String?)? = nil,
                   dreamSpool: String? = nil) {   // P15.3: 仅 dream fire 非 nil
        let t = transportFor(sid)
        if ephemeral {
            t.updateSessionBinding(nil)   // nil = --no-session (fire 轮次, P3.9 拍板)
        } else {
            t.updateSessionBinding(sid)
            // P6.3.1: 侧问绑定 (决策见 sideChatBinding; 普通会话 = derived, 无额外下发)
            switch sideChatBinding(for: sid) {
            case .fork(let src):          t.startForkSession(sourceFile: src)
            case .explicitFile(let path): t.updateSessionFilePath(path)
            case .derived:                break
            }
        }
        t.updateWorkingDirectory(cwd)
        // P15.3: dream spool 是**实例级 per-turn** 的 —— 与 `modeOverride` 同一层,
        // **不是**档位也不是全局。⚠️ 这是**无条件赋值**（不是 `if let`）: 普通回合要把它清回 nil,
        // 否则任务日志会话里手动说一句话之后, 那份 transport 会一直挂着 dream 扩展与 env。
        t.updateDreamSpool(dreamSpool)
        // 无人值守 fire 关审批 (弹卡 = 任务死锁); 其余跟随全局开关。
        // P10.2a-0: approvalOverride 优先 —— 邮箱哨兵走 .autoJudge (白名单放行 + 危险命令拒且不阻塞),
        // 它是 per-turn 下发, 会被全局 askApproval 开关覆盖, 故每回合 send 前重设。
        if let approvalOverride {
            t.updateApprovalMode(approvalOverride)
        } else {
            t.updateApprovalPolicy(askApproval: unattended ? false : askApproval)
        }
        if let modeOverride { t.updateMode(modeOverride) }
        // P10.4: 任务级模型期望 (transport 实例级, 全局零污染; spawn 快照在本轮生效)
        if let m = modelOverride {
            t.setModel(provider: m.provider, modelId: m.modelId)
            if let thinking = m.thinking { t.setThinkingLevel(thinking) }
        }
        liveTurns[sid] = liveTurns[sid] ?? []   // 镜像容器就位 (视图会话事件直进 messages)
        runningTurns.insert(sid)
        turnStartAt[sid] = Date()   // P4.1: 回合计时起点
        if sid == selectedConversationId { awaySummary = nil }   // P6.3.2: 新回合开始清过期摘要
        if injectedTransport != nil { injectedTurnSid = sid }   // 注入实例: 记录串行回合归属
        t.send(prompt: prompt, images: images)
    }

    /// 无选中会话时隐式创建 (持久化要求每条消息都有 session 归属)。
    /// 选了 project 则新会话归入该 project (工作区/cwd 绑定的前提)。
    private func ensureConversationForSend() {
        guard selectedConversationId == nil else { return }
        let item = ConversationItem(title: Self.defaultConversationTitle)
        if let pid = selectedProjectId,
           let g = projects.firstIndex(where: { $0.id == pid }) {
            projects[g].items.insert(item, at: 0)
            try? persistence?.insertChatSession(item, projectId: pid)
        } else {
            chats.insert(item, at: 0)
            try? persistence?.insertChatSession(item)
        }
        selectedConversationId = item.id
        markLastSession()
    }

    /// P9-#16: 核心数据路径统一落库入口 — 失败打日志 + 一次性横幅 (原 try? 全静默:
    /// 磁盘满/库损坏时消息"只活到下次重放"而无任何信号)。其余 try? 调用点随 P9.1 拆分收敛。
    func persistOrNotify(_ op: String, _ body: () throws -> Void) {   // P9.1d: internal — CaptureService 落库回调
        do { try body() } catch {
            print("[Persistence] \(op) 失败: \(error)")
            setTurnLimitNotice(String(format: L("⚠️ 本地库写入失败 (%@), 数据可能未保存"), op), isError: true)
        }
    }

    /// 落库: 显式 sid 优先 (回合归属), 缺省回落当前选中会话。
    func persistMessage(_ m: ChatMessage, sid: UUID? = nil) {   // P9.1b: internal — SchedulerService fire 落库
        guard let sid = sid ?? selectedConversationId else { return }
        persistOrNotify(L("消息落库")) { try persistence?.appendMessageEvent(sessionId: sid, m) }
        touchConversation(sid)   // P8.0: 消息落库即刷新侧栏活跃时间
    }

    /// P8.0: 会话活跃 → 侧栏 updatedAt 同步刷新 (日分组/排序/相对时间的数据源)。
    /// 旧实现只在创建/重命名时定格, 日分组把陈旧值暴露成"昨天"误显; db 同刷保重启后仍准。
    private func touchConversation(_ sid: UUID, at date: Date = .now) {
        if let idx = chats.firstIndex(where: { $0.id == sid }) {
            let old = chats[idx]
            chats[idx] = ConversationItem(id: sid, title: old.title, updatedAt: date,
                                          unreadCount: old.unreadCount, sideOf: old.sideOf)
        }
        if let pidx = projects.firstIndex(where: { $0.items.contains { $0.id == sid } }),
           let iidx = projects[pidx].items.firstIndex(where: { $0.id == sid }) {
            let old = projects[pidx].items[iidx]
            projects[pidx].items[iidx] = ConversationItem(id: sid, title: old.title, updatedAt: date,
                                                          unreadCount: old.unreadCount, sideOf: old.sideOf)
        }
        try? persistence?.touchSession(id: sid, updatedAt: date)
    }

    /// 停止选中会话的在途回合 (Composer 停止按钮入口)。
    func stopStreaming() {
        guard let sid = selectedConversationId else { return }
        stopTurn(sid)
    }

    /// 停止指定会话的在途回合 (P4.2 迷你条 [■] 停止按钮也走这里):
    /// 先 abort, 再兜底收尾 (半截回复落库 + 回合状态清理)。
    /// pi abort 后进程退出会再发 streamEnded —— 幂等, 不双写 (finalize 翻转沿防重)。
    /// 手动停止不发完成通知/闪显 (用户自己停的; turnStartAt 先清即可)。
    func stopTurn(_ sid: UUID) {
        guard runningTurns.contains(sid) else { return }
        transportFor(sid).cancel()
        if sid == selectedConversationId,
           let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
            persistMessage(messages[idx], sid: sid)
        }
        runningTurns.remove(sid)
        liveTurns[sid] = nil
        turnStartAt[sid] = nil
        approvalBlocked.remove(sid)   // P8-T26: 手动停 → 在途审批一并死掉
        if injectedTurnSid == sid { injectedTurnSid = nil }
        finishWaitingFireIfNeeded(sid: sid)
        // P15.3: dream 的收口挂在**与等待型同一个位置** —— 两者都是"这次 fire 到此为止"的落点。
        // 手动停（本处）也要收: 「跑不完不算失败」, 已经产出的提案照样进表。
        scheduler.finishDreamFireIfNeeded(sid: sid)
        // 这一轮到此为止 ⇒ 把这场会话在**今天**的流水刷新一次。
        // 放在 dream 收口之后（那之后 spool 已变成提案，流水里那一行才说得出"几轮"）。
        // 节流在 `TimelineJournal` 里（3 秒），所以同一轮漏出的多个落定事件不会重写三遍。
        TimelineJournal.recordSession(store: self, sessionId: sid)
        mailbox.noteTurnFinished(sid: sid, blocks: transportFor(sid).autoJudgeBlocks)
    }

    /// 重新生成: 截断最后一条 user 消息之后的内容并重放流式回复。
    func regenerate() {
        guard let sid = selectedConversationId,
              !runningTurns.contains(sid) else { return }
        if atTurnLimit {
            setTurnLimitNotice(String(format: L("并发已达上限 (%lld), 请等待任务结束或在设置中调高"), maxConcurrentTurns))
            return
        }
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        if messages.count > lastUserIdx + 1 {
            messages.removeSubrange((lastUserIdx + 1)...)
        }
        guard case .text(let prompt) = messages[lastUserIdx].content else { return }
        // P9-#2: 库侧同步截断 — 只删内存不删 events, 重启重放后旧回复会复活并与新回复并存
        _ = try? persistence?.deleteEventsAfterLastUser(sessionId: sid)   // 返回 Int, 显式弃 (消 unused warning)
        beginTurn(sid: sid, prompt: prompt, ephemeral: false,
                  cwd: activeProjectPath, unattended: false)
    }

    // MARK: - Model / effort (P9.1c: 状态/菜单/物化在 ModelStore, 此处仅转发)

    /// 菜单全集 (自管优先, 回落 pi 上报目录; 纯模型列表 —— 级别的笛卡尔积展开已删)。
    var menuModels: [AgentModelInfo] { model.menuModels }

    /// 「这个 provider/id 还在不在模型清单里」—— **判据只此一处**, 两个消费点:
    ///   ① `applySessionConfig` —— 会话恢复时模型已被删 ⇒ 只恢复其余项, 不动当前模型;
    ///   ② `SchedulerService.runScheduledFire` —— fire 前拦下已经下线的 pinned 模型。
    ///
    /// **清单为空 = 无从判断 ⇒ 一律放行**: 探针还没回报时把所有定时任务一起拦掉,
    /// 是比"放过去"更坏的 bug（拦了不 fire, 用户还不知道为什么）。
    func isKnownModel(provider: String, modelId: String) -> Bool {
        let known = model.menuModels
        return known.isEmpty || known.contains { $0.provider == provider && $0.id == modelId }
    }

    /// 当前选中组合 (composer 药丸初值)。
    var currentChoice: ModelChoice { model.currentChoice }

    /// 条目显示名 (自管条目优先; 含 legacy 迁移条目)。
    func customLabel(provider: String, modelId: String) -> String? {
        model.customLabel(provider: provider, modelId: modelId)
    }

    /// 当前选中模型的显示名: 自管 label 优先, 回落 id 末段。
    var currentModelDisplayName: String { model.currentModelDisplayName }

    /// 物化产物下发 (探测实例 + 注入实例 + 全部会话实例; 模型变更/启动时调用)。
    func refreshPIConfig() {
        model.refreshPIConfig()
    }

    /// 新增/更新自管模型 (落库 + 刷物化)。
    func upsertManagedModel(_ m: ManagedModel) {
        model.upsertManagedModel(m)
    }

    /// 删除自管模型 (落库 + 刷物化)。
    func deleteManagedModel(_ m: ManagedModel) {
        model.deleteManagedModel(m)
    }

    /// 启停开关 (enabled 决定进不进物化清单)。
    func setManagedModelEnabled(_ id: String, _ enabled: Bool) {
        model.setManagedModelEnabled(id, enabled)
    }

    /// provider 级 key 存取 (Keychain; account = provider, 物化进 auth.json)。
    func setProviderKey(_ key: String, provider: String) {
        model.setProviderKey(key, provider: provider)
    }

    func providerKey(provider: String) -> String? {
        model.providerKey(provider: provider)
    }

    /// 选中自管模型 (settings 行"启用"; 级别收敛到该模型支持的档位)。
    func selectManagedModel(_ m: ManagedModel) {
        model.selectManagedModel(m)
    }

    /// 选中组合 (整体写入; 级别由 `ModelPicker` 收敛为合法停靠点):
    /// 全局期望更新 (新实例由 transportFor 补发) + 选中会话实例即时下发。
    func selectModel(_ pick: ModelChoice) {
        model.selectModel(pick)
    }

    // MARK: - Knowledge (P3.7; P9.1c 起状态与逻辑在 KnowledgeStore, 此处仅转发)

    /// 当前生效条数 (Composer pill 显示用)。
    var activeKnowledgeCount: Int { knowledge.activeKnowledgeCount }

    /// 提炼候选 (待审核)。
    var pendingKnowledge: [KnowledgeItem] { knowledge.pendingKnowledge }

    /// 组装注入块 (nil = 无可注入内容)。
    func buildKnowledgeBlock() -> String? {
        knowledge.buildKnowledgeBlock()
    }

    /// 左列「自定义」区 (2026-09-22 起按**来源**分区, 不再是按层分区):
    /// 已审核 + 生效作用域的 DB 条目, **含被关掉的**(可见 ≠ 会被注入, 见 `KnowledgeStore.customKnowledge`)。
    var customKnowledge: [KnowledgeItem] { knowledge.customKnowledge }
    /// P15.3 起是 dream 提案的**只读快照**; P15.4 起可拍板 —— 但写入口只有
    /// `knowledge.adoptProposal` / `discardProposal` 两个（View 直接调 `store.knowledge.*`,
    /// 与 `saveNote` / `createNote` 同一条路, 不在这里再包一层转发）。
    var noteProposals: [NoteProposal] { knowledge.noteProposals }
    /// 笔记区的**唯一根列表**（笔记根在前、历史挂载库在后）。
    /// ⚠️ P15.5 起它不再有"折算后"这个说法 —— P11.4 的内置 L1 库已退休，两表合一。
    var allKnowledgeBases: [KnowledgeBase] { knowledge.allKnowledgeBases }
    func knowledgeBase(id: String) -> KnowledgeBase? { knowledge.knowledgeBase(id: id) }
    /// 挂载 / 改描述 / 启停 / 摘库 —— 返回 nil = 成功; 非 nil = 拒绝原因(**数据**, 文案在 View 侧拼)。
    @discardableResult
    func addKnowledgeBase(path: String, description: String) -> KnowledgeBaseRejection? {
        knowledge.addKnowledgeBase(path: path, description: description)
    }
    @discardableResult
    func updateKnowledgeBase(id: String, description: String? = nil,
                             enabled: Bool? = nil) -> KnowledgeBaseRejection? {
        knowledge.updateKnowledgeBase(id: id, description: description, enabled: enabled)
    }
    func toggleKnowledgeBase(id: String) { knowledge.toggleKnowledgeBase(id: id) }
    func deleteKnowledgeBase(id: String) { knowledge.deleteKnowledgeBase(id: id) }
    /// 载荷条 (P11.1 A 块) 所需: 最近一次组装结果 + 告警 (**数据**; 文案在 View 侧拼)。
    var lastInjection: KnowledgeStore.KnowledgeInjection { knowledge.lastInjection }
    var injectionWarnings: [KnowledgeStore.KnowledgeWarning] { knowledge.injectionWarnings }
    /// persona pack 目录。key 保留集合不再对外转发 —— 它的唯一消费者是编辑器的 key 输入口,
    /// 而那个口已在 P11.2c 撤下 (见 `KnowledgeStore` 里同位置的说明)。
    var personaPackDir: String { knowledge.personaPackDir }
    /// persona pack 全文 (P11.2a: 只读展示 + 组装第一段)。
    var personaPack: PersonaPack { knowledge.personaPack }
    /// App 外改了人格文件后重建快照 (磁盘为准, 但不指望用户重启 App)。
    func reloadPersonaPackAndRefresh() { knowledge.reloadPersonaPackAndRefresh() }

    /// 返回 nil = 成功; 非 nil = 拒绝原因 (**数据**; 文案在 View 侧拼, 见 `KeyRejection`)。
    /// 缺省值必须与 `KnowledgeStore.addKnowledge` **逐字一致** (这里是纯转发) ——
    /// 包括 `layer = .always` (P11.2d: 新建即生效), 否则 facade 与实现会给出两套缺省。
    @discardableResult
    func addKnowledge(title: String, content: String, scope: KnowledgeScope, projectId: UUID?,
                      kind: KnowledgeKind = .fact, layer: KnowledgeLayer = .always,
                      priority: Int = 0, key: String? = nil,
                      trigger: String? = nil, counterfactual: String? = nil) -> KnowledgeStore.KeyRejection? {
        knowledge.addKnowledge(title: title, content: content, scope: scope, projectId: projectId,
                               kind: kind, layer: layer, priority: priority, key: key,
                               trigger: trigger, counterfactual: counterfactual)
    }

    @discardableResult
    func updateKnowledge(_ item: KnowledgeItem) -> KnowledgeStore.KeyRejection? {
        knowledge.updateKnowledge(item)
    }

    func deleteKnowledge(id: UUID) {
        knowledge.deleteKnowledge(id: id)
    }

    func toggleKnowledge(id: UUID) {
        knowledge.toggleKnowledge(id: id)
    }

    /// 会话内"保存为记忆": 文本沉淀为全局知识条目, 带 origin_session_id 溯源。
    func saveAsMemory(_ text: String, sessionId: UUID?) {
        knowledge.saveAsMemory(text, sessionId: sessionId)
    }

    func setDistillOutcome(_ text: String, isError: Bool) {
        knowledge.setDistillOutcome(text, isError: isError)
    }

    /// 手动触发: 提炼当前会话 → 候选落 pending (审核在知识面板)。
    func distillMemoryFromCurrentSession() {
        knowledge.distillMemoryFromCurrentSession()
    }

    /// 审核采纳: pending → active。返回 nil = 成功; 非 nil = 拒绝原因 (**数据**)。
    @discardableResult
    func adoptKnowledge(id: UUID) -> KnowledgeStore.KeyRejection? {
        knowledge.adoptKnowledge(id: id)
    }

    /// 审核丢弃。
    func discardKnowledge(id: UUID) {
        knowledge.discardKnowledge(id: id)
    }

    /// 打开知识面板 (面板互斥, 与 toggle 同语言但强制打开)。
    func openKnowledgePanel() {
        showKnowledgePanel = true
        showScheduledPanel = false
        showExtensionsPanel = false
    }

    /// Composer pill "重启引擎生效": 重启池内全部实例使最新注入块生效 (丢进程内对话记忆, 用户显式触发)。
    func restartEngine() {
        transports.values.forEach { $0.restartEngine() }
        capabilityProbe?.restartEngine()
        knowledgeDirty = false
        extensionsDirty = false
    }

    /// 面板互斥: 打开一个关另外两个 (主区同一时刻只显示一个面板)。
    ///
    /// ⚠️ **2026-10-10 修**: 原先这里只清 `showScheduledPanel` (下面那条只清 `showKnowledgePanel`)
    /// —— **两个 toggle 谁都没清 `showExtensionsPanel`**。于是"开过 Plugins 再点 Knowledge"
    /// 会留下两个 true, 而主区只显示一个: 侧栏的 Plugins 行一直亮着, 却点不出已开的面板。
    /// 当时看不出来 (高亮只是把图标染个色); P14 给导航行加了选中胶囊后, 同一个状态错
    /// 直接表现成**两颗胶囊同时亮** —— 状态错被 UI 放大成"有两个当前项"。
    /// 不变量由 `panelsExclusive` + 冒烟守住 (别再往这里加"只清一个"的分支)。
    func toggleKnowledgePanel() {
        showKnowledgePanel.toggle()
        if showKnowledgePanel {
            showScheduledPanel = false
            showExtensionsPanel = false
        }
    }

    // MARK: - Settings (P14: 设置已是**独立窗口**, 开关归 SettingsWindowController)

    /// `showSettingsPanel` 现在只是**独立设置窗的可见性镜像** —— 唯一的写入方是
    /// SettingsWindowController(开窗置 true / 关窗置 false)。它**不再参与主区面板互斥**:
    /// 窗口可以和主窗口里任何一个面板并存。侧栏高亮与其它消费点读的就是这个 flag。

    // MARK: - Scheduled (P3.6 本地定时任务)

    func toggleScheduledPanel() {
        showScheduledPanel.toggle()
        if showScheduledPanel {
            showKnowledgePanel = false
            showExtensionsPanel = false
        }
    }

    // MARK: - Scheduled (P3.6 本地定时任务; P9.1b 起由 SchedulerService 承载, 此处仅转发)

    func addScheduled(name: String, prompt: String, cron: String,
                      projectId: UUID?, continuous: Bool = false) {
        scheduler.addScheduled(name: name, prompt: prompt, cron: cron,
                               projectId: projectId, continuous: continuous)
    }

    func updateScheduled(_ t: ScheduledTask) {
        scheduler.updateScheduled(t)
    }

    /// 删除任务; deleteSessions = 连带删除日志会话 (开放问题 12: 默认保留, 用户可选删)。
    func deleteScheduled(id: UUID, deleteSessions: Bool = false) {
        scheduler.deleteScheduled(id: id, deleteSessions: deleteSessions)
    }

    func toggleScheduled(id: UUID) {
        scheduler.toggleScheduled(id: id)
    }

    /// 到点投递 (P3.9): 全链路在 SchedulerService, ChatStore 转发 (冒烟直访入口)。
    func runScheduledFire(_ task: ScheduledTask, at now: Date = Date()) {
        scheduler.runScheduledFire(task, at: now)
    }

    /// P17: 漏跑清单 (视图经 facade 读; 冒烟直访 SchedulerService)。
    var missedFires: [SchedulerService.MissedFire] { scheduler.missedFires }

    /// P17: 补跑最近一次 / 认账忽略 (视图经 facade 调)。
    func catchUpMissedFire(_ taskId: UUID) { scheduler.catchUpMissedFire(taskId) }
    func ignoreMissedFire(_ taskId: UUID) { scheduler.ignoreMissedFire(taskId) }

    /// P15.3: dream 的 spool 落点 (冒烟直访; 视图侧不用它 —— 谁跑 dream 由任务 id 认)。
    static func dreamSpoolPath(taskId: UUID) -> String {
        PiRpcTransport.dreamSpoolPath(taskId: taskId)
    }

    /// 交接文件路径 (ScheduledView 经 facade 访问)。
    func handoffPath(for task: ScheduledTask) -> String {
        scheduler.handoffPath(for: task)
    }

    /// 读交接文件 (ScheduledView 经 facade 访问)。
    func readHandoff(for task: ScheduledTask) -> (content: String, updatedAt: Date?)? {
        scheduler.readHandoff(for: task)
    }

    /// 写交接文件 (ScheduledView 经 facade 访问)。
    @discardableResult
    func saveHandoff(for task: ScheduledTask, content: String) -> Bool {
        scheduler.saveHandoff(for: task, content: content)
    }

    /// P3.10: 侧栏任务日志会话标志 (定时任务 clock / 哨兵任务雷达)。
    func scheduledBadge(for sessionId: UUID) -> String? {
        scheduler.scheduledBadge(for: sessionId)
    }

    // MARK: - Tool approval (转发给 transport)

    /// Commands the user chose to always allow (persisted only for this run).
    @Published var alwaysAllowedToolIds: Set<UUID> = []

    /// 审批决策的**本地痕迹**（P16，瞬态、**不落库**）。
    ///
    /// ⚠️ 为什么需要它：`routeToolDecision` 只做两件事 —— 转发 transport + 清
    /// `approvalBlocked`。**`phase` 原地不动**（要等 agent 回事件才流转）⇒ 用户点完「允许」
    /// 之后，卡片上那行会继续写「待审批」，而三个按钮已经消失 —— 自相矛盾。
    /// 有了这一笔，行右立刻兑现成「已允许 / 已拒绝 / 已允许（始终）」。
    ///
    /// ⚠️ 有意**不写进 `ToolCall`**：那个模型是 Codable、会进 DB，碰它就撞「DB 列只增不删」
    /// （已发版 tag ⇒ 旧版打开新库即崩）；何况这是纯 UI 瞬态，本来就不该落库。
    @Published var toolDecisions: [UUID: PermissionDecision] = [:]

    func approveTool(_ toolId: UUID) {
        routeToolDecision(toolId, .allow)
    }

    func denyTool(_ toolId: UUID) {
        routeToolDecision(toolId, .deny)
    }

    func alwaysAllowTool(_ toolId: UUID) {
        // P3.10: bash "始终允许" → 学习各段首 token 到持久白名单 (跨会话生效)
        if let card = currentToolCard(toolId), card.kind == .bash {
            let cmd = card.command ?? card.title
            let tokens = BashRiskEvaluator.learnTokens(command: cmd)
            if !tokens.isEmpty {
                bashWhitelist.formUnion(tokens)
                persistence?.saveBashWhitelist(bashWhitelist)
                transports.values.forEach { $0.updateBashWhitelist(bashWhitelist) }
            }
        }
        alwaysAllowedToolIds.insert(toolId)
        routeToolDecision(toolId, .alwaysAllow)
    }

    /// 审批路由 (P4.0.2): 卡片只可能出现在当前视图的会话中 (后台回合不弹卡),
    /// 按选中会话取池实例转发; 冒烟注入态由 transportFor 回落注入实例。
    private func routeToolDecision(_ toolId: UUID, _ decision: PermissionDecision) {
        guard let sid = selectedConversationId else { return }
        transportFor(sid).respondToPermission(toolId: toolId, decision: decision)
        approvalBlocked.remove(sid)   // P8-T26: 审批已响应, phase 流转即清
        // P16: 记一笔本地痕迹 —— phase 要等 agent 回事件才动, 卡片得先自己兑现"已决策"。
        toolDecisions[toolId] = decision
    }

    private func currentToolCard(_ toolId: UUID) -> ToolCall? {
        for msg in messages {
            if case .tool(let t) = msg.content, t.id == toolId { return t }
        }
        return nil
    }

    /// Locate a message whose `.tool` content matches `toolId` and swap its phase.
    private func setToolPhase(_ toolId: UUID, _ phase: ToolPhase) {
        for i in messages.indices {
            if case .tool(let tool) = messages[i].content, tool.id == toolId {
                messages[i].content = .tool(tool.withPhase(phase))
                return
            }
        }
    }
}

// MARK: - AgentTransportDelegate (事件归并: AgentEvent → messages 状态)

extension ChatStore: AgentTransportDelegate {
    /// P4.0.2: 事件归属路由 —— transport 实例即会话身份 (回调首参数)。
    /// 注入实例 (冒烟) 全会话共用 → 归属 send 时刻定格的回合会话 (无则在途选中会话)。
    private func sessionOf(_ transport: any AgentTransport) -> UUID? {
        if let injectedTransport, transport === injectedTransport {
            return injectedTurnSid ?? selectedConversationId
        }
        for (sid, t) in transports where t === transport { return sid }
        return nil
    }

    func transport(_ transport: any AgentTransport, didEmit event: AgentEvent) {
        // 探测实例/已逐出实例的事件 (能力探测进程偶发上行) → 无归属, 丢弃
        guard let sid = sessionOf(transport) else { return }
        handleTurnEvent(event, sid: sid)
    }

    /// 回合事件归并 (带归属会话): 视图会话写 messages, 后台会话写 liveTurns 镜像。
    /// 两容器同构处理 —— 切换会话时由 selectConversation 负责迁移/合并。
    private func handleTurnEvent(_ event: AgentEvent, sid: UUID) {
        let inView = sid == selectedConversationId

        switch event {
        case .streamStarted:
            // runningTurns 在 beginTurn 即插入 (这里仅确认, 不重复维护)。
            // P12.1a: 引擎真跑起来了一条流 ⇒ 清掉上次的启动失败诊断 (判据用"能开工",
            // 不用"进程在"—— 半死的进程照样在)。
            engineDiagnosis = nil

        case .textChunk(let id, let delta):
            // P10.5: 无宿主 chunk 丢弃 —— 回合已落定 (或被替换) 后的迟到 chunk 若新建消息会成单字残块
            guard runningTurns.contains(sid) || hasStreamingHost(id, sid: sid) else { break }
            if inView {
                upsertStreaming(in: &messages, id: id, delta: delta, think: false)
            } else {
                upsertStreaming(in: &liveTurns[sid, default: []], id: id, delta: delta, think: false)
            }

        case .thoughtChunk(let id, let delta):
            guard runningTurns.contains(sid) || hasStreamingHost(id, sid: sid) else { break }   // P10.5 同上
            if inView {
                upsertStreaming(in: &messages, id: id, delta: delta, think: true)
            } else {
                upsertStreaming(in: &liveTurns[sid, default: []], id: id, delta: delta, think: true)
            }

        case .toolUpdated(let tool):
            var terminal = false
            if case .done = tool.phase { terminal = true }
            if case .error = tool.phase { terminal = true }
            let msg = ChatMessage(role: .assistant, content: .tool(tool))
            if inView {
                upsertTool(in: &messages, tool: tool)
            } else {
                upsertTool(in: &liveTurns[sid, default: []], tool: tool)
            }
            if terminal {
                persistMessage(msg, sid: sid)   // 终态落库 (trajectory 只存终态事件)
            }
            if case .awaitingApproval = tool.phase { approvalBlocked.insert(sid) }   // P8-T26

        case .messageFinalized(let id, let usage):
            if inView {
                finalizeBlock(in: &messages, id: id, sid: sid, usage: usage)
            } else {
                finalizeBlock(in: &liveTurns[sid, default: []], id: id, sid: sid, usage: usage)
            }

        case .toolPhaseChanged(let toolId, let phase):
            if inView {
                setToolPhase(toolId, phase)
            } else {
                setToolPhaseIn(&liveTurns[sid, default: []], toolId, phase)
            }
            persistOrNotify(L("工具相位落库")) { try persistence?.appendToolUpdateEvent(sessionId: sid, toolId: toolId, phase: phase) }
            if case .awaitingApproval = phase { approvalBlocked.insert(sid) }   // P8-T26

        case .extensionNotify(let type, let message):
            // P6.0②: 扩展 fire-and-forget 通知 → 底栏横幅 (8s 自清; error/warning 用错误样式)。
            setExtensionNotice(message, isError: type == "error" || type == "warning")

        case .contextCompacted(let before, let after, let reason):
            // A: 常驻标记 —— 与一次性横幅**同时**存在, 一个管"此刻", 一个管"回看"。
            // 视图/后台同构处理 (后台会话写 liveTurns 镜像, 切回来时随迁移并入 messages)。
            // ⚠️ 这条**不过 `inView` 守卫**: 后台会话压缩完, 用户切回来时必须看到它发生过
            //    (横幅那条会挂到别的会话上, 见 .extensionNotify 缺 inView 的已知偏差)。
            let marker = ChatMessage(role: .system,
                                     content: .compaction(tokensBefore: before,
                                                          tokensAfter: after,
                                                          reason: reason))
            if inView {
                messages.append(marker)
            } else {
                liveTurns[sid, default: []].append(marker)
            }
            persistMessage(marker, sid: sid)   // 重启重放要能重建这条事实
            // B: 当场改写上下文统计 (仅当前选中会话 —— sessionStats 只服务它)
            if inView { applyCompactionTokens(after) }

        case .usageTick(let stats):
            // P6.1.1: 流式期用量 tick (仅前台会话; context% 缺省沿用最近一次上报)
            guard inView else { break }
            applySessionStats(stats)

        case .phaseChanged(let phase):
            // P6.1.2: 过程态胶囊 (仅前台会话; 切会话由 selectConversation 重置)
            guard inView else { break }
            runtimePhase = phase

        case .emptyTurn(let model):
            // 2026-10-21 (空回合): 引擎正常收尾却零产出 —— 生产上这曾经**完全静默**（实测:
            // 模型下线 ⇒ API 404 ⇒ pi 把它吃成空回合）。这里落一条**持久化**的事实行:
            // 这条会话回看时必须看得见"这一回合跑过、什么都没回"，否则它就等于没发生过。
            //
            // ⚠️ 文案取词在**写入时**（同 `setTurnLimitNotice`），不另造 `MessageContent` case:
            //    这是一条诊断记录，不是用户要拿来对账的字段（对照 P6 的压缩标记 —— 那个存的是
            //    tokensBefore/After 这类**证据数字**，所以它必须结构化）。
            let text = model.map {
                String(format: L("引擎返回了空回合 · 模型 %@ 可能不存在或已下线"), $0)
            } ?? L("引擎返回了空回合 · 引擎没有返回任何内容, 请检查模型与凭据")
            let msg = ChatMessage(role: .system, content: .text(text))
            if inView {
                messages.append(msg)
            } else {
                liveTurns[sid, default: []].append(msg)   // 后台会话: 随镜像迁移并入 (库为准)
            }
            persistMessage(msg, sid: sid)

        case .streamEnded:
            runningTurns.remove(sid)
            approvalBlocked.remove(sid)   // P8-T26: 回合落定兜底清 (防审批泄漏常亮)
            if inView {
                // 安全网: 收尾视图内所有在途流式块 (text + think 可能同时各有一条)
                for i in messages.indices where messages[i].isStreaming {
                    messages[i].isStreaming = false
                }
            }
            // P4.1/P4.2: 回合完成 —— 前台闪显迷你条完成卡 / 非前台发系统通知。
            // elapsed 取自 turnStartAt 且只能取一次 (手动停过的回合已被清 → 不通知)。
            let elapsed = turnStartAt.removeValue(forKey: sid).map { Date().timeIntervalSince($0) }
            if let elapsed {
                // 回复预览须在镜像清除前取
                let proj = sid == selectedConversationId ? messages : (liveTurns[sid] ?? [])
                // 轮末账单的耗时记账 —— 必须赶在 `liveTurns[sid] = nil` 之前（下面几行就地清镜像）。
                // 只记实测值；手动停止那条路 `elapsed` 是 nil（turnStartAt 已被清）⇒ 不记，账单少一格。
                noteTurnElapsed(sid: sid, projection: proj, seconds: elapsed)
                // P6.3.2: 不在场完成 → 积累 (手动停止 elapsed=nil 已被排除; 摘要独立于通知,
                // 已发系统通知的完成回到前台仍会出横幅 —— 拍板 2026-09-14)
                if sid != selectedConversationId || !appIsActive {
                    accumulateAway(sid: sid, projection: proj)
                }
                if elapsed >= 1 {
                    let title = allConversations.first { $0.id == sid }?.displayTitle ?? L("任务")
                    let mins = Int(elapsed) / 60, secs = Int(elapsed) % 60
                    if appIsForeground {
                        // P4.2: mini 台完成闪显数据 (显示 5s 后自清, mini 窗口保持不自动还原)
                        lastCompleted = (sid, title, String(format: L("✓ 完成 · 耗时 %02d:%02d"), mins, secs))
                        lastCompletedTask?.cancel()
                        lastCompletedTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            if !Task.isCancelled { lastCompleted = nil }
                        }
                    } else if completionNotificationsEnabled {
                        notifyCompletion(sid: sid, title: title, elapsed: elapsed, projection: proj)
                    }
                }
            }
            liveTurns[sid] = nil   // 产出已落库, 镜像即弃 (库为准)
            if injectedTurnSid == sid { injectedTurnSid = nil }
            finishWaitingFireIfNeeded(sid: sid)
            scheduler.finishDreamFireIfNeeded(sid: sid)   // P15.3: 正常落定的那条路
            // 同上（`stopTurn` 那处也有一份）—— 两个落定点记的是同一件事。
            // 分两处而不是抽一个"回合结束"统一入口: 现在没有这样一个入口, 而造一个
            // 要动整条事件分发的形状（那远超"记一行流水"该动的范围）。
            TimelineJournal.recordSession(store: self, sessionId: sid)
            // P10.2a/b: 释放远程回合串行位 + 结算回执 (blocks = 本回合 autoJudge 拦下的命令;
            // 事件归并没有 transport 参数, 用 sid 反查池实例 —— 与 stopTurn 同一写法)
            mailbox.noteTurnFinished(sid: sid, blocks: transportFor(sid).autoJudgeBlocks)
        }
    }

    // MARK: - P9-#15: NSApp 活跃判定 (单一实现, 双语义兜底)
    // 冒烟/CLI 无 Bundle.main → headlessDefault 兜底: 通知/闪显路径传 false (视为非前台, no-op);
    // 在场判定路径传 true (否则冒烟里一切完成都会被算成"离开")。

    private func isAppActive(headlessDefault: Bool) -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return headlessDefault }
        return NSApp.isActive
    }

    /// App 是否前台激活 (通知/mini 台闪显判定)。
    private var appIsForeground: Bool { isAppActive(headlessDefault: false) }

    // MARK: - P6.3.2: 离开摘要 (Away summary)

    /// 不在场完成 → 积累 (sid 分键; preview 取该轮最后一条 assistant 首行前 60 字)。
    /// 调用点保证 projection 在镜像清除前传入。
    private func accumulateAway(sid: UUID, projection: [ChatMessage]) {
        let preview = Self.assistantPreviewLine(projection)
        var entry = pendingAway[sid] ?? (turns: 0, preview: "")
        entry.turns += 1
        if !preview.isEmpty { entry.preview = preview }
        pendingAway[sid] = entry
    }

    /// 结算选中会话的积累 → 展示态 (selectConversation / didBecomeActive 调用)。
    /// 只消费当前 key, 其余会话的积累原封留着等各自被选中。
    private func settleAwaySummary() {
        guard let sid = selectedConversationId else { awaySummary = nil; return }
        if let p = pendingAway.removeValue(forKey: sid) {
            awaySummary = AwaySummary(sid: sid, turns: p.turns, preview: p.preview)
        } else {
            awaySummary = nil
        }
    }

    /// × 按钮: 只关不滚。点击滚底路径由视图调同一方法 (滚动在视图层做)。
    func dismissAwaySummary() {
        awaySummary = nil
    }

    /// P6.3.2: App 是否激活 (在场判定, 兜底方向与 appIsForeground 相反 — 见 isAppActive 注释)。
    private var appIsActive: Bool { isAppActive(headlessDefault: true) }

    /// P4.1: 组装完成通知 (标题 = 会话/任务名, 正文 = 耗时 + 回复首行 60 字)。
    private func notifyCompletion(sid: UUID, title: String, elapsed: TimeInterval,
                                  projection: [ChatMessage]) {
        let preview = Self.assistantPreviewLine(projection)
        let mins = Int(elapsed) / 60, secs = Int(elapsed) % 60
        let body = preview.isEmpty
            ? String(format: L("回合完成 · 耗时 %02d:%02d"), mins, secs)
            : String(format: L("回合完成 · 耗时 %02d:%02d\n%@"), mins, secs, preview)
        Task { await CompletionNotifier.shared.post(sessionId: sid, title: title, body: body) }
    }

    /// 投影里最后一条 assistant 文本的首行前 60 字 (P4.1 通知与 P6.3.2 摘要共用)。
    static func assistantPreviewLine(_ proj: [ChatMessage]) -> String {
        proj.reversed().compactMap { msg -> String? in
            guard msg.role == .assistant, case .text(let s) = msg.content, !s.isEmpty else { return nil }
            return s
        }.first.map { line -> String in
            let first = line.split(separator: "\n").first.map(String.init) ?? line
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        } ?? ""
    }

    // MARK: - P4.2 迷你条数据投影

    /// 迷你条 L1: 会话名 / 任务名。
    func turnTitle(_ sid: UUID) -> String {
        allConversations.first { $0.id == sid }?.displayTitle ?? L("任务")
    }

    /// 迷你条 L1: 回合计时 (mm:ss)。
    func turnElapsedText(_ sid: UUID) -> String {
        guard let start = turnStartAt[sid] else { return "--:--" }
        let t = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// 迷你条 L2 摘要: 在途工具卡 title → 流式文本尾部 60 字 → "思考中…" → "运行中…"。
    func miniSummary(_ sid: UUID) -> String {
        let proj = sid == selectedConversationId ? messages : (liveTurns[sid] ?? [])
        for msg in proj.reversed() {
            if case .tool(let t) = msg.content {
                switch t.phase {
                case .done, .error: continue   // 终态卡不是"当前活动"
                default: return t.title
                }
            }
            if msg.isStreaming, case .text(let s) = msg.content {
                return "…" + String(s.suffix(60))
            }
            if msg.isStreaming, case .think = msg.content {
                return L("思考中…")
            }
        }
        return L("运行中…")
    }

    /// 流式块 upsert: 有则追加 delta (光标保持), 无则建块 (归属路由保证内容不断头)。
    private func upsertStreaming(in list: inout [ChatMessage], id: UUID, delta: String, think: Bool) {
        if let idx = list.lastIndex(where: { $0.id == id }) {
            if think, case .think(let existing) = list[idx].content {
                list[idx].content = .think(existing + delta)
            } else if !think, case .text(let existing) = list[idx].content {
                list[idx].content = .text(existing + delta)
            }
            list[idx].isStreaming = true
        } else {
            list.append(ChatMessage(id: id, role: .assistant,
                                    content: think ? .think(delta) : .text(delta),
                                    isStreaming: true))
        }
    }

    /// 工具卡整对象 upsert (按 ToolCall.id 定位, 无则新建)。
    private func upsertTool(in list: inout [ChatMessage], tool: ToolCall) {
        if let idx = list.lastIndex(where: {
            if case .tool(let t) = $0.content { return t.id == tool.id }
            return false
        }) {
            list[idx].content = .tool(tool)
        } else {
            list.append(ChatMessage(role: .assistant, content: .tool(tool)))
        }
    }

    /// 相变原位应用 (镜像容器版本, 与 setToolPhase 同构)。
    private func setToolPhaseIn(_ list: inout [ChatMessage], _ toolId: UUID, _ phase: ToolPhase) {
        for i in list.indices {
            if case .tool(let tool) = list[i].content, tool.id == toolId {
                list[i].content = .tool(tool.withPhase(phase))
                return
            }
        }
    }

    /// 流式块收尾: 摘光标 + done 标记剥离 (fire 回合扫描) + 落库 (+ usage 挂载 P5.0.1)。
    /// 仅在 streaming→false 的翻转沿落库 (防 stopStreaming 兜底与事件收尾双写)。
    private func finalizeBlock(in list: inout [ChatMessage], id: UUID, sid: UUID, usage: MessageUsage? = nil) {
        guard let idx = list.lastIndex(where: { $0.id == id }) else { return }
        let wasStreaming = list[idx].isStreaming
        list[idx].isStreaming = false
        if let usage { list[idx].usage = usage }
        if case .text(let s) = list[idx].content, s.contains(SchedulerService.doneMarker) {
            list[idx].content = .text(stripDoneMarker(s, sid: sid))
        }
        if wasStreaming { persistMessage(list[idx], sid: sid) }
    }

    /// 剥离任务状态标记 (doneMarker); 命中且该会话有在途 fire → 通知 SchedulerService (P9.1b)。
    private func stripDoneMarker(_ s: String, sid: UUID) -> String {
        guard s.contains(SchedulerService.doneMarker) else { return s }
        scheduler.noteDoneMarkerHit(sid: sid)
        return s.replacingOccurrences(of: SchedulerService.doneMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// P3.10/P4.0.2: 等待型 fire 收尾——done 命中则自动停用任务 (P9.1b: 状态在 SchedulerService)。
    private func finishWaitingFireIfNeeded(sid: UUID) {
        scheduler.finishWaitingFireIfNeeded(sid: sid)
    }

    // MARK: - P3.5: 能力上报归并

    /// 能力上报只接受探测实例 (池实例 spawn 也会上报 get_state, 不覆盖全局状态)。
    /// 上报值仅作首次初始化 (字段为空时): 探测实例 spawn 不带 --model, 报的是 pi 的
    /// settings.json 默认——若持续回写, 会把用户刚选的模型打回默认 (已实证)。
    func transport(_ transport: any AgentTransport,
                   didUpdateModelState provider: String, modelId: String, thinkingLevel: String) {
        guard transport === capabilityProbe else { return }
        captureAppDefault(provider: provider, modelId: modelId, thinkingLevel: thinkingLevel)
        if currentProvider.isEmpty { currentProvider = provider }
        if currentModelId.isEmpty { currentModelId = modelId }
        if let level = ThinkingLevel(rawValue: thinkingLevel), !userThinkingLevelPinned {
            self.thinkingLevel = level
        }
    }

    func transport(_ transport: any AgentTransport, didReportModels: [AgentModelInfo]) {
        guard transport === capabilityProbe else { return }
        availableModels = didReportModels
    }

    /// P6.1.1: get_session_stats 上报 (spawn 期 / settled 拆进程前)。仅当前选中会话生效
    /// (探测实例无归属 → sessionOf 为 nil, 天然丢弃其空统计)。
    func transport(_ transport: any AgentTransport, didReportSessionStats stats: SessionStats) {
        guard let sid = sessionOf(transport), sid == selectedConversationId else { return }
        applySessionStats(stats)
    }

    /// P12.1a: 引擎启动失败诊断 —— **有意不设 `sessionOf` 守卫**: 起不来是全局事实,
    /// 探测实例上的失败同样必须让用户看见 (原实现丢 stderr ⇒ 这就是那条静默失败的终点)。
    func transport(_ transport: any AgentTransport, didFailEngineWithDiagnosis diagnosis: String) {
        engineDiagnosis = diagnosis
    }

    private func applySessionStats(_ s: SessionStats) {
        var merged = s
        if merged.contextPercent == nil { merged.contextPercent = sessionStats?.contextPercent }
        sessionStats = merged
    }

    /// B: 压缩成功后**立刻**用 pi 的 `estimatedTokensAfter` 改写上下文统计。
    ///
    /// 为什么必须做: pi 压缩后把 `contextUsage.tokens/percent` 报成 **null**
    /// (`rpc-commands.md`: "null immediately after compaction until a fresh
    /// post-compaction assistant response provides valid usage data"), 而
    /// `applySessionStats` 遇到 null 是**沿用上次的值** ⇒ 底栏会一直挂着**压缩前**
    /// 那个百分比, 直到下一次 settled 上报。数字是错的, 但看不出错 —— 这正是 B 要堵的洞。
    ///
    /// 改写的是 pi 自己给的估算值, 下一次完整上报到达后自然被真值覆盖; 窗口未知时
    /// 百分比留 nil (UI 显示 "--"), 不猜一个分母。
    private func applyCompactionTokens(_ tokens: Int) {
        var s = sessionStats ?? SessionStats()
        s.contextTokens = tokens
        s.contextPercent = s.contextWindow > 0
            ? Double(tokens) / Double(s.contextWindow) * 100
            : nil
        sessionStats = s
    }

    // MARK: - P6.2.3: Trace HTML 导出
    // (存储属性 exportTransport/exportTimeout/isExportingHTML 在类体; 此处只放编排方法)

    /// 导出文件路径: ~/.mangox/exports/<sessionId>-<yyyyMMdd-HHmmss>.html (internal 供冒烟)。
    static func exportHTMLPath(sessionId: UUID, now: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return NSHomeDirectory() + "/.mangox/exports/"
            + sessionId.uuidString + "-" + df.string(from: now) + ".html"
    }

    /// Trace 头导出按钮 → 临时拉起会话绑定进程 → export_html → Finder reveal。
    func exportTraceHTML() {
        guard let sid = selectedConversationId, exportTransport == nil else { return }
        let path = Self.exportHTMLPath(sessionId: sid)
        try? FileManager.default.createDirectory(
            atPath: NSHomeDirectory() + "/.mangox/exports", withIntermediateDirectories: true)
        // 注入实例优先 (冒烟: MockTransport 回 nil 走失败分支, 验证 delegate 链路不弹 Finder);
        // 生产 injectedTransport 恒 nil → 临时 transport 原行为
        let t = injectedTransport ?? Self.makeTransport()
        t.delegate = self   // P9-#1: 导出结果只经 delegate 回调上报, 缺挂 = 永远走 20s 超时兜底
        t.updateWorkingDirectory(activeProjectPath)
        t.updateSessionBinding(sid)   // pi 载入该会话 transcript 再导出
        exportTransport = t
        isExportingHTML = true
        exportTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.exportTransport === t else { return }
            self.finishExport(transport: t, path: nil, timeout: true)
        }
        t.exportHTML(outputPath: path)
    }

    private func finishExport(transport t: any AgentTransport, path: String?, timeout: Bool = false) {
        exportTimeout?.cancel()
        exportTimeout = nil
        exportTransport = nil
        isExportingHTML = false
        t.shutdown()
        if let path {
            setExtensionNotice(L("HTML 已导出 · 已在 Finder 显示"), isError: false)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            setExtensionNotice(timeout ? L("导出超时") : L("导出失败"), isError: true)
        }
    }

    func transport(_ transport: any AgentTransport, didFinishExportHTMLPath path: String?) {
        guard exportTransport === transport else { return }
        finishExport(transport: transport, path: path)
    }

    // MARK: - P6.3.1: fork 产物回读归并

    /// 成功: 产物路径落库 (后续回合 --session 显式绑定) + 临时快照清理。
    /// 失败: 首回合已失败 (孤儿快照语义) → 删除空的侧问会话 + 横幅。
    func transport(_ transport: any AgentTransport, didReadSessionFile path: String?) {
        guard let sid = sessionOf(transport) else { return }
        defer { cleanupForkTemp(sid: sid) }
        if let path {
            try? persistence?.setSessionFile(id: sid, path: path)
            transport.updateSessionFilePath(path)
        } else {
            setExtensionNotice(L("侧问创建失败：快照回读未完成 (回合未成功)"), isError: true)
            deleteConversation(sid)
        }
    }
}
