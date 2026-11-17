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

    // 编辑目标 (P19: 收件档已删, 只剩计划任务一侧)
    @State private var target: EditorTarget = .newTask

    /// 切换编辑目标的**唯一写入口** (保留函数而非直接写 `target`: 语义仍是"换编辑对象")。
    private func setTarget(_ t: EditorTarget) { target = t }
    @State private var draftName: String = ""
    @State private var draftPrompt: String = ""
    @State private var draftCron: String = "0 9 * * *"
    @State private var draftProjectId: UUID?
    @State private var draftContinuous: Bool = false
    /// P19: 任务类型（Cron 定时 / 助理）。legacy 行不从草稿来 —— 它是 condition 派生的归档态。
    @State private var draftKind: TaskKind = .execute
    /// P19: 来源列表。**本版没有添加入口**（外部来源未接入，见 `sourcesCard` 的说明）——
    /// 留着它是因为老库/手改配置里可能有行, 界面对它们要**显示**而不是假装不存在。
    @State private var draftSources: [WatchSourceSpec] = []
    /// P19 S7 触达草稿。飞书 URL **不进草稿的落库路径** —— 保存时单独写钥匙串。
    @State private var draftNotifySystem: Bool = true
    @State private var draftNotifyEmail: String = ""
    @State private var draftNotifyWebhook: Bool = false
    /// 新填的 webhook 地址（空 = 不改）。已经在钥匙串里的那条永不回显 —— 见 `notifyCard`。
    @State private var draftWebhookInput: String = ""
    /// 钥匙串里现在有没有这条任务的地址（只判是否存在，不读内容到界面）。
    @State private var webhookStored: Bool = false
    @State private var draftBudget: String = ""
    @State private var notifyError: String? = nil
    @State private var hoveringId: UUID?
    // P9-#17: 无人值守恒开 (fire 不再读 task.unattended), 开关与确认弹窗已移除
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
    /// P19 收件箱: 展开中的那条结论（一次只展开一条 —— 多条同时展开会把列表顶没）。
    @State private var expandedFinding: UUID?
    /// P19 S6: 最近执行过的那一组是否展开。**默认收起**: 它是"回滚的入口"，不是待办 ——
    /// 天天摆在最上面就成了噪音（而收件箱的全部价值是"这里有事要你决定"）。
    @State private var showExecuted: Bool = false
    @State private var savedFlash: Bool = false

    /// 编辑器当前对象。计划任务侧原代码全按 `editingId` 读写, 这里由 target 派生 →
    /// 该侧 12 处使用零改动 (只有 3 处赋值点改成写 target)。
    private enum EditorTarget: Equatable {
        case newTask
        case task(UUID)
    }

    private var editingId: UUID? {
        if case .task(let id) = target { return id }
        return nil
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
        .onAppear { consumeFindingFocus() }
        // P19 S7: 通知点击可能发生在定时页**已经开着**的时候 ⇒ 那一次 `onAppear` 不会再触发,
        // 要靠 `onChange` 接住（与设置页 `pendingSettingsCategory` 同款）。
        .onChange(of: store.pendingFindingFocus) { _, _ in consumeFindingFocus() }
    }

    /// 取走"展开某条结论"的请求（通知点击放进来）。清空延到下一轮 runloop —— 见 ChatStore 那条注释。
    private func consumeFindingFocus() {
        guard let id = store.consumeFindingFocus() else { return }
        withAnimation(CodexTheme.animFast) { expandedFinding = id }
    }

    // MARK: - 列表

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("定时任务")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                // P19: 两档（Cron 定时 / 助理）。段选不再画在编辑器里而是**落在新建入口**:
                // 类型是"这条任务是什么", 在点 + 的那一刻就该定; 之后想改类型等于换一种东西,
                // 不该是一个随手可切的开关（切换会静默丢掉另一半字段的语义）。
                Menu {
                    Button("Cron 定时任务") { startNew(kind: .execute) }
                    Button("助理（目标式）") { startNew(kind: .assistant) }
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
                .help("新建：Cron 定时（动作写死）或 助理（目标式，只读巡检）")
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    if !openFindings.isEmpty { inboxSection }
                    if !executedFindings.isEmpty { executedSection }
                    if !store.missedFires.isEmpty { missedSection }
                    ForEach(store.scheduledTasks) { task in row(task) }
                    if store.scheduledTasks.isEmpty {
                        Text("暂无任务\n点右上角 + 新建")
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                }
                // 与 Knowledge 面板**共用侧栏那个常量** (2026-10-12) —— 两块面板同形并排,
                // 各写一个数字迟早会漂。面板标题那一行 (`SCHEDULED`) 两边本来就同款, 不动。
                .padding(.horizontal, Tune.sidebarContentInset)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - P19 findings 收件箱

    /// 只显 `open` 的结论（其余折叠）。**判据在 `FindingStatus.isInboxVisible`**，
    /// 视图不自己比字符串 —— 加一个状态时改一处就够。
    private var openFindings: [AgentFinding] {
        store.findings.filter { $0.status.isInboxVisible }
    }

    private func findingTaskName(_ f: AgentFinding) -> String {
        store.scheduledTasks.first { $0.id == f.taskId }?.name ?? L("未知任务")
    }

    /// 住定时任务列表**上方**、不新开主区面板（§03 拍板）: 它是低频、待处理的东西，
    /// 做成主面板就得天天空着，还得为它设计一套空态。没有待处理结论时**一个像素都不占**。
    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: "tray.full")
                    .font(.system(size: 9))
                    .foregroundStyle(CodexTheme.accent)
                Text("待处理")
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(CodexTheme.textMuted)
                Text("\(openFindings.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CodexTheme.accent)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 3)
            ForEach(openFindings) { f in findingRow(f) }
            Divider().overlay(CodexTheme.divider).padding(.vertical, 6)
        }
    }

    private func findingRow(_ f: AgentFinding) -> some View {
        let expanded = expandedFinding == f.id
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(CodexTheme.animFast) {
                    expandedFinding = expanded ? nil : f.id
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.title)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textPrimary)
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(findingTaskName(f))
                        Text("·")
                        // 方案步数比"严重度"有用: 人一看就知道点进去要不要做决定
                        Text(f.plan.isEmpty ? L("只有结论") : String(format: L("方案 %lld 步"), f.plan.count))
                        if f.planRev > 1 {
                            Text("·")
                            Text(String(format: L("第 %lld 版"), f.planRev))
                        }
                        Text("·")
                        Text(f.createdAt.relativeTag)
                    }
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(f.body)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let ev = f.evidence, !ev.isEmpty {
                        Text(ev)
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(f.plan, id: \.n) { step in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(step.n).")
                                .font(CodexTheme.fontTiny)
                                .foregroundStyle(CodexTheme.textMuted)
                                .frame(width: 16, alignment: .trailing)
                            Text(step.text)
                                .font(CodexTheme.fontSmall)
                                .foregroundStyle(CodexTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // P19 S6: 执行痕迹 —— 每一步过闸的结果。**只显有痕迹的那几步**:
                    // 一条只被看过的结论不该有一张空表（"没执行过"与"执行了但什么都没记"
                    // 在界面上必须能分开，前者不出现这一段）。
                    let acts = store.actions(for: f.id)
                    if !acts.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("执行痕迹")
                                .font(.system(size: 9, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(0.3)
                                .foregroundStyle(CodexTheme.textMuted)
                            ForEach(acts) { a in
                                HStack(alignment: .top, spacing: 5) {
                                    Text(a.step > 0 ? "\(a.step)." : "—")
                                        .font(CodexTheme.fontTiny)
                                        .foregroundStyle(CodexTheme.textMuted)
                                        .frame(width: 16, alignment: .trailing)
                                    Text(Self.actionText(a))
                                        .font(CodexTheme.fontTiny)
                                        // 颜色只给状态（主题那条规矩）: 过闸是中性的, 被拦才是状态。
                                        .foregroundStyle(a.result == "allowed" || a.result == "restored"
                                                         ? CodexTheme.textSecondary : CodexTheme.toolError)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    HStack(spacing: 6) {
                        // 「执行」= 人把这份方案授权给它。**不设「以后这类都自动」**（§03）:
                        // 授权粒度恒为"这一份方案的这几步"。
                        if f.status == .running {
                            Text("执行中…")
                                .font(CodexTheme.fontTiny)
                                .foregroundStyle(CodexTheme.blocked)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        } else if !f.plan.isEmpty {
                            Button(LK("采纳并执行")) {
                                _ = store.startFindingExecution(f.id)
                            }
                            .buttonStyle(.plain)
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .help("按这份方案执行；起手先做整轮快照，红线动作恒拒")
                        }
                        Button(LK("忽略")) {
                            store.setFindingStatus(f.id, status: .dismissed)
                        }
                        .buttonStyle(.plain)
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .help("从待处理里移除（不是解决 —— 结论本身留着）")
                        Spacer()
                        // 「追问」= 打开那个任务会话（它就是对话轮）。**不新开一个"问答框"**:
                        // 人的追问与巡检记录必须落在同一场会话里，否则「那个」指代的是什么
                        // 就成了猜 —— 而 `ephemeral: false` 正是为这件事存在的。
                        Button(LK("追问")) {
                            if let sid = store.scheduledTasks.first(where: { $0.id == f.taskId })?.logSessionId {
                                store.selectConversation(sid)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.info)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(expanded ? CodexTheme.bgElevated : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
    }

    /// 一行痕迹的人话。**动作名原样（bash / write）+ 结果说人话** ——
    /// 把工具名翻译成中文反而让人对不上会话里那张卡。
    static func actionText(_ a: FindingAction) -> String {
        let what: String
        switch a.result {
        case "allowed": what = L("已执行")
        case "denied_by_redline": what = L("被红线拦下")
        case "drifted": what = L("跑偏，已中止")
        case "restored": what = L("已从快照还原")
        default: what = a.result
        }
        let target = (a.target ?? "").replacingOccurrences(of: "\n", with: " ")
        let body = target.isEmpty ? what : "\(what) · \(target)"
        // 同一步过闸多次 = 一行里带个 ×N（`output` 就是干这个的，见落痕那一侧）。
        let times = a.output.map { " \($0)" } ?? ""
        return body + times
    }

    /// 已经跑过的结论（`resolved` / `failed`）—— **回滚的入口**。
    /// 只列有快照的: 没有快照的条目点了也回不去，摆出来只是给人一个点不动的按钮。
    private var executedFindings: [AgentFinding] {
        store.findings
            .filter { ($0.status == .resolved || $0.status == .failed) && ($0.undoPath?.isEmpty == false) }
            .sorted { ($0.decidedAt ?? $0.createdAt) > ($1.decidedAt ?? $1.createdAt) }
    }

    private var executedSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(CodexTheme.animFast) { showExecuted.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                        .foregroundStyle(CodexTheme.textMuted)
                    Text("最近执行")
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(CodexTheme.textMuted)
                    Text("\(executedFindings.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CodexTheme.textMuted)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showExecuted {
                ForEach(executedFindings) { f in executedRow(f) }
            }
        }
    }

    private func executedRow(_ f: AgentFinding) -> some View {
        HStack(spacing: 6) {
            Image(systemName: f.status == .resolved ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(f.status == .resolved ? CodexTheme.toolDone : CodexTheme.toolError)
            Text(f.title)
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            // 「回滚」= 把整轮快照解回去。**不改结论**（状态回 open）: 人回滚 = 承认这次没解决。
            Button(LK("回滚")) {
                _ = store.rollbackFinding(f.id)
            }
            .buttonStyle(.plain)
            .font(CodexTheme.fontTiny)
            .foregroundStyle(CodexTheme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .help("把这一轮改动还原成执行前的快照（7 天内可用）")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    /// P17 · 运行可靠性: 睡眠 / 长挂起期间的漏跑清单。**只在有漏跑时出现** —— 没有它时一个像素都不占。
    ///
    /// 口径 = 「该跑却没跑」（`SchedulerService.missedSummary`）。所以**不止睡眠**: 因并发满 /
    /// 该任务回合在途而被 `recordFireSkip` 跳过的也算 —— 它们同样是"这次没跑", 而且用户点开那个
    /// 日志会话能看到跳过原因。**项目已删的不算**（那不是漏跑, 是配置坏了, 有别的提示位）。
    private var missedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: L("漏跑 %lld 个任务"), store.missedFires.count))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CodexTheme.accent)
                .padding(.bottom, 2)
            Text(L("补跑只跑最近一次; 忽略 = 认下这批, 不再提示"))
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textMuted)
                .padding(.bottom, 6)
            ForEach(store.missedFires) { m in missedRow(m) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CodexTheme.radiusSm).fill(CodexTheme.bgCard))
        .overlay(RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
            .stroke(CodexTheme.accent.opacity(0.45), lineWidth: 0.5))
        .padding(.bottom, 6)
    }

    /// 漏跑单条: 任务名 + 档期/次数/最近 + 两个动作。
    private func missedRow(_ m: SchedulerService.MissedFire) -> some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(missedTaskName(m.taskId))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(CodexTheme.textPrimary)
                Text(missedDetail(m))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(CodexTheme.textSecondary)
            }
            Spacer(minLength: 2)
            Button(action: { store.catchUpMissedFire(m.taskId) }) {
                Text(L("补跑"))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("立刻补跑最近一次 (不等定时)")
            Button(action: { store.ignoreMissedFire(m.taskId) }) {
                Text(L("忽略"))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("认下这批漏跑, 不再提示")
        }
        .padding(.vertical, 4)
    }

    /// 副标题: 「每天 03:00 · 漏 2 次 · 最近 1d」。
    private func missedDetail(_ m: SchedulerService.MissedFire) -> String {
        guard let t = store.scheduledTasks.first(where: { $0.id == m.taskId }) else { return "" }
        return [CronExpr.describe(t.cron),
                String(format: L("漏 %lld 次"), m.count),
                String(format: L("最近 %@"), m.last.relativeTag)].joined(separator: " · ")
    }

    /// 任务名 —— 任务可能刚被删掉, 回落一个中性词而不是让整块清单崩掉。
    private func missedTaskName(_ id: UUID) -> String {
        store.scheduledTasks.first { $0.id == id }?.name ?? L("已删除的任务")
    }

    private func row(_ task: ScheduledTask) -> some View {
        let selected = isEditing(task)
        let hovered = hoveringId == task.id
        let icon = rowIcon(task)
        return HStack(spacing: 7) {
            Image(systemName: icon.name)
                .font(.system(size: 12))
                .foregroundStyle(icon.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(task.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .foregroundStyle(selected ? CodexTheme.textPrimary : (task.completedAt != nil ? CodexTheme.textMuted : CodexTheme.textSecondary))
                    if let mark = SchedulerService.rowMarker(task) {
                        markerView(mark, selected: selected)
                    }
                }
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
            // P19: 旧条件值守 = 只读归档 —— 不给「立即运行」、不给开关。
            // 两者都必须在**入口处**就不出现: `runScheduledFire` 里那道 guard 是**最后一道**,
            // 让按钮在、点了没反应, 比没有按钮更坏（用户会以为调度器坏了）。
            if !task.isLegacyWaiting {
                // P15.3: 「立即运行」**常显**（不做 hover-only）—— 藏起来的入口 = 没有入口,
                // 同常驻区那个 folder 按钮。它不抢眼靠的是颜色（未 hover 时与正文同级）。
                runNowButton(task, hovered: hovered)
                CodexMiniToggle(isOn: Binding(
                    get: { task.enabled },
                    set: { _ in store.toggleScheduled(id: task.id) }
                ))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.selected : (hovered ? CodexTheme.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? task.id : nil }
        .onTapGesture { loadDraft(task) }
    }

    /// P15.3: 「立即运行」。
    ///
    /// **零新逻辑** —— `runScheduledFire` 从来不看 `enabled`（到点投递那条循环才看,
    /// `schedulerTick` 里那句 `where task.enabled`）。所以"开关只管定时、手动随时可跑"
    /// 是既有语义, 这个按钮只是把它露出来。
    ///
    /// 不在回合在途时禁用: `runScheduledFire` 自己会落一条"因冲突跳过"的时间线,
    /// 禁用按钮反而会把那条记录藏起来（用户点了没反应, 却不知道为什么）。
    private func runNowButton(_ task: ScheduledTask, hovered: Bool) -> some View {
        Button(action: { store.runScheduledFire(task) }) {
            Image(systemName: "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(hovered ? CodexTheme.accent : CodexTheme.textMuted)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("立即运行 (不等定时; 关掉开关也能跑)")
    }

    /// 行首图标: 定时型 clock / 助理 sparkles / 旧条件值守（只读归档）警告三角
    /// P19: 等待型雷达图标随条件值守档一起退出 —— legacy 用三角明示「它已经不跑了」。
    private func rowIcon(_ task: ScheduledTask) -> (name: String, color: Color) {
        if task.isLegacyWaiting {
            return ("exclamationmark.triangle", CodexTheme.textMuted)
        }
        if task.kind == .assistant {
            return task.enabled ? ("sparkles", CodexTheme.accent) : ("sparkles", CodexTheme.textMuted)
        }
        return task.enabled ? ("clock.badge.fill", CodexTheme.toolDone) : ("clock.badge", CodexTheme.textMuted)
    }

    /// 行内标记（P15.6c · 2026-10-13 boss 定的「不可删的要看得出来」）—— 目前只有一种。
    ///
    /// **取舍不在这里**: `SchedulerService.rowMarker` 判"该显不该显", 这里只负责画
    /// （视图层只编译不执行, 判据只能落在那个纯函数上 —— 同 `canDelete` 那条）。
    /// **两处共用这一个 helper**（列表行 · 编辑器里那张只读指令卡片）—— 同一个东西必须长得一样,
    /// 两份实现迟早一份改了另一份没改。
    ///
    /// 三个刻意的选择（每个都能被问"为什么不那样"）:
    ///   ① **中性灰, 不用 `accent`**: 这套板子里 accent 的语义是"品牌 / 可点", 把锁染成它会读成按钮。
    ///   ② **不用 emoji 🔒**: emoji 是彩色固有色, 亮/暗主题下都不落在板子里（同"颜色是语义"那条）。
    ///   ③ **贴在名字后面跟着走**: 不占独立槽位; `.fixedSize()` 保证名字先截、锁留住 ——
    ///      名字是用户字段, 长到 20 字很常见（"我的整理助手 · 会话与笔记归档"）。
    @ViewBuilder
    private func markerView(_ mark: SchedulerService.RowMarker, selected: Bool) -> some View {
        switch mark {
        case .pinned:
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(selected ? CodexTheme.textSecondary : CodexTheme.textMuted)
                .fixedSize()
                .help("App 固定任务：不可删除；名字与档期照常可改")
        }
    }

    /// 三行版式 · L2 状态行 (扫一眼的高频信息; cron 无效红字提示)
    private func statusLine(_ task: ScheduledTask) -> String {
        if task.isLegacyWaiting { return L("旧类型 · 已停用（不再值守）") }
        if !cronValid(task) { return L("cron 无效") }
        var parts: [String] = []
        parts.append(CronExpr.describe(task.cron))   // "每天 09:00" 等人话描述 (识别不出=cron 原文)
        if task.isAssistant {
            // 助理的"跑了几次"不如"看了几条来源"有用 —— 它每轮都可能什么都不说
            parts.append(String(format: L("助理 · %lld 个来源"), task.activeSourceCount))
        }
        if !task.enabled {
            parts.append(L("已暂停"))
        } else if task.continuous && !task.isAssistant {
            parts.append(L("留痕"))
        }
        if task.runCount > 0 {
            parts.append(String(format: L("已跑 %lld 次"), task.runCount))
        } else if let last = task.lastRunAt {
            parts.append(String(format: L("上次 %@"), last.relativeTag))
        } else if parts.isEmpty {
            parts.append(L("待运行"))
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
        parts.append(task.cron)
        parts.append(L("无人值守"))   
        return parts.joined(separator: " · ")
    }

    private func cronValid(_ task: ScheduledTask) -> Bool { task.cronExpr != nil }
    private func isEditing(_ task: ScheduledTask) -> Bool { editingId == task.id }

    // MARK: - 编辑器

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                taskEditor
                    .id(editorIdentity)   // 换编辑对象 = 换实例 (草稿状态随之重建, 不串台)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: Tune.scheduleEditorMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 编辑器身份: 换编辑对象 ⇒ 换实例 (草稿状态随之重建, 不串台)。
    private var editorIdentity: String {
        switch target {
        case .newTask:      return "new-task"
        case .task(let id): return "task-\(id.uuidString)"
        }
    }

    private var taskEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlsRow
            nameField
            cronRow
            if isLegacyEditing, let t = editingTask() { legacyConditionCard(t) }
            promptCard
            if draftKind == .assistant { sourcesCard }
            if draftKind == .assistant { notifyCard }
            configCard   // P10.4: 任务级模型/级别/模式
            if editingId != nil && draftContinuous && draftKind == .execute {
                workLogCard
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            kindPill
            projectMenu
            unattendedPill
            // 工作日志开关只对 Cron 持续模式有意义: 助理档**恒**注入交接文件（它没有写权限，
            // 这一栏对它是只读的东西），把开关摆出来会让人以为能关掉它。
            if draftKind == .execute { continuousToggle }
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
            // ⚠️ P15.3 的 dream 任务**不可删**（2026-10-12 boss: "要固定死, 不能删除, 只能修改以及开关"）。
            //    所以这里**不渲染**删除按钮 —— 不是置灰: 置灰等于承诺"以后某个条件能满足", 而这个条件
            //    永远不会满足。判据走 `SchedulerService.canDelete`, 与域层那条守卫**同一个规则**。
            if let t = editingTask(), SchedulerService.canDelete(t) {
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
                .help(LK(draftReady ? "保存" : draftBlockReason))
        }
    }

    /// P19 类型徽章。**已保存的任务不可改类型**: 换类型等于换一种东西（`prompt` 的语义从
    /// 「动作」变成「目标」），允许随手切就会让一条跑了三个月的任务在某次编辑后语义反转。
    /// 新建草稿可以切（那时还没有任何历史可言），切换**保留**已填的名称与正文。
    private var kindPill: some View {
        Group {
            if editingId == nil {
                Menu {
                    Button("Cron 定时") { draftKind = .execute }
                    Button("助理（目标式）") { draftKind = .assistant }
                } label: { kindPillBody }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                kindPillBody
            }
        }
        .help(draftKind == .assistant
              ? "助理：到点只读巡检，产出结论等你批准（`prompt` 写目标，不是动作）"
              : "Cron 定时：到点执行 `prompt` 里写好的动作")
    }

    private var kindPillBody: some View {
        HStack(spacing: 4) {
            Image(systemName: draftKind == .assistant ? "sparkles" : "clock.arrow.circlepath")
                .font(.system(size: 10))
            Text(draftKind == .assistant ? LK("助理") : LK("Cron 定时"))
                .font(CodexTheme.fontSmall)
            if draftKind == .assistant {
                Text(LK("只读"))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(CodexTheme.info.opacity(0.16))
                    .foregroundStyle(CodexTheme.info)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if editingId == nil {
                Image(systemName: "chevron.down").font(.system(size: 8))
                    .foregroundStyle(CodexTheme.textMuted)
            }
        }
        .foregroundStyle(CodexTheme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 24)
        .background(CodexTheme.bgElevated)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(CodexTheme.border.opacity(0.5), lineWidth: 1))
    }

    /// 来源卡（仅助理档）。
    ///
    /// ⚠️ **本版刻意没有「添加来源」入口**：外部来源只剩邮件一条，而它要等 PEEK 实测
    /// （现有 poll 会置已读）—— 现在摆一个能加、加了却永远采不到的入口，就是
    /// 「看着像支持、配了不生效」。所以这一栏只做两件事：说清当前唯一的可用来源是**绑定项目**，
    /// 以及把库里已有的来源行**如实显示**（老库 / 手改配置里可能有 `kind` 不认识的行）。
    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text("来源")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
            }
            // 隐式来源: 项目
            HStack(spacing: 6) {
                Image(systemName: draftProjectId == nil ? "circle.dashed" : "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(draftProjectId == nil ? CodexTheme.textMuted : CodexTheme.accent)
                Text(projectLabel)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(draftProjectId == nil ? CodexTheme.textMuted : CodexTheme.textPrimary)
                Text("项目 · 只读查看")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(CodexTheme.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))

            ForEach(draftSources) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.isActive ? "tray.full" : "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(s.isActive ? CodexTheme.accent : CodexTheme.blocked)
                    Text(s.name)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text(s.isSupported ? LK("外部来源") : LK("不支持的类型"))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(s.isSupported ? CodexTheme.textMuted : CodexTheme.blocked)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CodexTheme.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
            }

            Text("助理至少要有项目这一条来源；外部来源（邮件）本版未接入 —— 它的只读采集要等「不置已读」验证通过。")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
        )
    }
    // MARK: - P19 S7 触达与预算

    /// 触达卡（仅助理档）：**怎么叫人**，与上面那张「看什么」正交。
    ///
    /// 三条写在这里的约束:
    ///   · 飞书地址**永不回显** —— 它是凭据。已配置只显示"已保存"，要换就整条重填。
    ///   · 邮件发件人是"第一个能发的账号"，不是每条任务选一次 —— 见 `firstSendableMailboxAccount`。
    ///   · 预算 0 = 不设限；超了是**跳过并落痕**，不换便宜模型（§04）。
    private var notifyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bell")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text("触达")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                if draftNotifySystem == false && draftNotifyEmail.isEmpty && !draftNotifyWebhook {
                    Text("全都关着 —— 结论只落在收件箱")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.blocked)
                }
            }

            Toggle(isOn: $draftNotifySystem) {
                Text("系统通知")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("弹系统通知；受「设置 → 通用 → 回合完成通知」总开关约束")

            // 邮件
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                TextField("邮件收件人（留空 = 不发）", text: $draftNotifyEmail)
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .frame(maxWidth: 280)
                Spacer()
                Text(senderHint)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(senderHintIsWarn ? CodexTheme.blocked : CodexTheme.textMuted)
            }

            // 飞书
            HStack(spacing: 8) {
                Image(systemName: "paperplane")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Toggle(isOn: $draftNotifyWebhook) {
                    Text("飞书机器人")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textPrimary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                if draftNotifyWebhook {
                    SecureField(webhookStored ? "已保存（不回显）—— 要换就整条重填" : "粘贴自定义机器人 webhook 地址",
                                text: $draftWebhookInput)
                        .textFieldStyle(.plain)
                        .font(CodexTheme.fontSmall)
                        .frame(maxWidth: 300)
                }
                Spacer()
                if webhookStored && draftNotifyWebhook {
                    Text("已保存")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.toolDone)
                }
            }

            // 预算
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text("日预算")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textPrimary)
                TextField("不限", text: $draftBudget)
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .frame(width: 90)
                Text("token / 天")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                if let id = editingId {
                    Text(String(format: L("今日已用 %lld"), store.tokenSpentToday(id)))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
            }
            if let e = notifyError {
                Text(e)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.toolError)
            }
            Text("外发只带标题与任务名，正文与证据留在 App 内。飞书地址存钥匙串，库里只有「配过」。")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
        )
    }

    /// 邮件发件人提示 —— **说清到底谁发**，否则"填了收件人但没收到"归因不了。
    private var senderHint: String {
        if let a = store.firstSendableMailboxAccount() {
            return String(format: L("发件: %@"), a.address)
        }
        return L("没有可发的账号 —— 设置 → 集成 → 邮箱账号")
    }

    private var senderHintIsWarn: Bool { store.firstSendableMailboxAccount() == nil }

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

    /// P19: 旧条件值守任务的触发条件 —— **只读展示**。
    /// 该档整体停用（无人授权自动执行那条路已拆），所以这里只负责让人看清它当年在等什么；
    /// 想继续用同一件事，请重建为助理（目标式任务）。
    private func legacyConditionCard(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原触发条件（旧类型 · 已停用，不再值守）")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            Text(task.condition ?? "")
                .font(CodexTheme.fontBody)
                .foregroundStyle(CodexTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CodexTheme.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                        .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
                )
        }
    }

    /// 正在编辑的是旧条件值守任务 —— 只读归档，不许保存。
    private var isLegacyEditing: Bool { editingTask()?.isLegacyWaiting == true }

    private func editingTask() -> ScheduledTask? {
        editingId.flatMap { id in store.scheduledTasks.first { $0.id == id } }
    }

    /// 正在编辑的是不是那条 dream。判据走域层**同一条规则**（`SchedulerService.isDreamTask`），
    /// 不在这里重写一遍 `id ==` —— 同 `canDelete` 那条注释里的理由。
    private var draftIsDream: Bool {
        guard let t = editingTask() else { return false }
        return SchedulerService.isDreamTask(t)
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
                    taskModelPicker    // 模型 + 思考强度合一 (2026-09-24; 原 configModelPicker + configThinkingPicker)
                    // ⚠️ `CodexPillMenu` 里是 `Menu(.borderlessButton)` —— **宽度是弹性的**。
                    // HStack 里没有任何东西吸收余量时它会一路撑到卡片最右, 于是"模式"看着比"模型"
                    // 宽出一大截 (2026-09-24 boss 截图实锤)。收窄靠 `fixedSize`, `Spacer` 兜住剩余量 ——
                    // 与设置页里同款手法。
                    configModePicker   // 模式**独立**保留 —— 它不是"模型链路"的一环
                        .fixedSize()
                    Spacer(minLength: 0)
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

    /// 任务级「模型 + 思考强度」(2026-09-24): 复用受控 `ModelPicker`, 替掉原先两个 `CodexPillMenu`。
    /// **值进值出**: 只吐 `onPick` 写进草稿, 绝不碰 `store.model.currentChoice` —— 这是
    /// 与 composer 药丸的**唯一**区别, 也是这段文案("不改变你当前会话")的技术含义。
    private var taskModelPicker: some View {
        ModelPicker(
            models: store.model.menuModels,
            // 传**解析后**的具体值而不是裸草稿: 控件没有"未指定"这个状态, 而 `taskChoice`
            // 把 nil 分量补成当前全局值 ⇒ 落档时三件套天然齐全 (级别不会被 `modelOverride` 丢掉)。
            choice: taskChoice,
            title: { m in
                store.model.customLabel(provider: m.provider, modelId: m.id) ?? m.label
            },
            fallbackTitle: taskFallbackTitle,
            // 与下方那行说明**逐字节同句** (含句末句号) —— 复用同一条译文, 免得同一句话出现两种译法。
            helpText: L("仅作用于本任务运行 (日志会话), 不改变你当前会话的模型与档位。"),
            pillChrome: true   // 嵌在 pill 行里 ⇒ 要真胶囊底 (默认裸标签是给 composer 底栏用的)
        ) { pick in
            draftProvider = pick.provider
            draftModelId = pick.modelId
            draftThinking = pick.level.rawValue
        }
    }

    /// 滑轨/药丸的显示值。⚠️ `draftThinking == nil` (旧库、或"设置自定义"开关刚打开) 时
    /// 按**当前全局档**落位 —— 控件表达不了"未指定"。**只有落过档才写回具体值**:
    /// 没动过的任务保存后仍是 nil, 与 `SessionConfig.thinkingLevel` 的"不钉死"约定一致。
    private var taskChoice: ModelChoice {
        ModelChoice(provider: draftProvider, modelId: draftModelId,
                    level: draftThinking.flatMap(ThinkingLevel.init(rawValue:))
                        ?? store.model.thinkingLevel)
    }

    /// 草稿模型不在 `menuModels` 里 (未配 / pi 尚未上报) 时的药丸文案。
    private var taskFallbackTitle: String {
        store.model.customLabel(provider: draftProvider, modelId: draftModelId)
            ?? (draftModelId.isEmpty ? L("选择模型") : draftModelId)
    }

    /// P13: 从原生 `Menu`(只显示一个名字) 换成共用自绘菜单 —— 才能在选择 codemode 时
    /// 看到"这一档会换掉工具调用范式"的代价说明 (`subtitle` 在原生 Menu 里会被剥掉)。
    /// ⚠️ 草稿仍按 `String`(rawValue) 存, 所以这里做一层双向转换 (改了草稿类型会牵动别处)。
    private var configModePicker: some View {
        AgentModePicker(mode: Binding(
            get: { AgentMode(rawValue: draftMode) ?? .standard },
            set: { draftMode = $0.rawValue })) {
            HStack(spacing: 4) {
                Image(systemName: "switch.2")
                Text(LK(AgentMode(rawValue: draftMode)?.displayName ?? "模式"))
            }
            .font(CodexTheme.fontSmall)
            .foregroundStyle(CodexTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(CodexTheme.bgPill)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
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

    /// 留痕开关 —— UI 叫「留痕」, 字段仍叫 `continuous`, 机制叫交接文件 (handoff)。
    /// 三个名字指向同一件事: 每次触发把上一轮的产出与工作日志带进来, 跑完再写回去。
    ///
    /// ⚠️ 2026-11-09 从「持续」改名（boss 原话: 这个词很容易误解, 有段时间没用就记不起来了）。
    ///    根因是原词描述的是**时间**（一直不停）, 而它管的是**记忆**（记得上一轮）——
    ///    名字指向错误的维度, 忘掉是必然的。别改回「持续 / 连续 / 循环」那一族。
    private var continuousToggle: some View {
        Button(action: { draftContinuous.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(draftContinuous ? CodexTheme.accent : CodexTheme.textMuted)
                Text("留痕")
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
        .help("每轮把进展留在工作日志里，下一轮接着它干")
    }

    private var nameField: some View {
        TextField("任务名称", text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: Tune.knowledgeTitleFontSize, weight: .semibold))
            .foregroundStyle(CodexTheme.textPrimary)
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
            cronEditor
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

    /// 指令那一栏。**dream 是只读的**（P15.6b）。
    ///
    /// 为什么必须只读, 而不是"能改但 fire 不看": 后者会让这一栏**在说谎** —— 用户改了、
    /// 保存了、界面还回显"已保存", 却没有任何效果。**能改的东西必须真的生效; 不生效的东西
    /// 必须看出来不能改**（同 `canDelete` 那条"可见性层与能力层同一个规则"）。
    @ViewBuilder
    private var promptCard: some View {
        if draftIsDream { dreamPromptCard } else { editablePromptCard }
    }

    /// dream 的指令 —— **出厂文案**: 随版本更新, 不落库、不随本任务保存。
    /// 只读展示 + 一句说明, 让"为什么改不了"有地方可查（否则看着像坏了）。
    private var dreamPromptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(SchedulerService.dreamPrompt)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(minHeight: 220)
            // P15.6c: 同一个锁标记, 与列表行共用 `markerView` —— 列表行那处答"为什么这条没有删除
            // 按钮", 这里答"为什么这栏是灰的"。两处问的不是同一件事, 所以都留。
            HStack(spacing: 5) {
                markerView(.pinned, selected: false)
                Text(LK("出厂指令 · 随版本更新；本任务能改的是档期、开关与执行配置"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
        )
    }

    private var editablePromptCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draftPrompt)
                .font(CodexTheme.fontBody)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 220)
            if draftPrompt.isEmpty {
                Text(LK(draftKind == .assistant
                        ? "到点要达成的目标（不是动作）——例：保证 CI 是绿的；红了就查清原因给我方案…"
                        : "到点投递给 Agent 的 prompt…"))
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

    /// 实际生效的 cron: 控件生成 (高级档直取 draftCron 原文)
    private var effectiveCron: String {
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
        !isLegacyEditing   // P19: 旧条件值守任务只读归档，不许保存
        && !draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty
        && CronExpr.parse(effectiveCron) != nil
        // P19 助理: 至少一条可用来源。本版的"可用"就是**绑定项目**（外部来源未接入），
        // 没有项目的助理到点会"采集全失败 ⇒ 不 spawn"，那是个到点就静默的配置错误 ——
        // 在保存这一刻拦住, 比让人三天后才发现任务从没跑过要好。
        && (draftKind != .assistant || draftProjectId != nil)
        // 名称可空: 留空自动取 prompt 首行; 项目可空: 落平铺 Chats (纯对话场景)
    }

    /// 保存不了时说明**是哪一条**不满足 —— 一句话兜全部的话, 人得自己猜。
    private var draftBlockReason: String {
        if isLegacyEditing { return "旧类型已停用，不能保存" }
        if draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty { return "prompt 与 cron 为必填" }
        if CronExpr.parse(effectiveCron) == nil { return "cron 无效" }
        if draftKind == .assistant && draftProjectId == nil {
            return "助理要绑定一个项目 —— 它是本版唯一可用的来源"
        }
        return "保存"
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

    private func startNew(kind: TaskKind = .execute) {
        setTarget(.newTask)
        draftName = ""
        draftPrompt = ""
        draftCron = "0 9 * * *"
        draftProjectId = store.activeProject?.id
        draftContinuous = false
        draftKind = kind
        draftSources = []
        draftNotifySystem = true
        draftNotifyEmail = ""
        draftNotifyWebhook = false
        draftWebhookInput = ""
        webhookStored = false
        draftBudget = ""
        notifyError = nil
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

    /// 工作日志区块 (P3.9 交接文件): agent 运行期写、用户可改, 磁盘为准; 保存即写回。
    ///
    /// ⚠️ 必须**收起 + 展开后定高** (2026-11-12): 外层是 `ScrollView`, 它给子视图提的可用高度是
    /// **无限** —— `TextEditor` 只给 `minHeight` 时会撑到整篇文字那么高, 交接日志越长整页越长,
    /// 最后把编辑器顶成一条。所以展开后给**定高**(内部自己滚), 收起时整块只剩一行。
    private var workLogCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(CodexTheme.animFast) { showWorkLog.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CodexTheme.textMuted)
                            .rotationEffect(showWorkLog ? .degrees(90) : .zero)
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
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if showWorkLog {
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
            }
            if showWorkLog {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draftLog)
                        .font(CodexTheme.fontBody)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(height: Tune.scheduleLogEditorHeight)
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
        // P15.6b: dream 的指令取出厂常量回填（那一栏只读）。**不读 `task.prompt`** ——
        // 库里那份是种任务时的副本, 可能已经过期; 回填旧文案会让只读的那一栏显示错误的指令。
        draftPrompt = SchedulerService.isDreamTask(task) ? SchedulerService.dreamPrompt : task.prompt
        draftCron = task.cron
        draftProjectId = task.projectId
        draftContinuous = task.continuous
        // P19: legacy 不是可编辑的类型（归档态）⇒ 编辑器按 Cron 呈现，但整页只读
        draftKind = task.isLegacyWaiting ? .execute : task.kind
        draftSources = task.sources
        draftNotifySystem = task.notify.system
        draftNotifyEmail = task.notify.emailTo ?? ""
        draftNotifyWebhook = task.notify.webhook
        // 钥匙串里那条**只判存在、不读出来** —— 读出来就等于把它摆进界面与截图的射程。
        webhookStored = store.hasWebhookURL(taskId: task.id)
        draftWebhookInput = ""
        draftBudget = task.dailyTokenBudget > 0 ? String(task.dailyTokenBudget) : ""
        notifyError = nil
        syncCronControls(task.cron)
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
        // S7: 触达与预算先校验 —— 校验不过就**整个保存都不做**（半保存会让"我以为改了"变成
        // "改了一半"，而触达配错的全部表现都是"没收到消息"）。
        guard let opts = validatedNotifyOptions() else { return }
        let budget = parsedBudget()
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
            // dream 的指令是**出厂常量**（P15.6b）⇒ 这一栏对它是只读的, 不把它当表单值回写。
            // 纵深: 域层 `updateScheduled` 对 dream 一律把 prompt 归一到**当前**常量 —— 即使有别的
            // 调用点绕过这里（批量编辑 / 导入配置）, 库里也长不出第二真源。两条各自的职责不同:
            // 这里管"表单不提交只读字段", 那里管"库里那份恒等于常量"。
            if !SchedulerService.isDreamTask(existing) { existing.prompt = draftPrompt }
            existing.cron = effectiveCron
            existing.projectId = draftProjectId
            existing.continuous = draftContinuous
            // P19: `condition` 不再由编辑器写入 —— 条件值守档已移除，旧值原样留在行上供查看。
            existing.unattended = true   // P9-#17: 恒无人值守, 字段仅作记录
            existing.config = buildDraftConfig()   // P10.4: 任务级执行配置
            // P19: `kind` **不回写** —— 已保存任务的类型不可改（见 `kindPill` 的注释）。
            // 来源照写: 本版界面不能改来源, 但库里已有的行必须原样留住, 否则一次编辑就静默清空。
            existing.sources = draftSources
            existing.notify = opts
            existing.dailyTokenBudget = budget
            store.updateScheduled(existing)
            writeWebhookSecret(taskId: id)
        } else {
            let cron = effectiveCron
            store.addScheduled(name: draftName, prompt: draftPrompt,
                               cron: cron, projectId: draftProjectId,
                               continuous: draftContinuous,
                               kind: draftKind, sources: draftSources)
            // 无人值守附加字段 (addScheduled 无全参入口, 保存后回填)
            if let idx = store.scheduledTasks.indices.last {
                store.scheduledTasks[idx].unattended = true   // P9-#17: 恒无人值守
                store.scheduledTasks[idx].config = buildDraftConfig()   // P10.4
                store.scheduledTasks[idx].notify = opts
                store.scheduledTasks[idx].dailyTokenBudget = budget
                store.updateScheduled(store.scheduledTasks[idx])
                writeWebhookSecret(taskId: store.scheduledTasks[idx].id)
            }
        }
        // "✓ 已保存"短闪 (与代码块"已复制"同模式)
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    /// 触达草稿 → `NotifyOptions`。nil = 校验不过（错误已写进 `notifyError`）。
    private func validatedNotifyOptions() -> NotifyOptions? {
        notifyError = nil
        var opts = NotifyOptions()
        opts.system = draftNotifySystem
        let to = draftNotifyEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        opts.emailTo = to.isEmpty ? nil : to
        opts.webhook = draftNotifyWebhook
        if draftNotifyWebhook {
            let raw = draftWebhookInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                guard raw.hasPrefix("https://"), URL(string: raw) != nil else {
                    notifyError = L("飞书地址要以 https:// 开头")
                    return nil
                }
                if !WatchNotifyService.looksLikeFeishuHook(raw) {
                    // 只提示不拦: 自建中转也会是别的域名, 拦掉就把那条路堵死了。
                    notifyError = L("这个域名不像飞书 —— 确认后再保存也行（自建中转可以）")
                }
            } else if !webhookStored {
                notifyError = L("飞书开着, 但还没有地址 —— 粘贴一条自定义机器人的 webhook")
                return nil
            }
        }
        return opts
    }

    /// 预算草稿 → 整数。空 / 非数字 → 0（不设限）。不拦保存: 这个字段写歪了人一眼能看出来
    /// （"不限"），而拦下整个保存的代价是别的改动也一起丢了。
    private func parsedBudget() -> Int {
        Int(draftBudget.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// 只在**填了新地址**时写钥匙串；关掉飞书开关**不清地址** ——
    /// 开关表达的是"要不要发"，不是"要不要存"。清掉之后人再打开就得去飞书重抄一遍，
    /// 而那不是他的意思。
    private func writeWebhookSecret(taskId: UUID) {
        let raw = draftWebhookInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        store.setWebhookURL(raw, taskId: taskId)
        if store.hasWebhookURL(taskId: taskId) {
            webhookStored = true
            draftWebhookInput = ""   // 存完就不在界面上留一份
        } else {
            notifyError = L("地址没能写进钥匙串 —— 飞书这一路会发不出去")
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
        draftLog = ""
        handoffUpdatedAt = nil
        showWorkLog = false
    }
}
