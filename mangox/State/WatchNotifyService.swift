//
//  WatchNotifyService.swift
//  P19 S7: 独立触达通道 —— 邮件与飞书自定义机器人。
//
//  三条纪律（写在这里是因为它们决定了这一层能做什么、不能做什么）:
//   ① **只发不收。** 这一层没有 poll，没有就绪检查，没有任何一条把外部数据带回来的路。
//      收是来源（`WatchSources`）的事，两者不同居 —— 合起来就成了"渠道"，
//      而渠道要处理鉴权、去重、线程映射，那是 P19.1 的事。
//   ② **外发只有标题 + 任务名。** 载荷由 `payload(finding:taskName:)` 一处构造，
//      三个 sink 共用；任何 sink 都不许自己拼 `body` / `evidence`。
//   ③ **凭据只经 Keychain。** webhook URL 的路径段本身就是密钥 —— 它不出现在库里、
//      不出现在日志里、也不出现在给用户看的错误文案里（`redact` 是这条路唯一的口径）。
//

import Foundation
import Security

// MARK: - 凭据缝

/// webhook URL 的存储缝。**按 taskId 存** —— 一条任务一个机器人，删任务要能删干净。
protocol NotifySecretStore: AnyObject {
    func webhookURL(taskId: UUID) -> String?
    func setWebhookURL(_ url: String?, taskId: UUID) throws
}

/// Keychain 实现: service = com.mangox.notify, account = `notify.hook.<taskId>`。
final class KeychainNotifySecretStore: NotifySecretStore {
    let service = "com.mangox.notify"

    /// 冒烟注入缝（与 `KeychainModelKeyStore.keyStoreOverride` 同款）。
    /// 无签名的冒烟二进制读钥匙串会弹授权框 + `SecItemCopyMatching` 一直等答复 ⇒ 挂死。
    nonisolated(unsafe) static var override: NotifySecretStore?

    static var current: NotifySecretStore {
        if let injected = override { return injected }
        #if SMOKE
        return smokeShared
        #else
        return KeychainNotifySecretStore()
        #endif
    }

    #if SMOKE
    nonisolated(unsafe) static var smokeShared = InMemoryNotifySecretStore()
    #endif

    static func accountKey(_ id: UUID) -> String { "notify.hook.\(id.uuidString)" }

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

    func webhookURL(taskId: UUID) -> String? { read(Self.accountKey(taskId)) }

    func setWebhookURL(_ url: String?, taskId: UUID) throws {
        let account = Self.accountKey(taskId)
        guard let url, !url.isEmpty else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }
        let data = Data(url.utf8)
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
}

/// 冒烟/测试用内存实现。
final class InMemoryNotifySecretStore: NotifySecretStore {
    private var hooks: [UUID: String] = [:]

    func webhookURL(taskId: UUID) -> String? { hooks[taskId] }
    func setWebhookURL(_ url: String?, taskId: UUID) throws {
        if let url, !url.isEmpty { hooks[taskId] = url } else { hooks.removeValue(forKey: taskId) }
    }
}

// MARK: - 投递缝

/// webhook 投递缝。冒烟可注入"只记不发"的实现（不连真网、不往用户的飞书群里发消息）。
///
/// ⚠️ `@MainActor` 与 `MailTransport` 同款：投递只从回合落定那一个上下文发起，
/// 把它开成任意线程可达只会让"这条结论发了几次"变成竞态问题。
@MainActor
protocol WebhookSender: AnyObject {
    /// 返回 HTTP 状态码 + 响应体。**飞书对参数错误也回 200**（body 里 `code != 0`），
    /// 所以判成功不能只看状态码 —— 见 `feishuError(_:)`。
    func post(_ url: URL, json: Data) async throws -> (status: Int, body: String)
}

@MainActor
final class URLSessionWebhookSender: WebhookSender {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: cfg)
    }

    func post(_ url: URL, json: Data) async throws -> (status: Int, body: String) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - 纯函数（判据全打在这一层）

enum WatchNotifyService {

    /// 外发载荷。**唯一**构造点 —— 见文件头纪律 ②。
    static func payload(finding: AgentFinding, taskName: String) -> NotifyPayload {
        NotifyPayload(findingId: finding.id, taskName: taskName, title: finding.title)
    }

    /// 邮件。收件人由人配、发件人是账号自己 —— 两者都不从 finding 里来，避免"回信给来信人"
    /// 这种把外部输入当目的地的事。
    ///
    /// ⚠️ 正文用 `String(format: L(...))` 而不是多行字符串里的 `\(…)` 插值：
    /// 后者有两个坑 —— `L()` 拿到的 key 是**已经插值完**的整句（词表里永远查不到），
    /// 而多行字面量的后续行还在 `gen_strings.py` 的扫描盲区里（它按行扫）。
    static func mail(_ p: NotifyPayload, to recipient: String, from sender: String) -> OutgoingMail {
        let subject = "[MangoX] " + p.line
        let body = String(format: L("%@\n\n任务：%@\n处理：打开 MangoX → 定时任务 → 待处理\n\n—— 正文与证据留在 App 内，不经邮件外发。"),
                          p.title, p.taskName)
        return OutgoingMail(to: recipient, subject: subject, body: body)
    }

    /// 飞书自定义机器人 v2 载荷：`{"msg_type":"text","content":{"text":"…"}}`。
    ///
    /// 用 `JSONEncoder` 而不是手拼字符串：标题里会出现引号、换行与 emoji，
    /// 手拼一次就要转义一次，漏一处就是"发不出去且报错看不懂"。
    static func feishuBody(_ p: NotifyPayload) -> Data? {
        struct Text: Encodable { let text: String }
        struct Content: Encodable { let msg_type: String; let content: Text }
        let line = String(format: L("【MangoX】%@\n打开 App 的收件箱处理 —— 正文与证据留在本地。"),
                          p.line)
        return try? JSONEncoder().encode(Content(msg_type: "text", content: Text(text: line)))
    }

    /// 飞书的**真实失败判据**：HTTP 200 也可能失败，错误码在 body 里。
    /// 返回 nil = 成功；否则是给用户看的一句话（**不含 URL**）。
    static func feishuError(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return L("响应不是 JSON（机器人地址对吗？）") }
        let code = (obj["code"] as? Int) ?? (obj["StatusCode"] as? Int) ?? 0
        guard code != 0 else { return nil }
        let msg = (obj["msg"] as? String) ?? (obj["StatusMessage"] as? String) ?? "unknown"
        return String(format: L("飞书拒绝（code %@）: %@"), String(code), msg)
    }

    /// URL 脱敏 —— 这是**唯一**允许 URL 出现在日志/文案里的形态。
    ///
    /// 保留 scheme + host: 用户要能从日志判断"我配的是不是那个机器人"；
    /// 砍掉路径: 飞书机器人的路径段就是凭据本身（拿到它就能以这个机器人发言）。
    static func redact(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        guard let u = URL(string: s), let scheme = u.scheme, let host = u.host else {
            // 连 URL 都解不出 ⇒ **一个字都不回显**。这时候它要么是手抖，要么是密钥本身。
            return L("（不是合法 URL）")
        }
        return "\(scheme)://\(host)/…"
    }

    /// 一条 URL 看着像不像飞书自定义机器人（配错时的第一道提示，不是权威校验）。
    static func looksLikeFeishuHook(_ raw: String) -> Bool {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme == "https", let host = u.host else { return false }
        return host.hasSuffix("feishu.cn") || host.hasSuffix("larksuite.com")
    }
}
