//
//  PiCompactionBudget.swift
//  **只读**解析 pi 的压缩预算 (`compaction.reserveTokens`), 供底栏显示「压缩线」。
//
//  名字里刻意没有 "Settings": 这个类型**不承载任何设置** —— 它没有 setter、不写盘、
//  也没有对应的 UI。唯一的事是回答"pi 现在这条线在哪"。叫 Settings 会让人以为
//  MangoX 在管压缩配置 (2026-10-17 boss 就按这个名字问过一次)。
//
//  为什么只能"读"、不能"配": 预算是 pi 的**触发条件**
//  (`compaction.md`: contextTokens > contextWindow - reserveTokens)。MangoX 复制一份
//  存进自己的库就是**第二真源** —— 用户改了 pi 那边、或者按 modelOverrides 单独调过,
//  UI 就会显示一条永远不会发生的线。所以这里只解析、只展示, 不写回。
//
//  ⚠️ 读哪两个文件由 `PI_CODING_AGENT_DIR` 决定, **不是**恒定 `~/.pi/agent`:
//     有自管模型时 spawn 会把它指到 `~/.mangox/pi-config`(见 PiRpcTransport :1305),
//     那时 `~/.pi/agent/settings.json` **一个字节都不参与**。照着文档路径硬读 ⇒
//     读到的是一条错的线, 而且零红灯。⇒ 调用方必须把"这次到底用的是哪个 agent 目录"
//     传进来 (`agentDirOverride`), 本文件的 IO 壳不自己猜。
//

import Foundation

enum PiCompactionBudget {

    /// pi 的内置默认 (未配置时的触发线)。数值来自 `docs/compaction.md` 的设置表。
    /// ⚠️ 只放**用得到的**那个数: `keepRecentTokens` 的默认值(20000)与这里的显示无关,
    ///    搬过来就是一个没人读的常量。
    static let defaultReserveTokens = 16384

    // MARK: - 纯函数核心

    /// 解析有效 `reserveTokens`。
    ///
    /// 优先级 (逐字对应 `docs/compaction.md` 的 "Per-model overrides" 段):
    /// "The files merge recursively before lookup, so a global model-specific value
    ///  beats a project-wide fallback."
    /// ⇒ ① 先按 **project 覆盖 global** 递归合并
    ///   ② 合并结果里先查 `compaction.modelOverrides[model].reserveTokens` (精确匹配)
    ///   ③ 再查 `compaction.reserveTokens`
    ///   ④ 都没有 = 内置默认 16384
    ///
    /// `global` / `project` 传 `nil` 表示该文件不存在 (与"空对象"等价)。
    /// 非法值 (负数 / 非整数) 一律当"没配" —— pi 读非法值会直接报错, 那种情况下
    /// 这条线画不画都无所谓, 但**绝不能**把它显示成一个看上去合理的数。
    static func resolveReserveTokens(global: Data?, project: Data?, model: String?) -> Int {
        let merged = merge(parse(global), parse(project))
        let compaction = merged["compaction"] as? [String: Any] ?? [:]
        if let model, let overrides = compaction["modelOverrides"] as? [String: Any],
           let entry = overrides[model] as? [String: Any],
           let n = positiveInt(entry["reserveTokens"]) {
            return n
        }
        if let n = positiveInt(compaction["reserveTokens"]) { return n }
        return defaultReserveTokens
    }

    /// 递归合并: `override` 覆盖 `base`; 两边都是对象时**逐键递归**, 其余情况 override 赢。
    /// (pi 的行为是 "merge recursively", 不是简单的顶层替换 —— 顶层替换会让
    ///  project 只写一条 `compaction.enabled` 就把 global 的 `reserveTokens` 抹成默认。)
    private static func merge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in override {
            if let b = out[k] as? [String: Any], let o = v as? [String: Any] {
                out[k] = merge(b, o)
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func parse(_ data: Data?) -> [String: Any] {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    private static func positiveInt(_ v: Any?) -> Int? {
        let n: Int?
        if let i = v as? Int { n = i }
        else if let d = v as? Double { n = Int(d) }
        else { n = nil }
        guard let n, n > 0 else { return nil }
        return n
    }

    // MARK: - IO 壳

    /// 读盘解析。`agentDirOverride` = 这次 spawn 有没有把 `PI_CODING_AGENT_DIR` 改掉:
    /// - 非 nil: pi 读 `<该目录>/settings.json`, `~/.pi/agent` 完全不参与
    /// - nil   : pi 读 `~/.pi/agent/settings.json`
    /// 项目级 `<projectDir>/.pi/settings.json` 两种情况都会读到 (pi 的 cwd 就是项目目录)。
    static func reserveTokens(agentDirOverride: URL?,
                              projectDir: URL?,
                              model: String?,
                              fileManager: FileManager = .default) -> Int {
        let agentDir = agentDirOverride
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent", isDirectory: true)
        let global = try? Data(contentsOf: agentDir.appendingPathComponent("settings.json"))
        let project = projectDir.map {
            try? Data(contentsOf: $0.appendingPathComponent(".pi/settings.json"))
        } ?? nil
        return resolveReserveTokens(global: global, project: project, model: model)
    }
}
