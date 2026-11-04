//
//  CaseChatPerf.swift
//  长会话的投影成本基线（2026-11-04，B 批 B3）。
//
//  背景：`ChatView.body` 里每拍都会重算 `projectedChat` —— 它是一趟全量 O(N) 走查
//    （建行数组 / `ToolNesting.index` / 分组 / 每组 `ToolRunBuilder` / 轮末账单）。
//    B 批把 `onChange` 的**深比较**换成了 `messagesRevision`，但投影本身没动。
//    计划里 B3 的原话是"先测量，不先写缓存" ⇒ 这个用例就是那把尺子。
//
//  ⚠️ 判据用**增长比**（250 → 1000 条），不用绝对毫秒：绝对毫秒在快慢不同、CI 负载
//     不同的机器上会让门自己变色，那种门最后一定会被"调大预算"搪塞过去。
//     增长比是**复杂度**的指纹：线性 ≈ 4×，平方级 ≈ 16×，跟机器多快无关。
//     绝对毫秒只留一个**很松**的悬崖线（量级回归才响），读数写在 PASS 文案里给人看。
//
//  ⚠️ 量的必须是**真投影**（`SmokeChatProjection` → `ChatView.projectedChat`）。
//     在外面另写一份"轻量版投影"来计时的话，量的是另一段代码 —— 真那段退化成
//     平方级时它照样绿。
//
//  ⚠️ 不覆盖的部分：SwiftUI 自己的视图树 diff（那部分在无窗口的冒烟里根本跑不起来）。
//     这里量的是"我们这个文件里自己写的那些 O(N)"。
//

import Foundation

// MARK: - 计时小工具

/// 一次调用的耗时（毫秒）。
///
/// `sink` 不是装饰：没有它，优化器可以把"返回值没人要"的循环整段删掉，
/// 于是量出来的是空转，而且**看起来特别好**（恒 0.00ms）。
fileprivate func cperfTimeOnce(_ sink: inout Int, _ body: () -> Int) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    sink &+= body()
    let t1 = DispatchTime.now().uptimeNanoseconds
    return Double(t1 &- t0) / 1_000_000
}

fileprivate func cperfSamples(_ reps: Int, _ sink: inout Int, _ body: () -> Int) -> [Double] {
    var xs: [Double] = []
    xs.reserveCapacity(reps)
    for _ in 0..<reps { xs.append(cperfTimeOnce(&sink, body)) }
    xs.sort()
    return xs
}

fileprivate func cperfP50(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs[xs.count / 2] }

fileprivate func cperfP95(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    return xs[min(xs.count - 1, Int(Double(xs.count - 1) * 0.95))]
}

// MARK: - 夹具

fileprivate func cperfTool(_ kind: ToolKind, _ title: String, output: String) -> ChatMessage {
    ChatMessage(role: .assistant,
                content: .tool(ToolCall(kind: kind,
                                        title: title,
                                        command: kind == .bash ? "./scripts/smoke/run.sh" : nil,
                                        details: [ToolDetail("输出", output)],
                                        phase: .done,
                                        durationMs: 12)))
}

/// 一轮 10 条：用户一句话 + 思考 + 5 张工具卡（带输出）+ 3 段正文。
/// 形状比条数重要 —— 投影的开销在"分组 / 折叠 / 工具段"上，不在纯文本条数上。
fileprivate func cperfFixture(turns: Int) -> [ChatMessage] {
    let filler = String(repeating: "读代码的时候顺带确认了一下边界条件，", count: 12)  // ≈250 字
    var out: [ChatMessage] = []
    out.reserveCapacity(turns * 10)
    for t in 0..<turns {
        out.append(ChatMessage(role: .user, content: .text("第 \(t) 轮: 把那几个文件的接线对一遍")))
        out.append(ChatMessage(role: .assistant, content: .think("先看 " + filler)))
        out.append(cperfTool(.read, "/repo/src/Mod\(t)/View.swift", output: filler + filler))
        out.append(cperfTool(.bash, "swift build", output: filler))
        out.append(ChatMessage(role: .assistant, content: .text("这一步的结论是: " + filler)))
        out.append(cperfTool(.grep, "messagesRevision", output: filler))
        out.append(cperfTool(.edit, "/repo/src/Mod\(t)/View.swift", output: filler))
        out.append(ChatMessage(role: .assistant, content: .text("改完了, " + filler)))
        out.append(cperfTool(.bash, "./scripts/smoke/run.sh", output: filler + filler))
        out.append(ChatMessage(role: .assistant, content: .text("全绿。")))
    }
    return out
}

// MARK: - 用例

extension SmokeMain {
    @MainActor
    static func caseChatPerf() async {
        print("== T-CPERF 长会话投影成本 (B3 基线) ==")

        let dir = fixtureDir("chatperf")
        let store = ChatStore(transport: MockTransport(), dbPath: dir + "/p.db",
                              managedExtensionsDir: dir + "/ext")
        store.mailbox.stopScheduler()
        store.messages = []

        let probe = SmokeChatProjection(store: store)
        var sink = 0

        // ── 小规模：250 条 ──────────────────────────────────────
        store.messages = cperfFixture(turns: 25)
        // 预热：首次调用要把类型元数据 / 字典容量这些冷启动成本付掉，
        // 不预热的话前几个样本会虚高，而虚高的位置随机器变 ⇒ 读数不可比。
        for _ in 0..<3 { sink &+= probe.run() }
        let small = cperfSamples(15, &sink, probe.run)

        // ── 大规模：1000 条 ─────────────────────────────────────
        store.messages = cperfFixture(turns: 100)
        for _ in 0..<3 { sink &+= probe.run() }
        let big = cperfSamples(15, &sink, probe.run)
        let blocksBig = probe.run()

        let tSmall = cperfP50(small)
        let tBig = cperfP50(big)
        let p95Big = cperfP95(big)

        // 地板的理由：`tSmall` 若小到计时器分辨率附近（几十微秒），比值就是个噪音放大器。
        // 20µs 在 250 条规模下远低于实测值，只有"投影真的变快了 10 倍"才会踩到。
        let ratio = tBig / max(tSmall, 0.02)

        check(store.messages.count == 1000, "T-CPERF 夹具 1000 条 (实测 \(store.messages.count))")
        check(blocksBig > 0 && blocksBig < 1000,
              "T-CPERF 1000 条投影出 \(blocksBig) 块 (折叠后必须少于条数, 否则投影没生效)")

        check(ratio < 8.0,
              String(format: "T-CPERF 投影随消息数近线性: 4× 数据实测 %.2f× (上限 8×; 平方级会到 16×)", ratio))
        check(tBig < 60.0,
              String(format: "T-CPERF 1000 条单次投影 %.2fms (p50) / %.2fms (p95), 悬崖线 60ms", tBig, p95Big))

        // ── 参考读数：被 B2 换掉的那笔"深比较" ────────────────
        // 这不是判据，是**取舍的证据**：视图原来每拍 `onChange(of: store.messages)`
        // 就要付这笔钱。数字只写进日志，不设阈值 —— 它的大小取决于正文长度，
        // 没有一个"对所有人都对"的界。
        //
        // ⚠️ 必须**逼开 COW 共享缓冲**：`var b = a; a == b` 会命中 stdlib 的
        //    「同一块 buffer」引用相等短路（实测 0.00ms），量出来的是身份判断。
        //    真实场景里 old 是上一拍捕获的数组，被就地改过之后 buffer 早就分家了。
        var forced = store.messages
        let lastIdx = forced.count - 1
        let keep = forced[lastIdx]
        forced[lastIdx] = ChatMessage(role: .user, content: .text("__cow__"))
        forced[lastIdx] = keep
        check(forced == store.messages,
              "T-CPERF 深比较夹具内容与 store 一致 (否则比的是长度不一致的短路, 数字没意义)")

        var deepTotal = 0.0
        for _ in 0..<10 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let same = (forced == store.messages)
            let t1 = DispatchTime.now().uptimeNanoseconds
            deepTotal += Double(t1 &- t0) / 1_000_000
            sink &+= same ? 1 : 0
        }
        let deepMs = deepTotal / 10
        print(String(format: "   · 参考: 1000 条 [ChatMessage] 深比较 %.2fms/次 (B2 已换成 revision, 这笔不再付)",
                     deepMs))

        // ── 流式 500 chunk：正文从 0 长到 ~200KB ────────────────
        // 投影**不该**关心正文多长（它只看结构）。若哪天有人把 markdown / 解析塞进
        // 投影里，这里就会顺着正文长度往上爬 —— 那是"每 chunk 越来越慢"的起点。
        if let gi = store.messages.lastIndex(where: { $0.role == .assistant }) {
            let chunk = String(repeating: "流式追加的一段正文，", count: 8)  // ≈80 字
            var body = ""
            var head: [Double] = []
            var tail: [Double] = []
            for i in 0..<500 {
                body += chunk
                store.messages[gi].content = .text(body)
                let t = cperfTimeOnce(&sink, probe.run)
                if i < 50 { head.append(t) }
                if i >= 450 { tail.append(t) }
            }
            head.sort(); tail.sort()
            let grow = cperfP50(tail) / max(cperfP50(head), 0.02)
            check(grow < 2.0,
                  String(format: "T-CPERF 正文长到 %ldKB 后投影不随长度变慢: 实测 %.2f× (上限 2×)",
                         body.utf8.count / 1024, grow))
        } else {
            check(false, "T-CPERF 夹具里找不到 assistant 行 —— 流式增长那一段没跑, 这条红灯代表用例残缺")
        }

        // 让 `sink` 参与一个不可能失败的结论，防止整段被优化掉。
        check(sink > 0, "T-CPERF 计时样本参与了累加 (sink=\(sink))")
    }
}
