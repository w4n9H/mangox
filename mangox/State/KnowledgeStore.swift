//
//  KnowledgeStore.swift
//  P9.1c: 知识库/记忆域自 ChatStore 抽离 (P3.7 全链路: 条目 CRUD/注入块组装/蒸馏/审核)。
//  拆分不动行为: ChatStore 保留同名 facade 转发 (冒烟/视图零改动);
//  服务持有 store 弱引用, 经 store 回调落库/重放/活跃项目判定; 池下发走 pushKnowledgeContext。
//

import Foundation
import Combine

@MainActor
final class KnowledgeStore: ObservableObject {

    // P3.7: 知识库/记忆 (统一模型, 记忆 = source=session 条目)
    @Published var knowledgeItems: [KnowledgeItem] = []
    @Published var showKnowledgePanel: Bool = false
    /// 注入块快照 (池实例 spawn 期消费; applyKnowledgeChange/启动时刷新)。
    private(set) var currentKnowledgeBlock: String?
    /// 最近一次组装的完整结果 (载荷条 A 块消费: 计数 / 降级清单 / 冲突清单)。
    @Published private(set) var lastInjection = KnowledgeInjection()
    /// 组装告警 (超限降级 / key 冲突 / pack 解析失败)。**只报给 UI 与事件流, 永不阻断注入** (P11 §2.5)。
    ///
    /// 派生自 `lastInjection` —— **不存第二份状态**, 因此不可能漏刷。
    /// **本文件不出文案**: 它在 `gen_strings.py` 的 `EXCLUDE_FILES` 里 (同时拼**注入面**文本,
    /// 注入面必须恒中文), 在这里写 `L()` 得到的 key **永远进不了词表** ⇒ 英文界面静默回落中文,
    /// 而且词表门跳过本文件、连"废弃"都不报 —— **三道 l10n 门全都看不见** (2026-09-22 实测踩过)。
    /// 文案一律在 View 侧拼 (带插值必须 `String(format: L("…%lld…"), x)`, 见 details 本地化深坑 ⑤)。
    var injectionWarnings: [KnowledgeWarning] { Self.warnings(for: lastInjection) }

    // Memory distillation (P3.7 记忆自动提炼; v1 人工触发, 自动门槛留 v1.2)
    @Published var distillRunning: Bool = false
    /// 提炼结果提示 (Composer 上方横幅, 8s 自清)。isError = 红/绿两种横幅。
    @Published var distillOutcome: (text: String, isError: Bool)?
    private var distillOutcomeTask: Task<Void, Never>?

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) { self.store = store }

    // MARK: - 投影 (Composer pill / 知识面板)

    /// 当前生效条数 (已审核 + 启用 + 全局/当前 project)——Composer pill 显示用。
    var activeKnowledgeCount: Int {
        let pid = store?.activeProject?.id
        return knowledgeItems.filter { item in
            guard item.enabled, item.status == .active else { return false }
            return item.scope == .global || item.projectId == pid
        }.count
    }

    /// 提炼候选 (待审核)。
    var pendingKnowledge: [KnowledgeItem] {
        knowledgeItems.filter { $0.status == .pending }
    }

    /// **注入资格**: 已启用 + 已审核 + 在生效作用域内。`buildInjection` 的唯一入口。
    ///
    /// - Important: 这里的 `enabled` **不是可选的** —— 去掉它就会把用户关掉的条目注进 prompt。
    private var injectableScopedItems: [KnowledgeItem] {
        let pid = store?.activeProject?.id
        return knowledgeItems.filter { item in
            guard item.enabled, item.status == .active else { return false }
            return item.scope == .global || item.projectId == pid
        }
    }

    /// **自定义区** (面板左列第二段): 已审核 + 在生效作用域内。**刻意不筛 `enabled`**。
    ///
    /// 为什么必须和 `injectableScopedItems` 分开 (2026-09-22 boss 实测报的 bug)：
    /// 左列最初复用了注入资格那一条判据 ⇒ 在行内关掉开关后, 条目**同时掉出两个分组**、面板上
    /// 彻底消失, 只能翻 DB 才知道它还在。那个开关的实际效果等于删除, 而且没有任何红灯
    /// (关掉是合法操作, 断言全绿)。
    ///
    /// 两件事本来就不同, 之前只是**恰好同形**: "能不能被注入"与"用户能不能看见它"。
    /// 关掉的那条**可见、但不注入**(载荷计数走 `injectableScopedItems`, 所以"面板 4 行 / 载荷 3 条"
    /// 是真话, 不是不一致)。行内开关 + 标题转灰就是"这条关着"的表达。
    ///
    /// - Note: 左列**按来源分区** (常驻 = persona pack / 自定义 = 这里的 DB 条目 / 知识库 = 挂载目录),
    ///   所以**层 (`isResident`) 不再是分区维度** —— 它降为行副标里的一个标记(只在"按需"时出现)。
    ///   分组维度只能有一个; 层是正交的另一维, 靠"把它从某个分组里抹掉"表达就是下一个"消失"事故。
    var customKnowledge: [KnowledgeItem] {
        let pid = store?.activeProject?.id
        return knowledgeItems.filter { item in
            guard item.status == .active else { return false }
            return item.scope == .global || item.projectId == pid
        }
    }

    // MARK: - 知识库档 (P11.4): 挂载记录 + 索引

    /// 用户挂载的库 (落库的)。**内置库不在这里** —— 见 `builtinKnowledgeBases`。
    @Published var knowledgeBases: [KnowledgeBase] = []

    /// 内置库 —— L1 落盘目录**自动挂载** (§3.4 / §8.1 Q13)。
    ///
    /// 为什么必须自动挂: `kind=ondemand` 的条目落成 L1 文件之后, **除 `SOUL.md` 里那句手写文字
    /// 外没有任何机制告诉 agent 它们存在**。这正是 P11.1 遗留的真真空 —— 那些条目"不进 prompt"
    /// 是对的, 缺的是"进索引"。
    ///
    /// 不落库而是**现算**: 它们的身份由落盘目录决定 (项目增删、目录存亡都自动跟随),
    /// 落库就会出现"项目删了但库还在"的幽灵行。路径同样走 `resolvedL1Dir`, **测试重定向自动生效**
    /// (冒烟绝不扫用户家目录)。
    var builtinKnowledgeBases: [KnowledgeBase] {
        var out: [KnowledgeBase] = []
        var seen: Set<String> = []
        func add(_ id: String, _ path: String, _ desc: String) {
            // 同一目录只挂一次 —— 与建表 `UNIQUE(path)` 同一个判据 (§3.4: 挂两次 = 索引里
            // 同一份资料出现两遍, 纯浪费每轮预算)。可达路径: 测试重定向下两个项目若**末段同名**,
            // `l1Dir` 会算出同一个落点 (生产形状 `p + "/.mangox/agent"` 用全路径, 不会撞)。
            guard seen.insert(path).inserted else { return }
            out.append(KnowledgeBase(id: id, path: path, description: desc,
                                     enabled: true, isBuiltin: true))
        }
        // 跨项目 L1: `~/.mangox/agent/memory/`
        add(Self.builtinGlobalID, resolvedL1Dir(projectPath: nil),
            "按需知识的落盘目录 (App 管理, 正文由 agent 按需读)")
        // 项目内 L1: `<项目>/.mangox/agent/`
        for p in store?.projects ?? [] {
            guard let path = p.path, !path.isEmpty else { continue }
            add(Self.builtinProjectPrefix + p.id.uuidString, resolvedL1Dir(projectPath: path),
                "本项目按需知识的落盘目录 (App 管理)")
        }
        return out
    }

    static let builtinGlobalID = "builtin:l1-global"
    static let builtinProjectPrefix = "builtin:l1-project:"

    /// UI 与组装共用的**唯一库列表** (用户挂载 + 内置)。顺序: 用户的在前 (人配的比自动的更需要看见)。
    var allKnowledgeBases: [KnowledgeBase] { knowledgeBases + builtinKnowledgeBases }

    /// 单库查询 —— **带生效态**(面板选中一个库时读它)。
    func knowledgeBase(id: String) -> KnowledgeBase? {
        effectiveKnowledgeBases.first { $0.id == id }
    }

    /// 索引段 (§2.2 / §3.4)。`nil` = 没有可注入的库 (没挂 / 全停用 / 全空)。
    ///
    /// 组装器与 UI 预览**共用它** —— `chars` 是给预算用的真实字符数, `bases` 是缺席点名要用的
    /// 每库占位 (Q11 方案 A: 装不下就整段缺席, 但要说得清是哪些库)。
    struct KnowledgeIndexSegment {
        let text: String
        /// 每库: 显示名 + 该库索引块字符数。缺席告警按它点名。
        let bases: [KnowledgeBaseCost]
        /// 挂了、启用了, 但一个文档都没扫到的库 —— 索引里**不出现** (§3.4: 空库不注入,
        /// 只是每轮占一行预算), 但 UI 要能提示"这个目录是空的"。
        let emptyBases: [String]
        var count: Int { bases.count }
        var chars: Int { text.count }
    }

    /// **同源入口**: 每个库 + 它扫到的文档。注入文本与 UI 的索引预览都调它 ——
    /// 各扫一遍迟早会出现"预览说 12 个文件、agent 实际看到 9 个"。
    ///
    /// - Important: 读 `effectiveKnowledgeBases` 而不是 `allKnowledgeBases`。前者把**内置库的
    ///   停用**折算进 `enabled`（见它的注释）⇒ 注入路径与 UI 列表看到的是**同一份带真实生效态的
    ///   列表**。读 `allKnowledgeBases` 会让「停用 memory/ 索引」这个开关**静默失效** ——
    ///   内置库的 `enabled` 恒为 `true`, 下面那句 `guard base.enabled` 会永远放行。
    ///
    /// 每次现算、不缓存: 与 §3.3「磁盘为准」同一条纪律 —— 用户在 App 外改了目录, 下轮即生效。
    func knowledgeBaseScan() -> [(base: KnowledgeBase, docs: [KnowledgeBaseDoc])] {
        effectiveKnowledgeBases.map { ($0, KnowledgeBaseScan.docs(root: $0.path)) }
    }

    /// 索引段文本 (含段头)。库之间空一行; `enabled = false` 的库**整段不出现**
    /// (§3.4: 索引是给模型看的, 没有"灰"这个状态)。
    func knowledgeIndexSegment() -> KnowledgeIndexSegment? {
        var parts: [String] = []
        var costs: [KnowledgeBaseCost] = []
        var empty: [String] = []
        for (base, docs) in knowledgeBaseScan() {
            guard base.enabled else { continue }
            // 空库不注入 (§3.4): 一条"这次是空的"对 agent 没有可行动信息, 只是每轮占预算。
            if docs.isEmpty { empty.append(base.displayName); continue }
            guard let block = KnowledgeBaseScan.indexBlock(for: base, docs: docs) else { continue }
            parts.append(block.text)
            costs.append(KnowledgeBaseCost(name: base.displayName, chars: block.chars))
        }
        guard !parts.isEmpty else { return nil }
        let text = ([KnowledgeBaseScan.segmentHeader] + parts).joined(separator: "\n\n")
        return KnowledgeIndexSegment(text: text, bases: costs, emptyBases: empty)
    }

    /// 挂载一个目录。返回 nil = 成功; 非 nil = 拒绝原因 (**数据**, 文案在 View 侧拼)。
    ///
    /// - Important: 描述**必填** —— 它不是装饰: 索引里只有文件名的话, agent 拿到的是一串
    ///   没有语义的字符串 (`2024Q3-复盘.md` 说明不了这是财务还是技术)。**拒绝创建**而不是
    ///   "回落到目录名": 静默用目录名填进去, 用户永远不会回来补一句真正有用的话。
    @discardableResult
    func addKnowledgeBase(path: String, description: String) -> KnowledgeBaseRejection? {
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else { return .emptyDescription }
        guard desc.count <= KnowledgeBase.descriptionLimit else {
            return .descriptionTooLong(limit: KnowledgeBase.descriptionLimit)
        }
        let normalized = Self.normalizedBasePath(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue else {
            return .notADirectory
        }
        if let dup = allKnowledgeBases.first(where: { $0.path == normalized }) {
            return .duplicatePath(existing: dup.displayName)
        }
        let base = KnowledgeBase(id: UUID().uuidString, path: normalized, description: desc)
        knowledgeBases.append(base)
        try? store?.persistence?.upsertKnowledgeBase(base)
        applyKnowledgeChange()
        return nil
    }

    /// 改描述 / 启停。内置库不可改 (它的存在由落盘目录决定, 不归用户配置)。
    @discardableResult
    func updateKnowledgeBase(id: String, description: String? = nil,
                             enabled: Bool? = nil) -> KnowledgeBaseRejection? {
        guard let idx = knowledgeBases.firstIndex(where: { $0.id == id }) else { return .builtinImmutable }
        if let description {
            let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !desc.isEmpty else { return .emptyDescription }
            guard desc.count <= KnowledgeBase.descriptionLimit else {
                return .descriptionTooLong(limit: KnowledgeBase.descriptionLimit)
            }
            knowledgeBases[idx].description = desc
        }
        if let enabled { knowledgeBases[idx].enabled = enabled }
        knowledgeBases[idx].updatedAt = .now
        try? store?.persistence?.upsertKnowledgeBase(knowledgeBases[idx])
        applyKnowledgeChange()
        return nil
    }

    /// 停用内置库 —— **允许**。理由: "现在别把 memory/ 塞进 prompt"是个正当诉求
    /// (比如它在一段会话里成了噪声源), 而库的**存在**不归用户配置、**是否生效**归用户配置。
    /// 它仍然**不可删** —— 删了下次现算又回来, 那种"删了又出现"的按钮比没有按钮更坏。
    func setBuiltinKnowledgeBaseEnabled(id: String, enabled: Bool) {
        if enabled { builtinDisabled.remove(id) } else { builtinDisabled.insert(id) }
        applyKnowledgeChange()
    }

    /// 被用户停用的内置库 id (**不落库** —— 它是 UI 偏好级别的东西, 与落盘目录同生共死)。
    @Published var builtinDisabled: Set<String> = []

    func deleteKnowledgeBase(id: String) {
        guard !id.hasPrefix("builtin:") else { return }   // 内置库不可删 (见上)
        knowledgeBases.removeAll { $0.id == id }
        try? store?.persistence?.deleteKnowledgeBase(id: id)
        applyKnowledgeChange()
    }

    func toggleKnowledgeBase(id: String) {
        if id.hasPrefix("builtin:") {
            setBuiltinKnowledgeBaseEnabled(id: id, enabled: builtinDisabled.contains(id))
            return
        }
        guard let idx = knowledgeBases.firstIndex(where: { $0.id == id }) else { return }
        knowledgeBases[idx].enabled.toggle()
        knowledgeBases[idx].updatedAt = .now
        try? store?.persistence?.upsertKnowledgeBase(knowledgeBases[idx])
        applyKnowledgeChange()
    }

    /// 路径标准化: 展开 `~` + 去末尾 `/` + 标准化。
    /// **必须做** —— 否则 `/a/b` 与 `/a/b/` 会被当成两个库 (唯一索引也拦不住), 索引里出现两遍。
    static func normalizedBasePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let std = (expanded as NSString).standardizingPath
        return std.count > 1 && std.hasSuffix("/") ? String(std.dropLast()) : std
    }

    /// **带真实生效态的库列表** —— 内置库里被停用的那些在这里折算成 `enabled = false`。
    ///
    /// 为什么必须共用这一份 (2026-09-22): 内置库的 `enabled` 结构上恒为 `true`(它的存在由落盘目录
    /// 决定), "停用"记在 `builtinDisabled` 里。UI 若自己判一遍 `builtinDisabled.contains(id)`,
    /// 那条判据就有**两个真源**: 注入路径读折算后的、面板读原始的 ⇒ 某天改了一处, 开关在另一处
    /// **静默失效**(而它不会变红 —— 点了没反应是"用户没注意"级别的故障)。
    /// 所以列表与注入路径**读同一个属性**; `allKnowledgeBases` 是"未折算"的原始表, 不再对外使用。
    var effectiveKnowledgeBases: [KnowledgeBase] {
        allKnowledgeBases.map { base in
            guard base.isBuiltin, builtinDisabled.contains(base.id) else { return base }
            var copy = base
            copy.enabled = false
            return copy
        }
    }

    // MARK: - 组装注入块 (P11.1: 分层 + 可预测降级)

    /// 组装结果 —— 块文本 + 计数 + 降级/冲突清单 (载荷条 A 块与守卫 1-2 消费)。
    ///
    /// **段边界显式暴露, 不让消费方按行号重新推导** (2026-09-22) —— 组装结构一旦改了
    /// (比如 persona 段插到最前), 所有"数前 N 行"的推导都会静默指错段。冒烟与 UI 一律读这里。
    struct KnowledgeInjection {
        /// 完整组装结果 = `personaText` + `bodyText` (persona 段恒在偏移 0, 守卫 10)。
        var text: String?
        /// persona 段 (来自 pack 文件, P11.2a)。**不参与 priority 排序、不参与超限截尾**。
        var personaText: String = ""
        var personaCount: Int = 0
        var personaChars: Int = 0
        /// 除 persona 段之外的其余部分 (小块头 + 稳定段 + 易变段)。`text` 的后半截。
        var bodyText: String?
        var stableCount: Int = 0
        var stableChars: Int = 0
        var volatileCount: Int = 0
        var volatileChars: Int = 0
        var onDemandCount: Int = 0
        /// 索引段 (P11.4) —— 排在稳定段之后、易变段之前。**空串 = 本段缺席**。
        /// 缺席有两个正当理由: 没有可注入的库, 或预算装不下 (后者必同时有 `indexSkipped`)。
        var indexText: String = ""
        /// 进了索引的库数。
        var indexCount: Int = 0
        var indexChars: Int = 0
        /// 预算装不下 ⇒ **整段缺席**并在此点名每库占多少字 (Q11 方案 A)。
        var indexSkipped: [KnowledgeBaseCost] = []
        /// 挂了、启用了但扫不到任何文档的库 (不进索引, 但 UI 要提示"目录是空的")。
        var emptyKnowledgeBases: [String] = []
        /// 超预算被降级的常驻条目 (priority 升序 = 先掉的在前)。
        var degraded: [KnowledgeItem] = []
        /// 与 persona pack 的 `key` 相撞、因此**不注入**的 DB 条目 (守卫 13)。
        var reservedConflicts: [KnowledgeItem] = []
        var packKeysParseFailed: Bool = false
        /// frontmatter 破损的 pack 文件 (红条要能说"去修哪个文件")。
        var brokenPackFiles: [String] = []
        /// pack 里 `layer: ondemand` 的文件 (§3.2)。
        ///
        /// 它们照旧不进 prompt (对), 但**也进不了索引** —— pack 目录不是任何知识库的扫描根
        /// (L1 落盘目录是它的**子目录** `memory/`, 见 `productionL1Dir`)。⇒ 对模型彻底隐形,
        /// 正是 P11 要根除的那类缺陷。点名让"隐形"变成"响的"。
        ///
        /// ⚠️ 这不是过渡态的残留: `layer: ondemand` 仍是合法写法 (删了解析分支会让老文件按
        /// `?? .always` **整篇挤进 persona 段**, 那是 §3.2 明确要避免的)。只要还可能有人写它,
        /// 这条告警就要在场。
        var onDemandPackFiles: [String] = []
        /// persona 段为空 (§3.2): 挑不出任何常驻条目 ⇒ 段**整段消失**, 本轮 prompt 里没有"我"。
        /// `nil` = 段在场。带原因是因为"下一步做什么"取决于它是哪种空。
        ///
        /// ⚠️ 判据是「**没有可载入的 `.md`**」, 不是"少了几份" —— 用户可**故意**只留一份
        /// (把"必须三份"这种结构塞回数据正是 §2.1 反对的)。破损 / 全按需 / 读不出来三种情形
        /// **不报这条**: 它们各有更准确的告警 (同一件事挨两枪 = 红条变噪音)。
        var personaPackEmpty: PersonaPackEmptyCause? = nil
        /// 存在但读不出来 (编码 / 权限) 的 pack 文件 —— **文件在, 内容却没进 prompt**。
        ///
        /// 与 `PersonaPack.unreadableFiles` 的分工: 那边是"现读磁盘的原始事实", 这边是"本轮组装的
        /// 结论"。磁盘上完全看不出来这件事 (`ls` 照样列出文件), 只有组装器知道。
        var personaUnreadableFiles: [String] = []

        // MARK: 组装自检产物 (§5.6) —— 都靠**独立于组装写法的**检查得出 (字符串查找, 不是集合算术)
        /// ① 应入块的稳定段条目里, 没在块里找到的那些。
        var missingStable: [KnowledgeItem] = []
        /// ③ 常驻条目既不在块内、也不在 `degraded` 里 (= 静默丢弃)。
        var unaccountedResident: [KnowledgeItem] = []
        /// ⑤ persona 段存在但组装结果不是以它开头。
        var personaNotAtOffsetZero: Bool = false
        /// ⑥ 挂了启用的库却没进索引、又不在缺席点名单里 (= 索引被静默丢弃, 守卫 16)。
        var indexSilentlyDropped: [String] = []
        /// ⑦ 段序不是 persona < 稳定段 < 索引段 < 易变段 (守卫 17)。
        var segmentOrderViolated: Bool = false

        var residentCount: Int { personaCount + stableCount + volatileCount }
        var residentChars: Int { personaChars + stableChars + volatileChars }
        var overflowed: Bool { !degraded.isEmpty }
        /// 索引段是否真的进了块。
        var indexPresent: Bool { !indexText.isEmpty }
        var indexBudgetSkipped: Bool { !indexSkipped.isEmpty }
    }

    /// 一个库在索引里占了多少字 (§3.4 预算待遇 Q11 方案 A 的点名单位)。
    /// 单独成一个类型而不是 `(String, Int)` 元组 —— 元组不能合成 `Equatable` (`KnowledgeWarning` 要)。
    struct KnowledgeBaseCost: Equatable {
        let name: String
        let chars: Int
    }

    /// persona 段为空的**原因** (§3.2) —— 两种情况的用户动作不同 (去建目录 / 去放文件),
    /// 所以它是**两个 case**, 不是一个 Bool。
    ///
    /// ⚠️ 这里只报**可判定的事实**, 不猜"是不是被删了": App 只看得到现在的磁盘,
    /// "从未有过"与"刚被删掉"在文件系统上**是同一个状态**。要区分它们得额外存一份持久态
    /// (上次见到非空 pack), 那份状态自己也会过期 —— 判据宁可选"可判定", 不选"能分辨"。
    enum PersonaPackEmptyCause: Equatable {
        /// 目录不在 (尚未建 / 已被移走或删掉; 路径被同名文件占着时同判)。
        case dirMissing
        /// 目录在, 但里面没有一个可载入的 `.md`。
        case noFiles
    }

    /// 组装告警 —— **数据, 不是文案**。消费方各自措辞 (UI 走 `L()`, 事件流走它自己的格式)。
    /// 只在这里拼字符串会掉进"隐形漏译"的坑, 理由见 `injectionWarnings` 的注释。
    enum KnowledgeWarning: Equatable {
        /// 常驻超限: 按 priority 从低到高**截尾**降级的条目 (任务照常执行)。
        /// 带标题而不是只带个数 —— "超限了"是无字之墙, "这三条没进 prompt"才是可行动信息 (§4.2 A)。
        case residentOverflow(titles: [String])
        /// 与 persona pack 的 `key` 相撞、被跳过注入的 DB 条目 (守卫 13)。红条要能**指名道姓**。
        case reservedKeyConflicts(titles: [String])
        /// persona pack 里有文件 frontmatter 破损 ⇒ 该文件不注入 + 已保守禁止新建任何 key (守卫 5/9)。
        /// 带文件名: "去修那个文件"是可行动信息, "pack 坏了"不是。
        case personaFrontmatterBroken(files: [String])
        /// pack 里有文件**读不出来** (编码 / 权限): 文件在磁盘上、`ls` 看得见, 内容却进不了 prompt。
        /// "读不出来"和"没有这个文件"是两件事 —— 只有前者用户能在原文件上修。
        case personaUnreadableFiles(files: [String])
        /// ① 稳定段缺条 —— 应入块的硬规/身份没进 prompt (§5.6 ①)。
        case stableSegmentMissing(titles: [String])
        /// ③ 常驻条目既不在块内也不在降级清单里 = **静默丢弃** (§5.6 ③) —— 这正是 P11 要根除的病。
        case silentlyDropped(titles: [String])
        /// ⑤ persona 段没落在组装结果的偏移 0 (§5.6 ⑤ / §3.2 结构性不变量)。
        case personaNotAtOffsetZero
        /// persona 段**为空** (§3.2): 本轮 prompt 里没有"我"。带原因 —— 用户动作不同。
        ///
        /// 为什么这也要响: 它是**整段缺席**, 而 persona 段存在的全部意义就是"每轮都在场"。
        /// 少了它 agent 照常跑、照常答, 只有它自己不知道"我是谁" —— 这正是零红灯的隐形缺陷。
        case personaPackEmpty(cause: PersonaPackEmptyCause)
        /// 索引段**整段缺席**: 预算装不下 (§3.4 Q11 方案 A)。带每库占多少字 ——
        /// "索引太大"是无字之墙, "项目文档 1800 字、笔记 900 字"才是用户能动手的信息。
        case indexSkipped(bases: [KnowledgeBaseCost])
        /// ⑥ 挂了启用的库却没进索引、又不在缺席点名单里 = 索引被**静默丢弃** (守卫 16)。
        /// 与 `.silentlyDropped` 同一个病, 只是对象是库不是条目 —— 应当是代码回归。
        case indexSilentlyDropped(bases: [String])
        /// pack 里有 `layer: ondemand` 的文件 (§3.2): 不进 prompt 是对的, 但它们**也进不了索引**
        /// (pack 目录不是任何库的扫描根) ⇒ 对模型**隐形**。带文件名 —— "把哪一份迁去知识库"才是可行动信息。
        case onDemandPackFiles(files: [String])

        /// 分类键 —— 供断言与事件流去重 (与文案无关)。
        var kind: Kind {
            switch self {
            case .residentOverflow:         return .residentOverflow
            case .reservedKeyConflicts:     return .reservedKeyConflicts
            case .personaFrontmatterBroken: return .personaFrontmatterBroken
            case .stableSegmentMissing:     return .stableSegmentMissing
            case .silentlyDropped:          return .silentlyDropped
            case .personaNotAtOffsetZero:   return .personaNotAtOffsetZero
            case .personaPackEmpty:         return .personaPackEmpty
            case .personaUnreadableFiles:   return .personaUnreadableFiles
            case .indexSkipped:             return .indexSkipped
            case .indexSilentlyDropped:     return .indexSilentlyDropped
            case .onDemandPackFiles:        return .onDemandPackFiles
            }
        }
        enum Kind: Equatable {
            case residentOverflow, reservedKeyConflicts, personaFrontmatterBroken
            case stableSegmentMissing, silentlyDropped, personaNotAtOffsetZero
            case personaPackEmpty, personaUnreadableFiles
            case indexSkipped, indexSilentlyDropped, onDemandPackFiles
        }
    }

    /// 分层组装:
    /// - **persona 段** (来自 pack 文件) 恒在**偏移 0**, 不参与 priority 排序、**不参与超限截尾**;
    /// - **稳定段** (persona/user/rule 的 DB 条目) 跟在其后, **永不降级** —— 它承载的是"我是谁", 不是可丢的知识;
    /// - **索引段** (P11.4 知识库) 再跟其后, **不参与 priority 降级**, 装不下则整段缺席 + 告警 (Q11 方案 A);
    /// - **易变段** 按 `priority` 降序放, 超预算的部分记入 `degraded` (不再按 updatedAt 静默丢最旧);
    /// - `layer=ondemand` 进不了 prompt, 只计数 (落盘见 `syncL1Files`)。
    ///
    /// 段序 (persona < 稳定段 < 索引段 < 易变段) 是**结构**, 不是排序的副产物 —— 守卫 17 直接比偏移。
    func buildInjection() -> KnowledgeInjection {
        var out = KnowledgeInjection()
        let pack = reloadPersonaPack()
        let reserved = pack.reservedKeys
        out.packKeysParseFailed = pack.parseFailed
        out.brokenPackFiles = pack.brokenFiles
        // §3.2 过渡态点名: 既不入 persona 段、又不在任何库扫描根下 ⇒ 会隐形 (见字段注释)。
        // 破损文件不算 —— 它们走 `brokenPackFiles` 那条更严重的告警, 不该同时挨两枪。
        out.onDemandPackFiles = pack.entries
            .filter { $0.layer == .ondemand && !$0.isBroken }
            .map(\.fileName)
            .sorted()
        out.personaUnreadableFiles = pack.unreadableFiles
        let eligible = injectableScopedItems
        // 计数口径与"会被注入的集合"**同源** (`injectableScopedItems`) —— 载荷条说的是"这一轮真的
        // 进去了几条", 所以它**必须**排除被关掉的条目; 而左列是"用户有哪些条目", 两者有意不同源
        // (见 `customKnowledge`: 关掉的条目可见但不注入)。
        out.onDemandCount = eligible.filter { !$0.isResident }.count
        var resident = eligible.filter { $0.isResident }
        // 组装期撞 pack key: pack 唯一持有 ⇒ 该条不注入 (写入期漏网的手改文件会在这里被兜住)
        if !reserved.isEmpty {
            out.reservedConflicts = resident.filter { item in
                item.key.map { reserved.contains($0) } ?? false
            }
            let conflicted = Set(out.reservedConflicts.map(\.id))
            resident.removeAll { conflicted.contains($0.id) }
        }
        let clipped = resident.map(Self.clipped)
        let stable = clipped.filter { $0.kind.isStableSegment }.sorted(by: Self.stableOrder)
        let volatile = clipped.filter { !$0.kind.isStableSegment }.sorted(by: Self.volatileOrder)
        // body = 三段按序拼 (守卫 17: persona < 稳定段 < 索引段 < 易变段)。
        // 为什么从"单一 `lines` 数组"改成"块数组": 索引段不是 `- [tag] …` 那种行, 而是一整块
        // 自带段头与缩进的文本。拼接方式对**没有库的情况逐字节等价**于旧的平铺数组。
        var blocks: [String] = []
        var stableLines: [String] = []
        for item in stable {
            stableLines.append(Self.line(item))
            out.stableCount += 1
            out.stableChars += Self.cost(item)
        }
        if !stableLines.isEmpty { blocks.append(stableLines.joined(separator: "\n")) }
        // persona 段: 独立第一段 (§3.2 结构性不变量)。**排在 budget 之前扣**, 因为它永不参与截尾 ——
        // 它吃掉的那部分预算必须真的从"可丢条目"的额度里扣掉, 否则载荷条会说"64k 里只用了 30k"
        // 而真实 prompt 已经 50k。代价: persona 段过胖时易变段会整体降级 (那是真话, 不是 bug)。
        out.personaText = Self.personaSegment(pack)
        out.personaCount = pack.residentEntries.count
        out.personaChars = pack.residentEntries.reduce(0) { $0 + $1.content.count }
        // §3.2 空 pack: 段**整段为空** ⇒ 本轮 prompt 里没有"我"。
        //
        // ⚠️ 判据读**产物** (`personaText`), 不是输入的集合算术 (`pack.residentEntries.isEmpty`) ——
        // 与 §5.6 同一条纪律: 组装哪天把这段拼丢了, 集合算术照样说"有 3 个常驻条目", 只有读产物
        // 才看得见。"被检查的东西"不可以自己出题。
        //
        // 三种"有文件却挑不出常驻条目"的情形**各有更准的告警**, 不在这里重复报 (同一件事挨两枪
        // 会让红条变噪音, 用户开始无视红条 —— 那比不报还坏):
        //   ① 破损 ⇒ `.personaFrontmatterBroken` (点名文件, 且连带收紧 key)
        //   ② 全按需 ⇒ `.onDemandPackFiles` (病是"进不了索引", 比"段为空"更具体)
        //   ③ 读不出来 ⇒ `.personaUnreadableFiles` (上面那条, 它自己就是最准的)
        if out.personaText.isEmpty && !pack.parseFailed
            && out.onDemandPackFiles.isEmpty && pack.unreadableFiles.isEmpty {
            out.personaPackEmpty = pack.dirMissing ? .dirMissing : .noFiles
        }
        var budget = Tune.knowledgeTotalCharLimit - out.personaChars - out.stableChars
        // ---- 索引段 (P11.4) ----
        // 判定**先于易变段**有两层理由, 缺一都会错:
        //  ① 位置: 它排在易变段之前 (§2.2 前缀稳定性的支点 —— 保住 persona + 稳定段这段最长稳定前缀)。
        //  ② 语义: 它**不参与 priority 降级**。索引是"地图", 局部截尾的地图会让 agent 以为
        //     "资料只有这些", 比没有地图更坏 ⇒ 装不下就**整段缺席** + 点名每库占多少字。
        //     缺席是**响的** (有 `.indexSkipped` 告警), 不是静默的 (Q11 方案 A / 守卫 16)。
        let indexSegment = knowledgeIndexSegment()
        if let seg = indexSegment {
            if seg.chars <= budget {
                blocks.append(seg.text)
                out.indexText = seg.text
                out.indexCount = seg.count
                out.indexChars = seg.chars
                budget -= seg.chars
            } else {
                out.indexSkipped = seg.bases
            }
            out.emptyKnowledgeBases = seg.emptyBases
        }
        // **截尾**, 不是贪心填空: 一旦某条装不下, 它**与它之后的所有条目**一律降级。
        // 反例 (贪心 `continue` + 继续试): priority=180 的大条目被降, priority=3 的小条目
        // 却因为"缝隙还塞得下"进了 prompt ⇒ 用户看到"高优先级没进、低优先级进了",
        // 规则不再可预测 —— 而可预测正是 §2.5 把降级依据从 updatedAt 换成 priority 的全部理由。
        var cut = volatile.count
        var volatileLines: [String] = []
        for (idx, item) in volatile.enumerated() {
            let cost = Self.cost(item)
            if cost > budget { cut = idx; break }
            volatileLines.append(Self.line(item))
            out.volatileCount += 1
            out.volatileChars += cost
            budget -= cost
        }
        if !volatileLines.isEmpty { blocks.append(volatileLines.joined(separator: "\n")) }
        // 尾巴 = 被降级的(priority 升序 = 先掉的在前)
        if cut < volatile.count { out.degraded = Array(volatile[cut...]) }
        out.degraded.sort { $0.priority < $1.priority }
        out.bodyText = blocks.isEmpty ? nil : ([Self.blockHeader] + blocks).joined(separator: "\n")
        // 拼接: persona 段为空时**不留前导换行** (否则"没有 pack"也会让块以空行开头 = 白吃 token)
        switch (out.personaText.isEmpty, out.bodyText) {
        case (true,  let body?):    out.text = body
        case (false, let body?):    out.text = out.personaText + "\n" + body
        case (false, nil):          out.text = out.personaText
        case (true,  nil):          out.text = nil
        }
        Self.selfCheck(into: &out, stable: stable, resident: resident, volatile: volatile,
                       indexBases: indexSegment?.bases ?? [])
        return out
    }

    /// 组装自检 (§5.6)。判据必须**独立于上面的组装写法** —— 这里一律靠**在拼好的块里找字符串**,
    /// 而不是复用"应该进了"的集合算术: 复用等于让被检查的东西自己出题, 造反例永远不会红。
    ///
    /// - Parameter indexBases: 本该进索引的库 (启用 + 非空 + 有块)。**传的是"期望集", 但判定靠
    ///   在块里搜 token** —— 与 ① 同一种独立性。
    private static func selfCheck(into out: inout KnowledgeInjection,
                                  stable: [KnowledgeItem],
                                  resident: [KnowledgeItem],
                                  volatile: [KnowledgeItem],
                                  indexBases: [KnowledgeBaseCost]) {
        let block = out.bodyText ?? ""
        // ① 稳定段一条不缺: 应入块的稳定条目必须能在块里逐行找到
        out.missingStable = stable.filter { !block.contains(Self.line($0)) }
        // ③ 无静默丢弃: 每个常驻条目必须落在 ①块内 ②降级清单 之一
        let degradedIds = Set(out.degraded.map(\.id))
        out.unaccountedResident = resident.filter { item in
            !degradedIds.contains(item.id) && !block.contains(Self.line(Self.clipped(item)))
        }
        // ⑤ persona 段确实在偏移 0 (§3.2: "我是谁"是结构, 不是"priority 碰巧排前")
        out.personaNotAtOffsetZero = !out.personaText.isEmpty
            && !(out.text?.hasPrefix(out.personaText) ?? false)
        // ⑥ 索引段无静默丢弃 (守卫 16): 每个"挂了、启用、非空"的库必须落在
        //    ①块内(搜 `[知识库] <目录名>`) 或 ②缺席点名单 之一 —— 缺席是正当的(预算不够),
        //    静默丢弃不是。这正是 `.silentlyDropped` 的同款判据, 只是对象是库。
        let skippedNames = Set(out.indexSkipped.map(\.name))
        out.indexSilentlyDropped = indexBases.filter { cost in
            !skippedNames.contains(cost.name)
                && !block.contains("\(KnowledgeBaseScan.token) \(cost.name)")
        }.map(\.name)
        // ⑦ 段序 (守卫 17): persona < 稳定段 < 索引段 < 易变段。**比偏移, 不复用组装顺序** ——
        //    组装顺序写错时"按组装顺序读"当然是对的, 造反例永远不会红 (与 §5.6 同一条纪律)。
        out.segmentOrderViolated = Self.segmentOrderViolated(out, stable: stable, volatile: volatile)
        _ = volatile   // 仅参与上面的截尾与段序检查, 自检不直接读它 (降级清单已覆盖)
    }

    /// 段序自检 (守卫 17)。在**拼好的整块**里找各段首字节的偏移并断言单调递增。
    /// 缺段 (persona 为空 / 索引缺席 / 首条易变被降级) 时**跳过对应标记** —— 只检查在场的段。
    private static func segmentOrderViolated(_ out: KnowledgeInjection,
                                            stable: [KnowledgeItem],
                                            volatile: [KnowledgeItem]) -> Bool {
        guard let full = out.text else { return false }
        let ns = full as NSString
        func offset(_ s: String) -> Int? {
            guard !s.isEmpty else { return nil }
            let r = ns.range(of: s)
            return r.location == NSNotFound ? nil : r.location
        }
        var marks: [Int] = []
        if let o = offset(out.personaText) { marks.append(o) }                       // persona
        if let first = stable.first, let o = offset(Self.line(first)) { marks.append(o) }   // 稳定段
        if let o = offset(out.indexText) { marks.append(o) }                         // 索引段
        if let first = volatile.first,
           let o = offset(Self.line(Self.clipped(first))) { marks.append(o) }        // 易变段
        return marks != marks.sorted()
    }

    /// 兼容入口 (Composer pill / 注入快照 / 冒烟): 只要块文本。
    func buildKnowledgeBlock() -> String? { buildInjection().text }

    /// 用户在 App **外面**改了人格文件 ⇒ 重新现读磁盘并重建快照。
    ///
    /// 为什么需要它: 快照只在知识变动/启动时重建, 而改文件不经过本类 —— 没有这个入口的话,
    /// 用户改完 SOUL.md 看到的是**旧内容**, 会以为"改了没用"。改完仍要重启引擎 (注入在 spawn 期生效)。
    func reloadPersonaPackAndRefresh() {
        refreshSnapshot()
        store?.knowledgeDirty = true
    }

    /// 启动期: 重建注入块快照 (ChatStore.init 调用) + L1 落盘对账。
    func refreshSnapshot() {
        let injection = buildInjection()
        lastInjection = injection
        currentKnowledgeBlock = injection.text
        syncL1Files()
    }

    // MARK: - 组装细节

    private static let blockHeader = "以下是 MangoX 客户端注入的知识库/记忆, 回答时请参考:"

    /// persona 段的小标题。**注入面文本 ⇒ 恒中文** (本文件在 `gen_strings.py` 的 `EXCLUDE_FILES`
    /// 里, 在这里写 `L()` 的 key 永远进不了词表 —— 理由见 `injectionWarnings` 的注释)。
    private static let personaHeader = "以下是我的人格本体 (persona pack, 只读, 恒在提示词最前):"

    /// 组装 persona 段。**恒为整块的偏移 0** (§3.2 结构性不变量 / 守卫 10)。
    ///
    /// 为什么"人格"不能只是"priority 比较高的条目": `fact` 是可丢的知识, `persona` 是"我" ——
    /// 丢了它这个 agent 就不再是它。两者失败代价不在一个数量级, 不能用同一个可以手滑改掉的
    /// 数字参数来担保。所以它是**结构** (独立首段 + 不参与截尾), 不是**数据** (priority 大)。
    private static func personaSegment(_ pack: PersonaPack) -> String {
        let entries = pack.residentEntries
        guard !entries.isEmpty else { return "" }
        var parts = [personaHeader]
        for e in entries {
            parts.append("--- \(e.fileName) ---")
            parts.append(e.content)
        }
        return parts.joined(separator: "\n")
    }

    /// 单条上限截断 (与旧行为一致)。
    private static func clipped(_ item: KnowledgeItem) -> KnowledgeItem {
        guard item.content.count > Tune.knowledgeItemCharLimit else { return item }
        var copy = item
        copy.content = String(copy.content.prefix(Tune.knowledgeItemCharLimit))
            + "\n…(超出单条上限已截断)"
        return copy
    }

    private static func cost(_ item: KnowledgeItem) -> Int { item.title.count + item.content.count }

    /// 拼一行注入文本。用 `kind.tag` (**中文原文**) —— 注入块是给模型的契约, 不随界面语言变
    /// (见 `KnowledgeKind.tag` 注释 / 守卫 12)。
    private static func line(_ item: KnowledgeItem) -> String {
        "- [\(item.kind.tag)] \(item.title): \(item.content)"
    }

    /// 稳定段排序: priority 降序; 同 priority 用**与编辑无关**的稳定键兜底 (title/id),
    /// 否则改一条 persona 的正文就会抖动整个稳定段 —— 而稳定段的字节稳定是硬要求 (守卫 12)。
    private static func stableOrder(_ a: KnowledgeItem, _ b: KnowledgeItem) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        if a.title != b.title { return a.title < b.title }
        return a.id.uuidString < b.id.uuidString
    }

    /// 易变段排序: priority 降序, 同 priority 取较新的在前。
    private static func volatileOrder(_ a: KnowledgeItem, _ b: KnowledgeItem) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// 告警数据 (空 = 无告警)。**注: 注入行为本身永不因此被阻断** (P11 §2.5)。
    /// 只出数据不出文案 —— 理由见 `KnowledgeWarning` 与 `injectionWarnings` 的注释。
    ///
    /// 顺序 = 严重度递减 (**结构坏了 > 内容丢了 > 数据没进来**) —— UI 直接按数组顺序渲染红条,
    /// 所以顺序是这里的责任, 不是 View 的。
    private static func warnings(for injection: KnowledgeInjection) -> [KnowledgeWarning] {
        var out: [KnowledgeWarning] = []
        if injection.personaNotAtOffsetZero {
            out.append(.personaNotAtOffsetZero)
        }
        // persona 段的两种"自身有问题"紧跟其后 —— 都是**结构层**的 (整段不在场 / 文件读了没用),
        // 比下面"某条内容丢了"更靠前。空 pack 又排在破损之前: 前者是整段没了, 后者是段还在、少一份。
        if let cause = injection.personaPackEmpty {
            out.append(.personaPackEmpty(cause: cause))
        }
        if injection.packKeysParseFailed {
            out.append(.personaFrontmatterBroken(files: injection.brokenPackFiles))
        }
        if !injection.personaUnreadableFiles.isEmpty {
            out.append(.personaUnreadableFiles(files: injection.personaUnreadableFiles))
        }
        if !injection.missingStable.isEmpty {
            out.append(.stableSegmentMissing(titles: injection.missingStable.map(\.title)))
        }
        if !injection.unaccountedResident.isEmpty {
            out.append(.silentlyDropped(titles: injection.unaccountedResident.map(\.title)))
        }
        if injection.overflowed {
            out.append(.residentOverflow(titles: injection.degraded.map(\.title)))
        }
        // 索引段整段缺席 —— 排在"条目降级"之后: 它是**结构性缺席**, 不是单条内容丢了。
        // pack 里的按需文件排在这里: 它的**解法**就是"把它挂成知识库", 与下面几条同类 (要用户动手)。
        if !injection.onDemandPackFiles.isEmpty {
            out.append(.onDemandPackFiles(files: injection.onDemandPackFiles))
        }
        if !injection.indexSkipped.isEmpty {
            out.append(.indexSkipped(bases: injection.indexSkipped))
        }
        if !injection.indexSilentlyDropped.isEmpty {
            out.append(.indexSilentlyDropped(bases: injection.indexSilentlyDropped))
        }
        if !injection.reservedConflicts.isEmpty {
            out.append(.reservedKeyConflicts(titles: injection.reservedConflicts.map(\.title)))
        }
        return out
    }

    // MARK: - persona pack (P11.1 只读 keys; P11.2a 读全文并成为注入块第一段)

    /// pack 目录: `~/.mangox/agent/` (P11 §3.2 Q2a 拍板)。目录不存在 = 空 pack (**尚未迁移**), 不是错误。
    static var defaultPersonaPackDir: String { agentRoot }
    /// 冒烟/测试可指向临时目录 (**冒烟绝不读用户家目录**, 否则断言会随用户手改文件随机变红)。
    /// 未设时回落 `agentRootOverride` —— 见 `agentRootOverride` 处"为什么必须是进程级"。
    var personaPackDirOverride: String?
    var personaPackDir: String { personaPackDirOverride ?? Self.defaultPersonaPackDir }
    /// 最近一次现读磁盘的结果 (UI 展示与组装校验**同源**, 避免两处各读一次出现漂移)。
    private(set) var personaPack = PersonaPack.empty
    /// pack 的 frontmatter 破损 (= 起始 `---` 没有收尾) ⇒ **收紧**: 保守禁止新建任何 key。
    /// (否则保留集合变空 = 守卫被静默绕过, P11 §8.2 风险 5②)
    private(set) var packKeysParseFailed = false
    /// key → 持有它的 pack 文件名 (UI 提示"请去改那个文件")。
    private(set) var packKeyHolders: [String: String] = [:]

    enum FrontmatterKeys {
        case none                  // 没有 frontmatter (合法)
        case failed                // 有起始 --- 但没收尾 ⇒ 解析失败 (保守收紧)
        case keys([String])
    }

    /// 现读磁盘 (用户任何方式改文件, 下轮即生效; 与 L1"磁盘为准"同一纪律)。
    @discardableResult
    func reloadPersonaPack() -> PersonaPack {
        personaPack = PersonaPack.load(dir: personaPackDir)
        packKeysParseFailed = personaPack.parseFailed
        packKeyHolders = personaPack.keyHolders
        return personaPack
    }

    /// 兼容入口 (P11.1 起的调用点): 保留集合。
    @discardableResult
    func reloadPackKeys() -> Set<String> { reloadPersonaPack().reservedKeys }

    func reservedKeys() -> Set<String> { reloadPersonaPack().reservedKeys }

    // 曾在此有一个 `reloadPackKeysAndHolders()` (→ `[String: String]`), 供编辑器显示"哪些 key 被占用"
    // —— P11.2c 撤下 key 输入口后它连同 `ChatStore` 的转发一起删掉 (唯一消费者没了)。
    // **别原样加回来**: 它的语义是"渲染期现读磁盘"(每次 body 求值都重解析一遍 pack 目录),
    // 把 IO 放进了渲染路径。真要显示保留集合时读**快照属性** `packKeyHolders` ——
    // 它由 `reloadPersonaPack()` 在配置变更时统一刷新, 显示与校验本就不该各自现读一遍。

    /// 极简 frontmatter `keys:` 判定 —— **已退化为 `PersonaPack.parse` 的薄包装**。
    ///
    /// - Important: 这里只做**三态归类**, 不再自带解析逻辑。全项目只有一个 frontmatter 解析器
    ///   (`PersonaPack.parse`): 若这里另存一份实现, 两份迟早对同一个文件给出不同判定
    ///   (一份说破损、一份说没事), 守卫 9 的"破损 ⇒ 收紧"就会漏 —— 而漏掉的正是它要防的那件事。
    static func parseFrontmatterKeys(_ raw: String) -> FrontmatterKeys {
        let parsed = PersonaPack.parse(raw)
        if parsed.broken { return .failed }
        if parsed.noFrontmatter { return .none }
        return .keys(parsed.keys)      // 有 frontmatter 但没写 keys ⇒ `.keys([])`, 与旧行为一致
    }

    /// 写入前的 key 校验结果 —— **数据, 不是文案**。理由同 `KnowledgeWarning`:
    /// 本文件在 `gen_strings.py` 的 `EXCLUDE_FILES` 里 (它同时拼**注入面**文本, 注入面必须恒中文),
    /// 在这里 `L("…")` 得到的 key **永远进不了词表** ⇒ 英文界面静默回落中文, 而且词表门跳过本文件、
    /// 连"已废弃"都不报 —— **三道 l10n 门全都看不见**。
    ///
    /// - Important: 2026-09-22 实测踩过**两次**。第一次修了告警 (`KnowledgeWarning`), 但漏了这里 ——
    ///   本类型就是那次漏掉的遗留: 原先 `keyRejection` 直接返回拼好的中文串, 其中 4 条 key
    ///   (「该 key 由 persona pack 持有」/「请直接改那个文件」/「key 已被另一条占用」/「key 全局唯一」)
    ///   从未进过词表。**判据: 本文件里出现 `L(` 就是 bug**, 不管它看起来多像"只是内部错误串"。
    enum KeyRejection: Equatable {
        /// pack 的 frontmatter 破损 ⇒ 保守禁止任何带 key 的写入 (**失败时收紧, 不放松**, 守卫 9)。
        case packFrontmatterBroken
        /// 该 key 由 persona pack 持有 (pack 唯一持有, §2.4 / 守卫 3)。
        case heldByPack(key: String, file: String)
        /// DB 内已有另一条占用 (key 全局唯一)。
        case duplicateKey(key: String)
    }

    /// 写入前的 key 校验。nil = 可写; 非 nil = **拒绝原因 (数据)** —— 文案由调用方 (View) 拼。
    /// 判据见 P11 §2.4: 设计上不允许冲突存在 —— 撞了不是"谁赢", 而是**拒绝创建**。
    func keyRejection(_ rawKey: String?, excluding id: UUID? = nil) -> KeyRejection? {
        guard let key = Self.normalizedKey(rawKey) else { return nil }
        _ = reloadPackKeys()
        if packKeysParseFailed { return .packFrontmatterBroken }
        if let holder = packKeyHolders[key] { return .heldByPack(key: key, file: holder) }
        if knowledgeItems.contains(where: { $0.key == key && $0.id != id }) {
            return .duplicateKey(key: key)
        }
        return nil
    }

    private static func normalizedKey(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - CRUD (P3.7)

    /// 新建条目。返回 nil = 成功; 非 nil = 拒绝原因 (**数据**, 文案在 View 侧拼)。
    ///
    /// - Note: `key` / `trigger` / `counterfactual` **保留在签名里但 UI 已不再传** (P11.2c);
    ///   `kind` / `layer` / `priority` 同样保留 (P11.2d)。它们是**模型层能力**, 不该随 UI 撤下
    ///   而被删 —— 冲突检测 (守卫 3/9)、P11.3 的教训回路、P11.4 的知识库档都还要用;
    ///   将来把输入口加回来时, 这里零改动。
    ///
    /// - Important: `layer` 的缺省是 **`.always`** (与 `KnowledgeItem.layer` 的缺省一致):
    ///   UI 不再问"这条进不进每轮 prompt", 于是缺省就是**产品行为** —— 新建 = 生效。
    ///   改成 `.ondemand` 会让用户新建的知识**静默不进 prompt** (填了不生效)。同一判据见
    ///   `KnowledgeItem.layer` 的注释。
    @discardableResult
    func addKnowledge(title: String, content: String, scope: KnowledgeScope, projectId: UUID?,
                      kind: KnowledgeKind = .fact, layer: KnowledgeLayer = .always,
                      priority: Int = 0, key: String? = nil,
                      trigger: String? = nil, counterfactual: String? = nil) -> KeyRejection? {
        if let reason = keyRejection(key) { return reason }
        let item = KnowledgeItem(id: UUID(), scope: scope,
                                 projectId: scope == .project ? projectId : nil,
                                 title: title, content: content, source: .manual,
                                 kind: kind, layer: layer,
                                 priority: KnowledgeItem.clampedPriority(priority),
                                 key: Self.normalizedKey(key), trigger: trigger,
                                 counterfactual: counterfactual)
        knowledgeItems.insert(item, at: 0)
        try? store?.persistence?.upsertKnowledge(item)
        applyKnowledgeChange()
        return nil
    }

    @discardableResult
    func updateKnowledge(_ item: KnowledgeItem) -> KeyRejection? {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == item.id }) else { return nil }
        if let reason = keyRejection(item.key, excluding: item.id) { return reason }
        var clean = item
        clean.key = Self.normalizedKey(item.key)
        // 归一化写在唯一入口 (纵深防御: 上层控件已钳, 但手改 DB / 将来的导入器不走 UI)
        clean.priority = KnowledgeItem.clampedPriority(item.priority)
        knowledgeItems[idx] = clean
        try? store?.persistence?.upsertKnowledge(clean)
        applyKnowledgeChange()
        return nil
    }

    func deleteKnowledge(id: UUID) {
        knowledgeItems.removeAll { $0.id == id }
        try? store?.persistence?.deleteKnowledge(id: id)
        applyKnowledgeChange()
    }

    func toggleKnowledge(id: UUID) {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == id }) else { return }
        knowledgeItems[idx].enabled.toggle()
        knowledgeItems[idx].updatedAt = .now
        try? store?.persistence?.upsertKnowledge(knowledgeItems[idx])
        applyKnowledgeChange()
    }

    /// 会话内"保存为记忆": 文本沉淀为全局知识条目, 带 origin_session_id 溯源。
    /// 种类 / 层走 `KnowledgeItem` 缺省 (`.fact` / `.always`) —— "保存为记忆"的语义就是"让它知道"。
    func saveAsMemory(_ text: String, sessionId: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = String(trimmed.split(separator: "\n").first?.prefix(24) ?? "记忆")
        let item = KnowledgeItem(id: UUID(), scope: .global, projectId: nil,
                                 title: String(title), content: trimmed,
                                 source: .session, originSessionId: sessionId)
        knowledgeItems.insert(item, at: 0)
        try? store?.persistence?.upsertKnowledge(item)
        applyKnowledgeChange()
    }

    // MARK: - Memory distillation (P3.7)

    func setDistillOutcome(_ text: String, isError: Bool) {
        distillOutcome = (text, isError)
        distillOutcomeTask?.cancel()
        distillOutcomeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { distillOutcome = nil }
        }
    }

    /// 提炼模板 (业务语义 = TODO 占位脚手架: 边界示例与反例措辞待首个真实提炼轮后人工打磨)。
    private static func buildDistillPrompt(material: String, existing: [KnowledgeItem]) -> String {
        let list = existing.isEmpty ? "无" :
            existing.map { "- [\( $0.scope == .global ? "全局" : "项目")] \($0.title)" }.joined(separator: "\n")
        return """
        【任务: 记忆提炼】
        下面给你一段人机对话记录与现有知识条目清单。请判断对话中是否出现了值得跨会话长期记住的信息, 只输出 JSON, 不要输出任何其他文字, 不要使用任何工具。

        值得记录的只有三类:
        1. 环境/技术栈事实 —— 机器、项目结构、服务地址、数据规模等稳定事实
        2. 用户偏好与约定 —— 沟通/代码/流程上用户明确表达的偏好与规矩
        3. 决策及理由 —— 对话中拍板的技术或业务决策 (记结论和为什么)

        不要记录: 一次性任务的过程细节、代码片段本身、未验证的推测、与现有条目重复的内容 (见下方清单)。
        TODO(人工打磨): 补充边界示例与反例, 待首轮真实提炼后定稿。

        【现有知识条目】
        \(list)

        【对话记录】
        \(material)

        【输出格式】
        {"items": [{"title": "简短标题", "content": "事实本体, 精炼成独立可读的一句话或几句话", "scope": "global", "reason": "为什么值得记"}]}
        scope 只有 "global" 或 "project" 两种。没有值得记录的内容时输出 {"items": []} —— 宁可空, 不要凑数。
        """
    }

    /// 手动触发: 提炼当前会话 → 候选落 pending (审核在知识面板)。
    /// 失败静默 (解析失败/超时直接放弃, 不打扰)。
    func distillMemoryFromCurrentSession() {
        guard let store else { return }
        guard !distillRunning, !store.isStreaming else { return }
        guard let sid = store.selectedConversationId else { return }
        // 材料: 最近 12 条 text 消息 (user+assistant), 总量截断
        var texts = store.replayMessages(for: sid).compactMap { msg -> String? in
            guard case .text(let s) = msg.content, !s.isEmpty else { return nil }
            return "\(msg.role == .user ? "用户" : "助手"): \(s)"
        }
        guard texts.count > 2 else { return }   // 太短不值得提炼
        texts = Array(texts.suffix(12))
        var material = texts.joined(separator: "\n\n")
        if material.count > Tune.distillMaterialCharLimit {
            material = "…(更早的已省略)\n" + String(material.suffix(Tune.distillMaterialCharLimit))
        }
        let existing = knowledgeItems.filter { $0.status == .active }
        let prompt = Self.buildDistillPrompt(material: material, existing: existing)
        // 归属 = 会话所在的项目分组 (selectedProjectId 只在点项目/建会话时设置,
        // 从侧栏直接点开会话不同步它——用会话反查才是 source of truth)
        let projectId = store.projects.first(where: { $0.items.contains(where: { $0.id == sid }) })?.id
        let model = store.currentProvider.isEmpty ? nil : "\(store.currentProvider)/\(store.currentModelId)"
        let thinking = store.thinkingLevel.rawValue
        distillRunning = true
        MemoryDistiller.shared.run(prompt: prompt, model: model, thinking: thinking) { [weak self] raw in
            guard let self else { return }
            self.distillRunning = false
            guard let raw else {
                self.setDistillOutcome("提炼失败: 超时或引擎无响应 (见控制台日志)", isError: true)
                return
            }
            print("[MemoryDistiller] 原始输出 \(raw.count) 字符: \(raw.prefix(400))")
            let candidates = MemoryDistiller.parseOutput(raw)
            guard !candidates.isEmpty else {
                // 区分"模型认为没什么可记"与"输出解析失败" (都有 items 字段 = 正常应答)
                if raw.contains("\"items\"") {
                    self.setDistillOutcome("提炼完成: 本轮没有值得沉淀的内容", isError: false)
                } else {
                    self.setDistillOutcome("提炼失败: 输出无法解析 (见控制台日志)", isError: true)
                }
                return
            }
            self.addPendingKnowledge(candidates, sessionId: sid, projectId: projectId)
            self.setDistillOutcome("提炼完成: \(candidates.count) 条候选待审核", isError: false)
        }
    }

    /// 候选落 pending: 插入列表 + 落库。注入块未变 (pending 不注入) → 不标 dirty。
    /// 净化: scope=project 但无项目归属 → 降级 global (绝不建"未知项目"条目)。
    private func addPendingKnowledge(_ candidates: [MemoryDistiller.Candidate],
                                     sessionId: UUID, projectId: UUID?) {
        for c in candidates {
            let scope: KnowledgeScope = c.scope == .project && projectId != nil ? .project : .global
            // 种类 / 层 / 排序走 `KnowledgeItem` 的缺省 (`.fact` / **`.always`** / 0) —— P11.2d 起
            // 编辑器不再改它们, 所以"采纳后进不进 prompt"由模型缺省决定: 采纳即生效。这正是
            // P11 之前的行为 (那时 knowledge_items 里的每一条都进 prompt); 落 `.ondemand` 会让
            // 用户点完"采纳入库"却什么都没发生。
            let item = KnowledgeItem(id: UUID(), scope: scope,
                                     projectId: scope == .project ? projectId : nil,
                                     title: c.title, content: c.content,
                                     source: .session, originSessionId: sessionId,
                                     enabled: true, status: .pending, note: c.reason)
            knowledgeItems.insert(item, at: 0)
            try? store?.persistence?.upsertKnowledge(item)
        }
    }

    /// 审核采纳: pending → active, 清 note, 注入块变更 → 标 dirty (重启引擎生效)。
    /// 返回 nil = 成功; 非 nil = 拒绝原因 (**数据**; 采纳时若带 key 撞了 pack, 拒绝而非静默入库)。
    @discardableResult
    func adoptKnowledge(id: UUID) -> KeyRejection? {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == id }),
              knowledgeItems[idx].status == .pending else { return nil }
        if let reason = keyRejection(knowledgeItems[idx].key, excluding: id) { return reason }
        knowledgeItems[idx].status = .active
        knowledgeItems[idx].note = nil
        knowledgeItems[idx].updatedAt = .now
        try? store?.persistence?.upsertKnowledge(knowledgeItems[idx])
        applyKnowledgeChange()
        return nil
    }

    /// 审核丢弃。
    func discardKnowledge(id: UUID) {
        deleteKnowledge(id: id)
    }

    // MARK: - L1 落盘 (P11 §3.3 / 守卫 15 / 守卫 7)

    // ── 落盘重定向 (测试专用) ────────────────────────────────────────────────
    //
    // **进程级**重定向: 冒烟在 `main()` 开头设一次, 此后**任何** `ChatStore` 实例都指向临时目录。
    //
    // 为什么必须是进程级, 而不是"每个实例记得设": 落盘类重定向一旦靠自觉, 迟早有人
    // `ChatStore(...)` 新建一个实例就漏了。**实测踩过 (2026-09-22)**: T-KNOW 造老库的 helper
    // 只设了 `personaPackDirOverride`、没设 `l1RootOverride`, 而 `refreshSnapshot()` 在
    // `ChatStore.init` 里就会对账 L1 ⇒ **一次冒烟就把夹具「老条目」写进了用户真实的
    // `~/.mangox/agent/memory/`**。漏一次就已经是数据污染, 而它不会有任何红灯。
    //
    // 优先级: 实例 override (`l1RootOverride` / `personaPackDirOverride`) > 本静态值 > 真实家目录。
    // 实例级仍保留 —— 单个用例想把两种作用域分桶到不同子目录时用。
    static var agentRootOverride: String?
    /// `~/.mangox/agent` 的解析值 —— persona pack 与跨项目 L1 的共同父层。
    static var agentRoot: String { agentRootOverride ?? (NSHomeDirectory() + "/.mangox/agent") }

    /// L1 落点的**生产形状**（不看测试重定向）—— 跨项目 = `~/.mangox/agent/memory/`;
    /// 项目内 = `<项目>/.mangox/agent/`。
    ///
    /// 守卫 7 的断言对象是"落点形状"这条**政策**, 它不该随测试重定向变 —— 所以政策(本函数)
    /// 与解析(`l1Dir`)分开: 断言查政策, 写入走解析。混在一起的话, 重定向一开守卫就变成自证。
    ///
    /// - Note: 全局多一层 `memory/` 是因为 `~/.mangox/agent/` 顶层已经住着 persona pack ——
    ///   L1 文件落在同一个目录会被 `PersonaPack.load` 当成人格文件读进去。
    static func productionL1Dir(projectPath: String?) -> String {
        guard let p = projectPath, !p.isEmpty else { return NSHomeDirectory() + "/.mangox/agent/memory" }
        return p + "/.mangox/agent"
    }

    /// 实际落点 = 生产形状 + 测试重定向（`agentRootOverride`）。两种作用域都跟着重定向走 ——
    /// **项目内落点也在用户项目里**, 冒烟同样不该往里写。
    static func l1Dir(projectPath: String?) -> String {
        guard agentRootOverride != nil else { return productionL1Dir(projectPath: projectPath) }
        guard let p = projectPath, !p.isEmpty else { return agentRoot + "/memory" }
        return agentRoot + "/proj-" + (p as NSString).lastPathComponent
    }

    /// 守卫 7: L1 落点**不占** `AGENTS.md` / `CLAUDE.md` / `.pi/` (P3.9 概念重命名)。
    /// 判据是"可断言的检查", 不是"我们记得别那么干" —— 冒烟直接调它。
    static func isAllowedL1Path(_ path: String) -> Bool {
        let lowered = path.lowercased()
        if lowered.contains("/.pi/") || lowered.hasSuffix("/.pi") { return false }
        let last = (path as NSString).lastPathComponent
        return !["AGENTS.md", "CLAUDE.md", "AGENTS", "CLAUDE", ".pi"].contains(last)
    }

    /// 冒烟可整体重定向 L1 根 —— **冒烟绝不写用户家目录或用户项目目录**
    /// (同 `personaPackDirOverride`; 否则一次冒烟就在用户真实项目里撒文件)。
    var l1RootOverride: String?

    /// 实例侧落点 (含测试重定向)。重定向时按作用域分桶, 保留"全局 vs 项目"的区分 ——
    /// 否则两种作用域的文件会撞在同一个目录里, 而它们本该分开。
    func resolvedL1Dir(projectPath: String?) -> String {
        guard let root = l1RootOverride else { return Self.l1Dir(projectPath: projectPath) }
        guard let p = projectPath, !p.isEmpty else { return root + "/global" }
        return root + "/proj-" + (p as NSString).lastPathComponent
    }

    /// 上次对账涉及过的目录 —— 全删光时 `desired` 里不会再出现它, 但那些文件还得被清掉。
    private var lastL1Dirs: Set<String> = []

    /// **我们自己的标记** —— 对账时靠它区分"我写的"与"用户自己丢进这个目录的笔记"。
    /// 纪律: 只删带标记的文件, 无标记的一律不动 (这个目录是 App 管的, 但用户的文件是用户的)。
    static let l1MarkerPrefix = "mangox_item:"

    /// 文件名 = `key` (守卫 15: 一条一文件 —— 否则 `read` 了一个文件无法归因到单条, 命中记账就无从记起)。
    ///
    /// - Important: `key` 是**用户输入**, 直接当文件名有两个真风险, 所以这里必须净化:
    ///   ① 路径穿越 (含 `/` 或 `..` 的 key 会写到目录外);
    ///   ② **`key: AGENTS.md` ⇒ 写出一个 `AGENTS.md`, 而 pi 会自动加载那个文件名** ——
    ///      等于用一条知识条目偷偷改了 agent 的指令面, 绕过整个注入通道。
    ///   净化对**正常 key 是恒等变换** (`name.md`), 只有畸形 key 才会看到前缀。
    static func l1FileName(for item: KnowledgeItem) -> String {
        let rawKey = item.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = rawKey.isEmpty ? item.id.uuidString : rawKey
        for bad in ["/", "\\", ":", "\n", "\0"] {
            name = name.replacingOccurrences(of: bad, with: "-")
        }
        if name.isEmpty || name == "." || name == ".." { name = item.id.uuidString }
        if !isAllowedL1Path(name) || name.hasPrefix(".") { name = "k-" + name }
        return name + ".md"
    }

    /// L1 文件正文 —— frontmatter 带我们的标记 + 归属信息 (agent 读到时才知道这条从哪来),
    /// 正文原样落在后面。
    ///
    /// - Note: 曾有一行 `sensitivity:` (P11.2c 随敏感档一起删) —— 它零行为后果:
    ///   能读到这份文件的 agent 本来就已经把正文读到手了, "它是否敏感"这个标记拦不住任何事。
    static func l1FileBody(_ item: KnowledgeItem) -> String {
        """
        ---
        \(l1MarkerPrefix) \(item.id.uuidString)
        title: \(item.title)
        kind: \(item.kind.rawValue)
        ---

        \(item.title)

        \(item.content)
        """
    }

    /// L1 全量对账: 写应存在者、删**带我们标记**但已不该存在者。
    ///
    /// 为什么是**对账**而不是"只写不删": 只写不删 = 已经删掉/改成常驻的条目会以文件形态
    /// 永远留在磁盘上, 而 agent 按路径读它 —— 那就是"记忆只涨不缩"换了个地方复发。
    ///
    /// - Returns: 本次发生变化的路径 (冒烟用来断言"确实动了/确实没动")。
    @discardableResult
    func syncL1Files() -> [String] {
        var desired: [String: [String: String]] = [:]      // dir → (fileName → body)
        for item in knowledgeItems where item.enabled && item.status == .active && !item.isResident {
            let projectPath: String?
            if item.scope == .project {
                // 按**条目自己的**项目找路径 (不是 activeProject) —— 否则切项目会把别的项目的 L1 全删了
                guard let pid = item.projectId,
                      let p = store?.projects.first(where: { $0.id == pid }) else { continue }
                projectPath = p.path
            } else {
                projectPath = nil
            }
            let dir = resolvedL1Dir(projectPath: projectPath)
            guard Self.isAllowedL1Path(dir) else { continue }
            var byName = desired[dir] ?? [:]
            var name = Self.l1FileName(for: item)
            // 净化后撞名 (`a/b` 与 `a-b` 都落成 `a-b.md`): 后来的退回落 id, 谁都不丢
            if byName[name] != nil { name = item.id.uuidString + ".md" }
            byName[name] = Self.l1FileBody(item)
            desired[dir] = byName
        }
        // 还要把"上次写过、这次不该存在"的目录也扫一遍 (条目全删光时 desired 里没有它)
        var dirs = Set(desired.keys)
        dirs.formUnion(lastL1Dirs)
        var changed: [String] = []
        let fm = FileManager.default
        for dir in dirs {
            let want = desired[dir] ?? [:]
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (name, body) in want {
                let path = dir + "/" + name
                // 内容相同就别写 —— 避免每次组装都磨 mtime (备份/同步工具会因此反复嘬盘)
                if let old = try? String(contentsOfFile: path, encoding: .utf8), old == body { continue }
                if (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                    changed.append(path)
                }
            }
            let existing = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for name in existing where name.hasSuffix(".md") && want[name] == nil {
                let path = dir + "/" + name
                guard Self.isOurL1File(path) else { continue }     // 没有标记 = 用户的文件, 不动
                if (try? fm.removeItem(atPath: path)) != nil { changed.append(path) }
            }
        }
        lastL1Dirs = Set(desired.keys)
        return changed
    }

    /// 是不是**我们**写的 L1 文件 —— 只读开头几行找标记。无标记 ⇒ 一律当成用户的文件。
    static func isOurL1File(_ path: String) -> Bool {
        guard let head = try? String(contentsOfFile: path, encoding: .utf8).prefix(400) else { return false }
        return head.contains(l1MarkerPrefix)
    }

    // MARK: - 变更生效 (注入块快照 + 池下发 + dirty 标记)

    /// 知识变动后: 快照注入块 + L1 落盘对账 + 池内实例同步下发 + 标记引擎待重启。
    private func applyKnowledgeChange() {
        let injection = buildInjection()
        lastInjection = injection
        currentKnowledgeBlock = injection.text
        syncL1Files()
        store?.pushKnowledgeContext(currentKnowledgeBlock)
        store?.knowledgeDirty = true
    }
}
