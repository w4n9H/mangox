//
//  CaseFollowBeats.swift
//  「滚到底」的**复核拍**（2026-10-21，boss 第三次报「回车后整个对话区白屏」）。
//
//  病根不是"滚得不够远"，而是**一次落点不可信**：
//    `scrollTo(anchor: .bottom)` 的目标位置按 `LazyVStack` 的**估算**文档高算 —— 同一份数据
//    （794 事件 / 795 条消息的真实会话）实测读出过 32,547 与 68,924 两种值（≈2 倍，6 次里 5 次是
//    翻倍那个）。翻倍那次跟随落地的几帧里视口 **100% 纯底色 / 0% 墨迹**（整片白），滚动条却在轨道底。
//    紧跟一拍就会重排一遍、内容立刻回来（+0.05s 全白 → +0.08s 恢复）。
//  ⇒ 能守住的判据只有一条：**拍数 ≥ 2**（落一次 + 至少复核一次）。
//
//  ⚠️ 这条断言看着"只是在数常量"，它守的正是被修掉的那个 bug：
//     把 `ChatFollowBeats.plan` 改回 `[0]` 就是 0.1.27 之前的样子 —— 白屏会一直亮到 llm 返回。
//     实测依据与四个入口（初屏 / 换会话 / 提交跟随 / 回到最新）都写在 `ChatView.scrollToTail`。
//
//  ⚠️ 用例结尾**不许**调 `report()`: 它是"收尾 + exit", 只属于整个 run 的末尾。
//     写在这里会让 `registeredCases` 从这一行起**被静默截断**（本轮实测：后面的 T-FOLD 一条没跑，
//     而日志照样 "ALL PASS"）。现在就由 `casesRemaining` 那道兜底把它变成红灯。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseFollowBeats() async {
        print("== T-FOLLOW 滚到底的复核拍 ==")

        let beats = ChatFollowBeats.plan
        check(beats.count >= 2,
              "T-FOLLOW 落完必须复核: 拍数 = \(beats.count) (≥2; 只有一拍 = 白屏会一直亮到下一帧有内容)")
        check(beats.first == 0,
              "T-FOLLOW 第一拍必须立刻落 (实测首拍若延后, 视口先停在新内容之外再跳)")
        check(zip(beats, beats.dropFirst()).allSatisfy { $0 < $1 },
              "T-FOLLOW 拍序严格递增 (实测 \(beats.map { String(format: "%.2f", $0) }.joined(separator: "/")))")
        check((beats.last ?? 1) <= 0.5,
              "T-FOLLOW 复核窗口有界: 末拍 \(String(format: "%.2f", beats.last ?? -1))s ≤ 0.5s —— "
              + "再长就会和 P9-#9「上滑阅读不拽回」抢")
        check(beats.allSatisfy { $0 >= 0 && $0 <= 0.5 },
              "T-FOLLOW 每一拍都落在 [0, 0.5] 内 (负值会变成同步阻塞, 超界会跨回合)")
    }
}
