//
//  MailboxModels.swift
//  P10.2 邮箱哨兵: 两层配置 (账号池 = 连接与凭据 / 哨兵 = 策略) + 任务与拒收日志。
//  凭据与共享密钥不进模型 (Keychain: mailbox.acct.<id>.auth / mailbox.sentinel.<id>.secret)。
//

import Foundation

/// 邮箱账号 — 只管"怎么连"(技术参数)。可配多个; 授权码在 Keychain。
struct MailboxAccount: Codable, Equatable, Identifiable {
    var id: UUID
    var label: String
    /// 该账号**登录的邮箱自身** (IMAP/SMTP 用户名 + 回执 From)。**不是发件人过滤** ——
    /// 「谁能驱动 agent」是 `MailboxSentinel.whitelist`, 两者别混 (UI 文案曾写错成"只收这个地址的信")。
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

/// 哨兵 — 管"谁能驱动 + 在哪跑 + 怎么跑"(策略)。与账号 1:1 (account_id UNIQUE)。
struct MailboxSentinel: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var accountId: UUID
    var projectId: UUID?           // 决定 11: nil → NSHomeDirectory()
    var whitelist: [String] = []   // 发件人白名单 (决定 14: 名单外 → 移 Trash + 拒收日志)
    var requireSecret: Bool = true // 密钥闸开关 (决定 13): 关掉 = 只剩白名单 + 服务商 DMARC 过滤
    var pollInterval: Int = 30     // 秒
    var agentMode: AgentMode = .full           // 工具面 (拍板 7)
    var approval: ApprovalMode = .autoJudge    // 裁决 (拍板 8)
    var intranetProbeURL: String = ""          // 可选前置探测 (默认空 = 不探)
    var enabled: Bool = false
    var lastPollAt: Date?
    var lastError: String?

    init(id: UUID = UUID(), name: String, accountId: UUID, projectId: UUID? = nil,
         whitelist: [String] = [], requireSecret: Bool = true, pollInterval: Int = 30,
         agentMode: AgentMode = .full, approval: ApprovalMode = .autoJudge,
         intranetProbeURL: String = "", enabled: Bool = false,
         lastPollAt: Date? = nil, lastError: String? = nil) {
        self.id = id
        self.name = name
        self.accountId = accountId
        self.projectId = projectId
        self.whitelist = whitelist
        self.requireSecret = requireSecret
        self.pollInterval = pollInterval
        self.agentMode = agentMode
        self.approval = approval
        self.intranetProbeURL = intranetProbeURL
        self.enabled = enabled
        self.lastPollAt = lastPollAt
        self.lastError = lastError
    }
}

/// 任务状态机: received (已受理未入队) → queued (排队) → running (在途) → done/failed;
/// blocked = 裁决层拦下 (P10.2a-0 记录的 blocked_reason 回填)。
enum MailboxTaskStatus: String, Codable, CaseIterable {
    case received, queued, running, done, failed, blocked

    var label: String {
        switch self {
        case .received: return "received"
        case .queued:   return "queued"
        case .running:  return "running"
        case .done:     return "done"
        case .failed:   return "failed"
        case .blocked:  return "blocked"
        }
    }
}

/// 任务 / 线程映射 — 一行 = 一个邮件线程 (threadKey 只在哨兵内唯一)。
struct MailboxTask: Codable, Equatable, Identifiable {
    var id: UUID
    var sentinelId: UUID
    var threadKey: String          // 线程根 (首封 Message-ID 或短 id, 见 threadKey 规则)
    var sessionId: UUID?           // 绑定的 MangoX 会话 (建立后回填)
    var projectId: UUID?           // 决定 12: 首封快照, 后续轮读列不读哨兵配置
    var status: MailboxTaskStatus
    var title: String              // 主题清洗后 (已剥 secret)
    var blockedReason: String?
    var lastMessageId: String?     // 该线程最后处理到的 Message-ID (幂等游标)
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), sentinelId: UUID, threadKey: String, sessionId: UUID? = nil,
         projectId: UUID? = nil, status: MailboxTaskStatus = .received, title: String,
         blockedReason: String? = nil, lastMessageId: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.sentinelId = sentinelId
        self.threadKey = threadKey
        self.sessionId = sessionId
        self.projectId = projectId
        self.status = status
        self.title = title
        self.blockedReason = blockedReason
        self.lastMessageId = lastMessageId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 拒收原因 (决定 14) — 非白名单静默处理时留痕的唯一排查线索。
/// `missingIntent` (P10.2a 实做补): 白名单内但主题无 `[MGOX]` 意图标记 —— 同样"发了没反应", 必须留痕。
enum MailboxRejectionReason: String, Codable, CaseIterable {
    case notWhitelisted = "not_whitelisted"
    case missingIntent = "missing_intent"
    case secretMissing = "secret_missing"
    case secretMismatch = "secret_mismatch"

    var label: String {
        switch self {
        case .notWhitelisted: return "发件人不在白名单"
        case .missingIntent:  return "主题缺 [MGOX] 标记"
        case .secretMissing:  return "agent 未配密钥"
        case .secretMismatch: return "密钥不匹配"
        }
    }
}

/// 拒收日志 — 每哨兵只留最近 200 条。
struct MailboxRejection: Codable, Equatable, Identifiable {
    var id: UUID
    var sentinelId: UUID
    var sender: String             // From 地址 (原样保留)
    var subject: String            // 主题摘要 (截断 120 字, 已剥 secret)
    var reason: MailboxRejectionReason
    var messageId: String?
    var at: Date

    init(id: UUID = UUID(), sentinelId: UUID, sender: String, subject: String,
         reason: MailboxRejectionReason, messageId: String? = nil, at: Date = Date()) {
        self.id = id
        self.sentinelId = sentinelId
        self.sender = sender
        self.subject = subject
        self.reason = reason
        self.messageId = messageId
        self.at = at
    }
}
