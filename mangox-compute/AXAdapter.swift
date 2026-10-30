//
//  AXAdapter.swift
//  mangox-compute: 把真 AX 树拍成 `AXNode`(那边的整形/剪枝/遮蔽才是判据所在)。
//
//  ⚠️ 这个文件**故意很薄**: 它只做"翻译", 一个判断都不做。判据(剪枝、编号、差分、
//     遮蔽、作用域)全部住在 `mangox/Models/` 里的纯函数上, 那边能被冒烟断言。
//     真 AX 调用在没有屏幕、没有 TCC 授权的机器上测不了 ⇒ 能测的部分不许留在这里。
//
//  ⚠️ 三条**已知没做**的事(诚实标注, 不假装完成):
//    ① **超时**: 目标 App 无响应时 `AXUIElementCopyAttributeValue` 会挂住(§05 代价表)。
//       真超时语义要等批 2 与"跳过"策略一起做 —— 这里先不假装能中断。
//    ② `AXProtectedContent`: SDK 里没有导出常量, 所以按**属性名字符串**读(见 `isProtected`)。
//       **两条路都要接**: ① `build`(读给模型看的那棵树) ② `liveTarget`(动作判据)。取不到时
//       不算受保护 —— 兜底是角色名(`ComputerRedline.isPasswordRole`), 任一生效即遮。
//       ⚠️ 这里曾经**只在 `liveTarget` 那条路上接**, `build` 硬写了 `false` ⇒ 遮蔽只剩"按角色"
//       一档, 而头注释已经写着"按属性名字符串读"(注释比事实说得多)。`run.sh` ③q 现在盯着这句。
//       ⚠️ 仍然没在真机上找到过一个 `AXProtectedContent=1` 的元素来对照 —— 真遇到时回来记一笔。
//    ③ **网页正文读不到**: 浏览器把网页当独立进程(渲染进程), 主窗口树默认只有外壳。常规解法是
//       给目标 App 置 `AXManualAccessibility`(Chromium) / `AXEnhancedUserInterface`(WebKit),
//       但实测(2026-10-28)Chrome 对这两个**都拒绝**: `−25205` / `−25208`, 节点数与深度一字未变
//       ⇒ 本版**不假装**能读网页正文。要读正文只能走截图 + 视觉那条路(批 2 的图像面)。
//

import ApplicationServices
import CoreGraphics
import Foundation

enum AXAdapter {

    /// 一棵树 + **索引路径 → 真元素**的表。
    ///
    /// ⚠️ 批 2b 起必须有这张表: 模型寻址用编号, 而编号只活在 `AXSnapshot` 里; helper 要按编号
    ///    找回 `AXUIElement` 才能按得下去。表的键由 `AXSnapshot.pathKey` 生成 —— **同一个函数**,
    ///    不许两边各拼一次。
    struct Trees {
        let root: AXNode
        let elements: [String: AXUIElement]
    }

    /// 遍历深度上限。不是性能考虑, 是**防失控**: 有些 App 的 AX 树会自引用或极深。
    ///
    /// ⚠️ 这个数**不是随便定的**(2026-10-28 实测): 14 是我第一版拍的数, 而 Chrome 的网页正文
    ///    恰好从 **d15** 开始(d14 上 13 个节点全是浏览器外壳) ⇒ 14 把整页内容切在外面, 快照里
    ///    只剩工具栏。实测深度: Finder 7 · Chrome 23。取 32 = 实测 23 之上留一档余量。
    ///    真正的兜底是 `maxNodes`(自引用会立刻把节点预算烧光), 深度只是第二道。
    static let maxDepth = 32

    /// 节点数上限。超了就停止展开 —— 一棵几千节点的树对模型没有信息量, 只会把上下文撑爆。
    static let maxNodes = 3000

    /// 取某个 pid 的**前台窗口**树。取不到返回 nil(调用方负责说人话)。
    static func frontWindowTree(pid: pid_t) -> Trees? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let w = focused {
            // ⚠️ 必须是 `as!` 而不是 `as?`: AXUIElement 是 CF 类型, 条件转换"永远成功",
            //   编译器直接判错。上游 `success` 已经保证这里拿得到元素。
            return buildTree(w as! AXUIElement)
        }
        // 没有"聚焦窗口"就退到第一个窗口: 有些 App 的 focusedWindow 是 nil, 但它有窗口。
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let raw = windows else { return nil }
        // `as!` 的结果不是 Optional ⇒ 不用 `if let` 再包一层(编译器会直接判错)。
        let list = raw as! [AXUIElement]
        guard let first = list.first else { return nil }
        return buildTree(first)
    }

    private static func buildTree(_ root: AXUIElement) -> Trees {
        var elements: [String: AXUIElement] = [:]
        let node = build(root, depth: 0, path: [], budget: maxNodes, elements: &elements)
        return Trees(root: node, elements: elements)
    }

    // MARK: - 翻译

    private static func build(_ el: AXUIElement,
                              depth: Int,
                              path: [Int],
                              budget: Int,
                              elements: inout [String: AXUIElement]) -> AXNode {
        var remaining = budget
        elements[AXSnapshot.pathKey(path)] = el

        let role = string(el, kAXRoleAttribute) ?? ""
        let title = string(el, kAXTitleAttribute) ?? ""
        // ⚠️ 这一行不是"顺手多读一个属性": 实测 Safari 的工具栏按钮**标题是空的, 名字只在
        //    `AXDescription` 里**(Chrome 两个都写) ⇒ 不读它, Safari 那一排按钮在快照里全是
        //    无名的 `[n] button`, 模型只能靠编号点数、人也看不懂审批卡。取舍在 `AXSnapshot.label`。
        let detail = string(el, kAXDescriptionAttribute) ?? ""
        let identifier = string(el, kAXIdentifierAttribute) ?? ""
        let value = string(el, kAXValueAttribute) ?? ""
        let actions = actionNames(el)
        let frame = rect(el)

        var children: [AXNode] = []
        if depth < maxDepth, remaining > 0 {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw) == .success,
               let value = raw {
                let list = value as! [AXUIElement]
                for (i, child) in list.enumerated() {
                    guard remaining > 0 else { break }
                    remaining -= 1
                    children.append(build(child,
                                          depth: depth + 1,
                                          path: path + [i],
                                          budget: remaining,
                                          elements: &elements))
                }
            }
        }

        return AXNode(role: role,
                      title: title,
                      detail: detail,
                      value: value,
                      // ⚠️ 2026-10-30 之前这里是**硬写的 `false`** ⇒ 遮蔽只剩"按角色"那一档,
                      //    而头注释（当时）已经写成"按属性名字符串读" —— 注释比事实说得多。
                      //    现在真读了，但**只在有值时才问**：这个属性每节点一次 AX 往返
                      //    (3000 节点 = 3000 次 IPC), 而遮蔽挡的是"值泄出去", 空值没什么可遮的。
                      isProtected: !value.isEmpty && isProtected(el),
                      identifier: identifier,
                      actions: actions,
                      frame: frame,
                      children: children)
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &raw) == .success else { return nil }
        if let s = raw as? String { return s }
        // 数字型的值(滑块、步进器)AX 给的是 NSNumber —— 转成字符串, 否则模型看不见当前值。
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    private static func actionNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else {
            return []
        }
        return list
    }

    /// 位置 + 尺寸。`AXValue` 里装的是 CGPoint / CGSize, 取不出来就当没有 ——
    /// 坐标只写给人看, 它是**可缺失**的(缺失不影响模型按编号寻址)。
    private static func rect(_ el: AXUIElement) -> AXRect? {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        var point = CGPoint.zero
        var size = CGSize.zero
        var hasPoint = false
        var hasSize = false

        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRaw) == .success,
           let raw = posRaw, CFGetTypeID(raw) == AXValueGetTypeID() {
            let v = raw as! AXValue
            if AXValueGetType(v) == .cgPoint, AXValueGetValue(v, .cgPoint, &point) { hasPoint = true }
        }
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRaw) == .success,
           let raw = sizeRaw, CFGetTypeID(raw) == AXValueGetTypeID() {
            let v = raw as! AXValue
            if AXValueGetType(v) == .cgSize, AXValueGetValue(v, .cgSize, &size) { hasSize = true }
        }
        guard hasPoint, hasSize else { return nil }
        return AXRect(x: Int(point.x), y: Int(point.y), w: Int(size.width), h: Int(size.height))
    }

    // MARK: - 批 2b: 动作

    /// 按编号找回真元素。键由 `AXSnapshot.pathKey` 生成, 这里是**唯一**的查表入口。
    static func element(_ trees: Trees, at path: [Int]) -> AXUIElement? {
        trees.elements[AXSnapshot.pathKey(path)]
    }

    /// 目标元素的**现场**读数 —— 判据必须吃这个, 不许用 read 时刻拍下来的那份。
    ///
    /// ⚠️ 名字走 `AXSnapshot.label`(title 优先, 空则退到 `AXDescription`)是**同源**要求,
    ///    不是复用癖: 两条路各写一遍, 迟早一边认得出「Safari 的按钮名」一边认不出,
    ///    而症状是"同一个按钮, 快照里叫『登录』, 判据看它叫空"。
    static func liveTarget(_ el: AXUIElement) -> ComputerActTarget {
        let role = string(el, kAXRoleAttribute) ?? ""
        let node = AXNode(role: role,
                          title: string(el, kAXTitleAttribute) ?? "",
                          detail: string(el, kAXDescriptionAttribute) ?? "")
        let (key, mods) = menuKey(el)
        return ComputerActTarget(role: role,
                                 title: AXSnapshot.label(node),
                                 actions: actionNames(el),
                                 isProtected: isProtected(el),
                                 keyEquivalent: key,
                                 modifiers: mods,
                                 // 这两条**现问系统**, 不按角色猜 —— 见 `ComputerActTarget` 上的注释。
                                 canFocus: canFocus(el),
                                 canScroll: scrollBar(of: el) != nil)
    }

    /// 目标窗口上此刻挂着的 sheet。**现场读** —— 存盘弹窗是"刚才那一秒"才弹出来的,
    /// 拿上次快照判断会整个漏掉(而漏掉的后果正是"模型替人决定丢弃未保存的修改")。
    ///
    /// 返回值里的 `elements` 与 `node.children` **一一对应**: 判据用前者算下标, 执行用后者取元素。
    struct Sheet {
        let node: AXNode
        let elements: [AXUIElement]
    }

    static func sheet(of window: AXUIElement) -> Sheet? {
        var raw: CFTypeRef?
        // ⚠️ `AXSheets` 用字面量: `kAXSheetsAttribute` 在 Swift 里没有导出(同 `AXProtectedContent`
        //    那条) —— AX 属性名本身是稳定的线上字符串。
        guard AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &raw) == .success,
              let list = raw as? [AXUIElement],
              let el = list.first else { return nil }
        // 路径给 `[0]` 只是占位: 这棵树**不进缓存也不占编号**, 只用来判"要不要保存"。
        var scratch: [String: AXUIElement] = [:]
        let node = build(el, depth: 0, path: [0], budget: 200, elements: &scratch)
        // ⚠️ 按 node.children 的顺序取元素, 不用 `scratch.values`: 字典无序, 取出来的顺序
        //    一旦和 children 不一样, `buttonIndices` 算出的下标就会按到旁边那个键上。
        let kids: [AXUIElement] = node.children.indices.compactMap {
            scratch[AXSnapshot.pathKey([0, $0])]
        }
        return Sheet(node: node, elements: kids)
    }

    static func actWindow(of window: AXUIElement) -> ComputerActWindow {
        guard let s = sheet(of: window) else { return .none }
        return AXSnapshot.actWindow(from: s.node)
    }

    /// 按 sheet 里第 `buttonIndex` 个**按钮**(下标由 `AXSnapshot.buttonIndices` 算)。
    /// 找不到就返回 nil ⇒ 调用方恒拒, 不许退而求其次去按第一个。
    static func pressSheetButton(in window: AXUIElement, at buttonIndex: Int) -> AXError? {
        guard let s = sheet(of: window) else { return nil }
        let indices = AXSnapshot.buttonIndices(in: s.node)
        guard buttonIndex >= 0, buttonIndex < indices.count else { return nil }
        let i = indices[buttonIndex]
        guard i < s.elements.count else { return nil }
        return press(s.elements[i])
    }

    /// 按。失败**不重试、不退到坐标点击** —— 按不下去就如实报, 让人来。
    static func press(_ el: AXUIElement) -> AXError {
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }

    /// 写值。只有 `ComputerActGuard.isWritableRole` 放行的角色会走到这里。
    static func setValue(_ el: AXUIElement, _ text: String) -> AXError {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString)
    }

    // MARK: - 聚焦与滚动 (批 2f)

    /// 把焦点放到这个元素上。**纯 AX** —— 不发任何按键事件。
    static func focus(_ el: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// 焦点此刻在不在它身上 —— `focus` 的**回读判据**。
    ///
    /// ⚠️ 必须有这一问: `AXUIElementSetAttributeValue` 对某些元素返回 `success` 却什么都没做,
    ///    不回读就会回"聚焦了", 而模型接着 setValue 写进了一个没聚焦的控件。
    static func isFocused(_ el: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &raw) == .success,
              let n = raw as? NSNumber else { return false }
        return n.boolValue
    }

    /// `AXFocused` 在这个元素上可设吗 —— `focus` 那条判据的**现场**依据。
    static func canFocus(_ el: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(el, kAXFocusedAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// `scroll` 一次挪多少(占整段可滚范围的比例)。
    ///
    /// ⚠️ 这个数不是"一屏": 我们拿不到内容高度与视口高度, 而且**假装知道**比说不知道更糟
    ///    (模型会以为一次就到底)。0.1 的含义就是"十分之一段", 回执里会把百分比写出来,
    ///    要更多就再叫一次。
    static let scrollStep = 0.1

    /// 这个元素管着的那根**竖向滚动条**(没有就 nil) —— `scroll` 的落点。
    ///
    /// ⚠️ 四档依次: ① 自己就是滚动条 ② 自己的 `AXVerticalScrollBar` 属性(常量没导出, 用字面量 ——
    ///    同 `AXSheets` / `AXProtectedContent` 那两处) ③ 子树里第一个 `AXScrollBar`
    ///    (有**预算**: 网页的树动辄几千节点, 整棵搜一遍会让一次 scroll 慢到几百毫秒)
    ///    ④ 再往**上**找四层 —— 模型点名的多半是页面里的控件, 滚动条在它上面的容器上。
    ///
    /// ⚠️ `nil` 不等于"这个 App 不能滚", 只等于**它不把滚动条交给系统**(Chrome / Safari 的
    ///    网页内容常常如此) ⇒ 回执要把这个区别说出来, 别让模型以为是它点错了节点。
    static func scrollBar(of el: AXUIElement) -> AXUIElement? {
        if (string(el, kAXRoleAttribute) ?? "") == "AXScrollBar" { return el }
        if let own = verticalScrollBar(of: el) { return own }
        if let inTree = firstScrollBar(in: el, depth: 0, budget: 60) { return inTree }
        // ⚠️ 再**往上**找几层。模型手里有编号的通常不是滚动容器本身, 而是页面里的某个控件
        //    (正文、链接、输入框), 而滚动条挂在它**上面**那层。只往下找的话, 最常见的
        //    "长网页滚一屏"永远滚不动, 而回执会把原因说成"这个 App 不交给系统" ——
        //    那是**说错话**(同一句会让人以为这条路彻底不通), 比不动更糟。
        var cur = el
        for _ in 0..<4 {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &raw) == .success,
                  let p = raw, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
            let parent = p as! AXUIElement
            if (string(parent, kAXRoleAttribute) ?? "") == "AXScrollBar" { return parent }
            if let bar = verticalScrollBar(of: parent) { return bar }
            cur = parent
        }
        return nil
    }

    /// 元素自己身上那个 `AXVerticalScrollBar` 属性(没有就不猜)。
    ///
    /// ⚠️ 先比 type id 再转, 不用裸 `as!`: 这个属性在自绘 App 里可能回别的类型,
    ///    而 helper 崩一次 = 整个 computer_* 面到重启前都不可用(同 `frame` 那两处先例)。
    private static func verticalScrollBar(of el: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXVerticalScrollBar" as CFString, &raw) == .success,
              let bar = raw, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        let barEl = bar as! AXUIElement
        return (string(barEl, kAXRoleAttribute) ?? "") == "AXScrollBar" ? barEl : nil
    }

    private static func firstScrollBar(in el: AXUIElement, depth: Int, budget: Int) -> AXUIElement? {
        guard depth < 3, budget > 0 else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw) == .success,
              let list = raw as? [AXUIElement] else { return nil }
        var spent = 0
        for child in list {
            spent += 1
            if spent > budget { return nil }
            if (string(child, kAXRoleAttribute) ?? "") == "AXScrollBar" { return child }
            if let hit = firstScrollBar(in: child, depth: depth + 1, budget: budget - spent) {
                return hit
            }
        }
        return nil
    }

    /// 滚动条此刻的位置(0 … 1)。读不到就是 nil(调用方据此拒, 不猜 0)。
    static func scrollValue(_ bar: AXUIElement) -> Double? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &raw) == .success,
              let n = raw as? NSNumber else { return nil }
        return n.doubleValue
    }

    static func setScrollValue(_ bar: AXUIElement, _ value: Double) -> AXError {
        let clamped = min(1.0, max(0.0, value))
        return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                            NSNumber(value: clamped))
    }

    /// 菜单项的快捷键 + 修饰键。**永久删除判据的一半** —— 见 `ComputerRedline.decodedModifiers`。
    ///
    /// ⚠️ 用字符串字面量读属性而不是 `kAXMenuItemCmdChar` 常量: 那两个常量在 Swift 里
    ///    不一定导出(同 `kAXProtectedContentAttribute` 那条 "别在这里猜一个常量名"),
    ///    而 AX 属性名本身是稳定的线上字符串。
    static func menuKey(_ el: AXUIElement) -> (String?, Set<String>) {
        let char = string(el, "AXMenuItemCmdChar")
        var raw: CFTypeRef?
        var mods: Set<String> = []
        if AXUIElementCopyAttributeValue(el, "AXMenuItemCmdModifiers" as CFString, &raw) == .success,
           let n = raw as? NSNumber {
            mods = ComputerRedline.decodedModifiers(n.intValue)
        }
        return (char, mods)
    }

    /// AX 的受保护内容标记(`AXProtectedContent`)。取不到就当**不是**受保护 ——
    /// 这条判据的兜底是角色名(`ComputerRedline.isPasswordRole`), 两条任一生效即遮。
    ///
    /// ⚠️ **两条路都在用**: ① `build`(进快照, 交给模型看的那份值) ② `liveTarget`(动作判据)。
    ///    少接一条的后果不一样: 少接 `liveTarget` = 往受保护字段里写; 少接 `build` = **值泄进上下文**
    ///    (后者更坏, 而且不会有任何红灯 —— 2026-10-30 之前就是这样)。
    private static func isProtected(_ el: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXProtectedContent" as CFString, &raw) == .success else {
            return false
        }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }
}
