#!/bin/bash
# MangoX 冒烟门禁: 编译全量源码 (排除 @main 入口) + 运行 ChatStore 语义冒烟。
# 用法: scripts/smoke/run.sh
# 通过条件: 编译零错误 && 冒烟输出 "ALL PASS" (退出码 0)。
#
# ⚠️ 标准跑法 (2026-10-13 boss 定的纪律; 展开在 MEMORY-details「门禁诊断细则」):
#   本脚本只往 stdout 打, **不落盘也不给条数** ⇒ 调用方要一次拿全, 别跑完才发现没抓条数、
#   再跑一遍 (那次实测白跑了三趟)。标准式:
#     bash scripts/smoke/run.sh > /tmp/smoke.log 2>&1; echo "RC=$?"
#     grep -c '^PASS' /tmp/smoke.log; grep -c '^FAIL' /tmp/smoke.log; grep '^FAIL' /tmp/smoke.log
#     grep -c 'warning:' /tmp/smoke.log; grep 'warning:' /tmp/smoke.log; tail -3 /tmp/smoke.log
#   ⚠️ `warning:` 那一对**不是可选的**: swiftc 的编译告警只出现在**日志头部** (编译在
#   运行之前), 而 `^PASS`/`^FAIL`/`tail` 全在尾部 ⇒ 只抓尾就漏掉编译告警。
#   **一轮门禁只跑两次**: 正例 (上面这一跑就把读数吃全) + 反例 (改坏 → 确认红的恰好是你动的
#   那几处); **反例还原后即结束**, 不再跑正例 —— 正例刚刚才跑过。
set -euo pipefail

cd "$(dirname "$0")/../.."

SMOKE_DIR="$(pwd)/scripts/smoke"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# 工具链: 显式 DEVELOPER_DIR > /Applications/Xcode.app > xcode-select 当前指向。
# 与 scripts/diag/resource-gate.sh 是同一套顺序 —— 两个脚本挑到不同工具链的话, 门禁
# 验证的就不是同一个 SDK 编出来的东西 (静默失效, 比报错更难查)。
# 原写法硬编码 DEVELOPER_DIR="/Applications/Xcode.app", 在只装了 CommandLineTools 的
# 机器上 xcrun 直接报 "missing DEVELOPER_DIR path" 退出 —— 门禁在那种机器上等于不可用。
# CLT 自带完整 macOS SDK + swiftc, 冒烟只要能编过, 不需要 actool。
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    DEV="$DEVELOPER_DIR"
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    DEV="/Applications/Xcode.app/Contents/Developer"
else
    DEV="$(xcode-select -p 2>/dev/null || true)"
fi
[[ -n "$DEV" && -d "$DEV" ]] || { echo "错误: 找不到开发者目录 (xcode-select --install)" >&2; exit 1; }
SDK="$(DEVELOPER_DIR="$DEV" xcrun --sdk macosx --show-sdk-path)"

# 架构跟宿主走: 原先硬编码 arm64, 在 Intel Mac 上编出来的二进制跑不了 (门禁直接失效,
# 而且失败信息是 exec format error, 很难联想到是构建脚本的架构写死了)
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo "错误: 不支持的宿主架构 $ARCH" >&2; exit 1 ;; esac

# ---- 颜色 / 源码判据 (P16) ----
# 快检放编译**前面**: 它红了没必要再花几十秒编一遍。这两条都**不在** smokeMain 里,
# 理由各自写在下面 (一条是"独立第二实现", 一条是"源码事实" —— 数值守卫看不见后者)。
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "错误: 找不到 $PY (亮/暗色算例需要它)" >&2; exit 1; }

# ① 亮 / 暗两块板的算例 —— 与 smokeMain 的 T-COLOR 段**同源同界**的独立第二实现:
#    两份实现必须逐位吻合, 否则"冒烟绿了"这件事本身就不可证伪。
#    ⚠️ 它同时覆盖**亮色** —— smokeMain 的 T-COLOR 只看 `enum Dark`, 亮色侧一条数值门禁都没有。
"$PY" scripts/diag/palette_probe.py || { echo "FAIL - 亮/暗色算例破了 (见上)" >&2; exit 1; }

# ② 内嵌面底色的**源码事实** —— 数值守卫看不见"视图用了哪个 token"(值本身没变)。
#    P10.8b: 聊天流里的内嵌面 (工具输出区 / diff 预览) 必须比正文面**亮一档**;
#    用 bgBase/bgChat/bgInput 就是"在正文面上挖黑洞"(暗色实测 3.01× 亮度差, 久读累眼)。
if grep -nE 'background\(CodexTheme\.(bgBase|bgChat|bgInput)\)' \
        mangox/Views/Chat/ToolCallCardView.swift mangox/Views/Chat/ToolRunReceipt.swift; then
    echo "FAIL - 工具行的内嵌面底色退回了低于正文面的一档 (P16: 内嵌面只许 bgCard)" >&2
    exit 1
fi

# ③ 列表类视图的初屏定位**不许**用锚底 —— `.defaultScrollAnchor(.bottom)` 会在**内容尺寸变化时
#    重新锚底**: 展开任意一行整列就跳, 体感"点了 A 打开了 B"。同一个坑 2026 年先修在 TrajectoryView
#    (注释见 TrajectoryView.swift:153), ChatView 漏了, 2026-10-14 boss 实机撞上 ⇒ 补修 + 立门。
#    它编译得过、值也没变 ⇒ 数值守卫与编译告警都看不见, 只能扫**源码事实**。
#    ⚠️ 只认**行首的修饰符调用** —— 解释这个坑的注释里必然出现该词, 不排除会误伤。
if grep -rn '^[[:space:]]*\.defaultScrollAnchor(' mangox/Views/ ; then
    echo "FAIL - 锚底回来了 (展开一行整列就跳, 点 A 开 B); 初屏定位请用 onAppear + scrollTo" >&2
    exit 1
fi

# ③b 轨迹视图的**单块 Text 禁令** (2026-10-21 boss「dream 会话点轨迹 tab 直接卡死, 程序无响应」)。
#     根因: 那一轮的用户消息 **115,315 字符 / 2,817 行**(最长一行 3,389 字符), 而 `.user` 行写的是
#     `Text(event.prompt)` 一整块 —— 单个 `Text` 承载整块文本的布局是**平方级**的。同一条语料实测
#     **20,925 ms**(主线程 = 那十几秒无响应) vs 按行切块 **342 ms** vs 折叠预览 **0.7 ms**。
#     ⚠️ 它编译得过、没有任何数值会变、也没有任何断言会红 ⇒ 只有**源码事实**能守。
#     正文一律走 `collapsibleTraceText` / `boundedTraceText`(判据在 `UserMessageFold`,
#     与聊天侧 `ChatView.userBody` 共用一份)。
#     ⚠️ 这条是**绊线不是证明**: 只认"行首就是这个 Text"的写法(上面 ③ 同款取舍);
#        `detailLine` 里的工具 `value` 故意不在名单里 —— `statCell(value:)` 也叫 value, 会误伤。
if grep -nE '^[[:space:]]*Text\((event\.prompt|event\.fullText|think|diff)\)' \
        mangox/Views/Trajectory/TrajectoryView.swift; then
    echo "FAIL - 轨迹视图里又出现单块 Text 渲染的用户/模型正文 (平方级: 实测 21 秒)" >&2
    echo "       长度由数据决定的只读面必须按块渲染 (见 TrajectoryView.collapsibleTraceText)" >&2
    exit 1
fi

# ③c 「滚到底」**只许有一个实现**，且不许带补间 (2026-10-21 boss 第三次报「回车后白屏」)。
#     实测: `scrollTo(anchor: .bottom)` 的目标位置按 `LazyVStack` 的**估算**文档高算 —— 同一份
#     794 事件的真实会话读出过 32,547 / 68,924 两种值（6 次里 5 次是翻倍那个）；落在那个位置上
#     视口**一帧都没画**（逐帧取像素：100% 纯底色 / 0% 墨迹，滚动条却在轨道底），紧跟一拍就恢复。
#     ⇒ 四个入口（初屏 / 换会话 / 提交跟随 / 回到最新）必须共用 `ChatView.scrollToTail`
#       —— 它带着复核拍。**分头写就会分头漏掉复核**（这个 bug 已经这样活了两个版本）。
#     ⚠️ 同时禁 `withAnimation` 包 scrollTo: 补间的中间态按动画插值的布局算（实测落点差 100~260pt），
#        而且"动画结束"≠"布局落定"，复核等于白做。
#     两条都编译得过、没有任何数值会变 ⇒ 只能扫**源码事实**（与上面 ③ 同一类取舍）。
SCROLL_N=$(grep -cE 'proxy\.scrollTo\(' mangox/Views/Chat/ChatView.swift || true)
if [[ "$SCROLL_N" -ne 1 ]]; then
    echo "FAIL - 「滚到底」的实现分支了: ChatView 里 proxy.scrollTo( 出现 $SCROLL_N 处 (期望 1)" >&2
    echo "       四个入口请一律走 scrollToTail —— 它带复核拍, 漏了它 = 回车后白屏会一直亮着" >&2
    exit 1
fi
if grep -nE 'withAnimation' -A2 mangox/Views/Chat/ChatView.swift | grep -qE 'scrollTo'; then
    echo "FAIL - 滚到底又带上补间了 (补间按动画插值的布局算落点, 实测差 100~260pt, 且没法复核)" >&2
    exit 1
fi

# 「源码事实门」的公共取词器 —— 剥掉**整行被注释掉**的行之后再匹配。
#    为什么必须剥: 把 `chmod(path, 0o600)` 前面加两个斜杠, 那串字**还在文件里** —— 不剥的话门会
#    对着注释里的同一串字点头, 反例注入之后照样 RC=0(2026-10-28 实测踩到: 注释掉 socket 权限那行,
#    ③i 一条没红)。⇒ 这类门当前全是**假门**, 判据改成"有效代码行里有这串字"。
#    ⚠️ 已知边界: 只挡「整行注释」这一种; 行尾注释 `let x = 1 // chmod(...)` 仍会误命中。
has_code() {
    awk '!/^[ \t]*\/\//' "$1" | grep -qE -- "$2"
}

# ③d 「滚到底」的锚点必须是**恒实例化**的末尾哨兵 (2026-10-23 boss 报「打开后默认会话不在最底、
#     ｜也没有《跳转最新》按钮，切一次会话才正常」)。
#     锚在 `LazyVStack` 的行 id 上时，那个行在初屏**还没实例化** ⇒ `scrollTo` 只能按**估算**的
#     文档高落点，而且同一 id 重复调用**不再重新锚定**。用 AppKit 侧 `documentVisibleRect` 实测
#     （真 ChatView + 1014 条消息 + 1280×800）：落点距真底 **240 / 1947 / 2701 / 2898pt** 不等；
#     更坏的是内容底探针住在最后一块**下面**，视口够不到 ⇒ 永不实例化 ⇒ 永不报数 ⇒
#     `nearBottom` 停在初始 `true` ⇒ 按钮永不出现。换成末尾哨兵后 gap = **0.0pt**（三次跑全 0）。
#     ⚠️ 两条都编译得过、没有任何数值会变、也没有断言会红 ⇒ 只能扫**源码事实**。
if ! has_code mangox/Views/Chat/ChatView.swift 'private var scrollTarget: AnyHashable \{ Self\.tailAnchor \}'; then
    echo "FAIL - 「滚到底」的锚点不是内容末尾哨兵 (scrollTarget 必须返回 Self.tailAnchor)" >&2
    echo "       锚在 LazyVStack 的行 id 上 = 按估算落点, 实测距真底 240~2900pt 且按钮永不出现" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatView.swift '\.id\(Self\.tailAnchor\)'; then
    echo "FAIL - 内容末尾哨兵不见了 (`.id(Self.tailAnchor)` 必须在 ScrollView 的内容里)" >&2
    exit 1
fi

# ③e 第一拍必须先锚**真实行**、其余才锚哨兵 —— 顺序反了就是**白屏**。
#     只锚哨兵时，切过来的那一秒文档高还是**估的**（同一会话实测 39695 / 49203 / 50599 / 51437，
#     最大值比真实内容底多约 840pt ≈ 一屏），锚到哨兵就按虚高值落进**内容之下的空白区** ⇒ 整片白。
#     实测同一白屏场景（dream → 模型部署测试）：只锚哨兵 `y=50719` 白 → 先锚最后一块 `y=49881` 有内容。
#     ⚠️ 这次最狠的教训：**虚高文档上 `gap=0` 照样成立** —— 几何判据判不出白屏，只有画面能判。
#     ⇒ 源码事实门（两条写法都编译得过、数值也不变，没有断言会红）。
if ! has_code mangox/Views/Chat/ChatView.swift 'projectedChat\.blocks\.last\.map \{ AnyHashable'; then
    echo "FAIL - 找不到「先把尾块量出来」的锚点 (materializeTarget 必须取 projectedChat.blocks.last)" >&2
    echo "       只锚末尾哨兵会在切换后落进估算出来的空尾 = 白屏 (实测 y=50719 纯白)" >&2
    exit 1
fi
if ! grep -A9 -E 'for \(i, delay\) in Self\.followBeats\.enumerated\(\)' mangox/Views/Chat/ChatView.swift \
        | grep -qE 'if i == 0'; then
    echo "FAIL - 「滚到底」的节拍没有分两段 (followBeats 循环里第一拍 i == 0 必须锚 materializeTarget)" >&2
    echo "       顺序反了 = 每一拍都按虚高文档落点 = 白屏; 只改注释不算, 这门看的是真源码" >&2
    exit 1
fi
# ③f 流式期的锚点必须是**懒栈的孩子**（流式指示器），不能是末尾哨兵。
#     哨兵 `tailAnchor` 是 `LazyVStack` 的**兄弟** ⇒ `scrollTo` 只能吃"整条懒栈的总高估算"；
#     指示器在懒栈**里面** ⇒ `scrollTo` 会为它把前面的行实例化出来，落点用的是**量出来的**高度。
#     0.1.30 实测（真机 · 长回复）：流式期估算 doc=**22263** / 落定后真实 **13245**，差 **9018pt**
#     ⇒ 视口停在内容**下方** = 整片白，而且视口下方没有行被实例化，这个估算**永远不会自我纠正**
#     （boss 报「回车后白屏，连对话完成后都不显示，切一次会话才好」）。
#     ⚠️ 两条写法都编译得过、没有任何数值会变、也没有断言会红 ⇒ 只能扫源码事实。
FOLLOW_LOOP=$(grep -A20 'for (i, delay) in Self.followBeats.enumerated()' mangox/Views/Chat/ChatView.swift)
if ! echo "$FOLLOW_LOOP" | grep -qE 'target = Self\.streamingAnchor'; then
    echo "FAIL - 流式期的锚点不是 Self.streamingAnchor (锚哨兵 = 吃总高估算 = 白屏, 实测差 9018pt)" >&2
    echo "       指示器是懒栈的孩子才量得出真实落点; 只改注释不算, 这门看的是真源码" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatView.swift '\.id\(Self\.streamingAnchor\)'; then
    echo "FAIL - 流式指示器上没有 .id(Self.streamingAnchor) (锚一个不存在的 id = 静默不滚 = 白屏)" >&2
    exit 1
fi
# ③g 静止态那一拍必须先锚尾块，而且判据是**尾块身份**（`materialize != materializedTail`），
#     不是"要不要量"的布尔开关 —— 开关在回车那一刻早就 false 了，尾块却换了（多一条用户消息）
#     ⇒ 只锚哨兵 ⇒ 落进估算出来的空尾。0.1.30 实测：改成身份判据前，回车必白。
#     反过来的写法（无判据、每拍都先锚尾行）会让流式期每个 token 都 28pt 来回弹 = **刷屏**。
if ! echo "$FOLLOW_LOOP" | grep -qE 'materialize != materializedTail'; then
    echo "FAIL - 静止态第一拍缺尾块身份判据 (应为 `materialize != materializedTail`)" >&2
    echo "       少了它 = 每拍都先锚尾行再锚哨兵, 28pt 来回弹 = 刷屏 (0.1.30 实测)" >&2
    exit 1
fi

# ③h codemode 的**嵌套调用**必须挂到父卡上，而不是各占一行。
#     pi 为嵌套调用（`ctx.executeTool()` → codemode 的 `tools.bash(...)`）发的
#     `tool_execution_*` 带 `parentToolCallId`（= `<父callId>/<n>`）；官方 TUI 的判据就一句
#     `if (event.parentToolCallId) break;`（画在父行里面）。
#     ⚠️ 不接这个字段的两个后果都实测过（2026-10-26 boss 截图）：
#     ① 一次调用显示成 `bash` + `codemode` **两行**；
#     ② **重放时子行排到父前面** —— 落库只写终态，子调用先完成（22ms）父后完成（84ms）
#        ⇒ seq 子在前 ⇒ 按 seq 还原就颠倒。直播时反而是对的，所以这现象只在重开会话后出现。
#     ⚠️ 三条写法都编译得过、数值不变、没有断言会红 ⇒ 只能扫源码事实。
if ! has_code mangox/Agent/PiRpcTransport.swift 'parentToolCallId'; then
    echo "FAIL - 传输层没读 parentToolCallId (嵌套调用会被当成顶层工具卡)" >&2
    echo "       后果: 一次 codemode 显示两行, 且重放时 bash 排到 codemode 前面" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatView.swift 'ToolNesting\.index\(in: store\.messages\)'; then
    echo "FAIL - 顶层投影没走 ToolNesting.index 建嵌套索引" >&2
    echo "       ⚠️ 键必须是【父卡那条消息的 id】, 不是 parentId 里的工具 id —— 混用的症状如下:" >&2
    echo "       子卡凭空消失 (2026-10-26 boss 截图: 5 次内层调用一个都没画出来, 全绿却错)" >&2
    echo "       ⚠️ children 与 attached 必须出自**同一次扫描** (Index 的两面, 分两次算就允许各自为政)" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatView.swift 'attached\.contains\(t\.id\)'; then
    echo "FAIL - 摘掉顶层行的判据不是 attached (真挂上了才许摘)" >&2
    echo "       按 parentId != nil 判 = 一挂错就那一行从界面上消失; 按 attached 判 = 挂不上就露出来" >&2
    exit 1
fi
# 段收据的 count 与屏上的行必须是**同一个判据** —— 2026-10-26 audit ③:
# `ToolRunBuilder` 收到的是**一组**消息, 而子卡的父卡可能不在这一组里（压缩插了 `.system`、
# 老会话只留半截）。它若自己按本组现算, 就把那种子卡数成"看得见的一行", 收据上的
# 「N 次工具调用」与 `ChatView` 摘行后的实际行数对不上 —— 且两边都不报错。
if ! has_code mangox/Views/Chat/ChatView.swift 'ToolRunBuilder\.runs\(in: .*attached: attached'; then
    echo "FAIL - 段收据没拿到会话级的 attached (判据与 isNested 分家了)" >&2
    echo "       跨组挂载的子卡会被数进「N 次工具调用」, 而 ChatView 已经把它的行摘掉了" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ToolCallCardView.swift 'children: \[Nested\]'; then
    echo "FAIL - 工具行没有接收嵌套调用的入口 (ToolCallCardView.children)" >&2
    echo "       摘掉行却没人接 = 内层调用直接从界面上消失" >&2
    exit 1
fi

# ③i mangox-compute 的**socket 只认自己人** —— P18 §04 前置门 0。
#     这条挡的是"别人替你的机器动手", 比审批闸门(挡模型误用)更该排在前面:
#     授权辅助功能之后, 本机**任何同 uid 进程**都能连上这条 socket 发动作,
#     而作用域/遮蔽/恒拒判据全挡不住这条路径 —— 它们只挡模型。
#     三件必须都在: ① `LOCAL_PEERCRED` 取对端 uid(不依赖对端自报) ② 进程树校验
#     ③ 文件 0600 / 目录 0700。
#     ⚠️ 三件都编译得过、没有任何数值会变 ⇒ 只能扫**源码事实**(与上面 ③ 同一类取舍)。
if ! has_code mangox-compute/PeerCheck.swift 'getsockopt\(socket, SOL_LOCAL, LOCAL_PEERCRED'; then
    echo "FAIL - helper 不再用 LOCAL_PEERCRED 取对端 uid (这条是 peer 校验的支点)" >&2
    echo "       不取内核凭据 = 只能信对端自报 = 本机任何进程都能驱动界面" >&2
    exit 1
fi
if ! has_code mangox-compute/PeerCheck.swift 'isSelfOrDescendant\(pid: pid, of: ancestor\)'; then
    echo "FAIL - accept 之后没有走进程树校验 (只验 uid 不够: 同 uid 的任何进程都能连)" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'chmod\(path, 0o600\)'; then
    echo "FAIL - socket 文件的权限没有显式设成 0600 (目录 0700 之外的另一半)" >&2
    exit 1
fi
# 作用域名单为空时必须**拒**, 而不是"全都行" —— 空 = 没下发, 不是开放。
if ! has_code mangox-compute/ComputerServer.swift 'guard !allowedBundles\.isEmpty else \{ return false \}'; then
    echo "FAIL - helper 的作用域判据在名单为空时放行了 (空名单 = 没下发, 不是全部允许)" >&2
    exit 1
fi

# ③j computer 的**跨 target 契约 token**: App 侧 `ComputerHost` 写的 env 名与 helper 侧读的
#     必须逐字相同。⚠️ 这两个 target **各自编译**, 改一边不会有任何编译错误, 也不会有断言变红
#     —— 只是子进程读到 nil, 现象是"工具每次都回未启用"。同 `MANGOX_BOCHA_KEY` 那条纪律:
#     契约 token 只能靠门钉住, 不能靠类型系统。
for KEY in MANGOX_COMPUTE_ALLOWED_BUNDLES MANGOX_COMPUTE_ACT_BUNDLES MANGOX_COMPUTE_PEER_PID MANGOX_COMPUTE_PARENT_PID; do
    # ⚠️ 模式**必须带引号**: 只子串匹配的话, 把 key 改名成 `..._PIDX` 依然含 `..._PID`
    #    ⇒ 门对着已然对不上的两个名字点头(2026-10-28 反例实测: 注入后 RC=0)。
    if ! has_code mangox/Agent/ComputerHost.swift "\"$KEY\""; then
        echo "FAIL - computer 契约 token $KEY 在 App 侧不见了 (helper 读的就是这几个字)" >&2
        exit 1
    fi
    if ! has_code mangox-compute/ComputerServer.swift "\"$KEY\"" \
       && ! has_code mangox-compute/PeerCheck.swift "\"$KEY\""; then
        echo "FAIL - computer 契约 token $KEY 在 helper 侧不见了 (App 侧改名 ⇒ 这里必须同改)" >&2
        exit 1
    fi
done

# ③k helper 里有两个**决定模型能看见什么**的数, 而它们没有任何断言拦得住(真 AX 调用测不了):
#    ① 名字只从 `AXTitle` 取 ⇒ 实测 Safari 的工具栏按钮 title 是空的、名字只在 `AXDescription`
#       里 ⇒ 那一排按钮在快照里全是无名的 `[n] button`(模型只能点编号, 人也看不懂审批卡);
#    ② 深度上限 14 ⇒ 实测 Chrome 的网页正文**恰好从 d15 开始**(Finder 7 · Chrome 23),
#       整页 DOM 被切在外面, 读出来只剩工具栏, 而且回执看着像"读成功了"。
#    ⚠️ 这两条都不改数值就编译得过、断言也全绿 —— 只能扫源码事实(同 ③i)。
if ! has_code mangox-compute/AXAdapter.swift 'kAXDescriptionAttribute'; then
    echo "FAIL - AXAdapter 不再读 kAXDescriptionAttribute (Safari 的名字就在这一处)" >&2
    echo "       去掉它 ⇒ Safari 那一排按钮全是无名的 [n] button, 而快照看着完全正常" >&2
    exit 1
fi
# 深度上限是**实测出来的数**, 不是拍的: 低于 24 就一定把浏览器正文切掉。
COMPUTE_DEPTH="$(awk '/static let maxDepth/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' mangox-compute/AXAdapter.swift)"
if [ -z "$COMPUTE_DEPTH" ] || [ "$COMPUTE_DEPTH" -lt 24 ]; then
    echo "FAIL - AXAdapter.maxDepth = ${COMPUTE_DEPTH:-取不到} (< 24)" >&2
    echo "       实测深度: Finder 7 · Chrome 23, 且 Chrome 的正文从 d15 开始 ⇒ 14 会把整页切掉" >&2
    exit 1
fi

# ③l 动作面(批 2b)的三条**只在真机上才会出事**的事实 —— 它们全都编译得过、纯函数断言也全绿:
#    ① 判据(`ComputerActGuard.evaluate`)**必须**排在执行(`AXAdapter.press`)之前。
#       把它俩调个位置, 界面上没有任何异样, 直到"模型替人点了不保存"那天。
#    ② 执行只能经 `AXAdapter` 的 `AXUIElementPerformAction` —— 出现 `CGEvent` 就说明有人
#       偷偷加了坐标兜底, 而那批动作**不经过作用域/编号/红线任何一道**。
#    ③ 三条恒拒必须真的接在 guard 里(判据写了但没人调 = 一张好看的函数表)。
if ! has_code mangox-compute/ComputerServer.swift 'ComputerActGuard.evaluate'; then
    echo "FAIL - ComputerServer 不再调 ComputerActGuard (动作就绕开了全部判据)" >&2
    exit 1
fi
ACT_GUARD_LINE="$(awk '/ComputerActGuard.evaluate\(/ { print NR; exit }' mangox-compute/ComputerServer.swift)"
ACT_PRESS_LINE="$(awk '/AXAdapter.press\(/ { print NR; exit }' mangox-compute/ComputerServer.swift)"
if [ -z "$ACT_GUARD_LINE" ] || [ -z "$ACT_PRESS_LINE" ] || [ "$ACT_GUARD_LINE" -ge "$ACT_PRESS_LINE" ]; then
    echo "FAIL - 判据与执行的顺序不对 (guard@${ACT_GUARD_LINE:-?} press@${ACT_PRESS_LINE:-?})" >&2
    echo "       执行必须排在判据之后 —— 反了就等于'先按了再问能不能按'" >&2
    exit 1
fi
for f in mangox-compute/*.swift; do
    if has_code "$f" 'CGEvent'; then
        echo "FAIL - $f 里出现了 CGEvent" >&2
        echo "       坐标点击是批 3(人类接管)的事: 它绕开作用域/编号/红线三道判据" >&2
        exit 1
    fi
done
# ③p helper 取"谁在跑 / 谁在前台"不许用 `NSWorkspace.shared.runningApplications` /
#     `.frontmostApplication` —— 2026-10-29 实测(macOS 14.8.1), 这两个在**不抽 run loop** 的
#     进程里返回的是**首次查询那一刻的快照**。helper 正是"阻塞在 accept() 上一个 loop 都不跑"
#     的裸进程 ⇒ boss 那次 `computer_open` 回"4 秒内还没看到它起来"、`computer_read` 回
#     "它们现在都没在运行", 而 `pgrep` 明明看得见 —— **回执在撒谎, 零红灯**。
#     同一进程里抽 60ms run loop 就恢复(枚举 0→1) ⇒ 它靠通知刷新, 不抽就永不刷新;
#     而按 bundle 现问的 `runningApplications(withBundleIdentifier:)` 是同步查询, 立刻 0→1。
#     ⚠️ 这条只能扫源码事实: 编译得过、纯函数那半边全绿, 只有真机跑起来才看得出回执错了。
for f in mangox-compute/*.swift; do
    if has_code "$f" 'NSWorkspace\.shared\.(runningApplications|frontmostApplication)'; then
        echo "FAIL - $f 又用了 NSWorkspace.shared 里那两个**会定格**的查询" >&2
        echo "       它们在没抽 run loop 的进程里只反映首次查询那一刻 ⇒ 回执会说'它没在运行'而它明明在跑" >&2
        echo "       改用 NSRunningApplication.runningApplications(withBundleIdentifier:) 逐个问 (见 ComputerServer.runningApp)" >&2
        exit 1
    fi
done
for NEEDLE in 'ComputerRedline.refusal' 'ComputerRedline.savePromptDecision'; do
    if ! has_code mangox/Models/ComputerAct.swift "$NEEDLE"; then
        echo "FAIL - ComputerActGuard 里少了 $NEEDLE (判据表还在, 但没人用它)" >&2
        exit 1
    fi
done
if ! has_code mangox-compute/AXAdapter.swift 'AXUIElementPerformAction'; then
    echo "FAIL - AXAdapter 不再调 AXUIElementPerformAction (按不动了, 但它会一直说'按了')" >&2
    exit 1
fi

# ③m socket 的**分帧**两侧都以「完整行」收尾 (2026-10-29 boss 截图报「渲染出乱码」)。
#     症状是一个汉字变成 3 个 U+FFFD —— 实测 483 字的一条 Safari 脚注, 坏在字符 199 / 字节 541,
#     「条」的 3 个 UTF-8 字节被 socket 的 chunk 边界劈开, 两半各自解码 ⇒ 各自补替换字符。
#     ⚠️ 这一处**任何断言都拦不住**: 报文仍是合法 JSON(替换字符是合法字符), 长度只差几个字节,
#        模型只会以为自己读到的是网页原文。⇒ 只能扫源码事实, 而且两侧各一条:
#        ① App 侧(JS 扩展)攒**字节**, 拿到行尾才 `toString("utf8")`;
#        ② helper 侧把整行**写完** —— `send` 的返回值是"这次写了多少", 不是成功/失败。
if has_code mangox/Agent/PiRpcTransport.swift 'String\(chunk\)'; then
    echo "FAIL - computer 扩展又逐块解码了 (String(chunk) 会把跨块汉字劈成 U+FFFD)" >&2
    echo "       攒字节、拿到 0x0a 再整体解码 —— 一次 toString 只能作用在**完整行**上" >&2
    exit 1
fi
for NEEDLE in 'Buffer\.concat' 'toString\("utf8"\)'; do
    if ! has_code mangox/Agent/PiRpcTransport.swift "$NEEDLE"; then
        echo "FAIL - computer 扩展的读侧少了 $NEEDLE (按字节攒 + 整行解码, 缺一个就会出替换字符)" >&2
        exit 1
    fi
done
if ! has_code mangox-compute/ComputerServer.swift 'writeAll\(fd:'; then
    echo "FAIL - helper 不再经 writeAll 回话 (单次 send 只写了半行也当成功)" >&2
    exit 1
fi
if has_code mangox-compute/ComputerServer.swift '_ = out\.withUnsafeMutableBytes \{ send'; then
    echo "FAIL - helper 又单次 send 整行 (快照几 KB, 缓冲区满时丢掉的那截不报错)" >&2
    exit 1
fi

# ③n 滚动路径上**不许每帧写 @State** (2026-10-29 boss「读 safari 的那个会话往上拉卡顿严重」)。
#     `contentBottomY` 的定义是"内容底相对**视口顶**的 y" —— 滚动时它每帧都在变, 而
#     `onPreferenceChange` 每帧都会调 `handleContentBottom`。写成 `@State CGFloat` ⇒ 每滚一帧
#     就标记视图失效一次 ⇒ body 全量重算(`projectedChat` 单独计时 < 5ms, 再加全部可见行重建)
#     ⇒ 内容越重掉帧越狠。
#     ⚠️ 这一处**没有任何断言能间接拦住**: 值是对的、判据是对的、滚动逻辑也是对的 ——
#        唯一的症状是"手感到变差", 而那不会让任何一条 PASS 变红。
if has_code mangox/Views/Chat/ChatView.swift '@State private var lastBottomY: CGFloat'; then
    echo "FAIL - lastBottomY 又变回 @State CGFloat 了" >&2
    echo "       它每滚一帧就变一次 ⇒ 每帧标记视图失效 ⇒ 长会话往上拉必掉帧" >&2
    echo "       装进引用盒子(改字段不走 setter), 它只在 refreshViewport 里被读一次" >&2
    exit 1
fi
if has_code mangox/Views/Chat/ChatView.swift '^[[:space:]]*lastBottomY = '; then
    echo "FAIL - 有地方直接给 lastBottomY 赋值了 (盒子应该写 lastBottomY.value)" >&2
    exit 1
fi

# ③o helper 的作用域**变了就得重启** (2026-10-29 boss「我明明加了」)。
#     helper 的作用域是**启动那一刻读 env 定死的**, 进程一起就再也不看 env。而 `start` 原来
#     只问"进程还在跑吗", 不问"名单还是不是那一批" ⇒ 把 Safari 改成 Calculator 之后, 助手
#     照旧按 Safari 拒, **拒绝信息里列的也是 Safari** —— 而设置页明明勾着计算器。
#     ⚠️ 这一处零红灯: 设置对、env 对、作用域判据也对, 唯一错的是"哪一份名单算数"。
if ! has_code mangox/Agent/ComputerHost.swift 'runningScope == wanted'; then
    echo "FAIL - ComputerHost.start 复用 socket 时不再比作用域" >&2
    echo "       助手只在启动时读一次 env ⇒ 改了设置它还是按旧名单拒" >&2
    exit 1
fi
if ! has_code mangox/Agent/ComputerHost.swift 'runningScope = nil'; then
    echo "FAIL - stop() 不再清 runningScope (留着它, 下次 start 会以为名单已经下发过了)" >&2
    exit 1
fi

# ③q 遮蔽的**第二档**不许掉线: `AXAdapter.build` 必须把 `AXProtectedContent` **真读进来**。
#    2026-10-30 之前那行硬写的是 `isProtected: false` ⇒ 序列化那一步只剩"按角色"一档
#    (`ComputerRedline.isPasswordRole`), 而文件头注释早写着"按属性名字符串读" —— 注释比事实说得多。
#    症状: 角色不叫 secure、但被系统标了受保护内容的值**照原文进上下文**; 零红灯、断言全绿
#    (纯函数那半边喂的是手搓的树, 它不知道 helper 根本没填这个字段)。
#    ⚠️ 只能扫源码事实: helper 不参与冒烟编译, 而且真机上还没找到一个 `AXProtectedContent=1`
#    的元素来对照 ⇒ 两条一起: 禁用常量 + 钉住"现场读"这个调用。
if has_code mangox-compute/AXAdapter.swift 'isProtected: false'; then
    echo "FAIL - AXAdapter.build 又把 isProtected 硬写成 false 了" >&2
    echo "       那样遮蔽只剩'按角色'一档 ⇒ 被标了受保护内容的值照原文进模型上下文, 且零红灯" >&2
    echo "       要写成 !value.isEmpty && isProtected(el) —— 空值不问, 省掉每节点一次 AX 往返" >&2
    exit 1
fi
if ! has_code mangox-compute/AXAdapter.swift 'isProtected: !value\.isEmpty && isProtected\(el\)'; then
    echo "FAIL - AXAdapter.build 不再从现场读 AXProtectedContent (遮蔽的第二档掉了)" >&2
    exit 1
fi

# ④ 冒烟主文件的**体量棘轮** (2026-10-19) —— 判据 = 行数**只减不增**。
#    为什么要有这条: 冒烟已长到 7000+ 行, 而且几乎全在**一个函数 `run()`** 里
#    (Swift 函数体不能跨文件 ⇒ 只要它还是一个大函数, 就必然是一个大文件)。
#    2026-10-19 的教训: 想靠"按注释锚点机械抽 67 个函数"一次解决 —— 结果抽断了 `run()` 里
#    几百个共享夹具的作用域, 约束求解器掉进 salvage() 指数爆炸, 编译从 126 秒涨到 19 分钟以上,
#    而且**零红灯**(编译日志 0 字节, 看着像卡死)。⇒ 改走"冻结 + 增量外移":
#    先把主文件冻在这个数上, 新用例一律进 scripts/smoke/cases/ 并自带夹具(用 fixtureDir);
#    外移成功一段就把 size_budget 调**小**。
#    要调大 = 一次需要评审的决策, 必须出现在 diff 里 —— 这条门存在的全部意义就在这里。
BUDGET_FILE="$SMOKE_DIR/size_budget"
[[ -f "$BUDGET_FILE" ]] || { echo "错误: 缺 $BUDGET_FILE (体量棘轮门的基线文件)" >&2; exit 1; }
BUDGET="$(tr -d '[:space:]' < "$BUDGET_FILE")"
NOWLINES="$(wc -l < "$SMOKE_DIR/smokeMain.swift" | tr -d '[:space:]')"
if (( NOWLINES > BUDGET )); then
    echo "FAIL - smokeMain.swift 已 $NOWLINES 行, 超出预算 $BUDGET 行" >&2
    echo "       新用例请放 scripts/smoke/cases/ (自带夹具, 用 fixtureDir), 不要再往主文件里加。" >&2
    echo "       外移成功一段后, 把 scripts/smoke/size_budget 调**小**。" >&2
    exit 1
fi

# 冒烟自己的源文件: 除 smokeMain.swift 外还有 SmokeCore.swift / SmokeFakes.swift,
# 以后新增的 cases/ 也自动进来。判据 = "脚本目录下所有 .swift" ⇒ 加文件不用改这一行
# (和 mangox/ 下新增文件不用改 pbxproj 是同一个思路)。
SMOKE_SRC=$(find "$SMOKE_DIR" -name "*.swift" | sort)

SRC=$(find mangox -name "*.swift" ! -name "mangoxApp.swift" | sort)

DEVELOPER_DIR="$DEV" xcrun swiftc \
    -sdk "$SDK" \
    -target "$ARCH-apple-macos14.0" \
    -D DEBUG \
    -D SMOKE \
    -o "$OUT/smoke" \
    $SMOKE_SRC \
    $SRC

"$OUT/smoke"
