//
//  caseTimeline —— P18 三件事: dream 提案粒度 / 批量采纳 / 时间线
//
//  每条断言都要能**变红**: 判据是"改坏了会怎样", 不是"现在是对的"。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseTimeline() async {
        print("== P18 时间线 + dream 提案粒度 + 批量采纳 ==")

        let dir = fixtureDir("p18")
        let store = ChatStore(transport: MockTransport(), dbPath: dir + "/p18.db",
                              managedExtensionsDir: dir + "/ext")
        store.mailbox.stopScheduler()
        // 进程级重定向之外再加一层实例级: 本用例与别的用例同跑时, 笔记根必须只落在自己的目录。
        store.knowledge.noteRootOverride = dir + "/notes"
        let projPath = dir + "/proj"
        try? FileManager.default.createDirectory(atPath: projPath, withIntermediateDirectories: true)
        store.addProject(title: "p18 项目", path: projPath)
        let projConv = ConversationItem(title: "p18 会话")
        if let i = store.projects.firstIndex(where: { $0.path == projPath }) {
            store.projects[i].items.append(projConv)
        }
        let globalRoot = store.knowledge.resolvedNoteDir(projectPath: nil)

        // 固定日历: 日期断言必须确定性 —— 用 `.current` 等于把"今天几号"写进期望值。
        var fcal = Calendar(identifier: .gregorian)
        fcal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            fcal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) ?? Date()
        }

        // ---- ① 行格式 ----
        // 判据: 行是**人扫读**的东西, 格式一变就和人眼里的"一天"对不上。
        let r1 = TimelineDoc.sessionRow(at: at(2026, 10, 22, 9, 12), title: "vLLM 部署",
                                        turns: 14, failures: 2, calendar: fcal)
        check(r1.line == "- 09:12  会话「vLLM 部署」· 14 轮 · 2 次失败",
              "P18 ①: 会话行格式 (实测 \(r1.line))")
        let r1b = TimelineDoc.sessionRow(at: at(2026, 10, 22, 9, 12), title: "vLLM 部署",
                                         turns: 14, failures: 0, calendar: fcal)
        check(!r1b.line.contains("失败"),
              "P18 ①: 0 次失败**不写** —— 把默认值念一遍只是白占人眼 (实测 \(r1b.line))")

        // 反例三条: 标题里的换行 / 闭括号 / 空串。它们各自对应一个真会发生的坏结局。
        check(TimelineDoc.sanitize("标题\n第二行") == "标题 第二行",
              "P18 ①: 标题里的换行折成空格 —— 不折就会把一行拆成两行, 下一轮 upsert 再也找不到它")
        check(TimelineDoc.sanitize("a」b") == "a）b",
              "P18 ①: 标题里的 `」` 替换 —— 它是用来闭合 key 的, 带一个就提前闭合")
        check(TimelineDoc.sanitize("   ") == "未命名",
              "P18 ①: 空标题回落「未命名」(不发明一个像内容的名字)")

        // ---- ② upsert: 同一天原地替换, 新的一天插到最前 ----
        let doc0 = TimelineDoc.newDocument(monthHeading: "# 2026-10 · 全局笔记", row: r1, calendar: fcal)
        check(doc0.contains("# 2026-10 · 全局笔记") && doc0.contains("## 2026-10-22"),
              "P18 ②: 新文件的形状 = 标题 + 空行 + 当天一节")
        let r1c = TimelineDoc.sessionRow(at: at(2026, 10, 22, 10, 30), title: "vLLM 部署",
                                         turns: 20, failures: 2, calendar: fcal)
        let doc1 = TimelineDoc.upsert(doc0, row: r1c, calendar: fcal)
        check(doc1.components(separatedBy: "会话「vLLM 部署」").count - 1 == 1,
              "P18 ②: 同一场会话只留**一行** —— 每轮都追加的话, 一天能堆出十几行同一个标题")
        check(doc1.contains("20 轮") && !doc1.contains("14 轮"),
              "P18 ②: 替换成新轮次 (旧的 14 轮必须消失, 否则两份状态并存)")
        check(doc1.contains("10:30"), "P18 ②: 时间戳跟着更新")

        let r2 = TimelineDoc.sessionRow(at: at(2026, 10, 23, 8, 0), title: "第二场",
                                        turns: 3, failures: 0, calendar: fcal)
        let doc2 = TimelineDoc.upsert(doc1, row: r2, calendar: fcal)
        let a = doc2.range(of: "## 2026-10-23")
        let b = doc2.range(of: "## 2026-10-22")
        check(a != nil && b != nil && a!.lowerBound < b!.lowerBound,
              "P18 ②: 新的一天插在**最前**（节间倒序 = 打开就看到最近的）")
        check(doc2.contains("会话「vLLM 部署」· 20 轮"),
              "P18 ②: 插新节**不动**既有内容（流水只增不改别人的行）")

        // ---- ③ recentSegment: 只取最近几天 + 每天有行数上限 ----
        let docA = """
        # 2026-10 · 全局笔记

        ## 2026-10-22
        - 09:12  会话「A」· 1 轮
        - 10:00  会话「B」· 1 轮
        - 11:00  会话「C」· 1 轮

        ## 2026-10-21
        - 09:12  会话「D」· 1 轮

        ## 2026-10-20
        - 09:12  会话「E」· 1 轮
        """
        let seg = TimelineDoc.recentSegment([docA], now: at(2026, 10, 22, 12, 0),
                                            days: 2, rowsPerDay: 2, charLimit: 4000, calendar: fcal)
        check(seg.contains(TimelineDoc.token), "P18 ③: 段头带契约 token \(TimelineDoc.token)")
        check(seg.contains("2026-10-22") && seg.contains("2026-10-21"),
              "P18 ③: 取到最近两天")
        check(!seg.contains("2026-10-20"),
              "P18 ③: 更早的天**不进段**（它仍在磁盘上, agent 按路径 read）")
        check(seg.contains("另 1 条"),
              "P18 ③: 每天超出行数上限折成「另 N 条」—— 静默丢弃会让「那天还发生过别的事」变成不可知")
        // 字数兜底: 逼到很小 ⇒ 先减天数, 不能整段消失（"缺席"与"真的没发生"长得一样）。
        let tight = TimelineDoc.recentSegment([docA], now: at(2026, 10, 22, 12, 0),
                                              days: 2, rowsPerDay: 2, charLimit: 120, calendar: fcal)
        check(tight.hasPrefix(TimelineDoc.segmentHeader),
              "P18 ③: 预算再紧也**留着段头**, 不返回空串（整段缺席会读成「最近什么都没发生」）")
        check(tight.count < seg.count, "P18 ③: 收紧预算后确实变短了（否则上面那条是空转绿）")

        // ---- ④ 归属根: 与 noteKnowledgeBases 同源 ----
        check(TimelineJournal.rootId(for: store, sessionId: projConv.id).hasPrefix(KnowledgeBase.noteProjectPrefix),
              "P18 ④: 有 path 的项目会话 ⇒ 项目根")
        let flat = ConversationItem(title: "平铺会话")
        store.chats.append(flat)
        check(TimelineJournal.rootId(for: store, sessionId: flat.id) == KnowledgeBase.noteGlobalID,
              "P18 ④: 平铺会话（不在任何项目里）⇒ 全局根")
        // ⚠️ 这条是"同源"的判据: `noteKnowledgeBases` 只给 **path 非空** 的项目建根。
        // 不同源的话这里会算出一个盘上不存在的根 ⇒ appendTimeline 拿不到路径 ⇒ **静默不记账**。
        let noPathConv = ConversationItem(title: "无目录会话")
        store.addProject(title: "p18 无目录", path: "")
        if let i = store.projects.firstIndex(where: { $0.title == "p18 无目录" }) {
            store.projects[i].items.append(noPathConv)
        }
        check(TimelineJournal.rootId(for: store, sessionId: noPathConv.id) == KnowledgeBase.noteGlobalID,
              "P18 ④: **没有 path 的项目** ⇒ 回落全局（与 noteKnowledgeBases 的建根判据同源）")
        check(!store.knowledge.noteKnowledgeBases.contains {
                  $0.id.hasPrefix(KnowledgeBase.noteProjectPrefix)
                  && $0.displayName == KnowledgeBase.noteRootLabel(projectTitle: "p18 无目录")
              },
              "P18 ④ 反向: 那个项目**确实没有根** —— 否则上面那条是空转绿")

        // ---- ⑤ stats: 数轮次与失败 ----
        let msgs: [ChatMessage] = [
            ChatMessage(role: .user, content: .text("第一问")),
            ChatMessage(role: .assistant, content: .think("想一想")),
            ChatMessage(role: .assistant,
                        content: .tool(ToolCall(kind: .bash, title: "ls", phase: .error("exit 1")))),
            ChatMessage(role: .assistant, content: .text("答完")),
            ChatMessage(role: .user, content: .text("第二问")),
            ChatMessage(role: .system, content: .text("（系统提示不算一轮）")),
        ]
        let st = TimelineJournal.stats(msgs)
        check(st.turns == 2, "P18 ⑤: 轮次 = **user 文本**条数, 不是 assistant 条数 (实测 \(st.turns))")
        check(st.failures == 1, "P18 ⑤: 失败数 = 工具相位是 error 的条数 (实测 \(st.failures))")

        // ---- ⑥ 落盘: 走 resolvedNoteDir + 越界一律拒 ----
        let now = Date()
        let row = TimelineDoc.sessionRow(at: now, title: "落盘会话", turns: 4, failures: 1)
        let ok = store.knowledge.appendTimeline(rootId: KnowledgeBase.noteGlobalID, row: row)
        let rel = TimelineDoc.relativePath(for: now)
        let abs = globalRoot + "/" + rel
        check(ok && FileManager.default.fileExists(atPath: abs),
              "P18 ⑥: 落盘到 \(rel)（路径走 resolvedNoteDir, 不是手拼）")
        let text1 = (try? String(contentsOfFile: abs, encoding: .utf8)) ?? ""
        check(text1.hasPrefix("# "), "P18 ⑥: 文件头是月份标题（它同时是笔记索引里那行的 summary）")
        check(text1.contains("会话「落盘会话」"), "P18 ⑥: 行真的写进去了")

        let row2 = TimelineDoc.sessionRow(at: now, title: "落盘会话", turns: 9, failures: 1)
        store.knowledge.appendTimeline(rootId: KnowledgeBase.noteGlobalID, row: row2)
        let text2 = (try? String(contentsOfFile: abs, encoding: .utf8)) ?? ""
        check(text2.components(separatedBy: "会话「落盘会话」").count - 1 == 1,
              "P18 ⑥: 再写一次还是**一行**（这是节流之外的第二道幂等: upsert 自己认得出来）")
        check(text2.contains("9 轮"), "P18 ⑥: 轮次被刷新成 9")

        check(!store.knowledge.appendTimeline(rootId: "note:project:不存在的项目", row: row),
              "P18 ⑥ 反例: 指向不存在的根 ⇒ **拒写**, 不是写到别处去")

        // ---- ⑥b 容器粒度: **按月**, 且天粒度没丢 ----
        // 这条锁的是**容器大小**, 理由不是审美而是索引预算: `maxCharsPerBase = 2000`,
        // 每个文件在索引里恒占一行(约 60 字符) ⇒ 按月一年 12 行(708 字符)能和主题笔记共存;
        // 按周 52 行(3120)已超; 按天一年 22600, **32 天就爆** —— 而兜底是 `removeLast()`
        // 从字典序尾部丢, 丢掉的恰是**最新**那篇（第 33 天起今天记的反而看不见, 方向反了）。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let sampleDay = cal.date(from: DateComponents(year: 2026, month: 10,
                                                       day: 22, hour: 9, minute: 12))!
        check(TimelineDoc.relativePath(for: sampleDay, calendar: cal) == "timeline/2026-10.md",
              "P18 ⑥b: 容器是**月** —— 按天 32 天就撑爆 2000 字符的索引预算")
        check(TimelineDoc.dayHeader(sampleDay, calendar: cal) == "## 2026-10-22",
              "P18 ⑥b: 天粒度**没有丢**, 它表达在节头 —— 所以按月不等于丢掉时间线")

        // 写完**当场**就要重算注入块快照。不重算的话: 文件天天在长、agent 永远看不见,
        // 而所有别的断言照样全绿（这正是"零红灯的隐形缺陷"那一类）。
        check(store.knowledge.currentKnowledgeBlock?.contains(TimelineDoc.token) == true,
              "P18 ⑥: 写完流水就重算了 `currentKnowledgeBlock`（快照不刷 = 这个功能没接上）")

        // ---- ⑦ 注入段: 在最末, 且真的进了块 ----
        let inj = store.knowledge.buildInjection()
        check(inj.timelineText.contains(TimelineDoc.token),
              "P18 ⑦: 组装结果里有流水段")
        check(inj.text?.hasSuffix(inj.timelineText) == true,
              "P18 ⑦: 流水段在**整块的最末** —— 它每轮都可能变, 压在中间会让后面全部离开稳定前缀")
        check(!inj.timelineSkipped, "P18 ⑦: 这个量级的流水不该被预算挤掉")

        // ---- ⑧ 批量采纳: 逐条独立判, 一条失败不拖累其余 ----
        let insight = NoteProposal(
            id: UUID(), rootId: KnowledgeBase.noteGlobalID, kind: .insight,
            targetPath: "p18-批量.md", baseHash: "", title: "p18-批量",
            content: "# p18-批量\n\n正文", reason: "批量采纳的测试条目",
            sources: [ProposalSource(kind: .session, ref: "s-1", quote: "")],
            createdAt: Date(), status: .pending, sessionId: "log-1")
        let missing = NoteProposal(
            id: UUID(), rootId: KnowledgeBase.noteGlobalID, kind: .replace,
            targetPath: "根本没有这一篇.md", baseHash: "deadbeef", title: "",
            content: "# x", reason: "",
            sources: [ProposalSource(kind: .note, ref: "根本没有这一篇.md", quote: "")],
            createdAt: Date(), status: .pending, sessionId: "log-1")
        let outcome = store.knowledge.adoptProposals([insight, missing])
        check(outcome.adopted == 1,
              "P18 ⑧: 批量采纳成功 1 条 (实测 \(outcome.adopted))")
        check(outcome.failures.count == 1 && outcome.failures.first?.error == .noteMissing,
              "P18 ⑧: 目标不存在的那条**单独失败**, 而不是拖垮整批"
              + "（实测 \(String(describing: outcome.failures.first?.error))）")
        check(FileManager.default.fileExists(atPath: globalRoot + "/p18-批量.md"),
              "P18 ⑧: 成功那条真的落盘了")

        // 采纳后流水里该补一行 —— 这是"坑在哪里"那条主观信息的落点。
        let text3 = (try? String(contentsOfFile: abs, encoding: .utf8)) ?? ""
        check(text3.contains("采纳「p18-批量」"),
              "P18 ⑧: 采纳后流水补了一行「采纳「…」」")
        check(text3.contains("批量采纳的测试条目"),
              "P18 ⑧: 那一行带的是**提案里的 reason**（人拍板前看过的那句话）")

        // ---- ⑨ dream 的粒度口径: 软约束, 超了要**说出来** ----
        check(SchedulerService.dreamPrompt.contains("最多 \(Tune.dreamMaxProposals) 条"),
              "P18 ⑨: 指令里写死了上限 \(Tune.dreamMaxProposals) 条（改了常量不改指令 ⇒ 这里红）")
        check(SchedulerService.dreamPrompt.contains("合成一篇"),
              "P18 ⑨: 指令要求**同一会话的相关事实合成一篇** —— 这是治「8 条碎片」的根")
        check(SchedulerService.dreamPrompt.contains("三个月后"),
              "P18 ⑨: 粒度判据是「三个月后翻这一篇能不能独立说明白一件事」")
        check(SchedulerService.dreamSummary(kept: Tune.dreamMaxProposals + 2, rejects: [])
                .contains("超出约定粒度"),
              "P18 ⑨: 收口时**点名**超限 —— 软约束唯一的执法方式就是「没守住时看得见」")
        check(!SchedulerService.dreamSummary(kept: 1, rejects: []).contains("超出约定粒度"),
              "P18 ⑨ 反例: 1 条时不告警（否则这条警告会变成每次都响的噪音）")
    }
}
