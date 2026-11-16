//
//  CompletionNotifier.swift
//  P4.1: 回合完成系统通知 (UNUserNotificationCenter)。
//  触发判定在 ChatStore (App 非前台 + 开关开); 这里只管授权与投递。
//  冒烟安全: 无 bundle id (CLI 直编) 不建 center — UNUserNotificationCenter.current() 会 fatal。
//

import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class CompletionNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifier()
    private var center: UNUserNotificationCenter?

    /// 点击通知 → 打开对应会话 (App 启动 attach 时挂)。
    var onOpen: ((UUID) -> Void)?
    /// P19: 点击结论通知 → 打开收件箱里那条（S7 接；未接时回落 `onOpen`）。
    var onOpenFinding: ((UUID) -> Void)?
    /// 授权状态 (设置页提示用)。
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    override private init() {
        super.init()
        guard Bundle.main.bundleIdentifier != nil else { return }
        center = UNUserNotificationCenter.current()
    }

    /// AppDelegate 启动期安装 delegate (点击响应要求启动早期设置)。
    func installDelegate() {
        center?.delegate = self
    }

    /// 设置页开启 / App 启动(开关已开)时调用: 仅 notDetermined 才请求授权。
    func ensureAuthorization() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        guard settings.authorizationStatus == .notDetermined else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        authorizationStatus = granted ? .authorized : .denied
    }

    /// 投递完成通知 (identifier 带会话 id, 点击跳转)。
    func post(sessionId: UUID, title: String, body: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["sessionId": sessionId.uuidString]
        let request = UNNotificationRequest(
            identifier: "turn-\(sessionId.uuidString)-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        try? await center.add(request)
    }

    /// P19: 助理结论通知。多带一个 `findingId` —— 点击该落在**那条结论**上，
    /// 而不是落在"一场越来越长的日志会话"上（§03 验收项 10）。
    func postFinding(findingId: UUID, sessionId: UUID, title: String, body: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["sessionId": sessionId.uuidString,
                            "findingId": findingId.uuidString]
        let request = UNNotificationRequest(
            identifier: "finding-\(findingId.uuidString)",   // 同一条结论只留一条通知
            content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate (点击激活 + 跳会话)

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let sid = (response.notification.request.content.userInfo["sessionId"] as? String)
            .flatMap(UUID.init(uuidString:))
        let fid = (response.notification.request.content.userInfo["findingId"] as? String)
            .flatMap(UUID.init(uuidString:))
        if let sid {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                // 有 findingId 就落到那条结论（S7 接上收件箱高亮）; 没有就退回日志会话。
                if let fid { self.onOpenFinding?(fid) } else { self.onOpen?(sid) }
            }
        }
        completionHandler()
    }
}
