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

/// 列宽分配 —— **纯函数**, 出图探针直接拿它当判据件。
///
/// 为什么单独抽出来: "列宽是不是按内容比例"在像素上看不出来 (没有竖线, 只能看文字起始位置),
/// 而这段算法本身是确定的 —— 用真实读数 (need / available) 断言它, 比量像素牢。
enum TableColumnSizing {

    /// - Parameters:
    ///   - need: 每列的"自然宽" = 单行文字宽 + 两侧内边距 (即**不让它折行**所需的宽度)
    ///   - available: 可用宽 (消息列宽)
    ///
    /// 放得下 ⇒ **按 need 的比例放大**: 每列都拿到"内容按比例分到的那一份", 窄列不会被撑成一整条
    /// 空道 (2026-10-20 boss: "第一列只放三个字却占了一半")。
    /// 放不下 ⇒ **先饿死大的**: 凡 need 没超过均分额的列**保住自己的自然宽**, 只让超额的列按比例
    /// 让路。若这里直接全体按比例缩, 一列超长路径就能把旁边两三个字的列挤到折行。
    static func widths(need: [CGFloat], available: CGFloat) -> [CGFloat] {
        let n = need.count
        guard n > 0, available > 1 else { return [] }
        let total = need.reduce(0, +)
        guard total > 0 else { return [] }

        if total <= available {
            return need.map { available * $0 / total }
        }

        let share = available / CGFloat(n)
        let small = need.indices.filter { need[$0] <= share }
        let smallSum = small.reduce(CGFloat.zero) { $0 + need[$1] }
        let bigSum = total - smallSum
        guard bigSum > 0 else { return need }
        let rest = available - smallSum
        return need.map { $0 <= share ? $0 : rest * $0 / bigSum }
    }
}

/// 表格: **铺满消息列宽 · 列宽按内容比例 · 放不下就折行**, 永远不裁内容。
///
/// ⚠️ 2026-10-20 boss「表格显示bug，超出的部分看不到了」—— 上一版是「列不折行 + 横向 ScrollView
///    兜底」，理论上有横滚，实际在聊天列里等于**右侧被裁掉**，三条原因叠在一起：
///    ① 横滚容器（`ScrollView(.horizontal)`）把内容按**无限宽**测量 ⇒ 单元格永远"装得下"
///       ⇒ **折行根本不可能发生**（所以只删 `fixedSize` 没用，宽度约束在容器那一层）；
///    ② `showsIndicators: false` ⇒ 连"这里能滚"的提示都没有；
///    ③ 只有鼠标时横向滚动基本不可发现 —— 用户看到的就是"字被切了"。
///    实测（真 `MarkdownView`，探针 `/tmp/mdtable`）：同一条两列表在 680 与 1000 两档宽度下
///    **总高完全相同（301pt）** ⇒ 一个字都没折行 ⇒ 右侧对半截断。
///
/// ⇒ 现在的判据：
///    ① **不许有横向 `ScrollView`** —— 它在，折行就永远不触发（见上①）。
///    ② 单元格**不许挂 `fixedSize(horizontal:)`** —— 那会强制"列宽 = 内容宽"，把表顶出容器。
///    ③ 单元格必须留 `maxWidth: .infinity` —— `frame(alignment:)` 只有在本视图比列宽窄时才
///       有意义；列宽 == 内容宽时对齐是**空操作**，删了它右对齐/居中就全哑。
///    ④ **列宽按内容比例分配**（`TableColumnSizing`），不吃 Grid 的默认均分 —— 均分会让
///       "三个字的列"和"一句话的列"各占一半，前者空着 80%、后者一直在折行。
///    ⑤ **两个测量都必须"与表内容无关"**，否则表会自己证明自己：
///       · 可用宽挂在 `.frame(maxWidth: .infinity)` **之后** ⇒ 量到的是消息列宽，不是表的宽度；
///       · 自然宽用 `.fixedSize()` 的隐形副本来量 ⇒ 不受列宽回灌影响。
///       踩反了会静默死锁在"内容宽"上：量回内容宽 → 按它铺满 → 永远是内容宽（旧版 `viewport`
///       恒 0 是同一类病，那次是 `.background` + 横滚构成环，SwiftUI 直接丢更新）。
///
/// 体检（探针 `/tmp/mdtable`，五种都逐张看过"内容完整可见"）：两列长句 361pt · 四列数字 151pt ·
/// 六列窄表 146pt（模型名折两行）· 超长路径（按 `/` 折行，不裁）· 单列铺满。
private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let aligns: [MarkdownAlign]

    /// 可用宽 (= 消息列宽)。0 = 第一趟还没量到。
    @State private var available: CGFloat = 0
    /// 每列自然宽 (单行文字宽, 不含内边距); 缺项 = 该列还没量到。
    @State private var natural: [Int: CGFloat] = [:]

    private static let hPad = Tune.mdTableCellHPadding

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        let widths = resolvedWidths
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { idx, cell in
                    sizedCell(cell, index: idx, isHeader: true, widths: widths)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { idx, cell in
                        sizedCell(cell, index: idx, isHeader: false, widths: widths)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) { naturalWidthProbe }
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .overlay(availableWidthProbe)
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
        // ⚠️ 可用宽**取整后再比较**: 列宽之和 = 可用宽, 而列宽又是从它算出来的 ⇒ 亚像素差会
        //    每趟都"变了一点", `onPreferenceChange` 一直触发, 形成布局回环 (门禁跑不完)。
        .onPreferenceChange(TableAvailableKey.self) { measured in
            let rounded = measured.rounded()
            guard rounded > 1, abs(rounded - available) > 0.5 else { return }
            available = rounded
        }
        .onPreferenceChange(TableNaturalKey.self) { natural = $0 }
    }

    // MARK: 列宽

    private var resolvedWidths: [CGFloat] {
        let n = columnCount
        guard n > 0, available > 1,
              (0..<n).allSatisfy({ natural[$0] != nil }) else { return [] }
        let need = (0..<n).map { (natural[$0] ?? 0) + 2 * Self.hPad }
        return TableColumnSizing.widths(need: need, available: available)
    }

    // MARK: 两个测量

    /// 量**可用宽** —— 挂在 `.frame(maxWidth: .infinity)` 之后, 量到的是消息列宽。
    /// ⚠️ `.allowsHitTesting(false)` 不能省: `Color.clear` 照样吃点击 (漏了表格里的选中/点按全哑)。
    private var availableWidthProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: TableAvailableKey.self, value: proxy.size.width)
        }
        .allowsHitTesting(false)
    }

    /// 量**每列自然宽** —— 隐形的 `.fixedSize()` 副本, 按单行排, 与真实列宽无关。
    /// 这里走 SwiftUI 自己的文字排版 (而不是拿 AppKit 量字符串): 单元格正文里可能嵌 `行内代码`
    /// (mono 字体) / 加粗, 那些宽度差只有真排版算得准。
    private var naturalWidthProbe: some View {
        HStack(spacing: 0) {
            ForEach(Array(0..<columnCount), id: \.self) { column in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(cellTexts(in: column).enumerated()), id: \.offset) { _, item in
                        Text(MarkdownInline.attributed(item.text))
                            .font(item.isHeader ? CodexTheme.fontLabel : CodexTheme.fontSmall)
                            .fixedSize()
                    }
                }
                .fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear
                        .preference(key: TableNaturalKey.self, value: [column: proxy.size.width])
                })
            }
        }
        .fixedSize()
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cellTexts(in column: Int) -> [(text: String, isHeader: Bool)] {
        var out: [(text: String, isHeader: Bool)] = []
        if column < header.count { out.append((header[column], true)) }
        for row in rows where column < row.count { out.append((row[column], false)) }
        return out
    }

    // MARK: 单元格

    @ViewBuilder
    private func sizedCell(_ text: String, index: Int, isHeader: Bool,
                           widths: [CGFloat]) -> some View {
        if index < widths.count {
            tableCell(text, index: index, isHeader: isHeader).frame(width: widths[index])
        } else {
            tableCell(text, index: index, isHeader: isHeader)
        }
    }

    private func tableCell(_ text: String, index: Int, isHeader: Bool) -> some View {
        let align: MarkdownAlign = index < aligns.count ? aligns[index] : .leading
        return Text(MarkdownInline.attributed(text))
            .font(isHeader ? CodexTheme.fontLabel : CodexTheme.fontSmall)
            .foregroundStyle(isHeader ? CodexTheme.textPrimary : CodexTheme.textSecondary)
            // ⚠️ `maxHeight: .infinity` 是**承重**的（2026-10-20 允许折行之后才需要）：
            //    同一行里"两行的模型名"和"一行的数字"高度不同，而分隔线是**每个 cell 自己**
            //    在 `.overlay(.bottom)` 画的 ⇒ 不撑满行高就会画出**高低不齐的横线**
            //    （探针 `/tmp/mdtable/z3b.png` 实测差 4pt，一行里两段线错开）。
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: Alignment(horizontal: align.frameAlignment.horizontal,
                                        vertical: .center))
            .padding(.horizontal, Self.hPad)
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

private struct TableAvailableKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TableNaturalKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        for (column, width) in nextValue() { value[column] = width }
    }
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
