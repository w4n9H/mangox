//
//  TrajectoryView.swift
//  P5.0.3: 轨迹列表视图 v1 —— 摘要头 (Duration/Turns/Calls) + 三色事件行 + 展开。
//  事件行 = TrajectoryBuilder 纯派生自 store.messages (落库 replay + 实时同源);
//  实时语义: 流式 assistant 不成行 → 「生成中」旋转弧占位; 工具徽章随 phase 翻转。
//  不做逐字打字 (设计 §1.3: 那是「读」的体验, 归对话视图)。
//

import SwiftUI

struct TrajectoryView: View {
    @ObservedObject var store: ChatStore
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let turns = TrajectoryBuilder.turns(from: store.messages)
        VStack(alignment: .leading, spacing: 0) {
            headerRow(turns)
            Divider().overlay(CodexTheme.divider)
            if turns.isEmpty && !store.isStreaming {
                emptyState
            } else {
                eventList(turns)
            }
            ChatBottomBar(store: store)   // 轨迹模式仍可继续输入 (共享底栏)
        }
        .background(CodexTheme.bgChat)
        .onChange(of: store.selectedConversationId) { _, _ in
            expanded.removeAll()   // 换会话收起全部展开行
        }
    }

    // MARK: - 摘要头

    private func headerRow(_ turns: [TrajectoryTurn]) -> some View {
        let s = TrajectoryBuilder.summary(turns)
        return HStack(spacing: 24) {
            Text("TRACE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(CodexTheme.textMuted)
            statCell(value: s.turns == 0 ? "—" : TrajectoryBuilder.formatDuration(s.durationMs),
                     label: "Duration")
            statCell(value: "\(s.turns)", label: "Turns")
            statCell(value: "\(s.calls)", label: "Calls")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func statCell(value: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
            Text(label)
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
        }
    }

    // MARK: - 事件列表

    private func eventList(_ turns: [TrajectoryTurn]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(turns) { turn in
                        turnHeader(turn, isFirst: turn.index == 1)
                        ForEach(turn.events) { event in
                            eventRow(event)
                                .overlay(alignment: .bottom) {
                                    // 行间淡灰分隔线 (行底贴线; 末行也留一条保持节奏)
                                    Rectangle()
                                        .fill(CodexTheme.divider.opacity(0.7))
                                        .frame(height: 1)
                                }
                        }
                    }
                    if store.isStreaming {
                        liveRow.id("live")
                    }
                    Color.clear.frame(height: 24)   // 底部呼吸空间
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.messages.count) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
    }

    /// 回合分组头: Turn N · 起始时间 · 回合时长估计。
    private func turnHeader(_ turn: TrajectoryTurn, isFirst: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Turn \(turn.index)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CodexTheme.textSecondary)
            Text(turn.startedAt.formatted(date: .omitted, time: .standard))
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            if let d = turn.durationMs {
                Text(TrajectoryBuilder.formatDuration(d))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer()
        }
        .padding(.top, isFirst ? 2 : 16)
        .padding(.bottom, 6)
    }

    // MARK: - 事件行 (三色)

    @ViewBuilder
    private func eventRow(_ event: TrajectoryEvent) -> some View {
        switch event.kind {
        case .user:
            HStack(alignment: .top, spacing: 10) {
                kindChip("USER", CodexTheme.accent, prominent: true)
                Text(event.prompt)
                    .font(.system(size: 12))   // 正文降档: 事件线是主线, 正文退居次要
                    .foregroundStyle(CodexTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
        case .assistant:
            assistantRow(event)
        case .tool:
            toolRow(event)
        }
    }

    /// ASSISTANT 行: 折叠 = 首句 + 元数据 (tokens · model · 时长估计); 点击展开全文 + think + usage。
    private func assistantRow(_ event: TrajectoryEvent) -> some View {
        let isExpanded = expanded.contains(event.id)
        let meta = assistantMeta(event)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(CodexTheme.animFast) { toggle(event.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    kindChip("ASSISTANT", CodexTheme.info)
                    Text(TrajectoryBuilder.firstSentence(event.fullText))
                        .font(.system(size: 12))   // 正文降档 (同 USER: 一个字号一个色号)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(CodexTheme.fontMonoXs)
                            .foregroundStyle(CodexTheme.textMuted)
                            .fixedSize()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CodexTheme.textMuted)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                assistantDetail(event)
            }
        }
        .padding(.vertical, 7)
    }

    private func assistantDetail(_ event: TrajectoryEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let think = event.thinkText, !think.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(CodexTheme.thinking)
                        .frame(width: 2)
                    Text(think)
                        .font(.system(size: 12))
                        .foregroundStyle(CodexTheme.textTertiary)   // 思考比正文再淡一档
                        .textSelection(.enabled)
                }
            }
            Text(event.fullText)
                .font(.system(size: 12))   // 展开全文与折叠预览同档 (正文统一)
                .foregroundStyle(CodexTheme.textSecondary)
                .textSelection(.enabled)
            if let usage = event.usage {
                Text(usageDetail(usage))
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textMuted)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 30)   // 对齐 chip 后内容
    }

    /// TOOL 行: 工具名 + 参数摘要 + 时长 + 状态徽章 (实时翻转); 展开看 details/diff/错误。
    private func toolRow(_ event: TrajectoryEvent) -> some View {
        guard let tool = event.tool else { return AnyView(EmptyView()) }
        let isExpanded = expanded.contains(event.id)
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(CodexTheme.animFast) { toggle(event.id) }
            } label: {
                HStack(spacing: 10) {
                    kindChip(tool.kind.label, tool.kind.defaultColor)
                    Text(tool.command ?? tool.title)
                        .font(CodexTheme.fontMonoSm)
                        .foregroundStyle(CodexTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let ms = tool.durationMs {
                        Text(TrajectoryBuilder.formatDuration(ms))
                            .font(CodexTheme.fontMonoXs)
                            .foregroundStyle(CodexTheme.textMuted)
                            .fixedSize()
                    }
                    phaseBadge(tool.phase)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CodexTheme.textMuted)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                toolDetail(tool)
            }
        }
        .padding(.vertical, 7))
    }

    private func toolDetail(_ tool: ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if tool.command != nil && tool.command != tool.title {
                detailLine("cmd", tool.command ?? "")
            }
            ForEach(tool.details, id: \.key) { d in
                detailLine(d.key, d.value)
            }
            if let diff = tool.diffText, !diff.isEmpty {
                Text(diff)
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CodexTheme.bgCard)
                    .cornerRadius(CodexTheme.radiusSm)
            }
            if case .error(let msg) = tool.phase {
                Text(msg)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.toolError)
            }
        }
        .padding(.leading, 30)
    }

    private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize()
            Text(value)
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textSecondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - 碎片

    /// 类型徽章 (USER 用 prominent 放大字号与色框, 用户拍板)。
    private func kindChip(_ label: String, _ color: Color, prominent: Bool = false) -> some View {
        Text(label)
            .font(.system(size: prominent ? 10 : 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, prominent ? 7 : 5)
            .padding(.vertical, prominent ? 3 : 2)
            .background(color.opacity(0.12))
            .cornerRadius(prominent ? 5 : 4)
            .frame(minWidth: prominent ? 38 : 30)
    }

    private func phaseBadge(_ phase: ToolPhase) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(phase.color)
                .frame(width: 6, height: 6)
            Text(phase.label)
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textSecondary)
        }
        .fixedSize()
    }

    private func assistantMeta(_ event: TrajectoryEvent) -> String {
        var parts: [String] = []
        if let usage = event.usage {
            parts.append(TrajectoryBuilder.formatTokens(usage.totalTokens) + " tok")
        }
        if let model = TrajectoryBuilder.shortModelName(event.usage?.model) {
            parts.append(model)
        }
        if let ms = event.heuristicMs {
            parts.append(TrajectoryBuilder.formatDuration(ms))
        }
        return parts.joined(separator: " · ")
    }

    private func usageDetail(_ u: MessageUsage) -> String {
        var parts = ["in \(u.input)", "out \(u.output)"]
        if u.cacheRead > 0 { parts.append("cache \(u.cacheRead)") }
        if u.cacheWrite > 0 { parts.append("cwrite \(u.cacheWrite)") }
        if u.reasoning > 0 { parts.append("reason \(u.reasoning)") }
        parts.append("total \(u.totalTokens)")
        if let model = TrajectoryBuilder.shortModelName(u.model) { parts.append(model) }
        if let rid = u.responseId { parts.append(rid) }
        return parts.joined(separator: " · ")
    }

    /// 实时占位行: 会话在途且无新落定事件 → 旋转弧 + 「生成中」(同侧栏弧样式)。
    private var liveRow: some View {
        HStack(spacing: 10) {
            kindChip("ASSISTANT", CodexTheme.info)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let angle = Angle.degrees(t.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360)
                ZStack {
                    Circle()
                        .stroke(CodexTheme.textMuted.opacity(0.22), lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(CodexTheme.toolDone,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(angle)
                }
                .frame(width: 12, height: 12)
            }
            Text("AI 回复生成中…")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
            Spacer()
        }
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 22))
                .foregroundStyle(CodexTheme.textMuted)
            Text("暂无事件")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
