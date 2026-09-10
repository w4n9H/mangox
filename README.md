# MangoX

macOS 原生 AI Agent 客户端（SwiftUI），对标 Codex Desktop 的交互形态，底层对接 [pi CLI](https://github.com/mariozechner/pi-coding-agent) 作为推理引擎。

![version](https://img.shields.io/badge/version-0.1.0-orange)

## 功能

**对话与 Agent**
- per-turn 进程架构：每回合拉起一个 pi 进程，跑完即退，无常驻内存与会话串味
- 会话持久化：`--session` 挂载 `<uuid>.jsonl`，重启 App / 切会话 / 切项目不失忆
- 审批流：bash 只读白名单静默放行，edit/write 审批卡带红绿块对照 diff 预览
- 工具卡：bash / read / edit / write / fetch 全事件上屏，含真实执行时长（审批等待不计入）

**项目模式**
- 项目绑定工作目录，pi cwd 跟随切换
- 工作区栏：懒加载文件树（大仓库毫秒级展开）、git 分支 + 脏文件 + 每文件 `+n -n` 行数统计、最近提交、语言构成条、「本会话改动」标记（agent edit/write 触达的文件）、文件过滤、内置预览
- @ 文件引用：composer 里 @ 唤起文件补全

**知识库与调度**
- 知识库：全局 / 项目两级作用域，spawn 期 `--append-system-prompt` 注入
- 定时任务：cron 调度 + 等待型哨兵（扫任务完成标记）+ 持续模式（交接文件携带连续性，磁盘为准零缓存）
- 任务日志：每个任务一个日志会话，运行时间线追加式记录；冲突跳过也落痕

**工程化**
- SQLite 持久化（WAL），事件流重放式加载；退出时 WAL checkpoint + 终止在途 pi 进程
- 扩展管理：内置 mangox-approval（源码内嵌, 每次 spawn 自动校验重建，换机器零影响），托管扩展启停/导入/删除
- 内置 JetBrains Mono（SIL OFL），等宽三级字体链
- 深/浅色自适应主题

## 要求

- macOS 14.8+
- Xcode 16（构建）
- [pi CLI](https://github.com/mariozechner/pi-coding-agent) 已安装且在 `PATH`（缺 pi 时 App 会显示引擎不可用横幅，不会假装在回复）
- pi 侧已配置模型 provider 与 API key

## 构建

```bash
open mangox.xcodeproj   # Xcode 里 Cmd+R
```

## 已知限制 (v0.1.0)

- **长会话上下文线性增长**：pi transcript 无 compaction，单会话建议控制在几十轮内，过长后每次拉起的 token 成本与延迟都会上升
- **agent 改文件后文件树不自动刷新**：工作区栏有手动刷新按钮；自动增量刷新在路线图上
- **asset catalog 未接入构建**：App 图标走 `Resources/AppIcon.icns`（工程 synced group 的历史问题），新增图片类资源时需留意
- **fire 冲突跳过**：定时任务到点但有回合在途时跳过本轮（cron 到期不重排），跳过记录会写进任务日志会话

## License

见 [LICENSE](LICENSE)。
