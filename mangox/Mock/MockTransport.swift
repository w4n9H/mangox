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
