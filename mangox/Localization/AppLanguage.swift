//
//  AppLanguage.swift
//  P10.7 语言: 三态选择 (跟随系统 / 中文 / English) + 运行时取词。
//
//  机制: SwiftUI `Text("中文")` 是 LocalizedStringKey, 查哪张词表由**环境 locale** 决定
//  (实测: 改环境 locale 会让已渲染的 Text 重解析 → 视图层字面量站点零改动)。
//  词表: Resources/<lang>.lproj/Localizable.strings, **中文串即 key**, 表内缺项自动回落中文原文。
//
//  ⚠️ `zh-Hans.lproj` 必须存在 (内容可以是空注释): 请求 zh-Hans 而该表不存在时, Foundation 会
//     回落到 development region 的表 (= en) —— 只加 en.lproj 会让**中文侧整体变英文** (探针 B 组实证)。
//

import Foundation
import SwiftUI

// MARK: - 语言三态

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case en

    var id: String { rawValue }

    /// 注入 environment 的 locale 标识。`.system` 由 `followSystem()` 解析成具体 case, 不会原地递归。
    var localeIdentifier: String {
        switch self {
        case .system: return AppLanguage.followSystem().localeIdentifier
        case .zhHans: return "zh-Hans"
        case .en:     return "en"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    /// 语言名用**它自己的语言**书写 (选了看不懂的语言是死胡同); "跟随系统" 才需要取词。
    var label: String {
        switch self {
        case .system: return L("跟随系统")
        case .zhHans: return "中文"
        case .en:     return "English"
        }
    }

    /// 语言标识前缀 → case。**新增语言只动这里 + 补一份 lproj**。
    static func matching(_ identifier: String) -> AppLanguage? {
        let lower = identifier.lowercased()
        if lower.hasPrefix("zh") { return .zhHans }
        if lower.hasPrefix("en") { return .en }
        return nil
    }

    /// 跟随系统: 按用户语言优先级取第一个我们支持的语言; 都不支持 → 中文 (App 默认语言)。
    static func followSystem(_ preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in preferred { if let hit = matching(identifier) { return hit } }
        return .zhHans
    }

    /// 存值兼容: 缺失 / 未知 → 跟随系统 (不突然翻英文)。
    static func resolve(_ stored: String?) -> AppLanguage {
        guard let stored, let value = AppLanguage(rawValue: stored) else { return .system }
        return value
    }
}

// MARK: - 选择状态 (镜像 AppearanceModel)

/// 写 UserDefaults + 发布变更驱动全树重解析。
final class LanguageModel: ObservableObject {
    static let shared = LanguageModel()
    static let defaultsKey = "appLanguage"

    @Published var current: AppLanguage {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey) }
    }

    private init() { current = .resolve(UserDefaults.standard.string(forKey: Self.defaultsKey)) }

    var locale: Locale { current.locale }
}

// MARK: - 注入容器

/// 挂环境 locale 的根容器。**必须由视图承担** —— App body 只求值一次, 不会跟随变更。
/// 四处独立 SwiftUI 根各包一层: 主窗口 / mini 台 / QuickCapture 面板 / 任意新独立窗口。
struct L10nRoot<Content: View>: View {
    @ObservedObject private var language = LanguageModel.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View { content.environment(\.locale, language.locale) }
}

// MARK: - 取词口 (SwiftUI 字面量不需要它)

/// 域层 / AppKit 上下文的取词口。无 lproj 资源时 (冒烟 harness) 恒等回落 key
/// —— 中文串即 key, 行为与本地化前逐字一致。
/// - Note: 带插值的串写成 `String(format: L("Inbox「%@」: …"), name)`, 占位符进词表。
func L(_ key: String) -> String { L10n.text(key) }

/// 把**运行时字符串**当 key 交给 SwiftUI (字面量不需要它 —— 字面量本身就是 LocalizedStringKey)。
/// 三元表达式 / 变量实参走这里: 值命中词表即翻译, 未命中回落原串 (用户数据如项目名、账号名安全)。
func LK(_ key: String) -> LocalizedStringKey { LocalizedStringKey(key) }

enum L10n {
    private static let lock = NSLock()
    private static var cache: [String: Bundle?] = [:]

    /// 当前语言对应的 lproj bundle; 查不到返回 nil (调用方回落 key)。
    static func bundle(for language: AppLanguage) -> Bundle? {
        let identifier = language.localeIdentifier
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[identifier] { return cached }   // 双层 Optional: 命中"已判定为 nil"也走这里
        let resolved = Bundle.main.path(forResource: identifier, ofType: "lproj")
            .flatMap(Bundle.init(path:))
        cache[identifier] = resolved
        return resolved
    }

    static func text(_ key: String) -> String {
        guard let bundle = bundle(for: LanguageModel.shared.current) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
