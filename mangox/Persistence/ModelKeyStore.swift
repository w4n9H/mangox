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

/// 钥匙串实现 —— **走 `SecretVault`（一个条目）**，不再一条 provider 一个条目。
///
/// 2026-11-25 boss: 每装一个新版本，首次打开要连着输四次密码（一次一个条目），
/// 点「集成」再输第五次。macOS 的授权粒度是**每条目一次** ⇒ 条目数就是弹框数，
/// 所以三类凭据合进一个条目（见 `SecretVault` 的文件头）。这个类型现在只负责
/// "provider 名 → 逻辑键" 这一层翻译。
struct KeychainModelKeyStore: ModelKeyStore {

    /// 冒烟注入: **进程级**重定向 key store 的缝 (与 `ImagePipeline.attachmentsRootOverride` 同款)。
    ///
    /// ⚠️ 为什么必须是进程级: `ChatStore.init` 的 `modelKeyStore:` 是**函数级**参数, 只有显式传
    ///    它的调用点才受控 —— 而 `ChatStore.init` **无条件**要跑 `scanExtensions()`, 后者起手就读
    ///    `bochaKey` ⇒ 凡是没传参数的构造点都会去读用户**真实**的钥匙串。条目存在时 macOS 会向
    ///    另一个二进制要授权（弹窗）, 而 `SecItemCopyMatching` **一直等答复** ⇒ 冒烟**挂死在弹窗上**。
    ///    实测 2026-10-16: 0.1.20 发版门禁卡在这里, 冒烟里 52/58 个 `ChatStore` 构造点没传参数。
    ///    与守卫 21/22/23/26/27 同一族 —— 生产调用点不传参数, 靠各处自觉迟早漏。
    nonisolated(unsafe) static var keyStoreOverride: ModelKeyStore?

    /// 当前生效的 store。**政策与解析拆开** —— 守卫断言读它, 否则守卫自证。
    static var current: ModelKeyStore {
        if let injected = keyStoreOverride { return injected }
        #if SMOKE
        return smokeShared
        #else
        return KeychainModelKeyStore()
        #endif
    }

    /// 编译开关的**可断言投影**: `-D SMOKE` 开了没有。
    ///
    /// ⚠️ 冒烟**入口**靠它决定要不要跑（见 `smokeMain.run()` 的 guard）。为什么不只查
    ///    `current is InMemoryModelKeyStore`: 那个表达式本身不碰钥匙串, 但**它的结论救不了场** ——
    ///    隔离一失效, 冒烟会在建 ChatStore 的过程中几十次去读用户真实钥匙串, macOS **疯狂弹授权框**
    ///    （实测 2026-10-16: 只报一条 FAIL 继续跑的那版, 弹到用户叫停）。
    ///    ⇒ 判据要在**建任何 ChatStore 之前**读到一个不碰钥匙串的事实, 并且**拒绝运行**。
    ///    这个投影就是那个事实。
    static var isSmokeIsolated: Bool {
        #if SMOKE
        true
        #else
        false
        #endif
    }

    #if SMOKE
    /// 冒烟进程的默认 store: **一个进程一个实例**。
    /// ⚠️ 不能"每次现建一个" —— 真实钥匙串是所有 `ChatStore` **共享**的（A 存的 provider key,
    ///    B 物化时读得到）。每次新建会让"跨 store 看得见"那类断言失真（既假阴也假阳）。
    ///
    /// 这条分支同时**是门的判据**: 冒烟断言 `current is InMemoryModelKeyStore` ⇒ `run.sh` 里的
    /// `-D SMOKE` 一旦掉了那条立刻红（否则会静默回到"读用户真实钥匙串 + 弹窗挂死"）。
    nonisolated(unsafe) static var smokeShared = InMemoryModelKeyStore()
    #endif

    func key(account: String) -> String? { SecretVault.value(SecretVault.modelKey(account)) }

    func setKey(_ newKey: String, account: String) throws {
        try SecretVault.set(newKey, SecretVault.modelKey(account))
    }

    func deleteKey(account: String) throws {
        try SecretVault.set(nil, SecretVault.modelKey(account))
    }
}

/// 冒烟/测试用内存实现。
final class InMemoryModelKeyStore: ModelKeyStore {
    private var storage: [String: String] = [:]

    func key(account: String) -> String? { storage[account] }
    func setKey(_ key: String, account: String) throws { storage[account] = key }
    func deleteKey(account: String) throws { storage.removeValue(forKey: account) }
}
