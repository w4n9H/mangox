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

    private let transport: any AgentTransport
    /// P3.1: SQLite 持久化; 打不开时降级为纯内存 (原 mock 行为)。
    private let persistence: PersistenceStore?

    // Chat
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
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
    /// Codex "Ask for approval": on = 工具调用走人工审批流。
    @Published var askApproval: Bool = true {
        didSet { transport.updateApprovalPolicy(askApproval: askApproval) }
    }

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
    // P3.10: 等待型任务 fire 的回合追踪 (done 标记扫描 + 自动停用)
    private var bashWhitelist: Set<String> = []
    private var waitingFireTaskId: UUID?
    private var waitingFireDone = false
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
        // 下发 spawn 加载列表 (托管区启用项)
        let enabled = items.filter { $0.source == .managed && $0.enabled }.map(\.path)
        transport.updateExtensions(enabled)
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
        if showExtensionsPanel { scanExtensions() }
    }

    // Layout
    @Published var sidebarCollapsed: Bool = false

    init(transport: (any AgentTransport)? = nil, dbPath: String? = nil,
         managedExtensionsDir: String? = nil) {
        // 默认参数表达式是非隔离上下文, transport 的创建放进来。
        // P3.2: 检测到 pi 二进制 → 真引擎; 缺失时 Release 下不再静默降级 Mock
        // (假数据演戏是发布事故), 置 engineMissing 由 UI 报错; DEBUG 保留 mock 回归基线。
        #if DEBUG
        let fallback: any AgentTransport = PiRpcTransport.available() ? PiRpcTransport() : MockTransport()
        #else
        let fallback: any AgentTransport = PiRpcTransport()
        #endif
        let transport = transport ?? fallback
        self.transport = transport
        engineMissing = transport is PiRpcTransport && !PiRpcTransport.available()
        // 无默认值的 let 需最先初始化 (两阶段: 赋值前不可访问 self)
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
        transport.delegate = self
        transport.updateApprovalPolicy(askApproval: askApproval)
        if let store {
            bashWhitelist = store.loadBashWhitelist()   // P3.10: 学习白名单恢复
            disabledExtensionPaths = store.loadDisabledExtensions()   // P3.11: 扩展启停恢复
        }
        transport.updateBashWhitelist(bashWhitelist)
        scanExtensions()   // P3.11: 扫描 + 向 transport 下发托管扩展加载列表
        syncWorkspaceContext()   // 文件树扫描 + pi cwd 绑定 (P3.4)
        // P3.7: 注入块必须在 refreshCapabilities 之前下发 (spawn args 在拉起时定格)
        transport.updateKnowledgeContext(buildKnowledgeBlock())
        transport.refreshCapabilities()   // P3.5: 模型/effort 上报 (pi 拉起 + get_state/models)
        startScheduler()   // P3.6: 每秒 tick, 分钟对齐检查到期任务

        // WAL 落盘 + 杀在途 pi: 强杀/exit 不跑 deinit, 数据滞留 -wal 会在下次清库时全丢;
        // 在途回合的 pi 若不终止会变孤儿进程继续烧 LLM token
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPersistence()
                self?.transport.shutdown()
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
        bindTranscript(to: item.id)   // 新会话 = 空白 transcript
        showKnowledgePanel = false   // 从面板发起新会话 → 回会话视图
        showScheduledPanel = false
        showExtensionsPanel = false
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
        if selectedConversationId == id { stopStreaming() } // 删当前会话先终止在途流
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
                bindTranscript(to: first.id)   // 选中顺延 = 换会话 → 重置 transcript
                messages = replayMessages(for: first.id)
                markLastSession()
            } else {
                selectedConversationId = nil
                bindTranscript(to: nil)
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

    /// 重扫文件树 + 把 cwd 同步给 transport (cwd 变化在下次 send 时重启 pi 生效)。
    private func syncWorkspaceContext() {
        if let root = activeProjectPath {
            fileTree = WorkspaceScanner.scanShallow(root: root)   // lazy: 只扫一层, 展开时按需加载
        } else {
            fileTree = []
        }
        transport.updateWorkingDirectory(activeProjectPath)
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
        bindTranscript(to: item.id)   // 新会话 = 空白 transcript
        messages = []
        showKnowledgePanel = false
        showExtensionsPanel = false
        showScheduledPanel = false
        markLastSession()
        syncWorkspaceContext()
    }

    /// 删除项目 (侧栏 "..." → 二次确认后调用): 连带其下所有会话与消息。
    func deleteProject(_ id: UUID) {
        guard let g = projects.firstIndex(where: { $0.id == id }) else { return }
        let removed = projects.remove(at: g)
        try? persistence?.deleteProject(id: id)
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

    /// pi transcript 当前绑定的 UI 会话 (per-turn 架构)。
    /// 每回合一个 pi 进程, 结束即退; 绑定决定下回合 spawn 参数——
    /// 非 nil: --session 文件 (pi 自动持久化 + 恢复, 重启引擎/App 重启不失忆);
    /// nil: --no-session ephemeral (任务 fire 轮次, 连续性只靠交接文件——P3.9 拍板)。
    private var transcriptSessionId: UUID?

    /// 会话边界绑定: 目标变化时更新 transport 的 spawn 参数 (幂等, 不触发进程操作)。
    private func bindTranscript(to id: UUID?) {
        guard transcriptSessionId != id else { return }
        transport.updateSessionBinding(id)
        transcriptSessionId = id
    }

    func selectConversation(_ id: UUID?) {
        let previous = selectedConversationId
        selectedConversationId = id
        showKnowledgePanel = false   // 点选会话 → 回会话视图
        showScheduledPanel = false
        showExtensionsPanel = false
        if id != previous { bindTranscript(to: id) }   // 换会话 → 重置 pi 对话记忆
        guard let id else { return }
        messages = replayMessages(for: id)
        markLastSession()
        syncWorkspaceContext()   // 选中会话变化 → 工作区上下文跟随 (P3.4)
    }

    // MARK: - Send (只做入参整理, 生成逻辑在 transport)

    func sendDraft(ephemeral: Bool = false) {
        guard !isStreaming else { return } // 防止流式中重复触发双流竞争
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 引擎缺失: 不发请求, 本地给一条说明 (engineMissing 横幅常驻在聊天顶部)
        if engineMissing {
            messages.append(ChatMessage(role: .assistant,
                                        content: .text("⚠️ 未找到 pi CLI, 无法发送。请确认已安装 pi 并重启 MangoX (或检查 pi 安装路径)。")))
            return
        }
        ensureConversationForSend() // 无选中会话时隐式建会话, 消息才有归属
        // 任务 fire 轮次保持 ephemeral (交接文件注入模板不得滚进持久 transcript)
        if !ephemeral {
            bindTranscript(to: selectedConversationId)   // 首轮发送前确保绑定持久 session (幂等)
        }
        let msg = ChatMessage(role: .user, content: .text(trimmed))
        messages.append(msg)
        draft = ""
        persistMessage(msg)
        // P3.4: 发送前把当前项目工作目录下发给 transport (cwd 变化会触发 pi 重启)
        transport.updateWorkingDirectory(activeProjectPath)
        transport.send(prompt: trimmed)
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

    private func persistMessage(_ m: ChatMessage) {
        guard let sid = selectedConversationId else { return }
        try? persistence?.appendMessageEvent(sessionId: sid, m)
    }

    func stopStreaming() {
        transport.cancel()
        isStreaming = false
        // 收尾在途流式消息, 否则光标永远挂在半截回复上
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
            persistMessage(messages[idx]) // 半截回复也落库
        }
    }

    /// 重新生成: 截断最后一条 user 消息之后的内容并重放流式回复。
    func regenerate() {
        guard !isStreaming else { return }
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        if messages.count > lastUserIdx + 1 {
            messages.removeSubrange((lastUserIdx + 1)...)
        }
        guard case .text(let prompt) = messages[lastUserIdx].content else { return }
        transport.send(prompt: prompt)
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

    /// 选中组合: set_model + set_thinking_level (pi 侧各自动回读 get_state 同步 UI)。
    func selectModel(_ model: AgentModelInfo, level: ThinkingLevel?) {
        transport.setModel(provider: model.provider, modelId: model.id)
        if let level { transport.setThinkingLevel(level.rawValue) }
    }

    // MARK: - Knowledge (P3.7 知识库/记忆, 设计见 docs §3.7)

    /// 当前生效条数 (启用 + 全局/当前 project)——Composer pill 显示用。
    var activeKnowledgeCount: Int {
        let pid = activeProject?.id
        return knowledgeItems.filter { item in
            guard item.enabled else { return false }
            return item.scope == .global || item.projectId == pid
        }.count
    }

    /// 组装注入块: 全局 + 当前 project 的启用条目, 带 token 预算 (单条截断/总量丢弃)。
    /// nil = 无可注入内容。
    func buildKnowledgeBlock() -> String? {
        let pid = activeProject?.id
        let enabled = knowledgeItems.filter { item in
            guard item.enabled else { return false }
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

    /// 知识变动后: 重算注入块下发给 transport + 标记引擎待重启。
    private func applyKnowledgeChange() {
        transport.updateKnowledgeContext(buildKnowledgeBlock())
        knowledgeDirty = true
    }

    /// Composer pill "重启引擎生效": 重启 pi 使最新注入块生效 (丢进程内对话记忆, 用户显式触发)。
    func restartEngine() {
        transport.restartEngine()
        knowledgeDirty = false
        extensionsDirty = false
    }

    /// 面板互斥: 打开一个关另一个 (主区同一时刻只显示一个面板)。
    func toggleKnowledgePanel() {
        showKnowledgePanel.toggle()
        if showKnowledgePanel { showScheduledPanel = false }
    }

    // MARK: - Scheduled (P3.6 本地定时任务)

    func toggleScheduledPanel() {
        showScheduledPanel.toggle()
        if showScheduledPanel { showKnowledgePanel = false }
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

    /// 到点投递 (P3.9 单日志会话): 任务的全部运行追加进同一个日志会话 (首次 fire 建立),
    /// 每次运行先插入"── HH:mm 运行 ──"分隔, 再走 sendDraft 完整链路。
    /// 在途生成时跳过本轮 (cron 到期不重排)。
    /// 持续模式 (continuous): 注入交接文件 (工作日志, agent 写用户可改) + 近期运行摘录,
    /// 并指令 agent 把关键进展写回交接文件——连续性靠文件携带, 磁盘为准零缓存。
    func runScheduledFire(_ task: ScheduledTask, at now: Date = Date()) {
        guard !isStreaming else {
            recordFireSkip(task, at: now, reason: "有回合在途")
            return
        }
        if let pid = task.projectId {
            guard projects.contains(where: { $0.id == pid }) else {
                recordFireSkip(task, at: now, reason: "项目已删除")
                return
            }
        }
        // fire 是独立轮次: 连续性靠交接文件注入 (P3.9 拍板), 不依赖 pi transcript——
        // 绑定 ephemeral (--no-session), 每轮空白起点, 防与其他会话/上一轮残留互相污染。
        bindTranscript(to: nil)
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
                selectedProjectId = pid
            } else {
                chats.insert(item, at: 0)
                try? persistence?.insertChatSession(item)
                selectedProjectId = nil   // cwd 回落 home
            }
            logId = item.id
        }
        selectedConversationId = logId
        messages = replayMessages(for: logId!)   // 日志会话全文上屏 (追加式时间线)
        showKnowledgePanel = false
        showExtensionsPanel = false
        showScheduledPanel = false
        markLastSession()
        syncWorkspaceContext()
        // P3.10: 无人值守任务 fire 回合关闭审批 (全 YOLO; streamEnded 恢复)。
        // 无人值守下弹审批 = 卡片永远挂着 = 任务死锁, 开关即接受。
        if task.unattended { transport.updateApprovalPolicy(askApproval: false) }
        if let c = task.condition, !c.isEmpty {
            waitingFireTaskId = task.id   // 等待型: 本回合结束扫 done 标记
            waitingFireDone = false
        }
        // 运行分隔标记 (时间线锚点; "──" 前缀用于摘录时过滤)
        let sep = ChatMessage(role: .user, content: .text("── \(fmt.string(from: now)) 运行 ──"))
        messages.append(sep)
        persistMessage(sep)
        draft = buildScheduledPrompt(task)
        sendDraft(ephemeral: true)
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
        transport.respondToPermission(toolId: toolId, decision: .allow)
    }

    func denyTool(_ toolId: UUID) {
        transport.respondToPermission(toolId: toolId, decision: .deny)
    }

    func alwaysAllowTool(_ toolId: UUID) {
        // P3.10: bash "始终允许" → 学习各段首 token 到持久白名单 (跨会话生效)
        if let card = currentToolCard(toolId), card.kind == .bash {
            let cmd = card.command ?? card.title
            let tokens = BashRiskEvaluator.learnTokens(command: cmd)
            if !tokens.isEmpty {
                bashWhitelist.formUnion(tokens)
                persistence?.saveBashWhitelist(bashWhitelist)
                transport.updateBashWhitelist(bashWhitelist)
            }
        }
        alwaysAllowedToolIds.insert(toolId)
        transport.respondToPermission(toolId: toolId, decision: .alwaysAllow)
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
    func transport(_ transport: any AgentTransport, didEmit event: AgentEvent) {
        switch event {
        case .streamStarted:
            isStreaming = true

        case .textChunk(let id, let delta):
            if let idx = messages.lastIndex(where: { $0.id == id }) {
                guard case .text(let existing) = messages[idx].content else { return }
                messages[idx].content = .text(existing + delta)
                messages[idx].isStreaming = isStreaming   // 流式态跟随全局, 回合外的迟到块不再点亮光标
            } else {
                messages.append(ChatMessage(id: id, role: .assistant,
                                            content: .text(delta), isStreaming: isStreaming))
            }

        case .thoughtChunk(let id, let delta):
            if let idx = messages.lastIndex(where: { $0.id == id }) {
                guard case .think(let existing) = messages[idx].content else { return }
                messages[idx].content = .think(existing + delta)
                messages[idx].isStreaming = isStreaming
            } else {
                messages.append(ChatMessage(id: id, role: .assistant,
                                            content: .think(delta), isStreaming: isStreaming))
            }

        case .toolUpdated(let tool):
            if let idx = messages.lastIndex(where: {
                if case .tool(let t) = $0.content { return t.id == tool.id }
                return false
            }) {
                messages[idx].content = .tool(tool)
                // 终态落库 (trajectory 只存终态事件)
                if case .done = tool.phase { persistMessage(messages[idx]) }
                if case .error = tool.phase { persistMessage(messages[idx]) }
            } else {
                let msg = ChatMessage(role: .assistant, content: .tool(tool))
                messages.append(msg)
            }

        case .messageFinalized(let id):
            if let idx = messages.lastIndex(where: { $0.id == id }) {
                messages[idx].isStreaming = false
                // P3.10: 剥离任务状态标记 (HTML 注释不应呈现/落库), 剥离前记录供回合扫描
                if case .text(let s) = messages[idx].content, s.contains(Self.doneMarker) {
                    if waitingFireTaskId != nil { waitingFireDone = true }
                    let cleaned = s.replacingOccurrences(of: Self.doneMarker, with: "")
                                   .trimmingCharacters(in: .whitespacesAndNewlines)
                    messages[idx].content = .text(cleaned)
                }
                persistMessage(messages[idx])
            }

        case .toolPhaseChanged(let toolId, let phase):
            setToolPhase(toolId, phase)
            if let sid = selectedConversationId {
                try? persistence?.appendToolUpdateEvent(sessionId: sid, toolId: toolId, phase: phase)
            }

        case .streamEnded:
            isStreaming = false
            // 安全网: 收尾所有在途流式块 (text + think 可能同时各有一条)
            for i in messages.indices where messages[i].isStreaming {
                messages[i].isStreaming = false
            }
            finishWaitingFireIfNeeded()
        }
    }

    /// P3.10: 等待型回合收尾——恢复审批策略 + done 标记命中则自动停用任务。
    private func finishWaitingFireIfNeeded() {
        // 无条件恢复审批策略 (无人值守 fire 回合关闭过; 用户会话的 askApproval 保持不变)
        transport.updateApprovalPolicy(askApproval: askApproval)
        guard let tid = waitingFireTaskId else { return }
        waitingFireTaskId = nil
        guard waitingFireDone,
              let idx = scheduledTasks.firstIndex(where: { $0.id == tid }) else { return }
        scheduledTasks[idx].enabled = false
        scheduledTasks[idx].completedAt = Date()
        try? persistence?.upsertScheduled(scheduledTasks[idx])
    }

    // MARK: - P3.5: 能力上报归并

    func transport(_ transport: any AgentTransport,
                   didUpdateModelState provider: String, modelId: String, thinkingLevel: String) {
        currentProvider = provider
        currentModelId = modelId
        status.modelName = "\(provider)/\(modelId)"
        if let level = ThinkingLevel(rawValue: thinkingLevel) {
            self.thinkingLevel = level
            status.effort = ReasoningEffort(rawValue: thinkingLevel) ?? status.effort
        }
    }

    func transport(_ transport: any AgentTransport, didReportModels: [AgentModelInfo]) {
        availableModels = didReportModels
    }
}
