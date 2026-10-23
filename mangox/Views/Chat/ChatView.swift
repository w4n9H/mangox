//
//  ChatView.swift
//  Middle column: scrolling message list + composer.
//

import SwiftUI

// MARK: - P9-#9 滚动探针 key (内容底距视口底 <140pt = 跟随区, 上滑阅读不拽回)

private struct ChatContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 「滚到底」的节拍计划

/// 「滚到底」的**节拍**（秒，相对提交那一拍）—— 第一拍立刻落，后面几拍是**复核**。
///
/// 为什么必须多于一拍（2026-10-21 实测，`/tmp/blank-probe`：真 `ChatView` + 794 事件的真实会话 +
/// 一个"收到 prompt 就沉默"的 transport，逐帧取 `CGWindowListCreateImage` 的像素分布）：
///
/// - `scrollTo(anchor: .bottom)` 的目标位置是按 `LazyVStack` 的**估算**文档高算的。同一份数据
///   实测读出过 **32,547** 和 **68,924**（≈2 倍）两种值，**6 次里 5 次是翻倍那个**。
/// - 翻倍那几次，跟随落地的那几帧视口**什么都没画**：像素 **100% 纯底色 / 0% 墨迹**（整片白），
///   而滚动条在轨道底 —— 正是 boss 报的「回车后整个对话区白掉」（10-20 他那张截图的实测
///   底色 247 / 最暗 224 也是同一件事，当时被我读成"这块视图一帧都没画"）。
/// - 紧跟一拍（哪怕还是同一个 `scrollTo`）就会重排一遍，内容立刻回来
///   （实测 +0.05s 全白 → +0.08s 恢复）。⇒ **"落一次就算完" 是错的，落完必须复核**。
///   0.1.27 只补了一拍、而且挂在补间结束回调上（那时布局还没落定），所以白屏照旧。
///
/// ⚠️ 别退回 `withAnimation`：补间的中间态按**动画插值**的布局算，实测落点差 100~260pt，
///    且"动画结束"≠"布局落定"（复核等于白做）。瞬移 + 复核实测落点误差 **0.0pt**（改前 118~189pt）。
///
/// ⚠️ 独立成类型是为了**能被冒烟断言**（`CaseFollowBeats`）：退回 `[0]` 就是白屏会一直亮着。
enum ChatFollowBeats {
    static let plan: [Double] = [0, 0.04, 0.12, 0.30]
}

// MARK: - 折叠时机

/// 一组的工具行**什么时候**折成一行收据 —— 纯函数，判据只住这里。
///
/// 折叠的触发本来是"后面又出现了一组"，也就是**用户回车的那一刻**。0.1.28 起把这一拍
/// 让开：最后一组还是**光秃秃一条用户消息**（首 token 还没回来）时，上一组先保持展开。
/// 两个理由（实测见 `/tmp/blank-probe`，`--w=760 --noforce`）：
///
/// ① 体感：折叠 = 把用户刚读完的那份答案当场收走，而他一回车正要拿新问题和旧答案对照。
/// ② 白屏：折叠与"插入一条新用户消息"落在**同一拍**时，内容高度骤降，而同一拍的
///    `scrollTo(anchor: .bottom)` 正拿 `LazyVStack` 的**估算**文档高定位 —— 估算当场放大
///    到 3 倍（实测 `documentView` 32,389 → 93,333），视口落到内容之外，整屏只剩底色
///    （像素：主色 #EEEEEE 95~100%、暗像素 0.00%、底空 538.5pt = 整个视口）。窄栏下不复原。
///    把折叠推迟到"第一段正文回来"那一拍，同样的滚动就落得稳（实测 10 次 0 白屏，
///    旧行为 4 次里 2 次白）。
///
/// ⚠️ 独立成类型是为了**能被冒烟断言**（`CaseFoldRule`）：判据散在 `projectedBlocks` 里
///    就只能靠像素探针守，而探针不进仓库。
enum ChatFoldRule {
    /// - Parameters:
    ///   - index: 组下标（0 起）
    ///   - count: 组总数
    ///   - tailIsLoneUserRow: 最后一组是不是**只有一条** `.user` 消息（还没长出任何回答）
    static func keepOpen(index: Int, count: Int, tailIsLoneUserRow: Bool) -> Bool {
        if index == count - 1 { return true }                       // 最后一组永不折叠
        if tailIsLoneUserRow && index == count - 2 { return true }  // 等回答那一拍：上一组也先原样
        return false
    }
}

struct ChatView: View {
    @ObservedObject var store: ChatStore
    @State private var viewportHeight: CGFloat = 0
    /// 最近一次内容底读数 —— 视口高**后到**时靠它重判（见 `refreshViewport`），否则判据会停在错的档上。
    @State private var lastBottomY: CGFloat = 0
    @State private var nearBottom = true   // 初始视为在底部 (初屏定位 = scrollContent 的 onAppear)
    /// 自动滚动同帧合并标记: 流式期同帧多个 chunk 只调度一次滚动 (防 "update multiple times per frame")。
    @State private var scrollScheduled = false

    /// 「这一拍跟随」的代号 —— 只为一件事：**复核拍判断有没有更新的一次跟随插进来**。
    /// 引用语义不需要（它不参与布局），但必须能让补拍的闭包读到最新值 ⇒ 用 `@State`。
    @State private var followEpoch = 0

    /// 已展开的**工具段**（键 = 段首工具消息 id，见 `ToolRun.id`）。
    ///
    /// ⚠️ 折叠态必须住在这里，**不许住行内 `@State`**：段里每来一条新工具，
    ///    收据那一行的 identity 就变（它的 id 是段首消息 id 之外的成员变化），
    ///    行内 state 会跟着重建 ⇒ 表现为"点开又自己收起"。
    /// ⚠️ 只活在这个视图实例里，**不入库**：换个会话回来一律回到收起态，
    ///    与 `UserMessageFold` / `ThinkingCardView` 的取舍一致（"上次点开过"不该变全局默认）。
    @State private var expandedRuns: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if let side = store.activeSideChat {
                SideChatBanner(info: side,
                               canJump: store.allConversations.contains { $0.id == side.parent }) {
                    store.selectConversation(side.parent)
                }
            }
            messageList
            ChatBottomBar(store: store)   // P5.0.3: 横幅 + 输入区抽共享组件 (轨迹视图同用)
        }
    }

    // MARK: - P9-#9 滚动判据

    /// 「是否已贴底」的**唯一判据** —— 抽成纯函数是为了**可断言**（冒烟 T-UI 守着它）。
    ///
    /// `contentBottomY` = 内容底相对**视口顶**的 y（`messageBlocks` 末尾那枚探针报的数）。
    /// 2026-10-16 实测它的三个取值（一次性探针，读数见当日 log）：长内容滚到顶 = **内容高**、
    /// 滚到底 = **视口高**、内容不满一屏 = **内容高**。据此「距视口底」= `contentBottomY - viewportHeight`，
    /// 落进 140pt 内才算跟随区。
    ///
    /// ⚠️ **原式 `contentBottomY > viewportHeight - 140` 是写反的**（`>` 应为 `<`、`-140` 应为 `+140`）：
    ///    它对**任何**超出一屏的内容恒为 `true` ⇒ `guard nearBottom` 形同虚设 ⇒ P9-#9 那条
    ///    「上滑阅读不拽回」**一直没有真正生效**（同一处还让"不满一屏"被误判成 `false`）。
    ///    症状是静默的（自动跟随照跑），所以只靠读代码看不出来 —— 这条断言就是为了不让它再翻回去。
    /// ⚠️ `viewportHeight == 0` 的兜底**不是**判"在底部"，是判"还没量到"（首帧）。它曾经是个
    ///    长期谎言：探针挂错位置 ⇒ 视口高恒 0 ⇒ 这一支永远命中 ⇒ `nearBottom` 恒 true。
    ///    现在视口高由 `messageList` 外层 `GeometryReader` 直接赋值，这一支只在首帧成立。
    static func isNearBottom(contentBottomY: CGFloat, viewportHeight: CGFloat) -> Bool {
        viewportHeight == 0 ? true : contentBottomY < viewportHeight + 140
    }

    /// 内容底进入视口底 140pt 内 = 跟随区 (Bool 去重, 不随滚动帧重渲染)。
    private func handleContentBottom(_ bottomY: CGFloat) {
        // ⚠️ 2026-10-19 **这条 guard 是「回到最新」按钮三次不出现的真因**。
        //    探针住在 `messageBlocks` 的 LazyVStack 末尾, 而 LazyVStack 只实例化**可见**行 ——
        //    探针滚出可见区时, 它的 GeometryReader 报 **0**, 不是"内容底在顶部"。
        //    真机日志 (每对都这样, 无一例外):
        //        near=0 bottom=831.4 viewport=642.0   ← 判对了
        //        near=1 bottom=0.0   viewport=642.0   ← 被 0 当场翻回去
        //    前两次修的是判据公式和视口高来源 (方向都对), 全被这个 0 盖掉了。
        //    0 一律当"这一拍没量到", 保留上一次的有效读数 —— 绝不能当坐标用。
        guard bottomY > 0 else { return }
        lastBottomY = bottomY
        let v = ChatView.isNearBottom(contentBottomY: bottomY, viewportHeight: viewportHeight)
        if nearBottom != v {
            nearBottom = v   // 等值不写, 防 PreferenceKey 高频触发失效性更新
        }
    }

    /// 视口高度变了就**用已知的内容底重判一次**。
    ///
    /// ⚠️ 少了这一步就有一个真实的错窗：内容底偏好可能**先于**视口高到达 —— 那时
    ///    `viewportHeight` 还是 0、判据走 `== 0 ? true` 兜底（判"在底部"）。视口高稍后到达，
    ///    但若用户没动、内容也没变，`handleContentBottom` 不会再被触发 ⇒ `nearBottom` 就停在
    ///    那个错的 `true` 上，直到下一次滚动才纠正（症状：「明明在上头看历史，新消息还是把
    ///    你拽回底部」——正是 P9-#9 要禁止的那件事）。
    private func refreshViewport(_ h: CGFloat) {
        guard viewportHeight != h else { return }
        viewportHeight = h
        if lastBottomY > 0 { handleContentBottom(lastBottomY) }
    }

    /// ⚠️ 外面这层 `GeometryReader` 是**视口高度的唯一真源**（2026-10-16 上机实测定的）。
    ///    原来把它做成一枚 `.background(...)` 里的 preference 探针：实测 `GeometryReader`
    ///    内部读数**完全正确**（视口高 642/670、内容底 24141 且随滚动变化），但**传到父层恒为 0**
    ///    —— `.background()` / `.overlay()` 是装饰层，其 preference 不并入被装饰视图的 primary
    ///    preference ⇒ `onPreferenceChange` 只收到 `defaultValue`。后果是 `isNearBottom` 一直走
    ///    `viewportHeight == 0 ? true` 的兜底 ⇒ `nearBottom` **恒 true** ⇒ ① 「回到最新」永不出现
    ///    ② P9-#9「上滑阅读不拽回」其实从未生效（0.1.22 只改了判据方向，输入是 0 等于没修）。
    ///    ⇒ 这里**直接赋值、不走 preference**；`ChatViewportHeightKey` 随之整条删掉。
    private var messageList: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                scrollColumn(proxy)
            }
            .onAppear { refreshViewport(outer.size.height) }
            .onChange(of: outer.size.height) { _, h in refreshViewport(h) }
        }
    }

    /// 滚动锚点 —— **自动跟随 / 初屏定位 / "回到最新"按钮共用同一个目标**：
    /// **内容末尾那枚恒实例化的哨兵**（见 `tailAnchor`）。
    ///
    /// ⚠️ 2026-10-23 之前这里取的是「投影后最后一块的 id」（流式期则是 `streaming-tail`），
    ///    那是个**静默失效**的锚点：`LazyVStack` 只实例化**可见**行 ⇒ 初屏时最后一块
    ///    **根本不在视图树里** ⇒ `scrollTo` 只能按**估算**的文档高落点，而且**重复调用不再
    ///    重新锚定**（同一 id 再点一次什么都不发生）。
    ///    实测（真 `ChatView` + 1014 条消息 + 1280×800 窗口，AppKit 侧读 `documentVisibleRect`）：
    ///    落点距真底 **240 / 1947 / 2701 / 2898pt** 不等（同一份代码不同次跑就不一样 ——
    ///    因为文档高在 1.1s 内还在长：39730 → 40503，长的速度取决于哪几行先被实例化），
    ///    而 0.04/0.12/0.30 这三拍**一次都没把它推到底**。
    ///    连锁症状正是 boss 报的那两条：① 打开不在最底 ② 没有「回到最新」按钮 ——
    ///    内容底探针住在最后一块**下面**（末尾 `chatVPadding 18 + 块距 10`），视口够不到它
    ///    就永不实例化 ⇒ 永远不报数 ⇒ `nearBottom` 停在初始的 `true`（那是"还没量到"的兜底）。
    /// ⇒ 现在锚 `tailAnchor`：`scrollContent` 里紧贴内容末尾的 0 高哨兵，**非 lazy ⇒ 恒实例化**。
    ///    同样条件实测 **gap = 0.0pt**（`doc - y - viewport`），探针 0.6s 内即报数。
    ///    教训一句话：**滚到底要锚在一个"此刻一定存在"的视图上**，不能锚在懒加载行的 id 上。
    /// ⚠️ 别把它当成「白屏」（0.1.27，见 `ChatFollowBeats`）的修复 —— 那条是**过冲**（估算翻倍
    ///    ⇒ 视口落到内容之外 ⇒ 整屏纯底色），这条是**欠冲**（估算偏小 ⇒ 差几百到两千多 pt 到底）。
    ///    同源不同向。A/B 实测（真 ChatView + 1014 条消息 + 1280×800，折叠 + 流式 + 再折叠，85 帧）：
    ///    贴底帧 **0 → 80**、最终 gap **264 → 0.0pt**；而越界帧**两边都是 0** ⇒ 白屏这条**没有**被证实治好。
    private var scrollTarget: AnyHashable { Self.tailAnchor }

    /// 内容末尾哨兵的 id —— ⚠️ 必须挂在**恒实例化**的视图上（理由见 `scrollTarget`）。
    static let tailAnchor = "chat-tail-anchor"

    /// **先把尾块量出来**的那个锚点 = 投影后最后一块（真实行）。
    ///
    /// ⚠️ 为什么需要两个锚点（2026-10-23 实测，真 `ChatView` + 1014 条消息 + 1280×872，
    ///    `dream → 模型部署测试` 切换后**逐帧取画面**判白）：
    ///    **只锚末尾哨兵会在切换后落进空洞**。因为 `LazyVStack` 只量过可见行，切过来的下一秒
    ///    文档高是**估的**：同一会话实测出现过 **39695 / 49203 / 50599 / 51437** 四种值，
    ///    最大值比真实内容底多了约 **840pt**（≈ 一屏高），而「锚到末尾哨兵」按那个虚高值落点
    ///    ⇒ 视口停真实内容**之下**的空白区 ⇒ **整片白**（画面实测：侧栏正常、消息列 0 墨迹，
    ///    而几何判据 gap=0 竟然成立 —— 所以在虚高文档上 `gap=0` 不代表在白处）。
    ///    ⇒ 顺序换成「**先锚最后一块，再锚哨兵**」：锚一个真实行会把它实例化、把真实高度量出来，
    ///    之后的各拍锚哨兵就落在真底（实测同一个白屏场景：`y=50719 白` → `y=49881 有内容`）。
    private var materializeTarget: AnyHashable? {
        projectedChat.blocks.last.map { AnyHashable($0.id) }
    }

    /// 回到最新 (2026-10-16 boss: "往上翻了记录, 还要再往下翻才能到最底部")。
    /// 出现条件复用 P9-#9 的 `nearBottom`（**修好后的**那个, 见 `isNearBottom`）—— 不另起一套判定,
    /// 两套判定迟早不一致, 会得到"在跟随区里却显示按钮"这种自相矛盾的状态。
    /// ⚠️ 它**只响应点击, 绝不自动滚**: "上滑阅读不拽回"是 P9-#9 立的规矩, 别让这个按钮
    ///    变成第二个自动跟随。
    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToTail(proxy)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CodexTheme.textSecondary)
                .frame(width: Tune.jumpToLatestSize, height: Tune.jumpToLatestSize)
                .background(Circle().fill(CodexTheme.bgElevated))
                .overlay(Circle().strokeBorder(CodexTheme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help(Copy.jumpToLatest)
        .padding(.bottom, Tune.jumpToLatestInset)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    /// 「滚到底」的**节拍** —— 第一拍立刻落，后面几拍是**复核**（实测依据见 `ChatFollowBeats`）。
    private static var followBeats: [Double] { ChatFollowBeats.plan }

    /// **「滚到底」的唯一实现** —— 初屏定位 / 换会话 / 提交跟随 / 回到最新 全走这里。
    ///
    /// ⚠️ 别在入口处各写一遍 `scrollTo`: 分头写就会分头漏掉复核（这个 bug 已经这样活了两个版本）。
    /// - Parameter veto: 每一拍落之前问一句"还要不要落"。`followEpoch` 变化（有更新的一次跟随）
    ///   永远是否决项；调用方再按语义追加：流式跟随要追加 `nearBottom`（P9-#9 上滑阅读不拽回），
    ///   提交那一拍**不加**（我发了消息就要看它和回答，见 `onChange(of: store.messages)`）。
    private func scrollToTail(_ proxy: ScrollViewProxy, veto: @escaping () -> Bool = { true }) {
        followEpoch += 1
        let epoch = followEpoch
        for (i, delay) in Self.followBeats.enumerated() {
            // 第一拍锚**最后一块**（把它量出来），其余各拍锚**末尾哨兵**（真底）——
            // 顺序反了就会落进"估算出来的空尾"里，那是白屏（见 `materializeTarget`）。
            var target: AnyHashable = Self.tailAnchor
            if i == 0, let materialize = materializeTarget {
                target = materialize
            }
            // 同一次调用里的每一拍是**同一件事**，所以只认 epoch 与本拍的 veto
            let tap = {
                guard epoch == followEpoch, veto() else { return }
                proxy.scrollTo(target, anchor: .bottom)
            }
            if delay == 0 { tap() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: tap) }
        }
    }

    /// 滚动列 = ScrollView + 摘要胶囊占位行 (拆子表达式, 防 type-check 超时)。
    private func scrollColumn(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            scrollContent(proxy)
                // 回到最新: 浮层挂在 ScrollView 上 (不占布局流, 不与内容互相挤压)
                // ⚠️ `!store.messages.isEmpty` 不只是"没消息就没得回" —— 空态**根本不挂**
                //    内容底探针（它住在 `messageBlocks` 的 LazyVStack 末尾，见那里注释），
                //    此时 `bottomY` 会停在旧值或偏好默认 `0`, 靠它单个判据会得到幽灵按钮。
                // ⚠️ `.animation(value:)` 必须挂在 `if` 的**父层**（挂在条件分支自己身上,
                //    insertion / removal 的 transition 不会动）; 但父层要选**只罩住按钮**的那一层 ——
                //    挂到 `scrollContent` 上就等于把动画广播进整个 ScrollView 子树(消息/滚动都在里头)。
                .overlay(alignment: .bottom) {
                    ZStack {
                        if !store.messages.isEmpty, !nearBottom {
                            jumpToLatestButton(proxy)
                        }
                    }
                    .animation(CodexTheme.animFast, value: nearBottom)
                }
            // P6.3.2: 离开摘要胶囊 — 独立占位行 (浮层会盖住最该读的最新内容, 2026-09-14 否决)
            if store.awaySummary != nil {
                HStack {
                    Spacer()
                    if let away = store.awaySummary {
                        AwaySummaryPill(
                            turns: away.turns,
                            preview: away.preview,
                            onJump: {
                                store.dismissAwaySummary()
                                scrollToTail(proxy)
                            },
                            onDismiss: { store.dismissAwaySummary() })
                            .frame(maxWidth: Tune.chatColumnWidth)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(CodexTheme.animMed, value: store.awaySummary)
    }

    /// ScrollView + 探针/锚底/滚动响应 (P9-#9)。
    private func scrollContent(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            if store.messages.isEmpty {
                if store.activeSideChat != nil {
                    sideEmptyState
                } else {
                    WelcomeView()
                        // ⚠️ 2026-10-20 boss「位置可以试试居中」：原来是 `padding(.top, 160)` ——
                        //    欢迎块钉在距顶 160pt，下面到输入卡之间空出 400pt 以上，整页像"两块
                        //    互不相干的东西"。改成在**滚动区里垂直居中**，它和输入卡才是一个整体。
                        // ⚠️ 用 `containerRelativeFrame` 而不是 `frame(minHeight: viewportHeight)`：
                        //    后者的输入来自 `onAppear` 才赋值的 state ⇒ 首帧是 0、第二帧才跳到
                        //    中间（可见的跳动）。这个取的是滚动容器自身的尺寸，没有时序问题。
                        // ⚠️ 横向的居中住在 `WelcomeView` 自己体内（`frame(maxWidth: .infinity)`），
                        //    别在这里再加一条 —— 一处负责一个轴。
                        .containerRelativeFrame(.vertical, alignment: .center)
                }
            } else {
                messageBlocks
                    // ⚠️ 2026-10-19: 探针的 preference **只在这一层收**。
                    //    它必须与探针待在**同一个布局容器**里（探针住在 `messageBlocks` 的
                    //    LazyVStack 末尾）；挂到外层 `ScrollView` 上就是跨了一条布局边界 ——
                    //    症状正是这条判据的历史病: 读数永远收不到 ⇒ `contentBottomY` 停在
                    //    默认值 ⇒ 判"贴底"恒真 ⇒ **「回到最新」按钮永不出现**（boss 报了三次）。
                    //    坐标空间 `.named("chatScroll")` 仍在 ScrollView 上，探针照样读得到。
                    .onPreferenceChange(ChatContentBottomKey.self) { handleContentBottom($0) }
                // 内容**末尾哨兵** —— 「滚到底」的唯一锚点（见 `scrollTarget` 的实测记录）。
                // ⚠️ 三条约束，缺一条就退回到"初屏落短几千 pt + 按钮永不出现"：
                //    ① 必须**在这一层**（`ScrollView` 的直接内容里）：`LazyVStack` **内部**的行
                //       只有可见时才会被实例化 ⇒ 锚在那些 id 上等于锚在一个不存在的视图上。
                //    ② 必须**紧贴内容末尾**（`messageBlocks` 之后、没有任何额外间距）：它下面
                //       多一档留白，落点就离真底远那一档。
                //    ③ 必须 `height: 0`：它是锚点不是留白 —— 底部 18pt 是 `chatVPadding` 给的。
                Color.clear.frame(height: 0).id(Self.tailAnchor)
            }
        }
        .coordinateSpace(name: "chatScroll")
        // ⚠️ 这里**不能**用锚底 (`defaultScrollAnchor(.bottom)`) —— 它会在**内容尺寸变化时重新
        //    锚底**: 展开任意一行, 整列都跳一下, 体感"点了 A 打开了 B"(与 TrajectoryView:153
        //    同一个坑, 那次只修了 Trace, 漏了这里)。改 onAppear 定位; 流式跟随由下面
        //    onChange(of: store.messages) 管。
        .onAppear {
            DispatchQueue.main.async { scrollToTail(proxy) }
        }
        .onChange(of: store.selectedConversationId) { _, _ in
            // 换会话: replay 内容整批替换, 兜底滚到最新 (首帧 onAppear 之外的双保险)
            DispatchQueue.main.async { scrollToTail(proxy) }
        }
        .onChange(of: store.messages) { old, new in
            // 流式 chunk 高频到达, 同帧多次触发会报 "update multiple times per frame";
            // scrollScheduled 同帧合并为一次滚动调度, 双跳异步复位 (滚动执行完的下一拍才放行)。
            // P9-#9: 用户上滑阅读历史时不再强制拽回 (距视口底 <140pt 才跟随)
            // ⚠️ 2026-10-09: 守卫与置位**必须都在 async 块里** —— 在 onChange 的 action 里同步写
            //    @State 本身就会让 SwiftUI 判成"同帧多次更新", 光靠守卫挡不住刷新警告 (见 :64 同款教训)。
            //
            // ⚠️ 2026-10-20 **"用户刚提交"是这条守卫唯一的例外**（boss 报「回车后整个界面白掉，
            //    直到 llm 有返回才正常」理由另有一条，见 `scrollToTail` 的实测注释：落点会落进
            //    "什么都没画"的区域）。`nearBottom` 是**几何判据**，它分不出「高度变了」和
            //    「用户上滑了」—— 在这一拍它读到什么都可能，可**语义是确定的**：我刚发了消息，
            //    就要看它和回答。⇒ 提交这一拍不吃守卫，其余每一拍（流式 / 工具 / 压缩标记…）照旧吃。
            let justSent = new.last?.role == .user && old.last?.id != new.last?.id
            DispatchQueue.main.async {
                guard !scrollScheduled else { return }
                scrollScheduled = true
                // ⚠️ 2026-10-19 起这里**不再做补间**（原先连发时降级瞬移、慢工具走 0.25s 补间）。
                //    两个理由，都是实测：① 补间的中间态按**动画插值**的布局算 ⇒ 落点差 100~260pt；
                //    ② 带补间的落点**没法复核**（复核那一拍会打断补间）。现在统一走 `scrollToTail`
                //    的"瞬移 + 复核"，高频位移下人眼分辨不出补间丢失的那点顺滑。
                if justSent {
                    scrollToTail(proxy)
                } else {
                    scrollToTail(proxy, veto: { nearBottom })   // P9-#9: 用户上滑了就停手
                }
                DispatchQueue.main.async { scrollScheduled = false }
            }
        }
    }

    /// 消息块列 (空态分流在 scrollContent)。
    /// P10.6a: LazyVStack — 原 VStack 会为全部消息实例化 MessageBlockView (每条内含
    /// MarkdownView 的块解析 + 文本布局), 长会话首帧同步主线程构建数千视图。
    /// P16 修正 (0.1.18 的回归): 块间距是**两件事** —— 回合内(同 role 连续)该紧, 回合之间该松。
    /// `LazyVStack` 只有一档 spacing, 所以把差值补到**回合首条**的 `.padding(.top)` 上。
    private struct MessageRow: Identifiable {
        let message: ChatMessage
        /// 补间距用 —— **首条为 false**（会话顶部已有 `chatVPadding`, 再加一次就是双倍顶白）。
        let isTurnStart: Bool
        /// 画作者小标用 —— **首条也为 true**（第一段也是"某个人说的", 不能因为它顶在最上面就没作者）。
        let isAuthorHead: Bool
        var id: UUID { message.id }
    }

    /// 回合边界 = **role 变化处**。同一回合的连续输出(思考 / 工具行 / 正文)各是一条独立
    /// message、role 都是 .assistant ⇒ 「同 role 连续」正好等价于「属于同一回合」。
    /// ⚠️ 上面两个标记在这个判据上**只差第一条**（`prev == nil`）—— 故意不合并:
    ///    间距与作者是两件事, 合并会让第一条消息凭空多顶 14pt。
    /// ⚠️ 上下文压缩标记 (role `.system`) 是**分界线**, 不是"谁说的": 它自己既不画作者小标,
    ///    也不吃回合首行那档加宽间距 (细线上下都该跟着走)。但它**会**把 `prev` 变成 `.system`
    ///    ⇒ 紧跟其后的 assistant 重新成为"回合首行" —— 这正是压缩点该有的观感
    ///    (压缩只发生在回合边界, 所以这条不会把某个回合从中间劈开)。
    private var messageRows: [MessageRow] {
        var out: [MessageRow] = []
        out.reserveCapacity(store.messages.count)
        var prev: MessageRole?
        for m in store.messages {
            let isMarker = m.role == .system
            out.append(MessageRow(message: m,
                                  isTurnStart: !isMarker && prev != nil && prev != m.role,
                                  isAuthorHead: !isMarker && prev != m.role))
            prev = m.role
        }
        return out
    }

    // MARK: - 投影: 已完成组里「两段正文之间」的工具行 → 一行收据

    /// 一组的**完成**判据 = 后面还有一组（下一句用户消息 / 一个压缩标记），**且后面那组已经长出行来**
    /// （0.1.28: 只剩一句孤零零的用户消息不算"完成"，那一拍先不折 —— 理由见 `projectedBlocks` 里
    /// `awaitingReply` 的注释：体感 + 白屏引信）。
    ///
    /// ⇒ **最后一组永不折叠**。它要么正在跑、要么刚答完还没被下一句顶走 ——
    ///   折它有两个病：① 答案刚读完、工具行就地收掉的跳动；
    ///   ② 要盯的("是不是在刷同一个命令")正是这一组，折了等于把证据收起来。
    /// `ForEach` 的 id 空间**按块类型分开**。
    ///
    /// ⚠️ 必须这样，因为收据的 id 就是**段首消息 id**（`ToolRun.id`），而展开后段首那一行
    ///    **也会被画出来** ⇒ 用裸 UUID 当 id 会**撞车**（同一 id 两个块）。重复 id 在 SwiftUI 里
    ///    是**未定义行为**，实测（探针复现）是：段首那条被顶掉、收据画两遍、点击也串在一起
    ///    （"展开了收不回去"、中间一片空白、收据说 2 段思考却只看见 1 段）。三者同一个根因。
    /// ⇒ 让撞车在**类型层面**不可能发生，而不是靠"记得别撞"。
    private enum ChatBlockID: Hashable {
        case row(UUID)
        case receipt(UUID)
    }

    /// `headTaken` = 这一行的**作者小标 / 回合首间距已被收据接管**，渲染时不许再画一次。
    ///
    /// ⚠️ 收据是"平移"不是"插入"：它替段首那行挂上 `MangoX` 小标与回合首间距。
    /// 折叠时那行藏起来了，没问题；**一旦展开**，那行原样回来、又挂一次 ⇒ 同一个 head 画两遍
    /// （2026-10-20 boss 真机截图：收据上方一个 `MangoX`，展开的 Reasoning 行又一个）。
    /// ⇒ 展开还原时**只对段首那一行**置 `true`。判据不是"是不是段首"，而是"收据有没有替它画"。
    private enum ChatBlock: Identifiable {
        case row(MessageRow, headTaken: Bool)
        case receipt(ToolRun, authorHead: Bool, turnStart: Bool, isExpanded: Bool)
        var id: ChatBlockID {
            switch self {
            case .row(let r, _): return .row(r.message.id)
            case .receipt(let run, _, _, _): return .receipt(run.id)
            }
        }
    }

    /// 一次投影的产物：**行** + **轮末账单**。
    ///
    /// ⚠️ 两者必须是**同一次分组**的两个产物。账单要回答"这一轮改了哪些文件"，判据就是
    ///    「这一组有哪些消息」—— 若在别处再写一遍"怎么分组"，两份判据迟早漂移，
    ///    表现是"账单说 5 个文件、收据说 4 个工具"，而两边都不报错。
    private struct ProjectedChat {
        let blocks: [ChatBlock]
        /// 宿主消息 id（该轮**末条 assistant 正文**）→ 那一轮的账。
        let bills: [UUID: TurnBill]
    }

    private var projectedChat: ProjectedChat {
        let rows = messageRows
        guard !rows.isEmpty else { return ProjectedChat(blocks: [], bills: [:]) }

        // 组边界 = `.user` 开新组；`.system`（压缩标记）自成一组 —— 它本来就不属于任何发言。
        var groups: [[MessageRow]] = []
        for row in rows {
            let role = row.message.role
            if groups.isEmpty || role == .user || role == .system {
                groups.append([row])
            } else {
                groups[groups.count - 1].append(row)
            }
        }

        // 最后一组是不是**光秃秃一条用户消息**（刚回车、首 token 还没回来）——
        // 是的话，上一组这一拍先别折（判据与实测理由都在 `ChatFoldRule`）。
        // ⚠️ 只认"最后一组没有属于它自己的行", 不认 `isStreaming`: 后者要等 `beginTurn` 才为真，
        //    而 `streamStarted` 之前那一小段同样是"只有一句新话"。残缺状态（回合失败 / 中断）下
        //    这一组会一直停在"一条用户消息", 上一组也就一直展开 —— 宁可多露一段答案, 也不白屏。
        let tail = groups[groups.count - 1]
        let awaitingReply = groups.count > 1 && tail.count == 1 && tail[0].message.role == .user

        var out: [ChatBlock] = []
        out.reserveCapacity(rows.count)

        for (gi, group) in groups.enumerated() {
            let keepOpen = ChatFoldRule.keepOpen(index: gi, count: groups.count,
                                                 tailIsLoneUserRow: awaitingReply)
            guard !keepOpen else {
                out.append(contentsOf: group.map { .row($0, headTaken: false) })
                continue
            }
            var runAt: [Int: ToolRun] = [:]
            // ⚠️ 只登记 `foldable` 的段。不可折的段（1 条 / 含 error 等）走普通行路径,
            //    于是它们连"收据"都不出现 —— 形态与改前完全一致。
            // 键用**段首在组内的下标**（不是消息 id）: 遍历是按位置走的, 用位置索引才不会错位。
            for run in ToolRunBuilder.runs(in: group.map(\.message)) where run.foldable {
                runAt[run.span.lowerBound] = run
            }

            var i = 0
            while i < group.count {
                if let run = runAt[i] {
                    let row = group[i]
                    let isExpanded = expandedRuns.contains(run.id)
                    out.append(.receipt(run,
                                        authorHead: row.isAuthorHead,
                                        turnStart: row.isTurnStart,
                                        isExpanded: isExpanded))
                    if isExpanded {
                        // 还原 = 把这段**真实占的那几行**原样放回去（含中间那条 `.think`）。
                        // 段首那行的 head 收据已经画过了 ⇒ `headTaken: true`，否则 `MangoX` 出现两次。
                        for k in run.span {
                            out.append(.row(group[k], headTaken: k == run.span.lowerBound))
                        }
                    }
                    // ⚠️ 按 `span` 前进, **不是** `memberIds.count` —— 段中间可能夹着 `.think`
                    //    （它不是边界），成员在组内**不连续**。按条数跳会跳少一格, 于是最后
                    //    一条工具"既算进收据、又单独画一行"（2026-10-20 boss 截图实测）。
                    i = run.span.upperBound
                } else {
                    out.append(.row(group[i], headTaken: false))
                    i += 1
                }
            }
        }

        // ── 轮末的账 ───────────────────────────────────────────────
        // 宿主 = 该组**最后一条 assistant 正文**（不是"最后一条消息"）：账单要贴在
        // "讲完的那段话"下面，而那段话才是 footer 工具条的主人。
        // 组末若是工具卡（模型崩在工具后面、没有收尾正文）⇒ 这一组没有宿主 ⇒ 没有账单。
        // 一处残缺好过一处撒谎。
        var bills: [UUID: TurnBill] = [:]
        let sid = store.selectedConversationId
        let lastGroup = groups.count - 1
        for (gi, group) in groups.enumerated() {
            guard let host = group.last(where: { row in
                guard row.message.role == .assistant,
                      case .text = row.message.content else { return false }
                return true
            }) else { continue }
            // 还在流式的那段不结账；**整个会话在跑时最后一组也不结** ——
            // 工具在跑的间隙里没有正文在流（`isStreaming` 是假的），只看上一条会把半轮当成讲完了。
            if host.message.isStreaming { continue }
            if gi == lastGroup && store.isStreaming { continue }
            let elapsed = sid.flatMap { store.turnElapsed(sid: $0, messageId: host.message.id) }
            let bill = TurnBillBuilder.bill(group: group.map(\.message),
                                            elapsed: elapsed,
                                            root: store.activeProjectPath)
            if !bill.isEmpty { bills[host.message.id] = bill }
        }
        return ProjectedChat(blocks: out, bills: bills)
    }

    /// `You` / `MangoX` 是**角色标签, 原样保留英文**（与 Chat / Trace 同族，见 `Tune.authorLabelSpacing`）。
    private func authorLabel(isUser: Bool) -> some View {
        Text(isUser ? "You" : "MangoX")
            .font(CodexTheme.fontAuthor)
            .tracking(0.3)
            .foregroundStyle(CodexTheme.textTertiary)
    }

    private var messageBlocks: some View {
        // 投影**只算一次**：行与轮末账单是它同一趟分组的两个产物（见 `ProjectedChat`）。
        let proj = projectedChat
        return LazyVStack(alignment: .leading, spacing: Tune.chatBlockSpacing) {
            ForEach(proj.blocks) { block in
                switch block {
                case .row(let row, let headTaken):
                    VStack(alignment: .leading, spacing: Tune.authorLabelSpacing) {
                        // P16 §03 改动六 · 2026-10-14 boss 拍板: 回合**首行**的作者锚点。
                        // 参考图的解法正是「每回合一枚小标 + 用户消息一个整栏浅灰块」—— 少了小标,
                        // 长用户消息下"谁说的"只能靠位置猜（参考图的那条规则在长消息下会失效）。
                        // ⚠️ `headTaken` 时**不画**：收据已经替这行挂过小标了。
                        if row.isAuthorHead && !headTaken { authorLabel(isUser: row.message.role == .user) }
                        MessageBlockView(message: row.message, store: store,
                                         bill: proj.bills[row.message.id])
                    }
                    // 回合首间距同理：收据那一步已经加过了，这里再加就是双份。
                    .padding(.top, (row.isTurnStart && !headTaken)
                             ? Tune.chatMessageSpacing - Tune.chatBlockSpacing : 0)
                    .id(block.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                case .receipt(let run, let head, let turnStart, let isExpanded):
                    // 收据**接管**这一段的作者小标（段首工具行原本挂着它）——
                    // 是"平移"不是"插入"：后面正文的 isAuthorHead/isTurnStart 全不用改。
                    VStack(alignment: .leading, spacing: Tune.authorLabelSpacing) {
                        if head { authorLabel(isUser: false) }
                        ToolRunReceiptRow(run: run, isExpanded: isExpanded) {
                            withAnimation(CodexTheme.animFast) {
                                if isExpanded { expandedRuns.remove(run.id) }
                                else { expandedRuns.insert(run.id) }
                            }
                        }
                    }
                    .padding(.top, turnStart ? Tune.chatMessageSpacing - Tune.chatBlockSpacing : 0)
                    .id(block.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            if store.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .tint(CodexTheme.accent)
                    Text(Copy.streamingIndicator)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                .padding(.leading, 4)
            }

            // P9-#9: 内容底部探针。⚠️ 必须是**内容树里的真实子视图** —— 它原来挂在
            // `messageBlocks.background(...)` 上，而 `.background` / `.overlay` 的 preference
            // **不向父层传播**（上机实测：内部算得全对、父层恒收 0）⇒ 判据永远是兜底值。
            // `frame(height: 0)` 让它不占高度；`.padding(.top, -spacing)` 抵掉 LazyVStack
            // 在它前面插的那一档块距，否则内容底凭空多 10pt、底部留白从 18 变 28。
            GeometryReader { g in
                Color.clear.preference(key: ChatContentBottomKey.self,
                                       value: g.frame(in: .named("chatScroll")).maxY)
            }
            .frame(height: 0)
            .padding(.top, -Tune.chatBlockSpacing)
        }
        .padding(.horizontal, Tune.chatHPadding)
        .padding(.vertical, Tune.chatVPadding)
        .frame(maxWidth: Tune.chatColumnWidth, alignment: .leading)  // 内容 + 2×水平内边距, 与 Composer 内容宽同源 (Tune.chatContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(CodexTheme.animMessage, value: store.messages.count)
    }
}

// MARK: - Side chat (P6.3.1)

/// 离开摘要悬浮胶囊 (P6.3.2): 点击任意处 = 滚底 + 消失; × = 只关不滚。
struct AwaySummaryPill: View {
    let turns: Int
    let preview: String
    var onJump: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onJump) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textMuted)
                    // 单复数分开写: 英文 "1 turn" / "N turns" 需要各自一条词条 (不靠 %lld 硬套)
                    if turns == 1 {
                        Text("离开期间完成 1 轮")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CodexTheme.textPrimary)
                    } else {
                        Text("离开期间完成 \(turns) 轮")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CodexTheme.textPrimary)
                    }
                    if !preview.isEmpty {
                        Text(L("· 最近：") + preview)
                            .font(.system(size: 12))
                            .foregroundStyle(CodexTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CodexTheme.textMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(CodexTheme.bgElevated)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(CodexTheme.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

/// 快照提示条: 侧问会话常驻顶部 — 中性 chrome 条 (非告警样式), 右端唯一 accent = 跳回源会话。
struct SideChatBanner: View {
    let info: SideChatInfo
    var canJump: Bool
    var onJump: () -> Void
    @State private var hovering = false

    /// fork 时刻紧凑格式: 今天只报时间, 跨天报 M/d HH:mm。
    private var timeText: String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(info.at) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: info.at)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CodexTheme.textMuted)
            Text("源会话快照 · 含 \(info.turns) 轮上下文 · \(timeText) fork · 主线新消息不同步")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Button(action: onJump) {
                Text("前往源会话")
                    .font(.system(size: 11, weight: canJump ? .medium : .regular))
                    .foregroundStyle(hovering && canJump ? CodexTheme.accent : CodexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .disabled(!canJump)
            .opacity(canJump ? 1 : 0.4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(CodexTheme.bgSidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CodexTheme.divider).frame(height: 1)
        }
    }
}

extension ChatView {
    /// 侧问空态 (DB 空消息起步 — 模型有记忆, 界面无历史): 引导文案替代 WelcomeView。
    var sideEmptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(CodexTheme.bgElevated)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(CodexTheme.textSecondary)
            }
            .frame(width: 46, height: 46)
            Text("直接提问，模型已了解源会话上下文")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CodexTheme.textPrimary)
            if let side = store.activeSideChat {
                Text("来自「\(side.parentTitle)」的快照 · 含 \(side.turns) 轮上下文")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
            }
        }
        .padding(.top, Tune.welcomeTopPadding + 40)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Block renderer

struct MessageBlockView: View {
    let message: ChatMessage
    @ObservedObject var store: ChatStore
    /// 这一轮的账 —— **只在该轮末条正文上非 nil**（见 `ChatView.projectedChat`）。
    /// 账号宿主是消息而不是轮，所以它跟着这一行走：换会话 / 重排 / 懒加载都不需要额外的账本。
    var bill: TurnBill? = nil
    @State private var hovering: Bool = false
    /// P7-M6c: 大图预览 (sheet, 不开独立 NSWindow — P4.2 尺寸控制坑)。
    @State private var previewAttachment: Attachment?
    /// 用户消息的展开态 —— 长消息折叠 (判据在 `UserMessageFold`)。**只活在这个视图实例里**:
    /// 滚出屏再滚回来、或换会话, 都回到折叠态。有意如此 —— 同 `ThinkingCardView` 的取舍,
    /// "上次点开过"不该变成全局默认。
    @State private var userExpanded = false
    /// 「分享」按钮的四态 —— 点了立刻回报, **失败不许静默** (失败是一个词, 不是没反应)。
    private enum ShareState { case idle, copied, tooLong, failed }
    @State private var shareState: ShareState = .idle
    /// 分享图的配色跟随当前外观 (`adaptive()` 是动态色, 离屏渲染必须显式给环境)。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // ⚠️ P16 §03 改动三：用户消息的附件挪进了整栏块**内**（见 `userBubble`）——
            //    这里只留给非用户消息（助手消息理论上不带附件，但这条通用路径保持原样）。
            if message.role != .user, let atts = message.attachments, !atts.isEmpty {
                attachmentRow(atts)
            }
            content
            if let raw = rawText {
                // 这一行**同时**装两样东西 —— 左：「复制 / 分享 / 记忆 / 重新生成」（hover 才现）,
                // 右：这一轮的账（常驻）。
                //
                // 为什么不给账另起一行（2026-10-22 贴截图拍下的）: 另起一行会让两排小字
                // 同基线 / 同字号 / 同灰度, 读起来像同一组东西的下半截 —— 分不出哪排是动作。
                // 而**本行的高度本来就在文档流里常驻**（`footerToolbar` 的注释）, 于是塞进去
                // 一分版面都不多占, 悬停长按钮时右侧也不动。
                HStack(spacing: 8) {
                    if message.role == .user { Spacer(minLength: 0) }
                    footerToolbar(raw: raw)
                        // 0.5 → 0 (2026-10-14 review): 常驻半亮的按钮从第二条消息起就成第二层噪点,
                        // 与正文抢注意力。改 hover 才现。
                        // ⚠️ `opacity(0)` **不摘除命中测试** ⇒ 必须同时关 hitTest, 否则成了
                        //    "看不见但能点到" —— 在消息下方那片空白里点一下就会复制/重新生成。
                        //    用 `opacity` 而非 `.hidden()` / 条件渲染: 18pt 高度照留, hover 时不跳。
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                        .animation(.easeInOut(duration: 0.15), value: hovering)
                    if let bill {
                        Spacer(minLength: 8)
                        TurnBillChip(bill: bill, root: store.activeProjectPath, store: store)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onHover { hovering = $0 }
        .sheet(item: $previewAttachment) { att in
            attachmentPreview(att)
        }
    }

    // MARK: - 附件 (P7-M6c: 缩略图行 + 大图预览; replay 从 events 同源渲染)

    private func attachmentRow(_ atts: [Attachment]) -> some View {
        HStack(spacing: 6) {
            ForEach(atts) { att in
                thumbnail(att)
                    .onTapGesture { previewAttachment = att }
            }
            // P16 §03 改动三：前导 `Spacer()` 改成**后置** —— 附件跟随左对齐，不再被推到右缘。
            // 原来的 `.padding(.bottom, 2)` 一并去掉：块内那个间距由容器的 `spacing: 10` 管。
            Spacer(minLength: 0)
        }
    }

    /// 88×66 圆角缩略 (scaledToFill 裁切; 点击开大图)。
    private func thumbnail(_ att: Attachment) -> some View {
        Group {
            // P9-#12: 解码结果按路径缓存, 滚动/流式重算不再重复 IO
            if let img = ImagePipeline.cachedImage(atPath: att.path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(CodexTheme.bgSidebar)
                    .overlay(Image(systemName: "photo")
                        .foregroundStyle(CodexTheme.textMuted))
            }
        }
        .frame(width: 88, height: 66)
        .clipped()
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
        .contentShape(Rectangle())
        .help("点击查看大图")
    }

    /// 大图 sheet: 原图 scaledToFit + 点击背景/Esc/按钮关闭 (Esc 为 sheet 默认)。
    private func attachmentPreview(_ att: Attachment) -> some View {
        VStack(spacing: 10) {
            if let img = ImagePipeline.cachedImage(atPath: att.path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 900, maxHeight: 620)
            } else {
                Text("图片已不存在 (附件文件被移动或删除)")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(40)
            }
            Text("\(att.fileName) · \(att.pixelWidth)×\(att.pixelHeight)")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            Button("关闭") { previewAttachment = nil }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(CodexTheme.bgBase)
        .contentShape(Rectangle())
        .onTapGesture { previewAttachment = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch message.content {
        case .text(let s):
            if message.role == .user {
                userBubble(s, attachments: message.attachments ?? [])
            } else {
                MarkdownView(text: s, isStreaming: message.isStreaming,
                             basePath: store.activeProjectPath)
            }
        case .think(let s):
            ThinkingCardView(text: s, id: message.id, isStreaming: message.isStreaming)
        case .tool(let tool):
            ToolCallCardView(tool: tool,
                             decision: store.toolDecisions[tool.id],
                             onApprove: { store.approveTool(tool.id) },
                             onDeny: { store.denyTool(tool.id) },
                             onAlwaysAllow: { store.alwaysAllowTool(tool.id) })
        case .plan(let q):
            PlanQuestionCardView(question: q)
        case .compaction(let before, let after, let reason):
            compactionMarker(before: before, after: after, reason: reason)
        }
    }

    /// 上下文压缩标记 (A) —— 一条细线夹一行小字, 居中。
    ///
    /// 为什么是**分界线**而不是卡片: 它描述的是"历史在这里断开", 不是一次发言。
    /// 卡片会跟工具卡抢同一层视觉, 而这件事应该在读完一整段之后才被注意到。
    ///
    /// 配色只取中性 token: `divider` 画线、`textTertiary` 写字 (在内容面上 4.86:1, 过 AA)。
    /// ⚠️ **不许用 `textMuted`** —— 那一档是**图标**色 (3.2:1), 拿它写字是既有约定里明令禁止的;
    /// 也**不许用琥珀** (思考专用) 或红 (错误专用): 压缩是正常事件, 不是告警。
    private func compactionMarker(before: Int, after: Int, reason: String) -> some View {
        HStack(spacing: 8) {
            compactionHairline
            Text(Copy.compactedMarker(reason: reason, before: before, after: after))
                .font(.system(size: 10.5))
                .foregroundStyle(CodexTheme.textTertiary)
                .lineLimit(1)
                .fixedSize()
            compactionHairline
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .help(Copy.compactedMarkerHelp)
    }

    private var compactionHairline: some View {
        Rectangle()
            .fill(CodexTheme.divider)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }

    private var rawText: String? {
        guard case .text(let s) = message.content else { return nil }
        return s
    }

    // MARK: - 消息底部工具条 (hover 才现; 高度常驻在文档流里, 所以不抖)

    private func footerToolbar(raw: String) -> some View {
        HStack(spacing: 10) {
            footerButton("doc.on.doc", "复制", label: "复制") { copyToPasteboard(raw) }

            // 分享 = 这条正文渲染成图片进剪贴板 (不弹窗、不落盘、不发任何对外请求)。
            // 只给助手消息 —— 用户消息的内容本来就在他手上, 要分享也是转发截图。
            if message.role == .assistant {
                footerButton(shareIcon, "把这条回复存成图片放进剪贴板", label: LK(shareLabel)) {
                    shareAsImage(raw)
                }
            }

            // P3.7: 保存为记忆 (沉淀为全局知识条目, 带会话溯源)
            footerButton("bookmark", "保存为记忆", label: "记忆") {
                store.saveAsMemory(raw, sessionId: store.selectedConversationId)
            }

            if message.role == .assistant {
                // ⚠️ 临时撤下 (boss 2026-10-14 要求) —— **功能全留着**, 只是不再有显示入口:
                //    · KnowledgeStore.distillMemoryFromCurrentSession()  ← 保留
                //    · ChatStore 的 distillRunning / distillOutcome 转发   ← 保留
                //    · ChatBottomBar 的提炼结果 banner                    ← 保留
                //    ⇒ 该方法因此**当前无视图调用点**(可正常编译, Swift 不报未引用方法)。
                //    恢复 = 去掉这一块的注释即可; 未删是为了"暂时"二字 —— 删掉就没有回程票了。
                // footerButton(store.distillRunning ? "hourglass" : "wand.and.stars",
                //              LK(store.distillRunning ? "提炼中…" : "提炼本会话 → 待审核记忆"),
                //              label: LK(store.distillRunning ? "提炼中…" : "提炼"),
                //              disabled: store.distillRunning) {
                //     store.distillMemoryFromCurrentSession()
                // }
                if !message.isStreaming {
                    footerButton("arrow.clockwise", "重新生成", label: "重新生成") { store.regenerate() }
                }
            }
        }
    }

    /// 图标 + 文字标签 (裸图标不解释, 猜谜界面不要有)
    private func footerButton(_ icon: String, _ help: LocalizedStringKey,
                              label: LocalizedStringKey? = nil,
                              disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .frame(width: 12)
                if let label {
                    Text(label)
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(CodexTheme.textTertiary)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: - 分享成图片 

    /// 图标先变 (一眼看出"成了/没成"), 文字再说清是哪一种。
    private var shareIcon: String {
        switch shareState {
        case .idle:                    return "photo.on.rectangle"
        case .copied:                  return "checkmark"
        case .tooLong, .failed:        return "exclamationmark.triangle"
        }
    }

    /// ⚠️ 用 `L()` 取词 + 调用处 `LK()` 包一层 —— 与 `ToolPhase.label` 同款。
    /// 直接把中文塞进 `LocalizedStringKey` 属性也能工作, 但会落进接线门的"未接线"一类
    /// (它只看字面量开引号前的前缀), 白白多一条要人分诊的假阳性。
    private var shareLabel: String {
        switch shareState {
        case .idle:      return L("分享")
        case .copied:    return L("已复制图片")
        case .tooLong:   return L("太长 · 改用复制")
        case .failed:    return L("出图失败")
        }
    }

    /// 出图 + 进剪贴板。实测同步 **180ms(短回复) ~ 460ms(顶到 2100pt 上限)** —— **不拆 async**:
    /// 拆了只是把卡顿藏到下一帧, 这段时间里 UI 一行都不变; 真嫌顿再加"生成中"态 (代价是多一条文案)。
    /// ⚠️ 上限从 750 抬到 2100 之后, 最坏耗时翻了一倍多 —— 上面这行数字要跟着 `shareMaxHeight` 走。
    private func shareAsImage(_ raw: String) {
        switch MessageImageShare.copyImage(
            text: raw,
            basePath: store.activeProjectPath,
            caption: message.timestamp.formatted(date: .numeric, time: .shortened),
            dark: colorScheme == .dark) {
        case .copied:   shareState = .copied
        case .tooLong:  shareState = .tooLong
        case .failed:   shareState = .failed
        }
        // 1.8 秒回常态 —— 按钮 hover 才现, 不回落的话下次 hover 还挂着上一句话
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { shareState = .idle }
    }

    // MARK: - 用户消息块

    /// 用户消息：**左对齐整栏块**（P16 §03 改动三）—— 原先是「右对齐尾部气泡」。
    ///
    /// ⚠️ 为什么不是「保留气泡、只改成左对齐」：气泡的判据是「短消息」，圆角 + 内边距在长文本下
    /// 会把整栏切成一块块；整栏块在任意长度下边界都稳定，且它与代码块、工具行**共用同一个底**
    /// （`bgCard`）⇒ 一整页只剩「纸」和「块」两种材质。
    /// ⚠️ 代价明写：短消息（三个字）时看着「空」。本版接受 —— 短消息在 MangoX 的使用里是少数。
    /// ⚠️ 附件从「块外独立一行」挪进块**内顶部**，跟随左对齐（见 `attachmentRow`）。
    /// ⚠️ 作者小标（回合首行 `You` / `MangoX`）**不住在这里** —— 它画在 `messageBlocks` 的回合
    /// 首行，因为那是「**回合**」的概念；用户消息只是恰好常常是回合首行（P16 §03 改动六）。
    private func userBubble(_ s: String, attachments atts: [Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !atts.isEmpty {
                attachmentRow(atts)
            }
            userBody(s)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
    }

    /// 用户消息正文。短文本就是一条 `Text`; 长文本走折叠 —— 判据与切分在 `UserMessageFold`,
    /// 为什么必须有这一层 (占屏 + `Text(整段)` 是平方级) 写在那里。
    @ViewBuilder
    private func userBody(_ s: String) -> some View {
        if UserMessageFold.shouldFold(s) {
            foldedUserText(s)
        } else {
            Text(s)
                .font(CodexTheme.fontBody)
                .foregroundStyle(CodexTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)   // 用户消息正文同样可选中复制
        }
    }

    /// 折叠态 = 预览 6 行 + 一行「还有 N 行 · 展开」; 展开态 = **固定高滚动区**。
    /// ⚠️ 展开态**按行渲染** (`LazyVStack`), 不是 `Text(全文)` —— 后者是平方级的。
    ///    只实例化可见行, 所以 1 万行和 100 行的展开代价一样。
    /// ⚠️ 提示必须报出**确切行数**: "还剩 1196 行"和"内容被吞了"是两件事。
    @ViewBuilder
    private func foldedUserText(_ s: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if userExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(s.components(separatedBy: "\n").enumerated()),
                                id: \.offset) { _, line in
                            userLine(line)
                        }
                    }
                }
                .frame(maxHeight: UserMessageFold.expandedMaxHeight)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(UserMessageFold.preview(s).components(separatedBy: "\n").enumerated()),
                            id: \.offset) { _, line in
                        userLine(line)
                    }
                }
            }

            Button {
                withAnimation(CodexTheme.animFast) { userExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: userExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text(userExpanded
                         ? Copy.userMessageCollapse
                         : Copy.userMessageExpand(hiddenLines: UserMessageFold.hiddenLineCount(s)))
                        .font(CodexTheme.fontTiny)
                }
                .foregroundStyle(CodexTheme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 一行。**空行写成一个空格** —— `Text("")` 高度为 0, 空行会被吃掉, 观感与原文不符。
    private func userLine(_ line: String) -> some View {
        Text(line.isEmpty ? " " : line)
            .font(CodexTheme.fontBody)
            .foregroundStyle(CodexTheme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
