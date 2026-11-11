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
//    ③ **网页正文要靠目标 App 自己开着 a11y**: 浏览器把网页当独立进程(渲染进程), 主窗口树默认只有
//       外壳。我们这侧推不动它 —— 常规解法是给目标 App 置 `AXManualAccessibility`(Chromium) /
//       `AXEnhancedUserInterface`(WebKit), 实测(2026-10-28)Chrome 对这两个**都拒绝**:
//       `−25205` / `−25208`, 节点数与深度一字未变。
//       ⇒ **能不能读网页, 是目标 App 的状态, 不是我们的能力上限**:
//         · Safari(WebKit) 默认就开着 —— 2026-11-06 实测一个内容页 2504 节点 / 1598 行 / 781ms。
//         · Chrome(Chromium) 要人手动开: `chrome://accessibility` 勾 `Web accessibility`, 或启动时
//           带 `--force-renderer-accessibility`; 那个勾**不跨重启**。2026-11-09 实测勾上之后
//           363 节点 / 251 行 / 8904 字符 / 156ms（此前恒 43 行, 只有外壳）。
//       ⚠️ 判据: 读回来的行里有没有 `webarea` 的正文。有 = 开了; 只有外壳 = 没开。
//          **别再把这条写成"本版做不到"**（手册与回执都改过一遍了）。
//       另: 还有一条**未验**的路 —— 把 `AXEnhancedUserInterface` 设在 **system-wide 元素**上
//       (10-28 那次设在 Chrome 自己身上才吃 −25205/−25208)。
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
        /// 这次走完没有。**回执必须据此说话** —— 一棵被截断的树与一棵完整的树在
        /// `AXSnapshot` 上长得一样, 模型分不出来, 就会把"读到的前 120 项"当成全部。
        var stop: StopReason = .complete
    }

    /// 遍历为什么停下。
    enum StopReason: String {
        /// 树走完了 —— 下面就是全部。
        case complete
        /// 撞了节点上限(`maxNodes`)。
        case budget
        /// 撞了墙钟上限(`readTimeout`)。
        case timeout
    }

    /// **一次 read 的墙钟上限**(秒)。2026-11-02 实测逼出来的数:
    ///   备忘录 129 节点 268ms · 日历 625 节点 781ms —— 正常 App 都在 1 秒以内;
    ///   而**邮件收件箱(799 封)走了 3000 节点、花了 200 秒**(67ms/节点)。
    ///   12 秒 = 对正常 App 留 15 倍余量, 对读不动的 App 立刻止损。
    ///
    /// ⚠️ 这不是"体验优化", 是**安全项**: helper 是单线程串行(accept → 处理 → 关闭),
    ///   一次 200 秒的 read 会把整个 computer use 挂住 —— 期间连 `accept()` 都不转,
    ///   别的会话发来的请求全部排队等着。没有超时 = 一个 App 能让整条能力失效。
    /// ⚠️ 为什么是**协作式**（每节点查 deadline）而不是把遍历甩到后台线程 + 信号量等:
    ///   甩出去的那个线程没法中断, 它照样在 IPC 上跑, 只是没人等它 —— 既省不了时间,
    ///   又多一个会和 `elements` 表抢的元素所有权问题。协作式在这里是唯一干净的做法。
    static let readTimeout: TimeInterval = 12

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
    ///
    /// `timeout` 可传 —— 重读那一路要给它**剩下的**时间, 否则一次 read 的最坏耗时是
    /// (1 + maxRereads) × `readTimeout`。
    static func frontWindowTree(pid: pid_t, timeout: TimeInterval = readTimeout) -> Trees? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let w = focused {
            // ⚠️ 必须是 `as!` 而不是 `as?`: AXUIElement 是 CF 类型, 条件转换"永远成功",
            //   编译器直接判错。上游 `success` 已经保证这里拿得到元素。
            return buildTree(w as! AXUIElement, timeout: timeout)
        }
        // 没有"聚焦窗口"就退到第一个窗口: 有些 App 的 focusedWindow 是 nil, 但它有窗口。
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let raw = windows else { return nil }
        // ⚠️ 用 `as?` 而不是 `as!`: 这是**外部 App 给的数据**, 真有一个 App 把 `AXWindows`
        //    回成单个元素(而不是数组), `as!` 就是**整个 helper 崩掉** —— 症状是 socket 突然
        //    断开, 而回执一个字都没有(2026-10-30 review)。
        guard let list = raw as? [AXUIElement] else { return nil }
        guard let first = list.first else { return nil }
        return buildTree(first, timeout: timeout)
    }

    /// 遍历预算的**唯一**计数点 —— 全局的, 不是每棵子树各一份。
    ///
    /// ⚠️ 2026-10-30 修的一处真缺陷: 原来写的是 `build(..., budget: remaining)`, 而
    ///    `remaining` 只在**同一层兄弟之间**递减、子树里烧掉的节点**不回流给父级** ⇒
    ///    `maxNodes = 3000` 实际变成"每层每个子树各有 3000", 总量是**乘出来的**。
    ///    现实后果不是崩, 是**一条 read 卡几十秒**: 深层 DOM(20 层、每层 2~3 个孩子)会把
    ///    整棵树全量走完 —— 每个节点一次 AX IPC(~0.5ms), 5 万节点就是 25 秒, 而
    ///    `elements` 字典还把每个 `AXUIElement` 都留住(内存跟着涨)。
    ///    小树上看不出来(实测备忘录 128 / Finder 16) ⇒ 这类缺陷只能靠读代码或压力样本发现。
    private final class Budget {
        var left: Int
        let deadline: Date
        /// 到过点没有。**粘住** —— 一旦为真就不再回落, 免得后面赶巧跑快了, "停过"这件事
        /// 在回执里凭空消失。
        private(set) var timedOut = false

        init(_ n: Int, timeout: TimeInterval) {
            left = n
            deadline = Date().addingTimeInterval(timeout)
        }

        /// 到点了吗(每节点查一次)。
        var expired: Bool {
            if timedOut { return true }
            if Date() > deadline {
                timedOut = true
                return true
            }
            return false
        }
    }

    private static func buildTree(_ root: AXUIElement, timeout: TimeInterval = readTimeout) -> Trees {
        var elements: [String: AXUIElement] = [:]
        let budget = Budget(maxNodes, timeout: timeout)
        let node = build(root, depth: 0, path: [], budget: budget, elements: &elements)
        // 两个上限先后无所谓, 但**超时优先报**: 撞节点是"这棵树本来就大"(可预期),
        // 超时是"这个 App 慢到读不了"(要人管), 后者更该被看见。
        let stop: StopReason = budget.timedOut ? .timeout
            : (budget.left <= 0 ? .budget : .complete)
        return Trees(root: node, elements: elements, stop: stop)
    }

    // MARK: - 翻译

    private static func build(_ el: AXUIElement,
                              depth: Int,
                              path: [Int],
                              budget: Budget,
                              elements: inout [String: AXUIElement]) -> AXNode {
        budget.left -= 1
        elements[AXSnapshot.pathKey(path)] = el

        let role = string(el, kAXRoleAttribute) ?? ""
        let title = string(el, kAXTitleAttribute) ?? ""
        // ⚠️ 这一行不是"顺手多读一个属性": 实测 Safari 的工具栏按钮**标题是空的, 名字只在
        //    `AXDescription` 里**(Chrome 两个都写) ⇒ 不读它, Safari 那一排按钮在快照里全是
        //    无名的 `[n] button`, 模型只能靠编号点数、人也看不懂审批卡。取舍在 `AXSnapshot.label`。
        let detail = string(el, kAXDescriptionAttribute) ?? ""
        let identifier = string(el, kAXIdentifierAttribute) ?? ""
        let value = string(el, kAXValueAttribute) ?? ""
        // ⚠️ `AXSubrole` **只对文本类问**: 它是每节点一次 IPC(3000 节点 = 3000 次往返), 而
        //    密码框的身份只可能出现在文本类元素上(实测 Safari / AppKit 都是
        //    `AXRole = AXTextField` + `AXSubrole = AXSecureTextField`)。
        //    ⚠️ 漏了它, 网页密码框两条判据(role 名 / AXProtectedContent)全落空 ——
        //    文本靠 WebKit 自己返回 `••••••` 侥幸没泄, 而**图像面一点没涂**(2026-10-30 实测)。
        let subrole = role.localizedCaseInsensitiveContains("textfield")
            ? (string(el, kAXSubroleAttribute) ?? "") : ""
        let actions = actionNames(el)
        let frame = rect(el)

        var children: [AXNode] = []
        if depth < maxDepth, budget.left > 0, !budget.expired {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw) == .success,
               let value = raw, let list = value as? [AXUIElement] {
                for (i, child) in list.enumerated() {
                    // 预算**全局递减**: 到 0 就停, 不再往下走(兄弟、以及别人的子树都一样)。
                    // 墙钟同理 —— 到点就收手, **已经走完的那部分照样留着**(树是完整遍历的前缀,
                    // 与撞预算同一种形态), 回执再说明它不完整。
                    guard budget.left > 0, !budget.expired else { break }
                    children.append(build(child,
                                          depth: depth + 1,
                                          path: path + [i],
                                          budget: budget,
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
                      subrole: subrole,
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
        // ⚠️ **日期这一档是 2026-11-04 实测补的**(批 2m): 日历事件编辑器里那四个时间格子
        //    (`AXDateTimeArea`, id `start-timepicker` …) 的 `AXValue` 是 **CFDate**。
        //    不认它 ⇒ 快照里这四格**连值都没有**, 而这正是"改一条日程的时间"唯一能落脚的地方:
        //    模型只能看见四个无名空格子, 连现在几点都读不出来。
        //    渲染成 `yyyy-MM-dd HH:mm`(本机时区), 与 `ComputerDateValue.parse` 认的格式同源 ——
        //    "读到的样子 = 能写回去的样子"。
        if let d = raw as? Date { return ComputerDateValue.display(d) }
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
    ///
    /// ⚠️ `tap` 那道几何闸也要用它(见 `frontWindowFrame`) ⇒ 不再是 private。
    static func rect(_ el: AXUIElement) -> AXRect? {
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

    /// 前端窗口的**外框** —— 不建树, 只问两个属性。
    ///
    /// ⚠️ 为什么不能直接用快照上的 `windowFrame`: `tap` 要判的是"**此刻**窗口还在不在原处",
    ///    而快照是过去那一刻的。拿旧值跟自己比等于恒真。
    /// ⚠️ 为什么不用 `frontWindowTree`: 那是一整棵树(微信以外的 App 也要 200ms~1s, 费 3000 节点
    ///    的预算), 而这里只要 4 个整数。`tap` 每点一次都要问一遍, 用建树去问就是把"点一下"
    ///    的代价抬到"读一次"。
    static func frontWindowFrame(pid: pid_t) -> AXRect? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let w = focused {
            return rect(w as! AXUIElement)
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let raw = windows, let list = raw as? [AXUIElement], let first = list.first
        else { return nil }
        return rect(first)
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
        // ⚠️ 与 `build` 同一套判据、同一处读取: 现场判定若漏了 subrole, 症状是"快照里认得出
        //    这是密码框(已遮), 一到 act 就认不出来" —— 同一份界面, 两条路给出不同结论。
        let subrole = role.localizedCaseInsensitiveContains("textfield")
            ? (string(el, kAXSubroleAttribute) ?? "") : ""
        // `subrole` 一起塞进 `AXNode`: `AXSnapshot.label` 靠它认密码框, 而下面那行用的正是
        // 同一个 `label` —— 少传一个字段, 两条路就分叉了。
        let node = AXNode(role: role,
                          title: string(el, kAXTitleAttribute) ?? "",
                          detail: string(el, kAXDescriptionAttribute) ?? "",
                          subrole: subrole)
        let (key, mods) = menuKey(el)
        return ComputerActTarget(role: role,
                                 subrole: subrole,
                                 title: AXSnapshot.label(node),
                                 actions: actionNames(el),
                                 isProtected: isProtected(el),
                                 keyEquivalent: key,
                                 modifiers: mods,
                                 // 这两条**现问系统**, 不按角色猜 —— 见 `ComputerActTarget` 上的注释。
                                 canFocus: canFocus(el),
                                 canScroll: scrollBar(of: el) != nil,
                                 // 同上: 值的类型现问, 不按角色猜 —— `datetimearea` 是日期,
                                 // 但别人完全可以给它挂一个字符串值。
                                 valueShape: valueShape(of: el))
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
        let node = build(el, depth: 0, path: [0], budget: Budget(200, timeout: readTimeout), elements: &scratch)
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

    /// 打开/进入 —— `AXOpen`。
    ///
    /// ⚠️ 它与 `press` 是**两个动作**, 不是同一个动作的两种叫法。实测(2026-11-04):
    ///    日历右下角小月历的日期格子、Finder 桌面上的文件图标都**只暴露 `AXOpen`**,
    ///    在它们身上 `AXPress` 有两个坏法 —— 要么根本不在动作表里, 要么**返回 0 却什么都不做**。
    /// ⚠️ 这里**没有 `kAXOpenAction` 这个常量**(苹果的 `AXActionConstants.h` 里没有它),
    ///    只能写字符串 —— 它是个非正式动作, 所以更不能拿返回码当判据:
    ///    同一次 `AXOpen` 报 `-25205` 而界面确实跳了。码怎么读住 `ComputerOpenVerdict`。
    static func open(_ el: AXUIElement) -> AXError {
        AXUIElementPerformAction(el, "AXOpen" as CFString)
    }

    /// 执行元素自己声明的**具名动作** —— 名字由 `ComputerCustomAction.match` 选出(唯一命中),
    /// 判据(能不能做、红线)全在 App 侧那一遍, 这里只发。
    ///
    /// ⚠️ 名字必须用**原始串**(`Name:删除\nTarget:0x0\nSelector:(null)`), 不能用洗过的「删除」:
    ///    AX 认的是它自己那一串, 我们只是在给模型看的时候洗掉噪音。
    /// ⚠️ 返回码这族也**不可信**: 实测提醒事项的 `Name:删除` 回 **-25205**(「属性不支持」)
    ///    而条目真的没了。所以调用方只把 `invalidUIElement` 当"没发出去", 其余一律按
    ///    "发出去了、去看重读"记 —— 同 `open` 那条。
    static func perform(_ el: AXUIElement, action name: String) -> AXError {
        AXUIElementPerformAction(el, name as CFString)
    }

    /// 把这一格的**上下文菜单**摆出来 —— `AXShowMenu`。
    ///
    /// ⚠️ 它与 `press` 是**两个动作**, 不是同一个动作的两种叫法(同 `open` 那条): 有些控件动作表里
    ///    两样都有, 一个按下去、一个把菜单摆出来。实测量级(2026-11-05)。
    /// ⚠️ **返回码照样不可信, 而且两个方向都不可信**: 同一次实现在备忘录笔记格上报 **-25204**
    ///    (`kAXErrorCannotComplete`) 而菜单真的弹了; 在侧边栏文件夹行上报 **0**。所以这里只
    ///    执行, 判据留给调用方 —— **唯一可信的判据是"菜单项有没有真的出现"**(重读之后数
    ///    `menuitem` 的行), 与 `press` 拿 `err == .success` 当判据不是同一路数。
    /// ⚠️ 菜单**不是独立窗口**: 它挂在这一格的**子树**里(`AXMenu` ← 目标元素)。所以重读一次
    ///    前台窗口树, 菜单项就带着新编号出现了 —— 不需要另开一条"读菜单"的路。
    ///    (实测 2026-11-05: 备忘录的上下文菜单 17 项, 含「删除」; `AXWindows` 仍是 1, 前台窗口
    ///     没变 ⇒ 不依赖"这个 App 在前台", 也就不破那条"禁顶栏菜单"的红线。)
    static func showMenu(_ el: AXUIElement) -> AXError {
        AXUIElementPerformAction(el, "AXShowMenu" as CFString)
    }

    /// 确认/提交 —— `AXConfirm`。**第三件不同的事**(见 `ComputerAction` 里 `confirm` 那段):
    /// 实测(2026-11-04, 日历「创建快速日程」): 只有它能把手里的文本变成一条真日程, 而同一个
    /// 文本框上 `AXPress` 返回 `0` 却什么都不发生 —— 拿返回码"看起来一样"就会把它当同义词。
    static func confirm(_ el: AXUIElement) -> AXError {
        AXUIElementPerformAction(el, kAXConfirmAction as CFString)
    }

    /// 写值。只有 `ComputerActGuard.isWritableRole` 放行的角色会走到这里。
    ///
    /// ⚠️ **写法跟着属性当前的类型走**(批 2m, 2026-11-04 实测), 不是一味写字符串:
    ///    `AXDateTimeArea` 的 `AXValue` 是 `CFDate`, 拿 `CFString` 去写系统回
    ///    **-25201**(`kAXErrorIllegalArgument`), 界面纹丝不动 —— 改日程时间在"只会写字符串"
    ///    的实现里根本不可能。`shape` 由 `liveTarget` 现场读来, 判据(该不该写、解析成什么)
    ///    在 `ComputerWritePlan`, 这里只执行。
    static func setValue(_ el: AXUIElement, _ text: String, shape: ComputerValueShape = .text) -> AXError {
        if case .date(let d) = ComputerWritePlan.decide(shape: shape, text: text) {
            return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, d as CFDate)
        }
        return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString)
    }

    /// 这个元素的 `AXValue` 是什么类型。读不到就当**文本**(维持批 2m 之前的行为)。
    private static func valueShape(of el: AXUIElement) -> ComputerValueShape {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &raw) == .success,
              let raw else { return .text }
        // ⚠️ 先比 type id 再转, 不用裸 `as!`: 属性类型由目标 App 决定, 撞上非 CFDate 的
        //    一天就是 helper 崩掉 —— 而 helper 一崩, 整条 computer_* 面到重启前都不可用。
        if CFGetTypeID(raw) == CFDateGetTypeID() { return .date }
        if CFGetTypeID(raw) == CFStringGetTypeID() { return .text }
        return .other
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

    /// 屏幕坐标 → 那个坐标**底下**的元素(批 3a)。
    ///
    /// ⚠️ 它存在的唯一理由是**别开第二套寻址**: 坐标点击原本会绕开"按编号寻址"这个前提 ——
    ///    "我看见的节点 = 我点的东西"那个等式就没了, 三条恒拒(付款 / 永久删除 / 存盘)也无处落脚
    ///    (它们判的是**元素**)。把坐标翻译回元素之后, 坐标只是一种**输入方式**, 不是一种绕过。
    ///
    /// ⚠️ 坐标系是**全局屏幕坐标, 左上原点**(与快照里每行末尾那个 `frame` 同一套) ——
    ///    这也正是 `AXUIElementCopyElementAtPosition` 要的坐标。多显示器下原点左侧的屏是负值,
    ///    所以**不许把坐标 clamp 到 ≥0**。
    ///
    /// ⚠️ 返回 nil 不等于"那儿是空白": 自绘界面(画布 / 游戏)也有元素, 只是不交给系统。
    ///    调用方的话术要把这两种可能都说出来, 别替系统下结论。
    ///
    /// ⚠️⚠️ **起点必须问系统(`AXUIElementCreateSystemWide()`), 不能拿 `AXUIElementCreateApplication(pid)`
    ///    去问。** 用 App 元素当起点时, 问的其实是"**这个 App** 在 (x,y) 上占的是哪块" ——
    ///    落在**别的 App 的窗口**上、甚至落在屏幕外 `(-400,-400)` / `(9999,9999)`,
    ///    **照样回一个元素**(那个 App 自己) ⇒ 于是"坐标上没有东西 ⇒ 直接拒"那条判据
    ///    **永远走不到**, 而回执会说"`(9999,9999)` 上有一个元素" —— 一句凭空捏造的事实。
    ///    2026-10-30 真机探针实测: 四个坐标(屏幕外 / 负值 / 菜单栏 / 窗口背景)全撞上同一句。
    ///    换成 systemWide 后: 屏幕外 ⇒ 系统报错, 命中 nil; 别家 App ⇒ 回**那个 App 的**元素,
    ///    由 `processID(of:)` 认出来"这不是我在读的那个 App"。
    static func element(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                   Float(point.x), Float(point.y), &hit)
        guard err == .success else { return nil }
        return hit
    }

    /// 这一点底下能读到的**文字** —— `tap` 的语义闸用(付款 / 删除那类词)。
    ///
    /// ⚠️ 它**不是**语义判断, 是"能看见几个字": 微信这类 App 在这一点上只回得出
    ///    `AXApplication`(一个字的都没有), 于是那一档少了这道闸 —— 回执里要说清
    ///    "底下没读到字, 所以我看不出这是不是付款键", 不许假装它被判过。
    /// ⚠️ 取三个属性而不是只取 title: 按钮文字常在 value 里, 图标按钮只有一个 description。
    static func text(at point: CGPoint) -> String {
        guard let el = element(at: point) else { return "" }
        var parts: [String] = []
        for key in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                    kAXHelpAttribute] {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, key as CFString, &raw) == .success,
                  let s = raw as? String else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !parts.contains(t) { parts.append(t) }
        }
        return parts.joined(separator: " ")
    }

    /// 元素属于哪个进程 —— 坐标寻址的第二道判据(命中的是不是**这次在读的那个 App**)。
    ///
    /// ⚠️ `AXUIElementCopyElementAtPosition` 问的是**整块屏幕**, 所以模型给的坐标很容易落在
    ///    别的窗口上(它看的是快照里的 frame, 而窗口会被它挪动)。不判这一步, "在 (x,y) 上按一下"
    ///    就成了替**另一个 App** 点 —— 那个 App 我一次都没读过, 也没判过。
    static func processID(of el: AXUIElement) -> pid_t {
        var pid: pid_t = -1
        AXUIElementGetPid(el, &pid)
        return pid
    }

    /// 元素的角色名(`AXButton` / `AXGroup` / `AXApplication`…)。
    /// 坐标没落进快照里的某一格时, 靠它说清"那底下到底是什么", 而不是含糊地说"有一个元素"。
    static func roleName(of el: AXUIElement) -> String {
        string(el, kAXRoleAttribute) ?? ""
    }

    /// 此刻**键盘焦点**在哪个角色上。`nil` = 这个 App 答不出来(微信那种 AX 恒空的树)。
    ///
    /// ⚠️ 为什么要它(2026-11-11 代码评审): `computer_type` 写的是"当前焦点", 而焦点落在
    ///    **列表 / 表格**上时, 注入的字符会变成"按键跳转"(Finder 里敲一个 `f` 就跳到某个
    ///    文件), 空格是预览 —— 那是动作, 不是打字。原来这条链上没有任何一步问过"焦点是
    ///    不是能写字的控件", 回执照样说"往当前焦点写了"。
    /// ⚠️ 但**不能因为读不到就拒**: 微信的 AX 树恒空, 而它恰恰是这一档唯一的真实用例。
    ///    所以调用方拿到 `nil` 时放行, 只在回执里说明"这一格我没判过"(判据那一侧见
    ///    `ComputerTypeRule.editableRoles`)。
    /// ⚠️ 起点必须是 `AXUIElementCreateApplication(pid)`: 焦点是**这个 App 的**属性,
    ///    与"坐标上是谁"不同(那条要用 systemWide, 见 `element(at:)`)。
    static func focusedRole(pid: pid_t) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                kAXFocusedUIElementAttribute as CFString,
                                                &raw)
        guard err == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return roleName(of: raw as! AXUIElement)
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
