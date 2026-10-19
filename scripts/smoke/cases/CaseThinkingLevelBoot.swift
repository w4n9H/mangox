//
//  caseThinkingLevelBoot —— 思考档位: 启动默认 + clamp 边界
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家 + dir→fixturesRoot 等价替换）。
//  原位替换为 `await caseThinkingLevelBoot()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseThinkingLevelBoot() async {
        let db = fixturesRoot + "/menu.db"
        let s = ChatStore(transport: MockTransport(), dbPath: db,
                          managedExtensionsDir: fixturesRoot + "/ext")
        check(s.managedModels.isEmpty, "T13 新库无自管模型")
        check(s.menuModels.count == 3
              && Set(s.menuModels.map(\.provider)) == ["deepseek", "openai"],
              "T13 无自管模型时菜单回落 pi 上报目录")

        // 停靠点: 上报无 supportedLevels (裸态) ⇒ 全集 —— 空集会让滑轨退化成单点、级别再也调不了
        let bare = s.menuModels[0]
        check(bare.supportedLevels.isEmpty, "T13 上报条目无 supportedLevels (前置)")
        check(thinkingStops(for: bare) == ThinkingLevel.allCases,
              "T13 裸态停靠点 = 全集 (空 ≠ 无级别可选)")

        // 停靠点: 有 supportedLevels ⇒ 严格取之 (不补齐)
        var restricted = bare
        restricted.supportedLevels = [.off, .high]
        check(thinkingStops(for: restricted) == [.off, .high],
              "T13 有上报级别时停靠点严格取之")
        check(clampLevel(.xhigh, to: restricted) == .high
              && clampLevel(.minimal, to: restricted) == .off,
              "T13 clamp 越界落到最近端点")
        check(clampLevel(.high, to: restricted) == .high,
              "T13 clamp 已合法则原样")
        // 并列取更低档 (宁少想不多想): [low, high] 对 medium 等距 ⇒ low
        var tie = bare
        tie.supportedLevels = [.low, .high]
        check(clampLevel(.medium, to: tie) == .low,
              "T13 clamp 并列取更低档")

        // 选中透传真实 provider/id; 药丸回落 id 末段 (无自管条目可查 label)
        s.selectModel(ModelChoice(provider: bare.provider, modelId: bare.id, level: .high))
        check(s.currentProvider == "deepseek" && s.currentModelId == "deepseek-v4-flash",
              "T13 选中透传真实 provider/id")
        check(s.currentModelDisplayName == "deepseek-v4-flash",
              "T13 无自管条目时药丸回落 id 末段")
        check(s.currentChoice == ModelChoice(provider: "deepseek",
                                             modelId: "deepseek-v4-flash", level: .high),
              "T13 currentChoice 与选中一致 (控件初值来源)")
    }
}
