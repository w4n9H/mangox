//
//  MailboxReply.swift
//  P10.2b: 回执组装 (纯函数) —— 状态机主题 + 正文 (产出 + 结算数据 + 拦截清单)。
//  主题与 `mailbox_tasks.title` **共用同一份清洗** (决定 13: 剥 secret 是硬要求, 否则随每封回执扩散)。
//

import Foundation

/// 回执状态机 (§2 / §五): 手机上不点开即可扫进度。
/// 落定路径发 DONE / BLOCKED / FAILED 三种; **RUNNING 留给执行中的里程碑回执** (Scheduled 挂 email 汇报),
/// 定义在此以固定契约 —— 改状态机字面量是一处改, 不是散落各文件。
enum MailboxReplyStatus: String, CaseIterable {
    case running, done, blocked, failed

    /// 主题前缀标记 (用户侧过滤规则/客户端规则都按它匹配)。
    var tag: String {
        switch self {
        case .running: return "[MGOX][RUNNING]"
        case .done:    return "[MGOX][DONE]"
        case .blocked: return "[MGOX][BLOCKED]"
        case .failed:  return "[MGOX][FAILED]"
        }
    }

    /// 正文里的中文短语 (回执是给人看的, tag 是给机器/过滤规则看的)。
    var label: String {
        switch self {
        case .running: return "执行中"
        case .done:    return "已完成"
        case .blocked: return "已完成 (有命令被拦下)"
        case .failed:  return "失败"
        }
    }
}

/// 回合结算数据 — 来源: 本回合产出的消息 `usage` 聚合 + 客户端计时。
/// **不用 `ChatStore.sessionStats`**: 它只归并"当前选中会话"的上报 (`didReportSessionStats` 里
/// 有 `sid == selectedConversationId` 守卫), 后台邮件会话拿不到; 逐消息 usage 则是会话无关的。
struct MailboxReplyStats: Equatable {
    var rounds = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var costUSD: Double?
    var elapsed: TimeInterval = 0

    /// 聚合本回合产出的消息 (assistant 消息带 usage; 无上报的消息跳过)。
    static func aggregate(_ messages: [ChatMessage], elapsed: TimeInterval) -> MailboxReplyStats {
        var s = MailboxReplyStats()
        s.elapsed = elapsed
        for m in messages {
            guard m.role == .assistant else { continue }
            if case .text = m.content { s.rounds += 1 }
            guard let u = m.usage else { continue }
            s.inputTokens += u.input
            s.outputTokens += u.output
            s.cacheReadTokens += u.cacheRead
            if let c = u.costUSD { s.costUSD = (s.costUSD ?? 0) + c }
        }
        return s
    }

    /// "12.3k 入 / 4.5k 出 (缓存 8.1k)" — 缓存为 0 时省掉尾括号。
    var tokenSummary: String {
        let head = "\(Self.compact(inputTokens)) 入 / \(Self.compact(outputTokens)) 出"
        return cacheReadTokens > 0 ? head + " (缓存 \(Self.compact(cacheReadTokens)))" : head
    }

    /// "3分12秒" / "45秒" (回执给人看, 不用 00:03:12)。
    var elapsedSummary: String {
        let total = Int(elapsed.rounded())
        let m = total / 60, s = total % 60
        return m > 0 ? "\(m)分\(s)秒" : "\(s)秒"
    }

    /// 无上报 → nil (回执省掉该行, 不写 "$0.0000" 误导)。
    var costSummary: String? {
        guard let costUSD else { return nil }
        return String(format: "$%.4f", costUSD)
    }

    /// 12345 → "12.3k" (回执是概览, 不需要精确到个位)。
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

enum MailboxReplyComposer {

    /// 产出正文上限 — 邮件客户端承载得住, 也避免把整段终端输出灌进回执。
    static let outputCharLimit = 6000

    /// 回执主题: `[MGOX][DONE] [MGOX-<id8>] <title>`。
    /// 短 id 由 MangoX 自行注入 (§3.3 兜底定位: References 被客户端剥掉时仍能按短 id 归线程)。
    static func subject(status: MailboxReplyStatus, taskId: UUID, title: String) -> String {
        "\(status.tag) \(MailboxSentinelService.shortIdMarker(taskId)) \(title)"
    }

    /// 回执正文: [拦截清单] + [产出] + [结算行]。纯函数, 冒烟直接断言。
    static func body(status: MailboxReplyStatus, output: String, stats: MailboxReplyStats,
                     blocks: [AutoJudgeBlock] = []) -> String {
        var sections: [String] = []
        if !blocks.isEmpty {
            var lines = ["⚠️ 有 \(blocks.count) 条命令被自动裁决拦下 (未执行):"]
            for b in blocks {
                lines.append("  · \(b.command) — \(b.reason)")
            }
            lines.append("")
            lines.append("被拦下的命令不会执行; 其余步骤已按计划完成。如需放行, 请在 MangoX 里改该 agent 的裁决档 (或在会话里手动跑一次)。")
            sections.append(lines.joined(separator: "\n"))
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sections.append(status == .failed
                ? "(本轮没有产出 — 可能被中止或引擎出错, 详见 MangoX 会话)"
                : "(本轮无文本产出)")
        } else if trimmed.count > outputCharLimit {
            sections.append(String(trimmed.prefix(outputCharLimit)) + "\n…(回执已截断, 完整内容见 MangoX 会话)")
        } else {
            sections.append(trimmed)
        }
        var meta = ["状态: \(status.label)",
                    "耗时: \(stats.elapsedSummary) · 轮次: \(stats.rounds)",
                    "tokens: \(stats.tokenSummary)"]
        if let cost = stats.costSummary { meta.append("费用: \(cost)") }
        sections.append(meta.joined(separator: "\n"))
        return sections.joined(separator: "\n\n")
    }

    /// 本回合最后一条 assistant 文本 (= 交付给用户的正文)。
    /// 取最后一条而非拼接: agent 的最终答复就是它, 拼接会把中间的过渡语一并带上。
    static func lastAssistantText(_ messages: [ChatMessage]) -> String {
        for m in messages.reversed() {
            guard m.role == .assistant, case .text(let s) = m.content else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return ""
    }

    /// 从 References 链去重保序地拼 In-Reply-To (自铸 Message-ID 恒排最后 = 最新)。
    static func referenceChain(threadKey: String, inReplyTo: String) -> [String] {
        var out: [String] = []
        for c in [threadKey, inReplyTo] where !c.isEmpty && !out.contains(c) { out.append(c) }
        return out
    }
}
