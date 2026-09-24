//
//  ChatView.swift
//  Middle column: scrolling message list + composer.
//

import SwiftUI

// MARK: - P9-#9 滚动探针 key (内容底距视口底 <140pt = 跟随区, 上滑阅读不拽回)

private struct ChatContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatView: View {
    @ObservedObject var store: ChatStore
    @State private var viewportHeight: CGFloat = 0
    @State private var nearBottom = true   // 初始视为在底部 (defaultScrollAnchor 锚底)
    /// 自动滚动同帧合并标记: 流式期同帧多个 chunk 只调度一次滚动 (防 "update multiple times per frame")。
    @State private var scrollScheduled = false

    var body: some View {
        VStack(spacing: 0) {
            if let side = store.activeSideChat {
                SideChatBanner(info: side,
                               canJump: store.allConversations.contains { $0.id == side.parent }) {
                    store.selectConversation(side.parent)
                }
            }
            messageList
            ChatBottomBar(store: store)   // P5.0.3: 横幅 + 输入区抽共享组件 (轨迹视图同用)
        }
    }

    // MARK: - P9-#9 滚动探针 (独立成员: 拆小表达式避免类型检查超时)

    private var contentBottomProbe: some View {
        GeometryReader { g in
            Color.clear.preference(key: ChatContentBottomKey.self,
                                   value: g.frame(in: .named("chatScroll")).maxY)
        }
    }

    private var viewportHeightProbe: some View {
        GeometryReader { g in
            Color.clear.preference(key: ChatViewportHeightKey.self,
                                   value: g.frame(in: .named("chatScroll")).height)
        }
    }

    /// 视口高度只在布局/窗口变化时更新 (滚动中恒定)。
    private func handleViewportHeight(_ h: CGFloat) {
        viewportHeight = h
    }

    /// 内容底进入视口底 140pt 内 = 跟随区 (Bool 去重, 不随滚动帧重渲染)。
    private func handleContentBottom(_ bottomY: CGFloat) {
        let v = viewportHeight == 0 ? true : bottomY > viewportHeight - 140
        if nearBottom != v { nearBottom = v }   // 等值不写, 防 PreferenceKey 高频触发失效性更新
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            scrollColumn(proxy)
        }
    }

    /// 滚动列 = ScrollView + 摘要胶囊占位行 (拆子表达式, 防 type-check 超时)。
    private func scrollColumn(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            scrollContent(proxy)
            // P6.3.2: 离开摘要胶囊 — 独立占位行 (浮层会盖住最该读的最新内容, 2026-09-14 否决)
            if store.awaySummary != nil {
                HStack {
                    Spacer()
                    if let away = store.awaySummary {
                        AwaySummaryPill(
                            turns: away.turns,
                            preview: away.preview,
                            onJump: {
                                store.dismissAwaySummary()
                                withAnimation(CodexTheme.animMed) {
                                    proxy.scrollTo(store.messages.last?.id ?? UUID(), anchor: .bottom)
                                }
                            },
                            onDismiss: { store.dismissAwaySummary() })
                            .frame(maxWidth: Tune.chatColumnWidth)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(CodexTheme.animMed, value: store.awaySummary)
    }

    /// ScrollView + 探针/锚底/滚动响应 (P9-#9)。
    private func scrollContent(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            if store.messages.isEmpty {
                if store.activeSideChat != nil {
                    sideEmptyState
                } else {
                    WelcomeView()
                        .padding(.top, Tune.welcomeTopPadding)
                }
            } else {
                messageBlocks
                    .background(contentBottomProbe)   // P9-#9: 内容底部探针 (视口坐标系, 随滚动实时变化)
            }
        }
        .background(viewportHeightProbe)      // P9-#9: 视口高度探针 (挂 ScrollView 自身, 不随内容滚动)
        .coordinateSpace(name: "chatScroll")
        .onPreferenceChange(ChatViewportHeightKey.self) { handleViewportHeight($0) }
        .onPreferenceChange(ChatContentBottomKey.self) { handleContentBottom($0) }
        .defaultScrollAnchor(.bottom)   // 默认锚底: 打开会话即看最新内容 (否则停在最老一条)
        .onChange(of: store.selectedConversationId) { _, _ in
            // 换会话: replay 内容整批替换, 兜底滚到最新 (首帧锚点之外的双保险)
            DispatchQueue.main.async {
                withAnimation(nil) {
                    proxy.scrollTo(store.messages.last?.id ?? UUID(), anchor: .bottom)
                }
            }
        }
        .onChange(of: store.messages) { _, _ in
            // 流式 chunk 高频到达, 同帧多次触发会报 "update multiple times per frame";
            // scrollScheduled 同帧合并为一次滚动调度, 双跳异步复位 (滚动执行完的下一拍才放行)。
            // P9-#9: 用户上滑阅读历史时不再强制拽回 (距视口底 <140pt 才跟随)
            guard nearBottom, !scrollScheduled else { return }
            scrollScheduled = true
            DispatchQueue.main.async {
                let anchor: AnyHashable = store.isStreaming ? "streaming-tail" : (store.messages.last?.id ?? UUID())
                withAnimation(CodexTheme.animMed) {
                    proxy.scrollTo(anchor, anchor: .bottom)
                }
                DispatchQueue.main.async { scrollScheduled = false }
            }
        }
    }

    /// 消息块列 (空态分流在 scrollContent)。
    /// P10.6a: LazyVStack — 原 VStack 会为全部消息实例化 MessageBlockView (每条内含
    /// MarkdownView 的块解析 + 文本布局), 长会话首帧同步主线程构建数千视图。
    private var messageBlocks: some View {
        LazyVStack(alignment: .leading, spacing: Tune.chatMessageSpacing) {
            ForEach(store.messages) { msg in
                MessageBlockView(message: msg, store: store)
                    .id(msg.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if store.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .tint(CodexTheme.accent)
                    Text(Copy.streamingIndicator)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                .padding(.leading, 4)
                .id("streaming-tail")
            }
        }
        .padding(.horizontal, Tune.chatHPadding)
        .padding(.vertical, Tune.chatVPadding)
        .frame(maxWidth: Tune.chatColumnWidth, alignment: .leading)  // 内容 + 2×水平内边距, 与 Composer 内容宽同源 (Tune.chatContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(CodexTheme.animMessage, value: store.messages.count)
    }
}

// MARK: - Side chat (P6.3.1)

/// 离开摘要悬浮胶囊 (P6.3.2): 点击任意处 = 滚底 + 消失; × = 只关不滚。
struct AwaySummaryPill: View {
    let turns: Int
    let preview: String
    var onJump: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onJump) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textMuted)
                    // 单复数分开写: 英文 "1 turn" / "N turns" 需要各自一条词条 (不靠 %lld 硬套)
                    if turns == 1 {
                        Text("离开期间完成 1 轮")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CodexTheme.textPrimary)
                    } else {
                        Text("离开期间完成 \(turns) 轮")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CodexTheme.textPrimary)
                    }
                    if !preview.isEmpty {
                        Text(L("· 最近：") + preview)
                            .font(.system(size: 12))
                            .foregroundStyle(CodexTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CodexTheme.textMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(CodexTheme.bgElevated)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(CodexTheme.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

/// 快照提示条: 侧问会话常驻顶部 — 中性 chrome 条 (非告警样式), 右端唯一 accent = 跳回源会话。
struct SideChatBanner: View {
    let info: SideChatInfo
    var canJump: Bool
    var onJump: () -> Void
    @State private var hovering = false

    /// fork 时刻紧凑格式: 今天只报时间, 跨天报 M/d HH:mm。
    private var timeText: String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(info.at) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: info.at)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CodexTheme.textMuted)
            Text("源会话快照 · 含 \(info.turns) 轮上下文 · \(timeText) fork · 主线新消息不同步")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Button(action: onJump) {
                Text("前往源会话")
                    .font(.system(size: 11, weight: canJump ? .medium : .regular))
                    .foregroundStyle(hovering && canJump ? CodexTheme.accent : CodexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .disabled(!canJump)
            .opacity(canJump ? 1 : 0.4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(CodexTheme.bgSidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CodexTheme.divider).frame(height: 1)
        }
    }
}

extension ChatView {
    /// 侧问空态 (DB 空消息起步 — 模型有记忆, 界面无历史): 引导文案替代 WelcomeView。
    var sideEmptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(CodexTheme.bgElevated)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(CodexTheme.textSecondary)
            }
            .frame(width: 46, height: 46)
            Text("直接提问，模型已了解源会话上下文")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CodexTheme.textPrimary)
            if let side = store.activeSideChat {
                Text("来自「\(side.parentTitle)」的快照 · 含 \(side.turns) 轮上下文")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
            }
        }
        .padding(.top, Tune.welcomeTopPadding + 40)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Block renderer

struct MessageBlockView: View {
    let message: ChatMessage
    @ObservedObject var store: ChatStore
    @State private var hovering: Bool = false
    /// P7-M6c: 大图预览 (sheet, 不开独立 NSWindow — P4.2 尺寸控制坑)。
    @State private var previewAttachment: Attachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let atts = message.attachments, !atts.isEmpty {
                attachmentRow(atts)
            }
            content
            if let raw = rawText {
                footerToolbar(raw: raw)
                    .opacity(hovering ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.15), value: hovering)
                    .frame(maxWidth: .infinity,
                           alignment: message.role == .user ? .trailing : .leading)
            }
        }
        .onHover { hovering = $0 }
        .sheet(item: $previewAttachment) { att in
            attachmentPreview(att)
        }
    }

    // MARK: - 附件 (P7-M6c: 缩略图行 + 大图预览; replay 从 events 同源渲染)

    private func attachmentRow(_ atts: [Attachment]) -> some View {
        HStack(spacing: 6) {
            Spacer()   // 用户消息靠右
            ForEach(atts) { att in
                thumbnail(att)
                    .onTapGesture { previewAttachment = att }
            }
        }
        .padding(.bottom, 2)
    }

    /// 88×66 圆角缩略 (scaledToFill 裁切; 点击开大图)。
    private func thumbnail(_ att: Attachment) -> some View {
        Group {
            // P9-#12: 解码结果按路径缓存, 滚动/流式重算不再重复 IO
            if let img = ImagePipeline.cachedImage(atPath: att.path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(CodexTheme.bgSidebar)
                    .overlay(Image(systemName: "photo")
                        .foregroundStyle(CodexTheme.textMuted))
            }
        }
        .frame(width: 88, height: 66)
        .clipped()
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
        .contentShape(Rectangle())
        .help("点击查看大图")
    }

    /// 大图 sheet: 原图 scaledToFit + 点击背景/Esc/按钮关闭 (Esc 为 sheet 默认)。
    private func attachmentPreview(_ att: Attachment) -> some View {
        VStack(spacing: 10) {
            if let img = ImagePipeline.cachedImage(atPath: att.path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 900, maxHeight: 620)
            } else {
                Text("图片已不存在 (附件文件被移动或删除)")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(40)
            }
            Text("\(att.fileName) · \(att.pixelWidth)×\(att.pixelHeight)")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            Button("关闭") { previewAttachment = nil }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(CodexTheme.bgBase)
        .contentShape(Rectangle())
        .onTapGesture { previewAttachment = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch message.content {
        case .text(let s):
            if message.role == .user {
                userBubble(s)
            } else {
                MarkdownView(text: s, isStreaming: message.isStreaming,
                             basePath: store.activeProjectPath)
            }
        case .think(let s):
            ThinkingCardView(text: s, id: message.id, isStreaming: message.isStreaming)
        case .tool(let tool):
            ToolCallCardView(tool: tool,
                             onApprove: { store.approveTool(tool.id) },
                             onDeny: { store.denyTool(tool.id) },
                             onAlwaysAllow: { store.alwaysAllowTool(tool.id) })
        case .plan(let q):
            PlanQuestionCardView(question: q)
        }
    }

    private var rawText: String? {
        guard case .text(let s) = message.content else { return nil }
        return s
    }

    // MARK: - 消息底部工具条 (常驻淡显, hover 变清晰; 挂在文档流里不抖)

    private func footerToolbar(raw: String) -> some View {
        HStack(spacing: 10) {
            footerButton("doc.on.doc", "复制", label: "复制") { copyToPasteboard(raw) }

            // P3.7: 保存为记忆 (沉淀为全局知识条目, 带会话溯源)
            footerButton("bookmark", "保存为记忆", label: "记忆") {
                store.saveAsMemory(raw, sessionId: store.selectedConversationId)
            }

            if message.role == .assistant {
                // 记忆自动提炼 (人工触发): 整段会话 → 候选 → 知识面板待审核
                footerButton(store.distillRunning ? "hourglass" : "wand.and.stars",
                             LK(store.distillRunning ? "提炼中…" : "提炼本会话 → 待审核记忆"),
                             label: LK(store.distillRunning ? "提炼中…" : "提炼"),
                             disabled: store.distillRunning) {
                    store.distillMemoryFromCurrentSession()
                }
                if !message.isStreaming {
                    footerButton("arrow.clockwise", "重新生成", label: "重新生成") { store.regenerate() }
                }
            }
        }
    }

    /// 图标 + 文字标签 (裸图标不解释, 猜谜界面不要有)
    private func footerButton(_ icon: String, _ help: LocalizedStringKey,
                              label: LocalizedStringKey? = nil,
                              disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .frame(width: 12)
                if let label {
                    Text(label)
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(CodexTheme.textTertiary)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: - Bubbles

    private func userBubble(_ s: String) -> some View {
        HStack {
            Spacer()
            Text(s)
                .font(CodexTheme.fontBody)
                .foregroundStyle(CodexTheme.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(CodexTheme.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
                .textSelection(.enabled)   // 用户气泡正文同样可选中复制
        }
    }
}
