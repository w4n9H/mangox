//
//  SleepGuard.swift
//  锁屏后的运行方式（2026-10-27，boss 从 WorkBuddy 的设置页拿来的一行）。
//
//  为什么需要：MangoX 的长任务跑在 pi 子进程里，机器一睡，任务就断在半路 ——
//  定时任务到点触发却睡过去了，是最难解释的一种"没跑"。
//
//  ⚠️ 为什么用 `ProcessInfo.beginActivity` 而不是 IOKit 的 `IOPMAssertionCreateWithName`：
//     两者底层是同一条路，但 `beginActivity` **令牌一释放就撤**、**进程退出自动撤**；
//     `IOPMAssertion` 忘了 release 会一直按住（`caffeinate` 子进程漏杀同病）。
//     ⇒ 能用"有生命周期的令牌"就别用"要人工配对的全局状态"。
//
//  ⚠️ 范围（boss 2026-10-27 定）：**只在有回合在途时断言**，不常驻。
//     理由是"保持屏幕常亮"常驻会耗电且容易被忘；而只在跑任务时按住，
//     既省电又没有"我什么时候开过它"的记忆负担。
//     ⇒ 调用点的判据是 `ChatStore.runningTurns`（定时任务也走同一个 turn 集合）。
//
//  ⚠️ 这个断言只作用于**本进程**。pi 子进程锁屏后是否被降频（App Nap / 定时器合并）
//     是另一件事，`beginActivity` 管不到 —— 要实测：起长任务 → 锁屏 → 看日志时间戳间隔。
//

import Foundation

/// 锁屏后的运行方式三档。
///
/// ⚠️ `rawValue` 是**落库标识**（小写英文），不是显示文案 —— 显示走 `label`。
/// 与 `SettingsCategory`（rawValue = 中文、直接当词表 key）**有意不同**：那个不落库，
/// 这个要写进 settings 表；一旦拿中文当键，**改一次文案就静默丢掉所有人的设置**。
enum LockScreenMode: String, CaseIterable, Identifiable {
    case off     = "off"
    case dimming = "dimming"
    case glowing = "glowing"

    var id: String { rawValue }

    /// 显示文案（中文原文即词表 key，英文界面查表换成译文）。
    /// ⚠️ 必须是**计算属性** —— 写成 `static let` 会只在首次求值取一次词，
    ///    切语言后这一栏不跟着变（本地化坑 ⑨）。
    var label: String {
        switch self {
        case .off:     L("不保持唤醒")
        case .dimming: L("熄屏后保持唤醒")
        case .glowing: L("保持屏幕常亮")
        }
    }

    /// 缺省 / 未知值 → `.dimming`。
    ///
    /// 为什么不缺省成 `.off`：断言**只在任务在途时**才持有，所以 dimming 的代价是
    /// "跑任务那几个分钟机器不睡"，几乎为零；而选择 off 的代价是**任务被打断**。
    /// 出厂默认取"更少出事故"的一侧（同 `layer` 缺省取 `.always` 那条判据）。
    static func resolve(_ stored: String?) -> LockScreenMode {
        guard let stored, let hit = LockScreenMode(rawValue: stored) else { return .dimming }
        return hit
    }
}

/// 持有 / 释放"别睡"的断言。
///
/// 判据：`apply` 必须**幂等** —— `runningTurns` 每次变动都会调它（并发任务进出频繁），
/// 每次都重建令牌等于每回合刷新一次系统断言，而且中间会有一个"空窗期"真的放开。
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()

    /// 上一次算出来的状态（含"不该持有"），用来判"要不要动"。
    private var active: (mode: LockScreenMode, holding: Bool)?
    private var token: NSObjectProtocol?

    private init() {}

    /// 按 `(模式, 是否有任务在跑)` 收敛到目标状态。
    func apply(mode: LockScreenMode, busy: Bool) {
        let shouldHold = busy && mode != .off
        if let active, active.mode == mode, active.holding == shouldHold { return }
        release()
        active = (mode, shouldHold)
        guard shouldHold else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: SleepGuard.options(for: mode),
            // reason 会进系统日志（`pmset -g assertions` 也读得到）⇒ 用英文短句。
            reason: "MangoX: agent turn in flight")
    }

    /// 三档 → 断言选项。**纯函数**，冒烟可断言（`apply` 会真按住系统，只能在真机上验）。
    nonisolated static func options(for mode: LockScreenMode) -> ProcessInfo.ActivityOptions {
        switch mode {
        case .off:     []
        case .dimming: [.idleSystemSleepDisabled]
        case .glowing: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled]
        }
    }

    private func release() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
}
