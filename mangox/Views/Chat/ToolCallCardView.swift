//
//  ToolCallCardView.swift
//  Tool row: kind · target · right-side phase badge · optional detail rows.
//
//  P16（0.1.18）: 从"卡"改成"行" —— 对齐 `ThinkingCardView` 的形态（左竖条 + 折叠行）。
//  聊天流里 5 个普通工具从 480pt（占屏 60%）收到 123pt（15%）。判据、取舍、"为什么不做聚合"
//  见 `docs/P16-functional-design.html`。
//

import SwiftUI

struct ToolCallCardView: View {
    let tool: ToolCall
    /// 用户已就这张审批卡做过的选择（真源 = `ChatStore.toolDecisions`）。
    ///
    /// ⚠️ 为什么视图要自带一份：`routeToolDecision` 只做两件事 —— 转发 transport + 清
    /// `approvalBlocked`。**`phase` 原地不动**（要等 agent 回事件才流转）⇒ 不给本地一份记忆，
    /// 点了「允许」以后按钮没了、行上却继续写「待审批」，自相矛盾。
    var decision: PermissionDecision? = nil
    var onApprove: (() -> Void)? = nil
    var onDeny: (() -> Void)? = nil
    var onAlwaysAllow: (() -> Void)? = nil

    /// 用户手动拨过折叠开关 ⇒ 一切默认规则让位（`nil` = 没拨过，按相位走）。
    ///
    /// ⚠️ 记的是**"拨过的那一次"**，不是"展开/收起"本身 —— 默认态由 `expanded` 现算，
    /// 于是相位一变就自动跟上。写成 `@State expanded = true` 会有两个病：新卡片永远默认展开；
    /// 相位流转后不再自动收（改前就是这两个病）。
    @State private var userOverride: Bool? = nil
    @State private var copied = false

    // MARK: - 形态的全部规则（都在这几个计算属性里，不写 onChange 状态机）

    private var decided: Bool { decision != nil }
    private var denied: Bool { decision == .deny }

    /// 已决策的**兑现说法**。`nil` = 还没表态 —— 只有这时才写「待审批」。
    private var decisionText: String? {
        switch decision {
        case .allow:       return L("已允许")
        case .deny:        return L("已拒绝")
        case .alwaysAllow: return L("已允许（始终）")
        case nil:          return nil
        }
    }

    /// 「出事了」的两个来源 —— 失败，以及**还没被拍板**的审批请求。
    private var needsAttention: Bool {
        if case .error = tool.phase { return true }
        return tool.phase == .awaitingApproval && !decided
    }

    /// **类别色**（回答"这是什么"）：恒冷蓝。
    ///
    /// ⚠️ 有意**不随相态变** —— 一变，「蓝 = 工具行」这条一眼可辨的规则就废了；而且相态已经由
    /// 右侧 badge 说清楚了，颜色再说一遍是**同一信息说两次**。改前按相态取色（`.done` 一律
    /// `textSecondary` 灰）会把"跑完了"读成"这条不重要"。
    private var kindColor: Color { CodexTheme.info }

    /// **竖条 / chevron 的色**（回答"到了哪一步"）：只有"出事了"才破例转红。
    ///
    /// ⚠️ 破例**只给图形元素**：`toolError` 在暗色下只有 3.98:1 —— 过得了图形元素的 3:1，
    /// **过不了文字的 4.5:1**。所以红色**不许**上 `kind` 文字（那会跌 AA）。
    /// 由 `palette_probe.py` 与冒烟 T-COLOR 两份实现分别守着这条线。
    private var railColor: Color { needsAttention || denied ? CodexTheme.toolError : kindColor }

    /// 展开规则（2026-10-13 boss 定）：**只有两件事值得自动展开 —— 出错、以及"需要你拍板"**。
    ///
    /// `running` 有意**不**展开 —— boss 原话：「运行中的 tool 不需要自动展开，万一输出很大，
    /// 那不是爆炸了」⇒ 运行中只在右侧留「⟳ 运行中」，要看就自己点开。用户拨过就全让位。
    private var expanded: Bool {
        if let userOverride { return userOverride }
        if case .error = tool.phase { return true }   // 失败不许自己缩回
        if decided { return false }                   // 选过了 ⇒ 收起
        return tool.phase == .awaitingApproval        // 只剩"需要你拍板"展开
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 100% 不透明（暗色下 0.85 会把冷蓝从 6.21 压到 4.91，没必要）。
            // 与思考竖条的 `thinking.opacity(0.7)` **有意不同**：工具行承担"我干了什么"，
            // 比"我想了什么"更该看清。
            Rectangle()
                .fill(railColor)
                .frame(width: 2)
                .padding(.vertical, 3)

            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded { expandedBody }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // ⚠️ 这里**没有** `.background(bgCard)` / `clipShape` —— 行是行，不是卡。
        //    ⚠️ 底色的**源码事实**（内嵌面只能比正文面亮一档）由 `scripts/smoke/run.sh`
        //    直接扫本文件守 —— 数值守卫看不见"视图用了哪个 token"（值本身没变）。
    }

    // MARK: - Header row（整行可点 = 展开/收起）

    private var header: some View {
        Button {
            withAnimation(CodexTheme.animFast) { userOverride = !expanded }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(railColor)
                    .frame(width: 12)

                Text(tool.kind.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(kindColor)

                Text(tool.title)
                    .font(CodexTheme.fontMonoSm)
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineLimit(1)

                if let cmd = tool.command {
                    Text(cmd)
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !tool.imagePaths.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "photo")
                            .font(.system(size: 9))
                        Text(verbatim: "\(tool.imagePaths.count)")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(CodexTheme.textMuted)
                }

                Spacer(minLength: 8)

                phaseBadge
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 展开后的内容

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 输出头：分节标签 · 复制全部。**没有"展开全部"箭头了** —— 固定高滚动区接手，
            // 2 行截断 + 展开箭头那套和它讲的是同一件事，留着就是两个开关抢一个语义。
            if !tool.details.isEmpty {
                HStack(spacing: 6) {
                    Text("输出")
                        .font(CodexTheme.fontLabel)
                        .foregroundStyle(CodexTheme.textTertiary)
                    Spacer()
                    Button(action: { copyAllOutput() }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(copied ? CodexTheme.toolDone : CodexTheme.textTertiary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("复制全部输出")
                }
            }

            // ⚠️ 必须门一下再画盒子：没有输出内容的行（例如只有 diff 的审批卡）会画出
            //    **一个空盒子**，量高凭空 +36pt（实测 271 → 307）。这条是量高时抓到的。
            if !tool.details.isEmpty || !tool.imagePaths.isEmpty {
                ToolOutputBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(tool.details.enumerated()), id: \.offset) { _, d in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                // 分节头已是"输出"，行内同 key 不再重复打印
                                if d.key != "输出" {
                                    Text(LK(d.key))
                                        .font(CodexTheme.fontMonoXs)
                                        .foregroundStyle(CodexTheme.textTertiary)
                                        .frame(width: 36, alignment: .leading)
                                }
                                Text(d.value)
                                    .font(CodexTheme.fontMonoXs)
                                    .foregroundStyle(CodexTheme.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                        }

                        // 工具产出的图片（读图工具 / 生成图工具）：排在文本输出之后。
                        // 不另起小标题 —— 缩略图自明，多一行标签只会把行读成两段。
                        if !tool.imagePaths.isEmpty {
                            ToolOutputImages(paths: tool.imagePaths)
                                .padding(.top, tool.details.isEmpty ? 0 : 2)
                        }
                    }
                }
            }

            // 审批卡的改动预览（edit/write）。底色与输出区同族 —— 见 DiffPreviewView。
            if let diff = tool.diffText, !diff.isEmpty {
                DiffPreviewView(diffText: diff)
            }

            // 三键在**决策后立刻退场**（哪怕 agent 还没回事件）——
            // 否则点了「允许」按钮还在原地，用户会怀疑自己没点到。
            if tool.phase == .awaitingApproval && !decided {
                approvalRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// 审批三键**压成一行、就在行内**（P16 形态）—— 收起来的审批入口 = 没有入口。
    private var approvalRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                Text("此操作需要你的批准才能执行")
                    .font(CodexTheme.fontSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(CodexTheme.toolError)

            Spacer(minLength: 8)

            if let onAlwaysAllow {
                Button(action: onAlwaysAllow) {
                    Text("始终允许")
                        .font(.system(size: 12))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let onDeny {
                Button(action: onDeny) {
                    Text("拒绝")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CodexTheme.toolError)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(CodexTheme.toolError.opacity(0.55), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            if let onApprove {
                Button(action: onApprove) {
                    Text("允许")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(CodexTheme.toolDone)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private func copyAllOutput() {
        // 复制出去的内容**跟随语言** —— 详情键在界面上本来就是查表显示的 (LK(d.key)),
        // 若复制出来恒是中文, 英文界面下就成了另一种不一致。`L()` 收运行时字符串, 未命中回落原串。
        var lines = tool.details.map { "\(L($0.key)): \($0.value)" }
        // 图片按路径入列 —— 只有图片没有文本时 (典型: read 一张截图) 复制也**不会是个空操作**。
        // ⚠️ 带插值的串必须写 `String(format: L("…%@…"), x)` (禁令 ⑤: L() 禁插值)。
        lines.append(contentsOf: tool.imagePaths.map { String(format: L("图片: %@"), $0) })
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch tool.phase {
        case .running:
            // 运行中的圈与字**都用冷蓝**（类别色）—— 改前用琥珀 `toolRunning`, 那与思考行
            // 撞色; 「琥珀垄断给思考」是 P16 定的分工。
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .tint(CodexTheme.info)
                Text(tool.phase.label)
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.info)
            }
        case .done:
            HStack(spacing: 6) {
                if let ms = tool.durationMs {
                    // verbatim: Text 字符串插值走 LocalizedStringKey 会给 Int 加千位分隔符
                    // (6533 → "6,533ms"); ≥1s 换算成 x.xs 更易读
                    Text(verbatim: ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms")
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                Text(tool.phase.label)
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.toolDone)
            }
        case .awaitingApproval:
            // 本地已表态 ⇒ **不再写「待审批」**（agent 那边可能还没回，但用户已经拍过板了）
            if let text = decisionText {
                HStack(spacing: 5) {
                    Image(systemName: denied ? "xmark" : "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                    Text(verbatim: text)
                        .font(CodexTheme.fontMonoXs)
                }
                .foregroundStyle(denied ? CodexTheme.toolError : CodexTheme.toolDone)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(tool.phase.label)
                        .font(CodexTheme.fontMonoXs)
                }
                .foregroundStyle(CodexTheme.toolError)
            }
        case .error(let msg):
            Text(msg)
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.toolError)
                .lineLimit(1)
        case .queued:
            Text(tool.phase.label)
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textTertiary)
        }
    }
}

// MARK: - 展开后的固定高滚动区

/// 工具行展开后的输出区。
///
/// ⚠️ 它存在的**全部理由** = 让高度与输出长度**脱钩**：同一行收起 23pt / 输出 40 行 233pt /
/// 输出 400 行 **233pt**（实测逐值相同）。没有它，"点开看一眼"就会把消息列铺满 ——
/// P16 立项的起因正是 5 个工具占了 60% 高度。
///
/// ⚠️ `maxHeight` 是**上界不是定高**：短输出按自身高度收，只有超了才滚。
///
/// ⚠️ 底色必须是 `bgCard`（比正文面**亮**一档，与代码块/表格同族）。用 `bgBase` 就是在正文面上
/// **挖出近黑洞** —— 暗色实测 3.01× 亮度差，正是 P10.8b 说的"看着累"。亮色侧同理（纸上的灰块）。
private struct ToolOutputBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: Tune.toolOutputMaxHeight)
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Diff preview (edit/write 审批)

/// 审批卡内的改动预览: 扩展侧生成的行前缀 diff (- 旧 / + 新 / FILE 头 / ·· 分隔)。
/// 块对照式 (不做行对齐), 高度受限内滚动; 用户先看改动再决定允许/拒绝。
struct DiffPreviewView: View {
    let diffText: String

    private func color(for line: String) -> Color {
        if line.hasPrefix("- ") { return CodexTheme.toolError }
        if line.hasPrefix("+ ") { return CodexTheme.toolDone }
        if line.hasPrefix("FILE ") { return CodexTheme.textSecondary }
        // ⚠️ 兜底**不是** `textMuted`：落到 diff 里的无前缀行是**要读的代码行**，不是装饰符。
        //    `textMuted` 在亮色下只有 2.30:1（挪进 bgCard 前的旧底色上也只有 2.55:1 —— 早就破线）。
        return CodexTheme.textSecondary
    }

    private func bg(for line: String) -> Color {
        if line.hasPrefix("- ") { return CodexTheme.toolError.opacity(0.08) }
        if line.hasPrefix("+ ") { return CodexTheme.toolDone.opacity(0.08) }
        return Color.clear
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // ⚠️ `omittingEmptySubsequences: false` —— 默认的 `true` 会**吃掉空行**，
                //    而 diff 里的空行是改动上下文的骨架（改前的写法就漏在这里）。
                ForEach(Array(diffText.split(separator: "\n", omittingEmptySubsequences: false)
                                .enumerated()),
                        id: \.offset) { _, line in
                    let s = String(line)
                    // verbatim: diff 是**代码**, 永远不许过本地化（`Text(s)` 虽也是 verbatim 语义,
                    // 但显式写出来能挡住后来人"顺手改成 L()"）。
                    Text(verbatim: s)
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(color(for: s))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bg(for: s))
                        .padding(.horizontal, 10)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: Tune.toolDiffMaxHeight)
        // ⚠️ 与 `ToolOutputBox` 同族：聊天流里的内嵌面一律 `bgCard`（比正文面亮一档）。
        //    改前这里是 `bgBase` —— 暗色下的近黑洞，聊天流里唯一一处例外。
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
