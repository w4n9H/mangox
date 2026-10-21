//
//  DreamConfirmSheet.swift
//  P15.9 定向 dream（`由此 Dream`）—— 点了菜单项之后的二次确认。
//

import SwiftUI

/// 「由此 Dream」的二次确认弹窗。
///
/// **为什么要这一屏而不是"点了就跑"**（boss 2026-10-21）:
/// ① 它是 dream 里最贵的一次调用（256k 预算）—— 规模、预算占用、会不会被裁，要在
///    **按下之前**看得到，而不是跑完才知道；
/// ② 归属根是这场会话**唯一的落点**（P15.8），点之前就该知道会归到哪个笔记根；
/// ③ 空正文、上一场还在跑这两种情况，弹窗里就能说清 / 置灰，不必"点完再报错"。
///
/// 三个数都是**查出来的**（`PersistenceStore.dreamMaterialStats` 一条聚合），不是估的：
/// 字数与真正喂给模型的 material 同源，所以"送入 113,354 字"这个数字与 `sessionMaterial`
/// 拼出来的长度逐字相等（判据见冒烟）。
struct DreamConfirmSheet: View {
    let preview: DreamPreview
    /// 确认后真正 fire（由侧栏传入 `store.startTargetedDream`）
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Rectangle().fill(CodexTheme.divider).frame(height: 1)
            facts
            budgetBar
            if preview.willTruncate { truncationNotice }
            if preview.isEmpty { emptyNotice }
            Text(L("这是单独一次，不会移动每日 dream 的时间窗口。"))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(20)
        .frame(width: 460)
        .background(CodexTheme.bgChat)
    }

    // MARK: 分段

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("由此 Dream"))
                .font(CodexTheme.fontTitle)
                .foregroundStyle(CodexTheme.textPrimary)
            Text(preview.title)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 7) {
            // ⚠️ **一个字符串只放一个占位符**: 多占位符的译文会调语序（en 是
            //    "%lld turns · %@ chars" 还是反过来?）, 按位置喂参数就会错位。拆成两段再拼,
            //    顺序由这里的 `·` 决定, 译文只管自己那一小段。
            fact(L("正文"), String(format: L("%@ 字"), grouped(preview.materialChars))
                 + " · " + String(format: L("%lld 个回合"), preview.turns))
            fact(L("归属"), preview.rootLabel)
            fact(L("产出"), L("只出提案，不改任何文件"))
        }
    }

    private var budgetBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: L("送入 %@ 字"), grouped(preview.materialChars))
                 + " / " + String(format: L("预算 %@ 字"), grouped(preview.budget)))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textSecondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CodexTheme.bgElevated)
                    Capsule()
                        .fill(preview.willTruncate ? CodexTheme.blocked : CodexTheme.accent)
                        .frame(width: max(2, proxy.size.width * preview.budgetRatio))
                }
            }
            .frame(height: 4)
        }
    }

    private var truncationNotice: some View {
        Text(String(format: L("超出预算：只会做最近 %@ 字，前面的回合会被省略。"),
                    grouped(preview.budget)))
            .font(CodexTheme.fontTiny)
            .foregroundStyle(CodexTheme.blocked)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyNotice: some View {
        Text(L("这一场只有工具输出，没有可提炼的内容。"))
            .font(CodexTheme.fontTiny)
            .foregroundStyle(CodexTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
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
            Button(L("开始 Dream")) {
                onStart()
                dismiss()
            }
            .buttonStyle(CodexActionButtonStyle(kind: .primary))
            .disabled(preview.isEmpty)
        }
    }

    // MARK: 小件

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 千分位 —— `113,354`。**不做"11.4 万字"那种换算**: 换算要乘除 10⁴, 换语言时
    /// 格式串（`%.1f 万字`）对不上新的单位, 而精确到个位的数字本身没有歧义。
    private func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
