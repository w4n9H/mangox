//
//  MailTransport.swift
//  P10.2a: 收件/发件抽象 — **按账号实例化** (连接参数与凭据都在账号上), 哨兵只提供策略。
//  生产实现 = CurlMailTransport (P10.2c); 冒烟 = MockMailTransport (不连真网)。
//

import Foundation

/// 一封来信 (MimeParser 产物 / Mock 构造)。保留原始形态, 清洗在鉴权链之后做。
struct RawMail: Equatable {
    /// IMAP UID (标记已读/移动用); nil = 该实现不支持。
    var uid: Int64?
    /// 已规范化 (去尖括号 + trim) 的 Message-ID —— 线程键与幂等游标都用它。
    var messageId: String
    var inReplyTo: String?
    var references: [String]
    /// 发件人地址 (原样; 白名单闸自行归一大小写)
    var from: String
    var subject: String
    /// 首个 text/plain (未清洗); 纯 HTML 邮件为空 → 上层回执"请以纯文本发送"
    var body: String
    var date: Date?

    init(uid: Int64? = nil, messageId: String, inReplyTo: String? = nil,
         references: [String] = [], from: String, subject: String, body: String,
         date: Date? = nil) {
        self.uid = uid
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.from = from
        self.subject = subject
        self.body = body
        self.date = date
    }
}

/// 待发回执 (P10.2b 组装; 本批次只定类型供协议签名)。
struct OutgoingMail: Equatable {
    var to: String
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: [String] = []
    /// MangoX 自带 `<task-<id8>@mangox.local>` (§3.3 链路闸的锚点)
    var messageId: String?
    var attachments: [MailAttachment] = []
}

struct MailAttachment: Equatable {
    var filename: String
    var mimeType: String
    var data: Data
}

enum MailTransportError: Error, Equatable {
    case notConfigured(String)   // 缺 host / 缺凭据
    case connection(String)      // 连接或认证失败
    case parse(String)           // 解析失败
    case send(String)

    /// 用户可见错误文案 (进 setNotice / 表单错误) → 走 L()。落库面不用它。
    var label: String {
        switch self {
        case .notConfigured(let s): return String(format: L("未配置: %@"), s)
        case .connection(let s):    return String(format: L("连接失败: %@"), s)
        case .parse(let s):         return String(format: L("解析失败: %@"), s)
        case .send(let s):          return String(format: L("发送失败: %@"), s)
        }
    }
}

/// 收件/发件抽象。**按账号实例化**: 连接参数与凭据都挂在账号上。
/// **纪律: 只 poll INBOX** —— 它是鉴权主防线的前提 (借力服务商 SPF/DKIM/DMARC 过滤),
/// 一旦改为也看垃圾箱, 主防线立刻失效 (见 P10.2 拆解 §四)。
@MainActor
protocol MailTransport: AnyObject {
    var accountId: UUID { get }

    /// 拉取 INBOX 未读邮件 (已处理过的由上层幂等闸兜住)。
    func poll() async throws -> [RawMail]
    /// 标记已读 (未过闸的邮件不重复处理)。
    func markRead(_ mail: RawMail) async throws
    /// 移入 Trash (决定 14: 非白名单静默处理; **不用 EXPUNGE 硬删**, 留可逆余地)。
    func moveToTrash(_ mail: RawMail) async throws
    /// 发送回执 (P10.2b 起使用)。
    func send(_ mail: OutgoingMail) async throws
    /// Settings "测试连接" 按钮: nil = 成功; 非 nil = 错误描述。
    func testConnection() async -> String?
}
