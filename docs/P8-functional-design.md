# P8 功能设计 · 五项（侧栏分组 / 审批阻塞提示 / 快速捕获 / 手动备份 / worktree 隔离）

> 拍板记录（2026-09-15）：
> 1. 侧栏 Chats 日分组 ✅ 已落地（0.1.5 后）：项目会话留 Projects 嵌套，日分组只管非项目平铺 Chats；活动徽章（`N 轮 · 改 M 文件`）整条砍掉（实机否决，视觉噪）。
> 2. 外部模型建议的"成本仪表盘 / 晨报周报 / activity_log 独立表"否决——不关心成本（账单在厂商侧）；Turns 视图够"查"，侧栏日分组够"扫"。
> 3. 快速捕获热键定为 **Alt+X**（非 ⌥Space）；手动备份（非自动）；M7 工具产图维持冻结。
> 4. 流程纪律（教训）：先文档对齐再代码——本文档即对齐物，各项确认后才开工。

---

## 1. 侧栏 Chats 日分组（已落地，本文仅存档）

- `DayBucket`（`Models/DayBucket.swift`）纯函数四桶：今天 / 昨天 / 本周 / 更早（`Calendar.isDate(_:inSameDayAs:)` + `weekOfYear` 粒度对齐）。
- 作用域：**仅 Chats 区**（非项目平铺会话），组头右侧显示会话数；Projects 区恢复嵌套会话（展开/收起，按 updatedAt 排序）。
- 冒烟 T25（日桶四段断言，固定周三 2026-09-16 规避周界歧义）。
- 补丁（实机 bug）：`updatedAt` 原只在创建/重命名定格，日分组把陈旧值显成"昨天"——`persistMessage` 落库即 `touchConversation`（内存 chats/projects + db `touchSession` 同刷），冒烟 T25b（内存刷新 + 落库 roundtrip）。存量会话的下一次活跃起算，不回填历史。

## 2. 侧栏审批阻塞提示

### 2.1 问题

会话的工具调用停在 `awaitingApproval` 时，用户若正看着别的会话（或别的 App），**侧栏无任何信号**——审批卡只存在于该会话的气泡流里。并发场景下这是任务死锁的温床（审批没人点，回合挂起，还占并发名额）。

### 2.2 方案

- **数据**：ChatStore 增 `@Published private(set) var approvalBlocked: Set<UUID>`（会话级，非逐卡）。
  - 置入：`toolUpdated` / `toolPhaseChanged` 事件里 phase == `.awaitingApproval` → `insert(sid)`。
  - 移除：审批响应（approve/deny/alwaysAllow，phase 流转即清）、`streamEnded`（兜底清，防泄漏）、会话删除（evictTransport 路径）。
- **呈现**：侧栏行在 `isRunning` 转圈之外增加阻塞指示——`hand.raised` 琥珀色小图标（与 composer 审批开关同一符号语言），hover 提示"等待审批"。二者互斥时优先显示阻塞（阻塞是更紧急的状态）。
- **点击行为不变**：选中进 Chat 直接看到审批卡。

### 2.3 边界

- 不做通知/声音（v1；无人值守路径本来就关审批，会挂起的只有前台有人值守的会话）。
- 侧问/任务日志会话同样适用（统一按会话 id）。

### 2.4 冒烟 T26

审批事件置位 / 响应清除 / streamEnded 兜底清除 / 删除会话清除。

---

## 3. 快速捕获（Alt+X Spotlight 式悬浮输入条）

### 3.1 形态

```
┌──────────────────────────────────────────────┐
│ [folder] 项目名 ▾ │ 在这里输入该做什么…        │ ⏎ │
└──────────────────────────────────────────────┘
```

- 独立 **NSPanel**（`windowLevel = .floating`，无标题栏，居中偏上 1/3 处），SwiftUI 承载内容——P4.2 已验证主窗口外独立 NSWindow 尺寸可控。
- 组成：项目 pill（Menu 切换，默认 = 上次捕获所用项目，settings KV 记忆）+ 单行文本输入 + 发送键。**纯文本**（v1 不接图片/附件/@引用）。
- 行为：全局热键 toggle（显示时前置并聚焦输入框；再按或 Esc / 点击外部 → 隐藏）；**Enter 发送 → 立即隐藏**。

### 3.2 发送语义（已对齐：即发即跑）

- 走 `beginTurn` 无人值守路径：`askApproval = false`（审批卡没人点 = 死锁，P3.9 拍板沿用）。
- **工具集强制 Minimal 档**（read/bash/write/edit，`AgentMode.minimal` 现成），与该项目档位设置无关——无人盯着时收窄风险面。落库的会话档位标 Minimal，事后在主窗口继续对话时可正常切档（下回合生效）。
- 会话归属：选定项目的常规新会话（`ensureConversationForSend` 同路径），首条消息自动命名（P6.4 现成）。
- 反馈闭环：发送即隐藏 → 侧栏该会话转圈（isRunning）→ 完成弹系统通知（P4.1 非前台路径）。零新增反馈代码。

### 3.3 热键（已对齐：Alt+X）

- **Carbon `RegisterEventHotKey`**（无需辅助功能权限；不用 NSEvent global monitor）。默认 **⌥X**，设置页可录制改键（监听 keyDown 记 modifier+keyCode，存 settings KV）。
- **冲突处理**：注册失败（事件码非 noErr）→ App 内横幅提示"热键被占用，请在设置中更改"，不抢注、不降级猜测。
- Carbon 回调线程 → hop MainActor。

### 3.4 生命周期（已对齐）

- v1 限定 **App 进程存活期间**（含主窗口关闭后的驻留）；不做菜单栏常驻图标 / LaunchAgent / 登录自启（后置）。
- 热键触发时若 App 在前台且主窗口 Key → 同样弹出捕获条（行为统一，不分场景）。

### 3.5 边界（v1 明确不做）

- 不做输入历史/联想/多行；不与迷你台合并（完成闪显保持独立 NSWindow）；不做"草稿不发送"模式（就是发射口）。

### 3.6 冒烟 T27

- 热键配置解析（settings KV roundtrip + 修饰键编码）。
- 捕获发送链路：注入 transport 下 `submitCapture(text:project:)` → 会话创建 + 自动命名 + 无人值守审批策略 + Minimal 档下发（MockTransport 断言 lastMode/审批）。
- 发送后 `pendingCapture` 清空。

---

## 4. Settings 手动备份

### 4.1 形态

Settings 新增「备份」卡：一行说明 + 目标目录（显示已选路径，点击选择，NSOpenPanel，settings KV 记忆）+ **「立即备份」**按钮 + 上次备份时间/结果（成功大小 / 失败原因）。

### 4.2 备份内容与流程（同一目录、时间戳子目录）

```
<备份目录>/mangox-backup-<yyyyMMdd-HHmmss>/
├── mangox.db            (WAL checkpoint 后的主库文件)
├── attachments/         (全部图片附件)
└── sessions/            (pi transcript <uuid>.jsonl 目录)
```

流程：先 `wal_checkpoint(TRUNCATE)`（Database.swift 加入口；退出路径已有同款）→ 拷贝 db 主文件 → 递归拷 attachments 与 sessions 目录 → 汇总大小写回 UI。失败逐项报告（哪个源缺失/拷贝失败），不半途抛错。

### 4.3 立场

- **只做手动**（用户拍板），自动定时备份后置——本项先建"备份即拷贝"的最小可信动作。
- 不做压缩归档 / 增量 / 校验和（目录直拷，用户自己扔 iCloud）。
- 知识库在 db 内（knowledge_items 表），随库带走。

### 4.4 冒烟 T28

checkpoint 后拷贝源存在 / 时间戳目录生成 / db+attachments+sessions 三项齐 / 缺目录容错。

---

## 5. 第 7 批 · worktree 隔离（❄️ 已冻结，2026-09-15 评估后不做）

> **冻结记录（2026-09-15）**：评估结论 = 非必需品，缓建。
> 1. 前提不成立：同仓库多 agent 并行（实际并发 1-3 且多跨项目，cwd 即隔离边界）；无人值守任务以巡检/零散活为主，非深度改码。
> 2. git 本身是兜底隔离：tracked 文件损坏 `git checkout` 即回滚，单人场景合并义务纯增负（每任务 checkout/审阅/合并/清分支）。
> 3. 技术上只覆盖一半风险面：无人值守 `askApproval=false` 时 transport 对所有 bash 直接放行（含 `rm` 任意路径），worktree 圈不住进程级文件访问。
> 4. 升级条件：同一仓库 3+ 并行编码任务成为常态（配合轻编排）再重启本节。
> 5. 替代方案（如需无人值守风险收敛）：无人值守轮次默认只读工具门（`--tools read,grep,find,ls`），任务级可选「允许写入」——成本约为本节 1/10。

### 5.1 范围拍板（沿用 2026-09-14 拍板，冻结存档）

隔离只做 git worktree；`sandbox/`/`gondolin` 容器原语不做。**编排/共享记忆仍缓**，本批只做第一层。

### 5.2 作用对象与粒度

- **隔离单位 = 定时任务**（"一任务一 worktree"），普通会话不隔离（对话式工作流用户在场，切换 cwd 反而碍事）。任务编辑页新增开关「worktree 隔离」+ 分支名前缀。
- 前提：任务所属项目根目录是 git 仓库（无 `.git` → 开关禁用并提示）。

### 5.3 生命周期

| 阶段 | 行为 |
|---|---|
| 首次运行 | `git worktree add <root>/.mangox/worktrees/<taskId> -b mangox/task-<taskId>`（从项目默认分支 HEAD 起；目录已存在且是合法 worktree 则复用） |
| 每次运行 | pi spawn 的 cwd = worktree 路径（现有 `updateWorkingDirectory` 链路，切 cwd 重启进程为已知约束）；`--session` 绝对路径绑定不变（托管目录，**不用** `--session-dir`——MangoX 会话文件统一管理，fork 产物回读逻辑不受影响） |
| 任务删除 | 二次确认：「worktree 有未提交改动时仅提示路径不删除；干净则 `git worktree remove` + 删分支 `mangox/task-<taskId>`」 |
| 运行结束 | **不自动合并/不自动清理**——产物留在 worktree，用户在主窗口自行审阅合并（agent 在 worktree 里的 edit/write 天然隔离，主仓库零污染） |

### 5.4 三个预留问题的回答（roadmap §1.1 遗留）

1. **任务与项目的关系**：任务必属项目（现状即如此），worktree 从该项目根创建；无项目任务（cwd=nil）无隔离资格。
2. **清理策略**：见 5.3——删除时提示式清理，脏 worktree 不动；另提供任务编辑页「打开 worktree 目录」（Finder reveal）方便人工处理。
3. **知识库作用域**：project 作用域按主仓库根判定（现状），worktree 内容同源，注入不换轨；跨任务污染问题由隔离本身解决（这正是先做隔离的动机）。

### 5.5 边界

- 不做 worktree 池/预热；不做主窗口内 worktree 文件树切换（工作区栏仍显示主仓库——任务产物审阅走 Finder/Terminal，v1 接受）。
- Windows / 非 git 项目明确不支持。
- 子模块/LFS 场景不特殊处理（git worktree 原生行为兜底）。

### 5.6 冒烟 T29

worktree 创建命令拼装（纯函数：root/taskId → add/remove/branch 参数矩阵）/ 已存在复用 / 脏目录判定不删 / 无 .git 禁用路径。

---

## 6. 总序与门禁

| # | 项 | 状态 | 门禁 |
|---|---|---|---|
| 1 | 侧栏日分组 | ✅ 已落地 | T25 |
| 2 | 审批阻塞提示 | ✅ 已落地 | T26 |
| 3 | 快速捕获（⌃⌥X，含追加既有会话） | ✅ 已落地 | T27 |
| 4 | 手动备份 | ✅ 已落地 | T28 |
| 5 | worktree 隔离 | ❄️ 冻结（评估后不做，见 §5） | — |

附加修复（实机返工）：侧栏 updatedAt 活跃刷新（T25b）、mini 台安全区裁卡、sessionRow 传参竞态丢失（T26b 真链路冒烟补测）。

实施序 2 → 4 → 3 → 5 已走完前三项，第 5 项冻结。每项独立 commit，全量冒烟 ALL PASS 后推进下一项。
