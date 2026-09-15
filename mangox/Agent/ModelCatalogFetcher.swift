//
//  ModelCatalogFetcher.swift
//  P7-M3: 测试连接 + /models 清单拉取 (直连, 不经 pi)。
//  失败不阻断保存 (回落 seedModels); parse 纯函数供冒烟。
//

import Foundation

enum ModelCatalogFetcher {

    struct Result {
        let modelIds: [String]
        let verified: Bool       // false = 拉取失败, 走 seed 兜底
        let error: String?
    }

    /// OpenAI {"data":[{"id":..}]} / Ollama {"models":[{"name":..}]} / 顶层数组; 不认识 → nil。
    static func parseModelIds(_ data: Data) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var ids: [String] = []
        if let dict = obj as? [String: Any] {
            if let arr = dict["data"] as? [[String: Any]] {
                ids = arr.compactMap { $0["id"] as? String }
            } else if let arr = dict["models"] as? [[String: Any]] {
                ids = arr.compactMap { ($0["name"] as? String) ?? ($0["id"] as? String) }
            }
        } else if let arr = obj as? [String] {
            ids = arr
        }
        ids = ids.filter { !$0.isEmpty }
        return ids.isEmpty ? nil : ids
    }

    static func modelsURL(baseURL: String, ollamaStyle: Bool) -> URL? {
        var base = baseURL
        if ollamaStyle {
            // http://host:11434/v1 → http://host:11434/api/tags
            base = base.replacingOccurrences(of: "/v1", with: "")
            return URL(string: base.hasSuffix("/") ? base + "api/tags" : base + "/api/tags")
        }
        return URL(string: base.hasSuffix("/") ? base + "models" : base + "/models")
    }

    /// 异步拉取; HTTP 非 200 / 解析失败 → verified=false。
    static func fetch(baseURL: String, apiKey: String?, apiType: String,
                      ollamaStyle: Bool) async -> Result {
        guard let url = modelsURL(baseURL: baseURL, ollamaStyle: ollamaStyle) else {
            return Result(modelIds: [], verified: false, error: "base URL 无效")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if let apiKey, !apiKey.isEmpty {
            if apiType == "anthropic-messages" {
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                return Result(modelIds: [], verified: false, error: "HTTP \(code)")
            }
            guard let ids = parseModelIds(data) else {
                return Result(modelIds: [], verified: false, error: "响应格式不认识")
            }
            return Result(modelIds: ids, verified: true, error: nil)
        } catch {
            return Result(modelIds: [], verified: false, error: error.localizedDescription)
        }
    }
}
