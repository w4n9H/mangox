//
//  CodeBlockView.swift
//  Fenced code block: language label · copy button · horizontally scrollable highlighted code.
//

import SwiftUI

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: language + copy action
            HStack(spacing: 6) {
                Circle()
                    .fill(CodexTheme.accent.opacity(0.75))
                    .frame(width: 5, height: 5)
                Text(language ?? "code")
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textTertiary)
                    .textCase(.lowercase)
                Spacer()
                Button(action: { copyCode() }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "已复制" : "复制")
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

            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlight(code, language: language))
                    .font(CodexTheme.fontMono)
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineSpacing(Tune.mdCodeLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radius)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
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
