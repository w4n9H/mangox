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
    let needsKey: Bool                // 当前 4 家全 true; false 留给本地/免鉴权端点
    let ollamaStyle: Bool             // /api/tags 清单接口 (当前无预设用; 留给自定义端点)
    /// 该 **provider 固有的** 请求体采样参数 (JSON 文本), 物化时作为每个模型的默认值。
    ///
    /// 为什么放在 provider 级: 这类参数是厂商 API 的固有契约, 与具体模型无关 ——
    /// 例: MiniMax 的 `reasoning_split` (不传则思考混在 `content` 里)。pi 的 schema 只在
    /// **model 条目**上有 `samplingParams` (没有 provider 级), 所以由我们在物化时降维展开。
    /// ⚠️ 与 pi 语义对齐: **模型自带者优先** (见 `ModelMaterializer`), 这里只是缺省值。
    var samplingParams: String? = nil
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
    /// 内置预设。P13 起重整为 4 家 (deepseek / kimi / minimax / zhipu-GLM) ——
    /// 其余 (qwen / openai / anthropic / ollama) 已从库里移除; 加回 = 在此加一条数据。
    /// ⚠️ 移除 preset **不影响**已保存的自管模型 (它们存的是自己的元数据快照, 不是引用 preset);
    ///    只是这两家以后不能再从芯片一键载入。
    /// ⚠️ `ollamaStyle` / `needsKey: false` 目前无任何预设引用 (Ollama 预设已移除) —— 能力保留:
    ///    自定义 provider 仍可指 Ollama 的 OpenAI 兼容口 (`http://localhost:11434/v1`)。
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
                // 2026-07-16 发布, 元数据取自 models.dev `moonshotai` (== `moonshotai-cn`, 两组内容一致)。
                // ⚠️ 旧种子 (kimi-k2-0905-preview / kimi-latest) 已不在目录里, 2026-10-09 换掉。
                // Map: 官方 reasoning_options 只给 effort [low,high,max] 且**不可关**
                // ⇒ off/minimal/medium/xhigh 置 null (滑轨上不出现; 被请求时 pi 夹到 low),
                //    避免「缺键 = 默认支持」把 off 放上滑轨却发不出合法值。
                .init("kimi-k3", "Kimi K3", reasoning: true,
                      input: ["text", "image"], contextWindow: 1_048_576, maxTokens: 1_048_576,
                      cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3),
                      thinkingLevelMap: "{\"off\":null,\"minimal\":null,\"low\":\"low\",\"medium\":null,\"high\":\"high\",\"xhigh\":null,\"max\":\"max\"}"),
            ]),
        ProviderPreset(
            id: "minimax", displayName: "MiniMax", baseURL: "https://api.minimaxi.com/v1",
            apiType: "openai-completions", needsKey: true, ollamaStyle: false,
            // ⚠️ `reasoning_split` 是 MiniMax 的**固有契约**: 不传则思考直接混在 `content` 里
            //    (形如 `<think>…</think>` + 答案), 被 pi 当正文推给 UI —— pi **不做任何 `<think>` 剥离**
            //    (pi-ai/dist/api/openai-completions.js:385-395)。
            //    带上 ⇒ 正文干净, 思考走 `reasoning_content` —— 那是 pi 取推理字段的**第一顺位**
            //    (同文件 :400) ⇒ 落 thinking_delta ⇒ 进思考卡片。**净收益**, 不是拿"丢思考"换干净正文。
            //    M3.1-Flash-Preview 默认就分开 (订阅制端点行为不同), 传了无害。
            //    复现 (要真 key): python3 scripts/diag/mm_reasoning_split_probe.py --assert
            samplingParams: "{\"reasoning_split\":true}",
            seedModels: [
                // MiniMax-M3.1-Flash-Preview (2026-09-27 发布)。⚠️ 更正: 它**在** models.dev, 但只出现在
                // `minimax-cn-coding-plan` / `minimax-coding-plan` 两个订阅制组里, 不在 pay-as-you-go 的
                // `minimax` / `minimax-cn` 组 ⇒ 我们按 alias 读 `minimax` 时拉不到它, 种子仍是唯一来源。
                // 元数据取 models.dev 的 coding-plan 组 (窗口 1_000_000 / 输出 512_000 / 订阅制无单价)。
                // ⚠️ thinkingLevelMap 必须显式给: 缺 map 时 pi 走 off..high 默认档 ⇒ 实测 off 静默
                //    变成服务端默认 max (最贵最慢)、xhigh/max 被夹成 high。off/minimal 置 null ⇒ pi 夹到 low。
                // ⚠️ input 不能写 "video" (pi schema 只认 text|image), 写了整条 models.json 会被丢弃。
                .init("MiniMax-M3.1-Flash-Preview", "MiniMax-M3.1 Flash Preview", reasoning: true,
                      input: ["text", "image"], contextWindow: 1_000_000, maxTokens: 512_000,
                      cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                      thinkingLevelMap: "{\"off\":null,\"minimal\":null,\"low\":\"low\",\"medium\":\"medium\",\"high\":\"high\",\"xhigh\":\"xhigh\",\"max\":\"max\"}"),
                // 下面三条元数据对齐 models.dev `minimax` 组 (2026-10-09 校对; reasoning=true 无 map = pi 默认 off..high)。
                .init("MiniMax-M3", "MiniMax-M3", reasoning: true,
                      input: ["text", "image"], contextWindow: 1_000_000, maxTokens: 512_000,
                      cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0)),
                .init("MiniMax-M2.7", "MiniMax-M2.7", reasoning: true,
                      contextWindow: 204_800, maxTokens: 131_072,
                      cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0.375)),
                .init("MiniMax-M2.7-highspeed", "MiniMax-M2.7 Highspeed", reasoning: true,
                      contextWindow: 204_800, maxTokens: 131_072,
                      cost: ModelCost(input: 0.6, output: 2.4, cacheRead: 0.06, cacheWrite: 0.375)),
            ]),
        ProviderPreset(
            id: "zhipu", displayName: "GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4",
            apiType: "openai-completions", needsKey: true, ollamaStyle: false,
            seedModels: [
                // 取 models.dev `zai` 组里最新的两条 (2026-10-09)。
                // ⚠️ 旧种子 glm-4.6 (2025-09-30) / glm-4.5-air (2025-07-28) 已过时一年 ⇒ 换掉。
                // ⚠️ 目录里他们的 modalities.input 含 video/pdf —— pi schema 只认 text|image, 这里只取 text+image。
                // Map 同 Kimi: effort [low,high,max] 且不可关。
                .init("glm-5.3-flashx", "GLM-5.3-FlashX", reasoning: true,
                      input: ["text", "image"], contextWindow: 1_000_000, maxTokens: 131_072,
                      cost: ModelCost(input: 0.37, output: 1.25, cacheRead: 0.075, cacheWrite: 0),
                      thinkingLevelMap: "{\"off\":null,\"minimal\":null,\"low\":\"low\",\"medium\":null,\"high\":\"high\",\"xhigh\":null,\"max\":\"max\"}"),
                .init("glm-5.3-flash", "GLM-5.3-Flash", reasoning: true,
                      input: ["text", "image"], contextWindow: 1_000_000, maxTokens: 131_072,
                      cost: ModelCost(input: 0.15, output: 0.5, cacheRead: 0.03, cacheWrite: 0),
                      thinkingLevelMap: "{\"off\":null,\"minimal\":null,\"low\":\"low\",\"medium\":null,\"high\":\"high\",\"xhigh\":null,\"max\":\"max\"}"),
            ]),
    ]

    /// provider id 是否为内置预设。
    static func preset(id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }

    /// 「vendor 的 `/models` 清单里没有、但种子里有」的 id（保持传入顺序）。
    ///
    /// ⚠️ **候选不能简单等于 `/models`**：订阅制 / 隐藏模型（如 `MiniMax-M3.1-Flash-Preview`）**永远不会**
    /// 出现在官方清单里，而我们**正是为它们**维护种子 ⇒ 纯替换会把唯一的补丁删掉。
    /// 实测：真 key + 该 model id ⇒ 200（同名回显），假 id ⇒ 400 `unknown model` ⇒ 它是在售的，
    /// 只是 `/models` 结构性列不出来。所以式子是 **`/models` ∪ 未列出的种子**。
    static func vendorUnlisted(returned: [String], seedIds: [String]) -> [String] {
        let seen = Set(returned)
        return seedIds.filter { !seen.contains($0) }
    }
}
