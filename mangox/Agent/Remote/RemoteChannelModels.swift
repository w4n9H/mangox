//
//  RemoteChannelModels.swift
//  P19.2 S15 —— 飞书桥的**协议面**（只有数据形状与解析，没有 IO、没有状态）。
//
//  为什么协议面单独一个文件: 桥是 node 进程，Swift 这一侧唯一能"单测"的就是
//  "这一行字节到底被读成了什么"。把它和起进程、读写管道混在一起，冒烟里就只剩
//  "进程起没起来"可断言，而真正会错的地方（content 是 JSON 字符串要二次解析、
//  create_time 是毫秒**字符串**、SDK 会往 stdout 打非协议行）全在解析里。
//
//  桥的 emit 形状（`scripts/feishu-bridge/bridge.mjs` 顶部注释是同一份契约）:
//    {"type":"status","bot":"<id>","connected":true,"note":"..."}
//    {"type":"message","bot":"<id>","chat_id":..,"chat_type":..,"message_id":..,
//     "create_time":"1794...","text":"Hi","msg_type":"text","sender_type":"user","open_id":"ou_.."}
//    {"type":"send_result","bot":"<id>","ok":true,"message_id":"om_.."}
//    {"type":"error","msg":"..."}
//
//  ⚠️ **每一帧都带 `bot`**（S15b: 一个桥进程管 N 个机器人）。不带的那一帧投不出也回不了，
//  而"哪个机器人说的"恰恰是路由的唯一键 —— 少了它，多机器人下全部消息会归到同一个助理。
//

import Foundation

// MARK: - 一帧

/// 桥 → App 的一行。
enum RemoteFrame: Equatable {
    /// `botId` 是**桥那边的机器人标识**（App 侧生成 UUID 字符串传下去）。
    case status(botId: String, connected: Bool, note: String?)
    case message(RemoteInbound)
    /// `ref` = App 发 `send` 时带下去的那个关联键，桥原样带回来（2026-11-23）。
    /// 没有它就只能知道"最近有一次发送失败了"，对不上"哪一条没发出去"。
    case sendResult(botId: String, ok: Bool, messageId: String?, msg: String?, ref: String?)
    case error(String)

    /// 解一行。**非 JSON 一律 nil**（不当作 error）—— 桥那边已经把 SDK 的
    /// `console.log` 改道到 stderr 了，但"上游哪天多打一行"不该变成一条用户可见的错误。
    static func decode(_ line: String) -> RemoteFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "status":
            return .status(botId: obj["bot"] as? String ?? "",
                           connected: obj["connected"] as? Bool ?? false,
                           note: obj["note"] as? String)
        case "message":
            guard let m = RemoteInbound(json: obj) else { return nil }
            return .message(m)
        case "send_result":
            return .sendResult(botId: obj["bot"] as? String ?? "",
                               ok: obj["ok"] as? Bool ?? false,
                               messageId: obj["message_id"] as? String,
                               msg: obj["msg"] as? String,
                               ref: obj["ref"] as? String)
        case "error":
            return .error(obj["msg"] as? String ?? "unknown")
        default:
            return nil
        }
    }
}

/// 桥推进来的一条飞书消息。
struct RemoteInbound: Equatable {
    /// 哪个机器人收到的。**路由的唯一键**（S15b）。
    let botId: String
    let chatId: String
    let chatType: String        // "p2p" / "group"
    let messageId: String
    /// `create_time` 是毫秒**字符串**（实测 `"1794898655254"`），解析不出按 0 记。
    let createTimeMillis: Int64
    let text: String
    let msgType: String         // "text" / "image" / …
    let senderType: String      // "user" / "app"
    let openId: String

    init?(json: [String: Any]) {
        guard let chatId = json["chat_id"] as? String, !chatId.isEmpty else { return nil }
        self.botId = json["bot"] as? String ?? ""
        self.chatId = chatId
        self.chatType = json["chat_type"] as? String ?? ""
        self.messageId = json["message_id"] as? String ?? ""
        self.createTimeMillis = Int64(json["create_time"] as? String ?? "") ?? 0
        self.text = json["text"] as? String ?? ""
        self.msgType = json["msg_type"] as? String ?? ""
        self.senderType = json["sender_type"] as? String ?? ""
        self.openId = json["open_id"] as? String ?? ""
    }

    /// 直接构造（冒烟用，不经 JSON 往返）。
    init(botId: String = "bot_test", chatId: String, chatType: String = "p2p", messageId: String,
         createTimeMillis: Int64 = 0, text: String, msgType: String = "text",
         senderType: String = "user", openId: String = "ou_test") {
        self.botId = botId
        self.chatId = chatId
        self.chatType = chatType
        self.messageId = messageId
        self.createTimeMillis = createTimeMillis
        self.text = text
        self.msgType = msgType
        self.senderType = senderType
        self.openId = openId
    }

    /// 「人对着助理说的一句文本」—— 只有这一种往下走。
    ///
    /// 四条都不是洁癖：群里被 @ 的是机器人，但**群里还有别人**（S15 只做单聊保底，群聊
    /// 一旦漏过去就是把助理的话广播给一屋子人）；`sender_type == "app"` 是我们自己发的
    /// 回声（实测飞书**不会**推自己的消息，但把这条判据留着，是为了上游换了实现时不会静默成环）；
    /// 空文本是图片/表情包。
    var isDirectText: Bool {
        chatType == "p2p" && msgType == "text" && senderType == "user"
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var createTime: Date? {
        createTimeMillis > 0 ? Date(timeIntervalSince1970: Double(createTimeMillis) / 1000) : nil
    }
}

// MARK: - 出去的话

enum RemoteReply {
    /// 单条文本的上限。飞书本身能收很长，但一条 8000 字的聊天消息没人读得完，
    /// 而且它会把"这条通道还活着"的信号埋掉。超了截断并在末尾指路 App。
    static let maxChars = 3000

    /// 把回合正文变成能发出去的一段话 —— **去掉提议块**。
    ///
    /// 为什么必须去: 提议块（`【提议】…`）是给机器解析的契约，人看到的是
    /// "标题/理由/方案/风险"四个字段名。它在收件箱里已经被渲染成一张卡了，
    /// 原样丢进飞书等于让人在两个地方读同一件事，而其中一处是原始格式。
    static func compose(_ raw: String) -> String {
        // ⚠️ 用 `splitProposalBlock` 而不是"拿去原文里替换": 块回来时已经被归一化过
        // （块头那几个字被摘掉、首尾空白被 trim）⇒ **不是原文的子串**，替换等于没做，
        // 而且零信号（这条通道的实测就是这么发现飞书那边收到「【提议】结论：…」的）。
        var body = WatchFindingService.splitProposalBlock(in: raw).body
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            // 一整个回合只有一条提议 —— 不能什么都不发（人那边看到的是"它没理我"）。
            return L("（这一轮只有一条提议，已进 MangoX 的收件箱）")
        }
        if body.count > maxChars {
            let head = String(body.prefix(maxChars))
            return head + "\n\n" + L("（太长，已截断 —— 全文在 MangoX 里）")
        }
        return body
    }
}
