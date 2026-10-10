//
//  AppCommands.swift
//  菜单栏接线 —— 让 MangoX 长出一套「Mac App 该有的」菜单命令。
//
//  ⚠️ mangoxApp.swift (@main) **不参与冒烟编译** ⇒ 命令体一律只做转发,
//     真实逻辑留在可测的 store / controller 里; app 入口只留一行 `.commands { AppCommands() }`。
//
//  ⚠️ 菜单命令够不到 `ContentView` 里的 `@StateObject store` —— 走 SwiftUI 的
//     `focusedSceneValue` / `@FocusedValue` 通道把**当前窗口的 store** 递过来。
//     没有聚焦窗口时 store 为 nil ⇒ 命令置灰 (不留"点了没反应"的死项)。
//

import AppKit
import SwiftUI

// MARK: - FocusedValue 通道

private struct ChatStoreFocusedKey: FocusedValueKey {
    typealias Value = ChatStore
}

extension FocusedValues {
    /// 当前聚焦窗口的 store。`ContentView` 用 `.focusedSceneValue(\.chatStore, store)` 注入。
    var chatStore: ChatStore? {
        get { self[ChatStoreFocusedKey.self] }
        set { self[ChatStoreFocusedKey.self] = newValue }
    }
}

// MARK: - 命令集

struct AppCommands: Commands {
    @FocusedValue(\.chatStore) private var store

    var body: some Commands {
        // 设置… ⌘, —— macOS 惯例位。SwiftUI 只在声明了 `Settings` 场景时才给这一项,
        // 而我们的设置是独立 NSWindow (SettingsWindowController) ⇒ 必须显式接管。
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { if let store { SettingsWindowController.shared.show(store: store) } }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(store == nil)
        }

        // 新会话 ⌘N —— 接在系统「文件 > 新建」惯例位之后。
        CommandGroup(after: .newItem) {
            Button("新会话") { store?.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(store == nil)
        }

        // 刷新工作区 ⌘R —— 重扫文件树 (合并保住展开态) + 让视图重载 git / 统计。
        CommandGroup(after: .toolbar) {
            Button("刷新工作区") { store?.refreshWorkspace() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store?.activeProjectPath == nil)
        }

        // 工作区中查找 ⌘F —— macOS「在当前视图里查找」的惯例位 (Edit 菜单尾)。
        // ⚠️ MangoX **没有全局搜索**, 这里对齐的是「聚焦当前视图的过滤框」, 不假装是"搜整个 App"。
        CommandGroup(after: .pasteboard) {
            Button("工作区中查找") { store?.focusWorkspaceFilter() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store?.activeProjectPath == nil)
        }

        // 使用手册 —— 当前唯一可交付的文档是仓库 README (无独立站点)。
        CommandGroup(replacing: .help) {
            Button("MangoX 使用手册") { Self.openREADME() }
        }
    }

    private static let readmeURL = URL(string: "https://github.com/w4n9H/mangox#readme")

    private static func openREADME() {
        guard let readmeURL else { return }
        NSWorkspace.shared.open(readmeURL)
    }
}
