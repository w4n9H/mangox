//
//  BashRiskEvaluator.swift
//  P3.10 审批分层: bash 只读白名单自动放行, 其余弹卡。
//  立场: 白名单放行 (漏 = 多弹一次卡, 失败模式是烦), 不做黑名单拦截 (漏 = 出事)。
//  覆盖所有会话: 判定挂在 transport 的审批桥 (handleExtensionUIRequest), 全局生效。
//

import Foundation

enum BashRiskEvaluator {

    enum Verdict { case allow, ask }

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

    /// 判定一条 bash 命令: 只读 → .allow (静默放行); 其余 → .ask (弹审批卡)。
    static func evaluate(command: String, learned: Set<String>) -> Verdict {
        // 重定向 = 写文件 (先剥 stderr/both 形式 2> &>, 避免误伤 2>/dev/null)
        let probe = command
            .replacingOccurrences(of: "2>", with: "")
            .replacingOccurrences(of: "&>", with: "")
        if probe.contains(">>")
            || probe.range(of: "(^|[^>])>", options: .regularExpression) != nil
            || probe.range(of: "\\btee\\b", options: .regularExpression) != nil {
            return .ask
        }
        // 组合命令切段 (&& || ; | &), 每段首命令都只读才整体放行
        let segments = splitSegments(command)
        for seg in segments {
            let tokens = seg.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let first = tokens.first.map(String.init), !first.isEmpty else { continue }
            if learned.contains(first) { continue }
            if first == "git" {
                guard tokens.count > 1, gitReadOnly.contains(String(tokens[1])) else { return .ask }
                continue
            }
            guard builtInReadOnly.contains(first) else { return .ask }
        }
        return .allow
    }

    /// 从命令提取各段首 token (供"始终允许"学习沉淀)。
    static func learnTokens(command: String) -> Set<String> {
        var out: Set<String> = []
        for seg in splitSegments(command) {
            let tokens = seg.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if let first = tokens.first.map(String.init), !first.isEmpty, first != "git" {
                out.insert(first)
            }
        }
        return out
    }

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
