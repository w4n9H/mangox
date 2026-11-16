//
//  WatchSourceModels.swift
//  P19 助理的「来源 → 观察」契约。设计见 docs/P19 §03「来源契约」。
//
//  一条硬边界：**任何来源都不是指令通道**。邮件正文、查询结果、日志只产
//  `WatchObservation`；据来源文本建任务 / 改配置 / 直接 fire 一律禁止 —— 执行入口
//  只有人对 finding 点「采纳」。
//

import Foundation

/// 来源种类。**本版值域只有 `mail`**。
///
/// ⚠️ `project` 故意**不在这里**（§03）: 助理绑定了项目就等于有了项目来源 ——
/// 它由分析段的只读工具（read/grep/find/ls）现场看，既不需要采集器也不需要配置行。
/// 把它也做成一条 source 行，会让「至少一个 enabled 来源」这条校验变得可以用一个
/// 空壳满足。MCP / HTTP 本版不接、**也不预留 kind**：值域里留一个永不实现的 case，
/// 就是给「看着像支持、配了不生效」开口子。
enum WatchSourceKind: String, CaseIterable {
    case mail
}

/// 一条来源配置（落库为 `scheduled_tasks.sources` 的 JSON 数组）。
struct WatchSourceSpec: Identifiable, Equatable, Codable {
    var id: UUID
    /// **持久化的是原始字符串**（不是枚举）。
    ///
    /// 未知值（老库 / 未来版本 / 手改配置）⇒ `resolvedKind == nil` ⇒ `isActive == false`
    /// ⇒ **永不参与采集**，但行还在、UI 上标「不支持」。不崩溃、不静默当成 `project`
    /// —— 后者会让一条本该被跳过的来源变成"看项目"，而人以为自己配的是邮箱。
    var kind: String
    var name: String
    var enabled: Bool = true
    /// 来源自己的配置引用。本版 mail 只认邮箱账号 id。
    var configRef: String?

    var resolvedKind: WatchSourceKind? { WatchSourceKind(rawValue: kind) }
    var isSupported: Bool { resolvedKind != nil }
    /// 采集资格 = 开着的 **且** 类型认识。两种"不采"在 UI 上是两句话，所以分开。
    var isActive: Bool { enabled && isSupported }

    init(id: UUID = UUID(), kind: WatchSourceKind, name: String,
         enabled: Bool = true, configRef: String? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.name = name
        self.enabled = enabled
        self.configRef = configRef
    }
}

/// 采集器的输出单位。`externalId` 只用于来源内幂等；`content` 是**不可信数据**。
struct WatchObservation: Equatable {
    let sourceId: UUID
    let externalId: String
    let title: String
    let content: String
    let observedAt: Date
    let metadata: [String: String]

    init(sourceId: UUID, externalId: String, title: String, content: String,
         observedAt: Date = Date(), metadata: [String: String] = [:]) {
        self.sourceId = sourceId
        self.externalId = externalId
        self.title = title
        self.content = content
        self.observedAt = observedAt
        self.metadata = metadata
    }
}

/// 采集失败的两种性质 —— 区分它们是为了让日志说实话。
enum WatchSourceError: Error, Equatable {
    /// 这条路**本版就不可用**（例: 邮箱 PEEK 未验前不得上线，因为现有 poll 会置已读）。
    /// 它不是"这次失败了"，重试也不会好 ⇒ 不该按偶发错误报。
    case unavailable(String)
    /// 真出错（网络 / 解析 / 权限）。
    case failed(String)

    var text: String {
        switch self {
        case .unavailable(let s): return "不可用: " + s
        case .failed(let s):      return "采集失败: " + s
        }
    }
}

/// 每源每轮的上限（§03 契约，数值是**契约**不是手感）。
enum WatchLimits {
    static let perSourceMaxObservations = 20
    /// 32 KiB 按 **UTF-8 字节**算 —— 与字符数不是一回事，中文内容差三倍。
    static let perSourceMaxContentBytes = 32 * 1024
    /// 注入段里所有来源渲染后的总上限：单源有界，多源相乘仍可能撑爆上下文。
    static let injectedSnapshotMaxBytes = 96 * 1024
}

/// 助理绑定的项目 —— 不是 source 行，但每轮都要让模型知道"你说的是哪个盘"。
struct WatchProjectContext: Equatable {
    let name: String
    let path: String
}
