//
//  ContentView.swift
//  Two-column root (sidebar + chat) + optional workspace column (Work mode).
//  P4.2: mini 模式下主窗口整体变形为任务台 (Apple Music mini player 同款语义)。
//  Top chrome = native unified toolbar (transparent, 2026-09-09 用户拍板回滚:
//  自绘 header/毛玻璃/实色条三个替代方案均被否, 接受滚顶时内容穿透 pill 的原始行为)。
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = ChatStore()

    var body: some View {
        Group {
            if store.miniMode {
                MiniBarWindowView(store: store)
            } else {
                mainLayout
            }
        }
        .background(CodexTheme.bgBase)
        .animation(CodexTheme.animMed, value: store.workspaceVisible)
        .onChange(of: store.miniMode) { _, mini in
            // 主窗口变形 = 主窗隐藏 + mini 台顶上 (SwiftUI AppKitWindow 的 size 无法程序性
            // 修改——[MiniResize] 排查实证——由 MiniWindowController 用独立 NSWindow 承载)
            DispatchQueue.main.async {
                if mini {
                    guard let win = NSApp.windows.first(where: {
                        !($0 is NSPanel) && $0.identifier?.rawValue != "miniTaskWindow" && $0.isVisible
                    }) else { return }
                    MiniWindowController.shared.show(from: win)
                } else {
                    MiniWindowController.shared.restore()
                }
            }
        }
        .onAppear {
            // P4.2: mini 台窗口挂接; P4.1: 开关已开时启动期请求通知授权
            MiniWindowController.shared.attach(store: store)
            QuickCaptureController.shared.install(store: store)   // P8-T27: 全局热键 + 捕获条
            CompletionNotifier.shared.onOpen = { sid in
                store.selectConversation(sid)
                if store.miniMode { store.miniMode = false }   // 通知跳转 → 还原主窗口
                NSApp.activate(ignoringOtherApps: true)
            }
            if store.completionNotificationsEnabled {
                Task { await CompletionNotifier.shared.ensureAuthorization() }
            }
        }
        .toolbar {
            // P5.0.2 三段钉边 (v3 终态): .navigation 钉左 / .principal 居中 / .primaryAction 钉右。
            // 坑 (SO 72988380 实证): macOS 上存在 .principal 时 .primaryAction 会紧贴它而非钉右缘
            // —— 解法: 中间插一个只装 Spacer 的 ToolbarItem 撑开。
            ToolbarItem(placement: .navigation) {
                if store.miniMode {
                    // mini 台 chrome: 还原按钮 + 标题 (窗口拖动靠工具栏区; 向外扩 = 还原)
                    HStack {
                        Button(action: { store.miniMode = false }) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11))
                                .foregroundStyle(CodexTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("还原主窗口")
                        Group {
                            if store.runningTurns.isEmpty {
                                Text("任务台")
                            } else {
                                Text("任务台 · \(store.runningTurns.count) 个在途")
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CodexTheme.textPrimary)
                    }
                } else {
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
                        .help(LK(store.sidebarCollapsed ? "展开侧栏" : "收起侧栏"))

                        // P4.2: 最小化为任务台 (Apple Music mini player 同款; 向内收 = 缩小)
                        Button(action: { store.miniMode = true }) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 11))
                                .foregroundStyle(CodexTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("最小化为任务台")

                        TopBarTitleControls(store: store)
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                // 胶囊居中 (mini 态无主区胶囊)
                if !store.miniMode {
                    TopBarCapsuleControls(store: store)
                }
            }
            ToolbarItem { Spacer() }   // 撑开: 把 Work 推到右缘 (否则紧贴 principal)
            // Work 独立钉在窗口右缘 (与胶囊解挤; mini 态无主区工具栏)
            ToolbarItem(placement: .primaryAction) {
                if !store.miniMode {
                    TopBarWorkButton(store: store)
                }
            }
        }
    }

    // MARK: - 主布局 (normal 形态)

    private var mainLayout: some View {
        HStack(spacing: 0) {
            if !store.sidebarCollapsed {
                SidebarView(store: store)
                    .frame(width: Tune.sidebarWidth)
                    .background(CodexTheme.bgSidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Divider().overlay(CodexTheme.divider)
            // P3.7/P3.6/P3.11/P4.0.4: 主区切换——知识 / 定时任务 / 插件 / 设置 / 会话视图
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
            } else if store.showSettingsPanel {
                SettingsView(store: store)
                    .frame(maxWidth: .infinity)
                    .background(CodexTheme.bgChat)
            } else {
                // P5.0.2: 底档 = capsuleMode (Chat / 轨迹); Work 右列是独立开关 (下方 if)
                // P6.1.1: 主区底部挂状态栏 (4 项纯展示; Work 列/其他面板不挂)
                VStack(spacing: 0) {
                    if store.capsuleMode == .trajectory {
                        TrajectoryView(store: store)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(CodexTheme.bgChat)
                    } else {
                        ChatView(store: store)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(CodexTheme.bgChat)
                    }
                    BottomStatusBar(phase: store.runtimePhase,
                                    turnCount: store.currentTurnCount,
                                    stats: store.sessionStats)
                }
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
        .frame(minWidth: Tune.windowMinSize.width, minHeight: Tune.windowMinSize.height)
        .animation(CodexTheme.animMed, value: store.sidebarCollapsed)
        .animation(CodexTheme.animMed, value: store.capsuleMode)
    }

    // MARK: - 主窗口尺寸切换 (P4.2)
    // 已由 MiniWindowController 承载 (独立 NSWindow): 此处仅保留高度共享计算。

    /// mini 台窗口高: 空态紧凑; 有任务 = chrome + 卡数 (上限 4 卡)。mini 窗口与内容同源。
    static func miniWindowHeight(cards: Int) -> CGFloat {
        cards == 0 ? Tune.miniWindowEmptyHeight
                   : Tune.miniWindowChrome + CGFloat(min(cards, 4)) * Tune.miniCardRowHeight
    }
}
