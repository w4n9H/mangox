//
//  SchedulerService.swift
//  P9.1b: 定时任务域自 ChatStore 抽离 (P3.6 调度 / P3.9 fire / P3.10 等待型 / P4.0.2 会话化)。
//  拆分不动行为: ChatStore 保留同名 facade 转发 (冒烟/视图零改动);
//  服务持有 store 弱引用, 仅经 store 的会话/落库接口回调。
//

import Foundation
import Combine

@MainActor
final class SchedulerService: ObservableObject {

    // P3.6: 本地定时任务 (仅 App 运行期生效, launchd 后置)
    @Published var scheduledTasks: [ScheduledTask] = []
    @Published var showScheduledPanel: Bool = false
    /// P20 P5: 助理团队页（泳道 · 纯展示）。与 `showScheduledPanel` **互斥** ——
    /// 它们是同一件事的两个面（建与改 / 看），同时开着只会在侧栏留下两颗亮着的胶囊。
    ///
    /// ⚠️ 独立开关而不是在 `ScheduledView` 里加一条分段: 团队页是**三栏**（筛选 / 泳道 /
    /// 检查器），定时页是**两栏**（列表 / 编辑器）—— 塞进同一个视图会让那个文件变成
    /// "一个容器 + 两套布局"，而它的职责本来就是"建与改"。
    @Published var showTeamPanel: Bool = false
    /// P17 · 运行可靠性: 睡眠 / 长挂起期间漏跑的任务（由 `refreshMissedFires` 重算）。
    /// 空 = 侧栏那块 UI 整个不出现。
    @Published var missedFires: [MissedFire] = []
    /// 2026-11-23: 还没兑现的 follow-up（`status = pending`，按到点时刻升序）。
    /// 界面只读它（任务卡上那一行"约在 14:30 回看"），写路径在 `ingest` / `fire` / `reload`。
    @Published var followUps: [FollowUp] = []
    private var schedulerTimer: Timer?
    private var lastSchedulerMinute: Int = 0
    /// 上次清理过期快照的**日键**（`yyyy-MM-dd`）。空 = 本进程还没清过 ⇒ 启动后第一次 tick 清一遍。
    private var lastUndoPurgeDay: String = ""
    /// P17: 防 App Nap 的常驻断言。**必须强持有** —— 头文件明说对象一旦被释放断言就自动结束,
    /// 存成局部变量等于没加。`private(set)` 是为了让冒烟能断言"加上了 / 交还了"。
    private(set) var napAssertion: NSObjectProtocol?
    // P15.3: 在途的 dream fire —— 日志会话 -> 这次运行的 spool 文件。
    // 只服务 dream 自己: 它管的是"一批提案的收口", 判据是这一条字典 + `dreamTargets`,
    // 与任何"任务类型"的判据无关。
    private var dreamFires: [UUID: String] = [:]
    /// P19: 在途的助理巡检（logId → 收尾时要用的上下文）。
    /// 为什么要存: 收尾发生在**回合落定之后**，那时采集快照早就出了作用域；而"证据里的编号
    /// 是不是本轮真采到过"这条校验只能在收尾时做（结论才刚生成）。
    private var watchFires: [UUID: WatchFireContext] = [:]
    /// 定向 dream（`由此 Dream`）在途的日志会话 -> 目标会话 id。**只服务两件事**:
    /// ① 收口时发一句「dream 完成: N 条待审」到会话横幅（否则用户在侧栏看着自己那场会话，
    ///    永远不知道后台已经跑完）；② 完成后从字典里清掉，免得下次定时那轮被当成定向。
    private var dreamTargets: [UUID: UUID] = [:]
    /// 2026-10-21 (空回合): 「这个任务的 pin 模型已经不在清单里」这条事实**上次是为哪个 pin 记的**。
    /// 任务 id -> `provider/modelId`。作用只有一个: 断掉的 pin 是**常态**（模型下线后不会自己
    /// 回来）, 每个 cron 点都往日志里写同一行会让那场会话被刷成一片同样的字。
    /// 值变了才再记一笔 ⇒ 改过模型又坏掉时仍然看得见（不会因为"记过"而永久闭嘴）。
    private var modelBlockNoted: [UUID: String] = [:]
    /// 2026-11-23: 「这个任务的档位会削掉扩展工具 ⇒ 调不到 follow_up」这条事实**提过没有**。
    /// 与 `modelBlockNoted` 同一个理由: 每分钟一次的助理会把同一行刷满整场日志。
    private var followUpTrimNoted: Set<UUID> = []
    /// 2026-11-23: 在途的 follow-up 回合 —— 日志会话 -> (spool, 归属任务)。
    ///
    /// 为什么要记: 收口发生在**回合落定之后**（`finishFollowUpIfNeeded`），那时只有 `sid`，
    /// "这份 spool 是哪个任务的"已经查不出来了（对话轮反查得到，fire 轮的新会话还没绑）。
    private var followUpFires: [UUID: (spool: String, taskId: UUID)] = [:]

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) {
        self.store = store
        // 2026-11-23: 启动时把未兑现的约定读进来 —— 任务卡那一行「约在 14:30 回看」不能等到
        // 第一次 ingest 才出现（那时人已经以为这个功能没生效了）。
        reloadFollowUps()
    }

    // MARK: - CRUD (P3.6)

    /// P20 (2026-11-24): 新增 `role` / `parentId` / 两个职责字段 —— 全部带缺省值，老调用点零改动。
    ///
    /// 返回 `false` = **域层拒绝**（`TeamRule.violation`）。为什么是 `Bool` 而不是一个发布出去的
    /// 错误状态: 拒绝理由的属性是"**保存前**就该看见"（P4 的编辑器直接问 `TeamRule` 拿词），
    /// 存完再报只是一句事后通知，而它长在 `@Published` 上就成了一份没有读者的第二真源。
    /// 这里只负责一件事: **库里长不出坏行**。
    @discardableResult
    func addScheduled(name: String, prompt: String, cron: String,
                      projectId: UUID?, continuous: Bool = false,
                      kind: TaskKind = .execute,
                      sources: [WatchSourceSpec] = [],
                      role: TaskRole = .main, parentId: UUID? = nil,
                      description: String = "", descriptionDetail: String = "") -> Bool {
        var t = ScheduledTask(id: UUID(), name: name, prompt: prompt, cron: cron,
                              projectId: projectId, continuous: continuous)
        t.kind = kind
        t.sources = sources
        t.role = role
        t.parentId = parentId
        t.description = description
        t.descriptionDetail = descriptionDetail
        t = normalizedConfig(t)
        // P20: 与 `normalizedConfig` 同一条理由 —— 视图侧只是**可见性**，这里是**能力**。
        // `addScheduled` 是公开写路径（将来的批量导入 / 冒烟 / 飞书指令都会绕过视图）。
        guard TeamRule.violation(t, among: scheduledTasks) == nil else { return false }
        scheduledTasks.append(t)
        try? store?.persistence?.upsertScheduled(t)
        return true
    }

    /// 2026-11-20 boss 定：「模型与模式配置」是 **cron / 助理的必须项**。
    ///
    /// 视图侧已经拦了（没选模型就存不了），这里是**域层兜底** —— 与 `deleteScheduled` /
    /// dream 指令归一同一个理由: `updateScheduled` 是**公开写路径**，将来的批量编辑、
    /// 导入配置、冒烟都会绕过视图。没有这一层，"config == nil 的任务"随时能被造出来，
    /// 而它的行为是"每次跑时看全局"—— 那是 boss 明确不要的（全局会被"选个会话"改掉）。
    ///
    /// ⚠️ 两个例外都写在这一个地方:
    ///   ① **dream 不钉** —— 它是出厂任务，配置历来跟随全局，不替它做决定。
    ///   ② **全局值不完整时不填**（首启、pi 还没上报）—— 宁可留 nil 让视图继续拦，
    ///      也不要造一个 `provider` 为空的配置（那会让 `beginTurn` 下发一个空模型）。
    private func normalizedConfig(_ t: ScheduledTask) -> ScheduledTask {
        guard t.config == nil, !Self.isDreamTask(t),
              t.kind == .execute || t.kind == .assistant,
              let store, !store.currentProvider.isEmpty, !store.currentModelId.isEmpty
        else { return t }
        var out = t
        out.config = SessionConfig(provider: store.currentProvider, modelId: store.currentModelId,
                                   thinkingLevel: store.thinkingLevel.rawValue,
                                   agentMode: store.agentMode.rawValue, askApproval: false)
        return out
    }

    /// 返回 `false` = 域层拒绝（同 `addScheduled`：库里长不出坏行）。
    @discardableResult
    func updateScheduled(_ t: ScheduledTask) -> Bool {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == t.id }) else { return false }
        var t = t
        // P15.6b: dream 的指令是**出厂常量** ⇒ 不接受调用方带来的 prompt, 一律归一成常量。
        // 守卫同样放在**域层**而不是视图（与 `deleteScheduled` 同一条理由）: 视图侧"那一栏只读"
        // 只是可见性, 而 `updateScheduled` 是**公开写路径** —— 将来的批量编辑 / 导入配置都会绕过视图。
        //
        // 归一化**不吞掉任何用户输入**: dream 的指令本来就改不了（P15.6b 拍板 "指令取常量, 不可改"）。
        // 它顺手治好"存量旧行"—— 老库里那份复制粘贴的旧文案, 下一次编辑就对齐到当前常量。真正
        // 兜底的不变式在 fire 侧: `buildScheduledPrompt` **根本不读** `t.prompt`（见 `dreamFirePrompt`）
        // —— 所以即使一行都不编辑, 旧文案也**永远没有效果**; 这里只是别让库里继续留着假副本。
        if Self.isDreamTask(t) { t.prompt = Self.dreamPrompt }
        t = normalizedConfig(t)   // 2026-11-20: cron/助理 必须有确定配置（见该函数）
        // P20: 团队不变量。`among:` 里带着这一行的**旧值**，`TeamRule` 自己按 id 摘掉自己。
        guard TeamRule.violation(t, among: scheduledTasks) == nil else { return false }
        scheduledTasks[idx] = t
        try? store?.persistence?.upsertScheduled(t)
        // 2026-11-20: 日志会话的执行配置归任务 ⇒ 任务一改，那一行跟着改。
        // 这一行是"这场会话的执行配置"的**持久事实**（任务被删掉后那场会话还在，读的就是它），
        // 不跟着任务走就会变成一句过了期的话。注意它**不是** pill 的数据源 —— pill 走
        // `selectConversation` → 任务配置，不经这一行。
        if let logId = t.logSessionId, let cfg = t.config {
            store?.persistence?.saveSessionConfig(id: logId, config: cfg)
        }
        return true
    }

    /// 删除任务; deleteSessions = 连带删除日志会话 (开放问题 12: 默认保留, 用户可选删)。
    ///
    /// ⚠️ **助理是例外: 恒删会话、恒删账本**（P19.2 S15 前置）。会话的语义（注入目标、
    /// 写权限、账本落点）全部由任务定义 —— 任务没了，它只是一条没有身份的普通会话，
    /// 而"助理已死、会话还活着"正是 D3 那个静默退化的中间态。成对删除把**状态本身**消掉：
    /// 留痕是标记异常，成对删除是让异常不存在。⇒ `deleteSessions` 对助理**失去意义**。
    ///
    /// ⚠️ **dream 不可删**（2026-10-12 boss: "要固定死, 不能删除, 只能修改以及开关"）。守卫放在
    /// **这里**而不是视图: 视图那边"不渲染删除按钮"只是**可见性**, 这里才是**能力**。只要还剩一条
    /// 能删它的路径, 用户就永远丢了这条任务 —— 它是 App 自己种下的（`seedDreamTaskIfNeeded` 会让
    /// 它长回来, 但那是"补救", 不是"允许删"）。
    func deleteScheduled(id: UUID, deleteSessions: Bool = false) {
        guard let task = scheduledTasks.first(where: { $0.id == id }), Self.canDelete(task) else { return }
        let sessionIds = task.logSessionId.map { [$0] } ?? []
        let paired = task.isAssistant
        // S12 在这里留过一行痕（"这场会话从此是普通会话"）。成对删除之后那条路径**永不执行**
        // ⇒ 整条删掉，不留 `if`：一个永远不会进来的分支只会给下次改回"可选"留下后门。
        scheduledTasks.removeAll { $0.id == id }
        // 删任务行**连同它的数据**（findings / actions / token 日账），并把执行快照目录带出来。
        // ⚠️ 以前这一句只删一行 `scheduled_tasks` ⇒ 悬空外键 + 收件箱里的「未知任务」。
        var undoDirs: [String] = []
        if let p = store?.persistence, let dirs = try? p.deleteScheduled(id: id) { undoDirs = dirs }
        if paired || deleteSessions {
            // ⚠️ `deleteTranscript: true`（2026-11-18）：**删会话连它的 jsonl 一起删**。
            // 以前这里是默认值 `false` ⇒ 会话行没了、`pi-sessions/<sid>.jsonl` 还躺着，
            // 而它已经谁也认领不到（反查不到会话行 = 永久孤儿）。实测这台机器上攒了 3 个。
            // 走 `deleteConversation` 而不是自己拼路径：删除半径**只有那一处定义**
            // （删会话 / 删项目共用），在这里开第二份就是让它慢慢漂。
            for sid in sessionIds { store?.deleteConversation(sid, deleteTranscript: true) }
        }
        if paired {
            removeAssistantLedger(for: task)
            // 快照目录（`~/.mangox/undo/<findingId>/`）: 人点「回滚」才有意义，而那条 finding
            // 刚被删掉 ⇒ 留着就是永远没人认领的 tar。先把路径取出来再删盘（见 DB 层注释）。
            for d in undoDirs { try? FileManager.default.removeItem(atPath: d) }
        }
        // 2026-11-23: 这个任务的约定跟着一起没了（DB 层同步删）。内存那一份要重读 ——
        // 否则界面还会显示一行"约在 14:30 回看"，而那个任务已经不存在了。
        // P20: 团队连带（**唯一一处**，见 `applyTeamCascade`）。放在这里而不是各个调用点:
        // 删任务有两条入口（用户删 / 将来的批量清理），连带逻辑一旦跟着入口走就必然漏一条。
        applyTeamCascade(task, event: .deleted)
        reloadFollowUps()
    }

    /// 助理的账本**两份都可能存在**：新位置（`.mangox/assistant`）与 S9 之前的旧位置
    /// （`.mangox/tasks`）—— `readHandoff` 在新位置缺失时会回落读旧的。
    /// 所以删除也必须两边都看：只删新位置的话，回落会把旧账本"复活"，
    /// 而用户刚被告知"账本已删除"（**回收判据必须与谁真持有该文件同源**）。
    private func removeAssistantLedger(for task: ScheduledTask) {
        guard task.isAssistant else { return }
        for p in [handoffPath(for: task), legacyHandoffPath(for: task)] {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    /// 会话被删之后，把指向它的 `logSessionId` **清成 nil**（P19.2 S15 前置）。
    ///
    /// 为什么不是"什么都不做": 留一个指向已删会话的 id 就是**悬空指针** —— 而悬空指针
    /// 与"这个助理本来就没有会话"在 `assistantChatTurn` 里长得一模一样（反查失败），
    /// 于是"它为什么不认得我"这件事在界面上没有落点。清成 nil 之后，下一轮 fire 会
    /// `ensureLogSession` 建一场新的：助理失忆一次（**账本是文件，还在**），但状态是显式的。
    ///
    /// ⚠️ **单向**: 这里只清列、不删任务。反向（删任务 ⇒ 删会话）在 `deleteScheduled` 里，
    /// 若两边互相调用就成环 —— 成对删除必须有一侧"不回头"。
    func detachAssistantSession(_ sid: UUID) {
        for i in scheduledTasks.indices
        where scheduledTasks[i].isAssistant && scheduledTasks[i].logSessionId == sid {
            scheduledTasks[i].logSessionId = nil
            try? store?.persistence?.upsertScheduled(scheduledTasks[i])
        }
    }

    func toggleScheduled(id: UUID) {
        guard let task = scheduledTasks.first(where: { $0.id == id }) else { return }
        setEnabled(id, !task.enabled)
    }

    // MARK: - P20 助理团队（2026-11-24）

    /// 开关的**唯一写路径**（`toggleScheduled` 与将来的行内开关都走它）。
    ///
    /// 它比"翻个 bool"多三件事，每件都有单独的失败模式（所以别在视图里再拼一份）：
    ///   ① 人**手动**打开一个 worker ⇒ 清掉 `disabledByParent`（它不再"因 main 而停"，
    ///      否则下次启 main 会把它当成跟随停用的那个再动一次）；
    ///   ② main 的开关要**往下连累**（`applyTeamCascade`）；
    ///   ③ 落库 + 级联都在这一个事务边界里，界面不会看到"开关翻了但 worker 没跟着"。
    @discardableResult
    func setEnabled(_ id: UUID, _ on: Bool) -> Bool {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == id }) else { return false }
        guard scheduledTasks[idx].enabled != on else { return true }
        var t = scheduledTasks[idx]
        t.enabled = on
        if on && t.role == .worker { t.disabledByParent = false }
        scheduledTasks[idx] = t
        try? store?.persistence?.upsertScheduled(t)
        applyTeamCascade(t, event: on ? .enabled : .disabled)
        return true
    }

    /// 连带的三种触发（删 / 停 / 启）。**枚举而不是三个 Bool**：三个布尔有 8 种组合，其中 5 种
    /// 没有意义，而"传错一个"在这里的后果是悄悄改了别人名下的 worker。
    enum TeamEvent {
        case deleted
        case disabled
        case enabled
    }

    /// 团队的**全部连带逻辑**（文档 §04「连带与回收」那张表）。
    ///
    /// ⚠️ 只许写在这一处。散到 `deleteScheduled` / `toggleScheduled` / 将来的行内开关各一份的话，
    /// "改一条漏一条"是必然的 —— 与 `deleteScheduled` 那批连带同族（`removeAssistantLedger`
    /// 之所以要同时看新老两个路径，就是被这种分叉坑过一次）。
    ///
    /// | 触发 | 名下的 worker | 未完成的派活 |
    /// | 删 main | 只停用，不删；`parent_id` 留成悬挂值（画板落进「未归属」） | `cancelled` |
    /// | 停 main | 全部停用，并打上 `disabledByParent` | 保持 `queued`（到期顺延） |
    /// | 启 main | 只启用打了标记的那些，并清标记 | 顺延的自然会在下一跳起跑 |
    /// | 删 worker | — | `cancelled`（那一行留着，P3 靠它给 main 一条「这个活没了」） |
    /// | 停 worker | — | 保持 `queued`（可逆的操作不该毁掉一条活） |
    private func applyTeamCascade(_ task: ScheduledTask, event: TeamEvent) {
        let now = Date()
        switch (task.role, event) {
        case (.main, .deleted):
            // ⚠️ **不打 `disabledByParent`**: 那个标记的唯一读者是"启 main ⇒ 恢复谁"，
            // 而这个 main 不会再启了。给一个没人读的标记只会在将来骗人。
            updateWorkers(of: task.id) { w in
                guard w.enabled else { return false }
                w.enabled = false
                return true
            }
            _ = try? store?.persistence?.cancelOpenDelegations(from: task.id, note: "main 已删除", at: now)

        case (.main, .disabled):
            updateWorkers(of: task.id) { w in
                // ⚠️ **只打在"原本是开的"那些上**。给一个已经被手动停掉的 worker 也打标记，
                // 下次启 main 就会把它拉起来 —— 而那是人自己关的（这个功能最贵的一条判据）。
                guard w.enabled else { return false }
                w.enabled = false
                w.disabledByParent = true
                return true
            }

        case (.main, .enabled):
            updateWorkers(of: task.id) { w in
                guard w.disabledByParent else { return false }
                w.enabled = true
                w.disabledByParent = false
                return true
            }

        case (.worker, .deleted):
            // 行**不删**、只落终态: 一条 `cancelled` 且没汇报过的单子正是 P3 要念给 main 的那句
            // "这个活没了"（见 `cancelOpenDelegations` 的注释）。
            _ = try? store?.persistence?.cancelOpenDelegations(to: task.id, note: "worker 已删除", at: now)

        case (.worker, .disabled), (.worker, .enabled):
            break   // 可逆的操作不该毁掉一条活 —— 到期时发现它停着，顺延就是了（P2）
        }
        // 五档状态跟着连带一起变（停 main ⇒ 名下全停，界面那一列立刻要落成"停用"）。
        refreshTeamStates()
    }

    /// 改动某个 main 名下的 worker。`mutate` 返回 `true` = 这一行要落库（**逐行判**，
    /// 而不是"全量重写一遍"—— 后者会把这些 worker 的其它字段一起写回去）。
    private func updateWorkers(of mainId: UUID, mutate: (inout ScheduledTask) -> Bool) {
        for i in scheduledTasks.indices
        where scheduledTasks[i].role == .worker && scheduledTasks[i].parentId == mainId {
            guard mutate(&scheduledTasks[i]) else { continue }
            try? store?.persistence?.upsertScheduled(scheduledTasks[i])
        }
    }

    // MARK: - P15.3 dream（预置任务）

    /// 预置那条 dream 任务的**稳定 id** —— 任务的身份靠它, **不靠名字**。
    ///
    /// 为什么不认 `name == "dream"`: 用户随时能把名字改掉, 改完这条任务对 App 就"消失"了
    /// （于是同一个人会有两份 dream, 而两份的 `note_proposals` 混在一起）。名字是标签, id 是身份
    /// —— 同「持久化键不许是容器里的位置」那条判据。
    static let dreamTaskID = UUID(uuidString: "2E7B4C1A-9F3D-4A6E-8B5C-1D0F7A3E9C42")!

    /// ⚠️ **没有"种过没"的一次性标记了**（2026-10-12 boss 拍板）。原先有一个 `dream_task_seeded`,
    /// 它的判据是"种过没、不是表里有没有" —— 理由是"否则会把用户删掉它读成从没种过, 每次启动都长回来"。
    /// 那条理由的前提（**用户能删掉它**）已被同一条拍板推翻：dream **不可删**（见 `deleteScheduled`）。
    /// ⇒ 现在的判据就是"**表里有没有**"：缺了就补。这才是"固定死"（否则它一旦因老库/将来某 bug 不在,
    /// 就永远不回来了）。代价明写：**已经删过它的老库, 下次启动这条会回来** —— 那正是本意的反面。
    /// （老库里若还留着 `dream_task_seeded` 那一行 setting, 是无害的死配置, 不清理。）

    /// 默认档期 = **每天** 03:00（5 字段 cron: 分 时 日 月 周）。
    ///
    /// ⚠️ **P17 从"每周日"改成"每天"**：dream 的定位是"越用越懂你"（P15 立的），而周更意味着
    /// 一周里前六天攒下的洞见都要等到周日 —— 那六天的会话还得靠"三周窗口"捞回来（已随之
    /// 收到 36 小时, 见 `dreamDigestWindowHours`）。
    /// 只影响**新库种出来的默认值**：老库里那条任务照旧（档期是用户在 Schedule 页能改的字段）。
    static let dreamDefaultCron = "0 3 * * *"

    /// P17 · 运行可靠性: 防 App Nap 的断言。
    ///
    /// **为什么需要**: App Nap 在「窗口不可见 + 无音频 + 在后台 + **没有任何持久断言**」时启动,
    /// 后果是 timer throttling —— 实测 100ms / 200ms 的 timer 会双双被拉到 **5 秒**一跳, 而且
    /// **漏掉的不补**。我们的调度是「每秒 tick + 分钟变了才检查」, 一旦某次 tick 跨过整分钟,
    /// 那一分钟的到期检查**根本不发生** ⇒ 那次任务永不触发。
    ///
    /// ⚠️ 选项取 `userInitiatedAllowingIdleSystemSleep` 而**不是** `userInitiated`: 后者的定义
    /// 里含 `IdleSystemSleepDisabled` ⇒ 会让 Mac **永不休眠**（电池代价）。我们要的只是"别被降频",
    /// 不需要"别睡眠" —— 这条线由冒烟判据守着（`napSuppressionOptions` 不许含该位）。
    ///
    /// 原因串会显示在「活动监视器 → 能耗」与 `pmset -g assertions` 里 ⇒ **刻意不进 L10n 词表**:
    /// 它是喂给 macOS 的标识而不是界面文案（Apple 自家 app 的 reason 同样是英文裸串）,
    /// 方向也与 `[笔记]` 那类"进 prompt 的契约 token"相反。
    static let napSuppressionReason = "MangoX scheduled tasks"
    static let napSuppressionOptions: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep]

    /// dream 的指令文本 —— **恒中文**: 它逐字进 prompt（本文件在 `gen_strings.py` 的
    /// `EXCLUDE_FILES` 里, 在这里写 `L()` 的 key 永远进不了词表; 而同文件里既有
    /// `buildScheduledPrompt` 就是这么写的）。
    ///
    /// 为什么把硬约束写这么重: dream 拿到的是**完整工具集**（它能 read 会话、能 read 笔记,
    /// 也能 write/bash）。判据不能靠"它不会乱来", 得靠它明确知道**这次不写盘**, 以及
    /// App 侧真的没有一条从提案到磁盘的代码路径。
    ///
    /// ⚠️ **P15.6 重写过一次, 教训在"输入"那一段**: 初版让模型自己 `bash` 读
    /// `~/.mangox/pi-sessions/*.jsonl`（只读最近三周）。那条指令有三个病, 报出来时
    /// boss 的原话是"你就是随手一写, 但是细节全都忽略了":
    ///   ① **没有上界** —— 一个 jsonl 几十 KB, 而其中绝大多数字节是工具输出;
    ///   ② 会话与文件的对应关系说不清 —— 文件名才是会话 id, 而文件第一行那个 `id`
    ///      是 pi 内部的会话号, 两个不是一回事; 目录里还混着快照与 fork 产物;
    ///   ③ 于是"读多少、跳哪些行"全靠模型自觉。
    /// 现在摘要由 App 侧算好（`sessionDigest`）随本消息末尾一起给, **prompt 里不再出现
    /// 任何磁盘路径** —— 想加回去的话先读上面三条。
    /// 另: `note_proposal` 是**扩展工具**（`mangox-dream.ts`, 见 `PiRpcTransport`）,
    /// 只在 standard / full 档可见 ⇒ 最后一条硬约束必须告诉模型"找不到它"是什么意思。
    ///
    /// ⚠️ **P15.8 收掉了这处唯一的"磁盘路径例外"**: 原来「没有 [笔记] 段 ⇒ 目标写到
    /// `\(productionNoteDir(projectPath: nil))/<新文件名>.md`」是全文唯一出现具体路径的地方,
    /// 而且它指的是**全局根** —— 于是它成了一个问题不是答案的锚点（2026-10-13 实测: dream 把
    /// MangoX 项目的洞见写进了全局笔记）。现在 `[笔记]` 段**只在所有根都被停用时**才缺席,
    /// 所以那一支的正确反应是"没有落点, 直接结束"。
    /// 归属规则本身（项目优先 / 全局是例外）也写在这里 —— 见下面那两条硬约束。
    static let dreamPrompt = """
    你是 MangoX 的 dream —— 一次**只读**的整理。本次任务里你不写任何文件。

    输入:
      ① 最近会话摘录 —— 见本消息**末尾**的【最近会话摘录】段。App 已经摘好: 只含人与助手的
         正文, 工具输出不在内。每段标题里那串 UUID 就是**会话 id**
      ② 现有笔记 —— 见本消息里的【笔记目录】与【笔记正文】两段。目录是**地图**: 一行一篇
         (根内相对路径 · 标题 · 摘要 · 陈旧天数); 正文是**内容本身**。
         正文超预算时只给最新的那些, 丢掉的会在段尾点名 —— 要它们用 read 按
         「根路径 + 相对路径」取回来。某个根下面写着「（本根暂无笔记）」= 那个根还没有内容,
         但它**已经是合法落点**, 可以直接写

    产出: 用 note_proposal 工具提交提案（字段口径以该工具自己的描述为准）:
      insight —— 会话里反复出现、但还没有成篇的结论（目标是一个**还不存在**的新文件）
      merge   —— 两篇笔记在讲同一件事, 建议并成一篇（目标是留下的那一篇）
      replace —— 笔记里的某个值已过期, 用新值替换（目标就是那一篇）
      delete  —— 这一篇整条不再有用（注意它不是"该改"的另一面: "改"要求还有要说的,
                 "删"要求没有了）。目标是那一篇, 采纳后它进系统废纸篓

    粒度（这一条比下面所有格式要求都重要 —— 它是"人要不要看"的判据）:
      · **一次运行最多 \(Tune.dreamMaxProposals) 条提案。**常规是 1~2 条
      · **同一来源会话里的相关事实, 合成一篇**（用 `##` 小节分开）, 不要一件事一篇。
        判据: 三个月后翻这一篇, 它能不能独立说清"当时在做什么、定了什么、为什么"
      · 只有当一个会话里确实放着**互不相干**的几件事时, 才拆成多篇
      · 拿不准就并进同一篇: 多一篇的成本是**人的审核**, 多一节几乎不花钱
      · 宁可一篇写全, 不要几篇各写一半 —— 半篇笔记比没有更坏, 它看起来像结论

    硬约束:
      · 提案只是提交给人看的, 他采纳了才会落盘 —— 你不需要也不应该写任何文件
      · 每条提案必须有 sources: 会话来源的 ref 填段头那串会话 id, 笔记来源填根内相对路径
      · target_path 必须是**绝对路径**, 且父目录是【笔记目录】段里列出的某一个根。
        标着「（本根暂无笔记）」的根**同样是合法落点** —— 它只是还空着, 不是不能写
      · **归属: 项目优先, 全局是例外。** 默认写到**来源会话所属项目**的那一个根:
        摘要段头的 `归属` 就是那个根的名字, 去【笔记目录】段里按名字找到它的路径。
        只有这两种情况才写全局笔记:
          ① 来源会话的 `归属` 本来就写着「全局笔记」（它不属于任何项目）
          ② 这条结论**明确跨项目** —— 换个项目、换个人也照样成立
        拿不准不是跨项目的理由: 拿不准就写项目根。
      · **不要填 base_hash** —— 目标文件的指纹由 App 在你写下提案的那一刻自己取
        （你拿不到它: read 工具只回正文, 目录段里也只有路径与摘要）
      · **delete 与另外三类不同**: 它不是"写一段新内容" ⇒ **不要 content、也不要 title**;
        其余三类的 content 必须是**整篇新内容**, 不是 diff
      · **找不到 note_proposal 这个工具** ⇒ 本次档位削掉了扩展工具, 直接结束并说明原因,
        不要改用写文件的方式模拟 —— App 侧没有从文件到提案的解析路径
      · 没有【最近会话摘录】段 ⇒ 最近没有会话, 没料可提, 直接结束
      · 没有【笔记目录】段 ⇒ **所有笔记根都被停用了**, 没有可写的落点: 直接结束并说明原因
      · 想不出值得提的就一条都不提 —— 那是正常结果, 不是失败
      · 本次跑不完也不算失败: 出几条算几条
    """

    /// dream 的 fire 指令 = **出厂常量** + （有的话）笔记段 + （有的话）本次摘要（P15.6b / P17）。
    ///
    /// 顺序有意（P17）: 笔记在前、会话摘录在后, 与 `dreamPrompt` 里"输入 ① 会话 / ② 笔记"
    /// 的编号**故意不同** —— 指令正文里那句"见本消息**末尾**的【最近会话摘录】"要成立,
    /// 会话段就必须压在最后（长上下文里"末尾"是有信息量的位置）。
    ///
    /// ⚠️ **刻意不接收 `task`** —— 参数里没有它, 就**不可能**读错 `task.prompt`。
    ///
    /// 为什么必须这样（2026-10-13 boss 实测报的）: `task.prompt` 是**种任务时复制进 DB 的一份
    /// 副本**。我改了 `dreamPrompt` 常量, 而库里那一行纹丝不动（`seedDreamTaskIfNeeded` 的判据
    /// 只有"表里有没有", 没有"在不在当期"）⇒ 打开 Schedule 看到的还是旧指令, **fire 时拿到的是
    /// 旧指令 + 新摘要**（旧指令让它 `bash` 读 jsonl, 摘要又说不用读磁盘 —— 自相矛盾）。
    /// 这是"**能从常量推导的产品文案不许落库当用户字段**"那条判据的实例: 落了就是第二真源,
    /// 且过期时**零红灯**（同一族的还有「持久化键不许是容器里的位置」）。
    ///
    /// 抽成 internal static 还为了让冒烟能造一条"存量旧行"来断言它 —— 今天之前, 这条路径
    /// **一条判据都没有**（夹具里的 dream 任务都是新种的, 永远走不到"存量"）。
    static func dreamFirePrompt(digest: String, notes: String, scopeNote: String? = nil) -> String {
        var parts = [dreamPrompt]
        if let scopeNote { parts.append(scopeNote) }
        if !notes.isEmpty { parts.append(notes) }
        if !digest.isEmpty { parts.append(digest) }
        return parts.joined(separator: "\n\n")
    }

    /// 这一条任务是不是 dream。判据只看 id（见 `dreamTaskID`）。
    /// 定向 dream（`由此 Dream`）追加在常量之后的那一段 —— 说清这次的范围与定时那轮不同。
    ///
    /// 为什么不直接改 `dreamPrompt` 常量: 它同时是定时那轮的指令，而且**落库**成任务行的
    /// `prompt`（`seedDreamTaskIfNeeded`）。改常量会让"定时 = 窗口 / 定向 = 整场"里必有一边
    /// 变成假话。于是"范围"这件事走**追加**：常量管"怎么干"，这一段只管"这次喂的是什么"。
    static let dreamTargetedScopeNote = """
    本次范围是**定向整理**：只针对**一场指定会话**的整段过程（不是最近 36 小时的窗口）。
    段头写着「整场 · 指定会话」—— 把它当成一次完整的经历来提炼，不必顾虑"同一件事是否已经在
    别的会话里出现过"。其余规则不变。
    """

    static func isDreamTask(_ task: ScheduledTask) -> Bool { task.id == dreamTaskID }

    /// 这条任务**允许被删吗**。**规则只写在这里**, 两处消费:
    /// ① `deleteScheduled` 的守卫（能力层, 真正拦住删除）
    /// ② 视图决定「删除」按钮渲不渲染（可见性层）。
    ///
    /// 为什么做成 `static` 纯函数: 视图层**只编译不执行** ⇒ 冒烟抓不到"按钮还在不在", 所以
    /// 可见性必须有一个能被单独断言（且能变红）的形状。改渲染条件时改它, 别在视图里内联 `isDreamTask`。
    static func canDelete(_ task: ScheduledTask) -> Bool { !isDreamTask(task) }

    /// 行内标记的**取舍**（P15.6c）—— 视图只负责画, 不负责判。
    ///
    /// 为什么要有它（而不是让视图直接写 `if !canDelete(task)`）: **视图层只编译不执行**, 冒烟抓不到
    /// "标记渲没渲"（与 `canDelete` 上面那条理由逐字相同）。把取舍挪进纯函数, 才有一条能变红的门
    /// —— 否则这个改动**一条判据都加不了**, 只能靠肉眼看图。
    ///
    /// 做成 enum 而不是 `Bool`: 第二个标记（"等待型 / 已停用"之类）到时候有地方放, 不必在视图里
    /// 再散一次 `if`。目前只有一种。
    enum RowMarker {
        case pinned
    }

    /// 这条任务该显哪个行内标记。**判据只走 `canDelete`**（同一个规则, 不在这里重写一遍 `isDreamTask`
    /// —— 两份判据迟早对同一个任务给出不同答案）。
    ///
    /// ⚠️ 标记的**含义必须小于等于事实**: dream **能改名、能改档期、能开关**, 只有"删除"与"指令正文"
    /// 是锁的 ⇒ 它不许被读成"整条动不了"。所以 tooltip 里那句话必须说全（见视图那侧）。
    /// **标记比事实说得多 = 另一种形式的"这一栏在说谎"**（同 P15.6b 那条判据）。
    static func rowMarker(_ task: ScheduledTask) -> RowMarker? {
        canDelete(task) ? nil : .pinned
    }

    /// 预置一条 dream 任务, **默认关着**（2026-10-12 boss 拍板）。
    ///
    /// 默认关的理由是它的**代价**而不是它的风险: 一次 dream 要读会话 + 全部笔记, 是这批里最贵的
    /// 一次调用, 不该在用户没点头时自己烧 token。而"关着"并不等于"不能用" ——
    /// 开关只管 `cron` 那一路, 手动入口从来不看 `enabled`（见 `runScheduledFire` 的注释）。
    ///
    /// **缺了就补**（判据 = 表里有没有, 见 `dreamTaskID` 上面那段）：所以它不只是"首次启动种一次",
    /// 而是"每次启动都确认它在"。补出来的一律是**出厂态**（默认关 / 默认档期）—— 用户改过的东西本来
    /// 就在那一行里, 行没了就没有可保留的东西。
    func seedDreamTaskIfNeeded() {
        guard let p = store?.persistence else { return }
        // 身份判据只走 `isDreamTask`（同一个规则, 不在这里重写一遍 `id ==`）。
        guard !scheduledTasks.contains(where: { Self.isDreamTask($0) }) else { return }
        // `projectId` 留空 ⇒ fire 时 `cwd = nil` ⇒ 回落 home。**全局笔记跟着人走**,
        // 而 dream 读的会话目录也在 home 下 ⇒ 按 home 跑是它该在的地方（零新配置）。
        let t = ScheduledTask(id: Self.dreamTaskID, name: "dream",
                              prompt: Self.dreamPrompt, cron: Self.dreamDefaultCron,
                              projectId: nil, enabled: false, continuous: false)
        scheduledTasks.append(t)
        try? p.upsertScheduled(t)
    }

    // MARK: - P15.6 dream 的输入摘要

    /// dream 摘要的一条输入 —— 一个会话的身份 + 它的消息。
    ///
    /// 为什么不直接用 `ConversationItem`: 它身上没有消息, 而 `unreadCount` / `sideOf`
    /// 这些字段与摘要无关。摘要函数只该看见它需要的东西 —— **看不见的字段不会悄悄参与计算**。
    struct DreamDigestInput {
        let id: UUID
        let title: String
        let updatedAt: Date
        let messages: [ChatMessage]
        /// 这个会话**该往哪个笔记根写** —— 就是 `[笔记]` 段里那个根的显示名 (P15.8)。
        ///
        /// 刻意是**已经解析好的标签**, 不是 `projectId`: 摘要函数不该知道"哪个项目有根"
        /// （那是 `noteKnowledgeBases` 的事), 它只负责把这一格印在段头上。解析在调用点完成,
        /// 且从 `noteKnowledgeBases` 的**启用态**派生 ⇒ 结构上不可能指向一个段里不存在的根。
        let noteRootLabel: String
    }

    /// 把若干会话编成一段**有界**材料, 给 dream 当唯一输入（P15.6）。
    ///
    /// 为什么需要它: P15.3 的 dream 让模型自己 `bash` 读 `~/.mangox/pi-sessions/*.jsonl`。
    /// 那条路治不好 —— 没有上界（一个 jsonl 几十 KB, 且大部分是工具输出）、数据源是第三方
    /// 文件格式（形状不由本仓定义）、于是"读多少、跳什么"全靠模型自觉。
    /// 这里把三件事一次性收回 Swift: **过滤**（`KnowledgeStore.sessionMaterial` 只认 text,
    /// 与记忆提炼同源）、**预算**（窗口 / 会话数 / 两级字符上限）、**点名**（丢掉的要说出来
    /// —— 折省略, 不静默截断, P15 老判据）。
    ///
    /// 段头 = `会话 id · 标题 · 日期 · 归属 <笔记根名>`。四格里 **`归属` 是唯一给"这条该归到哪儿"
    /// 用的**（P15.8）, 其余三格服务的是"这两件事隔了多久 / 是谁说的"。
    ///
    /// 纯函数: 冒烟喂造数据就能造反例, 不需要真库 / 真磁盘 / 真模型。
    /// - Parameter excludeIds: **本来就不该出现在摘要里**的会话（任务日志会话 / 侧问会话）。
    ///   注意它们仍计入末尾的点名 —— `sessions` 是"交进来的全部", 点名是"没列出来的全部"。
    /// - Parameter priorOmitted: **没交给本函数的**会话数（调用点为了省掉库读只交了个短名单,
    ///   见 `dreamShortlist`）。必须如实计入点名 —— 否则"省下的读"会变成"少说的数"。
    /// - Parameter since: **窗口起点**（P17 起由调用方给, 不再是"now 减固定天数"）——
    ///   它 = `max(now - 36h, 上次 fire 真跑起来的那一刻)`, 见 `dreamDigestSince`。
    ///   把窗口的**来历**留在调用方, 这个纯函数只管"按给定起点筛"。
    /// - Parameter budget: **单会话**预算。默认 = 定时 dream 的 4 万字；定向 dream（`由此 Dream`）
    ///   传 `dreamTargetedMaxChars`（256k）。两条路共用同一个裁剪器 ⇒ "按回合整对丢 + 点名"
    ///   这条语义不需要写第二遍。
    /// - Parameter totalBudget: **整段**预算。定向时传 `dreamTargetedMaxChars` —— 那一段里只有
    ///   一场会话, 而这个循环**不会把最后一场丢掉**（丢光 = 没有料可提炼）, 于是"整段上限"
    ///   在定向路径上实际不参与裁剪；显式传它只是不让读代码的人以为 100k 仍然管着。
    /// - Parameter scopeSuffix: 段头第几格的口径。定时 = `窗口 36 小时`；定向 = 整场。
    ///   ⚠️ **【最近会话摘录】这个名字不许按定向改名** —— `dreamPrompt` 的指令正文指着它
    ///   （"见本消息末尾的【最近会话摘录】段"），改名等于告诉模型"没有摘录段", 它会直接收场。
    static func sessionDigest(_ sessions: [DreamDigestInput],
                              since: Date,
                              excludeIds: Set<UUID> = [],
                              priorOmitted: Int = 0,
                              budget: Int = Tune.dreamDigestMaxCharsPerSession,
                              totalBudget: Int = Tune.dreamDigestTotalChars,
                              scopeSuffix: String = "窗口 \(Tune.dreamDigestWindowHours) 小时") -> String {
        let candidates = sessions
            .filter { !excludeIds.contains($0.id) && $0.updatedAt >= since }
            .sorted { $0.updatedAt > $1.updatedAt }        // 新的在前 ⇒ 下面从**尾部**丢最旧的
        guard !candidates.isEmpty else { return "" }

        var entries: [String] = []
        // P17: **不再 `prefix(MaxSessions)`** —— 编进几个由窗口决定（窗口内全会话都要）。
        for s in candidates {
            let lines = KnowledgeStore.sessionMaterial(from: s.messages)
            guard !lines.isEmpty else { continue }   // 整场只有工具输出的会话: 没有可提炼的东西
            var body = lines.joined(separator: "\n")
            // P17: 单会话超长 ⇒ **按回合整对丢**（原来是 `suffix` 切字符串: ① 开头的用户提问
            // 整段消失 ② 切点落在半句话中间 ⇒ 喂进去的是"没有提问的回答"）。
            if body.count > budget {
                body = KnowledgeStore.trimMaterialByTurns(lines, budget: budget)
            }
            // 段头 **4 格**: 会话 id · 标题 · 日期 · **归属**(P15.8)。
            //
            // 归属必须在**段头**, 不能挪到段尾或别处: dream 每读到一段会话材料, 手边就得同时有
            // "这条该归到哪儿"的答案。分开写要它自己做一次跨段联想 —— 而归属判断正是它唯一的任务。
            // `归属` 后面那串与 `[笔记]` 段里根的第一行**逐字同源**（都出自 `noteRootLabel`)。
            entries.append("## \(s.id.uuidString) · \(s.title) · \(Self.digestDay(s.updatedAt))"
                           + " · 归属 \(s.noteRootLabel)\n\(body)")
        }
        guard !entries.isEmpty else { return "" }

        // 整段超预算 ⇒ 从最旧的会话继续丢, 并计入点名。**循环里重算**而不是先算好:
        // 段头/段尾的数字自身也占字符, 丢一个会话会让它们少一位 —— 用近似值会写出超限的段。
        var kept = entries
        var omitted = priorOmitted + sessions.count - kept.count
        while kept.count > 1, assemble(kept, omitted: omitted, scope: scopeSuffix).count > totalBudget {
            kept.removeLast()
            omitted += 1
        }
        return assemble(kept, omitted: omitted, scope: scopeSuffix)
    }

    /// 摘要的组装 —— 段头 + 会话段 + （有的话）点名行。抽出来是因为上面的循环要反复算长度。
    private static func assemble(_ kept: [String], omitted: Int, scope: String) -> String {
        var parts = ["【最近会话摘录 · \(kept.count) 个会话, \(scope)】"]
        parts.append(contentsOf: kept)
        if omitted > 0 { parts.append("（另有 \(omitted) 个会话未列出: 更早的 / 超出预算的 / 没有正文的）") }
        return parts.joined(separator: "\n")
    }

    /// 摘要段头里的日期。**刻意用绝对日期而不是"3 天前"**: 后者会随 dream 哪天跑而变,
    /// 而模型要判的是"这两件事隔了多久" —— 相对时间在这里是噪声。
    private static let digestDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    static func digestDay(_ d: Date) -> String { digestDayFormatter.string(from: d) }

    /// dream 的**候选短名单** —— 只读它算摘要, 不是读全部会话。
    ///
    /// **为什么要一个界**: `buildDreamDigest` 是**逐会话全量重放**（`loadMessages` 会把整个事件流
    /// 解码成 `ChatMessage`）, 而实测约 **64% 的字节解码完就被 `sessionMaterial` 丢掉**
    /// （`tool` 卡与 `think` 块 —— 见 §11i 的实测表）。没有界, 读的量就与摘要预算完全脱钩。
    ///
    /// ⚠️ **P17 换了界的来历, 且换完更强**:
    /// P15.6 的界是 `MaxSessions + |excludeCount|`, 配一段"为什么它不丢内容"的**证明** ——
    /// 那条证明成立的前提是"`sessionDigest` 最终只保留前 `MaxSessions` 个"。P17 取消了会话数
    /// 上限（范围改由 36 小时窗口决定）⇒ **那条证明失效**, 必须换界。
    ///
    /// 现在的界就是**窗口本身**, 而且它是**精确的**而不是近似的: `sessionDigest` 用的是同一条
    /// `updatedAt >= since` 判据 ⇒ 落在这之外的会话**本来就不会进摘要**。
    /// 近似界要写一段证明"没丢", 精确界不需要 —— 同一条不变量, 换了种更强的成立理由。
    ///
    /// 纯函数 ⇒ 冒烟仍拿它和"读全体"比**逐字相等**（把界改成"按 `updatedAt` 倒序取前 N 个"
    /// ⇒ 那条立刻红, 因为窗口外的会话会占掉名额）。
    static func dreamShortlist(_ items: [ConversationItem], since: Date) -> [ConversationItem] {
        items.filter { $0.updatedAt >= since }
    }

    /// 摘要窗口的起点 = **`max(now - 36h, 上次 fire 真跑起来的那一刻)`**（P17）。
    ///
    /// **为什么必须退到 `lastRunAt`**: 固定 36h 的固有毛病是"漏跑一天 ⇒ 那天的料永久掉出窗口"。
    /// 而 `lastRunAt` 只在 fire **真的起来**时写（`runScheduledFire` 里那一行）, 被跳过的 fire
    /// （`recordFireSkip`）**不写** ⇒ 取 max 同时解决两件事:
    ///   ① 正常日更 ⇒ 取 36 小时（`lastRunAt` 更近）
    ///   ② 漏跑一天 ⇒ 窗口自动拉长到"上次真跑到今天", 那天的会话还在
    ///
    /// 代价明写: 漏跑之后那次会**多读**一批历史会话（`replayMessages` 逐条解码）。但
    /// ① 它只是一次性的, 下一次 fire 的 `lastRunAt` 就回到当下; ② 真正喂给模型的量仍由
    /// `dreamDigestTotalChars` 截住 ⇒ 多读的是**读**, 不是**喂**。
    ///
    /// 纯函数（`now` / `lastRunAt` 都是参数）⇒ 冒烟能喂"上次跑在 50 小时前"造反例。
    static func dreamDigestSince(now: Date, lastRunAt: Date?) -> Date {
        let floor = now.addingTimeInterval(-Double(Tune.dreamDigestWindowHours) * 3600)
        guard let last = lastRunAt else { return floor }
        return min(floor, last)   // 取**更早**的那个 ⇒ 窗口更长（重复可接受, 丢失不行）
    }

    /// 取料 → 编摘要。**这里只做"取", 所有判据在 `sessionDigest` 里**（纯函数, 可造反例）。
    ///
    /// 排除两类会话: ① **任务日志会话**（含 dream 自己的）—— 那是"任务运行记录", 不是人机对话,
    /// 编进去 dream 会把自己的历次运行当成人说过的话来提炼（自我循环）;
    /// ② **侧问会话**（fork）—— 内容已经在源会话的上下文里, 再编一遍只是白占预算。
    ///
    /// 不做"先按窗口筛一遍再读消息"的优化: 预算的判据只该有一处（`sessionDigest`）,
    /// 在调用点再抄一遍窗口条件, 迟早会有一边被改掉而**静默少读会话**。
    /// 这里省掉的读靠的是 `dreamShortlist` 那个**与窗口策略无关**的界（只按 `updatedAt` 排,
    /// 所以窗口怎么改都不会让它失效）, 并且把省掉的数量交给 `priorOmitted` 如实点名。
    private func buildDreamDigest() -> String {
        guard let store else { return "" }
        let all = store.allConversations
        var exclude = Set(scheduledTasks.compactMap(\.logSessionId))
        for c in all where c.sideOf != nil { exclude.insert(c.id) }
        // P17: 窗口起点 = max(now - 36h, 上次 fire 真跑起来的那一刻)。**在 fire 之前**算 ——
        // 此刻 `lastRunAt` 还是上一轮的值（本轮的写在 fire 之后）, 这正是要的那个"上次"。
        let since = Self.dreamDigestSince(
            now: Date(), lastRunAt: scheduledTasks.first { Self.isDreamTask($0) }?.lastRunAt)
        let pass = Self.dreamShortlist(all, since: since)
        // P15.8: 会话 → 归属根名。**从 `noteKnowledgeBases` 的启用态派生**, 不另写一套规则 ——
        // 于是"项目没有 path"与"项目根被用户停用"这两种会话自动回落到全局标签,
        // 而它们本来就没有可写的项目根（那个根压根不在 `[笔记]` 段里）。
        let labels = Self.sessionRootLabels(store: store)
        let inputs = pass.map { c in
            DreamDigestInput(id: c.id, title: c.title, updatedAt: c.updatedAt,
                             messages: store.replayMessages(for: c.id),
                             noteRootLabel: labels[c.id] ?? KnowledgeBase.noteGlobalLabel)
        }
        return Self.sessionDigest(inputs, since: since, excludeIds: exclude,
                                  priorOmitted: all.count - pass.count)
    }

    /// **定向**取料：只编**这一场**，走整场预算（`由此 Dream`，boss 2026-10-21）。
    ///
    /// 与上面那个的三个差别，每一条都是必要的：
    ///   ① `since: .distantPast` —— 目标是**指定的这一场**，不是"最近 36 小时里有哪些"。窗口在
    ///      这条路上没有意义（一场三天前的会话照样该能被完整整理）；
    ///   ② `budget = dreamTargetedMaxChars`（256k）—— 常规 4 万是"一天里每一场各分一点"的口径，
    ///      对"整场"等于砍掉 2/3（实测：11.3 万字 / 40 回合的会话只留得下 19 个回合）；
    ///   ③ `scopeSuffix` 换成整场 —— 段头必须如实说这是整场，否则「窗口 36 小时」就是假话。
    ///
    /// 不做"要不要把它从定时那轮的候选里排掉"的处理: 排掉需要一份"这场被定向跑过"的账，
    /// 而重复提炼只是多两条待审提案（人一看就丢），漏提炼却是永久损失 —— 判据同 P17
    /// 「重复可接受, 丢失不行」。
    /// ⚠️ **不是 `private`**：冒烟要断言"生产路径真的用了 256k"。留成 private 的话，判据只能
    /// 另写一句 `sessionDigest(budget: Tune.dreamTargetedMaxChars)` —— 那是**复述实现**，
    /// 把这里的预算换回默认值它照样绿。可见性放宽一格，换的是一条真能红的门。
    func buildDreamDigest(target: ConversationItem) -> String {
        guard let store else { return "" }
        let labels = Self.sessionRootLabels(store: store)
        let input = DreamDigestInput(id: target.id, title: target.title, updatedAt: target.updatedAt,
                                     messages: store.replayMessages(for: target.id),
                                     noteRootLabel: labels[target.id] ?? KnowledgeBase.noteGlobalLabel)
        return Self.sessionDigest([input], since: .distantPast,
                                  budget: Tune.dreamTargetedMaxChars,
                                  totalBudget: Tune.dreamTargetedMaxChars,
                                  scopeSuffix: "整场 · 指定会话, 不受窗口限制")
    }

    /// dream 的**笔记段** = 【笔记目录】+【笔记正文】（P17）。
    ///
    /// 目录借 `knowledgeIndexSegment()`（与常驻 `[笔记]` 段**同一个组装器**, 于是"根名"两处
    /// 必然一致 —— 归属判断全靠它）。正文是 P17 新开的段, 只在 here 用一次。
    ///
    /// ⚠️ 两段都可能为空: 目录为空 = 所有根都被停用（`dreamPrompt` 里"没有【笔记目录】段 ⇒ 直接结束"
    /// 那一支的判据）; 正文为空 = 笔记都是空的（那是合法状态, 不是错误）。
    ///
    /// ⚠️ **一处已知的措辞重叠（有意不改）**: `knowledgeIndexSegment()` 的段头那句
    /// 「只给索引与摘要; 需要正文时用 read 工具按路径取」是**常驻段**的语境 —— 搬进 dream 之后,
    /// 正文另有【笔记正文】一段, 那句话读起来会有点旧。不动它: 它是**每一轮对话**都在的字节,
    /// 为了让 dream 读着顺一点去改常驻段, 代价与收益倒挂。`dreamPrompt` 的输入②已经把两段的
    /// **分工**写清楚了（"目录是地图、正文是内容本身"）—— 指令比段头权威。
    private func buildDreamNotes() -> String {
        guard let store else { return "" }
        var parts: [String] = []
        if let idx = store.knowledge.knowledgeIndexSegment() {
            parts.append("【笔记目录】\n" + idx.text)
        }
        let body = store.knowledge.noteBodySegment()
        if !body.text.isEmpty { parts.append(body.text) }
        return parts.joined(separator: "\n\n")
    }

    /// 会话 id → 那条会话**该往哪个笔记根写**（根名）。P15.8。
    ///
    /// 两个"必须同源"的点, 各自对应一次可复现的坏结局:
    /// ① **名字取自 `noteKnowledgeBases` 里那个根自己的 `displayName`** —— 模型拿段头的
    ///    `归属 <名字>` 去 `[笔记]` 段里找同名根。两处各拼一遍名字 ⇒ 名字对不上 ⇒ 模型找不到根
    ///    ⇒ 回落全局, **而这一路零红灯**（与 2026-10-13 报的缺陷同一个结局）。
    /// ② **只认 `enabled` 的根** —— 被停用的根不在段里, 把会话指向它就是指向一个不存在的落点。
    ///
    /// 没命中的一律由调用点回落 `noteGlobalLabel`。三种落空都**不是**错误:
    /// 平铺会话（本就没有项目）、项目没有 path（没有落点, `noteKnowledgeBases` 也不列它）、
    /// 项目根被停用（用户明确不要）。
    ///
    /// 纯函数（只读 `store`, 不碰磁盘）⇒ 冒烟能拿它造反例, 不需要真模型。
    static func sessionRootLabels(store: ChatStore) -> [UUID: String] {
        var byProject: [UUID: String] = [:]
        for base in store.knowledge.noteKnowledgeBases where base.enabled {
            guard base.id.hasPrefix(KnowledgeBase.noteProjectPrefix),
                  let pid = UUID(uuidString: String(
                      base.id.dropFirst(KnowledgeBase.noteProjectPrefix.count)))
            else { continue }
            byProject[pid] = base.displayName
        }
        var out: [UUID: String] = [:]
        // 归属 = 位置: 会话属于哪个项目, 就归哪个项目的根。**只走 `ProjectGroup.items`** ——
        // 平铺 `chats` 不属于任何项目, 天然不在这张表里。
        for p in store.projects {
            guard let label = byProject[p.id] else { continue }
            for item in p.items { out[item.id] = label }
        }
        return out
    }

    // MARK: - 调度 + fire (P3.9)

    /// 调度器: 每秒 tick, 分钟变化时才检查 (对齐 cron 的最小粒度; 睡眠唤醒后靠分钟差兜底)。
    /// P17: 同时持一条防 App Nap 的断言 —— 没有它 tick 会被系统降频到秒级甚至更粗,
    /// 跨过整分钟就漏掉一次到期检查（详见 `napSuppressionOptions`）。
    func startScheduler() {
        if napAssertion == nil {   // 幂等: 重复 start 不许堆断言
            napAssertion = ProcessInfo.processInfo.beginActivity(
                options: Self.napSuppressionOptions,
                reason: Self.napSuppressionReason)
        }
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulerTick() }
        }
    }

    /// 停调度 + 交还断言（与 `startScheduler` 对称）。
    func stopScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        if let t = napAssertion { ProcessInfo.processInfo.endActivity(t) }
        napAssertion = nil
    }

    private func schedulerTick() {
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        let gap = minute - lastSchedulerMinute
        guard minute != lastSchedulerMinute else { return }
        lastSchedulerMinute = minute
        // P20 P4: **worker 没有 cron 触发面**（文档 §06 ①「worker 没有 cron 入口」）。
        // 它被叫起来只有一条路: main 派活（`fireDueDelegations`）。不拦的话，UI 里给 worker
        // 配的那条占位 cron 会让它每天自己跑一次 —— 而它没有任何目标，那一轮只会浪费 token。
        for task in scheduledTasks where task.enabled && task.role != .worker {
            guard let cron = task.cronExpr, cron.matches(now) else { continue }
            runScheduledFire(task, at: now)
        }
        // 2026-11-23: agent 给自己约的时点。位置在 cron **之后**、漏跑重算之前:
        //  · 之后 —— 同一分钟里"该跑的巡检"优先，回看是补上次的，不抢这一跳；
        //  · 之前 —— 回看轮**不推进 `lastRunAt`**（它不是这个任务的一次定时运行），
        //    所以它不会影响漏跑的口径，放哪都一样；仍放在这里读起来最顺。
        fireDueFollowUps(now: now)
        // P20: 派活的起跑。放在回看之后: 同一分钟里"它自己约的"优先（那是它上一轮的判断），
        // 派活是别人交代的活。两者都按 `runScheduledFire` 的五道闸走，谁也不抢谁。
        fireDueDelegations(now: now)
        // P17: 大跳 = 睡眠 / 长时间挂起 ⇒ 重算漏跑清单。放在到期检查**之后**: 刚跑过的任务
        // `lastRunAt` 已经前移, 不会被自己算成"漏跑"。首次启动时 `lastSchedulerMinute` 是 0
        // ⇒ gap 巨大 ⇒ 顺带把"启动时算一次"也覆盖了。
        if gap > 1 { refreshMissedFires(now: now) }
        // P19.2 S14: 催。**不另起定时器** —— 这一跳本来就每分钟一次，条件是"有没有该催的"
        // （`WatchNagService.due` 是纯函数）。放在 fire 之后: 同一分钟里先跑该跑的巡检，
        // 再催历史遗留 —— 而"催"不 spawn、不烧 token，与预算闸和并发闸都不相交。
        nagWaitingFindings(now: now)
        // P20 P4: 五档状态的每分钟一跳。界面读的是快照（见 `teamStates`）。
        refreshTeamStates()
        // 执行快照的过期清理（`undoRetentionDays` = 7 天）。
        //
        // ⚠️ 2026-11-18 review: 这个函数**从写下来那天起零调用** —— 于是时间线上那句
        //    「快照留在 …，7 天内可从收件箱回滚」是**半句假话**（实际永久保留，只有删助理才清）。
        //    一个"写了清理器但没人调"的坑比没有清理器更坏: 文档与判据都以为它在跑。
        //
        // 按**日**一次而不是每跳: 目录数是"有几个 finding"（几十到几百），每分钟 stat 一遍
        // 不值当。放后台: 它只删盘，不碰任何 @Published 状态。
        let today = Self.dayKey(now)
        if today != lastUndoPurgeDay {
            lastUndoPurgeDay = today
            DispatchQueue.global(qos: .utility).async {
                let removed = WatchExecService.purgeExpired()
                if removed > 0 { Log.event("undo-purge", "removed", "\(removed)") }
            }
        }
    }

    /// 扫一遍还开着的结论，把"该催的"催一次（判据全在 `WatchNagService.due`，这里只执行）。
    ///
    /// 三条执行纪律：
    ///   · **先落库、再触达**。顺序反过来（先发后落）的话，"发成功但落库失败"会让下一跳
    ///     再发一遍 —— 宁可少催一次，也不要同一件事连发两封（人的反应是把通道整个关掉）。
    ///   · **不写 store.messages**（同 `appendTimeline` 的理由）: 这一跳可能正好有回合在跑。
    ///   · `nagCount` 涨在**这一行 finding** 上（`fingerprint` 定的那一行），所以改方案
    ///     不会刷新上限 —— 那是同一件事的第二次提法，不是新的一件事。
    func nagWaitingFindings(now: Date = Date()) {
        guard let store, let p = store.persistence, !store.findings.isEmpty else { return }
        var byId: [UUID: ScheduledTask] = [:]
        for t in scheduledTasks { byId[t.id] = t }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        var changed = false
        for f in store.findings {
            guard let task = byId[f.taskId],
                  WatchNagService.due(f, task: task, now: now) else { continue }
            var nf = f
            nf.nagCount += 1
            nf.lastNaggedAt = now
            try? p.upsertFinding(nf)
            changed = true
            let logId = task.logSessionId ?? f.sessionId
            appendTimeline("── \(fmt.string(from: now)) 已催第 \(nf.nagCount) 次（\(nf.title)）──",
                           to: logId)
            // 与首次通知**同一条路**: 系统通知受全局开关管，任务级 `notify.system` 是它上面一层；
            // 邮件 / 飞书复用同一个载荷（不另造一种"催促"通知形状 —— 那会多一份会漂的规则）。
            if task.notify.system { store.notifyWatchFinding(nf, taskName: task.name) }
            deliverFinding(nf, task: task, logId: logId)
            Log.event("nag", ["finding": String(nf.id.uuidString.prefix(8)),
                              "n": "\(nf.nagCount)"])
        }
        if changed { store.reloadFindings() }
    }

    /// 一次 fire 的结局 —— 只有两档："起来了" 与 "没起来（+ 为什么）"。
    ///
    /// 做成返回值只为一件事: **follow-up 必须在"没起来"时把约定放回去**（见
    /// `fireDueFollowUps`）。它已经先把那条约定认领成 `fired` 了（防重复叫），若这时被闸挡掉
    /// 还当作已兑现，人就永远等不到那一次回看，而日志里只有一行"因冲突跳过"。
    ///
    /// `@discardableResult`: cron / 补跑 / 定向那些调用点不关心这个值（它们的重试靠下一个 cron 点）。
    enum FireStart: Equatable {
        case started
        case skipped(String)
    }

    /// 到点投递 (P3.9 单日志会话): 任务的全部运行追加进同一个日志会话 (首次 fire 建立)。
    /// P4.0.2: 完全后台化 —— 不劫持选中会话/UI, 直接往日志会话投递回合;
    /// 该任务日志会话已有回合在途则跳过 (cron 到期不重排)。
    /// 持续模式 (continuous): 注入交接文件 (工作日志, agent 写用户可改) + 近期运行摘录,
    /// 并指令 agent 把关键进展写回交接文件——连续性靠文件携带, 磁盘为准零缓存。
    ///
    /// `followUp` 非 nil = 这一轮是**它自己约的**（2026-11-23）: 不进 `lastRunAt` / `runCount`
    /// （同定向 fire 的理由，见末尾那段注释），且把 `why` 原样注入这一轮。
    @discardableResult
    func runScheduledFire(_ task: ScheduledTask, at now: Date = Date(),
                          targeted: ConversationItem? = nil,
                          followUp: FollowUp? = nil,
                          delegation: Delegation? = nil) -> FireStart {
        // P19: 旧条件值守任务只读归档 —— 不 spawn、不写日志、不落痕。
        // 它是全系统唯一一条「无人授权自动执行」的路（fire 恒 unattended: true），
        // 封在这里就是把那条路拆掉；静默是刻意的，UI 上该行已标「旧类型（已停用）」。
        if task.isLegacyWaiting { return .skipped("旧类型已停用") }
        guard let store else { return .skipped("store 未就绪") }
        if let pid = task.projectId {
            guard store.projects.contains(where: { $0.id == pid }) else {
                recordFireSkip(task, at: now, reason: "项目已删除")
                return .skipped("项目已删除")
            }
        }
        // 定位/建立日志会话 (有项目归 project, 无项目落平铺 Chats)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        guard let logId = ensureLogSession(for: task) else { return .skipped("日志会话建不起来") }
        guard !store.runningTurns.contains(logId) else {
            recordFireSkip(task, at: now, reason: "该任务回合在途")
            return .skipped("该任务回合在途")
        }
        // P4.0.4: 并发已满 → 落痕跳过 (与"冲突跳过"同语义, cron 到期不重排)
        if store.runningTurns.count >= store.maxConcurrentTurns {
            recordFireSkip(task, at: now, reason: "并发已满 (\(store.maxConcurrentTurns))")
            return .skipped("并发已满 (\(store.maxConcurrentTurns))")
        }
        // 2026-10-21 (空回合): fire 前校验 pinned 模型还在不在清单里 —— **不在就不 fire**。
        // 为什么非拦不可（2026-10-21 实测，不是推断）: 这条路的后半段是**彻底静默**的。
        // 模型下线后 pi 只 warn 一句 `Using custom model id` 照旧发请求, API 打回 404,
        // 而 pi 把这个 404 **吃成一个空回合**（`agent_settled` 且 assistant content 为空）⇒
        // 日志会话里只有那一大段 prompt, 之后一个字都没有、一条错都没有。用户看到的就是
        // "点了 dream, 之后没任何反应"。拦在这里至少留下**名字**: 哪一次、pin 的是哪个模型。
        // 清单为空 = 无从判断 ⇒ 放行（判据见 `ChatStore.isKnownModel`）。
        if let cfg = task.config, !cfg.modelId.isEmpty,
           !store.isKnownModel(provider: cfg.provider, modelId: cfg.modelId) {
            let pin = cfg.provider + "/" + cfg.modelId
            // 同一个断掉的 pin 每个 cron 点都会走到这里 ⇒ 只在**换了 pin** 时再记一笔
            if modelBlockNoted[task.id] != pin {
                modelBlockNoted[task.id] = pin
                appendTimeline("── \(fmt.string(from: now)) 未运行 (模型 \(pin) 不在模型清单里, 去定时页重选模型) ──", to: logId)
            }
            // 日志会话要**当场绑给任务**: 这条路径 return 在下面那段"推进 lastRunAt / 绑日志会话"
            // 之前, 不绑的话每个 cron 点都会新建一场会话再往里写同一行 —— 那条记录会被撒进
            // 一堆互不相干的会话里, 而任务自己永远指向 nil（下次照样新建）。
            bindLogSession(taskId: task.id, logId: logId)
            return .skipped("模型 \(pin) 不在清单里")
        }
        modelBlockNoted.removeValue(forKey: task.id)   // 跑得起来了: 下次再断要重新留痕
        // ── P19 S7 日预算闸 ────────────────────────────────────────────────────
        // 判据（§04 / 验收 ⑩）：`dailyTokenBudget = 1` ⇒ 次日首次 fire 记「日预算已满」并跳过。
        // 位置在**采集之前**: 采集要跑 curl、要读文件，超了预算还采一遍是白花时间，而且那份
        // 数据立刻会被丢掉 —— 人的观感是"卡了一下, 什么都没发生"。
        // 0 = 不设限 ⇒ 既有 Cron 任务的这一行恒不命中（"Cron 零改动"靠的是默认值, 不是分支）。
        if let reason = budgetBlockedReason(task, at: now) {
            // 同上面两条 return 的坑：**建了会话就必须绑给任务**，否则每个 cron 点都新建一场。
            bindLogSession(taskId: task.id, logId: logId)
            appendTimeline("── \(fmt.string(from: now)) 本轮未运行（\(reason)）──", to: logId)
            return .skipped(reason)
        }
        // 时间线锚点 + prompt 落库 (用户正看着日志会话则同步上屏)
        let viewing = store.selectedConversationId == logId
        // P15.9: 定时与定向**共用这一条**日志会话 ⇒ 分隔行必须当场分得开。两种运行长得一模一样的
        // 话, 三个月后翻这条 dream 记录, 没人看得出哪一次是《由此 Dream》、目标又是哪一场。
        //
        // ⚠️ 标题读 `title` 而**不是** `displayTitle`: 后者会 `L("新对话")`, 而这一行是**落库的
        // 时间线**, 恒中文（本文件在 L10n 的 `EXCLUDE_FILES` 里）—— 掺一个可本地化词会让同一条
        // 记录在不同界面语言下写出不同字节。默认标题的哨兵在这条路上换成恒中文的说法。
        let sepLabel: String
        if let delegation {
            // P20: 派活轮与 cron / 回看**必须一眼分得开** —— 不然人会以为"这个 worker 自己跑了一次"。
            sepLabel = "派活 · 「" + Self.shortWhy(delegation.goal) + "」"
        } else if let followUp {
            // 2026-11-23: 回看轮必须**一眼认得出**。它与一次普通 cron 运行长得一模一样的话，
            // 人会以为"这个任务怎么半夜三点自己跑了一次"，而实际是助理自己约的。
            // 回叫与回看是两件事（一个是 App 替 worker 报信，一个是它自己约的），
            // 长得一样的话三个月后翻日志没人分得清。
            sepLabel = followUp.kind == .callBack
                ? "回叫 · " + Self.shortWhy(followUp.why)
                : "回看 · 约的是「" + Self.shortWhy(followUp.why) + "」"
        } else if let targeted {
            let raw = targeted.title
            let name = raw == ConversationTitle.defaultValue ? "未命名会话" : raw
            sepLabel = "由此 Dream · 「" + (name.count > 40 ? String(name.prefix(40)) + "…" : name) + "」"
        } else {
            sepLabel = "运行"
        }
        let sep = ChatMessage(role: .user, content: .text("── \(fmt.string(from: now)) \(sepLabel) ──"))
        store.persistMessage(sep, sid: logId)
        if viewing { store.messages.append(sep) }
        // ── P19 助理（巡检轮）: 先采集, 再看 ────────────────────────────────────
        // 采集在 spawn **之前**（Swift 侧只读完成）⇒ pi 的 allowlist 不随来源数量膨胀，
        // 也不给来源任何"挂个扩展去读"的机会。写在这一段是因为它要用 logId 留痕：
        // 没有可用来源时**不 spawn**（不烧一轮 token 去看空数据），但必须留一行 ——
        // 静默不发会让人以为"任务根本没跑"，而实际是配置坏了。
        var watchExtra: String?
        if task.isAssistant {
            let snapshot = WatchSourceService(collectors: Self.watchCollectors)
                .collect(sources: task.sources)
            let proj = task.projectId.flatMap { pid in
                store.projects.first { $0.id == pid }.map {
                    WatchProjectContext(name: $0.title, path: $0.path ?? "")
                }
            }
            // 项目就是一条隐式来源（它不需要采集器）⇒ 有项目就不算"没有可用来源"
            //
            // ⚠️ P19.2 S13: **"一条来源都没配"不再算错误**。原判据是 `proj == nil && allFailed`，
            // 而 `allFailed` 把"没有任何可采集的来源"也当失败 ⇒ 无项目助理**永远不 spawn**
            // （当时靠保存校验替它挡着，而那道校验 S13 放宽了）。
            // 现在的判据: **配了来源、且一条都没采到** —— 那才是配置坏了，值得留痕不跑。
            // 没配来源 ⇒ 照常跑: 它还能读账本、看有没有该继续追的事（Q2：不跳过，只改注入）。
            if proj == nil && !task.sources.isEmpty && snapshot.allFailed {
                // ⚠️ 建会话之后 return 的路径**必须**先把会话绑给任务 —— 不绑的话每个 cron 点
                // 都会新建一场会话再往里写同一行，那条记录被撒进一堆互不相干的会话里，
                // 而任务自己永远指向 nil（下次照样新建）。与下面模型 pin 那条同一个坑。
                bindLogSession(taskId: task.id, logId: logId)
                appendTimeline("── \(fmt.string(from: now)) 本轮未运行（没有可用来源: "
                               + "启用 \(task.sources.filter { $0.isActive }.count) 条, "
                               + "出错 \(snapshot.errorCount) 条）──", to: logId)
                return .skipped("没有可用来源")
            }
            if snapshot.errorCount > 0 {
                appendTimeline("── \(fmt.string(from: now)) 部分来源没采到（\(snapshot.errorCount) 条）, 本轮按其余来源判断 ──", to: logId)
            }
            // P20 P3: 队伍段与回执段。**两处都要**: 巡检轮知道"我派出去的活有下文了"，
            // 而它派活的那一轮是另一轮（同一场会话，不同的 turn）。
            let seg = teamSegments(for: task, sid: logId)
            watchExtra = Self.watchSystemPrompt(project: proj,
                                                goal: task.prompt,
                                                handoff: readHandoff(for: task)?.content,
                                                snapshot: snapshot,
                                                ledgerPath: handoffPath(for: task),
                                                followUp: followUp?.why,
                                                followUpKind: followUp?.kind ?? .selfWake,
                                                sent: sentMemory(task.id),
                                                team: seg.team,
                                                receipts: seg.receipts)
            // 收尾要用: 归属哪个任务、这条 finding 算哪个来源、证据允许引用哪些编号。
            // source_id **由 App 决定**（项目来源 / 唯一启用的来源）—— 不接受模型给的 id,
            // 伪造面因此从"编造来源"缩小成"编造观察编号"，后者由 allowedExternalIds 拦。
            watchFires[logId] = WatchFireContext(
                taskId: task.id,
                sourceId: task.projectId ?? snapshot.outcomes.first?.spec.id,
                allowedExternalIds: Set(snapshot.outcomes.flatMap { o in
                    o.observations.map(\.externalId)
                }))
        }
        // 助理的用户消息 = 人写的**目标**（观察与契约在 system 段）; Cron 一字不动
        // P20: 派活轮的用户消息**就是那张单子**（它的长期职责仍在 system 段的【目标】里）——
        // 混进 `task.prompt` 的话，worker 会把一次性的活写进账本目标。
        var prompt: String
        if let delegation {
            prompt = Self.workOrderPrompt(delegation, worker: task)
        } else {
            prompt = task.isAssistant
                ? Self.watchUserPrompt(goal: task.prompt)
                : buildScheduledPrompt(task, targeted: targeted)
        }
        // 2026-11-23: 回看轮必须知道自己**为什么醒**，否则它就是"半夜三点被叫起来重新判断一遍"。
        // 助理档挂在 system 段（`watchSystemPrompt(followUp:)` —— 它得排在输出契约**之前**，
        // 否则"说完就结束"那条末尾不变量被破）；Cron 档没有 system 段可挂（`--no-session`
        // 且不注入），只能接在指令后面。
        if let f = followUp, !task.isAssistant {
            prompt += "\n\n" + (f.kind == .callBack
                                 ? Self.callBackNote(why: f.why)
                                 : Self.followUpNote(why: f.why))
        }
        let promptMsg = ChatMessage(role: .user, content: .text(prompt))
        store.persistMessage(promptMsg, sid: logId)
        if viewing { store.messages.append(promptMsg) }
        // ⚠️ 2026-11-18 boss 定: **定时轮和对话轮走同一场会话** —— 助理档不再用
        // `--no-session`，它和对话轮读写同一份 transcript（同一身份、同一段记忆）。
        // 从前那条"fire 是 ephemeral、连续性靠交接文件"（P3.9）对助理作废；交接文件仍然写，
        // 它现在只是"给下一轮看的结构化摘要"，不再是唯一的连续性来源。
        // ⚠️ **Cron 档一字不动**：非助理任务仍然 `--no-session`（"Cron 零改动"是定过的线）。
        // cwd 用任务项目路径 (无项目回落 home)。
        // P9-#17: 恒无人值守 (task.unattended 仅作历史记录) —— 后台日志会话的审批卡
        // 停在 liveTurns 镜像里无 UI 入口, 弹卡 = 任务卡死到 pi 32s 超时 deny
        let cwd = task.projectId.flatMap { pid in store.projects.first(where: { $0.id == pid })?.path }
        // P10.4: 任务级执行配置 — 只动日志会话 transport (modeOverride/modelOverride 实例级),
        // 全局期望零污染 (主会话档位/模型不受后台任务影响)
        let cfg = task.config
        // P10.4: 任务级档位 —— nil = 跟随全局（这里要算出**生效值**, 下面那条告警才准）。
        let fireMode = cfg.flatMap { AgentMode(rawValue: $0.agentMode) } ?? store.agentMode
        // ── P15.3: dream 的三件前置 ─────────────────────────────────────────────
        // ① 清掉上一次残留的 spool。**它会残留只有一个原因**: 那次 fire 的收口根本没跑到
        //    （进程崩了 / App 被强退）⇒ 那批提案没有可归因的日志会话。留着它更糟 ——
        //    下一次 fire 收口时会把两批混成一锅, 而"这批复核一下"就指不清是哪一次了。
        // ② 档位告警。**只告警不拦截**: 把 dream 配成哪一档是用户的选择（同 P13 不替他改档）。
        // ③ 记下这次的 spool —— 收口时靠 logId 反查（`finishDreamFireIfNeeded`）。
        var fireSpool: String?
        if Self.isDreamTask(task) {
            let spool = PiRpcTransport.dreamSpoolPath(taskId: task.id)
            try? FileManager.default.removeItem(atPath: spool)
            if !fireMode.exposesExtensionTools {
                appendTimeline("── dream: 当前档位 \(fireMode.displayName) 会削掉扩展工具, "
                               + "这次调不到 note_proposal（换 standard / full 档可解）──", to: logId)
            }
            dreamFires[logId] = spool
            if let targeted { dreamTargets[logId] = targeted.id }
            fireSpool = spool
        }
        // 2026-11-23: 档位会削掉扩展工具 ⇒ `follow_up` 那一轮**根本看不到**。
        // **只告警不拦截**（配成哪一档是用户的选择, 同 dream 那一条）。
        // ⚠️ 与 dream **不同的一点**: 这里按任务去重。dream 每个 cron 点都说一遍是因为它一天
        //    通常只跑一次；而 follow-up 的主战场是"每分钟/每小时"的助理 —— 同一个任务把同一行
        //    刷进时间线几十遍，等于把这场日志淹掉（同 `modelBlockNoted` 的理由）。
        if fireMode.exposesExtensionTools {
            followUpTrimNoted.remove(task.id)   // 换档换好了: 以后再削要重新提一次
        } else if followUpTrimNoted.insert(task.id).inserted {
            appendTimeline("── 当前档位 \(fireMode.displayName) 会削掉扩展工具, "
                           + "这个任务调不到 follow_up（换 standard / full 档可解）──", to: logId)
        }
        // 收口只有 sid ⇒ 先记下"这一轮是哪张单"（与 `followUpFires` / `watchFires` 同一套理由）。
        if let delegation { delegationFires[logId] = delegation }
        store.beginTurn(sid: logId, prompt: prompt, ephemeral: !task.isAssistant,
                        cwd: cwd, unattended: true,
                        modeOverride: cfg.flatMap { AgentMode(rawValue: $0.agentMode) },
                        modelOverride: cfg.map {
                            (provider: $0.provider, modelId: $0.modelId, thinking: $0.thinkingLevel)
                        },
                        dreamSpool: fireSpool,
                        // P19: 助理 = 注入段（观察 + 契约 + 交接）。per-turn，`beginTurn` 里
                        // **无条件**下发（见那里的注释: 不清就会漏进下一回合）。
                        // ⚠️ 2026-11-18: 这里原来还有 `analysisReadOnly: task.isAssistant`
                        // —— 只读面整层删了，助理的工具面按它自己选的档位（boss 定）。
                        extraSystemPrompt: watchExtra,
                        followUpOwner: task)
        // P10.3 联动: 日志会话行带上任务配置 (点开会话即恢复其执行配置)
        if let cfg { store.persistence?.saveSessionConfig(id: logId, config: cfg) }
        // P15.9: 定向 fire **不推进 `lastRunAt` / `runCount`** —— 它不是"这个定时任务的一次运行"。
        // `lastRunAt` 一被推到现在, 就吃掉"上次真跑在很久以前"的那段**补跑窗口**：
        // `dreamDigestSince` 取 `max(now - 36h, lastRunAt)`，36 小时是**地板**、改不动, 被吃掉的
        // 是**超出 36 小时的那部分** ⇒ 那段时间里没被定向跑过的会话**永久掉出窗口**, 且零红灯。
        // `runCount` 同理: 它是"定时跑了几次", 定向跑一次不该让它涨。
        //
        // 2026-11-23: **回看轮同一条理由**。它是"任务体外的一次唤醒"，不是这个任务的定时那一次 ——
        // 推进 lastRunAt 会让"下次 cron 该补哪一段"算错，涨 runCount 会让"已跑 N 次"里混进
        // 用户没安排过的次数（而那个数他就拿来判断"这个东西是不是太吵"）。
        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            // P20: 派活轮同理 —— 它不是这个 worker 的定时那一次。
            if targeted == nil && followUp == nil && delegation == nil {
                scheduledTasks[idx].lastRunAt = now
                scheduledTasks[idx].runCount += 1   // P3.10: 执行次数
            }
            // 起跑时刻**不记在这里** —— 四种 fire 都会往下走 `store.beginTurn`，那里记一次
            // 就覆盖了全部入口（含人手动点、飞书）；在这里另记一份只会让两条路给出两个起点。
            scheduledTasks[idx].logSessionId = logId
            try? store.persistence?.upsertScheduled(scheduledTasks[idx])
        }
        return .started
    }

    // MARK: - follow-up · agent 给自己约定时器（2026-11-23）

    /// 这一轮能不能给自己约定时器 —— 能就把 spool 路径给它，不能就 nil。
    ///
    /// **判据只有一条**: 这一轮属于某个**还活着、能跑、还肯给它配额**的任务 —— `owner != nil`，
    /// 不是旧条件值守（只读归档，连 fire 都不许），不是 dream（见下面那条），且这个任务的
    /// 回看配额 > 0（Cron 档恒 0 ⇒ 那一档根本看不到这个工具）。
    /// 为什么必须是任务:
    ///   · 约定要有个**归属**才能在到点时被叫起来 —— 普通会话没有"那个任务"，醒了往哪跑？
    ///   · 更实际的一条: 普通会话的收口路径根本不读 spool（`finishFollowUpIfNeeded` 靠
    ///     `followUpFires` 反查）。给了工具却不读，表现是"它说约好了，到点没人叫它"——
    ///     比没有这个工具更坏。
    ///
    /// ⚠️ **双闸门的挂载那一半**: 返回值非 nil 才把扩展挂上去（`PiRpcTransport`）。
    func beginFollowUpTurn(sid: UUID, owner: ScheduledTask?) -> String? {
        // ⚠️ dream 也在排除之列: 它的触发只有「到点的 cron」与「人点由此 Dream」两种，
        // 让一次提炼给自己约下一次 = 让蒸馏自己决定什么时候蒸馏 —— 那是一条只烧 token
        // 的回路，而它的产出（提案）本来就要人一条条点采纳。
        // ⚠️ 配额在这里也是**挂载闸门**的一半: 0 就干脆不给工具。给一个工具却让每次调用
        //    都被配额挡回来，模型会反复试 —— 而那是最坏的一种"看起来支持"。
        guard let owner, !owner.isLegacyWaiting, !Self.isDreamTask(owner),
              owner.effectiveFollowUpsPerDay > 0 else { return nil }
        let spool = PiRpcTransport.followUpSpoolPath(taskId: owner.id)
        // 记一笔给收口用: 那里只有 sid，反查不出这份 spool 属于哪个任务
        //（fire 轮新建的会话在那一刻还没绑到任务上）。
        followUpFires[sid] = (spool: spool, taskId: owner.id)
        return spool
    }

    /// 飞书上叫停时落进 `note` 的那句话。**恒中文**（本文件在 L10n 的 `EXCLUDE_FILES` 里，
    /// 落库文案不本地化）。放在这里而不是调用现场: `RemoteChannelService` 不在排除名单里,
    /// 在那儿写中文字面量会让三道 l10n 门当场变红。
    static let feishuStopNote = "用户在飞书上说这件事结束了"

    /// 作废某任务名下**所有还等着叫的**约定（2026-11-26）。
    ///
    /// 为什么要有这个: 在这之前 `cancelled` 只有两个产生者 —— "任务被删除"与"任务被停用"
    /// （见 `fireDueFollowUps`）。用户说一句「这件事搞定了」**不会**作废任何约定，于是
    /// 几天后它还照旧到点把人叫起来问一遍已经解决了的事 —— 那正是"主动性"最坏的一种表现
    /// （要被追问的人重新交代一次现状）。
    ///
    /// ⚠️ **只动 `pending`**。`fired` 是"已经叫过一轮"这个事实，`missed` 是"试了三次没起来"，
    /// 两个都是**已经发生过的历史** —— 回滚它们等于改写历史，而人回头看时间线时会找不到
    /// 那几轮到底还在不在。作废的语义只有"将来不要再叫"，不包含"把过去撤销"。
    ///
    /// - Returns: 真的作废了几条（0 = 本来就没有排着的，调用方据此决定怎么回话）。
    @discardableResult
    func cancelPendingFollowUps(taskId: UUID, note: String, sid: UUID? = nil) -> Int {
        guard let p = store?.persistence else { return 0 }
        let pending = (try? p.loadFollowUps(taskId: taskId, status: .pending)) ?? []
        guard !pending.isEmpty else { return 0 }
        for f in pending {
            try? p.settleFollowUp(id: f.id, status: .cancelled, firedAt: nil, note: note)
        }
        reloadFollowUps()
        if let sid {
            appendTimeline("── 作废了 \(pending.count) 条回看：\(note) ──", to: sid)
        }
        Log.event("follow-up-cancel", ["task": String(taskId.uuidString.prefix(8)),
                                       "n": String(pending.count)])
        return pending.count
    }


    /// 一轮结束时把 spool 收进 `agent_followups`，然后删掉 spool。
    ///
    /// 两条路都要收: **落定**（`agentSettled`）与**手动停**（`stopTurn`）——「跑不完不算失败」，
    /// 它已经约下的时刻仍然有效（那是这一轮唯一的产出）。
    ///
    /// ⚠️ **`dueAt` 在这里算**（`now + after_minutes`），不是扩展侧算的 —— 子进程的钟我们
    /// 看不见也不该信。代价: 约定比模型说的时间晚"一个回合的尾巴"（几十秒到几分钟）。
    /// 换来的是"到点时刻只有一个产生者"，不存在"它算的钟和 App 的钟差 8 小时"这种不可复现的偏差。
    ///
    /// ⚠️ 顺序 = 解析 → 落库 → 删文件。**删在最后**: 落库失败时 spool 还在，下一轮收口会再
    /// ingest 一次；而每条请求都带扩展侧生成的 `id` ⇒ 撞主键 ⇒ 不会变成两条约定。
    func finishFollowUpIfNeeded(sid: UUID) {
        guard let ctx = followUpFires.removeValue(forKey: sid) else { return }
        guard let store, let p = store.persistence else { return }
        // 任务在回合中途被删掉 ⇒ 约定没有归属了（tick 也没有东西可叫起来）。
        // spool 照旧删 —— 留着它只会被下一轮当成"上一次没消化完的"再读一遍。
        guard let task = scheduledTasks.first(where: { $0.id == ctx.taskId }) else {
            try? FileManager.default.removeItem(atPath: ctx.spool)
            return
        }
        guard let text = try? String(contentsOfFile: ctx.spool, encoding: .utf8) else { return }
        let batch = FollowUpSpool.parseBatch(text)
        let now = Date()
        // ── 作废 **先于** 新约（2026-11-26）──
        // 顺序不是随便排的: 同一轮里写"原来的不用了，改看另一件事"是合法写法；反过来的话
        // 新约那条会先插进去、紧接着被自己的作废扫掉 —— 表现是"它说约好了，到点没人叫它"。
        // ⚠️ 作废**不吃三道配额闸**（它不产生唤醒）。吃掉一条配额等于让"叫停"这件事
        //    在"今天已经约满"的那天变成不可能 —— 而那恰恰是最该叫停的时候。
        for c in batch.cancels {
            _ = cancelPendingFollowUps(taskId: ctx.taskId,
                                       note: "用户说这件事结束了：" + c.why,
                                       sid: sid)
        }
        // ── 三道配额闸，全部**只在 App 侧判**（扩展不知道今天用了多少、也不该知道）──
        //  ① 每轮最多 `followUpsPerTurn` 条：一轮里写出两个以上的未来时刻 = 它在给自己排班；
        //  ② 每天最多 `effectiveFollowUpsPerDay` 条：人手里那个旋钮，拦"每轮都约"；
        //  ③ 未兑现最多 `maxPendingPerTask` 条：拦堆积（与 ①② 不重复 —— 一天的 2 条可能
        //    横跨好几天，未兑现的可以攒到 3）。
        let quota = task.effectiveFollowUpsPerDay
        let usedToday = (try? p.followUpCountSince(
            taskId: ctx.taskId, since: Calendar.current.startOfDay(for: now))) ?? 0
        var quotaLeft = max(0, quota - usedToday)
        var pending = (try? p.pendingFollowUpCount(taskId: ctx.taskId)) ?? 0
        var inThisTurn = 0
        var added: [FollowUp] = []
        var problems = batch.rejects.map { "第 \($0.line) 行: \($0.reason)" }
        var duplicates = 0
        for r in batch.items {
            guard inThisTurn < Self.followUpsPerTurn else {
                problems.append("一轮只能约 \(Self.followUpsPerTurn) 条（这一轮后面那几条没记上）")
                continue
            }
            guard quotaLeft > 0 else {
                problems.append("今天已经约了 \(usedToday) 条（上限 \(quota)），这条没约上 —— "
                                + "改配额在任务设置里")
                continue
            }
            // 上限按**未兑现**的算（不是历史上的条数）: 一个跑了一个月的助理不该因为
            // "它总共约过 50 次"而被禁止再约。
            guard pending < FollowUpLimit.maxPendingPerTask else {
                problems.append("这个任务已经欠 \(pending) 条约定了（上限 "
                                + "\(FollowUpLimit.maxPendingPerTask)），这条没约上")
                continue
            }
            let f = FollowUp(id: r.id,
                             taskId: ctx.taskId,
                             dueAt: now.addingTimeInterval(Double(r.afterMinutes) * 60),
                             why: r.why,
                             status: .pending,
                             attempts: 0,
                             createdAt: now,
                             firedAt: nil,
                             note: nil)
            if (try? p.insertFollowUpIfAbsent(f)) == true {
                added.append(f)
                pending += 1
                inThisTurn += 1
                quotaLeft -= 1
            } else {
                // 同一个 spool 被 ingest 第二次（收口崩在落库与删文件之间）。**不算错误**。
                duplicates += 1
            }
        }
        if !added.isEmpty || !problems.isEmpty {
            appendTimeline(Self.followUpSummary(added: added, problems: problems,
                                                duplicates: duplicates, now: now), to: sid)
        }
        try? FileManager.default.removeItem(atPath: ctx.spool)
        reloadFollowUps()
    }

    /// 一轮里最多能约几条。**1** —— follow-up 的语义是"过一会儿再看这一件事"；一轮里冒出
    /// 三个不同的未来时刻，说明它已经在给自己排班了，而那正是要防的。
    /// ⚠️ 这条比"两次约定之间至少隔 N 分钟"准：后者挡不住真正的病（每轮都约，那是频次问题，
    /// 由每天配额拦），却会挡住"10 分钟后复查构建"这种正当的近邻复查。
    static let followUpsPerTurn = 1

    /// 重读未兑现的约定（界面那一行 + `nextFollowUp` 的唯一来源）。
    func reloadFollowUps() {
        guard let p = store?.persistence else { followUps = []; return }
        followUps = (try? p.loadFollowUps(status: .pending)) ?? []
        // 五档状态与这份清单同源（同一批写路径会改它）⇒ 顺手一起刷。两条查询，不值得分开叫。
        refreshTeamStates()
    }

    /// 团队五档状态的**快照** —— 界面读它，不在 `body` 里读库。
    ///
    /// 为什么是快照而不是计算属性: 一次刷新两条查询，而 SwiftUI 的 `body` 在一次滚动里会
    /// 求值几十次（本仓踩过"滚动路径上算东西"那一类）。这里把频率压到"数据真的变了"。
    ///
    /// 刷新点: `schedulerTick`（每分钟）+ 派活那几条写路径（派出去 / 起跑 / 落定 / 汇报）
    /// + 连带（停用 / 删除）。**漏一个的后果**: 界面停在旧状态，直到下一跳 —— 一分钟，可接受；
    /// 所以宁可少叫几次，也不要放进 body。
    @Published private(set) var teamStates: [UUID: TeamState] = [:]

    func refreshTeamStates() {
        guard let p = store?.persistence else { teamStates = [:]; return }
        // 一个 worker 同时只允许一张（硬拒不排队）⇒ 多张时取最早那张当"手上那张"（同 `openDelegationsByWorker`）。
        var busy: [UUID: Delegation] = [:]
        for d in (try? p.openDelegations()) ?? [] where busy[d.toTask] == nil { busy[d.toTask] = d }
        let awaiting = (try? p.latestUnreportedByWorker()) ?? [:]
        var out: [UUID: TeamState] = [:]
        for t in scheduledTasks {
            // 「此刻在自己跑」= 它那场日志会话在 `runningTurns` 里。这就是派活闸门用的同一个判据
            // （`main.logSessionId` + `runningTurns`，见"main 这一轮还在跑 ⇒ 顺延"那一处）——
            // 两处同源，不会出现"界面说在跑、闸门说空闲"。
            // 起点取 `turnStartedAt`（`beginTurn` 里那一行）：定时 / 回看 / 派活 / 飞书 / 人手动点
            // 五条入口**都从那儿过**，所以这里不用按入口分别记 —— 早先那版在本文件里另存一张
            // task 键的表，结果漏了"人在会话里手动叫它跑"和"飞书触发"两条路（会画成空闲）。
            let live: Date? = {
                guard let log = t.logSessionId,
                      store?.runningTurns.contains(log) == true else { return nil }
                return store?.turnStartedAt(sessionId: log)
            }()
            out[t.id] = TeamState.of(t, busy: busy, awaiting: awaiting[t.id], live: live)
        }
        teamStates = out
    }

    /// 一个人现在的状态（没算过 = 空闲，界面不会因此画错一行）。
    func teamState(of taskId: UUID) -> TeamState {
        teamStates[taskId] ?? .idle(lastActive: nil)
    }

    /// 某个 main 名下有几个 worker（列表行右侧那一句「N 个 worker」）。
    func workerCount(of mainId: UUID) -> Int {
        scheduledTasks.filter { $0.role == .worker && $0.parentId == mainId }.count
    }

    /// 某个 worker 归谁（名单与列表要用名字，不要 id）。
    func parentName(of worker: ScheduledTask) -> String? {
        worker.parentId.flatMap { pid in scheduledTasks.first { $0.id == pid }?.name }
    }

    /// 这个任务下一条约定（已排序，取最早那条）。界面只用它显示一行。
    func nextFollowUp(for taskId: UUID) -> FollowUp? {
        followUps.first { $0.taskId == taskId }
    }

    /// 扫一遍到点的约定，**一条一条起一轮**。由 `schedulerTick` 每分钟调一次。
    ///
    /// 三条纪律（每条都对应一次能复现的坏结局）:
    ///
    /// ① **先认领、再起轮**。认领（`pending → fired`）与起轮之间隔着五道闸；顺序反过来
    ///    （先起后落）的话，"起来了但落库失败"会让下一跳再叫一次 —— 而这一次是**真的重跑一整轮**，
    ///    烧的是 token，不是一条通知。
    /// ② **起不来就放回去**（`rearm`）。被"在途 / 并发满 / 超预算"挡掉时不能当作已兑现 ——
    ///    那等于把约定吃掉，人永远等不到那次回看。重试是**顺延**（`retryStepMinutes` × 次数），
    ///    不是每分钟狂撞；三次之后判 `missed` 并在日志里留一行。
    /// ③ **任务没了/停了就作废，不重排**。给一个已经停用的任务排回看，是替用户重新开启他关掉的东西。
    func fireDueFollowUps(now: Date = Date()) {
        guard let store, let p = store.persistence else { return }
        let due = (try? p.dueFollowUps(now: now)) ?? []
        guard !due.isEmpty else { return }
        for f in due {
            guard let task = scheduledTasks.first(where: { $0.id == f.taskId }) else {
                try? p.settleFollowUp(id: f.id, status: .cancelled, firedAt: nil, note: "任务已删除")
                continue
            }
            guard task.enabled, !task.isLegacyWaiting else {
                try? p.settleFollowUp(id: f.id, status: .cancelled, firedAt: nil, note: "任务已停用")
                continue
            }
            try? p.settleFollowUp(id: f.id, status: .fired, firedAt: now, note: nil)
            if case .skipped(let reason) = runScheduledFire(task, at: now, followUp: f) {
                let attempts = f.attempts + 1
                if attempts >= FollowUpLimit.maxAttempts {
                    try? p.settleFollowUp(id: f.id, status: .missed, firedAt: nil,
                                          note: "\(reason) · 试了 \(attempts) 次没起来")
                } else {
                    let next = now.addingTimeInterval(
                        Double(FollowUpLimit.retryStepMinutes * attempts) * 60)
                    try? p.rearmFollowUp(id: f.id, dueAt: next, attempts: attempts, note: reason)
                }
            }
            // 日志: 约定 id 前 8 位 + 结局。排查"它约了但没跑"时这是第一现场。
            Log.event("follow-up", ["id": String(f.id.uuidString.prefix(8)),
                                    "task": String(f.taskId.uuidString.prefix(8))])
        }
        reloadFollowUps()
    }

    /// 时间线那一行的措辞（恒中文：本文件在 L10n 的 `EXCLUDE_FILES` 里，落库文案不本地化）。
    ///
    /// ⚠️ **必须把被拒的那几条说出来**。spool 马上删了，现在不写，人只会看到"这次怎么没约上"，
    /// 而不知道是哪一条死在了路上（同 `dreamSummary` 的理由）。
    static func followUpSummary(added: [FollowUp], problems: [String],
                                duplicates: Int, now: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        var lines: [String] = []
        for f in added {
            let due = fmt.string(from: f.dueAt)
            lines.append("── \(fmt.string(from: now)) 约在 \(due) 回看（\(f.why)）──")
        }
        for p in problems { lines.append("── \(fmt.string(from: now)) 约定没记上: \(p) ──") }
        if duplicates > 0 {
            lines.append("── \(fmt.string(from: now)) 有 \(duplicates) 条约定重复提交, 已忽略 ──")
        }
        return lines.joined(separator: "\n")
    }

    /// 回看轮的注入段（助理档走 system、Cron 档接在指令后面 —— 同一份字，两处挂）。
    ///
    /// 它只说**为什么醒**与**这一轮该怎么收**，不复述目标（目标/账本/契约都在别处）。
    /// ⚠️ 最后那句"别连着约第三次"是有意的: follow-up 一旦接上自指回路，最省事的行为就是
    /// 「再看一次再约一次」—— 那是最贵的空转（每轮都烧满上下文，什么都不变）。
    static func followUpNote(why: String) -> String {
        """
        【回看 · 你自己约的】
        这是你上一轮结束时给自己约的一次。约的时候你写的是：\(why)
        ⚠️ 不是人在叫你，也不是这个任务的定时到了 —— 是你自己说「过一会儿再来看看」。
        这一轮别把上一次的判断重做一遍，先看它现在是什么样，然后落到三种之一：
        · 已经做完 / 已经过去 ⇒ 说清结论，**不要再约下一次**；
        · 还没变 ⇒ 说清现在的状态；确实还要等，才再约一次（同一件事别连着约第三次）；
        · 缺东西（要人给材料 / 要人拍板）⇒ 说清缺什么、要他怎么答。
        """
    }

    /// 回叫轮的注入段（P20）。与 `followUpNote` **并列而不是复用**它:
    /// 那一份开头写着"这是你上一轮结束时给自己约的"，而回叫是**别人那边**结束了 ——
    /// 用同一份会让 main 以为自己约过，于是它去"再检查一遍"而不是去看回执。
    ///
    /// ⚠️ 最后那句"别把它的活重做一遍"是有针对的: main 手上有全部上下文，最省事的反应就是
    /// 自己顺手干完 —— 那等于同一件事烧两次 token，而 worker 那一轮的产出白扔。
    static func callBackNote(why: String) -> String {
        """
        【回叫 · 你的 worker 交活了】
        \(why)
        ⚠️ 不是人叫你，也不是定时到了 —— 是你派出去的那件事有了下文。
        这一轮先看这条回执：办成了就跟人说清结论；没办成要决定重派、换人，还是自己接。
        **不要把它的活重做一遍** —— 它那一轮的产出在它自己的台账里。
        """
    }

    /// 分隔行里那一小段"约的是什么"。**截短**是因为它会进时间线，而时间线是一条消息。
    static func shortWhy(_ why: String) -> String {
        let t = why.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 24 ? String(t.prefix(24)) + "…" : t
    }

    // MARK: - P20 派活（2026-11-24）

    /// 在途的**派活轮** —— 日志会话 -> 那张单。
    ///
    /// 为什么要记: 收口（`finishDelegationFireIfNeeded`）发生在回合落定之后，那时只有 `sid`；
    /// "这一轮是哪张单"在库里查不出来（那张单此刻还是 `running`，但同一个 worker 可能
    /// 先跑自己的 cron 再跑下一张单）。与 `followUpFires` / `watchFires` 同一套理由。
    private var delegationFires: [UUID: Delegation] = [:]

    /// 在途的**派活请求收集** —— 日志会话 -> (spool, main 的任务 id)。这一轮是 main 在派活。
    private var delegateSpools: [UUID: (spool: String, mainId: UUID)] = [:]

    /// 这一轮能不能给 worker 派活 —— 能就把 spool 路径给它。
    ///
    /// 判据三条，缺一条都不给工具（**挂载闸门**，`PiRpcTransport` 那半靠返回值非 nil）:
    ///   · 它是 main —— worker 的工具面里没有 `delegate`，递归扇出在结构上不成立；
    ///   · 它是助理 —— Cron 档没有"一支队伍"这个概念（也没有 `--session` 的注入面）；
    ///   · 配额 > 0 —— 0 = 人明确关掉。**给一个每次都被挡的工具比不给更坏**（模型会反复试）。
    func beginDelegationTurn(sid: UUID, owner: ScheduledTask?) -> String? {
        guard let owner, owner.isAssistant, owner.role == .main,
              !owner.isLegacyWaiting, owner.effectiveDelegatesPerDay > 0 else { return nil }
        let spool = PiRpcTransport.delegateSpoolPath(mainTaskId: owner.id)
        delegateSpools[sid] = (spool: spool, mainId: owner.id)
        // P3: 两个只读工具要的正文与 spool **同时**落盘 —— 挂得上工具就读得到数据，
        // 不存在"工具有、数据没有"那个中间态。
        writeTeamDossier(main: owner, spool: spool)
        return spool
    }

    /// 一轮结束时把 spool 里那几张派活请求过一遍**七条判据**，落库，然后删 spool。
    ///
    /// 顺序 = 解析 → 判 → 落库 → 删文件（同 `finishFollowUpIfNeeded`）: 删在最后，
    /// 崩在中间时下一轮会再读一遍，而每张请求都带扩展侧生成的 `id` ⇒ 撞主键不会变成两张单。
    ///
    /// ⚠️ **判据只在这里**（不在扩展里）: 名单 / 谁手上有活 / 今天派了几条都是库里的瞬时事实，
    /// 而塞进子进程 env 的那一份会在进程复用时**冻结**。代价 = 模型下一轮才知道被拒。
    func finishDelegateTurn(sid: UUID) {
        guard let ctx = delegateSpools.removeValue(forKey: sid) else { return }
        guard let store, let p = store.persistence else { return }
        guard let main = scheduledTasks.first(where: { $0.id == ctx.mainId }) else {
            // main 在回合中途被删了 ⇒ 这些请求没有归属。spool 照旧删。
            try? FileManager.default.removeItem(atPath: ctx.spool)
            return
        }
        guard let text = try? String(contentsOfFile: ctx.spool, encoding: .utf8) else { return }
        let parsed = DelegationSpool.parse(text)
        let now = Date()
        var busy = openDelegationsByWorker()
        var usedToday = (try? p.delegationCount(
            from: main.id, since: Calendar.current.startOfDay(for: now))) ?? 0
        var usedThisTurn = 0
        var accepted: [(Delegation, String)] = []
        var problems = parsed.rejects.map { "第 \($0.line) 行: \($0.reason)" }
        for ask in parsed.items {
            switch DelegationRule.check(ask, from: main, roster: scheduledTasks, busy: busy,
                                        usedToday: usedToday, usedThisTurn: usedThisTurn) {
            case .failure(let why):
                // 前三条是**事实错误**（改一次就对）⇒ 顺手把可用名单回给它，省一轮来回。
                // 配额那两条不回名单: 名单没问题，它需要的是等或者改设置。
                let withRoster: Bool
                switch why {
                case .unknownWorker, .workerIsMain, .workerDisabled: withRoster = true
                default: withRoster = false
                }
                problems.append("派给「\(ask.worker)」没成: " + why.reason
                                + (withRoster
                                   ? "\n   " + DelegationRule.rosterLine(main, roster: scheduledTasks,
                                                                        busy: busy)
                                   : ""))
            case .success(let workerId):
                guard let worker = scheduledTasks.first(where: { $0.id == workerId }) else { continue }
                let d = Delegation(id: ask.id, fromTask: main.id, toTask: workerId,
                                   goal: ask.goal, acceptance: ask.acceptance, context: ask.context,
                                   dueAt: now.addingTimeInterval(Double(ask.afterMinutes) * 60),
                                   dueBy: ask.dueInMinutes.map {
                                       now.addingTimeInterval(Double($0) * 60)
                                   },
                                   status: .queued, attempts: 0, note: nil, summary: nil,
                                   reportedAt: nil, createdAt: now, startedAt: nil, finishedAt: nil)
                try? p.insertDelegation(d)
                // 同一轮里派第二张单时，"他手上有活"必须看得见刚派的这张 —— 否则一轮可以
                // 给同一个 worker 派两单，而那正是文档硬拒的那件事。
                busy[workerId] = d
                accepted.append((d, worker.name))
                usedThisTurn += 1
                usedToday += 1
            }
        }
        if !accepted.isEmpty || !problems.isEmpty {
            appendTimeline(Self.delegationSummary(accepted: accepted, problems: problems, now: now),
                           to: sid)
        }
        try? FileManager.default.removeItem(atPath: ctx.spool)
        // 新派的单子会改"谁手上有活" ⇒ 界面那一档立刻跟上（不然要等一分钟才显示"已排上"）。
        refreshTeamStates()
    }

    /// 这些 worker 手上还没落定的单（`openDelegations` 的字典版）。
    private func openDelegationsByWorker() -> [UUID: Delegation] {
        guard let p = store?.persistence else { return [:] }
        let open = (try? p.openDelegations()) ?? []
        // 一个 worker 同时只允许一张（硬拒不排队）⇒ 有多张时取最早的那张当"手上那张"。
        var out: [UUID: Delegation] = [:]
        for d in open where out[d.toTask] == nil { out[d.toTask] = d }
        return out
    }

    // MARK: - P3 注入与只读工具（2026-11-24）

    /// 本轮**注入过**哪几条回执 —— 收口成功时按它标 `reported_at`。
    /// 与 `delegateSpools` / `delegationFires` 同一套理由: 收口那一刻手里只有 `sid`。
    private var receiptsInjected: [UUID: [UUID]] = [:]

    /// 有下文、还没念过的那一批（最多 5 条，最新的在前）。
    func unreportedReceipts(from mainId: UUID) -> [Delegation] {
        guard let p = store?.persistence else { return [] }
        return (try? p.unreportedDelegations(from: mainId,
                                            limit: DelegationLimit.maxReceipts)) ?? []
    }

    /// 这一轮要注入的两段（`nil` = 这一段没有内容）。
    ///
    /// ⚠️ **判据只有"数据有没有"，没有角色判据** —— worker 名下必然没有 worker（深度恒 1），
    /// 它派出去的也必然没有单子（工具面里没有 `delegate`）。多写一个 `role == .main`
    /// 只是又一处会漂的判据，而它判的这件事本来就不成立。
    func teamSegments(for task: ScheduledTask, sid: UUID) -> (team: String?, receipts: String?) {
        let busy = openDelegationsByWorker()
        let now = Date()
        let team = TeamPrompt.rosterBlock(main: task, roster: scheduledTasks,
                                         busy: busy, now: now)
        let rows = unreportedReceipts(from: task.id)
        // **无条件赋值**（含清空）: 上一轮若半路没跑起来，这条记录会留成一条指向旧单子的账，
        // 下一轮成功收尾时就会把**没念过**的那条标掉 —— 静默吞掉一条回执。
        receiptsInjected[sid] = rows.isEmpty ? nil : rows.map(\.id)
        var byId: [UUID: ScheduledTask] = [:]
        for t in scheduledTasks { byId[t.id] = t }
        let receipts = TeamPrompt.receiptBlock(rows, workers: byId, now: now)
        return (team, receipts)
    }

    /// 回执消化掉了。**只在那一轮成功收尾时调**（`ChatStore.streamEnded`）。
    ///
    /// `produced == false`（空回合 / 崩了）⇒ **不标**: 那一轮一个字都没说，人根本没看见这条回执，
    /// 标掉等于把它吞了。方向永远是"宁可下一轮再念一遍" —— 重复念一句的代价远小于
    /// "那件活出了事，而我永远不会知道"。
    func markReceiptsReported(sid: UUID, produced: Bool) {
        guard let ids = receiptsInjected.removeValue(forKey: sid), !ids.isEmpty else { return }
        guard produced, let p = store?.persistence else { return }
        let now = Date()
        for id in ids { try? p.markDelegationReported(id: id, at: now) }
        refreshTeamStates()   // 「等回执」那一档是界面状态，标掉就要跟着落回去
    }

    /// dossier 文件名的后缀（spool 派生）。扩展那侧读的是同一个公式 —— **两处一起改**。
    static let teamDossierSuffix = ".team.json"

    /// 两个只读工具的正文**提前算好**，写在 spool 旁边（`<spool>.team.json`）。
    ///
    /// 为什么不另开一个 env: 那要多一条 per-turn 下发通道（协议 / 默认实现 / Mock 三处），
    /// 而这两份文件本来就同生同死（同一个 main、同一轮）；派生一个文件名比加一条通道便宜。
    /// 为什么不等到调工具那一刻再算: 子进程读不到库，它只能读文件；而写在**这一轮开始时**
    /// 还顺带保证了"同一轮两次调用看到的是同一份"。
    private func writeTeamDossier(main: ScheduledTask, spool: String) {
        let busy = openDelegationsByWorker()
        let now = Date()
        let roster = TeamPrompt.dossierBlock(main: main, roster: scheduledTasks, busy: busy,
                                             lastDone: lastDoneByWorker(main), now: now)
        var ledgers: [String: String] = [:]
        for w in TeamPrompt.myWorkers(main, roster: scheduledTasks) {
            ledgers[w.name] = TeamPrompt.ledgerBlock(workerName: w.name,
                                                     ledger: readHandoff(for: w)?.content)
        }
        let json = TeamPrompt.dossierJSON(roster: roster, ledgers: ledgers)
        let dir = (spool as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? json.write(toFile: spool + Self.teamDossierSuffix,
                        atomically: true, encoding: .utf8)
    }

    /// 每个 worker 最近一次**交活**的时刻（`list_workers` 那句「上次 11-22 交活」）。
    /// 用 `finishedAt`（真的干完了）而不是 `createdAt`（派出去了）。
    private func lastDoneByWorker(_ main: ScheduledTask) -> [UUID: Date] {
        guard let p = store?.persistence,
              let rows = try? p.loadDelegations(fromTask: main.id) else { return [:] }
        var out: [UUID: Date] = [:]
        for d in rows where d.status == .done {
            let at = d.finishedAt ?? d.createdAt
            if (out[d.toTask] ?? .distantPast) < at { out[d.toTask] = at }
        }
        return out
    }

    /// 时间线那几行措辞（恒中文，本文件在 L10n 的 `EXCLUDE_FILES` 里）。
    static func delegationSummary(accepted: [(Delegation, String)], problems: [String],
                                  now: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        var lines: [String] = []
        for (d, name) in accepted {
            lines.append("── \(fmt.string(from: now)) 派给「\(name)」· 约在 "
                         + "\(fmt.string(from: d.dueAt)) 起跑（\(shortWhy(d.goal))）──")
        }
        for p in problems { lines.append("── \(fmt.string(from: now)) 派活没成: \(p) ──") }
        return lines.joined(separator: "\n")
    }

    /// 扫一遍到点的派活单，**一张一张起 worker 的一轮**。由 `schedulerTick` 每分钟调一次。
    ///
    /// 与 `fireDueFollowUps` 同构，只有两处**故意不同**:
    ///  · **不按次数判死**（那个函数三次就 `missed`）: worker 忙四十分钟是正常的，把它判成
    ///    失败等于把一条活扔掉。顺延到天荒地老，直到 `due_by` 过了才作废；
    ///  · 起跑要额外避让 **main 那一场**（`ComputerHost` 一个进程一个 scope，两场同时要助手
    ///    会互相 `stop()` 重启 —— 现象是"微信点了一半助手消失了"）。
    func fireDueDelegations(now: Date = Date()) {
        guard let store, let p = store.persistence else { return }
        let due = (try? p.dueDelegations(now: now)) ?? []
        guard !due.isEmpty else { return }
        for d in due {
            guard let main = scheduledTasks.first(where: { $0.id == d.fromTask }) else {
                // main 没了 ⇒ 这张单谁也不欠，作废（不留回执: 收件人都不在了）。
                try? p.settleDelegation(id: d.id, status: .cancelled,
                                        summary: nil, note: "main 已删除", at: now)
                continue
            }
            guard let worker = scheduledTasks.first(where: { $0.id == d.toTask }) else {
                finishDelegation(d, worker: nil, status: .cancelled,
                                 summary: nil, note: "worker 已删除", at: now)
                continue
            }
            // 停用 / 只读归档 ⇒ **顺延**（可逆的操作不该毁掉一条活），过了 due_by 才作废。
            if !worker.enabled || worker.isLegacyWaiting {
                postpone(d, reason: "「\(worker.name)」停着", now: now, at: p)
                continue
            }
            // ⚠️ main 那一场还在跑 ⇒ 顺延。代价明写: 伪实时退化成"main 跑完立刻起"。
            if let mainLog = main.logSessionId, store.runningTurns.contains(mainLog) {
                postpone(d, reason: "main 这一轮还在跑", now: now, at: p)
                continue
            }
            switch runScheduledFire(worker, at: now, delegation: d) {
            case .started:
                try? p.startDelegation(id: d.id, at: now)
                Log.event("delegate", ["id": String(d.id.uuidString.prefix(8)),
                                       "to": String(worker.id.uuidString.prefix(8))])
            case .skipped(let reason):
                // `runScheduledFire` 自己会留痕（在途 / 并发满 / 模型不在清单 …）。
                postpone(d, reason: reason, now: now, at: p)
            }
        }
    }

    /// 顺延一张单（起不来），或者——过了 `due_by`——作废并回执。
    private func postpone(_ d: Delegation, reason: String, now: Date, at p: PersistenceStore) {
        if let dueBy = d.dueBy, dueBy <= now {
            finishDelegation(d, worker: scheduledTasks.first(where: { $0.id == d.toTask }),
                             status: .cancelled, summary: nil,
                             note: "过了期限没起来（\(reason)）", at: now)
            return
        }
        // 步长固定、不按次数判死（见 `fireDueDelegations` 的注释）。`attempts` 只是给人看的量。
        let next = now.addingTimeInterval(Double(FollowUpLimit.retryStepMinutes) * 60)
        try? p.rearmDelegation(id: d.id, dueAt: next, attempts: d.attempts + 1, note: reason)
    }

    /// 一张单落定 + （按需）给 main 一条回执。**所有终态都走这里** —— 分叉出去就会有一条路忘了回执。
    ///
    /// 为什么不给"回执"另造一张表/一个队列: `agent_delegations` 那一行本身就是待汇报的状态
    /// （`reported_at IS NULL` = 还没汇报），再存一份就是第二真源。回执的**投递**借用 follow-up
    /// 的到期机制（`dueAt = now` ⇒ 下一跳就叫它），但 `kind = .callBack` ⇒ **不占** main 的配额。
    private func finishDelegation(_ d: Delegation, worker: ScheduledTask?,
                                  status: DelegationStatus, summary: String?, note: String?,
                                  at now: Date) {
        guard let p = store?.persistence else { return }
        try? p.settleDelegation(id: d.id, status: status, summary: summary, note: note, at: now)
        // main 已经不在了 ⇒ 没有收件人，不插回执（插了也没人会读，而 tick 每次都会去叫它）。
        guard scheduledTasks.contains(where: { $0.id == d.fromTask }) else { return }
        let name = worker?.name ?? "worker"
        let head: String
        switch status {
        case .done: head = "\(name) 交活了：\(summary ?? "（没写结论，细节去读它的台账）")"
        case .cancelled: head = "\(name) 那张单作废了：\(note ?? "原因不明")"
        default: head = "\(name) 没干成：\(note ?? "这一轮没有产出")"
        }
        let f = FollowUp(id: UUID(), taskId: d.fromTask, dueAt: now,
                         why: Self.shortWhy(head), status: .pending, attempts: 0,
                         createdAt: now, firedAt: nil, note: nil, kind: .callBack)
        if (try? p.insertFollowUpIfAbsent(f)) == true { reloadFollowUps() }
        refreshTeamStates()
    }

    /// 一轮落定：把那张单收成 `done` / `failed`，并给 main 一条回执。
    ///
    /// **判据**: "这一轮有没有产出"（最后一条 assistant 消息有没有字），不是"活干成没有" ——
    /// 活成没成只有 worker 自己知道，那一句写在 `summary` 里由 main 读。
    func finishDelegationFireIfNeeded(sid: UUID) {
        guard let d = delegationFires.removeValue(forKey: sid) else { return }
        guard let store, store.persistence != nil else { return }
        let text = Self.turnConclusion(store.replayMessages(for: sid))
        let worker = scheduledTasks.first(where: { $0.id == d.toTask })
        guard !text.isEmpty else {
            finishDelegation(d, worker: worker, status: .failed, summary: nil,
                             note: "这一轮没有产出（空回合 / 中途停 / 出错）", at: Date())
            return
        }
        finishDelegation(d, worker: worker, status: .done,
                         summary: DelegationLimit.clip(text, DelegationLimit.maxSummaryChars),
                         note: nil, at: Date())
    }

    /// 这一轮的结论 = **最后一条 assistant 文本的第一行**（≤400 字由调用方截）。
    ///
    /// 为什么是第一行: 助理档的输出契约第一行就是「结论：…」，而摘要的用途是"main 读一眼
    /// 就知道它干成没干成" —— 整段塞进回执等于把 worker 的窗口搬进 main 的窗口。
    static func turnConclusion(_ msgs: [ChatMessage]) -> String {
        guard let last = msgs.last(where: { $0.role == .assistant }),
              case .text(let s) = last.content else { return "" }
        let first = s.split(separator: "\n").first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 派活轮的**正文**（工人看到的那张单子）。恒中文，逐字进 user prompt。
    ///
    /// 为什么不复用 `task.prompt`: 那是它的**长期职责**（"盯着 CI"），而一张单子是
    /// "这一次干什么"。混成一个字段的话，worker 会把一次性的活写进账本目标里。
    static func workOrderPrompt(_ d: Delegation, worker: ScheduledTask) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        var lines = [
            "【派活单】这一轮只干这件事。",
            "",
            "要做的：\(d.goal)",
            "算干完的标志：\(d.acceptance)",
        ]
        if let c = d.context?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            lines.append("相关上下文：\n\(c)")
        }
        if let dueBy = d.dueBy {
            lines.append("最晚要：\(fmt.string(from: dueBy)) 之前。")
        }
        lines.append("")
        lines.append("""
        收尾时：
        · **第一行写一句话结论**（队长读的就是那一行；细节写进你的账本）；
        · 别把这张单并进你账本里的长期目标 —— 它是这个队长的一次委派；
        · 没人坐在旁边，所以不写「方案」等审批；但删东西 / 对外发消息仍然不许碰。
        """)
        return lines.joined(separator: "\n")
    }

    // MARK: - P19 助理 · 巡检轮

    /// 巡检轮的**回复**契约 = 出厂常量。
    ///
    /// 为什么是常量而不是 `task.prompt`: 那一段是**人写的目标**（「保证 CI 是绿的」），
    /// 契约是**机器的接口**（三段 / NO_FINDING）。混进同一个字段，人一改目标就把契约删了，
    /// 而下游解析只会在某一天发现"结论没解析出来"，零红灯。
    ///
    /// ⚠️ P19.2 S11: **「工作日志」段从这里搬走了** —— 账本不再由 App 从回复里解析后写盘，
    /// 改由模型自己 `write` 那一份文件（落点由注入段里那个绝对路径给定 —— 围栏已删，见 D8）。所以这里的回复只剩三段，
    /// 而五节的**文件格式**搬到 `watchLedgerContract`（见下）。两份东西分开的理由:
    /// 回复是"这一轮判断了什么"（给人看、给解析器落 finding），账本是"目标到哪了"（给
    /// 下一轮的自己看）。混在一个段落里时，任何一处格式改动都会同时影响两件事。
    static let watchOutputContract = """
    【输出契约】只输出下面三段，不要寒暄、不要复述我给你的数据。
    结论：一句话 —— 目标达成了 / 没达成 / 没达成但有变化。
    证据：支撑结论的具体观察，带上来源与编号（形如 [3]）；文件位置写 file.swift:42。
    方案：没达成时给编号步骤，每步写清「动哪个目标 · 怎么做 · 能不能撤销」；不需要动手就写「无」。
    这一轮没有任何变化、也不值得找人 ⇒ 只输出一行：NO_FINDING
    """

    /// 无目标助理的**这一轮正文**（P19.2 S13）。出厂常量，不从 `prompt` 派生。
    ///
    /// 为什么必须替它写一句: 空 `prompt` 直接发下去 = 一条**空 user 消息**，
    /// 而模型那一侧收到的是「看守一个长程目标」的 system 段 + 什么都没有 —— 它会开始编目标。
    /// 这句话同时给了它退路（NO_FINDING 不算失败）。
    static let assistantNoGoalPrompt = """
    这一轮没有给定目标。
    先读账本与注入的观察：有值得接手的就接着做，没有就只回一行 NO_FINDING。
    """

    /// 账本的**文件格式**（五节）。P19.2 S8 定形状、S11 起由模型自己写盘。
    ///
    /// ⚠️ 这些节名与标记是**和解析器约定好的字面量**（`AssistantLedger.parse`）——
    /// 不得本地化、不得改写、不得增删别名（`## 已完成（归档）` 是"做完就撤下验收项"的唯一出口，
    /// 没有它，16k 满了以后就是「每轮账本都不更新」）。
    static let watchLedgerContract = """
    【账本格式】下面五节一节都不许省，节名照抄：
    ## 目标
    一句话复述你在看守的目标。目标被人改过，就写「原目标 → 现目标」。
    ## 完成状态
    验收标准逐条，一行一条，行首打标：[x] 已达成 / [ ] 未达成 / [!] 卡住（后面写卡在什么上）。
    第一轮先把验收标准列出来（三到五条），之后每轮更新**同一批**，不要每轮换一批。
    ## 在跟踪
    当前正在推进的事，一行一件；没有就写「无」。
    ## 待你决定
    要人授权 / 给材料 / 做选择的事，**一行一件**；没有就写「无」。
    这一节不是记给自己看的笔记 —— **每一行都会被主动发到人的飞书**（一次发一条），
    所以它写的是"问他"，一行就必须能独立读懂。每行自带三件事，缺一件就别写这一行：
    **要什么 · 为什么（带观察编号 [n] 或文件位置）· 他怎么答**（回「可以 / 不行」还是给一段信息）。
    - **查得到的不要问**：能用 read / grep / find / ls 看到的，先看了再说话。
      把查得到的东西拿来问，比不问更浪费人。
    - **这一节只放「要信息」，不放「要动手」**：动手的事写进输出契约的「方案」那一段 ——
      那一份才有人点「采纳并执行」，起手会做快照。把"我要删掉 X"写成这里的问句，
      人会以为点个头就完了，而实际没人会去删。
    - **已经在这一节里的，原样保留那一行**（一个字都别改）。改写措辞会被当成**另一件事**，
      人就再被打扰一次。它没解决就一直留着，别每轮换个说法重写。
    - 人回答之后：把那一行从这一节**撤掉**，结论写进「在跟踪」或「已完成（归档）」。
    ## 已完成（归档）
    已经收尾的事，一行一件，写成「日期 + 一句话」（如 2026-11-17 修好 CI：根因是时区写死）。
    这件事做完就把它的验收项从「完成状态」撤下来、在这里记一条；没有就写「无」。
    """

    /// 采集器表。**`project` 不在里面**（它由分析段的只读工具现场看，不是采集器）；
    /// `mail` 本版**故意不接** —— 现有 curl poll 会置已读，PEEK 未实测前上线就是偷偷
    /// 改动用户的邮箱状态（§02 前置门 4）。
    ///
    /// 空表不是"空壳": `WatchSourceService` 对没有采集器的来源记 `unavailable`，
    /// 这正是要它在日志与 UI 里说出来的那句话 —— 静默跳过才是空壳。
    static var watchCollectors: [WatchSourceKind: WatchSourceCollecting] { [:] }

    /// 巡检轮的用户消息 = **目标**（唯一稳定、由人写的东西）。
    ///
    /// 每轮变的观察 / 交接文件 / 契约走 system 注入（`watchSystemPrompt`）。
    /// 这条分工不是美学: 目标是**人写的那一句**，它该留在人看得见的消息流里；
    /// 观察是每轮现采的，滚进日志会话只会让三个月后的那场会话全是重复数据。
    static func watchUserPrompt(goal: String) -> String {
        // P19.2 S13: 没有目标的助理是合法配置（"待命"档）。空目标若照旧拼进去，
        // 模型收到的是「本轮巡检目标：」后面什么都没有 —— 一句悬空的话比没有更糟。
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return Self.assistantNoGoalPrompt }
        return """
        本轮巡检目标：\(g)

        这一轮采集到的观察数据与输出规则已随本轮注入（不在下面的会话历史里）。
        按它判断这个目标达成没有；没达成且值得找人，就把方案写清楚。
        """
    }

    // MARK: - 已发消息记忆（2026-11-23）

    /// 「你已经发过的」那一段 —— **每轮现算**，进易变段。
    ///
    /// 为什么必须现算: 它要接的正是**上一轮刚发出去的那句话**。塞进常驻 persona 就等于
    /// 把"昨天说过什么"冻在启动那一刻，而这个功能的全部意义是"这一轮别重复上一轮"。
    ///
    /// ⚠️ 只取 `status = sent`：`queued`（回执没来）与 `failed` 都不是"已经在他手机上"，
    ///    把它们写进这段等于教模型记错事实。
    /// ⚠️ 空就**整段不出现**。写一句"（还没有）"只会让模型去猜自己是不是忘了什么。
    ///
    /// 不 `private`：冒烟要直接调它断言"哪几条进了段、每条被渲染成什么样" —— 走整轮 fire
    /// 去验这段的代价是每加一条判据多跑一整轮，而它是个无副作用的读方法。
    func sentMemory(_ taskId: UUID, now: Date = Date()) -> String? {
        guard let p = store?.persistence,
              let rows = try? p.loadSent(taskId: taskId,
                                         limit: SentLimit.injectCount,
                                         onlySent: true),
              !rows.isEmpty else { return nil }
        // 查询是"新的在前"，注入按时间**正序**读才像一份记录（人读聊天记录也是从上往下）。
        let lines = rows.reversed().map { m -> String in
            let one = m.text.replacingOccurrences(of: "\n", with: " ")
            let clipped = one.count > SentLimit.injectChars
                ? String(one.prefix(SentLimit.injectChars)) + "…"
                : one
            return "- \(Self.sentTag(m.at, now: now)) · \(m.kind.tag) · \(clipped)"
        }
        return """
        【你已经发过的】（最近 \(lines.count) 条，只有真的发出去的）
        这些**已经在对方手机上了**。同一件事不必再说一遍 —— 要说就接着往下说
        （"昨天我说过 X" 可以，重复 X 本身不是）。
        \(lines.joined(separator: "\n"))
        """
    }

    /// 注入段里的时间标签。**恒中文**（注入面不进词表，同 `[笔记]` 那一族）。
    /// 近的给相对说法（今天/昨天），远的给日期 —— 与任务卡 L2 那行同一套口径。
    static func sentTag(_ at: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if cal.isDate(at, inSameDayAs: now) { return f.string(from: at) }
        if cal.isDateInYesterday(at) { return "昨天 " + f.string(from: at) }
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: at)
    }

    /// 巡检轮的 system 注入段（走 `--append-system-prompt`）。**纯函数**: 参数即全部输入。
    /// `ledgerPath` **不是可选的** —— 巡检轮按构造永远有一份账本（`handoffPath` 总能算出
    /// 一条路径）。留一个 nil 分支只会让人以为"某一轮可以没有账本"。
    /// `goal` 是任务的目标（= `task.prompt`）。**只在它为空时说话**：非空时目标已经是
    /// 这一轮的 user 消息，搬进 system 段只是把同一句话写两遍，还会让人分不清哪个算数。
    static func watchSystemPrompt(project: WatchProjectContext?,
                                  goal: String,
                                  handoff: String?,
                                  snapshot: WatchSnapshot,
                                  ledgerPath: String,
                                  followUp: String? = nil,
                                  followUpKind: FollowUpKind = .selfWake,
                                  sent: String? = nil,
                                  team: String? = nil,
                                  receipts: String? = nil) -> String {
        var parts: [String] = []
        parts.append("""
        【助理任务 · 巡检轮】
        你是在替一个人看守一个**长程目标**（可能持续几周甚至几个月），不是执行一条命令。
        ⚠️ 这一轮**没有人坐在你旁边**（到点自己跑的那一轮）：不弹审批卡，也没人会按。
        所以边界只能靠你自己分清楚，下面三条一句话一条：

        · **普通活直接干** —— 读、看、写普通文件、跑脚本、装依赖、查日志。不用问，没人拦你。
        · **重要操作先别动** —— 删东西、覆盖已有的重要内容、重启/停服务、动数据库、
          对外发消息（邮件 / 飞书 / 任何别人能看见的东西）、花钱。
          把它写成**输出契约里的「方案」那一段**（编号步骤，每步写清动什么、能不能撤销），
          人点了「采纳并执行」才会真做 —— 那条路起手会做整轮快照，跑完能回滚。
        · **要信息 / 要人做选择**（不是要动手）—— 写进账本的「## 待你决定」，
          那一节会被**主动发到人的飞书**。缺材料也一样：查过之后仍然缺，就写进那一节问人。

        账本在：\(ledgerPath)（要记进度就写它；只写这一个地方不会被当成「没干活」）
        """)
        if let p = project, !p.path.isEmpty {
            parts.append("【项目】\n\(p.name) · \(p.path)\n这一轮的工作目录就是它，read / grep / find / ls 可以直接看。")
        } else if let p = project {
            parts.append("【项目】\n\(p.name)\n（这个项目没有绑定目录，只能用注入的观察数据判断。）")
        }
        // P19.2 S13: **没有目标的助理**是合法配置（"待命"档），不是错误。
        // 它这一轮能做的是: 读账本、看观察、判断有没有值得接手的活。两处都空就回 NO_FINDING ——
        // 这句话必须在这里说清，否则模型收到的是一个"看守目标"的指令 + 一段空正文。
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("""
            【目标】
            这一轮**没有给定目标** —— 你唯一的目标来源是账本和下面的观察。
            两处都没有值得追的事，就只回一行 NO_FINDING（不要自己编一个目标出来）。
            """)
        }
        let h = (handoff ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // P20 P3:【你的队伍】。位置 = "我是谁 / 我要干什么"之后、"上一轮的记忆"之前 ——
        // 它回答的是"我手上有什么人"，与目标同属**这一轮的判断输入**，而不是记忆。
        if let team, !team.isEmpty { parts.append(team) }
        parts.append(h.isEmpty
            ? "【上一轮留下的工作日志】\n（**账本还不存在或还是空的**。如果你判断没有可追踪的目标，只回一行 NO_FINDING；有的话就把五节写全。）"
            : "【上一轮留下的工作日志】\n\(h)")
        // P19.2 S8: 报字数。**模型看不见自己那份账本多大** —— 只在契约里写「允许压缩」是一句
        // 空话，它永远不知道自己已经 13k 了。这一行是「压缩归档」那条路唯一的触发条件。
        // 空账本不说（没有可压缩的东西，多一句只是噪音）。
        if !h.isEmpty {
            let cap = WatchFindingService.handoffMaxChars
            let compact = WatchFindingService.handoffCompactThreshold
            parts.append(h.count > compact
                ? "【账本容量】当前 \(h.count) 字 / 上限 \(cap) —— **已超过 \(compact) 字**。这一轮请把「## 已完成（归档）」压缩到最近 \(WatchFindingService.archivedKeep) 条：只删最旧的那几行，其余四节一个字都不要删。"
                : "【账本容量】当前 \(h.count) 字 / 上限 \(cap)。超过 \(compact) 字时才需要压缩归档，这一轮不用管。")
        }
        parts.append("【这一轮的观察】\n" + snapshot.rendered())
        // 账本: 落点规矩 + 文件格式。**必须说清"你自己写"** —— 从前这里写的是
        // 「你写不了工作日志」，那在 S11 之后就是假的: 它现在真的有一支笔。
        parts.append("""
        【写账本】
        落点只有一个，就是上面那个绝对路径。三条硬规矩：
        1. **写绝对路径**，不要用 `~` 也不要写相对路径 —— 判不清会落到哪，一律拒。
        2. **整篇覆盖**: 把上一轮的账本（已注入在上面）连同这一轮的更新合成一篇，一次 write 写完。
        3. 不要为了"留证据"往别处写文件；不要声称你改了别的东西。
        """)
        parts.append(Self.watchLedgerContract)
        // 2026-11-23:「已发消息」—— 它上一轮往外说过什么。**排在回看注记之前**：那一段是
        // "这一轮为什么醒"（属于收尾），而"我说过什么"是判断的输入，得先看见。
        if let sent, !sent.isEmpty { parts.append(sent) }
        // 2026-11-23: 回看轮的"为什么醒"。**必须排在输出契约之前** —— 契约是"说完就结束"的那一段，
        // 它后面不该再有话（这条不变量从写下来那天就挂着）。
        if let f = followUp, !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(followUpKind == .callBack ? Self.callBackNote(why: f)
                                                  : Self.followUpNote(why: f))
        }
        // P20 P3:【派活回执】。位置与回看注记同一条理由 —— 排在输出契约**之前**。
        // 它是"这一轮有下文要处理"，属于判断输入；放在契约后面等于让它在"说完就结束"之后。
        if let receipts, !receipts.isEmpty { parts.append(receipts) }
        // 回复契约放最后（它是"说完就结束"的那一段，后面不该再有话）
        parts.append(Self.watchOutputContract)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - P19 助理 · 对话轮

    /// 一场会话如果是某个**助理任务的对话轮**，这一轮要带的三样东西。
    ///
    /// 为什么不是只返回注入段: P19.2 S12 起对话轮有**一支笔**（只许写账本），
    /// 而「笔往哪写」与「注入里承诺的那个路径」**必须是同一个字符串** —— 分成两次反查，
    /// 迟早出现"prompt 里说的是 A、账本落到 B"，而那种偏差只表现为"它说它写了，文件没变"。
    struct AssistantChatTurn: Equatable {
        let taskId: UUID
        let prompt: String
        let ledgerPath: String
    }

    /// 收尾要用的上下文（只在 `beginDialogueTurn` 里落一张，`finish*` 里认领）。
    private struct DialogueTurnContext: Equatable {
        let taskId: UUID
        let ledgerPath: String
    }

    private var dialogueTurns: [UUID: DialogueTurnContext] = [:]

    /// 这场会话是不是**某个助理的**（巡检轮 / 对话轮 / 执行轮都算）。
    ///
    /// 与 `assistantChatTurn` 的区别只有一件事：那个还要**生成对话轮的注入段**，这个只回答是/否。
    /// `ChatStore.beginTurn` 用它来钉「助理线上工具级审批恒关」—— 那边只是要一个布尔值，
    /// 顺手调 `assistantChatTurn` 会白算一遍注入（而那份注入有一处 `readHandoff` 是读盘的）。
    func isAssistantLogSession(_ sid: UUID) -> Bool {
        scheduledTasks.contains { $0.isAssistant && $0.logSessionId == sid }
    }

    /// 这场会话是哪个任务的**日志会话**？（`nil` = 普通会话 / 侧问 / 不是任何任务的日志）
    ///
    /// ⚠️ 2026-11-20 boss 定：**日志会话的执行配置由任务单向拥有**。
    /// 起因是一次实测：同一场助理日志会话里，巡检轮跑 `minimax`，人手动问的那轮跑
    /// `deepseek-v4-pro` —— 判据是每条 assistant message 自己的 `model` 字段（**不是**
    /// "转录里有没有 `model_change`"：运行时切模型 pi 不记新事件，那个判据会把切换看成没发生）。
    /// 两轮必须一致，所以"这场会话用哪个模型"只能有一个答案，而它在任务那一行。
    func owningTask(for sid: UUID) -> ScheduledTask? {
        // 1:1 是常态；万一两条任务引用了同一场会话，取**第一条有配置**的（否则"跟随全局"的那条
        // 会把另一条钉死的配置顶掉）。没有配置的也算 owning —— 它表示"这场会话归某人管，
        // 但配置跟随全局"，调用方据此**不读会话行**。
        let owners = scheduledTasks.filter { $0.logSessionId == sid }
        return owners.first(where: { $0.config != nil }) ?? owners.first
    }

    /// 日志会话的执行配置（`nil` = 不是日志会话，或任务还没配 —— dream 与"老库未重新保存过"）。
    func owningConfig(for sid: UUID) -> SessionConfig? {
        owningTask(for: sid)?.config
    }

    /// 这场会话是不是某个**助理任务的对话轮**？（纯读，不落任何状态 —— 冒烟直接断言这个。）
    ///
    /// 为什么靠 `logSessionId` 反查、而不是给会话打一个"我是助理会话"的标记:
    /// 标记要落库、要在两处维护一致性；而"这个会话是某个助理的日志"本来就能从任务表推出来
    /// —— `logSessionId` 是唯一真源，反查不会漂。**代价**（D3）: 助理被删之后反查必然失配，
    /// 于是这场会话**静默**变成普通会话。S12 的处理是**在删除那一刻留一行痕**（见 `deleteScheduled`），
    /// 而不是在这里猜 —— 从这里看不出"这曾是谁的会话"，任何补救都只能靠猜。
    ///
    /// ⚠️ 与巡检轮**不是同一段**：巡检轮是"到点了，看看"，对话轮是"人在跟你说话"。
    /// 两段都带账本，但对话轮的账本是**人的目标**要落地的地方，巡检轮的账本是**一轮判断的结果**。
    func assistantChatTurn(for sid: UUID) -> AssistantChatTurn? {
        guard let task = scheduledTasks.first(where: { $0.isAssistant && $0.logSessionId == sid })
        else { return nil }
        let ledger = handoffPath(for: task)
        return AssistantChatTurn(taskId: task.id,
                                 prompt: dialoguePrompt(for: task, ledgerPath: ledger, sid: sid),
                                 ledgerPath: ledger)
    }

    /// 开一个对话轮：**反查 + 记一笔**，同一个入口。`ChatStore.beginTurn` 只调这个。
    ///
    /// 为什么记一笔是必须的: 收尾时（`streamEnded` / 手动停）只有 `sid`，而"这一轮到底是不是
    /// 对话轮"在那里已经查不出来了 —— 普通会话与助理会话在那一刻长得一模一样。
    func beginDialogueTurn(sid: UUID) -> AssistantChatTurn? {
        guard let chat = assistantChatTurn(for: sid) else { return nil }
        dialogueTurns[sid] = DialogueTurnContext(taskId: chat.taskId, ledgerPath: chat.ledgerPath)
        return chat
    }

    private func dialoguePrompt(for task: ScheduledTask, ledgerPath: String, sid: UUID) -> String {
        var parts: [String] = []
        var head = """
        【助理任务 · 对话轮】
        这一轮是人在跟你说话，不是定时巡检。
        """
        // 2026-11-17：助理编辑器**不再有**手填目标（目标靠每轮下发 / 从账本长出来），
        // 所以这一行是按需出现的 —— 老助理写过目标的照样注入（那是它们唯一的长期上下文），
        // 新助理不写就不出现。空着还硬留一行「你的长期目标：」比不写更糟：模型会去猜那是什么。
        let goal = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { head += "\n你的长期目标：\(goal)" }
        parts.append(head)
        // P20 P3: 队伍与回执在**对话轮也要有** —— 人在这儿说"让财务对账再跑一次"，
        // 而它上一轮派的活刚交活；只在巡检轮注入的话，人在会话里问起来它一问三不知。
        let seg = teamSegments(for: task, sid: sid)
        if let team = seg.team, !team.isEmpty { parts.append(team) }
        parts.append("""
        【能做什么】
        这一轮**人在跟你说话**（可能在 App 里，也可能从飞书发过来 —— 同一场会话）。
        工具级审批在你这儿是**关的**：改文件、跑命令不会弹卡，也没人会拦你。
        所以边界只能靠你自己守：
        · **普通活直接做** —— 读、看、改普通文件、跑脚本、查日志。
        · **重要操作先说一句再动** —— 删东西、覆盖已有的重要内容、重启/停服务、动数据库、
          对外发消息（邮件 / 飞书 / 任何别人能看见的东西）、花钱。
          说清「我要做什么 / 为什么 / 做完能不能撤」，等人答「可以」再动手；
          他没答或者答得含糊，就先别动。
        · **他答不了的事**（缺材料、要他去别处点一下）—— 写进账本的「## 待你决定」。

        【写账本】
        账本在：\(ledgerPath)
        两条硬规矩：
        1. **整篇覆盖**: 把当前账本（在下面）连同这一轮的更新合成一篇，一次 write 写完。
        2. **「## 待你决定」的写法与账本契约里那一条完全相同**（一行一件、自带三要素、
           查得到的不许问、已有的原样保留）：那一节每一行都会主动发到他的飞书，
           所以改写措辞 = 再打扰他一次。它只放「要信息」的事，不放「要动手」的事。
        """)
        let open = (store?.findings ?? []).filter { $0.taskId == task.id && $0.status.isInboxVisible }
        if !open.isEmpty {
            let lines = open.map { f -> String in
                let tail = f.plan.isEmpty
                    ? "只有结论"
                    : "方案 \(f.plan.count) 步 · 第 \(f.planRev) 版"
                return "- \(f.title)（\(tail)）"
            }
            parts.append("【还开着的结论】\n" + lines.joined(separator: "\n"))
        }
        let h = (readHandoff(for: task)?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = WatchFindingService.handoffMaxChars
        if h.isEmpty {
            parts.append("【当前账本】\n还没有账本。这一轮该写就把五节写全，不该动就别写。")
        } else {
            let compact = WatchFindingService.handoffCompactThreshold
            parts.append("【当前账本】（\(h.count) 字 / 上限 \(cap)）\n\(h)"
                         + (h.count > compact ? "\n⚠️ 已超 \(compact) 字：这一轮顺手把「已完成」压到最近 "
                            + "\(WatchFindingService.archivedKeep) 条。" : ""))
        }
        parts.append(Self.watchLedgerContract)
        // 2026-11-23:「已发消息」（对话轮同理 —— "我昨天跟你说过 X" 多数发生在这里）。
        if let sent = sentMemory(task.id) { parts.append(sent) }
        // P20 P3:【派活回执】。同巡检轮的位置 —— 输出契约之前。
        if let receipts = seg.receipts, !receipts.isEmpty { parts.append(receipts) }
        // 回复契约放最后（它是"说完就结束"的那一段，后面不该再有话）
        parts.append(Self.dialogueOutputContract)
        return parts.joined(separator: "\n\n")
    }

    /// 对话轮的**回复**契约（与巡检轮不同: 对话是聊天, 不能整篇都是段头）。
    ///
    /// 两段: ① 正文（给人看的，随便写）② **可选**的提议块（要人拍板时才有）。
    /// 「可选」这一条是判据而不是客套: 每轮都写一块 = 每轮都往收件箱塞一条待办，
    /// 而收件箱是"要人决策的事"，不是聊天记录。
    static let dialogueOutputContract = """
    【输出契约】两段，顺序固定。
    ① 正文：直接回答人问的，想怎么写怎么写 —— **不要**写「结论：」这类段头。
    ② 提议（**可选**）：只有需要人拍板时才写，放在最后，块首单独一行 `【提议】`，块内三行：
    结论：一句话说清这是什么问题 / 要做什么。
    证据：文件:行号或读数。**不要写 `[1]` 这种观察编号** —— 对话轮没有采集轮次，那种编号一律按编造拒收。
    方案：编号步骤，每步写清「动哪个目标 · 怎么做 · 能不能撤销」；不需要动手就写「无」。
    不需要人拍板就**整块不写**。
    """

    /// 对话轮的收口：回复末尾有【提议】块就落一条 finding，没有就什么都不做。
    ///
    /// 三条刻意的选择：
    ///   · **不发通知、不触达**：人此刻就在看着这条回复。巡检轮那套"叫人"的机制搬过来，
    ///     等于对着正在跟你说话的人再喊一声。
    ///   · **不写时间线**：这条会话就是人正在看的那一屏，往库里追加一行而不进 UI，
    ///     表现是"重开才看得见"。结论本身在回复正文里，本来就看得见。
    ///   · **沿用 `WatchFindingService.plan`**（指纹去重 / 冷却 / 伪造引用拒收 / 落库形状）:
    ///     两条路各写一套判据，迟早有一套先漂。冷却在这里传 `nil` —— 人就在场，
    ///     冷却的语义（"别一天叫两次"）在这里不成立。
    func finishDialogueTurnIfNeeded(sid: UUID) {
        guard let ctx = dialogueTurns.removeValue(forKey: sid) else { return }
        guard let store, let p = store.persistence,
              let task = scheduledTasks.first(where: { $0.id == ctx.taskId }) else { return }
        let text = lastAssistantText(in: store, sid: sid)
        guard let block = WatchFindingService.proposalBlock(in: text) else { return }
        let report = WatchFindingService.parse(block)
        let existing = (try? p.loadFindings(taskId: task.id)) ?? []   // 只认本任务（同 ②）
        // `allowedExternalIds = []`: 对话轮不采集观察 ⇒ 任何 `[n]` 引用都只能是编造的。
        // `sourceId = 任务的项目`: 与巡检轮「项目隐式来源」同一条口径（`task.projectId` 就是来源 id）。
        let plan = WatchFindingService.plan(report: report, task: task, sessionId: sid,
                                           sourceId: task.projectId,
                                           allowedExternalIds: [],
                                           existing: existing, lastNotifyAt: nil, now: Date())
        guard let f = plan.finding else {
            // 解析失败 / 没有来源 / 编造引用 —— 三种都**不落库**，但留诊断（不然"它说提了，收件箱没有"）。
            if !plan.summary.isEmpty {
                Log.event("dialogue-proposal-skip", "why", String(plan.summary.prefix(120)))
            }
            return
        }
        try? p.upsertFinding(f)
        store.reloadFindings()
        Log.event("dialogue-proposal", ["task": String(task.id.uuidString.prefix(8)),
                                        "new": plan.isNew ? "1" : "0"])
    }

    /// 这一轮模型的**回复正文**（最后一条 assistant 文本）。
    ///
    /// 判据只有一处（`ChatStore.lastAssistantText`）—— 巡检轮、对话轮、飞书回传三个消费者
    /// 各抄一遍的话，"哪一条才算回复"就会有三份口径，而它们的错法完全一样（把工具卡当正文）。
    private func lastAssistantText(in store: ChatStore, sid: UUID) -> String {
        store.lastAssistantText(sid: sid)
    }

    // MARK: - P19 助理 · 执行轮（人对结论点了「采纳并执行」）

    /// 一次执行轮的上下文（收尾要用）。
    struct ExecFireContext: Equatable {
        let taskId: UUID
        let findingId: UUID
        /// `nil` = 这个助理没绑项目 ⇒ 这一轮没有快照（也就没有整轮回滚）。
        let projectPath: String?
        let authorizedSteps: [Int]
    }

    private var execFires: [UUID: ExecFireContext] = [:]

    /// 「采纳并执行」的启动结果 —— **每一种都要有话说**（`ChatStore` 翻成横幅）。
    /// 不做成 `Bool`: 拒绝的六种原因各有各的补救路径（去绑目录 / 等回合结束 / 改方案…
    /// 把六句合成一句"现在不能执行"等于让人自己猜）。
    enum ExecStart: Equatable {
        case started
        case rejected(String)
    }

    /// 起手执行一条结论。**顺序不许换**：闸门 → 状态 running → 快照 → 开回合。
    ///
    /// 三处刻意的选择：
    ///   · 状态先落 `running` 再快照 —— 快照按项目根打包，大仓库要几秒；这几秒里人到收件箱
    ///     看这条结论，它必须已经是"正在执行"，否则会连点两次（两个 tar 同时写同一个目录）。
    ///   · 快照**失败即回退**到 `authorized`（"人批准了但没起手"）—— 没有快照就不许写（§03 L3）。
    ///   · 执行轮走 `ephemeral: false`（真加载历史 =「刚才那一步为什么失败」指代得上），
    ///     与巡检轮相反；两者是**同一场日志会话**，所以人能在一条时间线上看完整条链路。
    func startExecution(findingId: UUID) -> ExecStart {
        guard let store, let p = store.persistence else { return .rejected("本地库不可用") }
        guard let f = store.findings.first(where: { $0.id == findingId }) else {
            return .rejected("找不到这条结论（可能刚被删）")
        }
        if let reason = WatchExecService.blockReason(finding: f) { return .rejected(reason) }
        guard let task = scheduledTasks.first(where: { $0.id == f.taskId }) else {
            return .rejected("它归属的助理任务已经不在了")
        }
        if task.isLegacyWaiting { return .rejected("旧类型的任务不能执行（重建为助理）") }
        // 2026-11-18: **不再要求绑项目**。原来这里是一道硬门（"没项目就没有围栏、也没有
        // 可回滚的范围 ⇒ 拒"），而围栏已经整层删了 ⇒ 这道门挡掉的是"整个功能用不了"
        // （助理跑在专属机器上时根本没有"项目目录"这个概念）。
        //
        // 代价写在时间线上，不藏着：没有项目 ⇒ **没有整轮快照、不能整轮回滚**。
        // 有项目就照旧做快照 —— 快照是"能回滚"这个承诺，不是审批的前置条件。
        let projectPath: String? = task.projectId
            .flatMap { pid in store.projects.first(where: { $0.id == pid })?.path }
            .flatMap { $0.isEmpty ? nil : $0 }
        guard let logId = ensureLogSession(for: task) else { return .rejected("建不出任务日志会话") }
        if store.runningTurns.contains(logId) { return .rejected("这场任务的回合还在跑，等它结束") }
        if store.runningTurns.count >= store.maxConcurrentTurns { return .rejected("并发已满") }

        let steps = f.plan.map(\.n)
        var running = f
        running.status = .running
        running.decidedAt = f.decidedAt ?? Date()
        try? p.upsertFinding(running)
        store.reloadFindings()
        let stepList = steps.map(String.init).joined(separator: ",")
        guard let projectPath else {
            // 没绑项目: **不快照，直接起执行轮**。时间线必须把"这次不能回滚"说出来 ——
            // 不说的话，人点回滚时会以为按钮坏了（那才是最难查的一种）。
            appendTimeline("── \(stamp()) 采纳并开始执行（方案第 \(f.planRev) 版 · 第 "
                           + stepList + " 步）—— 这个助理没绑项目，**这次不做快照、不能整轮回滚** ──",
                           to: logId)
            var started = f
            started.status = .running
            started.undoPath = nil
            try? p.upsertFinding(started)
            execFires[logId] = ExecFireContext(taskId: task.id, findingId: findingId,
                                               projectPath: nil, authorizedSteps: steps)
            beginExecTurn(task: task, finding: started, logId: logId,
                          projectPath: nil, steps: steps)
            return .started
        }
        appendTimeline("── \(stamp()) 采纳并开始执行（方案第 \(f.planRev) 版 · 第 "
                       + stepList + " 步），先做快照 ──",
                       to: logId)

        // 快照放后台: 它按项目根打包，在点击那一刻卡主线程 = "点了没反应"。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            var dir: String?
            do {
                dir = try WatchExecService.snapshot(findingId: findingId,
                                                    projectPath: projectPath, relativePaths: [])
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                guard let self, let store = self.store else { return }
                if let failure {
                    // 回 `open` 而不是 `authorized`: 收件箱只显 `open`（`isInboxVisible`），
                    // 落在 `authorized` 的那条会**从待处理里消失**，而它其实一步都没跑 ——
                    // 人只会觉得"点了执行, 然后它没了"。批准这件事没兑现，就该重新等人点。
                    try? store.persistence?.setFindingStatus(id: findingId, status: .open, at: nil)
                    self.appendTimeline("── 快照失败，没有开始执行（\(failure)）──", to: logId)
                    store.reloadFindings()
                    store.setTurnLimitNotice("快照失败，没有开始执行（磁盘满了？）", isError: true)
                    return
                }
                var started = f
                started.status = .running
                started.undoPath = dir
                try? store.persistence?.upsertFinding(started)
                self.execFires[logId] = ExecFireContext(taskId: task.id, findingId: findingId,
                                                        projectPath: projectPath,
                                                        authorizedSteps: steps)
                self.beginExecTurn(task: task, finding: started, logId: logId,
                                   projectPath: projectPath, steps: steps)
            }
        }
        return .started
    }

    private func beginExecTurn(task: ScheduledTask, finding: AgentFinding, logId: UUID,
                               projectPath: String?, steps: [Int]) {
        guard let store else { return }
        let prompt = Self.watchExecPrompt(goal: task.prompt, finding: finding)
        let msg = ChatMessage(role: .user, content: .text(prompt))
        store.persistMessage(msg, sid: logId)
        if store.selectedConversationId == logId { store.messages.append(msg) }
        let extra = WatchExecService.executionSystemPrompt(finding: finding,
                                                           authorizedSteps: steps,
                                                           projectPath: projectPath)
        // 没绑项目时 cwd 落 home —— 执行轮的相对路径就按它解（红线判据用的是同一个基准）。
        store.beginTurn(sid: logId, prompt: prompt, ephemeral: false,
                        cwd: projectPath ?? NSHomeDirectory(),
                        unattended: false,
                        extraSystemPrompt: extra,
                        executionGuard: ExecutionGuard(projectPath: projectPath,
                                                       allowedSteps: steps,
                                                       findingId: finding.id))
    }

    /// 执行轮的用户消息。观察与方案在 system 段（`executionSystemPrompt`），这里只写
    /// "人在批准什么" —— 三个月后翻这条日志，第一个问题永远是"当时它被授权干了哪件事"。
    static func watchExecPrompt(goal: String, finding: AgentFinding) -> String {
        """
        人已经批准了下面这条结论的方案，现在按方案执行。

        长期目标：\(goal)
        这条结论：\(finding.title)

        执行规则在注入的系统段里（已授权的步骤号、写入范围、收尾格式）。
        做不到就停下来写清楚卡在哪 —— 不要用别的方式绕过同一件事。
        """
    }

    /// 一轮执行落定后的收口。由 `ChatStore` 在**两个落定点**调（正常结束 / 手动停）。
    ///
    /// 判定顺序 = **先看机器证据，再看模型自己的说法**：
    ///   ① 过闸落痕里有 `denied_by_redline` / `drifted` ⇒ 一律 `failed`。
    ///      模型这时往往会写 `RESULT: DONE`（它觉得自己绕过去了）—— 那是我们要盖掉的谎。
    ///   ② 没有硬拦 ⇒ 认收尾段：`DONE` → resolved，`FAILED` → failed。
    ///   ③ 什么都没写 ⇒ **failed**。"无法证明"不许记成成功：resolved 是下一轮巡检的事实来源。
    func finishExecFireIfNeeded(sid: UUID) {
        guard let ctx = execFires.removeValue(forKey: sid) else { return }
        guard let store, let p = store.persistence else { return }
        let text = lastAssistantText(in: store, sid: sid)
        let result = WatchExecService.parseResult(text)
        let actions = store.transportFor(sid).execActions
        let blocked = actions.values
            .filter { $0.result == "denied_by_redline" || $0.result == "drifted" }
            .sorted { $0.step < $1.step }

        var note = result.summary
        let status: FindingStatus
        if !blocked.isEmpty {
            status = .failed
            let why = blocked.map { a -> String in
                let what = a.result == "drifted" ? "跑偏" : "被红线拦下"
                return a.step > 0 ? "第 \(a.step) 步\(what)" : what
            }.joined(separator: "，")
            note = note.isEmpty ? why : "\(why)；\(note)"
        } else {
            switch result.verdict {
            case .done:
                status = .resolved
            case .failed:
                status = .failed
            case .unclear:
                status = .failed
                if note.isEmpty { note = "没有按收尾格式给出 RESULT，按未完成记" }
            }
        }
        try? p.setFindingStatus(id: ctx.findingId, status: status, at: Date())
        // 落痕 = 每个步骤号一行（同一步多次过闸已经在 transport 侧并过了；"几次"进 `output`）。
        let now = Date()
        for a in actions.values.sorted(by: { $0.step < $1.step }) {
            try? p.upsertFindingAction(FindingAction(findingId: ctx.findingId, step: a.step,
                                                     kind: a.kind, target: a.target,
                                                     result: a.result,
                                                     output: a.count > 1 ? "×\(a.count)" : nil,
                                                     at: now))
        }
        let head = status == .resolved ? "执行结束：已解决" : "执行结束：未完成"
        let tail = note.isEmpty ? "" : "（\(note)）"
        appendTimeline("── \(stamp()) \(head)\(tail) ──", to: sid)
        // 从飞书批的那一次：把结果推回那个私聊。人不一定回 App 看时间线 ——
        // 而"批完之后没有下文"是最让人不敢再用的一种失败（2026-11-18）。
        store.remote.reportExecFinished(sid: sid, line: head + tail)
        if let undo = store.findings.first(where: { $0.id == ctx.findingId })?.undoPath {
            appendTimeline("── 快照留在 \(undo)，7 天内可从收件箱回滚 ──", to: sid)
        }
        store.reloadFindings()
        store.reloadFindingActions()
    }

    /// 启动时把"上一个进程里还在跑"的执行收回原状。
    ///
    /// 依据是结构性的: 调度与执行都在 App 进程内（不常驻），进程没了那轮执行就不存在了。
    /// **不收的后果是永久卡死** —— `running` 属于 `blocksExecution`（拒绝再执行），
    /// 而收件箱只显 `open` ⇒ 那条结论从此既点不动、也不出现在待处理里，只能靠翻历史会话
    /// 才想得起它存在。判据只看状态本身，不看时间戳: 进程刚起来不可能有真在跑的回合。
    @discardableResult
    func recoverInterruptedExecutions() -> Int {
        guard let store, let p = store.persistence else { return 0 }
        // 只取 running 那几行：这里原来读全表再 filter，而它跑在**每次启动**上。
        // 状态收窄在 SQL 里做，语义与"读全量再筛"逐行等价（`loadFindings` 的注释）。
        let stuck = (try? p.loadFindings(status: .running)) ?? []
        guard !stuck.isEmpty else { return 0 }
        for f in stuck {
            try? p.setFindingStatus(id: f.id, status: .open, at: nil)
            if let log = scheduledTasks.first(where: { $0.id == f.taskId })?.logSessionId {
                appendTimeline("── \(stamp()) 上次执行被中断（App 退出），这条结论已放回待处理 ──",
                               to: log)
            }
        }
        store.reloadFindings()
        return stuck.count
    }

    /// 整轮回滚（§03 L3）。**只还原文件，不改方案** —— 状态回 `open`：人回滚 = 承认
    /// 这次没解决（改回 `resolved` 就等于把问题从收件箱里藏起来了）。
    ///
    /// ⚠️ **后台解压、主线程回写**（2026-11-18 review 修）。原来这里是 @MainActor 上同步跑
    /// `tar -xzf` + `waitUntilExit`，而**同一条链的另一半**（`startExecution` 的快照）特意
    /// 放了后台、注释还写着"卡主线程 = 点了没反应" —— 同一件事的两半各写一种做法。
    /// 大项目回滚时界面会冻住几秒到几十秒，而人只会以为"点了没反应"，再点一次。
    ///
    /// ⚠️ `rollingBack` 挡连点：两个 tar 同时往同一目录解 = 互相覆盖（比不响应更糟）。
    /// 它是**能力层**的守卫，不是把按钮置灰 —— 置灰只是可见性。
    ///
    /// 签名从 `-> String?` 改成完成回调：解压的耗时不该让调用方同步等。
    /// 回调参数 = nil 表示成功，否则是人话的失败原因。
    func rollbackFinding(_ findingId: UUID, completion: @escaping (String?) -> Void) {
        guard !rollingBack.contains(findingId) else {
            completion("这一条正在回滚，等一下")
            return
        }
        guard let store, let p = store.persistence,
              let f = store.findings.first(where: { $0.id == findingId }) else {
            completion("找不到这条结论")
            return
        }
        guard let undo = f.undoPath, !undo.isEmpty else {
            completion("这条结论没有快照，回滚不了")
            return
        }
        rollingBack.insert(findingId)
        // 只把 tar 挪到后台；库与 @Published 全部回主线程做（与 `startExecution` 同一个形状）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var reason: String?
            do {
                if try WatchExecService.restore(findingId: findingId) == false {
                    reason = "快照还原失败（快照目录 \(undo)）"
                }
            } catch {
                reason = "快照还原失败：\(error)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.rollingBack.remove(findingId)
                if let reason {
                    completion(reason)
                    return
                }
                try? p.setFindingStatus(id: findingId, status: .open, at: nil)
                try? p.upsertFindingAction(FindingAction(findingId: findingId, step: 0, kind: "rollback",
                                                         target: undo, result: "restored",
                                                         output: nil, at: Date()))
                store.reloadFindings()
                store.reloadFindingActions()
                completion(nil)
            }
        }
    }

    /// 正在回滚的 finding（能力层的连点守卫，见 `rollbackFinding`）。
    private var rollingBack: Set<UUID> = []

    /// 时间线那一段的时:分。**恒中文、恒本地时区**（同 `recordFireSkip`）——
    /// 它是日志正文，不是界面文案，不进词表。
    private func stamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date())
    }

    // MARK: - P15.9 定向 dream（`由此 Dream`）

    /// 定向 dream 的启动结果 —— **每一种都要有话说**（`ChatStore` 负责翻成人话横幅）。
    /// 前三种在同一处判完再 fire, 所以它们不是"事后才知道", 而是"点了就知道"。
    enum DreamStart: Equatable {
        case started
        /// 这一场自己的回合在跑 / 上一场 dream 还在跑 / 并发已满
        case busy
        /// 这一场只有工具输出, 没有可提炼的正文
        case empty
        /// 库里没有 dream 任务（理论上删不掉, 兜底）
        case noTask
    }

    /// dream 的日志会话 —— 定时与定向**共用同一个**（用户的"dream 运行记录"只有一处），
    /// 取法见 `dreamIsRunning`（判据只在那里写一遍）。
    private var dreamTask: ScheduledTask? { scheduledTasks.first { Self.isDreamTask($0) } }

    /// 有没有一次 dream 正在跑。**判据只此一处**（纯函数，参数是"在途集合"与"任务表"）：
    /// 侧栏据此置灰菜单项、`startTargetedDream` 据此回 `.busy` —— 两处各写一遍
    /// `runningTurns.contains(log)` 迟早会漂。
    static func dreamIsRunning(_ running: Set<UUID>, tasks: [ScheduledTask]) -> Bool {
        guard let log = tasks.first(where: { isDreamTask($0) })?.logSessionId else { return false }
        return running.contains(log)
    }

    /// 「由此 Dream」能不能点 —— **一条规则, 两个调用点**（侧栏置灰 + `ChatStore` 兜底）。
    /// 三条禁用各有各的不可挽回性:
    ///   ① 这一场自己的回合在跑 ⇒ 读到的会是**半句话**；
    ///   ② 上一场 dream 还在跑 ⇒ 日志会话撞车, 起来也会被跳过（用户点了却没反应是最坏的反馈）；
    ///   ③ 任务日志会话 ⇒ 那是**机器跑出来的日志**, dream 自己那轮的候选也排除它们（自我循环）。
    static func canTargetDream(sid: UUID, running: Set<UUID>, tasks: [ScheduledTask]) -> Bool {
        if running.contains(sid) { return false }
        if dreamIsRunning(running, tasks: tasks) { return false }
        return !tasks.contains { $0.logSessionId == sid }
    }

    /// 对**指定的一场会话**做一次整场 dream（boss 2026-10-21：会话行菜单「由此 Dream」）。
    ///
    /// 与定时那轮的关系只有两条: ① 用同一个 dream 任务与同一个日志会话（于是档位/收口/spool
    /// 全部复用, 不需要第二套）；② **不推进 `lastRunAt`**（见 `runScheduledFire` 里那段注释）。
    @discardableResult
    func runTargetedDream(_ target: ConversationItem,
                          stats: (chars: Int, turns: Int, lines: Int)) -> DreamStart {
        guard let store else { return .noTask }
        guard let task = dreamTask else { return .noTask }
        // 空正文在这里挡掉: 否则会 fire 一个"没有【最近会话摘录】段"的回合, 让模型自己
        // 读到那条硬约束再空转结束 —— 花一次调用只为了说"没料"。
        guard stats.chars > 0 else { return .empty }
        if store.runningTurns.contains(target.id) { return .busy }
        if Self.dreamIsRunning(store.runningTurns, tasks: scheduledTasks) { return .busy }
        if store.runningTurns.count >= store.maxConcurrentTurns { return .busy }
        runScheduledFire(task, targeted: target)
        return .started
    }

    /// 定位/建立任务的日志会话（有项目归 project，无项目落平铺 Chats）。
    ///
    /// ⚠️ 抽出来是为了**巡检轮与执行轮共用同一个会话**：两处各抄一遍这段，早晚有一处少写
    /// 一行插入 —— 表现是"项目里多出一场没有归属的会话"，而功能照跑、零红灯。
    func ensureLogSession(for task: ScheduledTask) -> UUID? {   // internal — 冒烟直访（执行轮前置）
        guard let store else { return nil }
        // ── P19.2 S9 / Q5: 助理账本目录由 **App** 预建，不交给模型 ──────────────────
        // `write` 写不进不存在的目录；而「允许它自己建目录」等于再开一个路径口子，与
        // 「账本落点只有一个」冲突（S11 起巡检轮就有 `write` 了，这条是它的前置）。
        // 挂在这里是因为它是**两条轮次共同的唯一入口**（巡检轮与执行轮都先调它）；
        // `createDirectory` 幂等 ⇒ 目录被人删掉，下一次 fire 顺手补回来。
        // 只在助理档做：Cron 的 `tasks/` 目录一直由 `saveHandoff` 自己建，不动它。
        if task.isAssistant {
            try? FileManager.default.createDirectory(
                atPath: (handoffPath(for: task) as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
        }
        if let id = task.logSessionId, store.allConversations.contains(where: { $0.id == id }) {
            return id
        }
        let item = ConversationItem(title: task.name)
        if let pid = task.projectId {
            if let g = store.projects.firstIndex(where: { $0.id == pid }) {
                store.projects[g].items.insert(item, at: 0)
            }
            try? store.persistence?.insertChatSession(item, projectId: pid)
        } else {
            store.chats.insert(item, at: 0)
            try? store.persistence?.insertChatSession(item)
        }
        // 2026-11-20: 建会话的同一刻把**任务配置**写进去。
        // ⚠️ 不写的话它生下来是 **NULL 行**，而 NULL 行的语义是"应用 App 默认" ——
        //    App 默认 = **pi 探测上报的默认模型**（`app_default_config`），与任务配置毫无关系。
        //    于是只要有人点开这场会话，`selectConversation` 就会把那个默认值灌进全局，
        //    再经 `applySessionConfig` 推给它的 transport ⇒ 对话轮跑成默认模型。
        //    实测事故：助理日志会话里第 1 轮 minimax、第 2 轮 deepseek-v4-pro，而事后
        //    `sessions.config` 那行被 stamp 成的内容与 `app_default_config` **逐字段相同**
        //    —— 那就是默认值灌进来的指纹，不是谁选的。
        if let cfg = task.config {
            store.persistence?.saveSessionConfig(id: item.id, config: cfg)
        }
        return item.id
    }

    /// 把刚建好的日志会话**当场绑给任务**。
    ///
    /// 铁律: 任何"已经建了会话、但要走一条提前 return"的路径都必须先调它一次。
    /// 不绑的后果不是红灯, 而是**会话增殖**: 每个 cron 点新建一场、往里写一行、然后丢弃,
    /// 任务自己 `logSessionId` 永远是 nil ⇒ 用户点「任务日志」什么也看不到, 而磁盘上堆着
    /// 一堆只有一行的孤儿会话。（2026-10-21 模型 pin 那条路径踩过一次, 这里补成公共入口。）
    ///
    /// P19.2 S15: 第二个调用者是飞书入口（`RemoteChannelService.deliver`）—— 它同样
    /// "刚建好会话就要立刻开一轮", 且 `beginDialogueTurn` 靠 `logSessionId` 反查,
    /// 晚一步绑定, 那一轮就会被当成普通会话跑（没目标、没账本、没只读面）。
    func bindLogSession(taskId: UUID, logId: UUID) {
        guard let store, let i = scheduledTasks.firstIndex(where: { $0.id == taskId }),
              scheduledTasks[i].logSessionId != logId else { return }
        scheduledTasks[i].logSessionId = logId
        try? store.persistence?.upsertScheduled(scheduledTasks[i])
    }

    /// fire 被跳过时往日志会话追加一条时间线记录 (只落库, 不动 UI 状态——
    /// 跳过发生在别的回合进行中, 不能打断当前会话)。
    /// 日志会话尚未建立则放弃: 纯跳过不值得为它建会话, 任务真正跑起来时自然会建。
    private func recordFireSkip(_ task: ScheduledTask, at now: Date, reason: String) {
        guard let logId = task.logSessionId,
              store?.allConversations.contains(where: { $0.id == logId }) == true else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        appendTimeline("── \(fmt.string(from: now)) 因冲突跳过 (\(reason)) ──", to: logId)
    }

    /// 往日志会话追加一条时间线记录 —— **只落库、不动 UI**。
    ///
    /// 为什么不动 UI: 跳过与告警都发生在"别的回合可能正在进行"的时候, 往 `store.messages` 里塞
    /// 会打断当前会话。用户点开那个日志会话时, 他看到的顺序就是当时的顺序（`seq` 定的）。
    private func appendTimeline(_ text: String, to logId: UUID) {
        try? store?.persistence?.appendMessageEvent(
            sessionId: logId, ChatMessage(role: .user, content: .text(text)))
    }

    // MARK: - 漏跑清单 (P17 · 运行可靠性)

    /// 一个任务的漏跑汇总 —— **只留次数和最近一次**, 不留整个时刻数组。
    /// 口径来自产品（boss 拍板）: 补跑**只跑最近一次**, 前面的次数只用来表达严重程度。
    /// 顺带让内存与窗口长度**脱钩** —— `* * * * *` 漏 7 天是一万次, 存数组会白白堆一万个 Date。
    struct MissedFire: Identifiable, Equatable {
        let taskId: UUID
        let count: Int
        let last: Date
        var id: UUID { taskId }
    }

    /// 窗口起点 = **四个候选里最晚的那个**。
    ///   `floor`     —— 回溯上限 (`Tune.missedFiresLookbackDays`)
    ///   `createdAt` —— 兜住"新建任务从没跑过", 否则会误报它出生前的每一个 cron 点
    ///   `lastRunAt` —— 上次**真跑**的时刻（被 `recordFireSkip` 跳过的不算, 见那里的注释）
    ///   `ackAt`     —— 用户点过"忽略"的时刻
    /// 取最晚 = "上一次已知状态之后"; 三种来源（真跑 / 出生 / 认账）与上限之间是**并集**关系。
    static func missedWindowStart(task: ScheduledTask, now: Date, floor: Date, ackAt: Date?) -> Date {
        var start = max(floor, task.createdAt)
        if let last = task.lastRunAt { start = max(start, last) }
        if let ack = ackAt { start = max(start, ack) }
        return start
    }

    /// 窗口内"该跑却没跑"的汇总 —— **纯函数**（now / floor / ackAt 全是参数）⇒ 冒烟能造反例。
    ///
    /// 「没跑」是**确定**的而不是猜的: `lastRunAt` 只在 fire **真的起来**时写
    /// (`runScheduledFire` 末尾), 所以窗口内任何一个 cron 点只要真跑过, `lastRunAt` 就该比它更晚
    /// —— 反证。
    static func missedSummary(for task: ScheduledTask, now: Date,
                              floor: Date, ackAt: Date?) -> MissedFire? {
        guard task.enabled, let cron = task.cronExpr else { return nil }
        let start = missedWindowStart(task: task, now: now, floor: floor, ackAt: ackAt)
        guard start < now else { return nil }
        var count = 0
        var last: Date?
        // 起点 = **start 之后**的第一个整分（**开区间**）。「上次跑过」与「已认账」都意味着那个
        // 时刻已经处理完了, 不含它本身。
        // ⚠️ 这里踩过一次: 写 `.rounded(.up)` 在 start **恰好是整分**时原地不动 ⇒ 把 `lastRunAt`
        //    那一刻也算成漏跑（实测 3 变 4) —— 正是冒烟那条"恰好 3 次"抓出来的。
        var t = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60)
        let cal = Calendar.current
        while t <= now {
            // 先在"分钟"位上筛一道: cron 的分钟集通常很窄, 这一步挡掉绝大部分迭代
            // （逐分钟 × 7 天 = 10080 次, 不筛的话每次都要白做一遍日历分解）。
            if cron.minutes.contains(cal.component(.minute, from: t)), cron.matches(t) {
                count += 1
                last = t
            }
            t = t.addingTimeInterval(60)
        }
        guard let lastAt = last else { return nil }
        return MissedFire(taskId: task.id, count: count, last: lastAt)
    }

    /// ack 的 KV 键（每任务一条; 值 = 认账时刻的 epoch 秒）。
    static func missedAckKey(_ taskId: UUID) -> String { "sched_missed_ack_\(taskId.uuidString)" }

    /// 重算全部任务的漏跑清单。
    func refreshMissedFires(now: Date = Date()) {
        guard let store else { missedFires = []; return }
        let floor = now.addingTimeInterval(-Double(Tune.missedFiresLookbackDays) * 86400)
        var out: [MissedFire] = []
        for task in scheduledTasks where task.enabled && task.role != .worker {
            // 项目已删的任务**不算漏跑**: 它每次到点都会被 `recordFireSkip` 跳过, 而那里
            // **不写** `lastRunAt` ⇒ 它会永远赖在清单里。那是配置坏了, 有别的提示位。
            if let pid = task.projectId, !store.projects.contains(where: { $0.id == pid }) { continue }
            let ack = store.persistence?
                .loadSettingText(key: Self.missedAckKey(task.id))
                .flatMap(Double.init)
                .map { Date(timeIntervalSince1970: $0) }
            if let m = Self.missedSummary(for: task, now: now, floor: floor, ackAt: ack) {
                out.append(m)
            }
        }
        missedFires = out.sorted { $0.last > $1.last }   // 最近漏的排前面
    }

    /// 补跑**最近的一次**（boss 拍板: 不管漏了几次都只跑最近那次）。
    /// 内容层面为什么够: P17 的水位 `min(now - 36h, lastRunAt)` 本来就会把窗口拉长, 补这一次
    /// 就把漏掉那几天的料一起捞回来了; 真去补 N 次反而会在同一个日志会话里连投 N 个回合,
    /// 后面几个全被"在途则跳过"的保护挡掉 —— 白点。
    func catchUpMissedFire(_ taskId: UUID) {
        guard let task = scheduledTasks.first(where: { $0.id == taskId }) else { return }
        // P20 P4: worker 不在漏跑清单里（`refreshMissedFires` 已排除），这里是第二道 ——
        // 手滑把 id 传进来也不该让它自己跑一轮。
        guard task.role != .worker else { return }
        runScheduledFire(task)
        // ⚠️ 无论这次 fire 是否被在途保护跳过, 都要认账 —— 否则 `lastRunAt` 没前移, 条目原样留着
        // ⇒ 用户看到的是"点了没反应"。同 `runNowButton` 那条"禁用按钮反而把记录藏起来"的理由。
        ignoreMissedFire(taskId)
    }

    /// 认账: 这批漏跑我看见了, 不补。**要落库**是因为下次开机不该再问一遍 ——
    /// 没有这一条, 用户"决定不补"这个动作就没有落点, 清单会一直挂在那儿。
    ///
    /// `at` 只给冒烟注入用（默认 = 真实的现在, 产品行为不变）: 落库的 ack 与紧接着那次
    /// `refreshMissedFires` 必须是**同一个 now**, 否则"忽略后清单空"会随跑的时刻漂 ——
    /// 2026-10-19 CI 在 01:44 UTC 跑红过一次, 而本机 09:44 是绿的（差在有没有过当天 03:00）。
    func ignoreMissedFire(_ taskId: UUID, at now: Date = Date()) {
        store?.persistence?.saveSettingText(
            key: Self.missedAckKey(taskId), value: String(now.timeIntervalSince1970))
        refreshMissedFires(now: now)
    }

    // MARK: - 交接文件 (P3.9 · P19.2 S9 分家)

    /// 交接文件路径。**P19.2 S9: 两档分家** ——
    ///   · Cron（`.execute` / `.legacyWaiting`）→ `<项目>/.mangox/tasks/` · `~/.mangox/task-memory/`
    ///   · 助理（`.assistant`）→ `<项目>/.mangox/assistant/` · `~/.mangox/assistant-memory/`
    ///
    /// 为什么非分不可：两者在文件树里**长得一模一样**，而语义差得远 —— 一份是「跑过一次留下的
    /// 痕迹」，一份是「这个目标三个月的进度」。混在一个目录里，人打开文件树分不出哪份是哪份，
    /// 而这份差别正是 P19.2 全部功能的立足点（账本可读、可催、可回「无目标」）。
    ///
    /// ⚠️ **Cron 的那两个字符串一个字节都不许动**（「Cron 档零改动」是硬约束）。所以这里只抽
    /// **公式**、不合并两档：合并之后「助理路径」与「Cron 路径」会变成同一个表达式，改一处就
    /// 动另一处 —— 而那条路径是回落 / 快照归属 / 清理全部逻辑的锚。
    func handoffPath(for task: ScheduledTask) -> String {
        task.isAssistant ? assistantHandoffPath(for: task) : legacyHandoffPath(for: task)
    }

    /// Cron 的公式。**逐字节等于 P19.2 之前的 `handoffPath`** —— `CaseHandoffPath` 四条真值表
    /// 按字面拼期望值钉着（不是拿它和自己比）。
    private func legacyHandoffPath(for task: ScheduledTask) -> String {
        resolvedHandoffPath(for: task,
                            projectSubdir: ".mangox/tasks",
                            homeSubdir: ".mangox/task-memory")
    }

    private func assistantHandoffPath(for task: ScheduledTask) -> String {
        resolvedHandoffPath(for: task,
                            projectSubdir: ".mangox/assistant",
                            homeSubdir: ".mangox/assistant-memory")
    }

    /// 唯一那条公式：项目在 ⇒ `<项目>/<projectSubdir>`；否则 ⇒ `~/<homeSubdir>`。
    ///
    /// ⚠️ **「项目已删」也走 home** —— 原实现是 `if let pid, let p` **两者都成立**才用项目路径。
    /// 改写成 `flatMap` 时很容易只剩「有没有 pid」这一半，那样「项目删了但任务还在」的任务会
    /// 拼出一个已不存在目录下的路径（写必失败，而零红灯）。真值表 ③ 就是为了这条。
    private func resolvedHandoffPath(for task: ScheduledTask,
                                     projectSubdir: String, homeSubdir: String) -> String {
        let dir: String
        if let pid = task.projectId,
           let p = store?.projects.first(where: { $0.id == pid })?.path {
            dir = p + "/" + projectSubdir
        } else {
            dir = NSHomeDirectory() + "/" + homeSubdir
        }
        return dir + "/\(task.id.uuidString).md"
    }

    /// 读交接文件 (磁盘为准, 零缓存)。返回 nil = 文件不存在。
    ///
    /// **S9 给的回落**: 助理刚换目录，旧的那份还躺在 `<项目>/.mangox/tasks/` 里。不回落的话，
    /// 换版本那一刻它读到的是「空」⇒ 几个月的进度被当成「第一轮」，而这件事**零红灯**
    /// （指令照跑、结论照出，只是它不再记得自己在追什么）。
    ///
    /// 三条口径：
    ///   ① 新位置有文件 ⇒ 就用新的，**不看旧的**；
    ///   ② 新位置没有 ⇒ 去旧位置读**一次**（不是搬、不是删 —— 回落是只读的）；
    ///   ③ 一旦新位置有了文件，就**不再**回落 —— 否则两份真源同时活着，改了新的旧的还在顶。
    ///      ⚠️ 遗留：旧文件我们不删。所以「新文件被手动删掉」会把旧账本复活一次 ——
    ///      这是刻意的取舍（宁可在极端情况读到旧账，也不在正常路径上删人的文件）。
    func readHandoff(for task: ScheduledTask) -> (content: String, updatedAt: Date?)? {
        if let current = readHandoffFile(at: handoffPath(for: task)) { return current }
        guard task.isAssistant else { return nil }
        return readHandoffFile(at: legacyHandoffPath(for: task))
    }

    private func readHandoffFile(at path: String) -> (content: String, updatedAt: Date?)? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return (content, attr[.modificationDate] as? Date)
    }

    /// 写交接文件 (编辑器保存 / 兜底重建共用)。
    @discardableResult
    func saveHandoff(for task: ScheduledTask, content: String) -> Bool {
        let path = handoffPath(for: task)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try? content.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - Prompt 组装 (P3.9/P3.10)

    /// 持续模式 prompt 组装 (P3.9): 交接文件全文 (长期记忆) + 近期运行摘录 (短期上下文)
    /// + 本次指令 + 写回指令。文件丢失时从日志会话 (run-log) 静默重建。
    /// P19: 条件值守档已整体移除，这里不再有「等待协议」分支 —— 旧任务归 `.legacyWaiting` 且不 fire。
    /// P9.1b 惯例: **internal** —— 冒烟要断言"存量旧行不影响 dream"（那个失效模式在别处零红灯）。
    func buildScheduledPrompt(_ task: ScheduledTask, targeted: ConversationItem? = nil) -> String {
        // P15.6: dream 的输入 = **App 侧算好的有界摘要**, 挂在指令之后一起发出去。
        // 刻意不写进 `task.prompt`: 那一段是用户在编辑器里看见、会去改的东西, 而摘要是
        // **每次 fire 现算的**派生数据 —— 混进去会让"任务指令"这一栏每次都不一样。
        // 摘要在指令**之后**: 指令是"怎么干", 摘要是"料", 先立规矩再给料。
        // 摘要为空（最近没有会话）⇒ 只有指令: prompt 里那条"没有摘录段就直接结束"的硬约束
        // 负责让它体面收场, 不需要在这里造一个空段。
        // P15.6b: 指令正文取 `dreamFirePrompt`（= **常量**）, **不是** `task.prompt`。
        if Self.isDreamTask(task) {
            // P15.9 定向: 只编这一场 + 追加一段范围说明。指令常量**一个字不动**
            // （它同时是定时那轮的指令，也是落库成任务行的 `prompt`）。
            if let targeted {
                return Self.dreamFirePrompt(digest: buildDreamDigest(target: targeted),
                                            notes: buildDreamNotes(),
                                            scopeNote: Self.dreamTargetedScopeNote)
            }
            return Self.dreamFirePrompt(digest: buildDreamDigest(), notes: buildDreamNotes())
        }
        guard task.continuous else { return task.prompt }
        var sections: [String] = []
        // 长期记忆: 交接文件; 丢失且有日志 → 从 run-log 静默重建
        var handoff = readHandoff(for: task)?.content
        if (handoff ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let rebuilt = rebuildHandoff(from: task.logSessionId) {
                saveHandoff(for: task, content: rebuilt)
                handoff = rebuilt
            }
        }
        if let h = handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            sections.append("【持续任务 · 工作日志】\n\(h)")
        }
        // 短期上下文: 最近一次运行的产出原文 (取最后一条 assistant text, 截取上限)
        if let logId = task.logSessionId {
            let tail = store?.replayMessages(for: logId).compactMap { msg -> String? in
                guard case .text(let s) = msg.content, !s.isEmpty,
                      msg.role == .assistant else { return nil }
                return s
            }.last
            if var t = tail {
                if t.count > Tune.scheduleHistoryCharLimit {
                    t = "…(更早的已省略)\n" + t.suffix(Tune.scheduleHistoryCharLimit)
                }
                sections.append("【近期运行摘录】\n\(t)")
            }
        }
        sections.append("【本次指令】\n\(task.prompt)")
        return sections.joined(separator: "\n\n") +
            "\n\n请在了解此前执行情况的基础上继续本次任务, 并在结束后把关键进展、当前状态与待办更新写入交接文件: \(handoffPath(for: task))"
    }

    /// run-log 兜底: 从日志会话的 text 消息重建交接文件内容 (过滤分隔标记, 截取上限)。
    /// 指令侧只取【本次指令】段 (历史注入模板不入档, 防层级滚雪球)。
    private func rebuildHandoff(from logId: UUID?) -> String? {        guard let logId, let store else { return nil }
        let lines = store.replayMessages(for: logId).compactMap { msg -> String? in
            guard case .text(let s) = msg.content, !s.isEmpty,
                  !s.hasPrefix("──") else { return nil }   // 过滤运行分隔
            if msg.role == .user {
                if let r = s.range(of: "【本次指令】\n") {
                    return "[指令] " + s[r.upperBound...]
                }
                return nil   // 注入模板全文不入档
            }
            return "[产出] \(s)"
        }
        guard !lines.isEmpty else { return nil }
        var record = lines.joined(separator: "\n")
        if record.count > Tune.scheduleHistoryCharLimit * 2 {
            record = "…(更早的已省略)\n" + record.suffix(Tune.scheduleHistoryCharLimit * 2)
        }
        return record
    }

    // MARK: - P15.3 dream 收口（spool → note_proposals）

    /// 一次 dream fire 结束时调 —— 把 spool 收进 `note_proposals`, 然后删掉 spool。
    ///
    /// 两条路都要收: **落定**（`agentSettled`）与**手动停**（`stopTurn`）——「跑不完不算失败」。
    func finishDreamFireIfNeeded(sid: UUID) {
        guard let spool = dreamFires.removeValue(forKey: sid) else { return }
        let target = dreamTargets.removeValue(forKey: sid)
        guard let store, let p = store.persistence else { return }
        // 顺序 = 读 → 解析 → 落表 → 删。**删在最后**: 落表失败时 spool 还在,
        // 而它在下次 fire 开头会被清掉（那时这批也真的没别的出路了）。
        guard let text = try? String(contentsOfFile: spool, encoding: .utf8) else { return }
        let roots = store.knowledge.allKnowledgeBases.map { (id: $0.id, path: $0.path) }
        let parsed = NoteProposalSpool.parse(text, roots: roots)
        // P15.9 去重: 同一场会话被定向跑两次（或定向跑完又被定时那轮吃一遍）⇒ 待审队列里会躺
        // 两行一模一样的（同根 + 同目标路径 + 同标题）。判据只认这三样 —— 内容是整篇、标题相同
        // 就够说明"这是同一条洞见"。**只在待审队列里去重**: 人已经丢弃过的再来一次是正常的新提议。
        var seen: Set<String> = []
        for existing in (try? p.loadNoteProposals()) ?? [] {
            seen.insert(Self.proposalKey(rootId: existing.rootId, path: existing.targetPath,
                                        title: existing.title))
        }
        var kept = 0
        var duplicates = 0
        for d in parsed.items {
            let key = Self.proposalKey(rootId: d.rootId, path: d.targetPath, title: d.title)
            if seen.contains(key) { duplicates += 1; continue }
            seen.insert(key)
            let proposal = NoteProposal(
                id: UUID(), rootId: d.rootId, kind: d.kind, targetPath: d.targetPath,
                baseHash: d.baseHash, title: d.title, content: d.content, reason: d.reason,
                sources: d.sources, createdAt: .now, status: .pending, sessionId: sid.uuidString)
            if (try? p.appendNoteProposal(proposal)) != nil { kept += 1 }
        }
        store.knowledge.reloadProposals()
        // ⚠️ 这话必须说 —— 尤其是被拒的那几条。spool 马上就删了, 现在不写,
        //    用户只会看到"这次怎么才出两条", 而不知道另外三条死在了路上。
        appendTimeline(Self.dreamSummary(kept: kept, rejects: parsed.rejects, duplicates: duplicates),
                       to: sid)
        // P15.9: 定向跑完要**在用户看得见的地方**说一声 —— 他多半正看着自己那一场会话,
        // 不会去翻 dream 的日志会话。文案在 `ChatStore` 里成型（本文件在 L10n 的
        // `EXCLUDE_FILES` 里, 恒中文只对"落库的时间线"成立, 横幅是界面文案）。
        if let target, kept > 0 || duplicates > 0 {
            store.notifyTargetedDreamFinished(targetId: target, kept: kept)
        }
        try? FileManager.default.removeItem(atPath: spool)
    }

    // MARK: - P19 助理收尾（结论落库 / 工作日志写盘 / 触达）

    /// 一轮巡检落定后的收口。由 `ChatStore` 在**两个落定点**调（正常结束 / 手动停）。
    ///
    /// 顺序 = 读回复 → 解析 → 校验 → 决定 → 写。**写在最后**: 判据（`WatchFindingService.plan`）
    /// 是纯函数，落库与通知只是它的执行者 —— 这样"同指纹不重发 / 冷却"这类判断能在冒烟里对拍。
    func finishWatchFireIfNeeded(sid: UUID) {
        guard let ctx = watchFires.removeValue(forKey: sid) else { return }
        guard let store, let p = store.persistence,
              let task = scheduledTasks.first(where: { $0.id == ctx.taskId }) else { return }
        let text = lastAssistantText(in: store, sid: sid)
        let report = WatchFindingService.parse(text)
        // **按任务收窄**：下面两处（同指纹去重、`lastNotifyAt`）本来就只认 `task.id`，
        // 读全表等于把别的助理上千行 JSON 解一遍再丢掉。跨任务的信息这里一个都不需要。
        let existing = (try? p.loadFindings(taskId: task.id)) ?? []
        // "上次提给人是多久前" 用这个任务最近一条结论的时间近似。**够用且无状态** ——
        // 真正的通知时刻要多存一列, 而它只在这条冷却判据里用得上（§04 冷却按任务）。
        let lastNotifyAt = existing.filter { $0.taskId == task.id }.map(\.createdAt).max()
        let plan = WatchFindingService.plan(report: report, task: task, sessionId: sid,
                                           sourceId: ctx.sourceId,
                                           allowedExternalIds: ctx.allowedExternalIds,
                                           existing: existing, lastNotifyAt: lastNotifyAt,
                                           now: Date())
        if let f = plan.finding { try? p.upsertFinding(f) }
        // ── 账本写盘: **App 不写了**（P19.2 S11 翻面；2026-11-16 的「由 App 写」已退役）──
        //
        // 历史: S11 之前巡检轮没有写工具，让它自己写是做不到的事，所以内容进输出契约、
        // 落盘归 App。S11 给了它一支笔（`write` 来自档位），于是这里只把
        // 回复里的「工作日志」段**有意忽略**。
        //
        // 为什么必须退役而不是留着: 两个写者 = 两份真源。模型这一轮刚写完的账本，
        // 会被 App 用"回复里那一段"覆盖一遍 —— 而那段是模型**凭记忆复述**的，不是它写进
        // 文件的那一份。表现是"账本里的归档总比它说过的少一条"，且没有任何红灯。
        //
        // 为什么**不删**解析器与 `handoffMaxChars`: 老回复里这一段还会出现（模型习惯难改），
        // 忽略它就够了；而 `plan` 的"超长拒收"仍是纯函数级判据（`CaseWatchFindings` ⑩），
        // 留着当"这段文本再大也不会撑爆什么"的兜底。
        // ⚠️ 若哪天要恢复 App 写盘，**先删掉模型那一侧的写**，别两处同时写。
        _ = plan.handoff
        if !plan.summary.isEmpty { appendTimeline(plan.summary, to: sid) }
        if plan.shouldNotify, let f = plan.finding {
            // 系统通知仍受**全局开关**管（`notifyWatchFinding` 里判）; 任务级 `notify.system`
            // 是它上面的一层：人可以在"全都收"的前提下，把某一条吵人的任务单独静音。
            if task.notify.system { store.notifyWatchFinding(f, taskName: task.name) }
            deliverFinding(f, task: task, logId: sid)
        }
        // ── 「## 待你决定」→ findings（P19.4）────────────────────────────────
        // 为什么这一节必须落地成 findings: 无人值守下 fire 恒 `unattended` ⇒ 审批卡**根本不发**
        // （`beginTurn` 里 `askApproval: false`；围栏那一层 2026-11-18 也整层删了，见 D8）。
        // 所以"重要操作等人确认 / 缺材料问人"这两件事在 fire 轮**没有任何出路** ——
        // 而模型能表达它们的唯一地方就是账本这一节，账本却**没有触达**：人永远不会知道。
        //
        // 落成 `info` finding 之后，催（`WatchNagService.due`）、催的上限、系统通知、飞书私聊
        // 全部自动接上，不必为"提问"再开一条外发通道（那会多一份会漂的频控规则）。
        //
        // ⚠️ **落库全部、外发只发第一条**。一次 fire 有五件在等人决定，就往飞书塞五条消息 ——
        //    人的反应是把通道整个关掉。第一条已经足够让人知道"它有事问你"，剩下的在 App 里
        //    逐条看；而没被回答的那些，催会按冷却和上限一轮一轮盯着（这才是它们的常态）。
        let ledgerText = readHandoff(for: task)?.content ?? ""
        let waiting = WatchFindingService.waitingFindings(
            ledger: AssistantLedger.parse(ledgerText),
            taskId: task.id, sessionId: sid, existing: existing, now: Date())
        for (i, f) in waiting.added.enumerated() {
            try? p.upsertFinding(f)
            guard i == 0 else { continue }
            if task.notify.system { store.notifyWatchFinding(f, taskName: task.name) }
            deliverFinding(f, task: task, logId: sid)
        }
        if !waiting.summary.isEmpty { appendTimeline(waiting.summary, to: sid) }
        store.reloadFindings()
    }

    // MARK: - P19 S7 结论推送：只剩飞书私聊（只发不收）

    /// 把一条结论推到**助理绑定的那个机器人的私聊**。
    ///
    /// 2026-11-18 晚（boss）: 编辑器里的「触达」卡整张删了 —— 系统通知由全局开关管、
    /// 飞书由「入口」绑没绑机器人决定、日预算挪进了模型卡。**邮件外发通道一并删除**：
    /// 它唯一的配置入口就是那张卡，卡没了还留着投递路径 = "我看不见它，但它还在发信"。
    /// （底层 `MailTransport` / `CurlMailTransport` 保留 —— 设置页的"测试连接"用它。）
    ///
    /// ⚠️ **推不出去也要写进时间线**："没收到"和"没发"必须长得不一样。
    /// ⚠️ 只在**助理**档走这一句：入口（机器人绑定）是助理才有的东西。不加这个守卫的话，
    ///    每条 Cron 任务每次跑完都会落一行「没绑机器人」—— 真话，但是噪音。
    ///
    /// internal — 冒烟直访：判据要打在**真路径**上。
    func deliverFinding(_ f: AgentFinding, task: ScheduledTask, logId: UUID) {
        guard let store, task.kind == .assistant else { return }
        let payload = WatchNotifyService.payload(finding: f, taskName: task.name)
        // 同步（`link.send` 只是往桥的 stdin 写一行，没有网络等待）。
        let outcome = store.remote.pushFinding(payload, taskId: task.id)
        appendTimeline("── 触达 · 飞书私聊: \(outcome.text) ──", to: logId)
    }

    // MARK: - P19 S7 日预算

    /// 账本的日键 = **本地日** `yyyy-MM-dd`。
    /// 存 UTC 日会让 +08:00 的人在早上 8 点前被算进昨天，而那正是"每天 9 点巡检"最常撞的时刻。
    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// 某任务今天已经烧了多少 token。
    func tokenSpentToday(_ taskId: UUID, now: Date = Date()) -> Int {
        (try? store?.persistence?.tokenUsage(taskId: taskId, day: Self.dayKey(now))) ?? 0
    }

    /// 某任务**今天约了几条**回看（编辑器的「今日已约 N 次」；口径 = `created_at` 的本地日）。
    /// 与配额闸读同一处、同一个 since，免得界面上写 2、判据却按 3 拦。
    func followUpsToday(_ taskId: UUID, now: Date = Date()) -> Int {
        (try? store?.persistence?.followUpCountSince(
            taskId: taskId, since: Calendar.current.startOfDay(for: now))) ?? 0
    }

    /// 超预算的人话原因；nil = 还没超（或这条任务没设上限）。
    ///
    /// ⚠️ 超预算的处理是**跳过并落痕**，不是换一个便宜模型接着跑：降级会让人永远不知道
    /// 自己设的上限已经生效，而结论质量变了却没人知道为什么（§04）。这是本版唯一的取舍。
    func budgetBlockedReason(_ task: ScheduledTask, at now: Date = Date()) -> String? {
        guard task.dailyTokenBudget > 0 else { return nil }
        let spent = tokenSpentToday(task.id, now: now)
        guard spent >= task.dailyTokenBudget else { return nil }
        return "日预算已满（今日已用 \(spent) / 上限 \(task.dailyTokenBudget) token），这次跳过"
    }

    /// 回合落定后记一笔 token 账 —— 预算闸的**事实来源**。
    ///
    /// 只记**任务自己发起的回合**（巡检轮 / 执行轮）。人自己问的话不吃任务的预算 ——
    /// 否则"我去问它两句"会把今天的巡检名额吃掉，而时间线上冒出一句「日预算已满」，
    /// 人根本联想不到是自己聊天聊掉的。
    ///
    /// ⚠️ 2026-11-18 review 修：原来只有 `logSessionId == sid` 一条判据，而 D8 之后
    /// 「会话 = 助理 = 机器人」—— 助理的对话轮**就是**那条会话 ⇒ 上面那句承诺根本没兑现
    /// （注释写着"包括助理的对话轮"，代码做不到）。现在补上：对话轮在 `beginDialogueTurn`
    /// 里登记、在 `finishDialogueTurnIfNeeded` 里认领，而本函数**排在两者之间**
    /// （`ChatStore` 的 `.streamEnded`：先记账、后 finish*）⇒ 此刻字典里还有它。
    ///
    /// 按 `turnStart` 过滤而**不是**整场会话求和：日志会话装着几十次 fire，全求和等于
    /// 第二次 fire 就爆预算。
    func recordScheduledUsage(sid: UUID, turnStart: Date?, projection: [ChatMessage]) {
        guard let turnStart, let p = store?.persistence else { return }
        guard dialogueTurns[sid] == nil else { return }   // 这一轮是人在跟它说话，不算任务的账
        guard let task = scheduledTasks.first(where: { $0.logSessionId == sid }) else { return }
        let tokens = projection.reduce(0) { acc, m in
            guard m.role == .assistant, let u = m.usage, m.timestamp >= turnStart else { return acc }
            return acc + u.totalTokens
        }
        guard tokens > 0 else { return }
        try? p.addTokenUsage(taskId: task.id, day: Self.dayKey(Date()), tokens: tokens)
    }

    /// 提案的身份 = **根 + 目标路径 + 标题**（去重用；三样都是 dream 自己在提案里写的，
    /// 不掺 `base_hash` —— 那份指纹每次现取, 同一条洞见两次跑必然不同）。
    /// `rootId` 是 `NoteProposal` 里的那一份（String，不是 UUID）。
    static func proposalKey(rootId: String, path: String, title: String) -> String {
        "\(rootId)|\(path)|\(title)"
    }

    /// 收口那句话。**恒中文**（本文件在 `EXCLUDE_FILES` 里, 且它与 `recordFireSkip` 同性质:
    /// 是一行**日志时间线**, 不是界面文案）。
    static func dreamSummary(kept: Int, rejects: [SpoolRejection], duplicates: Int = 0) -> String {
        var s = "── dream 收口: \(kept) 条提案待审 ──"
        // 超出约定粒度的**必须说出来**。`Tune.dreamMaxProposals` 是 prompt 里的软约束,
        // 而软约束唯一的执法方式就是"没守住时看得见" —— 收口这一行是它唯一的着落点。
        // ⚠️ 不在这里截断: 砍掉的可能是这批里最值钱的一条, 那比"多两条要审"坏得多。
        if kept > Tune.dreamMaxProposals {
            s += "\n      超出约定粒度 \(Tune.dreamMaxProposals) 条 —— 这批偏碎, 可留意是否该并成一篇"
        }
        // 去重数必须单列: 否则"这条我上次提过"看起来就像"模型这次没提"。
        if duplicates > 0 { s += "\n      跳过 \(duplicates) 条已在待审队列里的重复提案" }
        guard !rejects.isEmpty else { return s }
        let detail = rejects.prefix(5).map { "第 \($0.line) 行 \(rejectText($0.reason))" }
            .joined(separator: "; ")
        return s + "\n      被拒 \(rejects.count) 条（\(detail)）"
    }

    /// 拒收原因的人话。**只服务上面那行日志** —— 提案列表里不会出现它（被拒的不进表）。
    private static func rejectText(_ r: ProposalRejection) -> String {
        switch r {
        case .notJSON: "不是合法 JSON"
        case .notAnObject: "不是 JSON 对象"
        case .kindUnknown(let k): "不认识的 kind（\(k)）"
        case .missingField(let f): "缺字段 \(f)"
        case .emptyContent: "内容为空"
        case .emptySources: "没有来源"
        case .sourceKindUnknown(let k): "不认识的来源类型（\(k)）"
        case .baseHashRequired: "merge / replace 缺 base_hash"
        case .targetNotAbsolute: "target_path 不是绝对路径"
        case .unknownRoot: "target_path 不在任何笔记根下"
        }
    }

    // MARK: - 侧栏徽标 (P3.10)

    /// 侧栏任务日志会话标志 (定时任务 clock / 助理 sparkles)
    func scheduledBadge(for sessionId: UUID) -> String? {
        for t in scheduledTasks where t.logSessionId == sessionId {
            return t.kind == .assistant
                ? "sparkles"
                : "clock.badge"
        }
        return nil
    }
}
