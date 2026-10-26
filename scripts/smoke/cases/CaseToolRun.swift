//
//  CaseToolRun.swift
//  已完成对话组里「两段正文之间」的工具段折叠 (2026-10-20)。
//
//  为什么这些断言必须有: 分段的边界与可折条件是纯逻辑, 写错**不会报错**,
//  只会安静地把不该折的折了 —— 最典型的两条:
//    · 把 `.think` 当边界 ⇒ Codex 式回合里每段只剩 1 条 ⇒ 功能静默失效（看上去"上线了"）;
//    · 不检查相态就折 ⇒ 折掉一条 error, 让人以为这组干干净净。
//  两种都不会让编译或界面变形, 只能靠断言钉住。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseToolRun() async {
        print("== T-TOOLRUN 工具段折叠 ==")

        func toolMsg(_ title: String,
                     _ kind: ToolKind = .bash,
                     _ phase: ToolPhase = .done,
                     _ ms: Int? = 100) -> ChatMessage {
            ChatMessage(role: .assistant,
                        content: .tool(ToolCall(kind: kind, title: title, phase: phase, durationMs: ms)))
        }
        func textMsg(_ s: String = "说的这句") -> ChatMessage {
            ChatMessage(role: .assistant, content: .text(s))
        }
        func thinkMsg(_ s: String = "想一下") -> ChatMessage {
            ChatMessage(role: .assistant, content: .think(s))
        }
        /// 单数组 = 「整个会话」⇒ `attached` 由这批消息自己派生（与 `ChatView` 同一个函数）。
        ///
        /// ⚠️ 生产里传进来的是**一组**、`attached` 来自**整个会话**；这里两者同源，是因为
        ///    夹具数组本来就装着父卡和子卡。要测"父卡不在本组"的跨组情形，别用它 ——
        ///    直接调 `ToolRunBuilder.runs(in:attached:)` 显式给一份 `attached`（见 ⑬）。
        func runs(_ m: [ChatMessage]) -> [ToolRun] {
            ToolRunBuilder.runs(in: m, attached: ToolNesting.attachedToolIds(in: m))
        }

        // ① 正文是边界: 2 条 / 正文 / 1 条 ⇒ 两段
        let a = [toolMsg("a1"), toolMsg("a2"), textMsg(), toolMsg("b1")]
        let runsA = runs(a)
        check(runsA.count == 2, "T-TOOLRUN 正文切段 ⇒ 2 段 (实测 \(runsA.count))")
        check(runsA.first?.count == 2, "T-TOOLRUN 第一段 2 条 (实测 \(runsA.first?.count ?? -1))")
        check(runsA.last?.count == 1, "T-TOOLRUN 第二段 1 条 (实测 \(runsA.last?.count ?? -1))")

        // ② `.think` **不是**边界 —— 这条翻红就说明有人把思考当成了"解说"
        let b = [toolMsg("a1"), thinkMsg(), toolMsg("a2")]
        check(runs(b).count == 1,
              "T-TOOLRUN 思考不切段 (think 与 tool 属于同一次执行)")
        check(runs(b).first?.count == 2,
              "T-TOOLRUN 被思考隔开的两条工具仍在同一段")

        // ③ 计划卡 / 压缩标记是边界
        let plan = PlanQuestion(title: "选哪个?", options: [])
        let c = [toolMsg("a1"), ChatMessage(role: .assistant, content: .plan(plan)), toolMsg("b1")]
        check(runs(c).count == 2, "T-TOOLRUN 计划卡切段")
        let d = [toolMsg("a1"),
                 ChatMessage(role: .system,
                             content: .compaction(tokensBefore: 10, tokensAfter: 5, reason: "manual")),
                 toolMsg("b1")]
        check(runs(d).count == 2, "T-TOOLRUN 压缩标记切段")

        // ④ 成员 id = **消息** id（不是工具 id）, 含段首、时间序连续
        let e = [toolMsg("a1"), toolMsg("a2")]
        if let run = runs(e).first {
            check(run.id == e[0].id, "T-TOOLRUN 段 id = 段首消息 id")
            check(run.memberIds == [e[0].id, e[1].id],
                  "T-TOOLRUN 成员 id 是消息 id 且保持时间序")
            // ⚠️ 2026-10-26: `memberIds` 装**全部**成员消息（含内层），`count` 只数顶层
            // ⇒ 两者只在没有内层的段上相等。别再把"相等"当成不变量。
            check(run.memberIds.count == run.count + run.nested.count,
                  "T-TOOLRUN 成员数 = 顶层工具 + 内层工具")
        } else {
            check(false, "T-TOOLRUN 两条工具应成一段")
        }

        // ⑤ 可折条件
        check(runs(e).first?.foldable == true, "T-TOOLRUN 2 条全 done ⇒ 可折")
        let single = [toolMsg("a1")]
        check(runs(single).first?.foldable == false,
              "T-TOOLRUN **1 条不可折** (23pt → 22pt, 省 1pt 却多一次点击)")
        let withErr = [toolMsg("a1"), toolMsg("a2", .bash, .error("exit 1"))]
        check(runs(withErr).first?.foldable == false,
              "T-TOOLRUN 含 error ⇒ 不可折 (失败不许自己缩回, 新机制不许旁路)")
        let withRun = [toolMsg("a1"), toolMsg("a2", .bash, .running)]
        check(runs(withRun).first?.foldable == false,
              "T-TOOLRUN 含 running ⇒ 不可折")
        let withAppr = [toolMsg("a1"), toolMsg("a2", .bash, .awaitingApproval)]
        check(runs(withAppr).first?.foldable == false,
              "T-TOOLRUN 含待审 ⇒ 不可折 (要人拍板的东西不能藏)")

        // ⑥ 类型分布按**首次出现**排序（同一批数据重放两次必须同序, 否则收据会跳字）
        let f = [toolMsg("x", .read), toolMsg("y", .bash), toolMsg("z", .read)]
        let kinds = runs(f).first?.kindCounts ?? []
        check(kinds.count == 2, "T-TOOLRUN 两种类型 (实测 \(kinds.count))")
        check(kinds.first?.kind == .read && kinds.first?.count == 2,
              "T-TOOLRUN 首次出现的类型排前面, 且计数正确")
        check(kinds.last?.kind == .bash, "T-TOOLRUN 后出现的类型排后面")

        // ⑦ 耗时口径与 `ToolCallCardView.phaseBadge` 一致: 求和, ≥1s 换成 x.xs
        let g = [toolMsg("a1", .bash, .done, 800), toolMsg("a2", .bash, .done, 400)]
        let run = runs(g).first
        check(run?.totalMs == 1200, "T-TOOLRUN 耗时求和 (实测 \(run?.totalMs ?? -1))")
        check(run?.durationText == "1.2s", "T-TOOLRUN ≥1s 显示 x.xs (实测 \(run?.durationText ?? "nil"))")
        let h = [toolMsg("a1", .bash, .done, 420)]
        check(runs(h).first?.durationText == "420ms", "T-TOOLRUN <1s 显示毫秒")
        let i = [toolMsg("a1", .bash, .done, nil), toolMsg("a2", .bash, .done, nil)]
        check(runs(i).first?.durationText == nil,
              "T-TOOLRUN 全部无耗时 ⇒ 不显示 (不猜 0ms)")

        // ⑧ 真实序列复现（2026-10-20 boss 截图）: 段中间夹着 `.think` ⇒ 仍是一个段,
        //    而且 `span` 必须**覆盖**那几条 think（boss 追加: 正文之间的一切都收,
        //    所以段首那条 think 也归这一段）。视图层按 span 前进, 按成员条数跳会跳少一格,
        //    症状是最后一条工具"既算进收据、又单独画一行"（看着像漏了工具, 其实是重复）。
        let real: [ChatMessage] = [
            ChatMessage(role: .user, content: .text("thinking 默认开，使用 --no-thinking 关闭")),
            thinkMsg(),
            toolMsg("grep"), toolMsg("edit", .edit), toolMsg("bash"),
            thinkMsg(),
            toolMsg("bash"),
            textMsg("改完了，桩跑验证通过。"),
        ]
        let realRuns = runs(real)
        check(realRuns.count == 1, "T-TOOLRUN 真实序列只成 1 段 (实测 \(realRuns.count))")
        check(realRuns.first?.count == 4, "T-TOOLRUN 真实序列 4 个工具 (实测 \(realRuns.first?.count ?? -1))")
        check(realRuns.first?.span == 1..<7,
              "T-TOOLRUN span 从段首思考起、覆盖中间 think (期望 1..<7, 实测 \(String(describing: realRuns.first?.span)))")
        check(realRuns.first?.span.count == 6 && realRuns.first?.memberIds.count == 4,
              "T-TOOLRUN span 占 6 行 > 成员 4 条 ⇒ 只许按 span 跳行")
        check(realRuns.first?.thinkCount == 2, "T-TOOLRUN 段内 2 段思考 (实测 \(realRuns.first?.thinkCount ?? -1))")

        // ⑨ 纯空白正文不作边界（空串如果算边界, 会被切成"4 条 + 1 条", 那条又不折 ⇒ 像漏了一条）
        let blank = [toolMsg("a1"), textMsg("   \n"), toolMsg("a2")]
        check(runs(blank).count == 1,
              "T-TOOLRUN 纯空白正文不作边界 (实测 \(runs(blank).count) 段)")

        // ⑩ 只有思考、没有工具 ⇒ **也产出段, 也可折**。
        //    2026-10-20 boss 截图纠正: 一屏里第一段是裸露的 `Reasoning`、后面每段都是收据 ⇒
        //    "看着像漏了一行没折"。规则是"正文之间的一切都收", 没有例外。
        //    ⚠️ 收益不是高度（两边都是一行）, 是**形态统一**; 所以这里断言的是 foldable 与 count,
        //    不是"省了多少 pt"—— 后者永远为 0, 写成断言会把人误导到别处去优化。
        let onlyThink = [thinkMsg(), thinkMsg()]
        let onlyRuns = runs(onlyThink)
        check(onlyRuns.count == 1, "T-TOOLRUN 纯思考段也产出 (实测 \(onlyRuns.count) 段)")
        check(onlyRuns.first?.count == 0, "T-TOOLRUN 纯思考段工具数 0 (实测 \(onlyRuns.first?.count ?? -1))")
        check(onlyRuns.first?.thinkCount == 2, "T-TOOLRUN 纯思考段思考数 2 (实测 \(onlyRuns.first?.thinkCount ?? -1))")
        check(onlyRuns.first?.foldable == true, "T-TOOLRUN 纯思考段可折 (一律收, 不设门槛)")
        check(onlyRuns.first?.span == 0..<2, "T-TOOLRUN 纯思考段 span 覆盖全部思考")

        // ⑪ 思考让"单条工具"变得值得折: span 2 行 vs 一行收据
        let toolAndThink = [toolMsg("a1"), thinkMsg()]
        check(runs(toolAndThink).first?.foldable == true,
              "T-TOOLRUN 1 工具 + 1 思考 ⇒ 可折 (占 2 行)")

        // ⑫ 内层调用（codemode 脚本里的 `tools.bash(...)`）**不出可见行** ⇒ 计数与相态要分开算。
        //    2026-10-26: 一条 codemode + 2 条内层，屏上只有 1 行 —— 若按 `span.count` 判会以为
        //    "3 行值得折"，实际折起来省 0pt 还多一次点击（正是 ⑪ 反面 / 2026-10-20 那条"1 条不折"）。
        let cm = ToolCall(kind: .codemode, title: "script", phase: .done, durationMs: 84)
        func nested(_ t: String, _ phase: ToolPhase = .done) -> ChatMessage {
            ChatMessage(role: .assistant,
                        content: .tool(ToolCall(kind: .bash, title: t, phase: phase,
                                                durationMs: 5, parentId: cm.id)))
        }
        let onlyNested: [ChatMessage] = [
            ChatMessage(role: .assistant, content: .tool(cm)), nested("a"), nested("b"),
        ]
        let onlyRun = runs(onlyNested).first
        check(onlyRun?.count == 1, "T-TOOLRUN 内层不算进「N 次工具调用」(实测 \(onlyRun?.count ?? -1))")
        check(onlyRun?.span.count == 3, "T-TOOLRUN span 仍覆盖内层行 (视图层按 span 前进)")
        check(onlyRun?.foldable == false,
              "T-TOOLRUN 1 条顶层 + 2 条内层 ⇒ **不可折** (屏上只有 1 行, 折了纯亏)")
        let mixed: [ChatMessage] = [
            ChatMessage(role: .assistant, content: .tool(cm)), nested("a"), nested("b"),
            toolMsg("c"), toolMsg("d"),
        ]
        if let run = runs(mixed).first {
            check(run.count == 3, "T-TOOLRUN 3 条顶层 (codemode + c + d), 内层不算 (实测 \(run.count))")
            check(run.foldable == true, "T-TOOLRUN 3 条顶层 + 2 条内层 ⇒ 可折")
            check(run.totalMs == 284, "T-TOOLRUN 耗时只算顶层 (实测 \(run.totalMs), 内层被父卡包着不重复计)")
            check(run.nested.count == 2, "T-TOOLRUN 内层单独一栏 (实测 \(run.nested.count))")
        } else {
            check(false, "T-TOOLRUN 顶层 + 内层混排应成一段")
        }
        // 内层出事时父卡会替它亮红；这一段若被折进收据，那次失败在界面上就消失了。
        let nestedErr: [ChatMessage] = [
            ChatMessage(role: .assistant, content: .tool(cm)), nested("a"), nested("b", .error("exit 1")),
            toolMsg("c"), toolMsg("d"),
        ]
        check(runs(nestedErr).first?.foldable == false,
              "T-TOOLRUN 内层有 error ⇒ 不可折 (折了 = 那次失败在界面上消失)")

        // ⑬ 判据必须来自**传入的 `attached`**，不是本组消息 —— 2026-10-26 audit ③。
        //    "父卡不在本组"是真会发生的：压缩在轮中插了 `.system`（它自成一组）、老会话只留半截
        //    （父卡那条消息被截掉）。那样的组里只剩子行。`ChatView` 按**会话级**的表已经把
        //    这些行摘掉了；builder 若按本组现算，就会把它们数成"看得见的一行" ⇒ 收据上的
        //    「N 次工具调用」与屏上的行数对不上，而两边都不报错。同一个判据只许一个来源。
        let orphanKids = [nested("a"), nested("b")]
        let kidIds = orphanKids.compactMap { m -> UUID? in
            if case .tool(let t) = m.content { return t.id }
            return nil
        }
        check(kidIds.count == 2, "T-TOOLRUN 夹具: 两条子卡的 id 取到了")
        // 反例口径 = 改前那版"自己按本组消息现算"（等价于 attached 给空集）。
        let guessed = ToolRunBuilder.runs(in: orphanKids, attached: [])
        let shared = ToolRunBuilder.runs(in: orphanKids, attached: Set(kidIds))
        check(guessed.first?.count == 2,
              "T-TOOLRUN 反例: 不给 attached ⇒ 子卡被当成顶层行计进收据 (实测 \(guessed.first?.count ?? -1))")
        check(shared.first?.count == 0,
              "T-TOOLRUN 会话级 attached ⇒ 子卡不进「N 次工具调用」(实测 \(shared.first?.count ?? -1))")
        check(shared.first?.nested.count == 2,
              "T-TOOLRUN 子卡仍单列一栏 (实测 \(shared.first?.nested.count ?? -1))")
        check(shared.first?.span.count == 2, "T-TOOLRUN span 照样覆盖子行 (视图层按它前进)")
        check(shared.first?.foldable == false,
              "T-TOOLRUN 屏上一行都没有 ⇒ 不可折 (0 顶层 + 0 思考)")
    }
}
