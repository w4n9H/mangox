//
//  CaseRemoteChannel —— P19.2 S15: 飞书通道（协议 / 切行 / 路由 / 投递 / 回传）
//
//  这条通道**能坏的地方全在边界上**，而边界恰恰是自动化最验得到的部分：
//    ① 桥那一行字节被读成了什么（`content` 是 JSON 字符串、`create_time` 是毫秒字符串）；
//    ② 一次 `readabilityHandler` 给的 chunk 与"一行"毫无关系（长回复必被切开）；
//    ③ 一条消息该不该进某个助理（八种输入，八种结论，其中五种长得一模一样）；
//    ④ 收尾时回给谁（认领即删：在电脑上说的下一轮不该回响到飞书）。
//  真机那半边（真的收得到飞书的消息）自动化验不了 —— 它归 S15 的手工验收清单。
//
//  反例（2026-11-17 **实测**，每条单独下，红数是数出来的不是推的）:
//    · `NDJSONBuffer.feed` 不保留半行（每 chunk 整段当一行解析）⇒ **3 红**：②半行 / ②补齐 / ②两行挤一起。
//      （②reset 那格**不红** —— 它本来就只有一行，整段解析照样对得上。）
//    · `RemoteRoute.decide` 去掉 `duplicate` ⇒ **2 红**：④重复 + ⑤同一条 message_id 重推。
//    · `isDirectText` 去掉 `chatType == "p2p"` ⇒ **1 红**（④群聊）。
//      ⚠️ 第一次下的时候是 2 红 —— 因为我在那一行末尾写了 `// ❌ 反例`, 而它把同一行的
//      `&& senderType == "user"` 一起注释掉了 ⇒ ①app 回声那格也跟着红。**反例写坏了会多出红**,
//      与"反例没打中靶子"是同一类错误的两面: 红的条数必须能逐条对上, 对不上就先怀疑反例本身。
//    · `ChatStore` 收尾处删掉 `remote.finishRemoteTurn(sid:)` ⇒ **3 红**：⑤回传 / ⑤正文 / ⑤认领即删
//      （后两格是连带的: 认领不到 ⇒ 回传表里一直留着那条 ⇒ 再收尾一次还会发）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseRemoteChannel() async {
        let dir = fixtureDir("p19remote")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // ══ ① 协议解码（桥 → App 的那一行） ═══════════════════════════════════
        let statusLine = #"{"type":"status","connected":true,"note":"bridge up in 2001ms"}"#
        check(RemoteFrame.decode(statusLine) == .status(connected: true, note: "bridge up in 2001ms"),
              "T-REMOTE ①status 行解出 connected + note")

        // 这一行是**实测抓到的原始形状**（text 在 content 里是二次编码的 JSON 字符串，
        // 桥负责解一次；这里验的是解完之后的字段落位）。
        let msgLine = #"{"type":"message","chat_id":"oc_18e619c49667a0841b0384a7c784ee9e","chat_type":"p2p","message_id":"om_x100b608be33c14b4ce8cfc9943ccfc2","create_time":"1794898655254","text":"Hi","msg_type":"text","sender_type":"user","open_id":"ou_a02e3b66808d3397f8fea7d112698cd5"}"#
        guard case .message(let m)? = RemoteFrame.decode(msgLine) else {
            check(false, "T-REMOTE ①message 行解得出（后续判据都依赖它）"); return
        }
        check(m.chatId == "oc_18e619c49667a0841b0384a7c784ee9e" && m.text == "Hi" && m.chatType == "p2p",
              "T-REMOTE ①message 行的 chat_id / text / chat_type 都对上（实测原样）")
        check(m.createTimeMillis == 1794898655254,
              "T-REMOTE ①`create_time` 是毫秒**字符串** ⇒ 解成 Int64（不解析的话这格会一直是 0）")
        check(m.isDirectText, "T-REMOTE ①单聊 + 文本 + 人发 ⇒ 算一句话")

        check(RemoteFrame.decode(#"{"type":"send_result","ok":true,"message_id":"om_1"}"#)
                == .sendResult(ok: true, messageId: "om_1", msg: nil),
              "T-REMOTE ①send_result 行解得出")
        check(RemoteFrame.decode(#"{"type":"error","msg":"token failed"}"#) == .error("token failed"),
              "T-REMOTE ①error 行解得出")
        check(RemoteFrame.decode("[info]: [ 'event-dispatch is ready' ]") == nil,
              "T-REMOTE ①SDK 漏到 stdout 的日志行 ⇒ nil（**不是** error —— 上游多打一行不该变成用户可见告警）")
        check(RemoteFrame.decode(#"{"type":"message","chat_type":"p2p"}"#) == nil,
              "T-REMOTE ①缺 chat_id 的 message ⇒ nil（没有 chat_id 就投不出去，早丢比晚崩好）")

        // ══ ② 切行（chunk 与行无关） ═══════════════════════════════════════
        var buf = NDJSONBuffer()
        let half = Data(#"{"type":"status","connected""#.utf8)
        check(buf.feed(half).isEmpty,
              "T-REMOTE ②半行先到 ⇒ **不吐**（按 chunk 解析的话长回复必丢、短回复偶尔丢）")
        let rest = Data(":true}\n".utf8)
        check(buf.feed(rest) == [#"{"type":"status","connected":true}"#],
              "T-REMOTE ②补齐之后吐出一整行")
        var buf2 = NDJSONBuffer()
        let two = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        check(buf2.feed(two) == [#"{"a":1}"#, #"{"b":2}"#],
              "T-REMOTE ②一次挤进两行 ⇒ 都吐出来（否则第二条要等下一次读取才出现，表现为「有时慢一句」）")
        var buf3 = NDJSONBuffer()
        check(buf3.feed(Data("\n\n{\"a\":1}\n".utf8)) == [#"{"a":1}"#],
              "T-REMOTE ②空行丢掉（不丢的话每一行前面都会多出一条解析失败）")
        var buf4 = NDJSONBuffer()
        _ = buf4.feed(Data(#"{"partial":"#.utf8))
        buf4.reset()
        check(buf4.feed(Data("{\"x\":1}\n".utf8)) == [#"{"x":1}"#],
              "T-REMOTE ②reset 之后不带上一轮的残渣（重连时用同一个实例）")

        // ══ ③ 出去的话（回传正文的整形） ═════════════════════════════════════
        let withBlock = """
        CI 还是红的，我改了时区。
        【提议】
        结论：CI 失败与时区写死有关
        证据：ci/build.sh:42
        """
        let composed = RemoteReply.compose(withBlock)
        check(composed.contains("我改了时区") && !composed.contains("【提议】") && !composed.contains("证据："),
              "T-REMOTE ③提议块从回传正文里去掉（收件箱里已经渲染成卡了，原样丢进飞书等于让人读两份）")
        check(RemoteReply.compose("【提议】\n结论：只有一条提议") ==
                L("（这一轮只有一条提议，已进 MangoX 的收件箱）"),
              "T-REMOTE ③整轮只有提议 ⇒ 回一句兜底话（什么都不发的话，人看到的是「它没理我」）")
        let long = String(repeating: "字", count: RemoteReply.maxChars + 50)
        let cut = RemoteReply.compose(long)
        check(cut.count < long.count + 40 && cut.hasSuffix(L("（太长，已截断 —— 全文在 MangoX 里）")),
              "T-REMOTE ③超长截断并指路 App（一条 3000 字以上的聊天消息没人读完）")

        // ══ ④ 路由表（八格） ═══════════════════════════════════════════════
        let taskId = UUID()
        func input(bound: UUID? = taskId, assistant: Bool = true, enabled: Bool = true,
                   busy: Bool = false, dup: Bool = false,
                   chatType: String = "p2p", sender: String = "user", msgType: String = "text",
                   text: String = "把 CI 看一眼") -> RemoteRouteInput {
            RemoteRouteInput(
                inbound: RemoteInbound(chatId: "oc_x", chatType: chatType, messageId: "om_1",
                                       createTimeMillis: 1, text: text, msgType: msgType,
                                       senderType: sender),
                boundTaskId: bound, taskIsAssistant: assistant, taskEnabled: enabled,
                sessionBusy: busy, duplicate: dup)
        }
        check(RemoteRoute.decide(input()) == .deliver(taskId: taskId, prompt: "把 CI 看一眼"),
              "T-REMOTE ④绑了 + 开着 + 空闲 ⇒ 投递（prompt 是 trim 过的原话）")
        check(RemoteRoute.decide(input(dup: true)) == .ignore("duplicate"),
              "T-REMOTE ④同一个 message_id 第二次 ⇒ 丢（飞书会重推，不去重就是同一句话进去两次）")
        check(RemoteRoute.decide(input(chatType: "group")) == .ignore("not-direct-text"),
              "T-REMOTE ④群聊 ⇒ 丢（S15 只做单聊：群里回一句等于拿别人的群当公告板）")
        check(RemoteRoute.decide(input(sender: "app")) == .ignore("not-direct-text"),
              "T-REMOTE ④自己发的回声 ⇒ 丢（不丢的话会自问自答成环）")
        check(RemoteRoute.decide(input(msgType: "image", text: "")) == .ignore("not-direct-text"),
              "T-REMOTE ④图片 / 空文本 ⇒ 丢")
        check(RemoteRoute.decide(input(bound: nil)) == .unbound,
              "T-REMOTE ④没绑助理 ⇒ unbound（要回一句，否则人以为消息丢了）")
        check(RemoteRoute.decide(input(assistant: false)) == .ignore("bound-to-non-assistant"),
              "T-REMOTE ④绑到非助理 ⇒ 丢（防御：库是随手可改的）")
        check(RemoteRoute.decide(input(enabled: false)) == .paused(taskId: taskId),
              "T-REMOTE ④助理停用 ⇒ 回一句「先打开」（静默的话人会一直发）")
        check(RemoteRoute.decide(input(busy: true)) == .busy(taskId: taskId),
              "T-REMOTE ④会话正忙 ⇒ 回一句（我们**没有队列**，说「排队中」就是骗）")

        // ══ ⑤ 端到端：真投进会话、真回传 ═════════════════════════════════════
        // 用 `store.remote` 本身（不是另建一个 service）—— 要验的正是"ChatStore 的收尾点
        // 会不会调 finishRemoteTurn"这条**接线**；另建实例只能验服务自己。
        let mock = MockTransport()
        mock.scriptedReply = { _ in "我看了一眼，CI 这次是绿的。" }
        let store = ChatStore(transport: mock, dbPath: dir + "/remote.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let fake = FakeRemoteLink()
        store.remote.attachLink(fake)

        let chatId = "oc_test_chat_0001"
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: nil, kind: .assistant)
        guard let idx = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-REMOTE ⑤前置: 助理已建"); return
        }
        store.scheduledTasks[idx].remoteChatId = chatId
        check(store.scheduledTasks[idx].logSessionId == nil,
              "T-REMOTE ⑤前置: 这个助理还没有日志会话（第一条飞书消息应当**顺手把它建出来**）")

        store.remote.ingest(RemoteInbound(chatId: chatId, messageId: "om_a", text: "把 CI 看一眼"))
        let sid = store.scheduledTasks[idx].logSessionId
        check(sid != nil, "T-REMOTE ⑤第一条消息 ⇒ 会话建出来了并绑在助理上（不绑的话这一轮会被当成普通会话跑）")
        check(store.remote.pendingChats.contains { $0.chatId == chatId },
              "T-REMOTE ⑤这个单聊进了「找过机器人的单聊」表（绑定的唯一入口，飞书没有列单聊的接口）")
        guard let sid else { return }
        let began = await waitUntil { store.runningTurns.isEmpty }
        check(began, "T-REMOTE ⑤这一轮跑完了（前置：后面的断言都依赖落定的回合）")
        // ⚠️ 不用 `filter { }`：Swift 6 的 `Sequence.filter(Predicate)` 重载会把尾随闭包抢走
        //    （报 "trailing closure passed to parameter of type 'Predicate<ChatMessage>'"）。
        func userText(_ m: ChatMessage) -> String? {
            guard m.role == .user, case .text(let s) = m.content else { return nil }
            return s
        }
        func countSaid(_ text: String) -> Int {
            store.replayMessages(for: sid).compactMap(userText)
                .reduce(0) { $0 + ($1 == text ? 1 : 0) }
        }
        let said = countSaid("把 CI 看一眼")
        check(said == 1, "T-REMOTE ⑤那句话落库了**且只有一条**（\(said) 条）")
        check(fake.sent.count == 1 && fake.sent.first?.chatId == chatId,
              "T-REMOTE ⑤回合落定 ⇒ 回传到**原单聊**（收尾点接线：删掉 `finishRemoteTurn` 这格就红）")
        check(fake.sent.first?.text.contains("CI 这次是绿的") == true,
              "T-REMOTE ⑤回传的是**这一轮的回复正文**（不是空串、不是协议块）")
        // 这一轮**真的是助理的对话轮**（不是普通会话）—— 判据在 transport 收到的注入段上，
        // 那是"助理上下文"唯一的最终落点；只看 `logSessionId` 被绑上不够（绑上但反查失配
        // 也一样是普通回合，而那种"半绑"状态零信号）。
        check(mock.lastExtraSystemPrompt?.contains("【助理任务 · 对话轮】") == true,
              "T-REMOTE ⑤这一轮带着助理上下文跑（目标/账本/只读面都在那条注入段里）")
        check(mock.lastAnalysisReadOnly == true,
              "T-REMOTE ⑤对话轮是只读面（写只许写账本）")

        // 重复投递：同一个 message_id 再来一次
        store.remote.ingest(RemoteInbound(chatId: chatId, messageId: "om_a", text: "把 CI 看一眼"))
        _ = await waitUntil { store.runningTurns.isEmpty }
        let afterDup = countSaid("把 CI 看一眼")
        check(afterDup == 1,
              "T-REMOTE ⑤同一条 message_id 重推 ⇒ 不再投第二遍（飞书在网络抖动时会重推）")

        // 没绑的单聊：要回一句"还没绑"，而且**不要**建会话
        let fake2 = FakeRemoteLink()
        store.remote.attachLink(fake2)
        let before = store.allConversations.count
        store.remote.ingest(RemoteInbound(chatId: "oc_stranger", messageId: "om_b", text: "在吗"))
        check(store.allConversations.count == before,
              "T-REMOTE ⑤没绑的单聊 ⇒ **不建会话**（否则每个来找机器人的陌生人都长出一场空会话）")
        check(fake2.sent.count == 1 && fake2.sent.first?.text.contains("还没绑定助理") == true,
              "T-REMOTE ⑤没绑 ⇒ 回一句「还没绑定」，而不是沉默")
        // 冷却：连续两条只回一句
        store.remote.ingest(RemoteInbound(chatId: "oc_stranger", messageId: "om_c", text: "在吗？"))
        check(fake2.sent.count == 1,
              "T-REMOTE ⑤同一单聊 60 秒内只回一句系统提示（连发五条回来五句「还没绑」是噪音）")

        // 在电脑上说的下一轮**不该**回响到飞书：`remoteTurns` 认领即删
        let sentBefore = fake2.sent.count
        store.remote.finishRemoteTurn(sid: sid)
        check(fake2.sent.count == sentBefore,
              "T-REMOTE ⑤认领过的回合再收尾一次 ⇒ 什么都不发（认领即删，不会重复回传）")
    }
}
