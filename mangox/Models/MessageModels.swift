//
//  MessageModels.swift
//

import Foundation

enum MessageRole: String, Codable, Hashable {
    case user, assistant, system
}

/// Message content variants.
/// - text   : plain assistant text
/// - think  : collapsible "思考过程" card (amber left rail)
/// - tool   : tool call card (colored left rail + label)
/// - plan   : plan question card with options
enum MessageContent: Hashable, Codable {
    case text(String)
    case think(String)
    case tool(ToolCall)
    case plan(PlanQuestion)
}

/// P5.0.1: 单次 LLM 调用的用量 (pi message_end 捕获; 轨迹视图/将来成本计算的数据源)。
struct MessageUsage: Hashable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0
    var totalTokens: Int = 0
    /// 消息级模型 (中途切模型不串)。
    var model: String?
    /// 本次调用的 call id (pi responseId)。
    var responseId: String?
}

struct ChatMessage: Identifiable, Hashable, Codable {
    let id: UUID
    let role: MessageRole
    var content: MessageContent
    let timestamp: Date
    var isStreaming: Bool
    /// 该消息产出的 LLM 用量 (assistant 专属; nil = 未上报/旧数据)。
    var usage: MessageUsage?

    init(id: UUID = UUID(),
         role: MessageRole,
         content: MessageContent,
         timestamp: Date = .now,
         isStreaming: Bool = false,
         usage: MessageUsage? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.usage = usage
    }
}
