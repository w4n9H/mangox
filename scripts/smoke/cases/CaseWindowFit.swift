//
//  CaseWindowFit.swift
//  开工作区的窗口补宽 (2026-10-23)
//
//  为什么这些断言必须有: 补宽的判据是「**聊天区可用宽一个像素都不变**」——
//  变了就要整条正文重排（实测一次 200~1200ms），而**什么都不报错**，表现就跟没修一样。
//  第一版我就是按"补到 776 门槛"算的，多了几 pt ⇒ area 变了 ⇒ 反而重排两遍（1.2~2.2s）。
//  所以这里锁的不是某个数字，是那条**不变量**。
//
//  能变红的点:
//    · 把面板宽 / 分隔线漏掉一项 ⇒ 补完聊天区还是变窄;
//    · 顺手加"余量" ⇒ 补完聊天区变宽（同样是重排）;
//    · 屏幕装不下时硬撑 ⇒ 窗口跑出屏幕外（x 越界）;
//    · 已经够宽还去 setFrame ⇒ 白改一次窗口（还会把用户拉宽的窗口缩回去）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseWindowFit() async {
        print("== T-WINFIT 开工作区的窗口补宽 ==")

        let before: CGFloat = 1280           // 样本窗口宽 = 默认宽 (Tune.windowDefaultSize); 它恒比"补宽所需"窄
        let need = WorkspaceWindowFit.requiredWidth(currentWidth: before)

        // ① 补宽量 = 面板 + 它的分隔线。少算分隔线 ⇒ 补完聊天区就窄 1pt ⇒ 重排。
        check(need - before == Tune.workspaceWidth + 1,
              "T-WINFIT 补宽量 = 面板 + 分隔线 (实测 \(need - before))")

        // ② **不变量**: 补完之后把面板占的位置扣掉, 聊天区必须回到原宽。
        check(need - (Tune.workspaceWidth + 1) == before,
              "T-WINFIT 补宽后聊天区宽度不变 (实测 \(need - Tune.workspaceWidth - 1) vs \(before))")

        // ③ 已经够宽 ⇒ 原样返回（不许缩、不许挪）。
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let wide = CGRect(x: 40, y: 40, width: need + 300, height: 900)
        check(WorkspaceWindowFit.targetFrame(current: wide, requiredWidth: need, screen: screen) == wide,
              "T-WINFIT 够宽时窗口一像素不动")

        // ④ 正好等于所需宽也按"够宽"处理（差一档就是一次重排）。
        let exact = CGRect(x: 40, y: 40, width: need, height: 900)
        check(WorkspaceWindowFit.targetFrame(current: exact, requiredWidth: need, screen: screen) == exact,
              "T-WINFIT 正好等于所需宽时也不动")

        // ⑤ 1280 窗口 ⇒ 补到 1280+361；高 / y 不动；右缘有地方时左缘不动。
        let small = CGRect(x: 100, y: 60, width: before, height: 860)
        let fitted = WorkspaceWindowFit.targetFrame(current: small, requiredWidth: need, screen: screen)
        check(fitted.width == before + Tune.workspaceWidth + 1,
              "T-WINFIT 1280 补到 \(before + Tune.workspaceWidth + 1) (实测 \(fitted.width))")
        check(fitted.height == small.height && fitted.minY == small.minY,
              "T-WINFIT 补宽只改横向 (高 \(fitted.height) / y \(fitted.minY))")
        check(fitted.minX == small.minX,
              "T-WINFIT 右缘有地方时左缘不动 (实测 x \(fitted.minX))")

        // ⑥ 窗口贴着屏幕右缘 ⇒ 整体左移，右缘不出屏。
        let atEdge = CGRect(x: screen.maxX - before, y: 60, width: before, height: 860)
        let pushed = WorkspaceWindowFit.targetFrame(current: atEdge, requiredWidth: need, screen: screen)
        check(pushed.maxX <= screen.maxX + 0.01 && pushed.width == need,
              "T-WINFIT 贴屏时左移而不是出屏 (x \(pushed.minX) 宽 \(pushed.width))")

        // ⑦ 屏幕比所需宽还窄 ⇒ 只补到屏宽（此时会重排，但绝不出屏），且不许反缩。
        let tinyScreen = CGRect(x: 0, y: 0, width: 1400, height: 800)
        let clamped = WorkspaceWindowFit.targetFrame(current: CGRect(x: 0, y: 0, width: 1300, height: 700),
                                                    requiredWidth: 1300 + Tune.workspaceWidth + 1,
                                                    screen: tinyScreen)
        check(clamped.width <= tinyScreen.width + 0.01 && clamped.maxX <= tinyScreen.maxX + 0.01,
              "T-WINFIT 屏幕装不下时就补到边缘 (宽 \(clamped.width) 屏宽 \(tinyScreen.width))")
        check(clamped.width >= 1300, "T-WINFIT 装不下也不许反缩 (宽 \(clamped.width))")

        // ── 以下是 2026-11-13 的窗口**下限**（上面 ①~⑦ 管的是"开面板补宽"，两件事）──
        //
        // 判据（boss）：「**在不触发对话区重排的前提下，窗口能调整的范围最大**」。
        // 重排的开关只有"正文列可用宽 < 776"这一条线 ⇒ 下限 = 临界线 + **看得见的一点点留白**：
        // 低于临界线必然重排，比留白再宽就是拖到最小也消不掉的死白（旧值 1100 多了 67pt）。留白本身
        // 归 boss 手感（"诸如 10 20，留 1 太小了"），但守在 8~48：小于 8 窗口边缘贴着正文列（看着像被裁），
        // 大于 48 = 超过正文列自身的 `chatHPadding`，观感就从"边距"变成"正文浮在中间"。

        // ⑧ 常态下限 = 临界线 + 留白，**高出来的必须正好是那个留白**。
        //    钉精确值而不是范围，是因为旧值 1100 正是从这里漂出去的（一漂 67pt，读数里直接可见）。
        let floor = Tune.sidebarWidth + 1 + Tune.chatColumnWidth
        let normal = Tune.windowMinWidth(sidebarCollapsed: false, workspaceVisible: false)
        check(normal - floor == Tune.windowMinGutter,
              "T-WINFIT 下限高出临界线的只能是留白 (实测 \(normal - floor) / 留白 \(Tune.windowMinGutter))")
        check(Tune.windowMinGutter >= 8 && Tune.windowMinGutter <= 48,
              "T-WINFIT 留白本身要落在 8~48 (实测 \(Tune.windowMinGutter))")

        // ⑨ 开工作区 ⇒ 下限把面板与它的分隔线一起算上。少这一档，"正文列不被挤窄"就在
        //    面板这里破功：开着面板手动缩窗，正文被压到 500 上下 ⇒ 全量重排（就是本文件头那件事）。
        let withPanel = Tune.windowMinWidth(sidebarCollapsed: false, workspaceVisible: true)
        check(withPanel - normal == Tune.workspaceWidth + 1,
              "T-WINFIT 开面板时下限 += 面板 + 分隔线 (实测 +\(withPanel - normal))")

        // ⑩ 收起侧栏 ⇒ 少一整条侧栏。不只是对齐数字：1920 屏并排两窗各 960，
        //    带着侧栏的 1053 做不到，收起后的 797 才做到。
        let collapsed = Tune.windowMinWidth(sidebarCollapsed: true, workspaceVisible: false)
        check(normal - collapsed == Tune.sidebarWidth,
              "T-WINFIT 收起侧栏时下限少一整条侧栏 (实测 -\(normal - collapsed))")

        // ⑪ 屏宽是**安全阀**不是设计值：装得下一分不封；装不下封到屏宽（绝不把窗口顶出屏幕、
        //    再也拖不回来）。两半都要钉 —— 只钉"封顶"会漏掉"平时乱封"。
        check(Tune.windowMinWidth(sidebarCollapsed: false, workspaceVisible: true,
                                 screenWidth: 1920) == withPanel,
              "T-WINFIT 1920 屏装得下就一分不封 (下限 \(withPanel) vs 屏宽 1920)")
        let onNarrowScreen = Tune.windowMinWidth(sidebarCollapsed: false, workspaceVisible: true,
                                                screenWidth: 1280)
        check(onNarrowScreen == 1280,
              "T-WINFIT 屏宽装不下时封到屏宽 (实测 \(onNarrowScreen) vs 屏宽 1280)")
    }
}
