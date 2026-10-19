//
//  caseDreamGuard —— dream 双闸门 + 不可删除
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家 + dir→fixturesRoot 等价替换）。
//  原位替换为 `await caseDreamGuard()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseDreamGuard() async {
        let right = MarkdownParser.parse("| 渠道 | 昨日装机 |\n|---|--:|\n| 华为 | 128,430 |")
        check(right == [.table(header: ["渠道", "昨日装机"], rows: [["华为", "128,430"]],
                               aligns: [.leading, .trailing])],
              "T-MD 表格: 分隔行 `--:` ⇒ 该列右对齐 (实测 \(right))")

        let centered = MarkdownParser.parse("| a | b |\n|:---:|---|\n| 1 | 2 |")
        check(centered == [.table(header: ["a", "b"], rows: [["1", "2"]],
                                  aligns: [.center, .leading])],
              "T-MD 表格: `:---:` ⇒ 居中, `---` ⇒ 缺省左对齐")

        let plain = MarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |")
        check(plain == [.table(header: ["a", "b"], rows: [["1", "2"]],
                               aligns: [.leading, .leading])],
              "T-MD 表格: 无 `:` ⇒ 一律左对齐 (缺省口径与 GitHub 一致)")

        // 列数不齐在真实模型输出里很常见。**必须对齐到表头列数** —— 渲染侧是按下标取
        // `aligns[i]` 的, 少一格就整列错位、多一格也没人读。
        let shorter = MarkdownParser.parse("| a | b | c |\n|---|---|\n| 1 | 2 | 3 |")
        check(shorter == [.table(header: ["a", "b", "c"], rows: [["1", "2", "3"]],
                                 aligns: [.leading, .leading, .leading])],
              "T-MD 表格: 分隔行比表头少 ⇒ 补 leading 到表头列数")

        let longer = MarkdownParser.parse("| a | b |\n|---|---|---|\n| 1 | 2 |")
        check(longer == [.table(header: ["a", "b"], rows: [["1", "2"]],
                                aligns: [.leading, .leading])],
              "T-MD 表格: 分隔行比表头多 ⇒ 截到表头列数")

        check(MarkdownParser.parse("![趋势](/tmp/dau.png)")
                == [.image(alt: "趋势", source: "/tmp/dau.png")],
              "T-MD 图片: **整行** `![alt](src)` 成 image 块")
        check(MarkdownParser.parse("![趋势](/tmp/dau.png \"标题\")")
                == [.image(alt: "趋势", source: "/tmp/dau.png")],
              "T-MD 图片: 带 `\"title\"` 时只取 URL")
        check(MarkdownParser.parse("![a](</tmp/a b.png>)")
                == [.image(alt: "a", source: "/tmp/a b.png")],
              "T-MD 图片: 尖括号包裹的含空格路径")

        // 反例三条 —— 判据是"**整行**才是图", 这三条必须**不**成块:
        check(MarkdownParser.parse("看这张 ![趋势](/tmp/dau.png) 图")
                == [.paragraph(text: "看这张 ![趋势](/tmp/dau.png) 图")],
              "T-MD 图片: 行内图不成块 (成块会把一句话拆成三段)")
        check(MarkdownParser.parse("[趋势](/tmp/dau.png)")
                == [.paragraph(text: "[趋势](/tmp/dau.png)")],
              "T-MD 图片: 少了 `!` 是链接, 不是图")
        check(MarkdownParser.parse("![a]()") == [.paragraph(text: "![a]()")],
              "T-MD 图片: 空源不成块 (渲染不出东西, 留原文更有用)")

        // 回归: 新 case 的插入位置不能吃掉既有块型 (它排在表格/列表/引用之前)
        check(MarkdownParser.parse("```swift\nlet a = 1\n```")
                == [.codeBlock(language: "swift", code: "let a = 1")],
              "T-MD 回归: 代码围栏仍是 codeBlock")
        check(MarkdownParser.parse("# 标题") == [.heading(level: 1, text: "标题")],
              "T-MD 回归: 标题仍是 heading")
        check(MarkdownParser.parse("- 一条") == [.listItem(indent: 0, ordered: false, index: 0, text: "一条")],
              "T-MD 回归: 列表仍是 listItem")
    }
}
