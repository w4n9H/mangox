//
//  ChatView.swift
//  Middle column: scrolling message list + composer.
//

import SwiftUI

struct ChatView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            messageList
            ChatBottomBar(store: store)   // P5.0.3: 横幅 + 输入区抽共享组件 (轨迹视图同用)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.messages.isEmpty {
                    WelcomeView()
                        .padding(.top, Tune.welcomeTopPadding)
                } else {
                    VStack(alignment: .leading, spacing: Tune.chatMessageSpacing) {
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
                // 滚动推出当前帧, 同帧合并为一次。
                DispatchQueue.main.async {
                    let anchor: AnyHashable = store.isStreaming ? "streaming-tail" : (store.messages.last?.id ?? UUID())
                    withAnimation(CodexTheme.animMed) {
                        proxy.scrollTo(anchor, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Block renderer

struct MessageBlockView: View {
    let message: ChatMessage
    @ObservedObject var store: ChatStore
    @State private var hovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
    }

    @ViewBuilder
    private var content: some View {
        switch message.content {
        case .text(let s):
            if message.role == .user {
                userBubble(s)
            } else {
                MarkdownView(text: s, isStreaming: message.isStreaming)
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
                             store.distillRunning ? "提炼中…" : "提炼本会话 → 待审核记忆",
                             label: store.distillRunning ? "提炼中…" : "提炼",
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
    private func footerButton(_ icon: String, _ help: String,
                              label: String? = nil,
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
        }
    }
}
