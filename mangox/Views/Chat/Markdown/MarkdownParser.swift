//
//  MarkdownParser.swift
//  Block-level markdown parser (zero-dependency).
//  Blocks hand-rolled; inline styling via AttributedString(markdown:).
//

import Foundation

// MARK: - Block model

/// 表格列对齐 (来自分隔行里的 `:` 标记), 口径同 GitHub:
/// `:---` 左 · `:---:` 居中 · `---:` 右 · `---` 左 (缺省)。
/// 分隔行本来就认得 `:`, 但旧实现解析时**把信息丢了** ⇒ 数字列一律左对齐, 读不了位数。
enum MarkdownAlign: Equatable {
    case leading, center, trailing
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(language: String?, code: String)
    case listItem(indent: Int, ordered: Bool, index: Int, text: String)
    case blockquote(text: String)
    case table(header: [String], rows: [[String]], aligns: [MarkdownAlign])
    /// **整行**就是一张图时才成块 (行内 `![](…)` 仍留在段落里, 否则一句话会被拆碎)。
    case image(alt: String, source: String)
    case divider
}

// MARK: - Parser

enum MarkdownParser {

    // MARK: - P9-#7 解析缓存 (真 LRU)
    // 流式期 messages 数组每 chunk 变更 → 全部 MarkdownView 重渲染;
    // 历史消息文本不变 → 命中缓存, 每 chunk 只重解析流式中那一条 (其余全量重解析是 O(n²) 根因)。
    //
    // ⚠️ 必须是**真 LRU** —— 原先手写的"`cache[k]=v; order.append(k); 满了摘队首`"是 FIFO:
    //    历史块每拍命中但顺序不动 ⇒ 照样按插入顺序被流式那条挤出去 ⇒ 反复重解析。
    //    见 `LRUCache` 的类型注释。
    // ⚠️ 解析在**锁外**跑: 原实现 `lock()` 之后才 `parse`, 一条流式长消息解析全程攥着
    //    全局锁, 期间所有 MarkdownView 连"命中缓存"都要排队。
    private static let cache = LRUCache<[MarkdownBlock]>(capacity: 64)

    static func parseCached(_ raw: String) -> [MarkdownBlock] {
        if raw.count > 200_000 { return parse(raw) }   // 超长不进缓存, 限内存
        if let hit = cache.value(for: raw) { return hit }
        let blocks = parse(raw)
        cache.insert(blocks, for: raw)
        return blocks
    }

#if SMOKE
    /// 只给冒烟用: 把缓存对象本身露出来, 判"第二次同文本真的**命中**了", 而不是又解析了一遍。
    /// 判据不能是"两次结果相等"(不缓存也相等), 必须是"这条真的躺在缓存里"。
    static var smokeCache: LRUCache<[MarkdownBlock]> { cache }
#endif

    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = splitLines(raw)
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

            // Image — 整行单张 (`![alt](src)`) 才成块, 见 parseStandaloneImage 的判据
            if let img = parseStandaloneImage(line) {
                flushParagraph()
                blocks.append(.image(alt: img.alt, source: img.source))
                i += 1
                continue
            }

            // Table (header | separator | rows)
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(line)
                let aligns = tableAligns(lines[i + 1], count: header.count)
                i += 2
                var rows: [[String]] = []
                while i < lines.count,
                      lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows, aligns: aligns))
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

    /// 切成**行**（解析要 `[String]`，不能是切片 —— 后面各分支都在建新的 `String`）。
    ///
    /// ⚠️ `components(separatedBy: "\n")` 会把 CRLF 切成 `"行\r"`：那个 `\r` 会一路进到
    ///    渲染面 —— 段落里渲染成一个方框，围栏代码里**重新拼出 `\r\n`**（把代码块那条
    ///    "按行渲染"的路堵掉，见 `CodeHighlighter.splitLines`）。
    ///    所以这里顺手把**行尾**的 `\r` 剥掉。只剥行尾：孤立的 `\r`（进度条中间那种）
    ///    留着 —— 与 `SplitLines.isBreak` 的口径一致，不认它当换行。
    /// ⚠️ 只在真含 `\r` 时才走第二条分支：常见路径（纯 LF）一次额外遍历都不加。
    /// ⚠️ 判"含不含 `\r`"要用 **unicodeScalars**，不能用 `raw.contains("\r")` ——
    ///    `\r\n` 在 String 里是**一个 `Character`**，`"\r"` 不是它的子串（canonical equivalence
    ///    也不认），于是"含 CRLF 的文档"会被判成"不含 `\r`"，剥 `\r` 的分支**静默不执行**
    ///    （2026-11-04 第一次改就是这么错的，被 T-CBL 当场抓住：解析出来仍是 `"a\r\nb\r"`）。
    private static func splitLines(_ raw: String) -> [String] {
        let parts = raw.components(separatedBy: "\n")
        guard raw.unicodeScalars.contains(where: { $0 == "\r" }) else { return parts }
        return parts.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

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

    /// 分隔行的 `:` 标记 → 每列对齐。**列数必须与表头对齐** (多则截、少则补 leading),
    /// 否则渲染时按下标取对齐会越界或错列 —— 而 `| a | b |` 与 `|---|---|` 的列数
    /// 在真实模型输出里并不保证一致。
    private static func tableAligns(_ separator: String, count: Int) -> [MarkdownAlign] {
        var out: [MarkdownAlign] = tableCells(separator).map { cell in
            let lead = cell.hasPrefix(":")
            let trail = cell.hasSuffix(":")
            if lead && trail { return .center }
            if trail { return .trailing }
            return .leading
        }
        if out.count < count {
            out.append(contentsOf: Array(repeating: MarkdownAlign.leading, count: count - out.count))
        } else if out.count > count {
            out = Array(out.prefix(count))
        }
        return out
    }

    /// 整行就是一张图才成块 —— 判据: 去除首尾空白后为 `![alt](src)` 且 src 非空。
    /// 只认**独占一行**的形态: 行内图若也成块, 一句话会被拆成"文字 / 图 / 文字"三段,
    /// 阅读顺序与气泡高度都变差。尖括号包裹的 `![a](<path with space>)` 一并支持。
    private static func parseStandaloneImage(_ line: String) -> (alt: String, source: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("!["), t.hasSuffix(")"), let close = t.firstIndex(of: "]") else { return nil }
        let afterClose = t.index(after: close)
        guard afterClose < t.endIndex, t[afterClose] == "(" else { return nil }
        let alt = String(t[t.index(t.startIndex, offsetBy: 2)..<close])
        var source = String(t[t.index(after: afterClose)..<t.index(before: t.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("<"), source.hasSuffix(">"), source.count > 2 {
            source = String(source.dropFirst().dropLast())
        } else if let space = source.firstIndex(of: " ") {
            source = String(source[..<space])   // 去掉 `"title"` 尾巴
        }
        guard !source.isEmpty, source.count < 4096 else { return nil }
        return (alt, source)
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

// MARK: - 对齐映射

extension MarkdownAlign {
    /// 列内对齐 → SwiftUI 的 frame 对齐。
    var frameAlignment: Alignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
}
