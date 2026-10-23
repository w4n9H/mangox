//
//  TurnBill.swift
//  MangoX
//
//  **轮末的账**（2026-10-22） —— 一轮讲完，花了多久、动了哪些文件、调了几次工具。
//
//  四条判据（都不是审美）：
//   ① **没有成功 / 失败**。一轮不是一次工具调用，它没有退出码：编译没过时我会改一版继续跑，
//      到轮末早就处理完了；用户按了停止也只是"讲完了"。给它挂状态词 = 替用户下结论。
//      （暗色下 `toolError` 只有 3.74:1，红字本来也过不了 AA —— 这条以前是配色问题，
//       现在连"要不要红"这个问题本身都不存在了。）
//   ② **一轮只记一次，挂在轮末那段正文的工具条右端**。那一行的高度**本来就在文档流里常驻**
//      （见 `ChatView.footerToolbar` 的注释）⇒ 塞进去不改变版面、不抖。
//      另起一行会让两排小字同基线、同字号、同灰度 —— 读起来像同一组东西的下半截，
//      分不出哪一排是动作、哪一排是账（贴截图指出来的就是这个）。
//   ③ **缺的字段整段不显示**（耗时 / token 缺了就消失），不报 0、不编数。
//   ④ 账**不落库**：调用数 / token / 文件全都能从 `messages` 重算。唯一例外是耗时 ——
//      它只有"本进程内看着它跑完"才有（见 `TurnBill.elapsed`）。
//

import AppKit
import SwiftUI

/// 一轮（一次提问 → agent 讲完）的账。
struct TurnBill: Equatable {
    /// 实测耗时（秒）。
    ///
    /// ⚠️ `nil` = **没实测到**，此时那一格不显示。**绝不用首末消息的时间戳硬凑** ——
    ///    消息的 `timestamp` 是它**开始**流式的时刻（`ChatMessage` 建出来时赋的，之后
    ///    upsert 只改 content），末条正文的跨度会明显偏短：一整轮 2:14 会显示成 1:20 左右，
    ///    而那是个**看起来合理的错数**，比没有更糟。
    var elapsed: TimeInterval?
    /// 工具调用次数（按 `ToolCall.id` 去重）。
    var calls: Int
    /// 本轮 token 总数。`0` = 库里没有 usage（老会话）⇒ 整段不显示。
    var tokens: Int
    /// 本轮改到的文件（相对项目根，新 → 旧去重）。
    var files: [String]

    /// 一句都说不出来时不画这一行（极老会话 / 空轮）。
    var isEmpty: Bool { elapsed == nil && calls == 0 && tokens == 0 && files.isEmpty }

    /// `02:14`。超过 1 小时也照分钟数写（`74:03`）—— 一轮到头也就几十分钟，
    /// 多一层 `h` 只是给一个不会用到的区间加格式。
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// `18.4k` / `940`。与 `DiffStatView.short` 同一套口径（千位缩写），但**不共用实现** ——
    /// 那边是行数徽标（9pt、带 +/− 号），这边是 token；两处口径相同是巧合，不是契约。
    static func shortNumber(_ n: Int) -> String {
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    /// 数字 + 名词。**单复数分开取词**（英文 `1 file` / `5 files` 各一条词条）——
    /// 不靠 `%lld files` 硬套，那在 n = 1 时是错的（与 `AwaySummaryPill` 同一套办法）。
    static func count(_ n: Int, one: String, many: String) -> String {
        n == 1 ? one : String(format: many, n)
    }
}

// MARK: - 算账

enum TurnBillBuilder {

    /// 一轮的账。`group` = 该轮的**全部**消息（含那句用户提问）。
    ///
    /// 纯函数（只吃 `[ChatMessage]`）⇒ 冒烟能直接喂一串夹具消息断言，不需要真跑一场对话。
    /// - Parameter elapsed: 实测耗时。视觉层的落地点把它传进来（`ChatStore.turnElapsed`），
    ///   传 `nil` 就是"这一轮没有这个数"。
    static func bill(group: [ChatMessage], elapsed: TimeInterval?, root: String?) -> TurnBill {
        var seenTools: Set<UUID> = []
        var calls = 0
        var tokens = 0
        for m in group {
            if case .tool(let t) = m.content, seenTools.insert(t.id).inserted { calls += 1 }
            if let u = m.usage { tokens += u.totalTokens }
        }
        return TurnBill(elapsed: elapsed, calls: calls, tokens: tokens,
                        files: AgentTouched.paths(in: group, root: root))
    }
}

// MARK: - agent 触达集（工作区与本文件**同源**）

/// agent 触达集。
///
/// ⚠️ 装进一个 caseless enum 而不是写成自由函数: 视图里有个同名私有方法
///    `agentTouchedPaths(root:)`（本会话口径），自由函数会被那条**同名实例方法遮住** ——
///    实测报 "use of 'agentTouchedPaths' refers to instance method rather than global function"。
///    加个命名空间比"记得别重名"可靠。
enum AgentTouched {

    /// 这批消息里 agent 触达过的文件（edit / write 工具，新 → 旧去重），相对项目根。
    ///
    /// ⚠️ **认哪些工具算"改动"必须是同一个判据**：工作区「改动」tab 数的是"本会话"，
    ///    轮末账单数的是"本轮" —— 范围不同，但**成员判据**必须一致，否则同一批文件在两个
    ///    地方对不上（一个说改了 5 个、另一个说 4 个，而两边都不报错）。
    static func paths(in messages: [ChatMessage], root: String?) -> [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for msg in messages.reversed() {
            guard case .tool(let t) = msg.content,
                  t.kind == .edit || t.kind == .write else { continue }
            let rel = workspaceRelativePath(t.title, root: root)
            guard !rel.isEmpty, seen.insert(rel).inserted else { continue }
            order.append(rel)
        }
        return order
    }
}

/// 绝对路径剥 root 前缀；本来就是相对路径的原样返回；**不认识的绝对路径返回空串**。
///
/// ⚠️ 返回空串（而不是原值）是有意的：项目外的文件不属于"这一轮改了什么"，
///    把它塞进列表会变成一条点不开的行。
func workspaceRelativePath(_ path: String, root: String?) -> String {
    if let root, !root.isEmpty, path.hasPrefix(root) {
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    return path.hasPrefix("/") ? "" : path
}

// MARK: - 轮末那一行（工具的右端那一截）

/// 轮末的账 —— 一条**尾注**，住在消息底部工具条的右端。
///
/// 静息只露这一截；悬停时左边的复制 / 分享 / 记忆 / 重新生成才长出来（`ChatView` 管那一半）。
/// 点它出小弹窗 —— 明细在浮层里，所以它自己占不了一分版面。
struct TurnBillChip: View {
    let bill: TurnBill
    let root: String?
    @ObservedObject var store: ChatStore

    @State private var showPopover = false
    @State private var hovering = false

    var body: some View {
        Button { showPopover = true } label: {
            HStack(spacing: 5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                    if i > 0 { Text("·").foregroundStyle(CodexTheme.textMuted) }
                    Text(s)
                }
                Text("›").foregroundStyle(CodexTheme.textMuted)
            }
            .font(CodexTheme.fontTiny)
            .foregroundStyle(hovering ? CodexTheme.textSecondary : CodexTheme.textTertiary)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .help(L("这一轮花了什么"))
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            // 跳走时**先关浮层再跳** —— 否则工作区从右边长出来、浮层还悬在消息上，
            // 而它锚着的那一行可能已经被挤到视野外了。
            TurnBillPopover(bill: bill, root: root, store: store,
                            onOpenWorkspace: { showPopover = false })
        }
    }

    /// 一行能说完的片段。**0 的不占位** —— "改了 0 个文件"比空着更吵，
    /// 而"到底改没改"这件事弹窗里写着（`本次没有改动文件`）。
    private var segments: [String] {
        var out: [String] = []
        if let e = bill.elapsed { out.append(TurnBill.duration(e)) }
        if !bill.files.isEmpty {
            out.append(TurnBill.count(bill.files.count, one: L("1 个文件"),
                                      many: L("%lld 个文件")))
        }
        if bill.calls > 0 {
            out.append(TurnBill.count(bill.calls, one: L("1 次调用"),
                                      many: L("%lld 次调用")))
        }
        return out
    }
}

// MARK: - 小弹窗

/// 点开之后的明细。**只有账，没有结论**（没有"完成 / 失败"，没有重试按钮）。
///
/// 面用 `bgElevated`（比正文面亮两档）+ `border` 描边 —— 浮层必须一眼看出"这是另一个层"，
/// 它也是这整个设计里唯一一处允许压住内容的东西。
struct TurnBillPopover: View {
    let bill: TurnBill
    let root: String?
    @ObservedObject var store: ChatStore
    /// 跳去工作区之前先收浮层（由 `TurnBillChip` 提供，它才是 `isPresented` 的主人）。
    var onOpenWorkspace: () -> Void = {}

    /// 打开时才跑一次 `git status`。**不跟会话流同步**：一份账单不该为它多开一条命令，
    /// 而弹窗是用户自己点的，那一刻取一次就够；取不到（非 git / git 不可用）就只少那一列数字。
    @State private var git: WorkspaceGit.Status?
    @State private var copied = false

    private let width: CGFloat = 300
    private let maxRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !usageSegments.isEmpty {
                Text(usageSegments.joined(separator: " · "))
                    .font(CodexFonts.monoFont(11))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .padding(.top, 4)
            }
            hairline.padding(.vertical, 9)
            filesSection
            hairline.padding(.vertical, 9)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: width, alignment: .leading)
        .background(CodexTheme.bgElevated)
        .task {
            guard let root, !root.isEmpty else { return }
            git = await Task.detached { WorkspaceGit.status(root: root) }.value
        }
    }

    private var hairline: some View {
        Rectangle().fill(CodexTheme.divider).frame(height: 1)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L("本轮"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer(minLength: 8)
            if let e = bill.elapsed {
                Text(TurnBill.duration(e))
                    .font(CodexFonts.monoFont(11))
                    .foregroundStyle(CodexTheme.textTertiary)
            }
        }
    }

    /// `12 次调用` · `18.4k tokens`。两个都缺就整段不出现（不画一行空的）。
    private var usageSegments: [String] {
        var out: [String] = []
        if bill.calls > 0 {
            out.append(TurnBill.count(bill.calls, one: L("1 次调用"),
                                      many: L("%lld 次调用")))
        }
        if bill.tokens > 0 {
            out.append(TurnBill.shortNumber(bill.tokens) + " " + L("tokens"))
        }
        return out
    }

    @ViewBuilder
    private var filesSection: some View {
        if bill.files.isEmpty {
            Text(L("本次没有改动文件"))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textTertiary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TurnBill.count(bill.files.count, one: L("1 个文件"),
                                    many: L("%lld 个文件")))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer(minLength: 8)
                if let (added, deleted) = addedDeleted, added + deleted > 0 {
                    // 与工作区 tab **同一个视图**（`DiffStatView`）：同一个数字不该有两个样子。
                    DiffStatView(stat: WorkspaceGit.DiffStat(added: added, deleted: deleted))
                }
            }
            ForEach(bill.files.prefix(maxRows), id: \.self) { rel in
                fileRow(rel)
            }
            if bill.files.count > maxRows {
                Text(String(format: L("还有 %lld 个"), bill.files.count - maxRows))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textTertiary)
                    .padding(.top, 1)
            }
        }
    }

    private func fileRow(_ rel: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            // 字母徽标与工作区树 / 改动列表**同源**（`workspaceGitLetterColor`）——
            // 同一个 `M` 在两个地方两种颜色是最容易发生、也最难发现的那种漂移。
            if let letter = git?.changes[rel] {
                Text(letter)
                    .font(CodexFonts.monoFont(11))
                    .foregroundStyle(workspaceGitLetterColor(letter))
            } else {
                // git 没跑到 / 这个文件已经被提交或还原了：留空位，别画一个假的 `M`。
                Spacer().frame(width: 7)
            }
            Text((rel as NSString).lastPathComponent)
                .font(CodexFonts.monoFont(11))
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let st = git?.stats[rel] {
                DiffStatView(stat: st)
            }
        }
        .help(rel)   // 同名文件靠 tooltip 分（列表里放全路径会把名字挤没）
        .frame(height: 18)
    }

    /// 本轮文件的行数汇总。**只在 git 认得的文件上累加** —— 认不出的那几个不进分母，
    /// 否则页面上的 `+1020` 会跟列表里能看见的那些行对不上。
    private var addedDeleted: (Int, Int)? {
        guard let git else { return nil }
        var a = 0, d = 0
        for f in bill.files {
            guard let st = git.stats[f] else { continue }
            a += st.added
            d += st.deleted
        }
        return (a, d)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                onOpenWorkspace()
                store.openWorkspaceChanges()
            } label: {
                HStack(spacing: 3) {
                    Text(L("在工作区打开"))
                    Text("›").foregroundStyle(CodexTheme.textMuted)
                }
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.accent)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(copyPayload, forType: .string)
                copied = true
            } label: {
                Text(copied ? L("已复制") : L("复制"))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    /// 复制出去的是一段**纯文本账单**（贴到别处就能读，不依赖这个界面）。
    private var copyPayload: String {
        var lines: [String] = []
        var head: [String] = []
        if let e = bill.elapsed { head.append(TurnBill.duration(e)) }
        head.append(contentsOf: usageSegments)
        if !head.isEmpty { lines.append(L("本轮") + " " + head.joined(separator: " · ")) }
        if bill.files.isEmpty {
            lines.append(L("本次没有改动文件"))
        } else {
            lines.append(TurnBill.count(bill.files.count, one: L("1 个文件"),
                                        many: L("%lld 个文件")))
            for f in bill.files { lines.append("- " + f) }
        }
        return lines.joined(separator: "\n")
    }
}
