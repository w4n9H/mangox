//
//  BashRiskEvaluator.swift
//  P3.10 审批分层: bash 只读白名单自动放行, 其余弹卡。
//  立场: 白名单放行 (漏 = 多弹一次卡, 失败模式是烦), 不做黑名单拦截 (漏 = 出事)。
//  覆盖所有会话: 判定挂在 transport 的审批桥 (handleExtensionUIRequest), 全局生效。
//  P10.2a-0: 补四类"命令名只读但参数可写/可执行"的误放行 (find/env/sort/curl·wget),
//  并返回裁决原因 (Risk) —— 无人值守档 (ApprovalMode.autoJudge) 靠它写回执。
//

import Foundation

enum BashRiskEvaluator {

    enum Verdict { case allow, ask }

    /// 转 .ask 的原因分类。用 enum + 中文文案, 不引 i18n 表: 消费点目前只有回执一处。
    enum Risk: String, CaseIterable {
        case unknownCommand   // 不在只读白名单
        case redirect         // 输出重定向 / tee
        case findAction       // find -exec/-ok/-delete/-fprint*
        case envExec          // env 后跟要执行的命令
        case sortOutput       // sort -o
        case netFetchWrite    // curl/wget 落盘或上传
        case gitWrite         // git 非只读子命令

        /// 回执文案 (「卡在: <label>」)。
        var label: String {
            switch self {
            case .unknownCommand: return "非只读命令"
            case .redirect:       return "写文件 (重定向)"
            case .findAction:     return "find 执行命令/改文件"
            case .envExec:        return "env 执行程序"
            case .sortOutput:     return "sort 写文件"
            case .netFetchWrite:  return "下载落盘/上传文件"
            case .gitWrite:       return "git 写操作"
            }
        }
    }

    /// 裁决结果。allow 时 risk = nil; ask 时必定带原因。
    struct Decision {
        let verdict: Verdict
        let risk: Risk?
        var isAllow: Bool { verdict == .allow }

        static let allow = Decision(verdict: .allow, risk: nil)
        static func ask(_ risk: Risk) -> Decision { Decision(verdict: .ask, risk: risk) }
    }

    /// 内置只读命令 (首 token); 学习白名单 (弹卡"始终允许"沉淀) 在此之上合并。
    static let builtInReadOnly: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "rg", "find", "pwd", "wc",
        "file", "which", "man", "du", "df", "ps", "curl", "wget", "date",
        "whoami", "uname", "hostname", "env", "printenv", "id", "stat",
        "sort", "uniq", "diff", "basename", "dirname", "realpath", "tree",
        "echo", "true", "false", "sleep", "printf",
    ]

    /// git 双词白名单: 首 token = git 时校验第二 token (git 可写仓库状态)。
    static let gitReadOnly: Set<String> = [
        "status", "log", "diff", "show", "branch", "remote", "tag",
    ]

    /// 判定一条 bash 命令并给出原因。
    static func judge(command: String, learned: Set<String>) -> Decision {
        let p = probe(command)
        if let risk = redirectRisk(p) { return .ask(risk) }
        // 组合命令切段 (&& || ; | &), 每段首命令都只读才整体放行。
        // 切段与 token 化都用探针串: 否则 `cmd 2>&1` 的 `&` 会被当成组合分隔符,
        // 切出假段 "1" 而被当成未知命令 (误弹卡)。
        for seg in splitSegments(p) {
            let tokens = seg.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let first = tokens.first, !first.isEmpty else { continue }
            if first == "git" {
                guard tokens.count > 1, gitReadOnly.contains(tokens[1]) else { return .ask(.gitWrite) }
                continue
            }
            guard builtInReadOnly.contains(first) || learned.contains(first) else {
                return .ask(.unknownCommand)
            }
            // 二次参数检查: 命令名可信 ≠ 这组参数只读 (find/env/sort/curl·wget)
            if let risk = argumentRisk(first: first, args: Array(tokens.dropFirst())) {
                return .ask(risk)
            }
        }
        return .allow
    }

    /// 兼容入口 (旧调用点): 只看裁决, 不看原因。
    static func evaluate(command: String, learned: Set<String>) -> Verdict {
        judge(command: command, learned: learned).verdict
    }

    /// 从命令提取各段首 token (供"始终允许"学习沉淀)。
    static func learnTokens(command: String) -> Set<String> {
        var out: Set<String> = []
        for seg in splitSegments(probe(command)) {
            let tokens = seg.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if let first = tokens.first.map(String.init), !first.isEmpty, first != "git" {
                out.insert(first)
            }
        }
        return out
    }

    // MARK: - 重定向

    /// 剥掉"不落盘"的输出写法 (`2>&1` / `1>&2` / 任意 `…>/dev/null`), 得到判定用探针串。
    /// 探针串同时用于切段 (见 judge): `2>&1` 的 `&` 不能被当成组合分隔符。
    private static func probe(_ command: String) -> String {
        command
            .replacingOccurrences(of: "2>&1", with: "")   // stderr 并入 stdout: 不落盘
            .replacingOccurrences(of: "1>&2", with: "")   // stdout 并入 stderr: 不落盘
            .replacingOccurrences(of: "[12&]?&?>\\s*/dev/null", with: "", options: .regularExpression)
    }

    /// 探针串仍有 `>` `>>` 或 tee = 写文件。
    /// 注意: 早期实现整段剥 `2>` 与 `&>`, 连带把 `ls 2>err.txt` / `cat f &> out` 也放行了 —— 属误放行, 此处修正。
    private static func redirectRisk(_ probe: String) -> Risk? {
        if probe.contains(">>")
            || probe.range(of: "(^|[^>])>", options: .regularExpression) != nil
            || probe.range(of: "\\btee\\b", options: .regularExpression) != nil {
            return .redirect
        }
        return nil
    }

    // MARK: - 二次参数检查 (P10.2a-0)

    /// 命令名在只读表内, 但某些参数会把它变成写/执行 —— 命中即转 .ask。
    /// 只覆盖四个已知洞; 其余命令名默认信任其白名单语义 (漏 = 多弹卡, 不做出事方向)。
    private static func argumentRisk(first: String, args: [String]) -> Risk? {
        switch first {
        case "find":
            // -exec/-execdir/-ok/-okdir 执行任意命令; -delete 删文件; -fprint/-fprintf 写文件
            for a in args {
                if a == "-exec" || a == "-execdir" || a == "-ok" || a == "-okdir" || a == "-delete" {
                    return .findAction
                }
                if a.hasPrefix("-fprint") { return .findAction }
            }
        case "env":
            // `env <cmd>` = 换环境跑任意程序。只认选项与 KEY=VAL, 其余首个 token 即命令。
            for a in args where !a.hasPrefix("-") && !isAssignment(a) { return .envExec }
        case "sort":
            // -o <file> / --output[=]<file> (含短选项簇 -ro)
            for a in args where a.hasPrefix("--output") || shortCluster(a, contains: "o") {
                return .sortOutput
            }
        case "curl", "wget":
            // 落盘 (-o) / 按远名存 (-O/--remote-name) / 上传 (-T/--upload-file) / 读文件当请求体 (--post-file)
            for a in args {
                if a == "-o" || a == "-O" || a == "-T"
                    || a.hasPrefix("--output") || a.hasPrefix("--remote-name")
                    || a.hasPrefix("--upload-file") || a.hasPrefix("--post-file") {
                    return .netFetchWrite
                }
                if shortCluster(a, contains: "o") || shortCluster(a, contains: "O")
                    || shortCluster(a, contains: "T") {
                    return .netFetchWrite
                }
            }
        default:
            break
        }
        return nil
    }

    /// `KEY=VAL` 形态 (env 的变量前缀)。
    private static func isAssignment(_ token: String) -> Bool {
        token.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
    }

    /// 短选项簇 (curl 的 `-sSL` / sort 的 `-ro`) 是否含目标字母 (区分大小写)。
    /// 只看单破折号开头的 token; `--long` 与裸 `-` 不算。
    private static func shortCluster(_ token: String, contains ch: Character) -> Bool {
        guard token.hasPrefix("-"), !token.hasPrefix("--") else { return false }
        return token.dropFirst().contains(ch)
    }

    // MARK: - 切段

    private static func splitSegments(_ command: String) -> [String] {
        // NSRegularExpression: 兼容目标 Swift 版本 (Regex literals 依赖较新 runtime)
        guard let re = try? NSRegularExpression(pattern: "&&|\\|\\||[;|&]") else { return [command] }
        let ns = command as NSString
        var parts: [String] = []
        var start = 0
        for m in re.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > start { parts.append(ns.substring(with: NSRange(location: start, length: m.range.location - start))) }
            start = m.range.location + m.range.length
        }
        if start < ns.length { parts.append(ns.substring(from: start)) }
        return parts
    }
}
