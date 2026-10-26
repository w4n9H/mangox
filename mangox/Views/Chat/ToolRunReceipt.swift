//
//  ToolRunReceipt.swift
//  「已完成对话组」里, 两段正文之间的那串连续块（**思考 + 工具**）—— 折成一行收据。
//
//  形状与取舍见 boss 2026-10-20 的拍板（三轮才收敛, 别凭直觉改回去）:
//    ① 单位是**组内的一段**（两段正文之间）, 不是整组 —— 整组折会把"正文 → 工具 → 正文"
//       的配对压成一坨: 折叠态下无从判断"这 7 次插在哪两句之间"。按段折 = 收据就在原位置。
//    ② 只有**已完成的组**才折。未完成组（正在跑 / 刚答完还没下一条用户消息）一行不动 ——
//       那正是要盯着看"是不是在瞎干活"的窗口。
//    ③ 段边界是**正文**。`.think` 不算边界: think 与 tool 在 Codex 式回合里是交错的,
//       把 think 当边界会让每段只剩 1 条, 再被 `foldable` 的 count≥2 挡掉 —— 功能等于没做。
//

import SwiftUI

/// 两段正文之间的一串连续块（**思考 + 工具**）。收据 = 这一段的折叠形态, 落点就是它原本的位置。
struct ToolRun: Identifiable, Hashable {
    /// = **段首那条消息**的 id（纯思考段时就是那第一条思考的 id）。
    ///
    /// ⚠️ 必须**内容派生**（不许是数组序号、更不许 `UUID()`）: 折叠态按这个 id 记,
    ///    id 一不稳, 每来一条新工具盒里那格"已展开"就被重置成收起 —— 与 Tune 里那几条
    ///    "点 A 开 B"的账是同一族。
    let id: UUID
    /// 成员**消息** id（含段首, 时间序）。用于计数与断言。
    ///
    /// ⚠️ 与 `tools[i].id` **不是一回事**: 前者是聊天流的行 id, 后者是工具调用 id。
    ///
    /// ⚠️ **别拿它的个数当"要跳过的行数"** —— 段中间可能夹着 `.think`（不是边界），
    ///    成员在组内**不连续**, 按条数跳会把夹在中间的行留在原地 ⇒ 那一条工具会
    ///    "既算进收据、又单独画一行"（2026-10-20 boss 截图实测）。跳行只认 `span`。
    let memberIds: [UUID]
    let tools: [ToolCall]
    /// 段内的**内层调用**（`parentId != nil` —— codemode 脚本里的 `tools.bash(...)`）。
    ///
    /// 为什么要单独一栏、而不并进 `tools`：内层**不占可见行**（顶层投影把子行摘掉了，
    /// 画在父卡的展开区里）⇒ 它们既不该进收据的「N 次工具调用」、也不该进耗时之和
    /// （内层的时间已经被父卡包着了，再加一遍就是重复计费）。
    ///
    /// ⚠️ 但**相态判定必须看它们**：内层一条 `error` 被折进收据里，就等于把那次失败
    ///    从界面上抹掉了 —— `ToolCallCardView` 的「失败不许自己缩回」是既有红线。
    ///    同理 `awaitingApproval`：父卡会替它亮红，折起来就看不见了。
    let nested: [ToolCall]
    /// 段内**思考块**的条数。
    ///
    /// 2026-10-20 boss 定: **正文之间的一切都收** —— 思考块不再是"单独一行 Reasoning" +
    /// 收据一行，而是一起进收据。所以它既要计入这里（收据上要报出来），也不参与 `foldable`
    /// 的相态判定（思考没有 `.done`）。
    let thinkCount: Int
    /// 本段在**输入数组**里的下标范围（含首尾）。覆盖段内被跨过的非工具行（典型：`.think`）。
    ///
    /// 它存在的**全部理由** = 让视图层按"真实占了几行"前进, 而不是按工具个数。
    let span: Range<Int>

    var count: Int { tools.count }

    /// 耗时之和（缺 `durationMs` 的按 0 计 —— 不猜）。
    var totalMs: Int { tools.reduce(0) { $0 + ($1.durationMs ?? 0) } }

    var durationText: String? {
        guard totalMs > 0 else { return nil }
        // ⚠️ 与 `ToolCallCardView.phaseBadge` **同一口径**（≥1s 换 x.xs）: 两处不一致就会
        //    出现"收据说 1.2s、点开每一行都写 800ms", 看上去像有一条在说谎。
        return totalMs >= 1000 ? String(format: "%.1fs", Double(totalMs) / 1000) : "\(totalMs)ms"
    }

    /// 类型分布, **按首次出现排序**（同一批数据重放两次必得同一顺序 ⇒ 收据不跳字）。
    var kindCounts: [(kind: ToolKind, count: Int)] {
        var order: [ToolKind] = []
        var tally: [ToolKind: Int] = [:]
        for t in tools {
            if tally[t.kind] == nil { order.append(t.kind) }
            tally[t.kind, default: 0] += 1
        }
        return order.map { ($0, tally[$0] ?? 0) }
    }

    /// 能不能折。
    ///
    /// **纯思考段一律折**，有工具的段另有两条硬条件。
    var foldable: Bool {
        // ① 纯思考段（`tools.isEmpty`）: **不收白不收**。
        //    2026-10-20 boss 截图: 一屏里第一段是裸露的 `Reasoning`, 后面每段都是收据 ⇒
        //    两种形态混排, 看着就像"漏了一行没折"。规则"正文之间的一切都收"本来没有例外。
        //    ⚠️ 收它的理由**不是省高度**（`ThinkingCardView` 折叠态本来就是一行, 23pt → 23pt,
        //    持平, 还多一次点击）—— 上一版正是只算了高度就把它排除了。真正的收益是**秩序**:
        //    用户不用猜"这一段为什么没折"。
        if tools.isEmpty { return nested.isEmpty && thinkCount > 0 }

        // ② 判据是**可见行数**，不是 `span.count`。
        //    `span` 覆盖段内**真实占的位置**（含内层调用行），但内层**不出顶层行**
        //    （`ChatView` 按 `parentId` 摘掉了）⇒ 用 `span.count` 会把内层算成"看得见的行"。
        //    症状: 一条 `codemode` + 2 条内层 ⇒ `span.count == 3` ⇒ 以为"3 行值得折"，
        //    实际屏上只有 1 行，折起来省 0pt 却多一次点击（正是 2026-10-20 那条"1 条不折"的反面）。
        // ③ 全部 `.done`: 含 `error` / 待审 / `running` 的段**必须原样露出**。
        //    `ToolCallCardView` 定的"失败不许自己缩回、待审必须问人"是既有红线,
        //    新机制**不许旁路**它 —— 折掉一条 error 行, 等于让人以为这组干干净净。
        //    ⚠️ 相态要连**内层**一起看（内层出事时父卡会替它亮红，折起来就看不见了）。
        let visible = tools.count + thinkCount
        return visible >= 2 && (tools + nested).allSatisfy { $0.phase == .done }
    }
}

// MARK: - 嵌套调用（codemode 的父子）与聊天行的对应
//
// ⚠️ 这一节存在的理由是一次**零红灯的消失**（2026-10-26 boss 截图）：内层 bash 既不在顶层
//    占行、又没出现在父卡的展开区里 —— 界面上凭空少了 5 次调用，编译、冒烟、构建全绿。
//    根因是**两种 id 混用**：`ToolCall.parentId` 存的是父卡**工具** id，而聊天流按
//    **消息** id 找宿主（`ChatMessage.id != ToolCall.id`，见 `ToolRun` 顶部那条注）。
//    ⇒ 这类"键对不上就静默丢"的东西必须收进一个能断言的纯函数里，别散在视图里现算。

enum ToolNesting {
    /// 一趟扫完的嵌套索引。**`children` 与 `attached` 必须出自同一次扫描。**
    ///
    /// ⚠️ 这两张表是同一个事实的两面（"子卡挂在哪" / "哪些子卡挂上了"），分两次算就等于
    ///    允许它们**各自为政**。2026-10-26 已经被这个形状咬过一次：`ChatView` 按一张表摘行、
    ///    按另一张表找宿主，两边判据略一岔开，子卡就**凭空消失**（编译/冒烟/构建全绿）。
    ///    现在它们只能一起产出，形态上不允许分家。
    struct Index {
        /// 宿主**消息** id → 挂在它上面的子卡（时间序）。
        var children: [UUID: [ToolCall]]
        /// **真的挂上了**父卡的工具调用 id（= `children` 里出现过的那些，同源派生）。
        var attached: Set<UUID>
    }

    /// 父卡**工具** id → 承载它的那条**消息** id。
    ///
    /// 子卡要挂到父卡的展开区里，而展开区是**按消息 id** 索引的（`ChatView` 遍历的是
    /// `MessageRow`）⇒ 中间必须过这一道翻译。
    static func hostMessageIds(in messages: [ChatMessage]) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for m in messages {
            if case .tool(let t) = m.content { out[t.id] = m.id }
        }
        return out
    }

    static func index(in messages: [ChatMessage]) -> Index {
        let hosts = hostMessageIds(in: messages)
        var children: [UUID: [ToolCall]] = [:]
        var attached: Set<UUID> = []
        for m in messages {
            // ⚠️ 判据不能只看 `parentId != nil`：父卡那条工具消息不在这批消息里时（压缩截断、
            //    老会话只留半截、父卡没建出来就被丢事件），子卡既被摘掉顶层行、又没有宿主可挂 ⇒
            //    **凭空消失**。宁可在外面多露一行 —— 多一行是噪音，少一行是骗人。
            guard case .tool(let t) = m.content, let pid = t.parentId,
                  let host = hosts[pid] else { continue }
            children[host, default: []].append(t)
            attached.insert(t.id)
        }
        return Index(children: children, attached: attached)
    }

    static func childrenByHostMessage(in messages: [ChatMessage]) -> [UUID: [ToolCall]] {
        index(in: messages).children
    }

    static func attachedToolIds(in messages: [ChatMessage]) -> Set<UUID> {
        index(in: messages).attached
    }
}

enum ToolRunBuilder {

    /// 把**一组内**的消息切成若干段。
    ///
    /// 边界 = 正文（`.text`，且非空白）/ 计划卡（`.plan`）/ 压缩标记（`.compaction`）。
    /// ⇒ 两段正文之间的**一切**（思考 + 工具）属于同一段。
    ///
    /// - Parameter attached: **谁挂上了父卡**（`ToolNesting.Index.attached`）。
    ///   ⚠️ 必须是**会话级**的那份，不能在本函数里按传进来的 `messages` 现算 —— 传进来的
    ///   只是**一组**，而子卡的父卡可能不在这一组里（压缩插了 `.system`、老会话只留半截）。
    ///   本函数自己现算就会把那种子卡当成"看得见的一行"计进 `count`，而 `ChatView` 那边
    ///   按会话级的表**已经把它的行摘掉了** ⇒ 两个数对不上，且谁都不报错。
    ///   同一个判据只许有**一个来源**，由调用方算一次传进来（那里本来就要算）。
    static func runs(in messages: [ChatMessage], attached: Set<UUID>) -> [ToolRun] {
        var out: [ToolRun] = []
        var head: UUID?
        var start = 0        // 段首块的下标
        var last = 0         // 段内**最后一块**的下标
        var ids: [UUID] = []
        var acc: [ToolCall] = []
        var inner: [ToolCall] = []
        var thinks = 0

        func flush() {
            // ⚠️ **纯思考段也要产出**。2026-10-20 boss 截图: 两段正文之间只有一段思考时,
            //    它原样露在外面, 而旁边每段都是收据 ⇒ 一屏两种形态。
            //    文案侧由收据自己分派（没有工具就不印"0 次工具调用"）。
            if let head {
                // ⚠️ 上界用 `last + 1`（**段内最后一块**的位置）而不是数组长度 ——
                //    段后面的正文不属于这一段，不能一起吞掉。
                out.append(ToolRun(id: head, memberIds: ids, tools: acc,
                                   nested: inner, thinkCount: thinks,
                                   span: start..<(last + 1)))
            }
            head = nil
            ids = []
            acc = []
            inner = []
            thinks = 0
        }

        for (i, m) in messages.enumerated() {
            switch m.content {
            case .tool(let t):
                if head == nil { head = m.id; start = i }
                ids.append(m.id)
                // 内层调用（`parentId != nil` 且宿主在）与顶层工具分开记：前者不出可见行（见 `nested`）。
                // ⚠️ 但**照样更新 `last`** —— `span` 要覆盖它们真实占的位置，
                //    否则视图层按 span 前进时会落后，把内层行当普通行再画一遍。
                if attached.contains(t.id) { inner.append(t) } else { acc.append(t) }
                last = i
            case .think:
                // 思考**属于这一段**（boss: 正文之间的一切都收）: 既不切段, 也不单独留行。
                if head == nil { head = m.id; start = i }
                thinks += 1
                last = i
            case .text(let s):
                // ⚠️ **空白正文不作边界**: pi 的文本块可能落成空串/纯空白, 它夹在两次工具
                //    之间时若当边界, 会把一串工具切成"4 条 + 1 条", 而那 1 条又因 span<2
                //    不折 ⇒ 看上去就是"漏了一个工具"。
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                flush()
            case .plan, .compaction:
                flush()
            }
        }
        flush()
        return out
    }
}

// MARK: - 收据行

/// 一段工具调用的**折叠形态**。整行可点 = 展开 / 收起。
///
/// 展开时它**留着**当这段的头（chevron 朝下 + 原来的工具行接在下面）——
/// 与 `ToolCallCardView` 的"header 常驻、body 可收"是同一套交互语法,
/// 不这样的话"展开以后怎么收回"就没有入口了。
struct ToolRunReceiptRow: View {
    let run: ToolRun
    let isExpanded: Bool
    let onToggle: () -> Void

    /// 类型分布 + 思考段数。
    ///
    /// 思考计数排在类型串末尾: 它答的是"这一堆里还夹着几段思考", 而不是另一种工具。
    /// 全都没有时返回空串（不打印一个空的间隔号）。
    private var detailText: String {
        var parts = run.kindCounts.map { "\($0.kind.label) \($0.count)" }
        if run.thinkCount > 0 {
            parts.append(String(format: L("思考 %lld"), run.thinkCount))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 12)

                // verbatim + String(format:): `L()` 禁插值（禁令 ⑤）, 数字也不该被
                // LocalizedStringKey 加上千位分隔符。
                //
                // ⚠️ **纯思考段不印"0 次工具调用"**: 那是在报一个不存在的数, 还会被读成
                //    "这段什么也没干"。此时整行就是 `detailText`（= `思考 N`）。
                if run.count > 0 {
                    Text(verbatim: String(format: L("%lld 次工具调用"), run.count))
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textSecondary)
                }

                Text(verbatim: detailText)
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let d = run.durationText {
                    Text(verbatim: d)
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            // ⚠️ 聊天流里的内嵌面一律 `bgCard`（比正文面**亮**一档, 与代码块/输出区同族）。
            //    用 `bgBase` 就是在正文面上挖近黑洞 —— 暗色实测 3.01× 亮度差。
            .background(CodexTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 文案不说"工具调用" —— 纯思考段也走这一行, 说工具就是在说谎。
        .help(isExpanded ? L("收起这一段过程") : L("展开这一段过程"))
    }
}
