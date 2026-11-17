//
//  ScheduledModels.swift
//  P3.6 本地定时任务: 到点把一条 prompt 投递给指定 project 的 Agent 会话,
//  执行过程与结果落成一个普通会话 (复用消息流渲染)。设计见 docs §3.5。
//

import Foundation

/// P19 任务类型 —— 两档 + 一个只读归档态。
/// `.execute`（Cron 定时）/ `.assistant`（助理）可新建、可保存；
/// `.legacyWaiting` 是旧「Watch 条件值守」任务的归档态：**不可新建、不可保存、不可 fire**。
/// ⚠️ 它**不落库**（`upsert` 写 NULL）：由 `condition` 非空派生 —— 条件值守的全部语义本来
/// 就藏在 `condition` 里，多存一份只会让两边有机会不一致。
enum TaskKind: String, Codable {
    case execute
    case assistant
    case legacyWaiting
}

struct ScheduledTask: Identifiable {
    let id: UUID
    var name: String
    var prompt: String
    /// 5 字段标准 cron (分 时 日 月 周), 第一版纯文本输入。
    var cron: String
    var projectId: UUID?
    var enabled: Bool = true
    var lastRunAt: Date?
    /// 单日志会话 (P3.9): 任务所有运行追加进同一个会话, 首次 fire 建立后固定。
    var logSessionId: UUID?
    /// 持续模式: 每次触发注入交接文件 (工作日志) + 近期运行摘录 (跨天任务保连续性)。
    var continuous: Bool = false
    /// P3.10 等待型: 触发条件 (非空 = 等待型任务); prompt 字段 = 触发后动作。
    var condition: String?
    /// P3.10 无人值守: fire 回合关闭审批 (全 YOLO), 默认开。
    var unattended: Bool = true
    /// P3.10 等待型: 触发执行完成的时刻 (自动停用后 UI 标"已触发")。
    var completedAt: Date?
    /// P3.10: 已执行次数 (每次 fire +1, 长程任务的进度直观量)。
    var runCount: Int = 0
    /// 列表排序依据 (新任务靠上)。
    var createdAt: Date = Date()
    /// P10.4 任务级执行配置 (nil = 跟随全局默认); fire 时只动日志会话 transport, 不碰全局。
    var config: SessionConfig? = nil
    /// P19 任务类型。**解码顺序有讲究**: 先看 `condition` 非空 ⇒ `.legacyWaiting`,
    /// 再看这里缺省 ⇒ `.execute`。顺序反了会把旧条件值守任务的「触发后动作」
    /// 当成普通 prompt 每轮无条件执行 —— 静默变意, 比崩溃更坏。
    var kind: TaskKind = .execute
    /// P19 助理的来源列表（落库 JSON）。`project` 不是一行来源 —— 见 `WatchSourceModels.swift`。
    var sources: [WatchSourceSpec] = []
    /// P19 S7: 触达配置（落库 JSON）。缺省 = 只发系统通知（与 S4 的行为逐字一致）。
    var notify: NotifyOptions = .default
    /// P19 S7: 日 token 预算。**0 = 不设限**（默认）—— 所以 Cron 档的既有任务一个字节都不变。
    ///
    /// 超预算的处理是**跳过并落痕**，不是"换个便宜模型接着跑"：降级会让人永远不知道
    /// 自己设的上限已经生效，而结论质量变了却没人知道为什么（§04）。
    var dailyTokenBudget: Int = 0

    /// 旧条件值守任务 = 只读归档: 不 fire、不保存、列表置灰。
    var isLegacyWaiting: Bool { kind == .legacyWaiting }

    var isAssistant: Bool { kind == .assistant }

    /// 助理「至少一个来源」的门槛 —— **视图与域层共用这一处**。
    ///
    /// 绑了项目就算有项目来源（分析段自己看），否则要有至少一条**可采集**的来源。
    /// ⚠️ 用 `isActive` 而不是 `enabled`: 类型不认识的旧行也算"没有"，否则一条
    /// `kind: "imap-v2"` 的残留配置就能让一个什么都不看的助理通过校验。
    var hasAnyWatchSource: Bool {
        projectId != nil || sources.contains { $0.isActive }
    }

    /// 来源实际行数（不含隐式的 project）—— 列表状态行与日志用。
    var activeSourceCount: Int {
        sources.filter { $0.isActive }.count + (projectId != nil ? 1 : 0)
    }

    /// 解析失败 = cron 非法 (UI 上标记, 调度器跳过)。
    var cronExpr: CronExpr? { CronExpr.parse(cron) }
}

// MARK: - 最小 cron 解析器 (零依赖, 只覆盖常用语法)

/// 5 字段: 分(0-59) 时(0-23) 日(1-31) 月(1-12) 周(0-6, 0=周日)。
/// 支持: `*`、`*/n` 步进、`a-b` 范围、逗号列表。不做月名/星期名/@daily 等扩展。
struct CronExpr {
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>

    static func parse(_ s: String) -> CronExpr? {
        let parts = s.split(whereSeparator: \.isWhitespace)
        guard parts.count == 5,
              let m = field(parts[0], 0...59),
              let h = field(parts[1], 0...23),
              let d = field(parts[2], 1...31),
              let mo = field(parts[3], 1...12),
              let wd = field(parts[4], 0...6) else { return nil }
        return CronExpr(minutes: m, hours: h, days: d, months: mo, weekdays: wd)
    }

    private static func field(_ str: Substring, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out: Set<Int> = []
        for part in str.split(separator: ",") {
            if part == "*" {
                out.formUnion(range)
            } else if part.hasPrefix("*/") {
                guard let step = Int(part.dropFirst(2)), step > 0 else { return nil }
                var v = range.lowerBound
                while v <= range.upperBound {
                    out.insert(v)
                    v += step
                }
            } else if let dash = part.firstIndex(of: "-") {
                guard let lo = Int(part[..<dash]),
                      let hi = Int(part[part.index(after: dash)...]),
                      lo <= hi, range.contains(lo), range.contains(hi) else { return nil }
                out.formUnion(lo...hi)
            } else {
                guard let v = Int(part), range.contains(v) else { return nil }
                out.insert(v)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Calendar.weekday: 1=周日..7=周六 → cron: 0=周日..6=周六 (即 wd - 1)。
    func matches(_ date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let mi = c.minute, let h = c.hour, let d = c.day,
              let mo = c.month, let wd = c.weekday else { return false }
        return minutes.contains(mi)
            && hours.contains(h)
            && days.contains(d)
            && months.contains(mo)
            && weekdays.contains(wd - 1)
    }

    // MARK: - 人类可读描述 (录入器预览 / 任务列表状态行共用)

    /// 形态识别出人话; 识别不出 (月/日受限等) 或非法 → 原文/标记兜底, 不硬翻。
    /// **域层 String: 字面量本身不吃本地化 → 逐处 L()** (显示在任务列表/编辑器里)。
    static func describe(_ cron: String) -> String {
        guard let e = CronExpr.parse(cron) else { return L("cron 无效") }
        guard e.months == Set(1...12), e.days == Set(1...31) else { return cron }
        let hhmm = { String(format: "%02d:%02d", $0, $1) }
        // 每天 HH:MM (日/月/星期全量, 时/分单值)
        if e.weekdays == Set(0...6), e.hours.count == 1, e.minutes.count == 1 {
            return String(format: L("每天 %@"), hhmm(e.hours.first!, e.minutes.first!))
        }
        // 每周X·Y HH:MM (星期受限, 日/月全量)
        if !e.weekdays.isEmpty, e.weekdays != Set(0...6),
           e.hours.count == 1, e.minutes.count == 1 {
            let names = e.weekdays.sorted().map { weekdayName($0) }.joined(separator: " ")
            return String(format: L("每周%@ %@"), names, hhmm(e.hours.first!, e.minutes.first!))
        }
        // 每 N 小时: 分钟={0}, 小时从 0 起等差 (*/n 或全量=每小时)
        if e.weekdays == Set(0...6), e.minutes == Set([0]), let step = stepSize(e.hours, low: 0, high: 23) {
            return step == 1 ? L("每小时") : String(format: L("每 %lld 小时"), step)
        }
        // 每 N 分钟: 小时/星期全量, 分钟从 0 起等差 (全量=每分钟)
        if e.weekdays == Set(0...6), e.hours == Set(0...23), let step = stepSize(e.minutes, low: 0, high: 59) {
            return step == 1 ? L("每分钟") : String(format: L("每 %lld 分钟"), step)
        }
        return cron
    }

    /// 单字星期名走词表 (zh: 日一二…; en: Sun Mon…), 由 `describe` 以空格连接。
    private static func weekdayName(_ cronWd: Int) -> String {
        [L("日"), L("一"), L("二"), L("三"), L("四"), L("五"), L("六")][cronWd]
    }

    /// 等差序列识别 (*/n 的 set 投影): 必须从 low 起、等差; 末段允许不满步长 (*/30 → [0,30])。
    private static func stepSize(_ set: Set<Int>, low: Int, high: Int) -> Int? {
        guard set.count > 1 else { return nil }
        let s = set.sorted()
        guard s[0] == low else { return nil }
        let d = s[1] - s[0]
        guard d > 0, low + d <= high else { return nil }
        for i in 1..<s.count where s[i] - s[i - 1] != d { return nil }
        return d
    }
}
