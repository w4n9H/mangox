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
    /// P6.3.1: 侧问会话标记 — 非 nil = 由该会话 fork 而来 (UI 侧栏徽章 + 快照提示条判定)。
    let sideOf: UUID?

    init(id: UUID = UUID(),
         title: String,
         updatedAt: Date = .now,
         unreadCount: Int = 0,
         sideOf: UUID? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.unreadCount = unreadCount
        self.sideOf = sideOf
    }
}

/// P6.3.1: 当前选中会话的侧问快照信息 (提示条数据源; fork 时刻定格, 不随后续轮次变化)。
struct SideChatInfo: Equatable {
    /// 源会话 id (nil-safe 使用: 源可能已被删除)。
    let parent: UUID
    let parentTitle: String
    /// fork 时源会话已完成的轮数 (提示条 "含 N 轮源会话上下文")。
    let turns: Int
    let at: Date
}

/// P14 (2026-10-10): 侧栏搜索的**纯过滤函数**。
///
/// 为什么放模型层而不是 View 里: "哪些行该留"是可断言的语义, 塞进 `SidebarView` 的
/// `body` 就只能靠肉眼验收 —— 而搜索一旦写松 (例如项目名命中却只留下标题命中的会话),
/// 表现是"少了几行", 不会报任何错。
enum SidebarFilter {

    /// 查询串去空白后是否非空 (即: 是否处于过滤态)。
    static func isFiltering(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 大小写/变音符号不敏感的子串匹配。空查询恒不匹配 (调用方先判 `isFiltering`)。
    static func matches(_ text: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return text.range(of: trimmed,
                          options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// 会话过滤: 不过滤时**原样返回** (含顺序 —— 调用方还要按 updatedAt 排)。
    static func chats(_ chats: [ConversationItem], query: String) -> [ConversationItem] {
        guard isFiltering(query) else { return chats }
        return chats.filter { matches($0.title, query: query) }
    }

    /// 项目过滤 —— 两种命中, 语义不同 (这是本函数唯一的判断, 也是它值得被断言的原因):
    ///   · **项目名命中** → 保留整个项目 (含全部会话): 命中容器时该看到容器全貌。
    ///   · 仅**某个会话**命中 → 保留该项目但**只留命中的会话**: 不该顺带展开无关会话。
    ///   · 两者都没中 → 丢掉该项目 (compactMap 返回 nil)。
    static func projects(_ projects: [ProjectGroup], query: String) -> [ProjectGroup] {
        guard isFiltering(query) else { return projects }
        return projects.compactMap { group in
            if matches(group.title, query: query) { return group }
            let hits = group.items.filter { matches($0.title, query: query) }
            guard !hits.isEmpty else { return nil }
            var copy = group
            copy.items = hits
            return copy
        }
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
