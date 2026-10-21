//
//  SideChatTurn.swift
//  P6.3.3 侧问选点 —— `由此侧问` 的二次确认弹窗（2026-10-21 boss 定）
//

import Foundation

/// 侧问可以选的**一个起点** = 一轮用户提问。
///
/// 粒度只有"轮"没有"条": fork 走的是 `--fork <jsonl 快照>`, 而快照只能取**前缀**
/// （`ChatStore.snapshotLinePrefix` 的语义）。切在助手消息或工具卡中间会留下
/// "没有结果的工具调用"、取区间则第一条就指着一个不存在的父节点 ⇒ 越界的点最终都得
/// 吸附回回合边界。与其在 UI 上假装能选任意位置, 不如把点说成回合。
struct SideChatTurn: Identifiable, Equatable {
    /// **1 起**的轮号, 与 `ChatStore.snapshotLinePrefix(turns:)` 的 `turns` **同一套编号**
    /// （那边数的是 jsonl 里 `role=user` 的行, 这边数的是 `role == .user` 的消息）。
    /// ⚠️ 两边必须同源: 轮号对不上时截出来的东西**不是报错, 而是"少了几轮"** —— 零红灯。
    let index: Int
    /// 该轮那条用户消息的 id（列表项的身份; 也是"这一轮"在会话里的锚）
    let messageId: UUID
    /// 首行正文, 已截断（`SideChatTurns.titleLimit`）。空串 = 这条消息没有文字（只有图片）
    let title: String
    let at: Date

    var id: UUID { messageId }
}

/// 把会话消息折成"可选的轮次" —— 纯函数, 冒烟直接喂数据就能造反例。
///
/// **为什么不用新表 / 不存库**: 轮次是 `replayMessages` 的一眼投影, 存下来就成了第二真源
/// （会话继续往后跑, 表里的轮数立刻过期, 且过期时零红灯）。
enum SideChatTurns {
    /// 首句截断长度。**按字符不按词**: 中文没有词边界, 按词切会在英文里切出半个单词。
    static let titleLimit = 60

    /// **倒序**返回（最新在前）。
    ///
    /// 为什么倒序: 起侧问的场景几乎都是"从最近某处岔开", 而轮号越大越靠上 ⇒ 打开就能选,
    /// 不必先滚到底。整场那一项由弹窗自己钉在最上面（它是 `upTo: nil`, 不属于轮次）。
    static func build(from messages: [ChatMessage]) -> [SideChatTurn] {
        var out: [SideChatTurn] = []
        var n = 0
        // 只认 `.user`: 工具卡与助手消息**不许**变成一轮 —— 它们夹在所属回合里, 跟着那一轮走。
        // 这条与 `snapshotLinePrefix` 的判据是同一个（那边看 jsonl 的 `message.role == "user"`）。
        for m in messages where m.role == .user {
            n += 1
            out.append(SideChatTurn(index: n, messageId: m.id, title: title(of: m), at: m.timestamp))
        }
        return out.reversed()
    }

    /// 首行正文。`think` / `tool` 内容一律当"没有文字"处理 —— 用户消息不该有这两类,
    /// 真有的话也不是"他要问的话"。
    static func title(of m: ChatMessage) -> String {
        guard case .text(let s) = m.content else { return "" }
        let line = s
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > titleLimit ? String(trimmed.prefix(titleLimit)) + "…" : trimmed
    }

    /// 选中的轮号 → `startSideChat(upTo:)` 的参数。`nil` = 整场。
    ///
    /// **选到最新那一轮就合并成整场**: 内容完全等价（`snapshotLinePrefix` 在 turns ≥ 源轮数时
    /// 返回整文件）, 但那条路要多建一份临时快照、首回合 send 之后再删掉 —— 白拷一次文件。
    /// 这条规则放在这里而不是视图里: 视图层**只编译不执行**, 冒烟抓不到"合并没合并"。
    static func upTo(picked: Int?, newest: Int?) -> Int? {
        guard let picked, let newest, picked < newest else { return nil }
        return picked
    }
}
