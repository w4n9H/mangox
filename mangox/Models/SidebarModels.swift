//
//  SidebarModels.swift
//  Codex-style sidebar: project groups + flat chats, compact relative timestamps.
//

import Foundation

struct ProjectGroup: Identifiable, Hashable {
    let id: UUID
    let title: String
    /// 工作目录 (P3.4): 有 path 的 project 才能用 Work 工作区 + pi cwd 绑定。
    var path: String?
    var items: [ConversationItem]

    init(id: UUID = UUID(), title: String, path: String? = nil, items: [ConversationItem]) {
        self.id = id
        self.title = title
        self.path = path
        self.items = items
    }
}

struct ConversationItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    let updatedAt: Date
    let unreadCount: Int

    init(id: UUID = UUID(),
         title: String,
         updatedAt: Date = .now,
         unreadCount: Int = 0) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.unreadCount = unreadCount
    }
}

extension Date {
    /// Codex-style compact tag: now / 5m / 4h / 1d / 9/7
    var relativeTag: String {
        let minutes = Int(-timeIntervalSinceNow / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: self)
    }
}
