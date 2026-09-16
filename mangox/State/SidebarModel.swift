//
//  SidebarModel.swift
//  P9.1e (#8): 侧栏数据投影 —— 只转发侧栏关心的域状态, 不含 messages/draft 等流式热路径。
//  SidebarView 改订本投影后, 流式每 chunk 的 messages 变更不再触发侧栏全量重算。
//  动作仍经 store 调用 (视图持 store 为普通引用, 不订阅其 objectWillChange)。
//

import Foundation
import Combine

@MainActor
final class SidebarModel: ObservableObject {

    @Published var chats: [ConversationItem] = []
    @Published var projects: [ProjectGroup] = []
    @Published var selectedConversationId: UUID?
    @Published var runningTurns: Set<UUID> = []
    @Published var approvalBlocked: Set<UUID> = []
    @Published var sidebarCollapsed: Bool = false
    // 面板互斥四态 (来自 ChatStore / KnowledgeStore / SchedulerService)
    @Published var showKnowledgePanel: Bool = false
    @Published var showScheduledPanel: Bool = false
    @Published var showExtensionsPanel: Bool = false
    @Published var showSettingsPanel: Bool = false
    // 徽标数据源
    @Published var knowledgePendingCount: Int = 0
    @Published var scheduledTasks: [ScheduledTask] = []

    init(store: ChatStore) {
        store.$chats.assign(to: &$chats)
        store.$projects.assign(to: &$projects)
        store.$selectedConversationId.assign(to: &$selectedConversationId)
        store.$runningTurns.assign(to: &$runningTurns)
        store.$approvalBlocked.assign(to: &$approvalBlocked)
        store.$sidebarCollapsed.assign(to: &$sidebarCollapsed)
        store.$showExtensionsPanel.assign(to: &$showExtensionsPanel)
        store.$showSettingsPanel.assign(to: &$showSettingsPanel)
        store.knowledge.$showKnowledgePanel.assign(to: &$showKnowledgePanel)
        store.knowledge.$knowledgeItems
            .map { $0.filter { $0.status == .pending }.count }
            .assign(to: &$knowledgePendingCount)
        store.scheduler.$showScheduledPanel.assign(to: &$showScheduledPanel)
        store.scheduler.$scheduledTasks.assign(to: &$scheduledTasks)
    }
}
