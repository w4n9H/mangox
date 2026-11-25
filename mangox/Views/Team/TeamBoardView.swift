//
//  TeamBoardView.swift
//  P20 P5 助理团队页（泳道 · 纯展示，2026-11-25）。
//
//  设计来源: `docs/P20-functional-design.html` §03「助理团队 · 状态泳道 · 纯展示」。
//
//  三栏: 左 = 队伍筛选 / 中 = 五条泳道 / 右 = 检查器。
//  这一页**不可编辑**（归属与职责都在定时任务页改）—— 它不是第二个入口，
//  是同一批数据的另一种看法: 列表页答"这个助理怎么配"，这里答"谁现在在干什么"。
//

import SwiftUI

struct TeamBoardView: View {
    @ObservedObject var store: ChatStore

    @State private var scope: TeamBoardScope = .all
    @State private var selectedId: UUID?
    @State private var hoveringId: UUID?

    // MARK: 检查器的数据（**不在 body 里查**）
    //
    // 检查器是"选中谁就换一次内容"的栏，而 `readHandoff` 是一次读盘 + `parse` 六遍，
    // `recentDelegations` 是一次 SQL。放进 body 就是"每 tick 查一次"（`teamStates` 每分钟变）。
    // 只在"选中变了"与"这个人又跑过一轮"两个时点刷 —— 与 `ScheduledView.refreshLedger` 同一条纪律。
    @State private var recent: [Delegation] = []
    @State private var ledger: AssistantLedger = .init()

    var body: some View {
        HStack(spacing: 0) {
            filterPane
                .frame(width: Tune.teamFilterWidth)
                .background(CodexTheme.bgSidebar)
            Divider().overlay(CodexTheme.divider)
            boardPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CodexTheme.bgChat)
            Divider().overlay(CodexTheme.divider)
            inspectorPane
                .frame(width: Tune.teamInspectorWidth)
                .background(CodexTheme.bgChat)
        }
        .onAppear { refreshInspector() }
        .onChange(of: selectedId) { _, _ in refreshInspector() }
        .onChange(of: selectedTask?.lastRunAt) { _, _ in refreshInspector() }
    }

    // MARK: - 名单（全部纯计算，不查库）

    /// 这一页的**全体**：助理档，且不是只读归档。
    ///
    /// ⚠️ **Cron 档不进这一页**。它在存储上也是 `role == .main`（`TaskRole` 缺省值），
    /// 但它没有队伍这个概念 —— 派不了活、也没人会派它。混进来之后左侧"全部 6"与泳道总数
    /// 就对不上（文档样张里那张"发版检查"就是画错的: 7 张卡 vs 左侧 6）。
    /// 数字对不上的界面，人第一眼就会怀疑整页是假的。
    private var allPeople: [ScheduledTask] {
        store.scheduler.scheduledTasks.filter { $0.isAssistant && !$0.isLegacyWaiting }
    }

    private var mains: [ScheduledTask] {
        allPeople.filter { $0.role == .main }
    }

    private var orphans: [ScheduledTask] {
        TeamBoardText.people(.orphans, all: allPeople)
    }

    private var scoped: [ScheduledTask] {
        TeamBoardText.people(scope, all: allPeople)
    }

    /// 五列各几个人。空列要折叠，所以这个字典是布局的输入（不只是统计）。
    private var cards: [TeamLane: Int] {
        var out: [TeamLane: Int] = [:]
        for t in scoped {
            out[TeamLane.of(store.scheduler.teamState(of: t.id)), default: 0] += 1
        }
        return out
    }

    private var teamsInScope: Int {
        switch scope {
        case .all:     return mains.count
        case .team:    return 1
        case .orphans: return 0
        }
    }

    private var scopeName: String {
        switch scope {
        case .all:
            return L("全部")
        case .team(let id):
            // 这个 main 被删了（人还停在那一页）⇒ 说清原委，不要回落成「全部」——
            // 那会让人以为自己选的筛选静默失效了。
            return mains.first { $0.id == id }?.name ?? L("原队伍已删除")
        case .orphans:
            return L("未归属")
        }
    }

    private var selectedTask: ScheduledTask? {
        guard let id = selectedId else { return nil }
        return store.scheduler.scheduledTasks.first { $0.id == id }
    }

    // MARK: - 左栏：队伍筛选

    private var filterPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("团队"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    scopeRow(.all, title: L("全部"), count: allPeople.count)
                    ForEach(mains) { m in
                        scopeRow(.team(m.id), title: m.name,
                                 count: 1 + store.scheduler.workerCount(of: m.id))
                    }
                    if !orphans.isEmpty {
                        Divider()
                            .overlay(CodexTheme.divider)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        scopeRow(.orphans, title: L("未归属"), count: orphans.count)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private func scopeRow(_ s: TeamBoardScope, title: String, count: Int) -> some View {
        let active = scope == s
        return Button { scope = s; selectedId = nil } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(CodexFonts.monoFont(9.5))
                    .foregroundStyle(CodexTheme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                    .fill(active ? CodexTheme.selected : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 中栏：统计行 + 五条泳道

    private var boardPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(TeamBoardText.statsLine(total: scoped.count, teams: teamsInScope, cards: cards))
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if allPeople.isEmpty {
                emptyBoard
            } else if scoped.isEmpty {
                // 有人、但这个范围里没有 —— 与"一个人都没有"是两件事，
                // 用同一个空态会让人以为名单被清空了。
                Text(L("这个范围里没有人。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(CodexTheme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 24)
            } else {
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Tune.teamLaneGap) {
                            ForEach(TeamLane.allCases) { lane in laneColumn(lane) }
                        }
                        // 装得下就**居中**（不是靠左）: 只有两个助理时，
                        // 整片看板挤在左上角、右边一大片空 —— 那比空列更显得"这页没什么内容"。
                        // 居中之后空白被分成两份，读起来是"一小片看板浮在中间"。
                        .frame(minWidth: geo.size.width, alignment: .center)
                        .padding(.bottom, 12)
                    }
                    // 溢出时右缘渐隐。**不用原生滚动指示器**: 亮色下它是横贯底部的一条
                    // 白杠（出图实测），既难看又占掉一行 —— 而它要说的只有一句"右边还有"。
                    .overlay(alignment: .trailing) {
                        if TeamBoardText.boardWidth(cards: cards) > geo.size.width {
                            LinearGradient(
                                colors: [CodexTheme.bgChat.opacity(0), CodexTheme.bgChat],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: 30)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }

    private var emptyBoard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 22))
                .foregroundStyle(CodexTheme.textMuted)
            Text(TeamBoardText.emptyBoardLine())
                .font(.system(size: 12))
                .foregroundStyle(CodexTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("去定时任务")) { store.toggleScheduledPanel() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(CodexTheme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private func laneColumn(_ lane: TeamLane) -> some View {
        let people = TeamBoardText.order(lane, scoped, states: store.scheduler.teamStates)
        let empty = people.isEmpty
        return VStack(alignment: empty ? .center : .leading, spacing: Tune.teamCardGap) {
            laneHeader(lane, count: people.count, collapsed: empty)
            if !empty {
                ForEach(people) { t in cardView(t, lane: lane) }
            }
            Spacer(minLength: 0)
        }
        .frame(width: TeamBoardText.laneWidth(empty: empty), alignment: .top)
    }

    /// 列头。**空列收窄成竖排列头 + 一个 0**（`TeamBoardText.laneWidth` 的注释解释了为什么
    /// 收窄宽度而不隐藏列: 位置是这个页面唯一的导航锚）。
    private func laneHeader(_ lane: TeamLane, count: Int, collapsed: Bool) -> some View {
        Group {
            if collapsed {
                VStack(spacing: 3) {
                    // ⚠️ 定高 36（三行 10pt 字）: 列名有 2 字（在跑）也有 3 字（已排上），
                    // 不定高时那个 `0` 会跟着列名长短上下错位 —— 出图实测五列的数字参差不齐。
                    VStack(spacing: 0) {
                        ForEach(Array(TeamBoardText.laneTitle(lane).enumerated()), id: \.offset) { _, ch in
                            Text(String(ch))
                                .font(.system(size: 10))
                                .foregroundStyle(CodexTheme.textMuted)
                        }
                    }
                    .frame(height: 36, alignment: .top)
                    Text("0")
                        .font(CodexFonts.monoFont(9))
                        .foregroundStyle(CodexTheme.textMuted.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(laneTint(lane))
                        .frame(width: 5, height: 5)
                    Text(TeamBoardText.laneTitle(lane))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(CodexTheme.textSecondary)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(CodexFonts.monoFont(9))
                        .foregroundStyle(CodexTheme.textMuted)
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// 状态色 —— **只画在列头那个小圆点上**，卡片本身不上色。
    ///
    /// 文档 §03「身份与颜色分两个通道」: 身份走 3px 竖条 + 名字 500（都不占颜色），
    /// 颜色只表示状态。给卡片再上一个底色，同一屏就有两套色编码 —— main 用了蓝，
    /// "正在跑的 main"就分不出是身份还是状态；而二十张卡各带底色就是一堵彩墙。
    private func laneTint(_ lane: TeamLane) -> Color {
        switch lane {
        case .running:  return CodexTheme.info
        case .queued:   return CodexTheme.toolQueued
        case .awaiting: return CodexTheme.thinking
        case .idle:     return CodexTheme.textTertiary
        case .disabled: return CodexTheme.textMuted
        }
    }

    private func cardView(_ t: ScheduledTask, lane: TeamLane) -> some View {
        let selected = selectedId == t.id
        let hovered = hoveringId == t.id
        let lead = TeamRowText.isTeamLead(t)
        let subtitle = TeamBoardText.cardSubtitle(
            t,
            parentName: store.scheduler.parentName(of: t),
            state: store.scheduler.teamState(of: t.id),
            now: Date()
        )
        return Button { selectedId = t.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name)
                    // 名字 500 = 身份三样里的第二样。只给队长 —— 全员加粗等于没加粗。
                    .font(.system(size: 11.5, weight: lead ? .medium : .regular))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Tune.teamCardPadH)
            .padding(.vertical, Tune.teamCardPadV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // 3px 竖条与底同层、整层裁圆角 —— 竖条跟着卡片圆角走，不会在左上角露一个直角。
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                        .fill(selected ? CodexTheme.bgElevated : CodexTheme.bgCard)
                    if hovered && !selected { CodexTheme.hover }
                    if lead {
                        Rectangle()
                            .fill(CodexTheme.textMuted.opacity(0.55))
                            .frame(width: Tune.teamIdentityBarWidth)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
            }
            // 亮色下卡片面 #F1F1F1 压在纸 #F8F8F8 上只差 Δ7，没有边就"看不出这是一张卡"
            // （出图实测: 整片读成一行行文字浮在纸上）。边用 `border`（两套主题都成立），
            // 选中时换成 accent —— 不是加一条更粗的边，是**换颜色**（同一处只画一次）。
            .overlay {
                RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                    .strokeBorder(selected ? CodexTheme.accent.opacity(0.75) : CodexTheme.border,
                                  lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringId = $0 ? t.id : nil }
    }

    // MARK: - 右栏：检查器

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let t = selectedTask {
                    selectedInspector(t)
                } else {
                    scopeInspector
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }

    /// 没选卡时：**当前范围的真实读数**，不是一片空白。
    ///
    /// 纯展示页的第一眼大概率是"什么都没选中"—— 那一眼若是一片空白，整页就只剩
    /// "左边一列名单 + 中间几张卡"，人会以为这页没做完。
    private var scopeInspector: some View {
        let lines = TeamBoardText.scopeLines(scopeName: scopeName, total: scoped.count,
                                             teams: teamsInScope, cards: cards)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("当前范围"))
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textMuted)
            Text(lines.first ?? scopeName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CodexTheme.textPrimary)
                .lineLimit(2)
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(CodexTheme.divider).padding(.vertical, 4)
            Text(L("点一张卡，看它的职责、最近五次执行与台账进度。"))
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selectedInspector(_ t: ScheduledTask) -> some View {
        let state = store.scheduler.teamState(of: t.id)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineLimit(2)
                Text(TeamRowText.identityLine(
                    t,
                    workers: store.scheduler.workerCount(of: t.id),
                    parentName: store.scheduler.parentName(of: t)
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(CodexTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(TeamRowText.stateWord(state, now: Date()))
                    .font(CodexFonts.monoFont(10))
                    .foregroundStyle(laneTint(TeamLane.of(state)))
            }

            if !t.description.isEmpty {
                inspectorBlock(L("职责"), t.description)
            } else if t.role == .worker {
                // 域层不许 worker 空着职责，所以走到这里说明是**老库里的行**
                // （P4 之前建的）。说出来，别让它读成"这个人没有职责"。
                inspectorBlock(L("职责"), L("这一行早于「职责必填」，去编辑器补一句。"))
            }
            if !t.descriptionDetail.isEmpty {
                inspectorBlock(L("职责说明"), t.descriptionDetail)
            }
            inspectorBlock(L("模型"), modelLabel(t))

            recentBlock
            ledgerBlock

            HStack(spacing: 8) {
                actionButton(L("打开编辑器")) { store.focusTask(t.id) }
                if let sid = t.logSessionId {
                    actionButton(L("打开会话")) { store.selectConversation(sid) }
                }
            }
            .padding(.top, 2)
        }
    }

    private func inspectorBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textMuted)
            Text(body)
                .font(.system(size: 11.5))
                .foregroundStyle(CodexTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelLabel(_ t: ScheduledTask) -> String {
        guard let cfg = t.config else { return L("跟随默认") }
        return store.model.customLabel(provider: cfg.provider, modelId: cfg.modelId) ?? cfg.modelId
    }

    /// 最近五次执行。**按 `created_at` 降序**，还没落定的那一单也在里面（`recentDelegations` 的注释）。
    private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("最近五次执行"))
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textMuted)
            if recent.isEmpty {
                Text(L("还没被派过活"))
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
            } else {
                ForEach(recent) { d in
                    HStack(spacing: 6) {
                        Text(DelegationRefusal.hhmm(d.createdAt))
                            .font(CodexFonts.monoFont(9.5))
                            .foregroundStyle(CodexTheme.textMuted)
                        Text(d.goal)
                            .font(.system(size: 10.5))
                            .foregroundStyle(CodexTheme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(delegationWord(d.status))
                            .font(.system(size: 9.5))
                            .foregroundStyle(delegationTint(d.status))
                    }
                }
            }
        }
    }

    private func delegationWord(_ s: DelegationStatus) -> String {
        switch s {
        case .queued:    return L("已排上")
        case .running:   return L("在跑")
        case .done:      return L("已交活")
        case .failed:    return L("没干成")
        case .cancelled: return L("作废")
        }
    }

    private func delegationTint(_ s: DelegationStatus) -> Color {
        switch s {
        case .queued:    return CodexTheme.toolQueued
        case .running:   return CodexTheme.info
        case .done:      return CodexTheme.toolDone
        case .failed:    return CodexTheme.toolError
        case .cancelled: return CodexTheme.textMuted
        }
    }

    /// 台账的「完成状态」摘要 —— 只读 `AssistantLedger` 的派生量，**不用它的 `brief`**:
    /// 那个是注入面/对话轮的恒中文措辞（进 prompt 的字节不许跟界面语言走），
    /// 界面这一句必须能翻译（`L()`）。
    private var ledgerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("台账 · 完成状态"))
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textMuted)
            Text(ledgerLine)
                .font(.system(size: 11.5))
                .foregroundStyle(ledger.hasContent ? CodexTheme.textSecondary : CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ledgerLine: String {
        guard ledger.hasContent else { return L("还没有账本") }
        var parts: [String] = []
        if ledger.items.isEmpty {
            parts.append(L("还没有列出验收项"))
        } else if ledger.isComplete {
            parts.append(String(format: L("验收 %lld 项全部达成"), ledger.items.count))
        } else {
            parts.append(String(format: L("验收 %lld 项 · 已达成 %lld"),
                               ledger.items.count, ledger.doneCount))
        }
        if ledger.blockedCount > 0 {
            parts.append(String(format: L("卡住 %lld"), ledger.blockedCount))
        }
        if !ledger.waiting.isEmpty {
            parts.append(String(format: L("等你决定 %lld 件"), ledger.waiting.count))
        }
        return parts.joined(separator: " · ")
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                        .fill(CodexTheme.bgElevated)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 检查器数据刷新（写路径只有这一个函数）

    private func refreshInspector() {
        guard let t = selectedTask else {
            recent = []
            ledger = .init()
            return
        }
        recent = store.recentDelegations(taskId: t.id, limit: 5)
        if let h = store.scheduler.readHandoff(for: t) {
            ledger = AssistantLedger.parse(h.content)
        } else {
            ledger = .init()
        }
    }
}
