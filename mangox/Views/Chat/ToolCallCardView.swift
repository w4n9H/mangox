//
//  ToolCallCardView.swift
//  Tool card: kind tag · target · right-side phase badge · optional detail rows.
//

import SwiftUI

struct ToolCallCardView: View {
    let tool: ToolCall
    var onApprove: (() -> Void)? = nil
    var onDeny: (() -> Void)? = nil
    var onAlwaysAllow: (() -> Void)? = nil
    @State private var expanded: Bool = true
    @State private var outputExpanded: Bool = false
    @State private var copied: Bool = false

    /// Any detail row long enough to need expand/collapse.
    private var hasLongOutput: Bool {
        tool.details.contains { $0.value.count > 80 || $0.value.contains("\n") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row: kind tag · title (· command) · status badge
            HStack(spacing: 10) {
                Text(tool.kind.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(railColor)
                    .frame(minWidth: 40, alignment: .leading)

                Text(tool.title)
                    .font(CodexTheme.fontMonoSm)
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineLimit(1)

                if let cmd = tool.command {
                    Text(cmd)
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                phaseBadge
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            // Optional detail rows (path / 输出 / ...) + 工具产出的图片
            if expanded, !tool.details.isEmpty || !tool.imagePaths.isEmpty {
                Rectangle()
                    .fill(CodexTheme.divider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 4) {
                    // Output header: label · copy all · expand toggle
                    HStack(spacing: 6) {
                        Text("输出")
                            .font(CodexTheme.fontLabel)
                            .foregroundStyle(CodexTheme.textTertiary)
                        Spacer()
                        Button(action: { copyAllOutput() }) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9))
                                .foregroundStyle(copied ? CodexTheme.toolDone : CodexTheme.textTertiary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help("复制全部输出")

                        if hasLongOutput {
                            Button(action: {
                                withAnimation(CodexTheme.animFast) { outputExpanded.toggle() }
                            }) {
                                Image(systemName: outputExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(CodexTheme.textTertiary)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain)
                            .help(LK(outputExpanded ? "收起" : "展开全部"))
                        }
                    }

                    ForEach(Array(tool.details.enumerated()), id: \.offset) { _, d in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            // 分节头已是"输出", 行内同 key 不再重复打印
                            if d.key != "输出" {
                                Text(LK(d.key))
                                    .font(CodexTheme.fontMonoXs)
                                    .foregroundStyle(CodexTheme.textTertiary)
                                    .frame(width: 36, alignment: .leading)
                            }
                            Text(d.value)
                                .font(CodexTheme.fontMonoXs)
                                .foregroundStyle(CodexTheme.textSecondary)
                                .lineLimit(outputExpanded ? nil : 2)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }

                    // 工具产出的图片 (读图工具 / 生成图工具): 排在文本输出之后。
                    // 不另起小标题 —— 缩略图自明, 多一行标签只会把卡片读成两段。
                    if !tool.imagePaths.isEmpty {
                        ToolOutputImages(paths: tool.imagePaths)
                            .padding(.top, tool.details.isEmpty ? 0 : 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }

            // Approval footer — shown while the tool is waiting for the user.
            if tool.phase == .awaitingApproval {
                Rectangle()
                    .fill(CodexTheme.divider)
                    .frame(height: 1)
                if let diff = tool.diffText, !diff.isEmpty {
                    DiffPreviewView(diffText: diff)
                    Rectangle()
                        .fill(CodexTheme.divider)
                        .frame(height: 1)
                }
                approvalFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
        .onTapGesture {
            withAnimation(CodexTheme.animFast) { expanded.toggle() }
        }
    }

    // MARK: - Approval footer

    private var approvalFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.toolError)
                Text("此操作需要你的批准才能执行")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
            }

            HStack(spacing: 8) {
                if let onAlwaysAllow {
                    Button(action: onAlwaysAllow) {
                        Text("始终允许")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CodexTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CodexTheme.bgElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if let onDeny {
                    Button(action: onDeny) {
                        Text("拒绝")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CodexTheme.toolError)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(CodexTheme.toolError.opacity(0.6), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                if let onApprove {
                    Button(action: onApprove) {
                        Text("允许")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .background(CodexTheme.toolDone)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(CodexTheme.toolError.opacity(0.06))
    }

    // MARK: - Helpers

    private func copyAllOutput() {
        // 复制出去的内容**跟随语言** —— 详情键在界面上本来就是查表显示的 (LK(d.key)),
        // 若复制出来恒是中文, 英文界面下就成了另一种不一致。`L()` 收运行时字符串, 未命中回落原串。
        var lines = tool.details.map { "\(L($0.key)): \($0.value)" }
        // 图片按路径入列 —— 只有图片没有文本时 (典型: read 一张截图) 复制也**不会是个空操作**。
        // ⚠️ 带插值的串必须写 `String(format: L("…%@…"), x)` (禁令 ⑤: L() 禁插值)。
        lines.append(contentsOf: tool.imagePaths.map { String(format: L("图片: %@"), $0) })
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private var railColor: Color {
        switch tool.phase {
        case .running:
            return CodexTheme.toolRunning
        case .done:
            return CodexTheme.textSecondary   // 完成态工具标签素色 (Codex 风格, 不上彩色)
        case .awaitingApproval:
            return CodexTheme.toolError
        case .error:
            return CodexTheme.toolError
        case .queued:
            return CodexTheme.toolQueued
        }
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch tool.phase {
        case .running:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .tint(CodexTheme.toolRunning)
                Text(tool.phase.label)
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.toolRunning)
            }
        case .done:
            HStack(spacing: 6) {
                if let ms = tool.durationMs {
                    // verbatim: Text 字符串插值走 LocalizedStringKey 会给 Int 加千位分隔符
                    // (6533 → "6,533ms"); ≥1s 换算成 x.xs 更易读
                    Text(verbatim: ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms")
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                Text(tool.phase.label)
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.toolDone)
            }
        case .awaitingApproval:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text(tool.phase.label)
                    .font(CodexTheme.fontMonoXs)
            }
            .foregroundStyle(CodexTheme.toolError)
        case .error(let msg):
            Text(msg)
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.toolError)
        case .queued:
            Text(tool.phase.label)
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textTertiary)
        }
    }
}

// MARK: - Diff preview (edit/write 审批)

/// 审批卡内的改动预览: 扩展侧生成的行前缀 diff (- 旧 / + 新 / FILE 头 / ·· 分隔)。
/// 块对照式 (不做行对齐), 高度受限内滚动; 用户先看改动再决定允许/拒绝。
struct DiffPreviewView: View {
    let diffText: String

    private func color(for line: String) -> Color {
        if line.hasPrefix("- ") { return CodexTheme.toolError }
        if line.hasPrefix("+ ") { return CodexTheme.toolDone }
        if line.hasPrefix("FILE ") { return CodexTheme.textSecondary }
        return CodexTheme.textMuted
    }

    private func bg(for line: String) -> Color {
        if line.hasPrefix("- ") { return CodexTheme.toolError.opacity(0.08) }
        if line.hasPrefix("+ ") { return CodexTheme.toolDone.opacity(0.08) }
        return Color.clear
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diffText.split(separator: "\n").enumerated()),
                        id: \.offset) { _, line in
                    let s = String(line)
                    Text(s)
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(color(for: s))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bg(for: s))
                        .padding(.horizontal, 10)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 260)
        .background(CodexTheme.bgBase)
    }
}
