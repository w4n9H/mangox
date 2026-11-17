//
//  WatchExecService.swift
//  P19 执行段（S6）：快照 → 红线/围栏 → 废纸篓 → 落痕 → 跑偏即停 → 回滚。
//  设计见 docs/P19 §03「授权与执行」/ §04 表结构。
//
//  四条不变量（每条都能被反例打红）：
//    ① **没有快照就不许写** —— `undo_path` 为空 ⇒ 拒（人得有回滚的底气才敢点下一次授权）；
//    ② **已经在跑 / 已解决的不许再跑** —— 写动作跑两遍 = 双倍破坏，且第二遍没有快照保护；
//    ③ **跑偏即停** —— 动作对不上已授权步骤号 ⇒ 记 `drift`、中止，不落 `resolved`；
//    ④ **删不删文件由人决定，怎么删由我们决定** —— 一律走废纸篓，不走 `rm`。
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
    @discardableResult
    static func snapshot(findingId: UUID, projectPath: String, relativePaths: [String]) throws -> String {
        let dir = undoDir(findingId: findingId)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let archive = dir + "/snapshot.tar.gz"
        var args = ["-czf", archive, "-C", projectPath]
        args += relativePaths.isEmpty ? ["."] : relativePaths
        let r = try run("/usr/bin/tar", args)
        guard r == 0, FileManager.default.fileExists(atPath: archive) else {
            throw WatchSourceError.failed("快照失败（tar 退出码 \(r)）")
        }
        try? projectPath.write(toFile: dir + "/project.txt", atomically: true, encoding: .utf8)
        return dir
    }

    /// 从快照还原。**不用 `--overwrite` 之外的任何"合并"策略**: 还原就是还原，
    /// 合并会让"回滚"变成"再改一次"。
    @discardableResult
    static func restore(findingId: UUID) throws -> Bool {
        let dir = undoDir(findingId: findingId)
        let archive = dir + "/snapshot.tar.gz"
        guard FileManager.default.fileExists(atPath: archive) else { return false }
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

    // MARK: - 跑偏判定（纯函数）

    /// 一个动作算不算"跑偏"。
    ///
    /// 判据只有一条: **它必须对应一个已授权的步骤号**。对不上 ⇒ drift。
    /// 为什么不是"看它改了什么": 改什么是执行时才知道的，而"是否在授权范围内"必须在
    /// 动作**发生前**就能答 —— 事后比对只能做事后追责。
    ///
    /// ⚠️ 实现只有一处：`ExecGate.driftReason`（审批桥用的是同一份）。这里只是给"要不要中止"
    /// 这个问题一个布尔回答 —— 两处各写一遍判据，迟早有一处把"没声明步骤"算成放行。
    static func isDrift(step: Int?, authorized: [Int]) -> Bool {
        ExecGate.driftReason(declared: step, authorized: authorized) != nil
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
        if let projectPath { parts.append("【写入范围】\n只允许写 \(projectPath) 之内；此外一律拒。") }
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
