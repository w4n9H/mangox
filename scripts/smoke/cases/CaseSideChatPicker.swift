//
//  caseSideChatPicker —— P6.3.3 侧问选点（`由此侧问` 的二次确认弹窗）
//
//  这一段守的是**轮号与 jsonl 同源**。轮号一旦和 `snapshotLinePrefix` 对不上, 结果不是报错,
//  而是"截出来的东西少了几轮" —— 侧问带着错的上下文开跑, 而且**零红灯**。三条最容易偏的地方:
//   ① 把助手消息 / 工具卡也数成一"轮";
//   ② 用"有没有文字"当判据 ⇒ **只有图片的那一轮被吞掉**, 轮号整体前移一格;
//   ③ 轮号与 `turns` 参数的口径不同（一个数消息、一个数 jsonl 里的 `role=user` 行）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSideChatPicker() async {
        func scMsg(_ role: MessageRole, _ text: String) -> ChatMessage {
            ChatMessage(role: role, content: .text(text))
        }

        // ── ① 切分: 只认 user, 倒序, 轮号 1 起 ──
        let scMsgs: [ChatMessage] = [
            scMsg(.user, "第一问：把左侧栏对齐"),
            scMsg(.assistant, "看懂了"),
            ChatMessage(role: .assistant, content: .tool(ToolCall(kind: .bash, title: "ls"))),
            scMsg(.user, ""),                                   // ← 只有图片, 没有文字
            scMsg(.assistant, "收到"),
            scMsg(.user, "第三问\n这一行不该被选成标题"),
        ]
        let scTurns = SideChatTurns.build(from: scMsgs)
        check(scTurns.count == 3,
              "P6.3.3 切分: 6 条消息里只有 **3 轮**（助手 / 工具卡不算轮）—— 实测 \(scTurns.count) 轮")
        check(scTurns.map(\.index) == [3, 2, 1],
              "P6.3.3 切分: **倒序**（最新在上; 正序 ⇒ 这条立刻红, 因为首项会变成第 1 轮）"
              + " —— 实测 \(scTurns.map(\.index))")
        check(scTurns.last?.title == "第一问：把左侧栏对齐",
              "P6.3.3 切分: 轮号 1 起、且最旧那一轮排在最后")
        check(scTurns[1].title.isEmpty,
              "P6.3.3 切分: **只有图片的那一轮照样算一轮**, 只是标题为空"
              + "（用\"正文非空\"当判据 ⇒ 它被吞掉、后面轮号整体前移一格, 零红灯）")
        check(scTurns.first?.title == "第三问",
              "P6.3.3 标题: 多行正文只取**第一个非空行**（实测 [\(scTurns.first?.title ?? "nil")])")

        // ── ② 轮数必须与 jsonl 的 user 行数同源 ──
        // 造同一场会话对应的 jsonl: 每条消息一行。
        func scLine(_ role: String) -> String {
            #"{"type":"message","message":{"role":"\#(role)"}}"#
        }
        let scLines = [scLine("user"), scLine("assistant"), scLine("user"),
                       scLine("assistant"), scLine("user")]
        let scUserLines = scLines.filter { $0.contains("\"role\":\"user\"") }.count
        check(scTurns.count == scUserLines,
              "P6.3.3 同源: 轮数 = jsonl 里 `role=user` 的行数 (实测 \(scTurns.count) vs \(scUserLines))")
        // 选第 k 轮 ⇒ 前缀落在"第 k+1 条 user 行之前"（切在 user 行上, 那一轮整轮丢掉）
        check(ChatStore.snapshotLinePrefix(scLines, turns: 2) == 4,
              "P6.3.3 同源: `turns: 2` 的切点 = 第 3 条 user 行 (索引 4) —— 与第 2 轮**含**它自己对齐")
        check(ChatStore.snapshotLinePrefix(scLines, turns: scTurns.count) == scLines.count,
              "P6.3.3 同源: 选到轮数上限 = 整文件 ⇒ 所以\"最新那一轮\"与\"整场\"内容等价")

        // ── ③ 选最新一轮 ⇒ 合并成整场（省一次临时快照拷贝）──
        check(SideChatTurns.upTo(picked: nil, newest: 3) == nil,
              "P6.3.3 合并: 选\"整场\" ⇒ `nil`（零拷贝, 直接用源文件）")
        check(SideChatTurns.upTo(picked: 3, newest: 3) == nil,
              "P6.3.3 合并: 选**最新那一轮**也 ⇒ `nil`（内容等价, 不该为它多拷一份文件）")
        check(SideChatTurns.upTo(picked: 2, newest: 3) == 2,
              "P6.3.3 合并: 选了中间那一轮 ⇒ 原样透传（否则侧问会悄悄变成整场, 而且看不出来）")
        check(SideChatTurns.upTo(picked: 3, newest: nil) == nil,
              "P6.3.3 合并: 空会话 ⇒ `nil`（没有轮次可截）")

        // ── ④ 首句截断: 按字符, 超了补省略号 ──
        let scLong = String(repeating: "字", count: SideChatTurns.titleLimit + 20)
        let scLongTurn = SideChatTurns.build(from: [scMsg(.user, scLong)])
        check(scLongTurn.first?.title.count == SideChatTurns.titleLimit + 1,
              "P6.3.3 截断: 首句截到 \(SideChatTurns.titleLimit) 字符 + 一个省略号"
              + " (实测 \(scLongTurn.first?.title.count ?? -1))")
        check(scLongTurn.first?.title.hasSuffix("…") == true, "P6.3.3 截断: 截断处必须看得出被截过")
        let scShort = SideChatTurns.build(from: [scMsg(.user, "短")])
        check(scShort.first?.title == "短", "P6.3.3 截断 反向: 没超长就**原样**, 不加省略号")

        // ── ⑤ 空会话: 列表空, 弹窗据此禁用主按钮 ──
        check(SideChatTurns.build(from: []).isEmpty, "P6.3.3 空态: 没说过话 ⇒ 零项（不是一项空标题）")
        check(SideChatTurns.build(from: [scMsg(.assistant, "只有助手")]).isEmpty,
              "P6.3.3 空态: 只有助手消息也算零轮 —— 侧问没有可带的提问")

        // ── ⑥ 真库: 会话里真的能取出这些轮 ──
        let scDir = fixtureDir("p632")
        let sc = ChatStore(transport: MockTransport(), dbPath: scDir + "/p632.db",
                           managedExtensionsDir: scDir + "/ext")
        sc.mailbox.stopScheduler()
        sc.addProject(title: "p632", path: scDir)
        guard let scPid = sc.projects.last?.id else {
            check(false, "P6.3.3 夹具: 建不出项目 (不是通过)")
            return
        }
        sc.createSession(in: scPid)
        guard let scSid = sc.selectedConversationId else {
            check(false, "P6.3.3 夹具: 建不出会话 (不是通过)")
            return
        }
        for n in 1...3 {
            sc.persistMessage(scMsg(.user, "第\(n)个问题"), sid: scSid)
            sc.persistMessage(scMsg(.assistant, "答\(n)"), sid: scSid)
        }
        let scLive = sc.sideChatTurns(for: scSid)
        check(scLive.map(\.index) == [3, 2, 1],
              "P6.3.3 真库: `sideChatTurns` 从落库消息里折出 3 轮 (实测 \(scLive.map(\.index)))")
        check(scLive.first?.title == "第3个问题",
              "P6.3.3 真库: 首项是最新那一轮的首句 (实测 [\(scLive.first?.title ?? "nil")])")
        check(sc.sideChatTurns(for: UUID()).isEmpty,
              "P6.3.3 真库: 不存在的会话 ⇒ 空列表（侧栏点了也只会看到禁用态, 不会崩）")

        // ── ⑦ 快照孤儿回收: 判据是"这个文件**有没有主**", 不是"它放了几天" ──
        // 三个反例各红一条, 缺一个这一节就是恒真:
        //   只断言"孤儿被清" ⇒ "把 side-snapshot-* 一律删"照样绿;
        //   只断言"有主的留着" ⇒ "什么都不做"照样绿;
        //   只认 `session_file` 一列 ⇒ **开了侧问没发消息**的那个快照被误删（它此刻唯一的
        //   指向是 `fork_source_file`, 会话已经在侧栏里, 首回合会 --fork 一个不存在的文件）。
        // ⚠️ transcript 根是**进程级**重定向 (守卫 27), 这里临时换成夹具目录再还原 ——
        //   不换的话这一节会去扫用户真实的 `~/.mangox/pi-sessions/`。
        let p634 = fixtureDir("p634")
        let snapDir = p634 + "/sessions"
        try? FileManager.default.createDirectory(atPath: snapDir, withIntermediateDirectories: true)
        let scDirBackup = PiRpcTransport.sessionDirectoryOverride
        PiRpcTransport.sessionDirectoryOverride = snapDir
        defer { PiRpcTransport.sessionDirectoryOverride = scDirBackup }

        let sc2 = ChatStore(transport: MockTransport(), dbPath: p634 + "/p634.db",
                            managedExtensionsDir: p634 + "/ext")
        sc2.mailbox.stopScheduler()
        sc2.addProject(title: "p634", path: p634)
        guard let sc2Pid = sc2.projects.last?.id else {
            check(false, "P6.3.4 夹具: 建不出项目 (不是通过)")
            return
        }
        sc2.createSession(in: sc2Pid)
        guard let sc2Sid = sc2.selectedConversationId else {
            check(false, "P6.3.4 夹具: 建不出会话 (不是通过)")
            return
        }
        sc2.createSession(in: sc2Pid)
        guard let scPendingSid = sc2.selectedConversationId, scPendingSid != sc2Sid else {
            check(false, "P6.3.4 夹具: 建不出第二场会话 (不是通过)")
            return
        }
        // 三种快照:
        //   scOwn     —— 已落定的侧问 (`session_file` 认得它)
        //   scForked  —— 侧问已进侧栏、**还没发消息** (`session_file` 是 NULL, 只有 `fork_source_file`)
        //   scOrphan  —— 会话被删掉之后留下的（正是实测那 238 个）
        let scOwn = snapDir + "/side-snapshot-" + UUID().uuidString + ".jsonl"
        let scForked = snapDir + "/side-snapshot-" + UUID().uuidString + ".jsonl"
        let scOrphan = snapDir + "/side-snapshot-" + UUID().uuidString + ".jsonl"
        for f in [scOwn, scForked, scOrphan] {
            try? "{}\n".write(toFile: f, atomically: true, encoding: .utf8)
        }
        try? sc2.persistence?.setSessionFile(id: sc2Sid, path: scOwn)
        try? sc2.persistence?.markSideChat(id: scPendingSid, sideOf: sc2Sid,
                                           sourceFile: scForked, turns: 2, at: .now)
        let scRemoved = sc2.pruneOrphanSideSnapshots()
        check(scRemoved == 1 && !FileManager.default.fileExists(atPath: scOrphan),
              "P6.3.4 回收: 没人认领的快照被清掉 (实测清了 \(scRemoved) 个, 应为 1)")
        check(FileManager.default.fileExists(atPath: scOwn),
              "P6.3.4 回收: `session_file` 认领的**一条都不许动** —— 一律当孤儿, 这条立刻红"
              + "（那快照还挂在一场侧问上, 上下文直接断层且不可恢复）")
        check(FileManager.default.fileExists(atPath: scForked),
              "P6.3.4 回收: **只认 `session_file` 会误杀这一条** —— 侧问已进侧栏、还没发消息,"
              + "它此刻唯一的指向是 `fork_source_file`; 删了它, 那场侧问首回合就 --fork 一个不存在的文件")

        // 删会话必须**立刻**带走快照 —— 泄漏的真源头就是这条路 (默认 `deleteTranscript: false`,
        // 而快照不吃那个开关)。这里刻意用默认参数, 复现最普通的那次点击。
        sc2.deleteConversation(scPendingSid)
        check(!FileManager.default.fileExists(atPath: scForked),
              "P6.3.4 删除: 删掉那场侧问 ⇒ 快照跟着走 —— 旧的半径只认 `session_file`,"
              + "没落定的侧问那儿是 NULL ⇒ 行没了、文件永远躺着（实测 238 个就是这么攒的）")

        // 接线: 同一个库上再开一个 store = 重启 App。回收**不该只在被手动调用时才发生**,
        // 否则纯函数全绿、孤儿永远躺着 —— 这正是修这个问题之前的现场。
        let scLeftover = snapDir + "/side-snapshot-" + UUID().uuidString + ".jsonl"
        try? "{}\n".write(toFile: scLeftover, atomically: true, encoding: .utf8)
        let scBoot = ChatStore(transport: MockTransport(), dbPath: p634 + "/p634.db",
                               managedExtensionsDir: p634 + "/ext")
        scBoot.mailbox.stopScheduler()
        check(!FileManager.default.fileExists(atPath: scLeftover),
              "P6.3.4 接线: `init` 开机时就回收了 —— 只写纯函数没人调, 这条红（孤儿永远不回收到）")
        check(FileManager.default.fileExists(atPath: scOwn),
              "P6.3.4 接线: 开机回收同样绕开有主的快照 (库里那条 `session_file` 还指着它)")
    }
}
