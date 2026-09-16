# P9 — 全库代码 Review 问题清单与修复计划

> 基线: v0.1.6 (commit `0141ba0`)。Review 范围: MockData / PiRpcTransport / PersistenceStore / Database /
> QuickCaptureController / MemoryDistiller / ImagePipeline / ModelMaterializer / 主要视图层。
> 日期: 2026-09-15 review, 2026-09-16 定档。
> 共同教训: #1/#2/#4 均属"注入态冒烟测不到"类 (delegate 挂接点 / 库事件一致性 / 视图销毁路径),
> 每项修复必须配套针对性冒烟断言。

---

## 一、问题清单

### A. 真 Bug (6 项)

| # | 问题 | 代码位置 | 解决方式 |
|---|------|---------|---------|
| 1 | **Trace 导出永远走 20s 超时**: `exportTraceHTML` 创建的临时 transport 未设 `t.delegate = self`, pi 导出结果只经 delegate 回调上报 (nil → 静默丢弃) → 永远报"导出超时", 文件已生成但不 reveal, `isExportingHTML` 卡 20s | MockData.swift:2378-2394<br>PiRpcTransport.swift:380,398 | 补一行 `t.delegate = self`; 冒烟补断言:临时实例 delegate 回调能触发 finishExport |
| 2 | **regenerate 只删内存不删库**: `messages.removeSubrange` 后旧 assistant 回复的 events 行仍在 → 重启/replay 后旧回复复活, 与新回复并存两份答案 | MockData.swift:1284-1291 | PersistenceStore 增加按 seq 截断删除 (最后一条 user 之后的 message + tool_update), regenerate 时同步清库; 冒烟: regenerate → 重放 → 断言无旧回复 |
| 3 | **捕获条点主窗口关不掉**: 只装 `addGlobalMonitorForEvents` (只回调其他 App 的点击); 捕获条唤起时 App 已激活 → 点主窗口/侧栏不隐藏 | QuickCaptureController.swift:120-127 | 补一路 local monitor: `event.window !== panel` 则 hide; 面板内交互不受影响 |
| 4 | **热键录制 monitor 泄漏 + 功能假死**: 录制中切走 → SettingsView 被 ContentView if/else 分支销毁, NSEvent local monitor 无人清理 → 永久吞全 App 修饰键 (⌘C/⌘V/⌘W 失灵); 再进设置页 `guard keyMonitor == nil` no-op | SettingsView.swift:574-595 | 加 `.onDisappear { stopHotkeyRecording() }` |
| 5 | **管道断裂崩溃**: `stdinHandle.write(_:)` 在 pi 进程死亡后抛 ObjC 异常 (`NSFileHandleOperationException`), Swift 接不住 → 整 App 崩 | PiRpcTransport.swift:546<br>MemoryDistiller.swift:179 | 两处换 throwing 版 `try stdinHandle.write(contentsOf:)` + do/catch 静默 (失败即进程已死, 后续 teardown 收尾) |
| 6 | **sentCommands 无界增长 (含 base64 图片全文)**: 每条命令无条件 append 永不清理, `send()` 的 cmd 含 images base64 (单次可几 MB); `internal` 而非 `#if DEBUG`, Release 同样泄漏 | PiRpcTransport.swift:542 | append 包 `#if DEBUG` 并剥离 images 字段 (只记 type+id 元信息), 或环形缓冲; 默认取前者 |

### B. 性能 / 用户体验 (7 项)

| # | 问题 | 代码位置 | 解决方式 |
|---|------|---------|---------|
| 7 | **流式渲染 O(n²)** (最大性能项): 每 chunk → MarkdownView 整条消息全量重新 parse + CodeBlockView 重新语法高亮; 长回复后 CPU 飙升、掉帧 | MarkdownView.swift:14<br>CodeBlockView.swift:49 | parse 结果按 text 缓存 (Equatable 短路); 流式期只重解析最后一个 block; `ForEach id: \.offset` 改稳定 id 复用 block 视图 |
| 8 | **粗粒度 @Published 单体**: ChatStore 30+ @Published, 流式每 chunk 触发 SidebarView (sorted+分桶+relativeTag)、ChatComposer (模型菜单笛卡尔积) 等无关视图重算 | MockData.swift 全域 | 拆子 store (messages/sidebar 各自 ObservableObject), 或侧栏只订阅投影 |
| 9 | **流式期间滚动劫持**: `onChange(of: store.messages)` 每 chunk 强制 scrollTo bottom → 用户上滑读历史被反复拽回 | ChatView.swift:71-80 | 滚动前判定"是否接近底部" (offset 追踪), 上滑时暂停自动跟随 |
| 10 | **会话切换全量重放 + 磁盘扫描**: 每次点侧栏会话 = loadMessages 重放全部 events 行 (逐条 JSON decode) + syncWorkspaceContext 扫盘 + scanExtensions + DB 读; events 表只增不减 (每工具 3+ 行 tool_update + 终态再存整条 message) | PersistenceStore.swift:343-404<br>MockData.swift:695-705,2105 | loadMessages 结果按会话缓存 (写入时失效); appendEvent 的 `SELECT MAX(seq)` 改内存游标; 规划 tool_update 历史压缩策略 |
| 11 | **备份主线程同步执行**: 递归拷贝 attachments/sessions 在 @MainActor, 附件库长大后 UI 冻结 (代码注释已自知) | MockData.swift:466-491 | Task.detached 后台执行 + 完成回主线程刷新摘要; `backupRunning` 防重入保留 |
| 12 | **附件缩略图同步解码无缓存**: `NSImage(contentsOfFile:)` 每次渲染全图解码, 滚动历史 + 流式重算时反复 IO | ChatView.swift:278,300 | NSCache 按 path 缓存缩略图 (88×66 下采样) |
| 13 | **QuickCapture 拒绝路径丢输入**: `submit()` 忽略 `submitCapture` 返回值, 被拒时面板照样关闭+清空文本 | QuickCaptureController.swift:218-226 | 返回 nil 时不 hide/不清空, 横幅提示后聚焦输入 |

### C. 维护性 (4 项)

| # | 问题 | 代码位置 | 解决方式 |
|---|------|---------|---------|
| 14 | **ChatStore god object**: 2430 行承载 transport 池/调度器/知识库/备份/捕获/模型自管/侧问/离开摘要/导出/审批路由 10+ 职责, 且在 `Mock/` 目录名不副实 | MockData.swift 全文件 | 按职责拆 (ChatState / SchedulerService / CaptureService / ModelStore), 文件改名 ChatStore.swift |
| 15 | **`appIsForeground` / `appIsActive` 双胞胎**: 同为 `Bundle.main` guard + `NSApp.isActive`, 冒烟兜底方向相反 (一个 false 一个 true), 极易用错 | MockData.swift:2165-2168, 2200-2203 | 合并为 `isAppActive(headlessDefault:)` 单一实现 |
| 16 | **持久化错误全 `try?` 吞掉**: persistMessage/insertChatSession/appendMessageEvent 全部静默; 磁盘满/库损坏时消息只活到下次重放, 无任何信号 | MockData.swift / PersistenceStore.swift 全域 | 集中一个 `persist()` 包装: 失败打日志 + 一次性用户可见横幅 |
| 17 | **后台审批卡不可达假设未闭环**: attended 定时任务 (unattended=false) 在后台日志会话 fire 时审批卡进 liveTurns 镜像, UI 无入口 → 靠 pi 32s 超时 deny 兜底 | MockData.swift:1999-2005 | 二选一: fire 时强制 unattended (与捕获同语义), 或侧栏琥珀标点击直达该会话审批卡 |

---

## 二、修复计划 (3 批次)

分批原则: **先崩潰与功能失效 → 再数据一致与内存 → 最后性能与结构**。
每批次以冒烟门禁收口 (`bash scripts/smoke/run.sh` ALL PASS, 含新增断言), 批内一次性批量改完 (一遍过),
改完不自动 commit, 等用户确认。

### Batch 1 — 崩溃与功能失效 (P0, 一行级修复为主) ✅ 2026-09-16 完成

| 项 | 改动 | 新增冒烟断言 |
|----|------|-------------|
| #1 | exportTraceHTML 补 `t.delegate = self` | 注入实例模拟 export 回调 → finishExport 摘要横幅 |
| #4 | SettingsView 加 `.onDisappear { stopHotkeyRecording() }` | 视图销毁路径, 冒烟不可达 → 实机验证项 |
| #5 | PiRpcTransport.sendCommand + MemoryDistiller.send 换 throwing write + catch | 无进程时 cancel/send 不崩 (现行为), 补 stderr 静默日志 |
| #3 | QuickCaptureController 补 local monitor 双路关闭 | 面板窗口判定纯逻辑可测; 实机验证: 点主窗口关闭 |

- 风险: 低。全部是局部改动, 不碰数据面。
- 收口: 冒烟全绿 + 实机自查 (热键录制中途切页再回来 / ⌃⌥X 唤起后点主窗口 / Trace 导出)。

### Batch 2 — 数据一致性与内存 (P1, 需新增持久层 API) ✅ 2026-09-16 完成

> 实施注记: #6 落地为 `#if DEBUG` + 只存 type/id 元信息, run.sh 同步加 `-D DEBUG`
> (原门禁未定义 DEBUG, 直接包裹会让 T14/T26b 断言失效); #17 落地为 fire 恒传
> `unattended: true`, `task.unattended` 字段保留仅作历史记录 (UI 开关语义后随 P9.1 清理)。

| 项 | 改动 | 新增冒烟断言 |
|----|------|-------------|
| #2 | PersistenceStore 增 `deleteEventsAfterLastUser(sessionId:)`, regenerate 调用 | regenerate → loadMessages 重放 → 断言旧回复消失、user 保留 |
| #6 | sentCommands append 包 `#if DEBUG` + 剥离 images (只存 type/id) | 现有 T26b/T27 断言不依赖 images 字段, 全量回归验证 |
| #13 | QuickCaptureView.submit 检查 submitCapture 返回 nil → 不 hide 不清空 | 已有 T27 拒绝路径断言, 补 UI 态断言 (text 保留) |
| #17 | 定稿: fire 时强制 unattended (与捕获同语义, 成本 1/10 方案), ScheduledTask.unattended 文档注记 | runScheduledFire 强制路径断言 |

- 风险: 中。#2 动 events 表写路径, 需确认不破坏 tool_update 重放; #6 需全量回归冒烟。
- 收口: 冒烟全绿 (含新断言) + 实机验证 regenerate 重启不复活。

### Batch 3 — 性能与结构 (P2, 可拆小批推进) ✅ 2026-09-16 完成 (不含 #14/#8)

> 实施注记: #7 落地为 MarkdownParser/CodeHighlighter 各带 LRU 缓存 (流式期历史消息全部命中,
> 只重解析流式中那一条 — 全量 O(n²) 根因消除; 增量解析留后续); #10 落地为
> replayCache + seqCursor (删除/截断路径清空回落 SELECT MAX); #11 落地为
> performManualBackupInBackground + backupFailureMessage 弹窗 (同步版保留供冒烟 T28);
> #16 先收敛核心数据路径 5 处 (persistOrNotify), 其余 try? 调用点随 P9.1 收敛;
> #9 落地为 PreferenceKey 双探针 + nearBottom Bool (140pt 阈值)。ChatView 拆子表达式
> (scrollColumn/scrollContent/messageBlocks) 解决 type-check 超时。#14/#8 归 P9.1。

| 项 | 改动 | 新增冒烟断言 |
|----|------|-------------|
| #7 | MarkdownView parse 缓存 + 稳定 id; CodeBlockView 高亮缓存 | 现 320 断言回归 (纯视图层, 冒烟主要保编译) |
| #9 | ChatView 滚动: near-bottom 判定, 上滑暂停自动跟随 | 无 (实机验证) |
| #10 | loadMessages 会话级缓存 + appendEvent 内存 seq 游标 | 重放正确性: 现有 replay 相关断言全量回归 |
| #11 | 备份挪后台 Task.detached | T28 断言回归 (同步语义改异步, 断言改轮询/回调) |
| #12 | 附件缩略图 NSCache | 无 |
| #15 | appIsForeground/appIsActive 合并 | 无 (等价重构) |
| #16 | persist() 集中包装: 日志 + 一次性横幅 | 写库失败注入 (冒烟只验成功路径不回归) |
| #14 | ChatStore 拆分 (最大项, 建议单独小批: 先文件改名 → 再拆 SchedulerService/CaptureService) | 全量回归 |
| #8 | 粗粒度 @Published 拆分 (与 #14 同期做, 拆分即顺手解决) | 全量回归 |

- 风险: 高。#14/#8 是结构手术, 建议放本批末位, 且 #14 单独立项为 P9.1 (拆分不动行为, 冒烟全量回归为门禁)。
- 收口: 冒烟全绿 + 实机验证 (长回复流式流畅度 / 上滑阅读不被拽回 / 多会话切换延迟)。

### 批次依赖与顺序

- Batch 1 → Batch 2 串行 (Batch 2 的 #6 全量回归依赖 Batch 1 先稳定基线)。
- Batch 3 内: #7/#9/#11/#12/#15/#16 可并行小步; #10 独立; #14/#8 收尾单独小批。
- 全部完成后: 0.1.7 发版流程 (版本号 6 处 → CHANGELOG → README → 冒烟 → commit)。

---

## 三、P9.1 — 结构手术计划 (#14 ChatStore 拆分 + #8 @Published 粒度)

> 前提: Batch 1-3 已完成 (333 ALL PASS)。原则: **拆分不动行为** — 每小批以全量冒烟
> (333 断言) 为门禁, 对外 API 尽量保持外观 (facade), 冒烟与视图改动最小化。
> 目标终态: `Mock/MockData.swift` (2430 行) 消失, ChatStore 核心收敛到 ~1000 行。

### 拆分目标 (按职责, 各自 @MainActor)

| 子模块 | 承载内容 | 预估行数 | 目标文件 |
|--------|---------|---------|---------|
| ChatStore 核心 | messages/draft/pendingImages、transports 池、runningTurns/approvalBlocked、liveTurns、beginTurn/handleTurnEvent 事件归并、审批路由、侧问/离开摘要/导出 | ~1100 | `State/ChatStore.swift` |
| SchedulerService | scheduledTasks/showScheduledPanel、schedulerTimer/fire 链路、buildScheduledPrompt/waiting 协议、handoff 文件读写、finishWaitingFire | ~380 | `State/SchedulerService.swift` |
| KnowledgeStore | knowledgeItems/showKnowledgePanel、注入块组装、蒸馏 (prompt/回调/候选/审核)、saveAsMemory | ~320 | `State/KnowledgeStore.swift` |
| ModelStore | availableModels/customModels/managedModels、currentProvider/ModelId/thinkingLevel、模型菜单、ModelMaterializer 物化下发 | ~320 | `State/ModelStore.swift` |
| CaptureService | CaptureTarget/captureHotkey/submitCapture/memo KV | ~150 | `Agent/CaptureService.swift` (与 QuickCaptureController 同居) |
| BackupService | backupDirectory/backupRunning/performManualBackup 两版/摘要 KV | ~110 | `State/BackupService.swift` |

### 小批推进 (每批冒烟门禁收口, 不动行为)

| 小批 | 内容 | 关键风险 | 冒烟配套 |
|------|------|---------|---------|
| a. 物理迁移 ✅ 2026-09-16 | MockData.swift → `State/ChatStore.swift` (改名+移动, 零代码改动); pbxproj 文件引用同步更新 | pbxproj 路径遗漏导致 Xcode 工程缺文件 | 全量回归 (编译即覆盖) |
| b. SchedulerService ✅ 2026-09-16 | 定时任务全链路抽离; ChatStore 持有并**转发** `scheduledTasks` 等 API (facade, 冒烟零改动) | fire 链路与 ChatStore 的 runningTurns/beginTurn 交叉引用 → 服务持有 store 弱引用, 只通过 store 公开接口回调 | 现有 fire/等待型断言回归 + runScheduledFire 无人值守断言 (T-P9b) |
| c. KnowledgeStore + ModelStore ✅ 2026-09-16 | 知识/模型两域抽离; 物化下发 (refreshPIConfig) 落 ModelStore, ChatStore 转发 | 模型期望值 (userThinkingLevelPinned) 与事件上报归并耦合在 ChatStore delegate → 边界: 归并留 ChatStore, 状态与菜单进 ModelStore | 现有 T21/T22/T22b/T23 + 蒸馏相关断言回归 |
| d. CaptureService + BackupService ✅ 2026-09-16 (#17 已清) | 两个小域抽离; #17 遗留: ScheduledView "无人值守"开关语义清理 (fire 恒 unattended 后开关无效 → 移除或改为提示文案) | 无 | T27/T28 断言回归 |
| e. #8 粒度 (收尾) ✅ 2026-09-16 | 子 store 各自 ObservableObject, 视图直订: SidebarView 订阅 chats/projects 投影 (SidebarModel)、ChatComposer 模型菜单直订 ModelStore (ModelMenuSection) — 消除"流式每 chunk 全 UI 重算"。注: 其余面板仍走 facade + objectWillChange 转发 (逐步), 视图接线改动冒烟不可达, 需实机验证 | 视图层改动面大; facade 转发属性不能再是 @Published, 需逐视图核对订阅源 | 全量回归 + 实机: 流式期侧栏/菜单不重算 (Instruments Core AnimationFPS) |

### 关键约束

1. **facade 优先**: 冒烟通过 `ChatStore(transport:dbPath:managedExtensionsDir:)` 注入并直访
   `store.scheduledTasks` / `store.submitCapture` 等公开 API — 拆分后 ChatStore 保持同名转发
   (computed property → 子 store), 小批 a-d 冒烟零改动; e 批起才逐步让视图/冒烟直订子 store。
2. **事件归并留核心**: AgentTransportDelegate 的 sessionOf/handleTurnEvent 是路由中枢, 不迁出。
3. **禁止顺手重构**: 拆分批内不做行为/命名优化; try? 收敛余项 (#16) 在 b/c/d 各域迁移时随域完成。
4. 每小批完成后 commit 一次 (一行标题, 如 `MangoX: P9.1b scheduler split`), 出问题可单批回退。

