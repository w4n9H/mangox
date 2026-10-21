//
//  caseTargetedDream —— P15.9 定向 dream（侧栏会话行的《由此 Dream》）
//
//  为什么值得断言: 这一段的风险全在"看起来跑通了"上, 三处都不会报错 ——
//   ① **预算没真的换成 256k**（改法有一百种, 漏一处 = 用户点了、弹窗写着 256k, 实际还是 4 万）;
//   ② **定向 run 顺手推进了 `lastRunAt`**（那一刻什么都不报, 代价是"上次真跑在很久以前"那段
//      **补跑窗口**被吃掉 ⇒ 那几天没被定向跑过的会话**永久掉出 36 小时窗口**, 且零红灯）;
//   ③ **弹窗显示的字数与真正喂进去的不一个口径**（两个数各算各的, 差几个百分点肉眼看不出来）。
//
//  三条都只在**长会话**上现形 ⇒ 夹具就是一场 ~8 万字 / 40 回合的合成会话:
//  它**必须超定时预算**（否则"定向不裁"是空转绿）, 又**必须远低于 256k**（否则反过来）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseTargetedDream() async {
        // ── ① 预算常量: 两个数必须有量级差 ──
        check(Tune.dreamTargetedMaxChars == 256000,
              "P15.9 预算: 定向单场 256k (boss 2026-10-21 指定; 改回 4 万 ⇒ 立刻红)")
        check(Tune.dreamDigestMaxCharsPerSession < Tune.dreamTargetedMaxChars,
              "P15.9 预算: 定向**必须**比定时那轮大 —— 两者相等的话\"整场\"与\"窗口\"就是同一件事,"
              + " 这一整套入口没有存在理由 (实测 \(Tune.dreamDigestMaxCharsPerSession) vs \(Tune.dreamTargetedMaxChars))")

        // ── ② 真实库: 一场 40 回合的会话 ──
        let tdDir = fixtureDir("p159")
        let td = ChatStore(transport: MockTransport(), dbPath: tdDir + "/p159.db",
                           managedExtensionsDir: tdDir + "/ext")
        td.mailbox.stopScheduler()
        // 实例级重定向（与 P15.8 同法）: 归属根与后面写笔记都落在夹具里, 不碰用户真实目录。
        td.knowledge.noteRootOverride = tdDir + "/notes"
        td.addProject(title: "p159", path: tdDir)
        guard let tdPid = td.projects.last?.id else {
            check(false, "P15.9 夹具: 建不出项目 (不是通过)")
            return
        }
        td.createSession(in: tdPid)
        guard let tdSid = td.selectedConversationId else {
            check(false, "P15.9 夹具: 建不出会话 (不是通过)")
            return
        }
        // 40 个回合 × ≈1.9k 字 ≈ 7.7 万字符 —— 超 4 万、远低于 256k。
        // 每回合还夹一条**工具卡**: 它不进材料, 顺带守住"弹窗的字数不是消息条数"。
        for n in 1...40 {
            td.persistMessage(ChatMessage(role: .user,
                                          content: .text("第\(n)个问题：这一段到底要解决什么")), sid: tdSid)
            td.persistMessage(ChatMessage(role: .assistant,
                                          content: .text(String(repeating: "答", count: 1900))), sid: tdSid)
            td.persistMessage(ChatMessage(role: .assistant,
                                          content: .tool(ToolCall(kind: .bash, title: "ls"))), sid: tdSid)
        }

        // ── ③ 规模口径: 弹窗那个数 = 真正送进去的材料, **逐字相等** ──
        let tdMsgs = td.replayMessages(for: tdSid)
        let tdLines = KnowledgeStore.sessionMaterial(from: tdMsgs)
        let tdBody = tdLines.joined(separator: "\n")
        guard let tdStats = td.persistence?.dreamMaterialStats(id: tdSid) else {
            check(false, "P15.9 规模口径: 取不到 dreamMaterialStats (不是通过)")
            return
        }
        check(tdStats.chars == tdBody.count,
              "P15.9 规模口径: 弹窗的字数与**真正喂进去的材料逐字相等**"
              + " (实测 \(tdStats.chars) vs \(tdBody.count)) —— 这条打的是\"口径算错方向\""
              + "（多算 ⇒ 弹窗喊超预算而实际没裁, 少算 ⇒ 该告警的不告警）")
        check(tdStats.lines == tdLines.count,
              "P15.9 规模口径: 行数 = 有正文的消息条数（工具卡不算, 实测 \(tdStats.lines) vs \(tdLines.count))")
        let tdUserLines = tdLines.filter { $0.hasPrefix("用户: ") }.count
        check(tdStats.turns == tdUserLines,
              "P15.9 规模口径: 回合数只数**用户**行（说\"40 个回合\"才像一场对话; 实测 \(tdStats.turns) vs \(tdUserLines))")
        // 夹具自证: 没有这两条, 下面的"不裁"可能只是因为材料本来就短。
        check(tdStats.chars > Tune.dreamDigestMaxCharsPerSession,
              "P15.9 夹具: 这一场**超**定时预算 (实测 \(tdStats.chars) 字 > \(Tune.dreamDigestMaxCharsPerSession)) —— 否则④是空转绿")
        check(tdStats.chars < Tune.dreamTargetedMaxChars,
              "P15.9 夹具: 这一场**远低于** 256k (实测 \(tdStats.chars) 字) —— 否则⑤那条告警判据没处落")

        guard let tdItem = td.allConversations.first(where: { $0.id == tdSid }) else {
            check(false, "P15.9 夹具: allConversations 里找不到刚建的会话 (不是通过)")
            return
        }

        // ── ④ 生产路径: `buildDreamDigest(target:)` 真的用了 256k ──
        let tdDigest = td.scheduler.buildDreamDigest(target: tdItem)
        check(tdDigest.contains("用户: 第1个问题") && tdDigest.contains("用户: 第40个问题"),
              "P15.9 生产路径: 定向摘要**整场都在** —— 最早那一问与最后一问同时在"
              + "（把 `buildDreamDigest(target:)` 的 `budget` 换回默认值 ⇒ 这里立刻红: "
              + "实测段头 [\(tdDigest.prefix(56))…] 共 \(tdDigest.count) 字）")
        check(!tdDigest.contains("更早的") && !tdDigest.contains("另有"),
              "P15.9 生产路径: 256k 下**一句省略都没有** (实测 [\(tdDigest.prefix(56))…])")
        check(tdDigest.contains("整场 · 指定会话"),
              "P15.9 生产路径: 段头如实说这是整场 —— 否则\"窗口 36 小时\"就是假话（模型据此判时间跨度）")
        check(tdDigest.contains("【最近会话摘录"),
              "P15.9 生产路径: 段名**没跟着定向改名** —— `dreamPrompt` 的指令正文指着它, "
              + "改名等于告诉模型\"没有摘录段\", 它会直接收场（零红灯）")
        // 对照面: 同一份材料走定时那轮的预算 ⇒ **必然**被裁。它证明④不是"材料本来就不长"。
        let tdLabel = SchedulerService.sessionRootLabels(store: td)[tdSid] ?? KnowledgeBase.noteGlobalLabel
        let tdTimed = SchedulerService.sessionDigest(
            [SchedulerService.DreamDigestInput(id: tdSid, title: tdItem.title,
                                              updatedAt: tdItem.updatedAt, messages: tdMsgs,
                                              noteRootLabel: tdLabel)],
            since: .distantPast)
        check(tdTimed.contains("更早的"),
              "P15.9 **对照面**: 同一场用定时那轮的 4 万预算就必然被裁"
              + "（所以④的\"不裁\"只可能来自预算 —— 实测 [\(tdTimed.prefix(48))…])")

        // ── ⑤ 弹窗的取舍 (纯数据, 视图只画) ──
        let tdPrev = DreamPreview(id: tdSid, title: tdItem.title, materialChars: tdStats.chars,
                                  turns: tdStats.turns, lines: tdStats.lines,
                                  rootLabel: tdLabel, budget: Tune.dreamTargetedMaxChars)
        check(!tdPrev.isEmpty && !tdPrev.willTruncate,
              "P15.9 弹窗: 7.7 万字 < 256k ⇒ 不置灰、**不亮**超预算提示")
        check(tdPrev.budgetRatio > 0.2 && tdPrev.budgetRatio < 0.5,
              "P15.9 弹窗: 进度条按真实占比走 (实测 \(String(format: "%.2f", tdPrev.budgetRatio)))")
        let tdOver = DreamPreview(id: tdSid, title: tdItem.title,
                                  materialChars: Tune.dreamTargetedMaxChars + 1,
                                  turns: 1, lines: 1, rootLabel: tdLabel, budget: Tune.dreamTargetedMaxChars)
        check(tdOver.willTruncate, "P15.9 弹窗: 超 1 个字就亮告警（判据是 `>` 不是 `>=`, 正好等于预算时不算裁）")
        check(tdOver.budgetRatio == 1, "P15.9 弹窗: 进度条**吃到 100% 就停** (超了也不越出框)")
        let tdEmpty = DreamPreview(id: tdSid, title: tdItem.title, materialChars: 0, turns: 0, lines: 0,
                                   rootLabel: tdLabel, budget: Tune.dreamTargetedMaxChars)
        check(tdEmpty.isEmpty && !tdEmpty.willTruncate && tdEmpty.budgetRatio == 0,
              "P15.9 弹窗: 空会话 ⇒ 只置灰, **不叠加**\"超预算\"(两句话自相矛盾会让人不敢点)")

        // ── ⑥ 禁用规则 ①: 这一场自己在跑 (纯函数; ②③ 要看日志会话, 所以在 fire 之后) ──
        check(SchedulerService.canTargetDream(sid: tdSid, running: [], tasks: td.scheduledTasks),
              "P15.9 禁用 反向: 什么都不在跑时**可点**（否则下面几条是空转绿）")
        check(!SchedulerService.canTargetDream(sid: tdSid, running: [tdSid], tasks: td.scheduledTasks),
              "P15.9 禁用 ①: 这一场自己的回合在跑 ⇒ 不可点（读到的会是**半句话**—— 半句话的摘录比没有摘录更坏）")
        check(SchedulerService.canTargetDream(sid: tdSid, running: [UUID()], tasks: td.scheduledTasks),
              "P15.9 禁用 ① 反例: **别的**会话在跑不影响（判据是 `running.contains(sid)`, 不是\"有任何回合在跑\")")

        // ── ⑦ 定向 fire: 起得来、但不推进 `lastRunAt` ──
        guard let tdTaskIdx = td.scheduledTasks.firstIndex(where: { SchedulerService.isDreamTask($0) }) else {
            check(false, "P15.9 fire: 表里没有 dream 任务 (不是通过)")
            return
        }
        let tdTask0 = td.scheduledTasks[tdTaskIdx]
        check(tdTask0.lastRunAt == nil,
              "P15.9 fire 前置: 这条 dream 任务从没跑过 (下面才能区分\"没写\"与\"写了同一个值\")")
        check(td.scheduler.runTargetedDream(tdItem, stats: tdStats) == .started,
              "P15.9 fire: 正常一场 ⇒ `.started`")
        let tdTask1 = td.scheduledTasks[tdTaskIdx]
        check(tdTask1.lastRunAt == tdTask0.lastRunAt,
              "P15.9 **反向判据**: 定向 run **不推进 `lastRunAt`** —— 一推进, `dreamDigestSince` 就取到近处,"
              + " 那几天没被定向跑过的会话**永久掉出 36 小时窗口**, 且零红灯 (实测 \(String(describing: tdTask1.lastRunAt)))")
        check(tdTask1.runCount == tdTask0.runCount,
              "P15.9: `runCount` 也不涨 —— 它的语义是\"定时跑了几次\"")
        // 非空转的证明: 同一个 `if let idx` 块里 `logSessionId` **写了** ⇒ 那一行确实执行过,
        // 唯一没写 `lastRunAt` 的原因就是 `targeted == nil` 那道闸（不是"整块没跑到"）。
        check(tdTask1.logSessionId != nil,
              "P15.9 fire: `logSessionId` 照写（复用同一个日志会话）—— 它证明上面那条不是\"那一段根本没执行\"")
        if let tdFirstLog = tdTask1.logSessionId {
            check(!SchedulerService.canTargetDream(sid: tdSid, running: [tdFirstLog], tasks: td.scheduledTasks),
                  "P15.9 禁用 ②: dream 在跑 ⇒ 不可点（日志会话撞车, 起来也会被跳过 —— 点了没反应是最坏的反馈）")
            check(!SchedulerService.canTargetDream(sid: tdFirstLog, running: [], tasks: td.scheduledTasks),
                  "P15.9 禁用 ③: **任务日志会话本身** ⇒ 不可点（那是机器跑出来的日志, dream 自己那轮的候选也排除它）")
        }

        // ── ⑧ 收口去重: 同一场被跑两次, 待审队列里只该有一行 ──
        // 定向让"重复提炼"从罕见变成常态（用户点一次 + 当晚定时那轮又吃一遍）, 而重复的提案
        // 在队列里长得一模一样、标题也一样 —— 人只能靠肉眼认出"这条我见过"。
        let tdRootPath = td.knowledge.resolvedNoteDir(projectPath: nil)
        let tdSpool = PiRpcTransport.dreamSpoolPath(taskId: SchedulerService.dreamTaskID)
        func tdWriteSpool() {
            try? FileManager.default.createDirectory(
                atPath: (tdSpool as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? #"{"kind":"insight","target_path":"\#(tdRootPath)/p159-dedupe.md","title":"p159-dedupe","content":"一条洞见","reason":"复现 3 次","sources":[{"ref":"s1","quote":"原话"}]}"#
                .write(toFile: tdSpool, atomically: true, encoding: .utf8)
        }
        if let tdLog = tdTask1.logSessionId {
            func tdDreamLines() -> [String] {
                td.replayMessages(for: tdLog).compactMap { m -> String? in
                    if case .text(let s) = m.content, s.contains("dream 收口") { return s }
                    return nil
                }
            }
            tdWriteSpool()
            td.scheduler.finishDreamFireIfNeeded(sid: tdLog)
            let tdFirst = (try? td.persistence?.loadNoteProposals()) ?? []
            check(tdFirst.count == 1, "P15.9 收口: 第一次落表 1 条 (实测 \(tdFirst.count) 条)")
            check(tdDreamLines().last?.contains("跳过") == false,
                  "P15.9 收口: 第一次**不提**重复 —— 那时队列里确实还没有（否则\"跳过\"这个词会变成噪音）")

            // 第二轮: 同一场再跑一次（`runningTurns` 必须先收干净, 否则门口就 `.busy`）
            check(await waitUntil { td.runningTurns.isEmpty }, "P15.9 收口: 第一轮回合收干净")
            check(td.scheduler.runTargetedDream(tdItem, stats: tdStats) == .started,
                  "P15.9 收口: 同一场可以再跑一次（定向不与定时互斥, 只与\"在途\"互斥）")
            tdWriteSpool()
            td.scheduler.finishDreamFireIfNeeded(sid: tdLog)
            let tdSecond = (try? td.persistence?.loadNoteProposals()) ?? []
            check(tdSecond.count == 1,
                  "P15.9 收口 **去重**: 同根 + 同路径 + 同标题 ⇒ 第二次**不入表** (实测 \(tdSecond.count) 条)")
            check(tdDreamLines().last?.contains("跳过 1 条已在待审队列里的重复提案") == true,
                  "P15.9 收口: 重复数**单列说出来** —— 否则\"这条我上次提过\"看起来像\"模型这次没提\""
                  + " (实测 [\((tdDreamLines().last ?? "-").replacingOccurrences(of: "\n", with: " / "))])")
            // 去重键的三段: 少任何一段都会把不同的洞见吞成一条。
            check(SchedulerService.proposalKey(rootId: "r", path: "a.md", title: "t")
                    != SchedulerService.proposalKey(rootId: "r", path: "b.md", title: "t"),
                  "P15.9 去重键: **目标路径**参与（否则同名不同文的洞见会被吞）")
            check(SchedulerService.proposalKey(rootId: "r", path: "a.md", title: "t")
                    != SchedulerService.proposalKey(rootId: "r2", path: "a.md", title: "t"),
                  "P15.9 去重键: **根**参与（全局与项目各有一条同名笔记是合法的两件事）")
            check(SchedulerService.proposalKey(rootId: "r", path: "a.md", title: "t")
                    != SchedulerService.proposalKey(rootId: "r", path: "a.md", title: "t2"),
                  "P15.9 去重键: **标题**参与")
        } else {
            check(false, "P15.9 收口: 没有日志会话 ⇒ 去重判据没跑 (不是通过)")
        }

        // ── ⑨ 空会话: 在门口挡掉, 一个回合都不起 ──
        td.createSession(in: tdPid)
        guard let tdEmptySid = td.selectedConversationId,
              let tdEmptyItem = td.allConversations.first(where: { $0.id == tdEmptySid }) else {
            check(false, "P15.9 空会话: 建不出空会话 (不是通过)")
            return
        }
        let tdEmptyStats = td.persistence?.dreamMaterialStats(id: tdEmptySid) ?? (chars: 0, turns: 0, lines: 0)
        check(tdEmptyStats.chars == 0, "P15.9 空会话: 材料 0 字（弹窗据此置灰按钮）")
        let tdRunningBefore = td.runningTurns
        check(td.scheduler.runTargetedDream(tdEmptyItem, stats: tdEmptyStats) == .empty,
              "P15.9 空会话: 返回 `.empty`（否则会 fire 一个没有摘录段的回合, 让模型自己读到硬约束再空转结束 ——"
              + " 花一次调用只为说\"没料\"）")
        check(td.runningTurns == tdRunningBefore,
              "P15.9 空会话: **一个回合都没起**（判据看回合集合, 不看返回值 —— 返回值对但回了"
              + " \"已开始 dream\" 的横幅同样是坏反馈）")

        // ── ⑩ 指令: 定向那段是**追加**, 不改常量 ──
        check(SchedulerService.dreamPrompt.contains("【最近会话摘录】"),
              "P15.9 指令: 常量正文仍指着【最近会话摘录】(段名一改, 模型就以为没有摘录段)")
        check(!SchedulerService.dreamPrompt.contains("定向整理"),
              "P15.9 指令: **常量里不含**定向那一段 —— 它同时是定时那轮的指令（且落库成任务行的 prompt）,"
              + " 写进去会让\"定时 = 窗口\"变成假话")
        let tdTargetedPrompt = SchedulerService.dreamFirePrompt(
            digest: tdDigest, notes: "", scopeNote: SchedulerService.dreamTargetedScopeNote)
        check(tdTargetedPrompt.hasPrefix(SchedulerService.dreamPrompt),
              "P15.9 指令: 出厂常量**原样在最前**（追加而不是替换 —— 规则只有一份）")
        check(tdTargetedPrompt.contains("定向整理") && tdTargetedPrompt.contains("整场 · 指定会话"),
              "P15.9 指令: 定向那次带上了范围说明, 且与段头用的是**同一句话**")
        let tdTimedPrompt = SchedulerService.dreamFirePrompt(digest: tdDigest, notes: "")
        check(!tdTimedPrompt.contains("定向整理"),
              "P15.9 指令: 定时那轮**不带**（`scopeNote` 缺省 nil ⇒ 两条路分得开）")
        check(tdTargetedPrompt.hasSuffix(tdDigest),
              "P15.9 指令: 摘录段压在**末尾**（指令正文说\"见本消息末尾\", 长上下文里\"末尾\"是有信息量的位置）")

        // ── ⑪ 两类运行在同一条会话里必须分得开（分隔行）──
        // 定向与定时共用**同一条** dream 日志会话（这是有意的: 不然点一次侧栏多一条）。代价是
        // 分隔行若长得一样, 三个月后翻这条记录分不出哪次是《由此 Dream》、对的是哪一场。
        guard let tdLog = td.scheduledTasks.first(where: { SchedulerService.isDreamTask($0) })?.logSessionId else {
            check(false, "P15.9 分隔行: 没有日志会话 (不是通过)")
            return
        }
        func tdSeps() -> [String] {
            // ⚠️ 收口那行（`── dream 收口: N 条提案待审 ──`）也是同一个包围格式, 必须排掉 ——
            //    否则"两次定向 = 两行分隔"这条会被收口行凑数, 变成恒真的绿。
            td.replayMessages(for: tdLog).compactMap { m -> String? in
                guard case .text(let s) = m.content, s.hasPrefix("── "), s.hasSuffix(" ──"),
                      !s.contains("收口") else { return nil }
                return s
            }
        }
        let tdSepsBefore = tdSeps()
        let tdTargetedSeps = tdSepsBefore.filter { $0.contains("由此 Dream") }
        check(tdTargetedSeps.count == 2,
              "P15.9 分隔行: 两次定向各留一行 —— 共用一条会话靠它数得清次数"
              + " (实测 \(tdSepsBefore.count) 行分隔, 其中定向 \(tdTargetedSeps.count) 行)")
        check(tdTargetedSeps.allSatisfy { $0.contains("「") && $0.contains("」") },
              "P15.9 分隔行: 每行都带**目标标题**（括号就是判据: 只剩「由此 Dream」四个字时, 只知道类型"
              + "却不知道对哪一场 —— 实测 [\(tdTargetedSeps.last ?? "无")])")
        check(tdTargetedSeps.allSatisfy { !$0.contains(ConversationTitle.defaultValue) },
              "P15.9 分隔行: 落库的是**恒中文**说法 —— 默认标题哨兵 `New chat` 不许原样进日志"
              + "（读 `title` 不读 `displayTitle`: 后者会 `L(\"新对话\")`, 同一条记录会随界面语言写出不同字节）")

        // ⚠️ 上面那两次 fire 的会话**没有标题**（走的是哨兵兜底）⇒ 三条判据只证明了"有括号"。
        //    真正要守的是"标题是**那一场自己的**"：换一场有标题的再跑一次, 把插值写成常量
        //    （永远吐「未命名会话」）的写法在这里**立刻红**。
        var tdTitled = tdItem
        tdTitled.title = "P159 目标会话"
        check(await waitUntil { td.runningTurns.isEmpty }, "P15.9 分隔行: 前两轮回合收干净")
        check(td.scheduler.runTargetedDream(tdTitled, stats: tdStats) == .started,
              "P15.9 分隔行 夹具: 有标题的那一场也起得来")
        check(tdSeps().last?.contains("「P159 目标会话」") == true,
              "P15.9 分隔行: 括号里是**那一场自己的标题**（实测 [\(tdSeps().last ?? "无")]）")

        // 反向面: 定时那一路仍然只写「运行」—— 两条路要**分得开**, 不是都改一个样。
        check(await waitUntil { td.runningTurns.isEmpty }, "P15.9 分隔行: 上一轮回合收干净")
        if let tdDreamTask = td.scheduledTasks.first(where: { SchedulerService.isDreamTask($0) }) {
            let tdCountBefore = tdSeps().count
            td.scheduler.runScheduledFire(tdDreamTask)
            let tdSepsAfter = tdSeps()
            check(tdSepsAfter.count == tdCountBefore + 1,
                  "P15.9 分隔行: 定时那轮**也**追加了一行 (实测 \(tdCountBefore) → \(tdSepsAfter.count))")
            check(tdSepsAfter.last?.hasSuffix("运行 ──") == true,
                  "P15.9 分隔行 反向: 定时写的是「运行」, 不带定向字样 (实测 [\(tdSepsAfter.last ?? "无")])")
            check(tdSepsAfter.filter { $0.contains("由此 Dream") }.count == 3,
                  "P15.9 分隔行 反向: 定时那行没被顺手改成定向的写法（三次定向仍是三行）")
        }
    }
}
