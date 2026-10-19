//
//  caseScheduleCron —— 定时任务: cron 解析 / 下次运行 / 落库列
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家 + dir→fixturesRoot 等价替换）。
//  原位替换为 `await caseScheduleCron()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseScheduleCron() async {
        // —— ① 防 App Nap 的断言 ——
        let napDir = fixtureDir("p17nap")
        let napStore = ChatStore(transport: MockTransport(), dbPath: napDir + "/p17nap.db",
                                 managedExtensionsDir: napDir + "/ext")
        napStore.mailbox.stopScheduler()
        // `ChatStore` 初始化里就调了 `startScheduler`(589 行) ⇒ 此刻本来就该持有一条。
        check(napStore.scheduler.napAssertion != nil,
              "P17 nap: ChatStore 一起来就持有防降频断言（startScheduler 那条路）")
        napStore.scheduler.stopScheduler()
        check(napStore.scheduler.napAssertion == nil,
              "P17 nap: stopScheduler **交还**断言（不停 ⇒ 重复构造 store 会越堆越多）")

        napStore.scheduler.startScheduler()
        let napFirst = napStore.scheduler.napAssertion
        check(napFirst != nil, "P17 nap: startScheduler 之后持有一条断言")
        napStore.scheduler.startScheduler()          // 幂等
        // ⚠️ 判据带上 `napFirst != nil`: 只比 `===` 的话, 整段断言被删掉时
        //    (`napFirst` 与 `napAssertion` 双双为 nil) 会 `nil === nil` 判**绿** —— 假绿。
        check(napFirst != nil && napStore.scheduler.napAssertion === napFirst,
              "P17 nap: 重复 start **不堆断言**（还是同一条对象 ⇒ 幂等; 去掉 `if napAssertion == nil` 这里立刻红）")
        napStore.scheduler.stopScheduler()
        check(napStore.scheduler.napAssertion == nil, "P17 nap: 再 stop 又交还")

        // ⚠️⛔ 这里原来有一格"选项**不含** `IdleSystemSleepDisabled`"的断言, **2026-10-15 已按
        //    boss 拍板移除**。它守的是"断言有没有偷偷变成**会禁用系统睡眠**的那一档"
        //    （`.userInitiated` 名字看着无害, 定义里却含 `IdleSystemSleepDisabled` ⇒ 会让
        //    Mac 永不休眠, 笔记本拔电还醒着烧电）。移除理由: 它是**全仓唯一**用代码引用那个
        //    符号的地方（生产代码只在 `SchedulerService.swift:119` 的注释里提它）, boss
        //    担心 GitHub CI 那条 `scripts/smoke/run.sh` 在别的 SDK 上编不过。
        //
        //    ⛔ **留下的缺口 —— 别以为被下面那条盖住了**: `contains(.userInitiatedAllowing…)`
        //    **守不了**这件事, 两个常量的位是**交叠**的:
        //      UserInitiated                      = 0x00FFFFFF | (1<<20)  = 0x00FFFFFF
        //      UserInitiatedAllowingIdleSystemSleep = 0x00FFFFFF & ~(1<<20) = 0x00EFFFFF
        //    而 `OptionSet.contains` 判的是"**位有交集**" ⇒ 真换成 `.userInitiated`, 它**照样绿**。
        //    ⇒「选项有没有被改成会禁睡眠的那一档」现在**没有自动判据**, 只能靠 review 看
        //    `SchedulerService.swift:119` 那段注释与常量本身。
        //    要补回同一道守卫、又不碰任何 SDK 符号, 一行就够:
        //      napSuppressionOptions.rawValue & (1 << 20) == 0
        //    （`1 << 20` 就是 `NSActivityIdleSystemSleepDisabled` 那一位; 纯 UInt64 运算,
        //    与符号的可用性 / 弃用标注完全无关）。**待 boss 定, 当前未加。**
        check(SchedulerService.napSuppressionOptions.contains(.userInitiatedAllowingIdleSystemSleep),
              "P17 nap: 且确实是 userInitiated 那一档（不是被悄悄降成 .background）")
        check(SchedulerService.napSuppressionReason == "MangoX scheduled tasks",
              "P17 nap: reason 是恒英文常量（它进 pmset / 活动监视器, 不该被 L10n 改）")

        // —— ② 漏跑清单: 纯函数四边界 ——
        // 固定锚点「今天 12:00」⇒ 判据不随跑的时刻漂。
        let mfCal = Calendar.current
        let mfDay = mfCal.startOfDay(for: Date())
        func mfAt(_ daysAgo: Int, _ hour: Int) -> Date {
            let d = mfCal.date(byAdding: .day, value: -daysAgo, to: mfDay)!
            return mfCal.date(byAdding: .hour, value: hour, to: d)!
        }
        let mfNow   = mfAt(0, 12)          // 今天 12:00
        let mfFloor = mfNow.addingTimeInterval(-7 * 86400)

        func mfTask(cron: String, lastRunAt: Date?, createdAt: Date,
                    enabled: Bool = true, projectId: UUID? = nil) -> ScheduledTask {
            var t = ScheduledTask(id: UUID(), name: "mf", prompt: "x", cron: cron,
                                  projectId: projectId)
            t.lastRunAt = lastRunAt
            t.createdAt = createdAt
            t.enabled = enabled
            return t
        }
        let mfOld = mfAt(10, 0)            // 出生在 10 天前（够老, 不干扰 lastRunAt 的判据）

        // ⓐ 正例: 每天 03:00, 上次真跑在 3 天前的 03:00 ⇒ 该跑没跑的是后三天
        let mfA = SchedulerService.missedSummary(
            for: mfTask(cron: "0 3 * * *", lastRunAt: mfAt(3, 3), createdAt: mfOld),
            now: mfNow, floor: mfFloor, ackAt: nil)
        check(mfA?.count == 3,
              "P17 漏跑: 每天 03:00 + 上次跑在 3 天前 ⇒ **恰好 3 次**（实测 \(mfA?.count ?? -1)）")
        check(mfA?.last == mfAt(0, 3),
              "P17 漏跑: 最近一次 = **今天 03:00**（补跑要跑的就是它; 清单只留这一条时刻）")

        // ⓑ `createdAt` 兜底: 新建任务从没跑过 ⇒ 只从出生那刻算起。
        //    没有这一格, 一个 5 分钟前建的任务会报出 7 天内每一个 03:00 ⇒ 纯误报。
        let mfB = SchedulerService.missedSummary(
            for: mfTask(cron: "0 3 * * *", lastRunAt: nil, createdAt: mfAt(0, 6)),
            now: mfNow, floor: mfFloor, ackAt: nil)
        check(mfB == nil,
              "P17 漏跑: 今天 06:00 建、从没跑过 ⇒ **零漏跑**（03:00 在它出生之前; 拿掉 createdAt 这里立刻红）")

        // ⓒ `ackAt` 兜底: 昨天 12:00 认过账 ⇒ 只剩今天那一次。
        //    这正是「忽略」按钮要的效果。
        let mfC = SchedulerService.missedSummary(
            for: mfTask(cron: "0 3 * * *", lastRunAt: mfAt(3, 3), createdAt: mfOld),
            now: mfNow, floor: mfFloor, ackAt: mfAt(1, 12))
        check(mfC?.count == 1,
              "P17 漏跑: 昨天 12 点认过账 ⇒ 只剩今天一次（实测 \(mfC?.count ?? -1)）")

        // ⓓ 反向: 停用的 / cron 非法的 ⇒ 一律不进清单（与调度器跳过它们同一个判据）
        check(SchedulerService.missedSummary(
                for: mfTask(cron: "0 3 * * *", lastRunAt: mfAt(3, 3), createdAt: mfOld, enabled: false),
                now: mfNow, floor: mfFloor, ackAt: nil) == nil,
              "P17 漏跑: **停用的**任务不进清单")
        check(SchedulerService.missedSummary(
                for: mfTask(cron: "不是 cron", lastRunAt: mfAt(3, 3), createdAt: mfOld),
                now: mfNow, floor: mfFloor, ackAt: nil) == nil,
              "P17 漏跑: **cron 非法**不进清单")

        // ⓔ 回溯上限: 出生在 30 天前且从没跑过 ⇒ 被 floor 截到最近 7 天, 不能一路回到 30 天前
        let mfE = SchedulerService.missedSummary(
            for: mfTask(cron: "0 3 * * *", lastRunAt: nil, createdAt: mfAt(30, 0)),
            now: mfNow, floor: mfFloor, ackAt: nil)
        check(mfE?.count == 7,
              "P17 漏跑: 出生在 30 天前 ⇒ 被上限截到 **7 次**（实测 \(mfE?.count ?? -1); 拿掉 floor 这里会变成 31 —— 不是 30: createdAt 在那天 00:00, 窗口里那天 03:00 也算一个)")

        // —— ③ 集成: 清单 → 忽略 → **落库** ——
        // 拉锯点在最后一格: 只断言"忽略后清单空了"是**假绿** —— 内存里清掉也能过。
        // 必须**重建一个 store** 才证明 ack 真的写进了 settings KV。
        let mfId = UUID()
        var mfReal = ScheduledTask(id: mfId, name: "落库用例", prompt: "x",
                                   cron: "0 3 * * *", projectId: nil)
        mfReal.lastRunAt = mfAt(3, 3)
        mfReal.createdAt = mfOld
        napStore.scheduler.scheduledTasks = [mfReal]
        try? napStore.persistence?.upsertScheduled(mfReal)
        napStore.scheduler.refreshMissedFires(now: mfNow)
        check(napStore.missedFires.count == 1 && napStore.missedFires.first?.taskId == mfId,
              "P17 漏跑: refresh 之后清单里就是它（实测 \(napStore.missedFires.count) 条）")

        // 项目已删的**不算漏跑** —— 它每次到点都被 `recordFireSkip` 跳过, 而那里不写
        // `lastRunAt` ⇒ 不排除的话它会永远赖在清单里。
        var mfOrphan = ScheduledTask(id: UUID(), name: "孤儿", prompt: "x",
                                     cron: "0 3 * * *", projectId: UUID())
        mfOrphan.lastRunAt = mfAt(3, 3)
        mfOrphan.createdAt = mfOld
        napStore.scheduler.scheduledTasks.append(mfOrphan)
        napStore.scheduler.refreshMissedFires(now: mfNow)
        check(!napStore.missedFires.contains { $0.taskId == mfOrphan.id },
              "P17 漏跑: **项目已删**的任务不进清单（那是配置坏了, 不是漏跑）")
        napStore.scheduler.scheduledTasks.removeAll { $0.id == mfOrphan.id }

        napStore.scheduler.ignoreMissedFire(mfId)
        check(napStore.missedFires.isEmpty,
              "P17 漏跑: 忽略之后清单立刻空")

        let napStore2 = ChatStore(transport: MockTransport(), dbPath: napDir + "/p17nap.db",
                                  managedExtensionsDir: napDir + "/ext")
        napStore2.mailbox.stopScheduler()
        napStore2.scheduler.refreshMissedFires(now: mfNow)
        check(napStore2.missedFires.isEmpty,
              "P17 漏跑: 忽略**落了库** —— 重建 store 后它不再提示（只在内存里清 ⇒ 这里立刻红）")
        napStore.scheduler.stopScheduler()
        napStore2.scheduler.stopScheduler()
    }
}
