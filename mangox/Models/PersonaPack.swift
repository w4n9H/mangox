//
//  PersonaPack.swift
//  P11.2a: persona pack —— 人格本体的**文件真源** (`~/.mangox/agent/` 下的一族 md)。
//
//  载体为什么是文件而不是 DB 行 (P11 §2.1): 可 git / 可 diff / 可手改 / **可被任意宿主读** ——
//  换躯干时搬的是"我", 不是一份快照。App 侧只读 (只展示 + 跳转编辑, 双写必漂移, 同 P3.9)。
//
//  本文件只做两件事: ① 解析 frontmatter ② 把正文原样交给组装器当**第一段** (守卫 10)。
//

import Foundation

/// pack 里一个 md 文件 → 一个**只读**条目。
///
/// - Note: 它不是 `KnowledgeItem` —— 没有审核态 / 启停 / 作用域, 也不能被编辑。
///   两者只在**呈现层**合流 (左列"每轮都带上"段), 不在数据层混成一个类型:
///   `KnowledgeItem` 有一整套 DB 语义 (status / enabled / scope / updatedAt), pack 文件没有。
struct PersonaPackEntry: Identifiable, Equatable {
    /// ⚠️ **模型层不再持有标题** (2026-09-23): 行标题是**出厂固定文案**, 归 View 侧
    /// (`PersonaRowText`) —— 它是用户可见文案, 要进词表、要中英各自正确; 而本文件只出数据。
    /// 这里连"标题从哪来"的三态都不留: 判据已不在内容上, 留个枚举只会让人以为还有回落链。
    let fileName: String
    /// frontmatter 之后的正文, 原样 (只 trim 首尾空白)。**这是要进 prompt 的字节**。
    let content: String
    let readWhen: [String]
    let priority: Int
    let layer: KnowledgeLayer
    /// ~~`shared`~~ —— **已于 2026-09-22 (P11.2c) 删除**。
    ///
    /// 它是 Q2b 为"跨宿主同步"预留的位, 而从落地到删除**零消费**: 没有任何逻辑读它、
    /// 没有任何界面显示它、冒烟夹具之外没有任何地方写过它。契约里一个"用户得写、系统不看"
    /// 的字段, 代价是每个读 frontmatter 的人都要多问一句"这个要不要设"。
    /// 真要同步时, 按那时的需求重新设计 —— **别预付**。
    let keys: [String]
    /// frontmatter 破损 (有起始 `---` 没收尾)。**破损文件只展示、不注入** ——
    /// 连 `layer` 都读不出来, 凭什么赌它是常驻。同时它让自检变红 + 保守禁止新建 key (守卫 9)。
    let isBroken: Bool

    var id: String { fileName }

    /// 是否进注入块第一段。两个否定条件, 缺一不可:
    /// - `layer == .ondemand`: 它本身就是磁盘上的文件, "按需读"不需要再复制一份到 L1 落点;
    /// - `isBroken`: 解析不出 `layer`, 不做乐观假设。
    var isResident: Bool { layer == .always && !isBroken }
}

/// 一次**现读磁盘**的解析结果。磁盘为准 —— 用户任何方式改文件, 下轮即生效 (P11 §3.3 同一纪律)。
struct PersonaPack: Equatable {
    var dir: String = ""
    /// 已解析条目 (**含破损文件**, 破损者靠 `isBroken` 区分 —— 它也要在左列可见, 否则用户
    /// 只知道"少了点什么"却看不到"哪个文件坏了", 而修它必须去 Finder)。
    var entries: [PersonaPackEntry] = []
    /// 存在但读不出来 (编码 / 权限)。
    var unreadableFiles: [String] = []
    /// 目录**不在** (尚未建 / 已被移走或删掉; 该路径被同名文件占着时同判)。
    ///
    /// 与"目录在、里面没有一个可载入的 `.md`"分开记 —— 两者的**用户动作不同** (去建目录 / 去放文件),
    /// 而告警要说得清"下一步做什么"。判定必须放在 `load` 的入口: 目录不存在与目录不可读在
    /// `contentsOfDirectory` 那里退化成同一个失败, 事后分不出来。
    var dirMissing: Bool = false
    /// key → 持有它的文件名 (UI 靠它说"请去改那个文件")。
    var keyHolders: [String: String] = [:]

    static let empty = PersonaPack()

    var reservedKeys: Set<String> { Set(keyHolders.keys) }
    /// frontmatter 破损 ⇒ **收紧**: 保守禁止新建任何 key (P11 §8.2 风险 5②)。
    var parseFailed: Bool { entries.contains { $0.isBroken } }
    var brokenFiles: [String] { entries.filter(\.isBroken).map(\.fileName) }
    /// 会进注入块的条目, 已按**确定性**顺序排好 (priority 降序 → 文件名升序)。
    /// 确定性不是审美: 稳定段逐字节稳定 = KV cache 前缀命中, 也是守卫 10 可断言的前提。
    var residentEntries: [PersonaPackEntry] {
        entries.filter(\.isResident).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.fileName < $1.fileName
        }
    }
    /// 什么都没有: 目录不在、也没读到任何条目或读不出的文件。
    ///
    /// ⚠️ 它**只回答"有没有东西"**, 不回答"这是不是个问题" —— 空 pack 意味着 persona 段
    /// **整段消失** (§3.2), 所以要由组装器报出来 (`KnowledgeInjection.personaPackEmpty`)。
    /// 别拿它当"没事"的判据 (它与 `dirMissing` 是两个正交事实)。
    var isEmpty: Bool { entries.isEmpty && unreadableFiles.isEmpty }
    func entry(_ fileName: String) -> PersonaPackEntry? { entries.first { $0.fileName == fileName } }
}

// MARK: - 解析

extension PersonaPack {

    /// 解析一份 md 的 frontmatter 与正文。
    ///
    /// - Important: **全项目只有一个 frontmatter 解析器**。`KnowledgeStore.parseFrontmatterKeys`
    ///   已退化为本函数的薄包装 —— 否则"破损 ⇒ 收紧"这条语义会长出第二份实现,
    ///   而两份实现迟早对同一个文件给出不同判定 (一份说破损、一份说没事), 守卫就漏了。
    struct Parsed {
        /// 没有 frontmatter —— 合法 (正文即全部)。
        var noFrontmatter = false
        /// 有起始 `---` 但没收尾 —— 破损, 调用方必须**收紧**。
        var broken = false
        var readWhen: [String] = []
        var priority: Int?
        var layer: KnowledgeLayer?
        var keys: [String] = []
        var body = ""
    }

    static func parse(_ raw: String) -> Parsed {
        var out = Parsed()
        var lines = raw.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            out.noFrontmatter = true
            out.body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return out
        }
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            out.broken = true
            return out
        }
        out.body = lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 单趟状态机: 一次遍历同时读出 `keys` 与其余字段。
        // **不要拆成两个解析器** —— 它们会对同一个文件给出不同判定。
        enum Collecting { case none, keys, readWhen }
        var collecting = Collecting.none

        func inlineList(_ text: String, after key: String) -> [String]? {
            let rest = String(text.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("[") else { return nil }
            return rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",")
                .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }

        for line in lines[1..<end] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("keys:") {
                if let inline = inlineList(t, after: "keys:") {
                    out.keys.append(contentsOf: inline)
                    collecting = .none
                } else {
                    collecting = .keys
                }
                continue
            }
            if t.hasPrefix("read_when:") {
                if let inline = inlineList(t, after: "read_when:") {
                    out.readWhen.append(contentsOf: inline)
                    collecting = .none
                } else {
                    collecting = .readWhen
                }
                continue
            }
            if t.hasPrefix("priority:") {
                out.priority = Int(String(t.dropFirst("priority:".count)).trimmingCharacters(in: .whitespaces))
                collecting = .none
                continue
            }
            if t.hasPrefix("layer:") {
                let v = unquoted(String(t.dropFirst("layer:".count)).trimmingCharacters(in: .whitespaces))
                out.layer = KnowledgeLayer(rawValue: v)
                collecting = .none
                continue
            }
            // 曾在此解析 `shared:` (P11.2c 删) 与 `summary:` (2026-09-23 删, 行标题改出厂固定表)
            // —— 而这里**不需要**补一个"忽略它们"的分支: 未知顶层键本来就走不出去 ——
            // 下面的 `guard collecting != .none` 与末尾的 `collecting = .none` 已经把它静默跳过
            // ⇒ 用户文件里残留的 `shared: false` / `summary: "…"` 与从前的行为**逐位一致**
            // (不报错、不起作用)。
            guard collecting != .none else { continue }
            if t.hasPrefix("-") {
                let v = unquoted(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                guard !v.isEmpty else { continue }        // `-` 空项: 同旧行为, 记 nothing
                switch collecting {
                case .keys:     out.keys.append(v)
                case .readWhen: out.readWhen.append(v)
                case .none:     break
                }
            } else if !t.isEmpty {
                collecting = .none                        // 列表块结束 (遇到下一个顶层键)
            }
        }
        return out
    }

    private static func unquoted(_ s: String) -> String {
        var v = s
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    /// 现读目录。目录不在 / 不可读 = 空 pack (**不崩、不阻断任何任务**)。
    ///
    /// - Important: "不是错误"说的是**不阻断** (P11 §2.5), 不是"不出声" —— 空 pack 会让 persona 段
    ///   **整段消失**, 而那一整段就是"我"。所以 `load` 只负责**如实记下原因**
    ///   (`dirMissing` / `unreadableFiles`), 响不响、怎么响由组装器定 (§3.2 空 pack)。
    static func load(dir: String) -> PersonaPack {
        var pack = PersonaPack(dir: dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            pack.dirMissing = true
            return pack
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return pack }
        for name in names.sorted() where name.hasSuffix(".md") {
            guard let raw = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else {
                pack.unreadableFiles.append(name)
                continue
            }
            let p = parse(raw)
            let entry = PersonaPackEntry(
                fileName: name,
                // 破损文件的正文 = 整个文件原样 (拿不到边界, 也不该猜) —— UI 展示它才修得动
                content: p.broken ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : p.body,
                readWhen: p.readWhen,
                priority: KnowledgeItem.clampedPriority(p.priority ?? 0),
                // 缺省 `always`: 放进 `~/.mangox/agent/` 的就是人格本体, 它**默认每轮都在场**
                // (P11 §2.2 稳定段 = persona pack + 硬规; 想要按需必须显式写 `layer: ondemand`)
                layer: p.layer ?? .always,
                keys: p.keys,
                isBroken: p.broken)
            pack.entries.append(entry)
            for k in entry.keys where pack.keyHolders[k] == nil { pack.keyHolders[k] = name }
        }
        return pack
    }
}
