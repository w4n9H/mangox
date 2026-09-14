//
//  ChatBottomBar.swift
//  P5.0.3: 底部输入区共享组件 (横幅 + ChatComposer)。
//  Chat 与轨迹两个底档共用 — 切轨迹模式后仍能继续输入 (用户反馈补齐)。
//

import SwiftUI

struct ChatBottomBar: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        if store.engineMissing {
            engineMissingBanner
        }
        if let outcome = store.distillOutcome {
            noticeBanner(outcome,
                         clear: { store.distillOutcome = nil },
                         actionTitle: outcome.isError ? nil : "去审核",
                         action: outcome.isError ? nil : { store.openKnowledgePanel() })
        }
        if let notice = store.turnLimitNotice {
            noticeBanner(notice, clear: { store.turnLimitNotice = nil })
        }
        if let notice = store.extensionNotice {
            noticeBanner(notice, clear: { store.extensionNotice = nil })
        }
        ChatComposer(store: store)
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

    /// 通知横幅 (8s 自清, 提炼结果/并发超限共用; 可带一个动作按钮)。
    private func noticeBanner(_ outcome: (text: String, isError: Bool),
                              clear: @escaping () -> Void,
                              actionTitle: String? = nil,
                              action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: outcome.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(outcome.isError ? CodexTheme.toolError : CodexTheme.toolDone)
            Text(outcome.text)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle) { action() }
                    .buttonStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .help(actionTitle == "去审核" ? "打开知识面板的待审核分组" : "")
            }
            Button {
                clear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
        .padding(.horizontal, Tune.chatHPadding)
        .padding(.vertical, 7)
        .background((outcome.isError ? CodexTheme.toolError : CodexTheme.accent).opacity(0.10))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .bottom
        )
    }
}
