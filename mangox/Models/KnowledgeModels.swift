//
//  KnowledgeModels.swift
//  P3.7 知识库/记忆: 统一数据模型。
//  "记忆" = source 为 .session 的知识条目 (带 originSessionId 溯源), 不建第二套系统。
//  设计见 docs/P3-functional-design.md §3.7。
//

import Foundation

enum KnowledgeScope: String {
    case global
    case project
}

enum KnowledgeSource: String {
    case manual   // 知识面板手动编写
    case session  // 会话"保存为记忆"沉淀 / 提炼候选
}

/// 审核状态: pending = 提炼候选待人工审核 (永不注入); active = 已入库。
/// 与 enabled 正交——enabled 表达用户启停, status 表达是否过了审核闸门。
enum KnowledgeStatus: String {
    case pending
    case active
}

/// P11.1: 条目种类 —— 五类 (标签两字, 见 P11 文档 §4.3)。
///
/// `rawValue` 落库, **不可改** (改 = 存量条目错类)。
///
/// - Important: `tag` 是**中文原文且恒不本地化** —— 它有两个用途, 都必须吃原文:
///   ① 拼进 L0 注入块 (`KnowledgeStore.line(_:)`), 是**给模型看的契约 token**, 不是 UI 文案;
///   ② 作为 l10n 词表的 key, 由 UI 侧 `L()` / `LK()` 取词。
///   若在这里就 `L()`, 用户切换界面语言会**改掉注入进 prompt 的字节** —— 既破坏稳定段的
///   逐字节稳定性 (守卫 12), 又让同一个 agent 的行为被用户的界面语言决定。故只给原文。
enum KnowledgeKind: String, CaseIterable {
    case persona   // 我是谁 · 态度与边界
    case user      // 用户是谁 · 怎么配合
    case rule      // 常驻的硬约束, 永远成立
    case fact      // 稳定事实: 环境 / 技术栈 / 项目结构
    case lesson    // 从一次具体事故长出来的条件反射 (带 trigger)

    /// 两字标签 (一字标签五个里四个要靠解释 ⇒ 那是谜语不是标签)。**中文原文, 不本地化**。
    var tag: String {
        switch self {
        case .persona: return "人格"
        case .user:    return "用户"
        case .rule:    return "硬规"
        case .fact:    return "事实"
        case .lesson:  return "教训"
        }
    }

    /// 稳定段成员 = 身份 / 关系 / 硬规: 排在最前且**不参与降级截尾** (P11 §2.2 / §3.2)。
    var isStableSegment: Bool { self == .persona || self == .user || self == .rule }
}

/// P11.1: 注入层 —— L0 每轮进 prompt / L1 落文件按需读。
///
/// - Note: `tag` 与 `KnowledgeKind.tag` **同形但不同责**: kind 的标签是**注入块的契约 token**
///   (见上), layer 的标签**不进注入块** (组装只写 kind), 纯 UI 措辞 —— 所以它可以、也应该
///   用用户自己的话 (`每轮都带上 / 需要时才查`), 而不是 `每轮注入 / 按需取用` 这种内部术语。
///   两条都保持"中文原文 + 只在 UI 侧 `L()` 取词"的同一形态。
enum KnowledgeLayer: String, CaseIterable {
    case always     // L0 常驻
    case ondemand   // L1 按需 (不进 prompt)

    var tag: String {
        switch self {
        case .always:   return "每轮都带上"
        case .ondemand: return "需要时才查"
        }
    }
}

/// ~~P11.1 敏感档~~ —— **已于 2026-09-22 (P11.2c) 删除**。
///
/// 删的依据是**可证等价**, 不是口味: `local` 与 `layer == .ondemand` 逐位同效 ——
/// 都不进 prompt (`isResident == false`)、都落 L1 文件、都计入"需要时才查"的计数,
/// 唯一差别只是 L1 文件 frontmatter 里那一行 `sensitivity:`, 而读它的 agent 本来就已经
/// 把正文读到手了 ⇒ **零行为后果**。两个开关做同一件事, 而 UI 上它们还隔着一个 `priority`
/// 块: 用户得同时理解两个概念才能预测"这条到底进不进 prompt"。
///
/// 表达能力一条没少 (判据统一收敛到 `isResident`)。留本注是为了后来的读者不必再推一遍 ——
/// 若将来真要"本地读 / 可外发"这层语义, 那该是**新的**语义 (比如"可否出现在导出/同步里"),
/// 而不是把它重新塞回 `isResident` 这个开关里。
struct KnowledgeItem: Identifiable {
    let id: UUID
    var scope: KnowledgeScope
    /// scope == .project 时指向所属项目; 全局条目为 nil。
    var projectId: UUID?
    var title: String
    var content: String
    var source: KnowledgeSource
    /// source == .session 时指向沉淀来源会话。
    var originSessionId: UUID?
    var enabled: Bool = true
    var status: KnowledgeStatus = .active
    /// 提炼候选的"为什么值得记" (审核卡展示; 采纳时清除)。
    var note: String?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    // MARK: - P11.1 增列

    var kind: KnowledgeKind = .fact
    /// 新建条目**默认生效 (每轮都带上)**。
    ///
    /// - Important: P11.2d (2026-09-22) 起编辑器不再暴露层选择器, 于是这条缺省**不再是
    ///   "某个没人改的初值", 而是"新建知识"的实际行为** —— 改它就等于改产品行为。
    ///   取 `.always` 是为了对齐 P11 **之前**的老行为 (那时存进 `knowledge_items` 的每一条
    ///   都进 prompt): 用户"记下它"的意图就是"让它知道", 而落成 `.ondemand` 会让新知识
    ///   **静默不进 prompt** —— 那正是我删 `trigger` / `counterfactual` 时用的判据
    ///   ("填了不生效"比"没有"更坏), 不能反过来在自己身上犯。
    /// - Note: 与 `PersistenceStore.loadKnowledge` 的回落值 (`?? .ondemand`) **有意不同**:
    ///   那个回答的是另一个问题 —— "升级前没有 `layer` 列的旧行怎么算"。那一处保持不动
    ///   (P11.1 的决定): 迁移的默认值不该顺手把一个存量库的条目全推进 prompt。
    var layer: KnowledgeLayer = .always
    /// L0 内排序与**超限降级的唯一依据** (越大越靠前)。
    ///
    /// 合法区间见 `priorityRange` —— **越界值由 `clampedPriority(_:)` 归一化**, 不是报错。
    var priority: Int = 0
    /// 全局唯一的条目身份键; persona pack 已占用的 key 禁止出现在 DB (设计上不允许冲突)。
    var key: String?
    /// 仅 `kind=lesson`: 文件 glob / 命令前缀, 驱动按事件回灌 (P11.3)。
    ///
    /// - Note: **P11.2c 起 UI 不再暴露** —— 它要的驱动逻辑 (教训门 / 前瞻注入) 在 P11.3,
    ///   现在填了不生效。"填了不生效的输入框"比"没有这个框"更坏: 用户以为它work。
    ///   字段与落库保留, 编辑既有条目时**原值不动** (见 `withUpdated`)。
    var trigger: String?
    /// 仅 `kind=lesson`: **"什么情况下这条不适用"** (入库强制, P11.3 起校验)。同 `trigger`, UI 暂撤。
    var counterfactual: String?
    var hitCount: Int = 0
    var lastHitAt: Date?

    /// 是否进注入块 (L0 常驻)。**判据只此一处** —— 左列分组 / 载荷条计数 / L1 落盘都读它,
    /// 各写各的判据就会让"条上说 3 条、左列只列 2 条"这种不一致重新长出来。
    var isResident: Bool { layer == .always }

    /// `priority` 的合法区间 —— **只在这里定义一次** (步进器边界 / 可编辑字段的钳制 /
    /// 写入路径的归一化三处都读它; 各写一个数字 = 迟早不一致)。
    ///
    /// 取值理由: 它是**相对**排序键, 用不到 5 位数; 但也不该小到让"排到最后"要靠反复点击。
    /// 999 留足余量, 且冒烟里 `priority: 1...200` 的降级构造原样成立。
    static let priorityRange = 0...999

    /// 越界钳制。**钳而不拒**: 它是可归一化的排序键, "因为数字大了点就拒绝一次保存"
    /// 比"钳到边界"更糟 (同 `ScheduledView.timeField` 的整数域外钳制)。
    static func clampedPriority(_ value: Int) -> Int {
        min(max(value, priorityRange.lowerBound), priorityRange.upperBound)
    }

    /// 编辑副本 (保留 id/createdAt, 刷新 updatedAt)。
    ///
    /// - Note: 只覆盖**编辑器真能改的**那几维。`kind` / `layer` / `priority` (P11.2d) 与
    ///   `key` / `trigger` / `counterfactual` (P11.2c) 都已从 UI 撤下, 故**不在参数里 ——
    ///   保持原值**。这条边界要守住: "撤下输入框" ≠ "清空数据", 编辑一条旧条目不该把它
    ///   已定的种类 / 层 / 排序, 或已填的教训触发面悄悄抹掉 (那是静默的数据丢失)。
    ///   反例长什么样: 一条 `kind=lesson` + `layer=always` 的老条目, 只因改了错别字就被
    ///   重置成 `fact` + 默认层 —— 而 `kind` 是**注入块的契约 token**, 模型下一轮看到的
    ///   标签都会被改掉。
    ///
    /// - Important: `layer` 的**新建缺省**在 `var layer` 上 (`.always`), 不在这里 ——
    ///   本函数永远不该碰它。要"改层"就只在创建时决定, 见 `KnowledgeItem.layer` 的注释。
    func withUpdated(title: String, content: String, scope: KnowledgeScope, projectId: UUID?) -> KnowledgeItem {
        var copy = self
        copy.title = title
        copy.content = content
        copy.scope = scope
        copy.projectId = projectId
        copy.updatedAt = Date.now
        return copy
    }
}
