//
//  AssistantLedgerSheet.swift
//  P19.2 S13 —— 助理台账（读账本、渲染五节 + brief）。
//
//  为什么是一个**只读**的 sheet 而不是编辑器: 账本的写者是**模型**（S11 起它自己 write），
//  两个写者 = 两份真源。人要看的是"目标到哪了、有什么在等我"，不是"改一行字" ——
//  真要改，去会话里说一句，那会走同一条写盘路径（围栏仍然只认那一份文件）。
//
//  ⚠️ 读法必须与 fire 那一刻**同源**: 路径来自 `SchedulerService.handoffPath`（调用方传进来），
//     不是这里自己拼 —— 自己拼的话，S9 那套「新位置 / 旧位置回落」在这里是另一份实现，
//     台账显示的可能根本不是模型正在写的那一份。
//
//  ⚠️ 五节的**结构**由 `AssistantLedger` 给（S8 的 35 条判据管着它），这一层只负责摆。
//     视图里不许再写一份"怎么认节头"的逻辑 —— 那就是三份真源里的第三份。
//

import SwiftUI

struct AssistantLedgerSheet: View {
    let title: String
    /// 账本原文（读不到 / 还没写 ⇒ 空串）。
    let text: String
    /// 文件的修改时间（nil = 还没有这个文件）。
    let updatedAt: Date?
    @Environment(\.dismiss) private var dismiss

    /// 归档默认**收起**: 它是"给人回看的记忆"，不是待办 —— 天天摊在眼前就成了噪音
    /// （与 `ScheduledView.showExecuted` 同一条取舍）。
    @State private var archiveOpen = false

    private var ledger: AssistantLedger { AssistantLedger.parse(text) }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CodexTheme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isEmpty {
                        emptyNote
                    } else {
                        if !ledger.goal.isEmpty { section(L("目标"), [ledger.goal], mono: false) }
                        completionSection
                        if !ledger.tracking.isEmpty { section(L("在跟踪"), ledger.tracking, mono: false) }
                        if !ledger.waiting.isEmpty {
                            section(L("待你决定"), ledger.waiting, mono: false, tint: CodexTheme.blocked)
                        }
                        archiveSection
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 520)
        .background(CodexTheme.bgChat)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(CodexTheme.fontTitle)
                .foregroundStyle(CodexTheme.textPrimary)
                .lineLimit(1)
            stageChip
            if !isEmpty {
                Text(String(format: L("账本 %lld 字"), text.count))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textTertiary)
            }
            if let updatedAt {
                Text(updatedAt, style: .relative)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textTertiary)
            }
            Spacer()
            Button(L("关闭")) { dismiss() }
                .buttonStyle(.plain)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 三态各自**说一句话**。空账本不算"完成"（`isComplete` 只在 `.done` 为真），
    /// 这一格就是那句话在界面上的落点。
    private var stageChip: some View {
        let (label, color): (String, Color) = {
            switch ledger.stage {
            case .empty:    return (L("当前无目标"), CodexTheme.textTertiary)
            case .tracking: return (L("在追"), CodexTheme.info)
            case .done:     return (L("已完成 · 可收尾"), CodexTheme.statusDone)
            }
        }()
        return Text(label)
            .font(CodexTheme.fontTiny)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var emptyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("还没有账本"))
                .font(CodexTheme.fontBody)
                .foregroundStyle(CodexTheme.textPrimary)
            Text(L("这个助理还没写出账本 —— 等它跑一轮，或在会话里让它记一笔，五节就会出现在这里。"))
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var completionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("完成状态"))
            if ledger.items.isEmpty {
                Text(L("还没有列出验收项"))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textTertiary)
            } else {
                ForEach(Array(ledger.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(glyph(item.mark))
                            .font(CodexTheme.fontMonoSm)
                            .foregroundStyle(color(item.mark))
                        Text(item.text)
                            .font(CodexTheme.fontSmall)
                            .foregroundStyle(item.mark == .done ? CodexTheme.textSecondary
                                                                : CodexTheme.textPrimary)
                            .strikethrough(item.mark == .done, color: CodexTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 折叠标题带条数: 收起时也得看得出"这里有多少历史"，否则人会以为没有。
            Button {
                archiveOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(archiveOpen ? 90 : 0))
                    Text(L("已完成（归档）"))
                        .font(CodexTheme.fontLabel)
                        .foregroundStyle(CodexTheme.textSecondary)
                    Text("\(ledger.archived.count)")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if archiveOpen {
                if ledger.archived.isEmpty {
                    Text(L("还没有归档"))
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textTertiary)
                } else {
                    ForEach(Array(ledger.archived.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(CodexTheme.fontSmall)
                            .foregroundStyle(CodexTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func section(_ title: String, _ lines: [String],
                         mono: Bool, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(mono ? CodexTheme.fontMonoSm : CodexTheme.fontSmall)
                    .foregroundStyle(tint ?? CodexTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(CodexTheme.fontLabel)
            .foregroundStyle(CodexTheme.textTertiary)
    }

    private func glyph(_ m: LedgerMark) -> String {
        switch m {
        case .done:    return "[x]"
        case .todo:    return "[ ]"
        case .blocked: return "[!]"
        }
    }

    private func color(_ m: LedgerMark) -> Color {
        switch m {
        case .done:    return CodexTheme.statusDone
        case .todo:    return CodexTheme.textTertiary
        case .blocked: return CodexTheme.blocked
        }
    }
}
