//
//  MiniWindowController.swift
//  P4.2: mini 工具台窗口 (主窗口变形的承载者)。
//  语义 = Apple Music mini player: 点最小化 → 主窗口隐藏, mini 台在原窗口右下角出现
//  (观感是同一窗口变形); 还原时反向切换。尺寸由 AppKit 全权管理
//  (SwiftUI AppKitWindow 的 size 无法程序性修改, 已实证, 见 [MiniResize] 排查史)。
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class MiniWindowController {
    static let shared = MiniWindowController()
    private var window: NSWindow?
    private weak var mainWindow: NSWindow?
    private weak var store: ChatStore?
    private var cancellable: AnyCancellable?

    /// App 启动挂接 (ContentView onAppear): 建 mini 窗口 (不显示) + 订阅在途回合。
    func attach(store: ChatStore) {
        guard window == nil else { return }
        self.store = store
        let hosting = NSHostingView(rootView: MiniBarWindowView(store: store))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Tune.miniBarWidth, height: 180),
                           styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.identifier = NSUserInterfaceItemIdentifier("miniTaskWindow")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false   // 红灯 close 只隐藏, 窗口对象复用
        win.level = .floating
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = hosting
        win.backgroundColor = .windowBackgroundColor
        window = win
        // 红灯关闭 mini 台 = 还原主窗口 (否则主窗口处于隐藏态, App 变成无窗口)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store?.miniMode = false   // 触发 ContentView 的 restore 链路
            }
        }
        // 卡数变化 → 高度跟随 (锚定左上角)
        cancellable = store.$runningTurns
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] turns in self?.refit(cards: turns.count) }
    }

    /// 进入 mini 形态: 主窗口隐藏 + mini 台出现在其右下角。
    func show(from mainWindow: NSWindow) {
        guard let window else { return }
        self.mainWindow = mainWindow
        let frame = mainWindow.frame
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "mainWindowFrame")
        mainWindow.orderOut(nil)
        positionWindow(atOrigin: frame, visibleFrame: mainWindow.screen?.visibleFrame)
        window.orderFrontRegardless()
    }

    /// 还原主窗口。
    func restore() {
        guard let mainWindow else { return }
        window?.orderOut(nil)
        if let saved = UserDefaults.standard.string(forKey: "mainWindowFrame"),
           NSRectFromString(saved).width > 0 {
            mainWindow.setFrame(NSRectFromString(saved), display: true, animate: true)
        }
        mainWindow.makeKeyAndOrderFront(nil)
    }

    /// mini 台定位: 原(主)窗口右下角, clamp 进屏。
    private func positionWindow(atOrigin frame: NSRect, visibleFrame: NSRect?) {
        guard let window else { return }
        let height = ContentView.miniWindowHeight(cards: store?.runningTurns.count ?? 1)
        let visible = visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        var target = NSRect(x: frame.maxX - Tune.miniBarWidth,
                            y: frame.minY + frame.height - height,
                            width: Tune.miniBarWidth,
                            height: height)
        target.origin.x = min(max(target.origin.x, visible.minX), visible.maxX - target.width)
        target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - target.height)
        window.setFrame(target, display: false)
    }

    /// 卡数变化 → 窗口高度跟随 (保持左上角原位)。
    private func refit(cards: Int) {
        guard let window, window.isVisible else { return }
        let frame = window.frame
        let height = ContentView.miniWindowHeight(cards: cards)
        guard abs(frame.height - height) > 1 else { return }
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height,
                               width: Tune.miniBarWidth, height: height),
                        display: true)
    }
}
