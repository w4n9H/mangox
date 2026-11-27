//
//  TeamBoardText.swift
//  P20 P5 助理团队页的措辞、排序与度量（2026-11-25，2026-11-27 泳道退役）。
//
//  设计来源: `docs/P20-functional-design.html` §03「助理团队 · 纯展示」。
//
//  ⚠️ 为什么这些要抽成纯函数: 团队页**视图层没有门**。整个 P5 能被断言的东西，
//     只有"从数据到文字/顺序/宽度"这几步 —— 它们全部不碰库、不读时钟（`now` 由调用方给），
//     于是冒烟可以直接喂一组人和一组状态，把组内排序、列数、统计口径逐条钉死。
//     与 P4 的 `TeamRowText` 同一款式（视图层无门 ⇒ 把能断言的抽出来）。
//
//  ⚠️ 度量那个函数**只吃一个数**（可用宽），吐"一行摆几张"。卡宽是定稿常数（200），
//     不是算出来的 —— 宽度不够就少摆一张。见 `cardColumns(available:)` 里那张窗口对照表。
//

import Foundation

// MARK: - 状态档

/// 状态的五档 —— **顺序即语义**，从"最该被我看见"到"最不需要管"。
///
/// 为什么单独一个枚举而不是直接用 `TeamState`: `TeamState` 带载荷（时刻），
/// 而"哪一档"是**分类**。分类只有五份、顺序固定；载荷每 tick 在变。
/// 把两件事混在一起，排序/配色就会被载荷的相等性牵着走（`Date` 一改就整片重算）。
///
/// ⚠️ 2026-11-27 由 `TeamLane` 改名: 泳道那层已经整层退役（改成分组卡片），
/// 但"五档"本身一点没少 —— 它现在管的是**组内排序 + 左边缘状态色 + 统计行**。
/// 名字叫回 `lane` 会让后来的人以为界面里还有列。
enum TeamStage: Int, CaseIterable, Identifiable {
    case running
    case queued
    case awaiting
    case idle
    case disabled

    var id: Int { rawValue }

    /// 状态 → 档。**全量分支**（不用 `default`）: `TeamState` 将来加一档时，
    /// 这里必须编译不过，而不是把它悄悄折进某个已有的档里。
    static func of(_ s: TeamState) -> TeamStage {
        switch s {
        case .running:  return .running
        case .queued:   return .queued
        case .awaiting: return .awaiting
        case .idle:     return .idle
        case .disabled: return .disabled
        }
    }
}

/// 一个人归谁 —— 2026-11-27 起它不再是"左侧筛选项"，而是**分组的输入**。
///
/// 左栏筛选整层删掉了（boss: 个人用户 3 支队伍 × 3~5 人，列出来反而重复 ——
/// 分组头已经写着「写清楚了的 4 人 · 2 在跑」）。但这个枚举留着: 分组要算的三件事
/// （全部 / 某支队伍含队长本人 / 未归属）一点没变，冒烟里那三条也照旧成立。
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

    // MARK: 档名

    /// 那一档的字。**不用 `TeamRowText.stateWord` 那一套** —— 那是"一句话"（在跑 4 分钟），
    /// 这里要的是"这一档叫什么"（在跑），用在统计行与检查器。
    ///
    /// 用「停用」而不是「已停用」: 这里是**标签**不是**状态叙述**，两个字并排更好排。
    static func stageTitle(_ stage: TeamStage) -> String {
        switch stage {
        case .running:  return L("在跑")
        case .queued:   return L("已排上")
        case .awaiting: return L("等回执")
        case .idle:     return L("空闲")
        case .disabled: return L("停用")
        }
    }

    // MARK: 卡片第二行 / 状态行

    /// 卡片第二行 = **归属**（样张: `管理` / `写清楚了的` / `未归属`）。
    ///
    /// ⚠️ 2026-11-27 改版后这一行**只写归属，不再带时态**。原因: 卡片上多了一行独立的状态行
    /// （"在跑 1 分钟"），而原来的 `归属 · 时态` 会让**同一个时长说两遍**
    /// （"写清楚了的 · 1 分钟" 紧接 "在跑 1 分钟"—— 出图当场看出来的）。
    /// 时态归状态行，这一行归身份，两个通道各说一件事。
    ///
    /// ⚠️ 归属这一格**不许省**: 一支队伍的卡与"未归属"的卡混在一屏里，卡片上不写归属，
    /// 二十张卡就是认不出谁是谁的人。
    static func cardSubtitle(_ t: ScheduledTask, parentName: String?) -> String {
        if t.role == .worker {
            // 悬挂值（main 被删了）说「未归属」，与列表行 L2 同一个词 ——
            // 留空会让这张卡读成"这个人没有队伍这个概念"，而它其实是一支残队的人。
            return parentName ?? L("未归属")
        }
        // 队长自己的卡写它的角色短标记（`管理`）。2026-11-25 起与列表行**同一个函数**取词
        // （`roleToken`），两处不会漂。
        return TeamRowText.roleToken(kind: t.kind, role: t.role)
    }

    // 卡片上那行**状态** = `TeamRowText.stateWord`，本文件**不再有 `cardStateLine`**。
    //
    // ⚠️ 2026-11-27 出图后改回单标签：上一版让停用档多带一句后果（「停用 · 派了会被拒」），
    //    而一屏三张停用卡就是**同一句后果复读三遍**，同时顶栏 chip 还写着「3 停用」。
    //    后果本身没丢，搬去了检查器（`whoBlock`）—— 点开那一栏有整行空间把它说完。
    //    判据：**卡片是扫视面，一句话只许出现一次；要解释的话去检查器说。**

    // MARK: 组内排序

    /// 组内排序 —— **不是按名字，是按"最该被我看见的"**。
    ///
    /// 两级: ① **档位**（在跑 → 已排上 → 等回执 → 空闲 → 停用，即 `TeamStage.rawValue`）；
    /// ② 同档内按各自的时刻键:
    ///   · 在跑 —— 起跑时刻**升序**（跑得久的浮上来: 那是"卡住了"的最大嫌疑）
    ///   · 已排上 —— 到点时刻**升序**（最快起跑的在上）
    ///   · 等回执 —— 交活时刻**升序**（等最久的在上）
    ///   · 空闲 —— 最后动过**升序**，`nil` 排最前（"从没跑过"= 最久没动）
    ///   · 停用 —— 同空闲。**文档说"按停用时刻"，而本仓没有这个字段**
    ///     （`ScheduledTask` 没有 `updatedAt`）⇒ 用"最后动过"顶替，并在界面上不声称是停用时刻。
    ///     这是**如实降级**，不是凑数: 两档之间唯一有意义的比较本来就是"谁更久没动静"。
    ///
    /// ⚠️ 2026-11-27 起**不再按档过滤**（泳道退役，一张卡只属于一个组，不归属某一列）。
    ///    档位从"第几次调用"变成"排序的第一级键" —— 顺序语义一字未改。
    ///
    /// 排序必须**确定**: 键相等时按 `createdAt`（建人顺序）再按名字。
    /// `sort` 本身不稳定，少了这个 tiebreaker，同键的两张卡每 tick 换位 —— 而"位置固定"
    /// 正是这个页面敢叫人靠位置认人的前提。
    static func order(_ people: [ScheduledTask], states: [UUID: TeamState]) -> [ScheduledTask] {
        people.sorted { a, b in
            let sa = stateOfOrIdle(a, states), sb = stateOfOrIdle(b, states)
            let ra = TeamStage.of(sa).rawValue, rb = TeamStage.of(sb).rawValue
            if ra != rb { return ra < rb }
            let ka = sortKey(sa) ?? .distantPast
            let kb = sortKey(sb) ?? .distantPast
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

    // MARK: 队伍色

    /// 看板上每支队伍的**色板下标**（key = main 的 id）。
    ///
    /// 三条都要，缺一条就出"看起来一样"或者"颜色乱跳":
    ///   · **互不相同**（队伍数 ≤ 色板数时）—— 这条就是 boss 那句「不同的团队，应该有颜色区分」
    ///     的白话。第一版按 uuid 取哈希取模，六色两支队伍有 1/6 概率**撞成同色**，而撞了之后
    ///     每一张卡都"看起来是对的"，只有并排摆着才看得出来 ⇒ 拿互不相同当判据。
    ///   · **同 uuid 同色，且与传入顺序无关**（先按 uuid 排序再取位）—— 排序是确定的，
    ///     所以 `mains` 这一年的排列怎么变都不影响颜色。
    ///   · **不随进程重播种** —— 不碰 `hashValue`（Swift 每个进程重播种，重启一次全换色）。
    /// 代价明写: 队伍数变了（新建/删一支）时，排它后面的那些会挪一个色 —— 要"永不挪"就得容忍
    /// 撞色（确定性哈希的必然结果），两者只能选一个，这里选**不撞色**。
    static func tintIndexMap(teamIds: [UUID]) -> [UUID: Int] {
        let sorted = teamIds.sorted { $0.uuidString < $1.uuidString }
        var out: [UUID: Int] = [:]
        for (i, id) in sorted.enumerated() { out[id] = i % CodexTheme.teamTints.count }
        return out
    }

    /// 这张卡的颜色下标 —— **worker 跟它那支队伍同色**（否则一张卡写着"归 X"却与 X 不同色）。
    ///
    /// `nil` = 它没有队伍，调用方画中性灰。两种来源: ① 老库里本来就空着的 `parentId`;
    /// ② **挂在已被删除的 main 上**（`parentId` 是个悬挂值 —— 域层故意不置空，见
    /// `PersistenceStore` 那段「删 main 之后故意不置空」）。第二种只有调用方知道，
    /// 所以 `parentIsAlive` 从外面传进来 —— 与卡片第二行那个「未归属」用同一个判据，
    /// 不能一处说"没队伍"、另一处还给它上队伍色。第三种是"自己的 id 不在表里"——
    /// 那只可能是**筛选后没列出来的那支**，同样按"没队伍"处理，别现编一个色出来。
    static func cardTintIndex(_ t: ScheduledTask, parentIsAlive: Bool,
                              tintMap: [UUID: Int]) -> Int? {
        if t.role == .worker {
            guard let pid = t.parentId, parentIsAlive else { return nil }
            return tintMap[pid]
        }
        return tintMap[t.id]
    }

    // MARK: 度量

    /// 一行摆几张卡 —— **宽度不够就少摆一张，不是把卡挤窄**。
    ///
    /// 2026-11-27 boss 定稿的规则。判据只有一条: `teamCardWidth` 是**定稿宽度**（200），
    /// 压到 190 就会出现名字被省略号吃掉；所以能摆几张算几张，剩的留白。
    ///
    /// | 内容区可用宽 | 几张 | 出现在 |
    /// |---|---|---|
    /// | 1053 − 侧栏 257 = 796 | 3 | 窗口拖到最窄（`Tune.windowMinWidth` 常态档） |
    /// | 1280 − 257 = 1023 | 4 | 开机默认窗口 |
    /// | ≥ 1040 | 5（封顶） | 更宽也只是留白，卡片不跟着变宽 |
    ///
    /// ⚠️ **这个数跟窗口下限无关**: 团队页最窄需要两列 = 2×200 + 10 + 32 = 442 内容宽 ⇒
    ///    加侧栏 257 = 699 窗口，远低于既有的 1053 ⇒ **一行代码都不用为它抬低下限**。
    ///    抬下限那条路的代价见 `WorkspaceWindowFit` 文件头（补宽同步阻塞 217ms）。
    ///
    /// ⚠️ 向下取整: 让"刚好放得下"那一档不会因为 0.4pt 的余数把最后一张挤到下一行。
    static func cardColumns(available: CGFloat) -> Int {
        let step = Tune.teamCardWidth + Tune.teamCardGap
        let fit = Int(((available + Tune.teamCardGap) / step).rounded(.down))
        return min(Tune.teamCardMaxColumns, max(1, fit))
    }

    // MARK: 统计行

    /// 顶栏那几个 chip 的**数据** —— 不是一句拼好的话。
    ///
    /// 为什么返回结构而不是字符串: 改版后这一行是**分块上色**的（"2 在跑"用琥珀、"1 等回执"用红），
    /// 一句拼好的话没法分色。原来那个 `statsLine(...) -> String` 在泳道页是一行纯文本，
    /// 改版后视图用不上它了 —— 留着就成了一条**只有冒烟在守的死代码**（断言恒绿，界面根本没画）。
    ///
    /// 规则与那句一模一样: **只列非零的档**（零有卡片在说，这里再说一遍是噪音），
    /// 队伍的计数**只在 > 1 时出现**（"1 支队伍"是单队伍用户的默认状态，天天报等于白占一格）。
    /// 目标: "扫一眼知道有几件事在动"。
    static func statChips(total: Int, teams: Int, cards: [TeamStage: Int]) -> [StatChip] {
        var out = [StatChip(value: "\(total)", label: L("个助理"), stage: nil)]
        if teams > 1 { out.append(StatChip(value: "\(teams)", label: L("支队伍"), stage: nil)) }
        for stage in TeamStage.allCases {
            let n = cards[stage] ?? 0
            guard n > 0 else { continue }
            out.append(StatChip(value: "\(n)", label: stageTitle(stage), stage: stage))
        }
        return out
    }

    // MARK: 检查器空态

    /// 没选卡时下方那一栏 —— **不画一片空白**。
    ///
    /// 为什么值得单独设计: 这是个纯展示页，进来看的第一眼大概率是"没选中任何东西"，
    /// 而那一眼如果是一片空白，整页就只剩"几张卡 + 一条空横栏"，
    /// 人会觉得这个页面没做完。这里放的是**真实读数**（不是引导占位）。
    static func scopeLines(scopeName: String, total: Int, teams: Int,
                           cards: [TeamStage: Int]) -> [String] {
        var lines = [scopeName]
        lines.append(String(format: L("%lld 个人 · %lld 支队伍"), total, teams))
        let moving = TeamStage.allCases.compactMap { stage -> String? in
            let n = cards[stage] ?? 0
            guard n > 0, stage == .running || stage == .awaiting || stage == .queued else { return nil }
            return String(format: L("%lld %@"), n, stageTitle(stage))
        }
        lines.append(moving.isEmpty ? L("手上都没有活") : moving.joined(separator: " · "))
        return lines
    }

    /// 一个人都还没有时的整页空态（**一句去哪里建**）。
    ///
    /// 判据: 空态必须给出**下一步去哪**，而不是只说"还没有"。这个页面的入口在侧栏，
    /// 而人可以是从定时任务页点过来的 —— 只写"还没有助理"，他下一步会去翻设置。
    static func emptyBoardLine() -> String {
        L("还没有助理。去「定时任务」新建一个，或把已有的改成助理（执行）")
    }

    // MARK: 卡片底部那三格数字

    /// `41.2k` / `1.2k` / `860` / `—`。
    ///
    /// 为什么用 k 而不是原始位数: 卡片可用宽只有 175pt（200 − 左右各 10 − 竖条 3 − 右边 2），
    /// 三格并排时每格约 58pt；`1234567` 这种七位数会撑破格子并把旁边两格挤歪。
    /// 一位小数够用来比较量级，而"具体多少"在检查器里。
    ///
    /// `0 → "—"` 是**如实**: 没跑过的人没有 token 这个概念，写 `0` 会被读成"跑了但没花钱"。
    static func tokenLabel(_ n: Int) -> String {
        guard n > 0 else { return "—" }
        if n >= 1_000_000 {
            return String(format: "%.1fm", Double(n) / 1_000_000)
        }
        if n >= 10_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        if n >= 1_000 {
            return String(format: "%.2fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

}

/// 顶栏一个 chip 的数据。`stage` 为 `nil` = 中性灰（"7 个助理"这种数不是状态）；
/// 非 `nil` = 用该档的状态色（"2 在跑"上琥珀）。
struct StatChip: Equatable {
    let value: String
    let label: String
    let stage: TeamStage?
}

/// 卡片底部那三格数字的**快照**（2026-11-27）。
///
/// ⚠️ 为什么必须是快照而不是 `body` 里现算: 每格都是一条聚合查询，而一张卡要三格。
/// 七张卡放进 `body` = 一次滚动求值几十次 × 七个人 —— 与本文件头那条「视图层没有门，
/// 把能断言的抽出来」同源的纪律，也是 `teamStates` 那条「界面读快照」。
/// 刷新点与 `teamStates` **同一个**（`SchedulerService.refreshTeamStates`），不另开时点。
///
/// ⚠️ **三格全部来自 db，一格都不读盘**（2026-11-27 boss：「台账计算有点麻烦，能不能换成
///    别的可以从 db 获取的指标」）。原来第三格是「台账 · 验收 7/9」，要每人读一次交接文件
///    （≤4420 字）再逐行 parse —— 那是这一页唯一碰文件系统的地方，也是"麻烦"的全部来源。
///    换成**交活**（`agent_delegations` 里 `status = 'done'` 的条数）之后:
///    三格都是"这台机器上它一共产出过多少"，语义还更齐（token / 回合 / 交活都是累计量）。
///    ⚠️ 台账本身没消失 —— 它还在**下方检查器**里（选中谁才读一次，本来就只读一次）。
struct TeamCardStat: Equatable {
    var tokens: Int = 0
    var turns: Int = 0
    /// 交过几次活 —— `agent_delegations.status = 'done'` 的条数。
    var doneDelegations: Int = 0

    static let empty = TeamCardStat()

    var tokenLabel: String { TeamBoardText.tokenLabel(tokens) }
    /// 交活数: 0 显示 `—`（与 token 同一条理由 —— 没交过就是没交过，写 `0` 会被读成"交了但记成 0"）。
    var doneLabel: String { doneDelegations > 0 ? "\(doneDelegations)" : "—" }

    // ⚠️ 曾经有过一个 `isQuiet`（三项全零）用来"待命卡省掉那一行"，2026-11-27 已删:
    //    boss 的判据是**版式不许随状态变形** —— 同一张卡今天一句话、明天三格，
    //    读的人每次都得重新认一次版式，比「— 0 —」那点噪声难受得多。
    //    所以三格**恒在**，别再为"空"加特判。
}
