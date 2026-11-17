//
//  RemoteRouting.swift
//  P19.2 S15 —— 「这一条飞书消息该投给谁」的**纯判据**。
//
//  单独成纯函数的理由和 S13 的 `SaveBlocker` 一样: 一条消息有六种该被放下或放行的
//  理由，而它们**在那句检查里长得几乎一样**（都是 `return`）。散在服务里的话，
//  "群消息漏进来了" 与"重复消息投了两次" 只能靠真机复现；写成表，冒烟可以对每一格。
//
//  ⚠️ 顺序不是随便排的，它决定反例打不打得到靶子（S14 踩过：两个 guard 谁在前，
//     决定去掉后一个时红灯会不会亮）。这里的顺序按"越极端越靠前"：
//      ① 重复 → ② 不是人说的单聊文本 → ③ 没绑助理 → ④ 绑的不是助理（防御）
//      → ⑤ 助理被停用 → ⑥ 会话正忙 → ⑦ 投递
//

import Foundation

/// 一条消息的**全部输入**（都从外面算好传进来 —— 判据里不读 store、不读时钟）。
struct RemoteRouteInput: Equatable {
    let inbound: RemoteInbound
    /// `chat_id` 绑到哪个助理（`nil` = 这个单聊还没绑）。
    let boundTaskId: UUID?
    /// 那个任务是不是助理档。**防御性的一条**: 绑定时只允许绑助理，但库是随手可改的。
    let taskIsAssistant: Bool
    let taskEnabled: Bool
    /// 那场会话此刻是否已有回合在途。
    let sessionBusy: Bool
    /// 这个 `message_id` 是否已经处理过。
    let duplicate: Bool
}

enum RemoteRoute: Equatable {
    case deliver(taskId: UUID, prompt: String)
    /// 没绑助理 —— 要回一句"还没绑"，否则人以为消息发丢了。
    case unbound
    /// 绑了但助理停用了。
    case paused(taskId: UUID)
    /// 绑了但上一个回合还没跑完。**不回"排队中"**: 我们没有队列，说排队就是在骗。
    case busy(taskId: UUID)
    /// 不投、不回（重复 / 群聊 / 非文本 / 自己发的）。
    case ignore(String)

    static func decide(_ i: RemoteRouteInput) -> RemoteRoute {
        if i.duplicate { return .ignore("duplicate") }
        guard i.inbound.isDirectText else {
            // 群聊在这里被挡下（S15 只做单聊保底）。**不回复**: 群里回一句
            // "我只在单聊里工作" 是拿别人的群当自己的公告板。
            return .ignore("not-direct-text")
        }
        guard let taskId = i.boundTaskId else { return .unbound }
        guard i.taskIsAssistant else { return .ignore("bound-to-non-assistant") }
        guard i.taskEnabled else { return .paused(taskId: taskId) }
        guard !i.sessionBusy else { return .busy(taskId: taskId) }
        return .deliver(taskId: taskId,
                        prompt: i.inbound.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
