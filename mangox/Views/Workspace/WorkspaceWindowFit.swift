//
//  WorkspaceWindowFit.swift
//  「开工作区时把窗口补宽」—— **治标**的一刀（2026-10-23 boss: `先治标吧，治本后面再说`）。
//
//  ## 病是什么（实测，不是猜）
//
//  在 1014 条消息的会话上量主队列吞吐（进程内探针，见当日 log）：静息 max gap 0.3~0.6ms，
//  而**开/关工作区那一下会堵 200~820ms**。逐个摘除对照出来的责任方只有一个：
//
//      | 变体                        | 开工作区时主线程最大间隙 |
//      | 现状                         | 200~822ms               |
//      | 面板内容换成空色块            | 372~1182ms（没变）       |
//      | 跳过 git / 语言统计加载        | 182~1185ms（没变）       |
//      | 拆掉根节点整树 `.animation`    | 163~920ms（没变）        |
//      | 面板只淡入                    | 264~2162ms（没变）       |
//      | **正文列换占位**              | **10~28ms**             |
//      | **侧栏摘掉**（正文仍 680 宽）   | **10~37ms**             |
//
//  ⇒ **正文那条 `LazyVStack` 整体重排**。不是动画、不是面板、不是 git、也不是投影
//    （`projectedChat` 单独计时 < 5ms）。
//
//  ## 触发条件恰好是一条常数边界
//
//  `ChatView` 正文列是 `.frame(maxWidth: Tune.chatColumnWidth)`（= 内容 680 + 2×48 = 776）：
//  **可用宽 ≥ 776 时内容就卡在 680 不动；一旦低于 776，全部行重新测量**（约 0.8ms/行 × 1014 行）。
//
//      带侧栏开面板: 1280 − 256(侧栏) − 360(面板) − 2(分隔线) = 662 → 内容 566 ⇒ 全量重排
//      侧栏摘掉后  : 1280 − 360 − 2 = 918 ≥ 776 → 内容仍 680 ⇒ 零重排（这就是那组对照干净的原因）
//
//  同理，**手动把窗口拖窄到这条线以下也会卡**（同一机制，未单独实测）。
//
//  ## 为什么这样治标（以及治本是什么）
//
//  治标 = **让正文的可用宽在开面板前后不变**：窗口按缺口补宽，正文仍 680 ⇒ 零重排、零闪烁，
//  面板宽度与版面一个像素都不改。窗口已经在屏幕右缘时补不进去，就只补得到的部分（会重排一次）。
//
//  治本（boss 说后面再说，**先记在这里**）= 让重排本身变便宜：正文按**回合窗口化**
//  （只渲染最近 N 块 + 「更早」展开），行数不再随会话长度线性增长 —— 附带还能治手动缩窗的卡。
//  ⚠️ 别拿"缓存投影"当治本：投影 < 5ms，病在布局不在计算。
//
//  ## 两个实测出来的时序坑（都踩过，都留了证据）
//
//  ① **必须 `animate: false`**。`setFrame(animate: true)` 本身同步阻塞 **217ms**，而且窗口
//     动画期间 SwiftUI 每帧重排整个窗口 ⇒ 反而更卡（实测到 2217ms）。
//  ② **必须在 `workspaceVisible` 落地之前补**。补宽挂在 `.onChange(of: workspaceVisible)` 上时，
//     SwiftUI 已经先按**旧窗口宽**排过一版（正文 566 ⇒ 全量重排），补宽后又排一版
//     （正文 680 ⇒ 又一次全量重排）—— 实测"修复"后反而 1.2~2.2s，比修之前还差。
//     现在的挂载点是 `ChatStore.workspaceVisible` 的 **willSet**（见 `ChatStore.willSetWorkspaceVisible`）：
//     先改窗口，再落地状态 ⇒ 只有一版布局，正文宽 680 → 680，一次都不重排。
//  ③ **关的时候反过来**：得等面板真的从视图树里摘掉（~250ms 转场）再缩窗口，
//     否则那一刻是"窄窗口 + 还带着面板"= 最窄的一版 ⇒ 白重排一次（见 `apply(open: false)` 那段）。
//

import AppKit
import SwiftUI

enum WorkspaceWindowFit {

    /// 关面板后多久把窗口缩回去 —— 要压过面板的转场（`CodexTheme.animMed` = 250ms）。
    static let restoreDelay: TimeInterval = 0.30

    /// 补宽后的窗口宽 = 现在这么宽 **+ 面板 + 它的分隔线**。
    ///
    /// ⚠️ **不是"补到某个门槛"，而是"把面板的位置让出来"** —— 判据是「聊天区的可用宽一个像素都不变」。
    ///    我第一版按"补到内容 680 的上限"算（门槛 776），实测反而更糟：正文在 1280 窗口下本来就
    ///    只有 **659.8**（被挤状态，远低于 680 上限），补到 776 之上是**先把正文撑宽一次**，
    ///    面板再插进来又**挤窄一次** ⇒ 两遍全量重排（实测 1.2~2.2s）。留任何"余量"都是同一个错：
    ///    余量会让 area_after ≠ area_before，一样触发重排。
    static func requiredWidth(currentWidth: CGFloat) -> CGFloat {
        currentWidth + Tune.workspaceWidth + 1
    }

    /// 目标 frame。
    ///
    /// - 已经够宽 ⇒ **原样返回**（绝不因为"顺手"去缩窗口）。
    /// - 右缘超出屏幕 ⇒ 整体左移（宽度优先，保持右缘贴屏）。
    /// - 屏幕实在装不下 ⇒ 只补到屏宽（此时仍会重排，但总比不动强）。
    static func targetFrame(current: CGRect, requiredWidth: CGFloat, screen: CGRect) -> CGRect {
        guard current.width < requiredWidth else { return current }
        var width = requiredWidth
        var x = current.origin.x
        if x + width > screen.maxX {
            x = max(screen.minX, screen.maxX - width)
        }
        if x + width > screen.maxX {          // 屏宽不够 ⇒ 认命，补到边缘为止
            width = max(current.width, screen.maxX - x)
            x = min(x, screen.maxX - width)
        }
        return CGRect(x: x, y: current.origin.y, width: width, height: current.height)
    }

    // MARK: - 时序执行（状态只有一个主窗，所以住在这里，不进视图的 @State）

    /// 开之前那一版 frame（关的时候还回去）。
    private static var preOpenFrame: CGRect?
    /// 我们**实际设过**的 frame —— 用它判断"窗口还是不是我们摆的那个"。
    private static var appliedFrame: CGRect?
    /// 关面板后那次"缩回去"的预约（这期间又开 ⇒ 取消）。
    private static var restoreWork: DispatchWorkItem?

    private static var mainWindow: NSWindow? {
        NSApp.windows.first {
            !($0 is NSPanel) && $0.identifier?.rawValue != "miniTaskWindow" && $0.isVisible
        }
    }

    /// 工作区开关时的窗口动作。**开走 willSet、关走"面板摘掉之后"**（理由见文件头 ②③）。
    @MainActor
    static func apply(open: Bool, chatIsMainArea: Bool,
                      canUseWorkspace: Bool, miniMode: Bool) {
        guard !miniMode, let win = mainWindow else { return }
        restoreWork?.cancel()
        restoreWork = nil

        if open {
            guard canUseWorkspace else { return }
            preOpenFrame = win.frame
            // 非聊天主区（知识 / 定时 / 插件 / 轨迹）没有 680 上限 ⇒ 补宽毫无意义
            guard chatIsMainArea else { return }
            let need = requiredWidth(currentWidth: win.frame.width)
            guard need - win.frame.width >= 1 else { return }
            let screen = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let target = targetFrame(current: win.frame, requiredWidth: need, screen: screen)
            guard target != win.frame else { return }
            win.setFrame(target, display: true, animate: false)
            appliedFrame = target
            return
        }

        // 关：等面板转场走完再缩（那一刻窗口还带着面板，是最窄的一版）
        guard let pre = preOpenFrame, let applied = appliedFrame else { return }
        let work = DispatchWorkItem {
            guard let win = mainWindow else { return }
            preOpenFrame = nil
            appliedFrame = nil
            // 用户在我们之后手动挪过 / 缩过 ⇒ 别抢方向盘（宁可窗口保持现状）
            guard abs(win.frame.width - applied.width) < 1,
                  abs(win.frame.origin.x - applied.origin.x) < 1 else { return }
            win.setFrame(pre, display: true, animate: false)
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
    }
}
