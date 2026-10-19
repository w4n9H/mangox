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
    @MainActor
    static var registeredCases: [@MainActor () async -> Void] {
        [
            caseUserMessageFold,
            caseSessionTitlePersist,
        ]
    }

    @MainActor
    static func runRegisteredCases() async {
        for one in registeredCases { await one() }
    }
}
