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
    /// 本文件只认它的**形状**: 通则（第一个 `## ` 之前）+ 若干个 `## 名字 · bundle [· bundle…] · 版本` 节。
    /// `## ` 这一级就是**注入边界**（节头里出现的 `com.xxx` 就是这一节注入给谁）; 一个 bundle 都
    /// 认不出的节整节丢弃。一个节可以挂多个 bundle（浏览器那节）, 命中任何一个就整节注入。
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
    /// ⚠️ 扩这个集合 = 两处一起改: 这里 + `SopManual.text` 里让它出现在某一节的节头
    ///    （不同 App 就加一节; **同一类操作**的 App 加进已有那一节的节头, 如浏览器）。
    ///    不同步会被 `missing` 点名, 冒烟的「手册本体」判据也会红。
    static let builtins: Set<String> = [
        "com.apple.Notes",      // 备忘录 128 节点 / 193ms
        "com.apple.iCal",       // 日历   130 行（月视图）/ 450ms
        // ⚠️ 邮件 2026-11-04 移出（boss 定）: 本机邮箱没配置，手册与探针都不再覆盖它。
        //    收件箱那条实测（799 封 = 3000 节点 / 200 秒）仍然是超时规则的依据，留在 run.sh 注释里。
        "com.apple.reminders",  // 提醒事项 54 节点 / 42ms
        "com.apple.finder",     // 访达   列表视图 291 行 / 1.4 秒
        // ⚠️ Safari 排在最后: 手册的节序 = 优先级（超预算从后往前掉），而它是这批里
        //    最不确定的一个。2026-11-06 实测: 起始页 109 节点 / 71 行 / 369ms；
        //    一个内容页 2504 节点 / **1598 行** / 781ms（渲染上限对它放开到 3000，
        //    见 `AXSnapshot.renderLineLimit`）。网页内容**照常可动**（⑤b 已于 11-09 撤）。
        "com.apple.Safari",     // Safari 网页 1598 行 / 2504 节点 / 781ms
    ]

    /// 手册覆盖的**第三方** App —— **装了才列**, 不能像内置那样写死。
    ///
    /// 为什么单开一张表（2026-11-10 boss: 「内置应用可以写死，这种你需要考虑用户是否安装了」）:
    ///   · `builtins` 的语义是**恒列** —— 出现在设置页, 不装也有一行。这对内置 App 成立
    ///     （它们跟着系统来）; 对第三方就是**给一个永远读不到东西的勾选框**（没装 Chrome 的人
    ///     勾上它, 只会得到"它现在没在跑"）。
    ///   · 但"装了才列"**不等于**"手册不管它": 浏览器那一节的节头写着 Chrome, 注入时要认它
    ///     ⇒ **注入判据是 `covered`, 列列表的判据还要再叠一层"装没装"**（见
    ///     `ComputerSettings.supported(installed:)`）。
    /// 加一个第三方 = 这张表加一行 + 手册里给它一个节头（**渲染上限不够时**再给
    /// `ComputerAppProfile.lineLimits` 加一行）。
    /// ⚠️ 那句"加一行"原来是无条件的, 2026-11-10 加微信时改成条件的: `lineLimits` 是
    ///    **按 bundle 记的渲染上限**, 微信的 AX 恒 3 行、视觉那一路一屏也就几十块, 120 绰绰有余
    ///    ⇒ 给它写一行等于写个默认值, 那是**没有读者的配置**(`ComputerAppProfile` 文件头
    ///    明写"只放有消费者的字段")。网页类（Safari / Chrome）必须写, 因为 120 只够看到页头。
    static let thirdParty: Set<String> = [
        // Chrome 2026-11-10 实测（真源码探针, B 站首页）: 634 节点 / 222 行 / 5300 字 / 184ms,
        // `webarea` + 56 个 `link` + 标签栏的 `radiobutton` 全在 —— 11-09 那条「网页节点恒为 0」
        // 不再复现。⚠️ 新 profile 仍可能是空壳（renderer accessibility 默认不开）
        // ⇒ 手册里"读不到 webarea 就请人开"的那句不能删。
        "com.google.Chrome",
        // 微信 2026-11-10 实测（真源码探针）: 主窗 **5 节点 / 3 行 / 101 字 / 0% 覆盖率**,
        // 3 行全是 14×16 匿名 button。主二进制是 **x86_64（Rosetta）**、只链 Cocoa + 腾讯自家
        // `ilink*` / `andromeda` / `ConfSDKdyn`, **没有 Chromium/Electron**, `strings` 里连
        // `AXManualAccessibility` / `force-renderer-accessibility` 都不存在
        // ⇒ **不是浏览器懒加载, 没有属性开关可解**, 只能走视觉那条路。
        // ⚠️ 它与 Chrome 的差别在于"为什么进名单": Chrome 是 AX 能读但可能空壳,
        //    微信是 AX **恒空**。同一个表(装了才列)装两种理由, 是因为列表的判据是
        //    "装了没装", 不是"能不能读"; 能不能读由设置页那一列「读法」写着。
        "com.tencent.xinWeChat",
    ]

    /// 手册**真正覆盖**的全部 App（**注入**判据）—— 内置 ∪ 第三方。
    ///
    /// ⚠️ 列列表**不许**直接用它: 第三方还要叠"装没装"（写死就是上面那条注释说的病）。
    static var covered: Set<String> { builtins.union(thirdParty) }

    /// 手册里的一节 = 一个 App, **或一类 App**。
    ///
    /// 为什么允许一节挂多个 bundle（2026-11-09 boss 定, 原话「不要区分不同浏览器, 这样太浪费
    /// 为数不多的空间了, 以浏览器操作手册的方向去做」）: 整份预算只有 `Tune.sopTotalCharLimit`, 而**同一件事**在
    /// Safari 与 Chrome 上是同一条路（网页里点东西 / 换页 / 切标签）—— 写成两节等于把同一套
    /// 步骤讲两遍, 还多出一个"两节迟早会漂"的真源。
    ///
    /// ⚠️ 合成节的**唯一**理由是「操作完全一致」。差一条就得分开写: 合成之后模型会把 A 的锚点
    ///    套到 B 上, 而它读不到"这一条只对 Safari 成立"这种括号里的限定 ⇒ 点错且不可逆。
    ///    所以合成节里的锚点只能写**各家都成立**的判据（`webarea` / `radiobutton` / 行数变化）,
    ///    各家不同的按钮名一律写成"按 read 回来的名字找"。
    struct Section: Equatable {
        /// 顺序 = 节头里的书写顺序（多 bundle 时版本也按这个顺序写）。
        let bundles: [String]
        /// 显示名（`## 备忘录 · com.apple.Notes · 4.11` 里的第一段）。
        let title: String
        /// 写手册时那个 App 的版本。空串 = 没写。多 bundle 时按 ` / ` 隔开、顺序同上。
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
    ///   - bundles: 当前**允许碰**的名单（`ComputerSettings.activeAllowedBundles` = 可读 ∪ 视觉）。
    ///     ⚠️ 不是纯读面: 只勾了「视觉」的 App（微信）也该看到自己那一节, 否则它进得了操作面、
    ///        却永远拿不到"怎么做"的说明 —— 那正是它最容易点错的时候。
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
        // 只认**手册覆盖的** App（`covered` = 内置 ∪ 第三方）。名单里**表外**的 App
        // 静默跳过、**不点名**: 它不是"这份手册缺席", 而是"不在这份文档的范围内"。
        let wanted = Set(Array(bundles).filter { covered.contains($0) })
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
        for sec in doc.sections {
            // 这一节在名单里命中了哪些 App（还没进过段的）。多 bundle 的节只要**有一个**命中
            // 就整节注入 —— 正文是各类 App 通用的一套步骤, 拆开就没有意义了。
            // ⚠️ `!seen.contains` 同时也是"同一个 App 写了两节"的兜底: 取第一节, 后面那节自动出局。
            let hit = sec.bundles.filter { wanted.contains($0) && !seen.contains($0) }
            guard !hit.isEmpty else { continue }
            let piece = render(sec, actBundles: actBundles, hit: hit)
            if overflowed || used + piece.count > budget {
                overflowed = true
                out.missing.append(contentsOf: hit.map { Result.Missing(bundle: $0, why: "超预算") })
                continue
            }
            parts.append(piece)
            for b in hit {
                seen.insert(b)
                out.injected.append(b)
            }
            used += piece.count
        }
        // 白名单里有、手册里没这一节 = **两边不同步**（加了 App 忘了写手册）。
        // 这条必须点名: 否则"扩白名单"这个动作永远不会产生任何可见后果。
        //
        // ⚠️ 它必须在下面那道 `parts.isEmpty` 之前算 —— 曾经写在后面, 于是"名单里那个 App
        //    在手册里根本没有一节"这个最需要点名的情形恰好被 `return out` 吞掉, 一条都不会报。
        let inFile = Set(doc.sections.flatMap(\.bundles))
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
    ///
    /// ⚠️ 权限**按 App 各写一次**, 不写"这一节可操作": 合成节里 Safari 可点而 Chrome 只读是
    ///    完全可能的（两个名单各自独立）, 一个节级徽章会对着其中一个说谎 —— 于是模型要么去点
    ///    点不动的东西, 要么放着一堆能点的行不敢动。
    ///     单 bundle: `备忘录 · com.apple.Notes · 可操作 · v4.11`（与旧格式逐字节相同）
    ///     多 bundle: `浏览器 · com.apple.Safari(可操作) · com.google.Chrome(只读) · v26.0.1 / 130`
    static func render(_ sec: Section, actBundles: [String], hit: [String]) -> String {
        let act = Set(actBundles)
        let who: [String]
        if hit.count == 1 {
            who = [hit[0], act.contains(hit[0]) ? "可操作" : "只读"]
        } else {
            who = hit.map { act.contains($0) ? "\($0)(可操作)" : "\($0)(只读)" }
        }
        var meta = [sec.title] + who
        if !sec.version.isEmpty { meta.append("v\(sec.version)") }
        return "\n\n--- " + meta.joined(separator: " · ") + " ---\n" + sec.body
    }

    // MARK: - 解析

    struct Doc: Equatable {
        var preamble: String = ""
        var sections: [Section] = []
    }

    /// 一段手册正文 = **通则**（第一个 `## ` 之前）+ 若干个 `## 名字 · bundle [· bundle…] · 版本` 小节。
    ///
    /// 只认 `## ` 这一级: 节内用 `### 任务` 这一级随便写, 不会被切开。
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
            // 一个都认不出就**整节丢掉并真的丢掉**（不猜）—— 猜错 = 把 A 的手册教给 B。
            let bundles = head.split(whereSeparator: { " ··—-\t".contains($0) })
                .map(String.init).filter(isBundleID)
            guard !bundles.isEmpty else { return }
            // 名字与版本 = 标题里**不是 bundle** 的那几段: 第一段是名字, 最后一段是版本。
            // 中间夹着几个 bundle 就跳过几个, 所以 `名字 · a · b · v` 与 `名字 · a · v` 同一套规则。
            let rest = head.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !isBundleID($0) }
            let title = rest.first ?? bundles[0]
            let version = rest.count >= 2
                ? rest[rest.count - 1].replacingOccurrences(of: "v", with: "")
                : ""
            let body = c.body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            doc.sections.append(Section(bundles: bundles, title: title, version: version, body: body))
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

    /// 标题里一个片段是不是 bundle id（`com.apple.Notes`）。
    ///
    /// ⚠️ 判据是 **`com.` 前缀 + 后面还有至少一个点**, 不是"含点": 版本号 `26.0.1` 也含点,
    ///    按"含点"认的话它会被当成一个 App, 于是每节的 bundle 列表里多出一个 `26.0.1`。
    static func isBundleID(_ s: String) -> Bool {
        s.hasPrefix("com.") && s.dropFirst(4).contains(".")
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
