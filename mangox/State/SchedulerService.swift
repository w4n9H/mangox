//
//  SchedulerService.swift
//  P9.1b: 定时任务域自 ChatStore 抽离 (P3.6 调度 / P3.9 fire / P3.10 等待型 / P4.0.2 会话化)。
//  拆分不动行为: ChatStore 保留同名 facade 转发 (冒烟/视图零改动);
//  服务持有 store 弱引用, 仅经 store 的会话/落库接口回调。
//

import Foundation
import Combine

@MainActor
final class SchedulerService: ObservableObject {

    /// 等待型任务完成标记 (HTML 注释: Markdown 渲染不可见, 客户端可解析)
    static let doneMarker = "<!--task: done-->"

    // P3.6: 本地定时任务 (仅 App 运行期生效, launchd 后置)
    @Published var scheduledTasks: [ScheduledTask] = []
    @Published var showScheduledPanel: Bool = false
    private var schedulerTimer: Timer?
    private var lastSchedulerMinute: Int = 0
    // P3.10: 等待型任务 fire 的回合追踪 (P4.0.2 会话化: 日志会话 sid -> 任务 id)
    private var fireTurnTask: [UUID: UUID] = [:]   // 在途 fire: 日志会话 -> 任务 id
    private var fireDoneHit: Set<UUID> = []        // 本轮日志会话已命中 done 标记

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) { self.store = store }

    // MARK: - CRUD (P3.6)

    func addScheduled(name: String, prompt: String, cron: String,
                      projectId: UUID?, continuous: Bool = false) {
        let t = ScheduledTask(id: UUID(), name: name, prompt: prompt, cron: cron,
                              projectId: projectId, continuous: continuous)
        scheduledTasks.append(t)
        try? store?.persistence?.upsertScheduled(t)
    }

    func updateScheduled(_ t: ScheduledTask) {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == t.id }) else { return }
        scheduledTasks[idx] = t
        try? store?.persistence?.upsertScheduled(t)
    }

    /// 删除任务; deleteSessions = 连带删除日志会话 (开放问题 12: 默认保留, 用户可选删)。
    func deleteScheduled(id: UUID, deleteSessions: Bool = false) {
        let sessionIds = scheduledTasks.first { $0.id == id }?.logSessionId.map { [$0] } ?? []
        scheduledTasks.removeAll { $0.id == id }
        try? store?.persistence?.deleteScheduled(id: id)
        if deleteSessions {
            for sid in sessionIds { store?.deleteConversation(sid) }
        }
    }

    func toggleScheduled(id: UUID) {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == id }) else { return }
        scheduledTasks[idx].enabled.toggle()
        try? store?.persistence?.upsertScheduled(scheduledTasks[idx])
    }

    // MARK: - 调度 + fire (P3.9)

    /// 调度器: 每秒 tick, 分钟变化时才检查 (对齐 cron 的最小粒度; 睡眠唤醒后靠分钟差兜底)。
    func startScheduler() {
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulerTick() }
        }
    }

    private func schedulerTick() {
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard minute != lastSchedulerMinute else { return }
        lastSchedulerMinute = minute
        for task in scheduledTasks where task.enabled {
            guard let cron = task.cronExpr, cron.matches(now) else { continue }
            runScheduledFire(task, at: now)
        }
    }

    /// 到点投递 (P3.9 单日志会话): 任务的全部运行追加进同一个日志会话 (首次 fire 建立)。
    /// P4.0.2: 完全后台化 —— 不劫持选中会话/UI, 直接往日志会话投递回合;
    /// 该任务日志会话已有回合在途则跳过 (cron 到期不重排)。
    /// 持续模式 (continuous): 注入交接文件 (工作日志, agent 写用户可改) + 近期运行摘录,
    /// 并指令 agent 把关键进展写回交接文件——连续性靠文件携带, 磁盘为准零缓存。
    func runScheduledFire(_ task: ScheduledTask, at now: Date = Date()) {
        guard let store else { return }
        if let pid = task.projectId {
            guard store.projects.contains(where: { $0.id == pid }) else {
                recordFireSkip(task, at: now, reason: "项目已删除")
                return
            }
        }
        // 定位/建立日志会话 (有项目归 project, 无项目落平铺 Chats)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        var logId = task.logSessionId
        let logExists = logId.map { id in store.allConversations.contains(where: { $0.id == id }) } ?? false
        if !logExists {
            let item = ConversationItem(title: task.name)
            if let pid = task.projectId {
                if let g = store.projects.firstIndex(where: { $0.id == pid }) {
                    store.projects[g].items.insert(item, at: 0)
                }
                try? store.persistence?.insertChatSession(item, projectId: pid)
            } else {
                store.chats.insert(item, at: 0)
                try? store.persistence?.insertChatSession(item)
            }
            logId = item.id
        }
        guard let logId else { return }
        guard !store.runningTurns.contains(logId) else {
            recordFireSkip(task, at: now, reason: "该任务回合在途")
            return
        }
        // P4.0.4: 并发已满 → 落痕跳过 (与"冲突跳过"同语义, cron 到期不重排)
        if store.runningTurns.count >= store.maxConcurrentTurns {
            recordFireSkip(task, at: now, reason: "并发已满 (\(store.maxConcurrentTurns))")
            return
        }
        // 时间线锚点 + prompt 落库 (用户正看着日志会话则同步上屏)
        let viewing = store.selectedConversationId == logId
        let sep = ChatMessage(role: .user, content: .text("── \(fmt.string(from: now)) 运行 ──"))
        store.persistMessage(sep, sid: logId)
        if viewing { store.messages.append(sep) }
        let prompt = buildScheduledPrompt(task)
        let promptMsg = ChatMessage(role: .user, content: .text(prompt))
        store.persistMessage(promptMsg, sid: logId)
        if viewing { store.messages.append(promptMsg) }
        // fire 是独立轮次: ephemeral (--no-session), 连续性靠交接文件 (P3.9 拍板);
        // cwd 用任务项目路径 (无项目回落 home)。
        // P9-#17: 恒无人值守 (task.unattended 仅作历史记录) —— 后台日志会话的审批卡
        // 停在 liveTurns 镜像里无 UI 入口, 弹卡 = 任务卡死到 pi 32s 超时 deny
        let cwd = task.projectId.flatMap { pid in store.projects.first(where: { $0.id == pid })?.path }
        // P10.4: 任务级执行配置 — 只动日志会话 transport (modeOverride/modelOverride 实例级),
        // 全局期望零污染 (主会话档位/模型不受后台任务影响)
        let cfg = task.config
        store.beginTurn(sid: logId, prompt: prompt, ephemeral: true,
                        cwd: cwd, unattended: true,
                        modeOverride: cfg.flatMap { AgentMode(rawValue: $0.agentMode) },
                        modelOverride: cfg.map {
                            (provider: $0.provider, modelId: $0.modelId, thinking: $0.thinkingLevel)
                        })
        // P10.3 联动: 日志会话行带上任务配置 (点开会话即恢复其执行配置)
        if let cfg { store.persistence?.saveSessionConfig(id: logId, config: cfg) }
        if let c = task.condition, !c.isEmpty {
            fireTurnTask[logId] = task.id   // 等待型: 本回合结束扫 done 标记
        }
        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[idx].lastRunAt = now
            scheduledTasks[idx].logSessionId = logId
            scheduledTasks[idx].runCount += 1   // P3.10: 执行次数
            try? store.persistence?.upsertScheduled(scheduledTasks[idx])
        }
    }

    /// fire 被跳过时往日志会话追加一条时间线记录 (只落库, 不动 UI 状态——
    /// 跳过发生在别的回合进行中, 不能打断当前会话)。
    /// 日志会话尚未建立则放弃: 纯跳过不值得为它建会话, 任务真正跑起来时自然会建。
    private func recordFireSkip(_ task: ScheduledTask, at now: Date, reason: String) {
        guard let logId = task.logSessionId,
              store?.allConversations.contains(where: { $0.id == logId }) == true else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let note = ChatMessage(role: .user,
                               content: .text("── \(fmt.string(from: now)) 因冲突跳过 (\(reason)) ──"))
        try? store?.persistence?.appendMessageEvent(sessionId: logId, note)
    }

    // MARK: - 交接文件 (P3.9)

    /// 交接文件路径: 项目任务 → <项目>/.mangox/tasks/<taskId>.md (进文件树/可 @ 引用);
    /// 无项目任务 → ~/.mangox/task-memory/<taskId>.md。
    func handoffPath(for task: ScheduledTask) -> String {
        let dir: String
        if let pid = task.projectId,
           let p = store?.projects.first(where: { $0.id == pid })?.path {
            dir = p + "/.mangox/tasks"
        } else {
            dir = NSHomeDirectory() + "/.mangox/task-memory"
        }
        return dir + "/\(task.id.uuidString).md"
    }

    /// 读交接文件 (磁盘为准, 零缓存)。返回 nil = 文件不存在。
    func readHandoff(for task: ScheduledTask) -> (content: String, updatedAt: Date?)? {
        let path = handoffPath(for: task)
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return (content, attr[.modificationDate] as? Date)
    }

    /// 写交接文件 (编辑器保存 / 兜底重建共用)。
    @discardableResult
    func saveHandoff(for task: ScheduledTask, content: String) -> Bool {
        let path = handoffPath(for: task)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try? content.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - Prompt 组装 (P3.10)

    /// P3.10 等待型 prompt: 两分支协议 (未成立→一句观察轻检查; 成立→查防重复记录→执行动作→done 标记)。
    /// 轻检查轮不注入近期摘录 (token 经济); 交接文件保持极短且必注入 (含"已触发"防重复记录)。
    private func buildWaitingPrompt(_ task: ScheduledTask, condition: String) -> String {
        var sections: [String] = []
        sections.append("""
        【等待任务 · 本轮检查】
        触发条件: \(condition)
        要求: 用工具实际核实当前状态, 不要凭此前记忆推断; 不确定是否成立时按"未成立"处理。
        - 若条件未成立: 只用一句话报告观察结果 (如"截至当前尚未…"), 不要执行任何其他动作。
        - 若条件成立: 先读下方交接文件确认此前未触发过, 然后执行【触发后动作】, 完成后在回复最后单独一行输出: \(Self.doneMarker)
        """)
        var handoff = readHandoff(for: task)?.content
        if (handoff ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let rebuilt = rebuildHandoff(from: task.logSessionId) {
                saveHandoff(for: task, content: rebuilt)
                handoff = rebuilt
            }
        }
        if let h = handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            sections.append("【交接文件】\n\(h)")
        }
        sections.append("【触发后动作】\n\(task.prompt)")
        return sections.joined(separator: "\n\n")
    }

    /// 持续模式 prompt 组装 (P3.9): 交接文件全文 (长期记忆) + 近期运行摘录 (短期上下文)
    /// + 本次指令 + 写回指令。文件丢失时从日志会话 (run-log) 静默重建。
    /// 等待型 (condition 非空) 走等待协议; 普通 prompt 原样返回。
    private func buildScheduledPrompt(_ task: ScheduledTask) -> String {
        if let c = task.condition, !c.isEmpty {
            return buildWaitingPrompt(task, condition: c)
        }
        guard task.continuous else { return task.prompt }
        var sections: [String] = []
        // 长期记忆: 交接文件; 丢失且有日志 → 从 run-log 静默重建
        var handoff = readHandoff(for: task)?.content
        if (handoff ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let rebuilt = rebuildHandoff(from: task.logSessionId) {
                saveHandoff(for: task, content: rebuilt)
                handoff = rebuilt
            }
        }
        if let h = handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            sections.append("【持续任务 · 工作日志】\n\(h)")
        }
        // 短期上下文: 最近一次运行的产出原文 (取最后一条 assistant text, 截取上限)
        if let logId = task.logSessionId {
            let tail = store?.replayMessages(for: logId).compactMap { msg -> String? in
                guard case .text(let s) = msg.content, !s.isEmpty,
                      msg.role == .assistant else { return nil }
                return s
            }.last
            if var t = tail {
                if t.count > Tune.scheduleHistoryCharLimit {
                    t = "…(更早的已省略)\n" + t.suffix(Tune.scheduleHistoryCharLimit)
                }
                sections.append("【近期运行摘录】\n\(t)")
            }
        }
        sections.append("【本次指令】\n\(task.prompt)")
        return sections.joined(separator: "\n\n") +
            "\n\n请在了解此前执行情况的基础上继续本次任务, 并在结束后把关键进展、当前状态与待办更新写入交接文件: \(handoffPath(for: task))"
    }

    /// run-log 兜底: 从日志会话的 text 消息重建交接文件内容 (过滤分隔标记, 截取上限)。
    /// 指令侧只取【本次指令】段 (历史注入模板不入档, 防层级滚雪球)。
    private func rebuildHandoff(from logId: UUID?) -> String? {
        guard let logId, let store else { return nil }
        let lines = store.replayMessages(for: logId).compactMap { msg -> String? in
            guard case .text(let s) = msg.content, !s.isEmpty,
                  !s.hasPrefix("──") else { return nil }   // 过滤运行分隔
            if msg.role == .user {
                if let r = s.range(of: "【本次指令】\n") {
                    return "[指令] " + s[r.upperBound...]
                }
                return nil   // 注入模板全文不入档
            }
            return "[产出] \(s)"
        }
        guard !lines.isEmpty else { return nil }
        var record = lines.joined(separator: "\n")
        if record.count > Tune.scheduleHistoryCharLimit * 2 {
            record = "…(更早的已省略)\n" + record.suffix(Tune.scheduleHistoryCharLimit * 2)
        }
        return record
    }

    // MARK: - Done 标记扫描 (P3.10, 事件归并在 ChatStore, 状态在这里)

    /// 回复命中 done 标记且该会话有在途 fire → 点亮 fireDoneHit (ChatStore 剥离时回调)。
    func noteDoneMarkerHit(sid: UUID) {
        if fireTurnTask[sid] != nil { fireDoneHit.insert(sid) }
    }

    /// 会话逐出: 清在途 fire 追踪 (ChatStore.evictTransport 回调)。
    func clearFireTracking(sid: UUID) {
        fireTurnTask[sid] = nil
        fireDoneHit.remove(sid)
    }

    /// P3.10/P4.0.2: 等待型 fire 收尾——done 命中则自动停用任务。
    /// 审批策略无需恢复: 池化后策略按回合下发 (unattended fire 只影响自己的实例配置)。
    func finishWaitingFireIfNeeded(sid: UUID) {
        guard let tid = fireTurnTask.removeValue(forKey: sid) else { return }
        let hit = fireDoneHit.contains(sid)
        fireDoneHit.remove(sid)
        guard hit,
              let idx = scheduledTasks.firstIndex(where: { $0.id == tid }) else { return }
        scheduledTasks[idx].enabled = false
        scheduledTasks[idx].completedAt = Date()
        try? store?.persistence?.upsertScheduled(scheduledTasks[idx])
    }

    // MARK: - 侧栏徽标 (P3.10)

    /// 侧栏任务日志会话标志 (定时任务 clock / 哨兵任务雷达)
    func scheduledBadge(for sessionId: UUID) -> String? {
        for t in scheduledTasks where t.logSessionId == sessionId {
            return (t.condition?.isEmpty == false)
                ? "dot.radiowaves.left.and.right"
                : "clock.badge"
        }
        return nil
    }
}
