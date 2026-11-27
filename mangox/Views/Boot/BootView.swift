//
//  BootView.swift
//  启动页（设计稿: `next-version-drafts.html` 稿 2）。
//
//  ── 这一屏的三条硬规矩（设计稿原文，缺一条它就是骗人的）────────────────────
//  ① **每一行对应一次真实动作** —— 数据全部来自 `BootTrace`，这里**一个假动作都不许有**；
//  ② **等它真完成才打勾** —— 本视图不推进任何一格，只负责把 `BootTrace` 的相位画出来；
//  ③ **任意键鼠输入立刻消失**，`SKIP` 常驻右上角，版本号变了才再播一次（`BootGate`）。
//
//  ── 为什么它自己这套配色不搬进 `CodexTheme` ────────────────────────────────
//  正文那套 token 是**面链**（bgBase < bgSidebar < bgChat < …），改一个全 App 跟着变；
//  这一屏是**独立一屏**，纸面 / 扫描线 / 三处状态色全是为"终端"这个意象单独定的值
//  （浅色档成功色 `#1A7F37`、进行中 `#B07A12` 都是暗色号在亮底上糊掉之后另校准的）。
//  混进 `CodexTheme` 会让"改一个 token 全 App 变"这条不成立。所以它是本文件私有的。
//

import SwiftUI
import AppKit

// MARK: - 本屏自用的尺度（唯一一处数字）

private enum BS {
    static let padH: CGFloat = 34
    static let padTop: CGFloat = 30
    static let padBottom: CGFloat = 26
    /// 品牌字。稿子 23px / 字距 .26em。
    static let brandSize: CGFloat = 23
    /// 步骤列 + 进度条同宽（稿子 470）。整屏窄于它时按可用宽收，见 `stepsWidth`。
    static let stepsWidth: CGFloat = 470
    static let rowPadV: CGFloat = 11
    static let rowGap: CGFloat = 12
    static let labelWidth: CGFloat = 132
    /// 第二行（`BOOT SEQUENCE`）与 `SKIP` 的顶距。
    static let railTop: CGFloat = 96
    static let footerBottom: CGFloat = 52

    // ── 节奏（2026-11-27 boss 定）────────────────────────────────────────────
    //
    // **每一步做完停 0.5 秒再揭示下一步。** 起因是实机太快（workspace 8ms / assistants 127 /
    // model 133 全挤在首帧之前，整屏只活 1.1 秒，五行里只有两行看得见"在动"）。
    //   · 0.3s 那版实机量出来行间隔 318ms、整屏 2.0s —— boss 仍说"太快"，抬到 0.5 ⇒ 行间隔约 520ms。
    //
    // ⚠️ 这 0.5s 是**只准拖、不准提前**的：`BootTrace` 仍然是唯一真源，打勾永远发生在真实动作
    //    完成之后；停顿只决定"晚多少揭示"。仍未揭示的行画成排队态（`·` + `—`）——
    //    对"它其实已经做完了"这件事，这一屏是**晚说**，不是**先说**。
    static let stepDwell: Double = 0.5

    // ── 转场 C「光标接管」（稿 `boot-transition.html`，稿子给的是 420ms）────────
    // 四段各自的时间点，全部照抄设计稿的**比例**，一个都不许"顺手调顺"：
    //
    // ⚠️ **tempo = 1.4** 是 boss（2026-11-27）要的"慢一点"：稿子自己写着"超过 400ms 就开始烦人"，
    //    这里**故意越过那条线**，因为稿子是按静态示意图定的，实机 420ms 里四段挤成一团、
    //    看上去像"一刀切"。1.4 ⇒ 588ms，四段各自可辨，仍然在"一遍就完"的量级。
    //    **只改这一个数就整体变速**，别去动下面八个数（改了比例就散了）。
    static let tempo: Double = 1.4

    // ⚠️ 下面的数另外还乘了 `slowmo`。它是**冒烟构建专属**的诊断开关（`--boot-slowmo 6`，
    //    缺省 1 = 原速）：几百毫秒的转场用 `screencapture`（约 7 帧/秒）只抓得到中间一帧，
    //    "光标到底飞没飞、落在哪"在图上分不清。放慢 6 倍就能一帧一帧对轨迹。
    //    正式构建里它是个常量 1 —— 不是可配置项，别当设置用。
    //    走 `--args` 而不是环境变量：`open --env` 实测传不进去（`launchctl setenv` 又没权限）。
    static let slowmo: Double = {
        #if SMOKE
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--boot-slowmo"), i + 1 < a.count,
           let v = Double(a[i + 1]), v > 0 { return v }
        return 1
        #else
        return 1
        #endif
    }()

    /// 转场里所有时长 / 延迟的统一倍数（稿子值 × `tempo` × `slowmo`）。
    private static let beat: Double = tempo * slowmo

    static let caretsOut: Double = 0.16 * beat         // 行退场：linear 160ms
    static let caretsOutLag: Double = 0.02 * beat      //   首行延迟 20ms，之后每行 +25ms
    static let caretsOutStep: Double = 0.025 * beat
    static let brandOut: Double = 0.16 * beat          // 品牌 / 四角 / 进度条
    static let brandOutLag: Double = 0.02 * beat
    static let footOut: Double = 0.14 * beat           // 页脚
    static let footOutLag: Double = 0.01 * beat
    /// 背景层**最后 70ms 才收** —— 早收会让两层同时半透，字叠字。
    static let bgOut: Double = 0.07 * beat
    static let bgOutLag: Double = 0.32 * beat
    /// 光标起飞 / 飞行时长（cubic-bezier(.34,.9,.24,1)）。
    static let flyStart: Double = 0.23 * beat
    static let flyDuration: Double = 0.17 * beat
    /// 整段转场 = 420ms × tempo（当前 588ms）。
    static let transition: Double = 0.42 * beat

    /// 兜底上限。5 步 × 0.5s 停顿本身就是 2.5s，再叠真实等待（引擎 0.6s + 落底 1.4s）⇒ 正常 ≈3.6s。
    /// 超了就收 —— 剩下的行**保持转圈**，不假装做完。
    static let hardCap: Double = 7.0
}

// MARK: - 本屏配色（浅/暗两档，全部走 `NSColor(name:)` 动态解析）

private enum BC {
    private static func boot(_ light: UInt32, _ dark: UInt32) -> Color {
        // 与 `CodexTheme.adaptive` 同一套机制（按 `effectiveAppearance` 现解析），
        // 但**值不是同一组** —— 理由见文件头。
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let bg     = boot(0xFBFBFD, 0x0C0C10)
    static let strong = boot(0x1F242A, 0xE8E8EC)
    static let base   = boot(0x3A4149, 0xC8C8D0)
    static let mid    = boot(0x57606A, 0xA8A8B2)
    static let dim    = boot(0x7A828B, 0x6C6C77)
    static let faint  = boot(0x8C9199, 0x5A5A66)
    static let ghost  = boot(0xBFC4CB, 0x4A4A56)
    static let rule   = boot(0xE8E8EC, 0x1B1B24)
    static let track  = boot(0xE2E2E7, 0x242430)
    static let ok     = boot(0x1A7F37, 0x3FB950)   // 成功：亮底上浅绿直接糊掉，所以两档不同值
    static let run    = boot(0xB07A12, 0xE0A030)   // 进行中：同上
    /// 品牌红 —— **两档共用**，它是身份不是状态（设计稿原话）。
    static let brand  = Color(nsColor: NSColor(hex: 0xDD5742))

    /// 扫描线：暗色是"白线压暗底"，亮色换成"黑线压白底"且透明度更低（否则白底上显脏）。
    static let scan: Color = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.028) : NSColor(white: 0, alpha: 0.016)
    })
    static let vignette: Color = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.045) : NSColor(white: 0, alpha: 0.03)
    })
}

// MARK: - 只播一次

enum BootGate {
    /// 记住"上次播过的版本号"。丢了的代价只是多播一次，所以走 `UserDefaults` 就够了。
    ///
    /// ⚠️ 之所以不走 settings 表（仓里其它设置都在那儿）：这个判据要在 `ChatStore` 建出来
    ///    **之前**就有答案 —— 晚一帧就是"先看见主界面、再被盖住"，闪一下。
    static let versionKey = "boot.lastShownVersion"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func shouldPlay() -> Bool {
        #if DEBUG
        return true   // 开发构建恒播：否则每改一点东西都要先 `defaults write` 一次才看得见
        #else
        return UserDefaults.standard.string(forKey: versionKey) != appVersion
        #endif
    }

    static func markShown() {
        UserDefaults.standard.set(appVersion, forKey: versionKey)
    }
}

// MARK: - 窗口外壳（红绿灯 + 工具栏）

enum BootChrome {
    /// 启动页盖住整窗时，把**窗口壳**也一起让开 —— 否则 `MANGOX` 那个字正好压在红绿灯上，
    /// 右上角还会飘着主界面的工具栏 pill（`.hiddenTitleBar` 下它是浮在内容上面的）。
    ///
    /// 判据只有一条：`hidden == false` 时必须**原样还回去**。所以它不记"原来是什么样"——
    /// 用户本来就没有能力在启动那 3 秒里改这两样东西。
    static func hide(_ hidden: Bool) {
        for w in NSApp.windows where w.isVisible {
            w.standardWindowButton(.closeButton)?.isHidden = hidden
            w.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
            w.standardWindowButton(.zoomButton)?.isHidden = hidden
            w.toolbar?.isVisible = !hidden
        }
    }
}

// MARK: - 视图

struct BootView: View {
    @ObservedObject var trace: BootTrace
    let onDone: () -> Void

    /// 已经**揭示**了几行（不是"完成了几行"）。见 `BS.stepDwell` 与该常量上的注释。
    @State private var revealed = 0
    /// 转场进行中（C 方案的分段退场都看它）。
    @State private var leaving = false
    /// 收场已经开始 —— 用来掐掉重复调用，以及让键鼠监听闭嘴。
    @State private var closing = false
    /// 已经交棒（`onDone` 调过）。转场途中被"立刻消失"插队时，两条路都会走到 `handOff`，
    /// 靠它保证只交一次 —— 否则窗口壳会被还两次、`onDone` 也会响两次。
    @State private var finished = false
    /// 光标飞到终点没有 / 飞行中的缩放（稿子的 1 → 1.45 → .84 → 1 那三下）。
    @State private var flying = false
    @State private var flyScale: CGFloat = 1
    /// 落点：主输入框插入点，收场那一刻现问 `ComposerAnchor` 要。
    @State private var caretTarget: CGPoint?
    /// 键鼠监听器。`Any?` 是因为 `removeMonitor` 要原样还回去，类型是 `Any`。
    @State private var monitor: Any?
    /// 让窗口壳一直让开的看门循环（见 `appear`）。
    @State private var chromeTask: Task<Void, Never>?
    /// 逐行揭示的节奏循环。
    @State private var paceTask: Task<Void, Never>?

    var body: some View {
        // ⚠️ 这三个值**必须在 body 里读一次**，不能只在 `overlayPreferenceValue` 的闭包里读。
        //    闭包不是每帧都重算的：它只在 preference 变的时候才被叫一遍。状态只被闭包读
        //    ⇒ 这个视图不依赖它 ⇒ 改了也不重画 ⇒ 光标永远停在起点（实测踩过：慢放下
        //    整屏都淡完了，方块还死死贴在末行右缘）。
        let goal = caretTarget
        let inFlight = flying
        let zoom = flyScale

        return ZStack {
            backgroundLayer
            chrome
        }
        .ignoresSafeArea()
        .overlayPreferenceValue(CaretAnchorKey.self) { anchor in
            // 光标飞行层。**住在锚点解算器里**：`GeometryReader` 的局部坐标就是整窗内容坐标，
            // 而落点（`goal`）也是同一套坐标 —— 两边不换算，直接比。
            GeometryReader { geo in
                if let a = anchor, let t = goal {
                    flyingCaret(from: geo[a], to: t, flown: inFlight, zoom: zoom)
                }
            }
            .allowsHitTesting(false)
        }
        .onAppear(perform: appear)
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            chromeTask?.cancel(); chromeTask = nil
            paceTask?.cancel(); paceTask = nil
            BootChrome.hide(false)   // 兜底: 任何路径下台都不能把红绿灯留在隐藏状态
        }
    }

    // MARK: 层

    /// 背景三层（纸面 / 暗晕 / 扫描线）一起收 —— 稿子 C 的"背景不一刀切"就是这一组。
    private var backgroundLayer: some View {
        ZStack {
            BC.bg
            vignetteLayer
            scanlines
        }
        .modifier(ExitFade(leaving: leaving, delay: BS.bgOutLag,
                           duration: BS.bgOut, rise: 0))
    }

    private var vignetteLayer: some View {
        // 稿子: `radial-gradient(120% 90% at 50% 45%, vig, transparent 62%)`
        EllipticalGradient(colors: [BC.vignette, .clear],
                           center: UnitPoint(x: 0.5, y: 0.45),
                           startRadiusFraction: 0,
                           endRadiusFraction: 0.62)
    }

    /// 扫描线。一屏 ~200 条 1pt 横线 —— 用 `Canvas` 一笔记完，不建 200 个 View。
    private var scanlines: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                         with: .color(BC.scan))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }

    private var chrome: some View {
        ZStack {
            cornerBrand.modifier(brandExit)
            cornerVersion.modifier(brandExit)
            rail.modifier(brandExit)
            centerBlock
            cornerProgress.modifier(brandExit)
            cornerClock.modifier(brandExit)
            footer.modifier(footerExit)
        }
        .padding(.horizontal, BS.padH)
        .padding(.top, BS.padTop)
        .padding(.bottom, BS.padBottom)
    }

    /// 品牌 / 四角 / 顶部那行 / 进度条 —— 同一拍退场（稿子：`160ms 20ms linear`）。
    private var brandExit: ExitFade {
        ExitFade(leaving: leaving, delay: BS.brandOutLag, duration: BS.brandOut, rise: -5)
    }

    /// 页脚比正文早 10ms 走、时长也短 20ms（稿子：`140ms 10ms`）。
    private var footerExit: ExitFade {
        ExitFade(leaving: leaving, delay: BS.footOutLag, duration: BS.footOut, rise: -5)
    }

    // MARK: 四角

    private var cornerBrand: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "MANGOX")
                .font(CodexFonts.monoFont(BS.brandSize, weight: .semibold))
                .tracking(BS.brandSize * 0.26)
                .foregroundStyle(BC.strong)
            Text(verbatim: "AGENT   WORKBENCH   LOCAL FIRST")
                .font(CodexFonts.monoFont(9))
                .tracking(1.8)
                .foregroundStyle(BC.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var cornerVersion: some View {
        Text(verbatim: versionLine)
            .font(CodexFonts.monoFont(9.5))
            .tracking(1.33)
            .foregroundStyle(BC.faint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var cornerProgress: some View {
        Text(verbatim: counterLine)
            .font(CodexFonts.monoFont(9.5))
            .tracking(1.33)
            .foregroundStyle(BC.faint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var cornerClock: some View {
        // 只为了"这一屏在动" —— 稿子就是这么个意思，不是给谁看时间的。
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            Text(verbatim: Self.clockText(ctx.date))
                .font(CodexFonts.monoFont(9.5))
                .tracking(1.33)
                .foregroundStyle(BC.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    // MARK: 第二行（BOOT SEQUENCE + SKIP）

    private var rail: some View {
        VStack {
            HStack(alignment: .top) {
                HStack(spacing: 0) {
                    Text(verbatim: "BOOT SEQUENCE ")
                    Text(verbatim: "·").foregroundStyle(BC.brand)
                    Text(verbatim: " LOCAL PROFILE")
                }
                .font(CodexFonts.monoFont(9.5))
                .tracking(0.95)
                .foregroundStyle(BC.faint)

                Spacer(minLength: 16)

                Button(action: { dismiss(instant: true) }) {
                    Text(verbatim: "SKIP  →")
                        .font(CodexFonts.monoFont(9.5))
                        .tracking(1.52)
                        .foregroundStyle(BC.dim)
                }
                .buttonStyle(.plain)
                .help(L("跳过启动页"))
            }
            Spacer()
        }
        .padding(.top, BS.railTop - BS.padTop)
    }

    // MARK: 中间：五行 + 进度条

    private var centerBlock: some View {
        VStack(spacing: 0) {
            steps
            progressBar.padding(.top, 20).modifier(brandExit)
        }
        .frame(width: BS.stepsWidth)
    }

    private var steps: some View {
        VStack(spacing: 0) {
            ForEach(Array(BootTrace.Step.allCases.enumerated()), id: \.element) { idx, step in
                BootRow(step: step,
                        // 未揭示的行画成排队态。**不是"它还没做完"** —— 是"这一屏还没说到它"，
                        // 见 `BS.stepDwell` 那一段。
                        entry: idx < revealed ? (trace.entries[step] ?? .init()) : .init(),
                        isLast: idx == BootTrace.Step.allCases.count - 1,
                        leaving: leaving,
                        exitDelay: BS.caretsOutLag + Double(idx) * BS.caretsOutStep)
            }
        }
    }

    private var progressBar: some View {
        HStack(spacing: 5) {
            ForEach(0..<BootTrace.Step.allCases.count, id: \.self) { i in
                Capsule()
                    .fill(i < shownDone ? BC.brand : BC.track)
                    .frame(height: 2)
            }
        }
    }

    /// 已经**揭示出来**的完成数。进度条与 `[ NN / 05 ]` 都只看它 ——
    /// 用 `trace.doneCount` 会让读数抢在打勾之前变，等于把"停顿"当不存在。
    private var shownDone: Int {
        BootTrace.Step.allCases.enumerated().reduce(0) { acc, pair in
            acc + (pair.offset < revealed && trace.phase(pair.element) == .done ? 1 : 0)
        }
    }

    // MARK: 页脚

    private var footer: some View {
        VStack(spacing: 4) {
            Text(verbatim: footerLine)
                .font(.system(size: 11))
                .tracking(0.66)
                .foregroundStyle(BC.mid)
            Text(verbatim: "MATCHING WORKSPACE RECORD")
                .font(CodexFonts.monoFont(9.5))
                .tracking(1.71)
                .foregroundStyle(BC.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, BS.footerBottom - BS.padBottom)
    }

    // MARK: 文案（全部现算，不进 static let —— 见本地化第 ⑨ 条）

    private var versionLine: String {
        #if arch(arm64)
        let chip = "APPLE SILICON"
        #else
        let chip = "INTEL"
        #endif
        return "v" + BootGate.appVersion + " · " + chip
    }

    private var counterLine: String {
        let done = shownDone
        let total = BootTrace.Step.allCases.count
        let n = done < 10 ? "0\(done)" : "\(done)"
        return "[ \(n) / 0\(total) ]   BOOTSTRAP"
    }

    private var footerLine: String {
        L("正在恢复工作区…")
    }

    private static func clockText(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    // MARK: 收场

    private func appear() {
        // 一行沿: "这一屏到底有没有上来 / 上来时五行已经是什么状态"。没有它的话,
        // "启动页好像没出现"这件事只能靠猜（截图时机、窗口什么时候真的上台，都不可控）。
        Log.view("boot-appear", ["settled": trace.settled ? "1" : "0",
                                 "done": "\(trace.doneCount)",
                                 "engine": "\(trace.phase(.engine))",
                                 "slowmo": "\(BS.slowmo)"])
        keepChromeHidden()
        // 任何键鼠输入 ⇒ **0 帧内消失**（设计稿原文："不等动画播完"）。
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                       .scrollWheel, .magnify, .swipe]
        ) { event in
            dismiss(instant: true)
            // **鼠标那一下要吞掉**：不吞的话 overlay 一消失，这次点击正好落在底下那个按钮上
            // —— "关掉启动页"顺手点开了某个面板，是最说不清的一种误触。
            // 键盘放行：这一屏只活几秒，期间按 ⌘Q / ⌘, 也该管用。
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: return nil
            default: return event
            }
        }
        startPacing()
        DispatchQueue.main.asyncAfter(deadline: .now() + BS.hardCap) { dismiss(instant: false) }
    }

    /// 逐行揭示：**每一步真的做完**之后再停 `stepDwell`，然后才揭示下一行。
    ///
    /// 判据没变（`trace` 是唯一真源、打勾只在真完成之后），变的是"说到第几步"的节奏。
    /// 实测：1.1s（无停顿）→ 2.0s（0.3 停顿）→ ~3.6s（0.5 停顿，5 × 0.5 + 引擎 0.6s + 落底 1.4s）。
    private func startPacing() {
        paceTask = Task { @MainActor in
            for (i, step) in BootTrace.Step.allCases.enumerated() {
                if Task.isCancelled { return }
                revealed = i + 1                       // 先把这一行揭示出来（它可能还在跑）
                // 一行沿 = "这一行是什么时候被说出来的"。停顿**没有别的地方能测**：
                // 它既不改 `BootTrace` 也不改任何断言，只能靠这对时间戳对账（实测见 BS.stepDwell）。
                Log.view("boot-reveal", ["step": step.rawValue, "n": "\(i + 1)"])

                while !Task.isCancelled {
                    let p = trace.phase(step)
                    if p == .done || p == .skipped { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: UInt64(BS.stepDwell * 1_000_000_000))
            }
            if !Task.isCancelled { dismiss(instant: false) }
        }
    }

    /// 让窗口壳（红绿灯 + 工具栏）在整屏期间保持隐藏。
    ///
    /// ⚠️ 为什么是**循环**而不是 `.onAppear` 里调一次：实测那一帧 `w.isVisible` 还是 false、
    ///    `w.toolbar` 还是 nil —— 一次调用在第一次实测里**完全落空**（红绿灯照样压在
    ///    `MANGOX` 上、工具栏胶囊飘在正中）。而启动这几秒里 `ContentView` 会因 `store`
    ///    变化反复重渲染，工具栏随时可能被 SwiftUI 重新摆出来。150ms 一拍、跟着这一屏
    ///    一起死 —— 最省事也最稳，代价是这一屏期间 20 来次空写。
    private func keepChromeHidden() {
        chromeTask = Task { @MainActor in
            while !Task.isCancelled {
                BootChrome.hide(true)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// 转场 C 的飞行光标。
    ///
    /// 起点 = 最后一行的右缘（锚点给的矩形）。之所以是"右缘"而不是"那个方块光标"：
    /// 值列是**右对齐**的，最后一行的光标就贴在它的右缘上，误差在一两个点以内。
    ///
    /// ⚠️ **不许给它加淡入**。稿子里的意思是"别的都退了、这一小块活下来"：它必须在
    ///    `leaving` 那一帧就**原地是实的**，然后才起飞。淡入会变成"凭空长出一个新东西"，
    ///    恰好把 C 方案唯一那句话（"你看到的这个光标，就是你接下来要打字的那个"）说反。
    private func flyingCaret(from: CGRect, to: CGPoint, flown: Bool, zoom: CGFloat) -> some View {
        let start = CGPoint(x: from.maxX - 3, y: from.midY)
        return Rectangle()
            .fill(BC.run)
            .frame(width: 6, height: 11)
            .scaleEffect(zoom)
            .position(flown ? to : start)
    }

    private func dismiss(instant: Bool) {
        if finished { return }
        // 转场已经在跑时，"正常收场"不许再来一次；但**"立刻消失"可以插队** ——
        // 稿子那条"任意键鼠 0 帧内消失"在最后那半秒里同样算数。
        if closing && !instant { return }
        closing = true
        Log.view("boot-dismiss", ["instant": instant ? "1" : "0",
                                  "done": "\(trace.doneCount)",
                                  "revealed": "\(revealed)",
                                  "settled": trace.settled ? "1" : "0"])
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        // ⚠️ 看门循环必须**先**停：反过来的话下一拍（≤150ms 后）又把壳藏起来，
        //    表现是"启动页没了、但工具栏和红绿灯也没了"。
        chromeTask?.cancel(); chromeTask = nil
        paceTask?.cancel(); paceTask = nil
        BootGate.markShown()

        if instant {
            // 0 帧：壳和这一屏同一帧一起下台，不放转场（设计稿："不等动画播完"）。
            // 也不交焦点 —— 用户已经在动键鼠了，这时候把光标塞进输入框是抢。
            handOff(focus: false)
            return
        }

        // ── 转场 C「光标接管」────────────────────────────────────────────────
        let probe = ComposerAnchor.caretPoint()
        caretTarget = probe.point
        // 落点取不到时**不假装飞过**：光标那一层整层不画，其余转场照播。
        // 这一行日志就是"到底飞没飞、落在哪条路径上"的唯一证据 —— 半秒里抓不到两帧。
        Log.view("boot-caret", ["source": probe.source,
                                "target": probe.point.map { "\(Int($0.x)),\(Int($0.y))" } ?? "nil"])
        leaving = true                       // 分段退场开始（各部件延迟见 BS）
        DispatchQueue.main.asyncAfter(deadline: .now() + BS.flyStart) {
            Log.view("boot-fly", ["to": caretTarget.map { "\(Int($0.x)),\(Int($0.y))" } ?? "nil"])
            withAnimation(.timingCurve(0.34, 0.9, 0.24, 1, duration: BS.flyDuration)) {
                flying = true
            }
        }
        scheduleCaretPop()
        // ⚠️ 壳要等**转场播完**再还回去。先还的话红绿灯会提前蹦到还没落完的启动页上。
        DispatchQueue.main.asyncAfter(deadline: .now() + BS.transition) {
            // 落点拿到了才交焦点 —— 没飞过光标却让输入框抢焦点，那是凭空蹦出一个光标。
            handOff(focus: probe.point != nil)
        }
    }

    /// 交棒：壳还回去、这一屏撤掉。**只会成功一次**（`finished`），
    /// 因为转场途中可能被"立刻消失"插队 —— 两条路都会走到这里。
    private func handOff(focus: Bool) {
        if finished { return }
        finished = true
        BootChrome.hide(false)
        onDone()
        if focus { ComposerAnchor.focus() }
    }

    /// 稿子那三下：58% 放到 1.45、78% 收到 .84、100% 回 1。
    private func scheduleCaretPop() {
        let base = BS.flyStart
        DispatchQueue.main.asyncAfter(deadline: .now() + base + BS.flyDuration * 0.58) {
            withAnimation(.easeOut(duration: 0.05)) { flyScale = 1.45 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + base + BS.flyDuration * 0.78) {
            withAnimation(.easeIn(duration: 0.035)) { flyScale = 0.84 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + base + BS.flyDuration) {
            withAnimation(.easeOut(duration: 0.02)) { flyScale = 1 }
        }
    }
}

// MARK: - 分段退场

/// 稿子 C 的退场原语：`opacity → 0` + 上移 5pt，**各自带自己的延迟**。
///
/// SwiftUI 里没有 `animation-delay`，延迟只能写成 `Animation.delay(_:)`；
/// 而 `.animation(_:value:)` 的 `Animation?` 传 nil 就是"不动画"，
/// 所以 `leaving` 回到 false 时不会补一段莫名其妙的过渡。
private struct ExitFade: ViewModifier {
    let leaving: Bool
    let delay: Double
    let duration: Double
    let rise: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(leaving ? 0 : 1)
            .offset(y: leaving ? rise : 0)
            .animation(leaving ? .linear(duration: duration).delay(delay) : nil, value: leaving)
    }
}

/// 最后一行的矩形 —— 光标起飞的锚。
private struct CaretAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: - 一行

private struct BootRow: View {
    let step: BootTrace.Step
    let entry: BootTrace.Entry
    let isLast: Bool
    let leaving: Bool
    /// 本行退场的延迟（稿子：首行 20ms，之后每行 +25ms）。
    let exitDelay: Double

    var body: some View {
        HStack(spacing: BS.rowGap) {
            Text(verbatim: mark)
                .font(CodexFonts.monoFont(11))
                .foregroundStyle(markColor)
                .frame(width: 13)
            Text(verbatim: label)
                .font(.system(size: 11.5))
                .tracking(0.69)
                .foregroundStyle(labelColor)
                .frame(width: BS.labelWidth, alignment: .leading)
            Text(verbatim: caption)
                .font(CodexFonts.monoFont(9))
                .tracking(1.44)
                .foregroundStyle(BC.faint)
            Spacer(minLength: 8)
            valueView
        }
        .padding(.vertical, BS.rowPadV)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(BC.rule).frame(height: 1)
            }
        }
        // 转场 C 的起点锚：只有最后一行给（光标从它右缘起飞）。
        .anchorPreference(key: CaretAnchorKey.self, value: .bounds) { isLast ? $0 : nil }
        .modifier(ExitFade(leaving: leaving, delay: exitDelay,
                           duration: BS.caretsOut, rise: -5))
    }

    private var valueView: some View {
        HStack(spacing: 3) {
            Text(verbatim: value)
                .font(CodexFonts.monoFont(10.5))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
            // 转场一开始就把行内那个闪烁光标收掉：接管光标已经在起点上了，
            // 两个方块并排是"两个光标"，恰好破掉 C 方案那句"是同一个"。
            if entry.phase == .running && !leaving { caret }
        }
    }

    /// 闪烁光标。稿子是 `steps(1)` 硬切，不是渐变 —— 这里同样硬切（取 0.55s 的商奇偶）。
    private var caret: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            Rectangle()
                .fill(BC.run)
                .frame(width: 6, height: 11)
                .opacity(on ? 1 : 0)
        }
    }

    // MARK: 相位 → 视觉

    private var mark: String {
        switch entry.phase {
        case .done:    return "✓"
        case .running: return "▸"
        case .pending: return "·"
        case .skipped: return "·"
        }
    }

    private var markColor: Color {
        switch entry.phase {
        case .done:    return BC.ok
        case .running: return BC.run
        case .pending: return BC.ghost
        case .skipped: return BC.ghost
        }
    }

    private var labelColor: Color {
        switch entry.phase {
        case .done:    return BC.base
        case .running: return BC.strong
        case .pending: return BC.dim
        case .skipped: return BC.dim
        }
    }

    private var valueColor: Color {
        switch entry.phase {
        case .running: return BC.run
        default:       return BC.dim
        }
    }

    /// 行标题。**中文走词表**，英文小字是**终端腔的版式元素**（`verbatim`）——
    /// 它在两种语言下都保持原样，与中文标题并排成"中文说什么 / 机器说什么"的关系。
    private var label: String {
        switch step {
        case .engine:     return L("引擎进程")
        case .model:      return L("模型与凭据")
        case .workspace:  return L("项目与工作区")
        case .assistants: return L("助理与定时")
        case .sessions:   return L("对话记录")
        }
    }

    private var caption: String {
        switch step {
        case .engine:     return "ENGINE"
        case .model:      return "MODEL · KEYCHAIN"
        case .workspace:  return "WORKSPACE"
        case .assistants: return "ASSISTANTS"
        case .sessions:   return "SESSIONS"
        }
    }

    /// 读数。**每一格都是从 `entry.n` 现算的真数**，没有一格是文案占位。
    private var value: String {
        let n = entry.n
        switch entry.phase {
        case .done:
            switch step {
            case .engine:     return String(format: L("pi · %lld 个子进程"), n)
            case .model:      return String(format: L("已授权 %lld 次"), n)
            case .workspace:  return String(format: L("%lld 个项目"), n)
            case .assistants: return String(format: L("%lld 位助理"), n)
            case .sessions:   return String(format: L("%lld 段会话"), n)
            }
        case .running:
            switch step {
            case .sessions:   return L("恢复中")
            default:          return L("载入中")
            }
        case .skipped:
            // 只有"引擎"会走这条（本机没装 pi）。如实说"没装"，不装作跑过。
            return step == .engine ? L("pi 未安装") : "—"
        case .pending:
            return "—"
        }
    }
}
