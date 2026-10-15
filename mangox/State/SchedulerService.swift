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

    /// 等待型任务完成标记 (HTML 注释: Markdown 渲染不可见, 客户端可解析)
    static let doneMarker = "<!--task: done-->"

    // P3.6: 本地定时任务 (仅 App 运行期生效, launchd 后置)
    @Published var scheduledTasks: [ScheduledTask] = []
    @Published var showScheduledPanel: Bool = false
    /// P17 · 运行可靠性: 睡眠 / 长挂起期间漏跑的任务（由 `refreshMissedFires` 重算）。
    /// 空 = 侧栏那块 UI 整个不出现。
    @Published var missedFires: [MissedFire] = []
    private var schedulerTimer: Timer?
    private var lastSchedulerMinute: Int = 0
    /// P17: 防 App Nap 的常驻断言。**必须强持有** —— 头文件明说对象一旦被释放断言就自动结束,
    /// 存成局部变量等于没加。`private(set)` 是为了让冒烟能断言"加上了 / 交还了"。
    private(set) var napAssertion: NSObjectProtocol?
    // P3.10: 等待型任务 fire 的回合追踪 (P4.0.2 会话化: 日志会话 sid -> 任务 id)
    private var fireTurnTask: [UUID: UUID] = [:]   // 在途 fire: 日志会话 -> 任务 id
    private var fireDoneHit: Set<UUID> = []        // 本轮日志会话已命中 done 标记
    // P15.3: 在途的 dream fire —— 日志会话 -> 这次运行的 spool 文件。
    // 与 `fireTurnTask` 分开: 那个只在**等待型**任务上有值（`condition` 非空）, 而 dream 是普通
    // cron 任务 ⇒ 复用那个字典会让 dream 的收口被"等待型"的判据顺手漏掉。
    private var dreamFires: [UUID: String] = [:]

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) { self.store = store }

    // MARK: - CRUD (P3.6)

    func addScheduled(name: String, prompt: String, cron: String,
                      projectId: UUID?, continuous: Bool = false) {
        let t = ScheduledTask(id: UUID(), name: name, prompt: prompt, cron: cron,
                              projectId: projectId, continuous: continuous)
        scheduledTasks.append(t)
        try? store?.persistence?.upsertScheduled(t)
    }

    func updateScheduled(_ t: ScheduledTask) {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == t.id }) else { return }
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
        scheduledTasks[idx] = t
        try? store?.persistence?.upsertScheduled(t)
    }

    /// 删除任务; deleteSessions = 连带删除日志会话 (开放问题 12: 默认保留, 用户可选删)。
    ///
    /// ⚠️ **dream 不可删**（2026-10-12 boss: "要固定死, 不能删除, 只能修改以及开关"）。守卫放在
    /// **这里**而不是视图: 视图那边"不渲染删除按钮"只是**可见性**, 这里才是**能力**。只要还剩一条
    /// 能删它的路径, 用户就永远丢了这条任务 —— 它是 App 自己种下的（`seedDreamTaskIfNeeded` 会让
    /// 它长回来, 但那是"补救", 不是"允许删"）。
    func deleteScheduled(id: UUID, deleteSessions: Bool = false) {
        guard let task = scheduledTasks.first(where: { $0.id == id }), Self.canDelete(task) else { return }
        let sessionIds = task.logSessionId.map { [$0] } ?? []
        scheduledTasks.removeAll { $0.id == id }
        try? store?.persistence?.deleteScheduled(id: id)
        if deleteSessions {
            for sid in sessionIds { store?.deleteConversation(sid) }
        }
    }

    func toggleScheduled(id: UUID) {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == id }) else { return }
        scheduledTasks[idx].enabled.toggle()
        try? store?.persistence?.upsertScheduled(scheduledTasks[idx])
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
    static func dreamFirePrompt(digest: String, notes: String) -> String {
        var parts = [dreamPrompt]
        if !notes.isEmpty { parts.append(notes) }
        if !digest.isEmpty { parts.append(digest) }
        return parts.joined(separator: "\n\n")
    }

    /// 这一条任务是不是 dream。判据只看 id（见 `dreamTaskID`）。
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
    static func sessionDigest(_ sessions: [DreamDigestInput],
                              since: Date,
                              excludeIds: Set<UUID> = [],
                              priorOmitted: Int = 0) -> String {
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
            if body.count > Tune.dreamDigestMaxCharsPerSession {
                body = KnowledgeStore.trimMaterialByTurns(lines,
                                                          budget: Tune.dreamDigestMaxCharsPerSession)
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
        while kept.count > 1, assemble(kept, omitted: omitted).count > Tune.dreamDigestTotalChars {
            kept.removeLast()
            omitted += 1
        }
        return assemble(kept, omitted: omitted)
    }

    /// 摘要的组装 —— 段头 + 会话段 + （有的话）点名行。抽出来是因为上面的循环要反复算长度。
    private static func assemble(_ kept: [String], omitted: Int) -> String {
        var parts = ["【最近会话摘录 · \(kept.count) 个会话, 窗口 \(Tune.dreamDigestWindowHours) 小时】"]
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

    /// 停调度 + 交还断言（与 `startScheduler` 对称; MailboxSentinelService 同款）。
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
        for task in scheduledTasks where task.enabled {
            guard let cron = task.cronExpr, cron.matches(now) else { continue }
            runScheduledFire(task, at: now)
        }
        // P17: 大跳 = 睡眠 / 长时间挂起 ⇒ 重算漏跑清单。放在到期检查**之后**: 刚跑过的任务
        // `lastRunAt` 已经前移, 不会被自己算成"漏跑"。首次启动时 `lastSchedulerMinute` 是 0
        // ⇒ gap 巨大 ⇒ 顺带把"启动时算一次"也覆盖了。
        if gap > 1 { refreshMissedFires(now: now) }
    }

    /// 到点投递 (P3.9 单日志会话): 任务的全部运行追加进同一个日志会话 (首次 fire 建立)。
    /// P4.0.2: 完全后台化 —— 不劫持选中会话/UI, 直接往日志会话投递回合;
    /// 该任务日志会话已有回合在途则跳过 (cron 到期不重排)。
    /// 持续模式 (continuous): 注入交接文件 (工作日志, agent 写用户可改) + 近期运行摘录,
    /// 并指令 agent 把关键进展写回交接文件——连续性靠文件携带, 磁盘为准零缓存。
    func runScheduledFire(_ task: ScheduledTask, at now: Date = Date()) {
        guard let store else { return }
        if let pid = task.projectId {
            guard store.projects.contains(where: { $0.id == pid }) else {
                recordFireSkip(task, at: now, reason: "项目已删除")
                return
            }
        }
        // 定位/建立日志会话 (有项目归 project, 无项目落平铺 Chats)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        var logId = task.logSessionId
        let logExists = logId.map { id in store.allConversations.contains(where: { $0.id == id }) } ?? false
        if !logExists {
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
            logId = item.id
        }
        guard let logId else { return }
        guard !store.runningTurns.contains(logId) else {
            recordFireSkip(task, at: now, reason: "该任务回合在途")
            return
        }
        // P4.0.4: 并发已满 → 落痕跳过 (与"冲突跳过"同语义, cron 到期不重排)
        if store.runningTurns.count >= store.maxConcurrentTurns {
            recordFireSkip(task, at: now, reason: "并发已满 (\(store.maxConcurrentTurns))")
            return
        }
        // 时间线锚点 + prompt 落库 (用户正看着日志会话则同步上屏)
        let viewing = store.selectedConversationId == logId
        let sep = ChatMessage(role: .user, content: .text("── \(fmt.string(from: now)) 运行 ──"))
        store.persistMessage(sep, sid: logId)
        if viewing { store.messages.append(sep) }
        let prompt = buildScheduledPrompt(task)
        let promptMsg = ChatMessage(role: .user, content: .text(prompt))
        store.persistMessage(promptMsg, sid: logId)
        if viewing { store.messages.append(promptMsg) }
        // fire 是独立轮次: ephemeral (--no-session), 连续性靠交接文件 (P3.9 拍板);
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
            fireSpool = spool
        }
        store.beginTurn(sid: logId, prompt: prompt, ephemeral: true,
                        cwd: cwd, unattended: true,
                        modeOverride: cfg.flatMap { AgentMode(rawValue: $0.agentMode) },
                        modelOverride: cfg.map {
                            (provider: $0.provider, modelId: $0.modelId, thinking: $0.thinkingLevel)
                        },
                        dreamSpool: fireSpool)
        // P10.3 联动: 日志会话行带上任务配置 (点开会话即恢复其执行配置)
        if let cfg { store.persistence?.saveSessionConfig(id: logId, config: cfg) }
        if let c = task.condition, !c.isEmpty {
            fireTurnTask[logId] = task.id   // 等待型: 本回合结束扫 done 标记
        }
        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[idx].lastRunAt = now
            scheduledTasks[idx].logSessionId = logId
            scheduledTasks[idx].runCount += 1   // P3.10: 执行次数
            try? store.persistence?.upsertScheduled(scheduledTasks[idx])
        }
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
        for task in scheduledTasks where task.enabled {
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
        runScheduledFire(task)
        // ⚠️ 无论这次 fire 是否被在途保护跳过, 都要认账 —— 否则 `lastRunAt` 没前移, 条目原样留着
        // ⇒ 用户看到的是"点了没反应"。同 `runNowButton` 那条"禁用按钮反而把记录藏起来"的理由。
        ignoreMissedFire(taskId)
    }

    /// 认账: 这批漏跑我看见了, 不补。**要落库**是因为下次开机不该再问一遍 ——
    /// 没有这一条, 用户"决定不补"这个动作就没有落点, 清单会一直挂在那儿。
    func ignoreMissedFire(_ taskId: UUID) {
        store?.persistence?.saveSettingText(
            key: Self.missedAckKey(taskId), value: String(Date().timeIntervalSince1970))
        refreshMissedFires()
    }

    // MARK: - 交接文件 (P3.9)

    /// 交接文件路径: 项目任务 → <项目>/.mangox/tasks/<taskId>.md (进文件树/可 @ 引用);
    /// 无项目任务 → ~/.mangox/task-memory/<taskId>.md。
    func handoffPath(for task: ScheduledTask) -> String {
        let dir: String
        if let pid = task.projectId,
           let p = store?.projects.first(where: { $0.id == pid })?.path {
            dir = p + "/.mangox/tasks"
        } else {
            dir = NSHomeDirectory() + "/.mangox/task-memory"
        }
        return dir + "/\(task.id.uuidString).md"
    }

    /// 读交接文件 (磁盘为准, 零缓存)。返回 nil = 文件不存在。
    func readHandoff(for task: ScheduledTask) -> (content: String, updatedAt: Date?)? {
        let path = handoffPath(for: task)
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

    // MARK: - Prompt 组装 (P3.10)

    /// P3.10 等待型 prompt: 两分支协议 (未成立→一句观察轻检查; 成立→查防重复记录→执行动作→done 标记)。
    /// 轻检查轮不注入近期摘录 (token 经济); 交接文件保持极短且必注入 (含"已触发"防重复记录)。
    private func buildWaitingPrompt(_ task: ScheduledTask, condition: String) -> String {
        var sections: [String] = []
        sections.append("""
        【等待任务 · 本轮检查】
        触发条件: \(condition)
        要求: 用工具实际核实当前状态, 不要凭此前记忆推断; 不确定是否成立时按"未成立"处理。
        - 若条件未成立: 只用一句话报告观察结果 (如"截至当前尚未…"), 不要执行任何其他动作。
        - 若条件成立: 先读下方交接文件确认此前未触发过, 然后执行【触发后动作】, 完成后在回复最后单独一行输出: \(Self.doneMarker)
        """)
        var handoff = readHandoff(for: task)?.content
        if (handoff ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let rebuilt = rebuildHandoff(from: task.logSessionId) {
                saveHandoff(for: task, content: rebuilt)
                handoff = rebuilt
            }
        }
        if let h = handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            sections.append("【交接文件】\n\(h)")
        }
        sections.append("【触发后动作】\n\(task.prompt)")
        return sections.joined(separator: "\n\n")
    }

    /// 持续模式 prompt 组装 (P3.9): 交接文件全文 (长期记忆) + 近期运行摘录 (短期上下文)
    /// + 本次指令 + 写回指令。文件丢失时从日志会话 (run-log) 静默重建。
    /// 等待型 (condition 非空) 走等待协议; 普通 prompt 原样返回。
    /// P9.1b 惯例: **internal** —— 冒烟要断言"存量旧行不影响 dream"（那个失效模式在别处零红灯）。
    func buildScheduledPrompt(_ task: ScheduledTask) -> String {
        if let c = task.condition, !c.isEmpty {
            return buildWaitingPrompt(task, condition: c)
        }
        // P15.6: dream 的输入 = **App 侧算好的有界摘要**, 挂在指令之后一起发出去。
        // 刻意不写进 `task.prompt`: 那一段是用户在编辑器里看见、会去改的东西, 而摘要是
        // **每次 fire 现算的**派生数据 —— 混进去会让"任务指令"这一栏每次都不一样。
        // 摘要在指令**之后**: 指令是"怎么干", 摘要是"料", 先立规矩再给料。
        // 摘要为空（最近没有会话）⇒ 只有指令: prompt 里那条"没有摘录段就直接结束"的硬约束
        // 负责让它体面收场, 不需要在这里造一个空段。
        // P15.6b: 指令正文取 `dreamFirePrompt`（= **常量**）, **不是** `task.prompt`。
        if Self.isDreamTask(task) {
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
    private func rebuildHandoff(from logId: UUID?) -> String? {
        guard let logId, let store else { return nil }
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

    // MARK: - Done 标记扫描 (P3.10, 事件归并在 ChatStore, 状态在这里)

    /// 回复命中 done 标记且该会话有在途 fire → 点亮 fireDoneHit (ChatStore 剥离时回调)。
    func noteDoneMarkerHit(sid: UUID) {
        if fireTurnTask[sid] != nil { fireDoneHit.insert(sid) }
    }

    /// 会话逐出: 清在途 fire 追踪 (ChatStore.evictTransport 回调)。
    func clearFireTracking(sid: UUID) {
        fireTurnTask[sid] = nil
        fireDoneHit.remove(sid)
    }

    /// P3.10/P4.0.2: 等待型 fire 收尾——done 命中则自动停用任务。
    /// 审批策略无需恢复: 池化后策略按回合下发 (unattended fire 只影响自己的实例配置)。
    func finishWaitingFireIfNeeded(sid: UUID) {
        guard let tid = fireTurnTask.removeValue(forKey: sid) else { return }
        let hit = fireDoneHit.contains(sid)
        fireDoneHit.remove(sid)
        guard hit,
              let idx = scheduledTasks.firstIndex(where: { $0.id == tid }) else { return }
        scheduledTasks[idx].enabled = false
        scheduledTasks[idx].completedAt = Date()
        try? store?.persistence?.upsertScheduled(scheduledTasks[idx])
    }

    // MARK: - P15.3 dream 收口（spool → note_proposals）

    /// 一次 dream fire 结束时调 —— 把 spool 收进 `note_proposals`, 然后删掉 spool。
    ///
    /// ⚠️ 与 `finishWaitingFireIfNeeded` **分开**而不是并进去: 那个管的是"等待型任务命中 done
    /// ⇒ 自动停用", 判据是 `fireTurnTask`; 这个管的是"一批提案的收口", 判据是 `dreamFires`。
    /// 合成一个函数会让两条互不相干的判据共用一次 `return`（谁先命中就把另一条吞掉）。
    ///
    /// 两条路都要收: **落定**（`agentSettled`）与**手动停**（`stopTurn`）——「跑不完不算失败」。
    func finishDreamFireIfNeeded(sid: UUID) {
        guard let spool = dreamFires.removeValue(forKey: sid) else { return }
        guard let store, let p = store.persistence else { return }
        // 顺序 = 读 → 解析 → 落表 → 删。**删在最后**: 落表失败时 spool 还在,
        // 而它在下次 fire 开头会被清掉（那时这批也真的没别的出路了）。
        guard let text = try? String(contentsOfFile: spool, encoding: .utf8) else { return }
        let roots = store.knowledge.allKnowledgeBases.map { (id: $0.id, path: $0.path) }
        let parsed = NoteProposalSpool.parse(text, roots: roots)
        var kept = 0
        for d in parsed.items {
            let proposal = NoteProposal(
                id: UUID(), rootId: d.rootId, kind: d.kind, targetPath: d.targetPath,
                baseHash: d.baseHash, title: d.title, content: d.content, reason: d.reason,
                sources: d.sources, createdAt: .now, status: .pending, sessionId: sid.uuidString)
            if (try? p.appendNoteProposal(proposal)) != nil { kept += 1 }
        }
        store.knowledge.reloadProposals()
        // ⚠️ 这话必须说 —— 尤其是被拒的那几条。spool 马上就删了, 现在不写,
        //    用户只会看到"这次怎么才出两条", 而不知道另外三条死在了路上。
        appendTimeline(Self.dreamSummary(kept: kept, rejects: parsed.rejects), to: sid)
        try? FileManager.default.removeItem(atPath: spool)
    }

    /// 收口那句话。**恒中文**（本文件在 `EXCLUDE_FILES` 里, 且它与 `recordFireSkip` 同性质:
    /// 是一行**日志时间线**, 不是界面文案）。
    static func dreamSummary(kept: Int, rejects: [SpoolRejection]) -> String {
        let s = "── dream 收口: \(kept) 条提案待审 ──"
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

    /// 侧栏任务日志会话标志 (定时任务 clock / 哨兵任务雷达)
    func scheduledBadge(for sessionId: UUID) -> String? {
        for t in scheduledTasks where t.logSessionId == sessionId {
            return (t.condition?.isEmpty == false)
                ? "dot.radiowaves.left.and.right"
                : "clock.badge"
        }
        return nil
    }
}
