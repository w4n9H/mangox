# P5 功能设计：会话轨迹视图（主菜）+ 正交入口改造 + 自定义模型

> 2026-09-11 立项（0.1.2 发版后当日设计对齐，计划下周开工）。
> 主菜 = **会话轨迹视图**（灵感来自 DeepSeek harness 轨迹透视，用户提供截图），
> 连带入口改造（Chat/轨迹 + 独立 Work 按钮）、自定义模型（治本目录与 API 名错位）、icns 清理。
> 门禁传统不变：typecheck 全绿 + 冒烟脚本全过 + 真机操作验证。

---

## 0. 架构事实（2026-09-11 实证，判断的前提）

1. **pi `message_end`（assistant）原生携带轨迹全要素**（0.85.1 实测）：
   `usage`（input/output/cacheRead/reasoning/totalTokens + cost 全拆解）、`responseId`（call id）、
   `model`/`provider`（消息级，中途换模型断不出错）、`stopReason`、`timestamp`。
   → **数据侧零缺口，轨迹视图是纯视图层工程**。
2. **MangoX 落库时把 usage 丢了**：events payload 仅 5 字段
   （`content/id/isStreaming/role/timestamp`）。根因：渲染走 `message_update` 增量流，
   `message_end` 只用于滚动消息边界（`PiRpcTransport.swift:460`），完整消息体从未被解析。
3. **工具卡已带时长与状态**：`toolCall` 事件含 `id` / `durationMs` / phase——工具行零新增数据。
4. **pi 对清单外模型 id 的 fallback 语义**（0.85.1 `buildFallbackModel` 源码实证）：
   **克隆该 provider 默认条目的全部元数据，仅换 `id`/`name`**。推论：
   - API 请求层可用（baseUrl/api/compat 照搬），同厂商同家族模型无感；
   - `contextWindow`/`maxTokens`/成本价**继承默认条目**（新模型差异大时 compaction/成本不准）；
   - provider 本身必须在 pi 目录中存在，否则报错（全新厂商走不了透传）。
5. **chat/trajectory 与 work 是正交概念**（用户拍板）：胶囊管主区底档，Work 是独立开关，
   互不干涉对方状态。

---

## 1. P5.0 会话轨迹视图（主菜）

### 1.1 动机

轨迹不是日志，是**可回放的结构化产品**。对话视图给人读（自然语言流），
轨迹视图给调试/审计读（结构化事件流 + 每事件元数据）。参照 DeepSeek harness：
Duration / Turns / Calls 摘要 + 类型化事件行 + 右侧元数据列（call id / 状态 / 成本）。

### 1.2 数据层：只差「接住」（P5.0.1）

- **捕获点**：`message_end` 的 assistant 分支（现在只做 `rollMessageBoundary()`）——
  从 `dict["message"]` 取 `usage` / `responseId` / `model`，挂到滚动边界前的最后一条
  assistant `ChatMessage`；
- **落库**：events payload 本来就是 JSON 直存 → 字段加进 `ChatMessage`（optional）后
  **零 schema 迁移**，replay 自动带回；
- **存量数据**：不做兼容（用户拍板：未进入生产力，旧数据可弃）——字段本来就 optional，
  旧消息无 usage 自然不显示，**零额外工作**；
- **边界**：手动停止 / 异常中断时 `message_end` 可能不来 → 该消息 usage 为空，轨迹行
  显示时长（有）但不显示 token（无），不阻塞；
- **成本采集这次做，显示后置**（用户拍板：单位/展示优先级不高）——payload 直存免费，
  以后显示不用翻旧数据。

### 1.3 视图层 v1（P5.0.3）：摘要头 + 三色事件行

**入口**：TopBar 胶囊切到「轨迹」（见 §2）。

**摘要头**（本会话聚合，从落库数据算）：
- **Duration**：回合时长合计；**Turns**：回合数；**Calls**：工具调用次数；
- 成本列暂不显示（数据已采集，后置）。

**事件列表**（读落库 replay 数据，`USER / ASSISTANT / TOOL` 三色行）：
- USER 行：prompt 全文（轨迹视图不折叠）；
- ASSISTANT 行：折叠为首句 + 右侧元数据（时长 / token 数），展开看全文；
- TOOL 行：工具名 + 参数摘要 + `durationMs` + 状态徽章（复用 toolCards phase 映射）；
- 每行可展开；对话视图管「读」，轨迹视图管「查」。

**实时性（同源免费）**：轨迹视图消费同一个 `store.messages` / `liveTurns`（`@Published`），
对话视图的变化轨迹视图同帧可见，无需额外刷新机制。形态差异是刻意的——**轨迹行是事件
语义，事件没落地不成行**：
- AI 回复生成中 → 不出 ASSISTANT 行，行尾一行「AI 回复生成中」+ 旋转弧占位；
- 工具执行中 → TOOL 行状态徽章实时翻转（`running → ready`）；
- 消息落定 → ASSISTANT 行成型（首句 + 元数据）。
- **不做逐字打字效果**（有立场）：那是「读」的体验，属于对话视图；轨迹的实时反馈 =
  行级出现/状态翻转，粒度粗一级但足够表达「活着、在推进」。

**明确不做**（防范围膨胀）：
- 逐字流式打字效果（行级出现 + 状态翻转就是轨迹的实时反馈，见上）；
- **三泳道时间条（Input/Model/Tools）→ 无限期延后**（用户拍板：优先级不高，不做可接受）。
  设计备忘留档：工作量约 200 行 + 半天边角，无技术依赖；卡点 = 粒度——harness 是单次 run
  一条轴，MangoX 会话跨天多回合，全局轴长会话不可用，若将来重启按「回合级小条嵌入事件
  组头部」方案（粒度与单 run 同量级，色块可读性等价）；
- 子代理 CONTEXT 事件 → pi 无子代理概念，等 **Mangopi v0.2** trajectory schema 定稿后对齐；
- 跨会话聚合分析。

### 1.4 分期

| 阶段 | 内容 | 量级 |
|---|---|---|
| P5.0.1 | usage/responseId/model 捕获落库 ✅ 已实现（2026-09-11）：`MessageUsage` 模型（token 五分量 + model/responseId）+ `ChatMessage.usage` optional 字段（JSON payload 直存零迁移）；`AgentEvent.messageFinalized` 搭载 usage（挂在边界最后一个落定块——同次调用的 think 块在前文本块在后，仅 think 时 think 拿）；`message_end` 时解析、`message_start`/agent_end/进程异常退出传 nil；冒烟 T11 共 5 项断言（数值捕获/归属规则/旧格式兜底），51 项全过 | ✅ 门禁全绿 |
| P5.0.2 | 入口改造：`capsuleMode` + TopBar（见 §2） | 半天 |
| P5.0.3 | 轨迹列表视图 v1（摘要头 + 三色事件行） | 1-2 天 |
| （backlog） | 三泳道时间条 `TrajectoryLaneView`——**无限期延后**（用户拍板，见 §1.3 备忘） | — |

---

## 2. 入口改造：正交双开关（P5.0.2，用户拍板零耦合）

### 2.1 拍板记录

> 初版方案 A 为三态互斥枚举（`.chat/.trajectory/.workspace` + lastCapsuleMode 记忆），
> 用户纠正：**chat/trajectory 与 work 是两个独立概念，不应有关联**——
> 不管底档是 chat 还是轨迹，都不影响打开工作区。终版 = 正交双开关。

### 2.2 终版状态模型

```swift
enum CapsuleMode { case chat, trajectory }
@Published var capsuleMode: CapsuleMode = .chat   // 新：主区底档
@Published var workspaceVisible: Bool = false     // 原变量原语义，零迁移

// 主区渲染（ContentView 现有 if 分支改一行）
workspaceVisible ? WorkspaceView
                 : (capsuleMode == .trajectory ? TrajectoryView : ChatView)
```

### 2.3 交互规则（两条，无特例）

1. **Work 开关完全独立**：任意底档下都能开/关工作区；开关只动 `workspaceVisible`；
2. **胶囊只管底档**：工作区开着时点胶囊，**高亮切换但主区不动**（底档在后台换好，
   关掉工作区自然露出新档）——胶囊高亮本身就是反馈，不存在死点，无需 lastMode 变量。

### 2.4 TopBar 形态

- 胶囊：`Chat / 轨迹` 二档互切（原 `Chat / Work` 胶囊同位置同形态）；
- Work：右上角**独立图标按钮**（folder 类 SF Symbol，品牌橙描边高亮激活态），
  项目会话不可用时照旧灰掉。

---

## 3. 自定义模型（P5.1，用户提出 + 源码验证定稿）

### 3.1 动机与背景

DeepSeek 4.1 实证：pi 0.85.1 目录条目「DeepSeek V4.1 Flash」的 API 名
`deepseek-v4.1-flash` 被服务端 400 拒收（服务端实报名：`deepseek-flash` / `deepseek-v4-pro`）。
**目录条目与 API 名可能错位**，等上游收录不可控 → MangoX 自己管菜单。

### 3.2 方案定性：菜单自主，运行时借壳

- `custom_models` 表管**选择与展示**；spawn 照旧 `--model provider/id` 透传
  （pi 对清单外 id 克隆默认条目元数据，见 §0.4）；
- **边界（UI 透明化）**：自定义条目运行时参数继承 pi 目录默认条目——contextWindow/
  compaction/成本价可能不准；thinking 级别放开为全级别可选（pi `clampThinkingLevel`
  会按默认条目自动收敛，安全）；
- **成本将来 MangoX 自算**：usage 原始 token 是真实的（轨迹视图采集），token × DB 单价
  比继承的借价准——P5.0.1 的采集为这里铺路；
- **硬边界**：provider 必须在 pi 目录中存在，否则 pi 报错——UI 输入时校验 provider 前缀。

### 3.3 落库与 UI

```sql
CREATE TABLE IF NOT EXISTS custom_models (
  provider   TEXT NOT NULL,
  model_id   TEXT NOT NULL,
  label      TEXT,
  created_at REAL NOT NULL,
  PRIMARY KEY (provider, model_id)
);
```

- 模型菜单：pi 目录条目照旧 + 分区「自定义」（带删除）+ 底部「自定义模型 ID…」入口；
- 自定义条目带 `custom` 小徽章；thinking 级别全级别；
- 构造 custom `AgentModelInfo` 走现有 `selectModel`（期望钉死逻辑 P4.2 后记已就绪）。

### 3.4 实现记录（P5.1，2026-09-11）

- **落库**：`PersistenceStore.migrate()` 建 `custom_models`（PK provider+model_id）；`loadCustomModels/upsertCustomModel/deleteCustomModel` 三件套照 knowledge 模板；
  `Models/CustomModel.swift`（provider/modelId/label/createdAt + `asAgentModelInfo` 全级别）。
- **store**：`@Published customModels`（init 从库加载）+ `catalogModels`（pi 目录剔除被覆盖者）+
  `customModelInfos` + `menuModels` + `menuEntries(for:)`；`addCustomModel`（provider 校验 + 同 PK upsert 覆盖）/`removeCustomModel`/`isValidProvider`/`currentModelDisplayName`。
- **三条拍板（2026-09-11，用户选推荐项）**：①**同名 provider/id → custom 覆盖 pi 条目**（治本场景必需：deepseek-flash 改名显示，且天然避免重复 id 撞 ForEach）②增删入口 = **管理 sheet**（列表删除 + 添加表单 + 校验红字）③药丸**显示自定义 label**（菜单与药丸一致）。
- **UI**：模型菜单 = 目录条目 + `Section("自定义")`（条目带 ` · custom`）；**管理归设置页内联**（用户拍板：
  「管理自定义模型建议放在 settings 里面比较好」→「管理方式好奇怪」→ 选定内联管理）——SettingsView「自定义模型」卡片即管理面：
  条目行（显示名 + `provider / modelId` + 覆盖标记 + 「启用」+ 删除）+ 底部常驻添加表单（三输入 + 校验提示贴行下），
  **零弹窗**（CustomModelSheet.swift 已删除）；「启用」按当前 thinking 级别直接选中，管理与切换合一。
  `.sheet` 不再需要（历史坑：Menu/设置页挂 sheet 均不如内联直观）。
- **门禁**：冒烟 T13 共 23 项（provider 校验 / 覆盖隐藏 / 菜单 id 无撞车 / 全级别 / label upsert / 药丸 label / 透传真实 id / 落库 roundtrip / 删除收敛），92 项全过。
- **治本用法**：`provider=deepseek` + `model_id=deepseek-flash`（服务端认的名字）+ `label=DeepSeek V4.1 Flash`。

---

## 4. P5.2 收尾清理（顺手项）✅ 已完成（2026-09-11）

- `Resources/AppIcon.icns` 删除（0.1.2 已确认无 pbxproj 引用，纯文件删除，~480KB bundle 冗余）✅；
- CHANGELOG `[0.1.3]` 段 + README 功能清单更新；发版流程沿用 0.1.2 惯例（本地提交 + tag，push 前确认）✅
  —— MARKETING_VERSION ×6 → 0.1.3；README 版本徽章/功能（轨迹视图、自定义模型）/已知限制（继承目录参数、时长估计）/冒烟项数 92 同步；
  顺带修正 README 里 pi 仓库链接（`mariozechner/pi-coding-agent` 已 404，现为 `earendil-works/pi`）。
- 用户拍板：**仅 commit，不 push**（tag 待确认后补）。

---

## 5. 里程碑总表

| 阶段 | 内容 | 状态 |
|---|---|---|
| P5.0.1 | usage/responseId/model 捕获落库（存量数据不做兼容，字段 optional 自然兜底） | ✅ 2026-09-11 |
| P5.0.2 | 入口改造：`capsuleMode` + TopBar（Chat/轨迹胶囊 + Work 独立按钮） | ✅ 2026-09-11 |
| P5.0.3 | 轨迹列表视图 v1（摘要头 Duration/Turns/Calls + 三色事件行 + 展开） | ✅ 2026-09-11 |
| P5.1 | 自定义模型（custom_models 表 + 菜单分区 + custom 徽章） | ✅ 2026-09-11 |
| P5.2 | icns 清理 + CHANGELOG/README + 发 0.1.3 | ✅ 2026-09-11（commit，未 push） |
| （backlog） | 三泳道时间条——无限期延后（用户拍板） | — |
| （Mangopi v0.2 后） | 子代理 CONTEXT 事件对齐 | 依赖前置 |

## 6. 风险清单

1. **流式中断时的 usage 缺失**：手动停止/异常 end 时 message_end 不来 → 该行 token 显示
   "—"（有兜底，不阻塞）；真机验证停止场景的轨迹行完整性；
2. **自定义模型的 compaction 时机**：继承默认条目 contextWindow，若自定义模型实际窗口
   更小可能 compaction 偏晚——v1 接受（同家族场景无感），UI 详情页注明；
3. **迷你台/设置页与入口改造的联动**：mini 台 toolbar 与主区 toolbar 是两套
   （mini 态不显示胶囊/Work），改造时确认互不影响。

## 7. 拍板记录（2026-09-11）

1. ~~成本显示~~ → 用户拍板：优先级不高暂不显示；**采集这次做**（AI 建议，采纳）。
2. ~~usage 落库位置~~ → 已验证：payload JSON 直存零迁移，无需独立表。
3. ~~旧数据兼容~~ → 用户拍板：不做（未进入生产力，旧数据可弃）；optional 字段自然兜底，零工作量。
4. ~~入口形态~~ → 用户拍板：**正交双开关**（chat/trajectory 与 work 独立），否决三态枚举。
5. ~~自定义模型方案~~ → 用户提出 DB 自存 + 参数透传，AI 源码验证 fallback 语义后定稿
   （菜单自主，运行时借壳）。
6. ~~三泳道时间条排期~~ → 用户拍板（2026-09-11）：**无限期延后**，优先级不高、不做可接受；
   粒度方案（回合级小条）已留档于 §1.3，将来重启直接执行。
7. ~~TopBar 三段钉边~~ → 技术坑（2026-09-11 实证，SO 72988380）：macOS 上存在 `.principal`
   项时 `.primaryAction` 紧贴它而非钉右缘——解法 = principal 与 primaryAction 之间插
   `ToolbarItem { Spacer() }` 撑开；principal 亦非数学居中（受左组宽度影响）。
