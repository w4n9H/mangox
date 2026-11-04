//
//  CaseChatScroll.swift
//  尾部实体化的记账时机（2026-11-04 评审）。
//
//  病根：`scrollToTail` 在 veto 之前就把“尾块已量过”写进账本。
//    用户上滑看历史时，这一拍的滚动被拒绝，账上却已记账 ⇒ 之后点「回到最新」
//    会跳过真实行的实例化，重新落进 `LazyVStack` 的估算高度 = 白屏。
//
//  这条用例守的是两步契约：**候选不记账，执行后才记账**。
//    把 `candidate` 改回“顺手写 lastMaterialized”两条会立刻红。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseChatScroll() async {
        print("== T-CSCROLL 尾部实体化记账时机 ==")

        let a = AnyHashable("tail-a")
        let b = AnyHashable("tail-b")

        let ledger = ChatTailLedger()

        // ① veto 拒绝时不许产生候选。
        check(ledger.candidate(a, allowed: false) == nil,
              "T-CSCROLL 跟随被否决时不许选中尾块")
        check(ledger.lastMaterialized == nil,
              "T-CSCROLL 被否决后账本必须仍为空（先记账再 veto = 白屏回来的那条路）")

        // ② 允许时只返回候选，**不许顺手记账**。
        check(ledger.candidate(a, allowed: true) == a,
              "T-CSCROLL 允许滚动的第一拍先选真实尾块")
        check(ledger.lastMaterialized == nil,
              "T-CSCROLL candidate 只做判断，不改账本（记账必须等滚动真正执行）")

        // ③ 执行后确认，同一个块不再重复实体化。
        ledger.confirm(a)
        check(ledger.lastMaterialized == a,
              "T-CSCROLL 真正滚过之后才记账")
        check(ledger.candidate(a, allowed: true) == nil,
              "T-CSCROLL 已量过的同一尾块不再重复实体化")
        check(ledger.candidate(b, allowed: true) == b,
              "T-CSCROLL 尾块换成新的之后必须重新实体化")

        // ④ 复现原 bug 的时序：先被否决、稍后用户点「回到最新」。
        //    旧写法第一步就记账 ⇒ 第二步拿到 nil，直接锚哨兵。
        let afterVeto = ChatTailLedger()
        _ = afterVeto.candidate(a, allowed: false)
        check(afterVeto.candidate(a, allowed: true) == a,
              "T-CSCROLL 先否决、后允许时仍须实体化尾块")
    }
}
