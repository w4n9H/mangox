//
//  MailboxCredentialStore.swift
//  P10.2a: 邮箱凭据缝 —— 授权码与共享密钥走 Keychain, 不进 SQLite 模型。
//  协议化便于冒烟注入内存实现 (对齐 ModelKeyStore 模式); 真 Keychain 实现 P10.2d 接 Settings。
//

import Foundation
import Security

protocol MailboxCredentialStore: AnyObject {
    /// 账号授权码 (IMAP/SMTP 共用; 163/QQ 等"授权码制"邮箱)。
    func accountAuth(accountId: UUID) -> String?
    func setAccountAuth(_ value: String?, accountId: UUID) throws
    /// 哨兵共享密钥 (决定 13: 首封主题里那串 `<secret>`)。
    func sentinelSecret(sentinelId: UUID) -> String?
    func setSentinelSecret(_ value: String?, sentinelId: UUID) throws
}

/// Keychain 实现: service = com.mangox.mailbox, account = 文档约定键名。
final class KeychainMailboxCredentialStore: MailboxCredentialStore {
    let service = "com.mangox.mailbox"

    static func accountKey(_ id: UUID) -> String { "mailbox.acct.\(id.uuidString).auth" }
    static func secretKey(_ id: UUID) -> String { "mailbox.sentinel.\(id.uuidString).secret" }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String?, account: String) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }
        let data = Data(value.utf8)
        if read(account) != nil {
            let status = SecItemUpdate(baseQuery(account) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func accountAuth(accountId: UUID) -> String? { read(Self.accountKey(accountId)) }
    func setAccountAuth(_ value: String?, accountId: UUID) throws {
        try write(value, account: Self.accountKey(accountId))
    }
    func sentinelSecret(sentinelId: UUID) -> String? { read(Self.secretKey(sentinelId)) }
    func setSentinelSecret(_ value: String?, sentinelId: UUID) throws {
        try write(value, account: Self.secretKey(sentinelId))
    }
}

/// 冒烟/测试用内存实现 (不碰真 Keychain: 无签名的冒烟二进制访问 Keychain 不可靠)。
final class InMemoryMailboxCredentialStore: MailboxCredentialStore {
    private var accounts: [UUID: String] = [:]
    private var secrets: [UUID: String] = [:]

    func accountAuth(accountId: UUID) -> String? { accounts[accountId] }
    func setAccountAuth(_ value: String?, accountId: UUID) throws {
        accounts[accountId] = value
    }
    func sentinelSecret(sentinelId: UUID) -> String? { secrets[sentinelId] }
    func setSentinelSecret(_ value: String?, sentinelId: UUID) throws {
        secrets[sentinelId] = value
    }
}
