//
//  MailboxSettings.swift
//  P19 S7: 设置 →「邮箱账号」（**只管"怎么连"**）。
//
//  ⚠️ 本版这一块只有一个消费者: 助理结论的**邮件 sink**（发出去）。
//    收信那条路（IMAP 只读采集）归 P19.1 —— 它要等"不置已读"的实测，本版故意不接。
//    所以这一栏只写"发件要什么": SMTP 主机 + 授权码。
//
//  为什么"测试连接"还测 IMAP: 它就是 `MailTransport.testConnection`（收 + 发两个方向都验），
//  而只验发信会漏掉一类静默失败（实测 2026-09-20: IMAP 全通、SMTP 因 AUTH PLAIN 被拒不报）。
//  这里**不新增**探针，直接复用那一个。
//

import SwiftUI

struct MailboxAccountsSection: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        MailboxAccountBlock(store: store)
    }
}

private struct MailboxAccountBlock: View {
    @ObservedObject var store: ChatStore

    @State private var expanded = false
    @State private var presetId = MailProviderPreset.customId
    @State private var label = ""
    @State private var address = ""
    @State private var imapHost = ""
    @State private var smtpHost = ""
    @State private var authInput = ""
    @State private var formError: String?
    @State private var testing: UUID?
    @State private var testResult: [UUID: String] = [:]

    private var preset: MailProviderPreset {
        MailProviderPreset.allWithCustom.first { $0.id == presetId } ?? MailProviderPreset.custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("邮箱账号")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                Text("助理结论的邮件通知借它发出。授权码存钥匙串, 不落数据库; 第一个能发的账号就是发件人。")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.mailboxAccounts.isEmpty && !expanded {
                Text("尚未配置邮箱。要用邮件通知就在这里加一个 —— 建议专门开一个个人邮箱, 不要用企业邮箱。")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.mailboxAccounts) { account in
                Divider().overlay(CodexTheme.divider)
                accountRow(account)
            }

            if expanded {
                Divider().overlay(CodexTheme.divider)
                form
            }

            HStack(spacing: 8) {
                Button(LK(expanded ? "取消" : "添加邮箱")) {
                    if expanded { reset() } else { expanded = true }
                }
                .fixedSize()
                if let formError {
                    Text(formError)
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.toolError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsCard()
    }

    // MARK: - 行

    @ViewBuilder
    private func accountRow(_ account: MailboxAccount) -> some View {
        let hasAuth = store.hasMailboxAccountAuth(account.id)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text(LK(MailProviderPreset.label(forPresetId: account.presetId)))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(CodexTheme.bgComposer)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .clipShape(Capsule())
                    // 谁在发 —— 邮件没到时的第一句归因
                    if store.firstSendableMailboxAccount()?.id == account.id {
                        Text("发件账号")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(CodexTheme.accentSoft)
                            .foregroundStyle(CodexTheme.accent)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(account.address)
                        .font(CodexFonts.monoFont(11))
                        .foregroundStyle(CodexTheme.textSecondary)
                    Text(LK(hasAuth ? "授权码已设置" : "缺授权码"))
                        .font(.system(size: 10))
                        .foregroundStyle(hasAuth ? CodexTheme.toolDone : CodexTheme.toolError)
                    if !account.smtpHost.isEmpty {
                        // 标签走中文 key、主机名原样拼 —— "SMTP" 单独成句时中文模式下是漏译。
                        Text(String(format: L("发件服务器 %@"), account.smtpHost))
                            .font(.system(size: 10))
                            .foregroundStyle(CodexTheme.textMuted)
                    }
                }
                if let r = testResult[account.id] {
                    // ⚠️ 不用 `LK("✗ \(r)")`: 插值会把 key 变成 `✗ %@`，词表里永远查不到
                    // （禁令三则之一）。先 L() 取词、再 String(format:) 拼。
                    Text(r.isEmpty ? L("✓ 连接正常") : String(format: L("✗ %@"), r))
                        .font(.system(size: 10))
                        .foregroundStyle(r.isEmpty ? CodexTheme.toolDone : CodexTheme.toolError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(LK(testing == account.id ? "测试中…" : "测试连接")) { runTest(account) }
                .fixedSize()
                .disabled(testing != nil)
                .help("连一次 IMAP 并做一次 SMTP 认证（不发信）")
            Button("重设授权码") { resetAuth(account) }
                .fixedSize()
            Button(role: .destructive) { store.removeMailboxAccount(account.id) } label: {
                Text("删除")
            }
            .fixedSize()
            .help("删除该账号并清掉钥匙串里的授权码")
        }
    }

    // MARK: - 表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("服务商")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .frame(width: 64, alignment: .leading)
                Picker("", selection: $presetId) {
                    ForEach(MailProviderPreset.allWithCustom) { p in
                        Text(LK(p.label)).tag(p.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: presetId) { _, _ in fillFromPreset() }
            }
            field(LK("备注名"), text: $label, hint: LK("只在这页显示"))
            field(LK("邮箱地址"), text: $address, hint: LK("发件人与登录用户名都是它"))
            if preset.isCustom {
                field(LK("IMAP 主机"), text: $imapHost, hint: LK("含端口, 如 imap.example.com:993"))
                field(LK("SMTP 主机"), text: $smtpHost, hint: LK("含端口, 如 smtp.example.com:465"))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text("授权码")
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .frame(width: 64, alignment: .leading)
                    SecureField("授权码 / 客户端专用密码", text: $authInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(maxWidth: 260)
                }
                Text(LK(preset.authNote))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 74)
            }
            HStack(spacing: 8) {
                Button(LK("保存账号")) { save() }
                    .fixedSize()
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty
                              || authInput.isEmpty)
                if let url = preset.helpURL, let u = URL(string: url) {
                    Button(LK("服务商帮助")) { NSWorkspace.shared.open(u) }
                        .fixedSize()
                }
            }
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>,
                       hint: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textSecondary)
                .frame(width: 64, alignment: .leading)
            TextField(hint, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: 260)
        }
    }

    // MARK: - 动作

    private func fillFromPreset() {
        imapHost = preset.imapHost
        smtpHost = preset.smtpHost
    }

    private func reset() {
        expanded = false
        presetId = MailProviderPreset.customId
        label = ""
        address = ""
        imapHost = ""
        smtpHost = ""
        authInput = ""
        formError = nil
    }

    private func save() {
        formError = nil
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addr.contains("@") else {
            formError = L("邮箱地址不像一个地址")
            return
        }
        let p = preset
        let account = MailboxAccount(
            label: label.trimmingCharacters(in: .whitespaces).isEmpty ? addr : label.trimmingCharacters(in: .whitespaces),
            address: addr,
            presetId: p.id,
            imapHost: p.isCustom ? imapHost.trimmingCharacters(in: .whitespaces) : p.imapHost,
            smtpHost: p.isCustom ? smtpHost.trimmingCharacters(in: .whitespaces) : p.smtpHost)
        guard !account.smtpHost.isEmpty else {
            formError = L("缺 SMTP 主机 —— 没有它发不了信（选了自定义就要手填）")
            return
        }
        store.addMailboxAccount(account)
        // 凭据写钥匙串。**写失败要说出来** —— 静默失败的表现是"配置好了, 但邮件从不发出"。
        store.setMailboxAuth(authInput, accountId: account.id)
        guard store.hasMailboxAccountAuth(account.id) else {
            formError = L("账号已存, 但授权码没能写进钥匙串 —— 邮件会发不出去, 请重设一次")
            return
        }
        reset()
    }

    /// 重设授权码：就地弹一次输入。**不回显旧值**（凭据一律只写不读，同飞书 secret 那条规矩）。
    private func resetAuth(_ account: MailboxAccount) {
        let alert = NSAlert()
        alert.messageText = String(format: L("重设「%@」的授权码"), account.address)
        alert.informativeText = L("授权码住钥匙串, 不落数据库。留空保存 = 清除。")
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = f
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.setMailboxAuth(f.stringValue.isEmpty ? nil : f.stringValue, accountId: account.id)
        testResult[account.id] = nil
    }

    private func runTest(_ account: MailboxAccount) {
        testing = account.id
        testResult[account.id] = nil
        let auth = store.mailboxAuth(account.id)
        Task { @MainActor in
            let t = CurlMailTransport(account: account, auth: auth)
            let result = await t.testConnection()
            testResult[account.id] = result ?? ""
            testing = nil
        }
    }
}
