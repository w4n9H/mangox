//
//  StatusBarModels.swift
//  P6.1.1: 状态栏数据模型。
//  展示裁剪为 4 项纯展示: 过程态胶囊 · 上下文 % · Token ↑↓ · 缓存 %
//  (费用/轮数 → Trace; 模型/思考 → composer 菜单; P6 设计 §2.2 拍板)。
//

import Foundation

/// P6.1.1: 会话统计 (pi get_session_stats + message_update 顶层 usage 的保守投影)。
/// contextPercent == nil = 刚压缩完 / 尚未上报 (pi 侧置 null), UI 显示 "--"。
struct SessionStats {
    var contextPercent: Double?
    var contextTokens: Int = 0
    var contextWindow: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var costUSD: Double?

    /// 缓存命中率 = cacheRead / (input + cacheRead); 无分母时 nil (Trace 用, 状态栏不展示)。
    var cachePercent: Double? {
        let denom = inputTokens + cacheReadTokens
        guard denom > 0 else { return nil }
        return Double(cacheReadTokens) / Double(denom) * 100
    }
}

/// P6.1.2: 回合过程态 (transport 按 pi 事件驱动)。
/// idle/streaming 之外的过程态用 amber 胶囊 (警示但不响)。
enum RuntimePhase: Equatable {
    case idle
    case streaming
    /// auto_retry_start {attempt, maxAttempts, delayMs}
    case retrying(attempt: Int, maxAttempts: Int, delayMs: Int)
    /// compaction_start {reason: manual/threshold/overflow}
    case compacting(reason: String)
    /// summarization_retry_scheduled / _attempt_start
    case summarizing
    /// queue_update (steering + followUp 合计; 清空回 streaming)
    case queued(count: Int)

    /// 胶囊文案 (P6 设计 §2.3)。
    var capsuleText: String {
        switch self {
        case .idle:                          return "idle"
        case .streaming:                     return "streaming"
        case .retrying(let a, let m, let d): return "重试 \(a)/\(m) · \((d + 999) / 1000)s 后"
        case .compacting(let reason):        return "压缩中（\(reason)）…"
        case .summarizing:                   return "摘要重试中…"
        case .queued(let n):                 return "排队 \(n) 条"
        }
    }

    var isIdle: Bool { self == .idle }
}
