//
//  caseDreamStaleTask —— dream 存量任务: 老库老文案读回来仍是"陈旧"
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家, 未改一行逻辑）。
//  原位替换为 `await caseDreamStaleTask()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseDreamStaleTask() async {
        let dsDir = fixtureDir("dream-stale")
        let dsDB = dsDir + "/stale.db"
        let dsSeed = ChatStore(transport: MockTransport(), dbPath: dsDB,
                               managedExtensionsDir: dsDir + "/ext-seed")
        dsSeed.mailbox.stopScheduler()
        dsSeed.scheduler.seedDreamTaskIfNeeded()
        let dsSeeded = dsSeed.scheduledTasks.first { SchedulerService.isDreamTask($0) }
        check(dsSeeded?.prompt == SchedulerService.dreamPrompt,
              "P15.6b 预置: 刚种下的那行, prompt 就是当前常量（种的时候是对的 —— 错在它**会被复制**)")

        // 伪造"上一版种下的副本": 一段**任何常量里都不存在**的指令。名字与档期一并改掉,
        // 用来证明归一化**只碰 prompt**（那两者是真正的用户字段）。
        let dsFake = "旧版指令: 用 bash 读 ~/.mangox/pi-sessions/*.jsonl 再总结"
        if var dsStale = dsSeeded {
            dsStale.prompt = dsFake
            dsStale.name = "我改过的名字"
            dsStale.cron = "5 4 * * *"
            try? dsSeed.persistence?.upsertScheduled(dsStale)
        }

        // —— 关键夹具: 新 store 打开同一个库（= 老库 + 新版本启动）——
        let ds = ChatStore(transport: MockTransport(), dbPath: dsDB,
                           managedExtensionsDir: dsDir + "/ext")
        ds.mailbox.stopScheduler()
        let dsRow = ds.scheduledTasks.first { SchedulerService.isDreamTask($0) }
        check(dsRow?.prompt == dsFake,
              "P15.6b 夹具: 新版本打开老库, 读到的**确实是那份旧副本**"
              + "（没有这一步, 下面的判据全是自证; 实测 [\(dsRow?.prompt.prefix(12) ?? "nil")…])")
        check(dsRow?.cron == "5 4 * * *",
              "P15.6b 夹具（= P15.3 档期语义）: **重启也不还原用户改过的档期** —— 新版本打开老库,"
              + " 那一行还在 ⇒ seed 早退 ⇒ 原样保留。只有「那一行不在了」才补种回出厂 每周日 03:00")

        if let dsRow {
            // ① fire: 指令正文来自**常量**, 与库里那份副本无关。
            let dsFired = ds.scheduler.buildScheduledPrompt(dsRow)
            check(!dsFired.contains(dsFake),
                  "P15.6b fire: 旧副本**一个字节都进不去**（真改成读 `task.prompt` 立红）")
            check(dsFired.hasPrefix(SchedulerService.dreamPrompt),
                  "P15.6b fire: 拼出来的是**当前常量**打头（实测 [\(dsFired.prefix(18))…])")
            check(!dsFired.contains("5 4 * * *"),
                  "P15.6b fire: 那条旧行的**任何字段**都没有混进指令（档期不是给模型看的）")

            // ② 保存: 域层归一。`updateScheduled` 收的是**带着旧副本**的那个对象。
            ds.scheduler.updateScheduled(dsRow)
            let dsHealed = ds.scheduledTasks.first { SchedulerService.isDreamTask($0) }
            check(dsHealed?.prompt == SchedulerService.dreamPrompt,
                  "P15.6b 保存: 编辑过 dream 行 ⇒ prompt 被域层**归一成当前常量**"
                  + "（实测 [\(dsHealed?.prompt.prefix(16) ?? "nil")…])")
            check(dsHealed?.name == "我改过的名字" && dsHealed?.cron == "5 4 * * *",
                  "P15.6b 保存 反例: 归一化**只碰 prompt** —— 名字与档期是用户字段, 必须原样保留")
            let dsReload = ((try? ds.persistence?.loadScheduled()) ?? [])
                .first { SchedulerService.isDreamTask($0) }
            check(dsReload?.prompt == SchedulerService.dreamPrompt,
                  "P15.6b 保存: 归一化**落到了盘上**（库里那份假副本被治好, 不是只改了内存）")

            // ③ 反例: 普通任务的两条路径都不受影响（守卫不许把非 dream 一起拦掉）。
            let dsPlain = ScheduledTask(id: UUID(), name: "普通任务", prompt: "原样回写我",
                                        cron: "0 6 * * *", projectId: nil)
            ds.scheduler.scheduledTasks.append(dsPlain)
            try? ds.persistence?.upsertScheduled(dsPlain)
            var dsPlainEdited = dsPlain
            dsPlainEdited.prompt = "用户改过的新指令"
            ds.scheduler.updateScheduled(dsPlainEdited)
            let dsPlainBack = ds.scheduledTasks.first { $0.id == dsPlain.id }
            check(dsPlainBack?.prompt == "用户改过的新指令",
                  "P15.6b 反例: 普通任务的指令**照常回写**（归一化只对 dream 生效）")
            check(ds.scheduler.buildScheduledPrompt(dsPlainEdited) == "用户改过的新指令",
                  "P15.6b 反例: 普通任务 fire 拿到的就是 `task.prompt` 本身")
        }
    }
}
