//
//  TrajectoryView.swift
//  P5.0.3 → P6.2: Trace v2 —— segment 三档 (Messages / Turns / Details) + 导出。
//  三视图同源 store.messages 纯派生 (TrajectoryBuilder, 冒烟可测);
//  Messages = v1 增强 (Turn 卡折叠 + 连续同类工具分组 + toolcall_start 提前出卡);
//  Turns = 回合卡片概览 (点击跳 Messages 并展开该回合); Details = LLM 调用粒度明细。
//

import SwiftUI

struct TrajectoryView: View {
    @ObservedObject var store: ChatStore
    @State private var expanded: Set<UUID> = []           // 行/组展开态 (assistant/tool/组)
    /// 回合折叠 override (用户点过为准); nil 覆盖 = 默认仅展开最近一回合 (P6.2.1)。
    @State private var turnOverrides: [UUID: Bool] = [:]
    @State private var segment: TraceSegment = .messages
    /// Turns 卡 → Messages 定位 (跨 segment 互跳)。
    @State private var jumpTarget: UUID?

    enum TraceSegment: String, CaseIterable, Identifiable {
        case messages, turns, details
        var id: String { rawValue }
        var label: String {
            switch self {
            case .messages: return "Messages"
            case .turns:    return "Turns"
            case .details:  return "Details"
            }
        }
    }

    var body: some View {
        let turns = TrajectoryBuilder.turns(from: store.messages)
        VStack(alignment: .leading, spacing: 0) {
            headerRow(turns)
            Divider().overlay(CodexTheme.divider)
            switch segment {
            case .messages: messagesSegment(turns)
            case .turns:    turnsSegment(turns)
            case .details:  detailsSegment
            }
            ChatBottomBar(store: store)   // 轨迹模式仍可继续输入 (共享底栏)
        }
        .background(CodexTheme.bgChat)
        .onChange(of: store.selectedConversationId) { _, _ in
            expanded.removeAll()   // 换会话收起全部展开行
            turnOverrides.removeAll()
            segment = .messages
        }
    }

    // MARK: - 摘要头 (stats + segment 切换 + 导出)

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
            // P6.2.2: segment 三档
            HStack(spacing: 2) {
                ForEach(TraceSegment.allCases) { seg in
                    Button {
                        withAnimation(CodexTheme.animFast) { segment = seg }
                    } label: {
                        Text(seg.label)
                            .font(.system(size: 10, weight: segment == seg ? .semibold : .regular))
                            .foregroundStyle(segment == seg ? CodexTheme.textPrimary : CodexTheme.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(segment == seg ? CodexTheme.bgCard : Color.clear)
                            .cornerRadius(CodexTheme.radiusSm)
                    }
                    .buttonStyle(.plain)
                }
            }
            // P6.2.3: 导出 HTML → Finder
            Button {
                store.exportTraceHTML()
            } label: {
                if store.isExportingHTML {
                    ProgressView().controlSize(.mini).scaleEffect(0.5)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isExportingHTML)
            .foregroundStyle(CodexTheme.textSecondary)
            .help("导出 HTML 并在 Finder 显示")
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

    // MARK: - Messages 段 (P6.2.1: Turn 折叠 + 工具分组)

    private func messagesSegment(_ turns: [TrajectoryTurn]) -> some View {
        let lastId = turns.last?.id
        if turns.isEmpty && !store.isStreaming {
            return AnyView(emptyState)
        }
        return AnyView(ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(turns) { turn in
                        let isExpanded = TrajectoryBuilder.isTurnExpanded(
                            turn, lastTurnId: lastId, overrides: turnOverrides)
                        turnHeader(turn, isFirst: turn.index == 1, isExpanded: isExpanded)
                            .id("turn-\(turn.id.uuidString)")
                            .contentShape(Rectangle())
                            .onTapGesture { toggleTurn(turn, lastId: lastId) }
                        if isExpanded {
                            ForEach(TrajectoryBuilder.rows(for: turn)) { row in
                                rowView(row)
                                    .overlay(alignment: .bottom) {
                                        Rectangle()
                                            .fill(CodexTheme.divider.opacity(0.7))
                                            .frame(height: 1)
                                    }
                            }
                        } else {
                            collapsedTurnRow(turn)
                        }
                    }
                    if store.isStreaming {
                        liveRow.id("live")
                    }
                    Color.clear.frame(height: 24).id("trace-bottom")   // 底部呼吸空间
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 坑: defaultScrollAnchor(.bottom) 会在内容尺寸变化时重锚底——展开任何行
            // (如 bash × N 分组) 视图都跳到列表底, 体感"点了 A 打开了 B"。改 onAppear 定位。
            .onAppear { proxy.scrollTo("trace-bottom", anchor: .bottom) }
            .onChange(of: store.messages.count) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
            .onChange(of: jumpTarget) { _, target in
                // P6.2.2: Turns 卡互跳定位 (回合已确保展开)
                guard let target else { return }
                proxy.scrollTo("turn-\(target.uuidString)", anchor: .top)
                jumpTarget = nil
            }
        })
    }

    /// 回合分组头: Turn N · 起始时间 · 回合时长估计 · 折叠箭头 (P6.2.1 可点)。
    private func turnHeader(_ turn: TrajectoryTurn, isFirst: Bool, isExpanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(CodexTheme.textMuted)
                .rotationEffect(isExpanded ? .degrees(90) : .zero)
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
        // P6.3.1: 轮级侧问入口 — fork 截至该轮的快照 (截断副本 → --fork)
        .contextMenu {
            Button("由此侧问 (含 Turn \(turn.index) 及之前)") {
                if let sid = store.selectedConversationId {
                    store.startSideChat(from: sid, upTo: turn.index)
                }
            }
            .disabled(!store.canStartSideChat)
        }
    }

    /// 折叠回合摘要行: 事件数 + 输出首句 (P6.2.1)。
    private func collapsedTurnRow(_ turn: TrajectoryTurn) -> some View {
        HStack(spacing: 8) {
            Text("\(turn.events.count) events")
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize()
            if let out = TrajectoryBuilder.turnOutput(turn) {
                Text(out)
                    .font(.system(size: 12))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { toggleTurn(turn, lastId: nil) }   // 折叠行必有 override (末回合默认展开), nil 安全
    }

    private func toggleTurn(_ turn: TrajectoryTurn, lastId: UUID?) {
        withAnimation(CodexTheme.animFast) {
            turnOverrides[turn.id] = !TrajectoryBuilder.isTurnExpanded(
                turn, lastTurnId: lastId, overrides: turnOverrides)
        }
    }

    // MARK: - 展示行 (单事件 / 工具组)

    @ViewBuilder
    private func rowView(_ row: TrajectoryRow) -> some View {
        switch row {
        case .single(let event):
            eventRow(event)
        case .group(let group):
            toolGroupRow(group)
        }
    }

    /// P6.2.1: 连续同类工具分组行「bash × 5」; 展开还原逐条卡片。
    private func toolGroupRow(_ group: TrajectoryToolGroup) -> some View {
        let isExpanded = expanded.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(CodexTheme.animFast) { toggle(group.id) }
            } label: {
                HStack(spacing: 10) {
                    kindChip(group.kind.label, group.kind.defaultColor)
                    Text("\(group.kind.label) × \(group.count)")
                        .font(CodexTheme.fontMonoSm)
                        .foregroundStyle(CodexTheme.textPrimary)
                    if let ms = group.totalDurationMs {
                        Text(TrajectoryBuilder.formatDuration(ms))
                            .font(CodexTheme.fontMonoXs)
                            .foregroundStyle(CodexTheme.textMuted)
                            .fixedSize()
                    }
                    if group.hasError {
                        Text("error")
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.toolError)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CodexTheme.textMuted)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 7)
            if isExpanded {
                ForEach(group.events) { event in
                    eventRow(event)
                }
            }
        }
    }

    // MARK: - Turns 段 (P6.2.2: 回合卡片概览, 倒序)

    private func turnsSegment(_ turns: [TrajectoryTurn]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(turns.reversed()) { turn in
                    turnCard(turn)
                }
                if turns.isEmpty {
                    Text("暂无回合")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                        .padding(.top, 40)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
        }
    }

    private func turnCard(_ turn: TrajectoryTurn) -> some View {
        Button {
            // 互跳: 展开 + 切 Messages + 定位 (Details 不跳, 设计 §3.3)
            withAnimation(CodexTheme.animFast) {
                turnOverrides[turn.id] = true
                jumpTarget = turn.id
                segment = .messages
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Turn \(turn.index)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CodexTheme.textSecondary)
                    Text(turn.startedAt.formatted(date: .omitted, time: .standard))
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                    Spacer()
                    if let d = turn.durationMs {
                        Text(TrajectoryBuilder.formatDuration(d))
                            .font(CodexTheme.fontMonoXs)
                            .foregroundStyle(CodexTheme.textMuted)
                    }
                }
                Text(turn.prompt.isEmpty ? "(无输入)" : TrajectoryBuilder.firstSentence(turn.prompt))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineLimit(1)
                if let out = TrajectoryBuilder.turnOutput(turn) {
                    Text(out)
                        .font(.system(size: 12))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    Label("\(turn.toolCalls)", systemImage: "wrench")
                    if let tokens = TrajectoryBuilder.turnTokens(turn) {
                        Label(TrajectoryBuilder.formatTokens(tokens), systemImage: "circle.grid.2x1")
                    }
                }
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodexTheme.bgCard)
            .cornerRadius(CodexTheme.radius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Details 段 (P6.2.2: LLM 调用粒度)

    private var detailsSegment: some View {
        let d = TrajectoryBuilder.details(from: store.messages)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sessionTotalsRow
                    .padding(.bottom, 12)
                if d.unreported > 0 {
                    Text("未上报 \(d.unreported) 条 (旧会话无 responseId)")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                        .padding(.bottom, 8)
                }
                ForEach(d.rows) { row in
                    detailRow(row)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(CodexTheme.divider.opacity(0.7))
                                .frame(height: 1)
                        }
                }
                if d.rows.isEmpty && d.unreported == 0 {
                    Text("暂无调用明细")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 顶行合计 = 会话级 SessionStats (P6.1.1 直读, 不自算; 设计 §3.4)。
    private var sessionTotalsRow: some View {
        HStack(spacing: 16) {
            if let stats = store.sessionStats {
                if let p = stats.contextPercent {
                    statCell(value: String(format: "%.1f%%", p), label: "Context")
                }
                statCell(value: TrajectoryBuilder.formatTokens(stats.inputTokens), label: "In")
                statCell(value: TrajectoryBuilder.formatTokens(stats.outputTokens), label: "Out")
                if let cache = stats.cachePercent {
                    statCell(value: String(format: "%.0f%%", cache), label: "Cache")
                }
                // 费用不显示 (2026-09-14 拍板: Details 只看 token); costUSD 仍在数据链里
            } else {
                Text("会话统计尚未上报 (发一轮后可得)")
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer()
        }
        .padding(10)
        .background(CodexTheme.bgCard)
        .cornerRadius(CodexTheme.radiusSm)
    }

    /// Details 行: 折叠 = 时间 · model · total; 展开 = token 六路 + responseId + 时长 (费用不显示)。
    private func detailRow(_ row: TrajectoryDetail) -> some View {
        let isExpanded = expanded.contains(row.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(CodexTheme.animFast) { toggle(row.id) }
            } label: {
                HStack(spacing: 10) {
                    kindChip("LLM", CodexTheme.info)
                    Text(row.timestamp.formatted(date: .omitted, time: .standard))
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textSecondary)
                    if let model = TrajectoryBuilder.shortModelName(row.usage.model) {
                        Text(model)
                            .font(CodexTheme.fontMonoXs)
                            .foregroundStyle(CodexTheme.textSecondary)
                    }
                    Spacer()
                    Text(TrajectoryBuilder.formatTokens(row.usage.totalTokens) + " tok")
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textSecondary)
                        .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CodexTheme.textMuted)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(usageDetail(row.usage)
                     + (row.heuristicMs.map { " · " + TrajectoryBuilder.formatDuration($0) } ?? ""))
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textMuted)
                    .textSelection(.enabled)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 7)
    }

    // MARK: - 事件行 (三色, v1 保留)

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
