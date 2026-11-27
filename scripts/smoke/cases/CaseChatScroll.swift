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

        // ⑦ 看门狗：四拍打完读数还不可信就继续追（2026-11-25，`mangox-20261125-155126.log`）。
        //
        // 病根不是"动作错"而是"**时机**错"：`ChatFollowBeats` 到 0.30 秒收手，而那一刻
        // 滚动容器正处在过渡态 —— 同一份日志里 `doc` 被量成 158 / 453 / 1892（真实 8000+），
        // 之后 7.4 / 13.6 / 22.6 秒才出现可信读数。boss 那两次都是靠外力救回来的（切会话 / 滚轮），
        // 而 `switch-conv` 与 `follow` 走的是同一条 `scrollToTail` ⇒ 补的是**时机**。
        //
        // ⚠️ 三条正例各自针对一个**不同**的失败形态（文档塌陷 / 欠冲 / 越界半白），
        //    三个反例各自对应一个**会误伤**的简化写法（见下）。
        let W = ChatFollowWatchdog.self

        // 正例① 文档塌陷（16:29:56 现场原数）。`bottom=813 > doc=453` —— 探针也跟着缩到一行高，
        // 所以"内容底还在视口里"这句话不能用来反驳它：两个读数是一起错的。
        check(W.needsRetry(doc: 453, vp: 902, gap: -397, bottom: 813,
                           probeAgeMs: 1886, peak: 2162),
              "T-CSCROLL 文档塌成一行高(453 vs 峰值 2162)时必须继续追")

        // 正例② 欠冲（17:11:54 现场原数）：doc 正常、峰值也正常，只有 gap 406 说了实话。
        check(W.needsRetry(doc: 5214, vp: 754, gap: 406, bottom: 665,
                           probeAgeMs: 1_851_189, peak: 5214),
              "T-CSCROLL 欠冲超过半屏时必须继续追 (与塌陷是两条独立的路)")

        // 正例③ 越界半白（17:12:01 现场原数）：gap=0 说"贴底了"，而新鲜探针说内容底只到
        // 视口 438/754 处 ⇒ 底部空 316pt。只信 gap 的写法会漏掉这一种。
        check(W.needsRetry(doc: 2951, vp: 754, gap: 0, bottom: 438,
                           probeAgeMs: 2, peak: 2951),
              "T-CSCROLL 视口越过内容底(内容底只到 438/754)时必须继续追, 哪怕 gap 读作 0")

        // 正例④ 探针**一次都没报过**（2026-11-27 现场原数，
        // `mangox-20261127-092811.log` 開屏 1023 条消息）。
        //
        // 那次的日志是一条完整的"判绿收手"链:
        //   `mat=1 msgs=1023` → 四拍全 `bottom=0 age=na` → `retry step=0 gap=3107` →
        //   重试落到 `gap=0` → `.settle gap=0`，然后屏幕整块是底色（boss 截图）。
        // ①②③ 都接不住: ①`doc == peak` 不塌、②`gap` 归零后不再超限、
        // ③ 的前置就是 `bottom > 0`（把"从没报过"排除在外）。
        // ⚠️ 这一条判的是"内容底探针从未实例化"，**不是**"内容底在 0 处" —— 前提是
        //    `probeAgeMs == nil`（`lastBottomAt` 的初值，见 `ChatView` 里那段注释）。
        check(W.needsRetry(doc: 40192, vp: 754, gap: 0, bottom: 0,
                           probeAgeMs: nil, peak: 40192),
              "T-CSCROLL 内容底探针从没报过(bottom=0 age=na)而文档比视口长时, 必须继续追 "
              + "—— 这是唯一一种'几何读数全绿、屏幕全空'的组合, 漏掉它就只能靠切会话救")

        // 反例④ 内容**不满一屏**的短会话: `doc` 有值但比 `vp` 小，探针同样"从没报过" ⇒ **不许**追。
        // 拦的是"只判 `probeAgeMs == nil` 而丢掉 `doc > vp`"那个简化写法 ——
        // 少了这半个条件，每一个内容不满一屏的会话都会被看门狗追满五拍（0.6~6.0 秒）。
        //
        // ⚠️ 这条**必须**用 `doc > 0 且 doc < vp`，不能用 `doc: 0`：`needsRetry` 开头有
        //    `guard vp > 0, doc > 0`，`doc: 0` 在进门就被挡掉 ⇒ 那条反例对"去掉 doc > vp 的简化"
        //    毫无区分度（2026-11-27 实测：喂 doc 0 时那个简化照样全绿，反例是假门）。
        check(!W.needsRetry(doc: 400, vp: 754, gap: -354, bottom: 0,
                            probeAgeMs: nil, peak: 400),
              "T-CSCROLL 内容不满一屏(doc 400 < vp 754, 探针也没报过)不许追 "
              + "—— 判据必须同时要求 doc 比视口长, 只判 age==nil 会把每个短会话追五遍")

        check(!W.needsRetry(doc: 3053, vp: 754, gap: 0, bottom: 666,
                            probeAgeMs: 100, peak: 3053),
              "T-CSCROLL 贴底且探针新鲜时不许再追 (追了就是每秒抖一次)")

        // 反例② **短会话装得下**：`doc < vp` 是正常的。如果谁把判据简化成 `doc < vp`，
        // 每个新建会话都会被追五遍 —— 这条就是拦那个简化的。
        check(!W.needsRetry(doc: 453, vp: 902, gap: -449, bottom: 400,
                            probeAgeMs: 50, peak: 453),
              "T-CSCROLL 短会话(doc 比视口还小但没有塌陷史)不许判成塌陷")

        // 反例③ 探针**陈旧**时不许拿它定罪：`age` 决定 `bottom` 还能不能当证据
        // （那三段空白里 `age` 一度是 1_851_189ms = 30 分钟前的读数）。
        check(!W.needsRetry(doc: 3000, vp: 754, gap: 100, bottom: 300,
                            probeAgeMs: 60_000, peak: 3000),
              "T-CSCROLL 探针陈旧时不许用 bottom 判越界 (30 分钟前的读数会一直说白)")

        // 节拍：必须在四拍（0.30 秒）之后才开始，且递增 —— 否则和复核拍抢同一帧。
        check(W.retryPlan.first! > ChatFollowBeats.plan.last!,
              "T-CSCROLL 看门狗首拍必须晚于复核末拍(0.30s), 否则和它抢同一帧")
        check(zip(W.retryPlan, W.retryPlan.dropFirst()).allSatisfy { $0 < $1 },
              "T-CSCROLL 看门狗节拍必须递增(退避), 不许固定间隔猛刷")
    }
}
