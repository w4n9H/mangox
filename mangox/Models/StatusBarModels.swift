//
//  StatusBarModels.swift
//  Bottom status bar: model · 思考强度 · 当前会话轮数 · 上下文 · Token · 缓存 · 费用
//

import Foundation

enum ReasoningEffort: String, CaseIterable, Identifiable {
    case off, minimal, low, medium, high, xhigh   // 与 pi set_thinking_level 全集一致
    var id: String { rawValue }

    var displayName: String { rawValue }

    var rank: Int {
        switch self {
        case .off: return 0
        case .minimal: return 1
        case .low: return 2
        case .medium: return 3
        case .high: return 4
        case .xhigh: return 5
        }
    }
}

struct AgentStatus {
    var modelName: String
    var effort: ReasoningEffort
    var turnCount: Int
    var contextPercent: Double
    var tokenUp: Int
    var tokenDown: Int
    var cachePercent: Double
    var costCNY: Double
    var autoMode: Bool
}
