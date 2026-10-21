# P6 功能设计：状态显示 + Trace v2 + 侧问/回顾（roadmap 第 0-3 批）

> 2026-09-14 立项（`docs/merged-roadmap-2026-09-14.md` 定稿 v4 当日）。今日目标 = **第 0-3 批**：
> P6.0 缺陷修复（0.5 天）→ P6.1 状态显示强化（1.5 天）→ P6.2 Trace v2（2 天）→ P6.3 Side chat + Away summary（1-1.5 天）。
> 门禁传统不变：`bash scripts/smoke/run.sh` 全过 + 真机操作验证；每阶段门禁确认后进下一阶段。
> 依据索引统一见 roadmap 附录，本文不重复论证，只写设计与拍板。

---

## 0. 架构事实（2026-09-14 pi 0.85.1 实测，判断的前提）

1. **pi 事件契约 21 类，MangoX 只接 8 类；9 种流式 delta 只用 2 种**。最关键语义差：
   `agent_end` = 一次底层 run 结束（`willRetry:true` 时后面还有重试/压缩重试/排队后续），
   **`agent_settled` = 彻底落定**（`docs/rpc.md:885-911`）。
2. **`get_session_stats` 一条命令给全状态栏指标**：tokens 四路、**cost（pi 按模型单价含 tiers 算好，USD）**、
   `contextUsage{tokens,contextWindow,percent}`、消息/工具计数。它是**命令不是事件**——落定后主动拉，
   不能每 chunk 拉（`docs/rpc.md:554-596`）。
3. **`message_update` 顶层带累计 `usage`**——流式中 token/成本实时跳字的数据源，现在被丢弃。
4. **非审批类扩展 UI 请求是 fire-and-forget**（`notify`/`setStatus`/`setWidget`/`setTitle`，不应回 response）；
   MangoX 现在对它们无脑回 `"Allow"` 且 `notify` 内容被静默丢弃。
5. **`fork`/`clone`（按 entryId 分叉，原路径保留）+ CLI `--fork`** 原生可用；Side chat 的引擎侧语义免费。
6. **per-turn 进程架构**（`spawnProcess` 每回合拉起、落定即拆）= spawn 参数天然扩展位，
   也意味着「下回合生效」类变更零成本。
7. **兜底已存在**：`processDidExit` 在 `turnActive` 时会 finalize + emit `.streamEnded`
   （`PiRpcTransport.swift:386-396`）——P6.0 改落定语义后，异常退出路径天然兜底，无需新增看门狗。

---

## 1. P6.0 缺陷修复（第 0 批，0.5 天）

### 1.1 修法逐项

**① `agent_end` 腰斩自动重试**（`PiRpcTransport.swift:532-545`）
- 现状：`case "agent_end", "agent_settled":` 同等对待，立刻 `turnActive=false` + `teardownProcess()`。
- 修法：**switch 拆开**。`agent_settled` → 原有落定流程（finalize + emit `.streamEnded` + teardown）；
  `agent_end` → **不拆进程、不翻 turnActive**，只读 `willRetry` 存入 transport 状态（供 P6.1.2 过程态用）；
  `processDidExit` 兜底不变（异常退出/abort 后进程消失都会走它）。
- 连带：`MemoryDistiller.swift` 自带独立 line handler，`agent_end`/`agent_settled` 同等对待——
  同步改为只认 `agent_settled`（提炼轮遇到服务端 5xx 重试时不再腰斩；watchdog 兜底不变）。
- 收益外溢：`CompletionNotifier` 的完成通知从「重试前的假完成」后移到真落定，**更准**。

**② 非审批扩展请求回 `"Allow"`**（`:600-606`）
- 修法：`handleExtensionUIRequest` 分流——方法 ∈ `{select, confirm, input, editor}` 照旧走审批/自动应答；
  方法 ∈ `{notify, setStatus, setWidget, setTitle, set_editor_text}` → **不回任何 response**；
  其中 `notify` 上抛新事件 `AgentEvent.extensionNotify(type: String, message: String)`
  （notifyType 映射 info/warning/error）→ Store → ChatBottomBar 既有横幅通道显示（warning/error 常驻直至下回合）；
  其余三个 TUI 概念忽略 + debug log。
- 边界：MANGOX APPROVE 标记的审批分流在白名单之前判断，顺序不变。

**③ `parseUsage` 丢 cost**（`:639-651`）
- 修法：`MessageUsage` 加 `costUSD: Double?`（optional，JSON payload 直存零迁移）；
  `parseUsage` 读 `usage.cost.total`（缺失 → nil）。P6.1 状态栏与 P6.2 Details 直接消费。

**④ 工具卡标签错显**（`:708-720`）
- 修法：`kindFor` 补 `case "grep", "find", "ls": return .grep/.find/.ls`？——**不加枚举**，
  `ToolKind` 加三个 case 会波及 Codable 存量数据判断；改用**最小改法**：
  `ToolKind` 现有 8 case 不动，`kindFor` 把 `grep/find/ls/powershell` 分别映射：
  `powershell → .bash`（同族），`grep/find/ls → .read`（信息类同色）——**这治不了标签**。
  → 终版：`ToolKind` 增加 `case grep, find, ls`（`label = rawValue`，`defaultColor = .info` 与 read 同族；
  ToolPhase/渲染无 switch 遗漏风险——`defaultColor` 是唯一 switch，补三行即可）。
  存量 JSON 无此三值，无需迁移。

### 1.2 冒烟（T14，✅ 10 项，2026-09-14）

1. agent_end(willRetry:true) 不 teardown、不置 idle；2. agent_settled 才落定；
3. 非审批方法零 response（断言 sentCommands 无 extension_ui_response）；4. notify 上抛横幅事件；
5. parseUsage cost 捕获 + 缺失 nil；6. grep/powershell 映射。
实现记录：transport 加 `lastWillRetry`（internal）与 `sentCommands`（internal 冒烟钩子）两个可观测状态；
门禁 102 项 ALL PASS（2026-09-14）。

---

## 2. P6.1 状态显示强化（第 1 批，1.5 天）

### 2.1 数据面（P6.1.1 前半）

- **新 delegate 方法** `transport(_:didReportSessionStats:)` + `SessionStats` 结构：
  `tokens(input/output/cacheRead/cacheWrite/total) / costUSD / contextTokens / contextWindow / contextPercent(Optional) / userMessages / assistantMessages / toolCalls`。
- **拉取时机（有立场，防 RPC 打爆）**：仅两处——spawn 后（spawnProcess 尾部与
  get_state/get_available_models 并列）与 `agent_settled` 后（**先拉再拆**：settled 不立即
  teardown，get_session_stats 响应到达才拆，2s 无响应兜底强拆；期间开新回合由 turnActive 守卫）。
  **不随 chunk 拉**。
- **流式实时**：`message_update` 顶层 `usage` → 节流 **500ms** emit 新事件
  `AgentEvent.usageTick(SessionStats)`（transport 内聚累计，非每 delta 一条）；
  落定后的 `get_session_stats` 回读**覆盖**实时值（幂等，以 pi 为准）。

### 2.2 状态栏（P6.1.1 后半）

- **挂载**：`BottomStatusBar` 挂 `ContentView` 主列底部（Chat/Trajectory 两底档共用，
  workspace 底档不挂——文件树有自己的空间诉求，待真机看效果再定）。
- **字段映射（2026-09-14 拍板：只展示 4 项，费用/轮数/模型/思考全部移出——
  费用→Trace Details、轮数→Trace 摘要头、模型/思考→composer 菜单）**：

| 展示项 | 数据源 |
|---|---|
| 过程态胶囊 | P6.1.2 RuntimePhase（见 §2.3） |
| 上下文 % | `contextUsage.percent`（**null → 显示 `--`**，压缩刚结束的合法态） |
| Token ↑↓ | `usageTick`（流式期）+ `get_session_stats`（落定后以 pi 为准） |
| 当前会话 N 轮 | 本地 user 消息数（`store.currentTurnCount` 现算，真实且零成本；2026-09-14 拍板替换缓存%） |

- **形态（已落地）**：BottomStatusBar **纯展示**——AUTO toggle 与思考级别 Menu 已删
  （模型/思考切换唯一入口 = composer 模型菜单；`AgentStatus`/`ReasoningEffort`随之移除，
  `SessionStats` 替代）。

### 2.3 过程态（P6.1.2，✅ 已落地）

- **`RuntimePhase` 枚举**（transport 维护，事件 `AgentEvent.phaseChanged(RuntimePhase)`）：

| phase | 触发事件 | 文案 |
|---|---|---|
| `.idle` | agent_settled / streamEnded | （无胶囊） |
| `.streaming` | agent_start | streaming |
| `.retrying(attempt, maxAttempts, delayMs)` | auto_retry_start | 重试 2/3 · 4s 后 |
| `.compacting(reason)` | compaction_start | 压缩中（threshold）… |
| `.summarizing` | summarization_retry_* | 摘要重试中… |
| `.queued(count)` | queue_update | 排队 N 条 |

- 落地补充：auto_retry_end / summarization_retry_finished / queue 清空 → 回 `.streaming`；
  进程异常退出（processDidExit）同样归 `.idle`；切会话时 phase 跟随选中会话
  （在途 = `.streaming` 粗粒度，精细相位仅前台会话事件归并）。
- 胶囊配色：idle = 灰 / streaming = 主色 / 过程态 = amber（`CodexTheme.thinking`，警示但不响）。

- `compaction_end` → 附带 `tokensBefore → estimatedTokensAfter` 一次性横幅（复用 notify 横幅通道）；
  `extension_error` → error 横幅（extensionPath 收敛为文件名）。
- **控制按钮后置**（`compact` / `set_auto_compaction` / `set_auto_retry` / `abort_retry`）——
  显示优先，控制进 backlog 防膨胀；`turn_start/turn_end` 本期只入 P6.2 的数据面。

### 2.4 分期

| 阶段 | 内容 | 量级 |
|---|---|---|
| P6.1.1 | SessionStats + 拉取时机 + usageTick 节流 + BottomStatusBar 挂载（纯展示版） | ✅ 2026-09-14 |
| P6.1.2 | RuntimePhase + 6 组事件接入 + 过程态胶囊 + 横幅 | ✅ 2026-09-14 |

---

## 3. P6.2 Trace v2（第 2 批，2 天）

### 3.1 视图结构

Trace 头部摘要行下加 **segment 三档：Messages / Turns / Details**（`TrajectoryView` 内部状态，
不影响 TopBar 胶囊的 Chat/Trace 底档语义）。三视图同源 `store.messages`（+ P6.1.2 的 turn 数据）。

### 3.2 Messages（现 v1 增强，P6.2.1）

- **Turn 卡折叠**：`TrajectoryModels.turns(from:)` 已有回合分组——回合头加折叠态
  （默认展开最近一回合、折叠其余，`Set<UUID>` 展开态机制复用）；
- **工具行分组**：同回合内**连续**同类工具（kind 相同）折叠为一行「bash × 5」，
  展开还原逐条卡片；跨段不合并（保持时序语义）；
- 工具卡提前量：`toolcall_start`（toolName + id）→ 先出 `.queued` 卡，`tool_execution_start` 转 running。

### 3.3 Turns 视图（P6.2.2）

- 每回合一张卡：输入首句 / 输出首句 / durationMs / tokens / 工具数；
- 数据源 = P6.1.2 接入的 `turn_end`（真实回合边界 + toolResults）；无 turn 事件的存量消息**回落现有派生**；
- 卡片点击 → 跳 Messages 视图并展开该回合（两视图互跳， Details 不跳）。

### 3.4 Details 视图（P6.2.2）

- 按 **LLM 调用粒度**列 run 明细：`usage.responseId` 有值的消息各一行（无 responseId 的旧消息归并"未上报"）；
- 行展开 = in/out/cacheRead/cacheWrite/reasoning/total + costUSD + model + responseId + durationMs；
- 顶行合计 = 会话级（直接用 P6.1.1 的 SessionStats，不自算）。

### 3.5 导出（P6.2.3）

- Trace 头部加导出按钮 → `export_html` 带 `outputPath = ~/.mangox/exports/<sessionId>-<yyyyMMdd-HHmmss>.html`
  （目录不存在则建）→ 成功后 `NSWorkspace` reveal in Finder；
- **Markdown 导出后置 backlog**（pi 出的是 HTML；自建 Markdown = `get_messages` 拼装，半天，另排）。

### 3.6 分期

| 阶段 | 内容 | 量级 |
|---|---|---|
| P6.2.1 | Messages 增强（Turn 卡折叠 + 工具行分组 + toolcall_start 提前出卡） | ✅ 2026-09-14 |
| P6.2.2 | Turns + Details 两视图（segment 切换 + 互跳） | ✅ 2026-09-14 |
| P6.2.3 | export_html 导出 + reveal | ✅ 2026-09-14 |

- **落地注记（2026-09-14）**：Turns/Details v1 数据源 = 现有派生（TrajectoryBuilder 纯函数,
  tokens = 回合内 usage 合计, 时长沿用启发式估计）；`turn_end` 接入（真实时长 + toolResults 摘要）
  后置——派生已满足 v1 需求。导出 = 临时会话绑定进程（spawn 带 --session → export_html →
  响应/15s 超时后拆进程）→ ChatStore 收口 Finder reveal + 横幅；导出路径
  `~/.mangox/exports/<sessionId>-<yyyyMMdd-HHmmss>.html`。

---

## 4. P6.3 Side chat + Away summary（第 3 批，1-1.5 天）

### 4.1 Side chat（P6.3.1）✅ 落地注记（2026-09-14）

- **证伪点实测定案**（pi 0.85.1 + deepseek-flash，隔离 session-dir）：
  ① `--fork <src>` 产物落 session-dir 同目录，文件名 `<时间戳>_<新UUID>.jsonl`，header 带
  `parentSession: <src绝对路径>` 溯源字段；**turn 失败也留产物文件（孤儿快照）**。
  ② `--fork` 与 `--session` **互斥硬错误**（"cannot be combined", exit 1）→ 绑定只能走回读。
  ③ fork 后首条 prompt 确认携带源上下文（暗号验证通过）。
  ④ spawn 后 2-3s 内进程未就绪时 get_state 可能无响应 → **回读用 700ms 轮询兜底**（≤10 次）。
- **绑定路径化**：`sessions` 表新增 `session_file`（显式产物路径）+ `side_of`/`fork_source_file`/
  `fork_turns`/`fork_at`（侧问溯源）；transport 侧 `updateSessionFilePath`（显式路径优先于
  UUID 派生）+ `startForkSession(sourceFile:)`（spawn 带 `--fork` + `--session-dir` 收产物进托管目录）。
- **spawn 策略**：侧问首回合 `--fork <快照>`；回读落库后**后续回合一律 `--session <产物路径>`**
  （fork 只发生一次；`sideChatBinding(for:)` 纯函数决策，冒烟直测）。
- **轮级 fork**：`--fork` 只能 fork 文件当前态 → 轮级入口走**截断副本**（`snapshotLinePrefix`
  纯函数按 user 消息条数切前缀 → `side-snapshot-*.jsonl` 临时文件，回读后清理）。
- **UI（2026-09-14 用户拍板）**：初始显示 = **空白 + 快照提示条**（"界面空白 · 模型有记忆"，
  空态引导文案"直接提问，模型已了解源会话上下文"）；形态 = **侧栏新会话** `Side · <原标题>` +
  fork 徽章；入口 = **双入口**（顶栏全局按钮 = fork 最新态 + Trace 轮级右键 = fork 截至该轮）。
- **孤儿治理**：回读失败 → 删除空的侧问会话 + 横幅（首回合失败 = 快照孤儿，不转正）；
  回读成功 → `session_file` 落库 + 临时快照清理；删除侧问会话按显式路径清产物文件。
- 遗留：`⌘;` 快捷键未接（v1 鼠标入口够用）；源会话删除不连带侧问（快照自带上下文，可独立存活）。

### 4.2 Away summary（P6.3.2）✅ 落地注记（2026-09-14）

- **触发（实拍板）**：「不在场」= `sid != selectedConversationId || !NSApp.isActive`（会话级切走 /
  App 级失焦两条路径），在 streamEnded 归并点积累 `pendingAway[sid] = (turns, preview)`——
  sid 分键天然隔离并发任务（依赖 P4.0.2 transport→sid 归属路由，无共享状态）。
- **手动停止不计入**：stopTurn 清 turnStartAt → streamEnded 时 elapsed=nil 跳过积累。
- **结算**：`selectConversation`（切入会话）或 `didBecomeActive`（回到前台）时只消费当前 key，
  其余会话的积累原封留着；横幅数据 = `AwaySummary(sid, turns, preview)` 纯内存。
- **通知重叠（拍板）**：已发系统通知的完成回到前台**仍出横幅**（通知可能被忽略）。
- **展示（拍板）**：消息区**底部悬浮胶囊**（浮于内容上不推挤布局）——通栏贴顶与贴 composer
  两个方案均被否；文案「离开期间完成 N 轮 · 最近：<首句>」；交互 = 点击任意处滚底+消失 /
  右端 × 只关不滚 / 新回合开始与切会话自动清。
- preview 抽取复用 `assistantPreviewLine`（首行前 60 字，与 P4.1 完成通知同源）。
- v1 不调 LLM（MemoryDistiller 管线可复用，LLM 摘要留 backlog）；Trace 模式不显示胶囊
  （回到 Chat 即见，v1 可接受）。
- 冒烟坑：`addScheduled` 是 append——T19 最初用 `scheduledTasks[0]` 误 fire 了 T5 的旧任务
  （同日志会话串数据），改 `.last` 后全绿。

### 4.3 侧问选点（P6.3.3）✅ 落地注记（2026-10-21）

> 编号说明：**P6.3.2 是「离开摘要」**（§4.2，2026-09-14 已用）。这批最初误写成 P6.3.2，
> 已全量改为 **P6.3.3**（23 处 cases 标签 + 5 处源码注释 + 调用点与词表注释各 1）。**编号前先翻
> §4.3 分期表与 §6 里程碑总表** —— 本仓 P15 / P16 各复活过一次，这是同一个坑。

- **要解决的问题**：P6.3 之后顶栏「fork 最新态」按钮被移除（§6.1），常规入口只剩侧栏
  `由此侧问` 一个，而它等于"整场 fork"。fork 出来的上下文**永久**带着那一段，选错只能删掉
  重开 ⇒ **"从哪一轮开始"正是用户唯一想控制的那一格**，却没有任何入口。
- **粒度只到回合边界（boss 拍板）**。不是"某条消息 / 某个字符位置"。理由在架构侧：
  `--fork` 只能 fork 文件**当前态** ⇒ 轮级入口本来就走截断副本（`snapshotLinePrefix`）。
  切在工具调用中间会留下"有调用无结果"的一轮；取**区间**（非前缀）时第一行指向不存在的
  父节点。⇒ 精确到像素级的位置**做不出真东西**，宁可只给能兑现的那一档。
- **入口形态**：行菜单 `由此侧问` → **先出一屏**再 fork（与 `由此 Dream` 的二次确认同形），
  **默认「整场」** ⇒ 一路回车即走，老手感不变。
- **轮号必须与 `snapshotLinePrefix` 同源**：那边数 jsonl 里 `role=user` 的**行**，这边数
  `role == .user` 的**消息**。两边一旦漂，表现不是报错而是**少几轮上下文（零红灯）**。
  冒烟直接用 `ChatStore.snapshotLinePrefix` 对打，不另写一套口径。
- **只有图片的那一轮照样算一轮**：用"正文非空"当判据会让它被吞掉、**后面轮号整体前移一格**。
  行标题因此允许为空，UI 显式写「（只有图片）」——空一格会让人以为列表错位。
- **选到最新那一轮 = 整场**（`SideChatTurns.upTo` 合并成 `nil`）：内容等价，但那条路要多建
  一份临时快照再删 ⇒ 白拷一次文件。`picked >= newest` 与 `picked == nil` 都归 `nil`。
- **候选在点击之后才算**（`ChatStore.sideChatTurns` 走 `replayMessages`）：侧栏悬停 / 展开
  **不碰**它，与 `dreamPreview` 同法。一次点击读一场，与"每次悬停都读"是两件事。
- **提示条不用加字段（原计划取消）**：`startSideChat` 里 `sourceTurns = turns ?? count(user)`，
  而截断时就传 `turns` ⇒ 顶部那条「含 N 轮上下文」记的本来就是**带进去的轮数**，仍然为真。
  原计划"给 `SideChatInfo` 加 `upTo` 字段改表"因此**取消**（`fork_turns` 列不加）。
- **标题不写轮次（有意）**：仍是 `侧问 · <源标题>`。把"截至第 N 轮"写进标题 = 把**不可变事实**
  塞进一个**可编辑字段**（用户一改名就没了），而这个信息已经在提示条里 —— 同
  「能由产品回答的问题，不要拿去问用户」的反面：能由已有状态答的，不要再存一份。

```
┌─ 由此侧问 ──────────────────────────────────┐
│ MangoX 模型部署测试                         │
├─────────────────────────────────────────────┤
│ 选一轮：那一轮及之前的对话都会带进侧问。     │
│ ┌─────────────────────────────────────────┐ │
│ │ ● —     整场                 零拷贝     │ │
│ │ ─────────────────────────────────────── │ │
│ │ ○ 第 3 轮  第三问            14:12      │ │
│ │ ○ 第 2 轮  （只有图片）      13:58      │ │
│ │ ○ 第 1 轮  第一问：把左侧栏对齐 13:41    │ │
│ └─────────────────────────────────────────┘ │
│ 将带上 3 轮源会话上下文      [取消] [由此处侧问]│
└─────────────────────────────────────────────┘
```

### 出图时才发现的两处（10-21，真渲染）

第一次出图是拿 `ImageRenderer` 直接画的，图里**列表整块空着** —— `ScrollView` 在
`ImageRenderer` 下不真正布局滚动内容。换成 **`NSHostingView` 离屏托管**（App 里真正走的那条
布局路径）才画出来。⇒ **`ScrollView` 必须在 HostingView 里出图**，`ImageRenderer` 给的"空列表"
是个不报错、看着像"忘了画"的假象。

图上暴露的两件事：

1. **产品缺陷（已改）**：「整场」那一行把 `L("整场")` **写了两次** —— 轮号列与标题列同一个词。
   修法 = 轮号列在 `index == nil` 时显示 `—`（本仓对"这个值不存在"的诚实占位惯例），标题列保留
   「整场」、右端「零拷贝」。**这条只有真图能看见**：20 条判据全在模型层，一个字都没错。
2. **夹具缺陷（已改）**：第一版我手捏 `SideChatTurn(index:title:at:)`，跳过了 `SideChatTurns.title(of:)`
   取首个非空行那一步 ⇒ 图里「第三问」被渲染成「第三问…」（多行正文塞进 `lineLimit(1)`）。
   这属于**夹具和产品不同源**，正是 2026-10-14 那次"图是假的"的同一根火柴 ⇒ 改成夹具喂
   `[ChatMessage]`、由**生产函数** `SideChatTurns.build(from:)` 折出来。

**改动面**

| 文件 | 位置 | 做什么 |
|---|---|---|
| `Models/SideChatTurn.swift` | 新增 72 行 | `SideChatTurn`（轮号 / 消息 id / 首句 / 时间）+ `SideChatTurns.build` / `title(of:)` / `upTo(picked:newest:)`。**规则全在模型层** —— 视图层只编译不执行，判据必须有不依赖渲染的形状。 |
| `Views/Sidebar/SideChatStartSheet.swift` | 新增 174 行 | 460 宽一屏：标题 / 说明句 / 回合列表（固定高 264 + 内部滚动）/ 空态 / 底部"将带上 N 轮" + 取消 + 主按钮。自绘单选（`Circle().strokeBorder`）。 |
| `Views/Sidebar/SidebarView.swift` | `:23` `:397` | `@State sideChatPick` + `.sheet(item:)`；`onSideChat` 从"直接 fork"改成"先出弹窗"。 |
| `State/ChatStore.swift` | `:1362-1369` | `sideChatTurns(for:)`（`SideChatTurns.build(replayMessages)`）。**`startSideChat(from:upTo:)` 一行未改** —— 轮级入口 P6.3.1 就有，缺的只是入口。 |
| `scripts/l10n/en_values.py` | 尾部 7 条 | `选一轮：…` / `整场` / `零拷贝` / `（只有图片）` / `这个会话还没说过话…` / `将带上 %lld 轮源会话上下文` / `由此处侧问`。每条**只含一个占位符**。 |
| `scripts/smoke/cases/CaseSideChatPicker.swift` | 新增 111 行 / **20 条**判据 | 六节：切分 / 与 jsonl 同源 / `upTo` 四种 / 截断 / 空态 / 真库。自带夹具与独立 `ChatStore`（纪律四则④）。 |

**判据（每条都能变红）**

| 轮号 | 判据 | 变红的方式 |
|---|---|---|
| 1 | 6 条消息里只有 **3 轮**（助手 / 工具卡不算） | 把助手消息也算一轮 |
| 2 | **倒序**（最新在上，轮号仍 1 起） | 去掉 `out.reversed()` |
| 3 | 最旧那一轮排在**最后** | 同上（说明倒序不是按时间反着标号） |
| 4 | **只有图片的那一轮照样算一轮**，只是标题为空 | 用"正文非空"当过滤条件 |
| 5 | 多行正文只取**第一个非空行** | 取整段（列表里会变成一堵墙） |
| 6 | 轮数 = jsonl 里 `role=user` 的**行**数 | 口径改成"消息条数" |
| 7 | `turns: 2` 的切点 = 第 3 条 user 行（索引 4），即第 2 轮**含**它自己 | 切在那条 user 行上（整轮丢掉） |
| 8 | 选到轮数上限 ⇒ `snapshotLinePrefix` 返回整文件 | 边界写错（会裂到下一轮） |
| 9-12 | `upTo` 四种：`nil`⇒`nil` · 最新轮⇒`nil` · 中间轮⇒原样 · 空会话⇒`nil` | 中间轮也改 `nil`（侧问会**悄悄**变整场） |
| 13-15 | 首句截 60 字符 + 一个 `…`；`…` 必须在尾部；没超长**原样**不加 | 截断少一个 / 恒加省略号 |
| 16-17 | 空态两种：没说过话、只有助手消息，都是**零项**（不是一项空标题） | 空数组返回 1 项 |
| 18-20 | 真库：从落库消息折出 `[3,2,1]` · 首项是最新轮首句 · 不存在的会话 ⇒ 空列表 | 改走聚合投影而非 `replayMessages` |

（另有两处夹具守卫：建不出项目 / 建不出会话时**直接判红**，不静默通过。）

**门禁读数（2026-10-21）**：`bash scripts/smoke/run.sh` → **1460 PASS / 0 FAIL**（P6.3.3 新增 20 条）；
**反例**（吞掉图片轮 + 取消倒序，同跑一次）→ **恰好 9 红**，其余 **1451 条不动**，退码 1；
`xcodebuild` → **BUILD SUCCEEDED** / 44 `SwiftCompile` / **0 warning / 0 error**；
`gen_strings --check` **781/781**，未翻译 0 / 已废弃 0。

**已知缺口**：`SideChatStartSheet` 的列表**不可搜索** —— 40 轮的会话要滚。当前不做：
轮列表按时间倒序、人找的永远是"最近那几轮"；等真实会话长到三位数轮再谈（同 §7 的风险口径）。

### 4.4 分期

| 阶段 | 内容 | 量级 |
|---|---|---|
| P6.3.1 | `--fork` 冒烟定方案 → sessionFile 绑定路径化 → 侧栏入口 + fork 徽章 | 1 天 |
| P6.3.2 | Away summary 横幅（触发判定 + 文案 + 滚底） | 0.5 天 |
| P6.3.3 | 侧问选点（回合边界粒度 + 选点弹窗 + 与 jsonl 同源的轮号） | 0.5 天 |

---

## 5. P6.4 收尾（随发版节奏）

CHANGELOG `[0.1.4]` 段 + README（状态栏/Trace v2/侧问/回顾）+ MARKETING_VERSION ×6 + 冒烟项数同步。
**发版时机用户拍板**（惯例：冒烟全绿 → commit，push/tag 待确认）。

---

## 6. 里程碑总表

| 阶段 | 内容 | 状态 |
|---|---|---|
| P6.0 | 4 缺陷修复（settled 语义 / fire-and-forget / cost / 工具标签） | ✅ 2026-09-14（102 项 ALL PASS） |
| P6.1.1 | SessionStats + 状态栏挂载（纯展示，4 项裁剪版） | ✅ 2026-09-14 |
| P6.1.2 | RuntimePhase 过程态 + 横幅 | ✅ 2026-09-14 |
| P6.2.1 | Messages 增强（Turn 卡 + 工具行分组） | ✅ 2026-09-14 |
| P6.2.2 | Turns + Details 视图 | ✅ 2026-09-14 |
| P6.2.3 | export_html 导出 | ✅ 2026-09-14 |
| P6.3.1 | Side chat（`--fork` + 绑定路径化 + 入口） | ✅ 2026-09-14（169 项 ALL PASS） |
| P6.3.2 | Away summary 横幅 | ✅ 2026-09-14（185 → 194 项 ALL PASS） |
| P6.3.3 | 侧问选点（`由此侧问` 先出选点弹窗，粒度 = 回合边界） | ✅ 2026-10-21（1460 项 ALL PASS） |
| P6.4 | 收尾发版 0.1.4 | 时机待拍板 |
| （backlog） | 过程态控制按钮 / Markdown 导出 / LLM Away 摘要 / mini 窗 Side chat | — |

### 6.1 P6.3 后体验打磨（用户逐条反馈，2026-09-14）

| 项 | 处置 |
|---|---|
| Side chat 提示条"像报错" | 弃 accentSoft 粉底 → 中性 `bgSidebar` chrome 条；日期改 HH:mm / M-d HH:mm |
| Side chat 空态图标糙 | 46pt 圆形徽章 + 17pt 图标；文案层级重排 |
| 侧栏行操作碎 | hover 双小标 → 单 `...` 菜单（重命名 / 由此侧问 / 删除…） |
| 顶栏 fork 按钮冗余 | 移除（入口收敛为侧栏菜单 + Trace 轮级右键） |
| Away 胶囊压住正文 | overlay 浮层 → 独立占位行（信息条必须占位，浮层只适合瞬态提示） |
| 气泡正文不可选中 | MarkdownView 全块 + userBubble 补 `.textSelection(.enabled)`（跨段落仍不可选） |
| Trace Details 费用 | 去 Cost cell 与 `$` 尾缀（数据链保留，只是不渲染） |
| 会话恒为 "New chat" | 首条 user 消息 → 会话名 = 首行前 10 字符（一次性，手动重命名不被覆盖） |
| 侧问只能 fork 整场 | → **P6.3.3**（2026-10-21）：`由此侧问` 先出选点弹窗，粒度 = 回合边界、默认整场。理由：fork 出来的上下文**永久**带着那一段，选错只能删掉重开 |

---

## 7. 风险清单

1. **abort 后 `agent_settled` 是否必达**：pi 语义（abort 等到 idle 才 response）应当会发 settled，
   但需真机验证 abort 场景；兜底 = `processDidExit`（已有）+ 若验证发现不 emit，则 cancel()
   成功后加一次性 settle 定时器（3s 内无 settled 强制 finalize）——先验证再决定加不加；
2. **`contextUsage` 压缩后 null**：显示 `--`（rpc.md 明文），冒烟断言空值路径；
3. **usageTick 与 get_session_stats 的双写**：落定后 stats 回读覆盖实时值，方向恒为「pi 为准」；
   节流 500ms 防高频重绘；
4. **`--fork` 行为待证伪**：P6.3.1 第一刀就是冒烟定方案，失败 fallback 已写明（绑定路径化）；
   绑定路径化是本次唯一 touching 现有会话恢复链路的重构，冒烟覆盖「重启 App 恢复会话」；
5. **BottomStatusBar 减交互**：删 AUTO/思考控件是行为变化，真机验收确认无功能感损失
   （AUTO 状态本就无消费者）；
6. **存量 Trace 数据无 turn/responseId**：Turns/Details 两视图对旧消息回落派生/归并显示，不阻塞。

---

## 8. 拍板记录（2026-09-14）

1. ~~范围~~ → 用户拍板：今日目标 = roadmap 第 0-3 批（P6.0-P6.3）。
2. ~~模型管理导入~~ → 用户拍板（roadmap §1.7）：从 MangoX 目录从零开始，不做 `~/.pi/agent` 导入向导。
3. ~~第 3/4 批顺序~~ → 用户拍板：对换（侧问第 3 批、模型+权限第 4 批——后者不在本期）。
4. ~~隔离方式~~ → 用户拍板：只做 worktree 不做容器（不在本期，记录于 roadmap）。
5. **状态栏纯展示**（删 AUTO/思考交互控件）——✅ 用户确认（P6.1.1 裁剪 4 项 + 缓存% 换轮数，2026-09-14）。
6. **Away summary v1 不调 LLM**（结构化一句话）——AI 立场，待确认。
7. **Side chat v1 = 侧栏新会话 + fork 徽章**（不做独立小窗）——AI 立场，待确认。
8. **导出只做 HTML**（pi 原生 `export_html`），Markdown 后置——AI 立场，待确认。
9. **过程态只显示不控制**（compact/auto-retry 开关后置）——AI 立场，待确认。
