//
//  LoginItemService.swift
//  P19 S7: 登录项（常驻）—— 助理巡检靠它才谈得上"常驻"。
//
//  ⚠️ **本版对登录项的态度是"能开就开、开不了就说实话"**，不是"必须自启":
//    · ad-hoc 签名下 `SMAppService.mainApp.register()` **可能成功但要求人工批准**
//      （系统设置 → 通用 → 登录项）。那时把开关画成"已开启"就是撒谎；
//    · 失败/待批准都退回同一句真话：**打开 App 才会巡检**（合盖不打开 = 不巡检）。
//  这个降级不是缺陷，是 §03 明知代价的选择：不补一条不可靠的自启路径。
//

import Foundation
import ServiceManagement

enum LoginItemService {

    /// 能注册登录项吗。无 bundle id（CLI 直编 / 冒烟）恒 false —— 与 `CompletionNotifier`
    /// 同一条判据：那种进程里 `Bundle.main.bundleIdentifier` 是 nil，碰系统 API 只会崩或卡。
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    /// 对外只暴露这三个 + 一个"不支持"，**不把 `SMAppService.Status` 漏出这一层**:
    /// 它是系统枚举，用它在视图里做判断就等于把 macOS 的版本差异写进 UI。
    enum State: String, Equatable {
        case off
        case on
        /// 已注册，但系统要求人工批准（ad-hoc 签名下最常见的那一格）。
        case requiresApproval
        case unavailable
    }

    static func state() -> State {
        guard isSupported else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled:          return .on
        case .requiresApproval: return .requiresApproval
        case .notRegistered:    return .off
        default:                return .off     // .notFound 等：按"没开"处理，不假装
        }
    }

    /// 开。返回 nil = 成功；非 nil = 人话的失败原因（**要能直接摆到设置页上**）。
    static func enable() -> String? {
        guard isSupported else { return L("这个构建没有应用标识，不能注册登录项") }
        do {
            try SMAppService.mainApp.register()
        } catch {
            return String(format: L("注册失败: %@"), "\(error.localizedDescription)")
        }
        // 注册成功 ≠ 已在自启：`status` 是唯一的事实（可能立刻就是 requiresApproval）。
        return nil
    }

    /// 关。返回 nil = 成功。
    static func disable() -> String? {
        guard isSupported else { return nil }
        do {
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            // 没注册过时 unregister 也可能抛 —— 那不算失败，状态本来就对。
            if SMAppService.mainApp.status == .notRegistered { return nil }
            return String(format: L("注销失败: %@"), "\(error.localizedDescription)")
        }
    }

    /// 状态 → 一句话。**纯函数**（冒烟判据打在它上面：这一层的分支要不要紧，
    /// 全看这句话有没有把"已开 / 待批准 / 开不了"说成三件不同的事）。
    static func statusText(_ s: State) -> String {
        switch s {
        case .on:
            return L("已随登录启动 —— 合盖休眠期间仍然不跑，唤醒后按漏跑清单补最近一次")
        case .requiresApproval:
            return L("已注册，但系统要求你批准 —— 系统设置 → 通用 → 登录项 → 允许 MangoX")
        case .off:
            return L("未开启 —— 打开 App 才会巡检")
        case .unavailable:
            return L("这个构建不能注册登录项 —— 打开 App 才会巡检")
        }
    }
}
