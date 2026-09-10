//
//  MarkdownParser.swift
//  Block-level markdown parser (zero-dependency).
//  Blocks hand-rolled; inline styling via AttributedString(markdown:).
//

import Foundation

// MARK: - Block model

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(language: String?, code: String)
    case listItem(indent: Int, ordered: Bool, index: Int, text: String)
    case blockquote(text: String)
    case table(header: [String], rows: [[String]])
    case divider
}

// MARK: - Parser

enum MarkdownParser {

    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                flushParagraph()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing fence (or EOF)
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang,
                                         code: code.joined(separator: "\n")))
                continue
            }

            // Heading
            if line.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil {
                flushParagraph()
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = line.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: rest))
                i += 1
                continue
            }

            // Horizontal rule
            if line.range(of: "^\\s*(-{3,}|\\*{3,})\\s*$", options: .regularExpression) != nil {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }

            // Table (header | separator | rows)
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count,
                      lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // List item
            if let markerRange = line.range(of: "^\\s*(?:[-*+]|\\d+\\.)\\s+",
                                            options: .regularExpression) {
                flushParagraph()
                let indent = line.prefix(while: { $0 == " " }).count / 2
                let marker = String(line[markerRange]).trimmingCharacters(in: .whitespaces)
                let ordered = !"-*+".contains(marker)
                let index = ordered ? Int(marker.dropLast()) ?? 1 : 0
                let rest = line[markerRange.upperBound...].trimmingCharacters(in: .whitespaces)
                blocks.append(.listItem(indent: indent, ordered: ordered, index: index, text: rest))
                i += 1
                continue
            }

            // Blockquote
            if line.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    quote.append(String(lines[i].dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(text: quote.joined(separator: "\n")))
                continue
            }

            // Blank line / paragraph accumulation
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Helpers

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("|") && t.contains("-")
            && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Inline styling

import SwiftUI

enum MarkdownInline {

    /// Bold / italic / strikethrough / `code` / links → AttributedString.
    static func attributed(_ text: String) -> AttributedString {
        let attr: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attr = parsed
        } else {
            attr = AttributedString(text)
        }
        return styleInlineCode(attr)
    }

    private static func styleInlineCode(_ source: AttributedString) -> AttributedString {
        var attr = source
        let runs = Array(attr.runs)
        for run in runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].inlinePresentationIntent = nil
            attr[run.range].font = CodexTheme.fontMonoSm
            attr[run.range].foregroundColor = CodexTheme.textMono
            // 半透明底: 紧贴文字也柔和 (实色 bgElevated 的方块感是"粗糙"来源之一)
            attr[run.range].backgroundColor = CodexTheme.bgPill.opacity(0.55)
        }
        return attr
    }
}
