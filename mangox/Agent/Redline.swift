//
//  Redline.swift
//  P19 执行段的**硬约束**：红线恒拒 + 步骤围栏。设计见 docs/P19 §03「授权与执行」。
//
//  为什么是纯函数：红线的全部价值在"它真的拦住了"。拦不住的两种写法都很常见 ——
//  写在执行路径深处（没人测得动）与写在提示词里（模型不听就没了）。所以判定单独成函数，
//  入参只有"要干什么"，出参只有"准不准 + 为什么"，判据直接打在它上面。
//
//  ⚠️ 这里还剩**两条**，而且它们管的是两件不同的事：
//    · 红线 = 任何档位、任何授权都不放行（`rm -rf /`、凭据目录、系统目录、危险命令）；
//    · 步骤围栏 = 动作必须落在**人批过的那几步**里（没声明「第 N 步」= 证明不了 ⇒ 拒）。
//
//  ⚠️ 2026-11-18 删掉了第三条第「写范围围栏」（只能写任务项目目录内）。理由见
//     `denyReason(forWrite:)` 的注释：助理后续跑在同一台专属机器上，"项目外"不成立。
//     删掉之后**红线与步骤围栏一个字都没放宽** —— 别为了补洞把它们一起改了。
//

import Foundation

enum Redline {

    /// 恒拒的系统目录（写入目标）。
    static let systemRoots: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/Library/LaunchDaemons",
        "/Library/LaunchAgents", "/private/var/db",
    ]

    /// 恒拒的凭据目录（读写都不许）。
    static let credentialPaths: [String] = [
        ".ssh", ".aws", ".gnupg", ".config/gh", ".docker/config.json", ".netrc", ".kube",
    ]

    /// 恒拒的命令片段（小写比较）。**宁可多拦**：这些词出现在命令行里本身就说明意图。
    static let deniedCommandFragments: [String] = [
        "rm -rf /", "rm -fr /", "rm -rf ~", "rm -fr ~", "rm -rf ~/", "rm -rf $home",
        "sudo ", "sudo\t", "csrutil", "mkfs", "diskutil erase", "diskutil apfs delete",
        "shutdown", "reboot", "halt -", "launchctl unload /system",
        "git push --force", "git push -f", "git push --delete", "git push origin :",
        ":(){ :|:& };:",                      // fork bomb
    ]

    /// 凭据文件的**读**也不算"只读": 读出来就等于泄露（凭据会被写进日志 / 会话）。
    /// 这一条比"写"更严 —— 但它只影响 `checkRead`，不影响普通 read 工具的放行。
    static func isCredentialPath(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return credentialPaths.contains { expanded.contains("/" + $0) || expanded.hasSuffix($0) }
            || expanded.hasSuffix("/.env")
    }

    /// 命令红线。返回 nil = 放行；返回字符串 = 拒（理由进 `agent_finding_actions.result`）。
    static func denyReason(forCommand cmd: String) -> String? {
        let lowered = cmd.lowercased()
        // 折叠空白后再比: `rm  -rf   /` 与 `rm -rf /` 是同一件事
        let collapsed = lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for frag in deniedCommandFragments where collapsed.contains(frag) {
            return "红线：命令命中了禁止项「\(frag.trimmingCharacters(in: .whitespaces))」"
        }
        // 通配删工作区外: `rm -rf /*`、`rm -rf ..`、`rm -rf $HOME/...`
        if collapsed.hasPrefix("rm ") {
            let args = collapsed.split(separator: " ").dropFirst()
            let recursive = args.contains { $0.hasPrefix("-") && ($0.contains("r") || $0.contains("R")) }
            if recursive {
                for a in args where !a.hasPrefix("-") {
                    if a == "/" || a == "/*" || a == "~" || a.hasPrefix("~/") || a == "$home"
                        || a.hasPrefix("/users/") && a.split(separator: "/").count <= 2
                        || a == ".." || a.hasSuffix("/..") {
                        return "红线：递归删除工作区外的路径「\(a)」"
                    }
                }
            }
        }
        if isCredentialPath(collapsed) {
            return "红线：命令触碰凭据目录"
        }
        return nil
    }

    /// 命令里 `>` / `>>` 的重定向目标。
    ///
    /// 为什么要单列：`echo x > /etc/hosts` 一个红线词都不含 —— 命令片段判据只看"词"，
    /// 看不见"往哪写"。重定向是 bash 里**最主要的写盘方式**，漏掉它就等于"围栏只管 write 工具"，
    /// 而执行轮的能力是全给的（§03）。
    ///
    /// 取法刻意朴素：按 token 走，只认独立出现的 `>` / `>>` / `N>` / `N>>`。
    /// 不解析引号与 heredoc —— 宁可在少数写法上漏，也不要把这套判据写成半个 shell 解析器
    /// （半个解析器比没有更容易让人误以为它可靠）。
    static func redirectTargets(in command: String) -> [String] {
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var out: [String] = []
        var expectTarget = false
        for tok in tokens {
            if expectTarget {
                expectTarget = false
                // `2>&1` 这类是**复制描述符**，不是文件目标
                if !tok.hasPrefix("&") { out.append(tok) }
                continue
            }
            // 纯重定向符: 目标在下一个 token
            if tok == ">" || tok == ">>" || tok == ">|" { expectTarget = true; continue }
            guard tok.contains(">") else { continue }
            // `2>` / `2>>` / `>file` / `2>file`：剥掉前导数字后必须以 `>` 开头
            // （`a>b` 那种不是重定向，认它会误伤，也会漏掉真正的目标）
            var head = tok
            while let f = head.first, f.isNumber { head.removeFirst() }
            guard head.hasPrefix(">") else { continue }
            let rest = String(head.drop(while: { $0 == ">" }))
            if rest.isEmpty { expectTarget = true }       // `2>`：目标在下个 token
            else if rest.hasPrefix("&") { continue }      // `>&1`：复制描述符
            else { out.append(rest) }                     // `>out.log`：紧贴写
        }
        return out
    }

    /// 命令红线 + 写重定向围栏（`projectPath` = 执行轮的写入边界）。
    static func denyReason(forCommand cmd: String, projectPath: String?) -> String? {
        if let reason = denyReason(forCommand: cmd) { return reason }
        for target in redirectTargets(in: cmd) {
            if let reason = denyReason(forWrite: target, projectPath: projectPath) {
                return "命令要写「\(target)」⇒ " + reason
            }
        }
        return nil
    }

    /// 写入红线。`projectPath` 现在**只当相对路径的基准**用（执行轮的 cwd）。
    ///
    /// ⚠️ 2026-11-18 删掉了「围栏」那一条（"只许写项目目录内，否则拒"）：助理后续跑在
    /// **独立的 Mac 主机**上，那台机器整个就是给它用的，"项目外"这个说法在那里不成立。
    /// 留下的是**红线**——凭据目录、系统目录、危险命令，这些与"在哪台机器上"无关。
    /// 两级边界改在**人**这一侧：方案级（采纳并执行）+ 重要操作级（写进方案等人批）。
    static func denyReason(forWrite path: String, projectPath: String?) -> String? {
        let proj = projectPath.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        // 相对路径按**项目根**解（执行轮的 cwd 就是项目根）。不解的话 `> out.txt` 会被判成
        // 一个不存在的位置，表现是"正常写法莫名全被拒"。
        let abs = absolutePath(path, base: proj)
        if isCredentialPath(abs) { return "红线：凭据目录不许写" }
        for root in systemRoots where abs == root || abs.hasPrefix(root + "/") {
            return "红线：系统目录不许写（\(root)）"
        }
        return nil
    }

    /// 绝对化。**不碰磁盘**：`..` 按字面消掉，不解析符号链接。
    /// 判据要回答的是"它指向哪"，而这件事必须与"磁盘上现在是什么"脱钩 —— 否则同一份
    /// 方案在符号链接换掉之后会给出不同答案，而快照里存的是当时那个。
    static func absolutePath(_ path: String, base: String?) -> String {
        var p = path
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        guard !p.hasPrefix("/") else { return URL(fileURLWithPath: p).standardized.path }
        guard let base else { return p }
        return URL(fileURLWithPath: base).appendingPathComponent(p).standardized.path
    }
}

/// 执行回合的守卫参数 —— per-turn 下发给 transport，审批桥据此在**弹卡之前**先过红线。
struct ExecutionGuard: Equatable {
    /// 任务绑定的项目目录。**围栏删掉之后它只剩一个用途**: 相对路径的基准
    /// （执行轮的 cwd 就是项目根，`> out.txt` 要解到这儿）。
    let projectPath: String?
    /// 已授权的步骤号。动作对不上就记 drift 并中止。
    let allowedSteps: [Int]
    /// 正在执行的 finding（`agent_finding_actions` 的主键外键）。
    let findingId: UUID

    func denyReason(forCommand cmd: String) -> String? {
        Redline.denyReason(forCommand: cmd, projectPath: projectPath)
    }
}

// MARK: - 执行轮的门（纯函数，判据直接打在这里）

/// 一次**要审批的动作**在执行轮该不该被直接拒 —— 与档位、与"用户点过允许"无关。
///
/// 为什么单独成一个类型而不是并进审批桥的 if 里：这是 §03 三层约束里唯一一条
/// **没有可回滚机会**的判据（动作真的发生了，快照也救不回来"已经删掉的东西"）。
/// 写在 `handleExtensionUIRequest` 深处的话，能验证它的只有"真跑一次 `rm -rf`"——
/// 那种判据没人会写第二次。所以判定只入参与出参，纯函数，冒烟直测。
enum ExecGate {

    enum Kind: String, Equatable {
        /// 红线：任何档位、任何授权都不放行。
        case redline
        /// 跑偏：动作对不上已授权的步骤号。
        case drift
    }

    struct Denial: Equatable {
        let kind: Kind
        let reason: String
    }

    /// 入参就是"要干什么"：工具名、目标（bash 是命令原文，write/edit 是路径）、
    /// 以及模型在正文里声明到第几步（nil = 没声明）。
    static func check(guard g: ExecutionGuard, tool: String, target: String,
                      declaredStep: Int?) -> Denial? {
        // ① 红线 / 围栏：写在工具差异之前 —— 它们与"是哪个工具"无关
        //    两者的区别**只影响落痕的措辞**（拒不拒由有没有理由决定）：`Redline` 的理由串
        //    以「红线：」/「围栏：」开头，这里按前缀归一次类，不去解析句子。
        func denial(_ reason: String) -> Denial {
            // 2026-11-18: 只剩红线这一类（"围栏"整条删了 — 见 `denyReason(forWrite:)`）。
            Denial(kind: .redline, reason: reason)
        }
        if tool == "bash" {
            if let reason = Redline.denyReason(forCommand: target, projectPath: g.projectPath) {
                return denial(reason)
            }
        } else if tool == "write" || tool == "edit" || tool == "multiedit" || tool == "patch" {
            if let reason = Redline.denyReason(forWrite: target, projectPath: g.projectPath) {
                return denial(reason)
            }
        }
        // ② 步骤围栏：**所有**要审批的动作都要落在已授权步骤里（computer / MCP 也一样）。
        //    没声明步骤 = 无法证明在授权内 ⇒ 拒（§03 L1.5）。
        //    为什么不看"它改了什么"：改什么是执行时才知道的，而"是否在授权范围内"必须在
        //    动作**发生前**就能答 —— 事后比对只能做事后追责。
        if let reason = driftReason(declared: declaredStep, authorized: g.allowedSteps) {
            return Denial(kind: .drift, reason: reason)
        }
        return nil
    }

    /// 跑偏判据。抽出来是因为"没报步骤号"这一半最容易被写成放行（`guard let` 一句话就漏了）。
    static func driftReason(declared: Int?, authorized: [Int]) -> String? {
        guard let declared else {
            return "跑偏：正文里没写「第 N 步」⇒ 这个动作证明不了在已授权范围里"
        }
        guard authorized.contains(declared) else {
            let list = authorized.map(String.init).joined(separator: ",")
            return "跑偏：动作声明在第 \(declared) 步，已授权的是第 \(list) 步"
        }
        return nil
    }

    /// 从模型正文里取**最新**的「第 N 步」声明（没有 = nil）。
    ///
    /// 手写扫描而不是正则：它跑在流式文本上（每个 delta 一次），而 `NA`/正则的编译开销
    /// 与"要匹配的东西只有这一种形状"不相称；顺带也不依赖 `Regex` 的最低系统版本。
    /// ⚠️ 只认阿拉伯数字。模型偶尔写成「第一步」—— 那种就当没声明（拒），
    /// 因为"猜它写的中文数字是第几"这件事本身就是错的开始。
    static func declaredStep(in text: String) -> Int? {
        var best: Int?
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "第" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            var digits = ""
            while j < chars.count, chars[j].isNumber, digits.count < 3 { digits.append(chars[j]); j += 1 }
            while j < chars.count, chars[j] == " " { j += 1 }
            if !digits.isEmpty, j < chars.count, chars[j] == "步", let n = Int(digits) { best = n }
            i = j
        }
        return best
    }
}

/// 执行轮里一次**过闸**的落痕（`agent_finding_actions` 的一行）。
struct ExecAction: Equatable {
    var step: Int            // 0 = 正文里没声明步骤号
    var kind: String         // bash / write / edit / computer_* / …
    var target: String?      // 命令或路径（截断；**不存全文** —— 命令里可能带凭据）
    var result: String       // allowed / denied_by_redline / drifted
    var count: Int = 1
}
