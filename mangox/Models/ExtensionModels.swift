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
        case .managed: L("托管")
        case .global: L("全局")
        case .project: L("项目")
        }
    }
}

struct ExtensionItem: Identifiable {
    let name: String
    let path: String
    let source: ExtensionSource
    let enabled: Bool
    /// 内置扩展 (mangox-approval / mangox-dream): 不可删除/不可停用
    let isBuiltIn: Bool
    var id: String { path }

    /// 该扩展注册出来的工具名 —— 面板在那一行下面缩进展开 (空 = 不展开)。
    var toolNames: [String] = []

    /// **投影项** (P15.7): 磁盘上没有这个文件, 列表里的条目由 App 合成。
    ///
    /// 只有 dream 是这种 —— 它的 `.ts` 只在 dream 那次 fire 才落盘 (双闸门的第一道),
    /// 所以平时 `ls ~/.mangox/extensions` 是看不到它的。详情页的源码预览因此走
    /// `PiRpcTransport.dreamExtensionSource` 常量, **不读文件**。
    /// ⚠️ 「列表有、磁盘没有」是**设计本身**, 不是 bug —— 别顺手把这条投影删掉。
    var isSynthetic: Bool = false

    /// **按需挂载** —— true = 这一项不是恒挂的, 只在那次需要它的运行里挂上。
    ///
    /// ⚠️ 判据是**挂载策略**, 不是 `isBuiltIn`: approval 与 dream 都是内置, 但 approval
    /// **四档恒挂**(给它挂"按需"就是说谎), dream **只在那次 fire 挂**。两者必须分开表达
    /// —— 否则那颗胶囊会比事实说得多 (P15.6b「在说谎」的同一条)。
    ///
    /// 出数据不出文案: 面板据此**不给启停开关**、改挂一颗说明胶囊 (文案在 View 侧)。
    var isOnDemand: Bool = false

    /// 内置扩展名单 —— 不可删除、不可停用。加名字要同时想清楚"它恒挂还是按需"(见 `isOnDemand`)。
    static let builtInNames: Set<String> = ["mangox-approval", "mangox-dream"]

    /// 内置扩展**注册出来的工具名**, 按扩展名查 —— 面板在那一行下面展开它们。
    ///
    /// ⚠️ **真源跟着源码走**: 这些名字定义在 `PiRpcTransport` 里那段扩展 TS 的**旁边**
    /// (`dreamToolNames`), 这里只是"按名字查"的入口。加第二个内置扩展时, 在那边加常量、
    /// 在这里登记一行 —— 漏登记 ⇒ 它跑过一次(磁盘有文件)后就不再展开工具名, 且**零红灯**。
    static let builtInToolNames: [String: [String]] = ["mangox-dream": PiRpcTransport.dreamToolNames]

    /// 内置扩展里**按需挂载**的那几个。不在这张名单里的内置 = **恒挂**（approval 就是）。
    static let builtInOnDemand: Set<String> = ["mangox-dream"]
}
