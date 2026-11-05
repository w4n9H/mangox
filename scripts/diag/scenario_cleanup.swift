//
//  scenario_cleanup.swift
//  P19 场景回归的**测试清理器**（2026-11-04）。
//
//  ⚠️ 它**不是产品能力**，也**不进任何门禁**：产品路径没有"删一条日程"这个动作（删要走菜单，
//     而菜单不在窗口那棵树里 —— 场景 #6 正是被这条卡住的）。但场景测试要反复跑，跑完必须把
//     自己造的数据清干净，否则第二次跑就是在别人的垃圾堆上跑。
//     ⇒ 用完即弃，别把它当成"那就顺手加个 delete op"的理由（那要过门槛：同一个缺口在
//        ≥2 个真实场景里卡住）。
//
//  ✅ **硬红线（2026-11-04 boss 定）：只在目标 App 的 UI 元素上操作，绝不走全局输入。**
//     这条不是洁癖，是**不可逆损失**：
//       · 顶栏菜单属于"此刻前台的那个 App" —— 要按它就得先把目标 App 弄到前台。一旦前台
//         不是它（比如人正停在 WorkBuddy 里敲字），那一下"删除"落到谁身上说不准，而删除
//         / 移到废纸篓**没有撤销**。
//       · 全局键鼠（`CGEvent` 发 ⌘⌫ / Esc / 鼠标点击）更糟：它们是发给**屏幕的最上层**的，
//         跟我读的那棵树完全没有关系。我读过日历，不代表那一刻的前台是日历。
//     ⇒ 所以这个文件里**没有** `CGEvent`、**没有** `AXMenuBarItem`。三条路都走不通时，
//        正确地失败：打印"这一条 AX 做不到，请人来删"，退码 3。**不许退到全局输入。**
//        （`run.sh` 有一条源码门盯着这件事，见「③u 诊断脚本不许发全局输入」。）
//
//  用法:
//    scenario-cleanup <bundle id> <名字里含这个串> [菜单项标题...]
//  例:
//    scenario-cleanup com.apple.iCal "【场景测试】" 删除
//
//  ⚠️ 实测记录(2026-11-04)，全是"看着成功其实没做"的那种：
//    ① **返回码不可信**：日历事件行上 `AXShowMenu` 回 **-25204**（`kAXErrorCannotComplete`）
//       却是**唯一**有效的路 —— 上下文菜单真的弹了。所以判据一律是「**菜单项变可用**」。
//    ② 备忘录：**取的是父链上那层 `cell`**（2026-11-04 boss 一句「备忘录的右键是可以删除的」
//       逼出来的）。快照里"一行"映射到的是最里面的 `statictext`（一个动作都没有），而
//       `Name:删除` 挂在外两层 —— 只试元素自己的话，结论会错成"这个 App 只能靠人删"。
//    ③ 提醒事项的笔记行有自己的**自定义动作** `Name:删除`，那条最干净（元素级、不用前台）。
//    ⇒ 通用的教训：**动作要沿父链找**。AX 里"哪一层承载动作"没有规律，只有实测。
//
//  退出码: 0 = 清干净（或本来就没有）· 3 = 找到但没删成 · 4 = App 没在跑 / 读不到窗口
//

import AppKit
import ApplicationServices

func fail(_ code: Int32, _ msg: String) -> Never {
    FileHandle.standardError.write(Data(("scenario-cleanup: " + msg + "\n").utf8))
    exit(code)
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var raw: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &raw) == .success ? raw : nil
}
func role(_ el: AXUIElement) -> String { (attr(el, kAXRoleAttribute) as? String) ?? "" }
func title(_ el: AXUIElement) -> String { (attr(el, kAXTitleAttribute) as? String) ?? "" }
/// 名字 = `AXTitle` 优先、空则退到 `AXDescription`（与 `AXSnapshot.label` 同一套）。
func name(_ el: AXUIElement) -> String {
    let t = title(el)
    return t.isEmpty ? ((attr(el, kAXDescriptionAttribute) as? String) ?? "") : t
}
func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let l = names as? [String] else { return [] }
    return l
}
func parent(_ el: AXUIElement) -> AXUIElement? {
    // ⚠️ 必须走 `as!` 而不是 `as?`: CoreFoundation 类型的条件降级在 swiftc 里是**编译错误**
    //    ("conditional downcast ... will always succeed")，而它一报错脚本只留下旧二进制
    //    —— 症状是"改了代码没生效"。踩过一次。
    guard let raw = attr(el, kAXParentAttribute) else { return nil }
    return (raw as! AXUIElement)
}

func walk(_ el: AXUIElement, depth: Int = 0, out: inout [AXUIElement]) {
    guard depth <= 8, out.count < 4000 else { return }
    out.append(el)
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { walk(k, depth: depth + 1, out: &out) }
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
guard argv.count >= 2 else {
    fail(2, "用法: scenario-cleanup <bundle id> <名字里含这个串> [菜单项标题...]")
}
let bundle = argv[0]
let marker = argv[1]
let menuTitles = argv.count > 2 ? Array(argv.dropFirst(2))
                                   : ["删除", "移到废纸篓", "Delete", "Move to Trash"]

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
    fail(4, "\(bundle) 没在跑")
}
let pid = app.processIdentifier
let appEl = AXUIElementCreateApplication(pid)

func allEls() -> [AXUIElement] {
    var all: [AXUIElement] = []
    walk(appEl, out: &all)
    return all
}
func isEnabled(_ el: AXUIElement) -> Bool { (attr(el, kAXEnabledAttribute) as? Bool) ?? false }

/// 这一项是不是**顶栏菜单**里的（它的祖先里有没有 `AXMenuBar`）。
///
/// ⚠️ 这是硬红线的**执行点**：顶栏菜单要前台，而前台是谁我说了不算 —— 见文件头。
///    元素**自己的上下文菜单**（右键菜单）不在此列：它属于这个元素、这个 App，不依赖前台。
func inMenuBar(_ el: AXUIElement) -> Bool {
    var cur: AXUIElement? = el
    for _ in 0..<10 {
        guard let c = cur else { return false }
        if role(c) == "AXMenuBar" { return true }
        cur = parent(c)
    }
    return false
}

/// 名字命中目标、可用、且**不在顶栏**的菜单项。
func usableItems() -> [AXUIElement] {
    allEls().filter {
        role($0) == "AXMenuItem" && menuTitles.contains(name($0)) && isEnabled($0) && !inMenuBar($0)
    }
}

/// 提醒事项那种**元素自带的**自定义动作（`AXActionNames` 里那条 `Name:删除`）。
///
/// ⚠️ 这是最干净的一条：元素级、不需要前台、不需要菜单。判据是动作真的发出去了。
func customAction(on el: AXUIElement) -> String? {
    actions(el).first { raw in menuTitles.contains { raw.contains($0) } }
}

/// 有确认框就按同名的那一个（「删除」/「移到废纸篓」…）。**按钮是元素级的 `AXPress`。**
func confirmSheetIfAny() {
    for sheet in allEls() where role(sheet) == "AXSheet" {
        var buttons: [AXUIElement] = []
        walk(sheet, out: &buttons)
        for b in buttons where role(b) == "AXButton" && menuTitles.contains(name(b)) {
            _ = AXUIElementPerformAction(b, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.5)
            return
        }
    }
}

/// 元素本身 + 往上几层祖先（含自己，最里层在前）。
///
/// ⚠️ **为什么必须往上找**（2026-11-04，boss 一句「备忘录的右键是可以删除的」逼出来的）：
///    快照把"一行"映射到的是**最里面的 `statictext`**，而备忘录那条 `Name:删除` 挂在
///    **外面两层的 `cell`**（`ICMNoteListCell` 的父级）上：
///        [0] statictext          actions=[]
///        [1] cell id=ICMNoteListCell   actions=["AXShowMenu"]
///        [2] cell                actions=["AXShowMenu", "Name:置顶…", "Name:共享…", "Name:删除…"]
///        [3] row                 actions=["Name:置顶…", "Name:删除…"]
///    只看元素自己 ⇒ 永远找不到 ⇒ 我上一版据此写下"这个 App 只能靠人删"，那句是**错的**。
/// 从元素本身往上爬时**到此为止**的角色。
///
/// ⚠️ 容器层不许按：`AXTable` / `AXOutline` 上的「删除」删的是**"当前选中的那个"**，不是
///    "我要删的那一行"。而"选中"这件事在 AX 里经常是假的（备忘录的 `AXSelectedRows` 就是
///    假的：写进去回 0、回读 1 条，实际删除动作落到别的行上 —— 2026-11-04 实测）。
///    按错一格 = 删错东西且没有撤销 ⇒ 宁可这条路走不通，也不许按容器。
let stopRoles: Set<String> = ["AXTable", "AXOutline", "AXWindow", "AXScrollArea", "AXApplication"]

func selfAndAncestors(_ el: AXUIElement, up: Int = 4) -> [AXUIElement] {
    var chain: [AXUIElement] = []
    var cur: AXUIElement? = el
    for _ in 0...up {
        guard let c = cur else { break }
        if stopRoles.contains(role(c)) { break }
        chain.append(c)
        cur = parent(c)
    }
    return chain
}

/// 把弹出来的菜单层收掉。`AXCancel` 是元素级动作；不支持就随它去（菜单是独立窗口，
/// 挡不住我们读主窗口）。顶栏那些 `AXMenu` 本来就没展开，按一下也无害。
func closeMenus() {
    for menu in allEls() where role(menu) == "AXMenu" {
        _ = AXUIElementPerformAction(menu, "AXCancel" as CFString)
    }
}

/// 把这一条删掉。**全程元素级**，三条路按实测有效顺序：
///   ① 自定义动作（提醒事项 `Name:删除`、备忘录 `Name:删除`）② 上下文菜单（日历）
///   ③ 名字命中的子元素（Finder 那种"可点的是子元素"）
///
/// ⚠️ ① 和 ② 都**沿父链逐层试**，不只试元素自己 —— 见 `selfAndAncestors` 那段实测。
/// 三条都不通 ⇒ 返回 false。**不许退到全局键鼠** —— 见文件头那条红线。
func deleteThis(_ el: AXUIElement) -> Bool {
    let chain = selfAndAncestors(el)

    // ① 自定义动作：挨层找（哪一层有就用哪一层）
    for node in chain {
        guard let act = customAction(on: node) else { continue }
        if AXUIElementPerformAction(node, act as CFString) == .success {
            Thread.sleep(forTimeInterval: 0.8)
            confirmSheetIfAny()
            return true
        }
    }

    // ② 上下文菜单：挨层试（能弹的那一层留下菜单，`usableItems` 已经排掉了顶栏）
    for node in chain {
        _ = AXUIElementPerformAction(node, "AXShowMenu" as CFString)
        Thread.sleep(forTimeInterval: 0.6)
        if let item = usableItems().first {
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                closeMenus()
                return false
            }
            Thread.sleep(forTimeInterval: 0.6)
            confirmSheetIfAny()
            return true
        }
        closeMenus()
    }

    // ③ 名字命中的子元素
    var kids: [AXUIElement] = []
    walk(el, out: &kids)
    for k in kids.dropFirst() where menuTitles.contains(name(k)) {
        if AXUIElementPerformAction(k, kAXPressAction as CFString) == .success {
            Thread.sleep(forTimeInterval: 0.6)
            confirmSheetIfAny()
            return true
        }
    }
    return false
}

func snapshotRows() -> [AXSnapshot.Row]? {
    guard let trees = AXAdapter.frontWindowTree(pid: pid) else { return nil }
    let snap = AXSnapshot.build(root: trees.root, appName: bundle, windowTitle: trees.root.title)
    return snap.rows
}

/// 现在还剩几条带标记的行（读前端窗口那一棵）。
///
/// ⚠️ 这是**唯一可信的判据**。实测（2026-11-04）：备忘录那条 `Name:删除` 按下去返回
///    **-25205**（"属性不支持"），可笔记**真的进了「最近删除」**（9 → 8，最近删除 10 → 11）。
///    AX 的返回码在这族动作上不可信 —— 拿 `err == .success` 当判据，会把一次成功的删除
///    记成失败（进而"再试一次"、或者写下"这个 App 只能靠人删"这种错结论）。
///    ⇒ 删没删，只认**前后条数差**。
func hitCount() -> Int? {
    guard let rows = snapshotRows() else { return nil }
    return rows.filter { $0.title.contains(marker) || $0.value.contains(marker) }.count
}

guard let trees0 = AXAdapter.frontWindowTree(pid: pid) else {
    fail(4, "读不到「\(app.localizedName ?? bundle)」的窗口")
}
_ = trees0

let start = hitCount() ?? -1
if start == 0 { print("没找到含「\(marker)」的行 —— 已经干净") }

var current: Int? = start
var round = 0
while round < 8, let c = current, c > 0 {
    round += 1
    guard let trees = AXAdapter.frontWindowTree(pid: pid) else { break }
    let snap = AXSnapshot.build(root: trees.root, appName: bundle, windowTitle: trees.root.title)
    let hits = snap.rows.filter { $0.title.contains(marker) || $0.value.contains(marker) }
    for row in hits {
        guard let el = trees.elements[AXSnapshot.pathKey(row.path)] else { continue }
        _ = deleteThis(el)          // 返回码不看 —— 见上面 `hitCount` 那段实测
    }
    Thread.sleep(forTimeInterval: 0.5)
    current = hitCount()
    // 一条都没少 ⇒ 这 App 的元素级这条路走不通, 再跑七轮也是同一个结果
    if let newC = current, newC >= c {
        print("  删不动: 这一轮之后还是 \(newC) 条 —— 元素级这条路走不通"
              + "（元素自己不暴露动作, 上下文菜单里也没有这一项）")
        break
    }
}

let left = current ?? -1
let removed = (start >= 0 && left >= 0) ? start - left : 0
print("删掉 \(removed) 项, 残留 \(left < 0 ? "?" : String(left))")
if removed == 0 && left > 0 {
    print("⚠️ 这个 App 只能靠人删 —— 全局输入那条路已经按红线删掉了 (见文件头)")
}
exit(left == 0 ? 0 : 3)
