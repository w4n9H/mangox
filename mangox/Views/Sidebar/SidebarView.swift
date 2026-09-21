//
//  SidebarView.swift
//  Codex-style rail: brand · nav items · nested projects · flat chats · footer.
//

import SwiftUI

struct SidebarView: View {
    /// P9.1e (#8): 仅动作入口, 不订阅 ChatStore —— 流式每 chunk 的 messages 变更不再重算侧栏。
    let store: ChatStore
    /// 数据源 = chats/projects 投影 (订阅域状态, 不含流式热路径)。
    @StateObject private var model: SidebarModel
    @State private var expandedProjects: Set<UUID> = []
    // 删除会话二次确认 (两种粒度: 仅 db / db+pi 记忆文件)
    @State private var confirmDeleteTarget: ConversationItem?

    init(store: ChatStore) {
        self.store = store
        _model = StateObject(wrappedValue: SidebarModel(store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                brandHeader
                navSection
                projectsSection
                chatsSection
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .background(CodexTheme.bgSidebar)
        .confirmationDialog("删除会话「\(confirmDeleteTarget?.title ?? "")」？",
                            isPresented: Binding(get: { confirmDeleteTarget != nil },
                                                 set: { if !$0 { confirmDeleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("删除会话 (保留 AI 记忆文件)") {
                if let id = confirmDeleteTarget?.id { store.deleteConversation(id, deleteTranscript: false) }
                confirmDeleteTarget = nil
            }
            Button("删除会话和 AI 记忆文件", role: .destructive) {
                if let id = confirmDeleteTarget?.id { store.deleteConversation(id, deleteTranscript: true) }
                confirmDeleteTarget = nil
            }
            Button("取消", role: .cancel) { confirmDeleteTarget = nil }
        } message: {
            Text("AI 记忆文件 = 该会话的对话上下文 (<uuid>.jsonl); 误删不可恢复。")
        }
        .onAppear {
            // 默认展开全部项目
            expandedProjects = Set(model.projects.map(\.id))
        }
    }

    // MARK: - Brand header (主题切换已移入 设置 → 外观, P10.7)

    private var brandHeader: some View {
        HStack(spacing: 8) {
            Text("MangoX")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 全局导航 (Codex: New chat / Plugins / Scheduled)

    private var navSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            navRow(icon: "square.and.pencil", title: "New chat") {
                store.newConversation()
            }
            // P3.7: 原 Plugins 槽位复用为知识库/记忆入口 (nav 保持英文, 与 New chat/Scheduled 一致)
            navRow(icon: "book", title: "Knowledge",
                   active: model.showKnowledgePanel,
                   badge: model.knowledgePendingCount) {
                store.toggleKnowledgePanel()
            }
            navRow(icon: "clock.badge", title: "Scheduled",
                   active: model.showScheduledPanel) {
                store.toggleScheduledPanel()
            }
            // P3.11: 插件管理 (pi 扩展托管/启停/导入)
            navRow(icon: "puzzlepiece", title: "Plugins",
                   active: model.showExtensionsPanel) {
                store.toggleExtensionsPanel()
            }
            // P4.0.4: 最小设置页 (并发上限; 通知开关随 P4.1)
            navRow(icon: "gearshape", title: "Settings",
                   active: model.showSettingsPanel) {
                store.toggleSettingsPanel()
            }
        }
        .padding(.bottom, 6)
    }

    private func navRow(icon: String, title: String,
                        active: Bool = false,
                        badge: Int? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(active ? CodexTheme.accent : CodexTheme.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13,
                                  weight: title == "New chat" || active ? .medium : .regular))
                    .foregroundStyle(active ? CodexTheme.textPrimary : CodexTheme.textPrimary)
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(CodexFonts.monoFont(10, weight: .medium))
                        .foregroundStyle(CodexTheme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(CodexTheme.accentSoft)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Projects (嵌套会话, 行内同带活动徽章)

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("Projects")
            ForEach(model.projects) { group in
                projectRow(group)
                if expandedProjects.contains(group.id) {
                    nestedSessions(group)
                }
            }
        }
    }

    /// 项目下的会话: 缩进 + 一条竖向引导线, 表达"这些会话属于上面那个项目"。
    /// P10.7 之前这里与顶层会话同缩进 (`indent` 被硬编码 false, Tune.sidebarRowIndent 是死代码),
    /// 层级完全读不出来 —— 会话看起来和项目平级。
    private func nestedSessions(_ group: ProjectGroup) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(group.items.sorted { $0.updatedAt > $1.updatedAt }) { item in
                sessionRow(item, indent: true)
            }
        }
        .overlay(alignment: .topLeading) {
            // 只跨子会话区 (不含项目行本身), 上下各留 4pt 让线不贴着相邻行
            Rectangle()
                .fill(CodexTheme.guide)
                .frame(width: 1)
                .padding(.leading, Tune.sidebarGuideInset)
                .padding(.vertical, 4)
        }
    }

    private func projectRow(_ group: ProjectGroup) -> some View {
        let expanded = expandedProjects.contains(group.id)
        return HStack(spacing: 6) {
            // 展开状态三角小标 (Codex 式 disclosure)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(CodexTheme.textMuted)
                .frame(width: 10)
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textSecondary)
                .frame(width: 14)
            Text(group.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CodexTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            // 行操作菜单: 新建会话 / 删除项目 (二次确认)
            Menu {
                Button("新建会话") { store.createSession(in: group.id) }
                Divider()
                Button("删除项目…") { confirmDeleteProject(group) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("项目操作")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, Tune.sidebarProjectRowVPadding)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(CodexTheme.animFast) {
                if expanded {
                    expandedProjects.remove(group.id)
                } else {
                    expandedProjects.insert(group.id)
                }
            }
        }
    }

    /// 删除项目二次确认 (连带其下所有会话, 不可撤销)。
    private func confirmDeleteProject(_ group: ProjectGroup) {
        let alert = NSAlert()
        alert.messageText = String(format: L("删除项目「%@」？"), group.title)
        alert.informativeText = L("该项目下的所有会话与消息记录将一并删除, 此操作不可撤销。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("删除"))
        alert.addButton(withTitle: L("取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.deleteProject(group.id)
        }
    }

    // MARK: - Chats (P8.0: 非项目会话按 今天/昨天/本周/更早 分桶)

    private var chatsSection: some View {
        let sessions = model.chats.sorted { $0.updatedAt > $1.updatedAt }
        let grouped = Dictionary(grouping: sessions) { DayBucket.bucket(for: $0.updatedAt, now: .now) }
        return VStack(alignment: .leading, spacing: 1) {
            sectionHeader("Chats")
            ForEach(DayBucket.allCases, id: \.rawValue) { bucket in
                if let items = grouped[bucket], !items.isEmpty {
                    dayHeader(bucket, count: items.count)
                    ForEach(items) { item in
                        sessionRow(item, indent: false)
                    }
                }
            }
        }
    }

    private func dayHeader(_ bucket: DayBucket, count: Int) -> some View {
        HStack {
            Text(LK(bucket.rawValue))
                .font(.system(size: 10, weight: .medium))
                .tracking(0.5)
            Spacer()
            Text("\(count)")
                .font(CodexTheme.fontTiny)
        }
        .foregroundStyle(CodexTheme.textMuted)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(CodexTheme.textMuted)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    // MARK: - Session row (含重命名/删除)

    /// `indent` 必传 (不给默认值 —— 之前默认值 let 调用点静默省略, 层级就是这么丢的)。
    private func sessionRow(_ item: ConversationItem, indent: Bool) -> some View {
        ConversationRow(item: item,
                        isSelected: item.id == model.selectedConversationId,
                        indent: indent,
                        // P6.3.1: 侧问会话 = fork 徽章; 普通会话 = 定时任务标 or 对话气泡
                        badge: item.sideOf != nil
                            ? "arrow.triangle.branch"
                            : (store.scheduledBadge(for: item.id) ?? "bubble.left"),
                        isRunning: model.runningTurns.contains(item.id),   // P4.0.2: 并发在途各自转圈
                        isBlocked: model.approvalBlocked.contains(item.id), // P8-T26: 待审批琥珀标
                        onSelect: { store.selectConversation(item.id) },
                        onRename: { store.renameConversation(item.id, to: $0) },
                        onDelete: { confirmDeleteTarget = item },
                        canSideChat: store.canStartSideChat(for: item.id),
                        onSideChat: { store.startSideChat(from: item.id) })
    }
}

// MARK: - Conversation row

struct ConversationRow: View {
    let item: ConversationItem
    let isSelected: Bool
    /// 项目下的会话行 = true (缩进到 `Tune.sidebarRowIndent`); 顶层会话行 = false (8)。
    let indent: Bool
    /// P3.10: 定时/哨兵任务的日志会话标志 (SF Symbol 名; nil = 普通会话)
    var badge: String? = nil
    /// 会话回合运行中 → 绿色脉冲圈
    var isRunning: Bool = false
    /// P8-T26: 有工具卡停在待审批 → hand.raised 琥珀标 (与 running 互斥, 阻塞优先)
    var isBlocked: Bool = false
    var onSelect: () -> Void
    var onRename: (String) -> Void
    var onDelete: () -> Void
    /// P6.3.1: "..." 菜单里的侧问入口 (无持久记忆/侧问自身时禁用)
    var canSideChat: Bool = false
    var onSideChat: () -> Void = {}
    @State private var hovering: Bool = false
    @State private var isEditing: Bool = false
    @State private var editTitle: String = ""

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("会话名", text: $editTitle)
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textPrimary)
                    .onSubmit { commitRename() }
                    .onExitCommand { isEditing = false }
            } else {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 9))
                        .foregroundStyle(CodexTheme.textMuted)
                }
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
            }

            Spacer(minLength: 2)

            if isBlocked {
                // P8-T26: 阻塞指示 (优先于运行圈 —— 审批没人点是更紧急的状态)
                Image(systemName: "hand.raised")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexTheme.blocked)
                    .help("等待审批")
            } else if isRunning {
                // 运行指示 (行尾): 经典旋转弧 (P9 实机: 低频 tick + CA 插值, 流式期不掉帧)
                CodexSpinner()
                    .help("Agent 正在运行…")
            }

            if hovering && !isEditing {
                // P6.3.1: 行操作收敛为 "..." 菜单 (改名 / 由此侧问 / 删除) — 原双小标过碎
                Menu {
                    Button("重命名") { startRename() }
                    Button("由此侧问") { onSideChat() }
                        .disabled(!canSideChat)
                    Divider()
                    Button("删除会话…", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CodexTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(item.updatedAt.relativeTag)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
        }
        .padding(.leading, indent ? Tune.sidebarRowIndent : 8)
        .padding(.trailing, 8)
        .padding(.vertical, Tune.sidebarRowVPadding)
        .background(isSelected ? CodexTheme.bgElevated : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if !isEditing { onSelect() }
        }
        .onTapGesture(count: 2) { startRename() }
    }

    private func startRename() {
        editTitle = item.title
        isEditing = true
    }

    private func commitRename() {
        onRename(editTitle)
        isEditing = false
    }
}
