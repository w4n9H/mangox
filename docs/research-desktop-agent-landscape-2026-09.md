# 同赛道 Desktop Agent 客户端扫描（2026-09-11）

> 目的：为 MangoX 下一版选型提供参照。扫描对象 = AI coding / agent 桌面客户端（含并行编排、轨迹可观测性、隔离机制）。
> 方法：公开文档 + 2026 年社区对比文章交叉核对（来源见文末）。结论主观排序放在 §5。

---

## 1. 赛道地图（四种形态）

| 形态 | 代表 | 核心隐喻 | 隔离方式 |
|---|---|---|---|
| **工作台型**（workstation） | Claude Code Desktop、Codex App、Nimbalyst(Crystal)、Conductor、Emdash、Orca、Superset | 一个窗口管 N 个 agent + 内嵌 IDE 能力 | git worktree（多数）/ 容器（Sculptor） |
| **终端原生** | Claude Squad、cmux、Warp | tmux 会话管理 + worktree | worktree |
| **看板型** | Vibe Kanban | 任务卡 → 指派 agent → 列流转 | worktree |
| **可观测性/轨迹** | LangSmith（含 Studio） | 结构化 span 树 + 三视图 + time travel | — |

关键分野不是"能不能并行"，而是「**有没有隔离** → 有没有编排 → 有没有共享记忆」三层。
MangoX 当前处于「并行有（会话级）+ 隔离弱（共享工作目录）」的位置。

---

## 2. 逐个要点

### 2.1 Claude Code Desktop（Anthropic）
- **三标签**：Chat / Cowork（长任务）/ Code；Code 标签内每个会话独立 chat 历史 + 项目文件夹 + 代码变更
- **窗格自由编排**：chat / diff / browser / terminal / files / plan / tasks 任意网格拖拽排列
- **环境选择**：Local / Cloud（Anthropic 托管）/ SSH / WSL，发送前四选一（环境 / 文件夹 / 模型 / 权限模式）
- **权限模式选择器**（赛道共识）：Manual → Accept edits → Plan → Auto（安全分类器后台复核）→ Bypass permissions；**记住每个文件夹的选择**，Plan 仅本次会话
- **Diff 审查**：改动后出 `+12 -1` 统计指示器 → 点开 diff 视图（左文件列表 / 右变更）→ **行级注释**，多条注释一次性提交给 agent（Cmd+Enter）→ agent 按注释改；带 **Review code** 按钮做高信号自评
- **Browser 窗格**：agent 自验（起 dev server、截图、检查 DOM、点元素、填表单、修问题），页面操作有独立权限卡（Allow once / Always allow / Deny，按站点授权）
- **Checkpoints**：改动前自动快照，**Esc Esc 回退**
- **Plan mode**：只探索不修改，先给方案
- **Subagents**：独立上下文窗口，隔离冗长工作
- **Side chat**：`⌘;` 起侧边会话，借用当前会话上下文但不偏离主线（**很值得抄**）
- **Away summary**：离开后回来，给出会话级"你不在时发生了什么"
- **后台任务 + 移动推送**：长命令后台跑、完成推送；手机/网页可接管
- **Slash 命令 / skills / hooks / plugins / MCP** 分层扩展；`/context` 查看上下文占用、`/compact` 压缩
- **PR CI 状态条**：轮询 CI，支持 Auto-fix（读失败日志迭代）与 Auto-merge（全绿后 squash 合并），完成发桌面通知；PR 合并/关闭后自动归档会话

### 2.2 Codex App（OpenAI，2026 桌面版已并入 ChatGPT 桌面）
- **三栏**：左 = Projects / Threads / Automations（可按状态、项目、环境过滤）；中 = 对话 + 模型/沙箱/执行模式；右 = **Review 面板**（Diff 审查 + 集成终端 + Browser 预览）
- **执行模式**：Local（直接改工作目录）/ **Worktree**（`git worktree add` 到 `~/.codex/worktrees`，默认上限 15 个，超限自动删旧并留快照）/ Cloud（云端沙箱，回 PR）
- **Hand off**：会话可在 Local ↔ Worktree 之间迁移（自动完成 git 操作）
- **Hunk 级接受/拒绝**：diff 里按块选择性接受
- **Subagents**：各自上下文与沙箱，可互相 review 后回报父 agent（2026-03 上线）
- **Goal Mode**：给高层目标 → 自动拆子任务 → 顺序执行（2026-05）
- **Preview System**：复杂任务先给 2-4 个实现方案（速度优先 / 兼容优先 / 扩展性优先）让人挑
- **Plugins & Triggers**：自定义集成 + 定时任务（如夜间安全扫描）；持久记忆（偏好、技术栈、工作流）
- **一键部署**：Cloudflare / Netlify 等预览部署
- 平台：macOS / Windows / Linux 桌面 + CLI + IDE 插件 + Cloud + Slack/Linear 入口

### 2.3 Conductor / Crystal(Nimbalyst) / Superset / Orca / Emdash / Sculptor
- **Conductor**（macOS，专有）：一键为每个任务建 worktree，一块板上看所有 agent 与 diff，内置 review→merge→PR 流
- **Crystal → Nimbalyst**：开源跨平台同型，逐迭代 commit、应用内 diff review、内置 rebase/squash/merge；新版加 session 看板、WYSIWYG 编辑、任务跟踪、**扩展系统、原生 iOS**
- **Superset / Orca / Emdash**：agent 无关（25+ agents）、远程/云端 workspace、跨平台
- **Sculptor（Imbue，容器隔离路线）**：**每个 agent 一个 Docker 容器**，而不是 worktree —— 直击 worktree 的痛点："worktree 隔离文件，但隔离不了端口、node_modules、dev 数据库、容器名；6 个 agent 各跑 `npm run dev` 会抢 3000 端口，容器不会"。代价：社区小（~200 stars）

### 2.4 LangSmith（轨迹可观测性，对标 MangoX 的 Trace 视图）
- **对话优先的导航单元**：Threads → 单个 thread 的侧栏有 **三个视图切换**：
  - **Messages**（轨迹层）：每个 turn 一个块 = 模型回复 + 触发的工具调用 + 返回结果；块头元数据 = token 数 / 成本 / 模型名 / 跳转到 run 的链接；**think 块默认折叠；subagent 内联为一个动作（点进去嵌套视图）；多个并行/同类工具调用折叠成一行，展开看每条**；可**导出整条 thread 为 Markdown**
  - **Turns**（结构层）：每回合一张卡（输入 / 输出，展开折叠），不看全文也能扫结构
  - **Details**（调试层）：单 run 的输入输出、耗时、token、错误、metadata
- **Time travel / fork**（LangGraph runtime）：每个 super-step 都写 checkpoint → 可回退到任意点、改状态、从那里重新向前跑（原路径保留，新路径成为分支）；LLM/工具/interrupt 都真实重放
- 在线评估、LLM-as-judge、按 latency/token/error 过滤找长尾

---

## 3. 值得抄的交互清单（按 MangoX 价值/成本排序）

### P0 — 低成本、高收益（数据/能力已具备）
| # | 项 | 来源 | 为什么值 |
|---|---|---|---|
| 1 | **轨迹三视图**：Messages / Turns / Details 切换 | LangSmith | 我们只有"事件流"一种粒度：审计要全量、回看要结构、排障要单点 |
| 2 | **Turn 卡折叠**（回合级输入/输出摘要卡） | LangSmith | 长会话快速扫结构 |
| 3 | **工具调用分组行**（并行/同类折叠 + 展开） | LangSmith | 一轮里连发 5 个 bash 时轨迹会刷屏 |
| 4 | **轨迹导出 Markdown** | LangSmith | 归档 / 贴 issue / 交接 |
| 5 | **Diff 统计指示器 + 行级注释回流**（`+12 -1` → 评论 → agent 改） | Claude Code、Codex | 把"审阅"变成指令入口，我们的工具卡已有 diff 基础 |
| 6 | **权限模式选择器**（Manual / Accept edits / Plan / Auto）替代单一 askApproval 开关 | Claude Code Desktop | 底层已有（白名单/审批/无人值守），做成模式层即可，且**按项目记忆** |
| 7 | **Away summary**（离开回来一句话总结） | Claude Code Desktop | 我们有通知但缺"回来后补上下文" |
| 8 | **usage/cost 面板**（会话级 token + 估算成本） | LangSmith、Codex | P5.0.1 已采集 usage，只差显示 |
| 9 | **Side chat**（`⌘;` 侧问不污染主线） | Claude Code Desktop | 与我们的多会话架构天然契合 |

### P1 — 中等成本、架构性
| # | 项 | 来源 | 备注 |
|---|---|---|---|
| 10 | **worktree 隔离（一任务一 worktree + 分支）** | Codex / Conductor / Crystal / Cursor | 赛道共识；MangoX 现在多会话共享同一工作目录，并行写文件会互相踩 |
| 11 | **容器隔离**（替代/补充 worktree） | Sculptor | 解决端口/node_modules/DB 争用；成本更高 |
| 12 | **Subagent 内联可视化**（嵌套视图） | LangSmith、Codex、Claude Code | 依赖 pi 能力，已留待 Mangopi v0.2 schema |
| 13 | **Goal Mode / Plan Mode**（目标拆解、先方案后执行） | Codex、Claude Code | 我们现在只有"直接执行" |
| 14 | **Preview System**（先给 2-4 个方案再动手） | Codex | 高价值但需 UI 设计 |
| 15 | **移动/远程接管 + 云端执行** | Claude Code、Codex、Superset | 与我们本地优先定位冲突，可缓 |
| 16 | **会话生命周期**：按状态/项目/环境过滤 + PR 合并自动归档 | Codex、Claude Code | 我们侧栏是平铺列表 |

### P2 — 可选 / 差异化
- 计划与任务看板（Vibe Kanban / Nimbalyst）
- CI 状态条 + auto-fix / auto-merge
- Browser 窗格（agent 自验）
- 扩展市场 + hooks 管理 UI
- Checkpoint / rewind（Escape×2 + 快照回退）——需先想清与 pi transcript 的关系（pi 无 compaction，回退语义 = 截断/分叉 transcript）

---

## 4. MangoX 现状对照

| 能力 | MangoX | 赛道共识度 |
|---|---|---|
| 多会话并行 | ✅（上限 10、事件归属隔离） | 高（人人有） |
| 会话持久化 / 重启恢复 | ✅（`--session`） | 高 |
| 审批 + 白名单 | ✅（但只有开关，无模式层） | 高（模式选择器是标配） |
| 工具卡 + 时长 | ✅ | 高 |
| 轨迹视图 | ✅（v1，单粒度事件流） | 中高（LangSmith 三视图更细） |
| usage 采集 | ✅（未显示） | 高（大家都会显示成本） |
| 通知 | ✅（回合完成） | 中（还有 away summary / 移动推送） |
| 定时任务 / 哨兵 | ✅（**差异化**，Codex 的 Triggers 类似） | 中 |
| 迷你任务台 | ✅（**差异化**，未见同型） | 低 |
| 知识库注入 | ✅（≈ CLAUDE.md/AGENTS.md 层） | 高 |
| 扩展管理 | ✅（托管 + 启停） | 中高（skills/hooks/plugins 分层） |
| 工作区（文件树/git/预览） | ✅ | 高（Codex Review 面板类似，但缺 diff 注释流） |
| **worktree 隔离** | ❌ | 高（一任务一 worktree 是标配） |
| **Plan 模式 / Goal 模式** | ❌ | 高 |
| **Checkpoint 回退** | ❌ | 中高 |
| **成本显示** | ❌（数据已采） | 高 |
| **轨迹导出 / 三视图** | ❌ | 中高 |
| **Side chat** | ❌（有多会话，但不是侧问语义） | 中 |
| **Away summary** | ❌ | 中 |
| Subagent 可视化 | ❌（依赖 pi，待 Mangopi v0.2） | 中 |

---

## 5. 我的建议（有立场）

**下一步做三件，按此顺序：**

1. **轨迹视图 v2：三视图 + Turn 卡 + 工具行分组 + 导出 Markdown（P0，1-2 天）**
   理由：Trace 是 MangoX 目前最接近"差异化主菜"的东西，而数据侧零缺口（P5.0.1 已把 usage/model 落库）。
   三视图直接照 LangSmith 的 Messages / Turns / Details 语义做，等于一次性获得"审计 / 结构扫读 / 单点排障"三种粒度。

2. **usage/cost 面板 + Away summary（P0，半天-1 天）**
   理由：usage 已经落库，只差显示；成本按 DB 单价自算是我们相对"借价"的天然优势。
   Away summary 成本极低（用已有消息 + 时间戳生成一句话），但"回来知道发生了什么"的感知很强。

3. **权限模式层（Manual / Accept edits / Plan / Auto）（P0，1 天）**
   理由：底层能力（审批、白名单、无人值守）都已具备，缺的只是把散落的开关收敛成一个"按项目记忆的模式选择器"，
   这是所有同赛道客户端的标配姿势，也是 Plan 模式的前置。

**明确缓做：** worktree/容器隔离（P1 里最贵、也最伤架构，需要单独设计一轮：任务与项目的关系、清理策略、与现有 `--session` 和知识库作用域的交互）；移动接管与云端执行（与本地优先定位冲突）。

**值得留意的两个"非共识但可能对"的点：**
- **容器隔离（Sculptor）**：worktree 解决不了端口/dev DB 冲突，我们做隔离时值得直接跳到容器或至少给端口分配策略。
- **Time travel（LangGraph）**：比 checkpoint 更彻底 —— 从任意 checkpoint 改状态再往前跑，原路径成为分支。放在 MangoX 语境里就是"从某一回合分叉出新会话"，与现有 `--session` 迁移成本不高，但要先解决 pi transcript 无 compaction 的截断语义。

---

## 来源

- Claude Code Desktop 官方文档（code.claude.com/docs/desktop，三标签 / 窗格 / 权限模式 / diff 注释 / browser / PR CI）
- Claude Code 2026 功能纵览（25 项：subagents / checkpoints / plan mode / away summary / 后台任务 / sandbox）
- Codex App 文档与三方综述（三栏布局 / 三种执行模式 / worktree 上限 15 / handoff / subagents / goal mode / preview system / automations）
- Conductor vs Crystal vs Superset、多 agent 工具横评（worktree 模型、Nimbalyst 演进、Claude Squad、Vibe Kanban）
- Sculptor 容器隔离路线（developertoolkit.ai 对比文）
- LangSmith View traces（Messages / Turns / Details 三视图、subagent 内联、工具调用分组、Markdown 导出）
- LangChain "The runtime behind production deep agents"（time travel / checkpoint fork）
