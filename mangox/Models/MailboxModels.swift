//
//  MailboxModels.swift
//  P19: 只剩邮箱账号 (连接参数)。哨兵 / 任务线程 / 拒收日志三组模型随收件档一起删除。
//  ⚠️ 这一层**当前零消费者** —— 留着是给 S7 的邮件 sink 与 P19.1 的邮件通道用, 不是死代码。
//  凭据不进模型 (Keychain: mailbox.acct.<id>.auth)。
//

import Foundation

/// 邮箱账号 — 只管"怎么连"(技术参数)。可配多个; 授权码在 Keychain。
struct MailboxAccount: Codable, Equatable, Identifiable {
    var id: UUID
    var label: String
    /// 该账号**登录的邮箱自身** (IMAP/SMTP 用户名 + 发件 From)。
    /// ⚠️ 它**不是**收件人过滤: 谁能驱动 agent 归 P19 的 `agent_findings.source_id` 管, 别混。
    var address: String
    var presetId: String?          // 来源预设 ("163"/"qq"/…); 自定义为 nil (仅 UI 回显)
    var imapHost: String = ""      // 由预设填充, 仍可手改 (服务商偶有端口调整)
    var smtpHost: String = ""
    var createdAt: Date = Date()

    init(id: UUID = UUID(), label: String, address: String, presetId: String? = nil,
         imapHost: String = "", smtpHost: String = "", createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.address = address
        self.presetId = presetId
        self.imapHost = imapHost
        self.smtpHost = smtpHost
        self.createdAt = createdAt
    }
}
