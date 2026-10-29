//
//  AXSnapshot.swift
//  P18 批 1: AX 树 → 编号表 → 差分。**纯数据**, 不 import ApplicationServices。
//
//  为什么这里不直接调 AX: 判据要能被断言(P18 §05「一条会撞碎的不变量」) ——
//  真 AX 调用只在 helper 里, 这边只认 `AXNode` 这种自有结构。真机侧写一个 adapter 把
//  `AXUIElement` 拍成 `AXNode`, 于是"剪枝/编号/差分/遮蔽"全部能在冒烟里跑, 不需要真屏幕。
//
//  三条整形规则(§03 改动二):
//    ① 剪枝 —— 只留可交互角色 + 有文本的叶子, 容器只借道不下场;
//    ② 去冗余 —— 子节点的文本与父节点标题相同时丢弃;
//    ③ 编号 + 差分 —— 动作后只回**变化**, 不重发整棵树。
//
//  ⚠️ 模型寻址用**编号**, 不用坐标: 坐标会因窗口移动/滚动/缩放失效, 而编号背后是
//     "那个叫『发送』的按钮" —— 语义稳定。坐标只写给人看(审批卡里"点哪儿")。
//

import Foundation

/// 一个矩形 —— 只用来写给人看。**不参与差分判据**(窗口抖一格不该算"界面变了")。
struct AXRect: Equatable, Codable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var short: String { "(\(x),\(y) \(w)×\(h))" }
}

/// AX 元素的自有表示。真机侧由 adapter 拍平出来, 冒烟里手搓。
struct AXNode: Equatable {
    var role: String
    var title: String = ""
    /// `AXDescription`。**不是** title 的同义词: 有些 App 只往这儿写名字(见 `AXSnapshot.label`)。
    var detail: String = ""
    var value: String = ""
    /// AX 的受保护内容标记(`kAXProtectedContentAttribute`)。
    var isProtected: Bool = false
    /// `AXIdentifier` —— 有它就用它当差分键(比索引路径稳)。
    var identifier: String = ""
    /// 支持的动作名(`AXPress` / `AXConfirm` …), 空 = 不可交互。
    var actions: [String] = []
    var frame: AXRect?
    var children: [AXNode] = []
}

/// 一棵树的整形结果: 编号行 + 元信息。
struct AXSnapshot: Equatable {

    /// 一行 = 模型看到的一个可寻址元素。
    struct Row: Equatable {
        /// 模型用的编号(从 1 开始, 按遍历序)。
        let number: Int
        /// 缩进层数(只按**保留下来的**祖先算)。
        let indent: Int
        let role: String
        let title: String
        /// 已经过遮蔽的值 —— 这里存的就是最终能进上下文的字节。
        let value: String
        let frame: AXRect?
        let actions: [String]
        /// 差分键: `id:<AXIdentifier>` 优先, 否则 `path:<索引路径>`。
        let key: String
        /// 在**原始树**上的索引路径(`[]` = 窗口根)。
        ///
        /// ⚠️ 批 2b 加它: 动作面要按编号找回那个 `AXUIElement`。原来只有 `key` 一个字符串,
        ///    从 `"path:0/2/1"` 里反解路径属于"靠字符串前缀猜语义" —— 换个键格式就静默失效。
        ///    ⚠️ 路径对的是**剪枝前**的树(剪枝不重编号), 所以它和 `key` 是两件事, 不能合并。
        let path: [Int]
    }

    let appName: String
    let windowTitle: String
    let rows: [Row]

    /// 编号 → 行。动作指令(`ui_act`)按编号找回目标, 找不回就是过期的旧快照。
    var byNumber: [Int: Row] { Dictionary(uniqueKeysWithValues: rows.map { ($0.number, $0) }) }

    func row(_ number: Int) -> Row? { rows.first { $0.number == number } }

    // MARK: - 整形

    /// 剪枝 + 编号。`appName` / `windowTitle` 只进表头, 不参与判据。
    static func build(root: AXNode, appName: String, windowTitle: String) -> AXSnapshot {
        var rows: [Row] = []
        var counter = 0
        _ = walk(node: root,
                 path: [],
                 keptIndent: -1,
                 lastText: nil,
                 rows: &rows,
                 counter: &counter)
        return AXSnapshot(appName: appName, windowTitle: windowTitle, rows: rows)
    }

    /// 返回值 = **这一棵子树里最后被保留下来的那段文本**。
    ///
    /// ⚠️ 必须回传, 不能只在调用栈里往下传: 去冗余说的"同一个词不写两遍"是**兄弟之间**的事
    ///   (标题 StaticText + 子 StaticText 各写一遍)。只往下传时, 兄弟俩谁也看不见谁 ——
    ///   实测就是这样漏掉的: 断言报"实际 5 项", 多出来的正是重复那条。
    @discardableResult
    private static func walk(node: AXNode,
                             path: [Int],
                             keptIndent: Int,
                             lastText: String?,
                             rows: inout [Row],
                             counter: inout Int) -> String? {
        let kind = classify(node)
        let text = Self.visibleText(node)
        var childIndent = keptIndent
        var carried = lastText

        switch kind {
        case .container:
            // 容器只借道 —— 不下场, 但孩子接着走。
            break

        case .element:
            // 去冗余: 纯文本叶子与上一个被保留的文本相同 ⇒ 丢(同一个词不写两遍)。
            let isStaticText = staticTextRoles.contains(cleanRoleName(node.role))
            if isStaticText, !text.isEmpty, text == lastText {
                return lastText
            }
            counter += 1
            let indent = keptIndent + 1
            childIndent = indent
            if !text.isEmpty { carried = text }
            rows.append(Row(
                number: counter,
                indent: indent,
                role: cleanRoleName(node.role),
                title: text,
                value: ComputerRedline.maskedValue(node.value,
                                                   role: node.role,
                                                   isProtected: node.isProtected),
                frame: node.frame,
                actions: node.actions,
                key: node.identifier.isEmpty
                    ? "path:" + path.map(String.init).joined(separator: "/")
                    : "id:" + node.identifier,
                path: path
            ))
        }

        for (i, child) in node.children.enumerated() {
            carried = walk(node: child,
                           path: path + [i],
                           keptIndent: childIndent,
                           lastText: carried,
                           rows: &rows,
                           counter: &counter) ?? carried
        }
        return carried
    }

    private enum NodeKind { case container, element }

    private static func classify(_ node: AXNode) -> NodeKind {
        let r = cleanRoleName(node.role).lowercased()
        if interactiveRoles.contains(r) { return .element }
        if staticTextRoles.contains(r) {
            // 有文本才有信息量; 空的 StaticText 是布局占位。
            // ⚠️ 判"有没有文本"必须走 `visibleText` —— 有的 App 把文本只写在 description 里,
            //    更多 App 把它写在 **value** 里; 只看 title 会把一条真文本当占位丢掉。
            return Self.visibleText(node).isEmpty ? .container : .element
        }
        // ① 结构根恒只借道 —— 表头已经写了它是谁(`# 快照 · 前台:· 窗口:`),
        //    再占一行只是把同一句话再说一遍, 白吃一个编号。
        if rootRoles.contains(r) { return .container }
        // ② 其余容器**有名字就留**: 名字标记的是它下面那棵子树。
        //    Finder 的 `outline "边栏"` 就是这类 —— 丢了它, 模型只看见一串格子,
        //    分不清哪些属于边栏、哪些属于文件列表。
        //
        // ⚠️ 这里原来还有一条 `|| !node.actions.isEmpty` 的逃生口, 2026-10-28 实测后**删掉**:
        //    Chromium 给**每个 DOM 元素**都挂 `AXScrollToVisible` + `AXShowMenu` ⇒ 网页里 453 个
        //    无名 group 全被当成"可交互"留下来, 快照 1601 行中 1285 行是这么来的, 真正的正文
        //    被挤到 120 行截断之后 —— **读到了却看不见**, 比读不到更糟。容器只借道, 就只借道。
        return Self.label(node).isEmpty ? .container : .element
    }

    /// `AXButton` → `button`。**统一小写**: 它是写给模型看的 token, 大小写混着来会让
    /// 模型在不同 App 间学出两套写法(而且 `AXButton`/`AXbutton` 这种脏数据真的存在)。
    static func cleanRoleName(_ role: String) -> String {
        var r = role.lowercased()
        if r.hasPrefix("ax") { r = String(r.dropFirst(2)) }
        return r
    }

    /// 模型看到的**名字**。
    ///
    /// ⚠️ 为什么不直接用 `node.title`: 2026-10-28 实测(同一个探针、同一次辅助功能授权) ——
    ///   · Chrome 的工具栏按钮**两个属性都写**: `d=7 title=返回 desc=返回`
    ///   · Safari 的同类按钮 **`title` 是空的, 只写 `AXDescription`**
    ///   ⇒ 只认 title 时 Safari 那一排全是无名的 `[14] button`: 模型指不动(它只会说"点第 14 个"),
    ///     人也看不懂审批卡上写的是什么。**名字 = title 优先, 空则退到 description**。
    ///
    /// ⚠️ **密码类角色不许退到 description**: 第三方 App 会往这个属性里乱写(它和
    ///   `AXPlaceholder` 并不是同一个东西, 但没人强制), 有把输入内容露出来的可能。
    ///   宁可这一行没有名字 —— 值那栏恒 `••••`, 名字这里不能再开一个后门。
    static func label(_ node: AXNode) -> String {
        let t = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if ComputerRedline.isPasswordRole(node.role) { return "" }
        return node.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 这一行**看得见的那段字** —— 名字优先, 没有就用值(去首尾空白)。
    ///
    /// 用途只有两个: 判"有没有东西可看"(剪枝) 与 判"是不是同一个词"(去冗余)。
    /// ⚠️ **不能**拿它当行的名字: 只有值没有名字的 `statictext` 会让渲染出
    ///    `"更多" (值:"更多")` 这种同一句话说两遍的行 —— 名字只认 `label`。
    ///
    /// ⚠️ 也不能只认 `label`: 2026-10-28 实测百度首页, 每个导航项都是
    ///    `link "新闻"` + 子 `statictext (值:"新闻")` —— 文本住在**值**里 ⇒ 只认名字时
    ///    去冗余整个失效, 111 行里 50 行是这种成对重复(实测截图里 [2]-[22] 正是这个)。
    static func visibleText(_ node: AXNode) -> String {
        let l = label(node)
        if !l.isEmpty { return l }
        return node.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let interactiveRoles: Set<String> = [
        "button", "textfield", "textarea", "searchfield", "securetextfield",
        "checkbox", "radiobutton", "popupbutton", "combobox", "menuitem",
        "menubaritem", "menubutton", "tab", "link", "slider", "toggle",
        "switch", "disclosuretriangle", "colorwell", "incrementor", "cell",
    ]

    private static let staticTextRoles: Set<String> = [
        "statictext", "text", "heading", "listitem",
    ]

    /// **结构根** —— 恒只借道, 名字不进行。判据是"它的名字已经写在表头里了"
    /// (`# 快照 · 前台:X · 窗口:Y`), 再占一行只是重复。
    private static let rootRoles: Set<String> = [
        "window", "sheet", "drawer", "dialog", "application",
    ]

    // MARK: - 「窗口是空的」还是「这个 App 不暴露界面」(2026-10-28 实测微信后加)

    /// 承载**内容**的角色。判据是"有没有一层能读的控件", 不是"节点多不多"。
    ///
    /// ⚠️ 三类**故意不在**这张表里, 每一类都是实测逼出来的:
    ///    · `button` —— 微信的树恰好是 `window + group×2 + button×3`(窗口那三个红绿灯按钮),
    ///      把它算内容 ⇒ 自绘 App 全判成"可读", 这条判据当场就废;
    ///    · `group` / `window` —— 任何树都有, 算进来等于恒真。
    ///
    /// ⚠️ 也**不能**写成"节点数 < N": 一个只有标题栏的小工具窗节点同样少, 而它是可读的。
    private static let contentRoles: Set<String> = staticTextRoles.union([
        "textfield", "textarea", "searchfield", "securetextfield", "combobox",
        "scrollarea", "table", "outline", "list", "row", "cell", "webarea", "browser",
    ])

    /// 窗口**两个方向**都不小于这个值才做判断 —— 排除窄条与对话框。
    ///
    /// ⚠️ 取 `min(w, h)` 而不是 `max`: "确定/取消"那种弹窗常有 300×120, 用 max 会把它们
    ///    一起拉进来判; 而它们只要有一句提示文案就够读了, 判错只是让回执多一句废话。
    static let readableMinSide = 200

    /// 这棵树里有没有一层能承载内容的控件。
    static func hasReadableControls(root: AXNode) -> Bool {
        if contentRoles.contains(cleanRoleName(root.role)) { return true }
        return root.children.contains { hasReadableControls(root: $0) }
    }

    /// 窗口够大、但整棵树没有一个内容角色 ⇒ **这个窗口没有可读的控件层**。
    ///
    /// 实测依据(2026-10-28, 同一个探针、同一次辅助功能授权):
    ///   · 微信 `com.tencent.xinWeChat` 主窗口 1052×754 ⇒ **6 个节点, 0 个内容角色**
    ///     (消息列表 / 聊天正文 / 输入框一个都没有 —— 微信没有实现 AX)
    ///   · Finder ⇒ 567 个节点 / 311 处文本; 企业微信 ⇒ 570 / 190
    ///     ⇒ 这不是"节点少的程度差异", 是微信**根本没给**这一层。
    ///
    /// ⚠️ 命中之后**不许把话说死**: 一个真的空白窗口(新建的白页)也长这样。回执里必须把
    ///    两种可能都写出来 —— 猜成"这里什么都没有"会让模型以为自己读成功了。
    static func lacksReadableControls(root: AXNode) -> Bool {
        guard let f = root.frame, min(f.w, f.h) >= readableMinSide else { return false }
        return !hasReadableControls(root: root)
    }

    // MARK: - 批 2c: 懒加载兜底

    /// 内容角色**盖住了窗口的多少**(0~1)。
    ///
    /// ⚠️ 为什么需要它: `hasReadableControls` 只问"树里有没有一片内容控件", 而 Safari 的
    ///    **搜索栏**本身就是一个 `textfield` ⇒ 整页正文一个字都没读到, 那条判据照样成立、
    ///    警告一个字不响。实测(2026-10-29): 第一次读 apple.com.cn 拿到 **20 个节点, 全是地址栏
    ///    与工具栏**, 判据说"可读", 模型只看见 20 个导航按钮。
    ///
    /// 算法: 把每个内容角色的 rect **裁到窗口内**再求和, 除以窗口面积。
    ///    · 重叠会重复计 ⇒ 只会**高估** ⇒ 偏向判成"有内容", 不会凭空报警;
    ///    · 超出窗口的 rect 真实存在(实测 Safari 一条 `image` 的 x 是 −579、宽 3009),
    ///      不裁的话一个跑出屏幕的元素就能把覆盖率刷满。
    ///
    /// ⚠️ 这个数**只用来决定"要不要再读一次"**, 不进报警文案 —— 一个 800×600 的对话框里
    ///    只有一句 700×40 的提示, 覆盖率同样只有几个百分点, 但它就是**全部内容**。
    ///    两者在 AX 树上同构, 分不开。所以"低覆盖"只当**触发重读**的信号, 报不报警仍归
    ///    `lacksReadableControls`。
    static func contentCoverage(root: AXNode) -> Double {
        guard let win = root.frame, win.w > 0, win.h > 0 else { return 1 }
        var covered = 0.0
        func walk(_ node: AXNode) {
            if contentRoles.contains(cleanRoleName(node.role)), let f = node.frame, f.w > 0, f.h > 0 {
                let x0 = max(f.x, win.x)
                let y0 = max(f.y, win.y)
                let x1 = min(f.x + f.w, win.x + win.w)
                let y1 = min(f.y + f.h, win.y + win.h)
                if x1 > x0, y1 > y0 { covered += Double(x1 - x0) * Double(y1 - y0) }
            }
            for c in node.children { walk(c) }
        }
        walk(root)
        return min(1, covered / (Double(win.w) * Double(win.h)))
    }

    /// 覆盖率低于这个数就值得**再读一次**。
    ///
    /// 取 0.15 的依据: 工具栏那一层(地址栏 + 按钮)在 1425×4627 的页面上占 **0.2%**,
    /// 而 Finder / 企业微信那种真读到了的树, 列表与文本占掉大半个窗口。中间没有任何
    /// 真实样本 —— 0.15 落在两个数量级之间, 怎么挪都不影响这两类。
    static let rereadBelowCoverage = 0.15

    /// 最多重读几次。
    ///
    /// 不再多: 每次重读都要等一个间隔, 而"读界面"是个交互动作 —— 等超过 1 秒, 人就已经
    /// 自己动手了。两次(0.2s + 0.4s)覆盖到"页面刚打开"的那一段, 再慢就该如实说"没内容"。
    static let maxRereads = 2

    /// 这次读的树**可能只是没加载完** ⇒ 值得隔一会儿再读一次。
    ///
    /// 只在窗口够大时才判(与 `lacksReadableControls` 同一条下限): 小工具窗本来就没多少面积。
    ///
    /// ⚠️ 还有一道前提: **得有一个内容角色报得出坐标**。有的 App 只给角色不给 rect, 那样
    ///    覆盖率恒为 0 ⇒ 每次读都白等; 而"一个内容角色都没有"的树(微信那种)本来就不实现
    ///    AX, 重读一百次也还是那 6 个按钮。
    static func worthRereading(root: AXNode) -> Bool {
        guard let f = root.frame, min(f.w, f.h) >= readableMinSide else { return false }
        guard hasFramedContent(root: root) else { return false }
        return contentCoverage(root: root) < rereadBelowCoverage
    }

    /// 树里有没有**报得出坐标**的内容角色。
    private static func hasFramedContent(root: AXNode) -> Bool {
        if contentRoles.contains(cleanRoleName(root.role)), let f = root.frame, f.w > 0, f.h > 0 {
            return true
        }
        return root.children.contains { hasFramedContent(root: $0) }
    }

    // MARK: - 批 2b: 动作面要的两次转换

    /// 索引路径 → **元素表的键**。
    ///
    /// ⚠️ helper 建表用它、按编号查表也用它, 必须是**同一个函数**: 两边各拼一次 `"0/2/1"`,
    ///    迟早有一天拼得不一样, 而症状是"按了没反应"(零信号 —— 编译过、编号照查得到)。
    static func pathKey(_ path: [Int]) -> String {
        path.map(String.init).joined(separator: "/")
    }

    /// sheet 里的按钮**位置**(下标 = `sheet.children` 里的位置)。
    ///
    /// ⚠️ 这是"按哪个键"的唯一判据 —— helper 拿它去元素表里取对应的 `AXUIElement`。
    ///    如果 helper 自己再筛一遍按钮(比如"role 是 button 且标题非空"), 两边迟早筛得不一样,
    ///    而错位的后果是**按到了旁边那个键**(存盘弹窗里旁边就是"不保存")。
    static func buttonIndices(in sheet: AXNode) -> [Int] {
        sheet.children.indices.filter { i in
            let c = sheet.children[i]
            return cleanRoleName(c.role) == "button" && !Self.label(c).isEmpty
        }
    }

    /// 一个现场读出来的 sheet 节点 → 存盘判据要的形状(`ComputerActWindow`)。
    static func actWindow(from sheet: AXNode?) -> ComputerActWindow {
        guard let s = sheet else { return .none }
        return ComputerActWindow(sheetTitle: Self.label(s),
                                 sheetButtons: buttonIndices(in: s).map { Self.label(s.children[$0]) })
    }

    // MARK: - 渲染

    /// 拼成模型看的那段文本。
    ///
    /// `limit` 是**上界不是配额**: 一棵几千节点的树整段塞进上下文没有信息量, 只是贵。
    /// 截断时**必须**把"还有多少没显示"写出来 —— 否则模型会以为那就是全部。
    func rendered(limit: Int = 120) -> String {
        var lines: [String] = []
        lines.append("# 快照 · 前台:\(appName) · 窗口:\(windowTitle)")
        let shown = rows.prefix(limit)
        for row in shown {
            lines.append(Self.line(row))
        }
        if rows.count > limit {
            lines.append("… 还有 \(rows.count - limit) 项未显示 (需要的话让我滚动/展开再看)")
        }
        return lines.joined(separator: "\n")
    }

    static func line(_ row: Row) -> String {
        let pad = String(repeating: "  ", count: min(row.indent, 2))
        var s = "\(pad)[\(row.number)] \(row.role)"
        if !row.title.isEmpty { s += " \"\(row.title)\"" }
        // ⚠️ 值与名字相同时不写 —— 实测 Safari 的 `statictext` 把同一段字既放进
        //    `AXDescription` 又放进 `AXValue`(百度首页整页都是) ⇒ 不判就渲染成
        //    `"设置" (值:"设置")`, 同一句话两遍, 只是把上下文撑长。
        if !row.value.isEmpty, row.value != row.title { s += " (值:\"\(row.value)\")" }
        if let f = row.frame { s += " \(f.short)" }
        return s
    }

    // MARK: - 差分

    /// 两棵树之间"变了什么"。动作后只回这个, 不重发整棵树。
    struct Diff: Equatable {
        struct Change: Equatable {
            let before: Row
            let after: Row
        }
        var added: [Row] = []
        var removed: [Row] = []
        var changed: [Change] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

        /// 拼成模型看的一句话。空差分也要说出来 —— "什么都没变"本身是信息。
        func rendered() -> String {
            if isEmpty { return "— 变化:无(界面没动)" }
            var parts: [String] = []
            if !changed.isEmpty {
                let s = changed.map { one -> String in
                    let before = one.before
                    let after = one.after
                    return "\(before.title.isEmpty ? before.role : before.title)"
                        + "  \"\(before.value)\" → \"\(after.value)\""
                }
                parts.append("改:" + s.joined(separator: "; "))
            }
            if !added.isEmpty {
                parts.append("新增:" + added.map { "[\($0.number)] \($0.title.isEmpty ? $0.role : $0.title)" }
                    .joined(separator: " "))
            }
            if !removed.isEmpty {
                parts.append("消失:" + removed.map { $0.title.isEmpty ? $0.role : $0.title }
                    .joined(separator: " "))
            }
            return "— 变化:" + parts.joined(separator: " · ")
        }
    }

    /// 差分判据:
    ///   · **键**: `AXIdentifier` 优先, 没有就用索引路径(见 `key`);
    ///   · **算变**: 标题 / 值 / 角色 任一不同;
    ///   · **不算变**: `frame` —— 窗口抖一格、滚动条挪两像素都会让坐标变, 那不是"界面变了"。
    ///
    /// ⚠️ 索引路径的**已知弱点**: 中间插入一个兄弟节点, 后面所有路径都退一位 ⇒ 会报成
    ///   "一批消失了、一批出现了"。真机侧应当优先读 `AXIdentifier`; 没有标识的 App 只能
    ///   靠这一层兜(这也是 §05 代价表里"AX 覆盖率是天花板"的一条具体表现)。
    static func diff(from old: AXSnapshot, to new: AXSnapshot) -> Diff {
        var result = Diff()
        var oldByKey: [String: Row] = [:]
        for r in old.rows { oldByKey[r.key] = r }
        var seen = Set<String>()

        for r in new.rows {
            seen.insert(r.key)
            guard let before = oldByKey[r.key] else {
                result.added.append(r)
                continue
            }
            if before.title != r.title || before.value != r.value || before.role != r.role {
                result.changed.append(Diff.Change(before: before, after: r))
            }
        }
        for r in old.rows where !seen.contains(r.key) {
            result.removed.append(r)
        }
        return result
    }
}
