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

struct ChatMessage: Identifiable, Hashable, Codable {
    let id: UUID
    let role: MessageRole
    var content: MessageContent
    let timestamp: Date
    var isStreaming: Bool

    init(id: UUID = UUID(),
         role: MessageRole,
         content: MessageContent,
         timestamp: Date = .now,
         isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }
}
