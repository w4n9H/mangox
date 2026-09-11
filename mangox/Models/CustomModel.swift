//
//  CustomModel.swift
//  P5.1: 自定义模型条目 (菜单自主, 运行时借壳 — 设计 §3)。
//  pi 目录条目名与 API 名错位时 (DeepSeek 4.1 实证), 由 MangoX 自己管菜单显示,
//  spawn 照旧 --model provider/id 透传 (pi 对清单外 id 克隆 provider 默认条目元数据)。
//

import Foundation

struct CustomModel: Identifiable, Hashable, Codable {
    /// 必须存在于 pi 目录中的 provider 前缀 (如 deepseek/openai); 否则 pi 直接报错。
    let provider: String
    /// 实际下发的 API 模型 id。
    let modelId: String
    /// 菜单显示名 (空则回落 modelId)。
    var label: String
    let createdAt: Date

    /// PK = (provider, modelId), 与 custom_models 表主键一致。
    var id: String { "\(provider)/\(modelId)" }

    var displayName: String { label.isEmpty ? modelId : label }

    init(provider: String, modelId: String, label: String = "", createdAt: Date = .now) {
        self.provider = provider
        self.modelId = modelId
        self.label = label
        self.createdAt = createdAt
    }

    /// 构造选中用的 AgentModelInfo。
    /// thinking 级别放开为全级别 (pi clampThinkingLevel 会按默认条目收敛, 安全 — 设计 §3.2)。
    var asAgentModelInfo: AgentModelInfo {
        AgentModelInfo(provider: provider, id: modelId, name: displayName,
                       supportedLevels: ThinkingLevel.allCases)
    }
}
