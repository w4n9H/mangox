//
//  MockMailTransport.swift
//  P10.2a 冒烟: 脚本化收件箱 + 记录 send / 标记已读 / 移 Trash (不连真网)。
//

import Foundation

@MainActor
final class MockMailTransport: MailTransport {
    let accountId: UUID

    /// 脚本化收件箱 (poll 取走后清空, 模拟"已被取走")
    var inbox: [RawMail] = []
    /// 注入 poll 失败 (连接分支断言)
    var pollError: MailTransportError?
    /// testConnection 返回 (nil = 成功)
    var testConnectionResult: String?

    private(set) var sentMails: [OutgoingMail] = []
    private(set) var readMails: [RawMail] = []
    private(set) var trashedMails: [RawMail] = []
    private(set) var pollCount = 0

    init(accountId: UUID) { self.accountId = accountId }

    /// 投递一封 (脚本化)。
    func deliver(_ mail: RawMail) { inbox.append(mail) }

    func poll() async throws -> [RawMail] {
        pollCount += 1
        if let pollError { throw pollError }
        let out = inbox
        inbox = []   // 模拟"取走后不再返回" (幂等闸另有 IMAP UID 游标兜底)
        return out
    }

    func markRead(_ mail: RawMail) async throws { readMails.append(mail) }
    func moveToTrash(_ mail: RawMail) async throws { trashedMails.append(mail) }
    func send(_ mail: OutgoingMail) async throws { sentMails.append(mail) }
    func testConnection() async -> String? { testConnectionResult }
}
