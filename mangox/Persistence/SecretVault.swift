//
//  SecretVault.swift
//  一把钥匙串条目装下**全部**凭据（2026-11-25）。
//
//  ── 为什么要有它 ────────────────────────────────────────────────────────────
//  原来三个 service、一条凭据一个条目：`com.mangox.model-key`（每个 provider 一条）、
//  `com.mangox.mailbox`（每个邮箱账号一条授权码 + 每个哨兵一条密钥）、
//  `com.mangox.remote`（每个飞书机器人一条 secret）。后果是**启动要授权四次**
//  （bocha + 物化 auth.json 时读的那几条 provider key），点「集成」再授权一次（飞书 secret）。
//
//  macOS 的授权粒度是**每个钥匙串条目一次**，不是每次读一次 —— 同一条目在一个进程里读
//  多少次都只问一遍。所以"合并成一个条目"是唯一能把 N 次压到 1 次的办法。
//
//  另一半（每装一个新版本又要重来一遍）不在这个文件里：那是**签名身份**的问题 ——
//  ad-hoc 签名的 designated requirement 是二进制的 cdhash，每编译一次就变，于是
//  "始终允许"记下的那个身份下一次对不上。改成固定自签证书签才治得了（见
//  `scripts/install-from-release.sh` 的说明）。
//
//  ── 三条约定 ────────────────────────────────────────────────────────────────
//  ① **一个条目**: service `com.mangox.vault` / account `v1`，值是 JSON 字典
//     （逻辑键 → 明文）。加一类凭据不改条目数。
//  ② **进程内只读一次**: 第一次访问把整条读进内存，之后所有读都是内存。写是"改内存 + 整条写回"
//     —— 于是写一次也只多一次 **写** 授权（写不弹框，条目已在本进程的授权范围内）。
//  ③ **逻辑键带命名空间**（`model.` / `mailbox.` / `remote.`）: 三类凭据共用一个字典，
//     键撞了就是**静默覆盖**（老 `'归属'` 那个重复 key 的坑同族），命名空间是那道墙。
//

import Foundation
import Security

enum SecretVault {

    /// 唯一的那个条目。
    static let service = "com.mangox.vault"
    static let account = "v1"

    // MARK: - 逻辑键（带命名空间）

    static func modelKey(_ provider: String) -> String { "model." + provider }

    /// 邮箱授权码。**键名与老 service 的 account 一字不差** —— 迁移时直接拿它去读老位置，
    /// 不需要再维护一张对照表（对照表是第二个真源，迟早对不上）。
    static func mailboxAccountKey(_ id: UUID) -> String { "mailbox.acct.\(id.uuidString).auth" }
    static func mailboxSentinelKey(_ id: UUID) -> String { "mailbox.sentinel.\(id.uuidString).secret" }

    static func remoteBotKey(_ id: UUID) -> String { "remote.feishu.bot.\(id.uuidString).secret" }

    // MARK: - 老位置（迁移用）

    /// 老版本把凭据分成三个 service。这里只做**读**，一个字都不写：
    /// 读完立刻搬进 vault 并落盘，之后不再碰（vault 条目存在就不会再走这条路）。
    ///
    /// ⚠️ 映射错了 = 用户的 key **静默消失**（读不到就是 nil，界面表现为"没配过"），
    /// 所以这条映射被冒烟 ㊶ 逐条钉住（`legacyLocation` ↔ 三个 `*Key` 函数互相反解）。
    static let legacyModelService = "com.mangox.model-key"
    static let legacyMailboxService = "com.mangox.mailbox"
    static let legacyRemoteService = "com.mangox.remote"

    static func legacyLocation(_ key: String) -> (service: String, account: String)? {
        if key.hasPrefix("model.") {
            return (legacyModelService, String(key.dropFirst("model.".count)))
        }
        if key.hasPrefix("mailbox.") {
            return (legacyMailboxService, key)
        }
        if key.hasPrefix("remote.") {
            return (legacyRemoteService, String(key.dropFirst("remote.".count)))
        }
        return nil
    }

    // MARK: - 状态

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    /// 本进程**真去碰过钥匙串几次**（只在真身那段自增，冒烟替身不算）。
    ///
    /// 唯一消费者 = 启动页第 2 行的读数「已授权 N 次」—— 它要说的正是这件事：
    /// 这一屏背后问了你**几次**钥匙串。⛔️ 别拿它当业务判据（"有没有配过 key" 是
    /// `get(...) != nil`），它是**计数**不是状态。
    nonisolated(unsafe) static var vaultReadCount = 0
    /// **载入那一刻**条目就在（= 早就搬完了）。它决定还要不要去读老位置 ——
    /// 老位置读一次就是一次授权框；而且我们**从不删老条目**，所以"没搬完"这个状态
    /// 一旦松掉，被删掉的键会被老条目**复活**（`set(nil)` 之后下次启动又读回来）。
    /// ⚠️ 只能由 `loadIfNeeded` 写。**它不是"钥匙串里此刻有没有这条"** —— 那个是
    /// `itemExists`。第一版把两件事共用一个标志: 迁移写完第一条就把这位置成 `true`，
    /// 剩下几个老键当场读 nil（邮箱凭据 / 飞书 secret **静默消失**），而且 SMOKE 的
    /// `persist` 是空实现、压根不动它 ⇒ 冒烟结构上抓不到。两个语义必须分开。
    nonisolated(unsafe) private static var migrated = false
    /// 钥匙串里此刻有没有这条（`persist` 据此选 update 还是 add）。
    nonisolated(unsafe) private static var itemExists = false
    /// 已经把老位置问过一遍的键（同一次进程内不重复问）。
    nonisolated(unsafe) private static var legacyProbed: Set<String> = []

    // MARK: - 读 / 写

    static func value(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        if let v = cache?[key] { return v }
        guard !migrated, legacyProbed.insert(key).inserted,
              let loc = legacyLocation(key), let old = readLegacy(loc), !old.isEmpty else { return nil }
        cache?[key] = old
        // 立刻落盘: 不写回的话下次启动还要再问一次老位置（那就不是"只多一次"了）。
        try? persist()
        return old
    }

    /// 传 nil / 空串 = 删掉那个键。
    static func set(_ newValue: String?, _ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        if let newValue, !newValue.isEmpty {
            cache?[key] = newValue
        } else {
            cache?.removeValue(forKey: key)
        }
        try persist()
    }

    #if SMOKE
    /// 冒烟用: 换成一版"全新安装"的状态 —— 条目不存在，老位置也没有任何东西。
    static func resetForSmoke() {
        lock.lock()
        defer { lock.unlock() }
        cache = [:]
        migrated = false             // 冒烟里 `readLegacy` 只查 `legacyStub`，不碰真钥匙串
        itemExists = false
        legacyProbed = []
        legacyStub = [:]
        stubStore = [:]
    }

    /// 冒烟用: 模拟**重启** —— 内存 `cache` 丢掉，钥匙串里那条留着（走 `readRaw` 读回来）。
    static func reloadForSmoke() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
        legacyProbed = []
    }
    #endif

    // MARK: - 落盘（只在非 SMOKE 下碰钥匙串）

    private static func baseQuery(account: String = SecretVault.account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func loadIfNeeded() {
        guard cache == nil else { return }
        cache = [:]
        guard let data = readRaw() else { migrated = false; itemExists = false; return }
        migrated = true
        itemExists = true
        cache = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    // MARK: - 碰钥匙串的那几个函数（SMOKE 下整段不编进去）

    // ⚠️ **`persist` 也必须在这道 `#if` 里**。第一版只把两个 `read*` 隔开了，于是
    //    冒烟里调 `set` 会走到 `SecItemAdd` —— 2026-11-25 实测: 冒烟真的在用户登录钥匙串里
    //    建出了 `com.mangox.vault`（`security find-generic-password -s com.mangox.vault` 查到的
    //    cdat 就是那一跑的分钟）。这类事故在 `KeychainModelKeyStore` 的注释里已经写过两回
    //    （0.1.16 挂死 / 0.1.20 门禁卡住），我的教训是**判据要覆盖"写"而不只是"读"**。
    //    `scripts/smoke/run.sh` 有一条源码判据盯着这件事（SMOKE 段里出现 `SecItem` 就红）。

    #if SMOKE
    /// 冒烟里当"老位置"用的假数据，键 = `"<service>/<account>"`。空 = 老条目都不存在。
    nonisolated(unsafe) static var legacyStub: [String: String] = [:]

    /// 假钥匙串里那条的**内容**。⚠️ 必须是独立一份，不能复用 `cache` ——
    /// `loadIfNeeded` 是先把 `cache` 清空再调 `readRaw` 的，读自己就等于每次重启都读到空
    /// （第一版这么写，㊺ 实测 `["nil","nil"]`）。**假实现要能分辨"内存里"与"盘上"**。
    nonisolated(unsafe) private static var stubStore: [String: String] = [:]

    /// 冒烟: 纯内存，但**语义与真身一致** —— 写进去的能读回来，`itemExists` 跟着变。
    /// 第一版这里直接返回 nil / 空实现，于是"迁移只搬得动第一个键"这类 bug 在冒烟里
    /// **不可复现**（`persist` 不翻转任何状态）⇒ 判据恒绿。假实现也得守合同。
    private static func readRaw() -> Data? {
        guard itemExists else { return nil }
        return try? JSONEncoder().encode(stubStore)
    }
    private static func readLegacy(_ loc: (service: String, account: String)) -> String? {
        legacyStub["\(loc.service)/\(loc.account)"]
    }
    /// 冒烟: 落到 `stubStore`（那把假钥匙串），条目状态照实维护。
    private static func persist() throws {
        stubStore = cache ?? [:]
        itemExists = !stubStore.isEmpty
    }
    #else
    private static func readRaw() -> Data? {
        vaultReadCount += 1
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &out)
        // 一行定案「一次启动弹几个框」：`status != 0` ⇒ 条目没读到 ⇒ 下面每个键都会去读老位置
        // （每个老 service + account 一个框）。这一行就是"退化"的开关读数。
        Log.store("vault-read", ["st": "\(st)", "hit": st == errSecSuccess ? "1" : "0"])
        guard st == errSecSuccess, let data = out as? Data else { return nil }
        return data
    }

    private static func readLegacy(_ loc: (service: String, account: String)) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: loc.service,
                                    kSecAttrAccount as String: loc.account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &out)
        // ⚠️ account 只记前 8 个字符（邮箱账号那条的 account 可能带地址，日志不该落明文）。
        Log.store("vault-legacy", ["svc": loc.service,
                                   "acc": String(loc.account.prefix(8)),
                                   "st": "\(st)"])
        guard st == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 整条重写: 先 update、条目没了再 add。**写的是全部键** —— 调用方保证 `cache` 是全量。
    private static func persist() throws {
        let dict = cache ?? [:]
        Log.store("vault-write", ["mode": itemExists ? "update" : "add", "keys": "\(dict.count)"])
        if dict.isEmpty {
            if itemExists {
                let status = SecItemDelete(baseQuery() as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
                itemExists = false
            }
            return
        }
        let data = try JSONEncoder().encode(dict)
        if itemExists {
            let status = SecItemUpdate(baseQuery() as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return }
            if status != errSecItemNotFound {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            itemExists = false        // 被人从钥匙串里删了 ⇒ 落到下面的 add
        }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        itemExists = true
    }
    #endif

}
