# Changelog

本文件记录 MangoX 的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [0.1.1] - 2026-09-10

### Added

- **Scheduled cron 四档录入器**：每天（自绘时间输入）/ 每周（星期多选 chips + 时间）/ 间隔（N + 分钟/小时）/ 高级（表达式文本框兜底）——控件生成 cron，调度器零改动；编辑时反解析回填控件态，手写复杂表达式落高级档；`CronExpr.describe` 人类可读预览（"每天 09:00" 等，识别不出显示原文），任务列表状态行复用
- **记忆自动提炼 v1（人工触发）**：assistant 消息工具条"提炼"按钮 → 独立一次性 pi 进程（与主引擎并行，拒绝一切工具调用，60s 超时）→ 提炼模板（最近 12 条消息 + 现有条目清单去重）→ 候选落 pending（永不注入）→ 知识面板"待审核"分组人工采纳/丢弃；Sidebar Knowledge 角标显示候选数；结果横幅反馈成败与候选数
- **消息工具条重做**：从 hover 悬浮改为消息底部常驻淡显（修复 hover 追逐闪烁），图标 + 文字标签（复制/记忆/提炼/重新生成）

### Changed

- 知识库 token 预算上调：单条 8k→16k chars，总量 24k→64k chars
- `knowledge_items` 加 `status`/`note` 列（pending 候选与 enabled 启停正交，note 存提炼依据）

### Fixed

- 定时任务保存不校验 cron 合法性（手写错误表达式也能入库）
- 修复 Xcode "Copy Bundle Resources contains Info.plist" 警告（同步组 exception 排除 Info.plist，bundle 不再冗余拷贝）
- 提炼候选归属：从会话所在项目分组反查（`selectedProjectId` 在侧栏点开会话时不同步导致"未知项目"条目）；project 候选无归属时降级 global 兜底

## [0.1.0] - 2026-09-10

首个公开版本。

### Added

- **对话与 Agent**
  - per-turn 进程架构：每回合拉起一个 pi 进程，跑完即退（无常驻内存、无会话串味）
  - 会话持久化：`--session` 挂载 `<uuid>.jsonl`，重启 App / 切会话 / 切项目不失忆
  - 审批流：bash 只读白名单静默放行 + 学习白名单（"始终允许"沉淀）；edit/write 审批卡带红绿块对照 diff 预览
  - 工具卡：bash / read / edit / write / fetch 全事件上屏，含真实执行时长（审批等待不计入）
  - 引擎缺失保护：pi CLI 不在时显示不可用横幅，不静默降级
- **项目模式**
  - 项目绑定工作目录，pi cwd 跟随切换
  - 工作区栏：懒加载文件树、git 分支/脏文件/每文件 `+n -n` 行数统计、最近提交、语言构成条、「本会话改动」标记、文件过滤、代码预览
  - composer @ 文件引用
- **知识库与调度**
  - 知识库：全局 / 项目两级作用域，spawn 期 system prompt 注入
  - 定时任务：cron 调度、等待型哨兵、持续模式（交接文件携带连续性）
  - 任务日志会话：运行时间线追加式记录，冲突跳过落痕
- **工程化**
  - SQLite (WAL) 持久化 + 事件流重放加载；退出时 checkpoint 并终止在途 pi
  - 扩展管理：内置 mangox-approval（源码内嵌自动重建），托管扩展启停/导入/删除
  - 内置 JetBrains Mono（SIL OFL），深/浅色自适应主题，🥭 App 图标
