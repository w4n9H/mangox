//
//  CaseComputerType.swift
//  第五档（2026-11-10；2026-11-11 补第十道闸）：`computer_type` 的十道闸 + 解码缺省 + env/Scope 管道。
//
//  ⚠️ 这一档与 `tap` 的风险形状**不一样**，所以判据的重点也不一样：
//    · `tap` 怕的是"坐标偏了"（点错位置，界面上看得见）；
//    · `type` 怕的是"字进错了地方、又被回车送出去"（看不见，且撤不回）。
//    所以这里最要紧的三条是: 前台 / 人没在打字 / **不许有换行**。前两条能反证,
//    第三条只能靠一条纯函数 —— 而它最容易在"顺手支持一下多行"的改动里被放开。
//
//  ⚠️ **一条 check = 一个独立的失败模式**（2026-11-11 boss：「加了几十个，太多了，减少，
//     只要必须的」）。所以：
//       · 同一个分支的多个输入（`\n` / `\r\n` / `\r`，左键 / 右键，三种"该放行"的焦点）
//         合成**一条**，由 check 的文案点名漏的是哪一个 —— 条数是虚的，**红了能不能定位**才是实的；
//       · **不同闸之间绝不合并**：合了之后一条红说不清是哪道闸坏了，那种红等于没红。
//    原来这一节 44 条，合并后 **19** 条，判据的能力一条没少。
//
//  ⚠️ 文案只用 `contains` 断"报的是哪一条", 不比整串(同 `CaseComputerTap` 的理由)。
//
//  ⚠️ 全部是纯函数: 不碰真键盘、不求辅助功能授权、一个字都不发 —— 真机那一路另有
//    `scripts/diag/scenario_probe.sh` 那条链(要真人桌面), 不进 CI。
//

import Foundation

extension SmokeMain {

    /// 一组合法输入。每条断言只翻一个字段 —— 红了就能直接指出是哪一道闸。
    private static func typeFacts() -> ComputerTypeRule.Facts {
        ComputerTypeRule.Facts(
            typeEnabled: true,
            appActable: true,
            appName: "微信",
            snapshotPid: 4242,
            currentPid: 4242,
            isFrontmost: true,
            leftButtonDown: false,
            rightButtonDown: false,
            sinceHumanInputMs: 5_000,
            text: "大家好，我是mangox",
            submit: false)
    }

    @MainActor
    static func caseComputerType() async {
        print("== T-TYPE 往焦点里写字 (第五档 / 十道闸) ==")

        // MARK: ① 基准: 一切正常时要放行
        //  排最前, 因为它反证了后面每一条: 基准本身若拒, 所有"应该拒"的断言都会
        //  **因为错误的原因**通过(恒真的红), 那是最没用的判据。
        check(ComputerTypeRule.refusal(typeFacts()) == nil,
              "T-TYPE 基准: 十道闸全过 ⇒ 放行")

        // MARK: ② 档位
        //  拒 + 指路合成一条: 它们是同一句话的两半, 只报"不行"而不给路, 模型只会重试。
        var f = typeFacts(); f.typeEnabled = false
        let offWhy = ComputerTypeRule.refusal(f)
        check(offWhy?.contains("这一档关着") == true && offWhy?.contains("设置") == true,
              "T-TYPE 档关 ⇒ 拒并点名去设置页开 (实际: \(offWhy ?? "放行了"))")

        // MARK: ③ 逐 App 授权
        f = typeFacts(); f.appActable = false
        let appWhy = ComputerTypeRule.refusal(f)
        check(appWhy?.contains("可操作") == true && appWhy?.contains("微信") == true,
              "T-TYPE 没勾「可操作」⇒ 拒且点名哪个 App (全局档开着不等于谁都能写)")

        // MARK: ④ 空文本 = 两种不同的拒
        //  ⚠️ 必须分开: "光按回车"不是打字, 它在不少 App 里就是"发送 / 确定" ——
        //     报成"没给要写的字"会让模型改写成空内容再试一次, 而它该做的是先写内容。
        f = typeFacts(); f.text = ""; f.submit = true
        let enterWhy = ComputerTypeRule.refusal(f)
        f = typeFacts(); f.text = ""; f.submit = false
        let emptyWhy = ComputerTypeRule.refusal(f)
        f = typeFacts(); f.text = "   \n  "          // 全空白: trim 之后与空串同一条路
        let blankWhy = ComputerTypeRule.refusal(f)
        check(enterWhy?.contains("只给了回车") == true,
              "T-TYPE 空文本 + submit ⇒ 单独一条拒 (光按回车 ≠ 打字)")
        check(emptyWhy?.contains("没给要写的字") == true
              && blankWhy?.contains("没给要写的字") == true,
              "T-TYPE 空文本 / 全空白 ⇒ 都按\"没给字\"拒, 不是按\"按了回车\"")

        // MARK: ⑤ 换行 —— 这一档最要紧的一条
        //  ⚠️ 三种写法**同一个分支**, 合成一条; 但漏了哪一种要能从文案里看出来。
        //     `\r\n` 是 Swift 里**一个** Character ⇒ 按 `== "\n"` 判会漏, 所以它必须在这组里。
        var leaked: [String] = []
        for (label, body) in [("\\n", "第一行\n第二行"),
                              ("\\r\\n", "第一行\r\n第二行"),
                              ("\\r", "第一行\r第二行")] {
            f = typeFacts(); f.text = body
            if ComputerTypeRule.refusal(f)?.contains("换行") != true { leaked.append(label) }
        }
        check(leaked.isEmpty,
              "T-TYPE 三种换行都拒且报「换行」(回车在不少 App 里等于发送; 漏了: \(leaked))")

        // MARK: ⑥ 控制字符（含行分隔符）—— 与换行是**两个分支**, 不合并
        //  ⚠️ U+2028/2029 不是 `\n`, 但同样会断行; 它们走的是"不认识的控制字符"那条。
        var loose: [String] = []
        for (label, body) in [("U+0007", "abc\u{07}def"),
                              ("U+2028", "第一行\u{2028}第二行")] {
            f = typeFacts(); f.text = body
            if ComputerTypeRule.refusal(f)?.contains("控制字符") != true { loose.append(label) }
        }
        check(loose.isEmpty,
              "T-TYPE 控制字符与行分隔符 ⇒ 拒且报「控制字符」(注入进去会变成什么取决于目标 App; 漏了: \(loose))")

        // MARK: ⑦ 量: 边界卡 2000（一个阈值两个点, 合成一条）
        f = typeFacts(); f.text = String(repeating: "字", count: 2_000)
        let atLimit = ComputerTypeRule.refusal(f)
        f.text = String(repeating: "字", count: 2_001)
        let overLimit = ComputerTypeRule.refusal(f)
        check(atLimit == nil && overLimit?.contains("2000") == true,
              "T-TYPE 2000 放行 / 2001 拒且把上限写进话里 "
              + "(实际 2000=\(atLimit ?? "放行"), 2001=\(overLimit ?? "放行"))")

        // MARK: ⑧ 身份: 进程换过 = 焦点归谁不知道
        f = typeFacts(); f.currentPid = 9999
        let pidWhy = ComputerTypeRule.refusal(f)
        check(pidWhy?.contains("重启") == true && pidWhy?.contains("read") == true,
              "T-TYPE App 重启过 ⇒ 拒并指回 read (焦点可能已经不在那个输入框里)")

        // MARK: ⑨ 前台 —— 键盘事件发给谁由系统决定
        f = typeFacts(); f.isFrontmost = false
        let frontWhy = ComputerTypeRule.refusal(f)
        check(frontWhy?.contains("前台") == true && frontWhy?.contains("computer_open") == true,
              "T-TYPE 不在前台 ⇒ 拒并给下一步 (键会落到**另一个 App** 的焦点里)")

        // MARK: ⑩ 手上按着键（左右是同一个分支）
        var held: [String] = []
        for (label, isLeft) in [("左键", true), ("右键", false)] {
            f = typeFacts()
            if isLeft { f.leftButtonDown = true } else { f.rightButtonDown = true }
            if ComputerTypeRule.refusal(f) == nil { held.append(label) }
        }
        check(held.isEmpty, "T-TYPE 按着鼠标键 ⇒ 拒 (可能在拖拽, 那一下正好插进去; 放过了: \(held))")

        // MARK: ⑪ 人静阈值: 三个点一条线（100ms 拒 / 400ms 放行 / 拿不到事实不判）
        f = typeFacts(); f.sinceHumanInputMs = 100
        let busyWhy = ComputerTypeRule.refusal(f)
        f = typeFacts(); f.sinceHumanInputMs = ComputerTypeRule.humanQuietMs
        let edge = ComputerTypeRule.refusal(f)
        f = typeFacts(); f.sinceHumanInputMs = nil
        let noFact = ComputerTypeRule.refusal(f)
        check(busyWhy?.contains("毫秒") == true && edge == nil && noFact == nil,
              "T-TYPE 人静阈值: 100ms 拒 / 正好 400ms 放行(卡在 `<`) / 监听没装上不假装判过 "
              + "(实际 \(busyWhy ?? "放行") / \(edge ?? "放行") / \(noFact ?? "放行"))")

        // MARK: ⑫ 工具面同源（三处是同一个事实: 名字对不上, 模型根本看不到这个工具）
        //  ⚠️ 解码那一半只活在 helper 里, 冒烟编不到 ⇒ 由 `run.sh` 扫源码(含 `?? false`)。
        check(PiRpcTransport.computerTypeToolName == "computer_type"
              && PiRpcTransport.computerToolNames.contains("computer_type")
              && PiRpcTransport.computerExtensionSource.contains("name: \"computer_type\""),
              "T-TYPE 工具名三处同源 (Swift 常量 / computerToolNames / 内嵌 TS 声明)")

        // MARK: ⑬ env 键与作用域管道（同一个事实: 它是独立的一档）
        //  ⚠️ 与 `tap` **必须是两个键**: 合成一个等于让"允许点一下"顺带授权了"打字 + 回车"。
        let sOff = ComputerHost.Scope(read: ["com.apple.Safari"], act: [], type: false)
        let sOn = ComputerHost.Scope(read: ["com.apple.Safari"], act: [], type: true)
        check(ComputerTypeRule.envKey == "MANGOX_COMPUTE_TYPE"
              && ComputerTypeRule.envKey != ComputerTapRule.envKey
              && sOff != sOn,
              "T-TYPE env 键与 tap 分开, 且档位参与 Scope 比较 "
              + "(共用键 = 老值改义; 不进 Scope = 开了不生效, 而设置页是开着的)")

        // MARK: ⑭ 设置项: 缺省关 + 落库往返
        let fresh = ComputerSettings()
        let legacy = ComputerSettings()
        legacy.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari")
        check(!fresh.typeEnabled && !legacy.typeEnabled,
              "T-TYPE 缺省关 (新建 / 老库缺键 都不许用 `?? true` 把权限偷偷带出来)")

        var written: [String: String] = [:]
        fresh.onPersist = { key, value in written[key] = value }
        fresh.typeEnabled = true
        let opened = written[ComputerSettings.typeKey]
        fresh.typeEnabled = false
        let closed = written[ComputerSettings.typeKey]
        fresh.onPersist = nil
        let restored = ComputerSettings()
        restored.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari", typeRaw: "1")
        check(opened == "1" && closed == "0" && restored.typeEnabled && !restored.tapEnabled,
              "T-TYPE 落库恒写 \"1\"/\"0\", 反解只认它自己 (不许顺带打开 tap —— 两件事两个开关)")

        // MARK: ⑮ 焦点落在什么控件上 —— 第十道闸 (2026-11-11 代码评审补的)
        //  ⚠️ 这条闸的**形状**与前九道不同: 读得到才判, 读不到(微信那种 AX 恒空) **放行**。
        //     所以"该放行"的三个点合成一条 —— 它们同一个分支, 而其中"读不到"这一格
        //     一旦被改成拒, 这一档唯一的真实用例就整个关死, 且一条红灯都不会有。
        var rejected: [String] = []
        for role in ["AXTextField", "AXTextArea", "AXWebArea"] {
            f = typeFacts(); f.focusedRole = role
            if ComputerTypeRule.refusal(f) != nil { rejected.append(role) }
        }
        f = typeFacts(); f.focusedRole = nil
        let unknownFocus = ComputerTypeRule.refusal(f)
        check(rejected.isEmpty && unknownFocus == nil,
              "T-TYPE 输入框 / 网页 / **读不到焦点** 都放行 "
              + "(读不到就拒 = 关死微信那条唯一的路; 误拒: \(rejected) 读不到=\(unknownFocus ?? "放行"))")

        f = typeFacts(); f.focusedRole = "AXOutline"
        let listWhy = ComputerTypeRule.refusal(f)
        check(listWhy?.contains("不是能写字的输入框") == true && listWhy?.contains("AXOutline") == true,
              "T-TYPE 焦点在列表上 ⇒ 拒且点名角色 "
              + "(往那儿敲字符是「按键跳转」, 那是动作不是打字; 实际: \(listWhy ?? "放行了"))")

        //  ⚠️ 顺序即代价序: 不在前台时"焦点是谁"没有意义, 必须先报前台那一条。
        f = typeFacts(); f.isFrontmost = false; f.focusedRole = "AXOutline"
        check(ComputerTypeRule.refusal(f)?.contains("不在前台") == true,
              "T-TYPE 前台要先于焦点报 (反了会让人去点输入框, 而真正的问题是它不在前面)")
    }
}
