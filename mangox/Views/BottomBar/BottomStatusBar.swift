//
//  BottomStatusBar.swift
//  Bottom row:
//  AUTO · {model} · 思考: {effort} · 当前会话 {n} 轮 · 上下文 {p}% · Token ↑{u} / ↓{d} · 缓存 {c}% · 费用 ¥{cny}
//

import SwiftUI

struct BottomStatusBar: View {
    @Binding var status: AgentStatus
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: 10) {
            // AUTO toggle
            Button(action: { status.autoMode.toggle() }) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(status.autoMode ? CodexTheme.statusDone : CodexTheme.textTertiary)
                        .frame(width: 6, height: 6)
                    Text("AUTO")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                }
                .foregroundStyle(status.autoMode ? CodexTheme.textPrimary : CodexTheme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(CodexTheme.bgCard)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            dot

            Text(status.modelName)
                .font(CodexFonts.monoFont(10))
                .foregroundStyle(CodexTheme.textPrimary)

            dot

            // 思考强度 — click to cycle
            Menu {
                ForEach(ReasoningEffort.allCases) { e in
                    Button {
                        status.effort = e
                    } label: {
                        HStack {
                            Text(e.displayName)
                            if status.effort == e {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text("思考: \(status.effort.displayName)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(CodexTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            dot

            Text("当前会话 \(status.turnCount) 轮")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textSecondary)

            dot

            Text("上下文 \(formatted(status.contextPercent))%")
                .font(CodexFonts.monoFont(10))
                .foregroundStyle(CodexTheme.textSecondary)

            dot

            Text("Token ↑\(status.tokenUp) / ↓\(status.tokenDown)")
                .font(CodexFonts.monoFont(10))
                .foregroundStyle(CodexTheme.textSecondary)

            dot

            Text("缓存 \(status.cachePercent)%")
                .font(CodexFonts.monoFont(10))
                .foregroundStyle(CodexTheme.textSecondary)

            dot

            Text("费用 ¥\(String(format: "%.4f", status.costCNY))")
                .font(CodexFonts.monoFont(10))
                .foregroundStyle(CodexTheme.textSecondary)

            Spacer()

            if isStreaming {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).scaleEffect(0.5)
                        .tint(CodexTheme.accent)
                    Text("streaming")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.accent)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Tune.bottomBarHeight)
        .background(CodexTheme.bgBase)
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .top
        )
    }

    private var dot: some View {
        Text("·")
            .font(.system(size: 10))
            .foregroundStyle(CodexTheme.textMuted)
    }

    private func formatted(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}
