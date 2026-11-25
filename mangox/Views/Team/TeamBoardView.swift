//
//  TeamBoardView.swift
//  P20 P5 助理团队页（泳道 · 纯展示，2026-11-25）。
//
//  设计来源: `docs/P20-functional-design.html` §03「助理团队 · 状态泳道 · 纯展示」。
//
//  布局（2026-11-25 boss 定）: **左栏 + 上下两栏**。
//     · 左栏 = 队伍筛选（200pt，固定）
//     · 上栏 = 统计行 + 五条泳道（吃掉剩下的**全部宽度与高度**）
//     · 下栏 = 检查器（横条，定高 200pt，三段并排: 身份职责 / 最近五次执行 / 台账 + 动作）
//  ⚠️ 检查器原来是**右栏**（272pt 竖条）。改到下方是因为两条: ① 五列等宽要求横向有整幅
//  可用宽 —— 右栏一占 272，中间只剩 400 出头，五列连 90pt 都分不到；② 这一页纵向本来
//  就空（"几个人"的数据撑不满一屏），把检查器放到下面正好把那份空填掉。
//
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
            // 上下两栏: 上面是泳道（吃掉全部剩余宽度与高度），下面那条横的检查器。
            VStack(spacing: 0) {
                boardPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(CodexTheme.divider)
                inspectorBar
            }
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

    /// 每支队伍一个色，**整块板子算一次**（见 `TeamBoardText.tintIndexMap` 里那三条）。
    /// 卡片竖条与左栏图例读的是同一份映射 —— 分两处各算一次，改一处就会对不上。
    private var tintMap: [UUID: Int] {
        TeamBoardText.tintIndexMap(teamIds: mains.map(\.id))
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
                                 count: 1 + store.scheduler.workerCount(of: m.id),
                                 // 与卡片竖条**同一个下标**（同一支队伍 ⇒ 同一个颜色）:
                                 // 这一列同时是图例 —— 卡片上那条 3px 的色，在这里能查到是谁。
                                 tint: TeamBoardText.cardTintIndex(
                                     m, parentIsAlive: true, tintMap: tintMap)
                                     .map { CodexTheme.teamTints[$0] })
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

    private func scopeRow(_ s: TeamBoardScope, title: String, count: Int,
                          tint: Color? = nil) -> some View {
        let active = scope == s
        return Button { scope = s; selectedId = nil } label: {
            HStack(spacing: 6) {
                // 队伍色的小圆点 —— 只有队伍行有（「全部」「未归属」不是队伍）。
                // 它顺带把队伍行**缩进**一级，读起来是"全部 > 各队"的层级。
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                }
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
                    // 五列**等宽**，宽度由这一栏的可用宽算出来（`laneWidth(available:)`）。
                    // 常见窗口下它正好是"均分后放满"—— 既不横向滚，也不留一截空白。
                    let laneW = TeamBoardText.laneWidth(available: geo.size.width)
                    ScrollView(.horizontal, showsIndicators: false) {
                        // `spacing: 0` —— 列间距改由 `laneRule` 自己占（12pt 的槽中间画 1px 线），
                        // 于是"五列 + 四条线"的实际宽仍然是 `laneWidth × 5 + gap × 4`，
                        // `boardWidth` 那个判据不用改。
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(TeamLane.allCases) { lane in
                                if lane != TeamLane.allCases.first { laneRule }
                                laneColumn(lane, width: laneW)
                            }
                        }
                        // 宽窗口下列宽封顶 150、整片会窄于这一栏 —— 那时居中（不是靠左）:
                        // 靠左会让"看板只有右边一半空"，居中读起来是"一片看板浮在中间"。
                        .frame(minWidth: geo.size.width, alignment: .center)
                        .padding(.bottom, 12)
                    }
                    // 溢出时右缘渐隐。**不用原生滚动指示器**: 亮色下它是横贯底部的一条
                    // 白杠（出图实测），既难看又占掉一行 —— 而它要说的只有一句"右边还有"。
                    // 只有**窄到列宽下限**时才会溢出，判据与布局同一个 `laneWidth`。
                    .overlay(alignment: .trailing) {
                        if TeamBoardText.boardWidth(available: geo.size.width) > geo.size.width {
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

    /// 列与列之间那条**淡线**（2026-11-25 boss：「能不能在不同的列之间有一条淡淡的分割线」）。
    ///
    /// 三条分寸:
    ///   · **1px** —— 再粗就变成格子边框，而这五格里四格是空的，边框会强调"空";
    ///   · **`divider` 的 60%** —— 与面板分割线（筛选 / 检查器那两条）用同一个色，但更弱:
    ///     它们分的是"不同的东西"，这条分的只是"同一种东西的五份";
    ///   · **整条高度到底** —— 只画在有卡的那几行就回到"列头漂浮"的老问题; 到底才读成五条道。
    private var laneRule: some View {
        Rectangle()
            .fill(CodexTheme.divider.opacity(0.6))
            .frame(width: 1)
            // 外面这层把 12pt 的列间距接过来 —— 线正好落在间距正中，整片宽度不变。
            .frame(width: Tune.teamLaneGap)
    }

    private func laneColumn(_ lane: TeamLane, width: CGFloat) -> some View {
        let people = TeamBoardText.order(lane, scoped, states: store.scheduler.teamStates)
        return VStack(alignment: .leading, spacing: Tune.teamCardGap) {
            laneHeader(lane, count: people.count)
            ForEach(people) { t in cardView(t, lane: lane) }
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .top)
    }

    /// 列头。**只有一份画法**：圆点 + 列名一行 + 数字右对齐。空列与有卡列长得一模一样，
    /// 区别只有"下面有没有卡"—— 宽度是五列共用的（`TeamBoardText.laneWidth(available:)`）。
    ///
    /// ⚠️ 这里推翻过两版（2026-11-25 两次出图）: ① 空列把列名**按字符竖排** + 定高 36
    /// ⇒「又是横字，又是竖字」; ② 空列按实测列名收窄到 61pt ⇒「至少要等宽吧」。
    /// 两版都错在"给空列开特例"这个念头上 —— 这一页是**五条等宽的泳道**，空的那条只是没人。
    private func laneHeader(_ lane: TeamLane, count: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(laneTint(lane))
                .frame(width: 5, height: 5)
            Text(TeamBoardText.laneTitle(lane))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(CodexFonts.monoFont(9))
                .foregroundStyle(CodexTheme.textMuted)
        }
        .padding(.horizontal, 2)
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
        let parentName = store.scheduler.parentName(of: t)
        let subtitle = TeamBoardText.cardSubtitle(
            t,
            parentName: parentName,
            state: store.scheduler.teamState(of: t.id),
            now: Date()
        )
        // 这张卡属于哪支队伍 —— `nil` = 没有队伍（悬挂的 parentId 也算），中性灰。
        // ⚠️ `parentIsAlive` 与上面那个 `parentName` 是**同一个判据**（`parentName(of:)` 查不到人
        // 就返回 nil）—— 一处说"未归属"、另一处还给上队伍色，是最容易犯的那种不一致。
        let tint: Color? = TeamBoardText
            .cardTintIndex(t, parentIsAlive: parentName != nil, tintMap: tintMap)
            .map { CodexTheme.teamTints[$0] }
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
                    // 竖条 = **队伍色**（2026-11-25 boss：「不同的团队，应该有颜色区分」）。
                    // ⚠️ 它原来只画给队长（"竖条一旦到处都是就什么也不表示"）—— 那条判据在
                    // **只有一支队伍**时成立; 多队并存时，卡片上没有一个东西说得出"我属于谁"，
                    // 而 worker 的第二行写的是归属**名字**，扫读要逐卡看字。
                    // 现在竖条人人都有、且同队同色 ⇒ 队长改由**名字 500 + 身份行里的「管理」**认。
                    // 孤儿（main 被删）没有队伍 ⇒ 中性灰，与自己那行「未归属」对得上。
                    Rectangle()
                        .fill(tint ?? CodexTheme.textMuted.opacity(0.45))
                        .frame(width: Tune.teamIdentityBarWidth)
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

    // MARK: - 下栏：检查器（横条）

    /// 横过来的检查器 —— 定高 `Tune.teamInspectorHeight`，内部**四格**并排。
    ///
    /// 四格的切法是按语义，不是按"平均": ① 是谁 + 现在什么状态 ② 配了什么（职责 / 说明 / 模型）
    /// ③ 最近五次执行 ④ 台账 + 动作。
    /// ⚠️ 第一版是三格（①②合一），出图当场被否: 一格里摞着名字、身份、状态、职责、说明、模型，
    /// 高度顶穿 200pt，最后一行「模型」正好被底边切掉一半 —— 而它又不在滚动位置的起点上，
    /// 看上去就是"这里坏了"。**一格里最多摞三行**是这条横栏的体量纪律。
    ///
    /// 四格宽度**等分**（`maxWidth: .infinity`）而不是固定宽: 这一页要跟着窗口缩放走 ——
    /// 固定宽在窄窗口里会把最后一格挤成一条缝，等分则每格都能摊开、文字自然折行。
    /// 内容仍超高时整条一起纵向滚（四格同时滚，比各自滚更不容易看丢对照关系）。
    private var inspectorBar: some View {
        ScrollView {
            Group {
                if let t = selectedTask {
                    HStack(alignment: .top, spacing: 16) {
                        whoBlock(t)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider().overlay(CodexTheme.divider)
                        dutyBlock(t)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider().overlay(CodexTheme.divider)
                        recentBlock
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider().overlay(CodexTheme.divider)
                        VStack(alignment: .leading, spacing: 12) {
                            ledgerBlock
                            actionsBlock(t)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    scopeInspector
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(height: Tune.teamInspectorHeight)
        .background(CodexTheme.bgChat)
    }

    /// 第 ① 格 —— 是谁、现在什么状态。
    private func whoBlock(_ t: ScheduledTask) -> some View {
        let state = store.scheduler.teamState(of: t.id)
        return VStack(alignment: .leading, spacing: 4) {
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
    }

    /// 第 ② 格 —— 它被配成什么样: 职责 / 职责说明 / 模型。
    private func dutyBlock(_ t: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
        }
    }

    /// 第 ④ 格的下半 —— 两个动作。它们是**对这一行数据的下一步**，
    /// 而这条横栏已经是"这一行的全部读数"。
    private func actionsBlock(_ t: ScheduledTask) -> some View {
        HStack(spacing: 8) {
            actionButton(L("打开编辑器")) { store.focusTask(t.id) }
            if let sid = t.logSessionId {
                actionButton(L("打开会话")) { store.selectConversation(sid) }
            }
            Spacer(minLength: 0)
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
