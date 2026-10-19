//
//  ChatComposer.swift
//  Codex-style composer: project pill · input card · (+ / approval / model / send).
//  Width aligns with the 760pt message column; editor height is driven by
//  content measurement reported back to SwiftUI (external .frame is authoritative).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatComposer: View {
    @ObservedObject var store: ChatStore
    /// CompactTextEditor 实测内容高度回调 (SwiftUI 外部 frame 才是权威布局)。
    @State private var editorHeight: CGFloat = Tune.editorMinHeight
    /// 输入框焦点态 —— 占位提示据此**在获得焦点时退场** (见 `inputCard` 里的条件)。
    @State private var editorFocused = false
    // P13: 档位 popover 的展开态移进共用件 AgentModePicker, 这里不再需要它

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
        // P10.8c: 输入区**与正文面同面** —— 它本来就是同一张纸的下半部, 不是"另一层"。
        // 上一版让它坐页面底 (bgChat) 当"凹槽", 但这条色带的顶边落在消息列下方的空白处,
        // 成了一道横贯全宽、无任何边界元素的硬边 (boss 2026-09-21 圈出"明显的割裂感")。
        // 现在: 区域 = 正文面; "凹"交给输入卡自己 (bgComposer 比正文面暗一档 + 描边),
        // "浮"交给项目条 (bgCard 比正文面亮) —— 层级全由卡表达, 交界处没有第二种底色。
        .background(CodexTheme.contentPanel)
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
            if !store.pendingImages.isEmpty {
                attachmentChips
                    .padding(.horizontal, Tune.cardHPadding)
                    .padding(.top, 10)
            }
            ZStack(alignment: .topLeading) {
                CompactTextEditor(
                    text: $store.draft,
                    minHeight: Tune.editorMinHeight,
                    maxHeight: Tune.editorMaxHeight,
                    onSubmit: { store.sendDraft() },
                    onHeightChange: { editorHeight = $0 },
                    onImagePaste: { data, ext in store.addPendingImage(data, suggestedExtension: ext) },
                    onFocusChange: { editorFocused = $0 }
                )
                .frame(height: editorHeight)

                // ⚠️ 占位提示**在获得焦点时必须退场** —— 它和系统插入点占同一像素, 只能二选一
                //    (判据与来历见 `PasteInterceptTextView` 上方的长注释)。
                //    这也正是 AppKit 自己的行为: NSTextField 一开始编辑, placeholder 就消失。
                if store.draft.isEmpty && !editorFocused {
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
                modeMenu
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
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusComposer))
        .overlay(
            // P14 第四批: 45% 透明 → 实色 (对齐参考图实测 #E2E2E2; token 本身即 #E3E3E7)。
            // ⚠️ 圆角与这条描边必须用**同一个 token** —— 分开写会让圆角与描边错开。
            RoundedRectangle(cornerRadius: CodexTheme.radiusComposer)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
        // 投影 0.05/5 → 0.12/7 (2026-10-14 review, 带实测读数):
        //   亮色: `bgComposer` **就等于正文面** (`contentPanel`, 两个都是 #FFFFFF) ⇒ 上面那句
        //     "输入卡凹下"在亮色**没有面值可依**, 能读出"这是一张卡"的只剩这条投影。
        //     离屏渲染实测 (ImageRenderer 2x, 描边外最深处): 旧 = #F8F8F8 (灰度差 **7/255**,
        //     1x 下看不见) → 新 = #EEEEEE (**16/255**, 2.3 倍), 晕开到 ~7pt。
        //   暗色: 实测**怎么调都一样** —— 卡面 #1F1F27 本来就在正文面 #23232C **下面**一档,
        //     "凹下"由面值表达, 黑投影压无可压 (0.05/5→0.12/7 的剖面只差 38→37→36 共 1~2 级)。
        //     ⇒ **不必按主题分叉** (试过：那要另开一个动态色 token, 收益为零)。
        // ⚠️ 这条结论的前提是"暗色卡面比正文面暗"。哪天暗色 `bgComposer` 抬到比正文面亮,
        //    投影就成了唯一表达 ⇒ 那时要重新量, 别照抄这句。
        // 不碰另两条路: 描边已是实色 `border` (#E3E3E7, P14 对齐参考图的实测值),
        // 面值 `bgComposer` 有 9 个消费点 (Scheduled / Knowledge / Extensions 都在用)。
        .shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 2)
        .onDrop(of: [UTType.image], isTargeted: nil) { providers in
            // P7-M6b 拖拽入口: 图片落卡 → 附件通道 (文本文件拖拽不接, @语义仍走文本)
            guard !providers.isEmpty else { return false }
            for provider in providers {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let ext = ImagePipeline.sniffExtension(data) ?? "png"
                    Task { @MainActor in store.addPendingImage(data, suggestedExtension: ext) }
                }
            }
            return true
        }
    }

    // MARK: - 附件暂存 chips (P7-M6b: 64pt 缩略 + ×, 随 draft 生命周期)

    private var attachmentChips: some View {
        HStack(spacing: 8) {
            ForEach(store.pendingImages) { p in
                chip(p)
            }
            if store.pendingImages.count >= ImagePipeline.maxPerMessage {
                Text("最多 \(ImagePipeline.maxPerMessage) 张")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.toolError)
            }
            Spacer()
        }
    }

    private func chip(_ p: PendingImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = NSImage(data: p.data) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(CodexTheme.bgSidebar)
                }
            }
            .frame(width: 64, height: 64)
            .clipped()
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))

            Button {
                store.removePendingImage(p.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .background(Circle().fill(CodexTheme.bgBase))
                    .offset(x: 5, y: -5)
            }
            .buttonStyle(.plain)
            .help("移除")
        }
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
                Text("需要审批")
                    .font(CodexTheme.fontSmall)
            }
            // 开关视觉: on = textPrimary (近黑), off = textTertiary (无状态区分是 A4"点了没反应"的根因)
            .foregroundStyle(store.askApproval ? CodexTheme.textPrimary : CodexTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // P14 第四批: 控件退成"裸"的图标 + 文字 —— 无描边、无底色 (对齐参考图)。
            // 状态全靠上方 foregroundStyle 的**文字色**表达 (off = textTertiary / on = textPrimary)。
            // 判据边界: P10.8c「面必须自带边界元素」管的是"面"; 控件不在这个范畴。
            .frame(height: Tune.pillHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LK(store.askApproval ? "审批流开启, 点击关闭" : "审批流关闭, 点击开启"))
    }

    // MARK: - 模式档位 pill (P7-M4 三档; P13 加 codemode 层, per-turn spawn 生效)

    /// 菜单内容抽到共用件 `AgentModeMenu` —— 三处入口从此**同一份** (原来只有这里是自绘
    /// popover, 另两处在原生 Menu 里退化成一个名字, 看不到 codemode 的代价说明)。
    private var modeMenu: some View {
        // ⚠️ help 文本原先写作 `.help("…")` —— 那是**硬编码中文**: `.help(` 恰好在接线扫描的
        //    豁免名单里, 所以它一直"绿"着却有译文没人用 (隐形漏译)。现在它成了普通实参,
        //    扫描器看得见了 ⇒ 必须真接 `L()`。
        AgentModePicker(mode: $store.agentMode,
                        help: L("模式档位: 决定 agent 可用的工具与扩展 (下回合生效)")) {
            (Text(Image(systemName: "slider.horizontal.3"))
                .font(.system(size: 10)).foregroundColor(store.agentMode == .standard ? CodexTheme.textTertiary : CodexTheme.textPrimary)
             // ⚠️ 别写成 `Text(" \(…)")` —— 那是 `LocalizedStringKey` **带插值**, SwiftUI 会拿
             //    `" %@"` 去查表（查不到就回落, 看起来正常, 但词表里永远查不出这条"幽灵键"）。
             //    拼接进来的本就是已本地化的字符串, 所以这里用 `verbatim:` 明确"不要再查表"。
             + Text(verbatim: " " + store.agentMode.displayName)
                .font(CodexTheme.fontSmall).foregroundColor(store.agentMode == .standard ? CodexTheme.textTertiary : CodexTheme.textPrimary))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                // P14 第四批: 同 approvalToggle —— 无描边、无底色; 状态靠文字色表达。
                // ⚠️ 曾用 `accent` (品牌红) —— 实测参考图的控件行是**纯灰阶**(#181818/#E0E0E0, R=G=B),
                //    零彩色 ⇒ 换中性色 (standard = textTertiary / 非 standard = textPrimary)。
                .frame(height: Tune.pillHeight)
                .contentShape(Rectangle())
        }
    }

    // MARK: - 知识注入 pill (P3.7: 生效条数 + 重启引擎入口)

    @ViewBuilder
    private var knowledgePill: some View {
        // 无生效条目不占位 (与 Codex 降噪口径一致)
        if store.activeKnowledgeCount > 0 {
            Menu {
                Button(LK(store.knowledgeDirty ? "重启引擎生效 (知识改动将注入)" : "注入块已是最新")) {
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

    private var modelMenu: some View {
        // P9.1e (#8): 控件数据直订 ModelStore —— 流式 chunk (store.messages) 不再触发菜单重算。
        // 2026-09-23: 换受控 `ModelPicker` (popover: 模型列表 + 强度滑轨), 级别收敛在控件内,
        // 这里只负责"把结果写成全局期望"。
        ModelPicker(
            models: store.model.menuModels,
            choice: store.model.currentChoice,
            title: { m in
                store.model.customLabel(provider: m.provider, modelId: m.id) ?? m.label
            },
            fallbackTitle: store.model.currentModelDisplayName,
            helpText: L("模型与思考强度 (选中即期望, 下一回合生效)")
        ) { pick in
            store.selectModel(pick)
        }
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
                          || !store.pendingImages.isEmpty
            Button(action: { store.sendDraft() }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canSend ? CodexTheme.bgBase : CodexTheme.textMuted)
                    .frame(width: Tune.sendButtonSize, height: Tune.sendButtonSize)
                    // ⚠️ 禁用态用 `bgChat`（= 比输入区所在的 `contentPanel` 暗一档）**是有意的**：
                    // 它和"可用态 = 实心 `textPrimary` 圆"配成一对（都是"实心圆按钮"，只是灭的），
                    // 且自带 1px 描边 → 满足"面必须自带边界元素"的判据，不是无边界补丁。
                    // 历史上它和输入区同为 `bgChat`（填色等于隐形、只剩圈）；P10.8c 把输入区
                    // 抬到 `contentPanel` 后它才显形 —— 别把它"修"回 `contentPanel`。
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
            // P7-M6b: 图片走附件通道 (base64 进 RPC), 非图片保留 @路径 文本语义 (@file 模型自己 read)
            if ImagePipeline.isImageExtension(url.pathExtension) {
                store.addPendingImage(at: url)
            } else {
                store.draft += Copy.attachment(url.path)
            }
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
    /// P7-M6b: ⌘V 拦截 — 剪贴板是图片时不进文本, 走附件通道 (data, ext)。
    var onImagePaste: (Data, String) -> Void = { _, _ in }
    /// 焦点变化回传 (2026-10-16): 占位提示据此**在获得焦点时退场** —— 见下方长注释。
    var onFocusChange: (Bool) -> Void = { _ in }

    /// P7-M6b: 剪贴板图片拦截 — 双路由 (⌘V 可能经菜单 paste: 或 key equivalent 派发,
    /// 两条路都拦; 剪贴板无图时放行常规文本粘贴)。
    private final class PasteInterceptTextView: NSTextView {
        var onImagePaste: ((Data, String) -> Void)?
        var onFocusChange: ((Bool) -> Void)?

        /// 插入点与占位提示**占同一像素, 只能二选一** —— 同一条冲突的两面, 各踩中过一次:
        ///   · 2026-09-21 boss"那个闪烁线和那句'给 MangoX 发消息'重叠了, 感官非常不友好"
        ///     (截图实测: 光标占 x 102–105, 而"给"的墨迹从 x 97 起 → 竖线落在字的左半)。
        ///   · 2026-10-16 boss"鼠标点上去了, 没有那个闪烁的竖标, 但是可以正常输入"
        ///     —— 上一版为躲重叠, 在 `drawInsertionPoint` 里**只按 `string.isEmpty` 就不画**;
        ///     但占位提示并不随焦点退场 ⇒ 空框一被聚焦就**两样都没有**(光标被压掉、提示还占着位)。
        ///
        /// 修法 = **按焦点裁决, 不按"有没有字"**: 获得焦点 ⇒ 提示退场、插入点照画;
        /// 失焦 ⇒ 提示回来(此时本来也没有插入点)。⇒ 两者**永不同时在场**, 重叠从根上不成立。
        /// 这也正是 AppKit 自己的行为 (NSTextField 一开始编辑, placeholder 就消失);
        /// ⚠️ 且它**语言无关** —— 不必去猜"首字左边距"那个字体/语言相关的偏移
        /// (那是 2026-09-21 否掉"把提示往右挪几个点"的理由, 现在依然成立)。
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { notifyFocus(true) }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { notifyFocus(false) }
            return ok
        }

        /// ⚠️ **先把回调取出来再跳异步**: 属性读发生在 MainActor 上(合法), 而
        ///     `DispatchQueue.main.async` 的闭包**不是** actor-isolated —— 直接在闭包里读
        ///     `self.onFocusChange` 可能触并发隔离告警(本项目要求 warning 为 0)。
        ///     跳异步本身是为了避开 "Modifying state during view update"。
        private func notifyFocus(_ focused: Bool) {
            let callback = onFocusChange
            DispatchQueue.main.async { callback?(focused) }
        }

        override func paste(_ sender: Any?) {
            if let img = ImagePipeline.pasteboardImage() {
                onImagePaste?(img.data, img.ext)
                return
            }
            super.paste(sender)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown,
               event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v",
               let img = ImagePipeline.pasteboardImage() {
                onImagePaste?(img.data, img.ext)
                return true   // 窗口级先于菜单派发, 直接吃掉 ⌘V
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // 手动组装: documentView 必须是拦截子类 (scrollableTextView() 造的是原生类)
        let textView = PasteInterceptTextView()
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
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onImagePaste = onImagePaste
        textView.onFocusChange = onFocusChange
        textView.delegate = context.coordinator
        scrollView.documentView = textView

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
