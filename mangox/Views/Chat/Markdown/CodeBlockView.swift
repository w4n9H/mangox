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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: language + wrap toggle + copy action
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
    private var codeText: some View {
        Text(CodeHighlighter.highlightCached(code, language: language))
            .font(CodexTheme.fontMono)
            .foregroundStyle(CodexTheme.textPrimary)
            .lineSpacing(Tune.mdCodeLineSpacing)
            .textSelection(.enabled)
            // 横滚态按内容撑开 (不被提案压扁); 折行态放开水平约束, 允许按栏宽折
            .fixedSize(horizontal: !wrapped, vertical: true)
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
