//
//  AssistantLedger.swift
//  P19.2 S8 —— 助理「工作日志」的结构化视图，也是它与 Cron「交接文件」的分界线。
//
//  为什么需要这一层: 工作日志是**整篇重写**的自由文本（模型自己 write 覆盖），
//  而"目标完成到哪了"必须能被程序算出来 —— 台账、催促、"全部完成回待命"都靠它。
//  没有这一层，契约里的 `## 完成状态` 就只是个标题: 人看得见、程序看不见。
//
//  ⚠️ 与 Cron 交接文件的区别**不是命名品味，是语义**:
//    · Cron「交接文件」= 一次执行的过程记忆。模型自己写盘，格式自由，没有"完成"这回事
//      （它每轮都重新执行一次指令）；
//    · 助理「工作日志」= 长程目标的账本。固定五节，其中「完成状态」是验收面，
//      「已完成（归档）」是给人回看的记忆。
//  本类型只服务**助理档** —— Cron 的字段、prompt 与文件路径一个字节都不动。
//
//  ⚠️ 三态（`Stage`）不是好看的枚举，它堵的是这一层唯一的假绿入口:
//  旧写法 `isComplete = 验收项非空 && 全达成` 在加了归档之后会翻面 ——
//  一件事做完、验收项被移进归档 ⇒ `items` 变空 ⇒ 旧定义把「刚做完」判成「没达成」。
//  三态把「没有验收项」明确落在 `.empty`，于是它永远不会被读成 `.done`。
//

import Foundation

/// 一条验收项的标记。
///
/// 只认 ASCII `[x] / [ ] / [!]` —— 契约里点名要求的就是这三种。符号（`☑ ✅ ⏸`）另做容错，
/// 但不作主判据: 模型写符号的稳定性差得多，而**漏认一个标记的后果是「这条没达成」**
/// （把已完成的写成未完成，人以为进度退了）。
enum LedgerMark: String, Equatable {
    case done = "x"
    case todo = " "
    case blocked = "!"

    /// 符号容错。认不出返回 nil（宁可少一条，也不替它决定达成没达成）。
    static func fromSymbol(_ s: String) -> LedgerMark? {
        switch s {
        case "☑", "✅", "✓", "✔": return .done
        case "☐", "⬜", "○": return .todo
        case "⏸", "⚠", "🛑": return .blocked
        default: return nil
        }
    }
}

/// 账本的状态。**这是「无目标 → 在追 → 完成 → 回无目标」这条回路的判据**。
enum LedgerStage: Equatable {
    /// 没有验收项、也没有在跟踪的事 ⇒ 无目标，等指令（账本不存在也算这一档）。
    case empty
    /// 有未达成的验收项，或在跟踪非空。
    case tracking
    /// 有验收项且**全部达成**、在跟踪为空 ⇒ 该收尾了（把验收项移进归档）。
    case done
}

/// 助理工作日志的五节结构。
///
/// 解析**不抛错也不丢弃**: 认不出节头的行留在当前节里当正文（丢一行 = 这条验收项不存在），
/// 认不出标记的验收行不算验收项（见 `LedgerMark`）。
struct AssistantLedger: Equatable {
    struct Item: Equatable {
        var mark: LedgerMark
        var text: String
    }

    /// `## 目标` —— 只看首行（契约要求"一句话复述"）。
    var goal: String = ""
    /// `## 完成状态` 里带标记的行。
    var items: [Item] = []
    /// `## 在跟踪`（占位的「无」已滤掉）。
    var tracking: [String] = []
    /// `## 待你决定`（占位的「无」已滤掉）—— 催促的判据就是它非空。
    var waiting: [String] = []
    /// `## 已完成（归档）`。**只用于显示，不参与任何判定** ——
    /// 所以它被压缩掉一行，不会有任何判据跟着变。
    var archived: [String] = []

    // MARK: - 派生量

    /// 原文长度（`parse` 填）。0 也可能是"还没解析过"，别拿它当唯一判据。
    var charCount: Int = 0

    /// 有没有任何可显示的东西（全空 ⇒ 台账卡显示"还没有账本"那两句话）。
    ///
    /// ⚠️ 不能只看 `stage == .empty`: 一篇**只有目标**的账本 `stage` 也是 `.empty`
    /// （`stage` 只认 items / tracking），而它明明有内容、卡片该把目标显示出来。
    var hasContent: Bool {
        !goal.isEmpty || !items.isEmpty || !tracking.isEmpty
            || !waiting.isEmpty || !archived.isEmpty
    }

    var stage: LedgerStage {
        if items.isEmpty && tracking.isEmpty { return .empty }
        if !items.isEmpty && items.allSatisfy({ $0.mark == .done }) && tracking.isEmpty { return .done }
        return .tracking
    }

    /// ⚠️ 只有 `.done` 算完成。**空验收项落在 `.empty`，不许读成完成。**
    var isComplete: Bool { stage == .done }

    var doneCount: Int { items.filter { $0.mark == .done }.count }
    var blockedCount: Int { items.filter { $0.mark == .blocked }.count }
    /// 未达成 = 总数 - 已达成（含"卡住"）。
    var openCount: Int { items.count - doneCount }

    /// 一句话摘要（给对话轮 / 台账用）。三态都有话说 ——
    /// 「当前无目标」本身就是人最想知道的那一句。
    var brief: String {
        switch stage {
        case .empty:
            return archived.isEmpty
                ? "账本里没有验收项、也没有在跟踪的事 —— **当前无目标**。"
                : "账本里没有在追的目标 —— **当前无目标**；历史归档 \(archived.count) 条。"
        case .done:
            var s = "验收 \(items.count) 项**全部达成** —— 目标已完成，可以收尾（把验收项移进归档）。"
            if !waiting.isEmpty { s += "\n但还有 \(waiting.count) 件在等人决定。" }
            return s
        case .tracking:
            var parts: [String] = []
            if items.isEmpty {
                parts.append("还没有列出验收项")
            } else {
                var s = "验收 \(items.count) 项 · 已达成 \(doneCount)"
                if blockedCount > 0 { s += " · 卡住 \(blockedCount)" }
                let plainOpen = openCount - blockedCount
                if plainOpen > 0 { s += " · 未达成 \(plainOpen)" }
                parts.append(s)
            }
            parts.append(tracking.isEmpty
                ? "在跟踪: 无"
                : "在跟踪: " + tracking.prefix(3).joined(separator: "；"))
            if !waiting.isEmpty {
                parts.append("在等你决定 \(waiting.count) 件: " + waiting.prefix(3).joined(separator: "；"))
            }
            return parts.joined(separator: "\n")
        }
    }

    // MARK: - 节头

    /// 节名与它的别名。
    ///
    /// ⚠️ **守住 `已完成（归档）` 的不是这张表的顺序，是 `head` 里那条「整行等值或紧跟冒号」** ——
    /// `已完成（归档）` 对别名 `已完成` 两样都不满足（既不等、后面也不是冒号），所以自然落到
    /// 更长的别名上。2026-11-17 实测确认: 把 `已完成` 挪到最前、并把排序删掉，`⑤b` **仍然是绿的**。
    /// 排序留着只是保险 —— 哪天加一个更长的别名、或者有人把 `head` 放宽成前缀匹配，
    /// 不用再回头想顺序。真正守着「别按前缀认」的是算例 `⑤a`。
    private static let flatHeads: [(name: String, alias: String)] = [
        ("目标", "目标"),
        ("完成状态", "完成状态"),
        ("在跟踪", "在跟踪"),
        ("待你决定", "待你决定"),
        ("已完成", "已完成（归档）"),
        ("已完成", "已完成(归档)"),
        ("已完成", "已完成"),
    ].sorted { $0.alias.count > $1.alias.count }

    /// 认一行是不是节头。返回 (节名, 同行剩下的内容)。
    ///
    /// **要求整行等值或紧跟冒号** —— 只按前缀认会把正文切错: `目标达成了三条` 会被当成
    /// 「目标」节的正文，于是真正那一句目标被它顶掉，而所有计数照样有理有据。
    private static func head(_ raw: String) -> (name: String, rest: String)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Markdown 装饰: `## 目标` / `### 完成状态` / `**在跟踪**`
        while s.hasPrefix("#") || s.hasPrefix("*") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("*") { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        for spec in flatHeads where s == spec.alias || s.hasPrefix(spec.alias + "：")
            || s.hasPrefix(spec.alias + ":") {
            var rest = String(s.dropFirst(spec.alias.count)).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("：") || rest.hasPrefix(":") {
                rest.removeFirst()
                rest = rest.trimmingCharacters(in: .whitespaces)
            }
            return (spec.name, rest)
        }
        return nil
    }

    // MARK: - 解析

    static func parse(_ text: String) -> AssistantLedger {
        var out = AssistantLedger()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        // 原文长度由解析顺带带出来（视图要用它显示「账本 N 字」与判空）。
        // ⚠️ 之所以挂在解析结果上: 台账卡是**每次 body 求值都要用**这几个值的地方，
        //    而 `parse` 是 O(n)。原来视图里 `ledger` 是计算属性 ⇒ 一次 body 解析 6 遍
        //    （2026-11-18 review）。解析只做一次、结果带着长度，视图就无从重复。
        out.charCount = normalized.count
        var current: String?

        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let h = head(trimmed) {
                current = h.name
                absorb(h.rest, into: &out, section: h.name)
                continue
            }
            absorb(trimmed, into: &out, section: current)
        }
        return out
    }

    /// 把一行塞进对应节。空的节名（还没见到任何节头）⇒ 丢弃 —— 节前的寒暄不属于任何一节。
    private static func absorb(_ line: String, into out: inout AssistantLedger, section: String?) {
        guard let section, !line.isEmpty else { return }
        switch section {
        case "目标":
            if out.goal.isEmpty { out.goal = line }
        case "完成状态":
            if let it = item(line) { out.items.append(it) }
        case "在跟踪":
            if let s = bullet(line), !isPlaceholder(s) { out.tracking.append(s) }
        case "待你决定":
            if let s = bullet(line), !isPlaceholder(s) { out.waiting.append(s) }
        case "已完成":
            if let s = bullet(line), !isPlaceholder(s) { out.archived.append(s) }
        default:
            break
        }
    }

    /// `- [x] 文本` / `[ ] 文本` / `[!] 文本`。认不出标记的行**不算验收项**。
    static func item(_ raw: String) -> Item? {
        var s = stripBullet(raw)
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]"), close > s.startIndex else { return nil }
            let inner = s[s.index(after: s.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            let mark: LedgerMark
            switch inner.lowercased() {
            case "x": mark = .done
            case "": mark = .todo
            case "!": mark = .blocked
            default: return nil
            }
            let text = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return Item(mark: mark, text: text)
        }
        // 符号容错: `☑ 已达成` 这种写法也要认，否则整份账本会「一项都没有」
        if let first = s.first, let mark = LedgerMark.fromSymbol(String(first)) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            return Item(mark: mark, text: s)
        }
        return nil
    }

    private static func stripBullet(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("• ") {
            s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// 列表项的正文（去前缀 `- ` / `* ` / `• `）。
    private static func bullet(_ raw: String) -> String? {
        let s = stripBullet(raw)
        return s.isEmpty ? nil : s
    }

    /// 占位。契约要求"没有就写「无」" —— 那不是一个待办项，也不是一条归档。
    private static func isPlaceholder(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " 。.、，,—-"))
        // 「无」「没有」「-」是契约点名的占位写法。漏认的后果不是显示难看:
        // 「在跟踪: 无」会被算成**一条在跟踪** ⇒ 目标永远推进不到 `.done`。
        return t.isEmpty || ["none", "n/a", "无", "没有", "暂无"].contains(t.lowercased())
    }
}
