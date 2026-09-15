//
//  AgentTransport.swift
//  P3.0: UI 与 Agent 引擎的边界。
//  ChatStore 只消费事件做状态归并, 不关心对端是 mock 还是真实 ACP 进程。
//

import Foundation

/// UI 对审批卡的决定 (Approval footer 三按钮)。
enum PermissionDecision {
    case allow
    case deny
    case alwaysAllow
}

/// Agent → UI 的单向事件流 (呈现投影, 与 pi RPC / ACP 的事件语义一一对应)。
enum AgentEvent {
    case streamStarted
    /// 追加文本增量; messageID 首次出现时由 Store 自动建 assistant 块。
    case textChunk(messageID: UUID, delta: String)
    /// 追加思考增量; messageID 首次出现时由 Store 自动建 think 块。
    case thoughtChunk(messageID: UUID, delta: String)
    /// 某条流式消息落定 (isStreaming = false); usage = 该次 LLM 调用用量 (P5.0.1,
    /// 挂在边界最后一个落定块上; nil = 无上报)。
    case messageFinalized(messageID: UUID, usage: MessageUsage?)
    /// 工具卡相位变化, Store 按 toolId 定位消息并应用 (P3.2 ACP 换整对象 upsert)。
    case toolPhaseChanged(toolId: UUID, phase: ToolPhase)
    /// 工具卡整对象 upsert (按 ToolCall.id): 无则新建, 有则整体替换。
    case toolUpdated(ToolCall)
    /// P6.0②: 扩展 fire-and-forget 通知 (pi extension_ui_request / notify)。
    /// type = notifyType (info/warning/error)。
    case extensionNotify(type: String, message: String)
    /// P6.1.1: 流式期用量 tick (message_update 顶层累计 usage, 500ms 节流)。
    case usageTick(SessionStats)
    /// P6.1.2: 回合过程态 (agent_start/auto_retry/compaction/queue/summarization 驱动)。
    case phaseChanged(RuntimePhase)
    case streamEnded
}

/// P7-M6b: 随 prompt 发送的图片 (原始字节 + mime; pi 侧 RPC 编码 base64)。
struct OutgoingImage: Hashable {
    let data: Data
    let mimeType: String
}

@MainActor
protocol AgentTransport: AnyObject {
    var delegate: (any AgentTransportDelegate)? { get set }
    /// 发送一轮 prompt (regenerate 复用同一入口; images = P7-M6b 图片附件, 编码进 RPC images 数组)。
    func send(prompt: String, images: [OutgoingImage])
    /// 取消在途生成。
    func cancel()
    /// 对审批卡作出决定。
    func respondToPermission(toolId: UUID, decision: PermissionDecision)
    /// 同步审批策略 (askApproval 开关即时生效; pi 侧由客户端自动应答实现)。
    func updateApprovalPolicy(askApproval: Bool)
    /// 同步工作目录 (P3.4: project 会话绑定 pi 的 cwd; nil = 无项目, 用 home)。
    func updateWorkingDirectory(_ path: String?)
    /// P3.5: 拉取对端能力上报 (当前模型/思考级别 + 可用模型清单)。spawn 后自动触发。
    func refreshCapabilities()
    /// P3.5: 运行时切换模型 (pi: set_model {provider, modelId})。
    func setModel(provider: String, modelId: String)
    /// P3.5: 运行时切换思考级别 (pi: set_thinking_level {level})。
    func setThinkingLevel(_ level: String)
    /// P3.7: 下发知识注入块 (spawn 期 system prompt)。nil = 无知识。
    /// 注意: 只影响下次引擎拉起, 变更后需 restartEngine() 立即生效。
    func updateKnowledgeContext(_ text: String?)
    /// P3.7: 重启引擎进程 (使最新注入块生效; 丢进程内对话记忆)。
    func restartEngine()
    /// P3.10: 下发 bash 学习白名单 (弹卡"始终允许"沉淀的首 token 集)。
    func updateBashWhitelist(_ tokens: Set<String>)
    /// P3.11: 下发托管扩展加载列表 (spawn 期 --extension, 变更需重启引擎生效)。
    func updateExtensions(_ paths: [String])
    /// 会话绑定: UI 会话 ↔ 引擎侧对话记忆。nil = ephemeral (fire 轮次, 不持久化);
    /// 非 nil = 绑定该 UI 会话的持久 transcript (pi: --session <file>, 重启自动恢复,
    /// 进程重启/切项目/App 重启都不再失忆)。变更时引擎需重载。
    func updateSessionBinding(_ sessionId: UUID?)
    /// App 退出时调用: 终止在途引擎进程 (per-turn 架构下孤儿 pi 会继续烧 token 跑完回合)。
    func shutdown()
    /// P6.2.3: 导出会话 HTML (pi export_html; 进程不活则临时拉起)。
    /// 完成后经 delegate didFinishExportHTMLPath 上报 (path nil = 失败)。
    func exportHTML(outputPath: String)
    /// P6.3.1: 显式会话文件路径绑定 (优先于 UUID 派生路径; 侧问 fork 产物专用,
    /// 产物文件名 = <时间戳>_<uuid>.jsonl, 无法派生, 只能回读)。
    func updateSessionFilePath(_ path: String?)
    /// P6.3.1: 下一回合 spawn 带 --fork <sourceFile> (--session 互斥, 不可同传)。
    /// spawn 后经 get_state.sessionFile 回读产物路径, 走 delegate didReadSessionFile。
    func startForkSession(sourceFile: String)
    /// P7-M3: 下发自管模型物化产物 (nil = 无自管模型; spawn 注 PI_CODING_AGENT_DIR + 落盘)。
    func updatePIConfig(_ output: ModelMaterializer.Output?)
    /// P7-M4: 下发模式档位 (spawn 期 --tools / 扩展挂载矩阵; per-turn 语义, 下回合生效)。
    func updateMode(_ mode: AgentMode)
}

/// P3.5: 对端上报的可用模型 (pi modelRegistry 条目的保守投影)。
struct AgentModelInfo: Hashable {
    let provider: String
    let id: String
    /// 显示名 (pi 侧 name 字段, 如 "DeepSeek V4 Flash"); 空则回落 id。
    var name: String = ""
    /// 模型支持的思考级别 (按 pi getSupportedThinkingLevels 语义计算:
    /// reasoning=false → 仅 off; reasoning=true → off..high 默认支持 (显式 null 才剔除),
    /// xhigh 仅在 thinkingLevelMap 显式给出时支持); 空 = 单条菜单。
    var supportedLevels: [ThinkingLevel] = []
    var label: String { name.isEmpty ? id : name }
}

/// 菜单条目 = 模型 × 思考级别 (笛卡尔积)。Identifiable 的 id 必须含级别分量——
/// 同一模型的 high/xhigh 两条若共用 model.id 作 ForEach id 会撞车, 渐染成重复行。
struct ModelMenuEntry: Identifiable {
    let id: String
    let model: AgentModelInfo
    let level: ThinkingLevel?
}

/// P3.5: pi 支持的思考级别全集 (--thinking 文档与 set_thinking_level 一致)。
enum ThinkingLevel: String, CaseIterable, Identifiable {
    case off, minimal, low, medium, high, xhigh
    var id: String { rawValue }
}

@MainActor
protocol AgentTransportDelegate: AnyObject {
    func transport(_ transport: any AgentTransport, didEmit event: AgentEvent)
    /// P3.5: 当前模型/思考级别上报 (get_state)。
    func transport(_ transport: any AgentTransport,
                   didUpdateModelState provider: String, modelId: String, thinkingLevel: String)
    /// P3.5: 可用模型清单上报 (get_available_models)。
    func transport(_ transport: any AgentTransport, didReportModels: [AgentModelInfo])
    /// P6.1.1: 会话统计上报 (get_session_stats; spawn 期 + settled 拆进程前各拉一次)。
    func transport(_ transport: any AgentTransport, didReportSessionStats stats: SessionStats)
    /// P6.2.3: HTML 导出完成上报。path = 产物路径 (nil = 失败/超时)。
    func transport(_ transport: any AgentTransport, didFinishExportHTMLPath path: String?)
    /// P6.3.1: fork 产物路径回读 (get_state.sessionFile)。nil = 回读失败 (进程退出前未拿到)。
    func transport(_ transport: any AgentTransport, didReadSessionFile path: String?)
}

extension AgentTransportDelegate {
    // 默认空实现: Mock 等不关心能力上报的 delegate 少写样板。
    func transport(_ transport: any AgentTransport,
                   didUpdateModelState provider: String, modelId: String, thinkingLevel: String) {}
    func transport(_ transport: any AgentTransport, didReportModels: [AgentModelInfo]) {}
    func transport(_ transport: any AgentTransport, didReportSessionStats stats: SessionStats) {}
    func transport(_ transport: any AgentTransport, didFinishExportHTMLPath path: String?) {}
    func transport(_ transport: any AgentTransport, didReadSessionFile path: String?) {}
}

extension AgentTransport {
    // 默认空实现: Mock 无进程/注入概念, 零样板。
    func updateKnowledgeContext(_ text: String?) {}
    func restartEngine() {}
    /// P3.10: 下发 bash 学习白名单 (弹卡"始终允许"沉淀的首 token 集)。
    func updateBashWhitelist(_ tokens: Set<String>) {}
    /// P3.11: 下发托管扩展加载列表 (spawn 期 --extension, 变更需重启引擎生效)。
    func updateExtensions(_ paths: [String]) {}
    /// 会话绑定 (Mock 无进程, 空实现)。
    func updateSessionBinding(_ sessionId: UUID?) {}
    /// 退出清理 (Mock 无进程, 空实现)。
    func shutdown() {}
    /// HTML 导出 (Mock 无进程, 空实现; 真实路径由 PiRpcTransport 实现)。
    func exportHTML(outputPath: String) {}
    /// P6.3.1: 显式会话文件绑定 (Mock 无进程, 空实现)。
    func updateSessionFilePath(_ path: String?) {}
    /// P6.3.1: fork 会话 (Mock 无进程, 空实现)。
    func startForkSession(sourceFile: String) {}
    /// P7-M3: 物化产物下发 (Mock 无进程, 空实现)。
    func updatePIConfig(_ output: ModelMaterializer.Output?) {}
    /// P7-M4: 模式档位下发 (Mock 无进程, 空实现)。
    func updateMode(_ mode: AgentMode) {}
}
