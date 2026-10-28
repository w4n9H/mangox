//
//  AllCases.swift —— 冒烟新用例的**注册表**。
//
//  为什么单独有这个文件: `run()` 所在的 `smokeMain.swift` 有体量棘轮门（只减不增），
//  所以"接线"不能让主文件变长 —— 所有新用例的接线都集中登记在这里，主文件只留**一行**
//  `await runRegisteredCases()`（已经加好了，以后不用再动）。
//
//  加一个用例:
//    1. 在本目录新建 `CaseXxx.swift`，写成 `extension SmokeMain { @MainActor static func caseXxx() async { … } }`
//    2. 在下面的数组里登记一行 `caseXxx,`
//  详见同目录 `README.md`。
//

import Foundation

extension SmokeMain {
    /// 登记表: 顺序即执行顺序。每个 case **必须自带夹具**（用 `fixtureDir`），
    /// 不得依赖 `run()` 里的任何局部变量 —— 那些变量不属于你。
    ///
    /// ⚠️ 用例内部**不许**调 `report()` —— 它是"收尾 + exit"，只属于整个 run 的末尾。
    /// 写在某个 case 结尾，`registeredCases` 就从那一条起**被静默截断**，而日志照样 "ALL PASS"
    /// （2026-10-21 实测：`caseFollowBeats` 结尾那句 `report()` 让后面登记的 T-FOLD 一条没跑、
    /// 1498 条 PASS 全绿）。⇒ `casesRemaining` 会在 `report()` 里把这件事变成红灯。
    static var casesRemaining = 0

    @MainActor
    static var registeredCases: [@MainActor () async -> Void] {
        [
            caseUserMessageFold,
            caseToolRun,
            caseSessionTitlePersist,
            caseEmptyTurn,
            caseNestedTool,
            caseModelPin,
            caseFollowBeats,
            caseFoldRule,
            caseTimeline,
            caseTurnBill,
            caseWindowFit,
            caseSettingsWindow,
            caseSleepGuard,
            caseComputerPure,
            caseApprovalGate,
        ]
    }

    @MainActor
    static func runRegisteredCases() async {
        let all = registeredCases
        casesRemaining = all.count
        for one in all {
            await one()
            casesRemaining -= 1
        }
    }
}
