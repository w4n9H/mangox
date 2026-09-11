//
//  SettingsView.swift
//  P4.0.4 最小设置页 (主区切换视图): 并发回合上限。
//  通知开关随 P4.1 加入; 版式统一为 macOS 系统设置范式 (左标题+说明 / 右控件)。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject private var notifier = CompletionNotifier.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CodexTheme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    concurrencySection
                    notificationSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(CodexTheme.bgChat)
    }

    private var header: some View {
        HStack {
            Text("SETTINGS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(CodexTheme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - 统一行范式: 左标题+说明, 右控件

    private func settingRow<Control: View>(title: String, detail: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }

    // MARK: - 并发上限

    private var concurrencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "并发回合上限",
                       detail: "每个在途任务是一个独立 pi 进程 (约 50MB), 请按机器负载设置") {
                Stepper(value: Binding(
                    get: { store.maxConcurrentTurns },
                    set: { store.maxConcurrentTurns = $0 }
                ), in: 1...20) {
                    HStack(spacing: 6) {
                        Text("\(store.maxConcurrentTurns)")
                            .font(CodexFonts.monoFont(14, weight: .semibold))
                            .foregroundStyle(CodexTheme.accent)
                            .frame(width: 24)
                        Text("个任务")
                            .font(.system(size: 12))
                            .foregroundStyle(CodexTheme.textSecondary)
                    }
                }
                .fixedSize()
            }
            Divider().overlay(CodexTheme.divider)
            Text("超过上限时: 会话发送被拒绝并提示; 定时任务到点会跳过并在日志会话记录原因。")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCard()
    }

    // MARK: - 回合完成通知 (P4.1)

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "回合完成通知",
                       detail: "App 在后台时, 回合结束弹出系统通知; 前台使用时不弹, 点击通知跳回对应会话") {
                Toggle(isOn: Binding(
                    get: { store.completionNotificationsEnabled },
                    set: { on in
                        store.completionNotificationsEnabled = on
                        if on {
                            Task { await CompletionNotifier.shared.ensureAuthorization() }
                        }
                    }
                )) {
                    Text("回合完成通知")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }
            statusHint
        }
        .settingsCard()
    }

    @ViewBuilder
    private var statusHint: some View {
        let hint: String? = {
            switch notifier.authorizationStatus {
            case .denied:
                return "⚠️ 系统通知未授权 —— 请到 系统设置 → 通知 → MangoX 开启"
            case .notDetermined:
                return "尚未请求通知授权, 打开开关后首次完成时会请求"
            default:
                return nil
            }
        }()
        if let hint {
            Divider().overlay(CodexTheme.divider)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
        }
    }
}

// MARK: - 设置卡片容器 (等宽 + 统一边框/圆角)

private extension View {
    func settingsCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodexTheme.bgElevated)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(CodexTheme.divider, lineWidth: 1)
            )
    }
}
