//
//  ComputerShot.swift
//  mangox-compute (P18 批 3c): 图像面 —— 读的**第二种表示**。
//
//  为什么需要它: 有些 App 的 AX 树薄得只剩窗口外壳(微信 1052×754 只暴露 6 个节点),
//  文本读一百次也读不出消息正文。这时唯一能给的兜底就是"让我看一眼"。
//
//  ⚠️ 图像是**只读**的, 而且永远进不了动作面: 像素里没有编号 ⇒ `act` 那三条恒拒判的是
//     **元素**, 图里根本没有元素可判。这一层不参与授权判断, 只负责"看清楚"。
//
//  ⚠️ 判据不在这个文件里 —— 名单匹配与输出尺寸都住在 `mangox/Models/ComputerShotRule.swift`,
//     因为冒烟只编译 `mangox/` 下的源码, 住在这里的判据一条都断言不了。这里只做 IO。
//
//  ⚠️ **这里不涂黑任何东西**(2026-10-30 boss 定, 见 `ComputerShotRule` 文件头两条理由):
//     密码框自己就渲染成圆点, 黑块只遮住长度; 而黑块一旦落错位置, 整张图就废了, 且零报错。
//     遮蔽只留在文本层。
//
//  ⚠️ 截图走 ScreenCaptureKit 而不是 `CGWindowListCreateImage`: 后者在 macOS 14.0 起
//     被标记弃用, 一调用就是编译警告, 而本项目的门禁要求 **0 warning**(实测确认过)。
//

import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ComputerShot {

    /// 拍一张。成功返回 PNG 字节; 失败返回**人话**(由调用方原样回给模型)。
    ///
    /// 失败原因按"模型下一步该做什么"分类, 不合并:
    ///   ① 没有屏幕录制权限 ⇒ 让用户去系统设置(唯一一条**只能由人**解开的)
    ///   ② 找不到窗口 / 拍失败 ⇒ 报告, 别重试
    ///
    /// ⚠️ "没在名单里"**不在这里判**: 那是 App 层的授权判断, 由 `ComputerServer.finishRead`
    ///    先拦(它还负责在"没开图片"时仍把文本交回去)。
    static func capture(pid: pid_t, root: AXNode, bundle: String)
        -> Result<Data, ComputerShotRule.ShotFailure> {
        guard let window = root.frame else {
            return .failure(ComputerShotRule.ShotFailure(
                "这个窗口没有几何信息 ⇒ 我不知道要拍多大一块, 就不拍了。"
                + "这一页只能靠文本读, 读不出的话只能请用户自己看一眼。"))
        }
        guard let wid = windowID(pid: pid, frame: window) else {
            // ⚠️ 带插值的串**不会**被隐式转成 `ShotFailure`(它不是裸字面量) ⇒ 显式包一层。
            return .failure(ComputerShotRule.ShotFailure(
                "找不到「\(bundle)」的窗口编号 ⇒ 拍不了"
                + "(它可能刚最小化, 或者被别的窗口挡住)。"))
        }
        // ⚠️ 输出尺寸**不能**用 AX 的窗口框: 截图尺寸由 SCK 那边的 `SCWindow.frame` 决定,
        //    两者差一个标题栏的话, 我按 AX 框设宽度 ⇒ SCK 会**非等比缩放**把图塞进这个尺寸
        //    ⇒ 整个画面变形。尺寸一律以 `SCWindow.frame` 为准。
        switch shoot(windowID: wid) {
        case .failure(let why):
            return .failure(why)
        case .success(let image):
            return encode(image)
        }
    }

    /// 屏幕录制权限 —— **另一份 TCC**, 与辅助功能不共享。
    ///
    /// ⚠️ helper 是裸可执行, 这项权限按 **responsible process(MangoX)** 记账, 所以用户要
    ///    授权的是 MangoX, 不是 helper。`CGPreflightScreenCaptureAccess` 只查询、不弹窗。
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 按 pid + 窗口几何找 `CGWindowID`。SCK 只认窗口编号, 而 AX 树只给 frame。
    ///
    /// 容差 2px(四边之和): AX 与 CGWindow 的坐标偶尔差一像素(阴影 / 圆角), 卡死会**永远**
    /// 找不到窗口 —— 而那种失败在回执里长得和"窗口真的不在"一模一样。
    static func windowID(pid: pid_t, frame: AXRect) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: (id: CGWindowID, delta: Int)?
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let bx = bounds["X"] as? CGFloat, let by = bounds["Y"] as? CGFloat,
                  let bw = bounds["Width"] as? CGFloat, let bh = bounds["Height"] as? CGFloat
            else { continue }
            let delta = abs(Int(bx) - frame.x) + abs(Int(by) - frame.y)
                + abs(Int(bw) - frame.w) + abs(Int(bh) - frame.h)
            guard delta <= 2 else { continue }
            if best == nil || delta < best!.delta { best = (number, delta) }
        }
        return best?.id
    }

    // MARK: - SCK 桥

    /// 同步拍一张。helper 的 socket 循环是同步的, 而 SCK 只有 async API。
    ///
    /// ⚠️ **实测过**: 这个"主线程 `sem.wait()` + `Task.detached`"的写法在裸可执行里不会死锁
    ///    (权限缺失时能正常抛出 TCC 错误)。如果哪天 SCK 改成必须回主队列, 表现会是**整个
    ///    helper 卡死**而不是报错 —— 那时得把 accept 循环挪到后台线程。
    ///
    /// ⚠️ 只截**那一个窗口**(`desktopIndependentWindow`), 不是整个屏幕: 桌面、别的窗口、
    ///    壁纸都不在过滤器里。窗口被别的窗口挡住也照样拍得到 —— 取的是它自己的表面。
    private static func shoot(windowID: CGWindowID)
        -> Result<CGImage, ComputerShotRule.ShotFailure> {
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        Task.detached(priority: .userInitiated) {
            // ⚠️ 单出口: 每加一个分支就多一处可能漏 `signal()` 的地方, 而漏了的表现是
            //    **helper 整个卡死**而不是报错 —— 那种故障在现场极难归因。
            defer { sem.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true)
                guard let win = content.windows.first(where: { $0.windowID == windowID }) else {
                    box.result = .failure("窗口在屏幕列表里消失了(刚关掉或被最小化) ⇒ 拍不了。")
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let size = ComputerShotRule.captureSize(window: axRect(win.frame))
                let config = SCStreamConfiguration()
                config.width = size.width
                config.height = size.height
                config.showsCursor = false
                // 阴影不属于窗口内容, 留着会给四周加几十像素透明边 ⇒ 图看着像"窗口漂在一个
                // 透明底上"。单窗口过滤器里这条是必须的, 不是美观问题。
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                box.result = .success(image)
            } catch {
                // 没权限时 SCK 抛的就是这句("用户拒绝了…捕捉的TCC") ⇒ 换成带指引的人话。
                box.result = .failure(ComputerShotRule.ShotFailure(screenRecordingGranted()
                    ? "截图失败: \(error.localizedDescription) ⇒ 这次没有图, 别重试。"
                    : "屏幕录制权限还没给 ⇒ 拍不了。请到 系统设置 › 隐私与安全性 › 屏幕录制 "
                      + "里勾上 MangoX, 然后重开 MangoX(改这项要重启才生效)。"))
            }
        }
        sem.wait()
        return box.result ?? .failure("截图没有返回结果(内部错误) ⇒ 这次没有图。")
    }

    /// `CGRect` → `AXRect`(四舍五入)。只用在"算输出尺寸"这一处。
    private static func axRect(_ r: CGRect) -> AXRect {
        AXRect(x: Int(r.origin.x.rounded()), y: Int(r.origin.y.rounded()),
               w: Int(r.width.rounded()), h: Int(r.height.rounded()))
    }

    /// `Result` 的容器 —— 跨线程传回一个值, 只写一次再读一次。
    private final class Box: @unchecked Sendable {
        var result: Result<CGImage, ComputerShotRule.ShotFailure>?
    }

    /// 编成 PNG。
    ///
    /// ⚠️ 这里**只编码, 不重绘**: 之前为了填黑块要新建一块 `CGContext` 把图画进去, 现在没有
    ///    黑块了, 直接交给 `CGImageDestination` —— 少一次全画布拷贝(2K 窗口约 20MB),
    ///    也少一处"画布建不出来"的失败分支。
    private static func encode(_ image: CGImage) -> Result<Data, ComputerShotRule.ShotFailure> {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            return .failure("图处理失败(建不了 PNG 容器) ⇒ 这次没有图。")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            return .failure("图处理失败(PNG 编码) ⇒ 这次没有图, 别重试。")
        }
        return .success(data as Data)
    }
}
