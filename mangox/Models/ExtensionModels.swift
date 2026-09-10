//
//  ExtensionModels.swift
//  P3.11: pi 扩展 (插件) 的扫描投影。无新表——列表 = 目录扫描派生,
//  启停状态持久化在 settings (extensions_disabled, 按 path 记)。
//

import Foundation

enum ExtensionSource: String {
    case managed   // ~/.mangox/extensions/ — MangoX 托管, 完整管理 (spawn 期 --extension 按启用列表加载)
    case global    // ~/.pi/agent/extensions/ — pi 全局自动发现, 只读
    case project   // cwd/.pi/extensions/ — pi 项目自动发现, 只读

    var label: String {
        switch self {
        case .managed: "托管"
        case .global: "全局"
        case .project: "项目"
        }
    }
}

struct ExtensionItem: Identifiable {
    let name: String
    let path: String
    let source: ExtensionSource
    let enabled: Bool
    /// 内置扩展 (mangox-approval): 不可删除/不可停用
    let isBuiltIn: Bool
    var id: String { path }

    static let builtInName = "mangox-approval"
}
