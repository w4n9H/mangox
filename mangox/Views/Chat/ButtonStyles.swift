//
//  ButtonStyles.swift
//  Shared button styles for plan / confirmation actions.
//

import SwiftUI

struct CodexPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CodexTheme.fontButton)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(CodexTheme.accent.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
    }
}

/// 实底次要按钮 (plan 卡片的主/次操作对里用; 与 hover ghost 的 CodexGhostButtonStyle 区分)。
struct CodexTonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CodexTheme.fontButton)
            .foregroundStyle(CodexTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(CodexTheme.bgCard.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
    }
}
