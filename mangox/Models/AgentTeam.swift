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
    /// worker 没写职责（`description` 空）。
    ///
    /// ⚠️ 这一条**域层也拦**（文档 §04「worker 必填（域层与保存都拦）」）：职责是
    /// `list_workers` 与【你的队伍】的唯一来源，空着 = 一个**选不出来**的人 ——
    /// 而"选不出来"在主模型那一侧表现为"这个 worker 好像什么都能干"，不是报错。
    /// 只在表单拦是不够的：`addScheduled` 是公开写路径（将来的导入 / 批量编辑会绕过视图）。
    ///
    /// 代价（明写）：库里若真有一行空职责的 worker（P4 之前建的、或手改的配置），
    /// 它改名字也会被这一条挡下。`list_workers` 那句「没有写职责」的缺口提示就是给它们留的
    /// —— 那不是"允许建空的"，是"存量坏了要说得清"。
    case workerWithoutDuty
    case duplicateName(String)

    /// 恒中文，进日志 / 时间线 / 拒绝回执。**不是界面词**（见文件头）。
    var reason: String {
        switch self {
        case .mainHasParent:
            return "main 不该有上级 —— 它是一支队伍的起点"
        case .workerWithoutParent:
            return "worker 必须归属一个 main"
        case .workerWithoutDuty:
            return "worker 必须写职责 —— 名单与注入段只读那一行，空着等于一个选不出来的人"
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
            // 结构先于内容: 归谁（上面两条）说清了, 才轮到"它是什么人"。
            if t.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .workerWithoutDuty
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

    // MARK: - P3 注入与只读工具的容量（2026-11-24）

    /// 【派活回执】最多念几条。堆到十几条时人看到的是一堵墙，而他要决定的是"现在怎么办"。
    /// 没被念到的**不丢**（`reported_at` 仍 NULL）⇒ 下一轮接着念。
    static let maxReceipts = 5

    /// `read_worker_ledger` 的总长上限与"最近多少行"。
    ///
    /// 为什么不返回整篇: 一份台账五节写满是几千字，一个 main 巡五个 worker 就是两万字 ——
    /// 那是把"独立台账"的好处（各占各的窗口）又塞回一个窗口里。要看全篇就分节再要一次。
    static let maxLedgerChars = 1500
    static let maxLedgerLines = 20
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

// MARK: - P3 注入段与只读工具的正文（2026-11-24）

/// 一个人在团队里的**五档状态** —— 注入面与界面共用这一份判据（措辞各写各的）。
///
/// ⚠️ 为什么判据只许一处: 界面说"在跑"、注入段说"空闲"，模型就会把活派给一个正在干活的
/// worker（那一单会被硬拒，白烧一轮）。而两处各写一遍「谁在跑、谁排上了」是必然会漂的。
///
/// ⚠️ `.awaiting`（等回执）在**注入面**折叠成"空闲"（见 `TeamPrompt.stateWord`）:
/// 从"能不能派"的角度它确实闲着（`openDelegations` 只算 queued / running），
/// 而"有一张单等你处理"已经由【派活回执】那一段说了 —— 在名单里再说一遍，
/// 会让 main 以为这个人不能派。
enum TeamState: Equatable {
    case disabled
    /// 正在跑（`since` = 起跑时刻，用来算"几分钟"）。
    case running(since: Date?)
    /// 已排上，等 `at` 起跑。
    case queued(at: Date)
    /// 交了活、main 还没汇报（`since` = 落定时刻）。**只影响界面**，不影响能不能派。
    case awaiting(since: Date)
    /// 闲着。`lastActive` = 上一次自己跑过的时刻（算"几天没派"）。
    case idle(lastActive: Date?)

    static func of(_ t: ScheduledTask, busy: [UUID: Delegation],
                   awaiting: Date?) -> TeamState {
        // 顺序 = 人的判断顺序: 停用 ⇒ 在跑 ⇒ 已排上 ⇒ 等回执 ⇒ 空闲。
        // 前两档是**硬的**（派不了），后两档是"闲着，但手上有事 / 没事"。
        guard t.enabled else { return .disabled }
        if let d = busy[t.id] {
            return d.status == .running ? .running(since: d.startedAt) : .queued(at: d.dueAt)
        }
        if let a = awaiting { return .awaiting(since: a) }
        return .idle(lastActive: t.lastRunAt)
    }
}

/// 两段注入 + 两个只读工具的**正文** —— 全是纯函数（不碰 DB、不读时钟，`now` 由调用方给），
/// 所以冒烟可以直接喂数据断言字数与措辞，不用起一场真回合。
///
/// ⚠️ 为什么正文在 Swift 而不在扩展的 TS 里: 扩展那半边**没有门禁**（`node --check` 只认
/// CommonJS，对 ESM 静默退 0 —— 0.2.11 那次假门）。而这两段是**每轮都进上下文**的字节，
/// 它们必须能被断言字数、能被造反例。扩展只负责"按名字把已经算好的那段打印出来"。
///
/// ⚠️ 措辞**恒中文**（本文件在 L10n 的 `EXCLUDE_FILES` 里）: 这是注入面，模型认的就是这些字。
/// 界面取词是 P4/P5 的事 —— 同一件事在两处取词，注入 prompt 的字节会随界面语言变。
enum TeamPrompt {

    static let teamHeader = "【你的队伍】"
    static let receiptHeader = "【派活回执】"

    // MARK: 名单（两处共用一份筛选与排序）

    /// "我的人"。**上限 12**（`DelegationLimit.maxTeamRows`，域层拦得住，这里只是兜底）。
    /// 排序 = 建人顺序：每轮顺序一样，模型才不会以为"队伍变了"。
    static func myWorkers(_ main: ScheduledTask, roster: [ScheduledTask]) -> [ScheduledTask] {
        let mine = roster
            .filter { $0.role == .worker && $0.parentId == main.id }
            .sorted { $0.createdAt < $1.createdAt }
        return Array(mine.prefix(DelegationLimit.maxTeamRows))
    }

    /// 状态词（注入面的**显示形态**）。判据在 `TeamState.of`，这里只管措辞。
    ///
    /// 「空闲 N 天」只在 N ≥ 1 时出现: 一天之内说"空闲 0 天"是噪音，而那个数字的用途是
    /// "三天没派过活的人该被我看见"（文档 §03 列内排序那一条）。
    static func stateWord(_ w: ScheduledTask, busy: [UUID: Delegation], now: Date) -> String {
        switch TeamState.of(w, busy: busy, awaiting: nil) {
        case .disabled: return "已停用"
        case .running(let since):
            let minutes = since.map { max(1, Int(now.timeIntervalSince($0) / 60)) } ?? 1
            return "在跑 \(minutes) 分钟"
        case .queued(let at): return "已排上 " + DelegationRefusal.hhmm(at)
        case .awaiting: return "空闲"      // 见 `TeamState` 的说明：手上没活，回执是 main 自己的账
        case .idle(let last):
            guard let last, now.timeIntervalSince(last) >= 86_400 else { return "空闲" }
            return "空闲 \(Int(now.timeIntervalSince(last) / 86_400)) 天"
        }
    }

    /// 一句话结论 —— 【派活回执】与时间线**共用这一份措辞**。
    /// 分两处写，三个月后两边说的就不是同一件事了（而人会把它们当成同一件事）。
    static func verdictHead(status: DelegationStatus, worker: String,
                            summary: String?, note: String?) -> String {
        switch status {
        case .done:
            return "\(worker) 交活了：\(summary ?? "（没写结论，细节去读它的台账）")"
        case .cancelled:
            return "\(worker) 那张单作废了：\(note ?? "原因不明")"
        default:
            return "\(worker) 没干成：\(note ?? "这一轮没有产出")"
        }
    }

    // MARK: 【你的队伍】

    /// `nil` = 名下**一个 worker 都没有**。
    ///
    /// 为什么不是空段头: 一个只有标题的段会被读成"有过、现在没了"，而事实是它还没有人。
    /// 一个字的成本都不该付在"你什么都没有"这句上 —— 它本来就没有可执行的信息。
    static func rosterBlock(main: ScheduledTask, roster: [ScheduledTask],
                            busy: [UUID: Delegation], now: Date) -> String? {
        let mine = myWorkers(main, roster: roster)
        guard !mine.isEmpty else { return nil }
        var lines = [teamHeader]
        for w in mine {
            let duty = w.description.trimmingCharacters(in: .whitespacesAndNewlines)
            // 职责**原文照搬、一字不截**: 这是它被选中的唯一依据，截一半等于让人猜。
            lines.append("- \(w.name) · \(duty.isEmpty ? "（没写职责）" : duty) · "
                         + stateWord(w, busy: busy, now: now))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 【派活回执】

    /// `nil` = 没有没汇报过的终态。
    ///
    /// 这里**只念结论一行**，不贴台账正文: 那一行是"要不要现在处理"的判据，
    /// 细节在 worker 自己的账本里（`read_worker_ledger` 按需取）。
    static func receiptBlock(_ rows: [Delegation], workers: [UUID: ScheduledTask],
                             now: Date) -> String? {
        guard !rows.isEmpty else { return nil }
        var lines = [receiptHeader + "（最近 \(DelegationLimit.maxReceipts) 条，没汇报过的）"]
        for d in rows.prefix(DelegationLimit.maxReceipts) {
            let name = workers[d.toTask]?.name ?? "worker"
            let at = DelegationRefusal.hhmm(d.finishedAt ?? d.dueAt)
            lines.append("- \(at) " + verdictHead(status: d.status, worker: name,
                                                 summary: d.summary, note: d.note))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: `list_workers` 的正文

    /// 名单 + 简历（一次拿全，无参）。
    ///
    /// **缺口必须分级说出来**，两档不能合并:
    ///   · 没有职责 —— 异常态（worker 本该必填）⇒ 明说"你只能从名字判断"；
    ///   · 有职责、没说明 —— 正常但信息少 ⇒ 说"只有一句职责"。
    /// 留白会让模型把这两种都读成"这个人没什么特别的"，而它们其实是**可行动的信息缺口**
    /// （改派，或者先问人）。
    static func dossierBlock(main: ScheduledTask, roster: [ScheduledTask],
                             busy: [UUID: Delegation], lastDone: [UUID: Date],
                             now: Date) -> String {
        let mine = myWorkers(main, roster: roster)
        guard !mine.isEmpty else { return "你名下还没有 worker —— 这一轮只能自己干。" }
        var out: [String] = []
        for w in mine {
            let activity: String
            if let done = lastDone[w.id] {
                activity = "上次 " + monthDay(done) + " 交活"
            } else if let ran = w.lastRunAt {
                activity = "上次 " + monthDay(ran) + " 跑过，没交过活"
            } else {
                activity = "从未交活"
            }
            out.append("- \(w.name) | \(stateWord(w, busy: busy, now: now)) | \(activity)")
            let duty = w.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if duty.isEmpty {
                out.append("  （**没有写职责** —— 你只能从名字判断。）")
                continue
            }
            out.append("  职责：\(duty)")
            let detail = w.descriptionDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(detail.isEmpty ? "  （只有一句职责，没有说明。）" : "  说明：\(detail)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: `read_worker_ledger` 的正文

    /// 一份台账的**摘要 + 最近 20 行**，总长截到 1500 字。
    ///
    /// 结构不靠猜: 目标与「完成状态」走 `AssistantLedger.parse`（那是台账的唯一解析口径），
    /// 「最近 20 行」走原文的尾巴 —— 两者都要，因为**验收项的原文与它最近的动线是两件事**：
    /// 前者答"干到哪了"，后者答"刚才在干什么"。
    static func ledgerBlock(workerName: String, ledger: String?) -> String {
        let raw = (ledger ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "「\(workerName)」还没有台账 —— 它没跑过，或者跑完没写。"
        }
        let a = AssistantLedger.parse(raw)
        let head = "【\(workerName) · 台账】\n目标："
            + (a.goal.isEmpty ? "（台账里没写目标）" : a.goal)
        let tail = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(DelegationLimit.maxLedgerLines).joined(separator: "\n")
        let tailPart = "最近 \(DelegationLimit.maxLedgerLines) 行：\n" + tail
        // 验收项那一节。**「完成状态」是唯一会随验收项线性变长的一节** —— 所以要砍就砍它。
        var statusLines: [String]
        if a.items.isEmpty {
            statusLines = ["完成状态：（没有验收项）"]
        } else {
            statusLines = ["完成状态："]
            for it in a.items {
                let mark = it.mark == .done ? "[x]" : (it.mark == .blocked ? "[!]" : "[ ]")
                statusLines.append("- \(mark) \(it.text)")
            }
        }
        // 预算分配: 头 + 尾巴**先占住**，剩下的给验收项。
        //
        // ⚠️ 为什么先保尾巴: 「最近 20 行」是这个工具存在的另一半理由（"刚才在干什么"），
        // 而验收项是累积的、下一轮还在。从尾部硬截会把最新那条动线藏起来 ——
        // 第一版就是这么写的，实测读数 1500 字、内容全对、**尾巴一行都没了**。
        let cap = DelegationLimit.maxLedgerChars
        let room = cap - head.count - tailPart.count - 4
            - 24   // 给"还有 N 项没列"那句留的位置
        var kept = [statusLines[0]]
        var used = statusLines[0].count
        if statusLines.count > 1 {
            for line in statusLines.dropFirst() {
                if used + line.count + 1 > room { break }
                kept.append(line)
                used += line.count + 1
            }
        }
        let omitted = statusLines.count - kept.count
        if omitted > 0 { kept.append("…还有 \(omitted) 项没列（要看全篇就分节问）") }
        let s = [head, kept.joined(separator: "\n"), tailPart].joined(separator: "\n\n")
        // 兜底: 尾巴自己就超了上限（20 行可以很长）—— 那时候只能截，但至少结构还在。
        return s.count <= cap ? s : clipped(s, cap)
    }

    /// 截断时**把提示也算在上限里** —— 否则"截到 1500 字"这句话本身就是假的
    /// （实测读数会是 1500 + 那行提示的长度）。
    private static func clipped(_ s: String, _ cap: Int) -> String {
        guard s.count > cap else { return s }
        let note = "\n…（截到 \(cap) 字；要看全篇就分节问）"
        return String(s.prefix(max(0, cap - note.count))) + note
    }

    static func monthDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: d)
    }

    // MARK: 交给扩展的那份数据

    /// 两个只读工具的正文**提前算好**，写成一个 JSON 交给扩展。
    ///
    /// 为什么提前算: 那两件事要的都是库里的瞬时事实（名单 / 忙闲 / 台账），子进程读不到库，
    /// 它只能读文件。写的时机是**这一轮开始时** ⇒ 模型在这一轮里拿到的一定是同一份，
    /// 不会中途漂（而"同一次调用两次结果不一样"是最难解释的一种现象）。
    static func dossierJSON(roster: String, ledgers: [String: String]) -> String {
        let obj: [String: Any] = ["roster": roster, "ledgers": ledgers]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
