//
//  CaseExecSnapshot —— P19 S6 执行快照：**不覆盖 / 取最新 / 有上限 / 7 天清理**
//
//  这一组守的是 2026-11-18 review 发现的一条**不可逆**缺陷：
//  快照原来恒写 `<dir>/snapshot.tar.gz`（`tar -czf` 同名覆盖），而 `blocksExecution`
//  只挡 `running` / `resolved` —— `failed` 的结论**允许再执行**。于是：
//    ① 第一次执行前快照 A（未被污染的原始状态）→ 跑一半失败，状态 `failed`；
//    ② 人再点「采纳并执行」→ 快照 B **盖掉 A**，而此刻项目已经被①改过；
//    ③ 从此「回滚」只能回到"半个破坏之后"，原始状态**永久没了**，界面还写着「已回滚」。
//  四步里没有任何一步会报错 —— 所以判据必须钉在**文件系统**上，钉在状态机上看不出来。
//
//  五组（各一个失败模式，不是同一件事的四种写法）:
//    ① 两次快照**都在**（不覆盖）
//    ② `restore` 取**编号最大**那份（最近一次执行前），不是最旧的 —— 否则回滚会把
//       两次执行的改动一起抹掉，而人以为只回滚了最后一次
//    ③ 上限 = 1 号 + 最近 N 份：`不覆盖` 的代价是磁盘增长，没有上限就是另一个 bug
//    ④ 升级前留下的 `snapshot.tar.gz`（无编号）照样能还原
//    ⑤ `purgeExpired` 真的按 7 天清 —— 它**从写下来那天起零调用**（2026-11-18 实测），
//       而时间线上一直在向人承诺「7 天内可回滚」
//
//  ⚠️ 全部走 `undoRootOverride` 重定向: 不重定向就是拿真实的 `~/.mangox/undo` 当夹具（守卫 25）。
//  ⚠️ 每条都**先造后断言**："删完没了"这类话在"前提根本没造出来"时也照样绿。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseExecSnapshot() async {
        print("== T-SNAPSHOT 执行快照 (不覆盖 / 取最新 / 上限 / 过期清理) ==")

        let dir = fixtureDir("p19snap")
        let fm = FileManager.default
        WatchExecService.undoRootOverride = dir + "/undo"
        defer { WatchExecService.undoRootOverride = nil }

        // ── ① 两次执行 ⇒ 两份快照（不覆盖） ────────────────────────────────
        let proj = dir + "/repo"
        try? fm.createDirectory(atPath: proj, withIntermediateDirectories: true)
        let target = proj + "/app.txt"
        try? "A".write(toFile: target, atomically: true, encoding: .utf8)
        let fid = UUID()
        _ = try? WatchExecService.snapshot(findingId: fid, projectPath: proj, relativePaths: [])
        try? "B".write(toFile: target, atomically: true, encoding: .utf8)
        _ = try? WatchExecService.snapshot(findingId: fid, projectPath: proj, relativePaths: [])
        let undoDir = WatchExecService.undoDir(findingId: fid)
        func archives(_ d: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: d)) ?? [])
                .filter { $0.hasSuffix(".tar.gz") }.sorted()
        }
        check(archives(undoDir) == ["snapshot-1.tar.gz", "snapshot-2.tar.gz"],
              "T-SNAPSHOT ① 两次执行两份快照（实际 \(archives(undoDir))）—— 同名覆盖的话，"
              + "第二次会盖掉**第一次执行前**的原始状态，而 `failed` 的结论允许再执行")

        // ── ② 回滚取「最近一次执行前」那份 ─────────────────────────────────
        // 现在的文件是 B（第二次快照那一刻的内容）；改成 C 再回滚 ⇒ 必须回到 B。
        try? "C".write(toFile: target, atomically: true, encoding: .utf8)
        let restored2 = (try? WatchExecService.restore(findingId: fid)) ?? false
        let text2 = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        check(restored2 && text2 == "B",
              "T-SNAPSHOT ② 回滚取**编号最大**的那份（期望 B，实际 \(text2)）—— "
              + "取最旧那份会把两次执行的改动一起抹掉，而人以为只回滚了最后一次")

        // ── ③ 上限：1 号 + 最近 N 份 ───────────────────────────────────────
        for _ in 0..<5 { _ = try? WatchExecService.snapshot(findingId: fid, projectPath: proj, relativePaths: []) }
        let capped = archives(undoDir)
        check(capped.count == WatchExecService.archiveKeepRecent + 1,
              "T-SNAPSHOT ③ 同一件事最多留 \(WatchExecService.archiveKeepRecent) + 1 份"
              + "（实际 \(capped.count) 份）—— 不设上限的话每次执行多一份全量 tar，"
              + "而人只会觉得「磁盘莫名少了空间」")
        check(capped.contains("snapshot-1.tar.gz"),
              "T-SNAPSHOT ③b 1 号（第一次执行前那份）**永不删** —— 删它等于把原始状态又弄丢一次")
        let cappedNums = capped.compactMap { WatchExecService.archiveNumber($0) }
        check(cappedNums.max() == 7,
              "T-SNAPSHOT ③c 刚写的那份（7 号）也在（实际 \(cappedNums.sorted())）"
              + " —— 上限不许把刚写的那份削掉")

        // ── ④ 升级前的老格式（无编号）照样能还原 ───────────────────────────
        let proj2 = dir + "/repo2"
        try? fm.createDirectory(atPath: proj2, withIntermediateDirectories: true)
        let target2 = proj2 + "/old.txt"
        try? "L".write(toFile: target2, atomically: true, encoding: .utf8)
        let legacy = UUID()
        _ = try? WatchExecService.snapshot(findingId: legacy, projectPath: proj2, relativePaths: [])
        let ldir = WatchExecService.undoDir(findingId: legacy)
        try? fm.moveItem(atPath: ldir + "/snapshot-1.tar.gz", toPath: ldir + "/snapshot.tar.gz")
        try? "M".write(toFile: target2, atomically: true, encoding: .utf8)
        let legacyOK = (try? WatchExecService.restore(findingId: legacy)) ?? false
        let legacyText = (try? String(contentsOfFile: target2, encoding: .utf8)) ?? ""
        check(legacyOK && legacyText == "L",
              "T-SNAPSHOT ④ 升级前留下的 `snapshot.tar.gz` 照样能还原（按 0 号算，实际 \(legacyText)）"
              + " —— 认不出老名字 = 升级那一刻所有人的历史快照全废")

        // ── ⑤ 过期清理（7 天）────────────────────────────────────────────
        let oldId = UUID(), freshId = UUID()
        let oldDir = WatchExecService.undoDir(findingId: oldId)
        let freshDir = WatchExecService.undoDir(findingId: freshId)
        try? fm.createDirectory(atPath: oldDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: freshDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)],
                              ofItemAtPath: oldDir)
        let removed = WatchExecService.purgeExpired()
        check(removed == 1 && !fm.fileExists(atPath: oldDir),
              "T-SNAPSHOT ⑤ 过期快照被清（返回 \(removed)）—— 这个函数 2026-11-18 之前**零调用**，"
              + "而时间线上一直写着「7 天内可从收件箱回滚」")
        check(fm.fileExists(atPath: freshDir),
              "T-SNAPSHOT ⑤b 新鲜的留着（按 mtime 判过期，不按编号）")
    }
}
