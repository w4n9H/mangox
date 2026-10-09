//
//  ModelCatalog.swift
//  P7-M3.5: 模型元数据目录 — models.dev 自有化三层 (bundled 快照 > 远端缓存 > 空)。
//  运行时零依赖 ~/.pi/agent; 目录只补元数据 (名称/思考/窗口/价格), id 清单仍以 /models 实拉为准。
//

import Foundation

/// 目录条目 (models.dev 6 字段剪裁 + 发布日期)。
struct CatalogModelEntry: Hashable {
    var name: String
    var reasoning: Bool
    var input: [String]
    var contextWindow: Int?
    var maxTokens: Int?
    var cost: ModelCost?
    /// 发布日期 (ISO `yyyy-MM-dd`)。⚠️ 存字符串不存 Date —— 字典序即时间序, 直接拿来排序,
    /// 且不受时区/locale 影响。缺省 nil (bundled 快照没这个字段) ⇒ 排到最后, 不假装最新。
    var releaseDate: String? = nil
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

    /// 本地缓存 schema 版本。解析键名 / 条目字段一旦变化就必须递增 —— 旧解析器已把窗口/输出/模态/缓存价
    /// 压成 nil 或默认值, 而 mtime 还新鲜 (TTL 7 天) 不会重拉, 只能靠版本戳把这份缓存判死。
    /// v2 = 修正线上键名; v3 = 条目加 releaseDate (缺了它就排不出「新版在前」)。
    static let cacheSchemaVersion = 3

    private(set) var providers: [String: [String: CatalogModelEntry]] = [:]

    /// loadCached 置位: 盘上缓存是否按当前 schema 版本成功解码。
    /// false ⇒ isStale 恒 true ⇒ 下次巡检 (点预设芯片) 必然重拉, 不等 TTL。
    private var cacheValid = false

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
        if let idx = Self.decode(Self.data(at: Self.cacheURL)) {
            providers = idx
            cacheValid = true
        } else {
            providers = Self.parse(Self.bundledData()) ?? [:]
            cacheValid = false
        }
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

    /// 指定 provider 的全部条目 (仅精确 + 别名, 不模糊), **新版在前** — loadPreset 展开用。
    /// ⚠️ 排序是「一眼看到的是不是最新模型」的判据本身, 所以住在 model 层 (可被冒烟断言),
    ///    不写在视图里。日期相同或缺失时按 id 升序, 保证顺序稳定可复现。
    func entriesNewestFirst(provider: String) -> [(id: String, entry: CatalogModelEntry)] {
        let bucket = providers[provider] ?? providers[Self.providerAliases[provider] ?? ""] ?? [:]
        return bucket.map { (id: $0.key, entry: $0.value) }
            .sorted {
                let a = $0.entry.releaseDate ?? "", b = $1.entry.releaseDate ?? ""
                return a == b ? $0.id < $1.id : a > b
            }
    }

    // MARK: - 远端刷新 (静默失败, 7 天 TTL)

    var isStale: Bool {
        guard cacheValid,
              let attr = try? FileManager.default.attributesOfItem(atPath: Self.cacheURL.path),
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
        cacheValid = true   // 盘上已是当前 schema 版本的有效缓存 ⇒ isStale 交回 TTL 判, 否则每次点芯片都重拉
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

    /// 条目解析 — 同时兼容 models.dev 线上形制与 MangoX 自有扁平形制。
    ///
    /// ⚠️ 两套形制的键名不同, 曾按扁平名去读线上数据 ⇒ 全表 8462 条的窗口/输出/模态/缓存价
    ///    静默丢失 (唯一可见症状: 候选列表的 `image` 徽章对目录来的模型从不点亮)。
    ///    线上: limit.context / limit.output / modalities.input / cost.cache_read / cost.cache_write
    ///    扁平: contextWindow / maxTokens / input / cost.cacheRead / cost.cacheWrite (bundled 快照与本地缓存)
    static func parseEntry(_ mv: [String: Any]) -> CatalogModelEntry {
        var cost: ModelCost?
        if let c = mv["cost"] as? [String: Any] {
            func d(_ keys: String...) -> Double {
                for k in keys { if let v = num(c[k]) { return v } }
                return 0
            }
            cost = ModelCost(input: d("input"), output: d("output"),
                             cacheRead: d("cache_read", "cacheRead"),
                             cacheWrite: d("cache_write", "cacheWrite"))
        }
        let limit = mv["limit"] as? [String: Any] ?? [:]
        let modalities = mv["modalities"] as? [String: Any] ?? [:]
        let rawInput = (modalities["input"] as? [String]) ?? (mv["input"] as? [String]) ?? ["text"]
        // pi 的 input schema 只认 text|image; 混进 "video" 会让整条 models.json 被引擎丢弃
        // (回落内置 provider 打真 API ⇒ 表现为莫名的 401)。这里先过滤, 过滤空了退回 ["text"]。
        let input = rawInput.filter { $0 == "text" || $0 == "image" }
        return CatalogModelEntry(
            name: mv["name"] as? String ?? "",
            reasoning: mv["reasoning"] as? Bool ?? false,
            input: input.isEmpty ? ["text"] : input,
            contextWindow: int(limit["context"]) ?? int(mv["contextWindow"]),
            maxTokens: int(limit["output"]) ?? int(mv["maxTokens"]),
            cost: cost,
            releaseDate: (mv["release_date"] as? String) ?? (mv["releaseDate"] as? String))
    }

    /// JSONSerialization 的数值一律是 NSNumber (整数也可能落成 Int), 统一走这里取值。
    private static func num(_ v: Any?) -> Double? {
        guard let v else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func int(_ v: Any?) -> Int? { num(v).map { Int($0) } }

    /// 写带版本戳的本地缓存形制 {schemaVersion, catalog}。
    static func encode(_ index: [String: [String: CatalogModelEntry]]) -> Data? {
        var root: [String: Any] = [:]
        for (pid, models) in index {
            var mb: [String: Any] = [:]
            for (mid, e) in models {
                var m: [String: Any] = ["name": e.name, "reasoning": e.reasoning, "input": e.input]
                if let w = e.contextWindow { m["contextWindow"] = w }
                if let t = e.maxTokens { m["maxTokens"] = t }
                if let d = e.releaseDate { m["releaseDate"] = d }
                if let c = e.cost {
                    m["cost"] = ["input": c.input, "output": c.output,
                                 "cacheRead": c.cacheRead, "cacheWrite": c.cacheWrite]
                }
                mb[mid] = m
            }
            root[pid] = ["models": mb]
        }
        return try? JSONSerialization.data(
            withJSONObject: ["schemaVersion": cacheSchemaVersion, "catalog": root],
            options: [.sortedKeys])
    }

    /// 读本地缓存; 版本戳缺失或不符 (旧解析器写的坏缓存) 一律返回 nil, 当作没有缓存。
    static func decode(_ data: Data?) -> [String: [String: CatalogModelEntry]]? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schemaVersion"] as? Int == cacheSchemaVersion,
              let catalog = root["catalog"] else { return nil }
        return parse(try? JSONSerialization.data(withJSONObject: catalog))
    }
}
