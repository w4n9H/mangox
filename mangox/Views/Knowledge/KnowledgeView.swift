//
//  KnowledgeView.swift
//  P3.7 知识库/记忆管理面板 (主区切换视图)。
//  视觉语言对齐全局: 左列 = Sidebar 行语言 (窄/紧凑/hover 选中), 编辑区 = Composer 输入卡语言
//  (无底框大字标题 + 白卡细描边正文)。注入为 spawn 期 system prompt, 改动后需"重启引擎生效"。
//

import SwiftUI

struct KnowledgeView: View {
    @ObservedObject var store: ChatStore

    // 编辑草稿 (editingId == nil 表示新建)
    @State private var editingId: UUID?
    @State private var draftTitle: String = ""
    @State private var draftContent: String = ""
    @State private var draftScope: KnowledgeScope = .global
    @State private var draftProjectId: UUID?
    @State private var hoveringId: UUID?
    @State private var savedFlash: Bool = false          // 保存成功 → "已保存"短闪
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: Tune.knowledgeListWidth)
                .background(CodexTheme.bgSidebar)
            Divider().overlay(CodexTheme.divider)
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CodexTheme.bgChat)
        }
        .confirmationDialog("删除条目「\(draftTitle)」？",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteEditing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不可恢复; 已注入过会话的知识块不受影响。")
        }
    }

    // MARK: - 列表 (Sidebar 行语言)

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 区头: 与侧栏 "Projects/Chats" 同款 + 右侧新建
            HStack {
                Text("KNOWLEDGE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                Button(action: startNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新建条目")
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(store.knowledgeItems) { item in
                        row(item)
                    }
                    if store.knowledgeItems.isEmpty {
                        Text("暂无条目\n点右上角 + 新建")
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private func row(_ item: KnowledgeItem) -> some View {
        let selected = isEditing(item)
        let hovered = hoveringId == item.id
        return HStack(spacing: 7) {
            Image(systemName: item.source == .session ? "bookmark.fill" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(item.source == .session ? CodexTheme.thinking : CodexTheme.textMuted)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(item.enabled
                                     ? (selected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                                     : CodexTheme.textMuted)
                Text(scopeLabel(item))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            CodexMiniToggle(isOn: Binding(
                get: { item.enabled },
                set: { _ in store.toggleKnowledge(id: item.id) }
            ))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.bgElevated : (hovered ? CodexTheme.bgElevated.opacity(0.5) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? item.id : nil }
        .onTapGesture { loadDraft(item) }
    }

    private func scopeLabel(_ item: KnowledgeItem) -> String {
        var parts: [String] = []
        parts.append(item.scope == .global
                     ? "全局"
                     : store.projects.first { $0.id == item.projectId }?.title ?? "未知项目")
        if item.source == .session { parts.append("记忆") }
        return parts.joined(separator: " · ")
    }

    private func isEditing(_ item: KnowledgeItem) -> Bool { editingId == item.id }

    // MARK: - 编辑器 (Composer 输入卡语言)

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                controlsRow
                titleField
                contentCard
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: Tune.knowledgeEditorMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            CodexSegmented(options: ["全局", "项目"],
                           selection: Binding(
                            get: { draftScope == .global ? 0 : 1 },
                            set: { draftScope = $0 == 0 ? .global : .project }))
            if draftScope == .project {
                projectMenu
            }
            Spacer()
            if editingId != nil {
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("删除")
                    }
                }
                .buttonStyle(CodexActionButtonStyle(kind: .danger))
                .help("删除该条目")
            }
            Button(savedFlash ? "✓ 已保存" : "保存") { saveEditing() }
                .buttonStyle(CodexActionButtonStyle(
                    kind: savedFlash ? .success : .primary,
                    disabled: !draftReady))
                .disabled(!draftReady || savedFlash)
                .help("保存 (⌘S)")
        }
    }

    /// 项目选择胶囊 (Codex pill 语言: Menu 外层挂样式, label 内部只留 contentShape)
    private var projectMenu: some View {
        Menu {
            ForEach(store.projects) { p in
                Button(p.title) { draftProjectId = p.id }
            }
        } label: {
            Text(store.projects.first { $0.id == draftProjectId }?.title ?? "选择项目")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(CodexTheme.bgPill)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
    }

    /// 标题: 无底框大字 (对齐顶栏标题气质)
    private var titleField: some View {
        TextField("标题", text: $draftTitle)
            .textFieldStyle(.plain)
            .font(.system(size: Tune.knowledgeTitleFontSize, weight: .semibold))
            .foregroundStyle(CodexTheme.textPrimary)
    }

    /// 正文: 白卡 + 细描边 (与 Composer 输入卡同语言)
    private var contentCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draftContent)
                .font(CodexTheme.fontBody)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 320)
            if draftContent.isEmpty {
                Text("内容…")
                    .font(CodexTheme.fontBody)
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(.leading, 12)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
        )
    }

    private var draftReady: Bool {
        !draftTitle.trimmingCharacters(in: .whitespaces).isEmpty
        && !draftContent.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 草稿动作

    private func startNew() {
        editingId = nil
        draftTitle = ""
        draftContent = ""
        draftScope = store.activeProject != nil ? .project : .global
        draftProjectId = store.activeProject?.id
    }

    private func loadDraft(_ item: KnowledgeItem) {
        editingId = item.id
        draftTitle = item.title
        draftContent = item.content
        draftScope = item.scope
        draftProjectId = item.projectId
    }

    private func saveEditing() {
        guard draftReady else { return }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingId,
           let existing = store.knowledgeItems.first(where: { $0.id == id }) {
            store.updateKnowledge(existing.withUpdated(
                title: title, content: draftContent, scope: draftScope, projectId: draftProjectId))
        } else {
            store.addKnowledge(title: title, content: draftContent,
                               scope: draftScope, projectId: draftProjectId)
            editingId = store.knowledgeItems.last?.id   // 新建后进入编辑态, 保存键语义延续
        }
        // "✓ 已保存"短闪 (与代码块"已复制"同模式)
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    private func deleteEditing() {
        guard let id = editingId else { return }
        store.deleteKnowledge(id: id)
        editingId = nil
        draftTitle = ""
        draftContent = ""
    }
}
