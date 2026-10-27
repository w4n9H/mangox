//
//  CaseSettingsWindow.swift
//  设置浮窗的尺寸与位置（2026-10-26）
//
//  为什么这些断言必须有: 三条判据写错**都不会报错** —— 设置页只会悄悄比主窗口大一点、
//  或者上半截漂到屏幕外、或者下限没跟着缩（于是小窗口下弹出的页反而更大）。
//  编译过、构建过、界面上看起来"就是那样"，只能靠断言钉住。
//
//  能变红的点:
//    · 忘了减留白 ⇒ 设置页与主窗口同宽（"整窗替换"的观感）;
//    · 忘了 min ⇒ 主窗口比首选小的时候，弹出页仍然 920 宽（就是那条投诉本身）;
//    · 下限反过来取 max ⇒ 小窗口下内容小、下限却更大，窗口被撑回去;
//    · 居中不夹屏幕 ⇒ 主窗口贴屏幕右缘时，设置窗右边一半在屏幕外;
//    · 用内容尺寸居中（而不是窗口外框）⇒ 整体偏下（标题栏那段高度被算错了）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSettingsWindow() async {
        print("== T-SETWIN 设置浮窗的尺寸与位置 ==")

        let preferred = Tune.settingsWindowSize          // 920 × 780
        let margin = Tune.settingsWindowMargin           // 24

        // ① 主窗口很大 ⇒ 用首选尺寸（不因为"主窗口大"就跟着变大，那会让设置页失去固定形状）
        let big = SettingsWindowFit.contentSize(
            preferred: preferred,
            host: CGSize(width: 2560, height: 1440), margin: margin)
        check(big == preferred, "T-SETWIN 主窗口够大 ⇒ 用首选尺寸 (实测 \(big))")

        // ② 主窗口比首选小 ⇒ **收进去**，且每边留出 margin
        //    ⚠️ 取 800×600 而不是 1000×700：后者宽度够放 920（min 会取首选），只有高度收 ——
        //    那样断言"两边都收"会假红（我第一版就这么写的，冒烟立刻抓到了）。
        let host = CGSize(width: 800, height: 600)
        let small = SettingsWindowFit.contentSize(preferred: preferred, host: host, margin: margin)
        check(small.width == 800 - margin * 2 && small.height == 600 - margin * 2,
              "T-SETWIN 主窗口更小 ⇒ 收进主窗口并留白 (实测 \(small))")
        check(small.width <= host.width && small.height <= host.height,
              "T-SETWIN **硬约束**: 内容尺寸不许超过主窗口")
        // 反例口径: 上面那条如果写成"只减一次 margin"或"不减", 这条会跟着红
        check(small.width < host.width, "T-SETWIN 反例: 收进去之后必须真的更小 (不许同宽)")

        // ②' 只有一边装不下 ⇒ 只收那一边，另一边仍用首选（不许连带缩）
        let midHost = SettingsWindowFit.contentSize(
            preferred: preferred, host: CGSize(width: 1000, height: 700), margin: margin)
        check(midHost == CGSize(width: preferred.width, height: 700 - margin * 2),
              "T-SETWIN 只有高度装不下 ⇒ 只收高度, 宽度保持首选 (实测 \(midHost))")

        // ③ 主窗口被拖到极扁 ⇒ 退回地板，但**仍然不许超过主窗口**这条要让位给可读性
        //    （地板 360×280 是最后一道兜底）
        let tiny = SettingsWindowFit.contentSize(
            preferred: preferred, host: CGSize(width: 200, height: 150), margin: margin)
        check(tiny == SettingsWindowFit.floorSize,
              "T-SETWIN 主窗口极小时抬到地板 (实测 \(tiny))")

        // ④ 下限跟着内容一起缩 —— 否则窗口会被撑回 760×640, 又比主窗口大
        let minSmall = SettingsWindowFit.minSize(preferredMin: Tune.settingsWindowMinSize,
                                                 content: small)
        check(minSmall.width == small.width && minSmall.height == small.height,
              "T-SETWIN 主窗口小于下限时, 下限跟着缩 (实测 \(minSmall))")
        let minBig = SettingsWindowFit.minSize(preferredMin: Tune.settingsWindowMinSize,
                                               content: big)
        check(minBig == Tune.settingsWindowMinSize,
              "T-SETWIN 正常尺寸下下限仍是首选下限 (实测 \(minBig))")

        // ⑤ 居中：窗口中心 = 主窗口中心
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let hostFrame = CGRect(x: 400, y: 200, width: 1200, height: 800)
        let win = CGSize(width: 920, height: 810)   // = 内容 780 + 标题栏
        let o = SettingsWindowFit.origin(windowSize: win, host: hostFrame, screen: screen)
        check(abs((o.x + win.width / 2) - hostFrame.midX) < 0.5
              && abs((o.y + win.height / 2) - hostFrame.midY) < 0.5,
              "T-SETWIN 居中到主窗口 (实测 \(o) vs 主窗口中心 \(hostFrame.midX),\(hostFrame.midY))")

        // ⑥ 主窗口贴着屏幕右下 ⇒ 夹回可见区（否则右/上边缘在屏幕外，点不到）
        let edge = CGRect(x: 1500, y: 0, width: 1200, height: 800)
        let oe = SettingsWindowFit.origin(windowSize: win, host: edge, screen: screen)
        check(oe.x + win.width <= screen.maxX && oe.y >= screen.minY,
              "T-SETWIN 越界时夹进屏幕 (实测 \(oe))")
        check(oe.x >= screen.minX && oe.y + win.height <= screen.maxY,
              "T-SETWIN 左侧/上侧也不许出屏 (实测 \(oe))")
    }
}
