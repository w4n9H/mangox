//
//  FollowUpModels.swift
//  follow-up（2026-11-23）—— **agent 给自己约定时器**。
//
//  起因（2026-11-23 boss）：「我设置了一个周循环，那这件事只能等下周了」。
//  在此之前 MangoX 的触发只有三档：巡检轮（cron）、对话轮（飞书进来）、执行轮（方案被批准）。
//  三档全是**外部**给的时点 —— agent 判断完"这事明天再看"，除了等下一轮 cron 之外没有任何出口。
//  follow-up 补的就是这个缺口：它在回合里约一个时刻，到点由 tick 把它叫起来。
//
//  ⚠️ 它**不是**一条新的定时任务（没有名字、没有 cron、不进任务列表）—— 它是**任务的**一次
//  体外唤醒。这个区分是刻意的：借 scheduled_tasks 造一条一次性任务会污染任务列表，而
//  "跑完就删"的行还带一个没人认领的日志会话；更要紧的是 cron 的语义是「周期性」，
//  一次性唤醒混进那张表之后，`refreshMissedFires` 会把"约过但没跑"算成漏跑。
//
//  ⚠️ **不占 P 号**（2026-10-22 boss 定的红线：「我们只截止到 P17，其他都是小功能，
//  不需要累加这个」）⇒ 全仓只有日期标记，没有 P20。
//

import Foundation

/// 一条 follow-up 的生命周期。
///
/// ⚠️ **不做 CHECK 约束**（同 `FindingStatus` / `agent_findings.status` 的理由，见
/// `PersistenceStore.migrate` 那段注释）：值域是产品语义，将来加一个状态若碰上 CHECK，
/// 已发版的老 App 打开新库会**写不进去**（P11 判据 ② 的对偶面）。越界的值由解码侧兜成
/// `nil` ⇒ 整行丢掉（不 fire、不上屏），而不是猜一个 `pending` 出来把过期的约定又叫一遍。
enum FollowUpStatus: String, Codable {
    /// 等着的。tick 扫它。
    case pending
    /// 已经叫过一轮了（**不是**"那件事做完了"—— 做没做完只有 agent 自己知道）。
    case fired
    /// 主动作废：任务被删 / 被停用。**留着行不删**，好让人回头看"这个助理约过什么"。
    case cancelled
    /// 到点了但试了几次都没起来（在途 / 并发满 / 超预算）。
    ///
    /// 与 `cancelled` 分开的理由：一个是"约定不该再存在"，一个是"约定还在、但没叫起来"。
    /// 合成一个值，人就分不清自己该去修什么。
    case missed

    /// 未知值 ⇒ `nil` ⇒ 调用方丢行。**别回落成 `pending`**：那是把一条本该被忽略的旧约定
    /// 重新叫起来（"猜一个"永远比"丢掉"更坏，同 `FindingStatus.decode`）。
    static func decode(_ raw: String) -> FollowUpStatus? { FollowUpStatus(rawValue: raw) }
}

/// 这条唤醒**是谁约的**。
///
/// 加上它的唯一原因是**配额口径**（P20 · 2026-11-24）：`followUpCountSince` 数的是"这个任务
/// 今天约了几条"，而 worker 交活回叫是 App 自己插的 —— 它要是也被算进去，一个带 5 个 worker 的
/// main 跑一天就把自己的回看配额耗光了，而人看到的是"我没约过这么多次"。
///
/// 第二个用处是时间线的分隔行：`回看 · 约的是…` 与 `回叫 · X 交活了` 是两件事，长得一样的话
/// 三个月后翻日志没人分得清（同 P15.9 给定向 fire 加标签那条理由）。
enum FollowUpKind: String, Codable {
    /// 模型自己通过 `follow_up` 工具约的。**占配额**。
    case selfWake = "self"
    /// worker 交活之后 App 插的那条（P20）。**不占配额**，也不受"未兑现 3 条"那道闸约束。
    case callBack = "call_back"

    /// 未知值回落 `selfWake` —— 宁可多算一次配额，也不要把一条来路不明的唤醒当成
    /// "App 自己插的"从而少算（少算的那一侧会让人设的上限悄悄失效）。
    static func decode(_ raw: String) -> FollowUpKind { FollowUpKind(rawValue: raw) ?? .selfWake }
}

/// 一条落库的约定。
struct FollowUp: Identifiable, Equatable {
    /// **由扩展侧生成**（`randomUUID`），不是 App 分配 —— 这样"同一个 spool 行被 ingest 两次"
    /// 会撞主键 ⇒ `INSERT OR IGNORE` 天然幂等（收口崩在插入与删文件之间时不会变成两条约定）。
    let id: UUID
    let taskId: UUID
    /// 到点时刻。**在 ingest 那一刻算**（`createdAt + after_minutes`），不是扩展侧算的 ——
    /// 理由见 `FollowUpSpool.parse` 上面那段（子进程的钟不可信，而且它拿不到 App 的 now）。
    var dueAt: Date
    /// 为什么约这一次（模型自己写的一句话）。**fire 时要原样交给它** ——
    /// 半夜三点被叫起来而不知道自己在等什么的 agent，只会重新采集一遍再重新判断一遍。
    var why: String
    var status: FollowUpStatus
    /// 起来失败了几次（见 `SchedulerService.fireDueFollowUps` 的重排规则）。
    var attempts: Int
    let createdAt: Date
    var firedAt: Date?
    /// 落库的人话原因（"任务已删除" / "并发已满 3 次"）。**恒中文**：它进时间线/日志，
    /// 与 `SchedulerService` 里那些落库文案同一条纪律（那个文件在 L10n 的 `EXCLUDE_FILES` 里）。
    var note: String?
    /// 谁约的（见 `FollowUpKind`）。缺省 `selfWake` ⇒ 既有构造点与老行都不变。
    var kind: FollowUpKind = .selfWake
}

/// 约定的边界 —— 三个数都是**产品判断**，不是实现细节。
///
/// · `minMinutes = 5`：比 5 分钟更短的约定没有意义。tick 是每分钟一次，而且一轮本身就要跑
///   几十秒到几分钟；约 1 分钟之后只会撞上"该任务回合在途"⇒ 白跳一次 + 一条 miss 记录。
/// · `maxMinutes = 7 天`：再远的"等一等"就不该用 follow-up 了 —— 那时候 cron 才是对的工具
///   （一次性的远期安排在 App 重启之后只有这张表记得，而它的读者是 tick，不是人）。
/// · `maxPendingPerTask = 3`：一个任务的**未兑现**约定上限。没有它，一轮焦虑的巡检可以约 20 个
///   时刻，此后每条 cron 都在"叫醒自己"里烧 token，而人看到的是账单。
enum FollowUpLimit {
    static let minMinutes = 5
    static let maxMinutes = 7 * 24 * 60
    static let maxPendingPerTask = 3
    /// `why` 的长度上限。它每一轮都会被原样拼进 prompt ⇒ 没有上限就是一个没有围栏的注入面。
    static let maxWhyChars = 240
    /// 起来失败后最多重试几次（每次顺延 `retryStepMinutes`）。三次之后判 `missed`。
    static let maxAttempts = 3
    static let retryStepMinutes = 5
}

// MARK: - spool 的解析口径

/// spool 文件的解析口径 —— **一处定义，扩展侧只写不解析**。
///
/// 形态：一条约定一行 JSON（JSONL）。与 `NoteProposalSpool` 同一套理由：扩展是**逐条追加**
/// 写的，而 spool 存在的意义正是"进程崩了也不丢已产出的部分"⇒ 逐行追加是它最便宜的实现。
///
/// ⚠️ **这里算不出 `dueAt`** —— 只有 `after_minutes`。扩展侧算不了真实时刻（它跑在子进程里，
/// 我们看不到它的钟，也不该信），所以"什么时候到点"由 App 在 ingest 那一刻定：`now + N 分钟`。
/// 代价 = 约定比模型说的时间**晚一个回合的尾巴**（几十秒到几分钟）；换来的是"到点时刻只有一个
/// 产生者"，不存在"模型算的钟和 App 的钟差 8 小时，于是约定排到明天早上"这种不可复现的 bug。
enum FollowUpSpool {

    /// 一行 = 一次请求。
    struct Request: Equatable {
        let id: UUID
        let afterMinutes: Int
        let why: String
    }

    /// 一行 = 「这件事结束了，别叫了」（2026-11-26）。
    ///
    /// 为什么与 `Request` 分开而不是加一个 `cancel: true` 字段：两者的**配额待遇完全不同** ——
    /// 约定吃「一轮一条 / 每天 N 条 / 未兑现 3 条」三道闸，作废一条都不吃（它不产生唤醒）。
    /// 塞进同一个结构，三道闸就得在里面再分叉一次，而那种 if 是这类 bug 的老家。
    ///
    /// `id` 照旧是幂等键（扩展侧生成）：收口崩在"落库都落完、文件还没删"之间时，
    /// 第二次 ingest 会重放这一行 —— 而作废的对象是 `pending` 集合，第二次已经是空集，
    /// **重复执行一次是安全的**（代价只有时间线上可能多一行，见 `finishFollowUpIfNeeded`）。
    struct Cancel: Equatable {
        let id: UUID
        /// 人原话 / 为什么结束了。落进那条约定的 `note`，三个月后回看时它是唯一线索。
        let why: String
    }

    /// 被拒的行。**带行号**：人（和日志）要能回到那一行去看模型到底写了什么。
    struct Rejection: Equatable {
        let line: Int
        let reason: String
    }

    /// 一批请求的解析结果。
    ///
    /// 单独成结构而不是三元组：`parse` 的两个老消费点（含冒烟里四处解构）都按
    /// `(items, rejects)` 取，改成三元组会**静默**改变它们的语义位置。
    struct Batch: Equatable {
        let items: [Request]
        let cancels: [Cancel]
        let rejects: [Rejection]
    }

    /// 逐行解析。空行不是错（尾部换行会造出一行），其余每一行要么产出、要么带行号被拒。
    ///
    /// 纯函数（不碰磁盘、不碰 DB、不读时钟）⇒ 冒烟可以直接喂字符串造反例，不需要真跑一轮。
    static func parse(_ text: String) -> (items: [Request], rejects: [Rejection]) {
        let batch = parseBatch(text)
        return (batch.items, batch.rejects)
    }

    /// 带「作废」的那一版。`op` 缺省 = `add` —— 老扩展写的行**没有这个字段**，
    /// 把它们判成"形状不对"会让已经在磁盘上的残留文件一次性全废。
    static func parseBatch(_ text: String) -> Batch {
        var items: [Request] = []
        var cancels: [Cancel] = []
        var rejects: [Rejection] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            do {
                switch try classify(line) {
                case .add(let r):    items.append(r)
                case .cancel(let c): cancels.append(c)
                }
            } catch let e as Reject {
                rejects.append(Rejection(line: i + 1, reason: e.reason))
            } catch {
                rejects.append(Rejection(line: i + 1, reason: "不是合法的 JSON"))
            }
        }
        return Batch(items: items, cancels: cancels, rejects: rejects)
    }

    private struct Reject: Error { let reason: String }

    private enum Line {
        case add(Request)
        case cancel(Cancel)
    }

    private static func classify(_ line: String) throws -> Line {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw Reject(reason: "不是合法的 JSON")
        }
        guard let dict = obj as? [String: Any] else {
            throw Reject(reason: "不是 JSON 对象")
        }
        switch (dict["op"] as? String) ?? "add" {
        case "add":    return .add(try parseLine(dict))
        case "cancel": return .cancel(try parseCancel(dict))
        default:       throw Reject(reason: "op 只认 add / cancel（拿到 \(dict["op"] ?? "nil")）")
        }
    }

    private static func parseCancel(_ dict: [String: Any]) throws -> Cancel {
        guard let rawId = (dict["id"] as? String)?.trimmingCharacters(in: .whitespaces),
              let id = UUID(uuidString: rawId) else {
            throw Reject(reason: "缺 id 或 id 不是 UUID")
        }
        var why = ((dict["why"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else {
            // 与约定那边同一条：作废也要留下"为什么"。没有理由的作废三个月后没人说得清
            // 是"用户说的"还是"它自己判断的"—— 而这两件事的可信度差着一整个量级。
            throw Reject(reason: "why 是空的")
        }
        if why.count > FollowUpLimit.maxWhyChars {
            why = String(why.prefix(FollowUpLimit.maxWhyChars)) + "…"
        }
        return Cancel(id: id, why: why)
    }

    private static func parseLine(_ dict: [String: Any]) throws -> Request {
        guard let rawId = (dict["id"] as? String)?.trimmingCharacters(in: .whitespaces),
              let id = UUID(uuidString: rawId) else {
            // id 由扩展侧生成、用来做幂等键。缺了就没法"插入两次只算一次" ⇒ 拒。
            throw Reject(reason: "缺 id 或 id 不是 UUID")
        }
        // ⚠️ `NSNumber` 会把 `3.5` 也当数字 ⇒ 先按 Int 取，取不到再判"是不是个非整数"。
        guard let num = dict["after_minutes"] as? NSNumber else {
            throw Reject(reason: "缺 after_minutes")
        }
        let minutes = num.intValue
        guard Double(minutes) == num.doubleValue else {
            throw Reject(reason: "after_minutes 必须是整数（拿到 \(num.doubleValue)）")
        }
        guard (FollowUpLimit.minMinutes...FollowUpLimit.maxMinutes).contains(minutes) else {
            throw Reject(reason: "after_minutes 要在 \(FollowUpLimit.minMinutes)…"
                         + "\(FollowUpLimit.maxMinutes) 之间（拿到 \(minutes)）")
        }
        var why = ((dict["why"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else {
            // `why` 不是装饰: fire 时它就是"你为什么要醒"的全部信息。
            // 空着放过去 = 半夜叫醒它，然后它重新判断一遍 —— 而那正是要避免的烧钱。
            throw Reject(reason: "why 是空的")
        }
        if why.count > FollowUpLimit.maxWhyChars {
            why = String(why.prefix(FollowUpLimit.maxWhyChars)) + "…"
        }
        return Request(id: id, afterMinutes: minutes, why: why)
    }
}
