//
//  ComputerAct.swift
//  P18 批 2b: 动作面的**全部判据** —— 纯函数, 喂一份请求 + 一份现场读数, 出一个决定。
//
//  ⚠️ 为什么判据全在这一个函数里, 而不是散在 `ComputerServer` 的分发处:
//     ① 顺序**本身就是判据**(先查作用域还是先查 seq, 回执会差一句话, 而那句话决定模型
//        下一步做什么); 散着写就没有"顺序"这个东西可断言, 只有一堆 if。
//     ② helper 在没授权、没屏幕的机器上测不了 ⇒ 能测的部分不许留在那边(同 `AXAdapter` 头注释)。
//     ③ 反例要能变红: 把第 6/7 条改回放行 ⇒ `CaseComputerAct` 必须红。
//
//  ⚠️ **红线判据读的是"现场读数", 不是快照里缓存的文本**。`seq` 保证的是"编号没指错元素",
//     挡不住"同一个元素标题从『登录』变成了『删除』" —— 所以 `ComputerActTarget` 由 helper
//     在**执行前那一刻**现场读属性填进来, 不许拿 read 时刻拍下来的那份凑。
//

import Foundation

// MARK: - 动作

/// 模型能做的动作。⚠️ **只有四个**, 而且每一个都必须按**编号**寻址 ——
/// 多一个 op 就多一条"模型以为自己能动"的路(同 `PiRpcTransport.computerToolNames` 那条注释)。
///
/// 批 2b 只有 `press` / `setValue`; 批 2f 补了 `focus` / `scroll`, 两条都是**纯 AX**:
///   · `focus`: 不少 web / Electron 输入框**不吃** `setValue`(AX 返回成功, 值没变),
///     而"先点进去再发按键"要 CGEvent ⇒ 先把"能不能聚焦"这一半如实交出去。
///   · `scroll`: 长页面/长列表读不完 —— `AXSnapshot.rendered` 截断那句"需要的话让我滚动
///     再看"在批 2f 之前是**空头支票**(根本没有 scroll 这个 op, 模型照做只会撞"不认识的 op")。
/// 坐标点击仍然不做: 它绕开编号("我看见的节点 = 我点的东西"这个等式没了), 要等人类接管那批。
enum ComputerAction: String, Equatable, CaseIterable {
    case press
    case setValue
    case focus
    case scroll

    /// 线上给的 `op` 字符串 → 动作。**不认识的 op 返回 nil**, 由调用方拒掉。
    ///
    /// ⚠️ 单独抽出来是为了能断言: 线上把 `op` 写成 `"click"` / `"PRESS"` 时, 解码要是
    ///    默默落到某个默认分支, 就等于"扩展侧改名之后一切照常"。
    static func parse(_ raw: String) -> ComputerAction? {
        ComputerAction(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// `scroll` 往哪滚。
///
/// ⚠️ 只有上下两档: 横向滚动在真实界面里几乎都是"表格列太宽", 而那是**读**能解决的
///    (宽表快照里带坐标); 多一个方向就多一条模型点错的路。
enum ComputerScrollDirection: String, Equatable, CaseIterable {
    case up
    case down

    static func parse(_ raw: String) -> ComputerScrollDirection? {
        ComputerScrollDirection(
            rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// 屏幕坐标 —— **全局坐标, 左上原点**, 与快照里每行的 `frame`(`x,y w×h`)是同一套。
///
/// ⚠️ 它存在的前提是**坐标能被翻译回元素**(helper 的 `AXUIElementCopyElementAtPosition`)。
///    翻译不回来的时候(自绘画布上没有可识别的元素)一律拒 —— 见 `ComputerPointRule`。
struct ComputerPoint: Equatable, Decodable {
    let x: Double
    let y: Double

    /// 回执里写给人看:`(420,300)`。
    var short: String { "(\(Int(x.rounded())),\(Int(y.rounded())))" }
}

/// 坐标寻址的**参数合法性**(批 3a)。**纯函数**, 因为"坐标能不能用在这个动作上"是判据不是实现。
///
/// ⚠️ 这里不判"坐标底下有没有元素" —— 那要问系统, 判不了。它只判**请求本身有没有自相矛盾**:
///    坐标配了个只能按编号的动作 / 同时给了编号和坐标 / 坐标明显不在屏幕上。
///    ⚠️ 同时给编号和坐标**不许挑一个用**: 挑错了方向不对称(按了错的东西比没按更糟),
///       而两个都给说明调用方自己没想清楚, 那就退回"重新说一遍"。
enum ComputerPointRule {

    /// 坐标超出这个范围就不像屏幕上的点(27 寸 5K 也才 5120×2880; 多屏拼接留足余量)。
    static let maxAbsCoordinate: Double = 20000

    /// 返回拒绝原因(`nil` = 参数没问题)。**只判参数, 不判能力**。
    static func refusal(action: ComputerAction,
                        index: Int,
                        point: ComputerPoint?) -> String? {
        guard let point else { return nil }
        guard action == .press else {
            return "坐标只能配 press(在那个点上按一下) ⇒ 没动。"
                + "\(action.rawValue) 得按编号来 —— 它要知道动的是哪一格。"
        }
        if index > 0 {
            return "编号和坐标只能给一个(给了 #\(index) 又给了 \(point.short)) ⇒ 没动。"
                + "两个都说, 我不知道该按哪个。"
        }
        if abs(point.x) > maxAbsCoordinate || abs(point.y) > maxAbsCoordinate {
            return "\(point.short) 不像屏幕上的点(超出 ±\(Int(maxAbsCoordinate))) ⇒ 没动。"
                + "坐标是全局屏幕坐标, 左上原点, 和快照里每行末尾那个 (x,y) 同一套。"
        }
        return nil
    }

    /// 坐标底下的那个元素**没进快照**时, 它属于哪一类。
    ///
    /// ⚠️ 这不是"给回执加个形容词" —— 四类对应的**下一步完全不同**, 合成一句就是在骗人:
    ///    ① `container`: 窗口背景 / 分组 / 滚动区这类**容器**从来不进快照(快照只列格子) ⇒
    ///       跟模型说"重新读一次, 它就带上编号了"是**空话**, 再读一百次也没有;
    ///    ② `wholeApp`: 自绘界面(游戏 / 画布 / 微信那种)只把**整块窗口**交给系统, 里面没有
    ///       更细的格子 ⇒ 坐标在这类 App 上**永远**点不了, 只能截图看;
    ///    ③ `outerChrome`: 菜单栏 / 菜单**不在窗口那棵树里** ⇒ 跟容器一样"重读也没编号",
    ///       但方向相反: 它不是"往里挑一格", 而是"这条路到不了它";
    ///    ④ `stale`: 按钮 / 文本这些真格子 ⇒ 唯一说得通的原因是**快照过期**, 重新读一次就有了。
    enum PointMissKind {
        case wholeApp
        case outerChrome
        case container
        case stale
    }

    /// AX 的纯容器角色 —— 只是**窗口里面**的布局层(不承载"一格")。
    static let containerRoles: Set<String> = [
        "AXWindow", "AXSheet", "AXGroup", "AXSplitGroup", "AXScrollArea",
        "AXLayoutArea", "AXToolbar", "AXTabGroup", "AXWebArea", "AXUnknown",
    ]

    /// 菜单栏 / 菜单 —— 它们**根本不在窗口那棵树里**(快照只读窗口), 所以跟模型说
    /// "重新读一次就有编号了"是句错话, 它再读一百次也不会有。
    /// ⚠️ 实测来源(2026-10-30): `(5,5)` 命中的是**当前 App 自己的**菜单栏(pid 对得上,
    ///    所以进程那一关放行), 落到这里。**别把它并进 `container`** —— 容器是"窗口里面",
    ///    而菜单栏在窗口外面, 那一刻正确的下一步是"换窗口里的按钮", 不是"往里挑一格"。
    static let outerChromeRoles: Set<String> = [
        "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem", "AXMenuItemCustom",
    ]

    /// - Parameter role: 现场读到的 `AXRole`。读不出角色时给空串。
    static func missKind(role: String) -> PointMissKind {
        if role == "AXApplication" { return .wholeApp }
        if outerChromeRoles.contains(role) { return .outerChrome }
        // 读不出角色 ⇒ 当容器: 说"重读就有编号"比说"那是背景"更容易把人带错方向。
        if role.isEmpty || containerRoles.contains(role) { return .container }
        return .stale
    }
}

/// 一条动作请求 —— 与 `ComputerRequest.act` 的字段一一对应。
struct ComputerActRequest: Equatable {
    let app: String
    let action: ComputerAction
    /// 上一次读里的**编号**。
    let index: Int
    /// 上一次读返回的快照序号。**没有它就不许动** —— 这是「先读再动」唯一可验的形式。
    let seq: Int
    /// 只 `setValue` 用。
    let text: String
    /// 只 `scroll` 用。缺了就是**参数错**, 判据会拒(不是默认往下滚)。
    let direction: ComputerScrollDirection?

    init(app: String,
         action: ComputerAction,
         index: Int,
         seq: Int,
         text: String,
         direction: ComputerScrollDirection? = nil) {
        self.app = app
        self.action = action
        self.index = index
        self.seq = seq
        self.text = text
        self.direction = direction
    }
}

// MARK: - 现场读数

/// 目标元素的**现场**属性。由 helper 在动作执行前一刻读, 不是快照里的缓存值。
struct ComputerActTarget: Equatable {
    let role: String
    /// `AXSubrole` —— **网页密码框的身份只在这里**(2026-10-30 实测 Safari:
    /// `AXRole = AXTextField`、`AXProtectedContent = nil`、`AXSubrole = AXSecureTextField`)。
    /// 默认空串 ⇒ 旧调用点与 Mock 不用改。
    let subrole: String
    let title: String
    let actions: [String]
    let isProtected: Bool
    /// `AXMenuItemCmdChar` —— 只用来认 `⇧⌘⌫` 这条恒定的永久删除入口。
    let keyEquivalent: String?
    /// 已经解码过的修饰键(`["command","shift"]`), 不是 AX 的位掩码。
    let modifiers: Set<String>
    /// `AXFocused` 在这个元素上**可设**吗(helper 现问 `AXUIElementIsAttributeSettable`)。
    ///
    /// ⚠️ 为什么不按角色猜"它像不像输入框": 可设与否是**系统给的答案**, 猜错的方向不对称 ——
    ///    猜"能"就是一次点了没反应的 action, 而回执还得替它圆场。
    let canFocus: Bool
    /// 这个元素管着的那根**竖向滚动条**能不能读写(`scroll` 的落点)。
    let canScroll: Bool

    init(role: String,
         subrole: String = "",
         title: String,
         actions: [String] = [],
         isProtected: Bool = false,
         keyEquivalent: String? = nil,
         modifiers: Set<String> = [],
         canFocus: Bool = false,
         canScroll: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.actions = actions
        self.isProtected = isProtected
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.canFocus = canFocus
        self.canScroll = canScroll
    }
}

/// 目标窗口上此刻挂着的 sheet(存盘确认就是这种)。空 = 没有 sheet。
struct ComputerActWindow: Equatable {
    let sheetTitle: String
    let sheetButtons: [String]

    init(sheetTitle: String = "", sheetButtons: [String] = []) {
        self.sheetTitle = sheetTitle
        self.sheetButtons = sheetButtons
    }

    static let none = ComputerActWindow()

    var hasSheet: Bool { !sheetTitle.isEmpty || !sheetButtons.isEmpty }
}

/// 判第 2~5 条要的那点东西。
struct ComputerActScope: Equatable {
    /// `app` 参数解出来的 bundle id。
    let bundle: String
    let appName: String
    let readBundles: Set<String>
    let actBundles: Set<String>
    /// 请求带的 seq(模型手上那份快照)。
    let requestSeq: Int
    /// 本机此刻对这个 App 的最新 seq。
    let currentSeq: Int
    /// 那份快照一共几行 —— 只为把"没有 #37"说成"这份快照只有 12 项"。
    let rowCount: Int
}

// MARK: - 决定

/// 三种出路, 不是两种: **"替你按取消"既不是执行也不是拒绝** ——
/// 它改动了界面(按了取消键), 但结果是把决定权交回给人。
enum ComputerActDecision: Equatable {
    /// 可以执行。
    case allow(ComputerAction)
    /// 什么都不做。`refusal` 非空 = 命中了三条恒拒之一(要留痕); nil = 参数/权限不合法。
    case refuse(reason: String, refusal: ComputerRefusal?)
    /// 存盘确认: 按 `sheetButtons` 里第 `buttonIndex` 个键(恒为"取消")。
    case cancelSavePrompt(buttonIndex: Int, reason: String)

    var isAllow: Bool { if case .allow = self { return true }; return false }
}

// MARK: - 判据

/// 动作执行前的**九条判据**。顺序不可调 —— 见每一步的注释。
enum ComputerActGuard {

    /// 一次 `setValue` 最多写多少个字符。
    ///
    /// ⚠️ 有上界不是洁癖: 写进去的是**用户的数据**, 一次塞几万字进去既可能是模型搞错了对象
    /// (把整份文档倒进搜索框), 也可能是它以为"这样更省事"。超了就不写, 让人来。
    static let maxSetValueChars = 4000

    /// 按这一个函数判完。**不执行任何东西** —— 执行在 helper。
    ///
    /// `target` 是 Optional 不是偷懒: 它由 "编号 → 行 → 元素 → 现场读数" 这一串得来, 编号
    /// 不在这份快照里时**根本读不出目标**。用 `nil` 表达"那儿没有东西", 比让 helper 编一个
    /// 占位读数交给判据诚实 —— 占位数会被第 ⑥⑦ 条当真去判(比如占位的空标题恰好放行)。
    static func evaluate(request: ComputerActRequest,
                         scope: ComputerActScope,
                         target: ComputerActTarget?,
                         window: ComputerActWindow) -> ComputerActDecision {

        // ① op 合法性已在 `ComputerAction.parse` 那一步做完(解析不出来就进不到这里),
        //    这里不重复判 —— 但正因为不重复, 那条判据必须有自己的断言:
        //    `CaseComputerAct` 里 `ComputerAction.parse("click") == nil`(坐标点击**还没有**)。

        // ② 这个 App 在不在"能读"的名单里。
        //    ⚠️ helper 是先按作用域挑候选再挑 App 的, 所以正常路径下这条恒真 —— **保留它是因为
        //    "绕过一次判据零红灯"是本仓踩过的坑(守卫 24 同族): 换个调用顺序, 这条就成了唯一防线。
        guard scope.readBundles.contains(scope.bundle) else {
            return .refuse(reason: "「\(scope.appName)」不在开放名单里 ⇒ 我不动它。",
                           refusal: nil)
        }

        // ③ 在不在"能操作"的名单里。**读与操作是两档权限**, 读得到不等于动得。
        //
        // ⚠️ 口令/系统类在这里**再拦一次**, 不看名单里有没有它: 设置页勾不上, 但落盘值可能
        //    是老数据、手改过的库、或者将来某个导入功能带进来的。判据不能只活在一个位置上。
        guard scope.actBundles.contains(scope.bundle),
              !ComputerRedline.actBannedBundles.contains(scope.bundle) else {
            return .refuse(reason: actRefusalReason(scope), refusal: nil)
        }

        // ④ 手上这份快照是不是最新的。
        //    ⚠️ 必须排在"编号存在"之前: 反过来的话, 过期快照里恰好也有 #12 时会读到
        //    一个**语义完全不同**的元素, 而回执还会说"按了 #12", 看不出错。
        guard scope.requestSeq == scope.currentSeq else {
            return .refuse(
                reason: "#\(request.index) 属于旧快照(你手上 seq=\(scope.requestSeq), 现在是 \(scope.currentSeq))"
                    + " ⇒ 没动。重新读一次再决定。",
                refusal: nil)
        }

        // ⑤ 编号在这份快照里。
        guard request.index >= 1, request.index <= scope.rowCount else {
            return .refuse(
                reason: "这份快照里没有 #\(request.index)(一共 \(scope.rowCount) 项) ⇒ 没动。"
                    + "编号只对刚才那一次读有效, 重新读一次。",
                refusal: nil)
        }
        // ⑤b 编号查得到行, 行查得到元素。走到这里为 nil 说明 helper 那边的表与快照脱节了
        //     (理论上不该发生) —— 照样拒, 因为"查不到就是不动作"永远是对的。
        guard let target else {
            return .refuse(reason: "#\(request.index) 在这份快照里查不到对应元素 ⇒ 没动。重新读一次。",
                           refusal: nil)
        }

        // ⑥ 三条恒拒里的两条: 永久删除 / 付款。**判目标控件本身**。
        if let d = ComputerRedline.refusal(forControl: target.title,
                                           role: target.role,
                                           keyEquivalent: target.keyEquivalent,
                                           modifiers: target.modifiers) {
            return .refuse(reason: d.reason, refusal: d.refusal)
        }

        // ⑦ 第三条: 存盘确认。**判整个窗口** —— 目标是"不保存"按钮时第 ⑥ 条不会命中,
        //    而那一步恰恰最需要拦(模型替人决定丢弃未保存的修改)。
        if let d = ComputerRedline.savePromptDecision(title: window.sheetTitle,
                                                      buttons: window.sheetButtons) {
            // ⚠️ 找不到"取消"键 ⇒ **恒拒**, 不许退而求其次去点"不保存"或"保存"。
            guard let cancel = ComputerRedline.cancellationIndex(buttons: window.sheetButtons) else {
                return .refuse(reason: d.reason, refusal: .savePrompt)
            }
            return .cancelSavePrompt(buttonIndex: cancel, reason: d.reason)
        }

        // ⑧ 这个动作在这个控件上做不做得到。
        switch request.action {
        case .press:
            guard target.actions.contains("AXPress") else {
                let known = target.actions.isEmpty
                    ? "它一个动作都不提供"
                    : "它能做的只有：" + target.actions.joined(separator: " / ")
                return .refuse(
                    reason: "「\(displayName(target))」按不了 —— \(known) ⇒ 没动。",
                    refusal: nil)
            }
        case .setValue:
            // ⚠️ 密码框那条**必须排在"能不能写"之前**: `securetextfield` 本来就不在可写白名单里,
            //    先判角色会把它报成「不是能写字的地方」—— 结论一样但话术完全不同, 而模型看到
            //    前者会换个控件再试, 看到后者才知道"这一栏根本不许碰"。
            if target.isProtected
                || ComputerRedline.isPasswordRole(target.role, subrole: target.subrole) {
                return .refuse(reason: "这是密码框 ⇒ 我不往里写任何东西。", refusal: nil)
            }
            guard isWritableRole(target.role) else {
                return .refuse(
                    reason: "「\(displayName(target))」是 \(AXSnapshot.cleanRoleName(target.role)), "
                        + "不是能写字的地方 ⇒ 我不往里写。",
                    refusal: nil)
            }
            let text = request.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // ⚠️ 空串 `AXSetValue` = **清空输入框**。它不是"什么都没干", 是一次有后果的写。
                return .refuse(reason: "要写的内容是空的 ⇒ 没动。清空某一栏请你自己来。", refusal: nil)
            }
            guard text.count <= maxSetValueChars else {
                return .refuse(
                    reason: "要写的内容有 \(text.count) 个字, 超过 \(maxSetValueChars) 的上限 ⇒ 没写。"
                        + "这么长的东西多半是搞错了对象。",
                    refusal: nil)
            }
        case .focus:
            // ⚠️ 判据是**这个控件接受不接受聚焦**, 由 helper 现问 `AXUIElementIsAttributeSettable`
            //    (`target.canFocus`), 不是"它长得像输入框" —— 猜"能"就是一次点了没反应的动作。
            guard target.canFocus else {
                return .refuse(
                    reason: "「\(displayName(target))」不接受聚焦(系统说这个控件的焦点不可设) ⇒ 没动。"
                        + "要写内容请直接 setValue; 它连 AXValue 也不吃的话, 说明这类 App 只能靠"
                        + "坐标点击(还没做) —— 那就如实告诉用户。",
                    refusal: nil)
            }
        case .scroll:
            // 先判参数: 没说方向是**调用方写错了**, 与"这个 App 滚不动"是两件事, 下一步也不同
            // (前者重发一次, 后者换 App 或告诉用户)。
            guard request.direction != nil else {
                return .refuse(reason: "scroll 要说清往哪滚(up / down) ⇒ 没动。", refusal: nil)
            }
            guard target.canScroll else {
                // ⚠️ helper 是「自己 → 子树 → 上面四层」都找过的, 所以这句话说的是**找过**,
                //    不是"我觉得它没有" —— 回执不能比事实说得多。
                return .refuse(
                    reason: "「\(displayName(target))」附近没有可写的滚动条(它自己和上面几层都没有) ⇒ 滚不动。"
                        + "有些 App(尤其网页内容)不把滚动条交给系统 —— 那就趁早告诉用户这一页我一次读不完,"
                        + " 别反复换节点试。",
                    refusal: nil)
            }
        }

        // ⑨ 到此为止都成立。
        return .allow(request.action)
    }

    /// `setValue` 允许落的角色。**白名单**, 不是黑名单 —— 新角色默认不可写(漏 = 写不进去, 不是乱写)。
    ///
    /// ⚠️ 故意不含 `combobox`: 有些 App 的 combobox 是可编辑输入, 有些只是个选择器,
    ///    分不出来的时候**当成不能写**。
    static func isWritableRole(_ role: String) -> Bool {
        let r = AXSnapshot.cleanRoleName(role)
        return r == "textfield" || r == "textarea" || r == "searchfield"
    }

    /// ③ 的文案要分岔: "根本没给操作权限" 与 "给了但这类 App 不许操作" 是两件事 ——
    /// 前者去设置里勾一下就行, 后者勾了也不会生效(说成前者会让人在设置页里白找)。
    static func actRefusalReason(_ scope: ComputerActScope) -> String {
        if ComputerRedline.actBannedBundles.contains(scope.bundle) {
            return "「\(scope.appName)」是口令/系统类应用 ⇒ 我永远不操作它, 只读。"
        }
        return "「\(scope.appName)」只开了「读」, 没开「操作」⇒ 我不动它。"
            + "要让它能动, 请在 设置 › 集成 › 电脑操作 里给它开「可操作」。"
    }

    private static func displayName(_ target: ComputerActTarget) -> String {
        let t = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? AXSnapshot.cleanRoleName(target.role) : t
    }

    // MARK: 审批卡上那一行

    /// `press #12 · Safari` —— 审批卡与轨迹里显示给人看的那一行。
    ///
    /// ⚠️ 这里**不查标题**: 弹卡时判据还没跑(卡在动作之前), 此刻的标题既可能是"登录"
    /// 也可能是"删除", 写上去反而给了人一种"我确认过它是什么"的错觉。卡上只承诺
    /// **编号 + App**, 让人自己去界面上看那一条。
    static func preview(action: ComputerAction, app: String, index: Int) -> String {
        let verb: String
        switch action {
        case .press: verb = "按"
        case .setValue: verb = "写"
        case .focus: verb = "聚焦"
        case .scroll: verb = "滚动"
        }
        let who = app.trimmingCharacters(in: .whitespacesAndNewlines)
        return verb + " #" + String(index) + (who.isEmpty ? " · 当前前台" : " · " + who)
    }
}
