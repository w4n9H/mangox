//
//  ModelPicker.swift
//  受控模型选择控件: 一根药丸 → popover (上半模型列表 + 下半思考强度滑轨)。
//
//  契约 (2026-09-23 模型链路收敛):
//   · **值进值出**: 只吃 `choice`, 只吐 `onPick` —— 不读全局 store、不写任何状态。
//     所以同一个控件既能驱动 composer 的「全局期望」, 也能驱动定时任务的「仅本任务」配置。
//   · **clamp 内聚**: 换模型后级别收敛到该模型的合法停靠点, 由 `onPick` 一并吐出,
//     宿主无须知道 supportedLevels。⇒ "胶囊显示 xhigh、实际跑 off" 这类割裂不可能出现。
//   · **必须 popover, 不能用 Menu**: `borderlessButton` Menu 的 label 只渲染"首个 Image +
//     首个 Text" (NSMenu title 机制), 而本控件下半是自绘滑轨。`modeMenu` 已是同款先例。
//   · **药丸有两档形态** (2026-09-24): 默认**裸标签** —— composer 用它坐在底栏上, 不需要底;
//     嵌进 pill 行时传 `pillChrome: true` 取 `CodexPillMenu` 同款胶囊底。**别只在宿主加底**:
//     不带底时它在一排真胶囊里就是个飘着的裸字, 看起来"特别窄" (boss 截图实证)。
//

import SwiftUI

struct ModelPicker: View {
    /// 候选模型 (来源由宿主决定: composer 传 `store.model.menuModels`)。
    let models: [AgentModelInfo]
    /// 当前值。
    let choice: ModelChoice
    /// 显示名解析 (策略归宿主: composer 走自管 label, 未配时回落 pi 上报的 name)。
    let title: (AgentModelInfo) -> String
    /// 无匹配模型时药丸上的文案 (通常是"当前显示名")。
    var fallbackTitle: String = ""
    /// 悬停提示 (文案归宿主 —— 复用点不同, 语义也不同)。
    var helpText: String = ""
    /// 给药丸套上 `CodexPillMenu` 同款胶囊底 (嵌在 pill 行里时开)。
    var pillChrome: Bool = false
    let onPick: (ModelChoice) -> Void

    @State private var showPanel = false

    /// 面板宽度与 modeMenu 同款 (同一个 popover 家族, 宽窄不一致会显脏)。
    private let panelWidth: CGFloat = 320
    /// 模型列表滚动上限 (超出后列表内滚, 滑轨恒可见)。
    private let listMaxHeight: CGFloat = 240
    /// 滑轨几何 (2026-09-24: 粗胶囊轨 → 再加粗一档): 轨 20px, 把手 26px (上下各外凸 3px)。
    private let trackHeight: CGFloat = 20
    private let knobSize: CGFloat = 26
    /// 停靠点圆点直径 (轨上每一档都画一颗)。
    private let stopDotSize: CGFloat = 6
    /// 轨的**全宽**渐变, 颜色本身就在说"越往右想得越多"。
    /// 三段取色与"亮暗共用一套"的理由都在 `CodexTheme` 的「思考强度轨」段 —— 蓝→紫→洋红。
    private let railGradient = LinearGradient(
        colors: [CodexTheme.railStart, CodexTheme.railMid, CodexTheme.railEnd],
        startPoint: .leading, endPoint: .trailing
    )

    private var current: AgentModelInfo? {
        models.first { $0.provider == choice.provider && $0.id == choice.modelId }
    }

    private var displayTitle: String {
        if let current { return title(current) }
        if !fallbackTitle.isEmpty { return fallbackTitle }
        return choice.modelId.isEmpty ? "model" : choice.modelId
    }

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            pill
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            panel
        }
        .modifier(HelpIfPresent(text: helpText))
    }

    // MARK: - 药丸

    /// 药丸文本。保持**单 Text 拼接**: 旧版受 borderlessButton 上述限制才拼串, 换成 HStack 虽可渲染,
    /// 但行高/图标基线会回归 ⇒ 为"逐像素不变"留形 (2026-09-23)。裸/带底两档共用这一段, 只换外壳。
    private var pillText: Text {
        (Text(Image(systemName: "bolt.fill"))
            .font(.system(size: Tune.boltIconSize)).foregroundColor(CodexTheme.textMuted)
         + Text(" \(displayTitle)")
            .font(CodexTheme.fontSmall).foregroundColor(CodexTheme.textTertiary)
         + Text(" \(choice.level.displayName)")
            .font(.system(size: Tune.levelFontSize, weight: .semibold)).foregroundColor(CodexTheme.textPrimary)
         + Text(Image(systemName: "chevron.down"))
            .font(.system(size: Tune.chevronIconSize, weight: .semibold)).foregroundColor(CodexTheme.textMuted))
    }

    @ViewBuilder private var pill: some View {
        if pillChrome {
            // 与 `CodexPillMenu` **逐项同配方** (同左右/上下内距 + bgPill + 同透明度描边)。
            // 高度不用 `Tune.pillHeight` 硬塞: 两边正文都是 12pt (`fontSmall` / `levelFontSize`),
            // 同配方 ⇒ 天然等高。硬塞反而会让这个 pill 比页面上其他 pill 高 3px。
            pillText
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CodexTheme.bgPill)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
                .contentShape(Rectangle())
        } else {
            pillText
                .frame(height: Tune.pillHeight)
                .contentShape(Rectangle())
        }
    }

    // MARK: - 面板

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if models.isEmpty {
                // pi 尚未上报且无自管条目: 只报当前值, 不给空列表假象。
                Text(displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // 用下标作 id: `menuModels` 理论上不会重复, 但同 id 撞车会让
                        // ForEach 直接崩 —— 复用件不值得赌这一把。
                        ForEach(models.indices, id: \.self) { i in
                            modelRow(models[i])
                        }
                    }
                }
                .frame(maxHeight: listMaxHeight)
            }
            Divider()
            levelSlider
        }
        .padding(.vertical, 5)
        .frame(width: panelWidth)
    }

    private func modelRow(_ m: AgentModelInfo) -> some View {
        let selected = m.provider == choice.provider && m.id == choice.modelId
        return Button {
            // 换模型: 级别就地收敛后一并吐出。**不关面板** —— 接着拖强度是常态操作。
            onPick(ModelChoice(provider: m.provider, modelId: m.id,
                               level: clampLevel(choice.level, to: m)))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(m))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text(m.provider)
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textMuted)
                }
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CodexTheme.textPrimary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? CodexTheme.bgSidebar : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 思考强度滑轨

    private var levelSlider: some View {
        let stops = thinkingStops(for: current)
        let idx = stops.firstIndex(of: clampLevel(choice.level, to: current)) ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                // 档位名走 displayName (英文常量): rawValue 是契约 token, 不作展示。
                Text(stops[idx].displayName)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textPrimary)
                Spacer(minLength: 8)
            }
            // 端点提示那行已删 (2026-09-24): 粗胶囊轨上的刻度自己就说明了范围。
            // spacing 4→2 是补偿 —— 把手比轨高 6px, 那 3px 外凸已经算进视觉间距。
            track(stops: stops, idx: idx)
                .frame(height: knobSize)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// 第 i 个停靠点在轨内的横坐标 (把手中心)。
    /// ⚠️ 必须是方法, 不能写成 `track` 里的局部 `func` —— GeometryReader 的闭包是 ViewBuilder,
    /// 里面只许放表达式, 放声明会直接编译失败 (2026-09-24 实测)。
    private func stopCenter(_ i: Int, travel: CGFloat, gaps: Int) -> CGFloat {
        travel * CGFloat(i) / CGFloat(gaps) + knobSize / 2
    }

    /// 自绘拖拽轨道 (粗胶囊 + 渐变): 只在 `stops` 上吸附 —— 模型不支持的档位**不是停靠点**,
    /// 拖动时直接跨过。
    ///
    /// **两层同款渐变** (2026-09-24 boss: 「思考等级越高颜色越偏向紫色」):
    ///   ① 床 = 满宽渐变 @0.28 透明度 ⇒ "能拉到哪" 范围始终可见 (且是低饱和的同色系);
    ///   ② 已达成段 = **同一渐变裁到把手位置** ⇒ 档位越高露出的越多、末端越紫。
    ///
    /// ⚠️ 裁切必须用 `mask` **不能改用窄 `frame`** —— 渐变会按自身 frame 重算比例,
    /// 那样低档时会在那一小截里把整条蓝→紫压完 (颜色与档位脱钩, 正是这轮要修的毛病)。
    private func track(stops: [ThinkingLevel], idx: Int) -> some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let gaps = max(stops.count - 1, 1)
            // 把手行程要扣掉自身宽度, 否则两端把手会溢出轨外 (系统滑块同口径)。
            let travel = max(w - knobSize, 0)
            let mid = knobSize / 2
            let x = stopCenter(min(max(idx, 0), stops.count - 1), travel: travel, gaps: gaps)
            ZStack(alignment: .leading) {
                Capsule().fill(railGradient)
                    .frame(width: w, height: trackHeight)
                    .opacity(0.28)
                    .position(x: w / 2, y: mid)
                Capsule().fill(railGradient)
                    .frame(width: w, height: trackHeight)
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                    .position(x: w / 2, y: mid)
                // 停靠点**全档都画** (告诉用户"总共几档、有没有被模型剔掉"), 半透明以免与把手抢。
                ForEach(stops.indices, id: \.self) { i in
                    Circle().fill(CodexTheme.bgBase.opacity(0.55))
                        .frame(width: stopDotSize, height: stopDotSize)
                        .position(x: stopCenter(i, travel: travel, gaps: gaps), y: mid)
                }
                // 把手: 亮色下即参考图那颗白圆; 暗色下 `bgBase` 翻成近黑 —— 纯白在暗色里
                // 会是整屏最亮的一点, 犯 P10.8「暗色不再累眼」。细描边只为白底上仍能看出版式。
                Circle().fill(CodexTheme.bgBase)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(Circle().stroke(CodexTheme.border.opacity(0.7), lineWidth: 0.5))
                    .position(x: x, y: mid)
            }
            .frame(height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0 ⇒ 单击轨道也落档, 不必精确拖拽。
                DragGesture(minimumDistance: 0).onChanged { v in
                    let raw = v.location.x - mid
                    let ratio = travel <= 0 ? 0 : min(max(raw, 0), travel) / travel
                    let slot = Int((ratio * CGFloat(gaps)).rounded())
                    let landed = min(max(slot, 0), stops.count - 1)
                    guard landed != idx else { return }
                    onPick(ModelChoice(provider: choice.provider, modelId: choice.modelId,
                                       level: stops[landed]))
                }
            )
        }
    }
}

/// `.help` 只在宿主给了文案时才挂 (复用件不该替宿主编提示语)。
private struct HelpIfPresent: ViewModifier {
    let text: String
    @ViewBuilder func body(content: Content) -> some View {
        if text.isEmpty { content } else { content.help(Text(text)) }
    }
}
