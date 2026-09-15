//
//  DayBucket.swift
//  P8.0: 侧栏会话列表的 今天/昨天/本周/更早 分桶 (纯函数)。
//

import Foundation

enum DayBucket: String, CaseIterable {
    case today = "今天"
    case yesterday = "昨天"
    case thisWeek = "本周"
    case earlier = "更早"

    /// 按 updatedAt 分桶 (纯函数, 冒烟直接断言)。
    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> DayBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yest = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yest) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        return .earlier
    }
}
