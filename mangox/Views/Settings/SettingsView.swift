//
//  SettingsView.swift
//  P4.0.4 最小设置页 (主区切换视图): 并发回合上限。
//  通知开关随 P4.1 加入; 版式统一为 macOS 系统设置范式 (左标题+说明 / 右控件)。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject private var notifier = CompletionNotifier.shared
    /// P5.1: 自定义模型内联管理 (取消弹窗——卡片即管理面, 对齐 macOS 系统设置范式)。
    @State private var newProvider = ""
    @State private var newModelId = ""
    @State private var newLabel = ""
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CodexTheme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelSection
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

    // MARK: - 自定义模型 (P5.1, 内联管理)

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("自定义模型")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                Text("菜单显示名与 API 名解耦，运行时仍按 provider / model id 透传给 pi")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.customModels.isEmpty {
                Divider().overlay(CodexTheme.divider)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.customModels) { m in
                        modelRow(m)
                    }
                }
            }

            Divider().overlay(CodexTheme.divider)
            addModelForm
        }
        .settingsCard()
    }

    /// 条目行: 显示名 + provider/modelId (+ 覆盖标记) | 启用 | 删除。
    private func modelRow(_ m: CustomModel) -> some View {
        let isCurrent = store.currentProvider == m.provider && store.currentModelId == m.modelId
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.displayName)
                        .font(.system(size: 13))
                        .foregroundStyle(CodexTheme.textPrimary)
                    if overridesCatalog(m) {
                        Text("覆盖目录条目")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CodexTheme.toolRunning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(CodexTheme.toolRunning.opacity(0.12))
                            .cornerRadius(3)
                    }
                }
                Text("\(m.provider) / \(m.modelId)")
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer()
            Button {
                store.selectModel(m.asAgentModelInfo, level: nil)   // 保持当前思考级别
            } label: {
                Text(isCurrent ? "当前" : "启用")
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? CodexTheme.toolDone : CodexTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isCurrent ? CodexTheme.toolDone.opacity(0.12) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isCurrent ? Color.clear : CodexTheme.border, lineWidth: 1)
                    )
                    .cornerRadius(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCurrent)
            .help(isCurrent ? "当前已选中" : "切换到这个模型")

            Button {
                store.removeCustomModel(m)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.vertical, 7)
    }

    /// 添加表单 (常驻; 校验提示贴输入行下方)。
    private var addModelForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("provider", text: $newProvider)
                    .textFieldStyle(.roundedBorder)
                    .font(CodexTheme.fontSmall)
                    .frame(width: 104)
                TextField("model id", text: $newModelId)
                    .textFieldStyle(.roundedBorder)
                    .font(CodexTheme.fontSmall)
                    .frame(minWidth: 90)
                TextField("显示名（可选）", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(CodexTheme.fontSmall)
                    .frame(minWidth: 90)
                Button("添加") { addModel() }
                    .fixedSize()
                    .disabled(!canAddModel)
            }
            Text(addHint)
                .font(.system(size: 11))
                .foregroundStyle(addError != nil ? CodexTheme.toolError : CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canAddModel: Bool {
        !newProvider.trimmingCharacters(in: .whitespaces).isEmpty
        && !newModelId.trimmingCharacters(in: .whitespaces).isEmpty
        && store.isValidProvider(newProvider)
    }

    private var addHint: String {
        if let addError { return addError }
        let p = newProvider.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty, !store.isValidProvider(p) {
            let known = store.validProviders.sorted().joined(separator: "、")
            return "✗ provider 必须在 pi 目录中存在（可用：\(known.isEmpty ? "未知" : known)）"
        }
        let known = store.validProviders.sorted().joined(separator: "、")
        return known.isEmpty
            ? "pi 目录尚未上报，暂不校验 provider；同名条目将覆盖目录条目"
            : "provider 需在 pi 目录中（\(known)）；同名时覆盖目录条目"
    }

    private func addModel() {
        let ok = store.addCustomModel(provider: newProvider, modelId: newModelId, label: newLabel)
        if ok {
            newProvider = ""; newModelId = ""; newLabel = ""; addError = nil
        } else {
            addError = "✗ provider 不在 pi 目录中，或 model id 为空"
        }
    }

    private func overridesCatalog(_ m: CustomModel) -> Bool {
        store.availableModels.contains { $0.provider == m.provider && $0.id == m.modelId }
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
