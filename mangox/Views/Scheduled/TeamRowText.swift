//
//  TeamRowText.swift
//  P20 P4 定时任务列表行的措辞（2026-11-24）。
//
//  设计来源: `docs/P20-functional-design.html` §03「定时任务 · 建与改」的列表样张。
//

import Foundation

/// 团队相关的**界面措辞** —— 与注入面那份恒中文的（`TeamPrompt.stateWord`）刻意分成两份。
///
/// 为什么必须是两份: 注入面的字节不许随界面语言漂（模型认的就是那些字），而界面必须跟着
/// 语言走。为什么判据只许一份: `TeamState.of` / `TeamRule` 是唯一判据口，这里只管措辞 ——
/// 于是"界面说在跑、注入段说空闲"这种分叉从结构上不会发生（它会让 main 把活派给一个正在
/// 干活的人，那一单会被硬拒，白烧一轮）。
///
/// 全是纯函数（不碰库、不读时钟，`now` 由调用方给）⇒ 冒烟可以直接喂数据断言。
/// 视图层没有门，能断言的只有被抽出来的纯函数 —— 与 `SchedulerService.rowMarker` 同款。
enum TeamRowText {

    // MARK: - 身份

    /// 列表行 / 泳道卡上的**角色短标记**。
    ///
    /// 2026-11-25 boss 定: `助理（管理）` / `助理（执行）` 是完整名字（新建菜单与身份胶囊用），
    /// 这一行只有 240pt，取短形式 `管理` / `执行`。
    ///
    /// ⚠️ 这里推翻过 P4 的判据（那版是 `main` / `worker`、`Text(verbatim:)`、不进词表）。
    /// 推翻的理由不是"中文更好看": 菜单里三档并列时 `worker · 只被派活叫起来` 和
    /// `助理（目标式）` 不是一个维度，而列表又写着 `main` —— 同一个东西三处三个名字。
    /// **存储与域层仍是 `main` / `worker`**（那是协议，改了会让旧库读不出来）。
    ///
    /// `cron` 不是角色而是**档**: Cron 任务没有队伍, 把它写成「管理」会让人以为它手底下有人。
    static func roleToken(kind: TaskKind, role: TaskRole) -> String {
        if kind != .assistant { return "cron" }
        return role == .worker ? L("执行") : L("管理")
    }

    /// 这一行是不是**队伍队长**（列表上那条 3px 竖条 + 名字加粗的唯一判据）。
    ///
    /// ⚠️ 判据是 `role == .main && 助理档`，**不是** `role == .main` 一条: Cron 任务在存储上
    /// 也是 main（`TaskRole` 缺省就是 main），但它在队伍系统外面 —— 给它竖条等于把"这里有个
    /// 队长"说给每一条 Cron 任务听，而竖条一旦到处都是就什么也不表示。
    static func isTeamLead(_ t: ScheduledTask) -> Bool {
        t.role == .main && t.isAssistant && !t.isLegacyWaiting
    }

    /// L2 · 身份行 —— 「谁 · 多久一次 · 手底下几个人 / 归谁」。
    ///
    /// ⚠️ 文档 §03 那句「类型与周期移到右侧同一列」在 240pt 的侧栏里落成了**名字下一行的一条**:
    /// 真排成第二列时 `管理 · 每天 09:00 · 4 个助理`（约 120pt）会把名字挤成两行 ——
    /// 而文档自己反对的正是"名字 + 归属两行都折行"（那句本来是说团队页的列宽）。
    ///
    /// ⚠️ **worker 不写周期**: 它在 `schedulerTick` / `漏跑` / `补跑` 三处都被排除了,
    /// cron 那一列对它是**占位值**。写出来就是承诺一件永远不会发生的事。
    ///
    /// ⚠️ 队伍人数与来源数**二选一**（同一格，L2 只有一行宽）: 有队伍就报人数（那是新信息），
    /// 没有队伍照旧报来源数 —— 不这样，P20 之前建的每一个助理都会从「3 个来源」变成
    /// 「还没有 worker」，而那件事它根本没在参与。
    static func identityLine(_ t: ScheduledTask, workers: Int, parentName: String?) -> String {
        // 旧类型是只读归档: 它的 cron 不再生效，写出周期等于承诺一件不会发生的事。
        if t.isLegacyWaiting { return L("旧类型 · 已停用（不再值守）") }
        // 识别不出的 cron 是**要修的错误**，不是身份 —— 身份行只写这一件事（行本身会染红）。
        if t.cronExpr == nil { return L("cron 无效") }
        var parts = [roleToken(kind: t.kind, role: t.role)]
        if t.role == .main { parts.append(CronExpr.describe(t.cron)) }
        switch t.role {
        case .worker:
            // 「归谁」永远是**名字**。悬挂值（main 被删了）说「未归属」——
            // 留空会让这一行读成"这个人没有队伍这个概念"，而它其实是一支残队的人。
            parts.append(parentName.map { String(format: L("归 %@"), $0) } ?? L("未归属"))
        case .main:
            if t.isAssistant {
                if workers > 0 {
                    // 「N 个助理」不是笔误: 这一行是**管理助理**的身份行，"4 个助理"= 它带的 4 个。
                    // 写成「4 个执行」在中文里不成立（执行是动词），而「4 个下属」又引入了第五个词。
                    parts.append(String(format: L("%lld 个助理"), workers))
                } else if t.activeSourceCount > 0 {
                    parts.append(String(format: L("%lld 个来源"), t.activeSourceCount))
                }
            } else if t.continuous {
                parts.append(L("留痕"))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 状态

    /// 五档状态的**界面版**措辞。判据在 `TeamState.of`，这里只管词。
    ///
    /// `.awaiting`（等回执）在**注入面**被折叠成"空闲"（见 `TeamPrompt.stateWord`），
    /// 界面上却必须说出来: 那是"有一张单等我处理"，人不该靠翻回执才知道。
    static func stateWord(_ s: TeamState, now: Date) -> String {
        switch s {
        case .disabled:
            return L("已停用")
        case .running(let since):
            let minutes = since.map { max(1, Int(now.timeIntervalSince($0) / 60)) } ?? 1
            return String(format: L("在跑 %lld 分钟"), minutes)
        case .queued(let at):
            return String(format: L("已排上 %@"), DelegationRefusal.hhmm(at))
        case .awaiting(let since):
            return String(format: L("等回执 %lld 分钟"),
                          max(1, Int(now.timeIntervalSince(since) / 60)))
        case .idle(let last):
            // 一天以内说"空闲 0 天"是噪音 —— 那个数字的用途是"三天没派过活的人该被我看见"。
            guard let last, now.timeIntervalSince(last) >= 86_400 else { return L("空闲") }
            return String(format: L("空闲 %lld 天"), Int(now.timeIntervalSince(last) / 86_400))
        }
    }

    /// L3 · 现场行 —— 「现在什么状态 · 约了什么时候回看 · 跑过几次 · 哪个项目」。
    ///
    /// 空串 = 这一行不画（legacy 归档行只有"它不跑了"这一件事，L2 已经说了）。
    ///
    /// ⚠️ 五档只画给**助理档**。Cron 任务没有队伍那五档（它不会"被派活"，也不会"等回执"），
    /// 给它写「空闲 3 天」会读成"这个定时任务闲置了三天"，而它其实天天在跑。
    static func stateLine(_ t: ScheduledTask, state: TeamState, followUp: Date?,
                          project: String?, now: Date) -> String {
        if t.isLegacyWaiting { return project ?? "" }
        var parts: [String] = []
        if !t.enabled {
            parts.append(L("已停用"))
        } else if t.isAssistant {
            parts.append(stateWord(state, now: now))
        }
        // 2026-11-23 那条约定（它自己约的回看）。放在"跑过几次"**之前** ——
        // "14:30 还会回来"比"已跑 12 次"更影响人此刻的判断。
        if let followUp { parts.append(String(format: L("约了 %@ 回看"), followUpTag(followUp, now: now))) }
        if t.runCount > 0 {
            parts.append(String(format: L("已跑 %lld 次"), t.runCount))
        } else if let last = t.lastRunAt {
            parts.append(String(format: L("上次 %@"), last.relativeTag))
        } else if parts.isEmpty {
            parts.append(L("待运行"))
        }
        if let project { parts.append(project) }
        return parts.joined(separator: " · ")
    }

    /// 回看时刻的人话: 今天只写 `14:30`，明天加「明天」，再远给 `11/26 09:00`。
    /// **不写整日期**的理由同列表那一行: 一个 `2026-11-26 09:00` 会把整条挤成换行。
    static func followUpTag(_ date: Date, now: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = .current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if cal.isDate(date, inSameDayAs: now) { return f.string(from: date) }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) {
            return L("明天") + " " + f.string(from: date)
        }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }

    // MARK: - 行的相对顺序（2026-11-25）

    /// 列表的**行序**: 队长在前、它的人紧跟在它下面；其余行原地不动。
    ///
    /// boss 实机: 「助理 Main」被自己的两个 worker 压在下面。根因是源顺序 ——
    /// `PersistenceStore.loadScheduled` 是 `ORDER BY created_at DESC`（新的在上，这一列
    /// 二十多条都靠它），而 **worker 一定比它的队长晚建** ⇒ 它必然排在队长上面。
    ///
    /// 为什么这不是"换个排序"，而是**只挪 worker 一种行**:
    ///   · 主干（助理队长 / cron / 没有活的 worker）保持**原相对顺序** —— 整列换个口径重排，
    ///     所有行都会跳位置，而这页唯一的导航锚就是"那一行在哪"。
    ///   · **孤儿原地不动**（`parentId` 指向一个已经不在列表里的队长）: 它没有可跟的人，
    ///     挪到任何地方都是替它编一个归属出来。它的行上写着「未归属」，位置要跟那句话一致。
    ///   · `↳` 这个记号本身就在说"我属于上面那个人" —— 队长在它下面时，那个箭头指向的是
    ///     **上一个队的最后一行**，读起来是"它归那个人"，比不缩进更错。
    ///
    /// 判据（冒烟 T-TEAM ㊵）: 输出恒是输入的一个**排列**（id 多重集相等 —— 不丢不增），
    /// 队长在它的人之前，孤儿的相对位置不变。
    static func listOrder(_ tasks: [ScheduledTask]) -> [ScheduledTask] {
        listGroups(tasks).flatMap { $0 }
    }

    /// 同一个行序，但**按组分**（每组 = 一个队长 + 它的人；其余行各成一组）。
    ///
    /// 视图必须拿到组、而不能只拿到一列平铺的行 —— 因为**分组不画边界就等于瞎认亲**:
    /// 排完之后「客户回访」的两个人下面紧跟着一条 cron，中间什么记号都没有，看起来就是
    /// 这支队的第三个人（boss 2026-11-25 的原话:「一个 cron 为什么会在客户回访的 team 里面」）。
    /// 组边界就是那条 3px 竖条: 它从队长那一行**连到最后一个队员**，队外那一行自然在竖条外面。
    ///
    /// ⚠️ 这条竖条的含义因此变了: 原来是"我是队长"（只画在自己那一行），现在是
    /// "这一片是这支队伍"。谁是队长仍由**名字加粗 + `管理`** 说，竖条不再承担那件事。
    static func listGroups(_ tasks: [ScheduledTask]) -> [[ScheduledTask]] {
        let leads = Set(tasks.filter { isTeamLead($0) }.map(\.id))
        // 只有"**队还在**的执行助理"才跟着队长走；悬挂的 `parentId` 与空 `parentId` 都返回 nil。
        func leadOf(_ t: ScheduledTask) -> UUID? {
            guard t.role == .worker, let pid = t.parentId, leads.contains(pid) else { return nil }
            return pid
        }
        var children: [UUID: [ScheduledTask]] = [:]
        for t in tasks {
            guard let pid = leadOf(t) else { continue }
            children[pid, default: []].append(t)
        }
        var out: [[ScheduledTask]] = []
        for t in tasks {
            guard leadOf(t) == nil else { continue }   // 它已经挪到队长下面去了
            out.append([t] + (children[t.id] ?? []))
        }
        return out
    }
}
