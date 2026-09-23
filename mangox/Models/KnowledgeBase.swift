//
//  KnowledgeBase.swift
//  P11.4 知识库档 —— 第三载体: 挂载目录 + 描述 + 索引。
//  设计见 docs/P11-functional-design.md §3.4（表结构 / 扫描契约 / 索引形态 / 只读红线）。
//
//  为什么不把文件搬进 DB: 成套资料有自己的生命周期（可能是 git 仓库、可能别人在维护、
//  可能天天被改）。App **只读不写**, 只做两件事 —— 让 agent 知道它存在（索引）、
//  告诉它去哪读（路径）。
//

import Foundation

/// 一条"挂载记录"。`{ 目录路径, 描述（必填）, 启用 }`。
///
/// - Note: `id` 取 `String` 而不是 `UUID`, 是为了**内置库**能用稳定 id
///   (`"builtin:l1-global"` / `"builtin:l1-project:<projectId>"`) —— 内置库不落库、
///   每次现算, 但它要能在 UI 里被选中, 所以必须有一个跨启动稳定的身份。
struct KnowledgeBase: Identifiable, Equatable {
    let id: String
    /// 目录绝对路径（已展开 `~`、已标准化）。**必须绝对** —— 索引里要把它给 agent 去 read。
    var path: String
    /// 描述 —— **必填**。索引里如果只有文件名, agent 拿到的是一串没有语义的字符串。
    var description: String
    var enabled: Bool = true
    /// 内置库 = L1 落盘目录自动挂载（§3.4）: 不可删、描述由 App 写死、不落库。
    var isBuiltin: Bool = false
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// 描述长度上限。它是"一句话"，不是摘要 —— 长了就开始跟正文抢预算。
    static let descriptionLimit = 200

    /// 左列显示名 = 目录末段（`/Users/x/Documents/notes` → `notes`）。
    var displayName: String {
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
    /// 内置库不可改 / 不可删（它的存在由 L1 落盘目录决定, 不归用户配置）。
    case builtinImmutable
}

/// 扫描到的单个文档。`relativePath` 用 `/` 分隔且**总是相对库根** ——
/// 索引里给相对路径（深度信息本身有价值: "这是子目录里的"）, 绝对定位靠库的 `path`。
struct KnowledgeBaseDoc: Equatable {
    let relativePath: String
    /// 1 = 根目录下的直接文件。
    let depth: Int
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

    /// 注入块的契约 token —— 模型看到的就是这个字面量 ⇒ **恒中文, 不许本地化**
    /// （同 `KnowledgeKind.tag`: 界面语言不许改 prompt 字节）。
    static let token = "[知识库]"
    /// 索引段的段头。同 `[知识库]`, 恒中文。
    static let segmentHeader = "以下是挂载的知识库 (只给索引; 需要时用 read 工具按路径自行取用):"

    /// 扫描一个目录。**只读目录项、不读文件正文** ⇒ 成本与文件总大小无关, 也不需要缓存。
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
                guard let type = (try? fm.attributesOfItem(atPath: full))?[.type] as? FileAttributeType,
                      type != .typeSymbolicLink else { continue }
                if type == .typeDirectory {
                    walk(full, prefix + name + "/", depth + 1)
                } else {
                    let ext = (name as NSString).pathExtension.lowercased()
                    guard extensions.contains(ext) else { continue }
                    out.append(KnowledgeBaseDoc(relativePath: prefix + name, depth: depth))
                }
            }
        }
        walk(root, "", 1)
        return out.sorted { $0.relativePath < $1.relativePath }
    }

    /// 索引文本的**统计与文本**（UI 预览与注入文本共用它 —— 同源）。
    struct IndexBlock: Equatable {
        let text: String
        let shown: Int
        let omitted: Int
        let chars: Int
    }

    /// 组装一个库的索引块。`nil` = 该库不进索引（停用, 或一个文件都没有）。
    ///
    /// - 空库不注入: 一条"这次是空的"记录对 agent 没有任何可行动信息, 只是每轮占一行预算。
    ///   （UI 里仍然显示, 标 0 个文件 —— 用户得看得见自己挂了个空目录。）
    static func indexBlock(for base: KnowledgeBase, docs: [KnowledgeBaseDoc]) -> IndexBlock? {
        guard base.enabled, !docs.isEmpty else { return nil }
        var shown = Array(docs.prefix(maxLinesPerBase))
        var omitted = docs.count - shown.count
        let lines = [
            "\(token) \(base.displayName)",
            "路径: \(base.path)",
            "说明: \(base.description)",
        ]
        func tailLines() -> [String] {
            var ls = shown.map { "  " + $0.relativePath }
            if omitted > 0 { ls.append("  … 另 \(omitted) 个文件") }
            return ls
        }
        var text = (lines + ["文件 (\(docs.count), 深度≤\(maxDepth)):"] + tailLines()).joined(separator: "\n")
        // 字符兜底: 文件名很长时行数上限拦不住 ⇒ 从尾部继续丢, 并把丢掉的计入 `omitmitted`
        while text.count > maxCharsPerBase, shown.count > 1 {
            shown.removeLast()
            omitted += 1
            text = (lines + ["文件 (\(docs.count), 深度≤\(maxDepth)):"] + tailLines()).joined(separator: "\n")
        }
        return IndexBlock(text: text, shown: shown.count, omitted: omitted, chars: text.count)
    }
}
