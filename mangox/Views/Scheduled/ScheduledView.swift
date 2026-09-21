//
//  ScheduledView.swift
//  P3.6 本地定时任务管理面板 (主区切换视图)。
//  视觉语言与 KnowledgeView 一致: 左列 Sidebar 行语言 + 编辑区 Composer 输入卡语言。
//  cron 四档录入器 (每天/每周/间隔/高级): 控件生成 cron, cron 仍是唯一真相 (调度器零改动);
//  高级档保留 mono 文本框兜底, 人类可读预览走 CronExpr.describe (识别不出显示原文)。
//

import SwiftUI

struct ScheduledView: View {
    @ObservedObject var store: ChatStore

    // 编辑目标 (P10.2e: Inbox 与 Cron/Watch 共用本双栏页)
    @State private var target: EditorTarget = .newTask
    /// 两侧各自"上次在哪" —— 类型段选来回切时不至于每次都被踢回新建态。
    @State private var lastTaskTarget: EditorTarget = .newTask
    @State private var lastSparseTarget: EditorTarget = .newSparse

    /// 切换编辑目标的**唯一写入口**: 顺带记住该侧的上次目标 (供段选回切)。
    private func setTarget(_ t: EditorTarget) {
        switch t {
        case .newTask, .task:     lastTaskTarget = t
        case .newSparse, .sparse: lastSparseTarget = t
        }
        target = t
    }

    /// 切回任务侧时校验旧目标还在 (被删则回落新建)。
    private func validTaskTarget(_ t: EditorTarget) -> EditorTarget {
        if case .task(let id) = t, store.scheduledTasks.contains(where: { $0.id == id }) { return t }
        return .newTask
    }

    /// 切回 Inbox 侧: 旧目标还在就用它, 否则落到列表第一个, 一个都没有才新建。
    private func validSparseTarget(_ t: EditorTarget) -> EditorTarget {
        if case .sparse(let id) = t, store.mailboxSentinels.contains(where: { $0.id == id }) { return t }
        if let first = store.mailboxSentinels.first { return .sparse(first.id) }
        return .newSparse
    }
    @State private var draftName: String = ""
    @State private var draftPrompt: String = ""
    @State private var draftCron: String = "0 9 * * *"
    @State private var draftProjectId: UUID?
    @State private var draftContinuous: Bool = false
    @State private var hoveringId: UUID?
    // P3.10 Watch 任务 (原"哨兵任务"): 类型段选 / 触发条件 / 检查频率三档
    // P9-#17: 无人值守恒开 (fire 不再读 task.unattended), 开关与确认弹窗已移除
    @State private var draftIsWaiting: Bool = false
    @State private var draftCondition: String = ""
    @State private var draftFrequency: FrequencyKind = .low
    // cron 四档录入器: 控件态 → 生成 cron; 编辑时 classifyCron 反解析回填 (解析不出落高级档)
    @State private var cronMode: CronMode = .daily
    @State private var cronHour: Int = 9
    @State private var cronMinute: Int = 0
    @State private var cronWeekdays: Set<Int> = [1, 2, 3, 4, 5]   // cron 星期: 0=日
    @State private var cronInterval: Int = 30
    @State private var cronIntervalUnit: IntervalUnit = .minutes
    // 工作日志 (P3.9 交接文件): 编辑器内嵌可编辑区块, 磁盘为准
    @State private var draftLog: String = ""
    @State private var handoffUpdatedAt: Date?
    @State private var showWorkLog: Bool = false
    // P10.4 任务级执行配置 (nil 草稿 = 跟随全局默认; fire 时只动日志会话 transport)
    @State private var draftUseCustomConfig: Bool = false
    @State private var draftProvider: String = ""
    @State private var draftModelId: String = ""
    @State private var draftThinking: String?
    @State private var draftMode: String = AgentMode.standard.rawValue
    // 操作反馈: 删除二次确认 / 保存成功闪现
    @State private var showDeleteConfirm: Bool = false
    @State private var savedFlash: Bool = false

    /// 编辑器当前对象。计划任务侧原代码全按 `editingId` 读写, 这里由 target 派生 →
    /// 该侧 12 处使用零改动 (只有 3 处赋值点改成写 target)。
    private enum EditorTarget: Equatable {
        case newTask
        case task(UUID)
        case newSparse
        case sparse(UUID)
    }

    private var editingId: UUID? {
        if case .task(let id) = target { return id }
        return nil
    }

    private var editingSparseId: UUID? {
        if case .sparse(let id) = target { return id }
        return nil
    }

    /// 编辑器当前渲染 sparse agent 侧 (新建或编辑)。
    private var isSparseTarget: Bool {
        switch target {
        case .newSparse, .sparse: return true
        case .newTask, .task:     return false
        }
    }

    /// 左侧列表条目 (P10.2e 单列表混排两类任务, 靠行首图标区分)。
    private enum ListEntry: Identifiable {
        case task(ScheduledTask)
        case sparse(MailboxSentinel)

        var id: String {
            switch self {
            case .task(let t):   return "task-\(t.id.uuidString)"
            case .sparse(let s): return "sparse-\(s.id.uuidString)"
            }
        }
    }

    /// 计划任务保持原有顺序; sparse agent 追加在其后 (两侧新建都落在各自末尾, 行为一致)。
    private var listEntries: [ListEntry] {
        store.scheduledTasks.map(ListEntry.task) + store.mailboxSentinels.map(ListEntry.sparse)
    }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: Tune.knowledgeListWidth)
                .background(CodexTheme.bgSidebar)
            Divider().overlay(CodexTheme.divider)
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CodexTheme.bgChat)
        }
        .confirmationDialog("删除任务「\(draftName)」？",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除任务 (保留会话与工作日志)") { deleteEditing(deleteSessions: false) }
            Button("删除任务和日志会话", role: .destructive) { deleteEditing(deleteSessions: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("任务删除后停止调度。工作日志文件始终保留; 日志会话可选删除。")
        }
    }

    // MARK: - 列表

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SCHEDULED")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                Menu {
                    Button("新建 Cron 任务") { startNew(waiting: false) }
                    Button("新建 Watch 任务") { startNew(waiting: true) }
                    Button("新建 Inbox") { startNewSparse() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("新建 (Cron 定时 · Watch 条件值守 · Inbox 来信驱动)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(listEntries) { entry in
                        switch entry {
                        case .task(let task):     row(task)
                        case .sparse(let agent):  sparseRow(agent)
                        }
                    }
                    if listEntries.isEmpty {
                        Text("暂无任务\n点右上角 + 新建")
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private func row(_ task: ScheduledTask) -> some View {
        let selected = isEditing(task)
        let hovered = hoveringId == task.id
        let icon = rowIcon(task)
        return HStack(spacing: 7) {
            Image(systemName: icon.name)
                .font(.system(size: 10))
                .foregroundStyle(icon.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(selected ? CodexTheme.textPrimary : (task.completedAt != nil ? CodexTheme.textMuted : CodexTheme.textSecondary))
                Text(statusLine(task))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(cronValid(task) ? CodexTheme.textSecondary : CodexTheme.toolError)
                Text(contextLine(task))
                    .font(CodexFonts.monoFont(9))
                    .lineLimit(1)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer(minLength: 2)
            if task.completedAt == nil {   // 已触发的等待任务不显示开关 (重开 = 重新等待)
                CodexMiniToggle(isOn: Binding(
                    get: { task.enabled },
                    set: { _ in store.toggleScheduled(id: task.id) }
                ))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.selected : (hovered ? CodexTheme.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? task.id : nil }
        .onTapGesture { loadDraft(task) }
    }

    /// P3.10 行首图标: 定时型 clock / 等待型雷达 / 已触发对勾
    private func rowIcon(_ task: ScheduledTask) -> (name: String, color: Color) {
        let isWaiting = task.condition?.isEmpty == false
        if isWaiting {
            if task.completedAt != nil { return ("checkmark.seal.fill", CodexTheme.toolDone) }
            return task.enabled
                ? ("dot.radiowaves.left.and.right", CodexTheme.info)
                : ("dot.radiowaves.left.and.right", CodexTheme.textMuted)
        }
        return task.enabled ? ("clock.badge.fill", CodexTheme.toolDone) : ("clock.badge", CodexTheme.textMuted)
    }

    // MARK: - sparse agent 行 (P10.2e: 第三种触发源, 与上面两类同版式)

    private func sparseRow(_ agent: MailboxSentinel) -> some View {
        let selected = editingSparseId == agent.id
        let hovered = hoveringId == agent.id
        return HStack(spacing: 7) {
            Image(systemName: agent.enabled ? "envelope.badge.fill" : "envelope")
                .font(.system(size: 10))
                .foregroundStyle(agent.enabled ? CodexTheme.accent : CodexTheme.textMuted)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(selected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                Text(sparseStatusLine(agent))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle((agent.lastError?.isEmpty == false) ? CodexTheme.toolError : CodexTheme.textSecondary)
                Text(sparseContextLine(agent))
                    .font(CodexFonts.monoFont(9))
                    .lineLimit(1)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer(minLength: 2)
            CodexMiniToggle(isOn: Binding(
                get: { agent.enabled },
                set: { _ in store.toggleMailboxSentinel(id: agent.id) }
            ))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.selected : (hovered ? CodexTheme.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? agent.id : nil }
        .onTapGesture { loadSparseDraft(agent) }
    }

    /// L2 状态行: 收信情况 + 最近错误 (与计划任务的 statusLine 同位同义)。
    private func sparseStatusLine(_ agent: MailboxSentinel) -> String {
        var parts: [String] = []
        if let error = agent.lastError, !error.isEmpty {
            parts.append("✗ \(error)")
        } else if agent.enabled {
            parts.append(String(format: L("收信中 · 每 %llds"), agent.pollInterval))
        } else {
            parts.append(String(format: L("已停用 · 每 %llds"), agent.pollInterval))
        }
        parts.append(agent.lastPollAt.map { String(format: L("上次收信 %@"), relativeTime($0)) } ?? L("尚未收信"))
        return parts.joined(separator: " · ")
    }

    /// L3 上下文行: 绑定的邮箱与工作目录 (对应计划任务的 cron 行位置)。
    private func sparseContextLine(_ agent: MailboxSentinel) -> String {
        let account = store.mailboxAccounts.first { $0.id == agent.accountId }
        let project = store.projects.first { $0.id == agent.projectId }
        let address = account?.address ?? L("账号已删除")
        return "\(address)  →  \(project.map(\.title) ?? "home")"
    }

    /// 三行版式 · L2 状态行 (扫一眼的高频信息; cron 无效红字提示)
    private func statusLine(_ task: ScheduledTask) -> String {
        if !cronValid(task) { return L("cron 无效") }
        var parts: [String] = []
        if task.condition?.isEmpty == false {
            if let done = task.completedAt {
                parts.append(String(format: L("已触发 · %@"), done.relativeTag))
            } else if task.enabled {
                parts.append(String(format: L("值守中 · %@"), FrequencyKind.from(cron: task.cron).shortLabel))
            } else {
                parts.append(L("已暂停"))
            }
        } else {
            parts.append(CronExpr.describe(task.cron))   // "每天 09:00" 等人话描述 (识别不出=cron 原文)
            if !task.enabled {
                parts.append(L("已暂停"))
            } else if task.continuous {
                parts.append(L("持续"))
            }
            if task.runCount > 0 {
                parts.append(String(format: L("已跑 %lld 次"), task.runCount))
            } else if let last = task.lastRunAt {
                parts.append(String(format: L("上次 %@"), last.relativeTag))
            } else if parts.isEmpty {
                parts.append(L("待运行"))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// 三行版式 · L3 上下文行 (mono 次要信息)
    private func contextLine(_ task: ScheduledTask) -> String {
        var parts: [String] = []
        if let pid = task.projectId {
            parts.append(store.projects.first { $0.id == pid }?.title ?? L("未知项目"))
        } else {
            parts.append(L("无项目"))
        }
        parts.append(task.condition?.isEmpty == false ? FrequencyKind.from(cron: task.cron).cron : task.cron)
        parts.append(L("无人值守"))   
        return parts.joined(separator: " · ")
    }

    private func cronValid(_ task: ScheduledTask) -> Bool { task.cronExpr != nil }
    private func isEditing(_ task: ScheduledTask) -> Bool { editingId == task.id }

    // MARK: - 编辑器

    /// P10.2e: 类型段选置顶 (跨两侧共用), 下面才是该类型的编辑器本体。
    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                kindSelector
                Group {
                    if isSparseTarget {
                        SparseAgentEditor(store: store,
                                          sentinelId: editingSparseId,
                                          onSaved: { id in setTarget(.sparse(id)) },
                                          onDeleted: { setTarget(validSparseTarget(lastSparseTarget)) })
                    } else {
                        taskEditor
                    }
                }
                .id(editorIdentity)   // 换编辑对象 = 换实例 (草稿状态随之重建, 不串台)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: Tune.knowledgeEditorMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 编辑器身份 (P10.2e): sparse agent 侧的状态活在 SparseAgentEditor 内, 靠 id 变化触发重建。
    private var editorIdentity: String {
        switch target {
        case .newTask:        return "new-task"
        case .task(let id):   return "task-\(id.uuidString)"
        case .newSparse:      return "new-sparse"
        case .sparse(let id): return "sparse-\(id.uuidString)"
        }
    }

    private var taskEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlsRow
            nameField
            cronRow
            if draftIsWaiting { conditionCard }
            promptCard
            configCard   // P10.4: 任务级模型/级别/模式
            if editingId != nil && (draftContinuous || draftIsWaiting) {
                workLogCard
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            projectMenu
            unattendedPill
            if !draftIsWaiting { continuousToggle }
            Spacer()
            if let last = editingTask()?.logSessionId {
                Button("任务日志") {
                    store.selectConversation(last)
                }
                .buttonStyle(.plain)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.info)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            if editingId != nil {
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("删除")
                    }
                }
                .buttonStyle(CodexActionButtonStyle(kind: .danger))
            }
            Button(LK(savedFlash ? "✓ 已保存" : "保存")) { saveEditing() }
                .buttonStyle(CodexActionButtonStyle(
                    kind: savedFlash ? .success : .primary,
                    disabled: !draftReady))
                .disabled(!draftReady || savedFlash)
                .help(LK(draftReady ? "保存" : (draftIsWaiting ? "触发条件与动作为必填" : "prompt 与 cron 为必填")))
        }
    }

    /// 三种触发源 (P10.2e 命名): Cron=时间 / Watch=本地条件 / Inbox=外部来信。
    /// 段选跨两侧共用 —— 它同时是"当前在看哪一类任务"的指示器。
    enum EditorKind: Int, CaseIterable, Identifiable {
        case cron, watch, inbox
        var id: Int { rawValue }
        var label: String { switch self {
        case .cron: "Cron"
        case .watch: "Watch"
        case .inbox: "Inbox"
        } }
        var help: String { switch self {
        case .cron: L("到点投递 prompt (cron 驱动)")
        case .watch: L("按频率轻检查触发条件, 条件成立才执行动作 (条件驱动)")
        case .inbox: L("来信驱动的无人值守 agent: 按间隔收信, 过鉴权四道闸后起会话执行")
        } }
    }

    private var activeKind: EditorKind {
        switch target {
        case .newSparse, .sparse: return .inbox
        case .newTask, .task:     return draftIsWaiting ? .watch : .cron
        }
    }

    /// 类型段选 (P10.2e): 三档并列, 点哪档进哪类任务的编辑器。
    private var kindSelector: some View {
        HStack(spacing: 4) {
            ForEach(EditorKind.allCases) { kind in kindPill(kind) }
        }
        .padding(2)
        .background(CodexTheme.bgElevated)
        .clipShape(Capsule())
    }

    private func kindPill(_ kind: EditorKind) -> some View {
        let active = activeKind == kind
        return Button(action: { selectKind(kind) }) {
            Text(kind.label)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(active ? CodexTheme.textPrimary : CodexTheme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .frame(height: 22)
                .background(active ? CodexTheme.bgBase : Color.clear)
                .clipShape(Capsule())
                .shadow(color: active ? CodexTheme.border.opacity(0.5) : .clear, radius: 1.5, y: 0.5)
        }
        .buttonStyle(.plain)
        .help(kind.help)
    }

    /// 段选落点: 任务侧两档只翻模式 (草稿内容不动), Inbox 档才换编辑器。
    private func selectKind(_ kind: EditorKind) {
        switch kind {
        case .cron, .watch:
            if isSparseTarget {
                restoreTaskTarget(waiting: kind == .watch)
            } else {
                switchTaskMode(waiting: kind == .watch)
            }
        case .inbox:
            setTarget(validSparseTarget(lastSparseTarget))
        }
    }

    /// 任务侧 Cron ↔ Watch: 只翻档并同步对应控件 (草稿的 prompt/名称等原样保留)。
    private func switchTaskMode(waiting: Bool) {
        guard draftIsWaiting != waiting else { return }
        let currentCron = effectiveCron   // 依赖当前 draftIsWaiting, 必须在翻转前取
        if waiting {
            // Cron→Watch: 检查频率从当前生效的 cron 反推 (匹配不上落 low 档)
            draftFrequency = FrequencyKind.from(cron: currentCron)
            draftIsWaiting = true
        } else {
            // Watch→Cron: 控件态从检查频率 cron 反解析
            draftIsWaiting = false
            syncCronControls(draftFrequency.cron)
        }
    }

    /// 从 Inbox 侧切回任务侧: 恢复上次任务目标 (被删则回落新建并清空草稿)。
    private func restoreTaskTarget(waiting: Bool) {
        let restored = validTaskTarget(lastTaskTarget)
        if restored == lastTaskTarget {
            setTarget(restored)
            switchTaskMode(waiting: waiting)
        } else {
            startNew(waiting: waiting)
        }
    }

    /// P9-#17: 无人值守恒开徽章 (原开关 + 风险确认弹窗已移除——
    /// fire 恒 unattended, 开关已无语义; 后台日志会话无审批 UI 入口, 弹卡会卡死到超时)。
    private var unattendedPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.accent)
            Text("无人值守 · 恒开")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 24)
        .background(CodexTheme.accentSoft)
        .clipShape(Capsule())
        .help("fire 回合恒不经确认执行工具调用 (含 bash)——后台任务无审批入口, 关闭会卡死任务; 执行过程见任务日志")
    }

    /// P3.10 触发条件卡 (等待型): 条件=看什么 / 动作=干什么, 两卡分开
    private var conditionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("触发条件 (每轮轻检查)")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draftCondition)
                    .font(CodexTheme.fontBody)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 88)
                if draftCondition.isEmpty {
                    Text("写可判定的标准, 如: 官网发布 X 的正式公告页 (相关新闻不算)…")
                        .font(CodexTheme.fontBody)
                        .foregroundStyle(CodexTheme.textMuted)
                        .padding(.leading, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(CodexTheme.bgComposer)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                    .stroke(CodexTheme.info.opacity(0.45), lineWidth: 1)
            )
        }
    }

    private func editingTask() -> ScheduledTask? {
        editingId.flatMap { id in store.scheduledTasks.first { $0.id == id } }
    }

    // MARK: - P10.4 任务级执行配置 (模型/级别/模式; fire 只动日志会话 transport)

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { draftUseCustomConfig.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: draftUseCustomConfig ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(draftUseCustomConfig ? CodexTheme.accent : CodexTheme.textMuted)
                    Text("自定义模型与模式")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(draftUseCustomConfig ? CodexTheme.textPrimary : CodexTheme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            if draftUseCustomConfig {
                HStack(spacing: 8) {
                    configModelPicker
                    configThinkingPicker
                    configModePicker
                }
                Text("仅作用于本任务运行 (日志会话), 不改变你当前会话的模型与档位。")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var configModelPicker: some View {
        CodexPillMenu {
            ForEach(Array(store.model.menuModels.enumerated()), id: \.offset) { _, m in
                Button(store.model.customLabel(provider: m.provider, modelId: m.id) ?? m.id) {
                    draftProvider = m.provider
                    draftModelId = m.id
                }
            }
        } label: {
            Image(systemName: "cpu")
            Text(store.model.customLabel(provider: draftProvider, modelId: draftModelId)
                 ?? (draftModelId.isEmpty ? L("选择模型") : draftModelId))
        }
    }

    private var configThinkingPicker: some View {
        CodexPillMenu {
            ForEach(ThinkingLevel.allCases) { level in
                Button(level.rawValue) {
                    draftThinking = level.rawValue
                }
            }
        } label: {
            Image(systemName: "brain")
            Text(LK(draftThinking ?? "级别"))
        }
    }

    private var configModePicker: some View {
        CodexPillMenu {
            ForEach(AgentMode.allCases) { mode in
                Button(mode.displayName) {
                    draftMode = mode.rawValue
                }
            }
        } label: {
            Image(systemName: "switch.2")
            Text(LK(AgentMode(rawValue: draftMode)?.displayName ?? "模式"))
        }
    }

    private var projectMenu: some View {
        CodexPillMenu {
            Button("无项目（纯对话）") { draftProjectId = nil }
            ForEach(store.projects) { p in
                Button(p.title) { draftProjectId = p.id }
            }
        } label: {
            Text(projectLabel)
        }
    }

    private var projectLabel: String {
        guard let pid = draftProjectId else { return L("无项目（纯对话）") }
        return store.projects.first { $0.id == pid }?.title ?? L("选择项目")
    }

    /// 持续模式开关 (跨天任务: 每次触发注入上次运行的执行记录)
    private var continuousToggle: some View {
        Button(action: { draftContinuous.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: draftContinuous ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(draftContinuous ? CodexTheme.accent : CodexTheme.textMuted)
                Text("持续")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(draftContinuous ? CodexTheme.textPrimary : CodexTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(height: 24)
            .background(draftContinuous ? CodexTheme.accentSoft : Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("持续模式: 每次触发自动带上此前运行的执行记录 (跨天任务保连续性)")
    }

    private var nameField: some View {
        TextField("任务名称", text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: Tune.knowledgeTitleFontSize, weight: .semibold))
            .foregroundStyle(CodexTheme.textPrimary)
    }

    /// P3.10 Watch 任务检查频率三档 (内部映射 cron, 调度器零改动)
    enum FrequencyKind: String, CaseIterable, Identifiable {
        case high, medium, low
        var id: String { rawValue }
        var cron: String { switch self {
        case .high: "*/5 * * * *"
        case .medium: "*/15 * * * *"
        case .low: "*/30 * * * *"
        } }
        var label: String { switch self {
        case .high: L("高 · 每 5 分钟")
        case .medium: L("中 · 每 15 分钟")
        case .low: L("低 · 每 30 分钟")
        } }
        /// 状态行简短版 (不带档位词)
        var shortLabel: String { switch self {
        case .high: L("每 5 分钟")
        case .medium: L("每 15 分钟")
        case .low: L("每 30 分钟")
        } }
        static func from(cron: String) -> FrequencyKind {
            allCases.first { $0.cron == cron } ?? .low
        }
    }

    /// cron 录入四档: 前三档控件生成 cron, 高级档直写表达式 (手写复杂表达式反解析不出时落这里)
    enum CronMode: String, CaseIterable, Identifiable {
        case daily, weekly, interval, advanced
        var id: String { rawValue }
        var label: String { switch self {
        case .daily: L("每天")
        case .weekly: L("每周")
        case .interval: L("间隔")
        case .advanced: L("高级")
        } }
    }

    enum IntervalUnit: String, CaseIterable, Identifiable {
        case minutes, hours
        var id: String { rawValue }
        var label: String { self == .minutes ? L("分钟") : L("小时") }
        var clamp: ClosedRange<Int> { self == .minutes ? 1...59 : 1...23 }
    }

    private var cronRow: some View {
        HStack(spacing: 8) {
            if draftIsWaiting {
                Menu {
                    ForEach(FrequencyKind.allCases) { f in
                        Button(f.label) { draftFrequency = f }
                    }
                } label: {
                    Text(draftFrequency.label)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(CodexTheme.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
                Text("= 检查频率 (条件可能成立后按此间隔值守)")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            } else {
                cronEditor
            }
            Spacer()
        }
    }

    /// cron 四档录入器: 模式段选 + 分档控件 + 人类可读预览 (识别不出显示原文)
    private var cronEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(CronMode.allCases) { m in
                    cronModePill(m)
                }
            }
            HStack(spacing: 8) {
                switch cronMode {
                case .daily:
                    timeField(label: "时", value: $cronHour, range: 0...23)
                    timeField(label: "分", value: $cronMinute, range: 0...59)
                case .weekly:
                    weekdayChips
                    timeField(label: "时", value: $cronHour, range: 0...23)
                    timeField(label: "分", value: $cronMinute, range: 0...59)
                case .interval:
                    intervalField
                    Menu {
                        ForEach(IntervalUnit.allCases) { u in
                            Button(u.label) { cronIntervalUnit = u; clampInterval() }
                        }
                    } label: {
                        Text(cronIntervalUnit.label)
                            .font(CodexTheme.fontSmall)
                            .foregroundStyle(CodexTheme.textSecondary)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                case .advanced:
                    TextField("分 时 日 月 周", text: $draftCron)
                        .textFieldStyle(.plain)
                        .font(CodexTheme.fontMonoSm)
                        .frame(width: 200)
                }
                Spacer()
            }
            cronPreviewLine
        }
    }

    private func cronModePill(_ mode: CronMode) -> some View {
        Button(action: { cronMode = mode }) {
            Text(mode.label)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(cronMode == mode ? CodexTheme.textPrimary : CodexTheme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .frame(height: 22)
                .background(cronMode == mode ? CodexTheme.selected : Color.clear)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(CodexTheme.border.opacity(cronMode == mode ? 0.6 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 自绘时间输入 (对齐页面自绘控件语言, 不用原生 DatePicker): 整数域外自动钳制
    private func timeField(label: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            TextField("0", value: value, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(CodexTheme.fontMonoSm)
                .multilineTextAlignment(.center)
                .frame(width: 36)
                .onChange(of: value.wrappedValue) { _, newValue in
                    value.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
    }

    private func clampInterval() {
        cronInterval = min(max(cronInterval, cronIntervalUnit.clamp.lowerBound), cronIntervalUnit.clamp.upperBound)
    }

    private var intervalField: some View {
        HStack(spacing: 4) {
            Text("每")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            TextField("30", value: $cronInterval, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(CodexTheme.fontMonoSm)
                .multilineTextAlignment(.center)
                .frame(width: 40)
                .onChange(of: cronInterval) { _, _ in clampInterval() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
    }

    /// 星期多选 chips (cron 星期 0=日; 显示序 一二三四五六日)
    private var weekdayChips: some View {
        HStack(spacing: 3) {
            ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { wd in
                let active = cronWeekdays.contains(wd)
                Button(action: {
                    if active { cronWeekdays.remove(wd) } else { cronWeekdays.insert(wd) }
                }) {
                    Text(LK(["日", "一", "二", "三", "四", "五", "六"][wd]))
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(active ? CodexTheme.textPrimary : CodexTheme.textMuted)
                        .frame(width: 22, height: 22)
                        .background(active ? CodexTheme.accentSoft : CodexTheme.bgElevated)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 生成的 cron + describe 预览; 高级档非法时红字
    private var cronPreviewLine: some View {
        let cron = effectiveCron
        let valid = CronExpr.parse(cron) != nil
        return Text("\(cron)  ·  \(CronExpr.describe(cron))")
            .font(CodexFonts.monoFont(10))
            .foregroundStyle(valid ? CodexTheme.textMuted : CodexTheme.toolError)
    }

    private var promptCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draftPrompt)
                .font(CodexTheme.fontBody)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 220)
            if draftPrompt.isEmpty {
                Text(LK(draftIsWaiting ? "条件触发后要执行的动作…" : "到点投递给 Agent 的 prompt…"))
                    .font(CodexTheme.fontBody)
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(.leading, 12)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
        )
    }

    /// 实际生效的 cron: Watch=频率档; Cron=控件生成 (高级档直取 draftCron 原文)
    private var effectiveCron: String {
        if draftIsWaiting { return draftFrequency.cron }
        switch cronMode {
        case .daily:
            return "\(cronMinute) \(cronHour) * * *"
        case .weekly:
            let days = cronWeekdays.sorted().map(String.init).joined(separator: ",")
            return "\(cronMinute) \(cronHour) * * \(days.isEmpty ? "*" : days)"
        case .interval:
            return cronIntervalUnit == .minutes ? "*/\(cronInterval) * * * *" : "0 */\(cronInterval) * * *"
        case .advanced:
            return draftCron
        }
    }

    private var draftReady: Bool {
        !draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty
        && CronExpr.parse(effectiveCron) != nil
        && (!draftIsWaiting || !draftCondition.trimmingCharacters(in: .whitespaces).isEmpty)
        // 名称可空: 留空自动取 prompt 首行; 项目可空: 落平铺 Chats (纯对话场景)
    }

    /// 反解析: cron → 录入控件态 (识别不出 → 高级档显示原文, 不丢不猜)
    private func classifyCron(_ s: String) -> (mode: CronMode, hour: Int, minute: Int, weekdays: Set<Int>, interval: Int, unit: IntervalUnit)? {
        let f = s.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5 else { return nil }
        if let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*", f[4] == "*" {
            return (.daily, h, m, [1, 2, 3, 4, 5], 30, .minutes)
        }
        if let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*",
           let days = parseDayField(f[4]) {
            return (.weekly, h, m, days, 30, .minutes)
        }
        if f[0].hasPrefix("*/"), let n = Int(f[0].dropFirst(2)),
           f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*" {
            return (.interval, 0, 0, [1, 2, 3, 4, 5], n, .minutes)
        }
        if f[0] == "0", f[1].hasPrefix("*/"), let n = Int(f[1].dropFirst(2)),
           f[2] == "*", f[3] == "*", f[4] == "*" {
            return (.interval, 0, 0, [1, 2, 3, 4, 5], n, .hours)
        }
        return nil
    }

    /// 星期字段: 逗号列表 / a-b 范围 → Set (0...6)
    private func parseDayField(_ s: String) -> Set<Int>? {
        var out: Set<Int> = []
        for part in s.split(separator: ",") {
            if let dash = part.firstIndex(of: "-") {
                guard let lo = Int(part[..<dash]), let hi = Int(part[part.index(after: dash)...]),
                      lo <= hi, (0...6).contains(lo), (0...6).contains(hi) else { return nil }
                out.formUnion(lo...hi)
            } else {
                guard let v = Int(part), (0...6).contains(v) else { return nil }
                out.insert(v)
            }
        }
        return out.isEmpty ? nil : out
    }

    private func syncCronControls(_ s: String) {
        if let c = classifyCron(s) {
            cronMode = c.mode
            cronHour = c.hour
            cronMinute = c.minute
            cronWeekdays = c.weekdays
            cronInterval = c.interval
            cronIntervalUnit = c.unit
        } else {
            cronMode = .advanced
        }
    }

    // MARK: - 草稿动作

    private func startNew(waiting: Bool = false) {
        setTarget(.newTask)
        draftName = ""
        draftPrompt = ""
        draftCron = "0 9 * * *"
        draftProjectId = store.activeProject?.id
        draftContinuous = false
        draftIsWaiting = waiting
        draftCondition = ""
        draftLog = ""
        handoffUpdatedAt = nil
        showWorkLog = false
        cronMode = .daily
        cronHour = 9
        cronMinute = 0
        cronWeekdays = [1, 2, 3, 4, 5]
        cronInterval = 30
        cronIntervalUnit = .minutes
    }

    /// 新建 sparse agent (草稿状态活在 SparseAgentEditor 内, 这里只切编辑目标)。
    private func startNewSparse() {
        setTarget(.newSparse)
    }

    /// 点列表行切到某个 sparse agent。
    private func loadSparseDraft(_ agent: MailboxSentinel) {
        setTarget(.sparse(agent.id))
    }

    /// 工作日志区块 (P3.9 交接文件): agent 运行期写、用户可改, 磁盘为准; 保存即写回。
    private var workLogCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                Text("工作日志")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                if let d = handoffUpdatedAt {
                    Text("更新于 \(d.formatted(.relative(presentation: .named)))")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
                Spacer()
                Button("重新读取") { loadHandoff() }
                    .buttonStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .help("丢弃本地修改, 重读磁盘文件")
                Button("保存日志") { saveHandoff() }
                    .buttonStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .help("写回磁盘, 下次运行生效")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draftLog)
                    .font(CodexTheme.fontBody)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: Tune.scheduleLogEditorMinHeight)
                if draftLog.isEmpty {
                    Text("首次运行前为空; agent 运行后会把关键进展写在这里, 也可手动编辑干预任务方向…")
                        .font(CodexTheme.fontBody)
                        .foregroundStyle(CodexTheme.textMuted)
                        .padding(.leading, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(CodexTheme.bgComposer)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                    .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
            )
            if let t = editingTask() {
                Text(store.handoffPath(for: t))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func loadHandoff() {
        guard let t = editingTask(), let h = store.readHandoff(for: t) else {
            draftLog = ""
            handoffUpdatedAt = nil
            return
        }
        draftLog = h.content
        handoffUpdatedAt = h.updatedAt
    }

    private func saveHandoff() {
        guard let t = editingTask() else { return }
        if store.saveHandoff(for: t, content: draftLog) {
            handoffUpdatedAt = Date()
        }
    }

    private func loadDraft(_ task: ScheduledTask) {
        setTarget(.task(task.id))
        draftName = task.name
        draftPrompt = task.prompt
        draftCron = task.cron
        draftProjectId = task.projectId
        draftContinuous = task.continuous
        draftIsWaiting = task.condition?.isEmpty == false
        draftCondition = task.condition ?? ""
        draftFrequency = FrequencyKind.from(cron: task.cron)
        if !draftIsWaiting { syncCronControls(task.cron) }
        // P10.4: 任务级配置回填 (nil = 跟随全局, 预填当前全局值供开启即用)
        if let cfg = task.config {
            draftUseCustomConfig = true
            draftProvider = cfg.provider
            draftModelId = cfg.modelId
            draftThinking = cfg.thinkingLevel
            draftMode = cfg.agentMode
        } else {
            draftUseCustomConfig = false
            draftProvider = store.currentProvider
            draftModelId = store.currentModelId
            draftThinking = nil
            draftMode = AgentMode.standard.rawValue
        }
        let h = store.readHandoff(for: task)
        draftLog = h?.content ?? ""
        handoffUpdatedAt = h?.updatedAt
        showWorkLog = false
    }

    private func saveEditing() {
        guard draftReady else { return }
        // 名称留空 → 自动取 prompt 首行前 24 字 (与"保存为记忆"命名规则一致)
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            // 先 String 化再兜底 —— 直接写 `String(substring? ?? L("任务"))` 会因左侧是
            // `Substring?` 而要求右侧同为 Substring (L() 返回 String, 编译不过)。
            let head = draftPrompt.split(separator: "\n").first.map { String($0.prefix(24)) }
            draftName = head ?? L("任务")
        }
        if let id = editingId,
           var existing = store.scheduledTasks.first(where: { $0.id == id }) {
            existing.name = draftName
            existing.prompt = draftPrompt
            existing.cron = effectiveCron
            existing.projectId = draftProjectId
            existing.continuous = draftContinuous
            existing.condition = draftIsWaiting && !draftCondition.trimmingCharacters(in: .whitespaces).isEmpty
                ? draftCondition : nil
            existing.unattended = true   // P9-#17: 恒无人值守, 字段仅作记录
            existing.config = buildDraftConfig()   // P10.4: 任务级执行配置
            store.updateScheduled(existing)
        } else {
            let cron = effectiveCron
            store.addScheduled(name: draftName, prompt: draftPrompt,
                               cron: cron, projectId: draftProjectId,
                               continuous: draftContinuous)
            // 等待型/无人值守附加字段 (addScheduled 无全参入口, 保存后回填)
            if let idx = store.scheduledTasks.indices.last {
                store.scheduledTasks[idx].condition = draftIsWaiting && !draftCondition.trimmingCharacters(in: .whitespaces).isEmpty
                    ? draftCondition : nil
                store.scheduledTasks[idx].unattended = true   // P9-#17: 恒无人值守
                store.scheduledTasks[idx].config = buildDraftConfig()   // P10.4
                store.updateScheduled(store.scheduledTasks[idx])
            }
        }
        // "✓ 已保存"短闪 (与代码块"已复制"同模式)
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    /// P10.4: 草稿 → 任务级配置 (未开启自定义 = nil 跟随全局)
    private func buildDraftConfig() -> SessionConfig? {
        guard draftUseCustomConfig, !draftProvider.isEmpty, !draftModelId.isEmpty else { return nil }
        return SessionConfig(provider: draftProvider, modelId: draftModelId,
                             thinkingLevel: draftThinking, agentMode: draftMode, askApproval: false)
    }

    private func deleteEditing(deleteSessions: Bool) {
        guard let id = editingId else { return }
        store.deleteScheduled(id: id, deleteSessions: deleteSessions)
        setTarget(.newTask)
        draftName = ""
        draftPrompt = ""
        draftIsWaiting = false
        draftCondition = ""
        draftLog = ""
        handoffUpdatedAt = nil
        showWorkLog = false
    }
}
