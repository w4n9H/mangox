//
//  CodexControls.swift
//  UI 细节打磨 (2026-09-09): 系统原生控件 (NSSegmentedControl / NSSwitch) 的自绘替换。
//  视觉语言对齐 TopBar modePill / Scheduled kindSelector: bgElevated 容器 + bgBase 滑块 + 柔影。
//

import SwiftUI

// MARK: - 自绘段选 (替换 .pickerStyle(.segmented))

struct CodexSegmented: View {
    let options: [String]
    @Binding var selection: Int
    @State private var hovering: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Button(action: {
                    withAnimation(CodexTheme.animFast) { selection = i }
                }) {
                    Text(options[i])
                        .font(CodexTheme.fontSmall.weight(selection == i ? .medium : .regular))
                        .foregroundStyle(selection == i
                                         ? CodexTheme.textPrimary
                                         : (hovering == i ? CodexTheme.textSecondary : CodexTheme.textTertiary))
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(
                            selection == i ? CodexTheme.bgBase
                            : (hovering == i ? CodexTheme.bgElevated : Color.clear)
                        )
                        .clipShape(Capsule())
                        .shadow(color: selection == i ? .black.opacity(0.08) : .clear,
                                radius: 1.5, y: 0.5)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 ? i : nil }
            }
        }
        .padding(2)
        .background(CodexTheme.bgElevated)
        .clipShape(Capsule())
    }
}

// MARK: - 自绘 mini 开关 (替换 .toggleStyle(.switch))

struct CodexMiniToggle: View {
    @Binding var isOn: Bool
    var disabled: Bool = false
    @State private var hovering: Bool = false

    var body: some View {
        Button(action: {
            guard !disabled else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { isOn.toggle() }
        }) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isOn ? CodexTheme.accent
                          : (hovering ? CodexTheme.bgElevated : CodexTheme.bgPill))
                    .overlay(Capsule().stroke(
                        isOn ? Color.clear : CodexTheme.border.opacity(0.6), lineWidth: 1))
                Circle()
                    .fill(isOn ? Color.white : CodexTheme.textTertiary)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .offset(x: isOn ? 16 : 3)
            }
            .frame(width: 29, height: 16)
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(CodexTheme.animFast, value: hovering)
    }
}

// MARK: - hover 文字按钮 (替换裸 .plain 的"删除/保存"类动作)

/// 默认态 = 文字色, hover = 浅底圆角 (与 navRow 同语言), 按压加深。
struct CodexGhostButtonStyle: ButtonStyle {
    /// 覆盖默认前景色 (如删除按钮的红色); nil 用 textPrimary。
    var foreground: Color = CodexTheme.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        HoverGhostLabel(foreground: foreground,
                        pressed: configuration.isPressed) {
            configuration.label
        }
    }

    private struct HoverGhostLabel: View {
        let foreground: Color
        let pressed: Bool
        let label: () -> any View
        @State private var hovering = false

        var body: some View {
            AnyView(label())
                .foregroundStyle(foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (hovering ? CodexTheme.bgElevated : Color.clear)
                        .opacity(pressed ? 1.5 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - 面板动作按钮 (保存/删除级: 有明确边界, 克制配色)

/// primary = 实底深色 (与发送按钮同语言, Codex CTA 风);
/// danger = 中性描边 + 灰字, hover 才变红 (平时不扎眼);
/// success = 保存成功的短闪态 (绿实底)。
struct CodexActionButtonStyle: ButtonStyle {
    enum Kind { case primary, danger, success }
    var kind: Kind
    var disabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ActionLabel(kind: kind, disabled: disabled, pressed: configuration.isPressed) {
            configuration.label
        }
    }

    private struct ActionLabel: View {
        let kind: Kind
        let disabled: Bool
        let pressed: Bool
        let label: () -> any View
        @State private var hovering = false

        private var fg: Color {
            switch kind {
            case .primary:
                return disabled ? CodexTheme.textMuted : CodexTheme.bgBase
            case .success:
                return CodexTheme.bgBase   // 闪现态不受 disabled 灰化 (否则绿底灰字看不清)
            case .danger:
                return disabled ? CodexTheme.textMuted
                    : (hovering ? CodexTheme.toolError : CodexTheme.textSecondary)
            }
        }

        private var bg: Color {
            switch kind {
            case .primary:
                return disabled ? CodexTheme.bgPill : CodexTheme.textPrimary
            case .success:
                return CodexTheme.toolDone
            case .danger:
                return (hovering && !disabled) ? CodexTheme.bgElevated : Color.clear
            }
        }

        private var stroke: Color {
            switch kind {
            case .primary, .success: return .clear
            case .danger:
                if disabled { return CodexTheme.border.opacity(0.4) }
                return hovering ? CodexTheme.toolError.opacity(0.5) : CodexTheme.border.opacity(0.8)
            }
        }

        var body: some View {
            AnyView(label())
                .font(CodexTheme.fontSmall.weight(.medium))
                .foregroundStyle(fg)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(bg.opacity(pressed && kind != .success ? 0.8 : 1))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(stroke, lineWidth: 1))
                .opacity(kind == .success ? 1 : (disabled ? 0.6 : 1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(CodexTheme.animFast, value: hovering)
        }
    }
}
