import Foundation

// MARK: - 并排 diff 的一行

/// 行级 diff 的一行 —— **并排两侧共用同一个行号空间**，所以它天然表达"左右对齐"。
///
/// 为什么是一个"两侧都带"的结构，而不是两个数组：并排视图要的是"左边第 3 行与右边第 3 行
/// 是同一根横线"。分成两个独立数组后，那个对应关系就没地方存了 —— 只能靠两边下标相等来暗示，
/// 而一旦某一侧插入/删除过行，下标相等就**不再成立**（那正是 diff 要表达的东西）。
struct NoteDiffLine: Equatable, Identifiable {
    enum Kind: Equatable {
        /// 两边一样。
        case same
        /// 只在新版里有（左边那一格是空的）。
        case added
        /// 只在旧版里有（右边那一格是空的）。
        case removed
    }

    /// 对齐序号（从 0 起）—— 两侧共用。
    let id: Int
    let kind: Kind
    /// 旧版这一行。`nil` = 这一格空着（新增行）。
    let left: String?
    /// 新版这一行。`nil` = 这一格空着（删除行）。
    let right: String?
}

// MARK: - 算法

/// 行级 diff。**纯函数**（不吃磁盘、不吃 DB、不碰状态）⇒ 冒烟可以直接喂字符串造反例，
/// 不需要一篇真笔记、更不需要跑一次 dream。
///
/// 为什么放在模型层而不是 View 里：它是**判据**（"哪些行变了"必须能被断言），
/// 而 View 里的东西冒烟看不见（`swiftc` 能编译它，但没法调它）。
enum NoteDiff {

    /// 逐行 LCS 的格子上限。超过就退化成"整体替换"。
    ///
    /// 这是**性能护栏，不是正确性妥协**：真表是 O(n·m)，而调用点在主线程的界面更新路径上。
    /// 一份 500 行 × 500 行的笔记是 25 万格 —— 到这儿已经不值得为了"更精细的对齐"
    /// 让界面慢一拍；而退化输出的语义（整段删、整段增）**依然是诚实的**。
    static let maxCells = 250_000

    /// 对齐两版文本。返回的序列按"两边合并后的阅读顺序"排列。
    ///
    /// - Note: 空串按**零行**处理，不是"一个空行" —— 否则"新建一篇（旧版不存在）"
    ///   会凭空多出一格空的旧行，而那一格在界面上长得像"这一行被改过"。
    static func lines(old: String, new: String) -> [NoteDiffLine] {
        let l = splitLines(old)
        let r = splitLines(new)
        if l.isEmpty { return r.enumerated().map { NoteDiffLine(id: $0.offset, kind: .added,
                                                               left: nil, right: $0.element) } }
        if r.isEmpty { return l.enumerated().map { NoteDiffLine(id: $0.offset, kind: .removed,
                                                                left: $0.element, right: nil) } }
        if l.count * r.count > maxCells { return replaced(l, r) }

        // LCS 长度表（自底向上）。`t[i][j]` = l[i...] 与 r[j...] 的最长公共子序列长度。
        var t = [[Int]](repeating: [Int](repeating: 0, count: r.count + 1), count: l.count + 1)
        for i in stride(from: l.count - 1, through: 0, by: -1) {
            for j in stride(from: r.count - 1, through: 0, by: -1) {
                t[i][j] = l[i] == r[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        // 回溯。**顺序**: 先处理"左边独有"再处理"右边独有" —— 反过来会让
        // "删一行 + 加一行"渲染成"加在下、删在上", 与实际发生的事反着。
        var out: [NoteDiffLine] = []
        var i = 0, j = 0
        while i < l.count || j < r.count {
            if i < l.count && j < r.count && l[i] == r[j] {
                out.append(NoteDiffLine(id: out.count, kind: .same, left: l[i], right: r[j]))
                i += 1; j += 1
            } else if i < l.count && (j >= r.count || t[i + 1][j] >= t[i][j + 1]) {
                out.append(NoteDiffLine(id: out.count, kind: .removed, left: l[i], right: nil))
                i += 1
            } else {
                out.append(NoteDiffLine(id: out.count, kind: .added, left: nil, right: r[j]))
                j += 1
            }
        }
        return out
    }

    /// 两版**有没有实质差异** —— 与 `lines` 同源（都走行切分），所以不会出现
    /// "diff 说有差异、这个说有/没有"的矛盾。§05 那条「diff 为空则整份不产出」读它。
    static func isEmpty(old: String, new: String) -> Bool {
        splitLines(old) == splitLines(new)
    }

    // MARK: 私有

    /// 行切分 —— **与 `proposalContentPreview` 的切分同源**（`omittingEmptySubsequences: false`）:
    /// 空行是一个真实的行（它决定段落间距）, 不是"没有行"。
    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 超规模的退化形态：旧版整段删、新版整段增。
    private static func replaced(_ l: [String], _ r: [String]) -> [NoteDiffLine] {
        var out: [NoteDiffLine] = []
        for line in l { out.append(NoteDiffLine(id: out.count, kind: .removed, left: line, right: nil)) }
        for line in r { out.append(NoteDiffLine(id: out.count, kind: .added, left: nil, right: line)) }
        return out
    }
}
