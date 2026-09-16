//
//  PersistenceStore.swift
//  P3.1: SQLite 持久化 (~/.mangox/mangox.db, WAL)。
//  events 表 append-only: "message" 追加整条 ChatMessage 投影,
//  "tool_update" 追加相位变化; 加载 = 按 seq 重放。推理上下文在 agent 侧,
//  这里只存呈现投影 + agentSessionId 指针 (见 docs/P3-functional-design.md §5.3)。
//

import Foundation

@MainActor
final class PersistenceStore {
    private let db: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// 库文件路径 (P8-T28 备份拷贝源; 默认 ~/.mangox/mangox.db)
    let path: String
    /// P9-#10: 事件重放缓存 (sid → 消息列表)。任何写路径失效; 值类型拷贝, 调用方改不动缓存。
    /// 侧栏每次点击会话都全量重放 events (逐行 JSON decode), 事件多时可感卡顿。
    private var replayCache: [UUID: [ChatMessage]] = [:]
    /// P9-#10: seq 游标 (sid → 下一个 seq)。删除路径清空回落 SELECT MAX(seq)。
    private var seqCursor: [UUID: Int64] = [:]

    init(path: String = NSHomeDirectory() + "/.mangox/mangox.db") throws {
        self.path = path
        db = try Database(path: path)
    }

    // MARK: - Schema

    func migrate() throws {
        try db.run("""
        CREATE TABLE IF NOT EXISTS projects (
            id       TEXT PRIMARY KEY,
            title    TEXT NOT NULL,
            position INTEGER NOT NULL
        )
        """)
        try db.run("""
        CREATE TABLE IF NOT EXISTS sessions (
            id         TEXT PRIMARY KEY,
            project_id TEXT,
            title      TEXT NOT NULL,
            position   INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
        try db.run("""
        CREATE TABLE IF NOT EXISTS events (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            seq        INTEGER NOT NULL,
            type       TEXT NOT NULL,
            payload    TEXT NOT NULL,
            ts         REAL NOT NULL
        )
        """)
        try db.run("""
        CREATE TABLE IF NOT EXISTS scheduled_tasks (
            id              TEXT PRIMARY KEY,
            name            TEXT NOT NULL,
            prompt          TEXT NOT NULL,
            cron            TEXT NOT NULL,
            project_id      TEXT,
            enabled         INTEGER NOT NULL DEFAULT 1,
            last_run_at     REAL,
            last_session_id TEXT
        )
        """)
        try db.run("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.run("""
        CREATE TABLE IF NOT EXISTS knowledge_items (
            id                TEXT PRIMARY KEY,
            scope             TEXT NOT NULL,             -- 'global' | 'project'
            project_id        TEXT,                      -- scope=project 时必填
            title             TEXT NOT NULL,
            content           TEXT NOT NULL,
            source            TEXT NOT NULL,             -- 'manual' | 'session'
            origin_session_id TEXT,                      -- source=session 时的溯源指针
            enabled           INTEGER NOT NULL DEFAULT 1,
            status            TEXT NOT NULL DEFAULT 'active',  -- 'pending' | 'active'
            created_at        REAL NOT NULL,
            updated_at        REAL NOT NULL
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, seq)")
        // P5.1: 自定义模型 (菜单自主 — 与 pi 目录条目的展示名解耦)
        try db.run("""
        CREATE TABLE IF NOT EXISTS custom_models (
            provider   TEXT NOT NULL,
            model_id   TEXT NOT NULL,
            label      TEXT,
            created_at REAL NOT NULL,
            PRIMARY KEY (provider, model_id)
        )
        """)
        // P7-M2: 模型自管真源 (settings 页管理, 物化给 pi; 见 docs/P7-functional-design.md §1.1)
        try db.run("""
        CREATE TABLE IF NOT EXISTS models (
            provider           TEXT NOT NULL,
            model_id           TEXT NOT NULL,
            display_name       TEXT,
            api_type           TEXT NOT NULL,
            reasoning          INTEGER NOT NULL DEFAULT 0,
            base_url           TEXT,
            key_ref            TEXT,
            context_window     INTEGER,
            max_tokens         INTEGER,
            input_modalities   TEXT,
            cost_json          TEXT,
            thinking_level_map TEXT,
            compat             TEXT,
            sampling_params    TEXT,
            enabled            INTEGER NOT NULL DEFAULT 1,
            source             TEXT NOT NULL DEFAULT 'custom',
            created_at         REAL NOT NULL,
            PRIMARY KEY (provider, model_id)
        )
        """)
        // 旧库补列: 先查 PRAGMA table_info, 列已存在就不发 ALTER
        // (无条件 ALTER 会被 try? 吞掉异常, 但 SQLite 自己仍往 stderr 吐 duplicate column 日志)
        addColumnIfMissing("projects", "path", "TEXT")
        // P7-M3: models 表补 reasoning 显式列 (M2 首版靠 map 有无推导, MiniMax 系 map=null 误判)
        addColumnIfMissing("models", "reasoning", "INTEGER NOT NULL DEFAULT 0")
        // 记忆提炼: 候选条目待审核状态 (pending 不注入)
        addColumnIfMissing("knowledge_items", "status", "TEXT NOT NULL DEFAULT 'active'")
        addColumnIfMissing("knowledge_items", "note", "TEXT")
        // P3.6: 定时任务持续模式
        addColumnIfMissing("scheduled_tasks", "continuous", "INTEGER NOT NULL DEFAULT 0")
        // P3.9: 单日志会话 (补列 + last_session_id 数据搬迁)
        addColumnIfMissing("scheduled_tasks", "log_session_id", "TEXT")
        try? db.run("UPDATE scheduled_tasks SET log_session_id = last_session_id WHERE log_session_id IS NULL AND last_session_id IS NOT NULL")
        // P3.10: 等待型任务 (condition/unattended/completed_at 等)
        addColumnIfMissing("scheduled_tasks", "condition", "TEXT")
        addColumnIfMissing("scheduled_tasks", "unattended", "INTEGER NOT NULL DEFAULT 1")
        addColumnIfMissing("scheduled_tasks", "completed_at", "REAL")
        addColumnIfMissing("scheduled_tasks", "run_count", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("scheduled_tasks", "created_at", "REAL")
        // P6.3.1: 侧问会话 (side_of = 源会话; fork 溯源/轮数/时刻; session_file = 显式绑定路径,
        // fork 产物文件名带时间戳前缀, 无法从 UUID 派生, 只能 get_state.sessionFile 回读)
        addColumnIfMissing("sessions", "side_of", "TEXT")
        addColumnIfMissing("sessions", "fork_source_file", "TEXT")
        addColumnIfMissing("sessions", "fork_turns", "INTEGER")
        addColumnIfMissing("sessions", "fork_at", "REAL")
        addColumnIfMissing("sessions", "session_file", "TEXT")
        // P3.10: created_at 一次性重算——上一版把存量统一回填成迁移时刻导致排序乱;
        // 真实创建时间不可考, 用日志会话时间 (≈首次 fire) 近似, 无日志的用 rowid 兜底沉底。
        let backfilled = ((try? db.query("SELECT value FROM settings WHERE key = 'sched_created_backfill'")) ?? []).isEmpty == false
        if !backfilled {
            try? db.run("""
            UPDATE scheduled_tasks SET created_at = COALESCE(
                (SELECT s.created_at FROM sessions s WHERE s.id = scheduled_tasks.log_session_id),
                1700000000 + rowid)
            """)
            try? db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('sched_created_backfill','1')")
        }
    }

    /// 旧库补列: 列已存在则跳过 ALTER (发一条也会成功, 但 SQLite 会往 stderr 吐 duplicate column)。
    private func addColumnIfMissing(_ table: String, _ column: String, _ decl: String) {
        let cols = (try? db.query("PRAGMA table_info(\(table))")) ?? []
        let exists = cols.contains { row in
            if case .text(let name)? = row["name"] { return name == column }
            return false
        }
        guard !exists else { return }
        try? db.run("ALTER TABLE \(table) ADD COLUMN \(column) \(decl)")
    }

    // MARK: - Seed (只在首次启动执行, settings 标记防重复)

    func isSeeded() -> Bool {
        let rows = (try? db.query("SELECT value FROM settings WHERE key = 'seeded'")) ?? []
        return !rows.isEmpty
    }

    func seed(projects: [ProjectGroup],
              chats: [ConversationItem],
              initialSessionId: UUID,
              messages: [ChatMessage]) throws {
        try db.transaction {
            for (i, p) in projects.enumerated() {
                try db.run("INSERT INTO projects (id, title, position) VALUES (?,?,?)",
                           [.text(p.id.uuidString), .text(p.title), .int(Int64(i))])
                for (j, item) in p.items.enumerated().reversed() {
                    try insertSession(item, projectId: p.id,
                                      position: Int64(p.items.count - j))
                }
            }
            for (i, item) in chats.enumerated() {
                try insertSession(item, projectId: nil, position: Int64(chats.count - i))
            }
            // 时间戳规范成递增: 重放侧按 timestamp 排序, mock 数据顺序即真实顺序
            let base = Date.now
            for (i, m) in messages.enumerated() {
                let normalized = ChatMessage(id: m.id, role: m.role, content: m.content,
                                             timestamp: base.addingTimeInterval(Double(i)),
                                             isStreaming: false)
                try appendMessageEvent(sessionId: initialSessionId, normalized)
            }
            try db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('seeded','1')",
                       [])
        }
    }

    // MARK: - Sessions / Sidebar

    private func insertSession(_ item: ConversationItem, projectId: UUID?, position: Int64? = nil) throws {
        var pos = position
        if pos == nil {
            let clause = projectId == nil ? "WHERE project_id IS NULL" : "WHERE project_id = ?"
            let params: [DBValue] = projectId == nil ? [] : [.text(projectId!.uuidString)]
            let rows = try db.query("SELECT COALESCE(MAX(position),0)+1 AS next FROM sessions \(clause)", params)
            pos = int(rows.first?["next"] ?? .null)
        }
        try db.run("""
            INSERT INTO sessions (id, project_id, title, position, created_at, updated_at)
            VALUES (?,?,?,?,?,?)
            """, [.text(item.id.uuidString),
                  projectId.map { .text($0.uuidString) } ?? .null,
                  .text(item.title),
                  .int(pos ?? 0),
                  .real(item.updatedAt.timeIntervalSince1970),
                  .real(item.updatedAt.timeIntervalSince1970)])
    }

    func insertChatSession(_ item: ConversationItem, projectId: UUID? = nil) throws {
        try insertSession(item, projectId: projectId)
    }

    /// P3.4: 新建 project (带工作目录)。
    func insertProject(_ project: ProjectGroup, position: Int64) throws {
        try db.run("INSERT INTO projects (id, title, path, position) VALUES (?,?,?,?)",
                   [.text(project.id.uuidString), .text(project.title),
                    project.path.map { .text($0) } ?? .null, .int(position)])
    }

    /// P3.4: 为已有 project 设置/更新工作目录。
    func updateProjectPath(id: UUID, path: String?) throws {
        try db.run("UPDATE projects SET path = ? WHERE id = ?",
                   [path.map { .text($0) } ?? .null, .text(id.uuidString)])
    }

    /// 删除项目 (连带其下所有会话与 events)。
    func deleteProject(id: UUID) throws {
        let rows = try db.query("SELECT id FROM sessions WHERE project_id = ?",
                                [.text(id.uuidString)])
        for row in rows {
            if case .text(let sid) = row["id"] ?? .null, let uuid = UUID(uuidString: sid) {
                try deleteSession(id: uuid)
            }
        }
        try db.run("DELETE FROM projects WHERE id = ?", [.text(id.uuidString)])
    }

    func renameSession(id: UUID, title: String, updatedAt: Date) throws {
        try db.run("UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?",
                   [.text(title), .real(updatedAt.timeIntervalSince1970), .text(id.uuidString)])
    }

    /// P8.0: 会话活跃即刷新 updated_at (侧栏日分组/排序/相对时间的数据源)。
    func touchSession(id: UUID, updatedAt: Date) throws {
        try db.run("UPDATE sessions SET updated_at = ? WHERE id = ?",
                   [.real(updatedAt.timeIntervalSince1970), .text(id.uuidString)])
    }

    func deleteSession(id: UUID) throws {
        try db.run("DELETE FROM sessions WHERE id = ?", [.text(id.uuidString)])
        try db.run("DELETE FROM events WHERE session_id = ?", [.text(id.uuidString)])
        replayCache[id] = nil   // P9-#10: 写路径失效
        seqCursor[id] = nil
    }

    func loadProjects() throws -> [ProjectGroup] {
        let prows = try db.query("SELECT id, title, path FROM projects ORDER BY position ASC")
        return prows.map { row in
            let pid = UUID(uuidString: text(row, "id")) ?? UUID()
            let items = loadItems(projectId: pid)
            let path: String? = {
                if case .text(let s) = row["path"] ?? .null { return s }
                return nil
            }()
            return ProjectGroup(id: pid, title: text(row, "title"), path: path, items: items)
        }
    }

    func loadChats() throws -> [ConversationItem] {
        loadItems(projectId: nil)
    }

    private func loadItems(projectId: UUID?) -> [ConversationItem] {
        let sql = """
            SELECT id, title, updated_at, side_of FROM sessions
            \(projectId == nil ? "WHERE project_id IS NULL" : "WHERE project_id = ?")
            ORDER BY position DESC
            """
        let params: [DBValue] = projectId == nil ? [] : [.text(projectId!.uuidString)]
        let rows = (try? db.query(sql, params)) ?? []
        return rows.map {
            ConversationItem(id: UUID(uuidString: text($0, "id")) ?? UUID(),
                             title: text($0, "title"),
                             updatedAt: Date(timeIntervalSince1970: double($0, "updated_at")),
                             sideOf: UUID(uuidString: text($0, "side_of")))
        }
    }

    // MARK: - Side chat (P6.3.1 侧问会话)

    /// 侧问会话落库标记 (建会话后追加写侧问专属列; insertSession 保持通用)。
    func markSideChat(id: UUID, sideOf: UUID, sourceFile: String, turns: Int, at: Date) throws {
        try db.run("""
            UPDATE sessions SET side_of = ?, fork_source_file = ?, fork_turns = ?, fork_at = ?
            WHERE id = ?
            """, [.text(sideOf.uuidString),
                  .text(sourceFile),
                  .int(Int64(turns)),
                  .real(at.timeIntervalSince1970),
                  .text(id.uuidString)])
    }

    /// 显式绑定路径写入 (fork 产物 get_state.sessionFile 回读后落库)。
    func setSessionFile(id: UUID, path: String) throws {
        try db.run("UPDATE sessions SET session_file = ? WHERE id = ?",
                   [.text(path), .text(id.uuidString)])
    }

    /// 显式绑定路径 (nil = 未回读过; 普通会话恒 nil, 走 UUID 派生路径)。
    func loadSessionFile(id: UUID) -> String? {
        let rows = (try? db.query("SELECT session_file FROM sessions WHERE id = ?",
                                  [.text(id.uuidString)])) ?? []
        return optionalText(rows.first ?? [:], "session_file")
    }

    /// 侧问信息 (nil = 非侧问会话)。
    func sideChatInfo(id: UUID) -> (sideOf: UUID, sourceFile: String, turns: Int, at: Date)? {
        let rows = (try? db.query("""
            SELECT side_of, fork_source_file, fork_turns, fork_at FROM sessions WHERE id = ?
            """, [.text(id.uuidString)])) ?? []
        guard let row = rows.first,
              let sideOf = UUID(uuidString: text(row, "side_of")),
              let src = optionalText(row, "fork_source_file") else { return nil }
        let turns = Int(int(row["fork_turns"] ?? .null))
        let at = optionalDate(row, "fork_at") ?? .distantPast
        return (sideOf, src, turns, at)
    }

    // MARK: - Events (append-only trajectory)

    private func appendEvent(_ sessionId: UUID, type: String, payload: Data) throws {
        // P9-#10: seq 游标免每次 SELECT MAX; 写路径同时失效重放缓存
        let next: Int64
        if let cursor = seqCursor[sessionId] {
            next = cursor
        } else {
            let rows = try db.query(
                "SELECT COALESCE(MAX(seq),0)+1 AS next FROM events WHERE session_id = ?",
                [.text(sessionId.uuidString)])
            next = int(rows.first?["next"] ?? .null)
        }
        seqCursor[sessionId] = next + 1
        replayCache[sessionId] = nil
        try db.run("""
            INSERT INTO events (session_id, seq, type, payload, ts) VALUES (?,?,?,?,?)
            """, [.text(sessionId.uuidString),
                  .int(next),
                  .text(type),
                  .text(String(data: payload, encoding: .utf8) ?? ""),
                  .real(Date.now.timeIntervalSince1970)])
    }

    /// 追加整条消息投影 (user 发送 / assistant 落定 / Stop 截断的半截回复)。
    func appendMessageEvent(sessionId: UUID, _ message: ChatMessage) throws {
        try appendEvent(sessionId, type: "message", payload: try encoder.encode(message))
    }

    /// 追加工具相位变化 (加载时按 toolId upsert)。
    func appendToolUpdateEvent(sessionId: UUID, toolId: UUID, phase: ToolPhase) throws {
        struct Payload: Codable { let toolId: UUID; let phase: ToolPhase }
        try appendEvent(sessionId, type: "tool_update",
                        payload: try encoder.encode(Payload(toolId: toolId, phase: phase)))
    }

    /// 重放事件流重建消息列表 (流式 chunk 不落库, 只有终态事件)。
    func loadMessages(sessionId: UUID) throws -> [ChatMessage] {
        if let hit = replayCache[sessionId] { return hit }   // P9-#10: 写路径已失效, 命中即最新
        let rows = try db.query(
            "SELECT type, payload FROM events WHERE session_id = ? ORDER BY seq ASC",
            [.text(sessionId.uuidString)])
        var out: [ChatMessage] = []
        for row in rows {
            guard case .text(let json) = row["payload"] ?? .null,
                  let data = json.data(using: .utf8) else { continue }
            switch text(row, "type") {
            case "message":
                out.append(try decoder.decode(ChatMessage.self, from: data))
            case "tool_update":
                struct Payload: Codable { let toolId: UUID; let phase: ToolPhase }
                let p = try decoder.decode(Payload.self, from: data)
                if let i = out.lastIndex(where: {
                    if case .tool(let t) = $0.content { return t.id == p.toolId }
                    return false
                }), case .tool(let t) = out[i].content {
                    out[i].content = .tool(t.withPhase(p.phase))
                }
            default:
                break
            }
        }
        // 事件到达顺序 ≠ 消息时序 (如 text 先 finalize、think 后落库), 按创建时间戳稳定排序;
        // 同时间戳用原始索引兜底 (Swift sort 不保证稳定)。
        out = out.enumerated()
            .sorted { a, b in
                if a.element.timestamp != b.element.timestamp {
                    return a.element.timestamp < b.element.timestamp
                }
                return a.offset < b.offset
            }
            .map(\.element)
        replayCache[sessionId] = out   // P9-#10
        return out
    }

    /// P9-#2: 删除最后一条 user 消息事件之后的所有事件 (regenerate 的库侧对账 —
    /// 内存截断后旧 assistant 回复/tool_update 不清, 重启重放即复活)。
    /// 无 user 事件时不删 (防御)。返回删除事件数。
    @discardableResult
    func deleteEventsAfterLastUser(sessionId: UUID) throws -> Int {
        let rows = try db.query(
            "SELECT id, type, payload FROM events WHERE session_id = ? ORDER BY seq DESC",
            [.text(sessionId.uuidString)])
        var cutoff: Int64?
        for row in rows {
            guard case .text(let type) = row["type"] ?? .null, type == "message",
                  case .text(let json) = row["payload"] ?? .null,
                  let data = json.data(using: .utf8),
                  let msg = try? decoder.decode(ChatMessage.self, from: data),
                  msg.role == .user else { continue }
            if case .int(let id) = row["id"] ?? .null { cutoff = id }
            break
        }
        guard let cutoff else { return 0 }
        var deleted = 0
        for row in rows {
            if case .int(let id) = row["id"] ?? .null, id > cutoff { deleted += 1 }
        }
        try db.run("DELETE FROM events WHERE session_id = ? AND id > ?",
                   [.text(sessionId.uuidString), .int(cutoff)])
        replayCache[sessionId] = nil   // P9-#10: 截断后失效 (seq 游标一并清, 回落 SELECT MAX 防游标越界)
        seqCursor[sessionId] = nil
        return deleted
    }

    // MARK: - Knowledge items (P3.7 知识库/记忆)

    func loadKnowledge() throws -> [KnowledgeItem] {
        let rows = try db.query("""
            SELECT id, scope, project_id, title, content, source, origin_session_id,
                   enabled, status, note, created_at, updated_at
            FROM knowledge_items ORDER BY updated_at DESC
            """)
        return rows.compactMap { row in
            let scope: KnowledgeScope = text(row, "scope") == "project" ? .project : .global
            let source: KnowledgeSource = text(row, "source") == "session" ? .session : .manual
            let status: KnowledgeStatus = text(row, "status") == "pending" ? .pending : .active
            return KnowledgeItem(
                id: UUID(uuidString: text(row, "id")) ?? UUID(),
                scope: scope,
                projectId: UUID(uuidString: text(row, "project_id")),
                title: text(row, "title"),
                content: text(row, "content"),
                source: source,
                originSessionId: UUID(uuidString: text(row, "origin_session_id")),
                enabled: int(row["enabled"] ?? .null) == 1,
                status: status,
                note: text(row, "note").isEmpty ? nil : text(row, "note"),
                createdAt: Date(timeIntervalSince1970: double(row, "created_at")),
                updatedAt: Date(timeIntervalSince1970: double(row, "updated_at")))
        }
    }

    func upsertKnowledge(_ item: KnowledgeItem) throws {
        try db.run("""
            INSERT OR REPLACE INTO knowledge_items
            (id, scope, project_id, title, content, source, origin_session_id,
             enabled, status, note, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(item.id.uuidString),
                  .text(item.scope == .project ? "project" : "global"),
                  item.projectId.map { .text($0.uuidString) } ?? .null,
                  .text(item.title),
                  .text(item.content),
                  .text(item.source == .session ? "session" : "manual"),
                  item.originSessionId.map { .text($0.uuidString) } ?? .null,
                  .int(item.enabled ? 1 : 0),
                  .text(item.status == .pending ? "pending" : "active"),
                  item.note.map { .text($0) } ?? .null,
                  .real(item.createdAt.timeIntervalSince1970),
                  .real(item.updatedAt.timeIntervalSince1970)])
    }

    func deleteKnowledge(id: UUID) throws {
        try db.run("DELETE FROM knowledge_items WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - Custom models (P5.1 菜单自主)

    func loadCustomModels() throws -> [CustomModel] {
        let rows = try db.query("""
            SELECT provider, model_id, label, created_at
            FROM custom_models ORDER BY created_at DESC
            """)
        return rows.map { row in
            CustomModel(provider: text(row, "provider"),
                        modelId: text(row, "model_id"),
                        label: text(row, "label"),
                        createdAt: Date(timeIntervalSince1970: double(row, "created_at")))
        }
    }

    func upsertCustomModel(_ model: CustomModel) throws {
        try db.run("""
            INSERT OR REPLACE INTO custom_models (provider, model_id, label, created_at)
            VALUES (?,?,?,?)
            """, [.text(model.provider),
                  .text(model.modelId),
                  .text(model.label),
                  .real(model.createdAt.timeIntervalSince1970)])
    }

    func deleteCustomModel(provider: String, modelId: String) throws {
        try db.run("DELETE FROM custom_models WHERE provider = ? AND model_id = ?",
                   [.text(provider), .text(modelId)])
    }

    // MARK: - Managed models (P7-M2 模型自管真源)

    func loadManagedModels() throws -> [ManagedModel] {
        let rows = try db.query("""
            SELECT provider, model_id, display_name, api_type, reasoning, base_url, key_ref,
                   context_window, max_tokens, input_modalities, cost_json,
                   thinking_level_map, compat, sampling_params, enabled, source, created_at
            FROM models ORDER BY created_at DESC
            """)
        return rows.map { row in
            ManagedModel(
                provider: text(row, "provider"),
                modelId: text(row, "model_id"),
                displayName: text(row, "display_name"),
                apiType: text(row, "api_type"),
                reasoning: int(row["reasoning"] ?? .null) != 0,
                baseURL: optionalText(row, "base_url"),
                keyRef: optionalText(row, "key_ref"),
                contextWindow: optionalInt(row, "context_window"),
                maxTokens: optionalInt(row, "max_tokens"),
                inputModalities: decodeJSON([String].self, optionalText(row, "input_modalities")) ?? ["text"],
                cost: decodeJSON(ModelCost.self, optionalText(row, "cost_json")),
                thinkingLevelMapJSON: optionalText(row, "thinking_level_map"),
                compatJSON: optionalText(row, "compat"),
                samplingParamsJSON: optionalText(row, "sampling_params"),
                enabled: int(row["enabled"] ?? .null) != 0,
                source: ManagedModelSource(rawValue: text(row, "source")) ?? .custom,
                createdAt: optionalDate(row, "created_at") ?? .distantPast)
        }
    }

    func upsertManagedModel(_ m: ManagedModel) throws {
        try db.run("""
            INSERT OR REPLACE INTO models
            (provider, model_id, display_name, api_type, reasoning, base_url, key_ref,
             context_window, max_tokens, input_modalities, cost_json,
             thinking_level_map, compat, sampling_params, enabled, source, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(m.provider),
                  .text(m.modelId),
                  m.displayName.isEmpty ? .null : .text(m.displayName),
                  .text(m.apiType),
                  .int(m.reasoning ? 1 : 0),
                  m.baseURL.map { .text($0) } ?? .null,
                  m.keyRef.map { .text($0) } ?? .null,
                  m.contextWindow.map { .int(Int64($0)) } ?? .null,
                  m.maxTokens.map { .int(Int64($0)) } ?? .null,
                  encodeJSON(m.inputModalities).map { .text($0) } ?? .null,
                  encodeJSON(m.cost).map { .text($0) } ?? .null,
                  m.thinkingLevelMapJSON.map { .text($0) } ?? .null,
                  m.compatJSON.map { .text($0) } ?? .null,
                  m.samplingParamsJSON.map { .text($0) } ?? .null,
                  .int(m.enabled ? 1 : 0),
                  .text(m.source.rawValue),
                  .real(m.createdAt.timeIntervalSince1970)])
    }

    func deleteManagedModel(provider: String, modelId: String) throws {
        try db.run("DELETE FROM models WHERE provider = ? AND model_id = ?",
                   [.text(provider), .text(modelId)])
    }

    /// P7-M2: custom_models 三字段表一次性迁入 (source=legacy, api_type 借壳默认值);
    /// 同 PK 不覆盖; 旧表保留不删。返回迁移条数 (幂等, 重跑 = 0)。
    func migrateLegacyCustomModels() throws -> Int {
        let rows = try db.query("SELECT provider, model_id, label, created_at FROM custom_models")
        var migrated = 0
        for row in rows {
            let provider = text(row, "provider")
            let modelId = text(row, "model_id")
            let exists = try db.query(
                "SELECT 1 FROM models WHERE provider = ? AND model_id = ?",
                [.text(provider), .text(modelId)])
            guard exists.isEmpty else { continue }
            try db.run("""
                INSERT INTO models
                (provider, model_id, display_name, api_type, enabled, source, created_at)
                VALUES (?,?,?,?,1,'legacy',?)
                """, [.text(provider),
                      .text(modelId),
                      optionalText(row, "label").map { .text($0) } ?? .null,
                      .text("openai-completions"),   // legacy 借壳语义: 走 pi 内置 provider 定义, api 多为 openai 兼容
                      .real(double(row, "created_at"))])
            migrated += 1
        }
        return migrated
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func optionalInt(_ row: [String: DBValue], _ col: String) -> Int? {
        if case .int(let n) = row[col] ?? .null { return Int(n) }
        if case .real(let d) = row[col] ?? .null { return Int(d) }
        return nil
    }

    // MARK: - Scheduled tasks (P3.6 本地定时任务)

    func loadScheduled() throws -> [ScheduledTask] {
        let rows = try db.query("""
            SELECT id, name, prompt, cron, project_id, enabled, last_run_at, log_session_id, continuous, condition, unattended, completed_at, run_count, created_at
            FROM scheduled_tasks ORDER BY created_at DESC
            """)
        return rows.map { row in
            ScheduledTask(
                id: UUID(uuidString: text(row, "id")) ?? UUID(),
                name: text(row, "name"),
                prompt: text(row, "prompt"),
                cron: text(row, "cron"),
                projectId: UUID(uuidString: text(row, "project_id")),
                enabled: int(row["enabled"] ?? .null) == 1,
                lastRunAt: optionalDate(row, "last_run_at"),
                logSessionId: UUID(uuidString: text(row, "log_session_id")).flatMap { $0 },
                continuous: int(row["continuous"] ?? .null) == 1,
                condition: optionalText(row, "condition"),
                unattended: int(row["unattended"] ?? .null) != 0,
                completedAt: optionalDate(row, "completed_at"),
                runCount: Int(int(row["run_count"] ?? .null)),
                createdAt: optionalDate(row, "created_at") ?? .distantPast)
        }
    }

    func upsertScheduled(_ t: ScheduledTask) throws {
        try db.run("""
            INSERT OR REPLACE INTO scheduled_tasks
            (id, name, prompt, cron, project_id, enabled, last_run_at, log_session_id, continuous, condition, unattended, completed_at, run_count, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(t.id.uuidString),
                  .text(t.name),
                  .text(t.prompt),
                  .text(t.cron),
                  t.projectId.map { .text($0.uuidString) } ?? .null,
                  .int(t.enabled ? 1 : 0),
                  t.lastRunAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                  t.logSessionId.map { .text($0.uuidString) } ?? .null,
                  .int(t.continuous ? 1 : 0),
                  t.condition.map { .text($0) } ?? .null,
                  .int(t.unattended ? 1 : 0),
                  t.completedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                  .int(Int64(t.runCount)),
                  .real(t.createdAt.timeIntervalSince1970)])
    }

    func deleteScheduled(id: UUID) throws {
        try db.run("DELETE FROM scheduled_tasks WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - Checkpoint (退出前落盘)

    /// 把 WAL 落进主文件; 在 App willTerminate 与冒烟退出前调用。
    func checkpoint() {
        db.checkpoint()
    }

    // MARK: - Last session (启动恢复上一次作业会话)

    func saveLastSession(id: UUID) throws {
        try db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('last_session_id', ?)",
                   [.text(id.uuidString)])
    }

    func loadLastSession() -> UUID? {
        let rows = (try? db.query("SELECT value FROM settings WHERE key = 'last_session_id'")) ?? []
        guard let v = rows.first?["value"], case .text(let s) = v else { return nil }
        return UUID(uuidString: s)
    }

    // MARK: - Settings (通用 key-value, P4.0.4 并发上限等)
    // 注意: settings 表 value 列为 TEXT NOT NULL — 整数也按文本存取 (TEXT affinity 语义)。

    func saveSetting(key: String, value: Int) {
        try? db.run("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                    [.text(key), .text(String(value))])
    }

    func loadSetting(key: String, defaultValue: Int) -> Int {
        let rows = (try? db.query("SELECT value FROM settings WHERE key = ?", [.text(key)])) ?? []
        guard let v = rows.first?["value"] else { return defaultValue }
        switch v {
        case .text(let s): return Int(s) ?? defaultValue
        case .int(let i):  return Int(i)   // 容错: 若列曾存过原生整数
        default:           return defaultValue
        }
    }

    /// P8-T28: 文本 KV (备份目录/上次备份结果)。
    func saveSettingText(key: String, value: String) {
        try? db.run("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                    [.text(key), .text(value)])
    }

    func loadSettingText(key: String) -> String? {
        let rows = (try? db.query("SELECT value FROM settings WHERE key = ?", [.text(key)])) ?? []
        guard let v = rows.first?["value"], case .text(let s) = v else { return nil }
        return s
    }

    // MARK: - Row helpers

    private func text(_ row: [String: DBValue], _ col: String) -> String {
        if case .text(let s) = row[col] ?? .null { return s }
        return ""
    }

    private func int(_ v: DBValue) -> Int64 {
        if case .int(let n) = v { return n }
        return 0
    }

    private func double(_ row: [String: DBValue], _ col: String) -> Double {
        if case .real(let d) = row[col] ?? .null { return d }
        if case .int(let n) = row[col] ?? .null { return Double(n) }
        return 0
    }

    private func optionalDate(_ row: [String: DBValue], _ col: String) -> Date? {
        if case .real(let d) = row[col] ?? .null { return Date(timeIntervalSince1970: d) }
        return nil
    }

    private func optionalText(_ row: [String: DBValue], _ col: String) -> String? {
        if case .text(let s) = row[col] ?? .null, !s.isEmpty { return s }
        return nil
    }

    // MARK: - P3.10 bash 学习白名单 (settings 持久化, 跨会话生效)

    func loadBashWhitelist() -> Set<String> {
        let rows = (try? db.query("SELECT value FROM settings WHERE key = 'bash_whitelist'")) ?? []
        guard let v = rows.first?["value"], case .text(let json) = v,
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    func saveBashWhitelist(_ tokens: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(tokens).sorted()),
              let json = String(data: data, encoding: .utf8) else { return }
        try? db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('bash_whitelist', ?)",
                    [.text(json)])
    }

    // MARK: - P3.11 扩展启停 (settings 持久化, 按 path 记停用)

    func loadDisabledExtensions() -> Set<String> {
        let rows = (try? db.query("SELECT value FROM settings WHERE key = 'extensions_disabled'")) ?? []
        guard let v = rows.first?["value"], case .text(let json) = v,
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    func saveDisabledExtensions(_ paths: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(paths).sorted()),
              let json = String(data: data, encoding: .utf8) else { return }
        try? db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('extensions_disabled', ?)",
                    [.text(json)])
    }
}
