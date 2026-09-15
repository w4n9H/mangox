//
//  CaptureHotkey.swift
//  P8-T27 快速捕获热键配置 (纯数据, 冒烟可断言)。
//  修饰键用 Carbon 掩码 (RegisterEventHotKey 直接消费); 键码用 kVK_ANSI 码。
//

import Foundation

struct CaptureHotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    // Carbon modifier masks
    static let command: UInt32 = 0x0100   // cmdKey
    static let shift:   UInt32 = 0x0200   // shiftKey
    static let option:  UInt32 = 0x0800   // optionKey
    static let control: UInt32 = 0x1000   // controlKey

    /// 默认 ⌃⌥X (拍板 2026-09-15; ⌥X 实机与输入法/截图类 App 冲突率高;
    /// kVK_ANSI_X = 7, controlKey|optionKey)
    static let fallback = CaptureHotkey(keyCode: 7, modifiers: control | option)

    /// "⌃⌥X" 式展示 (macOS 惯例顺序 ⌃⌥⇧⌘; 字母/数字键名, 其余键码退化为 k<code>)
    var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option  != 0 { s += "⌥" }
        if modifiers & Self.shift   != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    var hasModifier: Bool {
        modifiers & (Self.command | Self.shift | Self.option | Self.control) != 0
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
            35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            49: "Space", 36: "↩", 53: "Esc", 51: "⌫", 48: "Tab",
        ]
        return names[code] ?? "k\(code)"
    }

    // MARK: - Settings KV roundtrip (capture_key_code / capture_modifiers)

    @MainActor
    static func load(persistence: PersistenceStore?) -> CaptureHotkey {
        guard let p = persistence else { return .fallback }
        let code = p.loadSetting(key: "capture_key_code", defaultValue: Int(fallback.keyCode))
        let mods = p.loadSetting(key: "capture_modifiers", defaultValue: Int(fallback.modifiers))
        return CaptureHotkey(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    @MainActor
    func save(persistence: PersistenceStore?) {
        persistence?.saveSetting(key: "capture_key_code", value: Int(keyCode))
        persistence?.saveSetting(key: "capture_modifiers", value: Int(modifiers))
    }
}
