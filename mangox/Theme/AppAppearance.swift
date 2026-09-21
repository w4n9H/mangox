//
//  AppAppearance.swift
//  P10.7: 主题外观三态 (跟随系统 / 浅色 / 深色)。
//
//  为什么从 mangoxApp.swift 外移: 那个文件含 @main, 不参与冒烟编译 (scripts/smoke/run.sh
//  显式排除它), 于是原先靠 scripts/smoke/smokeStubs.swift 复制一份同名类 —— 两处定义是
//  漂移源 (改一处忘另一处 → 冒烟验的行为与 App 真实行为不一致)。外移后单一来源, stub 删除。
//

import AppKit
import SwiftUI

/// 外观三态。rawValue 沿用旧的 "light" / "dark" 字面值 —— 老用户 UserDefaults 里的值直接可读, 无需迁移。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// `nil` = 跟随系统 (`NSApp.appearance = nil` 即交回系统决定)。
    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light:  return .aqua
        case .dark:   return .darkAqua
        }
    }

    /// 显示名。走 `L()` 查词表 —— 域层 `String` 计算属性不吃 `\.environment(\.locale)`,
    /// 必须显式取词; 语言切换后由 SettingsView 的 `@ObservedObject appearance` 触发重绘。
    var label: String {
        switch self {
        case .system: return L("跟随系统")
        case .light:  return L("浅色")
        case .dark:   return L("深色")
        }
    }

    /// 存值解析: 缺失 / 未知值 → `.light`。
    /// 刻意与旧版"读不到就是 light"的行为一致 —— 升级不改变用户观感, 不把所有人突然翻成深色。
    static func resolve(_ stored: String?) -> AppAppearance {
        guard let stored, let value = AppAppearance(rawValue: stored) else { return .light }
        return value
    }
}

/// 主题外观单例: 写 UserDefaults 的同时立即应用到 NSApp,
/// 并通过 @Published 驱动设置页控件刷新 (@AppStorage 在 App struct 上不可靠)。
final class AppearanceModel: ObservableObject {
    static let shared = AppearanceModel()

    static let defaultsKey = "appAppearance"

    @Published var current: AppAppearance {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    private init() {
        current = .resolve(UserDefaults.standard.string(forKey: Self.defaultsKey))
    }

    /// 启动 / 切换时应用外观。`.system` 走 `nil`, 其余按名解析。
    func apply() {
        guard let name = current.nsAppearanceName else {
            NSApp.appearance = nil
            return
        }
        NSApp.appearance = NSAppearance(named: name)
    }
}
