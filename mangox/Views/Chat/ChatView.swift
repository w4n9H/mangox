//
//  ChatView.swift
//  Middle column: scrolling message list + composer.
//

import SwiftUI

struct ChatView: View {
    @ObservedObject var store: ChatStore

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

    private var messageList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                if store.messages.isEmpty {
                    if store.activeSideChat != nil {
                        sideEmptyState
                    } else {
                        WelcomeView()
                            .padding(.top, Tune.welcomeTopPadding)
                    }
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
                    Text(turns == 1 ? "离开期间完成 1 轮" : "离开期间完成 \(turns) 轮")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CodexTheme.textPrimary)
                    if !preview.isEmpty {
                        Text("· 最近：" + preview)
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
                .textSelection(.enabled)   // 用户气泡正文同样可选中复制
        }
    }
}
