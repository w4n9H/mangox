//
//  SessionConfig.swift
//  P10.3: 会话级配置快照 — 每会话记住自己的模型/思考级别/模式档位/审批开关。
//  存 sessions.config (JSON blob); 新字段只加属性, 不再动表结构。
//

import Foundation

struct SessionConfig: Codable, Equatable {
    var provider: String
    var modelId: String
    /// nil = 用户未手动选过级别 (恢复时不钉死, 保持探测上报行为)。
    var thinkingLevel: String?
    /// AgentMode.rawValue (minimal / standard / full)。
    var agentMode: String
    var askApproval: Bool
}
