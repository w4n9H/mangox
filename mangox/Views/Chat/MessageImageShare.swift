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

    // MARK: - 提前拒（省掉白排版）

    /// 字符数**密到极致也装不下**时返回真 —— 连排版都不必做。
    ///
    /// 为什么要有这一步：出图前那趟 `NSHostingView` 排版（4 拍 RunLoop + 两趟布局）实测
    /// 180ms(短回复) ~ 460ms(顶到上限)；而**超长的那些恰恰更久** —— 一个 `Text` 承载整段
    /// 是平方级的，一屏装不下的正文能把这一步拖到秒级。用户点了「分享」干等几秒换回一句
    /// "太长"，而这件事一次 O(n) 数数就能当场说清。
    ///
    /// ⚠️ 这是**下界**，不是预估：取"比任何真实字形都窄 / 比任何真实行距都矮"的假设算出来
    ///    仍旧超过 `shareMaxHeight`，那真排版只会更高 ⇒ **不可能误拒**。
    ///    反过来，低于下界**不说明能出图** —— 判决仍然只属于排版后的真高度。
    ///    （源码下面那句"按字符数预估会说谎"，说的是拿它当**判决**，不是当下界的反证。）
    static func certainlyTooLong(_ text: String) -> Bool {
        lowerBoundHeight(text) > Tune.shareMaxHeight
    }

    /// 高度下界（pt）。想调门槛就动下面两个常量，但**只能往更松的方向调**（见上）。
    static func lowerBoundHeight(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let lines = (CGFloat(text.count) / charsPerLineUpperBound).rounded(.up)
        return lines * minLineAdvance
    }

    /// 一行最多塞多少字符 —— **上界**。2.8pt/字比 10pt 字号的任何字形都窄。
    private static var charsPerLineUpperBound: CGFloat { Tune.shareWidth / 2.8 }
    /// 一行至少占多高 —— **下界**。正文实际行距 ≈ 18pt，取 11 留近一倍余量。
    private static let minLineAdvance: CGFloat = 11

    // MARK: - 渲染

    /// 正文 (markdown) → PNG。
    ///
    /// `dark` 决定配色: `CodexTheme.adaptive()` 是 NSColor **动态色**, 离屏渲染时按
    /// **环境 `colorScheme`** 解析 (`.environment(\.colorScheme, …)`); 换 `NSAppearance` 那招
    /// 实测不生效 —— 见 `md_preview.py` 里同一条注释。
    ///
    /// `htmlName` / `htmlSnapshot` (2026-11-26): 这一轮的网页产物。**两块预算冲突的解法**：
    /// 先按"带图"排一次，超上限就把图降级成文件名条、再排一次（只降一次，不递归）。
    /// 降级而不是直接拒 —— 分享的主体是正文，网页那块是附赠；整张图不出是最差的结果。
    /// 两条都超 ⇒ 还是拒（"不出半张图"这条没松）。
    static func png(text: String, basePath: String?, caption: String?,
                    htmlName: String? = nil, htmlSnapshot: NSImage? = nil,
                    dark: Bool) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        // 密到极致也装不下 ⇒ 连排版都别做（下界，不会误拒；见 `certainlyTooLong`）。
        // ⚠️ 这个下界**只算正文**，不含网页那块 —— 所以它依旧成立（是下界，不是预估）。
        guard !certainlyTooLong(trimmed) else {
            throw Failure.tooLong(height: lowerBoundHeight(trimmed))
        }

        var preview = htmlName.map { ShareCardText.ShareHtmlPreview(name: $0, snapshot: htmlSnapshot) }
        var laid = layout(trimmed, basePath: basePath, caption: caption, preview: preview, dark: dark)
        if laid.height > Tune.shareMaxHeight, preview?.snapshot != nil {
            preview?.snapshot = nil
            laid = layout(trimmed, basePath: basePath, caption: caption, preview: preview, dark: dark)
        }
        // ⚠️ **长图上限: 超了就不出图** (2026-10-22 boss「超过 3 屏的就可以不出了」)。
        // 只能在**这里**判 —— 高度只有真排版才准 (折行/表格/图片都算在里头), 按字符数预估会说谎,
        // 症状是"按钮说能出、点下去被拒"。
        guard laid.height <= Tune.shareMaxHeight else {
            throw Failure.tooLong(height: laid.height)
        }

        // 定值 2x —— **没有"超长就降 1x"的分支**: 要么出清楚的图, 要么不出。
        let scale: CGFloat = 2
        let pxW = Int(Tune.shareWidth * scale), pxH = Int(laid.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure.renderFailed
        }
        rep.size = NSSize(width: Tune.shareWidth, height: laid.height)
        laid.host.cacheDisplay(in: laid.host.bounds, to: rep)
        withExtendedLifetime(laid.win) {}   // 窗口要活到这一行: 提前释放会让 display 通道拿到空内容
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure.renderFailed
        }
        return png
    }

    /// 排一次版，回来时高度是**落定后**的。
    ///
    /// 抽出来是为了加网页预览时能排**两遍**（带图 / 降级成条）而不把下面这套
    /// "4 拍 RunLoop + 重取高度"抄第二份 —— 那几条注释每一条都是踩坑踩出来的。
    private static func layout(_ text: String, basePath: String?, caption: String?,
                               preview: ShareCardText.ShareHtmlPreview?,
                               dark: Bool)
        -> (host: NSHostingView<AnyView>, win: NSWindow, height: CGFloat) {

        let card = AnyView(
            ShareCardText(text: text, basePath: basePath, caption: caption, htmlPreview: preview)
                .frame(width: Tune.shareWidth, alignment: .topLeading)
                .background(CodexTheme.bgChat)
                .environment(\.colorScheme, dark ? .dark : .light)
        )

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
        return (host, win, height)
    }

    // MARK: - 出口

    /// 放进剪贴板。**PNG 和 TIFF 都写** —— 一部分老 IM 只认 TIFF (代价实测: 一张卡片
    /// TIFF ≈ 2.9 MB, PNG ≈ 128 KB; 嫌重就删掉 TIFF 那一支)。
    static func copyToPasteboard(_ png: Data, to pb: NSPasteboard = .general) throws {
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        // ⚠️ 两个 setData **都要执行**：写成 `pngOK || tiffOK` 会短路，
        //    声明了 `.tiff` 却不写数据 ⇒ 只认 TIFF 的老 IM 拿到空图（2026-11-04 评审发现）。
        let wrote = writeBothFormats(
            png: png,
            writePNG: { pb.setData($0, forType: .png) },
            writeTIFF: { pb.setData($0, forType: .tiff) })
        guard wrote else { throw Failure.clipboardFailed }
    }

    /// 两种格式的写入策略：**两个 writer 都必须被调用**，成功条件是至少一个写成。
    ///
    /// 单独抽出来是为了能被冒烟判据钉住 —— `NSPasteboard` 会按需把 PNG 合成 TIFF，
    /// 直接读 `.tiff` 的端到端断言在旧 `||` 写法下**照样绿**（2026-11-04 反例实测）。
    static func writeBothFormats(png: Data,
                                 writePNG: (Data) -> Bool,
                                 writeTIFF: (Data) -> Bool) -> Bool {
        let pngOK = writePNG(png)
        let tiffOK = NSImage(data: png)?.tiffRepresentation.map(writeTIFF) ?? false
        return pngOK || tiffOK
    }

    /// 一步到位 —— 按钮直接调它。返回值决定按钮那三态, **失败不许静默**。
    ///
    /// 网页那张快照是**在外面**抓好的（`HtmlSnapshot` 是异步的，而这里是同步的排版+出图）——
    /// 快照失败传 nil 即可，那会降级成文件名条，不会让整张图失败。
    static func copyImage(text: String, basePath: String?, caption: String?, dark: Bool,
                          htmlName: String? = nil, htmlSnapshot: NSImage? = nil,
                          to pb: NSPasteboard = .general) -> Result {
        do {
            let png = try png(text: text, basePath: basePath, caption: caption,
                              htmlName: htmlName, htmlSnapshot: htmlSnapshot, dark: dark)
            try copyToPasteboard(png, to: pb)
            return .copied
        } catch Failure.tooLong(let height) {
            return .tooLong(height: height)
        } catch {
            return .failed
        }
    }
}
