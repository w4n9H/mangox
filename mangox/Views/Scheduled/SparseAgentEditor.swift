//
//  SparseAgentEditor.swift
//  P10.2e: Inbox 编辑器 —— 从 Settings 搬到 Scheduled 页右侧编辑区。
//  定位: 与「Cron」(时间) 「Watch」(条件) 并列的第三种触发源 —— 来信驱动的无人值守 agent
//  (收信 → 过四道闸 → fire 一个真 session)。账号池仍留在 Settings (决定 10)。
//  视觉语言与 ScheduledView 编辑区一致 (大标题输入 + pill 行 + bgElevated 卡片)。
//

import SwiftUI

struct SparseAgentEditor: View {
    @ObservedObject var store: ChatStore
    /// nil = 新建草稿
    let sentinelId: UUID?
    /// 保存成功后把编辑目标切到该 agent (新建 → 拿到落地 id)
    var onSaved: (UUID) -> Void
    /// 删除后回到新建态
    var onDeleted: () -> Void

    @State private var draft = MailboxSentinel(name: "", accountId: UUID())
    @State private var accountId: UUID?
    @State private var projectId: UUID?
    @State private var whitelistText = ""
    @State private var secretInput = ""
    @State private var formError: String?
    @State private var loaded = false
    @State private var showDeleteConfirm = false
    @State private var savedFlash = false

    /// 空闲账号 (编辑既有 agent 时把自己占的那个保留在可选里)。
    private var available: [MailboxAccount] { store.availableMailboxAccounts(forSentinel: effectiveExistingId) }
    /// 编辑既有 agent 的 id (新建草稿为 nil)。
    private var effectiveExistingId: UUID? { sentinelId }
    /// 只有带工作目录的项目能绑定 —— agent 要拿它当 pi 的 cwd。
    private var bindableProjects: [ProjectGroup] {
        store.projects.filter { !($0.path ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 名称非空 = 创建/保存按钮可点 (唯一硬前置; 其余缺项点了会给红字理由)。
    private var nameFilled: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 白名单文本 → 地址数组 (保存与"还差什么"共用同一份解析, 免得两处判据漂移)。
    private var parsedWhitelist: [String] {
        whitelistText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 尚未填齐的必填项 (按钮被锁/将报错时显示在按钮旁)。
    private var missingRequired: String? {
        if !nameFilled { return "名称" }
        if accountId == nil { return "邮箱" }
        if parsedWhitelist.isEmpty { return "发件人白名单" }
        return nil
    }

    var body: some View {
        Group {
            if effectiveExistingId == nil && available.isEmpty {
                noAccountHint
            } else {
                editor
            }
        }
        .onAppear(perform: loadOnce)
    }

    private var noAccountHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有可用的邮箱账号")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            Text("Inbox 借邮箱账号收信与发回执。先去「设置 › 邮箱账号」添加一个 (个人邮箱 + 授权码), 再回来创建。")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 主体

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlsRow
            TextField("Inbox 名称 (必填)", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: Tune.knowledgeTitleFontSize, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            rulesCard
            deliveryCard
            if let id = effectiveExistingId { rejectionCard(sentinelId: id) }
        }
        .confirmationDialog("删除「\(draft.name)」？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除这个 agent", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("连带删除它的邮件线程映射与拒收日志; 已产生的会话保留。")
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            accountMenu
            projectMenu
            enabledToggle
            Spacer()
            if effectiveExistingId != nil {
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 10))
                        Text("删除")
                    }
                }
                .buttonStyle(CodexActionButtonStyle(kind: .danger))
            }
            // 按钮被锁时必须在旁边直说缺什么 —— 否则用户只看到「点不动」(2026-09-20 实机反馈)。
            if let formError {
                Text(formError)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.toolError)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let missingRequired {
                Text("还差: \(missingRequired)")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.toolRunning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(savedFlash ? "✓ 已保存" : (effectiveExistingId == nil ? "创建" : "保存")) { save() }
                .buttonStyle(CodexActionButtonStyle(kind: savedFlash ? .success : .primary,
                                                    disabled: !nameFilled))
                .disabled(savedFlash || !nameFilled)
                .help(nameFilled ? (effectiveExistingId == nil ? "创建这个 Inbox" : "保存")
                                 : "请先填名称 (编辑器顶部那个大字输入框)")
        }
    }

    private var accountMenu: some View {
        CodexPillMenu {
            menuItem("请选择", selected: accountId == nil) { accountId = nil }
            ForEach(available) { a in
                menuItem(accountTitle(a), selected: accountId == a.id) { accountId = a.id }
            }
        } label: {
            Image(systemName: "tray.full").font(.system(size: 10))
            Text(selectedAccount.map { $0.label.isEmpty ? $0.address : $0.label } ?? "选择邮箱")
        }
        .disabled(effectiveExistingId != nil)   // 绑定后不可改 (1:1, 改绑请重建)
        .help(effectiveExistingId != nil ? "邮箱绑定后不可修改 (一个邮箱只服务一个 Inbox)" : "选择收信用的邮箱账号")
    }

    private var projectMenu: some View {
        CodexPillMenu {
            menuItem("无项目 (回落 home)", selected: projectId == nil) { projectId = nil }
            ForEach(bindableProjects) { p in
                menuItem(p.title, selected: projectId == p.id) { projectId = p.id }
            }
        } label: {
            Image(systemName: "folder").font(.system(size: 10))
            Text(selectedProject.map { "→ \($0.title)" } ?? "→ 回落 home")
        }
        .help("agent 在这个目录里干活; 选「无项目」时按 home 执行 (请看管好白名单)")
    }

    private func accountTitle(_ a: MailboxAccount) -> String {
        a.label.isEmpty ? a.address : "\(a.label) · \(a.address)"
    }

    /// 胶囊菜单里的单选条目 (✓ 前缀 = 当前选中, 与 ChatComposer 模型菜单同款)。
    /// 必须用 Button —— 见 CodexPillMenu 上方的约束说明。
    private func menuItem(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(selected ? "✓ \(title)" : title) }
    }

    private var enabledToggle: some View {
        HStack(spacing: 5) {
            CodexMiniToggle(isOn: Binding(get: { draft.enabled }, set: { draft.enabled = $0 }))
            Text(draft.enabled ? "启用" : "停用")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(draft.enabled ? CodexTheme.textPrimary : CodexTheme.textTertiary)
        }
        .help("停用后不再收信 (绑定关系保留)")
    }

    private var selectedAccount: MailboxAccount? {
        store.mailboxAccounts.first { $0.id == accountId }
    }

    private var selectedProject: ProjectGroup? {
        store.projects.first { $0.id == projectId }
    }

    // MARK: - 规则卡 (白名单 / 轮询 / 密钥闸 / 高级)

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("发件人白名单", hint: "一行一个地址; 名单外的信静默丢弃并移入 Trash") {
                VStack(alignment: .leading, spacing: 2) {
                    TextEditor(text: $whitelistText)
                        .font(CodexFonts.monoFont(12))
                        .frame(height: 56)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(CodexTheme.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            field("轮询间隔", hint: "多久看一次收件箱 (全局串行: 同一时刻只跑一个远程任务)") {
                Stepper(value: $draft.pollInterval, in: 15...300, step: 15) {
                    Text("\(draft.pollInterval) 秒")
                        .font(CodexFonts.monoFont(12))
                        .foregroundStyle(CodexTheme.accent)
                }
                .fixedSize()
            }
            field("密钥闸", hint: "首封主题里必须带这串密钥 (清洗剥掉后不落库)") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $draft.requireSecret) { Text("要求密钥") }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .fixedSize()
                    if draft.requireSecret {
                        SecureField(store.hasMailboxSentinelSecret(sentinelId: draft.id)
                                    ? "已设置 (留空不修改)" : "共享密钥", text: $secretInput)
                            .textFieldStyle(.roundedBorder)
                            .font(CodexFonts.monoFont(12))
                            .frame(maxWidth: 260)
                    }
                }
            }
            if !draft.requireSecret {
                Text("⚠️ 关掉密钥闸后只剩白名单 + 服务商过滤, 建议名单内各域都已配 DMARC")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.toolRunning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field("高级", hint: "工具面与危险命令裁决 (无人值守路径没有审批 UI)") {
                HStack(spacing: 12) {
                    Picker("", selection: $draft.agentMode) {
                        ForEach(AgentMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()

                    Picker("", selection: $draft.approval) {
                        ForEach(ApprovalMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    .help(draft.approval.subtitle)
                }
            }
            field("探测地址", hint: "可选: 执行前先探这个 URL, 不通则不跑 (空 = 不探)") {
                TextField("https://…", text: $draft.intranetProbeURL)
                    .textFieldStyle(.roundedBorder)
                    .font(CodexFonts.monoFont(11))
            }
            if effectiveExistingId != nil {
                Text("改配置不影响已建线程 —— 它们吃首封快照 (项目目录也随之固定)。")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 运行态卡 (全局串行 + 该 agent 的收信状态)

    private var deliveryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text("运行状态")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
            }
            Text(globalStatusLine)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let existing = effectiveExistingId.flatMap({ id in store.mailboxSentinels.first { $0.id == id } }) {
                HStack(spacing: 10) {
                    Text(existing.lastPollAt.map { "上次收信 \(relativeTime($0))" } ?? "尚未收信")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                    Text("白名单 \(existing.whitelist.count) 条")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                }
                if let error = existing.lastError, !error.isEmpty {
                    Text("✗ \(error)")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.toolError)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 服务层的诊断提示 (回执发送失败 / 账号不可用 / 项目目录不存在 …) —— 原先 `setNotice`
                // 写了却没人读, 「回执没发出去」这类失败完全静默 (2026-09-20 联调实锤: 任务跑了、会话建了、
                // 回执没到, 界面一片正常)。注意它是**全局**一条, 不按哨兵分账 (与全局串行队列同粒度)。
                if let notice = store.mailboxNotice, !notice.isEmpty {
                    Text("✗ \(notice)")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.toolError)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var globalStatusLine: String {
        var parts: [String] = ["全局串行 (同一时刻只跑一个远程任务)"]
        parts.append("排队 \(store.mailboxQueuedTaskCount) 个")
        if let running = store.mailboxRunningTask {
            parts.append("在途: \(running.title)")
        } else {
            parts.append("串行位空闲")
        }
        if let last = store.mailboxLastPollAt { parts.append("最近收信 \(relativeTime(last))") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 最近拒收 (排查「发了信为什么没执行」)

    private func rejectionCard(sentinelId: UUID) -> some View {
        let rows = Array(store.mailboxRejections(sentinelId: sentinelId).prefix(20))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.toolError)
                Text("最近拒收")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer()
                Text("最多留 200 条")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            if rows.isEmpty {
                Text("暂无拒收记录。")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            ForEach(rows) { rejection in
                Divider().overlay(CodexTheme.divider)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(rejection.reason.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(CodexTheme.toolError)
                            Text(shortTime(rejection.at))
                                .font(.system(size: 10))
                                .foregroundStyle(CodexTheme.textMuted)
                        }
                        Text(rejection.sender)
                            .font(CodexFonts.monoFont(11))
                            .foregroundStyle(CodexTheme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(rejection.subject)
                            .font(.system(size: 11))
                            .foregroundStyle(CodexTheme.textPrimary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("加入白名单") {
                        store.addMailboxWhitelist(sentinelId: rejection.sentinelId, address: rejection.sender)
                        whitelistText = (store.mailboxSentinels.first { $0.id == sentinelId }?.whitelist ?? [])
                            .joined(separator: "\n")
                    }
                    .fixedSize()
                    .help("写进白名单, 下次来信即可执行")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 小件

    private func field<C: View>(_ label: String, hint: String?,
                                @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11)).foregroundStyle(CodexTheme.textSecondary)
                if let hint {
                    Text(hint).font(.system(size: 10)).foregroundStyle(CodexTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 96, alignment: .leading)
            control().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 草稿装配

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        accountId = nil
        projectId = nil
        secretInput = ""
        formError = nil
        if let id = effectiveExistingId, let existing = store.mailboxSentinels.first(where: { $0.id == id }) {
            draft = existing
            accountId = existing.accountId
            projectId = existing.projectId
            whitelistText = existing.whitelist.joined(separator: "\n")
        } else {
            draft = MailboxSentinel(name: "", accountId: available.first?.id ?? UUID())
            accountId = available.first?.id
            projectId = store.activeProject?.id
            whitelistText = ""
        }
    }

    private func save() {
        var agent = draft
        agent.name = agent.name.trimmingCharacters(in: .whitespaces)
        guard !agent.name.isEmpty else { formError = "请填名字"; return }
        guard let accountId else { formError = "请选择邮箱"; return }
        agent.accountId = accountId
        agent.projectId = projectId
        agent.whitelist = parsedWhitelist
        guard !agent.whitelist.isEmpty else { formError = "白名单至少一个发件人地址"; return }
        guard store.upsertMailboxSentinel(agent) else {
            formError = "该邮箱已被其他 Inbox agent 占用 (一个邮箱只能绑一个)"
            return
        }
        let secret = secretInput.trimmingCharacters(in: .whitespaces)
        if !secret.isEmpty { store.setMailboxSentinelSecret(secret, sentinelId: agent.id) }
        draft = agent
        secretInput = ""
        // 密钥闸开着却没有密钥 → 留在原地提示 (已落库, 补完密钥再保存即更新同一行)
        if agent.requireSecret && !store.hasMailboxSentinelSecret(sentinelId: agent.id) {
            formError = "密钥闸开着但没有密钥 —— 首封会被判「缺密钥」拒绝"
            return
        }
        formError = nil
        savedFlash = true
        onSaved(agent.id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    private func performDelete() {
        guard let id = effectiveExistingId else { return }
        store.removeMailboxSentinel(id: id)
        onDeleted()
    }
}
