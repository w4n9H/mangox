//
//  mangoxApp.swift
//  mangox
//
//  Pixel-level UI replica of OpenAI Codex Desktop (mock data only).
//

import SwiftUI

// AppearanceModel / AppAppearance 已外移到 Theme/AppAppearance.swift
// (此处含 @main 不参与冒烟编译, 定义留在这儿会被迫在 smoke/stubs 里复制一份)。

@main
struct mangoxApp: App {
    // P4.1: 启动早期安装通知 delegate (点击通知跳会话的响应依赖启动期设置)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Mangox") {
            L10nRoot {
                ContentView()
                    .frame(minWidth: Tune.windowMinSize.width, minHeight: Tune.windowMinSize.height)
                    .background(CodexTheme.bgBase)
                    .onAppear {
                        AppearanceModel.shared.apply()
                    }
            }
        }
        .defaultSize(width: Tune.windowDefaultSize.width, height: Tune.windowDefaultSize.height)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
    }
}

// MARK: - AppDelegate (P4.1 通知 delegate 安装)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CompletionNotifier.shared.installDelegate()
    }
}