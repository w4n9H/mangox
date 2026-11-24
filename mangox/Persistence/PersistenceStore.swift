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
        // P15.2: 笔记的**旧版**（「不删旧知识」在笔记区的落地）。
        // 写入路径是这张表**唯一的产地** ⇒ 它跟写入能力同批（P15.2）加; 消费它画"变更史"的
        // 界面在 P15.4。**只加表, 不动任何现有表**（P11 判据: DB 列只增不删）。
        try db.run("""
        CREATE TABLE IF NOT EXISTS note_revisions (
            id         TEXT PRIMARY KEY,
            root_id    TEXT NOT NULL,               -- 笔记根 id (note:global / note:project:<pid>)
            path       TEXT NOT NULL,               -- 根内相对路径
            content    TEXT NOT NULL,               -- 被覆盖/删除前的**整篇原文**
            sha256     TEXT NOT NULL,               -- 那一版的指纹
            written_at REAL NOT NULL,
            origin     TEXT NOT NULL,               -- NoteRevisionOrigin.rawValue (小写落库)
            sources    TEXT NOT NULL DEFAULT '[]'   -- P17: [ProposalSource] 的 JSON (形状同 note_proposals.sources)
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_note_revisions ON note_revisions(root_id, path, written_at)")
        // P17 补列 —— 老库升上来时 `CREATE TABLE IF NOT EXISTS` **不会动它** ⇒ 必须显式 ALTER。
        // 存量行被 `DEFAULT '[]'` 填成**空列表**: 那不叫「缺」而叫「没有来源记录」——
        // 本列上线之前写下的版本, 谁也没法回头补出它当初的依据。
        // ⚠️ 形状与 `note_proposals.sources` **逐字同源**（都是 `TEXT NOT NULL` + JSON）:
        // 两处各写一套格式的话, 其中一处悄悄改了, 另一处读出来就是空, 而**零红灯**。
        addColumnIfMissing("note_revisions", "sources", "TEXT NOT NULL DEFAULT '[]'")
        // P15.3: dream 的**提案**。`sources` 是一列 JSON 文本 (条数不定、永远整块读写)。
        // ⚠️ 提案**不落 `_proposals/` 目录**: 扫描器只挡 `hasPrefix(".")` 与 `excludedNames`
        // 那三个名字, 下划线两头都不占 ⇒ 落盘的提案会被当成笔记扫进索引、每轮吃 prompt 预算。
        // 落表还顺带解决另外两件: 提案是**带状态的对象**(文件系统不表达状态), 以及
        // "输入永不被改写"这条不变量 (靠 `base_hash` 比对比靠"文件没被写"更容易断言)。
        // **只加表, 不动任何现有表**（P11 判据: DB 列只增不删）。
        try db.run("""
        CREATE TABLE IF NOT EXISTS note_proposals (
            id          TEXT PRIMARY KEY,
            root_id     TEXT NOT NULL,              -- 笔记根 id (note:global / note:project:<pid>)
            kind        TEXT NOT NULL,              -- NoteProposalKind.rawValue (insight / merge / replace / delete)
            target_path TEXT NOT NULL,              -- 根内相对路径 (与 note_revisions.path 同形)
            base_hash   TEXT NOT NULL,              -- 提出时的指纹; insight 恒空串
            title       TEXT NOT NULL,              -- 可空串
            content     TEXT NOT NULL,              -- 整篇新内容 (不是 diff)
            reason      TEXT NOT NULL,              -- 可空串: 为什么提这一条
            sources     TEXT NOT NULL,              -- [ProposalSource] 的 JSON (非空; 拿不出指针的不入表)
            created_at  REAL NOT NULL,
            status      TEXT NOT NULL,              -- NoteProposalStatus.rawValue (小写落库)
            session_id  TEXT NOT NULL,              -- 产生它的那次 dream 的日志会话 id
            decided_at  REAL                        -- P15.4 遗留列: P15.8/5f 起无写入者 (恒 NULL), 保留 = 列只增不删
        )
        """)
        // 列表按「待审优先、新的在前」读 ⇒ 索引给到这三列; P15.4 的终态写也是按 (status) 过滤。
        try db.run("CREATE INDEX IF NOT EXISTS idx_note_proposals ON note_proposals(status, created_at DESC)")
        // P15.4 补列（老库升上来时 `CREATE TABLE IF NOT EXISTS` 不会动它 ⇒ 必须显式 ALTER）。
        // ⚠️ P15.8/5f 起**没有任何读取者**（拍过板的行直接删掉, 不再记"拍板时刻"）——
        // 但 `INSERT` 仍然点得到这一列, 删掉 ALTER 会让老库在写入时**报没有这一列**。
        // ⇒ 列与非空形状都保留（DB 判据: 列只增不删）。
        addColumnIfMissing("note_proposals", "decided_at", "REAL")
        // P15.8/5f **存量移除**: 本版起提案表 = 「待审队列」, 拍过板的行直接删掉（不再写终态）。
        // 老库里那两条终态行若留着, 会变成**读得出来但看不见**的垃圾 ——
        // `NoteProposalStatus` 已收敛成只有 `pending`, `guard let status` 会把它们静默丢掉。
        // ⇒ 明确删掉, 不让它静默。
        // ⚠️ 将来若重新引入终态行, **这一条必须一起删** —— 否则它每次启动都会静默吃掉新写入的行。
        try db.run("DELETE FROM note_proposals WHERE status <> 'pending'")
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
        // P19.2 S15b: 飞书机器人（一个自建应用 = 一个身份 = 一个机器人）。
        //
        // 「一个机器人只归一个助理」由 `assistant_id` 是**单值列**保证 —— 不靠保存时扫全表
        // 去摘别人的绑定（那版做法的症状是"我明明绑给它了，它不回"，而且界面无解释）。
        // 反过来也成立（2026-11-17 boss 定）：**一个助理只挂一个机器人**，由
        // `ChatStore.assignRemoteBot` 顶掉旧的保证 —— 列只有一个值，加上这句才是 1:1。
        //
        // ⚠️ **app_secret 不在这张表里**（`feishu.bot.<id>.secret` 进钥匙串）。`app_id` 在这里:
        // 它是标识不是凭据，而列表页要能不看钥匙串就把 N 行画出来（读钥匙串 = 无签名构建弹框）。
        //
        // ⚠️ `enabled` 是**死列**（2026-11-18）: 机器人没有自己的开关了，连接只看归属的助理
        // 开没开 ⇒ 这一列既不读也不写。留着是因为「列只增不删」—— 删了旧版 App 打开新库会崩。
        try db.run("""
        CREATE TABLE IF NOT EXISTS remote_bots (
            id           TEXT PRIMARY KEY,
            name         TEXT NOT NULL DEFAULT '',
            app_id       TEXT NOT NULL DEFAULT '',
            enabled      INTEGER NOT NULL DEFAULT 1,
            assistant_id TEXT,
            last_chat_id TEXT,
            last_chat_at REAL,
            created_at   REAL NOT NULL
        )
        """)
        // P19: 收件档整体删除 ⇒ mailbox_sentinels / mailbox_tasks / mailbox_rejections **不再创建**。
        // 旧库里的这三张表与数据原样留着（列只增不删的同一条纪律: 降级回旧版仍能打开）。
        // 账号池表保留 —— P19.1 的邮件通道要接着用它。
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
        // P19: 任务类型 (execute / assistant); 旧条件值守不落此列, 由 condition 派生为只读归档
        addColumnIfMissing("scheduled_tasks", "kind", "TEXT")
        // P19 助理: 来源列表 (JSON 数组; 空 / NULL 都解成 [] —— 老库升上来没有来源是正常的)
        addColumnIfMissing("scheduled_tasks", "sources", "TEXT")
        // P19 S7 触达: 配置 JSON (系统通知 / 邮件收件人 / 飞书开关) 与日预算上限。
        // ⚠️ 飞书那条 **URL 不在这里** —— 它住 Keychain, 库里这一列只有一个 Bool。
        addColumnIfMissing("scheduled_tasks", "notify", "TEXT")
        addColumnIfMissing("scheduled_tasks", "daily_token_budget", "INTEGER NOT NULL DEFAULT 0")
        // 2026-11-23: **可空**是刻意的 —— `NULL` = 从没配过（老库升上来），`0` = 人明确关掉。
        // 带 `DEFAULT 0` 的话这两件事就再也分不开：老行会被读成"用户关掉了"，
        // 而默认值本该由 `ScheduledTask.effectiveFollowUpsPerDay` 一处给（含 Cron 档恒 0）。
        addColumnIfMissing("scheduled_tasks", "follow_ups_per_day", "INTEGER")
        // P20 (2026-11-24) 助理团队: 六个列。**`role` 带 NOT NULL DEFAULT 'main'`** ——
        // 老行、以及所有 Cron 行都没有"角色"这个概念，读出来必须还是"队长"；把缺省放在 DDL 里
        // 而不是靠读侧兜，是因为 NULL 会一路飘到 `role == .main` 这类比较里（`TaskRole.decode`
        // 只是最后一道，不是唯一一道）。
        addColumnIfMissing("scheduled_tasks", "role", "TEXT NOT NULL DEFAULT 'main'")
        // worker 归属的 main。单值列保证"一个 worker 只归一个 main"。**删 main 之后故意不置空**
        // （留成悬挂值）: 画板上它要落进「未归属」区，而置空之后"归谁"这件事就再也查不回来了。
        addColumnIfMissing("scheduled_tasks", "parent_id", "TEXT")
        // 职责 / 职责说明。两段都是**注入面或工具面的原文**（见 `AgentTeam.swift` 文件头）。
        addColumnIfMissing("scheduled_tasks", "description", "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing("scheduled_tasks", "description_detail", "TEXT NOT NULL DEFAULT ''")
        // 三态（同 `follow_ups_per_day`）: NULL = 没配过（走出厂值），0 = 人明确关掉。
        addColumnIfMissing("scheduled_tasks", "delegate_per_day", "INTEGER")
        // 1 = "它是因为 main 停用才跟着停的"。唯一读者是"启 main ⇒ 恢复谁"。
        addColumnIfMissing("scheduled_tasks", "disabled_by_parent", "INTEGER NOT NULL DEFAULT 0")
        // P19.2 S15: 飞书单聊绑定的 chat_id。**列只增不删**（旧版 App 打开新库会崩那一条）。
        // ⚠️ S15b 起这一列**没人读了**（绑定改在 `remote_bots.assistant_id` 上）。留着是为了
        // "旧版打开新库不崩"，以及迁移时一次性把它收成机器人行（见 `migrateLegacyRemoteBindings`）。
        addColumnIfMissing("scheduled_tasks", "remote_chat_id", "TEXT")
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
        // P19: 助理的结论（findings）+ 它的执行痕迹。**两张表一次建**，因为 `_actions`
        // 是 findings 的从表、由执行段（S6）写；先有表比事后 ALTER 稳（老库升上来是空表）。
        //
        // ⚠️ `status` **不做 CHECK 约束**: 值域是产品语义（`FindingStatus`），将来加一个状态
        // 若碰上 CHECK，老的 App 版本打开新库会**写不进去**（DB 列只增不删的同一条理由，
        // 见 P11 判据 ②）。越界的值由解码侧兜成"不进收件箱、不放行执行"。
        try db.run("""
        CREATE TABLE IF NOT EXISTS agent_findings (
            id          TEXT PRIMARY KEY,
            task_id     TEXT NOT NULL,
            source_id   TEXT NOT NULL,
            session_id  TEXT NOT NULL,
            title       TEXT NOT NULL,
            body        TEXT NOT NULL,
            evidence    TEXT,
            plan        TEXT,                       -- WatchPlanStep 的 JSON 数组; 空 = 只会看不会修
            plan_rev    INTEGER NOT NULL DEFAULT 1,
            severity    TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            status      TEXT NOT NULL,
            undo_path   TEXT,
            tokens      INTEGER,
            cost_usd    REAL,
            created_at  REAL NOT NULL,
            decided_at  REAL
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_findings_task ON agent_findings(task_id, created_at)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_findings_fp ON agent_findings(fingerprint)")
        // P19.2 S14: 催促状态。**只增不删**（老库升上来是 0 / NULL = 从没催过，语义等价于"新行"，
        // 不需要迁移脚本）。为什么不另建一张表: 催的对象就是这条 finding 本身，
        // "同一件事最多催 K 次"这个上限必须与 finding **同一行**才不会被重建成两件事。
        addColumnIfMissing("agent_findings", "nag_count", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("agent_findings", "last_nagged_at", "REAL")
        try db.run("""
        CREATE TABLE IF NOT EXISTS agent_finding_actions (
            finding_id  TEXT NOT NULL,
            step        INTEGER NOT NULL,
            kind        TEXT NOT NULL,
            target      TEXT,
            result      TEXT NOT NULL,
            output      TEXT,
            at          REAL NOT NULL,
            PRIMARY KEY (finding_id, step)
        )
        """)
        // P19 S7: 日 token 账本。判据是 (任务, 日) —— 预算闸问的正是这两个维度。
        //
        // 为什么不从事件流现算: 事件里的 `usage` 是**按一次 LLM 调用**记的，它不带"这次调用属于
        // 哪一次 fire"；而一场日志会话会装下几十次 fire。想现算就得给每条事件再补一列归属，
        // 那是改事件流的形状 —— 比多一张两列表贵得多。
        //
        // `day` 是**本地日**的 `yyyy-MM-dd`（Text，不是时间戳）: 预算是人对"今天"的直觉，
        // 存 UTC 日会让 +08:00 的用户在早上 8 点前被算进昨天。
        try db.run("""
        CREATE TABLE IF NOT EXISTS agent_token_daily (
            task_id TEXT NOT NULL,
            day     TEXT NOT NULL,
            tokens  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (task_id, day)
        )
        """)
        // 2026-11-23: follow-up —— agent 给自己约的定时唤醒。
        //
        // **独立一张表**，不借 `scheduled_tasks` 造一次性任务：那张表的每一行都会进任务列表、
        // 占一条日志会话、参与 cron 匹配与"漏跑"统计；而一次"半小时后再来看看"的最短命周期
        // 只有一轮，塞进去等于往用户面前扔一堆跑完就该消失的任务，且 `refreshMissedFires`
        // 会把"约过但没跑"算成漏跑（那是两件完全不同的事）。
        //
        // `status` 同样**不做 CHECK 约束**（理由见上面 `agent_findings` 那段）。
        try db.run("""
        CREATE TABLE IF NOT EXISTS agent_followups (
            id          TEXT PRIMARY KEY,
            task_id     TEXT NOT NULL,
            due_at      REAL NOT NULL,
            why         TEXT NOT NULL,
            status      TEXT NOT NULL,
            attempts    INTEGER NOT NULL DEFAULT 0,
            created_at  REAL NOT NULL,
            fired_at    REAL,
            note        TEXT
        )
        """)
        // 扫描口径 = `status = ? AND due_at <= ?` ⇒ 这条索引就是 tick 那一跳要的。
        try db.run("CREATE INDEX IF NOT EXISTS idx_followups_due ON agent_followups(status, due_at)")
        // 删任务时的回收口径 + "这个任务还欠着几条"（`maxPendingPerTask` 那条闸）。
        try db.run("CREATE INDEX IF NOT EXISTS idx_followups_task ON agent_followups(task_id, status)")
        // 配额闸（`followUpCountSince`）按 `created_at` 扫同一个任务的行。
        try db.run("CREATE INDEX IF NOT EXISTS idx_followups_created ON agent_followups(task_id, created_at)")
        // P20: `agent_followups.kind` —— `self`（模型自己约的，占配额）/ `call_back`（worker 交活
        // 之后 App 插的，不占配额）。**老行全是 `self`**（那个功能出生时只有一种来路），
        // 所以缺省值就是真相，不需要迁移脚本。
        // ⚠️ 补列必须写在**建表之后** —— `addColumnIfMissing` 对不存在的表是静默无效的
        // （PRAGMA 返回空 ⇒ 以为缺 ⇒ ALTER 失败被 `try?` 吞掉），而这里“失败”的表现是
        // 配额口径永远按老 SQL 走、回叫照样吃配额，且零红灯。
        addColumnIfMissing("agent_followups", "kind", "TEXT NOT NULL DEFAULT 'self'")
        // 2026-11-23:「已发消息」记忆 —— 助理往外发过的每一句。**只记模型说的话**
        //（`notice*` 那族是 App 话术, 不记, 所以**没有 `origin` 列**）。
        // `id` 同时是发给桥的 `ref`: 回执带回来 ⇒ "这一条发没发出去"能对上具体那一条。
        // `status` 同样不做 CHECK（老版打开新库要能写, 同上面两处）。
        try db.run("""
        CREATE TABLE IF NOT EXISTS agent_sent (
            id          TEXT PRIMARY KEY,
            task_id     TEXT NOT NULL,
            session_id  TEXT,
            at          REAL NOT NULL,
            kind        TEXT NOT NULL,
            status      TEXT NOT NULL,
            text        TEXT NOT NULL,
            note        TEXT
        )
        """)
        // 注入段与界面都问"这个任务最近几条" ⇒ 一条索引够两处用。
        try db.run("CREATE INDEX IF NOT EXISTS idx_sent_task ON agent_sent(task_id, at)")
        // P20 (2026-11-24) 派活单 —— main 给 worker 的一次**定时唤醒 + 工单**。
        //
        // 为什么独立一张表而不是并进 `agent_followups`（两者都按时间触发，看起来该合一）:
        // 判据是**字段与状态机是否同构**，不是"是不是都按时间触发"。follow-up 只有 `why` 与四态;
        // 派活有工单三件、两条时间线（`due_at` / `due_by`）、回执消费（`reported_at`）与五种终态。
        // 并表会得到十几个 nullable 列，而每一列都要在两种语义下各解释一遍。
        //
        // `status` 同样**不做 CHECK 约束**（理由见上面 `agent_findings` 那段）。
        // `id` 同时是回执的关联键（与 `agent_sent.id` 当 `ref` 同一族做法）。
        try db.run("""
        CREATE TABLE IF NOT EXISTS agent_delegations (
            id          TEXT PRIMARY KEY,
            from_task   TEXT NOT NULL,              -- 必须是 main（域层校验，见 TeamRule）
            to_task     TEXT NOT NULL,
            goal        TEXT NOT NULL,
            acceptance  TEXT NOT NULL,
            context     TEXT,
            due_at      REAL NOT NULL,              -- 起跑时刻 = 派活那一刻 + after_minutes
            due_by      REAL,                       -- 最晚什么时候要（可空）
            status      TEXT NOT NULL,
            attempts    INTEGER NOT NULL DEFAULT 0,
            note        TEXT,                       -- 为什么被挡 / 为什么失败（闸与桥的原话）
            summary     TEXT,                       -- 交活时 worker 写的一句话结论
            reported_at REAL,                       -- main **成功收尾之后**才标（不标在注入时）
            created_at  REAL NOT NULL,
            started_at  REAL,
            finished_at REAL
        )
        """)
        // "它手上有没有活" 是最高频的查询（派活前那道硬拒）⇒ 主索引在 `to_task`。
        try db.run("CREATE INDEX IF NOT EXISTS idx_delegation_to ON agent_delegations(to_task, status)")
        // tick 那一跳: `status = 'queued' AND due_at <= now`。
        try db.run("CREATE INDEX IF NOT EXISTS idx_delegation_due ON agent_delegations(status, due_at)")
        // 每日配额（`delegationCountSince` 按 `created_at` 数同一个 main 的单子）+ 一轮几条。
        try db.run("CREATE INDEX IF NOT EXISTS idx_delegation_from ON agent_delegations(from_task, created_at)")
        // P19.2 S15b: 旧的「助理 × chat_id」绑定收成机器人行。**放在最后** —— 它要读
        // `scheduled_tasks.remote_chat_id`（上面 260 行才补的列）与刚建好的 `remote_bots`。
        migrateLegacyRemoteBindings()
    }

    /// 一次性: 把 S15 的 chat_id 绑定搬成一条机器人行（app_id 留空，见下）。
    ///
    /// 判据是 settings 里的**一次性标记**，不是"表空着" —— 用户把机器人全删掉再重启，
    /// 表也是空的；靠"表空"判会让**删掉的机器人复活**。
    ///
    /// ⚠️ 这里**不读钥匙串**。`app_id` 也留空: 读钥匙串会在启动线程上弹授权框
    /// （无签名构建每次重编都弹一次），表现是"App 启动卡住"，而且它发生在启动路径上，
    /// 人连界面的影子都看不到。凭据留给设置页那个显式按钮（列表里那行显示「缺 app_id」，
    /// 人一看就知道要补，见 `FeishuChannelSettings` 的「从旧版读取」）。
    private func migrateLegacyRemoteBindings() {
        let done = ((try? db.query("SELECT value FROM settings WHERE key = 'remote_bots_migrated'")) ?? []).isEmpty == false
        guard !done else { return }
        let rows = (try? db.query("""
            SELECT id, name, remote_chat_id FROM scheduled_tasks
            WHERE remote_chat_id IS NOT NULL AND remote_chat_id != ''
            """)) ?? []
        let now = Date().timeIntervalSince1970
        for row in rows {
            try? db.run("""
                INSERT OR IGNORE INTO remote_bots
                (id, name, app_id, assistant_id, last_chat_id, last_chat_at, created_at)
                VALUES (?,?,'',?,?,?,?)
                """, [.text(UUID().uuidString),
                      .text(text(row, "name")),
                      .text(text(row, "id")),
                      .text(text(row, "remote_chat_id")),
                      .real(now), .real(now)])
        }
        try? db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('remote_bots_migrated','1')")
    }

    // MARK: - 飞书机器人 (P19.2 S15b)

    func loadRemoteBots() throws -> [RemoteBot] {
        // ⚠️ `enabled` 列**不再读**（2026-11-18: 机器人没有自己的开关了，连接只看归属的助理）。
        // 列留着不删（列只增不删：降级回旧版仍能打开），但也**不再写** ——
        // 见 `upsertRemoteBot` 里那句说明。
        let rows = try db.query("""
            SELECT id, name, app_id, assistant_id, last_chat_id, last_chat_at, created_at
            FROM remote_bots ORDER BY created_at ASC
            """)
        return rows.map { row in
            RemoteBot(
                id: UUID(uuidString: text(row, "id")) ?? UUID(),
                name: text(row, "name"),
                appId: text(row, "app_id"),
                // 空串与 NULL 同义（手改库会留下空串）。
                assistantId: optionalText(row, "assistant_id")
                    .flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) },
                lastChatId: optionalText(row, "last_chat_id").flatMap { $0.isEmpty ? nil : $0 },
                lastChatAt: optionalDate(row, "last_chat_at"),
                createdAt: optionalDate(row, "created_at") ?? .distantPast)
        }
    }

    func upsertRemoteBot(_ b: RemoteBot) throws {
        // `enabled` 不写 ⇒ 新行拿到列默认值 1。这是**有意留着的死列**：删列会让旧版 App
        // 打开新库时刷不出这一行（列只增不删），而留着它没人读也不会有第二种真源。
        try db.run("""
            INSERT OR REPLACE INTO remote_bots
            (id, name, app_id, assistant_id, last_chat_id, last_chat_at, created_at)
            VALUES (?,?,?,?,?,?,?)
            """, [.text(b.id.uuidString),
                  .text(b.name),
                  .text(b.appId),
                  b.assistantId.map { .text($0.uuidString) } ?? .null,
                  b.lastChatId.map { .text($0) } ?? .null,
                  b.lastChatAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                  .real(b.createdAt.timeIntervalSince1970)])
    }

    /// 删机器人。钥匙串那条 secret 由 `ChatStore.removeRemoteBot` 一起清（本层碰不到钥匙串）。
    func deleteRemoteBot(id: UUID) throws {
        try db.run("DELETE FROM remote_bots WHERE id = ?", [.text(id.uuidString)])
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

    /// **所有**还指着某个 transcript 文件的会话 —— 侧问快照的孤儿回收只读这一列。
    ///
    /// 两列都要, 少一列就会把**在用的**快照当孤儿删掉:
    /// - `session_file`: 已回读、被会话认领的记忆文件（侧问首回合成功后才有值）;
    /// - `fork_source_file`: 侧问**还没发消息/没落定**时唯一的指向 —— 会话已经在侧栏里,
    ///   但 `session_file` 仍是 NULL。只看前者 ⇒ 开了侧问没发消息的那场, 快照在下次开机
    ///   被清掉, 而那场侧问还在列表里、首回合 `--fork` 一个不存在的文件。
    ///
    /// ⚠️ 不要改成扫 `events`: 那里是消息, 不是绑定。判据必须与"谁真正持有这个文件"同源,
    ///   否则会得出"这文件没人用"的假结论, 然后把还在用的快照删掉。
    func allSessionFileRefs() -> [String] {
        let rows = (try? db.query("""
            SELECT session_file AS ref FROM sessions
              WHERE session_file IS NOT NULL AND session_file <> ''
            UNION
            SELECT fork_source_file FROM sessions
              WHERE fork_source_file IS NOT NULL AND fork_source_file <> ''
            """)) ?? []
        return rows.compactMap { optionalText($0, "ref") }
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

    /// 一场会话的**正文规模**（定向 dream 的确认弹窗用，`由此 Dream`）。
    ///
    /// 为什么是一条聚合而不是 `replayMessages` 之后再数: 后者会把整条事件流解码成
    /// `ChatMessage`（实测 794 个事件里 616 个解码完就被丢弃），只为显示一个字数——而且这段
    /// 代码是**点了菜单项才跑**，用户会直接感到那一下的卡顿。
    ///
    /// **`chars` 的定义必须与 `KnowledgeStore.sessionMaterial` 拼出来的长度一致**，否则弹窗
    /// 说"送入 11.3 万字"、实际送进去 11.7 万，就是"标记比事实说得少"。口径:
    /// 每条 = 角色前缀（`用户: ` / `助手: ` / `系统: ` 都是 4 字符）+ 正文，行间一个换行
    /// ⇒ n 行合计 `正文总长 + 4n + (n - 1)`。空正文不计数（`sessionMaterial` 同样跳过）。
    ///
    /// ⚠️ 已知的一处**不精确**: SQLite `length()` 数的是**码点**，Swift `String.count` 数的是
    /// **字形簇**。含 ZWJ 的 emoji（一个字形簇 4 个码点）会被这里多算 ⇒ 这个数**偏大**。
    /// 偏大的方向是安全的（只影响显示与"会不会截断"的保守判断），且只在 emoji 密集时才有感。
    func dreamMaterialStats(id: UUID) -> (chars: Int, turns: Int, lines: Int) {
        let rows = (try? db.query("""
            SELECT
              COALESCE(SUM(LENGTH(json_extract(payload, '$.content.text._0'))), 0) AS text_len,
              COALESCE(SUM(CASE WHEN json_extract(payload, '$.role') = 'user'
                                 AND LENGTH(json_extract(payload, '$.content.text._0')) > 0
                                THEN 1 ELSE 0 END), 0) AS turns,
              COALESCE(SUM(CASE WHEN LENGTH(json_extract(payload, '$.content.text._0')) > 0
                                THEN 1 ELSE 0 END), 0) AS lines
            FROM events
            WHERE session_id = ? AND type = 'message'
              AND json_extract(payload, '$.content.text._0') IS NOT NULL
            """, [.text(id.uuidString)])) ?? []
        let row = rows.first ?? [:]
        let textLen = Int(int(row["text_len"] ?? .null))
        let lines = Int(int(row["lines"] ?? .null))
        let turns = Int(int(row["turns"] ?? .null))
        let chars = lines > 0 ? textLen + 4 * lines + (lines - 1) : 0
        return (chars, turns, lines)
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

    // MARK: - Note revisions (P15.2 笔记旧版)

    /// 记下一个旧版本。**只增不改不删** —— 它的语义就是"这一版曾经存在过"。
    func appendNoteRevision(_ r: NoteRevision) throws {
        try db.run("""
            INSERT INTO note_revisions (id, root_id, path, content, sha256, written_at, origin, sources)
            VALUES (?,?,?,?,?,?,?,?)
            """, [.text(r.id.uuidString), .text(r.rootId), .text(r.path), .text(r.content),
                  .text(r.sha256), .real(r.writtenAt.timeIntervalSince1970),
                  .text(r.origin.rawValue), .text(encodeJSON(r.sources) ?? "[]")])
    }

    /// 某一篇的历史（新 → 旧）。
    ///
    /// P15.2 的消费者是**冒烟**（验"旧版真的留下了, 而且内容就是覆盖前那一份"）;
    /// P15.4 的"变更史"界面读同一个函数 —— 不另开一条查询路径。
    func loadNoteRevisions(rootId: String, path: String) throws -> [NoteRevision] {
        try db.query("""
            SELECT id, root_id, path, content, sha256, written_at, origin, sources
            FROM note_revisions WHERE root_id = ? AND path = ?
            ORDER BY written_at DESC
            """, [.text(rootId), .text(path)]).compactMap { row in
            guard let id = UUID(uuidString: text(row, "id")),
                  let origin = NoteRevisionOrigin(rawValue: text(row, "origin")) else { return nil }
            // ⚠️ `sources` 解析失败回落**空列表**, 而不是像 `loadNoteProposals` 那样**丢整行** ——
            // 这个不对称是有意的: 提案表里 `sources` 是**非空约束的一部分**（拿不出指针的不入表）,
            // 丢了它那行就不该存在; 而版本史里它只是一条**附加信息** —— 丢了它这一版仍然完整
            // （content / sha256 / origin 都在）, 而**丢整行会让变更史凭空少一版**, 那是更重的损失。
            return NoteRevision(id: id, rootId: text(row, "root_id"), path: text(row, "path"),
                                content: text(row, "content"), sha256: text(row, "sha256"),
                                writtenAt: Date(timeIntervalSince1970: double(row, "written_at")),
                                origin: origin,
                                sources: decodeJSON([ProposalSource].self, text(row, "sources")) ?? [])
        }
    }

    /// 这一版**记过没有**？—— 只回答是否, 不把历史正文拖回来。
    ///
    /// P15.4 的写入路径在落盘前问它: **没记过 ⇒ 先补记**。补的是什么?
    /// 就是"上一次写入没有被我们记下的那一版" —— 它只有两个来源: ① P15.4 之前的老库
    /// ② 用户在外部编辑器改过（dream 的写入必经 App, 走不到这条路上）。
    /// 不补记, 这两版会在下一次覆盖时**静默消失**; 补了, 版本史才真正连续。
    ///
    /// - Note: 走 `SHA256` 而不是"最新一条的时间戳" —— 判据是**内容同一性**, 不是时间顺序
    ///   （同 `saveNote` 的乐观并发那条: 同一件事不该有两种指纹）。
    func noteRevisionExists(rootId: String, path: String, sha256: String) -> Bool {
        let rows = (try? db.query("""
            SELECT 1 FROM note_revisions WHERE root_id = ? AND path = ? AND sha256 = ? LIMIT 1
            """, [.text(rootId), .text(path), .text(sha256)])) ?? []
        return !rows.isEmpty
    }

    // MARK: - Note proposals (P15.3 dream 提案)

    /// 落一条提案。**只增** —— 提案一旦产出就不再变。
    ///
    /// ⚠️ **P15.8/5f 起本表是「待审队列」**: 拍过板的行（采纳 / 丢弃）会被**删掉**
    /// （`KnowledgeStore.removeProposal`）, 不再改写状态 ⇒ 这里恒写 `pending`。
    /// 两条终态写入路径连同 `setNoteProposalStatus` 已一并删除（生产者没了, API 就不留）。
    ///
    /// - Important: `sources` 编不出来时**直接抛**, 不写空串 —— 一个没有来源的提案
    ///   正是 §05 那条风险（"把没说过的话总结成事实"）唯一的结法所要挡的东西,
    ///   让它以降级形态进表等于把闸门拆了。
    func appendNoteProposal(_ p: NoteProposal) throws {
        // `sources` 是 `[ProposalSource]`（全 String 字段）⇒ 这个 `guard` 实际上从不触发。
        // 但**不能写成 `?? "[]"`** —— 那会让"没有来源的提案"在编码失败时悄悄成立,
        // 而它正是 §05 那条风险唯一的结法所要挡的东西（宁可整条不写, 不可降级写入）。
        guard let sourcesJSON = encodeJSON(p.sources) else {
            throw DatabaseError.bind("note_proposals.sources")
        }
        try db.run("""
            INSERT INTO note_proposals
                (id, root_id, kind, target_path, base_hash, title, content, reason,
                 sources, created_at, status, session_id, decided_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(p.id.uuidString), .text(p.rootId), .text(p.kind.rawValue),
                  .text(p.targetPath), .text(p.baseHash), .text(p.title), .text(p.content),
                  .text(p.reason), .text(sourcesJSON),
                  .real(p.createdAt.timeIntervalSince1970), .text(p.status.rawValue),
                  .text(p.sessionId),
                  // `decided_at` 列必须留着（DB 列只增不删）⇒ 恒落 NULL。
                  // P15.8/5f 起没有任何写入者: 拍过板的行直接删掉, 不再记"拍板时刻"。
                  .null])
    }

    /// 读提案。**表里恒只有 `pending`**（拍过板的行已删）⇒ 不需要状态过滤,
    /// 排序也就只剩"新的在前"（P15.4 那个 `CASE WHEN status = 'pending'` 随终态一起去掉）。
    func loadNoteProposals() throws -> [NoteProposal] {
        return try db.query("""
            SELECT id, root_id, kind, target_path, base_hash, title, content, reason,
                   sources, created_at, status, session_id
            FROM note_proposals
            ORDER BY created_at DESC
            """).compactMap { row in
            guard let id = UUID(uuidString: text(row, "id")),
                  let kind = NoteProposalKind(rawValue: text(row, "kind")),
                  let status = NoteProposalStatus(rawValue: text(row, "status")),
                  let sources = decodeJSON([ProposalSource].self, text(row, "sources")) else { return nil }
            return NoteProposal(
                id: id, rootId: text(row, "root_id"), kind: kind,
                targetPath: text(row, "target_path"), baseHash: text(row, "base_hash"),
                title: text(row, "title"), content: text(row, "content"),
                reason: text(row, "reason"), sources: sources,
                createdAt: Date(timeIntervalSince1970: double(row, "created_at")),
                status: status, sessionId: text(row, "session_id"))
        }
    }

    /// 删一条提案 —— 拍过板（采纳 / 丢弃）之后走这里。
    ///
    /// ⚠️ 删的**只是这一行提案**（一份"我想建议你改这里"的草稿）: 磁盘上的笔记、
    /// `note_revisions` 里的版本史都**不受影响** —— 采纳已经把内容写进笔记了,
    /// 丢弃本来就一个字节没写过。
    func deleteNoteProposal(id: UUID) throws {
        try db.run("DELETE FROM note_proposals WHERE id = ?", [.text(id.uuidString)])
    }

    // (P5.1 的 custom_models 读写 API 已于 2026-09-23 删除 —— 生产路径已无写入者。
    //  custom_models 表与 migrateLegacyCustomModels (本文件下方) 保留: 旧版本 MangoX 写的库
    //  仍需在启动时把行搬进 models 表, 且 DROP 表会让旧版本打开新库直接崩。)

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
            SELECT id, name, prompt, cron, project_id, enabled, last_run_at, log_session_id, continuous, condition, unattended, completed_at, run_count, created_at, config, kind, sources, notify, daily_token_budget, follow_ups_per_day,
                   role, parent_id, description, description_detail, delegate_per_day, disabled_by_parent
            FROM scheduled_tasks ORDER BY created_at DESC
            """)
        return rows.map { row in
            // P19 解码顺序: **先看 condition**, 再看 kind 缺省。
            // 反过来会让旧条件值守任务的「触发后动作」被当成普通 prompt 每轮无条件执行
            // （它当年靠 condition 判断要不要跑, 现在会每轮都跑）⇒ 静默变意。
            let cond = optionalText(row, "condition")
            let kind: TaskKind = (cond?.isEmpty == false)
                ? .legacyWaiting
                : (TaskKind(rawValue: optionalText(row, "kind") ?? "") ?? .execute)
            return ScheduledTask(
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
                    .flatMap { try? decoder.decode(SessionConfig.self, from: $0) },
                kind: kind,
                // 来源列表: 坏 JSON / NULL / 空串一律 → []。**不抛** —— 一条来源配置损坏
                // 不该让整个任务列表读不出来（那会连带 dream 任务一起消失）。
                sources: optionalText(row, "sources")
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? decoder.decode([WatchSourceSpec].self, from: $0) } ?? [],
                // P19 S7: 坏 JSON / NULL 一律回落**默认**（只发系统通知）——
                // 触达配置读不出来时"照旧发通知"比"整条任务读不出来"好得多。
                notify: optionalText(row, "notify")
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? decoder.decode(NotifyOptions.self, from: $0) } ?? .default,
                dailyTokenBudget: optionalInt(row, "daily_token_budget") ?? 0,
                // `nil` = 没配过（不是 0）—— 见 `ScheduledTask.followUpsPerDay` 的三态说明。
                followUpsPerDay: optionalInt(row, "follow_ups_per_day"),
                // P20: 角色**缺省恒 main**（列是 NOT NULL DEFAULT 'main'，这里的 decode 只是
                // 对"将来可能出现的第三态"表态，见 `TaskRole.decode`）。
                role: TaskRole.decode(optionalText(row, "role")),
                parentId: UUID(uuidString: text(row, "parent_id")),
                // 空串 = 没写（不是 NULL：两段都是 NOT NULL DEFAULT ''，少一层"空串还是 null"的分叉）。
                description: text(row, "description"),
                descriptionDetail: text(row, "description_detail"),
                delegatesPerDay: optionalInt(row, "delegate_per_day"),
                disabledByParent: int(row["disabled_by_parent"] ?? .null) == 1)
        }
    }

    func upsertScheduled(_ t: ScheduledTask) throws {
        let configJSON = t.config.flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        let sourcesJSON = t.sources.isEmpty
            ? nil
            : (try? encoder.encode(t.sources)).flatMap { String(data: $0, encoding: .utf8) }
        // 触达配置**恒写一份**（含"全默认"）：写 NULL 也行，但读侧就得靠"NULL = 默认"这条
        // 隐含规则来还原，而那是两个真源。恒写，读侧只需解码失败时兜底。
        let notifyJSON = (try? encoder.encode(t.notify))
            .flatMap { String(data: $0, encoding: .utf8) }
        // P19.2 S15b: `remote_chat_id` **不再写** —— 绑定在 `remote_bots.assistant_id` 上。
        // 列还在（旧版打开不崩），但 `INSERT OR REPLACE` 会整行重建 ⇒ 它自然落成 NULL。
        // 这是有意的: 两个真源里活的那一个在 `remote_bots`，留着旧列同步只会让两边有机会不一致。
        try db.run("""
            INSERT OR REPLACE INTO scheduled_tasks
            (id, name, prompt, cron, project_id, enabled, last_run_at, log_session_id, continuous, condition, unattended, completed_at, run_count, created_at, config, kind, sources, notify, daily_token_budget, follow_ups_per_day, role, parent_id, description, description_detail, delegate_per_day, disabled_by_parent)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
                  configJSON.map { .text($0) } ?? .null,
                  // P19: legacy 不落值 —— 它是 condition 派生出来的归档态, 写 NULL 让它下次照样派生。
                  t.isLegacyWaiting ? .null : .text(t.kind.rawValue),
                  sourcesJSON.map { .text($0) } ?? .null,
                  notifyJSON.map { .text($0) } ?? .null,
                  .int(Int64(max(0, t.dailyTokenBudget))),
                  // nil 写 NULL（= 没配过），0 写 0（= 人关掉了）—— 这一列的三态全靠它。
                  t.followUpsPerDay.map { .int(Int64(max(0, $0))) } ?? .null,
                  // P20: 角色 / 归属 / 两段职责 / 派活配额 / 跟随停用标记。
                  // `role` 恒写实值（不写 NULL）: 列是 NOT NULL，而"没有角色"这件事由 `.main` 表达。
                  .text(t.role.rawValue),
                  t.parentId.map { .text($0.uuidString) } ?? .null,
                  // 两段都**恒写实值**（空串也写）: 读侧只需 "空串 = 没写"，不必再分 NULL 与 ''。
                  .text(t.description),
                  .text(t.descriptionDetail),
                  t.delegatesPerDay.map { .int(Int64(max(0, $0))) } ?? .null,
                  .int(t.disabledByParent ? 1 : 0)])
    }

    // MARK: - P19 S7 日 token 账本

    /// 某任务某天已用的 token 数。没有行 = 0。
    func tokenUsage(taskId: UUID, day: String) throws -> Int {
        let rows = try db.query(
            "SELECT tokens FROM agent_token_daily WHERE task_id = ? AND day = ?",
            [.text(taskId.uuidString), .text(day)])
        guard let row = rows.first else { return 0 }
        return Int(int(row["tokens"] ?? .null))
    }

    /// 累加一笔。**累加而不是覆盖** —— 一天里会有很多次 fire，覆盖等于只记得最后一次。
    func addTokenUsage(taskId: UUID, day: String, tokens: Int) throws {
        guard tokens > 0 else { return }
        try db.run("""
            INSERT INTO agent_token_daily (task_id, day, tokens) VALUES (?,?,?)
            ON CONFLICT(task_id, day) DO UPDATE SET tokens = tokens + excluded.tokens
            """, [.text(taskId.uuidString), .text(day), .int(Int64(tokens))])
    }

    // MARK: - follow-up（agent 给自己约定时器, 2026-11-23）

    /// 读约定。两个收窄参数都只是往 WHERE 里加条件（同 `loadFindings` 的理由：读全量再在内存里
    /// filter 与它逐行等价，但多解一遍别的任务的行）。**按 `due_at` 升序** —— 早该叫的先叫。
    func loadFollowUps(taskId: UUID? = nil, status: FollowUpStatus? = nil) throws -> [FollowUp] {
        var where_: [String] = []
        var args: [DBValue] = []
        if let taskId { where_.append("task_id = ?"); args.append(.text(taskId.uuidString)) }
        if let status { where_.append("status = ?"); args.append(.text(status.rawValue)) }
        let filter = where_.isEmpty ? "" : " WHERE " + where_.joined(separator: " AND ")
        let rows = try db.query("""
            SELECT id, task_id, due_at, why, status, attempts, created_at, fired_at, note, kind
            FROM agent_followups\(filter) ORDER BY due_at ASC
            """, args)
        return rows.compactMap(decodeFollowUp)
    }

    /// tick 要的那一批：`pending` 且已到点。
    func dueFollowUps(now: Date) throws -> [FollowUp] {
        let rows = try db.query("""
            SELECT id, task_id, due_at, why, status, attempts, created_at, fired_at, note, kind
            FROM agent_followups WHERE status = 'pending' AND due_at <= ? ORDER BY due_at ASC
            """, [.real(now.timeIntervalSince1970)])
        return rows.compactMap(decodeFollowUp)
    }

    /// 行的解码口径 —— **只有这份**（上两个读法都走它，加列只改一处）。
    ///
    /// 坏行**跳过而不是抛**（同 `loadFindings`）：一行解不出来不该让整个调度停摆。
    /// 未知 `status` ⇒ 也丢：它既不该被 tick 叫起来，也不该在界面上冒充"还在等"。
    private func decodeFollowUp(_ row: [String: DBValue]) -> FollowUp? {
        guard let id = UUID(uuidString: text(row, "id")),
              let taskId = UUID(uuidString: text(row, "task_id")),
              let status = FollowUpStatus.decode(optionalText(row, "status") ?? "")
        else { return nil }
        return FollowUp(id: id,
                        taskId: taskId,
                        dueAt: optionalDate(row, "due_at") ?? .distantPast,
                        why: text(row, "why"),
                        status: status,
                        attempts: Int(max(Int64(0), int(row["attempts"] ?? .null))),
                        createdAt: optionalDate(row, "created_at") ?? .distantPast,
                        firedAt: optionalDate(row, "fired_at"),
                        note: optionalText(row, "note"),
                        // 未知值回落 `selfWake`（占配额的那一侧）: 宁可多算一次配额，
                        // 也不要把一条来路不明的唤醒当成"App 自己插的"从而少算。
                        kind: FollowUpKind.decode(optionalText(row, "kind") ?? ""))
    }

    /// 这个任务还欠着几条（`FollowUpLimit.maxPendingPerTask` 那条闸）。
    func pendingFollowUpCount(taskId: UUID) throws -> Int {
        let rows = try db.query(
            "SELECT COUNT(*) AS n FROM agent_followups WHERE task_id = ? AND status = 'pending'",
            [.text(taskId.uuidString)])
        guard let row = rows.first else { return 0 }
        return Int(int(row["n"] ?? .null))
    }

    /// 这个任务在 `since` 之后**约了几条**（配额闸用；口径 = `created_at`，不是"跑了几轮"）。
    ///
    /// ⚠️ 为什么是 `created_at` 而不是 `fired_at`: 要拦的是"它约得太勤"，而"跑了几轮"会被
    /// **重试顺延**带偏（一次约定被闸挡三次就记成三轮，配额凭空少一天的量）。
    /// 取消/重排也算 —— 改主意本身也吵。
    func followUpCountSince(taskId: UUID, since: Date) throws -> Int {
        // ⚠️ `kind = 'self'` 是**配额口径的一半**（P20）: 这条数的是"人给它的额度用掉了多少"，
        // 而 worker 交活回叫是 App 插的 —— 算进去等于一个带 5 个 worker 的 main 一天就把
        // 自己的回看配额耗光，而人会说"我没约过这么多次"。
        let rows = try db.query("""
            SELECT COUNT(*) AS n FROM agent_followups
            WHERE task_id = ? AND created_at >= ? AND kind = 'self'
            """, [.text(taskId.uuidString), .real(since.timeIntervalSince1970)])
        guard let row = rows.first else { return 0 }
        return Int(int(row["n"] ?? .null))
    }

    /// 插一条。`id` 就是幂等键（扩展侧的 nonce）⇒ `INSERT OR IGNORE`。
    ///
    /// 返回是否**真插进去**（`false` = 这条已经在了）。收口那条路径"先落库、再删 spool"，
    /// 万一崩在中间，下一次 ingest 会读到同一行 —— 靠主键撞掉它，而不是靠调用方记得去重。
    @discardableResult
    func insertFollowUpIfAbsent(_ f: FollowUp) throws -> Bool {
        // ⚠️ `Database` 只暴露 `run` / `query`，没有 `sqlite3_changes` ⇒ "插进去了没有"这件事
        // 用一次**主键查询**来判。比 `COUNT(*)` 前后各数一遍便宜，口径也更窄（只问这一条）。
        let exists = try db.query("SELECT 1 FROM agent_followups WHERE id = ? LIMIT 1",
                                  [.text(f.id.uuidString)]).isEmpty == false
        guard !exists else { return false }
        try db.run("""
            INSERT OR IGNORE INTO agent_followups
            (id, task_id, due_at, why, status, attempts, created_at, fired_at, note, kind)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [.text(f.id.uuidString),
                  .text(f.taskId.uuidString),
                  .real(f.dueAt.timeIntervalSince1970),
                  .text(f.why),
                  .text(f.status.rawValue),
                  .int(Int64(f.attempts)),
                  .real(f.createdAt.timeIntervalSince1970),
                  f.firedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                  f.note.map { .text($0) } ?? .null,
                  .text(f.kind.rawValue)])
        return true
    }

    /// 落定一条：`fired` / `cancelled` / `missed` 都走这里。
    ///
    /// `firedAt` 只在**真的起来过**时给值；`cancelled` 给 nil —— 那一列是"叫过没有"的证据，
    /// 一条被作废的约定**没有**叫过任何人，给它写个时刻等于伪造证据。
    func settleFollowUp(id: UUID, status: FollowUpStatus, firedAt: Date?, note: String?) throws {
        try db.run("UPDATE agent_followups SET status = ?, fired_at = ?, note = ? WHERE id = ?",
                   [.text(status.rawValue),
                    firedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    note.map { .text($0) } ?? .null,
                    .text(id.uuidString)])
    }

    /// 重排一条（起来被闸挡了，但约定还没作废）：只动 `due_at` / `attempts` / `note`。
    /// `status` 保持 `pending` —— 一旦标成 `missed` 它就不该再被 tick 捡起来。
    func rearmFollowUp(id: UUID, dueAt: Date, attempts: Int, note: String?) throws {
        try db.run("UPDATE agent_followups SET due_at = ?, attempts = ?, note = ? WHERE id = ?",
                   [.real(dueAt.timeIntervalSince1970),
                    .int(Int64(attempts)),
                    note.map { .text($0) } ?? .null,
                    .text(id.uuidString)])
    }

    // MARK: - 派活单（P20 agent_delegations, 2026-11-24）

    /// 读派活单。三个收窄参数都只是往 WHERE 里加条件 —— 语义与"读全量再在内存里 filter"
    /// 逐行等价，但少解一遍别人的单子（同 `loadFollowUps` / `loadFindings` 的理由）。
    /// **按 `due_at` 升序**: 早该起的排前面，画板与回执都按时间读。
    func loadDelegations(fromTask: UUID? = nil, toTask: UUID? = nil,
                         status: DelegationStatus? = nil) throws -> [Delegation] {
        var where_: [String] = []
        var args: [DBValue] = []
        if let fromTask { where_.append("from_task = ?"); args.append(.text(fromTask.uuidString)) }
        if let toTask { where_.append("to_task = ?"); args.append(.text(toTask.uuidString)) }
        if let status { where_.append("status = ?"); args.append(.text(status.rawValue)) }
        let filter = where_.isEmpty ? "" : " WHERE " + where_.joined(separator: " AND ")
        let rows = try db.query("""
            SELECT id, from_task, to_task, goal, acceptance, context, due_at, due_by, status,
                   attempts, note, summary, reported_at, created_at, started_at, finished_at
            FROM agent_delegations\(filter) ORDER BY due_at ASC
            """, args)
        return rows.compactMap(decodeDelegation)
    }

    /// tick 要的那一批：`queued` 且已到点。
    func dueDelegations(now: Date) throws -> [Delegation] {
        let rows = try db.query("""
            SELECT id, from_task, to_task, goal, acceptance, context, due_at, due_by, status,
                   attempts, note, summary, reported_at, created_at, started_at, finished_at
            FROM agent_delegations WHERE status = 'queued' AND due_at <= ? ORDER BY due_at ASC
            """, [.real(now.timeIntervalSince1970)])
        return rows.compactMap(decodeDelegation)
    }

    /// "它手上有没有活" —— 只看**未落定**的两种，不看历史条数。
    ///
    /// ⚠️ 派活前那道硬拒读的是这个，不是 `COUNT(*) > 0`: 一个交过活、又被重新派了一单的
    /// worker 在历史上有很多行，但"手上有没有活"是 0 或 1 的瞬时事实。
    /// `to == nil` = **全体**未落定的（派活前那一批要一次拿全，别按 worker 查 N 次）。
    func openDelegations(to taskId: UUID? = nil) throws -> [Delegation] {
        let filter = taskId == nil ? "" : " AND to_task = ?"
        let sql = """
            SELECT id, from_task, to_task, goal, acceptance, context, due_at, due_by, status,
                   attempts, note, summary, reported_at, created_at, started_at, finished_at
            FROM agent_delegations WHERE status IN ('queued', 'running')
            """ + filter + " ORDER BY due_at ASC"
        return try db.query(sql, taskId.map { [.text($0.uuidString)] } ?? [])
            .compactMap(decodeDelegation)
    }

    /// 【派活回执】要念的那一批: **已落定、但还没汇报过**的单子，最近 `limit` 条。
    ///
    /// 判据是 `reported_at IS NULL`，不是另存一个"待念队列" —— 那一行本身就是待汇报状态，
    /// 再存一份就是第二真源（而两份一定会先漂一份）。`reported_at` 只在 main 那一轮
    /// **成功收尾**之后才标（见 `SchedulerService.markReceiptsReported`）。
    ///
    /// 按 `finished_at` 降序: 人最想知道的是"刚才那件事怎么样了"。`finished_at` 为 NULL 的
    /// 老行（理论上不会有）用 `due_at` 兜底排序。
    func unreportedDelegations(from taskId: UUID, limit: Int) throws -> [Delegation] {
        let rows = try db.query("""
            SELECT id, from_task, to_task, goal, acceptance, context, due_at, due_by, status,
                   attempts, note, summary, reported_at, created_at, started_at, finished_at
            FROM agent_delegations
            WHERE from_task = ? AND reported_at IS NULL
              AND status IN ('done', 'failed', 'cancelled')
            ORDER BY COALESCE(finished_at, due_at) DESC LIMIT ?
            """, [.text(taskId.uuidString), .int(Int64(max(1, limit)))])
        return rows.compactMap(decodeDelegation)
    }

    /// 行的解码口径 —— **只有这份**（上面几个读法都走它，加列只改一处）。
    /// 坏行 / 未知 `status` **跳过而不是抛**（同 `decodeFollowUp`）。
    private func decodeDelegation(_ row: [String: DBValue]) -> Delegation? {
        guard let id = UUID(uuidString: text(row, "id")),
              let from = UUID(uuidString: text(row, "from_task")),
              let to = UUID(uuidString: text(row, "to_task")),
              let status = DelegationStatus.decode(optionalText(row, "status") ?? "")
        else { return nil }
        return Delegation(id: id,
                          fromTask: from,
                          toTask: to,
                          goal: text(row, "goal"),
                          acceptance: text(row, "acceptance"),
                          context: optionalText(row, "context"),
                          dueAt: optionalDate(row, "due_at") ?? .distantPast,
                          dueBy: optionalDate(row, "due_by"),
                          status: status,
                          attempts: Int(max(Int64(0), int(row["attempts"] ?? .null))),
                          note: optionalText(row, "note"),
                          summary: optionalText(row, "summary"),
                          reportedAt: optionalDate(row, "reported_at"),
                          createdAt: optionalDate(row, "created_at") ?? .distantPast,
                          startedAt: optionalDate(row, "started_at"),
                          finishedAt: optionalDate(row, "finished_at"))
    }

    /// 插一张单。`id` 是幂等键（回执要靠它对上具体那一条）⇒ `INSERT OR REPLACE`。
    ///
    /// ⚠️ **四个长文本在这里再截一次**。这不是主要手段（P2 的工具入参该拒的还在拒，且会
    /// 报实际字数），而是最后一道围栏: 这一列的内容会**逐字进 worker 的 prompt 与 main 的回执**,
    /// 没有上限就是一个没有围栏的注入面。放在存储层是因为它是唯一一个"所有写路径都必经"的点。
    func insertDelegation(_ d: Delegation) throws {
        try db.run("""
            INSERT OR REPLACE INTO agent_delegations
            (id, from_task, to_task, goal, acceptance, context, due_at, due_by, status,
             attempts, note, summary, reported_at, created_at, started_at, finished_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(d.id.uuidString),
                  .text(d.fromTask.uuidString),
                  .text(d.toTask.uuidString),
                  .text(DelegationLimit.clip(d.goal, DelegationLimit.maxGoalChars)),
                  .text(DelegationLimit.clip(d.acceptance, DelegationLimit.maxAcceptanceChars)),
                  d.context.map {
                      .text(DelegationLimit.clip($0, DelegationLimit.maxContextChars))
                  } ?? .null,
                  .real(d.dueAt.timeIntervalSince1970),
                  d.dueBy.map { .real($0.timeIntervalSince1970) } ?? .null,
                  .text(d.status.rawValue),
                  .int(Int64(max(0, d.attempts))),
                  d.note.map { .text($0) } ?? .null,
                  d.summary.map { .text(DelegationLimit.clip($0, DelegationLimit.maxSummaryChars)) } ?? .null,
                  d.reportedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                  .real(d.createdAt.timeIntervalSince1970),
                  d.startedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                  d.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null])
    }

    /// 起跑: `queued` → `running`，只写 `started_at`。**不动 `finished_at`**。
    func startDelegation(id: UUID, at: Date) throws {
        try db.run("UPDATE agent_delegations SET status = 'running', started_at = ? WHERE id = ?",
                   [.real(at.timeIntervalSince1970), .text(id.uuidString)])
    }

    /// 落定: `done` / `failed` / `cancelled` 都走这里（`finished_at` 一并写）。
    ///
    /// `summary` / `note` 传 `nil` = **清空**（同 `settleFollowUp`）—— 落定只发生一次，
    /// 所以不存在"想保留上一次那句"的场景；反过来，含糊成"nil 表示不动"会让
    /// "为什么这条回执没有结论"变成猜的。
    ///
    /// ⚠️ **不清 `reported_at`**: 一条已经汇报过的单子被改成 cancelled（比如 main 后来删了），
    /// 清掉它会让 main 再被念一遍同一件事 —— 而人已经在上一轮看过那条回执了。
    func settleDelegation(id: UUID, status: DelegationStatus,
                          summary: String?, note: String?, at: Date) throws {
        try db.run("""
            UPDATE agent_delegations SET status = ?, summary = ?, note = ?, finished_at = ?
            WHERE id = ?
            """, [.text(status.rawValue),
                  summary.map { .text(DelegationLimit.clip($0, DelegationLimit.maxSummaryChars)) } ?? .null,
                  note.map { .text($0) } ?? .null,
                  .real(at.timeIntervalSince1970),
                  .text(id.uuidString)])
    }

    /// 顺延（起跑被闸挡住，单子还没作废）：只动 `due_at` / `attempts` / `note`。
    /// `status` 保持 `queued` —— 它仍然"该起"，只是这一跳轮不到它。
    func rearmDelegation(id: UUID, dueAt: Date, attempts: Int, note: String?) throws {
        try db.run("""
            UPDATE agent_delegations SET due_at = ?, attempts = ?, note = ? WHERE id = ?
            """, [.real(dueAt.timeIntervalSince1970),
                  .int(Int64(max(0, attempts))),
                  note.map { .text($0) } ?? .null,
                  .text(id.uuidString)])
    }

    /// 回执消化掉了。**只在 main 那一轮成功收尾之后调** —— 标在"注入时"会让崩掉的那一轮
    /// 永久丢回执（同 `settleSent` 的哲学：唯一诚实的位置是"真的消化完了"）。
    func markDelegationReported(id: UUID, at: Date) throws {
        try db.run("UPDATE agent_delegations SET reported_at = ? WHERE id = ?",
                   [.real(at.timeIntervalSince1970), .text(id.uuidString)])
    }

    /// 这个 main 在 `since` 之后派了几张单（每日配额闸）。
    ///
    /// ⚠️ 口径 = `created_at`，不是"跑了几轮": 要拦的是"派得太勤"，而"跑了几轮"会被
    /// **顺延**带偏（一张单被闸挡三次就记成三张，配额凭空少一天的量）。取消/改期也算。
    func delegationCount(from taskId: UUID, since: Date) throws -> Int {
        let rows = try db.query("""
            SELECT COUNT(*) AS n FROM agent_delegations WHERE from_task = ? AND created_at >= ?
            """, [.text(taskId.uuidString), .real(since.timeIntervalSince1970)])
        guard let row = rows.first else { return 0 }
        return Int(int(row["n"] ?? .null))
    }

    /// 连带作废：某个 main 派出去、或某个 worker 名下**还没落定**的单子。
    ///
    /// ⚠️ **行不删、只落终态**（与 `deleteScheduled` 里 follow-up 那条"清掉"相反）。
    /// 理由是回执: 一条 `cancelled` 且 `reported_at` 仍为 NULL 的单子，正好是 P3 那段
    /// 【派活回执】要念给 main 的"这个活没了" —— 删掉行，那条回执就永远到不了。
    /// 代价（明写）: 行会随时间堆，保留期属于产品决定，将来要加时按 `agent_findings` 同款处理。
    ///
    /// 返回作废了几条（冒烟与日志要能说"影响面有多大"）。
    @discardableResult
    func cancelOpenDelegations(from taskId: UUID? = nil, to: UUID? = nil,
                               note: String, at: Date) throws -> Int {
        precondition(taskId != nil || to != nil, "cancelOpenDelegations 至少给一个方向")
        var where_: [String] = ["status IN ('queued', 'running')"]
        var whereArgs: [DBValue] = []
        if let taskId { where_.append("from_task = ?"); whereArgs.append(.text(taskId.uuidString)) }
        if let to { where_.append("to_task = ?"); whereArgs.append(.text(to.uuidString)) }
        let clause = where_.joined(separator: " AND ")
        // `Database` 只暴露 run / query（没有 sqlite3_changes）⇒ "影响了几条"用一次 COUNT 来报。
        let rows = try db.query("SELECT COUNT(*) AS n FROM agent_delegations WHERE " + clause, whereArgs)
        let n = Int(int(rows.first?["n"] ?? .null))
        guard n > 0 else { return 0 }
        try db.run("""
            UPDATE agent_delegations SET status = 'cancelled', note = ?, finished_at = ?
            WHERE \(clause)
            """, [.text(note), .real(at.timeIntervalSince1970)] + whereArgs)
        return n
    }

    // MARK: - 已发消息（助理往外发过的话, 2026-11-23）

    /// 记一条"要发"。**先落库再交给桥**: 顺序反过来的话，桥一崩就什么都没留下
    /// —— 而"我以为我说过、其实一个字都没出去"正是这个功能要消灭的那件事。
    func insertSent(_ s: SentMessage) throws {
        try db.run("""
            INSERT OR REPLACE INTO agent_sent
            (id, task_id, session_id, at, kind, status, text, note)
            VALUES (?,?,?,?,?,?,?,?)
            """, [.text(s.id.uuidString),
                  .text(s.taskId.uuidString),
                  s.sessionId.map { .text($0.uuidString) } ?? .null,
                  .real(s.at.timeIntervalSince1970),
                  .text(s.kind.rawValue),
                  .text(s.status.rawValue),
                  .text(String(s.text.prefix(SentLimit.maxTextChars))),
                  s.note.map { .text($0) } ?? .null])
    }

    /// 回执到了：把 `queued` 落成 `sent` / `failed`。`ref` 就是行的主键。
    ///
    /// ⚠️ 找不到这一行（旧版写的 `ref`、或者桥把别人的 ref 还回来）⇒ **静默不动**：
    /// 一条对不上的回执不该改任何一条记录，那会让"发没发出去"变成猜的。
    func settleSent(id: UUID, status: SentStatus, note: String?) throws {
        guard status != .queued else { return }
        try db.run("UPDATE agent_sent SET status = ?, note = ? WHERE id = ? AND status = 'queued'",
                   [.text(status.rawValue),
                    note.map { .text($0) } ?? .null,
                    .text(id.uuidString)])
    }

    /// 这个任务最近发过的几条（新的在前）。
    ///
    /// `onlySent = true` ⇒ 只要 `sent`（注入段用：那是模型唯一该当成事实的一档）。
    /// 默认 **全都要**（含 `queued` / `failed`）—— 存储层不替产品做"哪些该显示"的决定，
    /// 那两处（注入 / 预览卡）各自有各自的取舍。
    func loadSent(taskId: UUID, limit: Int, onlySent: Bool = false) throws -> [SentMessage] {
        let extra = onlySent ? " AND status = 'sent'" : ""
        let rows = try db.query("""
            SELECT id, task_id, session_id, at, kind, status, text, note
            FROM agent_sent WHERE task_id = ?\(extra) ORDER BY at DESC LIMIT ?
            """, [.text(taskId.uuidString), .int(Int64(max(0, limit)))])
        return rows.compactMap(decodeSent)
    }

    /// 行的解码口径 —— **只有这份**。坏行跳过而不是抛（同 `decodeFollowUp`）。
    private func decodeSent(_ row: [String: DBValue]) -> SentMessage? {
        guard let id = UUID(uuidString: text(row, "id")),
              let taskId = UUID(uuidString: text(row, "task_id")),
              let kind = SentKind(rawValue: text(row, "kind")),
              let status = SentStatus.decode(text(row, "status"))
        else { return nil }
        return SentMessage(id: id,
                           taskId: taskId,
                           sessionId: optionalText(row, "session_id").flatMap { UUID(uuidString: $0) },
                           at: optionalDate(row, "at") ?? .distantPast,
                           kind: kind,
                           status: status,
                           text: text(row, "text"),
                           note: optionalText(row, "note"))
    }

    /// 只留最近 `SentLimit.keepPerTask` 条。**在插入之后立刻做**（每次发送只有一次 DELETE），
    /// 不做定期任务：没有第二个时点，也就没有"定时器忘了跑"这种失效模式。
    func pruneSent(taskId: UUID, keep: Int = SentLimit.keepPerTask) throws {
        try db.run("""
            DELETE FROM agent_sent WHERE task_id = ? AND id NOT IN (
                SELECT id FROM agent_sent WHERE task_id = ? ORDER BY at DESC LIMIT ?
            )
            """, [.text(taskId.uuidString), .text(taskId.uuidString), .int(Int64(max(0, keep)))])
    }

    /// 删任务 —— **连同它的数据**。返回被删 findings 的执行快照目录（供上层删盘）。
    /// ⚠️ 2026-11-18 之前这里只删一行 `scheduled_tasks`。三张带 `task_id` 的表
    /// （`agent_findings` / `agent_finding_actions` / `agent_token_daily`）于是留下**悬空外键**：
    /// 实测这一台机器上，删掉两个助理之后 `agent_token_daily` 里还有 2 条账挂着已经不存在的
    /// `task_id`，收件箱里的结论也会显示成「未知任务」。它们不报错，只会在哪天有人统计
    /// "这个助理花了多少 / 它提过什么" 时给出**假数**。
    ///
    /// **回收判据必须与「谁真持有这些东西」同源**：`task_id` 就是持有者，
    /// 所以删除半径 = 所有 `WHERE task_id = ?` 的表；少认一张就等于把垃圾留在库里。
    /// ⚠️ 这张名单**每次加一张带 `task_id` 的表都要回来补一行**（2026-11-23 加了
    /// `agent_followups` 与 `agent_sent`）——
    /// 它就是"谁真持有"的账本本身，漏记的样子是垃圾而不是报错。
    ///
    /// ⚠️ `agent_finding_actions` 的外键是 `finding_id` 而不是 `task_id` —— 它必须**先**删，
    /// 否则子查询那一步已经把 findings 删了，actions 就再也找不到自己的父行。
    ///
    /// ⚠️ 快照目录（`~/.mangox/undo/<findingId>/`）只能**先查后删**：删完 findings 就查不到
    /// 那些路径了，盘上留下永远没人认领的 tar。DB 层不碰文件系统，所以它只负责把路径带出来。
    @discardableResult
    func deleteScheduled(id: UUID) throws -> [String] {
        let tid = DBValue.text(id.uuidString)
        let undos = try db.query(
            "SELECT undo_path FROM agent_findings WHERE task_id = ? AND undo_path IS NOT NULL",
            [tid]).compactMap { optionalText($0, "undo_path") }
        try db.run("""
            DELETE FROM agent_finding_actions
            WHERE finding_id IN (SELECT id FROM agent_findings WHERE task_id = ?)
            """, [tid])
        try db.run("DELETE FROM agent_findings WHERE task_id = ?", [tid])
        try db.run("DELETE FROM agent_token_daily WHERE task_id = ?", [tid])
        // 2026-11-23: 未兑现的约定跟着任务一起走。留着它的下场是 tick 每一分钟都扫到一条指向
        // 不存在任务的 `pending` ⇒ 每次判"任务已删除"再标 cancelled（几十次之后才安静）。
        try db.run("DELETE FROM agent_followups WHERE task_id = ?", [tid])
        // 2026-11-23:「已发消息」也跟着走。留着它的样子是"任务列表里没有这个助理了，
        // 但库里还有 200 条它说过的话" —— 而那个任务再也不会说话了。
        try db.run("DELETE FROM agent_sent WHERE task_id = ?", [tid])
        try db.run("DELETE FROM scheduled_tasks WHERE id = ?", [tid])
        return undos
    }

    // MARK: - 助理结论 (P19 findings)

    /// 读结论。两个**收窄参数**都只是往 WHERE 里加条件，语义与"读全量再在内存里 filter"逐行等价。
    ///
    /// ⚠️ 为什么要给参数（2026-11-18 review）：收尾那一轮只要**同一个任务**的旧行做指纹去重，
    /// 崩溃自愈那一处只要 `status == running` 的几行 —— 而它们原来都走全量解码
    /// （`body` / `evidence` / `plan` 三段 JSON 逐行解）。按天巡检跑一年是上千行，
    /// 每轮把这上千行解一遍只为挑出 3 行，是纯白烧。**不加归档/删除**：保留期是产品决定，
    /// 而"只读需要的行"不是。
    func loadFindings(taskId: UUID? = nil, status: FindingStatus? = nil) throws -> [AgentFinding] {
        var where_: [String] = []
        var args: [DBValue] = []
        if let taskId { where_.append("task_id = ?"); args.append(.text(taskId.uuidString)) }
        if let status { where_.append("status = ?"); args.append(.text(status.rawValue)) }
        let filter = where_.isEmpty ? "" : " WHERE " + where_.joined(separator: " AND ")
        let rows = try db.query("""
            SELECT id, task_id, source_id, session_id, title, body, evidence, plan, plan_rev,
                   severity, fingerprint, status, undo_path, tokens, cost_usd, created_at, decided_at,
                   nag_count, last_nagged_at
            FROM agent_findings\(filter) ORDER BY created_at DESC
            """, args)
        return rows.compactMap { row in
            // 坏行**跳过而不是抛**: 一行 JSON 坏了不该让整个收件箱读不出来
            // （同 `scheduled_tasks.sources` 那条）。
            guard let id = UUID(uuidString: text(row, "id")),
                  let taskId = UUID(uuidString: text(row, "task_id")),
                  let sourceId = UUID(uuidString: text(row, "source_id")),
                  // 未知 status ⇒ 解成 nil ⇒ 整行丢掉: 它既不该进收件箱也不该放行执行,
                  // 而"猜一个 open"会让一条本该被忽略的旧结论重新冒出来叫人。
                  let status = FindingStatus.decode(optionalText(row, "status") ?? "") else { return nil }
            let plan = optionalText(row, "plan")
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode([WatchPlanStep].self, from: $0) } ?? []
            return AgentFinding(
                id: id, taskId: taskId, sourceId: sourceId,
                sessionId: UUID(uuidString: text(row, "session_id")) ?? UUID(),
                title: text(row, "title"), body: text(row, "body"),
                evidence: optionalText(row, "evidence"), plan: plan,
                planRev: Int(int(row["plan_rev"] ?? .null)),
                severity: text(row, "severity"),
                fingerprint: text(row, "fingerprint"), status: status,
                nagCount: Int(int(row["nag_count"] ?? .null)),
                lastNaggedAt: optionalDate(row, "last_nagged_at"),
                undoPath: optionalText(row, "undo_path"),
                tokens: optionalText(row, "tokens").flatMap { Int($0) },
                costUSD: optionalText(row, "cost_usd").flatMap { Double($0) },
                createdAt: optionalDate(row, "created_at") ?? .distantPast,
                decidedAt: optionalDate(row, "decided_at"))
        }
    }

    func upsertFinding(_ f: AgentFinding) throws {
        let planJSON = f.plan.isEmpty
            ? nil
            : (try? encoder.encode(f.plan)).flatMap { String(data: $0, encoding: .utf8) }
        try db.run("""
            INSERT OR REPLACE INTO agent_findings
            (id, task_id, source_id, session_id, title, body, evidence, plan, plan_rev,
             severity, fingerprint, status, undo_path, tokens, cost_usd, created_at, decided_at,
             nag_count, last_nagged_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(f.id.uuidString),
                  .text(f.taskId.uuidString),
                  .text(f.sourceId.uuidString),
                  .text(f.sessionId.uuidString),
                  .text(f.title),
                  .text(f.body),
                  f.evidence.map { .text($0) } ?? .null,
                  planJSON.map { .text($0) } ?? .null,
                  .int(Int64(f.planRev)),
                  .text(f.severity),
                  .text(f.fingerprint),
                  .text(f.status.rawValue),
                  f.undoPath.map { .text($0) } ?? .null,
                  f.tokens.map { .int(Int64($0)) } ?? .null,
                  f.costUSD.map { .real($0) } ?? .null,
                  .real(f.createdAt.timeIntervalSince1970),
                  f.decidedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                  .int(Int64(f.nagCount)),
                  f.lastNaggedAt.map { .real($0.timeIntervalSince1970) } ?? .null])
    }

    /// 只改状态（忽略 / 采纳 / 执行回写都走这里）。`decided_at` 只在**人拍板**时给值。
    func setFindingStatus(id: UUID, status: FindingStatus, at: Date?) throws {
        try db.run("UPDATE agent_findings SET status = ?, decided_at = ? WHERE id = ?",
                   [.text(status.rawValue),
                    at.map { .real($0.timeIntervalSince1970) } ?? .null,
                    .text(id.uuidString)])
    }

    // MARK: - 执行落痕 (P19 S6)

    func loadFindingActions() throws -> [FindingAction] {
        let rows = try db.query("""
            SELECT finding_id, step, kind, target, result, output, at
            FROM agent_finding_actions ORDER BY finding_id ASC, step ASC
            """)
        return rows.compactMap { row in
            guard let fid = UUID(uuidString: text(row, "finding_id")) else { return nil }
            return FindingAction(findingId: fid,
                                 step: Int(int(row["step"] ?? .null)),
                                 kind: text(row, "kind"),
                                 target: optionalText(row, "target"),
                                 result: text(row, "result"),
                                 output: optionalText(row, "output"),
                                 at: optionalDate(row, "at") ?? .distantPast)
        }
    }

    /// 一行 = 一个步骤号（主键 `(finding_id, step)`）⇒ 同一步再落痕就是**覆盖**。
    func upsertFindingAction(_ a: FindingAction) throws {
        try db.run("""
            INSERT OR REPLACE INTO agent_finding_actions
            (finding_id, step, kind, target, result, output, at)
            VALUES (?,?,?,?,?,?,?)
            """, [.text(a.findingId.uuidString),
                  .int(Int64(a.step)),
                  .text(a.kind),
                  a.target.map { .text($0) } ?? .null,
                  .text(a.result),
                  a.output.map { .text($0) } ?? .null,
                  .real(a.at.timeIntervalSince1970)])
    }

    // MARK: - 邮箱账号池 (P19: 只剩账号; 哨兵 / 线程 / 拒收三表已随收件档删除)
    // 本表只存连接参数; 授权码在 Keychain (MailboxCredentialStore)。
    // P19 现状: 消费者 = S7 的邮件 sink（设置 → 集成 → 邮箱账号）与 P19.1 的邮件通道。

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
