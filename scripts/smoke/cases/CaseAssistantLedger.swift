//
//  CaseAssistantLedger —— P19.2 S8: 助理工作日志的五节账本 + 三态 + 注入报字数
//
//  为什么这一层要立判据（docs/P19 §03「工作日志 vs Cron 交接文件」）：
//    账本不是给人看的排版，它是「无目标 → 在追 → 完成 → 回无目标」这条回路的**唯一判据**。
//    它错一格，表现全部是静默的：
//      ① 三态判错 ⇒ 助理永远在追一个早已结束的目标（或者刚做完就判「没达成」）；
//      ② 归档混进判定 ⇒ 压缩归档（删旧行）会顺手改掉「完成没完成」；
//      ③ 「没写完成状态」被读成「完成」⇒ 一份空账本让助理当场收工；
//      ④ 符号/大小写不认 ⇒ 模型写得没错，人看到的是「进度退了」；
//      ⑤ 节头按前缀认 ⇒ 「目标达成了三条」顶掉真目标，而所有计数照样有理有据；
//      ⑥ 压缩归档 ⇒ 判定翻面（这一条是 ② 的量化版，必须真跑一次压缩）。
//
//  ⚠️ 三态这条是**设计级**的：旧写法 `isComplete = 验收项非空 && 全达成` 在加了归档之后会翻面 ——
//  做完的事被移进归档 ⇒ `items` 变空 ⇒ 旧定义把「刚做完」判成「没达成」。
//
//  反例（2026-11-17 实测）：
//    · `stage` 把 `items.isEmpty` 那行删掉 ⇒ ① 红（空账本读成完成）；
//    · `isPlaceholder` 去掉「无」 ⇒ ①第二格红（「在跟踪: 无」被算成一条在跟踪 ⇒ 永远到不了 done）；
//    · `flatHeads` 不按长度降序 ⇒ ⑤b 红（`已完成（归档）` 被 `已完成` 抢走，归档多出一条「（归档）」）；
//    · `head` 改成只按前缀认 ⇒ ⑤a 红；
//    · `watchSystemPrompt` 报 `h.utf8.count` ⇒ 注入那两条红（中文一字三字节）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseAssistantLedger() async {
        let dir = fixtureDir("p19ledger")

        // 一份「在追」的账本：契约里点名的五节全在，验收项两达成一未达成。
        let tracking = """
        ## 目标
        保证 CI 是绿的，失败当天必须有人知道。
        ## 完成状态
        - [x] flaky 用例定位
        - [x] 时区问题修掉
        - [ ] nightly 稳定性跑满两周
        ## 在跟踪
        - nightly 已连跑 9 天
        ## 待你决定
        - 换 runner 要不要先跑一周对比
        ## 已完成（归档）
        - 2026-11-17 修好 CI：根因是时区写死
        """
        let t = AssistantLedger.parse(tracking)
        check(t.goal == "保证 CI 是绿的，失败当天必须有人知道。",
              "T-LEDGER 目标节取首行（\(t.goal.prefix(12))…）")
        check(t.items.count == 3 && t.doneCount == 2 && t.openCount == 1,
              "T-LEDGER 验收三项 · 达成 \(t.doneCount) · 未达成 \(t.openCount)")
        check(t.tracking.count == 1 && t.waiting.count == 1,
              "T-LEDGER 在跟踪 \(t.tracking.count) 条 · 待你决定 \(t.waiting.count) 条")
        check(t.archived == ["2026-11-17 修好 CI：根因是时区写死"],
              "T-LEDGER 归档条数 = 1（\(t.archived.count)）")
        check(t.stage == .tracking && !t.isComplete,
              "T-LEDGER ① 有未达成项 ⇒ `.tracking`")

        // —— ① 三态各一格 ——
        // (a) 没有验收项、没有在跟踪 ⇒ 无目标。**「在跟踪: 无」是占位，不是一条在跟踪** ——
        //     漏认它的后果不是难看：目标永远推进不到 `.done`（这条我第一版就写错了）。
        let blank = AssistantLedger.parse("""
        ## 目标
        等人给指令
        ## 完成状态
        ## 在跟踪
        无
        ## 待你决定
        无
        """)
        check(blank.stage == .empty && !blank.isComplete,
              "T-LEDGER ①a 空账本 ⇒ `.empty`，且**不许**读成完成（tracking=\(blank.tracking.count)）")
        check(blank.tracking.isEmpty && blank.waiting.isEmpty,
              "T-LEDGER ①a 「无」是占位、不是一条在跟踪（漏认 ⇒ 永远到不了 done）")
        check(AssistantLedger.parse("").stage == .empty,
              "T-LEDGER ①a 空串（文件不存在）⇒ `.empty`")
        // (b) 全部达成 + 在跟踪为空 ⇒ 完成
        let finished = AssistantLedger.parse("""
        ## 目标
        把上线做完
        ## 完成状态
        - [x] 灰度
        - [x] 全量
        ## 在跟踪
        无
        """)
        check(finished.stage == .done && finished.isComplete,
              "T-LEDGER ①b 全达成 + 在跟踪空 ⇒ `.done`")
        // (c) 全达成但**还在跟踪** ⇒ 不算完（「清单做完了，事还没完」是常态）
        let draining = AssistantLedger.parse("""
        ## 完成状态
        - [x] 灰度
        ## 在跟踪
        - 观察 24 小时
        """)
        check(draining.stage == .tracking && !draining.isComplete,
              "T-LEDGER ①c 验收项全达成但**在跟踪非空** ⇒ 仍在追（清单完了 ≠ 事完了）")

        // —— ② 归档不参与任何判定 ——
        // 判据不是「归档字段有值」，而是**同一份账本加上归档之后，三态与计数一个都不变**。
        let withArchive = AssistantLedger.parse(tracking.replacingOccurrences(
            of: "- 2026-11-17 修好 CI：根因是时区写死",
            with: "- 2026-11-17 修好 CI：根因是时区写死\n- 2026-11-10 加了下班告警"))
        check(withArchive.stage == t.stage && withArchive.items == t.items
              && withArchive.tracking == t.tracking && withArchive.waiting == t.waiting,
              "T-LEDGER ② 归档多一条，三态与三个计数全不变（归档只显示、不判定）")
        check(withArchive.archived.count == 2,
              "T-LEDGER ② 归档确实多了一条（\(withArchive.archived.count)）—— 上一格不是假绿")

        // —— ③ 没写「完成状态」⇒ `.empty`，而不是 `.done` ——
        // 这是最危险的一格：模型偶尔会漏掉一节。漏了还判完成 ⇒ 助理当场收工，
        // 而人只看到「它说做完了」。归档有内容也不能把它拉成 done。
        let missing = AssistantLedger.parse("""
        ## 目标
        守住院里的发布
        ## 已完成（归档）
        - 2026-11-01 上一件事收尾了
        """)
        check(missing.stage == .empty && !missing.isComplete,
              "T-LEDGER ③ 只有目标 + 归档、没有完成状态 ⇒ `.empty`（**不是**完成；归档拉不动判定）")
        check(missing.archived.count == 1,
              "T-LEDGER ③ 归档还是读出来了（\(missing.archived.count) 条 —— 判定与显示分开）")

        // —— ④ 符号 / 大小写容错 ——
        // 模型写得没错、程序不认，代价是「进度退了」。契约点名 ASCII，符号只做容错。
        let symbols = AssistantLedger.parse("""
        ## 完成状态
        - [X] 大写 X
        - ☑ 勾选符
        - ⬜ 空心方
        - ⏸ 卡住了
        - [x] 正常
        """)
        check(symbols.doneCount == 3, "T-LEDGER ④ `[X]` / `☑` 都算达成（实际 \(symbols.doneCount)）")
        check(symbols.blockedCount == 1, "T-LEDGER ④ `⏸` 算卡住（实际 \(symbols.blockedCount)）")
        check(symbols.items.count == 5,
              "T-LEDGER ④ 五项全进（认不出标记的行**不算验收项** ⇒ 会静默少一项，实际 \(symbols.items.count)）")
        let junk = AssistantLedger.parse("""
        ## 完成状态
        - [~] 认不出的标记
        - 光秃秃一行
        """)
        check(junk.items.isEmpty,
              "T-LEDGER ④ 认不出标记 ⇒ 不算验收项（宁可少一条，也不替它决定达成没达成）")

        // —— ⑤ 节头严格 ——
        // (a) 只按前缀认的话，`目标达成了三条` 会被当成「目标」节头 ⇒ 真目标被顶掉，计数照样对。
        let prefixTrap = AssistantLedger.parse("""
        ## 在跟踪
        - 推进 A
        在跟踪 的事有三件
        - 推进 B
        """)
        check(prefixTrap.tracking.count == 3,
              "T-LEDGER ⑤a 「在跟踪 的事有三件」当**正文**读（若当节头 ⇒ 2 条，实际 \(prefixTrap.tracking.count)）")
        // (b) 长别名的落点。**守卫是 `head` 的「整行等值/紧跟冒号」，不是表的顺序** ——
        // 实测: 把 `已完成` 挪到最前并删掉排序，这一格仍是绿的（所以别把它的红归因到排序上）。
        let archiveHead = AssistantLedger.parse("""
        ## 已完成（归档）
        - 2026-11-17 修好 CI
        """)
        check(archiveHead.archived == ["2026-11-17 修好 CI"],
              "T-LEDGER ⑤b `已完成（归档）` 吃掉整行（被 `已完成` 抢走会多出一条「（归档）」：\(archiveHead.archived)）")
        check(AssistantLedger.parse("## 已完成\n- 老写法也认").archived.count == 1,
              "T-LEDGER ⑤b 老节名 `已完成` 仍然认（兼容前向版本写下的账本）")

        // —— ⑥ 压缩归档后判定不变 ——
        // 这是 ② 的量化版：真的删掉 22 行再比一次。不跑这一格的话，「压缩会翻面」只是推理。
        let manyArchive = (0..<25).map { "- 2026-11-\(String(format: "%02d", $0 + 1)) 旧事项 \($0 + 1)" }
        func ledger(_ archive: [String]) -> String {
            """
            ## 目标
            守住院里的发布
            ## 完成状态
            - [x] 灰度
            - [x] 全量
            ## 在跟踪
            无
            ## 已完成（归档）
            """ + "\n" + archive.joined(separator: "\n")
        }
        let before = AssistantLedger.parse(ledger(manyArchive))
        let after = AssistantLedger.parse(ledger(Array(manyArchive.suffix(WatchFindingService.archivedKeep))))
        check(before.archived.count == 25 && after.archived.count == WatchFindingService.archivedKeep,
              "T-LEDGER ⑥ 归档 25 → \(WatchFindingService.archivedKeep) 条（夹具真的被压缩了）")
        check(before.stage == .done && after.stage == .done
              && before.items == after.items && before.goal == after.goal,
              "T-LEDGER ⑥ 压缩归档后三态与验收项**一个都不变**（删旧记忆不该改判定）")

        // —— brief：三态各自那句话 ——
        // 它是台账（S13）与催促（S14）要显示的那一行。S8 还没人消费它，但语义现在就得钉:
        // 「全部完成后回无目标」这句产品要求，落点正是 `.empty` 的 brief —— 它必须**明说无目标**，
        // 而不是只说「历史归档 3 条」（那样人以为还有事在追）。
        check(blank.brief.contains("当前无目标"),
              "T-LEDGER brief① 空账本 ⇒ 明说「当前无目标」（\(blank.brief)）")
        check(finished.brief.contains("全部达成"),
              "T-LEDGER brief② 完成 ⇒ 说「全部达成」并指出该收尾（\(finished.brief)）")
        check(t.brief.contains("已达成 2") && t.brief.contains("未达成 1"),
              "T-LEDGER brief③ 在追 ⇒ 报已达成 / 未达成两个数（\(t.brief.replacingOccurrences(of: "\n", with: "⏎"))）")
        check(t.brief.contains("在等你决定 1 件"),
              "T-LEDGER brief③ 有待你决定的事必须在 brief 里露头（催促 S14 就靠这一句）")

        // —— 注入：报字数 ——
        // ⚠️ 模型看不见自己那份账本多大。只在契约里写「允许压缩」是一句空话 ——
        // 这两格钉的是「报的数 = 真实字数」：用中文夹具，`utf8.count` 会是三倍。
        let cn = String(repeating: "字", count: 7)
        let short = SchedulerService.watchSystemPrompt(
            project: nil, handoff: cn, snapshot: WatchSnapshot(outcomes: []))
        check(short.contains("【账本容量】当前 \(cn.count) 字 / 上限 \(WatchFindingService.handoffMaxChars)"),
              "T-LEDGER 注入① 报的是**字符数** \(cn.count)（报 utf8 会是 \(cn.utf8.count)）与真实上限")
        check(short.contains("这一轮不用管"),
              "T-LEDGER 注入① 未过水位 ⇒ 不喊压缩（天天喊 = 噪音，真到水位就不听了）")
        let fat = String(repeating: "字", count: WatchFindingService.handoffCompactThreshold + 1)
        let fatSys = SchedulerService.watchSystemPrompt(
            project: nil, handoff: fat, snapshot: WatchSnapshot(outcomes: []))
        check(fatSys.contains("当前 \(fat.count) 字")
              && fatSys.contains("已超过 \(WatchFindingService.handoffCompactThreshold) 字")
              && fatSys.contains("压缩到最近 \(WatchFindingService.archivedKeep) 条"),
              "T-LEDGER 注入② 报的是**字符数** \(fat.count)（utf8 会是 \(fat.utf8.count)）"
              + " · 过水位 ⇒ 明确要求压缩归档到 \(WatchFindingService.archivedKeep) 条")
        check(fatSys.contains("其余四节一个字都不要删"),
              "T-LEDGER 注入② 压缩只许动归档节（删到「待你决定」= 把要人拍板的事删了）")
        let emptySys = SchedulerService.watchSystemPrompt(
            project: nil, handoff: nil, snapshot: WatchSnapshot(outcomes: []))
        check(!emptySys.contains("【账本容量】"),
              "T-LEDGER 注入③ 空账本不报字数（没有可压缩的东西，多一句只是噪音）")

        // —— 反向门：Cron 档一字不动 ——
        // S8 改了 `handoffMaxChars`（4000 → 16000），那是**助理巡检轮**的上限；
        // Cron 的交接文件是模型自己 write 的、不走 `WatchFindingService.plan`，所以不受影响 ——
        // 但「不受影响」必须是测出来的，不是推的。
        let store = ChatStore(transport: MockTransport(), dbPath: dir + "/p19ledger.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: dir, items: []))
        var cron = ScheduledTask(id: UUID(), name: "旧 cron", prompt: "每日巡检",
                                 cron: "0 9 * * *", projectId: projId)
        cron.continuous = true
        cron.kind = .execute
        let cronPrompt = store.scheduler.buildScheduledPrompt(cron)
        let expected = "【本次指令】\n每日巡检\n\n"
            + "请在了解此前执行情况的基础上继续本次任务, 并在结束后把关键进展、当前状态与待办更新写入交接文件: "
            + store.scheduler.handoffPath(for: cron)
        check(cronPrompt == expected,
              "T-LEDGER Cron① `buildScheduledPrompt` **逐字节**等于改动前（实测 \(cronPrompt.count) 字）\n"
              + "        实际: \(cronPrompt.replacingOccurrences(of: "\n", with: "⏎"))")
        check(!cronPrompt.contains("## 完成状态") && !cronPrompt.contains("## 已完成")
              && !cronPrompt.contains("【账本容量】") && !cronPrompt.contains("## 目标"),
              "T-LEDGER Cron② 交接文件的 prompt 里**没有**账本五节（助理的账本是助理的，Cron 格式自由）")
        var plain = ScheduledTask(id: UUID(), name: "一次性", prompt: "跑一下",
                                  cron: "0 9 * * *", projectId: nil)
        plain.continuous = false
        plain.kind = .execute
        check(store.scheduler.buildScheduledPrompt(plain) == "跑一下",
              "T-LEDGER Cron③ 非持续任务的 prompt 原样（一个前缀都不加）")
    }
}
