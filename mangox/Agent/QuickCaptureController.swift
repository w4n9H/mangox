//
//  QuickCaptureController.swift
//  P8-T27 Alt+X Spotlight 式捕获条: Carbon RegisterEventHotKey (无需辅助功能权限)
//  + 独立 NSPanel (floating, 无标题栏, 居中偏上 1/3)。v1 限定 App 进程存活期。
//  发送语义见 ChatStore.submitCapture (无人值守 + Minimal 强制 + 即发即跑)。
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 可成为 key window 的无边框面板 (TextField 接收输入的前提)。
final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class QuickCaptureController {
    static let shared = QuickCaptureController()

    private weak var store: ChatStore?
    private var panel: NSPanel?
    private var hotkeyRef: EventHotKeyRef?
    private var clickMonitors: [Any] = []
    private var handlerInstalled = false
    private(set) var registeredHotkey: CaptureHotkey?

    /// App 启动挂接 (ContentView.onAppear; store 由主视图持有)。
    func install(store: ChatStore) {
        self.store = store
        register(store.captureHotkey)
    }

    /// 注册/改注册热键。冲突 → App 内横幅提示, 不抢注、不降级猜测 (设计 3.3)。
    func register(_ hk: CaptureHotkey) {
        if let existing = hotkeyRef {
            UnregisterEventHotKey(existing)
            hotkeyRef = nil
        }
        registeredHotkey = nil
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D4E4758), id: 1)   // 'MNGX'
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            store?.setExtensionNotice(String(format: L("快捷键 %@ 被其他 App 占用, 请在设置中更改捕获热键"), hk.display),
                                      isError: true)
            return
        }
        hotkeyRef = ref
        registeredHotkey = hk
        installHandlerOnce()
    }

    private func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { QuickCaptureController.shared.hotkeyFired() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    private func hotkeyFired() {
        toggle()
    }

    // MARK: - Panel 生命周期

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let p = ensurePanel()
        position(p)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installClickMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        removeClickMonitor()
    }

    /// 居中偏上 1/3 (设计 3.1)。
    private func position(_ p: NSPanel) {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let f = p.frame
        p.setFrameOrigin(NSPoint(x: vf.midX - f.width / 2,
                                 y: vf.maxY - vf.height / 3 - f.height / 2))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        // Spotlight 式: 无边框 + 透明底 (圆角卡片和投影由 SwiftUI 绘制, 外圈留 12pt 画阴影)
        let p = QuickCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 664, height: 84),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.hasShadow = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        if let store {
            p.contentView = NSHostingView(rootView: L10nRoot { QuickCaptureView(store: store) })
        }
        panel = p
        return p
    }

    /// 点击面板外部 → 隐藏 (设计 3.1)。双路监听:
    /// global monitor 只回调"其他 App"的点击; 捕获条唤起时本 App 已激活,
    /// 点主窗口/侧栏必须走 local monitor 才能关 (P9-#3)。
    /// 面板自身点击 (event.window === panel) 与 pill 菜单弹层 (NSMenu 系窗口) 放行。
    private func installClickMonitor() {
        guard clickMonitors.isEmpty else { return }
        // 两个 monitor 注册都返回 Any?, if-let 显式解包 (消除 Any?→Any 隐式强转 warning)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { QuickCaptureController.shared.hide() }
            }
        }) {
            clickMonitors.append(m)
        }
        // 局部闭包直传 (尾闭包紧随 if-let 会被判 confusable)
        let localHandler: (NSEvent) -> NSEvent? = { [weak panel] event in
            if Self.shouldDismiss(clickWindow: event.window, panel: panel) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { QuickCaptureController.shared.hide() }
                }
            }
            return event
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: localHandler) {
            clickMonitors.append(m)
        }
    }

    private func removeClickMonitor() {
        for m in clickMonitors { NSEvent.removeMonitor(m) }
        clickMonitors = []
    }

    /// 关闭判定 (纯函数, 冒烟直测): 点击窗口 nil = 点击了桌面; 面板自身放行;
    /// NSMenu 弹层窗口 (pill 目标菜单) 放行 —— 菜单选择期间不能把捕获条关掉。
    nonisolated static func shouldDismiss(clickWindow: NSWindow?, panel: NSPanel?) -> Bool {
        guard let panel else { return false }
        if clickWindow === panel { return false }
        let name = String(describing: type(of: clickWindow))
        return !name.contains("Menu")
    }
}

// MARK: - 捕获条 UI (项目 pill + 单行输入 + 发送)

struct QuickCaptureView: View {
    @ObservedObject var store: ChatStore
    @State private var text = ""
    @State private var target: ChatStore.CaptureTarget = .newSession(projectId: nil)
    @FocusState private var focused: Bool

    var body: some View {
        // Spotlight 式: 放大镜 + 大号单行输入 + 右缘目标 pill; 卡片圆角 + 柔和投影
        card
            .padding(12)   // 外圈留白给 SwiftUI 投影 (面板透明底)
            .onAppear {
                target = .from(memoRaw: store.captureMemo)   // 记忆上次捕获目标
                focused = true
            }
    }

    private var card: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(CodexTheme.textMuted)
            TextField("在这里输入该做什么…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(CodexTheme.textPrimary)
                .focused($focused)
                .onSubmit { submit() }
                .onExitCommand { QuickCaptureController.shared.hide() }   // Esc 关闭
            targetPill
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: 13)
            .fill(CodexTheme.bgElevated)
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(CodexTheme.border, lineWidth: 1)))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }

    /// 目标 pill (会话级平铺): 新会话 / 新会话-项目 / 追加-会话。
    private var targetPill: some View {
        Menu {
            Button("新会话") { target = .newSession(projectId: nil) }
            ForEach(store.projects) { g in
                Button("新会话-\(g.title)") { target = .newSession(projectId: g.id) }
            }
            Divider()
            ForEach(recentSessions) { item in
                Button("追加-\(item.title)") { target = .append(sessionId: item.id) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label(for: target))
                    .font(.system(size: 13))
                    .foregroundStyle(CodexTheme.textMuted)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(CodexTheme.textMuted)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 追加候选: 最近活跃 8 个会话 (含侧问会话; 无侧问来源限制 —— 追加语义与侧问绑定兼容)。
    private var recentSessions: [ConversationItem] {
        Array(store.allConversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
    }

    private func label(for t: ChatStore.CaptureTarget) -> String {
        switch t {
        case .newSession(let pid):
            let proj = pid.flatMap { p in store.projects.first { $0.id == p }?.title }
            return proj.map { String(format: L("新会话-%@"), $0) } ?? L("新会话")
        case .append(let sid):
            return L("追加-") + (store.allConversations.first { $0.id == sid }?.title ?? L("已删除会话"))
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.setCaptureMemo(target.memoRaw)
        // P9-#13: 拒绝路径 (并发满/目标失效/引擎缺失) 保留面板与输入, 横幅已提示原因;
        // 原实现无条件 hide + 清空, 用户打的字直接丢
        guard store.submitCapture(text: trimmed, target: target) != nil else { return }
        text = ""
        target = .newSession(projectId: nil)   // 发送后回默认 (下次 onAppear 再读记忆)
        QuickCaptureController.shared.hide()   // 发送即隐藏 (反馈 = 侧栏转圈 → 完成通知)
    }
}
