# MangoX 合并 Roadmap（v2）

> 日期：2026-09-14。输入：上周赛道扫描四点结论（`docs/research-desktop-agent-landscape-2026-09.md`）+ 你的三个想法 + pi 0.85.1 实测能力边界（要点见文末附录与项目记忆「pi 集成事实」）。
> 拍板记录（2026-09-14）：第 0 批先修 4 缺陷 ✅；模型管理从 MangoX 目录从零开始、不做导入向导 ✅；Side chat + Away summary 提前、多模态移后、工具产图单独成批 ✅；隔离只做 worktree 不做容器 ✅；**第 3/4 批对换：Side chat + Away summary = 第 3 批，模型管理 + 权限模式 = 第 4 批** ✅。唯一遗留待拍板：key 存储位置（§1.7）。
> 本文取代同日早版 merged-roadmap：按你的七点重新组织，优先级重排，模型管理方向按"**MangoX 自管、不依赖 pi 侧**"重新设计（有一个新原语让这条路变干净了，见 §1.7）。

---

## 0. 一屏结论

| 你的点 | pi 层 | 成本 | 批次 |
|---|---|---|---|
| ①分层：隔离 → 编排 → 共享记忆（我们=并行有/隔离弱/记忆雏形） | L3 为主 | 大 | 第 7 批（分三步走） |
| ②Trace v2 ≈ LangSmith 三视图 | L3 自建 + L1 辅助 | 2 天 | 第 2 批 |
| ③权限模式选择器（现在还是开关） | **L2** | 1-1.5 天 | 第 4 批 |
| ④Side chat + Away summary（小而感知强） | **L1**（fork 原语）+ L3 UI | 1-1.5 天 | **第 3 批** |
| 想法 1：多模态（传图 + 气泡显示图片） | **L1** + L3 管线 | 2-2.5 天 | **第 5 批** |
| 想法 1 附：工具产图（image 块进气泡渲染） | L3 | 1 天 | **第 6 批（单独）** |
| 想法 2：状态显示强化（上下文占用等） | **L1** | 1.5 天 | 第 1 批 |
| 想法 3：模型管理 MangoX 自管（为接别的引擎铺路） | **L1**（`PI_CODING_AGENT_DIR`）+ L3 | 2-3 天 | 第 4 批 |
| （前置）4 个缺陷修复 | — | 0.5 天 | **第 0 批** |

排序逻辑 = 感知/成本比 + 依赖：**想法 2 最便宜且最可见，先做；②③④ 是你上周自己圈的高感知项，紧随；想法 3 是"以后接别的模型"的地基，和③同批（预设与模式同源）；想法 1 的管线最长放第 5 批；①最贵，拆成三步只先做第一层（隔离）。**

---

## 1. 七点逐项落位

### 1.1 分层：隔离 → 编排 → 共享记忆

赛道结论：真正的分野不是"能不能并行"，是**隔离 → 编排 → 共享记忆**三层。MangoX 现状：并行 ✅（10 会话并发 + 事件归属）、隔离 ❌（多会话共享同一工作目录，并行写文件互相踩）、共享记忆 🔶（知识库注入≈CLAUDE.md 层，但无跨会话沉淀）。

**只先做第一层（隔离），后两层缓：**

- **worktree 隔离**：一任务一 worktree + 分支。pi 侧完全不管（只认 cwd，切 cwd 需重启进程——我们已知约束）；但 `--session` / `--session-dir` 与 cwd 解耦，**"一 worktree 一会话 + 独立 session 目录"结构上成立**。成本大，需要先想清三件事：任务与项目的关系、worktree 清理策略、与知识库作用域的交互。→ 第 7 批。**已拍板：隔离只做 worktree，不做容器**（`sandbox/`/`gondolin/` 原语留在缓做单开，需要时再评估）。
- **编排**（看板 / Goal Mode / 任务流转）：缓。我们已有定时任务 + 迷你任务台（差异化），先不让看板稀释。
- **共享记忆**（跨会话沉淀）：缓。MemoryDistiller 已是雏形，等隔离落地后它的作用域问题才有答案（现在跨会话记忆反而会被并行会话互相污染——这也是先做隔离的另一个理由）。

### 1.2 Trace v2 ≈ LangSmith 三视图（第 2 批）

数据侧零缺口（P5.0.1 usage 已落库，`store.messages` 落库 replay + 实时同源）。照 LangSmith 语义做三粒度：

- **Messages**（轨迹层，现 v1）：think 默认折叠已有；补 **Turn 卡折叠**（回合级输入/输出摘要卡）与**工具调用分组行**（一轮 5 个 bash 折成一行）。
- **Turns**（结构层，新增）：每回合一张卡，扫结构不看全文。数据可借 pi 的 `turn_start`/`turn_end`事件真实化（`turn_end` 带 message + toolResults），不再靠派生猜测。
- **Details**（调试层，新增）：单 run 输入输出/耗时/token/错误——展开详情已有 usage 明细，缺"单 run"视图。
- **导出**：pi 原生 `export_html`（出 **HTML**，不是 Markdown）；Markdown 用 `get_messages` 自建（半天，可选）。

### 1.3 权限模式选择器（第 4 批）

现状确实只是个开关（askApproval）。做成四档，**按项目记忆**：

| 模式 | 映射 |
|---|---|
| Manual | 现状：审批 + 白名单 |
| Accept edits | edit/write 免审批，bash 仍审 |
| Plan | **只读**：pi 原生支持 `--tools read,grep,find,ls`（官方文档原话 "Read-only mode"）；进阶照官方 `plan-mode/` 示例（禁 edit/write + 只读 bash 白名单 + `Plan:` 步骤抽取 + `[DONE:n]` 进度） |
| Auto | 现状：无人值守 |

工程上 = spawn 参数加 `--tools`/`--exclude-tools`（`PiRpcTransport.swift:327` 参数位现成）+ 模式状态机 + 项目级记忆。与官方 `tools.ts`（`setActiveTools` 工具开关）/ `preset.ts`（model+tools+thinking 预设）同源——**所以它和模型管理放同一批**。

### 1.4 Side chat + Away summary（第 3 批）

- **Side chat**：借当前会话上下文侧问、不污染主线。pi 的 `fork`/`clone`（从当前会话分叉，原路径保留）正好是这个语义；UI 自建（`⌘;` 起侧栏小会话）。我们多会话架构现成，成本低。
- **Away summary**：离开回来一句话总结。pi 无对应物，但消息 + 时间戳就在本地（可配 `get_last_assistant_text`），纯自建半天。

### 1.5 多模态：传图 + 气泡显示图片（第 5 批）

pi 侧零缺口，缺口全在我们的管线：

- **入口**：`⌘V` 粘贴 + 拖拽 + 附件按钮（现状附件按钮只把 `@<路径>` 塞进 prompt 文本——RPC 下 `@file` 是 CLI 参数语义，模型只能自己 read）。
- **发送**：`prompt`/`steer`/`follow_up` 原生收 `images:[{type,data(base64),mimeType}]`。**坑：`images.autoResize` 不覆盖 RPC base64 → 必须自压**（≤1536 / JPEG q0.8）。
- **持久化**：`ChatMessage` 加 attachments；文件落 `~/.mangox/attachments/<sessionId>/`，**SQLite 只存路径+尺寸+mime，不要 BLOB**；会话删除连带清理（对齐现有 `removeSessionFile`）。
- **气泡显示**（你点名的）：用户消息气泡内缩略图（点开大图）；模型能力门控用 registry 里的 `input` 模态（想法 3 的字段，第 4 批先从 pi 目录读过渡）。
- **工具产出图**（已拍板单独成批 → 第 6 批）：`outputString` 现在把 `content` 块数组静默丢弃。第 5 批交付时只做"占位不丢"（"[图片 N 张]"）；第 6 批把 image 块转附件进气泡渲染（牵动 `ToolDetail`/`ToolCall` 值类型与序列化，成本 1 天，独立验收）。

### 1.6 状态显示强化：上下文占用等（第 1 批）

- **`get_session_stats` 一条命令给全**：`contextUsage{tokens,contextWindow,percent}`（压缩刚结束可能为 null，显示 `--`）、tokens 四路、**cost（pi 已算好，USD，别自算）**、消息/工具计数。
- **挂载现成组件**：`Views/BottomBar/BottomStatusBar.swift` 全仓无人引用（P3 文档明写"等真实指标源再挂"）——指标源现在有了；`AgentStatus` 九字段全齐。
- **流式实时刷**：`message_update` 顶层带累计 `usage`，现在只在 `message_end` 落一次 → 整回合 token/费用不动。
- **过程态**：压缩（`compaction_start/end`，含 150k→32k）/ 重试（`auto_retry_*`：attempt·maxAttempts·delayMs）/ 排队（`queue_update`）/ 落定（`agent_settled`）/ `extension_error`；控制按钮 `compact`·`set_auto_compaction`·`set_auto_retry`·`abort_retry`。
- 货币：显示 `$`（pi 价目表是美元，换 ¥ 制造误差）。

### 1.7 模型管理 MangoX 自管（第 4 批）——设计原则：真源在 MangoX，pi 只是第一个消费者

你的诉求：baseUrl / key / model 全部参数由 MangoX 管理，不依赖 pi 侧，便于以后接别的引擎。**早版方案（读改写 `~/.pi/agent/models.json`）作废**——发现一个更干净的原语：

> **`PI_CODING_AGENT_DIR`**（`docs/environment-variables.md:81`）："Override the config directory; default is `~/.pi/agent`"

即 pi 的 `models.json` / `auth.json` / `settings.json` 都从**可指定目录**解析。于是：

- **真源**：SQLite `models` 表（升级现有 `custom_models` 三字段表）：`provider / model_id / display_name / api_type / base_url / api_key / context_window / max_tokens / input_modalities / cost(四价+tiers) / thinking_level_map / compat / sampling_params / enabled / source`。**api_type 枚举先只放 pi 支持的四种**（openai-completions / openai-responses / anthropic-messages / google-generative-ai），这就是"以后接别的模型"的接口缝。
- **物化层**：spawn 时设 `PI_CODING_AGENT_DIR=~/.mangox/pi-config/`，把真源**物化**成 `models.json` + `auth.json`（key 建议存 Keychain，物化时写出、文件 0600——TODO 待你拍板）。**完全不碰 `~/.pi/agent`，零并发写冲突，用户手工配置不受影响。**
- **生效**：per-turn 进程架构天然支持"下回合生效"；回合内切换仍走 `set_model`（该模型须已在本次物化清单里）。
- **迁移**：现有 `custom_models` 三字段一次性迁入新表。**已拍板：不提供"从 `~/.pi/agent/{models.json,auth.json}` 导入"向导——MangoX 目录从零开始**，用户手工的 pi 配置留在原地、互不影响；以后要收编再手工加。
- **内置目录**：`get_available_models` 的全量目录仍作为只读基线展示，自定义条目按 `provider+model_id` 覆盖（沿用 P5.1 语义）。
- **第一个冒烟**：`PI_CODING_AGENT_DIR` 指向空目录 + 最小 models.json，验证目录模型出现在 `get_available_models` 且能 `set_model`——半天内可证伪。

---

## 2. 批次排期（已按 2026-09-14 拍板重排）

```
第 0 批  0.5 天   缺陷修复（4 个，正确性）—— 已确认先修
第 1 批  1.5 天   想法 2 · 状态显示强化：状态栏挂载 + get_session_stats + 流式 usage + 过程态
第 2 批  2 天     赛道② · Trace v2：三视图 + Turn 卡 + 工具行分组 + export_html
第 3 批  1-1.5 天 赛道④ · Side chat（fork）+ Away summary
第 4 批  3-4 天   想法 3 · 模型管理自管（SQLite 真源 + PI_CODING_AGENT_DIR 物化，从零开始）
                 赛道③ · 权限模式选择器（四档 + 按项目记忆 + Plan 只读）
第 5 批  2-2.5 天 想法 1 · 多模态：入口/自压/持久化/气泡缩略图（工具图只占位）
第 6 批  1 天     多模态附 · 工具产图：image 块转附件进气泡渲染（单独一批）
第 7 批  4-6 天   赛道① · 隔离：worktree（一任务一 worktree + --session-dir）—— 不做容器
缓做/单开         编排看板 · 共享记忆 · 容器化全量(sandbox/gondolin 原语) · 写回 ~/.pi 的兼容导出
明确不做          移动/云接管（与本地优先冲突）
```

**依赖链**：第 0 批修 `agent_end`/`agent_settled` 是第 1 批过程态的地基（同一套事件机）；想法 3 的 registry 字段（`input` 模态）被第 5 批的发送按钮门控消费（第 4 批 < 第 5 批，顺序成立）；权限模式的 Plan 档与模型管理共用"预设"数据结构（同在第 4 批）；隔离（第 7 批）定了作用域之后，共享记忆才值得动。Side chat（第 3 批）只用 `fork` 原语，不依赖第 4 批。

---

## 3. 第 0 批 · 缺陷清单（前置，半天）

1. **`agent_end` 就拆进程 = 腰斩自动重试**（`PiRpcTransport.swift:532-545`）。pi 语义：`agent_end` = 一次底层 run 结束（`willRetry:true` 时后面还有重试/压缩重试/排队后续），`agent_settled` 才彻底落定。现在两者同等对待立刻 `teardownProcess()` → 5xx 时重试刚要退避进程已被杀，UI 显示"完成"实际失败。
2. **非审批类扩展 UI 请求被无脑回 `"Allow"`**（`:600-606`）。`notify`/`setStatus`/`setWidget`/`setTitle` 是 fire-and-forget，不应回 response；`notify` 的消息被静默丢弃。
3. **`parseUsage` 丢掉 pi 已算好的 `usage.cost`**（`:639-651`）。
4. **工具卡标签错显**：pi 内置工具 = read/bash/powershell/edit/write/grep/find/ls，`kindFor`（`:708-720`）无 `grep/find/ls` → 全落 `default → .read`。

---

## 4. 待拍板（2026-09-14 后仅剩一项）

~~1. 第 0 批 4 个缺陷先修~~ ✅ 已确认
~~2. 要不要"从 `~/.pi/agent` 导入"向导~~ ✅ 不做，MangoX 目录从零开始
~~3. 工具产图单独成批~~ ✅ 第 6 批
~~4. 隔离只做 worktree 不做容器~~ ✅ 确认

1. **key 存储位置**：Keychain（推荐——真源不落明文，物化时写 0600 的 `auth.json`）还是 SQLite 明文？这是第 4 批开工前唯一要定的事。

**下一步**：第 0 批 4 个缺陷，随时可开工。

---

## 附录：依据索引

| 事实 | 位置 |
|---|---|
| `PI_CODING_AGENT_DIR` 覆盖配置目录（默认 `~/.pi/agent`）；`PI_CODING_AGENT_SESSION_DIR` / `--session-dir` | `docs/environment-variables.md:79-82` |
| pi 有意不内置 MCP/sub-agents/permission popups/plan mode/to-dos/background bash | `docs/usage.md:305-311` |
| 工具门控 flag 与只读模式（`--tools read,grep,find,ls`）、内置工具清单 | `docs/usage.md:208-218, 296-299` |
| `get_session_stats`（tokens/cost/contextUsage）、`compaction_*`/`auto_retry_*`/`queue_update`/`turn_*` 事件 | `docs/rpc.md:554-596, 859-1183` |
| `message_update` 顶层累计 usage；`agent_end.willRetry` vs `agent_settled` | `docs/rpc.md:885-911, 938-997` |
| `images` 入参；`images.autoResize` 覆盖范围（不含 RPC base64） | `docs/rpc.md:41-123` · `docs/settings.md:179-191` |
| `fork`/`clone`/`get_tree`/`get_entries`/`get_fork_messages`/`export_html`/`get_commands`/`set_session_name` | `docs/rpc.md:597-855` |
| 官方示例扩展（随包发布）：`plan-mode/`·`subagent/`·`sandbox/`·`gondolin/`·`git-checkpoint.ts`·`tools.ts`·`preset.ts`·`ssh.ts` | `examples/extensions/` · `docs/extensions.md:2946-3030` |
| 完整 `Model` 对象（cost+tiers/contextWindow/input 模态/thinkingLevelMap 三态） | `docs/rpc.md:1409-1430` · `docs/models.md:197-300` |
| MangoX spawn 参数位 / 扩展托管 / 会话绑定 | `mangox/Agent/PiRpcTransport.swift:327-346` |
| 状态栏组件留置未挂载 | `docs/P3-functional-design.md:78` · `mangox/Views/BottomBar/BottomStatusBar.swift` |
