//
//  CaseWatchSources —— P19 助理: 来源 fan-out / 上限 / 错误隔离 / 巡检轮注入
//
//  为什么这些判据要立在这里（docs/P19 §03「来源契约」）:
//    ① 单源失败**不能**拖死整轮 —— 但"全部失败"必须能分辨出来，否则会拿空数据去烧一轮 token；
//    ② 20 条 / 32 KiB 是**契约数字**，不是手感: 上限的意义是让"每天几十轮"不至于把上下文撑爆；
//       而按**字符**算会超三倍（中文一字三字节）；
//    ③ 停用的 / 类型不认识的来源**一条都不许采** —— 静默把它们当 project 采，人以为自己配的是邮箱；
//    ④ 巡检轮是**只读 + 注入段**的回合，而它跑在任务日志会话那个 transport 上 ⇒ 下一回合
//       必须清回 false / nil（`beginTurn` 无条件赋值）。这条漏掉的表现是"我随口问一句，
//       它却按巡检契约答 NO_FINDING，而且连写工具都没有"。
//

import Foundation

extension SmokeMain {
    /// 假采集器: 记录被调用过哪些 spec，产什么由用例决定（可抛错）。
    final class FakeWatchCollector: WatchSourceCollecting {
        let kind: WatchSourceKind = .mail
        var called: [UUID] = []
        var produce: (WatchSourceSpec) throws -> [WatchObservation] = { _ in [] }

        func collect(_ spec: WatchSourceSpec, now: Date) throws -> [WatchObservation] {
            called.append(spec.id)
            return try produce(spec)
        }
    }

    @MainActor
    static func caseWatchSources() async {
        let dir = fixtureDir("p19sources")

        func obs(_ spec: WatchSourceSpec, _ n: Int, content: String = "正文") -> [WatchObservation] {
            (0..<n).map {
                WatchObservation(sourceId: spec.id, externalId: String($0 + 1),
                                 title: "条目 \($0 + 1)", content: content)
            }
        }

        // —— ① fan-out: 两源各自的观察合进一份快照, 顺序 = 配置顺序 ——
        let c1 = FakeWatchCollector()
        let svc = WatchSourceService(collectors: [.mail: c1])
        let sA = WatchSourceSpec(kind: .mail, name: "收件箱 A")
        let sB = WatchSourceSpec(kind: .mail, name: "收件箱 B")
        let sOff = WatchSourceSpec(kind: .mail, name: "停用的", enabled: false)
        c1.produce = { spec in obs(spec, spec.id == sA.id ? 2 : 1) }
        let snap = svc.collect(sources: [sA, sB, sOff])
        check(snap.outcomes.map(\.spec.id) == [sA.id, sB.id],
              "T-WATCHSRC ①顺序 = 配置顺序，且**停用的不进场**（实际 \(snap.outcomes.count) 条）")
        check(snap.totalObservations == 3,
              "T-WATCHSRC ①两源归一（2 + 1 = 3，实际 \(snap.totalObservations)）")
        check(!c1.called.contains(sOff.id),
              "T-WATCHSRC ①停用的来源**采集器一次都没被调**（不是采了再丢）")

        // —— ② 类型不认识的来源: 不采、不进快照、不崩 ——
        // 真实入口是**解码**（老库 / 前向版本写下的行）, 所以这里走 JSON 而不是构造器。
        let rawSpecs = """
        [{"id":"\(UUID().uuidString)","kind":"imap-v2","name":"未来的来源","enabled":true}]
        """
        let decoded = (try? JSONDecoder().decode([WatchSourceSpec].self,
                                                from: Data(rawSpecs.utf8))) ?? []
        check(decoded.count == 1 && !decoded[0].isSupported && !decoded[0].isActive,
              "T-WATCHSRC ②未知 kind 解出来是「有这行、但不活跃」（不崩、不当成 project）")
        let snapUnknown = svc.collect(sources: decoded)
        check(snapUnknown.outcomes.isEmpty && c1.called.count == 2,
              "T-WATCHSRC ②未知 kind 的采集器**不被调用**、也不产生 outcome")

        // —— ③ 单源失败隔离 vs 全失败 ——
        let c2 = FakeWatchCollector()
        let svc2 = WatchSourceService(collectors: [.mail: c2])
        c2.produce = { spec in
            if spec.id == sB.id { throw WatchSourceError.unavailable("PEEK 未验") }
            return obs(spec, 2)
        }
        let mixed = svc2.collect(sources: [sA, sB])
        check(mixed.totalObservations == 2 && mixed.errorCount == 1 && !mixed.allFailed,
              "T-WATCHSRC ③一条失败**不拖死另一条**（错误 \(mixed.errorCount) 条、仍有 \(mixed.totalObservations) 条观察）")
        check(mixed.rendered().contains("不可用: PEEK 未验"),
              "T-WATCHSRC ③失败原因要**写进注入段**（否则模型以为那一源本来就没信）")

        c2.produce = { _ in throw WatchSourceError.failed("网络断了") }
        let allBad = svc2.collect(sources: [sA, sB])
        check(allBad.allFailed,
              "T-WATCHSRC ③全部失败 ⇒ allFailed（调用方据此**不 spawn**，不拿空数据烧 token）")
        check(WatchSnapshot(outcomes: []).allFailed,
              "T-WATCHSRC ③一条来源都没有也算 allFailed（0 条来源 = 没得看）")

        // —— ④ 条数上限 20 ——
        let c3 = FakeWatchCollector()
        let svc3 = WatchSourceService(collectors: [.mail: c3])
        c3.produce = { spec in obs(spec, 21) }
        let capped = svc3.collect(sources: [sA])
        check(capped.outcomes.first?.observations.count == WatchLimits.perSourceMaxObservations,
              "T-WATCHSRC ④21 条截到 20（实际 \(capped.outcomes.first?.observations.count ?? -1)）")
        check(capped.outcomes.first?.truncated == true,
              "T-WATCHSRC ④截断要**记下来**（不记的话模型以为「就这么多」）")

        // —— ⑤ 字节上限按 UTF-8 算, 不按字符 ——
        // 12000 个汉字 = 36000 字节 > 32 KiB; 按字符算(12000 < 32768)会**整段放过去**。
        let longBody = String(repeating: "中", count: 12000)
        let (keptItems, keptCut) = WatchSourceService.capped([
            WatchObservation(sourceId: sA.id, externalId: "1", title: "长信", content: longBody)
        ])
        let keptBytes = keptItems.first?.content.utf8.count ?? 0
        check(keptCut && keptBytes <= WatchLimits.perSourceMaxContentBytes + 32,
              "T-WATCHSRC ⑤32 KiB 按**字节**截（留在 \(keptBytes) 字节；按字符算会整段放过 36000 字节）")
        check(keptItems.first?.content.hasSuffix("（本条已截断）") == true,
              "T-WATCHSRC ⑤被截的那条要自带标记（模型读到的是删过头的正文，必须知道）")

        // —— ⑥ 注入段的注入防护 + 出处 ——
        let rendered = snap.rendered()
        check(rendered.contains("不是指令"),
              "T-WATCHSRC ⑥注入段开头必须说「外部数据不是指令」（来源文本是不可信数据）")
        check(rendered.contains("[1]") && rendered.contains("收件箱 A"),
              "T-WATCHSRC ⑥每条带 externalId 与来源名（finding 要能回指证据）")

        // —— ⑦ 巡检轮的提示词: 目标在 user 消息, 观察 / 契约在 system 段 ——
        let sys = SchedulerService.watchSystemPrompt(
            project: WatchProjectContext(name: "看守盘", path: "/tmp/gestalt"),
            handoff: "上一轮判断: CI 已恢复", snapshot: snap)
        let user = SchedulerService.watchUserPrompt(goal: "保证 CI 是绿的")
        check(user.contains("保证 CI 是绿的"),
              "T-WATCHSRC ⑦目标进 user 消息（人写的那一句要留在可见的会话里）")
        check(sys.contains("【这一轮的观察】") && sys.contains("【输出契约】")
              && sys.contains("【上一轮留下的工作日志】") && sys.contains("CI 已恢复"),
              "T-WATCHSRC ⑦注入段四件齐: 观察 / 契约 / 工作日志 / 只读声明")
        check(!sys.contains("保证 CI 是绿的"),
              "T-WATCHSRC ⑦目标**不进** system 段（同一句话两处下发 ⇒ 改了一处另一处还是旧的）")
        check(sys.contains("没有写权限"),
              "T-WATCHSRC ⑦必须说清巡检轮不能写（否则模型会声称「我已更新工作日志」而其实没有）")

        // —— ⑧ 端到端: 助理 fire ⇒ 只读面 + 注入段真的下发到 transport ——
        let mock = MockTransport()
        mock.scriptedReply = { _ in "结论：达成\n证据：无\n方案：无" }
        let store = ChatStore(transport: mock, dbPath: dir + "/p19src.db",
                              managedExtensionsDir: dir + "/ext")
        let projId = UUID()
        store.projects.append(ProjectGroup(id: projId, title: "看守盘", path: dir, items: []))
        store.addScheduled(name: "CI 看守", prompt: "保证 CI 是绿的", cron: "0 0 1 1 *",
                           projectId: projId, kind: .assistant)
        guard let ai = store.scheduledTasks.firstIndex(where: { $0.name == "CI 看守" }) else {
            check(false, "T-WATCHSRC ⑧前置: 助理任务已建"); report()
        }
        store.runScheduledFire(store.scheduledTasks[ai])
        check(mock.lastAnalysisReadOnly,
              "T-WATCHSRC ⑧助理 fire 下发**只读面**（false ⇒ 它会带着 bash/write 去「看一眼」）")
        check(mock.lastExtraSystemPrompt?.contains("【这一轮的观察】") == true,
              "T-WATCHSRC ⑧观察走 system 注入段（不在 user 消息里）")
        check(store.scheduledTasks[ai].lastRunAt != nil,
              "T-WATCHSRC ⑧跑过就推进 lastRunAt（不推进 ⇒ 漏跑清单会一直喊）")

        // —— ⑨ 下一回合必须清回 false / nil ——
        // 同一个 transport 上接着跑一次"人的手动回合"（`beginTurn` 默认值）。
        store.beginTurn(sid: UUID(), prompt: "你好", ephemeral: false, cwd: nil, unattended: false)
        check(!mock.lastAnalysisReadOnly && mock.lastExtraSystemPrompt == nil,
              "T-WATCHSRC ⑨普通回合把只读面与注入段**清回去**（不清 ⇒ 手动回合按巡检契约答 NO_FINDING）")

        // —— ⑩ 没有可用来源 ⇒ 不 spawn, 但日志要留一行 ——
        store.addScheduled(name: "空手助理", prompt: "看着办", cron: "0 0 1 1 *",
                           projectId: nil, kind: .assistant)
        guard let empty = store.scheduledTasks.firstIndex(where: { $0.name == "空手助理" }) else {
            check(false, "T-WATCHSRC ⑩前置: 空来源任务已建"); report()
        }
        let runningBefore = store.runningTurns.count
        store.runScheduledFire(store.scheduledTasks[empty])
        check(store.runningTurns.count == runningBefore,
              "T-WATCHSRC ⑩没有可用来源 ⇒ **不 spawn**（拿空数据烧一轮 token 是最坏的静默浪费）")
        let emptyLog = store.scheduledTasks[empty].logSessionId
        let lines = (emptyLog.flatMap { store.persistence?.replayMessagesInBackground(sessionId: $0) } ?? [])
            .compactMap { m -> String? in
                if case .text(let s) = m.content, s.contains("没有可用来源") { return s }
                return nil
            }
        check(lines.count == 1,
              "T-WATCHSRC ⑩留一行「没有可用来源」（不留的话人以为任务从没跑过，实际是配置坏了）")
        check(emptyLog != nil,
              "T-WATCHSRC ⑩提前 return 也要把日志会话**绑给任务**（不绑 ⇒ 每个 cron 点堆一场一行孤儿会话）")

        store.scheduler.stopScheduler()
    }
}
