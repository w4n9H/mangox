//
//  CaseKnowledgeWeight.swift
//  常驻知识条目的**重量**建议条（2026-11-26；文章 #27「记下来的还要判断该不该用」）。
//
//  为什么要有这条判据: 「记对了」和「每轮都该读」是两件事。`.always` 的条目每一轮都进 L0，
//  条目一多就成了"旧信息反复干扰当前判断" —— 而在有读数之前，这件事只能靠感觉。
//
//  它**不是闸**: 超了只出红条，注入照旧（同 `residentOverflow` 的纪律：知识库告警永不阻断任务）。
//
//  两条判据:
//    ① 一条超过建议线的常驻条目 ⇒ 出 `.residentHeavy`，带的是**真数字**（与 `stableChars`
//       同源，不是常量回声）；
//    ② 同样的位置放一条小的 ⇒ 一条都不出（否则红条变噪音，而噪音会被无视 —— 那比不报还坏）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseKnowledgeWeight() async {
        print("== T-KWEIGHT 常驻知识的重量建议条 ==")

        let dir = fixtureDir("kweight")
        /// 单个用例的落盘重定向。⚠️ **两处都要设**: 只设 persona 目录而漏 L1 的话，
        /// `applyKnowledgeChange` 里的 `syncL1Files` 会写进真实家目录（而它零红灯）。
        func freshStore(_ name: String) -> ChatStore {
            let store = ChatStore(transport: MockTransport(), dbPath: dir + "/\(name).db",
                                  managedExtensionsDir: dir + "/ext")
            store.scheduler.stopScheduler()
            store.knowledge.personaPackDirOverride = dir + "/\(name)-pack"
            store.knowledge.l1RootOverride = dir + "/\(name)-l1"
            return store
        }

        // ── ① 重的那一份 ──
        let heavyStore = freshStore("heavy")
        let line = Tune.knowledgeResidentAdviceChars
        let big = String(repeating: "字", count: line + 700)
        _ = heavyStore.addKnowledge(title: "旧项目笔记", content: big, scope: .global, projectId: nil)
        let inj = heavyStore.knowledge.lastInjection
        let heavy = heavyStore.knowledge.injectionWarnings.filter { $0.kind == .residentHeavy }
        let payload: (chars: Int, total: Int)? = {
            guard case .residentHeavy(let c, let t)? = heavy.first else { return nil }
            return (c, t)
        }()
        // 数字必须与**组装结果**同源: `stableChars + volatileChars` 才是"常驻知识条目"，
        // 写死一个常量在这里等于让这条判据自己出题。
        let expected = inj.stableChars + inj.volatileChars
        check(heavy.count == 1 && payload?.chars == expected && expected >= line
              && (payload?.total ?? 0) >= expected,
              "T-KWEIGHT ①常驻知识超过 \(line) 字 ⇒ 出建议条, 且带的是**组装出来的真数字**"
              + " (实测 字 \(payload?.chars ?? -1) / 注入共 \(payload?.total ?? -1) / 组装 \(expected))")

        // ── ② 小的一份: 一条都不出 ──
        let lightStore = freshStore("light")
        _ = lightStore.addKnowledge(title: "一条短规", content: String(repeating: "字", count: 200),
                                    scope: .global, projectId: nil)
        let light = lightStore.knowledge.injectionWarnings.filter { $0.kind == .residentHeavy }
        check(light.isEmpty,
              "T-KWEIGHT ②小条目 ⇒ **不出**这条 (常驻告警本来就够多了; 凑数只会让人开始无视红条)")
    }
}
