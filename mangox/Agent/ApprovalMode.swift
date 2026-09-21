//
//  ApprovalMode.swift
//  P10.2a-0: 审批裁决档 —— 把原先的 askApproval 布尔 (弹卡 / 全放行两极)
//  拆成三档, 补上无人值守真正需要的那一极: 危险命令"拒绝但不阻塞"。
//
//  档位差异只在审批桥 (PiRpcTransport.handleExtensionUIRequest) 的裁决分支表达;
//  bash 分级判定 (BashRiskEvaluator) 三档共用。
//

import Foundation

/// P10.2a-0: `autoJudge` 档拦下的一条命令 (命令 + 人话原因)。
/// 本回合内累积, `send` 时清空 (transport 实例 = 会话, 见 `ChatStore.transports`)。
/// P10.2b: 提到模块级 —— 它是**回执**的数据来源, 由 `AgentTransport` 协议暴露 (原先嵌在 PiRpcTransport 里)。
struct AutoJudgeBlock: Equatable {
    let callId: String
    let command: String
    let reason: String
}

// Codable: 哨兵配置往表列落 rawValue (P10.2a); rawValue 即落库串。
enum ApprovalMode: String, Codable, CaseIterable, Identifiable {
    /// 白名单静默放行, 其余弹卡等人点 (默认; 原 askApproval = true)
    case interactive
    /// 全部放行, 不弹卡 (定时任务; 原 askApproval = false)
    case autoAllow
    /// 白名单放行; 其余 **deny 且不阻塞** + 记原因 (邮箱哨兵等远程驱动)
    case autoJudge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .interactive: "Interactive"
        case .autoAllow:   "Auto allow"
        case .autoJudge:   "Auto judge"
        }
    }

    var subtitle: String {
        switch self {
        case .interactive:
            L("只读命令静默放行, 其余弹审批卡等待点击。")
        case .autoAllow:
            L("不弹卡, 全部放行 — 定时任务用 (无人点击, 弹卡即死锁)。")
        case .autoJudge:
            L("只读命令静默放行, 危险命令自动拒绝并记下原因 (回执告知) — 远程驱动用。")
        }
    }

    /// 是否需要人点击 (只有交互档会挂起在途回合等人)。
    var waitsForUser: Bool { self == .interactive }

    /// 是否走风险分级 (autoAllow 不做判定, 直接放行)。
    var judgesByRisk: Bool { self != .autoAllow }
}
