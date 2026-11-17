//
//  NotifyModels.swift
//  P19 S7: 触达（怎么叫人）与来源（看什么）解耦后的那一半。
//
//  ⚠️ 这里的每个字段都以**同一条红线**为前提（§04 脱敏）：外发物只有标题与任务名，
//     正文与证据留在 App 内。通知栏是锁屏也看得见的地方，webhook 是离开这台机器的地方。
//

import Foundation

/// 一条助理任务的触达配置（落库 JSON，列 `notify`）。
struct NotifyOptions: Codable, Equatable {
    /// 系统通知。**默认开**（§03 拍板）：助理的全部价值是「有事找你」，默认静音等于默认不工作。
    /// 全局开关 `completionNotificationsEnabled` 仍是上位闸 —— 它关着就一个都不发。
    var system: Bool = true
    /// 邮件收件人。空 = 不发邮件。发件账号是「设置 → 集成 → 邮箱账号」里**第一个可发**的账号
    /// （有 SMTP 主机且 Keychain 里有授权码）—— 不让人在每条任务上再选一次发件人。
    var emailTo: String? = nil
    /// 飞书自定义机器人。**URL 住 Keychain**（`com.mangox.notify`），这里只记"配过没"。
    ///
    /// 为什么库里只存一个 Bool：那条 URL 的路径段**本身就是凭据**（谁拿到谁能以这个机器人发言）。
    /// 落一份到库里，它就同时进了备份包、诊断日志和任何一次 `sqlite3` 导出 —— 而这三处
    /// 都不是凭据该去的地方。库里这份的语义只是"曾经配过"，真正的真源在钥匙串。
    var webhook: Bool = false

    static let `default` = NotifyOptions()

    /// 归一后的收件人（全空白 = 没填）。
    var emailAddress: String? {
        guard let s = emailTo?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    var isAllOff: Bool { !system && emailAddress == nil && !webhook }
}

/// 外发载荷 = **脱敏后的最小事实**。
///
/// 三个 sink（系统通知 / 邮件 / 飞书）共用它 —— 不是省事，是"脱敏只写一遍"：
/// 三个各自拼一次正文，就有三次机会把 `finding.body` 或 `evidence` 拼进去。
struct NotifyPayload: Equatable {
    let findingId: UUID
    let taskName: String
    let title: String

    /// 一行式描述（邮件主题与飞书正文共用）。
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

    var isFailed: Bool { if case .failed = self { return true }; return false }
}
