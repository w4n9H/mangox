//
//  AgentTeam.swift
//  P20 多助理协作（2026-11-24）—— 两个角色、四条域不变量、派活单的数据面。
//
//  设计文档: `docs/P20-functional-design.html`（§04 数据与契约 / §06 执行计划）。
//
//  ⚠️ 本文件的字面量**全部不是界面文案**：
//      ① `TeamViolation.reason` 进日志 / 时间线 / 拒绝回执（与 `Redline` / `LedgerFence` 同族），
//         必须恒中文 —— 它是**给人看的落库数据**，不是界面词；
//      ② 本文件将来还会出【你的队伍】/【派活回执】两段注入字节（P3），那两个段头是模型认得的
//         契约 token，随界面语言漂 = 同一支队伍在英文界面上长得不一样，而下游零红灯。
//     ⇒ 已登记进 `scripts/l10n/gen_strings.py` 的 `EXCLUDE_FILES`。**UI 文案请写在 View 侧**
//      （按 `TeamViolation` 的 case 各自取词），别在这里写 `L()` —— 在这个文件里取词，
//      三道 l10n 门全都看不见它。
//

import Foundation

// MARK: - 角色

/// 一支队伍里的两种身份。判据只有一句：**谁决定它开始跑**。
///
/// · `.main` —— 有独立的触发面（cron / 飞书单聊 / 手动跑），能派人、能对外说话；
/// · `.worker` —— 只能被派活叫起来。工具面里没有 `delegate`（结构上做不到再往下派）。
///
/// ⚠️ **不由"有没有绑飞书"派生**（这是文档 §04 否掉的第一个方案）：`.assistant` 本来就可以带
/// cron，按绑没绑飞书分级会把一大批"有 cron、没飞书"的助理判成 worker（它们会失去 cron 与
/// 台账语义）；更要紧的是绑定可解 —— 一解绑角色就漂，而角色一旦漂，工具面跟着漂。
enum TaskRole: String, Codable {
    case main
    case worker

    /// 缺省恒 `.main`。
    ///
    /// 三个来源都必须落到 main，缺一个就会静默降级：
    ///   · 老库升上来的行（列是 `NOT NULL DEFAULT 'main'`，见 `migrate`）；
    ///   · 所有 Cron 行（它们从来没有"角色"这个概念）；
    ///   · **认不出的值**（将来版本加的第三态，被旧版读到）。这里刻意**不**猜 worker:
    ///     把一个 main 降级成 worker = 静默摘掉它的 cron 与对外出口（一种看不见的能力损失），
    ///     而把 worker 当 main 只在它真的试着派人时才会露出来。
    static func decode(_ raw: String?) -> TaskRole {
        guard let raw, !raw.isEmpty else { return .main }
        return TaskRole(rawValue: raw) ?? .main
    }
}

// MARK: - 域不变量

/// 一支队伍**为什么**不成立。枚举而不是字符串：界面（P4）要按 case 各取各的本地化词，
/// 而域层这份恒中文的那句只进日志与时间线。
///
/// ⚠️ 这里只放**会拦住保存**的那些。"归属的 main 已经不在了"**不**在此列 —— 那是删 main 之后
/// 的正常残留（见 `TeamRule.isOrphan`）：一个连名字都改不了、存不下去的孤儿，比一个孤儿更坏。
enum TeamViolation: Equatable {
    case mainHasParent
    case workerWithoutParent
    /// 上级自己也是个 worker ⇒ 深度不是 1。
    case parentIsWorker
    case duplicateName(String)

    /// 恒中文，进日志 / 时间线 / 拒绝回执。**不是界面词**（见文件头）。
    var reason: String {
        switch self {
        case .mainHasParent:
            return "main 不该有上级 —— 它是一支队伍的起点"
        case .workerWithoutParent:
            return "worker 必须归属一个 main"
        case .parentIsWorker:
            return "上级自己也是 worker —— 递归深度硬限 1 级"
        case .duplicateName(let name):
            return "已经有一个 worker 叫「\(name)」—— 名单按名字选人，重名等于两个人都叫这个"
        }
    }
}

/// 四条不变量的**唯一判据口**（视图、域层写路径、将来的导入/批量编辑都读它）。
///
/// 写成纯函数（不碰 DB、不读时钟）的理由与 `FollowUpSpool.parse` 同：冒烟可以直接喂一个
/// 构造出来的数组造反例，不需要先把库写脏。
enum TeamRule {

    /// `nil` = 合规。
    ///
    /// `all` 允许包含 `t` 自己（按 id 摘掉）—— 由调用方去记得"别把自己算重名"是迟早会漏的。
    static func violation(_ t: ScheduledTask, among all: [ScheduledTask]) -> TeamViolation? {
        let others = all.filter { $0.id != t.id }
        switch t.role {
        case .main:
            // 单值列保证"一个 worker 只归一个 main"；反向这条保证"main 不归谁"。
            return t.parentId == nil ? nil : .mainHasParent
        case .worker:
            guard let pid = t.parentId else { return .workerWithoutParent }
            // 上级不在 = 未归属（`isOrphan`），**不拦保存**。
            if let parent = others.first(where: { $0.id == pid }), parent.role != .main {
                // 深度恒 1 = 上级必须是个 main。只有两种角色, 所以"上级不是 main"就是"上级是 worker"。
                return .parentIsWorker
            }
            let name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // ⚠️ 唯一性按**全体 worker** 算（不是"同一支队伍内"）: 派活单里 `worker` 只写名字，
            // 而名字在两支队伍之间重了，模型下一次就会派给错的那一个 —— 那种错从回执上看不出来。
            let clash = others.contains {
                $0.role == .worker && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name
            }
            return clash ? .duplicateName(name) : nil
        }
    }

    /// 归属的 main 已经不在了 —— **只影响展示，不拦保存**。
    ///
    /// 删 main 时 worker 只停用、`parent_id` 故意留成悬挂值（文档 §04 连带表）：画板上它要落进
    /// 「未归属」区，而置空之后"它本来归谁"这件事就再也查不回来了。P5 用这个判据分列。
    static func isOrphan(_ t: ScheduledTask, among all: [ScheduledTask]) -> Bool {
        guard t.role == .worker, let pid = t.parentId else { return false }
        return !all.contains { $0.id == pid }
    }
}

// MARK: - 派活单

/// 一张派活单的生命周期。值域照 A2A 的 task 生命周期，**去掉 `skipped`**：这里没有
/// "跳过一次"这种结局，起不来只会被顺延（`queued` 留在原地）或被作废（`cancelled`）。
///
/// ⚠️ 同 `FollowUpStatus` / `FindingStatus`：**不做 CHECK 约束**，越界值由解码侧丢行
/// （理由见 `PersistenceStore.migrate` 里 `agent_findings` 那段 —— 已发版的老 App
/// 打开新库要能写进去）。
enum DelegationStatus: String, Codable {
    case queued
    case running
    case done
    case failed
    case cancelled

    /// 未知值 ⇒ `nil` ⇒ 调用方丢行。**别回落成 `queued`**: 那会把一条本该被忽略的旧单子
    /// 重新叫起来（"猜一个"永远比"丢掉"更坏，同 `FollowUpStatus.decode`）。
    static func decode(_ raw: String) -> DelegationStatus? { DelegationStatus(rawValue: raw) }

    /// 还没落定的两种 = "它手上有活"（派活前那条硬拒读这个，不是读计数）。
    var isOpen: Bool { self == .queued || self == .running }
}

/// 一张落库的派活单。
///
/// ⚠️ **独立一张表，不并进 `agent_followups`**（文档 §04 有那张对照表）：两者共享"到点叫醒"
/// 那一段（扫到期、认领、顺延、删任务连带清），但字段与状态机差得太远 —— follow-up 只有
/// `why` 与四态，派活有工单三件、两条时间线、回执消费与五种终态。合成一张会得到十几个
/// nullable 列，而每一列都要在两种语义下各解释一遍。
struct Delegation: Identifiable, Equatable {
    let id: UUID
    /// 谁派的。**域层要求它必须是 main**（worker 的工具面里没有 delegate）。
    let fromTask: UUID
    let toTask: UUID
    /// 这一次要干什么（不含长期职责 —— 那是 worker 自己的 `description`）。
    var goal: String
    /// 怎么算干完。会进 worker 台账的「完成状态」。
    var acceptance: String
    /// 相关文件路径 / 上次结论 / 约束。**不传对话快照**（理由见文档 §04 参数表）。
    var context: String?
    /// 什么时候起跑。App 侧算（`createdAt + after_minutes`），不信子进程的钟。
    var dueAt: Date
    /// 最晚什么时候要。可空；有值时域层要求 `dueAt < dueBy`。
    var dueBy: Date?
    var status: DelegationStatus
    /// 顺延了几次（被闸挡住时 +1）。**不用于判死** —— worker 忙四十分钟是正常的。
    var attempts: Int
    /// 为什么被挡 / 为什么失败（闸的原话、桥的原话）。必须有：否则人只看到"没跑"。
    var note: String?
    /// 交活时 worker 写的一句话结论（main 的回执读它，不读全文）。
    var summary: String?
    /// main **成功收尾之后**才标。标在"注入时"会让那一轮崩掉时回执永久丢失
    /// （同 `settleSent` 的哲学：唯一诚实的位置是"真的消化完了"）。
    var reportedAt: Date?
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
}

/// 派活边界 —— 每个数都是产品判断，不是实现细节（文档 §06 末尾"最可能被真跑推翻的四个数"
/// 说的就是这里这几个，改完要重算【你的队伍】那段的字数预算）。
enum DelegationLimit {
    /// 一轮最多派 2 条。与 follow-up"一轮一条"同族：一轮冒出五张单子 = 它在乱派，不是在分工。
    static let maxPerTurn = 2
    /// 同时最多 3 个 worker 在跑（再往上就是"开了一堆窗口、一个都没看完"）。
    static let maxConcurrentWorkers = 3
    /// 【你的队伍】那段的上限。12 × 每行约 55 字 ≈ 700 字 —— 这段是每轮都付的固定成本。
    static let maxTeamRows = 12

    static let maxGoalChars = 800
    static let maxAcceptanceChars = 400
    static let maxContextChars = 1200
    static let maxSummaryChars = 400

    /// `after_minutes` 的闭区间。0 = 下一跳就起（调度 tick 是每分钟一次 ⇒ ≤60 秒），
    /// 不是"立刻"；上限 7 天（再远的安排该用 cron，那是人定的周期）。
    static let minMinutes = 0
    static let maxMinutes = 7 * 24 * 60

    /// 职责 / 职责说明的字数上限（`ScheduledTask.description` / `.descriptionDetail`）。
    ///
    /// 拆两个字段而不是"取前 40 字"：人写「这个助理主要负责每个月的财务相关工作…」，按 40 字
    /// 硬截就得到半句废话，而注入段是**原文照搬**的 —— 截断问题从结构上消失，比加一个更聪明的
    /// 截断器便宜得多。
    static let maxDescriptionChars = 40
    static let maxDescriptionDetailChars = 240

    /// 超长就截断并加省略号（**最后一道围栏**，不是主要手段：工具入参该拒的还在 P2 拒）。
    static func clip(_ s: String, _ cap: Int) -> String {
        s.count <= cap ? s : String(s.prefix(cap)) + "…"
    }
}

// MARK: - 派活请求（spool 的解析口径 + 七条拒绝）

/// 一张**还没被接受**的派活请求 —— 就是扩展写进 spool 的那一行。
///
/// 与 `FollowUpSpool.Request` 同一个位置、同一套理由：扩展是哑的（读 env / 校验形状 / 追一行），
/// **落库、校验归属、算时刻全在 App 侧**。
///
/// ⚠️ **七条拒绝理由只在这里判一次**（`DelegationRule.check`），扩展侧不做业务校验。
/// 为什么不让扩展先挡一遍（那样模型能在本轮就改对，听起来更好）：那要求把"现在有哪些 worker、
/// 谁手上有活、今天派了几条"塞进子进程的 env，而 env 是**进程级冻结**的（本项目踩过: 改了作用域
/// 但进程被复用 ⇒ 助手照旧按旧名单拒）。两处判据一旦分叉，"拒了"和"拒对了"就成了两件事。
/// 代价（明写）: 模型要**下一轮**才知道被拒了 —— 文档 §04 那句"让下一轮能直接改对"就是这个意思。
struct DelegationAsk: Equatable {
    /// 扩展侧生成的幂等键（同一个 spool 被 ingest 两次不会派两单）。
    let id: UUID
    let worker: String
    let goal: String
    let acceptance: String
    let afterMinutes: Int
    /// 最晚什么时候要（相对分钟）。可空。
    let dueInMinutes: Int?
    let context: String?
}

/// 被拒的原因。`reason` 恒中文（进时间线、给下一轮的模型读），**不是界面词**
/// （界面按 case 取词是 P4/P5 的事，见文件头）。
///
/// `Error` 只为让 `check` 返回 `Result<UUID, DelegationRefusal>` 读起来是"成 / 不成 + 为什么" ——
/// 它从不被 `throw`、也没有谁按 `Error` 捕获。别把它接进任何 `catch` 链。
enum DelegationRefusal: Equatable, Error {
    case unknownWorker(String)
    case workerIsMain(String)
    case workerDisabled(String)
    /// 手上有活 —— 带"手上那条是什么、什么时候开始的"，否则下一轮还会再派一次。
    case workerBusy(name: String, goal: String, startedAt: Date?)
    case timeOutOfRange(minutes: Int)
    case dueNotAfterStart(after: Int, dueIn: Int)
    case turnLimit(Int)
    case dailyLimit(used: Int, quota: Int)
    /// 派活的不是 main（结构上不该出现：worker 的工具面里没有 `delegate`，这里是兜底）。
    case notMain

    var reason: String {
        switch self {
        case .unknownWorker(let name):
            return "没有叫「\(name)」的 worker"
        case .workerIsMain(let name):
            return "「\(name)」是一支队伍的队长（main），不能当 worker 用"
        case .workerDisabled(let name):
            return "「\(name)」被停用了 —— 先启用它，或者换一个人"
        case .workerBusy(let name, let goal, let startedAt):
            let when = startedAt.map { Self.hhmm($0) } ?? "刚刚"
            let what = goal.count > 20 ? String(goal.prefix(20)) + "…" : goal
            return "「\(name)」手上还有活（\(when) 起：\(what)），不会排队 —— 换人或者等它交活"
        case .timeOutOfRange(let m):
            return "after_minutes 要在 \(DelegationLimit.minMinutes)…"
                + "\(DelegationLimit.maxMinutes) 之间（拿到 \(m)）"
        case .dueNotAfterStart(let after, let dueIn):
            return "due_in_minutes（\(dueIn)）必须大于 after_minutes（\(after)）—— "
                + "先起跑、再要结果，不是反过来"
        case .turnLimit(let n):
            return "一轮最多派 \(n) 条（后面那几张没派出去）"
        case .dailyLimit(let used, let quota):
            return "今天已经派了 \(used) 条（上限 \(quota)），这条没派出去 —— 改配额在助理设置里"
        case .notMain:
            return "只有 main 能派活"
        }
    }

    /// `HH:mm` —— 拒绝理由与名单共用这一份格式化。
    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// 判据本体 —— **纯函数**（不碰 DB、不读时钟，`now` 由调用方给）⇒ 冒烟可以直接造反例。
enum DelegationRule {

    /// 通过时返回**解析出来的 worker**（名字是给人看的，id 才是身份）。
    ///
    /// `busy` 是"这些 worker 手上还没落定的单"（`openDelegations` 的结果），
    /// `usedToday` / `usedThisTurn` 由调用方数（它们要查库/数循环，不属于纯判据）。
    ///
    /// 判据顺序 = 文档 §04 那张表的顺序: 先"这个人存不存在"，再"他是不是能当 worker"，
    /// 再"他有空吗"，最后才是配额 —— 因为前几条是**事实错误**（改一次就对），配额是**额度**。
    static func check(_ ask: DelegationAsk, from main: ScheduledTask,
                      roster: [ScheduledTask], busy: [UUID: Delegation],
                      usedToday: Int, usedThisTurn: Int) -> Result<UUID, DelegationRefusal> {
        guard main.role == .main else { return .failure(.notMain) }
        let name = ask.worker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = roster.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name
        }) else {
            return .failure(.unknownWorker(name))
        }
        guard target.role == .worker else { return .failure(.workerIsMain(target.name)) }
        guard target.enabled else { return .failure(.workerDisabled(target.name)) }
        if let open = busy[target.id] {
            return .failure(.workerBusy(name: target.name, goal: open.goal,
                                        startedAt: open.startedAt))
        }
        guard (DelegationLimit.minMinutes...DelegationLimit.maxMinutes).contains(ask.afterMinutes)
        else { return .failure(.timeOutOfRange(minutes: ask.afterMinutes)) }
        if let dueIn = ask.dueInMinutes, dueIn <= ask.afterMinutes {
            return .failure(.dueNotAfterStart(after: ask.afterMinutes, dueIn: dueIn))
        }
        // 配额放在最后: 它的文案是"额度用完了"，而前几条是"这张单本身不成立"。
        // 先报额度会让模型以为改个时间就能过 —— 实际上它派错了人。
        guard usedThisTurn < DelegationLimit.maxPerTurn else {
            return .failure(.turnLimit(DelegationLimit.maxPerTurn))
        }
        guard usedToday < main.effectiveDelegatesPerDay else {
            return .failure(.dailyLimit(used: usedToday, quota: main.effectiveDelegatesPerDay))
        }
        return .success(target.id)
    }

    /// 拒绝时附带的可用名单（文档 §04 第 1 条: "回一句可用名单，让下一轮能直接改对"）。
    ///
    /// 只列**这个 main 名下的** worker —— 别人的队伍对这个 main 不可见（P3 的【你的队伍】
    /// 也只列自己的），列出来只会让它去派一个派不了的人。
    static func rosterLine(_ main: ScheduledTask, roster: [ScheduledTask],
                           busy: [UUID: Delegation]) -> String {
        let mine = roster.filter { $0.role == .worker && $0.parentId == main.id }
        guard !mine.isEmpty else { return "可用名单：（空 —— 这个 main 名下还没有 worker）" }
        let rows = mine.map { w -> String in
            let state: String
            if !w.enabled { state = "已停用" }
            else if let d = busy[w.id] {
                state = d.status == .running ? "在跑" : "已排上 \(DelegationRefusal.hhmm(d.dueAt))"
            } else { state = "空闲" }
            return "\(w.name)(\(state))"
        }
        return "可用名单：" + rows.joined(separator: " / ")
    }
}

/// spool 的解析口径 —— **一处定义，扩展侧只写不解析**（同 `FollowUpSpool`）。
enum DelegationSpool {

    struct Rejection: Equatable {
        let line: Int
        let reason: String
    }

    static func parse(_ text: String) -> (items: [DelegationAsk], rejects: [Rejection]) {
        var items: [DelegationAsk] = []
        var rejects: [Rejection] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            do {
                items.append(try parseLine(line))
            } catch let e as Reject {
                rejects.append(Rejection(line: i + 1, reason: e.reason))
            } catch {
                rejects.append(Rejection(line: i + 1, reason: "不是合法的 JSON"))
            }
        }
        return (items, rejects)
    }

    private struct Reject: Error { let reason: String }

    private static func parseLine(_ line: String) throws -> DelegationAsk {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw Reject(reason: "不是合法的 JSON")
        }
        guard let dict = obj as? [String: Any] else { throw Reject(reason: "不是 JSON 对象") }
        guard let rawId = (dict["id"] as? String)?.trimmingCharacters(in: .whitespaces),
              let id = UUID(uuidString: rawId) else {
            throw Reject(reason: "缺 id 或 id 不是 UUID")
        }
        func text(_ k: String) -> String {
            ((dict[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func int(_ k: String) throws -> Int? {
            guard let n = dict[k] as? NSNumber else { return nil }
            let v = n.intValue
            // `NSNumber` 把 `3.5` 也当数字 ⇒ 非整数在这里拒（同 `FollowUpSpool.parseLine`）。
            guard Double(v) == n.doubleValue else {
                throw Reject(reason: "\(k) 必须是整数（拿到 \(n.doubleValue)）")
            }
            return v
        }
        let worker = text("worker")
        guard !worker.isEmpty else { throw Reject(reason: "worker 是空的") }
        let goal = text("goal")
        guard !goal.isEmpty else {
            // goal 不是装饰: worker 被叫起来时，它就是"这一次要干什么"的全部信息。
            throw Reject(reason: "goal 是空的")
        }
        let acceptance = text("acceptance")
        guard !acceptance.isEmpty else {
            // acceptance 进 worker 台账的「完成状态」—— 没有它，交活时谁也不知道算不算干完。
            throw Reject(reason: "acceptance 是空的（怎么算干完）")
        }
        guard let after = try int("after_minutes") else { throw Reject(reason: "缺 after_minutes") }
        let dueIn = try int("due_in_minutes")
        let ctx = text("context")
        return DelegationAsk(id: id, worker: worker, goal: goal, acceptance: acceptance,
                             afterMinutes: after, dueInMinutes: dueIn,
                             context: ctx.isEmpty ? nil : ctx)
    }
}
