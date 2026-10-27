//
//  SettingsCategory.swift
//  设置页的**左侧分类**与外壳（2026-10-26）。
//
//  为什么要有：原来是一整列竖着堆的卡片（外观 / 语言 / 模型 / 搜索 / 并发 / 通知 / 捕获 /
//  邮箱 / 备份），9 段挤在一个滚动区里 —— 想改「备份」得先滚过 8 段別的东西，而它们之间
//  没有任何骨架说明谁和谁是一类。boss 的原话就是「排版方面现在太混乱了」。
//
//  ⚠️ 外壳单独成一个类型（`SettingsShell`）不是为了好看：`SettingsView` 吃 `ChatStore`
//     （数据库 / 模型目录 / 通知授权），出图脚本编不动它；把「左列 + 右栏」抽成只吃
//     `(selection, detail)` 的壳，文档效果图才能是**产品源码跑出来的**。
//

import SwiftUI

/// 设置页的分类。`rawValue` = 中文原文（与 `DayBucket` 同款：词表 key 就是它本身，
/// 渲染时走 `LK(...)` 查表 ⇒ 英文界面下自动换成译文，中文界面回落原文）。
///
/// ⚠️ 2026-10-27 boss：**「通用」与「运行」合并成「通用」** —— 原话「不然看上去太空旷了」。
///    两类各只有 2~3 段，切过去右栏大半是空白。合并后「通用」= 长啥样（外观/语言）
///    + 一次任务怎么跑（锁屏运行/并发/通知/捕获热键），正好是"跟具体模型、具体账号都无关"的那一坨。
///    ⇒ 分类的判据不是"代码里 section 的先后"，而是**用户切过去时那一坨有多满**。
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general     = "通用"
    case model       = "模型"
    case integration = "集成"
    case data        = "数据"

    var id: String { rawValue }

    /// SF Symbol。
    ///
    /// ⚠️ 用**线条字形**而不是 `.fill`：这一列是导航，实心图标会在选中行里和胶囊底抢注意力
    /// （侧栏那五条也是线条字形）。
    var icon: String {
        switch self {
        case .general:     "slider.horizontal.3"
        case .model:       "cpu"
        case .integration: "puzzlepiece.extension"
        case .data:        "externaldrive"
        }
    }
}

/// 左列分类 + 右栏内容。
struct SettingsShell<Detail: View>: View {
    @Binding var selection: SettingsCategory
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            categoryList
            // 一条通栏竖线：不是"卡片边框"，是两块面之间的缝。
            Rectangle()
                .fill(CodexTheme.divider)
                .frame(width: 1)
            ScrollView {
                detail
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CodexTheme.bgChat)
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsCategory.allCases) { c in
                Button {
                    selection = c
                } label: {
                    HStack(spacing: 8) {
                        // 选中行图标转 accent、未选中走 textSecondary —— 与侧栏导航行同一套。
                        Image(systemName: c.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(selection == c ? CodexTheme.accent : CodexTheme.textSecondary)
                            .frame(width: 16)
                        Text(LK(c.rawValue))
                            .font(.system(size: 13, weight: selection == c ? .medium : .regular))
                            .foregroundStyle(selection == c ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                            // ⚠️ 一定要 lineLimit(1)：见 `SettingsShell.categoryList` 末尾那段
                            //    "为什么列宽不是定值" —— 这一行会被挤到半个词宽。
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(selection == c ? CodexTheme.selected : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        // ── 为什么列宽**不是**一个定值（2026-10-27 实证）────────────────────────────
        // 原来写 `.frame(width: 168)`：中文版看着很空，收窄到 128 后**英文 `Integrations`
        // 在词中间断成 `Integration` + `s`**。查下来不是"128 差几个点"：
        // HStack 里 `Text` 和 `Spacer` 都算可伸缩（Text 长单词也允许断字 ⇒ 最小宽 = 0），
        // 剩余空间被两边**对半分** ⇒ 文字只拿到约 40pt，凑不齐一个单词就断行。
        // 实测：给 Text 加 `layoutPriority(1)` **无效**（照样断）；能治的只有"不许它被压缩"。
        // ⇒ 两条一起：Text 恒 `lineLimit(1)` + 列宽**由最宽那行撑开**（下面的 fixedSize），
        //    `settingsSidebarMinWidth` 只当**地板**（中文 2 字标签免得窄成一条线）。
        // 这样任何语言都不会断字，也不再需要"算一个能装下所有译文"的数字。
        .frame(minWidth: Tune.settingsSidebarMinWidth, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CodexTheme.bgSidebar)
    }
}
