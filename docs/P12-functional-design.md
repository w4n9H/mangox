# P12 — 引擎基线升级（pi 0.85.1 → 1.0）

> **这份文档只描述判定、契约与验收方式。** 调研过程与实测原始输出留在当天 daily log，这里只留结论与可复现的判据。
> **目标**：把 MangoX 对接的引擎基线从 **pi 0.85.1** 抬到 **pi 1.0.x**，并回答一个问题 —— **1.0 是大版本升级，对 MangoX 到底动了什么？**
> **基线**：本机实装 `pi 0.85.1`（`/opt/homebrew/bin/pi`，npm 全局装）。⚠️ boss 记忆中的「0.83」与之同属 0.8x；**0.83.0 的 RPC 契约与 0.85.1 逐字相同**（已下载 0.83.0 核对 `--thinking` 档位行与 RPC 命令集）⇒ **下面所有判定对 0.83 与 0.85.1 同时成立**，基线取哪个都不影响结论。
> **目标版本**：**`1.1.0`**（npm `latest`，2026-10-07；本机实装已同步升级）。初次调研的基线是 `1.0.2`；**P12.2 收口时按 boss「只兼容最新版 pi」的前置重核到 1.0.4** —— 1.0.3 / 1.0.4 的增量已逐条核过（§1.3），**对 MangoX 零影响**；**1.1.0 的增量已核过（§1.4），同样零影响**。中间跨过 0.86/0.87/0.99.0~0.99.2/1.0.0~1.1.0 共 16 个版本。
> **状态**：**P12.1 ✅ · P12.2 ✅ —— 均已落地并过门禁**（§五、§六 都是已实现记录）。
> **P13（codemode 接入）已于 2026-10-08 单独立项** —— 判定、契约、前置门与验收方式全在 **`docs/P13-functional-design.html`**；**本文不再持有 codemode 的任何结论**（保持单一来源）。

---

## 零、结论先行

**一句话**：**pi 1.0 对 MangoX 是中等偏安全的升级** —— 协议层（RPC 命令 / 事件 / 消息形状 / `models.json` schema）**零破坏**，但有两处必须处理：**① `--no-extensions` 的语义变了；② pi 的安装位置多了一条不确定路径**。

| 面 | 判定 | 依据强度 |
|---|:---:|---|
| RPC 命令集（33 条） | **零变化**（逐条比对 `.d.ts`，无增无减） | 强（类型定义 + 运行时代码） |
| 会话事件联合 | **零变化**（`agent-session.d.ts` 逐字相同） | 强 |
| `message_update` 的 JSON 改写规则 | **零变化**（仍剥 `partial`、仍给 `toolcall_start` 补 `id`/`toolName`） | 强 |
| 工具结果形状（`AgentToolResult`） | **零变化** | 中（文档 + 现有解析器兼容） |
| `turn_start` / `turn_end` | **两版都有**（不是 1.0 新增）；1.0 把 `turn_end` 升级为**可动作边界** | 强（类型 + `rpc.md` 表 + `agent-session.js` 转发点 + `json.md`） |
| `extension_error` | 两版**逐字相同**；⚠️ 1.0.2 的 `docs/json.md` **没有它的条目** | 强（`rpc-mode.js:260`） |
| `agent_before_settle` | **1.0 真新增**，但**只在扩展侧**（RPC 客户端收不到） | 强（0.85.1 全库 grep 为 0） |
| `models.json` / `auth.json` schema | **纯增量，完全向后兼容** | 强（typebox schema 字段级对比） |
| `agent_settled` 的 `aborted`（1.1.0 新增） | **纯增字段**；MangoX 不读 payload ⇒ 零影响（**有意不接**，信息冗余） | 强（`agent-session.js:689-691` + MangoX 代码） |
| `tool_execution_end` 的 `durationMs`（1.1.0 新增） | **纯增字段**；MangoX 原用墙钟自算（口径偏大）⇒ **已下沉为引擎值**（T15 ✅） | 强（`pi-agent-core@1.1.0/types.d.ts:491`；1.0.4 为 0 命中） |
| **`--no-extensions` 语义** | ⚠️ **破坏性** | **强（三源交叉 + 实测）** |
| **pi 安装位置** | ⚠️ **新增不确定性** | 中（官方安装文档；`install.sh` 原文待本机复核） |
| `--provider` 语义 | 变了，但 **MangoX 不传它** | 强 |
| 档位全集 | 两版都是 `off…xhigh, max`；**MangoX 曾缺 `max`**（**旧缺口**，非 1.0 引入）→ **P12.2 已补**（§6.1） | 强（pi-ai 源码 + 冒烟） |
| MCP / codemode / tool-search | 新能力，**本方案明确不接**（§七） | — |

**改动量级预估**：P12.1（必须改）≈ 3 处小改 + 1 条新告警通道；P12.2（顺手补齐）≈ 3 处；**不动架构**（per-turn 进程模型、审批桥、注入链路全部保留）。

**P12.2 实际改动量级（2026-10-07 回填）**：改 4 个文件（`AgentTransport` / `PiRpcTransport` / `smokeMain` / `en_values` + 生成的 `.strings`）+ 1 条新英文词条 + 22 条冒烟断言 + 2 处文档纠错（`README.md` / 本文件）。**架构零改动**；`settleTurn()` 是唯一被抽出的新函数（把既有落定主体从 `agent_settled` 里提出来共用，不是新逻辑）。

**P12.1 实际改动量级（2026-10-05 收口后回填）**：改 6 个文件（`PiRpcTransport` / `AgentTransport` / `ChatStore` / `ChatBottomBar` / `MemoryDistiller` / `CodexTheme`）+ 8 条新英文词条 + 约 40 条冒烟断言。**净新增文件数 0** —— 中途新建过 `mangox/Agent/PiVersionGate.swift`（127 行），**10-05 取消版本门控后整文件删除**。**架构确实一处未动** —— 这是本次最值得记的一条：上游跨 13 个版本，下游只动了"参数构造规则"与"失败可见性"。

**P12.3 基线复核（2026-10-08，boss 把本机 pi 升到 `1.1.0` 后）—— 结论：能正常使用（兼容性上**无需改动**）。** 1.1.0 **没有 Breaking Changes 段**；跨 1.0.2→1.1.0 唯一的破坏性变更（1.0.3 的 Azure provider 改名）MangoX **全库 0 命中**；`rpc-types.d.ts` / `resource-loader.js` / 内置扩展注册表 / 扩展 `hasUI` 语义**逐字相同**，RPC 命令集 **33→33**、会话事件名 **37→37**，`--help` 只多 3 行。并用**真进程**跑过 MangoX 的真实 spawn 参数（`get_state` success + `get_commands` 命中 `llama` + stderr 零行）。新增的两个事件字段（`agent_settled.aborted` / `tool_execution_end.durationMs`）都不构成兼容问题，详见 §1.4；后者**已下沉**（T15 ✅，2026-10-08 落地）。

---

## 一、pi 1.0 变更摘要（只列与 MangoX 有关的）

> 来源：`@earendil-works/pi-coding-agent` 的 `CHANGELOG.md`（1.0.2 包内），逐版精读 0.86.0 → 1.0.2。

### 1.1 破坏性变更（pi 自己声明的）

| 版本 | 变更 | 触及 MangoX？ |
|---|---|:---:|
| 0.86.0 | pi-ai provider 流输入 `Context` → `TranscriptContext`（自定义 provider 要改读法） | ❌ **不影响** —— MangoX 只用 `api` 适配器（`openai-completions` / `anthropic-messages`），**没有自定义 streaming 实现** |
| 0.86.0 | `ToolCall.arguments` / `ToolResultMessage.details` 收窄为 JSON 兼容值 | ❌ 不影响（MangoX 本来就按 `[String: Any]` 读） |
| 0.86.0 | `user_bash` 改为 **fail-closed** | ❌ 不影响 —— MangoX 的审批走 `tool_call` + `extension_ui_request`，**没挂 `user_bash`** |
| 0.87.0 | 删 `shouldStopAfterTurn`，改用 `finishTurn` | ❌ 不影响（host 侧扩展 API，MangoX 未用） |
| 0.87.0 | `SessionEntry` 联合新增 `ContextEditEntry` | ⚠️ **间接** —— 见 §3.7（MangoX 会解析会话 JSONL） |
| 0.87.0 | `SessionManager` 成为 provider context 唯一权威；赋值 `state.messages` 不再生效 | ❌ 不影响（MangoX 不碰 pi 进程内状态，只走 RPC + 文件） |
| 0.87.0 | `TurnEndEvent` 扩字段 / 新增 `AgentBeforeSettleEvent`；`agent_settled` 里请求的 run 被延后 | ⚠️ **间接** —— 见 §4.6（`turn_end` 的语义）与 §4.7（`agent_before_settle` 只在扩展侧） |
| **0.99.0** | **`--no-extensions` 连内置扩展一起关** | ✅ **打到** —— §3.1；**应对方式 10-05 已简化为无条件补参**（§五 P12.1b） |
| 1.0.0 | `--provider` 不带 `--model` 不再被静默忽略，改为报错 | ❌ 不影响 —— MangoX 只传 `--model provider/id`（**已核，见 §3.4**） |

### 1.2 能力性变更（不改也在，但可能值得用）

| 版本 | 变更 | 对 MangoX 的价值 |
|---|---|---|
| 0.86.0 | **prompt cache warming**（长工具轮次/空闲期保活缓存，cost-aware） | 省钱，但**默认行为**，MangoX 无需动 |
| 0.86.0 | **transcript-backed 系统提示/工具变更**（跨 resume 保留，仍命中缓存前缀） | ⚠️ 与 MangoX 的 `--append-system-prompt` 交互，见 §4.2 |
| 0.86.0/0.87.0 | Node 持久编译缓存 + 扩展编译器惰性加载 | **启动更快** ⇒ 缓解 MangoX「fork 回读要轮询」的老问题 |
| 0.87.0 | **per-model 图片缩放**（`inputLimits.images.resize`） | 可替代 `ImagePipeline` 的客户端压缩（§6.4） |
| 0.99.0 | RPC `prompt`/`steer`/`follow_up` 响应新增 `data.disposition` | 能准确区分「已接受 / 已排队 / 已处理」（§6.3） |
| 0.99.0 | `thinking_level_changed` 等在文档中补齐（**运行时 0.85.1 就有**） | **不接（有理由）**：它**只**由 `setThinkingLevel` 触发（`agent-session.js:2060`），而 MangoX 每次 `set_*` 后都回读 `get_state` ⇒ 信息必然重复、零暴露 → §6.6 |
| 1.0.0 | codemode `models.generateImages()`、`image()` 块 | ⚠️ 与 MangoX 的 `image` 工具卡渲染相关 —— 但 codemode **明确不接**（§七），故只是记一笔 |
| 1.0.2 | `samplingParamsByThinkingLevel` | 已支持写 `samplingParams`，可按档位细分（增强） |

### 1.3 基线复核：1.0.2 → 1.0.4（2026-10-07，P12.2 收口时）

> 前置是 boss 的「**只兼容最新版 pi**」⇒ 基线必须跟着 npm `latest` 走，不能停在调研当天。

- **`--help` 逐行 diff**：1.0.2（187 行）→ 1.0.4（191 行），差异**只有** `--tools` / `--exclude-tools` 的说明文字 + 新增 `--no-mcp`。**零新增 / 删除与 MangoX 相关的 flag。**
- **1.0.3 的破坏性变更**（Azure provider 改名 `azure-openai-responses` → `azure`）：MangoX 全库（`.swift` / `.md` / `.json`）grep `azure` = **0 命中** ⇒ **不涉及**。（用户手填 `models.json` 片段里的旧键属 §九 R4 的范畴，不是代码问题。）
- **1.0.4 的 `--tools` 语义变化**（支持 `*` 通配；"未以 `mcp__` 开头就保留 MCP 工具"）：MangoX 只传 `read,bash,write,edit`（`AgentMode.toolAllowlist`），**无 `mcp__*` 条目**；且 MangoX 不启 `builtin:mcp` ⇒ **行为不变**。
- **`--no-mcp`：核过，有意不加 —— 但理由于 2026-10-08 复核后改准。** 实现链：`dist/cli/args.js:163-165`（解析）→ `dist/main.js:634`（`disabledBuiltinExtensions: parsed.noMcp ? ["mcp"] : undefined`）→ 落在 `resource-loader.js:405-406` 那道 filter 上：
  ```js
  const extensionPaths = (this.noExtensions ? cliEnabledExtensions : this.mergePaths(cliEnabledExtensions, enabledExtensions))
      .filter((path) => !path.startsWith(BUILTIN_PATH_PREFIX)
          || !this.disabledBuiltinExtensions.has(path.slice(BUILTIN_PATH_PREFIX.length)));
  ```
  ⚠️ **两个开关不是「同一条不变量的两种写法」，覆盖面不同**：`--no-extensions` 只做「**不把 discovery 到的内置扩展加进来**」（显式 `-e` 仍生效 —— `--help` 原文 "explicit `-e` paths still work"），**挡不住有人显式写 `-e builtin:mcp`**；`--no-mcp` 的 filter 在 **merge 之后**，**连显式 `-e builtin:mcp` 一起摘掉**（但它只对 `builtin:` 前缀的路径有效）。
  ⇒ 对 MangoX **今天仍是不加**，理由换成**成本收益**：`extensionArguments` 只挂 `builtin:llama.cpp` + 审批桥 + 业务扩展，**从不传 `-e builtin:mcp`**，`-ne` 已足够覆盖；多挂一个开关的**真收益只有「显式表达 + 多挡一种没人会写的情形」**。**「永不连 MCP」这条安全立场已由 §七 + `--no-extensions` 表达。**
  ⇒ **但要记一条反面条件**：如果将来 `-e` 列表里开始出现别的内置扩展（**P13 的 `builtin:codemode` 就是**），这条「不加」就该重估 —— 那时 `-e` 列表变长，「显式声明边界」比「靠 `-ne` 顺带挡住」值钱得多。
- **内置扩展注册表 1.0.2 ↔ 1.0.4 逐字相同**（`dist/extensions/index.js`：`llama.cpp` / `codemode` / `tool-search` / `mcp`，仅 `llama.cpp` 非 replaceable）⇒ P12.1b 的 `builtin:llama.cpp` 契约**未变**。
- **`getSupportedThinkingLevels` 实现**（`pi-ai@1.0.4/dist/models.js:677-689`）与本次 R3 的结论一致（见 §6.1）。

### 1.4 基线复核：1.0.4 → 1.1.0（2026-10-08，boss 升级本机 pi 后）

> 触发是 boss 的「我更新了pi，现在是1.1.0了，你看看这个版本我能不能正常使用」。按「基线跟着 npm `latest` 走」的纪律立刻复核。
> **1.1.0 的 CHANGELOG 没有 Breaking Changes 段** —— 这是这个版本最重要的先行信号。

- **`--help` 逐行 diff**：1.0.4（191 行）→ **1.1.0（195 行）**，差异**只有 3 行**：`--tools` 说明下多一句 `Only +name/-name entries add to or remove from the defaults` + Examples 里多一个 `pi --tools +codemode`。**零 flag 增删。**
- **`--tools` 新语法（`+name` / `-name`）对 MangoX 零影响**：解析在 `dist/core/settings-manager.js:35-55`（`isToolModifier` = 以 `+`/`-` 开头），而 `sdk.js:151` 用 **`options.tools?.some(isToolModifier)`** 决定整份列表的语义 —— **只要有一个 modifier 就整份按增量处理，否则整份就是 allowlist（原样替换，即 1.0.x 的行为）**。MangoX 只传 `read,bash,write,edit`（`AgentMode.toolAllowlist`，无前缀）⇒ 走后者。**额外收获**：`getToolListError` 明确**禁止混用**（`"tool names cannot be mixed with +name or -name entries"`）⇒ 不存在"部分前缀被静默误解"的灰区。
- **`rpc-types.d.ts` 逐字相同**（477 行，`diff` 退码 0）⇒ **RPC 命令表 / 响应形状 / 扩展 UI 方法集零变化**。
- **RPC 命令集 33 → 33、会话事件名 37 → 37**（两版 `rpc-mode.js` 的 `case "x"` 与 `agent-session.js` 的 `type: "x"` 集合差均为空）⇒ 无新增 / 删除的命令与事件。
- **`--no-extensions` 的加载逻辑 `resource-loader.js` 逐字相同**；**内置扩展注册表 `dist/extensions/index.js` 逐字相同**（`llama.cpp` 非 replaceable，`codemode`/`tool-search`/`mcp` replaceable）⇒ **P12.1b 的 `-e builtin:llama.cpp` 契约未变**（§1.3 的 `--no-mcp` 纯冗余判定同样仍成立，R7 的前提没变）。
- **扩展 `ctx.hasUI` 语义双版逐字相同**（`core/extensions/types.d.ts:218-219` 注释原文：**"true in TUI and RPC modes"**；`runner.js` 的 `hasUI()` / `setUIContext` 片段 `diff` 退码 0；`rpc-mode.js:83` `createExtensionUIContext()` 仍在注真 context）⇒ **审批桥不受影响**（这条是本轮**唯一的"安全相关"核查项** —— 审批桥开头就有 `if (!ctx.hasUI) return undefined`，`hasUI` 若变 false 就是**静默放行**）。
- **真进程验证（不只是读源码）**：用 MangoX 的**真实 spawn 参数**（`--mode rpc --no-extensions --extension builtin:llama.cpp --extension ~/.mangox/extensions/mangox-approval.ts --tools read,bash,write,edit --thinking off`，另跑一遍不带 `--tools` 的常规档）跑 1.1.0 ⇒ `get_state` **success=true**、`get_commands` **命中 `llama`**、**stderr 零行**（⇒ 审批扩展**确实加载成功**）。探针留在 `~/tmp` 外的 `/tmp/pihelp/probe110.py`。

**1.1.0 新增的两处事件字段（都不构成兼容问题）**：

- **`agent_settled` 增 `aborted: boolean`**（`agent-session.js:689-691` 取 `_agentRunAbortRequested`，语义 = "这次落定是被 abort 触发的"）。**MangoX 的 `case "agent_settled"` 不读 payload**（`PiRpcTransport.swift:946-949` 只 `guard turnActive` + `settleTurn()`），且落定本体在 1.1.0 **无条件照常执行**（`_isAgentRunActive = false` 与 `aborted` 无关，只是字段值不同）⇒ **零影响**。**有意不接**：abort 本来就是 MangoX（用户点停止）发起的，信息冗余。
- **`tool_execution_end` 增 `durationMs?: number`**（**跨包**：`pi-agent-core@1.1.0/dist/types.d.ts:491`，注释原文 "Milliseconds `execute()` took, **measured with a monotonic clock**; **absent when the tool did not run**"；1.0.4 的同一行**没有**该字段）。**MangoX 原先是自己算的**（`Date()` 墙钟，从收到 start 到收到 end）⇒ **两者口径不同：引擎值是 `execute()` 本体耗时，原值含排队 / 流式 / 审批等待 ⇒ 偏大**。**已下沉（§八 T15 ✅，2026-10-08 落地）**：`PiRpcTransport.swift:936-937` —— `let engineMs = (dict["durationMs"] as? NSNumber)?.intValue`，`let ms = engineMs ?? 自算墙钟`。⚠️ **用 `NSNumber` 而非 `as? Int`**：契约是 TS `number`（不承诺整数），`as? Int` 会在小数上失败并**静默退回墙钟**（浮点形态被丢掉）。**失败分支（`isError`）当前不记时长** —— 与改造前一致，是有意边界（引擎在 catch 分支也给 `durationMs`，MangoX 尚未消费）。

> ⚠️ **跨包教训的第二次应用**：`rpc-types.d.ts` 里根本没有 `tool_execution_end`（RPC 原样透传 `toJsonEvent(event)`，见 `rpc-mode.js:266`），事件形状继承自 core 的 `AgentEvent` —— 而它在 **`pi-agent-core`** 包里。**又是在宿主包里查不到、往下钻一层才拿到权威定义**（同 R3）。

**环境侧观察（⚠️ 归因已修正，2026-10-08 下午）**：探针一度报 `Warning: Invalid settings file …: EEXIST: file already exists, mkdir '…settings.json.lock'`，且 `get_available_models` 读成 **0 个模型**。
**修正后的结论：这是我探针所在环境（WorkBuddy 宿主）注入的 fs shim 造成的 —— 不是 pi 的问题，也不是残留锁造成的。** 该环境设了 `NODE_OPTIONS=--require=…/node-language-shim.cjs` 与 `CODEBUDDY_BROKERED_FS_HOOK_ENABLED=1`（**代理文件系统调用**）⇒ pi 的 `mkdir` 锁被重复创建 ⇒ `EEXIST`。
**判据（可复现）**：加上 `env -u NODE_OPTIONS` 后重跑 `pi --list-models` ⇒ **零警告**，并正常列出用户的全部 **5 个模型**（deepseek `deepseek-flash` / `deepseek-v4-pro`；minimax `MiniMax-M2.7` / `MiniMax-M2.7-highspeed` / `MiniMax-M3`）⇒ **1.1.0 读本地配置完全正常**（这比"0 模型"那条观察强得多）。
**教训**：宿主环境变量会污染"引擎自己的告警"，把它变成**假阳性**。凡靠 stderr 做归因的判据，在本机都要先剥 `NODE_OPTIONS` 复核一遍，否则会把环境噪音当成引擎行为写进结论。`~/.pi/agent/*.lock` 是 pi 可自动重建的空目录，删掉无风险（已实测：删后跑 `--list-models`，跑完锁数 = 0）。

**顺带证实的 MangoX 侧既有缺口（P12.1a 只覆盖了一半，记入 §九 R8）**：`--extension` 指向**加载失败**的扩展时，pi **不退出、照常响应**，错误**只写 stderr**（实测：缺 `jiti` 依赖的 1.0.4 包报 `Failed to load extension …: Cannot find module 'jiti'`，而同一次 `get_state` 仍 `success`）。而 MangoX 的 `reportEngineSilence` 有 **`guard !engineFailureReported, !sawAnyRPC`**（`PiRpcTransport.swift:768`）⇒ **引擎只要说过话，这条 stderr 就永不上报**。⚠️ 该实测在宿主 shim 环境下取得，但失败根因是**缺依赖**（与 fs 代理无关），且 pi「扩展加载失败不退出」这条行为另由**源码**核实（`rpc-mode.js` 的 `loadExtension` 失败只记 error、进程继续）⇒ **结论不受环境影响**。

---

## 二、MangoX 侧耦合面清单（盘出来的全部）

> 判据：**凡是"逐字使用 pi 的字符串/形状"的地方都是契约点**。下表是全量清单，不是抽样。

| # | 面 | 位置 | 契约内容 |
|---|---|---|---|
| 1 | 二进制发现 | `PiRpcTransport.swift:100-110` | 硬编码 `/opt/homebrew/bin/pi` → `/usr/local/bin/pi` → 扫 `PATH` |
| 2 | 启动方式 | `PiRpcTransport.swift:116-127` | **断言「pi 是 node 脚本」**：解 symlink → `node <cli.js>` |
| 3 | spawn 参数 | 组装 `PiRpcTransport.swift:527-600`；扩展段见下 | `--mode rpc` `--session-dir` `--fork` `--session` `--no-session` `--tools` `--append-system-prompt` `--model` `--thinking`；**扩展段（`extensionArguments` `:183-197`）** = `--no-extensions` + `--extension builtin:llama.cpp` + 托管扩展。两条引擎路径共用该纯函数 |
| 4 | 配置目录注入 | `PiRpcTransport.swift:442-448` | `PI_CODING_AGENT_DIR` → `~/.mangox/pi-config`（仅自管模型 >0 时） |
| 5 | 下行 RPC | `:228` `prompt` · `:238` `abort` · `:361/:527` `get_state` · `:362/:528` `get_available_models` · `:530/:770` `get_session_stats` · `:371` `set_model` · `:380` `set_thinking_level` · `:397` `export_html` · `:907/:916` `extension_ui_response` | 8 种命令 |
| 6 | 上行事件 | `:793-1020` | 接：`agent_start` `agent_end(willRetry)` `agent_settled` `message_start/end/update` `tool_execution_start/update/end` `extension_ui_request` `extension_error`(P12.1a 补) `response` `auto_retry_*` `compaction_*` `summarization_retry_*` `queue_update`。**有意不接**：`turn_start`/`turn_end`（见 §4.6）· `bash_execution_update`（MangoX 不发 `bash` 命令 ⇒ 收不到） |
| 7 | 响应解析 | `:1211-1260` | `{type:"response", command, success, data}`；`get_state.model{provider,id}` / `get_available_models.models[]` / `get_session_stats.{tokens,contextUsage,cost}` |
| 8 | 扩展 UI 桥 | `:902-911` | `fireAndForgetMethods = {notify,setStatus,setWidget,setTitle,set_editor_text}`；其余用 `value:"Allow"`（`confirm` 用 `confirmed:true`）兜底 |
| 9 | 审批扩展 | `:131-212` | `pi.on("tool_call")` + `ctx.hasUI` + `ctx.ui.select(title, [...3 选项])` + 返回 `{block:true,reason}` |
| 10 | 工具名映射 | `:1105-1125` | `bash/powershell/read/grep/find/ls/edit/write/fetch/search/image/delegate` → `ToolKind`，未知 → `.other` |
| 11 | 工具结果解析 | `:1142-1177` | `{content:[{type:"text"\|"image",…}], details}` |
| 12 | 会话文件 | `:302-318` | `~/.mangox/pi-sessions/<uuid>.jsonl`；fork 产物名不可派生 ⇒ 靠 `get_state.sessionFile` 回读 |
| 13 | 会话 JSONL 解析 | `ChatStore.swift:1205-1241` | 按 `type=="message" && message.role=="user"` 数轮次做前缀截断 |
| 14 | 模型物化 | `ModelMaterializer.swift:30-129` | 写 `models.json`（`providers.<p>.{models,baseUrl,api}` + 模型级 `api/reasoning/input/contextWindow/maxTokens/cost/thinkingLevelMap/compat/samplingParams`）+ `auth.json` |
| 15 | 蒸馏进程 | `MemoryDistiller.swift:47-53` | 同 #3 的扩展段（**调用同一个** `extensionArguments`）+ `--no-session` + `--model` `--thinking` |
| 16 | 档位语义 | `AgentTransport.swift:115-150` | `ThinkingLevel` 枚举 + `supported(reasoning:map:)`（自称复刻 pi `getSupportedThinkingLevels`） |
| 17 | 模式 → `--tools` | `AgentMode.swift:35-64` | 极简档 `--tools read,bash,write,edit` |
| 18 | 预设 provider | `ProviderPresets.swift` | 自建 4 家 `deepseek/kimi/minimax/zhipu(GLM)` + `api` 适配器名（P13 砍库，原 8 家；`ollamaStyle` 能力保留给自定义端点） |

---

## 三、逐面判定

### 3.1 ⚠️ 破坏性：`--no-extensions` 语义变了（**必须改**）

**pi 侧三方证据（全部第一手）**：

1. **CLI `--help` 逐字**（实跑两版对比）：
   - 0.85.1：`--no-extensions, -ne  Disable extension discovery (explicit -e paths still work)`
   - 1.0.2：`--no-extensions, -ne  Disable extension discovery **and built-in extensions** (explicit -e paths still work)`
2. **源码**：`dist/extensions/index.js`
   - 0.85.1：`builtInExtensions = [{ name: "llama.cpp", factory: llamaExtension, hidden: true }]` —— 只有一个，且标 `hidden`（**不属于"发现"范畴**，故 `-ne` 关不掉）
   - 1.0.2：`[{name:"llama.cpp"},{name:"codemode"},{name:"tool-search"},{name:"mcp"}]` —— 四个，**都不再 hidden**
3. **CHANGELOG 0.99.0**：`--no-extensions` also disables the built-in extensions, including the llama.cpp provider. Load one explicitly with `-e builtin:<name>`.

**实测（RPC 探针，`get_commands` 看 `llama` 斜杠命令在不在）**：

| 配置 | `llama` 命令 | 结论 |
|---|:---:|---|
| 0.85.1 + `-ne` | ✅ 在 | 基线：`-ne` **不影响**内置 |
| 0.85.1 不带 `-ne` | ✅ 在 | 同上（hidden 恒载） |
| **1.0.2 + `-ne`** | ❌ **无** | **回归确认** |
| 1.0.2 + `-ne -e builtin:llama.cpp` | ✅ 恢复 | 修复路径确认 |

**MangoX 现状**：两条引擎路径都以 `--no-extensions --extension <mangox-approval.ts>` 起（现在统一由 `PiRpcTransport.extensionArguments` 组装）⇒ 上游升到 0.99+ 后，**两个进程都拿不到任何内置扩展**。

**影响面（诚实分级）**：

| 丢失的内置扩展 | 对 MangoX 的实际影响 |
|---|---|
| `llama.cpp` | ⚠️ **有影响，且条件明确**：它是 **provider**，被关掉 ⇒ `get_available_models` 里 llama.cpp 模型消失。**但只在"用户没建自管模型"时可见** —— 自管模型存在时 MangoX 会把 `PI_CODING_AGENT_DIR` 整个换掉（`PiRpcTransport.swift:442-448`），本来就看不到 `~/.pi/agent` 的内容。而 README 的官方上手路径恰恰是"**你自己装好 pi 并配好 provider/key**"（`README.md:108-109`）⇒ **这条命中的是"直接用现有 pi 配置"这一类用户**，不是边角 |
| `mcp` / `codemode` / `tool-search` | ✅ **无影响**：MangoX 目前完全不接这三样（§七），关掉等于维持原状 |

**修复方式是"无条件补参"（不是版本门控）—— 但这里有个实测坑，决定了修复的顺序**：

`-e builtin:<未知名字>` **是致命错误，不是警告**：

```
1.0.2: Error: Failed to load extension "builtin:nope": Unknown built-in extension: builtin:nope
0.85.1: Error: Failed to load extension "/private/tmp/…/builtin:nope": Extension path does not exist
```

⇒ 在 0.85.1（以及任何 < 0.99 的版本）上补这个参数会**直接把引擎打死**（旧版不认识 `builtin:` 前缀，当成文件路径）。
而 MangoX 当时**把 pi 的 stderr 丢进 `FileHandle.nullDevice`**（`PiRpcTransport.swift:505`）⇒ 用户看到的是"发了消息、什么都不发生"，**零可归因信息**。

⇒ 所以 §五 的 P12.1 里，**"让引擎死得响"排在"加哪个参数"前面** —— 前者是根因，后者是补丁。**这条顺序在 10-05 取消门控之后依然成立**：正因为失败会响（P12.1a 带 stderr 与退出码上报），"不兼容旧版"才是一个**可接受**的代价（见 §五 P12.1b）。

### 3.2 ⚠️ pi 装在哪儿：从"确定"变成"不确定"（**必须改**）

**pi 侧证据**：

- 0.85.1 的 `quickstart.md`：「**Pi is distributed as an npm package**」+ 唯一安装命令 `npm install -g`；卸载段还写明 curl 安装器「**uses npm globally**」⇒ **curl 装出来的 `pi` 也在 npm 全局 bin**（`/opt/homebrew/bin/pi`）。MangoX 的 `findBinary()` 对 0.85.1 **是完备的**。
- 1.0.2 的 `quickstart.md` 给了**三条**并列安装路径：pi.dev 安装器（`curl -fsSL https://pi.dev/install.sh | sh`，「pins all dependencies」）、npm 全局（明写「**does not pin transitive dependencies**」）、Nix flake。
- 1.0.2 CHANGELOG：`pi update` on global npm installations **now recommends migrating to the managed installation** from the pi.dev installer.
- 1.0.2 新增环境变量 `PI_PACKAGE_DIR`：「Override the package directory, **useful for Nix/Guix store paths**」。
- 1.0.2 **移除 `npm-shrinkwrap.json`**：「npm installations no longer pin transitive dependencies」—— 官方**在推动用户离开 npm 安装**。

**`install.sh` 原文（WebFetch 取得，⚠️ 标注为"待本机复核"，见 §九）**：托管安装根目录 = `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/install`，可执行入口按序落在 **`~/.pi/agent/bin`** / `~/.local/bin` / `~/bin` / `~/.bin` / `~/local/bin`，最后才考虑 homebrew。

⇒ **失败模式**：用户迁移到托管安装后，`pi` 落在 `~/.pi/agent/bin/pi` 或 `~/.local/bin/pi`。这两个**都不在 MangoX 的硬编码表里**；而 MangoX 的 `PATH` 兜底对 **Finder / Xcode 启动的 App 天然残缺**（代码自己注释了这点：`PiRpcTransport.swift:112-114`"Xcode 启动的 App PATH 不含 homebrew"）⇒ 结论 = **"引擎不可用"横幅**，而 pi 明明装着。

**修复动作**（两件，缺一不可）：
1. `findBinary()` 补齐托管安装的候选路径（含 `~/.pi/agent/bin/pi`、`~/.local/bin/pi`）。
2. **顺手治根**：探测时把「findBinary 找过哪些路径、逐条是否命中、最终选中哪个」报给 UI（**10-05 取消门控后不再报 `pi --version`** —— MangoX 里已无任何地方需要版本号，见 §3.1）。现在 `engineMissing` 只给一句"未找到 pi CLI"，用户无从自查（而 `README.md:108` 又明确要求用户自己装 pi）。

### 3.3 ⚠️ 启动方式断言「pi 是 node 脚本」（**要复核，建议加兜底**）

`PiRpcTransport.swift:116-127` 的 `launchSpec()` 做了两件事：`destinationOfSymbolicLink(piPath)` 解出真身 → 用 `node` 跑它。注释里的理由是硬理由（App 的 PATH 里没有 node）。

- npm 全局安装下**成立**：`/opt/homebrew/bin/pi` 是 symlink → `…/dist/bundle/cli.js`，是 JS。
- 已核：1.0.2 的 `install.sh` 产物**仍是 npm 包**（`node_modules/.bin/pi`），**不是编译的原生二进制**（`package.json` 里那个 `build:binary` 是另一条发布线）⇒ **假设大概率仍然成立**。
- ⚠️ **风险点**：托管安装的入口是一个**带 PATH 处理的启动器脚本**（原文有 "for pi's shebang" 字样）。若该入口是 **shell 脚本而非常规 symlink**，`destinationOfSymbolicLink` 抛错 → 代码回落到 `real = piPath`（`:122`）→ `node <shell脚本>` ⇒ **语法错误、进程即死**。而这条路径同样被 `nullDevice` 吞掉。

⇒ 归入 P12.1 的"死得响"一并解决；另加一条**启动自检**：spawn 后若 X 毫秒内没拿到任何 `response`，把 stderr 尾部升级成 UI 告警（§五）。

### 3.4 已核，**不受影响**的项（写下来是为了下次不用重查）

| pi 变更 | 为什么不影响 |
|---|---|
| `--provider` 不带 `--model` 从"静默忽略"变"报错" | MangoX **只传 `--model provider/id`**（`PiRpcTransport.swift:496`，`desiredModel = provider + "/" + modelId` 于 `:369`），从不单独传 `--provider` |
| 自定义 provider 的 `Context` → `TranscriptContext` | MangoX 不实现自定义 streaming，只用 `api` 适配器名 |
| `user_bash` fail-closed | 审批桥挂在 `tool_call` 事件上，不碰 `user_bash` |
| `--tui-mode` 默认翻成 fullscreen | MangoX 走 `--mode rpc`，无 TUI |
| `SessionManager` 成为 provider context 权威 | MangoX 不改 pi 进程内状态 |
| `--extension` 现在也接受 `builtin:<name>` | 纯扩展语法；MangoX 传的是真实文件路径（`~/.mangox/extensions/mangox-approval.ts`） |
| 0.99.2 MCP 工具名 `-`→`_` 归一化 | MangoX 不接 MCP |
| 1.0.0 `/login`、`/bug`、主题、剪贴板、Kitty 图片等大量 TUI 侧改动 | RPC 模式不经过 TUI |

### 3.5 `models.json` / `auth.json`：**纯增量，零改动**

**做法**：不靠文档（1.0.2 把 `models.md` 从 574 行砍到 205 行，字段表被搬走 ⇒ 靠文档 diff 会得出错误结论），直接比 **typebox schema**（`dist/core/model-config.js`）的字段名集合：

| schema | 0.85.1 | 1.0.2 | 结论 |
|---|:---:|:---:|---|
| `ModelDefinitionSchema` | 13 | 16 | **+`inputLimits` / `promptCache` / `samplingParamsByThinkingLevel`**，**移除 0** |
| `ProviderConfigSchema` | 11 | 11 | **逐字相同，零变化** |
| `ModelOverrideSchema` | 16 | 19 | 同上三项，**移除 0** |
| `compat.*` 字段 | 33 | 30 | **移除 `supportsAdditionalTools` / `supportsToolReferences` / `supportsToolSearch`**（全是 deferred-tools/tool-search 相关，MangoX 默认路径不涉及） |

⇒ **`ModelMaterializer` 写的 `models.json` 在 1.0.2 上照常可读**，物化层无需为兼容做任何事。`--tools` 的文档语义也没变（"Replaces the default selection with a comma-separated allowlist"，`cli.md:119-120`）—— 与 `AgentMode.swift:35-40` 的用法一致。

⚠️ 唯一残留：`compat` 现在**在 1.0.2 的任何 doc 页里都查不到字段表**（被移出 `models.md`）。MangoX 允许用户手填 `compat` JSON 片段 ⇒ **用户按老文档写的字段若被移除，会静默失效**。归 §六（诊断提示）。

### 3.6 RPC 协议层：**零变化**（本次调研最省心的结论）

| 检查项 | 方法 | 结果 |
|---|---|---|
| 命令集 | 从两版 `rpc-types.d.ts` 的命令联合抽 `type:` 常量 | 33 vs 33，**无增无减** |
| 命令形状 | 逐命令 diff 类型块 | **唯一差异**：`prompt`/`steer`/`follow_up` 的 `success:true` 响应新增 `data.disposition`（取值 `"started"` / `"handled"` / `"queued"`）—— **纯增量**，MangoX 这三个命令的响应走 `handleRPCResponse` 的 `default: break`（`:1014`），不会破 |
| 事件联合 | `dist/core/agent-session.d.ts` 的 `type:` 常量集 | **逐字相同**（含 `compaction_end`、`thinking_level_changed`、`entry_appended`、`session_info_changed`） |
| 扩展 UI 方法集 | 两版 d.ts 的 `method:` 枚举 | **逐字相同**：`confirm / editor / input / notify / select / setStatus / setTitle / setWidget / set_editor_text` |
| CLI 参数 | 实跑两版 `--help` 并 diff 全文 | **5 处差异**：`--provider` 说明、`--extension` 说明、`--no-extensions` 说明、`--tui-mode` 默认值、新增 `pi mcp` 子命令与 `META_API_KEY`。**MangoX 用到的 11 个参数全部原样存在**（`--thinking` 的档位列表逐字相同） |
| JSON 分帧 / 消息流改写 | `json.md` 对读 | `message_update` 仍剥 `partial`、仍给 `toolcall_start` 补 `id`+`toolName` ⇒ `PiRpcTransport.swift:639-641` 那条注释仍然成立 |

### 3.7 会话文件：**格式未变，但创建时机变了**

- **格式**：`session-format.md` 的版本号仍是 **v3**（0.85.1 与 1.0.2 相同）；`ContextEditEntry` 是 0.87.0 新增的**条目类型**（追加式），不破 v3。
- **时机（0.86.0 修复）**：*"Fixed new sessions being lost when pi exits before the first assistant response. **The session file is now created when the first user message is sent**"*。
- ⚠️ **对 MangoX 的意义**：侧问 fork 的产物路径靠 **spawn 后轮询 `get_state.sessionFile`** 回读（`:459-465`，10 次 × 700ms）。若文件推迟到首条 user 消息才创建，**回读窗口更靠后**。MangoX 在 fork 后立刻发首条消息，理论上仍落在 7s 预算内 —— 但这是**行为改变，必须实测**（§八 T3）。好消息是 0.86.0/0.87.0 把启动路径改快了（Node 编译缓存 + 惰性加载），净效应可能是正向的。

---

## 四、需要留意的语义变化（不一定改，但要知道）

### 4.1 `agent_settled` 仍是唯一的拆进程点

0.87.0 说 "Deferred runs requested from `agent_settled` handlers until all settled handlers finish"。MangoX **在 `agent_settled` 里拆进程**（`:759-781`）—— 这条改动约束的是"**扩展**从 settled 处理器里再起 run"，MangoX 的审批扩展不这么做。

⇒ **判定：不影响**。但这是 MangoX **最"贴边"的一条设计**（`P6.0①` 的核心不变量是"`agent_end` ≠ 结束"），1.0 之后要**保留实测**（§八 T4）。

### 4.2 系统提示现在是 transcript 的一部分

0.86.0/0.87.0 把系统提示与工具声明**持久化进会话文件**（首次请求写一条 `role:"system"` 且带 `sections`，之后用 `sections` 补丁 + `toolsAdded/Removed` 表达变更）。两处交互：

1. **对 `--append-system-prompt`（MangoX 的知识注入，`:492`）**：注入块会**落进 transcript**。MangoX 的注入是 **spawn 期定格**（改注入要 `restartEngine()`）—— 语义上仍然成立，但"注入块进 transcript"意味着**会话文件与注入内容耦合**：备份/删除会话文件会连带记忆。要实测"改了知识块后 resume 会不会出现新旧两份"。
2. **对 `ChatStore.snapshotLinePrefix`（`ChatStore.swift:1224-1241`）**：截断只认 `role=="user"` ⇒ 新增的 system 条目**不会被误计轮次**。✅ **安全**（这一点是特意核的：如果它按"是不是 message 条目"计数，就会把 system 条目算成轮次，快照边界整体错位）。

### 4.3 `message_end` 仍是权威值（未变）

`json.md`（1.0.2）明写 *"Buffer `delta` fields for a live display, but **replace reconstructed data with the completed content**… Replace the whole partial message with `message_end.message`"* —— 这正是 MangoX `rollMessageBoundary` 的做法（`:931-941`，把权威值随边界落定）。**无需改动。**

### 4.4 `tools` 白名单的作用域没变

`cli.md:128`（1.0.2）：*"Default enabled tools are `read`, `bash`, `edit`, and `write`… `--tools` replaces the whole selection."* ⇒ `AgentMode.minimal` 传 `read,bash,write,edit` 与 pi 默认集**完全相同**（`AgentMode.swift:37` 的注释"极简含 read/edit 的理由：盲写不可用"依然成立）。

### 4.5 1.0 顺手修好的"MangoX 正在吃的"问题

| pi 侧修复 | 对应 MangoX 现象 |
|---|---|
| 0.86.0 `--resume` 用 mtime 优先、渐进出结果 | MangoX 不走 `--resume`（用 `--session` 直挂），无关 |
| 0.86.0 修 "signal-terminated 本地命令被报成成功" | MangoX 的 `isError` 判定更可信（`:727`） |
| 0.86.0 **修 `EventStream` 排空的平方级 CPU** | 长会话下 pi 进程 CPU 降下来 ⇒ MangoX 满并发（10 进程）时机器负载下降 |
| 1.0.0 修 "transcript 里每条 assistant 消息保留两份渲染行"、渲染内存降 4/5 | pi 自身内存；MangoX 每回合拆进程，影响有限 |
| 0.99.2 修 "prompt 提交随会话长度变慢"（每 assistant 消息查一次目录） | 长会话首字延迟下降 |

### 4.6 `turn_start` / `turn_end`：**不是 1.0 新增**，但 1.0 改了它们的语义

> **起因**：boss 记得「1.0 新增了 `turn_start` / `turn_end`，看看是不是有用」。核了 —— **记忆不准确，但这一问有收获**。

**它们 0.85.1 就有**，三处证据：
- `docs/rpc.md:866-867`（0.85.1）的事件表里列着；
- `docs/json.md`（两版都列 `{"type":"turn_start"}` / `{"type":"turn_end", "message", "toolResults"}`）；
- `dist/core/agent-session.js:476/484`（0.85.1）就在转发。

而 RPC 模式是**无条件全量转发**（`rpc-mode.js:265` `session.subscribe(e => output(toJsonEvent(e)))`）⇒ **MangoX 一直在收它们**，只是落进 `default: break` 静默忽略。

**1.0 线真正改的是语义**（`CHANGELOG.md` **0.87.0** 段三条 + `agent-session.js:479-504`）：
- `turn_end` 从"通知"升级为**可动作边界**：扩展返回 `{entries:[...], continue:true}` 可在它之后**再跑一次 provider 请求**；
- `TurnEndEvent` **扩了必填边界字段**；新增 `AgentBeforeSettleEvent`（见 §4.7）；
- `ExtensionRunner.emit()` **不再接受** `turn_end`，host 改用 `emitBoundary(baseEvent, buildContext)`；
- 1.0.2 里 `turn_end` 要能解析出**持久化的 assistant entry ID**，否则发 `extension_error`（*"turn_end could not resolve the persisted assistant entry ID"*）；
- 继承来的 `shouldStopAfterTurn` 移除 → 改用 `finishTurn`（同属 0.87.0）。

**判定：不接（已在代码里写明理由 + 立了回归哨）。** 三条理由，按重要性：

1. **它不是回合结束**。MangoX 的拆进程点唯一是 `agent_settled`（P6.0①）。用 `turn_end` 拆 = 正是"腰斩自动重试"那个**已实证**的坑。
2. **1.0 把这条理由变强了**：既然扩展可以让引擎在 `turn_end` 之后继续跑，"`turn_end` 之后还有输出"现在是**正常**情况 ⇒ 更不能用它判结束。
3. **它带的信息是重复的**：`message_end` 已给权威消息 + usage（`rollMessageBoundary`），`tool_execution_end` 已给工具结果。`turn_end` 的 `message`/`toolResults` 只是**聚合视图**。

唯一可能的增量是 `RuntimePhase`（胶囊的轮次边界），而 `queue_update` 已够用 —— 收益 < 引入"多轮怎么显示"的 UI 语义成本。

**落地**：`PiRpcTransport.swift:1007` 的 `default` 分支补了逐条理由（原先是光秃秃的 `break`，事后看不出"不需要"还是"忘了接"），并加了一条**回归哨**冒烟断言 —— `turn_end` 一旦被接成 `streamEnded` / 拆进程信号，断言立刻变红。

### 4.7 `agent_before_settle`：**0.87.0 新增**（相对 0.85.1 是新东西），但**只在扩展侧**

`grep` 结果：0.85.1 的 `dist/` 与 `docs/` 里**完全没有**这个名字；1.0.2（引入于 0.87.0）出现在 `core/agent-session.js` / `extensions/types.d.ts` / `docs/extensions.md` / `docs/compaction.md`。

⚠️ **但它进不了 MangoX 的 RPC 流** —— 两版的 `docs/json.md`（客户端可见事件流）里**都没有**它，它是**扩展事件**（`pi.on("agent_before_settle", …)`）。

**判定：当前架构用不上，但值得记一条**：它是"落定**之前**"的唯一钩子，紧贴 MangoX 的拆进程点。若将来要在落定前做事（例如 P11.3 冻结的"教训回加"真要找时机），**这是正解** —— 但要通过 MangoX 自己挂的扩展去听，**不是** transport 层的事（transport 收不到）。

### 4.8 `extension_error`：两版都有、**1.0.2 文档里没有**，原先被静默丢弃

`rpc-mode.js:260`（两版**逐字相同**）：扩展处理事件时抛错 ⇒ `output({type:"extension_error", extensionPath, event, error})`。

两个反差：
- 它是 RPC 流的**一等事件**（`rpc.md` 事件表末行有它），但 **1.0.2 的 `docs/json.md` 里没有条目** ⇒ 字段形状只能读 `rpc-mode.js`（又一次印证"契约读类型/代码，不读文档"）。
- MangoX 原先落进 `default` **静默丢弃** ⇒ **引擎自己报的错没人知道** —— 与 P12.1a 同病，所以在同一批修掉。

**落地**：`case "extension_error"` → 复用 `extensionNotify(type:"error")` 上抛 8s 横幅（扩展抛错是可自愈的告警级，不是常驻状态，故**不**用 `engineDiagnosis`）。扩展名用 `extensionLabel(path:)` 取**目录名**而非 `index.js` —— 后者是所有扩展共用的入口名，报它等于没说。

---

## 五、P12.1 —— 必须改（3 项）

> **状态（2026-10-05）：三项全部落地。** 门禁：`scripts/smoke/run.sh` **ALL PASS / 830 条**（基线 797）；`xcodebuild` **BUILD SUCCEEDED，0 error / 0 warning**；本地化三道全绿（词表 601 条，`--check` / `scan_wiring --check` / `e2e_probe` 622 PASS）。
> **10-05 重要改动**：P12.1b 的**版本门控整体取消**（boss：「只需要兼容最新版本的 pi，不用管兼容问题」）⇒ 内置 provider 改为**无条件补参**，`PiVersionGate.swift` **整文件删除**。理由与代价见 §五 P12.1b。
> 落地过程里对初稿做了 5 处修正（3 处设计、2 处推迟），**逐条理由见下** —— 修正的原因比结论重要：其中「版本探测必须同步」与「上报不能走 8s 自清通道」两处，初稿的做法会让这一项**看起来做完了而实际没生效**。
> **另**：审计 §4.6 时发现同一族里还有两处空档（`turn_end` 缺回归哨、`extension_error` 被静默丢弃），一并补上 —— 它们不属于原定三项，但属于 P12.1a 的"不许静默"原则。

### P12.1a（根因）让引擎「死得响」：不再吞 stderr

**问题**：`PiRpcTransport.swift:505` 与 `MemoryDistiller.swift:54` 都把 `standardError` 指向 `nullDevice`；而 pi 的**致命错误全部只走 stderr**（实测：`-e builtin:nope` ⇒ stdout 空 + stderr 一行 Error + 退出）。⇒ 任何"参数不被这个版本接受"都会表现为**静默失败**：`send()` 里 `emit(.streamStarted)` 之后什么都没有。

**改法**：把 stderr 接进管道（保留尾部 N 行环形缓冲），并新增一条判据：

> **spawn 成功后 X 秒内既没拿到任何 `response`、也没收到任何事件 ⇒ 进程已死或参数不认 ⇒ 上报 stderr 尾部 + 退出码。**

这条**不依赖任何具体参数**，所以它对"`-e builtin:` 名字将来被 pi 改掉"这类**未来**的破坏同样有效 —— 这是把它排在 P12.1a 的理由（补丁治一次，通道治一类）。

**✅ 已落地（2026-10-04）**，三处与初稿不同，都有理由：

| 初稿 | 实际 | 为什么改 |
|---|---|---|
| 用 `extensionNotify(type:"error")` 上报 | 新增常驻 `ChatStore.engineDiagnosis` + 新 delegate 回调 `didFailEngineWithDiagnosis` | `extensionNotify` 走 `setExtensionNotice`，**8s 自清**。引擎起不来是**不可自愈**状态 —— 用户错过 8 秒就回到"什么都不发生"的原点，等于白报。判据是"这条信息要活到用户修好为止"，故挂在常驻位上；清空条件是"引擎真跑通一轮"（`streamStarted`），不是"进程在"（半死的进程照样在） |
| 容差取 8s（"沿用 `settleStatsTask` 的量级"） | `Tune.engineSilenceSeconds = 8` | 同值，但落成 token（冒烟钉住区间 3~30s），不再写死在逻辑里 |
| 判据用 `spawn 后无 response` | 判据用 `sawAnyRPC`（任一条**解析成功**的 JSONL） | 更强也更简单：pi 起手就发 `get_state`/`get_available_models`/`get_session_stats` 三条，任一条回来就说明进程活着；不必区分 response 与 event |

**两处位置选择（都有关键性，改回去会把这条判据变哑）**：

1. **`processDidExit` 里的上报必须在 `guard turnActive` 之前** —— 引擎在首个回合**还没开起来**就死时 `turnActive` 仍是 `false`，那条守卫会把唯一的线索吞掉。
2. **退出路径延迟 0.5s 再判** —— 进程退出时 stdout 缓冲区里可能还有没派发到主线程的 response，当场断言"一句话没说"会**误报**；看门狗路径（进程还活着）不需要这个延迟。

**有意不设会话守卫**：`didFailEngineWithDiagnosis` 的实现**没有** `sessionOf` 守卫（对比 `didReportSessionStats`）。引擎能不能起来是**全局事实** —— 探测实例上的失败同样必须让用户看见，否则"发消息没反应"又回来了。

### P12.1b 显式恢复内置扩展的 provider 能力（**无条件，不做版本门控**）

**做法**：给两条引擎路径的 spawn 参数**恒定**追加 `--extension builtin:llama.cpp`（`PiRpcTransport.spawnProcess` 与 `MemoryDistiller.run` 两处），抽成同一个纯函数 `PiRpcTransport.extensionArguments(hostedExtensionPath:enabled:)`。

**为什么不门控** —— 初稿写的是"仅在 pi ≥ 0.99 时追加"，**2026-10-05 boss 拍板取消**：

> 「我只需要你兼容最新版本的 pi，不用管兼容问题。」

门控**存在的唯一目的就是兼容旧版 pi**。既然只保证最新版，它就是纯复杂度 ⇒ 连带删掉整条版本探测链：
- ❌ 同步读入口 `package.json` 的 `version`
- ❌ 异步 `pi --version` 兜底探测 + 缓存
- ❌ `hidesBuiltinExtensions` 的 0.99 边界判断
- ❌ `PiVersionGate.swift`（**整文件删除**）

**顺带干掉了一整类时序问题**：初稿那套最麻烦的坑是"异步探测**赶不上第一次 spawn**"（`ChatStore.init` 只有一次 `refreshCapabilities()` ⇒ 探测实例一生只 spawn 一次，那一次拿不到参数就等于整轮运行都缺 llama 模型，**且零红灯**）。无条件之后这个问题**不存在** —— 参数不再依赖于任何运行时探测结果。

**代价（有意承担，写清在此）**：旧版 pi（< 0.99）收到 `builtin:llama.cpp` 会把它当**文件路径**找 ⇒ **直接起不来**（实测 0.85.1 报 `Extension path does not exist` 后退出）。这是**不兼容旧版的有意选择**，而不是疏漏。两点让它可接受：
1. **失败是响的** —— P12.1a 会带着 stderr 尾部与退出码报到 UI（"旧版静默死"才是不能接受的）；
2. 若将来真收到"我还在用旧 pi"的反馈，正确做法是**在引擎不可用的横幅里给出 pi 版本 + 一句"需要 1.0 以上"**，而不是把门控加回来 —— 门控把"版本"变成 spawn 参数的输入，会把"第一次 spawn"重新变成不可靠环节。

**只加 `llama.cpp`，不加另外三个内置扩展**（`codemode` / `tool-search` / `mcp`）—— 理由见 §七。

**⚠️ 这条现在更需要断言守**：门控在位时，"补内置 provider"是**版本判断的结果**；现在它是**恒定契约**，被人当成"与 `--no-extensions` 重复"顺手删掉的风险更高。故冒烟直接钉住 `extensionArguments` 的**整段顺序**（见 §八 T2）。

### P12.1c 补齐 pi 的托管安装路径 + 让"引擎不可用"可自查

- `PiRpcTransport.binaryCandidates(home:pathEnv:)`（纯函数，冒烟直测）候选表补 `~/.pi/agent/bin/pi` 与 `~/.local/bin/pi`；**顺序即优先级**：先既有硬编码（homebrew ×2），再托管安装 ×2，最后 `PATH` 扫描（去重，空段跳过）。
- `engineMissing` / 引擎起不来横幅补充：**找过的路径清单 + 当前判定结果**（逐条 ✅/·）。理由是 `README.md:108` 把"装 pi"定为用户义务 ⇒ App 必须让用户能自救。

**✅ 已落地（2026-10-04）**，两处与初稿不同：

| 初稿 | 实际 | 为什么 |
|---|---|---|
| 报告里带 `pi --version` | **不带**；改带**逐条路径的命中与否** + 一句"PATH 里没有就找不到托管安装以外的位置" | 版本号对"我该去哪儿找"这件事没有信息量；而 `engineMissing` 恰恰是**没找到二进制**的情形（此时版本无从谈起）。10-05 取消门控后，MangoX 里**不再有任何地方需要 pi 的版本号** |
| 登录 shell 探测（`$SHELL -lic 'command -v pi'`）作为"更稳的做法" | **未做（有意推迟）** | ① 覆盖的两条托管路径（`~/.pi/agent/bin`、`~/.local/bin`，**实测自 pi.dev 安装器说明**）已进候选表，Nix / 自定义 prefix 是长尾；② 它要引入一次**登录 shell 启动**（读 `.zshrc` 等 rc 文件 ⇒ 用户 rc 里的副作用会跟着跑）+ 缓存 + 失效策略，是一个独立的设计面。**留作独立项**，等出现"用户按文档装了却仍判不可用"的实证再做 |

**报告文案是 `L()` 包裹的**：`binarySearchReport()` **逐次现算**、绝不落存储属性 —— 文案要跟随界面语言，冻进实例属性就违反 L10n 的取词纪律（`scan_wiring.py` 正是在查这个）。

---

## 六、P12.2 —— 顺手补齐（**旧缺口，与 1.0 无关**，同批做）

> **状态：全部落地（2026-10-07），门禁全绿。**
> ⚠️ **落地时对原方案做了 3 处修正** —— 6.3 的**价值判断被推翻**（真正值得接的不是它写的那两条），6.2 的做法比原方案更进一步，6.4 由 boss 拍板定为**不做**。每条末尾都有「实际做法」。

### 6.1 ✅ `ThinkingLevel` 缺 `max` 档

- 现状（改前）：档位全集 = `off, minimal, low, medium, high, xhigh` —— **少一个 `max`**。
- 证据：**0.83.0 / 0.85.1 / 1.0.x 的 `--thinking` 与 `rpc.md` 三处都写着 7 档含 `max`** ⇒ 是 MangoX 自 P3.5 起的缺口，不是 1.0 引入。
- 症状（改前可复现）：`ProviderPresets` 给 DeepSeek V4.1 Flash / V4 Pro 写的 `thinkingLevelMap` 明确含 `{"max":"max"}` —— **但 `max` 在 UI 上永远出不来**（停靠点由 `ThinkingLevel.allCases` 驱动）⇒ 一行**死数据** + 用户拿不到 pi 明明支持的档位。
- **实际做法**：追加 `case … , max`（**只许追加在末尾**）—— `allCases` 顺序 = 滑轨停靠顺序，且已核与 pi 自己的规范序 `EXTENDED_THINKING_LEVELS`（`pi-ai/dist/models.js`）**逐字一致**。**无迁移风险已核**：档位落库落的是 `rawValue` 文本而非索引（`SessionConfig.thinkingLevel: String?` / `mailbox_sentinels.thinking_level TEXT` / 写入侧 `.rawValue`）。
- **R3 结案**（原为"不许照抄 `xhigh` 分支"的未知）：读 `pi-ai@1.0.4/dist/models.js:677-689` 的真实实现 —— `max` 与 `xhigh` **同规则**：
  ```js
  if (mapped === null) return false;
  if (level === "xhigh" || level === "max") return mapped !== undefined;
  ```
  ⇒ `supported()` 里把 `lv == .xhigh` 改成 `(lv == .xhigh || lv == .max)` 即**逐字复刻**。⚠️ `null` 剔除**优先于**该例外（给了键但值是 `null` ⇒ 不支持）。
- **连带**：`T22 有 map: …` 断言从 `[.off, .medium, .high]` 更新为 `[.off, .medium, .high, .max]` —— 该夹具的 map **本来就含 `"max":"max"`**，旧预期编码的是"枚举里没有这一档"，不是语义规则 ⇒ 属正当更新（不是把断言掰绿）。

### 6.2 ✅ 扩展 UI 的 `input` / `editor` 被误答

- 现状（改前）：`autoRespondExtensionUI` 对 `confirm` 给 `confirmed:true`，**其余一律给 `value:"Allow"`**。
- 问题：权威方法集（`rpc-types.d.ts:406-463`）里有 **`input`（要文本）** 与 **`editor`（要整段编辑文本）** ⇒ 对它们回 `"Allow"` 是**语义错答**（把一段文本当成 "Allow"）。当前不炸，只因为 MangoX 只挂自己的审批扩展（只用 `select`）—— 与 §七 拒绝 MCP 的"审批覆盖度"论证**同一类侥幸**。
- **实际做法**（比原方案更进一步）：**对所有非 MangoX 审批的扩展 UI 请求一律回 `{cancelled:true}` + 上抛 warning**（点名方法）。三条理由全部读源码定死：
  1. **形状合法**：`rpc-mode.js:84-86`（select / confirm / input）与 `:174-187`（editor）都把 `{cancelled:true}` 解析成"没答"（`select`/`input` → `undefined`，`confirm` → `false`）。
  2. **不回会挂死**：`editor` **没有 timeout**（其它三种有 `timeout?`）⇒ "干脆不回"**不是可选项**。
  3. **不发明同意**：MangoX 对第三方扩展的提问**没有任何依据**作答 —— 回 `Allow` 等于替用户点了同意。
  ⚠️ **连 `confirm` 也从自动 `true` 改成 `cancelled`**（有意改：resolver 是 `cancelled ? false : r.confirmed ?? false`，"否"的结果相同，但不再伪造"用户点了是"）。
- 形状抽成纯函数 `PiRpcTransport.unattendedExtensionUIResponse(id:)` 供冒烟直测（`sentCommands` 有意只存 type/id，看不到载荷）。

### 6.3 ✅ `prompt` 响应的 `disposition` —— **原方案的价值判断被推翻**

- 事实：`disposition ∈ {started, handled, queued}`，**0.99.0 引入**（已核 CHANGELOG 行号归属；0.85.1 里 grep 为 0），类型定义在 `agent-session.d.ts:167-168`。
- ⚠️ **原方案的理由是错的**。原写"`queued` 与 `started` 的区分能直接喂 `RuntimePhase`"。逐条核过实际价值：
  - `started` → **不动作**：权威的"开跑了"是紧接着的 `agent_start`（已在它上面发 `.phaseChanged(.streaming)`），这里再发一次是**噪音**。
  - `queued` → **不可达**：只有 pi 侧正在流式时才返回它，而 MangoX 在会话有回合在途时**根本不发 prompt**（`ChatStore.sendDraft` 的 `runningTurns` 守卫，P4.0.2 防双流）；队列显示另有权威的 `queue_update`。
  ⇒ **这两条都不值得接**。
- ✅ **真正值得接的是 `handled`，而它是个真缺口**：`agent-session.js:1522-1538` —— ① 以 `/` 开头的**扩展命令**被就地执行；② 扩展的 **input handler** 吃掉了输入。两种情形都**没有 run ⇒ 不会有 `agent_settled`** ⇒ 不处理就是：胶囊永远停在 streaming、进程不拆、`turnActive` 一直挂着。rpc-client 自己的注释也写着 "If the disposition is `handled`, no run started for this prompt, so don't wait for `agent_settled`"。
- **实际做法**：把 `agent_settled` 的落定主体抽成 **`settleTurn()`**（唯一实现：归位过程态 + 回拉会话统计 + 2s 兜底强拆），**两个调用点** = `agent_settled` 与 `disposition == "handled"`。`turnActive` 守卫照旧 ⇒ 两者重复到达不会双落定（有回归哨）。

### 6.4 ❌ 图片缩放下沉给 pi —— **boss 拍板：本期不做（2026-10-07）**

- 0.87.0 给了 `models.json` 的 `inputLimits.images.resize`（per-model，作用于附件 / `read` / 工具结果图片）。
- MangoX 现在**自己在客户端压**（`ImagePipeline.compressForSend`，≤1536px JPEG）。
- **决定：不做。** 理由：客户端压缩是**确定性的**（不依赖对端版本），下沉等于"把控制权交给一个跨版本会变的配置项"；换来的收益只是少一处代码。若将来出现"pi 侧压缩策略与 MangoX 打架"的**实证**，再谈。

### 6.5 ✅ 文档纠错：README 的"pi transcript 无 compaction"

- `README.md` 原写「**长会话上下文线性增长**：pi transcript 无 compaction，单会话建议控制在几十轮内」。
- **这是错的**：pi 的**自动压缩默认开启**（`docs/compaction.md:433-435`：`enabled: true`、`reserveTokens` 16384、`keepRecentTokens` 20k）；而且 MangoX 自己**正在渲染压缩横幅**（`compaction_end` → `emitCompactionBanner`）⇒ 代码与文案自相矛盾。
- **实际做法**：改成真实限制 —— 很长的单会话成本上升的根源是**反复摘要**（摘要本身是一次额外模型调用），并点明压缩期间 pi 会拒绝新 prompt。**这是对用户的错误承诺，不是措辞问题。**

### 6.6 ✅ 顺手核过：`thinking_level_changed` **不接**（并修掉 §1.2 的误标）

- MangoX 没接它。核 `agent-session.js:2049-2066`：**它只由 `setThinkingLevel` 触发**（函数体内唯一的 `_emit`）。
- 而 MangoX 每次 `set_thinking_level` / `set_model` 之后都回读 `get_state` ⇒ 该事件携带的信息**必然重复**，**零暴露**。
- ⇒ 原先 §1.2 表里把它标成"旧缺口（见 §6.2）"是**双重错误**（既不是缺口，交叉引用也指错了对象），已改。真正的缺口是 `max` 档本身（§6.1）。

---

## 七、明确不做（含理由）

| 不做什么 | 为什么 |
|---|---|
| **不接 MCP**（`builtin:mcp`） | ① **安全**：MangoX 的审批桥只拦 `bash`/`write`/`edit`（`SENSITIVE`），而 MCP 工具名是 `mcp__<server>__<tool>` ⇒ **hook 虽触发、但策略不覆盖** ⇒ **静默执行** ⇒ 开 MCP 等于给引擎一个不经用户同意的外部执行面（**要开必须先做 deny-by-default 的审批策略**，见 `docs/P13-functional-design.html`）。② 成本：MCP 会往系统提示里插 `mcp_servers` 段、改工具清单、加连接生命周期 ⇒ 与 MangoX 的"注入块由 App 全权决定"以及 per-turn 拆进程**直接冲突**（每个回合都要重连一次服务器）。要做必须单独立项 |
| **不接 codemode**（⚠️ **理由已于 2026-10-08 更正**；**本节起 codemode 的结论全在 `docs/P13-functional-design.html`**） | 原写「codemode 让模型跑 JS 调工具，**审批桥同样覆盖不到**」—— **这条是错的**：codemode 的嵌套调用走 `ctx.executeTool` ⇒ **完整 tool pipeline + session hooks**（`agent-session.js:384-386`；`codemode/tool.js:8-9` 明写 "`tool_call`/`tool_result` hooks … apply exactly as for direct calls"）⇒ **内层 `tools.bash`/`write`/`edit` 照常弹审批卡**；且 sandbox 禁 fs / 网络 / Node API ⇒ 影响面**只能经 tools**。⇒ **安全上可开**。它仍是**能力面扩张**（非升级适配）⇒ 立为 **P13**（`docs/P13-functional-design.html`） |
| **不接 tool-search** | 改的是**工具声明方式**（声明面，不是能力面）；MangoX 的工具清单由**档位白名单**决定，tool-search 的"模型自己搜工具"与"档位即能力边界"直接冲突 |
| **不改 per-turn 进程架构** | 1.0 没有任何东西要求它变；0.86.0/0.87.0 反而把启动改快了。热进程会引入状态串味与常驻内存 —— 现架构的代价（每回合重启）在变小，收益（隔离）在变大 |
| **不换成 SDK（`@earendil-works/pi-coding-agent` 的 in-process 用法）** | 那会把 Node 运行时塞进 MangoX 进程，逆转 `P3.0` 的"UI 与引擎边界"设计；且 0.87.0 的破坏性变更（`SessionManager` 权威化、`TranscriptContext`）**全部落在 SDK 面** ⇒ 换过去等于主动去踩本次唯一的一堆坑 |
| **不追 `--fork` 之外的新会话 API** | `switch_session` / `clone` / `get_tree` 等命令 0.85.1 就有，MangoX 只用 `--fork`；没有新的产品需求 |
| **不做 `disposition` 的全量状态机** | 只消费 `prompt` 的 `started/queued` 两态喂 `RuntimePhase`；不为它引入新状态机（`queue_update` 仍是主信号） |

---

## 八、验收方式（每条都可执行）

| # | 验收项 | 怎么做 | 期望 | 结果 |
|---|---|---|---|---|
| T1 | `--no-extensions` 回归 | RPC 探针发 `get_commands`，跑 `pi -ne` 与 `pi -ne -e builtin:llama.cpp` | 前者**无** `llama`、后者**有**（0.85.1 上两者**都有**） | ✅ 调研期实测（四组对照） |
| T2 | 扩展参数（原「版本门控」） | 断言 `extensionArguments` 的**整段顺序**；再用**最新版 pi** 跑全链路 | 恒为 `--no-extensions` → `--extension builtin:llama.cpp` → 托管扩展；业务扩展按序追加在最后；`builtin:llama.cpp` 只出现一次 | ✅ 纯函数已钉死（顺序 / 契约 token / 业务扩展追加 / 不重复）；**门控相关断言已随门控一起删除**（10-05）。全链路待启动 App（且需最新版 pi） |
| T3 | fork 回读时机 | 侧问开新会话（`--fork`），记录首条消息前后 `get_state.sessionFile` 的返回 | 产物路径**在 7s 窗口内**能回读到；失败则需把轮询窗口延长或改成"首条消息发出后再拉" | ⏳ 待启动 App（会话文件创建时机变了，见 §3.7） |
| T4 | `agent_settled` 仍可靠 | 跑一个带自动重试的回合（可注入瞬态错误） | **不腰斩**：重试跑完后才拆进程（`P6.0①` 不变量） | ⏳ 待启动 App；协议层事件联合逐字未变（§3.6） |
| T5 | 注入块与 transcript | 会话内改知识块 → `restartEngine()` → 同会话再来一轮 | 新块生效；**不出现新旧两份 system 段**打架 | ⏳ 待启动 App（1.0 起系统提示进 transcript，§4.2） |
| T6 | 快照截断 | 用**新版 pi 生成的**会话文件（含 `context_edit` / 新 system 条目）跑 `snapshotLinePrefix` | 轮次切点正确；补一条 `context_edit` 在途的用例 | ⏳ 需要 1.0 生成的会话文件（本机是 0.85.1） |
| T7 | `models.json` 仍被接受 | 造一个含 `thinkingLevelMap` + `compat` + `samplingParams` 的自管模型，在 1.0.2 上 spawn | 模型出现在 `get_available_models`；**pi 不报 schema 错** | ⏳ 需要 1.0 环境；schema 三张表已逐字段比对（§3.5） |
| T8 | 死得响 | 故意传一个非法参数（如 `-e builtin:nope`） | UI **必须在 8s 内**出现告警并带 stderr 尾部；**不允许静默** | ✅ 归因逻辑已由冒烟钉死（退出码 + stderr 尾 4 行 + 去重 + "说过话就不报"）；端到端待启动 App |
| T9 | 引擎发现 | 把 `pi` 移到 `~/.local/bin/`（临时、可复位） | 仍能发现；横幅能报出"找过哪些路径" | ✅ 候选表顺序/去重/空段 + 报告内容已冒烟钉死；真搬移待手工 |
| T10 | 门禁 | 按纪律评估后跑 `scripts/smoke/run.sh` + `xcodebuild` | 本批**动 State / 入口 / 断言** ⇒ **两道都要跑**；本地化三道因新增 `L()` 文案也要跑 | ✅ **全绿**（10-05 取消门控后重跑）：smoke ALL PASS 830 / xcodebuild BUILD SUCCEEDED 0 warning / gen_strings --check + scan_wiring --check + e2e_probe 622 PASS |
| T11 | 事件流审计（§4.6~4.8） | 对客户端可见事件全集做集合差；对 `turn_start`/`turn_end`/`bash_execution_update`/`extension_error` 逐个定"接/不接 + 理由" | 每个"不接"都有一条**可执行的理由**（不是"没做"）；`extension_error` 上抛；`turn_end` 有回归哨 | ✅ 集合差已做（两版 `json.md` + `rpc.md` 表 + `agent-session.js` 转发点）；`extension_error` 已接并冒烟钉死；`turn_end` 回归哨就位（`sink.events.isEmpty`） |
| T12 | `max` 档（§6.1） | 断言 `allCases` 全集/末位、`rawValue`、`displayName`；`supported()` 对 `max` 的四种 map 形态；**从 `ProviderPresets` 真数据**取 DeepSeek Flash 的 map 断言 `max` 可达 | 全集七档且 `max` 末位；`max` 与 `xhigh` 各自独立、显式 `null` 优先于例外；预设里那行 `{"max":"max"}` 真能出现在滑轨上 | ✅ 冒烟钉死（含"取不到夹具必须**变红**"的分支）；端到端待启动 App 看滑轨 |
| T13 | 扩展 UI 不瞎答（§6.2） | 断言应答形状 = `{cancelled:true}`（且无 `value` / `confirmed`）；投喂 `input` 请求，断言既应答又上抛 warning 并点名方法 | 不再回 `"Allow"`；`input` / `editor` 也**必须**应答（不回则永久挂死）；每次都留痕 | ✅ 冒烟钉死；第三方扩展的端到端行为待实测 |
| T14 | `disposition`（§6.3） | 投喂 `started` / `queued` / `handled` 三条成功响应 + 两个反例（回合未开 / 失败响应） | `started` / `queued` 不动作；`handled` 主动落定（`streamEnded` + idle）；随后重复的 `agent_settled` 不双落定；未开回合与失败响应都不落定 | ✅ 冒烟钉死；端到端待启动 App（需一个注册了 `/命令` 或 input handler 的扩展） |
| T15 | `tool_execution_end.durationMs`（§1.4，1.1.0 新增） | 断言两条分支：事件带 `durationMs` 时采用它、缺席时**回落**自算墙钟 | 采用引擎值（单调时钟测 `execute()` 本体，不含排队 / 审批等待）；**回落分支必须存在**（工具没跑就没有该字段） | ✅ **已落地**（2026-10-08）：冒烟 **5 条**断言钉死（整数优先 / 浮点不被丢弃 / 显式 `null` 回落 / 缺键回落 / 失败卡有意不记）；**造反例实测**：删掉 `?? 自算` ⇒ **3 条变红**（含既有那条「成功卡落 done + 时长」）|

> **T1~T9 里标 ⏳ 的那几条，本机的前置条件现已满足**（2026-10-08：本机 pi 已升到 **1.1.0**，不再是 0.85.1）—— 剩下的只是**启动一次 App 做手工回归**。**不要**把"逻辑已被冒烟钉死"当成"端到端已验证" —— 前者说明判据本身对，后者才说明它在真进程上成立。

---

## 九、已知风险与待实测

| # | 风险 | 现状 | 结法 |
|---|---|---|---|
| R1 | **`install.sh` 的路径结论是 WebFetch 二手** | P12.1c **已按它落地**候选表（`~/.pi/agent/bin/pi`、`~/.local/bin/pi`）—— ⚠️ **这两个路径至今仍是二手**（未 `sh -n` 也未人工读原文） | 取一次 `curl -fsSL https://pi.dev/install.sh \| sh -n`（只语法检查不执行）或下载后人工读，把托管路径坐实。**失败方向是安全的**：漏一条候选路径只会继续判"不可用"，不会误判"可用" |
| R2 | 托管入口可能是 shell 启动器而非 symlink | ⚠️ **未核**：若入口不是 node 脚本，`launchSpec()` 会用 `node <shell脚本>` 去跑 ⇒ 起不来（**被 P12.1a 兜住并报出 stderr**，不会静默）。10-05 取消版本门控后这一条**变简单了** —— 不再有"读不到版本 ⇒ 参数缺失"的次生影响 | 靠 P12.1a 兜住（死得响），再按实测决定是否给 `launchSpec()` 加"非 JS 入口 ⇒ 直接 spawn"的兜底 |
| R3 | ~~`max` 档位的 `supported()` 语义~~ | ✅ **已结案（2026-10-07）**：`getSupportedThinkingLevels` 不在 coding-agent 包里，而在 **`pi-ai`** 包（`dist/models.js:677-689`）—— `max` 与 `xhigh` **同规则**（`mapped !== undefined`），且 `mapped === null` 剔除优先 | 结（已按此实现并有冒烟断言）。⚠️ **教训**：跨包 API 要顺着 import 找下去，别在宿主包里查不到就猜 |
| R4 | `compat` 字段表从文档里消失了 | 用户手填的片段可能已含被移除的 3 个字段 | 在设置页的 `compat` 输入框旁给一句"字段表见 pi 版本对应的 docs"；更远可做"字段白名单校验" |
| R5 | `--no-extensions` 将来还可能再变 | 本次只覆盖到 1.0.2 | P12.1a 是唯一对新破坏 **结构性有效**的防线 ⇒ 它的优先级高于 P12.1b |
| R6 | 会话文件 system 条目导致文件变大 | 每个会话首条消息要落整份 prompt + 工具声明 | 观测即可；备份链路（`BackupService`）体积要留意 |
| R7 | **`--no-mcp` 的"纯冗余"判定有前提** | §1.3 的结论建立在"**MCP 就是内置扩展 `builtin:mcp`**"之上 —— 已核 1.0.2 与 1.0.4 的注册表逐字相同，且 `--no-extensions` 会挡住内置扩展 | 判别方法：看 `dist/extensions/index.js` 里还有没有 `{ name: "mcp", … }`（**1.1.0 复核：还在** ⇒ 判定仍成立）。⚠️ **原写的补救手段「届时才需要加 `--no-mcp`」是错的（2026-10-08 修正）**：`--no-mcp` 的实现**就是** `disabledBuiltinExtensions` 落在那道 **`builtin:` 前缀 filter** 上（`resource-loader.js:405-406`）⇒ **MCP 一旦不再是 `builtin:` 路径的扩展，`--no-mcp` 会与 `-ne` 同时失效 —— 它不是「解耦」情形的保险**。届时要在新形态里**重新找开关**，并从零验一遍 |
| R8 | **扩展加载失败在"引擎活着"时不可见**（P12.1a 只覆盖了一半） | 实测：`--extension` 指向加载失败的扩展时 pi **不退出、照常响应**，错误**只写 stderr**（1.1.0 上复现：缺依赖的包报 `Failed to load extension …: Cannot find module 'jiti'`，同一次 `get_state` 仍 `success`）。而 `reportEngineSilence` 有 `guard !engineFailureReported, !sawAnyRPC`（`PiRpcTransport.swift:768`）⇒ **引擎只要说过话，这条 stderr 永不上报**。⚠️ **与 1.1.0 无关**，是本次复核顺带证实的既有缺口 | 若审批扩展加载失败 ⇒ **审批桥静默消失**（`mangox-approval.ts` 开头就是 `if (!ctx.hasUI) return undefined`）⇒ 敏感工具（bash/write/edit）**静默放行 + 用户看不到**。风险低（扩展是 MangoX 自己写的固定文件，本次 1.1.0 实测加载成功）但非零。**修法候选**：spawn 后主动核一次"扩展是否挂上"（如让审批扩展注册一个可探测的标记），或对 stderr 中匹配 `Failed to load extension` 的行**独立上抛**（不走 `sawAnyRPC` 门） |

---

## 十、边界

- **与 P3（引擎对接）**：P3 定义了"UI ⇄ 引擎"的事件投影与 spawn 参数矩阵。P12 **不改投影**，只改**spawn 参数的构造规则**（P12.1b/c）与**失败可见性**（P12.1a）⇒ 是 P3 的下游补强，不是重写。
- **与 P6（会话/fork/导出）**：P6 的 `--session`/`--fork`/`export_html` 在 1.0 上参数逐字未变；P12 只碰**回读时机**（T3）与**快照截断的输入形态**（T6）。
- **与 P7（模型自管/模式档）**：`models.json` schema 纯增量 ⇒ P7 的物化层**零改动**；P7-M4 的 `--tools` 语义未变 ⇒ 模式档零改动。
- **与 P10（无人值守）**：`autoJudge` 的分级只覆盖 `bash`（`P10.2` 决定 8 B 案）⇒ 这**正是 §七 拒绝 MCP 的核心论据**：审批覆盖度决定了"能接什么能力"。P12 不扩张能力面，因此不动 P10。
- **与 P11（注入与记忆）**：`--append-system-prompt` 仍存在、注入仍是 spawn 期定格；1.0 让系统提示进 transcript（§4.2）⇒ **注入块现在会被写进会话文件**。P11 的"三载体"模型不变，但**备份/删除会话会连带记忆**这一点要在 P11 的文档里补一句。
