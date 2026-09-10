//
//  PiRpcTransport.swift
//  P3.2: 通过 `pi --mode rpc` (JSONL over stdio) 驱动 pi coding agent。
//  协议映射 (docs/P3-functional-design.md P3.2):
//    prompt → send · abort → cancel
//    agent_start/agent_end → streamStarted/streamEnded
//    message_update{text_delta} → textChunk · {thinking_delta} → thoughtChunk
//    tool_execution_start/update/end → toolUpdated(整对象 upsert)
//  无 initialize 握手, 进程起来直接发命令; JSONL 严格以 \n 分帧。
//

import Foundation

@MainActor
final class PiRpcTransport: AgentTransport {
    weak var delegate: (any AgentTransportDelegate)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var outPipe: Pipe?
    /// 调试用: 原始 RPC 行打到 stderr (冒烟测试用; env 方式因 ProcessInfo.environment 缓存不可靠)
    nonisolated(unsafe) static var rawEchoToStderr = false
    /// 行缓冲 (readabilityHandler 在后台线程回调, 加锁)
    private let lock = NSLock()
    private nonisolated(unsafe) var lineBuffer = Data()

    // 回合状态
    private var turnActive = false
    private var textMessageID: UUID?
    private var thinkMessageID: UUID?
    private var toolCards: [String: ToolCall] = [:]   // pi toolCallId → 卡片
    private var toolStartAt: [String: Date] = [:]
    private var requestId = 0

    // 审批 (P3.3): pi 侧 permission-gate 扩展对敏感工具发 extension_ui_request,
    // 客户端按 askApproval 决定弹卡或自动应答; "Allow always" 由扩展侧会话内记忆。
    private struct PendingApproval {
        let requestId: String
        let toolUUID: UUID
        let callId: String
    }
    private var pendingApprovals: [PendingApproval] = []
    private var askApprovalOn = true
    // P3.10: bash 学习白名单 (ChatStore 下发的持久集 + 会话内 alwaysAllow 沉淀)。
    // 判定在客户端桥 (handleExtensionUIRequest) 做, 覆盖所有会话路径。
    private var learnedBashTokens: Set<String> = []

    // 工作目录 (P3.4): store 下发 project path; cwd 变化在下次 send 时重启进程生效。
    private var desiredCwd: String?
    private var spawnedCwd: String?
    /// P3.7: 知识注入块 (spawn 期 --append-system-prompt 下发; 变更需重启进程生效)。
    private var desiredKnowledge: String?
    /// P3.11: 托管扩展加载列表 (spawn 期 --extension 逐个追加; mangox-approval 固定内置)。
    private var desiredExtensions: [String] = []
    /// 会话持久化绑定 (nil = --no-session ephemeral; 非 nil = --session 文件, 重启恢复)。
    private var desiredSessionId: UUID?
    /// per-turn: spawn 期模型/思考级别 (--model provider/id, --thinking), 下回合生效。
    private var desiredModel: String?
    private var desiredThinking: ThinkingLevel = .high

    // MARK: - 可用性探测

    static func available() -> Bool { findBinary() != nil }

    private static func findBinary() -> String? {
        for p in ["/opt/homebrew/bin/pi", "/usr/local/bin/pi"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let p = "\(dir)/pi"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// pi 是 node 脚本 (shebang #!/usr/bin/env node)。直接 spawn 它时 env 要在
    /// 子进程 PATH 里找 node——Xcode 启动的 App PATH 不含 homebrew, 必失败。
    /// 故解析出 cli.js 真实路径, 显式用 node 跑。
    /// internal: MemoryDistiller 复用同一套启动方式 (node + cli.js 真实路径)。
    static func launchSpec() -> (executable: String, scriptArgs: [String])? {
        guard let piPath = findBinary() else { return nil }
        let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        guard let node = nodeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (piPath, [])  // 没有 node 就赌直接 spawn 能行 (终端态 PATH 正常时)
        }
        let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: piPath)) ?? piPath
        let script = real.hasPrefix("/")
            ? real
            : URL(fileURLWithPath: real, relativeTo: URL(fileURLWithPath: (piPath as NSString).deletingLastPathComponent)).path
        return (node, [script])
    }

    /// 审批门控扩展: tool_call 拦截敏感工具, ui.select 三选项 (Allow/Allow always/Deny)。
    /// --extension 显式加载, 不污染用户终端里的 pi (不用自动发现目录)。
    static func ensureExtensionFile() -> String {
        let dir = NSHomeDirectory() + "/.mangox/extensions"
        let path = dir + "/mangox-approval.ts"
        let source = """
        // Auto-deployed by MangoX. Gate sensitive tools behind a MangoX approval card.
        // P3.10: write 新建文件放行 (覆盖已存在文件才请求审批); bash/edit 全部交客户端判定。
        // diff 预览: edit/write 审批时把 -/+ 行对照拼进 title (客户端 @@MANGOX_DIFF@@ 分段解析)。
        import * as fs from "fs";
        export default function (pi) {
          const alwaysAllowed = new Set();
          const SENSITIVE = new Set(["bash", "write", "edit"]);
          const MAX_DIFF_LINES = 120;
          const MAX_LINE_CHARS = 200;
          const truncLine = (s) => {
            s = String(s);
            return s.length > MAX_LINE_CHARS ? s.slice(0, MAX_LINE_CHARS) + " …" : s;
          };
          // 块对照式 diff: - 旧块 / + 新块 (edit 的 replace 对语义天然对应; 不做行对齐)
          const blockDiff = (path, oldText, newText) => {
            const out = ["FILE " + path];
            const oldLines = String(oldText ?? "").split("\\n");
            const newLines = String(newText ?? "").split("\\n");
            for (const l of oldLines) out.push("- " + truncLine(l));
            for (const l of newLines) out.push("+ " + truncLine(l));
            return out;
          };
          const buildDiff = (toolName, input) => {
            try {
              let rows = [];
              if (toolName === "edit" && Array.isArray(input.edits)) {
                rows = ["FILE " + input.path];
                for (const e of input.edits) {
                  rows.push(...blockDiff("", e.oldText, e.newText).slice(1));
                  rows.push("···");
                }
              } else if (toolName === "write" && input.path) {
                const old = fs.existsSync(input.path)
                  ? fs.readFileSync(input.path, "utf-8") : "";
                rows = blockDiff(input.path, old, input.content);
              }
              if (rows.length > MAX_DIFF_LINES) {
                rows = rows.slice(0, MAX_DIFF_LINES);
                rows.push("… 其余改动省略");
              }
              return rows.join("\\n");
            } catch (e) {
              return "";
            }
          };
          pi.on("tool_call", async (event, ctx) => {
            if (!SENSITIVE.has(event.toolName)) return undefined;   // 只读工具放行
            if (alwaysAllowed.has(event.toolName)) return undefined;
            if (!ctx.hasUI) return undefined;
            const input = event.input || {};
            if (event.toolName === "write" && input.path && !fs.existsSync(input.path)) {
              return undefined;   // 新建文件: 无覆盖风险, 放行
            }
            const detail = String(input.command || input.path || input.url || "").slice(0, 500);
            let title = "MANGOX|APPROVE|" + event.toolCallId + "|" + event.toolName + "|" + detail;
            if (event.toolName === "edit" || event.toolName === "write") {
              const diff = buildDiff(event.toolName, input);
              if (diff) title += "@@MANGOX_DIFF@@" + diff;
            }
            let choice = null;
            try {
              choice = await ctx.ui.select(title, ["Allow", "Allow always", "Deny"]);
            } catch (e) {
              return { block: true, reason: "Approval UI failed" };
            }
            if (choice === "Allow always") { alwaysAllowed.add(event.toolName); return undefined; }
            if (choice === "Deny") return { block: true, reason: "Denied by user in MangoX" };
            return undefined;
          });
        }
        """
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if existing != source {
            try? source.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    // MARK: - AgentTransport

    func send(prompt: String) {
        ensureProcessForCwd()
        guard process != nil else { return } // 启动失败: 本回合静默, UI 由 ChatStore 层守卫
        turnActive = true
        textMessageID = nil
        thinkMessageID = nil
        toolCards.removeAll()
        toolStartAt.removeAll()
        emit(.streamStarted)
        sendCommand(["id": "req-\(nextRequestId())", "type": "prompt", "message": prompt])
    }

    func cancel() {
        sendCommand(["type": "abort"])
    }

    func respondToPermission(toolId: UUID, decision: PermissionDecision) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.toolUUID == toolId }) else { return }
        let pending = pendingApprovals.remove(at: idx)
        let value: String
        switch decision {
        case .allow:        value = "Allow"
        case .alwaysAllow:  value = "Allow always"   // 扩展侧 Set 记忆, 会话内不再询问
        case .deny:         value = "Deny"
        }
        // UI 即时反馈; allow 的后续 running/事件由 pi 的 tool_execution 流接管
        // (响应统一走 respondExtensionUI: Allow 时内部重置计时起点, 审批等待不计入时长)
        if var card = toolCards[pending.callId] {
            switch decision {
            case .allow, .alwaysAllow: card = card.withPhase(.running)
            case .deny:                card = card.withPhase(.error("已拒绝"))
            }
            respondExtensionUI(pending.requestId, value: value, callId: pending.callId)
            toolCards[pending.callId] = card
            emit(.toolUpdated(card))
        } else {
            respondExtensionUI(pending.requestId, value: value, callId: pending.callId)
        }
    }

    func updateApprovalPolicy(askApproval: Bool) {
        askApprovalOn = askApproval
    }

    func updateWorkingDirectory(_ path: String?) {
        desiredCwd = path
    }

    func updateKnowledgeContext(_ text: String?) {
        desiredKnowledge = text
    }

    func updateBashWhitelist(_ tokens: Set<String>) {
        learnedBashTokens = tokens
    }

    func updateExtensions(_ paths: [String]) {
        desiredExtensions = paths.filter { !$0.hasSuffix("mangox-approval.ts") }
    }

    /// 重启 pi 使最新注入块/cwd 生效 (丢进程内对话记忆, 由 UI 显式触发)。
    func restartEngine() {
        guard process != nil else { return }   // 未运行则等下次 ensureProcessForCwd 自然带新参拉起
        teardownProcess()
        ensureProcessForCwd()
    }

    // MARK: - 会话持久化绑定 (pi --session)

    /// pi session 文件目录 (每 UI 会话一个 .jsonl, 存在则恢复/不存在则新建)。
    static var sessionDirectory: String {
        NSHomeDirectory() + "/.mangox/pi-sessions"
    }

    static func sessionFilePath(for id: UUID) -> String {
        sessionDirectory + "/" + id.uuidString + ".jsonl"
    }

    /// 删除会话的持久 transcript (会话删除时清理, 防磁盘残留)。
    static func removeSessionFile(for id: UUID) {
        try? FileManager.default.removeItem(atPath: sessionFilePath(for: id))
    }

    /// 会话绑定: 仅记录, 下回合 spawn 生效 (per-turn 进程架构, 无"绑定重启"概念)。
    /// 非 nil = spawn 带 --session 文件 (pi 恢复持久 transcript);
    /// nil = --no-session ephemeral (任务 fire 轮次用)。
    func updateSessionBinding(_ sessionId: UUID?) {
        desiredSessionId = sessionId
    }

    /// App 退出清理: 终止在途 pi (孤儿进程会继续跑完回合烧 LLM token)。
    /// transcript 已由 pi 按行持久化到 --session 文件, 强杀不丢已产出内容。
    func shutdown() {
        teardownProcess()
    }

    func refreshCapabilities() {
        ensureProcessForCwd()   // 模型清单无需等首条消息, 主动拉起 pi
        guard process != nil else { return }
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_state"])
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_available_models"])
        // per-turn: 这次拉起的进程属 idle, 会随首个回合结束而退出
    }

    func setModel(provider: String, modelId: String) {
        // per-turn: 记录 spawn 期参数 (--model provider/id), 下回合生效;
        // 回合内进程在时同时发 set_model 即时切换。
        desiredModel = provider + "/" + modelId
        guard stdinHandle != nil else { return }   // 无进程: 下回合 spawn 后 get_state 自动同步 UI
        sendCommand(["id": "req-\(nextRequestId())", "type": "set_model",
                     "provider": provider, "modelId": modelId])
        // set_model 成功与否以 response 为准, 收到后再回读 get_state 同步 UI
    }

    func setThinkingLevel(_ level: String) {
        // per-turn: 记录 spawn 期参数 (--thinking), 下回合生效; 回合内即时切换。
        desiredThinking = ThinkingLevel(rawValue: level) ?? .high
        guard stdinHandle != nil else { return }   // 无进程: 下回合 spawn 后 get_state 自动同步 UI
        sendCommand(["id": "req-\(nextRequestId())", "type": "set_thinking_level", "level": level])
    }

    // MARK: - 进程管理

    /// 确保 pi 进程跑在期望的 cwd 上。cwd 变化需重启进程 (pi 会话内无切目录命令);
    /// 代价是丢掉进程内对话记忆, 仅在切换 project 时发生, 可接受。
    private func ensureProcessForCwd() {
        let target = desiredCwd ?? NSHomeDirectory()
        if process != nil, spawnedCwd != target {
            teardownProcess()
        }
        guard process == nil else { return }
        spawnProcess(cwd: target)
    }

    private func teardownProcess() {
        guard let p = process else { return }
        outPipe?.fileHandleForReading.readabilityHandler = nil
        p.terminate()   // terminationHandler 会走 processDidExit, 靠身份守卫不误伤
        process = nil
        stdinHandle = nil
    }

    private func spawnProcess(cwd: String) {
        guard let spec = Self.launchSpec() else { return }
        let extPath = Self.ensureExtensionFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executable)
        var args = spec.scriptArgs + ["--mode", "rpc",
                                      "--no-extensions", "--extension", extPath]
        if let sessionId = desiredSessionId {
            // 会话持久化: 文件存在则恢复 transcript / 不存在则新建 (pi SessionManager.open
            // 对缺失文件返回空 entries + persist, 绝对路径模式无 not-found exit 风险)
            try? FileManager.default.createDirectory(atPath: Self.sessionDirectory,
                                                     withIntermediateDirectories: true)
            args += ["--session", Self.sessionFilePath(for: sessionId)]
        } else {
            // ephemeral: 任务 fire 轮次等, transcript 仅存进程内存
            args += ["--no-session"]
        }
        // P3.11: 托管扩展按启用列表逐个 --extension 追加 (--no-extensions 已关自动发现)
        for extPath in desiredExtensions {
            args += ["--extension", extPath]
        }
        // P3.7: 知识注入块挂在 spawn 参数上 (--append-system-prompt 可重复传; 会话内不可改)
        if let knowledge = desiredKnowledge, !knowledge.isEmpty {
            args += ["--append-system-prompt", knowledge]
        }
        // per-turn: 模型/思考级别 spawn 期定格 (回合内 set_model/set_thinking_level 仍可即时切换)
        if let model = desiredModel {
            args += ["--model", model]
        }
        args += ["--thinking", desiredThinking.rawValue]
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)   // App cwd=/ 问题的正式修复
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        process = p
        spawnedCwd = cwd
        self.outPipe = outPipe
        stdinHandle = inPipe.fileHandleForWriting
        lock.lock(); lineBuffer.removeAll(); lock.unlock()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            self?.enqueue(data)
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processDidExit(p) }
            }
        }
        // P3.5: 能力上报 — spawn 后立即拉当前模型状态与可用模型清单
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_state"])
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_available_models"])
    }

    /// 身份守卫: 只有当前 process 引用退出才清理 (teardown 重启时旧进程退出不误伤新进程)。
    private func processDidExit(_ proc: Process) {
        guard process === proc else { return }
        process = nil
        stdinHandle = nil
        guard turnActive else { return }
        turnActive = false
        finalizeTrackedMessages()
        emit(.streamEnded)
    }

    // MARK: - 下行 (UI → pi)

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func sendCommand(_ dict: [String: Any]) {
        guard let stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A)
        stdinHandle.write(data)
    }

    // MARK: - 上行 (pi → UI): 线程安全的行分帧

    private nonisolated func enqueue(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(lineBuffer[lineBuffer.startIndex..<nl])  // 取段须在持锁内完成
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if var line = String(data: lineData, encoding: .utf8) {
                if line.hasSuffix("\r") { line.removeLast() }  // 协议: 接受 \r\n 但剥离 \r
                if !line.isEmpty { lines.append(line) }
            }
        }
        lock.unlock()
        let debugLog = ProcessInfo.processInfo.environment["MANGOX_RPC_LOG"]
        for line in lines {
            let arrivedAt = Date()  // 行到达时刻: 主线程处理可能滞后 (渲染卡顿), 计时须用到达时刻
            if Self.rawEchoToStderr {
                FileHandle.standardError.write("RAW \(line)\n".data(using: .utf8)!)
            }
            if let debugLog, let data = String(format: "%f %@\n", Date().timeIntervalSince1970, line).data(using: .utf8) {
                let url = URL(fileURLWithPath: debugLog)
                if let fh = FileHandle(forWritingAtPath: debugLog) {
                    defer { try? fh.close() }
                    _ = try? fh.seekToEnd()
                    try? fh.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.handleRPCLine(line, arrivedAt: arrivedAt) }
            }
        }
    }

    // MARK: - 事件解析 (MainActor)

    /// internal 供冒烟测试直接投喂 JSONL 行。
    /// arrivedAt: 读取线程的行到达时刻 (MainActor 处理可能被 UI 渲染阻塞, 计时不能用处理时刻)
    func handleRPCLine(_ line: String, arrivedAt: Date = Date()) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return }
        switch dict["type"] as? String {
        case "agent_start":
            turnActive = true
            emit(.streamStarted)

        case "message_start", "message_end":
            // pi 一个回合由多条 assistant 消息组成 (think 条 / toolcall 条 / 文本条)。
            // 边界处逐条落定并重置当前块 id, 光标不会跨消息滞留 (修 A4"已完成"光标卡住)。
            if let msg = dict["message"] as? [String: Any], msg["role"] as? String == "assistant" {
                rollMessageBoundary()
            }

        case "message_update":
            guard let ev = dict["assistantMessageEvent"] as? [String: Any] else { return }
            let delta = ev["delta"] as? String ?? ""
            guard !delta.isEmpty else { return }
            switch ev["type"] as? String {
            case "text_delta":
                emit(.textChunk(messageID: lazyID(&textMessageID), delta: delta))
            case "thinking_delta":
                emit(.thoughtChunk(messageID: lazyID(&thinkMessageID), delta: delta))
            default:
                break
            }

        case "tool_execution_start":
            guard let callId = dict["toolCallId"] as? String else { return }
            let args = dict["args"] as? [String: Any] ?? [:]
            let name = dict["toolName"] as? String ?? "bash"
            let cmd = args["command"] as? String
            let title = (args["path"] as? String) ?? cmd ?? name
            // bash 卡 title 与 command 同源, 只显示一处 (避免命令渲染两遍)
            let card = ToolCall(kind: kindFor(name),
                                title: String(title.prefix(120)),
                                command: (cmd != nil && title == cmd) ? nil : cmd,
                                phase: .running)
            toolCards[callId] = card
            toolStartAt[callId] = arrivedAt
            emit(.toolUpdated(card))

        case "tool_execution_update":
            guard let callId = dict["toolCallId"] as? String,
                  var card = toolCards[callId] else { return }
            if let out = outputString(dict["partialResult"]) {
                card = card.withDetails([ToolDetail("输出", out)])
            }
            toolCards[callId] = card
            emit(.toolUpdated(card))

        case "tool_execution_end":
            guard let callId = dict["toolCallId"] as? String,
                  var card = toolCards[callId] else { return }
            let isError = dict["isError"] as? Bool ?? false
            if isError {
                let msg = outputString(dict["result"]) ?? "工具执行失败"
                card = card.withPhase(.error(String(msg.prefix(200))))
            } else {
                if let out = outputString(dict["result"]) {
                    card = card.withDetails([ToolDetail("输出", out)])
                }
                let ms = toolStartAt[callId].map { Int(Date().timeIntervalSince($0) * 1000) }
                card = ToolCall(id: card.id, kind: card.kind, title: card.title,
                                command: card.command, details: card.details,
                                phase: .done, durationMs: ms)
            }
            toolCards[callId] = card
            emit(.toolUpdated(card))

        case "extension_ui_request":
            handleExtensionUIRequest(dict)

        case "response":
            handleRPCResponse(dict)

        case "agent_end", "agent_settled":
            guard turnActive else { return }
            turnActive = false
            finalizeTrackedMessages()
            emit(.streamEnded)
            // per-turn: 回合结束即退出 (transcript 已持久化到 --session 文件;
            // 下回合 spawn 恢复, 天然隔离 + 无常驻内存/串味问题)
            teardownProcess()

        default:
            break
        }
    }

    // MARK: - 审批 (extension_ui_request / extension_ui_response)

    private func handleExtensionUIRequest(_ dict: [String: Any]) {
        guard let reqId = dict["id"] as? String,
              let method = dict["method"] as? String else { return }
        let title = dict["title"] as? String ?? ""
        let parts = title.split(separator: "|", omittingEmptySubsequences: false).map(String.init)

        // 只认 MangoX 审批标记; 其他扩展 UI 请求自动确认, 避免进程挂死
        guard parts.count >= 5, parts[0] == "MANGOX", parts[1] == "APPROVE", method == "select" else {
            autoRespondExtensionUI(reqId, method: method)
            return
        }
        // diff 预览: detail 之后可能带 @@MANGOX_DIFF@@ 分段 (edit/write 审批)
        let fullDetail = parts.dropFirst(4).joined(separator: "|")
        let diffText: String?
        if let range = fullDetail.range(of: "@@MANGOX_DIFF@@") {
            diffText = String(fullDetail[range.upperBound...])
        } else {
            diffText = nil
        }
        let callId = parts[2]
        guard var card = toolCards[callId] else {
            respondExtensionUI(reqId, value: "Allow", callId: callId)
            return
        }
        if diffText != nil {
            card = card.withDiffText(diffText)
        }

        // askApproval off → 自动放行, 不弹卡
        guard askApprovalOn else {
            respondExtensionUI(reqId, value: "Allow", callId: callId)
            return
        }

        // P3.10 审批分层: bash 只读白名单静默放行 (判定覆盖所有会话; 无人值守由 askApproval=false 自动放行)。
        // write 到达这里 = 覆盖已存在文件 (扩展侧 existsSync 放行新建) → 按 edit 弹卡。
        if parts[3] == "bash", askApprovalOn {
            let cmd = parts.dropFirst(4).joined(separator: "|")
            if BashRiskEvaluator.evaluate(command: cmd, learned: learnedBashTokens) == .allow {
                respondExtensionUI(reqId, value: "Allow", callId: callId)
                return
            }
        }

        card = card.withPhase(.awaitingApproval)
        toolCards[callId] = card
        emit(.toolUpdated(card))
        pendingApprovals.append(PendingApproval(requestId: reqId,
                                                toolUUID: card.id,
                                                callId: callId))
    }

    private func autoRespondExtensionUI(_ reqId: String, method: String) {
        if method == "confirm" {
            sendCommand(["type": "extension_ui_response", "id": reqId, "confirmed": true])
        } else {
            sendCommand(["type": "extension_ui_response", "id": reqId, "value": "Allow"])
        }
    }

    /// 发送审批响应。Allow 时重置计时起点: 时长口径 = 允许决定之后的真实执行,
    /// 审批等待 (手动点击) 与白名单放行前的排队 (UI 渲染卡顿) 都不计入。
    private func respondExtensionUI(_ reqId: String, value: String, callId: String? = nil) {
        sendCommand(["type": "extension_ui_response", "id": reqId, "value": value])
        if value.hasPrefix("Allow"), let callId { toolStartAt[callId] = Date() }
    }

    // MARK: - Helpers

    private func lazyID(_ slot: inout UUID?) -> UUID {
        if let id = slot { return id }
        let id = UUID()
        slot = id
        return id
    }

    /// 消息边界: 落定在途块并重置 id, 下一个 delta 开新块。
    private func rollMessageBoundary() {
        finalizeTrackedMessages()
        textMessageID = nil
        thinkMessageID = nil
    }

    private func finalizeTrackedMessages() {
        if let id = textMessageID { emit(.messageFinalized(messageID: id)) }
        if let id = thinkMessageID { emit(.messageFinalized(messageID: id)) }
    }

    // MARK: - 能力上报响应 (P3.5: type=response 行)

    /// pi 响应格式: {id, type:"response", command, success, data?/error?}
    private func handleRPCResponse(_ dict: [String: Any]) {
        guard dict["success"] as? Bool == true else { return }   // 失败静默 (如模型不存在)
        let command = dict["command"] as? String ?? ""
        let data = dict["data"] as? [String: Any] ?? [:]
        switch command {
        case "get_state":
            // data: { model: {provider, id, ...}, thinkingLevel: "...", ... }
            if let model = data["model"] as? [String: Any],
               let provider = model["provider"] as? String,
               let modelId = model["id"] as? String {
                let level = data["thinkingLevel"] as? String ?? ""
                delegate?.transport(self, didUpdateModelState: provider,
                                    modelId: modelId, thinkingLevel: level)
            }
        case "get_available_models":
            // data: { models: [{provider, id, reasoning, thinkingLevelMap, ...}, ...] }
            if let models = data["models"] as? [[String: Any]] {
                let infos: [AgentModelInfo] = models.compactMap { m -> AgentModelInfo? in
                    guard let provider = m["provider"] as? String,
                          let id = m["id"] as? String else { return nil }
                    // 逐条复刻 pi getSupportedThinkingLevels (pi-ai models.js):
                    // reasoning=false → [off]; reasoning=true → off..high 默认支持
                    // (显式 null 剔除), xhigh 仅在 thinkingLevelMap 显式给出时支持。
                    let levelMap = (m["thinkingLevelMap"] as? [String: Any]) ?? [:]
                    let reasoning = (m["reasoning"] as? Bool) ?? false
                    let levels: [ThinkingLevel]
                    if !reasoning {
                        levels = [.off]
                    } else {
                        levels = ThinkingLevel.allCases.filter { lv in
                            let mapped = levelMap[lv.rawValue]
                            if let v = mapped, v is NSNull { return false }
                            if lv == .xhigh && mapped == nil { return false }
                            return true
                        }
                    }
                    return AgentModelInfo(provider: provider, id: id,
                                          name: m["name"] as? String ?? "",
                                          supportedLevels: levels)
                }
                delegate?.transport(self, didReportModels: infos)
            }
        case "set_model", "set_thinking_level":
            // 切换成功后回读 get_state, 以 pi 侧状态为准同步 UI
            sendCommand(["id": "req-\(nextRequestId())", "type": "get_state"])
        default:
            break
        }
    }

    private func emit(_ event: AgentEvent) {
        delegate?.transport(self, didEmit: event)
    }

    private func kindFor(_ toolName: String) -> ToolKind {
        switch toolName {
        case "bash": return .bash
        case "read": return .read
        case "edit": return .edit
        case "write": return .write
        case "fetch": return .fetch
        case "search": return .search
        case "image": return .image
        default: return .read
        }
    }

    /// partialResult/result 形状因工具而异, 保守提取字符串。
    private nonisolated func outputString(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        guard let d = v as? [String: Any] else { return nil }
        for k in ["output", "content", "text", "result"] {
            if let s = d[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }
}

extension ToolCall {
    func withDetails(_ details: [ToolDetail]) -> ToolCall {
        ToolCall(id: id, kind: kind, title: title, command: command,
                 details: details, phase: phase, durationMs: durationMs)
    }
}
