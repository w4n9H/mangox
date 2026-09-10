# MangoX 功能设计文档（P3：从 Mock 到真实 Agent）

> 状态：草案 v1 · 2026-09-08
> 前置：UI 已按 Codex Desktop 像素级复刻完成（P0–P2 + R1–R6 + 细节迭代），全部跑在 mock 数据上。
> 本文档回答三个问题：要接哪些功能、Agent 引擎怎么选、按什么顺序落地。

---

## 1. 目标与定位

MangoX = 个人使用的 Codex Desktop 形态 Agent 客户端。不是通用聊天工具，核心场景是**让 Agent 在本机干活**（读写文件、跑命令、查数据），UI 负责把过程透明地呈现出来（思考、工具调用、审批、产物）。

非目标：多用户、团队协作、云端同步、插件市场。

## 2. 现状盘点：UI 已经承诺了什么

UI 不是一张皮，它已经对用户做出了交互承诺，P3 的功能设计必须兑现这些承诺：

| UI 元素 | 已实现的交互 | 背后的功能需求 |
|---|---|---|
| Sidebar Projects/Chats | 新建/重命名/删除/项目嵌套/相对时间 | 会话与项目持久化 |
| Chat 消息流 | text / think / tool / plan 四类块 + 流式光标 | Agent 流式事件协议 |
| ToolCallCard | 状态机（running/queued/awaitingApproval/done/error）+ 输出折叠复制 | 工具执行生命周期上报 |
| Approval footer | 允许/拒绝/始终允许 + Composer 的 askApproval 开关 | 权限请求通道（Agent → UI → Agent） |
| Composer | @文件引用、附件、Enter 发送、流式中 Stop、模型+思考强度选择 | 会话控制 + 模型配置下发 |
| 工作区 | 文件树 + 文件预览（diff 预留） | 真实文件系统读取 + Agent 写文件的 diff 呈现 |
| 空态 Welcome | 新会话入口 | — |

**关键观察**：这套消息模型与 ACP（Agent Client Protocol）的 `session/update` 通知类型几乎一一对应——`agent_message_chunk` → text 流、`agent_thought_chunk` → think、`tool_call`/`tool_call_update` → tool 卡、`plan` → plan 卡、`session/request_permission` → 审批 footer。这不是巧合，是选型的重要依据（见 §4）。

## 3. 功能需求分解

### 3.1 会话与项目（Sidebar）
- 会话 CRUD、项目分组、选中态、相对时间 —— UI 已有，缺持久化。
- 存储立场：**JSONL 文件优先，不上 SQLite**（详见 §5.3）。

### 3.2 消息流（Chat）
- 流式渲染已就绪（逐帧滚动 + 光标 + Stop/regenerate 守卫），只需要把 mock 定时器事件源换成真实 Agent 事件流。
- `ChatStore` 当前既管状态又管"假 Agent"，P3 第一步就是把后者抽出去。

### 3.3 工具执行与审批
- askApproval 开关当前是纯 UI 状态，需与真实权限通道联动：开关 on → 敏感工具（写文件/执行命令）触发审批卡；off → 自动放行只读工具、敏感操作仍提示（立场：**审批永远是 Agent 侧决定发起，UI 开关只是默认值下发**，否则 off 时写文件无审批有安全风险）。
- "始终允许"= 会话级白名单（按工具 kind + 目标 pattern 记忆，重启不保留）。

### 3.4 工作区（已拍板：仅 project 模式生效）
- **工作区与会话的项目绑定**：project 会话有工作目录 → 工作区（Work 模式）可用；无项目的普通 chat 没有工作目录 → Chat/Work 胶囊中的 Work 禁用（灰掉 + tooltip"仅项目会话可用"）。
- 文件树从 mock FileNode 换成 project path 的真实目录（FileManager 枚举，排除 .git/node_modules 等，深度限 6）。
- @引用浮层接真实文件树（flattenedFiles 已有，换数据源即可）。
- diff 视图：UI 预留，依赖 Agent 上报"写文件前/后内容"，P3 后期做。

### 3.5 Scheduled（已拍板：要实现）
- 定位：本地定时任务——到点把一条 prompt 投递给指定 project 的 Agent 会话，执行过程与结果落成一个普通会话（复用消息流渲染，不做第二套 UI）。
- 数据：`ScheduledTask { id, name, prompt, schedule(cron 表达式), projectId, enabled, lastRunAt, lastSessionId }`，存 `scheduled_tasks` 表（§5.3）。
- 调度：应用内 Timer 驱动（每分钟对齐检查）。立场：**先只做 App 运行期间生效**，个人工具够用；launchd 后台唤醒作为后续增强，不进本期。
- Sidebar Scheduled nav 项：任务列表（名称/周期/上次运行）+ 启停开关 + 点击跳转到最近一次的执行会话。创建入口先给最简形式（任务页内手动新建，cron 文本输入）。
- ✅ 已实现（2026-09-10）：cron 四档录入器——每天（自绘时间输入）/ 每周（星期多选 chips + 时间）/ 间隔（N + 分钟/小时）/ 高级（mono 文本框兜底）。控件生成 cron（cron 仍是唯一真相，调度器零改动）；编辑时 `classifyCron` 反解析回填控件态，手写复杂表达式落高级档不丢不猜；`CronExpr.describe` 人类可读预览（识别不出显示原文），任务列表状态行复用。自然语言录入否决：失败模式隐蔽（解析错词任务静默跑错时间）。
- **迭代（2026-09-09）**：持续模式（continuous）的"4000 字符原文截断注入"方案已被 **§3.9 任务持续性记忆**取代；无项目任务、名称自动命名等已随首版落地。

### 3.6 模型与思考强度
- 当前 mock 三选一（deepseek-v4-flash / gpt-5.6-sol / o4-mini）。真实模型列表由 Agent 进程上报（能力协商的一部分），UI 不硬编码。
- ✅ 已实现（P3.5）：pi RPC `get_available_models` 能力上报（PiRpcTransport），Composer 模型菜单消费 `availableModels`，空清单降级只显当前模型；effort 档位同批接入。原"接 ACP 后补全"作废——已拍板 pi 单协议。

### 3.7 知识库/记忆（已拍板：做，顶替原 Plugins nav 槽位）
- **定位**：跨会话上下文供给层。解决"每个新会话都要重新交代背景"（环境、技术栈、偏好、项目约定）。个人工具，v1 不做 RAG。
- **概念合并立场**：知识库（用户策展的长期事实）与记忆（从会话沉淀的片段）**统一为一个数据模型**——"记忆"只是 `source=session` 的知识条目（带 origin_session_id 溯源），不建两套系统。
- **注入机制（关键技术决策）**：pi spawn 参数 `--append-system-prompt <拼接文本>`（pi 原生支持，可重复传）。
  - 否决 prompt 逐条拼接（污染消息历史、每条消息重复注入）；否决写入 AGENTS.md（污染用户仓库、全局/项目两套分离）。
  - 注入范围 = 全局条目 + 当前 project 条目，拼接为一个文本块。切 project 本来就重启 pi，注入天然按 project 重新分组，无同步问题。
  - **生效时机 = pi 进程重启**（App 重启 / 切 project / Composer 知识 pill 菜单"重启引擎生效"）。RPC `new_session` 不带 system prompt 参数，会话内无法改——协议面约束，非实现偷懒。
- **与 AGENTS.md 的分工（互补，不替代）**：AGENTS.md 属于仓库（pi 自动从 cwd 向上加载，可提交、随 repo 走）；MangoX 知识库属于客户端（个人私有、跨 repo）。两者叠加生效。
- **检索立场**：v1 无检索，启用条目全量注入——个人条目量级 < 100，全量 + LLM 自找比引入 embedding 划算。v2 SQLite FTS5 关键词过滤；v3 本地 embedding（Qwen 部署后）。均不进本期。
- **token 预算**：单条上限 16k chars、总量上限 64k chars，超出提示并建议禁用最旧条目（阈值留人工调整；2026-09-10 用户拍板由 8k/24k 上调）。
- **记忆生成**：手动 + 提炼双轨（2026-09-10 落地）——手动：知识面板直接写 + 会话内"保存为记忆"（消息 hover 工具条，带溯源）；**自动提炼 v1（人工触发）**：消息 hover "提炼本会话" → 独立一次性 pi 进程（`--no-session`，extension_ui 一律 Deny——只许说话不许动手，与主 transport 并行不碰 UI 流式状态）→ 提炼模板（最近 12 条 text 消息截 12k + 现有条目清单去重）→ 结构化 JSON 候选 → 落 `status='pending'`（永不注入）→ 知识面板"待审核"分组人工采纳（可编辑后采纳）/丢弃，Sidebar Knowledge nav 角标显示候选数。**人工审核闸门是硬约束，禁止全自动入库**；pending 用独立 `status` 列（与 enabled 正交），提炼依据存 `note` 列。自动触发（回合门槛）留 v1.2——先让模板措辞在人工触发下打磨。提炼模板的边界示例 = TODO 占位脚手架，待首轮真实提炼后人工定稿。
- **UI**：Sidebar nav 复用原 Plugins 槽位（book 图标）→ 主区切换知识面板（master-detail：条目列表 + 编辑器，启停开关 + scope 标签"全局/项目名"）；Composer 底部加知识注入 pill（显示本会话生效条数，菜单含"重启引擎生效"）。

### 3.8 明确的占位（本期不做）
- ~~Plugins nav 项~~ → 槽位复用为**知识库/记忆**（§3.7）；**插件管理恢复为新 nav 项**（§3.11, 2026-09-09, 管理对象 = pi 扩展）。
- 状态栏（BottomStatusBar 文件保留未挂载）：等真实指标源（token 用量/耗时）有了再挂。

### 3.9 任务持续性记忆（已拍板：2026-09-09 头脑风暴定稿，迭代 §3.5/§3.6 的持续模式）

**动机**：P3.6 首版两个结构性问题——
1. **会话堆积**：小时级任务一天产生 24 个会话，映射错误（把"运行"映射成了"会话"）；
2. **伪记忆**：持续模式的 4000 字符原文截断是"最近聊天记录"不是"记忆"——无结构、无提炼、跨不了长周期（半个月 × 每天几次 = 数百轮原文早被截没了）。

**定稿架构（三件套）**：

```
任务 = 1 个日志会话 (所有运行追加, 解决堆积)
     + 1 个交接文件 (agent 写, 用户可改, 唯一事实源)
     + run-log 兜底 (events 表已有, 客户端内部, 不可见)
每次 fire 注入 = 交接文件全文 (长期) + 日志会话末尾原文 (短期) + 本次指令
```

**决策 1：单会话滚动（否决 per-run 新会话）**
- 每个任务建**一个**专属日志会话（`log_session_id` 固定指向），每次运行往里追加消息，开头插运行分隔标记（`── HH:mm 运行 ──`）。
- 与"每次 spawn 新 pi 进程"不冲突：pi 带 `--no-session`，连续性本来靠客户端注入，会话文件只是客户端呈现投影，可安全追加。
- 否决归组隐藏（保留按次隔离但要新 UI，粒度仍碎）与自动归档（治"看不过来"不治"产生太多"）。
- 副产品：跳转最近执行 → 跳转任务日志，单入口；侧栏里一个任务 = 一条连续工作日志，与"持续半月的任务"心智一致。

**决策 2：交接文件（agent 自管，主记忆机制）**
- 每次 fire 的 prompt 三段式指令：`先读交接文件（无则跳过）→ 执行本次指令 → 把关键进展/状态/待办写回交接文件`。写记忆与干活同一轮，零额外 LLM 调用，agent 自行决定记什么（结构自然涌现）。
- **语义定名为"工作日志/交接文件"，不叫 memory**——"记忆"会唤起 agent 自身记忆行为联想；"工作日志"是任务产物而非 agent 状态，双机制并存不越界。防冲突三原则（对接有记忆能力的 agent 时同样适用）：
  1. **唯一主权**：一个作用域一个记忆出口；接有记忆的 agent 时二选一（判断标准：跨 spawn 存活 + 可控可备份可人肉修改，满足就让它的记忆当主角，交接文件降级为只读备份）；
  2. **概念重命名**：文件用专属路径与命名，不占 AGENTS.md/CLAUDE.md 等约定文件名（防 pi 自动加载误捕）；
  3. **文件协议而非心智指令**：prompt 约定的是文件读写格式，不依赖模型"听话"，客户端只依赖文件内容。
- 路径约定：有项目任务 → `<项目>/.mangox/tasks/<taskId>.md`（进文件树、可 @ 引用，建议 gitignore `.mangox/`）；无项目任务 → `~/.mangox/task-memory/<taskId>.md`。
- **磁盘为准，客户端零缓存**：每次 fire 现读文件，不落 DB——用户任何方式改文件，下次 fire 即生效。

**决策 3：run-log 兜底（不可见）**
- events 表本就记录每次运行的完整投影，近零成本；交接文件丢失/被删时静默重建（非阻塞提示）。**不做 UI、不可编辑**——第二个可见记忆出口 = 第二主权，漂移问题回归。

**注入模板两层**：长期 = 交接文件全文（agent 提炼的，天然紧凑）；短期 = 日志会话末尾若干条原文（替代原 4000 字符截断；单会话滚动后来源即 `replayMessages(log_session_id)`，lastSessionId 指针作废）。注入文本作为 user 消息**完整可见**（无人值守调试的唯一线索，可折叠呈现但底层全文可搜可复制）。

**与 knowledge 的分工（层级 + 主权，不重叠）**：

| | Knowledge（§3.7） | 交接文件 |
|---|---|---|
| 内容 | 稳定知识/规则 | 动态任务状态 |
| 写入者 | 用户 | agent 写，用户可改 |
| 作用域 | 全局/项目，所有会话 | 单任务 |
| 注入层级 | system prompt（spawn 一次） | fire prompt（每次运行） |
| 生命周期 | 手动维护 | 随任务，删除时归档/删除 |

若用户在 knowledge 里写任务进度 = 用错工具，knowledge 编辑器 hint 引导（"任务进度请用任务的交接文件"）。

**可见性与干预**：① 任务编辑器内嵌"工作日志"折叠区块（渲染 md + 上次更新时间戳，可编辑写回磁盘）；② 文件树/Finder 直达磁盘实体；③ 用户直改文件 = 强干预（修正跑偏/调方向），下次 fire 生效。

**Schema 影响**（§5.3）：`scheduled_tasks` 的 `last_session_id` → `log_session_id`（首启建会话后固定）；迁移：首版任务无交接文件，首次 fire 由 prompt 指令自然初始化，`last_session_id` 迁移为 `log_session_id`。

**已知边界**：fire 仍会切走当前选中会话（跳转任务日志缓解）；agent 忘写交接文件的失败模式由 run-log 兜底；`.mangox/tasks/` 的 gitignore 由用户自管（项目任务首次创建时 App 提示一次）。

### 3.10 等待型任务与审批分层（已拍板：2026-09-09 头脑风暴定稿）**动机**：P3.9 解决了"持续推进"的长任务，但另一类真实场景是**长期、稀疏执行、条件触发**——"等某个公告出来整理要点"。特征：95% 的轮次无事可做（只做轻检查）、有一个客观触发条件、触发后一轮干完即收工。与 P3.9 推进型的本质区别：每轮不是"干一段实质的活"，而是"便宜地等 + 可靠地触发 + 保证只执行一次"。

**数据模型（最小增量）**：
- `ScheduledTask.condition: String?`——触发条件，非空 = 等待型；为空 = 定时型，行为完全不变。**不新增 kind 字段**（类型由 condition 是否有内容推导，UI 段选只是驱动状态）。
- `ScheduledTask.unattended: Bool = true`——无人值守开关，创建时提示风险。
- 现有 `prompt` 字段在等待型语义下 = **触发后动作**；cron 语义 = 检查频率（默认引导 `*/30`）。
- 复用 P3.9 全部底座：单日志会话、交接文件、run-log 兜底、fire 分隔标记。

**每轮 fire 协议（两分支）**：
```
【等待任务 · 本轮检查】
触发条件: <condition>
要求: 用工具实际核实, 不要凭上轮记忆推断
├─ 未成立 → 只回一句观察结果, 不做其他事 (轻轮: 不注入近期摘录, 交接文件保持极短)
└─ 成立   → 先查交接文件确认此前未触发过 → 执行【触发后动作】→ 结束输出标记
```
- **完成标记协议**：agent 每轮结尾输出 `<!--task: done-->`（HTML 注释, Markdown 渲染天然不可见, 客户端解析零成本）。流结束后客户端扫描最后一条 assistant 消息：`done` → 自动停用任务 + 标记"已触发完成"；无标记 = 继续等。失败模式软（漏标记 = 多等一轮）。
- **防重复执行（双保险）**：done 标记自动停用为主；交接文件写入"已于 X 时间触发执行"为兜底——每轮检查先查此标记, 标记漏打时下轮不会重复执行动作。
- **误报保守**：条件判定标准要求写进 condition（"正式公告页, 新闻稿不算"），prompt 指示"不确定按未成立处理"——触发执行是重活，误触发代价高于漏检一轮。

**UI**（单列表混排，否决分 nav / 硬分组）：
- 列表行：定时型 `clock.badge` 图标不变；等待型用雷达/声波图标（"守望"语义）；副标题状态优先——`● 等待中 · 每 30 分钟检查`（绿点）/ `已触发 · 今天 09:32 完成`（完成后降灰、隐藏开关）；重开开关 = 清除触发记录重新等待。
- 编辑器：controlsRow 加"定时 / 等待"段选（显式驱动, 保存时按段选决定写不写 condition, 防类型静默漂移）；等待态下 cron 示例文案变"检查频率"，prompt 卡上方插入**触发条件卡**（条件=看什么 / 动作=干什么, 两卡分开），prompt 卡 placeholder 变"条件触发后要执行的动作…"；**无人值守胶囊**放段选旁（默认开, 点击弹风险确认）。

**审批分层（P3.3 审批桥的判定策略增强, 非新机制）**：

| 操作 | 策略 |
|---|---|
| bash 只读白名单 | 自动放行；未命中弹卡 + "始终允许"（复用 alwaysAllow, 白名单随使用学习） |
| write（新建文件） | 自动放行（若 pi 的 write 可覆盖已存在文件 → 目标文件已存在按 edit 处理） |
| edit（改已有文件） | 弹卡 |
| bash 危险/修改类命令 | 弹卡 |
| 无人值守任务 | 全 YOLO（无人值守下弹审批 = 任务死锁；开关即接受, 风险提示含 bash 可绕过审批面的明示） |

**白名单立场：白名单放行, 不做黑名单拦截**——黑名单漏一个就出事（失败模式危险）, 白名单漏一个只是多弹一次卡（失败模式是烦）, 且 shell 绕过面无穷, 黑名单工程上打不完。判定细则：
1. 组合命令按 `&&` `||` `|` `;` 切段, **每段首命令**都在白名单内才整体放行；
2. 重定向（`>` `>>` `tee`）一律按写操作弹卡；
3. 只看每段首 token, 不解析参数语义, 误伤交给"始终允许"消化；
4. 初始白名单：ls cat head tail grep rg find pwd wc file which man du df ps curl wget git(log/status/diff/show/branch) 及 `--version` 类；后续靠 alwaysAllow 增长。

**后置（留开放问题）**：推进型 goal（完成判据 + 评估轮 + 自终止, 与等待型共享底座, 每轮协议不同）；事件驱动触发（文件监听/webhook, 需事件源接入, 大部分场景可用高频轻检查轮近似）。

### 3.11 插件管理（已拍板：2026-09-09 恢复 Plugins 能力, 管理对象 = pi 扩展）

**定位**：管理 pi 的扩展（extension）——pi 的插件机制是 TS 模块（`export default function(pi)`, 通过 `pi.on("tool_call")` 等钩子注入行为）。MangoX 自己的审批门控（mangox-approval.ts, `--extension` 显式加载）就是一个扩展。Sidebar 恢复 Plugins nav 项（puzzle 图标）→ 主区切换插件面板（与知识库/Scheduled 同语言 master-detail）。

**pi 0.73.1 扩展机制（源码确认, 设计的事实基础）**：
- 发现顺序：① 项目级 `cwd/.pi/extensions/` → ② 全局 `~/.pi/agent/extensions/` → ③ 显式 `--extension <path>`（文件/目录均可, 去重）
- **无"禁用自动发现"的 flag**：①② 区插件无法从命令行关闭, 且目录与用户终端的 pi 共享
- 结论：**MangoX 托管区**（`~/.mangox/extensions/`）完整管理（导入/启停/删除）；**系统区**（①②）只读展示, 标注"pi 自动发现, 与终端共用"

**功能清单 v1**：
1. **插件列表**（左列）：图标 puzzle + 名称（文件名去扩展名/目录名）+ 状态行（启用/停用 · 来源：托管/全局/项目）+ 启停开关（仅托管区可开关）；内置插件 mangox-approval 标"内置"不可删
2. **启停**：disabled 集合持久化（settings 表）；spawn 时拼接 `--extension` = mangox-approval + 托管区 enabled 插件；**生效时机 = pi 进程重启**（与知识注入同机制, 面板顶部"重启引擎生效"按钮）
3. **导入**：右上 + → NSOpenPanel 选 .ts 文件/目录 → 拷入 `~/.mangox/extensions/`（默认停用状态导入, 用户确认后启用——**导入第三方插件 = 代码将在 pi 进程内执行**, 导入时风险提示）
4. **详情/源码**（右编辑区）：名称大字、来源胶囊、路径行、**源码只读预览**（mono 滚动区）、删除按钮（托管区）
5. **系统区展示**：只读列出 + "在 Finder 中显示"跳转, 开关置灰

**数据与实现**：
- `ExtensionItem { name, path, source: managed|global|project, enabled }`——纯扫描派生, 无新表; disabled 集合存 settings key `extensions_disabled`
- `PiRpcTransport.spawnProcess` 的 `--extension` 拼接改造：从固定 mangox-approval → mangox-approval + 托管区 enabled 列表（ChatStore 下发, `updateExtensions([String])` 协议新方法, 默认空实现）
- 生效链路：启停 → disabled 集合落盘 → 提示重启 → `restartEngine()` 复用

**明确不做/后置**：插件市场与 URL 安装（需要来源信任体系）；接管全局扩展目录（`PI_CODING_AGENT_DIR` 指向私有 agent 目录可隔离发现, 但连带隔离 models/auth/sessions 配置, 复杂度不成比例）；插件级权限沙箱（pi 本身不提供扩展权限模型, 展示层风险提示替代）。

---

## 4. 核心选型：Agent 引擎

### 4.1 候选方案

**方案 A：ACP 客户端 → 外部 Agent 进程**（claude-code / gemini-cli / 未来的 Mangopi CLI）
MangoX 通过 ACP（JSON-RPC over stdio）拉起并驱动一个 Agent 子进程。Zed 牵头的开放协议，专为"编辑器/IDE 客户端 + Agent 进程"场景设计。

**方案 B：进程内自研 runtime**
在 MangoX 里直接写 agent loop：LLM API 调用 → tool call 解析 → 本地工具执行（fs/shell）→ 流式回 UI。

**方案 C：CLI 包装**（非 ACP，直接 spawn CLI 解析 stdout）
最省事但最脏：解析面向人眼的终端输出，流式/审批/工具状态全靠正则猜，否决。

### 4.2 差异分析

| 维度 | A：ACP 接外部进程 | B：自研 runtime |
|---|---|---|
| 与现有 UI 的契合 | **天然 1:1**（消息块/工具卡/plan/审批全部有对应协议类型） | 自己定义事件协议，等于在进程内重写一遍 ACP |
| 冷启动工作量 | ACP client（JSON-RPC + stdio 管理），约 600–800 行 | agent loop + 工具集 + 权限 + 流式，1500+ 行起步 |
| 能力上限 | 吃被接方的能力（Claude Code / Gemini 的工程能力现成） | 自己造轮子，短期天花板低 |
| 可控性 | 协议边界清晰但行为受对端影响 | 完全可控（call trajectory 自定义空间大） |
| 与 Mangopi CLI 的关系 | **v0.2 实现 ACP server 即插即用，投入复用** | 与 Mangopi 完全平行，两套 agent 逻辑重复建设 |
| 调试手段 | 现成 Agent 可先联调（不等 Mangopi） | 一切自己调 |
| 主要风险 | 对端 ACP 实现质量参差；permission 细节需实机联调 | 工作量大且最终大概率被 Mangopi 取代 |

### 4.3 结论（有立场）

**选 A，ACP-first。理由按权重排：**

1. **UI 消息模型与 ACP 通知类型一一对应**（§2 的表）——选 A 意味着数据层几乎只是协议翻译；选 B 等于先发明一个"进程内 ACP"再实现它。
2. **你正在把 Mangopi CLI v0.2 重构成 everything-is-plugin**——ACP server 对它就是又一个插件。选 B 会让 MangoX 内置一套和 Mangopi 平行的 agent loop，重复建设，最后还得删。
3. **不等 Mangopi**：claude-code / gemini-cli 现在就有 ACP 实现，可以立即作为联调基线把 UI 全部打通；Mangopi v0.2 完成后替换对端，UI 零改动。
4. call trajectory 作为一等产物的诉求不被牺牲——ACP 事件流本身就是结构化 trajectory，客户端落盘 JSONL 即可，还白赚一个"任何 ACP agent 通用"的格式。

**方案 B 作为降级预案**：只有当实机联调证明主流 ACP agent 的权限流/流式稳定性不达标时，才退回自研 runtime。§5 的 `AgentTransport` 抽象保证这个切换不动 UI 层。

**MCP 的位置**：MCP 是 Agent 进程的工具来源（比如把 mcp-data-query 挂给 Mangopi/Claude Code 做数据查询），不是 MangoX 直接对话的协议。MangoX ↔ Agent 走 ACP，Agent ↔ 工具走 MCP，两条协议各归各位，不要在客户端里混。

---

## 5. 架构设计

### 5.1 分层

```
┌─────────────────────────────────────────┐
│ Views (SwiftUI)          —— 已完成, 不动 │
├─────────────────────────────────────────┤
│ ChatStore (状态聚合)     —— 瘦身: 去掉假  │
│                            Agent 逻辑     │
├─────────────────────────────────────────┤
│ AgentTransport (协议)    —— 新增: 事件流  │
│   MockTransport → ACPTransport           │
├─────────────────────────────────────────┤
│ ACP Client (JSON-RPC/stdio) —— 新增      │
├─────────────────────────────────────────┤
│ Agent 进程 (claude-code / gemini /        │
│            Mangopi CLI v0.2)             │
└─────────────────────────────────────────┘
```

### 5.2 AgentTransport 抽象（职责描述，非代码）

- **下行**（UI → Agent）：startSession(projectPath, modelConfig) / prompt(text, attachments) / cancel / respondPermission(requestId, decision) / closeSession。
- **上行**（Agent → UI，事件流）：messageChunk / thoughtChunk / toolCallStart / toolCallUpdate / planUpdate / permissionRequest / usageUpdate / sessionEnd。
- ChatStore 只做"事件 → 消息列表状态"的归并，不知道对端是 mock 还是 ACP。
- MockTransport = 把现有 ChatStore 里的定时器假流原样搬进去，保证第一步重构 UI 行为零变化（回归基线）。

### 5.3 持久化（已拍板：SQLite，系统 libsqlite3 零依赖）

**选 SQLite，理由：**
- 投影 + 指针模型下，客户端存储本质是**可查询事件库**：按项目查会话、按时间排序、改标题、删会话、Scheduled 任务轮询 `lastRunAt`——全是 SQL 主场；
- JSONL + projects.json 的"索引/投影两处写"有崩溃一致性问题（需要重建逻辑），SQLite 事务天然解决；
- 单文件库（`~/.mangox/mangox.db`，WAL 模式）比一个目录的散文件更好备份/迁移；
- 代价：牺牲文本直读（grep）——用 `sqlite3` CLI 查询替代，对本项目维护者无成本。

**依赖立场**：直接用 macOS 系统 `libsqlite3`（`import SQLite3`），自写 ~150 行薄封装（open/prepare/bind/step/事务）。不引 GRDB/SQLite.swift——SPM 依赖会破坏 swiftc typecheck 门禁的零配置运行。

**Schema 草案**：
```
projects        (id, title, path, created_at)
sessions        (id, project_id NULL, title, agent_session_id NULL,
                 created_at, updated_at)
events          (id INTEGER PK AUTOINCREMENT, session_id, seq,
                 type, payload JSON, ts)              -- append-only, trajectory
scheduled_tasks (id, name, prompt, cron, project_id, enabled,
                 continuous, log_session_id, last_run_at)
knowledge_items (id, scope 'global'|'project', project_id NULL, title,
                 content, source 'manual'|'session', origin_session_id NULL,
                 enabled, created_at, updated_at)
settings        (key, value)
```
- `events` 即 trajectory：每行一个 ACP 事件投影，append-only 语义用 `(session_id, seq)` 保序，导出 trajectory = `SELECT ... ORDER BY seq`。
- `sessions.agent_session_id` 是对端指针（见下）。

**与 agent 侧 session 存储的关系（不重复，视角不同）**：
- Agent 进程自己的目录（如 `~/.pi/...`）存的是**推理上下文**——LLM 原始对话历史、内部状态，用于 resume/compact，格式是各家私有的。
- 客户端 `events` 表存的是 **ACP 事件流的呈现投影**——只含 UI 渲染需要的字段（消息块/工具卡/审批/时间戳），不含 system prompt、token 级 payload 等 agent 内部细节。
- 职责类比：服务器 access log vs 浏览器 Network 面板，同一次交互两份记录，各自面向"恢复执行"和"呈现/审计"。
- 避免真正重复的手段：`sessions.agent_session_id` 存对端 ID 作**指针**，恢复会话时通过 ACP resume 找回 agent 侧上下文——推理上下文永远只存 agent 侧一份，客户端只存投影 + 指针。
- 客户端必须自持投影的原因：跨 agent 统一（换对端后各家目录格式互不兼容，Sidebar 历史不能断）、agent 进程不在也能浏览、标题/项目分组/相对时间是客户端概念。
- 反方案（直接读 pi 的 session 目录渲染）被否决：UI 会被单一对端的私有格式绑死，违背 ACP-first 的初衷。

### 5.4 工作区数据源
- project path → 真实文件树（FileManager 枚举，排除 .git/node_modules 等，深度限 6）。
- 文件预览直接读磁盘；Agent 写文件后靠 ACP 的 fs 通知（或文件监听）刷新树。

---

## 6. 分阶段计划（每阶段门禁：typecheck 全绿 + 双主题视觉走查 + 真机操作验证）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P3.0** | AgentTransport 协议 + MockTransport 下沉，ChatStore 瘦身 | UI 行为与现在逐点一致（回归基线） |
| **P3.1** | 持久化：系统 libsqlite3 薄封装 + §5.3 schema，启动加载、增删改落盘 | 重启 App 会话完整恢复 |
| **P3.2** | **PiRpcTransport（已拍板：只做 pi RPC 单协议，不做 ACP）**——spawn `pi --mode rpc --no-session`，JSONL over stdio；协议映射 prompt→send / abort→cancel / text_delta→textChunk / thinking_delta→thoughtChunk / tool_execution_*→toolUpdated / agent_start+agent_end→stream 事件 | 用 pi（已拍板联调基线）完成一次真实问答，流式渲染正确 |
| **P3.3** | 审批通道：pi 默认 YOLO 无审批 → 用 permission-gate 扩展 + RPC 的 extension_ui_request/extension_ui_response 子协议桥到 Approval footer；askApproval 联动，始终允许白名单 | 触发一次写文件审批，允许/拒绝/始终允许三条路径正确 |
| **P3.4** | 工作区真实化：仅 project 会话可用；文件树/预览接磁盘，@引用真实文件；非 project 会话 Work 禁用 ✅ 已实现（2026-09-08：WorkspaceScanner 深度 6/排除点文件与依赖目录、projects.path 持久化、pi cwd 绑定 + 换目录重启进程、Work 灰掉 + tooltip、@引用 canUseWorkspace 门控、文件预览读磁盘 1MB 上限） | 选中项目后工作区展示真实仓库；普通 chat 的 Work 灰掉 |
| **P3.5** | 模型/effort 由对端能力上报驱动 ✅（pi RPC `get_available_models`，Composer 模型菜单，空清单降级）；call trajectory 落盘已是副产品，导出/查看入口**未做**（events 表就绪，缺 UI 入口）→ **部分完成** | 切换模型实际生效 ✅ |
| **P3.6** | Scheduled 定时任务：数据模型 + 应用内调度器 + Sidebar 任务列表/启停 + 执行落会话 | 建一个每分钟任务，到点自动产出会话 |
| **P3.7** | 知识库/记忆：knowledge_items 表 + spawn 期 `--append-system-prompt` 注入（全局+当前 project）+ Sidebar 知识面板 + 会话"保存为记忆" + Composer 注入 pill（§3.7） | 加一条知识 → 重启引擎 → 新会话回答体现该知识；注入 pill 条数正确 |
| **P3.8** | ~~Mangopi CLI v0.2 对接~~ **已冻结（2026-09-09 拍板：对端长期用 pi）**，Mangopi 侧进展恢复后再解冻 | — |
| **P3.9** | 任务持续性记忆（§3.9）✅ 已实现（2026-09-09）：单日志会话滚动（`log_session_id` 迁移 + "── HH:mm 运行 ──"分隔）+ 交接文件（fire 注入工作日志全文 + 近期摘录 + 写回指令；run-log 重建时只取【本次指令】段防注入模板滚雪球）+ 编辑器"工作日志"区块（重新读取/保存日志/路径显示）；`last_session_id` → `log_session_id` 迁移用例锁定 | 小时级任务跑一天只堆 1 个会话；第二次 fire 的产出体现交接文件状态；手改交接文件后下次 fire 生效 |
| **P3.10** | 等待型任务与审批分层（§3.10）✅ 已实现（2026-09-09）：`condition`/`unattended`/`completedAt` 字段 + 迁移；两分支 fire 协议（轻检查/触发执行）；`<!--task: done-->` 标记（messageFinalized 剥离 + 回合扫描自动停用）；UI 段选/条件卡/无人值守胶囊/状态副标题（等待中/已触发/对勾图标）；**审批分层**：`BashRiskEvaluator`（bash 只读白名单 + 组合命令全段校验 + 重定向=写）挂在客户端审批桥 → **覆盖所有会话**（普通/项目/定时任务同一路径）；write 新建放行（扩展侧 existsSync，覆盖→按 edit 弹卡）；"始终允许"学习持久白名单（settings）；无人值守 fire 回合关审批、streamEnded 恢复 | 等待型任务每 30 分钟轻检查一轮（回复一句观察）；条件成立轮执行动作并自动停用任务标记"已触发"；普通会话 `ls`/`curl` 不再弹审批，`edit`/`rm` 仍弹卡 |
| **P3.11** | 插件管理（§3.11）✅ 已实现（2026-09-09）：三区扫描投影（托管 `~/.mangox/extensions` 完整管理 / 全局 `/项目` 只读展示）+ settings `extensions_disabled` 启停持久化 + spawn 期按启用列表逐个 `--extension`（内置 mangox-approval 过滤防双载）；ExtensionsView 左列分组列表（puzzle 图标 + mini switch + "+" 导入 fileImporter）+ 右侧详情（来源胶囊/路径/源码只读预览/删除确认/全局区"导入到托管区"）；`extensionsDirty` → "重启引擎生效"按钮复用 restartEngine；syncWorkspaceContext 重扫项目区。**顺手修复协议 existential 分派 bug**：`updateBashWhitelist`/`updateExtensions` 此前只存在于 protocol extension 默认实现，`any AgentTransport` 调用静态绑定默认空实现 → Pi/Mock 的覆写从不执行（P3.10 白名单重启恢复实际失效）；现已提升进协议本体 | Plugins nav 项打开面板；导入 .ts 默认停用 → 启用 → 重启引擎 → pi 日志确认 `--extension` 加载；全局区扩展可导入托管区 |

## 7. 开放问题（留 TODO，人工拍板）

1. ~~联调基线选谁~~ → **已拍板：pi**（最轻量级 ACP coding agent）。
2. ~~Plugins/Scheduled 去留~~ → **已拍板：Scheduled 实现**（§3.5）；Plugins 槽位复用为**知识库/记忆**（§3.7，2026-09-09）。
3. ~~工作区根目录规则~~ → **已拍板：仅 project 模式生效**（§3.4）。
4. ~~模型清单配置格式~~ → **已落定（P3.5）**：pi RPC `get_available_models` 上报 + Composer 模型菜单（§3.6）。
5. **diff 视图**（事后回看，区别于审批卡的"批前预览"）：git 仓库走 `git diff -- <path>`（numstat 统计已用同源），非 git 场景用审批时扩展侧已捕获的写前快照兜底（存 events 表）；数据源已具备，缺 UI 入口（2026-09-10 更新：原"依赖 ACP fs 能力协商"前提已因拍板 pi 单协议过时）。
6. ~~Scheduled 的 cron 录入~~ → **已实现（2026-09-10）**：四档录入器（每天/每周/间隔/高级），控件生成 cron 调度器零改动；自然语言录入被否决（§3.5）。
7. ~~ACP 双协议~~ → **已拍板：不做**。只落 PiRpcTransport 单协议；AgentTransport 抽象保证未来加 ACP 是纯加法。附带策略：Mangopi CLI v0.2 可考虑兼容 pi 的 RPC 协议面（而非实现 ACP），接入 MangoX 零客户端改动。
8. **知识库 token 预算阈值**（单条/总量上限）：✅ 机制已落地——现值 16k/64k chars（CodexTheme 常量 + 注入块单条截断/总量丢弃，§3.7；2026-09-10 用户拍板由 8k/24k 上调）；剩调优，等真实条目量与模型 token 表现再调。
9. ~~记忆自动提炼~~ → **v1 已实现（2026-09-10，人工触发版）**："提炼本会话"按钮 → 独立一次性 pi 进程 → 候选落 pending → 知识面板待审核分组人工把关（§3.7）。自动触发（回合数+产出量门槛）留 v1.2，等模板措辞打磨后定参数。
10. **知识检索升级路径**：FTS5（v2）→ 本地 embedding（v3，依赖 Qwen 本地部署），触发条件 = 条目量全量注入超出 token 预算。
11. **交接文件格式协议**：文件内部结构（状态区/进展区/待办区的字段划分）留 P3.9 实现时随首个真实任务定稿；prompt 指令只约定"开头读、结尾更新"，不约定内部格式，让结构自然涌现后固化。
12. ~~任务删除的连带策略~~ → **已拍板（2026-09-09）**：删除确认框提供两个动作——"删除任务 (保留会话与工作日志)" / "删除任务和日志会话"；工作日志文件始终保留（成果归档，不随任务删除）。
13. **推进型目标任务**（§3.10 后置）：goal 完成判据 + 评估轮 + 自终止，与等待型共享底座；等真实需求出现再排期。
14. **事件驱动触发**（§3.10 后置）：文件监听/webhook/数据源 watch；需事件源接入，v1 用定时轻检查轮近似。
15. ~~write 工具覆盖语义~~ → **已确认并实现（P3.10）**：扩展侧 `fs.existsSync` 放行新建文件；write 覆盖已存在文件时按 edit 弹卡审批。
16. **接管 pi 全局扩展目录**（§3.11 后置）：`PI_CODING_AGENT_DIR` 指向私有 agent 目录可让 MangoX 完全接管全局扩展发现与启停，但连带隔离 models/auth/sessions 配置；待插件管理真实使用后评估是否值得。
17. **插件元数据约定**（§3.11 后置）：v1 名称取文件名、描述取文件头注释；若 pi 生态形成 package.json `pi.extensions` manifest 惯例，跟随。
