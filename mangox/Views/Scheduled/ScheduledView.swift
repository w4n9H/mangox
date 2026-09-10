//
//  ScheduledView.swift
//  P3.6 本地定时任务管理面板 (主区切换视图)。
//  视觉语言与 KnowledgeView 一致: 左列 Sidebar 行语言 + 编辑区 Composer 输入卡语言。
//  cron 第一版纯文本框 (分 时 日 月 周), 友好录入留后。
//

import SwiftUI

struct ScheduledView: View {
    @ObservedObject var store: ChatStore

    // 编辑草稿 (editingId == nil 表示新建)
    @State private var editingId: UUID?
    @State private var draftName: String = ""
    @State private var draftPrompt: String = ""
    @State private var draftCron: String = "0 9 * * *"
    @State private var draftProjectId: UUID?
    @State private var draftContinuous: Bool = false
    @State private var hoveringId: UUID?
    // P3.10 哨兵任务: 类型段选 / 触发条件 / 无人值守 / 检查频率三档
    @State private var draftIsWaiting: Bool = false
    @State private var draftCondition: String = ""
    @State private var draftUnattended: Bool = true
    @State private var draftFrequency: FrequencyKind = .low
    @State private var showUnattendedConfirm: Bool = false
    // 工作日志 (P3.9 交接文件): 编辑器内嵌可编辑区块, 磁盘为准
    @State private var draftLog: String = ""
    @State private var handoffUpdatedAt: Date?
    @State private var showWorkLog: Bool = false
    // 操作反馈: 删除二次确认 / 保存成功闪现
    @State private var showDeleteConfirm: Bool = false
    @State private var savedFlash: Bool = false

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
                Button(action: startNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新建任务")
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(store.scheduledTasks) { task in
                        row(task)
                    }
                    if store.scheduledTasks.isEmpty {
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
        .background(selected ? CodexTheme.bgElevated : (hovered ? CodexTheme.bgElevated.opacity(0.5) : Color.clear))
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

    /// 三行版式 · L2 状态行 (扫一眼的高频信息; cron 无效红字提示)
    private func statusLine(_ task: ScheduledTask) -> String {
        if !cronValid(task) { return "cron 无效" }
        var parts: [String] = []
        if task.condition?.isEmpty == false {
            if let done = task.completedAt {
                parts.append("已触发 · \(done.relativeTag)")
            } else if task.enabled {
                parts.append("值守中 · \(FrequencyKind.from(cron: task.cron).shortLabel)")
            } else {
                parts.append("已暂停")
            }
        } else {
            if !task.enabled {
                parts.append("已暂停")
            } else if task.continuous {
                parts.append("持续")
            }
            if task.runCount > 0 {
                parts.append("已跑 \(task.runCount) 次")
            } else if let last = task.lastRunAt {
                parts.append("上次 \(last.relativeTag)")
            } else if parts.isEmpty {
                parts.append("待运行")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// 三行版式 · L3 上下文行 (mono 次要信息)
    private func contextLine(_ task: ScheduledTask) -> String {
        var parts: [String] = []
        if let pid = task.projectId {
            parts.append(store.projects.first { $0.id == pid }?.title ?? "未知项目")
        } else {
            parts.append("无项目")
        }
        parts.append(task.condition?.isEmpty == false ? FrequencyKind.from(cron: task.cron).cron : task.cron)
        if task.unattended { parts.append("无人值守") }
        return parts.joined(separator: " · ")
    }

    private func cronValid(_ task: ScheduledTask) -> Bool { task.cronExpr != nil }
    private func isEditing(_ task: ScheduledTask) -> Bool { editingId == task.id }

    // MARK: - 编辑器

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                controlsRow
                nameField
                cronRow
                if draftIsWaiting { conditionCard }
                promptCard
                if editingId != nil && (draftContinuous || draftIsWaiting) {
                    workLogCard
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: Tune.knowledgeEditorMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .confirmationDialog("开启无人值守？", isPresented: $showUnattendedConfirm) {
            Button("开启无人值守") { draftUnattended = true }
        } message: {
            Text("无人值守下 Agent 将不经确认执行文件写入与命令（含 bash）。任务执行过程可在任务日志中审计。")
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            kindSelector
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
            Button(savedFlash ? "✓ 已保存" : "保存") { saveEditing() }
                .buttonStyle(CodexActionButtonStyle(
                    kind: savedFlash ? .success : .primary,
                    disabled: !draftReady))
                .disabled(!draftReady || savedFlash)
                .help(draftReady ? "保存" : (draftIsWaiting ? "触发条件与动作为必填" : "prompt 与 cron 为必填"))
        }
    }

    /// P3.10 类型段选: 定时 (cron 驱动) / 哨兵 (条件驱动, Sentinel)
    private var kindSelector: some View {
        HStack(spacing: 4) {
            kindPill("定时", active: !draftIsWaiting)
            kindPill("哨兵", active: draftIsWaiting)
        }
        .padding(2)
        .background(CodexTheme.bgElevated)
        .clipShape(Capsule())
    }

    private func kindPill(_ title: String, active: Bool) -> some View {
        Button(action: {
            draftIsWaiting = (title == "哨兵")
            if draftIsWaiting { draftFrequency = FrequencyKind.from(cron: draftCron) }
        }) {
            Text(title)
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
    }

    /// P3.10 无人值守开关 (默认开): 开启时弹风险确认
    private var unattendedPill: some View {
        Button(action: {
            if draftUnattended {
                draftUnattended = false
            } else {
                showUnattendedConfirm = true
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10))
                    .foregroundStyle(draftUnattended ? CodexTheme.accent : CodexTheme.textMuted)
                Text("无人值守")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(draftUnattended ? CodexTheme.textPrimary : CodexTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(height: 24)
            .background(draftUnattended ? CodexTheme.accentSoft : Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("无人值守: fire 回合不经确认执行工具调用 (含 bash), 执行过程见任务日志")
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

    private var projectMenu: some View {
        Menu {
            Button("无项目（纯对话）") { draftProjectId = nil }
            ForEach(store.projects) { p in
                Button(p.title) { draftProjectId = p.id }
            }
        } label: {
            Text(projectLabel)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(CodexTheme.bgPill)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
    }

    private var projectLabel: String {
        guard let pid = draftProjectId else { return "无项目（纯对话）" }
        return store.projects.first { $0.id == pid }?.title ?? "选择项目"
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

    /// P3.10 哨兵任务检查频率三档 (内部映射 cron, 调度器零改动)
    enum FrequencyKind: String, CaseIterable, Identifiable {
        case high, medium, low
        var id: String { rawValue }
        var cron: String { switch self {
        case .high: "*/5 * * * *"
        case .medium: "*/15 * * * *"
        case .low: "*/30 * * * *"
        } }
        var label: String { switch self {
        case .high: "高 · 每 5 分钟"
        case .medium: "中 · 每 15 分钟"
        case .low: "低 · 每 30 分钟"
        } }
        /// 状态行简短版 (不带档位词)
        var shortLabel: String { switch self {
        case .high: "每 5 分钟"
        case .medium: "每 15 分钟"
        case .low: "每 30 分钟"
        } }
        static func from(cron: String) -> FrequencyKind {
            allCases.first { $0.cron == cron } ?? .low
        }
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
                TextField("分 时 日 月 周", text: $draftCron)
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontMono)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(CodexTheme.bgElevated)
                    .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
                    .frame(width: 200)
                Text("例: 0 9 * * 1-5 = 工作日 09:00 · */30 * * * * = 每 30 分钟")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer()
        }
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
                Text(draftIsWaiting ? "条件触发后要执行的动作…" : "到点投递给 Agent 的 prompt…")
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

    private var draftReady: Bool {
        !draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty
        && (!draftIsWaiting || CronExpr.parse(draftFrequency.cron) != nil)
        && (!draftIsWaiting || !draftCondition.trimmingCharacters(in: .whitespaces).isEmpty)
        // 名称可空: 留空自动取 prompt 首行; 项目可空: 落平铺 Chats (纯对话场景)
    }

    // MARK: - 草稿动作

    private func startNew() {
        editingId = nil
        draftName = ""
        draftPrompt = ""
        draftCron = "0 9 * * *"
        draftProjectId = store.activeProject?.id
        draftContinuous = false
        draftIsWaiting = false
        draftCondition = ""
        draftUnattended = true
        draftLog = ""
        handoffUpdatedAt = nil
        showWorkLog = false
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
        editingId = task.id
        draftName = task.name
        draftPrompt = task.prompt
        draftCron = task.cron
        draftProjectId = task.projectId
        draftContinuous = task.continuous
        draftIsWaiting = task.condition?.isEmpty == false
        draftCondition = task.condition ?? ""
        draftUnattended = task.unattended
        draftFrequency = FrequencyKind.from(cron: task.cron)
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
            draftName = String(draftPrompt.split(separator: "\n").first?.prefix(24) ?? "任务")
        }
        if let id = editingId,
           var existing = store.scheduledTasks.first(where: { $0.id == id }) {
            existing.name = draftName
            existing.prompt = draftPrompt
            existing.cron = draftIsWaiting ? draftFrequency.cron : draftCron
            existing.projectId = draftProjectId
            existing.continuous = draftContinuous
            existing.condition = draftIsWaiting && !draftCondition.trimmingCharacters(in: .whitespaces).isEmpty
                ? draftCondition : nil
            existing.unattended = draftUnattended
            store.updateScheduled(existing)
        } else {
            let cron = draftIsWaiting ? draftFrequency.cron : draftCron
            store.addScheduled(name: draftName, prompt: draftPrompt,
                               cron: cron, projectId: draftProjectId,
                               continuous: draftContinuous)
            // 等待型/无人值守附加字段 (addScheduled 无全参入口, 保存后回填)
            if let idx = store.scheduledTasks.indices.last {
                store.scheduledTasks[idx].condition = draftIsWaiting && !draftCondition.trimmingCharacters(in: .whitespaces).isEmpty
                    ? draftCondition : nil
                store.scheduledTasks[idx].unattended = draftUnattended
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

    private func deleteEditing(deleteSessions: Bool) {
        guard let id = editingId else { return }
        store.deleteScheduled(id: id, deleteSessions: deleteSessions)
        editingId = nil
        draftName = ""
        draftPrompt = ""
        draftIsWaiting = false
        draftCondition = ""
        draftLog = ""
        handoffUpdatedAt = nil
        showWorkLog = false
    }
}
