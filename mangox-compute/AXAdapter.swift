//
//  AXAdapter.swift
//  mangox-compute: 把真 AX 树拍成 `AXNode`(那边的整形/剪枝/遮蔽才是判据所在)。
//
//  ⚠️ 这个文件**故意很薄**: 它只做"翻译", 一个判断都不做。判据(剪枝、编号、差分、
//     遮蔽、作用域)全部住在 `mangox/Models/` 里的纯函数上, 那边能被冒烟断言。
//     真 AX 调用在没有屏幕、没有 TCC 授权的机器上测不了 ⇒ 能测的部分不许留在这里。
//
//  ⚠️ 两条**已知没做**的事(诚实标注, 不假装完成):
//    ① **超时**: 目标 App 无响应时 `AXUIElementCopyAttributeValue` 会挂住(§05 代价表)。
//       真超时语义要等批 2 与"跳过"策略一起做 —— 这里先不假装能中断。
//    ② `AXProtectedContent`: SDK 里没有导出常量, 所以按**属性名字符串**读(见 `isProtected`),
//       取不到时不算受保护 —— 兜底是角色名(`ComputerRedline.isPasswordRole`), 任一生效即遮。
//       ⚠️ 这条至今**只在纯函数层验过**, 没在真机上找到过一个 `AXProtectedContent=1` 的元素
//       来对照 —— 真遇到时要回来记一笔。
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
                      isProtected: false,
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
                                 modifiers: mods)
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
    private static func isProtected(_ el: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXProtectedContent" as CFString, &raw) == .success else {
            return false
        }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }
}
