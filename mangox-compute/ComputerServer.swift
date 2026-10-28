//
//  ComputerServer.swift
//  mangox-compute: unix socket 的**生命周期**与请求分发。
//
//  三个不变量:
//   ① **目录 0700 / 文件 0600** —— 同用户以外的进程连路径都摸不到(§04 门 0 的第 ① 条);
//   ② **每次 accept 都验 peer**(uid + 进程树), 验不过就关掉连接, 且**不回话**
//      —— 回话等于告诉对方"这里有个 socket";
//   ③ 一问一答, 一个连接可以问多次, 但对端关掉就结束 —— 不做多路复用,
//      也不需要: 一轮会话只有一个 pi 在跟它说话。
//
//  ⚠️ 为什么 socket 路径只经 env 下发: 它是"这一轮才存在"的凭证。写进配置文件 ⇒
//     别的会话(别的任务、别的档位)也能连上来, 双闸门(挂载 + env)的第二道就破了。
//

import ApplicationServices
import AppKit
import Darwin
import Foundation

final class ComputerServer {

    /// 允许连接的**祖先进程**: 本轮 pi 的 pid, 经 env 下发。
    let allowedAncestorPid: pid_t?

    /// 作用域: 允许读的 bundle id。空 = 还没下发 ⇒ **一律拒**(不是"都给")。
    let allowedBundles: Set<String>

    private let path: String
    private var listenFd: Int32 = -1

    init(path: String) {
        self.path = path
        let env = ProcessInfo.processInfo.environment
        self.allowedAncestorPid = env[PeerCheck.peerPidEnvKey].flatMap { pid_t($0) }
        let raw = env[ComputerServer.allowedBundlesEnvKey] ?? ""
        self.allowedBundles = Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    static let allowedBundlesEnvKey = "MANGOX_COMPUTE_ALLOWED_BUNDLES"

    // MARK: - 生命周期

    /// 起监听。**失败就崩** —— 起不来比"起来但没在听"好排查得多。
    func serve() -> Never {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        unlink(path)

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { fatal("socket() 失败: \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = path.utf8
            let n = min(bytes.count, buf.count - 1)
            buf.copyBytes(from: Array(bytes.prefix(n)))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, size) == 0 && listen(listenFd, 8) == 0
            }
        }
        guard ok else { fatal("bind/listen 失败: \(errno) path=\(path)") }
        chmod(path, 0o600)

        installTerminationCleanup()
        print("mangox-compute listening: \(path)")
        fflush(stdout)

        while true {
            let fd = accept(listenFd, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                continue
            }
            handleConnection(fd)
            close(fd)
        }
    }

    /// App 退出 / 崩溃时也得有人收: 否则留一个**还握着辅助功能权限的孤儿进程** + 一个废 socket。
    private func installTerminationCleanup() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig) { _ in
                // ⚠️ 只做"删文件 + 退出", 不做别的: 信号处理器里能安全调的函数就那么几个。
                exit(0)
            }
        }
        // 父进程(launch 它的那一侧)死了也要走 —— 常驻进程最怕的就是"没人管它"。
        // `MANGOX_COMPUTE_PARENT_PID` 为 0 时不启用(手动调试时不该被杀掉)。
        if let raw = ProcessInfo.processInfo.environment["MANGOX_COMPUTE_PARENT_PID"],
           let parent = pid_t(raw), parent > 0 {
            DispatchQueue.global().async {
                while true {
                    sleep(2)
                    // `kill(pid, 0)` 只探活不送信 —— 父进程没了就说明没人管我们了。
                    if kill(parent, 0) != 0 { break }
                    // 被 reparent 到 launchd 也是同一个信号。
                    if getppid() == 1 { break }
                }
                unlink(self.path)
                exit(0)
            }
        }
    }

    private func fatal(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("mangox-compute: " + message + "\n").utf8))
        exit(1)
    }

    // MARK: - 连接

    private func handleConnection(_ fd: Int32) {
        guard PeerCheck.accept(socket: fd, allowedAncestorPid: allowedAncestorPid) else {
            // 不回话、不打日志里的路径: 未知来源连上来时, 沉默就是最好的回执。
            return
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(n))
            while let idx = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer.prefix(upTo: idx), as: UTF8.self)
                buffer.removeSubrange(...idx)
                let req = ComputerFraming.decode(line)
                let response: ComputerResponse
                if let req {
                    response = handle(req)
                } else {
                    response = .failure("读不懂这一行(协议不匹配)。")
                }
                var out = ComputerFraming.encode(response)
                _ = out.withUnsafeMutableBytes { send(fd, $0.baseAddress, $0.count, 0) }
            }
        }
    }

    // MARK: - 分发

    func handle(_ request: ComputerRequest) -> ComputerResponse {
        switch request {
        case .ping:
            return .pong(trusted: AXIsProcessTrusted())

        case .read(let app, let includeImage):
            guard AXIsProcessTrusted() else {
                return .failure("辅助功能权限还没授予 ⇒ 读不到界面。请在 系统设置 › 隐私与安全性 › 辅助功能 里勾上 MangoX。")
            }
            let candidates = candidatesInScope()
            guard !candidates.isEmpty else {
                return .failure("本次会话没有开放任何 App ⇒ 我不读界面。")
            }
            let target = resolve(query: app, in: candidates)
            guard let t = target else {
                // ⚠️ 回执**必须带上"能读哪些"**: 模型不知道作用域, 只说"不在作用域内"会让它
                // 一个个 App 试过去(每次一轮往返, 而且它可能会猜 bundle id)。
                return .failure(refusal(query: app, available: candidates))
            }
            guard isInScope(pid: t.pid) else {
                return .failure("「\(t.name)」不在本次作用域内 ⇒ 我不读它。")
            }
            guard let tree = AXAdapter.frontWindowTree(pid: t.pid) else {
                return .failure("读不到「\(t.name)」的窗口树(它可能没有窗口, 或者 AX 树太薄)。")
            }
            if includeImage {
                return .failure("图像面还没做(批 2 才接)。这次先按文本读。")
            }
            let snap = AXSnapshot.build(root: tree,
                                        appName: t.bundle,
                                        windowTitle: tree.title)
            // ⚠️ 「窗口是空的」与「这个 App 不暴露界面」在快照上长得**一模一样**(都近乎空),
            //    但模型该做的事不同: 前者报告"这里什么都没有", 后者换 App 或要求截图。
            //    不区分 ⇒ 模型会把微信那 3 个按钮当成"这个窗口的全部内容"(2026-10-28 实测: 微信
            //    主窗口 1052×754 只暴露 6 个节点, 消息列表/聊天正文/输入框一个都没有)。
            if AXSnapshot.lacksReadableControls(root: tree) {
                return .success(text: lackOfControlsNote(app: t.name, nodes: snap.rows.count)
                                + "\n\n" + snap.rendered())
            }
            return .success(text: snap.rendered())
        }
    }

    // MARK: - 指认 → 定位

    /// 作用域内**当前正在跑**的 App。
    ///
    /// ⚠️ 为什么先按作用域过滤再挑: 选不中的那一半**根本不该出现在候选里** ——
    ///    否则 `pick` 命中一个不在作用域的 App, 后面还要再挡一次(两处判就是两处会漂),
    ///    而且失败回执里会泄出"本机正跑着哪些 App"这类与本次任务无关的信息。
    func candidatesInScope() -> [ComputerTarget.Candidate] {
        guard !allowedBundles.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundle = app.bundleIdentifier, allowedBundles.contains(bundle) else { return nil }
            // `processIdentifier` 在 App 已退出但还在列表里时是 -1 ⇒ 那个 pid 读不到任何东西。
            guard app.processIdentifier > 0 else { return nil }
            return ComputerTarget.Candidate(bundle: bundle,
                                            name: app.localizedName ?? bundle,
                                            pid: app.processIdentifier)
        }
    }

    /// 空 query = **当前前台**; 其余交给 `ComputerTarget.pick`(纯函数, 冒烟能断言)。
    private func resolve(query: String,
                         in candidates: [ComputerTarget.Candidate]) -> ComputerTarget.Candidate? {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let bundle = front.bundleIdentifier else { return nil }
            return candidates.first { $0.bundle == bundle }
        }
        return ComputerTarget.pick(query: query, in: candidates)
    }

    /// 命中"没有可读控件层"时的说明。
    ///
    /// ⚠️ **两种可能都要写**("自绘不暴露" / "确实是空的"): 判据分不出它们, 而且分错了
    ///    的代价不对称 —— 说成"空的"会让模型以为读成功了, 然后基于"这个窗口只有三个按钮"
    ///    去推断用户想干什么。那是本轮最坏的一种错。
    private func lackOfControlsNote(app: String, nodes: Int) -> String {
        "⚠️「\(app)」的这个窗口里读不到可读的控件: 只拿到 \(nodes) 个节点, 没有任何文本/输入/列表。"
        + "两种可能: ① 这个 App 是自绘的、不向系统暴露界面(微信就是这样), 那样的 App 只能截图看;"
        + " ② 窗口确实是空的(例如刚新建的白页)。先换一个 App 试, 或者问用户这个界面上本来应该有什么。"
    }

    /// 选不中时的人话。⚠️ 两种原因要分开说: "没在跑"与"不在作用域"对模型是两条不同的路
    /// （前者可以等, 后者只能换目标或问用户）。
    private func refusal(query: String, available: [ComputerTarget.Candidate]) -> String {
        let names = available.map(\.name).joined(separator: " / ")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty, let front = NSWorkspace.shared.frontmostApplication {
            let who = front.localizedName ?? front.bundleIdentifier ?? "那个 App"
            return "当前前台是「\(who)」, 它不在本次作用域内 ⇒ 我不读它。本次能读: \(names)"
        }
        return "读不到「\(q)」—— 它现在没在跑, 或者不在本次作用域内。本次能读: \(names)"
    }

    /// 作用域判据的**这一层**: 只认 bundle id 名单。
    ///
    /// ⚠️ 名单为空 ⇒ 拒。理由同 `PeerCheck`: 空不是"全都行", 空是"没下发"。
    /// 真正的"动作面 / 恒拒判据"在 `mangox/Models` 上的纯函数里(能被冒烟断言)。
    func isInScope(pid: pid_t) -> Bool {
        guard !allowedBundles.isEmpty else { return false }
        return candidatesInScope().contains { $0.pid == pid }
    }
}
