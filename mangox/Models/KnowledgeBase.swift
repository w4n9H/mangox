//
//  KnowledgeBase.swift
//  P11.4 知识库档 —— 第三载体: 挂载目录 + 描述 + 索引。
//  设计见 docs/P11-functional-design.md §3.4（表结构 / 扫描契约 / 索引形态 / 只读红线）。
//  P15.1（2026-10-12）: 区的语义从"挂任意目录"收窄成"笔记" —— **两个固定根**（全局 / 项目），
//  路径与描述由 App 写死，用户不再填。见 docs/P15-functional-design.html 门 1 / §03 改动面。
//
//  为什么不把文件搬进 DB: 成套资料有自己的生命周期（可能是 git 仓库、可能别人在维护、
//  可能天天被改）。App **只读不写**, 只做两件事 —— 让 agent 知道它存在（索引）、
//  告诉它去哪读（路径）。
//

import Foundation

/// 一条"根记录"（P15.1 之前叫"挂载记录"）。`{ 目录路径, 描述, 启用 }`。
///
/// - Note: `id` 取 `String` 而不是 `UUID`, 是为了**固定根**能用稳定 id
///   (`"note:global"` / `"note:project:<projectId>"`) —— 固定根不落库、每次现算,
///   但它要能在 UI 里被选中, 所以必须有一个跨启动稳定的身份。
///   （P11.4 的内置 L1 库用的是 `"builtin:l1-global"` / `"builtin:l1-project:<id>"`，
///   已于 P15.5 退休 —— 那个前缀现在没有生产者。）
struct KnowledgeBase: Identifiable, Equatable {
    let id: String
    /// 目录绝对路径（已展开 `~`、已标准化）。**必须绝对** —— 索引里要把它给 agent 去 read。
    var path: String
    /// 描述 —— **必填**。索引里如果只有文件名, agent 拿到的是一串没有语义的字符串。
    var description: String
    var enabled: Bool = true
    /// **固定根** = 路径与描述都由 App 写死（笔记目录）：不可删、描述只读、**不落库**。
    ///
    /// ⚠️ P11.4 时代它同时标着 L1 落盘目录那批内置库 —— 那批已于 P15.5 退休（见
    /// `KnowledgeStore` 文件上方那段），现在 `true` 的**只有两个笔记根**。
    var isBuiltin: Bool = false
    /// 显示名。固定根由 App 写死（`"全局笔记"` / `"项目笔记"`），
    /// 用户挂载库留 `nil` ⇒ 回落到目录末段。
    ///
    /// 为什么要一个独立字段而不是一律取目录末段: 两个笔记根的末段都是 `note`（两个都一样 ⇒
    /// 界面上分不出谁是谁）。**名字是给人看的, 不该从磁盘形状推。**
    var label: String?
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// 描述长度上限。它是"一句话"，不是摘要 —— 长了就开始跟正文抢预算。
    static let descriptionLimit = 200

    // MARK: - 固定根的 id 与文案（P15.1）

    /// 笔记根 id（形状沿用 `builtin:l1-*`: 跨启动稳定、不落库）。
    static let noteGlobalID = "note:global"
    static let noteProjectPrefix = "note:project:"

    /// 两个笔记根的**描述与显示名** —— 由 App 写死。
    ///
    /// ⚠️ 这些字符串住在 `Models/` 里, 而本文件在 `gen_strings.py` 的 `EXCLUDE_FILES` 中 ⇒
    /// **它们不会进词表、也不会被翻译**（与内置 L1 库的描述同款）。这是一条**已知缺口**,
    /// 不是本版新引入的机制 —— 记在 P15 §05 风险里, 要收口得把它们搬到非排除文件。
    static let noteGlobalDescription = "全局笔记 (跟人走): 与具体项目无关的偏好、习惯与结论"
    static let noteProjectDescription = "项目笔记 (跟项目走): 只在本项目成立的事"
    static let noteGlobalLabel = "全局笔记"
    static let noteProjectLabel = "项目笔记"

    /// 项目根的**显示名** —— 唯一的产出点 (P15.8)。
    ///
    /// 为什么要抽成一个函数: 这个名字有**两个读者必须逐字对上** ——
    /// ① `[笔记]` 段里那个根的头一行（`indexBlock` 取 `displayName`）,
    /// ② dream 摘要段头的 `归属 <名字>`。
    /// 模型就是靠"名字相等"把会话映射回根的。两处各写一遍 `"\(title)（项目）"`, 谁改了一边都会让
    /// 归属**静默失效**（名字对不上 ⇒ 模型找不到那个根 ⇒ 回落全局, 与 2026-10-13 报的缺陷
    /// **同一个结局**), 而**零红灯**。
    static func noteRootLabel(projectTitle: String) -> String {
        projectTitle.isEmpty ? noteProjectLabel : "\(projectTitle)（项目）"
    }

    /// 显示名 = `label` → 目录末段（`/Users/x/Documents/notes` → `notes`）。
    var displayName: String {
        if let label, !label.isEmpty { return label }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// 挂载 / 编辑被拒的原因 —— **数据, 不是文案**（同 `KnowledgeStore.KeyRejection`:
/// 域层在 `gen_strings.py` 的 `EXCLUDE_FILES` 里, 在这里拼中文文案 = 隐形漏译）。
enum KnowledgeBaseRejection: Equatable {
    /// 描述为空（必填的理由见 `KnowledgeBase.description`）。
    case emptyDescription
    case descriptionTooLong(limit: Int)
    /// 同一目录挂两次 = 索引里同一份资料出现两遍, 纯浪费每轮预算 ⇒ 拒绝, 不做"谁赢"。
    case duplicatePath(existing: String)
    /// 路径不是一个存在的目录（含"是文件不是目录"）。
    case notADirectory
    /// 固定根（笔记根）不可改 / 不可删（它的路径与描述由 App 写死, 不归用户配置）。
    /// 生产点 = `setKnowledgeBaseDescription` 在 `knowledgeBases`（落库的那批）里查不到这个 id。
    case builtinImmutable
    /// P15.1: 笔记根目录不存在（门 1 的"根在不在"—— 入口**就地建目录**, 不弹错、不判空）。
    case noteRootMissing
}

/// 笔记**写入**被拒的原因 —— 与 `KnowledgeBaseRejection` 同形状: 数据, 不是文案
/// （本文件在 `gen_strings.py` 的 `EXCLUDE_FILES` 里, 在这里拼中文 = 隐形漏译）。
///
/// P15.2 起笔记区**可写**（P15.1 是只读）—— 这个枚举就是那道"写之前先问一遍"的闸门。
/// 每条都对应一个**真发生过或真会发生**的坏结局, 不是防御性代码。
///
/// - Note: 比 `KnowledgeBaseRejection` 多一个 `Error` 遵从 —— 新建要**同时**给出
///   "成了 / 没成"和失败原因, 那用 `Result<String, 本枚举>` 表达最直白。
enum NoteWriteRejection: Equatable, Error {
    /// 标题为空, 或净化后没剩下可用的文件名。
    case emptyTitle
    case titleTooLong(limit: Int)
    /// 同名文件已存在（新建时）—— 不做"覆盖还是改名"的猜测, 让用户自己换个名字。
    case nameCollision(existing: String)
    /// 相对路径逃出了笔记根（`..` / 绝对路径 / 空）。
    case pathEscapesRoot
    /// 磁盘上这篇**不存在**了（编辑期间被外部删掉）。
    case noteMissing
    /// 磁盘上的内容与打开时读到的不一致 ⇒ 外部改过（乐观并发 = Claude Platform `content_sha256` 的本地版）。
    case baseHashMismatch
    case writeFailed
}

/// 一次写入的**来源** —— 判「谁写的」的唯一依据（P15.4 的来源标记读它, **不拿文件去猜**）。
///
/// `rawValue` 小写且**是落库字符串**（同 `KnowledgeKind.tag` 那条判据: 它不是展示层的东西,
/// 改它要有数据迁移）。
enum NoteRevisionOrigin: String, CaseIterable {
    /// 人在 App 里写 / 删。
    case human
    /// dream 提案被采纳后落盘（P15.3 起）。
    case dream
}

/// 一篇笔记的**一个旧版本**（`note_revisions` 的一行）。
///
/// P15.2 起写入路径会记它（覆盖前 / 删除前）—— 这是「不删旧知识」在笔记区的落地:
/// App 改掉的那一版**没有消失**, 它躺在这张表里, 而不是被 `atomically` 换掉后无影无踪。
///
/// - Note: `content` 是**整篇原文**（不是 diff）—— 笔记是纯文本且普遍很小, 存整篇才能保证
///   任何一版都能被原样取出; diff 只适合"展示", 不适合"回放"。
struct NoteRevision: Equatable, Identifiable {
    let id: UUID
    let rootId: String
    let path: String
    let content: String
    let sha256: String
    let writtenAt: Date
    let origin: NoteRevisionOrigin
    /// **这一版内容的来源指针**（P17）—— 会话 id 或笔记相对路径, 形状与 `note_proposals.sources` 同。
    ///
    /// 为什么要它: 来源指针原来只活在 `note_proposals` 里, 而那张表**拍过板就删行**（P15.8/5f）
    /// ⇒ 一篇笔记落地之后, "它当初是凭什么写的"就**没有任何地方记着**了。下一次 dream 想判
    /// "这篇的依据还成立吗", 手里只剩正文 —— 只能重读全文去猜。
    ///
    /// 默认 `[]` = **没有来源记录**, 那是诚实的「空」而不是「缺」: 人写的版本本来就没有指针;
    /// 老库升上来的行也是空的（本列上线之前的事, 谁也补不出来）。
    ///
    /// ⚠️ 有默认值 ⇒ memberwise init 的 `sources` 可省 —— 但全仓**唯一该传它**的地方是
    /// `adoptProposal`（那是唯一"带着指针落盘"的路径）, 冒烟有一条端到端断言钉着它。
    let sources: [ProposalSource]

    /// 显式 init（不靠合成的 memberwise）—— 因为 `sources` 是个**带默认值的 `let`**：
    /// 合成器对这种情况的处理是「**不把它放进 init**」（`let` 有初值 ⇒ 视为已定），
    /// 于是调用点连写都写不进去（`extra argument 'sources' in call`）。写成 `var` 倒是能进，
    /// 但其余六个字段全是 `let`，不该为一个字段破例 ⇒ 显式列出，把默认值挪到参数上。
    /// 现有那些不传 `sources` 的调用点照旧编译得过。
    init(id: UUID, rootId: String, path: String, content: String, sha256: String,
         writtenAt: Date, origin: NoteRevisionOrigin, sources: [ProposalSource] = []) {
        self.id = id
        self.rootId = rootId
        self.path = path
        self.content = content
        self.sha256 = sha256
        self.writtenAt = writtenAt
        self.origin = origin
        self.sources = sources
    }
}

/// 扫描到的单个文档。`relativePath` 用 `/` 分隔且**总是相对库根** ——
/// 索引里给相对路径（深度信息本身有价值: "这是子目录里的"）, 绝对定位靠库的 `path`。
///
/// P15.1 起它同时是"一篇笔记": 多了时间 / 大小 / 标题 / 摘要四项。**这四个字段是索引行与左列
/// 可见性的全部来源** —— 没有它们, 界面上只能显示一串没有年龄、没有语义的文件名。
struct KnowledgeBaseDoc: Equatable {
    let relativePath: String
    /// 1 = 根目录下的直接文件。
    let depth: Int
    /// 文件 mtime —— **陈旧度的唯一权威**（不读用户手写的 `updated:`: 手写字段只要忘一次就永久说谎）。
    /// 遍历时 `attributesOfItem` 已在手 ⇒ 取它**零额外 IO**。
    let modifiedAt: Date?
    let byteCount: Int
    /// 显示名: frontmatter `title:` → 回落"文件名去扩展名"。
    let title: String
    /// 一行摘要: frontmatter `summary:` → 回落正文首行 → 空串（**不发明占位**）。
    let summary: String
}

/// 扫描契约（§3.4）—— **固定参数, 不给旋钮**。全部是 `static` 常量且**只在这里定义一次**:
/// View 的索引预览与组装器的注入文本**调的是同一个函数**, 否则"预览说有 12 个文件、
/// agent 实际看到 9 个"这种不一致会安静地长出来。
enum KnowledgeBaseScan {
    /// 递归深度上限。口径必须明确 —— "递归 3 层"在"含根 / 不含根"两种读法下差一层,
    /// 而差一层就会让人说"我明明放进去了": **根下的直接文件 = 第 1 层**。
    static let maxDepth = 3
    /// 仅文档格式（boss 定: md/txt/html）。`.htm` 与 `.html` 是同一种格式的两种后缀,
    /// 一起收 —— 漏了它只会让人困惑。
    static let extensions: Set<String> = ["md", "txt", "html", "htm"]
    /// 隐藏项由 `hasPrefix(".")` 单独挡（它同时挡 `.git`）。这里列的是"一挂就是代码仓库时
    /// 会占掉索引绝大部分位置、且从来不是资料"的目录名。
    static let excludedNames: Set<String> = ["node_modules", ".build", "DerivedData"]
    /// 每库索引上限: 先按行截, 再按字符兜底。**超限折成"另 N 个", 不静默截断** ——
    /// agent 会把"索引里没有"读成"资料里没有"。
    static let maxLinesPerBase = 120
    static let maxCharsPerBase = 2000
    /// P15.1: 陈旧度阈值（天）。**只在这里定义一次** —— UI 的行尾标记与索引行都读它,
    /// 两处各写一个数就会出现"界面说陈旧、索引里没有"（同 `maxDepth` 的写法）。
    ///
    /// ⚠️ 取 7 天的代价明写在 §05: 一周没更新就挂标记 ⇒ 大部分笔记长期挂着它、用户开始无视。
    /// 可消条件 = 做成可配, 或分两档（7 天「较久」/ 21 天「陈旧」）。
    static let staleAfterDays = 7
    /// 摘要长度上限。索引行是**路标**不是正文 —— 长了就开始跟别的库抢每轮预算。
    static let summaryLimit = 60
    /// 读标题与摘要时**只看文件头这么多字节**（不是全文）。
    ///
    /// ⚠️ 这一条**破了本文件原先那句"只读目录项、不读文件正文"的契约**（原 `:86`）——
    /// 代价已登记在 P15 §05: ① 只有 512 字节 ② 只对已在本轮索引里的文件读。
    static let headBytes = 512
    /// P15.2: 标题长度上限。它同时是**新建时的文件名** —— 超过 80 字在 Finder 里已经没法看,
    /// 而文件系统还有 255 **字节**的硬上限（中文一字 3 字节 ⇒ 80 字 = 240 字节, 顶着上限）。
    static let noteTitleLimit = 80

    /// 注入块的契约 token —— 模型看到的就是这个字面量 ⇒ **恒中文, 不许本地化**
    /// （同 `KnowledgeKind.tag`: 界面语言不许改 prompt 字节）。
    /// P15.1: `[知识库]` → `[笔记]`（门 2: 这一区里只有笔记, 没有知识条目）。
    static let token = "[笔记]"
    /// 索引段的段头。同 `token`, 恒中文。
    /// P15.1 改写: 旧文案「以下是**挂载**的知识库」是"外部只读资料"的语境, 与"笔记"说反话。
    static let segmentHeader = "以下是你的笔记 (只给索引与摘要; 需要正文时用 read 工具按路径取):"

    /// 空根的**文件段替身** (P15.8)。恒中文 —— 它与 `token` 同级: 进的是 prompt 字节。
    ///
    /// 只陈述事实（这个根还没有内容), **不带任何指令** —— "可以往这里写"是 prompt 的职责,
    /// 地图只说地图上的事。措辞刻意与"目录不存在"合并表述: 对模型而言两者一样
    /// （没有可读的东西、但是合法落点), 分开说只是多占预算。
    static let emptyRootLine = "（本根暂无笔记）"

    /// 扫描一个目录。**只读目录项 + 每个文件的前 `headBytes` 字节**（取标题与摘要），
    /// **不读全文** ⇒ 成本与文件总大小无关, 也不需要缓存。
    ///
    /// - 不跟随符号链接: 既防环（自引用目录会让遍历不终止）, 也防越界（链到库外）。
    /// - 结果按 `relativePath` 排序 ⇒ **确定性**（前缀稳定是 cache 的前提, §2.2）。
    static func docs(root: String, maxDepth: Int = KnowledgeBaseScan.maxDepth) -> [KnowledgeBaseDoc] {
        let fm = FileManager.default
        var out: [KnowledgeBaseDoc] = []
        func walk(_ dir: String, _ prefix: String, _ depth: Int) {
            guard depth <= maxDepth else { return }
            let names = (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? []
            for name in names {
                if name.hasPrefix(".") || excludedNames.contains(name) { continue }
                let full = dir + "/" + name
                // `fileExists(isDirectory:)` 会**跟随**链接 —— 要判"它本身是不是链接"只能查属性
                guard let attrs = try? fm.attributesOfItem(atPath: full),
                      let type = attrs[.type] as? FileAttributeType,
                      type != .typeSymbolicLink else { continue }
                if type == .typeDirectory {
                    walk(full, prefix + name + "/", depth + 1)
                } else {
                    let ext = (name as NSString).pathExtension.lowercased()
                    guard extensions.contains(ext) else { continue }
                    let meta = parseHead(readHead(full), fileName: name)
                    out.append(KnowledgeBaseDoc(
                        relativePath: prefix + name,
                        depth: depth,
                        modifiedAt: attrs[.modificationDate] as? Date,
                        byteCount: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                        title: meta.title,
                        summary: meta.summary))
                }
            }
        }
        walk(root, "", 1)
        return out.sorted { $0.relativePath < $1.relativePath }
    }

    // MARK: 笔记正文段 (P17)

    /// 正文段的一篇**输入** —— 由调用方从磁盘读好（纯函数不碰 IO）。
    struct NoteBodyInput: Equatable {
        /// 根的显示名（`[笔记]` 段里那个名字 —— 两处必须逐字同源, 否则模型找不到根）。
        let label: String
        /// 根内相对路径。
        let path: String
        /// 只用来排序（"从最旧的丢"）。`nil` = 未知 ⇒ 排最后。
        let modifiedAt: Date?
        let content: String
    }

    /// 正文段的组装结果。带 `omitted` 是因为**点名要说得出是谁**（同索引段的「另 N 个文件」判据）。
    struct NoteBodySegment: Equatable {
        let text: String
        let shown: Int
        let omitted: [String]
        let chars: Int
        static let empty = NoteBodySegment(text: "", shown: 0, omitted: [], chars: 0)
    }

    /// 组装正文段: 段头 + 逐篇 `## <根名> / <相对路径>` 与正文 + （有的话）点名行。
    ///
    /// 超预算时**从最旧的丢**（按 `modifiedAt` 倒序保留 = 新的优先）——
    /// "陈旧"在这本账里正是"更可能被 replace / delete 掉的那一批", 留新的更划算。
    /// 单篇自己就超预算的**跳过它、继续看下一篇**（不是"到它为止"）: 一篇巨型笔记不该
    /// 把排在它后面的所有小笔记一起拖下水。
    static func noteBodyBlock(_ notes: [NoteBodyInput], budget: Int) -> NoteBodySegment {
        let sorted = notes.sorted {
            ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
        }
        var kept: [NoteBodyInput] = []
        var omitted: [String] = []
        for n in sorted {
            if renderBody(kept + [n], omitted: omitted).count > budget {
                omitted.append(n.label + " / " + n.path)
            } else {
                kept.append(n)
            }
        }
        // 兜底: 上面那圈判的是"加入这一篇之后**当时**的点名行", 而丢掉一篇会让点名行**变长**
        // ⇒ 最终长度可能刚好越线。再从最旧的丢一轮（`kept` 是新的在前 ⇒ 尾部就是最旧的）。
        while kept.count > 1, renderBody(kept, omitted: omitted).count > budget {
            let dropped = kept.removeLast()
            omitted.append(dropped.label + " / " + dropped.path)
        }
        guard !kept.isEmpty || !omitted.isEmpty else { return .empty }
        let text = renderBody(kept, omitted: omitted)
        return NoteBodySegment(text: text, shown: kept.count, omitted: omitted, chars: text.count)
    }

    /// 正文段的渲染。**段头是契约 token 的兄弟**（同 `【最近会话摘录】`）—— 恒中文, 不进词表。
    private static func renderBody(_ notes: [NoteBodyInput], omitted: [String]) -> String {
        var parts = ["【笔记正文 · \(notes.count) 篇】"]
        for n in notes { parts.append("## \(n.label) / \(n.path)\n\(n.content)") }
        if !omitted.isEmpty {
            // 点名最多列 8 个: 全列出来会把"丢了 200 篇"变成一段比正文还长的清单。
            // 但**个数一定要说全** —— "丢了几篇"才是用户判断"要不要去 read"的依据。
            let head = omitted.prefix(8).joined(separator: "、")
            parts.append("（另有 \(omitted.count) 篇正文未列出: \(head)"
                         + (omitted.count > 8 ? " 等" : "") + " —— 需要时用 read 按路径取）")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 陈旧天数 —— 未达阈值返回 `nil`（"天天显示 1 天"是噪音, 标记要有信息量）。
    static func staleDays(_ modifiedAt: Date?, at now: Date = Date()) -> Int? {
        guard let modifiedAt else { return nil }
        let days = Int(now.timeIntervalSince(modifiedAt) / 86_400)
        return days >= staleAfterDays ? days : nil
    }

    /// 读文件头（最多 `limit` 字节）。**多字节字符被切断时往回退几字节重试** ——
    /// 否则一个 512 字节边界正好落在汉字中间, 整篇的标题与摘要都会变成空（而它不会报错）。
    static func readHead(_ path: String, limit: Int = KnowledgeBaseScan.headBytes) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: limit), !data.isEmpty else { return "" }
        for back in 0...3 {
            let n = data.count - back
            guard n > 0 else { break }
            if let s = String(data: data.prefix(n), encoding: .utf8) { return s }
        }
        return ""
    }

    /// 从文件头解析 `title` / `summary`。**解析失败不猜** —— 回落文件名与空串,
    /// 笔记正文永远不因 frontmatter 破损而消失（同 `PersonaPack` 那条判据的形状）。
    static func parseHead(_ head: String, fileName: String) -> (title: String, summary: String) {
        let fallbackTitle = fileStem(fileName)
        // 拆解走 `splitFrontmatter` —— **与编辑面同一口径**。两处各写一份的后果见那里的注释:
        // 同一份文件两条解析路径 ⇒ 编辑器里看到的正文与索引里的摘要对不上, 而且门禁全绿。
        // frontmatter = 首行 `---` + 后面某个闭合 `---`; **不闭合 = 破损** ⇒ 当普通正文,
        // 不吞掉整篇（正文里的 `---` 分隔线不会让这篇笔记消失）。
        let (meta, body) = splitFrontmatter(head)
        var title = ""
        var summary = ""
        for raw in meta {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if title.isEmpty, let v = frontmatterValue(of: "title", in: line) { title = v }
            if summary.isEmpty, let v = frontmatterValue(of: "summary", in: line) { summary = v }
        }
        if summary.isEmpty { summary = firstMeaningfulLine(body) }
        if summary.count > summaryLimit { summary = String(summary.prefix(summaryLimit)) }
        return (title.isEmpty ? fallbackTitle : title,
                summary.trimmingCharacters(in: .whitespaces))
    }

    /// 文件名去扩展名（含子目录的路径也吃得下 —— 取末段）。
    ///
    /// **两处必须共用一个函数**：`parseHead` 的 `title` 回落值、以及索引行判「标题值不值得占一格」。
    /// 各写一份的话，某天 `title` 明明等于回落值却被判成"不同" ⇒ **每行多一节零信息的标题**
    /// （每轮都吃 prompt 预算），而门禁全绿。
    static func fileStem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - P15.2 笔记的读与写（同一份文件的**同一个口径**）

    /// 由标题净化出**文件名**（不含扩展名）。`nil` = 净化后没剩下可用名字。
    ///
    /// ⚠️ 与 `KnowledgeStore.l1FileName` 的净化**不是一回事**: 那个防的是"用户输入变成
    /// `AGENTS.md` ⇒ 劫持 agent 的指令面", 所以非法字符全换 `-`、点开头还要加前缀。
    /// 这里是**给人看的文件**, 只挡真正会坏事的四类: 路径分隔符 / 冒号 / 换行 / 上跳与空白名。
    /// **中文、空格、括号、破折号一律原样保留** —— 过度净化会把「部署备忘（旧）」洗成「部署备忘-旧-」,
    /// 而文件名正是用户在 Finder 里认它的依据。
    static func noteFileName(from title: String) -> String? {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        for bad in ["/", "\\", ":", "\n", "\0"] {
            name = name.replacingOccurrences(of: bad, with: "-")
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { return nil }
        // 点开头会被扫描器当隐藏项跳过（`docs(root:)` 里 `hasPrefix(".")` 那道）——
        // 那样会"建成功但看不见", 所以补个前缀让它露面（同 `l1FileName` 的处置, 不同理由）。
        if name.hasPrefix(".") { name = "note" + name }
        return name
    }

    /// 拆一篇笔记: frontmatter 的**原文行**（不含那两条 `---`）+ 正文。
    ///
    /// **`parseHead` 与编辑面共用这一个口径** —— 两处各写一份, 就会出现"编辑器里看到的正文"
    /// 和"索引里的摘要"对不上（同一份文件、两条解析路径、两种结果, 而且**门禁全绿**）。
    /// 不闭合的 `---` = 没有 frontmatter（整篇都是正文）。
    ///
    /// 正文开头的**一个**空行被吃掉: 组装时（`composeNote`）总写一个空行做分隔, 不在这里吃掉它,
    /// 每保存一次就多长一个空行。
    static func splitFrontmatter(_ content: String) -> (meta: [String], body: String) {
        let lines = content.components(separatedBy: "\n")
        guard lines.first.map({ $0.trimmingCharacters(in: .whitespaces) == "---" }) ?? false,
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return ([], content) }
        var body = lines[(close + 1)...].joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        return (Array(lines[1..<close]), body)
    }

    /// 把 (frontmatter 原文行, 标题, 正文) 组回整篇。
    ///
    /// **只碰 `title:` 那一行, 其余 frontmatter 逐字保留** —— 用户的注释、键顺序、引号风格
    /// 都是他的东西, 重组一遍等于替他重写了一遍（静默的数据损失, 而且他不会知道）。
    /// 标题为空 ⇒ **删掉那一行**, 不写空值: 空标题的正确表达是"回落文件名"（见 `parseHead`）。
    ///
    /// `splitFrontmatter ∘ composeNote` 是**恒等**的（`meta` 与 `body` 原样进、原样出）。
    static func composeNote(meta: [String], title: String, body: String) -> String {
        var lines = meta
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let idx = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("title:") }
        if t.isEmpty {
            if let idx { lines.remove(at: idx) }
        } else if let idx {
            lines[idx] = "title: " + t
        } else {
            lines.insert("title: " + t, at: 0)
        }
        // 没有 frontmatter、标题也空 ⇒ 整篇就是正文（**不凭空造一块空的 `---`**）。
        guard !lines.isEmpty else { return body }
        return (["---"] + lines + ["---", "", body]).joined(separator: "\n")
    }

    private static func frontmatterValue(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        var v = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }

    /// 正文里第一行"有内容"的（跳过空行、HTML 注释、以及 `---` 这类分隔线,
    /// 去掉 markdown 标题的 `#`）。
    ///
    /// 为什么必须跳过分隔线: 开头 `---` 不闭合时整篇按普通正文处理, 那时第一行就是那个 `---` ——
    /// 把它当摘要等于让一篇笔记的摘要变成三个连字符。
    private static func firstMeaningfulLine(_ body: String) -> String {
        for raw in body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("<!--") { continue }
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "=" }) { continue }
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return ""
    }

    /// 索引文本的**统计与文本**（UI 预览与注入文本共用它 —— 同源）。
    struct IndexBlock: Equatable {
        let text: String
        let shown: Int
        let omitted: Int
        let chars: Int
    }

    /// 组装一个库的索引块。`nil` = 该库不进索引（**只剩"停用"这一种情形**）。
    ///
    /// - ⚠️ **P15.8 有意推翻 P11.4 的「空库不注入」**（原注释: 一条"这次是空的"记录对 agent 没有
    ///   可行动信息, 只是每轮占一行预算）。那条判断的**适用条件是 P11.4 的"根 = 用户挂载的任意目录"**
    ///   —— 那时"这个目录空着"确实没有可行动信息。P15.1 起根固定成两个、门 1 定「**归属 = 位置**」,
    ///   "这个根存在、可以往这里写"**就是**可行动信息: dream 唯一的任务就是判断一条洞见该归到哪儿,
    ///   而空根不进段 ⇒ 它对模型**不存在** ⇒ 唯一合法落点变成全局（2026-10-13 实测到的缺陷）。
    ///   省下的那两行预算, 代价是删掉了归属判断的**全部依据**。
    /// - 空根的块形状与有文件的块**完全一致**（3 行头 + 1 行 `（本根暂无笔记）`）——
    ///   刻意不压成一行: 模型不必处理两种结构, 而多出的 ~37 字在 64000 预算里不值一提。
    /// - `now` 可注入: 陈旧天数必须**可确定性断言**, 否则冒烟只能靠造"很久以前的文件"。
    static func indexBlock(for base: KnowledgeBase, docs: [KnowledgeBaseDoc],
                           now: Date = Date()) -> IndexBlock? {
        guard base.enabled else { return nil }
        var shown = Array(docs.prefix(maxLinesPerBase))
        var omitted = docs.count - shown.count
        let lines = [
            "\(token) \(base.displayName)",
            "路径: \(base.path)",
            "说明: \(base.description)",
        ]
        // 行 = `相对路径 · 标题 · 摘要 · N 天未更新`（后两节按条件出现）。
        // ⚠️ **相对路径必须在最前**: 它是 agent 唯一能拿去 `read` 的定位符 ——
        // 只给标题等于给了一张没有馆址的卡片（同 `路径:` 那条判据）。
        //
        // **标题只在它比路径末段多出信息时才补**（2026-10-12 boss 拍）。理由: `title` 的缺省值
        // 就是「文件名去扩展名」⇒ 与相对路径的末段**重复**，补上去只是把同一件事说两遍
        // （而那两遍都吃每轮预算）。判据读 `Self.fileStem` —— 与 `parseHead` 造回落值**同源**。
        func row(_ d: KnowledgeBaseDoc) -> String {
            var s = "  " + d.relativePath
            if !d.title.isEmpty, d.title != Self.fileStem(d.relativePath) { s += " · " + d.title }
            if !d.summary.isEmpty { s += " · " + d.summary }
            if let days = staleDays(d.modifiedAt, at: now) { s += " · \(days) 天未更新" }
            return s
        }
        func tailLines() -> [String] {
            var ls = shown.map { row($0) }
            if omitted > 0 { ls.append("  … 另 \(omitted) 个文件") }
            return ls
        }
        // 空根: **坐标照给**（P15.8 —— 门 1「归属 = 位置」, 没有坐标就没有合法落点), 只是没有文件可列。
        // 判定收在**一处**: `bodyFor()` 同时服务首算与字符兜底那圈, 免得两处各写一遍同一个三元。
        func bodyFor() -> [String] {
            docs.isEmpty ? [Self.emptyRootLine]
                         : (["文件 (\(docs.count), 深度≤\(maxDepth)):"] + tailLines())
        }
        var text = (lines + bodyFor()).joined(separator: "\n")
        // 字符兜底: 文件名很长时行数上限拦不住 ⇒ 从尾部继续丢, 并把丢掉的计入 `omitted`
        // （空根时 `shown == 0` ⇒ 这圈天然不进 —— 它没有可丢的行, 4 行头也不会超 2000 字）。
        while text.count > maxCharsPerBase, shown.count > 1 {
            shown.removeLast()
            omitted += 1
            text = (lines + bodyFor()).joined(separator: "\n")
        }
        return IndexBlock(text: text, shown: shown.count, omitted: omitted, chars: text.count)
    }
}
