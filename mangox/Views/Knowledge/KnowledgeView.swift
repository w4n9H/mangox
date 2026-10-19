//
//  KnowledgeView.swift
//  P3.7 知识库/记忆管理面板 (主区切换视图)。
//  视觉语言对齐全局: 左列 = Sidebar 行语言 (窄/紧凑/hover 选中), 编辑区 = Composer 输入卡语言
//  (无底框大字标题 + 白卡细描边正文)。注入为 spawn 期 system prompt, 改动后需"重启引擎生效"。
//

import SwiftUI

struct KnowledgeView: View {
    @ObservedObject var store: ChatStore

    /// 编辑器选中项 —— **单一选中态**。
    /// 两个独立的选中变量 (`editingId` + `editingPackFile`) 一定会在某个改动序列下出现
    /// "两个都亮 / 一个都不亮"的中间态, 而那种 bug 只在手点的时候才出现 (冒烟抓不到)。
    private enum Selection: Equatable {
        case none
        case item(UUID)      // DB 条目 (可编辑)
        case pack(String)    // persona pack 文件 (只读, 双击去 Finder)
        case base(String)    // 一个根 (只读信息面 + 改描述 / 摘库)
        case note(String, String)   // 一篇笔记 (根 id, 根内相对路径) —— P15.1 只读信息面, P15.2 起可写
        case proposal(UUID)  // 一条 dream 提案 —— **P15.3 只读**: 能看、能点开, 不能拍板
    }

    @State private var selection: Selection = .none

    // 编辑草稿 (非 .item 时视为新建)
    @State private var draftTitle: String = ""
    @State private var draftContent: String = ""
    @State private var draftScope: KnowledgeScope = .global
    @State private var draftProjectId: UUID?
    // P11.2d (2026-09-22, boss: "新增知识时这块也去掉, 就是最开始那个版本 —— 可以选择有无项目,
    // 可以选择开启和关闭, 就够用了"): 编辑器回到最简形态 = 作用域 + 标题 + 正文 + 保存。
    // 种类 / 层 / 排序三个旋钮的输入口全部撤下 —— 于是它们**不再有 draft 副本**:
    // 新建走模型缺省 (`KnowledgeItem.layer` = `.always`, 见那里的注释),
    // 编辑靠 `withUpdated` 保持原值 (撤下输入框 ≠ 清空数据)。
    // 撤下的字段与落库一个没删 —— 组装、分组、L1 落盘都还在读它们。
    /// key 被拒的原因 (**数据, 不是文案**) —— 文案在 `rejectBanner` 里拼, 见 `KeyRejection`。
    /// 编辑器已无 key 输入口, 但这条路径要留着: 手改 DB / 将来的导入器仍会撞上保留 key。
    @State private var draftReject: KnowledgeStore.KeyRejection?
    @State private var showInjection: Bool = false
    @State private var hoveringId: String?
    @State private var savedFlash: Bool = false          // 保存成功 → "已保存"短闪
    @State private var showDeleteConfirm: Bool = false
    /// 摘库确认 (内置库不可摘 ⇒ 这个对话框只会由用户库触发)。
    @State private var showDeleteBaseConfirm: Bool = false

    /// 选中根的扫描结果 (文档数在右侧信息面里给)。**不在 body 里现扫** —— 面板每次重绘都走一遍
    /// 目录树是那种"看起来没 bug、只是越来越卡"的开销。`.task(id:)` 只在换选中目标时扫一次。
    @State private var baseDocs: [KnowledgeBaseDoc] = []
    /// 左列的**根 × 笔记**快照 (P15.1)。与 `baseDocs` **分开**: 那个只服务"当前选中", 这个服务整个
    /// 列表, 两者要扫的目录不是同一个集合。同样**不在 body 里现扫**。
    @State private var rootScan: [RootScan] = []

    /// 一个根 + 它扫到的笔记。
    private struct RootScan: Identifiable {
        let base: KnowledgeBase
        let docs: [KnowledgeBaseDoc]
        var id: String { base.id }     // 路径唯一 ⇒ 根名唯一, 够当 ForEach 的身份
    }

    /// 用户**手动缩回**的根 id（`base.id` 是稳定的: 全局根是常量, 项目根是项目 UUID ⇒ 重扫不丢态）。
    ///
    /// ⚠️ 记的是「**缩回的**」而不是「展开的」（侧栏 `expandedProjects` 是对偶写法）—— 根是**扫盘现算**的,
    /// 会随项目增减出现; 记「展开的」⇒ 新根不在集合里 ⇒ **默认折叠 = 一出现就是隐形的**。
    /// 缺省必须可见（同"藏起来的入口 = 没有入口"）。侧栏靠 `onAppear` 一次性全展开拿到同一个缺省,
    /// 这里没有那个稳定时机（根每次重扫重算）, 所以换个**不依赖时机**的表达。
    @State private var collapsedRoots: Set<String> = []
    /// 用户库描述编辑草稿 (内置库描述不归用户配置, 只读展示)。
    @State private var draftBaseDesc: String = ""

    // MARK: P15.2 笔记编辑草稿

    /// 打开一篇笔记时那一版的**指纹** —— 保存时带回去比对。乐观并发的全部状态就只有这一个字符串
    /// （没有"锁定"、没有"正在编辑"标记: 磁盘才是真源, 我们只是记住"我读到的是哪一版"）。
    @State private var noteDraftHash: String = ""
    @State private var noteDraftTitle: String = ""
    @State private var noteDraftBody: String = ""
    /// 打开（或上次保存）时磁盘上的**整篇原文** —— 编辑面拿它算"改过没有", 也拿它当
    /// frontmatter 的真源（用户手写的注释 / 键顺序**逐字保留**, 我们只换 `title:` 那一行）。
    @State private var noteBaseline: String = ""
    /// 这篇支不支持改标题（非 `.md` 不支持: frontmatter 是 markdown 的东西）。
    @State private var noteTitleEditable: Bool = false
    @State private var noteReject: NoteWriteRejection?
    @State private var showNoteDeleteConfirm: Bool = false

    /// 选中那篇的**版本史**（新 → 旧）。与 `noteDraft*` **同一批读**（`.task(id: noteDraftTrigger)`）——
    /// 来源标记与变更史用的是同一份数据, 分开读就成了两个真源、两次 IO。
    ///
    /// ⚠️ **不做缓存**（同 `rootScan` 那条判据）: 它是低频写的（人点保存 / 采纳提案才变）,
    /// 而"在 `body` 里现读"会让每次重绘都打一次库。
    @State private var noteRevisions: [NoteRevision] = []
    /// 采纳 / 丢弃被拒的原因。文案在 View 侧拼 —— 与 `noteRejectText` 同一个理由:
    /// `NoteWriteRejection` 住在 `Models/KnowledgeBase.swift`, 而那个文件在
    /// `gen_strings.py` 的 `EXCLUDE_FILES` 里 ⇒ 在那边写 `L()` 的 key 永远进不了词表。
    @State private var proposalReject: NoteWriteRejection?
    /// 提案的"现在"（磁盘上目标那一篇的原文）。`nil` = 还没读到; insight 恒 `""`（目标还不存在）。
    /// **随选中项缓存**, 不在 `body` 里现读文件（同 `noteDraftTrigger` 那条判据）。
    @State private var proposalBase: String?

    /// 新建笔记的表单。
    @State private var showNewNoteSheet: Bool = false
    @State private var newNoteTitle: String = ""
    @State private var newNoteReject: NoteWriteRejection?

    private var editingId: UUID? { if case .item(let id) = selection { return id }; return nil }
    private var editingPackFile: String? { if case .pack(let f) = selection { return f }; return nil }
    private var editingBaseId: String? {
        switch selection {
        case .base(let id): return id
        // P15.1: 选中一篇笔记时, 右侧要**它的根**的信息 + 扫描结果 (`baseDocs` 靠它驱动)。
        case .note(let id, _): return id
        default: return nil
        }
    }

    /// 选中的那一篇笔记（根 + 文档）。找不到 = 文件在 App 外被删了 ⇒ 回落显示根的信息面。
    private var editingNote: (base: KnowledgeBase, doc: KnowledgeBaseDoc)? {
        guard case .note(let bid, let rel) = selection,
              let base = store.knowledgeBase(id: bid),
              let doc = baseDocs.first(where: { $0.relativePath == rel }) else { return nil }
        return (base, doc)
    }

    /// 选中的那条提案（P15.3）。找不到 = 这一批被重读了 ⇒ 回落显示条目编辑面（同 `editingNote` 的处置）。
    private var editingProposal: NoteProposal? {
        guard case .proposal(let id) = selection else { return nil }
        return store.noteProposals.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            loadBar
            Divider().overlay(CodexTheme.divider)
            HStack(spacing: 0) {
                listPane
                    .frame(width: Tune.knowledgeListWidth)
                    .background(CodexTheme.bgSidebar)
                Divider().overlay(CodexTheme.divider)
                editorPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CodexTheme.bgChat)
            }
        }
        .sheet(isPresented: $showInjection) { injectionSheet }
        .sheet(isPresented: $showNewNoteSheet) { newNoteSheet }
        .confirmationDialog("删除条目「\(draftTitle)」？",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteEditing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不可恢复; 已注入过会话的知识块不受影响。")
        }
        .confirmationDialog("摘掉知识库「\(editingBase?.displayName ?? "")」？",
                            isPresented: $showDeleteBaseConfirm,
                            titleVisibility: .visible) {
            Button("摘掉", role: .destructive) { deleteEditingBase() }
            Button("取消", role: .cancel) {}
        } message: {
            // 说清"摘掉 ≠ 删目录" —— 这是用户点下去前最需要知道的一件事。
            Text("只是不再挂载, 目录与里面的文件一个都不动。")
        }
        .confirmationDialog("删除笔记「\(noteDraftTitle)」？",
                            isPresented: $showNoteDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteEditingNote() }
            Button("取消", role: .cancel) {}
        } message: {
            // ⚠️ 两条退路都要写出来: 删除是本功能里唯一不可逆的动作, 而它其实**有**退路 ——
            //    不说, 用户就会按"删了就没了"来做决定, 于是要么不敢删、要么删错了才发现能捞。
            Text("当前内容会记进变更史; 文件移到「废纸篓」, 还能捞回来。")
        }
        .task(id: baseScanTrigger) { await reloadBaseDocs() }
        .task(id: rootScanTrigger) { await reloadRootScan() }
        // P15.2: 换选中那篇笔记时读一次磁盘（正文 / 标题 / 指纹）。**不在 `body` 里读** ——
        // 同一份文件每帧读一遍，是那种"看起来没 bug、只是越来越卡"的开销（同 `rootScan` 那条）。
        .task(id: noteDraftTrigger) { loadNoteDraft() }
        // P15.4: 换选中那条提案时读一次它的"现在"（并排 diff 的左半边）。
        .task(id: proposalBaseTrigger) { loadProposalBase() }
    }

    // MARK: - A 块: 顶部载荷条 (回答"这一轮我带什么上飞机")

    private var loadBar: some View {
        let inj = store.knowledge.lastInjection
        let fraction = min(1.0, Double(inj.residentChars) / Double(max(1, Tune.knowledgeTotalCharLimit)))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("注入量")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(CodexTheme.textMuted)
                // 带插值的取词必须走 String(format: L("…%lld…")) —— 见 KnowledgeStore.warning 的注释
                Text(String(format: L("每轮都带上 %lld 条 · %lld 字 / %lld 字"),
                            inj.residentCount, inj.residentChars, Tune.knowledgeTotalCharLimit))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                budgetBar(fraction: fraction, over: inj.overflowed)
                    .frame(width: 110, height: 4)
                Text(String(format: L("需要时才查 %lld 条 · 不占预算"), inj.onDemandCount))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                Button {
                    showInjection = true
                } label: {
                    Text(L("查看本次注入"))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("只读显示本轮真正发出去的注入块 —— 门禁绿 ≠ 改对了")
                if store.knowledgeDirty {
                    Button {
                        store.restartEngine()
                    } label: {
                        Text(L("改动未生效 · 重启引擎"))
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.thinking)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("注入块在 spawn 期生效; 点此重启引擎立刻生效")
                }
            }
            ForEach(warningLines) { line in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.toolError)
                    Text(line.text)
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.toolError)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(line.help ?? line.text)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgSidebar)
    }

    /// 一条告警的显示行。**文案在这侧拼** —— 组装器 (`KnowledgeStore`) 只出数据:
    /// 它在 `gen_strings.py` 的 `EXCLUDE_FILES` 里 (同时拼注入面文本, 注入面必须恒中文),
    /// 在那里写 `L()` 的 key **进不了词表** ⇒ 英文界面静默回落中文, 且三道门都看不见 (2026-09-22 实测)。
    private struct WarningLine: Identifiable {
        let id: String
        let text: String
        let help: String?
    }

    private var warningLines: [WarningLine] {
        store.knowledge.injectionWarnings.map { warning in
            switch warning {
            case .personaNotAtOffsetZero:
                // 结构性不变量破了: persona 段没在偏移 0 (§3.2)。这是代码回归, 不是用户能修的问题。
                return WarningLine(id: "personaOffset",
                                   text: L("人格段没有落在注入块最前 — 这是代码问题, 请反馈"),
                                   help: L("P11 §3.2: persona 段必须是独立第一段, 不参与排序与截尾"))
            case .personaPackEmpty(let cause):
                // §3.2: 段**整段消失** ⇒ agent 本轮没有"我"。措辞必须说破这一层 ——
                // "目录是空的"听着像个中性状态, 真相是人格本体一个字都没进 prompt。
                // ⚠️ 不写"被删了": App 只看得到现在的磁盘, "从未有过"与"刚被删掉"是同一个状态。
                switch cause {
                case .dirMissing:
                    return WarningLine(
                        id: "packEmptyDir",
                        text: L("人格目录不在 — 本轮 prompt 里没有「我」"),
                        help: L("点「常驻」区头的文件夹按钮: 目录不在时会就地建出来; 若那个位置被同名文件占着, 请先移走它"))
                case .noFiles:
                    return WarningLine(
                        id: "packEmptyNoFiles",
                        text: L("人格目录里没有可载入的 .md — 本轮 prompt 里没有「我」"),
                        help: L("只收 .md (大小写敏感); 若你刚要删或改名, 这条就是唯一的线索"))
                }
            case .personaUnreadableFiles(let files):
                return WarningLine(
                    id: "packUnreadable",
                    text: String(format: L("%lld 个人格文件读不出来 (权限或编码), 内容未进 prompt: %@"),
                                 files.count, namesBrief(files)),
                    help: L("文件还在磁盘上 — 用文本编辑器另存为 UTF-8 即可"))
            case .personaFrontmatterBroken(let files):
                return WarningLine(
                    id: "packBroken",
                    text: String(format: L("%lld 个人格文件 frontmatter 破损, 未注入且已禁止新建 key: %@"),
                                 files.count, namesBrief(files)),
                    help: L("修好文件开头的 --- 收尾后自动恢复; 点行尾「文件」去打开目录"))
            case .stableSegmentMissing(let titles):
                return WarningLine(
                    id: "stableMissing",
                    text: String(format: L("常驻硬规 %lld 条没进 prompt: %@"), titles.count, namesBrief(titles)),
                    help: L("稳定段永不参与降级 — 出现这条说明组装有 bug, 请反馈"))
            case .silentlyDropped(let titles):
                return WarningLine(
                    id: "silentDrop",
                    text: String(format: L("%lld 条常驻条目被静默丢弃: %@"), titles.count, namesBrief(titles)),
                    help: L("既不在 prompt 内、也不在降级清单里 — 这是 P11 要根除的那个缺陷"))
            case .residentOverflow(let titles):
                return WarningLine(
                    id: "overflow",
                    text: String(format: L("常驻超限: %lld 条未进本轮 prompt (按 priority 从低到高降级): %@"),
                                 titles.count, namesBrief(titles)),
                    help: L("去调 priority, 或把它改成「需要时才查」"))
            case .onDemandPackFiles(let files):
                // §3.2: 这类文件**不进 prompt 是对的**, 病在于它们同时进不了索引 ⇒ 对模型隐形。
                // 所以措辞不许写成"不注入" (那听着正常), 必须点破"模型不知道它存在"。
                return WarningLine(
                    id: "ondemandPack",
                    text: String(format: L("%lld 个人格文件是「按需」的, 模型不知道它们存在: %@"),
                                 files.count, namesBrief(files)),
                    help: L("它们不进 prompt, 也进不了笔记索引 (pack 目录不在任何根的扫描路径下)。把内容写成一篇笔记即可"))
            case .indexSkipped(let bases):
                // 索引段整段缺席 (Q11 方案 A)。点名每库占多少字 —— 用户才知道该摘哪个库。
                let detail = bases.map { "\($0.name) \($0.chars)" }.joined(separator: " · ")
                return WarningLine(
                    id: "indexSkipped",
                    text: String(format: L("知识库索引整段未进本轮 prompt (体积超预算): %@"), detail),
                    help: L("索引宁缺勿残 — 残缺的索引会让你以为资料只有这些; 摘掉或停用一两个库即可恢复"))
            case .indexSilentlyDropped(let bases):
                return WarningLine(
                    id: "indexDrop",
                    text: String(format: L("已挂载的知识库 %lld 个没进索引: %@"), bases.count, namesBrief(bases)),
                    help: L("既不在索引里、也不是因预算缺席 — 这是组装 bug, 请反馈"))
            case .reservedKeyConflicts(let titles):
                return WarningLine(
                    id: "conflict",
                    text: String(format: L("%lld 条与 persona pack 的 key 冲突, 已跳过注入: %@"),
                                 titles.count, namesBrief(titles)),
                    help: nil)
            }
        }
    }

    /// 红条最多列 3 条标题 (条数已在正文里, 多的折成省略号)。
    private func namesBrief(_ titles: [String]) -> String {
        titles.prefix(3).joined(separator: "、") + (titles.count > 3 ? "…" : "")
    }

    private func budgetBar(fraction: Double, over: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CodexTheme.border.opacity(0.5))
                Capsule()
                    .fill(over ? CodexTheme.toolError : CodexTheme.accent)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
    }

    /// 只读注入块: 真发出去的文本必须能被眼睛看见。
    ///
    /// **Markdown 预览** (2026-09-23 boss: "也需要改成 markdown 预览")。
    ///
    /// ⚠️ **绝不要退回"一个 `Text` 承载整块文本"** —— 那个写法在大文本上是**平方级**的,
    /// 实测 (ImageRenderer, 560pt 宽, 全高布局 = ScrollView 里的真实情形):
    ///
    /// | 行数 | `Text` 整块 | `MarkdownView` |
    /// |---|---|---|
    /// | 139 | 199 ms | 26 ms |
    /// | 561 | 4 251 ms | 105 ms |
    /// | 1 119 | 8 512 ms | 210 ms |
    /// | 3 341 | **36 108 ms** | 646 ms |
    ///
    /// 内容 ×24 ⇒ `Text` 耗时 **×181** (平方), `MarkdownView` **×24.6** (线性)。注入块的上限是
    /// 64 000 字符 ⇒ 旧写法**最长要 36 秒**, 这就是 boss 说的"卡顿到转圈圈"。
    /// 机制: `MarkdownView` 按块拆成多个小 `Text`, 每个各自布局 ⇒ 总代价线性。
    ///
    /// 复现: `python3 scripts/diag/render_probe.py`。
    ///
    /// **可复制**由行尾「复制全文」按钮承担 —— `MarkdownView` 的选中是**逐块**的,
    /// 里面没有"一次划过整篇"的选法, 而这一页的用途正是"把真发出去的文本拿走"。
    private var injectionSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("本次注入 (只读)"))
                .font(CodexTheme.fontTitle)
                .foregroundStyle(CodexTheme.textPrimary)
            ScrollView {
                Group {
                    if let block = store.knowledge.currentKnowledgeBlock, !block.isEmpty {
                        MarkdownView(text: block)
                    } else {
                        Text(L("(无注入内容)"))
                            .font(CodexTheme.fontSmall)
                            .foregroundStyle(CodexTheme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(CodexTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: CodexTheme.radius)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1))
            HStack {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(store.knowledge.currentKnowledgeBlock ?? "", forType: .string)
                } label: {
                    Text(L("复制全文"))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("整篇拿走 —— markdown 预览里的选中是逐块的, 没有一次选完整篇的选法"))
                Spacer()
                Button(L("关闭")) { showInjection = false }
                    .buttonStyle(CodexActionButtonStyle(kind: .primary))
            }
        }
        .padding(20)
        // 从 560×420 放大: markdown 有标题/列表/代码块的层级, 窄框里全挤在一起, 白瞎了它
        // 比纯文本好的那部分。这也是 boss 那句"显示效果更好"的一半。
        .frame(width: 720, height: 560)
        .background(CodexTheme.bgChat)
    }

    // MARK: - 列表 (Sidebar 行语言)

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 面板标题。**右侧那个 `+` 已移除**（2026-10-13, boss: 「那最上面那个小 + 可以移除了」）——
            // 新建条目的入口**只剩下一个**, 住在自定义区段内的 `newItemRow`。
            // 为什么移掉是对的:
            // ① 那个 `+` 挂在**面板标题**上, 它只能回答"这整块面板能新建", 回答不了"**哪一段**能新建"
            //    —— 而这正是当天踩坑的形状（删空自定义段 ⇒ 找不到落点）;
            // ② 同一个动作有两个入口、且分别落在两个层级 ⇒ 用户得先判断"这俩是不是一回事";
            // ③ **就近 > 全局**: 段的入口就在段末, 视线不必离开列表（常驻段最多 3~4 行, 自定义段
            //    永远在首屏内 —— 所以"长列表要滚回来点"这个保留理由不成立, 我自己否掉）。
            // 判据: **一个动作一个入口, 且入口住在这个动作所属的那一段里**。
            Text("知识库")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(CodexTheme.textMuted)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    // 左列 = **三个区, 按来源分** (2026-09-22 boss: "三个区域即可, 最上面的是常驻区,
                    // 然后是自定义区(就是我手动增加的), 最下面是知识库区")。
                    //
                    // 为什么按来源而不是按层: 按层分组时**同一个来源被劈成两半** —— persona 文件与
                    // 用户条目在"每轮都带上"和"需要时才查"两段里各出现一次, 那才是"看着乱"的真正来源。
                    // 层 (`isResident`) 因此降为**行内标记**, 且只在"按需"(非缺省)时出现 —— 见
                    // `PersonaRowText.subtitle`。分组维度只能有一个, 正交维度必须在行内表达 (P11.2d 同判据)。
                    let pack = store.knowledge.personaPack
                    let custom = store.customKnowledge
                    let pending = store.pendingKnowledge

                    // ① 常驻 = persona pack (固定档, 只读)。soul/user/rules 三份恒常驻; pack 里若还有人
                    //    写 `layer: ondemand`, 那一行也留在这里 (它同样是固定真源, 只是不进 prompt)。
                    //
                    // ⚠️ 区头数字取 `residentEntries.count`, **不是 `entries.count`** (2026-09-22 修)。
                    //    区头标题是一个**断言** ("这几条是常驻的"), 那数字就必须是**该断言的成员数**;
                    //    拿行数当计数会让「常驻 · 4」和载荷条「每轮都带上 3 条」并排打架 —— boss 正是
                    //    这样一眼看出不对的 (原话: "常驻4个, 但是每轮带上的显示只有3条")。
                    //    两个数**各自都对** (4 行里那 1 行副标写着"按需"), 却要解释才圆得上 ⇒ 那就是缺陷。
                    //    改后四个计数口径收敛到唯一真源 `isResident`, 与载荷条的 `residentCount` 同源。
                    //    2026-09-22 P11.4b 把最后一份 `ondemand` 的 pack 文件 (PROJECTS.md) 收编去了
                    //    知识库区 ⇒ 当前两者同集合; 但**别据此删掉下面第二个 ForEach** ——
                    //    `layer: ondemand` 仍是合法写法, 删了那类文件就静默消失 (同"可见性 ≠ 注入资格")。
                    //    ⚠️ **这一区不判空** (2026-09-23 修, 与知识库区同一条判据): "这几行的真源在
                    //    文件里" ⇒ 区头那个「文件夹」按钮是**唯一**的恢复入口, 判空会把入口一起藏掉
                    //    (藏起来的入口 = 没有入口)。人格文件缺失时它恰恰最该在。空的时候区头写「0」,
                    //    那本身就是信息 —— 而不是让整件事从界面上消失 (同"可见性 ≠ 注入资格"的病)。
                    sectionHeader(L("常驻"), count: pack.residentEntries.count, tint: CodexTheme.accent) {
                        // 这几行的真源在**文件**里 (App 内只读) ⇒ 这一段必须留一个"去哪改"的入口,
                        // 否则只读就成了死路。它以前是段脚注的一行, 现挪到区头: 入口更近, 也少一行。
                        Button {
                            let dir = store.knowledge.personaPackDir
                            // ⚠️ 目录不在时 `open` 会**静默什么都不做** —— 按钮看着能点、点了没反应,
                            //    而"人格文件没了"这个场景下它正是唯一的恢复入口 (实测 2026-09-23)。
                            //    所以先建空目录再开。这不违"App 只读不写": 那条红线管的是**正文**
                            //    (内容归用户, 双写必漂移), 这里建的只是**位置** —— 而位置本来就由 App
                            //    声明 (L1 落点 `memory/` 也在它下面)。
                            if !FileManager.default.fileExists(atPath: dir) {
                                try? FileManager.default.createDirectory(
                                    atPath: dir, withIntermediateDirectories: true)
                            }
                            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                                .foregroundStyle(CodexTheme.textTertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // ⚠️ 这里**不要**写 `.help("\(L("打开目录")) — \(path)")` —— 把 `L()` 嵌进
                        // 普通字符串插值会被词表收集器**归一化成合成 key `%@ — %@`** (外层被收、
                        // 里层那条 L() 反而不被收集 ⇒ 同一条文案既"未翻译"又"已废弃")。实测被门抓到。
                        // 拆开: tooltip 只给路径 (它的职责就是回答"在哪"), 动作名给无障碍标签。
                        .help(store.knowledge.personaPackDir)
                        .accessibilityLabel(L("打开目录"))
                    }
                    ForEach(pack.entries.filter(\.isResident)) { e in packRow(e) }
                    ForEach(pack.entries.filter { !$0.isResident }) { e in packRow(e) }
                    // ② 自定义 = 你手动加的 + 从会话沉淀的。**待审核候选排最前** —— 它们需要动作,
                    //    而"需要动作的东西埋在列表中间"是那种用户永远发现不了的 bug。
                    //
                    // ⚠️ 这一段**不判空**（2026-10-13 改口径 —— **同一根火柴第三次**）。
                    //    判据 = **这一段里有没有"用户在这个界面里能发起的动作"**（下面 ④ 反过来用它）:
                    //    提案只有**产出** ⇒ 判空（空段只是噪音）; 条目**永远可以再建一条** ⇒ 恒显示。
                    //    旧版判空踩的坑: 删掉唯一一条 ⇒ **整段（含区头）一起消失** ⇒ 段里那个入口
                    //    「像从未存在过一样」。boss 原话: 「我删除唯一一条自定义后, 发现没地方新建了」。
                    //    ⇒ **入口住的那一段不许判空**（笔记区 2026-09-23 已因同一条判据修过一次）。
                    //    修法不是补一个更聪明的 `if`, 而是**把 `if` 整个删掉**: 区头 + 条目行 + 新建行
                    //    恒渲染 —— 于是**不存在**"下次又忘了把入口带上"的位置。判据能修根因, 就不贴补丁。
                    sectionHeader(L("自定义"), count: pending.count + custom.count,
                                  tint: CodexTheme.textMuted)
                    ForEach(pending) { item in row(item) }
                    ForEach(custom) { item in row(item) }
                    newItemRow
                    // ③ 笔记 = **根分组 + 组内笔记行** (P15.1)。**不判空**: 固定根恒存在 (目录可能
                    //    还没建, 但"根"是本版主战场, 而入口住在这一段里 —— 藏起来的入口等于没有入口)。
                    //    ⚠️ 区头计数 = **笔记篇数**, 不是根数: 区头标题是一个断言 ("这些是笔记"),
                    //    数字就必须是**该断言的成员数** (同常驻区 2026-09-22 那条修正)。
                    //    分组维度也只有一个 = 根; "全局 / 项目"由**住在哪个根**表达, 不再做行内标记 ——
                    //    这正是门 1「位置即归属」在界面上的形状。
                    sectionHeader(L("笔记"), count: rootScan.reduce(0) { $0 + $1.docs.count },
                                  tint: CodexTheme.textMuted)
                    ForEach(rootScan) { group in rootGroup(group) }
                    newNoteRow

                    // ④ 提案 = dream 攒出来、**等你拍**的那批（P15.3, 只读）。
                    //
                    // ⚠️ 这一段**判空**（与上面的笔记区刻意相反）: 笔记区不判空是因为**入口住在
                    //    那一段里**（藏起来的入口 = 没有入口）; 而提案是**产出**, 没有产出就没有
                    //    任何可做的事 —— 空段只会让左列多一块"提案 · 0"的固定噪音。
                    //    判据 = 这一段里有没有"用户在这个界面里能发起的动作"。
                    if !store.noteProposals.isEmpty {
                        sectionHeader(L("提案"), count: store.noteProposals.count,
                                      tint: CodexTheme.accent)
                        ForEach(store.noteProposals) { p in proposalRow(p) }
                    }

                    if store.knowledgeItems.isEmpty && pack.isEmpty {
                        // 旧文案是「暂无条目 / 点右上角 + 新建」—— 只说了三条路里的一条, 而 user
                        // 真正想找的往往是**另外两条** (人格文件放哪 / 目录挂哪)。清单页在"什么都没有"
                        // 时是**唯一**能指路的地方, 指错路就等于没指 (2026-09-23 改口径)。
                        Text(L("还没有常驻内容\n点右上角 + 新建条目, 或用常驻区与笔记区的入口放入文件"))
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                // 容器内缩**共用侧栏那个常量** (2026-10-12) —— 两块面板常常同屏并排,
                // 表格线就是眼睛的锚点; 各写一个数字迟早会漂。这一层管的是"整块离窗口边多远"。
                .padding(.horizontal, Tune.sidebarContentInset)
                .padding(.bottom, 12)
            }
        }
    }

    /// persona pack 行 —— **只读** (右侧是 `文件` 标记, 不是开关)。
    /// 人格本体的真源是文件: 给了开关就会出现"以为关了其实还在注入"的错位 (双写必漂移)。
    private func packRow(_ entry: PersonaPackEntry) -> some View {
        let selected = selection == .pack(entry.fileName)
        let hovered = hoveringId == entry.fileName
        return HStack(spacing: 7) {
            Image(systemName: entry.isBroken ? "exclamationmark.triangle" : "text.book.closed")
                .font(.system(size: 12))
                .foregroundStyle(entry.isBroken ? CodexTheme.toolError : CodexTheme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(PersonaRowText.title(for: entry.fileName))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(selected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                Text(PersonaRowText.subtitle(for: entry))
                    .font(.system(size: 10))
                    .foregroundStyle(entry.isBroken ? CodexTheme.toolError : CodexTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            // 只读标记 —— 它回答"为什么这行没有开关", 而"没有开关却不说明"会被当成 bug
            Text(L("文件"))
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textTertiary)
                .help(L("人格文件是只读真源, 去 Finder 打开编辑"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.selected : (hovered ? CodexTheme.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? entry.fileName : nil }
        .onTapGesture { selection = .pack(entry.fileName) }
    }

    // pack 行副标曾在此私有构造 (类型 + 文件名 + 破损/按需标记)。
    // 2026-09-23 整块搬进 `PersonaRowText.subtitle(for:)` —— 判据(标题带文件名 ⇒ 副标不再带;
    // 字数取 `content.count` 而非整份文件)放在 View 的私有分支里冒烟够不着, 那条规则就没人守。
    // 留下的纪律: **一行文案的每一条判据, 都要有一个够得着的落点**。

    /// pack 段脚注已于 2026-09-22 删除 —— 它与条目行同形并排, 长得像"第四种内容"
    /// (boss 直接问"那个人格文件是干嘛的")。它的入口已挪进 **常驻区头的 folder 图标**。
    /// 留下的判据: **给一段做注脚的东西挂区头, 不要单开一行** —— 一行就意味着"它是一个条目"。

    // MARK: - 知识库区行 (P11.4b)

    // MARK: - 笔记区的根分组与笔记行 (P15.1)

    /// 一个根：小标题（小三角 · 根名 · 篇数 · 启用开关）+ 组内的笔记行。
    private func rootGroup(_ group: RootScan) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            rootHeaderRow(group)
            // 缩回 ⇒ **连引导线一起收走** —— 线是为"这些行属于上面那个根"画的, 没有行就没有归属要表达,
            // 留一根孤线只会让人以为下面还有东西。
            if !collapsedRoots.contains(group.base.id) {
                // 层级引导线：形态与侧栏 `nestedSessions` **逐项同一套常量**（同一个 `guide` token、
                // 同一个 `sidebarGuideInset`）。只跨子行区（不含根标题本身），上下各留 4pt 让线不贴相邻行。
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(group.docs, id: \.relativePath) { doc in
                        noteRow(doc, in: group.base)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Rectangle()
                        .fill(CodexTheme.guide)
                        .frame(width: 1)
                        .padding(.leading, Tune.sidebarGuideInset)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    /// 根的小标题。行内开关 = **这个根进不进索引**（与条目那个开关同形: 关掉 ≠ 删掉）。
    /// 描述不在这里铺开（它常常是两行）—— 挂到 tooltip 上, 点一下在右侧看全。
    ///
    /// 字号 11 semibold → **13 medium**（2026-10-12, 与侧栏对齐的连带面）: 组标题与它的子行
    /// 是**同字号、不同字重**（侧栏 Project / session 就是这条），否则子行 13 会**比组标题还响**。
    /// 颜色仍走 textSecondary（停用降 textMuted）—— 那一档是"这个根进不进索引"的语义, 别顺手统一。
    ///
    /// **行首小三角 = 展开/缩回**（2026-10-13 加）。三件事按判据定的, 不是随手:
    /// - **空根不画三角**（`docs.isEmpty`）—— 画了就是"点了没反应", 那是我们反复判过的形状;
    ///   但**占位保留 16**（与行图标列同宽）⇒ 有内容/没内容的根, 名字仍在同一条竖线上。
    /// - **三角自己吃掉点击**, 不并进整行的 `loadBase` —— 整行点击是"选中这个根、右侧看详情"（P11.4b
    ///   既有行为）, 不能被折叠顶掉。⚠️ 与侧栏 `projectRow` 有意不同: 那座项目行整行 = 折叠, 因为它
    ///   没有"选中后看详情"这个面。同形不同义的两个东西, 值 7 个字换清楚。
    /// - **命中区 16×16** —— 8pt 的 chevron 自身只有几个点宽, 不给 `contentShape` 就是"看得到点不到"。
    private func rootHeaderRow(_ group: RootScan) -> some View {
        let base = group.base
        let collapsible = !group.docs.isEmpty
        let collapsed = collapsedRoots.contains(base.id)
        return HStack(spacing: 7) {
            if collapsible {
                Button { toggleRoot(base.id) } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(CodexTheme.textMuted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16, height: 1)
            }
            Text(base.displayName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(base.enabled ? CodexTheme.textSecondary : CodexTheme.textMuted)
            Text("\(group.docs.count)")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textTertiary)
            Spacer(minLength: 2)
            CodexMiniToggle(isOn: Binding(
                get: { base.enabled },
                set: { _ in store.toggleKnowledgeBase(id: base.id) }
            ))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture { loadBase(base) }
        .help(base.description)
    }

    /// 展开/缩回一个根。**动画与侧栏同一档**（`animFast`）—— 一处折叠快、一处折叠慢会像两个 App。
    private func toggleRoot(_ id: String) {
        withAnimation(CodexTheme.animFast) {
            if collapsedRoots.contains(id) { collapsedRoots.remove(id) }
            else { collapsedRoots.insert(id) }
        }
    }

    /// 一篇笔记。行内三样: **标题**（给人的显示名）· **陈旧度**（只在超阈值时出现）· 根归属（分组）。
    ///
    /// - Note: 标题取 `doc.title`（frontmatter `title:` 回落文件名去扩展名）——
    ///   而**索引行给的是相对路径**: 模型需要一个能直接 `read` 的定位符, 人需要的是一个读得懂的名字。
    ///   两个消费者要的不是同一样东西, 所以这里刻意不共用同一个字段。
    private func noteRow(_ doc: KnowledgeBaseDoc, in base: KnowledgeBase) -> some View {
        let selected = selection == .note(base.id, doc.relativePath)
        let hovered = hoveringId == "note:" + base.id + ":" + doc.relativePath
        let days = KnowledgeBaseScan.staleDays(doc.modifiedAt)
        return HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                // 默认色用中性灰（跟侧栏会话行同档）；**陈旧才换 `toolError`** —— 陈旧 ≠ 错误，
                // 但这里是"该回头看它了"的提醒色，保留原语义。
                .foregroundStyle(days == nil ? CodexTheme.textSecondary : CodexTheme.toolError)
                .frame(width: 16)
            Text(doc.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(!base.enabled ? CodexTheme.textMuted
                                 : (selected ? CodexTheme.textPrimary : CodexTheme.textSecondary))
            Spacer(minLength: 2)
            if let days {
                // 只在超阈值时出现 —— "天天显示 1 天"是噪音, 标记要有信息量。
                Text(String(format: L("%lld 天未更新"), days))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
            }
        }
        .padding(.leading, Tune.sidebarRowIndent)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(selected ? CodexTheme.selected : (hovered ? CodexTheme.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? "note:" + base.id + ":" + doc.relativePath : nil }
        .onTapGesture { selection = .note(base.id, doc.relativePath) }
    }

    /// 新建笔记入口 —— P15.1 只到"把目录准备好"为止; **P15.2 起真的建一篇**。
    ///
    /// 只留**一个**入口、且固定落全局根: 门 1 的两个根都归用户, 但入口多一个就多一次
    /// "这条属于谁"的判断, 而那个判断用户往往还没做。放全局根最坏只是"先记下来, 回头再分";
    /// 落到项目根错了才麻烦（项目没了它就没了）。参数化"建到哪个根"等真有这个需求时再说。
    ///
    /// 「打开笔记目录」那个动作没消失, 挪去了编辑面底部 —— 它现在不是主路径了。
    private var newNoteRow: some View {
        let hovered = hoveringId == "new-note"
        return HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 12))
                .foregroundStyle(CodexTheme.textTertiary)
                .frame(width: 16)
            Text(L("新建笔记"))
                .font(.system(size: 13))
                .foregroundStyle(CodexTheme.textMuted)
            Spacer(minLength: 2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(hovered ? CodexTheme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? "new-note" : nil }
        .onTapGesture {
            newNoteTitle = ""
            newNoteReject = nil
            showNewNoteSheet = true
        }
        .help(L("写一篇新笔记 (存到全局笔记目录, 下一轮组装就会带上它)"))
    }

    /// 新建条目入口 —— **住在自定义区段内**（2026-10-13 加）。
    ///
    /// 为什么必须住在段内: 面板标题行那个 `+` 是**整块面板的工具栏**, 它回答的是"这个面板能新建",
    /// 不是"**这一段**能新建"。而这一段此前是判空的 ⇒ 删掉唯一一条, 整段连区头一起消失,
    /// 用户视线落在这一段的位置上就**什么都看不见了**（boss 实测: 删完就找不到入口）。
    /// 这是「藏起来的入口 = 没有入口」又一次实证 —— 两次都发生在**同一个位置类型**上。
    ///
    /// 形态与「+ 新建笔记」**逐项同款**（图标字号 / 占位 / 行高 / 悬停底 / 内缩）—— 两段都
    /// 必须能就地新建, 而"一段有、一段没有"正是这次踩坑的形状本身。
    ///
    /// 给的是**零新增文案**：行文字「新建条目」已经自明（面板 `+` 的 tooltip 也是这三个字,
    /// 再挂一遍是同义反复); 而目的地在点开后的右栏**可见**（scope 控件在那儿）⇒ 这里不像
    /// `newNoteRow` 那样有个"目的地是隐藏约定"要解释。不新增词条 ⇒ 本轮 l10n 三道读数
    /// **应当逐字不变**（这本身就是可核对的一条）。
    private var newItemRow: some View {
        let hovered = hoveringId == "new-item"
        return HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 12))
                .foregroundStyle(CodexTheme.textTertiary)
                .frame(width: 16)
            Text(L("新建条目"))
                .font(.system(size: 13))
                .foregroundStyle(CodexTheme.textMuted)
            Spacer(minLength: 2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(hovered ? CodexTheme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? "new-item" : nil }
        .onTapGesture { startNew() }
    }

    // MARK: - dream 提案（P15.3 只读面 · P15.4 起可拍板）

    /// 三类动作的行内标记。**文案在这里拼** —— `NoteProposalKind` 是模型层的数据,
    /// 而 `Models/NoteProposal.swift` 不在 `gen_strings.py` 的 `EXCLUDE_FILES` 里:
    /// 在那边拼中文要么漏掉 `L()`、要么把 key 写进一个语义不对的地方（域层只出数据）。
    private func proposalKindLabel(_ kind: NoteProposalKind) -> String {
        switch kind {
        case .insight: L("增")
        case .merge: L("并")
        case .replace: L("换")
        case .delete: L("删")
        }
    }

    /// 四种动作的配色——同时充当"这个标记到底在说什么"的唯一图例:
    /// 增 = 长出新东西(green) · 并 = 把两样合成一样(blue) · 换 = 旧值过期, 提醒你看一眼(amber) ·
    /// 删 = 整条作废(red: 这一条谈的是**丢掉东西**, 不是一次普通修改)。
    private func proposalKindColor(_ kind: NoteProposalKind) -> Color {
        switch kind {
        case .insight: CodexTheme.toolDone
        case .merge: CodexTheme.info
        case .replace: CodexTheme.thinking
        case .delete: CodexTheme.toolError
        }
    }

    /// 提案行的一句话: 有 `title` 就用它, 否则拿正文第一行(去掉 markdown 的 `#` 与缩进)。
    /// **不发明占位** —— 拿不出话的提案在解析阶段就被拒了, 走不到这里。
    ///
    /// ⚠️ `delete` 是唯一的例外: **它既没有 `title` 也没有 `content`**（产出不是文字, 是"进废纸篓"）
    /// ⇒ 它的一句话就是**要被删掉的那一篇**（根内相对路径）。留空才是真的在说谎 ——
    /// 一行只写着「删」却不说是删哪篇, 人没法拍板。
    private func proposalHeadline(_ p: NoteProposal) -> String {
        if p.kind == .delete { return p.targetPath }
        if !p.title.isEmpty { return p.title }
        var line = p.content.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        while line.hasPrefix("#") || line.hasPrefix(" ") { line.removeFirst() }
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    /// `全局笔记 / shell-quirks.md` —— 归属由**根的显示名**表达（门 1: 位置即归属）。
    private func proposalTargetLabel(_ p: NoteProposal) -> String {
        let root = store.knowledgeBase(id: p.rootId)?.displayName ?? p.rootId
        return root + " / " + p.targetPath
    }

    /// 一条提案行: 两行 —— 动作 + 一句话 / 目标 + 来源条数。
    ///
    /// ⚠️ **P15.8/5f**: 不再有"已拍板"的行（采纳 / 丢弃都**直接删行**）⇒ 这里没有降档分支,
    /// 表里出现的每一条都**在等你拍**。旧版那套「终态整行降档」随终态概念一起去掉了。
    private func proposalRow(_ p: NoteProposal) -> some View {
        let selected = selection == .proposal(p.id)
        let hovered = hoveringId == "proposal:" + p.id.uuidString
        return HStack(spacing: 7) {
            // 窄列标记: 中文是单字(10pt 宽 ≈10), 英文是 New / Merge / Swap 这类词 —— 用 `minWidth`
            // 让框跟着内容走: 中文居中落在 16pt 框里, 英文加宽而不溢出压住标题。
            // 16 与其余行的图标占位**同宽** —— 否则各段的标题起跑线不在一条竖线上 (侧栏对齐)。
            Text(proposalKindLabel(p.kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(proposalKindColor(p.kind))
                .frame(minWidth: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposalHeadline(p))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(selected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                Text(proposalTargetLabel(p) + " · "
                     + String(format: L("%lld 个来源"), p.sources.count))
                    .font(CodexFonts.monoFont(9))
                    .lineLimit(1)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer(minLength: 2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.selected : (hovered ? CodexTheme.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? "proposal:" + p.id.uuidString : nil }
        .onTapGesture { selection = .proposal(p.id) }
    }

    private static let proposalStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// 提案的审阅面（P15.3 起只读；**P15.4 起可拍板**；P15.8/5f 起只剩待审这一种形态）。
    ///
    /// ⚠️ P15.3 那句"这里没有采纳 / 丢弃按钮, 不是没做完, 是做完了"现在**过期了** ——
    /// 那两个动作正是本批的正面。变的不是纪律而是位置: 从提案到磁盘的路径**现在存在**,
    /// 但它只有一个入口（下面那两个按钮）, 且必须由人按下。
    ///
    /// 也不再需要"已拍板就不用画 diff"那个分支: 拍完板的行已经被删掉了, **能走到这里的
    /// 恒是待审** ⇒ diff 与两个按钮恒画。
    private func proposalEditor(_ p: NoteProposal) -> some View {
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(L("提案"))
                    .font(CodexTheme.fontTitle)
                    .foregroundStyle(CodexTheme.textPrimary)
                Text(proposalKindLabel(p.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(proposalKindColor(p.kind))
                Spacer()
                Text(proposalStampLine(p))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                factRow(L("目标"), value: proposalTargetLabel(p), mono: true)
                factRow(L("为什么提"), value: p.reason.isEmpty ? "—" : p.reason, mono: false)
                // 指纹只在 merge / replace 上有 —— 它是"提出时那一版长什么样"的凭据,
                // insight 的目标还不存在, 所以留空而不是补个假的。
                if !p.baseHash.isEmpty {
                    factRow(L("提出时的指纹"), value: String(p.baseHash.prefix(16)), mono: true)
                }
            }
            proposalSources(p)

            // 并排 diff **恒画**（P15.8/5f: 能走到这里的都是待审 —— 拍过板的行已经删了,
            // 不存在"两栏已经相等"那种情况了）。
            proposalDiffBlock(p)
            if let reject = proposalReject { noteRejectBanner(reject) }
            HStack(spacing: 8) {
                // ⚠️ **不弹二次确认**（与删除相反）: 采纳是**可逆**的 —— 被顶掉的那一版
                //    进了版本史, 写下去的也能再改回来。为可逆动作加一道确认, 只会训练用户
                //    闭眼点"确定"（而删除那道确认的份量正是靠"它不可逆"撑起来的）。
                // delete 上写「采纳」是**说不清的**: 它要采纳的是"把这篇删掉"。
                // 按钮仍是同一个动作、同一个出口, 只把动词换成它真正会做的事。
                Button(p.kind == .delete ? L("删掉这篇") : L("采纳")) { adoptProposal(p) }
                    .buttonStyle(CodexActionButtonStyle(kind: .primary))
                    .help(p.kind == .delete
                          ? L("把这一篇移进系统废纸篓; 旧内容会先进变更史")
                          : L("把这一份整篇写进上面那条目标; 被顶掉的那一版会进变更史"))
                // P15.8/5f: 丢弃 = **把这条提案删掉**（不再落终态留在列表里）。
                Button(L("丢弃")) { discardProposal(p) }
                    .buttonStyle(CodexActionButtonStyle(kind: .danger))
                    .help(L("删掉这条提案; 磁盘上的笔记一个字节都不会动"))
                Spacer()
            }
            Text(L("采纳前, 磁盘上的笔记一个字节都不会变 —— 上面那份 diff 只是「如果」。"))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 提案的并排 diff（P15.4）

    /// 并排 diff: 左 = **现在**（磁盘上的那一版）, 右 = **采纳后**（提案的 `content`）。
    ///
    /// 为什么必须是并排、且必须是**整份**: dream 的产出粒度是"整篇重写或新增一篇"
    /// （它做不了逐行手术, 见 P15 §03 提炼 ⑤）⇒ 人拍板时要判断的是"这一整篇换上去行不行",
    /// 而不是"这一行改得对不对"。P15.3 那个只看新版的预览正是**没有对照**才必须截断行数。
    ///
    /// ⚠️ 仍然按行渲染（一个 `Text` 装整块是平方级开销）。这里不再设行数上限 ——
    /// `NoteDiff` 自带规模护栏（超 `maxCells` 退化成整体替换, 语义依然诚实）。
    private func proposalDiffBlock(_ p: NoteProposal) -> some View {
        let rows = NoteDiff.lines(old: proposalBase ?? "", new: p.content)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                Text(L("现在"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("采纳后"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(CodexTheme.fontTiny)
            .foregroundStyle(CodexTheme.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        diffCell(row.left, kind: row.kind)
                        diffCell(row.right, kind: row.kind)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(CodexTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
            if p.kind == .insight {
                Text(L("左边是空的 —— 这是一篇**还不存在**的笔记(增)。"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            if p.kind == .delete {
                Text(L("右边是空的 —— 采纳后这篇进系统废纸篓, 还能在那里捞回来。"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
        }
    }

    /// 并排 diff 的一格。`nil` = 这一格空着（对面那一侧有内容）。
    ///
    /// 着色只落在**有内容的那一格**上 —— 空的那一格涂色会把"这里什么都没有"
    /// 也画成一次改动, 于是"删了一行"看起来像"删一行 + 凭空多一行"。
    private func diffCell(_ text: String?, kind: NoteDiffLine.Kind) -> some View {
        let tint: Color? = {
            guard text != nil else { return nil }
            switch kind {
            case .same: return nil
            case .added: return CodexTheme.toolDone.opacity(0.16)
            case .removed: return CodexTheme.toolError.opacity(0.16)
            }
        }()
        return Text(text ?? " ")
            .font(CodexTheme.fontMonoSm)
            .foregroundStyle(text == nil ? Color.clear
                                         : (kind == .same ? CodexTheme.textMono
                                                          : CodexTheme.textPrimary))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(tint ?? Color.clear)
    }

    /// 时间戳那一行: 提出于 X。
    ///
    /// ⚠️ P15.8/5f: 原来还有一段"拍板于 Y"（P15.4）—— 随终态一起去掉了:
    /// 拍过板的行**已经不在表里**, 没有哪一行还能有"拍板时刻"。「待审了多久」这个问题
    /// 现在由"提于 X"单独回答（收件箱里唯一存在的那段时间）。
    private func proposalStampLine(_ p: NoteProposal) -> String {
        String(format: L("提于 %@"), Self.proposalStamp.string(from: p.createdAt))
    }

    /// `.task(id:)` 的重扫键 —— 换选中那条提案时重读它的"现在"。
    private var proposalBaseTrigger: String {
        guard case .proposal(let id) = selection else { return "" }
        return id.uuidString
    }

    /// 读提案的"现在"（= 磁盘上目标那一篇的原文）。insight 的目标还不存在 ⇒ 空串。
    ///
    /// **不在 `body` 里读** —— 那是每帧一次文件 IO（同 `noteDraftTrigger` / `rootScan` 那条）。
    private func loadProposalBase() {
        proposalReject = nil
        guard let p = editingProposal else { proposalBase = nil; return }
        if p.kind == .insight { proposalBase = ""; return }
        proposalBase = store.knowledge.readNote(rootId: p.rootId, relativePath: p.targetPath) ?? ""
    }

    private func adoptProposal(_ p: NoteProposal) {
        proposalReject = store.knowledge.adoptProposal(p)
        guard proposalReject == nil else { return }
        // 磁盘变了 ⇒ 左列的"陈旧度/摘要"与这篇的版本史都得重读（提案本身也会刷新成终态）。
        Task { await reloadRootScan() }
    }

    private func discardProposal(_ p: NoteProposal) {
        proposalReject = store.knowledge.discardProposal(p)
    }

    private func factRow(_ label: String, value: String, mono: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(mono ? CodexTheme.fontMonoXs : CodexTheme.fontSmall)
                .foregroundStyle(mono ? CodexTheme.textMono : CodexTheme.textSecondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// 来源指针 —— **它们是"这条提案凭什么可信"的全部依据**（§05: 拿不出指针的不入表）。
    /// `quote` 为空就不画那一行: 强制模型编一句"原话"比让它留空更糟。
    private func proposalSources(_ p: NoteProposal) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(format: L("来源 · %lld 条"), p.sources.count))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            ForEach(Array(p.sources.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 8) {
                    Text(s.kind == .session ? L("会话") : L("笔记"))
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textTertiary)
                        .frame(width: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.ref)
                            .font(CodexTheme.fontMonoXs)
                            .foregroundStyle(CodexTheme.textMono)
                            .textSelection(.enabled)
                        if !s.quote.isEmpty {
                            Text(s.quote)
                                .font(CodexTheme.fontSmall)
                                .foregroundStyle(CodexTheme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func row(_ item: KnowledgeItem) -> some View {
        let selected = isEditing(item)
        let hovered = hoveringId == item.id.uuidString
        let isPending = item.status == .pending
        return HStack(spacing: 7) {
            Image(systemName: isPending ? "wand.and.stars"
                            : (item.source == .session ? "bookmark.fill" : "doc.text"))
                .font(.system(size: 12))
                // 三档都是**语义**（待审 accent / 会话沉淀 thinking / 其余中性），不是缺省色，
                // 所以这行只跟字号与占位宽度（侧栏对齐），颜色一个不动。
                .foregroundStyle(isPending ? CodexTheme.accent
                                 : (item.source == .session ? CodexTheme.thinking : CodexTheme.textMuted))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(!item.enabled || isPending
                                     ? CodexTheme.textMuted
                                     : (selected ? CodexTheme.textPrimary : CodexTheme.textSecondary))
                Text(subtitle(item))
                    .font(.system(size: 10))
                    .foregroundStyle(isPending ? CodexTheme.accent.opacity(0.8) : CodexTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            // C 块: 命中列 (P11.1 只留位 —— 记账在 P11.3; 占位期**整列不降档**,
            // 因为"降一档灰度"是"真·从未命中"的语义, 借用它会把"还没记账"说成"没人用过")
            Text(hitLabel(item))
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textTertiary)
                .frame(width: 16, alignment: .trailing)
                .help("命中统计将在启用后生效")
            if !isPending {
                CodexMiniToggle(isOn: Binding(
                    get: { item.enabled },
                    set: { _ in store.toggleKnowledge(id: item.id) }
                ))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.selected : (hovered ? CodexTheme.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? item.id.uuidString : nil }
        .onTapGesture { loadDraft(item) }
    }

    /// 分组小标 (有内容才出现; 分组维度 = 层)
    private func sectionHeader(_ title: String, count: Int, tint: Color) -> some View {
        sectionHeader(title, count: count, tint: tint, accessory: { EmptyView() })
    }

    /// 区头 + 右侧附件。附件是**给这一段做注脚**的东西 (如"人格文件的真源在哪")。
    ///
    /// 为什么附件挂区头而不是单独一行脚注 (2026-09-22 boss: "那个人格文件是干嘛的, 应该是要移除的吧")：
    /// 脚注**长得像一条内容** —— 它和条目行、知识库行同形并排, 于是读起来像"第四种东西",
    /// 而它其实只是这一段的元信息。挂在区头就不再有"它是不是一条数据"的歧义, 也少一行。
    private func sectionHeader<V: View>(_ title: String, count: Int, tint: Color,
                                        @ViewBuilder accessory: () -> V) -> some View {
        // 度量对齐侧栏的区头 (2026-10-12)：12 regular + tracking 0.3 是"大而轻的货架标签"，
        // 10 semibold 会把它读成次级按钮。内缩 10 / 上间距 14 与侧栏**同一个数**，不是巧合。
        // ⚠️ `tint` 是**语义**不是度量：「常驻 · N」保留 accent（那一段是"始终进 prompt"的断言），
        //    其余三区走灰。对齐的是字号与间距，不是颜色 —— 别顺手把它也统一了。
        HStack(spacing: 5) {
            Text("\(title) · \(count)")
                .font(.system(size: 12))
                .tracking(0.3)
                .foregroundStyle(tint)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    /// C 块: 命中数 (P11.1 无记账 ⇒ 恒 `—`; 语义见 §4.2 C, 不要在这里动手脚)
    private func hitLabel(_ item: KnowledgeItem) -> String { "—" }

    /// 行副标: **种类标签在前**, 后接作用域, 末尾是**按需标记**。
    /// `L()` 取词 —— 模型层的 `tag` 是中文原文 (注入块要用原文, 见 `KnowledgeKind.tag`)。
    private func subtitle(_ item: KnowledgeItem) -> String {
        var parts = ["\(L(item.kind.tag)) · \(scopeLabel(item))"]
        // 层已不再是分组维度 (分区按来源), 所以它必须在**行内**可见 —— 否则"这条会不会进 prompt"
        // 在面板上无处可查。只在"按需"(非缺省)时标: 新建缺省是常驻 (见 `KnowledgeItem.layer`)。
        if !item.isResident { parts.append(L(item.layer.tag)) }
        return parts.joined(separator: " · ")
    }

    private func scopeLabel(_ item: KnowledgeItem) -> String {
        var parts: [String] = []
        parts.append(item.scope == .global
                     ? L("全局")
                     : store.projects.first { $0.id == item.projectId }?.title ?? L("未知项目"))
        if item.status == .pending {
            parts.append(L("待审核 · 提炼候选"))
        } else if item.source == .session {
            parts.append(L("记忆"))
        }
        return parts.joined(separator: " · ")
    }

    private var editingItem: KnowledgeItem? {
        guard case .item(let id) = selection else { return nil }
        return store.knowledgeItems.first { $0.id == id }
    }

    /// 选中的 pack 文件 (现读磁盘的结果 —— 与组装校验**同源**)。
    private var editingPackEntry: PersonaPackEntry? {
        guard let file = editingPackFile else { return nil }
        return store.knowledge.personaPack.entry(file)
    }

    /// 选中的知识库 —— 走 `store.knowledgeBase(id:)` (它返回**带生效态**的那一份, 与注入路径同源)。
    private var editingBase: KnowledgeBase? {
        guard let id = editingBaseId else { return nil }
        return store.knowledgeBase(id: id)
    }

    private func isEditing(_ item: KnowledgeItem) -> Bool { selection == .item(item.id) }

    // MARK: - 编辑器 (Composer 输入卡语言)

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let entry = editingPackEntry {
                    packEditor(entry)
                } else if let note = editingNote {
                    noteEditor(note.doc, in: note.base)
                } else if let proposal = editingProposal {
                    proposalEditor(proposal)
                } else if let base = editingBase {
                    baseEditor(base)
                } else {
                    controlsRow
                    if let reject = draftReject { rejectBanner(reject) }
                    if let item = editingItem, let note = item.note, !note.isEmpty {
                        distillNoteBanner(note)
                    }
                    titleField
                    contentCard
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: Tune.knowledgeEditorMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - persona pack 文件的只读面

    /// 人格文件**只读** —— 不给可写控件。给了就会有一份"App 里的版本"和一份"文件里的版本",
    /// 而双写必漂移 (P3.9)。这里只做三件事: 说清它是谁 / 让你去改文件 / 把真源摆出来看。
    private func packEditor(_ entry: PersonaPackEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(PersonaRowText.title(for: entry.fileName))
                    .font(CodexTheme.fontTitle)
                    .foregroundStyle(CodexTheme.textPrimary)
                Text(L("文件"))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: store.knowledge.personaPackDir + "/" + entry.fileName)])
                } label: {
                    Text(L("在 Finder 打开"))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    store.reloadPersonaPackAndRefresh()
                } label: {
                    Text(L("重新读取"))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("在 App 外改完文件后点这里; 已开着的会话仍需重启引擎才生效"))
            }

            if entry.isBroken {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.toolError)
                    Text(L("frontmatter 破损 (开头的 --- 没有收尾): 该文件不进 prompt, 且已保守禁止新建 key。修好即恢复。"))
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.toolError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CodexTheme.toolError.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
            } else {
                // 破损时**不显示层** —— `layer` 在破损文件上恒为编造的缺省 `.always` (`PersonaPack.load`
                // 的 `p.layer ?? .always`, 而 parse 在破损时提前 return、根本没读 layer)。
                // 该文件实际不进 prompt, 显示"每轮都带上"就是撒谎; 破损块自己已把这件事说清了。
                packFactsRow(entry)
            }

            // 只读正文 —— **Markdown 预览** (2026-09-23 boss: "不支持修改, 直接改成 markdown 预览,
            // 显示效果更好")。顺带治了同一形状的性能病 —— 见 `injectionSheet` 的注释:
            // **一个 `Text` 承载整块文本时布局代价是平方级的** (实测 139 行 199 ms → 3341 行 36 s),
            // 而 `MarkdownView` 按块拆成多个小 `Text` ⇒ 代价回到线性。两份预览同源, 一起改。
            Group {
                if entry.content.isEmpty {
                    Text(L("(正文为空)"))
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                } else {
                    MarkdownView(text: entry.content)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(CodexTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: CodexTheme.radius)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1))
        }
    }

    /// pack 编辑器唯一一行元信息 —— 只留**别处看不见、且真能影响决策**的两件事:
    /// ① `layer`: pack 侧唯一的注入旋钮 (`always` 进 persona 段 / `ondemand` 不进 prompt)。
    ///    2026-09-22 起左列按**来源**分区, 层标记移到了行副标 (仅"按需"时出现) ⇒ 这条在这里是
    ///    编辑器内的第二处可见性 —— 别删, 它回答"我正在看的这个文件会不会进 prompt"。
    /// ② `keys`: 可执行契约 —— 被锁的 key 之后在 DB 条目里不能再使用 (见 `KnowledgeStore.KeyRejection`)。
    ///
    /// - Note: 曾经那排 chips (`persona` / 文件名 / 层 / `priority N` / 逐条 `key xxx`) 已删 ——
    ///   2026-09-22 boss 反馈"这玩意没必要显示吧, 越看越迷糊"。删的判据不是"少显示点",
    ///   而是**每一条都有更该在的地方**: 类型标记与文件名在左列副标已有 (文件名还在标题行);
    ///   `priority` 只决定 persona 段**内**的先后, 而该段**永不参与降级**、App 内也改不了文件顺序
    ///   ⇒ 编辑器里读了也做不出任何决策。`keys` 折成个数 + hover: 信息不减而视觉不吵。
    private func packFactsRow(_ entry: PersonaPackEntry) -> some View {
        var parts: [String] = [L(entry.layer.tag)]
        if !entry.keys.isEmpty {
            parts.append(String(format: L("占用 %lld 个保留 key"), entry.keys.count))
        }
        // `read_when` 只对按需文件成信息: 常驻文件的"什么时候读"就是"每轮", 再说一遍是噪声。
        // 它是文件里的**原文**(不走本地化), 所以以原语言出现 —— 见 `PersonaPack.parse`。
        if entry.layer == .ondemand { parts.append(contentsOf: entry.readWhen) }
        return HStack(spacing: 6) {
            Text(parts.joined(separator: " · "))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help(packFactsHelp(entry))
    }

    // MARK: - 知识库信息面 + 挂载流程 (P11.4b)

    /// 一个挂载库的信息面。**这一轮没有「索引预览」** —— 那是本段的下一步 (与注入调同一个函数,
    /// 逐字显示 agent 会看到的那段)。现在只回答三个真问题: 它在哪 (agent 拿这个路径去 read)、
    /// 它是什么 (描述, 也是唯一可写项)、它到底扫到了几个文档 (挂了不等于有效)。
    ///
    /// 为什么不把"文档数"折进左列行里: 那要在每次重绘时扫目录树。扫描放 `.task(id:)`, 换目标才扫一次。
    private func baseEditor(_ base: KnowledgeBase) -> some View {
        let descHint = baseDescHint(base)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(base.displayName)
                    .font(CodexTheme.fontTitle)
                    .foregroundStyle(CodexTheme.textPrimary)
                if base.isBuiltin {
                    Text(L("内置"))
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: base.path))
                } label: {
                    Text(L("在 Finder 打开"))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // 路径**可选中复制** —— 索引交给 agent 的就是这个字符串, 它得能被原样抄走。
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: base.isBuiltin ? "internaldrive" : "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                Text(base.path)
                    .font(CodexTheme.fontMonoSm)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodexTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: CodexTheme.radius)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(L("描述"))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                if base.isBuiltin {
                    Text(base.description)
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        TextField("", text: $draftBaseDesc)
                            .textFieldStyle(.plain)
                            .font(CodexTheme.fontBody)
                            .padding(8)
                            .background(CodexTheme.bgComposer)
                            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
                            .overlay(RoundedRectangle(cornerRadius: CodexTheme.radius)
                                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1))
                        Button(LK(savedFlash ? "✓ 已保存" : "保存")) { saveBaseDescription() }
                            .buttonStyle(CodexActionButtonStyle(
                                kind: savedFlash ? .success : .primary, disabled: !baseDescReady))
                            .disabled(!baseDescReady || savedFlash)
                    }
                }
                // 说清这句话去哪 —— 它不是备注, 它是每轮都要占预算的 prompt 字节。
                // 草稿与已保存不一致时这句换口径 (见 `baseDescHint`): 预览读的是真源, 得先说清。
                Text(descHint.text)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(descHint.isWarning ? CodexTheme.thinking : CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Image(systemName: base.enabled ? "doc.text.magnifyingglass" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(base.enabled ? CodexTheme.thinking : CodexTheme.textMuted)
                Text(base.enabled
                     ? String(format: L("扫到 %lld 个文档 (md / txt / html, 深度 ≤ 3)"), baseDocs.count)
                     : L("已停用 —— 索引里不出现这个库"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(base.enabled ? CodexTheme.textMuted : CodexTheme.thinking)
                Spacer()
                if base.enabled && baseDocs.isEmpty {
                    Text(L("这个目录里没有可读的文档"))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
            }

            // 索引预览 —— 放最后, 顺序 = **从叙述到证据** (名字→路径→描述→扫到几个→它长什么样)。
            // 用户改描述时最该看到的就是这一块: 那句话进 prompt 之后的样子, 而不是他写的样子。
            if let block = baseIndexBlock {
                baseIndexPreview(block, base: base)
            }

            if !base.isBuiltin {
                HStack {
                    Button(L("摘掉这个库")) { showDeleteBaseConfirm = true }
                        .buttonStyle(CodexActionButtonStyle(kind: .danger))
                        .help(L("只是不再挂载, 目录与里面的文件一个都不动。"))
                    Spacer()
                }
            }
        }
    }

    /// 该库在索引里的那一段 —— **逐字**, 调的是组装器用的**同一个** `KnowledgeBaseScan.indexBlock`。
    ///
    /// 为什么必须同源: 另写一份格式化逻辑, 迟早出现"预览说有 12 个文件、agent 实际看到 9 个"。
    /// 而那条不一致**没有红灯** —— 用户只能肉眼比, 比出来也说不清哪边是对的。
    ///
    /// `nil` = 这一库不进索引（只剩**没启用**这一种）。
    ///
    /// ⚠️ **P15.8 有意推翻**原来那句「空库不画预览框是有意的（再画一个空框只是噪声）」——
    /// 空根现在**真的进** prompt（只给坐标, 文件段是 `（本根暂无笔记）`, 见
    /// `KnowledgeBaseScan.indexBlock`), 预览再不画它就是在撒谎: 展示的文字与 agent 实际收到的
    /// 不一致, 而"预览说的和 agent 看到的不一样"正是上面那段注释要根除的病。
    /// 原来那行「扫到 0 个文档」照旧在, 它现在讲的是"这个根还空着", 不再是"它不进索引"。
    private var baseIndexBlock: KnowledgeBaseScan.IndexBlock? {
        guard let base = editingBase, base.enabled else { return nil }
        return KnowledgeBaseScan.indexBlock(for: base, docs: baseDocs)
    }

    /// 索引预览 (P11.4b): 这个库在**下一轮 prompt 的索引段**里长什么样。
    ///
    /// 两件事分开说, 因为它们是**两个层级**的真话:
    /// - **库级** —— 这一段逐字就是 agent 会看到的那一段 (同源函数保证)。
    /// - **段级** —— 索引是**整段进或整段不进** (Q11 方案 A) ⇒ 逐字对**不代表它真的进去了**。
    ///   这句话必须显示, 否则预览自己就在撒谎: 它展示了一段此刻并不在任何 prompt 里的文字。
    private func baseIndexPreview(_ block: KnowledgeBaseScan.IndexBlock, base: KnowledgeBase) -> some View {
        let skipped = store.knowledge.lastInjection.indexSkipped.contains { $0.name == base.displayName }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("索引预览"))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer()
                Text(String(format: L("显示 %lld / 折省略 %lld · %lld 字"),
                            block.shown, block.omitted, block.chars))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Text(block.text)
                .font(CodexTheme.fontMonoSm)
                .foregroundStyle(CodexTheme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CodexTheme.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
                .overlay(RoundedRectangle(cornerRadius: CodexTheme.radius)
                    .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1))
            Text(skipped
                 ? L("此刻不在 prompt 里 —— 索引整段进或整段不进, 它超出了本轮预算")
                 : L("这一段会进每轮 prompt 的索引段, 逐字就是 agent 收到的"))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(skipped ? CodexTheme.thinking : CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 描述框下面那句提示 —— 草稿与已保存不一致时**换成警告**。
    ///
    /// 因为索引预览显示的是**已保存**的那句 (真源)。不换的话, 用户会以为预览漏掉了他的新描述。
    /// 预览**不跟着草稿走**的理由: 预览的职责是"agent 现在收到什么"; 拿未保存的文本去预览,
    /// 展示的就是一个当前不存在的 prompt —— 正是本项目反复吃亏的那种"显示撒谎"。
    private func baseDescHint(_ base: KnowledgeBase) -> (text: String, isWarning: Bool) {
        if !base.isBuiltin,
           draftBaseDesc.trimmingCharacters(in: .whitespacesAndNewlines) != base.description {
            return (L("草稿还没保存 —— 下面的索引预览显示的是已保存的那句"), true)
        }
        return (L("这句话会进每轮 prompt 的索引 —— agent 靠它判断要不要来查这个目录。"), false)
    }

    /// 挂载弹窗。**两步而不是一步**: 选完目录不直接挂上, 而是先问描述。
    ///
    /// 为什么描述必填 (`addKnowledgeBase` 会拒): 索引里只有文件名时, agent 拿到的是一串没有语义的
    /// 字符串 (`2024Q3-复盘.md` 说明不了这是财务还是技术) ⇒ 那个库等于白挂。而"静默回落到目录名"
    /// 更坏: 用户永远不会回来补一句真正有用的话。
    /// 根描述可保存的条件。⚠️ **上限也在这里判**（P15.1）: 挂载弹窗下线之后,
    /// `.descriptionTooLong` 唯一的入口就只剩这里 —— 不判的话按钮可点、点了**静默什么都不发生**。
    private var baseDescReady: Bool {
        guard let base = editingBase else { return false }
        let trimmed = draftBaseDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        return !base.isBuiltin && !trimmed.isEmpty && trimmed != base.description
            && trimmed.count <= KnowledgeBase.descriptionLimit
    }

    /// hover 详情。**只讲 key** —— 层的语义已由行上的 tag 说清, 再复述一遍是噪音。
    /// pack 编辑器里那行元信息的 tooltip。
    ///
    /// **标题的来源写在这里** (2026-09-23, boss 拍板"直接固定化"): 行标题 = **文件名 + 出厂固定文案**
    /// (`PersonaRowText`: SOUL.md - 我是谁 …), **不读文件内容** —— 用户写什么不可控,
    /// 所以既不问他、也不从正文里猜; 表外文件就只有文件名。
    /// 它**不可被用户自定义** ⇒ 这段只说明"标题是哪来的", 不教怎么写 (没有可写的地方)。
    private func packFactsHelp(_ entry: PersonaPackEntry) -> String {
        let facts = entry.keys.isEmpty
            ? L("它没有声明 key（不锁任何名字）")
            : L("它锁住这些 key，DB 条目里不能再用:") + "\n" + entry.keys.joined(separator: "\n")
        return facts + "\n\n"
            + L("行标题是文件名加上一句固定说明（如 SOUL.md - 我是谁）；表外的文件就只有文件名")
    }

    // MARK: - D 块: 「更多设置」 —— **已于 P11.2d 整块撤下 (2026-09-22)**

    // 这里曾住着折叠区 `advancedSection` + 三个维度控件 (`kindBlock` / `layerBlock` /
    // `priorityBlock`) + 折叠头右侧的现值摘要 `advancedSummary`。boss 原话:
    //   "新增知识时, 这块也去掉, 就是最开始那个版本 —— 可以选择有无项目, 可以选择开启和关闭,
    //    就够用了"
    //
    // 撤下的**不是"少几个选项", 而是编辑器的一个层级**: 折叠区存在的理由是"正文优先、元数据
    // 渐进披露", 而它披露的三个旋钮没有一个能在用户建一条知识时被合理地决定 ——
    //   · 种类: 前 3 档 (人格/用户/硬规) 已被 persona pack 接管, DB 里再建 = 两个真源打架;
    //   · 层: 唯一可选的另一档 (需要时才查) 在 P11.4 知识库档里才成立 (目录即作用域);
    //   · 排序: 只在 L0 超限降级时才有意义, 而真实库里 `priority` 全为 0 (超限没发生过)。
    // **"先问人话再给选项"那套写法没错, 错的是问了三个当时没有答案的问题。**
    //
    // 三个字段与落库一个没删 —— 组装 / 左列分组 / L1 落盘都还在读它们, 只是不再由编辑器写入:
    //   新建 → 走 `KnowledgeItem.layer` 的缺省 (`.always`), `priority` 0, `kind` `.fact`;
    //   编辑 → `withUpdated` 只覆盖作用域/标题/正文, 其余**保持原值** (撤下输入框 ≠ 清空数据)。
    // 要加回任何一个输入口之前, 先回答"用户凭什么知道该选哪一档" —— 答不出来就说明它还没到能
    // 露面的阶段 (同 P11.2c 对 `trigger` / `counterfactual` 的判据)。

    /// P11.2c (2026-09-22) 从编辑器撤下的三块: `keyBlock` (身份键) / `lessonRows` (触发面 + 何时不适用)
    /// / `labeledField` (后者的行脚手架)。撤下的判据各不相同, 但都不是"眼不见为净":
    ///   · `key` —— 它是**实现机制** (给 persona pack 之间互相引用用), 它自己的说明都写着"一般不用填"。
    ///     写入期的 `keyRejection` (守卫 3 / 9) 与组装期的 `reservedConflicts` (守卫 13) 一条没少,
    ///     因为那两条路径与"有没有输入框"无关 —— 手改 DB / 将来的导入器照样会撞上。
    ///   · `trigger` / `counterfactual` —— 要它们的驱动逻辑 (教训门 / 前瞻注入) 在 P11.3。
    ///     现在暴露 = 让用户填一个**不生效**的框, 而"填了不生效"比"没这个框"更坏。
    /// 四者的字段与落库全部保留 ⇒ 编辑旧条目**不丢值** (见 `KnowledgeItem.withUpdated`)。
    ///
    /// 上面那条 `rejectBanner` 因此**仍可达** (不是死代码, 别顺手删): 它不靠输入框触发 ——
    /// 库里带 key 的旧条目走 `withUpdated` 时**原 key 会被保留**, 撞上 pack 保留 key / 重复 key
    /// 照样被拒。同理 `KnowledgeStore.updateKnowledge` 的归一化与校验也一条没少。
    ///
    /// 拒绝原因的文案 —— **在 View 侧拼**。域层 (`KnowledgeStore`) 只回数据: 它在 `gen_strings.py`
    /// 的 `EXCLUDE_FILES` 里, 在那里 `L()` 的 key 永远进不了词表 (英文界面静默回落中文, 三道门都看不见)。
    private func rejectText(_ reason: KnowledgeStore.KeyRejection) -> String {
        switch reason {
        case .packFrontmatterBroken:
            return L("人格文件 frontmatter 破损 — 修好开头的 --- 收尾后再建带 key 的条目")
        case .heldByPack(let key, let file):
            return L("该 key 由 persona pack 持有") + " (\(file)) — "
                + L("请直接改那个文件") + " · \(key)"
        case .duplicateKey(let key):
            return L("key 已被另一条占用") + " (\(key)) — " + L("key 全局唯一")
        }
    }

    private func rejectBanner(_ reason: KnowledgeStore.KeyRejection) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.toolError)
            Text(rejectText(reason))
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.toolError)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.toolError.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
    }

    /// 提炼候选的"为什么值得记" (审核依据, 采纳后消失)
    private func distillNoteBanner(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.accent)
            Text("提炼依据: \(note)")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            if editingItem?.status == .pending {
                Button("丢弃") { discardPending() }
                    .buttonStyle(CodexActionButtonStyle(kind: .danger))
                    .help("不采纳该候选, 直接删除")
                Button("✓ 采纳入库") { adoptPending() }
                    .buttonStyle(CodexActionButtonStyle(kind: .success))
                    .help("编辑内容后采纳, 转为正式条目 (需重启引擎生效)")
            }
            CodexSegmented(options: ["全局", "项目"],
                           selection: Binding(
                            get: { draftScope == .global ? 0 : 1 },
                            set: { draftScope = $0 == 0 ? .global : .project }))
            if draftScope == .project {
                projectMenu
            }
            Spacer()
            if editingId != nil && editingItem?.status != .pending {
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
                .help("删除该条目")
            }
            Button(LK(savedFlash ? "✓ 已保存" : "保存")) { saveEditing() }
                .buttonStyle(CodexActionButtonStyle(
                    kind: savedFlash ? .success : .primary,
                    disabled: !draftReady))
                .disabled(!draftReady || savedFlash)
                .help("保存 (⌘S); 标题可留空, 自动取正文首行")
        }
    }

    /// 项目选择胶囊 (Codex pill 语言: Menu 外层挂样式, label 内部只留 contentShape)
    private var projectMenu: some View {
        Menu {
            ForEach(store.projects) { p in
                Button(p.title) { draftProjectId = p.id }
            }
        } label: {
            Text(LK(store.projects.first { $0.id == draftProjectId }?.title ?? "选择项目"))
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

    /// 标题: 无底框大字 (对齐顶栏标题气质)
    private var titleField: some View {
        VStack(spacing: 6) {
            TextField("标题（可留空）", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: Tune.knowledgeTitleFontSize, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            Divider().overlay(CodexTheme.border.opacity(0.7))
        }
    }

    /// 正文: 白卡 + 细描边 (与 Composer 输入卡同语言)
    private var contentCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draftContent)
                .font(CodexTheme.fontBody)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 320)
            if draftContent.isEmpty {
                Text("写点值得记住的东西…")
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

    /// 正文必填; 标题可留空 (保存时自动取正文首行, 与"保存为记忆"/Scheduled 命名同规则)。
    private var draftReady: Bool {
        !draftContent.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 标题留空 → 自动取正文首行前 24 字 (与 saveAsMemory 命名规则一致)。
    private func resolvedTitle() -> String {
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        // 先 String 化再兜底 —— 直接写 `String(substring? ?? L("知识"))` 会因左侧是
        // `Substring?` 而要求右侧同为 Substring (L() 返回 String, 编译不过)。
        let head = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map { String($0.prefix(24)) }
        return head ?? L("知识")
    }

    // MARK: - 草稿动作

    private func startNew() {
        selection = .none
        draftTitle = ""
        draftContent = ""
        draftScope = store.activeProject != nil ? .project : .global
        draftProjectId = store.activeProject?.id
        // 种类 / 层 / 排序**不进 draft** (P11.2d): 编辑器已不改它们 ——
        // 新建时由模型缺省给出 (`KnowledgeItem.layer` = `.always`), 这里多一份副本只会多一个漂移源。
        draftReject = nil
    }

    private func loadDraft(_ item: KnowledgeItem) {
        selection = .item(item.id)
        draftTitle = item.title
        draftContent = item.content
        draftScope = item.scope
        draftProjectId = item.projectId
        // `kind` / `layer` / `priority` / `key` / `trigger` / `counterfactual` **都不进 draft**
        // (P11.2c + P11.2d): 编辑器已不改它们, 保存时原值由 `withUpdated` 自动带过。
        // 读进 draft 只会多出一份需要与库同步的副本。
        draftReject = nil
    }

    private func saveEditing() {
        guard draftReady else { return }
        let title = resolvedTitle()
        var reject: KnowledgeStore.KeyRejection?
        if let id = editingId,
           let existing = store.knowledgeItems.first(where: { $0.id == id }) {
            reject = store.updateKnowledge(existing.withUpdated(
                title: title, content: draftContent, scope: draftScope, projectId: draftProjectId))
        } else {
            reject = store.addKnowledge(title: title, content: draftContent,
                                        scope: draftScope, projectId: draftProjectId)
            if reject == nil, let first = store.knowledgeItems.first?.id {
                selection = .item(first)          // 新建后进入编辑态
            }
        }
        draftReject = reject
        guard reject == nil else { return }    // 被拒时不闪"已保存" (否则等于撒谎)
        draftTitle = title   // 标题留空被自动命名后回填, 字段与库内一致
        // "✓ 已保存"短闪 (与代码块"已复制"同模式)
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    private func deleteEditing() {
        guard let id = editingId else { return }
        store.deleteKnowledge(id: id)
        startNew()
    }

    // MARK: - 知识库动作 (P11.4b)

    // MARK: - 笔记动作（P15.2 写入）

    /// 打开一个笔记根目录（必要时**就地创建**）。
    ///
    /// 不直接 `open`: 目录不在时 `NSWorkspace.open` 会**静默什么都不做** —— 按钮看着能点、
    /// 点了没反应（实测 2026-09-23, 与常驻区那个 folder 按钮同一条坑）。建目录**不破任何红线**:
    /// P15.2 起正文都归 App 写了, 位置更是本来就由 App 声明。
    private func openNoteDir(_ base: KnowledgeBase) {
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(atPath: base.path,
                                                     withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: base.path))
    }

    /// 在 Finder 里**选中这一份文件**（而不是打开它所在的目录）——
    /// 用户此刻关心的是"这一篇在哪", `activateFileViewerSelecting` 正好回答这个。
    private func revealNote(_ doc: KnowledgeBaseDoc, in base: KnowledgeBase) {
        let abs = base.path + "/" + doc.relativePath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
    }

    /// `.task(id:)` 的重扫键 —— 换选中那篇笔记时重读磁盘。
    private var noteDraftTrigger: String {
        guard case .note(let bid, let rel) = selection else { return "" }
        return bid + "|" + rel
    }

    /// 从磁盘读一次编辑草稿。**每次打开 / 每次保存后**都调它（保存后调 = 把指纹换到新那一版,
    /// 同时确认磁盘上真的是我们写的那一份）。
    ///
    /// 保存后**不能**只改 `noteDraftHash` 了事: 那样"编辑器里显示的内容"就永远只是我们的记忆,
    /// 而磁盘的真源再没被核对过（`composeNote` 一旦有偏差, 界面会一直显示一份不存在的文本）。
    private func loadNoteDraft() {
        guard let note = editingNote,
              let draft = store.knowledge.noteDraft(rootId: note.base.id,
                                                    relativePath: note.doc.relativePath) else {
            noteDraftTitle = ""
            noteDraftBody = ""
            noteDraftHash = ""
            noteBaseline = ""
            noteTitleEditable = false
            noteReject = nil
            noteRevisions = []
            return
        }
        noteDraftTitle = draft.title
        noteDraftBody = draft.body
        noteDraftHash = draft.hash
        noteBaseline = draft.raw
        noteTitleEditable = draft.titleEditable
        noteReject = nil
        // 版本史跟着一起读 —— 判「来源」要拿它比指纹, 画「变更史」要它的全文。
        noteRevisions = store.knowledge.noteRevisions(rootId: note.base.id,
                                                      relativePath: note.doc.relativePath)
    }

    /// 改过没有 —— **与写盘共用 `composeNoteEdit`**（编辑面和写盘各算一份的话,
    /// "按钮说没变、写下去却变了"就是只有在手点时才会露头的 bug）。
    private func noteDraftDirty() -> Bool {
        store.knowledge.composeNoteEdit(current: noteBaseline,
                                        title: noteTitleEditable ? noteDraftTitle : nil,
                                        body: noteDraftBody) != noteBaseline
    }

    private func saveNoteDraft() {
        guard let note = editingNote else { return }
        noteReject = store.knowledge.saveNote(
            rootId: note.base.id,
            relativePath: note.doc.relativePath,
            title: noteTitleEditable ? noteDraftTitle : nil,
            body: noteDraftBody,
            baseHash: noteDraftHash)
        guard noteReject == nil else { return }
        flashSaved()
        loadNoteDraft()
        Task { await reloadRootScan() }
        Task { await reloadBaseDocs() }
    }

    /// 「仍然覆盖」= 接受磁盘上现在这一版（重读指纹）, 再照常保存。
    /// 它与「重新载入」是一对: 一个保住磁盘上的、一个保住编辑器里的, **由用户选**哪一份活下来。
    private func forceSaveNoteDraft() {
        guard let note = editingNote,
              let fresh = store.knowledge.noteDraft(rootId: note.base.id,
                                                    relativePath: note.doc.relativePath) else { return }
        noteDraftHash = fresh.hash
        saveNoteDraft()
    }

    private func deleteEditingNote() {
        guard let note = editingNote else { return }
        noteReject = store.knowledge.deleteNote(rootId: note.base.id,
                                                relativePath: note.doc.relativePath)
        guard noteReject == nil else { return }
        selection = .none
        baseDocs = []
        Task { await reloadRootScan() }
    }

    /// 新建笔记的表单。**只有一个输入框** —— 归属由"入口只有一个、固定落全局根"保证,
    /// 路径与文件名由标题派生（"能由产品回答的问题, 不要拿去问用户"）。
    private var newNoteSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("新建笔记"))
                .font(CodexTheme.fontTitle)
                .foregroundStyle(CodexTheme.textPrimary)
            Text(L("标题就是文件名。存到全局笔记目录, 下一轮组装就会带上它; 项目笔记去项目目录里建。"))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L("标题"), text: $newNoteTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createNoteFromDraft() }
            if let reject = newNoteReject { noteRejectBanner(reject) }
            HStack(spacing: 8) {
                Spacer()
                Button(L("取消")) { showNewNoteSheet = false }
                    .buttonStyle(CodexActionButtonStyle(kind: .primary))
                Button(L("创建")) { createNoteFromDraft() }
                    .buttonStyle(CodexActionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func createNoteFromDraft() {
        let rootId = KnowledgeBase.noteGlobalID
        switch store.knowledge.createNote(rootId: rootId, title: newNoteTitle) {
        case .failure(let reject):
            newNoteReject = reject
        case .success(let rel):
            showNewNoteSheet = false
            newNoteTitle = ""
            newNoteReject = nil
            selection = .note(rootId, rel)
            // 顺序不能反: `loadNoteDraft` 靠 `editingNote` 找到那篇, 而它读的是 `baseDocs` ——
            // 不先把新文件扫进来, 打开的就是一片空白（而且**没有红灯**: 看起来像"新建了个空笔记"）。
            Task {
                await reloadRootScan()
                await reloadBaseDocs()
                loadNoteDraft()
            }
        }
    }

    private func flashSaved() {
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    private func loadBase(_ base: KnowledgeBase) {
        selection = .base(base.id)
        // 内置库描述只读 ⇒ 草稿留空 (它在 `baseDescReady` 里本来就恒 false)
        draftBaseDesc = base.isBuiltin ? "" : base.description
    }

    private func saveBaseDescription() {
        guard let id = editingBaseId, baseDescReady else { return }
        guard store.updateKnowledgeBase(id: id, description: draftBaseDesc) == nil else { return }
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    private func deleteEditingBase() {
        guard let id = editingBaseId else { return }
        store.deleteKnowledgeBase(id: id)
        selection = .none
        baseDocs = []
    }

    /// `.task(id:)` 的重扫触发键 —— **必须含 `enabled`, 不能只用 id** (2026-09-22 修)。
    ///
    /// 漏掉 `enabled` 的后果 (实测推导): 在**停用状态**下选中一个库 ⇒ `reloadBaseDocs` 早退并把
    /// `baseDocs` 清空; 之后把开关打开, id 没变 ⇒ **task 不重跑** ⇒ 面板一直说"扫到 0 个文档 /
    /// 这个目录里没有可读的文档", 而目录里明明有文件。**显示撒谎**, 且没有任何红灯。
    private var baseScanTrigger: String {
        guard let base = editingBase else { return "" }
        return "\(base.id)|\(base.enabled ? 1 : 0)"
    }

    /// 左列的重扫触发键 —— 根集合 / 路径 / 启用态任一变化就重扫。
    ///
    /// ⚠️ **不含文件内容**: 在 App 外往笔记目录里丢一篇, 左列要等下一次面板重开才出现。
    /// 这是有意的取舍 —— 每次 `body` 重绘都去 walk 一遍目录树, 代价是那种"看起来没 bug、
    /// 只是越来越卡"的开销; 而**注入路径是每轮现算的**（磁盘为准那条纪律由它保证, 不由 UI）。
    private var rootScanTrigger: String {
        store.knowledge.allKnowledgeBases
            .map { "\($0.id)|\($0.enabled ? 1 : 0)|\($0.path)" }
            .joined(separator: ",")
    }

    /// 扫左列的**每一个根**。走 `Task.detached` ⇒ 不占主线程（目录树可能很大）。
    private func reloadRootScan() async {
        let bases = store.knowledge.allKnowledgeBases
        rootScan = await Task.detached {
            bases.map { RootScan(base: $0, docs: KnowledgeBaseScan.docs(root: $0.path)) }
        }.value
    }

    /// 一篇笔记的**可写编辑面**（P15.2）。
    ///
    /// 三个旋钮: **标题 · 正文 · 保存**。深度编辑（语法高亮 / 预览）**不做** —— 外部十家里的
    /// 笔记类载体全是"明文 md + 外部编辑器", 而 App 里再养一个渲染器就是两套渲染必漂移。
    /// 这里只保证三件事: 能改、改完能存、**存之前不会静默盖掉别人的改动**。
    ///
    /// P15.1 这里是一张只读信息面。那四行信息**留着** —— 它们回答的是"这份东西还值不值得信"
    /// （在哪 / 多大 / 多久没动 / 摘要）, 与"能不能改"是两个问题, 不因为能写了就作废。
    private func noteEditor(_ doc: KnowledgeBaseDoc, in base: KnowledgeBase) -> some View {
        let days = KnowledgeBaseScan.staleDays(doc.modifiedAt)
        let dirty = noteDraftDirty()
        return VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 6) {
                TextField(L("标题"), text: $noteDraftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: Tune.knowledgeTitleFontSize, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .disabled(!noteTitleEditable)
                Divider().overlay(CodexTheme.border.opacity(0.7))
            }
            HStack(spacing: 6) {
                Text(base.displayName)
                Text("·")
                Text(doc.relativePath)
                if !noteTitleEditable {
                    Text("·")
                    Text(L("txt / html 没有 frontmatter — 标题就是文件名"))
                }
            }
            .font(CodexTheme.fontTiny)
            .foregroundStyle(CodexTheme.textMuted)

            VStack(alignment: .leading, spacing: 6) {
                noteInfoLine(L("位置"), base.path + "/" + doc.relativePath)
                noteInfoLine(L("大小"), String(format: L("%lld 字节"), doc.byteCount))
                noteInfoLine(L("最后修改"), days.map { String(format: L("%lld 天前"), $0) }
                                ?? String(format: L("近 %lld 天内"), KnowledgeBaseScan.staleAfterDays))
                noteInfoLine(L("摘要"), doc.summary.isEmpty ? "—" : doc.summary)
                // 判据 = **内容同一性**（拿磁盘上的指纹去版本史里认领那一条），不是"最新一条的
                // origin" —— 后者在"最后写下的那版没被记过"（外部改 / 老库）时会答错。
                // `noteBaseline` 就是刚读到的磁盘原文 ⇒ 这里不再读一次文件。
                noteInfoLine(L("来源"), originLabel(KnowledgeStore.origin(ofContent: noteBaseline,
                                                                         in: noteRevisions)))
            }

            if !noteRevisions.isEmpty { noteHistoryBlock }

            if let reject = noteReject { noteRejectBanner(reject) }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("正文"))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $noteDraftBody)
                        .font(CodexTheme.fontBody)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 240)
                    if noteDraftBody.isEmpty {
                        Text(L("这一篇还是空的…"))
                            .font(CodexTheme.fontBody)
                            .foregroundStyle(CodexTheme.textMuted)
                            .padding(.leading, 12)
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                    }
                }
                .background(CodexTheme.bgComposer)
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
                .overlay(RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                    .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1))
            }

            HStack(spacing: 8) {
                Button(LK(savedFlash ? "✓ 已保存" : "保存")) { saveNoteDraft() }
                    .buttonStyle(CodexActionButtonStyle(kind: savedFlash ? .success : .primary))
                    .disabled(!dirty)
                    .help(L("内容没变时不会写盘, 也不会留下一条变更记录"))
                Button {
                    showNoteDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 10))
                        Text(L("删除"))
                    }
                }
                .buttonStyle(CodexActionButtonStyle(kind: .danger))
                .help(L("移进「废纸篓」(还能捞回来); 当前内容先记进变更史"))
                Spacer()
                Button(L("在 Finder 中显示")) { revealNote(doc, in: base) }
                    .buttonStyle(.plain)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textSecondary)
                Button(L("笔记目录")) { openNoteDir(base) }
                    .buttonStyle(.plain)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textSecondary)
            }

            Text(L("改完要点保存 —— 自动保存会把写了一半的句子也落盘, 还会跟你在外部编辑器里的改动抢。"))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 来源标记与变更史（P15.4）

    /// 「谁写的」两态。**文案在这里拼** —— `NoteRevisionOrigin.rawValue` 是**落库字符串**
    /// （`human` / `dream`）, 它不是展示层的东西（同 `KnowledgeKind.tag` 那条判据）。
    ///
    /// 为什么是这两个词而不是"人 / AI": 界面说的是"这篇笔记是谁攒出来的", 而 dream 的角色
    /// 就是**替你攒**（它从不写盘, 攒出来的东西等人拍板）—— 这一点得在措辞上兑现, 否则
    /// 用户会以为它已经自己写进去了。反过来说, `.human` 也包括"你在外部编辑器里改的"
    /// （见 `KnowledgeStore.origin(ofContent:in:)` 那条推论）。
    private func originLabel(_ origin: NoteRevisionOrigin) -> String {
        switch origin {
        case .human: L("你写的")
        case .dream: L("它攒的")
        }
    }

    /// 变更史最多列几条。超出的折成一行 —— 它住在正文上方, 不设上限会把编辑区顶到屏幕外。
    private static let noteHistoryLimit = 5

    /// 变更史（P15.4）。列到 `noteHistoryLimit` 条为止, 其余折成一行。
    ///
    /// ⚠️ **按行渲染**: 每条是独立的一行, 不用一个 `Text` 装整段
    /// （一个 `Text` 承载整块文本是**平方级**开销, 而这里的条数由用户的使用频率决定 ——
    /// boss 实测过 3431 行 36 s 那个坑）。
    private var noteHistoryBlock: some View {
        let shown = Array(noteRevisions.prefix(Self.noteHistoryLimit))
        // 磁盘上**现在**这一版是哪一条 —— 每次渲染算一次（它只是个 sha256, 不吃 IO）。
        let currentHash = KnowledgeStore.noteHash(noteBaseline)
        return VStack(alignment: .leading, spacing: 5) {
            Text(String(format: L("变更史 · %lld 条"), noteRevisions.count))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            ForEach(shown) { rev in
                HStack(spacing: 8) {
                    Text(Self.proposalStamp.string(from: rev.writtenAt))
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textTertiary)
                    Text(originLabel(rev.origin))
                        .font(.system(size: 10))
                        .foregroundStyle(rev.origin == .dream ? CodexTheme.thinking
                                                              : CodexTheme.textSecondary)
                    Text(String(rev.sha256.prefix(8)))
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textMuted)
                    Spacer(minLength: 2)
                    // **哪一条是磁盘上现在这一版**。没有这个标记, 用户会默认"最上面那条 =
                    // 当前状态", 而它只是"最近一次写入" —— 两者在外部改过之后**并不相同**,
                    // 而那个差值恰恰是他此刻最该看见的东西。
                    if rev.sha256 == currentHash {
                        Text(L("当前"))
                            .font(.system(size: 10))
                            .foregroundStyle(CodexTheme.toolDone)
                    }
                }
            }
            if noteRevisions.count > shown.count {
                Text(String(format: L("… 还有 %lld 条"), noteRevisions.count - shown.count))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
        }
    }

    /// 写入被拒的**文案** —— 在 View 侧拼: 那个枚举住在 `Models/KnowledgeBase.swift`, 而该文件在
    /// `gen_strings.py` 的 `EXCLUDE_FILES` 里 ⇒ 在那里 `L()` 的 key 永远进不了词表（同 `rejectText`）。
    private func noteRejectText(_ reject: NoteWriteRejection) -> String {
        switch reject {
        case .emptyTitle:
            return L("标题不能为空")
        case .titleTooLong(let limit):
            return String(format: L("标题太长 — 上限 %lld 字"), limit)
        case .nameCollision(let existing):
            return L("已经有同名笔记了") + " (\(existing)) — " + L("换一个标题")
        case .pathEscapesRoot:
            return L("这个路径不在笔记目录里")
        case .noteMissing:
            return L("这篇已经不在了 — 可能在 App 外被删掉或改名了")
        case .baseHashMismatch:
            return L("这篇在你编辑期间被外部改过 — 你的改动没有写盘")
        case .writeFailed:
            return L("写盘失败 — 检查目录权限与磁盘空间")
        }
    }

    /// 拒绝条。⚠️ `baseHashMismatch` 那一种**必须带上下一步**: 只说"被拒了"是个死胡同,
    /// 而用户此刻手上有一条改了一半的正文, 他需要一个明确的出口（同"禁用态按钮要自带还差什么"）。
    private func noteRejectBanner(_ reject: NoteWriteRejection) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.toolError)
            VStack(alignment: .leading, spacing: 8) {
                Text(noteRejectText(reject))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.toolError)
                    .fixedSize(horizontal: false, vertical: true)
                if reject == .baseHashMismatch {
                    HStack(spacing: 8) {
                        Button(L("重新载入（丢掉我的改动）")) { loadNoteDraft() }
                            .buttonStyle(CodexActionButtonStyle(kind: .primary))
                        Button(L("仍然覆盖")) { forceSaveNoteDraft() }
                            .buttonStyle(CodexActionButtonStyle(kind: .danger))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.toolError.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
    }

    private func noteInfoLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(CodexTheme.fontMonoSm)
                .foregroundStyle(CodexTheme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 换选中目标 (或它的启用态变了) 时扫一次文档清单。
    /// **不在 `body` 里现扫** —— 面板每次重绘走一遍目录树是那种"没有 bug、只是越来越卡"的开销。
    private func reloadBaseDocs() async {
        guard let base = editingBase, base.enabled else {
            baseDocs = []
            return
        }
        let root = base.path
        baseDocs = await Task.detached { KnowledgeBaseScan.docs(root: root) }.value
    }

    // MARK: - 提炼候选审核 (待审核条目)

    /// 采纳: 先写回编辑器里的修改 (可编辑后采纳), 再转正。
    private func adoptPending() {
        guard let item = editingItem, item.status == .pending else { return }
        if draftReady {
            let reject = store.updateKnowledge(item.withUpdated(
                title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                content: draftContent, scope: draftScope, projectId: draftProjectId))
            if let reject { draftReject = reject; return }   // 撞 key = 拒绝采纳, 不是静默入库
        }
        if let reject = store.adoptKnowledge(id: item.id) { draftReject = reject; return }
        selection = .none
        draftTitle = ""
        draftContent = ""
        draftReject = nil
    }

    /// 丢弃: 删候选, 编辑器清空。
    private func discardPending() {
        guard let item = editingItem, item.status == .pending else { return }
        store.discardKnowledge(id: item.id)
        selection = .none
        draftTitle = ""
        draftContent = ""
    }
}
