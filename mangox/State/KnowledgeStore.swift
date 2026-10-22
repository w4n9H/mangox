//
//  KnowledgeStore.swift
//  P9.1c: 知识库/记忆域自 ChatStore 抽离 (P3.7 全链路: 条目 CRUD/注入块组装/蒸馏/审核)。
//  拆分不动行为: ChatStore 保留同名 facade 转发 (冒烟/视图零改动);
//  服务持有 store 弱引用, 经 store 回调落库/重放/活跃项目判定; 池下发走 pushKnowledgeContext。
//

import Foundation
import Combine
import CryptoKit

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

    /// 用户挂载的库 (落库的)。P15.1 起**入口已下线**, 只剩历史数据。
    @Published var knowledgeBases: [KnowledgeBase] = []

    // ⚠️ **内置 L1 库已退休**（2026-10-12, 见 P15 §03「内置库退休」改动面那一行）。
    //
    // 它曾是 `~/.mangox/agent/memory/`（跨项目）与 `<项目>/.mangox/agent/`（项目内）两个 L1
    // 落盘目录的**自动挂载**（P11.4 §3.4 / §8.1 Q13），唯一用途 = 让 `layer = .ondemand` 条目的
    // L1 文件对 agent 不隐形。退休的两条依据（都是**实测**，不是口味）：
    //   ① **破门 1** —— 它和两个笔记根混在同一段列表里，界面上就是三行「按需知识 · 全局 /
    //      xx（按需知识）」，而门 1 说这一区里**只有笔记**；
    //   ② **空转** —— 退休时两个 L1 落点都是空目录（新建知识点一律 `.always` ⇒ 没有 ondemand
    //      生产者；库里唯一那条 `ondemand` 条目 `enabled = 0`）⇒ 三个库恒扫到 0 篇，
    //      而索引段本来就是「**空库不注入**」⇒ 它**从来没进过 prompt**。
    //
    // ⚠️ **退休的代价要记住**：ondemand 条目从"有路标"退回"隐形"。今天没有生产者（见 ②），
    // 但 P11.3 解冻时**必须一并重建这个路标** —— 重建成什么形状由那时定（不建议照抄本次退休的
    // 形态：把落盘目录当成一个"库"挂进来，正是它破门 1 的原因）。
    //
    // 它当年顺手带的那个「停用」开关**没有一起退休** —— 左列每一行（含两个笔记根）都用它。
    // 它现在叫 `fixedRootDisabled`，见下。

    /// 被用户停用的**固定根** id（**不落库** —— 它是 UI 偏好级别的东西, 与目录同生共死）。
    ///
    /// ⚠️ 为什么"停用"不直接写进固定根的 `enabled`: 固定根是**现算**的（每次调用重建一个值类型）,
    /// 没有可写的存储位。所以停用集合住在这里, 并由 `noteKnowledgeBases` **在构造时折算进 `enabled`**。
    ///
    /// 折算点**只有一个** ⇒ 注入路径与 UI 列表读到的永远是同一份带真实生效态的表。
    /// （P11.4 的老版本是"两张表 + 谁记得该读哪张" —— 那个形状已经被 2026-09-22 的实测判过死刑;
    /// 现在换成"一个构造点", 同一个不变量用更少的活动件表达。）
    @Published var fixedRootDisabled: Set<String> = []

    /// 笔记根 —— P15.1 的两个固定根（全局 / 各项目）。**派生, 不落库**。
    ///
    /// 为什么派生而不是落库: 路径由 scope 唯一决定（门 1「目录固定成两个根 ⇒ 归属 = 位置」）,
    /// 落库就会出现"项目删了但根还在"的幽灵行; 而描述由 App 写死 ⇒ 库里也没有可配的东西。
    /// 路径走 `resolvedNoteDir` ⇒ **测试重定向自动生效**（冒烟绝不扫用户 `~/.mangox/note`）。
    var noteKnowledgeBases: [KnowledgeBase] {
        var out: [KnowledgeBase] = []
        var seen: Set<String> = []
        func add(_ id: String, _ path: String, _ desc: String, _ label: String) {
            // 同一目录只挂一次：两个项目若指向同一路径（测试重定向下会发生），索引里同一份资料
            // 会出现两遍 —— 纯浪费每轮预算。`enabled` 保留：**一个根一个开关**（门 1 未取消它）。
            guard seen.insert(path).inserted else { return }
            out.append(KnowledgeBase(id: id, path: path, description: desc,
                                     enabled: !fixedRootDisabled.contains(id), isBuiltin: true,
                                     label: label))
        }
        add(KnowledgeBase.noteGlobalID, resolvedNoteDir(projectPath: nil),
            KnowledgeBase.noteGlobalDescription, KnowledgeBase.noteGlobalLabel)
        for p in store?.projects ?? [] {
            guard let path = p.path, !path.isEmpty else { continue }
            // 显示名走 `noteRootLabel`（**唯一产出点**, P15.8）—— dream 摘要段头的 `归属` 读的是
            // 同一个函数 ⇒ 模型靠"名字相等"把会话映射回它的根。两处各写一遍**不会报错**,
            // 只会让归属静默失效（名字对不上 ⇒ 模型回落到全局, 正是 2026-10-13 报的那个缺陷）。
            let label = KnowledgeBase.noteRootLabel(projectTitle: p.title)
            add(KnowledgeBase.noteProjectPrefix + p.id.uuidString,
                resolvedNoteDir(projectPath: path),
                KnowledgeBase.noteProjectDescription, label)
        }
        return out
    }

    /// **UI 与组装共用的唯一根列表**（P15.5 起"唯一"是真的唯一 —— 见下）。
    ///
    /// 顺序（P15.1 调整，**有意推翻** P11.4 的"用户挂载在前"）: **笔记根在前** —— 它是这一区的
    /// 主战场（门 1），而用户挂载库在 P15.1 已下线入口、只剩历史数据, 排最后最不显眼。
    ///
    /// ⚠️ P15.5（2026-10-12）把 P11.4 的 `builtinKnowledgeBases` 退休了（见文件上方那段），
    /// 于是「未折算表 / 折算后表」这一对（`allKnowledgeBases` × `effectiveKnowledgeBases`）消失 ——
    /// **两个名字指同一件事，正是本项目反复吃亏的"两个真源"**。现在只剩这一个名字。
    var allKnowledgeBases: [KnowledgeBase] {
        noteKnowledgeBases + knowledgeBases
    }

    /// 单库查询（面板选中一个库时读它）。
    func knowledgeBase(id: String) -> KnowledgeBase? {
        allKnowledgeBases.first { $0.id == id }
    }

    /// 索引段 (§2.2 / §3.4)。`nil` = 没有可注入的库 (没挂 / 全停用 / 全空)。
    ///
    /// 组装器与 UI 预览**共用它** —— `chars` 是给预算用的真实字符数, `bases` 是缺席点名要用的
    /// 每库占位 (Q11 方案 A: 装不下就整段缺席, 但要说得清是哪些库)。
    struct KnowledgeIndexSegment {
        let text: String
        /// 每库: 显示名 + 该库索引块字符数。缺席告警按它点名。
        let bases: [KnowledgeBaseCost]
        /// 挂了、启用了, 但一个文档都没扫到的根 —— ⚠️ **P15.8 起它们照进索引**
        /// （只给坐标, 文件段是 `（本根暂无笔记）`), 所以**这个字段不再是"没进索引"的意思**。
        /// 留着它是给 UI 用: "这个根还空着"是左列要标的事。名字带的历史已经不对了,
        /// 但改名的动作留到有第二个消费者时一起做（改名半径判据, 见 §05 登记）。
        let emptyBases: [String]
        var count: Int { bases.count }
        var chars: Int { text.count }
    }

    /// **同源入口**: 每个库 + 它扫到的文档。注入文本与 UI 的索引预览都调它 ——
    /// 各扫一遍迟早会出现"预览说 12 个文件、agent 实际看到 9 个"。
    ///
    /// - Important: 读 `allKnowledgeBases`（**唯一根列表**）。P11.4 时代这里埋过一个陷阱 ——
    ///   内置库的 `enabled` 结构上恒为 `true`、停用态另存在 `builtinDisabled` 里，所以只有读
    ///   "折算后"的那份才不会让 `guard base.enabled` 永远放行（否则开关**静默失效**）。
    ///   内置库退休后，那个陷阱连同它的第二份表一起没了（P15.5）。
    ///
    /// 每次现算、不缓存: 与 §3.3「磁盘为准」同一条纪律 —— 用户在 App 外改了目录, 下轮即生效。
    func knowledgeBaseScan() -> [(base: KnowledgeBase, docs: [KnowledgeBaseDoc])] {
        allKnowledgeBases.map { ($0, KnowledgeBaseScan.docs(root: $0.path)) }
    }

    /// 索引段文本 (含段头)。库之间空一行; `enabled = false` 的根**整段不出现**
    /// (§3.4: 索引是给模型看的, 没有"灰"这个状态)。
    ///
    /// ⚠️ **P15.8: 空根照进段**（**有意推翻** P11.4 的「空库不注入」）。为什么:
    /// dream 的硬约束是「`target_path` 的父目录必须是**本段列出的**某一个根」——
    /// 空根不进段 ⇒ 它对模型**不存在** ⇒ 只剩全局一个合法落点。2026-10-13 实测: dream 把
    /// MangoX 项目的洞见写进了全局笔记, 而三个根里只有全局有内容。
    /// 成本 ≈90 字/空根（64000 预算的 0.3%), 换回来的是**归属坐标** —— 而归属正是 dream
    /// 唯一的任务。判据: `indexBlock` 只在 `!enabled` 时返回 nil。
    ///
    /// 连带: `nil` 现在只剩**一种**含义 —— 一个可用的根都没有（全被停用）。它恰好是
    /// `dreamPrompt` 里「没有【笔记目录】段 ⇒ 直接结束」那一支的判据, 两边必须一起改。
    func knowledgeIndexSegment() -> KnowledgeIndexSegment? {
        var parts: [String] = []
        var costs: [KnowledgeBaseCost] = []
        var empty: [String] = []
        for (base, docs) in knowledgeBaseScan() {
            // 停用由 `indexBlock` 自己挡掉（`guard base.enabled`)—— 这里不再重复判一遍,
            // 否则"哪个条件让一个库不进段"就有了两处真源。
            guard let block = KnowledgeBaseScan.indexBlock(for: base, docs: docs) else { continue }
            parts.append(block.text)
            // 空根**也进 `costs`**: 它的块真的占了 `block.chars` 那么多预算, 所以整段缺席时的
            // 点名必须算上它（少说一个字, 用户就找不到"那几行是哪儿来的"）。
            costs.append(KnowledgeBaseCost(name: base.displayName, chars: block.chars))
            if docs.isEmpty { empty.append(base.displayName) }
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

    /// 删掉一个**用户挂载的**库。固定根（笔记根）不可删 —— 但这条现在是**结构保证**，不是前缀判断:
    /// 只在 `knowledgeBases`（落库的那批）里找，而固定根是**现算、不落库**的 ⇒ 结构上就查不到。
    ///
    /// ⚠️ 旧写法是 `guard !id.hasPrefix("builtin:")`。P15.5 退休内置库后那个前缀**没有生产者**了，
    /// 留着它就是一条"永远不为真"的守卫 —— 本项目对这类东西的处置是删掉（§11f 那条教训）。
    func deleteKnowledgeBase(id: String) {
        guard knowledgeBases.contains(where: { $0.id == id }) else { return }
        knowledgeBases.removeAll { $0.id == id }
        try? store?.persistence?.deleteKnowledgeBase(id: id)
        applyKnowledgeChange()
    }

    /// 启停一条根。**两条路按"这个 id 住在哪个集合里"分, 不按 id 前缀分** —— 与
    /// `deleteKnowledgeBase` 同一条判据（固定根现算、用户库落库）。
    ///
    /// ⚠️ 固定根那条路**必须**留着: 左列每一行（含两个笔记根）都有开关, 而它们的 `enabled`
    /// 是构造出来的、写不回去。删掉这条路 = 开关**点了没反应**（本项目最恨的那类故障:
    /// 不报错、不变红, 只是没用）。
    func toggleKnowledgeBase(id: String) {
        if let idx = knowledgeBases.firstIndex(where: { $0.id == id }) {
            knowledgeBases[idx].enabled.toggle()
            knowledgeBases[idx].updatedAt = .now
            try? store?.persistence?.upsertKnowledgeBase(knowledgeBases[idx])
        } else if noteKnowledgeBases.contains(where: { $0.id == id }) {
            if fixedRootDisabled.contains(id) { fixedRootDisabled.remove(id) }
            else { fixedRootDisabled.insert(id) }
        } else {
            return
        }
        applyKnowledgeChange()
    }

    /// 路径标准化: 展开 `~` + 去末尾 `/` + 标准化。
    /// **必须做** —— 否则 `/a/b` 与 `/a/b/` 会被当成两个库 (唯一索引也拦不住), 索引里出现两遍。
    static func normalizedBasePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let std = (expanded as NSString).standardizingPath
        return std.count > 1 && std.hasSuffix("/") ? String(std.dropLast()) : std
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
        /// 时间线段（P18）—— 排在**所有段之后**（易变段后面）。
        ///
        /// 为什么放最末：它每轮都可能变（一轮结束就多一行），压在中间会把后面所有内容
        /// 一起推离"稳定前缀"，缓存一个都命中不了。**空串 = 本段缺席**（没有流水，
        /// 或预算装不下 `timelineSkipped`）。
        var timelineText: String = ""
        var timelineChars: Int = 0
        /// 预算装不下 ⇒ 整段缺席。不参与 priority 降级（它与索引段同性质: 是地图，不是条目）。
        var timelineSkipped: Bool = false
        var onDemandCount: Int = 0
        /// 索引段 (P11.4) —— 排在稳定段之后、易变段之前。**空串 = 本段缺席**。
        /// 缺席有两个正当理由: 没有可注入的库, 或预算装不下 (后者必同时有 `indexSkipped`)。
        var indexText: String = ""
        /// 进了索引的库数。
        var indexCount: Int = 0
        var indexChars: Int = 0
        /// 预算装不下 ⇒ **整段缺席**并在此点名每库占多少字 (Q11 方案 A)。
        var indexSkipped: [KnowledgeBaseCost] = []
        /// 挂了、启用了但扫不到任何文档的根 —— ⚠️ P15.8 起它们**照进索引**（只给坐标),
        /// 见 `KnowledgeIndexSegment.emptyBases`。这个字段**零消费者**（全仓核过）,
        /// 留着是给 UI 的"这个根还空着"标记预留位置。
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
        // ---- 时间线段（P18）----
        // 放在**最末**：它是这批里唯一"每轮都可能变"的段（一轮结束就多一行）。
        // 压在中间会把后面所有内容一起推离稳定前缀，缓存一个都命中不了。
        // 与索引段同一档待遇：装不下就**整段缺席**并留 `timelineSkipped`，不参与 priority 降级
        //（它是地图，不是"可丢的条目"—— 局部地图比没有地图更坏）。
        if let seg = timelineRecentSegment(), !seg.isEmpty {
            if seg.count <= budget {
                blocks.append(seg)
                out.timelineText = seg
                out.timelineChars = seg.count
                budget -= seg.count
            } else {
                out.timelineSkipped = true
            }
        }
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
        //    ①块内(搜 `[笔记] <目录名>`, 字面量读 `KnowledgeBaseScan.token`) 或 ②缺席点名单 之一
        //    —— 缺席是正当的(预算不够),
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

    /// 会话材料: 只取 text 消息（**工具卡 / 思考 / 计划卡一律不进**），前面缀上角色。
    ///
    /// 为什么做成纯函数而不是内联在调用点: 这是"什么叫一段会话材料"的**唯一真源** ——
    /// 记忆提炼（P3.7）与 dream 摘要（P15.6）都要它。两处各写一遍的失效模式是
    /// **其中一处悄悄把工具输出也编了进去**, 而那种材料喂给模型不会报任何错,
    /// 只会让它提炼/提案出垃圾 —— 零红灯的错。
    ///
    /// 过滤的判据看的是 `MessageContent` 的 case, 不是字符串特征 ——
    /// 结构上就不可能混进 `ToolCall`（P15.6 之前, dream 是让模型自己去读 jsonl,
    /// 那里工具输出与人的话混在同一个文件里, 只能靠模型自觉跳）。
    static func sessionMaterial(from messages: [ChatMessage]) -> [String] {
        messages.compactMap { msg -> String? in
            guard case .text(let s) = msg.content, !s.isEmpty else { return nil }
            return "\(materialLabel(for: msg.role)): \(s)"
        }
    }

    /// 材料里的**作者标记** —— 三种角色各有各的字。
    ///
    /// ⚠️ **别写成二值** `role == .user ? "用户" : "助手"`（P17 之前就是那样）：
    /// `MessageRole` 有**三**个 case（`MessageModels.swift:7-9`），二值等于把第三类
    /// **静默并进「助手」** —— dream 会据此把「系统的话」当成「模型自己的话」去提炼，**零红灯**。
    /// boss 2026-10-15 定的口径：**「system 就是 system，别划到助手」**。
    ///
    /// ⚠️ 这一支**当前走不到，但将来会**：全仓没有 `.system` 的生产者（构造 `ChatMessage`
    /// 的 9 处全传 `.user` / `.assistant`），本机库 `events` 也是 `system = 0`。加它是因为
    /// pi 的 system / developer 事件一旦被映射进来、或某个 hook 往会话里插一条系统提示，
    /// 那时这里是**唯一**能拦住「静默误标」的地方。
    ///
    /// 用**穷举 `switch`** 而不是 `default` —— 将来给 `MessageRole` 加第四个 case 时这里
    /// **编译不过**，而不是悄悄把它算成某一类（同 `proposalKindLabel` / `proposalKindColor`
    /// 那两个穷举 switch 的判据）。
    ///
    /// ⚠️ 这三个词是**进 prompt 的契约 token**，恒中文、不进词表（同 `KnowledgeKind.tag`）。
    static func materialLabel(for role: MessageRole) -> String {
        switch role {
        case .user: return "用户"
        case .assistant: return "助手"
        case .system: return "系统"
        }
    }

    /// 把会话材料**按回合切开** —— 一条 `用户:` 行 + 它之后到下一个 `用户:` 之前的所有行 = 一个回合。
    ///
    /// ⚠️ `助手:` 与 `系统:` 行都跟着**它们前面那个回合**走（判据只认 `用户: ` 开头的行）；
    /// 若 `系统:` 出现在**最前面**，它会自成一段（`turns.isEmpty` 那一支）。
    /// 当前库里不会出现这种情况 —— 四场会话的 `seq=1` 全是 `.user`（system prompt 由 pi 侧
    /// 每轮动态拼，不进会话记录）。
    ///
    /// 为什么需要它（P17）: dream 的单会话裁剪原来是 `String.suffix(budget)`, 那个切法有两个病 ——
    /// ① 一场正常会话必超预算 ⇒ **开头的用户提问整段消失**; ② 切点落在字符串中间, 留下的第一行
    /// 从**半句话**说起。喂进去的是"没有提问的回答", 模型会把那些回答当成凭空冒出的结论。
    ///
    /// 判据读的是行的**前缀** `用户: ` —— 那不是"认字符串特征", 而是认 `sessionMaterial` 自己的
    /// 输出格式（前缀由它定义, 这里是同一份材料的**下游**）。
    static func materialTurns(_ lines: [String]) -> [[String]] {
        var turns: [[String]] = []
        for line in lines {
            if line.hasPrefix("用户: ") || turns.isEmpty {
                turns.append([line])
            } else {
                turns[turns.count - 1].append(line)
            }
        }
        return turns
    }

    /// 按回合裁剪: 超预算时**从最旧的回合整对丢**, 并在开头标注丢了几个。
    ///
    /// 与 `suffix` 的方向一致（都是"留最新的"）, 但保证每一段都是**完整的**「用户: … / 助手: …」。
    /// 循环里重算长度而不是先扣一个估数: 标注那行自己的位数会随丢掉的个数变
    /// （同 `sessionDigest` 里那个"段头也占字符"的判据）。
    ///
    /// 至少留**最后一个回合**（`kept.count > 1`）—— 单回合本身就超预算时宁可超一点,
    /// 也不能交出一段空材料（那会让"这场会话有料"变成"这场会话没有可提炼的东西"）。
    static func trimMaterialByTurns(_ lines: [String], budget: Int) -> String {
        let all = materialTurns(lines)
        let total = all.count
        var kept = all
        func render() -> String {
            let dropped = total - kept.count
            let head = dropped > 0 ? "…(更早的 \(dropped) 个回合已省略)\n" : ""
            return head + kept.map { $0.joined(separator: "\n") }.joined(separator: "\n")
        }
        while kept.count > 1, render().count > budget { kept.removeFirst() }
        return render()
    }

    /// dream 的**笔记正文段** —— 目录之外的"内容本身"（P17）。
    ///
    /// 为什么值得单开一段（而不是让模型自己 `read`）: 目录只有一行一篇, 模型拿它去判"这两篇讲的
    /// 是不是同一件事"必须先 read 一遍 —— 每条提案之前都要往返一次。把正文直接给它, 省掉的是
    /// **几十次 read 的往返**, 而 dream 一个月才跑 30 次 ⇒ 这点预算换得起。
    ///
    /// ⚠️ **常驻的 `[笔记]` 段一个字都不动**: 它每轮对话都在（与 `knowledgeTotalCharLimit` 同一本账）,
    /// 为 dream 放开预算时若连它一起抬, 多花钱的是**每一轮普通对话**。这一段的唯一消费者是
    /// `SchedulerService.buildDreamNotes`。
    ///
    /// 超预算 ⇒ 从**最旧的**（mtime）丢并在段尾点名 —— 退回到"地图 + 自己 read", 而不是悄悄丢一半。
    func noteBodySegment() -> KnowledgeBaseScan.NoteBodySegment {
        var inputs: [KnowledgeBaseScan.NoteBodyInput] = []
        for (base, docs) in knowledgeBaseScan() where base.enabled {
            for d in docs {
                guard let text = readNote(rootId: base.id, relativePath: d.relativePath) else { continue }
                inputs.append(.init(label: base.displayName, path: d.relativePath,
                                    modifiedAt: d.modifiedAt, content: text))
            }
        }
        return KnowledgeBaseScan.noteBodyBlock(inputs, budget: Tune.dreamNoteBodyChars)
    }

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
        var texts = Self.sessionMaterial(from: store.replayMessages(for: sid))
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

    /// 笔记根的**生产形状**（不看测试重定向）—— 跨项目 = `~/.mangox/note/`; 项目内 = `<项目>/.mangox/note/`。
    ///
    /// 与 `productionL1Dir` 拆开的**同一个理由**: 断言查政策、读写走解析 —— 混在一起守卫就变自证。
    /// 它与 L1 是**两个平行目录**（`note/` 与 `agent/`）, 刻意不嵌套 —— 嵌套会让"哪些是笔记、
    /// 哪些是 App 管的按需知识"变成靠路径猜。
    static func productionNoteDir(projectPath: String?) -> String {
        guard let p = projectPath, !p.isEmpty else { return NSHomeDirectory() + "/.mangox/note" }
        return p + "/.mangox/note"
    }

    /// **进程级**重定向笔记根（冒烟）—— 与 `agentRootOverride` 同一个理由: 生产调用点
    /// (`ChatStore` / `KnowledgeView`) 都不传参数, 靠"每个 helper 记得设实例 override"已经漏过一次
    /// (2026-09-22 把夹具写进了用户真实 L1 目录)。**漏一次就是数据污染, 而且没有任何红灯。**
    static var noteRootOverride: String?

    /// 实际落点 = 生产形状 + 测试重定向。两种作用域都跟着重定向走（项目内落点也在用户项目里）。
    static func noteDir(projectPath: String?) -> String {
        guard let root = noteRootOverride else { return productionNoteDir(projectPath: projectPath) }
        guard let p = projectPath, !p.isEmpty else { return root + "/global" }
        return root + "/proj-" + (p as NSString).lastPathComponent
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

    /// 实例侧笔记根重定向（优先级高于静态 `KnowledgeStore.noteRootOverride`）。
    /// 与 `l1RootOverride` 同形: 单个用例想把两种作用域分桶到不同子目录时用。
    var noteRootOverride: String?

    /// 笔记根落点（含测试重定向）。分桶规则与 `resolvedL1Dir` **逐字相同** ——
    /// 两处若各写一套, "全局 vs 项目"的分桶迟早会在其中一边失效。
    func resolvedNoteDir(projectPath: String?) -> String {
        guard let root = noteRootOverride else { return Self.noteDir(projectPath: projectPath) }
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

    // MARK: - P15.3 dream 提案（只读面）

    /// dream 提交的提案快照（`note_proposals` 表）。
    ///
    /// 为什么是"快照 + 显式 reload"而不是每次读库: 它是**低频写、低频读**的
    /// （一次 dream 出一批, 人点开笔记区才看）⇒ 现算完全够; 而做成计算属性会让 SwiftUI
    /// 每次重绘都打一次库。收口处（`SchedulerService.finishDreamFireIfNeeded`）负责 reload。
    ///
    /// ⚠️ P15.3 **只读**: 采纳 / 丢弃两个终态属 P15.4 —— 那时才会出现"写盘"这条路径,
    /// 而它正是 T5（dream 不改输入）在 P15.3 能**结构性成立**的原因, 不是靠纪律。
    /// P15.4 起可写, 但**写只发生在 `adoptProposal` / `discardProposal` 两个入口**,
    /// 且前者是"人拍了板"之后才走得到的 —— 结构性成立的边界只是往后挪了一道门, 没有拆掉。
    @Published private(set) var noteProposals: [NoteProposal] = []

    /// 从库里重读提案。**没有缓存失效逻辑** —— 因为它没有缓存（见上）。
    func reloadProposals() {
        noteProposals = (try? store?.persistence?.loadNoteProposals()) ?? []
    }

    // MARK: - P15.2 人写笔记（本仓库唯一会改**用户磁盘内容**的路径）

    /// 编辑面要的三样东西: 正文 / 标题 / 打开时的指纹。
    ///
    /// `body` 的定义必须与 `saveNote` 写回的那一段**同源** —— 打开看到 A 段、保存写回 B 段,
    /// 是那种"改一次掉一段"的 bug, 而且第二次打开才发现。
    struct NoteDraft: Equatable {
        /// `.md` 才有标题（frontmatter 是 markdown 的东西）; 其余格式恒为空串。
        let title: String
        /// `.md` = frontmatter 之后的部分; 其余格式 = 整篇。
        let body: String
        /// 打开时那一版的 sha256 —— 保存时带回来比对。
        let hash: String
        /// 打开时磁盘上的**整篇原文**（编辑面拿它算"改了没有", 也拿它当 frontmatter 的真源）。
        let raw: String
        /// 标题能不能改。`false` ⇒ 编辑面把标题显示成只读的文件名, 也不写任何 frontmatter。
        let titleEditable: Bool
    }

    /// 笔记根落点 —— **写盘必须走它**。
    ///
    /// 走 `allKnowledgeBases` ⇒ 路径来自 `resolvedNoteDir` ⇒ 冒烟的进程级重定向自动生效（守卫 23）。
    /// 绕过它（比如从 UI 传来的 `base.path` 直接拼）就会写进用户真实的 `~/.mangox/note/`,
    /// 而且**没有任何红灯** —— `agentRootOverride` 那次实测就是这么漏过一回的。
    private func noteRootPath(_ rootId: String) -> String? {
        allKnowledgeBases.first { $0.id == rootId }?.path
    }

    /// 相对路径 → 绝对路径。**出根一律拒**（`..` / 绝对路径 / `~` / 空）。
    ///
    /// 这不是防御性代码: 相对路径来自 UI, 而 UI 的值来自磁盘扫描 —— 中间隔着一段用户可以手改的
    /// 状态。「写盘前重新验一次边界」是"App 只会改笔记根里的东西"这句话唯一能兑现的方式。
    func noteAbsPath(rootId: String, relativePath: String) -> String? {
        guard let root = noteRootPath(rootId) else { return nil }
        let rel = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.hasPrefix("~") else { return nil }
        guard !rel.split(separator: "/").contains("..") else { return nil }
        let abs = ((root + "/" + rel) as NSString).standardizingPath
        guard abs.hasPrefix(root + "/") else { return nil }
        return abs
    }

    // MARK: - P18 时间线（App 侧自动记账 —— 本仓第三段会改用户磁盘的路径）

    /// 把一行流水写进当月的 `timeline/YYYY-MM.md`。
    ///
    /// ⚠️ **这是第三段会改用户磁盘的路径**（前两段：人写笔记 `saveNote` / 采纳提案
    /// `adoptProposal`）。它与那两段是**分工**，不是绕过：
    ///   · 那两段写的是**结论**，必须经人拍板（P15 门 2）；
    ///   · 这一段写的是**客观发生过的事**（几点、哪一场、几轮、几次失败），模型不参与
    ///     ⇒ 它不会编 ⇒ 也就不该再给 boss 造一个"审流水"的队列。
    /// 它只写 `timeline/` 一个子目录，且**永远不推翻已有内容**（只 upsert 自己那一行）。
    ///
    /// 落点必须走 `noteAbsPath`（越界一律拒）—— 同 `saveNote`：绕过校验 = 可能写进用户
    /// 任意目录，而且**零红灯**（守卫 24/25 那两回实测）。
    @discardableResult
    func appendTimeline(rootId: String, row: TimelineDoc.Row) -> Bool {
        let rel = TimelineDoc.relativePath(for: row.day)
        guard let abs = noteAbsPath(rootId: rootId, relativePath: rel) else { return false }
        let label = knowledgeBase(id: rootId)?.displayName ?? rootId
        let existing = (try? String(contentsOfFile: abs, encoding: .utf8)) ?? ""
        let next: String
        if existing.isEmpty {
            // 目录可能还不存在（这个根刚建 / 第一次记账）—— 就地建，与 `createNote` 同口径。
            try? FileManager.default.createDirectory(
                atPath: (abs as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            next = TimelineDoc.newDocument(
                monthHeading: TimelineDoc.monthHeading(for: row.day, rootLabel: label), row: row)
        } else {
            next = TimelineDoc.upsert(existing, row: row)
        }
        // 一个字节都没变就不写：重写只会改 mtime，而 mtime 正是"陈旧度"的唯一依据。
        guard next != existing else { return true }
        guard (try? next.write(toFile: abs, atomically: true, encoding: .utf8)) != nil else { return false }
        // ⚠️ **重算注入块快照** —— 不重算这个功能等于没接上。
        // `currentKnowledgeBlock` 是**快照**，只在「知识变动 / 启动」时刷新；而流水是
        // "一轮结束写一行"，**没有任何别的知识变动会顺带把它带进 prompt**。
        // 漏了的症状是"时间线文件天天在长，而 agent 永远看不见它"，且零红灯
        //（文件在、断言全绿、只是没进 prompt —— 与 P11 要根除的那类隐形缺陷同形）。
        refreshInjectionOnly()
        return true
    }

    /// 只重建注入块快照（并推给在途实例），**不做 L1 对账**。
    ///
    /// 与 `applyKnowledgeChange` 的差别只有一条：不动 L1 目录。用于**只改笔记区**的写入
    ///（P18 时间线）—— 那些写入不产生 L1 文件，而 L1 对账是整目录读写，陪跑一次不便宜。
    private func refreshInjectionOnly() {
        let injection = buildInjection()
        lastInjection = injection
        currentKnowledgeBlock = injection.text
        store?.pushKnowledgeContext(currentKnowledgeBlock)
    }

    /// 注入用的「最近流水」段（P18）。
    ///
    /// 只读**当月 + 上月**两个文件：`timelineRecentDays = 7` 最多跨一个月界，多读的是白付
    /// （而这一段每轮对话都在）。更早的流水仍在磁盘上，agent 按路径 read。
    ///
    /// ⚠️ 停用的根**不读**（`enabled`）—— 停用是对模型说的"别看这里"，而注入段是给模型看的，
    /// 与"记账还记不记"是两件事（记账照记，见 `appendTimeline` 不判 enabled）。
    func timelineRecentSegment(now: Date = .now) -> String? {
        let cal = Calendar.current
        let lastMonth = cal.date(byAdding: .month, value: -1, to: now) ?? now
        let paths = [TimelineDoc.relativePath(for: now, calendar: cal),
                     TimelineDoc.relativePath(for: lastMonth, calendar: cal)]
        var docs: [String] = []
        for base in allKnowledgeBases where base.enabled {
            for rel in paths {
                if let t = readNote(rootId: base.id, relativePath: rel) { docs.append(t) }
            }
        }
        guard !docs.isEmpty else { return nil }
        let seg = TimelineDoc.recentSegment(docs, now: now,
                                            days: Tune.timelineRecentDays,
                                            rowsPerDay: Tune.timelineInjectRowsPerDay,
                                            charLimit: Tune.timelineInjectChars)
        return seg.isEmpty ? nil : seg
    }

    /// 内容指纹 —— 整篇的 sha256 hex。与 `ModelMaterializer` 那条指纹同一种写法:
    /// 同一件事（"这份字节是不是那一份"）不该有两种指纹。
    static func noteHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 读一篇笔记的整篇原文（`nil` = 越界或读不到）。
    func readNote(rootId: String, relativePath: String) -> String? {
        guard let abs = noteAbsPath(rootId: rootId, relativePath: relativePath) else { return nil }
        return try? String(contentsOfFile: abs, encoding: .utf8)
    }

    func noteDraft(rootId: String, relativePath: String) -> NoteDraft? {
        guard let content = readNote(rootId: rootId, relativePath: relativePath) else { return nil }
        let isMD = relativePath.lowercased().hasSuffix(".md")
        return NoteDraft(
            title: isMD ? KnowledgeBaseScan.parseHead(content, fileName: relativePath).title : "",
            body: isMD ? KnowledgeBaseScan.splitFrontmatter(content).body : content,
            hash: Self.noteHash(content),
            raw: content,
            titleEditable: isMD)
    }

    /// (标题, 正文) → 整篇。`title = nil` ⇒ 这篇不支持标题 ⇒ 不碰 frontmatter。
    ///
    /// **编辑面与写盘共用这一个函数** —— 各写一份的话, "按钮说没变、写下去却变了"（或反过来）
    /// 就是那种只有手点才会发现的 bug。
    func composeNoteEdit(current: String, title: String?, body: String) -> String {
        guard let title else { return body }
        return KnowledgeBaseScan.composeNote(
            meta: KnowledgeBaseScan.splitFrontmatter(current).meta, title: title, body: body)
    }

    /// 新建一篇笔记。成功返回**根内相对路径**（调用方拿它选中新那篇）。
    ///
    /// **标题就是文件名**（净化后）, 新文件**不写** frontmatter `title:` —— 它与文件名相同 ⇒
    /// 索引行按 P15.1 的判据"标题 == 文件名去扩展名 ⇒ 一格都不补"**天然零冗余**。
    /// 用户后来把标题改成跟文件名不同, 那时才落下 `title:`（`saveNote` 负责）。
    ///
    /// P15.4: `body` / `origin` 是为**采纳 dream 的 insight 提案**开的 —— 那条路走的是
    /// "标题由模型给、正文当场就有", 而 UI 的新建表单走缺省（空正文、`.human`）。
    /// 两条路共用一个函数而不是各写一份: 撞名判定、边界校验、就地建目录这三件事
    /// 在两边是同一件事, 分头实现迟早分头长歪。
    func createNote(rootId: String, title: String, body: String = "",
                    origin: NoteRevisionOrigin = .human) -> Result<String, NoteWriteRejection> {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.emptyTitle) }
        guard t.count <= KnowledgeBaseScan.noteTitleLimit else {
            return .failure(.titleTooLong(limit: KnowledgeBaseScan.noteTitleLimit))
        }
        guard let root = noteRootPath(rootId),
              let stem = KnowledgeBaseScan.noteFileName(from: t) else { return .failure(.emptyTitle) }
        let rel = stem + ".md"
        guard let abs = noteAbsPath(rootId: rootId, relativePath: rel) else {
            return .failure(.pathEscapesRoot)
        }
        let fm = FileManager.default
        // 撞名不猜 —— "覆盖还是改名"是个产品决策, 而它没有明显正确答案 ⇒ 让用户换一个。
        if fm.fileExists(atPath: abs) { return .failure(.nameCollision(existing: rel)) }
        // 目录不存在⇒**就地建**（门 1: 藏起来的入口 = 没有入口; 根不在时点"新建"必须能成）。
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        guard (try? body.write(toFile: abs, atomically: true, encoding: .utf8)) != nil else {
            return .failure(.writeFailed)
        }
        // 写下的这一版立刻进版本史 —— **空正文那一版也记**（"新建了但一个字没写"同样是一个
        // 存在过的版本, 而且它让"删掉之后还能回放到刚建时"成立）。见 `recordNoteRevision`。
        recordNoteRevision(rootId: rootId, relativePath: rel, content: body, origin: origin)
        applyKnowledgeChange()
        return .success(rel)
    }

    /// 保存一篇笔记。`title = nil` ⇒ 这篇不支持标题（非 `.md`）⇒ 整篇都是正文, 不碰 frontmatter。
    ///
    /// 顺序 = **先验后写**, 每一步失败都在落盘之前返回:
    /// ① 边界 → ② 还在不在 → ③ 指纹（乐观并发）→ ④ 内容真的变了吗
    /// → ⑤ 补记没记过的当前版 → ⑥ 原子写 → ⑦ 记下刚写的这一版。
    /// ⚠️ ③ 必须排在 ④ **之前**: "外部改过"比"你没改"严重得多（一个是丢数据, 一个是白跑一趟）,
    /// 提示也完全不同 —— 顺序反了, 外部改动会被 `next == current` 那一步静默吞掉。
    ///
    /// P15.4: `origin` = **本次写入者**（人 = `.human` · 采纳 dream 提案 = `.dream`）,
    /// 记在 ⑦ 那一版上; ⑤ 补记的那一版恒记 `.human`（见 `recordIfUnrecorded` 里的推论）。
    func saveNote(rootId: String, relativePath: String, title: String?, body: String,
                  baseHash: String, origin: NoteRevisionOrigin = .human) -> NoteWriteRejection? {
        guard let abs = noteAbsPath(rootId: rootId, relativePath: relativePath) else {
            return .pathEscapesRoot
        }
        guard let current = try? String(contentsOfFile: abs, encoding: .utf8) else {
            return .noteMissing
        }
        guard Self.noteHash(current) == baseHash else { return .baseHashMismatch }
        let next = composeNoteEdit(current: current, title: title, body: body)
        // ④ 内容没变 ⇒ 不写（不磨 mtime, 备份/同步工具会因此反复嘬盘）**也不记** ——
        //    记了就成"每点一次保存就多一条历史"。
        guard next != current else { return nil }
        // ⑤ 补记"我们没记过的当前版"。漏了这一步, 外部改动会在**这一次**覆盖时静默消失
        //    （P15.2 T4 那条反例守的就是它, P15.4 换了记账时机之后必须在这里补上）。
        recordIfUnrecorded(rootId: rootId, relativePath: relativePath, content: current)
        guard (try? next.write(toFile: abs, atomically: true, encoding: .utf8)) != nil else {
            return .writeFailed
        }
        // ⑦ 写下的这一版进版本史。⚠️ 次序不可倒 —— 记在写盘**之后**, 写失败就不该留痕。
        recordNoteRevision(rootId: rootId, relativePath: relativePath, content: next, origin: origin)
        applyKnowledgeChange()
        return nil
    }

    /// 删除一篇笔记。**两道退路都留**: ① 内容进 `note_revisions` ② 文件进系统「废纸篓」。
    ///
    /// 为什么不用 `removeItem`: 删除是本功能里**唯一不可逆**的动作, 而 `trashItem` 是 macOS
    /// 自带的撤销通道 —— 代价为零, 换回的是"删错了还能捞回来"。回收站里那份不在笔记根里,
    /// 下一轮扫描看不到它 ⇒ 不影响索引。
    func deleteNote(rootId: String, relativePath: String) -> NoteWriteRejection? {
        guard let abs = noteAbsPath(rootId: rootId, relativePath: relativePath) else {
            return .pathEscapesRoot
        }
        guard let current = try? String(contentsOfFile: abs, encoding: .utf8) else {
            return .noteMissing
        }
        // 留档记的 origin 是**这一版的作者**, 不是"删除者" —— 删掉的是谁写的东西, 它就归谁。
        // `sources` 同源: 删掉的是**dream 凭什么写下的那一版**, 那份理由也就跟着那一版走。
        // 两者都靠 `sha256` 从历史里**反解**（正文自己不知道自己从哪来）, 所以这里取一次历史、
        // 让两个纯函数各认领一次 —— 分头取库迟早会读到两份不一样的历史。
        let history = noteRevisions(rootId: rootId, relativePath: relativePath)
        recordNoteRevision(rootId: rootId, relativePath: relativePath, content: current,
                           origin: Self.origin(ofContent: current, in: history),
                           sources: Self.sources(ofContent: current, in: history))
        let fm = FileManager.default
        do {
            if Self.noteDeleteUsesTrash {
                var resulting: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: abs), resultingItemURL: &resulting)
            } else {
                try fm.removeItem(atPath: abs)
            }
        } catch { return .writeFailed }
        applyKnowledgeChange()
        return nil
    }

    /// **生产政策**: 删除送「废纸篓」。它是只读的政策常量 —— 与下面那个可变开关拆开,
    /// 断言的必须是**政策**, 不是"冒烟期为了不污染用户目录临时改成了什么"
    /// （同 `productionL1Dir` / `l1Dir` 的拆法: 混在一起, 守卫就变成自证）。
    static let productionNoteDeleteUsesTrash = true

    /// 执行侧开关。**冒烟把它翻成 `false`**: 一次冒烟会往用户真实的 `~/.Trash` 里丢几十个夹具,
    /// 那是**污染用户目录** —— 与 `agentRootOverride` / `attachmentsRootOverride` 要避免的是同一类事
    /// （只不过那个是"写进用户的目录", 这个是"把东西丢进用户的回收站"）。
    static var noteDeleteUsesTrash = productionNoteDeleteUsesTrash

    /// 记下一个**曾在磁盘上存在过的版本**。
    ///
    /// ⚠️ **语义在 P15.4 变了, 这是有意的一次改写**: P15.2 是"覆盖前留旧版",
    /// 现在是"**每写下一版就记一条**"。原因是判「当前版是谁写的」需要**当前版也在表里**,
    /// 而旧语义下它永远不在 —— 最后写下的那一版**没有任何一条记录指向它**
    /// （`note_revisions` 里全是"上一版"）。改完语义, 当前版 = 能被 `sha256` 命中的那一条。
    ///
    /// 为什么不是"照旧记旧版 + 额外补一条当前版": 那样同一份内容会被记两次
    /// （一次作为刚写下的新版、一次作为下次的旧版）⇒ 历史表凭空翻倍, 而信息量没多。
    /// 两种语义下**每一次成功写入都恰好产生一条记录**, 变的只是它记的是"写下的"还是"被顶掉的"。
    ///
    /// - Important: 只增不改不删。它的语义就是"这一版曾经存在过"。
    /// - Parameter sources: **这一版从哪来**（P17）。只有 `adoptProposal` 会传非空 ——
    ///   另外两个调用点（人写 / 补记外部改动）给的就是「没有来源」, 那是事实, 不是省事的默认值。
    private func recordNoteRevision(rootId: String, relativePath: String,
                                    content: String, origin: NoteRevisionOrigin = .human,
                                    sources: [ProposalSource] = []) {
        let rev = NoteRevision(id: UUID(), rootId: rootId, path: relativePath, content: content,
                               sha256: Self.noteHash(content), writtenAt: .now, origin: origin,
                               sources: sources)
        try? store?.persistence?.appendNoteRevision(rev)
    }

    /// 这一版**我们记过吗**? 没记过就先补上。**恒记 `.human`**。
    ///
    /// 记 `.human` 不是偷懒, 是一条**结构性推论**: 写盘路径只有两条 —— 人的编辑面
    /// 与采纳 dream 提案, 而后者**必经 App**（`adoptProposal` 一定会留下记录）。
    /// 所以走到"没记过"这条分支上的内容, 只可能是 ① 用户在外部编辑器改的 ② P15.4 之前的老库。
    /// 两者都该归"你写的"（§04 那条「凡不在记录里的就归『你写的』」）。
    ///
    /// 不补的代价: 这一版会在下一次覆盖时**静默消失**（它既不是"刚写下的", 也没赶上"被顶掉"）。
    private func recordIfUnrecorded(rootId: String, relativePath: String, content: String) {
        // `noteRevisionExists` **不 throws**（它自己把查询失败吞成 false）⇒ 这里不写 `try?`
        // （写了会得到一条 "no calls to throwing functions occur within 'try' expression" 的警告）。
        let recorded = store?.persistence?.noteRevisionExists(
            rootId: rootId, path: relativePath, sha256: Self.noteHash(content)) ?? false
        guard !recorded else { return }
        recordNoteRevision(rootId: rootId, relativePath: relativePath, content: content, origin: .human)
    }

    /// **磁盘上这一版是谁写的**。判据 = 内容同一性, 不是"最新一条的 origin"。
    ///
    /// ⚠️ 为什么不能用"最新一条": 最后写下的那一版有可能**根本不在记录里**
    /// （外部改过 / 老库）—— 那时"最新一条"说的是**上一次**的作者, 恰好答错。
    /// 拿 `sha256` 去认领则不会: 认到就是精确的, 认不到才回落。
    ///
    /// 回落值 `.human` 与 `recordIfUnrecorded` 的推论同源（见那里）。
    /// 纯函数（只吃 `[NoteRevision]` + 字符串, 不碰磁盘/DB）⇒ 冒烟能直接造反例。
    static func origin(ofContent content: String, in revisions: [NoteRevision]) -> NoteRevisionOrigin {
        let sha = noteHash(content)
        return revisions.first { $0.sha256 == sha }?.origin ?? .human
    }

    /// `origin(ofContent:in:)` 的**兄弟** —— 这一版从哪来（P17）。
    ///
    /// 判据与它**逐字同源**（内容同一性, 不是「最新一条」）: 最后一版有可能根本不在记录里,
    /// 那时「最新一条」说的是**上一版**的来源, 恰好答错。
    ///
    /// 回落 `[]` = 没有来源记录。那不是「缺」而是「空」—— 人写的版本本来就没有指针,
    /// 而「空」比「编一个出来」诚实（同提案那边「拿不出指针的不入表」的口径）。
    static func sources(ofContent content: String, in revisions: [NoteRevision]) -> [ProposalSource] {
        let sha = noteHash(content)
        return revisions.first { $0.sha256 == sha }?.sources ?? []
    }

    /// 读一篇笔记的完整版本史（新 → 旧）。
    ///
    /// **唯一取数口** —— 判来源（`origin(ofContent:in:)` 的调用点）与界面画变更史都走它。
    /// `PersistenceStore.loadNoteRevisions` 才是实现, 但调用点不该各自去摸 `store?.persistence`:
    /// 那一层是双层可选链, 摸漏一处就是"界面永远空列表、而门禁全绿"。
    func noteRevisions(rootId: String, relativePath: String) -> [NoteRevision] {
        (try? store?.persistence?.loadNoteRevisions(rootId: rootId, path: relativePath)) ?? []
    }

    // MARK: - P15.4 拍板（采纳 / 丢弃）

    /// 采纳一条提案 = **本仓库第二段会改用户磁盘的路径**（第一段是 P15.2 的人写笔记）。
    ///
    /// 三个 kind 走**同一条落盘形态**: 把 `p.content` 整篇原子写进 `p.targetPath`。
    /// 这不是偷懒 —— `content` 的契约就是"**整篇新文本, 不是 diff**"
    /// （见 `mangox-dream.ts` 里 `note_proposal` 的工具描述与 `NoteProposalDraft.content`）,
    /// 因为 dream 的产出粒度是「整篇重写」或「新增一篇」, 它**做不了逐行手术**（P15 §03 提炼 ⑤）。
    /// 所以采纳没有"合并进现有正文"这种中间态 —— 要么整篇写下去, 要么不写。
    ///
    /// 三个 kind 的区别只剩"目标该不该已经存在":
    /// - `insight` ⇒ 目标应当**不存在**。若它现在存在了, 说明期间有人在外部建了同名文件
    ///   ⇒ **不覆盖**（`nameCollision`）—— "覆盖还是改名"是个产品决策, 与 `createNote` 同一口径。
    /// - `merge` / `replace` / `delete` ⇒ 目标必须存在, 且**指纹要对得上**（乐观并发, 同 `saveNote` ③）。
    ///   对不上 = 模型读完之后磁盘又变过 ⇒ 那是拿旧判断覆盖新内容, 正是要拦的事。
    ///
    /// - Note: 落盘成功后顺手做两件事: ① 记下 `.dream` 那一版（**来源标记靠它认领** —— 不记,
    ///   这篇笔记会永远被算成"你写的"）② **把提案行删掉**（P15.8/5f: 产出已经变成笔记区里
    ///   的一篇, 提案行是冗余 ⇒ 收件箱不该留着它）。
    @discardableResult
    func adoptProposal(_ p: NoteProposal) -> NoteWriteRejection? {
        guard let abs = noteAbsPath(rootId: p.rootId, relativePath: p.targetPath) else {
            return .pathEscapesRoot
        }
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: abs)
        // `delete` 的产出不是"写一份新内容", 而是"把这一篇移进废纸篓" ⇒ 它有自己的出口。
        // 两道闸门与 merge / replace **完全同款**（目标存在 + 指纹对得上）—— 删掉一个已经变过的
        // 东西正是要拦的事; 于是它紧挨着那个 else 放, 让"这两支比的是同一件事"看得见。
        if p.kind == .delete {
            guard exists, let current = try? String(contentsOfFile: abs, encoding: .utf8) else {
                return .noteMissing
            }
            guard Self.noteHash(current) == p.baseHash else { return .baseHashMismatch }
            // 留旧版 + 送废纸篓都在 `deleteNote` 里（那是本功能唯一不可逆动作的唯一出口）。
            // ⚠️ 它自己会 `applyKnowledgeChange()`, 所以这里直接返回, 不走下面那条公共尾部。
            if let err = deleteNote(rootId: p.rootId, relativePath: p.targetPath) { return err }
            return removeProposal(p)
        }
        if p.kind == .insight {
            guard !exists else { return .nameCollision(existing: p.targetPath) }
        } else {
            guard exists, let current = try? String(contentsOfFile: abs, encoding: .utf8) else {
                return .noteMissing
            }
            guard Self.noteHash(current) == p.baseHash else { return .baseHashMismatch }
            // 磁盘已经是提案要的样子 ⇒ **一个字节都不写**, 但意图已达成 ⇒ 照样删行。
            // 不删的话它会永远挂在"待审"里, 而再点一次还是什么都不做（"点了没反应"那种 bug）。
            if current == p.content { return removeProposal(p) }
            recordIfUnrecorded(rootId: p.rootId, relativePath: p.targetPath, content: current)
        }
        // 目录不存在 ⇒ 就地建（同 `createNote`: 根不在时点采纳必须能成, 不能只报个错）。
        if p.kind == .insight, let root = noteRootPath(p.rootId) {
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
        guard (try? p.content.write(toFile: abs, atomically: true, encoding: .utf8)) != nil else {
            return .writeFailed
        }
        // `sources: p.sources` —— **全仓唯一**带着来源指针落盘的一处。它补的正是 P15.8/5f
        // 「拍过板就删行」留下的那个缺口: 提案行（连同它的 `sources` 列）马上就要被删掉,
        // 来源得**活在版本史里**才查得到。
        recordNoteRevision(rootId: p.rootId, relativePath: p.targetPath,
                           content: p.content, origin: .dream, sources: p.sources)
        applyKnowledgeChange()
        // P18: 流水里补一行 —— 时间线上**唯一带主观内容**的那一行。
        // 内容不是模型现编的: `reason` 是提案里那句「为什么提」，人拍板前看过它，
        // 按下采纳 = 认了这句话。
        //
        // ⚠️ `delete` 那条路**不记**（它在上面的分支里直接返回）: 那一条的产出是
        // "一篇进了废纸篓"，没有新内容可写，而它的痕迹在 `note_revisions` 里查得到。
        // 硬记会让 `采纳「X」` 这个 key 与真正的采纳撞车（同一个标题）。
        if let store {
            let name = p.title.isEmpty ? KnowledgeBaseScan.fileStem(p.targetPath) : p.title
            TimelineJournal.recordAdoption(store: store, rootId: p.rootId,
                                           noteTitle: name, reason: p.reason)
        }
        return removeProposal(p)
    }

    /// 丢弃一条提案 —— **只删这行草稿, 不碰磁盘**。
    ///
    /// 这一条正是 dream 那道阀门的另一半: 提案没被采纳, 磁盘上就一个字节都不会变（T5）。
    ///
    /// ⚠️ **P15.8/5f（2026-10-13 boss 推翻 P15.4）**: 原来是"落 `dismissed` 终态 + 留在列表里降档显示",
    /// boss 的判据是 —— 拍过板的东西**没有任何后续动作**, 留在收件箱里就是噪音
    /// （收件箱只该回答"还剩几件等我拍"）。⇒ 改为**删行**。「终态」这个概念整条取消。
    @discardableResult
    func discardProposal(_ p: NoteProposal) -> NoteWriteRejection? {
        removeProposal(p)
    }

    /// 批量采纳 —— **逐条走同一个 `adoptProposal`**, 不另写一套判据。
    ///
    /// ⚠️ 刻意**不是事务**: 几条提案指向的文件彼此独立（甚至可能分属不同根）, 一条撞上
    /// 「目标被外部改过」不该拖着其余几条一起失败 —— 那会让一次批量操作变成"一个坏苹果
    /// 毁掉一整批", 而人还得重新逐条点一遍。
    ///
    /// ⚠️ 也刻意**不写"先全部校验、再统一写"**: 校验那套判据（指纹 / 名称冲突 / delete 的目标
    /// 必须存在）每个分支都对应一次真实的坏结局, 抄一份就等于养两个真源 —— 抄出来的那份
    /// 迟早与 `adoptProposal` 分叉, 而分叉的表现是"批量采纳放过了单条采纳会拦的东西",
    /// 且**零红灯**（两边各测各的）。
    ///
    /// - Returns: 成功条数 + 每条失败的原因（顺序与入参一致, 供界面点名）。
    @discardableResult
    func adoptProposals(_ list: [NoteProposal])
        -> (adopted: Int, failures: [(proposal: NoteProposal, error: NoteWriteRejection)]) {
        var adopted = 0
        var failures: [(proposal: NoteProposal, error: NoteWriteRejection)] = []
        for p in list {
            if let err = adoptProposal(p) {
                failures.append((p, err))
            } else {
                adopted += 1
            }
        }
        return (adopted, failures)
    }

    /// 批量丢弃 —— **丢弃不碰磁盘**, 所以恒成功; 返回值只为让界面能说"清了几条"。
    @discardableResult
    func discardProposals(_ list: [NoteProposal]) -> Int {
        var n = 0
        for p in list where discardProposal(p) == nil { n += 1 }
        return n
    }

    /// 把一条提案从表里删掉 + 刷新列表。
    ///
    /// 抽出来是因为**两个调用点做的是同一件事**: 丢弃, 以及采纳的每一个成功出口
    /// （正常写盘 / 磁盘已一致）。分头写迟早漏掉其中一个, 而漏掉的那个表现是
    /// "点了没反应, 列表还挂着那条"。
    ///
    /// ⚠️ **只有成功才删**。被拒的（`.nameCollision` / `.baseHashMismatch` / `.noteMissing` /
    /// `.writeFailed`）**一律留在待审** —— 那是 P15.4 那条判据的正面: 人得能重试,
    /// 而"删掉它"等于把一次失败的采纳伪装成一次拍板。
    private func removeProposal(_ p: NoteProposal) -> NoteWriteRejection? {
        do {
            try store?.persistence?.deleteNoteProposal(id: p.id)
        } catch {
            return .writeFailed
        }
        reloadProposals()
        return nil
    }
}
