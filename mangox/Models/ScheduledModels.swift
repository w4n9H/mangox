//
//  ScheduledModels.swift
//  P3.6 本地定时任务: 到点把一条 prompt 投递给指定 project 的 Agent 会话,
//  执行过程与结果落成一个普通会话 (复用消息流渲染)。设计见 docs §3.5。
//

import Foundation

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
}
