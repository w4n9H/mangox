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
        check(!wideText.contains("[121]"),
              "T-COMPUTER 上限外的不许渲染出来 (上界是硬上界, 不是'大概')")

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
        check(d3.isEmpty && d3.rendered().contains("无"),
              "T-COMPUTER 没变化也要说出来 (\"界面没动\"本身是信息, 静默会让模型以为读失败了)")

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

        // MARK: 图像面(批 3c) —— 两把钥匙 + 一条硬禁区
        //
        // 图像是**读的第二种表示**: 它进不了动作面(像素里没有编号), 却是遮蔽机制唯一的
        // 绕过口(文本值被换成 `••••`, 像素里是原样)。所以下面每条都在守同一件事 ——
        // "默认一张都不拍; 拍了的那几个必须是用户逐个点过的"。

        // ① 两把钥匙缺一不可: 总开关开了只代表"允许读/操作", 图片要**额外**勾。
        //    ⚠️ 反例: 让 `activeImageBundles` 直接返回 `selected` ⇒ 这条立刻红。
        let ci = ComputerSettings()
        ci.enabled = true
        ci.setSelected(["com.apple.Safari"])
        check(ci.activeImageBundles.isEmpty,
              "T-COMPUTER 总开关开着但没勾图片 ⇒ 一张都不拍 (图片是独立的一把钥匙)")

        ci.setImage("com.apple.Safari", true)
        check(ci.activeImageBundles == ["com.apple.Safari"],
              "T-COMPUTER 勾了才下发图像面")
        check(ci.activeBundles == ["com.apple.Safari"],
              "T-COMPUTER 勾图片要连带勾上读面 (拍得了但读不到没有意义)")

        // ② 不变量 `图像 ⊆ 读`: 摘掉读面, 图片必须跟着消失。
        ci.toggle("com.apple.Safari")
        check(ci.activeImageBundles.isEmpty && ci.selected.isEmpty,
              "T-COMPUTER 取消可读必须连带摘掉图片 (否则设置页勾着、helper 却必拒, 人以为时好时坏)")

        // ③ 排序在**投影层**(`activeImageBundles`)做过一次, env 那层照原样拼 ——
        //    与 `allowedBundles` / `actBundles` 同待遇。`Set` 的迭代顺序不稳定且与插入序
        //    无关 ⇒ 不在投影层排, 同样的勾选每次会拼出不同的 env 串, "改了什么"看不出来。
        ci.setImage("com.z", true)
        ci.setImage("com.a", true)
        check(ci.activeImageBundles == ["com.a", "com.z"],
              "T-COMPUTER 图像面按字典序下发 (Set 迭代序不稳 ⇒ 不排序就没法 diff)")

        // ④ 硬禁区: 口令/系统类一个像素都不许拍。视图置灰之外还得有这一道 ——
        //    视图那层被改坏不会有任何红灯, 只会在真机上把密码拍成图。
        check(!ComputerSettings.canImage("com.1password.1password"),
              "T-COMPUTER 口令类恒不许截图 (文本遮蔽在像素里不成立)")
        ci.setImage("com.1password.1password", true)
        check(!ci.activeImageBundles.contains("com.1password.1password")
              && !ci.selected.contains("com.1password.1password"),
              "T-COMPUTER 硬禁区连勾都勾不上 (判据在状态层, 不靠视图禁用)")

        // ⑤ 两档互不牵连 —— "能看"与"能按"是两个开关, 互相带上是上一批特意避开的错。
        ci.setAct("com.apple.mail", true)
        ci.setImage("com.apple.mail", false)
        check(ci.activeActBundles == ["com.apple.mail"],
              "T-COMPUTER 关图片不许动操作面 (setImage 不碰 actSelected)")

        // ⑥ 落盘: 图片同样存**身份**且落在读面内; 空集写成空串。
        check(ComputerSettings.decode(enabledRaw: "1",
                                      bundlesRaw: "com.apple.Safari",
                                      imageRaw: "com.apple.Safari,com.apple.mail").imageBundles
                == ["com.apple.Safari"],
              "T-COMPUTER 反解时图片取与读面的交集 (手改过的库写成超集 ⇒ 剪掉)")
        check(ComputerSettings.encode(enabled: true,
                                      bundles: ["com.apple.mail", "com.apple.Safari"],
                                      imageBundles: ["com.apple.Safari"]).imageBundles
                == "com.apple.Safari",
              "T-COMPUTER 图片落盘串排序稳定")
        check(ComputerSettings.encode(enabled: true, bundles: ["x"]).imageBundles.isEmpty,
              "T-COMPUTER 没勾图片 ⇒ 落盘是**空串**而不是缺键 (缺键读不出'用户明确关了')")

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

        // MARK: 可勾选清单 = 已安装 ∪ 运行中 (2026-10-28 boss: 「浏览器怎么都没有」)

        let merged = ComputerSettings.merge(
            installed: [("com.apple.Safari", "Safari"), ("com.apple.mail", "Mail")],
            running: [ComputerTarget.Candidate(bundle: "com.apple.mail", name: "mail 进程名", pid: 11),
                      ComputerTarget.Candidate(bundle: "com.example.loose", name: "Loose", pid: 22)],
            keep: ["com.example.gone"])
        check(merged.contains { $0.bundle == "com.apple.Safari" && !$0.running },
              "T-COMPUTER 装了但没在跑也要在列表里 (只列运行中 ⇒ 没打开的 App 永远勾不到)")
        check(merged.contains { $0.bundle == "com.apple.mail" && $0.running && $0.name == "Mail" },
              "T-COMPUTER 在跑的打标记, 名字仍用 Info.plist 那个 (不是进程名)")
        check(merged.contains { $0.bundle == "com.example.loose" && $0.running },
              "T-COMPUTER 没扫到但正在跑的也要进来 (容器内 App / 临时挂载的 dmg)")
        check(merged.contains { $0.bundle == "com.example.gone" },
              "T-COMPUTER 已勾但已不在清单里的要补进来 (否则勾着看不见、也取消不掉)")
        check(merged.count == 4, "T-COMPUTER 同一个 bundle 只出现一次")
        let names = merged.map(\.name)
        check(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
              "T-COMPUTER 按名字排序 (按'运行中优先'排会让列表每隔几分钟整块重排)")

        // 扫已安装: 用夹具造两个假 .app —— 一个在根目录, 一个在厂商子目录里
        let appsRoot = fixtureDir("computer-apps")
        func makeApp(_ rel: String, bundle: String, name: String) {
            let dir = appsRoot + "/" + rel + "/Contents"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(bundle)</string>
            <key>CFBundleName</key><string>\(name)</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """
            try? plist.write(toFile: dir + "/Info.plist", atomically: true, encoding: .utf8)
        }
        makeApp("FakeOne.app", bundle: "com.example.fakeone", name: "FakeOne")
        makeApp("Vendor/FakeTwo.app", bundle: "com.example.faketwo", name: "FakeTwo")
        let scanned = ComputerSettings.scanInstalled(roots: [appsRoot])
        check(scanned.contains { $0.bundle == "com.example.fakeone" },
              "T-COMPUTER 根目录的 .app 要扫到 (读 Info.plist 的 CFBundleIdentifier)")
        check(scanned.contains { $0.bundle == "com.example.faketwo" },
              "T-COMPUTER 厂商子目录里的一层也要扫到 (/Applications/*/*.app —— 只扫一层会漏掉一整类 App)")
        check(scanned.count == 2, "T-COMPUTER 同一份夹具里不重复收录")
        check(ComputerSettings.appRoots(home: "/Users/x").contains("/Users/x/Applications"),
              "T-COMPUTER 用户目录下的 ~/Applications 也要扫")

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
    }
}
