//
//  TrajectoryModels.swift
//  P5.0.3: 轨迹事件派生 (纯函数, 无 UI 依赖, 冒烟可测)。
//  数据源 = store.messages (落库 replay + 实时同源 @Published), 零落库改动。
//

import Foundation

/// 轨迹事件行: USER / ASSISTANT / TOOL 三色行 (设计 §1.3)。
struct TrajectoryEvent: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case user, assistant, tool
    }

    let id: UUID
    let kind: Kind
    let timestamp: Date

    /// USER: prompt 全文 (轨迹视图不折叠)。
    var prompt: String = ""

    /// ASSISTANT: 全文 (相邻 think 合并进 thinkText; 仅 think 时即全文)。
    var fullText: String = ""
    var thinkText: String? = nil
    /// usage 明细 (P5.0.1 落库; nil = 未上报/旧数据)。
    var usage: MessageUsage? = nil
    /// 时长估计: 与下一事件的时间差 (末事件未知 → nil)。
    var heuristicMs: Int? = nil

    /// TOOL: 原始工具卡 (phase/durationMs/details 随消息实时翻转)。
    var tool: ToolCall? = nil
}

/// 回合分组: 每个 user prompt 开启一个回合。
struct TrajectoryTurn: Identifiable, Hashable {
    let id: UUID            // 起始 user 消息 id (无 user 开头的隐式回合 = 首条消息 id)
    let index: Int          // 1-based
    let startedAt: Date
    let prompt: String
    var events: [TrajectoryEvent] = []

    var toolCalls: Int { events.filter { $0.kind == .tool }.count }
    /// 回合时长估计: 末事件 ts - 起始 ts (低估末块流式时长)。
    var durationMs: Int? {
        guard let last = events.last else { return nil }
        let ms = Int(last.timestamp.timeIntervalSince(startedAt) * 1000)
        return ms > 0 ? ms : nil
    }
}

/// 摘要头聚合 (Duration / Turns / Calls)。
struct TrajectorySummary: Hashable {
    let durationMs: Int
    let turns: Int
    let calls: Int
}

enum TrajectoryBuilder {

    /// messages → 回合分组事件流。
    /// 规则: user 消息开新回合; 流式中 assistant 不成行 (由视图出「生成中」占位);
    /// think 块合并给同回合后续 text 行 (仅 think 时独占一行); tool 行透传原卡。
    static func turns(from messages: [ChatMessage]) -> [TrajectoryTurn] {
        var turns: [TrajectoryTurn] = []
        var pendingThink: String? = nil
        var pendingThinkId: UUID? = nil

        /// 把挂起的 think 落为 ASSISTANT 行 (think 后无 text 的场景)。
        func flushThink(into ti: Int, fallbackId: UUID) {
            guard let think = pendingThink else { return }
            let ts = turns[ti].events.last?.timestamp ?? turns[ti].startedAt
            turns[ti].events.append(TrajectoryEvent(
                id: pendingThinkId ?? fallbackId, kind: .assistant, timestamp: ts,
                fullText: think))
            pendingThink = nil
            pendingThinkId = nil
        }

        for msg in messages {
            switch (msg.role, msg.content) {
            case (.user, .text(let prompt)):
                turns.append(TrajectoryTurn(
                    id: msg.id, index: turns.count + 1,
                    startedAt: msg.timestamp, prompt: prompt,
                    events: [TrajectoryEvent(id: msg.id, kind: .user,
                                             timestamp: msg.timestamp, prompt: prompt)]))
            case (.assistant, _) where msg.isStreaming:
                continue   // 事件语义: 未落地不成行 (视图出占位行)
            case (.assistant, .think(let think)):
                pendingThink = (pendingThink.map { $0 + think }) ?? think
                pendingThinkId = pendingThinkId ?? msg.id
            case (.assistant, .text(let text)):
                var ti = turns.count - 1
                if ti < 0 {   // 无 user 开头的隐式回合 (历史/异常数据兜底)
                    turns.append(TrajectoryTurn(id: msg.id, index: 1,
                                                startedAt: msg.timestamp, prompt: ""))
                    ti = 0
                }
                turns[ti].events.append(TrajectoryEvent(
                    id: msg.id, kind: .assistant, timestamp: msg.timestamp,
                    fullText: text, thinkText: pendingThink, usage: msg.usage))
                pendingThink = nil
                pendingThinkId = nil
            case (.assistant, .plan(let q)):
                var ti = turns.count - 1
                if ti < 0 {
                    turns.append(TrajectoryTurn(id: msg.id, index: 1,
                                                startedAt: msg.timestamp, prompt: ""))
                    ti = 0
                }
                turns[ti].events.append(TrajectoryEvent(
                    id: msg.id, kind: .assistant, timestamp: msg.timestamp,
                    fullText: q.title, thinkText: pendingThink, usage: msg.usage))
                pendingThink = nil
                pendingThinkId = nil
            case (_, .tool(let tool)):
                var ti = turns.count - 1
                if ti < 0 {
                    turns.append(TrajectoryTurn(id: msg.id, index: 1,
                                                startedAt: msg.timestamp, prompt: ""))
                    ti = 0
                }
                flushThink(into: ti, fallbackId: tool.id)   // think 后无 text 直接待工具 → think 独占一行
                turns[ti].events.append(TrajectoryEvent(
                    id: tool.id, kind: .tool, timestamp: msg.timestamp, tool: tool))
            default:
                break   // system 等不入轨迹
            }
        }
        // 收尾: 末尾残留 think (回合被截断) 独占一行
        if let think = pendingThink, !turns.isEmpty {
            let ti = turns.count - 1
            let ts = turns[ti].events.last?.timestamp ?? turns[ti].startedAt
            turns[ti].events.append(TrajectoryEvent(
                id: pendingThinkId ?? turns[ti].id, kind: .assistant, timestamp: ts,
                fullText: think))
        }

        // 时长估计: 事件与下一事件的时间差
        for ti in turns.indices {
            let events = turns[ti].events
            guard events.count > 1 else { continue }
            var updated = events
            for i in 0..<(updated.count - 1) {
                let ms = Int(updated[i + 1].timestamp.timeIntervalSince(updated[i].timestamp) * 1000)
                if ms > 0 { updated[i].heuristicMs = ms }
            }
            turns[ti].events = updated
        }
        return turns
    }

    static func summary(_ turns: [TrajectoryTurn]) -> TrajectorySummary {
        TrajectorySummary(durationMs: turns.compactMap(\.durationMs).reduce(0, +),
                          turns: turns.count,
                          calls: turns.reduce(0) { $0 + $1.toolCalls })
    }

    /// ASSISTANT 折叠预览: 首句。句号类终止符保留在预览里 (干净收尾不加省略号);
    /// 换行打断 / 超长封顶才补 "…"。
    static func firstSentence(_ text: String, cap: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var end = trimmed.endIndex
        var brokeAtNewline = false
        for (i, ch) in trimmed.enumerated() where ["。", "！", "？", "!", "?", "\n"].contains(ch) {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: i)
            if ch == "\n" {
                end = idx
                brokeAtNewline = true
            } else {
                end = trimmed.index(after: idx)
            }
            break
        }
        var sentence = String(trimmed[trimmed.startIndex..<end])
        let capped = sentence.count > cap
        if capped {
            sentence = String(sentence.prefix(cap))
        }
        return (capped || brokeAtNewline) ? sentence + "…" : sentence
    }

    static func formatDuration(_ ms: Int) -> String {
        if ms < 1_000 { return "<1s" }
        if ms < 60_000 { return "\(Int((Double(ms) / 1000).rounded()))s" }
        if ms < 3_600_000 {
            return "\(ms / 60_000)m \(Int((Double(ms % 60_000) / 1000).rounded()))s"
        }
        return "\(ms / 3_600_000)h \((ms % 3_600_000) / 60_000)m"
    }

    static func formatTokens(_ n: Int) -> String {
        n < 1000 ? "\(n)" : String(format: "%.1fk", Double(n) / 1000)
    }

    /// "deepseek/deepseek-flash" → "deepseek-flash"。
    static func shortModelName(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        return model.split(separator: "/").last.map(String.init)
    }
}
