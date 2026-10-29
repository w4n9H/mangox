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
        print("== T-ACT 动作面判据 (P18 批 2b) ==")

        // MARK: ① op 白名单 —— 认不出来的不许落到任何默认分支

        check(ComputerAction.parse("press") == .press, "T-ACT press 认得")
        check(ComputerAction.parse("setValue") == .setValue, "T-ACT setValue 认得")
        check(ComputerAction.parse(" press ") == .press, "T-ACT 两侧空白不算错 (线上偶尔带)")
        check(ComputerAction.parse("click") == nil,
              "T-ACT 坐标点击不在这一批 ⇒ 认不出来, 不许默默当成 press")
        check(ComputerAction.parse("scroll") == nil,
              "T-ACT 滚动是批 3 的事 ⇒ 现在必须认不出来, 否则等于偷偷开了个面")
        check(ComputerAction.parse("PRESS") == nil,
              "T-ACT 大小写敏感: 线上写错了要变红, 不许看着差不多就认")
        check(ComputerAction.allCases.count == 2,
              "T-ACT 动作面只有两个 —— 多一个就多一条「模型以为自己能动」的路")

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
                 text: String = "") -> ComputerActRequest {
            ComputerActRequest(app: "Safari", action: action, index: index, seq: seq, text: text)
        }
        let button = ComputerActTarget(role: "AXButton", title: "登录", actions: ["AXPress"])
        let field = ComputerActTarget(role: "AXTextField", title: "搜索", actions: ["AXPress"])

        // 基线: 什么都没问题 ⇒ 放行。没有这一条, 后面所有拒绝都可能是「反正都拒」。
        check(ComputerActGuard.evaluate(request: req(), scope: scope(),
                                        target: button, window: .none) == .allow(.press),
              "T-ACT 基线: 权限齐、seq 对、编号在、能按 ⇒ 放行")

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

        // MARK: ⑨ 审批卡上那一行

        check(ComputerActGuard.preview(action: .press, app: "Safari", index: 12) == "按 #12 · Safari",
              "T-ACT 卡片摘要 = 动作 + 编号 + App")
        check(ComputerActGuard.preview(action: .setValue, app: "", index: 7) == "写 #7 · 当前前台",
              "T-ACT 没给 App 时说当前前台, 不写一个空的间隔号")

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
