//
//  MarkdownView.swift
//  Renders parsed markdown blocks with Codex styling; streaming cursor at tail.
//

import SwiftUI

struct MarkdownView: View {
    let text: String
    var isStreaming: Bool = false

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
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
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

    private func tableView(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(MarkdownInline.attributed(cell))
                        .font(CodexTheme.fontLabel)
                        .foregroundStyle(CodexTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tune.mdTableCellHPadding)
                        .padding(.vertical, Tune.mdTableHeaderVPadding)
                        .background(CodexTheme.bgElevated)
                        .textSelection(.enabled)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownInline.attributed(cell))
                            .font(CodexTheme.fontSmall)
                            .foregroundStyle(CodexTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tune.mdTableCellHPadding)
                            .padding(.vertical, Tune.mdTableRowVPadding)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(CodexTheme.divider)
                                    .frame(height: 1)
                            }
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
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
