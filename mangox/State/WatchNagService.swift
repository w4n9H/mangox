//
//  WatchNagService.swift
//  P19.2 S14 —— 「催」的判据（纯函数）。
//
//  催的不是 cron，是**一件已经摆在收件箱里、等人拍板的事**。
//  所以它没有自己的定时器: 挂在 `schedulerTick` 那一分钟一跳上按条件扫一遍
//  （S14 最容易漏的一条 —— 另起一条 timer 就是第二个调度器，预算闸/并发闸都会各自为政）。
//
//  上限与冷却都按**这一行 finding** 算，不按任务:
//    · 同一个任务可能同时挂着三件事，它们各自该催各自的；
//    · "同一件事"由 `fingerprint` 定（改方案不换行 ⇒ 不会靠改版刷新上限）。
//
//  ⚠️ 判据里**不许有"花不花钱"这一维**: 催不 spawn、不烧 token，只发一条触达。
//     预算闸管的是"这一轮要不要跑"，与"这件事还等着你"是两件事，混一起会让人
//     在最需要被提醒的时候收不到提醒（预算用完了 ≠ 该做的事不见了）。
//

import Foundation

enum WatchNagService {

    /// 同一件事两次催促之间的最小间隔 = **20 小时**。
    ///
    /// 为什么不是 24: 巡检按天跑，cron 那一跳会有几分钟抖动 —— 24 小时会让"今天的巡检"
    /// 刚好卡在差几十秒上，于是隔一天才催一次，而人看到的是"有时候催有时候不催"。
    /// 20 小时留出的余量足够吸收抖动，又不会在同一天里催两次。
    static let cooldown: TimeInterval = 20 * 3600

    /// 同一件事最多催几次。**到顶就闭嘴** —— 催促的价值在前几次，第四次开始只是噪音，
    /// 而噪音会让整条通道（系统通知 / 邮件 / 飞书）被一起关掉，那比不催更坏。
    static let limit = 3

    /// 这一条现在该不该催。**入参即全部输入**（冒烟直接对拍这张表）。
    ///
    /// 五个条件，缺一个都不催（每一条都对应一种"本不该打扰人"的情形）:
    ///   ① `status == .open` —— 人已经 `snooze` / 忽略 / 采纳 / 执行过的一律不催。
    ///      **这就是「snooze 能压住它」的实现**: 压住它的不是一条特殊分支，而是状态机本身。
    ///   ② 任务还在、且 `enabled` —— 停用的任务不催（人明确关掉了这条巡检线）。
    ///   ③ `isAssistant` —— 只有助理档有"等我决定"这件事；Cron 档不该走到这里。
    ///   ④ `nagCount < limit` —— 用完了就闭嘴。
    ///   ⑤ 距**上次催（没有则距提出）**满一个冷却。
    ///
    /// ⚠️ ⑤ 的锚点是 `lastNaggedAt ?? createdAt`，不是只看 `createdAt`: 一条提出三天的结论
    ///     已经催过一次的话，下一次的起点是那次催，不是三天前 —— 否则 24 小时后它每一跳都"到期"。
    static func due(_ f: AgentFinding, task: ScheduledTask, now: Date) -> Bool {
        guard f.status == .open else { return false }
        guard task.enabled, task.isAssistant else { return false }
        guard f.nagCount < limit else { return false }
        let anchor = f.lastNaggedAt ?? f.createdAt
        return now.timeIntervalSince(anchor) >= cooldown
    }
}
