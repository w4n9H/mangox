//
//  SentMessage.swift
//  「已发消息」记忆（2026-11-23 boss 定）：助理往外发过的每一句，都要留一笔。
//
//  为什么要有它：外发是**唯一一条出去就再也看不见的路**。飞书那边发了什么、什么时候发的、
//  属于哪个任务 —— 发完就只剩一行日志（`feishu-send-result ok`），正文、归属全没有。
//  于是每小时巡检的那一轮**不知道自己上一轮说过什么**：要么重复说同一件事，要么接不上
//  "我昨天跟你说过 X"。
//
//  三条边界（都对应一种会撒谎的写法）:
//   ① **只记模型说的话**。`RemoteChannelService.notice*` 那一族是 **App 的话术**
//      （"上一个回合还在跑" / "已搁置" / "有文件没能发出去"）—— 记进来就会在注入段里
//      冒充"它自己说过的"，与刚修的 `other` 同一类错：标记比事实说得多。
//      ⇒ 所以这张表**没有 `origin` 列**：既然一个来源都不记，留一列恒为常量的字段只是噪音。
//   ② **只记"发出去"这件事，不记"打算发"**。`status` 三态：`queued`（交给桥了，还没回执）/
//      `sent` / `failed`。注入段只取 `sent` —— 模型只该以为真的到达了。
//   ③ **不记系统通知**（boss 明确排除）：macOS 通知不是"消息"，它没有正文、没有落点，
//      记进来只会让注入段出现一堆"通知过一件事"的空行。
//

import Foundation

/// 这条是怎么出去的。三值，不是一个布尔 —— UI 与注入段靠它区分"它主动找你"与"它在答你"。
enum SentKind: String, Codable, CaseIterable {
    /// 回答人的一句话（飞书私聊那一轮 / 执行收尾那句话）。
    case reply
    /// 主动推给人的结论（`pushFinding`，人没在跟它说话）。
    case push
    /// 一个文件（`feishu_attach` 排的队，落点是飞书私聊）。
    case file

    /// 注入段与界面共用的一份说法。**恒中文**（注入面不进词表，同 `[笔记]` 那一族）。
    var tag: String {
        switch self {
        case .reply: return "回复"
        case .push: return "结论"
        case .file: return "文件"
        }
    }
}

/// `queued` 是**真实存在的一档**，不是过渡态：桥是另一个进程，回执可能永远不来（它崩了）。
/// 那时这条记录停在 `queued` 是诚实的 —— "我们不知道发没发出去"，而不是"发了"或"没发"。
enum SentStatus: String, Codable {
    case queued, sent, failed

    static func decode(_ raw: String) -> SentStatus? { SentStatus(rawValue: raw) }

    var isVisible: Bool { self != .queued }
}

struct SentMessage: Identifiable, Equatable {
    /// 同时是**回执关联键**（发给桥的 `ref`）。桥回 `send_result` 时原样带回来 ⇒
    /// "这一条到底发没发出去"能对上具体那一条，而不是"最近有一次发送失败了"。
    let id: UUID
    let taskId: UUID
    let sessionId: UUID?
    let at: Date
    let kind: SentKind
    var status: SentStatus
    /// 真正发出去的正文。文件那条 = 文件名（正文是空的，标题就是它）。
    let text: String
    /// 失败原因（桥那一侧的原话）。`nil` = 没失败，或者还没回执。
    var note: String?

    init(id: UUID = UUID(), taskId: UUID, sessionId: UUID?, at: Date = Date(),
         kind: SentKind, status: SentStatus = .queued, text: String, note: String? = nil) {
        self.id = id
        self.taskId = taskId
        self.sessionId = sessionId
        self.at = at
        self.kind = kind
        self.status = status
        self.text = text
        self.note = note
    }
}

enum SentLimit {
    /// 单条上限（字符）。飞书单条消息本身很长，但这里存的是"记忆"，不是归档。
    static let maxTextChars = 4000
    /// 每个任务留多少条（超了从最旧的删）。200 条够撑几个月，也不至于让表无限长。
    static let keepPerTask = 200
    /// 注入段取几条。
    static let injectCount = 5
    /// 注入段每条截多少字。⚠️ 它要压得住上下文：5 × 120 已经是一屏的量。
    static let injectChars = 120
    /// 编辑器那张卡预览几条。
    static let previewCount = 5
}
