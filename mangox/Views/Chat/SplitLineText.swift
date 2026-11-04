//
//  SplitLineText.swift
//  一段**长度由用户 / 工具数据决定**的纯文本：短就整块，长就逐行 + 惰性。
//

import SwiftUI

/// 「把纯文本切成一行的纯函数」—— 全项目**只此一份**。
///
/// 单独抽出来不是为了好看：渲染是惰性的、量不出"切了几行"，而"切得对不对"恰恰是
/// 唯一能写死的判据（空行保不保、末尾换行算不算一行、`\r\n` 怎么办）。
/// 冒烟 `T-SPLIT` 直接断言这里，视图层只是它的消费者。
enum SplitLines {

    /// 换行判据：LF，以及 **CRLF**。
    ///
    /// ⚠️ `"\r\n"` 在 Swift 里是**一个 `Character`**（扩展字素簇）—— 所以
    ///    `text.split(separator: "\n")` **根本切不开 CRLF**：一份 Windows 换行的日志会被
    ///    当成**一整行**，于是"按行拆"退回"一个巨大的 `Text`"，平方级又回来了，而且
    ///    `count` 说 3000 行、`rows` 只有 1 行，两边静默分家。
    ///    （旧实现 `components(separatedBy: "\n")` 能切开，但每行尾巴留一个 `\r`，渲染成方框。）
    ///
    /// ⚠️ **不认孤立的 `\r`**：工具输出里的 `\r` 是进度条"回到行首重写"用的，
    ///    把它当换行会把一行进度条炸成几百行。这与"按 LF 字节切"的直觉一致。
    ///
    /// 非 private：`UserMessageFold` 的折叠预览也要用**同一个**判据（它只切前 6 行，
    /// 走的是 `maxSplits`，切法与 `rows` 必须逐字一致）。
    static func isBreak(_ ch: Character) -> Bool {
        ch == "\n" || ch == "\r\n"
    }

    /// 行数。与 `rows(_:)` **必须同口径** —— 门槛用 `count` 判、渲染用 `rows` 走，
    /// 两边差的正好是"被当成换行的那种字符"，症状是界面少几行字，没有任何报错。
    /// `""` 是 0 行（不是 1 行），`"a\n"` 是 2 行（末尾那个空行算）。
    static func count(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        var n = 1
        for ch in text where isBreak(ch) { n += 1 }
        return n
    }

    /// 是否**超过** `limit` 行 —— 渲染门槛专用。
    ///
    /// ⚠️ 早退是承重的：`count` 必须扫完整段（"还有 14 行"要报实数），而门槛只关心
    ///    "超没超" ⇒ 一份 5000 行的输出在第 41 个换行处就能停，不必数完。
    static func isOver(_ text: String, limit: Int) -> Bool {
        var n = text.isEmpty ? 0 : 1
        for ch in text where isBreak(ch) {
            n += 1
            if n > limit { return true }
        }
        return n > limit
    }

    /// 切行。`[Substring]` 只分配**一个数组**，不逐行复制字符；真正的 `String` 化发生在
    /// `LazyVStack` 的行构造里 —— 只有可见行会付。
    ///
    /// ⚠️ `omittingEmptySubsequences: false` **不能省**：默认的 `true` 会吃掉空行，
    ///    而工具输出 / diff / 用户贴的日志里，空行是结构的一部分（症状同样是"少几行字"）。
    static func rows(_ text: String) -> [Substring] {
        if text.isEmpty { return [] }
        return text.split(omittingEmptySubsequences: false, whereSeparator: isBreak)
    }

    /// 渲染前兜底剥掉行尾的 `\r`。
    ///
    /// `rows` 已经把 CRLF 当换行吃掉了，所以正常输入到这里没有 `\r`；**留下这个兜底是为了
    /// 孤立 `\r` 的尾巴**（`"a\r"` 这种进度条残留）—— 它在界面上会渲染成一个方框。
    /// 在渲染时剥、不在切行时剥：切行保持纯切片，不复制字符。
    ///
    /// 泛型是为了让 `String` 与 `Substring` 都能进（返回各自的原生切片类型，**都不复制**）：
    /// 有的渲染面手上只有整段 `String`（没切行），有的拿的是 `rows` 出来的 `Substring`。
    static func trimmed<S: StringProtocol>(_ line: S) -> S.SubSequence {
        line.last == "\r" ? line.dropLast() : line[...]
    }
}

/// 一段可能很长的纯文本。
///
/// 为什么必须有它：`Text(整段)` 在 SwiftUI 里是**平方级**的 —— 整篇是**一个**布局单位。
/// `scripts/diag/render_probe.py` 实测（560pt 宽、全高布局）：139 行 199ms / 561 行 4.2s /
/// 3341 行 **36s**。而工具输出**上游没有任何截断**（bash、read 一整个文件都照单全收），
/// 所以"输出五千行"是常态，不是极端场景。
///
/// 判据与 `CodeBlockView.codeText` 同源：**40 行以内保持整块**（与原来的渲染逐字相同），
/// 超过就按行拆成多个小 `Text` —— 每行各自布局，总量回到线性。
///
/// ⚠️ 行距**两处都要给**：`LazyVStack` 的 `spacing` 管行与行之间，每行自己的 `.lineSpacing`
///    管该行**折行之后**那几行之间。只给一处会与整块渲染的观感差一截
///    （`CodeBlockView` 踩过一次，见那里的注释）。
///
/// ⚠️ 代价明写：逐行以后 `textSelection` **跨行拖选只能选到已实例化的行**。
///    "复制全部"这类动作必须另有入口（工具输出区右上角就有「复制全部输出」）。
///
/// ⚠️ 空行要写成一个空格 —— `Text("")` 的高度是 0，空行会被吃掉（与代码块同一个坑）。
struct SplitLineText: View {
    let text: String
    let font: Font
    let color: Color
    /// 行距。默认 0 = SwiftUI 默认行距，也就是"整块渲染时的原样"。
    var lineSpacing: CGFloat = 0

    var body: some View {
        if SplitLines.isOver(text, limit: Tune.textSplitLines) {
            LazyVStack(alignment: .leading, spacing: lineSpacing) {
                ForEach(Array(SplitLines.rows(text).enumerated()), id: \.offset) { _, line in
                    lineText(line)
                        .font(font)
                        .foregroundStyle(color)
                        .lineSpacing(lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一行。两个分支都是 `Text`（`StringProtocol` 那个 init 与 `verbatim:` 同义，
    /// **不过本地化**）⇒ 不用为了空行多做一次 `String` 复制。
    private func lineText(_ line: Substring) -> Text {
        let trimmed = SplitLines.trimmed(line)
        return trimmed.isEmpty ? Text(verbatim: " ") : Text(trimmed)
    }
}
