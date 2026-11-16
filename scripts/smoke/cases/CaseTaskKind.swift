//
//  caseTaskKind —— P19 任务类型: 两档(execute / assistant) + 旧条件值守只读归档
//
//  五条不变量(每条都能变红):
//    ① 缺 kind 的旧行恒 `.execute` —— 老任务行为零漂移;
//    ② `condition` 非空 ⇒ `.legacyWaiting` **优先于** kind 字段 —— 顺序反了, 旧条件任务的
//       「触发后动作」会被当成普通 prompt **每轮无条件执行**(它当年靠 condition 判断要不要跑),
//       静默变意, 比崩溃更坏;
//    ③ legacy **不落 kind 值**(写 NULL), 靠 condition 派生 —— 不存第二份真相;
//    ④ legacy **不进 fire**, 连日志会话都不该建(正常路径会立刻建一个);
//    ⑤ `.assistant` 往返原样 —— 新档位真的存得住;
//    ⑥ 收件档的**三张旧表新库不再创建**, 账号池表仍在(旧库不 DROP, 降级回旧版还能开)。
//
//  注: ⑥ 是 P19 S0 的判据「新库不 CREATE 三张旧表」的落点; 删掉 PersistenceStore 里那三条
//  CREATE 之外的任何"顺手恢复"都必须让它变红 —— 它查的是 `sqlite_master`, 不是内存状态。
//
//  反例(2026-11-16 实测): 把 `loadScheduled` 里的判定改成「先看 kind 缺省、再看 condition」
//  ⇒ ② 立刻红; 把 `runScheduledFire` 开头那行 guard 删掉 ⇒ ④ 红(日志会话被建)。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseTaskKind() async {
        let dir = fixtureDir("p19kind")
        let store = ChatStore(transport: MockTransport(), dbPath: dir + "/p19kind.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        guard let p = store.persistence else {
            check(false, "T-TASK-KIND 需要 persistence 才能验落库往返")
            return
        }

        func reload(_ id: UUID) -> ScheduledTask? {
            ((try? p.loadScheduled()) ?? []).first { $0.id == id }
        }

        // —— ① 缺 kind 的普通旧行 ⇒ .execute ——
        let plainId = UUID()
        var plain = ScheduledTask(id: plainId, name: "旧 cron", prompt: "跑一下",
                                  cron: "0 9 * * *", projectId: nil)
        plain.kind = .execute
        try? p.upsertScheduled(plain)
        check(reload(plainId)?.kind == .execute,
              "T-TASK-KIND 缺 kind 的旧行解成 .execute（老任务零漂移）")

        // —— ⑤ .assistant 往返 ——
        let asstId = UUID()
        var asst = ScheduledTask(id: asstId, name: "助理", prompt: "保证 CI 是绿的",
                                 cron: "0 9 * * *", projectId: nil)
        asst.kind = .assistant
        try? p.upsertScheduled(asst)
        check(reload(asstId)?.kind == .assistant,
              "T-TASK-KIND kind = .assistant 落库后原样读回")

        // —— ② condition 非空 ⇒ legacy（顺序优先）——
        let legacyId = UUID()
        var legacy = ScheduledTask(id: legacyId, name: "旧值守", prompt: "触发后动作",
                                   cron: "0 3 * * *", projectId: nil)
        legacy.condition = "磁盘使用率超过 90%"
        legacy.kind = .execute   // ⚠️ 故意写成 execute: 解码必须靠 condition 把它掰回 legacy
        try? p.upsertScheduled(legacy)
        check(reload(legacyId)?.kind == .legacyWaiting,
              "T-TASK-KIND condition 非空 ⇒ .legacyWaiting（**优先于** kind；顺序反了这条红）")

        // —— ③ legacy 不落 kind 值（派生而非存储）——
        if let back = reload(legacyId) {
            try? p.upsertScheduled(back)
        }
        check(reload(legacyId)?.kind == .legacyWaiting,
              "T-TASK-KIND legacy 往返仍是 legacy（写 NULL，靠 condition 派生，不存第二份真相）")

        // —— ④ legacy 不进 fire ——
        var archived = ScheduledTask(id: UUID(), name: "归档值守", prompt: "动作",
                                     cron: "* * * * *", projectId: nil)
        archived.condition = "条件"
        archived.kind = .legacyWaiting
        store.scheduler.scheduledTasks = [archived]
        let convBefore = store.allConversations.count
        store.scheduler.runScheduledFire(archived)
        check(store.allConversations.count == convBefore
              && store.scheduler.scheduledTasks.first?.logSessionId == nil,
              "T-TASK-KIND legacy 不 fire（连日志会话都不建 —— 正常路径会立刻建一个）")

        // —— 对照: 同一条任务只要不是 legacy, fire 会真的建日志会话 ——
        // 没有这一格, 上一格可能因为「runScheduledFire 本来就不建会话」而假绿。
        var live = ScheduledTask(id: UUID(), name: "对照 cron", prompt: "跑一下",
                                 cron: "* * * * *", projectId: nil)
        live.kind = .execute
        store.scheduler.scheduledTasks = [live]
        store.scheduler.runScheduledFire(live)
        check(store.allConversations.count > convBefore,
              "T-TASK-KIND 对照: 非 legacy 任务 fire 会建日志会话（上一格不是假绿）")

        // —— ⑥ 新库不建收件三表（P19 S0 判据）——
        // 查 `sqlite_master` 而不是内存状态: 表建没建只有库自己知道；内存里没有对应属性这件事
        // 早在「删模型」那一步就成立了, 拿它当判据等于复述实现。
        var tables: Set<String> = []
        if let probe = try? Database(path: dir + "/p19kind.db", readonly: true),
           let rows = try? probe.query("SELECT name FROM sqlite_master WHERE type = 'table'") {
            for row in rows {
                if case .text(let name)? = row["name"] { tables.insert(name) }
            }
        }
        check(tables.contains("scheduled_tasks") && tables.contains("mailbox_accounts"),
              "T-TASK-KIND 建库表清单可读 (探针自身有效: 计划任务表 + 邮箱账号表都在)")
        check(!tables.contains("mailbox_sentinels")
              && !tables.contains("mailbox_tasks")
              && !tables.contains("mailbox_rejections"),
              "T-TASK-KIND 新库不 CREATE 收件三表（旧库不 DROP, 那是另一条纪律）")
    }
}
