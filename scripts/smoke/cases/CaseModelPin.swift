//
//  CaseModelPin.swift
//  fire 前校验 pinned 模型 (2026-10-21, `ChatStore.isKnownModel` + `SchedulerService`)。
//
//  为什么这道门必须在 fire **之前**:
//    模型下线后 pi 只 warn 一句 `Using custom model id` 照旧把请求发出去, API 打回 404,
//    而 pi 把 404 吃成一个**空回合**（见 `CaseEmptyTurn`）。于是整条链在后半段是彻底静默的:
//    日志会话里只有那一大段 prompt, 之后一个字都没有 → 用户看到"点了 dream, 什么反应都没有"。
//    拦在 fire 之前至少能留下**名字**: 哪一次、pin 的是哪个模型。
//
//  判据三件: ① 不 fire ② lastRunAt 不推进（漏跑清单照实记）③ 日志会话里有一行点名。
//
//  ⚠️ 这道门上线时**修好了两条既有用例的假 pin**（不是顺手改的, 是被它拦下来的）:
//     `T-P10.4 任务级 fire 配置` 与 `P15.3 档位告警` 原本 pin 的是 `prov-x/model-y`、
//     `p/m` 这种**根本不存在的占位模型** —— 它们只关心"配置有没有下发", 从不关心模型真假。
//     门一上线, 那两次 fire 就**正确地**被拦在门口（判据以"实测 []"红）, 所以两处改成
//     了 pi 上报目录里真有的 `openai/o4-mini`。用例的意图（下发的是**非默认**模型）不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseModelPin() async {
        print("== T-MODELPIN fire 前校验 pinned 模型 ==")

        let dir = fixtureDir("modelpin")
        let mock = MockTransport()
        let store = ChatStore(transport: mock, dbPath: dir + "/pin.db",
                              managedExtensionsDir: dir + "/ext")
        mock.scriptedReply = { _ in "巡检完成, 一切正常。" }

        // 自管清单只有一个"活着"的模型 ⇒ 菜单全集就是它（自管非空时 pi 上报目录退出菜单）
        store.upsertManagedModel(ManagedModel(provider: "tpin", modelId: "alive", apiType: "openai"))
        check(store.menuModels.count == 1 && store.menuModels.first?.id == "alive",
              "T-MODELPIN 前置: 清单 = 自管 enabled 条目 (实测 \(store.menuModels.map(\.id)))")

        // ── 判据本身: 空清单 = 无从判断 ⇒ 放行（这条**不许**变成"拦"）──
        check(store.isKnownModel(provider: "tpin", modelId: "alive"),
              "T-MODELPIN 清单内的模型 ⇒ 认识")
        check(!store.isKnownModel(provider: "tpin", modelId: "gone"),
              "T-MODELPIN 清单外的模型 ⇒ 不认识 (哪怕 provider 一致)")
        check(!store.isKnownModel(provider: "other", modelId: "alive"),
              "T-MODELPIN provider 也要对上 (同 id 不同家 ≠ 同一个模型)")

        store.addScheduled(name: "定点", prompt: "执行巡检", cron: "0 0 1 1 *", projectId: nil)
        guard let i = store.scheduledTasks.firstIndex(where: { $0.name == "定点" }) else {
            check(false, "T-MODELPIN 前置: 任务已建"); report()
        }
        func pin(_ modelId: String) {
            var t = store.scheduledTasks[i]
            t.config = SessionConfig(provider: "tpin", modelId: modelId, thinkingLevel: nil,
                                     agentMode: AgentMode.standard.rawValue, askApproval: false)
            store.updateScheduled(t)
        }
        func timelineLines(_ sid: UUID) -> [String] {
            (store.persistence?.replayMessagesInBackground(sessionId: sid) ?? []).compactMap { m in
                if case .text(let s) = m.content, m.role == .user, s.contains("未运行") { return s }
                return nil
            }
        }

        // ── ① pin 到一个已下线的模型 ⇒ 不 fire、落一行点名 ──
        pin("gone")
        store.runScheduledFire(store.scheduledTasks[i])
        check(store.runningTurns.isEmpty, "T-MODELPIN 模型不在清单 ⇒ 不 fire (runningTurns 为空)")
        check(store.scheduledTasks[i].lastRunAt == nil,
              "T-MODELPIN 不推进 lastRunAt (没跑就是没跑, 漏跑清单要照实记)")
        guard let logId = store.scheduledTasks[i].logSessionId else {
            check(false, "T-MODELPIN 日志会话绑给了任务 (否则每个 cron 点都新建一场)"); report()
        }
        let lines1 = timelineLines(logId)
        check(lines1.count == 1, "T-MODELPIN 日志会话落了一行「未运行」(实测 \(lines1.count) 行)")
        check(lines1.first?.contains("tpin/gone") == true,
              "T-MODELPIN 那行**点名**是哪个模型 (实测 \(lines1.first ?? "空"))")

        // ── ② 同一个断掉的 pin 再来一次 ⇒ 不重复刷同一行（断掉的 pin 是常态, cron 会一直到期）──
        store.runScheduledFire(store.scheduledTasks[i])
        check(timelineLines(logId).count == 1,
              "T-MODELPIN 同一个 pin 反复到期 ⇒ 日志不重复刷 (实测 \(timelineLines(logId).count) 行)")
        check(store.scheduledTasks[i].logSessionId == logId,
              "T-MODELPIN 后续跳过不新建日志会话")

        // ── ③ 换成另一个断掉的 pin ⇒ 要重新留痕（"记过"不等于永久闭嘴）──
        pin("gone-too")
        store.runScheduledFire(store.scheduledTasks[i])
        let lines2 = timelineLines(logId)
        check(lines2.count == 2, "T-MODELPIN 换了 pin ⇒ 再记一笔 (实测 \(lines2.count) 行)")
        check(lines2.last?.contains("tpin/gone-too") == true, "T-MODELPIN 新那行点名新 pin")

        // ── ④ 修好模型 ⇒ 正常 fire（这道门不许把能跑的任务一起拦掉）──
        pin("alive")
        store.runScheduledFire(store.scheduledTasks[i])
        check(store.runningTurns == [logId], "T-MODELPIN 模型在清单里 ⇒ 照常 fire (回合归属日志会话)")
        check(store.scheduledTasks[i].lastRunAt != nil, "T-MODELPIN 正常 fire 才推进 lastRunAt")
        check(await waitUntil { store.runningTurns.isEmpty }, "T-MODELPIN 正向对照: 回合正常结束")
    }
}
