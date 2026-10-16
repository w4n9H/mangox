//
//  AppVersion.swift
//  侧栏展示的当前版本 —— 真源 = Info.plist 的 CFBundleShortVersionString。
//

import Foundation

/// 当前 App 版本（展示用，形如 `v0.1.21`）。
///
/// ⚠️ **不许在这里写死版本号。** 它显示的正是用户用来判断「这次升级到底成没成」的东西 ——
/// 一个手写常量会在下次发版时漂掉，而**显示一个假的旧版本比不显示更糟**（用户会以为没升级，
/// 转身去重装）。真源链路：
///
///     MARKETING_VERSION (project.pbxproj, 发版时改的 6 处)
///       → CFBundleShortVersionString (Info.plist, 构建期注入)
///       → 这里读出来 → 侧栏那行小字
///
/// 抽成「纯函数 + 薄壳」两层是为了**可断言**：纯函数那半不依赖运行环境里有没有 Info.plist，
/// 冒烟能直接钉住它的行为（见 smokeMain 的 T-UI 那组）。
enum AppVersion {

    /// 把 Info.plist 的原始版本串变成展示串。
    ///
    /// 空串与 nil **都**回落 `dev`：非 app 环境（冒烟编出来的 Swift 命令行二进制、离屏预览
    /// harness）没有 Info.plist。这里明说「没有版本」，**不假装有** —— 回落成 `v0.0.0`
    /// 会让「没读到」和「真的是这个版本」长得一模一样，而这两件事正需要被分开。
    static func formatted(_ version: String?) -> String {
        guard let v = version, !v.isEmpty else { return "dev" }
        return "v\(v)"
    }

    /// 当前进程所属 bundle 的版本。在 .app 里 = Info.plist 的真值；在冒烟里 = `dev`。
    static var display: String {
        formatted(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
}
