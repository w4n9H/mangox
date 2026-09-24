//
//  MarkdownView.swift
//  Renders parsed markdown blocks with Codex styling; streaming cursor at tail.
//

import SwiftUI

struct MarkdownView: View {
    let text: String
    var isStreaming: Bool = false
    /// 图片块里**相对路径**的解析基准 (通常传会话绑定的项目目录)。
    /// 不传 ⇒ 相对路径判为不可解析并照实报错, 不猜。
    var basePath: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Tune.mdBlockSpacing) {
            ForEach(Array(MarkdownParser.parseCached(text).enumerated()),
                    id: \.offset) { _, block in
                blockView(block)
            }
            if isStreaming {
                StreamingCursor()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Block dispatch

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .font(CodexTheme.fontBody)
                .foregroundStyle(CodexTheme.textPrimary)
                .lineSpacing(Tune.mdLineSpacing)
                .textSelection(.enabled)   // 与思考卡/代码块对齐: 气泡正文可选中复制
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .listItem(let indent, let ordered, let index, let text):
            listItemView(indent: indent, ordered: ordered, index: index, text: text)
        case .blockquote(let text):
            blockquoteView(text: text)
        case .table(let header, let rows, let aligns):
            MarkdownTableView(header: header, rows: rows, aligns: aligns)
        case .image(let alt, let source):
            MarkdownImageView(alt: alt, source: source, basePath: basePath)
        case .divider:
            Rectangle()
                .fill(CodexTheme.divider)
                .frame(height: 1)
        }
    }

    // MARK: - Blocks

    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = Tune.mdHeadingSizes[min(level, 6) - 1]
        return Text(MarkdownInline.attributed(text))
            .font(.system(size: size, weight: level <= 2 ? .bold : .semibold))
            .foregroundStyle(CodexTheme.textPrimary)
            .padding(.top, level <= 2 ? 8 : 5)
            .textSelection(.enabled)
    }

    private func listItemView(indent: Int, ordered: Bool, index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(ordered ? "\(index)." : "•")
                .font(ordered ? CodexTheme.fontMonoSm : CodexTheme.fontBody)
                .foregroundStyle(CodexTheme.textTertiary)
                .frame(minWidth: 14, alignment: .leading)
            Text(MarkdownInline.attributed(text))
                .font(CodexTheme.fontBody)
                .foregroundStyle(CodexTheme.textPrimary)
                .lineSpacing(Tune.mdLineSpacing)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(indent) * Tune.mdListIndentStep)
    }

    private func blockquoteView(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(CodexTheme.thinking)
                .frame(width: 3)
            Text(MarkdownInline.attributed(text))
                .font(CodexTheme.fontBody)
                .foregroundStyle(CodexTheme.textSecondary)
                .lineSpacing(Tune.mdLineSpacing)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

}

// MARK: - Table

/// 表格: **铺满消息列宽** + 每列自带对齐 + 放不下才横滚。
///
/// ⚠️ 四条判据 (前三条是踩过的, 第四条是这次改法本身):
/// ① **余量均分本身不是错的, 错的是"没有铺满就均分"** —— 单元格挂 `maxWidth: .infinity`
///    会让余量均分, 旧版因此让短数字列被撑成一整条空道、长包名列反而不够用; 于是当年改成
///    "整张表恒取内容宽"。现在给 Grid 挂 `minWidth: 视口宽` ⇒ 余量是**在铺满列宽之后**才
///    均分的, 两种毛病一起没了。
/// ② **`fixedSize` 必须挂在文字上, 不能挂在 Grid 上** —— 挂在 Grid 上, 整张表恒取内容宽
///    (铺不满); 挂在文字上则是"列不折行 + 列宽 = 内容宽", 挤不下时**保持**内容宽、由外层
///    横滚承担。挂错位置正是"表要么铺不满、要么被压成多行"两种症状的同一个根因。
/// ③ **对齐必须落在"能撑满列宽"的 cell 上** —— `frame(alignment:)` 只有在本视图比列宽窄
///    时才有意义; 若列宽 == 内容宽, 对齐是空操作 (所以 `maxWidth: .infinity` 不能删)。
/// ④ **不能用 `ViewThatFits` 分"铺满 / 横滚"两档** —— 单元格挂着 `maxWidth: .infinity` 就
///    **永远装得下**, 第二档到不了。宽度只能实测, 不能诉求于"让它自己挑"。
///
/// 视口宽从 `ScrollView` 的**背景**读出 (横滚容器的宽就是消息列宽), 故本视图自持 `@State`;
/// 做成独立视图而不是 `MarkdownView` 的方法: 否则同一条消息里的多张表共用一份状态。
private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let aligns: [MarkdownAlign]

    @State private var viewport: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { idx, cell in
                        tableCell(cell, index: idx, isHeader: true)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { idx, cell in
                            tableCell(cell, index: idx, isHeader: false)
                        }
                    }
                }
            }
            // 宽度下界 = 视口宽 ⇒ 内容窄时报满消息列宽, 内容宽时按自身撑开由横滚承担。
            // 顺序要紧: `minWidth` 必须在背景/圆角**之前**, 否则只是给外框铺满、格子还是挤在左边。
            .frame(minWidth: viewport, alignment: .leading)
            .background(CodexTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                    .stroke(CodexTheme.border, lineWidth: 1)
            )
        }
        // ⚠️ **必须是 `.overlay` 而不是 `.background`** —— 这条踩出来花了一轮隔离实验:
        // `.background` 的几何读取会和 ScrollView 的理想尺寸算在同一次主布局里, 而内容的宽度
        // 又依赖量回来的 `viewport` ⇒ 成为一个环, SwiftUI **静默丢弃那次状态更新**
        // (症状: `viewport` 恒 0, 表格永远停在内容宽, 零报错)。`.overlay` 不参与主布局 ⇒ 送达。
        // ⚠️ `.allowsHitTesting(false)` 不能省: `Color.clear` 照样吃点击, 漏了表格里的选中/点按全哑。
        .overlay(GeometryReader { proxy in
            Color.clear
                .preference(key: TableViewportKey.self, value: proxy.size.width)
                .allowsHitTesting(false)
        })
        .onPreferenceChange(TableViewportKey.self) { viewport = $0 }
    }

    private func tableCell(_ text: String, index: Int, isHeader: Bool) -> some View {
        let align: MarkdownAlign = index < aligns.count ? aligns[index] : .leading
        return Text(MarkdownInline.attributed(text))
            .font(isHeader ? CodexTheme.fontLabel : CodexTheme.fontSmall)
            .foregroundStyle(isHeader ? CodexTheme.textPrimary : CodexTheme.textSecondary)
            .fixedSize(horizontal: true, vertical: false)   // 列不折行 (见 ②)
            .frame(maxWidth: .infinity, alignment: align.frameAlignment)
            .padding(.horizontal, Tune.mdTableCellHPadding)
            .padding(.vertical, isHeader ? Tune.mdTableHeaderVPadding : Tune.mdTableRowVPadding)
            .background(isHeader ? CodexTheme.bgElevated : Color.clear)
            .overlay(alignment: .bottom) {
                if !isHeader {
                    Rectangle().fill(CodexTheme.divider).frame(height: 1)
                }
            }
            .textSelection(.enabled)
    }
}

private struct TableViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Streaming cursor

struct StreamingCursor: View {
    @State private var visible: Bool = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(CodexTheme.accent)
            .frame(width: 7, height: 14)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}
