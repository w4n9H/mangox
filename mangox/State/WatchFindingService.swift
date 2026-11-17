//
//  WatchFindingService.swift
//  P19 巡检结论的落地：解析 → 校验 → 指纹 → 决定落库/通知 → 给调度器一份"该做什么"的计划。
//
//  三个刻意的分工:
//    ① **解析是纯函数**（`parse`）: 输出契约是自然语言三段，解析器写错的表现是"结论丢了"，
//       而丢了不会有任何报错 —— 所以它必须有夹具级的判据，且**解析失败要说人话**；
//    ② **决策也是纯函数**（`plan`）: 落不落库、通不通知，全在这里算完；写库/发通知由
//       `SchedulerService` 执行。这样"同指纹不重发 / 冷却 30 分钟"这类判断能在冒烟里对拍；
//    ③ 这个类型**不持有 `ChatStore`**（同 `WatchSourceService`）: 来源与结论都不能自己去 fire。
//

import Foundation
import CryptoKit

/// 一次结论落地的完整计划 —— 全是纯数据，谁执行谁负责写。
struct WatchIngestPlan: Equatable {
    /// 要写的行（新建或更新同一 fingerprint 的那一行）。nil = 这一轮不落库。
    var finding: AgentFinding?
    /// 新建还是改已有行（改 = 方案升级，`planRev` +1）。
    var isNew: Bool = false
    /// 更新后的整篇工作日志（nil = 这一轮不改）。
    var handoff: String?
    /// 要不要外发（系统通知）。同指纹不重发、同任务 30 分钟冷却。
    var shouldNotify: Bool = false
    /// 写进日志会话的一行人话。
    var summary: String = ""
}

enum WatchFindingService {

    /// 同任务外发冷却（§04）。**按任务**而不是按 finding: 一个人一天被同一个任务叫两次
    /// 已经够烦了，哪怕说的不是同一件事。
    static let notifyCooldown: TimeInterval = 30 * 60
    /// 工作日志单份上限。
    ///
    /// P19.2 S8: 4000 → **16000** —— 五节 + 归档 + 同时追几件事，4000 撑不住。
    /// 超了**不截断而是拒收** —— 截断会把「待你决定」切掉，留下半句比没有更坏。
    /// 所以拒收之外必须给它一条自己走出去的路: 压缩归档节（见下面两个水位）。
    static let handoffMaxChars = 16000

    /// 该开始压缩归档的字数水位。
    ///
    /// ⚠️ **模型看不见自己那份账本有多大** —— 只在 prompt 里写「允许压缩」是一句空话，
    /// 它永远不知道自己已经 13k 了。所以 `watchSystemPrompt` 里必须同时下发
    /// 「当前 N 字 / 上限 X」，这一条才有落地的可能。
    static let handoffCompactThreshold = 12000

    /// 压缩归档时保留的最近条数。**只删更旧的**，「完成状态 / 在跟踪 / 待你决定」一个字都不许删。
    static let archivedKeep = 20

    // MARK: - 解析（纯函数，夹具级判据打在这里）

    /// 把模型的回复解析成 `WatchReport`。
    ///
    /// 认的段头只有四个（都是输出契约里点名的）: `结论 / 证据 / 方案 / 工作日志`，
    /// 中英文冒号都收。**按行扫**不是因为好看: 模型在长回复里会写出多个"结论"字样，
    /// 而只有**行首的段头**才该切开分段（正文里那句"结论是……"不该切）。
    static func parse(_ text: String) -> WatchReport {
        var report = WatchReport()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var current: String?          // 当前段头
        var buckets: [String: [String]] = [:]
        let heads = ["结论", "证据", "方案", "工作日志"]

        for raw in lines {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let head = heads.first(where: { h in
                trimmed.hasPrefix(h + "：") || trimmed.hasPrefix(h + ":")
            }) {
                current = head
                let rest = String(trimmed.dropFirst(head.count + 1))
                    .trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { buckets[head, default: []].append(rest) }
                continue
            }
            if let c = current { buckets[c, default: []].append(line) }
        }

        let conclusionLines = (buckets["结论"] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        report.title = conclusionLines.first ?? ""
        report.body = conclusionLines.joined(separator: "\n")
        // 结论段**可以是多行**: 首行做标题, 余下即"诊断 / 影响面 / 回滚法"的正文。
        // 不额外要求三个固定小标题 —— 模型写三个小标题的稳定性远不如写一段话。
        report.evidence = (buckets["证据"] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if report.evidence?.isEmpty == true { report.evidence = nil }
        report.plan = parsePlan(buckets["方案"] ?? [])
        let handoff = (buckets["工作日志"] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        report.handoff = handoff.isEmpty ? nil : handoff

        // NO_FINDING 的判定**放在最后**: 只要真解析出结论段, 正文里提到 NO_FINDING 不算
        // （模型常在解释里写"这里本来可以回 NO_FINDING"）。反过来, 没有结论段又没写
        // NO_FINDING, 那是**解析失败**, 不是"没有结论" —— 两者对用户是两件事。
        if report.title.isEmpty {
            if normalized.uppercased().contains("NO_FINDING") {
                report.isNoFinding = true
            } else {
                report.parseIssue = "没解析出「结论」段"
            }
        }
        return report
    }

    /// 方案段 → 编号步骤。认 `1. / 1) / 1、/ - / *` 五种写法；编号取**原文里的数字**，
    /// 没写数字就按顺序补 —— 编号是执行段的授权凭据（"第 3 步"指的就是它），不能靠猜。
    static func parsePlan(_ lines: [String]) -> [WatchPlanStep] {
        var steps: [WatchPlanStep] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "无" || line == "无。" { return [] }
            var n: Int?
            var body = line
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" || $0 == "、" }) {
                let head = line[line.startIndex..<dot].trimmingCharacters(in: .whitespaces)
                if let v = Int(head) {
                    n = v
                    body = String(line[line.index(after: dot)...])
                        .trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard !body.isEmpty else { continue }
            steps.append(WatchPlanStep(n: n ?? (steps.count + 1), text: body))
        }
        return steps
    }

    // MARK: - 校验 / 指纹

    /// 证据里引用了几号外部观察、而本轮**根本没采到那个编号** ⇒ 返回这些编号。
    ///
    /// 这是本版**唯一还需要校验的伪造面**: `source_id` 由 App 从任务反推（见
    /// `WatchFindingModels.swift` 的注释），模型给不了它；能被编造的只有"我看到了第 7 条"。
    /// 只认 `[数字]` 形态 —— 文件:行号写在方括号里（`[App.swift:42]`）不算引用。
    static func forgedCitations(_ evidence: String?, allowed: Set<String>) -> [String] {
        guard let evidence, !evidence.isEmpty else { return [] }
        var out: [String] = []
        var i = evidence.startIndex
        while let open = evidence[i...].firstIndex(of: "[") {
            guard let close = evidence[open...].firstIndex(of: "]") else { break }
            let inner = evidence[evidence.index(after: open)..<close]
            if !inner.isEmpty, inner.allSatisfy(\.isNumber), !allowed.contains(String(inner)) {
                out.append(String(inner))
            }
            i = evidence.index(after: close)
        }
        return out
    }

    /// sha256(task_id + source_id + 规范化结论)。
    ///
    /// ⚠️ **只含结论，不含方案**: 指纹的语义是"这是不是同一件事"。方案改进（plan_rev+1）
    /// 讲的还是同一件事 —— 若把方案也揉进去，改一条步骤就会变成"新问题"，收件箱里堆两行。
    static func fingerprint(taskId: UUID, sourceId: UUID, title: String) -> String {
        let normalized = normalize(title)
        let data = Data("\(taskId.uuidString)|\(sourceId.uuidString)|\(normalized)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 规范化: 所有空白压成一个空格、去首尾。判据是**同一句话换个折行不该算两件事**。
    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - 决定：(落不落库 / 通不通知)

    /// 把解析结果变成一份可执行的计划。**纯函数** —— 副作用全留给调用方。
    ///
    /// 外层只做一件事: **工作日志上限**。放在这里而不是落盘侧，是为了让判据能打在纯函数上
    /// （写盘那一侧看不到"为什么没写"）。而且**拒收不截断**: 截断会把「下一步」切掉，
    /// 留下半句比没有更坏。
    static func plan(report: WatchReport, task: ScheduledTask, sessionId: UUID,
                     sourceId: UUID?, allowedExternalIds: Set<String>,
                     existing: [AgentFinding], lastNotifyAt: Date?, now: Date) -> WatchIngestPlan {
        var out = planCore(report: report, task: task, sessionId: sessionId, sourceId: sourceId,
                           allowedExternalIds: allowedExternalIds, existing: existing,
                           lastNotifyAt: lastNotifyAt, now: now)
        if let h = out.handoff, h.count > handoffMaxChars {
            out.summary += "（工作日志 \(h.count) 字超过上限，本轮不写盘）"
            out.handoff = nil
        }
        return out
    }

    private static func planCore(report: WatchReport, task: ScheduledTask, sessionId: UUID,
                     sourceId: UUID?, allowedExternalIds: Set<String>,
                     existing: [AgentFinding], lastNotifyAt: Date?, now: Date) -> WatchIngestPlan {
        var out = WatchIngestPlan()
        if let issue = report.parseIssue {
            out.summary = "── 巡检结论没解析出来（\(issue)），本轮不落库 ──"
            return out
        }
        if report.isNoFinding {
            out.summary = "── 本轮无新结论（NO_FINDING）──"
            out.handoff = report.handoff
            return out
        }
        guard let sourceId else {
            out.summary = "── 本轮没有可归属的来源，结论不落库 ──"
            return out
        }
        // 编造的引用 ⇒ **整条拒收**（不改写成"部分保留": 一条证据半真半假的结论宁可不要）
        let forged = forgedCitations(report.evidence, allowed: allowedExternalIds)
        if !forged.isEmpty {
            out.summary = "── 结论被拒收：引用了本轮没采到的观察 \(forged.map { "[\($0)]" }.joined()) ──"
            return out
        }

        let fp = fingerprint(taskId: task.id, sourceId: sourceId, title: report.title)
        let planText = report.plan.map { "\($0.n).\($0.text)" }.joined(separator: "\n")
        if var same = existing.first(where: { $0.fingerprint == fp && $0.taskId == task.id }) {
            // 同一件事又提了一次: 方案变了就升级版本, 但**不重新叫人**（同指纹不重发）。
            let oldText = same.plan.map { "\($0.n).\($0.text)" }.joined(separator: "\n")
            if oldText != planText {
                same.plan = report.plan
                same.planRev += 1
                same.evidence = report.evidence ?? same.evidence
                out.finding = same
                out.isNew = false
                out.summary = "── 同一结论，方案更新到第 \(same.planRev) 版（不重复通知）──"
            } else {
                out.summary = "── 同一结论、方案未变（不重复落库、不通知）──"
            }
            out.handoff = report.handoff
            return out
        }

        let f = AgentFinding(id: UUID(), taskId: task.id, sourceId: sourceId, sessionId: sessionId,
                             title: report.title,
                             body: report.body.isEmpty ? report.title : report.body,
                             evidence: report.evidence,
                             plan: report.plan, planRev: 1,
                             // 严重度只影响触达与折叠: 有步骤 = 要动手 ⇒ action; 否则 info
                             severity: report.plan.isEmpty ? "info" : "action",
                             fingerprint: fp, status: .open, createdAt: now)
        out.finding = f
        out.isNew = true
        out.handoff = report.handoff
        // 冷却: 同一个任务 30 分钟内最多叫人一次（哪怕说的是另一件事）
        let cooling = lastNotifyAt.map { now.timeIntervalSince($0) < notifyCooldown } ?? false
        out.shouldNotify = !cooling
        out.summary = "── 新结论：\(f.title)" + (f.plan.isEmpty ? "" : " · 方案 \(f.plan.count) 步")
            + (out.shouldNotify ? "" : "（冷却中，不通知）") + " ──"
        return out
    }
}
