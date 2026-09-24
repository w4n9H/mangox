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
        if !nameFilled { return L("名称") }
        if accountId == nil { return L("邮箱") }
        if parsedWhitelist.isEmpty { return L("发件人白名单") }
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
            Button(LK(savedFlash ? "✓ 已保存" : (effectiveExistingId == nil ? "创建" : "保存"))) { save() }
                .buttonStyle(CodexActionButtonStyle(kind: savedFlash ? .success : .primary,
                                                    disabled: !nameFilled))
                .disabled(savedFlash || !nameFilled)
                .help(nameFilled ? LK(effectiveExistingId == nil ? "创建这个 Inbox" : "保存")
                                 : LK("请先填名称 (编辑器顶部那个大字输入框)"))
        }
    }

    private var accountMenu: some View {
        CodexPillMenu {
            menuItem("请选择", selected: accountId == nil) { accountId = nil }
            ForEach(available) { a in
                menuItem(LK(accountTitle(a)), selected: accountId == a.id) { accountId = a.id }
            }
        } label: {
            Image(systemName: "tray.full").font(.system(size: 10))
            Text(LK(selectedAccount.map { $0.label.isEmpty ? $0.address : $0.label } ?? "选择邮箱"))
        }
        .disabled(effectiveExistingId != nil)   // 绑定后不可改 (1:1, 改绑请重建)
        .help(LK(effectiveExistingId != nil ? "邮箱绑定后不可修改 (一个邮箱只服务一个 Inbox)" : "选择收信用的邮箱账号"))
    }

    private var projectMenu: some View {
        CodexPillMenu {
            menuItem("无项目 (回落 home)", selected: projectId == nil) { projectId = nil }
            ForEach(bindableProjects) { p in
                menuItem(LK(p.title), selected: projectId == p.id) { projectId = p.id }
            }
        } label: {
            Image(systemName: "folder").font(.system(size: 10))
            Text(LK(selectedProject.map { "→ \($0.title)" } ?? "→ 回落 home"))
        }
        .help("agent 在这个目录里干活; 选「无项目」时按 home 执行 (请看管好白名单)")
    }

    private func accountTitle(_ a: MailboxAccount) -> String {
        a.label.isEmpty ? a.address : "\(a.label) · \(a.address)"
    }

    /// 胶囊菜单里的单选条目 (✓ 前缀 = 当前选中, 与 ChatComposer 模型菜单同款)。
    /// 必须用 Button —— 见 CodexPillMenu 上方的约束说明。
    private func menuItem(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Text("✓ ") + Text(title) } else { Text(title) }
        }
    }

    private var enabledToggle: some View {
        HStack(spacing: 5) {
            CodexMiniToggle(isOn: Binding(get: { draft.enabled }, set: { draft.enabled = $0 }))
            Text(LK(draft.enabled ? "启用" : "停用"))
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
            field("发件人白名单", hint: "一行一个地址; 名单外的信静默丢弃并移入 Trash", shape: .block) {
                whitelistEditor
            }
            field("轮询间隔", hint: "多久看一次收件箱 (全局串行: 同一时刻只跑一个远程任务)") {
                // 值就该长成"值"的样子: 首版用 `accent`(暖橙红) 画这个数字, 在一张表单里像条没接线的
                // 链接 —— 这套语言里暖色是给"动作/强调"的, 不是给读数的。
                Stepper(value: $draft.pollInterval, in: 15...300, step: 15) {
                    Text("\(draft.pollInterval) 秒")
                        .font(CodexFonts.monoFont(12))
                        .foregroundStyle(CodexTheme.textPrimary)
                }
                .fixedSize()
            }
            secretRow
            if !draft.requireSecret {
                Text("⚠️ 关掉密钥闸后只剩白名单 + 服务商过滤, 建议名单内各域都已配 DMARC")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.toolRunning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field("模型", hint: "只作用于这个 Inbox 起的会话, 不改变你当前会话的模型与档位") {
                inboxModelPicker
            }
            field("高级", hint: "工具面与危险命令裁决 (无人值守路径没有审批 UI)") {
                HStack(spacing: 6) {
                    agentModePill
                    approvalPill
                }
                // ⚠️ `CodexPillMenu` 里是 `Menu(.borderlessButton)` —— 宽度是**弹性**的: 不给
                // `fixedSize` 它会一路撑开、把紧跟其后的提示顶走 (P10.4 那轮踩过同一个坑)。
                .fixedSize()
            }
            field("探测地址", hint: "可选: 执行前先探这个 URL, 不通则不跑 (空 = 不探)", shape: .block) {
                probeField
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

    // MARK: - 规则卡里的小件 (2026-09-24 第二版: 系统控件全部换成自家的)

    /// 白名单输入井。面与另外两个输入井**同一种** (`bgInput` + 圆角 6)。
    private var whitelistEditor: some View {
        TextEditor(text: $whitelistText)
            .font(CodexFonts.monoFont(12))
            .frame(height: 56)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(CodexTheme.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 密钥闸: **开关跟在标签同一行**, 密钥井落在下一行的**控件列**上。
    /// 首版把开关与井竖着堆在右边缘 —— 右对齐的是整个 `VStack`, 而 `VStack` 内部仍是左对齐 ⇒
    /// 开关贴左、井在右, 成了个"台阶" (boss 截图里最乱的一行)。
    private var secretRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            field("密钥闸", hint: "首封主题里必须带这串密钥 (清洗剥掉后不落库)") {
                // 与编辑器头部那个「启用」**同一个控件** —— 系统 `.switch` 的蓝在这套界面里是外来色。
                CodexMiniToggle(isOn: $draft.requireSecret)
            }
            if draft.requireSecret {
                SecureField(store.hasMailboxSentinelSecret(sentinelId: draft.id)
                            ? L("已设置 (留空不修改)") : L("共享密钥"), text: $secretInput)
                    .textFieldStyle(.plain)
                    .font(CodexFonts.monoFont(12))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(CodexTheme.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: 260)
                    // 与控件列同一条左边缘 (首版它起于 745, 而这一列起于 96 —— 差着一格)。
                    .padding(.leading, Self.labelColumnWidth + 8)
            }
        }
    }

    /// 探测地址输入井 —— 与白名单**同一个面**。
    /// 首版这里用 `.roundedBorder` (系统白底描边)、而白名单用 `bgInput`: 一张卡里两种输入面 = 脏。
    private var probeField: some View {
        TextField("https://…", text: $draft.intranetProbeURL)
            .textFieldStyle(.plain)
            .font(CodexFonts.monoFont(11))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(CodexTheme.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 工具面 (`AgentMode`)。首版是系统 `.menu` `Picker`, 渲染成 AppKit 默认的**蓝色双箭头弹窗** ——
    /// 在这套全自绘胶囊的界面里最扎眼的一处 (boss 截图: "太丑了这个样式")。
    private var agentModePill: some View {
        CodexPillMenu {
            ForEach(AgentMode.allCases) { mode in
                Button(mode.displayName) { draft.agentMode = mode }
            }
        } label: {
            Image(systemName: "switch.2")
            Text(draft.agentMode.displayName)
        }
    }

    /// 危险命令裁决 (`ApprovalMode`) —— 同上。`displayName` 是契约侧常量, 不走本地化。
    private var approvalPill: some View {
        CodexPillMenu {
            ForEach(ApprovalMode.allCases) { mode in
                Button(mode.displayName) { draft.approval = mode }
            }
        } label: {
            Image(systemName: "checkmark.shield")
            Text(draft.approval.displayName)
        }
        .help(draft.approval.subtitle)
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
                    Text(existing.lastPollAt.map { String(format: L("上次收信 %@"), relativeTime($0)) } ?? L("尚未收信"))
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
        var parts: [String] = [L("全局串行 (同一时刻只跑一个远程任务)")]
        parts.append(String(format: L("排队 %lld 个"), store.mailboxQueuedTaskCount))
        if let running = store.mailboxRunningTask {
            parts.append(String(format: L("在途: %@"), running.title))
        } else {
            parts.append(L("串行位空闲"))
        }
        if let last = store.mailboxLastPollAt { parts.append(String(format: L("最近收信 %@"), relativeTime(last))) }
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

    // MARK: - 任务级模型 (2026-09-24, 与 Cron/Watch 的 `taskModelPicker` 同一条契约)

    /// 受控 `ModelPicker`: **值进值出** —— 只写 `draft`, 绝不碰 `store.model.currentChoice`。
    /// 文案里那句"不改变你当前会话"就是这条的技术含义 (与 Cron/Watch 侧逐字对齐)。
    private var inboxModelPicker: some View {
        ModelPicker(
            models: store.model.menuModels,
            choice: draftChoice,
            title: { m in
                store.model.customLabel(provider: m.provider, modelId: m.id) ?? m.label
            },
            fallbackTitle: inboxFallbackTitle,
            helpText: L("只作用于这个 Inbox 起的会话, 不改变你当前会话的模型与档位"),
            pillChrome: true   // 与 Cron/Watch 侧同一个控件、同一种形态
        ) { pick in
            // 三件套**整体**落定 —— 只改级别而模型仍空, `MailboxSentinel.modelOverride`
            // 会整体返回 nil 把级别丢掉 (那是静默失效, 不是"跟随")。
            draft.provider = pick.provider
            draft.modelId = pick.modelId
            draft.thinkingLevel = pick.level.rawValue
        }
    }

    /// 控件显示值。空分量 (老库的行 / 新建草稿) 按**当前全局值**补 —— 未 pin 的哨兵在 fire 时
    /// 走 `modelOverride: nil`, 落到日志会话自己的 transport 上 ≈ 当前会话的模型, 显示即为此。
    /// 与 Cron/Watch 侧同一条: 控件表达不了"未指定", 但**没动过就不写回** (保存后仍是空 = 继续跟随)。
    private var draftChoice: ModelChoice {
        ModelChoice(provider: draft.provider.isEmpty ? store.currentProvider : draft.provider,
                    modelId: draft.modelId.isEmpty ? store.currentModelId : draft.modelId,
                    level: draft.thinkingLevel.flatMap(ThinkingLevel.init(rawValue:))
                        ?? store.model.thinkingLevel)
    }

    /// 药丸文案: 已 pin 用它的名字; 未 pin 用当前全局模型名 (与 `draftChoice` 补的一致)。
    private var inboxFallbackTitle: String {
        guard !draft.modelId.isEmpty else { return store.model.currentModelDisplayName }
        return store.model.customLabel(provider: draft.provider, modelId: draft.modelId) ?? draft.modelId
    }

    // MARK: - 小件

    /// 标签列宽 —— **全卡唯一**。所有行的标签都占这一列, 控件列因此有统一的左边缘。
    /// 取 88pt: 最长标签「发件人白名单」(6 字 @11pt ≈ 66pt) + 余量 ⇒ 标签**永不折行**。
    private static let labelColumnWidth: CGFloat = 88

    /// 行的形状 —— 判据是**控件能不能被一行装下**。
    private enum FieldShape {
        /// 有本征宽度的控件 (Stepper / 开关 / 药丸 / 菜单): 一行放 [标签][控件][提示]。
        case inline
        /// 要占满控件列的控件 (TextEditor / TextField): [标签][提示] 一行, 控件在下一行。
        case block
    }

    /// 一条表单行。
    ///
    /// **两版迭代的教训 (都留着, 别再走回去)** —— boss 两次截图:
    ///   · 首版「96pt 固定标签列 + 控件列 `maxWidth: .infinity`」: 26 字的提示被塞进 96pt ⇒
    ///     折成 3~4 行 (**左挤**); 控件靠左摆而右侧整段空着 (boss: "左侧拥挤, 右侧留白又太多")。
    ///   · 二版把控件**推到右边缘**想治"右空" ⇒ 换来更坏的病 (boss: "太丑了这个样式"):
    ///     **控件列的左边缘没了**。每行控件起点都不同 (开关 745 / 密钥井 745 / 步进器 1030 /
    ///     药丸 845 / 两个菜单 818) ⇒ 读起来是一排"浮着的控件"; 提示与控件之间还横着一条
    ///     贯穿卡片的空道 (提示止于 470、控件起于 820)。
    ///     **"推右"只是把空道从行尾挪到了行中, 而且用一条对齐换来的。**
    /// ⇒ 现在: **两列共用**, 与同页 Cron/Watch 编辑器的 `cronRow` 同语言 (那是本页既有的写法):
    ///   ① 标签列固定 `labelColumnWidth` ⇒ 永不折行 (**治"左挤"**);
    ///   ② 控件列从同一个 x 起 ⇒ 所有控件共用一条左边缘 (**二版丢的就是它**);
    ///   ③ 提示**紧跟控件后面**, 不在中间留空道 —— 正是 `cronRow` 里「= 检查频率 (…)」的排法。
    @ViewBuilder
    private func field<C: View>(_ label: LocalizedStringKey,
                                hint: LocalizedStringKey? = nil,
                                shape: FieldShape = .inline,
                                @ViewBuilder control: () -> C) -> some View {
        switch shape {
        case .inline:
            HStack(alignment: .center, spacing: 8) {
                labelText(label)
                control()
                if let hint { hintText(hint) }
                Spacer(minLength: 0)
            }
        case .block:
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    labelText(label)
                    if let hint { hintText(hint) }
                    Spacer(minLength: 0)
                }
                // 控件也缩进到控件列 —— 否则整张卡会有**两个**左边缘 (标签一个、输入井一个)。
                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.labelColumnWidth + 8)
            }
        }
    }

    /// 标签: 定宽不折行 —— 控件列的左边缘就由它定。
    private func labelText(_ label: LocalizedStringKey) -> some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(CodexTheme.textSecondary)
            .lineLimit(1)
            .frame(width: Self.labelColumnWidth, alignment: .leading)
    }

    /// 提示: 跟在控件后面 (或 `.block` 的标题行里)。**永不截断**, 只在真放不下时折行。
    /// ⚠️ 别给它 `layoutPriority`: 那会让提示比**控件**强势 —— 窄窗口下它先吃满宽度, 把旁边
    /// 没有 `fixedSize` 的药丸挤成截断态。截断药丸是功能损失, 提示折行只是观感, 该让控件先取。
    private func hintText(_ hint: LocalizedStringKey) -> some View {
        Text(hint)
            .font(.system(size: 10))
            .foregroundStyle(CodexTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
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
        guard !agent.name.isEmpty else { formError = L("请填名字"); return }
        guard let accountId else { formError = L("请选择邮箱"); return }
        agent.accountId = accountId
        agent.projectId = projectId
        agent.whitelist = parsedWhitelist
        guard !agent.whitelist.isEmpty else { formError = L("白名单至少一个发件人地址"); return }
        guard store.upsertMailboxSentinel(agent) else {
            formError = L("该邮箱已被其他 Inbox agent 占用 (一个邮箱只能绑一个)")
            return
        }
        let secret = secretInput.trimmingCharacters(in: .whitespaces)
        if !secret.isEmpty { store.setMailboxSentinelSecret(secret, sentinelId: agent.id) }
        draft = agent
        secretInput = ""
        // 密钥闸开着却没有密钥 → 留在原地提示 (已落库, 补完密钥再保存即更新同一行)
        if agent.requireSecret && !store.hasMailboxSentinelSecret(sentinelId: agent.id) {
            formError = L("密钥闸开着但没有密钥 —— 首封会被判「缺密钥」拒绝")
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
