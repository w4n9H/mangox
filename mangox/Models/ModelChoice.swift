//
//  ModelChoice.swift
//  受控模型选择值 + 思考级别收敛规则 (模型链路收敛: 取代原"模型 × 级别"笛卡尔积展开)。
//
//  与 `SessionConfig` 的分工: 本类型只回答"选哪个模型、什么强度" —— 是 `ModelPicker` 的值;
//  `SessionConfig` 表达"一次运行的完整配置" (另含 agentMode / askApproval), 由宿主把本值并进去。
//

import Foundation

/// 受控选择值: 模型分量 (provider + modelId) + 思考级别。
/// 两处宿主共用: composer 药丸 (写全局期望) / 定时任务配置 (仅本任务, 不碰全局)。
struct ModelChoice: Equatable {
    var provider: String
    var modelId: String
    var level: ThinkingLevel

    /// 尚未选中任何模型 (pi 未上报且无自管条目时的初始态)。
    var isUnset: Bool { provider.isEmpty && modelId.isEmpty }
}

/// 某模型可停靠的思考级别 (= 滑轨的停靠点)。
/// ⚠️ `supportedLevels` **空 ≠ 无级别可选** ⇒ 空时给全集: pi 目录回落的裸态下该字段恒空,
/// 若按空处理则滑轨退化成一个停靠点、级别再也没法调 —— 旧 UI 靠菜单笛卡尔积展开级别,
/// 那条路径已随 `ModelMenuEntry` 删除, 兜底必须落在这里。
func thinkingStops(for model: AgentModelInfo?) -> [ThinkingLevel] {
    guard let model, !model.supportedLevels.isEmpty else { return ThinkingLevel.allCases }
    return model.supportedLevels
}

/// 把级别收敛到目标模型的合法停靠点: 已合法原样返回; 否则按 `allCases` 序**就近**取,
/// 并列取更低档 (宁少想不多想), 越界自然落到端点。
/// 用途: 换模型后立刻给出合法组合 —— 让"胶囊显示 xhigh、实际跑 off"这类割裂不可能出现。
func clampLevel(_ level: ThinkingLevel, to model: AgentModelInfo?) -> ThinkingLevel {
    let stops = thinkingStops(for: model)
    if stops.isEmpty { return level }
    if stops.contains(level) { return level }
    let target = ThinkingLevel.allCases.firstIndex(of: level) ?? 0
    func distance(_ l: ThinkingLevel) -> Int {
        abs((ThinkingLevel.allCases.firstIndex(of: l) ?? 0) - target)
    }
    // min(by:) 并列时保留先遇到者 ⇒ 结合 stops 已按 allCases 序 = 取更低档。
    return stops.min { distance($0) < distance($1) } ?? stops[0]
}
