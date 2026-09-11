# P4 功能设计：多会话并发跑（P4.0，最高优先级）+ 迷你条 + 完成通知

> 2026-09-10 立项，同日深夜拍板：**多会话并发跑为 P4 最高优先级（P4.0）**，
> P4.0.1 已真机验收通过（2026-09-11 晨），P4.0.2 核心场景（A `sleep 100s` + B `sleep 200s` 真跑 pi 并行）真机验收通过（2026-09-11 晨）。
> 迷你条（P4.2）与完成通知（P4.1）排后。
> 门禁传统不变：typecheck 全绿 + 双主题走查 + 真机操作验证 + 冒烟脚本。

---

## 0. 架构事实（判断的前提）

1. **当前回合全局串行**：`isStreaming` 是 ChatStore 单布尔，`sendDraft` 与 fire 均 guard 它。
   per-turn 进程改版解决的是"会话间**切换**互不污染"（随时切、参数各自 spawn），不是并发。
2. **事件面齐全但无归属**：`textChunk/toolUpdated/messageFinalized/streamEnded` 语义完整，
   缺的是"这个事件属于哪个回合/会话"——并发化的核心就是把归属补上。
3. **pi 侧 transcript 天然隔离**：每回合进程 spawn 时 `--session` 指向各自文件，产物写各自的
   transcript——**并发化只需要修客户端投影侧**，不碰 pi。
4. **`AgentTransportDelegate` 回调签名自带实例身份**：
   `func transport(_ transport: any AgentTransport, didEmit event: AgentEvent)`——
   事件路由可以靠"哪个实例发的"判别，**AgentEvent 枚举一个字段都不用加**。

---

## 1. P4.0 多会话并发跑（最高优先级）

### 1.1 目标（用户原话场景 = 验收场景）

> 启动 A 会话，执行 bash tool `sleep 100s`；再启动 B 会话，执行 bash tool `sleep 200s`。
> 2 个会话同时运行且互不干扰；schedule 中的任务也能正常运行。
> 可设置同时运行任务上限（比如 10 个）。

### 1.2 现状盘点（什么串、什么不串）

| 层 | 并发现状 | 结论 |
|---|---|---|
| pi 进程/LLM | 每回合一个进程，per-turn 已就绪 | ✅ 天然支持，零改动 |
| transcript 持久化 | 各回话各写各的 `--session` 文件 | ✅ 零改动 |
| events 表投影 | append-only per session，结构支持并发写 | ✅ 零改动（WAL 支持多写者） |
| 事件归并 | `messages` 单数组、无归属判断 | ❌ **核心改造点** |
| isStreaming | 全局单布尔 | ❌ 会话化 |
| fire | 劫持 UI（切会话、替换 messages） | ❌ 去劫持，改后台 turn |
| 审批 | pendingApprovals 全局单份、askApproval 全局 | ❌ 随实例池自然解决 |
| sendDraft 守卫 | 全局拒绝 | ❌ 改 per-session |

### 1.3 架构判断：Transport 多实例池（不是池化单实例）

**关键洞察**：`PiRpcTransport` 的全部状态（process/toolCards/pendingApprovals/计时表）
本来就是 per-process 自洽的——它被单例使用是历史，不是设计。**每个并发回合 = 一个独立的
`PiRpcTransport` 实例**，则：

- 事件路由零协议改动：delegate 第一参数即实例身份，`ChatStore.transports: [UUID: AgentTransport]`
  （sessionId → 实例），归并时查表路由；
- `isStreaming` 会话化 = `runningTurns: Set<UUID>`（sessionId 集合），协议不变；
- 审批天然 per-session：`updateApprovalPolicy` 本来就是实例方法——无人值守 fire 给自己的实例
  关审批，用户会话的实例保持询问，互不可见；
- 计时/工具卡/审批队列全部随实例隔离，现有实现原样保留。

**对比方案 B（单实例内部池化，AgentEvent 加 turnId 字段）**：要改 AgentEvent 枚举每个 case、
transport 内部所有字典加一层 key、协议语义重写——工程量数倍，否决。

**ChatStore 侧改造**（真正的工作量所在）：
- `messages` 降级为"当前选中会话的投影"；每个在途回合持有自己的缓冲
  （流式 text/think 块、工具卡），切到该会话时 replay + 注入缓冲续播；
- 非当前会话的事件**只落库不进视图**（修掉 §4.5 记录的污染 bug——路由正确后它自然消失）；
- `persistMessage` 等全部从 `selectedConversationId` 改为显式 `sid` 参数。

### 1.4 阶段拆解（每阶段独立可验收，P4.0.1 可单独发版）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P4.0.1 事件归属路由**（正确性修复，可独立发 0.1.2） | 归并层事件带回合会话归属（send 时记录 turnSessionId）；非当前会话事件只落库不进视图；persistMessage/appendToolUpdateEvent 显式 sid | A 跑 `sleep 100s` 流式中切到 B：B 视图无 A 内容；A 产物完整落 A 会话；A 结束后回 A 会话回放完整 |
| **P4.0.2 Transport 池 + 会话化 isStreaming** | `transports: [UUID: AgentTransport]`；`runningTurns: Set<UUID>`；sendDraft 按 selected 会话取/建实例；同会话回合在途仍拒绝、跨会话放行；能力上报走专用探测实例 | **验收场景全量跑**：A `sleep 100s` + B `sleep 200s` 同时在跑（迷你态下两条都活）、切视图互不干扰、两 transcript 各自完整 |
| **P4.0.3 Fire 去劫持** | ✅ **已随 P4.0.2 一并落地**：runScheduledFire 重写为纯后台投递（不动 selectedConversationId/messages/UI 面板），日志会话直接 persist 分隔+prompt、在途跳过改按会话粒度（"该任务回合在途"）；间隔期由全局"有回合在途"收窄为单日志会话冲突 | 待真机验证：两个 scheduled 任务同时 fire 并行追加 |
| **P4.0.4 并发上限 + 审批路由收尾** | settings 加 `max_concurrent_turns`（默认 10）；超限：用户发送 → 拒绝 + 横幅提示，fire → 落痕跳过（理由"并发已满"）；后台回合等待审批时经通知/迷你条提示（依赖 P4.1） | 上限设 2 时第三个任务被拒且提示明确；后台回合要审批时用户可感知并切过去处理 |
| **P4.0.5 回归收尾** | transcript/p311 冒烟适配；并发 smoke（双会话同时跑 + 切视图 + 回放比对）；迷你条堆叠适配（P4.2 前置）；README/CHANGELOG | 全部门禁绿 |

### 1.5 并发上限设定

- 存储：settings 表 `max_concurrent_turns`，默认 **10**；
- 口径：**在途回合数**（runningTurns.count），排队不做（v1 拒绝 + 明确提示；fire 与现有"冲突跳过"
  落痕语义一致）；
- 入口：设置页（拍板项 4 的最小设置页可顺势一起做，只放并发上限 + 通知开关两项）。

### 1.6 审批与安全

- per-session 审批策略随实例天然隔离（见 1.3）；
- 后台回合等待审批 = 进程挂起等待（安全闸门不降级），用户经通知/迷你条感知后切过去处理；
- BashRiskEvaluator 白名单行为不变（只读静默放行覆盖所有实例——评估器是纯函数，无状态，天然共享）。

### 1.7 风险清单

1. **切换到"回合在途"的会话时的视图续播**：replay + 缓冲合并的时序（切过去瞬间 chunk 还在到）——
   P4.0.1 先解决归属，P4.0.2 处理合并，都要真机验证；
2. **DEBUG MockTransport 兼容**：协议/Store 改动波及回归基线，保留默认实现；
3. **资源占用**：10 个并发 = 10 个 node 进程（各 ~50MB）+ 10 路 LLM 流——个人机可承受，但值得在
   README 已知限制里写明；
4. **冒烟体系**：现有 smoke 都是单回合假设，P4.0.5 需要并发 smoke 脚本（两实例真跑 pi 对拍 transcript）。

---

## 2. 功能一：任务迷你条（P4.2，依赖 P4.0 堆叠语义）

### 2.1 动机

fire 回合与长分析回合经常跑几分钟，用户切去干别的，回来才发现早跑完了。
需要"窗口缩成 2 行小条仍能看到任务在跑"——Apple Music mini player 正是此意。

### 2.2 方案对比（有立场）

> **2026-09-11 拍板变更**：初版选 A（独立置顶小窗）实现后，用户澄清真实意图 = **Apple Music 同款语义——
> 主窗口本体最小化变形**（左上角最小化按钮 → 主窗口缩成 mini 工具台），改选 C 落地。A 已删除。

| 方案 | 形态 | 工程量 | 判断 |
|---|---|---|---|
| A. 独立置顶小窗（NSPanel + NSHostingView） | 忠实还原 Apple Music：主窗口保留，小条置顶悬浮 | ~200 行 | ~~已实现后按用户澄清推翻~~ |
| B. MenuBarExtra 菜单栏项 | 状态收进菜单栏 | ~50 行 | 图标态看不到"正在跑什么"；留作 v2 补充 |
| **C. 主窗口折叠（最终方案）** | 左上角最小化按钮 → 同一主窗口缩为 mini 工具台，还原按钮恢复 | ~150 行 | **✅ 已落地**——原 frame 存档 + toolbar 自适应 + 完成自动还原 |

### 2.3 内容设计（2 行起，P4.0 后支持堆叠）

```
┌──────────────────────────────────────────┐
│ ⏳ 任务名 · 03:42                  [■ 停止] │   L1: 名称 + 回合计时 + 停止
│ ↳ 正在执行 bash "ps aux | grep …"         │   L2: 活动摘要（单行截断）
└──────────────────────────────────────────┘
```

- L2 摘要优先级：当前工具卡 title → 流式文本尾部 60 字 → "思考中…"；
- 宽 ~360pt 高 ~44pt，圆角 + hud 质感，可拖动（位置存 settings，见拍板项）；
- 点击条身 = 展开主窗口并跳对应会话；[■] = stop 该回合；
- **P4.0 之后**：>1 个任务在途时堆叠（每任务一卡，最多全展示或限高滚动）；
- 无任务在途时隐藏。

### 2.4 边界

- 迷你条内**不做**：看完整消息流（点回主窗口）、审批卡（scope 爆炸）；
- 回合结束 → 显示"✓ 完成 · 耗时"1.5s 后消失；App 非前台时由 P4.1 通知接管。

---

## 3. 功能二：回合完成通知（P4.1）

### 3.1 动机

长回合跑完时用户往往不在 App 窗口上。当前完成无任何提示。

### 3.2 方案（有立场）

**系统通知（UNUserNotificationCenter）**——"右上角小弹窗"就是通知中心横幅的形态；
免维护、联动专注模式、点击跳转会话。App 内 toast 否决为主案（App 不在前台时恰好看不见）。

### 3.3 触发规则

- 触发：per-turn `streamEnded` 且 **App 不在前台**；前台不弹（用户正看着）；
- 对象：普通回合 + fire 轮次；等待型任务"已触发"用单独文案；
- 内容：标题 = 会话名/任务名；正文 = "回合完成 · 耗时 03:42" + 回复首行 60 字；
- 点击：activate App + selectConversation + 收迷你条；
- 失败回合（异常 ended）也通知，标"异常结束"。

### 3.4 授权与风险

- 首次触发前 `requestAuthorization(.alert)`；拒绝则静默降级；
- **风险（P4.1 第一件事实测）**：ad-hoc 签名下 UNUserNotificationCenter 可用性——若不可用降级
  App 内 toast，并把 Developer ID 签名列入收益清单。

### 3.5 验收

跑 1 分钟以上回合 → 切浏览器 → 回合结束右上角弹横幅 → 点击激活并跳该会话；前台不弹；开关关闭不弹。

---

## 4. 里程碑总表

| 阶段 | 内容 | 状态 |
|---|---|---|
| **P4.0.1** | 事件归属路由（可独立发 0.1.2）✅ 已实现（2026-09-10 深夜，**真机验收通过**）：`activeTurnSessionId` send 时刻定格 + `turnIsInView` 路由 + text/think 无条件缓冲（切走凭缓冲落库、切回从缓冲全文起头）+ persistMessage/appendToolUpdateEvent 显式 sid | ✅ 已验收（注：实现本体已被 P4.0.2 池化架构吸收替代） |
| **P4.0.2** | Transport 池 + 会话化 isStreaming ✅ 已实现（2026-09-11 凌晨）：`transports: [UUID: AgentTransport]` 池（get-or-create + spawn 配置快照补发）；`runningTurns: Set<UUID>` + 计算属性 `isStreaming`（选中会话在途）；能力探测专用实例（池实例能力上报不覆盖全局）；`liveTurns` 实时镜像替代缓冲（切走迁移未落库流式块/非终态工具卡，切回 replay+按 id 去重合并）；事件归属 = transport 实例身份（`sessionOf` 路由，零协议改动）；审批按选中会话路由；deleteConversation/Project 逐出池实例；冒烟 30 项全过（含 fire 后台化/done 停用/落库对拍） | 待真机验收（核心场景：A/B 双会话真跑 pi 并行） |
| **P4.0.3** | Fire 去劫持（✅ 已随 P4.0.2 一并落地：runScheduledFire 纯后台投递，跳过判定收窄为单日志会话粒度） | ✅ 代码完成；待真机验证并发 fire |
| **P4.0.4** | 并发上限 + 审批路由收尾 ✅ 已实现（2026-09-11 早）：`max_concurrent_turns`（settings 表持久化，默认 10，clamp 1...20）；超限 = 用户发送拒绝+横幅提示（draft 保留、消息不落库）、fire 落痕跳过（"因冲突跳过 (并发已满 (N))"）；最小设置页（Settings navRow + 主区面板互斥，Stepper 1...20 + 说明）；审批路由已随 P4.0.2 闭环（选中会话路由转发 + 白名单全池推送），后台回合等待审批的可感知入口留 P4.1 通知 | 待真机验收 |
| **P4.0.5** | 并发回归收尾 ✅ 已完成（2026-09-11）：冒烟固化进仓库（`scripts/smoke/run.sh`，42 项语义冒烟一条命令——含并发路由/切视图镜像/回放比对/fire 后台化/上限拒绝/落痕）；真跑 pi 双实例 transcript 对拍由真机验收承担（2026-09-11 晨通过）；迷你条堆叠适配归 P4.2（迷你条未实现，无前置适配需求）；README（功能/已知限制/门禁）+ CHANGELOG（Unreleased 段）更新 | ✅ 门禁全绿（typecheck + 42 冒烟 + 真机验收） |
| P4.1 | 完成通知 ✅ 已实现（2026-09-11 上午）：`CompletionNotifier`（UNUserNotificationCenter 封装，无 bundle 环境安全 no-op）；触发 = streamEnded + App 非前台 + 开关开 + 耗时 ≥1s；正文 = 耗时 + 回复首行 60 字；点击通知激活并跳会话（delegate 启动期安装）；设置页开关（首次开启请求授权，denied 显提示）；手动停止不发通知 | 待真机验收（授权弹窗 + 后台横幅 + 点击跳转） |
| P4.2 | 任务迷你条 ✅ 已实现（2026-09-11，**方案 C 主窗口变形**，用户澄清拍板后重做）：左上角最小化按钮 → 同一主窗口缩为 mini 工具台（原 frame 存档 UserDefaults + 窗口缩至右下角 + level floating）；工具栏自适应（还原按钮 + "任务台 · N 个在途"）；任务卡堆叠（名称+计时+停止 / 活动摘要）；点卡身还原并跳会话；全部完成闪显"✓ 完成·耗时"1.5s 自动还原；mini 期间高度随卡数（1...4 卡） | 待真机验收（变形/还原/拖动/堆叠/点卡） |

## 5. 留拍板的开放问题

1. ~~迷你条形态~~ → 已拍板 A（独立置顶小窗），2026-09-10。
2. **通知触发口径**：只判"App 非前台"，还是加"前台但久未交互"？v1 建议只判前台。
3. **迷你条位置记忆**：拖动位置跨启动记住（存 settings）？建议要。
4. ~~设置页~~ → 已随 P4.0.4 建最小设置页（并发上限一项；通知开关随 P4.1 加入同一面板）。
5. ~~多会话并发跑排期~~ → 已拍板为 **P4.0 最高优先级**（2026-09-10 深夜），拆解见 §1.4。
