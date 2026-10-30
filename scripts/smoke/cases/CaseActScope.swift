//
//  CaseActScope.swift
//  P18 批 2d: **作用域那个勾就是授权** —— `computer_act` 的审批判据。
//
//  为什么要这一组: 这条能力两种坏法都是**静默**的。
//    · 勾了却仍然弹卡 ⇒ 一次 GUI 任务十几张卡, 连点十几次「允许」之后只剩麻木(保护 = 0);
//    · 没勾却放行     ⇒ 那是**安全面**: 模型动了一个你从没允许过的 App。
//  所以两边都测, 外加"算不出是哪个 App 时客户端不表态"。
//
//  ⚠️ 判据查的是**下发给 helper 的那份投影**(`activeActBundles`), 不是勾选框原始状态。
//    ④ 那一组专门造这个分叉(手改过的库让口令类留在勾选集里) —— 查原始状态就会放行它。
//
//  ⚠️ 另一条结构断言在 ②: `computer_act` **必须仍然进审批桥**。autoJudge 的"远程驱动档
//    一律拒"只活在那条桥上; 谁把它挪进只读白名单, 那条安全承诺就静默消失(零红灯)。
//
//  ⚠️ ④ 那组管 `computer_open`: 它查的是**读面**(`activeBundles`), 不是操作面 —— 打开一个
//    App 等于替用户点一下图标, 不动 App 里的任何东西。查错面有两种坏法: 查操作面 ⇒ 只勾了
//    「可读」的 App 连打开都被拒; 干脆不进桥 ⇒ 远程驱动档管不住它。
//
//  ⚠️ 全组自带还原: `ComputerSettings.shared` 是全局单例, 作用域不还原会把"某个 App 可操作"
//    带给同一进程里后面跑的用例。
//
//  ⚠️ ⑤ 那组管**候选表**与 `computer_open` 的三条分支。它的由来是 2026-10-29 一次真实失败:
//    helper 用 `NSWorkspace.shared.runningApplications` 取"谁在跑", 那个 API 在没有 run loop
//    的进程里会定格在首次查询那一刻 ⇒ 计算器随后起来了, 回执一路说"它们现在都没在运行"。
//    所以"取"必须现问系统(`NSRunningApplication.runningApplications(withBundleIdentifier:)`),
//    "判"留在 `ComputerTarget` 里 —— 这两件事分开之后, 这三档才有了可断言的落点。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseActScope() async {
        print("== T-ACTSCOPE computer_act: 作用域即授权 (勾了放行 / 没勾拒并提示 / 算不出交 helper) ==")

        let act = PiRpcTransport.computerActToolName
        let open = PiRpcTransport.computerOpenToolName
        let settings = ComputerSettings.shared
        let oldOverride = settings.candidateOverride
        let oldEnabled = settings.enabled
        let oldSelected = settings.selected
        let oldAct = settings.actSelected
        defer {
            settings.candidateOverride = oldOverride
            settings.restore(enabledRaw: oldEnabled ? "1" : "0",
                             bundlesRaw: oldSelected.sorted().joined(separator: ","),
                             actRaw: oldAct.sorted().joined(separator: ","))
        }

        let candidates: [ComputerTarget.Candidate] = [
            ComputerTarget.Candidate(bundle: "com.apple.Safari", name: "Safari", pid: 1),
            ComputerTarget.Candidate(bundle: "com.apple.SafariTechnologyPreview",
                                     name: "Safari Technology Preview", pid: 2),
            ComputerTarget.Candidate(bundle: "com.apple.mail", name: "Mail", pid: 3),
            ComputerTarget.Candidate(bundle: "com.apple.MailMate", name: "MailMate", pid: 4),
            ComputerTarget.Candidate(bundle: "com.1password.1password", name: "1Password", pid: 5),
            // 中文机器上系统 App 的**显示名**是中文, 而模型手里最稳的名字是英文(见 ①d 那组)。
            ComputerTarget.Candidate(bundle: "com.apple.calculator", name: "计算器", pid: 6),
        ]
        settings.candidateOverride = candidates

        // MARK: ① 认 App (复用作用域那把尺子 `ComputerTarget.pick`)

        check(settings.resolveBundle(query: "com.apple.Safari") == "com.apple.Safari",
              "T-ACTSCOPE 模型给 bundle id ⇒ 精确命中")
        check(settings.resolveBundle(query: "safari") == "com.apple.Safari",
              "T-ACTSCOPE 模型给名字(大小写无关) ⇒ 命中 Safari, 不落到 Technology Preview")
        check(settings.resolveBundle(query: "Mail") == "com.apple.mail",
              "T-ACTSCOPE 精确名字优先于「名字包含」 ⇒ Mail 不撞 MailMate")
        check(settings.resolveBundle(query: "   ") == nil,
              "T-ACTSCOPE 空 query ⇒ nil(**当前前台**那一刻答不了, 不许猜)")
        check(settings.resolveBundle(query: "微信") == nil,
              "T-ACTSCOPE 名字对不上 ⇒ 不猜")

        // ①d bundle 末段: 中文机器上的显示名是「计算器」, 模型给 Calculator 也得选得中
        //     (2026-10-29 boss 的失败就落在这一档: 名单里有它, 却"一个都认不出来")
        check(settings.resolveBundle(query: "计算器") == "com.apple.calculator",
              "T-ACTSCOPE 显示名(中文) ⇒ 命中")
        check(settings.resolveBundle(query: "Calculator") == "com.apple.calculator",
              "T-ACTSCOPE 英文名 = bundle 末段 ⇒ 命中 (少了这一档, 中文系统上一个都选不中)")
        check(settings.resolveBundle(query: "CALCULATOR") == "com.apple.calculator",
              "T-ACTSCOPE 末段比较忽略大小写")
        check(settings.resolveBundle(query: "calc") == nil,
              "T-ACTSCOPE 末段是**全等**不是包含 —— 半截名字不许命中(否则 `Mail` 会撞 `MailMate` 那类)")

        // MARK: ② 结构: act 仍然要进审批桥 (否则 autoJudge 的拒没地方待)

        check(ApprovalGate.needsApproval(act),
              "T-ACTSCOPE computer_act **仍然进审批桥** —— 挪进只读白名单 = 远程驱动档的安全承诺静默消失")
        check(!ApprovalGate.needsApproval(PiRpcTransport.computerReadToolName),
              "T-ACTSCOPE computer_read 仍然不进桥 (它在 JS 侧就 return undefined)")
        check(ApprovalGate.needsApproval(open),
              "T-ACTSCOPE computer_open **也要进桥** —— 否则远程驱动档管不住「打开一个 App」")

        // MARK: ③ 真链路

        final class Sink: AgentTransportDelegate {
            var events: [AgentEvent] = []
            func transport(_ t: any AgentTransport, didEmit event: AgentEvent) { events.append(event) }
            func transport(_ t: any AgentTransport, didFailEngineWithDiagnosis d: String) {}
        }
        func awaitingCount(_ s: Sink) -> Int {
            s.events.filter {
                if case .toolUpdated(let c) = $0 { return c.phase == .awaitingApproval }
                return false
            }.count
        }
        func errorText(_ s: Sink) -> String? {
            for e in s.events.reversed() {
                if case .toolUpdated(let c) = e, case .error(let m) = c.phase { return m }
            }
            return nil
        }
        func responded(_ t: PiRpcTransport) -> String? {
            t.sentCommands.reversed()
                .first { ($0["type"] as? String) == "extension_ui_response" }?["value"] as? String
        }
        /// `app == nil` = 模型没给 app(= 动当前前台), 卡头会退成工具名。
        func feed(_ t: PiRpcTransport, _ sink: Sink, callId: String, app: String?) {
            t.delegate = sink
            let args = app == nil
                ? #"{"op":"press","index":3,"seq":1}"#
                : #"{"app":"\#(app!)","op":"press","index":3,"seq":1}"#
            let head = app ?? act
            t.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"\#(callId)","toolName":"\#(act)","args":\#(args)}"#)
            t.handleRPCLine(#"{"type":"extension_ui_request","id":"u_\#(callId)","method":"select","title":"MANGOX|APPROVE|\#(callId)|\#(act)|按 #3 · \#(head)"}"#)
        }
        /// 打开 App: 参数只有 `app`(没有 op / index / seq), 卡头 title 就是那个 App。
        func feedOpen(_ t: PiRpcTransport, _ sink: Sink, callId: String, app: String) {
            t.delegate = sink
            t.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"\#(callId)","toolName":"\#(open)","args":{"app":"\#(app)"}}"#)
            t.handleRPCLine(#"{"type":"extension_ui_request","id":"u_\#(callId)","method":"select","title":"MANGOX|APPROVE|\#(callId)|\#(open)|打开 · \#(app)"}"#)
        }

        // ③a 勾了 Safari ⇒ **不弹卡**, 回 Allow
        settings.restore(enabledRaw: "1",
                         bundlesRaw: "com.apple.Safari",
                         actRaw: "com.apple.Safari")
        check(settings.activeActBundles == ["com.apple.Safari"],
              "T-ACTSCOPE 前置: 投影里真有它 (实测 \(settings.activeActBundles))")
        let t1 = PiRpcTransport()
        let s1 = Sink()
        feed(t1, s1, callId: "sc1", app: "Safari")
        check(awaitingCount(s1) == 0,
              "T-ACTSCOPE 勾了「可操作」⇒ 一张待审批卡片都不许发 (实测 \(awaitingCount(s1)))")
        check(responded(t1) == "Allow",
              "T-ACTSCOPE 勾了 ⇒ 回 Allow (不是 Allow always —— 名单已经没有了)")

        // ③b 没勾 Mail ⇒ 也不弹卡, 回 Deny, 卡上把话说明白
        let t2 = PiRpcTransport()
        let s2 = Sink()
        feed(t2, s2, callId: "sc2", app: "Mail")
        check(awaitingCount(s2) == 0,
              "T-ACTSCOPE 没勾 ⇒ 也不弹卡 (点了允许 helper 照样拒, 那张卡是纯误导; 实测 \(awaitingCount(s2)))")
        check(responded(t2) == "Deny", "T-ACTSCOPE 没勾 ⇒ 回 Deny")
        let hint = errorText(s2) ?? ""
        check(hint.contains("Mail") && hint.count > 12,
              "T-ACTSCOPE 没勾时卡上要点名是哪个 App 且给出补救路径 (实测「\(hint)」)")

        // ③c 模型没给 app(= 当前前台) ⇒ 客户端**不表态**, 交 helper 用同一份名单判
        let t3 = PiRpcTransport()
        let s3 = Sink()
        feed(t3, s3, callId: "sc3", app: nil)
        check(awaitingCount(s3) == 0 && responded(t3) == "Allow",
              "T-ACTSCOPE 算不出是哪个 App ⇒ 放行交给 helper (它才知道前台是谁 + 手上有真名单)")

        // ③d 查的是**投影**不是勾选框: 手改过的库能让口令类留在勾选集里
        settings.restore(enabledRaw: "1",
                         bundlesRaw: "com.apple.Safari,com.1password.1password",
                         actRaw: "com.1password.1password")
        check(settings.actSelected.contains("com.1password.1password"),
              "T-ACTSCOPE 前置: 手改过的库确实能让口令类留在勾选集里")
        check(settings.activeActBundles.isEmpty,
              "T-ACTSCOPE 但投影把它滤掉了 (实测 \(settings.activeActBundles)) —— 所以桥里必须查投影")
        let t4 = PiRpcTransport()
        let s4 = Sink()
        feed(t4, s4, callId: "sc4", app: "1Password")
        check(responded(t4) == "Deny",
              "T-ACTSCOPE 口令类: 勾选集里留着也照样拒 (查勾选框就会放行它)")

        // ③e 远程驱动档的**优先级**: autoJudge 的拒在作用域之前 —— 勾过不许绕过它
        settings.restore(enabledRaw: "1",
                         bundlesRaw: "com.apple.Safari",
                         actRaw: "com.apple.Safari")
        let t5 = PiRpcTransport()
        let s5 = Sink()
        t5.updateApprovalMode(.autoJudge)
        feed(t5, s5, callId: "sc5", app: "Safari")
        check(t5.autoJudgeBlocks.count == 1 && awaitingCount(s5) == 0,
              "T-ACTSCOPE 远程驱动档仍然拒 (实测 blocks=\(t5.autoJudgeBlocks.count)) —— 作用域不是后门")
        check(responded(t5) == "Deny", "T-ACTSCOPE 远程驱动档回 Deny")

        // ③f **没有任何像素从动作面出去**（验收项 6 的 ③，2026-10-30 到期补上）。
        //    文档原话是"③ 目前是结构性保证（图像面还没接）……等批 3 接上图像时必须补一条真断言，
        //    不许靠'现在还读不到像素'这件事撑着"。批 3c 已经接上了 ⇒ 这条不能再空着。
        //    ⚠️ 分工: 这里盯**这一次的转录**（act 这一路的下行命令里不许出现图像字段）;
        //    更强的结构性一条在 `run.sh` ③t（`ComputerImage(` 只许装配一处）——
        //    那条管"以后谁都加不了第二个出口", 这条管"这一次确实没发"。
        let pixelKeys: Set<String> = ["image", "data", "png", "base64"]
        let leakedPixels = t5.sentCommands.contains { cmd in pixelKeys.contains { cmd[$0] != nil } }
        // ⚠️ 非空前提必须一起判: 转录是空的时候 `contains` 恒为假 ⇒ 这条会变成"恒真的废话"
        //    (feed 哪天坏掉, 它还照样绿)。
        check(!t5.sentCommands.isEmpty && !leakedPixels,
              "T-ACTSCOPE 远程驱动档的动作回执里没有任何图像字段 "
              + "(实测下行 \(t5.sentCommands.count) 条; 像素从动作面出去 = 授权与遮蔽一起被绕过)")

        // MARK: ④ computer_open 查的是**读面** (两档权限不许被合成一档)

        // ④a 只勾「可读」、没勾「可操作」⇒ 打开它**必须放行**
        settings.restore(enabledRaw: "1", bundlesRaw: "com.apple.Safari", actRaw: "")
        check(settings.activeBundles == ["com.apple.Safari"] && settings.activeActBundles.isEmpty,
              "T-ACTSCOPE 前置: 只有读面 (实测 read=\(settings.activeBundles) act=\(settings.activeActBundles))")
        let t6 = PiRpcTransport()
        let s6 = Sink()
        feedOpen(t6, s6, callId: "so1", app: "Safari")
        check(responded(t6) == "Allow",
              "T-ACTSCOPE 只勾「可读」⇒ 打开它放行 —— 查操作面会误拒, 那等于把两档权限合成一档")
        check(awaitingCount(s6) == 0,
              "T-ACTSCOPE 打开 App 也不弹卡 (勾了就是允许; 实测待审批 \(awaitingCount(s6)) 张)")

        // ④b 读面也没勾 ⇒ 拒, 而且提示的是**「可读」**(说「可操作」会把人送去勾一个无关的框)
        settings.restore(enabledRaw: "1", bundlesRaw: "com.apple.mail", actRaw: "")
        let t7 = PiRpcTransport()
        let s7 = Sink()
        feedOpen(t7, s7, callId: "so2", app: "Safari")
        check(responded(t7) == "Deny", "T-ACTSCOPE 没勾「可读」⇒ 不打开它")
        let openHint = errorText(s7) ?? ""
        check(openHint.contains("Safari") && openHint.contains("可读"),
              "T-ACTSCOPE 提示里既要点名 App, 又要是「可读」那一档 (实测「\(openHint)」)")

        // ④c 远程驱动档一样管得住「打开一个 App」
        settings.restore(enabledRaw: "1",
                         bundlesRaw: "com.apple.Safari",
                         actRaw: "com.apple.Safari")
        let t8 = PiRpcTransport()
        let s8 = Sink()
        t8.updateApprovalMode(.autoJudge)
        feedOpen(t8, s8, callId: "so3", app: "Safari")
        check(t8.autoJudgeBlocks.count == 1 && awaitingCount(s8) == 0,
              "T-ACTSCOPE 远程驱动档不许打开 App (实测 blocks=\(t8.autoJudgeBlocks.count))")
        check(responded(t8) == "Deny", "T-ACTSCOPE 远程驱动档对 open 回 Deny")

        // MARK: ⑤ 候选表与"打开计划" (取"谁在跑"那一步踩过静默失效的坑, 判据留在这里)

        // ⚠️ 这一组的由来 (2026-10-29 实测): helper 原来用 `NSWorkspace.shared.runningApplications`
        //    取"谁在跑", 而那个 API 在**不抽 run loop** 的进程里会定格在首次查询那一刻 ——
        //    计算器明明随后起来了, `computer_read` 一路回"它们现在都没在运行", 且零红灯。
        //    把"取"(现问系统)与"判"(纯函数)拆开后, 下面这三档才断言得到。
        let runningTwo: [ComputerTarget.Running] = [
            .init(bundle: "com.apple.calculator", name: "计算器", pid: 61),
            .init(bundle: "com.apple.Safari", name: "Safari", pid: 62),
            .init(bundle: "com.example.notInScope", name: "名单外", pid: 63),
        ]
        let scoped = ComputerTarget.candidates(inScope: ["com.apple.Safari", "com.apple.calculator"],
                                               running: runningTwo)
        check(scoped.map(\.bundle) == ["com.apple.Safari", "com.apple.calculator"],
              "T-ACTSCOPE 候选表 = 名单 ∩ 在跑, 按 bundle 排序 (实测 \(scoped.map(\.bundle)))")
        check(scoped.allSatisfy { $0.pid > 0 },
              "T-ACTSCOPE 候选表都带真 pid (读与动作都靠它落到进程上)")
        check(ComputerTarget.candidates(inScope: ["com.apple.mail"], running: runningTwo).isEmpty,
              "T-ACTSCOPE 名单里有、但它没在跑 ⇒ 不进候选 (那次 bug 的判据: 不是名单里的人一律进)")
        check(ComputerTarget.candidates(inScope: ["com.apple.Safari"],
                                        running: [.init(bundle: "com.apple.Safari",
                                                        name: "Safari",
                                                        pid: -1)]).isEmpty,
              "T-ACTSCOPE pid = -1 (已退出但还在列表里) ⇒ 不进候选")
        check(ComputerTarget.candidates(inScope: [], running: runningTwo).isEmpty,
              "T-ACTSCOPE 名单空 ⇒ 候选空 (空 = 没下发, 不是全部允许)")

        // 名单里装着的那份: 名字用**中文显示名** —— 那是 helper 真会拿到的那份
        // (`installedInScope()` 在跑时取 `localizedName`, 没在跑退 bundle 末段)。
        let installed: [ComputerTarget.Candidate] = [
            .init(bundle: "com.apple.calculator", name: "计算器", pid: 0),
            .init(bundle: "com.apple.mail", name: "Mail", pid: 0),
        ]
        check(ComputerTarget.openPlan(query: "计算器", installed: installed, running: runningTwo)
                == .activate(.init(bundle: "com.apple.calculator", name: "计算器", pid: 61)),
              "T-ACTSCOPE 已在跑 ⇒ 只切前台, pid 取**系统那份**(不是候选表里的 0)")
        check(ComputerTarget.openPlan(query: "Mail", installed: installed, running: runningTwo)
                == .launch(.init(bundle: "com.apple.mail", name: "Mail", pid: 0)),
              "T-ACTSCOPE 装了但没跑 ⇒ 启动它")
        check(ComputerTarget.openPlan(query: "微信", installed: installed, running: runningTwo) == .notInScope,
              "T-ACTSCOPE 名字对不上 ⇒ 不猜着开 (猜错 = 悄悄打开了别人)")
        check(ComputerTarget.openPlan(query: "", installed: installed, running: runningTwo) == .notInScope,
              "T-ACTSCOPE 空 query 打不开 (同 pick: 空不等于随便挑一个)")
    }
}
