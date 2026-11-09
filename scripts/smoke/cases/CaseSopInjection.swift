//
//  CaseSopInjection.swift
//  P19: SOP 段（第二条注入通道）的纯函数判据。
//
//  ⚠️ 为什么这一段值得单开一个用例: 它是**唯一**能证明"模型真的被告知了怎么操作 App"的地方 ——
//     而它错了不会崩、不会红, 只会让模型拿着半份/错份手册去点按钮（不可逆）。
//     真机验证做不到"教错一份"这种判据（要点下去才知道）, 所以全靠这一层。
//
//  两组判据, 别混:
//    ① **组装**（①~⑫）: 传样本手册进 `block`, 把每种边界造出来（名单空 / 漏节 / 超预算 / 陈旧 / 档位）。
//    ② **本体**（⑬）: 直接盯 `SopManual.text` —— 它现在住在代码里、改一次要发一次版,
//       所以"写法"必须由门禁守, 不能靠写的人自觉（单节字数 / 任务线结构 / 覆盖白名单 / 不写编号 / 日期不造假）。
//

import Foundation

extension SmokeMain {

    /// 一节是不是写成了**任务线**: ≥2 个 `### 任务` 小标题, 且合计 ≥2 条编号步骤（`1. ` 这种）。
    ///
    /// ⚠️ 抽成函数, 为的是让**正例与反例走同一段逻辑**。反例若另写一份判定, 那一份会自己漂成
    ///    恒真 —— 而它恰恰是"上面那条不是恒真"的唯一证据（判据本身也可以是错的, 见 10-14 的教训）。
    static func isTaskLine(_ body: String) -> Bool {
        let tasks = body.components(separatedBy: "\n### ").count - 1
        let steps = body.components(separatedBy: "\n").filter {
            $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        }
        return tasks >= 2 && steps.count >= 2
    }

    @MainActor
    static func caseSopInjection() async {
        print("== T-SOP 应用手册注入 ==")

        let now = SopInjection.dayParser.date(from: "2026-11-02") ?? Date()

        /// 样本手册 = 通则 + 若干节（形状与 `SopManual.text` 同源, 但内容由本用例造）。
        func doc(_ sections: String) -> String {
            "**通则**：编号会变，先 read 再 act。\n" + sections
        }
        func section(_ title: String, _ bundle: String, _ version: String, _ body: String) -> String {
            "\n## \(title) · \(bundle) · \(version)\n\n" + body + "\n"
        }

        // ① 名单空 ⇒ 整段不出现（computer use 没开/没勾时, 一个字节都不该多）
        let empty = SopInjection.block(bundles: [], actBundles: [], now: now)
        check(empty.text == nil,
              "T-SOP 名单为空时整段不出现 (没开 computer use ⇒ 提示词里不许有手册)")

        // ①b 手册正文为空 ⇒ 同样不出现。生产上不可能（`SopManual.text` 是编译进二进制的常量,
        //    空的话 ⑬ 先红）, 但这一支是"上游给了空串"的唯一出口, 别让它拼出一个空段头。
        check(SopInjection.block(bundles: ["com.apple.Notes"], actBundles: [],
                                 manual: "", now: now).text == nil,
              "T-SOP 手册正文为空时整段不出现 (不许只出一个孤零零的段头)")

        // 一个正常的样本: 四节（正文写够长度, 后面预算判据才有确定边界）
        let filler = String(repeating: "细节。", count: 100)
        let sample = doc(
            section("备忘录", "com.apple.Notes", "4.11", "### 找\nfolder 在 outline。\n" + filler)
            + section("日历", "com.apple.iCal", "14.0", "### 找\n日历名住值里。\n" + filler)
            + section("提醒事项", "com.apple.reminders", "7.0", "### 找\n列表名住 cell 的 title。\n" + filler)
            + section("Chrome", "com.google.Chrome", "130", "### 找\n地址栏。\n" + filler))

        // ② 只注入名单内的, 顺序 = **手册里的顺序**（写的人把常用的放前面, 这个顺序
        //    本身就是优先级; 换成 bundle 排序的话, 超预算时掉哪一节是随机的）
        let two = SopInjection.block(bundles: ["com.apple.iCal", "com.apple.Notes"],
                                     actBundles: ["com.apple.Notes"], manual: sample, now: now)
        check(two.injected == ["com.apple.Notes", "com.apple.iCal"],
              "T-SOP 只注入名单内的小节, 顺序跟着手册走 (实际: \(two.injected))")
        check(!(two.text ?? "").contains("com.apple.reminders"),
              "T-SOP 名单外的 App 小节不许漏进来 (勾都没勾, 教了就是越权)")

        // ③ 节头必须写清**当前能不能点**: 它决定模型敢不敢 act
        let seg = two.text ?? ""
        check(seg.contains("备忘录 · com.apple.Notes · 可操作 · v4.11"),
              "T-SOP 节头写「可操作」+ 版本")
        check(seg.contains("日历 · com.apple.iCal · 只读"),
              "T-SOP 只有读权限的节头写「只读」 (写错 ⇒ 模型会去点一个点不动的东西)")

        // ④ 段头: token + 通则**只出现一次** + 整份验证日期
        check(seg.hasPrefix(SopInjection.token),
              "T-SOP 段以契约 token 开头 (\(SopInjection.token))")
        check(seg.components(separatedBy: "**通则**").count == 2,
              "T-SOP 通则只出现一次 (每节各带一遍 = 同一句话付 N 次 token)")
        // ⚠️ 判据从**真源**取日期, 不许在这里写一个字面量: 这条判的是"段头带不带日期",
        //    不是"日期是哪一天"。写死的话, 每次重跑探针 → 改 `verifiedOn` → 这条必红,
        //    而红的原因和它要守的东西毫无关系(2026-11-04 实测红过一次)。
        check(seg.contains("验证于 \(SopManual.verifiedOn)"),
              "T-SOP 段头带整份手册的验证日期 (实际: \(SopManual.verifiedOn))")

        // ⑤ 白名单: 第三方 App 就算手册里有那一节、名单里也勾了, 也不注入、不点名
        let third = SopInjection.block(bundles: ["com.google.Chrome"], actBundles: [],
                                       manual: sample, now: now)
        check(third.text == nil && third.missing.isEmpty,
              "T-SOP 第三方 App 不注入也不点名 (不在范围里, 点名会让模型去 read 一份不维护的手册)")
        let mixed = SopInjection.block(bundles: ["com.google.Chrome", "com.apple.Notes"],
                                       actBundles: [], manual: sample, now: now)
        check(mixed.injected == ["com.apple.Notes"],
              "T-SOP 名单里混着第三方 App 时只注入内置那几节 (实际: \(mixed.injected))")

        // ⑥ 白名单里有、手册里没那一节 = **两边不同步**（加了 App 忘了写手册）⇒ 必须点名
        //    ⚠️ 造"漏节"的 App 必须**白名单里有、样本里没有**: 曾用 reminders, 后来样本补上了它 ⇒
        //       `missing` 变空 ⇒ 这条立刻变红（不是静默, 比假绿好）。但红的原因与它守的东西无关,
        //       而最省事的"修法"是把断言删掉 —— 那就真的没有门了。所以换成 finder。
        let gap = SopInjection.block(bundles: ["com.apple.finder"], actBundles: [],
                                     manual: sample, now: now)
        check(gap.missing.contains { $0.bundle == "com.apple.finder" && $0.why.contains("没有这一节") },
              "T-SOP 手册漏了一节要点名 (否则「扩白名单」这个动作永远没有可见后果)")

        // ⑦ 节头的 bundle 认不出来 ⇒ 整节丢弃（不猜 —— 猜错就是把 A 的手册教给 B）
        let bad = SopInjection.block(bundles: ["com.apple.Notes"], actBundles: [],
                                     manual: doc("") + "\n## 某个 App\n\n### 找\n没有 bundle 的节。\n",
                                     now: now)
        check(!(bad.text ?? "").contains("没有 bundle 的节"),
              "T-SOP 节头写不出 bundle 的节要整节丢掉 (认不出归属就不能注入)")
        check(bad.injected.isEmpty && (bad.text ?? "").contains("没带上"),
              "T-SOP 丢了那一节之后仍要点名 (「手册里有节但认不出是谁的」对模型等于没有)")

        // ⑦b 一节挂**多个** App（浏览器那节, 2026-11-09）:
        //    ① 命中一个就整节注入; ② 正文只出一次; ③ 权限按 App 各写一次。
        //    ③ 是这三条里最要命的一条: 合成节里"一个能点、一个只读"是常态（两个名单各自独立）,
        //    节级徽章必然对着其中一个说谎 —— 模型要么去点点不动的东西, 要么放着能点的行不敢动。
        let oneOfPair = SopInjection.block(bundles: ["com.apple.Safari"], actBundles: [],
                                           manual: doc(section("浏览器",
                                                               "com.apple.Safari · com.google.Chrome",
                                                               "26.0.1 / 130",
                                                               "### 打开网址\n1. 带 url 打开。\n2. read 一次：标题变 = 成。")),
                                           now: now)
        check(oneOfPair.injected == ["com.apple.Safari"]
              && (oneOfPair.text ?? "").contains("浏览器 · com.apple.Safari · 只读"),
              "T-SOP 多 bundle 的节命中一个就整节注入, 节头只写**命中那个** App 的权限"
              + " (实际: \(oneOfPair.injected))")
        let twice = SopInjection.block(bundles: ["com.apple.Notes", "com.apple.iCal"],
                                       actBundles: ["com.apple.iCal"],
                                       manual: doc(section("两个",
                                                           "com.apple.Notes · com.apple.iCal", "1 / 2",
                                                           "### 甲\n1. 一步。\n2. 另一步。")),
                                       now: now)
        check(twice.injected == ["com.apple.Notes", "com.apple.iCal"],
              "T-SOP 两个 App 共用一节时两个都算注入 (少算一个 ⇒ 那个 App 会被点名「手册里没有这一节」, "
              + "而它的手册就在眼前。实际: \(twice.injected))")
        check((twice.text ?? "").components(separatedBy: "--- 两个").count == 2,
              "T-SOP 两个 App 共用一节时正文只出一次 (按 App 各出一遍 = 同一套步骤讲两遍, 白烧预算)")
        check((twice.text ?? "").contains("com.apple.Notes(只读) · com.apple.iCal(可操作)"),
              "T-SOP 多 bundle 的节权限按 App 各写一次 (节级徽章会对其中一个说谎)")

        // ⑧ 超预算: 逐节跳过 + 点名, 且**后面的小节不许钻空子**（截尾, 不是贪心填空）
        // 边界: 一节 ≈380 字（正文 300 + 节头），200 装不下一节、600 只装得下一节。
        let tiny = SopInjection.block(bundles: ["com.apple.Notes", "com.apple.iCal"],
                                      actBundles: [], manual: sample, now: now, budget: 200)
        check(tiny.injected.isEmpty && tiny.text != nil,
              "T-SOP 预算装不下一节时一节都不注入, 但仍要出段点名 (单节不截断: 半份手册会教错一步)")
        let partial = SopInjection.block(bundles: ["com.apple.iCal", "com.apple.Notes"],
                                         actBundles: [], manual: sample, now: now, budget: 600)
        check(partial.injected == ["com.apple.Notes"],
              "T-SOP 超预算时按手册顺序截尾, 后面的不钻空子 (实际: \(partial.injected))")
        check(partial.missing.contains { $0.why == "超预算" } && partial.text != nil,
              "T-SOP 超预算的那几节要点名, 且仍要出段 (模型不能因为「没看见」就以为「没有手册」)")

        // ⑨ 陈旧: 超过 30 天要**明说可能已经变了**, 但**不许**因此不注入
        //    P15 判据「陈旧 ≠ 错误」: 日期管陈旧, 探针管正确, 两条不许合述。
        let one = doc(section("备忘录", "com.apple.Notes", "4.11", "### 找\nfolder 在 outline。"))
        let stale = SopInjection.block(bundles: ["com.apple.Notes"], actBundles: [], manual: one,
                                       verifiedOn: "2026-09-01", now: now)
        check((stale.text ?? "").contains("可能已经变了") && stale.injected == ["com.apple.Notes"],
              "T-SOP 陈旧要标「可能已经变了」, 且仍然注入 (过期只是降级成提示, 不是删掉)")

        // ⑩ 没有验证日期 ⇒ 明说, 不许拿今天冒充
        let noDate = SopInjection.block(bundles: ["com.apple.Notes"], actBundles: [], manual: one,
                                        verifiedOn: "", now: now)
        check((noDate.text ?? "").contains("没写验证日期"),
              "T-SOP 缺验证日期时要如实说, 不许默认成今天 (默认成今天 = 造假)")

        // ⑪ codemode 那一段**跟着档位走**: 完整档没有 codemode 这个工具,
        //    教它写脚本 = 让它去调一个不存在的东西（白烧一轮, 而且零红灯）。
        let full = SopInjection.block(bundles: ["com.apple.Notes"], actBundles: [], manual: one,
                                      codemode: false, now: now)
        let code = SopInjection.block(bundles: ["com.apple.Notes"], actBundles: [], manual: one,
                                      codemode: true, now: now)
        check(!(full.text ?? "").contains("tools.computer_act"),
              "T-SOP 非 codemode 档不许教模型写脚本 (那一档没有这个工具)")
        check((code.text ?? "").contains("tools.computer_act"),
              "T-SOP codemode 档要教「act 的回执只给变化 + 新 seq」这条 (否则模型会为每一步多调一次 "
              + "read, 或者拿着平移前的编号去点)")
        check(code.chars > full.chars,
              "T-SOP codemode 段只在那个档里多出来 (实际 \(full.chars) → \(code.chars))")

        // ⑫ **手册本体** —— 手册住进代码之后, 这几条是它唯一的守门人。
        //     改一行手册不需要动任何逻辑, 所以没有任何别的东西会红。
        let manual = SopInjection.parse(SopManual.text)
        // 一节可以挂多个 App（浏览器）, 所以判据是**展平后**的集合: 数节数会把"两节并一节"
        // 误判成"少了一个 App 的手册"。
        let bundles = Set(manual.sections.flatMap(\.bundles))

        check(bundles == SopInjection.builtins,
              "T-SOP 手册恰好覆盖白名单那 \(SopInjection.builtins.count) 个 App、不多不少"
              + " (手册多出来的节永远不会被注入 = 死内容; 少一节 = 那个 App 没有手册。"
              + " 实际: \(bundles.sorted()))")

        // 同一个 App 出现在两节 = 后一节永远不会被注入（`block` 里的 `seen` 会挡掉）。
        // ⚠️ 这一条在"一节挂多个 bundle"之后才有意义: 节数已经不能代表 App 数了。
        let dup = Dictionary(grouping: manual.sections.flatMap(\.bundles), by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        check(dup.isEmpty,
              "T-SOP 同一个 App 不许写进两节 (第二节永远不会被注入 = 死内容; 两节还会各自漂。"
              + "实际重复: \(dup))")

        check(!manual.preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              "T-SOP 手册要有通则 (编号会变 / act 回执只给 diff 这两条对每个 App 都成立, 只写一次)")

        // 单节字数 + 结构: 每节必须写成**任务线**（`### 任务名` + 编号步骤）, 且必须有版本
        // —— 版本决定模型该不该照着做; 没有版本号 = 无法判断这节是不是上一个系统版本的界面。
        //
        // ⚠️ 2026-11-06 换过一次判据: 原来要求每节含 `### 找`（把知识按「找 / 做 / 成 / 别」四类切）。
        //    那个结构**不是 SOP** —— 同一件事的步骤被切碎分到四个抽屉里, 模型得自己拼一条路出来;
        //    更硬的一条: 「成」一个 App 只有一段, 可一个 App 有四五件事（备忘录那段的「成」
        //    其实只覆盖"删一条", 建一条 / 追加 / 打开都没有判据）。
        //    现在按**任务**切: 一条线 = 目标 + 编号步骤, 每步的判据跟在同一行后面。
        // 上限 = 整份预算的 1/5: 它的用处是"单个 App 不许吃掉大半预算", 不是"每节都必须短"。
        // ⚠️ 2026-11-09 从 700 提到 900: 浏览器那节要写「Safari 已验 / Chrome 要人先开
        //    accessibility」—— 那是**决策信息**, 砍掉它模型就会在 Chrome 的空壳上瞎点。
        let tooLong = manual.sections.filter { $0.body.count > 900 }.map { "\($0.title)=\($0.body.count)" }
        check(tooLong.isEmpty,
              "T-SOP 单节 ≤900 字 (每轮都进提示词; 超了就是写了没人要的东西。实际超: \(tooLong))")
        // 判据 = 这一节里 **≥2 个 `### 任务`**、且合计 **≥2 条编号步骤**。
        // 散文体 / 只有分类小标题的写法两条都过不了 —— 那正是"模型还得自己拼步骤"的样子。
        let notTaskLine = manual.sections.filter { !Self.isTaskLine($0.body) }.map(\.title)
        check(notTaskLine.isEmpty,
              "T-SOP 每节要写成任务线 (≥2 个 `### 任务` 且合计 ≥2 条编号步骤; 写成散文或"
              + "按知识分类切, 模型还得自己拼步骤。实际不合格: \(notTaskLine))")
        // 反例自证: 同一段判定喂它的**反面**必须判不合格, 否则上面那条对任何输入都返回空 = 恒真。
        // 用的正是被换掉的那种写法（一个 `###` 小标题 + 一段描述, 没有编号）—— 它曾经是四段结构的常态。
        check(!Self.isTaskLine("\n### 找\n- 左栏 outline：每个 cell 的 title 自带计数。\n"
                               + "- 分组行只有一个 statictext。"),
              "T-SOP 反例: 按知识分类切、没有编号步骤的写法必须判不合格 (否则上面那条是恒真的)")
        let noVersion = manual.sections.filter { $0.version.isEmpty }
            .map { $0.bundles.joined(separator: "+") }
        check(noVersion.isEmpty,
              "T-SOP 每节都要写 App 版本 (没有版本 ⇒ 无法判断这节是不是旧系统界面。实际缺: \(noVersion))")

        // 整份上限: 一个是"全都装得下"的绝对量级, 一个是运行时预算 —— 两条都要成立,
        // 否则 `block` 会在真机上**静默截尾**, 而这里是唯一能提前发现它的地方。
        check(SopManual.text.count <= 4500 && SopManual.text.count <= Tune.sopTotalCharLimit,
              "T-SOP 整份 ≤4500 字且在预算 \(Tune.sopTotalCharLimit) 内 (实际 \(SopManual.text.count) 字)")

        // 不许写具体编号: 编号每次 read 都变, 写死即过期数据（而且是**看起来最精确的**过期数据）
        check(SopManual.text.range(of: "#\\s*\\d", options: .regularExpression) == nil,
              "T-SOP 手册里不许出现具体编号 (`#7` 这种, 下次 read 就指向别的行了)")

        // 真注入量: 用**真手册 + 最宽的那一档**（六节全在 + codemode 段 + 日期行）直接量,
        // 而不是"手册字数 + 猜一个段头大小"。⚠️ `block` 的 `budget` 只卡各节, 段头是固定成本 ——
        // 所以"总字数在预算内"这条**只能**在这里断言, 别处推不出来。
        let widest = SopInjection.block(bundles: Array(SopInjection.builtins),
                                        actBundles: Array(SopInjection.builtins),
                                        codemode: true, now: now)
        check(widest.injected.count == SopInjection.builtins.count && widest.missing.isEmpty,
              "T-SOP 真手册在最宽一档下白名单里的节全都要进、一条都不许掉 (实际进 "
              + "\(widest.injected.count)/\(SopInjection.builtins.count) 节, "
              + "没带上 \(widest.missing))")
        check(widest.chars <= Tune.sopTotalCharLimit,
              "T-SOP 真注入量(含段头) ≤ 预算 \(Tune.sopTotalCharLimit) (实际 \(widest.chars) 字; "
              + "手册本体 \(SopManual.text.count) + 段头 \(widest.chars - SopManual.text.count))")
        check(widest.chars > SopManual.text.count,
              "T-SOP 段头真的是段头 (总字数必须大于手册本体, 否则上面那条比的是空集)")

        // 验证日期不许造假: 必须能解析, 且不在未来。
        // ⚠️ 两处刻意松, 都是为了不给**时区**判红(实测 `TZ=America/New_York`, 2026-11-05 03:00Z):
        //    ① 判的是**日历日**而不是时刻 —— `dayParser` 解出来是本地 00:00, 拿它比 `Date()`
        //       等于要求"今天已经过了零点之后才能写今天的日期";
        //    ② 还留 **1 天**余量 —— 日期字段不带时区, 作者那台机器的"今天"可以比这台早一天
        //       (纽约 11-04 22:19 时, 手册写 11-05 是"明天")。这条判据要拦的是**明显造假**
        //       (写成下个月去躲「陈旧」提示), 不是时差。
        let verified = SopInjection.dayParser.date(from: SopManual.verifiedOn)
        check(verified != nil,
              "T-SOP 手册的验证日期要能解析成 yyyy-MM-dd (实际: \(SopManual.verifiedOn))")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)
        check(verified.map { cal.startOfDay(for: $0) <= (tomorrow ?? today) } ?? false,
              "T-SOP 验证日期不许在未来 (按日历日比、留 1 天时区余量; 写成下个月那种 = 造假, "
              + "而且是最没人会去核的一种)")
    }
}
