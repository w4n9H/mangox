//
//  ManagedModel.swift
//  P7-M2: 模型自管真源条目 (settings 页管理, 物化给 pi 消费)。
//  真源在 MangoX, pi 只是第一个消费者 (PI_CODING_AGENT_DIR 物化)。
//

import Foundation

/// 条目来源: preset=预设生成 / custom=手写 baseUrl / legacy=custom_models 三字段表迁入。
enum ManagedModelSource: String, Codable {
    case preset, custom, legacy
}

/// 百万 token 单价 (USD), tiers 按 input 总量阶梯取最高命中档。
struct ModelCost: Hashable, Codable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
    var tiers: [Tier]?

    struct Tier: Hashable, Codable {
        let inputTokensAbove: Double
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }
}

struct ManagedModel: Identifiable, Hashable, Codable {
    let provider: String
    let modelId: String
    var displayName: String
    /// pi 四种流式 API (接口缝 — 未来接别的引擎在此扩枚举)。
    var apiType: String
    /// 是否支持扩展思考 (显式字段 — MiniMax 系 reasoning=true 但 map 为 null, 不能靠 map 有无推导)。
    var reasoning: Bool
    /// nil = 借 pi 内置 provider 定义 (legacy 迁移; 空物化目录下不可用, 实验②)。
    var baseURL: String?
    /// Keychain account (service=com.mangox.model-key); nil = 无 key (Ollama)。v1 语义: key 按 provider 归组。
    var keyRef: String?
    var contextWindow: Int?
    var maxTokens: Int?
    /// ["text"] / ["text","image"]; 第 5 批发送门控消费。
    var inputModalities: [String]
    var cost: ModelCost?
    /// 原样透传物化的 JSON 片段 (thinkingLevelMap 含 null 值, 结构化建模得不偿失)。
    var thinkingLevelMapJSON: String?
    var compatJSON: String?
    var samplingParamsJSON: String?
    var enabled: Bool
    var source: ManagedModelSource
    let createdAt: Date

    /// PK = (provider, modelId), 与 models 表主键一致。
    var id: String { "\(provider)/\(modelId)" }

    var displayNameOrId: String { displayName.isEmpty ? modelId : displayName }

    /// 菜单支持的思考级别 (pi 语义): 非 reasoning 只 off;
    /// reasoning 无 map → 默认 off..high; 有 map → off + map 中非 null 项 (null = 明确不支持)。
    var supportedLevels: [ThinkingLevel] {
        guard reasoning else { return [.off] }
        guard let raw = thinkingLevelMapJSON, let data = raw.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [.off, .minimal, .low, .medium, .high]
        }
        var levels: [ThinkingLevel] = [.off]
        for level in ThinkingLevel.allCases where level != .off {
            if let v = map[level.rawValue] as? String, !v.isEmpty { levels.append(level) }
        }
        return levels
    }

    /// 构造选中/菜单用的 AgentModelInfo (级别按 pi thinkingLevelMap 语义收敛)。
    var asAgentModelInfo: AgentModelInfo {
        AgentModelInfo(provider: provider, id: modelId, name: displayNameOrId,
                       supportedLevels: supportedLevels)
    }

    init(provider: String,
         modelId: String,
         displayName: String = "",
         apiType: String,
         reasoning: Bool = false,
         baseURL: String? = nil,
         keyRef: String? = nil,
         contextWindow: Int? = nil,
         maxTokens: Int? = nil,
         inputModalities: [String] = ["text"],
         cost: ModelCost? = nil,
         thinkingLevelMapJSON: String? = nil,
         compatJSON: String? = nil,
         samplingParamsJSON: String? = nil,
         enabled: Bool = true,
         source: ManagedModelSource = .custom,
         createdAt: Date = .now) {
        self.provider = provider
        self.modelId = modelId
        self.displayName = displayName
        self.apiType = apiType
        self.reasoning = reasoning
        self.baseURL = baseURL
        self.keyRef = keyRef
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.inputModalities = inputModalities
        self.cost = cost
        self.thinkingLevelMapJSON = thinkingLevelMapJSON
        self.compatJSON = compatJSON
        self.samplingParamsJSON = samplingParamsJSON
        self.enabled = enabled
        self.source = source
        self.createdAt = createdAt
    }
}
