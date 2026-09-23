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
    /// P9-#10: 事件重放缓存 (sid → 消息列表)。写路径增量维护 (P10.5, 原为失效全量重放)。
    /// 侧栏每次点击会话都全量重放 events (逐行 JSON decode), 事件多时可感卡顿。
    private var replayCache: [UUID: [ChatMessage]] = [:]
    /// P10.5: 增量 append 乱序标记 — 命中缓存但需惰性重排。
    private var replayCacheNeedsSort: Set<UUID> = []
    /// P10.6a: 重放缓存访问序 (旧→新)。原无上限 = 访问过的每个会话全量消息永久常驻,
    /// 内存随会话数线性增长 (长会话尤甚); 溢出逐出最久未用, 下次读回落全量 SELECT。
    private var replayCacheOrder: [UUID] = []
    /// 缓存会话数上限 (常态来回切的就那几个会话, 再多的重放成本已由后台路径兜住)。
    static let replayCacheLimit = 8
    /// P9-#10: seq 游标 (sid → 下一个 seq)。删除路径清空回落 SELECT MAX(seq)。
    private var seqCursor: [UUID: Int64] = [:]
    /// P10.5: 后台重放专用只读连接 (WAL + FULLMUTEX, 与主写连接并发读安全)。
    private let replayDb: Database?

    init(path: String = NSHomeDirectory() + "/.mangox/mangox.db") throws {
        self.path = path
        db = try Database(path: path)
        replayDb = try? Database(path: path, readonly: true)
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
        // P11.1: 注入与记忆 —— 条目分类 / 层 / 优先级 / 身份键 / 教训触发面 / 敏感档 / 命中信号
        addColumnIfMissing("knowledge_items", "kind", "TEXT NOT NULL DEFAULT 'fact'")
        addColumnIfMissing("knowledge_items", "layer", "TEXT NOT NULL DEFAULT 'ondemand'")
        addColumnIfMissing("knowledge_items", "priority", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("knowledge_items", "key", "TEXT")
        addColumnIfMissing("knowledge_items", "trigger", "TEXT")
        addColumnIfMissing("knowledge_items", "counterfactual", "TEXT")
        // `sensitivity` 已于 2026-09-22 (P11.2c) 停用 —— **列保留, 代码不再读写它**。
        // 保留而不 DROP 是**有意留下的妥协, 不是遗漏**, 理由两条:
        //   ① 可回滚: 旧代码会 `SELECT sensitivity`; 若新建的库没这列, 回滚即崩 (而旧库有);
        //   ② DROP COLUMN 不可逆, 换来的只是一列 TEXT 的空间。
        // 它在 DB 里是死重量, 在代码里是活的注释 —— 看到它别"顺手清掉", 先读这段。
        addColumnIfMissing("knowledge_items", "sensitivity", "TEXT NOT NULL DEFAULT 'normal'")
        addColumnIfMissing("knowledge_items", "hit_count", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("knowledge_items", "last_hit_at", "REAL")
        // `key` 全局唯一 (设计上不允许冲突)。SQLite 的 UNIQUE 索引允许多个 NULL ⇒ 无 key 的存量条目不受影响。
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_key ON knowledge_items(key)")
        // P11.4: 知识库档 (第三载体) —— **只存路径 + 描述, 正文仍在磁盘上** (§3.4)。
        // 幂等建表 ⇒ 老库升上来是空列表, 不需要迁移脚本 (同 `addColumnIfMissing` 的策略)。
        // 内置库 (L1 落盘目录自动挂载) **不落这张表** —— 它由落盘目录决定, 每次现算,
        // 落库就会出现"库删了但行还在"的幽灵。
        try db.run("""
        CREATE TABLE IF NOT EXISTS knowledge_bases (
            id          TEXT PRIMARY KEY,
            path        TEXT NOT NULL,             -- 目录绝对路径 (展开 ~ 后)
            description TEXT NOT NULL,             -- 必填: 索引里那句"这是什么"
            enabled     INTEGER NOT NULL DEFAULT 1,
            created_at  REAL NOT NULL,
            updated_at  REAL NOT NULL
        )
        """)
        // 同一目录挂两次 = 索引里同一份资料出现两遍, 纯浪费每轮预算。**DB 层也挡一道**
        // (纵深防御: store 层已先拦, 但手改 DB / 将来的导入器不走 UI)。
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_kb_path ON knowledge_bases(path)")
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
        // P10.2a: 邮箱哨兵四表 (账号池 / 哨兵 / 任务线程 / 拒收日志); 凭据与密钥走 Keychain 不进表
        try db.run("""
        CREATE TABLE IF NOT EXISTS mailbox_accounts (
            id         TEXT PRIMARY KEY,
            label      TEXT NOT NULL,
            address    TEXT NOT NULL,
            preset_id  TEXT,
            imap_host  TEXT NOT NULL DEFAULT '',
            smtp_host  TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        )
        """)
        try db.run("""
        CREATE TABLE IF NOT EXISTS mailbox_sentinels (
            id             TEXT PRIMARY KEY,
            name           TEXT NOT NULL,
            account_id     TEXT NOT NULL UNIQUE,
            project_id     TEXT,
            whitelist      TEXT NOT NULL DEFAULT '[]',
            require_secret INTEGER NOT NULL DEFAULT 1,
            poll_interval  INTEGER NOT NULL DEFAULT 30,
            agent_mode     TEXT NOT NULL DEFAULT 'full',
            approval       TEXT NOT NULL DEFAULT 'autoJudge',
            probe_url      TEXT NOT NULL DEFAULT '',
            enabled        INTEGER NOT NULL DEFAULT 0,
            last_poll_at   REAL,
            last_error     TEXT,
            created_at     REAL NOT NULL
        )
        """)
        try db.run("""
        CREATE TABLE IF NOT EXISTS mailbox_tasks (
            id              TEXT PRIMARY KEY,
            sentinel_id     TEXT NOT NULL,
            thread_key      TEXT NOT NULL,
            session_id      TEXT,
            project_id      TEXT,
            status          TEXT NOT NULL,
            title           TEXT NOT NULL,
            blocked_reason  TEXT,
            last_message_id TEXT,
            created_at      REAL NOT NULL,
            updated_at      REAL NOT NULL,
            UNIQUE (sentinel_id, thread_key)
        )
        """)
        try db.run("""
        CREATE TABLE IF NOT EXISTS mailbox_rejections (
            id          TEXT PRIMARY KEY,
            sentinel_id TEXT NOT NULL,
            sender      TEXT NOT NULL,
            subject     TEXT NOT NULL,
            reason      TEXT NOT NULL,
            message_id  TEXT,
            at          REAL NOT NULL
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_mailbox_rejections ON mailbox_rejections(sentinel_id, at)")
        // 旧库补列: 先查 PRAGMA table_info, 列已存在就不发 ALTER
        // (无条件 ALTER 会被 try? 吞掉异常, 但 SQLite 自己仍往 stderr 吐 duplicate column 日志)
        addColumnIfMissing("mailbox_sentinels", "require_secret", "INTEGER NOT NULL DEFAULT 1")
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
        // P10.4: 任务级执行配置 (JSON blob; 复用 SessionConfig)
        addColumnIfMissing("scheduled_tasks", "config", "TEXT")
        // P10.3: 会话级配置快照 (JSON blob; SessionConfig)
        addColumnIfMissing("sessions", "config", "TEXT")
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
        dropReplayCache(id)   // P9-#10: 写路径失效 (P10.6a: 三处状态同源清)
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
        // P9-#10: seq 游标免每次 SELECT MAX
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
        try db.run("""
            INSERT INTO events (session_id, seq, type, payload, ts) VALUES (?,?,?,?,?)
            """, [.text(sessionId.uuidString),
                  .int(next),
                  .text(type),
                  .text(String(data: payload, encoding: .utf8) ?? ""),
                  .real(Date.now.timeIntervalSince1970)])
        applyEventToReplayCache(sessionId, type: type, payload: payload)
    }

    /// P10.5: 缓存增量维护 (原为失效 → 切回该会话即全量重放, 流式会话每事件一次)。
    /// events append-only: message 追加投影, tool_update 原位 patch; 乱序标记惰性重排。
    private func applyEventToReplayCache(_ sessionId: UUID, type: String, payload: Data) {
        guard var cached = replayCache[sessionId] else { return }   // 未缓存: 下次读时全量构建
        switch type {
        case "message":
            guard let msg = try? decoder.decode(ChatMessage.self, from: payload) else {
                dropReplayCache(sessionId)   // 解码失败: 保守失效
                return
            }
            if let last = cached.last, msg.timestamp < last.timestamp {
                replayCacheNeedsSort.insert(sessionId)
            }
            cached.append(msg)
            replayCache[sessionId] = cached
        case "tool_update":
            struct Payload: Codable { let toolId: UUID; let phase: ToolPhase }
            guard let p = try? decoder.decode(Payload.self, from: payload) else {
                dropReplayCache(sessionId)
                return
            }
            if let i = cached.lastIndex(where: {
                if case .tool(let t) = $0.content { return t.id == p.toolId }
                return false
            }), case .tool(let t) = cached[i].content {
                cached[i].content = .tool(t.withPhase(p.phase))
                replayCache[sessionId] = cached
            }
            // 找不到宿主 tool 消息: 不动缓存 (正常流中宿主必已落库)
        default:
            break   // 投影外事件类型不进缓存
        }
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
        if var hit = replayCache[sessionId] {
            // P10.5: 增量 append 曾乱序 → 惰性重排一次
            if replayCacheNeedsSort.contains(sessionId) {
                hit = Self.stableSorted(hit)
                replayCache[sessionId] = hit
                replayCacheNeedsSort.remove(sessionId)
            }
            touchReplayCache(sessionId)   // P10.6a: 读即最近使用
            return hit
        }
        let rows = try db.query(
            "SELECT type, payload FROM events WHERE session_id = ? ORDER BY seq ASC",
            [.text(sessionId.uuidString)])
        let out = Self.projectEvents(rows)
        replayCache[sessionId] = out   // P9-#10
        touchReplayCache(sessionId)    // P10.6a
        return out
    }

    /// P10.5: 缓存命中判定 (ChatStore「先切再渲染」快路径判定用)。
    func isReplayCached(_ sessionId: UUID) -> Bool {
        replayCache[sessionId] != nil
    }

    // MARK: - P10.6a: 重放缓存上限 (LRU)

    /// 已缓存会话数 (冒烟观察用; 不变式 ≤ replayCacheLimit)。
    var cachedSessionCount: Int { replayCache.count }

    /// 标记最近使用, 并把超限的最久未用项逐出。
    private func touchReplayCache(_ id: UUID) {
        if let i = replayCacheOrder.firstIndex(of: id) { replayCacheOrder.remove(at: i) }
        replayCacheOrder.append(id)
        while replayCacheOrder.count > Self.replayCacheLimit {
            dropReplayCache(replayCacheOrder.removeFirst())
        }
    }

    /// 三处状态同源清理 (cache / 乱序标记 / 访问序) —— 漏一处会留下不一致的悬挂键。
    private func dropReplayCache(_ id: UUID) {
        replayCache[id] = nil
        replayCacheNeedsSort.remove(id)
        if let i = replayCacheOrder.firstIndex(of: id) { replayCacheOrder.remove(at: i) }
    }

    /// P10.5: 后台全量重放 (首切大会话不冻结主线程) — 独立只读连接 SELECT + 纯函数投影。
    /// 同步阻塞调用方线程; ChatStore 在 Task.detached 中调用。结果落地校验由调用方负责。
    nonisolated func replayMessagesInBackground(sessionId: UUID) -> [ChatMessage] {
        guard let replayDb,
              let rows = try? replayDb.query(
                "SELECT type, payload FROM events WHERE session_id = ? ORDER BY seq ASC",
                [.text(sessionId.uuidString)]) else { return [] }
        return Self.projectEvents(rows)
    }

    /// 事件行 → 消息投影 (decode + tool_update 合并 + 时序稳定排序)。纯函数, 可后台跑。
    nonisolated static func projectEvents(_ rows: [[String: DBValue]]) -> [ChatMessage] {
        let decoder = JSONDecoder()
        var out: [ChatMessage] = []
        for row in rows {
            guard case .text(let json) = row["payload"] ?? .null,
                  let data = json.data(using: .utf8) else { continue }
            switch row["type"] {
            case .text("message"):
                if let msg = try? decoder.decode(ChatMessage.self, from: data) {
                    out.append(msg)
                }
            case .text("tool_update"):
                struct Payload: Codable { let toolId: UUID; let phase: ToolPhase }
                guard let p = try? decoder.decode(Payload.self, from: data) else { continue }
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
        return stableSorted(out)
    }

    /// 按创建时间戳稳定排序 (同时间戳用原始索引兜底)。
    nonisolated static func stableSorted(_ msgs: [ChatMessage]) -> [ChatMessage] {
        msgs.enumerated()
            .sorted { a, b in
                if a.element.timestamp != b.element.timestamp {
                    return a.element.timestamp < b.element.timestamp
                }
                return a.offset < b.offset
            }
            .map(\.element)
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
                   enabled, status, note, created_at, updated_at,
                   kind, layer, priority, key, trigger, counterfactual,
                   hit_count, last_hit_at
            FROM knowledge_items ORDER BY updated_at DESC
            """)
        return rows.compactMap { row in
            let scope: KnowledgeScope = text(row, "scope") == "project" ? .project : .global
            let source: KnowledgeSource = text(row, "source") == "session" ? .session : .manual
            let status: KnowledgeStatus = text(row, "status") == "pending" ? .pending : .active
            // P11.1: 未知/缺失值一律回落缺省 (存量库补列后即为缺省值)
            let kind = KnowledgeKind(rawValue: text(row, "kind")) ?? .fact
            let layer = KnowledgeLayer(rawValue: text(row, "layer")) ?? .ondemand
            let lastHit = double(row, "last_hit_at")
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
                updatedAt: Date(timeIntervalSince1970: double(row, "updated_at")),
                kind: kind,
                layer: layer,
                priority: Int(int(row["priority"] ?? .null)),
                key: text(row, "key").isEmpty ? nil : text(row, "key"),
                trigger: text(row, "trigger").isEmpty ? nil : text(row, "trigger"),
                counterfactual: text(row, "counterfactual").isEmpty ? nil : text(row, "counterfactual"),
                hitCount: Int(int(row["hit_count"] ?? .null)),
                lastHitAt: lastHit > 0 ? Date(timeIntervalSince1970: lastHit) : nil)
        }
    }

    /// 写入条目。**按 id 冲突更新, 不用 INSERT OR REPLACE** —— P11.1 给 `key` 加了 UNIQUE 索引后,
    /// REPLACE 的语义会因"撞 key"而**删掉另一条** (静默丢数据)。撞 key 必须报错 (store 层已先拦)。
    func upsertKnowledge(_ item: KnowledgeItem) throws {
        // ⚠️ 参数数组单独成形并显式标注类型 —— 直接内联在 db.run(...) 里会让类型检查爆掉
        // ("unable to type-check in reasonable time", 21 个混合 DBValue 实测踩过)。
        //
        // 用 `ON CONFLICT(id) DO UPDATE` 而非 `INSERT OR REPLACE`: 后者在**唯一约束冲突**时
        // 是"删掉冲突行再插", 而 P11.1 给 `key` 加了 `UNIQUE`。诚实边界: 该场景目前**走不到**
        // (写入期 `keyRejection` 已拦住 key 撞车), 所以这不是在修一个已可达的 bug ——
        // 收益是**纵深防御**: 把"不会误删"从"靠上层校验"降级为"DB 层不可能"。
        let params: [DBValue] = [
            .text(item.id.uuidString),
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
            .real(item.updatedAt.timeIntervalSince1970),
            .text(item.kind.rawValue),
            .text(item.layer.rawValue),
            .int(Int64(item.priority)),
            item.key.map { .text($0) } ?? .null,
            item.trigger.map { .text($0) } ?? .null,
            item.counterfactual.map { .text($0) } ?? .null,
            .int(Int64(item.hitCount)),
            item.lastHitAt.map { .real($0.timeIntervalSince1970) } ?? .null,
        ]
        try db.run("""
            INSERT INTO knowledge_items
            (id, scope, project_id, title, content, source, origin_session_id,
             enabled, status, note, created_at, updated_at,
             kind, layer, priority, key, trigger, counterfactual, hit_count, last_hit_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
             scope = excluded.scope, project_id = excluded.project_id,
             title = excluded.title, content = excluded.content,
             source = excluded.source, origin_session_id = excluded.origin_session_id,
             enabled = excluded.enabled, status = excluded.status, note = excluded.note,
             created_at = excluded.created_at, updated_at = excluded.updated_at,
             kind = excluded.kind, layer = excluded.layer, priority = excluded.priority,
             key = excluded.key, trigger = excluded.trigger,
             counterfactual = excluded.counterfactual,
             hit_count = excluded.hit_count, last_hit_at = excluded.last_hit_at
            """, params)
    }

    func deleteKnowledge(id: UUID) throws {
        try db.run("DELETE FROM knowledge_items WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - Knowledge bases (P11.4 知识库档)

    func loadKnowledgeBases() throws -> [KnowledgeBase] {
        let rows = try db.query("""
            SELECT id, path, description, enabled, created_at, updated_at
            FROM knowledge_bases ORDER BY created_at
            """)
        return rows.compactMap { row in
            let path = text(row, "path")
            guard !path.isEmpty else { return nil }   // 路径空的行走不到任何事, 当脏数据跳过
            return KnowledgeBase(id: text(row, "id"),
                                 path: path,
                                 description: text(row, "description"),
                                 enabled: int(row["enabled"] ?? .null) == 1,
                                 isBuiltin: false,
                                 createdAt: Date(timeIntervalSince1970: double(row, "created_at")),
                                 updatedAt: Date(timeIntervalSince1970: double(row, "updated_at")))
        }
    }

    /// 插入或更新（同样不用 `INSERT OR REPLACE` —— 唯一索引冲突时它会**删掉另一行**, 见
    /// `upsertKnowledge` 的说明; 这里唯一约束是 `path`, 撞了必须由 store 层先拒）。
    func upsertKnowledgeBase(_ base: KnowledgeBase) throws {
        try db.run("""
            INSERT INTO knowledge_bases (id, path, description, enabled, created_at, updated_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
             path = excluded.path, description = excluded.description,
             enabled = excluded.enabled, updated_at = excluded.updated_at
            """, [.text(base.id), .text(base.path), .text(base.description),
                  .int(base.enabled ? 1 : 0),
                  .real(base.createdAt.timeIntervalSince1970),
                  .real(base.updatedAt.timeIntervalSince1970)])
    }

    func deleteKnowledgeBase(id: String) throws {
        try db.run("DELETE FROM knowledge_bases WHERE id = ?", [.text(id)])
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
            SELECT id, name, prompt, cron, project_id, enabled, last_run_at, log_session_id, continuous, condition, unattended, completed_at, run_count, created_at, config
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
                createdAt: optionalDate(row, "created_at") ?? .distantPast,
                config: optionalText(row, "config")
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? decoder.decode(SessionConfig.self, from: $0) })
        }
    }

    func upsertScheduled(_ t: ScheduledTask) throws {
        let configJSON = t.config.flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.run("""
            INSERT OR REPLACE INTO scheduled_tasks
            (id, name, prompt, cron, project_id, enabled, last_run_at, log_session_id, continuous, condition, unattended, completed_at, run_count, created_at, config)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
                  .real(t.createdAt.timeIntervalSince1970),
                  configJSON.map { .text($0) } ?? .null])
    }

    func deleteScheduled(id: UUID) throws {
        try db.run("DELETE FROM scheduled_tasks WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - P10.2a 邮箱哨兵 (账号池 / 哨兵 / 任务线程 / 拒收日志)
    // 四表只存配置与状态投影; 授权码 / 共享密钥在 Keychain (MailboxCredentialStore)。

    /// 拒收日志每哨兵保留条数 (设计稿 §3.1; 首配时用来发现漏加白名单的发件人, 不是审计流水)。
    /// nonisolated: 作默认参数值时在调用方 (非 MainActor) 上下文求值。
    nonisolated static let mailboxRejectionLimit = 200

    // MARK: 账号 (连接参数)

    func loadMailboxAccounts() throws -> [MailboxAccount] {
        let rows = try db.query("""
            SELECT id, label, address, preset_id, imap_host, smtp_host, created_at
            FROM mailbox_accounts ORDER BY created_at ASC
            """)
        return rows.map { row in
            MailboxAccount(
                id: UUID(uuidString: text(row, "id")) ?? UUID(),
                label: text(row, "label"),
                address: text(row, "address"),
                presetId: optionalText(row, "preset_id"),
                imapHost: text(row, "imap_host"),
                smtpHost: text(row, "smtp_host"),
                createdAt: optionalDate(row, "created_at") ?? .distantPast)
        }
    }

    func upsertMailboxAccount(_ a: MailboxAccount) throws {
        try db.run("""
            INSERT OR REPLACE INTO mailbox_accounts
            (id, label, address, preset_id, imap_host, smtp_host, created_at)
            VALUES (?,?,?,?,?,?,?)
            """, [.text(a.id.uuidString),
                  .text(a.label),
                  .text(a.address),
                  a.presetId.map { .text($0) } ?? .null,
                  .text(a.imapHost),
                  .text(a.smtpHost),
                  .real(a.createdAt.timeIntervalSince1970)])
    }

    /// 原始删除 — 引用保护在 `MailboxAccountStore.removeAccount` (被哨兵引用即拒绝, 决定 10)。
    func deleteMailboxAccount(id: UUID) throws {
        try db.run("DELETE FROM mailbox_accounts WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: 哨兵 (策略主体)

    func loadMailboxSentinels() throws -> [MailboxSentinel] {
        let rows = try db.query("""
            SELECT id, name, account_id, project_id, whitelist, require_secret, poll_interval,
                   agent_mode, approval, probe_url, enabled, last_poll_at, last_error
            FROM mailbox_sentinels ORDER BY created_at ASC
            """)
        return rows.map { row in
            MailboxSentinel(
                id: UUID(uuidString: text(row, "id")) ?? UUID(),
                name: text(row, "name"),
                accountId: UUID(uuidString: text(row, "account_id")) ?? UUID(),
                projectId: UUID(uuidString: text(row, "project_id")),
                whitelist: decodeJSON([String].self, text(row, "whitelist")) ?? [],
                requireSecret: int(row["require_secret"] ?? .null) == 1,
                pollInterval: Int(int(row["poll_interval"] ?? .null)),
                agentMode: AgentMode(rawValue: text(row, "agent_mode")) ?? .full,
                approval: ApprovalMode(rawValue: text(row, "approval")) ?? .autoJudge,
                intranetProbeURL: text(row, "probe_url"),
                enabled: int(row["enabled"] ?? .null) == 1,
                lastPollAt: optionalDate(row, "last_poll_at"),
                lastError: optionalText(row, "last_error"))
        }
    }

    /// 1:1 占用的唯一性由 `account_id UNIQUE` 把住 (决定 10) — 这里只做占用查询。
    func upsertMailboxSentinel(_ s: MailboxSentinel) throws {
        // created_at 不在模型里 (UI 用不到), 但列 NOT NULL: 取表内既有值, 首次插入才落 now,
        // 否则每次保存都把创建时刻刷成修改时刻, 列表排序会跟着跳。
        let prior = (try? db.query("SELECT created_at FROM mailbox_sentinels WHERE id = ?",
                                   [.text(s.id.uuidString)])) ?? []
        let createdAt = prior.first.flatMap { optionalDate($0, "created_at") } ?? Date.now
        let whitelistJSON = encodeJSON(s.whitelist) ?? "[]"
        try db.run("""
            INSERT OR REPLACE INTO mailbox_sentinels
            (id, name, account_id, project_id, whitelist, require_secret, poll_interval,
             agent_mode, approval, probe_url, enabled, last_poll_at, last_error, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(s.id.uuidString),
                  .text(s.name),
                  .text(s.accountId.uuidString),
                  s.projectId.map { .text($0.uuidString) } ?? .null,
                  .text(whitelistJSON),
                  .int(s.requireSecret ? 1 : 0),
                  .int(Int64(s.pollInterval)),
                  .text(s.agentMode.rawValue),
                  .text(s.approval.rawValue),
                  .text(s.intranetProbeURL),
                  .int(s.enabled ? 1 : 0),
                  s.lastPollAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                  s.lastError.map { .text($0) } ?? .null,
                  .real(createdAt.timeIntervalSince1970)])
    }

    /// 删哨兵连带清掉它的线程映射与拒收日志 (两者都以 sentinel_id 归属, 留悬空行只会在 UI 里变孤儿)。
    /// Keychain 密钥由 `MailboxSentinelStore` 负责一并删除。
    func deleteMailboxSentinel(id: UUID) throws {
        let sid = id.uuidString
        try db.transaction {
            try db.run("DELETE FROM mailbox_tasks WHERE sentinel_id = ?", [.text(sid)])
            try db.run("DELETE FROM mailbox_rejections WHERE sentinel_id = ?", [.text(sid)])
            try db.run("DELETE FROM mailbox_sentinels WHERE id = ?", [.text(sid)])
        }
    }

    /// 绑定该账号的哨兵 (设计稿 `sentinel(for: accountId)` 的表侧实现; nil = 账号空闲可选)。
    func mailboxSentinelId(usingAccount accountId: UUID) -> UUID? {
        let rows = (try? db.query("SELECT id FROM mailbox_sentinels WHERE account_id = ?",
                                  [.text(accountId.uuidString)])) ?? []
        return rows.first.flatMap { UUID(uuidString: text($0, "id")) }
    }

    // MARK: 任务线程

    func loadMailboxTasks() throws -> [MailboxTask] {
        let rows = try db.query("""
            SELECT id, sentinel_id, thread_key, session_id, project_id, status, title,
                   blocked_reason, last_message_id, created_at, updated_at
            FROM mailbox_tasks ORDER BY created_at DESC
            """)
        return rows.map(mailboxTaskFromRow)
    }

    /// 线程定位 (决定 12) — **先按 sentinel_id 过滤再匹配 thread_key**, 不同邮箱天然隔离。
    func mailboxTask(sentinelId: UUID, threadKey: String) -> MailboxTask? {
        let rows = (try? db.query("""
            SELECT id, sentinel_id, thread_key, session_id, project_id, status, title,
                   blocked_reason, last_message_id, created_at, updated_at
            FROM mailbox_tasks WHERE sentinel_id = ? AND thread_key = ?
            """, [.text(sentinelId.uuidString), .text(threadKey)])) ?? []
        return rows.first.map(mailboxTaskFromRow)
    }

    /// 调用方应先 `mailboxTask(sentinelId:threadKey:)` 取回既有行再改 —— 直接拿新 UUID 落库
    /// 会撞 UNIQUE(sentinel_id, thread_key) 被 REPLACE 打掉旧行, 线程 id 每轮漂移。
    func upsertMailboxTask(_ t: MailboxTask) throws {
        try db.run("""
            INSERT OR REPLACE INTO mailbox_tasks
            (id, sentinel_id, thread_key, session_id, project_id, status, title,
             blocked_reason, last_message_id, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(t.id.uuidString),
                  .text(t.sentinelId.uuidString),
                  .text(t.threadKey),
                  t.sessionId.map { .text($0.uuidString) } ?? .null,
                  t.projectId.map { .text($0.uuidString) } ?? .null,
                  .text(t.status.rawValue),
                  .text(t.title),
                  t.blockedReason.map { .text($0) } ?? .null,
                  t.lastMessageId.map { .text($0) } ?? .null,
                  .real(t.createdAt.timeIntervalSince1970),
                  .real(t.updatedAt.timeIntervalSince1970)])
    }

    func deleteMailboxTask(id: UUID) throws {
        try db.run("DELETE FROM mailbox_tasks WHERE id = ?", [.text(id.uuidString)])
    }

    private func mailboxTaskFromRow(_ row: [String: DBValue]) -> MailboxTask {
        MailboxTask(
            id: UUID(uuidString: text(row, "id")) ?? UUID(),
            sentinelId: UUID(uuidString: text(row, "sentinel_id")) ?? UUID(),
            threadKey: text(row, "thread_key"),
            sessionId: UUID(uuidString: text(row, "session_id")),
            projectId: UUID(uuidString: text(row, "project_id")),
            status: MailboxTaskStatus(rawValue: text(row, "status")) ?? .received,
            title: text(row, "title"),
            blockedReason: optionalText(row, "blocked_reason"),
            lastMessageId: optionalText(row, "last_message_id"),
            createdAt: optionalDate(row, "created_at") ?? .distantPast,
            updatedAt: optionalDate(row, "updated_at") ?? .distantPast)
    }

    // MARK: 拒收日志

    func loadMailboxRejections(sentinelId: UUID, limit: Int = PersistenceStore.mailboxRejectionLimit) -> [MailboxRejection] {
        let rows = (try? db.query("""
            SELECT id, sentinel_id, sender, subject, reason, message_id, at
            FROM mailbox_rejections WHERE sentinel_id = ?
            ORDER BY at DESC, rowid DESC LIMIT ?
            """, [.text(sentinelId.uuidString), .int(Int64(limit))])) ?? []
        return rows.map { row in
            MailboxRejection(
                id: UUID(uuidString: text(row, "id")) ?? UUID(),
                sentinelId: UUID(uuidString: text(row, "sentinel_id")) ?? UUID(),
                sender: text(row, "sender"),
                subject: text(row, "subject"),
                reason: MailboxRejectionReason(rawValue: text(row, "reason")) ?? .notWhitelisted,
                messageId: optionalText(row, "message_id"),
                at: optionalDate(row, "at") ?? .distantPast)
        }
    }

    /// 追加 + 裁剪: 超出的按 at 最旧滚出 (每哨兵 200 条, 是线索不是流水, 不无限膨胀)。
    func appendMailboxRejection(_ r: MailboxRejection) throws {
        let sid = r.sentinelId.uuidString
        try db.transaction {
            try db.run("""
                INSERT INTO mailbox_rejections (id, sentinel_id, sender, subject, reason, message_id, at)
                VALUES (?,?,?,?,?,?,?)
                """, [.text(r.id.uuidString),
                      .text(sid),
                      .text(r.sender),
                      .text(r.subject),
                      .text(r.reason.rawValue),
                      r.messageId.map { .text($0) } ?? .null,
                      .real(r.at.timeIntervalSince1970)])
            try db.run("""
                DELETE FROM mailbox_rejections WHERE sentinel_id = ? AND id NOT IN (
                    SELECT id FROM mailbox_rejections WHERE sentinel_id = ?
                    ORDER BY at DESC, rowid DESC LIMIT ?
                )
                """, [.text(sid), .text(sid), .int(Int64(PersistenceStore.mailboxRejectionLimit))])
        }
    }

    func deleteMailboxRejections(sentinelId: UUID) throws {
        try db.run("DELETE FROM mailbox_rejections WHERE sentinel_id = ?", [.text(sentinelId.uuidString)])
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

    // MARK: P10.3 会话级配置 (sessions.config JSON blob + last_session_config KV)

    func loadSessionConfig(id: UUID) -> SessionConfig? {
        let rows = (try? db.query("SELECT config FROM sessions WHERE id = ?", [.text(id.uuidString)])) ?? []
        guard let row = rows.first, case .text(let json)? = row["config"],
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionConfig.self, from: data)
    }

    func saveSessionConfig(id: UUID, config: SessionConfig) {
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else { return }
        try? db.run("UPDATE sessions SET config = ? WHERE id = ?", [.text(json), .text(id.uuidString)])
    }

    /// 全局回落: 上一次快照 (新会话/未存过配置的会话在启动恢复时继承)。
    func loadLastSessionConfig() -> SessionConfig? {
        guard let json = loadSettingText(key: "last_session_config"),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionConfig.self, from: data)
    }

    func saveLastSessionConfig(_ config: SessionConfig) {
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else { return }
        saveSettingText(key: "last_session_config", value: json)
    }

    /// App 默认配置 (probe 上报的 pi settings 默认, 独立于任何会话): NULL 会话的显示锚点。
    func loadAppDefaultConfig() -> SessionConfig? {
        guard let json = loadSettingText(key: "app_default_config"),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionConfig.self, from: data)
    }

    func saveAppDefaultConfig(_ config: SessionConfig) {
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else { return }
        saveSettingText(key: "app_default_config", value: json)
    }

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
