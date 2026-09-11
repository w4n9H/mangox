//
//  SidebarView.swift
//  Codex-style rail: brand · nav items · nested projects · flat chats · footer.
//

import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject private var appearance = AppearanceModel.shared
    @State private var expandedProjects: Set<UUID> = []
    // 删除会话二次确认 (两种粒度: 仅 db / db+pi 记忆文件)
    @State private var confirmDeleteTarget: ConversationItem?

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
            expandedProjects = Set(store.projects.map(\.id))
        }
    }

    // MARK: - Brand header (主题切换; 侧栏开关在顶栏)

    private var brandHeader: some View {
        HStack(spacing: 8) {
            Text("MangoX")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer()
            Button(action: { appearance.toggle() }) {
                Text(appearance.current)
                    .font(CodexFonts.monoFont(10, weight: .medium))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CodexTheme.bgElevated)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(appearance.current == "dark" ? "Switch to light" : "Switch to dark")
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
                   active: store.showKnowledgePanel,
                   badge: store.pendingKnowledge.count) {
                store.toggleKnowledgePanel()
            }
            navRow(icon: "clock.badge", title: "Scheduled",
                   active: store.showScheduledPanel) {
                store.toggleScheduledPanel()
            }
            // P3.11: 插件管理 (pi 扩展托管/启停/导入)
            navRow(icon: "puzzlepiece", title: "Plugins",
                   active: store.showExtensionsPanel) {
                store.toggleExtensionsPanel()
            }
            // P4.0.4: 最小设置页 (并发上限; 通知开关随 P4.1)
            navRow(icon: "gearshape", title: "Settings",
                   active: store.showSettingsPanel) {
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

    // MARK: - Projects (嵌套会话)

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("Projects")
            ForEach(store.projects) { group in
                projectRow(group)
                if expandedProjects.contains(group.id) {
                    ForEach(group.items) { item in
                        sessionRow(item, indent: true)
                    }
                }
            }
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
        alert.messageText = "删除项目「\(group.title)」？"
        alert.informativeText = "该项目下的所有会话与消息记录将一并删除, 此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            store.deleteProject(group.id)
        }
    }

    // MARK: - Chats (平铺)

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("Chats")
            ForEach(store.chats) { item in
                sessionRow(item, indent: false)
            }
        }
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

    private func sessionRow(_ item: ConversationItem, indent: Bool) -> some View {
        ConversationRow(item: item,
                        isSelected: item.id == store.selectedConversationId,
                        indent: indent,
                        badge: store.scheduledBadge(for: item.id) ?? "bubble.left",   // 普通会话 = 对话气泡
                        isRunning: store.runningTurns.contains(item.id),   // P4.0.2: 并发在途各自转圈
                        onSelect: { store.selectConversation(item.id) },
                        onRename: { store.renameConversation(item.id, to: $0) },
                        onDelete: { confirmDeleteTarget = item })
    }
}

// MARK: - Conversation row

struct ConversationRow: View {
    let item: ConversationItem
    let isSelected: Bool
    var indent: Bool = false
    /// P3.10: 定时/哨兵任务的日志会话标志 (SF Symbol 名; nil = 普通会话)
    var badge: String? = nil
    /// 会话回合运行中 → 绿色脉冲圈
    var isRunning: Bool = false
    var onSelect: () -> Void
    var onRename: (String) -> Void
    var onDelete: () -> Void
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

            if isRunning {
                // 运行指示 (行尾): 经典旋转弧 (TimelineView 逐帧驱动, 0.8s/圈, 同隐式动画教训)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let angle = Angle.degrees(t.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360)
                    ZStack {
                        Circle()
                            .stroke(CodexTheme.textMuted.opacity(0.22), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(CodexTheme.toolDone,
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(angle)
                    }
                    .frame(width: 12, height: 12)
                }
                .help("Agent 正在运行…")
            }

            if hovering && !isEditing {
                HStack(spacing: 2) {
                    Button(action: startRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(CodexTheme.textTertiary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("重命名")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundStyle(CodexTheme.textTertiary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("删除会话")
                }
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
