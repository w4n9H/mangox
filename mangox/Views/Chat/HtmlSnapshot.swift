//
//  HtmlSnapshot.swift
//  把一份本地 html 截成一张图（分享图里那块「网页预览」用它）。
//
//  为什么不能复用屏幕上那个 `WKWebView`（`HtmlPreviewCard` 里那块）：
//  ① 它只有**最后一轮**才有（历史轮次根本不渲染，见 `HtmlPreview.swift` 文件头 ①）；
//     而分享按钮在任意一条消息上都能点。
//  ② 它随时会被 LazyVStack 销毁重建 —— 拿别人的 View 去做一次性快照，是在跟生命周期抢。
//  所以这里**每次现开一个离屏的**：开销是一次 load + 一次快照，几百毫秒，而分享是低频动作。
//
//  三个坑（都踩过或必然踩到）：
//
//  ① **必须挂进一个真窗口**。裸 `WKWebView`（没有 window）的 `takeSnapshot` 常拿到空白 ——
//     它要靠 `display` 通道把内容画进位图，而离屏视图默认不参与那条通道。
//     窗口用 `.borderless` 且**不上屏**（不 `makeKeyAndOrderFront`），与 `MessageImageShare`
//     排版用的是同一条路子。
//
//  ② **`didFinish` 之后立刻截图会拿到空白/半成品**。`didFinish` 只保证 DOM 好了，字体解码、
//     首帧渲染还要一拍。所以等 `settleDelay` 再截（同 `MessageImageShare` 里"抽 RunLoop"的道理）。
//
//  ③ **超时兜底不能省**。`takeSnapshot` 的回调并不保证一定来（页面在跑 `requestAnimationFrame`
//     循环、或者进程被杀）。而 `withCheckedContinuation` **resume 两次会直接崩** ⇒
//     两条出口（回调 / 超时）都必须过同一个 once 闸。
//

import AppKit

@preconcurrency import WebKit

/// 离屏把本地 html 截成图。**失败一律返回 nil** —— 调用方降级成「文件名条」，
/// 绝不许让一次快照失败把整张分享图废掉（分享图的主体是正文，不是这块）。
///
/// `@MainActor`：WKWebView 全流程都在主线程，且 `capture` 是被 `Task { @MainActor }` 调的。
@MainActor
enum HtmlSnapshot {

    /// 单次快照的总预算。超过就当没截到（用户点分享后会转圈等这段时间，不能再长）。
    static let timeout: TimeInterval = 3.0
    /// `didFinish` 之后的落定余量。
    static let settleDelay: TimeInterval = 0.15
    /// `takeSnapshot` 自己的预算。
    static let snapshotTimeout: TimeInterval = 1.5

    /// 截 `fileURL` 的首屏，逻辑尺寸 = `size`。
    ///
    /// ⚠️ 位图倍率**不用自己乘**: `WKSnapshotConfiguration.snapshotWidth` 的单位是 **pt**，
    ///    输出位图再按屏幕的 backing scale（2x）放大。实测传 668 ⇒ 出 1336×1280 px。
    ///    第一版按"像素宽"理解传了 `size.width * 2` ⇒ 出 2672×2560（4x），图白胖四倍。
    static func capture(fileURL: URL, readAccessRoot: URL, size: CGSize) async -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let web = WKWebView(frame: CGRect(origin: .zero, size: size),
                            configuration: WKWebViewConfiguration())
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = web
        // 窗口要活到快照完成 —— 提前释放会让 display 通道拿到空内容（同 `MessageImageShare` 里
        // 那句 `withExtendedLifetime`）。这里靠 defer 拖到函数返回。
        defer { win.contentView = nil }

        let watcher = LoadWatcher()
        web.navigationDelegate = watcher
        await watcher.wait(timeout: timeout) {
            web.loadFileURL(fileURL, allowingReadAccessTo: readAccessRoot)
        }
        web.navigationDelegate = nil

        // ② 首帧落定。
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        return await snapshot(of: web, width: size.width)
    }

    // MARK: - 两个一次性出口

    private static func snapshot(of web: WKWebView, width: CGFloat) async -> NSImage? {
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = NSNumber(value: Double(width))
        return await withCheckedContinuation { (c: CheckedContinuation<NSImage?, Never>) in
            // ③ 回调与超时赛跑 —— 两条路共用一个闸，否则 resume 两次 = 崩。
            let once = Once()
            web.takeSnapshot(with: cfg) { image, _ in
                once.run { c.resume(returning: image) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + snapshotTimeout) {
                once.run { c.resume(returning: nil) }
            }
        }
    }

    /// 等页面 load 完（`didFinish` / 失败 / 超时，三者先到者算数）。
    private final class LoadWatcher: NSObject, WKNavigationDelegate {
        private var cont: CheckedContinuation<Void, Never>?
        private var fired = false

        /// ⚠️ 两件事都必须在这里做对:
        ///    ① **先挂 continuation 再发起 load** —— `loadFileURL` 会同步回调（文件不存在时
        ///       直接 `didFailProvisionalNavigation`），那时 cont 还没赋值就把它漏掉，然后永远等。
        ///    ② **`fired` 已经为真时立刻放开** —— 那次同步回调若发生在另一个入口，`finish` 已跑完，
        ///       这里的 continuation 就再没人 resume（`withCheckedContinuation` 会挂死到超时）。
        func wait(timeout: TimeInterval, start: () -> Void) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if fired { c.resume(); return }
                cont = c
                start()
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish()
                }
            }
        }

        private func finish() {
            guard !fired else { return }
            fired = true
            cont?.resume()
            cont = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) { finish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) { finish() }
    }

    /// 只跑一次。`CheckedContinuation` 被 resume 两次必崩，而这里有两条竞速的出口。
    private final class Once {
        private var done = false
        func run(_ body: () -> Void) {
            guard !done else { return }
            done = true
            body()
        }
    }
}
