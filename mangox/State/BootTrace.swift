//
//  BootTrace.swift
//  启动序列的进度真源 —— 启动页唯一的数据来源。
//
//  设计稿: `next-version-drafts.html` 稿 2「把真实启动步骤可视化」。
//

import Foundation
import Combine

/// 启动序列的**唯一真源**。
///
/// 三条判据（全部抄自设计稿，缺一条这页就是骗人的）：
///  ① **每一行对应一次真实动作** —— 没有对应动作，就不许加新的 `Step` case；
///  ② **等它真完成才打勾** —— 只有那件事真跑完才调 `finish`，不许按时间流"演"到下一步；
///  ③ **读数是量出来的** —— `n` 是那一刻真实的数（子进程数 / 授权次数 / 项目数 …），不是编的。
///
/// 为什么是独立对象、不是 `ChatStore` 上的几个 `@Published`：
/// 启动页要在 **`ChatStore.init` 期间**就拿到进度，而那时 `self` 还没初始化完
/// （`@Published` 的 `objectWillChange` 都还不能用）。所以它先独立建好，再被 `ChatStore` 持有。
///
/// ⚠️ 它**不转发进 `ChatStore.objectWillChange`**（与 scheduler/knowledge/model 那几个不同）：
///    唯一的消费者是启动页那一层；转发出去等于让 `ChatView` 在开屏这 3 秒里多渲染几次，
///    而那几秒恰好是它正在做落底重排的时候 —— 白拿一次扰动风险，换不来任何东西。
@MainActor
final class BootTrace: ObservableObject {

    enum Step: String, CaseIterable {
        /// 引擎进程 —— pi 子进程真的起来了**并答了话**（只有 `Process.run` 返回不算：
        /// 起得来但立刻死掉的 pi 一样会返回，见 `PiRpcTransport` 的 spawn 失败诊断）。
        case engine
        /// 模型与凭据 —— 钥匙串读完（那一次读就是本行读数来源）+ 物化配置写完。
        case model
        /// 项目与工作区 —— 项目表落进内存。
        case workspace
        /// 助理与定时 —— 定时任务表落进内存（含 dream 那条预置任务）。
        case assistants
        /// 对话记录 —— 上次那场会话回放完、**并真的贴到底且有内容**。
        /// 这一行只有它等得久（1023 条会话实测 ~2.4s），也正是启动页存在的理由：
        /// 盖住那段"窗口在、画面还在跳"的时间。
        case sessions
    }

    enum Phase: Equatable {
        case pending
        case running
        case done
        /// 这一步**根本没发生**（比如本机没装 pi）—— 如实留空，不装作跑过、也不显示成失败。
        case skipped
    }

    struct Entry: Equatable {
        var phase: Phase = .pending
        var n: Int = 0
    }

    @Published private(set) var entries: [Step: Entry] = [:]

    /// 计时起点 = 本对象构造那一刻（`ChatStore` 的存储属性初始化，早于 `init` 体）。
    private let t0 = Date()

    init() { for s in Step.allCases { entries[s] = Entry() } }

    // MARK: - 写

    func begin(_ s: Step) {
        guard let e = entries[s], e.phase == .pending else { return }
        entries[s] = Entry(phase: .running, n: e.n)
        log(s, .running)
    }

    /// 动作真的跑完了。**幂等**：第一次赢，后面的调用静默丢弃 ——
    /// 理由是它的调用点散布在 `init` / delegate 回调 / 视图滚动拍上，其中滚动拍每帧都来。
    func finish(_ s: Step, n: Int) {
        guard let e = entries[s], e.phase != .done else { return }
        entries[s] = Entry(phase: .done, n: n)
        log(s, .done)
    }

    func skip(_ s: Step) {
        guard let e = entries[s], e.phase != .done else { return }
        entries[s] = Entry(phase: .skipped, n: e.n)
        log(s, .skipped)
    }

    // MARK: - 读

    func phase(_ s: Step) -> Phase { entries[s]?.phase ?? .pending }
    func number(_ s: Step) -> Int { entries[s]?.n ?? 0 }

    var doneCount: Int {
        Step.allCases.reduce(0) { $0 + (phase($1) == .done ? 1 : 0) }
    }

    /// 每一行都有结论了（做成 / 真没有）。启动页据此自己收场。
    var settled: Bool {
        Step.allCases.allSatisfy { phase($0) == .done || phase($0) == .skipped }
    }

    var elapsedMs: Double { Date().timeIntervalSince(t0) * 1000 }

    /// 诊断日志。**每个"行 × 相位"只留一行**（滚动拍会反复调 `finish`，不设限会把日志刷满）。
    /// 键必须带相位 —— 第一版只按行去重，于是 `sessions` 的 `running` 记完就把 `done` 吞了，
    /// 那恰好是"这一屏等了多久"的唯一证据。
    private var logged: Set<String> = []
    private func log(_ s: Step, _ phase: Phase) {
        let key = s.rawValue + "." + "\(phase)"
        guard !logged.contains(key) else { return }
        logged.insert(key)
        Log.event("boot", ["step": s.rawValue,
                           "phase": "\(phase)",
                           "n": "\(number(s))",
                           "ms": String(format: "%.0f", elapsedMs)])
    }
}
