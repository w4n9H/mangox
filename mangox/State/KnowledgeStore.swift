//
//  KnowledgeStore.swift
//  P9.1c: 知识库/记忆域自 ChatStore 抽离 (P3.7 全链路: 条目 CRUD/注入块组装/蒸馏/审核)。
//  拆分不动行为: ChatStore 保留同名 facade 转发 (冒烟/视图零改动);
//  服务持有 store 弱引用, 经 store 回调落库/重放/活跃项目判定; 池下发走 pushKnowledgeContext。
//

import Foundation
import Combine

@MainActor
final class KnowledgeStore: ObservableObject {

    // P3.7: 知识库/记忆 (统一模型, 记忆 = source=session 条目)
    @Published var knowledgeItems: [KnowledgeItem] = []
    @Published var showKnowledgePanel: Bool = false
    /// 注入块快照 (池实例 spawn 期消费; applyKnowledgeChange/启动时刷新)。
    private(set) var currentKnowledgeBlock: String?

    // Memory distillation (P3.7 记忆自动提炼; v1 人工触发, 自动门槛留 v1.2)
    @Published var distillRunning: Bool = false
    /// 提炼结果提示 (Composer 上方横幅, 8s 自清)。isError = 红/绿两种横幅。
    @Published var distillOutcome: (text: String, isError: Bool)?
    private var distillOutcomeTask: Task<Void, Never>?

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) { self.store = store }

    // MARK: - 投影 (Composer pill / 知识面板)

    /// 当前生效条数 (已审核 + 启用 + 全局/当前 project)——Composer pill 显示用。
    var activeKnowledgeCount: Int {
        let pid = store?.activeProject?.id
        return knowledgeItems.filter { item in
            guard item.enabled, item.status == .active else { return false }
            return item.scope == .global || item.projectId == pid
        }.count
    }

    /// 提炼候选 (待审核)。
    var pendingKnowledge: [KnowledgeItem] {
        knowledgeItems.filter { $0.status == .pending }
    }

    /// 组装注入块: 全局 + 当前 project 的启用条目, 带 token 预算 (单条截断/总量丢弃)。
    /// pending 候选永不注入 (审核闸门)。nil = 无可注入内容。
    func buildKnowledgeBlock() -> String? {
        let pid = store?.activeProject?.id
        let enabled = knowledgeItems.filter { item in
            guard item.enabled, item.status == .active else { return false }
            return item.scope == .global || item.projectId == pid
        }
        guard !enabled.isEmpty else { return nil }
        // 单条上限截断
        let clipped = enabled.map { item -> KnowledgeItem in
            var c = item
            if c.content.count > Tune.knowledgeItemCharLimit {
                c.content = String(c.content.prefix(Tune.knowledgeItemCharLimit))
                    + "\n…(超出单条上限已截断)"
            }
            return c
        }
        // 总量预算: 优先保留最新 (updatedAt 降序), 超限的条目直接不入块
        var kept: [KnowledgeItem] = []
        var total = 0
        for item in clipped.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let cost = item.title.count + item.content.count
            guard total + cost <= Tune.knowledgeTotalCharLimit else { continue }
            kept.append(item)
            total += cost
        }
        guard !kept.isEmpty else { return nil }
        var lines = ["以下是 MangoX 客户端注入的知识库/记忆, 回答时请参考:"]
        let globals = kept.filter { $0.scope == .global }
        let projectScoped = kept.filter { $0.scope == .project }
        if !globals.isEmpty {
            lines.append("\n## 全局")
            globals.forEach { lines.append("- \($0.title): \($0.content)") }
        }
        if !projectScoped.isEmpty {
            lines.append("\n## 项目")
            projectScoped.forEach { lines.append("- \($0.title): \($0.content)") }
        }
        return lines.joined(separator: "\n")
    }

    /// 启动期: 重建注入块快照 (ChatStore.init 调用)。
    func refreshSnapshot() {
        currentKnowledgeBlock = buildKnowledgeBlock()
    }

    // MARK: - CRUD (P3.7)

    func addKnowledge(title: String, content: String, scope: KnowledgeScope, projectId: UUID?) {
        let item = KnowledgeItem(id: UUID(), scope: scope,
                                 projectId: scope == .project ? projectId : nil,
                                 title: title, content: content, source: .manual)
        knowledgeItems.insert(item, at: 0)
        try? store?.persistence?.upsertKnowledge(item)
        applyKnowledgeChange()
    }

    func updateKnowledge(_ item: KnowledgeItem) {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == item.id }) else { return }
        knowledgeItems[idx] = item
        try? store?.persistence?.upsertKnowledge(item)
        applyKnowledgeChange()
    }

    func deleteKnowledge(id: UUID) {
        knowledgeItems.removeAll { $0.id == id }
        try? store?.persistence?.deleteKnowledge(id: id)
        applyKnowledgeChange()
    }

    func toggleKnowledge(id: UUID) {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == id }) else { return }
        knowledgeItems[idx].enabled.toggle()
        knowledgeItems[idx].updatedAt = .now
        try? store?.persistence?.upsertKnowledge(knowledgeItems[idx])
        applyKnowledgeChange()
    }

    /// 会话内"保存为记忆": 文本沉淀为全局知识条目, 带 origin_session_id 溯源。
    func saveAsMemory(_ text: String, sessionId: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = String(trimmed.split(separator: "\n").first?.prefix(24) ?? "记忆")
        let item = KnowledgeItem(id: UUID(), scope: .global, projectId: nil,
                                 title: String(title), content: trimmed,
                                 source: .session, originSessionId: sessionId)
        knowledgeItems.insert(item, at: 0)
        try? store?.persistence?.upsertKnowledge(item)
        applyKnowledgeChange()
    }

    // MARK: - Memory distillation (P3.7)

    func setDistillOutcome(_ text: String, isError: Bool) {
        distillOutcome = (text, isError)
        distillOutcomeTask?.cancel()
        distillOutcomeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { distillOutcome = nil }
        }
    }

    /// 提炼模板 (业务语义 = TODO 占位脚手架: 边界示例与反例措辞待首个真实提炼轮后人工打磨)。
    private static func buildDistillPrompt(material: String, existing: [KnowledgeItem]) -> String {
        let list = existing.isEmpty ? "无" :
            existing.map { "- [\( $0.scope == .global ? "全局" : "项目")] \($0.title)" }.joined(separator: "\n")
        return """
        【任务: 记忆提炼】
        下面给你一段人机对话记录与现有知识条目清单。请判断对话中是否出现了值得跨会话长期记住的信息, 只输出 JSON, 不要输出任何其他文字, 不要使用任何工具。

        值得记录的只有三类:
        1. 环境/技术栈事实 —— 机器、项目结构、服务地址、数据规模等稳定事实
        2. 用户偏好与约定 —— 沟通/代码/流程上用户明确表达的偏好与规矩
        3. 决策及理由 —— 对话中拍板的技术或业务决策 (记结论和为什么)

        不要记录: 一次性任务的过程细节、代码片段本身、未验证的推测、与现有条目重复的内容 (见下方清单)。
        TODO(人工打磨): 补充边界示例与反例, 待首轮真实提炼后定稿。

        【现有知识条目】
        \(list)

        【对话记录】
        \(material)

        【输出格式】
        {"items": [{"title": "简短标题", "content": "事实本体, 精炼成独立可读的一句话或几句话", "scope": "global", "reason": "为什么值得记"}]}
        scope 只有 "global" 或 "project" 两种。没有值得记录的内容时输出 {"items": []} —— 宁可空, 不要凑数。
        """
    }

    /// 手动触发: 提炼当前会话 → 候选落 pending (审核在知识面板)。
    /// 失败静默 (解析失败/超时直接放弃, 不打扰)。
    func distillMemoryFromCurrentSession() {
        guard let store else { return }
        guard !distillRunning, !store.isStreaming else { return }
        guard let sid = store.selectedConversationId else { return }
        // 材料: 最近 12 条 text 消息 (user+assistant), 总量截断
        var texts = store.replayMessages(for: sid).compactMap { msg -> String? in
            guard case .text(let s) = msg.content, !s.isEmpty else { return nil }
            return "\(msg.role == .user ? "用户" : "助手"): \(s)"
        }
        guard texts.count > 2 else { return }   // 太短不值得提炼
        texts = Array(texts.suffix(12))
        var material = texts.joined(separator: "\n\n")
        if material.count > Tune.distillMaterialCharLimit {
            material = "…(更早的已省略)\n" + String(material.suffix(Tune.distillMaterialCharLimit))
        }
        let existing = knowledgeItems.filter { $0.status == .active }
        let prompt = Self.buildDistillPrompt(material: material, existing: existing)
        // 归属 = 会话所在的项目分组 (selectedProjectId 只在点项目/建会话时设置,
        // 从侧栏直接点开会话不同步它——用会话反查才是 source of truth)
        let projectId = store.projects.first(where: { $0.items.contains(where: { $0.id == sid }) })?.id
        let model = store.currentProvider.isEmpty ? nil : "\(store.currentProvider)/\(store.currentModelId)"
        let thinking = store.thinkingLevel.rawValue
        distillRunning = true
        MemoryDistiller.shared.run(prompt: prompt, model: model, thinking: thinking) { [weak self] raw in
            guard let self else { return }
            self.distillRunning = false
            guard let raw else {
                self.setDistillOutcome("提炼失败: 超时或引擎无响应 (见控制台日志)", isError: true)
                return
            }
            print("[MemoryDistiller] 原始输出 \(raw.count) 字符: \(raw.prefix(400))")
            let candidates = MemoryDistiller.parseOutput(raw)
            guard !candidates.isEmpty else {
                // 区分"模型认为没什么可记"与"输出解析失败" (都有 items 字段 = 正常应答)
                if raw.contains("\"items\"") {
                    self.setDistillOutcome("提炼完成: 本轮没有值得沉淀的内容", isError: false)
                } else {
                    self.setDistillOutcome("提炼失败: 输出无法解析 (见控制台日志)", isError: true)
                }
                return
            }
            self.addPendingKnowledge(candidates, sessionId: sid, projectId: projectId)
            self.setDistillOutcome("提炼完成: \(candidates.count) 条候选待审核", isError: false)
        }
    }

    /// 候选落 pending: 插入列表 + 落库。注入块未变 (pending 不注入) → 不标 dirty。
    /// 净化: scope=project 但无项目归属 → 降级 global (绝不建"未知项目"条目)。
    private func addPendingKnowledge(_ candidates: [MemoryDistiller.Candidate],
                                     sessionId: UUID, projectId: UUID?) {
        for c in candidates {
            let scope: KnowledgeScope = c.scope == .project && projectId != nil ? .project : .global
            let item = KnowledgeItem(id: UUID(), scope: scope,
                                     projectId: scope == .project ? projectId : nil,
                                     title: c.title, content: c.content,
                                     source: .session, originSessionId: sessionId,
                                     enabled: true, status: .pending, note: c.reason)
            knowledgeItems.insert(item, at: 0)
            try? store?.persistence?.upsertKnowledge(item)
        }
    }

    /// 审核采纳: pending → active, 清 note, 注入块变更 → 标 dirty (重启引擎生效)。
    func adoptKnowledge(id: UUID) {
        guard let idx = knowledgeItems.firstIndex(where: { $0.id == id }),
              knowledgeItems[idx].status == .pending else { return }
        knowledgeItems[idx].status = .active
        knowledgeItems[idx].note = nil
        knowledgeItems[idx].updatedAt = .now
        try? store?.persistence?.upsertKnowledge(knowledgeItems[idx])
        applyKnowledgeChange()
    }

    /// 审核丢弃。
    func discardKnowledge(id: UUID) {
        deleteKnowledge(id: id)
    }

    // MARK: - 变更生效 (注入块快照 + 池下发 + dirty 标记)

    /// 知识变动后: 快照注入块 + 池内实例同步下发 + 标记引擎待重启。
    private func applyKnowledgeChange() {
        currentKnowledgeBlock = buildKnowledgeBlock()
        store?.pushKnowledgeContext(currentKnowledgeBlock)
        store?.knowledgeDirty = true
    }
}
