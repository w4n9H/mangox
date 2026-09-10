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
