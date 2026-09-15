//
//  ModelKeyStore.swift
//  P7-M2: 模型 API key 存储。真源 Keychain (不落明文), 物化时读出写 auth.json (0600)。
//  协议化便于冒烟用内存实现; account 约定 = "{provider}" (v1 key 按 provider 归组)。
//

import Foundation
import Security

protocol ModelKeyStore {
    func key(account: String) -> String?
    func setKey(_ key: String, account: String) throws
    func deleteKey(account: String) throws
}

struct KeychainModelKeyStore: ModelKeyStore {
    let service: String = "com.mangox.model-key"

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func key(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ newKey: String, account: String) throws {
        let data = Data(newKey.utf8)
        if key(account: account) != nil {
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func deleteKey(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// 冒烟/测试用内存实现。
final class InMemoryModelKeyStore: ModelKeyStore {
    private var storage: [String: String] = [:]

    func key(account: String) -> String? { storage[account] }
    func setKey(_ key: String, account: String) throws { storage[account] = key }
    func deleteKey(account: String) throws { storage.removeValue(forKey: account) }
}
