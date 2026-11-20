//
//  MockTransport.swift
//  原 ChatStore 内的假 Agent 逻辑原样下沉 (P3.0 回归基线: UI 行为零变化)。
//

import Foundation

@MainActor
final class MockTransport: AgentTransport {
    weak var delegate: (any AgentTransportDelegate)?
    private var cancelled = false
    /// smoke 注入: 自定义回复生成 (nil = 默认模拟)。输入 prompt, 返回完整回复。
    var scriptedReply: ((String) -> String)?
    /// smoke 断言用: 最近一次 updateExtensions 下发的启用列表
    var lastDesiredExtensions: [String]?
    /// smoke 断言用: 会话绑定变化次数 (含 nil 绑定)
    private(set) var bindingChangeCount = 0
    /// smoke 断言用: 当前绑定
    private(set) var boundSessionId: UUID?
    /// P7-M3 smoke 断言用: 最近一次物化产物下发
    private(set) var lastPIConfig: ModelMaterializer.Output?
    /// P7-M4 smoke 断言用: 最近一次模式档位下发
    private(set) var lastMode: AgentMode?
    /// P10.4: 任务级模型/级别下发记录 (冒烟断言)
    private(set) var lastSetModel: (provider: String, modelId: String)?
    private(set) var lastThinking: String?
    /// P7-M6b smoke 断言用: 最近一次发送的图片数
    private(set) var lastSentImages: [OutgoingImage] = []
    /// P10.2a smoke 断言用: 最近一次 send 的 prompt (哨兵"beginTurn 收到 prompt"断言)
    private(set) var lastSentPrompt: String?
    /// P10.2a smoke 断言用: 最近一次 cwd 下发 (哨兵项目绑定/回落 home 断言)
    private(set) var lastWorkingDirectory: String?

    func updateExtensions(_ paths: [String]) {
        lastDesiredExtensions = paths
    }

    func updatePIConfig(_ output: ModelMaterializer.Output?) {
        lastPIConfig = output
    }

    func updateMode(_ mode: AgentMode) {
        lastMode = mode
    }

    /// P15.3 smoke 断言用: 最近一次 dream spool 下发。
    /// **记录"被清回 nil"同样重要** —— 普通回合必须把它清掉, 否则那份 transport 会一直
    /// 挂着 dream 扩展（而 `lastDreamSpool` 停在旧值上正是那个 bug 的形状）。
    private(set) var lastDreamSpool: String?
    private(set) var dreamSpoolUpdates: Int = 0

    /// P10.1b smoke 断言用: 最近一次下发的博查 key。判据同 `lastDreamSpool` ——
    /// **"被清回 nil"要能观察到**（清了 key 却还挂在旧值上 = 面板说没配、实际还在用）。
    private(set) var lastWebSearchKey: String?
    private(set) var webSearchKeyUpdates: Int = 0

    func updateDreamSpool(_ spool: String?) {
        lastDreamSpool = spool
        dreamSpoolUpdates += 1
    }

    /// S15c smoke 断言用: 最近一次飞书附件 spool 下发。判据同 `lastDreamSpool` ——
    /// **"普通回合被清回 nil"必须能观察到**（挂着不清 = 之后每一轮都能调 `feishu_attach`，
    /// 而落点是早就结束的那一轮）。
    private(set) var lastAttachSpool: String?
    private(set) var attachSpoolUpdates: Int = 0

    func updateAttachSpool(_ spool: String?) {
        lastAttachSpool = spool
        attachSpoolUpdates += 1
    }

    /// P10.1b: 记录下发的搜索 key —— 冒烟靠它断言"配置变更有没有真的推到 transport"。
    func updateWebSearchKey(_ key: String?) {
        lastWebSearchKey = key
        webSearchKeyUpdates += 1
    }

    /// P19 smoke 断言用: 最近一次的 system 注入段。判据同 `lastDreamSpool` ——
    /// **"被清回 nil"必须能观察到**：助理巡检轮之后的那次手动回合如果继承巡检契约，
    /// 表现是"我随口问一句，它按巡检契约答 NO_FINDING"。
    private(set) var lastExtraSystemPrompt: String?
    private(set) var extraSystemPromptUpdates: Int = 0

    func updateExtraSystemPrompt(_ text: String?) {
        lastExtraSystemPrompt = text
        extraSystemPromptUpdates += 1
    }

    /// P19: 执行守卫（冒烟断言"执行回合挂上了、普通回合清掉了"）。
    private(set) var lastExecutionGuard: ExecutionGuard?
    private(set) var executionGuardUpdates: Int = 0
    func updateExecutionGuard(_ guardValue: ExecutionGuard?) {
        // 计数与"清回 nil"两件事都要能观察 —— 同 `lastExtraSystemPrompt` 那条:
        // 漏清的表现是"之后每一轮都带着红线", 只有计数能证明它真的被下发过。
        lastExecutionGuard = guardValue
        executionGuardUpdates += 1
    }

    /// P19 S6 smoke 注入: 本回合的过闸落痕 (mock 无审批桥, 默认空)
    var execActions: [Int: ExecAction] = [:]

    func updateSessionBinding(_ sessionId: UUID?) {
        guard boundSessionId != sessionId else { return }
        boundSessionId = sessionId
        bindingChangeCount += 1
    }

    func send(prompt: String, images: [OutgoingImage]) {
        cancelled = false
        lastSentImages = images
        lastSentPrompt = prompt
        delegate?.transport(self, didEmit: .streamStarted)
        Task { await simulateReply(prompt: prompt) }
    }

    func cancel() {
        cancelled = true
    }

    func updateApprovalPolicy(askApproval: Bool) {
        // mock 无审批策略概念 (审批卡行为固定); 记录最近一次下发供 smoke 断言 (P8-T27)
        lastAskApproval = askApproval
    }

    /// P8-T27 smoke 断言用: 最近一次审批策略下发
    private(set) var lastAskApproval: Bool?

    func updateApprovalMode(_ mode: ApprovalMode) {
        // P10.2a-0 smoke 断言用: 裁决档下发 (验证 ChatStore.beginTurn 的 approvalOverride 接线)
        lastApprovalMode = mode
    }

    /// P10.2a-0 smoke 断言用: 最近一次裁决档下发 (nil = 从未下发, 走全局 askApproval 开关)
    private(set) var lastApprovalMode: ApprovalMode?

    /// P10.2b smoke 注入: 本回合"被自动裁决拦下"的命令 (回执链路断言用; mock 无审批桥, 默认空)
    var autoJudgeBlocks: [AutoJudgeBlock] = []

    func updateWorkingDirectory(_ path: String?) {
        // mock 无进程, 无 cwd 概念; 记录最近一次下发供 P10.2a 哨兵断言 (项目绑定 / 回落 home)
        lastWorkingDirectory = path
    }

    // MARK: - P9-#1 smoke: 导出 delegate 链路
    // 回 nil (失败分支) = 只验证 delegate 挂接与 finishExport 收尾, 不触发 Finder reveal

    /// P9-#1 smoke 断言用: 最近一次导出路径下发
    private(set) var lastExportPath: String?

    func exportHTML(outputPath: String) {
        lastExportPath = outputPath
        delegate?.transport(self, didFinishExportHTMLPath: nil)
    }

    // MARK: - P3.5: 能力上报 (mock 固定清单, 保持 UI 行为回归基线)

    private let mockModels: [AgentModelInfo] = [
        AgentModelInfo(provider: "deepseek", id: "deepseek-v4-flash"),
        AgentModelInfo(provider: "openai", id: "gpt-5.6-sol"),
        AgentModelInfo(provider: "openai", id: "o4-mini"),
    ]

    func refreshCapabilities() {
        delegate?.transport(self, didReportModels: mockModels)
        delegate?.transport(self, didUpdateModelState: "deepseek",
                            modelId: "deepseek-v4-flash", thinkingLevel: "xhigh")
    }

    /// 冒烟专用：清掉上一次动作的记录。
    ///
    /// ⚠️ 为什么必须有：同一场会话上接连做两个动作（fire → 对话轮）时，"后者取对了配置"这类
    /// 断言会读到**前一次**留下的值 ⇒ **恒绿**。T-OWN 第一版就是这么假绿的：把修复整段拆掉，
    /// 它照样 PASS（`lastSetModel` 还留着 fire 那次的值）。
    func resetDispatchProbe() {
        lastMode = nil
        lastSetModel = nil
        lastThinking = nil
    }

    func setModel(provider: String, modelId: String) {
        lastSetModel = (provider, modelId)   // P10.4: 冒烟断言任务级模型下发
        delegate?.transport(self, didUpdateModelState: provider,
                            modelId: modelId, thinkingLevel: "xhigh")
    }

    func setThinkingLevel(_ level: String) {
        lastThinking = level   // P10.4: 冒烟断言任务级级别下发
        delegate?.transport(self, didUpdateModelState: "deepseek",
                            modelId: "deepseek-v4-flash", thinkingLevel: level)
    }

    func respondToPermission(toolId: UUID, decision: PermissionDecision) {
        switch decision {
        case .deny:
            delegate?.transport(self, didEmit: .toolPhaseChanged(toolId: toolId, phase: .error("已拒绝")))
        case .allow, .alwaysAllow:
            delegate?.transport(self, didEmit: .toolPhaseChanged(toolId: toolId, phase: .running))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard !cancelled else { return }
                delegate?.transport(self, didEmit: .toolPhaseChanged(toolId: toolId, phase: .done))
            }
        }
    }

    // MARK: - Mock streaming (与原 simulateAgentReply 逐点等价)

    private func simulateReply(prompt: String) async {
        let reply = scriptedReply?(prompt)
            ?? "好的,先记下「\(prompt.prefix(30))」的需求,我会在下一轮把上下文喂给模型,再回执计划。"
        let id = UUID()
        for ch in reply {
            if cancelled { return } // user clicked stop
            delegate?.transport(self, didEmit: .textChunk(messageID: id, delta: String(ch)))
            try? await Task.sleep(nanoseconds: 18_000_000)
        }
        delegate?.transport(self, didEmit: .messageFinalized(messageID: id, usage: nil))
        delegate?.transport(self, didEmit: .streamEnded)
    }
}
