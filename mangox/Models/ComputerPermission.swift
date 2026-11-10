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
//  ⚠️ 但**只有两项申请得动**: 辅助功能 `AXIsProcessTrustedWithOptions(prompt:)`、
//     屏幕录制 `CGRequestScreenCaptureAccess()`。
//     **输入监控既申请不了、也不该申请** —— 辅助功能一给, `CGPreflightListenEventAccess()` 就恒
//     返回 true(键盘监听被它涵盖), 系统认为早已具备 ⇒ 系统设置那一页里**没有条目**可给、可撤。
//     2026-11-04 boss 实测: 我们自己那盏灯是绿的, 那一页却写着"无项目"。所以它只能是**说明**,
//     不是第三把钥匙(见 `keys`)。
//
//  ⚠️ 录屏与输入监控**授权后要重启 App 才生效** —— preflight 在同一进程里有缓存, 所以
//     "去系统设置点完、回来点重新检测、灯还是不亮"是**预期**, 不是坏了。技术绕不过去
//     (除非自己重启), 所以只能让文案说清, 不许让灯去猜。
//

import AppKit
import ApplicationServices

/// 系统钥匙。**顺序即显示顺序** —— 按"缺了它最先坏哪件事"排, 不是按弹窗出现的先后排。
/// ⚠️ `allCases` 里是**三个**, 但画成钥匙的只有 `keys` 那**两个**(见 `keys` 的注)。
enum ComputerPermission: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case screenRecording

    var id: String { rawValue }

    /// UI 上**真的画成钥匙**的那两项(顺序即显示顺序)。
    ///
    /// ⚠️ 为什么不是 `allCases`: `inputMonitoring` **不是一把能给的钥匙** —— 辅助功能一给,
    ///    `CGPreflightListenEventAccess()` 就恒 true(键盘监听被它涵盖), 系统设置那一页里
    ///    也就**没有条目**可给、可撤(2026-11-04 boss 实测: 灯是绿的, 那一页"无项目")。
    ///    它还留在 enum 里, 是因为深链 token 与 helper 侧判据都按它走, 删 case 会牵一片;
    ///    但"画成钥匙"是另一件事 —— 那一步是假的, 会让人去追一个不存在的东西。
    static let keys: [Self] = [.accessibility, .screenRecording]

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
            return L("不用单独给。辅助功能一给，键盘监听就有了 —— 所以系统设置那一页里看不到 MangoX，那是正常的，不是漏装。")
        case .screenRecording:
            return L("只有勾了「视觉」的 App 才会截窗口。给完要重启 MangoX 才生效 —— 灯不会当场变, 别以为没给成。")
        }
    }

    /// 未授权时多出来的一句 —— **只有"系统设置里可能压根没有 MangoX"的那一项**才需要。
    ///
    /// 屏幕录制是唯一这样的: 那个列表只收"自己申请过"的 App, 而我们在此之前只 preflight
    /// (只查不弹) ⇒ 用户点「前往系统设置」看到"无项目", 那不是漏装, 是还没登记。
    var manualAddHint: String? {
        switch self {
        case .screenRecording:
            return L("那一页里没有 MangoX？点左下角「+」手动添加，或者点「申请」让我自己登记进去。")
        case .accessibility, .inputMonitoring:
            return nil
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

    /// 主动索要一次。**只在用户点「申请」时调** —— 它会弹系统窗, 不能挂在 `onAppear` 上。
    ///
    /// ⚠️ 屏幕录制**没有"查询即触发"的路**: 只 preflight 的话 MangoX 永远进不了那个列表,
    ///    用户点「前往系统设置」看到的是一页"无项目"(2026-11-04 实测)。`CGRequestScreenCaptureAccess`
    ///    是唯一能让它自己登记进去的调用; 拒绝过之后它只返回 false、不再弹(幂等) ⇒ 重复点不骚扰。
    /// ⚠️ 返回 true 也**不代表灯马上变**: preflight 在当前进程里有缓存(见文件头), 仍要重启 App。
    func request() {
        switch self {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            // 空实现是**有意的**: 辅助功能给了之后这一项系统认为早已具备 —— 调它只返回 true,
            // 不弹窗、不写 TCC、列表里仍然没有条目。真调只会让调用方以为"申请过了"。
            break
        }
    }

    /// 三盏灯一次取完 —— 设置页 `onAppear` / 「重新检测」各调一次, 不在行里调。
    static func snapshot() -> [ComputerPermission: Bool] {
        var out: [ComputerPermission: Bool] = [:]
        for p in allCases { out[p] = p.isGranted }
        return out
    }
}
