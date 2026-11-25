//
//  TeamBoardText.swift
//  P20 P5 助理团队页的措辞、排序与度量（2026-11-25）。
//
//  设计来源: `docs/P20-functional-design.html` §03「助理团队 · 状态泳道 · 纯展示」。
//
//  ⚠️ 为什么这些要抽成纯函数: 团队页**视图层没有门**。整个 P5 能被断言的东西，
//     只有"从数据到文字/顺序/宽度"这几步 —— 它们全部不碰库、不读时钟（`now` 由调用方给），
//     于是冒烟可以直接喂一组人和一组状态，把列内排序、空列宽度、统计口径逐条钉死。
//     与 P4 的 `TeamRowText` 同一款式（视图层无门 ⇒ 把能断言的抽出来）。
//

import Foundation

// MARK: - 泳道

/// 泳道的五档 —— **顺序即语义**，从左到右 = 从"最该被我看见"到"最不需要管"。
///
/// 为什么单独一个枚举而不是直接用 `TeamState`: `TeamState` 带载荷（时刻），
/// 而"哪一列"是**分类**。分类只有五份、顺序固定；载荷每 tick 在变。
/// 把两件事混在一起，列宽/列序就会被载荷的相等性牵着走（`Date` 一改就整片重算）。
enum TeamLane: Int, CaseIterable, Identifiable {
    case running
    case queued
    case awaiting
    case idle
    case disabled

    var id: Int { rawValue }

    /// 状态 → 列。**全量分支**（不用 `default`）: `TeamState` 将来加一档时，
    /// 这里必须编译不过，而不是把它悄悄折进某个已有的列里。
    static func of(_ s: TeamState) -> TeamLane {
        switch s {
        case .running:  return .running
        case .queued:   return .queued
        case .awaiting: return .awaiting
        case .idle:     return .idle
        case .disabled: return .disabled
        }
    }
}

// MARK: - 范围（左侧那列筛选）

/// 左侧筛选的三态。**「未归属」不是"没选"** —— 它是一支残队（worker 的 main 被删了），
/// 与 `TeamRowText.identityLine` 里那个「未归属」同一个词、同一件事。
enum TeamBoardScope: Equatable {
    case all
    /// 某支队伍: **含队长本人**（他是这支队伍的人，不是"另外一个人"）。
    case team(UUID)
    case orphans
}

// MARK: - 措辞 / 排序 / 度量

enum TeamBoardText {

    // MARK: 范围过滤

    /// worker 但找不到它的 main —— `parentId` 为空，或指向一个已经不在名单里的 id。
    ///
    /// ⚠️ 必须传 `mains`（而不是每次去名单里 `first`）: 这个判据在"过滤整张表"里被调 N 次，
    /// 而 `first` 是 O(n) ⇒ 一百人就是一万次比较。名单在调用方算一次。
    static func isOrphan(_ t: ScheduledTask, mains: Set<UUID>) -> Bool {
        guard t.role == .worker else { return false }
        guard let pid = t.parentId else { return true }
        return !mains.contains(pid)
    }

    /// 某个范围里有谁。**纯函数**（只吃名单，不碰库）⇒ 冒烟能直接断言"未归属到底是谁"。
    static func people(_ scope: TeamBoardScope, all: [ScheduledTask]) -> [ScheduledTask] {
        let mains = Set(all.filter { $0.role == .main }.map(\.id))
        switch scope {
        case .all:
            return all
        case .team(let id):
            // 队长本人也在这支队伍里 —— 少了它，"CI 看守 4" 里的那个 1 就无处可寻
            // （而泳道里明明画着它）。
            return all.filter { $0.id == id || $0.parentId == id }
        case .orphans:
            return all.filter { isOrphan($0, mains: mains) }
        }
    }

    // MARK: 列头

    /// 列头那几个字。**不用 `TeamRowText.stateWord` 那一套** —— 那是"一句话"（在跑 4 分钟），
    /// 列头要的是"这一列叫什么"（在跑），数字由调用方单独画在右边。
    ///
    /// 用「停用」而不是「已停用」: 列头是**标签**不是**状态叙述**，两个字比三个字在 36pt 的
    /// 折叠栏里排得整齐（折叠态是竖排，每个字占一行）。
    static func laneTitle(_ lane: TeamLane) -> String {
        switch lane {
        case .running:  return L("在跑")
        case .queued:   return L("已排上")
        case .awaiting: return L("等回执")
        case .idle:     return L("空闲")
        case .disabled: return L("停用")
        }
    }

    // MARK: 卡片第二行

    /// 卡片第二行 = **归属 · 时态**（样张: `CI 看守 · 3 分钟` / `金融对账 · 3 天`）。
    ///
    /// ⚠️ 归属是泳道页**唯一还能认出"谁是谁的人"的地方**（文档 §03 明写）——
    /// 泳道按状态分列之后，一支队伍被拆到五列里，卡片上再不写归属，二十张卡就是认不出谁是谁的。
    /// 所以这一格**不许省**，宁可时态短语再短一点。
    static func cardSubtitle(_ t: ScheduledTask, parentName: String?,
                             state: TeamState, now: Date) -> String {
        let owner: String
        if t.role == .worker {
            // 悬挂值（main 被删了）说「未归属」，与列表行 L2 同一个词 ——
            // 留空会让这张卡读成"这个人没有队伍这个概念"，而它其实是一支残队的人。
            owner = parentName ?? L("未归属")
        } else {
            // `main` 是角色名，与 P4 同一条判据（不进词表、`L()` 不碰它）。
            owner = TeamRowText.roleToken(kind: t.kind, role: t.role)
        }
        return owner + " · " + statePhrase(state, now: now)
    }

    /// 卡片上的**时态短语** —— 比 `TeamRowText.stateWord` 更短（卡片只有 127pt 可用宽 = 150 − 左右各 10 − 竖条 3）。
    ///
    /// 与列表行那份的差别是刻意的: 列表行要能独立读成一句话（"在跑 4 分钟"），
    /// 卡片前面已经有归属（"CI 看守 · 4 分钟"），再写"在跑"就是同一列说两遍 ——
    /// 卡片坐在哪一列，本来就已经说了它是哪一档。
    static func statePhrase(_ s: TeamState, now: Date) -> String {
        switch s {
        case .running(let since):
            // 样张就是 `4 分钟`（不带"起跑"）—— 卡片坐在「在跑」列里，动词已经由列头给了。
            let minutes = since.map { max(1, Int(now.timeIntervalSince($0) / 60)) } ?? 1
            return String(format: L("%lld 分钟"), minutes)
        case .queued(let at):
            return DelegationRefusal.hhmm(at)
        case .awaiting(let since):
            // 等回执的时态是"什么时候交的活"（样张 09:42）—— 人要知道的是"这张单躺了多久"，
            // 而"躺了多久"由列内排序回答（等最久的在最上面）。
            return DelegationRefusal.hhmm(since)
        case .idle(let last):
            // ⚠️ 时态短语必须**短到放得进 127pt**（150 卡宽 − 左右各 10 − 竖条 3）。
            // 第一版写的是「N 天没派 / 还没跑过」，出图实测整行被尾部截断 —— 而截掉的
            // 恰恰是后面的字（"派"字没了，读起来是"N 天"）。归属在前、时态在后，
            // 截尾保住归属是对的；但这个短语本身就不该长到需要截。
            // 「几天」的语义由列头「空闲」承担，卡片上只留数字 —— 与样张同一个口径。
            guard let last else { return L("没跑过") }
            let days = Int(now.timeIntervalSince(last) / 86_400)
            if days >= 1 { return String(format: L("%lld 天"), days) }
            let hours = Int(now.timeIntervalSince(last) / 3_600)
            if hours >= 1 { return String(format: L("%lld 小时"), hours) }
            return L("刚跑过")
        case .disabled:
            // 这句话是"停用"这一档的**后果**，不是同义反复: 派活会被硬拒
            // （`TeamRule` 的 `.workerDisabled` 分支），人得知道点了会怎样。
            return L("派了会被拒")
        }
    }

    // MARK: 列内排序

    /// 列内排序 —— **不是按名字，是按"最该被我看见的"**（文档 §03）。
    ///
    /// 五档的键各不相同，但都指向同一句人话:
    ///   · 在跑 —— 起跑时刻**升序**（跑得久的浮上来: 那是"卡住了"的最大嫌疑）
    ///   · 已排上 —— 到点时刻**升序**（最快起跑的在上）
    ///   · 等回执 —— 交活时刻**升序**（等最久的在上）
    ///   · 空闲 —— 最后动过**升序**，`nil` 排最前（"从没跑过"= 最久没动）
    ///   · 停用 —— 同空闲。**文档说"按停用时刻"，而本仓没有这个字段**
    ///     （`ScheduledTask` 没有 `updatedAt`）⇒ 用"最后动过"顶替，并在界面上不声称是停用时刻。
    ///     这是**如实降级**，不是凑数: 两档之间唯一有意义的比较本来就是"谁更久没动静"。
    ///
    /// 排序必须**确定**: 键相等时按 `createdAt`（建人顺序）再按名字。
    /// `sort` 本身不稳定，少了这个 tiebreaker，同键的两张卡每 tick 换位 —— 而"位置固定"
    /// 正是这个页面敢叫人靠位置认人的前提。
    static func order(_ lane: TeamLane, _ people: [ScheduledTask],
                      states: [UUID: TeamState]) -> [ScheduledTask] {
        people
            .filter { TeamLane.of(stateOfOrIdle($0, states)) == lane }
            .sorted { a, b in
                let ka = sortKey(stateOfOrIdle(a, states)) ?? .distantPast
                let kb = sortKey(stateOfOrIdle(b, states)) ?? .distantPast
                if ka != kb { return ka < kb }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.name < b.name
            }
    }

    /// 没算过状态的人当"从没动过"（与 `SchedulerService.teamState(of:)` 的兜底同一个值）——
    /// 页面不会因为一条还没进快照的行就少画一个人。
    private static func stateOfOrIdle(_ t: ScheduledTask, _ states: [UUID: TeamState]) -> TeamState {
        states[t.id] ?? .idle(lastActive: t.lastRunAt)
    }

    private static func sortKey(_ s: TeamState) -> Date? {
        switch s {
        case .running(let d):  return d
        case .queued(let d):   return d
        case .awaiting(let d): return d
        case .idle(let d):     return d
        case .disabled:        return nil
        }
    }

    // MARK: 度量

    /// 一列此刻多宽。**空列折叠**（P5 落地时对"只有一两个助理"的真空图定的）。
    ///
    /// 判据只有一句: 文档说"列宽固定 150"的理由是**两行文字折行**，而空列里没有字 ——
    /// 所以 150 那条约束对空列不存在。收窄的是**宽度，不是列序**:
    /// 五列永远按 [`在跑` `已排上` `等回执` `空闲` `停用`] 排，位置语义一点没动。
    ///
    /// ⚠️ 不做的两件事: ① **不隐藏空列** —— 隐藏会让某一列一有卡就整片右移，而"位置固定"
    /// 是这个页面唯一的导航锚；② **不做换列/宽度动画** —— 卡片在列间移动的几百毫秒里，
    /// 点谁都是错的位置（文档同一条理由）。
    static func laneWidth(empty: Bool) -> CGFloat {
        empty ? Tune.teamRailWidth : Tune.teamLaneWidth
    }

    /// 整片泳道的宽（含列间 gap）。调用方拿它跟可用宽比: 装得下就居中，装不下就横向滚。
    static func boardWidth(cards: [TeamLane: Int]) -> CGFloat {
        let widths = TeamLane.allCases.map { laneWidth(empty: (cards[$0] ?? 0) == 0) }
        return widths.reduce(0, +) + CGFloat(TeamLane.allCases.count - 1) * Tune.teamLaneGap
    }

    // MARK: 统计行

    /// 顶部那一行。**只列非零的档** —— 零有列头的 `0` 在说，统计行再说一遍就是噪音，
    /// 而这一行的用处是"扫一眼知道有几件事在动"。
    ///
    /// 队伍的计数**只在 > 1 时出现**: "1 支队伍"是每个单队伍用户的默认状态，
    /// 天天报一个恒为 1 的数，等于那一格白占。
    static func statsLine(total: Int, teams: Int, cards: [TeamLane: Int]) -> String {
        var parts = [String(format: L("%lld 个助理"), total)]
        if teams > 1 { parts.append(String(format: L("%lld 支队伍"), teams)) }
        for lane in TeamLane.allCases {
            let n = cards[lane] ?? 0
            guard n > 0 else { continue }
            parts.append(String(format: L("%lld %@"), n, laneTitle(lane)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 检查器空态

    /// 没选卡时右侧那一栏 —— **不画一片空白**。
    ///
    /// 为什么值得单独设计: 这是个纯展示页，进来看的第一眼大概率是"没选中任何东西"，
    /// 而那一眼如果是一片空白，整页就只剩"左边一列名单 + 中间几张卡"，
    /// 人会觉得这个页面没做完。这里放的是**当前范围的真实读数**（不是引导占位）。
    static func scopeLines(scopeName: String, total: Int, teams: Int,
                           cards: [TeamLane: Int]) -> [String] {
        var lines = [scopeName]
        lines.append(String(format: L("%lld 个人 · %lld 支队伍"), total, teams))
        let moving = TeamLane.allCases.compactMap { lane -> String? in
            let n = cards[lane] ?? 0
            guard n > 0, lane == .running || lane == .awaiting || lane == .queued else { return nil }
            return String(format: L("%lld %@"), n, laneTitle(lane))
        }
        lines.append(moving.isEmpty ? L("手上都没有活") : moving.joined(separator: " · "))
        return lines
    }

    /// 一个人都还没有时的整页空态（**五列全空 + 一句去哪里建**）。
    ///
    /// 判据: 空态必须给出**下一步去哪**，而不是只说"还没有"。这个页面的入口在侧栏，
    /// 而人可以是从定时任务页点过来的 —— 只写"还没有助理"，他下一步会去翻设置。
    static func emptyBoardLine() -> String {
        L("还没有助理。去「定时任务」新建一个，或把已有的改成 worker")
    }
}
