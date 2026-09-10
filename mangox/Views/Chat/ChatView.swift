//
//  ChatView.swift
//  Middle column: scrolling message list + composer.
//

import SwiftUI

struct ChatView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            if store.engineMissing {
                engineMissingBanner
            }
            messageList
            ChatComposer(store: store)
        }
    }

    /// pi 缺失横幅: Release 不静默降级 Mock, 缺引擎必须可见。
    private var engineMissingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.toolRunning)
            Text("未找到 pi CLI, Agent 引擎不可用。请安装 pi 后重启 MangoX。")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, Tune.chatHPadding)
        .padding(.vertical, 8)
        .background(CodexTheme.toolRunning.opacity(0.10))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .bottom
        )
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
        content
            .onHover { hovering = $0 }
            .overlay(alignment: .topTrailing) {
                if hovering, let raw = rawText {
                    hoverToolbar(raw: raw)
                        .offset(x: 0, y: -8)
                }
            }
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

    // MARK: - Message hover toolbar (复制 / 重新生成)

    private func hoverToolbar(raw: String) -> some View {
        HStack(spacing: 2) {
            Button(action: { copyToPasteboard(raw) }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("复制")

            // P3.7: 保存为记忆 (沉淀为全局知识条目, 带会话溯源)
            Button(action: { store.saveAsMemory(raw, sessionId: store.selectedConversationId) }) {
                Image(systemName: "bookmark")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("保存为记忆")

            if message.role == .assistant && !message.isStreaming {
                Button(action: { store.regenerate() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textTertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("重新生成")
            }
        }
        .padding(2)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
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
