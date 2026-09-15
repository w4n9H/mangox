//
//  ProviderPresets.swift
//  P7-M3: 内置 provider 预设库 (静态数据, 不入库)。
//  主路径 = 测试连接拉 /models 让用户勾选; seedModels = 推荐预勾 + 拉取失败兜底。
//  加预设 = 加一条数据; 后续可做远端 JSON 更新。
//

import Foundation

struct ProviderPreset: Identifiable, Hashable {
    let id: String                    // provider id (物化进 pi models.json 的 provider 键)
    let displayName: String
    let baseURL: String
    let apiType: String
    let needsKey: Bool                // Ollama = false
    let ollamaStyle: Bool             // /api/tags 清单接口
    let seedModels: [SeedModel]

    struct SeedModel: Hashable {
        let id: String
        let name: String
        var reasoning: Bool
        var input: [String]
        var contextWindow: Int
        var maxTokens: Int
        var cost: ModelCost?
        /// thinkingLevelMap JSON 片段 (null = 该级别不支持); nil = 无 map (pi 默认 off..high)。
        var thinkingLevelMap: String?

        init(_ id: String, _ name: String, reasoning: Bool = false,
             input: [String] = ["text"], contextWindow: Int = 128_000, maxTokens: Int = 8_192,
             cost: ModelCost? = nil, thinkingLevelMap: String? = nil) {
            self.id = id; self.name = name; self.reasoning = reasoning; self.input = input
            self.contextWindow = contextWindow; self.maxTokens = maxTokens; self.cost = cost
            self.thinkingLevelMap = thinkingLevelMap
        }
    }

    var modelsURLHint: String {
        ollamaStyle ? "http://<host>:11434/api/tags" : baseURL + "/models"
    }
}

enum ProviderPresets {
    static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "deepseek", displayName: "DeepSeek", baseURL: "https://api.deepseek.com",
            apiType: "openai-completions", needsKey: true, ollamaStyle: false,
            seedModels: [
                // 对齐 pi 目录缓存 (models-store, 2026-09 权威元数据)。
                .init("deepseek-flash", "DeepSeek V4.1 Flash", reasoning: true,
                      input: ["text", "image"], contextWindow: 1_000_000, maxTokens: 384_000,
                      cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0),
                      thinkingLevelMap: "{\"minimal\":null,\"low\":\"low\",\"medium\":null,\"high\":\"high\",\"max\":\"max\"}"),
                .init("deepseek-v4-pro", "DeepSeek V4 Pro", reasoning: true,
                      contextWindow: 1_000_000, maxTokens: 384_000,
                      cost: ModelCost(input: 1.32, output: 3.96, cacheRead: 0.044, cacheWrite: 0),
                      thinkingLevelMap: "{\"minimal\":null,\"low\":null,\"medium\":null,\"high\":\"high\",\"max\":\"max\"}"),
            ]),
        ProviderPreset(
            id: "kimi", displayName: "Kimi", baseURL: "https://api.moonshot.cn/v1",
            apiType: "openai-completions", needsKey: true, ollamaStyle: false,
            seedModels: [
                .init("kimi-k2-0905-preview", "Kimi K2 0905", reasoning: true, contextWindow: 256_000,
                      cost: ModelCost(input: 0.6, output: 2.5, cacheRead: 0.1, cacheWrite: 0.6)),
                .init("kimi-latest", "Kimi Latest", reasoning: true, input: ["text", "image"], contextWindow: 256_000),
            ]),
        ProviderPreset(
            id: "zhipu", displayName: "GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4",
            apiType: "openai-completions", needsKey: true, ollamaStyle: false,
            seedModels: [
                .init("glm-4.6", "GLM-4.6", reasoning: true, contextWindow: 200_000, maxTokens: 128_000),
                .init("glm-4.5-air", "GLM-4.5 Air", reasoning: true, contextWindow: 128_000),
            ]),
        ProviderPreset(
            id: "qwen", displayName: "Qwen", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            apiType: "openai-completions", needsKey: true, ollamaStyle: false,
            seedModels: [
                .init("qwen3-coder-plus", "Qwen3 Coder Plus", contextWindow: 1_000_000),
                .init("qwen-max", "Qwen Max", contextWindow: 131_072),
                .init("qwen-plus", "Qwen Plus", contextWindow: 131_072),
            ]),
        ProviderPreset(
            id: "minimax", displayName: "MiniMax", baseURL: "https://api.minimaxi.com/v1",
            apiType: "openai-completions", needsKey: true, ollamaStyle: false,
            seedModels: [
                // pi 目录缓存元数据 (reasoning=true 无 map = pi 默认 off..high)。
                .init("MiniMax-M3", "MiniMax-M3", reasoning: true,
                      input: ["text", "image"], contextWindow: 1_048_576, maxTokens: 512_000,
                      cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0)),
                .init("MiniMax-M2.7", "MiniMax-M2.7", reasoning: true,
                      contextWindow: 204_800, maxTokens: 131_072,
                      cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0.375)),
                .init("MiniMax-M2.7-highspeed", "MiniMax-M2.7 Highspeed", reasoning: true,
                      contextWindow: 204_800, maxTokens: 131_072,
                      cost: ModelCost(input: 0.6, output: 2.4, cacheRead: 0.06, cacheWrite: 0.375)),
            ]),
        ProviderPreset(
            id: "openai", displayName: "OpenAI", baseURL: "https://api.openai.com/v1",
            apiType: "openai-completions", needsKey: true, ollamaStyle: false,
            seedModels: [
                .init("gpt-4.1", "GPT-4.1", input: ["text", "image"], contextWindow: 1_047_576, maxTokens: 32_768),
                .init("gpt-4o-mini", "GPT-4o mini", input: ["text", "image"], contextWindow: 128_000),
            ]),
        ProviderPreset(
            id: "anthropic", displayName: "Anthropic", baseURL: "https://api.anthropic.com",
            apiType: "anthropic-messages", needsKey: true, ollamaStyle: false,
            seedModels: [
                .init("claude-sonnet-4-5", "Claude Sonnet 4.5", reasoning: true,
                      input: ["text", "image"], contextWindow: 200_000, maxTokens: 64_000),
                .init("claude-haiku-4-5", "Claude Haiku 4.5", reasoning: true,
                      input: ["text", "image"], contextWindow: 200_000, maxTokens: 64_000),
            ]),
        ProviderPreset(
            id: "ollama", displayName: "Ollama", baseURL: "http://localhost:11434/v1",
            apiType: "openai-completions", needsKey: false, ollamaStyle: true,
            seedModels: [
                .init("llama3.1:8b", "Llama 3.1 8B"),
                .init("qwen2.5-coder:7b", "Qwen2.5 Coder 7B"),
            ]),
    ]

    /// provider id 是否为内置预设。
    static func preset(id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }
}
