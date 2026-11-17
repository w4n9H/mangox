//
//  CaseHandoffPath —— P19.2 S9: 工作日志与 Cron 交接文件分家
//
//  这一步动的是 Cron **共用**的 `handoffPath`，是全轮门最硬的一段。四条不变量：
//    ① **Cron 两条路径逐字节不变** —— 「Cron 档零改动」是硬约束，而它靠一句「我没改」是
//       守不住的：公式一抽、目录名一并，跑起来照样"能用"，只是几万个存量任务的文件
//       忽然换了位置（旧文件还在，新文件空 ⇒ 每个 Cron 任务都像「第一次跑」）。
//       所以这里的期望值**按字面拼**，不是拿 `handoffPath` 和自己比。
//    ② **助理落在另一个目录** —— 混在 `tasks/` 里，人打开文件树分不出「跑过一次的痕迹」
//       和「追了三个月的账本」。
//    ③ **回落只对助理开，且只读一次** —— 换目录那一刻旧账还在旧位置；不回落 = 几周记忆被
//       当成「第一轮」，而这件事零红灯（指令照跑、结论照出，它只是不再记得在追什么）。
//    ④ **目录由 App 预建**（Q5）—— S11 起巡检轮才有 `write`，而 `write` 写不进不存在的
//       目录；让模型自己建目录等于再开一个路径口子，与「落点只有一个」冲突。
//
//  反例（2026-11-17 实测）：
//    · 把 `legacyHandoffPath` 的两个目录名换成 `assistant/` ⇒ ①②③ 全红；
//    · `resolvedHandoffPath` 改写成「只看有没有 projectId」（丢掉「项目还在不在」）⇒ ③ 红；
//    · `readHandoff` 的回落去掉 `guard task.isAssistant` ⇒ ⑪ 红（Cron 读到助理的账本）；
//    · `ensureLogSession` 的预建去掉 `if task.isAssistant` ⇒ ⑭ 红（顺手给 Cron 建空目录）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseHandoffPath() async {
        let root = fixtureDir("p19handoff")
        let store = ChatStore(transport: MockTransport(), dbPath: root + "/p19handoff.db",
                              managedExtensionsDir: root + "/ext")
        store.scheduler.stopScheduler()

        /// 每个真值表格子一个独立目录，免得 A 的落盘污染 B 的断言。
        func project(_ tag: String) -> UUID {
            let p = root + "/" + tag
            try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            let id = UUID()
            store.projects.append(ProjectGroup(id: id, title: tag, path: p, items: []))
            return id
        }
        func task(_ kind: TaskKind, projectId: UUID?) -> ScheduledTask {
            var t = ScheduledTask(id: UUID(), name: "T", prompt: "目标",
                                  cron: "0 9 * * *", projectId: projectId)
            t.kind = kind
            t.continuous = true
            return t
        }
        let home = NSHomeDirectory()

        // ══ ① Cron 真值表（逐字节） ══════════════════════════════════════════════
        // 期望值全部**按字面拼**。这里的每条字符串都是「P19.2 之前那个实现会产出的东西」，
        // 不是「现在的实现产出的东西」—— 后者是自证。
        let cronDir = project("cronproj")
        let cronWithProject = task(.execute, projectId: cronDir)
        check(store.scheduler.handoffPath(for: cronWithProject)
              == root + "/cronproj/.mangox/tasks/" + cronWithProject.id.uuidString + ".md",
              "T-HANDOFF ①Cron 有项目 ⇒ <项目>/.mangox/tasks/<id>.md（\(store.scheduler.handoffPath(for: cronWithProject))）")

        let cronNoProject = task(.execute, projectId: nil)
        check(store.scheduler.handoffPath(for: cronNoProject)
              == home + "/.mangox/task-memory/" + cronNoProject.id.uuidString + ".md",
              "T-HANDOFF ②Cron 无项目 ⇒ ~/.mangox/task-memory/<id>.md（\(store.scheduler.handoffPath(for: cronNoProject))）")

        // ③ 项目已删：列表里没有这个 id ⇒ 回落 home。**这一格是抽公式时最容易丢的那一半。**
        let cronOrphan = task(.execute, projectId: UUID())
        check(store.scheduler.handoffPath(for: cronOrphan)
              == home + "/.mangox/task-memory/" + cronOrphan.id.uuidString + ".md",
              "T-HANDOFF ③Cron 项目已删 ⇒ 回落 home（不拼一个已不存在目录下的路径）")

        // ④ legacy 行不 fire，但仍然算得出一条路径（编辑器 / 清理都还要显示它）
        let legacy = task(.legacyWaiting, projectId: nil)
        check(store.scheduler.handoffPath(for: legacy)
              == home + "/.mangox/task-memory/" + legacy.id.uuidString + ".md",
              "T-HANDOFF ④legacy 行也算得出路径（它不 fire，但文件可能还在）")
        check(!store.scheduler.handoffPath(for: cronWithProject).contains("assistant"),
              "T-HANDOFF ①Cron 路径里**不含** assistant 字样（两档合并后所有 Cron 都会搬走）")

        // ══ ② 助理路径 ══════════════════════════════════════════════════════════
        let asstDir = project("asstproj")
        let asstWithProject = task(.assistant, projectId: asstDir)
        check(store.scheduler.handoffPath(for: asstWithProject)
              == root + "/asstproj/.mangox/assistant/" + asstWithProject.id.uuidString + ".md",
              "T-HANDOFF ⑥助理有项目 ⇒ <项目>/.mangox/assistant/<id>.md（\(store.scheduler.handoffPath(for: asstWithProject))）")

        let asstNoProject = task(.assistant, projectId: nil)
        check(store.scheduler.handoffPath(for: asstNoProject)
              == home + "/.mangox/assistant-memory/" + asstNoProject.id.uuidString + ".md",
              "T-HANDOFF ⑦助理无项目 ⇒ ~/.mangox/assistant-memory/<id>.md")
        let asstOrphan = task(.assistant, projectId: UUID())
        check(store.scheduler.handoffPath(for: asstOrphan)
              == home + "/.mangox/assistant-memory/" + asstOrphan.id.uuidString + ".md",
              "T-HANDOFF ⑧助理项目已删 ⇒ 回落 assistant-memory")

        // 同一条任务、只换 kind ⇒ 落点必须变。没有这一格，⑥ 可能是「本来就落在" assistant/」的假绿。
        var sameId = task(.execute, projectId: asstDir)
        let cronPathOfSame = store.scheduler.handoffPath(for: sameId)
        sameId.kind = .assistant
        let asstPathOfSame = store.scheduler.handoffPath(for: sameId)
        check(cronPathOfSame != asstPathOfSame
              && cronPathOfSame.hasSuffix(".mangox/tasks/\(sameId.id.uuidString).md")
              && asstPathOfSame.hasSuffix(".mangox/assistant/\(sameId.id.uuidString).md"),
              "T-HANDOFF ⑨同一个 id 只换 kind ⇒ 落点从 tasks/ 变 assistant/（不是「两档合并」）")

        // ══ ③ 回落 ══════════════════════════════════════════════════════════════
        // 夹具: 模拟「升级前那份账本」—— 直接写进**旧位置**，不经过 saveHandoff。
        let fallbackProj = project("fallback")
        let oldTask = task(.assistant, projectId: fallbackProj)
        let oldPath = root + "/fallback/.mangox/tasks/" + oldTask.id.uuidString + ".md"
        try? FileManager.default.createDirectory(
            atPath: (oldPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "## 目标\n三周前定下的目标".write(toFile: oldPath, atomically: true, encoding: .utf8)

        let viaFallback = store.scheduler.readHandoff(for: oldTask)
        check(viaFallback?.content == "## 目标\n三周前定下的目标",
              "T-HANDOFF ⑩旧位置有账本 ⇒ 助理读得到（换目录不能把记忆读没了）")
        check(viaFallback?.updatedAt != nil,
              "T-HANDOFF ⑩回落也要带 mtime（陈旧判据靠它，返回 nil 会让「多久没更新」恒真）")

        // ⑫ 写到新位置后不再回落。**顺序要紧**: 先写新的并验「新的赢」，再动旧的。
        check(store.scheduler.saveHandoff(for: oldTask, content: "## 目标\n换了位置之后的新账本"),
              "T-HANDOFF ⑬写新位置成功（目录不存在也写得进 —— 「目录没预建也不至于失败」的兜底）")
        check(store.scheduler.readHandoff(for: oldTask)?.content == "## 目标\n换了位置之后的新账本",
              "T-HANDOFF ⑫新位置有文件后 ⇒ 只读新的，**不再回落**（两份真源不能同时活着）")
        check(FileManager.default.fileExists(atPath: oldPath),
              "T-HANDOFF ⑫夹具: 旧文件**还在**（回落是只读的，没搬也没删 —— 上面那格不是「旧文件被删了」的假绿）")

        // ⑪ Cron **不回落**。同一条 id 换成 .execute: 它认 `tasks/` 那一份，
        // 但那一份此时装的是**升级前**的旧账（新账在 assistant/）。Cron 必须读到旧的那份；
        // 把旧的撤掉它就该读到 nil —— **不掉头去 assistant/ 找**。
        var cronTwin = oldTask
        cronTwin.kind = .execute
        check(store.scheduler.readHandoff(for: cronTwin)?.content == "## 目标\n三周前定下的目标",
              "T-HANDOFF ⑪a Cron 认 tasks/ 那一份（assistant/ 里的新账与它无关）")
        try? FileManager.default.removeItem(atPath: oldPath)
        check(store.scheduler.readHandoff(for: cronTwin) == nil,
              "T-HANDOFF ⑪b 回落**只对助理开**：Cron 在 tasks/ 没文件就是 nil（去掉 guard 这格红）")

        // ══ ④ 目录预建（Q5） ═══════════════════════════════════════════════════
        let preDir = project("precreate")
        let preTask = task(.assistant, projectId: preDir)
        let asstRoot = root + "/precreate/.mangox/assistant"
        check(!FileManager.default.fileExists(atPath: asstRoot),
              "T-HANDOFF ⑭a 夹具: ensureLogSession 之前 assistant/ 不存在（下面那一格才不是自证）")
        _ = store.scheduler.ensureLogSession(for: preTask)
        check(FileManager.default.fileExists(atPath: asstRoot),
              "T-HANDOFF ⑭b 助理的 fire 前置会**预建**账本目录（S11 的 write 写不进不存在的目录）")

        // 不能顺手给 Cron 也建一个：Cron 的 tasks/ 一直由 saveHandoff 自己建，
        // 提前建出空目录会在文件树里冒出一堆空的 .mangox/tasks。
        let preCron = task(.execute, projectId: preDir)
        _ = store.scheduler.ensureLogSession(for: preCron)
        check(!FileManager.default.fileExists(atPath: root + "/precreate/.mangox/tasks"),
              "T-HANDOFF ⑭c Cron 不被预建目录（否则文件树里凭空多出一堆空的 tasks/）")
    }
}
