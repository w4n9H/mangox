//
//  CaseFoldRule.swift
//  工具行的**折叠时机**（2026-10-21，boss 第三次报「回车后整个对话框白屏」）。
//
//  曾经：一组只要后面又出现了一组就折 —— 也就是**用户回车的那一刻**折。
//  那一拍同时发生两件事：上一组的工具行塌成一行收据（内容高度骤降）、插入一条新用户消息。
//  而同一拍的 `scrollTo(anchor: .bottom)` 正按 `LazyVStack` 的**估算**文档高定位，
//  估算当场放大到 3 倍（`documentView` 32,389 → 93,333）⇒ 视口落到内容之外 ⇒
//  整屏只剩底色（像素实测：主色 #EEEEEE 占 95~100%、暗像素 0.00%、底空 538.5pt = 整个视口），
//  窄栏下不复原，白到 LLM 吐第一个字为止。
//
//  修法 = 把那一拍让开：最后一组还是**光秃秃一条用户消息**时，上一组先保持展开。
//
//  ⚠️ 这条断言守的正是那个 bug：把 `ChatFoldRule.keepOpen` 里第二行去掉，
//     "T-FOLD 等回答那一拍不折" 立刻变红（本轮反例实测：旧行为 4 次里 2 次白屏，
//     带这条判据的实现 10 次 0 白屏）。判据住进纯函数就是为了这一步能进仓库 ——
//     像素探针（`/tmp/blank-probe`）不进仓库，光靠它等于没门。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseFoldRule() async {
        print("== T-FOLD 折叠时机 ==")

        // 最后一组永不折叠（P11 之前就有的规矩：它正在跑 / 刚答完还没被顶走）
        check(ChatFoldRule.keepOpen(index: 2, count: 3, tailIsLoneUserRow: false),
              "T-FOLD 最后一组永不折叠 (它是唯一还要盯着看的那一组)")
        check(ChatFoldRule.keepOpen(index: 0, count: 1, tailIsLoneUserRow: false),
              "T-FOLD 只有一组时也不折叠")

        // 等回答那一拍：上一组也先原样 —— 这条就是白屏的修法
        check(ChatFoldRule.keepOpen(index: 1, count: 3, tailIsLoneUserRow: true),
              "T-FOLD 最后一组还是一条光秃秃的用户消息时, 上一组这一拍不折 "
              + "(折它 = 白屏引信: 估算文档高当场放大 3 倍)")

        // 只让**紧邻**那一组, 不许把整段历史都撑开
        check(!ChatFoldRule.keepOpen(index: 0, count: 3, tailIsLoneUserRow: true),
              "T-FOLD 只推迟紧邻的那一组, 更早的组照常折叠")
        check(!ChatFoldRule.keepOpen(index: 1, count: 4, tailIsLoneUserRow: true),
              "T-FOLD 组数更多时同样只推迟倒数第二组")

        // 首 token 一回来, 折叠照原样发生（否则列表会越用越长）
        check(!ChatFoldRule.keepOpen(index: 1, count: 3, tailIsLoneUserRow: false),
              "T-FOLD 最后一组长出行来之后, 上一组必须折 (不折 = 列表只增不减)")
    }
}
