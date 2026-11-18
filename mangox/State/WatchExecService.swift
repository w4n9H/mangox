//
//  WatchExecService.swift
//  P19 执行段（S6）：前置 guard → 快照 → 执行轮 → 落痕 → 跑偏即停 → 回滚。
//  （2026-11-18 review 把标题里的「围栏 / 废纸篓」删了：围栏整层在 P19.5 撤掉，
//   废纸篓不在本文件兑现 —— 详见下面 ④。标题是这一屏最先读到的东西，不该骗人。）
//  设计见 docs/P19 §03「授权与执行」/ §04 表结构。
//
//  四条不变量（①②③ 各有一条反例能打红；④ 的落点不在本文件，见下）：
//    ① **没有快照就不许写** —— 快照在**起手那一刻**做，做不出来就中止（退回 `open`、
//       时间线留一句"快照失败，没有开始执行"），执行轮根本不会起
//       ⇒ 轮次开始后手上必定有一份快照。**不是**判 `undo_path` 非空：那一条恒假，
//       第一次执行前它本来就是空的。（落点：`SchedulerService.startExecution` 的 catch 分支）
//    ② **已经在跑 / 已解决的不许再跑** —— 写动作跑两遍 = 双倍破坏，且第二遍没有快照保护；
//    ③ **跑偏即停** —— 动作对不上已授权步骤号 ⇒ 记 `drift`、中止，不落 `resolved`；
//    ④ **删不删文件由人决定，怎么删不归模型决定** —— 但**这条不在本文件兑现**：
//       本文件只做快照/还原，一个字节都不删。真正的两道落点是
//       `ComputerRedline`（永久删除那一步直接拒，只放行「移到废纸篓」）与
//       `KnowledgeStore.deleteNote`（`trashItem` + 留 `note_revisions`）。
//       （2026-11-18 review 之前这里写的是"一律走废纸篓"，读起来像本文件在拦，
//        而本文件里没有任何一行能兑现它 —— 假承诺比没承诺更坏。）
//
//  ⚠️ 这个类型**不持有 ChatStore**（同来源 / 结论那两个）: 执行是"人对 finding 点了采纳"之后
//  的事，任何东西都不该能从这里反向去 fire 一轮。
//

import Foundation

enum WatchExecService {

    /// 快照保留 7 天（§03 L3）。
    static let undoRetentionDays = 7

    /// 快照根。**冒烟必须能重定向**（`undoRootOverride`）—— 与 `agentRootOverride` /
    /// `attachmentsRootOverride` 同一条纪律: 取根的方式做成可换的，否则冒烟会往真实的
    /// `~/.mangox/undo/` 里写 tar，而"净增 0"那类判据只看夹具目录 ⇒ **假绿**（实测漏过一次）。
    static var undoRootOverride: String?
    static var undoRoot: String { undoRootOverride ?? (NSHomeDirectory() + "/.mangox/undo") }

    /// 快照根: `<undoRoot>/<findingId>/`。
    static func undoDir(findingId: UUID) -> String {
        undoRoot + "/" + findingId.uuidString
    }

    // MARK: - 执行前 guard（纯函数：判据打在它上面）

    /// 能不能开始执行。nil = 可以。
    static func blockReason(finding: AgentFinding) -> String? {
        if finding.status.blocksExecution {
            return finding.status == .running ? "这一条正在执行中" : "这一条已经解决了"
        }
        if finding.status == .authorized {
            // authorized = 人点了采纳但还没起手（快照还没做）⇒ 可以开始
        } else if finding.status != .open {
            return "状态是 \(finding.status.rawValue)，不能执行"
        }
        if finding.plan.isEmpty { return "这条结论没有方案步骤，没有可执行的东西" }
        return nil
    }

    // MARK: - 快照 / 回滚

    /// 执行前快照。**起手就做，而且失败即中止** —— 快照做不出来还往下走，
    /// 等于把"可回滚"这句承诺变成空话。
    ///
    /// 用 `tar` 而不是逐文件复制: 目录级别的目标（"改这个目录"）用复制要处理符号链接、
    /// 权限位与硬链接，而 tar 本来就是干这个的。
    ///
    /// ⚠️ 顺手写一份 `project.txt`：**"还原到哪"必须与"从哪打的包"同源**。用任务表的
    /// `projectId` 反推的话，人改过项目目录之后再点回滚，tar 会把三个文件解到另一个地方
    /// —— 那是最坏的一种失败：它成功了，而且看起来像回滚了。
    /// ⚠️ **每份快照一个新文件名，绝不覆盖**（2026-11-18 review 修）。
    ///
    /// 原来这里恒写 `<dir>/snapshot.tar.gz`，而 `tar -czf` 是同名覆盖、`blocksExecution`
    /// 又只挡 `running`/`resolved`（`failed` / `open` 可以再执行）。于是这个序列是真实的：
    /// ① 第一次执行前快照 A（**未被污染的原始状态**）→ 跑一半失败，状态 `failed`；
    /// ② 人再点「采纳并执行」→ 快照 B **盖掉 A**，而此刻项目已经被①改过；
    /// ③ 从此「回滚」只能回到"半个破坏之后"，原始状态**永久没了**，而界面上照样写着
    ///    「已回滚」。四步里没有任何一步会报错 —— 这是本次 review 里唯一不可逆的一条。
    ///
    /// 编号从 1 起，`restore` 取**编号最大**的那份（= 最近一次执行前）。
    /// 老的 `snapshot.tar.gz`（无编号）按 0 处理 ⇒ 升级前留下的快照照样能用。
    @discardableResult
    static func snapshot(findingId: UUID, projectPath: String, relativePaths: [String]) throws -> String {
        let dir = undoDir(findingId: findingId)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let archive = nextArchivePath(in: dir)
        var args = ["-czf", archive, "-C", projectPath]
        args += relativePaths.isEmpty ? ["."] : relativePaths
        let r = try run("/usr/bin/tar", args)
        guard r == 0, FileManager.default.fileExists(atPath: archive) else {
            throw WatchSourceError.failed("快照失败（tar 退出码 \(r)）")
        }
        try? projectPath.write(toFile: dir + "/project.txt", atomically: true, encoding: .utf8)
        // 同一件事被反复执行不该把盘堆满（每次一份**全量** tar）。
        pruneOldArchives(in: dir)
        return dir
    }

    /// 同一 finding 最多留几份快照（不含 1 号）。
    ///
    /// 为什么必须有一条上限: "不覆盖"解决了数据丢失，代价是**每次执行多一份全量 tar** ——
    /// 一个几十 MB 的项目被点十次就是几百 MB，而人只会觉得"磁盘莫名少了空间"。
    /// 为什么 1 号**永不删**: 它是**第一次执行前**的状态，也就是"这一切都还没发生"的那一份；
    /// 中间那几份只是历史，删掉不影响任何承诺，而删掉 1 号等于把原始状态又弄丢一次。
    static let archiveKeepRecent = 4

    /// 只保留 1 号 + 最近 `archiveKeepRecent` 份。**纯按编号**，不看时间 ——
    /// 编号就是执行顺序，而 mtime 会被 `tar` 自己刷新，靠它排序是在猜。
    @discardableResult
    static func pruneOldArchives(in dir: String,
                                 keepRecent: Int = archiveKeepRecent) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let numbered = names.compactMap { n in archiveNumber(n).map { ($0, n) } }
            .sorted { $0.0 > $1.0 }                       // 新 → 旧
        guard numbered.count > keepRecent + 1 else { return [] }
        // 保留: 前 keepRecent 个 + 最小的那个（1 号，或升级前遗留的 0 号）。
        let keep = Set(numbered.prefix(keepRecent).map(\.0) + [numbered[numbered.count - 1].0])
        var removed: [String] = []
        for (n, name) in numbered where !keep.contains(n) {
            if (try? FileManager.default.removeItem(atPath: dir + "/" + name)) != nil {
                removed.append(name)
            }
        }
        return removed
    }

    /// 归档文件的命名规矩 —— **一处定义**（写与读各拼一遍的话，改名那天就是"回滚不了"）。
    static let archivePrefix = "snapshot-"
    static let archiveSuffix = ".tar.gz"
    /// 升级前的固定名（无编号 = 0 号）。
    static let legacyArchiveName = "snapshot.tar.gz"

    /// 下一份归档的路径：已有编号取 max + 1。**不返回已存在的路径** —— 这是"不覆盖"的全部实现。
    static func nextArchivePath(in dir: String) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let nums = names.compactMap { archiveNumber($0) }
        return dir + "/" + archivePrefix + "\((nums.max() ?? 0) + 1)" + archiveSuffix
    }

    /// 文件名 → 编号。不认的一律 nil（别把 `project.txt` 当快照）。
    static func archiveNumber(_ name: String) -> Int? {
        if name == legacyArchiveName { return 0 }
        guard name.hasPrefix(archivePrefix), name.hasSuffix(archiveSuffix) else { return nil }
        let core = name.dropFirst(archivePrefix.count).dropLast(archiveSuffix.count)
        return Int(core)
    }

    /// 该还原哪一份：编号最大的（最近一次执行前）。没有快照 ⇒ nil。
    static func latestArchivePath(in dir: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let best = names.compactMap { n in archiveNumber(n).map { ($0, n) } }.max { $0.0 < $1.0 }
        return best.map { dir + "/" + $0.1 }
    }

    /// 从快照还原。**不用 `--overwrite` 之外的任何"合并"策略**: 还原就是还原，
    /// 合并会让"回滚"变成"再改一次"。
    @discardableResult
    static func restore(findingId: UUID) throws -> Bool {
        let dir = undoDir(findingId: findingId)
        guard let archive = latestArchivePath(in: dir) else { return false }
        // 没有 project.txt = 快照不完整（老版本 / 半截写盘）⇒ 不猜，直接当"回滚不了"。
        guard let project = try? String(contentsOfFile: dir + "/project.txt", encoding: .utf8),
              !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let r = try run("/usr/bin/tar", ["-xzf", archive, "-C",
                                         project.trimmingCharacters(in: .whitespacesAndNewlines)])
        return r == 0
    }

    /// 过期快照清理（7 天）。返回删掉的目录数。
    @discardableResult
    static func purgeExpired(now: Date = Date()) -> Int {
        let root = undoRoot
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return 0 }
        var removed = 0
        for name in names {
            let p = root + "/" + name
            let mtime = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate]) as? Date
            if let mtime, now.timeIntervalSince(mtime) > Double(undoRetentionDays) * 86400 {
                if (try? FileManager.default.removeItem(atPath: p)) != nil { removed += 1 }
            }
        }
        return removed
    }

    /// 跑一个外部命令，只回退出码。**只用于我们自己发起的 tar** —— 用户动作一律经模型工具，
    /// 不在这里拼命令（在这里拼 = 又造了一个执行面，红线管不到它）。
    private static func run(_ launch: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - 收尾解析（纯函数）

    /// 执行轮的收尾判定。
    enum Verdict: String, Equatable {
        case done
        case failed
        /// 模型没按收尾格式说话（或回合被停）。**不算成功** —— 无法证明的事按失败记。
        case unclear
    }

    struct ExecResult: Equatable {
        var verdict: Verdict
        var summary: String
    }

    /// 解析执行轮的收尾段。
    ///
    /// 契约是 `RESULT: DONE|FAILED` + `SUMMARY: 一句话`。**只认这两行**，不从正文里猜
    /// "听起来像做完了" —— 猜出来的成功会把一条没解决的结论标成 resolved，而 resolved
    /// 是下一轮巡检的事实来源（§03「结果回写」）⇒ 错的不是一行状态，是下一轮的判断。
    static func parseResult(_ text: String) -> ExecResult {
        var verdict: Verdict = .unclear
        var summary = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("RESULT:") {
                let v = upper.dropFirst("RESULT:".count).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("DONE") || v.hasPrefix("RESOLVED") { verdict = .done }
                else if v.hasPrefix("FAILED") || v.hasPrefix("BLOCKED") { verdict = .failed }
            } else if upper.hasPrefix("SUMMARY:") {
                summary = String(line.dropFirst("SUMMARY:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ExecResult(verdict: verdict, summary: summary)
    }

    /// 执行轮的系统段：把"你能做什么、做到哪、不能碰什么"一次说清。
    /// **不是给模型看的说明书，是给审批卡看的上下文** —— 人点批准时要知道这是第几步。
    static func executionSystemPrompt(finding: AgentFinding, authorizedSteps: [Int],
                                      projectPath: String?) -> String {
        var parts: [String] = ["""
        【助理任务 · 执行轮】
        人已经批准了这条结论的方案。你**只能**做下面列出的步骤，一步都不要多做。
        每做一步之前，先在正文里写一行「第 N 步」；对不上步骤号的动作会被拒绝并记成跑偏。
        红线动作（删除根目录 / 凭据目录 / 系统目录 / 强推 / 支付）**不会**弹审批卡，直接拒。
        做不到就停下来把原因写清楚 —— 不要用别的方式绕过同一步。
        """ ]
        parts.append("【结论】\n\(finding.title)")
        if let ev = finding.evidence, !ev.isEmpty { parts.append("【证据】\n\(ev)") }
        parts.append("【已授权的步骤】\n" + finding.plan
            .map { "\($0.n). \($0.text)" }
            .joined(separator: "\n"))
        // 2026-11-18: 这里原来写的是「只允许写 <项目> 之内；此外一律拒」。围栏撤掉之后
        // 那句话是假话 —— 它会照着"我不能写外面"去自我审查, 而代码已经放行了。
        if let projectPath { parts.append("【工作目录】\n\(projectPath)") }
        parts.append("【已授权步骤号】\(authorizedSteps.map(String.init).joined(separator: ","))")
        // 收尾格式是**机器接口**，与巡检轮的四段同性质：解析器只认这两行，
        // 写得再漂亮但没有 RESULT 的回合会被记成 failed（"无法证明"按失败算）。
        parts.append("""
        【收尾格式】
        做完之后单独写一节，只要这两行（不要加别的）：
        RESULT: DONE
        SUMMARY: 一句话说实际做了什么 / 卡在哪

        没做成或中途停下就写 RESULT: FAILED。
        """)
        return parts.joined(separator: "\n\n")
    }
}
