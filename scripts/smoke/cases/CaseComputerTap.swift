//
//  CaseComputerTap.swift
//  纯视觉动手（第四档, 2026-11-10）：`computer_tap` 的十三道闸 + env/Scope 管道。
//
//  ⚠️ 这一档与前面几档**风险形状不同**: `press` 那道错的方向是"该拦的没拦"（点了一个
//    不该点的控件）; 这里的错还有一种更难发现的 —— **坐标偏了**。偏了的点击和正常的点击
//    长得一模一样: 回执成功、界面动了, 只是动的是隔壁那个东西。所以几何那几条闸(⑨~⑭)
//    必须正反都断言, 而且容差要**卡在边界上**测(2px 放行 / 3px 拒), 不然"容差被写成 20"
//    这种改动一条都不会红。
//
//  ⚠️ 文案只用 `contains` 断"报的是哪一条", 不比整串 —— 同 `CaseComputerAct` 的理由:
//    整串相等会把"改一句人话"变成红灯, 而那些话本来就要反复打磨。
//
//  ⚠️ 全部是纯函数: 不碰真屏幕、不要辅助功能授权、不点任何东西 —— 真机那一路另有
//    `scripts/diag/scenario_probe.sh` 那条链(要真人桌面), 不进 CI。
//

import Foundation

extension SmokeMain {

    /// 一组合法输入。每条断言只翻一个字段 —— 这样"红了"就能直接指出是哪一道闸。
    private static func tapFacts() -> ComputerTapRule.Facts {
        let frame = AXRect(x: 400, y: 100, w: 800, h: 600)
        return ComputerTapRule.Facts(
            tapEnabled: true,
            appActable: true,
            appName: "微信",
            snapshotPid: 4242,
            currentPid: 4242,
            isFrontmost: true,
            leftButtonDown: false,
            rightButtonDown: false,
            sinceHumanInputMs: 5_000,
            point: ComputerPoint(x: 500, y: 200),
            snapshotFrame: frame,
            currentFrame: frame,
            snapshotWindowNumber: 90,
            topWindowNumber: 90,
            topWindowPid: 4242,
            textUnderPoint: "会话列表")
    }

    @MainActor
    static func caseComputerTap() async {
        print("== T-TAP 纯视觉动手 (第四档 / 十三道闸) ==")

        // MARK: ① 基准: 一切正常时要放行
        //  这条排最前, 因为它反证了后面每一条: 若基准本身就拒, 那么所有"应该拒"的断言
        //  都会**因为错误的原因**而通过(恒真的红), 那是最没用的判据。
        check(ComputerTapRule.refusal(tapFacts()) == nil,
              "T-TAP 基准: 十三道闸全过 ⇒ 放行")

        // MARK: ② 档位
        var f = tapFacts(); f.tapEnabled = false
        check(ComputerTapRule.refusal(f)?.contains("这一档关着") == true,
              "T-TAP 全局档关着 ⇒ 拒, 并说清去哪开")
        check(ComputerTapRule.refusal(f)?.contains("设置") == true,
              "T-TAP 档关那句要点名去哪个页面开 (只说\"不行\"= 让人去猜)")

        // MARK: ③ 逐 App 授权
        f = tapFacts(); f.appActable = false
        check(ComputerTapRule.refusal(f)?.contains("可操作") == true,
              "T-TAP 这个 App 没勾「可操作」⇒ 拒 (全局档开着不等于谁都能点)")
        check(ComputerTapRule.refusal(f)?.contains("微信") == true,
              "T-TAP 拒的时候要点名是哪个 App")

        // MARK: ④ 身份: 进程换过 = 手上那份快照说的不是这个窗口
        f = tapFacts(); f.currentPid = 9999
        check(ComputerTapRule.refusal(f)?.contains("重启") == true,
              "T-TAP App 重启过 ⇒ 拒, 并要求重新 read")

        // MARK: ⑤ 前台
        f = tapFacts(); f.isFrontmost = false
        check(ComputerTapRule.refusal(f)?.contains("不在前台") == true,
              "T-TAP 不在前台 ⇒ 拒 (后台点不动, 而且会把它拽到前面)")
        check(ComputerTapRule.refusal(f)?.contains("computer_open") == true,
              "T-TAP 那句要给出下一步: 先把它切上来")

        // MARK: ⑥ 手上按着键 —— 拖拽时手是静止的, "人静"判据会放行, 所以必须单判
        f = tapFacts(); f.leftButtonDown = true
        check(ComputerTapRule.refusal(f)?.contains("按着鼠标键") == true,
              "T-TAP 左键按着 ⇒ 拒 (拖拽中间插一下会把人家的拖拽打断)")
        f = tapFacts(); f.rightButtonDown = true
        check(ComputerTapRule.refusal(f)?.contains("按着鼠标键") == true,
              "T-TAP 右键按着 ⇒ 也拒")

        // MARK: ⑦ 人刚动过 —— 边界卡在 humanQuietMs 上
        f = tapFacts(); f.sinceHumanInputMs = ComputerTapRule.humanQuietMs - 1
        check(ComputerTapRule.refusal(f)?.contains("毫秒前刚动过") == true,
              "T-TAP 人 \(ComputerTapRule.humanQuietMs - 1)ms 前动过 ⇒ 拒")
        f = tapFacts(); f.sinceHumanInputMs = ComputerTapRule.humanQuietMs
        check(ComputerTapRule.refusal(f) == nil,
              "T-TAP 刚好静了 \(ComputerTapRule.humanQuietMs)ms ⇒ 放行 (边界要能过, 否则等于把窗口定得比常量长)")
        // 监听没装上 ⇒ 拿不到事实 ⇒ **不假装判过**(同 `ComputerTakeover` 那条纪律)。
        f = tapFacts(); f.sinceHumanInputMs = nil
        check(ComputerTapRule.refusal(f) == nil,
              "T-TAP 接管监听没装上 ⇒ 这一条不判 (拿不到事实时不许假装判过); 回执里另行说清")

        // MARK: ⑧ 坐标本身
        f = tapFacts(); f.point = ComputerPoint(x: 99999, y: 200)
        check(ComputerTapRule.refusal(f)?.contains("不像屏幕上的点") == true,
              "T-TAP 坐标大得不像屏幕上的点 ⇒ 拒")

        // MARK: ⑨ 快照没记窗口几何 ⇒ 判不了坐标对着谁
        f = tapFacts(); f.snapshotFrame = nil
        check(ComputerTapRule.refusal(f)?.contains("没记窗口位置") == true,
              "T-TAP 快照没窗口几何 ⇒ 拒 (不许拿\"缺数据\"当\"没问题\")")

        // MARK: ⑩ 窗口挪没挪 —— 容差卡在 2px
        f = tapFacts(); f.currentFrame = AXRect(x: 403, y: 100, w: 800, h: 600)
        check(ComputerTapRule.refusal(f)?.contains("窗口挪过") == true,
              "T-TAP 窗口挪了 3px ⇒ 拒 (实测微信一小时挪了三次)")
        f = tapFacts(); f.currentFrame = AXRect(x: 402, y: 100, w: 800, h: 600)
        check(ComputerTapRule.refusal(f) == nil,
              "T-TAP 窗口偏 2px ⇒ 放行 (整数取整的正常抖动, 卡在这里才叫容差)")
        f = tapFacts(); f.currentFrame = nil
        check(ComputerTapRule.refusal(f)?.contains("读不到了") == true,
              "T-TAP 此刻读不到窗口 ⇒ 拒, 而且要说\"读不到了\"而不是编一个坐标")

        // MARK: ⑪ 点在不在窗口里 —— 右下边界**不含**
        f = tapFacts(); f.point = ComputerPoint(x: 400, y: 100)
        check(ComputerTapRule.refusal(f) == nil, "T-TAP 点正好在窗口左上角 ⇒ 放行 (边界算在里面)")
        f = tapFacts(); f.point = ComputerPoint(x: 1200, y: 200)
        check(ComputerTapRule.refusal(f)?.contains("不在「微信」的窗口") == true,
              "T-TAP 点 = 窗口右边那一列(x+w) ⇒ 拒 (右边界属于隔壁)")
        f = tapFacts(); f.point = ComputerPoint(x: 399, y: 200)
        check(ComputerTapRule.refusal(f)?.contains("不在「微信」的窗口") == true,
              "T-TAP 点在窗口左边 1px ⇒ 拒")

        // MARK: ⑫ 这一点上最顶层的是谁
        f = tapFacts(); f.topWindowPid = 777
        check(ComputerTapRule.refusal(f)?.contains("别的 App") == true,
              "T-TAP 这一点上盖着别的 App 的窗口 ⇒ 拒 (坐标是全局的, 很容易点到别人家)")
        f = tapFacts(); f.topWindowNumber = 91
        check(ComputerTapRule.refusal(f)?.contains("弹层") == true,
              "T-TAP 同 App 的另一个窗口盖在上面(弹层) ⇒ 拒 (同 pid 同 owner, 只比进程会放行)")
        f = tapFacts(); f.snapshotWindowNumber = 0
        check(ComputerTapRule.refusal(f) == nil,
              "T-TAP 读的时候没认出窗口号 ⇒ 这一条退化成只比 frame, 如实少判一道(不假装判过)")
        f = tapFacts(); f.topWindowPid = -1
        check(ComputerTapRule.refusal(f)?.contains("别的 App") == true,
              "T-TAP 这一点上没有任何窗口(-1) ⇒ 也拒 (不是放行)")

        // MARK: ⑬ 底下写着什么 —— 与 press 的两条恒拒**同源**
        f = tapFacts(); f.textUnderPoint = "立即付款"
        check(ComputerTapRule.refusal(f)?.contains("付款") == true,
              "T-TAP 底下写着「付款」⇒ 拒")
        f = tapFacts(); f.textUnderPoint = "彻底删除这条"
        check(ComputerTapRule.refusal(f)?.contains("彻底删除") == true,
              "T-TAP 底下写着「彻底删除」⇒ 拒, 而且回执要点名**命中的那个词**"
              + " (笼统说\"命中关键词\"等于让人自己猜是哪四个字)")
        f = tapFacts(); f.textUnderPoint = ""
        check(ComputerTapRule.refusal(f) == nil,
              "T-TAP 底下读不到任何字 ⇒ 这一条不判 (空串不是\"命中\", 而回执会如实说看不出来)")
        check(ComputerTapRule.taintedWords == ComputerRedline.paymentWords
                + ComputerRedline.permanentDeleteWords,
              "T-TAP 词表与 press 的两条恒拒**同源** (另抄一份就会漂: 同一个动作换个入口就不做了)")
        check(!ComputerTapRule.taintedWords.contains("发送"),
              "T-TAP 词表里没有裸的「发送」 (press 也不拦它; 加进来 tap 就比 press 严, 而微信正靠它发消息)")
        check(!ComputerTapRule.taintedWords.contains("删除"),
              "T-TAP 词表里没有裸的「删除」 (press 放行它 —— \"移到废纸篓\"必须能点)")

        // MARK: ⑭ 每条拒都要**说自己的话**
        //  ⑥ 条判据合成一句"条件不满足"是本档最省事的写法, 也是最坏的一种: 人猜不出该改哪。
        var messages: Set<String> = []
        for mutate in [
            { (f: inout ComputerTapRule.Facts) in f.tapEnabled = false },
            { (f: inout ComputerTapRule.Facts) in f.appActable = false },
            { (f: inout ComputerTapRule.Facts) in f.currentPid = 1 },
            { (f: inout ComputerTapRule.Facts) in f.isFrontmost = false },
            { (f: inout ComputerTapRule.Facts) in f.leftButtonDown = true },
            { (f: inout ComputerTapRule.Facts) in f.sinceHumanInputMs = 1 },
            { (f: inout ComputerTapRule.Facts) in f.point = ComputerPoint(x: 99999, y: 0) },
            { (f: inout ComputerTapRule.Facts) in f.snapshotFrame = nil },
            { (f: inout ComputerTapRule.Facts) in f.currentFrame = AXRect(x: 0, y: 0, w: 1, h: 1) },
            { (f: inout ComputerTapRule.Facts) in f.point = ComputerPoint(x: 1500, y: 900) },
            { (f: inout ComputerTapRule.Facts) in f.topWindowPid = 5 },
            { (f: inout ComputerTapRule.Facts) in f.topWindowNumber = 5 },
            { (f: inout ComputerTapRule.Facts) in f.textUnderPoint = "下单" },
        ] {
            var one = tapFacts()
            mutate(&one)
            if let m = ComputerTapRule.refusal(one) { messages.insert(m) }
        }
        check(messages.count == 13,
              "T-TAP 十三道闸各有各的话 (实测 \(messages.count) 种) —— 合成一句等于让人猜该改哪个条件")

        // MARK: ⑮ 纯函数自身: 容差与包含
        let a = AXRect(x: 0, y: 0, w: 10, h: 10)
        check(ComputerTapRule.sameFrame(a, AXRect(x: 2, y: 2, w: 12, h: 12)),
              "T-TAP sameFrame: 四个边都差 2 ⇒ 算同一个位置")
        check(!ComputerTapRule.sameFrame(a, AXRect(x: 3, y: 0, w: 10, h: 10)),
              "T-TAP sameFrame: 差 3 ⇒ 不算 (容差被改成 20 这条不红就等于没有)")
        check(!ComputerTapRule.sameFrame(nil, a),
              "T-TAP sameFrame: 缺一边 ⇒ 不算同一个 (不拿 nil 当通配)")
        check(ComputerTapRule.contains(a, ComputerPoint(x: 9.9, y: 9.9)),
              "T-TAP contains: 右下角内侧 ⇒ 在")
        check(!ComputerTapRule.contains(a, ComputerPoint(x: 10, y: 5)),
              "T-TAP contains: x = x+w ⇒ 不在")

        // MARK: ⑯ 管道: 开关必须进 env, 而且必须进 Scope 的比较
        //  后半条是**那次真踩过的坑**的判据: helper 只在启动时读 env, 所以"改了开关但不重启"
        //  等于没改 —— 而设置页是开着的, 回执却说"这一档关着"。
        let e = ComputerHost.environment(existing: nil, socketPath: "/tmp/x.sock",
                                         allowedBundles: ["com.tencent.xinWeChat"],
                                         actBundles: ["com.tencent.xinWeChat"],
                                         imageBundles: ["com.tencent.xinWeChat"],
                                         takeover: false, tap: true,
                                         peerPid: 1, inherited: [:])
        check(e?[ComputerTapRule.envKey] == "1",
              "T-TAP 开了档 ⇒ env 里写 \"1\" (helper 只认这一个值)")
        let e2 = ComputerHost.environment(existing: nil, socketPath: "/tmp/x.sock",
                                          allowedBundles: ["com.tencent.xinWeChat"],
                                          tap: false, peerPid: 1, inherited: [:])
        check(e2?[ComputerTapRule.envKey] == nil,
              "T-TAP 关着 ⇒ 这个键**整个删掉** (留着会让下次排查看到一条假线索: 像是开过的)")
        let e3 = ComputerHost.environment(existing: nil, socketPath: nil,
                                          allowedBundles: [], tap: true,
                                          peerPid: 1, inherited: [ComputerTapRule.envKey: "1"])
        check(e3 == nil || e3?[ComputerTapRule.envKey] == nil,
              "T-TAP 没有 socket(不挂扩展) ⇒ 连这个键一起清掉")
        check(ComputerHost.Scope(read: ["x"], act: [], tap: true)
                != ComputerHost.Scope(read: ["x"], act: [], tap: false),
              "T-TAP 开关变了 ⇒ Scope 必须跟着变 (否则助手不会重启, 还在按旧档位办)")
        check(ComputerHost.Scope(read: ["x"], act: [], tap: true)
                == ComputerHost.Scope(read: ["x"], act: [], tap: true),
              "T-TAP Scope 相等性不能恒真 (上面那条的反例方向)")

        // MARK: ⑰ tap 是一个**独立 op**, 不是 act 的一个分支
        //  并进 act 就等于给那九条判据开"有时候没有元素"的第二语义 —— 判据的输入一变,
        //  它就不再是同一条判据了。
        //
        //  ⚠️ `ComputerProtocol.swift` 只编进 helper, 冒烟连不上它 ⇒ 协议那一半(能不能解码、
        //     缺坐标解成 nil)只能**扫源码**, 放 `run.sh` ③s 里。这里能跑的只有 App 侧这一条:
        //     tap 不许是 `ComputerAction` 的 case —— 让模型以为 "act op=tap" 能通, 它就会
        //     按编号那套去理解坐标, 然后被「没有 #n」拒掉, 而真实原因与编号无关。
        check(ComputerAction(rawValue: "tap") == nil,
              "T-TAP tap 不是 ComputerAction 的子动作 (act 那九条判据的输入是元素, 这一档没有元素)")
        check(ComputerAction(rawValue: "press") != nil,
              "T-TAP 上面那条不能恒真 (同一个构造对真子动作必须认得出来)")

        // MARK: ⑱ 工具面: 名字进了表, 而且扩展源码里真有它
        //  `computerToolNames` 与内嵌 TS 是**两处同源**: 只改一边 ⇒ 模型看得到的工具和
        //  桥里认的工具对不上, 症状是卡上退成 OTHER 且 `app` 从卡上消失(零红灯)。
        check(PiRpcTransport.computerToolNames.contains(PiRpcTransport.computerTapToolName),
              "T-TAP computer_tap 在工具名表里")
        check(PiRpcTransport.computerExtensionSource.contains("name: \"computer_tap\""),
              "T-TAP 扩展源码里真的有这个工具 (表里有、源码里没有 = 模型永远看不到)")
    }
}
