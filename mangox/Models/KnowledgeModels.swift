//
//  KnowledgeModels.swift
//  P3.7 知识库/记忆: 统一数据模型。
//  "记忆" = source 为 .session 的知识条目 (带 originSessionId 溯源), 不建第二套系统。
//  设计见 docs/P3-functional-design.md §3.7。
//

import Foundation

enum KnowledgeScope: String {
    case global
    case project
}

enum KnowledgeSource: String {
    case manual   // 知识面板手动编写
    case session  // 会话"保存为记忆"沉淀 / 提炼候选
}

/// 审核状态: pending = 提炼候选待人工审核 (永不注入); active = 已入库。
/// 与 enabled 正交——enabled 表达用户启停, status 表达是否过了审核闸门。
enum KnowledgeStatus: String {
    case pending
    case active
}

struct KnowledgeItem: Identifiable {
    let id: UUID
    var scope: KnowledgeScope
    /// scope == .project 时指向所属项目; 全局条目为 nil。
    var projectId: UUID?
    var title: String
    var content: String
    var source: KnowledgeSource
    /// source == .session 时指向沉淀来源会话。
    var originSessionId: UUID?
    var enabled: Bool = true
    var status: KnowledgeStatus = .active
    /// 提炼候选的"为什么值得记" (审核卡展示; 采纳时清除)。
    var note: String?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// 编辑副本 (保留 id/createdAt, 刷新 updatedAt)。
    func withUpdated(title: String, content: String, scope: KnowledgeScope, projectId: UUID?) -> KnowledgeItem {
        var copy = self
        copy.title = title
        copy.content = content
        copy.scope = scope
        copy.projectId = projectId
        copy.updatedAt = Date.now
        return copy
    }
}
