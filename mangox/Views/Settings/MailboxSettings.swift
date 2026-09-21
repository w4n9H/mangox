//
//  MailboxSettings.swift
//  P10.2d/e: Settings「邮箱账号」块 —— 账号池只管"怎么连" (host / 地址 / 授权码 / 测试连接)。
//  P10.2e 归位: agent (策略) 与最近拒收已搬到「Scheduled」页, 与 Cron/Watch/Inbox 三类任务并列;
//  这里只留连接与凭据配置 (决定 10 原话: Settings 增加的是"邮箱配置能力")。
//  域逻辑全在 MailboxSentinelService; 本文件只做表单与回显。共用小件见 MailboxUI.swift。
//

import SwiftUI

/// 邮箱账号池 (SettingsView 只插入这一行)。
struct MailboxAccountsSection: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MailboxAccountBlock(store: store)
        }
    }
}

// MARK: - 账号池 (决定 10: 只管"怎么连")

private struct MailboxAccountBlock: View {
    @ObservedObject var store: ChatStore

    @State private var editing: UUID?          // 展开编辑的账号 (nil = 新增或收起)
    @State private var expanded = false
    @State private var draft = MailboxAccount(label: "", address: "")
    @State private var presetId = MailProviderPreset.customId
    @State private var authInput = ""
    @State private var formError: String?
    @State private var testing: UUID?          // 正在测连接的账号
    @State private var testResult: [UUID: String] = [:]   // [成功存 ""; 失败存文案]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsBlockHeader(title: "邮箱账号",
                                detail: "Inbox 类型的 agent 借它收信与发回执 (agent 本身在「Scheduled」页创建)。授权码存 Keychain, 不落数据库")
            if store.mailboxAccounts.isEmpty && !expanded {
                Text("尚未配置邮箱。点下方「添加邮箱」开始 —— 建议用一个专用个人邮箱, 不要用企业邮箱。")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
            }
            ForEach(store.mailboxAccounts) { account in
                Divider().overlay(CodexTheme.divider)
                accountRow(account)
            }
            if expanded {
                Divider().overlay(CodexTheme.divider)
                accountForm
            }
            HStack(spacing: 8) {
                Button(LK(expanded ? "取消" : "添加邮箱")) {
                    if expanded { resetForm() } else { startAdd() }
                }
                .fixedSize()
                if let formError, expanded {
                    Text(formError).font(.system(size: 11)).foregroundStyle(CodexTheme.toolError)
                }
            }
        }
        .settingsCard()
    }

    // MARK: 行

    @ViewBuilder
    private func accountRow(_ account: MailboxAccount) -> some View {
        let bound = store.sentinelBoundToken(accountId: account.id)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.label).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CodexTheme.textPrimary)
                    mboxBadge(LK(MailProviderPreset.label(forPresetId: account.presetId)), color: CodexTheme.textSecondary)
                    if bound != nil {
                        mboxBadge("已绑定", color: CodexTheme.accent)
                    }
                }
                HStack(spacing: 6) {
                    Text(account.address).font(CodexFonts.monoFont(11))
                        .foregroundStyle(CodexTheme.textSecondary)
                    Text(LK(store.hasMailboxAccountAuth(accountId: account.id) ? "授权码已设置" : "缺授权码"))
                        .font(.system(size: 10))
                        .foregroundStyle(store.hasMailboxAccountAuth(accountId: account.id)
                                         ? CodexTheme.toolDone : CodexTheme.toolError)
                }
                if let result = testResult[account.id] {
                    Text(LK(result.isEmpty ? "✓ 连接正常 (IMAP 登录 + 列 INBOX)" : "✗ \(result)"))
                        .font(.system(size: 10))
                        .foregroundStyle(result.isEmpty ? CodexTheme.toolDone : CodexTheme.toolError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(LK(testing == account.id ? "测试中…" : "测试连接")) { runTest(account) }
                .fixedSize()
                .disabled(testing != nil)
            Button("编辑") { startEdit(account) }.fixedSize()
            Button(role: .destructive) { store.removeMailboxAccount(account.id) } label: {
                Text("删除")
            }
            .fixedSize()
            .disabled(bound != nil)
            .help(bound.map { String(format: L("先删除 Inbox agent「%@」"), $0.name) } ?? L("删除该账号 (含 Keychain 授权码)"))
        }
    }

    // MARK: 表单

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("服务商").font(.system(size: 11)).foregroundStyle(CodexTheme.textSecondary)
                    .frame(width: 64, alignment: .leading)
                Picker("", selection: $presetId) {
                    ForEach(MailProviderPreset.allWithCustom) { p in Text(p.label).tag(p.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: presetId) { _, _ in applyPreset() }
                Spacer()
            }
            field("名字", text: $draft.label, hint: "如 家里那台 / 任务专用")
            field("邮箱地址", text: $draft.address, hint: "完整地址, 如 you@example.com")
                .help("该账号登录的邮箱本人: MangoX 从它收信, 也以它的名义发回执。它不是收件人过滤 —— 「谁能驱动 agent」在 Inbox 的「发件人白名单」里配。")
                .onChange(of: draft.address) { _, _ in autoMatchPreset() }
            field("IMAP 主机", text: $draft.imapHost, hint: "含端口, 如 imap.163.com:993")
            field("SMTP 主机", text: $draft.smtpHost, hint: "含端口, 如 smtp.163.com:465")
            HStack(spacing: 10) {
                Text("授权码").font(.system(size: 11)).foregroundStyle(CodexTheme.textSecondary)
                    .frame(width: 64, alignment: .leading)
                SecureField(LK(store.hasMailboxAccountAuth(accountId: draft.id) ? "已设置 (留空不修改)" : "授权码 / 客户端专用密码"),
                            text: $authInput)
                    .textFieldStyle(.roundedBorder)
                    .font(CodexFonts.monoFont(12))
            }
            if let note = MailProviderPreset.preset(id: presetId) {
                HStack(alignment: .top, spacing: 4) {
                    Text(note.authNote)
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = note.helpURL, let link = URL(string: url) {
                        Link("帮助", destination: link).font(.system(size: 11)).fixedSize()
                    }
                }
            }
            HStack(spacing: 8) {
                Button(LK(editing == nil ? "保存" : "保存修改"), action: save)
                    .fixedSize()
                if editing != nil {
                    Text("改动会重置该账号的连接实例 (下次收信生效)")
                        .font(.system(size: 10)).foregroundStyle(CodexTheme.textMuted)
                }
            }
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, hint: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundStyle(CodexTheme.textSecondary)
                .frame(width: 64, alignment: .leading)
            TextField(hint, text: text)
                .textFieldStyle(.roundedBorder)
                .font(CodexFonts.monoFont(12))
        }
    }

    // MARK: 动作

    private func startAdd() {
        editing = nil
        draft = MailboxAccount(label: "", address: "")
        presetId = MailProviderPreset.customId
        authInput = ""
        formError = nil
        expanded = true
    }

    private func startEdit(_ account: MailboxAccount) {
        editing = account.id
        draft = account
        presetId = account.presetId ?? MailProviderPreset.customId
        authInput = ""
        formError = nil
        expanded = true
    }

    private func resetForm() {
        expanded = false
        editing = nil
        authInput = ""
        formError = nil
    }

    private func applyPreset() {
        guard let preset = MailProviderPreset.preset(id: presetId) else { return }
        draft = MailProviderPreset.apply(preset, to: draft)
    }

    /// 只在用户还没选过预设时按域名自动匹配 (选了自定义就尊重手填)。
    private func autoMatchPreset() {
        guard presetId == MailProviderPreset.customId,
              let matched = MailProviderPreset.matching(address: draft.address) else { return }
        presetId = matched.id
        applyPreset()
    }

    private func save() {
        var account = draft
        account.label = account.label.trimmingCharacters(in: .whitespaces)
        account.address = account.address.trimmingCharacters(in: .whitespaces)
        account.imapHost = account.imapHost.trimmingCharacters(in: .whitespaces)
        account.smtpHost = account.smtpHost.trimmingCharacters(in: .whitespaces)
        if account.label.isEmpty { account.label = account.address }
        guard account.address.contains("@") else { formError = L("请填有效的邮箱地址"); return }
        guard !account.imapHost.isEmpty, !account.smtpHost.isEmpty else {
            formError = L("IMAP / SMTP 主机不能为空 (含端口)"); return
        }
        if editing == nil { store.addMailboxAccount(account) } else { store.updateMailboxAccount(account) }
        let auth = authInput.trimmingCharacters(in: .whitespaces)
        if !auth.isEmpty { store.setMailboxAccountAuth(auth, accountId: account.id) }
        testResult[account.id] = nil
        resetForm()
    }

    private func runTest(_ account: MailboxAccount) {
        testing = account.id
        Task {
            let error = await store.testMailboxConnection(accountId: account.id)
            testResult[account.id] = error ?? ""
            testing = nil
        }
    }
}

// MARK: - 共用小件

private struct SettingsBlockHeader: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            Text(detail).font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
