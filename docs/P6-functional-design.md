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

### 4.3 分期

| 阶段 | 内容 | 量级 |
|---|---|---|
| P6.3.1 | `--fork` 冒烟定方案 → sessionFile 绑定路径化 → 侧栏入口 + fork 徽章 | 1 天 |
| P6.3.2 | Away summary 横幅（触发判定 + 文案 + 滚底） | 0.5 天 |

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
