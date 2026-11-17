//
//  RemoteSecrets.swift
//  P19.2 S15 —— 飞书自建应用的 app_id / app_secret。
//
//  为什么两个都进钥匙串（app_id 看着"不像密码"）: 它不是密码，但它是**身份**。
//  App Secret 单独泄露没用（换不到 token 也不完整），而两者同时出现在一份能截图/
//  能上传的配置文件里，等于把"以这个机器人的身份收发消息"的能力交出去。S7 的 webhook
//  走的是同一条判据（URL 路径段就是密钥），这里保持一致。
//
//  ⚠️ 与 `KeychainNotifySecretStore` 是**两个 service**: 一个是"某条任务的触达地址"
//  （按 taskId 存），一个是"整台机器的飞书身份"（全局一条）。混成一个 service 会让
//  "删掉所有任务"顺手带走通道凭据，而界面上没有任何地方说得出这件事发生过。
//

import Foundation
import Security

protocol RemoteSecretStore: AnyObject {
    func appId() -> String?
    func appSecret() -> String?
    /// 传 nil / 空串 = 删掉那一条。
    func set(appId: String?, appSecret: String?) throws
}

/// Keychain 实现: service = com.mangox.remote, account = `feishu.app_id` / `feishu.app_secret`。
final class KeychainRemoteSecretStore: RemoteSecretStore {
    let service = "com.mangox.remote"

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

    static let appIdAccount = "feishu.app_id"
    static let appSecretAccount = "feishu.app_secret"

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

    func appId() -> String? { read(Self.appIdAccount) }
    func appSecret() -> String? { read(Self.appSecretAccount) }

    func set(appId: String?, appSecret: String?) throws {
        try write(appId, account: Self.appIdAccount)
        try write(appSecret, account: Self.appSecretAccount)
    }
}

/// 冒烟/测试用内存实现。
final class InMemoryRemoteSecretStore: RemoteSecretStore {
    private var id: String?
    private var secret: String?

    init(appId: String? = nil, appSecret: String? = nil) {
        self.id = appId
        self.secret = appSecret
    }

    func appId() -> String? { id }
    func appSecret() -> String? { secret }

    func set(appId: String?, appSecret: String?) throws {
        id = (appId?.isEmpty == false) ? appId : nil
        secret = (appSecret?.isEmpty == false) ? appSecret : nil
    }

    /// 「配齐了没有」—— 界面与启动判据共用这一处（不要各自拼 `!= nil && != ""`）。
    var isComplete: Bool { (id?.isEmpty == false) && (secret?.isEmpty == false) }
}
