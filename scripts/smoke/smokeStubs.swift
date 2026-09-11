//
//  冒烟 stub: AppearanceModel (生产定义在 mangoxApp.swift, 该文件含 @main 不能参与冒烟编译)
//

import AppKit
import SwiftUI

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

    func apply() {
        NSApp.appearance = NSAppearance(named: current == "dark" ? .darkAqua : .aqua)
    }
}
