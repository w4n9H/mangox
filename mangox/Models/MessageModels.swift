//
//  MessageModels.swift
//

import Foundation

enum MessageRole: String, Codable, Hashable {
    case user, assistant, system
}

/// Message content variants.
/// - text       : plain assistant text
/// - think      : collapsible "思考过程" card (amber left rail)
/// - tool       : tool call card (colored left rail + label)
/// - plan       : plan question card with options
/// - compaction : 上下文压缩的**常驻**系统标记 (见该 case 的注释)
enum MessageContent: Hashable, Codable {
    case text(String)
    case think(String)
    case tool(ToolCall)
    case plan(PlanQuestion)
    /// 上下文压缩成功的**常驻**标记 (role 恒 `.system`)。
    ///
    /// 为什么必须有它: pi 压缩后**原始条目仍在磁盘**(消息列表看起来没变短), 但模型侧
    /// 只剩摘要 + 最近 `keepRecentTokens` —— 于是 UI 上最可信的那块(往上翻到的原文)
    /// 恰好是模型已经看不见的部分, 而底栏那两条提示(胶囊 / 横幅)**都会飘走**。
    ///
    /// 为什么存结构化字段而不是拼好的一句话:
    /// ① 文案要在**渲染期**取词 (存字符串 = 切语言后这条永远停在旧语言);
    /// ② 数字是**证据** —— 存下来才能在回看时知道这次压缩付出了多少。
    ///
    /// `reason` = pi 的原值 (`manual` / `threshold` / `overflow`), **刻意是 String**:
    /// 第三方契约值, 不认识的原因也要照实存下来 (枚举 decode 失败会让整条事实消失)。
    /// 它是"谁触发的"这一维 —— 回看时"我自己压的"和"它自己压的"是两件事。
    ///
    /// ⚠️ 只有**成功**压缩才落这个 case。中止/失败仍走 8s 横幅 —— 什么都没变,
    ///    不值得在历史里留一行(失败信息归 Trace, 常驻行只记"事实发生过的改变")。
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String)
}

/// P5.0.1: 单次 LLM 调用的用量 (pi message_end 捕获; 轨迹视图/将来成本计算的数据源)。
struct MessageUsage: Hashable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0
    var totalTokens: Int = 0
    /// P6.0③: pi 按 model registry 单价算好的本次调用成本 (USD); nil = 无上报/旧数据。
    var costUSD: Double?
    /// 消息级模型 (中途切模型不串)。
    var model: String?
    /// 本次调用的 call id (pi responseId)。
    var responseId: String?
}

struct ChatMessage: Identifiable, Hashable, Codable {
    let id: UUID
    let role: MessageRole
    var content: MessageContent
    let timestamp: Date
    var isStreaming: Bool
    /// 该消息产出的 LLM 用量 (assistant 专属; nil = 未上报/旧数据)。
    var usage: MessageUsage?
    /// P7-M6: 用户消息图片附件 (路径+尺寸+mime, 磁盘存原图; nil = 无/旧数据)。
    var attachments: [Attachment]?

    init(id: UUID = UUID(),
         role: MessageRole,
         content: MessageContent,
         timestamp: Date = .now,
         isStreaming: Bool = false,
         usage: MessageUsage? = nil,
         attachments: [Attachment]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.usage = usage
        self.attachments = attachments
    }
}
