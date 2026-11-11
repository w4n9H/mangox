//
//  CaseComputerPure.swift
//  P18 批 1: computer use 的**纯函数层** —— 作用域 / 红线 / AX 树整形。
//
//  为什么先测这三样: 它们决定"模型能看见什么、能动什么", 而且是**唯一**能在没有真屏幕、
//  没有 TCC 授权、没有 helper 进程的情况下被断言的部分。helper 与 AX 真调用要到批 2 才接,
//  但判据今天就得钉住 —— 否则后面每一层都在猜。
//
//  ⚠️ 每条断言都要能**变红**: 把 `ComputerScope.resolvedFace` 里那行 credential 拦截去掉,
//     "credential 提 act 必须显式"立刻红; 把 `maskedValue` 的 `isProtected` 去掉,
//     "受保护内容恒遮蔽"立刻红。门禁的价值在于反例, 不在于绿。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseComputerPure() async {
        print("== T-COMPUTER 纯函数层 ==")

        // MARK: 作用域 —— 两层(App 面 × 动作面)

        check(ComputerScope.defaultFace(for: .normal) == .act,
              "T-COMPUTER 普通 App 默认给 act 面 (拿 App 类别当准入门 = 挡名字不挡行为)")
        check(ComputerScope.defaultFace(for: .credential) == .read,
              "T-COMPUTER 凭据/支付类默认只 read (值在序列化边界恒遮蔽 ⇒ 读也不泄露)")

        check(ComputerScope.resolvedFace(bundleId: "com.apple.Safari",
                                         appClass: .normal,
                                         overrides: []) == .act,
              "T-COMPUTER 没有覆盖时走类别默认")
        check(ComputerScope.resolvedFace(bundleId: "com.apple.Safari",
                                         appClass: .normal,
                                         overrides: [ComputerScopeOverride(bundleId: "com.apple.Safari",
                                                                           face: .none)]) == .none,
              "T-COMPUTER 用户把它排除了就得听 (App 面默认全给, 但排除有效)")

        // 这一条就是"act 面恒关"的门: 去掉 resolvedFace 里那行拦截 ⇒ 立刻红
        check(ComputerScope.resolvedFace(bundleId: "com.1password.1password",
                                         appClass: .credential,
                                         overrides: [ComputerScopeOverride(bundleId: "com.1password.1password",
                                                                           face: .act)]) == .read,
              "T-COMPUTER 凭据类写 act 但没带显式标记 ⇒ 仍按只读算 (act 面恒关)")

        check(ComputerScope.resolvedFace(bundleId: "com.1password.1password",
                                         appClass: .credential,
                                         overrides: [ComputerScopeOverride(bundleId: "com.1password.1password",
                                                                           face: .act,
                                                                           explicitCredentialAct: true)]) == .act,
              "T-COMPUTER 凭据类带显式标记才放 act (可放开, 但默认关)")

        // 后写覆盖前写 —— 设置页"改一次写一行", 最后一行才是用户现在看到的那一格
        let twoRows = [
            ComputerScopeOverride(bundleId: "com.x", face: .none),
            ComputerScopeOverride(bundleId: "com.x", face: .act),
        ]
        check(ComputerScope.resolvedFace(bundleId: "com.x", appClass: .normal, overrides: twoRows) == .act,
              "T-COMPUTER 同 bundleId 多条覆盖取最后一条 (与设置页的显示同源)")

        check(!ComputerScope.allowsRead(.none) && ComputerScope.allowsRead(.read),
              "T-COMPUTER none 面连读都不给")
        check(!ComputerScope.allowsAct(.read) && ComputerScope.allowsAct(.act),
              "T-COMPUTER read 面不许 act")

        // MARK: 红线 —— 遮蔽

        check(ComputerRedline.maskedValue("hunter2", role: "AXSecureTextField", isProtected: false)
                == ComputerRedline.mask,
              "T-COMPUTER 密码框的值恒被遮蔽 (遮蔽在序列化边界, 不靠 prompt 提醒)")
        check(ComputerRedline.maskedValue("4111 1111", role: "AXTextField", isProtected: true)
                == ComputerRedline.mask,
              "T-COMPUTER 标了受保护内容的字段同样遮蔽")
        check(ComputerRedline.maskedValue("好的, 我看一下", role: "AXTextField", isProtected: false)
                == "好的, 我看一下",
              "T-COMPUTER 普通输入框不遮蔽 (遮蔽过宽 = 模型看不见自己在填什么)")

        // 遮蔽**只认精确的密码框身份** (2026-10-30 收紧: 只遮 password, 防止误遮)。
        //
        // ⚠️ 为什么值得单列三条: 遮蔽是**单向**的 —— 多遮一格, 模型就少一条它该看见的信息,
        //    而且**看不出少了什么**。少遮还能靠别的手段发现, 多遮发现不了。
        check(ComputerRedline.maskedValue("hunter2", role: "AXTextField", isProtected: false,
                                          subrole: "AXSecureTextField") == ComputerRedline.mask,
              "T-COMPUTER 网页密码框(role=AXTextField + subrole=AXSecureTextField)照遮")
        // ⚠️ 这条是"收紧"本身的护栏: 旧判据是子串匹配, 名字里带 secure 的**任何**角色都会被
        //    当成密码框 ⇒ 一整个分组/面板的文字全变 ••••。收紧后它必须原样出来。
        //    反例: 把 `isPasswordRole` 改回 `contains("secure")` ⇒ 这条立刻红。
        check(ComputerRedline.maskedValue("公开说明", role: "AXSecureGroup", isProtected: false)
                == "公开说明",
              "T-COMPUTER 只是名字里带 secure 的角色不遮 (子串匹配会整片变 ••••, 且零报错)")
        check(ComputerRedline.maskedValue("hunter2", role: "AXSecureTextField", isProtected: false,
                                          subrole: "AXUnknownSubrole") == ComputerRedline.mask,
              "T-COMPUTER subrole 认不出也不影响: role 本身是密码框照遮 (两条路各管一半)")

        // MARK: 红线 —— 三条恒拒

        check(ComputerRedline.refusal(forControl: "确认付款", role: "AXButton")?.refusal == .payment,
              "T-COMPUTER 付款/下单恒拒")
        check(ComputerRedline.refusal(forControl: "立即删除", role: "AXButton")?.refusal == .permanentDelete,
              "T-COMPUTER 永久删除恒拒")

        // ⇧⌘⌫: 标题被本地化成什么都认得出 —— 这条是"认不出标题"时的唯一兜底
        check(ComputerRedline.refusal(forControl: "Delete",
                                      role: "AXMenuItem",
                                      keyEquivalent: "\u{8}",
                                      modifiers: ["command", "shift"])?.refusal == .permanentDelete,
              "T-COMPUTER ⇧⌘⌫ 按快捷键判永久删除 (不靠标题)")

        // 放行的那三侧同样要断言 —— 只会拦的门, 拦多了没人看得出来
        check(ComputerRedline.refusal(forControl: "移到废纸篓", role: "AXMenuItem") == nil,
              "T-COMPUTER 「移到废纸篓」放行 (可恢复的删除不该被拦)")
        check(ComputerRedline.refusal(forControl: "发送", role: "AXButton") == nil,
              "T-COMPUTER 「发送」放行 (2026-10-28 拍板: 它就是任务的目的本身)")

        // MARK: 红线 —— 存盘确认

        check(ComputerRedline.isSavePrompt(title: "保存更改", buttons: ["不保存", "取消"]),
              "T-COMPUTER 认出存盘确认弹窗 (标题路径)")
        check(ComputerRedline.isSavePrompt(title: "", buttons: ["Don't Save", "Cancel"]),
              "T-COMPUTER 标题空也能认 (按钮路径比标题硬, 各 App 标题措辞太散)")
        check(!ComputerRedline.isSavePrompt(title: "重命名", buttons: ["好", "取消"]),
              "T-COMPUTER 普通弹窗不算存盘确认 (否则每次重命名都恒拒)")

        check(ComputerRedline.cancellationIndex(buttons: ["保存", "不保存", "取消"]) == 2,
              "T-COMPUTER 存盘弹窗里挑到的永远是「取消」")
        check(ComputerRedline.savePromptDecision(title: "保存更改",
                                                 buttons: ["保存", "不保存", "取消"])?.refusal == .savePrompt,
              "T-COMPUTER 存盘弹窗恒拒 (模型不该替人决定不保存)")
        check(ComputerRedline.savePromptDecision(title: "保存更改",
                                                 buttons: ["保存", "不保存"]) != nil,
              "T-COMPUTER 没有「取消」键时也不许退而求其次 (连它在问什么都没把握)")

        // MARK: AX 树 —— 剪枝 / 编号 / 遮蔽

        let tree = AXNode(role: "AXWindow", title: "与张三的对话", children: [
            AXNode(role: "AXGroup", children: [
                AXNode(role: "AXButton", title: "发送", actions: ["AXPress"],
                       frame: AXRect(x: 120, y: 34, w: 24, h: 22)),
                AXNode(role: "AXTextField", title: "输入消息", value: ""),
                AXNode(role: "AXSecureTextField", title: "密码", value: "hunter2"),
                AXNode(role: "AXStaticText", title: "对方正在输入…"),
                AXNode(role: "AXStaticText", title: "对方正在输入…"),
                AXNode(role: "AXStaticText", title: ""),
            ]),
        ])
        let snap = AXSnapshot.build(root: tree, appName: "飞书", windowTitle: "与张三的对话")

        check(snap.rows.map(\.number) == Array(1...snap.rows.count),
              "T-COMPUTER 编号从 1 起连续 (模型按编号寻址, 断号就没法指)"
              + " 实际:\(snap.rows.map(\.number))")
        check(snap.rows.count == 4,
              "T-COMPUTER 剪枝后只剩 4 项: 容器不下场、重复文本去重、空 StaticText 丢掉"
              + " 实际:\(snap.rows.map(\.title))")
        check(snap.rows.contains { $0.title == "密码" && $0.value == ComputerRedline.mask },
              "T-COMPUTER 遮蔽发生在整形阶段 —— 进 rows 的已经是被遮蔽的字节")
        check(snap.rows.first(where: { $0.title == "发送" })?.role == "button",
              "T-COMPUTER 角色名去掉 AX 前缀 (button 而不是 AXButton)")

        // 遮蔽的第二条命根子: **受保护内容标记**(不是角色)。2026-10-30 之前 helper 的 `build`
        // 把它硬写成 `false` ⇒ 这一档在真机上从来没生效过, 而角色那一档会把断言照顾得很好看。
        // ⚠️ 这里两个节点**角色完全相同**, 只有 `isProtected` 不同 ⇒ 结论必须不同, 否则就是没读那个标记。
        let cardTree = AXNode(role: "AXWindow", title: "结账", children: [
            AXNode(role: "AXTextField", title: "卡号", value: "4111 1111 1111 1111",
                   isProtected: true),
            AXNode(role: "AXTextField", title: "备注", value: "用公司卡"),
        ])
        let cardSnap = AXSnapshot.build(root: cardTree, appName: "某商店", windowTitle: "结账")
        check(cardSnap.rows.first(where: { $0.title == "卡号" })?.value == ComputerRedline.mask,
              "T-COMPUTER 标了受保护内容的字段被遮蔽 (角色看着只是普通 textfield)")
        check(cardSnap.rows.first(where: { $0.title == "备注" })?.value == "用公司卡",
              "T-COMPUTER 对照: 同样角色、没标受保护 ⇒ 照原样给 (证明上一条是被**标记**翻转的)")
        let cardText = cardSnap.rendered()
        check(!cardText.contains("4111"),
              "T-COMPUTER 渲染出的那段文本里不许出现受保护内容 (只测 rows 不够: 出口是 rendered)")
        check(cardText.contains("卡号"),
              "T-COMPUTER 遮蔽只换值、不吞行 (标题与编号照旧, 否则模型连'那儿有卡号栏'都不知道)")

        // 编号稳定: 同一棵树读两次, 编号必须一致 —— 否则差分与动作寻址全废
        let snap2 = AXSnapshot.build(root: tree, appName: "飞书", windowTitle: "与张三的对话")
        check(snap.rows.map(\.number) == snap2.rows.map(\.number),
              "T-COMPUTER 同一棵树两次整形编号一致")

        let text = snap.rendered()
        check(text.contains("[1] button \"发送\"") && text.contains("# 快照"),
              "T-COMPUTER 渲染出模型看的那段文本 (含表头与编号行)")
        check(!text.contains("hunter2"),
              "T-COMPUTER 渲染结果里不得出现密码原文")
        // 截断提示: 一句谎话比不写更坏 —— 没说"还有 N 项"模型就当那是全部(2026-10-29 补门:
        // 这段文案此前**一条断言都没有**, 改了格式也没人知道)。
        check(!text.contains("未显示"),
              "T-COMPUTER 短快照不许出现截断提示 (没截断却写'还有 N 项' = 让模型以为漏了东西)")

        let wideRoot = AXNode(role: "AXWindow", title: "长列表", frame: AXRect(x: 0, y: 0, w: 800, h: 600),
                              children: (1...200).map { AXNode(role: "AXStaticText", title: "第\($0)条") })
        let wideSnap = AXSnapshot.build(root: wideRoot, appName: "x", windowTitle: "长列表")
        check(wideSnap.rows.count == 200,
              "T-COMPUTER 200 条互不相同的文本都要留下 实际:\(wideSnap.rows.count)")
        let wideText = wideSnap.rendered()
        check(wideText.contains("还有 80 项未显示"),
              "T-COMPUTER 超过上限(120)要**如实报出**剩下的 80 项 —— 否则模型把前 120 条当成全部")
        // ⚠️ 这三条守的是**提示的诚实度**, 不是措辞好看。文案换过两轮, 每一轮都是被真机教学:
        //    ① 初版"需要的话让我滚动/展开再看"是空头承诺(模型的下一步是滚/再读, 两轮都白烧);
        //    ② 改版说"被截的可能是工具栏 —— 滚也滚不到"是在**描述病**, 不是在说规则;
        //    ③ 2026-11-04 批 2l 之后工具栏根本不会被截(见 `keepIndices`), 这句话对**内容行**
        //       反而成了新谎 —— 内容行本来就在可滚区里。现在只许可说一件事实: 上限是常数。
        check(!wideText.contains("让我滚动") && !wideText.contains("滚动再看")
              && !wideText.contains("滚也滚不到"),
              "T-COMPUTER 截断提示不许承诺「滚动/展开就能看到被截的项」 (两轮踩过: 空头承诺 + 描述病)")
        check(wideText.contains("渲染上限 120 项") && wideText.contains("重读也一样"),
              "T-COMPUTER 截断提示要说清「上限是常数、重读没用」 (否则模型唯一的反应就是再读一遍)")
        check(!wideText.contains("[121]"),
              "T-COMPUTER 上限外的不许渲染出来 (上界是硬上界, 不是'大概')")

        // MARK: AX 树 —— 批 2l: 截断不许吃掉固定区
        //
        // 造的是**真机的形状**(2026-11-04 实测): 屏幕最上面那一排是工具栏, 而在 AX 遍历里它
        // 排在**最后**。所以"截断=切尾巴"恰好切掉模型最需要的那几个按钮 —— 日历月视图 130 行
        // 上限 120, 被切的 10 行正是 `添加日程` 与 `日/周/月/年`。
        func toolbarSnap(windowFrame: AXRect?, toolbarCount: Int = 3) -> AXSnapshot {
            var kids = (1...200).map { AXNode(role: "AXStaticText", title: "第\($0)条") }
            for i in 0..<toolbarCount {
                kids.append(AXNode(role: "AXButton",
                                   title: "工具\(i + 1)",
                                   frame: AXRect(x: 700 + i * 60, y: 10, w: 40, h: 24)))
            }
            let root = AXNode(role: "AXWindow", title: "长列表与工具栏",
                              frame: windowFrame, children: kids)
            return AXSnapshot.build(root: root, appName: "x", windowTitle: "长列表与工具栏")
        }
        func shownRowCount(_ s: String) -> Int {
            s.split(separator: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            }.count
        }
        let win = AXRect(x: 0, y: 0, w: 1200, h: 600)

        let toolSnap = toolbarSnap(windowFrame: win)
        check(toolSnap.rows.count == 203,
              "T-COMPUTER 夹具: 200 条内容 + 3 个工具栏按钮 实际:\(toolSnap.rows.count)")
        let toolText = toolSnap.rendered()
        check(toolText.contains("[201] button \"工具1\"") && toolText.contains("[203] button \"工具3\""),
              "T-COMPUTER 顶部固定区(工具栏)不许被渲染上限吃掉 —— 它在遍历末尾, 却在屏幕最上面")
        check(toolText.contains("[117]") && !toolText.contains("[118]"),
              "T-COMPUTER 捞工具栏的代价要从**内容那头**让名额, 不是把上界撑破")
        check(shownRowCount(toolText) == 120,
              "T-COMPUTER 捞回固定区之后总行数仍是上限 120 (上界是硬上界) 实际:\(shownRowCount(toolText))")
        check(toolText.contains("中间 83 项未显示"),
              "T-COMPUTER 缺口要写在**断掉的位置**并说清它换来了什么 (尾部那句'还有 N 项'不成立)")

        // 窗口没报坐标 ⇒ 没有判据, 退回纯遍历序 —— 别猜。
        let noFrameText = toolbarSnap(windowFrame: nil).rendered()
        check(!noFrameText.contains("[201]") && noFrameText.contains("[120]"),
              "T-COMPUTER 窗口没报坐标 ⇒ 整条固定区策略不生效 (不许凭角色猜'这是工具栏')")

        // 固定区本身也封顶: 一个几百行的工具栏不许把快照占满。
        let capText = toolbarSnap(windowFrame: win, toolbarCount: 40).rendered()
        check(capText.contains("[224]") && !capText.contains("[225]"),
              "T-COMPUTER 固定区一次最多捞 \(AXSnapshot.fixedRegionCap) 行 (封顶是它要占内容的名额)")
        check(capText.contains("还有 16 项未显示") && shownRowCount(capText) == 120,
              "T-COMPUTER 封顶之后尾部那批照旧如实报数 (两个缺口可以同时存在)")

        // MARK: AX 树 —— 批 2m: 日期格要进快照, 而且**只有它**能借 identifier 当名字
        //
        // 造的是真机的形状(2026-11-04 实测): 日历事件编辑器展开时间之后是**四个**
        // `AXDateTimeArea`(`start-datepicker` / `start-timepicker` / `end-*`), title 与
        // description **全空**, 名字只在 `AXIdentifier` 里, 值是一个 CFDate(读到 `string()`
        // 那一步已经渲染成 `yyyy-MM-dd HH:mm`)。不放它们进来, "改一条日程的时间"根本没有落脚点;
        // 不借 identifier, 快照里就是四行同名同值, 模型只能瞎猜该写哪一个。
        let dateTree = AXNode(role: "AXWindow", title: "日历", children: [
            AXNode(role: "AXDateTimeArea", value: "2026-11-04 17:00",
                   identifier: "start-datepicker"),
            AXNode(role: "AXDateTimeArea", value: "2026-11-04 17:00",
                   identifier: "start-timepicker"),
            // 对照: 同样只写 identifier 的普通容器 —— 它**不许**借 identifier 当名字。
            AXNode(role: "AXGroup", identifier: "__NS:3421", children: [
                AXNode(role: "AXStaticText", title: "正文"),
            ]),
        ])
        let dateSnap = AXSnapshot.build(root: dateTree, appName: "日历", windowTitle: "日历")
        check(dateSnap.rows.contains { $0.role == "datetimearea" && $0.title == "start-timepicker" },
              "T-COMPUTER 日期格进快照, 名字取 identifier 实际:\(dateSnap.rows.map(\.title))")
        check(dateSnap.rows.filter { $0.role == "datetimearea" }.count == 2,
              "T-COMPUTER 四个日期格一个都不许被当容器剪掉 (它们 title/description 都是空的)")
        check(dateSnap.rows.contains { $0.role == "datetimearea" && $0.value == "2026-11-04 17:00" },
              "T-COMPUTER 日期格的值要渲染出来 (否则模型连现在几点都读不出, 更别说写回去)")
        check(!dateSnap.rows.contains { $0.title == "__NS:3421" },
              "T-COMPUTER 对照: 别的角色不借 identifier (那里常是 __NS:3421 这种纯噪音)")

        // MARK: AX 树 —— 差分

        var changedTree = tree
        changedTree.children[0].children[1].value = "好的, 我看一下"
        let changedSnap = AXSnapshot.build(root: changedTree, appName: "飞书", windowTitle: "与张三的对话")
        let d1 = AXSnapshot.diff(from: snap, to: changedSnap)
        check(d1.changed.count == 1 && d1.added.isEmpty && d1.removed.isEmpty,
              "T-COMPUTER 值变 ⇒ 只报一条改, 不重发整棵树"
              + " 实际:改\(d1.changed.count) 增\(d1.added.count) 删\(d1.removed.count)")
        check(d1.rendered().contains("好的, 我看一下"),
              "T-COMPUTER 差分文案里带上了新值 (模型据此判断要不要继续)")

        var addedTree = tree
        addedTree.children[0].children.append(AXNode(role: "AXButton", title: "附件", actions: ["AXPress"]))
        let addedSnap = AXSnapshot.build(root: addedTree, appName: "飞书", windowTitle: "与张三的对话")
        let d2 = AXSnapshot.diff(from: snap, to: addedSnap)
        check(d2.added.count == 1 && d2.added.first?.title == "附件",
              "T-COMPUTER 新增按钮 ⇒ 报一条新增")

        let d3 = AXSnapshot.diff(from: snap, to: snap)
        check(d3.isEmpty && d3.rendered().contains("变化"),
              "T-COMPUTER 没变化也要说出来 (\"没变化\"本身是信息, 静默会让模型以为读失败了)")
        // ⚠️ 空差分**只**证明"这份文本快照没变", 不是"界面没动"(2026-11-04 端到端实测: 小月历
        //    open 一个日期, 界面跳了, 而 AX 文本一个字都没变 —— 选中/高亮只改绘制)。
        //    旧文案断言"界面没动"是过度断言: 回执前半句刚说"可能已经打开了, 看下面重读的结果",
        //    后半句又说"界面没动" ⇒ 模型当成白做、重试一次不可逆的动作。
        check(!d3.rendered().contains("界面没动"),
              "T-COMPUTER 空差分不许断言「界面没动」(它只证明文本没变; 选中/高亮这类读不到)")
        check(d3.rendered().contains("文本") && d3.rendered().contains("读不到"),
              "T-COMPUTER 空差分要说清这是「文本层面」的结论, 并点明哪类变化读不到")

        // AXIdentifier 优先当差分键 —— 索引路径在"前面插入一个兄弟"时会整批错位
        let idTree = AXNode(role: "AXWindow", children: [
            AXNode(role: "AXButton", title: "发送", identifier: "send-btn", actions: ["AXPress"]),
        ])
        let idSnap = AXSnapshot.build(root: idTree, appName: "飞书", windowTitle: "w")
        check(idSnap.rows.first?.key == "id:send-btn",
              "T-COMPUTER 有 AXIdentifier 就用它当差分键")

        // MARK: 指认 → 定位 —— 模型说得出 App 名字, 说不出此刻的 pid

        let cands = [
            ComputerTarget.Candidate(bundle: "com.apple.Safari", name: "Safari", pid: 100),
            ComputerTarget.Candidate(bundle: "com.apple.SafariTechnologyPreview",
                                     name: "Safari Technology Preview", pid: 200),
            ComputerTarget.Candidate(bundle: "com.apple.mail", name: "Mail", pid: 300),
            ComputerTarget.Candidate(bundle: "com.freron.MailMate", name: "MailMate", pid: 400),
        ]
        check(ComputerTarget.pick(query: "", in: cands) == nil,
              "T-COMPUTER 空 query 不许猜 (空 = 当前前台, 那是候选表回答不了的问题)")
        check(ComputerTarget.pick(query: "   ", in: cands) == nil,
              "T-COMPUTER 只有空格也算没指认 (退化成'挑第一个'会读错 App 且零报错)")
        check(ComputerTarget.pick(query: "com.apple.mail", in: cands)?.pid == 300,
              "T-COMPUTER bundle 全等优先")
        check(ComputerTarget.pick(query: "COM.APPLE.MAIL", in: cands)?.pid == 300,
              "T-COMPUTER bundle 匹配忽略大小写 (模型会照它见过的样子写)")
        check(ComputerTarget.pick(query: "Safari", in: cands)?.pid == 100,
              "T-COMPUTER 名字全等排在'包含'之前 (否则 Safari 撞上 Safari Technology Preview)")
        check(ComputerTarget.pick(query: "Mail", in: cands)?.pid == 300,
              "T-COMPUTER 同理: Mail 不许撞上 MailMate")
        check(ComputerTarget.pick(query: "Preview", in: cands)?.pid == 200,
              "T-COMPUTER 精确匹配全落空时才退到'包含'")
        check(ComputerTarget.pick(query: "没在跑的 App", in: cands) == nil,
              "T-COMPUTER 指认不到 ⇒ nil (回执里带可用清单, 免得模型挨个试过去)")
        check(ComputerTarget.pick(query: "Safari", in: []) == nil,
              "T-COMPUTER 候选为空 ⇒ nil (作用域没开放时不许'挑一个出来读')")

        // MARK: helper 的两条路径 —— 都会**静默**失效, 所以各要一条判据

        check(ComputerHost.helperPath(bundlePath: "/Applications/MangoX.app")
                == "/Applications/MangoX.app/Contents/MacOS/mangox-compute",
              "T-COMPUTER helper 在包里的位置 (拷到 MacOS/ 而不是 Contents/MacOS/ ⇒ "
              + "spawn 抛 No such file, 而界面只表现为'读不到界面')")
        check(ComputerHost.socketPath(home: "/Users/x", id: "ABC") == "/Users/x/.mangox/compute-ABC.sock",
              "T-COMPUTER socket 落在 ~/.mangox 下且带实例 id (固定名会让同时开着的第二个实例"
              + " bind 失败, 而先起的那个还握着权限 ⇒ 静默读到老的一份)")

        // MARK: env 接管 —— 四个键要么都设、要么都删

        let me = ProcessInfo.processInfo.processIdentifier
        let e1 = ComputerHost.environment(existing: nil,
                                          socketPath: "/tmp/a.sock",
                                          allowedBundles: ["com.apple.Safari", "com.apple.mail"],
                                          peerPid: me,
                                          inherited: ["PATH": "/usr/bin"])
        check(e1?[ComputerHost.sockEnvKey] == "/tmp/a.sock",
              "T-COMPUTER 启用时把 socket 路径给子进程 (没有它 ⇒ 工具每次回'未启用')")
        check(e1?[ComputerHost.allowedBundlesEnvKey] == "com.apple.Safari,com.apple.mail",
              "T-COMPUTER 作用域逐字下发 (helper 侧名单为空 ⇒ 一律拒)")
        check(e1?[ComputerHost.peerPidEnvKey] == String(me),
              "T-COMPUTER peer pid 用 App 自己的 pid (pi 是 App 的子进程 ⇒ 一条判据盖两代)")
        check(e1?[ComputerHost.parentPidEnvKey] == String(me),
              "T-COMPUTER 探活 pid 一起下发 (否则 App 崩了会留下一个握着辅助功能权限的孤儿)")
        check(e1?["PATH"] == "/usr/bin",
              "T-COMPUTER 接管 env 时不能把父环境连根拔掉 (existing 为空 ⇒ 以 inherited 为底)")

        let e2 = ComputerHost.environment(existing: nil, socketPath: nil,
                                          allowedBundles: [], peerPid: me,
                                          inherited: ["PATH": "/usr/bin"])
        check(e2 == nil,
              "T-COMPUTER 没启用时不要碰 p.environment (凭空造字典 = 把父环境整体复制进去)")

        // 父进程里残留同名变量: 用户在终端 export 过 ⇒ 子进程会继承 ⇒ 界面显示未启用、
        // 扩展却真的连上了一条 socket。标记不许比事实说得多 —— 所以必须删。
        var dirty = ["PATH": "/usr/bin"]
        dirty[ComputerHost.sockEnvKey] = "/tmp/别人的.sock"
        dirty[ComputerHost.allowedBundlesEnvKey] = "*"
        let e3 = ComputerHost.environment(existing: nil, socketPath: nil,
                                          allowedBundles: [], peerPid: me, inherited: dirty)
        check(e3 != nil,
              "T-COMPUTER 父进程有残留时必须接管 (返回非 nil), 否则那条残留会漏进子进程")
        check(e3?[ComputerHost.sockEnvKey] == nil,
              "T-COMPUTER 没启用时把残留的 socket 路径删掉")
        check(e3?[ComputerHost.allowedBundlesEnvKey] == nil,
              "T-COMPUTER 没启用时把残留的作用域删掉 ('*' 漏下去 = 全开)")
        check(e3?["PATH"] == "/usr/bin",
              "T-COMPUTER 删的是自己那几个键, 不是整份环境")

        let e4 = ComputerHost.environment(existing: ["A": "1"], socketPath: "/tmp/b.sock",
                                          allowedBundles: ["x"], peerPid: me, inherited: [:])
        check(e4?["A"] == "1" && e4?[ComputerHost.sockEnvKey] == "/tmp/b.sock",
              "T-COMPUTER 已有环境字典时在它上面补键 (不能覆盖掉别人刚写进去的东西)")

        // MARK: 人类接管(批 3b) —— 每个失效点都**没有红灯**, 所以各要一条判据

        // ① 开关只在"这一档有人在"时为真, 而且**缺省是关**。
        check(ApprovalMode.interactive.expectsHumanAtKeyboard,
              "T-COMPUTER 交互档有人在键鼠旁 (接管监听只在这一档装)")
        check(!ApprovalMode.autoAllow.expectsHumanAtKeyboard
              && !ApprovalMode.autoJudge.expectsHumanAtKeyboard,
              "T-COMPUTER 定时任务 / 远程驱动两档不装 —— 装了会让无人值守的任务在有人路过"
              + "碰一下鼠标时莫名停住, 而人以为它还在跑")

        let e5 = ComputerHost.environment(existing: nil, socketPath: "/tmp/c.sock",
                                          allowedBundles: ["x"], takeover: true,
                                          peerPid: me, inherited: [:])
        check(e5?[ComputerHost.takeoverEnvKey] == "1",
              "T-COMPUTER 有人在的档位把接管开关下发给 helper")
        let e6 = ComputerHost.environment(existing: nil, socketPath: "/tmp/c.sock",
                                          allowedBundles: ["x"], takeover: false,
                                          peerPid: me, inherited: [:])
        check(e6?[ComputerHost.takeoverEnvKey] == nil,
              "T-COMPUTER 没人在的档位必须**删掉**这个键 (父进程残留会让它看起来装了监听)")
        let e7 = ComputerHost.environment(existing: nil, socketPath: nil,
                                          allowedBundles: [], takeover: true, peerPid: me,
                                          inherited: [ComputerHost.takeoverEnvKey: "1"])
        check(e7?[ComputerHost.takeoverEnvKey] == nil,
              "T-COMPUTER 没挂扩展时连这个键一起清 (没人用的 env 是下次排查的假线索)")

        // ② 换档位必须重启 helper —— 它同样只在启动时读一次 env。
        check(ComputerHost.Scope(read: ["a"], act: [], takeover: false)
                != ComputerHost.Scope(read: ["a"], act: [], takeover: true),
              "T-COMPUTER 接管开关算作用域的一部分 (换档位不重启 ⇒ 监听还是老那一份)")

        // ③ "让路"的判据: 人一动就停, 但**会自己过期** —— 过期的反面是"永久罢工"。
        //    ⚠️ 反例: 把 `quiet < quietSeconds` 改成"只要有人动过就一直拒" ⇒ 下面第 2 条
        //    与第 4 条会红, 而真机上表现为"模型从此再也不动, 回执只说人在用电脑"。
        let t0 = 10_000.0
        check(ComputerTakeover.refusal(lastHumanInputAt: nil, now: t0, installed: true) == nil,
              "T-COMPUTER 装好之后一直没人碰 ⇒ 照做")
        if let why = ComputerTakeover.refusal(lastHumanInputAt: t0 - 0.5, now: t0, installed: true) {
            check(why.contains("动了鼠标") && why.contains("让"),
                  "T-COMPUTER 人刚动过 ⇒ 拒, 且说清「让路」与下一步 (实际:\(why))")
        } else {
            check(false, "T-COMPUTER 人刚动过键鼠必须拒 —— 否则模型会和人的手抢同一个鼠标")
        }
        check(ComputerTakeover.refusal(lastHumanInputAt: t0 - ComputerTakeover.quietSeconds,
                                       now: t0, installed: true) == nil,
              "T-COMPUTER 静默窗口**到期就恢复** (判据是 < 不是 ≤: 到点放行, 别多等一个窗口)")
        check(ComputerTakeover.refusal(lastHumanInputAt: t0 - 0.1, now: t0, installed: false) == nil,
              "T-COMPUTER 监听没装上 ⇒ 放行, 不假装判断过 (能力缺口由回执如实说)")
        check(ComputerTakeover.refusal(lastHumanInputAt: t0 + 5, now: t0, installed: true) != nil,
              "T-COMPUTER 时间戳比此刻还晚(两次取了不同时钟) ⇒ 当刚动过, 别把负静默期当'很久没动'")

        // MARK: 契约 token —— 改一边不会编译报错, 只会静默读到 nil

        let csrc = PiRpcTransport.computerExtensionSource
        check(csrc.contains(ComputerHost.sockEnvKey),
              "T-COMPUTER 扩展里读的 env 名与 App 侧常量同源 (改一边 ⇒ 这条红)")
        check(csrc.contains("op: \"read\""),
              "T-COMPUTER 扩展发的 op 与 helper 协议一致 (协议改名不会编译报错)")
        for one in PiRpcTransport.computerToolNames {
            check(csrc.contains("name: \"" + one + "\""),
                  "T-COMPUTER 工具名 \(one) 必须在扩展源码里出现 (名字表与源码会漂)")
        }

        // MARK: 动作面「开放名单」只许有一份真源

        // ⚠️ 2026-11-05 boss 一句「showmenu 不是说了不给模型调用吗」逼出来的缺口:
        //    **运行时其实关着**, 但关它的是两道互不相干的东西 ——
        //      ① 扩展源码里那份**手抄**的 `op` enum(模型看得见的只有它);
        //      ② helper 的 `ComputerAction.exposed` guard(真拦住它的那一道)。
        //    而**没有任何一条判据**看住这两份清单一致: 谁把 `"showmenu"` 抄回 enum, 编译过、
        //    纯函数断言全绿、`exposed` 那几条也全绿(它们只看 `exposed`), 症状要等到模型真去
        //    调那一下才出现 —— 白烧一轮, 而"门关着"这件事就只剩运行时兜底。
        //    判据落在**真注入给 pi 的那份字节**上, 不是再写一份手抄的期望值(那样又是一个人猿)。
        let opEnum = schemaOpEnum(csrc)
        check(opEnum != nil,
              "T-COMPUTER 能从扩展源码里抠出 op 的 enum (抠不出来 ⇒ 下面两条判的是空集)")
        let schemaOps = opEnum ?? []
        check(!schemaOps.contains(ComputerAction.showmenu.rawValue),
              "T-COMPUTER showmenu **不在**模型看得见的 op 枚举里 (作用域判不了: 实测它删的是"
              + "选中项, 不是那一行 ⇒ 代码保留、入口不给。实际: \(schemaOps))")
        check(Set(schemaOps) == Set(ComputerAction.exposed.map(\.rawValue)),
              "T-COMPUTER schema 的 op 枚举 == ComputerAction.exposed (两份清单必须一致: "
              + "多一个 = 模型能调一个我们没打算给它的动作; 少一个 = 那个动作白写。"
              + "实际 schema \(schemaOps) vs exposed \(ComputerAction.exposed.map(\.rawValue)))")

        // MARK: 扩展落地

        let ceDir = fixtureDir("computer-ext")
        let cePath = PiRpcTransport.ensureComputerExtensionFile(dir: ceDir)
        check(cePath.hasSuffix(PiRpcTransport.computerExtensionFileName),
              "T-COMPUTER 扩展落在托管目录下")
        let ceText = (try? String(contentsOfFile: cePath, encoding: .utf8)) ?? ""
        check(ceText == PiRpcTransport.computerExtensionSource,
              "T-COMPUTER 写出去的文件与源码逐字相等 (写坏了不报错, 只会在 pi 侧静默加载失败)")
        check(PiRpcTransport.ensureComputerExtensionFile(dir: ceDir) == cePath
              && ((try? String(contentsOfFile: cePath, encoding: .utf8)) ?? "") == ceText,
              "T-COMPUTER 再调一次是幂等的 (每轮 spawn 都会保底落一次)")

        // MARK: 语法门 —— 真拿 node 解析一遍**写出去的那份**

        // 为什么这条必须存在: 上面几条只钉"名字对不对得上", **语法错一条都抓不到**。而扩展是
        // 一个 289 行的 TypeScript 字符串 —— 少一个括号/多一个逗号, 编译期零信号、冒烟全绿,
        // 症状只是 pi 侧**静默加载失败** ⇒ 模型那个会话看不到 computer 工具。
        //
        // ⚠️ 为什么是 node 而不是"自己数括号": 那只是一个更差的解析器。扩展带 `import type`
        //    与类型标注, node 22 的 `--experimental-strip-types --check` 只做语法解析 + 类型擦除、
        //    不解析 import, 正好够用, 而且是**别人写好的真解析器**。
        // ⚠️ 找不到 node 就**红**, 不跳过: 一条会自己消失的门 = 没有门 (这条判据的全部价值
        //    就在于它真的跑过)。
        let syntax = runNodeSyntaxCheck(cePath)
        check(syntax.found,
              "T-COMPUTER 扩展语法门跑得起来 (需要 node; 找不到就红, 不静默跳过)")
        check(syntax.ok,
              "T-COMPUTER 扩展源码语法正确 (node 的 stripTypeScriptTypes 真解析; \(syntax.detail))")
        // ⚠️ **判据的判据**: 上面那条绿了不代表检查器在工作 —— 0.2.11 就是拿
        //    `node --check` 当语法门, 而它对含 `import` 的 ESM 一律退 0 ⇒ 扩展里多一个
        //    右括号照样全绿, 直到 pi 加载失败、**引擎起不来**。所以这里再喂一段坏 TS。
        let fake = nodeCheckRejectsBroken()
        check(fake.ok,
              "T-COMPUTER 语法门真的会判错 (喂一段写坏的 TS 必须被拒, 恒绿的门 = 没有门; \(fake.detail))")

        // MARK: 开关与作用域 —— 关 ⇒ 空, 无论勾过什么

        // ⚠️ 用**独立实例**而不是 `.shared`: 单例改了会污染后面登记的用例
        //    (同"冒烟新段必须独立 ChatStore"那条纪律)。
        let cs = ComputerSettings()
        check(cs.activeBundles.isEmpty, "T-COMPUTER 默认关 ⇒ 作用域为空")
        cs.setSelected(["com.apple.Safari", "com.apple.mail"])
        check(cs.activeBundles.isEmpty,
              "T-COMPUTER 关着的时候勾了也不开放 (标记不许比事实说得多)")
        cs.enabled = true
        check(cs.activeBundles == ["com.apple.Safari", "com.apple.mail"],
              "T-COMPUTER 开了才下发, 且**排序**稳定 (同样的勾选拼出同样的 env 串)")
        cs.toggle("com.apple.mail")
        check(cs.activeBundles == ["com.apple.Safari"], "T-COMPUTER 取消勾选立刻反映到作用域")
        cs.enabled = false
        check(cs.activeBundles.isEmpty,
              "T-COMPUTER 关掉 ⇒ 立刻回到空 (不存在'关了但在途会话还开着'的窗口)")

        // MARK: 视觉面(批 3c; 2026-11-10 从「图片」升成**独立一档**)
        //
        // 它进不了动作面(像素里没有编号), 却是遮蔽机制唯一的绕过口(文本值被换成 `••••`,
        // 像素里是原样)。所以下面每条都在守同一件事 —— "默认一张都不拍; 拍了的那几个
        // 必须是用户逐个点过的"。
        // ⚠️ 2026-11-10 起它**不再依附于「可读」**: 勾了它才允许走「ax视觉 / 纯视觉」两种读法,
        //    而 AX 恒空的 App(微信, 主窗 5 节点)只有这一条路 ⇒ 两条判据跟着翻了个面。

        // ① 两把钥匙缺一不可: 总开关开了只代表"允许碰", 视觉要**额外**勾。
        //    ⚠️ 反例: 让 `activeImageBundles` 直接返回 `selected` ⇒ 这条立刻红。
        let ci = ComputerSettings()
        ci.enabled = true
        ci.setSelected(["com.apple.Safari"])
        check(ci.activeImageBundles.isEmpty,
              "T-COMPUTER 总开关开着 + 勾了可读, 但没勾视觉 ⇒ 一张都不拍 (视觉是独立的一把钥匙)")

        ci.setImage("com.apple.Safari", true)
        check(ci.activeImageBundles == ["com.apple.Safari"],
              "T-COMPUTER 勾了才下发视觉面")

        // ② **正交**: 勾视觉不再连带勾读面, 取消读面也不再摘掉视觉。
        //    ⚠️ 两个反例分别打这两条: 在 `setImage` 里补一句 `selected.insert` ⇒ 第一条红;
        //       在 `toggle` 里补一句 `imageSelected.remove` ⇒ 第二条红。
        let cv = ComputerSettings()
        cv.enabled = true
        cv.setImage("com.tencent.xinWeChat", true)
        check(cv.selected.isEmpty && cv.activeImageBundles == ["com.tencent.xinWeChat"],
              "T-COMPUTER 勾视觉不再连带勾读面 (微信 AX 恒空 ⇒ 逼它先勾读面等于那条路永远打不开)")
        check(cv.activeAllowedBundles == ["com.tencent.xinWeChat"],
              "T-COMPUTER 只勾视觉的 App 也在**下发名单**里 (用纯读面当判据 ⇒ helper 压根不启动, "
              + "而设置页三个勾都勾着)")
        cv.setSelected(["com.tencent.xinWeChat"])
        cv.toggle("com.tencent.xinWeChat")
        check(cv.activeImageBundles == ["com.tencent.xinWeChat"],
              "T-COMPUTER 取消可读不摘视觉 (摘了 = 把这个 App 的全部能力一起关死)")

        // ③ 操作面的前提是"**有一条能给编号的来源**", 不是"读得到 AX" ⇒ 可读 ∪ 视觉。
        cv.setAct("com.tencent.xinWeChat", true)
        check(cv.activeActBundles == ["com.tencent.xinWeChat"],
              "T-COMPUTER 只靠视觉也能开操作面 (两条路都给编号: AX 树 / 屏幕识别)")
        // 反例方向: 两条来源都没有时**不替人勾上**(上一批特意避开的错: 自动勾会让人
        // 以为自己只开了一档)。
        cv.setAct("com.apple.mail", true)
        check(!cv.actSelected.contains("com.apple.mail"),
              "T-COMPUTER 一条读法都没有时「可操作」不生效, 也不替人勾上")

        // ④ 排序在**投影层**(`activeImageBundles`)做过一次, env 那层照原样拼 ——
        //    与 `allowedBundles` / `actBundles` 同待遇。`Set` 的迭代顺序不稳定且与插入序
        //    无关 ⇒ 不在投影层排, 同样的勾选每次会拼出不同的 env 串, "改了什么"看不出来。
        let cv2 = ComputerSettings()
        cv2.enabled = true
        cv2.setImage("com.z", true)
        cv2.setImage("com.a", true)
        check(cv2.activeImageBundles == ["com.a", "com.z"],
              "T-COMPUTER 视觉面按字典序下发 (Set 迭代序不稳 ⇒ 不排序就没法 diff)")

        // ⑤ 硬禁区: 口令/系统类一个像素都不许拍。视图置灰之外还得有这一道 ——
        //    视图那层被改坏不会有任何红灯, 只会在真机上把密码拍成图。
        check(!ComputerSettings.canImage("com.1password.1password"),
              "T-COMPUTER 口令类恒不许截图 (文本遮蔽在像素里不成立)")
        cv2.setImage("com.1password.1password", true)
        check(!cv2.activeImageBundles.contains("com.1password.1password")
              && !cv2.selected.contains("com.1password.1password"),
              "T-COMPUTER 硬禁区连勾都勾不上 (判据在状态层, 不靠视图禁用)")

        // ⑥ 两档互不牵连 —— "能看"与"能按"是两个开关, 互相带上是上一批特意避开的错。
        cv2.setAct("com.a", true)         // 来源是视觉: 允许
        cv2.setImage("com.a", false)
        check(cv2.actSelected.contains("com.a"),
              "T-COMPUTER 关视觉不许动操作面 (setImage 不碰 actSelected)")
        // ⚠️ 但**投影**要跟着挡: 勾选记着"我打算能动它", 而两条来源都没了 ⇒ 不下发。
        //    这两条合起来才是完整的话: 状态层不替人改主意, 发送层不替人放宽。
        check(cv2.activeActBundles.isEmpty,
              "T-COMPUTER 来源没了就不下发操作面 (act 记着意图, 投影按 可读 ∪ 视觉 挡掉)")

        // ⑦ 落盘: 视觉同样存**身份**, 但**不再被读面裁剪**, 操作面按 可读 ∪ 视觉 裁。
        check(ComputerSettings.decode(enabledRaw: "1",
                                      bundlesRaw: "com.apple.Safari",
                                      imageRaw: "com.apple.Safari,com.tencent.xinWeChat").imageBundles
                == ["com.apple.Safari", "com.tencent.xinWeChat"],
              "T-COMPUTER 反解时视觉**不**与读面取交集 (取交集 ⇒ 只勾视觉的 App 下次启动被静默抹掉, "
              + "而界面上什么都不会说)")
        check(ComputerSettings.decode(enabledRaw: "1", bundlesRaw: "com.apple.Safari",
                                      actRaw: "com.tencent.xinWeChat",
                                      imageRaw: "com.tencent.xinWeChat").actBundles
                == ["com.tencent.xinWeChat"],
              "T-COMPUTER 操作面的上界是 可读 ∪ 视觉, 不是纯读面")
        check(ComputerSettings.encode(enabled: true, bundles: [],
                                      imageBundles: ["com.tencent.xinWeChat"]).imageBundles
                == "com.tencent.xinWeChat",
              "T-COMPUTER 视觉落盘不跟着读面裁剪 (读面为空时那条唯一的路不能被丢掉)")
        check(ComputerSettings.encode(enabled: true,
                                      bundles: ["com.apple.mail", "com.apple.Safari"],
                                      imageBundles: ["com.apple.Safari"]).imageBundles
                == "com.apple.Safari",
              "T-COMPUTER 视觉落盘串排序稳定")
        check(ComputerSettings.encode(enabled: true, bundles: ["x"]).imageBundles.isEmpty,
              "T-COMPUTER 没勾视觉 ⇒ 落盘是**空串**而不是缺键 (缺键读不出'用户明确关了')")

        // ⑦ 下发: 这个键**恒设**, 空串 = 一张都不拍 —— 与 `takeover` 的"不要就删"不同。
        //    区别在于 `takeover` 缺键只影响"要不要监听", 而这里缺键会让 helper 以为
        //    "这一版 App 根本没有图像功能", 于是把用户明确关掉的事说成"不支持"。
        let eImg = ComputerHost.environment(existing: nil, socketPath: "/tmp/c.sock",
                                            allowedBundles: ["x"], imageBundles: [],
                                            takeover: false, peerPid: me, inherited: [:])
        check(eImg?[ComputerHost.imageBundlesEnvKey] == "",
              "T-COMPUTER 勾选为空也下发空串 (缺键 ≠ 用户关了, 回执会说错)")
        // ⚠️ 这里传**已排序**的 ["a", "b"]: `environment` 只 `joined`, 不重排(同 allowedBundles)。
        //    排序责任在 `activeImageBundles` —— 上面第 ③ 条守的就是它, 别在这里重复断言。
        let eImg2 = ComputerHost.environment(existing: nil, socketPath: "/tmp/c.sock",
                                             allowedBundles: ["x"], imageBundles: ["a", "b"],
                                             takeover: false, peerPid: me, inherited: [:])
        check(eImg2?[ComputerHost.imageBundlesEnvKey] == "a,b",
              "T-COMPUTER 图像面原样拼进 env (排序已在投影层做过, 这一层不重排)")
        let eImg3 = ComputerHost.environment(existing: nil, socketPath: nil,
                                             allowedBundles: [], imageBundles: ["x"],
                                             takeover: false, peerPid: me,
                                             inherited: [ComputerHost.imageBundlesEnvKey: "x"])
        check(eImg3?[ComputerHost.imageBundlesEnvKey] == nil,
              "T-COMPUTER 没挂扩展时连图像键一起清 (否则下次启动读到一条假授权)")

        // MARK: 图像面的判据 (批 3c) —— 只判"能不能拍、拍多大", **不判涂哪儿**

        // ① 名单匹配。**空串与缺键都是"一张都不拍"**, 不做模糊匹配。
        //    ⚠️ 反例: 把 `allowed` 的 `guard let raw, !raw.isEmpty` 去掉 ⇒ 第一条红。
        check(!ComputerShotRule.allowed(bundle: "com.apple.Safari", raw: ""),
              "T-COMPUTER 名单是空串 ⇒ 一张都不拍 (空 = 没勾, 不是全勾)")
        check(!ComputerShotRule.allowed(bundle: "com.apple.Safari", raw: nil),
              "T-COMPUTER 名单缺键 ⇒ 一张都不拍")
        check(ComputerShotRule.allowed(bundle: "com.apple.Safari", raw: "com.apple.Safari"),
              "T-COMPUTER 名单里有它就允许")
        check(ComputerShotRule.allowed(bundle: "com.apple.Safari",
                                       raw: "com.apple.mail, com.apple.Safari"),
              "T-COMPUTER 多值名单按逗号切, 且吃掉两侧空格")
        check(!ComputerShotRule.allowed(bundle: "com.apple.Safar", raw: "com.apple.Safari"),
              "T-COMPUTER 不做前缀/模糊匹配 (少一个字母就是不在名单里)")

        // ② 像素面**不涂黑**(2026-10-30 boss 定) —— 所以这里连一条矩形用例都没有。
        //    ⚠️ 这条决定不能只写在注释里: 谁把 `redactions` / `ctx.fill` 加回来, `run.sh` ③t
        //    的源码扫描会红(判据是"结构里没有这个能力", 不是"这个能力输出为空")。
        let cw = AXRect(x: 100, y: 200, w: 800, h: 600)

        // ③ 截图按 1 倍逻辑尺寸 —— 2 倍会让 PNG 体积翻四倍, 而它要进模型上下文。
        let capSize = ComputerShotRule.captureSize(window: cw)
        check(capSize.width == 800 && capSize.height == 600,
              "T-COMPUTER 截图尺寸 = 窗口逻辑尺寸 (1 倍: 这是兜底, 不是给人看的成品)")
        // ⚠️ 零尺寸不能让 0 漏到 SCK: 那边收到 0 是**抛错**, 而我们会在回执里把它说成"截图失败"。
        let zeroSize = ComputerShotRule.captureSize(window: AXRect(x: 0, y: 0, w: 0, h: 0))
        check(zeroSize.width == 1 && zeroSize.height == 1,
              "T-COMPUTER 零尺寸窗口算出 1×1 而不是 0 (SCK 收到 0 直接抛错)")

        // ④ 长边上限: 超过就等比缩到 maxEdge。**两个方向同一条** —— 同一个分支, 但漏了哪个
        //    方向要能从文案看出来(竖长窗口缩错了会撑爆字节, 横长窗口缩错了会变形)。
        //    ⚠️ 走**真正的入口** `captureSize` 而不是直接调 `fit`: 只测 `fit` 的话, 谁把
        //    `captureSize` 改回"窗口多大就拍多大", 这条照样绿(纯函数没坏, 是它没被用上)。
        let edge = ComputerShotRule.maxEdge
        var badFit: [String] = []
        for (label, w, h) in [("横长", 3008, 1692), ("竖长", 1200, 2400)] {
            let s = ComputerShotRule.captureSize(window: AXRect(x: 0, y: 0, w: w, h: h))
            // 长边必须**正好**是上限, 短边按同一比例(±1px 取整)。
            let expectShort = Int((Double(min(w, h)) * Double(edge) / Double(max(w, h))).rounded())
            guard max(s.width, s.height) == edge,
                  min(s.width, s.height) == max(1, expectShort) else {
                badFit.append("\(label) \(w)×\(h)→\(s.width)×\(s.height) 期望短边 \(expectShort)")
                continue
            }
        }
        check(badFit.isEmpty,
              "T-COMPUTER 超过长边 \(edge) 的窗口等比缩到 \(edge) 且不变形 (缩错 = 字节撑爆或 SCK 非等比拉伸; 错: \(badFit))")

        // ⑤ **只缩不放**: 装得下的窗口原样返回(放大只会更糊, 还白涨字节)。
        //    ⚠️ 正好等于上限那一格必须在"不缩"这一侧 —— 判据写成 `>=` 会把它缩成同一尺寸,
        //    看着一样, 但走的是"重采样"那条路(多一次全画布拷贝)。
        var grew: [String] = []
        for (w, h) in [(800, 600), (edge, edge), (edge - 1, 400)] {
            let s = ComputerShotRule.captureSize(window: AXRect(x: 0, y: 0, w: w, h: h))
            if s.width != w || s.height != h { grew.append("\(w)×\(h)→\(s.width)×\(s.height)") }
        }
        check(grew.isEmpty,
              "T-COMPUTER 装得下的窗口一律原样返回, 不放大也不重采样 (改: \(grew))")

        // MARK: 落盘串 —— 存 bundle id 本身, 不存位置

        let dScope = ComputerSettings.decode(enabledRaw: "1",
                                             bundlesRaw: "com.apple.mail,com.apple.Safari")
        check(dScope.enabled && dScope.bundles == ["com.apple.mail", "com.apple.Safari"],
              "T-COMPUTER 落盘串反解 (存的是 bundle id, 不是列表里的第几个)")
        check(!ComputerSettings.decode(enabledRaw: "0", bundlesRaw: "com.apple.Safari").enabled,
              "T-COMPUTER 不是 \"1\" 一律按关算, 不猜")
        check(ComputerSettings.decode(enabledRaw: nil, bundlesRaw: nil).bundles.isEmpty,
              "T-COMPUTER 键缺失 ⇒ 关且空 (新库表现得像没开过)")
        check(!ComputerSettings.decode(enabledRaw: "yes", bundlesRaw: "com.apple.Safari").enabled,
              "T-COMPUTER 乱值 ⇒ 关 (宁可不给, 不猜着给)")
        let eScope = ComputerSettings.encode(enabled: true,
                                             bundles: ["com.apple.mail", "com.apple.Safari"])
        check(eScope.enabled == "1" && eScope.bundles == "com.apple.Safari,com.apple.mail",
              "T-COMPUTER 编码排序 ⇒ 同样的勾选存成同样的串 (改了什么一眼看得出)")
        check(ComputerSettings.encode(enabled: false, bundles: ["com.apple.Safari"]).bundles
                == "com.apple.Safari",
              "T-COMPUTER 关掉开关**不清空勾选** (再打开时还在, 不用重勾一遍)")
        let round = ComputerSettings.decode(enabledRaw: eScope.enabled, bundlesRaw: eScope.bundles)
        check(round.enabled && round.bundles == ["com.apple.mail", "com.apple.Safari"],
              "T-COMPUTER 编码 → 反解回到同一个集合")

        // MARK: helper 的作用域复用判据 —— 2026-10-29 boss「我明明加了」
        //
        // helper 的作用域是**启动那一刻读 env 定死的**, 进程一起就再也不看 env。
        // 而 `start` 原来只问"进程还在跑吗"，不问"名单还是不是那一批" ⇒ 改了设置之后
        // 助手照旧按旧名单拒，**拒绝信息里列的也是旧那批 App**。症状只有一句"我明明勾了"。

        let permA = ComputerHost.Scope(read: ["com.b", "com.a"], act: [])
        let permB = ComputerHost.Scope(read: ["com.a", "com.b"], act: [])
        check(permA == permB,
              "T-COMPUTER 作用域比较必须**忽略勾选顺序** —— 否则用户点一下顺序就重启一次助手")

        let onlyA = ComputerHost.Scope(read: ["com.a"], act: [])
        check(permA != onlyA,
              "T-COMPUTER 名单变了就**不许复用** —— 复用了助手还按旧名单拒, 而设置页是勾着的")

        let withAct = ComputerHost.Scope(read: ["com.a", "com.b"], act: ["com.a"])
        check(permA != withAct,
              "T-COMPUTER 操作面单独变了也不许复用 (读面相同 ≠ 同一个作用域; "
              + "只比读面 = 新勾的「可操作」永远不生效)")

        // MARK: 「窗口是空的」还是「这个 App 不暴露界面」—— 2026-10-28 实测微信后加的判据

        // 微信实测形状: window 1052×754 + group×2 + button×3, 一个内容角色都没有
        let wechatTree = AXNode(role: "AXWindow", title: "微信",
                                frame: AXRect(x: 109, y: 39, w: 1052, h: 754), children: [
            AXNode(role: "AXGroup", children: [
                AXNode(role: "AXButton", title: "关闭", actions: ["AXPress"]),
                AXNode(role: "AXButton", title: "最小化", actions: ["AXPress"]),
                AXNode(role: "AXButton", title: "缩放", actions: ["AXPress"]),
            ]),
            AXNode(role: "AXGroup"),
        ])
        check(AXSnapshot.lacksReadableControls(root: wechatTree),
              "T-COMPUTER 微信那种树(只有 group + 窗口按钮)要判成'没有可读控件层' "
              + "(实测 6 节点/0 内容角色; 不判 ⇒ 模型那 3 个按钮当成窗口的全部内容)")

        let finderTree = AXNode(role: "AXWindow", title: "访达",
                                frame: AXRect(x: 0, y: 0, w: 900, h: 600), children: [
            AXNode(role: "AXOutline", children: [
                AXNode(role: "AXRow", children: [AXNode(role: "AXCell", title: "桌面")]),
            ]),
        ])
        check(!AXSnapshot.lacksReadableControls(root: finderTree),
              "T-COMPUTER 有列表/单元格 ⇒ 可读 (Finder 实测 567 节点 / 311 处文本)")

        let smallDialog = AXNode(role: "AXWindow", title: "保存",
                                 frame: AXRect(x: 0, y: 0, w: 300, h: 120), children: [
            AXNode(role: "AXButton", title: "取消", actions: ["AXPress"]),
        ])
        check(!AXSnapshot.lacksReadableControls(root: smallDialog),
              "T-COMPUTER 小弹窗(300×120)不判 (min(w,h) < 200 ⇒ 别把对话框拉进来)")

        // 这两条是判据成立的前提: 微信的树恰好全由它们组成
        check(!AXSnapshot.hasReadableControls(root: AXNode(role: "AXGroup")),
              "T-COMPUTER group 不算内容角色 (算进来 = 恒真)")
        check(!AXSnapshot.hasReadableControls(root: AXNode(role: "AXButton", title: "确定")),
              "T-COMPUTER button 不算内容角色 (微信就是 3 个窗口按钮 ⇒ 算进来判据当场废)")
        check(AXSnapshot.hasReadableControls(root: AXNode(role: "AXWindow", children: [
            AXNode(role: "AXTextField"),
        ])), "T-COMPUTER 有输入框就算可读 (别按节点数判)")

        // MARK: 懒加载兜底 —— 2026-10-29 boss 截图「应该是没加载出来」
        //
        // 第一次读 apple.com.cn 只拿到 20 个节点、全是地址栏与工具栏, 而**地址栏本身就是
        // 一个 `textfield`** ⇒ 上面那条判据说"可读", 一个字警告都没有。隔几秒再读, 整页
        // 4627px 全出来了。⇒ 判据不能只看"有没有一片内容控件", 得看**盖住了多少窗口**。

        // 实测形状: 窗口 1440×900, 内容只有顶部 44px 那一行(地址栏 + 两个按钮)
        let safariChromeOnly = AXNode(role: "AXWindow", title: "Apple (中国大陆)",
                                      frame: AXRect(x: 0, y: 0, w: 1440, h: 900), children: [
            AXNode(role: "AXGroup", frame: AXRect(x: 0, y: 0, w: 1440, h: 44), children: [
                AXNode(role: "AXButton", title: "返回", frame: AXRect(x: 10, y: 8, w: 24, h: 28)),
                AXNode(role: "AXTextField", title: "智能搜索栏", frame: AXRect(x: 60, y: 8, w: 600, h: 28)),
                AXNode(role: "AXButton", title: "重新载入", frame: AXRect(x: 700, y: 8, w: 24, h: 28)),
            ]),
        ])
        check(AXSnapshot.hasReadableControls(root: safariChromeOnly),
              "T-LAZY 只读到地址栏也算'有内容角色' —— 这正是旧判据漏掉的那一类")
        check(AXSnapshot.contentCoverage(root: safariChromeOnly) < AXSnapshot.rereadBelowCoverage,
              "T-LAZY 地址栏那一层的覆盖率必须低于重读线 (实测 1425×44 / 1425×4627 ≈ 1%)")
        check(AXSnapshot.worthRereading(root: safariChromeOnly),
              "T-LAZY 只读到工具栏 ⇒ 必须触发重读 (boss 那次就是页面还没建好)")

        // 同一棵树读到正文之后: webarea 铺满窗口
        let safariLoaded = AXNode(role: "AXWindow", title: "Apple (中国大陆)",
                                  frame: AXRect(x: 0, y: 0, w: 1440, h: 900), children: [
            AXNode(role: "AXGroup", frame: AXRect(x: 0, y: 0, w: 1440, h: 44), children: [
                AXNode(role: "AXTextField", title: "智能搜索栏", frame: AXRect(x: 60, y: 8, w: 600, h: 28)),
            ]),
            AXNode(role: "AXWebArea", title: "Apple (中国大陆)", frame: AXRect(x: 0, y: 44, w: 1440, h: 4627)),
        ])
        check(!AXSnapshot.worthRereading(root: safariLoaded),
              "T-LAZY 正文读到了就不再重读 (webarea 铺满 ⇒ 覆盖率到顶)")

        // 超出窗口的元素必须**裁掉** —— 实测 Safari 有一条 image 是 (-579,920 3009×692),
        // 不裁的话一个跑到屏幕外的元素就能把覆盖率刷满。
        let offscreen = AXNode(role: "AXWindow", title: "窗口",
                               frame: AXRect(x: 0, y: 0, w: 1000, h: 800), children: [
            AXNode(role: "AXWebArea", frame: AXRect(x: -579, y: 920, w: 3009, h: 692)),
        ])
        check(AXSnapshot.contentCoverage(root: offscreen) == 0,
              "T-LAZY 完全在窗口外的内容角色裁完是 0 面积 (不裁 = 跑到屏幕外的元素把覆盖率刷满)")

        // 前提判据: 内容角色一个都报不出坐标 ⇒ 覆盖率恒 0 ⇒ **不许**据此重读
        let noFrames = AXNode(role: "AXWindow", title: "访达",
                              frame: AXRect(x: 0, y: 0, w: 900, h: 600), children: [
            AXNode(role: "AXOutline", children: [
                AXNode(role: "AXRow", children: [AXNode(role: "AXCell", title: "桌面")]),
            ]),
        ])
        check(!AXSnapshot.worthRereading(root: noFrames),
              "T-LAZY 内容角色全都不报坐标 ⇒ 不重读 (否则每次读都白等 600ms)")
        check(!AXSnapshot.worthRereading(root: smallDialog),
              "T-LAZY 小弹窗(300×120)不重读 (与 lacksReadableControls 同一条面积下限)")
        check(!AXSnapshot.worthRereading(root: wechatTree),
              "T-LAZY 微信那种树不重读 (一个内容角色都没有 ⇒ 它本来就没实现 AX, 重读也没用)")

        // MARK: 可勾选清单 = **固定白名单** (2026-11-06 boss: 「应用太多了…只放测过 sop 的」)
        //
        // 这一组的职责换了。以前是"合成得对吗"(已安装 ∪ 运行中 ∪ 已勾), 现在是
        // **"目录外的 App 一律进不来"** —— 那才是这次改动要保住的东西。
        // ⚠️ 旧的 `merge` / `scanInstalled` / `appRoots` 判据**整组删掉**而不是留着:
        //    它们守的函数已经不存在了, 留着就是"判据在守一个没人调的东西"(假绿)。
        //
        // ⚠️ 第一版写了 13 条, 被 boss 打回（「不要为了冒烟而冒烟」）后砍到 6 条。
        //    砍掉的都是**复述实现**、不是判据 —— 判据要能变红, 而那几条只有"有人改写实现写法"
        //    才会红, 改了行为它们照样绿:
        //      · `supported.count == Set(supported).count` 并进 ① 同一条 check;
        //      · "手册里有节的都在清单里" —— 被 ① 蕴含(两边集合相等), 永远红不了;
        //      · "行数恒等于白名单大小" —— `options` 就是 `bundles.map`, 这条恒真;
        //      · "取不到名字退末段" 与 "没在跑也占一行" 各自单列 ⇒ 并进 ④/⑤ 的样本里;
        //      · 收敛的 4 条(摘了谁 / 白名单内不动 / 三档一起收 / 幂等) ⇒ 一次调用能全判, 并成 ⑥。
        //    **条数不是指标**: 该减少的是"断言行", 不是"独立失败模式"。

        // ① 目录漂移: 白名单 = 内置 ∪ (第三方 ∩ 装了) ∪ 免手册, 且无重复
        //    环境事实显式喂: 「这几个第三方都装了」那一档（它决定第三方那几行出不出现）。
        //    ⚠️ 期望值**从表里算**, 不写字面量清单: 写字面量的话每加一个 App 都要回来改一次,
        //       而"回来改断言"这个动作会让"漏加"与"断言写错"长得一模一样。
        let supported = ComputerSettings.supported(installed: SopInjection.thirdParty)
        let allowed = SopInjection.covered.union(ComputerSettings.manualFree)
        check(Set(supported) == allowed && Set(supported).count == supported.count,
              "T-COMPUTER 可勾清单 == 手册覆盖 ∪ 免手册, 且无重复 (实测 \(supported)) —— "
              + "两处各留一份清单就会各说各话")
        // ①b **内置写死 / 第三方查安装** —— 2026-11-10 boss 的要求, 三条各守一个失败模式:
        //     ① 没装的人不该看到它（写死 = 给一个永远读不到东西的勾选框）;
        //     ② 内置**不许**因为"没装"而消失（它们恒列, 跟着系统来）;
        //     ③ 两张表不许重叠（重叠 = "恒列"与"装了才列"两套语义打架, 谁赢看代码顺序）。
        let notInstalled = ComputerSettings.supported(installed: [])
        check(!notInstalled.contains("com.google.Chrome") && supported.contains("com.google.Chrome"),
              "T-COMPUTER 第三方 App 装了才列 (没装的人不会在设置页看到它)")
        check(Set(notInstalled).isSubset(of: Set(supported))
                && Set(supported).subtracting(notInstalled) == SopInjection.thirdParty,
              "T-COMPUTER `installed` 只影响第三方那几行 (内置一个都不许因为'没装'而消失, 它们恒列; "
              + "实测差异: \(Set(supported).subtracting(notInstalled).sorted()))")
        check(SopInjection.builtins.isDisjoint(with: SopInjection.thirdParty),
              "T-COMPUTER 内置 / 第三方两张表不许重叠 (实测交集: "
              + "\(SopInjection.builtins.intersection(SopInjection.thirdParty).sorted()))")
        // ② 免手册名单的边界: 它是"省掉一节 SOP"的例外, 不是"随便加一个 App"的口子。
        check(Set(ComputerSettings.manualFree).isDisjoint(with: SopInjection.builtins)
                && Set(ComputerSettings.manualFree).isDisjoint(with: ComputerRedline.actBannedBundles),
              "T-COMPUTER 免手册名单: 不与手册重叠(重叠了手册漏节也看不出来)、不含红线应用"
              + "(「界面简单」不是绕开恒拒的理由) —— 实测 \(ComputerSettings.manualFree)")

        // ② 目录外的 App: **既"装着"也"跑着", 仍然不许出现** —— 这次改动的全部产品要求
        //    ⚠️ 越界样本必须挑一个**真的不在白名单里**的（且要长期不在）:
        //       先用 Safari（11-06 进名单后红）→ 换 Chrome（**11-10 也进名单了**）；
        //       现在用邮件 —— 它 11-04 被 boss 明确移出白名单（见 `builtins` 那条注释），
        //       是最有据的一个"目录外"。挑错样本这条会**反向变红**, 而那种红会被误读成
        //       "白名单漏了它"。
        let fixed = ComputerSettings.options(
            bundles: supported,
            names: ["com.apple.Notes": "备忘录"],
            running: [ComputerTarget.Candidate(bundle: "com.apple.Notes", name: "Notes", pid: 9),
                      ComputerTarget.Candidate(bundle: "com.apple.mail", name: "Mail", pid: 8)])
        check(!fixed.contains { $0.bundle == "com.apple.mail" },
              "T-COMPUTER 正在跑但不在白名单里的 App 不出现 (否则又回到'几百行, 大半没量过')")
        check(fixed.contains { $0.bundle == "com.apple.Notes" && $0.running && $0.name == "备忘录" },
              "T-COMPUTER 白名单里的照样出现、在跑的打标记、名字用传进来的那个")

        // ③ 一个都没在跑时**照样全部列出** —— "先勾好、等下打开就能用"靠的就是这条;
        //    退回"只列运行中"(2026-10-28 那版)立刻红。这也是唯一能抓它的断言, 别删。
        let idle = ComputerSettings.options(bundles: supported, names: [:], running: [])
        check(idle.count == supported.count && idle.allSatisfy { !$0.running },
              "T-COMPUTER 一个都没在跑也列出全部 (实测 \(idle.count)/\(supported.count) 行)")

        // ④ 名字三档回落: 系统名 > 手册节名 > bundle 末段（最坏也要有个能点的名字）
        let bySys = ComputerSettings.displayNames(for: ["com.apple.Notes"],
                                                  manualTitles: ["com.apple.Notes": "备忘录"],
                                                  resolve: { _ in "笔记(系统)" })
        let byManual = ComputerSettings.displayNames(for: ["com.apple.Notes"],
                                                     manualTitles: ["com.apple.Notes": "备忘录"],
                                                     resolve: { _ in nil })
        let bySegment = ComputerSettings.displayNames(for: ["com.example.x"], resolve: { _ in nil })
        check(bySys["com.apple.Notes"] == "笔记(系统)"
                && byManual["com.apple.Notes"] == "备忘录"
                && bySegment["com.example.x"] == "x",
              "T-COMPUTER 名字三档回落 (系统 \(bySys["com.apple.Notes"] ?? "nil") / "
              + "手册 \(byManual["com.apple.Notes"] ?? "nil") / 末段 \(bySegment["com.example.x"] ?? "nil"))")

        // ⑤ 启动收敛（`pruneUnsupported`）: 一次调用把四件事一起判 ——
        //    摘的正是目录外那个 / 白名单内一根不动 / 三档一起收 / 第二遍什么都不摘(幂等)。
        //    拆成四条只会让"同一份前置"重复四遍, 红的还是同一次改坏。
        //    ⚠️ 越界样本同样用邮件（Chrome 11-10 已进白名单, 拿它当越界值这条会恒红）。
        let pruner = ComputerSettings()
        pruner.restore(enabledRaw: "1",
                       bundlesRaw: "com.apple.Notes,com.apple.mail",
                       actRaw: "com.apple.mail",
                       imageRaw: "com.apple.mail")
        check(pruner.selected.contains("com.apple.mail"),
              "T-COMPUTER 前置: `restore` 如实还原越界值 (收敛是产品决定, 不属于'还原')")
        let dropped = pruner.pruneUnsupported(installed: [])
        let twice = pruner.pruneUnsupported(installed: [])
        check(dropped == ["com.apple.mail"]
                && pruner.selected == ["com.apple.Notes"]
                && pruner.actSelected.isEmpty && pruner.imageSelected.isEmpty
                && twice.isEmpty,
              "T-COMPUTER 启动收敛: 摘目录外 / 白名单内不动 / 三档一起收 / 幂等 "
              + "(实测 dropped=\(dropped) read=\(pruner.selected.sorted()) "
              + "act=\(pruner.actSelected.sorted()) img=\(pruner.imageSelected.sorted()) twice=\(twice))")

        // MARK: 名字从哪儿来 + 什么该占行 (2026-10-28 实测, 见 AXAdapter.maxDepth 注释)
        //
        // 实测背景(同一个探针, 同一次辅助功能授权):
        //   · Chrome 的工具栏按钮 `title=返回 desc=返回`(两处都写); Safari 的 `title` **空**、只写 desc
        //   · Chrome 节点 1625 / 深度 23, 网页正文从 d15 起 ⇒ 旧的 depth=14 把整页切在外面
        //   · Chromium 给**每个 DOM 元素**都挂 AXScrollToVisible + AXShowMenu ⇒ 按"有动作"留行时
        //     网页快照 1601 行里 1285 行是噪声(453 个无名 group), 正文被挤到 120 行截断之后

        check(AXSnapshot.label(AXNode(role: "AXButton", title: "返回", detail: "别的说法")) == "返回",
              "T-COMPUTER 名字 title 优先 (两个属性都有值时用 title, 别让描述盖住标题)")
        check(AXSnapshot.label(AXNode(role: "AXButton", detail: "返回")) == "返回",
              "T-COMPUTER title 空要退到 AXDescription —— 实测 Safari 的按钮只写这一处 "
              + "(不读 ⇒ 那一排全是无名的 [n] button: 模型只会说'点第 14 个', 人也看不懂)")
        check(AXSnapshot.label(AXNode(role: "AXImage")) == "",
              "T-COMPUTER 两处都空就是没名字 (不许编一个出来)")
        check(AXSnapshot.label(AXNode(role: "AXTextField", title: " ", detail: " 备注 ")) == "备注",
              "T-COMPUTER 只有空白的 title 等于没有 (退到 description, 且去掉首尾空白)")
        // 这条是**遮蔽的边界**: 密码框的名字不许从 description 里捡 —— 第三方 App 会往那儿乱写
        check(AXSnapshot.label(AXNode(role: "AXSecureTextField", title: "密码", detail: "hunter2")) == "密码",
              "T-COMPUTER 密码框只用 title, 绝不退到 description (值那栏已恒 ••••, 名字不能再开后门)")
        check(AXSnapshot.label(AXNode(role: "AXSecureTextField", detail: "hunter2")) == "",
              "T-COMPUTER 没有 title 的密码框宁可不写名字 (也不把 description 里那串放出去)")

        // 树级: Safari 形状(按钮只有 description) ⇒ 行上有名字, 渲染出来也带名字
        let safariLike = AXSnapshot.build(root: AXNode(role: "AXWindow", title: "Safari", children: [
            AXNode(role: "AXButton", detail: "返回", actions: ["AXPress"]),
            AXNode(role: "AXButton", detail: "前进", actions: ["AXPress"]),
        ]), appName: "com.apple.Safari", windowTitle: "Safari")
        check(safariLike.rows.map(\.title) == ["返回", "前进"],
              "T-COMPUTER 只有 description 的按钮要在快照里带上名字 (截图里那排 [n] button 就是这个毛病)")
        check(safariLike.rendered().contains("\"返回\""),
              "T-COMPUTER 名字要真的进到模型看的那段文本里 (住在 AXNode 里但没渲染 = 等于没修)")

        // 网页模型: 无名容器即使带动作也只借道; 但有名字的容器、无名的按钮/输入框要留
        let domLike = AXSnapshot.build(root: AXNode(role: "AXWindow", title: "页面", children: [
            AXNode(role: "AXGroup", actions: ["AXScrollToVisible", "AXShowMenu"], children: [
                AXNode(role: "AXStaticText", value: "正文一"),
            ]),
            AXNode(role: "AXGroup", title: "卡片", actions: ["AXScrollToVisible"]),
            AXNode(role: "AXButton", actions: ["AXPress"]),
            AXNode(role: "AXTextField"),
        ]), appName: "com.google.Chrome", windowTitle: "页面")
        check(!domLike.rows.contains { $0.role == "group" && $0.title.isEmpty },
              "T-COMPUTER 无名的 group 带动作也不占行 (Chromium 每个 DOM 元素都挂 ScrollToVisible/ShowMenu "
              + "⇒ 认'有动作'就会把网页噪声全留下, 正文被挤到截断之后 = 读到了却看不见)")
        check(domLike.rows.contains { $0.role == "group" && $0.title == "卡片" },
              "T-COMPUTER 有名字的容器要留 (名字标记的是它下面那棵子树)")

        // 有名字的容器里最典型的一个: Finder 的 `outline "边栏"`。
        // 丢掉它 ⇒ 模型只看见一串无名格子, 分不清哪些属于边栏、哪些属于文件列表。
        let finderLike = AXSnapshot.build(root: AXNode(role: "AXWindow", title: "docs", children: [
            AXNode(role: "AXOutline", title: "边栏", children: [
                AXNode(role: "AXStaticText", value: "个人收藏"),
            ]),
        ]), appName: "com.apple.finder", windowTitle: "docs")
        check(finderLike.rows.contains { $0.role == "outline" && $0.title == "边栏" },
              "T-COMPUTER 有名字的容器要占一行 (Finder 的 outline \"边栏\" —— 它是那棵子树的标签)")
        check(!finderLike.rows.contains { $0.role == "window" },
              "T-COMPUTER 结构根(window/sheet/dialog)只借道, 名字不占行 (表头已经写了一整行 " 
              + "\"前台:· 窗口:\" ⇒ 再来一行就是同一句话的第二遍)")
        check(domLike.rows.contains { $0.role == "button" && $0.title.isEmpty },
              "T-COMPUTER 无名的按钮仍要留 (微信主窗口就只有 3 个无名红绿灯按钮 —— 它们能被点)")
        check(domLike.rows.contains { $0.role == "textfield" && $0.title.isEmpty },
              "T-COMPUTER 无名的输入框仍要留 (要能按编号定位才输得进去)")
        check(domLike.rows.contains { $0.role == "statictext" && $0.value == "正文一" },
              "T-COMPUTER 无名容器下面的正文照旧要留 (容器只借道, 孩子接着走)")

        // 只写在 description 里的**文本**也是文本: 只看 title/value 会把它当布局占位丢掉
        let descText = AXSnapshot.build(root: AXNode(role: "AXWindow", title: "w", children: [
            AXNode(role: "AXStaticText", detail: "只写在描述里的正文"),
        ]), appName: "a", windowTitle: "w")
        check(descText.rows.contains { $0.title == "只写在描述里的正文" },
              "T-COMPUTER 只写在 description 里的文本不许当布局占位 (与 Safari 按钮无名是同一个坑)")

        // 去冗余只对**小文本**: 同名的两个按钮是两个控件, 合并 ⇒ 编号少一个 ⇒ 点下去不可逆
        let twin = AXSnapshot.build(root: AXNode(role: "AXWindow", title: "确认", children: [
            AXNode(role: "AXButton", title: "继续", actions: ["AXPress"]),
            AXNode(role: "AXButton", title: "继续", actions: ["AXPress"]),
        ]), appName: "a", windowTitle: "确认")
        check(twin.rows.filter { $0.role == "button" }.count == 2,
              "T-COMPUTER 同名按钮不许被去冗余合并 (按钮是控件不是文本; 合并 = 少一个编号, "
              + "跨过'确定/取消'那种点击是不可逆的)")

        // 2026-10-28 实测百度首页(Safari): 每个导航项都是 `link "新闻"` + 子 `statictext (值:"新闻")`,
        // 文本住在 **value** 里 ⇒ 去冗余若只认名字就整个失效, 111 行里约 50 行是这种成对重复。
        let navLike = AXSnapshot.build(root: AXNode(role: "AXWindow", title: "百度", children: [
            AXNode(role: "AXLink", title: "新闻", children: [AXNode(role: "AXStaticText", value: "新闻")]),
            AXNode(role: "AXLink", title: "地图", children: [AXNode(role: "AXStaticText", value: "地图")]),
        ]), appName: "com.apple.Safari", windowTitle: "百度")
        check(navLike.rows.map(\.title) == ["新闻", "地图"],
              "T-COMPUTER 住在 value 里的文本也要参与去冗余 (只认名字 ⇒ 每个导航项占两行, "
              + "实测快照 111 行里 50 行是重复)")
        check(!navLike.rendered().contains("(值:\"新闻\")"),
              "T-COMPUTER 去冗余生效后, 渲染里不再出现同一句的第二遍")
        check(navLike.rows.first?.title == "新闻",
              "T-COMPUTER 行的名字只认 label, 不拿值凑 (否则渲染成 `\"新闻\" (值:\"新闻\")`)")

        // MARK: 渲染上限**按 App** 给 (2026-11-06)
        //
        // 内置四个 App 的树只有几百行（备忘录 71 / 日历 130 / 提醒事项 54 / 访达 291），120 够用。
        // Safari 的树里装着整个网页 —— 实测（2026-11-06）GitHub 仓库页 **1598 行**，而 120 行
        // 只够看到页头导航（`Products` / `Sign in` / `Code` / `Issues`），正文在 1000 行开外
        // ⇒ 不给它更大的上限，这个 App 等于只能读个标题栏。
        check(AXSnapshot.renderLineLimit(for: "com.apple.Safari") == 3000,
              "T-COMPUTER Safari 渲染上限 3000 行 (实测 GitHub 仓库页 1598 行; 120 行只够看页头)")
        check(AXSnapshot.renderLineLimit(for: "com.google.Chrome") == 3000,
              "T-COMPUTER Chrome 渲染上限 3000 行 (实测 B 站首页 222 行; 120 行只到正文开头)")
        let narrow = SopInjection.builtins
            .subtracting(["com.apple.Safari"])      // 唯一被放宽的内置（Chrome 不在这张表里）
            .union(["com.apple.calculator"])        // 免手册的那个也不是网页
            .union(["com.example.unconfigured"])    // 压根没配过的
        check(narrow.allSatisfy { AXSnapshot.renderLineLimit(for: $0) == 120 },
              "T-COMPUTER 只给浏览器放宽: 其余内置 + 计算器 + 未配置的仍然是 120 "
              + "(它们的树只有几百行, 放开是纯亏 —— 这份文本每轮都留在上下文里。实际: "
              + "\(narrow.filter { AXSnapshot.renderLineLimit(for: $0) != 120 }.sorted()))")
        // 行为面: 上限要**真的**影响渲染 —— 只查上面那张表证明不了它会被用上。
        let longPage = AXSnapshot.build(root: AXNode(role: "AXWindow", title: "长页", children:
            (0..<200).map { AXNode(role: "AXStaticText", value: "第\($0)行") }),
            appName: "com.apple.Safari", windowTitle: "长页")
        let capped = longPage.rendered(limit: 120)
        let roomy = longPage.rendered(limit: 3000)
        check(roomy.count > capped.count && capped.contains("未显示") && !roomy.contains("未显示"),
              "T-COMPUTER 上限真的生效 (120 行: \(capped.count) 字且带截断提示; "
              + "3000 行: \(roomy.count) 字全量)")
        // 收口（2026-11-09）：差异只许住在 `ComputerAppProfile` 的表里，而**表点名的 App
        // 必须真的在清单里** —— `supported(installed:)` 是从「手册节 ∩（builtins ∪ 装了的
        // thirdParty）∪ manualFree」**算**出来的，它不认这张表。所以"表里加一行、手册没加节"
        // 的后果是：读法放宽了，而用户在设置页根本勾不到这个 App（等于这个 App 不存在）。
        // ⚠️ "装了 Chrome"这一档必须显式喂 —— 不喂的话 Chrome 从清单里消失，这条会红在
        //    一个与"表 vs 清单"无关的原因上（2026-11-10 起 Chrome 在 thirdParty）。
        let strayProfiles = ComputerAppProfile.profiledBundles
            .filter { !ComputerSettings.supported(installed: ["com.google.Chrome"]).contains($0) }
        check(strayProfiles.isEmpty,
              "T-COMPUTER 读法表点名的 App 必须真在清单里 (否则那张表在描述一个勾不到的东西; "
              + "实际越界: \(strayProfiles) —— 清单 = "
              + "\(ComputerSettings.supported(installed: ["com.google.Chrome"])))")

        // 只有空白的文本(空格/换行)等于没有 —— 那些行在屏幕上什么也不显示
        let blankText = AXSnapshot.build(root: AXNode(role: "AXWindow", title: "w", children: [
            AXNode(role: "AXStaticText", value: "   "),
            AXNode(role: "AXStaticText", value: "\n"),
            AXNode(role: "AXStaticText", value: "真文本"),
        ]), appName: "a", windowTitle: "w")
        check(blankText.rows.count == 1 && blankText.rows.first?.value == "真文本",
              "T-COMPUTER 只有空白的文本要丢掉 (渲染出来是空行, 白占编号)")

        // 名字与值相同 ⇒ 只写一遍。实测 Safari 把同一段字既塞 AXDescription 又塞 AXValue
        let sameBoth = AXSnapshot.line(AXSnapshot.Row(number: 7, indent: 0, role: "statictext",
                                                      title: "设置", value: "设置",
                                                      frame: nil, actions: [], key: "path:0",
                                                      path: [0]))
        check(sameBoth == "[7] statictext \"设置\"",
              "T-COMPUTER 值与名字相同时不许写两遍 (Safari 整页都是 desc==value ⇒ "
              + "以前渲染成 `\"设置\" (值:\"设置\")`) 实际:\(sameBoth)")

        // MARK: 读健康 —— "读不动"由观测长出来 (2026-11-02)
        //
        // 背景: 邮件收件箱(799 封)一次 read 走 3000 节点 / **200 秒**, 而 helper 是单线程串行
        // (accept → 处理 → 关闭) ⇒ 那 200 秒里连 `accept()` 都不转, 别的会话全排队。
        // 手写一个 mail 黑名单能挡这一次, 但挡不住下一个"界面很大"的 App, 而且剪枝修好后
        // 没人记得回来删它。所以名单由**观测**长出来: helper 每次 read 覆盖写一行,
        // 读成功就把坏标记盖掉。下面这三态就是"设置页该不该置灰"的全部判据。

        let now = Date()
        let okHealth = ComputerSettings.ReadHealth(stop: "complete", rows: 2524,
                                                   elapsedMs: 900, at: now)
        let slowHealth = ComputerSettings.ReadHealth(stop: "timeout", rows: 3000,
                                                     elapsedMs: 12000, at: now)
        let staleHealth = ComputerSettings.ReadHealth(stop: "timeout", rows: 3000,
                                                      elapsedMs: 12000,
                                                      at: now.addingTimeInterval(-8 * 24 * 3600))
        check(!okHealth.isPartial && !okHealth.isBlocking,
              "T-COMPUTER 读过一次完整的 ⇒ 不当成读不动 (观测记的是'最近一次', 不是历史最差; "
              + "否则邮件这种'某种界面大、大多数界面正常'的 App 会被一次坏读数永久钉死)")
        check(slowHealth.isPartial && slowHealth.isBlocking,
              "T-COMPUTER 超时的那次要被标成读不动 (邮件收件箱实测 3000 节点 / 200 秒; "
              + "不许把它继续摆在'可用列表'里让模型一头撞上去)")
        check(staleHealth.isPartial && !staleHealth.isBlocking,
              "T-COMPUTER 观测过期(>7 天)就不再据此劝退 (过期 ≠ 变好了, 只 ≠ 能代表现在 ⇒ "
              + "过期的坏标记只降级成提示, 不删标记: 删了就等于假装它好了)")
        check(!slowHealth.isStale && staleHealth.isStale,
              "T-COMPUTER isStale 只看时间, 不看 stop (两条判据不许合述: 陈旧是 mtime 的事, "
              + "读不动是 stop 的事)")

        // budget 与 timeout 是两种"没读完", 归因分开说、结论一样 —— 都没拿到全貌。
        // 若哪天只把 timeout 当读不动, 撞节点上限的 App 就会静默回到可用列表。
        let cappedHealth = ComputerSettings.ReadHealth(stop: "budget", rows: 3000,
                                                       elapsedMs: 300, at: now)
        check(cappedHealth.isBlocking,
              "T-COMPUTER 撞节点上限也算没读完 (budget 与 timeout 归因不同、结论相同: "
              + "手里那份都是截断的树, 模型会把它当全部)")

        // 落盘一侧: helper 写的是 JSON 文件, App 侧只认 bundle/stop/at。
        // 这一段同时钉住**两侧的契约** —— 字段名对不上时这里立刻红, 而不是等设置页永远空着。
        let healthDir = fixtureDir("readhealth")
        func writeHealth(_ bundle: String, _ stop: String?, _ at: Date?) {
            var obj: [String: Any] = ["bundle": bundle, "name": bundle,
                                      "rows": 12, "elapsedMs": 8000]
            if let stop { obj["stop"] = stop }
            if let at { obj["at"] = at.timeIntervalSince1970 }
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            else { return }
            try? data.write(to: URL(fileURLWithPath: healthDir + "/" + bundle + ".json"))
        }
        writeHealth("com.apple.mail", "timeout", now)
        writeHealth("com.apple.iCal", "complete", now)
        // 半截文件(写到一半断电 / 手改坏了)不许把整张表拖垮 —— 跳过那一份, 其余照读。
        writeHealth("com.apple.finder", nil, now)
        try? Data("not json".utf8).write(to: URL(fileURLWithPath: healthDir + "/junk.json"))
        let loaded = ComputerSettings.loadReadHealth(dir: healthDir)
        check(loaded.count == 2,
              "T-COMPUTER 缺字段/坏 JSON 的那几份要跳过, 不能拖垮整张表 (实际读到 \(loaded.count) 条: "
              + "\(loaded.keys.sorted().joined(separator: ",")))")
        check(loaded["com.apple.mail"]?.isBlocking == true,
              "T-COMPUTER helper 写的 timeout 记录能被设置页读成'读不动' "
              + "(字段名 bundle/stop/at 就是两侧的契约, 对不上时设置页会永远空着而零红灯)")
        check(loaded["com.apple.iCal"]?.isBlocking == false,
              "T-COMPUTER 读过完整的记录读回来不算读不动")
        check(loaded["com.apple.mail"]?.rows == 12 && loaded["com.apple.mail"]?.elapsedMs == 8000,
              "T-COMPUTER rows / elapsedMs 要能读回来 (设置页要显示'读不动 · Ns', 数字得是真的)")
        check(ComputerSettings.loadReadHealth(dir: healthDir + "/missing").isEmpty,
              "T-COMPUTER 健康目录整不存在时返回空表, 不报错 (第一次用还没读过任何 App)")

        // MARK: 三把系统钥匙 (2026-11-02)
        //
        // 这一组的由来是一次实测反馈: 三个权限的申请时机相隔很远(输入监控一 spawn 就要、
        // 辅助功能第一次读才要、录屏第一次截图才要), 而界面上只有一句讲辅助功能。
        // 判据分两半: ① 接管检测的**三段与门**(它决定"会不会偷偷把权限带出来");
        // ② 三个深链 token 与文案(它决定"用户能不能自己补回来")。

        // ① 唯一为真的组合 —— 档位是交互档 ∧ 用户显式开了 ∧ 系统已经给了权限。
        check(ComputerSettings.shouldInstallTakeover(expectsHuman: true,
                                                     persisted: true,
                                                     granted: true),
              "T-COMPUTER 三个条件齐了才装接管检测")
        // ⚠️ 这一条就是"别再偷偷弹输入监控"本身: 去掉纯函数里的 `&& granted` ⇒ 立刻红。
        check(!ComputerSettings.shouldInstallTakeover(expectsHuman: true,
                                                      persisted: true,
                                                      granted: false),
              "T-COMPUTER 没有「输入监控」权限时**不许**去装事件监听 "
              + "(装了就会当场弹系统窗, 而那一下正是用户什么都还没要的时候)")
        check(!ComputerSettings.shouldInstallTakeover(expectsHuman: true,
                                                      persisted: false,
                                                      granted: true),
              "T-COMPUTER 用户没开这个开关就不装 (默认关 = 不再在 spawn 时索要权限)")
        check(!ComputerSettings.shouldInstallTakeover(expectsHuman: false,
                                                      persisted: true,
                                                      granted: true),
              "T-COMPUTER 无人值守档(D)不装 (有人在旁边碰一下鼠标就停住, 人以为它在跑)")

        // ② 落盘: 开关是"意图", "1"/"0" 恒写; 缺失与乱值一律按关算, 不猜。
        let tcs = ComputerSettings()
        var written: [String: String] = [:]
        tcs.onPersist = { key, value in written[key] = value }
        tcs.takeoverEnabled = true
        check(written[ComputerSettings.takeoverKey] == "1",
              "T-COMPUTER 接管检测开关打开要落 \"1\" (实际 \(written[ComputerSettings.takeoverKey] ?? "nil"))")
        tcs.takeoverEnabled = false
        check(written[ComputerSettings.takeoverKey] == "0",
              "T-COMPUTER 关掉要留下明确的 \"0\", 不是删键 (否则看不出'是谁关的')")
        tcs.onPersist = nil

        let rcs = ComputerSettings()
        rcs.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari", takeoverRaw: "1")
        check(rcs.takeoverEnabled, "T-COMPUTER 落盘串反解: \"1\" ⇒ 开")
        rcs.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari")
        check(!rcs.takeoverEnabled,
              "T-COMPUTER 老库没有这个键 ⇒ 关 (不许写成 `?? true` 把权限偷偷带出来)")
        rcs.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari", takeoverRaw: "yes")
        check(!rcs.takeoverEnabled, "T-COMPUTER 乱值 ⇒ 关 (宁可不给, 不猜着给)")

        // ③ 三个深链: token 是契约串, 拼错不报错、只会静默打开「隐私与安全性」首页。
        check(ComputerPermission.accessibility.settingsURL
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
              "T-COMPUTER 辅助功能的深链逐字 (拼错会静默落在首页, 用户以为没有这一项)")
        check(ComputerPermission.inputMonitoring.settingsURL
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
              "T-COMPUTER 输入监控的深链逐字 (是 ListenEvent, 不是 InputMonitoring)")
        check(ComputerPermission.screenRecording.settingsURL
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
              "T-COMPUTER 屏幕录制的深链逐字")
        // 复制粘贴最典型的错不是"拼错", 而是"三行都指向同一页" —— 那样灯灭了点一下就去了别的地方。
        let tokens = ComputerPermission.allCases.map(\.paneToken)
        check(Set(tokens).count == tokens.count,
              "T-COMPUTER 三把钥匙必须去三个不同的页 (实际 \(tokens))")

        // ④ 文案: 每条都得说"缺了会怎样"。空串在本地化回落时不会报错, 只会让那一行变成哑巴。
        for p in ComputerPermission.allCases {
            check(!p.title.isEmpty && !p.consequence.isEmpty,
                  "T-COMPUTER \(p.rawValue) 的标题与后果文案都不许为空")
        }
        check(ComputerPermission.allCases.map(\.rawValue)
                == ["accessibility", "inputMonitoring", "screenRecording"],
              "T-COMPUTER 深链的顺序 = 显示顺序 (缺了它先坏哪件事), 不按弹窗出现的先后")

        // ⑤ (批 2i) UI 只画**两把**钥匙 —— `inputMonitoring` 留在 enum 里(深链与 helper 判据都要),
        //    但它**不许进 `keys`**: 辅助功能一给, `CGPreflightListenEventAccess` 就恒 true, 那个列表
        //    里根本没有条目可给。画成灯 + 开关 = 让用户去追一个不存在的东西(2026-11-04 boss 实测)。
        check(ComputerPermission.keys == [.accessibility, .screenRecording],
              "T-COMPUTER UI 只画辅助功能与屏幕录制两把钥匙 (实际 \(ComputerPermission.keys.map(\.rawValue)))")
        check(!ComputerPermission.keys.contains(.inputMonitoring),
              "T-COMPUTER 输入监控不许再画成第三把钥匙 (它恒真、也无从授予)")
        // 「点 + 手加」这句只能挂在真正会缺条目那一项上: 挂在辅助功能上会让人去手加一个早就有的东西。
        check(ComputerPermission.screenRecording.manualAddHint != nil
                && ComputerPermission.accessibility.manualAddHint == nil
                && ComputerPermission.inputMonitoring.manualAddHint == nil,
              "T-COMPUTER 「系统设置里没有它？点 + 手加」这句只挂给屏幕录制")
    }

    /// 从扩展源码里抠出 `op` 那个 enum —— **模型能看见哪些 op 的唯一一处**。
    ///
    /// ⚠️ 认「含 `press` 的那一个」而不是「第一个」: 源码里有两个 `enum: [`(`op` 与 `direction`
    ///    的 up/down), 取第一个会拿到方向表, 于是这条判据永远在比一份无关的清单(**假绿**)。
    /// ⚠️ 不引真 TS 解析器: 这里要的只是「一个数组字面量里的字符串」, 上手写解析器反而更容易坏;
    ///    语法那条由下面 `runNodeSyntaxCheck` 的真解析器管, 两件事别混。
    static func schemaOpEnum(_ src: String) -> [String]? {
        var rest = Substring(src)
        while let head = rest.range(of: "enum: [") {
            rest = rest[head.upperBound...]
            guard let end = rest.firstIndex(of: "]") else { return nil }
            // 引号把数组切成奇数段: 第 1/3/5… 段才是值(`["a", "b"]` → ["a", ", ", "b"])。
            let vals = rest[..<end].split(separator: "\"", omittingEmptySubsequences: false)
                .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            if vals.contains("press") { return vals }
        }
        return nil
    }

    /// 拿 node 真解析一遍扩展源码。
    ///
    /// 走 `/usr/bin/env node`（跟用户 shell 同一套 PATH 解析），**不硬编码 node 路径**：
    /// 那台机器上 node 可能来自 nvm / homebrew / 宿主自带的运行时，写死一个就等于换台机器就静默失效。
    ///
    /// 返回值三态分开（`found` / `ok` / `detail`）是刻意的：**"没跑起来"与"跑起来但语法错"
    /// 必须是两条断言** —— 合成一条的话，node 不在的机器上会显示"语法正确"（假绿）。
    ///
    /// ⚠️ **不能用 `node --check`**（2026-11-11 实锤）：`--check` 只校验 CommonJS，遇到含
    ///    `import` 的 ESM 文件**静默跳过并退 0** —— 于是这道门对这份扩展**永远绿**，
    ///    连 `const a = );` 这种错都判不出来。0.2.11 就是这么发出去的：扩展里多了一个右括号，
    ///    2382 条断言全绿，而 pi 一加载就 ParseError ⇒ **引擎根本起不来**。
    ///    现在改成调 `module.stripTypeScriptTypes()`：那是 node 自己的 TS 解析器，真的会抛。
    /// ⚠️ 门本身要能红 —— 见 `nodeCheckRejectsBroken`，喂一段写坏的 TS 给它，必须报错。
    @MainActor
    static func runNodeSyntaxCheck(_ file: String) -> (found: Bool, ok: Bool, detail: String) {
        // ⚠️ 只做**解析**: `stripTypeScriptTypes` 剥类型时顺带解析, 语法错就抛; 它不执行文件。
        let script = """
        const { stripTypeScriptTypes } = require("node:module");
        const fs = require("node:fs");
        try {
          stripTypeScriptTypes(fs.readFileSync(process.argv[1], "utf8"));
        } catch (e) {
          console.error(String((e && e.message) || e));
          process.exit(1);
        }
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", "--experimental-strip-types", "-e", script, file]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do {
            try p.run()
        } catch {
            return (false, false, "起不来: \(error.localizedDescription)")
        }
        // 先读完再 wait：输出量很小, 但顺序反了在大输出上会卡死管道。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // `env` 找不到命令时退出码是 127 —— 那是"这台机器没有 node", 不是"源码有语法错"。
        if p.terminationStatus == 127 { return (false, false, "env 里找不到 node") }
        // ⚠️ 滤掉 node 自己的 `ExperimentalWarning` 那两行: 它每次都往 stderr 写, 混进来会让
        //    通过的那条断言也带一长串噪音, 久了就没人读了。
        let out = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("ExperimentalWarning")
                      && !$0.contains("trace-warnings") }
            .prefix(2)
            .joined(separator: " ⏎ ")
        return (true, p.terminationStatus == 0,
                "exit \(p.terminationStatus)" + (out.isEmpty ? "" : ": \(out)"))
    }

    /// **这支检查器是真会判错的吗** —— 拿一段故意写坏的 TS 喂给它，必须报错。
    ///
    /// ⚠️ 这条门就是为"门本身是假的"准备的。0.2.11 的教训：`node --check` 对含 `import`
    ///    的文件一律退 0，而所有断言（含"语法正确"那条）照样全绿 —— **判据的判据没人看**。
    ///    所以这里不只判"扩展能过"，还判"坏的过不去"。
    @MainActor
    static func nodeCheckRejectsBroken() -> (found: Bool, ok: Bool, detail: String) {
        let dir = fixtureDir("computer-ext-broken")
        let path = dir + "/broken.ts"
        let bad = """
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        const x = Type.String({ description: "a" })),
        export default x;
        """
        try? bad.write(toFile: path, atomically: true, encoding: .utf8)
        let r = runNodeSyntaxCheck(path)
        // `ok == false` 才是对的: 这段**必须**被拒。
        // ⚠️ 必须带上 `r.found`: node 根本没跑起来时 `r.ok` 也是 false, 光取反会**假绿**。
        return (r.found, r.found && !r.ok, r.detail)
    }
}
