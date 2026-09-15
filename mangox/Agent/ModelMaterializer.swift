//
//  ModelMaterializer.swift
//  P7-M2: SQLite 真源 → pi models.json + auth.json 物化。
//  materialize = 纯函数 (冒烟覆盖); writeIfNeeded = IO 壳 (fingerprint 不变跳写, 防 spawn 期磁盘搅动)。
//  实验①/①c 实测: 全新 provider 经 models.json 注册可用, key 走 auth.json (0600) 照常可用。
//

import Foundation
import CryptoKit

enum ModelMaterializer {

    struct Output {
        let modelsJSON: Data
        let authJSON: Data
        /// 物化的模型条数 (0 = 无自管模型, spawn 不注入 PI_CODING_AGENT_DIR)。
        let modelCount: Int
        /// sha256(modelsJSON ‖ authJSON) hex — 内容指纹, 与盘上 .fingerprint 比对决定是否重写。
        var fingerprint: String {
            var data = modelsJSON
            data.append(0)
            data.append(authJSON)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - 纯函数核心

    /// keyProvider: account (keyRef) → key 明文 (来自 Keychain)。返回 nil/空 = 该 provider 不进 auth.json。
    static func materialize(_ models: [ManagedModel],
                            keyProvider: (String) -> String?) -> Output {
        let enabled = models.filter { $0.enabled }
        // 排序保证 .sortedKeys 之外的结构也确定 (数组顺序影响指纹)
        let grouped = Dictionary(grouping: enabled, by: { $0.provider })
            .mapValues { $0.sorted { $0.modelId < $1.modelId } }

        var providers: [String: Any] = [:]
        var auth: [String: Any] = [:]

        for provider in grouped.keys.sorted() {
            let list = grouped[provider]!

            var modelEntries: [[String: Any]] = []
            var providerAPI: String?
            for m in list {
                var entry: [String: Any] = ["id": m.modelId]
                entry["name"] = m.displayNameOrId
                // api: provider 级取首条; 与首条不同才落 model 级
                if providerAPI == nil {
                    providerAPI = m.apiType
                } else if m.apiType != providerAPI {
                    entry["api"] = m.apiType
                }
                entry["reasoning"] = m.reasoning
                entry["input"] = m.inputModalities.isEmpty ? ["text"] : m.inputModalities
                if let cw = m.contextWindow { entry["contextWindow"] = cw }
                if let mt = m.maxTokens { entry["maxTokens"] = mt }
                if let cost = m.cost { entry["cost"] = costDict(cost) }
                if let raw = m.thinkingLevelMapJSON, let obj = parseFragment(raw) { entry["thinkingLevelMap"] = obj }
                if let raw = m.compatJSON, let obj = parseFragment(raw) { entry["compat"] = obj }
                if let raw = m.samplingParamsJSON, let obj = parseFragment(raw) { entry["samplingParams"] = obj }
                modelEntries.append(entry)
            }

            var providerEntry: [String: Any] = ["models": modelEntries]
            // baseUrl nil (legacy 借壳) → 省略, 靠 pi 内置 provider 定义
            if let base = list.first?.baseURL, !base.isEmpty { providerEntry["baseUrl"] = base }
            if let api = providerAPI { providerEntry["api"] = api }
            providers[provider] = providerEntry

            // key 按 provider 归组: 取该 provider 首个 enabled 条目的 keyRef
            if let keyRef = list.first(where: { $0.keyRef != nil })?.keyRef,
               let key = keyProvider(keyRef), !key.isEmpty {
                auth[provider] = ["type": "api_key", "key": key]
            }
        }

        let modelsJSON = (try? JSONSerialization.data(withJSONObject: ["providers": providers], options: [.sortedKeys])) ?? Data("{}".utf8)
        let authJSON = (try? JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Output(modelsJSON: modelsJSON, authJSON: authJSON, modelCount: enabled.count)
    }

    private static func costDict(_ c: ModelCost) -> [String: Any] {
        var d: [String: Any] = ["input": c.input, "output": c.output,
                                "cacheRead": c.cacheRead, "cacheWrite": c.cacheWrite]
        if let tiers = c.tiers, !tiers.isEmpty {
            d["tiers"] = tiers.map { t -> [String: Any] in
                ["inputTokensAbove": t.inputTokensAbove, "input": t.input,
                 "output": t.output, "cacheRead": t.cacheRead, "cacheWrite": t.cacheWrite]
            }
        }
        return d
    }

    private static func parseFragment(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return obj
    }

    // MARK: - IO 壳

    static func configDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mangox/pi-config", isDirectory: true)
    }

    /// 物化落盘 (指纹不变跳写)。返回是否实际写入。
    @discardableResult
    static func writeIfNeeded(_ output: Output, to directory: URL) throws -> Bool {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(".fingerprint")
        if let existing = try? String(contentsOf: marker, encoding: .utf8),
            existing == output.fingerprint {
            return false
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // auth.json / models.json 均 0600 (含 key 的文件收紧; models.json 同步收紧省心)
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if !fm.createFile(atPath: directory.appendingPathComponent("models.json").path,
                          contents: output.modelsJSON, attributes: attrs) {
            throw NSError(domain: "ModelMaterializer", code: 1)
        }
        if !fm.createFile(atPath: directory.appendingPathComponent("auth.json").path,
                          contents: output.authJSON, attributes: attrs) {
            throw NSError(domain: "ModelMaterializer", code: 2)
        }
        try output.fingerprint.write(to: marker, atomically: true, encoding: .utf8)
        return true
    }
}
