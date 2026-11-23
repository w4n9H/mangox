//
//  FeishuBridgeLink.swift
//  P19.2 S15 —— 起一个 node 子进程跑桥，按行收发。
//
//  ── 为什么是子进程而不是纯 Swift ────────────────────────────────────────────
//  飞书的长连接推的是 **protobuf 帧**，官方 SDK 只有 Node / Go / Java / Python。
//  "自己照着协议实现一遍" 不是不能做，是没有第二个人能验收 —— 而这条通道的全部价值
//  就在于**它真的能收到消息**。所以这里选择：桥用官方 SDK，App 只跟它讲 NDJSON。
//
//  ── 为什么不算"新增运行时依赖" ─────────────────────────────────────────────
//  node 早就是产品前提 —— `pi` 本身就是 node 脚本，`PiRpcTransport.launchSpec()`
//  显式用 `/opt/homebrew/bin/node` 去跑它（同款解析在下面 `nodePath()`，不另起一套）。
//  SDK 不进用户机器: 开发期 esbuild 打成单文件（`mangox/Resources/feishu-bridge.cjs`），
//  用户侧零安装。
//
//  ⚠️ 三条实测出来的坑（改了就会以"收不到消息"的形式复发，且零红灯）:
//    ① **stdin 必须保持打开**。桥靠 `stdin end/close` 判断"App 走了"，我们一关管道
//       它就退出；反过来，App 被强杀时管道断开，桥也会自己走（不留孤儿 node）。
//    ② **stdout 只读协议行**。SDK 会 `console.log('[info]: ...')`，桥里已经改道到
//       stderr，但这里仍按"解不出就丢"处理 —— 上游多打一行不该变成一条用户可见的错误。
//    ③ **单实例**。飞书长连接是集群随机投递（同一事件只给一个客户端），两个桥同时在线
//       会表现为"有时候回、有时候不回"。守卫在桥里（PID 锁文件），这里只负责把
//       "已经有一个在跑" 如实显示出来，不自己再猜。
//
//  ── S15b: 一个桥进程管 N 个机器人 ────────────────────────────────────────────
//  实测（`/tmp/fs-probe/multi.mjs`）: 同一进程里起两个 `WSClient`，两个都
//  `event-dispatch is ready`、8 秒后仍 `clients=2`。所以不需要"一个机器人一个进程"
//  —— 那会让单实例锁、孤儿回收、诊断行三件事都变成 N 份。
//  机器人集合变了（增删改/开关/换 secret）就**整条桥重启**: 热加一个客户端要维护
//  "哪几个已经起来"的中间态，而重启的代价只是几秒重连（飞书长连接重连很便宜）。
//

import Foundation

// MARK: - 按行切

/// 字节流 → 行。**纯值类型**，冒烟直接对拍（含"半行先到"这种唯一会错的情形）。
struct NDJSONBuffer {
    private var buf = Data()

    /// 喂一段字节，返回这次凑齐的完整行（不含换行符，已丢弃空行）。
    ///
    /// ⚠️ 保留不完整的尾巴是这条通道最容易写错的一处：`readabilityHandler` 一次给的
    ///    chunk 与"一行"没有关系 —— 大消息会被切开、小消息会挤在一起。若在这里按 chunk
    ///    直接解析，表现是**长回复必定丢、短回复偶尔丢**。
    mutating func feed(_ chunk: Data) -> [String] {
        buf.append(chunk)
        var lines: [String] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let lineData = buf[buf.startIndex..<nl]
            buf = buf[buf.index(after: nl)...]
            guard let s = String(data: lineData, encoding: .utf8) else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append(t) }
        }
        return lines
    }

    /// 换一行之后清空（管道断了再用同一个实例时不能带着上一条的残渣）。
    mutating func reset() { buf = Data() }
}

// MARK: - 缝

/// 交给桥的一个机器人（凭据的**唯一**载体，只在进程启动那一刻存在）。
struct RemoteLinkBot: Equatable {
    /// App 侧生成的机器人 id（UUID 字符串）。桥把它原样写进每一帧的 `bot` 字段。
    let id: String
    let appId: String
    let secret: String
}

/// 通道的实现缝。真实实现是 `FeishuBridgeLink`（node 子进程）；冒烟用 `FakeRemoteLink`。
///
/// ⚠️ `@MainActor`：收发的落点全是 `ChatStore`（主线程模型）。开成任意线程可达会让
/// "这条消息投进哪一轮"变成竞态问题，而那种问题在测试里几乎复现不出来。
@MainActor
protocol RemoteLink: AnyObject {
    var onFrame: ((RemoteFrame) -> Void)? { get set }
    var onExit: ((String) -> Void)? { get set }
    /// 起（或重起）整条桥。**机器人集合变了就整条重来** —— 见文件头。
    func start(bots: [RemoteLinkBot]) throws
    func stop()
    /// 出口跟着消息走: 同一个 `chat_id` 只有那个收到消息的机器人有资格回。
    ///
    /// `file` 非 nil ⇒ 桥先发文本、再上传并发送这个附件（`bridge.mjs` 的 `send` 帧）。
    /// 附件**只给路径**，二进制由桥自己读（同 TCC 归属，协议保持一行 JSON）。
    ///
    /// `ref`（2026-11-23）是**回执关联键**，桥在 `send_result` 里原样带回来 —— 「已发消息」
    /// 靠它把结果落回具体那一行（`agent_sent.id`）。传 nil 也合法（旧调用点 / 探针），
    /// 只是那条回执对不上任何记录。
    func send(botId: String, chatId: String, text: String, file: RemoteAttachment?, ref: String?)
}

extension RemoteLink {
    /// 只发文本。协议里不能写默认参数值，所以用这个扩展兜住"绝大多数只发文本"的调用点
    /// —— 少一个参数就多一处能传错的机会。
    func send(botId: String, chatId: String, text: String) {
        send(botId: botId, chatId: chatId, text: text, file: nil, ref: nil)
    }
}

// MARK: - 真实现

@MainActor
final class FeishuBridgeLink: RemoteLink {
    var onFrame: ((RemoteFrame) -> Void)?
    var onExit: ((String) -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var buffer = NDJSONBuffer()
    /// 最近一次起来的那个 node 的 pid。给联调判据用 —— **"我们这边的回调说它退了"不算证据**
    /// （回调只证明我们收到了通知），要验"有没有孤儿"只能回操作系统问一次。
    private(set) var childPid: Int32?

    /// 桥脚本。它跟着 App 走（`mangox/Resources/feishu-bridge.cjs`）。
    ///
    /// 找不到 = 出包时资源没进去（`PBXFileSystemSynchronizedRootGroup` 会把 `mangox/`
    /// 下的未知扩展名当资源拷 —— 但这依赖 Xcode 的判定，所以失败要**说得出原因**）。
    static func scriptURL() -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["MANGOX_FEISHU_BRIDGE"],
           FileManager.default.fileExists(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        return Bundle.main.url(forResource: "feishu-bridge", withExtension: "cjs")
    }

    /// node 在哪。**与 `PiRpcTransport.launchSpec()` 同一套候选**（Xcode 起的 App
    /// PATH 里没有 homebrew，靠 `which` 找不到）。
    static func nodePath() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["MANGOX_NODE"],
           FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        return ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 单实例锁。桥自己会读它、判 PID 存活；App 只负责给一个**稳定路径**。
    static var lockPath: String { NSHomeDirectory() + "/.mangox/feishu-bridge.pid" }

    func start(bots: [RemoteLinkBot]) throws {
        stop()
        guard !bots.isEmpty else { throw BridgeError.noBots }
        guard let node = Self.nodePath() else {
            throw BridgeError.noNode
        }
        guard let script = Self.scriptURL() else {
            throw BridgeError.noScript
        }
        // 机器人清单走**一个**环境变量（JSON）。凭据因此落在子进程的 env 里 ——
        // 同一个用户 `ps eww` 能看到，但同用户本来就能读钥匙串；换成 stdin 下发只是把
        // "一次性投递"变成"一条要维护的握手协议"，不划算。**别写进文件/日志。**
        let payload: [[String: String]] = bots.map {
            ["id": $0.id, "app_id": $0.appId, "app_secret": $0.secret]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let botsJSON = String(data: json, encoding: .utf8) else {
            throw BridgeError.badBots
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["FS_BOTS"] = botsJSON
        env["FS_LOCK"] = Self.lockPath
        // 桥把环境里的 PATH 带下去，但 node 已显式指定 ⇒ 这里只为 SDK 内部可能起的
        // 子进程（没有）留个正常值。
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            // 解析在主线程做（`onFrame` 的消费者是 ChatStore）；切行是纯值运算，代价可忽略。
            Task { @MainActor in self?.consume(chunk) }
        }
        // stderr 只留最后一段做诊断 —— 桥把 SDK 的日志全打到这里，不落文件、不刷控制台。
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
            Log.event("feishu-bridge-stderr", "tail", String(s.suffix(200)))
        }

        p.terminationHandler = { proc in
            Task { @MainActor [weak self] in
                // ⚠️ 只认**当前那个**子进程。`stop()` 会先 `terminate()` 再把 `process` 置 nil，
                // 而终止回调是异步到的 —— 不做这个身份判断的话，旧进程的回调会把**新进程**的
                // `process` 抹成 nil（之后 stop 杀不掉它 ⇒ 孤儿 node），还会报一条假的"通道断了"
                // （重连时一按就红，而桥其实好好的）。
                guard let self, self.process === proc else { return }
                self.process = nil
                self.flushRemainder()
                self.onExit?("exit \(proc.terminationStatus)")
            }
        }

        try p.run()
        process = p
        childPid = p.processIdentifier
        stdinPipe = inPipe
        stdoutPipe = outPipe
        stderrPipe = errPipe
        buffer.reset()
    }

    func stop() {
        stdinPipe?.fileHandleForWriting.closeFile()   // 桥见 stdin 断 ⇒ 自己退
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        buffer.reset()
    }

    func send(botId: String, chatId: String, text: String, file: RemoteAttachment?, ref: String?) {
        guard let pipe = stdinPipe else { return }
        var payload: [String: Any] = ["type": "send", "bot": botId, "chat_id": chatId, "text": text]
        if let file {
            payload["file"] = ["path": file.path, "name": file.name]
        }
        if let ref { payload["ref"] = ref }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        // 写管道失败 = 桥已经没了（进程崩/被杀）。**不在这里自动重启**: 自动重启会把
        // "它在反复崩"变成一条看不到的重试循环，而人只看到"消息时有时无"。
        try? pipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
    }

    private func consume(_ chunk: Data) {
        for line in buffer.feed(chunk) {
            if let frame = RemoteFrame.decode(line) {
                onFrame?(frame)
            } else {
                Log.event("feishu-bridge-noise", "line", String(line.prefix(120)))
            }
        }
    }

    /// 进程退出时如果缓冲里还剩半行，按"能解就解"处理一次。
    private func flushRemainder() {
        let rest = buffer.feed(Data([0x0A]))
        for line in rest {
            if let frame = RemoteFrame.decode(line) { onFrame?(frame) }
        }
    }

    enum BridgeError: LocalizedError {
        case noNode
        case noScript
        case noBots
        case badBots

        var errorDescription: String? {
            switch self {
            case .noNode:
                return L("找不到 node —— 桥要靠它跑（Homebrew 的 /opt/homebrew/bin/node）")
            case .noScript:
                return L("App 里缺少 feishu-bridge.cjs —— 打包时资源没进去")
            case .noBots:
                return L("一个机器人也连不了（没填 app_id 或没填 app_secret）")
            case .badBots:
                return L("机器人清单组装失败 —— 这是程序内部错误")
            }
        }
    }
}

// MARK: - 冒烟用

/// 什么都不起、什么都不发。`sent` 里留着发出去的话，供断言。
@MainActor
final class FakeRemoteLink: RemoteLink {
    var onFrame: ((RemoteFrame) -> Void)?
    var onExit: ((String) -> Void)?

    private(set) var started = 0
    private(set) var stopped = 0
    /// 每次 start 收到的机器人清单（"整条重起"这条判据的唯一证据）。
    private(set) var startedBots: [[RemoteLinkBot]] = []
    /// 发出去的文本（与 `ref` 一一对应：冒烟靠它断言"关联键真的传下去了"）。
    private(set) var sent: [(botId: String, chatId: String, text: String, ref: String?)] = []
    /// 发出去的附件（与 `sent` **分开记**: 文本那侧的断言一条都不该被附件改动）。
    private(set) var sentFiles: [(botId: String, chatId: String, file: RemoteAttachment)] = []
    var startError: Error?

    func start(bots: [RemoteLinkBot]) throws {
        if let e = startError { throw e }
        started += 1
        startedBots.append(bots)
    }

    func stop() { stopped += 1 }

    func send(botId: String, chatId: String, text: String, file: RemoteAttachment?, ref: String?) {
        sent.append((botId, chatId, text, ref))
        if let file { sentFiles.append((botId, chatId, file)) }
    }

    /// 模拟桥推进来一帧。
    func emit(_ frame: RemoteFrame) { onFrame?(frame) }
}
