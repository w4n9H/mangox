//
//  caseModelCatalogCompat —— 模型目录兼容层: apiType/模态/compat 解析
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家 + dir→fixturesRoot 等价替换）。
//  原位替换为 `await caseModelCatalogCompat()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseModelCatalogCompat() async {
        print("== T21 P7-M2: 模型自管真源 + 物化 ==")
        guard let mdb = try? PersistenceStore(path: fixturesRoot + "/t21.db") else {
            check(false, "T21 建 DB"); report()
        }
        try? mdb.migrate()

        let cost = ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0.2,
                             tiers: [ModelCost.Tier(inputTokensAbove: 200_000, input: 2, output: 4, cacheRead: 0.2, cacheWrite: 0.4)])
        let mA = ManagedModel(provider: "mangox-gw", modelId: "mangox-mini", displayName: "MangoX Mini",
                              apiType: "openai-completions", baseURL: "https://gw.invalid/v1",
                              keyRef: "mangox-gw", contextWindow: 131_072, maxTokens: 8_192,
                              inputModalities: ["text", "image"], cost: cost,
                              thinkingLevelMapJSON: "{\"high\":\"default\",\"low\":null}",
                              compatJSON: "{\"supportsDeveloperRole\":false}",
                              source: .preset)
        let mB = ManagedModel(provider: "mangox-gw", modelId: "mangox-max", displayName: "MangoX Max",
                              apiType: "openai-completions", baseURL: "https://gw.invalid/v1",
                              keyRef: "mangox-gw", source: .preset)
        let mC = ManagedModel(provider: "fake-anthropic", modelId: "fake-sonnet", displayName: "Fake Sonnet",
                              apiType: "anthropic-messages", baseURL: "https://fake.invalid/v1",
                              enabled: false, source: .custom)
        try? mdb.upsertManagedModel(mA)
        try? mdb.upsertManagedModel(mB)
        try? mdb.upsertManagedModel(mC)

        let loaded = (try? mdb.loadManagedModels()) ?? []
        check(loaded.count == 3, "T21 CRUD 往返 3 条")
        let la = loaded.first { $0.modelId == "mangox-mini" }
        check(la?.cost?.tiers?.first?.inputTokensAbove == 200_000, "T21 cost+tiers 往返")
        check(la?.inputModalities == ["text", "image"], "T21 input_modalities 往返")
        check(la?.thinkingLevelMapJSON == "{\"high\":\"default\",\"low\":null}", "T21 原样 JSON 透传 (thinkingLevelMap)")
        check(la?.compatJSON == "{\"supportsDeveloperRole\":false}", "T21 compat 透传")

        var mA2 = mA; mA2.displayName = "Mini v2"; mA2.enabled = false
        try? mdb.upsertManagedModel(mA2)
        check(((try? mdb.loadManagedModels()) ?? []).count == 3, "T21 同 PK 覆盖不新增")
        try? mdb.upsertManagedModel(mA)
        try? mdb.deleteManagedModel(provider: "fake-anthropic", modelId: "fake-sonnet")
        check(((try? mdb.loadManagedModels()) ?? []).count == 2, "T21 delete 生效")
        try? mdb.upsertManagedModel(mC)

        // 旧表写入用底层句柄: 生产路径已无写入者 (P5.1 层已删), 这里造"旧版本 MangoX 写的库"
        let t21Path = fixturesRoot + "/t21.db"
        if let raw = try? Database(path: t21Path) {
            try? raw.run("INSERT INTO custom_models (provider, model_id, label, created_at) VALUES (?,?,?,?)",
                         [.text("deepseek"), .text("deepseek-chat"), .text("DeepSeek Chat"), .real(1)])
            try? raw.run("INSERT INTO custom_models (provider, model_id, label, created_at) VALUES (?,?,?,?)",
                         [.text("kimi"), .text("kimi-k2"), .text(""), .real(2)])
        }
        let migrated = (try? mdb.migrateLegacyCustomModels()) ?? -1
        check(migrated == 2, "T21 legacy 迁移 2 条")
        let afterMig = (try? mdb.loadManagedModels()) ?? []
        let legacy = afterMig.first { $0.source == .legacy && $0.provider == "deepseek" }
        check(legacy != nil && legacy?.apiType == "openai-completions" && legacy?.baseURL == nil,
              "T21 legacy 条目 source/apiType/无 baseURL")
        check(((try? mdb.migrateLegacyCustomModels()) ?? -1) == 0, "T21 迁移幂等 (重跑 0)")
        var t21LegacyKept = 0
        if let afterDb = try? Database(path: t21Path, readonly: true),
           let rows = try? afterDb.query("SELECT provider FROM custom_models") {
            t21LegacyKept = rows.count
        }
        check(t21LegacyKept == 2, "T21 旧表保留")

        let keys = InMemoryModelKeyStore()
        try? keys.setKey("sk-test-123", account: "mangox-gw")
        let all = (try? mdb.loadManagedModels()) ?? []
        let out = ModelMaterializer.materialize(all, keyProvider: { keys.key(account: $0) })
        guard let providersObj = (try? JSONSerialization.jsonObject(with: out.modelsJSON)) as? [String: Any],
              let providers = providersObj["providers"] as? [String: Any] else {
            check(false, "T21 物化 JSON 可解析"); report()
        }
        check(providers.count == 3, "T21 disabled 排除 + legacy 进物化 (3 providers)")
        let gw = providers["mangox-gw"] as? [String: Any]
        check(gw?["baseUrl"] as? String == "https://gw.invalid/v1" && gw?["api"] as? String == "openai-completions",
              "T21 provider 级 baseUrl/api")
        let gwModels = gw?["models"] as? [[String: Any]] ?? []
        let mini = gwModels.first { ($0["id"] as? String) == "mangox-mini" }
        check(mini?["input"] as? [String] == ["text", "image"] && mini?["cost"] != nil
              && (mini?["contextWindow"] as? Int) == 131_072, "T21 model 级元数据 (input/cost/contextWindow)")
        check(mini?["thinkingLevelMap"] != nil, "T21 thinkingLevelMap 片段透传")
        let dsProv = providers["deepseek"] as? [String: Any]
        check(dsProv?["baseUrl"] == nil && (dsProv?["models"] as? [[String: Any]])?.isEmpty == false,
              "T21 legacy 无 baseUrl 省略")
        guard let authObj = (try? JSONSerialization.jsonObject(with: out.authJSON)) as? [String: Any] else {
            check(false, "T21 auth JSON 可解析"); report()
        }
        check((authObj["mangox-gw"] as? [String: Any])?["type"] as? String == "api_key"
              && authObj["deepseek"] == nil, "T21 auth.json 按 provider 且无 key 不进")

        let out2 = ModelMaterializer.materialize(all, keyProvider: { keys.key(account: $0) })
        check(out.fingerprint == out2.fingerprint, "T21 fingerprint 确定性")
        var mA3 = mA; mA3.maxTokens = 4_096
        let out3 = ModelMaterializer.materialize(all.map { $0.modelId == "mangox-mini" ? mA3 : $0 },
                                                 keyProvider: { keys.key(account: $0) })
        check(out3.fingerprint != out.fingerprint, "T21 fingerprint 变更敏感")

        let cfgDir = URL(fileURLWithPath: fixturesRoot).appendingPathComponent("pi-config", isDirectory: true)
        check(((try? ModelMaterializer.writeIfNeeded(out, to: cfgDir)) ?? false) == true, "T21 首次物化写入")
        let authAttrs = (try? FileManager.default.attributesOfItem(
            atPath: cfgDir.appendingPathComponent("auth.json").path)) ?? [:]
        check((authAttrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600, "T21 auth.json 0600 权限")
        check(((try? ModelMaterializer.writeIfNeeded(out, to: cfgDir)) ?? true) == false, "T21 指纹不变跳写")
        check(((try? ModelMaterializer.writeIfNeeded(out3, to: cfgDir)) ?? false) == true, "T21 变更后重写")
    }
}
