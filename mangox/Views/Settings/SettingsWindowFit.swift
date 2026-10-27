//
//  SettingsWindowFit.swift
//  设置浮窗的**尺寸与位置**（2026-10-26 boss: 「弹出页的大小不能超过主窗口, 弹出前需要判断
//  主窗口的长宽, 然后要居中」）。
//
//  ⚠️ 这些是**纯函数**，不碰 `NSWindow` —— 不是为了好看，是为了能被冒烟断言钉住：
//     窗口几何写错不会报错，只会让设置页比主窗口大、或者漂到屏幕外，而编译/构建全绿。
//     `SettingsWindowController.fit` 只负责把结果喂给窗口。
//
//  ## 三条判据
//  ① **不超过主窗口**：内容 = min(首选, 主窗口 − 每边留白)。留白让底下的主窗口露出边框，
//     否则贴齐会读成"整窗替换"，用户分不清这是浮窗还是有东西盖住了。
//  ② **下限跟着一起缩**：主窗口比 `settingsWindowMinSize` 还小时，"不超过主窗口"优先。
//     反过来（先保下限）就是这条投诉本身 —— 小窗口下弹出的设置页仍然更大。
//  ③ **居中到主窗口，再夹进屏幕可见区**：主窗口贴着屏幕边时，单纯居中会把窗推到屏幕外。
//

import AppKit

enum SettingsWindowFit {

    /// 主窗口被拖得极小时的地板 —— 再小窗口就变成一条线，什么也读不了。
    /// ⚠️ 它只在**主窗口本身小于这个数**时生效，是"最后一道兜底"，不是常规尺寸。
    static let floorSize = CGSize(width: 360, height: 280)

    /// 浮窗内容尺寸 = min(首选, 主窗口 − 每边留白)，再抬到地板。
    static func contentSize(preferred: CGSize, host: CGSize, margin: CGFloat) -> CGSize {
        CGSize(width:  max(floorSize.width,  min(preferred.width,  host.width  - margin * 2)),
               height: max(floorSize.height, min(preferred.height, host.height - margin * 2)))
    }

    /// 收缩下限 = min(首选下限, 实际内容尺寸) —— **不许反过来**（见文件头 ②）。
    static func minSize(preferredMin: CGSize, content: CGSize) -> CGSize {
        CGSize(width:  min(preferredMin.width,  content.width),
               height: min(preferredMin.height, content.height))
    }

    /// 居中到 `host`，再夹进 `screen`（可见区）。
    ///
    /// 入参是**窗口外框**尺寸（内容 + 标题栏），不是内容尺寸 —— 用内容尺寸会让窗整体偏上。
    static func origin(windowSize: CGSize, host: CGRect, screen: CGRect) -> CGPoint {
        var x = host.midX - windowSize.width / 2
        var y = host.midY - windowSize.height / 2
        x = min(max(x, screen.minX), screen.maxX - windowSize.width)
        y = min(max(y, screen.minY), screen.maxY - windowSize.height)
        return CGPoint(x: x, y: y)
    }
}
