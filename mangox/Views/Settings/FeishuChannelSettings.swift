//
//  FeishuChannelSettings.swift
//  P19.2 S15: 设置 →「集成」→ 飞书对话通道。
//
//  这一栏只管**通道本身**（身份 + 开关 + 现在通不通 + 谁来找过我）。
//  「这个单聊归哪个助理」不在这里 —— 它属于助理，见 `ScheduledView.remoteCard`。
//  分开的理由：凭据是**一台机器一份**，绑定是**一个助理一条**，两个作用域不同，
//  塞进同一页会让"我改的是这台机器还是这个助理"变得说不清。
//

import SwiftUI

struct FeishuChannelSection: View {
    @ObservedObject var remote: RemoteChannelService
    @ObservedObject var store: ChatStore

    @State private var appIdInput = ""
    @State private var secretInput = ""
    @State private var stored = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("飞书对话")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                // ⚠️ 一句话写一个**字面量**。写成 `"a" + "b"` 时 `Text` 会挑 `init(String)` 那个
                // 重载 ⇒ 整句不进词表、英文界面下原样显示中文（本地化门禁只看字面量，看不出来）。
                Text("在飞书的单聊里直接跟助理说话。用得着自建应用的 app_id / app_secret, 两个都存钥匙串。MangoX 关掉通道就断 —— 它不是服务端。")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(CodexTheme.divider)

            // 凭据：**永不回显**（同 S7 的 webhook）。已保存只显示"已保存"。
            HStack(spacing: 8) {
                Text("app_id")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .frame(width: 76, alignment: .leading)
                if stored {
                    Text("已保存 —— 要换就整条重填")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                    Spacer()
                    Button(LK("换一个")) { clearStored() }
                        .fixedSize()
                } else {
                    TextField("cli_…", text: $appIdInput)
                        .textFieldStyle(.plain)
                        .font(CodexTheme.fontSmall)
                        .frame(maxWidth: 320)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Text("app_secret")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .frame(width: 76, alignment: .leading)
                if stored {
                    Text("已保存")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                    Spacer()
                } else {
                    SecureField("自建应用的 App Secret", text: $secretInput)
                        .textFieldStyle(.plain)
                        .font(CodexTheme.fontSmall)
                        .frame(maxWidth: 320)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                if !stored {
                    Button(LK("保存凭据")) { saveCredentials() }
                        .fixedSize()
                }
                Toggle(isOn: Binding(get: { remote.isEnabled },
                                     set: { remote.setEnabled($0) })) {
                    Text("启用飞书对话")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textPrimary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                if remote.isEnabled {
                    Button(LK("重连")) { remote.restart() }
                        .fixedSize()
                }
                Spacer()
            }

            // 状态。**文案不写"已连接"这种绝对话** —— 桥给的 connected 是"启动后 2 秒没崩"，
            // 不是 TCP 握手成功（SDK 不回调连接状态）。说得太满，断线时人会先怀疑自己。
            HStack(spacing: 6) {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 6, height: 6)
                Text(remote.phase.text)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textSecondary)
                if let at = remote.lastEventAt {
                    Text("· " + L("最近一条") + " " + timeFormatter.string(from: at))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
                Spacer()
            }
            if let note = remote.lastNote, !note.isEmpty {
                Text(note)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.toolError)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !remote.pendingChats.isEmpty {
                Divider().overlay(CodexTheme.divider)
                Text("来找过机器人的单聊")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                ForEach(remote.pendingChats) { chat in
                    HStack(spacing: 8) {
                        Text(chat.shortChat)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CodexTheme.textPrimary)
                        Text(chat.shortSender)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CodexTheme.textMuted)
                        Text(chat.lastText)
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .lineLimit(1)
                        Spacer()
                        if let name = boundAssistantName(chat.chatId) {
                            Text(String(format: L("已绑：%@"), name))
                                .font(CodexTheme.fontTiny)
                                .foregroundStyle(CodexTheme.toolDone)
                        } else {
                            Text("未绑定")
                                .font(CodexTheme.fontTiny)
                                .foregroundStyle(CodexTheme.blocked)
                        }
                    }
                }
                Text("绑定在「定时/助理」里选 —— 打开那个助理，入口那一栏挑这个单聊。飞书没有「列出我的单聊」的接口，所以这个列表只会出现在这儿跟你说过话的会话。")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsCard()
        .onAppear(perform: refreshStored)
    }

    private var phaseColor: Color {
        switch remote.phase {
        case .up: return CodexTheme.toolDone
        case .connecting: return CodexTheme.blocked
        case .failed: return CodexTheme.toolError
        case .off: return CodexTheme.textMuted
        }
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }

    private func boundAssistantName(_ chatId: String) -> String? {
        store.scheduledTasks.first { $0.remoteChatId == chatId }?.name
    }

    private func refreshStored() {
        stored = (KeychainRemoteSecretStore.current.appSecret()?.isEmpty == false)
    }

    private func saveCredentials() {
        error = nil
        let id = appIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else {
            error = L("两个都要填 —— 只填一个换不到 token")
            return
        }
        do {
            try KeychainRemoteSecretStore.current.set(appId: id, appSecret: secret)
            appIdInput = ""
            secretInput = ""
            refreshStored()
            // 存完立刻按新凭据重连一次：不重启的话界面会显示"开着"而用的是旧身份
            // （同 P19 那条"连接实例缓存必须随配置失效"）。
            if remote.isEnabled { remote.restart() }
        } catch {
            self.error = String(format: L("存钥匙串失败：%@"), error.localizedDescription)
        }
    }

    private func clearStored() {
        try? KeychainRemoteSecretStore.current.set(appId: nil, appSecret: nil)
        stored = false
        remote.stop()
        if remote.isEnabled { remote.start() }
    }
}
