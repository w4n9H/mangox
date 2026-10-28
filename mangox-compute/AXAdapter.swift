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
//    ② `kAXProtectedContentAttribute`: 该常量在本 SDK 里的可用性还没验过, 所以本版
//       受保护内容**暂不识别**, 密码框只靠角色名(见 `ComputerRedline.isPasswordRole`)。
//       验证真机时补上, 别在这里猜一个常量名。
//    ③ **网页正文读不到**: 浏览器把网页当独立进程(渲染进程), 主窗口树默认只有外壳。常规解法是
//       给目标 App 置 `AXManualAccessibility`(Chromium) / `AXEnhancedUserInterface`(WebKit),
//       但实测(2026-10-28)Chrome 对这两个**都拒绝**: `−25205` / `−25208`, 节点数与深度一字未变
//       ⇒ 本版**不假装**能读网页正文。要读正文只能走截图 + 视觉那条路(批 2 的图像面)。
//

import ApplicationServices
import CoreGraphics
import Foundation

enum AXAdapter {

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
    static func frontWindowTree(pid: pid_t) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let w = focused {
            // ⚠️ 必须是 `as!` 而不是 `as?`: AXUIElement 是 CF 类型, 条件转换"永远成功",
            //   编译器直接判错。上游 `success` 已经保证这里拿得到元素。
            return build(w as! AXUIElement, depth: 0, budget: maxNodes)
        }
        // 没有"聚焦窗口"就退到第一个窗口: 有些 App 的 focusedWindow 是 nil, 但它有窗口。
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let raw = windows else { return nil }
        // `as!` 的结果不是 Optional ⇒ 不用 `if let` 再包一层(编译器会直接判错)。
        let list = raw as! [AXUIElement]
        guard let first = list.first else { return nil }
        return build(first, depth: 0, budget: maxNodes)
    }

    // MARK: - 翻译

    private static func build(_ el: AXUIElement, depth: Int, budget: Int) -> AXNode {
        var remaining = budget

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
                for child in list {
                    guard remaining > 0 else { break }
                    remaining -= 1
                    children.append(build(child, depth: depth + 1, budget: remaining))
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
}
