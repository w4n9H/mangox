//
//  CodeBlockView.swift
//  Fenced code block: language label · copy button · horizontally scrollable highlighted code.
//

import SwiftUI

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied: Bool = false
    /// 长行折行开关。**per-block 局部状态**: 跟 `copied` 同款 —— 换一条消息就重新开始,
    /// 不落库、不跨会话。判据: "这行要不要折行"是**局部阅读偏好**, 不是配置语义
    /// (它不改任何任务行为, 所以不走 Settings)。**默认关 = 保留原来的横向滚动**,
    /// 否则老用户会发现"长命令不再能横着看完整行"却没按过任何东西。
    @State private var wrapped: Bool = false

    /// `initialWrap` 只给 `scripts/diag/md_preview.py` 出对照图用 (生产一路走默认值)。
    /// 折行态是 `@State`, 探针驱动不了 —— 而"折行到底折没折"恰恰是必须看图才知道的那条。
    init(language: String?, code: String, initialWrap: Bool = false) {
        self.language = language
        self.code = code
        _wrapped = State(initialValue: initialWrap)
    }

    /// ⚠️ 这一层**没有任何随指针变形的分支**（头部常驻，原来的 hover 层已删，理由见 `header`）。
    ///    判据：body 里一旦出现"悬停时多一行 / 少一行"的 `if`，抖动就会回来。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if wrapped {
                codeText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    codeText
                        .padding(12)
                }
            }
        }
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radius)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 头部工具条 (常驻; 见 body 上那段"推翻 P16 §03 改动四")

    /// 语言点 + 语言名 + 折行开关 + 复制 —— **常驻**，不随指针显隐。
    ///
    /// ⚠️ **2026-10-16 boss 拍板：推翻 P16 §03 改动四。**
    ///    那一版把整条头部摘进 hover 层（默认态**整条不在视图树里**，图的是"别给每条代码块
    ///    白加一整行高度"）。实机代价是 **指针进块 ⇒ 自身高度变化 ⇒ 二次布局 ⇒ 抖一下** ——
    ///    指针与几何互相追，而"哪一帧在抖"取决于你从哪条边进块，不是稳定、可预测的观感。
    ///    ⇒ **用一次重排换一行高度，不值。**
    /// ⚠️ 于是 `@State hovering` / `.onHover` / 那半条 `.animation(value:)` **整条删掉** ——
    ///    它们没有别的用途，留着就是留着抖动源（别为了"以后可能要"再加回来）。
    /// ⚠️ 常驻 ≠ 吵：头部本身是安静的（`bgElevated` 底 + `textTertiary` 文字 + `bgPill` 胶囊），
    ///    它现在的角色是**代码块的标签栏**，不是浮出来的工具条。
    /// ⚠️ **四件一个不少** —— 折行是长命令的唯一出口（见 `codeText` 上那段注释），
    ///    复制是高频动作；删掉任何一件都是拿功能换观感（那是倒退，不是变好）。
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(CodexTheme.accent.opacity(0.75))
                    .frame(width: 5, height: 5)
                Text(language ?? "code")
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textTertiary)
                    .textCase(.lowercase)
                Spacer()
                wrapToggle
                Button(action: { copyCode() }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(LK(copied ? "已复制" : "复制"))
                            .font(CodexTheme.fontTiny)
                    }
                    .foregroundStyle(copied ? CodexTheme.toolDone : CodexTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CodexTheme.bgPill.opacity(0.8))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(CodexTheme.bgElevated)

            Rectangle()
                .fill(CodexTheme.divider)
                .frame(height: 1)
        }
    }

    // MARK: - 折行开关

    /// 药丸与「复制」同款 (bgPill 胶囊 · 11pt), 亮起用 accent 区分开/关。
    private var wrapToggle: some View {
        Button(action: {
            withAnimation(CodexTheme.animFast) { wrapped.toggle() }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10))
                Text(LK("换行"))
                    .font(CodexTheme.fontTiny)
            }
            .foregroundStyle(wrapped ? CodexTheme.accent : CodexTheme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(CodexTheme.bgPill.opacity(0.8))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("长行折行显示")
    }

    // MARK: - 正文

    /// ⚠️ 折行态**不能**留在横滚容器里 —— `ScrollView(.horizontal)` 给的是无界宽度提案,
    /// 折行在其中永远不会触发 (症状: 按了开关毫无变化)。
    /// 代码正文。**超过 `Tune.codeBlockSplitLines` 行就逐行渲染** —— 不是审美选择, 是性能:
    /// 一个 `Text` 承载又宽又长的横滚文本, 排版代价是平方级的(2026-10-29 boss 报往上拉卡顿)。
    /// 短的仍然走整块那一路, 与原来的渲染**逐字相同**。
    @ViewBuilder
    private var codeText: some View {
        if lineCount > Tune.codeBlockSplitLines {
            VStack(alignment: .leading, spacing: Tune.mdCodeLineSpacing) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineText(line)
                        .font(CodexTheme.fontMono)
                        .foregroundStyle(CodexTheme.textPrimary)
                        // ⚠️ 光靠 VStack 的 spacing 不够: 折行态下一行本身会折成好几行, 那几行
                        //    之间的行距归 `lineSpacing` 管, 不管的话折行态会比原来紧。
                        .lineSpacing(Tune.mdCodeLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: !wrapped, vertical: true)
                }
            }
        } else {
            Text(CodeHighlighter.highlightCached(code, language: language))
                .font(CodexTheme.fontMono)
                .foregroundStyle(CodexTheme.textPrimary)
                .lineSpacing(Tune.mdCodeLineSpacing)
                .textSelection(.enabled)
                // 横滚态按内容撑开 (不被提案压扁); 折行态放开水平约束, 允许按栏宽折
                .fixedSize(horizontal: !wrapped, vertical: true)
        }
    }

    /// 逐行渲染时的**一行**。空行要占一个空格 —— `Text("")` 的高度是 0, 空行会被吃掉。
    private func lineText(_ line: AttributedString) -> Text {
        Text(line.characters.isEmpty ? AttributedString(" ") : line)
    }

    /// 行数。O(n) 扫一遍即可 —— 与"排版 n 行"不是一个量级。
    private var lineCount: Int {
        code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private var lines: [AttributedString] {
        CodeHighlighter.highlightLinesCached(code, language: language)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
