//
//  ContentView.swift
//  Two-column root (sidebar + chat) + optional workspace column (Work mode).
//  Top chrome = native unified toolbar (transparent, 2026-09-09 用户拍板回滚:
//  自绘 header/毛玻璃/实色条三个替代方案均被否, 接受滚顶时内容穿透 pill 的原始行为)。
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = ChatStore()

    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarCollapsed {
                SidebarView(store: store)
                    .frame(width: Tune.sidebarWidth)
                    .background(CodexTheme.bgSidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Divider().overlay(CodexTheme.divider)
            // P3.7/P3.6/P3.11: 主区切换——知识面板 / 定时任务面板 / 插件面板 / 会话视图
            if store.showKnowledgePanel {
                KnowledgeView(store: store)
                    .frame(maxWidth: .infinity)
                    .background(CodexTheme.bgChat)
            } else if store.showScheduledPanel {
                ScheduledView(store: store)
                    .frame(maxWidth: .infinity)
                    .background(CodexTheme.bgChat)
            } else if store.showExtensionsPanel {
                ExtensionsView(store: store)
                    .frame(maxWidth: .infinity)
                    .background(CodexTheme.bgChat)
            } else {
                ChatView(store: store)
                    .frame(maxWidth: .infinity)
                    .background(CodexTheme.bgChat)
            }
            if store.workspaceVisible {
                Divider().overlay(CodexTheme.divider)
                WorkspaceView(store: store)
                    .frame(width: Tune.workspaceWidth)
                    .background(CodexTheme.bgRight)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(CodexTheme.bgBase)
        .animation(CodexTheme.animMed, value: store.sidebarCollapsed)
        .animation(CodexTheme.animMed, value: store.workspaceVisible)
        .toolbar {
            // 单 ToolbarItem 撑满整宽, 内部分布 (macOS hiddenTitleBar 下 .navigation/.primaryAction 都贴左)
            ToolbarItem(placement: .principal) {
                HStack {
                    // 侧栏开关 (常驻, 双向 toggle —— toolbar 条件渲染不可靠)
                    Button(action: {
                        withAnimation(CodexTheme.animMed) { store.sidebarCollapsed.toggle() }
                    }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 11))
                            .foregroundStyle(store.sidebarCollapsed
                                             ? CodexTheme.textSecondary
                                             : CodexTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help(store.sidebarCollapsed ? "展开侧栏" : "收起侧栏")

                    TopBarTitleControls(store: store)
                    Spacer()
                    TopBarModeControls(store: store)
                    Spacer()   // 双 Spacer 让 Chat/Work 居中于中间列 (对齐 Codex)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
