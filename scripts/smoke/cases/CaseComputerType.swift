//
//  CaseComputerType.swift
//  第五档（2026-11-10）：`computer_type` 的九道闸 + 解码缺省 + env/Scope 管道。
//
//  ⚠️ 这一档与 `tap` 的风险形状**不一样**，所以判据的重点也不一样：
//    · `tap` 怕的是"坐标偏了"（点错位置，界面上看得见）；
//    · `type` 怕的是"字进错了地方、又被回车送出去"（看不见，且撤不回）。
//    所以这里最要紧的三条是: 前台 / 人没在打字 / **不许有换行**。前两条能反证,
//    第三条只能靠一条纯函数 —— 而它最容易在"顺手支持一下多行"的改动里被放开。
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
        print("== T-TYPE 往焦点里写字 (第五档 / 九道闸) ==")

        // MARK: ① 基准: 一切正常时要放行
        //  排最前, 因为它反证了后面每一条: 基准本身若拒, 所有"应该拒"的断言都会
        //  **因为错误的原因**通过(恒真的红), 那是最没用的判据。
        check(ComputerTypeRule.refusal(typeFacts()) == nil,
              "T-TYPE 基准: 九道闸全过 ⇒ 放行")

        // MARK: ② 档位
        var f = typeFacts(); f.typeEnabled = false
        check(ComputerTypeRule.refusal(f)?.contains("这一档关着") == true,
              "T-TYPE 全局档关着 ⇒ 拒, 并说清去哪开")
        check(ComputerTypeRule.refusal(f)?.contains("设置") == true,
              "T-TYPE 档关那句要点名去哪个页面开 (只说\"不行\"= 让人去猜)")

        // MARK: ③ 逐 App 授权
        f = typeFacts(); f.appActable = false
        check(ComputerTypeRule.refusal(f)?.contains("可操作") == true,
              "T-TYPE 这个 App 没勾「可操作」⇒ 拒 (全局档开着不等于谁都能写)")
        check(ComputerTypeRule.refusal(f)?.contains("微信") == true,
              "T-TYPE 拒的时候要点名是哪个 App")

        // MARK: ④ 空文本 = 两种不同的拒
        //  ⚠️ 这两条必须分开: "光按回车"不是打字, 它在不少 App 里就是"发送 / 确定" ——
        //     报成"没给要写的字"会让模型改写成空内容再试一次, 而它真正该做的是先写内容。
        f = typeFacts(); f.text = ""; f.submit = true
        check(ComputerTypeRule.refusal(f)?.contains("只给了回车") == true,
              "T-TYPE 空文本 + submit ⇒ 单独一条拒 (光按回车 ≠ 打字)")
        f = typeFacts(); f.text = ""; f.submit = false
        check(ComputerTypeRule.refusal(f)?.contains("没给要写的字") == true,
              "T-TYPE 空文本 ⇒ 拒, 且报的是\"没给字\"不是\"按了回车\"")
        f = typeFacts(); f.text = "   \n  "
        check(ComputerTypeRule.refusal(f) != nil,
              "T-TYPE 全是空白 ⇒ 也不写 (否则等于往输入框里塞空行)")

        // MARK: ⑤ 换行 —— 这一档最要紧的一条
        //  ⚠️ 微信 / Slack / iMessage 的默认设置都是"回车 = 发送" ⇒ 一段带 5 个换行的文本
        //     会变成 5 条消息, 而模型以为自己只写了一段字。
        f = typeFacts(); f.text = "第一行\n第二行"
        check(ComputerTypeRule.refusal(f)?.contains("换行") == true,
              "T-TYPE 文本里有 \\n ⇒ 拒 (回车在不少 App 里等于发送)")
        f = typeFacts(); f.text = "第一行\r\n第二行"
        check(ComputerTypeRule.refusal(f)?.contains("换行") == true,
              "T-TYPE \\r\\n 也要拒 (它在 Swift 里是**一个** Character, 按 == \"\\n\" 判会漏)")
        f = typeFacts(); f.text = "第一行\r第二行"
        check(ComputerTypeRule.refusal(f)?.contains("换行") == true,
              "T-TYPE 裸 \\r 同样拒 (老式换行, 一样会变成回车)")
        //  ⚠️ 行分隔符 U+2028/2029 不是 \n, 但在不少 App 里同样断行 ⇒ 一并拒。
        f = typeFacts(); f.text = "第一行\u{2028}第二行"
        check(ComputerTypeRule.refusal(f) != nil,
              "T-TYPE U+2028 行分隔符同样拒 (它不是 \\n, 只按字符比对会漏)")

        // MARK: ⑥ 控制字符
        f = typeFacts(); f.text = "abc\u{07}def"
        check(ComputerTypeRule.refusal(f)?.contains("控制字符") == true,
              "T-TYPE 控制字符 ⇒ 拒 (注入进去会变成什么, 取决于目标 App)")
        check(ComputerTypeRule.offendingCharacter("正常的中文 abc 123，。") == nil,
              "T-TYPE 正常文本不许被误伤 (中文 / 英文 / 全角标点都算干净)")

        // MARK: ⑦ 量: 边界卡 2000
        f = typeFacts(); f.text = String(repeating: "字", count: 2_000)
        check(ComputerTypeRule.refusal(f) == nil,
              "T-TYPE 正好 2000 字 ⇒ 放行 (上限是 2000, 不是 1999)")
        f = typeFacts(); f.text = String(repeating: "字", count: 2_001)
        check(ComputerTypeRule.refusal(f)?.contains("2000") == true,
              "T-TYPE 2001 字 ⇒ 拒, 并把上限写在话里 (否则模型只会再试一次)")

        // MARK: ⑧ 身份: 进程换过 = 焦点归谁不知道
        f = typeFacts(); f.currentPid = 9999
        check(ComputerTypeRule.refusal(f)?.contains("重启") == true,
              "T-TYPE App 重启过 ⇒ 拒 (焦点可能已经不在那个输入框里)")
        check(ComputerTypeRule.refusal(f)?.contains("read") == true,
              "T-TYPE 拒的时候要说下一步: 重新 read")

        // MARK: ⑨ 前台 —— 键盘事件发给谁由系统决定
        f = typeFacts(); f.isFrontmost = false
        check(ComputerTypeRule.refusal(f)?.contains("前台") == true,
              "T-TYPE 不在前台 ⇒ 拒 (键会落到**另一个 App** 的焦点里)")
        check(ComputerTypeRule.refusal(f)?.contains("computer_open") == true,
              "T-TYPE 要说清怎么把它弄到前台 (报'不行'而不给路 = 模型重试同一个动作)")

        // MARK: ⑩ 手上按着键 / 人刚动过
        f = typeFacts(); f.leftButtonDown = true
        check(ComputerTypeRule.refusal(f) != nil,
              "T-TYPE 左键按着 ⇒ 拒 (可能在拖拽, 那一下正好插进人家拖拽中间)")
        f = typeFacts(); f.rightButtonDown = true
        check(ComputerTypeRule.refusal(f) != nil, "T-TYPE 右键按着 ⇒ 拒")
        f = typeFacts(); f.sinceHumanInputMs = 100
        check(ComputerTypeRule.refusal(f)?.contains("毫秒") == true,
              "T-TYPE 人 100ms 前刚动过 ⇒ 拒 (人正在打字时不往他那行里插字)")
        f = typeFacts(); f.sinceHumanInputMs = ComputerTypeRule.humanQuietMs
        check(ComputerTypeRule.refusal(f) == nil,
              "T-TYPE 正好 400ms ⇒ 放行 (边界值, 卡在 `<` 上)")
        f = typeFacts(); f.sinceHumanInputMs = nil
        check(ComputerTypeRule.refusal(f) == nil,
              "T-TYPE 监听没装上(拿不到事实) ⇒ 不假装判过, 放行 (回执里另说'盲写')")

        // MARK: ⑪ 协议/工具面同源
        //  ⚠️ 解码那一半只活在 helper 里, 冒烟编不到 ⇒ 那边由 `run.sh` ③s 扫源码
        //     (含 `?? false` 那条: 缺省 true 就是"默认发送")。
        check(PiRpcTransport.computerTypeToolName == "computer_type",
              "T-TYPE 工具名是 computer_type (契约字面量, 扩展与 Swift 两侧同源)")
        check(PiRpcTransport.computerToolNames.contains("computer_type"),
              "T-TYPE 它进了 computerToolNames (漏了 = 审批卡认不出、Mounted 判据也不算它)")
        check(PiRpcTransport.computerExtensionSource.contains("name: \"computer_type\""),
              "T-TYPE 内嵌扩展里真有这个工具声明 (Swift 侧登记了、TS 侧没注册 = 模型根本看不到)")

        // MARK: ⑫ env 键与作用域管道
        //  ⚠️ 与 `tap` **必须是两个键**: 合成一个等于让"允许点一下"顺带授权了"打字 + 回车"。
        check(ComputerTypeRule.envKey == "MANGOX_COMPUTE_TYPE",
              "T-TYPE env 键是 MANGOX_COMPUTE_TYPE (两侧逐字相同, 编译不会报错)")
        check(ComputerTypeRule.envKey != ComputerTapRule.envKey,
              "T-TYPE 与 tap **不许共用一个键** (两件事两种后果, 共用键 = 老值静默改义)")
        let sOff = ComputerHost.Scope(read: ["com.apple.Safari"], act: [], type: false)
        let sOn = ComputerHost.Scope(read: ["com.apple.Safari"], act: [], type: true)
        check(sOff != sOn,
              "T-TYPE 档位变了 Scope 就不相等 ⇒ 会自动重启 helper (不重启 = 开了也不生效)")

        // MARK: ⑬ 设置项: 缺省关 / 恒写 "1"/"0" / 老库缺键 = 关
        let cs = ComputerSettings()
        check(!cs.typeEnabled, "T-TYPE 默认关 (打开它 = 允许往焦点里写字)")

        var written: [String: String] = [:]
        cs.onPersist = { key, value in written[key] = value }
        cs.typeEnabled = true
        check(written[ComputerSettings.typeKey] == "1",
              "T-TYPE 打开时落一个明确的 \"1\"")
        cs.typeEnabled = false
        check(written[ComputerSettings.typeKey] == "0",
              "T-TYPE 关掉时留明确的 \"0\" (不是删键 —— 否则看不出是谁关的)")
        cs.onPersist = nil

        let old = ComputerSettings()
        old.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari")
        check(!old.typeEnabled,
              "T-TYPE 老库没有这个键 ⇒ 关 (不许写成 `?? true` 把权限偷偷带出来)")
        let restored = ComputerSettings()
        restored.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari", typeRaw: "1")
        check(restored.typeEnabled, "T-TYPE 落盘串反解: \"1\" ⇒ 开")
        //  ⚠️ 两个档互不牵连: 开打字不许顺带把"按坐标点击"也打开。
        check(!restored.tapEnabled,
              "T-TYPE 只反解 type, 不许顺带打开 tap (两件事两个开关)")
    }
}
