//
//  CodexControls.swift
//  UI 细节打磨 (2026-09-09): 系统原生控件 (NSSegmentedControl / NSSwitch) 的自绘替换。
//  视觉语言对齐 TopBar modePill / Scheduled kindSelector: bgElevated 容器 + bgBase 滑块 + 柔影。
//

import SwiftUI

// MARK: - 自绘段选 (替换 .pickerStyle(.segmented))

struct CodexSegmented: View {
    let options: [LocalizedStringKey]
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

// MARK: - 胶囊标签下拉菜单 (编辑器 pill 行共用)

/// bgPill 底 + 描边的胶囊胶囊, 内含一个 borderless Menu。
///
/// ⚠️ 两条实测约束 (2026-09-18 联调):
/// 1. `content` 里**只能放** Button / Toggle / Picker / Link —— 想做"单选菜单"时顺手写
///    `Text(x).tag(y)` 是**静默失效**的: Menu 会展开, 但每一项都渲染成灰色、点不动的死项
///    (`.tag` 只在 Picker 里有意义)。单选题就写 `Button { sel = y } label: { Text(x) }`。
/// 2. `label` 只放 Image + Text 各一个 —— borderlessButton Menu 会丢弃多余子视图。
struct CodexPillMenu<Content: View, Label: View>: View {
    private let content: Content
    private let label: Label

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 4) { label }
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(CodexTheme.bgPill)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
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

// MARK: - 运行中指示 (P9 实机反馈: TimelineView 逐帧驱动在流式期主线程拥堵时掉帧)
// 旧实现 .animation(minimumInterval: 1/30) 每帧在主线程重算子树, 流式 chunk 处理挤占主线程
// 时 tick 迟到 → 角度大步跳变 (掉帧感)。新实现: 低频 tick + .animation 让 CA
// 在渲染服务端插值 —— 主线程繁忙不再影响帧率 (逐帧合成成本在 CA 侧, 恒定)。
// tick 越短, 主线程拥堵导致 commit 迟到时的停顿-追赶窗口越短; 每次 tick 只是微秒级子树
// diff, 2Hz 开销可忽略 (真坑是旧的逐帧 SwiftUI 重算)。
// 注意: 不用 .repeatForever 隐式动画 (侧栏行复用/重建丢事务, 动画不启动 —— 见 MEMORY 教训);
// 本方案 value 驱动 (k 离散递增), 行重建时同值重算不重提交动画, 无事务丢失问题。
// 四种形态: .asteriskSpin 星芒慢旋+微呼吸 (默认, 对齐 Claude loading 标) / .asterisk 星芒纯呼吸 /
// .spin 旋转弧 / .breathe 呼吸环。呼吸类相位抖动感知免疫; 星芒加慢旋后转动的连续性由 CA 插值,
// 停顿感进一步被"辐条对称性 + 呼吸"掩盖。
struct CodexSpinner: View {
    enum Style { case asteriskSpin, asterisk, breathe, spin }
    var style: Style = .asteriskSpin
    var color: Color = CodexTheme.toolDone
    /// tick 周期 (秒)。spin/asteriskSpin 态角速度恒定 450°/s: 步长 = 450°/s × tick; 呼吸态 = 半个呼吸周期。
    var tick: Double = 0.5
    /// 周期锚点: @State 初值只在行生命周期内取一次, TimelineView schedule 稳定不重启。
    @State private var start = Date.now

    var body: some View {
        TimelineView(.periodic(from: start, by: tick)) { ctx in
            let k = Int((ctx.date.timeIntervalSince(start) / tick).rounded(.down))
            switch style {
            case .asteriskSpin:
                // 内层呼吸 (easeInOut) / 外层慢旋 (linear): 嵌套 .animation(value:) 各管各的属性
                asteriskGlyph
                    .opacity(k % 2 == 0 ? 1.0 : 0.55)
                    .scaleEffect(k % 2 == 0 ? 1.0 : 0.9)
                    .animation(.easeInOut(duration: tick), value: k)
                    .rotationEffect(.degrees(Double(k) * 450.0 * tick))
                    .animation(.linear(duration: tick), value: k)
            case .asterisk:
                asteriskGlyph
                    .opacity(k % 2 == 0 ? 1.0 : 0.35)
                    .scaleEffect(k % 2 == 0 ? 1.0 : 0.75)
                    .animation(.easeInOut(duration: tick), value: k)
            case .breathe:
                Circle()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .opacity(k % 2 == 0 ? 1.0 : 0.3)
                    .scaleEffect(k % 2 == 0 ? 1.0 : 0.78)
                    .animation(.easeInOut(duration: tick), value: k)
            case .spin:
                ZStack {
                    Circle()
                        .stroke(CodexTheme.textMuted.opacity(0.22), lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(Double(k) * 450.0 * tick))
                        .animation(.linear(duration: tick), value: k)
                }
            }
        }
        .frame(width: 12, height: 12)
    }

    /// 星芒字形: 6 根圆头辐条从内径向外辐射, 中心留空 (对齐参考图, 不糊心)。
    /// 12pt 槽位: 内径 1.8 / 外径 5.4, 辐条长 3.6。
    private var asteriskGlyph: some View {
        let inner: CGFloat = 1.8
        let outer: CGFloat = 5.4
        let h = outer - inner
        return ZStack {
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 1.4, height: h)
                    .offset(y: -(inner + h / 2))
                    .rotationEffect(.degrees(Double(i) * 60))
            }
        }
    }
}
