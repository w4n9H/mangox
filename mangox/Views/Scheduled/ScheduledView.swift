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
    /// P19 S7 触达草稿。**飞书不在这里** —— 它由「入口 · 飞书」那个机器人决定
    /// （2026-11-17 群 webhook 删掉之后，触达只剩系统通知与邮件）。
    /// P19.2 S15b: 这个助理挂在**哪一个**飞书机器人上。`nil` = 只能在 MangoX 里用。
    ///
    /// **1:1**（2026-11-17 boss 定）: 一个机器人只归一个助理，一个助理也只有一个机器人 ——
    /// 于是「一场会话」的含义才干净（一个入口 = 一场对话）。想要第二个入口就再建一个助理。
    @State private var draftBotId: UUID? = nil
    @State private var draftBudget: String = ""
    /// 2026-11-23: 「模型一天最多能自主调度几次」。**草稿里恒是生效值**（不是 nil）——
    /// 编辑器没有"未指定"这个状态，而 `nil` 与 `0` 的区别只在库里那一位上有意义
    /// （见 `ScheduledTask.followUpsPerDay` 的三态）。新建助理从出厂默认起步。
    @State private var draftFollowUpsPerDay: Int = ScheduledTask.factoryFollowUpsPerDay
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
    /// 台账卡的**已解析**快照（P19.2 S13）。
    ///
    /// ⚠️ 为什么要有这两个 @State（2026-11-18 review）: 原来 `ledgerCard` 每次 body 求值都
    /// `readHandoff`（一次 `contentsOfFile` + 一次 `attributesOfItem`），而它长在编辑器里 ——
    /// 编辑器的 `draftName/draftPrompt/...` 全是 @State ⇒ **每敲一个字符读一次盘**，
    /// 拿到原文之后卡里还要再 `parse` 六遍。现在读盘与解析都只发生在
    /// "打开/切换任务"与"这个任务又跑过一轮"这两个时点（`refreshLedger`）。
    @State private var ledgerParsed: AssistantLedger = .init()
    @State private var ledgerUpdatedAt: Date?
    /// 2026-11-23:「已发消息」预览。**与 `ledgerParsed` 同一个理由** —— 它也是一次 DB 查询，
    /// 而这张卡长在编辑器里（每个字段都是 `@State`）⇒ 在 body 里查就是"每敲一个字查一次库"。
    /// 只在打开编辑器 / 这个任务又跑过一轮时刷（`refreshSent`）。
    @State private var sentRows: [SentMessage] = []
    // P10.4 任务级执行配置 (2026-11-20 起是**必须项**: cron/助理 一建就钉住, 不再有"跟随全局")
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
            // P19.2 S15 前置: 助理**没有"保留会话"这个选项** —— 成对删除。三个选项里
            // "保留"对助理是骗人的：任务一没，那场会话就不再注入目标、不再给写权限，
            // 也不再认得"那个"。摆那个按钮等于让人以为还能留着用。
            if editingTask()?.kind == .assistant {
                Button(LK("删除助理（连同工作会话与账本）"), role: .destructive) {
                    deleteEditing(deleteSessions: true)
                }
            } else {
                Button("删除任务 (保留会话与工作日志)") { deleteEditing(deleteSessions: false) }
                Button("删除任务和日志会话", role: .destructive) { deleteEditing(deleteSessions: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if editingTask()?.kind == .assistant {
                Text("助理「\(draftName)」连同它的工作会话与账本文件一起删除；巡检停止，账本无法恢复。")
            } else {
                Text("任务删除后停止调度。工作日志文件始终保留; 日志会话可选删除。")
            }
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
                .help("新建：Cron 定时（动作写死）或 助理（目标式，产方案等人批准）")
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

    /// 卡片副行那一段（方案几笔 / 等你决定 / 只有结论）。
    ///
    /// 空方案**不等于**「只有结论」：`## 待你决定` 落下来的那些正是**在等人回答**，
    /// 两个情况写同一个标签，人会把它当成一条通知划过去（2026-11-18 boss 提的）。
    ///
    /// 判据看的是 `evidence` 那枚落库标记（`WatchFindingService.waitingEvidence`），
    /// **不是**标题文案 —— 标题是模型写的，会变。那枚标记恒中文、不本地化，两边都不用翻译。
    private func findingPlanLabel(_ f: AgentFinding) -> String {
        if !f.plan.isEmpty { return String(format: L("方案 %lld 步"), f.plan.count) }
        return f.evidence == WatchFindingService.waitingEvidence ? L("等你决定") : L("只有结论")
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
                        Text(findingPlanLabel(f))
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
            // 解压在后台做（大项目几秒起步），结果走顶部横幅 —— 这里不等返回值。
            Button(LK("回滚")) {
                store.rollbackFinding(f.id)
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
        // 2026-11-23: 它自己约的那一次。放在"跑了几次"**之前** —— "14:30 还会回来"比"已跑 12 次"
        // 更影响人此刻的判断；没有约就不出现（大多数任务永远没有这一行）。
        if let f = store.nextFollowUp(for: task.id) {
            parts.append(String(format: L("约了 %@ 回看"), followUpTag(f.dueAt)))
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

    /// 2026-11-23: 回看时刻的人话。今天只写 `14:30`，明天加「明天」，再远给 `11/26 09:00`。
    /// **不写整日期**的理由: 这一行是三行版式里的 L2（扫一眼的），一个 `2026-11-26 09:00`
    /// 会把"每天 09:00 · 约了… · 已跑 3 次"挤成换行，而多出来的年份一个字都没用。
    private func followUpTag(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if cal.isDateInToday(date) { return f.string(from: date) }
        if cal.isDateInTomorrow(date) { return L("明天") + " " + f.string(from: date) }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }
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
            // 助理**没有**手填目标（2026-11-17 boss: "助理的目标来自我的下发"）：
            // 目标要么在会话里说，要么 cron 巡检时从账本里长出来 —— 编辑框里写死一个
            // 静态目标，与"每轮下发"直接冲突。Cron 档不变（它的 prompt 是**指令**）。
            // ⚠️ dream 例外：它是助理，但指令是出厂常量，必须看得见（否则"为什么改不了"无处可查）。
            if draftIsDream { dreamPromptCard } else if draftKind != .assistant { editablePromptCard }
            // 来源卡只在**真有外部来源**时出现。本版没有添加入口（外部来源未接入），
            // 所以它平时是空的；而在助理档显示一行"项目 · 只读查看"是个陷阱 ——
            // 项目在顶栏那颗 pill 里选，这块既点不动又和实现矛盾（见 saveBlocker）。
            if draftKind == .assistant, !draftSources.isEmpty { sourcesCard }
            // 台账常驻（2026-11-18 晚）: 占的正是原来「触达」那一格 —— 那张卡删了（boss 定的
            // "移除触达及相关功能"），而台账是助理档唯一一个"我要随时看见"的东西。
            if draftKind == .assistant, editingTask() != nil { ledgerCard }
            // 2026-11-23: 台账下面那一张 —— 「它最近往外发过什么」（boss 定，紧挨台账）。
            if draftKind == .assistant, editingTask() != nil { sentCard }
            if draftKind == .assistant { remoteCard }
            // 2026-11-23: 「模型自主调度」配额。**独立一张小卡，紧挨在「模型与模式配置」之前**
            // （boss 定: 不要塞进那张卡里）。只对助理档显示 —— Cron 档的周期是人定的，
            // 让模型自己往里插时间点等于改写人定的东西（生效值恒 0，见 `ScheduledTask`）。
            if draftKind == .assistant { followUpCard }
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
              ? "助理：到点看一轮，产出带编号的方案等你批准（`prompt` 写目标，不是动作）"
              : "Cron 定时：到点执行 `prompt` 里写好的动作")
    }

    private var kindPillBody: some View {
        HStack(spacing: 4) {
            Image(systemName: draftKind == .assistant ? "sparkles" : "clock.arrow.circlepath")
                .font(.system(size: 10))
            Text(draftKind == .assistant ? LK("助理") : LK("Cron 定时"))
                .font(CodexTheme.fontSmall)
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
    /// 外部来源列表（仅助理档，且**只在真的有来源时出现**）。
    ///
    /// ⚠️ 2026-11-17 boss 报「来源那里点不了」—— 原来这张卡第一行画的是"项目 · 只读查看"，
    /// 那**不是一个控件**：项目是在顶栏那颗 pill 里选的，这里只是复述它。摆一块看着能点、
    /// 点下去毫无反应的东西，比不摆更坏。现在项目只住在顶栏，这张卡只管外部来源；
    /// 而本版没有添加入口（外部来源未接入），所以助理档平时根本看不到它。
    ///
    /// 那句"助理至少要有项目这一条来源"也一起删了 —— 它与 `saveBlocker` 直接矛盾
    /// （那里 2026-11-17 已放宽成"可以没有项目"）。文件说明与判据不一致时，人只会信界面上那句。
    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text("外部来源")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
            }

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

            Text("外部来源（邮件）本版未接入 —— 它的只读采集要等「不置已读」验证通过。")
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
    // MARK: - P19.2 S13 台账（常驻卡）

    /// 台账卡（仅助理档）：**不用点，进来就看得见**。
    ///
    /// 2026-11-18 晚（boss）：原来这里是「触达」那张卡（系统通知 / 邮件 / 日预算），
    /// 整张删掉 —— 触达的配置入口没有意义（飞书推不推由「入口」绑没绑机器人决定，
    /// 系统通知跟全局开关走），而台账是这个助理**唯一的现状视图**。
    ///
    /// 只对**已保存的助理**出现：草稿还没有账本文件，摆一张必空的卡等于骗人。
    /// 渲染与高度上限都在 `AssistantLedgerCard` 里（含"五节"的结构 —— 结构归
    /// `AssistantLedger`，这一层不许再写一份认节头的逻辑）。
    private var ledgerCard: some View {
        // 读法与 fire 同源（`readHandoff` 里含 S9 的新旧位置回落）——
        // 这里若自己拼路径，显示的就不是模型正在写的那一份。
        // ⚠️ 读盘与解析**不在 body 里**（见 `ledgerParsed` 的声明处）。
        // `lastRunAt` 变了 = 这个助理又跑过一轮 ⇒ 账本可能刚被改写，刷一次。
        AssistantLedgerCard(ledger: ledgerParsed, updatedAt: ledgerUpdatedAt)
            .onChange(of: editingTask()?.lastRunAt) { _, _ in refreshLedger() }
    }

    /// 重新读一次账本并解析（打开编辑器 / 手动刷新 / 这个任务刚跑过）。
    /// 返回原文 —— 工作日志卡（Cron 档）与台账卡（助理档）**同源**，一次读盘供两处用。
    @discardableResult
    private func refreshLedger() -> (content: String, updatedAt: Date?)? {
        guard let t = editingTask() else {
            ledgerParsed = .init()
            ledgerUpdatedAt = nil
            return nil
        }
        let h = store.scheduler.readHandoff(for: t)
        ledgerParsed = AssistantLedger.parse(h?.content ?? "")
        ledgerUpdatedAt = h?.updatedAt
        return h
    }

    // MARK: - 2026-11-23 「已发消息」预览

    /// 它最近往外发过的几条（只**预览**，点不进详情 —— 详情就是飞书那边那条消息本身）。
    ///
    /// 为什么不显示 `queued`：那一档的意思是"交出去了，回执还没来"（桥可能已经崩了）。
    /// 显示成"已发"是撒谎，显示成"发送中"是一句永远不结束的话 ⇒ 干脆不显示。
    /// `failed` 照显示并**明说没发出去** —— 那是一条真实发生过的事，藏起来比显示更难解释。
    private var sentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text(L("已发消息"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                if !sentRows.isEmpty {
                    Text(String(format: L("最近 %lld 条"), sentRows.count))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
            }
            if sentRows.isEmpty {
                Text(L("还没往外发过东西。它第一次给你发消息之后，这里会出现最近几条。"))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(sentRows) { m in
                    sentRow(m)
                }
            }
            // ⚠️ 一句话**必须写在同一个字符串字面量里** —— 用 `+` 拼两段时取词门会把两段
            // 各算一个 key（实测：一进词表就变成「未翻译 2 + 废弃 1」）。
            Text(L("只记它发出去的（飞书私聊 / 文件），不记系统通知。这份记录也会注入给模型，让它知道哪些话已经说过了。"))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
        )
        .onChange(of: editingTask()?.lastRunAt) { _, _ in refreshSent() }
    }

    private func sentRow(_ m: SentMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sentClock(m.at))
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textMuted)
                .frame(width: Tune.scheduleSentTimeWidth, alignment: .leading)
            Text(sentKindLabel(m.kind))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            Text(m.text)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(m.status == .failed ? CodexTheme.textMuted : CodexTheme.textSecondary)
                .lineLimit(2)
            if m.status == .failed {
                Text(L("没发出去"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.blocked)
            }
            Spacer(minLength: 0)
        }
    }

    /// 预览行里的时间：今天只给时刻，昨天/更早给相对说法。**与注入段同一套口径**
    /// （`SchedulerService.sentTag`）—— 两处口径分叉时，人看到的和模型看到的不一样。
    private func sentClock(_ at: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if cal.isDate(at, inSameDayAs: Date()) { return f.string(from: at) }
        if cal.isDateInYesterday(at) { return L("昨天") + " " + f.string(from: at) }
        f.dateFormat = "M/d"
        return f.string(from: at)
    }

    /// ⚠️ UI 这一份必须走 `L()` —— `SentKind.tag` 是**注入面**的恒中文说法（同 `[笔记]` 那一族），
    /// 直接拿来上界面就是一处静默漏译。
    private func sentKindLabel(_ k: SentKind) -> String {
        switch k {
        case .reply: return L("回复")
        case .push: return L("结论")
        case .file: return L("文件")
        }
    }

    /// 与 `refreshLedger` 同一个调用点（打开编辑器 / `lastRunAt` 变了）。
    private func refreshSent() {
        guard let id = editingId else { sentRows = []; return }
        sentRows = store.recentSent(taskId: id)
    }

    // MARK: - P19.2 S15b 入口（飞书机器人）

    /// 入口卡（仅助理档）：**哪个机器人把这个助理接进飞书**。
    ///
    /// 为什么绑定在助理这边而不是机器人那边: 「归谁」是这个助理的属性（"我的工作号归
    /// 日报助理"），在机器人列表里配会变成"一张全局对照表"，改一个助理要跑到另一页去翻。
    ///
    /// ⚠️ **1:1，两端都是**：一个机器人只归一个助理（`remote_bots.assistant_id` 单值列保证），
    /// 一个助理也只挂一个机器人（这里单选 + 域层 `assignRemoteBot` 顶掉旧的）。
    /// 已被别人占着的机器人不会静默搬过来 —— 它显示「已归 X」并给一个显式的
    /// 「改归本助理」。S15 那版是保存时悄悄摘走，症状是"我明明绑给它了，它不回"。
    ///
    /// ⚠️ 选择**进草稿**，保存才落库（与这一页其他字段同一条规矩：取消 = 什么都没发生）。
    private var remoteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text("入口 · 飞书")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                if store.remoteBots.isEmpty {
                    Text("没有机器人（设置 → 集成 → 飞书机器人）")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.blocked)
                } else if draftBotId == nil {
                    Text("没选 —— 只能在 MangoX 里用它")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
            }

            ForEach(store.remoteBots) { bot in
                botRow(bot)
            }

            Text("点一行就选中它（选中后要点右上角「保存」才生效）。选中的机器人收到的话会直接进这个助理的会话，回复原路发回飞书。群聊不接（只做单聊）。机器人没有自己的开关 —— 助理关着它就**不连**，飞书那边输入框会变灰。")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
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

    private func botRow(_ bot: RemoteBot) -> some View {
        // 「归谁」判的是**库里**的归属，不是草稿 —— 点完「不归它」但还没保存时，
        // 这一行必须回到"可选"的样子；否则它会说自己「已归：本助理」还劝你「改归本助理」。
        let selfId = editingTask()?.id
        let ownerName = bot.assistantId.flatMap { owner in
            store.scheduledTasks.first { $0.id == owner }?.name
        }
        let ownedByOther = bot.assistantId != nil && bot.assistantId != selfId
        let mine = draftBotId == bot.id
        // ⚠️ 2026-11-17 boss 报「入口那里点不了」：原来只有行尾那 4 个字的按钮是热区，
        // 行本身点下去毫无反应 —— 整块看着像选择器，实际只有一小撮能点。现在整行是一个按钮
        // （`contentShape` 铺满，连行尾的留白也算），行尾那行字只是**说明这次点击会发生什么**，
        // 不再是唯一的入口。被别的助理占着的行同样可点 = 改归本助理（仍要保存才落库）。
        let action: String = ownedByOther ? L("改归本助理") : (mine ? L("不归它") : L("归它"))
        return Button {
            draftBotId = mine ? nil : bot.id
        } label: {
            HStack(spacing: 8) {
                if ownedByOther {
                    Image(systemName: "lock")
                        .font(.system(size: 9))
                        .foregroundStyle(CodexTheme.textMuted)
                    Text(bot.displayName)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textSecondary)
                    Text(String(format: L("已归：%@"), ownerName ?? L("另一个助理")))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                } else {
                    Image(systemName: mine ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(mine ? CodexTheme.accent : CodexTheme.textMuted)
                    Text(bot.displayName)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text(bot.maskedAppId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CodexTheme.textMuted)
                    // 机器人没有自己的开关了（2026-11-18）⇒ 这里没有"已关"可写；
                    // 缺 app_id 已经由 `maskedAppId` 自己说出来，别重复一遍。
                }
                Spacer()
                Text(action)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(ownedByOther || !mine ? CodexTheme.accent : CodexTheme.textSecondary)
                    .fixedSize()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    // MARK: - 2026-11-23 「模型自主调度」配额

    /// 这两行是**一句话的两半**，别拆开看：段落说"它能给自己约时间"，第一行说"每轮最多 1 条"，
    /// 第二行说"一天最多几条"（那颗胶囊）。
    ///
    /// 为什么它是**独立一张卡**而不是塞进「模型与模式配置」: 那一张回答的是"跑起来用什么模型、
    /// 一天花多少"，这一张回答的是"**什么时候跑**"—— 它与上面的 cron 是一组，与模型不是。
    private var followUpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text(L("模型自主调度"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                if let id = editingId {
                    Text(String(format: L("今日已约 %lld 次"), store.followUpsToday(id)))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("两次巡检之间，它可以给自己约一个时刻回来（比如「构建还在跑，10 分钟后再看」）。"))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                followUpQuotaPicker
                    .fixedSize()
            }
            Text(L("每轮最多约 1 条。约来的那一轮照常算进日预算。"))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 配额胶囊。**落库存 Int**（不是枚举）: 将来要"自定义次数"不用改 schema；
    /// 而菜单里只给五档，是因为现在只有这五个语义（`0` = 不用）。
    ///
    /// ⚠️ 每项必须是 `Button` —— `Menu` 里塞带 `.tag` 的其它视图会**静默失效**（本项目踩过）。
    private var followUpQuotaPicker: some View {
        CodexPillMenu {
            ForEach([0, 1, 2, 3, 5], id: \.self) { n in
                Button(followUpQuotaLabel(n)) { draftFollowUpsPerDay = n }
            }
        } label: {
            Text(followUpQuotaLabel(draftFollowUpsPerDay))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
    }

    private func followUpQuotaLabel(_ n: Int) -> String {
        n == 0 ? L("不用（关掉）") : String(format: L("每天 %lld 次"), n)
    }

    /// 草稿 → 落库值。Cron 档恒 `nil`（那一档没有这个入口，不该在库里留一份没人能改的数据）。
    ///
    /// ⚠️ 助理档存**具体数**而不是"恰好等于默认就存 nil": "他看过并接受了 2" 与 "他从没看过"
    /// 是两件事 —— 后者会让将来的默认值变更悄悄改掉他的设置。
    private func savedFollowUpsPerDay(_ kind: TaskKind) -> Int? {
        kind == .assistant ? max(0, draftFollowUpsPerDay) : nil
    }

    // MARK: - P10.4 任务级执行配置 (模型/级别/模式; fire 只动日志会话 transport)

    /// 任务级「模型与模式配置」。**cron / 助理的必须项**（2026-11-20 boss 定）：
    /// 任务一建就钉住模型与档位，运行时不看全局 —— 所以这里不再有"跟随全局"这个选项。
    ///
    /// ⚠️ 这张卡**永远展开**（原来是个可勾选的「自定义模型与模式」开关）。理由就是 boss 那条
    /// 不变式：「不管我有没有手动拨换过模型，下一次跑永远按任务里设置的那个来」——
    /// 允许"不设置"，那条不变量就没有落点（`config == nil` 时 fire 用的是全局，而全局会被
    /// 别处的一次选会话改掉）。
    /// 守卫分两层：这里只是**可见性**（没填就存不了），真守卫在
    /// `SchedulerService.addScheduled/updateScheduled`（绕过视图也长不出 `config == nil` 的任务）。
    private var configCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                Text("模型与模式配置")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                // 没填时把"为什么存不了"就地写出来（与 `remoteCard` 的"没有机器人"同一个手法:
                // 拦截原因要长在**能修它的那个位置**，而不是只写在底栏的 help 里）。
                if buildDraftConfig() == nil {
                    Text("必填")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.blocked)
                }
            }
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
            // 日预算（2026-11-18 晚从「触达」卡挪过来）: 它不是"怎么叫人"，是**花钱的上限** ——
            // 跟模型放一起语义才对（"用哪个模型、一天最多花多少"）。只对助理档显示: 巡检轮
            // 每轮都在烧 token，Cron 档的消耗由 cron 频率本身决定。
            if draftKind == .assistant { budgetRow }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 日预算一行。0 / 留空 = 不设限；超了是**跳过并落痕**，不换便宜模型（§04）。
    /// 「今日已用」只在编辑已保存的任务时有意义（新建的还没有今天）。
    private var budgetRow: some View {
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

    /// 滑轨/药丸的显示值。⚠️ `draftThinking == nil` (旧库、或新任务还没动过) 时
    /// 按**当前全局档**落位 —— 控件表达不了"未指定"。2026-11-20 起保存时会把落位的这个值
    /// **写成具体值**（`buildDraftConfig`），不再有"不钉死"的任务配置。
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
                // 这张卡现在只服务 Cron 档（助理档不摆目标框，见 `taskEditor`）——
                // 占位文案因此只剩一种。留一个 assistant 分支等于给"把框加回去"埋一条隐形的路。
                Text(LK("到点投递给 Agent 的 prompt…"))
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

    /// 保存校验**只有这一处** —— `draftReady` 与 `draftBlockReason` 都读它。
    ///
    /// 为什么合成一个枚举: 两处各写一遍判断，迟早出现「按钮亮着，点下去说 cron 无效」
    /// （S7 的触达校验踩过同款）。而 S13 之后哪些条件**放宽了**也只有一处能读出来。
    private enum SaveBlocker: Equatable {
        case legacy     // 旧条件值守任务只读归档
        case prompt     // Cron: 指令必填
        case cron
        case model      // 模型与模式配置必填 (2026-11-20)
    }

    private var saveBlocker: SaveBlocker? {
        if isLegacyEditing { return .legacy }
        // P19.2 S13: **助理可以没有目标、可以没有项目**。
        //   · 2026-11-17 起助理档**根本没有目标输入框**（目标来自每轮下发 / 从账本长出来）
        //     ⇒ 新建的助理 prompt 恒为空，这一条必须放过，否则助理永远存不下去；
        //   · 没有项目 = 本版"唯一的可用来源是项目"这条限制撤掉了（外部来源仍未接入，
        //     但一轮没有可采数据并不等于配置错 —— 它还能读账本、看有没有该继续追的事）。
        // ⚠️ **Cron 一个字都不许放宽**：它的 prompt 是"要执行的指令"，空指令 = 一条永远
        //    什么也不做却按时烧 token 的任务，而人只会看到"跑了、没反应"。
        if draftKind != .assistant,
           draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty { return .prompt }
        if CronExpr.parse(effectiveCron) == nil { return .cron }
        // 2026-11-20 boss 定: **cron / 助理的「模型与模式配置」是必须项**。
        // 放最后判: 前面几条是"写错了"，这一条是"还没选" —— help 里说清是哪一种。
        if buildDraftConfig() == nil { return .model }
        return nil
    }

    private var draftReady: Bool { saveBlocker == nil }

    /// 保存不了时说明**是哪一条**不满足 —— 一句话兜全部的话, 人得自己猜。
    private var draftBlockReason: String {
        switch saveBlocker {
        case .legacy: return "旧类型已停用，不能保存"
        case .prompt: return "prompt 与 cron 为必填"
        case .cron:   return "cron 无效"
        case .model:  return "模型与模式配置为必填"
        case nil:     return "保存"
        }
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
        draftBotId = nil
        draftBudget = ""
        draftFollowUpsPerDay = ScheduledTask.factoryFollowUpsPerDay
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
        // 顺带刷新台账卡的已解析快照 —— 两边读的是同一份文件（`refreshLedger` 里那一次读盘）。
        let h = refreshLedger()
        draftLog = h?.content ?? ""
        handoffUpdatedAt = h?.updatedAt
        // 「已发消息」预览与它同源（都在"打开这个任务"这一刻取一次）。
        refreshSent()
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
        // ⚠️ 助理档**不显示**这一栏（2026-11-17），但仍要**原样载入** —— 保存时是整条写回的，
        // 不载入就等于"改个名字顺手把老目标清空"，而且是零信号的那种清空。
        draftCron = task.cron
        draftProjectId = task.projectId
        draftContinuous = task.continuous
        // P19: legacy 不是可编辑的类型（归档态）⇒ 编辑器按 Cron 呈现，但整页只读
        draftKind = task.isLegacyWaiting ? .execute : task.kind
        draftSources = task.sources
        // 归属从机器人那一侧反查（`remote_bots.assistant_id` 是唯一真源）。
        // 1:1 ⇒ 最多一个；`first` 而不是 `last` 只是为了"万一库里有两条"时行为可预期。
        draftBotId = store.remoteBots.first { $0.assistantId == task.id }?.id
        draftBudget = task.dailyTokenBudget > 0 ? String(task.dailyTokenBudget) : ""
        // 回填**生效值**：老行（nil）在这里被摊成本档的默认（助理 2 / Cron 0），
        // 下一次保存就把它固化成具体值 —— 与 `config` 那条"没有跟随全局这个状态了"同款。
        draftFollowUpsPerDay = task.effectiveFollowUpsPerDay
        syncCronControls(task.cron)
        // P10.4: 任务级配置回填。**没有"跟随全局"这个状态了** —— 老库里的 nil 行回填成
        // "当前全局值"只是把它的既有行为落成一个具体值（下一次保存即固化）。
        if let cfg = task.config {
            draftProvider = cfg.provider
            draftModelId = cfg.modelId
            draftThinking = cfg.thinkingLevel
            draftMode = cfg.agentMode
        } else {
            draftProvider = store.currentProvider
            draftModelId = store.currentModelId
            draftThinking = nil
            draftMode = AgentMode.standard.rawValue
        }
        let h = store.readHandoff(for: task)
        draftLog = h?.content ?? ""
        handoffUpdatedAt = h?.updatedAt
        // 台账卡的同一份读盘结果（`refreshLedger` 只在"打开/切换/刚跑过"时被调，不在 body 里）
        ledgerParsed = AssistantLedger.parse(h?.content ?? "")
        ledgerUpdatedAt = h?.updatedAt
        showWorkLog = false
    }

    /// 保存时把这个助理的归属落成**一条**机器人行。
    ///
    /// ⚠️ 这里**不再扫全表摘别人的绑定** —— "一个机器人只归一个助理"由 `assistant_id`
    /// 单值列保证: 写它就是改归，写 `nil` 就是解绑。S15 那版先写自己再扫别人，
    /// 两者中间有一个"同时被两条任务声称"的窗口，而症状是"我明明绑给它了，它不回"。
    /// 1:1 的另一半（一个助理只挂一个）在 `ChatStore.assignRemoteBot` 里顶掉旧的。
    private func applyRemoteBots(assistantId: UUID) {
        if let id = draftBotId {
            store.assignRemoteBot(id, to: assistantId)
        } else {
            store.unassignRemoteBots(from: assistantId)
        }
    }

    private func saveEditing() {
        guard draftReady else { return }
        // 预算归一后落库。⚠️ **触达不再由保存写回**（2026-11-18 晚删了配置入口）:
        // `existing.notify` 原样留在行上 —— "撤下输入框 ≠ 清空数据"（P11 判据①），
        // 老任务的 `system` 还照旧生效，新建任务走 `NotifyOptions.default`。
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
            existing.dailyTokenBudget = budget
            existing.followUpsPerDay = savedFollowUpsPerDay(draftKind)
            // P19.2 S15b: 飞书入口的归属。**只改机器人行**，助理行上没有这份数据。
            store.updateScheduled(existing)
            if draftKind == .assistant { applyRemoteBots(assistantId: id) }
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
                store.scheduledTasks[idx].dailyTokenBudget = budget
                store.scheduledTasks[idx].followUpsPerDay = savedFollowUpsPerDay(draftKind)
                store.updateScheduled(store.scheduledTasks[idx])
                if draftKind == .assistant { applyRemoteBots(assistantId: store.scheduledTasks[idx].id) }
            }
        }
        // "✓ 已保存"短闪 (与代码块"已复制"同模式)
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    /// 预算草稿 → 整数。空 / 非数字 → 0（不设限）。不拦保存: 这个字段写歪了人一眼能看出来
    /// （"不限"），而拦下整个保存的代价是别的改动也一起丢了。
    private func parsedBudget() -> Int {
        Int(draftBudget.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// P10.4: 草稿 → 任务级配置。**cron / 助理必须给得出一个具体模型**（2026-11-20）——
    /// 返回 nil 表示"没配全"，保存被 `SaveBlocker.model` 拦下；域层还会再兜一次。
    ///
    /// ⚠️ 思考强度**一律落成具体值**（草稿没动过就取当前全局档）。从前这里写 `nil` 表示"不钉死"，
    /// 而 `beginTurn` 只在 `thinking != nil` 时才下发 ⇒ 级别会**留着上一轮的值**漂走。
    /// 既然模型要钉死，级别也得钉死：同一场会话里两轮模型一致、级别不一致，一样是"对不上"。
    /// 控件本来就显示当前全局档（`taskChoice` 的兜底），所以界面上看不出差别。
    private func buildDraftConfig() -> SessionConfig? {
        guard !draftProvider.isEmpty, !draftModelId.isEmpty else { return nil }
        return SessionConfig(provider: draftProvider, modelId: draftModelId,
                             thinkingLevel: draftThinking ?? store.model.thinkingLevel.rawValue,
                             agentMode: draftMode, askApproval: false)
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
