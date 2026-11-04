//
//  ax_coverage_probe.swift
//  P19 前置: 量一批内置 App 的 **AX 覆盖率** —— 读一次要多少节点 / 保留几行 / 多少字符 / 多久。
//
//  为什么要有它: "哪个 App 值得做 computer use" 现在全是猜。备忘录那次的基线是
//  128 节点 → 83 行 → 3804 字符 → 118ms, 而微信 1052×754 只暴露 6 个节点 ⇒ 同一套代码,
//  不同 App 差两个数量级。设计场景之前先把这张表量出来, 否则就是在编排没数据的章节。
//
//  ⚠️ 它是**只读**探针: 只调 `AXAdapter.frontWindowTree`(读), 不 press / 不 setValue / 不截图。
//  ⚠️ 它编译的是**真源码**(`AXAdapter` + `AXSnapshot` + `ComputerRedline` + `ComputerAct`),
//     数字与 App 里跑出来的同一份, 不是另写一遍的近似实现。
//  ⚠️ 辅助功能权限是**按二进制**记的(cdhash), 换一次编译就要重授 —— 所以要一个**稳定的**
//     产物路径(见同名 .sh), 免得每跑一次都要点一次系统设置。
//

import AppKit
import ApplicationServices

// MARK: - 待测清单

/// 顺序 = 汇报顺序。`label` 只用于打印, 判据一律走 bundle id。
/// ⚠️ 这份清单与 `SopInjection.builtins` 是**同一批**（手册只写量过的 App）——
///    增删要两边一起动, 否则「手册里没有这一节」会点名。
///    音乐（`com.apple.Music`）2026-11-04 移出: 它量出来最便宜（99 节点 / 71ms）也最简单,
///    没有值得写进手册的坑, 留着只是每轮多付一段提示词。
let defaultTargets: [(bundle: String, label: String)] = [
    ("com.apple.iCal", "日历"),
    ("com.apple.mail", "邮件"),
    ("com.apple.Notes", "备忘录"),
    ("com.apple.reminders", "提醒事项"),
    ("com.apple.finder", "访达"),
]

// MARK: - 系统侧三件事

func trusted() -> Bool {
    // 第一次跑会把系统对话框弹出来(只有用户能点)。已经有了就直接返回 true。
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

func running(_ bundle: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
}

func open(_ bundle: String) -> NSRunningApplication? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    var out: NSRunningApplication?
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
        out = app
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 12)
    return out
}

/// 等它长出窗口 —— 刚 launch 的 App 有一段时间 `AXWindows` 还是空的。
func waitWindows(pid: pid_t, seconds: Double) -> [AXUIElement] {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let ws = windowHandles(pid: pid)
        if !ws.isEmpty { return ws }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return []
}

func windowHandles(pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
          let list = raw as? [AXUIElement] else { return [] }
    return list
}

func windowTitleOf(_ w: AXUIElement) -> String {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &raw) == .success,
          let s = raw as? String else { return "" }
    return s
}

/// 把某个窗口提到最前 —— **不点任何东西**, 只是让它成为"前台窗口"。
/// ⚠️ 必须有这一步: `frontWindowTree` 取的是 `AXFocusedWindow`, 而多窗口 App 此刻的焦点
///    可能是另一个(或 Finder 那种根本没窗口、焦点其实是桌面) ⇒ 量到的是错的那扇。
func raise(_ w: AXUIElement) {
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
}


// MARK: - 量

func nodeCount(_ n: AXNode) -> Int {
    1 + n.children.reduce(0) { $0 + nodeCount($1) }
}

/// 树里有多少比例的节点**落在窗口可视区内**。
///
/// 为什么要这个数: 报价里最贵的一项是 `AXUIElementCopyAttributeValue` —— 每节点 6~10 次 IPC,
/// 而 3000 个节点里有大量是滚动区外、压根看不见的行。**这个比例直接回答"按可视区剪枝值不值"**:
/// 如果 3000 个节点里只有 3% 在窗口内, 那剪枝就是 30 倍而不是 3% 的优化。
func visibleShare(_ root: AXNode) -> Double {
    guard let win = root.frame, win.w > 0, win.h > 0 else { return 1 }
    var total = 0
    var inside = 0
    func walk(_ n: AXNode) {
        total += 1
        if let f = n.frame, f.w > 0, f.h > 0,
           f.x + f.w > win.x, f.y + f.h > win.y,
           f.x < win.x + win.w, f.y < win.y + win.h {
            inside += 1
        }
        for c in n.children { walk(c) }
    }
    walk(root)
    return total == 0 ? 0 : Double(inside) / Double(total)
}

struct Measurement {
    let label: String
    let bundle: String
    let ok: Bool
    let note: String
    let nodes: Int
    let rows: Int
    let chars: Int
    let ms: Int
    let coverage: Double
    let readable: Bool
    let rendered: String
    /// 这个 App 开着几扇窗口。1 与 5 的"覆盖率"不是一件事, 表里得分开看。
    var windows: Int = 0
    /// 这一行量的是第几扇(1 起)。
    var windowIndex: Int = 0
    /// 树里落在窗口可视区内的节点比例 —— "按可视区剪枝值不值"就看它。
    var visible: Double = 0
}

func measureWindows(bundle: String, label: String, windowWait: Double) -> [Measurement] {
    guard trusted() else {
        return [Measurement(label: label, bundle: bundle, ok: false, note: "没辅助功能权限",
                            nodes: 0, rows: 0, chars: 0, ms: 0, coverage: 0, readable: false, rendered: "")]
    }
    // 没在跑就拉起来 —— 但**不替用户点开任何东西**, 只是把窗口摆出来。
    var app = running(bundle)
    if app == nil { app = open(bundle) }
    guard let app else {
        return [Measurement(label: label, bundle: bundle, ok: false, note: "本机没装 / 打不开",
                            nodes: 0, rows: 0, chars: 0, ms: 0, coverage: 0, readable: false, rendered: "")]
    }
    let wins = waitWindows(pid: app.processIdentifier, seconds: windowWait)
    guard !wins.isEmpty else {
        return [Measurement(label: label, bundle: bundle, ok: false, note: "没等到窗口",
                            nodes: 0, rows: 0, chars: 0, ms: 0, coverage: 0, readable: false, rendered: "")]
    }

    // ⚠️ **逐窗口量, 不只量前台那一扇**。这不是谨慎过度, 是实测教训: 第一次跑时
    //    "邮件"量到的是那扇**写了一半的「新邮件」窗口**(37 节点), 收件箱根本没被量到 ——
    //    而结论会变成"邮件的 AX 树很薄", 完全反了。多窗口 App 的"覆盖率"必须一扇一扇说。
    var out: [Measurement] = []
    for (i, w) in wins.enumerated() {
        raise(w)
        Thread.sleep(forTimeInterval: 0.25)
        let t0 = Date()
        guard let fresh = AXAdapter.frontWindowTree(pid: app.processIdentifier) else { continue }
        let snap = AXSnapshot.build(root: fresh.root,
                                    appName: app.localizedName ?? bundle,
                                    windowTitle: windowTitle(fresh.root))
        let text = snap.rendered()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        out.append(Measurement(label: label,
                               bundle: bundle,
                               ok: true,
                               note: snap.windowTitle.isEmpty ? "窗口无标题" : "",
                               nodes: nodeCount(fresh.root),
                               rows: snap.rows.count,
                               chars: text.count,
                               ms: ms,
                               coverage: AXSnapshot.contentCoverage(root: fresh.root),
                               readable: AXSnapshot.hasReadableControls(root: fresh.root),
                               rendered: text,
                               windows: wins.count,
                               windowIndex: i + 1,
                               visible: visibleShare(fresh.root)))
    }
    if out.isEmpty {
        return [Measurement(label: label, bundle: bundle, ok: false, note: "每一扇都读不出来",
                            nodes: 0, rows: 0, chars: 0, ms: 0, coverage: 0, readable: false, rendered: "")]
    }
    return out
}

func windowTitle(_ root: AXNode) -> String {
    // 窗口标题在 `AXNode` 里就是根节点的 title(窗口元素自己带)。
    root.title
}

// MARK: - 主

let args = CommandLine.arguments
var wait = 6.0
var targets = defaultTargets
if let i = args.firstIndex(of: "--wait"), i + 1 < args.count, let v = Double(args[i + 1]) { wait = v }
if let i = args.firstIndex(of: "--apps"), i + 1 < args.count {
    let want = Set(args[i + 1].split(separator: ",").map(String.init))
    targets = defaultTargets.filter { want.contains($0.bundle) }
    if targets.isEmpty { targets = want.map { ($0, $0) } }
}

guard trusted() else {
    FileHandle.standardError.write("""
    错误: 这个探针没有「辅助功能」权限。

      系统设置 › 隐私与安全性 › 辅助功能 → 勾上终端或这个探针的二进制。
      ⚠️ 权限是**按二进制(cdhash)**记的: 重新编译一次就变成"另一个 App" ⇒ 要再勾一次。
      所以产物路径固定为 ~/.mangox/bin/axcov (见 ax_coverage_probe.sh), 别每次换地方。

    """.data(using: .utf8)!)
    exit(2)
}

let outDir = NSHomeDirectory() + "/.mangox/tmp/axcov"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var all: [Measurement] = []
for t in targets {
    FileHandle.standardError.write("读 \(t.label) …\n".data(using: .utf8)!)
    let ms = measureWindows(bundle: t.bundle, label: t.label, windowWait: wait)
    all += ms
    for m in ms where m.ok {
        let path = "\(outDir)/\(t.bundle)-w\(m.windowIndex).txt"
        try? m.rendered.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - 报表

func pad(_ s: String, _ n: Int) -> String {
    // 中文字符按 2 格算, 只为了对齐好看 —— 判据不读这张表。
    let width = s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) }
    return s + String(repeating: " ", count: max(0, n - width))
}

print("")
print(pad("App", 10) + pad("窗口", 7) + pad("节点", 8) + pad("行", 7) + pad("字符", 9)
      + pad("ms", 7) + pad("可见", 8) + pad("覆盖率", 10) + "判定")
print(String(repeating: "-", count: 78))
for m in all {
    if !m.ok {
        print(pad(m.label, 10) + "—  " + m.note)
        continue
    }
    let cov = String(format: "%.0f%%", m.coverage * 100)
    let vis = String(format: "%.0f%%", m.visible * 100)
    print(pad(m.label, 10)
          + pad("\(m.windowIndex)/\(m.windows)", 7)
          + pad("\(m.nodes)", 8)
          + pad("\(m.rows)", 7)
          + pad("\(m.chars)", 9)
          + pad("\(m.ms)", 7)
          + pad(vis, 8)
          + pad(cov, 10)
          + (m.readable ? "有内容" : "只有外壳"))
}
print("")
print("明细(模型看到的那段文本) → \(outDir)/<bundle>-w<n>.txt")
let failed = all.contains { !$0.ok }
exit(failed ? 1 : 0)
