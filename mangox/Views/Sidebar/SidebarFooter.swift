//
//  SidebarFooter.swift
//  侧栏底部那条：分隔线 + 右端的设置齿轮。
//
//  为什么单独成一个类型（2026-10-26）：它原来是 `SidebarView` 里的一个私有计算属性，
//  而 `SidebarView` 牵一发动全身（`ChatStore` / `SidebarModel` / 数据库）—— 出图脚本根本
//  编不动它。抽出来只吃 `(active, onTap)` 两个入参 ⇒ **出图跑的就是产品源码**，
//  不是手搭一个"像那样"的仿制品（这条是 2026-10-14 立的规矩：文档效果图必须真源码跑）。
//

import SwiftUI

struct SidebarFooter: View {
    /// 设置窗口是否可见。真源 = `SidebarModel.showSettingsPanel`（由 `SettingsWindowController` 写入）。
    let active: Bool
    let onTap: () -> Void

    /// 出图用：强行指定悬停态（离屏渲染里没有鼠标，`onHover` 永远不会触发）。
    /// 产品恒传 `nil`，取真实悬停。
    var hoverOverride: Bool? = nil

    @State private var hovering = false

    private var isHovering: Bool { hoverOverride ?? hovering }

    var body: some View {
        VStack(spacing: 0) {
            // 分区线：没有它，底部这一截会被读成"最后一条会话"。
            Rectangle()
                .fill(CodexTheme.divider)
                .frame(height: 1)
                .padding(.horizontal, Tune.sidebarContentInset)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                settingsButton
            }
            .padding(.leading, Tune.sidebarContentInset)
            // 右沿 = `sidebarContentInset`（13）—— 与**分隔线的右端**、搜索框、会话行胶囊同一列。
            //
            // ⚠️ 曾经用过 `sidebarContentInset + 8`（对齐行内 ⋯ / 时间戳那一列），理由是
            //    "一个动作图标跟一排动作图标对齐"。2026-10-26 boss 看图否掉了：
            //    「右侧留空太大了, 留小一些, 尽量贴近那个边线」—— 在这个高度上，右端那 8pt 的
            //    空白读成了"没对齐"，而不是"对齐了某一列"。**图的判断优先于我的推演。**
            .padding(.trailing, Tune.sidebarContentInset)
            .padding(.top, 5)
            .padding(.bottom, 7)
        }
        // 底色与会话列表同一面：滚动内容从这条线下**穿过**时，压住它（`bgSidebar` 不透明）。
        .background(CodexTheme.bgSidebar)
    }

    /// 只有图标 ⇒ 三件事必须有：悬停说明、选中态（换色 + 底）、够大的命中框。
    ///
    /// ⚠️ **静息常驻一枚极淡底（`bgPill`）** —— 2026-10-26 boss 从七格里挑的"A2 这一格"。
    ///    理由不是好看：侧栏里每个可点对象都有底（会话行 / 项目行 / 导航行），只有它是裸图标时，
    ///    读起来像"悬在角落的装饰"而不是一个入口。
    ///
    /// ⚠️ 三档是**同一个底 + 逐级叠加**，不是三个各调出来的灰：
    ///    静息 `bgPill` → 悬停/选中再叠一层 `selected`（亮色下是**加深**，暗色下是**提亮** ——
    ///    同一个 alpha 叠加在两种底色上方向天然相反，这正是"用一个叠加而不是两个硬编码灰"的
    ///    理由：各调一个中间灰，必然有一边在某个主题下"悬停没有任何变化"）。
    private var settingsButton: some View {
        Button(action: onTap) {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(active ? CodexTheme.accent : CodexTheme.textSecondary)
                .frame(width: 22, height: 22)   // 图标 12pt 太小，直接点很难命中
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                            .fill(CodexTheme.bgPill)
                        if active || isHovering {
                            RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                                .fill(CodexTheme.selected)
                        }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .help(L("设置"))
        .accessibilityLabel(L("设置"))
    }
}
