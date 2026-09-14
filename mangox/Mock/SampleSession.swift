//
//  SampleSession.swift
//  Hard-coded mock data driving the UI demo.
//

import Foundation

enum SampleSession {

    // MARK: - Sidebar data (P3.4 收尾: mock 项目/会话已移除, 全部真实持久化)

    static let projects: [ProjectGroup] = []
    static let chats: [ConversationItem] = []

    /// 兼容旧签名: 永远 nil (启动不选中任何会话)。
    static var initialSelectedId: UUID? { nil }
}
