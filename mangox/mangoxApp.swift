//
//  mangoxApp.swift
//  mangox
//
//  Pixel-level UI replica of OpenAI Codex Desktop (mock data only).
//

import SwiftUI

/// 主题外观单例: 写 UserDefaults 的同时立即应用到 NSApp,
/// 并通过 @Published 驱动按钮图标刷新 (@AppStorage 在 App struct 上不可靠)。
final class AppearanceModel: ObservableObject {
    static let shared = AppearanceModel()

    @Published var current: String {
        didSet {
            UserDefaults.standard.set(current, forKey: "appAppearance")
            NSApp.appearance = NSAppearance(named: current == "dark" ? .darkAqua : .aqua)
        }
    }

    private init() {
        current = UserDefaults.standard.string(forKey: "appAppearance") ?? "light"
    }

    func toggle() {
        current = current == "dark" ? "light" : "dark"
    }

    /// 启动时应用持久化外观 (不重复发布)。
    func apply() {
        NSApp.appearance = NSAppearance(named: current == "dark" ? .darkAqua : .aqua)
    }
}

@main
struct mangoxApp: App {
    var body: some Scene {
        WindowGroup("Mangox") {
            ContentView()
                .frame(minWidth: Tune.windowMinSize.width, minHeight: Tune.windowMinSize.height)
                .background(CodexTheme.bgBase)
                .onAppear { AppearanceModel.shared.apply() }
        }
        .defaultSize(width: Tune.windowDefaultSize.width, height: Tune.windowDefaultSize.height)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
    }
}