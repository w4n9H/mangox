# Changelog

本文件记录 MangoX 的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [0.1.8] - 2026-09-20

本版主线 = **P10 冲刺**：邮箱哨兵（Inbox）新子系统 + 会话/任务级配置持久化 + 会话切换零阻塞。全量冒烟 **541 项 ALL PASS** + `xcodebuild` BUILD SUCCEEDED 零 warning。邮箱哨兵已**真机跑通 收信 → 执行 → 回执**（2026-09-20）。

### Added

- **邮箱哨兵（Inbox）**：一个邮箱 = 一个远程入口 —— 发一封邮件给专用邮箱，MangoX 在自己的项目目录里无人值守跑任务，跑完把结果**回执**回你的邮箱（手机在外也能派活）。全新子系统：4 张表 + 收/发通道 + 鉴权 + 回执链路 + 面板
  - **鉴权四道闸**（确定性规则，模型不参与）：①发件人白名单 ②首封须同时含 `[MGOX]` 意图标记 + 主题共享密钥（**密钥只在首封校验**）③首封 Date ≤ 7 天 ④Message-ID 幂等。**主防线 = 白名单 + 只 poll INBOX** —— 借服务商 SPF/DKIM/DMARC 过滤当免费的第一道闸，共享密钥只是覆盖「白名单含未配 DMARC 的域」的第二道
  - **多轮续跑**：直接**回复回执**即可，无需再带密钥（靠 `References` / `In-Reply-To` 命中线程键；主题里的 `[MGOX-<id8>]` 是客户端剥掉 References 时的兜底）。同一线程**续在同一会话**，cwd 吃**首封项目快照**（改配置不让历史线程漂移）
  - **回执状态机**：主题 `[MGOX][DONE|BLOCKED|FAILED] [MGOX-<id8>] <标题>`，手机上不点开即可扫进度；正文 = 产出 + 拦截清单 + 结算行（状态 / 耗时 / 轮次 / tokens / 费用）
  - **收/发通道**：封装系统 curl（`imaps://` 收 / `smtps://` 发）+ 自写 `MimeParser`（头折叠 / RFC2047 B+Q / multipart 递归取 text/plain / QP / base64 / charset 含 GB18030）与 `MailMessageBuilder`
  - **面板**：Settings 新增**邮箱账号池**（可多个 + 163/126/QQ/阿里云四家个人邮箱预设 + 一键测试连接）；Scheduled 页新增 Inbox 段与**最近拒收**面板（含「加入白名单」快捷按钮）
  - **凭据纪律**：授权码/密钥一律**不入库**（Keychain 按 id 分账 `mailbox.acct.<id>.auth` / `mailbox.sentinel.<id>.secret`），UI 永不回显已存凭据（留空 = 不修改）
  - ⚠️ **163 / 126 暂不可用**：网易强制客户端在登录后、`SELECT` 前发 IMAP `ID` 自报身份，当前 curl 通道的命令顺序固定、发不出 → 本版请用 **QQ / 阿里云个人邮箱**。用企业邮箱同理不支持（Outlook/Office365 已弃 IMAP basic auth）
- **审批三档（`ApprovalMode`）**：`Interactive`（弹卡等人点）/ `Auto allow`（全放行）/ `Auto judge`（只读静默放行，危险命令**自动拒绝且不阻塞** + 记原因并回执告知）。无人值守路径一律不走弹卡（后台没人点 = 死锁到超时），新增 `beginTurn(approvalOverride:)` 供哨兵 / 定时任务压过全局档位
- **会话级配置持久化（P10.3）**：`sessions.config` 记录每个会话自己的模型 / 思考级别 / 模式档 / bypass —— 重启不再全部回默认。恢复链 = 本会话配置 → **App 默认配置**（`app_default_config` KV）→ `last_session_config` 兜底；**被动浏览（切会话）永不写行**，只有用户动作（选模型 / 拨开关 / 新建会话）才写穿
- **定时任务级模型 / 模式配置（P10.4）**：`scheduled_tasks.config` 复用同一份 `SessionConfig` —— 重活跑 full + 高级模型、轻任务跑 minimal + 便宜模型。fire 时**只对那个会话的 transport 生效**，不污染全局状态；任务日志会话也 stamp 该配置，点开即知「这个任务用的什么模型」
- **只读 IMAP 诊断探针** `scripts/diag/imap_probe.py`：凭据只从环境变量读、输出全程脱敏、只用 `BODY.PEEK[]`（不 STORE / COPY / EXPUNGE）—— 用来一轮定案「我们发错了」还是「服务器不收」

### Changed

- **调度页命名体系按触发源统一**：定时任务 → **Cron** / 条件等待任务 → **Watch**（原「哨兵任务」）/ 邮件驱动 → **Inbox**（原 Sparse Agent，退为概念统称）。页面名保留 **Scheduled**；账号池（连接 / 凭据）留 Settings，agent + 拒收搬到 Scheduled；编辑器顶部**三档段选** Cron / Watch / Inbox，从编辑器直达三类
- **会话切换零阻塞（P10.5）**：重放缓存改**增量维护**（`appendEvent` 后原位 append / patch，乱序才惰性重排），切会话改**先切再渲染**（缓存命中同步上屏；未命中先空态 + **独立只读连接**后台 decode 再合并落地，带代数校验防串台）。实测首切 1000 消息会话，同步部分 **0.1ms**（后台落地 22.4ms）、缓存命中切换 **0.4ms**
- **长会话渲染与内存（P10.6a）**：消息列表 `VStack` → `LazyVStack`（视图构建成本从 O(总条数) 降到 O(视口)）；重放缓存加**访问序 LRU、上限 8 个会话**（只丢缓存不改库，下次读回落全量 SELECT）

### Fixed

- **`BashRiskEvaluator` 六类误放行洞**（自动裁决档的安全底座）：四类参数洞（`find -exec` / `env <cmd>` / `sort -o` / `curl·wget -o|-O|-T`）+ 早期实现整段剥 `2>` / `&>` 误放行 `ls 2>err.txt` + `2>&1` 的 `&` 被当组合分隔符切出假 token。语料 31 危险 + 27 只读全绿
- **邮箱通道四个真机 bug**（2026-09-20 联调实测，均已修 + 冒烟不变量守住）：
  - **取信拿不到正文**：`curl -X 'FETCH n BODY.PEEK[]'` 只把 IMAP **响应行**吐到 stdout（后面的大块字面量根本不读，只有 31 字节）→ 改走 curl **内置** `imaps://host/INBOX;UID=n` 路径，stdout 即裸邮件字节。代价 = 内置路径硬编码 `BODY[]`，**取信即置已读**（顺带好处：被拒的信也只出现一轮，不再每轮重复记同一条拒收日志）
  - **序号 vs UID 坐标系错位**：RFC 3501 裸 `SEARCH` 返回**消息序号**、`UID SEARCH` 才返 UID（信箱只剩 1 封而 `UIDNEXT 97` 时，两者是 `1` 与 `96` 的差别）→ 全链统一到 UID 空间（`UID SEARCH` / `UID FETCH` / `UID STORE` / `UID COPY`）+ 冒烟不变量防回归
  - **回执发不出去**：curl 不给 SASL 机制时自选 PLAIN，而 **QQ 的 SMTP 只接受 `AUTH LOGIN`**（同一台服务器的 IMAP 反而接受 PLAIN）→ 同一个授权码「IMAP 全通、SMTP 登不上」，看着像授权码没开 SMTP 权限。全链钉死 `--login-options AUTH=LOGIN`；「测试连接」由「只测 IMAP」改为**收发两个方向都验**（新增不发信、只认证的 `smtpAuthProbe`）
  - **失败静默**：回执发送失败原先只写进一个**没有任何视图消费**的字段 → 「任务跑了、会话建了、回执没到」而界面一片正常。现接进 Inbox 编辑器「运行状态」卡
- **多轮（后续轮）五条，含一条全域死锁**：①在途任务被后续轮**降级**成排队态 → 落定钩子按 `running` 反查落空 → **串行位永不释放，此后所有哨兵的邮件只进不出**（触发极日常：agent 干活时你在同一线程再回一封）②同线程连发两封原为**覆盖**语义（前一封指令静默丢失）→ 改为合并成一轮 ③回执主题的状态 tag 逐轮累积成 `[DONE] [DONE] …` → 清洗规则改由状态机 `allCases` 派生 ④引用行判定不认 QQ webmail 的 `------ 原始邮件 ------` → 第 2 轮起 prompt 会内嵌上一轮全文 ⑤崩溃残留的幽灵 `running` 行会被落定钩子命中，把**用户自己那轮**的产出当回执发出去 → 重启时一并判失败
- **两处胶囊下拉点不中**（SwiftUI `Menu` 内容只吃 Button / Toggle / Picker，照 `Picker` 写成 `.tag` 会整列渲染成禁用项，编译期零信号）→ 抽公共件 `CodexPillMenu` + `✓` 前缀标选中
- 垃圾箱名不再硬编码（`Trash` 在 QQ 上真名是 `Deleted Messages`，且 QQ 不返回 `\Trash` 标志、运行时判不出来）→ 候选列表逐个试 COPY，全失败仍打 `\Deleted`，**永不 EXPUNGE**

## [0.1.7] - 2026-09-16

### Fixed

P9 质量大扫除（全库 code review 出的 17 项，本版修 15 项，其余 2 项随结构手术完成）：

- **Trace 导出 HTML** 正常生成并在 Finder 显示（导出实例 delegate 断链）
- **regenerate 不再残留旧回复**：库侧按最后一条 user 事件截断，重启后不复活旧副本
- **捕获条**：点击主窗口/外部即关闭（菜单弹层放行）；空文本/引擎缺失/并发满被拒时面板与输入保留
- **热键录制**中途切页自动停止，不再误吞后续按键
- 引擎 stdin 写入换 throwing 版，写失败落日志
- **定时任务 fire 恒无人值守**（后台日志会话审批卡无 UI 入口，弹卡=任务卡死到超时）；Scheduled 编辑器开关改"无人值守 · 恒开"徽章，语义与运行时行为对齐
- **长回复流式掉帧**：Markdown 解析 / 代码高亮 LRU 缓存（历史消息不再每 chunk 全量重解析）+ 运行指示器换低频 tick + CA 插值合成
- **上滑阅读不拽回**：距视口底 <140pt 才自动跟随；自动滚动同帧合并（消除 `onChange multiple times per frame`）
- regenerate / 删除会话后重放一致（重放缓存 + seq 游标失效）
- **手动备份转后台线程**，大附件库不再冻结主线程；失败细节弹窗（"备份失败"alert）
- 知识编辑器标题留空自动取正文首行前 24 字（与"保存为记忆"命名规则对齐），正文必填即可保存
- 图片附件 NSCache 缓存，缩略图/大图不再重复解码
- 全量冒烟 333 项 + xcodebuild 零 warning 双门禁

### Changed

- **ChatStore 结构手术（P9.1）**：2430 → 1948 行，按职责拆出 5 个子 store——SchedulerService（定时任务全链路）/ KnowledgeStore（知识库+蒸馏）/ ModelStore（模型状态+菜单+自管物化）/ CaptureService（快速捕获）/ BackupService（手动备份）+ SidebarModel 侧栏投影；ChatStore 留同名 facade 转发，事件归并留核心
- **流式期局部重算**：侧栏（chats/projects 投影直订）与模型菜单（直订 ModelStore）不再随消息 chunk 全 UI 重算
- **运行指示器 CodexSpinner**：四形态（星芒慢旋 / 星芒呼吸 / 呼吸环 / 旋转弧），默认星芒慢旋 + 微呼吸；规避 repeatForever 行复用丢事务与逐帧驱动掉帧两代教训
- 文档收敛：docs/ 只保留 Px 系列设计文档（roadmap 与 research 参照移除，git 历史可查）

## [0.1.6] - 2026-09-15

### Added

- **侧栏审批阻塞提示**：会话的工具卡停在待审批时，侧栏行尾显示琥珀色 🖐 指示（替代运行转圈，阻塞优先）；审批响应 / 回合落定 / 手动停止 / 删除会话即清除——并发场景下不再有"审批卡沉在别的会话里没人点"的隐形死锁
- **手动备份（Settings）**：选目标目录 → 一键把会话数据库（含知识库）+ 图片附件 + pi 会话记录直拷到 `mangox-backup-<时间戳>/`；WAL 先 checkpoint 再拷主文件；源目录缺失容错跳过，硬失败逐项弹窗；目录与上次备份结果持久记忆
- **快速捕获（⌃⌥X 全局热键）**：Spotlight 式悬浮输入条——放大镜 + 大号单行输入 + 目标 pill（新会话 / 新会话-项目 / 追加-既有会话，平铺一层）；Carbon `RegisterEventHotKey` 免辅助功能权限，冲突不抢注出横幅，设置页可录制改键；发送即隐藏 → 侧栏转圈 → 完成通知（mini 台同步出任务卡）；Esc / 点击外部关闭
  - 新会话路径：无人值守（关审批）+ Minimal 档强制（全新上下文收窄风险面）
  - 追加路径：落既有会话（防双流竞争 + 已删目标拒绝），档位跟随该会话现状不强改；目标记忆跨启动

### Fixed

- 侧栏会话 `updatedAt` 只在创建/重命名定格——日分组把活跃会话误显"昨天"；现消息落库即刷新（内存 + db 同步）
- mini 台任务卡被窗口底缘裁掉一刀：`.fullSizeContentView` 标题栏安全区 28pt 漏算入高度预算（chrome 44→76、空态 100→116）

### Changed

- 冻结 worktree 隔离（P8 §5 评估记录）：同仓库多 agent 并行前提不成立 + git 本身兜底 + 圈不住 bash 进程级访问；升级条件与只读工具门替代方案见 `docs/P8-functional-design.md`

## [0.1.5] - 2026-09-15

### Added

- **模型管理自管**：设置页内置预设（DeepSeek / Kimi / GLM / MiniMax / OpenAI / Anthropic / Ollama / Qwen）→ 填 API Key（Keychain 存储）→ 测试连接（直连 provider `/models`，不经 pi）→ 勾选保存；SQLite `models` 表为真源，spawn 时物化 `models.json` + `auth.json`（0600，内容指纹不变跳写）并注入 `PI_CODING_AGENT_DIR=~/.mangox/pi-config`——**全程不读不写 `~/.pi/agent`**
- **模型元数据目录（models.dev 三层自有化）**：bundled 快照（精选 15 providers / 773 models，含思考强度/上下文窗口/价格）> `~/.mangox/catalog/modelsdev.json` 远端缓存（7 天 TTL，静默刷新）> 裸默认兜底；候选元数据优先级 = 种子（不漂移）> 目录 > 默认；思考强度显式 `reasoning` 字段 + `thinkingLevelMap` 按 pi 语义收敛菜单档位（MiniMax 系 map=null 不再误判）
- **模式选择器**：composer 档位 pill——Minimal（read/bash/write/edit + 不挂扩展）/ Standard（内置全量 + 不挂扩展）/ Full（全量 + 业务扩展）；按项目记忆（切项目自动恢复该档位），与审批开关正交组合；下回合 spawn 生效；业务扩展仅 Full 档挂载，系统审批扩展三档恒挂
- **多模态传图**：⌘V 粘贴（截图 / 浏览器复制图 / Finder 图片文件）/ 拖拽 / 附件按钮三入口，暂存 chips ≤4 张（超出提示拆条）；发送时原图落盘 `~/.mangox/attachments/<会话>/`，RPC `prompt` 携带发送副本——png/gif/webp 未超长边 1536px 原样透传（保动图/透明通道），其余压 JPEG（q0.8）；text-only 模型发送时拦截提示（附件保留，换多模态模型后可发）
- **气泡图片**：用户消息缩略图行（88×66）+ 点开大图 sheet（Esc/点击关闭）；重开会话从事件流同源渲染；删除会话连带清理附件目录（先读后删）
- 旧「自定义模型」（三字段表）一次性迁移为自管模型条目（`迁移` 徽章，旧表保留回滚余地）

### Changed

- 输入框模型菜单只认设置页配置的自管模型（不再展示 pi 全量目录）；每条目带思考强度档位
- 设置页铺满窗口宽度；预设芯片收敛为主推 4 家（DeepSeek/MiniMax/GLM/Kimi）+「其他」展开 + 自定义
- 未超限小图原样透传，不再无脑转码（保留 GIF 动效与 PNG 透明）

## [0.1.4] - 2026-09-14

### Added

- **状态栏（P6.1）**：底部常驻 4 项纯展示——过程态胶囊（重试 `重试 1/3 · 2s 后` / 压缩中（threshold）/ 排队 N 条，空闲灰 / 流式主色 / 重试压缩琥珀）、上下文占用 %（压缩后无上报显示 `--`）、Token ↑↓ 实时 tick（流式期 500ms 节流；`get_session_stats` 在 spawn 期与回合落定前各拉一次，落定响应到达才拆进程，2s 兜底）、`当前会话 N 轮`；压缩完成/中止复用通知横幅一次性提示
- **Trace v2（P6.2）**：轨迹视图三段式 `Messages / Turns / Details` + 导出 HTML 按钮（`pi export_html` → 自动在 Finder 显示）
  - Messages：回合折叠（最近一回合默认展开，点回合头切换）+ 摘要行（事件数 + 输出首句）；连续同类工具自动分组（`bash × 3`，展开看逐个调用）；`toolcall_start` 提前出卡（参数未知时先显示工具名，执行开始整卡升级不重复）
  - Turns：回合卡片流（点击跳回 Messages 对应回合）
  - Details：按 LLM 调用粒度列出（时间 · 模型 · total tok，展开看 input/output/cacheRead/cacheWrite/reasoning + responseId + 时长估计），未上报调用数单列
  - 消息正文与用户气泡支持划选复制（跨段落仍不可选，整段复制走每条消息的复制按钮）
- **Side chat 侧问（P6.3.1）**：对任意有持久记忆的会话开"侧问"——`pi --fork` 快照携带源会话上下文开新会话，独立作答不污染主线；入口 = 侧栏行 `...` 菜单「由此侧问」+ Trace 回合右键「由此侧问（含 Turn N 及之前）」；新会话标题 `Side · <原标题>` + 分叉徽章 + 顶部快照提示条（含轮数、fork 时刻、一键跳回源会话）；快照为单向时间点拷贝，主线新消息不同步
- **离开摘要（P6.3.2）**：切走会话或 App 失焦期间后台完成的回合，回来时在输入框上方出现胶囊「离开期间完成 N 轮 · 最近：<回复首句>」——点击滚到底部并消失，× 只关不滚；零 LLM 成本（本地消息投影），并发任务按会话分键隔离，手动停止不计入
- **会话自动命名**：首条消息发送后，仍叫 `New chat` 的会话自动改用该消息首行前 10 字符命名（此后不再自动改，手动重命名优先）

### Changed

- 会话绑定支持显式文件路径（`--session <path>`）：fork 产物文件名带时间戳前缀无法由 UUID 派生，改为 spawn 后回读 `get_state.sessionFile` 落库，后续回合按记录路径续接
- 会话首次输入后侧栏即显示有意义的名字（不再一排 `New chat`）

### Fixed

- **回合结束判定（P6.0）**：从 `agent_end` 改为 `agent_settled`——前者在一次底层 run 结束即触发，此时 pi 可能还在自动重试 / 压缩重试 / 投递排队消息，按它拆进程会腰斩后续
- 扩展 fire-and-forget 方法（`notify` / `setStatus` / `setWidget` / `setTitle`）不再回 response（协议语义：这些请求无响应）
- 工具标签补全：`grep` / `find` / `ls` 不再错显为 read，`powershell` 归入 bash 族
- 应用图标模糊：弃 asset catalog 编译链路（Xcode 16.2 actool 对 mac appiconset 只产出 ≤256 尺寸，1024/512 静默丢失），改由 `scripts/gen-icon.sh` 用 `iconutil` 直出全尺寸 icns
- Trace 视图展开任意行时列表跳到底部（`defaultScrollAnchor(.bottom)` 会在内容尺寸变化时重新锚底）→ 改初屏定位 + 流式跟随
- Details 段在空会话下崩溃（`0..<(n-1)` 区间越界）
- Away 摘要胶囊遮挡正文（浮层改独立占位行）

## [0.1.3] - 2026-09-11

### Added

- **会话轨迹视图（P5.0）**：顶栏胶囊 `Chat / Trace` 切换底档——轨迹视图按事件语义呈现同一会话：摘要头（Duration / Turns / Calls）+ 回合分组（Turn N · 起始时间 · 时长）+ `USER / ASSISTANT / TOOL` 三色事件行；行可展开（ASSISTANT 看全文 + 思考过程 + usage 明细，TOOL 看命令 / 参数 / diff / 错误）；行级实时（回复生成中出旋转弧占位行、工具状态徽章实时翻转），自动锚底；输入区两个底档共享，切到 Trace 也能继续发消息
- **usage 采集落库（P5.0.1）**：pi `message_end` 的 usage（input/output/cacheRead/cacheWrite/reasoning/totalTokens）、responseId、model 挂到对应 assistant 消息并随事件 payload 落库（轨迹视图数据源；将来成本计算铺路）
- **自定义模型（P5.1）**：`custom_models` 表管菜单显示名与 API 名的解耦——设置页「自定义模型」卡片内联管理（条目列表 + 启用 / 删除 + 底部常驻添加表单，provider 前缀校验）；模型菜单「自定义」分区（条目带 ` · custom` 标记），药丸显示自定义显示名；**同名 provider/model id 时覆盖 pi 目录条目**，用于解决目录条目名与服务端 API 名错位（DeepSeek V4.1 实证：目录 `deepseek-v4.1-flash` 被服务端 400 拒收，实报名 `deepseek-flash` / `deepseek-v4-pro`）
- 轨迹视图共享底栏（`ChatBottomBar`）：pi 缺失横幅 + 提炼/超限通知在两个底档一致显示

### Changed

- Work 工作区改为顶栏右侧独立按钮，与 `Chat / Trace` 胶囊完全正交（开不开工作区不影响底档，反之亦然）
- 顶栏三段布局：左组贴左 / 胶囊居中 / Work 钉右缘（macOS 上 `.principal` 存在时 `.primaryAction` 会紧贴前者，解法是中间插一个只装 `Spacer` 的工具栏项）
- 轨迹视图正文层级：正文（USER prompt / ASSISTANT 全文）统一 12pt 淡色，事件线与元数据为视觉主线
- 打开会话默认锚定底部（直接显示最新内容，不再停在最老一条）

### Fixed

- 模型菜单勾选与自定义条目一致性：自定义条目显示名优先，选中仍透传真实 `provider/model id`（不再撞目录条目名与服务端名错位）
- 轨迹视图/对话视图切换后输入框消失（底栏共享后修复）

### Removed

- `Resources/AppIcon.icns`（无引用的历史冗余，图标由 `Assets.xcassets` 的 AppIcon 编译生成）

## [0.1.2] - 2026-09-11

### Added

- **多会话并发跑（P4.0）**：Transport 实例池（每会话一个 pi 引擎实例），多个会话回合真正同时运行、互不干扰；侧栏各行独立显示在途状态；切走再切回不缺半截、不重复落库（`liveTurns` 实时镜像 + replay 去重合并）；能力探测专用实例，多实例 spawn 不再覆盖全局模型状态
- **并发回合上限**：默认 10（settings 持久化，1...20）；超限时用户发送被拒并横幅提示（草稿保留），定时任务到点跳过并在日志会话落痕（"因冲突跳过 (并发已满 (N))"）
- **设置页**：侧栏 Settings 入口，并发回合上限 + 回合完成通知；卡片统一 macOS 系统设置版式（左标题+说明 / 右控件，等宽卡片）
- **回合完成通知（P4.1）**：App 在后台时会话回合结束弹系统通知，点击通知跳回对应会话；前台使用、手动停止、短于 1s 的回合不弹（UNUserNotificationCenter；CLI/冒烟环境安全 no-op）
- **任务迷你台（P4.2）**：toolbar 最小化按钮 → 主窗口收起、右下角 300pt 迷你台（独立 NSWindow 承载，AppKit 全权管理尺寸）；任务卡堆叠（名称 + 计时 + 停止 / 活动摘要 / 完成闪显），点卡跳回对应会话并还原；顶行还原按钮，红灯关闭即还原；超过 4 张卡内部滚动
- 会话/项目删除时逐出对应引擎实例并终止在途 pi（不再有孤儿进程烧 token）

### Changed

- 定时任务 fire 完全后台化：不再劫持主视图（切换会话/清空消息），日志会话直接落盘；冲突跳过判定从"全局有回合在途"收窄为单任务日志会话冲突
- 审批策略按回合下发：无人值守 fire 只关自己的实例审批，不再全局改+恢复
- 迷你台任务全部完成后不再自动还原主窗口（完成卡显示 5s 后回落空态，还原走人工入口）
- 侧栏在途指示器改为经典旋转弧（TimelineView 逐帧驱动；行内循环动效弃用隐式 repeatForever——侧栏行复用会丢动画事务）
- 模型菜单勾选 / 底部模型药丸 / thinking 级别统一为用户期望值；能力探测上报仅作首次初始化，不再把用户选择打回 pi 默认模型

### Fixed

- **跨会话事件污染**（P4.0.1）：A 会话流式中切到 B，A 的回复不再染进 B 的视图与会话记录
- 半截回复双写：手动停止的兜底落库与事件收尾不再重复写库
- 并发上限/通知开关的持久化失效（settings 表 TEXT 列存取类型不匹配，读回恒为默认值）
- App 图标接入 asset catalog 构建（单尺寸 1024 格式）；`Resources/AppIcon.icns` 降级为无引用的冗余文件
- 迷你台「任务台」标题行异常缩进（移除多余的交通灯让位 padding，落当前行最左侧）
- 最小化/还原按钮图标语义互换（向内收 = 最小化，向外扩 = 还原）
- 迷你台超过 4 个在途任务时第 5 张卡起被窗口边缘裁切（卡片区改为滚动容器）
- 设置页两张配置卡宽度不一致（卡片统一撑满内容容器）
- 模型切换后底部药丸仍显示旧模型（期望选择与引擎上报两源互相覆盖，统一为期望源）

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
