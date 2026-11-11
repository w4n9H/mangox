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

/// 模型能做的动作。⚠️ **只有七个**, 而且每一个都必须按**编号**寻址 ——
/// 多一个 op 就多一条"模型以为自己能动"的路(同 `PiRpcTransport.computerToolNames` 那条注释)。
///
/// 批 2b 只有 `press` / `setValue`; 批 2f 补了 `focus` / `scroll`, 两条都是**纯 AX**:
///   · `focus`: 不少 web / Electron 输入框**不吃** `setValue`(AX 返回成功, 值没变),
///     而"先点进去再发按键"要 CGEvent ⇒ 先把"能不能聚焦"这一半如实交出去。
///   · `scroll`: 长页面/长列表读不完 —— `AXSnapshot.rendered` 截断那句"需要的话让我滚动
///     再看"在批 2f 之前是**空头支票**(根本没有 scroll 这个 op, 模型照做只会撞"不认识的 op")。
/// 批 2g(2026-11-04)补了 `open` —— **它不是 `press` 的兜底, 是另一个动作**:
///   · 有些控件只暴露 `AXOpen`(日历右下角小月历的日期格子、Finder 桌面上的文件图标)。
///     在它们身上 `AXPress` 要么根本不在动作表里, 要么**返回 0 却什么都不做**;
///   · `AXOpen` 的语义是"打开/进入它指的东西"(打开那个文件、跳到那一天), 与"按一下"
///     后果不同 ⇒ 必须各是一个 op。合成一个的话, 审批卡上写"打开"、实现发的却是
///     `kAXPressAction` —— 人签的字就不是他以为的那件事。
///   · ⚠️ 实测(2026-11-04, 日历 + Finder): `AXOpen` 报 `-25205` 却真的生效,
///     `AXPress` 报 `0` 却空转 ⇒ **返回码两个方向都不可信**, 见 `ComputerOpenVerdict`。
/// 批 2k(2026-11-04)补了 `confirm` —— **它不是「回车键」, 也不是 `press` 的兜底**:
///   · 实测起因: 日历的「创建快速日程」浮层里只有 statictext + textfield, **没有「完成」按钮**;
///     文本框的 `AXActionNames` = `["AXShowMenu", "AXConfirm", "AXPress"]`, 而 `AXPress` 返回
///     `0` 却什么都不发生 —— 只有 `AXConfirm` 能把那条日程真正落库(隔离验证: 只发它, 事件生成)。
///   · 所以它是**第三件不同的事**: press = 按一下、open = 打开它指的东西、confirm = 提交我刚写进去的值。
///   · ⚠️ **只对文本输入类角色放行**(`isConfirmableRole`)。放开到任意控件, `confirm` 就是一个
///     通用的「确认」后门 —— 付款 / 删除确认框上的默认按钮都吃这一手, 而恒拒三条拦的是**标题
///     与角色**, 一个"通用确认"会把它们整个绕过去。
/// 批 2n(2026-11-05)补了 `showmenu` —— **它不是 `press` 的兜底, 是"把够不着的功能摆出来"**:
///   · 实测起因: 备忘录删笔记 / 日历删日程 / 访达新建文件夹**三条场景全卡在同一个缺口上** ——
///     功能只在**上下文菜单**里, 窗口里的控件一个都不承载它。旧的动作集只有
///     press / setValue / focus / scroll / open / confirm,**没有任何一个能打开菜单**,
///     SOP 因此写下"这三件我做不到, 请人来" —— 那是**产品缺口被写成能力边界**(boss 当场否掉)。
///   · 为什么不能再塞进 `press`: 有些控件动作表里同时有 `AXPress` 与 `AXShowMenu`, 而它们做的是
///     **两件不同的事**(按一下 vs 把它的菜单摆出来)。合成一个, 审批卡上写"按", 人签字签的
///     就不是实际发生的事 —— 与 `open` 那条同一条理由。
///   · ⚠️ 它**只负责把菜单摆出来**, 不替人选。菜单项会带着新编号出现在**重读**里, 选哪一项是
///     下一手的 `press`, 那一步照样要过全部九条判据(含恒拒三条) —— 见 `ComputerRedline`。
/// 批 2p(2026-11-05)补了 `custom` —— **执行元素自己声明的那个具名动作**(不是 AX 标准动作):
///   · 起因是把 `showmenu` 那条结论推翻的那次实测: 备忘录列表行的动作表是
///     `["AXShowMenu", "Name:置顶…", "Name:共享…", "Name:删除…"]` —— **没有 `AXPress`、没有 `AXOpen`**,
///     所以"先点开某一条让它成为选中项, 再开菜单删"这条组合**在 AX 里第一步就没有入口**。
///   · 但同一行自己挂着 `Name:删除`。隔离实验(2026-11-05, 两条测试笔记): 编辑器里开着「乙条」,
///     对**甲条那一行**执行 `Name:删除` ⇒ 甲条进最近删除、乙条原地不动。
///     ⇒ **自定义动作是行作用域**; 而 `showmenu` 的菜单项是**选中作用域**(删的是编辑器里
///       开着的那条 —— 当天误删真笔记就是这个原因)。作用域不同, 不是同一件事的两种做法。
///   · 为什么 op 名不是 `delete`: 自定义动作的名字是**目标 App 起的**, 而且会本地化。
///     把它写进枚举等于假设全世界都叫「删除」。这里只承诺"执行它自己声明的某个动作",
///     名字由调用方给(片段匹配、必须唯一命中), 见 `ComputerCustomAction`。
///   · ⚠️ `custom` **不许碰 AX 标准动作**: 匹配只落在不以 `AX` 开头的名字上。否则
///     `custom("AXPress")` 就是给 `press` 那条判据开的后门。
/// 坐标点击仍然不做: 它绕开编号("我看见的节点 = 我点的东西"这个等式没了), 要等人类接管那批。
enum ComputerAction: String, Equatable, CaseIterable {
    case press
    case setValue
    case focus
    case scroll
    case open
    /// 确认/提交这一格 = `AXConfirm`(批 2k, 2026-11-04)。见文件头 `confirm` 那一段。
    case confirm
    /// 打开这一格的**上下文菜单** = `AXShowMenu`(批 2n, 2026-11-05)。
    ///
    /// ⚠️ **已实现, 但没对模型开放** —— 见 `exposed`。原因是它的作用域判不了:
    ///    菜单到底作用于"这一格"还是"当前选中项", AX 里**没有任何属性可以问**。
    ///    实测备忘录就是选中作用域(删掉了编辑器里开着的那条, 不是右键的那条) ⇒ 不可逆操作
    ///    不能建在一个猜出来的作用域上。代码留着: 它是"判据在、但门关着"的证据,
    ///    哪天真有 App 证明是元素作用域, 打开它就是往 `exposed` 里加一项。
    case showmenu
    /// 执行元素自己的**具名自定义动作**(批 2p, 2026-11-05)。见文件头 `custom` 那一段。
    case custom

    /// 线上给的 `op` 字符串 → 动作。**不认识的 op 返回 nil**, 由调用方拒掉。
    ///
    /// ⚠️ 单独抽出来是为了能断言: 线上把 `op` 写成 `"click"` / `"PRESS"` 时, 解码要是
    ///    默默落到某个默认分支, 就等于"扩展侧改名之后一切照常"。
    static func parse(_ raw: String) -> ComputerAction? {
        ComputerAction(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// **对模型开放的**动作。不在这张表里的 op: 认得出来, 但一律拒 ——
    /// 这样回执才说得清是"还没开放"而不是"不认识", 而这两句话让模型走向完全不同的下一步
    /// (换个说法重发 vs 换一条路)。
    ///
    /// ⚠️ 这张表是**唯一**的开放判据, 工具 schema 里那个 enum 只是它的影子。两处若漂移,
    ///    症状是"模型调得到但服务端拒"或反过来 —— 两种都没有红灯。冒烟单独钉住这一条。
    static let exposed: [ComputerAction] = [.press, .setValue, .focus, .scroll,
                                            .open, .confirm, .custom]
}

/// 元素自己声明的**自定义动作** —— 名字是目标 App 起的, 形如
/// `Name:删除\nTarget:0x0\nSelector:(null)`: 会本地化、还拖着一条噪音尾巴。
///
/// 这个类型只做三件事(全是纯函数, 所以判据留在这一侧): 认出哪些算自定义动作、把名字洗成
/// 人能读的样子、按片段**唯一**命中。执行在 helper —— 它只要那个原始名字。
///
/// ⚠️ 为什么不能直接把 `Name:删除\nTarget:0x0\nSelector:(null)` 交给模型照着抄:
///    那不是给人看的字符串, 抄错一个字节就是另一个动作(或者什么都没有)。让模型说人话
///    ("删除"), 由这一层去找, 找不到/找到多个都如实拒 —— 三种结果都是可断言的。
enum ComputerCustomAction {

    /// 只留**非 AX 标准动作**。
    ///
    /// ⚠️ `AXPress` / `AXOpen` / `AXShowMenu` / `AXConfirm` 一律不算: 它们是别的 op 的地盘,
    ///    从 `custom` 进来就等于绕过那些 op 各自的判据(比如 `confirm` 的角色白名单)。
    static func available(_ actions: [String]) -> [String] {
        actions.filter { !$0.hasPrefix("AX") }
    }

    /// 洗过的名字: `Name:删除\nTarget:0x0\nSelector:(null)` → `删除`。
    ///
    /// 没有 `Name:` 前缀就把整串修剪一下 —— 有些 App 直接把动作就叫 `Format`。
    static func humanName(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "Name:") { s = String(s[r.upperBound...]) }
        if let cut = s.firstIndex(where: { $0 == "\n" || $0 == "\r" }) { s = String(s[..<cut]) }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : t
    }

    enum Match: Equatable {
        case none
        /// 唯一命中 —— 里面是**原始动作名**(执行要用它, 不是洗过的那个)。
        case one(String)
        /// 命中多个(原始动作名)。分不清就不做。
        case many([String])
    }

    /// 按片段匹配。**必须唯一命中**: 多个候选一律交回, 让调用方要求说清楚。
    ///
    /// ⚠️ 匹配的是**洗过的名字**而不是原始串: 原始串里 `Target:0x0` / `Selector:(null)` 这些
    ///    噪音会让"任意片段都能命中一堆动作", 唯一性判据当场失效。
    static func match(_ actions: [String], needle: String) -> Match {
        let n = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return .none }
        let hits = available(actions).filter {
            humanName($0).localizedCaseInsensitiveContains(n)
        }
        if hits.count == 1 { return .one(hits[0]) }
        return hits.isEmpty ? .none : .many(hits)
    }
}

/// `open` 的返回值怎么读 —— **纯函数, 所以判据留在这一侧**(helper 在没授权、没屏幕的机器上
/// 测不了; 同 `AXAdapter` 头注释那条"能测的部分不许留在那边")。
///
/// ⚠️ 这二十几行是本次改动里**唯一不像"再加一个 case"的地方**, 因为实测发现 AX 的返回码
///    在 `AXOpen` 上**不可信**, 而且两个方向都不可信:
///      · `AXOpen` 打日历的日期格子 ⇒ 返回 **-25205**(`kAXErrorAttributeUnsupported`),
///        可界面**真的跳到了那一天**(周视图 11/1 那周 → 11/15 那周, 三次复现);
///      · `AXPress` 打同一个格子 ⇒ 返回 **0**(`success`), **什么都没发生**。
///    ⇒ 照别的动作用 `guard err == .success` 的话, 一次**成功**的打开会被回成"打不开";
///      模型下一手必然是重试 ⇒ 同一天被跳两次、同一个文件夹被打开两次。
///    ⇒ 所以这里**反过来**: 默认按"动作已经送到、界面可能动了"记, 只有下面那一个码能证明
///      "连元素都不在了、动作根本没发出去"。
///    ⚠️ 为什么不是白名单(只认 0 和 -25205): 未知码按"失败"记的代价是**重复动作**,
///      按"可能成功"记的代价是"模型多读一遍" —— 后者自愈, 前者不自愈。
enum ComputerOpenVerdict: Equatable {
    /// 返回 0: 送进去了。界面**可能**已经动了。
    case accepted
    /// 返回了别的码(实测 -25205), 但那个码在 `AXOpen` 上不可信 ⇒ 按"可能动了"记, 回执要写明。
    case acceptedWithSuspectCode(Int32)
    /// `kAXErrorInvalidUIElement`(-25202): 元素已经不在了, 动作**根本没发出去**。
    case notDelivered

    /// - Parameter raw: `AXUIElementPerformAction` 的原始返回码。
    static func classify(_ raw: Int32) -> ComputerOpenVerdict {
        if raw == 0 { return .accepted }
        // -25202 = kAXErrorInvalidUIElement。只有它说明"连那个元素都没了"。
        if raw == -25202 { return .notDelivered }
        return .acceptedWithSuspectCode(raw)
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

// MARK: - 值这一侧: 读成什么、怎么写回去 (批 2m, 2026-11-04)

/// 一个 AX 值**是什么类型** —— 决定"怎么写回去"。由 helper 现场问属性得到。
///
/// ⚠️ 为什么需要它: `setValue` 原来**只会写 CFString**, 而日历事件编辑器里那四个时间格子
///    (`AXDateTimeArea`, id `start-timepicker` …) 的 `AXValue` 是 **CFDate**。
///    实测(2026-11-04): 拿字符串去写它, 系统回 **-25201**(`kAXErrorIllegalArgument`),
///    界面纹丝不动 ⇒ "把日程改到 17:30"在只会写字符串的实现里**结构上做不到**,
///    而回执只会说"写失败", 让人看不出缺的是**类型**而不是权限。
///    同一个洞在**读**那一侧也漏了(日期读成 nil ⇒ 那四格在快照里连值都没有), 见
///    `AXAdapter.string`。
enum ComputerValueShape: Equatable {
    case text
    case date
    /// 既不是文本也不是日期(数组 / 元素 / 结构化值)。**维持旧行为**: 照字符串写。
    case other
}

/// `setValue` 落到一个格子上该**怎么写**。
///
/// ⚠️ 这是纯函数(`AXAdapter` 只负责执行), 因为"写什么"是判据不是实现 —— 而 helper 在没授权、
///    没屏幕的机器上测不了, 判据必须留在能被冒烟断言的一侧(同本文件头注释那条)。
enum ComputerWritePlan: Equatable {
    case text
    case date(Date)

    /// ⚠️ `timeZone` 必须**能显式传**: 不传 = 本机时区(与 `parse` / `display` 同一个缺省, 生产上
    ///    两边都走 `.current` ⇒ 读到什么样子就能写回什么样子)。
    ///    **判据里不许靠这个缺省**: 一条"用固定时区渲染、却让它自己去取 `.current`"的断言, 在 UTC
    ///    的 runner 上必红, 而本地(GMT+8)一直绿 —— 因为那里两个时区恰好同源。v0.2.5 的 CI 就是
    ///    这么翻的: 唯一一条红, 症状离原因很远。
    static func decide(shape: ComputerValueShape, text: String,
                       timeZone: TimeZone = .current) -> ComputerWritePlan {
        guard shape == .date, let d = ComputerDateValue.parse(text, timeZone: timeZone) else {
            return .text
        }
        return .date(d)
    }
}

/// 日期文本 ⇄ `AXValue` 里那个 `CFDate`。**两个方向同一套格式**, 因为"读到的样子 = 能写回去
/// 的样子"是最省事故的一条规矩: 模型在快照里看见 `2026-11-04 17:30`, 照抄回来就该能写进去。
///
/// ⚠️ **只认几种写死的格式, 不做自然语言猜测**("明天下午三点"这类解析不在这里): 猜错的代价是
///    把日程挪到**别的日子**, 而且不会有任何红灯。认不出来就如实回一句, 让调用方换一种写法。
enum ComputerDateValue {

    /// 认的格式, 依次试。`yyyy-MM-dd HH:mm` 必须排前面 —— 它就是快照里的那一款。
    static let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "HH:mm"]

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        // ⚠️ `en_US_POSIX` 不是洁癖: 跟随用户区域设置的话, 在佛教历/民国历的系统上
        //    "2026" 会被解析成完全不同的年份, 而且要命的是**解析成功**。
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    /// 文本 → 日期。只给 `HH:mm` 时按**今天**补日期(用户说"改到 17:30"说的就是那一天)。
    static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        for format in formats where format != "HH:mm" {
            if let d = formatter(format, timeZone: timeZone).date(from: t) { return d }
        }
        guard let hm = formatter("HH:mm", timeZone: timeZone).date(from: t) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let parts = cal.dateComponents([.hour, .minute], from: hm)
        var base = cal.dateComponents([.year, .month, .day], from: now)
        base.hour = parts.hour
        base.minute = parts.minute
        base.second = 0
        return cal.date(from: base)
    }

    /// 日期 → 文本(快照里给人看、也给模型照着写回来)。
    static func display(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd HH:mm", timeZone: timeZone).string(from: date)
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

// MARK: - 纯视觉动手（2026-11-10, 第四档）

/// 按坐标点一下 —— **不经过任何 `AXUIElement`**。
///
/// 存在的唯一原因: 有些 App 的 AX 树只剩窗口外壳(微信实测 5 节点 / 覆盖率 0%), 一条编号都没有,
/// 而**图是看得见的**。`press` 的 `point` 走的是"翻译回元素"(`AXUIElementCopyElementAtPosition`),
/// 那类 App 永远翻译不回来 ⇒ 结构上看得到、一步也动不了。这一档补的就是它。
///
/// ⚠️ **它不是 `press + point` 的放宽版, 是另一条路**:
///    · `press` 的判据跑在**元素**上(三条恒拒 / 可写角色白名单 / 子动作表), 而这里没有元素;
///    · 所以它自带一整套闸门(下面每条), 一条不过就拒, 且**每条说自己的话** ——
///      合成一句"条件不满足"等于让人猜是哪一条, 而人猜错的下一步通常是"再试一次"。
///    · 越界的动作(`setValue` / `confirm` / `custom`)一律不走这条路: 那三个的语义建在
///      role 上, 没有 role 就没有判据。tap 只能"点一下"。
///
/// ⚠️ **代价必须写在脸上**: 它用**真鼠标**。2026-11-10 在计算器上实测: 从挪光标到还回去
///    **74ms**, 归位精确到 0.0。但那 74ms 里光标真的在人眼前跳了一下 —— 所以下面有一半的闸
///    是在确认"人这一刻没在用鼠标", 而且提示词与回执都不许把它说成"不打扰"。
///
/// ⚠️ 为什么不走 `CGEvent.postToPid`(只投给目标进程、不动光标): **实测不通**。三种变体
///    (原样 / 补 `mouseEventWindowUnderMousePointer` / 先补一个 `mouseMoved`)在同一个坐标上
///    全部点不动, 而同坐标的 HID 投递一次就成 —— AppKit 不认按 pid 投递的鼠标事件。
///    数据在 `.workbuddy/memory/2026-11-10.md`(第五节)。谁要改回 pid 投递, 先复现那一组。
enum ComputerTapRule {

    /// 全局档的 env 键。**要就写 "1", 不要就删掉**(同 `MANGOX_COMPUTE_TAKEOVER`)。
    ///
    /// ⚠️ 键名住在**判据文件**里而不是各写一份: 本文件同时编进 App 与 helper 两个 target
    ///    (`mangox-compute` 的 Sources 里有它), 所以两边引用的是**同一个常量**。
    ///    抄成两个字面量的话, 改名那天不会编译报错, 只会**静默变成"档永远关着"** ——
    ///    而界面上那个开关是开着的(`run.sh` ③ 那种跨 target 契约扫描就是这么来的)。
    static let envKey = "MANGOX_COMPUTE_TAP"

    /// 人最后一次动键鼠之后, 至少消停这么久才允许点。
    ///
    /// ⚠️ **不能复用 `ComputerTakeover.quietSeconds`(6 秒)**: 那条的语义是"这一轮让人,
    ///    等机器静下来再继续", 6 秒合理; 这一条的语义是"按下去之前的 400ms 里人手上没东西",
    ///    6 秒会让人想手动点一下都得先空等 —— 而人一旦不耐烦, 恰恰最可能在模型点的瞬间碰鼠标。
    /// ⚠️ 也不能是 0: 取 0 等于"人正握着鼠标也照点", 而实测里人和模型同时抢鼠标是唯一
    ///    真的踩过的坑(点错且无撤销)。
    static let humanQuietMs = 400

    /// 坐标底下读到这些字就**不点** —— 与 `press` 那两条恒拒**同一份词表**(同源, 不抄第二份)。
    ///
    /// ⚠️ 为什么是"派生"而不是自己列一份: 两份词表会漂 —— 而漂了之后同一个动作(比如付款)
    ///    按编号会被拦、按坐标会放行, 于是"哪条路能过"变成了入口的属性, 不是动作的属性。
    ///    那正是本仓最忌讳的一种不一致(同"两处各写一遍判据")。
    /// ⚠️ 这一档的语义闸**必然弱于** `press`: `press` 判的是目标控件的角色与标题(高置信),
    ///    这里只判"这一点底下的几个字"(可能是正文)。所以它会**误伤** —— 正文里写着
    ///    "立即删除"的那一段会挡住一次合法的点击。认了: 误伤的代价是"这一步没点, 人自己来",
    ///    而漏判的代价是"替你点了付款"。两个方向不对称, 所以宁可误。
    /// ⚠️ 不另收裸的「删除」: `press` 也不拦它("移到废纸篓"必须放行), 这里加进来就又比
    ///    `press` 严了 —— 同一个动作换个入口就不做了, 模型只会学到"别用 tap"。
    static var taintedWords: [String] {
        ComputerRedline.paymentWords + ComputerRedline.permanentDeleteWords
    }

    /// 一次 tap 的全部输入。**全是事实** —— 没有一个"大概", 判据只对照它们。
    ///
    /// ⚠️ 为什么把事实摊成一个结构而不是让判据自己去问系统: 与 `ComputerActScope` /
    ///    `ComputerTakeover` 同一条纪律 —— 取事实的那一步(进程表 / 窗口表 / TCC)有坑且不可测,
    ///    而"拿到之后怎么判"是纯的。摊开之后每条闸都能在冒烟里造出来。
    struct Facts {
        /// 全局档(设置页那个开关)。**默认关**。
        var tapEnabled: Bool
        /// 这个 App 勾了「可操作」没有。
        var appActable: Bool
        /// 回执里点名用的显示名。
        var appName: String
        /// 上次 read 时那个进程, 与此刻的进程 —— 不相等 = App 重启过。
        var snapshotPid: Int32
        var currentPid: Int32
        /// 此刻前台是不是它。后台点不动(实测), 而且**会把它拽到前面**。
        var isFrontmost: Bool
        /// 此刻有没有鼠标键按着。**拖拽时手是静止的** ⇒ 光看"人静"会放行,
        /// 而那一下正好插在人家拖拽中间。
        var leftButtonDown: Bool
        var rightButtonDown: Bool
        /// 最近一次人类输入距今多少毫秒。`nil` = 监听没装上(拿不到事实, 不假装判断过)。
        var sinceHumanInputMs: Int?
        /// 要点的那个点(全局屏幕坐标, 左上原点)。
        var point: ComputerPoint
        /// 上次 read 记下的窗口外框, 与此刻的窗口外框。
        var snapshotFrame: AXRect?
        var currentFrame: AXRect?
        /// 上次 read 记下的窗口号(`0` = 读的时候没认出来), 与此刻这点上最顶层窗口的窗口号。
        var snapshotWindowNumber: Int
        var topWindowNumber: Int
        var topWindowPid: Int32
        /// 这一点底下能读到的文字(读不到就是空串)。
        var textUnderPoint: String
    }

    /// 两个外框算不算"同一个窗口位置"。容差 2px: AX 报的是整数, 而系统那边可能有亚像素抖动。
    static func sameFrame(_ a: AXRect?, _ b: AXRect?, tolerance: Int = 2) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.w - b.w) <= tolerance && abs(a.h - b.h) <= tolerance
    }

    /// 点在框里没有。**右下边界不含**(`x < x+w`): 窗口右边那一列属于隔壁。
    static func contains(_ rect: AXRect?, _ p: ComputerPoint) -> Bool {
        guard let r = rect else { return false }
        return p.x >= Double(r.x) && p.x < Double(r.x + r.w)
            && p.y >= Double(r.y) && p.y < Double(r.y + r.h)
    }

    /// 文字里命中的第一个恒拒词。`nil` = 没命中(或压根没读到字)。
    static func taintedHit(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return taintedWords.first(where: { t.contains($0) })
    }

    /// 拒(`nil` = 可以点)。**顺序即代价序**: 先判不要钱的, 最后才碰窗口表。
    static func refusal(_ f: Facts) -> String? {
        // ① 档位
        guard f.tapEnabled else {
            return "「按坐标点击」这一档关着 ⇒ 没点。"
                + "它默认关是因为可能点错、而且点错了没有撤销 ——"
                + " 要开就在 设置 › 集成 › 电脑操作 里打开。"
        }
        // ② 这个 App 有没有被允许动
        guard f.appActable else {
            return "「\(f.appName)」还没勾「可操作」⇒ 没点。看得到不等于动得。"
        }
        // ③ 同上一次读的是不是同一个进程
        guard f.snapshotPid == f.currentPid else {
            return "「\(f.appName)」重启过了 ⇒ 你手上那份快照说的不是这个窗口, 没点。重新 read 一次。"
        }
        // ④ 前台
        guard f.isFrontmost else {
            return "「\(f.appName)」不在前台 ⇒ 没点。"
                + "后台点不动(实测前后两帧一模一样), 而且真点下去会把它拽到最前面。"
                + "先 computer_open 把它切上来, 再点。"
        }
        // ⑤ 手上按着键
        guard !f.leftButtonDown, !f.rightButtonDown else {
            return "你此刻正按着鼠标键(可能在拖拽) ⇒ 没点。松开之后再说一次。"
        }
        // ⑥ 人刚动过
        if let ms = f.sinceHumanInputMs, ms < humanQuietMs {
            return "你 \(ms) 毫秒前刚动过键鼠 ⇒ 没点。"
                + "这一档用的是**真鼠标**, 我不能在人手上抢 —— 稍等一下再说一次。"
        }
        // ⑦ 坐标本身
        guard abs(f.point.x) <= ComputerPointRule.maxAbsCoordinate,
              abs(f.point.y) <= ComputerPointRule.maxAbsCoordinate else {
            return "\(f.point.short) 不像屏幕上的点 ⇒ 没点。坐标是全局屏幕坐标、左上原点。"
        }
        // ⚠️ 这里**不另判"在不在某个屏幕上"**: ⑩ 已经把点钉在这个 App 的窗口里了, 而窗口
        //    总在某个屏幕上。多判一道就要把 NSScreen 的**左下原点**换成左上原点, 那一步错了
        //    会让每一次 tap 都被拒, 而错误信息长得像"模型算错了坐标"。
        // ⑧ 快照有没有记下窗口位置
        guard let snap = f.snapshotFrame else {
            return "这份快照没记窗口位置 ⇒ 判不了 \(f.point.short) 是对着哪个窗口的 ⇒ 没点。"
                + "重新 read 一次(这次的快照会带上窗口外框)。"
        }
        // ⑨ 窗口挪没挪
        guard sameFrame(snap, f.currentFrame) else {
            let now = f.currentFrame.map { $0.short } ?? "读不到了"
            return "「\(f.appName)」的窗口挪过: 原来 \(snap.short), 现在 \(now) ⇒ 没点。"
                + "图上的位置是相对窗口的, 窗口一动就全偏 —— 重新 read 一次再算。"
        }
        // ⑩ 点在不在这个窗口里
        guard contains(snap, f.point) else {
            return "\(f.point.short) 不在「\(f.appName)」的窗口 \(snap.short) 里 ⇒ 没点。"
        }
        // ⑪ 这一点上最顶层的是不是它
        guard f.topWindowPid == f.currentPid else {
            return "\(f.point.short) 落在**别的 App** 的窗口上(不是「\(f.appName)」) ⇒ 没点。"
                + "要么窗口被挪走了, 要么这个点是照着另一张图算的。"
        }
        // ⑫ 有没有弹层盖在上面(同 pid 同 owner, 只比进程会放行)
        if f.snapshotWindowNumber != 0, f.topWindowNumber != f.snapshotWindowNumber {
            return "\(f.point.short) 上盖着「\(f.appName)」的另一个窗口(弹层 / 对话框) ⇒ 没点。"
                + "先处理弹层, 或者重新 read 一次按新的来。"
        }
        // ⑬ 底下写着什么
        if let word = taintedHit(f.textUnderPoint) {
            return "\(f.point.short) 底下写着「\(word)」 ⇒ 没点。"
                + "按坐标点这一档认不出控件语义, 这类词一律不替你点 —— 这一步你自己点。"
        }
        return nil
    }
}

/// 往**当前焦点**里写一段字(第五档, 2026-11-10)。
///
/// ⚠️ 为什么是独立一档而不是 `act` 的第八个动词: 与 `tap` 同一条理由 —— `ComputerActGuard`
///    那九条判据的输入是"元素", 而这一档压根没有元素, 它的语义就是"往焦点里写"。
///
/// ⚠️ 为什么不能复用 `setValue`: 那条路要求先把目标**翻译回元素**, 而微信那类 App 的
///    `CopyElementAtPosition` 永远回 `AXApplication` 自己 ⇒ 结构上写不进去(实测 5 节点 / 覆盖率 0%)。
///    键盘事件不认元素, 所以这是唯一能到得了那种界面的路。
///
/// ⚠️ 与 `tap` **各自一档**(两个 env 键、两个开关), 不合成一个: 它们同属"模拟输入", 但风险
///    不是一件事 —— 点错的位置当场看得见, 而打进输入框的字**可能被下一拍回车发出去**。
///    开关的语义必须与它管的那件事同一个(见 `ComputerPermission` 那次教训), 合成一个就等于
///    让用户点一次同时授权两件不同的事。
enum ComputerTypeRule {

    /// 这一档的 env 键。**要就写 "1", 不要就删掉**(同 `MANGOX_COMPUTE_TAP` / `MANGOX_COMPUTE_TAKEOVER`)。
    static let envKey = "MANGOX_COMPUTE_TYPE"

    /// 人最后一次动键鼠之后, 至少消停这么久才允许写。
    ///
    /// ⚠️ 与 `tap` 取了同一个数, 但**理由不同**: tap 那条防的是"抢鼠标导致点错", 这条防的是
    ///    "人正打着字, 我把字插进他那一行里"。人在连续输入时这个计时器一直被刷新 ⇒ 真在打字的人
    ///    天然被挡住, 这正是要的效果。
    /// ⚠️ 不能是 0: 那是"人正打着字我也照写"。
    static let humanQuietMs = 400

    /// 一次最多写多少。**防的不是攻击, 是失控**: 模型把一整篇文档当 `text` 塞进一个聊天输入框,
    /// 那一下既撤不回(可能被下一拍回车发出去), 也会把界面撑爆。
    static let maxChars = 2000

    /// 焦点落在这些角色上, 才算"在写字"。
    ///
    /// **白名单**, 不是黑名单: 不认识的控件一律按"不是输入框"处理。方向是刻意选的 ——
    /// 误挡的代价是"这一步没写, 人自己打"; 漏放的代价是往列表 / 画布里敲字符, 而那些字符
    /// 在不少 App 里是**动作**(Finder 敲一个 `f` 就跳到某个文件, 空格是预览, 回车是打开)。
    ///
    /// ⚠️ `AXWebArea` 也收: 网页里的 contenteditable 在不同浏览器上会报成 `AXTextArea`
    ///    或 `AXWebArea`, 只认前者会把"在网页输入框里打字"整条路挡掉。
    /// ⚠️ 这个判据**只在读得到焦点时**生效: 微信那种 AX 恒空的 App 一律读到 `nil`,
    ///    那边放行 —— 它恰恰是这一档唯一的真实用例(见 `Facts.focusedRole`)。
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea",
    ]

    /// 一次 type 的全部输入。**全是事实**, 判据只对照它们(同 `ComputerTapRule.Facts` 的纪律)。
    struct Facts {
        /// 全局档(设置页那个「模拟键盘输入」开关)。**默认关**。
        var typeEnabled: Bool
        /// 这个 App 勾了「可操作」没有。
        var appActable: Bool
        var appName: String
        /// 上次 read 时那个进程, 与此刻的进程 —— 不相等 = App 重启过, 焦点归谁不知道。
        var snapshotPid: Int32
        var currentPid: Int32
        /// 键盘事件发给**前台** App。不在前台时写进去的是别人的焦点。
        var isFrontmost: Bool
        var leftButtonDown: Bool
        var rightButtonDown: Bool
        /// 最近一次人类输入距今多少毫秒。`nil` = 监听没装上(拿不到事实, 不假装判过)。
        var sinceHumanInputMs: Int?
        var text: String
        /// 写完要不要补一次回车。
        var submit: Bool
        /// 焦点落在哪个角色上。**`nil` = 这个 App 答不出来**(微信这类 AX 恒空)。
        ///
        /// ⚠️ 这一格是"能判就判, 判不了不假判": 有值 ⇒ 必须落在 `editableRoles` 里;
        ///    `nil` ⇒ 放行, 但调用方要在回执里写明"这一格没判过"。不判的原因不是懒 ——
        ///    是微信那棵树里**没有**这个属性, 判不了。
        var focusedRole: String? = nil
    }

    /// 文本里的换行 / 控制字符。`nil` = 干净。
    ///
    /// ⚠️ 换行必须单独拦: 键盘注入的"回车"与文本里的 `\n` 在很多 App 里是同一件事 ——
    ///    微信 / Slack / iMessage 的默认设置都是"回车 = 发送" ⇒ 一段带 5 个换行的文本会变成
    ///    **5 条消息**, 而模型以为自己只写了一段字。这条不能靠调用方自觉。
    ///
    /// ⚠️ 连带拦 C0 控制字符与 U+2028/2029(行分隔符): 它们注入进去会变成什么, 取决于目标 App,
    ///    而我们连它是哪个控件都不知道 —— 窄口里不认识的输入一律不放行。
    static func offendingCharacter(_ text: String) -> Character? {
        for ch in text {
            for s in ch.unicodeScalars {
                if s.value < 0x20 || s.value == 0x7F || s.value == 0x2028 || s.value == 0x2029 {
                    return ch
                }
            }
        }
        return nil
    }

    /// 拒(`nil` = 可以写)。**顺序即代价序**: 先判不要钱的, 最后才碰进程表与监听。
    static func refusal(_ f: Facts) -> String? {
        // ① 档位
        guard f.typeEnabled else {
            return "「模拟键盘输入」这一档关着 ⇒ 没写。"
                + "它默认关是因为写进去的字可能被下一拍回车发出去、而发出去撤不回 ——"
                + " 要开就在 设置 › 集成 › 电脑操作 里打开。"
        }
        // ② 这个 App 有没有被允许动
        guard f.appActable else {
            return "「\(f.appName)」还没勾「可操作」⇒ 没写。看得到不等于动得。"
        }
        // ③ 空的字 + 要回车 —— 那不是打字, 是"光按一下回车"
        let body = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return f.submit
                ? "只给了回车、没给要写的字 ⇒ 没按。回车在不少 App 里就是「发出去 / 确定」,"
                    + " 这一档不替你单按它 —— 要发就先把内容写上。"
                : "没给要写的字 ⇒ 没写。"
        }
        // ④ 换行 / 控制字符
        if let bad = offendingCharacter(f.text) {
            let scalar = bad.unicodeScalars.first.map { String(format: "U+%04X", $0.value) } ?? ""
            // ⚠️ 判别用**布尔**, 不用 `what == "换行"` —— 拿一个显示字面量当判别键,
            //    改文案那天比较就静默变成恒假(同 `ToolDetail.key` / `KnowledgeKind.tag` 那一族)。
            let isLineBreak = scalar == "U+000A" || scalar == "U+000D"
            let what = isLineBreak ? "换行" : "控制字符 \(scalar)"
            var why = "文本里有\(what) ⇒ 没写。"
            if isLineBreak {
                why += "回车在不少 App 里等于发送, 一段带换行的字会变成好几条消息。"
                    + " 要分多段就分几次写。"
            }
            return why
        }
        // ⑤ 量
        guard f.text.count <= maxChars else {
            return "要写 \(f.text.count) 个字, 超过这一档的上限 \(maxChars) ⇒ 没写。"
                + " 分段写(或者让人自己粘贴)比一次塞进去安全 —— 塞进去之后想改也没法改。"
        }
        // ⑥ 同上一次读的是不是同一个进程
        guard f.snapshotPid == f.currentPid else {
            return "「\(f.appName)」重启过了 ⇒ 你手上那份快照说的不是这个窗口, 焦点落在哪儿也不知道, 没写。"
                + "重新 read 一次。"
        }
        // ⑦ 前台: 键盘事件发给谁, 由系统当前的前台 App 决定
        guard f.isFrontmost else {
            return "「\(f.appName)」不在前台 ⇒ 没写。"
                + "键盘事件会落到**此刻在前台的那个 App** 的焦点里, 不是你指定的这个。"
                + "先 computer_open 把它切上来。"
        }
        // ⑧ 手上按着键(可能在拖拽 / 多选)
        guard !f.leftButtonDown, !f.rightButtonDown else {
            return "你此刻正按着鼠标键 ⇒ 没写。松开之后再说一次。"
        }
        // ⑨ 焦点落在什么控件上 —— **读得到才判**(读不到是微信那一档, 见 `Facts.focusedRole`)
        if let role = f.focusedRole, !editableRoles.contains(role) {
            return "「\(f.appName)」此刻的焦点在「\(role)」上, 不是能写字的输入框 ⇒ 没写。"
                + "先点进输入框(或者用 computer_act 的 focus)再写。"
                + "往列表 / 表格里敲字符会变成「按键跳转」, 那是动作, 不是打字。"
        }
        // ⑩ 人刚动过键鼠
        if let ms = f.sinceHumanInputMs, ms < humanQuietMs {
            return "你 \(ms) 毫秒前刚动过键鼠 ⇒ 没写。"
                + "人正在打字时我不往他那行里插字 —— 稍等一下再说一次。"
        }
        return nil
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
    /// 它的 `AXValue` 是什么类型 —— `setValue` 据此决定**写字符串还是写日期**(批 2m)。
    ///
    /// ⚠️ 默认 `.text` 保住旧调用点与 Mock 的写法; 真机上由 `AXAdapter.liveTarget` 现问。
    let valueShape: ComputerValueShape

    init(role: String,
         subrole: String = "",
         title: String,
         actions: [String] = [],
         isProtected: Bool = false,
         keyEquivalent: String? = nil,
         modifiers: Set<String> = [],
         canFocus: Bool = false,
         canScroll: Bool = false,
         valueShape: ComputerValueShape = .text) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.actions = actions
        self.isProtected = isProtected
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.canFocus = canFocus
        self.canScroll = canScroll
        self.valueShape = valueShape
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

        // ⚠️ 这里**曾经**有一条 ⑤b「网页内容一律不动」（2026-11-06 立，2026-11-09 撤）。
        //
        // 撤掉的理由不是它判错了, 而是**它把 Safari 变成了只能看不能用的东西**:
        //   真机一量, 「打开百度 → 输入检索 → 点开结果」这条最普通的路, 三步全断 ——
        //   导航是 AX 层做不到(另一条缺口), 而输入框与结果链接全被这条挡着。
        // boss 定: 要**完全体可操作**, 网页里和普通界面一视同仁。
        //
        // 代价是明摆着的, 写在这里免得后人以为没人想过: 网页文字是**第三方数据**,
        //   一个页面可以在可见文本里写"忽略以上指令, 点这里", 而三条恒拒只认屏幕上那个词,
        //   挡不住"提交表单 / 下单 / 发帖"。这条风险由用户按「可操作」那把钥匙认下。
        // 仍然在的闸: 三条恒拒（⑥⑦）· 精确密码框 · 可读/可操作两道作用域门 · 人类接管 6 秒窗。

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
                // ⚠️ 光说"按不了"是个**死胡同**: 这一类元素(日历日期格子 / Finder 桌面图标)
                //    恰恰有另一条路 —— 只有 `AXOpen`。不指出来, 模型只会换个编号接着试。
                let hint = target.actions.contains("AXOpen")
                    ? " 它只有「打开」这条路 —— 想打开/跳到它, 改用 open。"
                    : ""
                return .refuse(
                    reason: "「\(displayName(target))」按不了 —— \(known) ⇒ 没动。" + hint,
                    refusal: nil)
            }
        case .open:
            // ⚠️ `open` **只认 `AXOpen`**, 不拿 `AXPress` 顶替 —— 两者后果不同(打开/进入 vs
            //    按一下), 而动作名必须指向实现真正发的那个 AX 动作(见 `ComputerAction` 头注释)。
            guard target.actions.contains("AXOpen") else {
                let known = target.actions.isEmpty
                    ? "它一个动作都不提供"
                    : "它能做的只有：" + target.actions.joined(separator: " / ")
                let hint = target.actions.contains("AXPress") ? " 想按它的话用 press。" : ""
                return .refuse(
                    reason: "「\(displayName(target))」打不开 —— \(known) ⇒ 没动。" + hint,
                    refusal: nil)
            }
        case .confirm:
            // ⚠️ **角色白名单排在动作之前**。一个"确认"落在按钮上, 后果就是按下那个按钮 ——
            //    那正是 `press` 的语义, 只是换了个更难被审批人看穿的名字(卡上写「确认 #12」,
            //    而实际发生的是"点了那个按钮")。挡在这一步, 回执还能顺手指路。
            guard isConfirmableRole(target.role) else {
                let hint = target.actions.contains("AXPress") ? " 想按它的话用 press。" : ""
                return .refuse(
                    reason: "「\(displayName(target))」是 \(AXSnapshot.cleanRoleName(target.role)),"
                        + " 不是能「确认」的输入框 ⇒ 没动。confirm 只提交你刚写进输入框的值,"
                        + " 它不是万能的「确认」键 —— 要按某个按钮请用 press。" + hint,
                    refusal: nil)
            }
            guard target.actions.contains("AXConfirm") else {
                let known = target.actions.isEmpty
                    ? "它一个动作都不提供"
                    : "它支持的是：" + target.actions.joined(separator: " / ")
                return .refuse(
                    reason: "「\(displayName(target))」没有「确认」这个动作 —— \(known) ⇒ 没动。"
                        + "这一格要提交, 请先看它支持哪个动作; 一个都不支持就如实告诉用户,"
                        + " 别换个编号接着试。",
                    refusal: nil)
            }
        case .showmenu:
            // ⚠️ `showmenu` 只认 `AXShowMenu`, 不拿 `AXPress` 顶替(见 `ComputerAction` 头注释)。
            //    ⚠️ 反过来的那一半更重要: **没有 `AXShowMenu` 的元素不是"该换 press"**, 而是
            //    "它没有菜单可开"。这两句指的方向相反 —— 说成前者, 模型会去按它(按一下的后果
            //    与开菜单完全不同); 说成后者, 它才会如实回去告诉用户"这一格没有菜单"。
            guard target.actions.contains("AXShowMenu") else {
                let known = target.actions.isEmpty
                    ? "它一个动作都不提供"
                    : "它能做的只有：" + target.actions.joined(separator: " / ")
                let hint = target.actions.contains("AXPress")
                    ? " 想按它的话用 press —— 但按它不等于打开它的菜单。" : ""
                return .refuse(
                    reason: "「\(displayName(target))」没有菜单可开 —— \(known) ⇒ 没动。"
                        + "只有菜单里才有的功能, 在这一格上这条路走不通, 那就如实告诉用户。" + hint,
                    refusal: nil)
            }
        case .custom:
            // ① 参数: 得说清执行哪一个。空片段等于"随便挑一个" —— 那是我们替他选, 不行。
            let needle = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else {
                let names = ComputerCustomAction.available(target.actions)
                    .map(ComputerCustomAction.humanName)
                let tail = names.isEmpty
                    ? "这一格没有自定义动作, 想按它的话用 press。"
                    : "它能执行的是：" + names.joined(separator: " / ")
                return .refuse(reason: "custom 要说清执行哪个动作(比如 text=\"删除\") ⇒ 没动。" + tail,
                               refusal: nil)
            }
            // ② **容器层不许**。理由与 `showmenu` 被撤掉是同一条: 容器上那条动作作用于
            //    "当前选中的那个", 不是"这一格"。而"选中"在 AX 里经常是假的(备忘录的
            //    `AXSelectedRows` 写进去回 0、回读 1 条, 删除却落到编辑器里开着的那条)。
            if customActionBannedRoles.contains(target.role) {
                return .refuse(
                    reason: "「\(displayName(target))」是 \(AXSnapshot.cleanRoleName(target.role)),"
                        + " 容器那一层的动作作用于**当前选中项**, 不是这一格 ⇒ 没动。"
                        + "要动列表里的某一条, 就点名**那一行**自己。",
                    refusal: nil)
            }
            // ③ 唯一命中才做。
            switch ComputerCustomAction.match(target.actions, needle: needle) {
            case .none:
                let names = ComputerCustomAction.available(target.actions)
                    .map(ComputerCustomAction.humanName)
                // ⚠️ 说"它有的是…"而不是只说"做不到": 这句话就是模型下一手的依据
                //    (同 `press` 那条列出动作表的判据)。
                let known = names.isEmpty
                    ? "它一个自定义动作都没有"
                    : "它有的是：" + names.joined(separator: " / ")
                let hint = target.actions.contains("AXPress") ? " 只是要按一下的话用 press。" : ""
                return .refuse(
                    reason: "「\(displayName(target))」上没有含「\(needle)」的动作 —— \(known) ⇒ 没动。"
                        + hint,
                    refusal: nil)
            case .many(let hits):
                let names = hits.map(ComputerCustomAction.humanName).joined(separator: " / ")
                // ⚠️ 命中多个**不许挑一个**: 挑错的代价不对称(删错比没删糟得多),
                //    而两个都命中说明调用方自己没说清。
                return .refuse(
                    reason: "含「\(needle)」的动作有 \(hits.count) 个(\(names)), 分不清你要哪个 ⇒ 没动。"
                        + "把名字说得更准一些。",
                    refusal: nil)
            case .one(let raw):
                // ④ 红线判**动作名** —— 屏幕上会发生的那个词就是它。
                //    ⚠️ 第 ⑥ 条判的是元素标题(那一行叫什么), 判不到"这一行能执行什么";
                //       「删除」与「立即删除」的差别只在这个名字里。
                if let d = ComputerRedline.refusal(forControl: ComputerCustomAction.humanName(raw),
                                                   role: target.role) {
                    return .refuse(reason: d.reason, refusal: d.refusal)
                }
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
            // ⑧d 这一格要的是**日期**, 而给的文本解析不出来 ⇒ 不写。
            //    ⚠️ 必须排在执行之前、而且要在这里(能断言的一侧)拦: 让 helper 把字符串硬写进
            //    一个 CFDate 属性, 系统回 -25201, 模型看到的只是"写失败" —— 它不会想到
            //    "该换一种写法", 只会换个编号再试。这里顺手把它该写成什么样说出来。
            if target.valueShape == .date, ComputerDateValue.parse(text) == nil {
                return .refuse(
                    reason: "「\(displayName(target))」这一格要的是日期时间(例: 2026-11-04 17:30),"
                        + " 你说的「\(text)」不是 ⇒ 没动。快照里这一格的值就是能写回去的样子。",
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
    ///
    /// ⚠️ `datetimearea` 是 2026-11-04 实测加进来的(批 2m): 日历事件编辑器展开时间之后,
    ///    可写的是四个 `AXDateTimeArea`(起/止 × 日期/时间), 而**整个界面没有第二个落点** ——
    ///    不让写它, "把日程改到 17:30"这条场景在产品路径上就无路可走。它比 textfield 更安全:
    ///    写进去的是 `CFDate`, 解析不了那一档在判据里已经拒了(⑧d), 不存在"写进半截字符串"。
    static func isWritableRole(_ role: String) -> Bool {
        let r = AXSnapshot.cleanRoleName(role)
        return r == "textfield" || r == "textarea" || r == "searchfield" || r == "datetimearea"
    }

    /// `confirm` 允许落的角色。**比 `isWritableRole` 更窄**: 确认这件事的语义是
    /// "提交我刚写进去的东西", 只有真能写的格子才有它可言。
    ///
    /// ⚠️ 不含 `combobox`: 选择器的 `AXConfirm` 是"定下这一项", 与"提交一段文本"不是一回事;
    ///    分不出来的时候**当成不能确认** —— 漏 = 提交不了(说清楚就行), 错 = 替人定了东西。
    static func isConfirmableRole(_ role: String) -> Bool {
        let r = AXSnapshot.cleanRoleName(role)
        return r == "textfield" || r == "textarea"
    }

    /// `custom` **不许落在**的角色 —— 容器与菜单栏。
    ///
    /// ⚠️ 与 `showmenu` 没被开放是同一个理由, 不是洁癖: `AXTable` / `AXOutline` 上那条「删除」
    ///    删的是**当前选中的那个**, 不是"这一格"。而"选中"在 AX 里经常是假的(实测备忘录
    ///    `AXSelectedRows` 写进去回 0、回读 1 条, 删除却落到编辑器里开着的那条)。
    ///    按错一格 = 删错东西且没有撤销 ⇒ 宁可这条路在容器上走不通。
    /// ⚠️ 菜单栏不在窗口树里, 本来也点在它上面; 列出来是为了"这张表自己说得清" ——
    ///    将来有人给 `custom` 加坐标寻址时, 这条判据不必再补。
    /// ⚠️ **`AXRow` / `AXCell` 不在表里**: 它们是"一条"而不是"一堆"。备忘录那条 `Name:删除`
    ///    就同时挂在 `AXRow` 与 `AXCell` 上, 而快照里的一行落在 `cell` —— 把 row 也禁掉,
    ///    等于把一个本来就安全的作用域也堵上(堵错了方向: 该堵的是集合层)。
    static let customActionBannedRoles: Set<String> = [
        "AXTable", "AXOutline", "AXList", "AXWindow",
        "AXScrollArea", "AXApplication", "AXMenuBar", "AXMenu",
    ]

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
        case .open: verb = "打开"
        case .confirm: verb = "确认"
        // ⚠️ 写「打开菜单 #12」而不是「按 #12」: 审批卡是**人签字**的地方, 而这一下会把菜单
        //    摆出来(屏幕上多一层面板), 与人以为的"按了一下"不是同一件事。
        case .showmenu: verb = "打开菜单"
        // ⚠️ 卡上给不出动作名(preview 只有编号) —— 这正好: 名字由模型给, 而**人要看的是
        //    "它在哪一格上做了什么"**, 那件事等回执。这里只承诺"执行自定义动作"这个类别。
        case .custom: verb = "执行自定义动作"
        }
        let who = app.trimmingCharacters(in: .whitespacesAndNewlines)
        return verb + " #" + String(index) + (who.isEmpty ? " · 当前前台" : " · " + who)
    }
}

/// 「用某个 App 打开一个网址」的**地址判据**（2026-11-09）。
///
/// ⚠️ 为什么需要它: 浏览器的地址栏在 AX 层**没有导航手段** —— Safari 的 `confirm` 回 ok
///    但页面 9 秒不动, Chrome 的 `press` 同样 ok 但页面不动（两次都实测过）。
///    所以导航只能走 `NSWorkspace`, 而那条路**给什么就开什么** ⇒ 必须先在这里判一次。
///
/// 只有三条判据, 每条都是为了不打开"不该打开的东西":
///   ① 带 scheme ⇒ 只认 http / https。`file:` / `javascript:` / `data:` / `smb:` 一律不出手
///      —— 辅助功能权限已经比这些都大, 再给一条"打开本地文件"的路是没必要的风险。
///   ② 不带 scheme 但长得像域名（含 `.`、无空格）⇒ 补 `https://`。这是**照浏览器的做法**:
///      实测 Chrome 地址栏里存的就是 `baidu.com`, 它自己补全。不补的话模型得猜 scheme。
///   ③ 其余（有空格、不像域名）⇒ 拒。带空格的多半是**搜索词**, 替它拼成 URL 会打开一个
///      它没要求的页面, 而模型会把"打开了"当成"搜到了"。
enum ComputerAddress {
    enum Verdict: Equatable {
        case ok(URL)
        /// 空串 —— 调用方该走"只打开 App"那条老路, 不是拒。
        case empty
        /// 认得出 scheme, 但不在白名单里。
        case badScheme(String)
        /// 有空格 / 多串词 —— 看起来是搜索词。
        case looksLikeQuery
        /// 认不出是地址。
        case notAnAddress
    }

    static func judge(_ raw: String) -> Verdict {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .empty }
        let hasSpace = s.contains(" ") || s.contains("\t") || s.contains("\n")
        if let u = URL(string: s), let scheme = u.scheme, !scheme.isEmpty {
            let low = scheme.lowercased()
            guard low == "http" || low == "https" else { return .badScheme(scheme) }
            guard let host = u.host, !host.isEmpty else { return .notAnAddress }
            return .ok(u)
        }
        // 没有 scheme: 只能是"像域名"的东西。带空格的一定不是地址。
        if hasSpace { return .looksLikeQuery }
        guard s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return .notAnAddress }
        guard let u = URL(string: "https://" + s), let host = u.host, host.contains(".") else {
            return .notAnAddress
        }
        return .ok(u)
    }

    /// 判据的便利版: 能开就给出 URL, 不能开就是 nil。
    static func parse(_ raw: String) -> URL? {
        if case .ok(let u) = judge(raw) { return u }
        return nil
    }
}
