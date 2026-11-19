//
//  CaseComputerKeys.swift
//  第六档（2026-11-19）：`computer_keys` 的九道闸 + 键名解析 + 分档 + 工具面/env 管道，
//  外加同批落的 `D0` 两条判据（自绘画布 vs 被截断的容器、外壳快照）。
//
//  ⚠️ 这一档与 `type` 的风险形状**又不一样**，重点也就不同：
//    · `tap` 怕点歪（看得见）；`type` 怕字进错地方再被回车发出去（看不见）；
//    · `keys` 怕的是**没有作用域** —— 一次 `⌘A` 选中的是全篇，后面跟一个删除键就没了。
//      2026-11-19 在 WPS 上真发生过：本来只想选中一段，结果清空了整篇正文。
//     ⇒ 所以这里最要紧的一条是 ⑨：**危险键在没有焦点证据时是拒，不是放行**，
//      而同一格里纯导航键必须放行（否则这一档唯一能做的事也做不了）。
//
//  ⚠️ **一条 check = 一个独立的失败模式**（同 `CaseComputerType` 的纪律）。
//    同一分支的多个输入合成一条，由文案点名漏的是哪一个；不同闸之间绝不合并。
//
//  ⚠️ 全部是纯函数 + 纯数据：不碰真键盘、不求授权、一个字都不发。真机那一路另有验收
//    （用 `keys` + `tap` 在 WPS 里重做一遍彩虹色），不进 CI。
//

import Foundation

extension SmokeMain {

    /// 一组合法输入。每条断言只翻一个字段 —— 红了就能直接指出是哪一道闸。
    private static func keysFacts() -> ComputerKeysRule.Facts {
        ComputerKeysRule.Facts(
            keysEnabled: true,
            appActable: true,
            appName: "WPS Office",
            snapshotPid: 4242,
            currentPid: 4242,
            isFrontmost: true,
            leftButtonDown: false,
            rightButtonDown: false,
            sinceHumanInputMs: 5_000,
            strokes: [ComputerKeyStroke(.right), ComputerKeyStroke(.right, [.shift])])
    }

    /// 危险档的一串（带 `command`，且含删除键）。
    private static var riskyStrokes: [ComputerKeyStroke] {
        [ComputerKeyStroke(.right, [.command]), ComputerKeyStroke(.delete)]
    }

    @MainActor
    static func caseComputerKeys() async {
        print("== T-KEYS 发导航键 / 组合键 (第六档 / 九道闸) ==")

        // MARK: ① 基准
        //  排最前: 基准本身若拒, 后面所有"应该拒"的断言都会**因为错误的原因**通过。
        check(ComputerKeysRule.refusal(keysFacts()) == nil,
              "T-KEYS 基准: 只按方向键、九道闸全过 ⇒ 放行")

        // MARK: ② 档位
        var f = keysFacts(); f.keysEnabled = false
        f.strokes = riskyStrokes          // 档位那一条必须排在"危险键"之前, 否则话术会指错方向
        let offWhy = ComputerKeysRule.refusal(f)
        check(offWhy?.contains("这一档关着") == true && offWhy?.contains("设置") == true,
              "T-KEYS 档关 ⇒ 拒并点名去设置页开, 且**先于**危险键那一条报 "
              + "(实际: \(offWhy ?? "放行了"))")

        // MARK: ③ 逐 App 授权
        f = keysFacts(); f.appActable = false
        let appWhy = ComputerKeysRule.refusal(f)
        check(appWhy?.contains("可操作") == true && appWhy?.contains("WPS Office") == true,
              "T-KEYS 没勾「可操作」⇒ 拒且点名哪个 App (看得到不等于动得)")

        // MARK: ④ 空的一串 / ⑤ 量（一个阈值两个点, 合成一条）
        f = keysFacts(); f.strokes = []
        let emptyWhy = ComputerKeysRule.refusal(f)
        f = keysFacts(); f.strokes = Array(repeating: ComputerKeyStroke(.right),
                                           count: ComputerKeysRule.maxStrokes)
        let atLimit = ComputerKeysRule.refusal(f)
        f.strokes = Array(repeating: ComputerKeyStroke(.right), count: ComputerKeysRule.maxStrokes + 1)
        let overWhy = ComputerKeysRule.refusal(f)
        check(emptyWhy?.contains("没给要按的键") == true,
              "T-KEYS 空的一串 ⇒ 拒（不是「发了个空请求」就回成功）")
        check(atLimit == nil && overWhy?.contains("\(ComputerKeysRule.maxStrokes)") == true,
              "T-KEYS 24 下放行 / 25 下拒且把上限写进话里 "
              + "(实际 24=\(atLimit ?? "放行"), 25=\(overWhy ?? "放行"))")

        // MARK: ⑥ 身份: 进程换过 ⇒ 焦点归谁不知道
        f = keysFacts(); f.currentPid = 9999
        let pidWhy = ComputerKeysRule.refusal(f)
        check(pidWhy?.contains("重启") == true && pidWhy?.contains("read") == true,
              "T-KEYS App 重启过 ⇒ 拒并指回 read")

        // MARK: ⑦ 前台 —— 键盘事件发给谁由系统决定
        f = keysFacts(); f.isFrontmost = false
        let frontWhy = ComputerKeysRule.refusal(f)
        check(frontWhy?.contains("前台") == true && frontWhy?.contains("computer_open") == true,
              "T-KEYS 不在前台 ⇒ 拒并给下一步 (键会落到**另一个 App** 的焦点里)")

        // MARK: ⑧ 手上按着鼠标键（左右同一个分支）
        var held: [String] = []
        for (label, isLeft) in [("左键", true), ("右键", false)] {
            f = keysFacts()
            if isLeft { f.leftButtonDown = true } else { f.rightButtonDown = true }
            if ComputerKeysRule.refusal(f) == nil { held.append(label) }
        }
        check(held.isEmpty, "T-KEYS 按着鼠标键 ⇒ 拒 (可能在拖拽 / 多选; 放过了: \(held))")

        // MARK: ⑨ 危险键必须有焦点证据 —— 这一档唯一的安全边界
        //  ⚠️ **同一格的两个方向**, 合成一条: 读不到焦点时
        //      · 危险键 ⇒ **拒**(没有证据就不动, 而这类键没有撤销);
        //      · 纯导航键 ⇒ **放行**(否则 WPS 那种答不出焦点的自绘 App 一步都走不了)。
        //     两个方向任一写反都能让这一档失效: 全拒 = 白开一个开关; 全放 = 等于没有这一条。
        f = keysFacts(); f.strokes = riskyStrokes; f.focusedRole = nil
        let noEvidence = ComputerKeysRule.refusal(f)
        f = keysFacts(); f.focusedRole = nil
        let navNoEvidence = ComputerKeysRule.refusal(f)
        check(noEvidence?.contains("答不出焦点") == true && navNoEvidence == nil,
              "T-KEYS 焦点读不到: 危险键拒 / 导航键放行 "
              + "(实际 危险=\(noEvidence ?? "放行"), 导航=\(navNoEvidence ?? "放行"))")

        // 焦点落在**非**可写控件上: 危险键拒且点名角色（在列表上按 ␣ / ⌫ 是别的动作, 不是编辑）
        f = keysFacts(); f.strokes = riskyStrokes; f.focusedRole = "AXOutline"
        let listWhy = ComputerKeysRule.refusal(f)
        check(listWhy?.contains("AXOutline") == true && listWhy?.contains("不是能写字的输入框") == true,
              "T-KEYS 焦点在列表上 + 危险键 ⇒ 拒且点名角色 (实际: \(listWhy ?? "放行了"))")

        // 焦点在真输入框上: 放行 —— 反过来若这里也拒, 这一档就只剩"选不了字"。
        var rejectedEditable: [String] = []
        for role in ["AXTextField", "AXTextArea"] {
            f = keysFacts(); f.strokes = riskyStrokes; f.focusedRole = role
            if ComputerKeysRule.refusal(f) != nil { rejectedEditable.append(role) }
        }
        check(rejectedEditable.isEmpty,
              "T-KEYS 焦点在输入框/文本区 + 危险键 ⇒ 放行 (误拒: \(rejectedEditable))")

        // MARK: ⑩ 人静阈值: 三个点一条线（100ms 拒 / 正好 400ms 放行 / 拿不到事实不判）
        f = keysFacts(); f.sinceHumanInputMs = 100
        let busyWhy = ComputerKeysRule.refusal(f)
        f = keysFacts(); f.sinceHumanInputMs = ComputerKeysRule.humanQuietMs
        let edge = ComputerKeysRule.refusal(f)
        f = keysFacts(); f.sinceHumanInputMs = nil
        let noFact = ComputerKeysRule.refusal(f)
        check(busyWhy?.contains("毫秒") == true && edge == nil && noFact == nil,
              "T-KEYS 人静阈值: 100ms 拒 / 卡在 400ms 放行 / 监听没装上不假装判过 "
              + "(实际 \(busyWhy ?? "放行") / \(edge ?? "放行") / \(noFact ?? "放行"))")

        // MARK: ⑪ 键名解析 —— 认不出必须是 nil, 不许"默认某个键"
        //  ⚠️ 三种"认不出"合成一条(字母数字 / 未知修饰键 / 空串): 它们同一个分支, 而漏哪一种
        //     都会变成"照着一个我没要的键按下去", 且回执说"按了"。字母那一格尤其要紧:
        //     收窄到不含字母, `⌘S` / `⌘Q` 这类组合才**结构上不存在**(不需要危险组合黑名单)。
        var unknownAccepted: [String] = []
        for raw in ["cmd+a", "hyper+right", "", "shift+", "right,"] {
            if ComputerKeyStroke.parse(raw) != nil { unknownAccepted.append("\"\(raw)\"") }
        }
        check(unknownAccepted.isEmpty,
              "T-KEYS 认不出的键名 ⇒ nil (字母数字 / 未知修饰 / 空串 / 悬空 +; 认成过: \(unknownAccepted))")

        // 显式标 `?`: 让"解析出 nil"与"解析出别的键"在断言里是两种能分清的失败。
        let parsed: ComputerKeyStroke? = ComputerKeyStroke.parse("Shift+Right")
        let cmdHome: ComputerKeyStroke? = ComputerKeyStroke.parse("command+home")
        check(parsed == ComputerKeyStroke(.right, [.shift])
              && cmdHome == ComputerKeyStroke(.home, [.command]),
              "T-KEYS 解析: 大小写不敏感、多修饰键前缀都对 "
              + "(实际 \(String(describing: parsed)) / \(String(describing: cmdHome)))")

        // 回执里那一串要按**固定顺序**重排(control→option→shift→command): 同一个请求两次
        // 记出来的字面量相同, 人比对日志时才不会以为按的是两回事。
        check(ComputerKeyStroke(.right, [.command, .shift]).display == "shift+command+right"
              && ComputerKeyStroke(.delete).display == "delete",
              "T-KEYS display 顺序固定、无修饰键时不带前缀")

        // MARK: ⑫ 分档 —— 这一档唯一的边界,"shift 不算危险"是最容易被顺手改掉的一格
        var misgraded: [String] = []
        for (raw, want) in [("right", ComputerKeyStroke.Safety.navigate),
                            ("shift+right", .navigate),
                            ("home", .navigate),
                            ("tab", .navigate),
                            ("esc", .navigate),
                            ("command+right", .destructive),
                            ("option+left", .destructive),
                            ("control+right", .destructive),
                            ("delete", .destructive),
                            ("backspace", .destructive),
                            ("enter", .destructive),
                            ("space", .destructive)] {
            guard let s = ComputerKeyStroke.parse(raw) else { misgraded.append(raw + "(解析失败)"); continue }
            if s.safety != want { misgraded.append("\(raw)→\(s.safety)") }
        }
        check(misgraded.isEmpty,
              "T-KEYS 分档: shift 组合只改选中范围 ⇒ 导航档; 其余修饰键与 删除/退格/回车/空格 ⇒ 危险档 "
              + "(分错的: \(misgraded))")

        // MARK: ⑬ 工具面同源（名字对不上, 模型根本看不到这个工具）
        //  ⚠️ 解码那一半只活在 helper 里, 冒烟编不到 ⇒ 由 `run.sh` 扫源码。
        check(PiRpcTransport.computerKeysToolName == "computer_keys"
              && PiRpcTransport.computerToolNames.contains("computer_keys")
              && PiRpcTransport.computerExtensionSource.contains("name: \"computer_keys\""),
              "T-KEYS 工具名三处同源 (Swift 常量 / computerToolNames / 内嵌 TS 声明)")

        // MARK: ⑭ env 键与作用域管道（它是**第六个**独立的一档）
        //  ⚠️ 与 `type` / `tap` 各是一个键: 合成一个等于让"允许打字"顺带授权了"全选 + 删除"。
        let sOff = ComputerHost.Scope(read: ["com.apple.Safari"], act: [], keys: false)
        let sOn = ComputerHost.Scope(read: ["com.apple.Safari"], act: [], keys: true)
        check(ComputerKeysRule.envKey == "MANGOX_COMPUTE_KEYS"
              && ComputerKeysRule.envKey != ComputerTypeRule.envKey
              && ComputerKeysRule.envKey != ComputerTapRule.envKey
              && sOff != sOn,
              "T-KEYS env 键与前两档分开, 且档位参与 Scope 比较 "
              + "(共用键 = 老值改义; 不进 Scope = 开了不生效, 而设置页是开着的)")

        // MARK: ⑮ 设置项: 缺省关 + 落库往返 + 反解只认自己
        let fresh = ComputerSettings()
        let legacy = ComputerSettings()
        legacy.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari")
        check(!fresh.keysEnabled && !legacy.keysEnabled,
              "T-KEYS 缺省关 (新建 / 老库缺键 都不许用 `?? true` 把权限偷偷带出来)")

        var written: [String: String] = [:]
        fresh.onPersist = { key, value in written[key] = value }
        fresh.keysEnabled = true
        let opened = written[ComputerSettings.keysKey]
        fresh.keysEnabled = false
        let closed = written[ComputerSettings.keysKey]
        fresh.onPersist = nil
        let restored = ComputerSettings()
        restored.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari", keysRaw: "1")
        check(opened == "1" && closed == "0" && restored.keysEnabled
              && !restored.typeEnabled && !restored.tapEnabled,
              "T-KEYS 落库恒写 \"1\"/\"0\", 反解只认它自己 (不许顺带打开 tap/type —— 三件事三个开关)")

        // MARK: ⑯ D0: 坐标落在**自绘画布**上, 不许再说"从快照里挑编号"
        //  ⚠️ 2026-11-19 WPS 实测: `CopyElementAtPosition` 在正文上回的是匿名 `AXGroup`,
        //     一分内容都没有。判成 `container` 时回执会说"重读一次就有编号" —— 对那块区域
        //     是**空话**(重读一百次也没有), 模型只会反复重读。
        let canvas = ComputerPointRule.missKind(role: "AXGroup", hasContentBelow: false)
        let truncated = ComputerPointRule.missKind(role: "AXGroup", hasContentBelow: true)
        let legacyDefault = ComputerPointRule.missKind(role: "AXGroup")
        check(canvas == .canvas && truncated == .container && legacyDefault == .container,
              "T-KEYS 容器角色: 子树里没内容 ⇒ canvas / 有内容 ⇒ container / 不传 ⇒ 保守判 container "
              + "(反向的代价是让模型放弃一条能走的路; 实际 \(canvas) / \(truncated) / \(legacyDefault))")

        // MARK: ⑰ D0: 重读到上限后仍低覆盖 ⇒ 如实说"这份快照只有外壳"
        //  ⚠️ 两个方向都要钉: 恒真会让每次读都多说一句"正文不在 AX 里"(假话),
        //     恒假会让 WPS 那种 1% 的树永远回到"再读一次"。
        let shellWindow = AXNode(role: "AXWindow", frame: AXRect(x: 0, y: 0, w: 1200, h: 800),
                                 children: [AXNode(role: "AXStaticText", title: "宋体",
                                                   frame: AXRect(x: 20, y: 20, w: 120, h: 20))])
        let fullWindow = AXNode(role: "AXWindow", frame: AXRect(x: 0, y: 0, w: 1200, h: 800),
                                children: [AXNode(role: "AXTextArea",
                                                  frame: AXRect(x: 0, y: 0, w: 1200, h: 700))])
        let tinyWindow = AXNode(role: "AXWindow", frame: AXRect(x: 0, y: 0, w: 150, h: 100),
                                children: [AXNode(role: "AXStaticText",
                                                  frame: AXRect(x: 0, y: 0, w: 20, h: 12))])
        check(AXSnapshot.looksShellOnly(root: shellWindow)
              && !AXSnapshot.looksShellOnly(root: fullWindow)
              && !AXSnapshot.looksShellOnly(root: tinyWindow),
              "T-KEYS 外壳判定: 只有工具栏的 1200×800 窗口 ⇒ 是; 正文铺满 ⇒ 不是; 小工具窗 ⇒ 不判")

        // MARK: ⑱ 内容角色的定义只有一份（`isContentRole` 是给动作面开的"问一句"）
        //  ⚠️ 开的是查询口而不是把表公开: 表是"窗口空不空"那条判据的定义, 改表等于改判据。
        check(AXSnapshot.isContentRole("AXStaticText")
              && AXSnapshot.isContentRole("axtextarea")
              && !AXSnapshot.isContentRole("AXButton")
              && !AXSnapshot.isContentRole("AXGroup"),
              "T-KEYS isContentRole 认大小写、且按钮/分组不算内容 (微信的树恰好是 window+group+红绿灯三键)")
    }
}
