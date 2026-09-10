//
//  TopBarView.swift
//  Native window toolbar: left title · right Chat/Work capsule pill (only).
//  Theme + settings have moved to the sidebar footer (Codex chrome discipline).
//

import SwiftUI

// MARK: - Left: session title

struct TopBarTitleControls: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        Text(store.selectedTitle)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(CodexTheme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Right: Chat/Work capsule pill (only)

struct TopBarModeControls: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        HStack(spacing: 0) {
            modePillButton("Chat", active: !store.workspaceVisible, disabled: false) {
                store.workspaceVisible = false
            }
            // P3.4: Work 仅 project 会话可用 (无目录的会话灰掉)
            modePillButton("Work", active: store.workspaceVisible,
                           disabled: !store.canUseWorkspace) {
                store.workspaceVisible = true
            }
        }
        .padding(2)
        .background(CodexTheme.bgElevated)
        .clipShape(Capsule())
        .fixedSize() // 禁止被压缩
        .help("Chat: 纯对话 · Work: 带工作区")
    }

    private func modePillButton(_ title: String,
                                active: Bool,
                                disabled: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Tune.modePillFontSize, weight: .medium))
                .foregroundStyle(active ? CodexTheme.textPrimary : CodexTheme.textTertiary)
                .opacity(disabled && !active ? 0.35 : 1)
                .padding(.horizontal, Tune.modePillHPadding)
                .padding(.vertical, Tune.modePillVPadding)
                .frame(minWidth: Tune.modePillMinWidth)
                .background(
                    Group {
                        if active {
                            CodexTheme.bgBase
                        } else {
                            Color.clear
                        }
                    }
                )
                .clipShape(Capsule())
                .shadow(color: .black.opacity(active ? 0.08 : 0),
                        radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "仅项目会话可用 (在输入框上方选择项目)" : "Chat: 纯对话 · Work: 带工作区")
    }
}