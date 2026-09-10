//
//  PlanQuestionCardView.swift
//

import SwiftUI

struct PlanQuestionCardView: View {
    let question: PlanQuestion
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12))
                    .foregroundStyle(CodexTheme.accent)
                Text("Plan question")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(CodexTheme.accent)
            }
            Text(question.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            if let body = question.body {
                Text(body)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
            }
            VStack(spacing: 6) {
                ForEach(question.options) { opt in
                    OptionRow(option: opt, isSelected: opt.id == selected) {
                        withAnimation(CodexTheme.animFast) { selected = opt.id }
                    }
                }
            }
            HStack(spacing: 8) {
                if question.allowsCustom {
                    Button("Custom answer…") {}
                        .buttonStyle(CodexTonalButtonStyle())
                }
                Spacer()
                Button("Confirm plan") {}
                    .buttonStyle(CodexPrimaryButtonStyle())
                    .disabled(selected == nil)
                    .opacity(selected == nil ? 0.5 : 1)
            }
        }
        .padding(14)
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.accent.opacity(0.4), lineWidth: 1)
        )
    }
}

struct OptionRow: View {
    let option: PlanOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? CodexTheme.accent : CodexTheme.border, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if isSelected {
                        Circle()
                            .fill(CodexTheme.accent)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(CodexTheme.fontBody)
                            .foregroundStyle(CodexTheme.textPrimary)
                        if option.isRecommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(CodexTheme.accentSoft)
                                .foregroundStyle(CodexTheme.accent)
                                .clipShape(Capsule())
                        }
                    }
                    if let d = option.detail {
                        Text(d)
                            .font(CodexTheme.fontSmall)
                            .foregroundStyle(CodexTheme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(isSelected ? CodexTheme.accentSoft : CodexTheme.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
        }
        .buttonStyle(.plain)
    }
}
