# P10 — 扩展五件套 · 邮箱哨兵 · 会话配置持久化

> 日期: 2026-09-17 头脑风暴定稿, 作为当日目标。
> 基线: v0.1.7 (commit `e58577a`, tag `v0.1.7` 已 push)。
> 编号约定: 本篇三工作流统一走 P10 编号 — P10.1 扩展五件套 / P10.2 邮箱哨兵 / P10.3 会话配置, 不再沿用 P3.12/P9.2 编号。
> 共同背景: 扩展生态调研基于实包源码勘察 (npm tarball), 版本全部 pin; 邮箱哨兵复用 SchedulerService 无人值守链路。
> **文档收敛 (2026-09-20)**: 原 `P10.2-mailbox-sentinel-breakdown.md` (实现拆解, 643 行) 与 `P10.2-e2e-checklist.md` (真机联调流程, 234 行) 的耐久内容已并入本篇 **§2.7~§2.12**, 两份文件按用户要求删除。判据 = 可复用性: 架构 / 表结构 / 通道约定 / 不变量 / 风险 / 联调要点**留下**, 逐批冒烟清单与一次性过程记录 (拍板沿革) **丢弃**。
> ⚠️ 两份原稿**从未被 git 跟踪** (本目录下除 P3~P9 已提交文档外均为未提交新文件), 删除后**不可从仓库找回**; 需追溯旧文只能看当日 daily log 摘要 (`.workbuddy/memory/2026-09-1{7,8,20}.md`)。今后此类临时稿定稿后应**先 `git add`** 再删。

---

## 〇、当日目标总览

| 批次 | 内容 | 优先级 | 依赖 |
|------|------|--------|------|
| P10.3 | 会话级配置持久化 (§3) | 先行 (每天实机验证直接受益) | 无 |
| P10.4 | 定时任务级模型/模式配置 (§4) | 接续 P10.3 (同族, 改动面小) | P10.3 (复用 SessionConfig) |
| P10.1a-e | 扩展五件套托管 (§1) | 主线 | pi 0.85.1 兼容性验证 |
| P10.2 | 邮箱哨兵 / Remote Inbox (§2) | 主线 | P10.1a/b (web-access 能力), 与 c-e 可并行 |

---

## 一、P10.1 — 扩展五件套 (选型拍板 2026-09-17)

### 1.1 选型结论 (用户拍板)

| # | 扩展 | 版本 (pin) | 作用 | 勘察结论 |
|---|------|-----------|------|---------|
| a | `pi-mcp-adapter` | 2.34.0 | MCP 生态桥 (单 proxy 工具 `mcp` + `mcpScript`) | `getAgentDir()` 原生读 `PI_CODING_AGENT_DIR`, 默认配置 `<agentDir>/mcp.json` — MangoX 自管配置零冲突; 可导入 Cursor/Claude/Windsurf/VSCode 配置; 工具路径 UI 依赖面仅 1×notify+1×confirm; OAuth 走 callback server + 浏览器; 体积大 (index.ts ~88K) 演进快, 必须 pin |
| b | `pi-web-access` | 0.28.0 | 多 provider 聚合搜索 (web_search + fetch_content) | 401K 下载/月头部体量; **博查 (Bocha) 在 30+ provider 列表中**, 国内直连稳定/中文质量好/免费, 设为默认 provider; 免 key 的 DuckDuckGo/Exa 可做零配置兜底; **workflow 必须配 `none` 或 `auto-summary`** 规避 curator TUI; 7.3MB/9 依赖 |
| c | `@gotgenes/pi-subagents` | 21.7.1 | 子代理 (in-process, pi SDK AgentSession) | 选它不选 tintinweb 原版 (重 TUI fleet view); 工具 `subagent`/`get_result`/`steer`; **前台进度走 tool onUpdate 流** → 映射 tool_execution_update 事件, MangoX 需接线该事件并在 TrajectoryView 工具卡渲染; callback-form setWidget RPC 不可序列化直接丢弃; 自定义代理读 `$PI_CODING_AGENT_DIR/agents/*.md` + 项目 `.pi/agents/*.md`; provider-inheritance 模块解决子会话 provider 解析 (#812), models.json/auth.json 路线不受影响 |
| d | `@injaneity/pi-computer-use` | v0.4.3 | macOS GUI 计算机操作 | **AX-first 语义定位** (`@e1` 引用优先于裸坐标), ScreenCaptureKit 截图仅兜底; Chromium CDP 快路; stealth 模式 (`PI_COMPUTER_USE_STEALTH=1`, 纯 AX 后台不抢焦点) 可做成设置开关; 需 Accessibility + Screen Recording 权限 (授予 MangoX/helper); helper 路径随 `PI_CODING_AGENT_DIR` → `~/.mangox/pi-config/helpers/...`, TCC 按路径授权 |
| e | `pi-memory` | 0.4.2 | 会话间记忆 (纯 markdown) | 6 核心工具零外部依赖; **存储目录优先读 `PI_MEMORY_DIR` env** (不读 PI_CODING_AGENT_DIR), spawn 时指向 `~/.mangox/pi-config/memory/`; 每回合注入 MEMORY.md+SCRATCHPAD.md+今昨日志, **KV cache-stable 前缀设计**; `memory_search` 语义搜索需外部 qmd CLI — **默认不装**, 纯工具模式起步; 与 KnowledgeStore 边界: 知识库=人工策展, 记忆=agent 自主沉淀, 互不混用 |

**落选记录**: `@ollama/pi-web-search` (被 pi-web-access 覆盖) / `bocha-web-search-pi-extension` (216/月, 被 pi-web-access 覆盖) / tintinweb subagents (重 TUI) / swairshah computer-use (grounding 依赖 vision 模型) / TUI 类 (plannotator/statusline/studio 等, RPC 模式无意义)。

### 1.2 托管路线 (对齐 P3.11)

1. 安装: `pi install npm:<pkg>@<pinned>` 装进 `~/.mangox/pi-config/` (`PI_CODING_AGENT_DIR` 指向), **不碰用户 `~/.pi/agent`**
2. spawn: 维持 `--no-extensions` + 白名单逐个 `--extension`; 五件套各配开关 (Settings 页)
3. 环境变量: `PI_MEMORY_DIR` (e), `PI_COMPUTER_USE_STEALTH` (d, 可选开关), workflow 配置 (b)
4. UI 事件策略: `notify` → toast; `setWidget` (callback form) / TUI overlay 请求 → 扩展层静默丢弃; MCP elicitation v1 自动拒绝

### 1.3 分批与门禁

| 批次 | 内容 | 冒烟要点 |
|------|------|---------|
| P10.1a | mcp-adapter | 挂一个 echo MCP server, proxy 工具调用闭环; mcp.json 物化读写 |
| P10.1b | web-access | 博查 provider 配 key 后 web_search 调用; workflow=none 不产生 curator UI 事件 |
| P10.1c | subagents | **接线 tool_execution_update** (当前只接 8/21 事件) + 工具卡渲染 AgentDetails; 串行/并行各一例 |
| P10.1d | computer-use | 权限 precheck + 授权引导深链; 截图经 ImagePipeline 在工具卡渲染; stealth 开关 |
| P10.1e | pi-memory | PI_MEMORY_DIR 隔离验证; memory_write/read 闭环; 注入内容不污染流式渲染 |

风险: mcp-adapter 版本演进快; gotgenes 与 pi SDK 内部 API 强耦合 (升 pi 需回归); 每批需先在 pi 0.85.1 实测兼容再 pin。

---

## 二、P10.2 — 邮箱哨兵 (Remote Inbox; **对外名 Inbox**, P10.2e 定名)

> **P10.2e 归位与命名 (2026-09-18)**: ①**命名按触发源统一** —— 原「定时 / 哨兵 / Sparse Agent」分别落在"触发方式 / 隐喻 / 主体类型"三个维度上, 故不成体系。定案: **Cron**(时间) / **Watch**(条件) / **Inbox**(来信), 页面名保留 **`Scheduled`** (曾短暂改为 `Agents`, 用户拍板改回; 侧栏/页头一致), 类型段选三档 = 三类触发源; `Sparse Agent` 退为**概念统称** (三类都是 sparse agent: 平时休眠、被事件稀疏唤醒), 不再当第三类的名字。代码类型仍 `MailboxSentinel`, 表仍 `mailbox_sentinels`。②**页面归位**: 决定 10 原话只把"**邮箱配置能力**"放 Settings → 现 Settings 只留**账号池** (连接/凭据), **agent 与它的拒收日志移入 Agents 页**, 与 Cron / Watch 并列。下文成文于归位前, 凡"哨兵"处若无特别说明即指今天的 **Inbox**。


### 2.1 场景 (用户拍板)

MangoX 常驻家里 Mac; Settings 配置**邮箱账号池** (可多个, 用户申请, 与私人邮箱隔离), 每个**邮箱哨兵绑定其中一个账号** (1:1, 决定 10), 用户在外用个人邮箱发任务邮件驱动执行, 回执走同线程。三类任务:

1. **单轮**: web search / 查本机文档 / browser agent 浏览公司内网 wiki → 回执即结束
2. **多轮返工**: 结果不满意, 同线程多轮回复继续干 (长程)
3. **跨天跨周**: 类似 Scheduled 哨兵任务, 执行情况用邮件沟通

### 2.2 核心抽象: 邮件线程 = MangoX 会话

**`threadKey ↔ sessionId` 映射是任务模型侧唯一的新概念** (配置侧另有「账号 ↔ 哨兵 1:1」分层, 见 §2.4 — 属配置组织, 不入任务模型), 三类任务归一为一条路径:

- 首封邮件 → 新建会话 → fire (无人值守) → `agent_settled` → 同线程回执, 线程标 `[MGOX][DONE]` (软边界, 不封死)
- 同线程回复 → 哨兵按 In-Reply-To/References 链定位已有会话 → `follow_up` 注入 → 继续跑 (多轮返工 = 单轮的幂等延展, 非独立类型)
- 定时触发 → Scheduled 挂 email 汇报配置, 回执进线程; 执行中按里程碑发 `[MGOX][RUNNING]`

白送的性质: 回家打开 app, 邮件遥控的对话在 conversations 列表原样可见 (带 via mail 徽章), 完整 Trace 可查 — **邮件只是会话的远程界面**; 多轮返工天然带上下文 (同一 pi session, 超长走 compaction)。

### 2.3 协议细节

- **threadKey**: 首封邮件 Message-ID (References 链根); MangoX 回执恒带 In-Reply-To; 同线程回复靠 References 关联。**短 id 兜底**: `[MGOX-<id8>]` 由 MangoX 在**首封回执**主题里自行注入, 后续回复被客户端自动继承 —— 用户无需手打, References 被客户端剥掉时仍可按短 id 定位
- **主题状态机**: `[MGOX][RUNNING/DONE/BLOCKED/FAILED] + 任务摘要` — 手机上不点开即可扫进度
- **鉴权链四道闸 (全确定性规则, 模型不参与, 顺序固定; 决定 13 重写)**:
  1. **白名单闸** (拦所有邮件): `From` 精确匹配 → 不在名单即标记已读 + 移 Trash + 记拒收日志, **不回执**
  2. **身份闸 (按首封 / 后续轮分叉)**:
     - **首封** (References 未命中任何 `thread_key`): 主题须含 `<secret>` (**仅当该哨兵密钥闸开启**, 决定 13) + 首封主题含 `[MGOX]` 意图标记
     - **后续轮** (References 命中 `mailbox_tasks.thread_key`): **不要求密钥** —— 链路本身已证明身份 (攻击者不知道首封 Message-ID 就构造不出能命中的 References; 想开新线程则必过首封闸)
  3. **时效闸**: `Date` ≤ 7 天 (只对首封) + `Message-ID` 未被见过 (幂等游标)
  4. **裁决层**: bash 走 `BashRiskEvaluator` (决定 8) —— 属执行期, 不计入鉴权链
  **反馈分层 (决定 14)**: 白名单外 → **静默** (防钓鱼探测); **白名单内但密钥缺失/错误 → 回执提示一次** (同地址 24h 限流) —— 否则自己打错时完全无法自查
  **回执主题必须剥掉 secret (决定 13)**: 否则 secret 会扩散到手机锁屏通知 / 邮件列表 / 服务商日志 / 转发链
  > **修正原因 (决定 13)**: 原设计「首封手打一次, 后续回复由客户端继承主题」在实现上**不成立** —— 用户回复的是**回执**, 继承的是**回执主题** (`[MGOX][DONE] <摘要>`, 不含 secret) → 第二轮起密钥闸必不过且静默丢弃, 表现为「首封正常, 之后永久没反应」。改为后续轮走 References 链路闸后, 密钥成本才真正降到每线程一次, 且 secret 只存在于首封那一封信里
- **防御强度来源 (决定 13 重新表述)**: 主防线 = **白名单 + 只 poll INBOX** —— 后者让邮件服务商的 SPF/DKIM/DMARC 过滤成为免费的第一道闸 (伪造主流邮箱域会被判垃圾/拒收, 不进 INBOX, 哨兵天然看不到)。**密钥闸是纵深防御第二道** (Settings 可关, 默认开), 覆盖服务商过滤的两个缺口: ①白名单里存在**未配 DMARC 的域** (公司邮箱 / 自建域 / 小服务商) 时伪造成本极低 ②服务商过滤并非 100%。**前提纪律: 只 poll INBOX 永不破例** (一旦改为也看垃圾箱, 主防线立刻失效)
- **正文即 prompt (决定 6)**: **无命令模板** —— 不对任务类型做任何预设, 邮件正文清洗后**全文**作为 prompt 直接下达, 任何任务都可表达
- **正文清洗 (必须)**: 取第一个 `text/plain` part → 在第一条引用行截断 (`>` 前缀 / `On … wrote:` / `在…写道：` / `-----Original Message-----`)。**不做清洗则第 3 轮的 prompt 会内嵌前两轮全文** (context 翻倍 + 语义混乱)
- **主题清洗 (必须, 决定 13)**: `mailbox_tasks.title` 与**回执主题**都必须剥掉 —— ①`Re:` / `Re[2]:` / `Fwd:` / `回复:` / `转发:` 类前缀 (可重复) ②`[MGOX]` 意图标记 ③**`<secret>` 子串**。第 ③ 条是硬要求: 主题清洗漏掉 secret, 就等于让 secret 随每一封回执扩散到锁屏通知 / 邮件列表 / 服务商日志 / 转发链。清洗后由 MangoX 重新拼装 `[MGOX][DONE] [MGOX-<id8>] <title>`
- **工具面 (决定 7, 覆盖原决定 1)**: 邮箱任务用 **`AgentMode.full`** —— 内置工具全量 (含 bash/write/edit) + 挂全部托管扩展, 与回家 app 内手工会话的工具面**完全一致**。实现成本 ≈ 0 (`beginTurn(modeOverride: .full)` 现成), 原决定 1 设想的"工具白名单透传"前置改动**取消**。
- **审批策略 (决定 8)**: 既不"弹卡等确认"也不"全自动放行", 走**风险分级自动裁决** —— bash 交 `BashRiskEvaluator` (现成), 安全命令静默放行, 危险命令 **deny 且不阻塞**, 任务回执告知"卡在 X, 请回 app 内跑"。**原确认流 (blocked 邮件往返) 因此不做** —— 邮件往返分钟级等不到 pi 的响应窗口, 而"不阻塞的自动裁决"同时给出了刹车与活性
- **配置分层 (决定 10)**: **账号** (`MailboxAccount`) 只管连接与凭据 (host / 地址 / 授权码), **哨兵** (`MailboxSentinel`) 管策略 (白名单 / 密钥 / 项目 / 间隔 / 执行配置), 一个账号只能被一个哨兵绑定。白名单与共享密钥落**哨兵级** —— 一个哨兵的完整语义 = "用这个邮箱, 接受这些人的指令, 在这个目录里干活"
- **执行位置 (决定 11 / 12)**: `cwd = sentinel.projectId → project.path`, 无项目回落 `NSHomeDirectory()` —— **与 ScheduledTask / 快速捕获同款一行式解析, 零新概念**。项目在**首封时快照**进 `mailbox_tasks.project_id`, 后续轮次不重算 (中途变 cwd 会触发 `ensureProcessForCwd` 重启进程丢记忆; "换个地方干"应当开新线程)。spawn 前**校验目录存在**, 被删/移走 → 任务 FAILED + 回执告知, 不 fire。**cwd 只是默认落点, 不是访问控制边界** (见 §2.6 ②)
- **安全面**: 仅出站 IMAP/SMTP, 无入站端口/无组网/无 webhook; 专有邮箱与私人邮件隔离。**SPF/DKIM 未纳入 v1 鉴权链** (curl 侧无现成校验) —— 该项威胁改由共享密钥 (决定 9) 覆盖

### 2.4 落点

- `MailboxSentinelService`: 轮询服务 (对齐 `SchedulerService.tick`), 遍历 **enabled 的哨兵** → 各自 IMAP 轮询 30s 档 → 鉴权链 → 线程定位 → 任务队列。**多哨兵仍全局串行** (一次只跑一个远程回合), 受 `maxConcurrentTurns` 约束
- `MailboxAccount` / `MailboxSentinel` (配置模型): 账号池在 Settings 管理 (可多个), 哨兵绑定其中一个账号 —— **一个账号只能被一个哨兵绑定** (UNIQUE, 决定 10)。账号被引用时**禁止删除** (UI 禁用 + 提示先删哨兵); 哨兵停用**不释放**绑定 (绑定是配置态, 不是运行态)
- `MailboxTask` (原 RemoteTask): 状态机 `received → queued → running → done / failed / blocked`, 并承载 `thread_key → session_id` 映射与 **`project_id` 快照**; fire 复用 SchedulerService 无人值守链路 (done 标记现成)。**与 Scheduled 的一处关键分叉: 邮箱任务是 `ephemeral: false`** (真 pi session), 而 Scheduled 是 `ephemeral: true` (`--no-session`) + 交接文件 —— 多轮返工要靠同一 session 的上下文连续性 (超长走 compaction), 不能靠文件重建 (见 §2.5 决定 5)。
- 回执: `get_session_stats` 取 cost/tokens → summary + 附件 (图表/PDF) 同线程回复; Trace 照常落本地
- 边界 case: 内网访问依赖家里 Mac VPN 在线 → **可选的**前置探测 (`intranetProbeURL` 非空才探, 默认关闭; 任务随机时无差别探测会误报); 并发 MVP 串行队列
- Settings: **账号池列表** (**服务商预设选择器** (决定 15) + host / 账号 / 授权码 / 测试连接) + **哨兵列表** (从未被占用的账号里选一个 + 项目 + 发件人白名单 + **密钥闸开关 + 共享密钥** (决定 13) + 轮询间隔 + 可选探测地址) + **最近拒收列表** (决定 14: 时间 / 发件人 / 主题摘要 / 原因, 用于自查漏加的白名单地址) (+ 可写工作区, 若 §2.6 ② 取 C 案 —— 决定 10 后路径直接取 `project.path`, 不新增字段)

### 2.5 拍板纪要 (2026-09-18)

| # | 决定 | 依据 / 后果 |
|---|------|------------|
| 1 | ~~**工具白名单 + 免审批**~~ **已被决定 7 覆盖** | 原结论: 只挂只读内置 + 扩展, bash/write/edit 不挂。**2026-09-18 用户改判**: 任务随机 → 只读面会把任务卡死, 改 full (见决定 7)。本条保留作沿革 |
| 2 | **P10.2a-d 先行** | 表 / 协议 / 回执 / Settings 均不依赖 P10.1。原 e 批次 (命令模板 + VPN precheck) 随决定 6 消解 —— **P10.2 收敛为 a-d 四批**, 不再等五件套 |
| 3 | **专用邮箱 = 普通个人邮箱 (163 / QQ 等, 授权码制)** | 国内直连稳定, 不依赖 VPN 常开 (Gmail 需 VPN 常开, 会与"内网 wiki 依赖 VPN"叠加成单点故障)。**邮箱类型限定为普通个人邮箱** (决定 15 追加约束: 企业邮箱不在此用途内)。P10.2a-d 全程 MockMailTransport, 联调前不连真网 |
| 4 | **鉴权链 Date 窗口只对首封生效** | 原「Date 距今 ≤ 7 天」与场景 3「跨天跨周」冲突: 用户隔周回复同线程会被自己的规则拒掉。重放风险本已由 `last_message_id` 游标 + References 链定位兜住, Date 不再重复兜 |
| 5 | **邮箱任务 `ephemeral: false`** | 与 Scheduled 的 `ephemeral: true` + 交接文件不同路: 多轮返工要真 session 连续性。连带影响成本口径与回执 stats |
| 6 | **取消命令模板体系, 正文即 prompt** (追加) | 用户任务随机、任何任务都可能, 模板会变成限制。删掉 `search/doc/wiki/confirm` 四件套与 `trustFreePrompt` 开关, 邮件正文清洗后全文作为 prompt。**代价: 正文清洗成为必须项** (引用行截断), 否则多轮 prompt 内嵌历史 |
| 7 | **工具面 = `AgentMode.full`, 含全部托管扩展** (覆盖决定 1) | 理由: 任务随机 → 只读面会把"帮我改个配置"这类任务直接卡死。改为与回家 app 内手工会话**完全同权**。**实现成本 ≈ 0** —— `beginTurn(modeOverride: .full)` 现成, 决定 1 设想的 `toolAllowlistOverride` 前置改动取消。**连带后果三项**: ①审批点必然回来 → 确认流策略重新待定 ②**鉴权链成为唯一防线** (从"伪造 From 只影响只读任务"升级为"伪造 From = 拿到那台 Mac 的 shell") → 需强化 ③"插件"要等 P10.1 五件套装好才有内容 |
| 8 | **审批 = 风险分级自动裁决** | full 下 bash/write/edit 都会撞审批, 而"全自动放行"与"弹卡等确认"都是坏的 (前者无刹车; 后者邮件往返分钟级等不到 pi 响应窗口)。改走: bash 交 `BashRiskEvaluator` → 安全静默放行 / 危险 **deny 且不阻塞** + 回执告知卡点。**原确认流 (blocked 邮件往返) 因此不做**。**理由不只是防外部攻击**: 无人值守下模型幻觉出破坏性命令是**必然事件**, 裁决层是唯一刹车 |
| 9 | **鉴权加共享密钥闸** | 决定 7 后 From 伪造 = 直接拿 shell, 而白名单精确匹配不验证发件域真实性 (SPF/DKIM 未纳入 v1)。密钥落在**主题**里 `[MGOX] <secret> <任务描述>` —— 首封手打一次, 后续回复由客户端自动继承主题, **无需重复输入**。实现 = 鉴权链多一条字符串比对。**→ 机制与定位已被决定 13 修正** (原「客户端继承主题」在实现上不成立) |
| 13 | **鉴权链重写为四道闸 + 密钥降级为可选第二道** (追加, 修正决定 9) | **两处修正**: ①**机制** —— 原「后续回复由客户端继承主题」不成立: 用户回复的是**回执**, 继承的是回执主题 (`[MGOX][DONE] <摘要>`, 不含 secret) → 第二轮起密钥闸必不过且静默丢弃, 表现为「首封正常、之后永久没反应」。改为 **首封校验密钥 / 后续轮走 References 链路闸** (`mailbox_tasks.thread_key` 命中即放行 —— 攻击者不知首封 Message-ID 则构造不出能命中的 References, 想开新线程必过首封闸) ②**定位** —— 主防线改为「**白名单 + 只 poll INBOX**」(后者让邮件服务商的 SPF/DKIM/DMARC 过滤成为**免费的第一道闸**), 密钥闸降为**纵深防御第二道**, Settings 可关 (默认开), 覆盖两个缺口: 白名单含**未配 DMARC 的域** (公司邮箱/自建域) / 服务商过滤非 100%。**连带**: 回执主题与 `title` 必须**剥掉 secret 子串** (否则扩散到锁屏通知/邮件列表/服务商日志/转发链); **纪律**: 只 poll INBOX 永不破例, 否则主防线失效 |
| 14 | **非白名单静默处理 + 拒收日志 + 白名单内密钥错要反馈** (追加) | ①**白名单外**: 标记已读 + **移 Trash** (不硬删 —— 监控系统 `no-reply@` 类地址漏加白名单很常见, 硬删即永久丢失) + 记拒收日志, **不回执** ②**拒收日志**: 表 `mailbox_rejections` (时间 / 发件人 / 主题摘要 / 原因), Settings 增"最近拒收"列表 —— 非白名单邮件被静默处理, 这是「我明明发了为什么没执行」的唯一线索, 也帮首次配置时发现漏加的白名单地址 ③**白名单内但密钥缺失/错误 → 回执提示一次** (同地址 24h 限流): 原「任一不过即静默」会让用户自己打错时完全无法自查 |
| 15 | **Settings 邮箱账号加服务商预设列表 (仅普通个人邮箱)** (追加, 用户: 「settings 做一个支持邮箱列表, 比如 163 + qq 这种国内主流」→ 追加约束「不用支持企业邮箱, 我也不会把企业邮箱给 mangox 绑定, 就是普通邮箱即可」) | 新增账号时**先选预设** → IMAP/SMTP host 自动填好, 用户只需填邮箱地址 + 授权码; 末尾留**"自定义"**兜底。**预设收敛为 4 项 (参数已核实)**: 网易163 `imap.163.com:993` / `smtp.163.com:465` · 网易126 `imap.126.com:993` / `smtp.126.com:465` · QQ邮箱 (含 `@foxmail.com`, 同一套服务器) `imap.qq.com:993` / `smtp.qq.com:465` · 阿里云邮箱 `imap.mxhichina.com:993` / `smtp.mxhichina.com:465`。**范围界定: 只收普通个人邮箱** —— 网易企业邮 / 腾讯企业邮 / 阿里企业邮**全部不列** (哨兵邮箱是个人专用邮箱, 企业邮箱不在用途内, 列了是噪声; 确有需要走"自定义")。每项带 **`authNote`** (「须先在**网页版**邮箱开启 IMAP/SMTP 服务并生成**授权码**, 不是登录密码」—— **最高频踩坑点**) + 官方帮助页深链。**另两项不列入属硬约束**: **Outlook/Office365** —— 微软已弃用 IMAP/SMTP basic auth, 必须走 OAuth2, curl 方案做不到; **Gmail** —— 需 VPN 常开, 与决定 3 同一理由。预设只作**填充值与提示**, host 字段仍可编辑 (服务商端口偶有调整) → 由"测试连接"按钮 + `lastError` 兜住失效 |
| 10 | **邮箱账号池 + 哨兵 1:1 绑定** (追加, 用户: 「可以配置多个, 新增的哨兵和配置的邮箱绑定, 不支持一个邮箱配置多个哨兵」) | Settings 新增**邮箱配置能力** (可多个账号); 每个哨兵绑一个账号, **账号侧唯一** (`mailbox_sentinels.account_id` UNIQUE)。分层依据: 账号 = 连接与凭据 (技术参数), 哨兵 = 谁能驱动 + 在哪跑 + 怎么跑 (策略参数) —— 故 whitelist / 密钥 / 项目 / 鉴权落**哨兵级**, host / 授权码 / 地址落**账号级**。**连带五项 + 引用完整性**: ①原单一 `MailboxConfig` 消解为 `mailbox_accounts` + `mailbox_sentinels` 两表 (`mailbox_tasks` 加 `sentinel_id` 列) ②Keychain key 按 id 分裂 (`mailbox.acct.<id>.auth` / `mailbox.sentinel.<id>.secret`), 原全局 `mailbox.secret` 取消 → **每哨兵独立密钥** ③IMAP UID/UIDVALIDITY 游标按**账号**存 (`mailbox.uid.<accountId>`) ④多哨兵轮询**仍全局串行** (一次只跑一个远程回合) ⑤`MailTransport` **按账号实例化** (连接参数与凭据都在账号上)。**引用完整性**: 账号被哨兵引用时禁止删除, 哨兵停用不释放绑定 |
| 11 | **无项目回落 home 是合理的** (追加, 用户: 「我个人是知晓风险的」) | **撤回**本档原拟的"必填 + fail-closed"建议。`projectId: UUID?` 可选, nil → `NSHomeDirectory()`, **与 ScheduledTask 完全同语义**。理由: 任务由用户本人发起, 风险边界由用户自担 —— 一致性优于额外保护 |
| 12 | **多轮中途不换项目** (追加) | 项目在**首封时快照**进 `mailbox_tasks.project_id`, 后续轮次不重算。理由: 中途变 cwd 会触发 `ensureProcessForCwd` 重启进程 (丢进程内记忆); 语义上"换个地方干"应当开新线程。连带: 字段必须落表 (不能每次从哨兵现读, 否则改配置会让历史线程 cwd 漂移) |

### 2.6 决定 8 / 10 / 11 / 12 的实现要点 (P10.2a 必做)

**① 复用 `BashRiskEvaluator` 前必须补误放行洞 (实证) — 已实做 (P10.2a-0, 2026-09-18)**。该评估器原把 `find` / `env` / `sort` / `curl`+`wget` 当只读命令, 且整段剥重定向写法, 实际有六类漏判:

| 命令 | 漏判路径 | 后果 |
|---|---|---|
| `find` | `find . -exec rm {} \;` / `-delete` / `-ok` / `-fprint*` | 执行任意命令 / 删文件 |
| `env` | `env <cmd>` (非 `KEY=VAL` 参数) | 执行任意程序 |
| `sort` | `sort -o <file>` / `--output` / 短选项簇 `-ro` | 写文件 |
| `curl` / `wget` | `-o` / `-O` / `-T` / `--output` / `--upload-file` / `--post-file` | 写文件 / 上传 |
| `2>file` · `&>file` | 早期实现**整段剥** `2>` 与 `&>` (为豁免 `2>/dev/null`) | 写文件 (含覆盖) |
| `2>&1` 的 `&` | 切段用原始串 → `&` 被当组合分隔符, 切出假段 `1` | 真只读命令被误弹卡 |

其文件头立场写的是「白名单放行 (漏 = 多弹一次卡, 失败模式是烦)」——即假设白名单里全是真只读命令。上表属于**误放行** (不安全方向), 在交互场景下已是小漏洞 (静默放行无卡), 在**远程无人值守**下会变成真实缺口。**修法 (已完成)**: 对这四个 token 加二次参数检查, 命中即转 `.ask`; 重定向改为只剥"不落盘"写法 (`2>&1` / `1>&2` / `…>/dev/null`), 该探针串**同时用于切段**; 裁决附带**原因分类** (`Risk` enum + 中文文案) 供无人值守回执写"卡在 X"。**全局修** (交互场景同一漏洞)。另定: **二次参数检查优先于人肉学习白名单** (`learnTokens` 只授予命令名信任, 不授予任意参数组合)。语料: 31 条危险 + 27 条只读 (冒烟 §八 a-0 行)。

**② write / edit 的裁决规则 — 取 B 案 (一律放行) — 已实做 (P10.2a-0)**

决定 8 的原始选项只把 **bash** 交给 `BashRiskEvaluator`, 故 v1 按此实现: **分级只管 bash, write/edit 一律放行** (实现口径: `autoJudge` 档下 write/edit 直接 Allow, 只有 bash 交判定)。理由: 用户明确"任务随机, 任何任务都有可能", 而"帮我改个配置"正是通过 write/edit 完成的; bash 那道刹车已覆盖最具破坏性的一类 (任意命令执行)。

- **可选收紧 (留档, 不在 v1)**: 「可写工作区」—— 远程任务限定在一个根目录内, 目录外 write/edit deny, 把爆炸半径限制在一个目录。**决定 10 后路径来源已确定: 直接用哨兵绑定的 `project.path`, 不再新增 `writableRoot` 字段** (省掉字段 + Settings 输入项, 成本 ~25 → ~15 行)。**注意 cwd ≠ 边界**: 项目绑定只给默认落点 + 语义提示, pi 的 bash 无 chroot/seatbelt, 仍可 `cd /` 或绝对路径读写 —— 真要访问控制边界必须走本项
- **被否**: `edit` 恒 deny —— 会让"改配置"这类任务完全做不了, 与决定 7 初衷冲突

**③ 项目绑定与路径校验 (决定 10 / 11 / 12) — 已实做 (P10.2a)**

- **解析**照抄现成一行: `let cwd = task.projectId.flatMap { pid in store.projects.first(where: { $0.id == pid })?.path }` (`SchedulerService.swift:135`, `CaptureService.swift:97` 同款) —— **零新概念**, `ProjectGroup.path` 是 P3.4 既有基础设施。**字段与校验都落在 P10.2a** (本轮约束 5): 否则 Mock 阶段验证不了 cwd 注入, 约束会推迟到联调才暴露
- **快照**: 首封时把 `projectId` 写进 `mailbox_tasks`, 后续轮次读列不读哨兵配置 (决定 12)
- **目录存在性校验 (本轮约束 4, 新发现)**: 有 `projectId` 时先检 `FileManager.fileExists` + 是目录, 不过则任务 `FAILED` + 回执 `[MGOX][FAILED] 项目目录不存在: <path>`, **不 fire**。当前 `ensureProcessForCwd()` (`PiRpcTransport.swift:405-412`) 直接把路径交给 `Process.currentDirectoryURL`, 不存在时静默失败 —— 无人值守下没人看日志, 必须显式 fail-closed 并回执。无项目时不校验 (home 必存在, 异常属系统级)
- **副作用 (正面)**: `transports[sid]` 是每会话实例 (`ChatStore.swift:961-978`), `desiredCwd` 实例级 → 项目绑定让同一 sessionId 的 cwd 恒定, **永不触发 `teardownProcess()`** (`:404-410`)

**非阻塞**

- 轮询间隔默认值 (倾向 30s, 可调)
- 回执附件: v1 单附件 (图表 PNG) 是否够
- 可选内网前置探测: 原挂在 `wiki` 模板上的 VPN precheck 随决定 6 取消 → 保留则降级为 `MailboxSentinel` 可选探测 URL (默认留空 = 不探)
- **`Authentication-Results` 头待真机确认 (决定 13 连带)**: 163/QQ 等邮箱域**支持** SPF/DKIM/DMARC (发信侧可配 `p=quarantine/reject`), 但公开文档**未说明**收信时是否写入 `Authentication-Results` 头。**P10.2c 联调时看一眼原始邮件头**: 有则可作 v2 的免费第一层校验 (直接读服务商的 SPF/DKIM 裁决结果, 不必自算), 无则算了 —— **不阻塞任何批次**
- 命名边界: 邮箱哨兵 (真 IMAP/SMTP 远程入口) 与 user skill `mangopi-mailbox` (本地磁盘 JSON 邮件组 IPC, agent↔agent) 是两层互补, 文档中不得混称

### 2.7 总体架构与组件落点 (P10.2 全批实做后回填)

```
Settings「邮箱账号」                          ← P10.2e 归位: 只管"怎么连"
  MailboxAccount 池 (可多个: label / 地址 / host / 授权码 / 测试连接 / 服务商预设)
        │ 1:1  (约束落账号侧: mailbox_sentinels.account_id UNIQUE)
        ▼
Scheduled 页「Inbox」                        ← 与 Cron / Watch 并列的第三种触发源
  左列表行: 信封图标 + 名称 + 收信状态行 + 账号→项目
  右编辑面板: 绑账号(1:1, 锁死) + 项目 + 白名单 + 密钥闸 + 间隔 + 高级
              + 运行时状态行 (队列数/在途/最近错误) + 该 Inbox 的最近拒收
        ▼
MailboxSentinelService (State/)   timer tick → pollOnce(): 遍历 enabled 的 Inbox
  ┌ 对每个 Inbox, 逐封走 (全局串行, 一次只跑一个远程回合):
  │   MailTransport(accountId).poll() → [RawMail]      ← 每账号一个实例 (连接参数+凭据都在账号上)
  │   → ①白名单闸 → ③线程定位 (References / 短 id) → ②身份闸 (首封密钥 / 后续轮链路)
  │   → ③时效 (只首封) + ④幂等 (Message-ID 游标)
  │   → 清洗 (主题剥 secret → title; 正文引用行截断 → prompt)
  │   → 项目快照 (首封写 project_id) → 目录校验 → 入队 / fire (beginTurn)
  │   未过闸: 白名单外 → 移 Trash + 拒收日志 (不回执)
  │           名单内身份不过 → 回执一次 (同地址 24h 限流)
  └ 回合落定 → 结算 (replayMessages 切"本回合产出") → 回执 → 释放串行位 → 补跑队列
```

| 组件 | 文件 | 职责 |
|------|------|------|
| `MailboxSentinelService` | `State/MailboxSentinelService.swift` | tick / `pollOnce` / 四道闸 / 清洗 / 线程定位 / 队列编排; **驱动 N 个 Inbox, 全局串行**; `@MainActor ObservableObject` + `weak store`, ChatStore 留 facade 转发。**账号池 CRUD 也在这里** (`addAccount` / `updateAccount` / `removeAccount` / `sentinel(for:)` / `availableAccounts(forSentinel:)`) —— 拆解期原拟拆 `MailboxAccountStore`, 实做时量太小, 不拆 |
| `MailTransport` 协议 | `Agent/MailTransport.swift` | `poll()` / `send(_:)` / `markRead` / `moveToTrash` / `testConnection`; **按账号实例化**, 哨兵只提供策略不持连接 |
| `CurlMailTransport` | `Agent/CurlMailTransport.swift` | 生产实现: curl 进程封装 (imaps 收 / smtps 发); `CurlRunner` 可注入 → 冒烟断言 argv |
| `CurlMailCommand` | `Agent/CurlMailCommand.swift` | 纯函数: argv 组装 + `* SEARCH` 输出解析 + 退出码归类 |
| `MimeParser` | `Agent/MimeParser.swift` | 来信解析 (头折叠 / RFC2047 B+Q / multipart / QP / base64 / charset) |
| `MailMessageBuilder` | `Agent/MailMessageBuilder.swift` | 出站 RFC822 拼装 (含 `Message-ID` / `In-Reply-To` / `References`) |
| `MailboxReply` | `Models/MailboxReply.swift` | 回执纯函数: 状态机主题 / 引用链 / 结算聚合 / 正文组装 |
| `MailProviderPreset` | `Models/MailProviderPreset.swift` | 服务商预设静态表 (决定 15), 纯数据 + 纯函数 |
| `MockMailTransport` | `Mock/MockMailTransport.swift` | 冒烟: 脚本化收件箱 + 记录 send/markRead/moveToTrash |
| 账号池面板 | `Views/Settings/MailboxSettings.swift` | Settings 只留账号池 (预设 + 凭据 + 测试连接) |
| Inbox 编辑器 | `Views/Scheduled/SparseAgentEditor.swift` + `ScheduledView.swift` | Scheduled 页第三类; 段选三档 Cron/Watch/Inbox **上移到 `editorPane` 顶部** (放任务编辑器内会随切档消失), `selectKind` 是唯一落点 |
| 共用小件 | `Views/MailboxUI.swift` | `mboxBadge` / `relativeTime` / `shortTime` |

### 2.8 数据模型 (四张表 + KV, PersistenceStore 迁移)

```sql
CREATE TABLE IF NOT EXISTS mailbox_accounts (        -- 账号池: 只管连接与凭据
    id TEXT PRIMARY KEY, label TEXT NOT NULL, address TEXT NOT NULL,
    imap_host TEXT NOT NULL, smtp_host TEXT NOT NULL, created_at REAL NOT NULL
);   -- 授权码不进表 → Keychain: mailbox.acct.<id>.auth

CREATE TABLE IF NOT EXISTS mailbox_sentinels (       -- Inbox: 管策略
    id TEXT PRIMARY KEY, name TEXT NOT NULL,
    account_id TEXT NOT NULL UNIQUE,                 -- 决定 10: 一个邮箱只被一个 Inbox 绑定
    project_id TEXT,                                 -- 决定 11: 可空 → NSHomeDirectory()
    whitelist TEXT NOT NULL DEFAULT '[]',            -- JSON 数组 (Inbox 级)
    poll_interval INTEGER NOT NULL DEFAULT 30,
    agent_mode TEXT NOT NULL DEFAULT 'full',         -- 决定 7
    approval TEXT NOT NULL DEFAULT 'autoJudge',      -- 决定 8
    probe_url TEXT NOT NULL DEFAULT '',              -- 可选内网前置探测
    enabled INTEGER NOT NULL DEFAULT 0,
    last_poll_at REAL, last_error TEXT, created_at REAL NOT NULL
);   -- 共享密钥不进表 → Keychain: mailbox.sentinel.<id>.secret

CREATE TABLE IF NOT EXISTS mailbox_tasks (           -- 线程映射 (threadKey ↔ sessionId)
    id TEXT PRIMARY KEY, sentinel_id TEXT NOT NULL,
    thread_key TEXT NOT NULL,                        -- 线程根 (见 §2.3)
    session_id TEXT,                                 -- 绑定的 MangoX 会话 (创建后回填)
    project_id TEXT,                                 -- 决定 12: 首封快照, 后续轮读列不读配置
    status TEXT NOT NULL,                            -- received|queued|running|done|failed|blocked
    title TEXT NOT NULL,                             -- 主题清洗后 (已剥 secret)
    blocked_reason TEXT,                             -- 裁决拦下原因; **兼作 failed 的附注** (无独立 fail_reason 列)
    last_message_id TEXT,                            -- 幂等游标
    created_at REAL NOT NULL, updated_at REAL NOT NULL,
    UNIQUE (sentinel_id, thread_key)                 -- 线程键只在 Inbox 内唯一
);

CREATE TABLE IF NOT EXISTS mailbox_rejections (      -- 决定 14: 静默处理是唯一排查线索
    id TEXT PRIMARY KEY, sentinel_id TEXT NOT NULL, sender TEXT NOT NULL,
    subject TEXT NOT NULL,                           -- 摘要 120 字, 已剥 secret
    reason TEXT NOT NULL,                            -- not_whitelisted|missing_intent|secret_missing|secret_mismatch
    message_id TEXT, at REAL NOT NULL
);   -- 每 Inbox 只留最近 200 条 (插入后顺带裁)
```

**分层依据**: 白名单与密钥落 Inbox 级、host 与授权码落账号级 —— 一个 Inbox 的完整语义 = "用这个邮箱 (账号), 接受这些人的指令 (白名单 + 密钥), 在这个目录里干活 (项目)"。账号是被消费的**连接资源**, Inbox 是**策略主体**。**引用完整性**: 账号被引用时禁止删除 (UI 禁用 + tooltip 指路); Inbox 停用 (`enabled=false`) **不释放**绑定 —— 绑定是配置态, 否则会出现"暂停的 Inbox 被别的 Inbox 抢走账号"。

**KV 分账** (多账号/多 Inbox 下必须, 否则互相污染): `mailbox.uid.<accountId>` · `mailbox.uidvalidity.<accountId>` · `mailbox.gate_reply.<sentinelId>.<sender>` (身份闸回执 24h 限流)。**UIDVALIDITY 变更即重置该账号的游标** (否则漏信或重复执行)。

**字段消解记录** (拍板后): `toolWhitelist` → 决定 7 取消 · `trustFreePrompt` → 决定 6 取消 (正文即 prompt 是唯一模式) · `confirmTimeoutMinutes` → 决定 8 后确认流不做 · `writableRoot` → 决定 10 **不新增** (要做可写工作区就用 `projectId → project.path`) · `imapHost`/`smtpHost`/`address` → 上移 `MailboxAccount` · 原全局 `mailbox.secret` → 分裂为每 Inbox 一个。

### 2.9 依赖选型与通道实现约定

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| **系统 curl (imaps/smtps)** | 零依赖 (macOS 自带)、与"shell-out pi"同哲学、无 SPM 供应链面 | 无 IDLE (靠轮询); MIME 要自写; **命令顺序固定 → 满足不了"SELECT 前发 ID"** | **v1 采用** (QQ / 阿里云可用; 网易系不可用) |
| `openssl s_client` 管道 | 零依赖; **命令序列完全可控 → 能发 `ID`**; 一次 poll 一个进程 | 要自拼命令序列与多响应解析; TLS 参数须显式 | **v1.1 候选 (修网易系)** |
| swift-nio-imap + swift-smtp | 官方/结构化 | NIO handler 集成复杂度、依赖树 | v2 再评估 |
| MailCore2 | 全功能久经考验 | ObjC++/C 构建重, SPM 非官方 | 否 |

🚨 **curl 的架构级硬限制 (实测)**: 网易系 (163/126/188) 强制客户端在 **LOGIN 之后、SELECT 之前**发 IMAP `ID` (RFC 2971) 自报身份, 否则 `SELECT INBOX` 被拒并回 `NO SELECT Unsafe Login. Please contact kefu@188.com for help`; curl 侧只表现为 `curl: (67) Select failed` (登录已成功的假象掩盖真因)。假 IMAP 服务器抓到的序列是 `CAPABILITY → LOGIN → SELECT INBOX → ID` —— **自定义命令恒在 SELECT 之后**; URL 不带 mailbox 时虽得 `LOGIN → ID`, 但进程随即退出、连接关闭 (curl 无会话复用); `-X` 里注入 `\r\n` 拼多命令被 curl 直接拒绝 (`curl: (3) URL using bad/illegal format`)。**出路**: ①换 QQ / 阿里云 (不要求 ID) ②换 IMAP 通道为 `openssl s_client` 管道 —— **已实测可行**: `printf 'a1 LOGIN …\r\na2 ID (…)\r\na3 SELECT INBOX\r\n' | openssl s_client -connect host:993 -servername host -quiet -verify_return_error -CAfile /etc/ssl/cert.pem` 能拿到完整响应, TLS 校验 3 层全过、`ID` 被接受。SMTP 不受影响 (发信不需要 ID, 保留 curl)。

**自写 MIME 解析的边界** (风险集中在解析, 用"来源可控"收敛): 来源 = 白名单发件人的个人邮箱客户端 → 标准 multipart 或 text/plain, 编码 UTF-8/QP/base64; v1 支持头解析 (Message-ID / In-Reply-To / References / Subject / From + RFC2047) + 第一个 text/plain part + QP/base64 + charset (含 GB18030/Big5); 解析失败 → 显式回执 (不静默吞); HTML-only → 回执"请以纯文本发送"。

**实现约定 (六条, 全是踩出来的)**:

1. **全链只用 UID 空间** (`UID SEARCH` + `UID FETCH` / `UID STORE` / `UID COPY`) —— RFC 3501: 裸 `SEARCH` 返回**消息序号**, `UID SEARCH` 才返 **UID**; 两者只在"信箱从没删过信"时偶然相等, 混用会**静默错位到别的邮件**。实测: 信箱只剩 1 封而 `UIDNEXT 97` → `SEARCH UNSEEN` 回 `1` / `UID SEARCH UNSEEN` 回 `96`, 拿 `1` 去 `UID FETCH` 被回 NO (`curl: (78) Remote file not found`)。冒烟不变量 **㊳** 守住 (凡吃 SEARCH 号码的命令必须带 `UID ` 前缀)。
2. **输入一律按 Latin1 无损解码** (`String(data:encoding:.isoLatin1)`, 每字节 ↔ 一个字符) —— charset 判定归 `MimeParser` 自己; 上游用 UTF-8 解码会在 GBK/未知 charset 上丢字节。
3. **IMAP 输出全是 CRLF, 而 Swift 的 `Character` 是字形簇 → CRLF 算 1 个字符**: `split(separator: "\n")` 切不开 CRLF 行尾, 按行处理前必须先 `replacingOccurrences(of: "\r\n", with: "\n")`。
4. **取信只能走 curl 内置 `imaps://host/INBOX;UID=n` 路径, `-X` 形态拿不到正文**: `-X 'FETCH n BODY.PEEK[]'` / `-X 'UID FETCH n BODY.PEEK[]'` / 与 `;UID=` 同时给 (`-X` 赢) —— curl **一律只输出 IMAP 响应行** (31 字节, 大块字面量根本不读) → 前端报"UID n 未取到邮件正文"。改用内置路径后 curl 发 `UID FETCH n BODY[]`, stdout **就是裸邮件字节** (与期望邮件 `cmp` 全等)。**代价**: 内置路径硬编码 `BODY[]` (非 `.PEEK`, curl 没暴露开关) → **取信即置 `\Seen`**。白捡的好处: 被拒的信也只出现一轮 (不再每轮重复记同一条拒收日志, 也不再需要"解析失败补 STORE"的兜底); 代价是 fetch 返回到入队之间崩溃会留"已读未处理" (单封, 仍在 INBOX 可人工找回)。要恢复 PEEK 语义只能走上面那条 `openssl` 通道。
5. **垃圾箱名不能硬编码单个值**: 服务端目录名随服务商与**界面语言**变, 运行时又判不出来 (QQ 的 `LIST "" "*"` 只回 `(\HasNoChildren)`, **不给 `\Trash` 特殊用途标志**; 真名是 `Deleted Messages`)。故 `CurlMailTransport.trashCandidates = ["Deleted Messages", "Trash", "已删除"]` **逐个试** COPY (第一个成功即止, 失败的 COPY 无副作用), 全失败仍打 `\Deleted` 收尾 —— 尽力而为, **永不 EXPUNGE**。
6. **SASL 机制必须显式钉死 `--login-options AUTH=LOGIN`, 不能靠 curl 自选**: curl 不给机制时选 **PLAIN**, 而 **QQ 的 SMTP 只接受 LOGIN, 对 PLAIN 一律 `535 Login denied`** (同服务器的 IMAP 反而接受 PLAIN) → 同一个授权码"IMAP 全通、SMTP 登不上", 看着像授权码没开 SMTP 权限。连带两条: ①「测试连接」必须**收发两个方向都验**, 新增 `CurlMailCommand.smtpAuthProbe` (只连 + 认证 + **不发信**: 认证过后 curl 卡在 `MAIL FROM` 被服务端 502 拒 → `exit 8`; **只有 67 才算凭据问题**) ②失败必须可见 —— 回执发送失败原先只写进一个**没有任何视图消费**的字段, 于是"任务跑了、会话建了、回执没到"而界面一片正常; 现接进 Inbox 编辑器「运行状态」卡。

**只读探针诊断法** (以后别靠日志反推远端状态): `scripts/diag/imap_probe.py` —— Python `ssl` 直连真服务器, 跑 `LOGIN` / `SELECT` / `LIST` / `SEARCH` / `UID SEARCH` / `UID FETCH n BODY.PEEK[]` / `LOGOUT`。纪律: 凭据只从环境变量读 + **输出全程脱敏** + 只用 `BODY.PEEK[]` (不 STORE / COPY / EXPUNGE, 零副作用) + 把"我们以为的命令"与"正确命令"**成对发** (差异自己跳出来)。**验证会改状态的链路就"做-验-还原"**: 取信会置已读 → 验完立刻 `STORE -FLAGS (\Seen)` 标回未读并复查。

### 2.10 多轮 (后续轮) 不变量 — 2026-09-20 审出五条

第 1 条是**全域死锁**, 2/3 是**静默失效**, 4/5 是脏数据。每条都有冒烟回归 (㊶ / ⑯ / 正文清洗)。

1. **在途任务的状态不许被降级** (死锁级)。同线程的追加指令会 `locate` 到**正在跑的那个任务**: 若无条件写 `status = .queued`, 落定钩子 (`noteTurnFinished` 按 `status == .running` 找任务) 就找不到它 → 串行位 `runningTaskId` **永不释放** —— 不是丢这一封, 而是**此后所有 Inbox 的邮件只进不出**, 且这一轮的回执也发不出去。触发极日常: agent 还在干活时用户在同一个线程再回一封, 或一次 poll 取回同线程的两封。**旧实现被"串行"的多轮测试掩盖**: 之前所有多轮用例都等上一轮落定才投下一封, 从没制造过"在途"窗口 (临时退回旧逻辑复现 → 5 条断言全红 + 回执 0 封)。修法: `enqueue(task:pending:currentlyRunning:)` 区分"在途"与"排队"; `driveQueue` 改**以 `queuedTurns` 为准** (按 status 找会漏掉在途任务收下的追加指令)。
2. **同线程连发两封 → 合并成一轮, 不覆盖**。原 `queuedTurns[task.id] = pending` 是覆盖语义 → 前一封的指令**静默消失**。现拼成 `第一封\n\n第二封` 一起跑, 回执锚定最新那封。刻意不做多级 FIFO: 邮件是慢通道, 连发两封的真实意图就是"合起来说"。
3. **回执主题的状态 tag 会在多轮里累积**。回执主题是 `[MGOX][DONE] <title>`; 用户对它点「回复」→ 客户端给 `Re: ` + 原主题 → `cleanSubject` 剥掉 `[MGOX]` 后**只剩 `[DONE]`** → 成为新一轮 title → 下一封回执 `[MGOX][DONE] [MGOX-xxx] [DONE] …` 一路滚长 (title 是会话列表标题, 会一直脏)。修法: `statusTagPattern` **由 `MailboxReplyStatus.allCases` 派生** (状态机加档只改一个文件, 两侧不失配), 且只吃方括号形态 (`分析 done 状态` 这类裸词不动)。
4. **正文引用截断要认 QQ webmail 的分隔行**。QQ 真机格式是 `------------------ 原始邮件 ------------------` (没有 `>`、没有 `写道：`) → 原 `isQuoteLine` 三条规则全不命中 → 第二轮起 prompt 会内嵌上一轮全文 (context 翻倍 + agent 重跑上轮动作)。补 `原始邮件` + "≥10 个 `-` 的纯分隔线"两条 (阈值 ≥10 是刻意给 markdown 的 `---` 留空间)。
5. **幽灵 `running` 行**。上次退出时回合还在跑 → 库里留一条 `status = .running`。它不占串行位 (那是内存态), 但 `noteTurnFinished` 按 `status == .running` 找任务 → 之后用户在那个会话里自己发一条消息, 落定时会**命中这条幽灵**, 把用户那条回合的产出当回执发出去。故 `reload()` 把 `.queued` 与 `.running` 一起判失败。

### 2.11 风险清单

| 风险 | 缓解 |
|------|------|
| MIME 解析脆弱 (客户端格式千奇百怪) | 来源可控 (白名单); 解析失败显式回执; 语料冒烟覆盖三大编码 |
| 凭据泄露 | 授权码与密钥走 Keychain **按 id 分账**; 两张配置表的行内**不含任何密文**; UI 永不回显已存凭据 |
| **邮件即远程 shell** (决定 7 的直接代价) | **已接受**。防护三层: ①**门禁** = 白名单 + 只 poll INBOX (借力服务商 DMARC) + 默认开的密钥闸 ②**刹车** = 分级裁决 (决定 8) ③**边界** = 项目绑定只给默认落点 (**非沙箱**)。决定 10 后每 Inbox 独立密钥 → 泄露一个邮箱不影响其他 |
| **From 伪造绕过白名单** | 三层覆盖: 服务商 SPF/DKIM/DMARC 过滤 (伪造主流域进不了 INBOX) → 密钥闸 (覆盖"名单内含未配 DMARC 的域") → `References` 链路闸 (进不了已有线程)。**残余风险**: 白名单域未配 DMARC + 服务商漏判 + 密钥闸被关, 三者同时成立才可进入执行 |
| **只 poll INBOX 一旦破例 → 主防线失效** | **纪律项**: 将来若为"防漏"改为也看垃圾箱 / All Mail, 服务商过滤这道免费闸立刻失效。**改动此行为前必须重估鉴权方案** |
| 后续轮不要求密钥的边界 | 前提是首封 Message-ID 不泄露 (能读到回执 = 已读到用户邮箱, 此时密钥同样保不住)。已超出本方案假设边界, 靠"只 poll INBOX" + 首封 Date 窗口 (≤7d) 收敛暴露期 |
| **主题清洗漏 secret → 扩散** | 硬要求: `title` 与回执主题**共用同一清洗函数**; 冒烟断言"send 主题不含 secret 子串"。否则扩散面 = 锁屏通知 / 邮件列表 / 服务商日志 / 转发链 |
| 密钥打错无反馈 → 无法自查 | 决定 14: 白名单内缺/错密钥 → 回执一次 (24h 限流) + 拒收日志留痕 (`secret_missing` / `secret_mismatch`) |
| 非白名单邮件被永久删除的不可逆性 | 决定 14: **移 Trash 而非 `EXPUNGE` 硬删** + 记拒收日志 (监控系统 `no-reply@` 漏加白名单是高频场景) |
| **`BashRiskEvaluator` 误放行洞** | 拍板 8 暴露四类 (`find -exec` / `env <cmd>` / `sort -o` / `curl·wget -o\|-O\|-T`), 实做又发现两类 (整段剥 `2>`/`&>` 连带放行 `ls 2>err.txt`; `2>&1` 的 `&` 被当组合分隔符切出假 token)。**已修 (a-0)**: 只剥"不落盘"写法, 其余 `>`/`>>`/`tee` 一律 `.ask`; 探针串**同时用于切段**。**二次参数检查优先于人肉学习白名单** |
| write / edit 无分级器 | v1 定案: **分级只管 bash, write/edit 一律放行** (任务随机; bash 那道刹车已覆盖最具破坏性的一类)。可选收紧"可写工作区"留档, 不新增字段 (用 `project.path`) |
| **cwd 被误当访问控制边界** | 文档与 UI 措辞须明确: 项目绑定只给**默认落点 + 语义提示**, pi 的 bash 无 chroot/seatbelt, 仍可 `cd /` 或绝对路径读写 |
| **UIDVALIDITY 变更 → UID 游标整体失效** | 每轮读 `UIDVALIDITY` 与 KV 比对, 变更即重置**该账号**游标 |
| **Inbox 收到自己的回执 → 自触发** | **只 poll `INBOX`**, 绝不 poll `Sent` / Gmail `All Mail`: 本机 SMTP 发出的回执不落自己的 INBOX, 天然隔离 |
| **多 Inbox 同时收到邮件 → 回合叠加** | **全局串行**: 一次只跑一个远程回合, 其余 `queued` (在 `maxConcurrentTurns` 之外再加这层) |
| **Inbox 改项目绑定 → 历史线程 cwd 漂移** | 决定 12: 首封快照进 `mailbox_tasks.project_id`, 后续轮读列不读配置 |
| **项目目录被删 → pi spawn 静默失败** | spawn 前校验存在且是目录, 不过 → FAILED + 回执, 不 fire |
| app 未常开 / Mac 休眠 → 邮件无人接 | 运维前提: app 常驻 (+ 必要时 `caffeinate`); 启动时补 poll 一次 |
| 预设参数随服务商调整失效 | 预设只是**填充值**: host 可手改 + "测试连接"即时验证 + `lastError` 兜底 → **不改代码即可自愈** |
| 用户误用登录密码而非授权码 | 最高频踩坑点。`authNote` 写明"不是登录密码" + 官方帮助页深链 |

### 2.12 真机联调要点与已知限制

**邮箱准备** (一次性): 用**专用个人邮箱** —— **首选 QQ** (不要求 `ID`, curl 直连可用) 或阿里云个人版; 网页版开启 **IMAP/SMTP 服务**并生成**授权码** (授权码 ≠ 登录密码, 页面关掉就不再显示)。**不要用日常邮箱** —— agent 会按规则读信, 白名单外的信会被移入 Trash。

**投递格式** (关键判定): 主题 `[MGOX] <密钥> <任务摘要>` —— `[MGOX]` 与密钥**都只在主题里判定**, 放正文无效; **正文即 prompt** (纯文本, 不能空: 纯 HTML 会回执"请以纯文本发送")。**发完别先去收件箱点开看** —— 轮询只捞未读 (`UID SEARCH UNSEEN`), 手动点开会打上 `\Seen`, Inbox 直接看不见这封信。**信落进垃圾箱 = 静默无事** (只 poll INBOX 是鉴权主防线的前提)。**处理过的信在 QQ 里会变已读 = 正常现象** (curl 内置 `;UID=` 硬编码 `BODY[]`, 见 §2.9 约定 4)。

**多轮怎么做**: 在**回执邮件**上直接点「回复」—— 别改主题、别新建, 正文只写新指令。连做 3 轮看: 会话标题**跨轮稳定** (不出现 `[DONE] [DONE] …`)、prompt **不重复内嵌上一轮全文**、**续在同一会话**。⭐ **必测一格: 回合还在跑的时候再回一封** (发完等 5~10 秒, 直接对上一封再点回复补一句) → 两轮依次跑完各回一封, 串行位不卡死 (这正是 §2.10 第 1 条那条死锁的现场, 原先无任何覆盖)。**反例**: 新建一封只带 `[MGOX]` 不带密钥的邮件 → 被当新线程首封 → 密钥闸拦下 + 提示回执 (同地址 24h 一次)。

**其余联调面**: 拒收四路径 (白名单外 / 缺 `[MGOX]` / 密钥错 / 未配密钥) + 快捷加白 + 重投幂等 · 无人值守裁决 (投一封要求 `rm -rf` 的信 → 回执 `[MGOX][BLOCKED]` + 被拦命令确实没执行 + 其余步骤照跑) · 边界保护 (1:1 占用 / 账号删除保护 / 首封 7 天窗 / 项目目录被删 / 无项目回落 home / 停用保留绑定 / 关密钥闸不丢密钥 / 删除连带清理 / 全局串行)。

**已知限制与盲区**:

0. 🚨 **网易系 (163 / 126 / 188) 在当前版本上必然失败** —— 见 §2.9 的 curl 架构级硬限制。预设表 4 项里有 2 项开箱即废; 出路是换 QQ/阿里云, 或把 IMAP 通道换成 `openssl s_client` 管道。
1. **`curl 67` 的文案分不出「登录被拒」和「SELECT 被拒」** —— 两者都是 67, UI 统一写"认证失败, 检查授权码", 会把网易系的 Unsafe Login 误判成"授权码填错" (联调实际踩到)。临时替代: 看括号里的 curl 原文 (`Access denied` = 登录阶段 / `Select failed` = 登录过了)。已做: exit **78** 单独归类为"服务端未返回该邮件"; 根治要开 `-v` 抓服务端原话 (注意 verbose 会**明文打印凭据**, 必须走既有 `secrets:` 脱敏) 并把 67 拆成两类文案。
2. **没有「立即收信」按钮** —— `ChatStore.pollMailboxOnce()` 存在但未接 UI, 联调只能等轮询 (间隔设 15s 即可)。另: 编辑器里也**没有「打开最近会话」**入口 (Cron 那边有"任务日志"按钮)。
3. **`Authentication-Results` 头待确认** (决定 13 连带) —— 163/QQ **支持** SPF/DKIM/DMARC 发信配置, 但公开文档未说明收信时是否写入该头。联调时看一眼原始邮件头: 有则可作 v2 的免费第一层校验, 无则算了。**不阻塞**。
4. **Trash 行为 / 已读状态待现场确认**: 非白名单信应落在垃圾箱 (而非硬删); 过闸执行的信收信后应变已读 (未过闸的 5.1 之外保持原状)。

---

## 三、P10.3 — 会话级配置持久化

### 3.1 问题

会话缺配置记录: 每个会话用什么模型/thinking level/agent mode/bypass, 重启后全部回默认, 每次要重选。

### 3.2 方案

- **存储**: `sessions` 表加 `config TEXT` 列 (JSON blob, 一次 ALTER TABLE; 后续加字段不再动表结构): `{modelProvider, modelId, thinkingLevel, agentMode, bypass}`
- **写回**: `selectModel` / `setThinkingLevel` / 切 agentMode / 切 bypass 四处 (P9.1 后均为 ModelStore/ChatStore facade setter, 收口清晰) → persistOrNotify 风格写 session 行
- **恢复**: 选中会话 / 启动 load conversations → 反序列化写回 facade (setter 即为载入路径保留)
- **新会话**: 继承 `settings` KV 的 `lastSessionConfig` (每次变更顺手刷全局默认) → 重启新建也免选
- **边界 (v2 语义, 实装后修订)**: NULL config 会话**不跟随可变全局** (否则改 A 会污染所有未配置会话 — 实机 bug) — 显示/应用 **App 默认配置** (`app_default_config` KV, 来源 = probe 上报的 pi settings 默认, 每次启动刷新); 启动时历史 NULL 行**一次性回填** App 默认 (幂等只补 NULL); **被动浏览 (切会话) 永不写行** (曾试过"离开锁定", 反而把污染固化, 已废); 用户动作 (选模型/拨开关/新建会话) 才写穿自己行 + lastSessionConfig; modelId 已删除/不在菜单 → 保留当前模型仅恢复其余项
- **启动恢复链**: 选中会话自己的 config → App 默认 KV → last_session_config (首次运行兜底)

### 3.3 门禁

- 冒烟 (T-P10.3, 15 断言): 写穿落行 / lastSessionConfig 同步 / A-B 互不串扰 / 历史会话回填 / NULL 行切过去显示默认 + 被动浏览零写入 / 新会话落生快照独立 / apply 恢复 + 抑制不回写
- 双门禁照常: smoke ALL PASS + xcodebuild 零 warning

---

## 四、P10.4 — 定时任务级模型/模式配置

### 4.1 问题

定时任务 fire 只吃全局默认配置: 任务用什么模型/思考级别/模式档位不可指定 — 重活想跑 full + 高级模型、轻任务想跑 minimal + 便宜模型, 现在做不到。

### 4.2 方案

- **存储**: `scheduled_tasks` 表加 `config TEXT` — **直接复用 P10.3 的 `SessionConfig` JSON** (provider/modelId/thinkingLevel/agentMode; `askApproval` 不需要 — #17 无人值守恒开); NULL = 跟随全局默认 (老任务兼容)
- **编辑 UI**: ScheduledView 任务表单加三个选择器 — 模型 (数据源 `model.menuModels`, 含"跟随默认"项) + 思考级别 + 模式档位三档
- **fire 应用 (关键差异)**: 定时 fire 在后台跑, **只动 transport 不动全局** — fire 会话的 `transportFor(sid)` 创建后补 `updateMode(cfg.agentMode)` + `setModel` + `setThinkingLevel`; 用户主会话的全局状态零污染
- **P10.3 联动**: fire 日志会话行 stamp 任务配置 → 之后点开该会话, 会话配置恢复逻辑自动呈现"这个定时任务用的什么模型"
- **冒烟**: 带 config 的 task fire → mock transport 收到对应 setModel/updateMode; 无 config → 跟随全局 (现状不变)

### 4.3 门禁

- 冒烟: task config roundtrip; fire 应用链路 (mock 断言 lastMode/setModel); 无 config 回落全局
- 双门禁照常

---

## 五、P10.5 — 会话切换零阻塞 (增量重放 + 先切再渲染)

### 5.1 问题

切会话「点了没反应, 延迟后一波出来」: `appendEvent` 每写一条事件即失效重放缓存, 流过式的会话切过去必然全量重放 (SELECT 全部事件 + 逐条 JSON decode + tool_update 合并 + 全量排序), 全程同步主线程; 历史越长越卡。

### 5.2 方案

- **增量重放缓存**: `appendEvent` 写成功后增量维护 (message append / tool_update 原位 patch), 乱序才打标记惰性重排; 截断/删除仍失效。
- **先切再渲染**: 缓存命中同步上屏; 未命中先空态 + 在途镜像, `Task.detached` 经**独立只读连接** decode 后回主线程合并落地 (校验选中未变 + 代数防串台, extras 保留 decode 期间新增消息)。
- **渲染减负**: applySessionConfig 等值短路; syncWorkspaceContext 根目录去重。

### 5.3 门禁与实测

- T-REPLAY 4 断言 (增量 append / 乱序惰性重排 / tool_update patch / 冷切空态+后台落地) + T-PERF 分段计时 (只打印)
- 实测: 首切 1000 消息会话 同步部分 0.1ms (后台落地 22.4ms); 缓存命中切换 0.4ms; 历史会话切换 0.09ms/次

---

## 六、P10.6 — 长会话渲染与重放缓存上限

### 6.1 问题

P10.5 只把 decode 挪到后台, 未做窗口化 —— 长会话仍是「全量进内存 + 全量渲染」。成本拆三层:

| 层 | 现状 |
|---|---|
| L1 事件 decode | 已解 (P10.5): 缓存命中 0.4ms, 冷切后台 ~22ms/1000 条 |
| L2 视图构建 + 首帧布局 | **未解** — `messageBlocks` 用 `VStack + ForEach`, N 条即 N 个 `MessageBlockView` (每条内含 `MarkdownView` 的块解析 + 文本布局), 全部同步主线程 |
| L3 重放缓存无界 | **未解** — `replayCache` 无上限, 访问过的每个会话全量消息永久常驻 |

### 6.2 方案 (6a 已落 / 6b 待排)

- **6a LazyVStack**: `ChatView.messageBlocks` 的 `VStack` → `LazyVStack`, 把 L2 从 O(总条数) 降到 O(视口)。
- **6a 缓存上限**: `replayCache` 加访问序 LRU, 上限 `PersistenceStore.replayCacheLimit = 8` 个会话; 溢出逐出最久未用 (只丢缓存不改库, 下次读回落全量 SELECT)。清理由 `dropReplayCache` 单点做 (cache / 乱序标记 / 访问序 三处同源, 漏一处留悬挂键)。
- **6b 窗口化分页 (未实施)**: tail N=100 + 上拉续载。DB 侧 `ORDER BY seq DESC` 走 seq 游标, **数到第 N 条 `message` 行即停** (tool_update 在 ASC 序里必在宿主之后 → DESC 里必先出现 → 天然无孤儿 patch); `replayMessages(for:)` 保持全量语义不动, 全量消费方 (Scheduler 交接文件 / Knowledge 提炼 / side chat 轮计数 / Workspace touched paths) 零改动。估 260~330 行 / 5 文件。

> 6a 的定位是**先解决视口成本**; 分页 6b 的真正价值在内存与冷切常数, 不在卡顿 —— LazyVStack 之后条数已不影响渲染成本。是否做待拍板。

### 6.3 门禁与实测

- T-LRU 4 断言 (缓存会话数封顶 / 最久未用被逐出 / 最近读取保留 / 逐出后重读回落 DB 重建)
- 冒烟 ALL PASS + xcodebuild BUILD SUCCEEDED 零 warning

> **待实机验证**: `LazyVStack` 与 `.defaultScrollAnchor(.bottom)` 的配合 (初始是否「先停顶再跳底」)、滚入行的 `.transition` 是否误触发淡入、`nearBottom` 探针是否仍准。三项均属视图层, 冒烟覆盖不到。

---

## 七、今日验收清单

- [x] P10.3: 会话配置持久化落地 + 冒烟全绿
- [x] P10.4: 定时任务级模型/模式配置 + 冒烟全绿
- [x] P10.5: 会话切换零阻塞 (增量重放 + 先切再渲染) + 实测达标
- [x] P10.6a: LazyVStack + 重放缓存 LRU 上限 + 冒烟全绿 (**实机验证通过 2026-09-18**)
- [ ] P10.6b: 窗口化分页 (待定, 非阻塞)
- [ ] P10.1a: mcp-adapter 托管冒烟 (echo server 闭环)
- [ ] P10.1b: web-access + 博查 key 调用闭环
- [ ] P10.1c-e: 视当日进度 (c 需先接线 tool_execution_update)
- [x] P10.2: 设计定稿 + 十五项拍板 (本档 §2.5, 2026-09-18)
- [x] P10.2a-0: 补 `BashRiskEvaluator` 误放行洞 (实修六类: 四类参数洞 + `2>file`/`&>file` + `2>&1` 切段) + `ApprovalMode` 三档 (`interactive`/`autoAllow`/`autoJudge`) + `beginTurn(approvalOverride:)` 接线 (§2.6, 2026-09-18; 纯函数语料 31 危险 + 27 只读全绿)
- [x] P10.2a: 四表 + `MailTransport` 协议 (按账号实例) + `MockMailTransport` + `MailboxSentinelService` 骨架 (遍历 enabled 哨兵 + **全局串行**) + 鉴权四道闸 (首封密钥 / 后续轮 References 分叉 + 反馈分层) + 主题清洗 (剥 secret) / 正文清洗 (引用行截断) + 项目 cwd 解析 (首封快照 + 目录校验) + `modeOverride: .full` + `approvalOverride: .autoJudge` 接线 (2026-09-18; 冒烟 T-MAILBOX 15 项全覆盖)
- [x] P10.2b: 回执链路 — `AutoJudgeBlock` 提级 + `AgentTransport.autoJudgeBlocks` 协议暴露 + `MailboxReply` (状态机主题 / 结算聚合 / 正文组装) + 回合落定两处钩子 (`streamEnded` / `stopTurn`) 结算发信 + blocked 也回执 (2026-09-18; 冒烟 T-MAILBOX-B 12 条)
- [x] P10.2c: `MimeParser` (头/折叠/RFC2047 B+Q/multipart 递归取 text/plain/QP/base64/charset 含 GB18030) + `MailMessageBuilder` (出站 RFC822 + 76 列 base64 + multipart/mixed) + `CurlMailCommand` (argv 组装与 IMAP 输出解析纯函数) + `CurlMailTransport` (curl 进程封装, `CurlRunner` 可注入) (2026-09-18; 冒烟 T-MIME ①~㉟)。**真机联调未做** (等专用邮箱)
- [x] P10.2d: Settings 三块 (账号池 + 哨兵 + 最近拒收) + Keychain 凭据/密钥 + 测试连接 + 服务商预设表 (2026-09-18; 冒烟 T-MAILBOX-S 36 条)。**P10.2 四批 a/b/c/d 至此全部落地**; 剩余只有真机联调 (等专用邮箱)。代码不依赖 P10.1; 原 e 批次随决定 6 消解
- [x] P10.2e: **页面归位 + 命名体系** (2026-09-18, 用户: 「邮箱哨兵应该在 schedule 里面啊，你怎么放在了 settings」+「schedule里面的3种调度任务的命名都挺土的」) — ①**命名按触发源统一**: 定时→**Cron** / 哨兵→**Watch** / Sparse Agent→**Inbox**（旧名混了三个维度, 是"土"的根因）；页面**保留 `Scheduled`**（侧栏 + 页头；曾短暂改 `Agents`, 用户拍板改回）；`Sparse Agent` 退为概念统称 ②账号池 (连接/凭据) **留 Settings** (`MailboxAccountsSection`); **agent + 最近拒收搬到 Scheduled 页**, 与 Cron / Watch 并列 (`ScheduledView.EditorTarget` + 新 `SparseAgentEditor.swift` + `MailboxUI.swift` 共用小件) ③编辑器类型段选**扩到三档** Cron / Watch / Inbox（原先两档 → 从编辑器进不去 Inbox; 段选上移到 `editorPane` 顶部跨两侧共用, `activeKind` 由 target 派生, `selectKind` = 唯一落点 —— 任务侧切档只翻 `draftIsWaiting` 不动草稿, Inbox 档才换编辑器） ④顺手修掉 `kindPill` 靠字符串比较判类型的脆弱写法。域层零改动, 冒烟 522 PASS / 0 FAIL 与归位前一致; xcodebuild BUILD SUCCEEDED 零 warning
