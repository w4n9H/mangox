//
//  StatusBarModels.swift
//  P6.1.1: 状态栏数据模型。
//  展示裁剪为 4 项纯展示: 过程态胶囊 · 上下文 % · Token ↑↓ · 缓存 %
//  (费用/轮数 → Trace; 模型/思考 → composer 菜单; P6 设计 §2.2 拍板)。
//

import Foundation

/// P6.1.1: 会话统计 (pi get_session_stats + message_update 顶层 usage 的保守投影)。
///
/// `contextPercent == nil` 的唯一含义 = **本会话一次统计都还没上报过** (UI 显示 "--")。
/// ⚠️ 旧注释写的是"刚压缩完 → nil" —— **那是错的**, 而且掩盖了一个真 bug:
///    `pi` 在压缩后确实把 `contextUsage.percent` 报成 null (`rpc-commands.md`:
///    "null immediately after compaction until a fresh post-compaction assistant response"),
///    但 `ChatStore.applySessionStats` 遇到 null 是**沿用上次的值** ⇒ 底栏挂着的其实是
///    **压缩前**那个百分比。现在由 `compaction_end` 的 `estimatedTokensAfter` 当场改写
///    (`ChatStore.applyCompactionTokens`), 所以这个 nil 分支只剩"从没上报过"一种来源。
struct SessionStats {
    var contextPercent: Double?
    var contextTokens: Int = 0
    var contextWindow: Int = 0
    /// pi 的压缩预算 (`compaction.reserveTokens`, 见 `PiCompactionBudget`)。0 = 未解析到。
    /// ⚠️ 它不参与任何计算以外的判断 —— 只用来**画那条线**, 不影响我们这边任何行为。
    var contextReserveTokens: Int = 0
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

    /// 压缩线 (占窗口的百分比) = (contextWindow - reserveTokens) / contextWindow。
    /// 窗口或预算未知、或预算大到线落在窗口外 ⇒ nil (底栏退回只显示百分比)。
    /// 判据取自 `docs/compaction.md`: `contextTokens > contextWindow - reserveTokens` 才触发。
    var compactionLinePercent: Double? {
        guard contextWindow > 0, contextReserveTokens > 0 else { return nil }
        let line = Double(contextWindow - contextReserveTokens)
        guard line > 0 else { return nil }
        return line / Double(contextWindow) * 100
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

    /// 胶囊文案 (P6 设计 §2.3)。**域层 String: 必须显式 L()** —— 字面量本身不吃本地化。
    var capsuleText: String {
        switch self {
        case .idle:                          return "idle"
        case .streaming:                     return "streaming"
        case .retrying(let a, let m, let d):
            return String(format: L("重试 %lld/%lld · %llds 后"), a, m, (d + 999) / 1000)
        case .compacting(let reason):        return Copy.compactingCapsule(reason: reason)
        case .summarizing:                   return L("摘要重试中…")
        case .queued(let n):                 return String(format: L("排队 %lld 条"), n)
        }
    }

    var isIdle: Bool { self == .idle }
}
