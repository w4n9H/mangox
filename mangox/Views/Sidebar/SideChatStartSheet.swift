//
//  SideChatStartSheet.swift
//  P6.3.3 侧问选点 —— 从**哪一轮**开始带上下文（2026-10-21 boss 定）
//

import SwiftUI

/// 弹窗的数据。`.sheet(item:)` 要 `Identifiable`, 而"选哪个回合"这件事本身不属于
/// `ChatStore` 的状态 —— 它只在**点了菜单之后**才临时算一次（与 `DreamPreview` 同法:
/// 侧栏悬停 / 展开不会碰 `replayMessages`）。
struct SideChatPick: Identifiable {
    let id = UUID()
    let sid: UUID
    let sourceTitle: String
    /// **倒序**（最新在前），来自 `ChatStore.sideChatTurns(for:)`
    let turns: [SideChatTurn]
}

/// 二次确认：选一轮，那一轮**及之前**的对话带进侧问。
///
/// 为什么这件事值得一屏（而不是像以前那样直接 fork 整场）: fork 出来的会话会**永久**带着
/// 那一段上下文, 选错了只能删掉重开 —— 而"从哪一轮开始"正是用户唯一想控制的那一格。
struct SideChatStartSheet: View {
    let pick: SideChatPick
    /// `nil` = 整场（零拷贝, 直接用源文件）
    let onStart: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// `nil` = 整场。**默认就是整场** —— 老手感不变: 一路回车就走。
    @State private var picked: Int?

    /// 选到**最新那一轮**时合并成整场（规则在 `SideChatTurns.upTo`, 那里才能被冒烟断言）
    private var upTo: Int? {
        SideChatTurns.upTo(picked: picked, newest: pick.turns.first?.index)
    }

    /// 会带进侧问的轮数（底部那句"将带上 N 轮"）
    private var carried: Int { upTo ?? pick.turns.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Rectangle().fill(CodexTheme.divider).frame(height: 1)
            Text(L("选一轮：那一轮及之前的对话都会带进侧问。"))
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            turnList
            if pick.turns.isEmpty { emptyNotice }
            footer
        }
        .padding(20)
        .frame(width: 460)
        .background(CodexTheme.bgChat)
    }

    // MARK: 分段

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("由此侧问"))
                .font(CodexTheme.fontTitle)
                .foregroundStyle(CodexTheme.textPrimary)
            Text(pick.sourceTitle)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var turnList: some View {
        // 固定高 + 内部滚动: 40 轮的会话不该把弹窗顶到屏幕外（同 dream 弹窗那条"高度与内容脱钩"）
        ScrollView {
            VStack(spacing: 0) {
                turnRow(index: nil, title: L("整场"), at: nil, trailing: L("零拷贝"))
                ForEach(pick.turns) { t in
                    Rectangle().fill(CodexTheme.divider).frame(height: 1)
                        .padding(.leading, 35)
                    turnRow(index: t.index, title: t.title, at: t.at, trailing: nil)
                }
            }
        }
        .frame(maxHeight: 264)
        .background(CodexTheme.bgElevated.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(CodexTheme.divider, lineWidth: 1))
    }

    /// 一行 = 一个可选起点。`index == nil` 那一行是"整场"。
    private func turnRow(index: Int?, title: String, at: Date?, trailing: String?) -> some View {
        let selected = picked == index
        return Button {
            picked = index
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(selected ? CodexTheme.accent : CodexTheme.textMuted,
                                  lineWidth: selected ? 4 : 1.2)
                    .frame(width: 12, height: 12)
                Text(index.map { String(format: L("第 %lld 轮"), $0) } ?? "—")
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(selected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                    .frame(width: 52, alignment: .leading)
                    .lineLimit(1)
                Group {
                    if title.isEmpty {
                        // 只有图片没有文字的那一轮: 这一格空着会让人以为列表错位
                        Text(L("（只有图片）"))
                            .foregroundStyle(CodexTheme.textMuted)
                    } else {
                        Text(title)
                            .foregroundStyle(selected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                    }
                }
                .font(CodexTheme.fontSmall)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing {
                    Text(trailing)
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textMuted)
                }
                if let at {
                    Text(at.formatted(date: .omitted, time: .shortened))
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(selected ? CodexTheme.bgElevated : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var emptyNotice: some View {
        Text(L("这个会话还没说过话，侧问会带一个空上下文。"))
            .font(CodexTheme.fontTiny)
            .foregroundStyle(CodexTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !pick.turns.isEmpty {
                Text(String(format: L("将带上 %lld 轮源会话上下文"), carried))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textSecondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text(L("取消"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(L("由此处侧问")) {
                onStart(upTo)
                dismiss()
            }
            .buttonStyle(CodexActionButtonStyle(kind: .primary))
            .disabled(pick.turns.isEmpty)
        }
    }
}
