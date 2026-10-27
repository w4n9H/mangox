//
//  SettingsWindowController.swift
//  设置从「主区整页覆盖」升级为**独立窗口** —— macOS 惯例: ⌘, 可开、能从菜单栏开、可与主窗口并存。
//  形态对齐 MiniWindowController (singleton + 弱引用 store + isReleasedWhenClosed = false 复用窗口对象)。
//
//  ⚠️ 独立 NSWindow **不继承主窗口的 environment** ⇒ 必须自己包一层 L10nRoot
//     (与 mini 台 / QuickCapture 同款; 见 AppLanguage.swift 「四处独立 SwiftUI 根」)。
//  ⚠️ 本文件**参与冒烟编译** ⇒ 窗口语义可被断言, 逻辑别写进 mangoxApp.swift (@main 不入冒烟)。
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private weak var store: ChatStore?
    private var langCancellable: AnyCancellable?

    /// 打开设置窗 (首次建窗, 之后复用并前置)。
    func show(store: ChatStore) {
        self.store = store
        let win = window ?? makeWindow(store: store)
        window = win
        // store 换代 (ContentView 重建) 时重挂内容 —— 否则窗口指向上一份已失效的 store。
        if hostingStore !== store { win.contentView = makeHosting(store: store) }
        // ⚠️ **每次开都重算尺寸与位置**：主窗口可能被拖过、缩过、挪过屏 —— 只算一次的话，
        //    第二次打开就会出现"比主窗口还大"或"漂到屏幕另一边"（正是 2026-10-26 那条投诉）。
        fit(win)
        win.makeKeyAndOrderFront(nil)
        store.showSettingsPanel = true   // 侧栏高亮 / 其它消费点读的就是它
    }

    /// 把设置窗**收进主窗口**并居中到它上面（2026-10-26 boss: 弹出页不能超过主窗口、要居中）。
    ///
    /// 几何全部在 `SettingsWindowFit`（纯函数，冒烟守着）；这里只负责**顺序**：先定尺寸再定位置。
    /// 反过来算的话，位置是按旧尺寸算的，窗口会偏。
    private func fit(_ win: NSWindow) {
        guard let host = mainWindow() else {
            win.setContentSize(Tune.settingsWindowSize)
            win.center()   // 主窗口不在（mini 台 / 全隐藏）⇒ 退回屏幕居中
            return
        }
        let content = SettingsWindowFit.contentSize(
            preferred: Tune.settingsWindowSize,
            host: host.frame.size,
            margin: Tune.settingsWindowMargin)
        win.contentMinSize = SettingsWindowFit.minSize(preferredMin: Tune.settingsWindowMinSize,
                                                       content: content)
        win.setContentSize(content)   // ⇐ 必须先设尺寸：下面的 origin 要用窗口外框（含标题栏）

        let screen = (host.screen ?? win.screen)?.visibleFrame ?? host.frame
        win.setFrameOrigin(SettingsWindowFit.origin(windowSize: win.frame.size,
                                                    host: host.frame,
                                                    screen: screen))
    }

    /// 主窗口 = 扣掉自己、迷你台、各种 panel 之后那个可见窗口
    /// （与 `ContentView` 里 mini 模式那条判据同一口径）。
    private func mainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0 !== window
                && !($0 is NSPanel)
                && $0.identifier?.rawValue != "miniTaskWindow"
                && $0.identifier?.rawValue != "settingsWindow"
                && $0.isVisible
        }
    }

    /// 侧栏按钮 / 菜单共用入口: 开着就关, 关着就开。
    func toggle(store: ChatStore) {
        if window?.isVisible == true { window?.close() } else { show(store: store) }
    }

    private var hostingStore: ChatStore?

    private func makeHosting(store: ChatStore) -> NSView {
        hostingStore = store
        return NSHostingView(rootView: L10nRoot { SettingsView(store: store) })
    }

    private func makeWindow(store: ChatStore) -> NSWindow {
        // ⚠️ `.resizable` 是 2026-10-10 加的 (首版没给): 固定尺寸的窗口一旦觉得挤, 用户只能等改代码。
        //    内容面本就是流式的 (SettingsView 外层 `frame(maxWidth: .infinity)`) ⇒ 拖大只会更舒展。
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Tune.settingsWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.identifier = NSUserInterfaceItemIdentifier("settingsWindow")
        win.isReleasedWhenClosed = false   // 红灯 close 只隐藏, 窗口对象复用
        win.contentView = makeHosting(store: store)
        // 尺寸/位置不在这里定 —— 见 `fit(_:)`：它每次开都按当时的主窗口重算。

        // 红灯 / ⌘W 关窗 → 同步 flag (侧栏高亮跟着灭, 不留"面板开着"的假状态)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.showSettingsPanel = false }
        }

        // 标题跟着语言走 —— 窗口标题是 L() 取词, 不订阅的话切语言后会冻在旧值
        // (同 SwiftUI 的「冻结取词」坑, 见 scripts/l10n/scan_wiring.py 的守卫)。
        win.title = L("设置")
        langCancellable = LanguageModel.shared.$current
            .receive(on: RunLoop.main)
            .sink { [weak win] _ in win?.title = L("设置") }
        return win
    }
}
