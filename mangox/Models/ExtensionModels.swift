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
    /// MangoX **自带**（源码内嵌在 App 里, 见 `builtInNames`）⇒ **不可删除**。
    ///
    /// ⚠️ **它不等于"不可停用"** —— 那是 `unswitchableNames`, 两者在 `mangox-web-search` 上分家:
    /// 它归我们维护（不许删）, 但用户**应该**能把它静音。历史上的坑正是把这两件事挤进这一个字段。
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

    /// **MangoX 自带**扩展名单（源码内嵌在 App 里, 由我们负责落地与维护）⇒ **不可删除**:
    /// 删掉也会在下次重扫 / spawn 时被写回来, 只会变成"打地鼠"（点删除 → 确认 → 它又回来了）。
    ///
    /// ⚠️ **"不可删除" ≠ "不可停用"** —— 见 `unswitchableNames`。这是**两件事**,
    /// 早先挤在 `isBuiltIn` 一个名字里同时当"删除守卫"与"开关守卫", 加 web-search 时才必须拆开:
    /// 它归我们维护（不许删）, 但用户**应该**能把它静音。
    static let builtInNames: Set<String> = ["mangox-approval", "mangox-dream", "mangox-web-search"]

    /// 自带扩展里**连启停开关都不给**的那些 —— approval 四档恒挂、dream 只在那次 fire 挂。
    /// 集差 = **可停用**的自带扩展, 目前只有 `mangox-web-search`（它的挂载由"有没有配 Key"决定,
    /// 但用户仍可主动静音）。
    ///
    /// ⚠️ **开关相关的判据一律用它, 别再用 `isBuiltIn`** —— 后者现在是"不可删除"的意思,
    /// 拿它当开关守卫会把 web-search 变成"不可停用", 而那是**标记比事实说得多**（说谎）。
    static let unswitchableNames: Set<String> = ["mangox-approval", "mangox-dream"]

    /// 内置扩展**注册出来的工具名**, 按扩展名查 —— 面板在那一行下面展开它们。
    ///
    /// ⚠️ **真源跟着源码走**: 这些名字定义在 `PiRpcTransport` 里那段扩展 TS 的**旁边**
    /// (`dreamToolNames` / `webSearchToolNames`), 这里只是"按名字查"的入口。加第二个内置扩展时,
    /// 在那边加常量、在这里登记一行 —— 漏登记 ⇒ 它跑过一次(磁盘有文件)后就不再展开工具名, 且**零红灯**。
    ///
    /// ⚠️ 这里的"builtIn"说的是**源码内嵌在 App 里**（相对于用户导入的第三方扩展）——
    /// 与 `builtInNames`（不可删除）一致, 但**与 `unswitchableNames`（不可停用）无关**:
    /// `mangox-web-search` 在两张名单里的位置**故意不同**（可删除=否, 可停用=是）。
    static let builtInToolNames: [String: [String]] = [
        "mangox-dream": PiRpcTransport.dreamToolNames,
        "mangox-web-search": PiRpcTransport.webSearchToolNames,
    ]

    /// 内置扩展里**按需挂载**的那几个。不在这张名单里的内置 = **恒挂**（approval 就是）。
    static let builtInOnDemand: Set<String> = ["mangox-dream"]

    /// 这一项当前**挂不上**的原因（nil = 正常）。判据必须是**产品能回答的**问题 ——
    /// 用户的选择（"我就是不想开"）走停用态, 不在这里。
    ///
    /// ⚠️ 有值时面板 **不给启停开关**（给了就是"你能开", 而那是个谎）, 改挂一颗说明胶囊、
    /// 文案在 View 侧（出数据不出文案）。加第二档时 `ExtensionsView.trailingBadge` 那个
    /// 分支必须跟着长 —— 漏掉不会有红灯（`switch` 之外还有 `else`）。
    enum BlockedReason: String {
        /// P10.1b: 自建联网搜索扩展没配博查 API Key。挂上它也**必然每次调用都回"未启用"**,
        /// 所以干脆不挂 —— 这是"能由产品回答的问题不要拿去问用户"那条的正面应用。
        case needsBochaKey
    }

    /// 非 nil = 这一项挂不上（原因见 `BlockedReason`）⇒ `enabled` 会被强制压成 false。
    var blockedReason: BlockedReason? = nil
}
