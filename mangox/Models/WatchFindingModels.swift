//
//  WatchFindingModels.swift
//  P19 助理的「结论」契约：一条 findings 一行、一个 status 值，外加一轮巡检的解析结果。
//  设计见 docs/P19 §04（表结构 / 输出契约 / 触达频控）。
//
//  ⚠️ `status` 是**便签不是枷锁**（§04）: 代码只做两件事 —— 收件箱按它筛、执行前按它 guard。
//  不写转移表: 该催、该等、该关，全交给模型按事实判断后写入。
//

import Foundation

enum FindingStatus: String, Codable, CaseIterable {
    case open
    case authorized
    case running
    case resolved
    case failed
    case dismissed
    /// 目标已不成立 / 问题自己好了 —— 与 `dismissed` 的区别是**不是人关的**。
    case stale
    /// 人让它先放着，到期自动回 `open`。
    case snooze

    /// 收件箱默认只显这一档（其余折叠）。
    var isInboxVisible: Bool { self == .open }

    /// 执行前 guard 用: 已经是这两个状态之一 ⇒ 拒绝再执行（写动作跑两遍 = 双倍破坏）。
    var blocksExecution: Bool { self == .running || self == .resolved }

    /// 未知值（老库 / 前向版本）⇒ 不进收件箱、不放行执行。**宁可什么都不做。**
    static func decode(_ raw: String) -> FindingStatus? { FindingStatus(rawValue: raw) }
}

/// 方案里的一步。
///
/// ⚠️ 本版只有 `n` 与 `text`，**没有** schema 里的 `kind / target / cmd` —— 那是故意的:
/// 让模型为每一步吐出「kind=bash, target=/tmp/x」这种字段，它十次里总有两三次是编的，
/// 而编出来的 `target` 会被下游当成**已授权的写入目标**（L2 围栏拿它比边界）⇒ 围栏比的是
/// 模型编的字符串，等于没有围栏。本版只认「第几步、做什么」这一句人话，动作细节留到
/// 执行轮由人看着审批卡确认（S6）。schema 里那几个字段等 S6 有了真实消费者再补。
struct WatchPlanStep: Codable, Equatable {
    var n: Int
    var text: String
}

/// 一条 finding（= 一件事 + 一个状态）。
struct AgentFinding: Identifiable, Equatable {
    var id: UUID
    var taskId: UUID
    /// 必须属于该任务。**本版由 App 决定**（`WatchFindingService.sourceId(for:)`），
    /// 不接受模型给的 id —— 从任务反推比"校验模型给的对不对"更强：伪造面直接消失。
    var sourceId: UUID
    var sessionId: UUID
    /// 一句话结论（findings 列表里那一行）。
    var title: String
    /// 诊断 / 影响面 / 回滚法（人复核时看的那一段）。
    var body: String
    /// 文件:行号、读数或 observation 的 externalId。
    var evidence: String?
    var plan: [WatchPlanStep]
    /// 二次授权会 +1；已执行的步骤不因改版而丢。
    var planRev: Int = 1
    /// info / notice / action —— **只影响触达与折叠，不决定能否执行**。
    var severity: String = "notice"
    /// sha256(task_id + source_id + 规范化结论)。
    var fingerprint: String
    var status: FindingStatus = .open
    /// 执行前快照目录；`resolved` 也要留着，人才敢点下一次授权。
    var undoPath: String?
    var tokens: Int?
    var costUSD: Double?
    var createdAt: Date
    var decidedAt: Date?
}

/// 一轮巡检的解析结果 —— **纯数据，不碰库**（判据直接打在这里）。
struct WatchReport: Equatable {
    /// 这一轮没有值得说的事。**判定在后**（见 `WatchFindingService.parse`）:
    /// 只要解析出「结论」段就不算 NO_FINDING —— 模型偶尔会把 NO_FINDING 写在正文里当解释。
    var isNoFinding: Bool = false
    var title: String = ""
    /// 结论段全文（首行是标题，余下即诊断 / 影响面 / 回滚法）。
    var body: String = ""
    var evidence: String?
    var plan: [WatchPlanStep] = []
    /// 更新后的**整篇**工作日志（不是 diff）。空 = 这一轮不改。
    var handoff: String?
    /// 解析上出的问题（说人话，进日志时间线）—— 空 = 没问题。
    var parseIssue: String?
}

/// 一条在途巡检的上下文 —— 收尾时要用，但那时采集快照已经不在手上了。
struct WatchFireContext: Equatable {
    let taskId: UUID
    /// 本版 = 项目来源（或唯一启用的来源）。
    let sourceId: UUID?
    /// 本轮观察里真实出现过的 externalId。证据引用了不在这里的编号 ⇒ 拒收。
    let allowedExternalIds: Set<String>
}

/// 执行轮里一次过闸的落痕（`agent_finding_actions` 的一行）。
///
/// ⚠️ 一行 = **一个步骤号**，不是"一次工具调用"：同一步里连着三个命令是常态，逐个并列会
/// 把"第 2 步"刷成三十行。`count` 是这一步真正过了几次闸。
/// `step == 0` 是"正文里没声明步骤号"那一格 —— 红线拦截与整轮收尾都落在它上面。
struct FindingAction: Identifiable, Equatable {
    var findingId: UUID
    var step: Int
    /// bash / write / edit / computer_act …；收尾那一行是 `result`。
    var kind: String
    var target: String?
    /// allowed / denied_by_redline / drifted / resolved / failed
    var result: String
    var output: String?
    var at: Date

    var id: String { "\(findingId.uuidString)#\(step)" }
}
