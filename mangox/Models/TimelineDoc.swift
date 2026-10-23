//
//  TimelineDoc.swift
//  MangoX
//
//  时间线 —— **App 侧自动记账**的那条流水（2026-10-22）。
//
//  为什么需要它：笔记是**主题卡**（一篇一件事，靠 mtime 判陈旧），它答不出
//  「上周我做了什么、坑在哪里」这类**按时间排**的问题。boss 的原话：
//  「作为记忆，没有时间线，比如什么时候做了什么，坑在哪里」。
//
//  ⚠️ 与笔记的根本分工（这是本功能唯一的架构判据）：
//     · **笔记** = 主观结论，dream 只出提案，人拍板才落盘（P15 门 2）；
//     · **时间线** = 客观发生的事（几点、哪一场、几轮、几次失败），**App 自己记**,
//       模型不参与 ⇒ 它不会编，也就不需要人审（审它就是给 boss 再造一个收件箱）。
//  「坑在哪里」有两层：客观的失败次数由 App 记；主观的教训仍然走 dream 提案,
//  采纳时由 `KnowledgeStore` 往当天补一行 `采纳「…」`。
//
//  落点 = `<笔记根>/timeline/YYYY-MM.md` —— 归属仍由「位置即归属」表达（P15 门 1）,
//  不新开一套目录概念，于是它也自动出现在 `[笔记]` 索引里。
//
import Foundation

enum TimelineDoc {

    /// 笔记根下的子目录名。放子目录而不是根下散文件：`timeline/` 这个前缀本身就是
    /// 「这些是流水，不是主题笔记」的标记，扫索引的人一眼分得开。
    static let dirName = "timeline"

    /// 行内的两个标记词。**恒中文**（同 `KnowledgeBaseScan.token`：它们会进文件正文、
    /// 进而进 prompt 字节 —— 界面语言不许改落盘内容）。
    static let sessionTag = "会话"
    static let adoptionTag = "采纳"

    /// 注入段的契约 token。恒中文，理由同上。
    static let token = "[流水]"

    /// 注入段的段头。恒中文。
    ///
    /// ⚠️ **必须以 `token` 开头** —— 与 `KnowledgeBaseScan.segmentHeader` 同形（那边是
    /// `[笔记]` 段，只是段头文字里不带 token 因为它另有 3 行块头）。这里一段只有一个 token
    /// 可认，所以 token 就写在段头第一句里：模型读到 `[流水]` 才知道这一段是什么、
    /// 与「笔记 / 知识」不是同一类东西。冒烟断言的就是这一句。
    static let segmentHeader = "[流水] 最近几天的自动记账 (不是结论; 需要细节时读笔记区 timeline/ 下那篇):"

    // MARK: - 一行

    /// 要写进文件的一行 + 它的**身份键**。
    ///
    /// 为什么要 key：会话行是**滚动的**（同一场会话每轮都更新轮次），没有身份就只能
    /// 一路追加，一天能堆出十几行同一个标题。
    ///
    /// key 里带标记词（`会话「X」` / `采纳「X」`）而不是裸标题: 两类行可能撞同一个标题
    /// （比如一篇笔记就叫「vLLM 部署」），带标记就不会互相当成对方。
    struct Row: Equatable {
        /// 落在哪一节 —— **只取年月日**，时分秒只影响行内那个 `HH:mm`。
        let day: Date
        /// 整行（含 `- ` 前缀）。
        let line: String
        let key: String
    }

    // MARK: - 时点与文件名

    /// `timeline/2026-10.md`（**根内相对路径**）。
    ///
    /// 按月而不是按天。⚠️ **注意：天粒度并没有丢** —— 它表达在文件内的 `## YYYY-MM-DD`
    /// 节上（`dayHeader`）。**文件只是容器**，容器多大由下面这条预算决定，不由审美决定：
    ///
    /// `KnowledgeBaseScan.indexBlock` 给每个根 `maxCharsPerBase = 2000` 字符 /
    /// `maxLinesPerBase = 120` 行，而**每个文件在索引里恒占一行**（时间线那行约 60 字符,
    /// 含路径 + 月份摘要 + 陈旧标记）⇒
    ///   · **按月**: 一年 12 行 ≈ 708 字符 = 预算 35%，能和主题笔记共存;
    ///   · **按周**: 一年 52 行 ≈ 3120 = 156%，已超;
    ///   · **按天**: 一年 ≈ 22600 = 1132%，**32 天就吃满**。
    ///
    /// 超预算的坏结局比"挤"更狠：兜底那圈是 `shown.removeLast()` 从尾部丢，而 `docs` 按
    /// `relativePath` **字典序正序**排 ⇒ 被丢的是**排在最后 = 最新**的那几篇。按天的话，
    /// 第 33 天起**今天刚记的反而进不了索引**，方向正好反了。这才是不能按天的真原因。
    ///
    /// 另一条同向的账: `staleAfterDays = 7`（`staleDays` 读 mtime）—— 按天时每一份历史日
    /// 文件 7 天后必挂「N 天未更新」，三十行里二十几行挂着同一句话，把这个信号稀释成背景噪音。
    static func relativePath(for date: Date, calendar: Calendar = .current) -> String {
        dirName + "/" + monthKey(for: date, calendar: calendar) + ".md"
    }

    /// `2026-10` —— 同时是文件名主干与文件头里的月份。
    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// 文件第一行。`# 2026-10 · 27b-model-deploy`。
    ///
    /// 带根名是因为**这个文件在哪个根里，只有根名说得清**（文件自己只看得见月份）。
    /// 它同时是笔记索引里那一行的 `summary`（`firstMeaningfulLine` 会剥掉 `#`）。
    static func monthHeading(for date: Date, rootLabel: String,
                             calendar: Calendar = .current) -> String {
        "# " + monthKey(for: date, calendar: calendar) + " · " + rootLabel
    }

    /// 一天一节的头：`## 2026-10-22`。
    static func dayHeader(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "## %04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `09:12`。手拼而不用 `DateFormatter`：它要**确定性**（冒烟断言一个字符都不能飘），
    /// 而 `DateFormatter` 的 `locale` / `timeZone` 是全局可变状态。
    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - 两种行

    /// 一场会话在**某一天**的状态行。
    ///
    /// 例：`- 09:12  会话「vLLM 部署」· 14 轮 · 2 次失败`
    ///
    /// - Parameter failures: 工具相位是 `.error` 的次数。**0 就不写** —— 写着「0 次失败」
    ///   只是把一个默认值念一遍，而流水里的每个字都要占人眼。
    static func sessionRow(at date: Date, title: String, turns: Int, failures: Int,
                           calendar: Calendar = .current) -> Row {
        let name = sanitize(title)
        var s = "- \(stamp(date, calendar: calendar))  \(sessionTag)「\(name)」· \(turns) 轮"
        if failures > 0 { s += " · \(failures) 次失败" }
        return Row(day: date, line: s, key: sessionTag + "「" + name + "」")
    }

    /// 一条采纳记录。例：`- 21:04  采纳「enforce-eager-ab」—— 显存降 2G 但吞吐掉 15%`
    ///
    /// 这是时间线上**唯一带主观内容**的行，而它的内容不是模型现编的：`reason` 是提案里
    /// 人**拍板前看过的那句话**（`NoteProposal.reason`）。人按下采纳 = 认了这句话。
    static func adoptionRow(at date: Date, noteTitle: String, reason: String,
                            calendar: Calendar = .current) -> Row {
        let name = sanitize(noteTitle)
        var s = "- \(stamp(date, calendar: calendar))  \(adoptionTag)「\(name)」"
        let gist = firstSentence(reason)
        // 中文破折号前后不加空格（`」—— 理由`）—— 这个是**句读**，不是排版。
        if !gist.isEmpty { s += "—— " + gist }
        return Row(day: date, line: s, key: adoptionTag + "「" + name + "」")
    }

    /// 标题进**行内**之前必须净化。
    ///
    /// 三个真会发生坏结局:
    /// ① 换行 —— 一条换行把一行拆成两行, 下一轮 upsert 就找不到它, 于是每轮多一行;
    /// ② `」` —— 它是用来**闭合 key** 的, 标题里带一个就提前闭合, 匹配从此错位;
    /// ③ 超长 —— 会话标题可以是整句话, 而这一行要挤在一天的节里被人扫读。
    ///
    /// 净化对正常标题是**恒等变换**，只有畸形标题才看得见效果。
    static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["\n", "\r", "\t"] { s = s.replacingOccurrences(of: bad, with: " ") }
        s = s.replacingOccurrences(of: "」", with: "）")
             .replacingOccurrences(of: "「", with: "（")
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 40 { s = String(s.prefix(40)) + "…" }
        return s.isEmpty ? "未命名" : s
    }

    /// 理由的第一句，给采纳行用。空理由返回空串（**不发明占位**）。
    static func firstSentence(_ raw: String, limit: Int = 50) -> String {
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return "" }
        var out = flat
        if let dot = flat.firstIndex(where: { $0 == "。" || $0 == "．" }) {
            out = String(flat[flat.startIndex..<dot])
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.count > limit { out = String(out.prefix(limit)) + "…" }
        return out
    }

    // MARK: - 落盘文本

    /// 一个**新月份文件**的初始文本。
    static func newDocument(monthHeading heading: String, row: Row,
                            calendar: Calendar = .current) -> String {
        [heading, "", dayHeader(row.day, calendar: calendar), row.line].joined(separator: "\n") + "\n"
    }

    /// 把一行写进文件的**那一天**。三条规则：
    ///
    /// 1. 同 key 的行**原地替换** —— 会话行每轮都要更新轮次，采纳行同一天同一篇只记一次；
    /// 2. 键不命中就**追加到那一节的末尾** —— 节内**正序**（一天从早到晚），读起来是流逝；
    /// 3. 没有这一天就**新建一节插在所有节之前** —— 节间**倒序**（打开就看到最近的）。
    ///
    /// ⚠️ 节内正序 / 节间倒序不是随手定的：这两个顺序服务两件不同的事 ——
    /// 前者是"这一天怎么过的"，后者是"最近在干什么"。混成一个方向必然有一边难读。
    ///
    /// 纯函数（只吃字符串、只吐字符串）⇒ 冒烟能直接造反例：喂一份带同标题行 / 缺那一天的
    /// 文本，断言替换与插入各自发生，且**原有内容一个字节不丢**。
    static func upsert(_ doc: String, row: Row, calendar: Calendar = .current) -> String {
        var lines = doc.isEmpty ? [] : doc.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let header = dayHeader(row.day, calendar: calendar)
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
            // 节的右边界 = 下一个节头（或文件尾）。
            var end = lines.count
            if let next = lines[(start + 1)..<lines.count].firstIndex(where: { $0.hasPrefix("## ") }) {
                end = next
            }
            if let hit = lines[(start + 1)..<end].firstIndex(where: { $0.contains(row.key) }) {
                lines[hit] = row.line
            } else {
                // 节尾 = 最后一个非空行之后。跳过尾部空行是为了**不把新行塞到节间空行后面**
                // （那会让它看起来属于下一节）。
                var j = end - 1
                while j > start, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j -= 1 }
                lines.insert(row.line, at: j + 1)
            }
        } else {
            // 新节插到所有节之前。空行跟着新块走 ⇒ 节之间恒有一个空行。
            let block = [header, row.line, ""]
            if let firstSection = lines.firstIndex(where: { $0.hasPrefix("## ") }) {
                lines.insert(contentsOf: block, at: firstSection)
            } else if lines.isEmpty {
                lines = block
            } else {
                lines.append(contentsOf: [""] + block)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 注入段

    /// 把最近几天抽成一段给常驻 prompt。
    ///
    /// 为什么要抽而不是整篇塞：时间线会一直长（一个月上千行），而常驻段是**每一轮对话**
    /// 都要付的账。常驻段只负责"最近发生了什么"这个引子，细节由 agent 按路径 read。
    ///
    /// - Parameter documents: 月份文件正文，**顺序无关**（内部按天重排）。
    /// - 超 `charLimit` 时先**减天数**（从最旧丢），天数见底后**减每天行数** ——
    ///   绝不返回空串：一段"最近什么都没发生"的静默缺席，与"这段时间真的空白"长得一样。
    static func recentSegment(_ documents: [String], now: Date,
                              days: Int, rowsPerDay: Int, charLimit: Int,
                              calendar: Calendar = .current) -> String {
        // (天键 `YYYY-MM-DD`, 缩进好的行)。
        var sections: [(day: String, rows: [String])] = []
        for text in documents {
            var currentDay: String?
            var bucket: [String] = []
            func flush() {
                if let d = currentDay, !bucket.isEmpty { sections.append((d, bucket)) }
                bucket = []
            }
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") {
                    flush()
                    currentDay = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("- "), currentDay != nil {
                    bucket.append("  " + line)
                }
            }
            flush()
        }
        // 天键是 `YYYY-MM-DD` ⇒ 字典序 = 时间序。未来那几节不取（时钟回拨时也不至于乱序）:
        // 上界 = `min(今天, 文件里最新那天)`。
        guard let newest = sections.map(\.day).max() else { return "" }
        let limit = min(todayKey(now, calendar: calendar), newest)
        let kept = sections.filter { $0.day <= limit }.sorted { $0.day > $1.day }
        guard !kept.isEmpty else { return "" }

        func build(_ d: Int, _ r: Int) -> String {
            var blocks: [String] = []
            for s in kept.prefix(max(1, d)) {
                var body = Array(s.rows.prefix(max(1, r)))
                if s.rows.count > body.count { body.append("  … 另 \(s.rows.count - body.count) 条") }
                blocks.append((["  ## " + s.day] + body).joined(separator: "\n"))
            }
            return segmentHeader + "\n" + blocks.joined(separator: "\n")
        }

        var useDays = max(1, days)
        var useRows = max(1, rowsPerDay)
        while true {
            let candidate = build(useDays, useRows)
            if candidate.count <= charLimit { return candidate }
            if useDays > 1 { useDays -= 1 }
            else if useRows > 1 { useRows -= 1 }
            else { return candidate }   // 一天一行还超: 收下它, 让预算超的那一点由调用方记账
        }
    }

    /// `YYYY-MM-DD` —— 与 `dayHeader` 同源，只是不带 `## `。
    static func todayKey(_ date: Date, calendar: Calendar = .current) -> String {
        String(dayHeader(date, calendar: calendar).dropFirst(3))
    }
}
