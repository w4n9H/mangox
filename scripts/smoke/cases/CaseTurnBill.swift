//
//  CaseTurnBill.swift
//  轮末的账 (2026-10-22)
//
//  为什么这些断言必须有: 「这一轮改了哪些文件」全部是从 `[ChatMessage]` 现算的纯函数,
//  算错了**不会报错**, 只会安静地多数一个文件 / 少数一次调用 —— 而账单这种东西,
//  一旦它在说谎就比没有更糟(用户拿它对账)。
//
//  能变红的四个点, 每一个都对应一种真实的写法错误:
//    · 认哪些工具算改动 —— 放宽到 read/bash ⇒ 账单会把"读过的文件"报成"改过的";
//    · 项目外的绝对路径 —— 不剥/不丢 ⇒ 列表里出现一条点不开的行;
//    · 去重 —— 同一文件改三次 ⇒ 报 3 个文件;
//    · 空账 —— 账全空时仍画一行 ⇒ 空轮也长出一条账。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseTurnBill() async {
        print("== T-BILL 轮末的账 ==")

        let root = "/tmp/billproj"

        func toolMsg(_ path: String, _ kind: ToolKind = .edit,
                     phase: ToolPhase = .done, id: UUID = UUID(),
                     parent: UUID? = nil) -> ChatMessage {
            ChatMessage(role: .assistant,
                        content: .tool(ToolCall(id: id, kind: kind, title: path,
                                                phase: phase, parentId: parent)))
        }
        func textMsg(_ s: String = "讲完了", role: MessageRole = .assistant,
                     tokens: Int? = nil) -> ChatMessage {
            var u: MessageUsage?
            if let tokens { u = MessageUsage(totalTokens: tokens) }
            return ChatMessage(role: role, content: .text(s), usage: u)
        }

        // ① 一轮 = 用户那句話 + 它的产出。调用数 / token / 文件都只数这一组。
        let turn2 = [textMsg("再改两处", role: .user),
                     toolMsg(root + "/b.swift"),
                     toolMsg(root + "/c.swift"),
                     textMsg("改完了 b 和 c", tokens: 300)]
        let b2 = TurnBillBuilder.bill(group: turn2, elapsed: 134, root: root)
        check(b2.calls == 2, "T-BILL 调用数 = 本轮工具条数 (实测 \(b2.calls))")
        check(b2.tokens == 300, "T-BILL token 按消息累加 (实测 \(b2.tokens))")
        check(b2.files == ["c.swift", "b.swift"],
              "T-BILL 文件新→旧去重 (实测 \(b2.files))")
        check(b2.elapsed == 134 && TurnBill.duration(134) == "02:14",
              "T-BILL 耗时 = 实测值, 格式化 mm:ss")

        // ② 认哪些工具算"改动" —— 只有 edit / write。
        //    反例心态: 把判据放宽成"只要不是 think 就算", 账单就会把**读过的**文件报成改过的。
        let mixed = [textMsg("看一眼再改", role: .user),
                     toolMsg(root + "/read-me.swift", .read),
                     toolMsg(root + "/ls.sh", .bash),
                     toolMsg(root + "/really.swift", .write),
                     textMsg("好了")]
        let bMixed = TurnBillBuilder.bill(group: mixed, elapsed: nil, root: root)
        check(bMixed.files == ["really.swift"],
              "T-BILL 只有 edit/write 算改动 (实测 \(bMixed.files) —— 多出来的是被 read/bash 带进来的)")
        check(bMixed.calls == 3,
              "T-BILL 调用数**不**按类型筛: read/bash 也是调用 (实测 \(bMixed.calls))")

        // ③ 同一个文件改三次 = 1 个文件 (按路径去重, 保留最新那次的位置)。
        let thrice = [textMsg("改三次", role: .user),
                      toolMsg(root + "/same.swift"),
                      toolMsg(root + "/other.swift"),
                      toolMsg(root + "/same.swift"),
                      textMsg("三次")]
        let bThrice = TurnBillBuilder.bill(group: thrice, elapsed: nil, root: root)
        check(bThrice.files == ["same.swift", "other.swift"],
              "T-BILL 同文件多次改只算一个 (实测 \(bThrice.files))")

        // ④ 同一工具重复推送 (相位更新) 不算两次调用 —— 按 ToolCall.id 去重。
        let dupID = UUID()
        let dup = [textMsg("同一条工具的两个相位", role: .user),
                   toolMsg(root + "/x.swift", .edit, phase: .running, id: dupID),
                   toolMsg(root + "/x.swift", .edit, phase: .done, id: dupID),
                   textMsg("完")]
        check(TurnBillBuilder.bill(group: dup, elapsed: nil, root: root).calls == 1,
              "T-BILL 相位更新不重复计调用 (按 ToolCall.id 去重)")

        // ⑤ 项目外的绝对路径**丢掉**, 不是原样显示 —— 那种行在列表里点不开。
        let outside = [textMsg("顺手改了别人的仓库", role: .user),
                       toolMsg("/Users/someone/elsewhere/z.swift"),
                       textMsg("好了")]
        check(TurnBillBuilder.bill(group: outside, elapsed: nil, root: root).files.isEmpty,
              "T-BILL 项目外的绝对路径不进列表 (返回原值 ⇒ 这里会红)")
        check(workspaceRelativePath(root + "/a/b.swift", root: root) == "a/b.swift",
              "T-BILL 绝对路径剥 root 前缀")
        check(workspaceRelativePath("rel/c.swift", root: root) == "rel/c.swift",
              "T-BILL 相对路径原样返回")

        // ⑥ 空账不画行 —— 但"只有耗时"是一条真账 (最后一轮只有一句话也有时长)。
        let nothing = TurnBillBuilder.bill(group: [textMsg("嗯", role: .user)], elapsed: nil, root: root)
        check(nothing.isEmpty, "T-BILL 什么都没有时 isEmpty (视图据此整行不画)")
        let onlyElapsed = TurnBillBuilder.bill(group: [textMsg("嗯", role: .user)], elapsed: 9, root: root)
        check(!onlyElapsed.isEmpty, "T-BILL 只有耗时的轮次仍是一条账 (不是空)")

        // ⑦ 老会话没有 usage ⇒ tokens = 0 (视图据此把那一格整段藏掉, 不是报 0)。
        let noUsage = TurnBillBuilder.bill(group: [textMsg("老会话"), textMsg("嗯", role: .user)],
                                           elapsed: nil, root: root)
        check(noUsage.tokens == 0, "T-BILL 无 usage ⇒ tokens 为 0 (整格不显示, 不报 0%)")

        // ⑧ 数字缩写: 与工作区 diffstat 同一套口径 (1.8k / 18k / 940)。
        check(TurnBill.shortNumber(940) == "940", "T-BILL 千位以下照写 (实测 \(TurnBill.shortNumber(940)))")
        check(TurnBill.shortNumber(1840) == "1.8k", "T-BILL 千位取一位小数 (实测 \(TurnBill.shortNumber(1840)))")
        check(TurnBill.shortNumber(18_400) == "18k", "T-BILL 万位取整 (实测 \(TurnBill.shortNumber(18_400)))")

        // ⑨ 单复数分开取词 —— 这里只钉住"分不分得出来", 词条本身在 en_values.py。
        check(TurnBill.count(1, one: "1 file", many: "%lld files") == "1 file",
              "T-BILL 1 走单数词条")
        check(TurnBill.count(5, one: "1 file", many: "%lld files") == "5 files",
              "T-BILL 5 走复数词条 (显示成 1 files 的那种英文错就出在这儿)")

        // ⑩ 内层调用（codemode 脚本里的 `tools.bash(...)`）**不算**这一轮的调用次数 ——
        //    2026-10-26 audit ①: 一次 codemode 就是一次调用, 它内部扇出几次是实现细节。
        //    ⚠️ 口径必须与「段收据」（`ToolRun.count`）一致: 两个数显示在同一屏
        //    （页脚「N 次调用」/ 收据「N 次工具调用」）, 一个含内层一个不含 ⇒ 用户看到
        //    "2 次调用" 与 "1 次工具调用" 并列, 而没有任何一处报错。
        let cmID = UUID()
        let withNested = [textMsg("跑一下脚本", role: .user),
                          toolMsg("script", .codemode, id: cmID),
                          toolMsg("ls -la", .bash, parent: cmID),
                          toolMsg("git status", .bash, parent: cmID),
                          textMsg("跑完了")]
        let bNested = TurnBillBuilder.bill(group: withNested, elapsed: nil, root: root)
        check(bNested.calls == 1,
              "T-BILL 内层调用不计数 (实测 \(bNested.calls), 期望 1 —— 3 说明把子卡算成了独立调用)")
        // 反例自证: 同一条消息只去掉 `parentId` ⇒ 它就该被数进去（否则上面的断言可能
        // 因为"根本没数工具"而假绿）。
        let withoutParent = [textMsg("跑一下脚本", role: .user),
                             toolMsg("ls -la", .bash),
                             textMsg("跑完了")]
        check(TurnBillBuilder.bill(group: withoutParent, elapsed: nil, root: root).calls == 1,
              "T-BILL 反例: 没 parentId 的同一条 bash 照样计数 (钉住上一条不是假绿)")
    }
}
