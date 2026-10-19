//
//  SmokeFakes.swift —— 冒烟专用假实现（2026-10-19 从 smokeMain.swift 拆出）
//

import Foundation

/// T-MIME (P10.2c): 假 curl runner —— 记录每次调用的 argv 与 stdin, 按脚本回放退出码/输出。
/// 让 CurlMailTransport 的整条链 (argv 组装 → 输出解析 → 错误归类) 可在不连真网的前提下断言。
final class FakeCurlRunner: CurlRunner, @unchecked Sendable {
    struct Call: Sendable {
        var arguments: [String]
        var stdin: Data?
    }

    var calls: [Call] = []
    var responses: [(exitCode: Int32, stdout: String, stderr: String)] = []
    var defaultResponse: (exitCode: Int32, stdout: String, stderr: String) = (0, "", "")

    func run(_ arguments: [String], stdin: Data?) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        calls.append(Call(arguments: arguments, stdin: stdin))
        if !responses.isEmpty { return responses.removeFirst() }
        return defaultResponse
    }

    /// 最近一次调用里 `-X` 后的 IMAP 命令串
    var lastImapCommand: String? {
        guard let call = calls.last,
              let index = call.arguments.firstIndex(of: "-X"),
              index + 1 < call.arguments.count else { return nil }
        return call.arguments[index + 1]
    }

    /// 最近一次调用里的 `--url`
    var lastUrl: String? {
        guard let call = calls.last,
              let index = call.arguments.firstIndex(of: "--url"),
              index + 1 < call.arguments.count else { return nil }
        return call.arguments[index + 1]
    }
}
