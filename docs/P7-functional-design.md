# P7 功能设计 · 第 4 批：模型管理自管 + 模式选择器

> 2026-09-15。输入：merged-roadmap-2026-09-14 第 4/5/6 批 + 本日与用户逐项对齐结论（对齐过程见对话记录与项目记忆）。
> 本文覆盖合并 roadmap 第 4 批（4a 模型管理 / 4b 模式选择器）与第 5、6 批（多模态 / 工具产图，§7/§8，2026-09-15 二轮对齐后追加）。

## 0. 拍板记录（2026-09-15）

1. **「权限模式选择器」改为「模式选择器」**：档位决定 agent 可用**工具集**（能力预设），不做审批策略分级。三档：极简 / 常规 / 完整（含扩展）。
2. **审批开关照旧**：composer 手型按钮（askApproval）保留为独立选项，与模式正交。模式管"能给什么"，审批管"用了要不要报备"。
3. **key 存 Keychain**（roadmap 遗留项就此关闭）：真源不落明文，物化时写 0600 的 `auth.json`。
4. **模型清单自动获取**：`/models` 接口拉取为主，预设热门清单兜底；拉取清单只是目录视图，用户勾选落库才是真源。
5. **扩展宇宙封闭**：延续 P3.11 `--no-extensions` + 显式 `--extension` 托管；扩展工具只经 MangoX 入册。
6. **多模态四立场确认**（§7）：门控"附件随时可挂、发送时才拦"；大图预览用 sheet/popover 不开独立窗口；删会话清附件目录遵守"先读后删"位置纪律；单条消息 ≤4 张。
7. **多模态边界确认**：Side chat fork 快照原样携带图片 base64，侧问 token 开销含图片——fork 语义自然结果，不特殊处理，真机验证时留意。

## 1. 4a · 模型管理自管

设计原则：**真源在 MangoX，pi 只是第一个消费者**。完全不碰 `~/.pi/agent`。

### 1.1 数据模型（两层）

**provider_presets（内置静态 Swift 数据，不入库）**

```
id / displayName / baseURL / apiType / modelsURL(缺省 baseURL+/v1/models)
seedModels: [SeedModel]   // 推荐预勾种子 + /models 拉取失败时的兜底清单（可含元数据）
needsKey: Bool            // Ollama = false
```

v1 预设清单：DeepSeek / Kimi / GLM(智谱) / Qwen(百炼) / MiniMax / OpenAI / Anthropic / Ollama(本地) + 自定义（任意 baseUrl，覆盖 one-api 类内网网关）。加预设 = 加一条静态数据，后续可做远端 JSON 更新。

**models 表（SQLite 真源，升级自 custom_models 三字段表）**

```sql
CREATE TABLE IF NOT EXISTS models (
  provider TEXT NOT NULL,
  model_id TEXT NOT NULL,
  display_name TEXT,
  api_type TEXT NOT NULL,        -- openai-completions | openai-responses | anthropic-messages | google-generative-ai（接口缝，未来接别的引擎）
  base_url TEXT,                 -- nil = 走 pi 内置目录同名条目
  key_ref TEXT,                  -- Keychain account；nil = 无 key（Ollama）
  context_window INTEGER,
  max_tokens INTEGER,
  input_modalities TEXT,         -- JSON ["text","image"]；第 5 批发送门控消费
  cost_json TEXT,                -- 四价 + tiers
  thinking_level_map TEXT,       -- JSON 三态（省略=默认/字符串=支持/null=不支持）
  compat_json TEXT,
  sampling_json TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,   -- 进物化清单的开关
  source TEXT NOT NULL,          -- preset | custom | legacy（custom_models 迁入标记）
  created_at REAL NOT NULL,
  PRIMARY KEY (provider, model_id)
)
```

### 1.2 Keychain

- service = `com.mangox.model-key`，account = `{provider}/{model_id}`（或 provider 级共享，实现时按 provider 粒度归组）。
- settings UI 只显掩码 + "更换"；真源表存 `key_ref` 不存明文。
- 物化时读 Keychain → 写 `auth.json`，文件权限 0600。

### 1.3 物化层（PI_CODING_AGENT_DIR）

- spawn 时（`PiRpcTransport.swift:403-404` 的 `Process()`，当前未设 environment）注入：

```swift
p.environment = ProcessInfo.processInfo.environment  // 先继承 PATH 等
p.environment?["PI_CODING_AGENT_DIR"] = ModelMaterializer.configDir.path
// configDir = ~/.mangox/pi-config/（MangoX 托管，与 ~/.pi/agent 互不相干）
```

- **物化内容**：`models.json`（enabled 条目全量 Model 对象：baseUrl/api/cost/input/thinkingLevelMap）+ `auth.json`（0600）。settings.json 写最小骨架（默认 provider-model 由 `--model` 显式传，不依赖 settings）。
- **写时机**：spawn 前对真源算 hash，与物化文件不一致才重写（避免每回合磁盘搅动）。
- **生效路径**：per-turn 进程架构天然"下回合生效"；回合内 `set_model` 要求目标模型在本次物化清单内（`desiredModel` 机制 `:331-339` 沿用）。
- ~~内置目录只读基线~~：**已砍（实验②）**——空配置目录下 pi 不自动拉取内置目录，且 `get_available_models` 只返回有凭据的模型。settings 页是唯一模型面，物化 models.json 只写 MangoX 条目。

### 1.4 settings 页与添加流程

形态见对齐用 mockup（2026-09-15 对话）：模型 Tab = provider 卡片列表（状态点/掩码/模型数）+ 添加面板。

```
选预设 → 填 key（base_url/api_type 预填可改）→ 测试连接（直连，不经 pi）
  ├─ /models 可用 → 拉清单 → 勾选（seedModels 预勾）→ 保存
  ├─ /models 不可用 → seedModels 兜底 + 手填 id → 保存（标黄"未验证"）
  └─ 测试失败不阻断保存（内网网关可能 /models 不开但 chat 通）
```

- 拉取清单 = 目录视图，可搜索过滤（网关可能返回上百 id），每次现拉 + 手动刷新，**不缓存为数据源**。
- 元数据策略（2026-09-15 修订：**models.dev 直连三层自有化，运行时零依赖 `~/.pi/agent`**）：
  - 背景：`/models` 只回 id 字符串，不含思考强度等元数据；早期方案借 `~/.pi/agent/models-store.json` 补元数据，但该文件本质是 **models.dev 的缓存**（4.6MB、216 providers，含 reasoning/limit/cost/modalities）。既然脱离 pi 自管模型，就不应再读 pi 的目录。
  - 三层：① bundled 快照 `Resources/model-catalog.json`（`scripts/gen-model-catalog.py` 从 models.dev 剪裁生成，当前 15 providers / 773 models / 154KB，含 6 字段 name/reasoning/contextWindow/maxTokens/input/cost）；② 远端刷新缓存 `~/.mangox/catalog/modelsdev.json`（7 天 TTL，拉 models.dev 全量 api.json，静默失败）；③ 兜底 = seed 元数据仍最高优先，最后才是裸 id 保守默认（contextWindow 128k、cost 空、input=["text"]）。
  - 候选元数据优先级：`seed（不漂移）> models.dev 目录 > 裸默认`；provider 别名 `kimi→moonshotai`、`zhipu→zai`；未知 provider 全目录模糊扫 modelId，唯一命中才采信。
  - loadPreset 用目录把预设 seed 之外的模型一并展开（seed 会漂移：kimi 预设里的 `kimi-k2-0905-preview` 在 models.dev 已不存在，目录里是 kimi-k3 等新代）。
  - 已知缺口：models.dev 无 qwen/ollama/together 等国内/聚合 provider 键，这些预设仍走 seed + 裸默认。
- 每条目带 `source` 徽章（preset/custom/legacy）+ `enabled` 勾选。

### 1.5 迁移

`custom_models`（provider/model_id/label/created_at）一次性迁入 models 表，`source='legacy'`、base_url=nil（继续借 pi 内置目录语义），label → display_name。旧表保留不删（回滚余地），代码路径切换。

## 2. 4b · 模式选择器

### 2.1 三档定义与 spawn 映射

| 档 | UI 名 | 工具集 | spawn 映射 |
|---|---|---|---|
| minimal | Minimal（极简） | read / bash / write / edit | `--tools read,bash,write,edit` + 不挂业务扩展 |
| standard | Standard（常规） | 内置 8 全量 | 不带 `--tools`（pi 默认即全量）+ 不挂业务扩展 |
| full | Full（完整） | 内置 8 + 扩展注册工具 | 不带 `--tools` + 挂全部业务扩展 |

- 极简集默认含 read/edit 的理由：盲写不可用（看不到文件改什么）。**用户原话是 bash/write，定稿前一行确认即可调**。
- 档位差异用**挂载扩展与否**表达"含不含扩展"，不依赖 `--tools` 对扩展工具的过滤行为（该行为未证伪，见 §3-③）——三档映射在两种证伪结果下都成立。
- powershell 为 Windows 侧工具，macOS 物理不可用，不必特判。

### 2.2 扩展挂载矩阵

| 扩展类型 | 三档行为 |
|---|---|
| MangoX 系统扩展（审批门控等控制面） | 三档都挂（否则审批/托管机制失效） |
| 业务扩展（用户托管的第三方/示例扩展） | 仅 Full 档挂载 |

业务扩展注册的工具进 Full 档工具池；未来"自定义档/工具清单视图"（设置页列出全部工具及来源）后置，不在本批。

### 2.3 审批开关（独立，照旧）

- `askApproval` 布尔、composer 手型按钮、transport 自动应答 + bash 只读白名单（`PiRpcTransport.swift:757-765`）**全部不动**。
- 与模式正交组合：如"Standard 档 + 审批开"= 工具全量但每步弹卡；"Minimal 档 + 审批关"= 定时任务轻装跑。
- 无人值守路径（`MockData.swift:932`）不受影响。

### 2.4 项目记忆与 UI

- 模式按项目存（projects 表加列或 settings KV，实现时定），默认 standard；composer 新增档位 pill Menu（位于审批开关旁），双击项目 = 恢复该项目档位。
- per-turn 语义：档位变更下回合生效（spawn 参数），与 desiredModel/desiredThinking 同机制（`PiRpcTransport.swift:405-449` 组装位现成）。

## 3. 开工前证伪实验（2026-09-15 已全部完成，结论如下）

### ① 全新 provider 注册 — ✅ 实测通过

`/tmp/p7exp/` 实测（pi 0.85.1 RPC + `PI_CODING_AGENT_DIR` 指向实验目录）：

- models.json 写入两个**不在 pi 内置 provider 列表**的 provider（`mangox-gw` openai-completions / `fake-anthropic` anthropic-messages），3 个模型全部出现在 `get_available_models`，元数据（baseUrl/api/contextWindow/input/reasoning/cost）完整回读。
- `set_model` 返回 `success:true`，`get_state` 确认切换生效。
- **key 走 auth.json 实测通过（①c）**：models.json 不含 `apiKey`，`auth.json` 写 `{"<provider>": {"type":"api_key","key":"..."}}`（0600）→ 模型照常可用。**与物化设计完全吻合：key 只进 auth.json。**
- 佐证文档：`docs/models.md`（"non-built-in provider configs need baseUrl and an api value"）。预设结构**无需** fallback 字段，结论 M2 可直接开工。

### ② PI_CODING_AGENT_DIR 指空目录 — ⚠️ 内置目录不可见，设计简化

- 空目录（含关沙箱允许网络重试）→ `get_available_models` 返回 **0 条**，pi 生成 2 字节的空 `models-store.json`/`auth.json`，**无自动拉取目录行为**。
- 对照（用户真实 `~/.pi/agent`）→ 7 条 / 2 providers（deepseek+minimax），恰为用户有 auth 的两家 → **`get_available_models` 只返回"有可用凭据"的模型**（与 models.md "models load but stay unavailable without auth" 一致）。
- **设计影响**：§1.3 的"内置目录只读基线展示"不成立，**砍掉**——MangoX settings 页是唯一模型面，无需"浏览内置"区；物化 models.json 只写 MangoX 管理的条目，无合并冲突面。

### ③ --tools 是否过滤扩展工具 — ✅ 文档实锤（不再依赖实测）

`docs/usage.md` Tool Options 明写：`--tools <list>` = "Allowlist specific **built-in, extension, and custom tools**"（`--exclude-tools` 同理；`--no-builtin-tools` 才是只关内置保留扩展）。

- **三档映射因此有双保险**：既可用 `--tools` 白名单（扩展工具一并被裁），也可用"不挂业务扩展"（§2.1 现行策略）。极简/常规档两条路都成立，Full 档全放开。
- 将来做"自定义档/工具清单视图"时可直接用 `--tools` 精确勾选，无遗漏风险。

## 4. 里程碑与门禁

| 步骤 | 内容 | 门禁 |
|---|---|---|
| M1 | 三证伪实验 + 结论回填 | ✅ 完成（§3） |
| M2 | models 表 + 迁移 + Materializer（物化纯函数化） | ✅ 完成 — 新增 `ManagedModel` / `ModelKeyStore`(Keychain+内存) / `ModelMaterializer`；冒烟 **T21 +23 项，全量 217 ALL PASS** |
| M3 | settings 模型管理 UI（预设/测试连接/勾选）+ spawn 接线 | ✅ 代码完成（2026-09-15）— `ProviderPresets`(8 家) / `ModelCatalogFetcher`(parse 纯函数) / SettingsView 模型区改版（预设芯片→key→测试→勾选→保存）/ ChatStore CRUD+refreshPIConfig / PiRpcTransport spawn 注 `PI_CODING_AGENT_DIR`+writeIfNeeded；冒烟 **T22 +13 项，全量 230 ALL PASS**；真机手验（测试连接真实请求 / 物化文件生效）待跑 App |
| M3.5 | 模型元数据目录自有化（models.dev 三层，零依赖 ~/.pi/agent） | ✅ 完成（2026-09-15）— `ModelCatalogStore`（bundled > ~/.mangox/catalog 缓存 7 天 TTL > 空；别名/模糊查询；静默远端刷新）+ `Resources/model-catalog.json` 快照（gen-model-catalog.py 生成）+ SettingsView 元数据优先级 seed>目录>裸默认 + loadPreset 目录展开；冒烟 **T22b +9 项，全量 245 ALL PASS** |
| M4 | 模式选择器（三档映射 + 扩展挂载矩阵 + 项目记忆） | ✅ 完成（2026-09-15）— 新增 `AgentMode`（三档 + `spawnArguments` 纯函数矩阵 + settings 序号持久化）；`AgentTransport.updateMode` + PiRpcTransport spawn 接线（极简 `--tools read,bash,write,edit` / 业务扩展仅 Full 挂 / 系统扩展恒挂不变）；ChatStore `agentMode` 按项目记忆（settings KV `agent_mode.<projectId>`，切项目恢复，默认 standard，didSet 全池下发 + transportFor 快照补发）；composer 审批开关旁档位 pill Menu（standard 素色/非 standard accent 胶囊）；冒烟 **T23 +10 项，全量 254 ALL PASS** |
| M5 | 收尾：CHANGELOG / README / 版本号 | 全量冒烟 ALL PASS |

M2 先行于 M3/M4；M2 依赖 M1-①② 结论。

## 7. 第 5 批 · 多模态：传图 + 气泡显示图片

pi 侧零缺口（`prompt`/`steer`/`follow_up` 原生收 `images`），缺口全在 MangoX 管线，七个环节：

### 7.1 管线七环节（落点已探明）

| # | 环节 | 现状与落点 |
|---|---|---|
| 1 | 入口 ×3 | ⌘V 粘贴（NSPasteboard 检测图片）/ 拖拽（composer 落点）/ 附件按钮——现状 NSOpenPanel 后 `insertMention` 塞 `@路径` 进 draft（`ChatComposer.swift:346-349`，文本语义）。改造：**图片类走附件通道，非图片保留 `@` 语义**（`@file` 本就该模型自己 read） |
| 2 | 暂存区 | composer 上方附件 chips（64pt 缩略图 + ×），随 draft 生命周期，发送即清 |
| 3 | 落盘 | 发送时拷入 `~/.mangox/attachments/<sessionId>/`；SQLite 只存路径+像素尺寸+mime，**不存 BLOB** |
| 4 | 自压 | `images.autoResize` 不覆盖 RPC base64（pi 契约）→ 客户端必压：长边 ≤1536px / JPEG q0.8（ImageIO）。**磁盘存原图、发送压副本**——原图留档，base64 只活一次 |
| 5 | 发送 | `prompt` 现在只发 `message`（`PiRpcTransport.swift:206`）→ 加 `images:[{type,data(base64),mimeType}]`；`steer`/`follow_up` 同构支持 |
| 6 | 气泡显示 | 用户气泡缩略图行（88×66 圆角）+ 点开大图；replay 从 SQLite attachments 列渲染，与实时同源 |
| 7 | 工具图占位 | `outputString` 静默丢 content 块数组（`:987-994`）→ 本批做 `"[图片 N 张]"` 占位；块转附件进气泡 = 第 6 批（§8） |

### 7.2 数据结构

```swift
struct Attachment: Hashable, Codable {
    let id: UUID
    let path: String        // ~/.mangox/attachments/<sessionId>/<uuid>.<ext>
    let pixelWidth: Int
    let pixelHeight: Int
    let mimeType: String    // image/jpeg / image/png / image/gif / image/webp
    let byteSize: Int
}
// ChatMessage 加 var attachments: [Attachment]（MessageModels.swift:39）
// SQLite messages 表加 attachments TEXT 列（JSON 数组），migrate() 补列沿用 addColumnIfMissing
```

### 7.3 拍板立场

1. **门控：附件随时可挂，发送时才拦。** 模型可中途切换，按钮置灰自相矛盾。发送时校验 `input_modalities`（4a models 表字段；过渡期读 `get_available_models` 的 `input`）不含 image → 拦下提示换模型；附件不白挂，切模型后可发。
2. **大图预览用 sheet/popover**，不开独立 NSWindow（P4.2 尺寸控制坑，不为预览踩）。Esc/点击关闭。
3. **删会话清附件目录，先读后删**：attachments 路径在删 messages 行**之前**读出（同 `loadSessionFile` 教训），目录删除对齐 `removeSessionFile` 模式。侧问删除同理。
4. **单条消息 ≤4 张**：超限拆条。防 base64 撑爆单条 RPC（4×1536px JPEG ≈ 2-4MB）。

### 7.4 边界与已知行为

- **Side chat fork 原样携带图片 base64**（transcript 原样拷贝）：侧问能看见主线贴过的图，token 开销含图片。fork 语义自然结果，不特殊处理，真机验证留意。
- GIF/webp：直接按 mime 透传不转码（压缩只对超限的位图做）；动图第一帧渲染缩略图。

### 7.5 里程碑

| 步骤 | 内容 | 门禁 |
|---|---|---|
| M6a | Attachment 模型 + 落盘 + SQLite 列 + 压缩管线（纯函数） | ✅ 完成（2026-09-15）— `Attachment` + `ImagePipeline`（pixelSize/sniffExtension/compressForSend/outgoingPayload/saveOriginal/removeSessionAttachments）；落盘 `~/.mangox/attachments/<sessionId>/`；**持久化偏差**：消息走 events 表整条 ChatMessage JSON（非独立 messages 表），`attachments` 作可选字段内嵌 payload（缺 key 解码 nil 兼容旧数据）；删会话先读后删；冒烟 T24 +13 项 |
| M6b | 三入口 + 暂存区 UI + 发送链路 images 数组 | ✅ 完成（2026-09-15）— 暂存 `pendingImages`（≤4 张）+ add/remove API；三入口：附件按钮（图片→附件通道/非图片保留 @语义）、⌘V（`PasteInterceptTextView` 子类拦截 png/tiff）、拖拽（onDrop UTType.image + 嗅探扩展名）；发送门控 `currentModelSupportsImages`（managed inputModalities 判定，无法判定不拦）；`AgentTransport.send(prompt:images:)` + RPC `images:[{type,data,mimeType}]`；发送字节 `outgoingPayload` 纯函数（png/gif/webp 未超限透传保动图，其余 JPEG 副本）；冒烟 T24b +8 项 |
| M6c | 气泡缩略图 + 大图预览 + replay 同源 | ✅ 代码完成（2026-09-15）— MessageBlockView 附件缩略行（88×66 圆角，用户消息靠右）+ 点开 sheet 大图（Esc/点击/按钮关闭，**不开 NSWindow**）+ 缺文件降级文案；replay 同源已由 T24 冒烟证明（events → attachments 渲染）；**真机手验待跑**（真实贴图发送/pi 侧收到 base64/气泡渲染） |

## 8. 第 6 批 · 工具产图（**已冻结，2026-09-15 拍板暂不做**）

> 状态：冻结。设计保留如下，解冻时可直接按此开工。

- `outputString` 提取层改返回**块数组**（text/image 保留），image 块转 `Attachment` 进气泡渲染；占位文案 `"[图片 N 张]"` 退役。
- 牵动 `ToolDetail`/`ToolCall` 值类型与序列化（`ToolCall.swift:34/44`）+ 落库 replay——改值类型影响持久化兼容，**单独成批独立验收**的理由。
- 里程碑 M7：值类型改造 + 迁移兼容（旧记录占位文案照常显示）+ 冒烟 T24；真机验证接一张真实工具产图（如 bash 生成 png 后 read）。

## 9. 总里程碑序

M1(证伪) → M2(models 表+物化) → M3(settings UI) → M3.5(元数据目录) → M4(模式选择器) → M5(第 4 批收尾) → M6(多模态) → M7(工具产图, **冻结**)。

| 步骤 | 状态 |
|---|---|
| M1-M4, M6 | ✅ 全部完成（2026-09-15，全量冒烟 276 ALL PASS） |
| M5 | ✅ 完成 — 版本 0.1.5（pbxproj 6 处）/ CHANGELOG 0.1.5 段 / README（徽章/功能/冒烟 276/已知限制） |
| M7 | ❄️ 冻结（2026-09-15 拍板） |
