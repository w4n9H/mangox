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
    /// P6.0①: 最近一次 agent_end 的 willRetry (P6.1.2 过程态消费; 冒烟断言用 internal)。
    internal private(set) var lastWillRetry = false
    /// P6.0②冒烟: sendCommand 副本 (无进程时 sendCommand 为 no-op, 日志即可断言"未回 response")。
    internal private(set) var sentCommands: [[String: Any]] = []
    /// P6.1.1: 流式期 usage tick 节流 (500ms)。
    private var lastUsageTickAt = Date.distantPast
    /// P6.1.1: settled 后拉 get_session_stats, 响应到达再拆进程 (2s 兜底强拆)。
    private var settleStatsPending = false
    private var settleStatsTask: Task<Void, Never>?
    private var textMessageID: UUID?
    private var thinkMessageID: UUID?
    private var toolCards: [String: ToolCall] = [:]   // pi toolCallId → 卡片
    private var toolStartAt: [String: Date] = [:]
    private var requestId = 0

    // 审批 (P3.3): pi 侧 permission-gate 扩展对敏感工具发 extension_ui_request,
    // 客户端按 approvalMode 决定放行/弹卡/拒绝; "Allow always" 由扩展侧会话内记忆。
    private struct PendingApproval {
        let requestId: String
        let toolUUID: UUID
        let callId: String
    }
    private var pendingApprovals: [PendingApproval] = []
    /// P10.2a-0: 裁决档 (默认交互)。老调用点经 updateApprovalPolicy(askApproval:) 映射。
    internal private(set) var approvalMode: ApprovalMode = .interactive
    /// P10.2a-0: autoJudge 档拦下的命令 (命令 + 原因), 供任务回执写"卡在哪"。
    /// 本回合内累积, send 时清空 (transport 实例 = 会话, 见 ChatStore.transports)。
    /// P10.2b: 类型定义已提到模块级 (ApprovalMode.swift), 此处只留实例状态。
    internal private(set) var autoJudgeBlocks: [AutoJudgeBlock] = []
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
    /// P6.3.1: 显式会话文件路径 (fork 产物; 优先于 UUID 派生路径)。
    private var desiredSessionFile: String?
    /// P6.3.1: fork 源快照 (非 nil = 下次 spawn 带 --fork; 与 --session 互斥, 分支优先)。
    private var desiredForkSource: String?
    /// P6.3.1: fork 产物路径回读在途 (get_state.sessionFile 命中后清)。
    private var forkReadbackPending = false
    private var forkReadbackTask: Task<Void, Never>?
    /// per-turn: spawn 期模型/思考级别 (--model provider/id, --thinking), 下回合生效。
    private var desiredModel: String?
    private var desiredThinking: ThinkingLevel = .high
    /// P7-M4: 模式档位 (spawn 期 --tools / 业务扩展挂载), 下回合生效。
    private var desiredMode: AgentMode = .standard
    /// P7-M3: 自管模型物化产物 (nil/空 = 不注入; spawn 期落盘 + 环境变量)。
    private var piConfig: ModelMaterializer.Output?

    /// P7-M3: 接收自管模型物化产物 (ChatStore 在模型变更时推送)。
    func updatePIConfig(_ output: ModelMaterializer.Output?) {
        piConfig = output
    }

    /// P7-M4: 模式档位下发 (spawn 期消费, 下回合生效)。
    func updateMode(_ mode: AgentMode) {
        desiredMode = mode
    }

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

    func send(prompt: String, images: [OutgoingImage]) {
        ensureProcessForCwd()
        guard process != nil else { return } // 启动失败: 本回合静默, UI 由 ChatStore 层守卫
        turnActive = true
        textMessageID = nil
        thinkMessageID = nil
        toolCards.removeAll()
        toolStartAt.removeAll()
        autoJudgeBlocks.removeAll()   // P10.2a-0: 本回合的拦截记录从零开始
        emit(.streamStarted)
        // P7-M6b: images:[{type,data(base64),mimeType}] — autoResize 不覆盖 RPC base64,
        // 进这里的已由 ImagePipeline.compressForSend 压过 (≤1536px JPEG)。
        var cmd: [String: Any] = ["id": "req-\(nextRequestId())", "type": "prompt", "message": prompt]
        if !images.isEmpty {
            cmd["images"] = images.map { ["type": "image",
                                          "data": $0.data.base64EncodedString(),
                                          "mimeType": $0.mimeType] }
        }
        sendCommand(cmd)
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
            case .deny:                card = card.withPhase(.error(L("已拒绝")))
            }
            respondExtensionUI(pending.requestId, value: value, callId: pending.callId)
            toolCards[pending.callId] = card
            emit(.toolUpdated(card))
        } else {
            respondExtensionUI(pending.requestId, value: value, callId: pending.callId)
        }
    }

    /// 老入口 (askApproval 开关): true → 交互弹卡; false → 全放行。
    /// P10.2a-0 拆档后它只是二值映射, 需要 autoJudge 的调用点走 updateApprovalMode。
    func updateApprovalPolicy(askApproval: Bool) {
        approvalMode = askApproval ? .interactive : .autoAllow
    }

    /// P10.2a-0: 直接指定裁决档 (邮箱哨兵 = .autoJudge)。
    func updateApprovalMode(_ mode: ApprovalMode) {
        approvalMode = mode
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

    /// P6.3.1: 按显式路径删除 transcript (侧问 fork 产物文件名不可派生)。
    static func removeSessionFile(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 会话绑定: 仅记录, 下回合 spawn 生效 (per-turn 进程架构, 无"绑定重启"概念)。
    /// 非 nil = spawn 带 --session 文件 (pi 恢复持久 transcript);
    /// nil = --no-session ephemeral (任务 fire 轮次用)。
    func updateSessionBinding(_ sessionId: UUID?) {
        desiredSessionId = sessionId
    }

    // MARK: - Side chat fork (P6.3.1)

    /// 显式会话文件路径 (fork 产物绑定; 优先于 UUID 派生)。
    func updateSessionFilePath(_ path: String?) {
        desiredSessionFile = path
    }

    /// 下回合 spawn 带 --fork <sourceFile> (实测与 --session 互斥硬错误, 只传其一)。
    /// 产物路径不可预知 → spawn 后轮询 get_state 回读, 经 didReadSessionFile 上报。
    func startForkSession(sourceFile: String) {
        desiredForkSource = sourceFile
        forkReadbackPending = true
    }

    /// 回读收尾: fork 期望清位 + 显式绑定写回 + delegate 上报。
    private func finishForkReadback(path: String?) {
        guard forkReadbackPending else { return }
        forkReadbackPending = false
        forkReadbackTask?.cancel()
        forkReadbackTask = nil
        desiredForkSource = nil
        if let path { desiredSessionFile = path }
        delegate?.transport(self, didReadSessionFile: path)
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

    // MARK: - HTML 导出 (P6.2.3)

    private var exportPending = false
    private var exportWatchdog: Task<Void, Never>?

    /// pi export_html: 进程不活则临时拉起 (调用方需先下发会话绑定/cwd)。
    /// 响应或 15s 超时后经 didFinishExportHTMLPath 上报, 空闲态随手拆进程。
    func exportHTML(outputPath: String) {
        ensureProcessForCwd()
        guard process != nil else {
            delegate?.transport(self, didFinishExportHTMLPath: nil)
            return
        }
        exportPending = true
        sendCommand(["id": "req-\(nextRequestId())", "type": "export_html",
                     "outputPath": outputPath])
        exportWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.exportPending else { return }
            self.finishExport(path: nil)
            if !self.turnActive { self.teardownProcess() }
        }
    }

    private func finishExport(path: String?) {
        exportPending = false
        exportWatchdog?.cancel()
        exportWatchdog = nil
        delegate?.transport(self, didFinishExportHTMLPath: path)
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
        // P7-M3: 自管模型物化 — 有自管模型才注入 (覆盖整个配置目录, 与 ~/.pi/agent 互不相干);
        // 指纹不变由 writeIfNeeded 跳写, 避免 spawn 期磁盘搅动。
        if let cfg = piConfig, cfg.modelCount > 0 {
            let dir = ModelMaterializer.configDirectory()
            if (try? ModelMaterializer.writeIfNeeded(cfg, to: dir)) != nil {
                p.environment = ProcessInfo.processInfo.environment
                p.environment?["PI_CODING_AGENT_DIR"] = dir.path
            }
        }
        var args = spec.scriptArgs + ["--mode", "rpc",
                                      "--no-extensions", "--extension", extPath]
        if let fork = desiredForkSource {
            // P6.3.1: 侧问首回合 — fork 源快照 (互斥分支: 不带 --session/--no-session)。
            // --session-dir 把产物收进托管目录 (否则落 pi 默认 ~/.pi/agent/sessions);
            // 产物文件名 = <时间戳>_<uuid>.jsonl, 路径由 get_state.sessionFile 回读获得。
            try? FileManager.default.createDirectory(atPath: Self.sessionDirectory,
                                                     withIntermediateDirectories: true)
            args += ["--session-dir", Self.sessionDirectory, "--fork", fork]
            // pi 启动早期命令可能不被响应 (实测 2-3s 内单发无回音): 轮询兜底回读
            forkReadbackTask = Task { [weak self] in
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard let self, self.forkReadbackPending, self.process != nil else { return }
                    self.sendCommand(["id": "req-\(self.nextRequestId())", "type": "get_state"])
                }
            }
        } else if let sessionId = desiredSessionId {
            // 会话持久化: 文件存在则恢复 transcript / 不存在则新建 (pi SessionManager.open
            // 对缺失文件返回空 entries + persist, 绝对路径模式无 not-found exit 风险)。
            // 侧问会话 (回读过产物) 用显式路径; 普通会话走 UUID 派生。
            try? FileManager.default.createDirectory(atPath: Self.sessionDirectory,
                                                     withIntermediateDirectories: true)
            args += ["--session",
                     desiredSessionFile ?? Self.sessionFilePath(for: sessionId)]
        } else if let file = desiredSessionFile {
            // 无 UUID 绑定但有显式文件 (防御分支, 当前调用面不会走到)
            args += ["--session", file]
        } else {
            // ephemeral: 任务 fire 轮次等, transcript 仅存进程内存
            args += ["--no-session"]
        }
        // P3.11: 托管扩展按启用列表逐个 --extension 追加 (--no-extensions 已关自动发现);
        // P7-M4: 业务扩展仅完整档挂载 (极简/常规不挂, 系统扩展已固定内置不受影响)。
        if desiredMode.mountsBusinessExtensions {
            for extPath in desiredExtensions {
                args += ["--extension", extPath]
            }
        }
        // P7-M4: 极简档 --tools 白名单裁内置工具 (常规/完整不传, pi 默认即全量)
        args += AgentMode.spawnArguments(for: desiredMode, businessExtensions: [])
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
        // P6.1.1: 会话统计 (会话绑定 spawn 时即得恢复后的 context%; ephemeral 返回空, 上层丢弃)
        sendCommand(["id": "req-\(nextRequestId())", "type": "get_session_stats"])
    }

    /// 身份守卫: 只有当前 process 引用退出才清理 (teardown 重启时旧进程退出不误伤新进程)。
    private func processDidExit(_ proc: Process) {
        guard process === proc else { return }
        process = nil
        stdinHandle = nil
        if exportPending { finishExport(path: nil) }   // P6.2.3: 导出中进程死亡 → 上报失败
        if forkReadbackPending { finishForkReadback(path: nil) }   // P6.3.1: 回读中死亡 → 上报失败
        guard turnActive else { return }
        turnActive = false
        finalizeTrackedMessages(usage: nil)   // 进程异常退出: usage 无从上报
        emit(.phaseChanged(.idle))            // P6.1.2: 过程态归位
        emit(.streamEnded)
    }

    // MARK: - 下行 (UI → pi)

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func sendCommand(_ dict: [String: Any]) {
        #if DEBUG
        // P9-#6: 冒烟断言副本 — 只存 type/id 元信息 (剥离 prompt 全文与 images base64,
        // 原实现整条 append 永不清理, 多图会话内存无界增长且 Release 同样生效)
        var meta: [String: Any] = [:]
        if let t = dict["type"] { meta["type"] = t }
        if let id = dict["id"] { meta["id"] = id }
        sentCommands.append(meta)
        #endif
        guard let stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A)
        // P9-#5: throwing 版 write — 管道断裂走 Error 而非 ObjC 异常 (进程死亡竞态不崩 App)
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            print("[PiRpcTransport] stdin write failed (进程已退出?): \(error)")
        }
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
            emit(.phaseChanged(.streaming))   // P6.1.2: 过程态胶囊
            emit(.streamStarted)

        case "message_start", "message_end":
            // pi 一个回合由多条 assistant 消息组成 (think 条 / toolcall 条 / 文本条)。
            // 边界处逐条落定并重置当前块 id, 光标不会跨消息滞留 (修 A4"已完成"光标卡住)。
            if let msg = dict["message"] as? [String: Any], msg["role"] as? String == "assistant" {
                // P5.0.1: message_end 携带该次 LLM 调用的 usage/responseId/model,
                // 挂到本边界落定的块上 (start 只滚边界, usage 传 nil)。
                let usage = (dict["type"] as? String == "message_end") ? Self.parseUsage(msg) : nil
                rollMessageBoundary(usage: usage)
            }

        case "message_update":
            // P6.1.1: 顶层累计 usage → 状态栏实时 tick (500ms 节流; 无顶层 usage 则忽略)
            if let u = dict["usage"] as? [String: Any] { noteLiveUsage(u) }
            guard let ev = dict["assistantMessageEvent"] as? [String: Any] else { return }
            // ⚠️ pi 的 JSON 层会**改写**这个事件 (json-event.js `toJsonAssistantMessageEvent`):
            // 剥掉 `partial`, 并给 `toolcall_start` 补上 `id` + `toolName` (取自 partial.content)。
            // 所以下面读不到 `partial` 是协议如此, 不是解析漏了。
            switch ev["type"] as? String {
            case "toolcall_start":
                // P6.2.1: 提前出卡 (queued; 参数未知 → title=工具名)。
                // tool_execution_start 携同一 callId 到达时整卡替换转 running。
                guard let callId = ev["id"] as? String else { return }
                let name = ev["toolName"] as? String ?? "bash"
                let card = ToolCall(kind: kindFor(name), title: name, command: nil, phase: .queued)
                toolCards[callId] = card
                emit(.toolUpdated(card))

            case "toolcall_end":
                // ③ 权威参数到手: `toolCall{id,name,arguments}`。不接它 = 把参数静默丢掉 ——
                // 卡头会一直停在 "BASH  bash  等待" 直到 tool_execution_start 才补齐,
                // 而审批/排队期间用户看不到自己要批的是什么。
                guard let tc = ev["toolCall"] as? [String: Any],
                      let callId = tc["id"] as? String else { return }
                let name = tc["name"] as? String ?? "bash"
                let kind = kindFor(name)
                let head = Self.toolHead(kind: kind, name: name,
                                         args: tc["arguments"] as? [String: Any] ?? [:])
                // 缺 start (流被打断 / 提前卡没出) 也要**补一张**, 而不是 return:
                // 这一步是权威数据, 丢掉它等于把参数彻底丢了。相态仍记 queued (是否真执行由
                // tool_execution_start 决定, 不在这里替它断言)。
                var card = toolCards[callId]
                    ?? ToolCall(kind: kind, title: name, command: nil, phase: .queued)
                card.kind = kind
                card.title = String(head.title.prefix(120))
                card.command = head.command
                toolCards[callId] = card
                emit(.toolUpdated(card))

            case "text_delta":
                let delta = ev["delta"] as? String ?? ""
                guard !delta.isEmpty else { return }
                emit(.textChunk(messageID: lazyID(&textMessageID), delta: delta))

            case "thinking_delta":
                let delta = ev["delta"] as? String ?? ""
                guard !delta.isEmpty else { return }
                emit(.thoughtChunk(messageID: lazyID(&thinkMessageID), delta: delta))

            default:
                // 显式忽略 (原先统一 `break`, 事后看不出是"不需要"还是"忘了接")。
                // 已逐个核对 pi-ai/types.d.ts:400-456 的 12 种事件:
                //   start / text_start / text_end / thinking_start / thinking_end / done / error
                //     → 正文与思考的权威值随 `message_end` 走 rollMessageBoundary 落定, 无需在此重复。
                //   toolcall_delta
                //     → 内容是 toolcall_end.arguments 的**原始 JSON 碎片** (未转义), 渲染出来
                //       是一串引号花括号, 且随即被 toolcall_end 覆盖 ⇒ 噪声, 不是信息。
                break
            }

        case "tool_execution_start":
            guard let callId = dict["toolCallId"] as? String else { return }
            let args = dict["args"] as? [String: Any] ?? [:]
            let name = dict["toolName"] as? String ?? "bash"
            let kind = kindFor(name)
            let head = Self.toolHead(kind: kind, name: name, args: args)
            // P6.2.1: toolcall_start 提前卡已存在 → 沿用其 id 整卡升级 (否则旧 queued 卡
            // 永不落定 + 同一调用两张卡, 轨迹里被连续同类分组误并)
            let card = ToolCall(id: toolCards[callId]?.id ?? UUID(),
                                kind: kind,
                                title: String(head.title.prefix(120)),
                                command: head.command,
                                phase: .running)
            toolCards[callId] = card
            toolStartAt[callId] = arrivedAt
            emit(.toolUpdated(card))

        case "tool_execution_update":
            guard let callId = dict["toolCallId"] as? String,
                  var card = toolCards[callId] else { return }
            // partialResult 是**快照不是增量** (bash 每次 onUpdate 给全量 output.snapshot) ⇒ 整行替换。
            let parsed = parseToolResult(dict["partialResult"])
            if let out = parsed.text {
                card = card.withDetails([ToolDetail("输出", out)])
            }
            // 流式期不落图片 (partial 里的 image 块每次重发同一张, 会一遍遍写盘);
            // 图片只认 tool_execution_end。
            toolCards[callId] = card
            emit(.toolUpdated(card))

        case "tool_execution_end":
            guard let callId = dict["toolCallId"] as? String,
                  var card = toolCards[callId] else { return }
            let isError = dict["isError"] as? Bool ?? false
            let parsed = parseToolResult(dict["result"])
            if isError {
                // 失败的 result 也是 AgentToolResult (content[0].text = 真错误文本,
                // 见 agent-loop.js createErrorToolResult) ⇒ 取真话, 不再一律打印兜底文案。
                let msg = parsed.text ?? L("工具执行失败")
                card = card.withPhase(.error(String(msg.prefix(200))))
            } else {
                var rows: [ToolDetail] = []
                if let out = parsed.text { rows.append(ToolDetail("输出", out)) }
                // 正文缺失时才用 details 兜底 (详见 flattenDetails 的判据)
                if parsed.text == nil, let det = parsed.detailsSummary {
                    rows.append(ToolDetail("细节", det))
                }
                let images = persistToolImages(parsed.images, owner: imageOwnerId)
                let ms = toolStartAt[callId].map { Int(Date().timeIntervalSince($0) * 1000) }
                card = card.finalized(details: rows, imagePaths: images, durationMs: ms)
            }
            toolCards[callId] = card
            emit(.toolUpdated(card))

        case "extension_ui_request":
            handleExtensionUIRequest(dict)

        case "response":
            handleRPCResponse(dict)

        case "agent_end":
            // P6.0①: 一次底层 run 结束 ≠ 落定 — willRetry=true 时 pi 还会自动重试/
            // 压缩重试/投递排队消息, 在此拆进程会腰斩重试。仅记录, 过程态 (P6.1.2) 消费。
            lastWillRetry = (dict["willRetry"] as? Bool) ?? false

        case "agent_settled":
            // P6.0①: 会话级彻底落定 (无重试/压缩重试/排队后续) — 唯一拆进程点。
            guard turnActive else { return }
            turnActive = false
            finalizeTrackedMessages(usage: nil)   // 正常路径 usage 已随 message_end 落定, 此处仅为兜底
            emit(.phaseChanged(.idle))            // P6.1.2: 过程态归位
            emit(.streamEnded)
            if process != nil {
                // P6.1.1: 拆进程前拉一次会话统计 (context% 以 pi 口径为准), 响应到达再拆;
                // 2s 无响应兜底强拆。期间若用户已开新回合, turnActive 守卫防误拆。
                settleStatsPending = true
                sendCommand(["id": "req-\(nextRequestId())", "type": "get_session_stats"])
                settleStatsTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, self.settleStatsPending else { return }
                    self.settleStatsPending = false
                    if !self.turnActive { self.teardownProcess() }
                }
            } else {
                // per-turn: 回合结束即退出 (transcript 已持久化到 --session 文件;
                // 下回合 spawn 恢复, 天然隔离 + 无常驻内存/串味问题)
                teardownProcess()
            }

        // ---- P6.1.2: 过程态事件 (rpc.md §auto_retry/compaction/queue/summarization) ----
        case "auto_retry_start":
            // 瞬态错误自动重试 (overloaded/5xx) → 重试胶囊
            emit(.phaseChanged(.retrying(attempt: dict["attempt"] as? Int ?? 0,
                                         maxAttempts: dict["maxAttempts"] as? Int ?? 0,
                                         delayMs: dict["delayMs"] as? Int ?? 0)))

        case "auto_retry_end":
            // 成功/终败后底层 run 继续 (终败随 agent_end/settled 归 idle) → 回 streaming
            emit(.phaseChanged(.streaming))

        case "compaction_start":
            emit(.phaseChanged(.compacting(reason: dict["reason"] as? String ?? "threshold")))

        case "compaction_end":
            // 一次性横幅 (复用 extensionNotify 通道); 压缩后 run 继续 (overflow 场景 willRetry 重试)
            emitCompactionBanner(dict)
            emit(.phaseChanged(.streaming))

        case "summarization_retry_scheduled", "summarization_retry_attempt_start":
            emit(.phaseChanged(.summarizing))

        case "summarization_retry_finished":
            emit(.phaseChanged(.streaming))

        case "queue_update":
            let steering = dict["steering"] as? [Any] ?? []
            let followUp = dict["followUp"] as? [Any] ?? []
            let count = steering.count + followUp.count
            emit(.phaseChanged(count > 0 ? .queued(count: count) : .streaming))

        default:
            break
        }
    }

    // MARK: - 审批 (extension_ui_request / extension_ui_response)

    private func handleExtensionUIRequest(_ dict: [String: Any]) {
        guard let reqId = dict["id"] as? String,
              let method = dict["method"] as? String else { return }

        // P6.0②: fire-and-forget 方法不回 response (rpc.md 明示语义; 回了也只会污染对端)。
        // notify 上抛横幅; setStatus/setWidget/setTitle/set_editor_text 是 TUI 概念, 忽略。
        if Self.fireAndForgetMethods.contains(method) {
            if method == "notify" {
                let type = dict["notifyType"] as? String ?? "info"
                let message = dict["message"] as? String ?? ""
                emit(.extensionNotify(type: type, message: String(message.prefix(200))))
            }
            return
        }

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

        // 全放行档: 不弹卡直接过 (定时任务; 弹卡无人点 = 死锁)
        guard approvalMode.judgesByRisk else {
            respondExtensionUI(reqId, value: "Allow", callId: callId)
            return
        }

        // P3.10 审批分层: bash 只读白名单静默放行 (判定覆盖所有会话)。
        // write 到达这里 = 覆盖已存在文件 (扩展侧 existsSync 放行新建) → 按 edit 弹卡。
        if parts[3] == "bash" {
            let cmd = parts.dropFirst(4).joined(separator: "|")
            let decision = BashRiskEvaluator.judge(command: cmd, learned: learnedBashTokens)
            if decision.isAllow {
                respondExtensionUI(reqId, value: "Allow", callId: callId)
                return
            }
            // P10.2a-0 无人值守: 危险命令 deny 且不阻塞 —— 不弹卡 (没人点会死锁),
            // 不静默放行 (那是缺口)。原因落卡片 + 记录, 供任务回执写 "卡在 X"。
            if approvalMode == .autoJudge {
                let reason = decision.risk?.label ?? BashRiskEvaluator.Risk.unknownCommand.label
                autoJudgeBlocks.append(AutoJudgeBlock(callId: callId, command: cmd, reason: reason))
                card = card.withPhase(.error(String(format: L("MangoX 自动裁决拦下: %@"), reason)))
                toolCards[callId] = card
                emit(.toolUpdated(card))
                respondExtensionUI(reqId, value: "Deny", callId: callId)
                return
            }
        } else if approvalMode == .autoJudge {
            // 决定 8 (P10.2) B 案: 分级只管 bash, write/edit 一律放行。
            respondExtensionUI(reqId, value: "Allow", callId: callId)
            return
        }

        card = card.withPhase(.awaitingApproval)
        toolCards[callId] = card
        emit(.toolUpdated(card))
        pendingApprovals.append(PendingApproval(requestId: reqId,
                                                toolUUID: card.id,
                                                callId: callId))
    }

    /// P6.0②: fire-and-forget 扩展 UI 方法 (rpc.md §1277-1345, 不期待 response)。
    private static let fireAndForgetMethods: Set<String> =
        ["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"]

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

    /// 消息边界: 落定在途块并重置 id, 下一个 delta 开新块。usage 挂在最后一个落定块
    /// (LLM 调用级元数据: 同一次调用的 think 块在前, 文本块在后拿 usage; 仅 think 时 think 拿)。
    private func rollMessageBoundary(usage: MessageUsage? = nil) {
        finalizeTrackedMessages(usage: usage)
        textMessageID = nil
        thinkMessageID = nil
    }

    private func finalizeTrackedMessages(usage: MessageUsage?) {
        let textID = textMessageID, thinkID = thinkMessageID
        if let tid = thinkID { emit(.messageFinalized(messageID: tid, usage: textID == nil ? usage : nil)) }
        if let sid = textID { emit(.messageFinalized(messageID: sid, usage: usage)) }
    }

    /// P6.0③: 从 pi assistant message 提取用量 (字段缺失容忍, 全缺返回 nil)。
    private static func parseUsage(_ msg: [String: Any]) -> MessageUsage? {
        guard let u = msg["usage"] as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { u[key] as? Int ?? 0 }
        let usage = MessageUsage(
            input: int("input"), output: int("output"),
            cacheRead: int("cacheRead"), cacheWrite: int("cacheWrite"),
            reasoning: int("reasoning"), totalTokens: int("totalTokens"),
            costUSD: (u["cost"] as? [String: Any])?["total"] as? Double,
            model: msg["model"] as? String,
            responseId: msg["responseId"] as? String)
        return usage.totalTokens > 0 ? usage : nil
    }

    // MARK: - 能力上报响应 (P3.5: type=response 行)

    /// pi 响应格式: {id, type:"response", command, success, data?/error?}
    private func handleRPCResponse(_ dict: [String: Any]) {
        let command = dict["command"] as? String ?? ""
        // P6.2.3: export_html 失败也上报 (UI 横幅), 不走"失败静默"
        if command == "export_html" {
            let path = (dict["success"] as? Bool == true)
                ? (dict["data"] as? [String: Any])?["path"] as? String : nil
            finishExport(path: path)
            if !turnActive { teardownProcess() }
            return
        }
        guard dict["success"] as? Bool == true else { return }   // 失败静默 (如模型不存在)
        let data = dict["data"] as? [String: Any] ?? [:]
        switch command {
        case "get_state":
            // data: { model: {provider, id, ...}, thinkingLevel: "...", sessionFile: "...", ... }
            // P6.3.1: fork 产物路径回读 (仅在 fork 在途时消费, 普通会话的上报忽略)
            if let file = data["sessionFile"] as? String, !file.isEmpty, forkReadbackPending {
                finishForkReadback(path: file)
            }
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
                    // 级别语义的唯一实现在 ThinkingLevel.supported (本文件曾是两份拷贝之一)
                    return AgentModelInfo(
                        provider: provider, id: id,
                        name: m["name"] as? String ?? "",
                        supportedLevels: ThinkingLevel.supported(
                            reasoning: (m["reasoning"] as? Bool) ?? false,
                            map: (m["thinkingLevelMap"] as? [String: Any]) ?? [:]))
                }
                delegate?.transport(self, didReportModels: infos)
            }
        case "get_session_stats":
            // P6.1.1: 会话统计上报 (spawn 期 + settled 拆进程前各拉一次)
            delegate?.transport(self, didReportSessionStats: Self.parseSessionStats(data))
            if settleStatsPending {
                settleStatsPending = false
                settleStatsTask?.cancel()
                settleStatsTask = nil
                if !turnActive { teardownProcess() }   // 已开新回合则不拆
            }
        case "set_model", "set_thinking_level":
            // 切换成功后回读 get_state, 以 pi 侧状态为准同步 UI
            sendCommand(["id": "req-\(nextRequestId())", "type": "get_state"])
        default:
            break
        }
    }

    // MARK: - 会话统计 (P6.1.1)

    /// P6.1.2: compaction_end → 一次性横幅 (复用 extensionNotify 通道)。
    /// 成功报 tokensBefore → estimatedTokensAfter; 中止/失败按 warning 报原因。
    private func emitCompactionBanner(_ dict: [String: Any]) {
        let aborted = dict["aborted"] as? Bool ?? false
        let message: String
        if aborted {
            message = L("上下文压缩已中止")
        } else if let result = dict["result"] as? [String: Any] {
            let before = result["tokensBefore"] as? Int ?? 0
            let after = result["estimatedTokensAfter"] as? Int ?? 0
            message = String(format: L("上下文压缩完成：%lld → %lld tokens"), before, after)
        } else {
            let err = dict["errorMessage"] as? String ?? L("未知错误")
            message = String(format: L("上下文压缩失败：%@"), err)
        }
        emit(.extensionNotify(type: aborted ? "warning" : "info", message: String(message.prefix(200))))
    }

    /// message_update 顶层累计 usage → usageTick (500ms 节流)。
    /// 流式 usage 无 context%, contextPercent 留 nil 由 Store 沿用最近一次上报。
    private func noteLiveUsage(_ u: [String: Any]) {
        let stats = SessionStats(
            contextPercent: nil,
            inputTokens: u["input"] as? Int ?? 0,
            outputTokens: u["output"] as? Int ?? 0,
            cacheReadTokens: u["cacheRead"] as? Int ?? 0,
            costUSD: (u["cost"] as? [String: Any])?["total"] as? Double)
        let now = Date()
        guard now.timeIntervalSince(lastUsageTickAt) >= 0.5 else { return }
        lastUsageTickAt = now
        emit(.usageTick(stats))
    }

    /// get_session_stats data → SessionStats (字段缺失容忍; percent null → nil)。
    private static func parseSessionStats(_ data: [String: Any]) -> SessionStats {
        func int(_ v: Any?) -> Int { v as? Int ?? 0 }
        func dbl(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            return nil
        }
        let t = data["tokens"] as? [String: Any] ?? [:]
        let c = data["contextUsage"] as? [String: Any] ?? [:]
        return SessionStats(
            contextPercent: dbl(c["percent"]),
            contextTokens: int(c["tokens"]),
            contextWindow: int(c["contextWindow"]),
            inputTokens: int(t["input"]),
            outputTokens: int(t["output"]),
            cacheReadTokens: int(t["cacheRead"]),
            costUSD: (data["cost"] as? [String: Any]).flatMap { dbl($0["total"]) })
    }

    private func emit(_ event: AgentEvent) {
        delegate?.transport(self, didEmit: event)
    }

    /// 卡头两列 (title / command) 的**唯一**推导处 —— `toolcall_end` 与 `tool_execution_start`
    /// 都调它。两处各写一套必然分叉 (前者是"参数已定", 后者是"开始执行"), 分叉后的症状是
    /// 卡片在两步之间**跳一下**、或者审批时看到的命令和随后执行的不是一条。
    private static func toolHead(kind: ToolKind, name: String, args: [String: Any])
        -> (title: String, command: String?) {
        let cmd = args["command"] as? String
        let path = args["path"] as? String
        // 未知工具 (kind == .other) 的卡头标签恒为 "OTHER", 标签本身不携带真名 ⇒ 真名必须
        // 占 title, 否则用户看不出跑的是哪个扩展工具 (args 退到 command 列)。
        if kind == .other { return (name, cmd ?? path ?? firstScalarArg(args)) }
        let title = path ?? cmd ?? name
        return (title, (cmd != nil && title == cmd) ? nil : cmd)
    }

    /// 未知工具的参数兜底: 取**第一个标量参数**渲染成 `key=value`。
    /// 对未知工具"哪个参数重要"是不可知的, 但"它有参数"是事实 —— 丢掉才是隐瞒。
    /// 按 key 排序取首个 ⇒ 同一调用**幂等** (两次推导必得同一结果, 卡头不会跳)。
    private static func firstScalarArg(_ args: [String: Any]) -> String? {
        for key in args.keys.sorted() {
            guard let v = args[key] else { continue }
            if let s = v as? String, !s.isEmpty { return "\(key)=\(s)" }
            if let b = v as? Bool { return "\(key)=\(b)" }
            if let n = v as? NSNumber { return "\(key)=\(n)" }
        }
        return nil
    }

    private func kindFor(_ toolName: String) -> ToolKind {
        switch toolName {
        case "bash", "powershell": return .bash   // P6.0④: powershell 是 Windows 同族
        case "read": return .read
        case "grep": return .grep                 // P6.0④: 内置工具补全 (原落 default 错显 read)
        case "find": return .find
        case "ls": return .ls
        case "edit": return .edit
        case "write": return .write
        case "fetch": return .fetch
        case "search": return .search
        case "image": return .image
        case "delegate": return .delegate         // pi 0.85.1 无内置生产方, 留位给扩展
        // ⚠️ **不许再 return .read** —— 那是谎报: 装了 web-search / subagents 这类扩展后,
        // 卡片标签会**读作 READ**, 轨迹页 chip 更连**颜色一起错** (`defaultColor` 只在轨迹页用;
        // 卡片标签色走 `railColor`, 由相态决定 ⇒ 那里错的是文字不是颜色)。
        // 且落库的 kind 已失真、事后分不出"真 read"和"未知工具"。
        // 中性 OTHER 难看, 但它是诚实的; 真名由 `toolHead` 放进 title (见下)。
        default: return .other
        }
    }

    /// pi 的工具结果是 **`AgentToolResult`**, 不是裸字符串:
    ///   `{ content: (TextContent | ImageContent)[], details: T, usage?, terminate? }`
    ///   `TextContent  = { type: "text",  text: String }`
    ///   `ImageContent = { type: "image", data: String(base64), mimeType: String }`
    /// (pi-agent-core/types.d.ts:317-331 · pi-ai/types.d.ts:251-255 · 实测 read.js:85 返回图片块)
    ///
    /// ⚠️ **旧版 `outputString` 只在顶层找字符串键** ⇒ `content[]` 整个没看 ⇒ 每张卡
    /// `"details":[]`(连成功的 `cat` 也没输出), 失败时只剩一句兜底文案。**这是丢数据, 不是没数据。**
    private struct ParsedToolResult {
        var text: String?
        var images: [(data: String, mimeType: String)] = []
        /// `details` 的可读折平 (各工具自定结构: bash 有 truncation/fullOutputPath)。
        var detailsSummary: String?
    }

    private func parseToolResult(_ v: Any?) -> ParsedToolResult {
        var out = ParsedToolResult()
        // 老/异形形状兜底: 扩展可能直接给字符串
        if let s = v as? String {
            out.text = s.isEmpty ? nil : s
            return out
        }
        guard let d = v as? [String: Any] else { return out }

        if let blocks = d["content"] as? [Any] {
            var texts: [String] = []
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty { texts.append(t) }
                case "image":
                    if let data = block["data"] as? String, !data.isEmpty {
                        out.images.append((data, block["mimeType"] as? String ?? "image/png"))
                    }
                default:
                    break
                }
            }
            if !texts.isEmpty { out.text = texts.joined(separator: "\n") }
        }
        // 无 content[] 的结果: 退回顶层字符串键 (旧口径, 保留)
        if out.text == nil {
            for k in ["output", "text", "result"] {
                if let s = d[k] as? String, !s.isEmpty { out.text = s; break }
            }
        }
        if let det = d["details"] {
            out.detailsSummary = Self.flattenDetails(det)
        }
        return out
    }

    /// `details` 折成一行可读文本 (`key=value · key.sub=1`)。
    /// **只在正文缺失时才有资格上屏** —— `content[].text` 已是给模型的摘要 (含
    /// "[Showing lines 1-50 of 300…]" 这类续读提示), 常见情形下 details 是它的子集, 同时
    /// 显示只会多一行噪声。
    private static func flattenDetails(_ v: Any) -> String? {
        var parts: [String] = []
        flatten(v, prefix: "", into: &parts)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func flatten(_ v: Any, prefix: String, into out: inout [String]) {
        if let d = v as? [String: Any] {
            for k in d.keys.sorted() {
                let key = prefix.isEmpty ? k : "\(prefix).\(k)"
                flatten(d[k] as Any, prefix: key, into: &out)
            }
        } else if let a = v as? [Any] {
            for (i, item) in a.enumerated() { flatten(item, prefix: "\(prefix)[\(i)]", into: &out) }
        } else if v is NSNull {
            return                                   // 空值不占位 (JSON null = 无此项)
        } else if let b = v as? Bool {
            out.append("\(prefix)=\(b)")
        } else if let n = v as? NSNumber {
            out.append("\(prefix)=\(n)")
        } else if let s = v as? String, !s.isEmpty {
            out.append("\(prefix)=\(s)")
        }
    }

    /// 工具产出图片的落盘位置键。有会话绑定用会话 id (这样"删会话"的
    /// `ImagePipeline.removeSessionAttachments` 一并覆盖); 无绑定 (任务 fire 的
    /// --no-session 回合) 退到 transport 实例 id —— 这类会话本来就没有 UI, 不必回收。
    private let transportInstanceId = UUID()
    private var imageOwnerId: UUID { desiredSessionId ?? transportInstanceId }

    /// base64 图片块 → 落盘 → 返回本机路径。落盘失败返回 nil (**不猜、不留半张**)。
    private func persistToolImages(_ images: [(data: String, mimeType: String)],
                                   owner: UUID) -> [String] {
        var paths: [String] = []
        for img in images {
            guard let data = Data(base64Encoded: img.data) else { continue }
            let ext = ImagePipeline.sniffExtension(data)
                ?? img.mimeType.split(separator: "/").last.map(String.init)
                ?? "png"
            if let saved = try? ImagePipeline.saveOriginal(data, fileExtension: ext, sessionID: owner) {
                paths.append(saved.path)
            }
        }
        return paths
    }
}
