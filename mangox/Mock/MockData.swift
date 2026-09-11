//
//  MockData.swift
//  Centralized in-memory state driving the UI.
//  P3.0: Agent 生成/审批逻辑已下沉到 AgentTransport, 这里只做事件归并 + UI 状态。
//

import Foundation
import SwiftUI
import AppKit

@MainActor
final class ChatStore: ObservableObject {

    /// P4.0.2 Transport 池: sessionId -> 实例 (每会话一个; 内部仍 per-turn 进程, spawn 即跑完即退)。
    private var transports: [UUID: any AgentTransport] = [:]
    /// 能力探测专用实例 (get_state/get_available_models, 不承载回合; 冒烟注入时复用注入实例)。
    private var capabilityProbe: (any AgentTransport)?
    /// 冒烟/测试注入的单实例: 注入时全会话共用 (串行语义, 保持回归基线)。
    private let injectedTransport: (any AgentTransport)?
    /// spawn 期配置快照: 新实例创建时与每次 send 前下发 (P3.7 注入 / P3.11 扩展)。
    private var currentKnowledgeBlock: String?
    private var currentExtensionPaths: [String] = []
    /// P4.0.2 会话化流式状态: 在途回合的会话集合 (并发数 = 集合大小; 上限治理在 P4.0.4)。
    @Published private(set) var runningTurns: Set<UUID> = []
    /// 兼容视图: 当前选中会话是否有回合在途。
    var isStreaming: Bool {
        selectedConversationId.map { runningTurns.contains($0) } ?? false
    }
    /// P3.1: SQLite 持久化; 打不开时降级为纯内存 (原 mock 行为)。
    private let persistence: PersistenceStore?

    // Chat
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    /// 引擎不可用 (pi CLI 缺失): Release 下不静默降级, UI 横幅明示 + 发送守卫。
    @Published var engineMissing: Bool = false

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
    /// 超限拒绝横幅 (Composer 上方, 8s 自清; 与提炼横幅同语言)。
    @Published var turnLimitNotice: (text: String, isError: Bool)?
    private var turnLimitNoticeTask: Task<Void, Never>?

    /// 主区切换: true = 设置面板 (侧栏 gear 入口)。
    @Published var showSettingsPanel: Bool = false

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


    func setTurnLimitNotice(_ text: String, isError: Bool = true) {
        turnLimitNotice = (text, isError)
        turnLimitNoticeTask?.cancel()
        turnLimitNoticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { turnLimitNotice = nil }
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
    @Published var workspaceVisible: Bool = false {
        didSet {
            // 无工作目录时强制回 Chat (切换到普通 chat 会话的场景)
            if workspaceVisible, !canUseWorkspace { workspaceVisible = false }
        }
    }

    /// 全部会话（跨 projects + chats）。
    var allConversations: [ConversationItem] {
        projects.flatMap(\.items) + chats
    }

    /// 顶栏标题: 当前会话名, 无选中则 "New chat"。
    var selectedTitle: String {
        allConversations.first { $0.id == selectedConversationId }?.title ?? "New chat"
    }

    // Workspace (第三栏, 文件树): 真实目录扫描 (P3.4), 无项目时为空
    @Published var fileTree: [FileNode] = []

    // Status bar
    @Published var status: AgentStatus = SampleSession.status

    // P3.5: 对端能力上报
    /// 可用模型清单 (pi get_available_models; 空 = 尚未上报, 菜单只显示当前模型)。
    @Published var availableModels: [AgentModelInfo] = []
    /// 当前模型 (provider/id 分量), 与 status.modelName 同步更新。
    @Published var currentProvider: String = ""
    @Published var currentModelId: String = ""
    /// 当前思考级别 (pi 状态; UI 用 ReasoningEffort 映射)。
    @Published var thinkingLevel: ThinkingLevel = .high
    /// 用户是否已在 UI 选过模型/级别 (选过 = 期望值钉死, 探测上报不再回写)。
    @Published var userThinkingLevelPinned: Bool = false

    // P3.7: 知识库/记忆 (统一模型, 记忆 = source=session 条目)
    @Published var knowledgeItems: [KnowledgeItem] = []
    /// 主区切换: false = 会话视图, true = 知识面板 (侧栏 book 入口)。
    @Published var showKnowledgePanel: Bool = false
    /// 知识有改动但引擎尚未重启 (注入块仍旧, 需 Composer pill "重启引擎生效")。
    @Published var knowledgeDirty: Bool = false

    // P3.6: 本地定时任务 (仅 App 运行期生效, launchd 后置)
    @Published var scheduledTasks: [ScheduledTask] = []
    @Published var showScheduledPanel: Bool = false
    private var schedulerTimer: Timer?
    private var lastSchedulerMinute: Int = 0
    // P3.10: 等待型任务 fire 的回合追踪 (P4.0.2 会话化: 日志会话 sid -> 任务 id)
    private var bashWhitelist: Set<String> = []
    private var fireTurnTask: [UUID: UUID] = [:]   // 在途 fire: 日志会话 -> 任务 id
    private var fireDoneHit: Set<UUID> = []        // 本轮日志会话已命中 done 标记
    /// 等待型任务完成标记 (HTML 注释: Markdown 渲染不可见, 客户端可解析)
    static let doneMarker = "<!--task: done-->"

    // MARK: - P3.11 扩展管理
    @Published var extensions: [ExtensionItem] = []
    @Published var showExtensionsPanel = false
    @Published var extensionsDirty = false   // 启停后未重启引擎
    private var disabledExtensionPaths: Set<String> = []
    /// smoke 注入: 托管扩展目录 (默认 ~/.mangox/extensions)
    private let managedExtensionsDir: String

    /// 扫描三区扩展并叠加启停状态 (spawn 带 --no-extensions, 自动发现区在 MangoX 内不生效)
    func scanExtensions() {
        let fm = FileManager.default
        var items: [ExtensionItem] = []
        let scanDir = { (dir: String) -> [String] in
            (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? []
        }
        // 托管区
        for f in scanDir(managedExtensionsDir) where f.hasSuffix(".ts") || f.hasSuffix(".js") {
            let path = managedExtensionsDir + "/" + f
            let name = (f as NSString).deletingPathExtension
            let builtIn = name == ExtensionItem.builtInName
            items.append(ExtensionItem(name: name, path: path, source: .managed,
                                       enabled: builtIn || !disabledExtensionPaths.contains(path),
                                       isBuiltIn: builtIn))
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
        transports.values.forEach { $0.updateExtensions(enabled) }
    }

    /// 启停托管扩展 (生效需重启引擎)
    func toggleExtension(_ item: ExtensionItem) {
        guard item.source == .managed, !item.isBuiltIn else { return }
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

    /// 删除托管扩展 (内置除外)
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
        (try? String(contentsOfFile: item.path, encoding: .utf8)) ?? "// 无法读取源码"
    }

    func toggleExtensionsPanel() {
        showExtensionsPanel.toggle()
        showKnowledgePanel = false
        showScheduledPanel = false
        showSettingsPanel = false
        if showExtensionsPanel { scanExtensions() }
    }

    // Layout
    @Published var sidebarCollapsed: Bool = false

    init(transport: (any AgentTransport)? = nil, dbPath: String? = nil,
         managedExtensionsDir: String? = nil) {
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
            scheduledTasks = (try? store.loadScheduled()) ?? []
            // 启动恢复: 打开上一次作业会话 (settings.last_session_id);
            // 无记录或会话已删除 → 欢迎空态, 发送时才隐式建会话。
            if let last = store.loadLastSession(),
               allConversations.contains(where: { $0.id == last }) {
                selectedConversationId = last
                messages = replayMessages(for: last)
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
        }
        scanExtensions()   // P3.11: 扫描 + 快照托管扩展列表 (池实例 spawn 期加载)
        syncWorkspaceContext()   // 文件树扫描 (P3.4); cwd 在每次 send 前按实例下发
        // P3.7: 注入块快照 (池实例 spawn 期消费)
        currentKnowledgeBlock = buildKnowledgeBlock()
        probe.refreshCapabilities()   // P3.5: 模型/effort 上报 (pi 拉起 + get_state/models)
        startScheduler()   // P3.6: 每秒 tick, 分钟对齐检查到期任务

        // WAL 落盘 + 杀在途 pi: 强杀/exit 不跑 deinit, 数据滞留 -wal 会在下次清库时全丢;
        // 在途回合的 pi 若不终止会变孤儿进程继续烧 LLM token
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPersistence()
                self?.capabilityProbe?.shutdown()
                self?.transports.values.forEach { $0.shutdown() }
            }
        }
    }

    /// SQLite WAL → 主文件落盘 (供退出钩子与冒烟测试调用)。
    func flushPersistence() {
        persistence?.checkpoint()
    }

    /// 记录"上一次作业会话" (启动恢复用)。选中会话变化的所有入口都要调。
    private func markLastSession() {
        if let sid = selectedConversationId {
            try? persistence?.saveLastSession(id: sid)
        }
    }

    // MARK: - Sidebar interactions

    /// Codex 式新建会话：插入 Chats 平铺区顶部并选中, 消息清空。
    func newConversation() {
        let item = ConversationItem(title: "New chat")
        chats.insert(item, at: 0)
        selectedConversationId = item.id
        messages = []
        showKnowledgePanel = false   // 从面板发起新会话 → 回会话视图
        showScheduledPanel = false
        showExtensionsPanel = false
        showSettingsPanel = false
        try? persistence?.insertChatSession(item)
        markLastSession()
        syncWorkspaceContext()   // 新 chat 无项目 → 工作区清空, Work 回 Chat
    }

    /// 重命名会话（保留 id, 刷新 updatedAt）。
    func renameConversation(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for g in projects.indices {
            if let idx = projects[g].items.firstIndex(where: { $0.id == id }) {
                projects[g].items[idx].title = trimmed
                projects[g].items[idx] = ConversationItem(
                    id: projects[g].items[idx].id, title: trimmed,
                    updatedAt: .now,
                    unreadCount: projects[g].items[idx].unreadCount)
                return
            }
        }
        if let idx = chats.firstIndex(where: { $0.id == id }) {
            chats[idx] = ConversationItem(id: chats[idx].id, title: trimmed,
                                          updatedAt: .now,
                                          unreadCount: chats[idx].unreadCount)
        }
        try? persistence?.renameSession(id: id, title: trimmed, updatedAt: .now)
    }

    /// 删除会话；删的是当前会话则顺延选中第一个, 全空则回到空态。
    /// 删除会话; deleteTranscript = 连带删除 pi 持久 transcript (<uuid>.jsonl)。
    /// 默认保留: 文件是 agent 的对话记忆, 误删不可恢复 (UI 二次确认里让用户选)。
    func deleteConversation(_ id: UUID, deleteTranscript: Bool = false) {
        evictTransport(id)   // P4.0.2: 逐出池实例 (终止在途 pi + 清回合状态), 无论是否当前选中
        try? persistence?.deleteSession(id: id) // 连带清 events
        if deleteTranscript {
            PiRpcTransport.removeSessionFile(for: id)   // pi 持久 transcript
        }
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
    private func replayMessages(for id: UUID) -> [ChatMessage] {
        guard let persistence else { return [] }
        return (try? persistence.loadMessages(sessionId: id)) ?? []
    }

    // MARK: - Workspace (P3.4: 文件树扫描 + 项目目录管理)

    /// 重扫文件树 (cwd 在每次 send 前按会话实例下发, P4.0.2 池化)。
    private func syncWorkspaceContext() {
        if let root = activeProjectPath {
            fileTree = WorkspaceScanner.scanShallow(root: root)   // lazy: 只扫一层, 展开时按需加载
        } else {
            fileTree = []
        }
        // P3.11: 项目区扩展跟随 cwd, 目录变了重扫 (托管/全局区结果不变, 幂等)
        scanExtensions()
    }

    /// 工作区列手动刷新入口: 只重扫文件树 (不动 cwd 绑定与扩展)。
    func refreshFileTree() {
        guard let root = activeProjectPath else { return }
        fileTree = WorkspaceScanner.scanShallow(root: root)
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
        let item = ConversationItem(title: "New chat")
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
        showSettingsPanel = false
        markLastSession()
        syncWorkspaceContext()
    }

    /// 删除项目 (侧栏 "..." → 二次确认后调用): 连带其下所有会话与消息。
    func deleteProject(_ id: UUID) {
        guard let g = projects.firstIndex(where: { $0.id == id }) else { return }
        let removed = projects.remove(at: g)
        try? persistence?.deleteProject(id: id)
        removed.items.forEach { evictTransport($0.id) }   // P4.0.2: 其下会话实例全部逐出
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
    private func transportFor(_ sid: UUID) -> any AgentTransport {
        if let injectedTransport { return injectedTransport }   // 冒烟: 全会话共用单实例 (串行基线)
        if let t = transports[sid] { return t }
        let t = Self.makeTransport()
        t.delegate = self
        t.updateApprovalPolicy(askApproval: askApproval)
        t.updateBashWhitelist(bashWhitelist)
        t.updateExtensions(currentExtensionPaths)
        t.updateKnowledgeContext(currentKnowledgeBlock)
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
        fireTurnTask[sid] = nil
        fireDoneHit.remove(sid)
        turnStartAt[sid] = nil
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
        showSettingsPanel = false
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
        guard let id else { return }
        messages = replayMessages(for: id)
        // 会话回合在途 → 合并实时镜像 (库快照 + 在途产出), 切回不缺半截;
        // 已落库的 finalized 块 replay 已含 → 按 id 去重
        if runningTurns.contains(id), let live = liveTurns[id] {
            let known = Set(messages.map(\.id))
            messages.append(contentsOf: live.filter { !known.contains($0.id) })
            liveTurns[id] = nil   // 后续事件直接进 messages (已选中)
        }
        markLastSession()
        syncWorkspaceContext()   // 选中会话变化 → 工作区上下文跟随 (P3.4)
    }

    // MARK: - Send (只做入参整理, 生成逻辑在 transport)

    func sendDraft(ephemeral: Bool = false) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 引擎缺失: 不发请求, 本地给一条说明 (engineMissing 横幅常驻在聊天顶部)
        if engineMissing {
            messages.append(ChatMessage(role: .assistant,
                                        content: .text("⚠️ 未找到 pi CLI, 无法发送。请确认已安装 pi 并重启 MangoX (或检查 pi 安装路径)。")))
            return
        }
        ensureConversationForSend() // 无选中会话时隐式建会话, 消息才有归属
        guard let sid = selectedConversationId,
              !runningTurns.contains(sid) else { return } // P4.0.2: 该会话已有回合在途, 防双流竞争
        // P4.0.4: 并发上限 —— 拒绝 + 横幅提示 (v1 不排队)
        if atTurnLimit {
            draft = trimmed
            setTurnLimitNotice("并发已达上限 (\(maxConcurrentTurns)), 请等待任务结束或在设置中调高")
            return
        }
        let msg = ChatMessage(role: .user, content: .text(trimmed))
        messages.append(msg)
        draft = ""
        persistMessage(msg, sid: sid)
        // 任务 fire 轮次保持 ephemeral (交接文件注入模板不得滚进持久 transcript)
        beginTurn(sid: sid, prompt: trimmed, ephemeral: ephemeral,
                  cwd: activeProjectPath, unattended: false)
    }

    /// P4.0.2: 回合启动公共路径 (用户会话与定时 fire 共用)。
    /// spawn 期配置在 send 前逐实例下发 (会话绑定/cwd/审批策略)。
    private func beginTurn(sid: UUID, prompt: String, ephemeral: Bool,
                           cwd: String?, unattended: Bool) {
        let t = transportFor(sid)
        t.updateSessionBinding(ephemeral ? nil : sid)   // nil = --no-session (fire 轮次, P3.9 拍板)
        t.updateWorkingDirectory(cwd)
        // 无人值守 fire 关审批 (弹卡 = 任务死锁); 其余跟随全局开关
        t.updateApprovalPolicy(askApproval: unattended ? false : askApproval)
        liveTurns[sid] = liveTurns[sid] ?? []   // 镜像容器就位 (视图会话事件直进 messages)
        runningTurns.insert(sid)
        turnStartAt[sid] = Date()   // P4.1: 回合计时起点
        if injectedTransport != nil { injectedTurnSid = sid }   // 注入实例: 记录串行回合归属
        t.send(prompt: prompt)
    }

    /// 无选中会话时隐式创建 (持久化要求每条消息都有 session 归属)。
    /// 选了 project 则新会话归入该 project (工作区/cwd 绑定的前提)。
    private func ensureConversationForSend() {
        guard selectedConversationId == nil else { return }
        let item = ConversationItem(title: "New chat")
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

    /// 落库: 显式 sid 优先 (回合归属), 缺省回落当前选中会话。
    private func persistMessage(_ m: ChatMessage, sid: UUID? = nil) {
        guard let sid = sid ?? selectedConversationId else { return }
        try? persistence?.appendMessageEvent(sessionId: sid, m)
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
        if injectedTurnSid == sid { injectedTurnSid = nil }
        finishWaitingFireIfNeeded(sid: sid)
    }

    /// 重新生成: 截断最后一条 user 消息之后的内容并重放流式回复。
    func regenerate() {
        guard let sid = selectedConversationId,
              !runningTurns.contains(sid) else { return }
        if atTurnLimit {
            setTurnLimitNotice("并发已达上限 (\(maxConcurrentTurns)), 请等待任务结束或在设置中调高")
            return
        }
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        if messages.count > lastUserIdx + 1 {
            messages.removeSubrange((lastUserIdx + 1)...)
        }
        guard case .text(let prompt) = messages[lastUserIdx].content else { return }
        beginTurn(sid: sid, prompt: prompt, ephemeral: false,
                  cwd: activeProjectPath, unattended: false)
    }

    // MARK: - Model / effort (P3.5: 透传给 transport, 状态以对端上报为准)

    /// 菜单条目 = 每个模型 × 其支持的思考级别 (无级别的模型单条)。
    /// 条目 id 含级别分量, 笛卡尔积下同模型多条不会 ForEach 撞 id。
    var modelMenuEntries: [ModelMenuEntry] {
        availableModels.flatMap { m in
            let levels: [ThinkingLevel?] = m.supportedLevels.isEmpty ? [nil] : m.supportedLevels
            return levels.map { ModelMenuEntry(id: "\(m.provider)/\(m.id)#\($0?.rawValue ?? "-")",
                                               model: m, level: $0) }
        }
    }

    /// 菜单条目是否为当前选中组合。
    func isCurrent(_ entry: ModelMenuEntry) -> Bool {
        entry.model.provider == currentProvider && entry.model.id == currentModelId &&
        (entry.level == nil || entry.level == thinkingLevel)
    }

    /// 选中组合: 全局期望更新 (新实例由 transportFor 补发) + 选中会话实例即时下发
    /// (pi 侧各自动回读 get_state 同步 UI; P4.0.2 spawn 期参数随该会话下回合生效)。
    func selectModel(_ model: AgentModelInfo, level: ThinkingLevel?) {
        currentProvider = model.provider
        currentModelId = model.id
        userThinkingLevelPinned = true   // 期望钉死: 探测上报不再回写级别
        if let level { thinkingLevel = level }
        guard let sid = selectedConversationId else { return }
        let t = transportFor(sid)
        t.setModel(provider: model.provider, modelId: model.id)
        if let level { t.setThinkingLevel(level.rawValue) }
    }

    // MARK: - Knowledge (P3.7 知识库/记忆, 设计见 docs §3.7)

    /// 当前生效条数 (已审核 + 启用 + 全局/当前 project)——Composer pill 显示用。
    var activeKnowledgeCount: Int {
        let pid = activeProject?.id
        return knowledgeItems.filter { item in
            guard item.enabled, item.status == .active else { return false }
            return item.scope == .global || item.projectId == pid
        }.count
    }

    /// 提炼候选 (待审核)。
    var pendingKnowledge: [KnowledgeItem] {
        knowledgeItems.filter { $0.status == .pending }
    }

    /// 组装注入块: 全局 + 当前 project 的启用条目, 带 token 预算 (单条截断/总量丢弃)。
    /// pending 候选永不注入 (审核闸门)。nil = 无可注入内容。
    func buildKnowledgeBlock() -> String? {
        let pid = activeProject?.id
        let enabled = knowledgeItems.filter { item in
            guard item.enabled, item.status == .active else { return false }
            return item.scope == .global || item.projectId == pid
        }
        guard !enabled.isEmpty else { return nil }
        // 单条上限截断
        let clipped = enabled.map { item -> KnowledgeItem in
            var c = item
            if c.content.count > Tune.knowledgeItemCharLimit {
                c.content = String(c.content.prefix(Tune.knowledgeItemCharLimit))
                    + "\n…(超出单条上限已截断)"
            }
            return c
        }
        // 总量预算: 优先保留最新 (updatedAt 降序), 超限的条目直接不入块
        var kept: [KnowledgeItem] = []
        var total = 0
        for item in clipped.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let cost = item.title.count + item.content.count
            guard total + cost <= Tune.knowledgeTotalCharLimit else { continue }
            kept.append(item)
            total += cost
        }
        guard !kept.isEmpty else { return nil }
        var lines = ["以下是 MangoX 客户端注入的知识库/记忆, 回答时请参考:"]
        let globals = kept.filter { $0.scope == .global }
        let projectScoped = kept.filter { $0.scope == .project }
        if !globals.isEmpty {
            lines.append("\n## 全局")
            globals.forEach { lines.append("- \($0.title): \($0.content)") }
        }
        if !projectScoped.isEmpty {
            lines.append("\n## 项目")
            projectScoped.forEach { lines.append("- \($0.title): \($0.content)") }
        }
        return lines.joined(separator: "\n")
    }

    func addKnowledge(title: String, content: String, scope: KnowledgeScope, projectId: UUID?) {
        let item = KnowledgeItem(id: UUID(), scope: scope,
                                 projectId: scope == .project ? projectId : nil,
                                 title: title, content: content, source: .manual)
        knowledgeItems.insert(item, at: 0)
        try? persistence?.upsertKnowledge(item)
        applyKnowledgeChange()
    }

    func updateKnowledge(_ item: KnowledgeItem) {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == item.id }) else { return }
        knowledgeItems[idx] = item
        try? persistence?.upsertKnowledge(item)
        applyKnowledgeChange()
    }

    func deleteKnowledge(id: UUID) {
        knowledgeItems.removeAll { $0.id == id }
        try? persistence?.deleteKnowledge(id: id)
        applyKnowledgeChange()
    }

    func toggleKnowledge(id: UUID) {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == id }) else { return }
        knowledgeItems[idx].enabled.toggle()
        knowledgeItems[idx].updatedAt = .now
        try? persistence?.upsertKnowledge(knowledgeItems[idx])
        applyKnowledgeChange()
    }

    /// 会话内"保存为记忆": 文本沉淀为全局知识条目, 带 origin_session_id 溯源。
    func saveAsMemory(_ text: String, sessionId: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = String(trimmed.split(separator: "\n").first?.prefix(24) ?? "记忆")
        let item = KnowledgeItem(id: UUID(), scope: .global, projectId: nil,
                                 title: String(title), content: trimmed,
                                 source: .session, originSessionId: sessionId)
        knowledgeItems.insert(item, at: 0)
        try? persistence?.upsertKnowledge(item)
        applyKnowledgeChange()
    }

    // MARK: - Memory distillation (P3.7 记忆自动提炼; v1 人工触发, 自动门槛留 v1.2)

    @Published var distillRunning: Bool = false
    /// 提炼结果提示 (Composer 上方横幅, 8s 自清)。isError = 红/绿两种横幅。
    @Published var distillOutcome: (text: String, isError: Bool)?
    private var distillOutcomeTask: Task<Void, Never>?

    func setDistillOutcome(_ text: String, isError: Bool) {
        distillOutcome = (text, isError)
        distillOutcomeTask?.cancel()
        distillOutcomeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { distillOutcome = nil }
        }
    }

    /// 打开知识面板 (面板互斥, 与 toggle 同语言但强制打开)。
    func openKnowledgePanel() {
        showKnowledgePanel = true
        showScheduledPanel = false
        showExtensionsPanel = false
        showSettingsPanel = false
    }

    /// 提炼模板 (业务语义 = TODO 占位脚手架: 边界示例与反例措辞待首个真实提炼轮后人工打磨)。
    private static func buildDistillPrompt(material: String, existing: [KnowledgeItem]) -> String {
        let list = existing.isEmpty ? "无" :
            existing.map { "- [\( $0.scope == .global ? "全局" : "项目")] \($0.title)" }.joined(separator: "\n")
        return """
        【任务: 记忆提炼】
        下面给你一段人机对话记录与现有知识条目清单。请判断对话中是否出现了值得跨会话长期记住的信息, 只输出 JSON, 不要输出任何其他文字, 不要使用任何工具。

        值得记录的只有三类:
        1. 环境/技术栈事实 —— 机器、项目结构、服务地址、数据规模等稳定事实
        2. 用户偏好与约定 —— 沟通/代码/流程上用户明确表达的偏好与规矩
        3. 决策及理由 —— 对话中拍板的技术或业务决策 (记结论和为什么)

        不要记录: 一次性任务的过程细节、代码片段本身、未验证的推测、与现有条目重复的内容 (见下方清单)。
        TODO(人工打磨): 补充边界示例与反例, 待首轮真实提炼后定稿。

        【现有知识条目】
        \(list)

        【对话记录】
        \(material)

        【输出格式】
        {"items": [{"title": "简短标题", "content": "事实本体, 精炼成独立可读的一句话或几句话", "scope": "global", "reason": "为什么值得记"}]}
        scope 只有 "global" 或 "project" 两种。没有值得记录的内容时输出 {"items": []} —— 宁可空, 不要凑数。
        """
    }

    /// 手动触发: 提炼当前会话 → 候选落 pending (审核在知识面板)。
    /// 失败静默 (解析失败/超时直接放弃, 不打扰)。
    func distillMemoryFromCurrentSession() {
        guard !distillRunning, !isStreaming else { return }
        guard let sid = selectedConversationId else { return }
        // 材料: 最近 12 条 text 消息 (user+assistant), 总量截断
        var texts = replayMessages(for: sid).compactMap { msg -> String? in
            guard case .text(let s) = msg.content, !s.isEmpty else { return nil }
            return "\(msg.role == .user ? "用户" : "助手"): \(s)"
        }
        guard texts.count > 2 else { return }   // 太短不值得提炼
        texts = Array(texts.suffix(12))
        var material = texts.joined(separator: "\n\n")
        if material.count > Tune.distillMaterialCharLimit {
            material = "…(更早的已省略)\n" + String(material.suffix(Tune.distillMaterialCharLimit))
        }
        let existing = knowledgeItems.filter { $0.status == .active }
        let prompt = Self.buildDistillPrompt(material: material, existing: existing)
        // 归属 = 会话所在的项目分组 (selectedProjectId 只在点项目/建会话时设置,
        // 从侧栏直接点开会话不同步它——用会话反查才是 source of truth)
        let projectId = projects.first(where: { $0.items.contains(where: { $0.id == sid }) })?.id
        let model = currentProvider.isEmpty ? nil : "\(currentProvider)/\(currentModelId)"
        let thinking = thinkingLevel.rawValue
        distillRunning = true
        MemoryDistiller.shared.run(prompt: prompt, model: model, thinking: thinking) { [weak self] raw in
            guard let self else { return }
            self.distillRunning = false
            guard let raw else {
                self.setDistillOutcome("提炼失败: 超时或引擎无响应 (见控制台日志)", isError: true)
                return
            }
            print("[MemoryDistiller] 原始输出 \(raw.count) 字符: \(raw.prefix(400))")
            let candidates = MemoryDistiller.parseOutput(raw)
            guard !candidates.isEmpty else {
                // 区分"模型认为没什么可记"与"输出解析失败" (都有 items 字段 = 正常应答)
                if raw.contains("\"items\"") {
                    self.setDistillOutcome("提炼完成: 本轮没有值得沉淀的内容", isError: false)
                } else {
                    self.setDistillOutcome("提炼失败: 输出无法解析 (见控制台日志)", isError: true)
                }
                return
            }
            self.addPendingKnowledge(candidates, sessionId: sid, projectId: projectId)
            self.setDistillOutcome("提炼完成: \(candidates.count) 条候选待审核", isError: false)
        }
    }

    /// 候选落 pending: 插入列表 + 落库。注入块未变 (pending 不注入) → 不标 dirty。
    /// 净化: scope=project 但无项目归属 → 降级 global (绝不建"未知项目"条目)。
    private func addPendingKnowledge(_ candidates: [MemoryDistiller.Candidate],
                                     sessionId: UUID, projectId: UUID?) {
        for c in candidates {
            let scope: KnowledgeScope = c.scope == .project && projectId != nil ? .project : .global
            let item = KnowledgeItem(id: UUID(), scope: scope,
                                     projectId: scope == .project ? projectId : nil,
                                     title: c.title, content: c.content,
                                     source: .session, originSessionId: sessionId,
                                     enabled: true, status: .pending, note: c.reason)
            knowledgeItems.insert(item, at: 0)
            try? persistence?.upsertKnowledge(item)
        }
    }

    /// 审核采纳: pending → active, 清 note, 注入块变更 → 标 dirty (重启引擎生效)。
    func adoptKnowledge(id: UUID) {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == id }),
              knowledgeItems[idx].status == .pending else { return }
        knowledgeItems[idx].status = .active
        knowledgeItems[idx].note = nil
        knowledgeItems[idx].updatedAt = .now
        try? persistence?.upsertKnowledge(knowledgeItems[idx])
        applyKnowledgeChange()
    }

    /// 审核丢弃。
    func discardKnowledge(id: UUID) {
        deleteKnowledge(id: id)
    }

    /// 知识变动后: 快照注入块 + 池内实例同步下发 + 标记引擎待重启。
    private func applyKnowledgeChange() {
        currentKnowledgeBlock = buildKnowledgeBlock()
        transports.values.forEach { $0.updateKnowledgeContext(currentKnowledgeBlock) }
        knowledgeDirty = true
    }

    /// Composer pill "重启引擎生效": 重启池内全部实例使最新注入块生效 (丢进程内对话记忆, 用户显式触发)。
    func restartEngine() {
        transports.values.forEach { $0.restartEngine() }
        capabilityProbe?.restartEngine()
        knowledgeDirty = false
        extensionsDirty = false
    }

    /// 面板互斥: 打开一个关另一个 (主区同一时刻只显示一个面板)。
    func toggleKnowledgePanel() {
        showKnowledgePanel.toggle()
        if showKnowledgePanel { showScheduledPanel = false; showSettingsPanel = false }
    }

    // MARK: - Settings (P4.0.4 最小设置页: 并发上限; 通知开关随 P4.1 加)

    func toggleSettingsPanel() {
        showSettingsPanel.toggle()
        if showSettingsPanel {
            showKnowledgePanel = false
            showScheduledPanel = false
            showExtensionsPanel = false
        }
    }

    // MARK: - Scheduled (P3.6 本地定时任务)

    func toggleScheduledPanel() {
        showScheduledPanel.toggle()
        if showScheduledPanel { showKnowledgePanel = false; showSettingsPanel = false }
    }

    func addScheduled(name: String, prompt: String, cron: String,
                      projectId: UUID?, continuous: Bool = false) {
        let t = ScheduledTask(id: UUID(), name: name, prompt: prompt, cron: cron,
                              projectId: projectId, continuous: continuous)
        scheduledTasks.append(t)
        try? persistence?.upsertScheduled(t)
    }

    func updateScheduled(_ t: ScheduledTask) {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == t.id }) else { return }
        scheduledTasks[idx] = t
        try? persistence?.upsertScheduled(t)
    }

    /// 删除任务; deleteSessions = 连带删除日志会话 (开放问题 12: 默认保留, 用户可选删)。
    func deleteScheduled(id: UUID, deleteSessions: Bool = false) {
        let sessionIds = scheduledTasks.first { $0.id == id }?.logSessionId.map { [$0] } ?? []
        scheduledTasks.removeAll { $0.id == id }
        try? persistence?.deleteScheduled(id: id)
        if deleteSessions {
            for sid in sessionIds { deleteConversation(sid) }
        }
    }

    func toggleScheduled(id: UUID) {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == id }) else { return }
        scheduledTasks[idx].enabled.toggle()
        try? persistence?.upsertScheduled(scheduledTasks[idx])
    }

    /// 调度器: 每秒 tick, 分钟变化时才检查 (对齐 cron 的最小粒度; 睡眠唤醒后靠分钟差兜底)。
    private func startScheduler() {
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulerTick() }
        }
    }

    private func schedulerTick() {
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard minute != lastSchedulerMinute else { return }
        lastSchedulerMinute = minute
        for task in scheduledTasks where task.enabled {
            guard let cron = task.cronExpr, cron.matches(now) else { continue }
            runScheduledFire(task, at: now)
        }
    }

    /// 到点投递 (P3.9 单日志会话): 任务的全部运行追加进同一个日志会话 (首次 fire 建立)。
    /// P4.0.2: 完全后台化 —— 不劫持选中会话/UI, 直接往日志会话投递回合;
    /// 该任务日志会话已有回合在途则跳过 (cron 到期不重排)。
    /// 持续模式 (continuous): 注入交接文件 (工作日志, agent 写用户可改) + 近期运行摘录,
    /// 并指令 agent 把关键进展写回交接文件——连续性靠文件携带, 磁盘为准零缓存。
    func runScheduledFire(_ task: ScheduledTask, at now: Date = Date()) {
        if let pid = task.projectId {
            guard projects.contains(where: { $0.id == pid }) else {
                recordFireSkip(task, at: now, reason: "项目已删除")
                return
            }
        }
        // 定位/建立日志会话 (有项目归 project, 无项目落平铺 Chats)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        var logId = task.logSessionId
        let logExists = logId.map { id in allConversations.contains(where: { $0.id == id }) } ?? false
        if !logExists {
            let item = ConversationItem(title: task.name)
            if let pid = task.projectId {
                if let g = projects.firstIndex(where: { $0.id == pid }) {
                    projects[g].items.insert(item, at: 0)
                }
                try? persistence?.insertChatSession(item, projectId: pid)
            } else {
                chats.insert(item, at: 0)
                try? persistence?.insertChatSession(item)
            }
            logId = item.id
        }
        guard let logId else { return }
        guard !runningTurns.contains(logId) else {
            recordFireSkip(task, at: now, reason: "该任务回合在途")
            return
        }
        // P4.0.4: 并发已满 → 落痕跳过 (与"冲突跳过"同语义, cron 到期不重排)
        if runningTurns.count >= maxConcurrentTurns {
            recordFireSkip(task, at: now, reason: "并发已满 (\(maxConcurrentTurns))")
            return
        }
        // 时间线锚点 + prompt 落库 (用户正看着日志会话则同步上屏)
        let viewing = selectedConversationId == logId
        let sep = ChatMessage(role: .user, content: .text("── \(fmt.string(from: now)) 运行 ──"))
        persistMessage(sep, sid: logId)
        if viewing { messages.append(sep) }
        let prompt = buildScheduledPrompt(task)
        let promptMsg = ChatMessage(role: .user, content: .text(prompt))
        persistMessage(promptMsg, sid: logId)
        if viewing { messages.append(promptMsg) }
        // fire 是独立轮次: ephemeral (--no-session), 连续性靠交接文件 (P3.9 拍板);
        // cwd 用任务项目路径 (无项目回落 home); unattended 关审批 (弹卡 = 死锁)
        let cwd = task.projectId.flatMap { pid in projects.first(where: { $0.id == pid })?.path }
        beginTurn(sid: logId, prompt: prompt, ephemeral: true,
                  cwd: cwd, unattended: task.unattended)
        if let c = task.condition, !c.isEmpty {
            fireTurnTask[logId] = task.id   // 等待型: 本回合结束扫 done 标记
        }
        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[idx].lastRunAt = now
            scheduledTasks[idx].logSessionId = logId
            scheduledTasks[idx].runCount += 1   // P3.10: 执行次数
            try? persistence?.upsertScheduled(scheduledTasks[idx])
        }
    }

    /// fire 被跳过时往日志会话追加一条时间线记录 (只落库, 不动 UI 状态——
    /// 跳过发生在别的回合进行中, 不能打断当前会话)。
    /// 日志会话尚未建立则放弃: 纯跳过不值得为它建会话, 任务真正跑起来时自然会建。
    private func recordFireSkip(_ task: ScheduledTask, at now: Date, reason: String) {
        guard let logId = task.logSessionId,
              allConversations.contains(where: { $0.id == logId }) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let note = ChatMessage(role: .user,
                               content: .text("── \(fmt.string(from: now)) 因冲突跳过 (\(reason)) ──"))
        try? persistence?.appendMessageEvent(sessionId: logId, note)
    }

    /// 交接文件路径: 项目任务 → <项目>/.mangox/tasks/<taskId>.md (进文件树/可 @ 引用);
    /// 无项目任务 → ~/.mangox/task-memory/<taskId>.md。
    func handoffPath(for task: ScheduledTask) -> String {
        let dir: String
        if let pid = task.projectId, let p = projects.first(where: { $0.id == pid })?.path {
            dir = p + "/.mangox/tasks"
        } else {
            dir = NSHomeDirectory() + "/.mangox/task-memory"
        }
        return dir + "/\(task.id.uuidString).md"
    }

    /// 读交接文件 (磁盘为准, 零缓存)。返回 nil = 文件不存在。
    func readHandoff(for task: ScheduledTask) -> (content: String, updatedAt: Date?)? {
        let path = handoffPath(for: task)
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return (content, attr[.modificationDate] as? Date)
    }

    /// 写交接文件 (编辑器保存 / 兜底重建共用)。
    @discardableResult
    func saveHandoff(for task: ScheduledTask, content: String) -> Bool {
        let path = handoffPath(for: task)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try? content.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// P3.10 等待型 prompt: 两分支协议 (未成立→一句观察轻检查; 成立→查防重复记录→执行动作→done 标记)。
    /// 轻检查轮不注入近期摘录 (token 经济); 交接文件保持极短且必注入 (含"已触发"防重复记录)。
    private func buildWaitingPrompt(_ task: ScheduledTask, condition: String) -> String {
        var sections: [String] = []
        sections.append("""
        【等待任务 · 本轮检查】
        触发条件: \(condition)
        要求: 用工具实际核实当前状态, 不要凭此前记忆推断; 不确定是否成立时按"未成立"处理。
        - 若条件未成立: 只用一句话报告观察结果 (如"截至当前尚未…"), 不要执行任何其他动作。
        - 若条件成立: 先读下方交接文件确认此前未触发过, 然后执行【触发后动作】, 完成后在回复最后单独一行输出: \(Self.doneMarker)
        """)
        var handoff = readHandoff(for: task)?.content
        if (handoff ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let rebuilt = rebuildHandoff(from: task.logSessionId) {
                saveHandoff(for: task, content: rebuilt)
                handoff = rebuilt
            }
        }
        if let h = handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            sections.append("【交接文件】\n\(h)")
        }
        sections.append("【触发后动作】\n\(task.prompt)")
        return sections.joined(separator: "\n\n")
    }

    /// 持续模式 prompt 组装 (P3.9): 交接文件全文 (长期记忆) + 近期运行摘录 (短期上下文)
    /// + 本次指令 + 写回指令。文件丢失时从日志会话 (run-log) 静默重建。
    /// 等待型 (condition 非空) 走等待协议; 普通 prompt 原样返回。
    private func buildScheduledPrompt(_ task: ScheduledTask) -> String {
        if let c = task.condition, !c.isEmpty {
            return buildWaitingPrompt(task, condition: c)
        }
        guard task.continuous else { return task.prompt }
        var sections: [String] = []
        // 长期记忆: 交接文件; 丢失且有日志 → 从 run-log 静默重建
        var handoff = readHandoff(for: task)?.content
        if (handoff ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let rebuilt = rebuildHandoff(from: task.logSessionId) {
                saveHandoff(for: task, content: rebuilt)
                handoff = rebuilt
            }
        }
        if let h = handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            sections.append("【持续任务 · 工作日志】\n\(h)")
        }
        // 短期上下文: 最近一次运行的产出原文 (取最后一条 assistant text, 截取上限)
        if let logId = task.logSessionId {
            let tail = replayMessages(for: logId).compactMap { msg -> String? in
                guard case .text(let s) = msg.content, !s.isEmpty,
                      msg.role == .assistant else { return nil }
                return s
            }.last
            if var t = tail {
                if t.count > Tune.scheduleHistoryCharLimit {
                    t = "…(更早的已省略)\n" + t.suffix(Tune.scheduleHistoryCharLimit)
                }
                sections.append("【近期运行摘录】\n\(t)")
            }
        }
        sections.append("【本次指令】\n\(task.prompt)")
        return sections.joined(separator: "\n\n") +
            "\n\n请在了解此前执行情况的基础上继续本次任务, 并在结束后把关键进展、当前状态与待办更新写入交接文件: \(handoffPath(for: task))"
    }

    /// run-log 兜底: 从日志会话的 text 消息重建交接文件内容 (过滤分隔标记, 截取上限)。
    /// 指令侧只取【本次指令】段 (历史注入模板不入档, 防层级滚雪球)。
    private func rebuildHandoff(from logId: UUID?) -> String? {
        guard let logId else { return nil }
        let lines = replayMessages(for: logId).compactMap { msg -> String? in
            guard case .text(let s) = msg.content, !s.isEmpty,
                  !s.hasPrefix("──") else { return nil }   // 过滤运行分隔
            if msg.role == .user {
                if let r = s.range(of: "【本次指令】\n") {
                    return "[指令] " + s[r.upperBound...]
                }
                return nil   // 注入模板全文不入档
            }
            return "[产出] \(s)"
        }
        guard !lines.isEmpty else { return nil }
        var record = lines.joined(separator: "\n")
        if record.count > Tune.scheduleHistoryCharLimit * 2 {
            record = "…(更早的已省略)\n" + record.suffix(Tune.scheduleHistoryCharLimit * 2)
        }
        return record
    }

    // MARK: - Tool approval (转发给 transport)

    /// Commands the user chose to always allow (persisted only for this run).
    @Published var alwaysAllowedToolIds: Set<UUID> = []

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
    }

    private func currentToolCard(_ toolId: UUID) -> ToolCall? {
        for msg in messages {
            if case .tool(let t) = msg.content, t.id == toolId { return t }
        }
        return nil
    }

    /// P3.10: 侧栏任务日志会话标志 (定时任务 clock / 哨兵任务雷达)
    func scheduledBadge(for sessionId: UUID) -> String? {
        for t in scheduledTasks where t.logSessionId == sessionId {
            return (t.condition?.isEmpty == false)
                ? "dot.radiowaves.left.and.right"
                : "clock.badge"
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
            break   // runningTurns 在 beginTurn 即插入 (这里仅确认, 不重复维护)

        case .textChunk(let id, let delta):
            if inView {
                upsertStreaming(in: &messages, id: id, delta: delta, think: false)
            } else {
                upsertStreaming(in: &liveTurns[sid, default: []], id: id, delta: delta, think: false)
            }

        case .thoughtChunk(let id, let delta):
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

        case .messageFinalized(let id):
            if inView {
                finalizeBlock(in: &messages, id: id, sid: sid)
            } else {
                finalizeBlock(in: &liveTurns[sid, default: []], id: id, sid: sid)
            }

        case .toolPhaseChanged(let toolId, let phase):
            if inView {
                setToolPhase(toolId, phase)
            } else {
                setToolPhaseIn(&liveTurns[sid, default: []], toolId, phase)
            }
            try? persistence?.appendToolUpdateEvent(sessionId: sid, toolId: toolId, phase: phase)

        case .streamEnded:
            runningTurns.remove(sid)
            if inView {
                // 安全网: 收尾视图内所有在途流式块 (text + think 可能同时各有一条)
                for i in messages.indices where messages[i].isStreaming {
                    messages[i].isStreaming = false
                }
            }
            // P4.1/P4.2: 回合完成 —— 前台闪显迷你条完成卡 / 非前台发系统通知。
            // elapsed 取自 turnStartAt 且只能取一次 (手动停过的回合已被清 → 不通知)。
            let elapsed = turnStartAt.removeValue(forKey: sid).map { Date().timeIntervalSince($0) }
            if let elapsed, elapsed >= 1 {
                // 回复预览须在镜像清除前取
                let proj = sid == selectedConversationId ? messages : (liveTurns[sid] ?? [])
                let title = allConversations.first { $0.id == sid }?.title ?? "任务"
                let mins = Int(elapsed) / 60, secs = Int(elapsed) % 60
                if appIsForeground {
                    // P4.2: mini 台完成闪显数据 (显示 5s 后自清, mini 窗口保持不自动还原)
                    lastCompleted = (sid, title, String(format: "✓ 完成 · 耗时 %02d:%02d", mins, secs))
                    lastCompletedTask?.cancel()
                    lastCompletedTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if !Task.isCancelled { lastCompleted = nil }
                    }
                } else if completionNotificationsEnabled {
                    notifyCompletion(sid: sid, title: title, elapsed: elapsed, projection: proj)
                }
            }
            liveTurns[sid] = nil   // 产出已落库, 镜像即弃 (库为准)
            if injectedTurnSid == sid { injectedTurnSid = nil }
            finishWaitingFireIfNeeded(sid: sid)
        }
    }

    /// App 是否前台激活 (CLI/冒烟无 NSApplication 实例 → 视为非前台, 通知 no-op)。
    private var appIsForeground: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return NSApp.isActive
    }

    /// P4.1: 组装完成通知 (标题 = 会话/任务名, 正文 = 耗时 + 回复首行 60 字)。
    private func notifyCompletion(sid: UUID, title: String, elapsed: TimeInterval,
                                  projection: [ChatMessage]) {
        let preview = projection.reversed().compactMap { msg -> String? in
            guard msg.role == .assistant, case .text(let s) = msg.content, !s.isEmpty else { return nil }
            return s
        }.first.map { line -> String in
            let first = line.split(separator: "\n").first.map(String.init) ?? line
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        } ?? ""
        let mins = Int(elapsed) / 60, secs = Int(elapsed) % 60
        let body = preview.isEmpty
            ? String(format: "回合完成 · 耗时 %02d:%02d", mins, secs)
            : String(format: "回合完成 · 耗时 %02d:%02d\n%@", mins, secs, preview)
        Task { await CompletionNotifier.shared.post(sessionId: sid, title: title, body: body) }
    }

    // MARK: - P4.2 迷你条数据投影

    /// 迷你条 L1: 会话名 / 任务名。
    func turnTitle(_ sid: UUID) -> String {
        allConversations.first { $0.id == sid }?.title ?? "任务"
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
                return "思考中…"
            }
        }
        return "运行中…"
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

    /// 流式块收尾: 摘光标 + done 标记剥离 (fire 回合扫描) + 落库。
    /// 仅在 streaming→false 的翻转沿落库 (防 stopStreaming 兜底与事件收尾双写)。
    private func finalizeBlock(in list: inout [ChatMessage], id: UUID, sid: UUID) {
        guard let idx = list.lastIndex(where: { $0.id == id }) else { return }
        let wasStreaming = list[idx].isStreaming
        list[idx].isStreaming = false
        if case .text(let s) = list[idx].content, s.contains(Self.doneMarker) {
            list[idx].content = .text(stripDoneMarker(s, sid: sid))
        }
        if wasStreaming { persistMessage(list[idx], sid: sid) }
    }

    /// 剥离任务状态标记 (doneMarker); 命中且该会话有在途 fire → 点亮 fireDoneHit。
    private func stripDoneMarker(_ s: String, sid: UUID) -> String {
        guard s.contains(Self.doneMarker) else { return s }
        if fireTurnTask[sid] != nil { fireDoneHit.insert(sid) }
        return s.replacingOccurrences(of: Self.doneMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// P3.10/P4.0.2: 等待型 fire 收尾——done 命中则自动停用任务。
    /// 审批策略无需恢复: 池化后策略按回合下发 (unattended fire 只影响自己的实例配置)。
    private func finishWaitingFireIfNeeded(sid: UUID) {
        guard let tid = fireTurnTask.removeValue(forKey: sid) else { return }
        let hit = fireDoneHit.contains(sid)
        fireDoneHit.remove(sid)
        guard hit,
              let idx = scheduledTasks.firstIndex(where: { $0.id == tid }) else { return }
        scheduledTasks[idx].enabled = false
        scheduledTasks[idx].completedAt = Date()
        try? persistence?.upsertScheduled(scheduledTasks[idx])
    }

    // MARK: - P3.5: 能力上报归并

    /// 能力上报只接受探测实例 (池实例 spawn 也会上报 get_state, 不覆盖全局状态)。
    /// 上报值仅作首次初始化 (字段为空时): 探测实例 spawn 不带 --model, 报的是 pi 的
    /// settings.json 默认——若持续回写, 会把用户刚选的模型打回默认 (已实证)。
    func transport(_ transport: any AgentTransport,
                   didUpdateModelState provider: String, modelId: String, thinkingLevel: String) {
        guard transport === capabilityProbe else { return }
        if currentProvider.isEmpty { currentProvider = provider }
        if currentModelId.isEmpty { currentModelId = modelId }
        status.modelName = "\(currentProvider)/\(currentModelId)"
        if let level = ThinkingLevel(rawValue: thinkingLevel), !userThinkingLevelPinned {
            self.thinkingLevel = level
            status.effort = ReasoningEffort(rawValue: thinkingLevel) ?? status.effort
        }
    }

    func transport(_ transport: any AgentTransport, didReportModels: [AgentModelInfo]) {
        guard transport === capabilityProbe else { return }
        availableModels = didReportModels
    }
}
