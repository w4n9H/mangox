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

        // ⑤ 同帧合并只留"更响亮的意图"（2026-11-06，`mangox-20261106-084658.log`）。
        //
        // 病根: 换会话时 `selectedConversationId` 与 `messagesRevision` 各发一次跟随请求
        // （实测相隔 1~24ms），后一次 `followEpoch += 1` 把前一次的**复核拍全部作废**
        // —— 六次换会话，六次都只落了第一拍。而 0.1.27 治白屏靠的就是复核拍。
        // ⇒ 两条必须合并成一拍，且留下的是**不吃 nearBottom 守卫**的那一个（换会话必须滚）。
        check(ChatView.followRank("follow") < ChatView.followRank("switch-conv"),
              "T-CSCROLL 普通跟随的优先级必须低于换会话 (否则换会话会被 nearBottom 拦住)")
        check(ChatView.followRank("send") == ChatView.followRank("switch-conv"),
              "T-CSCROLL 提交与换会话同级 (都不吃 nearBottom 守卫)")
        check(ChatView.mergeFollowOrigin(pending: "switch-conv", incoming: "follow") == "switch-conv",
              "T-CSCROLL 换会话排着队时, 后到的流式跟随**不许**把意图降级 (降级 = 复核拍重新被作废)")
        check(ChatView.mergeFollowOrigin(pending: "follow", incoming: "switch-conv") == "switch-conv",
              "T-CSCROLL 普通跟随排着队时, 换会话必须把意图升上去")
        check(ChatView.mergeFollowOrigin(pending: "", incoming: "follow") == "follow",
              "T-CSCROLL 队列空时直接接受来者")

        // ⑥ 回车那一拍**不许锚流式指示器**（2026-11-09，`mangox-20261109-142845.log`）。
        //
        // 现场: 1015 条消息的长会话里回车 → 白屏 → 滚轮才恢复。日志里第 1~4 拍全锚指示器,
        // 落点读回 `doc=38797`；8 秒后同一份文档被量成 `doc=182609`（4.7 倍），而那 8 秒里
        // `msgs` 一直是 1015 —— 回车后一个 chunk 都还没来, 指示器下面没有内容可锚 ⇒
        // `scrollTo` 只能吃懒栈的**估算**总高, 视口落进还没实例化的一段（屏幕全空）。
        // ⚠️ 这一条**只能**由这里守: 白屏不崩不报错, 几何判据也全是正常的（`gap`/`doc`
        //    是同一次估算算出来的, 自己证明自己）—— 长会话里才发作, 短会话里永远看不见。
        check(ChatView.followTarget(origin: "send", isStreaming: true) == ChatView.tailAnchor,
              "T-CSCROLL 回车那一拍要锚末尾哨兵, 不许锚流式指示器 (那一刻它还没有内容可锚; "
              + "锚它 = 按估算的文档高落进空白区 = 白屏, 且几何判据全绿)")
        check(ChatView.followTarget(origin: "follow", isStreaming: true) == ChatView.streamingAnchor,
              "T-CSCROLL 真正流式跟随时仍然锚流式指示器 (它会把前面的行量出来, 落点是真的)")
    }
}
