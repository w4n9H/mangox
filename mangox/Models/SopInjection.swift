//
//  SopInjection.swift
//  P19: 把 macOS **内置应用的操作手册**直接教给模型 —— 第二条注入通道。
//
//  ⚠️ 为什么**不**并进知识注入块（`KnowledgeStore.buildInjection`）:
//     那一块的语义是「我是谁 / 我知道什么」, 四段有序（persona 结构性首位 / 守卫 10 与 17）、
//     共用 64000 字预算、按 priority 降级。SOP 是「在这个 App 里怎么下手」, 生命周期也不一样
//     （跟着 computer use 的**开关与名单**走, 不跟着知识库走）。混进去会让两套判据互相牵制,
//     而"段序"与"预算"一旦被第二件事共用, 谁都不能单独改。
//     ⇒ 走**第二个** `--append-system-prompt`。pi 侧是数组 + `join("\n\n")`
//       (`dist/core/agent-session.js:1283`, 实测确认), 两条各自完整, 不存在"后一条顶掉前一条"。
//
//  ⚠️ 为什么是**一份**（2026-11-02 boss 定）: 六节分开存, 每次改动要在六处同步一套口径
//     （通则、格式、验证日期）—— 那是六个会各自漂移的真源。一份 + 按 App 分节, 通则只写一次,
//     预算也只算一次。
//
//  ⚠️ 为什么正文住在**代码里**（同一天, boss: 「我不想这个内容以文本的形式保存, 换机器还得带走」）:
//     它是**产品自带的知识**, 不是用户数据 ⇒ 该跟着版本走, 而不是"还得记得把那个目录带过去"。
//     落点 = `SopManual.text`; **本文件只负责挑哪些节、怎么拼**, 手册一个字都不在这儿。
//     代价明说: 改一条锚点 = 改代码 + 重编译 + 发版（不再是"改完重启对话"）。
//     ⇒ 于是这里**没有**"文件读不到"那一支: 常量要么在, 要么编译不过。
//
//  ⚠️ 本文件的产出**恒中文**: 它是注入给模型的文本, 不是界面文案 ⇒ 不进 `gen_strings.py` 词表
//     (与 `KnowledgeStore` 的注入面同一条纪律, 那个文件也在 `EXCLUDE_FILES` 里)。
//

import Foundation

/// 把「当前名单内内置应用的 SOP」组装成一段可直接拼进系统提示词的文本。
///
/// 纯函数: 输入 = 名单 + 手册正文 + 日期 + 时钟 + 预算, 输出 = 文本与诊断。**不碰网络、不碰 DB、
/// 不碰 App、不碰磁盘**, 所以冒烟能在任何上下文里直接把每条判据断言掉。
enum SopInjection {

    /// 段头 token。**恒不本地化、不许改**: 它是注入文本的契约字面量,
    /// 与 `[笔记]` / `AgentMode` 的 tool face 同族 —— 改了等于换了一套协议。
    static let token = "[SOP]"

    /// 手册正文住在 `SopManual.text`（**格式契约与五条硬约束写在那个文件头**, 这里不重复）。
    /// 本文件只认它的**形状**: 通则（第一个 `## ` 之前）+ 若干个 `## 名字 · bundle · 版本` 节。
    /// `## ` 这一级就是 App 的边界（节头里的 `com.xxx` 决定注入给谁）; 认不出 bundle 的节整节丢弃。
    /// ⚠️ 手册是**代码**（不是用户可改的文件）⇒ 唯一会漂的是"白名单加了 App 但手册没加节",
    ///    那一条由 `block` 点名（`missing.why = "手册里没有这一节"`）+ 冒烟 `T-SOP 手册本体` 守着。

    /// 陈旧阈值: 多久没复验就不再当"现在成立"用。与 P15 的 `staleAfterDays` 同一口径
    /// （**mtime 管陈旧 / 探针管正确, 两条不许合述**）。
    static let staleAfterDays = 30

    /// 手册**只覆盖 macOS 内置应用**（2026-11-02 boss 定）。
    ///
    /// 为什么要有白名单, 而不是"手册里写了什么就注入什么":
    ///   ① **范围就是承诺** —— 这几个是**真机量过**的（`scripts/diag/ax_coverage_probe.sh`）。
    ///   ② 内置 App 的界面是系统给的、跨用户基本一致; 第三方 App 每个版本都能重排,
    ///      手册折旧速度完全不是一个量级。
    ///   ③ 白名单让"注入量"有上限。
    /// ⚠️ 扩这个集合 = 两处一起改: 这里 + `SopManual.text` 里加一节（不同步会被 `missing` 点名,
    ///    冒烟的「手册本体」判据也会红）。
    static let builtins: Set<String> = [
        "com.apple.Notes",      // 备忘录 129 节点 / 268ms
        "com.apple.iCal",       // 日历   625 节点 / 781ms
        "com.apple.Music",      // 音乐   155 节点 / 243ms
        "com.apple.mail",       // 邮件   收件箱 3000 节点 / 200 秒（手册写"别直接读"）
        "com.apple.reminders",  // 提醒事项 54 节点 / 90ms
        "com.apple.finder",     // 访达   列表视图 ~800 节点
    ]

    /// 手册里的一节 = 一个 App。
    struct Section: Equatable {
        let bundle: String
        /// 显示名（`## 备忘录 · com.apple.Notes · 4.11` 里的第一段）。
        let title: String
        /// 写手册时那个 App 的版本。空串 = 没写。
        let version: String
        let body: String
    }

    /// 组装结果。`text == nil` = 这一轮没有这一段。
    struct Result: Equatable {
        struct Missing: Equatable {
            let bundle: String
            let why: String
        }
        var text: String?
        var injected: [String] = []
        /// 名单里有、但这次没能进段的 —— **必须点名**, 否则模型会以为"没有这个 App 的手册",
        /// 而实际是"这次没带上"或"手册里漏了这一节"。
        var missing: [Missing] = []
        var chars: Int { text?.count ?? 0 }
    }

    /// codemode 档专用的一段。**只有真的挂着 codemode 扩展时才拼进去**。
    ///
    /// ⚠️ 为什么这段住在代码里、不写进手册文件: 它讲的是**客户端档位**（那一档只留 codemode
    ///    一个工具, 其余全部经脚本内层调用）, 不是某个 App 的界面。写进文件就变成"完整档也
    ///    被告知去写脚本", 而那一档根本没有 `codemode` 这个工具 ⇒ 模型会去调一个不存在的东西,
    ///    白烧一轮。判据只能跟着 `AgentMode.codemode` 走。
    ///
    /// 内容全部有据（2026-11-02 核过）:
    ///   - `tools.<name>(args)` 调工具、脚本在沙箱里跑: pi `docs/codemode.md`
    ///   - act 的回执**只给变化 + 新 seq**: `ComputerServer.finishAct` 拼的是 `AXSnapshot.diff`
    ///     + `新快照 seq=…`, **不是**整份行表 —— 所以"不必再 read"只在"下一步动的还是刚变化的那几行"
    ///     时成立。这一条必须写准: 写宽了模型会拿着平移前的编号去点, 撞上"旧快照"被拒。
    static let codemodeNote = """
    **codemode 档：一次脚本做多步** —— 同一次 read 之后要动 **2 处以上**才值得写脚本（只有一两步别用, \
    codemode 的固定成本比省下来的多）。三条要点:
    ① `tools.computer_act(...)` 的回执是**变化了什么 + 新 seq**, 不是整份新快照 ⇒ 下一步动的若还是\
    **刚变化的那几行**, 直接接着走; 要动**没变**的行就得重新 `tools.computer_read(...)`（插入/删除\
    会让编号平移, 拿旧编号去点会被"旧快照"挡下）;
    ② 省 token 的地方不在"少读", 而在**中间结果不进对话上下文**: read 出来的整份编号表、每次 act 的 diff \
    都只活在脚本变量里, 脚本最后**只 return 一句摘要**（别 return 整份快照: 默认输出上限 10000 token,
    塞满就白省了）;
    ③ **结构不随动作变**的场景最适合串起来（连续填几个输入框、同一列表里批量勾选、连续翻页）;
    一旦动作会**切视图 / 开新窗口**（进收件箱、点开一封邮件）, 结构整个换了, 脚本里"下一行在哪"
    的假设就失效 —— 那种地方每一步都要重新找。
    """

    // MARK: - 组装

    /// - Parameters:
    ///   - bundles: 当前**可读**名单（`ComputerSettings.activeBundles`）。
    ///   - actBundles: 当前**可操作**名单（`activeActBundles`）—— 只用来在节头写清"能不能点"。
    ///   - manual: 手册正文。生产恒为 `SopManual.text`; 冒烟传样本 ⇒ 每条判据都能造边界。
    ///   - verifiedOn: 验手册的那天（`yyyy-MM-dd`）。空串 / 认不出 ⇒ 段头**如实说**"没写",
    ///     绝不拿今天冒充（那是造假, 而且是最没人会去核的一种）。
    ///   - codemode: 当前是不是 codemode 档（决定拼不拼 `codemodeNote`）。
    ///   - now: 时钟可注入 ⇒ 陈旧天数可确定性断言。
    ///   - budget: **各节**的分配额度（`Tune.sopTotalCharLimit`）。⚠️ 段头不计入这里 ——
    ///     它是固定成本（实测全六节 + codemode 段 ≈ 650 字）。"总字数不超预算"这条由冒烟
    ///     `T-SOP 整份注入量` 用**真手册 + 真段头**直接断言, 不靠这里推算。
    static func block(bundles: [String],
                      actBundles: [String],
                      manual: String = SopManual.text,
                      verifiedOn: String = SopManual.verifiedOn,
                      codemode: Bool = false,
                      now: Date = Date(),
                      budget: Int = Tune.sopTotalCharLimit) -> Result {
        var out = Result()
        guard !bundles.isEmpty else { return out }   // 名单空 = computer use 没开/没勾 ⇒ 整段不出现
        // 只认**内置应用**（见 `builtins`）。名单里的第三方 App 静默跳过、**不点名**:
        // 它不是"这份手册缺席", 而是"不在这份文档的范围内"。
        let wanted = Set(Array(bundles).filter { builtins.contains($0) })
        guard !wanted.isEmpty else { return out }
        // 手册是空的 = 没有手册 ⇒ 安静。⚠️ 不许走到下面去拼: 那时每一节都"漏了", 会拼出一个
        // 只有段头 + 「全都没带上」的空壳, 模型读到的意思变成"手册在这里、只是没内容"。
        guard !manual.isEmpty else { return out }

        let doc = parse(manual)

        var parts: [String] = []
        var used = 0
        var seen = Set<String>()
        // 通则在这份手册里只写一次（省 token）, 也只在真注入了至少一节时才带出去。
        let preamble = doc.preamble.trimmingCharacters(in: .whitespacesAndNewlines)
        var overflowed = false
        // 顺序 = **手册里的顺序**, 不是 bundle 排序: 写的人把常用的放前面, 这个顺序
        // 本身就是优先级（超预算从后往前掉）。换成 `sorted()` 的话掉哪一份是随机的。
        // 同时它也**稳定** —— 手册不动, 段内容就逐字节不变（前缀缓存才命得中）。
        for sec in doc.sections where wanted.contains(sec.bundle) {
            guard seen.insert(sec.bundle).inserted else { continue }   // 同一 App 写了两节 = 取第一节
            let piece = render(sec, act: actBundles.contains(sec.bundle))
            if overflowed || used + piece.count > budget {
                overflowed = true
                out.missing.append(Result.Missing(bundle: sec.bundle, why: "超预算"))
                continue
            }
            parts.append(piece)
            out.injected.append(sec.bundle)
            used += piece.count
        }
        // 白名单里有、手册里没这一节 = **两边不同步**（加了 App 忘了写手册）。
        // 这条必须点名: 否则"扩白名单"这个动作永远不会产生任何可见后果。
        //
        // ⚠️ 它必须在下面那道 `parts.isEmpty` 之前算 —— 曾经写在后面, 于是"名单里那个 App
        //    在手册里根本没有一节"这个最需要点名的情形恰好被 `return out` 吞掉, 一条都不会报。
        let inFile = Set(doc.sections.map(\.bundle))
        for bundle in wanted.sorted() where !inFile.contains(bundle) {
            out.missing.append(Result.Missing(bundle: bundle, why: "手册里没有这一节"))
        }
        // 一份都没进, 但**有话要说**（缺节 / 超预算）⇒ 仍然出段: 那句"这次没带上, 自己去 read"
        // 就是可行动的信息。两份都空才是真的没事可说。
        guard !parts.isEmpty || !out.missing.isEmpty else { return out }

        var head = ["\(token) macOS 内置应用操作手册 · \(out.injected.count) 个 App"]
        if !preamble.isEmpty {
            head.append(preamble)
        }
        // codemode 那一段: 跟着**档位**走, 不跟着手册走（见 `codemodeNote` 的注释）。
        if codemode {
            head.append(codemodeNote)
        }
        if let on = dayParser.date(from: verifiedOn) {
            let days = Int(now.timeIntervalSince(on) / 86400)
            var line = "整份手册验证于 \(dayString(on))"
            if days > staleAfterDays { line += " —— ⚠️ \(days) 天前, 界面可能已经变了" }
            head.append(line)
        } else {
            head.append("⚠️ 手册没写验证日期, 当参考不当事实")
        }
        if !out.missing.isEmpty {
            let names = out.missing.map(\.bundle).joined(separator: " / ")
            let why = Array(Set(out.missing.map(\.why))).sorted().joined(separator: " / ")
            head.append("（\(names) 这次没带上（\(why)） —— 那几个 App 请自己 read 界面。）")
        }
        // 段头各块之间留空行: 用 "\n" 拼出来的是一整段连续文字, 通则 / codemode 段 / 日期行
        // 会粘成一大坨（markdown 上就是同一个段落）—— 模型读起来没有段落边界, 哪条属于哪里全靠猜。
        // 各节自带前导 "\n\n"（见 `render`）, 所以 `parts` 直接接在后面。
        out.text = head.joined(separator: "\n\n") + parts.joined()
        return out
    }

    /// 一节在提示词里的样子。节头带**当前**权限与版本 —— 这两件事模型必须能在用之前看到:
    /// 前者决定它能不能点, 后者决定它该不该照着做。
    /// （日期只按**整份**算一次: 见 `SopManual.verifiedOn` 的注释, 逐节记日期会诱导模型去信"某节更新"。）
    static func render(_ sec: Section, act: Bool) -> String {
        var meta = [sec.title, sec.bundle, act ? "可操作" : "只读"]
        if !sec.version.isEmpty { meta.append("v\(sec.version)") }
        return "\n\n--- " + meta.joined(separator: " · ") + " ---\n" + sec.body
    }

    // MARK: - 解析

    struct Doc: Equatable {
        var preamble: String = ""
        var sections: [Section] = []
    }

    /// 一段手册正文 = **通则**（第一个 `## ` 之前）+ 若干个 `## 名字 · bundle · 版本` 小节。
    ///
    /// 只认 `## ` 这一级: 节内用 `##` 以下的小标题（`### 找` 之类）随便写, 不会被切开。
    /// ⚠️ 这里**不认识** frontmatter（`---` 那块）: 手册是代码常量之后, 验证日期是 `SopManual.verifiedOn`
    ///    一个 Swift 常量, 不再是文档里的元数据 —— 同一件事不留两个真源。
    static func parse(_ raw: String) -> Doc {
        var doc = Doc()
        let lines = raw.components(separatedBy: "\n")
        // 通则 = 第一个 `## ` 之前
        var firstSection = lines.count
        for (i, line) in lines.enumerated() where line.hasPrefix("## ") {
            firstSection = i
            break
        }
        doc.preamble = lines[0..<firstSection].joined(separator: "\n")
        // 小节
        var current: (head: String, body: [String])?
        func flush() {
            guard let c = current else { return }
            let head = c.head
            // bundle 从标题里认: 这是"这一节属于谁"的唯一判据。
            // 认不出来就**整节丢掉并真的丢掉**（不猜）—— 猜错 = 把 A 的手册教给 B。
            guard let bundle = firstBundle(in: head) else { return }
            let fields = head.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            let title = fields.first ?? bundle
            let version = fields.count >= 3 ? fields[2].replacingOccurrences(of: "v", with: "") : ""
            let body = c.body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            doc.sections.append(Section(bundle: bundle, title: title, version: version, body: body))
        }
        for line in lines[firstSection...] {
            if line.hasPrefix("## ") {
                flush()
                current = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
            } else if current != nil {
                current?.body.append(line)
            }
        }
        flush()
        return doc
    }

    /// 标题里第一个像 bundle id 的片段（`com.apple.Notes`）。
    static func firstBundle(in head: String) -> String? {
        let parts = head.split(whereSeparator: { " ··—-\t".contains($0) })
        return parts.first { $0.hasPrefix("com.") && $0.contains(".") }.map(String.init)
    }

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    static func dayString(_ d: Date) -> String { dayParser.string(from: d) }
}
