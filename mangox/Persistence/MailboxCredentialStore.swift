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

/// 钥匙串实现 —— **走 `SecretVault`（一个条目）**，不再一个账号一个条目（2026-11-25）。
/// 键名沿用老的 account 名（`mailbox.acct.<id>.auth` / `mailbox.sentinel.<id>.secret`），
/// 迁移时直接拿它去读老位置，不需要第二张对照表。
final class KeychainMailboxCredentialStore: MailboxCredentialStore {

    /// 冒烟注入缝（与 `KeychainModelKeyStore.keyStoreOverride` 同款）。
    /// 无签名的冒烟二进制读钥匙串会弹授权框 + `SecItemCopyMatching` 一直等答复 ⇒ 挂死。
    nonisolated(unsafe) static var override: MailboxCredentialStore?

    static var current: MailboxCredentialStore {
        if let injected = override { return injected }
        #if SMOKE
        return smokeShared
        #else
        return KeychainMailboxCredentialStore()
        #endif
    }

    #if SMOKE
    nonisolated(unsafe) static var smokeShared = InMemoryMailboxCredentialStore()
    #endif

    static func accountKey(_ id: UUID) -> String { SecretVault.mailboxAccountKey(id) }
    static func secretKey(_ id: UUID) -> String { SecretVault.mailboxSentinelKey(id) }

    func accountAuth(accountId: UUID) -> String? {
        SecretVault.value(Self.accountKey(accountId))
    }
    func setAccountAuth(_ value: String?, accountId: UUID) throws {
        try SecretVault.set(value, Self.accountKey(accountId))
    }
    func sentinelSecret(sentinelId: UUID) -> String? {
        SecretVault.value(Self.secretKey(sentinelId))
    }
    func setSentinelSecret(_ value: String?, sentinelId: UUID) throws {
        try SecretVault.set(value, Self.secretKey(sentinelId))
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
