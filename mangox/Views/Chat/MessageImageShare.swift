//
//  MessageImageShare.swift
//  「分享」—— 把一条正文渲染成图片放进剪贴板。
//
//  ⚠️ **不能用 `ImageRenderer`**: 它画不出 `ScrollView` 的内容 (代码块/表格「高度对、内容空」)。
//     这条路走 `NSHostingView` + 离屏 borderless 窗口 + `cacheDisplay` —— 与
//     `scripts/diag/md_preview.py` 量 markdown 用的**同一条**通道 (那个脚本只是把 `swiftc`
//     当编译器, 渲染全在 Swift/AppKit 里, 集成到 App 不需要任何 Python)。
//

import AppKit
import SwiftUI

@MainActor
enum MessageImageShare {

    enum Failure: Error {
        case empty
        case renderFailed
        case clipboardFailed
        /// 正文太长 —— **不出图** (不出半张图, 也不偷偷降清晰度凑一张)。
        /// `height` = 实测高度 (pt), 交给 UI 说清"长到多少"。
        case tooLong(height: CGFloat)
    }

    enum Result {
        case copied
        /// 正文太长: **没出图**。UI 该说清并提示改用「复制」, 不许静默失败。
        case tooLong(height: CGFloat)
        case failed
    }

    // MARK: - 渲染

    /// 正文 (markdown) → PNG。
    ///
    /// `dark` 决定配色: `CodexTheme.adaptive()` 是 NSColor **动态色**, 离屏渲染时按
    /// **环境 `colorScheme`** 解析 (`.environment(\.colorScheme, …)`); 换 `NSAppearance` 那招
    /// 实测不生效 —— 见 `md_preview.py` 里同一条注释。
    static func png(text: String, basePath: String?, caption: String?, dark: Bool) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }

        let card = ShareCardText(text: trimmed, basePath: basePath, caption: caption)
            .frame(width: Tune.shareWidth, alignment: .topLeading)
            .background(CodexTheme.bgChat)
            .environment(\.colorScheme, dark ? .dark : .light)

        let host = NSHostingView(rootView: card)
        var height = max(host.fittingSize.height, 1)
        host.frame = NSRect(x: 0, y: 0, width: Tune.shareWidth, height: height)
        // 不上屏: 只要 layout/display 通道
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.contentView = host
        // ⚠️ **必须抽 RunLoop, 不能只 layout 一趟**: 表格「量视口宽 → 回灌 @State → 重排」是
        // **两趟布局**, `onPreferenceChange` 要等一次 runloop 才送达 —— 只 layout 一趟量到的是
        // 第一趟 (窄表仍是内容宽)。屏幕上它照常重排, 只有离屏截图才看得到第一趟。
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        // 落定后**重新取高度**: 列宽回灌会改折行行数 ⇒ 高度变了。位图按第一趟的高度建, 空出来的
        // 那块是**未初始化的黑边** (2026-10-20 实测: 整幅图被判成"非背景")。
        let settled = max(host.fittingSize.height, 1)
        if abs(settled - height) > 0.5 {
            height = settled
            host.frame = NSRect(x: 0, y: 0, width: Tune.shareWidth, height: height)
            win.setContentSize(NSSize(width: Tune.shareWidth, height: height))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }

        // ⚠️ **长图上限: 超了就不出图** (2026-10-22 boss「超过 3 屏的就可以不出了」)。
        // 只能在**这里**判 —— 高度只有真排版才准 (折行/表格/图片都算在里头), 按字符数预估会说谎,
        // 症状是"按钮说能出、点下去被拒"。
        guard height <= Tune.shareMaxHeight else {
            throw Failure.tooLong(height: height)
        }

        // 定值 2x —— **没有"超长就降 1x"的分支**: 要么出清楚的图, 要么不出。
        let scale: CGFloat = 2
        let pxW = Int(Tune.shareWidth * scale), pxH = Int(height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure.renderFailed
        }
        rep.size = NSSize(width: Tune.shareWidth, height: height)
        host.cacheDisplay(in: host.bounds, to: rep)
        withExtendedLifetime(win) {}   // 窗口要活到这一行: 提前释放会让 display 通道拿到空内容
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure.renderFailed
        }
        return png
    }

    // MARK: - 出口

    /// 放进剪贴板。**PNG 和 TIFF 都写** —— 一部分老 IM 只认 TIFF (代价实测: 一张卡片
    /// TIFF ≈ 2.9 MB, PNG ≈ 128 KB; 嫌重就删掉 TIFF 那一支)。
    static func copyToPasteboard(_ png: Data, to pb: NSPasteboard = .general) throws {
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        let tiff = NSImage(data: png)?.tiffRepresentation
        let ok = pb.setData(png, forType: .png)
            || (tiff.map { pb.setData($0, forType: .tiff) } ?? false)
        guard ok else { throw Failure.clipboardFailed }
    }

    /// 一步到位 —— 按钮直接调它。返回值决定按钮那三态, **失败不许静默**。
    static func copyImage(text: String, basePath: String?, caption: String?, dark: Bool,
                          to pb: NSPasteboard = .general) -> Result {
        do {
            let png = try png(text: text, basePath: basePath, caption: caption, dark: dark)
            try copyToPasteboard(png, to: pb)
            return .copied
        } catch Failure.tooLong(let height) {
            return .tooLong(height: height)
        } catch {
            return .failed
        }
    }
}
