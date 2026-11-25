//
//  RemoteSecrets.swift
//  P19.2 S15b —— 飞书自建应用的 app_secret（**按机器人一条**）。
//
//  ── 为什么只有 secret 进钥匙串，app_id 反而进了库 ─────────────────────────────
//  S15 那版把 app_id 也塞进了钥匙串（理由："它是身份"）。多机器人之后这条理由不成立了:
//    ① 列表页要一次画出 N 行，每行读一次钥匙串 ⇒ 无签名构建**每次重编都弹一次授权框**，
//       而这一次读发生在**视图渲染路径**上（比启动路径更糟: 每帧都可能撞上）；
//    ② app_id 不是能力凭据 —— 它出现在每个飞书管理后台的地址栏里。真正"以这个机器人的
//       身份收发消息"的能力在 secret 上，而 secret 仍然只有钥匙串里那一份。
//  所以: app_id 落库（`remote_bots.app_id`），secret 进钥匙串（`feishu.bot.<id>.secret`）。
//
//  ⚠️ 与 `KeychainNotifySecretStore` 仍然是**两个 service**: 那个是"某条任务的触达地址"
//  （按 taskId 存），这个是"某个机器人的身份"。混成一个 service 会让"删掉所有任务"
//  顺手带走通道凭据，而界面上没有任何地方说得出这件事发生过。
//

import Foundation
import Security

protocol RemoteSecretStore: AnyObject {
    func secret(for botId: UUID) -> String?
    /// 传 nil / 空串 = 删掉那一条。
    func set(secret: String?, for botId: UUID) throws
}

/// 钥匙串实现 —— **走 `SecretVault`（一个条目）**，不再一个机器人一个条目（2026-11-25）。
/// 逻辑键 = `remote.feishu.bot.<uuid>.secret`，迁移时去掉 `remote.` 前缀就是老位置上的 account。
final class KeychainRemoteSecretStore: RemoteSecretStore {
    /// 老 service 名。**只读，不再写** —— `LegacyFeishuCredential` 的搬家按钮还靠它找老条目。
    static let keychainService = SecretVault.legacyRemoteService

    /// 冒烟注入缝（与 `KeychainNotifySecretStore.override` 同款）：
    /// 无签名的冒烟二进制读钥匙串会弹授权框并一直等答复 ⇒ 挂死。
    nonisolated(unsafe) static var override: RemoteSecretStore?

    static var current: RemoteSecretStore {
        if let injected = override { return injected }
        #if SMOKE
        return smokeShared
        #else
        return KeychainRemoteSecretStore()
        #endif
    }

    #if SMOKE
    nonisolated(unsafe) static var smokeShared = InMemoryRemoteSecretStore()
    #endif

    /// S15 的旧账号名（全局一条）。**只读，不再写** —— 迁移按钮要靠它把老配置搬到新结构。
    static let legacyAppIdAccount = "feishu.app_id"
    static let legacyAppSecretAccount = "feishu.app_secret"

    static func account(for botId: UUID) -> String { SecretVault.remoteBotKey(botId) }

    func secret(for botId: UUID) -> String? {
        SecretVault.value(Self.account(for: botId))
    }

    func set(secret: String?, for botId: UUID) throws {
        try SecretVault.set(secret, Self.account(for: botId))
    }
}

/// 冒烟/测试用内存实现。
final class InMemoryRemoteSecretStore: RemoteSecretStore {
    private var items: [UUID: String] = [:]

    init(seed: [UUID: String] = [:]) { items = seed }

    func secret(for botId: UUID) -> String? { items[botId] }

    func set(secret: String?, for botId: UUID) throws {
        if let secret, !secret.isEmpty { items[botId] = secret } else { items.removeValue(forKey: botId) }
    }
}

// MARK: - 旧配置搬家（S15 → S15b）

/// S15 那版把 app_id / app_secret 存在**全局两个账号**上。S15b 起按机器人存。
///
/// 为什么不在迁移里直接读: 读钥匙串可能弹授权框（无签名构建时**每次都弹**），
/// 而它会在启动线程上等答复 ⇒ App 表现为"启动卡死"。所以搬家做成设置页里的
/// **一个显式按钮** —— 人按下去的时候，弹框是预期内的。
enum LegacyFeishuCredential {
    static func read() -> (appId: String, secret: String)? {
        guard let id = readAccount(KeychainRemoteSecretStore.legacyAppIdAccount),
              let secret = readAccount(KeychainRemoteSecretStore.legacyAppSecretAccount) else {
            return nil
        }
        return (id, secret)
    }

    private static func readAccount(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: KeychainRemoteSecretStore.keychainService,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}
