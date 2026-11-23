//
//  CaseSentMemory.swift
//  「已发消息」记忆（2026-11-23）—— 助理往外说过的话，App 留一笔，模型才接得上。
//
//  这一层的坏结局**都不报错、不变红**，所以判据钉在它们身上:
//    · 只记"打算发"（`queued` 永不落定）⇒ 模型以为说过，其实一条都没出去；
//    · 把 App 的话术也记上（`notice*`："还没归给助理" / "上一个回合还在跑"）⇒
//      注入段冒充"它自己说过的"，与刚修的 `other` 同一类错：标记比事实说得多；
//    · 注入段把 `failed` / `queued` 也当成事实 ⇒ 它会在下一轮对着空气说"我昨天告诉你了"。
//
//  反例（本轮实测，逐条单独下）:
//    · `RemoteChannelService.emit` 不记（直接 `link?.send`）⇒ **2 红**：①（打点没有行）
//      + ② 的前置（没有行 ⇒ 后面立刻 return）。⚠️ ② 自己那半（`ok` 回执把 `queued` 落成
//      `sent`）**只有正例验过** —— 反例打的是"整条记录不存在"，它到不了那一格。
//    · `settleSent` 的 `status` 不看回执（恒 `.sent`）⇒ 预期 **1 红**：③(failed)（未单独下过）。
//    · `loadSent(onlySent: true)` 去掉那道过滤 ⇒ 预期 **1 红**：⑤(取哪几条)（未单独下过）。
//
//  ⚠️ 判据一律**读注入段与库**，不读 `FakeRemoteLink` 之外的实现细节 —— `sent` 那条队列
//     是"发出去什么"的证据，`ref` 是"哪一条"的键，两样都属于对外事实。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSentMemory() async {
        print("== T-SENT 已发消息记忆 (打点 / 回执 / 注入 / 回收) ==")
        let dir = fixtureDir("sentmem")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let mock = MockTransport()
        mock.scriptedReply = { _ in "我看了一眼，CI 这次是绿的。" }
        let store = ChatStore(transport: mock, dbPath: dir + "/sent.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let fake = FakeRemoteLink()
        store.remote.attachLink(fake)

        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: nil, kind: .assistant)
        guard let idx = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }),
              let p = store.persistence else {
            check(false, "T-SENT 前置: 助理与库都就位"); return
        }
        let tid = store.scheduledTasks[idx].id
        let botId = UUID()
        let chatId = "oc_sent_chat_0001"
        store.addRemoteBot(RemoteBot(id: botId, name: "工作号", appId: "cli_sent0000000000"))
        _ = store.setRemoteBotSecret("s3cret", for: botId)
        store.assignRemoteBot(botId, to: tid)
        fake.emit(.status(botId: botId.uuidString, connected: true, note: "ok"))

        // ══ ① 一轮真回复 ⇒ 落一行, 且**关联键真的跟着下去了** ═══════════════════
        // 两件事在同一处（`emit`）决定, 所以并成一条 —— 分开写会允许"记了但键没传"这种半成品。
        store.remote.ingest(RemoteInbound(botId: botId.uuidString, chatId: chatId,
                                          messageId: "om_s1", text: "看一眼 CI"))
        _ = await waitUntil { store.runningTurns.isEmpty }
        let rows1 = (try? p.loadSent(taskId: tid, limit: 5)) ?? []
        check(rows1.count == 1 && rows1[0].kind == .reply && rows1[0].status == .queued
              && rows1[0].text.contains("CI 这次是绿的")
              && fake.sent.last?.ref == rows1[0].id.uuidString,
              "T-SENT ①回复落一行(kind=reply, status=queued), 且发给桥的 `ref` = 这一行的 id"
              + " (实测 \(rows1.count) 行 / ref \(fake.sent.last?.ref ?? "nil"))")

        // ══ ② 回执 ok ⇒ 落定 sent（"真的发出去了"只有这一档） ═══════════════════
        guard let replyRow = rows1.first else { check(false, "T-SENT ②前置: 有那一行"); return }
        fake.emit(.sendResult(botId: botId.uuidString, ok: true, messageId: "om_out_1",
                              msg: nil, ref: replyRow.id.uuidString))
        let settled = (try? p.loadSent(taskId: tid, limit: 5))?.first
        check(settled?.status == .sent,
              "T-SENT ②ok 回执把这一条落成 sent (实测 \(String(describing: settled?.status)))")

        // ══ ③ 失败回执 ⇒ failed + **留下桥的原话** ═════════════════════════════
        // 顺带把"主动推结论"这条路也走一遍: 它是另一条外发路径（没有对话轮那种 sid）。
        let finding = AgentFinding(id: UUID(), taskId: tid, sourceId: UUID(), sessionId: UUID(),
                                   title: "CI 连续三次失败", body: "正文", evidence: "证据",
                                   plan: [], planRev: 1, severity: "action",
                                   fingerprint: "fp-sent", status: .open, createdAt: Date())
        let payload = WatchNotifyService.payload(finding: finding, taskName: "CI 看守")
        store.touchRemoteBotChat(botId, chatId: chatId)
        _ = store.remote.pushFinding(payload, taskId: tid)
        let pushed = (try? p.loadSent(taskId: tid, limit: 5))?.first
        fake.emit(.sendResult(botId: botId.uuidString, ok: false, messageId: nil,
                              msg: "bridge exploded",
                              ref: pushed?.id.uuidString ?? ""))
        let failedRow = (try? p.loadSent(taskId: tid, limit: 5))?.first
        check(pushed?.kind == .push && failedRow?.status == .failed
              && failedRow?.note == "bridge exploded",
              "T-SENT ③推结论也记(kind=push); 失败回执 ⇒ failed 且**留下桥的原话**"
              + " (实测 \(String(describing: failedRow?.status)) / \(failedRow?.note ?? "nil"))")

        // ══ ④ App 的话术**不记** ═══════════════════════════════════════════════
        // 一个**没归给任何助理**的机器人（但它在机器人表里）发来一句话 ⇒ 服务会回一句
        // "这个机器人还没归给助理"。那句是 **App 的话**：它真的发出去了，但不是模型说的，
        // 进了表就会在注入段冒充"它自己说过的"。
        // ⚠️ 别用"表里没有的 bot id"造这一幕 —— 那种帧被路由判成 `unknown-bot` 而**根本不回**
        //    （对陌生人沉默是有意的），于是"没记"会因为"压根没发"而假绿。
        let strangerBot = UUID()
        store.addRemoteBot(RemoteBot(id: strangerBot, name: "没归的号", appId: "cli_stranger0000"))
        let before = ((try? p.loadSent(taskId: tid, limit: 50)) ?? []).count
        store.remote.ingest(RemoteInbound(botId: strangerBot.uuidString, chatId: "oc_stranger",
                                          messageId: "om_s2", text: "在吗"))
        let after = ((try? p.loadSent(taskId: tid, limit: 50)) ?? []).count
        check(fake.sent.last?.text.contains("还没归给助理") == true && after == before,
              "T-SENT ④`notice` 那类 App 话术**不记**(它真的发出去了, 但不是我说的)"
              + " (实测表 \(before) → \(after) 条; 最后一条发出「"
              + (fake.sent.last?.text.prefix(20).description ?? "nil") + "」)")

        // ══ ⑤ 注入段: 取哪几条 / 每条长什么样 ═════════════════════════════════
        // 另起一个干净任务，条数才能精确算（上一条任务里已经有 reply/push 两行了）。
        store.addScheduled(name: "日报", prompt: "写日报", cron: "0 0 1 1 *",
                           projectId: nil, kind: .assistant)
        guard let i2 = store.scheduledTasks.firstIndex(where: { $0.name == "日报" }) else {
            check(false, "T-SENT ⑤前置: 第二个助理"); return
        }
        let tid2 = store.scheduledTasks[i2].id
        let now = Date()
        let long = String(repeating: "长", count: SentLimit.injectChars + 30)
        func sent(_ offset: Double, _ kind: SentKind, _ status: SentStatus, _ text: String) {
            try? p.insertSent(SentMessage(taskId: tid2, sessionId: nil,
                                          at: now.addingTimeInterval(offset),
                                          kind: kind, status: status, text: text))
        }
        // 6 条 sent（时间从旧到新）+ 1 条 failed + 1 条 queued（后两条都不该进段）。
        // ⚠️ 最旧那条是**故意要被挤掉的**：5 条的窗口是这份判据的一半。
        sent(-700, .reply, .sent, "最旧的这条应当被挤掉")
        sent(-600, .reply, .sent, "第一行\n第二行")
        sent(-500, .reply, .sent, long)
        sent(-400, .push, .sent, "第三条")
        sent(-300, .file, .sent, "报告.pdf")
        sent(-200, .reply, .sent, "第六条")
        sent(-50, .reply, .failed, "这条没发出去")
        sent(-40, .reply, .queued, "这条还在路上")
        let block = store.scheduler.sentMemory(tid2, now: now) ?? ""
        let bullets = block.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        check(bullets.count == SentLimit.injectCount
              && !block.contains("这条没发出去") && !block.contains("这条还在路上")
              && !block.contains("最旧的这条")
              && bullets.last?.contains("第六条") == true,
              "T-SENT ⑤注入段只取最近 \(SentLimit.injectCount) 条**真的发出去的**, 按时间正序"
              + " (实测 \(bullets.count) 条; 末条「\(bullets.last ?? "")」)")
        check(block.contains("第一行 第二行") && !block.contains("第一行\n第二行")
              && block.contains(String(repeating: "长", count: SentLimit.injectChars) + "…")
              && !block.contains(long),
              "T-SENT ⑤换行压成空格、超 \(SentLimit.injectChars) 字截断加省略号"
              + " (一条消息占一行, 否则 5 条能把段撑成 10 行)")

        // ══ ⑥ 每个任务只留最近 200 条 ═════════════════════════════════════════
        for i in 0..<(SentLimit.keepPerTask + 5) {
            try? p.insertSent(SentMessage(taskId: tid2, sessionId: nil,
                                          at: now.addingTimeInterval(Double(i)),
                                          kind: .reply, status: .sent, text: "第 \(i) 条"))
        }
        try? p.pruneSent(taskId: tid2)
        let kept = ((try? p.loadSent(taskId: tid2, limit: 1000)) ?? []).count
        check(kept == SentLimit.keepPerTask,
              "T-SENT ⑥超过 \(SentLimit.keepPerTask) 条 ⇒ 从最旧的删 (实测 \(kept) 条)")

        // ══ ⑦ 回收半径: 删助理连它发过的话一起删 ═══════════════════════════════
        store.deleteScheduled(id: tid2)
        let left = ((try? p.loadSent(taskId: tid2, limit: 1000)) ?? []).count
        check(left == 0,
              "T-SENT ⑦删助理把它的发送记录一起删 (留着就是「任务列表里没这个助理了, 但库里还有 200 句它说的话」;"
              + " 实测剩 \(left) 条)")
    }
}
