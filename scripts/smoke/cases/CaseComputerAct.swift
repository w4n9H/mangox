//
//  CaseComputerAct.swift
//  P18 批 2b: 动作面的九条判据 + 两档授权 —— 全是纯函数, 不需要真屏幕、不需要授权。
//
//  ⚠️ 这一批的**风险全在「该拦的没拦」**: 判据少一条、顺序错一步, 界面上一点异常都没有,
//    只有「模型替人点了不保存」那一天才会被发现。所以每条判据都要有**正例 + 反例方向**,
//    而且**顺序本身**要单独断言(见 ④ 段)。
//
//  ⚠️ 文案断言用 `contains` 而不是整串相等: 整串相等会让"改一句人话"变成红灯, 而那些话
//    本来就是要反复打磨的。这里断言的是**判据的落点**(报的是哪一条), 不是措辞。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseComputerAct() async {
        print("== T-ACT 动作面判据 (P18 批 2b / 四档 op 在批 2f 补齐 / confirm 在批 2k) ==")

        // MARK: ① op 白名单 —— 认不出来的不许落到任何默认分支

        check(ComputerAction.parse("press") == .press, "T-ACT press 认得")
        check(ComputerAction.parse("setValue") == .setValue, "T-ACT setValue 认得")
        check(ComputerAction.parse("focus") == .focus, "T-ACT focus 认得 (批 2f)")
        check(ComputerAction.parse("scroll") == .scroll, "T-ACT scroll 认得 (批 2f)")
        check(ComputerAction.parse("open") == .open,
              "T-ACT open 认得 (2026-11-04: 只暴露 AXOpen 的格子靠它才动得了)")
        check(ComputerAction.parse("confirm") == .confirm,
              "T-ACT confirm 认得 (批 2k: 日历快速日程只有这一条提交路)")
        check(ComputerAction.parse("showmenu") == .showmenu,
              "T-ACT showmenu 认得 (批 2n: 只活在菜单里的功能靠它才够得着)")
        check(ComputerAction.parse("custom") == .custom,
              "T-ACT custom 认得 (批 2p: 元素自己声明的动作, 备忘录删笔记靠它)")
        // ⚠️ **认得出来 ≠ 开放给模型**。`showmenu` 就是这一档: 代码在、判据在、门关着。
        //    这两件事必须分开断言 —— 合成一条("parse 认不出")的话, 将来谁把它加回 enum
        //    就顺手放开了, 而没有任何红灯。
        check(ComputerAction.exposed.contains(.custom),
              "T-ACT custom 在对模型开放的名单里")
        check(!ComputerAction.exposed.contains(.showmenu),
              "T-ACT showmenu **没**对模型开放 (作用域判不了: 实测它删的是选中项, 不是那一行)")
        check(ComputerAction.exposed.count == ComputerAction.allCases.count - 1,
              "T-ACT 开放名单 = 全部动作 - 1(showmenu) —— 多放一个进来必须是**有意**的")
        check(ComputerAction.parse(" press ") == .press, "T-ACT 两侧空白不算错 (线上偶尔带)")
        check(ComputerAction.parse("click") == nil,
              "T-ACT 坐标点击仍然不做 ⇒ 认不出来, 不许默默当成 press")
        check(ComputerAction.parse("PRESS") == nil,
              "T-ACT 大小写敏感: 线上写错了要变红, 不许看着差不多就认")
        check(ComputerAction.allCases.count == 8,
              "T-ACT 动作面只有八个 —— 多一个就多一条「模型以为自己能动」的路")

        // 方向是 scroll 的**独立参数**, 不是一个 op: 认不出来就必须拒(判据 ⑧ 的第一支),
        // 不许退回"那就往下滚"。
        check(ComputerScrollDirection.parse("down") == .down, "T-ACT 方向 down 认得")
        check(ComputerScrollDirection.parse(" Up ") == .up,
              "T-ACT 方向两侧空白与大小写都不算错 (它不是 op 那种枚举契约, 宽容一点没有风险)")
        check(ComputerScrollDirection.parse("left") == nil,
              "T-ACT 横向滚动不认 (横向多半是表太宽 ⇒ 那是「读」能解决的)")
        check(ComputerScrollDirection.parse("") == nil, "T-ACT 空方向认不出来")

        // MARK: 夹具 —— 一份样样都合格的上下文

        func scope(read: Set<String> = ["com.apple.Safari"],
                   act: Set<String> = ["com.apple.Safari"],
                   seq: Int = 3,
                   current: Int = 3,
                   rows: Int = 12) -> ComputerActScope {
            ComputerActScope(bundle: "com.apple.Safari",
                             appName: "Safari",
                             readBundles: read,
                             actBundles: act,
                             requestSeq: seq,
                             currentSeq: current,
                             rowCount: rows)
        }
        func req(_ action: ComputerAction = .press,
                 index: Int = 12,
                 seq: Int = 3,
                 text: String = "",
                 direction: ComputerScrollDirection? = nil) -> ComputerActRequest {
            ComputerActRequest(app: "Safari", action: action, index: index,
                               seq: seq, text: text, direction: direction)
        }
        let button = ComputerActTarget(role: "AXButton", title: "登录", actions: ["AXPress"])
        let field = ComputerActTarget(role: "AXTextField", title: "搜索", actions: ["AXPress"])
        // 两种"新 op 用得上"的目标。canFocus / canScroll **缺省都是 false** ——
        // 这一对夹具和 `button` 的区别只有那两个读数, 正好用来证明判据看的是系统答案, 不是角色。
        let focusable = ComputerActTarget(role: "AXTextField", title: "搜索", canFocus: true)
        let scrollable = ComputerActTarget(role: "AXScrollArea", title: "页面", canScroll: true)

        // 基线: 什么都没问题 ⇒ 放行。没有这一条, 后面所有拒绝都可能是「反正都拒」。
        check(ComputerActGuard.evaluate(request: req(), scope: scope(),
                                        target: button, window: .none) == .allow(.press),
              "T-ACT 基线: 权限齐、seq 对、编号在、能按 ⇒ 放行")

        // MARK: 网页内容与普通界面**一视同仁**（⑤b 于 2026-11-09 撤掉）
        //
        // 立过又撤: 2026-11-06 加 Safari 时立了「网页内容一律不动」，因为网页文字是第三方数据；
        // 11-09 boss 定要**完全体可操作** —— 真机一量，「打开百度 → 输入检索 → 点开结果」
        // 三步全断，Safari 只剩"能看不能用"。于是撤掉它，网页里照常按。
        //
        // ⚠️ 撤一条红线最容易顺手把别的门也拆掉 —— 所以这一片**必须双向判**：
        //   ① 网页里的 link / button ⇒ 走 ⑧ 的动作表，有 `AXPress` 就放行；
        //   ② 网页里的输入框 ⇒ 能 setValue；
        //   ③ **反例**：网页里那个按钮叫「删除」⇒ ⑥ 三条恒拒照旧拦（撤的只是"网页"这一条）；
        //   ④ **反例**：网页里的纯文本没有 `AXPress` ⇒ ⑧ 照旧拒（放行 ≠ 见谁都放行）。
        let webLink = ComputerActTarget(role: "AXLink", title: "新闻", actions: ["AXPress"])
        check(ComputerActGuard.evaluate(request: req(), scope: scope(),
                                        target: webLink, window: .none) == .allow(.press),
              "T-ACT 网页里的 link 能按（⑤b 已撤：网页内容与普通界面一视同仁）")
        check(ComputerActGuard.evaluate(request: req(.setValue, text: "天气"), scope: scope(),
                                        target: field, window: .none) == .allow(.setValue),
              "T-ACT 网页里的输入框能写（同上；改回「整片拒」这条会红）")
        // ③ 撤的是「网页」这一条，不是所有门。⚠️ 用**真会命中**的词（「立即删除」「确认支付」）：
        //    恒拒认的是"永久删除"那一族，**裸的「删除」不拦**（"移到废纸篓"必须放行）——
        //    这也正是撤⑤b 之后的真实代价：网页里叫「删除」的按钮，现在真能点下去。
        for word in ["立即删除", "确认支付"] {
            let webDanger = ComputerActTarget(role: "AXButton", title: word, actions: ["AXPress"])
            if case .refuse(let why, _) = ComputerActGuard.evaluate(
                request: req(), scope: scope(), target: webDanger, window: .none) {
                check(why.contains("永久删除") || why.contains("付款") || why.contains("不可恢复"),
                      "T-ACT 网页里的「\(word)」仍被恒拒拦下 实际:\(why)")
            } else {
                check(false, "T-ACT 网页里的「\(word)」必须仍被恒拒拦下（否则撤⑤b 把恒拒一起拆了）")
            }
        }
        // ④ 放行 ≠ 见谁都放行：动作表那关还在。
        let webPlainText = ComputerActTarget(role: "AXStaticText", title: "正文", actions: [])
        check(ComputerActGuard.evaluate(request: req(), scope: scope(),
                                        target: webPlainText, window: .none) != .allow(.press),
              "T-ACT 网页里的纯文本按不了（⑧ 动作表照旧生效，撤⑤b 没顺手拆掉它）")

        // MARK: ② 读面 —— 没开读的 App 一律不动

        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(), scope: scope(read: []),
            target: button, window: .none) {
            check(why.contains("不在开放名单"),
                  "T-ACT 读面为空 ⇒ 拒, 且说清是「读」这一档 实际:\(why)")
        } else {
            check(false, "T-ACT 读面为空必须拒 (这条是「绕过一次判据零红灯」的兜底)")
        }

        // MARK: ③ 操作面 —— 读得到不等于动得

        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(), scope: scope(act: []), target: button, window: .none) {
            check(why.contains("没开「操作」"),
                  "T-ACT 只给了读 ⇒ 拒, 且指名去设置里开哪一档 实际:\(why)")
            check(why.contains("设置"),
                  "T-ACT 拒的同时要给出下一步 (只说句不许会让模型反复试)")
        } else {
            check(false, "T-ACT 操作面为空必须拒 —— 这条没了, 两档权限就是摆设")
        }

        // 口令 / 系统类: 拦住的位置一样, 但回执**不许**叫人去设置里勾(勾了也不生效)
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(),
            scope: ComputerActScope(bundle: "com.1password.1password",
                                    appName: "1Password",
                                    readBundles: ["com.1password.1password"],
                                    actBundles: ["com.1password.1password"],
                                    requestSeq: 3, currentSeq: 3, rowCount: 12),
            target: button, window: .none) {
            check(why.contains("永远不操作"),
                  "T-ACT 口令类即使出现在操作面里也要拒 (防手改库/老数据) 实际:\(why)")
            check(!why.contains("请在 设置"),
                  "T-ACT 口令类被拦时不能叫人去设置里开 —— 那里根本勾不上 实际:\(why)")
        } else {
            check(false, "T-ACT 口令类出现在操作面里也必须拒")
        }
        check(!ComputerSettings.canAct("com.1password.1password")
                && !ComputerSettings.canAct("com.apple.systempreferences"),
              "T-ACT 设置页对这两个不许出现可勾的操作格 "
              + "(系统设置能关掉辅助功能授权本身 ⇒ 那是自我提权)")
        // ⚠️ 2026-11-04 boss 拍板: **操作 MangoX 自己**同理 —— 它能点掉自己刚弹出的人机确认卡、
        //    能把作用域/审批档一路放开。只挡"操作"不挡"读"（读是另一档权限, 走 activeBundles）。
        check(!ComputerSettings.canAct("moofs.mangox") && ComputerRedline.actBannedBundles.contains("moofs.mangox"),
              "T-ACT MangoX 自己不许被操作 (否则模型能点掉自己的确认卡 = 自我提权)")
        check(ComputerSettings.canAct("com.apple.Safari"),
              "T-ACT 普通 App 可以开操作 (对照: 不能一刀切全禁)")

        // MARK: ④ 顺序 —— seq 排在「编号是否存在」之前

        // seq 错 + 编号也越界: 必须报 seq。反过来的话, 过期快照里恰好也有 #12 时会读到
        // 一个语义完全不同的元素, 而回执照样说「按了 #12」, 没有人看得出错。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(index: 99, seq: 2), scope: scope(seq: 2, current: 5, rows: 12),
            target: button, window: .none) {
            check(why.contains("旧快照"),
                  "T-ACT seq 不符要排在编号检查之前 (报旧快照, 不是报没有 #99) 实际:\(why)")
        } else {
            check(false, "T-ACT seq 不符必须拒")
        }

        // MARK: ⑤ 编号与元素

        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(index: 99), scope: scope(), target: button, window: .none) {
            check(why.contains("没有 #99") && why.contains("12"),
                  "T-ACT 编号越界要说清一共几项 (模型据此知道该重新读) 实际:\(why)")
        } else {
            check(false, "T-ACT 编号越界必须拒")
        }
        if case .refuse(_, _) = ComputerActGuard.evaluate(
            request: req(index: 0), scope: scope(), target: button, window: .none) {
            check(true, "T-ACT 编号从 1 起, #0 不存在")
        } else {
            check(false, "T-ACT 编号 0 必须拒 (下界也归它管)")
        }
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(), scope: scope(), target: nil, window: .none) {
            check(why.contains("查不到对应元素"),
                  "T-ACT 编号在、元素不在(表与快照脱节) ⇒ 拒, 不许硬按")
        } else {
            check(false, "T-ACT target 为 nil 必须拒")
        }

        // MARK: ⑥ 恒拒之一: 付款 / 永久删除 —— 判**现场标题**, 不是快照里缓存的文本

        if case .refuse(_, let refusal) = ComputerActGuard.evaluate(
            request: req(),
            scope: scope(),
            target: ComputerActTarget(role: "AXButton", title: "确认付款", actions: ["AXPress"]),
            window: .none) {
            check(refusal == .payment, "T-ACT 付款字样恒拒, 且带留痕串")
        } else {
            check(false, "T-ACT 确认付款必须恒拒")
        }
        // ⇧⌘⌫ = 立即删除。位掩码 shift=1 + command 隐含
        if case .refuse(_, let refusal) = ComputerActGuard.evaluate(
            request: req(),
            scope: scope(),
            target: ComputerActTarget(role: "AXMenuItem", title: "Delete",
                                      actions: ["AXPress"],
                                      keyEquivalent: "\u{8}", modifiers: ["command", "shift"]),
            window: .none) {
            check(refusal == .permanentDelete, "T-ACT ⇧⌘⌫ 恒拒 (标题被本地化也认得出)")
        } else {
            check(false, "T-ACT ⇧⌘⌫ 必须恒拒 —— 它是唯一「标题认不出但快捷键恒定」的删除入口")
        }
        // 对照: ⌘⌫ 是「移到废纸篓」,**必须放行** —— 这条不写, 以后有人把 shift 判宽了没人发现
        check(ComputerActGuard.evaluate(
            request: req(),
            scope: scope(),
            target: ComputerActTarget(role: "AXMenuItem", title: "移到废纸篓",
                                      actions: ["AXPress"],
                                      keyEquivalent: "\u{8}", modifiers: ["command"]),
            window: .none) == .allow(.press),
              "T-ACT ⌘⌫ / 移到废纸篓放行 (改版后它不在红线里)")

        // MARK: ⑦ 恒拒之二: 存盘确认 —— **替你按取消**, 不是拒了就完事

        let saveSheet = ComputerActWindow(sheetTitle: "保存更改",
                                          sheetButtons: ["保存", "不保存", "取消"])
        if case .cancelSavePrompt(let i, let why) = ComputerActGuard.evaluate(
            request: req(), scope: scope(), target: button, window: saveSheet) {
            check(i == 2, "T-ACT 恒选「取消」那个键 (下标 2, 不是第一个) 实际:\(i)")
            check(why.contains("未保存"),
                  "T-ACT 回执要带「这里有未保存的修改」(对用户来说这条才是价值)")
        } else {
            check(false, "T-ACT 存盘弹窗必须返回代按取消, 不是放行也不是纯拒")
        }
        // 没有「取消」键 ⇒ 恒拒, 不许退而求其次去点「不保存」
        if case .refuse(let why, let refusal) = ComputerActGuard.evaluate(
            request: req(), scope: scope(), target: button,
            window: ComputerActWindow(sheetTitle: "保存更改", sheetButtons: ["保存", "不保存"])) {
            check(refusal == .savePrompt && why.contains("没有「取消」"),
                  "T-ACT 无取消键 ⇒ 什么都不点 (退一步就是替人丢弃) 实际:\(why)")
        } else {
            check(false, "T-ACT 无取消键必须恒拒")
        }
        // ⚠️ 顺序: 付款排在存盘之前 —— 目标就是「确认付款」时, 不许被存盘那一支吞掉
        if case .refuse(_, let refusal) = ComputerActGuard.evaluate(
            request: req(),
            scope: scope(),
            target: ComputerActTarget(role: "AXButton", title: "确认付款", actions: ["AXPress"]),
            window: saveSheet) {
            check(refusal == .payment,
                  "T-ACT 付款与存盘同时成立时报付款 (它不是代按取消能解决的事)")
        } else {
            check(false, "T-ACT 付款判据必须排在存盘之前")
        }

        // MARK: ⑧ 动作可行性

        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(),
            scope: scope(),
            target: ComputerActTarget(role: "AXStaticText", title: "正文", actions: []),
            window: .none) {
            check(why.contains("按不了"), "T-ACT 没有 AXPress ⇒ 拒 实际:\(why)")
        } else {
            check(false, "T-ACT 不可按的元素必须拒 (不许假装按了)")
        }
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.setValue, text: "周报"), scope: scope(),
            target: ComputerActTarget(role: "AXButton", title: "登录", actions: ["AXPress"]),
            window: .none) {
            check(why.contains("不是能写字的地方"), "T-ACT setValue 打在按钮上 ⇒ 拒 实际:\(why)")
        } else {
            check(false, "T-ACT 非可写角色必须拒")
        }
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.setValue, text: "hunter2"), scope: scope(),
            target: ComputerActTarget(role: "AXSecureTextField", title: "", actions: ["AXPress"]),
            window: .none) {
            check(why.contains("密码框"), "T-ACT 密码框不许写 (写进去 = 口令变成模型想的值)")
        } else {
            check(false, "T-ACT 密码框 setValue 必须拒")
        }
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.setValue, text: "   "), scope: scope(),
            target: field, window: .none) {
            check(why.contains("空的"), "T-ACT 空串不是什么都没干, 是清空 ⇒ 拒")
        } else {
            check(false, "T-ACT 空白 text 必须拒")
        }
        let long = String(repeating: "字", count: ComputerActGuard.maxSetValueChars + 1)
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.setValue, text: long), scope: scope(), target: field, window: .none) {
            check(why.contains("上限"), "T-ACT 超长文本拒 (多半是搞错了对象) 实际:\(why)")
        } else {
            check(false, "T-ACT 超长 setValue 必须拒")
        }
        check(ComputerActGuard.evaluate(
            request: req(.setValue, text: "周报"), scope: scope(),
            target: field, window: .none) == .allow(.setValue),
              "T-ACT 基线对照: 文本框 + 正常文本 ⇒ 放行")

        // —— focus / scroll (批 2f) ——
        // 这两个 op 都不动"按编号寻址"这个前提(判据体系一行没改), 只多了两个现场读数。
        // ⚠️ 判的是**系统说能不能**, 不是"角色长得像不像": 下面两个 fixture 的 role 都是
        //    `AXTextField`, 只有 `canFocus` 不同 —— 结论必须不同, 否则就是在按角色猜。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.focus), scope: scope(), target: field, window: .none) {
            check(why.contains("不接受聚焦"),
                  "T-ACT 焦点不可设 ⇒ 拒, 用「系统说不可设」这句(不是「好像点不动」) 实际:\(why)")
        } else {
            check(false, "T-ACT canFocus=false 必须拒 —— 否则回执只能替一次没反应的动作圆场")
        }
        check(ComputerActGuard.evaluate(
            request: req(.focus), scope: scope(), target: focusable, window: .none) == .allow(.focus),
              "T-ACT 基线对照: 同样角色但焦点可设 ⇒ 放行 (没有这条, 上面的拒绝可能是「反正都拒」)")

        // 参数错 与 能力不足 是两件事: 前者重发一次就能成, 后者得换节点 —— 回执必须分开。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.scroll, direction: nil), scope: scope(),
            target: scrollable, window: .none) {
            check(why.contains("往哪滚"),
                  "T-ACT scroll 没说方向 ⇒ 拒, 且指名是参数问题 (不许默认往下滚) 实际:\(why)")
        } else {
            check(false, "T-ACT scroll 缺 direction 必须拒")
        }
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.scroll, direction: .down), scope: scope(),
            target: button, window: .none) {
            check(why.contains("没有可写的滚动条"),
                  "T-ACT 目标上没滚动条 ⇒ 拒, 且说清「有些 App 不向系统暴露」 实际:\(why)")
        } else {
            check(false, "T-ACT canScroll=false 必须拒")
        }
        // ⚠️ 顺序: 参数错排在"滚不动"之前 —— 两个都成立时报参数, 因为下一步是重发不是换节点。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.scroll, direction: nil), scope: scope(),
            target: button, window: .none) {
            check(why.contains("往哪滚") && !why.contains("滚动条"),
                  "T-ACT 参数错与滚不动同时成立时报参数 (反过来的话模型会去换节点白试) 实际:\(why)")
        } else {
            check(false, "T-ACT 两者同时成立必须拒")
        }
        check(ComputerActGuard.evaluate(
            request: req(.scroll, direction: .up), scope: scope(),
            target: scrollable, window: .none) == .allow(.scroll),
              "T-ACT 基线对照: 有滚动条 + 说了方向 ⇒ 放行")

        // MARK: ⑧b `open` —— 与 `press` 是两个动作, 谁也不许顶替谁 (2026-11-04)

        // 实测事实(2026-11-04): 日历右下角小月历的日期格子、Finder 桌面上的文件图标
        // **只暴露 `AXOpen`**; 在它们身上 `AXPress` 返回 0 却什么都不做。
        let openOnly = ComputerActTarget(role: "AXButton", title: "15, 星期日, 十一月",
                                         actions: ["AXOpen"])
        check(ComputerActGuard.evaluate(request: req(.open), scope: scope(),
                                        target: openOnly, window: .none) == .allow(.open),
              "T-ACT 只暴露 AXOpen 的格子 ⇒ open 放行 (从前这条路整个是死的)")

        // ⚠️ 这一条是**本次改动的起因**: 同一个格子上 press 仍然被拒, 但拒绝语必须**指路**。
        //    只说「按不了」是个死胡同 —— 模型只会换个编号接着试, 而它试一万次也按不动。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.press), scope: scope(), target: openOnly, window: .none) {
            check(why.contains("按不了") && why.contains("open"),
                  "T-ACT 只有 AXOpen 的格子: press 照旧拒, 但要说清另一条路是 open 实际:\(why)")
        } else {
            check(false, "T-ACT 只有 AXOpen 的元素不许被 press 放行 (AXPress 在它身上返回 0 却空转)")
        }

        // 反方向: 只有 AXPress 的按钮不许被 open 顶替 —— 否则卡片上写「打开」、实现发的是
        // `kAXPressAction`, 人签的字就不是他以为的那件事。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.open), scope: scope(), target: button, window: .none) {
            check(why.contains("打不开") && why.contains("press"),
                  "T-ACT 只有 AXPress 的按钮: open 拒, 且指路去 press 实际:\(why)")
        } else {
            check(false, "T-ACT open 不许拿 AXPress 顶替 (两个动作后果不同, 卡片上写的必须是真做的那件事)")
        }
        check(ComputerActGuard.evaluate(
            request: req(.open), scope: scope(),
            target: ComputerActTarget(role: "AXGroup", title: "背景", actions: []),
            window: .none) != .allow(.open),
              "T-ACT 一个动作都不提供的容器: open 也拒 (对照: 不是「凡是 open 都放行」)")

        // MARK: ⑧c open 的返回码怎么读 —— 本次改动里唯一不能照抄别的动作的地方

        // 实测: `AXOpen` 打日期格子返回 -25205 而界面确实跳了; 同一格子 `AXPress` 返回 0
        // 却什么都没发生 ⇒ **两个方向的返回码都不可信**。
        check(ComputerOpenVerdict.classify(0) == .accepted,
              "T-ACT open 返回 0 ⇒ 送进去了")
        check(ComputerOpenVerdict.classify(-25205) == .acceptedWithSuspectCode(-25205),
              "T-ACT open 返回 -25205 **不许当失败** (实测: 报它, 界面照样跳了)")
        check(ComputerOpenVerdict.classify(-25202) == .notDelivered,
              "T-ACT 只有「元素已失效」这一个码能证明动作没发出去")
        // 反向: 未知码默认按「可能已经送出」记。代价是模型多读一遍(自愈); 按失败记的代价是
        // **重复动作**(再跳一天 / 再开一次文件夹), 那个不自愈。
        check(ComputerOpenVerdict.classify(-25200) == .acceptedWithSuspectCode(-25200),
              "T-ACT 未知码按「可能已送出」记 (按失败记会让模型重试 ⇒ 重复打开)")

        // MARK: ⑧c2 `computer_open` 的 url —— 导航唯一的路，判据只剩三道（2026-11-09）
        //
        // 为什么它落在 `open` 而不是 `act`: 两个浏览器的地址栏都没有导航手段 —— Safari 的
        // `confirm` 回 ok 但页面 9 秒不动（实测连读 6 次标题不变），Chrome 的 `press` 同样
        // ok 但页面不动。所以"打开某个网址"只能走系统，而系统那条路给什么就开什么。
        check(ComputerAddress.parse("https://www.baidu.com")?.absoluteString == "https://www.baidu.com",
              "T-ACT http(s) 地址原样放行")
        check(ComputerAddress.parse("baidu.com")?.absoluteString == "https://baidu.com",
              "T-ACT 不带 scheme 的域名补 https（Chrome 地址栏里存的就是 baidu.com，它自己补）")
        check(ComputerAddress.judge("") == .empty,
              "T-ACT 空 url = 只打开 App（老行为），不是拒")
        // 反例 —— 下面每一条都是"打开了不该打开的东西"。
        // ⚠️ 写成表、不各写一份 `if case`：早先 `javascript:` 那条是 `if case ... {}` **空体**，
        //    绿了什么都不打印 ⇒ 条数会随行为浮动，而且"它真跑了"这件事在日志里看不见。
        //    判据绿的时候也必须留下一条 PASS —— 这与"条数不是指标"是一体两面。
        for (raw, scheme) in [("file:///etc/passwd", "file"), ("javascript:alert(1)", "javascript")] {
            if case .badScheme(let s) = ComputerAddress.judge(raw) {
                check(s.lowercased() == scheme,
                      "T-ACT \(scheme): 被拒，且回执说得出是哪个 scheme 实际:\(s)")
            } else {
                check(false, "T-ACT \(scheme): 必须拒（否则等于给模型一条绕过地址判据的路）")
            }
        }
        check(ComputerAddress.judge("天气 上海") == .looksLikeQuery,
              "T-ACT 带空格的按搜索词拒（替它拼成 URL 会打开一个它没要求的页面）")
        check(ComputerAddress.judge("随便什么") == .notAnAddress,
              "T-ACT 不像域名的不猜（带 . 才当域名）")

        // MARK: ⑧d `confirm` —— 提交那一格, 但绝不许当"通用确认键" (批 2k, 2026-11-04)

        // 实测起因: 日历「创建快速日程」的文本框 actions = AXShowMenu / AXConfirm / AXPress,
        // 而同一格子上 AXPress 返回 0 **什么都不发生** —— 只有 AXConfirm 能把文本变成真日程
        // (隔离验证: 一个别的动作都不发, 事件当场生成)。
        let quickEventField = ComputerActTarget(role: "AXTextField", title: "新建快速日程",
                                               actions: ["AXShowMenu", "AXConfirm", "AXPress"])
        check(ComputerActGuard.evaluate(request: req(.confirm), scope: scope(),
                                        target: quickEventField, window: .none) == .allow(.confirm),
              "T-ACT 输入框 + 有 AXConfirm ⇒ confirm 放行 (日历快速日程只有这条路提交得了)")

        // ⚠️ **这一条是这档动作的红线**。同一个 AXConfirm 落到按钮上, 实际发生的事就是"按下
        //    那个按钮", 而卡上写的是「确认 #12」—— 审批人签的字不是他以为的那件事。
        let confirmableButton = ComputerActTarget(role: "AXButton", title: "删除",
                                                  actions: ["AXPress", "AXConfirm"])
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.confirm), scope: scope(), target: confirmableButton, window: .none) {
            check(why.contains("不是能「确认」的输入框") && why.contains("press"),
                  "T-ACT 按钮上的 confirm 必须拒、并指路 press (否则它就是个换了名字的 press) 实际:\(why)")
        } else {
            check(false, "T-ACT confirm 绝不许在按钮上放行 (卡上写「确认」, 实际是按下那个按钮)")
        }

        // 输入框但**不提供** AXConfirm: 说清它支持什么, 不许押着 press 顶上。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.confirm), scope: scope(),
            target: ComputerActTarget(role: "AXTextField", title: "搜索", actions: ["AXPress"]),
            window: .none) {
            check(why.contains("没有「确认」这个动作") && why.contains("AXPress"),
                  "T-ACT 输入框没 AXConfirm ⇒ 拒, 并列出它支持的动作 (不许拿 press 顶替) 实际:\(why)")
        } else {
            check(false, "T-ACT 没有 AXConfirm 的输入框不许被 confirm 放行")
        }

        // 恒拒三条对 confirm 一视同仁 —— 在存盘确认弹窗上按一下"确认"恰恰是最危险的那一下:
        // 它最容易被读成"对，我就是要保存/丢弃"，而那一手是人的决定。
        let saveSheetForConfirm = ComputerActWindow(sheetTitle: "要保存对「未命名」的更改吗？",
                                                   sheetButtons: ["不保存", "取消", "保存"])
        if case .cancelSavePrompt(let i, _) = ComputerActGuard.evaluate(
            request: req(.confirm), scope: scope(), target: quickEventField,
            window: saveSheetForConfirm) {
            check(i == 1,
                  "T-ACT confirm 在存盘弹窗上也替你按「取消」(下标 \(i)) —— 借「确认」两个字替人丢修改是最坏的一手")
        } else {
            check(false, "T-ACT 存盘弹窗在时 confirm 必须走「替你按取消」, 不许放行")
        }

        check(ComputerActGuard.preview(action: .confirm, app: "日历", index: 115) == "确认 #115 · 日历",
              "T-ACT 卡上那一行: confirm 写「确认」")

        // MARK: ⑧e 值的**类型**决定怎么写 —— 日期格不是字符串格 (批 2m, 2026-11-04)

        // 实测起因: 日历事件编辑器展开时间之后, 可写的只有四个 `AXDateTimeArea`
        // (`start-timepicker` …), 它们的 `AXValue` 是 **CFDate**。拿 CFString 去写, 系统回
        // **-25201**(`kAXErrorIllegalArgument`), 界面纹丝不动 ⇒ "把日程改到 17:30"在只会写
        // 字符串的实现里**结构上做不到**, 而回执只会说"写失败", 让人看不出缺的是类型。
        check(ComputerActGuard.isWritableRole("AXDateTimeArea"),
              "T-ACT 日期格可写 (整个日历编辑器里没有第二个落点)")
        check(!ComputerActGuard.isConfirmableRole("AXDateTimeArea"),
              "T-ACT 日期格不许被「确认」—— confirm 的语义是提交文本, 日期格没有这个动作")

        // 日期文本 ⇄ CFDate 的**两个方向同一套格式**: 快照里读到的样子就是能写回去的样子。
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let round = ComputerDateValue.parse("2026-11-04 17:30", timeZone: tz)
        check(round != nil, "T-ACT 「yyyy-MM-dd HH:mm」认得 (快照里渲染的就是这一款)")
        check(round.map { ComputerDateValue.display($0, timeZone: tz) } == "2026-11-04 17:30",
              "T-ACT 读出来的样子与写得回去的样子是**同一个格式** —— 模型照抄就能用")
        // 只给时分: 补**今天**, 而且必须落回同一个钟点(时区不许被系统悄悄换掉)。
        let now = ComputerDateValue.parse("2026-11-04 09:00", timeZone: tz)!
        let hm = ComputerDateValue.parse("17:30", now: now, timeZone: tz)
        check(hm.map { ComputerDateValue.display($0, timeZone: tz) } == "2026-11-04 17:30",
              "T-ACT 只说时分时补今天 实际:\(hm.map { ComputerDateValue.display($0, timeZone: tz) } ?? "nil")")
        check(ComputerDateValue.parse("明天下午三点", timeZone: tz) == nil,
              "T-ACT 自然语言**不猜**: 猜错是把日程挪到别的日子, 而且不会有任何红灯")
        check(ComputerDateValue.parse("", timeZone: tz) == nil, "T-ACT 空串不是日期")

        // 写法跟着**属性类型**走 —— 其余类型一律维持"写字符串"(旧行为不许被这次改动带跑)。
        // ⚠️ 这条曾经用固定时区渲染、却让 `decide` 自己去取 `.current` ⇒ **在 UTC 的 CI 上必红**
        //    (本地 GMT+8 与 `Asia/Shanghai` 同源, 所以一直绿)。判据要把时区**两头都钉住**,
        //    否则它测的不是"读写同源", 而是"这台机器的时区恰好等于断言里写的那一个"。
        if case .date(let d) = ComputerWritePlan.decide(shape: .date, text: "2026-11-04 17:30",
                                                        timeZone: tz) {
            check(ComputerDateValue.display(d, timeZone: tz) == "2026-11-04 17:30",
                  "T-ACT 日期格 + 能解析 ⇒ 按日期写 (读写同一个时区, 在哪个时区跑都一样)")
        } else {
            check(false, "T-ACT 日期格 + 能解析, 必须算出日期来")
        }
        check(ComputerWritePlan.decide(shape: .date, text: "随便写点什么") == .text,
              "T-ACT 日期格 + 解析不了 ⇒ 交回字符串那条路 (判据 ⑧e 会先拒, 这只是兜底)")
        check(ComputerWritePlan.decide(shape: .text, text: "2026-11-04 17:30") == .text,
              "T-ACT 普通输入框里那串字**就是个字符串** (否则搜个日期都写不进去)")

        // 判据那一侧: 日期格 + 不是日期的文本 ⇒ 拒, 且说清"这一格要日期时间"。
        let dateCell = ComputerActTarget(role: "AXDateTimeArea", title: "start-timepicker",
                                         valueShape: .date)
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.setValue, text: "下午三点"), scope: scope(),
            target: dateCell, window: .none) {
            check(why.contains("日期时间") && why.contains("快照"),
                  "T-ACT 日期格收到非日期 ⇒ 拒, 并指出快照里那个值就是能写回去的样子 实际:\(why)")
        } else {
            check(false, "T-ACT 日期格收到非日期必须拒 —— 硬写进去就是一次 -25201 的空转")
        }
        check(ComputerActGuard.evaluate(request: req(.setValue, text: "2026-11-04 17:30"),
                                        scope: scope(), target: dateCell, window: .none)
                == .allow(.setValue),
              "T-ACT 日期格 + 合法日期 ⇒ 放行")
        // 对照组: 同一句话写进普通输入框照旧放行 —— 证明上一条拒的是**类型**, 不是措辞。
        check(ComputerActGuard.evaluate(request: req(.setValue, text: "下午三点"), scope: scope(),
                                        target: ComputerActTarget(role: "AXTextField", title: "备注"),
                                        window: .none) == .allow(.setValue),
              "T-ACT 对照: 「下午三点」写进普通输入框照旧放行 (拒的是类型, 不是这句话)")

        // MARK: ⑧f `showmenu` —— 把够不着的功能摆出来, 但绝不替人选 (批 2n, 2026-11-05)

        // 实测起因: 备忘录删笔记 / 日历删日程 / 访达新建文件夹**三条场景全卡在同一个缺口**上 ——
        // 功能只活在上下文菜单里, 窗口里没有承载它的控件, 而动作集里没有任何 op 能打开菜单。
        // 旧 SOP 因此把这三件写成「做不到, 请人来」—— 那是**产品缺口被写成了能力边界**。
        let menuedCell = ComputerActTarget(role: "AXCell", title: "【场景测试】笔记",
                                          actions: ["AXShowMenu"])
        check(ComputerActGuard.evaluate(request: req(.showmenu), scope: scope(),
                                        target: menuedCell, window: .none) == .allow(.showmenu),
              "T-ACT 有 AXShowMenu 的格子 ⇒ showmenu 放行 (只活在菜单里的功能只有这条入口)")

        // ⚠️ 没有 AXShowMenu 的格子必须拒, 而且**不许把这句说成"那就用 press"**:
        //    按一下的后果与开菜单完全不同, 指错路会让模型去按一个它本想打开菜单的东西。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.showmenu), scope: scope(), target: button, window: .none) {
            check(why.contains("没有菜单可开") && why.contains("AXPress"),
                  "T-ACT 没有 AXShowMenu ⇒ 拒, 并列出它支持的动作 实际:\(why)")
            check(why.contains("按它不等于打开它的菜单"),
                  "T-ACT 拒的时候不许把指路写成「那就用 press」—— 那两件事的后果不一样 实际:\(why)")
        } else {
            check(false, "T-ACT 没有 AXShowMenu 的控件不许被 showmenu 放行")
        }
        // 一个动作都没有的格子: 要说"它一个都不提供", 不许押着系统背锅。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.showmenu), scope: scope(),
            target: ComputerActTarget(role: "AXStaticText", title: "正文"), window: .none) {
            check(why.contains("一个动作都不提供"),
                  "T-ACT 一个动作都没有的格子 ⇒ 拒, 且如实说它一个都不提供 实际:\(why)")
        } else {
            check(false, "T-ACT 没有任何动作的格子不许被 showmenu 放行")
        }

        // 两个动作**互不顶替** —— 这一对是"不许把 showmenu 合成 press 的别名"的判据。
        let menuOnly = ComputerActTarget(role: "AXCell", title: "一行", actions: ["AXShowMenu"])
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.press), scope: scope(), target: menuOnly, window: .none) {
            check(why.contains("按不了"), "T-ACT 只有 AXShowMenu 的格子 press 要拒 实际:\(why)")
        } else {
            check(false, "T-ACT press 不许落到只有 AXShowMenu 的格子上")
        }
        check(ComputerActGuard.evaluate(
                request: req(.showmenu), scope: scope(),
                target: ComputerActTarget(role: "AXCell", title: "一行",
                                          actions: ["AXShowMenu", "AXPress"]),
                window: .none) == .allow(.showmenu),
              "T-ACT 两个动作都有时 showmenu 照样是 showmenu (它不是 press 换了个名字)")

        // ⚠️ **红名单管着菜单项**: 菜单项也是控件, 选它 = press 它 ⇒ 走的是同一条恒拒。
        //    这一条是本轮最容易搞错的地方 —— 我一度想给词表加一个光秃秃的「删除」, 那会把
        //    备忘录删除整个掐死(真机实测: 菜单里那一项就叫「删除」)。判据该是**沿用现有词表**。
        check(ComputerRedline.refusal(forControl: "删除", role: "AXMenuItem") == nil,
              "T-ACT 菜单项「删除」放行 —— 它 = 移到废纸篓(可撤销), 不是永久删除")
        check(ComputerRedline.refusal(forControl: "移到废纸篓", role: "AXMenuItem") == nil,
              "T-ACT 菜单项「移到废纸篓」放行")
        if let d = ComputerRedline.refusal(forControl: "立即删除", role: "AXMenuItem") {
            check(d.refusal == .permanentDelete,
                  "T-ACT 菜单项「立即删除」命中恒拒 (菜单项与按钮同一套词表)")
        } else {
            check(false, "T-ACT 菜单项上的「立即删除」必须恒拒 —— 否则菜单成了绕开红线的后门")
        }

        check(ComputerActGuard.preview(action: .showmenu, app: "备忘录", index: 3) == "打开菜单 #3 · 备忘录",
              "T-ACT 卡上那一行: showmenu 写「打开菜单」—— 人签字时要知道屏幕上会多一层面板")

        // MARK: ⑧g `custom` —— 执行元素自己声明的动作 (批 2p, 2026-11-05)

        // 实测起因(把 showmenu 那条结论推翻的那次): 备忘录列表行的动作表是
        //   ["AXShowMenu", "Name:置顶…", "Name:共享…", "Name:删除…"] —— **没有 AXPress / AXOpen**,
        // 所以"先点开某条再开菜单"这条路第一步就断了。而 `Name:删除` 是**行作用域**的
        // (隔离实验: 编辑器里开着乙条, 对甲条那一行执行它 ⇒ 甲条没了、乙条不动)。
        let deleteAction = "Name:删除\nTarget:0x0\nSelector:(null)"
        let pinAction = "Name:置顶\nTarget:0x0\nSelector:(null)"
        // ⚠️ 夹具里**必须放一个真的 `AXPress`**: 第一版的夹具只有 `AXShowMenu`, 于是
        //    "custom 不许发出 AXPress"那条断言**恒真**(它匹配的是一张根本没有 AXPress 的表)。
        //    这类假绿只有在造反例时才看得见 —— 把 `available` 的过滤去掉, 它照样绿。
        let noteRow = ComputerActTarget(
            role: "AXCell", title: "问题修复批五",
            actions: ["AXPress", "AXShowMenu", pinAction,
                      "Name:共享\nTarget:0x0\nSelector:(null)", deleteAction])

        // 名字要洗成人话: 原始串那条噪音尾巴既不该给模型看, 也不该让模型抄。
        check(ComputerCustomAction.humanName(deleteAction) == "删除",
              "T-ACT 动作名洗成「删除」实际:\(ComputerCustomAction.humanName(deleteAction))")
        check(ComputerCustomAction.humanName("Format") == "Format",
              "T-ACT 没有 Name: 前缀的动作就整串用 (有些 App 直接叫 Format)")
        check(ComputerCustomAction.available(noteRow.actions).count == 3,
              "T-ACT AXPress / AXShowMenu 都不算自定义动作 (AX 标准动作是别的 op 的地盘, 实际:"
                + "\(ComputerCustomAction.available(noteRow.actions)))")
        // ⚠️ 这一条是 `custom` 的**后门判据**: 它能发 AXPress 的话, press 那条"动作表里没有
        //    AXPress 就拒"的判据当场失效, 而回执还会说"执行了自定义动作"。
        check(ComputerCustomAction.match(noteRow.actions, needle: "AXPress") == .none,
              "T-ACT custom 绝不许发出 AXPress —— 否则它就是 press 的后门")
        check(ComputerCustomAction.match(noteRow.actions, needle: "删除") == .one(deleteAction),
              "T-ACT 片段「删除」唯一命中, 且交回的是**原始动作名**(执行要用它)")
        check(ComputerCustomAction.match(noteRow.actions, needle: "置") == .one(pinAction),
              "T-ACT 片段按子串匹配 (人不会背完整名字)")
        check(ComputerCustomAction.match(noteRow.actions, needle: " 删除 ") == .one(deleteAction),
              "T-ACT 两侧空白不算错")
        check(ComputerCustomAction.match(noteRow.actions, needle: "") == .none,
              "T-ACT 空片段一个都不命中 (空 = 随便挑一个, 那是我们替他选)")
        // 命中多个 ⇒ 交回候选, **不许挑一个**。
        let twoDeletes = ["Name:删除\nTarget:0x0", "Name:立即删除\nTarget:0x0"]
        if case .many(let hits) = ComputerCustomAction.match(twoDeletes, needle: "删除") {
            check(hits.count == 2,
                  "T-ACT 两个都含「删除」⇒ 交回两个候选让调用方说清 实际:\(hits.count)")
        } else {
            check(false, "T-ACT 命中多个时必须交回候选 —— 挑一个就是我们在替他决定")
        }

        // 放行: 唯一命中 + 行作用域。
        check(ComputerActGuard.evaluate(request: req(.custom, text: "删除"), scope: scope(),
                                        target: noteRow, window: .none) == .allow(.custom),
              "T-ACT 行上的「删除」⇒ custom 放行 (备忘录删笔记唯一可靠的一条路)")

        // 参数缺失: 要说清执行哪一个, 并顺手把它能执行的列出来。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.custom, text: "  "), scope: scope(), target: noteRow, window: .none) {
            check(why.contains("要说清执行哪个动作") && why.contains("置顶"),
                  "T-ACT 空片段 ⇒ 拒, 并列出它能执行的那些 实际:\(why)")
        } else {
            check(false, "T-ACT custom 空片段必须拒")
        }

        // ⚠️ **容器层不许** —— 与 showmenu 被撤掉同一条理由: 容器上那条删除删的是"选中项"。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.custom, text: "删除"), scope: scope(),
            target: ComputerActTarget(role: "AXTable", title: "我的备忘录",
                                      actions: [deleteAction]),
            window: .none) {
            check(why.contains("容器那一层") && why.contains("选中"),
                  "T-ACT 容器上的 custom 必须拒, 且说清它作用在选中项上 实际:\(why)")
        } else {
            check(false, "T-ACT custom 绝不许落在 AXTable 上 —— 删错东西没有撤销")
        }

        // 红线判**动作名**: 「删除」与「立即删除」的差别只在这个名字里(第 ⑥ 条判的是行标题)。
        if case .refuse(_, let refusal) = ComputerActGuard.evaluate(
            request: req(.custom, text: "立即删除"), scope: scope(),
            target: ComputerActTarget(role: "AXCell", title: "一行",
                                      actions: ["Name:立即删除\nTarget:0x0"]),
            window: .none) {
            check(refusal == .permanentDelete,
                  "T-ACT 动作名「立即删除」命中恒拒 —— 自定义动作不许成为绕开红线的路")
        } else {
            check(false, "T-ACT 动作名「立即删除」必须恒拒")
        }
        // 对照组: 同一格上的「删除」照旧放行 —— 证明拒的是那个词, 不是这一类动作。
        check(ComputerActGuard.evaluate(request: req(.custom, text: "删除"), scope: scope(),
                                        target: ComputerActTarget(role: "AXCell", title: "一行",
                                                                  actions: [deleteAction]),
                                        window: .none) == .allow(.custom),
              "T-ACT 对照: 同一格上的「删除」照旧放行 (拒的是词, 不是这一类动作)")

        // 没命中: 说清"它有的是…", 而不是只说做不到 —— 那句话就是模型下一手的依据。
        if case .refuse(let why, _) = ComputerActGuard.evaluate(
            request: req(.custom, text: "归档"), scope: scope(), target: noteRow, window: .none) {
            check(why.contains("上没有含「归档」的动作") && why.contains("置顶"),
                  "T-ACT 没命中 ⇒ 拒, 并列出它真正能做的 实际:\(why)")
        } else {
            check(false, "T-ACT 没命中必须拒, 不许悄悄发一个别的动作")
        }

        check(ComputerActGuard.preview(action: .custom, app: "备忘录", index: 21)
                == "执行自定义动作 #21 · 备忘录",
              "T-ACT 卡上那一行: custom 写「执行自定义动作」")

        // MARK: ⑨ 审批卡上那一行

        check(ComputerActGuard.preview(action: .press, app: "Safari", index: 12) == "按 #12 · Safari",
              "T-ACT 卡片摘要 = 动作 + 编号 + App")
        check(ComputerActGuard.preview(action: .setValue, app: "", index: 7) == "写 #7 · 当前前台",
              "T-ACT 没给 App 时说当前前台, 不写一个空的间隔号")
        check(ComputerActGuard.preview(action: .focus, app: "Safari", index: 4) == "聚焦 #4 · Safari",
              "T-ACT focus 那一行 (批 2f)")
        check(ComputerActGuard.preview(action: .scroll, app: "", index: 4) == "滚动 #4 · 当前前台",
              "T-ACT scroll 那一行: 只承诺编号 + App, 方向不写在这里 "
              + "(滚错方向可以再滚回来, 不必占用卡上那一行)")
        check(ComputerActGuard.preview(action: .open, app: "日历", index: 21) == "打开 #21 · 日历",
              "T-ACT open 那一行: 卡上写「打开」, 实现就必须真发 AXOpen (不许悄悄换成 AXPress)")

        // MARK: ⑨b 坐标寻址的参数合法性 (批 3a) —— 坐标是**输入方式**, 不是第二套寻址

        // 坐标这条路的全部价值: 翻译回元素之后走的还是同一条判据链。所以这里只判参数本身。
        check(ComputerPointRule.refusal(action: .press, index: 0, point: ComputerPoint(x: 420, y: 300)) == nil,
              "T-ACT press + 坐标 + 没给编号 ⇒ 参数成立 (helper 之后会把它翻译成编号)")
        check(ComputerPointRule.refusal(action: .press, index: 12, point: nil) == nil,
              "T-ACT 老路径 (只给编号) 不受影响")
        if let why = ComputerPointRule.refusal(action: .setValue, index: 0,
                                               point: ComputerPoint(x: 420, y: 300)) {
            check(why.contains("坐标只能配 press"),
                  "T-ACT 坐标配 setValue ⇒ 拒 (写字得知道动的是哪一格) 实际:\(why)")
        } else {
            check(false, "T-ACT 非 press 带坐标必须拒 —— 否则就是把坐标当成了通用寻址")
        }
        // `open` 也只走编号: 它要知道打开的是哪一格。而且坐标那条路本来就要求"翻译回来的元素
        // 得在快照里认得出是第几号" —— 给它开坐标一点用都没有, 只是多一条绕路。
        check(ComputerPointRule.refusal(action: .open, index: 0,
                                        point: ComputerPoint(x: 420, y: 300)) != nil,
              "T-ACT open 不吃坐标 (只按编号) —— 它与 press 是两个动作, 不共用寻址方式")
        if let why = ComputerPointRule.refusal(action: .press, index: 12,
                                               point: ComputerPoint(x: 420, y: 300)) {
            check(why.contains("只能给一个"),
                  "T-ACT 编号与坐标同时给 ⇒ 拒, 不许挑一个用 (挑错方向不对称) 实际:\(why)")
        } else {
            check(false, "T-ACT 编号与坐标同时给必须拒")
        }
        if let why = ComputerPointRule.refusal(action: .press, index: 0,
                                               point: ComputerPoint(x: 999_999, y: 300)) {
            check(why.contains("不像屏幕上的点"),
                  "T-ACT 离屏的坐标 ⇒ 拒 (多半是把图片坐标当屏幕坐标了) 实际:\(why)")
        } else {
            check(false, "T-ACT 离屏坐标必须拒")
        }
        check(ComputerPointRule.refusal(action: .press, index: 0,
                                        point: ComputerPoint(x: -1200, y: 400)) == nil,
              "T-ACT 负坐标放行 —— 主屏左侧那块屏就是负值, clamp 到 ≥0 会把它挪到主屏上")
        check(ComputerPoint(x: 420.4, y: 300.6).short == "(420,301)",
              "T-ACT 回执里的坐标是四舍五入后的整数 (420.4/300.6 ⇒ (420,301))")

        // ⚠️ 2026-10-30 真机实测的教训落在这一段: 坐标命中的元素**不在快照里**时分四类,
        //    四类的下一步完全不同 —— 合成一句("重新读一次就有编号了")对容器是**空话**
        //    (容器从来不进快照), 对自绘 App 是**错话**(里面根本没有更细的格子),
        //    对菜单栏是**方向错**(它在窗口树外面, 往窗口里挑格子挑不到)。
        check(ComputerPointRule.missKind(role: "AXApplication") == .wholeApp,
              "T-ACT 命中整窗元素 ⇒ 自绘 App (再读也没有更细的格子, 只能截图看)")
        check(ComputerPointRule.missKind(role: "AXGroup") == .container,
              "T-ACT 命中分组 ⇒ 容器 (它从来就不在快照里, 重读一万次也没编号)")
        check(ComputerPointRule.missKind(role: "") == .container,
              "T-ACT 读不出角色 ⇒ 当容器 (说'重读就有编号'更容易把人带错方向)")
        check(ComputerPointRule.missKind(role: "AXButton") == .stale,
              "T-ACT 命中按钮却不在快照里 ⇒ 只可能是快照过期 (重读一次就有编号)")
        check(ComputerPointRule.missKind(role: "AXMenuBar") == .outerChrome,
              "T-ACT 命中菜单栏 ⇒ 单独一类 (它在窗口树外面: '往里挑一格'和'重读'两句都是错的)")
        check(!ComputerPointRule.containerRoles.contains("AXMenuBar"),
              "T-ACT 菜单栏不许被并进容器类 —— 容器是窗口里面, 菜单栏在窗口外面")
        check(!ComputerPointRule.containerRoles.contains("AXButton")
              && !ComputerPointRule.containerRoles.contains("AXStaticText"),
              "T-ACT 真格子(按钮/文本)不许被归成容器 —— 归错了就吞掉'重读一次'这个正确答案")

        // MARK: ⑩ sheet 的按钮必须**同源**筛出来 (判据算下标, 执行按元素)

        let sheet = AXNode(role: "AXSheet", title: "保存更改", children: [
            AXNode(role: "AXStaticText", title: "要保存吗?"),
            AXNode(role: "AXButton", title: "保存"),
            AXNode(role: "AXButton", title: "取消"),
            AXNode(role: "AXButton", title: ""),      // 空标题的按钮不算: 按不到也说不清
        ])
        check(AXSnapshot.buttonIndices(in: sheet) == [1, 2],
              "T-ACT 只把有名字的 button 算成按钮, 下标对得上 children "
              + "实际:\(AXSnapshot.buttonIndices(in: sheet))")
        let w = AXSnapshot.actWindow(from: sheet)
        check(w.sheetTitle == "保存更改" && w.sheetButtons == ["保存", "取消"],
              "T-ACT actWindow 的标题与按钮同源 (helper 拿同一份下标去按)")
        check(AXSnapshot.actWindow(from: nil) == .none,
              "T-ACT 没有 sheet ⇒ .none (不是空标题的空弹窗)")

        // MARK: ⑪ 两档授权的不变量: act ⊆ read

        let d = ComputerSettings.decode(enabledRaw: "1",
                                        bundlesRaw: "com.apple.Safari,com.apple.mail",
                                        actRaw: "com.apple.mail,com.google.Chrome")
        check(d.actBundles == ["com.apple.mail"],
              "T-ACT 反解时 act 与 read 取交集 (老库/手改库里会留着读不到的 App) "
              + "实际:\(d.actBundles.sorted())")
        let e = ComputerSettings.encode(enabled: true,
                                        bundles: ["com.apple.Safari"],
                                        actBundles: ["com.apple.Safari", "com.apple.mail"])
        check(e.actBundles == "com.apple.Safari",
              "T-ACT 编码是另一条入口, 同样要取交集")
        check(ComputerSettings.decode(enabledRaw: "1", bundlesRaw: "com.apple.Safari")
                .actBundles.isEmpty,
              "T-ACT 批 1 的老库没有 act 键 ⇒ 操作面为空 (不会凭空多出一档权限)")

        let cs = ComputerSettings()
        cs.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari",
                   actRaw: "com.apple.Safari,com.apple.mail")
        check(cs.activeActBundles == ["com.apple.Safari"],
              "T-ACT 下发前再取一次交集 (出事的那个方向不值得省这一行)")
        cs.toggle("com.apple.Safari")   // 取消可读
        check(cs.actSelected.isEmpty && cs.activeActBundles.isEmpty,
              "T-ACT 取消可读必须连带摘掉可操作 (否则留下动得了但读不到的组合)")
        cs.setAct("com.apple.Safari", true)
        check(cs.selected.contains("com.apple.Safari")
                && cs.activeActBundles == ["com.apple.Safari"],
              "T-ACT 开操作会顺带开读 (反方向那一步由设置页的禁用态守)")
        cs.setAct("com.1password.1password", true)
        check(!cs.actSelected.contains("com.1password.1password")
                && !cs.selected.contains("com.1password.1password"),
              "T-ACT 口令类连读都不该被 setAct 顺手勾上")
        cs.enabled = false
        check(cs.activeActBundles.isEmpty,
              "T-ACT 总开关关掉 ⇒ 操作面立刻为空 (同读面那条)")
    }
}
