//
//  TimelineJournal.swift
//  MangoX
//
//  P18（2026-10-22 boss 拍板）：时间线的**记账器** —— 唯一负责"什么时候往流水里写一行"的地方。
//
//  它只做三件事：算归属根、数出这一场会话的客观状态、把那一行交给
//  `KnowledgeStore.appendTimeline`（写盘的边界校验住在那一边，这里不重复）。
//
//  ⚠️ 为什么不是 dream 的活：dream 是模型，模型写的东西必须人审（P15 门 2）。
//  而流水记的是「几点 · 哪一场 · 几轮 · 几次失败」这种 App 自己就看得见的事实 ——
//  让模型去生成它，只会多一层幻觉风险 + 一个收件箱。
//
import Foundation

@MainActor
enum TimelineJournal {

    /// 一场会话的客观状态。
    struct Stats: Equatable {
        /// 用户说了几轮（= 会话里 user 文本消息的条数）。**不是** assistant 条数 ——
        /// 一次提问可能产出多段回复（思考 / 工具 / 正文），那三个数字都不是"轮"。
        let turns: Int
        /// 工具相位是 `.error` 的次数。它是"试错的痕迹"里**唯一客观**的那一半。
        let failures: Int
    }

    // MARK: - 纯函数（可造反例）

    /// 从重放出来的消息里数轮次与失败次数。
    ///
    /// 纯函数（只吃 `[ChatMessage]`）⇒ 冒烟能直接喂一串夹具消息断言，
    /// 不需要真跑一场对话。
    static func stats(_ messages: [ChatMessage]) -> Stats {
        var turns = 0
        var failures = 0
        for m in messages {
            switch m.content {
            case .text:
                if m.role == .user { turns += 1 }
            case .tool(let t):
                if case .error = t.phase { failures += 1 }
            case .think, .plan, .compaction:
                break
            }
        }
        return Stats(turns: turns, failures: failures)
    }

    /// 这场会话该记到哪个根。
    ///
    /// ⚠️ 判据必须与 `KnowledgeStore.noteKnowledgeBases` **同源**：那边只给
    /// **`path` 非空**的项目建根。不同源的话，一个没设工作目录的项目会算出一个
    /// "有名字、但盘上不存在的根" ⇒ `noteAbsPath` 返回 nil ⇒ **静默不记账**，
    /// 而界面上什么都看不出来。
    static func rootId(for store: ChatStore, sessionId: UUID) -> String {
        if let p = store.projects.first(where: { $0.items.contains { $0.id == sessionId } }),
           let path = p.path, !path.isEmpty {
            return KnowledgeBase.noteProjectPrefix + p.id.uuidString
        }
        return KnowledgeBase.noteGlobalID
    }

    /// 会话在侧栏里的身份（标题要它）。先查项目分组，再查平铺的 chats。
    static func conversation(_ store: ChatStore, id: UUID) -> ConversationItem? {
        if let c = store.projects.lazy.flatMap(\.items).first(where: { $0.id == id }) { return c }
        return store.chats.first { $0.id == id }
    }

    // MARK: - 节流

    /// 同一场会话多久最多写一次。
    ///
    /// 为什么需要它：一轮结束会漏出好几个事件（`streamEnded` / `agentSettled` / 手动停），
    /// 每个都写一次等于同一个文件被整篇重写三遍。而流水记的是**累计状态**（轮次单调涨），
    /// 跳过一次不影响下次正确 —— 最坏只是"最后一次更新晚了几秒"。
    static let minInterval: TimeInterval = 3
    private static var lastWriteAt: [UUID: Date] = [:]

    /// 清掉节流表。**只给冒烟用** —— 否则第二个用例会被上一个用例的时间戳挡住，
    /// 表现是"断言说没写、其实是被跳过了"，而那看起来正好像一个真 bug。
    static func resetThrottle() {
        lastWriteAt.removeAll()
    }

    // MARK: - 写

    /// 把一场会话在**这一天**的状态写进它所属根的流水。
    ///
    /// - Returns: 真的写了 / 无需写（内容一致）为 `true`；被节流、会话不存在、
    ///   还没说过话、写盘失败为 `false`。
    @discardableResult
    static func recordSession(store: ChatStore, sessionId: UUID, at date: Date = .now) -> Bool {
        if let last = lastWriteAt[sessionId],
           date.timeIntervalSince(last) < minInterval { return false }
        // ① **任务日志会话不记**：那是机器跑的，它有自己的日志会话与任务面板。
        //    混进流水会让「我上周做了什么」变成一堆「每天 3 点跑了早报」——
        //    而流水要回答的正是"人做了什么"。
        guard store.scheduler.scheduledBadge(for: sessionId) == nil else { return false }
        guard let conv = conversation(store, id: sessionId) else { return false }
        // ② **侧问会话不记**：它是对话中的 fork，正文与母会话重叠 ⇒ 记两条等于同一件事说两遍。
        guard conv.sideOf == nil else { return false }
        let s = stats(store.replayMessages(for: sessionId))
        // ③ 一句话都没说的会话不记：那是"新建了个空对话"，不是"做过什么事"。
        // 流水的每一行都要能回答"那天干了什么"，凑数的一行只会稀释它。
        guard s.turns > 0 else { return false }
        let row = TimelineDoc.sessionRow(at: date, title: conv.displayTitle,
                                         turns: s.turns, failures: s.failures)
        let ok = store.knowledge.appendTimeline(
            rootId: rootId(for: store, sessionId: sessionId), row: row)
        if ok { lastWriteAt[sessionId] = date }
        return ok
    }

    /// 采纳一篇笔记之后，往当天补一行。
    ///
    /// - Parameter reason: 提案里那句「为什么提」—— 它是**人拍板前看过的那句话**，
    ///   所以它落在流水上是"人认过的内容"，不是模型现编的。空串就不写破折号那一段。
    @discardableResult
    static func recordAdoption(store: ChatStore, rootId: String, noteTitle: String,
                               reason: String, at date: Date = .now) -> Bool {
        let row = TimelineDoc.adoptionRow(at: date, noteTitle: noteTitle, reason: reason)
        return store.knowledge.appendTimeline(rootId: rootId, row: row)
    }
}
