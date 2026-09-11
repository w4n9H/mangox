//
//  TopBarView.swift
//  Native window toolbar: left title · center Chat/轨迹 capsule (P5.0.2) · right Work toggle.
//  正交双开关: 胶囊 = 主区底档; Work = 右侧工作区列显隐, 互不影响。
//  P5.0.2 布局: 胶囊居中 (principal), Work 钉在窗口右缘 (.primaryAction) —— 解挤。
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

// MARK: - Center: Chat/Trace capsule (主区底档二选一)

struct TopBarCapsuleControls: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        HStack(spacing: 0) {
            modePillButton("Chat", active: store.capsuleMode == .chat) {
                store.capsuleMode = .chat
            }
            modePillButton("Trace", active: store.capsuleMode == .trajectory) {
                store.capsuleMode = .trajectory
            }
        }
        .padding(2)
        .background(CodexTheme.bgElevated)
        .clipShape(Capsule())
        .fixedSize() // 禁止被压缩
        .help("Chat: 对话 · Trace: 结构化事件回放")
    }

    private func modePillButton(_ title: String,
                                active: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Tune.modePillFontSize, weight: .medium))
                .foregroundStyle(active ? CodexTheme.textPrimary : CodexTheme.textTertiary)
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
    }
}

// MARK: - Right (窗口右缘): Work toggle

struct TopBarWorkButton: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        Button(action: { store.workspaceVisible.toggle() }) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(store.workspaceVisible ? CodexTheme.accent : CodexTheme.textTertiary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(store.workspaceVisible ? CodexTheme.accentSoft : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!store.canUseWorkspace)
        .opacity(!store.canUseWorkspace ? 0.35 : 1)
        .help(store.canUseWorkspace
              ? (store.workspaceVisible ? "收起工作区" : "打开工作区")
              : "仅项目会话可用 (在输入框上方选择项目)")
    }
}
