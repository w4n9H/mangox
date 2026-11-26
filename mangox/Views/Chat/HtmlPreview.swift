//
//  HtmlPreview.swift
//  对话区的 HTML 预览（2026-11-26）。
//
//  要解决的是这样一件事: 让助手写一份 html（报告 / 图 / 小工具），写完就得**当场看见长什么样**，
//  而不是回头去工作区找文件、或者拖到浏览器里打开。它对应的是"鹈鹕测试"那种用法 ——
//  生成的产物与看到的效果之间不该隔一步操作。
//
//  三个判据/取舍，写在这里免得以后被"优化"掉:
//
//  ① **只有最近一轮真渲染**。对话区是 `LazyVStack`，屏外行会被销毁重建；每张卡都挂一个
//     `WKWebView` 的话，滚动时页面会被反复重新加载、内部滚动位置也会丢 —— 那是"看起来能用、
//     一滚就垮"。所以历史轮次退化成一行「文件名 + 预览」（点开才渲染），整场对话里
//     同时最多只有一个活着的 WebView。
//
//  ② **读权限给到项目根**，不是文件所在目录。真实产物常常是 `docs/x.html` + `../assets/*.css`
//     这种结构（本仓自己的设计文档就是），只给同目录会静默丢样式 —— 而"预览里没样式"这个
//     症状最容易被误判成"生成的 html 有问题"。
//
//  ③ **非 file:// 的导航一律拦掉**。预览里点一个链接，正确的行为不是"把预览变成浏览器"
//     （它会离开这一页、还没有后退入口），而是交给系统浏览器。
//
//  ④ **只预览写完的那份**。工具卡在模型**决定**写的时候就进 `messages` 了，文件那时还不存在；
//     而卡是按路径缓存的 —— 提前上屏会显示"文件不在了"且永不自己恢复。判据 = `phase == .done`
//     （见 `HtmlPreviewTarget.pick`）。
//
//  ⑤ **一轮结束才上屏**（boss 定的）。理由不是性能，是语义: 预览回答的是"这件事做完了，给我看
//     结果"，不是"边做边直播"。一轮里模型常常写一版、改一版，中途上屏 = 把草稿推到眼前。
//     判据是 `store.isStreaming`（回合在途）—— **不是**"文件写完了没"，两者不是一回事。
//     由此还省掉一整套机制: 卡只在一轮定稿后出现，所以"同一轮内改了两次要不要重载"这个问题
//     不存在（`lastKey` 只看路径就够了）。
//

import AppKit
import SwiftUI
// WebKit 的 Sendable 标注是残缺的（SDK 还是老的并发模型），在 Swift 5 语言模式下会就
// 「跨隔离传递 WKNavigationAction 之类」报一条告警。本项目要求 0 warning，而这条**修不了**
// ——它在 SDK 里，不在我们的代码里。`@preconcurrency` 正是编译器给的处置方式：
// 让这个模块的诊断按旧规则放行。⚠️ 这不是"把警告藏起来"：我们所有 WebKit 调用都发生在
// 主线程（`NSViewRepresentable` 与 delegate 回调），并发上确实没有真问题。
@preconcurrency import WebKit

// MARK: - 选哪个文件

/// 一轮里改了哪几份 html —— 判据只有这一处（纯函数，冒烟直接打）。
enum HtmlPreviewTarget {

    /// 一次产物里**这一轮最后写的那份、而且已经写完的** html（相对路径）。
    ///
    /// 扫描顺序是 message **新 → 旧**，所以第一个命中的就是"最后修改的那个"
    /// —— 与用户直觉一致（他刚让我改的是那份）。多份 html 时也只能取一份：
    /// 模型可能同时产出一份报告 + 一张图 + 一个工具页，**没有依据**知道用户要看哪个，
    /// 取最后改的那个是唯一说得通的选择。
    ///
    /// ⚠️ **只认 `phase == .done`**（2026-11-26 评估空白屏时揪出来的）: 工具卡在模型**决定**
    ///    写的那一刻就进了 `messages`（`phase = .queued`），而文件要等工具跑完才存在。
    ///    不过滤的后果是卡先弹出来、文件还不在 ⇒ 显示"文件不在了"，然后因为 `lastKey` 只看
    ///    路径、路径没变 ⇒ **永远不会自己恢复**，用户得当故障处理。
    ///    同一份文件写两次时，用**最新那次**的 phase 判（逆序扫，第一面即最新）。
    ///
    /// 不认 `.htm` 之外的变体写法差异：扩展名大小写不敏感（`REPORT.HTML` 也算），
    /// 但**不以内容嗅探兜底**（"看着像 html" 不是判据，模型也可能写 `page.txt`）。
    static func pick(in messages: [ChatMessage], root: String?) -> String? {
        var seen: Set<String> = []
        var order: [String] = []
        var latestPhase: [String: ToolPhase] = [:]
        for msg in messages.reversed() {
            guard case .tool(let t) = msg.content,
                  t.kind == .edit || t.kind == .write else { continue }
            let rel = workspaceRelativePath(t.title, root: root)
            guard !rel.isEmpty else { continue }
            // 逆序遍历 ⇒ 第一次见到的就是**最新**那一次调用的状态。
            if seen.insert(rel).inserted {
                order.append(rel)
                latestPhase[rel] = t.phase
            }
        }
        return order.first { isHTML($0) && latestPhase[$0] == ToolPhase.done }
    }

    static func isHTML(_ path: String) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return true
        default:            return false
        }
    }

    /// 这一轮该不该挂卡 / 挂成什么样 —— 判据只有这一处。
    ///
    /// ⚠️ **回合还在跑就先不挂**（2026-11-26 boss 定）: 预览的时机是"一件事做完了给我看结果"，
    ///    而不是"边做边直播"。模型一轮里通常会写一版、看一眼、再改一版，中途上屏等于把草稿
    ///    推到眼前，而且每次改动都会让卡重载、闪一下。
    ///    判据用 `store.isStreaming`（会话级回合在途），**不是**"文件写完了没" —— 文件写完
    ///    之后模型往往还要接着写正文或改别的东西。
    ///
    /// 历史轮次一律挂成 `isLive: false` 的一行（理由见文件头 ①）。
    static func hint(isLastGroup: Bool, turnRunning: Bool, pick: String?) -> HtmlPreviewHint? {
        guard let pick else { return nil }
        if isLastGroup && turnRunning { return nil }
        return HtmlPreviewHint(path: pick, isLive: isLastGroup)
    }
}

/// 一张预览卡的归属信息（挂在**该轮末条 assistant 正文**上，与轮末账单同一个宿主）。
struct HtmlPreviewHint: Equatable {
    /// 相对项目根的路径。
    let path: String
    /// 是不是"最近一轮" —— 只有它真渲染，其余退化成一行（见文件头 ①）。
    let isLive: Bool
}

// MARK: - WebView

/// 本地 html 的渲染面。**一个实例一次只加载一个文件**，不缓存历史页 ——
/// 缓存带来的收益（滚动回去不用重载）远小于它的代价（同一个 WKWebView 在两个父视图之间
/// 搬家会出现白屏 / 位置跳动）。
struct HtmlPreviewWebView: NSViewRepresentable {
    let fileURL: URL
    /// 允许读取的根（项目根）。理由见文件头 ②。
    let readAccessRoot: URL
    /// 点「刷新」时 +1 —— `updateNSView` 靠它决定要不要重新 load。
    let reloadToken: Int
    /// 加载失败时把原因交回去（`nil` = 正常）。失败**不许静默**: 空白区域会被读成
    /// "这个 html 是空的"，而真相是"文件没了 / 路径不对"。
    @Binding var failure: String?

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        // 预览不该有"后退"这个动作: 它只有一页, 而手势会把这一页滑走、露出空白。
        web.allowsBackForwardNavigationGestures = false
        // 生成出来的页面自己会画底色; 这层只管"页面还没画上来"的那一瞬 ——
        // 不设的话暗色界面里会先闪一块白。
        web.underPageBackgroundColor = .clear
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.rootPath = readAccessRoot.path
        let key = "\(fileURL.path)#\(reloadToken)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // ⚠️ 必须异步改: 这是**视图更新期**（updateNSView 里），同步写 @Binding 会撞
            //    "Modifying state during view update" —— 表现是界面卡一帧 + 控制台一堆红字。
            let message = L("文件不在了（可能这一轮又把它删了）")
            DispatchQueue.main.async { failure = message }
            return
        }
        DispatchQueue.main.async { failure = nil }
        web.loadFileURL(fileURL, allowingReadAccessTo: readAccessRoot)
    }

    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let failure: Binding<String?>
        var lastKey: String?
        var rootPath: String = ""

        init(failure: Binding<String?>) { self.failure = failure }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // 被我们主动取消的导航也会走到这里 —— 那不是"页面坏了"，不许报错。
            if (error as NSError).code == NSURLErrorCancelled { return }
            failure.wrappedValue = L("这个页面没能加载出来（文件太大或编码不对）")
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            // 页面内的锚点跳转（`#foo`）没有 scheme，放行。
            if url.isFileURL, url.path.hasPrefix(rootPath) {
                decisionHandler(.allow)
                return
            }
            if !url.isFileURL {
                // 交给系统浏览器 —— 用户点的是"一个链接"，他要的是那个页面，不是这个预览窗。
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

// MARK: - 卡

/// 这一轮的 html 产物。挂在**轮末那条正文**下面（与轮末账单同一个宿主）。
struct HtmlPreviewCard: View {
    let hint: HtmlPreviewHint
    /// 项目根（读权限的边界 + 相对路径的基准）。
    let root: String

    @State private var reloadToken = 0
    @State private var failure: String?
    @State private var zoomed = false
    @State private var hovering = false

    private var fileName: String { (hint.path as NSString).lastPathComponent }

    private var fileURL: URL? {
        guard !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(hint.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if hint.isLive, let url = fileURL {
                Divider().overlay(CodexTheme.divider)
                HtmlPreviewWebView(fileURL: url,
                                   readAccessRoot: URL(fileURLWithPath: root),
                                   reloadToken: reloadToken,
                                   failure: $failure)
                    .frame(height: Tune.htmlPreviewCardHeight)
                    .clipped()
                if let failure {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.toolRunning)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CodexTheme.divider, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .help(hint.path)
        .sheet(isPresented: $zoomed) {
            if let url = fileURL {
                HtmlPreviewSheet(url: url, root: URL(fileURLWithPath: root), title: fileName)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textTertiary)
            Text(verbatim: fileName)
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // 历史轮次没有活着的那块渲染区 ⇒ 它只需要一个"点开看看"。
            if !hint.isLive {
                action(L("预览"), "eye") { zoomed = true }
            } else if hovering {
                // 三个按钮只在悬停时出现: 常驻会跟"这一轮改了什么"抢注意力，
                // 而它们在 95% 的时间里都不会被点（同 footerToolbar 那条取舍）。
                action(L("刷新"), "arrow.clockwise") { reloadToken += 1 }
                action(L("放大"), "arrow.up.left.and.arrow.down.right") { zoomed = true }
                action(L("在浏览器打开"), "safari") {
                    if let url = fileURL { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(CodexTheme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// 「放大」那一层。**不复用卡里那块** —— 一个 WKWebView 不能同时挂在两个父视图上，
/// 而 sheet 打开时卡还在屏幕上（会白屏）。
struct HtmlPreviewSheet: View {
    let url: URL
    let root: URL
    let title: String

    @State private var reloadToken = 0
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                Text(verbatim: title)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer()
                Button(L("刷新")) { reloadToken += 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textTertiary)
                Button(L("关闭")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider().overlay(CodexTheme.divider)
            HtmlPreviewWebView(fileURL: url, readAccessRoot: root,
                               reloadToken: reloadToken, failure: $failure)
            if let failure {
                Text(failure)
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.toolRunning)
                    .padding(8)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(CodexTheme.contentPanel)
    }
}
