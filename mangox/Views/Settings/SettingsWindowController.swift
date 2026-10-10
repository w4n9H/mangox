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
        win.makeKeyAndOrderFront(nil)
        store.showSettingsPanel = true   // 侧栏高亮 / 其它消费点读的就是它
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
        win.setContentSize(Tune.settingsWindowSize)
        win.contentMinSize = Tune.settingsWindowMinSize   // 拖到首版尺寸就打住, 再小只会更难读
        win.center()

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
