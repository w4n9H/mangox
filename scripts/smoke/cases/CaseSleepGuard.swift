//
//  CaseSleepGuard.swift
//  锁屏运行三档 → 休眠断言选项（2026-10-27）
//
//  为什么这几条必须钉住: `ProcessInfo.ActivityOptions` 写错**一个 flag 都不报错** ——
//  把「保持屏幕常亮」写成只有 `.idleDisplaySleepDisabled` 时, 系统仍然会睡,
//  表面上"设置生效了"（下拉选得中、状态记得住、`pmset -g assertions` 甚至能看到一条),
//  只有锁屏跑一个长任务才会发现任务被腰斩。这类"看起来对"的开关必须靠断言守。
//
//  ⚠️ 这里只测**纯函数**（`SleepGuard.options(for:)`）。`apply` 会真的按住本机 → 会污染
//  跑冒烟那台机器, 而且断言一持有, 后续用例的定时行为都变了。真机验证靠锁屏实测。
//
//  能变红的点:
//    · 让 `glowing` 少给 `.idleSystemSleepDisabled`（只剩防熄屏, 系统照样睡）;
//    · 让 `dimming` 顺手带上 `.idleDisplaySleepDisabled`（"熄屏"档却不让熄屏）;
//    · 三档里有任意两档映射成同一个集合（下拉变成了装饰品）;
//    · 有人把 `rawValue` 改成中文文案 —— 落库键变文案, 改一次措辞就丢所有人的设置。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSleepGuard() async {
        print("== T-SLEEP 锁屏运行的休眠断言 ==")

        let off     = SleepGuard.options(for: .off)
        let dimming = SleepGuard.options(for: .dimming)
        let glowing = SleepGuard.options(for: .glowing)

        // ① 关闭 = 一条都不给（否则"关闭"名不副实）
        check(off.isEmpty, "T-SLEEP 关闭档不持有任何断言 (实测 \(off.rawValue))")

        // ② 熄屏后保持唤醒 = 系统不睡, 但**允许熄屏**
        check(dimming.contains(.idleSystemSleepDisabled),
              "T-SLEEP 熄屏档必须防系统睡眠 (实测 \(dimming.rawValue))")
        check(!dimming.contains(.idleDisplaySleepDisabled),
              "T-SLEEP 熄屏档**不许**防熄屏 (实测 \(dimming.rawValue))")

        // ③ 保持屏幕常亮 = 两条都要
        check(glowing.contains(.idleSystemSleepDisabled) && glowing.contains(.idleDisplaySleepDisabled),
              "T-SLEEP 常亮档必须同时防睡眠与防熄屏 (实测 \(glowing.rawValue))")

        // ④ 三档两两不同 —— 否则下拉里有选项是摆设
        check(off != dimming && dimming != glowing && off != glowing,
              "T-SLEEP 三档必须互不相同 (\(off.rawValue) / \(dimming.rawValue) / \(glowing.rawValue))")

        // ⑤ 缺省与未知值都落到 .dimming（出厂取"更少出事故"的一侧）
        check(LockScreenMode.resolve(nil) == .dimming, "T-SLEEP 无存值 ⇒ 缺省熄屏保持唤醒")
        check(LockScreenMode.resolve("garbage") == .dimming, "T-SLEEP 未知存值 ⇒ 回落缺省")
        check(LockScreenMode.resolve("glowing") == .glowing, "T-SLEEP 存值往返")

        // ⑥ 落库键必须是稳定标识, 不许是文案（文案会改, 改了就静默丢设置）
        for mode in LockScreenMode.allCases {
            let raw = mode.rawValue
            check(!raw.isEmpty && raw == raw.lowercased() && raw.unicodeScalars.allSatisfy { $0.isASCII },
                  "T-SLEEP 落库键必须是小写 ASCII 标识 (实测「\(raw)」)")
        }
        // 反例口径: 显示文案是中文 ⇒ 上面那条如果没跑, 中文档位一定是"文案当键"
        check(LockScreenMode.allCases.contains { $0.label != $0.rawValue },
              "T-SLEEP 存在与 rawValue 不同的显示文案 ⇒ 文案确实没被当键用")
    }
}
