//
//  MiniBarView.swift
//  P4.2: mini 工具台 (主窗口变形形态, Apple Music mini player 同款语义)。
//  左上角最小化按钮 → 主窗口缩为 mini 台: 任务卡堆叠 (名称+计时+停止 / 活动摘要);
//  点卡身 = 还原主窗口并跳该会话; 全部完成 → 闪显完成卡 5s 后回落空态 (窗口保持, 不自动还原)。
//

import SwiftUI

struct MiniBarWindowView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶行: 还原按钮紧跟交通灯, 标题+在途数随后 (还原入口唯一)
            HStack(spacing: 6) {
                Button(action: { store.miniMode = false }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(CodexTheme.bgElevated)
                        .cornerRadius(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("还原主窗口")
                Text("任务台")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                if !store.runningTurns.isEmpty {
                    Text("· \(store.runningTurns.count) 个在途")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                Spacer()
            }
            // 位于交通灯下方一行的安全区内, 顶行最左侧
            if let flash = store.lastCompleted {
                flashCard(flash)
            }
            if store.runningTurns.isEmpty {
                if store.lastCompleted == nil {
                    emptyState
                }
            } else {
                // >4 卡: 窗口高度封顶 (miniWindowHeight), 多出的卡滚动查看
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(Array(store.runningTurns).sorted(by: { $0.uuidString < $1.uuidString }),
                                id: \.self) { sid in
                            MiniCardView(store: store, sid: sid)
                        }
                    }
                }
                // 无 fixedSize: ScrollView 在固定窗口高内贪婪填充, >4 卡时内部滚动
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CodexTheme.bgChat)
    }

    /// 空态: 一句轻提示 (还原走顶行按钮, 不重复放入口)。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 16))
                .foregroundStyle(CodexTheme.textMuted)
            Text("暂无在途任务")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// 完成闪显卡 (完成后显示 5s, 随后回落空态; 窗口保持不自动还原)。
    private func flashCard(_ flash: (sid: UUID, title: String, duration: String)) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(CodexTheme.toolDone)
            Text(flash.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CodexTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(flash.duration)
                .font(CodexFonts.monoFont(10, weight: .medium))
                .foregroundStyle(CodexTheme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(CodexTheme.toolDone.opacity(0.10))
        .cornerRadius(8)
    }
}

// MARK: - 单任务卡 (L1 名称+计时+停止 / L2 摘要)

struct MiniCardView: View {
    @ObservedObject var store: ChatStore
    let sid: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.accent)
                Text(store.turnTitle(sid))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(store.turnElapsedText(sid))
                        .font(CodexFonts.monoFont(10, weight: .medium))
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                Button(action: { store.stopTurn(sid) }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(CodexTheme.toolError)
                        .frame(width: 18, height: 18)
                        .background(CodexTheme.toolError.opacity(0.12))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("停止该任务")
            }
            Text(store.miniSummary(sid))
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(CodexTheme.bgElevated)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            // 点卡 = 看这个会话 → 还原主窗口 + 跳转
            store.selectConversation(sid)
            store.miniMode = false
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
