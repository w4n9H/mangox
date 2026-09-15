//
//  ModelCatalog.swift
//  P7-M3.5: 模型元数据目录 — models.dev 自有化三层 (bundled 快照 > 远端缓存 > 空)。
//  运行时零依赖 ~/.pi/agent; 目录只补元数据 (名称/思考/窗口/价格), id 清单仍以 /models 实拉为准。
//

import Foundation

/// 目录条目 (models.dev 6 字段剪裁)。
struct CatalogModelEntry: Hashable {
    var name: String
    var reasoning: Bool
    var input: [String]
    var contextWindow: Int?
    var maxTokens: Int?
    var cost: ModelCost?
}

/// 进程内单例; loadCached 即时, refreshIfStale 异步静默。
final class ModelCatalogStore {
    static let shared = ModelCatalogStore()

    /// models.dev 的 provider id 与 MangoX 预设 id 不同名的别名表 (MangoX → models.dev)。
    static let providerAliases: [String: String] = [
        "kimi": "moonshotai",
        "zhipu": "zai",
    ]

    static let remoteURL = URL(string: "https://models.dev/api.json")!
    static let ttl: TimeInterval = 7 * 24 * 3600

    private(set) var providers: [String: [String: CatalogModelEntry]] = [:]

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mangox/catalog", isDirectory: true)
            .appendingPathComponent("modelsdev.json")
    }

    private init() { loadCached() }

    /// smoke 用: 直接以解析好的索引构造。
    init(providers: [String: [String: CatalogModelEntry]]) { self.providers = providers }

    var isEmpty: Bool { providers.isEmpty }

    // MARK: - 加载 (远端缓存 > bundled 快照 > 空)

    func loadCached() {
        providers = Self.parse(Self.data(at: Self.cacheURL))
            ?? Self.parse(Self.bundledData())
            ?? [:]
    }

    static func bundledData() -> Data? {
        Bundle.main.url(forResource: "model-catalog", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }

    static func data(at url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: - 查询 (预设 id → 别名 → 模糊扫全目录)

    func entry(provider: String, modelId: String) -> CatalogModelEntry? {
        for key in [provider, Self.providerAliases[provider] ?? ""] where !key.isEmpty {
            if let e = providers[key]?[modelId] { return e }
        }
        // 未知 provider: 全目录扫 modelId, 唯一命中才采信
        let hits = providers.compactMap { $0.value[modelId] }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 指定 provider 的全部条目 (仅精确 + 别名, 不模糊) — loadPreset 展开用。
    func entries(provider: String) -> [String: CatalogModelEntry] {
        providers[provider] ?? providers[Self.providerAliases[provider] ?? ""] ?? [:]
    }

    // MARK: - 远端刷新 (静默失败, 7 天 TTL)

    var isStale: Bool {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: Self.cacheURL.path),
              let mtime = attr[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(mtime) > Self.ttl
    }

    /// 已是新鲜则跳过。返回 true = 实际执行了刷新且成功。
    @discardableResult
    func refreshIfStale() async -> Bool {
        guard isStale else { return false }
        return await refreshRemote()
    }

    /// 拉 models.dev 全量 api.json, 解析后写 ~/.mangox/catalog/modelsdev.json。
    @discardableResult
    func refreshRemote() async -> Bool {
        guard let (data, resp) = try? await URLSession.shared.data(from: Self.remoteURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let index = Self.parse(data), !index.isEmpty else { return false }
        providers = index
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let encoded = Self.encode(index) {
            try? encoded.write(to: url, options: .atomic)
        }
        return true
    }

    // MARK: - 解析/序列化 (统一 {provider: {models: {id: entry}}} 形制)

    static func parse(_ data: Data?) -> [String: [String: CatalogModelEntry]]? {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var index: [String: [String: CatalogModelEntry]] = [:]
        for (providerId, pv) in root {
            guard let pv = pv as? [String: Any],
                  let models = pv["models"] as? [String: Any] else { continue }
            var bucket: [String: CatalogModelEntry] = [:]
            for (modelId, mv) in models {
                guard let mv = mv as? [String: Any] else { continue }
                bucket[modelId] = parseEntry(mv)
            }
            if !bucket.isEmpty { index[providerId] = bucket }
        }
        return index.isEmpty ? nil : index
    }

    static func parseEntry(_ mv: [String: Any]) -> CatalogModelEntry {
        var cost: ModelCost?
        if let c = mv["cost"] as? [String: Any] {
            func d(_ k: String) -> Double { c[k] as? Double ?? 0 }
            cost = ModelCost(input: d("input"), output: d("output"),
                             cacheRead: d("cacheRead"), cacheWrite: d("cacheWrite"))
        }
        return CatalogModelEntry(
            name: mv["name"] as? String ?? "",
            reasoning: mv["reasoning"] as? Bool ?? false,
            input: mv["input"] as? [String] ?? ["text"],
            contextWindow: mv["contextWindow"] as? Int,
            maxTokens: mv["maxTokens"] as? Int,
            cost: cost)
    }

    static func encode(_ index: [String: [String: CatalogModelEntry]]) -> Data? {
        var root: [String: Any] = [:]
        for (pid, models) in index {
            var mb: [String: Any] = [:]
            for (mid, e) in models {
                var m: [String: Any] = ["name": e.name, "reasoning": e.reasoning, "input": e.input]
                if let w = e.contextWindow { m["contextWindow"] = w }
                if let t = e.maxTokens { m["maxTokens"] = t }
                if let c = e.cost {
                    m["cost"] = ["input": c.input, "output": c.output,
                                 "cacheRead": c.cacheRead, "cacheWrite": c.cacheWrite]
                }
                mb[mid] = m
            }
            root[pid] = ["models": mb]
        }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
