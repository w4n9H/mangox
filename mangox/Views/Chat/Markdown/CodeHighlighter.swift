//
//  CodeHighlighter.swift
//  Lightweight regex-based code highlighting mapped to Codex palette.
//

import SwiftUI

enum CodeHighlighter {

    /// Token colors: comment(1) string(2) keyword(3) number(4)
    static func highlight(_ code: String, language: String?) -> AttributedString {
        var attr = AttributedString(code)
        let pattern = masterPattern(for: language)
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators])
        else { return attr }

        let ns = code as NSString
        for m in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(m.range, in: attr) else { continue }
            let color: Color
            var italic = false
            if m.range(at: 1).location != NSNotFound {
                color = CodexTheme.textTertiary
                italic = true
            } else if m.range(at: 2).location != NSNotFound {
                color = CodexTheme.toolDone
            } else if m.range(at: 3).location != NSNotFound {
                color = CodexTheme.info
            } else {
                color = CodexTheme.thinking
            }
            attr[range].foregroundColor = color
            if italic { attr[range].inlinePresentationIntent = .emphasized }
        }
        return attr
    }

    // MARK: - P9-#7 高亮缓存 (LRU)

    // 流式期 messages 数组每 chunk 变更 → 全部 CodeBlockView 重渲染;
    // 已完成代码块命中缓存后只剩流式中那一个块重算。
    private static let cacheLock = NSLock()
    private static var cache: [String: AttributedString] = [:]
    private static var order: [String] = []
    private static let cacheLimit = 32

    static func highlightCached(_ code: String, language: String?) -> AttributedString {
        if code.count > 100_000 { return highlight(code, language: language) }   // 超长不进缓存
        let key = "\(language ?? "-")\u{1}\(code)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        let attr = highlight(code, language: language)
        cache[key] = attr
        order.append(key)
        if order.count > cacheLimit, let evict = order.first {
            order.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return attr
    }

    // MARK: - 逐行版 (长代码块专用)

    private static var lineCache: [String: [AttributedString]] = [:]
    private static var lineOrder: [String] = []

    /// 按行切好的高亮结果 —— **长代码块**走这一版。
    ///
    /// ⚠️ 为什么不直接用 `highlightCached` 再拼一个 `Text`: 见 `Tune.codeBlockSplitLines`。
    ///    一句话 —— 一个 `Text` 承载 124 行 × 最长 522 字符的横滚文本, 排版是平方级的。
    /// 键与整块缓存**分开存**(多一个 `L` 前缀), 因为两者类型不同, 混在一个字典里要擦类型。
    static func highlightLinesCached(_ code: String, language: String?) -> [AttributedString] {
        if code.count > 100_000 { return splitLines(highlight(code, language: language)) }
        let key = "L\u{1}\(language ?? "-")\u{1}\(code)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = lineCache[key] { return hit }
        let lines = splitLines(highlight(code, language: language))
        lineCache[key] = lines
        lineOrder.append(key)
        if lineOrder.count > cacheLimit, let evict = lineOrder.first {
            lineOrder.removeFirst()
            lineCache.removeValue(forKey: evict)
        }
        return lines
    }

    /// 按换行把 AttributedString 切成多段, **属性跟着行一起走**。
    ///
    /// ⚠️ 只能按 range 切, 不能"拆成 String 再逐行重新高亮": 高亮用的是
    ///    `.dotMatchesLineSeparators`, 多行注释 / 跨行字符串的属性是**跨行连续**的 ——
    ///    逐行重来会把它切成一段段的孤立 token, 颜色当场变。
    /// ⚠️ 空行要保留成空段(不是丢掉): 丢掉行就等于把代码里的空行吃了, 行号也对不上。
    static func splitLines(_ attr: AttributedString) -> [AttributedString] {
        var out: [AttributedString] = []
        var start = attr.startIndex
        var i = attr.startIndex
        while i < attr.endIndex {
            if attr.characters[i] == "\n" {
                out.append(AttributedString(attr[start..<i]))
                start = attr.index(afterCharacter: i)
            }
            i = attr.index(afterCharacter: i)
        }
        out.append(AttributedString(attr[start..<attr.endIndex]))
        return out
    }

    // MARK: - Pattern

    private static func masterPattern(for language: String?) -> String {
        let lang = (language ?? "").lowercased()
        let hashCommentLangs: Set<String> = ["python", "py", "bash", "sh", "shell",
                                             "yaml", "yml", "toml", "ruby", "r"]
        var comment = #"(//[^\n]*|/\*[\s\S]*?\*/)"#
        if hashCommentLangs.contains(lang) {
            comment = #"(//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)"#
        }
        let strings = #"(\"(?:[^\"\\\n]|\\.)*\"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`)"#
        let keywords = #"(\b(?:\#(keywords(for: lang)))\b)"#
        let numbers = #"(\b\d+(?:\.\d+)?\b)"#
        return [comment, strings, keywords, numbers].joined(separator: "|")
    }

    private static func keywords(for lang: String) -> String {
        let map: [String: String] = [
            "swift": "func let var if else for while return struct class enum import switch case break continue guard defer extension protocol static private public internal true false nil throws async await self init where",
            "javascript": "function const let var if else for while return class import export from new async await true false null undefined this typeof",
            "js": "function const let var if else for while return class import export from new async await true false null undefined this typeof",
            "typescript": "function const let var if else for while return class import export from new async await true false null undefined this typeof interface type enum",
            "ts": "function const let var if else for while return class import export from new async await true false null undefined this typeof interface type enum",
            "python": "def class if elif else for while return import from True False None lambda with as try except print not and or in is",
            "py": "def class if elif else for while return import from True False None lambda with as try except print not and or in is",
            "bash": "if then else fi for do done echo export function return local while case esac sudo cd",
            "sh": "if then else fi for do done echo export function return local while case esac sudo cd",
            "shell": "if then else fi for do done echo export function return local while case esac sudo cd",
            "json": "true false null",
            "glsl": "void float int bool vec2 vec3 vec4 mat2 mat3 mat4 uniform varying attribute return if else for while precision highp mediump lowp in out discard const",
            "c": "void int float char double if else for while return struct typedef const static unsigned signed sizeof switch case break default include define",
            "cpp": "void int float char double if else for while return class struct template typename const static namespace using switch case break default include define public private protected",
        ]
        return map[lang]
            ?? "true false null nil if else for while return func def function let var const import class"
    }
}
