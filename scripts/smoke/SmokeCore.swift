//
//  SmokeCore.swift —— 冒烟的基础设施（2026-10-19 从 smokeMain.swift 拆出）
//
//  只放**与具体用例无关**的东西: check / report / fixtureDir / waitUntil / hasText / 失败现场修剪。
//  ⚠️ 新用例请放 scripts/smoke/cases/, **不要**回填 smokeMain.swift（那里有体量棘轮门）。
//

import Foundation

extension SmokeMain {
    /// 一个用例的夹具目录。**必定落在临时目录下** —— 这条是硬约束, 不是习惯。
    ///
    /// - 历史: 这 9 处（t25b / t26b / t27 / t28 / tp9 / tp9b / tp10 / tp10b / tperf）原本
    ///   把夹具建在 `NSHomeDirectory() + "/.mangox/"` 里且**从不清理**, 于是冒烟每跑一次就往
    ///   用户的 app 数据目录里撒 9 个 `smoke-*`。实测累积 154 个、68 MB, 而它**不会有任何红灯**
    ///   （夹具建得成、断言全绿、退出码 0）。
    /// - 为什么可以搬走: 这些用例一律**显式传** `dbPath` / `managedExtensionsDir`, 夹具位置与
    ///   生产路径无关；`T-P9` 那条 `/.mangox/exports/` 断言取的是 `NSHomeDirectory()`(生产路径),
    ///   也不受影响。
    /// - 为什么不干脆用各自的 `NSTemporaryDirectory()`: 散在各处就又是一份"要记得清"的清单。
    @MainActor
    static func fixtureDir(_ tag: String) -> String {
        let base = fixturesRoot.isEmpty ? NSTemporaryDirectory() : fixturesRoot
        let path = base + "/\(tag)-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// 剖析开关：`MANGOX_SMOKE_PROFILE=1` 时，**慢断言**会在行尾带上耗时。
    ///
    /// ⚠️ 为什么默认关: 常态是微秒级, 每条都标反而看不清; 更要紧的是**输出必须与不开时逐字节
    ///    相同** —— 这个框架自己也被门禁断言（条数、报告格式），多打一个字都可能让别的判据红。
    /// 用途: 一次 CI 7 分钟, 一直没人知道花在哪。开它跑一次就知道（2026-11-19: 2706 条合计
    /// 107s ⇒ 平均 39ms/条, 而纯函数断言本该是微秒级 ⇒ 慢的是一小撮"重断言", 不是条数）。
    private static let profileOn = ProcessInfo.processInfo.environment["MANGOX_SMOKE_PROFILE"] == "1"
    /// 上一条断言打完的时刻。等待类断言（`waitUntil` / `Task.sleep`）的时间会算在**下一条**头上
    /// —— 这是有意的: 那条等待本来就是它的一部分。
    private static var lastTick = Date()

    /// 断言总数 —— 每次收尾都打出来（见 `report()`）。
    private static var checkCount = 0

    /// 上一个记下的条数。**不是门**, 只是让"涨了"这件事在每次 CI 日志里露出来。
    ///
    /// ⚠️ 为什么不做成硬上限（2026-11-19 boss 明令）: 卡死条数会让**正当的新判据**也被迫先
    ///    去别处凑数合并, 那种门最后一定被绕过（改常量就绿了）。他要的是**严格限制** ——
    ///    规则 + 可见, 而不是红灯。
    /// 规则: 加判据前先合并（见 `scripts/smoke/run.sh` 文件头七条）；合并省下来的空档,
    ///    把这行改成实测值, 下次再涨就会被日志点名。
    /// 说明: 条数**不是** CI 时间的主因 —— 2707 条里 2647 条合计只占 5 秒, 耗时在 2 条重
    ///    断言与 `swiftc` 编译。这个数管的是**维护成本**（每条都要有人读、有人判断红了是
    ///    改坏了还是判据过期了）。
    private static let recordedCount = 2714

    @MainActor
    static func check(_ cond: Bool, _ what: String) {
        checkCount += 1
        var line = (cond ? "PASS" : "FAIL") + " - " + what
        if profileOn {
            let now = Date()
            let ms = Int(now.timeIntervalSince(lastTick) * 1000)
            lastTick = now
            // 只标 ≥100ms 的: 比这更小的排队抖动能把日志冲成噪音, 而"慢了"的量级是秒。
            if ms >= 100 { line += "  [\(ms)ms]" }
        }
        print(line)
        if !cond { failures.append(what) }
    }

    @MainActor
    static func waitUntil(_ cond: @MainActor () -> Bool, timeout: Double = 20) async -> Bool {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @MainActor
    static func hasText(_ msgs: [ChatMessage], _ substr: String) -> Bool {
        msgs.contains { msg in
            if case .text(let s) = msg.content { return s.contains(substr) }
            return false
        }
    }
    @MainActor
    static func report() -> Never {
        // 登记表被截断 = 一条**悄悄卸掉的门**：某个 case 结尾调了 `report()`（它 exit），
        // 后面的用例一条没跑，而日志照样 "ALL PASS"（2026-10-21 实测，1498 条全绿、T-FOLD 缺席）。
        // ⇒ 这里把"还没跑完"变成红灯，而不是让它看起来像全过。
        if casesRemaining > 0 {
            failures.append("还有 \(casesRemaining) 个用例没跑 —— 某个 case 结尾调了 report() "
                            + "（report = 收尾 + exit，不许当用例结尾；见 scripts/smoke/cases/AllCases.swift）")
        }
        // 条数**只报不判**（2026-11-19 boss: 锁条数不至于, 严格限制即可）。打到 "ALL PASS"
        // 之前, 保持最后一行仍是结论; 涨了就当场点名, 让"顺手加两条"在日志里留下痕迹。
        // ⚠️ 不许改成 failures.append —— 那是把"严格限制"做成"挡路", 而挡路的门会被绕过。
        print("断言 \(checkCount) 条"
              + (checkCount > recordedCount
                 ? "（比上次记录 \(recordedCount) 多 \(checkCount - recordedCount) 条 —— 按规则先合并再新增;"
                   + " 确认要留着就改 SmokeCore.recordedCount）"
                 : ""))
        print(failures.isEmpty ? "\nALL PASS" : "\nFAILURES: \(failures.count)")
        failures.forEach { print(" - " + $0) }
        // 夹具清理 (2026-09-22): **只在全绿时清** —— 失败时留下现场供排查 (那正是最需要它的时刻)。
        // 判据里必须带"在临时目录下"这一条: `fixturesRoot` 万一被人指错, 这句 guard 是唯一防线。
        if fixturesRoot.isEmpty {
            print("(未使用夹具根)")
        } else if !fixturesRoot.hasPrefix(NSTemporaryDirectory()) {
            // 路径不在临时目录下 ⇒ **什么都不动**: 既不删自己的, 也不修剪别人的。
            // 修剪删的是"不是本次建的东西", 所以它比自清更要守这条防线。
            print("(保留夹具目录供排查: \(fixturesRoot))")
        } else {
            if failures.isEmpty {
                try? FileManager.default.removeItem(atPath: fixturesRoot)
                print("(已清理夹具目录 \(fixturesRoot))")
            } else {
                print("(保留夹具目录供排查: \(fixturesRoot))")
            }
            // 2026-10-12 (boss 拍板 "只留最近 3 次失败现场"): 现场数**有界**。
            // ⚠️ 全绿那次也要修剪 —— 否则"旧现场 + 一路全绿"永远掉不下去。实测: 失败现场无人清
            //    会持续累积 (2026-10-12 一次清掉 25 份 / 704 MB), 而那 25 份全是**失败时有意留下**的
            //    (本函数上面那条"只在全绿时清"), 所以它**只能**靠修剪收敛。
            pruneFailureScenes(in: NSTemporaryDirectory(), keeping: fixturesRoot,
                               currentIsKept: !failures.isEmpty)
        }
        exit(failures.isEmpty ? 0 : 1)
    }
    /// 修剪 `dir` 里的失败现场: 最多留 `keepFailureScenes` 份 (含 `current`, 若它被保留)。
    ///
    /// `dir` 由调用方给, **不是**函数自己取 —— 生产传 `NSTemporaryDirectory()`; 判据件传一个夹具
    /// 子目录。否则判据件一跑就会去动真实的现场命名空间 (那里还有本次运行正在用的 `fixturesRoot`)。
    ///
    /// `currentIsKept` = 本次现场**是否留下来了** (失败⇒留, 全绿⇒已删)。**这个减法必须在函数里做**:
    /// 让调用方传"留几份"的话, 迟早有人在全绿那条路上忘掉"本次已经不占名额" ⇒ 每次绿跑白删一份旧现场
    /// (删的是别人的现场, 而且零红灯)。
    ///
    /// 三条硬约束, **少任何一条都跳过**(不报错) —— 修剪是全仓**唯一**一处会删"不是本次建的东西"
    /// 的地方:① 目录名以 `mx-smoke-` 开头 · ② 后缀必须是**能解析的 UUID** (只认前缀的话, 别人建的
    /// `mx-smoke-*` 也会被误删) · ③ 确实是**目录**。
    ///
    /// 排序键 = **创建时间**, 不是目录名 —— 名字里那个 UUID 不带时间信息, 按名字排等于随机。
    /// 取不到创建时间退到修改时间; 两者都取不到 ⇒ 排最后 (不误伤新现场)。
    @MainActor
    static func pruneFailureScenes(in dir: String, keeping current: String, currentIsKept: Bool) {
        let fm = FileManager.default
        let prefix = "mx-smoke-"
        let scenes: [(path: String, born: Date)] = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .compactMap { name -> (String, Date)? in
                guard name.hasPrefix(prefix),
                      UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
                else { return nil }
                let path = dir + name
                guard path != current else { return nil }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                let attrs = try? fm.attributesOfItem(atPath: path)
                let born = (attrs?[.creationDate] as? Date)
                    ?? (attrs?[.modificationDate] as? Date) ?? .distantPast
                return (path, born)
            }
            .sorted { $0.born > $1.born }
        // `current` 若留着, 它**自己占一个名额** ⇒ 别的只能留 `keepFailureScenes - 1` 份。
        let keepOthers = keepFailureScenes - (currentIsKept ? 1 : 0)
        for old in scenes.dropFirst(max(0, keepOthers)) {
            try? fm.removeItem(atPath: old.path)
            print("(已清掉更老的失败现场 \(old.path))")
        }
    }
}
