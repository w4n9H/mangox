//
//  CaseCodeBlockLines.swift
//  长代码块**逐行渲染**（2026-10-29 boss「读 safari 的那个会话往上拉卡顿严重」）。
//
//  病根：`CodeBlockView.codeText` 把整块代码塞进**一个** `Text`，而横滚态是
//    `.fixedSize(horizontal: true)`（不折行）。实测那条消息里是 1 个代码块 / 124 行 /
//    6592 字符 / **最长单行 522 字符** ⇒ 等于让 CoreText 排一块约 3600pt 宽、124 行高的
//    文本，排版代价是平方级的，主线程直接卡住。
//  ⇒ 超过 `Tune.codeBlockSplitLines` 行就逐行渲染：每行只算自己那一行，总量回到线性。
//
//  ⚠️ 这条判据的要害**不是"切开了"**，而是**切开再拼回去必须与整块逐字逐属性相同** ——
//     否则"不卡了"的代价是颜色/斜体丢了（高亮用的是 `.dotMatchesLineSeparators`，多行注释
//     与跨行字符串的属性是**跨行连续**的，按字符重建就会把它切成孤立的 token）。
//  ⚠️ 用例结尾**不许**调 `report()`（见 `CaseFollowBeats` 头注释）。
//

import Foundation
import SwiftUI

extension SmokeMain {
    @MainActor
    static func caseCodeBlockLines() async {
        print("== T-CBL 长代码块逐行渲染 ==")

        // MARK: 切分本身

        let three = CodeHighlighter.splitLines(AttributedString("a\nb\nc"))
        check(three.count == 3 && three.map { String($0.characters) } == ["a", "b", "c"],
              "T-CBL 三行切成三段 实际:\(three.count) 段 \(three.map { String($0.characters) })")

        let withBlank = CodeHighlighter.splitLines(AttributedString("a\n\nb"))
        check(withBlank.count == 3 && String(withBlank[1].characters).isEmpty,
              "T-CBL 代码里的**空行必须留成空段** (丢掉就等于把空行吃了, 行号也对不上)")

        let trailing = CodeHighlighter.splitLines(AttributedString("a\n"))
        check(trailing.count == 2 && String(trailing[1].characters).isEmpty,
              "T-CBL 末尾换行 ⇒ 多一个空行 (否则最后一行少一行的位置)")

        let empty = CodeHighlighter.splitLines(AttributedString(""))
        check(empty.count == 1 && String(empty[0].characters).isEmpty,
              "T-CBL 空串仍然是一行 (渲染层不必特判)")

        // MARK: 切开再拼回去 == 整块

        // 分开调两个入口, 才能验"逐行版"与"整块版"的结果是同一份东西
        let code = "let a = 1\n// 注释\n\nlet b = \"x\"\n"
        let whole = CodeHighlighter.highlightCached(code, language: "swift")
        let pieces = CodeHighlighter.highlightLinesCached(code, language: "swift")
        check(rejoin(pieces) == whole,
              "T-CBL 逐行版拼回去必须与整块版**完全相同** (字符 + 属性; 不同就说明有属性丢了)")

        // 跨行属性: `.dotMatchesLineSeparators` 让多行注释的斜体/颜色横跨两行
        let multiline = "/* 第一行\n第二行 */\nlet x = 1"
        let mlWhole = CodeHighlighter.highlightCached(multiline, language: "swift")
        let mlPieces = CodeHighlighter.highlightLinesCached(multiline, language: "swift")
        check(mlPieces.count == 3,
              "T-CBL 多行注释仍然按物理行切成 3 段 实际:\(mlPieces.count)")
        // ⚠️ 这里**不能**用 `==`: `AttributedString` 的相等比较含 run 边界, 而跨行属性在行中间
        //    被切开后, 重新拼起来的分段方式不可能与整块那次一样 —— 那是存储形式, 不是观感。
        //    真正要守的是"**每个字符上的属性还在**", 逐字符比。
        let mlJoined = rejoin(mlPieces)
        check(String(mlJoined.characters) == String(mlWhole.characters),
              "T-CBL 跨行注释切完拼回, 字符必须逐字相同")
        check(samePerCharacterAttributes(mlJoined, mlWhole),
              "T-CBL **跨行注释**切完拼回, 每个字符的颜色/斜体都还在 —— "
              + "按字符重建而不是按 range 切, 这里就会红")
        // 反向自证: 上面那条判据不是恒真 —— 手改一个字符的颜色必须被抓到
        var tampered = mlJoined
        let ti = tampered.startIndex
        if ti < tampered.endIndex {
            tampered[ti..<tampered.index(afterCharacter: ti)].foregroundColor = Color.red
        }
        check(!samePerCharacterAttributes(tampered, mlWhole),
              "T-CBL 反例: 第一个字符改色后判据必须报不同 (否则上面那条是恒真的废话)")

        // MARK: 门槛

        check(Tune.codeBlockSplitLines >= 20,
              "T-CBL 门槛不能太小 (实际: \(Tune.codeBlockSplitLines)) —— 普通代码块要留在整块那一路, 视觉才与原来逐字相同")
        check(Tune.codeBlockSplitLines <= 100,
              "T-CBL 门槛不能太大 (实际: \(Tune.codeBlockSplitLines)) —— 100 行以上一个 Text 就已经能感觉到卡")
    }

    /// 按行拼回去（每段之间补回那个被切掉的换行符）。
    private static func rejoin(_ pieces: [AttributedString]) -> AttributedString {
        var out = AttributedString()
        for (i, piece) in pieces.enumerated() {
            if i > 0 { out.append(AttributedString("\n")) }
            out.append(piece)
        }
        return out
    }

    /// 逐个字符比**观感属性**（颜色 / 斜体），不比 run 边界。
    ///
    /// ⚠️ 跳过换行符: 跨行属性的范围**覆盖了中间那个 `\n`**, 而逐行切→拼回时换行符是补上去的
    ///    裸字符, 它身上没有颜色/斜体。换行符没有字形, 那个属性在屏幕上不存在 —— 比它只会
    ///    制造一条永远修不掉的红灯。
    private static func samePerCharacterAttributes(_ a: AttributedString,
                                                  _ b: AttributedString) -> Bool {
        guard a.characters.count == b.characters.count else { return false }
        var ia = a.startIndex
        var ib = b.startIndex
        while ia < a.endIndex {
            let nextA = a.index(afterCharacter: ia)
            let nextB = b.index(afterCharacter: ib)
            if a.characters[ia] != "\n" {
                let ra = a[ia..<nextA]
                let rb = b[ib..<nextB]
                if ra.foregroundColor != rb.foregroundColor { return false }
                if ra.inlinePresentationIntent != rb.inlinePresentationIntent { return false }
            }
            ia = nextA
            ib = nextB
        }
        return true
    }
}
