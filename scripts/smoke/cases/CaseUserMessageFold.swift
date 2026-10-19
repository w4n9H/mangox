//
//  CaseUserMessageFold.swift
//  长用户消息折叠的判据 (2026-10-19)。`UserMessageFold` 是纯函数, 所以不需要夹具。
//
//  这套断言存在的理由: 折叠的每一个数字都是"观感预算", 改动它会静默改变用户体验 ——
//  阈值调错一位, 要么该折的不折 (贴 1000 行照旧铺满), 要么不该折的折了 (一段正常的
//  长 prompt 被藏起来)。边界值必须钉住。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseUserMessageFold() async {
        print("== T-USERFOLD 长用户消息折叠 ==")

        // ① 短消息一律不折 —— 这是绝大多数输入, 折叠误伤比不折更糟
        check(!UserMessageFold.shouldFold("帮我看看这个报错"),
              "T-USERFOLD 一句短话不折叠")
        check(!UserMessageFold.shouldFold(""),
              "T-USERFOLD 空串不折叠 (空消息不该长出展开按钮)")

        // ② 行数门槛的**两侧**: 12 行不折 / 13 行折
        let twelve = Array(repeating: "x", count: 12).joined(separator: "\n")
        let thirteen = Array(repeating: "x", count: 13).joined(separator: "\n")
        check(UserMessageFold.lineCount(twelve) == 12, "T-USERFOLD 12 行数得对")
        check(!UserMessageFold.shouldFold(twelve),
              "T-USERFOLD **12 行不折** (门槛 = 超过 12 才折)")
        check(UserMessageFold.shouldFold(thirteen),
              "T-USERFOLD 13 行折 —— 少一行的这一侧翻红")

        // ③ 字数门槛的**两侧**: 1200 不折 / 1201 折 (单行, 行数没超 ⇒ 走的是字数门槛)
        let c1200 = String(repeating: "a", count: 1200)
        let c1201 = String(repeating: "a", count: 1201)
        check(UserMessageFold.lineCount(c1200) == 1, "T-USERFOLD 单行文本行数为 1")
        check(!UserMessageFold.shouldFold(c1200),
              "T-USERFOLD **1200 字符不折** (门槛 = 超过 1200 才折)")
        check(UserMessageFold.shouldFold(c1201),
              "T-USERFOLD 1201 字符折 —— 长散文没有换行也得折")

        // ④ 预览只给前 6 行, 剩下的行数要**如实报出来**
        let twenty = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let preview = UserMessageFold.preview(twenty)
        check(preview.components(separatedBy: "\n").count == 6,
              "T-USERFOLD 预览恰好 6 行 (实测 \(preview.components(separatedBy: "\n").count))")
        check(preview.hasPrefix("line 0\nline 1"),
              "T-USERFOLD 预览取的是**前** 6 行, 不是任意 6 行")
        check(UserMessageFold.hiddenLineCount(twenty) == 14,
              "T-USERFOLD 20 行 ⇒ 收起 14 行 (提示必须报实数, 实测 \(UserMessageFold.hiddenLineCount(twenty)))")

        // ⑤ 空行不能被吃掉 —— 折叠只是截行, 不是清理
        let withBlank = "a\n\nb"
        check(UserMessageFold.preview(withBlank).components(separatedBy: "\n").count == 3,
              "T-USERFOLD 预览里的空行照留 (空串 Text 高度为 0, 视图层用空格占位)")

        // ⑥ 单行超长: 被字符上限截断, 且此时 hiddenLineCount = 0
        //    ⇒ 文案走「内容较长」而不是「还有 0 行 · 展开」
        check(UserMessageFold.preview(c1201).count == UserMessageFold.previewCharCap,
              "T-USERFOLD 单行超长被字符上限截断 (实测 \(UserMessageFold.preview(c1201).count))")
        check(UserMessageFold.hiddenLineCount(c1201) == 0,
              "T-USERFOLD 单行超长时行数没超 ⇒ 隐藏行数为 0 (文案据此换成「内容较长」)")

        // ⑦ 展开区上界与工具输出区**有意不同** —— 改成一个数就说明有人顺手对齐了,
        //    那会把"用户自己写的东西"和"跑完看一眼的结果"混成同一个尺度。
        check(UserMessageFold.expandedMaxHeight > Tune.toolOutputMaxHeight,
              "T-USERFOLD 展开区上界 (\(Int(UserMessageFold.expandedMaxHeight))pt) 大于工具输出区 (\(Int(Tune.toolOutputMaxHeight))pt)")
    }
}
