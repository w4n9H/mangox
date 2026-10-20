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

        // ① 正文是边界: 2 条 / 正文 / 1 条 ⇒ 两段
        let a = [toolMsg("a1"), toolMsg("a2"), textMsg(), toolMsg("b1")]
        let runsA = ToolRunBuilder.runs(in: a)
        check(runsA.count == 2, "T-TOOLRUN 正文切段 ⇒ 2 段 (实测 \(runsA.count))")
        check(runsA.first?.count == 2, "T-TOOLRUN 第一段 2 条 (实测 \(runsA.first?.count ?? -1))")
        check(runsA.last?.count == 1, "T-TOOLRUN 第二段 1 条 (实测 \(runsA.last?.count ?? -1))")

        // ② `.think` **不是**边界 —— 这条翻红就说明有人把思考当成了"解说"
        let b = [toolMsg("a1"), thinkMsg(), toolMsg("a2")]
        check(ToolRunBuilder.runs(in: b).count == 1,
              "T-TOOLRUN 思考不切段 (think 与 tool 属于同一次执行)")
        check(ToolRunBuilder.runs(in: b).first?.count == 2,
              "T-TOOLRUN 被思考隔开的两条工具仍在同一段")

        // ③ 计划卡 / 压缩标记是边界
        let plan = PlanQuestion(title: "选哪个?", options: [])
        let c = [toolMsg("a1"), ChatMessage(role: .assistant, content: .plan(plan)), toolMsg("b1")]
        check(ToolRunBuilder.runs(in: c).count == 2, "T-TOOLRUN 计划卡切段")
        let d = [toolMsg("a1"),
                 ChatMessage(role: .system,
                             content: .compaction(tokensBefore: 10, tokensAfter: 5, reason: "manual")),
                 toolMsg("b1")]
        check(ToolRunBuilder.runs(in: d).count == 2, "T-TOOLRUN 压缩标记切段")

        // ④ 成员 id = **消息** id（不是工具 id）, 含段首、时间序连续
        let e = [toolMsg("a1"), toolMsg("a2")]
        if let run = ToolRunBuilder.runs(in: e).first {
            check(run.id == e[0].id, "T-TOOLRUN 段 id = 段首消息 id")
            check(run.memberIds == [e[0].id, e[1].id],
                  "T-TOOLRUN 成员 id 是消息 id 且保持时间序")
            check(run.memberIds.count == run.count, "T-TOOLRUN 成员数与工具数一致")
        } else {
            check(false, "T-TOOLRUN 两条工具应成一段")
        }

        // ⑤ 可折条件
        check(ToolRunBuilder.runs(in: e).first?.foldable == true, "T-TOOLRUN 2 条全 done ⇒ 可折")
        let single = [toolMsg("a1")]
        check(ToolRunBuilder.runs(in: single).first?.foldable == false,
              "T-TOOLRUN **1 条不可折** (23pt → 22pt, 省 1pt 却多一次点击)")
        let withErr = [toolMsg("a1"), toolMsg("a2", .bash, .error("exit 1"))]
        check(ToolRunBuilder.runs(in: withErr).first?.foldable == false,
              "T-TOOLRUN 含 error ⇒ 不可折 (失败不许自己缩回, 新机制不许旁路)")
        let withRun = [toolMsg("a1"), toolMsg("a2", .bash, .running)]
        check(ToolRunBuilder.runs(in: withRun).first?.foldable == false,
              "T-TOOLRUN 含 running ⇒ 不可折")
        let withAppr = [toolMsg("a1"), toolMsg("a2", .bash, .awaitingApproval)]
        check(ToolRunBuilder.runs(in: withAppr).first?.foldable == false,
              "T-TOOLRUN 含待审 ⇒ 不可折 (要人拍板的东西不能藏)")

        // ⑥ 类型分布按**首次出现**排序（同一批数据重放两次必须同序, 否则收据会跳字）
        let f = [toolMsg("x", .read), toolMsg("y", .bash), toolMsg("z", .read)]
        let kinds = ToolRunBuilder.runs(in: f).first?.kindCounts ?? []
        check(kinds.count == 2, "T-TOOLRUN 两种类型 (实测 \(kinds.count))")
        check(kinds.first?.kind == .read && kinds.first?.count == 2,
              "T-TOOLRUN 首次出现的类型排前面, 且计数正确")
        check(kinds.last?.kind == .bash, "T-TOOLRUN 后出现的类型排后面")

        // ⑦ 耗时口径与 `ToolCallCardView.phaseBadge` 一致: 求和, ≥1s 换成 x.xs
        let g = [toolMsg("a1", .bash, .done, 800), toolMsg("a2", .bash, .done, 400)]
        let run = ToolRunBuilder.runs(in: g).first
        check(run?.totalMs == 1200, "T-TOOLRUN 耗时求和 (实测 \(run?.totalMs ?? -1))")
        check(run?.durationText == "1.2s", "T-TOOLRUN ≥1s 显示 x.xs (实测 \(run?.durationText ?? "nil"))")
        let h = [toolMsg("a1", .bash, .done, 420)]
        check(ToolRunBuilder.runs(in: h).first?.durationText == "420ms", "T-TOOLRUN <1s 显示毫秒")
        let i = [toolMsg("a1", .bash, .done, nil), toolMsg("a2", .bash, .done, nil)]
        check(ToolRunBuilder.runs(in: i).first?.durationText == nil,
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
        let realRuns = ToolRunBuilder.runs(in: real)
        check(realRuns.count == 1, "T-TOOLRUN 真实序列只成 1 段 (实测 \(realRuns.count))")
        check(realRuns.first?.count == 4, "T-TOOLRUN 真实序列 4 个工具 (实测 \(realRuns.first?.count ?? -1))")
        check(realRuns.first?.span == 1..<7,
              "T-TOOLRUN span 从段首思考起、覆盖中间 think (期望 1..<7, 实测 \(String(describing: realRuns.first?.span)))")
        check(realRuns.first?.span.count == 6 && realRuns.first?.memberIds.count == 4,
              "T-TOOLRUN span 占 6 行 > 成员 4 条 ⇒ 只许按 span 跳行")
        check(realRuns.first?.thinkCount == 2, "T-TOOLRUN 段内 2 段思考 (实测 \(realRuns.first?.thinkCount ?? -1))")

        // ⑨ 纯空白正文不作边界（空串如果算边界, 会被切成"4 条 + 1 条", 那条又不折 ⇒ 像漏了一条）
        let blank = [toolMsg("a1"), textMsg("   \n"), toolMsg("a2")]
        check(ToolRunBuilder.runs(in: blank).count == 1,
              "T-TOOLRUN 纯空白正文不作边界 (实测 \(ToolRunBuilder.runs(in: blank).count) 段)")

        // ⑩ 只有思考、没有工具 ⇒ **也产出段, 也可折**。
        //    2026-10-20 boss 截图纠正: 一屏里第一段是裸露的 `Reasoning`、后面每段都是收据 ⇒
        //    "看着像漏了一行没折"。规则是"正文之间的一切都收", 没有例外。
        //    ⚠️ 收益不是高度（两边都是一行）, 是**形态统一**; 所以这里断言的是 foldable 与 count,
        //    不是"省了多少 pt"—— 后者永远为 0, 写成断言会把人误导到别处去优化。
        let onlyThink = [thinkMsg(), thinkMsg()]
        let onlyRuns = ToolRunBuilder.runs(in: onlyThink)
        check(onlyRuns.count == 1, "T-TOOLRUN 纯思考段也产出 (实测 \(onlyRuns.count) 段)")
        check(onlyRuns.first?.count == 0, "T-TOOLRUN 纯思考段工具数 0 (实测 \(onlyRuns.first?.count ?? -1))")
        check(onlyRuns.first?.thinkCount == 2, "T-TOOLRUN 纯思考段思考数 2 (实测 \(onlyRuns.first?.thinkCount ?? -1))")
        check(onlyRuns.first?.foldable == true, "T-TOOLRUN 纯思考段可折 (一律收, 不设门槛)")
        check(onlyRuns.first?.span == 0..<2, "T-TOOLRUN 纯思考段 span 覆盖全部思考")

        // ⑪ 思考让"单条工具"变得值得折: span 2 行 vs 一行收据
        let toolAndThink = [toolMsg("a1"), thinkMsg()]
        check(ToolRunBuilder.runs(in: toolAndThink).first?.foldable == true,
              "T-TOOLRUN 1 工具 + 1 思考 ⇒ 可折 (占 2 行)")
    }
}
