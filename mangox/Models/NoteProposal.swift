import Foundation

// MARK: - 提案的状态

/// 提案的状态。**本版只剩一个值。** `rawValue` 小写且**是落库字符串**
/// （同 `KnowledgeKind.tag` 那条判据: 它不是展示层的东西, 改它要有数据迁移）。
///
/// ⚠️ **P15.8/5f（2026-10-13 boss 推翻 P15.4）：「终态」这个概念整条取消。**
/// 原设计（P15.4）是 `accepted` / `dismissed` 两个终态**留在表里**、界面整行降档显示,
/// 好让「我不想做这个决定」与「我还没做决定」分得开。boss 的判据把这一层推翻了:
///
/// - **丢弃** = 我不想做这个决定 ⇒ 这条没有任何后续动作 ⇒ 留着就是噪音;
/// - **采纳** = 产出**已经变成笔记区里的一篇** ⇒ 记录在磁盘上, 提案行是冗余。
///
/// ⇒ 收件箱只回答一个问题:「还剩几件等我拍」。**拍过板的行直接删掉**（见
/// `KnowledgeStore.removeProposal`）, 于是表里恒只有 `pending` — 这个枚举恒取此值。
///
/// 为什么**不把枚举连列一起删**: `note_proposals.status` 是已发版的列
/// （DB 判据: 列只增不删 —— 旧版打开新库会立刻崩）。列留着, 词汇也就留着。
enum NoteProposalStatus: String {
    case pending
}

// MARK: - 提案的三类动作

/// 提案的四类动作 —— 前三件是 P15 §04 批 3 那句「三件事一起上、不拆」;
/// `delete` 是 P17 补的第四件（当时那版没有"删", 一篇"整条没用了"的笔记只能被硬塞进"换"里）。
///
/// `rawValue` 小写且恒 ASCII: 它同时是**落库字符串**与**扩展写给 spool 的 token**
/// （`mangox-dream.ts` 那侧写的就是这三个词）⇒ 改名 = 两边一起改 + 数据迁移。
enum NoteProposalKind: String, CaseIterable {
    /// 增: 从会话里浮出还没成篇的结论, 落一篇**新**笔记。
    /// `targetPath` 指向一个**还不存在**的文件 ⇒ 它没有"那一版", 也就没有指纹。
    case insight
    /// 并: 跨笔记合并 —— 两篇讲同一件事, 并成一篇（被并掉的那篇留旧版进 `note_revisions`）。
    case merge
    /// 换: 用新值覆盖过期值（旧值留旧版）。
    case replace
    /// 删: 这一篇整条不再有用 —— 它不是「该改」的另一侧（"改"要求还有要说的, "删"要求没有了）。
    /// 它**不要 `content`**（产出是"文件进废纸篓", 没有新字节可写）,
    /// 但**要 `base_hash`** —— 删的是不是它读到的那一版, 是这个动作唯一的判据。
    case delete
}

// MARK: - 来源指针

/// 一条提案的**来源指针** —— 「拿不出指针的提案不入表」那条（§05）的载体。
///
/// 为什么要一个 `kind`: merge 的来源是**笔记**而不是会话, 而界面上那两行长得完全不同
/// （「来源 · 3 个会话」/「来源 · 2 篇笔记」）。靠 `ref` 的形状去猜是哪种, 迟早猜错。
/// - Note: `Codable` 是给落库用的 —— `note_proposals.sources` 是一列 JSON 文本
///   （长度不定、条数不定、永远只整块读写 ⇒ 拆成关联表要为此养一张表和一套 join, 换不到什么）。
struct ProposalSource: Equatable, Codable {
    enum Kind: String, Codable {
        case session
        case note
    }

    let kind: Kind
    /// 会话 id, 或**笔记根内相对路径**。
    let ref: String
    /// 原话摘录。可空 —— 强制它只会让模型编一句来凑。
    let quote: String
}

// MARK: - 待落表的提案

/// 一条**待落表**的提案 —— spool 里那一行解析出来、但还没盖章的那一半。
///
/// 与 `NoteProposal` 拆开的理由: spool 是**扩展写的**, 而扩展不知道 App 的
/// `id` / 时间 / 状态 / 日志会话是哪个。盖章发生在 ingest 那一步。合成一个类型
/// 会让解析函数被迫接受四个它本该看不见的参数。
struct NoteProposalDraft: Equatable {
    /// `note:global` / `note:project:<pid>` —— 由 `target_path` **反解**得到, **不是**模型给的。
    let rootId: String
    let kind: NoteProposalKind
    /// **根内相对路径**（不是绝对路径）。落库形状与 `note_revisions.path` 一致 ——
    /// 绝对路径会把"项目当时在哪个目录"烤进数据里, 而 `rootId` 已经表达了归属。
    let targetPath: String
    /// merge / replace / delete 必填（乐观并发的本地版）; insight 恒空串 —— 目标文件还不存在, 任何指纹都是错的。
    let baseHash: String
    let title: String
    let content: String
    let reason: String
    let sources: [ProposalSource]
}

// MARK: - 落表后的提案

/// 落表后的一条提案（`note_proposals` 的一行）。
///
/// - Important: `content` 是**整篇新内容**, 不是 diff —— 与 `NoteRevision` 同口径:
///   diff 只适合"展示", 不适合"回放"。本版连展示都还没有（并排 diff 属 P15.4）。
struct NoteProposal: Equatable, Identifiable {
    let id: UUID
    let rootId: String
    let kind: NoteProposalKind
    let targetPath: String
    let baseHash: String
    let title: String
    let content: String
    let reason: String
    let sources: [ProposalSource]
    let createdAt: Date
    /// 恒 `.pending`（见 `NoteProposalStatus`）—— 本版没有任何终态行。
    let status: NoteProposalStatus
    /// 产生它的那次 dream 运行的日志会话 id（用于"这批复核一下"的回查入口）。
    let sessionId: String
}

// MARK: - 拒收原因

/// spool 一行被拒的原因 —— **数据, 不是文案**（同 `NoteWriteRejection` 的形状）。
///
/// ⚠️ 本文件**不在** `gen_strings.py` 的 `EXCLUDE_FILES` 里 ⇒ 在这里拼一句中文人话
/// 就得配一个 `L()`, 而那是 View 侧的事（拒绝原因的人话归 `KnowledgeView` 拼）。
///
/// 每条都对应一个**真会发生**的坏结局, 不是防御性代码:
/// - `unknownRoot` 是**唯一一道**"模型提的路径落在我们的目录里吗"的闸门。扩展那侧不做这个
///   判断（它是哑的, 见 `mangox-dream.ts`）⇒ 这道门漏了, 提案会指到用户的任意文件上去。
/// - `baseHashRequired`: 少了它, P15.4 的采纳就只能盲写 ⇒ 把用户的外部改动静默盖掉。
/// - `emptySources`: 「拿不出指针的提案不入表」—— 这是"新洞见把没说过的话总结成事实"那条
///   风险（§05）唯一的结法。
enum ProposalRejection: Equatable, Error {
    case notJSON
    case notAnObject
    case kindUnknown(String)
    case missingField(String)
    case emptyContent
    case emptySources
    case sourceKindUnknown(String)
    /// merge / replace / delete 少了 `base_hash`。
    case baseHashRequired
    /// `target_path` 不是绝对路径（扩展/模型写成了相对路径 ⇒ 根都定不下来）。
    case targetNotAbsolute
    /// `target_path` 不在任何笔记根下（含"标准化之后跑出根外"）。
    case unknownRoot
}

/// 第 `line` 行（1 起）为什么被拒。
///
/// 带行号是为了能指回 spool 文件 —— ingest 之后 spool 就被删了, 所以这条记录要在
/// **删之前**变成日志会话里的一句话（否则用户只看到"少了两条", 不知道少在哪）。
struct SpoolRejection: Equatable {
    let line: Int
    let reason: ProposalRejection
}

// MARK: - spool 解析（纯函数）

/// spool 文件的解析口径 —— **一处定义, 扩展侧不重复**。
///
/// 形态: 一条提案一行 JSON（JSONL）。为什么不是一个大 JSON 数组:
/// 扩展是**逐条追加**写的, 数组每追加一条就要重写整个文件 —— 而 spool 的存在意义
/// 正是"进程崩了也不丢已产出的部分"。逐行追加是这个语义最便宜的实现。
enum NoteProposalSpool {

    /// 逐行解析。**空行不是错**（尾部换行会造出一行）, 其余每一行要么产出、要么带行号被拒。
    ///
    /// 纯函数（不碰磁盘、不碰 DB）⇒ 冒烟可以直接喂字符串造反例, 不需要一个真跑起来的 dream。
    static func parse(_ text: String,
                      roots: [(id: String, path: String)])
        -> (items: [NoteProposalDraft], rejects: [SpoolRejection]) {
        var items: [NoteProposalDraft] = []
        var rejects: [SpoolRejection] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            do {
                items.append(try parseLine(line, roots: roots))
            } catch let e as ProposalRejection {
                rejects.append(SpoolRejection(line: i + 1, reason: e))
            } catch {
                rejects.append(SpoolRejection(line: i + 1, reason: .notJSON))
            }
        }
        return (items, rejects)
    }

    /// 绝对路径 → `(rootId, 根内相对路径)`。`nil` = 不在任何笔记根下。
    ///
    /// ⚠️ **取最长匹配的那个根**: 两个根有可能嵌套（项目就建在 `~/.mangox/note/` 底下这种
    /// 极端情形）, 取第一个匹配会把归属判错 —— 而归属错 = P15.4 采纳时写错目录。
    /// 判据用"相对路径更短", 它等价于"根更长", 但不用再去比字符串长度。
    ///
    /// - Note: 越界（`..` 跑出根外）到这个函数时**已经**不匹配了 —— `standardizingPath`
    ///   先把 `..` 折掉, 折完还在根前缀里才算数。所以这里没有单独的"出根"分支,
    ///   那种输入落进 `unknownRoot`。写盘前 `noteAbsPath` 还会再验一次（守卫 25）。
    static func relativeLocation(absolutePath: String,
                                 roots: [(id: String, path: String)])
        -> (rootId: String, relativePath: String)? {
        let raw = absolutePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("/") else { return nil }
        let abs = (raw as NSString).standardizingPath
        var best: (rootId: String, relativePath: String)?
        for root in roots {
            let rootPath = (root.path as NSString).standardizingPath
            guard !rootPath.isEmpty, abs.hasPrefix(rootPath + "/") else { continue }
            let rel = String(abs.dropFirst(rootPath.count + 1))
            guard !rel.isEmpty else { continue }
            if best == nil || rel.count < best!.relativePath.count { best = (root.id, rel) }
        }
        return best
    }

    // MARK: 单行

    private static func parseLine(_ line: String,
                                  roots: [(id: String, path: String)]) throws -> NoteProposalDraft {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw ProposalRejection.notJSON
        }
        guard let dict = obj as? [String: Any] else { throw ProposalRejection.notAnObject }

        let kindRaw = try required(dict, "kind")
        guard let kind = NoteProposalKind(rawValue: kindRaw) else {
            throw ProposalRejection.kindUnknown(kindRaw)
        }
        let target = try required(dict, "target_path")
        // content **不 trim 后落库**: 它是要写进文件的那份字节, 首尾空行是作者写的。
        let content = raw(dict, "content")
        // `delete` 没有新字节可写（产出是"文件进废纸篓"）⇒ 空的 `content` 对它是**正常**的。
        // 其余三类都要求非空: 一份"要写进去的东西"若是空的, 采纳的结果是**把这篇文章清空** ——
        // 而那多半不是提案的意思（真是想清空, 那正是 `delete`）。
        if kind != .delete {
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposalRejection.emptyContent
            }
        }
        // `base_hash` 是**结构上可选**的键（insight 没有它）, 所以不能走 `required` ——
        // 走 `required` 的话缺失会被通用的 `missingField` 拦掉, 而 `baseHashRequired`
        // 就成了一个**没有生产者的枚举**（实测抓到过: 判据红的不是这条, 是 missingField）。
        let baseRaw = raw(dict, "base_hash").trimmingCharacters(in: .whitespacesAndNewlines)
        if kind != .insight, baseRaw.isEmpty { throw ProposalRejection.baseHashRequired }
        // insight 的目标是**新文件** ⇒ 任何指纹都是错的, 归空（归一化, 不是静默丢弃）。
        let baseHash = kind == .insight ? "" : baseRaw
        let sources = try parseSources(dict["sources"])
        guard let loc = relativeLocation(absolutePath: target, roots: roots) else {
            throw target.hasPrefix("/") ? ProposalRejection.unknownRoot
                                        : ProposalRejection.targetNotAbsolute
        }
        return NoteProposalDraft(
            rootId: loc.rootId,
            kind: kind,
            targetPath: loc.relativePath,
            baseHash: baseHash,
            title: raw(dict, "title").trimmingCharacters(in: .whitespacesAndNewlines),
            content: content,
            reason: raw(dict, "reason").trimmingCharacters(in: .whitespacesAndNewlines),
            sources: sources)
    }

    /// 来源数组。**空数组 = 拒** —— 这就是「拿不出指针的提案不入表」。
    /// `kind` 缺省成 `session`（模型最常见的用法, 缺省它比缺省成"拒绝"有用）。
    private static func parseSources(_ rawValue: Any?) throws -> [ProposalSource] {
        guard let arr = rawValue as? [[String: Any]], !arr.isEmpty else {
            throw ProposalRejection.emptySources
        }
        return try arr.map { item in
            let ref = raw(item, "ref").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ref.isEmpty else { throw ProposalRejection.missingField("sources[].ref") }
            let kindRaw = raw(item, "kind").trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: ProposalSource.Kind
            if kindRaw.isEmpty {
                kind = .session
            } else if let parsed = ProposalSource.Kind(rawValue: kindRaw) {
                kind = parsed
            } else {
                throw ProposalRejection.sourceKindUnknown(kindRaw)
            }
            return ProposalSource(kind: kind, ref: ref,
                                  quote: raw(item, "quote")
                                      .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func raw(_ dict: [String: Any], _ key: String) -> String {
        (dict[key] as? String) ?? ""
    }

    private static func required(_ dict: [String: Any], _ key: String) throws -> String {
        let v = raw(dict, key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { throw ProposalRejection.missingField(key) }
        return v
    }
}

// MARK: - 与展示形状无关的一条判据

extension NoteProposalDraft {
    /// 这条提案的目标是不是**一篇还不存在的笔记**（= insight）。
    ///
    /// 放在模型层而不是各调用点各写一遍: 它同时是"要不要读 base_hash"与
    /// "P15.4 采纳时走 create 还是走 save"两个判断的同一个前提。
    var createsNewNote: Bool { kind == .insight }
}
