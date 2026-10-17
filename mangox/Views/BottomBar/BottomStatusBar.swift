//
//  BottomStatusBar.swift
//  P6.1.1/P6.1.2: 主区底部状态栏, 4 项纯展示 (无交互控件):
//  过程态胶囊 · 上下文 % · Token ↑↓ · 当前会话 N 轮
//  (费用→Trace Details; 模型/思考→composer 菜单; P6 设计 §2.2 拍板)
//

import SwiftUI

struct BottomStatusBar: View {
    let phase: RuntimePhase
    let turnCount: Int
    let stats: SessionStats?

    var body: some View {
        HStack(spacing: 10) {
            // 过程态胶囊 (P6.1.2: retrying/compacting/summarizing/queued; amber 警示但不响)
            HStack(spacing: 4) {
                Circle()
                    .fill(capsuleColor)
                    .frame(width: 6, height: 6)
                Text(phase.capsuleText)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
            }
            .foregroundStyle(capsuleColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(CodexTheme.bgCard)
            .clipShape(Capsule())

            dot

            Text(contextText)
                .font(CodexFonts.monoFont(10))
                .foregroundStyle(CodexTheme.textSecondary)

            dot

            Text("Token ↑\(tokenText(stats?.inputTokens)) / ↓\(tokenText(stats?.outputTokens))")
                .font(CodexFonts.monoFont(10))
                .foregroundStyle(CodexTheme.textSecondary)

            dot

            Text("当前会话 \(turnCount) 轮")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textSecondary)

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: Tune.bottomBarHeight)
        // P10.8c: 与正文面同面 (理由见 ChatComposer 同处注释) —— 底档整块只有一种底色,
        // 面板内部零硬边。它与输入区同色时会和输入区拼成一块板, 所以一起收回正文面;
        // 分区改由顶部这条 1px 线承担 (`divider` 在正文面上 ΔL*≈5.6, 看得见)。
        .background(CodexTheme.contentPanel)
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .top
        )
    }

    /// idle = 灰 / streaming = 主色 / 过程态 = amber (toolRunning 同源)
    private var capsuleColor: Color {
        switch phase {
        case .idle:       return CodexTheme.textTertiary
        case .streaming:  return CodexTheme.accent
        default:          return CodexTheme.thinking
        }
    }

    private var dot: some View {
        Text("·")
            .font(.system(size: 10))
            .foregroundStyle(CodexTheme.textMuted)
    }

    /// 上下文用量 —— **带压缩线** (D)。
    ///
    /// 两段式而不是恒两段: `compactionLinePercent` 需要窗口 + 预算都已知 (预算由
    /// `PiCompactionBudget` 在 spawn 期解析)。任一缺失就退回只显示百分比 ——
    /// 画一条猜出来的线比不画更坏 (用户会据此判断"还能聊多久")。
    ///
    /// `contextPercent == nil` 只剩一种来源 = 本会话还没上报过统计 (见 SessionStats 注释);
    /// 压缩后不再是 nil —— `ChatStore.applyCompactionTokens` 会当场用 pi 的估算值接管。
    private var contextText: String {
        let pct = stats?.contextPercent.map { String(format: "%.1f%%", $0) } ?? "--"
        guard let line = stats?.compactionLinePercent else {
            return String(format: L("上下文 %@"), pct)
        }
        return Copy.contextWithLine(pct, String(format: "%.1f%%", line))
    }

    private func tokenText(_ v: Int?) -> String {
        guard let v else { return "--" }
        return "\(v)"
    }
}
