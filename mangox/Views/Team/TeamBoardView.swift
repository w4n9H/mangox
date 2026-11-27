//
//  TeamBoardView.swift
//  P20 P5 助理团队页（分组卡片 · 纯展示，2026-11-25 → 2026-11-27 改版）。
//
//  设计来源: `docs/P20-functional-design.html` §03「助理团队 · 纯展示」。
//
//  布局（2026-11-27 boss 定稿）: **一栏到底**。
//    · 顶栏 = 标题 + 统计 chips
//    · 主体 = 按队伍分组的卡片网格（纵向滚，每组一个组头 + 若干张 200 宽的卡）
//    · 下栏 = 检查器（横条，定高 200pt，四段并排: 身份职责 / 职责说明·模型 / 最近五次 / 台账 + 动作）
//
//  ## 为什么把泳道整层拆掉（2026-11-27）
//
//  boss 的原话: 「泳道的优点在于工作状态展示清晰，非工作状态时就会有很大的一块空旷显示；
//  卡片的好处就是非工作状态时平铺展示很友好，但是工作状态时有点分不清谁在什么状态」。
//
//  两者的主轴不同: 泳道的主轴是**状态**（人站在哪一列），卡片的主轴是**归属**（这人是谁的人）。
//  泳道在全员待命时四列空着 —— 那不是"设计留白"，是四条空跑道。
//  ⇒ 换成卡片，**状态改由亮度回答**（亮 = 手上有活，暗 = 没有）:
//      · 卡面三档: 浮起（在跑/已排上/等回执）/ 平贴（空闲）/ 沉下（停用）—— `CodexTheme.teamCard*`
//      · 头像在非工作态 `saturation(0)` 褪成灰 —— **这一条才是明暗的主通道**，一张灰脸比一段灰字好扫
//      · 左边缘 3px 状态色 + 那行状态文字 = 第二、三通道（只靠明暗，红绿色弱的人分不出来）
//
//  ⚠️ **明暗不许长在文字上**。第一版把非工作态的正文压到 56% / 42%，实测对比度只有
//     2.33:1 / 1.85:1（浅色）—— 那叫"把内容藏了"，不叫弱化；而要让正文回到 4.5:1，
//     透明度得给到 0.85，也就等于没变暗。所以: **面承担明暗，字只轻推一档**
//     （空闲 0.90 / 停用 0.78，四态实测 6.39 / 4.52 / 3.36 浅色、5.37 / 5.51 / 4.89 暗色）。
//
//  ⚠️ 左侧那道**队伍筛选栏整层删掉了**（2026-11-27）：个人用户 3 支队伍 × 3~5 人，
//     而分组头已经写着「写清楚了的 4 人 · 2 在跑」—— 左栏再列一遍是同一个数字说两遍。
//     代价: 人多之后（12 人 / 6 队）没有快速收敛的手段，只能滚；那时再加顶部下拉。
//
//  这一页**不可编辑**（归属与职责都在定时任务页改）—— 它不是第二个入口，
//  是同一批数据的另一种看法: 列表页答"这个助理怎么配"，这里答"谁现在在干什么"。
//

import SwiftUI

struct TeamBoardView: View {
    @ObservedObject var store: ChatStore

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
        VStack(spacing: 0) {
            boardPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(CodexTheme.divider)
            inspectorBar
        }
        .background(CodexTheme.bgChat)
        .onAppear { refreshInspector() }
        .onChange(of: selectedId) { _, _ in refreshInspector() }
        .onChange(of: selectedTask?.lastRunAt) { _, _ in refreshInspector() }
    }

    // MARK: - 名单（全部纯计算，不查库）

    /// 这一页的**全体**：助理档，且不是只读归档。
    ///
    /// ⚠️ **Cron 档不进这一页**。它在存储上也是 `role == .main`（`TaskRole` 缺省值），
    /// 但它没有队伍这个概念 —— 派不了活、也没人会派它。混进来之后统计行的"7 个助理"
    /// 与画面上的卡片数就对不上（文档样张里那张"发版检查"就是画错的: 7 张卡 vs 左侧 6）。
    /// 数字对不上的界面，人第一眼就会怀疑整页是假的。
    private var allPeople: [ScheduledTask] {
        store.scheduler.scheduledTasks.filter { $0.isAssistant && !$0.isLegacyWaiting }
    }

    private var mains: [ScheduledTask] {
        allPeople.filter { $0.role == .main }
    }

    /// 未归属 = `parentId` 空着（老库）或指向一个已经不在名单里的 main（悬挂值）——
    /// 判据在 `TeamBoardText.people(.orphans:)`，本文件不再自己算一遍。
    private var orphans: [ScheduledTask] {
        TeamBoardText.people(.orphans, all: allPeople)
    }

    /// 每支队伍一个色，**整块板子算一次**（见 `TeamBoardText.tintIndexMap` 里那三条）。
    /// 头像底色与检查器里的色点读的是同一份映射 —— 分两处各算一次，改一处就会对不上。
    private var tintMap: [UUID: Int] {
        TeamBoardText.tintIndexMap(teamIds: mains.map(\.id))
    }

    /// 某个人的队伍色下标 —— `nil` = 没有队伍（悬挂的 `parentId` 也算），画中性灰。
    ///
    /// `parentIsAlive` 与卡片第二行那个「未归属」是**同一个判据**（`parentName(of:)` 查不到人
    /// 就返回 nil）—— 一处说"未归属"、另一处还给上队伍色，是最容易犯的那种不一致。
    private func tintIndex(_ t: ScheduledTask, parentName: String?) -> Int? {
        TeamBoardText.cardTintIndex(t, parentIsAlive: parentName != nil, tintMap: tintMap)
    }

    /// 状态计数（统计行与检查器空态共用）。
    private var stageCounts: [TeamStage: Int] {
        var out: [TeamStage: Int] = [:]
        for t in allPeople {
            out[TeamStage.of(store.scheduler.teamState(of: t.id)), default: 0] += 1
        }
        return out
    }

    private var selectedTask: ScheduledTask? {
        guard let id = selectedId else { return nil }
        return store.scheduler.scheduledTasks.first { $0.id == id }
    }

    // MARK: - 分组

    /// 一个分组 = 一支队伍（队长 + 他的执行）或"未归属"那一堆。
    private struct TeamGroup: Identifiable {
        let id: String
        let name: String
        let tint: Color?
        /// **已经排好序**的人（`TeamBoardText.order`）—— 视图不再自己排。
        let people: [ScheduledTask]
    }

    /// 分组次序 = 队伍建立次序（`mains` 就是 `scheduledTasks` 的顺序），未归属永远垫底。
    private var groups: [TeamGroup] {
        let states = store.scheduler.teamStates
        var out: [TeamGroup] = mains.map { m in
            let members = TeamBoardText.people(.team(m.id), all: allPeople)
            return TeamGroup(
                id: m.id.uuidString,
                name: m.name,
                tint: tintIndex(m, parentName: m.name).map { CodexTheme.teamTints[$0] },
                people: TeamBoardText.order(members, states: states)
            )
        }
        if !orphans.isEmpty {
            out.append(TeamGroup(id: "orphans", name: L("未归属"), tint: nil,
                                 people: TeamBoardText.order(orphans, states: states)))
        }
        return out
    }

    /// 组头右边那句:「4 人 · 2 在跑 · 1 等回执」。
    ///
    /// 只列**非零**的档 —— 四个 `0 空闲` 是噪音。这与顶栏 chip 同一口径
    /// （`TeamBoardText.statChips`），只是这里不带"个助理"三个字。
    private func groupMeta(_ people: [ScheduledTask]) -> String {
        var counts: [TeamStage: Int] = [:]
        for t in people {
            counts[TeamStage.of(store.scheduler.teamState(of: t.id)), default: 0] += 1
        }
        var parts = [String(format: L("%lld 人"), people.count)]
        for stage in TeamStage.allCases {
            guard let n = counts[stage], n > 0 else { continue }
            parts.append(String(format: L("%lld %@"), n, TeamBoardText.stageTitle(stage)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 主体

    private var boardPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if allPeople.isEmpty {
                emptyBoard
            } else {
                GeometryReader { geo in
                    // 可用宽 = min(视口, 卡区上界) − 左右内边距。用它算列数，卡片本身宽度恒定。
                    let contentCap = Tune.teamBoardMaxWidth + Tune.teamBoardHPadding * 2
                    let avail = min(geo.size.width, contentCap) - Tune.teamBoardHPadding * 2
                    let cols = TeamBoardText.cardColumns(available: avail)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(groups) { g in
                                groupSection(g, cols: cols)
                            }
                        }
                        .padding(.horizontal, Tune.teamBoardHPadding)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                        // 窄于上界 ⇒ 铺满；宽于上界 ⇒ 封顶住、靠外层 maxWidth 居中。
                        // ⚠️ 靠左会读成"右边一半坏了"（与泳道那套同一条理由）。
                        .frame(maxWidth: contentCap, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    /// 顶栏 —— 标题 + 统计 chips。原来统计行是一句纯文本，改版后做成 chip:
    /// 卡片页没有列头了，"有几件事在动"这一眼就得靠这一行；而分块才能给"在跑"上色。
    /// 成文规则（只列非零档、队伍数 >1 才出现）住在 `TeamBoardText.statChips` 里，冒烟钉着它。
    private var headerBar: some View {
        let chips = TeamBoardText.statChips(total: allPeople.count,
                                            teams: mains.count,
                                            cards: stageCounts)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L("团队"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    statChip(chip)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CodexTheme.divider).frame(height: 1)
        }
    }

    private func statChip(_ chip: StatChip) -> some View {
        HStack(spacing: 4) {
            Text(chip.value)
                .font(CodexFonts.monoFont(10.5))
                .foregroundStyle(chip.stage.map { stageTint($0) } ?? CodexTheme.textPrimary)
            Text(chip.label)
                .font(.system(size: 10.5))
                .foregroundStyle(CodexTheme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(CodexTheme.bgPill)
        }
    }

    private func groupSection(_ g: TeamGroup, cols: Int) -> some View {
        // ⚠️ 必须在**组内**分配（不是全表）：头像的用处是"这一屏里分得开谁是谁"，
        //    而两支队各有一只猫并不冲突 —— 它们本来就分在两张组头下面。
        //    这也让"超过 10 人的组"才可能重复，而不是"超过 10 个助理就开始重复"。
        let avatars = TeamAvatar.assign(g.people)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                // 组头左边那条竖条 = **队伍色**（与头像底色同源）。
                // 「未归属」没有队伍 ⇒ 中性灰，与自己那行第二行「未归属」对得上。
                // ⚠️ 高度必须写死: `Shape` 在两个方向都是贪心的，只给 width 时它会跟 HStack
                //    互相等着要尺寸，窄组头下容易塌成 0（画不出来又不报错）。
                RoundedRectangle(cornerRadius: 2)
                    .fill(g.tint ?? CodexTheme.textMuted)
                    .frame(width: Tune.teamIdentityBarWidth, height: 13)
                Text(g.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineLimit(1)
                Text(groupMeta(g.people))
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 15)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Tune.teamCardWidth),
                                                         spacing: Tune.teamCardGap),
                                     count: cols),
                      alignment: .leading,
                      spacing: Tune.teamCardGap) {
                ForEach(g.people) { t in
                    cardView(t, glyph: avatars[t.id] ?? TeamAvatar.of(t))
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

    // MARK: - 卡片

    /// 这张卡的明暗参数 —— 一档一个值，**只在这里读一次**。
    ///
    /// 三档的分法就是"手上有活吗":
    ///   · 浮起（在跑 / 已排上 / 等回执）—— 有活在手（含"交出去了在等回话"）
    ///   · 平贴（空闲）—— 没活
    ///   · 沉下（停用）—— 没活且不被派
    private struct CardLook {
        let surface: Color
        let border: Color
        let bar: Color
        /// 正文透明度。**轻推一档而已**，见文件头那段"明暗不许长在文字上"。
        let textDim: Double
        /// 头像 —— 明暗的主通道。
        let avatarDim: Double
        let avatarGray: Bool
    }

    private func look(_ stage: TeamStage) -> CardLook {
        switch stage {
        case .running:
            return CardLook(surface: CodexTheme.teamCardRaised,
                            border: CodexTheme.thinking.opacity(0.32),
                            bar: stageTint(stage), textDim: 1, avatarDim: 1, avatarGray: false)
        case .awaiting:
            return CardLook(surface: CodexTheme.teamCardRaised,
                            border: CodexTheme.accent.opacity(0.32),
                            bar: stageTint(stage), textDim: 1, avatarDim: 1, avatarGray: false)
        case .queued:
            // 已排上 = 有活、还没起跑。**也浮起** —— 这一页的明暗只回答"手上有没有活"，
            // 不回答"是正在跑还是排着队"；后者由左条颜色和状态文字说。
            return CardLook(surface: CodexTheme.teamCardRaised,
                            border: CodexTheme.border,
                            bar: stageTint(stage), textDim: 1, avatarDim: 1, avatarGray: false)
        case .idle:
            return CardLook(surface: CodexTheme.bgCard,
                            border: CodexTheme.border,
                            bar: stageTint(stage), textDim: 0.90, avatarDim: 0.88, avatarGray: false)
        case .disabled:
            // ⚠️ 2026-11-27 出图后改了两处（原来 `teamCardRecessed` + `avatarDim 0.42` + 灰）：
            //    ① **卡面回 `bgCard`**。沉下那一档（暗 0x1C1C24）和页面底色几乎同值，一屏
            //       三张停用卡整个融进背景，读起来是"这页没有卡"而不是"这些人在待命"。
            //       停用的语义是**不被派活**，不是"这个人不存在"。
            //    ② **头像不再去饱和**。灰 + 0.42 透明度是两层压制，emoji 在暗底上几乎看不见 ——
            //       而头像的全部用处就是"一屏里分得开谁是谁"，压掉它等于把这一列还回原样。
            //       "沉"已经由卡面、文字（0.82）、左条三处说了，不需要第四处。
            return CardLook(surface: CodexTheme.bgCard,
                            border: CodexTheme.border,
                            bar: stageTint(stage), textDim: 0.82, avatarDim: 0.66, avatarGray: false)
        }
    }

    /// 状态色 —— **只画在左边缘那 3px 和组头之外**，卡面不上色。
    ///
    /// 文档 §03「身份与颜色分两个通道」: 身份走**队伍色**（头像底 + 组头竖条），
    /// 状态走**色相**（琥珀 / 灰蓝 / 红 / 灰）。给卡面再上一个底色，同一屏就有两套色编码
    /// —— 而二十张卡各带底色就是一堵彩墙。
    private func stageTint(_ stage: TeamStage) -> Color {
        switch stage {
        case .running:  return CodexTheme.thinking
        case .queued:   return CodexTheme.toolQueued
        case .awaiting: return CodexTheme.accent
        case .idle:     return CodexTheme.textTertiary
        case .disabled: return CodexTheme.textMuted
        }
    }

    private func cardView(_ t: ScheduledTask, glyph: String) -> some View {
        let state = store.scheduler.teamState(of: t.id)
        let stage = TeamStage.of(state)
        let card = look(stage)
        let selected = selectedId == t.id
        let hovered = hoveringId == t.id
        let lead = TeamRowText.isTeamLead(t)
        let parentName = store.scheduler.parentName(of: t)
        let teamTint = tintIndex(t, parentName: parentName).map { CodexTheme.teamTints[$0] }
        let stat = store.scheduler.cardStat(of: t.id)

        return Button { selectedId = t.id } label: {
            VStack(alignment: .leading, spacing: 0) {
                // ① 头像 + 名字 / 归属·时态
                HStack(spacing: 8) {
                    avatar(glyph, tint: teamTint, dim: card.avatarDim, gray: card.avatarGray)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name)
                            // 名字 500 = 身份三样里的第二样。只给队长 —— 全员加粗等于没加粗。
                            .font(.system(size: 12.5, weight: lead ? .semibold : .regular))
                            .foregroundStyle(CodexTheme.textPrimary)
                            .lineLimit(1)
                        Text(TeamBoardText.cardSubtitle(t, parentName: parentName))
                            .font(.system(size: 9.5))
                            .foregroundStyle(CodexTheme.textTertiary)
                            .lineLimit(1)
                            .opacity(card.textDim)
                    }
                    Spacer(minLength: 0)
                }

                // ② 状态那行 —— 第三通道（"在跑 3 分钟"）。归属行已经只说归属，
                //    时长只在这里出现一次（2026-11-27：上一版两行都说时长，读起来像复读）。
                HStack(spacing: 4) {
                    Circle().fill(card.bar).frame(width: 5, height: 5)
                    // 只写**标签**（「停用」），后果句在检查器里 —— 见 `TeamBoardText` 里那段注释。
                    Text(TeamRowText.stateWord(state, now: Date()))
                        .font(.system(size: 10.5, weight: stage == .running || stage == .awaiting
                                      ? .medium : .regular))
                        // ⚠️ 停用 / 空闲都用 `textSecondary`（不是 `textTertiary`）：待命态是**常态**，
                        //    而截图里「已停用」在暗底上几乎读不出来 —— 状态行读不出，这张卡就只剩
                        //    名字和职责，看不出它是不是被停了。压暗那是"沉"的意思，
                        //    已经由卡面、头像 dim、左条三处说了，不必把字也压到看不清。
                        .foregroundStyle(stage == .idle || stage == .disabled
                                         ? CodexTheme.textSecondary : card.bar)
                        .lineLimit(1)
                }
                .padding(.top, 7)

                // ③ 职责两行。**固定两行高**（不是 `lineLimit(2)` 就够）——
                //    只写一行的卡会让底部三格数字与同排的卡错开一格，看着像排版坏了。
                Text(t.description.isEmpty ? "—" : t.description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 31, alignment: .topLeading)
                    .opacity(card.textDim)
                    .padding(.top, 6)

                Spacer(minLength: 0)

                // ④ 三格数字 —— **全部来自 db 聚合**，一格都不读盘（见 `TeamCardStat` 的注释）。
                //
                // ⚠️ 2026-11-27 试过两种"让待命卡少点噪声"的写法，都被 boss 否掉了：
                //    ① 组内全空 ⇒ **整行不画**：卡短半截，一页里还长得不一样，像没画完。
                //    ② 全空 ⇒ 换一句「还没被派过活」：**形态在两种之间切换**更别扭 ——
                //       同一张卡今天是一句话、明天是三格，读的人每次都得重新认一次版式。
                //    ⇒ 结论：**三格恒在**，空就写「— 0 —」。零信息也好过不稳定的版式。
                HStack(spacing: 0) {
                    numCell(stat.tokenLabel, L("token"), dim: card.textDim)
                    numCell("\(stat.turns)", L("回合"), dim: card.textDim)
                    numCell(stat.doneLabel, L("交活"), dim: card.textDim)
                }
                .padding(.top, 7)
                .overlay(alignment: .top) {
                    Rectangle().fill(CodexTheme.divider).frame(height: 1)
                }
            }
            .padding(.leading, Tune.teamCardPadH + Tune.teamIdentityBarWidth + 1)
            .padding(.trailing, Tune.teamCardPadH)
            .padding(.vertical, Tune.teamCardPadV)
            // 卡片**高度天然一致**: 职责块是 `minHeight: 31` + `lineLimit(2)`，而两行
            // 10.5pt 只有约 26pt ⇒ 无论职责写一行还是两行，块高恒是 31、卡高恒等。
            // 下面这两个 `.infinity` 是**防御**，不是实现手段: 将来谁把这个块改高
            // （比如加第四格数字），`LazyVGrid` 会让同排的卡各自按内容取高 ⇒ 数字行错开，
            // 那时 `Spacer` 才把差额吸在数字行之前。
            // ⚠️ 实测坐标（2026-11-27，`/tmp/teamrender` 探针出 2560×1600 图后逐行扫像素）:
            //    四张卡的头像块 192–243、副行 263–281、状态行 301–319、职责 327–345 与
            //    379–395、三格数字 407–422 —— **全部逐像素对齐，误差 ≤1px**。
            //    别凭缩略图判断对齐（我据一张 950pt 宽的缩略图误判过"错开一格"，
            //    真实原因是卡 4 的副行「管理」与状态行「空闲」在缩略图里被读串了）。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                // 左边缘 3px + 卡面同层、整层裁圆角 —— 竖条跟着卡片圆角走，不会在左上角露直角。
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                        .fill(selected ? CodexTheme.bgElevated : card.surface)
                    if hovered && !selected { CodexTheme.hover }
                    Rectangle()
                        .fill(card.bar)
                        .frame(width: Tune.teamIdentityBarWidth)
                }
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
            }
            // 亮色下"浮起"是白、纸是 #F8F8F8 —— 只差 Δ7，没有边就读成"一行字浮在纸上"；
            // 暗色下投影几乎不可见，所以浮起那一档的落差靠面本身（`teamCardRaised`）。
            .overlay {
                RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                    .strokeBorder(selected ? CodexTheme.accent.opacity(0.75) : card.border,
                                  lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringId = $0 ? t.id : nil }
    }

    /// 头像 —— **内置 emoji + 队伍色描边**（2026-11-27 boss 定）。
    ///
    /// 为什么不再用名字首字: 助理全叫「助理 X」⇒ 首字恒是"助"，一屏三张卡长得一模一样，
    /// 头像等于没有。内置 10 个 emoji 见 `TeamAvatar`（显式设置优先，没设过按 id 自动分配）。
    ///
    /// ⚠️ 底**不再是实心队伍色**，改成中性底 + 队伍色描边：emoji 自带颜色，再垫一个彩色圆
    ///    就是两层色彩打架（🦊 落在橙色队伍上几乎看不见）。队伍色仍在这一圈描边上，
    ///    "身份颜色"这个通道没丢，只是从面挪到了线。
    /// ⚠️ 它仍是**明暗的主通道**: 非工作态 `saturation(0)` + 降透明度 —— emoji 跟着一起变灰。
    private func avatar(_ glyph: String, tint: Color?, dim: Double, gray: Bool) -> some View {
        Text(glyph)
            .font(.system(size: 14))
            .frame(width: Tune.teamAvatarSize, height: Tune.teamAvatarSize)
            .background {
                Circle().fill(CodexTheme.bgPill)
            }
            .overlay {
                Circle().strokeBorder(tint ?? CodexTheme.textMuted, lineWidth: 1.5)
            }
            .saturation(gray ? 0 : 1)
            .opacity(dim)
    }

    private func numCell(_ value: String, _ key: String, dim: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(CodexFonts.monoFont(11.5))
                .foregroundStyle(CodexTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(key)
                .font(.system(size: 9))
                .foregroundStyle(CodexTheme.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dim)
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
                    overviewInspector
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
                .foregroundStyle(stageTint(TeamStage.of(state)))
            // 停用的后果句从卡片搬到这儿了（卡片上只留「停用」两个字，见 `TeamBoardText`）。
            // 这一栏是**点开之后**才看的，有整行空间把话说完整，不必压成半句塞进扫视面。
            if case .disabled = state {
                Text(L("派了会被拒 —— 先在编辑器里启用它。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    /// 没选卡时：**真实读数**，不是一片空白。
    ///
    /// 纯展示页的第一眼大概率是"什么都没选中"—— 那一眼若是一片空白，整页就只剩
    /// "几张卡 + 一条空横栏"，人会以为这页没做完。
    private var overviewInspector: some View {
        let lines = TeamBoardText.scopeLines(scopeName: L("全部"),
                                             total: allPeople.count,
                                             teams: mains.count,
                                             cards: stageCounts)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("当前范围"))
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textMuted)
            Text(lines.first ?? "")
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
            Text(L("点一张卡，看它的职责说明、最近五次执行与台账进度。"))
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
