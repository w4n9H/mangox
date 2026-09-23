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
        case base(String)    // 挂载的知识库 (P11.4b: 只读信息面 + 改描述 / 摘库)
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

    // —— 挂载流程 (P11.4b) ——
    // 走**两步**而不是"选完目录就挂上": 描述必填 (索引里只有文件名时, agent 拿到的是一串没有语义的
    // 字符串)。所以先选目录 → 再在弹窗里填描述。描述**不进 draft 复用** —— 它与条目草稿是两套东西。
    @State private var showMountSheet: Bool = false
    @State private var mountPath: String = ""
    @State private var mountDesc: String = ""
    @State private var mountReject: KnowledgeBaseRejection?
    /// 选中库的扫描结果 (文档数在右侧信息面里给)。**不在 body 里现扫** —— 面板每次重绘都走一遍
    /// 目录树是那种"看起来没 bug、只是越来越卡"的开销。`.task(id:)` 只在换选中目标时扫一次。
    @State private var baseDocs: [KnowledgeBaseDoc] = []
    /// 用户库描述编辑草稿 (内置库描述不归用户配置, 只读展示)。
    @State private var draftBaseDesc: String = ""

    private var editingId: UUID? { if case .item(let id) = selection { return id }; return nil }
    private var editingPackFile: String? { if case .pack(let f) = selection { return f }; return nil }
    private var editingBaseId: String? { if case .base(let id) = selection { return id }; return nil }

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
        .sheet(isPresented: $showMountSheet) { mountSheet }
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
        .task(id: baseScanTrigger) { await reloadBaseDocs() }
    }

    // MARK: - A 块: 顶部载荷条 (回答"这一轮我带什么上飞机")

    private var loadBar: some View {
        let inj = store.knowledge.lastInjection
        let fraction = min(1.0, Double(inj.residentChars) / Double(max(1, Tune.knowledgeTotalCharLimit)))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("PAYLOAD")
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
                    help: L("它们不进 prompt, 也进不了知识库索引 (pack 目录不在任何库的扫描路径下)。挂成知识库即可, 做法同 PROJECTS.md"))
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
            // 区头: 与侧栏 "Projects/Chats" 同款 + 右侧新建
            HStack {
                Text("KNOWLEDGE")
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
                .help("新建条目")
            }
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
                    let bases = store.effectiveKnowledgeBases

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
                    if !pending.isEmpty || !custom.isEmpty {
                        sectionHeader(L("自定义"), count: pending.count + custom.count,
                                      tint: CodexTheme.textMuted)
                        ForEach(pending) { item in row(item) }
                        ForEach(custom) { item in row(item) }
                    }
                    // ③ 知识库 = 挂载的目录。**不判空**: 内置库恒有一个 (L1 落盘目录), 所以这段永远在,
                    //    而它正是挂载入口的所在地 —— 藏起来的入口等于没有入口。
                    sectionHeader(L("知识库"), count: bases.count, tint: CodexTheme.textMuted)
                    ForEach(bases) { base in baseRow(base) }
                    mountRow

                    if store.knowledgeItems.isEmpty && pack.isEmpty {
                        // 旧文案是「暂无条目 / 点右上角 + 新建」—— 只说了三条路里的一条, 而 user
                        // 真正想找的往往是**另外两条** (人格文件放哪 / 目录挂哪)。清单页在"什么都没有"
                        // 时是**唯一**能指路的地方, 指错路就等于没指 (2026-09-23 改口径)。
                        Text(L("还没有常驻内容\n点右上角 + 新建条目, 或用上面两段的入口放入文件"))
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 8)
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
                .font(.system(size: 10))
                .foregroundStyle(entry.isBroken ? CodexTheme.toolError : CodexTheme.thinking)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(PersonaRowText.title(for: entry.fileName))
                    .font(.system(size: 12))
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
        .padding(.trailing, 6)
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

    /// 一条挂载记录。行内开关 = **是否进索引**(与条目那个开关同形: 关掉 ≠ 摘掉)。
    /// 「内置」标记一次说清两件事: 不可删 (删了下次现算又回来, 那种"删了又出现"的按钮比没有更坏)、
    /// 描述由 App 写死 (它的存在由 L1 落盘目录决定, 不归用户配置)。
    private func baseRow(_ base: KnowledgeBase) -> some View {
        let selected = selection == .base(base.id)
        let hovered = hoveringId == "base:" + base.id
        return HStack(spacing: 7) {
            Image(systemName: base.isBuiltin ? "internaldrive" : "folder")
                .font(.system(size: 10))
                .foregroundStyle(base.enabled ? CodexTheme.thinking : CodexTheme.textMuted)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(base.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(!base.enabled ? CodexTheme.textMuted
                                     : (selected ? CodexTheme.textPrimary : CodexTheme.textSecondary))
                Text(base.description)
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if base.isBuiltin {
                Text(L("内置"))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .help(L("L1 落盘目录, 自动挂载: 不可删, 描述由 App 写死"))
            }
            CodexMiniToggle(isOn: Binding(
                get: { base.enabled },
                set: { _ in store.toggleKnowledgeBase(id: base.id) }
            ))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.selected : (hovered ? CodexTheme.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? "base:" + base.id : nil }
        .onTapGesture { loadBase(base) }
    }

    /// 挂载入口 —— 做成**区里的一行**, 而不是区头再加一个「+」: 两个加号会让人分不清
    /// "新建条目"和"挂目录"(它们做的事完全不同, 而"都是加号"会让点错变成常态)。
    private var mountRow: some View {
        let hovered = hoveringId == "mount"
        return HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textTertiary)
                .frame(width: 14)
            Text(L("挂载目录…"))
                .font(.system(size: 12))
                .foregroundStyle(CodexTheme.textMuted)
            Spacer(minLength: 2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(hovered ? CodexTheme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onHover { hoveringId = $0 ? "mount" : nil }
        .onTapGesture { pickDirectory() }
        .help(L("挂一个目录当资料库: App 只读, 只把描述与文件清单给 agent"))
    }

    private func row(_ item: KnowledgeItem) -> some View {
        let selected = isEditing(item)
        let hovered = hoveringId == item.id.uuidString
        let isPending = item.status == .pending
        return HStack(spacing: 7) {
            Image(systemName: isPending ? "wand.and.stars"
                            : (item.source == .session ? "bookmark.fill" : "doc.text"))
                .font(.system(size: 10))
                .foregroundStyle(isPending ? CodexTheme.accent
                                 : (item.source == .session ? CodexTheme.thinking : CodexTheme.textMuted))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12))
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
        .padding(.trailing, 6)
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
        HStack(spacing: 5) {
            Text("\(title) · \(count)")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(tint)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 2)
        .padding(.top, 6)
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
    /// `nil` = 这一库不进索引 (没启用 / 目录里没有可读文档)。**空库不画预览框是有意的**:
    /// 上面那行「扫到 0 个文档」已经说了原因, 再画一个空框只是噪声。
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
    private var mountSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("挂载知识库"))
                .font(CodexTheme.fontTitle)
                .foregroundStyle(CodexTheme.textPrimary)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                Text(mountPath)
                    .font(CodexTheme.fontMonoSm)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodexTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))

            VStack(alignment: .leading, spacing: 4) {
                Text(L("这个目录里放的是什么资料？"))
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textSecondary)
                TextField("例: 2024 年各渠道的复盘文档", text: $mountDesc)
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontBody)
                    .padding(10)
                    .background(CodexTheme.bgComposer)
                    .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
                    .overlay(RoundedRectangle(cornerRadius: CodexTheme.radius)
                        .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1))
                Text(L("这句话会进每轮 prompt 的索引 —— agent 靠它判断要不要来查这个目录。"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reject = mountReject {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.toolError)
                    Text(baseRejectText(reject))
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.toolError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button(L("取消")) { showMountSheet = false }
                    .buttonStyle(CodexActionButtonStyle(kind: .danger))
                Button(L("挂载")) { confirmMount() }
                    .buttonStyle(CodexActionButtonStyle(kind: .primary, disabled: !mountReady))
                    .disabled(!mountReady)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(CodexTheme.bgChat)
    }

    private var mountReady: Bool {
        !mountDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var baseDescReady: Bool {
        guard let base = editingBase else { return false }
        let trimmed = draftBaseDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        return !base.isBuiltin && !trimmed.isEmpty && trimmed != base.description
    }

    /// 拒绝原因 —— **在 View 侧拼**(同 `rejectText`: 域层在 `gen_strings.EXCLUDE_FILES` 里,
    /// 在那里写 `L()` 的 key 永远进不了词表, 英文界面会静默回落中文且三道门都看不见)。
    private func baseRejectText(_ reject: KnowledgeBaseRejection) -> String {
        switch reject {
        case .emptyDescription:
            return L("描述不能是空的 — 索引里只有文件名的话, agent 拿到的是没有语义的字符串")
        case .descriptionTooLong(let limit):
            return String(format: L("描述太长 (上限 %lld 字, 它是一句话不是摘要)"), limit)
        case .duplicatePath(let existing):
            return String(format: L("这个目录已经挂过了 (%@)"), existing)
        case .notADirectory:
            return L("不是一个目录, 或者它已经不存在了")
        case .builtinImmutable:
            return L("内置库不可修改 — 它跟着 L1 落盘目录自动出现")
        }
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

    /// 选目录 —— 只到"拿到路径"为止, 真正挂上要等用户在弹窗里补齐描述 (见 `mountSheet`)。
    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L("选择")
        panel.message = L("选一个目录当资料库 — App 只读, 不会改动里面的任何文件")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mountPath = url.path
        mountDesc = ""
        mountReject = nil
        showMountSheet = true
    }

    private func loadBase(_ base: KnowledgeBase) {
        selection = .base(base.id)
        // 内置库描述只读 ⇒ 草稿留空 (它在 `baseDescReady` 里本来就恒 false)
        draftBaseDesc = base.isBuiltin ? "" : base.description
    }

    private func confirmMount() {
        guard mountReady else { return }
        if let reject = store.addKnowledgeBase(path: mountPath, description: mountDesc) {
            mountReject = reject          // 被拒时**不关弹窗** —— 让用户原地改, 别让他重选一次目录
            return
        }
        mountReject = nil
        showMountSheet = false
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
