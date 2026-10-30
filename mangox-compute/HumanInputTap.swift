//
//  HumanInputTap.swift
//  P18 批 3b: "人在动键鼠吗" —— 用 `CGEventTap` **只看, 不注入**。
//
//  三个必须写下来的理由:
//   ① **为什么单独一条线程 + 自己的 run loop**: helper 的主线程**阻塞在 `accept()`** 上,
//      一个 loop 都不跑(它与 `runningApp` 那条教训同一个根: 裸进程没有 run loop)。
//      tap 完全靠 run loop 驱动 ⇒ 挂在主线程上它一个事件都收不到, 而且**不会有任何报错**。
//   ② **为什么 `options: .listenOnly`**: 我们要的是"看见人动了", 不是"接管输入"。listenOnly
//      的 tap 不能改事件、不能吞事件 —— 哪天回调里写错了, 最坏结果是"没看见", 绝不会是
//      "把用户的按键吃了"。(它与 `run.sh` ③s 那条"不许注入"是同一个取向。)
//   ③ **为什么 `mouseMoved` 不算接管**: 光标会因为手搭在触控板上、桌面抖动而一直动;
//      把它算进来 ⇒ 人只要没把手拿开, 模型就永远动不了, 而人其实什么都没接管。
//      算接管的是**表态性**的输入: 按下 / 抬起 / 打字 / 滚动 / 修饰键 / 拖动。
//

import ApplicationServices
import Foundation

final class HumanInputTap {

    static let shared = HumanInputTap()

    /// env 键: 只有 App 判定"这一档有人在"时才下发(`ApprovalMode.expectsHumanAtKeyboard`)。
    /// ⚠️ 跨 target 契约串, `run.sh` ③j 钉着两侧。
    static let envKey = "MANGOX_COMPUTE_TAKEOVER"

    /// 算作"人在接管"的事件。**不含 `mouseMoved`** —— 见文件头 ③。
    static let interest: CGEventMask = {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .keyDown, .keyUp, .flagsChanged, .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { mask, t in
            mask | (CGEventMask(1) << CGEventMask(t.rawValue))
        }
    }()

    private let lock = NSLock()
    private var lastAt: TimeInterval?
    private var rearmed = 0
    private var port: CFMachPort?
    private var didStart = false

    /// 键盘事件到底看不看得见。**缺"输入监控"权限时系统只把鼠标事件喂给 tap**,
    /// 那时 tap 照样"装上"了、鼠标照样能看见 ⇒ 只说"你一动键盘我就让路"就是回执在编事实。
    private(set) var keyboardVisible = false

    private init() {}

    var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return port != nil
    }

    var lastHumanInputAt: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastAt
    }

    /// 被系统踢掉之后重装了几次 —— 真机上唯一能看出"自检重装"还活着的地方。
    var rearmCount: Int {
        lock.lock(); defer { lock.unlock() }
        return rearmed
    }

    func noteHumanInput(at t: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        lastAt = t
        lock.unlock()
    }

    /// 装监听。**返回 false 不是错误**, 是"这一半能力没有"(调用方要如实转述)。
    @discardableResult
    func start() -> Bool {
        lock.lock()
        if didStart {
            let installed = port != nil
            lock.unlock()
            return installed
        }
        didStart = true
        lock.unlock()

        // 先问"键盘听不听得见": 没有输入监控权限时 tap 仍能建、鼠标仍能看, 唯独键盘是空的。
        // 不查它, 回执就会替系统许诺一件它没做到的事。
        keyboardVisible = CGPreflightListenEventAccess()

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: Self.interest,
                                          callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }

        lock.lock()
        port = tap
        lock.unlock()

        // 等它**真的启用**再返回: 否则这一轮第一次 act 可能赶在 tap 生效之前, 判据拿不到事实
        // (再看 `start` 的返回值 —— 那时它已经在说"装上了")。
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "mangox.compute.human-tap"
        thread.stackSize = 512 * 1024
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        return true
    }

    /// 重装。**必须能从回调里调** —— 系统踢掉 tap 时只发一个"我被禁用了"的事件,
    /// 不在这里重装 ⇒ 从那一刻起"人有没有动"永远答"没有" ⇒ 接管这道门**静默消失**,
    /// 而门禁里没有一条断言看得到真机上的 tap 状态。
    fileprivate func rearm() {
        lock.lock()
        let tap = port
        rearmed += 1
        lock.unlock()
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// ⚠️ 回调是 **C 函数指针**, 不能捕获上下文 ⇒ 状态一律经 `userInfo` 传 `self`。
    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<HumanInputTap>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            me.rearm()
            return Unmanaged.passUnretained(event)
        }
        me.noteHumanInput()
        // listenOnly ⇒ 返回值被忽略; 原样递回去, 不改变任何事件。
        return Unmanaged.passUnretained(event)
    }
}
