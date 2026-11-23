//
//  EnvironmentReport.swift
//  设置 → 关于：把"这台机器上到底跑着什么"集中成一份可复制的快照。
//
//  为什么要有：报问题时最常被问的三件事 —— 什么版本、pi 装没装、跑在哪个 node 上。
//  它们散在三个地方（Info.plist / launchSpec / 系统），让用户自己找齐太容易缺一样。
//
//  ⚠️ 探测必须离开主线程：跑 `node --version` 是一次 fork+exec，冷启动在慢机器上能到
//     几百毫秒，而这段是在设置页打开时触发的 —— 主线程那会儿正在排版。
//

import Foundation

/// 一份环境快照。`nil` 一律表示"没探到"，**不写占位假值** ——
/// 把"没读到"和"真是这个值"混成一个串，正是版本号最容易骗人的地方。
struct EnvironmentReport: Equatable {
    var appVersion: String
    var osVersion: String
    var arch: String
    var dataRoot: String
    var piVersion: String?
    var piPath: String?
    var nodeVersion: String?
    var nodePath: String?
    /// 找不到 pi 时的自查报告（列查找路径）。找到了就是 nil。
    var engineReport: String?

    var engineReady: Bool { piVersion != nil }
}

enum EnvironmentProbe {

    /// 纯函数：把子进程输出变成可展示的版本串。
    ///
    /// 只取第一行 —— `pi --version` 后面若跟着半行警告（扩展加载失败之类），
    /// 整串塞进那一格会把表格撑破，而版本号本身永远是第一行。
    static func clean(_ raw: String) -> String? {
        guard let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return nil
        }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 跑一条只读命令取输出。
    ///
    /// ⚠️ 三个细节都是踩过才会写的：
    ///   ① `terminationHandler` 必须在 `run()` **之前**设，否则极快的进程会漏掉信号，卡满超时；
    ///   ② stderr 丢进 nullDevice —— 版本探测不该在控制台留噪音，也不该被上游当错误上报；
    ///   ③ 超时后 `terminate()` 再等一小会儿，不留孤儿进程（`pi --version` 正常是毫秒级，
    ///      超时通常意味着那个二进制不是我们以为的东西）。
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 3) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 0.5)
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// 组装快照。**参数是纯值**（`launchSpec` / `binarySearchReport` 都是 MainActor 的，
    /// 由调用方在主线程取好）⇒ 这个函数可以随便丢到后台线程。
    ///
    /// `piScript` 非空 = 走 node 跑脚本（托管安装的常态）；空 = 直接执行那个二进制。
    static func make(executable: String?, piScript: String?,
                     engineReport: String?) -> EnvironmentReport {
        var r = EnvironmentReport(
            appVersion: AppVersion.display,
            osVersion: osVersion(),
            arch: archName(),
            dataRoot: "~/.mangox",
            piVersion: nil, piPath: nil,
            nodeVersion: nil, nodePath: nil,
            engineReport: engineReport)

        guard let executable else { return r }

        if let script = piScript {
            r.nodePath = executable
            r.piPath = script
            r.nodeVersion = clean(run(executable, ["--version"]) ?? "")
            r.piVersion = clean(run(executable, [script, "--version"]) ?? "")
        } else {
            // 没有 node 时 `launchSpec` 给的是 pi 自己 —— 那就直接问它。
            r.piPath = executable
            r.piVersion = clean(run(executable, ["--version"]) ?? "")
        }
        return r
    }

    /// `15.2` —— 末位是 0 就不写（`15.2.0` 读起来像另一个东西）。
    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func archName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// 复制到剪贴板的纯文本。
    ///
    /// ⚠️ 这里**故意不本地化**：它会出现在 GitHub issue / 聊天窗口里，接收方
    /// 可能和我们不是同一套界面语言。所以固定成英文小写键 + `-` 表示缺失，
    /// 任何语言的人都能读（这也是 `pfSense` / `docker version` 那类诊断块的惯例）。
    static func plainText(_ r: EnvironmentReport) -> String {
        var lines: [String] = []
        lines.append("MangoX \(r.appVersion)")
        lines.append("macOS \(r.osVersion) (\(r.arch))")
        lines.append("pi   \(r.piVersion ?? "-")   \(r.piPath ?? "-")")
        lines.append("node \(r.nodeVersion ?? "-")   \(r.nodePath ?? "-")")
        lines.append("data \(r.dataRoot)")
        return lines.joined(separator: "\n")
    }
}
