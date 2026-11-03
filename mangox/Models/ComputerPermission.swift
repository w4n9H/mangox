//
//  ComputerPermission.swift
//  P18 补: 三把系统钥匙的**一处总账**。
//
//  为什么要有它(2026-11-02 boss 的实测反馈): 三把钥匙的申请时机相隔很远 ——
//  输入监控是 helper 一 spawn 就被 `CGEvent.tapCreate` 带出来的, 辅助功能是第一次真去读
//  界面时系统自己弹的, 录屏是第一次截图时。用户看到的是"隔一阵突然又弹一个",
//  而界面上**只有一句**讲辅助功能, 另两把连提都没提 ⇒ 拒绝过一次就永久静默, 无处可查、无处可补。
//
//  ⚠️ 三个 preflight 都**只查不弹**, 这才是它们能挂在视图里随时刷新的原因:
//     `AXIsProcessTrusted()` / `CGPreflightListenEventAccess()` / `CGPreflightScreenCaptureAccess()`。
//     会弹窗的只有两处: ① `CGRequestListenEventAccess()`(输入监控, 只在用户点开关时调一次);
//     ② 系统在**第一次真去用**的时候自己弹(辅助功能由第一次读触发, 录屏由 SCK 触发)。
//
//  ⚠️ 录屏与输入监控**授权后要重启 App 才生效** —— preflight 在同一进程里有缓存, 所以
//     "去系统设置点完、回来点重新检测、灯还是不亮"是**预期**, 不是坏了。技术绕不过去
//     (除非自己重启), 所以只能让文案说清, 不许让灯去猜。
//

import AppKit
import ApplicationServices

/// 三把钥匙。**顺序即显示顺序** —— 按"缺了它最先坏哪件事"排, 不是按弹窗出现的先后排。
enum ComputerPermission: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case screenRecording

    var id: String { rawValue }

    /// 行标题。
    ///
    /// ⚠️ 这几个是**计算属性**不是 `static let`: `L()` 落进 `static let` 只取一次词,
    ///    切语言后这一行会一直停在旧语言(本仓那条"冻结取词"的纪律)。
    var title: String {
        switch self {
        case .accessibility: return L("辅助功能")
        case .inputMonitoring: return L("输入监控")
        case .screenRecording: return L("屏幕录制")
        }
    }

    /// 一句"没给会怎样"。**不许写"权限不足"** —— 那等于什么都没说。
    var consequence: String {
        switch self {
        case .accessibility:
            return L("读任何 App 的界面都靠它。没有它, 读界面会直接报错。")
        case .inputMonitoring:
            return L("开: 你一动键鼠我就停下让路。关着时我不会让路 —— 我正要点一个按钮、你同时动了鼠标, 落到谁手里是随机的。给完权限要重启 MangoX 才生效。")
        case .screenRecording:
            return L("只有勾了「图片」的 App 才会截窗口。给完要重启 MangoX 才生效 —— 灯不会当场变, 别以为没给成。")
        }
    }

    /// 系统设置里那一页的锚。
    ///
    /// ⚠️ `Privacy_` 后面这一段是**契约串**(系统按字面认)。拼错的后果不是报错, 而是
    ///    **静默打开「隐私与安全性」首页** —— 用户在那儿找不到这一项, 只会以为这个功能坏了。
    ///    冒烟逐字钉着(`CaseComputerPure`), 别凭记忆改。
    var paneToken: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "ListenEvent"
        case .screenRecording: return "ScreenCapture"
        }
    }

    var settingsURL: String {
        "x-apple.systempreferences:com.apple.preference.security?Privacy_" + paneToken
    }

    /// 此刻给没给。**只查不弹**。
    var isGranted: Bool {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    /// 三盏灯一次取完 —— 设置页 `onAppear` / 「重新检测」各调一次, 不在行里调。
    static func snapshot() -> [ComputerPermission: Bool] {
        var out: [ComputerPermission: Bool] = [:]
        for p in allCases { out[p] = p.isGranted }
        return out
    }
}
