//
//  PiRpcTransport.swift
//  P3.2: 通过 `pi --mode rpc` (JSONL over stdio) 驱动 pi coding agent。
//  协议映射 (docs/P3-functional-design.md P3.2):
//    prompt → send · abort → cancel
//    agent_start/agent_end → streamStarted/streamEnded
//    message_update{text_delta} → textChunk · {thinking_delta} → thoughtChunk
//    tool_execution_start/update/end → toolUpdated(整对象 upsert)
//  无 initialize 握手, 进程起来直接发命令; JSONL 严格以 \n 分帧。
//

import Foundation

@MainActor
final class PiRpcTransport: AgentTransport {
    weak var delegate: (any AgentTransportDelegate)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var outPipe: Pipe?
    /// 调试用: 原始 RPC 行打到 stderr (冒烟测试用; env 方式因 ProcessInfo.environment 缓存不可靠)
    nonisolated(unsafe) static var rawEchoToStderr = false
    /// 行缓冲 (readabilityHandler 在后台线程回调, 加锁)
    private let lock = NSLock()
    private nonisolated(unsafe) var lineBuffer = Data()

    // P12.1a: pi 的**致命错误只走 stderr**。实测 (`-e builtin:<未知名>`):
    //   stdout 全空 + stderr 一行 `Error: Failed to load extension …` + 进程退出。
    // 原实现把 stderr 丢进 nullDevice ⇒ 参数不被这个版本接受时, 用户看到的是
    // "发了消息什么都不发生", 零可归因信息。这里留**尾部若干行**供启动失败时上报。
    private var errPipe: Pipe?
    /// 尾部 stderr 行 (后台读取线程写, 加锁; 上限见 `stderrTailLimit` ⇒ 绝不无界增长)。
    private nonisolated(unsafe) var stderrTail: [String] = []
    /// `nonisolated`: 读它的是 `enqueueStderr` (后台线程), 不是主线程。
    private nonisolated static let stderrTailLimit = 4
    /// 本次 spawn 是否已经收到过**任何** RPC 行。
    /// 判据用它而不是 `turnActive`: 正常 spawn 会立刻回 get_state / get_available_models /
    /// get_session_stats, **一句话都不说**就是启动失败。
    private var sawAnyRPC = false
    /// spawn 代数 (延迟上报要认朝代: 0.5s 内可能已经换了进程)。
    private var spawnGeneration = 0
    private var startupWatchdog: Task<Void, Never>?
    /// 本次 spawn 是否已报过启动失败 (看门狗与退出回调都会触发, 只报一次)。
    private var engineFailureReported = false

    // 回合状态
    private var turnActive = false
    /// 本回合是否产出过内容（正文 / 思考 / 工具卡）。**在 `emit` 里置位** ⇒ 漏不掉任何一种
    /// （`.toolUpdated` 一个事件就有五处 emit，逐处置位迟早漏一个）。
    private var turnProducedOutput = false
    /// 本回合有没有真的 `agent_start`。`prompt` 响应的 `handled` disposition 会**直接落定**
    /// 且根本没有 run（见 `settleTurn` 注释）—— 那种零产出是正常语义，不是引擎出错。
    private var turnSawAgentStart = false
    /// 本回合是不是用户自己按了停。停了之后零产出是**预期**，不该报"空回合"。
    private var turnUserAborted = false
    /// P6.0①: 最近一次 agent_end 的 willRetry (P6.1.2 过程态消费; 冒烟断言用 internal)。
    internal private(set) var lastWillRetry = false
    /// P6.0②冒烟: sendCommand 副本 (无进程时 sendCommand 为 no-op, 日志即可断言"未回 response")。
    internal private(set) var sentCommands: [[String: Any]] = []
    /// P6.1.1: 流式期 usage tick 节流 (500ms)。
    private var lastUsageTickAt = Date.distantPast
    /// 最近一次**完整**会话统计 (get_session_stats 的解析结果)。`usageTick` 以它为底稿,
    /// 只覆写用量字段 —— 见 `noteLiveUsage` 里那条"整结构体替换"的坑。
    private var lastFullStats: SessionStats?
    /// spawn 期解析的压缩预算 (见 `PiCompactionBudget`)。0 = 未知。
    /// 只在 spawn 定格: 它是 pi 的**配置**投影, 进程复用期间改了文件也不会重新生效
    /// (pi 自己也是 spawn 期读一次) ⇒ 跟着进程生命周期走才能与 pi 口径一致。
    private var resolvedReserveTokens = 0
    /// P6.1.1: settled 后拉 get_session_stats, 响应到达再拆进程 (2s 兜底强拆)。
    private var settleStatsPending = false
    private var settleStatsTask: Task<Void, Never>?
    private var textMessageID: UUID?
    private var thinkMessageID: UUID?
    private var toolCards: [String: ToolCall] = [:]   // pi toolCallId → 卡片
    private var toolStartAt: [String: Date] = [:]
    /// callId → 工具真名。只为了 `tool_execution_end` 那一步能分辨"这张图是现场截图"。
    ///
    /// ⚠️ 不用 `card.title` 判断: `title` 早被 `toolHead` 换成了给人看的抬头(如「按 #12 · Safari」),
    ///    工具名在里面已经不存在了。
    /// ⚠️ 用完即 `removeValue`(在 end 里) —— 否则这个字典随整个会话单调增长。
    private var toolNamesByCallId: [String: String] = [:]
    private var requestId = 0

    // 审批 (P3.3): pi 侧 permission-gate 扩展对敏感工具发 extension_ui_request,
    // 客户端按 approvalMode 决定放行/弹卡/拒绝; "Allow always" 由扩展侧会话内记忆。
    private struct PendingApproval {
        let requestId: String
        let toolUUID: UUID
        let callId: String
    }
    private var pendingApprovals: [PendingApproval] = []
    /// P10.2a-0: 裁决档 (默认交互)。老调用点经 updateApprovalPolicy(askApproval:) 映射。
    internal private(set) var approvalMode: ApprovalMode = .interactive
    /// P10.2a-0: autoJudge 档拦下的命令 (命令 + 原因), 供任务回执写"卡在哪"。
    /// 本回合内累积, send 时清空 (transport 实例 = 会话, 见 ChatStore.transports)。
    /// P10.2b: 类型定义已提到模块级 (ApprovalMode.swift), 此处只留实例状态。
    internal private(set) var autoJudgeBlocks: [AutoJudgeBlock] = []
    // P3.10: bash 学习白名单 (ChatStore 下发的持久集 + 会话内 alwaysAllow 沉淀)。
    // 判定在客户端桥 (handleExtensionUIRequest) 做, 覆盖所有会话路径。
    private var learnedBashTokens: Set<String> = []

    // 工作目录 (P3.4): store 下发 project path; cwd 变化在下次 send 时重启进程生效。
    private var desiredCwd: String?
    private var spawnedCwd: String?
    /// P15.3: **本次 spawn 时** `dreamSpool` 是什么 —— 与 `spawnedCwd` 同一个用途:
    /// 进程复用期间判断"期望值变了没, 变了就得重启"（扩展与 env 都只在 spawn 期定格）。
    private var spawnedDreamSpool: String?
    /// P3.7: 知识注入块 (spawn 期 --append-system-prompt 下发; 变更需重启进程生效)。
    private var desiredKnowledge: String?
    /// P3.11: 托管扩展加载列表 (spawn 期 --extension 逐个追加; mangox-approval 固定内置)。
    private var desiredExtensions: [String] = []
    /// 会话持久化绑定 (nil = --no-session ephemeral; 非 nil = --session 文件, 重启恢复)。
    private var desiredSessionId: UUID?
    /// P6.3.1: 显式会话文件路径 (fork 产物; 优先于 UUID 派生路径)。
    private var desiredSessionFile: String?
    /// P6.3.1: fork 源快照 (非 nil = 下次 spawn 带 --fork; 与 --session 互斥, 分支优先)。
    private var desiredForkSource: String?
    /// P6.3.1: fork 产物路径回读在途 (get_state.sessionFile 命中后清)。
    private var forkReadbackPending = false
    private var forkReadbackTask: Task<Void, Never>?
    /// per-turn: spawn 期模型/思考级别 (--model provider/id, --thinking), 下回合生效。
    private var desiredModel: String?
    private var desiredThinking: ThinkingLevel = .high
    /// P7-M4: 模式档位 (spawn 期 --tools / 业务扩展挂载), 下回合生效。
    private var desiredMode: AgentMode = .standard
    /// P7-M3: 自管模型物化产物 (nil/空 = 不注入; spawn 期落盘 + 环境变量)。
    private var piConfig: ModelMaterializer.Output?

    /// P15.3: 这一份 transport 是不是**正在跑 dream** —— 非 nil = 是, 且它就是那次运行的 spool。
    ///
    /// ⚠️ 刻意**不放进 `AgentMode`**: 「跑一次 dream」是**任务语义**, 不是档位语义
    /// (`Scheduled` 承载任务, `Settings` 承载配置 —— 项目约定)。做成第五档会让它出现在
    /// 用户能选的档位选择器里 ⇒ 主会话也能挂上 dream 扩展 ⇒ 下面那道双闸门当场失效。
    /// 实例级还顺带保证了"只有这一次 fire 知道 spool 在哪"。
    ///
    /// 谁设它: `ChatStore.beginTurn` 经 `updateDreamSpool` (per-turn 下发, 与 `updateMode` 同路);
    /// 谁清它: 同一个入口 —— **普通回合无条件写 nil**, 所以它不会粘在实例上。
    private var dreamSpool: String?

    /// 协议侧入口 (P15.3)。**刻意没有 public setter**: 一条路径进、一条路径出,
    /// 免得又冒出一个"从别处顺手改一下"的调用点 —— 双闸门靠的就是"只有这里能改"。
    func updateDreamSpool(_ spool: String?) { dreamSpool = spool }

    /// S15c: 这一份 transport 是不是**正在跑一个飞书轮** —— 非 nil = 是, 值就是那轮的 spool。
    ///
    /// ⚠️ 与 `dreamSpool` 是同一层、**不是**同一件事: 那个是"跑一次 dream"的任务语义,
    ///    这个是"这一轮人是从飞书私聊发起的"。做成一个变量会让两者互相覆盖（dream 的
    ///    收尾清 nil 会把飞书轮的工具也摘掉）。
    /// ⚠️ 谁设它: `ChatStore.beginTurn` → `RemoteChannelService.attachSpoolForTurn` ——
    ///    判据是 `remoteTurns` / `execReplies` 里有没有这个 sid（那两张表只在飞书
    ///    真的来了话时写入）。**普通会话无条件写 nil**，所以工具不会粘在实例上。
    private var attachSpool: String?
    private var spawnedAttachSpool: String?

    /// 协议侧入口 (S15c)。同 `updateDreamSpool`: 一条路径进、一条路径出。
    func updateAttachSpool(_ spool: String?) { attachSpool = spool }

    /// 2026-11-23: 这一份 transport 是不是**在替某个任务跑一轮** —— 非 nil = 是, 值就是那轮的 spool。
    ///
    /// ⚠️ 与 `dreamSpool` / `attachSpool` 并列的**第三个** per-turn 开关，不是它们的合并:
    /// 三者管的是三件不同的事（跑一次 dream / 人从飞书来 / 这一轮属于某个任务），
    /// 合成一个变量会让三重闸门互相把对方摘掉。
    ///
    /// ⚠️ 谁设它: `ChatStore.beginTurn` → `SchedulerService.beginFollowUpTurn` ——
    /// 判据是"这场会话归某个任务管"（`logSessionId` 反查）。**普通会话无条件写 nil**，
    /// 所以"聊天时给自己约定时器"这件事在结构上就做不到（不是靠提示词劝住）。
    private var followUpSpool: String?
    private var spawnedFollowUpSpool: String?

    /// 协议侧入口 (2026-11-23)。同 `updateDreamSpool`: 一条路径进、一条路径出。
    func updateFollowUpSpool(_ spool: String?) { followUpSpool = spool }

    /// P19: 巡检轮 / 执行轮的**系统级注入**（交接文件 + 输出契约 + Observation 快照）。
    ///
    /// ⚠️ 走 `--append-system-prompt` 而不是塞进 user prompt, 理由是**转录污染**:
    /// 塞进 user prompt 的话, 这段模板会作为"用户说过的话"落进 transcript —— 下一轮注入时
    /// 模型看到自己上一轮被喂过一份几乎相同的长文, 会当成"用户重复了一遍", 而写回交接文件的
    /// 指令也会被当成用户要求（`ChatStore.swift:1875` 当初要求 fire ephemeral 就是怕这个）。
    /// 代价: spawn 期定格 ⇒ 每轮注入内容变了必须重启进程（`spawnedExtraSystem`）。
    private var extraSystemPrompt: String?
    private var spawnedExtraSystem: String?
    func updateExtraSystemPrompt(_ text: String?) { extraSystemPrompt = text }

    /// P19 执行守卫（per-turn）。它不只影响审批裁决 —— 只要它非空，spawn 期还会多给一个
    /// env（`MANGOX_EXEC_PROJECT`，写围栏在扩展侧的那一半），所以它也在重启判据里。
    ///
    /// ⚠️ 与 `extraSystemPrompt` 的赋值纪律一致: 都是**无条件**赋值（不清就会漏进下一回合 —— 忘了清 = 之后每一轮都带着红线，
    /// 表面上只是"某些命令莫名被拒"）。
    private var executionGuard: ExecutionGuard?
    private var spawnedExecProject: String?
    func updateExecutionGuard(_ guardValue: ExecutionGuard?) {
        // 每回合从头开始（**无条件**，不看"值变没变"）: 两次执行轮之间守卫可能是同一个值
        // （同一条结论重试 / 同一份方案），按"变了才清"的写法会把上一轮的步骤号与落痕带进来 ——
        // 表现是"这次什么都没干，落痕里却有上次那几步"，而它不红、只是把审计做成假的。
        execDeclaredStep = nil
        execStepBuffer = ""
        execActions.removeAll()
        executionGuard = guardValue
    }

    /// 模型正文里**最新**声明到的步骤号（「第 N 步」）。审批桥拿它比已授权步骤。
    private var execDeclaredStep: Int?    /// 流式文本的尾部缓冲。只需尾部：判据要的是"最新的那个声明"。
    private var execStepBuffer = ""
    private static let execStepBufferMax = 2000

    /// 本轮过闸的落痕，按步骤号归并（`agent_finding_actions` 的每步一行）。
    private(set) var execActions: [Int: ExecAction] = [:]

    /// P10.1b: 博查 API Key (nil/空 = 未配置)。**只在这里定格, 只经 env 下发**, 不落盘。
    ///
    /// ⚠️ 与 `dreamSpool` 同一层（实例级、spawn 期定格），但**不是任务语义** —— 它是
    /// "这台机器配没配联网搜索"的**配置投影**, 由 `ChatStore` 在建实例与重扫时下发。
    /// 为什么不直接在 spawn 里读 Keychain: transport 拿不到 store（P9.1c 起配置一律经
    /// `update*` 推进来），而"读一次、定格到这次 spawn"正是 env 这类参数需要的语义
    /// （进程复用期间 key 变了要重启才生效，同 `dreamSpool` / `desiredKnowledge`）。
    private var webSearchKey: String?

    /// 协议侧入口 (P10.1b)。key 变更后需重启引擎才生效。
    func updateWebSearchKey(_ key: String?) { webSearchKey = key }

    /// **一个会话一份**(2026-11-12 boss 拍板)。
    ///
    /// ⚠️ 别改成 `ComputerHost.shared`: 试过, 不行。`Scope` 里 `takeover` 取自**每会话**的
    ///    `approvalMode` ⇒ 两个会话档位不同就互相把对方的 helper 重启掉, 而 socket 路径每次
    ///    spawn 换 UUID ⇒ 先起的那个会话永远连不上(`ECONNREFUSED`)。隔离优先。
    ///
    /// ⚠️ 所以这里**必须**在会话结束时 `stop()` —— 原来 `shutdown()` 只拆 pi,
    ///    helper 一个都不收: 每开一个会话多一个握着辅助功能 + 屏幕录制的子进程
    ///    (实测有一个跑了 1 小时 33 分), `~/.mangox/` 里的死 socket 越攒越多。
    private let computerHost = ComputerHost()

    /// P7-M3: 接收自管模型物化产物 (ChatStore 在模型变更时推送)。
    func updatePIConfig(_ output: ModelMaterializer.Output?) {
        piConfig = output
    }

    /// P7-M4: 模式档位下发 (spawn 期消费, 下回合生效)。
    func updateMode(_ mode: AgentMode) {
        desiredMode = mode
    }

    // MARK: - 可用性探测

    static func available() -> Bool { findBinary() != nil }

    /// P12.1c: pi 二进制候选表 (**顺序即优先级**)。
    /// pi 1.0 起安装路径不再只有 npm 全局 —— pi.dev 托管安装器把入口放在
    /// `~/.pi/agent/bin` 或 `~/.local/bin` (见 docs/P12 §3.2), 而这两个**都不在
    /// Finder / Xcode 启动的 App 的 PATH 里** ⇒ 只靠 PATH 兜底会判成"引擎不可用",
    /// 而 pi 明明装着。
    static func binaryCandidates(home: String = NSHomeDirectory(),
                                 pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> [String] {
        // 前四项与 PATH 无关 (homebrew 两条 + 托管安装两条), 放在前面保证确定性;
        // PATH 扫描放最后, 兜住自定义 prefix / 版本管理器这类未知位置。
        var out = ["/opt/homebrew/bin/pi",
                   "/usr/local/bin/pi",
                   home + "/.pi/agent/bin/pi",
                   home + "/.local/bin/pi"]
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            let p = "\(dir)/pi"
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    private static func findBinary() -> String? {
        for p in binaryCandidates() where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// P12.1c: 引擎不可用时的自查报告 —— 找过哪些路径、命中谁。
    /// 存在的理由: README 把"装 pi"定为**用户义务**, 那 App 就必须让用户能自救。
    /// 原来只有一句「未找到 pi CLI」⇒ 用户无从知道该查哪里 (托管安装 / Nix / 自定义 prefix)。
    /// ⚠️ 逐次现算 (不落存储属性): 文案要跟随界面语言, 冻进实例属性就违反 L10n 的取词纪律。
    static func binarySearchReport() -> String {
        let home = NSHomeDirectory()
        var lines = [L("未找到可执行的 pi。已按顺序查找:")]
        for p in binaryCandidates() {
            let mark = FileManager.default.isExecutableFile(atPath: p) ? "✅" : "·"
            lines.append("\(mark) " + abbreviateHome(p, home: home))
        }
        lines.append(L("PATH 里没有 pi 时, App 发现不了托管安装以外的位置 (Nix / 自定义 prefix)。"))
        return lines.joined(separator: "\n")
    }

    /// 报告里把 home 前缀折成 `~` (纯函数, 冒烟直测)。
    /// ⚠️ 必须按**路径分量**匹配, 不能按字符串前缀 —— `hasPrefix("/Users/x")` 会把
    /// `/Users/xy/bin/pi` 折成 `~y/bin/pi`, 报告里出现一个不存在的 `~y` 比不折更坏。
    static func abbreviateHome(_ path: String, home: String) -> String {
        var base = home
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return path }
        guard path == base || path.hasPrefix(base + "/") else { return path }
        return "~" + String(path.dropFirst(base.count))
    }

    /// 扩展的**身份是它的目录名**, 不是 `index.js` —— `index.*` 是所有扩展共用的入口
    /// 文件名, 本身不含身份信息 (`~/.mangox/extensions/mangox-approval/index.js` 报成
    /// "`index.js`" 等于什么都没说)。单文件扩展 (`foo.ts` 直接放在扩展目录下) 没有这一层,
    /// 就原样用文件名。纯函数, 冒烟直测。
    static func extensionLabel(path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return "?" }
        if last.hasPrefix("index."), parts.count >= 2 { return parts[parts.count - 2] }
        return last
    }

    /// P12.1b: `llama.cpp` 在 pi 里既是**内置扩展**也是一个 **provider**。
    /// ⚠️ **契约 token** —— 逐字进 spawn 参数, 名字由 pi 定, 不得本地化 / 改写 / 拆分。
    static let builtinLlamaExtension = "builtin:llama.cpp"

    /// P3.11 + P12.1b + P13: spawn 期的扩展参数 (纯函数, 冒烟直测)。四段顺序即理由:
    ///   ① `--no-extensions` 关掉**自动发现** (只加载 MangoX 认可的扩展);
    ///   ② `--extension builtin:llama.cpp` —— ⚠️ **不可省**: pi **0.99.0** 起
    ///      `--no-extensions` 连**内置扩展**一起关, 而 llama.cpp 是 provider ⇒ 不补回来,
    ///      `get_available_models` 里整族本地模型直接消失。**四档恒挂**。
    ///      另两个内置 (`tool-search` / `mcp`) **有意不开** —— 它们绕过审批桥 (理由见 docs/P12 §七)。
    ///   ③ MangoX 托管扩展 (审批桥, **四档恒挂**)。
    ///   ④ P13: **自建** codemode 扩展 —— **仅 codemode 档**(`codemodeExtensionPath` 为 nil 就不加)。
    ///      ⚠️ 它**不是** `builtin:codemode`: 内置版没有传 options 的口子, 而 "only" 这个模式
    ///      只有自建版能给 (见 ensureCodemodeExtensionFile 的注释)。
    ///   ⑤ 业务扩展 (仅完整档, 由调用方过滤后传进来)。
    ///   ⑤ P15.3: **自建** dream 扩展 —— **仅 dream 那次 fire 的实例**（`dreamExtensionPath`
    ///      为 nil 就不加, 同 codemode 的写法）。它是"提案提交工具"的唯一载体。
    ///
    /// - Note: 后两个可选段**都有默认值**, 所以既有调用点逐字节不变 —— 这不是方便,
    ///   是 P13 那条"传 nil 时整段不变"的判据能继续成立的形式化（三老档零影响）。

    /// 审批桥里「账本围栏」那一支的**决策口** —— **2026-11-18 已整层删除**。
    ///
    /// 删掉的理由（boss 的口径）：围栏把助理的写限制在"账本这一个文件"上，而助理后续会跑在
    /// **独立的 Mac 主机**上 —— 那台机器整个就是给它用的，"只能写项目目录/只能写账本"既拦不住
    /// 什么，又制造了一堆"它想干活却写不了"的死路（巡检轮连 `ls` 都被拒，实测 11:04:49）。
    ///
    /// 安全边界改成两级，都在**人**这一侧：
    ///   ① **方案级**：要动手的事写成带方案的提议，人点「采纳并执行」才起执行轮；
    ///   ② **重要操作级**：删/覆盖/重启/对外发 —— 在方案里单独列出来等人批。
    /// 工具级弹卡在助理线上**恒关**（`ChatStore.beginTurn` 里按"是不是助理会话"钉死），
    /// 因为"改个文件就问我一次"是纯噪音，不是保护。

    static func extensionArguments(hostedExtensionPath: String,
                                   codemodeExtensionPath: String?,
                                   dreamExtensionPath: String? = nil,
                                   attachExtensionPath: String? = nil,
                                   followUpExtensionPath: String? = nil,
                                   computerExtensionPath: String? = nil,
                                   enabled: [String]) -> [String] {
        var args = ["--no-extensions", "--extension", builtinLlamaExtension,
                    "--extension", hostedExtensionPath]
        if let codemode = codemodeExtensionPath { args += ["--extension", codemode] }
        if let dream = dreamExtensionPath { args += ["--extension", dream] }
        if let attach = attachExtensionPath { args += ["--extension", attach] }
        if let follow = followUpExtensionPath { args += ["--extension", follow] }
        if let computer = computerExtensionPath { args += ["--extension", computer] }
        for path in enabled { args += ["--extension", path] }
        return args
    }

    /// pi 是 node 脚本 (shebang #!/usr/bin/env node)。直接 spawn 它时 env 要在
    /// 子进程 PATH 里找 node——Xcode 启动的 App PATH 不含 homebrew, 必失败。
    /// 故解析出 cli.js 真实路径, 显式用 node 跑。
    /// internal: MemoryDistiller 复用同一套启动方式 (node + cli.js 真实路径)。
    static func launchSpec() -> (executable: String, scriptArgs: [String])? {
        guard let piPath = findBinary() else { return nil }
        let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        guard let node = nodeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (piPath, [])  // 没有 node 就赌直接 spawn 能行 (终端态 PATH 正常时)
        }
        let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: piPath)) ?? piPath
        let script = real.hasPrefix("/")
            ? real
            : URL(fileURLWithPath: real, relativeTo: URL(fileURLWithPath: (piPath as NSString).deletingLastPathComponent)).path
        return (node, [script])
    }

    /// 审批门控扩展: tool_call 拦下**默认敏感**的工具, ui.select 三选项 (Allow/Allow always/Deny)。
    /// --extension 显式加载, 不污染用户终端里的 pi (不用自动发现目录)。
    static func ensureExtensionFile() -> String {
        let dir = NSHomeDirectory() + "/.mangox/extensions"
        let path = dir + "/mangox-approval.ts"
        let source = approvalExtensionSource()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != source {
            try? source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    /// P19 S6: 写围栏的 env（`MANGOX_EXEC_PROJECT`）。**只有执行轮的 spawn 会设它**，
    /// 与 dream 的 spool 同一套双闸门写法。
    ///
    /// ⚠️ 返回 nil = "什么都不用改"（既没有执行围栏、父进程里也没有残留）；
    ///    父进程有残留时返回的是**删掉了那个键**的完整环境 —— 不删的话一个普通会话会莫名
    ///    带上围栏（表现是"新建文件也要审批"，而界面上没有任何地方写着为什么）。
    static let execFenceEnvKey = "MANGOX_EXEC_PROJECT"
    static func execFenceEnvironment(existing: [String: String]?,
                                     projectPath: String?,
                                     inherited: [String: String]) -> [String: String]? {
        let desired = (projectPath?.isEmpty == false) ? projectPath : nil
        if desired == nil, inherited[execFenceEnvKey] == nil { return nil }
        var env = existing ?? inherited
        env[execFenceEnvKey] = desired    // nil = 移除该键（同 `webSearchEnvironment`）
        return env
    }

    /// P19.2 S10 的 `MANGOX_LEDGER_PATH`（账本围栏 env）**2026-11-18 整段删掉了** ——
    /// 围栏撤掉之后没有第二个人读这个键（扩展侧那一半也一并删了），留着只会让人以为
    /// "账本还有一道保护"。

    /// 审批扩展的源码 —— **纯函数, 不落盘**(冒烟直测)。
    /// P18 批 2a: 两个工具集合从 `ApprovalGate` **插值**进来, 不在 JS 里另抄一份。
    /// 理由: 抄一份就是两个真源, 改一边不会有任何编译错误, 而现象是"某个工具又自带豁免了"
    /// —— 与 `MANGOX_COMPUTE_*` 那条契约 token 纪律同族。
    static func approvalExtensionSource() -> String {
        let readOnly = ApprovalGate.jsSetLiteral(ApprovalGate.readOnlyTools)
        let passthrough = ApprovalGate.jsSetLiteral(ApprovalGate.passthroughContainers)
        return """
        // Auto-deployed by MangoX. Gate every tool that is not explicitly read-only.
        // P18 批 2a: **默认敏感** —— 只有 READ_ONLY 里的工具能绕开审批。翻面之前的
        // `SENSITIVE = new Set(["bash","write","edit"])` 会让任何新工具自带豁免(漏 = 出事)。
        // PASSTHROUGH = 容器工具(它自己不做动作, 内层每次调用会再走一遍这个钩子)。
        // P3.10: write 新建文件放行 (覆盖已存在文件才请求审批); bash/edit 全部交客户端判定。
        // P19 S6: **执行轮**多给一个 env (MANGOX_EXEC_PROJECT) —— 它开两道口子:
        //   ① 新建文件**落到围栏外**时必须照样请求审批 (否则 `write ~/x` 一次卡都不弹);
        //   ② 不给「Allow always」(记住它 = 之后这个工具彻底不走审批桥 = 红线一起放行)。
        // P19.2 S10: **巡检轮**多给一个 env (MANGOX_LEDGER_PATH) —— 免检口径再收紧一层:
        //   设了它 ⇒ 只有**账本那一份**能免检, 其余新建文件一律进审批 (客户端再判 Deny)。
        //   env 不存在的进程这两种行为**逐字节等于从前**（定时任务不许被顺带改掉）。
        // diff 预览: edit/write 审批时把 -/+ 行对照拼进 title (客户端 @@MANGOX_DIFF@@ 分段解析)。
        import * as fs from "fs";
        import * as nodePath from "path";
        export default function (pi) {
          const alwaysAllowed = new Set();
          const READ_ONLY = new Set(\(readOnly));
          const PASSTHROUGH = new Set(\(passthrough));
          const EXEC_PROJECT = process.env.MANGOX_EXEC_PROJECT || "";
          // 落在执行围栏之外?
          // ⚠️ 必须 `path.resolve` 而不是字符串拼接 —— `../x` 拼出来仍然以项目根**开头**，
          //    于是被判成"在围栏内"、一次审批都不弹。这条判据错了不会红：它只会静默放行。
          // ⚠️ 前导 `~` 一律当**围栏外**（交给客户端按家目录判）: Node 侧不展开 `~`，
          //    而"到底写到了哪"取决于工具实现 —— 判不清就问，问错了最多多一次审批卡。
          const PROJECT_ROOT = EXEC_PROJECT ? nodePath.resolve(EXEC_PROJECT) : "";
          const outsideExecFence = (p) => {
            if (!EXEC_PROJECT || !p) return false;
            const raw = String(p);
            if (raw.charAt(0) === "~") return true;
            const abs = nodePath.resolve(PROJECT_ROOT, raw);
            return !(abs === PROJECT_ROOT || abs.indexOf(PROJECT_ROOT + nodePath.sep) === 0);
          };
          // P19.2 S10 的「账本落点」2026-11-18 **整段删掉了**: 围栏撤掉之后,
          // "新建文件只在账本上免检"这句话没有对象了 —— 现在只有执行围栏(EXEC_PROJECT)
          // 还管免检范围, 其余一律按 `hasUI` / 档位那套走。
          const MAX_DIFF_LINES = 120;
          const MAX_LINE_CHARS = 200;
          const truncLine = (s) => {
            s = String(s);
            return s.length > MAX_LINE_CHARS ? s.slice(0, MAX_LINE_CHARS) + " …" : s;
          };
          // 块对照式 diff: - 旧块 / + 新块 (edit 的 replace 对语义天然对应; 不做行对齐)
          const blockDiff = (path, oldText, newText) => {
            const out = ["FILE " + path];
            const oldLines = String(oldText ?? "").split("\\n");
            const newLines = String(newText ?? "").split("\\n");
            for (const l of oldLines) out.push("- " + truncLine(l));
            for (const l of newLines) out.push("+ " + truncLine(l));
            return out;
          };
          // computer 工具的审批卡那一行。⚠️ 只写**动作 + 编号 + App**, 不写标题:
          // 卡是在动作**之前**弹的, 此刻那个编号指向的控件可能刚从「登录」变成「删除」——
          // 写上去等于替判据背书, 而判据还没跑。
          const describeComputer = (toolName, input) => {
            const app = input.app ? " · " + String(input.app) : " · 当前前台";
            if (toolName === "computer_open") {
              // ⚠️ 拼法为的是**不留下以空格结尾的字面量**: `wiring_allow.txt` 逐行 strip,
              //    那种字面量登不进豁免名单(门会一直红)。共用 `app` 那一段也省一份译文。
              return input.app ? "打开" + app : "打开 (没说哪个 App)";
            }
            // 第四档(2026-11-10): 它没有 `op`, 唯一的参数就是那个点。不加这一支, 卡上会退成
            // 兜底那句"读" —— 而这一档最需要人看清的恰恰是"要按屏幕的哪儿"。
            if (toolName === "computer_tap") {
              return "按 (" + String(input.x) + "," + String(input.y) + ")" + app;
            }
            if (input.op === "setValue") {
              const n = input.text === undefined ? 0 : String(input.text).length;
              return "写 #" + (input.index ?? "?") + " (" + n + " 字)" + app;
            }
            if (input.op === "press") {
              if (input.point) {
                return "按 (" + String(input.point.x) + "," + String(input.point.y) + ")" + app;
              }
              return "按 #" + (input.index ?? "?") + app;
            }
            if (input.op === "open") return "打开 #" + (input.index ?? "?") + app;
            if (input.op === "focus") return "聚焦 #" + (input.index ?? "?") + app;
            if (input.op === "scroll") {
              const way = input.direction === "up" ? "向上" : "向下";
              return way + "滚动 #" + (input.index ?? "?") + app;
            }
            if (input.op) return String(input.op) + app;
            return "读" + app;
          };
          const buildDiff = (toolName, input) => {
            try {
              let rows = [];
              if (toolName === "edit" && Array.isArray(input.edits)) {
                rows = ["FILE " + input.path];
                for (const e of input.edits) {
                  rows.push(...blockDiff("", e.oldText, e.newText).slice(1));
                  rows.push("···");
                }
              } else if (toolName === "write" && input.path) {
                const old = fs.existsSync(input.path)
                  ? fs.readFileSync(input.path, "utf-8") : "";
                rows = blockDiff(input.path, old, input.content);
              }
              if (rows.length > MAX_DIFF_LINES) {
                rows = rows.slice(0, MAX_DIFF_LINES);
                rows.push("… 其余改动省略");
              }
              return rows.join("\\n");
            } catch (e) {
              return "";
            }
          };
          pi.on("tool_call", async (event, ctx) => {
            // 默认敏感: 只有明确只读的才放行。不在这两个集合里的任何工具 —— 包括以后
            // 才加的那些 —— 都会走到下面的审批卡, 而不是"名字没命中就放行"。
            if (READ_ONLY.has(event.toolName)) return undefined;
            if (PASSTHROUGH.has(event.toolName)) return undefined;
            if (alwaysAllowed.has(event.toolName)) return undefined;
            if (!ctx.hasUI) return undefined;
            const input = event.input || {};
            if (event.toolName === "write" && input.path && !fs.existsSync(input.path)
                && !outsideExecFence(input.path)) {
              return undefined;   // 新建文件: 无覆盖风险, 放行
            }
            // computer 工具没有 command / path / url —— 不看这一支的话卡片上那一行是空的,
            // 人只知道"它要动电脑", 不知道要动哪一下。
            const detail = String(input.command || input.path || input.url
              || (String(event.toolName).indexOf("computer_") === 0 ? describeComputer(event.toolName, input) : "")
            ).slice(0, 500);
            let title = "MANGOX|APPROVE|" + event.toolCallId + "|" + event.toolName + "|" + detail;
            if (event.toolName === "edit" || event.toolName === "write") {
              const diff = buildDiff(event.toolName, input);
              if (diff) title += "@@MANGOX_DIFF@@" + diff;
            }
            let choice = null;
            try {
              choice = await ctx.ui.select(title, ["Allow", "Allow always", "Deny"]);
            } catch (e) {
              return { block: true, reason: "Approval UI failed" };
            }
            if (choice === "Allow always") {
              // P19 S6: 执行轮**不记**「永久批准」—— 记了之后这个工具彻底不再进审批桥,
              // 而红线、围栏、步骤围栏全都在客户端这一侧 ⇒ 等于一次点击把它们一起放行。
              // 这一下仍然算允许（人刚点的就是允许），只是不留到下一步。
              if (!EXEC_PROJECT) alwaysAllowed.add(event.toolName);
              return undefined;
            }
            if (choice === "Deny") return { block: true, reason: "Denied by user in MangoX" };
            return undefined;
          });
        }
        """
    }

    /// P13: 自建 codemode 扩展 —— **唯一能钉住 `mode: "only"` 的载体**。
    ///
    /// ⚠️ 为什么不用 `builtin:codemode`: 内置版没有传 options 的口子, 而 `readMode(pi)` 只认
    /// `<agentDir>/settings.json` 里的 `codemode.mode` ⇒ 那条路要连着踩三个洞 (见 docs/P13 §03):
    ///   ① `PI_CODING_AGENT_DIR` 的注入**有前置条件** (`modelCount > 0`) ⇒ 无自管模型时静默失效;
    ///   ② 读 settings 走 `proper-lockfile` 的**目录锁**, 拿不到锁就**整个文件读不到**
    ///      (只吐一行 warning, `mode` 静默回落 `on`);
    ///   ③ `settings.json` 是**跨会话持久契约**, 写进去的 `only` 会在任何挂了 codemode 的
    ///      spawn 上生效 —— 想让别的层挂 codemode 又要 `on` 就没有表达力了。
    ///
    /// ✅ 自建版走 `createCodemodeExtension({ mode: "only" })`: 该函数从包根导出, 且
    ///    `options.mode ?? readMode(pi)` ⇒ **传进来的 mode 优先于 settings** ⇒ 变成纯 spawn 参数,
    ///    上面三条全部不适用 (已用真进程实测: 扩展 + `--tools +codemode` ⇒ 模型只声明 codemode 一条)。
    ///
    /// ⚠️ 裸模块名能解析的**机理**: pi 用动态 `import()` 加载扩展, 解析基点是 **pi 自己的**
    ///    `dist/bundle/cli.js` (launchSpec 已把它 realpath 出来) ⇒ 向上必然命中
    ///    `@earendil-works/pi-coding-agent` **自身**所在的那层 node_modules。
    ///    ⇒ **与扩展文件放在哪无关** (实测把扩展挪到 5 层深的目录仍可解析)。
    static func ensureCodemodeExtensionFile() -> String {
        let dir = NSHomeDirectory() + "/.mangox/extensions"
        let path = dir + "/mangox-codemode.ts"
        let source = """
        // Auto-deployed by MangoX. Pin codemode's exposure to "only" for the codemode mode.
        // P13: options.mode 优先于 <agentDir>/settings.json 的 codemode.mode ⇒
        // 档位由 spawn 参数决定, 不写 settings.json (也就没有锁/指纹/注入条件那三个洞)。
        import { createCodemodeExtension } from "@earendil-works/pi-coding-agent";
        export default createCodemodeExtension({ mode: "only" });
        """
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != source {
            try? source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    // MARK: - P15.3 dream 扩展与 spool

    /// 环境变量名 —— **契约 token**: 逐字进子进程 env, `mangox-dream.ts` 那侧读的就是它。
    /// 改它 = 两边一起改, 且**已经落在磁盘上的旧扩展文件会失效**（读不到变量 ⇒ 工具早退
    /// "未开启"）。与其他契约 token 同一条判据: 不得本地化 / 改写 / 拆分。
    static let dreamSpoolEnvKey = "MANGOX_DREAM_SPOOL"

    /// spool 的**生产形状**: `~/.mangox/dream-spool/`。
    ///
    /// 为什么不放 `note/` 也不放 `task-memory/` —— 那两处都会被**扫描器**扫到
    /// （`dream-spool` 既不是点开头、也不在 `excludedNames` 里）⇒ 提案落盘 → 被当成笔记进索引
    /// → 每轮吃 prompt 预算, 而"未采纳的东西出现在注入里"正是本版最不能接受的一件事（§03）。
    /// 放独立目录 + ingest 之后立刻删 ⇒ 常态下这个目录是空的。
    static func productionDreamSpoolDir() -> String {
        NSHomeDirectory() + "/.mangox/dream-spool"
    }

    /// **进程级**重定向（冒烟）—— 与 `noteRootOverride` 同一个理由: 生产调用点
    /// (`SchedulerService`) 不传参数, 靠"每个 helper 记得设实例 override"已经漏过一次。
    /// 这里漏一次的后果还要更重: 夹具会写进用户真实的 `~/.mangox/dream-spool/`,
    /// 而它**不在任何笔记根里** ⇒ 既有的几个"根重定向"守卫没有一个会看见它（守卫 26 守它）。
    static var dreamSpoolRootOverride: String?

    /// 实际落点 = 生产形状 + 测试重定向。
    static func dreamSpoolDir() -> String {
        dreamSpoolRootOverride ?? productionDreamSpoolDir()
    }

    /// 一次 fire 一个文件。**文件名 = 任务 id** ⇒ 并发的两次 dream 不会互相覆盖
    /// （`.jsonl` = 逐行追加的 JSON —— 逐行追加才经得起"进程中途挂了", 见 `NoteProposalSpool`）。
    static func dreamSpoolPath(taskId: UUID) -> String {
        dreamSpoolDir() + "/\(taskId.uuidString).jsonl"
    }

    /// P15.3: 自建 dream 扩展 —— **「提案提交工具」唯一的载体**。
    ///
    /// ⚠️ 为什么必须自建: pi 内置里没有"把结论写进 MangoX 的 `note_proposals` 表"这种东西,
    /// 那是本仓自己的契约。而扩展能做的事刚好够 —— `pi.registerTool` 给模型多一个可调用的动作,
    /// 这个动作的副作用 = 往 spool 追加一行。
    ///
    /// ⚠️ **这个扩展是哑的**: 读 env / 校验 JSON 形状 / 逐行追加, 三件事。
    /// "这个路径是不是落在笔记根里"**不在它这儿判** —— 那需要把根表复制一份到 TS 里
    /// （第二真源, 而且它拿不到 App 的 `resolvedNoteDir` 重定向）。判据全部留在
    /// `Models/NoteProposal.swift` 的纯函数里, 那里能造反例、能进门禁。
    ///
    /// ⚠️ **双闸门 = 挂载 + env**: `dreamSpool != nil` 才挂这个扩展（挂载闸门）,
    /// 且只有 dream 的 spawn 设 `MANGOX_DREAM_SPOOL`（激活闸门）。两个都要 ——
    /// 只挂不给 env ⇒ 工具早退"未开启"; 只给 env 没挂扩展 ⇒ 模型根本看不到这个工具。
    /// 别的会话两个都没有 ⇒ **连 spool 在哪都不知道**。
    ///
    /// 为什么用 `#"""` 原始字符串: TS 源码里有 `"\n"`（换行符）与 `${…}` 两种形态，
    /// 普通 Swift 字面量会把 `\n` 变成真换行、把 `\(` 当成插值 ⇒ 写出来的扩展是坏的。
    /// 原始字符串里反斜杠逐字保留 —— 这是唯一不会静默改坏源码的写法。
    static let dreamExtensionSource: String = #"""
        // Auto-deployed by MangoX (P15.3). Records dream's note proposals into a spool file.
        //
        // Deliberately dumb: read MANGOX_DREAM_SPOOL, check the JSON shape, append one line.
        // Whether a target path really lives inside a note root is decided by the app when
        // the run ends (Models/NoteProposal.swift) -- duplicating that table here would
        // make it a second source of truth, and it could not see the app's test redirects.
        //
        // If MANGOX_DREAM_SPOOL is unset the tool refuses: only a dream run sets it.
        import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
        import { createHash } from "node:crypto";
        import { dirname } from "node:path";
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";

        const SPOOL_ENV = "MANGOX_DREAM_SPOOL";

        const Source = Type.Object({
            kind: Type.Optional(Type.Union([Type.Literal("session"), Type.Literal("note")])),
            ref: Type.String({ description: "Session id, or a note path relative to its root." }),
            quote: Type.Optional(Type.String({ description: "The exact words this came from." })),
        });

        // 目标文件的指纹。**App 只认这一个口径**: SHA-256 of the UTF-8 bytes, lowercase hex
        // (同 KnowledgeStore.noteHash —— 一条判据在两种语言里各实现一次, 口径必须逐字节一致)。
        //
        // 为什么在这里算、不问模型: 模型**算不出** sha256 —— read 工具只回正文, [笔记] 段
        // 也只有路径与摘要, 它没有任何途径拿到这个值。上一版让它自己填 ⇒ merge / replace 的
        // 采纳必然撞指纹不符, 而报错说的是"内容被改过" —— 把原因指到了磁盘上, 归因是错的。
        // 在这里算还顺带解决时点: 记的是"写下这一行那一刻"的指纹, 正是乐观并发要比的那一版。
        //
        // 读不到 (目标不存在 / 没权限) ⇒ 空串 ⇒ App 侧按"缺指纹"拒。那是对的: merge /
        // replace 的目标必须存在, 读不到就是不存在。
        function noteHash(path) {
            try {
                return createHash("sha256").update(readFileSync(path)).digest("hex");
            } catch (e) {
                return "";
            }
        }

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "note_proposal",
                label: "Note proposal",
                description: [
                    "Record ONE proposal about the user's notes. This does NOT touch any file:",
                    "it appends a line to a spool that MangoX reads when this run ends. The user",
                    "reviews proposals afterwards and decides what actually lands.",
                    "",
                    "PREFER FEW, DENSE PROPOSALS. At most 3 per run - usually 1 or 2.",
                    "Merge related facts from the same session into ONE note with `##` sections",
                    "instead of one note per fact. Split only when the facts are genuinely",
                    "unrelated. A half-written note is worse than none: it reads like a conclusion.",
                    "",
                    "kind:",
                    "  insight - a conclusion from the sessions that has no note yet; target_path is a NEW file",
                    "  merge   - two notes say the same thing; target_path is the note to keep",
                    "  replace - a note states something that is now outdated; target_path is that note",
                    "  delete  - a note is no longer useful at all; target_path is that note and it gets trashed",
                    "",
                    "target_path must be an absolute path inside one of the note roots shown in your prompt.",
                    "content is the FULL new text of the note, never a diff. Do not send content for delete.",
                    "base_hash is filled in by the app from the file on disk - do not set it yourself.",
                    "Every proposal needs at least one source. A proposal without sources is dropped.",
                ].join("\n"),
                parameters: Type.Object({
                    kind: Type.Union([Type.Literal("insight"), Type.Literal("merge"), Type.Literal("replace"), Type.Literal("delete")]),
                    target_path: Type.String({ description: "Absolute path inside one of the note roots." }),
                    content: Type.Optional(Type.String({ description: "The full new text (not a diff). Omit it for delete." })),
                    reason: Type.String({ description: "One or two sentences: why this is worth proposing." }),
                    title: Type.Optional(Type.String({ description: "Note title. Required for insight (it becomes the filename)." })),
                    base_hash: Type.Optional(Type.String({ description: "Ignored - the app computes this from the file on disk." })),
                    sources: Type.Array(Source, { description: "At least one. Proposals without sources are dropped." }),
                }),

                async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
                    const spool = process.env[SPOOL_ENV];
                    if (!spool) {
                        return {
                            content: [{ type: "text", text: "note_proposal is not enabled in this session." }],
                            details: undefined,
                        };
                    }
                    // The app enforces these too, but only AFTER the run ends -- the model gets
                    // no chance to fix them then. Caught here, it can retry within this turn.
                    if (params.kind === "insight" && !(params.title || "").trim()) {
                        return {
                            content: [{
                                type: "text",
                                text: "Rejected: an insight proposal needs a title - it becomes the filename. Call note_proposal again with title set.",
                            }],
                            details: undefined,
                        };
                    }
                    if (!params.sources || params.sources.length === 0) {
                        return {
                            content: [{
                                type: "text",
                                text: "Rejected: every proposal needs at least one source. Call note_proposal again with sources.",
                            }],
                            details: undefined,
                        };
                    }
                    const target = (params.target_path || "").trim();
                    const baseHash = params.kind === "insight" ? "" : noteHash(target);
                    const line = JSON.stringify({
                        kind: params.kind,
                        target_path: target,
                        content: params.content || "",
                        reason: params.reason || "",
                        title: params.title || "",
                        base_hash: baseHash,
                        sources: params.sources.map(function (s) {
                            return { kind: s.kind || "session", ref: s.ref, quote: s.quote || "" };
                        }),
                    });
                    try {
                        mkdirSync(dirname(spool), { recursive: true });
                        appendFileSync(spool, line + "\n");
                    } catch (e) {
                        return {
                            content: [{ type: "text", text: "Failed to record the proposal: " + String(e) }],
                            details: undefined,
                        };
                    }
                    return {
                        content: [{
                            type: "text",
                            text: "Recorded " + params.kind + " for " + params.target_path + "."
                            + (params.kind !== "insight" && !baseHash
                                ? " (warning: that file could not be read, so the app will reject this one)"
                                : ""),
                        }],
                        details: undefined,
                    };
                },
            });
        }
        """#

    /// dream 扩展注册出来的工具名 —— Plugins 面板在那一行下面展开它们。
    ///
    /// ⚠️ **与 `dreamExtensionSource` 同源同改**: 冒烟断言「这张表里每个名字都能在上面那段
    /// 源码里找到 `name: "<名字>"`」—— 改了源码忘了这张表会红, 反过来也红。
    /// 这是 P15.6b 那条「同一段东西两个真源」判据的镜像。
    ///
    /// ⚠️ **必须 `nonisolated`**（2026-10-13 修）：本类是 `@MainActor`, 裸 `static let`
    /// 会被判成**主线程隔离**；而消费方 `ExtensionItem.builtInToolNames` 住在**非隔离**枚举里,
    /// 它是 `static let` ⇒ 初始化表达式在**非隔离上下文**求值 ⇒ 引用本属性就是这个告警
    /// （Swift 6 语言模式下是 **error**）。值是不可变 `[String]`（Sendable）⇒ 用 `nonisolated`
    /// 就够, **不需要 `unsafe`**（同 `stderrTailLimit` 那处）。
    nonisolated static let dreamToolNames: [String] = ["note_proposal"]

    /// 把 `dreamExtensionSource` 写到 `~/.mangox/extensions/mangox-dream.ts`, 返回路径。
    ///
    /// ⚠️ **P15.7: 调用时机一个字没改** —— 仍然只有 `dreamSpool != nil` 的那次 spawn 才调它。
    /// 面板里那个条目由 `ChatStore.scanExtensions` **投影**出来, 与磁盘无关:
    /// 「面板列着这一项」≠「磁盘上有这个文件」, 这是有意的 (见那边的注释)。
    static func ensureDreamExtensionFile() -> String {
        let dir = NSHomeDirectory() + "/.mangox/extensions"
        let path = dir + "/mangox-dream.ts"
        let source = Self.dreamExtensionSource
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != source {
            try? source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    // MARK: - S15c 飞书发附件 (自建扩展, 只写 spool)

    /// env 名 —— **契约 token**: 逐字进子进程 env, `MANGOX_FEISHU_ATTACH` 那侧读的就是它。
    ///
    /// 值是**一个 JSON 对象**（不是单个路径，同 dream 那种单值 env 不一样）:
    /// `{"spool":"/…/x.jsonl","roots":["/…/Documents","/…/Downloads"],"max_mb":30}`。
    ///
    /// 为什么把根表也放进来: 工具要在**这一轮里**就告诉模型"这条路径不行"（否则 App 在
    /// 回合结束时才拒，模型已经没机会改）。而根表**由 App 算、经 env 下发** —— 不是
    /// 在 TS 里再抄一份常量，所以它仍然只有一个真源。
    nonisolated static let attachEnvKey = "MANGOX_FEISHU_ATTACH"

    /// 扩展注册出来的工具名（面板展开用；与源码同源同改，同 `dreamToolNames` 那条守）。
    nonisolated static let attachToolNames: [String] = ["feishu_attach"]

    /// 自建「发附件」扩展 —— **模型侧唯一的入口**。
    ///
    /// ⚠️ 这个扩展是哑的: 读 env / 判路径 / 追加一行。**不联网、不碰凭据、不知道 chat_id**。
    ///    真正的发送在 `RemoteChannelService.finishRemoteTurn`，那里才有"这一轮是从哪个
    ///    私聊来的"这个信息（`remoteTurns` 只在飞书私聊真的来了话时写入）。
    ///
    /// ⚠️ **双闸门**（同 dream）: 挂载闸门 = 只有飞书轮的 spawn 才 `--extension` 它；
    ///    激活闸门 = 只有那次 spawn 设 env。别的会话两个都没有 ⇒ 模型连这个工具都看不到。
    ///
    /// ⚠️ 这里做的检查**只为了让模型能在本轮内改好**，不是最终裁决 —— 最终裁决在
    ///    `RemoteAttachments.decide`（规格化符号链接、凭据判据、精确大小），它跑在 App 里。
    ///    所以这里可以"从宽": 放过去的由 App 再拒，代价只是一句日志；反过来（从宽拒了
    ///    本来能发的）才是功能损失。
    static let attachExtensionSource: String = #"""
        // Auto-deployed by MangoX (S15c). Queues ONE local file to be sent to the user on
        // Feishu when this turn ends.
        //
        // Deliberately dumb: parse MANGOX_FEISHU_ATTACH, sanity-check the path, append a
        // line. No network, no credentials, no chat id -- the app owns all three, and only
        // a turn that actually came in from a Feishu DM gets this extension mounted.
        //
        // The checks here exist so the model can fix a bad path WITHIN this turn: the app
        // re-checks everything when the turn ends, and by then the model cannot retry.
        import { appendFileSync, mkdirSync, existsSync, statSync } from "node:fs";
        import { dirname } from "node:path";
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";

        const ENV = "MANGOX_FEISHU_ATTACH";

        function config() {
            try {
                const raw = process.env[ENV];
                if (!raw) return null;
                const c = JSON.parse(raw);
                if (!c || !c.spool) return null;
                return c;
            } catch {
                return null;
            }
        }

        function reject(text) {
            return { content: [{ type: "text", text: text }], details: undefined };
        }

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "feishu_attach",
                label: "Send file to Feishu",
                description: [
                    "Queue ONE local file to be sent to the user on Feishu. This does NOT send",
                    "anything right now: it goes out when this turn ends. The file must already",
                    "exist on this Mac and must live under the user's Documents or Downloads",
                    "folder. At most 3 files per turn.",
                    "",
                    "Use this when the user asked you to give them a file (a document, a picture,",
                    "a report you just wrote). Do NOT use it to announce things -- say it in your",
                    "reply text instead.",
                    "",
                    "Absolute path only. Files over 30 MB are refused by Feishu.",
                ].join("\n"),
                parameters: Type.Object({
                    path: Type.String({ description: "Absolute path of an existing file under ~/Documents or ~/Downloads." }),
                    name: Type.Optional(Type.String({ description: "Filename the user should see. Defaults to the file's own name." })),
                }),

                async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
                    const c = config();
                    if (!c) return reject("feishu_attach is not enabled in this session.");
                    const raw = (params.path || "").trim();
                    if (!raw) return reject("Rejected: path is empty.");
                    if (raw[0] !== "/") return reject("Rejected: needs an ABSOLUTE path (got \"" + raw + "\").");
                    const roots = Array.isArray(c.roots) ? c.roots : [];
                    const inside = roots.some(function (r) { return raw.startsWith(r + "/"); });
                    if (!inside) {
                        return reject("Rejected: only files under " + roots.join(" or ")
                            + " can be sent. If the file lives somewhere else, copy it there first "
                            + "(the user chose this rule).");
                    }
                    if (!existsSync(raw)) return reject("Rejected: no such file: " + raw);
                    let st;
                    try { st = statSync(raw); } catch (e) { return reject("Rejected: cannot read it: " + String(e)); }
                    if (st.isDirectory()) return reject("Rejected: that is a directory, not a file: " + raw);
                    const maxMb = Number(c.max_mb) || 30;
                    if (st.size === 0) return reject("Rejected: the file is empty.");
                    if (st.size > maxMb * 1024 * 1024) {
                        return reject("Rejected: " + (st.size / 1048576).toFixed(1) + " MB is over the "
                            + maxMb + " MB Feishu limit.");
                    }
                    const name = (params.name || raw.split("/").pop() || "").trim();
                    try {
                        mkdirSync(dirname(c.spool), { recursive: true });
                        appendFileSync(c.spool, JSON.stringify({ path: raw, name: name }) + "\n");
                    } catch (e) {
                        return reject("Failed to queue it: " + String(e));
                    }
                    return {
                        content: [{
                            type: "text",
                            text: "Queued " + name + " (" + (st.size / 1024).toFixed(0) + " KB). It goes out "
                                + "when this turn ends; mention it in your reply so the user knows what arrived.",
                        }],
                        details: undefined,
                    };
                },
            });
        }
        """#

    /// 组装 `attachEnvKey` 的值。**根表与上限取自 `RemoteAttachments`** —— 工具侧只消费，
    /// 不复制常量（不然改了白名单要记着改两处，而漏改的表现是"设置页说能发、工具说不能"）。
    static func attachEnvValue(spool: String) -> String? {
        let payload: [String: Any] = [
            "spool": spool,
            "roots": RemoteAttachments.allowedRoots(),
            "max_mb": RemoteAttachments.maxBytes / 1024 / 1024,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写到 `~/.mangox/extensions/mangox-feishu-attach.ts`, 返回路径。
    /// **只有飞书轮的 spawn 才调它**（同 `ensureDreamExtensionFile` 的调用时机纪律）。
    static func ensureAttachExtensionFile() -> String {
        let dir = NSHomeDirectory() + "/.mangox/extensions"
        let path = dir + "/mangox-feishu-attach.ts"
        let source = Self.attachExtensionSource
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != source {
            try? source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    // MARK: - follow-up 扩展（2026-11-23, 只写 spool）

    /// env 名 —— **契约 token**: 逐字进子进程 env, `mangox-followup.ts` 那侧读的就是它。
    /// 改它 = 两边一起改, 且**已经落在磁盘上的旧扩展文件会失效**（读不到变量 ⇒ 工具早退
    /// "这个会话没有"）。同 `dreamSpoolEnvKey` 那条判据: 不得本地化 / 改写 / 拆分。
    nonisolated static let followUpEnvKey = "MANGOX_FOLLOWUP_SPOOL"

    /// 扩展注册出来的工具名（面板展开用；与源码同源同改，同 `dreamToolNames` 那条守）。
    nonisolated static let followUpToolNames: [String] = ["follow_up"]

    /// spool 的**生产形状**: `~/.mangox/followup-spool/`。
    ///
    /// 与 `dream-spool` 一样**故意独立**: 它既不是笔记根（否则未兑现的约定会被扫描器当成笔记
    /// 进索引 —— 那是 P15 最不能接受的一件事），也不是任务记忆目录（那里放的是给人看的账本）。
    /// 常态下这个目录是空的（ingest 之后立刻删文件），只有"收口没跑到"时才会留下残留。
    static func productionFollowUpSpoolDir() -> String {
        NSHomeDirectory() + "/.mangox/followup-spool"
    }

    /// **进程级**重定向（冒烟）—— 与 `dreamSpoolRootOverride` **同一条理由，逐字同款**:
    /// 生产调用点（`SchedulerService`）不传参数，靠"每个 helper 记得设实例 override"已经漏过一次。
    /// 这里漏一次的后果更重: 夹具会写进用户真实的 `~/.mangox/followup-spool/`，而它**不在任何
    /// 笔记根里** ⇒ 既有的几个"根重定向"守卫没有一个会看见它（守卫 26 的第二个受守对象）。
    static var followUpSpoolRootOverride: String?

    static func followUpSpoolDir() -> String {
        followUpSpoolRootOverride ?? productionFollowUpSpoolDir()
    }

    /// 一个任务一个文件。**文件名 = 任务 id** ⇒ 同一任务的两次 fire 不会互相覆盖，
    /// 而不同任务之间本来就不该看见对方的约定。
    ///
    /// ⚠️ 与 dream 的**一个区别**: dream 在 fire 开头就把 spool 删掉（上一批残留无法归因），
    /// follow-up **不删** —— 残留的那几行仍然是有效的约定，只是还没被 ingest。代价见
    /// `SchedulerService.ingestFollowUpSpool` 的注释（幂等键把它兜住了）。
    static func followUpSpoolPath(taskId: UUID) -> String {
        followUpSpoolDir() + "/\(taskId.uuidString).jsonl"
    }

    /// 自建 follow-up 扩展 —— **模型给自己约定时器的唯一入口**。
    ///
    /// ⚠️ 这个扩展是哑的: 读 env / 校验形状 / 追加一行。**它不算时刻、不落库、不 fire** ——
    /// 三件事都在 App 侧: 时刻要 App 的钟（子进程的钟我们看不见，也不该信）, 落库要库,
    /// fire 要整个调度器。扩展只知道"约多少分钟之后 + 为什么"。
    ///
    /// ⚠️ **双闸门**（同 dream / attach）: 挂载闸门 = 只有**属于某个任务的那一轮**才
    /// `--extension` 它；激活闸门 = 只有那次 spawn 设 `MANGOX_FOLLOWUP_SPOOL`。
    /// 普通会话两个都没有 ⇒ 模型连这个工具都看不到 —— 而"看得到但每次调用都回未启用"
    /// 是比看不到更坏的一种假象。
    ///
    /// ⚠️ 为什么用 `#"""` 原始字符串: TS 源码里有 `"\n"`（换行符）与 `${…}`，普通 Swift 字面量
    /// 会把 `\n` 变成真换行 ⇒ 写出来的扩展是坏的。原始字符串里反斜杠逐字保留。
    static let followUpExtensionSource: String = #"""
        // Auto-deployed by MangoX (2026-11-23). Lets one run schedule its own wake-up.
        //
        // Deliberately dumb: read MANGOX_FOLLOWUP_SPOOL, check the shape, append one line.
        // It does NOT compute a due time and it does NOT touch the database -- this run
        // ends, the app reads the line, and only then does anything know what time it is.
        // A clock inside a subprocess we cannot inspect is not a clock worth trusting.
        //
        // It is also deliberately narrow: this tool does not create a new task. It asks an
        // EXISTING task to be woken up at a time it did not originally have. Tasks are the
        // user's; their schedule belongs to the cron field, not to the model.
        import { appendFileSync, mkdirSync } from "node:fs";
        import { randomUUID } from "node:crypto";
        import { dirname } from "node:path";
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";

        const SPOOL_ENV = "MANGOX_FOLLOWUP_SPOOL";
        const MIN_MINUTES = 5;
        const MAX_MINUTES = 10080;

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "follow_up",
                label: "Follow up later",
                description: [
                    "Ask to be woken up later ON THIS SAME TASK, instead of waiting for its next scheduled run.",
                    "One call = one future run. Up to 3 may be open per task; the app drops the rest.",
                    "",
                    "Use it only when the next step depends on TIME passing:",
                    "  - something you started is still running (a build, a download, a deploy);",
                    "  - a number/signal will only change by tomorrow (a daily report, a metric);",
                    "  - you asked the user something and he has not answered yet;",
                    "  - you applied a fix and it has to be re-checked after a while.",
                    "",
                    "Do NOT use it:",
                    "  - as a substitute for the task's own schedule (that is its cron, not your call);",
                    "  - when nothing will have changed by the time it fires -- that is a wake-up that",
                    "    only costs tokens;",
                    "  - to chain yourself in a loop (if the answer is 'check again in 5 minutes'",
                    "    forever, say so in the ledger instead and let the user decide the cadence).",
                    "",
                    "after_minutes: integer, 5..10080 (7 days). why: one line, handed back to you",
                    "verbatim when the wake-up fires -- write WHAT to look at and WHAT would count",
                    "as done. Do not restate the task's goal; the woken run gets that already.",
                ].join("\n"),
                parameters: Type.Object({
                    after_minutes: Type.Integer({
                        minimum: MIN_MINUTES,
                        maximum: MAX_MINUTES,
                        description: "How long from now, in minutes (5..10080).",
                    }),
                    why: Type.String({
                        description: "One line: what to look at, and what would count as done.",
                    }),
                }),

                async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
                    const spool = process.env[SPOOL_ENV];
                    if (!spool) {
                        return {
                            content: [{ type: "text", text: "follow_up is not available in this session." }],
                            details: undefined,
                        };
                    }
                    // Caught here so the model can fix it WITHIN this turn: the app re-checks
                    // everything when the run ends, and by then there is nobody to tell.
                    const n = Number(params.after_minutes);
                    if (!Number.isInteger(n) || n < MIN_MINUTES || n > MAX_MINUTES) {
                        return {
                            content: [{
                                type: "text",
                                text: "Rejected: after_minutes must be an integer between " + MIN_MINUTES
                                    + " and " + MAX_MINUTES + " (you gave " + String(params.after_minutes)
                                    + "). Call follow_up again.",
                            }],
                            details: undefined,
                        };
                    }
                    const why = String(params.why || "").trim();
                    if (!why) {
                        return {
                            content: [{
                                type: "text",
                                text: "Rejected: why is empty. The woken run only knows what you write there"
                                    + " -- say what to look at. Call follow_up again.",
                            }],
                            details: undefined,
                        };
                    }
                    const line = JSON.stringify({
                        id: randomUUID(),
                        after_minutes: n,
                        why: why,
                    });
                    try {
                        mkdirSync(dirname(spool), { recursive: true });
                        appendFileSync(spool, line + "\n");
                    } catch (e) {
                        return {
                            content: [{ type: "text", text: "Failed to record the follow-up: " + String(e) }],
                            details: undefined,
                        };
                    }
                    return {
                        content: [{
                            type: "text",
                            text: "Recorded: this task will be woken up about " + String(n) + " minutes after"
                                + " this run ends. Carrying on now -- nothing is blocked on it.",
                        }],
                        details: undefined,
                    };
                },
            });
        }
        """#

    /// 写到 `~/.mangox/extensions/mangox-followup.ts`, 返回路径。
    ///
    /// **只有 `followUpSpool != nil` 的那次 spawn 才调它**（同 `ensureDreamExtensionFile`
    /// 的调用时机纪律）—— 落地一个永久存在的 .ts 而从不挂它，只会让面板多一行看不懂的条目。
    static func ensureFollowUpExtensionFile() -> String {
        let dir = NSHomeDirectory() + "/.mangox/extensions"
        let path = dir + "/mangox-followup.ts"
        let source = Self.followUpExtensionSource
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != source {
            try? source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    // MARK: - P10.1b 联网搜索 (自建扩展, 只调博查)

    /// P10.1b: 博查 API Key 的 env 名 —— **契约 token**: 逐字进子进程 env,
    /// `mangox-web-search.ts` 那侧读的就是它。改它 = 两边一起改（同 `dreamSpoolEnvKey`）。
    static let webSearchKeyEnvKey = "MANGOX_BOCHA_KEY"

    /// 自建搜索扩展**注册出来的工具名** —— Plugins 面板在那一行下面展开它们。
    ///
    /// ⚠️ **与 `webSearchExtensionSource` 同源同改**: 冒烟断言「这张表里每个名字都能在
    /// 上面那段源码里找到 `name: "<名字>"`」（同 `dreamToolNames` 那条守）。
    ///
    /// ⚠️ **必须 `nonisolated`**（2026-10-13 修，`dreamToolNames` 的同款）: 本类是
    /// `@MainActor`, 裸 `static let` 会被判主线程隔离；消费方 `ExtensionItem`
    /// 住在**非隔离**枚举里, 它的 `static let` 初始化在非隔离上下文求值 ⇒ Swift 6 下是 error。
    nonisolated static let webSearchToolNames: [String] = ["bocha_web_search"]

    /// 自建搜索扩展的**文件名** —— 三处要用（落地 / spawn 前的挂载保底 / 面板侧拼路径）,
    /// 写死三次就会漂。面板那一处见 `ChatStore.scanExtensions`。
    nonisolated static let webSearchExtensionFileName = "mangox-web-search.ts"

    /// P10.1b: 自建联网搜索扩展 —— **只调博查**, 一次 POST, 零依赖。
    ///
    /// ⚠️ **为什么自建而不是挂 npm 包**（本方案的立项依据, 数字全是实测）:
    ///   · `pi-web-access` 那条路 spawn 期联网 `npm install`，拖进 **150+ 传递依赖**
    ///     （实测落盘 **82 MB / 10,776 个文件**）；本文件是 **1 个文件 / ~9 KB**，零依赖。
    ///   · npm 包**离线就静默消失**：`installMissing()` 开头 `if (isOfflineModeEnabled()) return false`
    ///     ⇒ 调用方 `continue`，扩展整段没了**且零报错**；自建没有这条路径。
    ///   · 包的落点由 `PI_CODING_AGENT_DIR` 决定 ⇒ 必须绑"有自管模型"这个前置条件；自建走
    ///     `~/.mangox/extensions/`，**不耦合配置目录**。
    ///   · 我们只用得到"搜一下"。包里的 web fetch / PDF / YouTube / GitHub clone 全用不上。
    ///
    /// ⚠️ **key 只走 env**（`webSearchKeyEnvKey`）: Keychain → spawn env, **不落盘**。
    /// npm 路的 key 必须写进 pi 的配置目录（那侧的配置读取路径写死 `homedir()`）—— 自建把这条也消掉了。
    ///
    /// ⚠️ **双闸门**（同 dream 的判据）: ① **挂载闸门** —— 没配 key 时 `ChatStore` 把它压成停用,
    /// 根本不发 `-e`；② **激活闸门** —— 只有那一次 spawn 会设 env。两道都要: 只挂不给 env ⇒
    /// 工具每次都回"未启用"; 只给 env 没挂扩展 ⇒ 模型根本看不到这个工具。
    ///
    /// ⚠️ **为什么用 `#"""` 原始字符串**: TS 里有 `\n`（字符串里的换行）与 `${…}` 两种形态,
    /// 普通 Swift 字面量会把 `\n` 变成真换行 ⇒ 写出去的扩展是坏的（同 dream 那条）。
    ///
    /// ⚠️ **输出上限是"按 10 篇 × 每篇 8 KB"定的**（boss 定），但**卡片渲染是有代价的**:
    /// 工具输出在卡片里是**一个 `Text`**（`ToolCallRenderer` 侧 `ToolDetail("输出", out)` 一行），
    /// 而单块 `Text` 在 SwiftUI 里是**平方级**的（另一次实测: 3341 行 36s vs 按块 646ms）。
    /// 默认（只要摘要）约 5 KB ⇒ 无感；80 KB 只在模型显式要 `content: true` 时才够得着。
    /// **真嫌慢的话正确的修法在视图侧（按块渲染），不是在这里偷偷砍结果。**
    static let webSearchExtensionSource: String = #"""
        // Auto-deployed by MangoX (P10.1b). Thin Bocha web search: one POST, zero runtime
        // deps beyond node built-ins and typebox.
        //
        // The key is NOT read from disk: MangoX injects MANGOX_BOCHA_KEY into this process
        // (Keychain -> spawn env), so the secret never lands on the filesystem. If the
        // variable is unset the tool refuses -- only a session with a configured key gets
        // this extension mounted in the first place.
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";
        import { mkdtemp, writeFile } from "node:fs/promises";
        import { tmpdir } from "node:os";
        import { join } from "node:path";

        const KEY_ENV = "MANGOX_BOCHA_KEY";
        const ENDPOINT = "https://api.bochaai.com/v1/web-search";

        // Retry policy mirrors the hand-rolled Python client this project already uses:
        // 5 attempts total, exponential backoff 1s / 2s / 4s, retry on 5xx and transport
        // errors only. 4xx is NOT retried -- a bad key or an exhausted quota does not fix
        // itself by waiting, and retrying silently only makes the user wait longer for the
        // same answer.
        const MAX_ATTEMPTS = 5;
        const BACKOFF_MS = [1000, 2000, 4000];
        const RETRYABLE = new Set([500, 502, 503, 504]);
        const ATTEMPT_TIMEOUT_MS = 20000;

        // Sized for 10 results with a full page body each (8 KB). The default (summaries
        // only) stays around 5 KB. See the MangoX-side note on why this ceiling is not
        // lower: one Text carrying a large block is quadratic to lay out, but the correct
        // fix for that lives in the view, not here.
        const MAX_LINES = 2000;
        const MAX_BYTES = 80000;
        const MAX_BODY_CHARS = 8000;

        function ok(text) {
            return { content: [{ type: "text", text: text }], details: undefined };
        }

        function sleep(ms) {
            return new Promise(function (resolve) { setTimeout(resolve, ms); });
        }

        // Trim a raw response down to something that fits inside an error message.
        function brief(body) {
            const flat = String(body || "").replace(/\s+/g, " ").trim();
            return flat.length > 400 ? flat.slice(0, 400) + "..." : flat;
        }

        function hintFor(status) {
            if (status === 401 || status === 403) {
                return "Bocha rejected the API key. Check it in MangoX: Settings - Web search.";
            }
            if (status === 429) {
                return "Bocha rate limit or quota reached. Wait, or check the plan on open.bochaai.com.";
            }
            if (status === 400) return "Bocha rejected the request parameters.";
            return "Unexpected response from Bocha.";
        }

        // Per-attempt deadline, relayed from the caller's cancellation signal. Written with
        // a plain AbortController on purpose -- AbortSignal.any / AbortSignal.timeout are
        // not available on every node pi may run on, and this needs no typings.
        function deadline(parent, ms) {
            const box = new AbortController();
            let expired = false;
            const timer = setTimeout(function () { expired = true; box.abort(); }, ms);
            const relay = function () { box.abort(); };
            if (parent) {
                if (parent.aborted) box.abort();
                else parent.addEventListener("abort", relay);
            }
            return {
                signal: box.signal,
                expired: function () { return expired; },
                release: function () {
                    clearTimeout(timer);
                    if (parent) parent.removeEventListener("abort", relay);
                },
            };
        }

        // Returns the parsed JSON payload, or throws a message that names what to do next.
        async function postSearch(body, key, signal) {
            let lastFailure = "no attempt was made";
            for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
                if (signal && signal.aborted) {
                    throw new Error("bocha_web_search was cancelled before it reached Bocha.");
                }
                const guard = deadline(signal, ATTEMPT_TIMEOUT_MS);
                let response;
                try {
                    response = await fetch(ENDPOINT, {
                        method: "POST",
                        headers: {
                            "Content-Type": "application/json",
                            Accept: "application/json",
                            Authorization: "Bearer " + key,
                        },
                        body: JSON.stringify(body),
                        signal: guard.signal,
                    });
                } catch (error) {
                    const why = guard.expired()
                        ? "timed out after " + ATTEMPT_TIMEOUT_MS + "ms"
                        : String(error);
                    lastFailure = "could not reach " + ENDPOINT + " (" + why + ")";
                    // A caller-side cancel is not a retryable transport fault.
                    if (signal && signal.aborted) throw new Error("bocha_web_search was cancelled.");
                    if (attempt < MAX_ATTEMPTS) {
                        await sleep(BACKOFF_MS[Math.min(attempt - 1, BACKOFF_MS.length - 1)]);
                        continue;
                    }
                    break;
                } finally {
                    guard.release();
                }
                if (response.ok) {
                    const rawBody = await response.text();
                    try {
                        return JSON.parse(rawBody);
                    } catch (error) {
                        throw new Error("Bocha returned a body that is not JSON: "
                            + String(error) + " - " + brief(rawBody));
                    }
                }
                const raw = await response.text();
                if (!RETRYABLE.has(response.status)) {
                    throw new Error("Bocha HTTP " + response.status + ". " + hintFor(response.status)
                        + (raw ? " Body: " + brief(raw) : ""));
                }
                lastFailure = "Bocha HTTP " + response.status + (raw ? " (" + brief(raw) + ")" : "");
                if (attempt < MAX_ATTEMPTS) {
                    await sleep(BACKOFF_MS[Math.min(attempt - 1, BACKOFF_MS.length - 1)]);
                    continue;
                }
            }
            throw new Error("Bocha search failed after " + MAX_ATTEMPTS + " attempts: " + lastFailure);
        }

        function render(query, pages, requested, withBody) {
            const lines = [];
            lines.push("Results for " + query + " - " + pages.length + " of " + requested + " requested");
            lines.push("");
            for (let i = 0; i < pages.length; i++) {
                const page = pages[i];
                lines.push((i + 1) + ". " + (page.name || "Untitled"));
                const link = page.url || page.displayUrl || "";
                if (link) lines.push("   " + link);
                const description = String(page.summary || page.snippet || "").replace(/\s+/g, " ").trim();
                if (description) lines.push("   " + description);
                if (withBody) {
                    const body = String(page.content || "").replace(/\s+/g, " ").trim();
                    if (body) {
                        lines.push("   body: "
                            + (body.length > MAX_BODY_CHARS ? body.slice(0, MAX_BODY_CHARS) + "..." : body));
                    }
                }
                const date = page.datePublished || page.dateLastCrawled;
                if (date) lines.push("   published: " + date);
                lines.push("");
            }
            return lines.join("\n").trim();
        }

        // Cut on a line boundary: the budget is measured on the UTF-8 form and a line is
        // kept or dropped whole, so a multi-byte character is never split in half.
        function truncate(text) {
            const lines = text.split("\n");
            const encoder = new TextEncoder();
            let bytes = 0;
            let kept = 0;
            for (const line of lines) {
                bytes += encoder.encode(line + "\n").length;
                if (kept >= MAX_LINES || bytes > MAX_BYTES) break;
                kept += 1;
            }
            if (kept >= lines.length) return { text: text, note: "" };
            return {
                text: lines.slice(0, kept).join("\n"),
                note: "[" + kept + " of " + lines.length + " lines shown; "
                    + (lines.length - kept) + " omitted.]",
            };
        }

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "bocha_web_search",
                label: "Bocha web search",
                description: [
                    "Search the web with Bocha (a Chinese search API) and return a plain list of",
                    "results: title, URL, summary, and publish date for each hit.",
                    "",
                    "Use it for current events, recent releases, prices, documentation, or anything",
                    "that may have changed after the training cutoff. Bocha covers Chinese-language",
                    "and mainland sources especially well. Keep queries short; prefer the user's own",
                    "language.",
                    "",
                    "Results are trimmed to " + MAX_LINES + " lines or " + MAX_BYTES + " bytes. If",
                    "trimmed, the full text is written to a temp file whose path is appended.",
                ].join("\n"),
                parameters: Type.Object({
                    query: Type.String({ description: "Search query." }),
                    count: Type.Optional(Type.Integer({
                        minimum: 1, maximum: 50,
                        description: "How many results to ask for (1-50). Default 10.",
                    })),
                    freshness: Type.Optional(Type.Union([
                        Type.Literal("noLimit"), Type.Literal("oneDay"), Type.Literal("oneWeek"),
                        Type.Literal("oneMonth"), Type.Literal("oneYear"),
                    ], { description: "Time window for results. Default noLimit." })),
                    summary: Type.Optional(Type.Boolean({
                        description: "Ask Bocha for an AI summary per result. Default true.",
                    })),
                    include: Type.Optional(Type.String({
                        description: "Only search these sites. Domains separated by | or , (max 20).",
                    })),
                    exclude: Type.Optional(Type.String({
                        description: "Never search these sites. Domains separated by | or , (max 20).",
                    })),
                    content: Type.Optional(Type.Boolean({
                        description: "Also return page body text (up to " + MAX_BODY_CHARS
                            + " characters each). Default false.",
                    })),
                }, { additionalProperties: false }),

                async execute(_toolCallId, params, signal) {
                    const key = process.env[KEY_ENV];
                    if (!key) {
                        // Second gate -- the first is MangoX not mounting this extension at all.
                        // Reaching here means the mount and the env disagree, so say so instead
                        // of failing silently.
                        return ok("bocha_web_search is not enabled in this session: "
                            + "no Bocha API key was provided.");
                    }
                    const requested = params.count || 10;
                    const payload = await postSearch({
                        query: params.query,
                        count: requested,
                        freshness: params.freshness || "noLimit",
                        summary: params.summary === undefined ? true : params.summary,
                        include: params.include || "",
                        exclude: params.exclude || "",
                    }, key, signal);

                    const logId = payload && payload.log_id ? " (log_id " + payload.log_id + ")" : "";
                    if (!payload || typeof payload !== "object") {
                        throw new Error("Bocha returned a payload that is not an object" + logId + ".");
                    }
                    if (Number(payload.code) !== 200) {
                        throw new Error("Bocha error code " + String(payload.code) + logId + ": "
                            + (payload.msg || "no message given"));
                    }
                    const webPages = payload.data ? payload.data.webPages : undefined;
                    const value = webPages ? webPages.value : undefined;
                    if (value === undefined) {
                        return ok('No web results for "' + params.query + '"' + logId + ".");
                    }
                    if (!Array.isArray(value)) {
                        throw new Error("Bocha returned webPages.value that is not an array"
                            + logId + ".");
                    }
                    const pages = value.filter(function (page) {
                        return typeof page === "object" && page !== null;
                    }).slice(0, requested);
                    if (pages.length === 0) {
                        return ok('No web results for "' + params.query + '"' + logId + ".");
                    }

                    const full = render(params.query, pages, requested, params.content === true);
                    const trimmed = truncate(full);
                    if (!trimmed.note) return ok(trimmed.text);

                    let note = trimmed.note;
                    try {
                        const dir = await mkdtemp(join(tmpdir(), "mangox-web-search-"));
                        const path = join(dir, "results.txt");
                        await writeFile(path, full, "utf8");
                        note += " Full output: " + path;
                    } catch (error) {
                        note += " (writing the full output failed: " + String(error) + ")";
                    }
                    return ok(trimmed.text + "\n\n" + note);
                },
            });
        }
        """#

    /// 把 `webSearchExtensionSource` 写到 `<dir>/mangox-web-search.ts`, 返回路径。
    ///
    /// 三个调用点，都**幂等**（内容相等就不写）:
    ///   ① `ChatStore.scanExtensions()` —— 无条件, 与 approval 同判据。这条保证"面板恒有一行",
    ///      没配 Key 时那一行挂着 `BlockedReason.needsBochaKey` 胶囊说明去哪儿补 ——
    ///      否则新用户在插件面板里根本看不到有这个能力。
    ///   ② `ChatStore.setBochaKey(_:)` —— 走 ① 的同一趟扫掠, 不单独调。
    ///   ③ `spawnProcess()` —— **挂载前保底, 这条不能省**: `-e` 列表里有它而文件不在 ⇒
    ///      pi 会 `Error: Failed to load extension` **直接起不来**（P12.1a 在 stderr 上见过这条）。
    ///
    /// ⚠️ **`dir` 必须能指到别处**（默认才是生产目录）: ① 的调用方是 `ChatStore`, 它的托管目录
    /// 在冒烟里是**夹具**（`managedExtensionsDir`）—— 写死 `NSHomeDirectory()` 会让冒烟
    /// 一边往真实 `~/.mangox/extensions` 落文件、一边在夹具里扫不到它（行根本不出, 断言恒假）。
    static func ensureWebSearchExtensionFile(dir: String? = nil) -> String {
        let dir = dir ?? (NSHomeDirectory() + "/.mangox/extensions")
        let path = dir + "/" + Self.webSearchExtensionFileName
        let source = Self.webSearchExtensionSource
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != source {
            try? source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    /// P10.1b: 把「这个 key 该怎么进子进程环境」抽成**纯函数** —— 门禁要能对四种组合变红
    /// （同 `businessExtensionPaths` 那条"提成 static 纯函数是为了这条判据能变红"）。
    ///
    /// 返回 `nil` = **不要碰 `p.environment`**：谁也不提这个变量时就不该凭空造一份环境字典
    /// （那会把父进程的整个环境连带复制进去，含义就变了）。
    ///
    /// ⚠️ **两个方向都要管**，只写"有 key 就设进去"是不够的:
    ///   · `key != nil` ⇒ 设进去（`existing` 为空就拿父环境当底，同 dream 那道守卫的写法）；
    ///   · `key == nil` 且**父进程环境里已有同名变量** ⇒ 必须**删掉**。
    ///     反例：用户在终端 `export MANGOX_BOCHA_KEY=…` 之后从这个 shell 起 App ⇒ 子进程会继承它,
    ///     于是「App 里没配 key（面板显示未配置、扩展不挂）」与「扩展其实拿到了 key」**同时为真**,
    ///     而且这条**不会亮任何红灯**。标记不许比事实说得多 —— 所以这个键必须由我们完全接管。
    static func webSearchEnvironment(existing: [String: String]?,
                                     key: String?,
                                     inherited: [String: String]) -> [String: String]? {
        if key == nil, inherited[webSearchKeyEnvKey] == nil { return nil }
        var env = existing ?? inherited
        env[webSearchKeyEnvKey] = key      // nil = 移除该键（Swift 字典下标赋 nil 即删除）
        return env
    }

    // MARK: - P18 批 1: computer use (自建扩展, 只读)

    /// `computer_` 三个工具**各自的名字常量**。
    ///
    /// ⚠️ 单独成常量不是为了好看: `kindFor` 与 `toolHead` 都要按名认它们, 而那两处
    ///    **写不下 case 模式**（Swift 的 `switch` 不放 static property）⇒ 只能写 `if` 比较。
    ///    若那两处写死字面量, 改名时唯一的信号是"卡片标签悄悄退回 OTHER + `app` 从卡上消失",
    ///    两个都是**零红灯**的退化。用常量则编译器盯着。
    nonisolated static let computerReadToolName = "computer_read"
    nonisolated static let computerActToolName = "computer_act"
    nonisolated static let computerOpenToolName = "computer_open"
    /// 第四档(2026-11-10): 按坐标点一下。**单独一个工具**, 不并进 `computer_act` ——
    /// 它前面没有元素, 也没有 `op`; 并进去等于让模型以为 act 有时可以不管编号。
    nonisolated static let computerTapToolName = "computer_tap"
    /// 第五档(2026-11-10): 往当前焦点里写一段字(可选补一次回车)。**又一个独立工具** ——
    /// 与 `tap` 同理: 它前面没有元素、没有编号、也没有坐标, 只有"焦点"。
    nonisolated static let computerTypeToolName = "computer_type"
    /// 第六档(2026-11-19): 发导航键 / 修饰键组合。**又一个独立工具**, 理由比前两个硬:
    ///
    /// ⚠️ 键盘**没有作用域** —— 一次 `Cmd+A` 选中的是全篇, 不管它是在哪一行按下;
    ///    2026-11-19 在 WPS 上真发生过: `Cmd+A` 之后一个 `delete` 清掉了整篇正文。
    ///    所以它既不能并进 `computer_type`(那个只写字符串、不按修饰键), 也不能默认开。
    nonisolated static let computerKeysToolName = "computer_keys"

    /// P18: computer 扩展注册出来的工具名 —— 与 `computerExtensionSource` 同源同改
    /// (冒烟断言"每个名字都能在源码里找到 `name: "<名字>"`", 同 `webSearchToolNames` 那条守)。
    ///
    /// ⚠️ **现在有六个工具**: 读一个、动一个、打开一个、按坐标点一个、往焦点里写一个、发键一个。
    nonisolated static let computerToolNames: [String] =
        [computerReadToolName, computerActToolName, computerOpenToolName,
         computerTapToolName, computerTypeToolName, computerKeysToolName]

    nonisolated static let computerExtensionFileName = "mangox-computer.ts"

    /// P18 批 1/2b: 界面读取器 + 动作面 —— 一次连一次问, 一问一答。
    ///
    /// ⚠️ **这个扩展是哑的**(同 dream 那条纪律): 读 env → 连 socket → 发一行 → 收一行。
    ///    判断全在 Swift 侧: "能不能读这个 App" 在 `ComputerScope`/`ComputerServer.isInScope`,
    ///    "读出来长什么样" 在 `AXSnapshot`, "哪些动作恒拒 / 该不该动" 在 `ComputerActGuard`。
    ///    判据写在 TS 里 ⇒ 冒烟断言不到(扩展不参与 Swift 编译), 只能靠肉眼看。
    ///
    /// ⚠️ **双闸门**(同 dream / webSearch): ① 挂载闸门 —— 作用域为空时 `spawnProcess`
    ///    连 helper 都不起, 也不挂扩展; ② 激活闸门 —— 只有那一次 spawn 设 `MANGOX_COMPUTE_SOCK`。
    ///    两条都要: 只挂不给 env ⇒ 工具每次回"未启用"; 只给 env 没挂 ⇒ 模型看不到这个工具。
    ///
    /// ⚠️ **失败分两类, 处理方式不同**: "被拒"(作用域/权限)是**一个答案**, 用 `ok()` 把
    ///    Swift 侧给的人话原样交回去, 让模型换目标; "连不上/超时"是**故障**, 用 `throw`
    ///    让它显示在跑的过程里 —— 否则模型会把"没回音"读成"界面上什么都没有"。
    static let computerExtensionSource: String = #"""
        // Auto-deployed by MangoX (P18). Read-only window reader: one JSON line in, one
        // JSON line out, over a unix socket that only MangoX itself can reach.
        //
        // Deliberately dumb: nothing here decides anything. Which apps are in scope, how
        // the tree is shaped, which values get masked -- all of that is decided in Swift,
        // where a counterexample can be written against it.
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";
        import { connect } from "node:net";

        const SOCK_ENV = "MANGOX_COMPUTE_SOCK";

        // ⚠️ **必须大于 helper 自己的 `AXAdapter.readTimeout`(12 秒)**, 否则那道闸永远看不见:
        //    助手保证"最迟 12 秒交卷, 哪怕只读到一部分", 而这边 10 秒就 destroy 了 socket ——
        //    于是每次慢读的结果都是"连不上/超时"这种**故障**, 而不是助手辛苦写出来的
        //    "只读到前面一部分"。实测(2026-11-13, 企业微信): 助手 12 秒时已经把 695 项快照
        //    准备好了, 而模型看到的是 `no reply within 10000ms` ⇒ 它以为工具坏了, 会重试。
        //    20 秒 = 12 秒 + 渲染/传输余量(含可选截图, 实测 <1 秒)。
        //    `run.sh` ③w 钉着"这个数 > 那边那个数", 改一个忘了另一个会红。
        const TIMEOUT_MS = 20000;

        function ok(text) {
            return { content: [{ type: "text", text: text }], details: undefined };
        }

        // Same answer plus a screenshot. The block shape mirrors pi's ImageContent
        // ({ type: "image", data: base64, mimeType }); get a key wrong here and the result
        // is "no image" with no error anywhere -- the model just never sees it.
        //
        // Text always comes first: the outline carries the row numbers, and a picture
        // without numbers is something the model can look at but cannot act on.
        function okImage(text, image) {
            const parts = [{ type: "text", text: text }];
            if (image && typeof image.data === "string" && image.data) {
                parts.push({
                    type: "image",
                    data: image.data,
                    mimeType: typeof image.mimeType === "string" ? image.mimeType : "image/png",
                });
            }
            return { content: parts, details: undefined };
        }

        // Framing is one JSON object per line (ComputerFraming on the Swift side): a request
        // is one line, a reply is one line. No length prefix -- one round trip carries exactly
        // one message, and newline framing stays readable in `nc` when things go wrong.
        function ask(sockPath, payload) {
            return new Promise(function (resolve, reject) {
                const socket = connect(sockPath);
                // ⚠️ 攒**字节**、拿到完整行才解码。socket 的 chunk 边界与字符边界无关,
                //    每来一块就 `String(chunk)` 会把跨块的汉字劈成两半, 两半各自解成
                //    U+FFFD ⇒ 回执里凭空多出替换字符, 而**整条链路零报错**。
                //    实测(2026-10-29): 一条 483 字的 Safari 脚注里「条」正好卡在块边界,
                //    模型读到的是 `符合折抵???件`, 我一开始还以为是网页本身的乱码。
                let buffer = Buffer.alloc(0);
                let settled = false;
                const fail = function (message) {
                    if (settled) return;
                    settled = true;
                    clearTimeout(timer);
                    socket.destroy();
                    reject(new Error(message));
                };
                const timer = setTimeout(function () {
                    fail("no reply from the window reader within " + TIMEOUT_MS + "ms");
                }, TIMEOUT_MS);
                socket.on("error", function (error) { fail(String(error)); });
                socket.on("connect", function () {
                    socket.write(JSON.stringify(payload) + "\n");
                });
                socket.on("data", function (chunk) {
                    if (settled) return;
                    buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
                    const cut = buffer.indexOf(0x0a);
                    if (cut < 0) return;
                    settled = true;
                    clearTimeout(timer);
                    const line = buffer.subarray(0, cut).toString("utf8");
                    socket.end();
                    let reply;
                    try {
                        reply = JSON.parse(line);
                    } catch (error) {
                        fail("the window reader sent a line that is not JSON: " + line);
                        return;
                    }
                    resolve(reply);
                });
            });
        }

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "computer_read",
                label: "Read window",
                description: [
                    "Read the front window of a macOS app as a numbered outline: role, title, value and the",
                    "actions each control offers. Row numbers and the snapshot `seq` -- the only things",
                    "computer_act accepts -- come from here and nowhere else.",
                    "",
                    "Only apps the user allowed for this session are readable; a refusal names the ones you",
                    "can read, so never guess through candidates.",
                    "",
                    "Numbers are valid for this outline only. Once anything changes they are stale, and an old",
                    "number is refused rather than approximated: read again, never reuse or guess one.",
                    "",
                    "A long window is cut off and the outline's last line says how many rows are missing --",
                    "scroll with computer_act, then read again. Values in password fields arrive masked; a",
                    "masked value is one you were never given.",
                    "",
                    "`includeImage` adds a screenshot of that same window, if the user turned vision on for",
                    "the app. A picture carries no row numbers, so it never replaces a read: ask for one when",
                    "the outline is thin or is the only way to see what is there -- and remember it costs",
                    "context. When there is no picture the text says why; do not retry it in a loop.",
                    "",
                    "Leave the picture out when you only need **fresh numbers to act again**: after any tap,",
                    "type or key the old outline is void and you must read once more, but that read is",
                    "usually just bookkeeping. A picture you did not need stays in this conversation and is",
                    "re-read on every later turn, so a blind screenshot is the most expensive kind. Take one",
                    "when you have to *judge* something the text cannot say -- a colour, a position, whether",
                    "the click landed.",
                    "",
                    "`imageScope` picks what goes into that picture. The default, `screen`, is the area",
                    "the window occupies on the display, so panels, sheets and menus drawn over it are in",
                    "the picture -- use it before computer_tap, since a tap lands on whatever is really on",
                    "top. `window` is the window's own surface only: it still shows the content while",
                    "another app covers it or while it hangs off the edge of the display, but a floating",
                    "panel of the same app will NOT be in that picture, and computer_tap will refuse a",
                    "point that another window of that app is covering.",
                ].join("\n"),
                parameters: Type.Object({
                    app: Type.Optional(Type.String({
                        description: "App name or bundle id. Omit to read the frontmost app.",
                    })),
                    includeImage: Type.Optional(Type.Boolean({
                        description: "Also return a screenshot of the window (only if the user"
                            + " turned vision on for this app). Omit it when you only need fresh"
                            + " numbers to keep acting -- an unneeded picture is re-read on every"
                            + " later turn.",
                    })),
                    imageScope: Type.Optional(Type.String({
                        enum: ["screen", "window"],
                        description: "Which part of the display to capture. `screen` (default)"
                            + " = the area the window occupies, overlays included; `window`"
                            + " = the window's own surface only (visible even when covered or"
                            + " off-screen, but same-app floating panels are left out).",
                    })),
                }, { additionalProperties: false }),

                async execute(_toolCallId, params) {
                    const sock = process.env[SOCK_ENV];
                    if (!sock) {
                        // Second gate -- the first is MangoX not mounting this extension at
                        // all. Reaching here means mount and env disagree, so say so rather
                        // than letting the model retry a tool that cannot work.
                        return ok("computer_read is not enabled in this session: no "
                            + SOCK_ENV + " was provided.");
                    }
                    let reply;
                    try {
                        reply = await ask(sock, {
                            op: "read",
                            app: params.app || "",
                            includeImage: params.includeImage === true,
                            imageScope: params.imageScope === undefined
                                ? "" : String(params.imageScope),
                        });
                    } catch (error) {
                        // A transport failure is a failure, not an answer.
                        throw new Error("could not reach the window reader: " + String(error));
                    }
                    if (!reply || typeof reply !== "object") {
                        throw new Error("the window reader sent something that is not an object.");
                    }
                    if (reply.ok !== true) {
                        // A refusal IS an answer. Hand back the app's own wording verbatim.
                        return ok("Refused: " + (reply.error || "no reason given."));
                    }
                    return okImage(typeof reply.text === "string"
                        ? reply.text
                        : "(the reader returned no text)", reply.image);
                },
            });

            pi.registerTool({
                name: "computer_act",
                label: "Act on a window",
                description: [
                    "One action on the window you just read. The target is `index` from that read, or -- press",
                    "only -- the `point` printed at the end of an outline row, which is resolved back to a row",
                    "so the same checks apply (prefer `index`). Nothing else: no dragging, no raw keystrokes.",
                    "",
                    "`seq` must come from the read that printed that row: numbers from an earlier snapshot are",
                    "refused as stale, and nothing is guessed for you. The reply is the *change* plus the new",
                    "`seq`, not a fresh outline.",
                    "",
                    "setValue refuses empty text on purpose (that is a wipe, not a no-op). If the reply says the",
                    "value did not change, \"focus\" that row first, then setValue again. scroll moves about a",
                    "tenth of the way per call -- read again to see where you landed; if it says no scroll bar",
                    "was found, that app cannot be scrolled this way, so tell the user instead of retrying.",
                    "",
                    "`open` is for rows that offer AXOpen instead of AXPress -- calendar day cells, desktop",
                    "file icons. On those, press returns success and does nothing. An open reply can say the",
                    "action \"may have gone through\": the system returned an error code this action is known",
                    "to report even when it worked. Never retry it -- read again and see what changed.",
                    "",
                    "`confirm` submits the text you just setValue'd (AXConfirm). Calendar's quick-event box is the",
                    "case that forced it: its tree has no Done button, press on the field returns success and does",
                    "nothing, and only confirm turns the text into an event. It is refused on anything that is not a",
                    "text field -- it is not a universal \"OK\", and on a dialog button it would just be press wearing",
                    "a friendlier name.",
                    "",
                    "`custom` runs an action the row declares itself, and it is the way to reach features that are",
                    "not a control in the window -- deleting a note in Notes, deleting a reminder. Name it with",
                    "`text` in the app's own words: that name is localized and carries a noisy tail, so it",
                    "is matched as a substring and must hit exactly one action -- otherwise the call is",
                    "refused, and the refusal lists the names the row actually offers: pass one of those",
                    "back. It never runs an AX standard action, and it is refused on containers (a table's",
                    "own Delete acts on whatever is selected, not on the row you named). Its name goes",
                    "through the same permanent-deletion check as any button.",
                    "",
                    "Always refused, whoever asks: paying or ordering, permanent deletion (Shift-Cmd-Delete",
                    "included), typing into password fields, and confirming a save sheet (it is cancelled and",
                    "the document stays untouched -- that call is the person's).",
                    "",
                    "If the reply says a human just touched the mouse or keyboard, nothing happened: you stepped",
                    "aside on purpose. Say what you were about to do and wait -- do not retry in a loop.",
                    "",
                    "Only apps the user marked actable can be touched; a refusal says whether it was permission",
                    "or policy, so do not retry the same call.",
                ].join("\n"),
                parameters: Type.Object({
                    app: Type.Optional(Type.String({
                        description: "App name or bundle id. Omit to act on the frontmost app.",
                    })),
                    op: Type.String({
                        enum: ["press", "setValue", "focus", "scroll", "open", "confirm", "custom"],
                        description: "press = invoke the control; setValue = write text into a field;"
                            + " focus = move keyboard focus onto it; scroll = move a scroll area;"
                            + " open = open/enter the thing this row points at (a file, a folder,"
                            + " a day) -- the one to use when press is refused because the row"
                            + " only offers AXOpen; confirm = submit the text you just set there"
                            + " (a quick-event box commits only this way); custom = run an action"
                            + " the row declares itself (delete a note, delete a reminder) --"
                            + " name it with `text`.",
                    }),
                    index: Type.Optional(Type.Number({
                        description: "The row number from the outline you are acting on."
                            + " Give either `index` or `point`, never both.",
                    })),
                    point: Type.Optional(Type.Object({
                        x: Type.Number(),
                        y: Type.Number(),
                    }, { additionalProperties: false,
                         description: "Only for press, instead of `index`: the screen point to"
                            + " click, in the same global coordinates as the (x,y) printed at the"
                            + " end of each outline row. It is resolved back to a row, so the"
                            + " usual checks still apply -- and a point with no element under it"
                            + " is refused." })),
                    seq: Type.Number({
                        description: "The snapshot sequence number returned by that read.",
                    }),
                    text: Type.Optional(Type.String({
                        description: "setValue: the text to write (must not be empty). custom: a"
                            + " fragment of that action's name, in the app's own words -- it must"
                            + " match exactly one of the actions that row declares.",
                    })),
                    direction: Type.Optional(Type.String({
                        enum: ["up", "down"],
                        description: "Only for scroll, and required there: which way to move.",
                    })),
                }, { additionalProperties: false }),

                async execute(_toolCallId, params) {
                    const sock = process.env[SOCK_ENV];
                    if (!sock) {
                        return ok("computer_act is not enabled in this session: no "
                            + SOCK_ENV + " was provided.");
                    }
                    let reply;
                    try {
                        reply = await ask(sock, {
                            op: "act",
                            app: params.app || "",
                            action: params.op,
                            index: params.index ?? 0,
                            seq: params.seq,
                            text: params.text || "",
                            direction: params.direction || "",
                            point: params.point,
                        });
                    } catch (error) {
                        throw new Error("could not reach the window reader: " + String(error));
                    }
                    if (!reply || typeof reply !== "object") {
                        throw new Error("the window reader sent something that is not an object.");
                    }
                    if (reply.ok !== true) {
                        return ok("Refused: " + (reply.error || "no reason given."));
                    }
                    return ok(typeof reply.text === "string"
                        ? reply.text
                        : "(the reader returned no text)");
                },
            });

            pi.registerTool({
                name: "computer_tap",
                label: "Tap a point",
                description: [
                    "Click one point -- for an app whose outline has no row you can act on, where the picture",
                    "is the only thing that shows what is there. Read it first with `includeImage`: that read",
                    "also prints where the window sits on screen, so the point is window origin plus the",
                    "position you measured in the picture.",
                    "",
                    "This is not a looser `press`: nothing is resolved back to a control, so the checks that",
                    "guard `press` (paying or ordering, permanent deletion, password fields) cannot run here.",
                    "What is left is geometry -- the window must not have moved since that read, the point must",
                    "be inside it, and the window on top of that point must be the same one. Each refusal says",
                    "which of those failed: re-read and measure again rather than nudging the point.",
                    "",
                    "It is off by default and it uses the real mouse, so the cursor moves for a moment. Do not",
                    "use it while the person may be working, and never for something a row number could do.",
                    "",
                    "A reply that says it clicked means the point was pressed -- not that the interface did",
                    "what you wanted. Read again to find out.",
                ].join("\n"),
                parameters: Type.Object({
                    app: Type.Optional(Type.String({
                        description: "App name or bundle id. Omit to tap in the frontmost app.",
                    })),
                    x: Type.Number({
                        description: "Global screen x, left edge origin (same numbers as the outline frames).",
                    }),
                    y: Type.Number({
                        description: "Global screen y, top edge origin.",
                    }),
                    seq: Type.Number({
                        description: "The snapshot sequence from the read whose picture you measured.",
                    }),
                }, { additionalProperties: false }),

                async execute(_toolCallId, params) {
                    const sock = process.env[SOCK_ENV];
                    if (!sock) {
                        return ok("computer_tap is not enabled in this session: no "
                            + SOCK_ENV + " was provided.");
                    }
                    let reply;
                    try {
                        reply = await ask(sock, {
                            op: "tap",
                            app: params.app || "",
                            point: { x: params.x, y: params.y },
                            seq: params.seq,
                        });
                    } catch (error) {
                        throw new Error("could not reach the window reader: " + String(error));
                    }
                    if (!reply || typeof reply !== "object") {
                        throw new Error("the window reader sent something that is not an object.");
                    }
                    if (reply.ok !== true) {
                        return ok("Refused: " + (reply.error || "no reason given."));
                    }
                    return ok(typeof reply.text === "string"
                        ? reply.text
                        : "(the reader returned no text)");
                },
            });

            pi.registerTool({
                name: "computer_type",
                label: "Type into the focused field",
                description: [
                    "Type a piece of text into whatever currently has the keyboard focus in that app -- for an",
                    "app whose outline has no usable text field at all (WeChat exposes five nodes and no input",
                    "control, so `setValue` structurally cannot reach it).",
                    "",
                    "It goes to the focus, not to a coordinate and not to a row: click the field first (with tap",
                    "or press), then type. The read must still be the latest one -- if the interface moved in",
                    "between, the focus may no longer be where you think it is.",
                    "",
                    "Line breaks are refused on purpose: in WeChat, Slack and iMessage the Return key sends. A",
                    "paragraph with five line breaks would go out as five messages. Write one line per call.",
                    "",
                    "`submit` presses Return once after the text. It is off by default because that is what",
                    "sends, and sending cannot be undone. A reply that says the text was typed only means the",
                    "keys went out -- read again to see whether it landed, or went out.",
                ].join("\n"),
                parameters: Type.Object({
                    app: Type.Optional(Type.String({
                        description: "App name or bundle id. Omit to type into the frontmost app.",
                    })),
                    text: Type.String({
                        description: "The text to type. No line breaks. At most 2000 characters.",
                    }),
                    submit: Type.Optional(Type.Boolean({
                        description: "Press Return once after typing (usually means send / confirm)."
                            + " Default false.",
                    })),
                    seq: Type.Number({
                        description: "The snapshot sequence from the most recent read.",
                    }),
                }, { additionalProperties: false }),

                async execute(_toolCallId, params) {
                    const sock = process.env[SOCK_ENV];
                    if (!sock) {
                        return ok("computer_type is not enabled in this session: no "
                            + SOCK_ENV + " was provided.");
                    }
                    let reply;
                    try {
                        reply = await ask(sock, {
                            op: "type",
                            app: params.app || "",
                            text: params.text,
                            submit: params.submit === true,
                            seq: params.seq,
                        });
                    } catch (error) {
                        throw new Error("could not reach the window reader: " + String(error));
                    }
                    if (!reply || typeof reply !== "object") {
                        throw new Error("the window reader sent something that is not an object.");
                    }
                    if (reply.ok !== true) {
                        return ok("Refused: " + (reply.error || "no reason given."));
                    }
                    return ok(typeof reply.text === "string"
                        ? reply.text
                        : "(the reader returned no text)");
                },
            });

            pi.registerTool({
                name: "computer_keys",
                label: "Send navigation or modified keys",
                description: [
                    "Send a short burst of keystrokes to that app: arrows, Home/End, Page Up/Down, Tab, Esc,",
                    "Space, Delete, Backspace, Return -- optionally with Shift, Option, Command or Control.",
                    "This is how text gets selected character by character (shift+right), how a caret is moved",
                    "to the start of a line (home), and how a menu shortcut is used when no row offers it.",
                    "",
                    "Letters are also accepted, but only in the exact shape `command+<one letter or digit>`",
                    "(command+s, not command+shift+s), and only for apps that have to be driven by",
                    "coordinates because AX cannot reach them -- today that is WPS (n new, s save,",
                    "z undo, y redo, f find, c copy, v paste, b/i/u bold / italic / underline) and",
                    "WeChat (f search, n new chat, 1 chats, 2 contacts, c copy, v paste). Apps that AX",
                    "can drive are refused outright: they need no keys, and a keystroke lands wherever",
                    "the focus already is. `command+v` is the one that matters most -- in a self-drawn",
                    "document the paste button can only be hit by coordinate. Do not guess a letter;",
                    "the reply names the whole list for the app you asked about.",
                    "",
                    "⚠️ Keys have no scope. There is no row and no coordinate, so nothing is resolved back to a",
                    "control and none of the checks that guard `press` can run -- `command+a` selects the whole",
                    "document no matter where the caret was. Combine it with `delete` and the document is gone,",
                    "with no undo anywhere in this tool. Send one stroke at a time, read again between rounds,",
                    "and never send a destructive key (Delete, Backspace, Return, Space, or any Command /",
                    "Option / Control combination built on a non-letter key) unless you can say what currently",
                    "has the focus.",
                    "",
                    "Quitting, closing a window and moving to the trash are never sent: command+q, command+w,",
                    "command+backspace and command+delete are refused outright, even on an allowlisted app.",
                    "",
                    "It is off by default and it uses the real keyboard, so anything typed at that moment goes",
                    "into that app. Do not use it while the person may be working.",
                    "",
                    "A reply that says the keys went out only means they were posted -- not that the interface",
                    "did what you wanted. Read again (or open the saved file) to find out.",
                ].join("\n"),
                parameters: Type.Object({
                    app: Type.Optional(Type.String({
                        description: "App name or bundle id. Omit to send keys to the frontmost app.",
                    })),
                    strokes: Type.Array(Type.String({
                        description: "One stroke per entry, e.g. \"left\", \"shift+right\", \"command+n\".",
                    }), {
                        description: "1 to 24 strokes, sent in order.",
                    }),
                    seq: Type.Number({
                        description: "The snapshot sequence from the most recent read.",
                    }),
                }, { additionalProperties: false }),

                async execute(_toolCallId, params) {
                    const sock = process.env[SOCK_ENV];
                    if (!sock) {
                        return ok("computer_keys is not enabled in this session: no "
                            + SOCK_ENV + " was provided.");
                    }
                    let reply;
                    try {
                        reply = await ask(sock, {
                            op: "keys",
                            app: params.app || "",
                            strokes: params.strokes,
                            seq: params.seq,
                        });
                    } catch (error) {
                        throw new Error("could not reach the window reader: " + String(error));
                    }
                    if (!reply || typeof reply !== "object") {
                        throw new Error("the window reader sent something that is not an object.");
                    }
                    if (reply.ok !== true) {
                        return ok("Refused: " + (reply.error || "no reason given."));
                    }
                    return ok(typeof reply.text === "string"
                        ? reply.text
                        : "(the reader returned no text)");
                },
            });

            pi.registerTool({
                name: "computer_open",
                label: "Open an app or a URL",
                description: [
                    "Open a macOS app, or bring it to the front if it is already running. An app with no window",
                    "has nothing to read or act on, so open it first.",
                    "",
                    "`app` is required -- a name or bundle id, matched against the bundle id, its last segment",
                    "and the display name (prefer the bundle id when a plain name is not recognised). It never",
                    "guesses.",
                    "",
                    "Pass `url` to have that app open a web address (`http` / `https` only; a bare domain like",
                    "`baidu.com` is read as `https://baidu.com`). This is the ONLY way to navigate a browser:",
                    "both Safari's and Chrome's address fields accept the text but never actually go there,",
                    "so do not try to drive the address bar with computer_act. It always opens a NEW TAB --",
                    "it cannot replace the page you are on. The page needs a few seconds to paint, so wait",
                    "before computer_read or you will only see a shell.",
                    "",
                    "Gated by the reading permission, not the acting one. It only launches: call computer_read",
                    "afterwards for an outline and a `seq`.",
                ].join("\n"),
                parameters: Type.Object({
                    app: Type.String({
                        description: "App name or bundle id. Required -- there is no frontmost default.",
                    }),
                    url: Type.Optional(Type.String({
                        description: "Web address to open in that app. http/https only. Opens a new tab.",
                    })),
                }, { additionalProperties: false }),

                async execute(_toolCallId, params) {
                    const sock = process.env[SOCK_ENV];
                    if (!sock) {
                        return ok("computer_open is not enabled in this session: no "
                            + SOCK_ENV + " was provided.");
                    }
                    let reply;
                    try {
                        reply = await ask(sock, { op: "open", app: params.app || "", url: params.url || "" });
                    } catch (error) {
                        throw new Error("could not reach the window reader: " + String(error));
                    }
                    if (!reply || typeof reply !== "object") {
                        throw new Error("the window reader sent something that is not an object.");
                    }
                    if (reply.ok !== true) {
                        return ok("Refused: " + (reply.error || "no reason given."));
                    }
                    return ok(typeof reply.text === "string"
                        ? reply.text
                        : "(the reader returned no text)");
                },
            });
        }
        """#

    /// 把 `computerExtensionSource` 写到 `<dir>/mangox-computer.ts`, 返回路径。
    ///
    /// ⚠️ `dir` 必须能指到别处(默认才是生产目录) —— 同 `ensureWebSearchExtensionFile` 那条:
    /// 写死 `NSHomeDirectory()` 会让冒烟一边往真实 `~/.mangox/extensions` 落文件、一边在
    /// 夹具里扫不到它。
    static func ensureComputerExtensionFile(dir: String? = nil) -> String {
        let dir = dir ?? (NSHomeDirectory() + "/.mangox/extensions")
        let path = dir + "/" + Self.computerExtensionFileName
        let source = Self.computerExtensionSource
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != source {
            try? source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    // MARK: - AgentTransport

    func send(prompt: String, images: [OutgoingImage]) {
        ensureProcessForCwd()
        guard process != nil else {
            // ⚠️ 这条静默 return 是「生成中…」常亮的源头: Store 侧 `runningTurns` 已经在
            //    `beginTurn` 里置位, 而这里一个事件都不发 ⇒ 没有任何东西负责收尾。
            Log.process("send-no-process", "chars", "\(prompt.count)")
            return
        }
        turnActive = true
        turnProducedOutput = false
        turnSawAgentStart = false
        turnUserAborted = false
        textMessageID = nil
        thinkMessageID = nil
        toolCards.removeAll()
        toolStartAt.removeAll()
        autoJudgeBlocks.removeAll()   // P10.2a-0: 本回合的拦截记录从零开始
        execActions.removeAll()       // P19 S6: 同层 —— 本回合的过闸落痕从零开始
        emit(.streamStarted)
        // P7-M6b: images:[{type,data(base64),mimeType}] — autoResize 不覆盖 RPC base64,
        // 进这里的已由 ImagePipeline.compressForSend 压过 (≤1536px JPEG)。
        var cmd: [String: Any] = ["id": "req-\(nextRequestId())", "type": "prompt", "message": prompt]
        if !images.isEmpty {
            cmd["images"] = images.map { ["type": "image",
                                          "data": $0.data.base64EncodedString(),
                                          "mimeType": $0.mimeType] }
        }
        sendCommand(cmd)
        // 诊断日志: 只记长度不记正文（正文走 `diag_log_body` 那个二级开关，见 `ChatStore`）。
        Log.process("send", ["chars": "\(prompt.count)", "imgs": "\(images.count)",
                             "pid": "\(process?.processIdentifier ?? -1)"])
    }

    /// P19 S6: 把流式文本接到"模型说到第几步"上。
    ///
    /// 只留尾部 —— 判据要的是**最新**那个声明，而正文可能很长（一条结论的诊断就有几屏）。
    /// 声明本身很短，落在尾部缓冲之外的唯一情况是"声明在第 1 步、之后写了两千字才动手"，
    /// 那时尾巴里通常还有一次重复的步骤声明；没有就按"没声明"拒（安全的方向）。
    private func trackDeclaredStep(_ delta: String) {
        execStepBuffer += delta
        if execStepBuffer.count > Self.execStepBufferMax {
            execStepBuffer = String(execStepBuffer.suffix(Self.execStepBufferMax))
        }
        if let step = ExecGate.declaredStep(in: execStepBuffer) { execDeclaredStep = step }
    }

    /// P19 S6: 记一笔"被门拦下"。卡片上要说话（人到会话里能看见停在哪一步），
    /// 落痕由收尾写进 `agent_finding_actions`（`execActions`）。
    private func recordExecDenial(_ d: ExecGate.Denial, step: Int, tool: String, target: String,
                                  callId: String, card: ToolCall?) {
        recordExecAction(step: step, kind: tool, target: target,
                         result: d.kind == .drift ? "drifted" : "denied_by_redline")
        guard let card else { return }
        let updated = card.withPhase(.error(String(format: L("MangoX 执行拦下: %@"), d.reason)))
        toolCards[callId] = updated
        emit(.toolUpdated(updated))
    }

    /// 落痕。按步骤号归并 —— 同一步里连着三个命令是常态，逐个并列会把"第 2 步"刷成三十行。
    private func recordExecAction(step: Int, kind: String, target: String?, result: String) {
        // ⚠️ 只存前 200 字：命令里可能带 token（`curl -H "Authorization: Bearer …"`），
        // 而这张表会一直留在磁盘上（诊断日志"不含正文"的同一条理由）。
        let clipped = target.map { String($0.prefix(200)) }
        if var rec = execActions[step] {
            rec.count += 1
            rec.kind = kind
            rec.target = clipped ?? rec.target
            rec.result = result
            execActions[step] = rec
        } else {
            execActions[step] = ExecAction(step: step, kind: kind, target: clipped,
                                           result: result, count: 1)
        }
    }

    func cancel() {
        // 用户停 = 零产出是预期的 ⇒ 不许被空回合判据算成"引擎出错"（同 Store 侧 elapsed==nil 的语义）
        turnUserAborted = true
        sendCommand(["type": "abort"])
    }

    func respondToPermission(toolId: UUID, decision: PermissionDecision) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.toolUUID == toolId }) else { return }
        let pending = pendingApprovals.remove(at: idx)
        let value: String
        switch decision {
        case .allow:        value = "Allow"
        case .alwaysAllow:  value = "Allow always"   // 扩展侧 Set 记忆, 会话内不再询问
        case .deny:         value = "Deny"
        }
        // UI 即时反馈; allow 的后续 running/事件由 pi 的 tool_execution 流接管
        // (响应统一走 respondExtensionUI: Allow 时内部重置计时起点, 审批等待不计入时长)
        if var card = toolCards[pending.callId] {
            switch decision {
            case .allow, .alwaysAllow: card = card.withPhase(.running)
            case .deny:                card = card.withPhase(.error(L("已拒绝")))
            }
            respondExtensionUI(pending.requestId, value: value, callId: pending.callId)
            toolCards[pending.callId] = card
            emit(.toolUpdated(card))
        } else {
            respondExtensionUI(pending.requestId, value: value, callId: pending.callId)
        }
    }

    /// 老入口 (askApproval 开关): true → 交互弹卡; false → 全放行。
    /// P10.2a-0 拆档后它只是二值映射, 需要 autoJudge 的调用点走 updateApprovalMode。
    func updateApprovalPolicy(askApproval: Bool) {
        approvalMode = askApproval ? .interactive : .autoAllow
    }

    /// P10.2a-0: 直接指定裁决档 (邮箱哨兵 = .autoJudge)。
    func updateApprovalMode(_ mode: ApprovalMode) {
        approvalMode = mode
    }

    func updateWorkingDirectory(_ path: String?) {
        desiredCwd = path
    }

    func updateKnowledgeContext(_ text: String?) {
        desiredKnowledge = text
    }

    func updateBashWhitelist(_ tokens: Set<String>) {
        learnedBashTokens = tokens
    }

    /// P13 + P15.3: 从一批路径里挑出**业务扩展** —— MangoX 自管的这几个都要滤掉, 它们由**轴**决定
    /// 挂不挂 (approval = 恒挂, codemode = 档位轴, dream = 那一次 fire 的实例, computer = 作用域
    /// 开关), 不能被业务扩展扫掠重复挂一遍。提成 static 纯函数是为了这条判据能**在门禁里变红**
    /// (实例侧只有 private 状态)。
    ///
    /// ⚠️ 漏一个的后果不是"多挂一次也没事": 同一个 `.ts` 会在同一次 spawn 里被
    /// `--extension` **传两次**(一次来自这里, 一次来自它自己的那条轴参数) ⇒ 工具注册两遍。
    /// 2026-11-10 实测就是漏了 `mangox-computer.ts`(它在面板里是"开着"的, 于是一路混进业务列表)。
    /// 加新的自管扩展时, 这条过滤与 `ExtensionItem.builtInNames` **要一起改**。
    static func businessExtensionPaths(_ paths: [String]) -> [String] {
        paths.filter {
            !$0.hasSuffix("mangox-approval.ts")
                && !$0.hasSuffix("mangox-codemode.ts")
                && !$0.hasSuffix("mangox-dream.ts")
                && !$0.hasSuffix("mangox-computer.ts")
                // 2026-11-23 补两个: 飞书发附件与 follow-up 都是**per-turn 轴**挂的，
                // 与 dream 同一类。⚠️ 它们原来不在这张滤网里 ⇒ 面板里它们是"开着"的，
                // 一旦磁盘上有那个 .ts，就会混进业务列表 ⇒ **同一次 spawn 传两遍**
                // （工具注册两遍），而且更坏: 普通会话也挂得上它们，双闸门的"挂载"那一道
                // 当场失效（漏的样子是"聊天时也能给自己约会谈" —— 而那条路径**没人读 spool**）。
                && !$0.hasSuffix("mangox-feishu-attach.ts")
                && !$0.hasSuffix("mangox-followup.ts")
        }
    }

    func updateExtensions(_ paths: [String]) {
        desiredExtensions = Self.businessExtensionPaths(paths)
    }

    /// 重启 pi 使最新注入块/cwd 生效 (丢进程内对话记忆, 由 UI 显式触发)。
    func restartEngine() {
        guard process != nil else { return }   // 未运行则等下次 ensureProcessForCwd 自然带新参拉起
        teardownProcess()
        ensureProcessForCwd()
    }

    // MARK: - 会话持久化绑定 (pi --session)

    /// 冒烟注入: **进程级**重定向 transcript 根目录 (在 `run()` 起手设一次)。
    ///
    /// ⚠️ 为什么必须是进程级（与 `ImagePipeline.attachmentsRootOverride` 同一条判据）:
    /// 生产调用点 `removeSessionFile(for:)` **不接受路径参数**, 只吃 `sessionDirectory`
    /// ⇒ 函数级注入管不到它。而 `NSHomeDirectory()` 实测**不吃 `HOME`**
    /// （2026-10-13 实测: `env HOME=/tmp/fakehome` 仍返回 `/Users/moofs`）⇒ 不设这个
    /// override, 冒烟就没有第二条路能把 transcript 挪出用户真实目录 —— 于是
    /// 「删会话 / 删项目时 transcript 按选项删没删」这条判据**永远无法变红**（守卫 27）。
    nonisolated(unsafe) static var sessionDirectoryOverride: String?

    /// pi session 文件目录 (每 UI 会话一个 .jsonl, 存在则恢复/不存在则新建)。
    static var sessionDirectory: String {
        sessionDirectoryOverride ?? (NSHomeDirectory() + "/.mangox/pi-sessions")
    }

    static func sessionFilePath(for id: UUID) -> String {
        sessionDirectory + "/" + id.uuidString + ".jsonl"
    }

    /// 删除会话的持久 transcript (会话删除时清理, 防磁盘残留)。
    static func removeSessionFile(for id: UUID) {
        try? FileManager.default.removeItem(atPath: sessionFilePath(for: id))
    }

    // MARK: - 旧声明的 transcript（2026-11-18）

    /// 读一份 transcript 里**声明的内置工具名**（首条带 `toolsAdded` 的 system message）。
    /// 读不出（没这文件 / 没这段 / 坏 JSON）一律 nil —— 那是"不知道"，不是"没有"。
    static func declaredToolNames(inSessionFile path: String) -> [String]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        // 只读前 256 KiB: 声明在首条 system message 里，正常会话前几行就到。
        let data = h.readData(ofLength: 256 * 1024)
        for line in data.split(separator: 0x0A) {
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line)),
                  let obj = raw as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  (msg["role"] as? String) == "system" else { continue }
            if let added = msg["toolsAdded"] as? [[String: Any]] {
                return added.compactMap { $0["name"] as? String }
            }
        }
        return nil
    }

    /// 这份 transcript 的工具面是**旧声明**（缺 `bash` / `edit`）⇒ 把它挪走，让 pi 起一份新的。
    ///
    /// 为什么非处理不可（2026-11-18，boss 真机撞到的那个 bug 的下半截）：
    /// pi 把「这一场能用哪些工具」写进会话**首条** system message 的 `toolsAdded`，之后每次恢复
    /// 都拿它当权威（`_restoreToolsFromTranscript`：记录集 + `--tools +x` 增补，**内置工具不补回**）。
    /// 所以 0.2.x 之前那版「只读分析面」写下的声明，会把这会话**永久**锁成
    /// `read/grep/find/ls/write` —— 档位改了、代码改了，它照样半残（有 `write`，没 `bash`/`edit`）。
    ///
    /// 判据是「缺 `bash` 或 `edit`」：四档（minimal / standard / full / codemode）**都**有这两个
    /// 内置工具，缺了只能是旧声明或坏数据。**不去猜"应该有哪些"** —— 扩展工具名 App 不知道，
    /// 正向推导一定被它打偏（实测：旧声明里就有 `bocha_web_search`）。
    ///
    /// 处理是**隔离，不是修复**：改名成 `<file>.stale-<ts>` 留着（不删），这一轮起一份新的。
    /// 手改 pi 的落盘格式 = 和它的内部结构绑死，那个代价比"模型忘掉这一段对话"大得多
    /// （UI 里的消息在我们自己的库里，一条不丢；丢的只是模型侧的记忆，且只丢这一次）。
    @discardableResult
    static func quarantineStaleSessionFile(_ path: String, now: Date = Date()) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let names = declaredToolNames(inSessionFile: path) else { return nil }
        guard !names.contains("bash") || !names.contains("edit") else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let moved = path + ".stale-" + fmt.string(from: now)
        guard (try? FileManager.default.moveItem(atPath: path, toPath: moved)) != nil else { return nil }
        return moved
    }

    /// P6.3.1: 按显式路径删除 transcript (侧问 fork 产物文件名不可派生)。
    static func removeSessionFile(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 会话绑定: 仅记录, 下回合 spawn 生效 (per-turn 进程架构, 无"绑定重启"概念)。
    /// 非 nil = spawn 带 --session 文件 (pi 恢复持久 transcript);
    /// nil = --no-session ephemeral (任务 fire 轮次用)。
    func updateSessionBinding(_ sessionId: UUID?) {
        desiredSessionId = sessionId
    }

    // MARK: - Side chat fork (P6.3.1)

    /// 显式会话文件路径 (fork 产物绑定; 优先于 UUID 派生)。
    func updateSessionFilePath(_ path: String?) {
        desiredSessionFile = path
    }

    /// 下回合 spawn 带 --fork <sourceFile> (实测与 --session 互斥硬错误, 只传其一)。
    /// 产物路径不可预知 → spawn 后轮询 get_state 回读, 经 didReadSessionFile 上报。
    func startForkSession(sourceFile: String) {
        desiredForkSource = sourceFile
        forkReadbackPending = true
    }

    /// 回读收尾: fork 期望清位 + 显式绑定写回 + delegate 上报。
    private func finishForkReadback(path: String?) {
        guard forkReadbackPending else { return }
        forkReadbackPending = false
        forkReadbackTask?.cancel()
        forkReadbackTask = nil
        desiredForkSource = nil
        if let path { desiredSessionFile = path }
        delegate?.transport(self, didReadSessionFile: path)
    }

    /// App 退出清理: 终止在途 pi (孤儿进程会继续跑完回合烧 LLM token)。
    /// transcript 已由 pi 按行持久化到 --session 文件, 强杀不丢已产出内容。
    func shutdown() {
        teardownProcess()
        // ⚠️ 会话没了 ⇒ 助手必须一起收(2026-11-11/12)。原来这里只拆 pi, **助手一个都不收**:
        //    每开一个会话多一个握着辅助功能 + 屏幕录制的子进程, 直到 App 退出。
        //    `stop()` 是幂等的(没起过就是空操作), 所以不必先判断"这次到底借过没有"。
        computerHost.stop()
    }

    func refreshCapabilities() {
        ensureProcessForCwd()   // 模型清单无需等首条消息, 主动拉起 pi
        guard process != nil else { return }
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_state"])
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_available_models"])
        // per-turn: 这次拉起的进程属 idle, 会随首个回合结束而退出
    }

    func setModel(provider: String, modelId: String) {
        // per-turn: 记录 spawn 期参数 (--model provider/id), 下回合生效;
        // 回合内进程在时同时发 set_model 即时切换。
        desiredModel = provider + "/" + modelId
        guard stdinHandle != nil else { return }   // 无进程: 下回合 spawn 后 get_state 自动同步 UI
        sendCommand(["id": "req-\(nextRequestId())", "type": "set_model",
                     "provider": provider, "modelId": modelId])
        // set_model 成功与否以 response 为准, 收到后再回读 get_state 同步 UI
    }

    func setThinkingLevel(_ level: String) {
        // per-turn: 记录 spawn 期参数 (--thinking), 下回合生效; 回合内即时切换。
        desiredThinking = ThinkingLevel(rawValue: level) ?? .high
        guard stdinHandle != nil else { return }   // 无进程: 下回合 spawn 后 get_state 自动同步 UI
        sendCommand(["id": "req-\(nextRequestId())", "type": "set_thinking_level", "level": level])
    }

    // MARK: - HTML 导出 (P6.2.3)

    private var exportPending = false
    private var exportWatchdog: Task<Void, Never>?

    /// pi export_html: 进程不活则临时拉起 (调用方需先下发会话绑定/cwd)。
    /// 响应或 15s 超时后经 didFinishExportHTMLPath 上报, 空闲态随手拆进程。
    func exportHTML(outputPath: String) {
        ensureProcessForCwd()
        guard process != nil else {
            delegate?.transport(self, didFinishExportHTMLPath: nil)
            return
        }
        exportPending = true
        sendCommand(["id": "req-\(nextRequestId())", "type": "export_html",
                     "outputPath": outputPath])
        exportWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.exportPending else { return }
            self.finishExport(path: nil)
            if !self.turnActive { self.teardownProcess() }
        }
    }

    private func finishExport(path: String?) {
        exportPending = false
        exportWatchdog?.cancel()
        exportWatchdog = nil
        delegate?.transport(self, didFinishExportHTMLPath: path)
    }

    // MARK: - 进程管理

    /// 确保 pi 进程跑在期望的 cwd 上。cwd 变化需重启进程 (pi 会话内无切目录命令);
    /// 代价是丢掉进程内对话记忆, 仅在切换 project 时发生, 可接受。
    private func ensureProcessForCwd() {
        let target = desiredCwd ?? NSHomeDirectory()
        // P15.3: **dream 状态与 cwd 一样是 spawn 期的定格** —— 扩展挂不挂、env 设不设,
        // 都只在 spawn 那一刻决定。而进程是**跨回合复用**的（同一个日志会话反复 fire）,
        // 所以"这次要不要 dream"变了也必须重启, 否则会沿用上一次的扩展与 env。
        // 这个分支不是为了第一次 fire（那次 process 本来就是 nil）—— 是为了
        // 用户点开任务日志会话说了句话（普通回合, `dreamSpool` 被置回 nil）之后再点「立即运行」。
        if process != nil, spawnedCwd != target || spawnedDreamSpool != dreamSpool
            || spawnedAttachSpool != attachSpool
            || spawnedFollowUpSpool != followUpSpool
            || spawnedExtraSystem != extraSystemPrompt
            || spawnedExecProject != executionGuard?.projectPath {
            // 诊断日志: 进程**复用**是常态, 重启是例外 —— 后者会丢进程内对话记忆,
            // 排查时"这一轮为什么没记忆"要能一眼看出是这里拆的。
            Log.process("teardown", ["cwdChanged": spawnedCwd != target ? "1" : "0",
                                     "dreamChanged": spawnedDreamSpool != dreamSpool ? "1" : "0",
                                     "attachChanged": spawnedAttachSpool != attachSpool ? "1" : "0",
                                     "followUpChanged": spawnedFollowUpSpool != followUpSpool ? "1" : "0",
                                     "injectChanged": spawnedExtraSystem != extraSystemPrompt ? "1" : "0",
                                     "fenceChanged": spawnedExecProject != executionGuard?.projectPath ? "1" : "0"])
            teardownProcess()
        }
        guard process == nil else {
            Log.process("reuse", "pid", "\(process?.processIdentifier ?? -1)")
            return
        }
        spawnProcess(cwd: target)
    }

    private func teardownProcess() {
        guard let p = process else { return }
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe = nil
        startupWatchdog?.cancel()   // P12.1a: 主动拆进程 ≠ 启动失败, 看门狗必须一起撤
        startupWatchdog = nil
        p.terminate()   // terminationHandler 会走 processDidExit, 靠身份守卫不误伤
        process = nil
        stdinHandle = nil
    }

    private func spawnProcess(cwd: String) {
        guard let spec = Self.launchSpec() else { return }
        let extPath = Self.ensureExtensionFile()
        // ⚠️ 2026-11-18 起这里**不再有"只读分析面"这一层**（boss 定: 助理按它自己选的档位
        //    拿权限）。原来那张面把工具裁成"只读五件 + write"、还顺手关掉 computer/知识/SOP，
        //    理由写在 `AnalysisFace` 里 —— 但 `--tools` 的 allowlist 会被 pi 写进会话首条声明，
        //    之后同会话里按档位跑（`+grep` 那种 modifier 写法）会被那条声明**覆盖回来**，
        //    于是"只想让巡检轮只读"变成"整个会话永远只有只读五件"，bash/edit 拿不回来。
        //    删掉之后 spawn 面只有一条来源 = 档位（`AgentMode`），与普通会话同源。
        // P13: 自建 codemode 扩展**只在这一档落地** —— 三老档连"挂载"这一步都没有,
        // 所以它们的扩展段逐字节不变 (是"不存在", 不是"挂了但没生效")。
        let codemodeExtPath = desiredMode.mountsCodemodeExtension
            ? Self.ensureCodemodeExtensionFile() : nil
        // P15.3: dream 扩展**只在这一份实例是 dream fire 时挂** —— `dreamSpool` 由
        // `SchedulerService` 在 fire 前设、fire 收尾时清。三老档与普通会话上它是 nil
        // ⇒ 扩展段逐字节不变（同 codemode 那条"是'不存在', 不是'挂了但没生效'"）。
        let dreamExtPath = dreamSpool != nil ? Self.ensureDreamExtensionFile() : nil
        // S15c: 飞书发附件扩展**只在飞书轮挂** —— `attachSpool` 由 `ChatStore.beginTurn` 经
        // `RemoteChannelService` 判"这个 sid 是不是飞书来的"后下发，普通会话是 nil
        // ⇒ 扩展段逐字节不变（同 dream / codemode 那条"是'不存在', 不是'挂了但没生效'"）。
        let attachExtPath = attachSpool != nil ? Self.ensureAttachExtensionFile() : nil
        // 2026-11-23: follow-up 扩展**只在"这一轮属于某个任务"时挂** —— `followUpSpool` 由
        // `ChatStore.beginTurn` 经 `SchedulerService.beginFollowUpTurn` 下发，普通会话是 nil
        // ⇒ 扩展段逐字节不变（同 dream / attach 那条"是'不存在', 不是'挂了但没生效'"）。
        let followUpExtPath = followUpSpool != nil ? Self.ensureFollowUpExtensionFile() : nil
        // P10.1b: 搜索扩展**保底落地**（文件本来由 `ChatStore.scanExtensions` 写好了, 这里只防
        // "列表里有它、文件却不在"——删过 / 换过托管目录 / 首次 spawn 抢在扫掠之前）。
        // 判据 = 它在**启用列表**里（那已经是"用户开着 + 有 key"的交集, 见 `ChatStore.scanExtensions`）
        // ⇒ 没配 key 时不调用它, 省一次无谓的文件比对。
        // ⚠️ 顺序必须是**先落地再拼参数**: `-e` 指向一个不存在的文件 ⇒ pi 报
        // `Error: Failed to load extension` 并直接退出。
        if desiredExtensions.contains(where: { $0.hasSuffix(Self.webSearchExtensionFileName) }) {
            _ = Self.ensureWebSearchExtensionFile()
        }
        // P18 批 1: computer 的**挂载闸门这一半** —— 作用域为空 ⇒ `start` 返回 nil
        // (那条判据只写在 `ComputerHost.start` 里, 这里不重复判断), 于是扩展不挂(下面)、
        // env 不给(更下面)。两半共用同一个 nil, 所以不存在"挂了但没生效"的中间态 ——
        // 那是比"没挂"更难查的一种: 模型看得到工具, 每次调用都回"未启用", 而界面上没有任何
        // 地方说为什么。
        //
        // ⚠️ 名字**每次 spawn 重新读**, 不做实例字段。注意这不等于"作用域归这一轮所有":
        //    名单存在全局 settings 表里, 一份 (见 `ComputerSettings` 文件头);
        //    每次读是为了让**生效时机**落在下一次 spawn —— 用户在设置里关掉 ⇒ 下一轮
        //    spawn 就不再给 env ⇒ 扩展根本不挂。存成字段会多出一个"改了设置但在途
        //    会话还开着"的窗口, 而那个窗口界面上看不见。
        // ⚠️ 用的是 `activeAllowedBundles`（读 ∪ 视觉）**不是** `activeBundles`（纯读面）:
        //    helper 这个名字问的是"这个 App 我能不能碰", 而截图那一路不需要 AX 树 ——
        //    只勾了微信视觉的人, 用读面当判据会让助手压根不启动（`start` 空名单直接
        //    `return nil`）, 而设置页三个勾都勾着。
        let computerBundles = ComputerSettings.shared.activeAllowedBundles
        // 操作面(批 2b)单独读一次: 它是**第二档权限**, 与读面不同源(见 `activeActBundles`)。
        let computerActBundles = ComputerSettings.shared.activeActBundles
        // 接管检测(2026-11-02): 原来是"档位对了就装", 而 `interactive` 是默认档 ⇒ 用户什么都
        // 还没要, 系统先弹「MangoX 想监听你的键盘输入」。现在是三段与门(档位 ∧ 显式开关 ∧ 已有
        // 权限), 判据与 `granted` 的取法全在 `ComputerSettings.shouldInstallTakeover` 里。
        // 只读分析面删掉之后，这里不再有"某些轮次连 start 都不调"这一支 —— 起不起只看作用域
        // （`ComputerHost.start` 对空名单自己返回 nil），判据仍然只有一处。
        let computerSock: String? = computerHost.start(
            allowedBundles: computerBundles,
            actBundles: computerActBundles,
            imageBundles: ComputerSettings.shared.activeImageBundles,
            takeover: ComputerSettings.shared.shouldInstallTakeover(
                        expectsHuman: approvalMode.expectsHumanAtKeyboard),
            tap: ComputerSettings.shared.tapEnabled,
            type: ComputerSettings.shared.typeEnabled,
            keys: ComputerSettings.shared.keysEnabled)
        let computerExtPath = computerSock != nil ? Self.ensureComputerExtensionFile() : nil
        var args = spec.scriptArgs + ["--mode", "rpc"]
        // P12.1b + P13: 扩展参数 (关自动发现 + 补回内置 provider + 挂托管扩展 + codemode 层)。
        // 业务扩展仅完整档挂载 (P7-M4); 系统扩展 (审批桥) 四档恒挂。
        // ⚠️ computer 是**第三类**: 挂载与档位无关 (2026-10-29 定案) —— 它按**作用域开关**挂
        //    (设置页全局 / 对话框), 所以 `computerExtensionPath` 与上面那行
        //    `mountsBusinessExtensions ? …` **并列**, 不跟着档位走。别把它并进去:
        //    "模型看不看得见"由 `--tools` 决定 (AgentMode.toolListArguments),
        //    那才是档位的地盘; 挂载这一层听开关。
        args += Self.extensionArguments(
            hostedExtensionPath: extPath,
            codemodeExtensionPath: codemodeExtPath,
            dreamExtensionPath: dreamExtPath,
            attachExtensionPath: attachExtPath,
            followUpExtensionPath: followUpExtPath,
            computerExtensionPath: computerExtPath,
            enabled: desiredMode.mountsBusinessExtensions ? desiredExtensions : [])
        if let fork = desiredForkSource {
            // P6.3.1: 侧问首回合 — fork 源快照 (互斥分支: 不带 --session/--no-session)。
            // --session-dir 把产物收进托管目录 (否则落 pi 默认 ~/.pi/agent/sessions);
            // 产物文件名 = <时间戳>_<uuid>.jsonl, 路径由 get_state.sessionFile 回读获得。
            try? FileManager.default.createDirectory(atPath: Self.sessionDirectory,
                                                     withIntermediateDirectories: true)
            args += ["--session-dir", Self.sessionDirectory, "--fork", fork]
            // pi 启动早期命令可能不被响应 (实测 2-3s 内单发无回音): 轮询兜底回读
            forkReadbackTask = Task { [weak self] in
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard let self, self.forkReadbackPending, self.process != nil else { return }
                    self.sendCommand(["id": "req-\(self.nextRequestId())", "type": "get_state"])
                }
            }
        } else if let sessionId = desiredSessionId {
            // 会话持久化: 文件存在则恢复 transcript / 不存在则新建 (pi SessionManager.open
            // 对缺失文件返回空 entries + persist, 绝对路径模式无 not-found exit 风险)。
            // 侧问会话 (回读过产物) 用显式路径; 普通会话走 UUID 派生。
            try? FileManager.default.createDirectory(atPath: Self.sessionDirectory,
                                                     withIntermediateDirectories: true)
            let file = desiredSessionFile ?? Self.sessionFilePath(for: sessionId)
            // ⚠️ 2026-11-18: 旧版「只读分析面」把工具面写进了首条 system message，pi 恢复时拿它
            //    当权威 ⇒ 这份 transcript 会**永久**半残。判断与处置都收在那一处（隔离，不手改）。
            if let moved = Self.quarantineStaleSessionFile(file) {
                Log.event("session-tools-stale", ["moved": (moved as NSString).lastPathComponent])
            }
            args += ["--session", file]
        } else if let file = desiredSessionFile {
            // 无 UUID 绑定但有显式文件 (防御分支, 当前调用面不会走到)
            if let moved = Self.quarantineStaleSessionFile(file) {
                Log.event("session-tools-stale", ["moved": (moved as NSString).lastPathComponent])
            }
            args += ["--session", file]
        } else {
            // ephemeral: 任务 fire 轮次等, transcript 仅存进程内存
            args += ["--no-session"]
        }
        // P7-M4 + P13: 档位对 --tools 的取值 (极简裁内置 / 常规·完整在其上增补只读三件套 / codemode 加自己的 modifier)。
        // ⚠️ 与上面那段 extensionArguments **必须同进同退**: codemode 档要"挂上"与"激活"两件事都做
        //    (扩展是 defaultActive: false —— 只 `--extension` 挂载不会生效, 已实测)。
        // 工具面**只有一条来源 = 档位**（2026-11-18: "只读分析面"整层删掉）。
        args += AgentMode.spawnArguments(for: desiredMode, businessExtensions: [])
        // P3.7: 知识注入块挂在 spawn 参数上 (--append-system-prompt 可重复传; 会话内不可改)
        if let knowledge = desiredKnowledge, !knowledge.isEmpty {
            args += ["--append-system-prompt", knowledge]
        }
        // P19: 巡检/执行轮的系统级注入（交接文件 + 输出契约 + Observation）。
        // 位置在知识块之后、SOP 之前: 三者的段序与 `SopInjection` 那条"结构性首位"无关 ——
        // 它们都是 `--append-system-prompt`, pi 按出现顺序拼, 任务自己的注入必须**晚于**
        // 人格/知识（否则人格段会被挤到后面, 破 `persona 段结构性首位`）。
        if let extra = extraSystemPrompt, !extra.isEmpty {
            args += ["--append-system-prompt", extra]
        }
        // P18: **第二条**注入通道 = 应用操作手册 (SOP)。刻意不并进上面那一块:
        //   知识块的语义是"我是谁/我知道什么", 有 persona 首位与段序两条结构性不变量;
        //   SOP 是"在这个 App 里怎么下手", 生命周期跟着**开关与名单**走。
        // ⚠️ 判据必须是 `computerSock`（不是"名单非空"）—— 与挂载走**同一个 nil**:
        //   扩展没挂上就没有那套工具, 却把手册教给模型 = 教它用手边不存在的东西。
        // ⚠️ 手册正文是**代码常量**（`SopManual.text`）, 不读盘; 现算的只有名单与档位 ——
        //   两样都在这一处定格 ⇒ 不存在"改了设置但提示词还是旧的"的窗口。
        if computerSock != nil {
            let sop = SopInjection.block(bundles: computerBundles,
                                         actBundles: computerActBundles,
                                         codemode: desiredMode == .codemode)
            if let text = sop.text, !text.isEmpty {
                args += ["--append-system-prompt", text]
            }
        }
        // per-turn: 模型/思考级别 spawn 期定格 (回合内 set_model/set_thinking_level 仍可即时切换)
        if let model = desiredModel {
            args += ["--model", model]
        }
        args += ["--thinking", desiredThinking.rawValue]
        // 2026-11-20 boss 定: 每一轮向 pi **要的是哪个模型**落一行。
        // ⚠️ 事故排查时没有这行，唯一的证据是 transcript 里每条 assistant message 的
        //    `model` 字段 —— 而那条判据要自己先猜对（"转录里只有一条 `model_change`"
        //    是**错的**判据: 运行时切模型 pi 不写新事件）。这一行与下面的 `pi-model`
        //    成对读，就能直接看出"要的"和"pi 真用的"是不是同一个。
        Log.event("spawn-model", [
            "sid": desiredSessionId?.uuidString ?? "(ephemeral)",
            "model": desiredModel ?? "pi-default",
            "thinking": desiredThinking.rawValue,
        ])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executable)
        // P7-M3: 自管模型物化 — 有自管模型才注入 (覆盖整个配置目录, 与 ~/.pi/agent 互不相干);
        // 指纹不变由 writeIfNeeded 跳写, 避免 spawn 期磁盘搅动。
        //
        // ⚠️ 这一支同时决定**压缩预算从哪个文件读**: `PI_CODING_AGENT_DIR` 一改, pi 就只读
        //    该目录的 settings.json, `~/.pi/agent/settings.json` **一个字节都不参与**。
        //    底栏那条「压缩线」必须跟着同一个判据走 (读错文件 = 画一条永远不会发生的线,
        //    而且零红灯), 所以 `agentDirOverride` 在这里定格后立刻交给解析器。
        var agentDirOverride: URL?
        if let cfg = piConfig, cfg.modelCount > 0 {
            let dir = ModelMaterializer.configDirectory()
            if (try? ModelMaterializer.writeIfNeeded(cfg, to: dir)) != nil {
                p.environment = ProcessInfo.processInfo.environment
                p.environment?["PI_CODING_AGENT_DIR"] = dir.path
                agentDirOverride = dir
            }
        }
        // 压缩预算 (只供底栏画线; 不参与我们这边任何行为) —— 与 pi 同口径: spawn 期读一次。
        resolvedReserveTokens = PiCompactionBudget.reserveTokens(
            agentDirOverride: agentDirOverride,
            projectDir: URL(fileURLWithPath: cwd, isDirectory: true),
            model: desiredModel)
        // P15.3: 双闸门的第二道 —— spool 路径只经 env 下发, 且只有 dream 的 spawn 会设它。
        //
        // ⚠️ **必须显式给 `p.environment` 赋值, 不能写 `p.environment?[...] = x` 就算完** ——
        // 上面那段只在"有自管模型"(`cfg.modelCount > 0`) 时才给它赋值, 其余情况它是 **nil**
        // (意味着子进程自己继承父环境)。那时 `p.environment?[...] = x` 会**静默变成空操作**:
        // 扩展挂上了、工具也注册了, 但读不到 env ⇒ 每次调用都回"未开启", 而门禁全绿。
        // （这条是读上面那个分支条件得到的, 不是靠跑出来的 —— 所以它更需要守卫, 见守卫 26。）
        if let spool = dreamSpool {
            if p.environment == nil { p.environment = ProcessInfo.processInfo.environment }
            p.environment?[Self.dreamSpoolEnvKey] = spool
        }
        // S15c: 飞书发附件 = 双闸门的第二道（挂载那道在上面 `attachExtPath`）。
        // 值是 JSON: spool 路径 + **App 算出来的**根表与上限 —— 工具侧的做法是"用 App
        // 给的值做一次预检"，不是自己再抄一份常量（抄了就是第二真源）。
        if let spool = attachSpool, let value = Self.attachEnvValue(spool: spool) {
            if p.environment == nil { p.environment = ProcessInfo.processInfo.environment }
            p.environment?[Self.attachEnvKey] = value
        }
        // 2026-11-23: follow-up = 双闸门的第二道（挂载那道在上面 `followUpExtPath`）。
        // 值与 dream 同形（单个路径）。⚠️ 守卫 26 同款: 上面几段都可能没给 `p.environment`
        // 赋值（nil = 继承父环境），那时 `p.environment?[k] = v` 是**静默空操作** ⇒ 必须整体赋值。
        // ⚠️ 必须显式删掉父进程残留的同名变量（用户 export 过再从那个 shell 起 App）——
        //    否则普通会话会莫名拿到这个工具，而它写的 spool **没有任何一轮会去读**。
        if followUpSpool != nil || ProcessInfo.processInfo.environment[Self.followUpEnvKey] != nil {
            if p.environment == nil { p.environment = ProcessInfo.processInfo.environment }
            p.environment?[Self.followUpEnvKey] = followUpSpool   // nil = 删除该键
        }
        // P19 S6: 执行轮的写围栏 env（扩展侧那一半，见 `approvalExtensionSource`）。
        //
        // ⚠️ 守卫 26 同款: 上面几段都可能没给 `p.environment` 赋值（nil = 继承父环境），
        // 那时 `p.environment?[k] = v` 是**静默空操作** ⇒ 必须整体赋值。
        // ⚠️ 也**必须显式删掉**父进程里可能残留的同名变量（用户 export 过再从那个 shell 起 App）
        // —— 否则一个普通会话会莫名其妙带上执行围栏，表现是"新文件写不进去还要审批"。
        if let env = Self.execFenceEnvironment(existing: p.environment,
                                               projectPath: executionGuard?.projectPath,
                                               inherited: ProcessInfo.processInfo.environment) {
            p.environment = env
        }
        // P10.1b: 博查 key 只走 env（Keychain → 子进程环境），**不落盘**。
        // ⚠️ 守卫 26 同款: 上面那段只在"有自管模型"时才给 `p.environment` 赋值, 其余情况它是
        //    **nil**（= 子进程自己继承父环境）。那时 `p.environment?[k] = v` 是**静默空操作** ——
        //    扩展挂上了、工具也注册了, 但读不到 key ⇒ 每次调用都回"未启用", 而门禁全绿。
        // ⚠️ 判据不写成 `if let key = webSearchKey`: 那会漏掉"父进程里残留了同名变量"这一半
        //    （用户 export 过再从该 shell 起 App）—— 那一半不删就等于**面板说没配、扩展却拿到了**。
        if let env = Self.webSearchEnvironment(existing: p.environment,
                                               key: webSearchKey,
                                               inherited: ProcessInfo.processInfo.environment) {
            p.environment = env
        }
        // P18 批 1/2b: computer 的五个 env 键。⚠️ 同上面那条守卫 —— `p.environment` 此时可能还是
        // nil(没人给过), 那时 `p.environment?[k] = v` 是**静默空操作** ⇒ 必须整体赋值。
        // 判据不写成 `if let sock = computerSock`: 那会漏掉"父进程里残留了同名变量"这一半。
        if let env = ComputerHost.environment(existing: p.environment,
                                              socketPath: computerSock,
                                              allowedBundles: computerBundles,
                                              actBundles: computerActBundles,
                                              imageBundles: ComputerSettings.shared.activeImageBundles,
                                              takeover: ComputerSettings.shared.shouldInstallTakeover(
                                                  expectsHuman: approvalMode.expectsHumanAtKeyboard),
                                              tap: ComputerSettings.shared.tapEnabled,
                                              type: ComputerSettings.shared.typeEnabled,
                                              keys: ComputerSettings.shared.keysEnabled,
                                              peerPid: ProcessInfo.processInfo.processIdentifier,
                                              inherited: ProcessInfo.processInfo.environment) {
            p.environment = env
        }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)   // App cwd=/ 问题的正式修复
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe   // P12.1a: 不再丢 nullDevice — 启动失败的唯一线索在 stderr
        let spawnStarted = Date()
        do { try p.run() } catch {
            // 诊断日志: 拉不起来这件事原来是**完全静默**的（`send` 那边只 `guard process != nil`），
            // 而 UI 上已把 `runningTurns` 置了位 ⇒ 表现是"生成中…"常亮、什么都不来。
            Log.process("spawn-failed", ["err": String(describing: error).prefix(120).description])
            // ⚠️ pi 没起来 ⇒ 这次起的助手也没人要了, 当场收掉(同 `shutdown`)。
            computerHost.stop()
            return
        }
        process = p
        // ⚠️ 只记**参数条数**，不记参数全文 —— 里面带 `--append-system-prompt`（知识库/手册）
        //    与 session 路径，写进日志就等于把提示词抄了一份。
        Log.process("spawned", ["pid": "\(p.processIdentifier)",
                                "args": "\(args.count)",
                                "ms": String(format: "%.0f", Date().timeIntervalSince(spawnStarted) * 1000),
                                "cwd": (cwd as NSString).lastPathComponent,
                                "gen": "\(spawnGeneration + 1)"])
        spawnedCwd = cwd
        spawnedDreamSpool = dreamSpool
        spawnedAttachSpool = attachSpool
        spawnedFollowUpSpool = followUpSpool
        spawnedExtraSystem = extraSystemPrompt
        spawnedExecProject = executionGuard?.projectPath
        self.outPipe = outPipe
        self.errPipe = errPipe
        stdinHandle = inPipe.fileHandleForWriting
        lock.lock()
        lineBuffer.removeAll()
        stderrTail.removeAll()      // 上一次 spawn 的残留不能混进这次的归因
        lock.unlock()
        sawAnyRPC = false
        engineFailureReported = false
        spawnGeneration += 1
        let generation = spawnGeneration

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            self?.enqueue(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            self?.enqueueStderr(data)
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processDidExit(p) }
            }
        }
        // P12.1a: 启动沉默看门狗 —— 正常 spawn 立刻就有 response, 一条都没有就说明
        // 进程没起来 / 参数不被这个版本接受 / 入口不是 node 脚本。进程若已自己退出,
        // 交给 processDidExit 报 (那边能带上退出码), 这里只管"还活着但沉默"。
        startupWatchdog?.cancel()
        startupWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Tune.engineSilenceSeconds * 1_000_000_000))
            guard let self, self.spawnGeneration == generation, self.process != nil else { return }
            self.reportEngineSilence(exitStatus: nil)
        }
        // P3.5: 能力上报 — spawn 后立即拉当前模型状态与可用模型清单
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_state"])
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_available_models"])
        // P6.1.1: 会话统计 (会话绑定 spawn 时即得恢复后的 context%; ephemeral 返回空, 上层丢弃)
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_session_stats"])
    }

    /// 身份守卫: 只有当前 process 引用退出才清理 (teardown 重启时旧进程退出不误伤新进程)。
    private func processDidExit(_ proc: Process) {
        guard process === proc else { return }
        // P12.1a: 能走到这里 = pi **自己退出**的 (teardownProcess 先把 process 置 nil, 上面那条
        // 身份守卫会把主动拆除挡掉)。若它到死**一句话都没说过**, 那就是启动失败, 必须报。
        // ⚠️ 位置在下面 `guard turnActive` **之前** —— 引擎在首个回合还没开起来就死时
        // turnActive 仍是 false, 那条守卫会把这唯一的线索吞掉。
        // 延后 0.5s 再判: 进程退出时 stdout 缓冲区里可能还有没派发到主线程的 response,
        // 当场断言"一句话没说"会误报。
        let status = proc.terminationStatus
        let generation = spawnGeneration
        // 诊断日志: 退出码是"引擎为什么没了"的第一手证据（`reportEngineSilence` 只在零输出时报，
        // 半路退出它不报）。配合上面的 `spawned` 能对上进程号与存活时长。
        Log.process("exit", ["status": "\(status)", "tid": "\(proc.processIdentifier)",
                             "hasRPC": sawAnyRPC ? "1" : "0"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.spawnGeneration == generation else { return }
                self.reportEngineSilence(exitStatus: status)
            }
        }
        process = nil
        stdinHandle = nil
        if exportPending { finishExport(path: nil) }   // P6.2.3: 导出中进程死亡 → 上报失败
        if forkReadbackPending { finishForkReadback(path: nil) }   // P6.3.1: 回读中死亡 → 上报失败
        guard turnActive else { return }
        turnActive = false
        finalizeTrackedMessages(usage: nil)   // 进程异常退出: usage 无从上报
        emit(.phaseChanged(.idle))            // P6.1.2: 过程态归位
        emit(.streamEnded)
    }

    // MARK: - 下行 (UI → pi)

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func sendCommand(_ dict: [String: Any]) {
        #if DEBUG
        // P9-#6: 冒烟断言副本 — 只存 type/id 元信息 (剥离 prompt 全文与 images base64,
        // 原实现整条 append 永不清理, 多图会话内存无界增长且 Release 同样生效)
        var meta: [String: Any] = [:]
        if let t = dict["type"] { meta["type"] = t }
        if let id = dict["id"] { meta["id"] = id }
        // P18 批 2a: 审批的**答案**也要留副本。只记 type 的话, "Allow" 与 "Deny" 在
        // 冒烟里长得一模一样 —— 而这两件事正好是安全判据的正反面(「远程驱动档必须拒」
        // 与「同档的 write 仍放行」靠的就是这一个字段区分)。值是个短字符串, 不带负载。
        if let v = dict["value"] { meta["value"] = v }
        sentCommands.append(meta)
        #endif
        guard let stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A)
        // P9-#5: throwing 版 write — 管道断裂走 Error 而非 ObjC 异常 (进程死亡竞态不崩 App)
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            print("[PiRpcTransport] stdin write failed (进程已退出?): \(error)")
            Log.process("stdin-failed", "type", "\(dict["type"] ?? "?")")
        }
    }

    // MARK: - 上行 (pi → UI): 线程安全的行分帧

    private nonisolated func enqueue(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(lineBuffer[lineBuffer.startIndex..<nl])  // 取段须在持锁内完成
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if var line = String(data: lineData, encoding: .utf8) {
                if line.hasSuffix("\r") { line.removeLast() }  // 协议: 接受 \r\n 但剥离 \r
                if !line.isEmpty { lines.append(line) }
            }
        }
        lock.unlock()
        let debugLog = ProcessInfo.processInfo.environment["MANGOX_RPC_LOG"]
        for line in lines {
            let arrivedAt = Date()  // 行到达时刻: 主线程处理可能滞后 (渲染卡顿), 计时须用到达时刻
            if Self.rawEchoToStderr {
                FileHandle.standardError.write("RAW \(line)\n".data(using: .utf8)!)
            }
            if let debugLog, let data = String(format: "%f %@\n", Date().timeIntervalSince1970, line).data(using: .utf8) {
                let url = URL(fileURLWithPath: debugLog)
                if let fh = FileHandle(forWritingAtPath: debugLog) {
                    defer { try? fh.close() }
                    _ = try? fh.seekToEnd()
                    try? fh.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.handleRPCLine(line, arrivedAt: arrivedAt) }
            }
        }
    }

    // MARK: - P12.1a: stderr 尾部缓冲

    /// 后台读取线程回调 (与 `enqueue` 同款: readabilityHandler 不在主线程)。
    /// 只留尾部 `stderrTailLimit` 行 —— 启动失败的线索几乎都在**最后一两行**,
    /// 而 pi 跑起来后 stderr 可能有大量进度/告警 ⇒ 不设上限会让这个数组无界增长。
    /// 这里的 stderr **不丢弃**: 进程活着时它是噪音, 进程死时它是**唯一**的归因来源。
    /// internal 供冒烟直接投喂 (与 `handleRPCLine` 同款: 不起进程也能验归因逻辑)。
    nonisolated func enqueueStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        // 拆行在锁外做 (纯字符串运算, 不碰共享状态), 只把追加动作留在锁内。
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let l = String(raw)
            return l.hasSuffix("\r") ? String(l.dropLast()) : l
        }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        lock.lock()
        stderrTail.append(contentsOf: lines)
        if stderrTail.count > Self.stderrTailLimit {
            stderrTail.removeFirst(stderrTail.count - Self.stderrTailLimit)
        }
        lock.unlock()
    }

    /// P12.1a: 引擎"启动即死 / 启动后一声不吭"的上报 (看门狗与退出回调共用, 只报一次)。
    /// - Parameter exitStatus: nil = 进程**还活着但沉默** (看门狗触发); 非 nil = 进程已自行退出。
    /// 判据不是 `turnActive`: 引擎在首个回合开起来之前就死时它仍是 false。
    /// internal 供冒烟 (看门狗 8s 太慢, 直接调它验判据与文案)。
    func reportEngineSilence(exitStatus: Int32?) {
        guard !engineFailureReported, !sawAnyRPC else { return }
        engineFailureReported = true
        lock.lock()
        let tail = stderrTail
        lock.unlock()

        var lines: [String] = []
        if let exitStatus {
            lines.append(String(format: L("Agent 引擎启动后立即退出 (退出码 %d)。"), exitStatus))
        } else {
            lines.append(L("Agent 引擎已启动但一直没有响应。"))
        }
        if tail.isEmpty {
            lines.append(L("引擎没有输出任何 stderr。"))
        } else {
            lines.append(L("引擎 stderr 末尾几行:"))
            lines.append(contentsOf: tail)
        }
        lines.append(Self.binarySearchReport())
        // 不走 extensionNotify: 那条通道 8s 自清, 而引擎起不来是**不可自愈**的状态,
        // 用户错过 8s 就回到"什么都不发生"的原点。这里走常驻诊断位。
        var report = lines.joined(separator: "\n")
        // 兜底: stderr 可能有超长单行, 不让它把 UI 拖垮
        if report.count > 4000 { report = String(report.prefix(4000)) + "…" }
        delegate?.transport(self, didFailEngineWithDiagnosis: report)
    }

    // MARK: - 事件解析 (MainActor)

    /// 嵌套调用（codemode 脚本里的 `tools.bash(...)`）的**父卡 id**。
    ///
    /// pi 只在嵌套调用的 `tool_execution_*` 事件上带 `parentToolCallId`
    /// （= 父调用的 callId，形如 `<父>/<n>`；见 pi 的 `core/nested-tool-calls.js`）
    /// ⇒ 模型直接调的工具没有这个字段，返回 nil = 顶层行。
    ///
    /// ⚠️ 父卡还没建出来时**返回 nil，不去猜**：宁可在外面多露一行，也不许把子卡挂到
    ///    别的父上（挂错 = 这一行从界面上凭空消失，用户根本看不到它跑过）。
    private func parentCardId(_ evt: [String: Any]) -> UUID? {
        guard let pid = evt["parentToolCallId"] as? String else { return nil }
        return toolCards[pid]?.id
    }

    /// internal 供冒烟测试直接投喂 JSONL 行。
    /// arrivedAt: 读取线程的行到达时刻 (MainActor 处理可能被 UI 渲染阻塞, 计时不能用处理时刻)
    func handleRPCLine(_ line: String, arrivedAt: Date = Date()) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return }
        // P12.1a: 只要 pi 回过**任何**一条合法 JSONL, 就说明进程真的活着 ⇒ 启动失败判据失效。
        // 位置在解析成功之后: 半行/乱码不算"说话了"。
        sawAnyRPC = true
        switch dict["type"] as? String {
        case "agent_start":
            turnActive = true
            turnSawAgentStart = true
            emit(.phaseChanged(.streaming))   // P6.1.2: 过程态胶囊
            emit(.streamStarted)

        case "message_start", "message_end":
            // pi 一个回合由多条 assistant 消息组成 (think 条 / toolcall 条 / 文本条)。
            // 边界处逐条落定并重置当前块 id, 光标不会跨消息滞留 (修 A4"已完成"光标卡住)。
            if let msg = dict["message"] as? [String: Any], msg["role"] as? String == "assistant" {
                // P5.0.1: message_end 携带该次 LLM 调用的 usage/responseId/model,
                // 挂到本边界落定的块上 (start 只滚边界, usage 传 nil)。
                let usage = (dict["type"] as? String == "message_end") ? Self.parseUsage(msg) : nil
                rollMessageBoundary(usage: usage)
            }

        case "message_update":
            // P6.1.1: 顶层累计 usage → 状态栏实时 tick (500ms 节流; 无顶层 usage 则忽略)
            if let u = dict["usage"] as? [String: Any] { noteLiveUsage(u) }
            guard let ev = dict["assistantMessageEvent"] as? [String: Any] else { return }
            // ⚠️ pi 的 JSON 层会**改写**这个事件 (json-event.js `toJsonAssistantMessageEvent`):
            // 剥掉 `partial`, 并给 `toolcall_start` 补上 `id` + `toolName` (取自 partial.content)。
            // 所以下面读不到 `partial` 是协议如此, 不是解析漏了。
            switch ev["type"] as? String {
            case "toolcall_start":
                // P6.2.1: 提前出卡 (queued; 参数未知 → title=工具名)。
                // tool_execution_start 携同一 callId 到达时整卡替换转 running。
                guard let callId = ev["id"] as? String else { return }
                let name = ev["toolName"] as? String ?? "bash"
                let card = ToolCall(kind: kindFor(name), title: name, command: nil, phase: .queued)
                toolCards[callId] = card
                emit(.toolUpdated(card))

            case "toolcall_end":
                // ③ 权威参数到手: `toolCall{id,name,arguments}`。不接它 = 把参数静默丢掉 ——
                // 卡头会一直停在 "BASH  bash  等待" 直到 tool_execution_start 才补齐,
                // 而审批/排队期间用户看不到自己要批的是什么。
                guard let tc = ev["toolCall"] as? [String: Any],
                      let callId = tc["id"] as? String else { return }
                let name = tc["name"] as? String ?? "bash"
                let kind = kindFor(name)
                let head = Self.toolHead(kind: kind, name: name,
                                         args: tc["arguments"] as? [String: Any] ?? [:])
                // 缺 start (流被打断 / 提前卡没出) 也要**补一张**, 而不是 return:
                // 这一步是权威数据, 丢掉它等于把参数彻底丢了。相态仍记 queued (是否真执行由
                // tool_execution_start 决定, 不在这里替它断言)。
                var card = toolCards[callId]
                    ?? ToolCall(kind: kind, title: name, command: nil, phase: .queued)
                card.kind = kind
                card.title = String(head.title.prefix(120))
                card.command = head.command
                toolCards[callId] = card
                emit(.toolUpdated(card))

            case "text_delta":
                let delta = ev["delta"] as? String ?? ""
                guard !delta.isEmpty else { return }
                trackDeclaredStep(delta)
                emit(.textChunk(messageID: lazyID(&textMessageID), delta: delta))

            case "thinking_delta":
                let delta = ev["delta"] as? String ?? ""
                guard !delta.isEmpty else { return }
                // 思考段也要跟: 模型把「第 2 步」写在思考里是常态, 只扫正文会让执行轮
                // 每一次动作都被判成"没声明步骤" —— 表现是正常的执行回合全线被拒。
                trackDeclaredStep(delta)
                emit(.thoughtChunk(messageID: lazyID(&thinkMessageID), delta: delta))

            default:
                // 显式忽略 (原先统一 `break`, 事后看不出是"不需要"还是"忘了接")。
                // 已逐个核对 pi-ai/types.d.ts:400-456 的 12 种事件:
                //   start / text_start / text_end / thinking_start / thinking_end / done / error
                //     → 正文与思考的权威值随 `message_end` 走 rollMessageBoundary 落定, 无需在此重复。
                //   toolcall_delta
                //     → 内容是 toolcall_end.arguments 的**原始 JSON 碎片** (未转义), 渲染出来
                //       是一串引号花括号, 且随即被 toolcall_end 覆盖 ⇒ 噪声, 不是信息。
                break
            }

        case "tool_execution_start":
            guard let callId = dict["toolCallId"] as? String else { return }
            let args = dict["args"] as? [String: Any] ?? [:]
            let name = dict["toolName"] as? String ?? "bash"
            let kind = kindFor(name)
            let head = Self.toolHead(kind: kind, name: name, args: args)
            // P6.2.1: toolcall_start 提前卡已存在 → 沿用其 id 整卡升级 (否则旧 queued 卡
            // 永不落定 + 同一调用两张卡, 轨迹里被连续同类分组误并)
            var card = ToolCall(id: toolCards[callId]?.id ?? UUID(),
                                kind: kind,
                                title: String(head.title.prefix(120)),
                                command: head.command,
                                phase: .running)
            // 嵌套调用（codemode 的 `tools.bash(...)`）: 记父卡, 由视图画进父卡里面
            // （自己**不出顶层行** —— 否则一次调用显示成两行, 且重放时子行会排到父前面）。
            card.parentId = parentCardId(dict)
            toolCards[callId] = card
            toolStartAt[callId] = arrivedAt
            toolNamesByCallId[callId] = name
            // P19 S6: 走到 `tool_execution_start` = 这个动作**真的被放行并开始跑了**
            // （被拒的调用在扩展侧就 `block` 了，不会有这条事件）。所以"允许"这件事
            // 只有这一个可信的观测点 —— 在审批桥里记"允许"会需要把每个 early return
            // 都补一行，漏一处就是一条假审计。
            // 只记要过审批的那些工具（read/grep 一次回合几十上百条，混进来会把痕迹淹掉）。
            if executionGuard != nil, ApprovalGate.needsApproval(name) {
                recordExecAction(step: execDeclaredStep ?? 0,
                                 kind: name,
                                 target: (args["command"] as? String) ?? (args["path"] as? String),
                                 result: "allowed")
            }
            emit(.toolUpdated(card))

        case "tool_execution_update":
            guard let callId = dict["toolCallId"] as? String,
                  var card = toolCards[callId] else { return }
            // partialResult 是**快照不是增量** (bash 每次 onUpdate 给全量 output.snapshot) ⇒ 整行替换。
            let parsed = parseToolResult(dict["partialResult"])
            if let out = parsed.text {
                card = card.withDetails([ToolDetail("输出", out)])
            }
            // 流式期不落图片 (partial 里的 image 块每次重发同一张, 会一遍遍写盘);
            // 图片只认 tool_execution_end。
            toolCards[callId] = card
            emit(.toolUpdated(card))

        case "tool_execution_end":
            guard let callId = dict["toolCallId"] as? String,
                  var card = toolCards[callId] else { return }
            let isError = dict["isError"] as? Bool ?? false
            // 取完即删: 这个字典只为这一行服务, 留着就是随会话单调增长的泄漏。
            let toolName = toolNamesByCallId.removeValue(forKey: callId)
            let parsed = parseToolResult(dict["result"])
            if isError {
                // 失败的 result 也是 AgentToolResult (content[0].text = 真错误文本,
                // 见 agent-loop.js createErrorToolResult) ⇒ 取真话, 不再一律打印兜底文案。
                let msg = parsed.text ?? L("工具执行失败")
                card = card.withPhase(.error(String(msg.prefix(200))))
            } else {
                var rows: [ToolDetail] = []
                if let out = parsed.text { rows.append(ToolDetail("输出", out)) }
                // 正文缺失时才用 details 兜底 (详见 flattenDetails 的判据)
                if parsed.text == nil, let det = parsed.detailsSummary {
                    rows.append(ToolDetail("细节", det))
                }
                // 批 3c: 现场截图**不在 attachments 留副本**。
                //
                // 图已经作为 tool result 的一部分随会话存在(那是 pi 的机制, 不由我们选),
                // 再落一份就成了双份; 而且它没有源文件 —— 附件目录里的东西都该是"用户的东西",
                // 截图不是。⇒ 这类卡只有文字, 没有缩略图。
                // ⚠️ 代价要认: 用户看不到模型看到的那张图, 只能在回执里读到我拍了多大一张。
                let isScreenShot = toolName == Self.computerReadToolName && !parsed.images.isEmpty
                let images = isScreenShot
                    ? []
                    : persistToolImages(parsed.images, owner: imageOwnerId)
                // P12.3: 时长**优先用引擎上报值** —— pi 1.1.0 起 `tool_execution_end` 带
                // `durationMs`（`Math.round(performance.now() - startedAt)`，**单调时钟**、
                // 只测 `execute()` 本体）；缺席时回落自算墙钟（含排队 / 流式 / 审批等待 ⇒ 偏大）。
                // ⚠️ 取值用 `NSNumber` 而非 `as? Int`: 契约是 TS `number`（不承诺整数），
                // 浮点形态也该被采用而不是被丢掉; 两种失败都保持**回落**。
                // 引擎侧写明 "absent when the tool did not run" ⇒ **缺席是正常语义, 不是异常**。
                // 失败分支 (上面 `isError`) 当前不记时长 —— 与改造前一致, 是有意边界。
                let engineMs = (dict["durationMs"] as? NSNumber)?.intValue
                let ms = engineMs ?? toolStartAt[callId].map { Int(Date().timeIntervalSince($0) * 1000) }
                card = card.finalized(details: rows, imagePaths: images, durationMs: ms)
            }
            toolCards[callId] = card
            emit(.toolUpdated(card))

        case "extension_ui_request":
            handleExtensionUIRequest(dict)

        case "response":
            handleRPCResponse(dict)

        case "agent_end":
            // P6.0①: 一次底层 run 结束 ≠ 落定 — willRetry=true 时 pi 还会自动重试/
            // 压缩重试/投递排队消息, 在此拆进程会腰斩重试。仅记录, 过程态 (P6.1.2) 消费。
            lastWillRetry = (dict["willRetry"] as? Bool) ?? false

        case "agent_settled":
            // P6.0①: 会话级彻底落定 (无重试/压缩重试/排队后续) — 唯一拆进程点。
            guard turnActive else { return }
            // 2026-10-21 (空回合): 零产出判据**只挂在这条路上**。`settleTurn` 的另一个调用点是 `prompt` 的
            // `handled` disposition —— 那一路"根本没有 run"（扩展就地吃掉了输入），
            // 零产出是**正常语义**，挂在那里会把它误报成引擎出错。
            // 顺序在 `settleTurn` 之前 = 在 `streamEnded` 之前: 落定之后 Store 已丢弃本回合的
            // 镜像容器, 后台会话（fire / dream）那条提示就无处可去（只有库里有, 界面要等重放）。
            if turnSawAgentStart, !turnProducedOutput, !turnUserAborted {
                emit(.emptyTurn(model: desiredModel))
            }
            settleTurn()

        // ---- P6.1.2: 过程态事件 (rpc.md §auto_retry/compaction/queue/summarization) ----
        case "auto_retry_start":
            // 瞬态错误自动重试 (overloaded/5xx) → 重试胶囊
            emit(.phaseChanged(.retrying(attempt: dict["attempt"] as? Int ?? 0,
                                         maxAttempts: dict["maxAttempts"] as? Int ?? 0,
                                         delayMs: dict["delayMs"] as? Int ?? 0)))

        case "auto_retry_end":
            // 成功/终败后底层 run 继续 (终败随 agent_end/settled 归 idle) → 回 streaming
            emit(.phaseChanged(.streaming))

        case "compaction_start":
            emit(.phaseChanged(.compacting(reason: dict["reason"] as? String ?? "threshold")))

        case "compaction_end":
            // 一次性横幅 (复用 extensionNotify 通道); 压缩后 run 继续 (overflow 场景 willRetry 重试)
            emitCompactionBanner(dict)
            // 常驻标记 + 当场改写上下文统计 (成功才发; 中止/失败什么都没变, 见 AgentEvent 注释)
            emitCompactionMarker(dict)
            emit(.phaseChanged(.streaming))

        case "summarization_retry_scheduled", "summarization_retry_attempt_start":
            emit(.phaseChanged(.summarizing))

        case "summarization_retry_finished":
            emit(.phaseChanged(.streaming))

        case "queue_update":
            let steering = dict["steering"] as? [Any] ?? []
            let followUp = dict["followUp"] as? [Any] ?? []
            let count = steering.count + followUp.count
            emit(.phaseChanged(count > 0 ? .queued(count: count) : .streaming))

        case "extension_error":
            // 扩展处理某个事件时抛错 (1.0.2 里包含 `turn_end` 边界解析失败:
            // "turn_end could not resolve the persisted assistant entry ID")。
            // ⚠️ 这条**两版都有**(0.85.1 的 rpc.md 事件表末行), 但 **1.0.2 的 docs/json.md
            // 没有它的条目** —— 字段形状只能读 `rpc-mode.js` 的 `onError`。
            // 原实现落进 default 静默丢弃 ⇒ **引擎自己报的错没人知道** (同 P12.1a 的病)。
            let ext = Self.extensionLabel(path: dict["extensionPath"] as? String ?? "")
            let evt = dict["event"] as? String ?? "?"
            let err = dict["error"] as? String ?? ""
            let text = String(format: L("扩展 %@ 在处理 %@ 时出错: %@"), ext, evt, err)
            emit(.extensionNotify(type: "error", message: String(text.prefix(200))))

        default:
            // 有意忽略的事件 (逐个核过, 不是漏接)。
            //  - `turn_start` / `turn_end`: 一轮 = 一次 assistant 回复 + 它的工具调用。
            //    ⚠️ 它们**不是 1.0 新增** —— 0.85.1 的 rpc.md 事件表与 json.md 都列着,
            //    `agent-session.js` 一直在转发 (所以 MangoX 一直在收)。不接的三条理由:
            //      ① 携带的信息 MangoX 已从**更细**的粒度拿到 (`message_end` 的权威消息 +
            //         usage、`tool_execution_end` 的工具结果) ⇒ `turn_end` 的
            //         `message`/`toolResults` 是**重复的聚合视图**;
            //      ② 它**不是回合结束** —— 拿它在 `agent_settled` 之前拆进程 = 腰斩自动重试
            //         (P6.0① 已实证的坑);
            //      ③ 0.87.0 起 `turn_end` 变成**可动作边界** (扩展可注入 entries 并 `continue: true`
            //         再跑一次 provider) ⇒ "`turn_end` 之后还有输出"是**正常**情况, 更不能用它判结束。
            //  - `bash_execution_update`: 只在客户端用 `bash` 命令时才有; MangoX 不发该命令
            //    (只发 prompt / abort / get_* / set_* / export_html / extension_ui_response) ⇒ 收不到。
            break
        }
    }

    // MARK: - 回合落定

    /// 归位过程态 + 拉会话统计 + 拆进程。**调用点必须只有两个**:
    ///   ① `agent_settled` —— 引擎说"会话级彻底落定"(P6.0① 的唯一拆进程点);
    ///   ② `prompt` 响应的 `handled` disposition —— 引擎说"这一回合**根本没有 run**"
    ///      (`agent-session.js:1522-1538`: 扩展命令就地执行 / 扩展 input handler 吃掉输入),
    ///      因此**不会有 `agent_settled`** ⇒ 不在这里落定, `turnActive` 会一直挂着
    ///      (胶囊永远停在 streaming, 进程也不拆)。
    /// ⚠️ 其余任何事件都不得调它 —— 尤其 `turn_end`(0.87.0 起它之后还能继续跑, 见上面的 `default`)。
    private func settleTurn() {
        turnActive = false
        finalizeTrackedMessages(usage: nil)   // 正常路径 usage 已随 message_end 落定, 此处仅为兜底
        emit(.phaseChanged(.idle))            // P6.1.2: 过程态归位
        emit(.streamEnded)
        if process != nil {
            // P6.1.1: 拆进程前拉一次会话统计 (context% 以 pi 口径为准), 响应到达再拆;
            // 2s 无响应兜底强拆。期间若用户已开新回合, turnActive 守卫防误拆。
            settleStatsPending = true
            sendCommand(["id": "req-\(nextRequestId())", "type": "get_session_stats"])
            settleStatsTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.settleStatsPending else { return }
                self.settleStatsPending = false
                if !self.turnActive { self.teardownProcess() }
            }
        } else {
            // per-turn: 回合结束即退出 (transcript 已持久化到 --session 文件;
            // 下回合 spawn 恢复, 天然隔离 + 无常驻内存/串味问题)
            teardownProcess()
        }
    }

    // MARK: - 审批 (extension_ui_request / extension_ui_response)

    private func handleExtensionUIRequest(_ dict: [String: Any]) {
        guard let reqId = dict["id"] as? String,
              let method = dict["method"] as? String else { return }

        // P6.0②: fire-and-forget 方法不回 response (rpc.md 明示语义; 回了也只会污染对端)。
        // notify 上抛横幅; setStatus/setWidget/setTitle/set_editor_text 是 TUI 概念, 忽略。
        if Self.fireAndForgetMethods.contains(method) {
            if method == "notify" {
                let type = dict["notifyType"] as? String ?? "info"
                let message = dict["message"] as? String ?? ""
                emit(.extensionNotify(type: type, message: String(message.prefix(200))))
            }
            return
        }

        let title = dict["title"] as? String ?? ""
        let parts = title.split(separator: "|", omittingEmptySubsequences: false).map(String.init)

        // 只认 MangoX 审批标记; 其他扩展 UI 请求自动确认, 避免进程挂死
        guard parts.count >= 5, parts[0] == "MANGOX", parts[1] == "APPROVE", method == "select" else {
            autoRespondExtensionUI(reqId, method: method)
            return
        }
        // diff 预览: detail 之后可能带 @@MANGOX_DIFF@@ 分段 (edit/write 审批)
        let fullDetail = parts.dropFirst(4).joined(separator: "|")
        let diffText: String?
        if let range = fullDetail.range(of: "@@MANGOX_DIFF@@") {
            diffText = String(fullDetail[range.upperBound...])
        } else {
            diffText = nil
        }
        let callId = parts[2]
        // ── P19 S6: 执行轮的门（红线 + 写围栏 + 步骤围栏）──────────────────────────
        //
        // ⚠️ 位置有三条硬理由，一条都不能挪：
        //   ① **在 `approvalMode.judgesByRisk` 之前** —— 全放行档也必须被拦（§03:
        //      「红线恒拒，任何档位、任何授权都不放行」）。放在档位判断之后，这条就只在
        //      "人恰好没关审批"时成立，那与红线无关，只是默认值。
        //   ② **在 `toolCards` 守卫之前** —— 卡片缺失时下面会直接 `Allow`；
        //      红线放在守卫之后 ⇒ 一条没有卡的 bash 调用就绕过去了。
        //   ③ **在 `BashRiskEvaluator.judge` 之前** —— 白名单（`ls`/`cat` 那类）会静默放行；
        //      `cat ~/.ssh/id_rsa` 正是白名单里的形状。
        if let g = executionGuard {
            let tool = parts[3]
            // bash 的目标是命令原文（可能带 `|`，所以按 dropFirst 拼回）;
            // write/edit 的目标是路径（`parts[4]`，**不含** diff 分段）。
            let target: String = tool == "bash"
                ? parts.dropFirst(4).joined(separator: "|")
                : (parts.count > 4 ? parts[4] : "")
            if let denial = ExecGate.check(guard: g, tool: tool, target: target,
                                          declaredStep: execDeclaredStep) {
                recordExecDenial(denial, step: execDeclaredStep ?? 0, tool: tool, target: target,
                                 callId: callId, card: toolCards[callId])
                respondExtensionUI(reqId, value: "Deny", callId: callId)
                return
            }
        }
        // ── P19.2 S11 的账本围栏（2026-11-18 删除）──────────────────────────────
        //
        // 这里原来有一整段「围栏外一律 Deny」：巡检轮 `mode == .deny`、对话轮 `mode == .ask`。
        // 删掉的不是"保护"，是"看起来是保护"：助理后续跑在**独立 Mac 主机**上，那台机器整个
        // 就是给它用的，限死"只能写账本"既拦不住有意为之的动作，又把正常干活堵死
        // （实测 11:04:49：巡检轮连 `ls` 都被拒）。
        //
        // 现在的边界在**人**这一侧，两级:
        //   ① 方案级 —— 要动手的事写成带方案的提议，人点「采纳并执行」才起执行轮;
        //   ② 重要操作级 —— 删 / 覆盖 / 重启 / 对外发, 在方案里单独列出来等人批。
        // 工具级弹卡在助理线上恒关（`ChatStore.beginTurn` 按"是不是助理会话"钉死）。
        //
        // ⚠️ 上面 `executionGuard` 那一段**保留**: 执行轮的「只做批过的那几步」是审批的兑现，
        //    不是围栏 —— 人批的是那几步，跑偏就该拦（`CaseWatchExec` 钉着）。
        guard var card = toolCards[callId] else {
            respondExtensionUI(reqId, value: "Allow", callId: callId)
            return
        }
        if diffText != nil {
            card = card.withDiffText(diffText)
        }

        // 全放行档: 不弹卡直接过 (定时任务; 弹卡无人点 = 死锁)
        guard approvalMode.judgesByRisk else {
            respondExtensionUI(reqId, value: "Allow", callId: callId)
            return
        }

        // P3.10 审批分层: bash 只读白名单静默放行 (判定覆盖所有会话)。
        // write 到达这里 = 覆盖已存在文件 (扩展侧 existsSync 放行新建) → 按 edit 弹卡。
        if parts[3] == "bash" {
            let cmd = parts.dropFirst(4).joined(separator: "|")
            let decision = BashRiskEvaluator.judge(command: cmd, learned: learnedBashTokens)
            if decision.isAllow {
                respondExtensionUI(reqId, value: "Allow", callId: callId)
                return
            }
            // P10.2a-0 无人值守: 危险命令 deny 且不阻塞 —— 不弹卡 (没人点会死锁),
            // 不静默放行 (那是缺口)。原因落卡片 + 记录, 供任务回执写 "卡在 X"。
            if approvalMode == .autoJudge {
                let reason = decision.risk?.label ?? BashRiskEvaluator.Risk.unknownCommand.label
                autoJudgeBlocks.append(AutoJudgeBlock(callId: callId, command: cmd, reason: reason))
                card = card.withPhase(.error(String(format: L("MangoX 自动裁决拦下: %@"), reason)))
                toolCards[callId] = card
                emit(.toolUpdated(card))
                respondExtensionUI(reqId, value: "Deny", callId: callId)
                return
            }
        } else if approvalMode == .autoJudge {
            // 决定 8 (P10.2) B 案: 分级只管 bash, write/edit 一律放行。
            //
            // ⚠️ P18 批 2a 的唯一例外: **computer 在远程驱动档一律拒**。
            //    理由不是"权限给多给少", 是**输入源** —— 定时任务的指令是用户自己写的,
            //    而邮箱哨兵驱动的这一档, 指令可能是**任何人发来的邮件正文**。同一张权限表
            //    表达不了这个差别, 所以它必须是显式分支, 不许靠"以后加个开关"绕过去。
            //    落痕同 bash 那条(autoJudgeBlocks + 卡片标红), 让任务回执能写"卡在 X"。
            if ApprovalGate.isComputerTool(parts[3]) {
                let reason = L("远程驱动档不允许操作界面")
                autoJudgeBlocks.append(AutoJudgeBlock(callId: callId,
                                                      command: fullDetail,
                                                      reason: reason))
                card = card.withPhase(.error(String(format: L("MangoX 自动裁决拦下: %@"), reason)))
                toolCards[callId] = card
                emit(.toolUpdated(card))
                respondExtensionUI(reqId, value: "Deny", callId: callId)
                return
            }
            respondExtensionUI(reqId, value: "Allow", callId: callId)
            return
        }

        // computer: **作用域那个勾就是授权**(P18 批 2d, 2026-10-29 boss 拍板)。
        //
        // ⚠️ 为什么这里**不弹卡**:
        //    勾上「可操作」本身就是一次明确的授权, 而且 helper 侧还有一道硬门
        //    (`ComputerAct.swift:160` 的 `scope.actBundles.contains`, 独立进程) —— 客户端
        //    漏判也绕不过去。在这之上再弹一张卡 = 同一个决定问第二遍; 而一次 GUI 任务
        //    十几个动作, 连点十几次「允许」之后那张卡就是摆设(告警疲劳, 保护等于 0)。
        //    曾经做过一份「始终允许」名单来记住这件事, 是**补丁**: 真正缺的是"授权该落在
        //    哪一层", 而不是"怎么记住"。名单已删 —— 别再把它加回来。
        //
        // ⚠️ 不变量: **客户端的判断只用来拒, 不用来放行**。
        //    算不出是哪个 App(模型没给 app = 当前前台)时 `?? true` **不表态**, 交 helper 用
        //    同一份名单判 —— "当前前台是谁"在决定的那一刻只有 helper 知道。拒错了最多多拒
        //    一次(可恢复), 放行错了是真出事。
        //
        // ⚠️ 位置与上面两条的相对顺序不许动: 全放行档与 autoJudge 已经 return 了 ——
        //    远程驱动档的指令可能是任何人发来的邮件正文, 它的拒**不许**被"用户勾过"绕过。
        //    也正因为如此, 走到这里的 computer 工具按定义都是非只读的(read 在 JS 里就放行),
        //    所以用前缀判据不会误伤 read。
        //
        // ⚠️ **`computer_open` 查的是"允许碰"那一档**(`activeAllowedBundles` = 读 ∪ 视觉),
        //    不是操作面 —— 打开一个 App 与"在 Dock 上点一下图标"是同一件事, 它不动 App 里的
        //    任何东西; 而清单页上写的是「可读」「视觉」「可操作」三档, 用户勾了前两档里
        //    任意一个就该能打开它。查操作面的话, 一个只勾了读的 App **连打开都要动权限** ——
        //    那是把两档权限合成了一档。
        //    （2026-11-10 从 `activeBundles` 换成它: 只勾视觉的 App——微信——也得能打开。）
        if ApprovalGate.isComputerTool(parts[3]) {
            let isOpen = parts[3] == Self.computerOpenToolName
            let allowed = isOpen
                ? ComputerSettings.shared.activeAllowedBundles
                : ComputerSettings.shared.activeActBundles
            let bundle = ComputerSettings.shared.resolveBundle(query: card.title)
            if bundle.map({ allowed.contains($0) }) ?? true {
                respondExtensionUI(reqId, value: "Allow", callId: callId)
            } else {
                // 没勾 ⇒ **不弹卡**: 用户点了「允许」helper 照样拒(名单没变), 那张卡是纯误导,
                // 而且它给不了补救路径(勾选不在卡上)。直接在卡上把话说明白。
                // ⚠️ 两档话说两句, 不拼装: 句子里那块词(`可读`/`可操作`)本身是译文,
                //    用 `string(format:)` 往里塞会把语序交给别的语言去猜(词表里也就只剩
                //    半句话, 译者看不见它填进哪儿)。
                let hint = String(format: isOpen
                                  ? L("「%@」还没勾「可读」⇒ 没打开它。到「设置 → 电脑操作」里给这个 App 勾上")
                                  : L("「%@」还没勾「可操作」⇒ 没动它。到「设置 → 电脑操作」里给这个 App 勾上"),
                                  card.title)
                card = card.withPhase(.error(hint))
                toolCards[callId] = card
                emit(.toolUpdated(card))
                respondExtensionUI(reqId, value: "Deny", callId: callId)
            }
            return
        }

        card = card.withPhase(.awaitingApproval)
        toolCards[callId] = card
        emit(.toolUpdated(card))
        pendingApprovals.append(PendingApproval(requestId: reqId,
                                                toolUUID: card.id,
                                                callId: callId))
    }

    /// P6.0②: fire-and-forget 扩展 UI 方法 (rpc.md §1277-1345, 不期待 response)。
    private static let fireAndForgetMethods: Set<String> =
        ["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"]

    /// P12.2: 非审批扩展 UI 请求的应答形状 (**纯函数, 冒烟直测**)。
    /// 形状合法性来源: `rpc-mode.js:84-86`(select/confirm/input) 与 `:174-187`(editor)
    /// 都把 `{cancelled:true}` 解析成"用户没答"。
    static func unattendedExtensionUIResponse(id: String) -> [String: Any] {
        ["type": "extension_ui_response", "id": id, "cancelled": true]
    }

    /// P12.2: 对**非 MangoX 审批**的扩展 UI 请求自动应答 —— 一律回**合法的"没答"**。
    ///
    /// ⚠️ 原实现对 `confirm` 回 `confirmed:true`、其余一律回 `value:"Allow"`。后半个分支是
    /// **语义错答**: `input`(要一段文本) / `editor`(要整段编辑文本) 收到 `"Allow"` 就是
    /// "把一段文本当成 Allow" —— 现在不炸, 只因为 MangoX 只挂自己的审批扩展(只用 `select`)
    /// ⇒ **是"只挂自己扩展"这个前提撑着的侥幸**, 一旦用户挂了第三方扩展就会出怪事。
    ///
    /// 为什么是 `cancelled` 而不是"不回"或"回一个空串":
    ///   ① **形状合法**: 见 `unattendedExtensionUIResponse`;
    ///   ② **不回会挂死**: `editor`(`rpc-mode.js:174-187`) **没有 timeout**, 不回就是永久 pending;
    ///   ③ **不发明同意**: MangoX 对第三方扩展的提问没有任何依据作答 —— 回 `Allow` 等于替用户点了同意。
    /// 同时**上抛告警**: "未识别的方法"与"用户没答"是两件事, 必须留痕(宁可留痕, 不要瞎答)。
    private func autoRespondExtensionUI(_ reqId: String, method: String) {
        sendCommand(Self.unattendedExtensionUIResponse(id: reqId))
        emit(.extensionNotify(type: "warning",
                              message: String(format: L("扩展请求了 MangoX 不处理的「%@」界面, 已按「取消」应答。"),
                                              method)))
    }

    /// 发送审批响应。Allow 时重置计时起点: 时长口径 = 允许决定之后的真实执行,
    /// 审批等待 (手动点击) 与白名单放行前的排队 (UI 渲染卡顿) 都不计入。
    private func respondExtensionUI(_ reqId: String, value: String, callId: String? = nil) {
        sendCommand(["type": "extension_ui_response", "id": reqId, "value": value])
        if value.hasPrefix("Allow"), let callId { toolStartAt[callId] = Date() }
    }

    // MARK: - Helpers

    private func lazyID(_ slot: inout UUID?) -> UUID {
        if let id = slot { return id }
        let id = UUID()
        slot = id
        return id
    }

    /// 消息边界: 落定在途块并重置 id, 下一个 delta 开新块。usage 挂在最后一个落定块
    /// (LLM 调用级元数据: 同一次调用的 think 块在前, 文本块在后拿 usage; 仅 think 时 think 拿)。
    private func rollMessageBoundary(usage: MessageUsage? = nil) {
        finalizeTrackedMessages(usage: usage)
        textMessageID = nil
        thinkMessageID = nil
    }

    private func finalizeTrackedMessages(usage: MessageUsage?) {
        let textID = textMessageID, thinkID = thinkMessageID
        if let tid = thinkID { emit(.messageFinalized(messageID: tid, usage: textID == nil ? usage : nil)) }
        if let sid = textID { emit(.messageFinalized(messageID: sid, usage: usage)) }
    }

    /// P6.0③: 从 pi assistant message 提取用量 (字段缺失容忍, 全缺返回 nil)。
    private static func parseUsage(_ msg: [String: Any]) -> MessageUsage? {
        guard let u = msg["usage"] as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { u[key] as? Int ?? 0 }
        let usage = MessageUsage(
            input: int("input"), output: int("output"),
            cacheRead: int("cacheRead"), cacheWrite: int("cacheWrite"),
            reasoning: int("reasoning"), totalTokens: int("totalTokens"),
            costUSD: (u["cost"] as? [String: Any])?["total"] as? Double,
            model: msg["model"] as? String,
            responseId: msg["responseId"] as? String)
        return usage.totalTokens > 0 ? usage : nil
    }

    // MARK: - 能力上报响应 (P3.5: type=response 行)

    /// pi 响应格式: {id, type:"response", command, success, data?/error?}
    private func handleRPCResponse(_ dict: [String: Any]) {
        let command = dict["command"] as? String ?? ""
        // P6.2.3: export_html 失败也上报 (UI 横幅), 不走"失败静默"
        if command == "export_html" {
            let path = (dict["success"] as? Bool == true)
                ? (dict["data"] as? [String: Any])?["path"] as? String : nil
            finishExport(path: path)
            if !turnActive { teardownProcess() }
            return
        }
        guard dict["success"] as? Bool == true else { return }   // 失败静默 (如模型不存在)
        let data = dict["data"] as? [String: Any] ?? [:]
        switch command {
        case "get_state":
            // data: { model: {provider, id, ...}, thinkingLevel: "...", sessionFile: "...", ... }
            // P6.3.1: fork 产物路径回读 (仅在 fork 在途时消费, 普通会话的上报忽略)
            if let file = data["sessionFile"] as? String, !file.isEmpty, forkReadbackPending {
                finishForkReadback(path: file)
            }
            if let model = data["model"] as? [String: Any],
               let provider = model["provider"] as? String,
               let modelId = model["id"] as? String {
                let level = data["thinkingLevel"] as? String ?? ""
                // 2026-11-20: pi **实际**的模型/级别。与 `spawn-model` 成对读。
                // ⚠️ 这里必须记，不能只靠 ChatStore 那条 delegate —— 那边
                //    `guard transport === capabilityProbe` 会把**会话实例**的上报全丢掉
                //    （结构如此：UI 上的那套是"我计划的"，不是"真跑的"）。
                //    只想要"看到的模型"时它是对的；想查"对不上"时必须看这一行。
                Log.event("pi-model", [
                    "sid": desiredSessionId?.uuidString ?? "(ephemeral)",
                    "model": "\(provider)/\(modelId)",
                    "thinking": level.isEmpty ? "-" : level,
                ])
                delegate?.transport(self, didUpdateModelState: provider,
                                    modelId: modelId, thinkingLevel: level)
            }
        case "get_available_models":
            // data: { models: [{provider, id, reasoning, thinkingLevelMap, ...}, ...] }
            if let models = data["models"] as? [[String: Any]] {
                let infos: [AgentModelInfo] = models.compactMap { m -> AgentModelInfo? in
                    guard let provider = m["provider"] as? String,
                          let id = m["id"] as? String else { return nil }
                    // 级别语义的唯一实现在 ThinkingLevel.supported (本文件曾是两份拷贝之一)
                    return AgentModelInfo(
                        provider: provider, id: id,
                        name: m["name"] as? String ?? "",
                        supportedLevels: ThinkingLevel.supported(
                            reasoning: (m["reasoning"] as? Bool) ?? false,
                            map: (m["thinkingLevelMap"] as? [String: Any]) ?? [:]))
                }
                delegate?.transport(self, didReportModels: infos)
            }
        case "get_session_stats":
            // P6.1.1: 会话统计上报 (spawn 期 + settled 拆进程前各拉一次)
            let full = Self.parseSessionStats(data, reserveTokens: resolvedReserveTokens)
            lastFullStats = full                 // usageTick 的底稿 (见 noteLiveUsage)
            delegate?.transport(self, didReportSessionStats: full)
            if settleStatsPending {
                settleStatsPending = false
                settleStatsTask?.cancel()
                settleStatsTask = nil
                if !turnActive { teardownProcess() }   // 已开新回合则不拆
            }
        case "set_model", "set_thinking_level":
            // 切换成功后回读 get_state, 以 pi 侧状态为准同步 UI
            sendCommand(["id": "req-\(nextRequestId())", "type": "get_state"])
        case "prompt":
            // P12.2: 1.0 起 prompt 的**成功**响应带 `data.disposition`
            // (`agent-session.d.ts:168` = "started" | "queued" | "handled")。原先走 default 丢弃。
            // 三态各自的处置(逐个核过, 不是漏接):
            //  - `started` → **有意不动作**: 权威的"开跑了"是紧接着的 `agent_start`
            //    (`:807-810` 已在它上面发 `.phaseChanged(.streaming)`), 这里再发一次是重复。
            //  - `queued`  → **不可达**: 只有 pi 侧正在流式时才返回它, 而 MangoX 在会话有回合
            //    在途时**根本不发 prompt**(`ChatStore.sendDraft` 的 `runningTurns` 守卫, P4.0.2) ⇒
            //    留着不处理; 队列显示由权威的 `queue_update` 负责。
            //  - `handled` → **必须处理**: 扩展命令就地执行 / 扩展 input handler 吃掉输入 ⇒
            //    没有 run、**没有 `agent_settled`** ⇒ 不落定就是胶囊永远 streaming + 进程不拆。
            switch data["disposition"] as? String {
            case "handled": if turnActive { settleTurn() }
            default: break
            }
        default:
            break
        }
    }

    // MARK: - 会话统计 (P6.1.1)

    /// P6.1.2: compaction_end → 一次性横幅 (复用 extensionNotify 通道)。
    /// 成功报 tokensBefore → estimatedTokensAfter; 中止/失败按 warning 报原因。
    private func emitCompactionBanner(_ dict: [String: Any]) {
        let aborted = dict["aborted"] as? Bool ?? false
        let message: String
        if aborted {
            message = L("上下文压缩已中止")
        } else if let result = dict["result"] as? [String: Any] {
            let before = result["tokensBefore"] as? Int ?? 0
            let after = result["estimatedTokensAfter"] as? Int ?? 0
            message = String(format: L("上下文压缩完成：%lld → %lld tokens"), before, after)
        } else {
            let err = dict["errorMessage"] as? String ?? L("未知错误")
            message = String(format: L("上下文压缩失败：%@"), err)
        }
        emit(.extensionNotify(type: aborted ? "warning" : "info", message: String(message.prefix(200))))
    }

    /// A: `compaction_end` 带 result ⇒ 一条**常驻**事实 (消息流系统标记 + 改写上下文统计)。
    ///
    /// 判据只看 `result != nil` 且 `aborted != true` —— 这与横幅那边"三路"的判据**有意不同**:
    /// 横幅要覆盖失败/中止(用户此刻需要知道), 而常驻行只记"发生了改变"的事。
    /// `estimatedTokensAfter` 缺失时也**不发** —— 一条说不出代价的标记没有信息量。
    private func emitCompactionMarker(_ dict: [String: Any]) {
        guard dict["aborted"] as? Bool != true,
              let result = dict["result"] as? [String: Any],
              let after = result["estimatedTokensAfter"] as? Int else { return }
        let before = result["tokensBefore"] as? Int ?? 0
        // reason 缺失时给空串而不是猜 "threshold": 标记上"不知道谁触发的"是诚实,
        // 猜成自动压缩则是编事实 (它可能来自我们以后要加的手动入口)。
        emit(.contextCompacted(tokensBefore: before, tokensAfter: after,
                               reason: dict["reason"] as? String ?? ""))
    }

    /// message_update 顶层累计 usage → usageTick (500ms 节流)。
    /// 流式 usage 无 context%, contextPercent 留 nil 由 Store 沿用最近一次上报。
    ///
    /// ⚠️ **必须带上 context 三件套** (`contextTokens` / `contextWindow` / `contextReserveTokens`)。
    ///    `.usageTick` 是**增量投影**, 而 Store 侧 `applySessionStats` 是**整结构体替换**
    ///    (只对 percent 做 nil 兜底) —— 早先这里每个 tick 都新建一个空 `SessionStats`,
    ///    于是 `contextWindow` / `contextReserveTokens` 在第一个 tick 就被清成 0:
    ///    底栏那条「压缩线」会随即消失, 且**零红灯**(0 读起来就是"未知")。
    ///    修法是让 tick 从最近一次**完整**上报继承底稿, 只覆写用量那几项。
    private func noteLiveUsage(_ u: [String: Any]) {
        var stats = lastFullStats ?? SessionStats()
        stats.contextPercent = nil
        stats.inputTokens = u["input"] as? Int ?? 0
        stats.outputTokens = u["output"] as? Int ?? 0
        stats.cacheReadTokens = u["cacheRead"] as? Int ?? 0
        stats.costUSD = (u["cost"] as? [String: Any])?["total"] as? Double
        let now = Date()
        guard now.timeIntervalSince(lastUsageTickAt) >= 0.5 else { return }
        lastUsageTickAt = now
        emit(.usageTick(stats))
    }

    /// get_session_stats data → SessionStats (字段缺失容忍; percent null → nil)。
    /// `reserveTokens` 由调用方给 (spawn 期解析的压缩预算, 0 = 未知) —— 这个文件是无状态
    /// 的解析函数, 刻意不自己去读盘 (它会被冒烟直接喂 JSON 断言)。
    private static func parseSessionStats(_ data: [String: Any],
                                          reserveTokens: Int = 0) -> SessionStats {
        func int(_ v: Any?) -> Int { v as? Int ?? 0 }
        func dbl(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            return nil
        }
        let t = data["tokens"] as? [String: Any] ?? [:]
        let c = data["contextUsage"] as? [String: Any] ?? [:]
        return SessionStats(
            contextPercent: dbl(c["percent"]),
            contextTokens: int(c["tokens"]),
            contextWindow: int(c["contextWindow"]),
            contextReserveTokens: reserveTokens,
            inputTokens: int(t["input"]),
            outputTokens: int(t["output"]),
            cacheReadTokens: int(t["cacheRead"]),
            costUSD: (data["cost"] as? [String: Any]).flatMap { dbl($0["total"]) })
    }

    /// ⚠️ 这里是"本回合有没有产出"的**唯一定义处**。判据挂在事件上、不挂在各个解析分支上 ——
    /// 否则迟早有一个分支忘了置位（`.toolUpdated` 就有五处 emit）。
    private func emit(_ event: AgentEvent) {
        switch event {
        case .textChunk, .thoughtChunk, .toolUpdated, .toolPhaseChanged:
            turnProducedOutput = true
        default:
            break
        }
        delegate?.transport(self, didEmit: event)
    }

    /// 卡头两列 (title / command) 的**唯一**推导处 —— `toolcall_end` 与 `tool_execution_start`
    /// 都调它。两处各写一套必然分叉 (前者是"参数已定", 后者是"开始执行"), 分叉后的症状是
    /// 卡片在两步之间**跳一下**、或者审批时看到的命令和随后执行的不是一条。
    private static func toolHead(kind: ToolKind, name: String, args: [String: Any])
        -> (title: String, command: String?) {
        let cmd = args["command"] as? String
        let path = args["path"] as? String
        // 未知工具 (kind == .other) 的卡头标签恒为 "OTHER", 标签本身不携带真名 ⇒ 真名必须
        // 占 title, 否则用户看不出跑的是哪个扩展工具 (args 退到 command 列)。
        if kind == .other { return (name, cmd ?? path ?? firstScalarArg(args)) }
        // P18 computer: 唯一要紧的参数是**哪个 App**(act 还要看动作与文本)。
        // ⚠️ 走下面的通用式会让 `app` 从卡上消失 —— 它既不是 `path` 也不是 `command`,
        //    title 会退成工具名、command 恒 nil ⇒ 卡头只剩 `computerAct` 一个词, 看不出动的是谁。
        //    那正是"看着像没发生"的那种卡: 审批时人要在**界面上**找它说的是哪个窗口。
        if Self.computerToolNames.contains(name) {
            let app = (args["app"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let op = (args["op"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var cmd = op.isEmpty ? nil : op
            // 第四档没有 `op`: 它唯一的参数是那个点。不写进 command 列, 卡上就只剩 App 名,
            // 而审批时人要在**界面上**找它说的是哪个位置。
            if name == Self.computerTapToolName {
                let x = args["x"].map { "\($0)" } ?? "?"
                let y = args["y"].map { "\($0)" } ?? "?"
                return (app.isEmpty ? name : app, "tap (\(x),\(y))")
            }
            // 第五档同样没有 `op` / 没有坐标: 它要紧的是**写什么**与**会不会按回车**。
            // ⚠️ `submit` 必须上卡: 那是"只写上"与"发出去"的分界 —— 审批时人要靠这一行决定,
            //    藏在参数里等于让人签一张自己没读过的字。
            // ⚠️ 这里不写汉字(与上面 `tap (x,y)` 同): 审批卡的 command 列是给眼睛看的定位信息,
            //    不是句式, 拼进 L() 反而会在两种语言下都变长。
            if name == Self.computerTypeToolName {
                let body = (args["text"] as? String) ?? ""
                let willSubmit = (args["submit"] as? Bool) == true
                return (app.isEmpty ? name : app,
                        (willSubmit ? "type + Enter (send): " : "type: ")
                            + "\"" + String(body.prefix(60)) + "\"")
            }
            // 第六档: 没有元素、没有坐标, 全部内容**就是那一串键**。不上卡就等于让人签一张
            // 空白单子 —— 而这一档能一手把整篇正文删掉(见 `computerKeysToolName` 的注释)。
            if name == Self.computerKeysToolName {
                let list = (args["strokes"] as? [Any])?.compactMap { $0 as? String } ?? []
                let joined = list.isEmpty ? "(none)" : list.joined(separator: " → ")
                return (app.isEmpty ? name : app, "keys: " + String(joined.prefix(80)))
            }
            // setValue 的正文要看得见: 审批时"要往这个框里写什么"就是这个动作的全部内容。
            if let text = args["text"] as? String, !text.isEmpty {
                cmd = (cmd.map { $0 + " " } ?? "") + "\"" + String(text.prefix(60)) + "\""
            }
            // `app` 省略 = 读/动**前台**那个 App (扩展侧就是这么做的) ⇒ 用真名占 title,
            // 别编一个"前台"上去: 那一刻前台是谁, 这里并不知道。
            return (app.isEmpty ? name : app, cmd)
        }
        // P13 codemode: 唯一参数是 `code` (**整段脚本**), 没有 path/command ⇒ 若走下面的通用式,
        // `title` 会退成 name(`codemode`)、`command` 恒 nil ⇒ **整段脚本从卡上消失**。
        // 让它占 title, 与 bash 的 `title = cmd` 同一道理; 审批时"要批的脚本"也才看得见。
        // ⚠️ 脚本可能以 `// @options:` 开头 —— 那就显示那一行 (pi 自己的 renderer 也是把该行
        //    当脚本一部分渲染的), 不特判、不猜"哪行才算正文"。
        if kind == .codemode { return (args["code"] as? String ?? name, nil) }
        // P10.1b 联网搜索: 唯一要紧的参数就是**查询词** —— 它没有 path/command ⇒ 走下面的通用式
        // 会让 `title` 退成工具名 (`bocha_web_search`)、`command` 恒 nil ⇒ **查询词从卡上消失**,
        // 而且比落 `.other` 还糟 (`.other` 至少把首个标量参数放进 command 列)。
        // ⚠️ 判据钉在**工具名**上 (`webSearchToolNames`), **不**写成 `kind == .search`: `.search`
        //    是通用的"搜索"档, 将来别的搜索工具的参数未必叫 `query` —— 拿它去猜就是"把 A 的
        //    字段喂给 B"。`kind == .codemode` 那条敢按 kind 写, 是因为 codemode 只会有一个生产方。
        if Self.webSearchToolNames.contains(name) { return (args["query"] as? String ?? name, nil) }
        // 2026-11-23: 自建扩展的三个工具 —— 与 codemode / bocha 同一条理由(关键参数既不是
        // `path` 也不是 `command`), 但丢的东西各不相同:
        //   · `follow_up`: 唯一的信息是 `why`(醒来时要看什么) —— 走通用式它会整个消失,
        //     卡上只剩 `followUp · follow_up`; 而 `after_minutes` 正是"它自己说多久后回来"。
        //   · `feishu_attach`: 要紧的是**用户收到的那份文件**(`name`; 省略时取 `path` 的末段) ——
        //     通用式会把**整条绝对路径**塞进 title, 把 command 列挤掉, 而路径规则恒是
        //     Documents/Downloads。
        //   · `note_proposal`: 要紧的是「改哪一篇 + 哪种改动」。⚠️ 它**绝不能**走通用式:
        //     首个标量参数按 key 排序是 `base_hash`(恒空的机器字段, App 自己填) ⇒ 卡头会变成
        //     `noteProposal · note_proposal · base_hash=` —— 三个词全是噪音。
        // ⚠️ 三处 command 都用英文短语(同 `tap (x,y)` / `keys: …` 的既有口径): 那一列是给
        //    眼睛的定位信息, 不是句式; 拼进 `L()` 在两种语言下都只会更长。
        if Self.followUpToolNames.contains(name) {
            let why = (args["why"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mins = (args["after_minutes"] as? Int)
                ?? (args["after_minutes"] as? NSNumber)?.intValue
            return (why.isEmpty ? name : why, mins.map { "in \($0) min" })
        }
        if Self.attachToolNames.contains(name) {
            let path = (args["path"] as? String) ?? ""
            let base = (path as NSString).lastPathComponent
            let shown = (args["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // title = **用户收到的那个名字**(`name` 省略时就是磁盘上的文件名)。
            // 两者不同时把磁盘名留在 command: 否则回看时"发出去的到底是哪个文件"对不上。
            let title = shown.isEmpty ? base : shown
            return (title.isEmpty ? name : title,
                    (base.isEmpty || base == title) ? nil : "file: " + base)
        }
        if Self.dreamToolNames.contains(name) {
            let path = (args["target_path"] as? String) ?? ""
            let base = (path as NSString).lastPathComponent
            let op = (args["kind"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (base.isEmpty ? name : base, op.isEmpty ? nil : op)
        }
        let title = path ?? cmd ?? name
        return (title, (cmd != nil && title == cmd) ? nil : cmd)
    }

    /// 未知工具的参数兜底: 取**第一个标量参数**渲染成 `key=value`。
    /// 对未知工具"哪个参数重要"是不可知的, 但"它有参数"是事实 —— 丢掉才是隐瞒。
    /// 按 key 排序取首个 ⇒ 同一调用**幂等** (两次推导必得同一结果, 卡头不会跳)。
    private static func firstScalarArg(_ args: [String: Any]) -> String? {
        for key in args.keys.sorted() {
            guard let v = args[key] else { continue }
            if let s = v as? String, !s.isEmpty { return "\(key)=\(s)" }
            if let b = v as? Bool { return "\(key)=\(b)" }
            if let n = v as? NSNumber { return "\(key)=\(n)" }
        }
        return nil
    }

    private func kindFor(_ toolName: String) -> ToolKind {
        // P18: computer 的三个工具 —— 同 codemode / `bocha_web_search` 那条, **按名归位**, 不落
        // other。落 other 不只是标签难看: `toolHead` 对 `.other` 走"真名占 title"的兜底 ⇒
        // 卡头会变成 `OTHER · computer_act · app=计算器`, 而且轨迹页那串"同类分组"会把
        // 读界面、动界面、打开 App 混进一堆叫 OTHER 的东西里。
        // ⚠️ 用常量比较而不是 case 字面量: `switch` 的 case 模式放不下 static property,
        //    写死字面量就等于把"名字不许漂"这条又一次交给记忆。
        if toolName == Self.computerReadToolName { return .computerRead }
        if toolName == Self.computerActToolName { return .computerAct }
        if toolName == Self.computerOpenToolName { return .computerOpen }
        // 2026-11-23: 第四~六档 —— 它们原来全落 `.other`(boss 截图: `email other computer_type`)。
        // ⚠️ 代价不止标签: `toolHead` 对 `.other` 先一步 return ⇒ 那三段为 tap/type/keys
        //    写好的卡头(`tap (x,y)` / `type: "…"` / `keys: …`)**从写下来那天起没执行过**,
        //    卡上只有 `app=…`(首个标量参数) ⇒ "它到底点了哪儿/写了什么"整个消失。
        if toolName == Self.computerTapToolName { return .computerTap }
        if toolName == Self.computerTypeToolName { return .computerType }
        if toolName == Self.computerKeysToolName { return .computerKeys }
        // 2026-11-23: 自建扩展的三个工具。这里**用常量而不是 `switch` 的字面量** —— 上面
        // `bocha_web_search` 那条只能写死字面量(Swift 的 case 模式放不下 static property),
        // 于是"名字改了忘了同步"只能靠冒烟兜; 能写成 `contains` 的就没必要留这个缺口。
        // ⚠️ 判据恒按**工具名**, 不按前缀猜: 同 `computer_scroll` 那条 —— 没登记就是 `.other`。
        if Self.followUpToolNames.contains(toolName) { return .followUp }
        if Self.attachToolNames.contains(toolName) { return .feishuAttach }
        if Self.dreamToolNames.contains(toolName) { return .noteProposal }
        switch toolName {
        case "bash", "powershell": return .bash   // P6.0④: powershell 是 Windows 同族
        case "read": return .read
        case "grep": return .grep                 // P6.0④: 内置工具补全 (原落 default 错显 read)
        case "find": return .find
        case "ls": return .ls
        case "edit": return .edit
        case "write": return .write
        case "fetch": return .fetch
        case "search": return .search
        case "image": return .image
        case "delegate": return .delegate         // pi 0.85.1 无内置生产方, 留位给扩展
        // P13: codemode 由**自建扩展**注册 (pi 的 `builtin:codemode` 没有传 options 的口子),
        // 但上报的工具名恒为 `codemode` ⇒ 按名归位, 不落 other。
        case "codemode": return .codemode
        // P10.1b: 自建联网搜索扩展注册的工具 —— 同 codemode 那条, 按名归位。
        // ⚠️ 这里**只能写死字面量** (`switch` 的 case 模式放不下 `webSearchToolNames`),
        //    所以"字面量与 `webSearchToolNames` 不许漂"靠冒烟那条 — 它用常量当工具名发 RPC
        //    ⇒ 谁把这里改错名字, 那条断言立刻红。
        case "bocha_web_search": return .search
        // ⚠️ **不许再 return .read** —— 那是谎报: 装了 subagents / mcp-adapter 这类扩展后,
        // 卡片标签会**读作 READ**, 轨迹页 chip 更连**颜色一起错** (`defaultColor` 只在轨迹页用;
        // 卡片标签色走 `railColor`, 由相态决定 ⇒ 那里错的是文字不是颜色)。
        // 且落库的 kind 已失真、事后分不出"真 read"和"未知工具"。
        // 中性 OTHER 难看, 但它是诚实的; 真名由 `toolHead` 放进 title (见下)。
        // ⚠️ 但它只是**兜底**, 不是终点: 我们自己扩展注册的工具**该按名归位** (上面 codemode 与
        //    `bocha_web_search` 都是) —— OTHER 留给"连参数含义都不可知"的第三方扩展。
        default: return .other
        }
    }

    /// pi 的工具结果是 **`AgentToolResult`**, 不是裸字符串:
    ///   `{ content: (TextContent | ImageContent)[], details: T, usage?, terminate? }`
    ///   `TextContent  = { type: "text",  text: String }`
    ///   `ImageContent = { type: "image", data: String(base64), mimeType: String }`
    /// (pi-agent-core/types.d.ts:317-331 · pi-ai/types.d.ts:251-255 · 实测 read.js:85 返回图片块)
    ///
    /// ⚠️ **旧版 `outputString` 只在顶层找字符串键** ⇒ `content[]` 整个没看 ⇒ 每张卡
    /// `"details":[]`(连成功的 `cat` 也没输出), 失败时只剩一句兜底文案。**这是丢数据, 不是没数据。**
    private struct ParsedToolResult {
        var text: String?
        var images: [(data: String, mimeType: String)] = []
        /// `details` 的可读折平 (各工具自定结构: bash 有 truncation/fullOutputPath)。
        var detailsSummary: String?
    }

    private func parseToolResult(_ v: Any?) -> ParsedToolResult {
        var out = ParsedToolResult()
        // 老/异形形状兜底: 扩展可能直接给字符串
        if let s = v as? String {
            out.text = s.isEmpty ? nil : s
            return out
        }
        guard let d = v as? [String: Any] else { return out }

        if let blocks = d["content"] as? [Any] {
            var texts: [String] = []
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty { texts.append(t) }
                case "image":
                    if let data = block["data"] as? String, !data.isEmpty {
                        out.images.append((data, block["mimeType"] as? String ?? "image/png"))
                    }
                default:
                    break
                }
            }
            if !texts.isEmpty { out.text = texts.joined(separator: "\n") }
        }
        // 无 content[] 的结果: 退回顶层字符串键 (旧口径, 保留)
        if out.text == nil {
            for k in ["output", "text", "result"] {
                if let s = d[k] as? String, !s.isEmpty { out.text = s; break }
            }
        }
        if let det = d["details"] {
            out.detailsSummary = Self.flattenDetails(det)
        }
        return out
    }

    /// `details` 折成一行可读文本 (`key=value · key.sub=1`)。
    /// **只在正文缺失时才有资格上屏** —— `content[].text` 已是给模型的摘要 (含
    /// "[Showing lines 1-50 of 300…]" 这类续读提示), 常见情形下 details 是它的子集, 同时
    /// 显示只会多一行噪声。
    private static func flattenDetails(_ v: Any) -> String? {
        var parts: [String] = []
        flatten(v, prefix: "", into: &parts)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func flatten(_ v: Any, prefix: String, into out: inout [String]) {
        if let d = v as? [String: Any] {
            for k in d.keys.sorted() {
                let key = prefix.isEmpty ? k : "\(prefix).\(k)"
                flatten(d[k] as Any, prefix: key, into: &out)
            }
        } else if let a = v as? [Any] {
            for (i, item) in a.enumerated() { flatten(item, prefix: "\(prefix)[\(i)]", into: &out) }
        } else if v is NSNull {
            return                                   // 空值不占位 (JSON null = 无此项)
        } else if let b = v as? Bool {
            out.append("\(prefix)=\(b)")
        } else if let n = v as? NSNumber {
            out.append("\(prefix)=\(n)")
        } else if let s = v as? String, !s.isEmpty {
            out.append("\(prefix)=\(s)")
        }
    }

    /// 工具产出图片的落盘位置键。有会话绑定用会话 id (这样"删会话"的
    /// `ImagePipeline.removeSessionAttachments` 一并覆盖); 无绑定 (任务 fire 的
    /// --no-session 回合) 退到 transport 实例 id —— 这类会话本来就没有 UI, 不必回收。
    private let transportInstanceId = UUID()
    private var imageOwnerId: UUID { desiredSessionId ?? transportInstanceId }

    /// base64 图片块 → 落盘 → 返回本机路径。落盘失败返回 nil (**不猜、不留半张**)。
    private func persistToolImages(_ images: [(data: String, mimeType: String)],
                                   owner: UUID) -> [String] {
        var paths: [String] = []
        for img in images {
            guard let data = Data(base64Encoded: img.data) else { continue }
            let ext = ImagePipeline.sniffExtension(data)
                ?? img.mimeType.split(separator: "/").last.map(String.init)
                ?? "png"
            if let saved = try? ImagePipeline.saveOriginal(data, fileExtension: ext, sessionID: owner) {
                paths.append(saved.path)
            }
        }
        return paths
    }
}
