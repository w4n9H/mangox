//
//  FeishuChannelSettings.swift
//  P19.2 S15b: 设置 →「集成」→ 飞书机器人。
//
//  这一页管**机器人**（一群身份）: 新增 / 改名 / 换凭据 / 开关 / 删除 / 现在通不通。
//  「它归哪个助理」不在这里 —— 那是助理的属性，在「定时/助理」那边勾（见 `ScheduledView`）。
//  分开的理由和上一版一样: 凭据是**一台机器 N 份**，归属是**一个助理一条**，作用域不同；
//  塞进同一页会让"我改的是这台机器还是这个助理"说不清。
//
//  ── 三个界面上的诚实条款 ────────────────────────────────────────────────────
//  ① **灯是桥报的握手结果**，不是"启动后 N 秒没崩"。凭证填错时它会当场变红并写明原因
//     （`app_id or app_secret is invalid`）—— 这是 S15b 顺手修掉的一个谎。
//  ② **secret 永不回显**。已保存只显示"已保存"；要换就整条重填。
//  ③ **连接不跟助理开关走**。助理停用时机器人照旧连着 —— 因为飞书那边一旦没有活着的
//     长连接，人**根本发不出消息**（输入框变灰）。这条写在文字里，否则人会以为断连是 bug。
//

import SwiftUI

struct FeishuChannelSection: View {
    @ObservedObject var remote: RemoteChannelService
    @ObservedObject var store: ChatStore

    /// 正在编辑的表单。`id == nil` = 新增。
    struct BotForm: Equatable {
        var id: UUID?
        var name: String = ""
        var appId: String = ""
        var secret: String = ""
    }

    @State private var form: BotForm?
    @State private var confirmDelete: UUID?
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(CodexTheme.divider)
            if store.remoteBots.isEmpty && form == nil {
                Text("还没有机器人。飞书自建应用就是你跟助理说话的那个「账号」 —— 一个机器人只归一个助理。")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.remoteBots) { bot in
                if form?.id == bot.id {
                    botForm
                } else {
                    botRow(bot)
                }
            }
            if form != nil && form?.id == nil { botForm }
            addRow
            if let error {
                Text(error)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.toolError)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice {
                Text(notice)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.toolDone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            recentChats
        }
        .settingsCard()
    }

    // MARK: - 头

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("飞书机器人")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                Spacer()
                Circle().fill(phaseColor(remote.phase)).frame(width: 6, height: 6)
                Text(remote.phase.text)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textSecondary)
            }
            // ⚠️ 一句话写一个**字面量**。写成 `"a" + "b"` 时 `Text` 会挑 `init(String)` 那个
            // 重载 ⇒ 整句不进词表、英文界面下原样显示中文（本地化门禁只看字面量，看不出来）。
            Text("在飞书的单聊里直接跟助理说话。每个机器人是一个飞书自建应用，凭据存钥匙串；一个机器人只归一个助理。机器人没有自己的开关 —— 它连不连，跟那条助理的开关走（助理关着它就不连，MangoX 关掉也断）。")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 一行机器人

    private func botRow(_ bot: RemoteBot) -> some View {
        let phase = remote.phase(for: bot.id)
        let assistant = store.scheduledTasks.first { $0.id == bot.assistantId }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(phaseColor(phase)).frame(width: 6, height: 6)
                Text(bot.displayName)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textPrimary)
                Text(bot.maskedAppId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                Button(LK("编辑")) { startEdit(bot) }
                    .font(CodexTheme.fontTiny)
                    .buttonStyle(.plain)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .fixedSize()
                Button(confirmDelete == bot.id ? LK("确认删除") : LK("删除")) {
                    deleteBot(bot)
                }
                .font(CodexTheme.fontTiny)
                .buttonStyle(.plain)
                .foregroundStyle(confirmDelete == bot.id ? CodexTheme.toolError : CodexTheme.textMuted)
                .fixedSize()
            }

            HStack(spacing: 6) {
                if let assistant {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(CodexTheme.textMuted)
                    Text(String(format: L("归：%@"), assistant.name))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textSecondary)
                } else {
                    Text("还没归助理 —— 收到的话会回一句「先归给一个助理」")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.blocked)
                }
                Spacer()
                if let at = bot.lastChatAt {
                    Text(String(format: L("上次说话 %@"), shortTime(at)))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
            }

            if !bot.hasAppId {
                // 旧版配置迁上来时 app_id 是空的（迁移**不读钥匙串** —— 那会在启动线程上弹框）。
                HStack(spacing: 8) {
                    Text("缺 app_id（从 S15 的旧配置迁过来的）")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.blocked)
                    Button(LK("从旧版读取")) { importLegacy(into: bot) }
                        .font(CodexTheme.fontTiny)
                        .buttonStyle(.plain)
                        .foregroundStyle(CodexTheme.accent)
                        .fixedSize()
                    Spacer()
                }
            }
            if case .failed(let why) = phase, !why.isEmpty {
                Text(why)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.toolError)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note = remote.botNote[bot.id], !note.isEmpty {
                Text(note)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 表单

    private var botForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("名字")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .frame(width: 72, alignment: .leading)
                TextField(L("例：工作号"), text: binding(\.name))
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .frame(maxWidth: 260)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("app_id")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .frame(width: 72, alignment: .leading)
                TextField("cli_…", text: binding(\.appId))
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .frame(maxWidth: 260)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("app_secret")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .frame(width: 72, alignment: .leading)
                SecureField(secretPlaceholder, text: binding(\.secret))
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .frame(maxWidth: 260)
                Spacer()
            }
            HStack(spacing: 8) {
                Button(LK("保存")) { saveForm() }
                    .fixedSize()
                Button(LK("取消")) { form = nil; error = nil }
                    .fixedSize()
                Spacer()
            }
            Text("凭据只进钥匙串，不进库、不写日志。填完保存后桥会按新清单整条重起（几秒钟）。")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
    }

    private var secretPlaceholder: String {
        guard let id = form?.id, remote.hasSecret(for: id) else { return L("自建应用的 App Secret") }
        return L("已保存 —— 留空就不改")
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Button {
                error = nil
                notice = nil
                form = BotForm()
            } label: {
                Label(L("新增机器人"), systemImage: "plus")
                    .font(CodexTheme.fontSmall)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CodexTheme.accent)
            .fixedSize()
            Spacer()
            if remote.phase != .off {
                Button(LK("重连")) { remote.restart() }
                    .font(CodexTheme.fontTiny)
                    .buttonStyle(.plain)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .fixedSize()
            }
        }
    }

    // MARK: - 最近找过机器人的会话（诊断）

    private var recentChats: some View {
        Group {
            if !remote.pendingChats.isEmpty {
                Divider().overlay(CodexTheme.divider)
                Text("最近来找过机器人的会话")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                ForEach(remote.pendingChats) { chat in
                    HStack(spacing: 8) {
                        Text(botName(chat.botId))
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textSecondary)
                            .frame(width: 72, alignment: .leading)
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
                    }
                }
                Text("这张表只是**诊断** —— 它证明连接真的通了、谁跟哪个机器人说过话。绑定不在这里做：去「定时/助理」里选一个机器人（一个助理只挂一个）。")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 动作

    private func startEdit(_ bot: RemoteBot) {
        error = nil
        notice = nil
        confirmDelete = nil   // 上一行按过一次「删除」不该让它一直亮着
        form = BotForm(id: bot.id, name: bot.name, appId: bot.appId, secret: "")
    }

    private func saveForm() {
        guard let f = form else { return }
        error = nil
        notice = nil
        let name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let appId = f.appId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = f.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appId.isEmpty else {
            error = L("app_id 要填 —— 它在飞书自建应用的「凭证与基础信息」里")
            return
        }
        if let id = f.id, var bot = store.remoteBots.first(where: { $0.id == id }) {
            bot.name = name
            bot.appId = appId
            // 顺序有意: 先落 secret 再写行。两者都会触发 `syncBots`，而签名里含 secret 哈希
            // ⇒ 重连只发生一次（在最后一次 syncBots 上）。
            if !secret.isEmpty, !store.setRemoteBotSecret(secret, for: id) { return }
            store.updateRemoteBot(bot)
        } else {
            let bot = RemoteBot(id: UUID(), name: name, appId: appId)
            store.addRemoteBot(bot)
            if !secret.isEmpty { guard store.setRemoteBotSecret(secret, for: bot.id) else { return } }
            if secret.isEmpty { notice = L("还没填 app_secret —— 它连不上，补上就自动连") }
        }
        form = nil
    }

    private func deleteBot(_ bot: RemoteBot) {
        guard confirmDelete == bot.id else {
            confirmDelete = bot.id
            return
        }
        confirmDelete = nil
        store.removeRemoteBot(bot.id)
    }

    /// 把 S15 的旧凭据搬进这个机器人。**按钮按下去才读钥匙串** —— 那一下可能弹授权框，
    /// 而弹框必须是预期内的（渲染路径上读钥匙串 = 每帧都可能卡住）。
    private func importLegacy(into bot: RemoteBot) {
        error = nil
        notice = nil
        guard let legacy = LegacyFeishuCredential.read() else {
            error = L("旧版里也没读到凭据 —— 那就手填一次 app_id / app_secret")
            return
        }
        var copy = bot
        copy.appId = legacy.appId
        store.updateRemoteBot(copy)
        guard store.setRemoteBotSecret(legacy.secret, for: bot.id) else { return }
        notice = L("已从旧版搬过来 —— 桥会按新凭据重连")
    }

    // MARK: - 小件

    private func binding(_ key: WritableKeyPath<BotForm, String>) -> Binding<String> {
        Binding(get: { form?[keyPath: key] ?? "" },
                set: { if form != nil { form![keyPath: key] = $0 } })
    }

    private func botName(_ botId: String?) -> String {
        guard let botId, let id = UUID(uuidString: botId) else { return L("旧版") }
        return store.remoteBots.first { $0.id == id }?.displayName ?? L("已删除")
    }

    private func phaseColor(_ p: RemoteChannelService.Phase) -> Color {
        switch p {
        case .up: return CodexTheme.toolDone
        case .connecting: return CodexTheme.blocked
        case .failed: return CodexTheme.toolError
        case .off: return CodexTheme.textMuted
        }
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}
