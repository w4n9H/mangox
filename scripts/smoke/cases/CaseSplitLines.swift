//
//  CaseSplitLines.swift
//  纯文本切行 + 用户消息折叠切分（2026-11-04，C 批）。
//
//  病根：`Text(整段)` 在 SwiftUI 里是平方级的（`render_probe.py`：3341 行 36 秒），
//    所以"长文本按行拆成多个小 Text"是必须的。而"拆得对不对"是唯一**能写死**的判据 ——
//    渲染是惰性的，量不出切了几行，但空行丢没丢、末尾换行算不算一行、`\r` 剥没剥，
//    全都可以在这里钉死。
//
//  ⚠️ 判据必须覆盖"省了分配但换了语义"这一类退化：
//    `rows` 返回 `[Substring]`（编译期就保证了不逐行复制），但切片仍然指向原文 ——
//    `\r` 没剥、空行被 `omittingEmptySubsequences` 吃掉，都不会报错，只会少几行字。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSplitLines() async {
        print("== T-SPLIT 纯文本切行 / 折叠切分 ==")

        // ── 基本口径 ─────────────────────────────────────────────
        check(SplitLines.count("") == 0 && SplitLines.rows("").isEmpty,
              "T-SPLIT 空文本是 0 行 (不是 1 行)")

        check(SplitLines.count("a") == 1, "T-SPLIT 单行文本 = 1 行")

        check(SplitLines.count("a\nb") == 2 && SplitLines.rows("a\nb").count == 2,
              "T-SPLIT 两行文本 = 2 行")

        // 末尾换行 = 多一个空行。丢掉它的症状是"输出的最后一行不见了", 而没有任何报错。
        check(SplitLines.count("a\n") == 2 && SplitLines.rows("a\n").count == 2,
              "T-SPLIT 末尾换行算一行 (实测 \(SplitLines.rows("a\n").count) 行)")

        let withBlank = SplitLines.rows("a\n\nb")
        check(withBlank.count == 3 && withBlank[1].isEmpty,
              "T-SPLIT 中间空行必须保留 (实测 \(withBlank.count) 行)")

        // ── count 与 rows 同口径 ────────────────────────────────
        // ⚠️ 这两条分家就会静默错位: 门槛用 count 判、渲染用 rows, 差的正好是空行。
        var mismatch: [String] = []
        for sample in ["", "a", "a\n", "\n", "\n\n", "a\n\nb", "a\nb\n",
                       "\r\n", "a\r\nb", "\r", "a\rb", "a\n\r\nb"] {
            if SplitLines.count(sample) != SplitLines.rows(sample).count {
                mismatch.append(sample.debugDescription)
            }
        }
        check(mismatch.isEmpty,
              "T-SPLIT count 与 rows 对所有样本同口径 (不一致: \(mismatch.joined(separator: ", ")))")

        // ── isOver 早退版与 count 同口径 ────────────────────────
        var overMismatch: [String] = []
        for sample in ["", "a", "a\n", "\n\n\n", "a\r\nb", "a\rb", "a\n\nb"] {
            for limit in 0...3 {
                let byCount = SplitLines.count(sample) > limit
                if SplitLines.isOver(sample, limit: limit) != byCount {
                    overMismatch.append("\(sample.debugDescription)>\(limit)")
                }
            }
        }
        check(overMismatch.isEmpty,
              "T-SPLIT isOver 早退版与 count 逐项一致 (不一致: \(overMismatch.joined(separator: ", ")))")

        // ── CRLF ───────────────────────────────────────────────
        // ⚠️ `\r\n` 在 Swift 里是**一个 `Character`** —— `split(separator: "\n")` 切不开它
        //    (症状: 一份 Windows 换行的日志被当成 1 行, 又退回一个巨大的 `Text`)。
        //    而 `components(separatedBy: "\n")` 虽然切得开, 却会在每行尾巴留一个 `\r`。
        //    这条是 C 批第一次跑就抓到的真 bug: 原来那版 `split(separator:)` 正是切不开的那个。
        let crlf = SplitLines.rows("a\r\nb")
        check(crlf.count == 2, "T-SPLIT CRLF 也切成两行 (实测 \(crlf.count) 行)")
        check(crlf.first == "a",
              "T-SPLIT CRLF 的行尾不留 \\r (实测 \(crlf.first?.debugDescription ?? "nil"))")
        check(SplitLines.rows("a\rb").count == 1,
              "T-SPLIT 孤立的 \\r **不**当换行 (工具输出里的进度条会炸成几百行)")
        check(SplitLines.trimmed("a\r") == "a", "T-SPLIT 渲染前兜底剥掉行尾 \\r")
        check(SplitLines.trimmed("a") == "a", "T-SPLIT 没有 \\r 的行原样返回")

        // ── 门槛两侧 ────────────────────────────────────────────
        check(Tune.textSplitLines == 40, "T-SPLIT 纯文本切行门槛 = 40 (实测 \(Tune.textSplitLines))")
        check(Tune.codeBlockMaxHeight == 320,
              "T-SPLIT 长代码块限高 = 320pt (2026-11-04 boss 拍板; 实测 \(Tune.codeBlockMaxHeight))")

        let exactly = String(repeating: "x\n", count: Tune.textSplitLines - 1) + "x"  // 40 行
        let over = exactly + "\ny"                                                     // 41 行
        check(SplitLines.count(exactly) == Tune.textSplitLines,
              "T-SPLIT 门槛这一侧 (40 行) 走整块, 不多不少")
        check(SplitLines.count(over) == Tune.textSplitLines + 1,
              "T-SPLIT 门槛另一侧 (41 行) 才逐行")

        // ── 大输入 ─────────────────────────────────────────────
        let huge = String(repeating: "日志行 log line\n", count: 3000)
        check(SplitLines.count(huge) == 3001,
              "T-SPLIT 3000 行输入数得对 (实测 \(SplitLines.count(huge)))")
        check(SplitLines.rows(huge).count == 3001, "T-SPLIT 3000 行切得对")

        // ── UserMessageFold.previewLines ───────────────────────
        let twenty = (1...20).map { "第 \($0) 行" }.joined(separator: "\n")
        let p20 = UserMessageFold.previewLines(twenty)
        check(p20.count == UserMessageFold.collapsedLineLimit,
              "T-UMF previewLines 20 行只取 6 行 (实测 \(p20.count))")
        check(p20.joined(separator: "\n") == UserMessageFold.preview(twenty),
              "T-UMF previewLines 与 preview 逐字相同 (同一个切法的两种形态)")

        // 早停：3000 行文本只该碰前 7 段。判据不是"多快", 而是"取出来的东西对不对"。
        let p3000 = UserMessageFold.previewLines(huge)
        check(p3000.count == UserMessageFold.collapsedLineLimit,
              "T-UMF 3000 行也只取 6 行 (实测 \(p3000.count))")
        check(p3000.dropFirst().allSatisfy { !$0.contains("日志行") || $0 == "日志行 log line" },
              "T-UMF 预览内容是原文的前几行, 不是从别处拼来的")

        // 空行在折叠预览里同样要保留 (UserMessageFold 的 CaseUserMessageFold 已钉过一遍,
        // 这里钉的是**新入口**(previewLines) 与旧入口(preview) 没有分家。
        let blankPreview = "a\n\nb\nc\nd\ne\nf\ng"
        check(UserMessageFold.previewLines(blankPreview).count == 6,
              "T-UMF 含空行的预览仍是 6 行")
        check(UserMessageFold.previewLines(blankPreview)[1].isEmpty,
              "T-UMF 预览里的空行没被吃掉")

        // 单行超长：只截这一行, 且恰好截到字符上限。
        let oneLong = String(repeating: "字", count: UserMessageFold.previewCharCap + 1)
        let pl = UserMessageFold.previewLines(oneLong)
        check(pl.count == 1 && pl[0].count == UserMessageFold.previewCharCap,
              "T-UMF 单行超长截到 \(UserMessageFold.previewCharCap) 字符 (实测 \(pl.first?.count ?? -1))")
    }
}
