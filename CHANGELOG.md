# Changelog

本文件记录 MangoX 的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

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
