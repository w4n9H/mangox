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
//  反例（2026-11-17 S15b **实测**，同样逐条下）:
//    · `RemoteRoute.decide` 去掉 `guard i.botKnown` ⇒ **1 红**（④机器人不在表里）。
//      ⚠️ 预测是 2 红（⑤那格也该红），当时只有 1 —— 因为未知机器人的 `enabled` 取
//      `bot?.enabled ?? false`，下一道 `botEnabled` 把它也挡了。两条判据在"未知机器人"
//      上重叠，**那是有意的纵深**。
//      ⚠️ 2026-11-18 那道纵深随"机器人开关"一起删了（`RemoteBot.enabled` 不再存在）
//      ⇒ 同一个反例现在**应当**变 **2 红**。这一条是**推断，本轮没有重测**（本轮动的是
//      开关收敛，`botKnown` 一行没改）。
//    · 回话处把 `botId: turn.botId` 写成 `botId: ""` ＋ `syncBots` 去掉签名短路 ⇒ **2 红**：
//      ⑤回话用的机器人 / ⑤只改名字不重起桥。（两条动的是互不相干的两处，各自对得上。）
//
//  反例（2026-11-18 开关收敛 **实测**）:
//    · `RemoteChannelService.isLive` 改成恒真（机器人不再看助理开关）⇒ **5 红**，全落在
//      新判据上: ⑤助理停用⇒桥停 / ⑤助理打开⇒桥重起（连带）/ ⑤归零之后⇒桥停 /
//      WATCHNOTIFY ④关助理⇒桥停 / ④助理关着⇒说助理关着。
//      ⚠️ 预测 4 红、实测 5 —— 多的那条是"助理打开 ⇒ 桥重起"：关的时候桥没停，起来时
//      次数自然对不上。**红的条数必须能逐条对上，对不上就先怀疑自己**（同 S15 那条教训）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseRemoteChannel() async {
        let dir = fixtureDir("p19remote")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // ══ ① 协议解码（桥 → App 的那一行） ═══════════════════════════════════
        let statusLine = #"{"type":"status","bot":"B1","connected":true,"note":"ws handshake ok"}"#
        check(RemoteFrame.decode(statusLine) == .status(botId: "B1", connected: true, note: "ws handshake ok"),
              "T-REMOTE ①status 行解出 bot + connected + note（**每帧都带 bot**：多机器人下它是路由的唯一键）")

        // 这一行是**实测抓到的原始形状**（text 在 content 里是二次编码的 JSON 字符串，
        // 桥负责解一次；这里验的是解完之后的字段落位）。
        let msgLine = #"{"type":"message","bot":"18E619C4-0000-0000-0000-000000000001","chat_id":"oc_18e619c49667a0841b0384a7c784ee9e","chat_type":"p2p","message_id":"om_x100b608be33c14b4ce8cfc9943ccfc2","create_time":"1794898655254","text":"Hi","msg_type":"text","sender_type":"user","open_id":"ou_a02e3b66808d3397f8fea7d112698cd5"}"#
        guard case .message(let m)? = RemoteFrame.decode(msgLine) else {
            check(false, "T-REMOTE ①message 行解得出（后续判据都依赖它）"); return
        }
        check(m.chatId == "oc_18e619c49667a0841b0384a7c784ee9e" && m.text == "Hi" && m.chatType == "p2p",
              "T-REMOTE ①message 行的 chat_id / text / chat_type 都对上（实测原样）")
        check(m.botId == "18E619C4-0000-0000-0000-000000000001",
              "T-REMOTE ①message 行的 bot 字段原样留住（路由靠它，丢了就全部归到同一个助理）")
        check(m.createTimeMillis == 1794898655254,
              "T-REMOTE ①`create_time` 是毫秒**字符串** ⇒ 解成 Int64（不解析的话这格会一直是 0）")
        check(m.isDirectText, "T-REMOTE ①单聊 + 文本 + 人发 ⇒ 算一句话")

        check(RemoteFrame.decode(#"{"type":"send_result","bot":"B1","ok":true,"message_id":"om_1"}"#)
                == .sendResult(botId: "B1", ok: true, messageId: "om_1", msg: nil),
              "T-REMOTE ①send_result 行解得出（含 bot：三个机器人里有一个发失败时，得知道是哪个）")
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

        // ══ ④ 路由表（十格） ═══════════════════════════════════════════════
        // S15b 起"绑定"的键是 **bot_id**（`chat_id` 只是出口），多出来的那一格全是被这一点带出来的:
        // "机器人不在表里"。⚠️ 2026-11-18 又少了一格"机器人被关掉" —— 机器人没有自己的开关了
        // （boss: 只留助理的开关），"关"现在就是"助理关着"，落到 `paused`。
        let taskId = UUID()
        func input(bound: UUID? = taskId, known: Bool = true,
                   assistant: Bool = true, enabled: Bool = true,
                   busy: Bool = false, dup: Bool = false,
                   chatType: String = "p2p", sender: String = "user", msgType: String = "text",
                   text: String = "把 CI 看一眼",
                   pending: UUID? = nil, hasPlan: Bool = false) -> RemoteRouteInput {
            RemoteRouteInput(
                inbound: RemoteInbound(botId: "B1", chatId: "oc_x", chatType: chatType, messageId: "om_1",
                                       createTimeMillis: 1, text: text, msgType: msgType,
                                       senderType: sender),
                botKnown: known,
                boundTaskId: bound, taskIsAssistant: assistant, taskEnabled: enabled,
                sessionBusy: busy, duplicate: dup,
                pendingFinding: pending, pendingHasPlan: hasPlan)
        }
        // ── 飞书审批（2026-11-18）：人不在电脑前，批与搁置都在飞书上完成 ----
        let fid = UUID()
        check(RemoteRoute.decide(input(text: "同意", pending: fid, hasPlan: true))
                == .approve(taskId: taskId, findingId: fid),
              "T-REMOTE ④「同意」+ 有待批 + 有方案 ⇒ 起执行（不必回 App）")
        check(RemoteRoute.decide(input(text: "同意", pending: fid, hasPlan: false)) == .noPlan,
              "T-REMOTE ④「同意」但那条没方案 ⇒ 明确回一句（没方案就没有可执行的东西，"
              + "静默丢弃会让他以为批了）")
        check(RemoteRoute.decide(input(text: "同意")) == .noPending,
              "T-REMOTE ④「同意」但手上没有待批的 ⇒ 明确回一句")
        check(RemoteRoute.decide(input(text: "先别动", pending: fid)) == .dismiss(taskId: taskId, findingId: fid),
              "T-REMOTE ④「先别动」⇒ 搁置（不需要方案）")
        // 忙碌时也要能批：正确的回答是"执行没起来"而不是"等它结束再发"——
        // 后者会让他以为**同意本身**没被收到。
        check(RemoteRoute.decide(input(busy: true, text: "同意", pending: fid, hasPlan: true))
                == .approve(taskId: taskId, findingId: fid),
              "T-REMOTE ④指令排在「会话正忙」之前（不然人回同意会收到一句无关的「等它结束再发」）")
        // 整句匹配：聊天里那句「可以」不许被当成批准
        for chat in ["可以", "行", "同意一下", "我觉得可以同意", "先别动吧"] {
            check(RemoteRoute.decide(input(text: chat, pending: fid, hasPlan: true))
                    == .deliver(taskId: taskId, prompt: chat),
                  "T-REMOTE ④`\(chat)` 当聊天（contains 判据会把「可以，但先别删」当批准 —— 那是误批）")
        }
        check(RemoteRoute.decide(input()) == .deliver(taskId: taskId, prompt: "把 CI 看一眼"),
              "T-REMOTE ④归了 + 开着 + 空闲 ⇒ 投递（prompt 是 trim 过的原话）")
        check(RemoteRoute.decide(input(dup: true)) == .ignore("duplicate"),
              "T-REMOTE ④同一个 message_id 第二次 ⇒ 丢（飞书会重推，不去重就是同一句话进去两次）")
        check(RemoteRoute.decide(input(chatType: "group")) == .ignore("not-direct-text"),
              "T-REMOTE ④群聊 ⇒ 丢（S15 只做单聊：群里回一句等于拿别人的群当公告板）")
        check(RemoteRoute.decide(input(sender: "app")) == .ignore("not-direct-text"),
              "T-REMOTE ④自己发的回声 ⇒ 丢（不丢的话会自问自答成环）")
        check(RemoteRoute.decide(input(msgType: "image", text: "")) == .ignore("not-direct-text"),
              "T-REMOTE ④图片 / 空文本 ⇒ 丢")
        check(RemoteRoute.decide(input(known: false)) == .ignore("unknown-bot"),
              "T-REMOTE ④机器人不在表里 ⇒ 丢**且不回**（防御: 桥跑着一个已被删掉的机器人；不回是因为我们手上没有它的 token）")
        check(RemoteRoute.decide(input(bound: nil)) == .unbound,
              "T-REMOTE ④机器人没归助理 ⇒ unbound（要回一句，否则人以为消息丢了）")
        check(RemoteRoute.decide(input(assistant: false)) == .ignore("bound-to-non-assistant"),
              "T-REMOTE ④归到非助理 ⇒ 丢（防御：库是随手可改的）")
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

        let botId = UUID()
        let appId = "cli_a1b2c3d4e5f6a7b8"
        let chatId = "oc_test_chat_0001"
        // ⚠️ 顺序被 2026-11-18 的开关收敛改了：机器人**没有自己的开关**，连接判据是"归给的
        // 助理存在且开着"⇒ 必须先有助理、先归上，再补 secret，否则"补上 secret 就起桥"验不到
        // （没归的机器人凭据齐了也不连）。
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: nil, kind: .assistant)
        guard let idx = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-REMOTE ⑤前置: 助理已建"); return
        }
        let assistantId = store.scheduledTasks[idx].id

        store.addRemoteBot(RemoteBot(id: botId, name: "工作号", appId: appId))
        store.assignRemoteBot(botId, to: assistantId)
        check(fake.started == 0,
              "T-REMOTE ⑤归了助理 + 有 app_id，但没 secret ⇒ **不连**（缺凭据不是错误，界面显示缺什么就行）")
        _ = store.setRemoteBotSecret("s3cret", for: botId)
        check(fake.started == 1 && fake.startedBots.last?.count == 1,
              "T-REMOTE ⑤补上 secret ⇒ 桥起了，且清单里就这一个机器人")
        check(fake.startedBots.last?.first?.appId == appId,
              "T-REMOTE ⑤下发给桥的是**这个机器人的** app_id（错位的话会用别的身份连）")

        check(store.remoteBots.first { $0.id == botId }?.assistantId == assistantId,
              "T-REMOTE ⑤归属落在**机器人行**上（`assistant_id` 单值列 ⇒ 一个机器人只归一个助理）")
        check(store.scheduledTasks[idx].logSessionId == nil,
              "T-REMOTE ⑤前置: 这个助理还没有日志会话（第一条飞书消息应当**顺手把它建出来**）")

        store.remote.ingest(RemoteInbound(botId: botId.uuidString, chatId: chatId,
                                          messageId: "om_a", text: "把 CI 看一眼"))
        let sid = store.scheduledTasks[idx].logSessionId
        check(sid != nil, "T-REMOTE ⑤第一条消息 ⇒ 会话建出来了并绑在助理上（不绑的话这一轮会被当成普通会话跑）")
        check(store.remote.pendingChats.contains { $0.chatId == chatId },
              "T-REMOTE ⑤这个会话进了「最近来找过机器人」表（诊断用: 它证明连接真的通了；绑定不靠它）")
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
              "T-REMOTE ⑤这一轮带着助理上下文跑（目标/账本/笔都在那条注入段里）")
        // ⚠️ 2026-11-18: 这里原来还有一格"对话轮是只读面"。只读面整层删了 —— 飞书来的这句话
        //    走的就是那场助理的**对话轮**，工具面跟助理自己选的档位走，不再有第三张面。

        // 重复投递：同一个 message_id 再来一次
        store.remote.ingest(RemoteInbound(botId: botId.uuidString, chatId: chatId,
                                          messageId: "om_a", text: "把 CI 看一眼"))
        _ = await waitUntil { store.runningTurns.isEmpty }
        let afterDup = countSaid("把 CI 看一眼")
        check(afterDup == 1,
              "T-REMOTE ⑤同一条 message_id 重推 ⇒ 不再投第二遍（飞书在网络抖动时会重推）")

        // ── 桥重起的判据：只该由"谁在跑"的签名变化触发 ──────────────────────
        // 这三格是 S15b 的状态机骨架。改名重连会让长连接每改一次名字就断一次；
        // 换 secret 不重连会用旧身份一直连（改了凭据却没生效，最难查）。
        let startedBeforeRename = fake.started
        var renamed = store.remoteBots.first { $0.id == botId }!
        renamed.name = "工作号（改名）"
        store.updateRemoteBot(renamed)
        check(fake.started == startedBeforeRename,
              "T-REMOTE ⑤只改名字 ⇒ **不重起桥**（重连一次就是几百毫秒收不到消息）")

        let startedBeforeSecret = fake.started
        _ = store.setRemoteBotSecret("rotated-secret", for: botId)
        check(fake.started == startedBeforeSecret + 1,
              "T-REMOTE ⑤换 secret ⇒ 重起桥（不重连就会用旧 secret 一直连，改了凭据却没生效）")

        // ⚠️ 2026-11-18 这格**反过来了**：机器人没有自己的开关，助理那盏就是它唯一的开关
        // ⇒ 停用助理必须**断桥**（旧口径"桥不动、只回一句先打开我"随 `RemoteBot.enabled` 一起作废）。
        let startedBeforePause = fake.started
        let stoppedBeforePause = fake.stopped
        store.toggleScheduled(id: assistantId)   // 停用助理
        check(fake.stopped > stoppedBeforePause && fake.started == startedBeforePause,
              "T-REMOTE ⑤助理停用 ⇒ **桥停下**（关助理就是关机器人：留着长连接等于多一个关不掉的入口）")
        store.toggleScheduled(id: assistantId)   // 打开回来
        check(fake.started == startedBeforePause + 1,
              "T-REMOTE ⑤助理打开 ⇒ 桥重起（关→开是一次真实的状态迁移，不是空操作）")

        // 没归助理的机器人：要回一句，而且**不要**建会话
        let fake2 = FakeRemoteLink()
        store.remote.attachLink(fake2)
        store.assignRemoteBot(botId, to: nil)
        check(fake2.stopped > 0,
              "T-REMOTE ⑤归零之后 ⇒ 桥停（没归助理 = 没有开关能管它 ⇒ 不留一个关不掉的长连接）")
        let before = store.allConversations.count
        store.remote.ingest(RemoteInbound(botId: botId.uuidString, chatId: "oc_stranger",
                                          messageId: "om_b", text: "在吗"))
        check(store.allConversations.count == before,
              "T-REMOTE ⑤机器人没归助理 ⇒ **不建会话**（否则每个来找它的陌生人都长出一场空会话）")
        check(fake2.sent.count == 1 && fake2.sent.first?.text.contains("还没归给助理") == true,
              "T-REMOTE ⑤没归 ⇒ 回一句「还没归给助理」，而不是沉默")
        check(fake2.sent.first?.botId == botId.uuidString,
              "T-REMOTE ⑤回话用的是**收到消息的那个机器人**（借别的机器人发 = 用错身份说话）")
        // 冷却：连续两条只回一句
        store.remote.ingest(RemoteInbound(botId: botId.uuidString, chatId: "oc_stranger",
                                          messageId: "om_c", text: "在吗？"))
        check(fake2.sent.count == 1,
              "T-REMOTE ⑤同一单聊 60 秒内只回一句系统提示（连发五条回来五句「还没归」是噪音）")

        // 表里没有的机器人：不投、不回（防御: 桥跑着一个已经删掉的机器人）
        let fake3 = FakeRemoteLink()
        store.remote.attachLink(fake3)
        store.remote.ingest(RemoteInbound(botId: UUID().uuidString, chatId: "oc_ghost",
                                          messageId: "om_d", text: "在吗"))
        check(fake3.sent.isEmpty,
              "T-REMOTE ⑤机器人不在表里 ⇒ 不投也不回（我们手上没有它的 token，回也回不出去）")

        // 在电脑上说的下一轮**不该**回响到飞书：`remoteTurns` 认领即删
        let sentBefore = fake2.sent.count
        store.remote.finishRemoteTurn(sid: sid)
        check(fake2.sent.count == sentBefore,
              "T-REMOTE ⑤认领过的回合再收尾一次 ⇒ 什么都不发（认领即删，不会重复回传）")

        // ── 删机器人：连带清钥匙串（没有主人的凭据 = 下次撞上就静默复用别人的） ──
        // ⚠️ 先把它归回去：机器人没有自己的开关（2026-11-18），不归助理它本来就不连 ——
        //    那样"删掉 ⇒ 桥停掉"会因为桥早就停了而验不到（断言仍绿，但它证明的是别的事）。
        // ⚠️ 删掉**最后一个**机器人时后台的动作是"停"而不是"重起"（清单空了，没有可连的），
        //    所以判据是 `stopped` —— 写成 `started + 1` 会红，而且是那种"看起来像功能坏了"的红。
        store.assignRemoteBot(botId, to: assistantId)
        let stoppedBefore = fake3.stopped
        store.removeRemoteBot(botId)
        check(store.remoteBots.isEmpty, "T-REMOTE ⑥删机器人 ⇒ 行没了")
        check(!store.hasRemoteBotSecret(botId),
              "T-REMOTE ⑥删机器人 ⇒ 钥匙串那条 secret 一起清（不留没有主人的凭据）")
        check(fake3.stopped > stoppedBefore,
              "T-REMOTE ⑥删掉最后一个机器人 ⇒ 桥停掉（不留一个什么都不连的 node 进程）")
        check(store.remote.phase == .off, "T-REMOTE ⑥一个机器人都没有 ⇒ 汇总状态是未启用")

        // ══ ⑦ 1:1 的另一半（一个助理只挂一个机器人） ═══════════════════════════
        // 这一格判的是**域层**，不是界面：界面上是单选，库里手改一下就能长出两个，
        // 而两个机器人归同一个助理时，两边的话会进同一场会话 —— 界面上完全看不出问题。
        // 机器人故意不给 secret（桥不启），这样这组断言只测归属，不牵动进程状态。
        let botA = UUID(), botB = UUID()
        store.addRemoteBot(RemoteBot(id: botA, name: "A 号", appId: "cli_aaaaaaaaaaaa"))
        store.addRemoteBot(RemoteBot(id: botB, name: "B 号", appId: "cli_bbbbbbbbbbbb"))
        store.addScheduled(name: "第二个助理", prompt: "随便看看", cron: "0 0 1 1 *",
                           projectId: nil, kind: .assistant)
        guard let second = store.scheduledTasks.first(where: { $0.name == "第二个助理" })?.id else {
            check(false, "T-REMOTE ⑦前置: 第二个助理已建"); return
        }
        store.assignRemoteBot(botA, to: second)
        store.assignRemoteBot(botB, to: second)
        check(store.remoteBots.first { $0.id == botA }?.assistantId == nil,
              "T-REMOTE ⑦同一助理改归第二个机器人 ⇒ 第一个被顶掉（把界面改成多选、或手改库，这格就红）")
        check(store.remoteBots.first { $0.id == botB }?.assistantId == second,
              "T-REMOTE ⑦第二个机器人归上了（顶掉旧的不等于没归上新的）")
    }
}
