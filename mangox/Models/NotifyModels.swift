//
//  NotifyModels.swift
//  P19 S7: 触达（怎么叫人）与来源（看什么）解耦后的那一半。
//
//  ⚠️ 这里的每个字段都以**同一条红线**为前提（§04 脱敏）：外发物只有标题与任务名，
//     正文与证据留在 App 内。通知栏是锁屏也看得见的地方，飞书私聊是离开这台机器的地方。
//
//  ⚠️ 2026-11-17 删掉 `webhook`（群机器人）。群不做了，而 webhook 只能发到群 ——
//     结论改推**入口机器人的私聊**（`RemoteChannelService.pushFinding`）。
//     旧库里的 `"webhook":true` 不会被解出来（未知键忽略），也不需要迁移：
//     它本来就只有他一个人配过、而且当时就是关着的。
//

import Foundation

/// 一条助理任务的触达配置（落库 JSON，列 `notify`）。
struct NotifyOptions: Codable, Equatable {
    /// 系统通知。**默认开**（§03 拍板）：助理的全部价值是「有事找你」，默认静音等于默认不工作。
    /// 全局开关 `completionNotificationsEnabled` 仍是上位闸 —— 它关着就一个都不发。
    var system: Bool = true
    /// 邮件收件人。**2026-11-18 晚起没有配置入口了**（「触达」卡整张删掉，邮件外发通道一并删除）:
    /// 字段留着是为了**旧行上的值原样读得回来**（"撤下输入框 ≠ 清空数据"），而不是因为它还在用。
    /// 真要靠邮件外发，先想清楚"人看不见它在发信"这件事怎么办。
    var emailTo: String? = nil

    static let `default` = NotifyOptions()
}

/// 外发载荷 = **脱敏后的最小事实**。
///
/// 系统通知与飞书私聊共用它 —— 不是省事，是"脱敏只写一遍"：
/// 两处各自拼一次正文，就有两次机会把 `finding.body` 或 `evidence` 拼进去。
struct NotifyPayload: Equatable {
    let findingId: UUID
    let taskName: String
    let title: String
    /// 这条**有没有可执行的方案**。决定推送尾巴说「回同意我就去做」还是「这条不用批」——
    /// 说错一边的代价都不小：说错成"能批"，人回「同意」会收到"这条没方案"；
    /// 说错成"不用批"，那条需要动手的事就永远没人做（2026-11-18）。
    let actionable: Bool

    /// 一行式描述（飞书私聊正文的开头）。
    var line: String { taskName + " · " + title }
}

/// 一个外发通道的投递结果。**每一种都要有话说** —— 静默失败会让"没收到"与"没发"长得一样。
enum NotifyOutcome: Equatable {
    case sent(String)
    case skipped(String)
    case failed(String)

    var text: String {
        switch self {
        case .sent(let s): return s
        case .skipped(let s): return s
        case .failed(let s): return s
        }
    }

}
