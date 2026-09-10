//
//  ChatComposer.swift
//  Codex-style composer: project pill · input card · (+ / approval / model / send).
//  Width aligns with the 760pt message column; editor height is driven by
//  content measurement reported back to SwiftUI (external .frame is authoritative).
//

import SwiftUI
import AppKit

struct ChatComposer: View {
    @ObservedObject var store: ChatStore
    /// CompactTextEditor 实测内容高度回调 (SwiftUI 外部 frame 才是权威布局)。
    @State private var editorHeight: CGFloat = Tune.editorMinHeight

    var body: some View {
        VStack(spacing: Tune.composerStackSpacing) {
            projectPill
            inputCard
        }
        .padding(.horizontal, Tune.composerHPadding)
        .padding(.top, Tune.composerTopPadding)
        .padding(.bottom, Tune.composerBottomPadding)
        .frame(maxWidth: Tune.composerMaxWidth)   // 内容宽 + 2×外边距, 与消息列内容宽同源 (Tune.chatContentWidth)
        .frame(maxWidth: .infinity)
        .background(CodexTheme.bgBase)
        .overlay(alignment: .bottom) {
            if let query = mentionQuery {
                MentionPopup(store: store, query: query) { path in
                    insertMention(path)
                }
                .offset(y: Tune.mentionPopupOffset)
            }
        }
    }

    // MARK: - Choose project pill (左对齐, 紧贴输入卡)

    private var currentProjectName: String {
        store.projects.first { $0.id == store.selectedProjectId }?.title ?? Copy.chooseProjectFallback
    }

    private var projectPill: some View {
        Menu {
            Button(Copy.chooseProjectMenu) { store.selectedProjectId = nil }
            Divider()
            Button("新建项目（选择目录）…") { pickNewProjectDirectory() }
            if store.selectedProjectId != nil {
                Button("为「\(currentProjectName)」设置目录…") { pickProjectDirectory(for: store.selectedProjectId!) }
            }
            Divider()
            ForEach(store.projects) { project in
                Button(project.title) { store.selectedProjectId = project.id }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                Text(currentProjectName)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // 通栏浅灰圆角条 (对齐 Codex); 样式必须挂 Menu 外层, label 内部会被菜单样式吞掉
        .padding(.horizontal, Tune.projectPillHPadding)
        .padding(.vertical, Tune.projectPillVPadding)
        .background(CodexTheme.bgCard)   // light F3F3F5 / dark 16161A, 两种主题下都与底色有区分
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radius)
                .stroke(CodexTheme.border.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Input card

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                CompactTextEditor(
                    text: $store.draft,
                    minHeight: Tune.editorMinHeight,
                    maxHeight: Tune.editorMaxHeight,
                    onSubmit: { store.sendDraft() },
                    onHeightChange: { editorHeight = $0 }
                )
                .frame(height: editorHeight)

                if store.draft.isEmpty {
                    Text(Copy.composerPlaceholder)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMono)
                        .padding(.top, 2)
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 4) {
                plusMenu
                approvalToggle
                knowledgePill
                Spacer()
                modelMenu
                sendButton
            }
            .padding(.top, Tune.controlRowTopSpacing)
        }
        .padding(.horizontal, Tune.cardHPadding)
        .padding(.vertical, Tune.cardVPadding)
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)  // Codex 式柔和投影, 卡片在白底上不再隐形
    }

    // MARK: - Bottom-left: + / Ask for approval

    private var plusMenu: some View {
        Menu {
            Button("附加文件…") { pickAttachment() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13))
                .foregroundStyle(CodexTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加附件")
    }

    private var approvalToggle: some View {
        Button(action: { store.askApproval.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: store.askApproval ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 10))
                Text("Ask for approval")
                    .font(CodexTheme.fontSmall)
            }
            // 开关视觉: on = accent 胶囊高亮, off = 素色描边 (无状态区分是 A4"点了没反应"的根因)
            .foregroundStyle(store.askApproval ? CodexTheme.accent : CodexTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(store.askApproval ? CodexTheme.accentSoft : Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
            .frame(height: Tune.pillHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.askApproval ? "审批流开启, 点击关闭" : "审批流关闭, 点击开启")
    }

    // MARK: - 知识注入 pill (P3.7: 生效条数 + 重启引擎入口)

    @ViewBuilder
    private var knowledgePill: some View {
        // 无生效条目不占位 (与 Codex 降噪口径一致)
        if store.activeKnowledgeCount > 0 {
            Menu {
                Button(store.knowledgeDirty ? "重启引擎生效 (知识改动将注入)" : "注入块已是最新") {
                    store.restartEngine()
                }
                .disabled(!store.knowledgeDirty)
            } label: {
                // ⚠️ borderlessButton Menu label 只渲染"首个 Image + 首个 Text", 必须单 Text 拼接
                let dirty: Text = store.knowledgeDirty
                    ? Text(" 待重启").font(CodexTheme.fontTiny).foregroundColor(CodexTheme.thinking)
                    : Text("")
                (Text(Image(systemName: "book"))
                    .font(.system(size: 10)).foregroundColor(CodexTheme.textMuted)
                 + Text(" \(store.activeKnowledgeCount)")
                    .font(CodexTheme.fontSmall).foregroundColor(CodexTheme.textTertiary)
                 + dirty)
                    .frame(height: Tune.pillHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("知识库/记忆: 当前会话注入条数")
        }
    }

    // MARK: - Bottom-right: model picker + send

    private var shortModelName: String {
        store.status.modelName.components(separatedBy: "/").last ?? store.status.modelName
    }

    private var modelMenu: some View {
        Menu {
            // P3.5: 条目 = 每个模型 × 其支持的思考级别 (thinkingLevelMap 过滤, 用户拍板样式
            // "DeepSeek V4 Flash（high）"); 未上报时只显示当前项。
            if store.availableModels.isEmpty {
                Button(shortModelName) {}
            } else {
                ForEach(store.modelMenuEntries) { entry in
                    let title: String = entry.level.map { "\(entry.model.label)（\($0.rawValue)）" }
                        ?? entry.model.label
                    Button(store.isCurrent(entry) ? "✓ " + title : title) {
                        store.selectModel(entry.model, level: entry.level)
                    }
                }
            }
        } label: {
            // ⚠️ borderlessButton Menu 的 label 只渲染"首个 Image + 首个 Text", HStack 多子视图
            // 会被静默丢弃 (级别/chevron 消失, 离屏渲染实测)。必须拼成单个 Text (SF Symbol 可内嵌)。
            (Text(Image(systemName: "bolt.fill"))
                .font(.system(size: Tune.boltIconSize)).foregroundColor(CodexTheme.textMuted)
             + Text(" \(shortModelName)")
                .font(CodexTheme.fontSmall).foregroundColor(CodexTheme.textTertiary)
             + Text(" \(store.thinkingLevel.rawValue)")
                .font(.system(size: Tune.levelFontSize, weight: .semibold)).foregroundColor(CodexTheme.textPrimary)
             + Text(Image(systemName: "chevron.down"))
                .font(.system(size: Tune.chevronIconSize, weight: .semibold)).foregroundColor(CodexTheme.textMuted))
            .frame(height: Tune.pillHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("模型与思考强度 (来自对端上报)")
    }

    @ViewBuilder
    private var sendButton: some View {
        if store.isStreaming {
            Button(action: { store.stopStreaming() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.bgBase)
                    .frame(width: Tune.sendButtonSize, height: Tune.sendButtonSize)
                    .background(CodexTheme.textPrimary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("停止 (⌘.)")
        } else {
            let canSend = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: { store.sendDraft() }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canSend ? CodexTheme.bgBase : CodexTheme.textMuted)
                    .frame(width: Tune.sendButtonSize, height: Tune.sendButtonSize)
                    .background(
                        Group {
                            if canSend {
                                CodexTheme.textPrimary
                            } else {
                                CodexTheme.bgChat
                            }
                        }
                    )
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(canSend ? Color.clear : CodexTheme.border.opacity(0.6),
                                    lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("发送 (Enter)")
        }
    }

    // MARK: - Attach

    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = Copy.attachPanelMessage
        if panel.runModal() == .OK, let url = panel.url {
            store.draft += Copy.attachment(url.path)
        }
    }

    // MARK: - Project directory pickers (P3.4: 工作区真实化的入口)

    private func pickNewProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Copy.newProjectPanelMessage
        if panel.runModal() == .OK, let url = panel.url {
            store.addProject(title: url.lastPathComponent, path: url.path)
        }
    }

    private func pickProjectDirectory(for projectId: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Copy.pickProjectPanelMessage(currentProjectName)
        if panel.runModal() == .OK, let url = panel.url {
            store.setProjectPath(projectId, to: url.path)
        }
    }

    // MARK: - @ file mention

    private var mentionQuery: String? {
        guard store.canUseWorkspace else { return nil }   // 非项目会话无工作区文件可引用
        guard let range = store.draft.range(of: "@[\\w./-]*$", options: .regularExpression)
        else { return nil }
        return String(store.draft[range].dropFirst())
    }

    private func insertMention(_ path: String) {
        if let range = store.draft.range(of: "@[\\w./-]*$", options: .regularExpression) {
            store.draft.replaceSubrange(range, with: "@\(path) ")
        }
    }
}

// MARK: - Mention popup

struct MentionPopup: View {
    let store: ChatStore
    let query: String
    let onPick: (String) -> Void

    private var matches: [(id: UUID, name: String, path: String)] {
        let all = store.flattenedFiles()
        let hit = query.isEmpty
            ? all
            : all.filter { $0.path.localizedCaseInsensitiveContains(query) }
        return Array(hit.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("引用工作区文件")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(matches, id: \.id) { file in
                Button(action: { onPick(file.path) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(CodexTheme.textTertiary)
                        Text(file.name)
                            .font(CodexTheme.fontMonoSm)
                            .foregroundStyle(CodexTheme.textPrimary)
                        Spacer()
                        Text(file.path)
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if matches.isEmpty {
                Text("无匹配文件")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 420)
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radius)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
    }
}

// MARK: - Compact NSTextView-backed editor
// 高度由内容实测后通过 onHeightChange 回调给 SwiftUI, 外部 .frame 是权威布局。

struct CompactTextEditor: NSViewRepresentable {
    @Binding var text: String
    var minHeight: CGFloat = 64
    var maxHeight: CGFloat = 180
    var font: NSFont = NSFont.systemFont(ofSize: 14)
    var onSubmit: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = font
        textView.backgroundColor = .clear
        textView.textColor = NSColor(CodexTheme.textPrimary)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.delegate = context.coordinator

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRange
            textView.string = text
            let len = textView.string.utf16.count
            if selected.location <= len {
                textView.selectedRange = NSRange(location: min(selected.location, len), length: 0)
            }
        }
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            guard let coordinator, let scrollView = coordinator.attachedScrollView else { return }
            coordinator.reportHeight(scrollView: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CompactTextEditor?
        weak var attachedScrollView: NSScrollView?

        init(_ parent: CompactTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let scrollView = textView.enclosingScrollView else { return }
            let newText = textView.string
            DispatchQueue.main.async { [weak self] in
                guard let self, let parent = self.parent else { return }
                parent.text = newText
                self.reportHeight(scrollView: scrollView)
            }
        }

        // Enter 发送 / Shift+Enter 换行; IME 组字中放行
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                if modifiers.contains(.shift) {
                    textView.insertText("\n", replacementRange: textView.selectedRange)
                    return true
                }
                parent?.onSubmit()
                return true
            }
            return false
        }

        func reportHeight(scrollView: NSScrollView) {
            guard let parent,
                  let textView = scrollView.documentView as? NSTextView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let used = textView.layoutManager?.usedRect(for: textView.textContainer!).size ?? .zero
            let h = min(parent.maxHeight,
                        max(parent.minHeight,
                            used.height + textView.textContainerInset.height * 2))
            parent.onHeightChange(h)
        }
    }
}
