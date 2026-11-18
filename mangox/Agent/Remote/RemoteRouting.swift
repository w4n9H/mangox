//
//  RemoteRouting.swift
//  P19.2 S15 —— 「这一条飞书消息该投给谁」的**纯判据**。
//
//  单独成纯函数的理由和 S13 的 `SaveBlocker` 一样: 一条消息有多种该被放下或放行的
//  理由，而它们**在那句检查里长得几乎一样**（都是 `return`）。散在服务里的话，
//  "群消息漏进来了" 与"重复消息投了两次" 只能靠真机复现；写成表，冒烟可以对每一格。
//
//  ⚠️ 顺序不是随便排的，它决定反例打不打得到靶子（S14 踩过：两个 guard 谁在前，
//     决定去掉后一个时红灯会不会亮）。这里的顺序按"越极端越靠前"：
//      ① 重复 → ② 不是人说的单聊文本 → ③ 机器人不在表里（防御）
//      → ④ 没归助理 → ⑤ 归的不是助理（防御）→ ⑥ 助理被停用
//      → ⑦ **审批指令**（同意 / 先别动）→ ⑧ 会话正忙 → ⑨ 投递
//
//  ⚠️ ⑦ 为什么排在"会话正忙"**前面**（2026-11-18）：人不在电脑前，回一句「同意」时
//     可能正好有个回合在跑。这时正确的回答是"没执行起来（回合还在跑）"，
//     而不是"上一个回合还在跑，等它结束再发" —— 后者会让他以为**同意本身没被收到**。
//
//  ⚠️ 2026-11-18 删掉「机器人被关掉」那一格：机器人**没有自己的开关**了（boss: 只留助理的开关）。
//     原来那一格是"刚关、桥还没重起"的防御，现在"关"就是"助理关着"⇒ 落到 ⑥，
//     而 ⑥ 本身也已经基本不可达（助理关着 ⇒ 它的机器人不连 ⇒ 收不到）——
//     留它是为重启失败那一小段窗口（旧桥还在跑），不是为了正常路径。
//
//  S15b 之后"绑定"的键是 **`bot_id`**，不是 `chat_id` —— `chat_id` 是运行时地址，
//  只用来把回复送回去（见 `RemoteChannelService.finishRemoteTurn`）。
//

import Foundation

/// 一条消息的**全部输入**（都从外面算好传进来 —— 判据里不读 store、不读时钟）。
struct RemoteRouteInput: Equatable {
    let inbound: RemoteInbound
    /// 这个机器人**在不在我们的表里**（`remote_bots`）。不在 = 桥跑着一个已经被删掉的机器人。
    let botKnown: Bool
    /// 机器人归哪个助理（`RemoteBot.assistantId`）。`nil` = 还没归给谁。
    let boundTaskId: UUID?
    /// 那个任务是不是助理档。**防御性的一条**: 归的时候只允许归助理，但库是随手可改的。
    let taskIsAssistant: Bool
    let taskEnabled: Bool
    /// 那场会话此刻是否已有回合在途。
    let sessionBusy: Bool
    /// 这个 `message_id` 是否已经处理过。
    let duplicate: Bool
    /// 这个助理名下**最近一条还开着的结论**（人回「同意」时指的就是它）。
    ///
    /// 为什么按"最近一条"而不是让他带上编号：推送是**一次一条**的（`pushFinding` 只发第一条），
    /// 所以"我刚收到的那条"是唯一不会认错的对象。要编号就得让人抄 token，那比多点一次还烦。
    let pendingFinding: UUID?
    /// 那条结论**有没有方案** —— 没有方案就没有"执行"这回事（只有"搁置"）。
    let pendingHasPlan: Bool
}

/// 飞书里的**审批指令**（纯数据，判据直接打在这里）。
///
/// 为什么只认**整句精确匹配**：人聊天时天天说「可以」「行」「好」，contains 判据会把
/// 一句「可以，但先别删那个文件」当成批准。整句匹配的代价是他必须单独发两个字，
/// 而推送文案里已经把这两个字写给他了（`pushFinding` 的尾巴）—— 这比误批一次便宜得多。
enum RemoteCommand: Equatable {
    case approve
    case dismiss

    /// 批准。**刻意不含「可以」**：那一句在聊天里太常见，且它不等于"按这份方案去做"。
    static let approveWords: Set<String> = ["同意", "批准", "执行", "采纳", "ok", "yes", "approve"]
    /// 搁置。
    static let dismissWords: Set<String> = ["先别动", "忽略", "搁置", "不批准", "算了", "no", "dismiss"]

    static func parse(_ text: String) -> RemoteCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if approveWords.contains(t) { return .approve }
        if dismissWords.contains(t) { return .dismiss }
        return nil
    }
}

enum RemoteRoute: Equatable {
    case deliver(taskId: UUID, prompt: String)
    /// 机器人还没归给助理 —— 要回一句，否则人以为消息发丢了。
    case unbound
    /// 归了但助理停用了。**现在只在"桥还没重起完"那一小段窗口里可达**（见文件头）。
    case paused(taskId: UUID)
    /// 归了但上一个回合还没跑完。**不回"排队中"**: 我们没有队列，说排队就是在骗。
    case busy(taskId: UUID)
    /// 不投、不回（重复 / 群聊 / 非文本 / 自己发的 / 机器人不在表里）。
    case ignore(String)
    /// 人要批的那件事：**在飞书上直接批，不必回 App**（2026-11-18 boss 定）。
    case approve(taskId: UUID, findingId: UUID)
    /// 人把这件事搁置（同一条结论，状态翻成"已忽略"）。
    case dismiss(taskId: UUID, findingId: UUID)
    /// 他想批，但现在没有等着批的事。
    case noPending
    /// 他想批的那条**没有方案**（那是一条提问 / 通报）—— 执行不了，得说清楚。
    case noPlan

    static func decide(_ i: RemoteRouteInput) -> RemoteRoute {
        if i.duplicate { return .ignore("duplicate") }
        guard i.inbound.isDirectText else {
            // 群聊在这里被挡下（S15 只做单聊保底）。**不回复**: 群里回一句
            // "我只在单聊里工作" 是拿别人的群当自己的公告板。
            return .ignore("not-direct-text")
        }
        guard i.botKnown else { return .ignore("unknown-bot") }
        guard let taskId = i.boundTaskId else { return .unbound }
        guard i.taskIsAssistant else { return .ignore("bound-to-non-assistant") }
        guard i.taskEnabled else { return .paused(taskId: taskId) }
        // ⚠️ 指令识别放在**忙碌之前**：他回「同意」时如果恰好有个回合在跑，正确的回答是
        // "执行没起来（回合还在跑）"，而不是"上一个回合还在跑，等它结束再发" —— 后者
        // 会让他以为**同意这件事本身**没被收到。
        if let cmd = RemoteCommand.parse(i.inbound.text) {
            guard let fid = i.pendingFinding else { return .noPending }
            switch cmd {
            case .approve:
                guard i.pendingHasPlan else { return .noPlan }
                return .approve(taskId: taskId, findingId: fid)
            case .dismiss:
                return .dismiss(taskId: taskId, findingId: fid)
            }
        }
        guard !i.sessionBusy else { return .busy(taskId: taskId) }
        return .deliver(taskId: taskId,
                        prompt: i.inbound.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
