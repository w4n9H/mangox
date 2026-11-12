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
#   ⚠️ **本脚本（以及任何 `set -o pipefail` 的脚本）内禁用 `| grep -q`**（2026-10-30 CI 实测）:
#   `-q` 命中即退 ⇒ 左边的 awk / echo 还在写，写进一条已经关闭的管道 ⇒ BSD awk 报
#   "i/o error occurred while closing /dev/stdout" 并**非零**退出 ⇒ `pipefail` 于是把"命中"
#   变成"红"。判命中一律写 `grep -cE … >/dev/null`（它必须读完才数得出来）。细节见 `has_code`。
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

# ⚠️ **SDK 主版本必须 ≥ 14**（2026-10-30 review 补的 CI 护栏）: 下面 `-target …-apple-macos14.0`
#    要求 SDK 能出 14.0 的部署目标。GitHub runner 的镜像一旦回退到老 Xcode, 报错会是
#    "invalid target / deployment target not supported" —— 那种失败**长得像代码错**, 会把人
#    引到错的方向。先在这里说清楚。
SDK_VERSION="$(DEVELOPER_DIR="$DEV" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [ -n "$SDK_VERSION" ] && [ "${SDK_VERSION%%.*}" -lt 14 ]; then
    echo "错误: SDK $SDK_VERSION 低于 14.0 (部署目标 -target …-apple-macos14.0 需要) —— 换更新的 Xcode" >&2
    exit 1
fi

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
if grep -nE 'withAnimation' -A2 mangox/Views/Chat/ChatView.swift | grep -cE 'scrollTo' >/dev/null; then
    echo "FAIL - 滚到底又带上补间了 (补间按动画插值的布局算落点, 实测差 100~260pt, 且没法复核)" >&2
    exit 1
fi

# 「源码事实门」的公共取词器 —— 剥掉**整行被注释掉**的行之后再匹配。
#    为什么必须剥: 把 `chmod(path, 0o600)` 前面加两个斜杠, 那串字**还在文件里** —— 不剥的话门会
#    对着注释里的同一串字点头, 反例注入之后照样 RC=0(2026-10-28 实测踩到: 注释掉 socket 权限那行,
#    ③i 一条没红)。⇒ 这类门当前全是**假门**, 判据改成"有效代码行里有这串字"。
#    ⚠️ 已知边界: 只挡「整行注释」这一种; 行尾注释 `let x = 1 // chmod(...)` 仍会误命中。
#    ⚠️ 右端必须写成 `grep -c … >/dev/null`，**不许 `grep -q`**（2026-10-30 CI 实测）:
#       `-q` 命中即退 ⇒ 左边的 awk / echo 还在写，写进一条已经关闭的管道 ⇒ BSD awk 报
#       "i/o error occurred while closing /dev/stdout" 并以**非零**退出 ⇒ `pipefail` 于是把
#       **"命中"变成"红"**。CI 那次就是这样：判据 225 行就命中了，报出来的却是
#       「滚到底的锚点不是内容末尾哨兵」。而本地跑三十次全绿 —— 这个 bug 只在"谁先跑完"
#       这件事上分胜负，**本地永远复现不了**。`-c` 要读完才数得出来，生产者看不到关闭的管道
#       ⇒ 同一句话在任何 runner 上都是同一个答案。
has_code() {
    awk '!/^[ \t]*\/\//' "$1" | grep -cE -- "$2" >/dev/null
}

# 计数版（有些判据要的不是"有没有"而是"几处都接上了"，例如同一个组件在两条分支里各出现一次）。
# ⚠️ 与 `has_code` 同一条纪律：**只用 `-c`，不用 `-q`** —— 见上面那段 CI 翻车的来龙去脉。
count_code() {
    awk '!/^[ \t]*\/\//' "$1" | grep -cE -- "$2" || true
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
if ! grep -A20 -E 'for \(i, delay\) in Self\.followBeats\.enumerated\(\)' mangox/Views/Chat/ChatView.swift \
        | grep -cE 'let candidate = i == 0 \? materializeCandidate : nil' >/dev/null; then
    echo "FAIL - 「滚到底」的节拍没有分两段 (followBeats 循环里第一拍必须取 materializeCandidate)" >&2
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
#
#     ⚠️ 2026-11-09 补上另一半：**提交那一拍是例外**（`mangox-20261109-142845.log`）。
#        回车时指示器下面**一个 chunk 都还没有**（`msgs` 卡在 1015 整整 8 秒）⇒ 锚它只能吃估算
#        总高（当时 doc=38797 / 8 秒后被量成 182609）⇒ 视口落进懒栈还没实例化的一段 = 白屏，
#        而几何判据全绿（`gap` / `doc` 是同一次估算算出来的，自己证明自己；`void` 读的 `bottom`
#        是 12.9 秒前的旧读数）。⇒ 选择逻辑收进 `ChatView.followTarget`：流式期返回指示器、
#        **提交拍返回哨兵**。这里的指纹跟着换成"循环真的用了它"；"选得对不对"由行为断言守
#        （`T-CSCROLL 回车那一拍…` / `T-CSCROLL 真正流式跟随时…` 两条），两处不重复同一件事。
FOLLOW_LOOP=$(grep -A20 'for (i, delay) in Self.followBeats.enumerated()' mangox/Views/Chat/ChatView.swift)
if ! echo "$FOLLOW_LOOP" | grep -cE 'Self\.followTarget\(origin: origin, isStreaming: store\.isStreaming\)' >/dev/null; then
    echo "FAIL - 「滚到底」的节拍没有按 followTarget 选锚点 (写死锚哨兵 = 吃总高估算 = 白屏)" >&2
    echo "       选择逻辑只许住 followTarget (那里有断言); 只改注释不算, 这门看的是真源码" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatView.swift '\.id\(Self\.streamingAnchor\)'; then
    echo "FAIL - 流式指示器上没有 .id(Self.streamingAnchor) (锚一个不存在的 id = 静默不滚 = 白屏)" >&2
    exit 1
fi
# ③g 静止态那一拍必须先锚尾块，而且判据是**尾块身份**（`ChatTailLedger.candidate` 比
#     `lastMaterialized`），不是"要不要量"的布尔开关 —— 开关在回车那一刻早就 false 了，
#     尾块却换了（多一条用户消息）⇒ 只锚哨兵 ⇒ 落进估算出来的空尾。0.1.30 实测：改判据前回车必白。
#     反过来的写法（无判据、每拍都先锚尾行）会让流式期每个 token 都 28pt 来回弹 = **刷屏**。
#     ⚠️ 2026-11-04 补：账必须**滚动之后**才记，否则被 veto 的那一拍也会记"量过" ⇒ 点「回到最新」
#        跳过实体化 ⇒ 同一片白屏从另一条路回来。
if ! has_code mangox/Views/Chat/ChatView.swift 'target != lastMaterialized'; then
    echo "FAIL - 静止态第一拍缺尾块身份判据 (ChatTailLedger.candidate 必须比 lastMaterialized)" >&2
    echo "       少了它 = 每拍都先锚尾行再锚哨兵, 28pt 来回弹 = 刷屏 (0.1.30 实测)" >&2
    exit 1
fi
# 记账必须排在滚动**之后**（2026-11-04 评审）：veto 拒绝时提前记账 ⇒ 之后「回到最新」
# 跳过尾块实体化 ⇒ 重新落进估算高度 = 白屏。两条行号缺一不可。
SCROLL_LINE="$(awk '/proxy\.scrollTo\(materialize \?\? target/ { print NR; exit }' mangox/Views/Chat/ChatView.swift)"
CONFIRM_LINE="$(awk '/tailLedger\.confirm\(materialize\)/ { print NR; exit }' mangox/Views/Chat/ChatView.swift)"
if [ -z "$SCROLL_LINE" ] || [ -z "$CONFIRM_LINE" ] || [ "$CONFIRM_LINE" -le "$SCROLL_LINE" ]; then
    echo "FAIL - 尾块记账没有排在滚动执行之后 (scroll@${SCROLL_LINE:-?} confirm@${CONFIRM_LINE:-?})" >&2
    echo "       提前记账 = veto 拒绝也记 '量过' ⇒ 「回到最新」跳过实体化 = 白屏" >&2
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

# ③v 「某个 App 读起来不一样」只许写在 `ComputerAppProfile` 的表里 (2026-11-09, 收口那一步)。
#    加 Safari 那轮的全部差异只有**渲染上限**一件事, 但它被写成了一句按 bundle 字面量分叉的
#    三元表达式, 藏在 AXSnapshot 里。再加一个浏览器就会变成 `bundle == A || bundle == B ? … : …`
#    —— 这种写法**错一个字符就谁都不生效**: 不报错、不告警, 行为只是静默退回 120,
#    而 120 行对网页来说等于"只能读到页头"(实测 GitHub 仓库页 1598 行, 正文在 1000 行开外)。
#    ⚠️ 编译得过、数值守卫也看不见(120 本来就是个合法值) ⇒ 只能扫源码事实(同 ③k)。
#    ⚠️ 表本身不算命中的: 它里面写的是 `"bundle": 3000` 这种键值, 没有等值比较。
STRAY_BUNDLE_EQ="$(grep -rn '== "com\.apple\.Safari"' mangox/ mangox-compute/ || true)"
if [ -n "$STRAY_BUNDLE_EQ" ]; then
    echo "FAIL - 又出现了按 bundle 字面量分叉的写法（读法差异必须住 ComputerAppProfile 的表里）:" >&2
    echo "$STRAY_BUNDLE_EQ" >&2
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
# ③s 人类接管(批 3b): 三条**只有在真机上才会静默失效**的事实。
#   ① CGEvent **只许听, 不许注入**: 听(`CGEvent.tapCreate` listenOnly)是"人在动键鼠吗"的唯一来源;
#      而注入(`event.post(...)` / `CGEventPost`)是按坐标点**任何**地方的**第二套寻址** ——
#      它绕开编号 ⇒ 三条恒拒(付款 / 永久删除 / 存盘)判不起来。判据因此从"helper 里不许出现
#      CGEvent"(批 2b 的写法, 那时监听还没做)收窄成"不许**发**事件"。
#   ⚠️ **2026-11-10 又改了一次口径(纯视觉动手 `tap` 落地, boss 拍板"开成窄口")**:
#      坐标寻址没有被**放开**, 而是被**围起来了**。围栏 = `ComputerTapRule.refusal` 的十三道闸:
#      档位 / 可操作 / 同进程 / 前台 / 没按键 / 人静 400ms / 坐标范围 / 快照有几何 / 窗口没挪 /
#      点在窗口内 / 顶上窗口是自己 / 窗口号对得上 / **底下读到付款·永久删除就拒** —— 最后那一闸
#      正是 ① 说的三条恒拒在这一档上的对应物(词表与 `press` 同源, 不抄第二份)。
#      于是判据从"不许发"收窄成"**只许 `hidClick` 这一处发, 且调用点必须排在判据之后**"。
#      ⚠️ 下面每一条都在钉围栏的**某一根柱子**: 谁发 / 发几发 / 排在谁后面 / 光标还不还。
#      少一根它就退回成"第二套寻址" —— 而回退之后**编译得过、界面上也没有任何异样**。
for f in mangox-compute/*.swift; do
    [ "$f" = "mangox-compute/ComputerServer.swift" ] && continue
    if has_code "$f" '\.post\(|CGEventPost'; then
        echo "FAIL - $f 里在发合成事件 (event.post / CGEventPost)" >&2
        echo "       全仓只允许 ComputerServer.swift 的 hidClick 一处发(围栏见本节 ①)" >&2
        exit 1
    fi
done
if ! has_code mangox-compute/ComputerServer.swift '\.post\(tap: \.cghidEventTap\)'; then
    echo "FAIL - hidClick 不再经 .cghidEventTap 投递" >&2
    echo "       改回 postToPid 就点不动(三种变体实测全失败, 见 ComputerTapRule 文件头)" >&2
    exit 1
fi
TAP_POST_N="$(count_code mangox-compute/ComputerServer.swift '\.post\(')"
if [ "$TAP_POST_N" != "6" ]; then
    echo "FAIL - helper 里发合成事件的处数是 ${TAP_POST_N}, 应该是 6 (鼠标 down/up + 字符 down/up + 回车 down/up)" >&2
    exit 1
fi
TAP_HIDCALL_N="$(count_code mangox-compute/ComputerServer.swift 'hidClick\(at')"
if [ "$TAP_HIDCALL_N" != "2" ]; then
    echo "FAIL - hidClick 出现 ${TAP_HIDCALL_N} 次(定义 + 调用应为 2) ⇒ 窄口又多开了一处" >&2
    exit 1
fi
TAP_RULE_LINE="$(awk '/ComputerTapRule\.refusal\(/ { print NR; exit }' mangox-compute/ComputerServer.swift)"
TAP_CLICK_LINE="$(awk '/hidClick\(at: cg/ { print NR; exit }' mangox-compute/ComputerServer.swift)"
if [ -z "$TAP_RULE_LINE" ] || [ -z "$TAP_CLICK_LINE" ] || [ "$TAP_RULE_LINE" -ge "$TAP_CLICK_LINE" ]; then
    echo "FAIL - 按坐标点的判据与执行顺序不对 (rule@${TAP_RULE_LINE:-?} click@${TAP_CLICK_LINE:-?})" >&2
    echo "       十三道闸必须排在 hidClick 之前 —— 反了等于'先点了再问能不能点', 而这一档没有撤销" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'defer .*CGWarpMouseCursorPosition\(restore\)'; then
    echo "FAIL - hidClick 不再把光标还回去(它就在你眼前被挪走了, 不还等于抢鼠标)" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'primaryHeight - saved\.y'; then
    echo "FAIL - 光标归位不再做左下→左上原点换算" >&2
    echo "       2026-11-10 实测: 少了这一步差 36px, 而回执照样写着'归位了'" >&2
    exit 1
fi
# ⚠️ 2026-11-10 第五档(`computer_type`)把"发事件"又扩了一次(键盘)。**同一套围栏, 同样四根柱子**:
#    谁发(上面那圈已经管住) / 几处 / 排在谁后面 / 分段与键码有没有被改坏。
TYPE_HIDCALL_N="$(count_code mangox-compute/ComputerServer.swift 'hidType\(')"
if [ "$TYPE_HIDCALL_N" != "2" ]; then
    echo "FAIL - hidType 出现 ${TYPE_HIDCALL_N} 次(定义 + 调用应为 2) ⇒ 键盘那个窄口又多开了一处" >&2
    exit 1
fi
TYPE_RULE_LINE="$(awk '/ComputerTypeRule\.refusal\(/ { print NR; exit }' mangox-compute/ComputerServer.swift)"
TYPE_CALL_LINE="$(awk '/return hidType\(text:/ { print NR; exit }' mangox-compute/ComputerServer.swift)"
if [ -z "$TYPE_RULE_LINE" ] || [ -z "$TYPE_CALL_LINE" ] || [ "$TYPE_RULE_LINE" -ge "$TYPE_CALL_LINE" ]; then
    echo "FAIL - 打字的判据与执行顺序不对 (rule@${TYPE_RULE_LINE:-?} type@${TYPE_CALL_LINE:-?})" >&2
    echo "       判据必须排在 hidType 之前 —— 反了就是'先打了再问能不能打', 而打出去的字撤不回" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'keyboardSetUnicodeString'; then
    echo "FAIL - 打字不再走 keyboardSetUnicodeString (改按物理键位映射就写不了中文)" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'min\(i \+ 20'; then
    echo "FAIL - 一次送的不再按 20 个 UTF-16 单元分段" >&2
    echo "       keyboardSetUnicodeString 的硬上限是 20, 超了会被**静默截断**(一个字都不报错)" >&2
    exit 1
fi
# ⚠️ 2026-11-11 代码评审: 20 单元的切分点必须是**字符边界**。原来写的是
#    `Array(text.utf16)` + `min(start + 20, …)`, 一个 emoji / 扩展 B 汉字占 2 个单元,
#    跨边界就被劈成两个**孤代理** ⇒ 目标 App 收到替换字符或什么都不收, 全程零报错。
#    真机只量过中文(BMP, 一字符一单元) ⇒ 那种切法在那里永远是对的, 所以验收看不见。
if ! has_code mangox-compute/ComputerServer.swift 'for ch in text'; then
    echo "FAIL - 打字的切分不再按 Character 走(硬切 UTF-16 单元会劈开代理对: emoji 与扩展 B 汉字)" >&2
    echo "       判据 = 循环源是 `for ch in text`, 不是 `for` 一个 UTF-16 数组" >&2
    exit 1
fi
if has_code mangox-compute/ComputerServer.swift 'Array\(text\.utf16\)'; then
    echo "FAIL - 又把整段拆成 UTF-16 单元数组再切 (代理对会被劈成两半, 而这条链一声不响)" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'virtualKey: 36'; then
    echo "FAIL - 提交那一下不再按 return(36)" >&2
    exit 1
fi
# ③y 模拟输入与"人在不在"的账(2026-11-11 代码评审抓出来两条):
#
#   ① **我们自己发的键鼠事件必须盖记号**。`hidClick` / `hidType` 走 `.cghidEventTap`,
#      而 `HumanInputTap` 挂在下游的 `.cgSessionEventTap` ⇒ 我们点的那一下、敲的那个键
#      一定会先经过它。不盖记号的后果: 紧接着的第二步被 `humanQuietMs`=400ms 拒掉, 而话术
#      写着"你 47 毫秒前刚动过键鼠"; 更远一点, 接管检测那 6 秒窗也用同一个时间戳 ⇒
#      一次 tap/type 之后**接下来 6 秒的每次 act 都回"刚才有人动了鼠标"**。两者都零红灯,
#      而且只在模型往返 < 400ms 时显形 —— 它一直靠 LLM 的延迟侥幸活着。
#
#   ② **动过界面就必须把旧快照作废**。`finishAct` 早就是"重读 + 换号 + 明说旧编号作废",
#      而 `hidClick` / `hidType` 原来把 seq 原样返回 ⇒ 界面刚变过, `seq` 判据却照样放行,
#      模型能拿旧编号接着 act, 按到语义已经变了的那一格。
TAG_N="$(count_code mangox-compute/ComputerServer.swift 'HumanInputTap\.stampSelfInjected\(')"
if [ "$TAG_N" != "6" ]; then
    echo "FAIL - 给自注入事件盖记号的是 ${TAG_N} 处 (应为 6 = 点按两发 + 成段写字两发 + 回车两发)" >&2
    echo "       漏掉的那一发会被自己的只读监听记成人类输入 ⇒ 下一步 400ms 内被拒, 而话术怪到人头上" >&2
    exit 1
fi
if ! has_code mangox-compute/HumanInputTap.swift 'setIntegerValueField\(\.eventSourceUserData'; then
    echo "FAIL - 记号不再写进 eventSourceUserData (记号必须跟着事件走, 时间窗会把真实输入一起吃掉)" >&2
    exit 1
fi
if ! has_code mangox-compute/HumanInputTap.swift 'getIntegerValueField\(\.eventSourceUserData\)'; then
    echo "FAIL - 回调不再比对自注入记号 ⇒ 我们自己发的键鼠被记成人类输入" >&2
    exit 1
fi
INVALIDATE_N="$(count_code mangox-compute/ComputerServer.swift 'invalidateSnapshot\(')"
if [ "$INVALIDATE_N" != "3" ]; then
    echo "FAIL - invalidateSnapshot 出现 ${INVALIDATE_N} 次 (定义 + 点按 + 写字应为 3)" >&2
    echo "       动过界面不作废旧快照 ⇒ 模型能拿旧编号接着 act, 而 UI 已经变了" >&2
    exit 1
fi
# 焦点那一条只活在 helper 侧(取事实), 判据在 `ComputerTypeRule`(冒烟里钉着)。
# 这里守的是"取事实那一步还在": 没人问过焦点, 上面那条闸就永远拿不到输入。
if ! has_code mangox-compute/ComputerServer.swift 'AXAdapter\.focusedRole\(pid:'; then
    echo "FAIL - 打字不再问'焦点落在什么控件上' ⇒ 往列表里敲字符会变成按键跳转, 而回执说'写了'" >&2
    exit 1
fi
# 视觉那一档改名之后, helper 里**一处**都不许再出现旧名 —— 回执让人去勾一个不存在的勾选框,
# 而这种漂移冒烟断言不到(helper 不在冒烟编译范围), 只能扫源码。
for f in mangox-compute/*.swift; do
    if has_code "$f" '「图片」'; then
        echo "FAIL - $f 还在说「图片」(2026-11-10 已改名「视觉」) ⇒ 那句话指向一个不存在的勾选框" >&2
        exit 1
    fi
done
# 协议那一半(解码)只活在 helper 里, 冒烟编不到它 ⇒ 只能扫源码:
# `point` 缺了必须解成 nil、由 server 拒并说清"要点哪儿" —— 在解码层编一个默认点(比如 0,0)
# 就等于把"模型没给坐标"变成"模型要左上角", 而它是模型最容易照做的那一个坐标。
if ! has_code mangox-compute/ComputerProtocol.swift 'case tap\(app: String, point: ComputerPoint\?, seq: Int\)'; then
    echo "FAIL - ComputerRequest 里没有独立的 tap 分支(并进 act 就是给九条判据开第二语义)" >&2
    exit 1
fi
TAP_BRANCH="$(awk '/case "tap":/{f=1; next} f && /^        case "/{exit} f {print}' mangox-compute/ComputerProtocol.swift)"
case "$TAP_BRANCH" in
    *'decodeIfPresent(ComputerPoint.self, forKey: .point)'*) ;;
    *)
        echo "FAIL - tap 的坐标没走 decodeIfPresent(缺坐标时会被塞一个默认点)" >&2
        exit 1
        ;;
esac
case "$TAP_BRANCH" in
    *'?? ComputerPoint'*|*'decode(ComputerPoint'*)
        echo "FAIL - tap 在解码层给坐标填了默认值" >&2
        echo "       缺坐标要在 server 拒并说清'要点哪儿'; 填 0,0 等于把'没给'变成'点左上角'" >&2
        exit 1
        ;;
esac
# 第五档的解码分支: 同样是扫源码(它只编进 helper)。
#   ① `submit` **缺省必须是 false** —— 写 `?? true` 等于"默认发送", 而发送撤不回;
#   ② 不许在解码层为 `text` 编默认值 —— 空文本要由 server 拒并说清"要写什么"。
TYPE_BRANCH="$(awk '/case "type":/{f=1; next} f && /^        case "/{exit} f {print}' mangox-compute/ComputerProtocol.swift)"
case "$TYPE_BRANCH" in
    *'forKey: .submit) ?? false'*) ;;
    *)
        echo "FAIL - type 的 submit 缺省不是 false (缺省 true = 默认按回车 = 默认可发送)" >&2
        exit 1
        ;;
esac
if ! has_code mangox-compute/HumanInputTap.swift 'options: \.listenOnly'; then
    echo "FAIL - 人类接管的监听不再是 listenOnly (它就没有资格改/吞用户的事件)" >&2
    exit 1
fi
if ! has_code mangox-compute/HumanInputTap.swift 'tapDisabledByTimeout'; then
    echo "FAIL - 监听被系统踢掉之后不再自检重装 (接管会静默消失, 零红灯)" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'env\[HumanInputTap\.envKey\] == "1"'; then
    echo "FAIL - helper 不再按 env 决定装不装监听 (缺省必须是'不装')" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'if let why = takeoverRefusal\(\)'; then
    echo "FAIL - act 不再先问'刚才有人动键鼠吗' (接管那道门没人调)" >&2
    exit 1
fi
if ! has_code mangox/Agent/ComputerHost.swift '"MANGOX_COMPUTE_TAKEOVER"'; then
    echo "FAIL - App 侧不再下发接管开关 (helper 永远收不到 ⇒ 这条能力静默不存在)" >&2
    exit 1
fi
if ! has_code mangox-compute/HumanInputTap.swift '"MANGOX_COMPUTE_TAKEOVER"'; then
    echo "FAIL - helper 侧的接管 env 名不见了 (两侧必须逐字相同, 编译不会报错)" >&2
    exit 1
fi

# ③t 图像面(批 3c) —— 七条会**静默**坏掉的地方
#
#   ① 截图 API: `CGWindowListCreateImage` 在 macOS 14.0 起被标记弃用。这不是风格问题 ——
#      本项目门禁要求 **0 warning**, 用它当场就红(实测确认过)。SCK 是唯一干净的路。
#   ② env 串两侧必须逐字相同: 编译不报错, 写歪了就是"设置页勾着、helper 说没开"。
#   ③ 屏幕录制是**另一份 TCC**, 与辅助功能不共享。不探测就只能回一句"截图失败: …",
#      而用户不知道该去系统设置里勾哪一个 —— 这句话等于没说。
#   ④ **像素面不涂黑**(2026-10-30 boss 定): 密码框自己就渲染成圆点, 黑块只遮住长度;
#      而黑块一旦落错位置(判据放宽 / 两套坐标系不同源 / 受保护容器框住整片), 整张图就废了,
#      且**遮错的东西长得和遮对的一模一样**。遮蔽只留在文本层。这条要挡住"谁把它加回来"。
#   ⑤ **只有读面能发图**: 图像对象只许装配一处(finishRead), 动作面永远拿不到像素。
#   ⑥ 截图等待必须带超时: 无超时会让单线程 helper 永久堵在 sem.wait 上(accept 循环不转)。
#   ⑦ AX 遍历预算必须是全局的: 每棵子树各一份 ⇒ 深层界面全量走完, 一条 read 卡几十秒。
for f in mangox-compute/*.swift; do
    if has_code "$f" 'CGWindowListCreateImage|CGDisplayCreateImage'; then
        echo "FAIL - $f 用了已弃用的截图 API (macOS 14.0 起标记弃用 ⇒ 破 0 warning 门禁)" >&2
        echo "       改用 SCScreenshotManager.captureImage (见 ComputerShot.shoot)" >&2
        exit 1
    fi
done
if ! has_code mangox-compute/ComputerShot.swift 'SCScreenshotManager\.captureImage'; then
    echo "FAIL - 截图不再走 ScreenCaptureKit" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerShot.swift 'CGPreflightScreenCaptureAccess'; then
    echo "FAIL - 不再探测屏幕录制权限 (没有它只会回一句'截图失败', 用户不知道去勾哪个)" >&2
    exit 1
fi
# 单窗口截图必须关掉阴影: 开着一圈半透明阴影会让画面四周多出几十像素透明边,
# 图看着像"窗口漂在一块透明底上", 也让任何按窗口框做的像素级判断全错位。
if ! has_code mangox-compute/ComputerShot.swift 'ignoreShadowsSingleWindow = true'; then
    echo "FAIL - 单窗口截图又带上了阴影 (四周多出几十像素透明边)" >&2
    exit 1
fi
# ⚠️ 等 SCK 回来时必须**泵主队列**(2026-11-11 根因修复): `SCShareableContent` /
#    `SCScreenshotManager` 的完成回调派回 **main queue**, 而 helper 的 socket 循环就在主线程。
#    直接 `sem.wait(timeout: .now() + captureTimeout)` 会把主线程堵死 ⇒ 回调永远排不上队
#    ⇒ **每次截图都等满 8 秒然后报"捕捉服务卡住了"**。现场两份轨迹读数: 两次带图 read
#    各 8.0s, 而同一时刻 `screencapture` CLI 251ms 就出了图 ⇒ 不是屏幕休眠、不是权限。
#    ⚠️ "没权限时不死锁"证明不了什么: TCC 是同步拒绝, 一次 XPC 都不发。
if ! has_code mangox-compute/ComputerShot.swift 'RunLoop\.current\.run\(mode:'; then
    echo "FAIL - 等截图结果时不再泵主队列 (SCK 回调派回 main queue ⇒ 每次截图都等满 8 秒)" >&2
    echo "       主线程既跑 socket 循环又堵在 sem.wait 上, 回调永远排不上队" >&2
    exit 1
fi
if has_code mangox-compute/ComputerShot.swift 'guard sem\.wait\(timeout: \.now\(\) \+ captureTimeout\)'; then
    echo "FAIL - 又回到「主线程裸等 8 秒」的写法 (回调派回 main queue ⇒ 必然超时)" >&2
    exit 1
fi
# ⚠️ 判据是"与界面树几何对齐": 尺寸一律取 `SCWindow.frame`, 不取 AX 的窗口框 ——
#    两者差一个标题栏时, 按 AX 框设宽度会让 SCK 非等比缩放 ⇒ 画面整个变形。
if ! has_code mangox-compute/ComputerShot.swift 'captureSize\(window: axRect\(win\.frame\)\)'; then
    echo "FAIL - 输出尺寸不再取自 SCWindow.frame (改回 AX 窗口框 ⇒ 差一个标题栏就非等比缩放)" >&2
    exit 1
fi
# ⚠️ 长边上限要落在**交给 SCK 的那个尺寸**上, 不是拿到图之后再缩: 后者多一次全画布拷贝,
#    也多一处"画布建不出来"的失败分支。谁把 `captureSize` 改回"窗口多大就拍多大",
#    在 6K 屏 + 贴满缩略图的窗口上就会顶到模型侧的单图上限 —— 而且报的是上游错误,
#    模型看到的东西里没有一个字指向"图太大"。纯函数那半边仍全绿, 只有这里能拦住。
if ! has_code mangox/Models/ComputerShotRule.swift 'fit\(width: max\(1, window\.w\)'; then
    echo "FAIL - captureSize 不再过 fit (窗口多大就拍多大 ⇒ 大窗口的 PNG 会顶到单图上限)" >&2
    echo "       上限必须压在 config.width/height 上, 不能拿到图之后再重绘" >&2
    exit 1
fi
# 两个数必须**是同一个数**: App 侧用户发的图与 helper 拍的截图, 最后进的是同一个上下文。
# ⚠️ 两个 target 各自编译(`mangox-compute` 里没有 `ImagePipeline`) ⇒ 类型系统帮不上忙,
#    只能靠这条源码事实 —— 打歪一处就是两套预算, 而两套都不会报错。
SHOT_EDGE="$(awk '/static let maxEdge = /{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' mangox/Models/ComputerShotRule.swift)"
SEND_EDGE="$(awk '/static let maxSendSide/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' mangox/Agent/ImagePipeline.swift)"
if [ -z "$SHOT_EDGE" ] || [ "$SHOT_EDGE" != "$SEND_EDGE" ]; then
    echo "FAIL - 截图长边上限 ${SHOT_EDGE:-取不到} ≠ 发图长边上限 ${SEND_EDGE:-取不到}" >&2
    echo "       用户发的图和截图进同一个上下文 ⇒ 这个上限只能有一个数" >&2
    exit 1
fi
if ! has_code mangox/Models/ComputerShotRule.swift '"MANGOX_COMPUTE_IMAGE_BUNDLES"'; then
    echo "FAIL - 判据侧的图像名单 env 名不见了" >&2
    exit 1
fi
# ⚠️ 回执里的"1:1"必须**按图自己的像素尺寸**算, 不许写成常量: 0.2.11 起大窗长边封顶 1536
#    ⇒ 图会被等比缩小, 而写死的 1:1 会让模型拿图内像素当屏幕偏移用 —— 点得下去, 点在别处,
#    且零报错。图尺寸只能来自 `CGImage.width/height`(`ComputerShot.Shot`)。
if has_code mangox-compute/ComputerServer.swift '图与窗口 1:1'; then
    echo "FAIL - 截图回执又把「图与窗口 1:1」写死了 (大窗被缩过 ⇒ 按图标点会整体偏)" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'shot\.width'; then
    echo "FAIL - 截图回执不再报图自己的像素尺寸 (模型算不出 图宽÷窗口宽 这个比例)" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerShot.swift 'Shot\(png: \$0, width: image\.width'; then
    echo "FAIL - 图尺寸不再取自 CGImage 自己 (改回窗口框 ⇒ 大窗被缩时报的尺寸是错的)" >&2
    exit 1
fi
if ! has_code mangox/Agent/ComputerHost.swift '"MANGOX_COMPUTE_IMAGE_BUNDLES"'; then
    echo "FAIL - App 侧不再下发图像名单 (helper 永远收不到 ⇒ 勾了也没用)" >&2
    exit 1
fi
# ④ 像素面不涂黑 —— 判据是"**结构上没有这个能力**", 不是"这个能力输出为空":
#    输出为空靠造一条用例就能骗过, 而类型/绘制调用一旦回来, 就是"哪天判据放宽就真动手了"。
#    ⚠️ 只有源码扫描能抓这条: 纯函数那半边全绿、编译零 warning, 遮错只会体现在图上看不出来。
if has_code mangox/Models/ComputerShotRule.swift 'Redaction|redactions'; then
    echo "FAIL - 图像面的涂黑判据又回来了 (2026-10-30 已废除: 遮错会让整张图失去价值)" >&2
    echo "       遮蔽只留在文本层 (ComputerRedline.maskedValue), 粒度是元素而不是像素" >&2
    exit 1
fi
if has_code mangox-compute/ComputerShot.swift 'ctx\.fill'; then
    echo "FAIL - ComputerShot 又在往图上填色块 (像素遮蔽已废除)" >&2
    exit 1
fi
# ⑤ **只有读面能发图**（验收项 6 的 ③, 2026-10-30 到期补上）。
#    做法是"图像对象只许装配一处": `ComputerImage(` 在整个 helper 里必须恰好出现 1 次,
#    而且那次必须在 `finishRead` 里(读面的唯一出口)。
#    ⚠️ 为什么用计数而不是"act 分支里搜 image": 坏法不止一种 —— 有人可能在 act 的**回执文本**
#    里塞 base64、或者新加一个 `shot` 操作直接返回像素, 那些都绕过了"act 分支"这个字面。
#    计数管的是"这扇门只有一把钥匙"。
SHOT_IMAGE_SITES="$(awk '/ComputerImage\(/ { n++ } END { print n+0 }' mangox-compute/ComputerServer.swift)"
if [ "$SHOT_IMAGE_SITES" != "1" ]; then
    echo "FAIL - 图像对象的装配点不是唯一一处 (实测 $SHOT_IMAGE_SITES 处) ⇒ 图可能从动作面出去" >&2
    echo "       只有 finishRead(读面出口) 允许装配 ComputerImage" >&2
    exit 1
fi
# ⑥ 截图等待**必须带超时**（2026-10-30 review 修的）: 无超时的 `sem.wait()` 会让单线程的
#    helper 永久阻塞 —— accept 循环不转, 进程活着但整个 computer use 死了, 只能重启 App。
if ! has_code mangox-compute/ComputerShot.swift 'sem\.wait\(timeout:'; then
    echo "FAIL - 截图等待又变成无超时的 sem.wait() ⇒ 一次卡住 = 永久卡住" >&2
    exit 1
fi
# ⑦ AX 遍历预算必须是**全局**的（2026-10-30 review 修的）: 原来 `budget: remaining` 只在
#    兄弟之间递减, 子树烧掉的节点不回流 ⇒ 总量是乘出来的, 深层 DOM 会把整棵树全量走完。
if ! has_code mangox-compute/AXAdapter.swift 'budget\.left' ; then
    echo "FAIL - AX 遍历的全局预算计数不见了 (budget.left)" >&2
    exit 1
fi
if has_code mangox-compute/AXAdapter.swift 'budget: remaining'; then
    echo "FAIL - AX 遍历预算又变成'每棵子树各一份' (budget: remaining) ⇒ 深层界面会全量走完" >&2
    exit 1
fi

# ⑧ AX 遍历必须**每个节点都查一次墙钟**（2026-11-02 实测逼出来的）。
#    背景: 邮件收件箱(799 封)一次 read 走 3000 节点、**200 秒**, 而 helper 是单线程串行
#    (accept → 处理 → 关闭) ⇒ 那 200 秒里连 accept() 都不转, 别的会话全排队。
#    没有超时 = 一个 App 能让整条 computer use 失效, 而且**零红灯**: 编译过、纯函数全绿,
#    只有真机点下去才发现"卡住了"。
#    ⚠️ 判据是**两处**: 外层 `if depth < maxDepth, …` 与内层 `guard … else { break }`。
#       只留一处 = 深层递归里仍会连续走完整层兄弟（每层 2~3 个、20 层 DOM 就是几十次 IPC），
#       超时从"12 秒止损"退化成"12 秒后还得把当前层走完"。⇒ 少于 2 处就红。
EXPIRED_N="$(awk '!/^[ \t]*\/\//' mangox-compute/AXAdapter.swift | grep -cE '!budget\.expired')"
if [ "${EXPIRED_N:-0}" -lt 2 ]; then
    echo "FAIL - AX 遍历的墙钟检查只剩 ${EXPIRED_N:-0} 处 (需要 2: 外层 if + 内层 guard)" >&2
    echo "       缺一处 ⇒ 超时只在外层生效, 深层循环里仍会一层层走完 ⇒ 又是一次几十秒的卡死" >&2
    exit 1
fi
# ⑨ 一次 read 的墙钟预算必须是**同一个数**从常量流过去的（不许 read 路径自己写个 10/30）。
#    否则超时逻辑看着在, 实际量的是另一个上限; 而且 `readTimeout` 是回执里那句
#    "只读完了一部分"的话术来源 —— 两处不等时, 说出来的数和做出来的事对不上。
if ! has_code mangox-compute/ComputerServer.swift 'AXAdapter\.readTimeout'; then
    echo "FAIL - read 路径没用 AXAdapter.readTimeout (自己写死了超时?) ⇒ 回执里的秒数与实际止损点会不一致" >&2
    exit 1
fi
# ⑩ 每次 read 都必须**记一笔观测**（2026-11-02 的 A 方案）。
#    设置页的"读不动 · Ns"完全靠它, 而它是 helper 写的、App 侧只读 —— 中间任何一环断了
#    (没调 / 路径变了 / 缺 .atomic) 都**没有任何红灯**: 设置页就是一直空着, 看起来像"全都好用"。
#    ⚠️ 这条同时是"名单自己长出来"的地基: 读成功也写(覆盖坏标记) ⇒ 不写就没有自动恢复。
if ! has_code mangox-compute/ComputerServer.swift 'recordReadHealth\(bundle:'; then
    echo "FAIL - read 的出口没有再记读健康观测 ⇒ 设置页永远不会显示'读不动', 也不会自动恢复" >&2
    exit 1
fi
# ⑪ 观的**落盘目录**必须在 helper 与 App 两侧是同一个字面量。
#    它们是两个 target, 不能共享常量 ⇒ 路径只能各写一份, 而写错的那一侧**零红灯**:
#    helper 照常写、设置页照常读, 只是一直读到空目录 ⇒ 页面看起来像"全都好用"。
for f in mangox-compute/ComputerServer.swift mangox/State/ComputerSettings.swift; do
    if ! has_code "$f" '"\/\.mangox/computer/health"'; then
        echo "FAIL - $f 里没有 \"/.mangox/computer/health\" 这个落盘路径" >&2
        echo "       helper 写、App 读, 两个 target 各写一份 ⇒ 改了一边就等于观测静默断链" >&2
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
# ③p2 「切前台」那条路: `NSRunningApplication.activate(options:)` 在 helper 这种**裸进程**里
#     **返回 true 却什么都不做**(2026-11-10 实测: 先把前台让给访达, 再调 `.activateAllWindows`,
#     返回值 true, `isActive` 仍是 false)。症状与 ③p 同族但更坏 —— 它是**动作**在撒谎:
#     回执写「已经切到前台」, 而 App 还在后面, 接下来 act/tap 要么点不动(后台点击无效)、
#     要么被「不是前台」拒掉, 两种都指向一个和真实原因无关的地方。
#     ⇒ ① 这个 API 一处都不许再出现在 helper 里; ② `open` 的 `.activate` 分支必须**按效果判**
#        (`isFrontmost` 轮询), 不许拿返回码当结果。
for f in mangox-compute/*.swift; do
    if has_code "$f" '\.activate\(options:'; then
        echo "FAIL - $f 又在用 NSRunningApplication.activate(options:)" >&2
        echo "       它在裸进程里返回 true 但什么都不做 ⇒ 回执会说'已切前台'而它还在后面" >&2
        echo "       改用 NSWorkspace.shared.open(App 包 URL)(实测真置前, 且不会另起一份)" >&2
        exit 1
    fi
done
if ! has_code mangox-compute/ComputerServer.swift 'guard Self\.isFrontmost\(bundle: t\.bundle, pid: t\.pid\) else'; then
    echo "FAIL - computer_open 的「只切前台」不再按效果判 (置前请求发出去了 ≠ 它到了前台)" >&2
    exit 1
fi

# ③x 内置扩展的归属账（2026-11-10，boss 问「mangox-computer.ts 是内置在代码中吗」时查出来）。
#    判据 = **MangoX 自己会往托管目录写的 `mangox-*.ts`, 一个不少地都要在 `builtInNames` 里** ——
#    不是"谁看起来像我们写的"。漏一个的后果全在面板上, 而且**零红灯**: 删除按钮点了又回来(打地鼠),
#    外加一个按不动的启停开关(它的挂载走独立参数, 不看面板那个 enabled 列表)。
#    输入取 `PiRpcTransport.swift` 里的**字面量**(真源, 常量与字面量两种写法都覆盖)
#    ⇒ 加第 6 个自管扩展时不用记得手动登记这条账。
#    ⚠️ 这条只管"会不会漏登记"; 「挂载那几条轴」另有判据 —— `businessExtensionPaths` 必须把同一批
#       都滤掉(漏一个就是同一次 spawn 里 `--extension` 传两次、工具注册两遍),
#       那条是纯函数断言, 在冒烟 `T-EXT-BUILTIN` 里(见 `caseBuiltInExtensions`)。
AUTO_EXT_FILES="$(grep -oE '"mangox-[a-z-]+\.ts"' mangox/Agent/PiRpcTransport.swift \
                  | tr -d '"' | sort -u)"
if [ -z "$AUTO_EXT_FILES" ]; then
    echo "FAIL - 一个自管扩展文件名都没扫到 ⇒ ③x 这条账是空转的" >&2
    exit 1
fi
BUILTIN_NAMES_LINE="$(awk '/static let builtInNames/,/\]/' mangox/Models/ExtensionModels.swift | tr '\n' ' ')"
for one in $AUTO_EXT_FILES; do
    nm="${one%.ts}"
    case "$BUILTIN_NAMES_LINE" in
        *"\"$nm\""*) ;;
        *)
            echo "FAIL - $one 会由 MangoX 自己写进托管目录, 但 \"$nm\" 不在 builtInNames 里" >&2
            echo "       面板会给它删除按钮(点一下又回来)和一个按不动的启停开关, 而零红灯" >&2
            exit 1
            ;;
    esac
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

# ③n2 输入框高度必须用**参数里的** scrollView，不许缓存成 coordinator 的属性 (2026-11-04 评审)。
#    旧版 `attachedScrollView` 全仓从未赋值 ⇒ `updateNSView` 的 guard 恒早退：
#    从外部改 draft（@ 插入 / 附加文件）后高度停在旧值，键盘输入那条路却能走 ⇒ 日常看不出来。
#    ⚠️ 编译得过、断言也全绿（键盘路径另有一条），只能扫源码事实。
if has_code mangox/Views/Chat/ChatComposer.swift 'attachedScrollView'; then
    echo "FAIL - 输入框又把 scrollView 缓存进 coordinator 了 (死字段一出现, 外部改 draft 高度就静默失效)" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatComposer.swift 'coordinator\?\.reportHeight\(scrollView: scrollView\)'; then
    echo "FAIL - updateNSView 没有用参数里的 scrollView 调 reportHeight" >&2
    exit 1
fi

# ③n3 分享图片必须两个 writer 都调用 (2026-11-04 评审)。
#    写成 `setData(png) || setData(tiff)` 会短路：声明了 .tiff 却没有写。
#    ⚠️ 端到端读 `.tiff` 抓不到 —— NSPasteboard 会按需用 PNG 合成 TIFF，断言照样绿。
if [ "$(awk '!/^[ \t]*\/\// && /writeBothFormats\(/ { n++ } END { print n+0 }' \
        mangox/Views/Chat/MessageImageShare.swift)" -lt 2 ]; then
    echo "FAIL - MessageImageShare 不再走 writeBothFormats (或只有定义没有调用点)" >&2
    echo "       两个 writer 必须都执行; 端到端 TIFF 断言会被 NSPasteboard 的自动转换骗绿" >&2
    exit 1
fi

# ③n4 流式跟随必须比**轻量 revision**，不许比 `[ChatMessage]` (2026-11-04，B 批)。
#    `ChatMessage` 的合成 == 会深比正文 / 工具输出 / 思考；每个 chunk 一次 = 长会话平方级。
#    ⚠️ 换回数组比较照样编译、照样能滚，只是慢 —— 只能扫源码事实。
if has_code mangox/Views/Chat/ChatView.swift 'onChange\(of: store\.messages\)'; then
    echo "FAIL - 流式跟随又在比 [ChatMessage] 了 (每 chunk 深比全部历史)" >&2
    echo "       触发值必须是 store.messagesRevision，尾 id 判断也只留一个 UUID" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatView.swift 'onChange\(of: store\.messagesRevision\)'; then
    echo "FAIL - 流式跟随没有接 messagesRevision" >&2
    exit 1
fi
if ! has_code mangox/State/ChatStore.swift 'messagesRevision &\+='; then
    echo "FAIL - messages.didSet 不再推进 messagesRevision (所有写路径都会失去跟随)" >&2
    exit 1
fi

# ③n5 工具输出 / 思考卡 = **一个 `Text` 承载整段** (2026-11-04 评审 C1)。
#    `ToolOutputBox` 只是一个 180pt 的滚动区, 但它的内容原先**一次性全部实例化** ——
#    bash 输出五千行 = 先建五千个视图再截断。而 `Text(整段)` 本身是**平方级**的:
#    `render_probe.py` 实测 139 行 199ms / 561 行 4.2s / 3341 行 **36s**。
#    ⚠️ 工具输出**上游没有任何截断**(bash / read 整文件都照单全收) ⇒ 这是常态, 不是极端场景。
#    ⚠️ 编译得过、数值不变、断言也不会红 ⇒ 只能扫源码事实。
if ! has_code mangox/Views/Chat/ToolCallCardView.swift 'LazyVStack\(alignment: \.leading, spacing: 4\)'; then
    echo "FAIL - 工具输出区不是惰性的 (ToolOutputBox 内容必须是 LazyVStack, spacing 4)" >&2
    echo "       一次性实例化 ⇒ 五千行输出会先建五千个视图再截断" >&2
    exit 1
fi
if has_code mangox/Views/Chat/ToolCallCardView.swift 'Text\(d\.value\)'; then
    echo "FAIL - 工具输出又是整段一个 Text 了 (平方级: 3341 行实测 36 秒)" >&2
    exit 1
fi
if [ "$(count_code mangox/Views/Chat/ToolCallCardView.swift 'SplitLineText\(text: d\.value')" -lt 2 ]; then
    echo "FAIL - 工具输出的值没走 SplitLineText (键值对与纯正文两条路都要接)" >&2
    exit 1
fi
if has_code mangox/Views/Chat/ThinkingCardView.swift 'Text\(text\)'; then
    echo "FAIL - 思考卡正文又是整段一个 Text 了 (高强度思考时几万字, 平方级)" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ThinkingCardView.swift 'SplitLineText\(text: text'; then
    echo "FAIL - 思考卡正文没接 SplitLineText" >&2
    exit 1
fi

# ③n6 长代码块必须**限高内滚 + 可展开全文** (2026-11-04 boss 拍板 320pt)。
#    ⚠️ 限高门槛与"逐行渲染"门槛**必须是同一个数**: 分家就会出现
#    "按行渲染了但还能无限长"或"限高了却整块一个 Text"这两种错配档。
if ! has_code mangox/Theme/CodexTheme.swift 'static let codeBlockMaxHeight'; then
    echo "FAIL - 长代码块限高常量不见了 (2026-11-04 boss 拍板 320pt; 数值由 T-SPLIT 断言)" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/Markdown/CodeBlockView.swift 'frame\(maxHeight: Tune\.codeBlockMaxHeight\)'; then
    echo "FAIL - 长代码块没有限高内滚 (800 行代码会把整屏铺满)" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/Markdown/CodeBlockView.swift 'lineCount > Tune\.codeBlockSplitLines'; then
    echo "FAIL - 限高门槛与逐行渲染门槛分家了 (必须都取 Tune.codeBlockSplitLines)" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/Markdown/CodeBlockView.swift 'expandedFull'; then
    echo "FAIL - 长代码块没有「展开全文」出口 (限高就成了截断)" >&2
    exit 1
fi

# ③n7 长文本切行**只许走 `SplitLines`** (2026-11-04 评审 C2/C4/C5)。
#    四处各写一份 `split(...)`/`components(...)` 的症状不是错, 是**慢性分家**:
#    空行保不保、`\r` 剥不剥、门槛怎么算, 各自改各自的 —— 而界面上只会"少几行字"。
if has_code mangox/Views/Chat/ChatView.swift 'components\(separatedBy: "\\n"\)' \
   || has_code mangox/Views/Chat/ToolCallCardView.swift 'components\(separatedBy: "\\n"\)' \
   || has_code mangox/Views/Chat/ThinkingCardView.swift 'components\(separatedBy: "\\n"\)' \
   || has_code mangox/Views/Chat/UserMessageFold.swift 'components\(separatedBy: "\\n"\)' \
   || has_code mangox/Views/Trajectory/TrajectoryView.swift 'components\(separatedBy: "\\n"\)'; then
    echo "FAIL - 又有渲染路径用 components(separatedBy: \"\\n\") 切行了 (逐行分配 String)" >&2
    echo "       长文本切行统一走 SplitLines.rows (返回 [Substring], 不复制字符)" >&2
    echo "       ⚠️ 只扫渲染面: MarkdownParser 的切分是**解析**(要 [String], 且带缓存), 不算。" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/UserMessageFold.swift 'maxSplits: collapsedLineLimit'; then
    echo "FAIL - 折叠预览又把全文切开了 (为了显示 6 行先分配 3000 个 String)" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ToolCallCardView.swift 'LazyVStack\(alignment: \.leading, spacing: 0\)'; then
    echo "FAIL - diff 预览不是惰性的 (整文件重写上万行会全部实例化)" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatView.swift 'SplitLines\.rows\(s\)'; then
    echo "FAIL - 用户消息展开态没走 SplitLines.rows (逐行复制字符)" >&2
    exit 1
fi

# ③n8 三处「缓存」必须是**真 LRU**, 图片必须分**两条通路** (2026-11-04, D 批)。
#     FIFO 冒充 LRU 的症状是**静默**的: 有上限、有逐出、`count` 永远 ≤ 容量, 而"每拍都在用"
#     的那一条照样按**插入顺序**被挤掉 ⇒ 反复逐出、反复重算, 缓存等于没起作用。
#     三处各写一份同款循环 (`MarkdownParser` / `CodeHighlighter` ×2) ⇒ 收进 `LRUCache`,
#     并且**不许再长出第二份** —— 判据只认"命中要提键", 那正是 FIFO 与 LRU 的唯一差别。
if [ "$(count_code mangox/Views/Chat/Markdown/LRUCache.swift 'order\.append\(key\)')" -lt 1 ]; then
    echo "FAIL - LRUCache 里没有「命中提键」(order.append) —— 那它还是 FIFO" >&2
    echo "       命中不提键 ⇒ 每拍在用的那条按插入顺序被逐出 ⇒ 历史块反复重解析, 而一切看起来正常" >&2
    exit 1
fi
for f in mangox/Views/Chat/Markdown/MarkdownParser.swift \
         mangox/Views/Chat/Markdown/CodeHighlighter.swift; do
    if [ "$(count_code "$f" 'order\.append\(')" -ne 0 ]; then
        echo "FAIL - $f 又手写了一份「append + 满了摘队首」的缓存 (那必然是 FIFO)" >&2
        echo "       统一走 LRUCache (命中提键 + 内部加锁); 语义由 T-CACHE 钉住" >&2
        exit 1
    fi
    if [ "$(count_code "$f" 'cacheLimit')" -ne 0 ]; then
        echo "FAIL - $f 又有自己的 cacheLimit (容量只许住在 LRUCache)" >&2
        exit 1
    fi
    if [ "$(count_code "$f" '\.value\(for:')" -lt 1 ]; then
        echo "FAIL - $f 的缓存不再被查 (只写不读 = 每次照样重算)" >&2
        exit 1
    fi
done
if [ "$(count_code mangox/Views/Chat/Markdown/CodeHighlighter.swift 'LRUCache<')" -lt 2 ]; then
    echo "FAIL - 高亮的两份缓存 (整块 / 逐行) 没有各自独立 — 混一个字典要擦类型, 也会互相顶掉" >&2
    exit 1
fi
# 图片: 缩略尺寸展示**必须**走降采样那条; 原图那条留给"要原图像素"的地方 (正文图/大图 sheet)。
# ⚠️ 反过来同样要守: 只留 `cachedThumbnail` 而无 `cachedImage` ⇒ 说明行 `宽×高` 会开始说谎。
if [ "$(count_code mangox/Views/Chat/ChatView.swift 'cachedThumbnail\(atPath')" -lt 1 ] \
   || [ "$(count_code mangox/Views/Chat/ToolOutputImages.swift 'cachedThumbnail\(atPath')" -lt 1 ]; then
    echo "FAIL - 缩略槽位又直接拿原图了 (88pt 的坑位塞全尺寸位图, 每次重绘都重采样)" >&2
    echo "       缩略一律走 ImagePipeline.cachedThumbnail(atPath:maxPixels:)" >&2
    exit 1
fi
if [ "$(count_code mangox/Views/Chat/Markdown/MarkdownImageView.swift 'cachedImage\(atPath')" -lt 1 ]; then
    echo "FAIL - 正文图不再取原图 (naturalCap 按原图像素定宽, 说明行读的也是 pixelsWide)" >&2
    exit 1
fi
# 分享出图: 提前拒必须在**排版之前**。顺序反了就等于没做 (排版已经跑完才判"太长")。
early=$(awk '/certainlyTooLong\(trimmed\)/ { print NR; exit }' mangox/Views/Chat/MessageImageShare.swift)
host=$(awk '/NSHostingView\(rootView/ { print NR; exit }' mangox/Views/Chat/MessageImageShare.swift)
if [ -z "$early" ] || [ -z "$host" ] || [ "$early" -ge "$host" ]; then
    echo "FAIL - 分享出图的「提前拒」不在排版之前 (early=$early host=$host)" >&2
    echo "       超长正文在排版那一步是**秒级**的, 排完再说太长 = 用户干等" >&2
    echo "       ⚠️ 判据是下界 (certainlyTooLong), 不是预估 —— 预估会误拒" >&2
    exit 1
fi
# 工具栏提示语: **不许拿已翻译的标题去比中文**。英文环境下 `actionTitle` 是 `Review`,
# 比 `== "去审核"` 永远为假 ⇒ 提示静默变空 (2026-11-04 评审发现)。
if has_code mangox/Views/Chat/ChatBottomBar.swift 'actionTitle =='; then
    echo "FAIL - ChatBottomBar 又在拿已翻译的标题比中文字面量了 (英文环境下提示静默消失)" >&2
    echo "       提示语要跟着**动作**传 (actionHelp:), 不能从标题反推" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/ChatBottomBar.swift '\.help\(actionHelp'; then
    echo "FAIL - 通知横幅的按钮又没有提示语了" >&2
    exit 1
fi
# 时间格式器: 每次 body 重算 `DateFormatter()` 是毫秒级的 (**建实例**贵, 改 dateFormat 不贵)。
# ⚠️ 这里只守接线 —— 开销本身量不出来 (冒烟里没有"每秒重算 60 次"的场景)。
if ! has_code mangox/Views/Chat/ChatView.swift 'static let hmFormatter'; then
    echo "FAIL - 侧问横幅的时间格式器又变成每次现建 (DateFormatter() 要读 locale/日历/时区)" >&2
    exit 1
fi

# ③n9 换行判据**只许有一份** (2026-11-04 残留补齐)。
#     `"\r\n"` 在 Swift 里是**一个 `Character`** ⇒ `== "\n"` 认不出 CRLF。代码块那条路曾经
#     自己写了一份 `$1 == "\n"`: CRLF 代码块被当成 **1 行** ⇒ 既不逐行也不限高
#     (一个 `Text` 承载整段, 平方级), 而正文明明画了 n 行 —— 零信号。
#     C 批修了四个渲染面, 漏了代码块与轨迹面这两处; 这条门就是那道缝。
if [ "$(count_code mangox/Views/Chat/Markdown/CodeHighlighter.swift '== "\\n"')" -ne 0 ]; then
    echo "FAIL - CodeHighlighter 又自己比对 \"\\n\" 了 (CRLF 是一个 Character, 认不出)" >&2
    echo "       换行只认 SplitLines.isBreak（LF / CRLF, 不认孤立 \\r）" >&2
    exit 1
fi
if ! has_code mangox/Views/Chat/Markdown/CodeBlockView.swift 'SplitLines\.count'; then
    echo "FAIL - 代码块的行数又自己数了 (CRLF 代码块会被当成 1 行 ⇒ 不限高也不逐行)" >&2
    echo "       行数取 SplitLines.count, 与 CodeHighlighter.splitLines 同源" >&2
    exit 1
fi
if ! has_code mangox/Views/Trajectory/TrajectoryView.swift 'SplitLines\.rows'; then
    echo "FAIL - 轨迹面又用 components(separatedBy:) 切行 (逐行分配 String + 行尾留 \\r)" >&2
    exit 1
fi

# ③n10 计划卡的两个按钮**还没接引擎** —— 禁用 + 明说 (2026-11-04 boss 拍板)。
#     ⚠️ 这是**过渡态**的门: 哪天真接上了它会红, 那时把这条门连同「未接入」文案一起删掉。
#        留一条永远绿的门, 下一个人就会以为它还在守着什么。
if has_code mangox/Views/Chat/PlanQuestionCardView.swift 'Button\("确认计划"\) \{\}'; then
    if [ "$(count_code mangox/Views/Chat/PlanQuestionCardView.swift '\.disabled\(true\)')" -lt 2 ]; then
        echo "FAIL - 计划卡有按钮是空动作却**没禁用** (点了没反应的按钮 = 无声死胡同)" >&2
        exit 1
    fi
    if ! has_code mangox/Views/Chat/PlanQuestionCardView.swift '还没接上引擎'; then
        echo "FAIL - 按钮禁用了却没说原因 (禁用态必须自带「还差什么」)" >&2
        exit 1
    fi
else
    echo "FAIL - 计划卡已经接上动作 —— 请删掉 ③n10 这条过渡门和「未接入」文案" >&2
    exit 1
fi

# ③n11 自禁的那个 bundle 必须与 App 自己的 `PRODUCT_BUNDLE_IDENTIFIER` 同源。
#     ⚠️ 硬编码一个字符串挡的是"操作自己"; 改 App 标识之后它**静默失效** ——
#        名单里那条从此指向一个不存在的 App, 而设置页照样能勾。
APP_BUNDLE_ID="$(awk -F'= ' '/PRODUCT_BUNDLE_IDENTIFIER = / { gsub(/[ ;]/,"",$2); print $2; exit }' mangox.xcodeproj/project.pbxproj)"
if [ -z "$APP_BUNDLE_ID" ]; then
    echo "FAIL - 读不到 PRODUCT_BUNDLE_IDENTIFIER (③n11 无法判定)" >&2
    exit 1
fi
if ! has_code mangox/Models/ComputerRedline.swift "\"$APP_BUNDLE_ID\""; then
    echo "FAIL - ComputerRedline.actBannedBundles 里没有 \"$APP_BUNDLE_ID\" (MangoX 自己能点掉自己的确认卡)" >&2
    echo "       操作自己 = 自我提权: 确认卡、作用域、审批档全在它自己手里" >&2
    exit 1
fi

# ③n12 `open` 这个动作的三条源码事实 —— 全是"写错了照样编译过、只在真机上静默变味"的。
#   ① 它必须发 `AXOpen`, 不是 `AXPress`: 两个动作后果不同(打开文件 vs 按一下), 混了不会报错,
#      只会让审批卡上写的"打开"变成假的。
#   ② `AXOpen` **没有 `kAXOpenAction` 常量**(苹果的 `AXActionConstants.h` 里没有, 实测编译不过),
#      只能写字符串 —— 所以这里钉的就是那个字符串。
#   ③ `ComputerServer` 的 `.open` 那一支**不许** `guard err == .success`: 实测 AXOpen 报 -25205
#      而界面确实动了(三次复现) ⇒ 照别的动作判会把成功回成失败, 模型重试 ⇒ 同一天跳两次。
OPEN_FUNC_LINE="$(awk '/static func open\(/ { print NR; exit }' mangox-compute/AXAdapter.swift)"
if [ -z "$OPEN_FUNC_LINE" ]; then
    echo "FAIL - AXAdapter 里找不到 open() (③n12 无法判定)" >&2
    exit 1
fi
# ⚠️ 按**边界**切块, 不按"往后数 N 行": 数行数会滑进隔壁函数/分支 —— 第一版就是
#    窗口 22 行, 结果把下一个 `case .setValue` 的 `guard err == .success` 算进了 `.open`,
#    门当场红在自己人身上(那次红是**门写错了**, 不是代码错了)。
# ⚠️ 切块**先剥注释**: `.open` 那一段的注释里原样写着那行 guard 的拼法(说的就是"不许这么写"),
#    不剥注释的话门会抓到自己的说明文字 —— 门判的是代码, 不是注释。
open_func_body() {
    awk -v s="$OPEN_FUNC_LINE" 'NR < s { next } /^[ \t]*\/\// { next }
        NR > s && /^    \}$/ { print; exit } { print }' mangox-compute/AXAdapter.swift
}
open_case_block() {
    awk -v s="$OPEN_CASE_LINE" 'NR < s { next } /^[ \t]*\/\// { next }
        NR > s && /^            case \./ { exit } { print }' mangox-compute/ComputerServer.swift
}
if ! open_func_body | grep -cF '"AXOpen" as CFString' >/dev/null; then
    echo "FAIL - AXAdapter.open 没有发 AXOpen (换了动作就是换了后果, 而卡片上照样写着「打开」)" >&2
    exit 1
fi
if open_func_body | grep -cF 'kAXPressAction' >/dev/null; then
    echo "FAIL - AXAdapter.open 里出现了 kAXPressAction —— open 不许退化成「按」" >&2
    exit 1
fi
OPEN_CASE_LINE="$(awk '/case \.open:/ { print NR; exit }' mangox-compute/ComputerServer.swift)"
if [ -z "$OPEN_CASE_LINE" ]; then
    echo "FAIL - ComputerServer 里找不到 case .open (③n12 无法判定)" >&2
    exit 1
fi
if ! open_case_block | grep -cF 'ComputerOpenVerdict.classify' >/dev/null; then
    echo "FAIL - ComputerServer 的 .open 分支没走 ComputerOpenVerdict (AXOpen 的返回码两个方向都不可信)" >&2
    exit 1
fi
if open_case_block | grep -cE 'guard err == \.success' >/dev/null; then
    echo "FAIL - .open 分支里出现了 guard err == .success —— 实测 AXOpen 报失败却生效, 这样会把成功回成失败" >&2
    exit 1
fi

# ③n13 三把钥匙里**只有两把申请得动** —— 全是"写错了照样编译过、只在真机上静默变味"的。
#   ① 屏幕录制的「申请」必须真的调 `CGRequestScreenCaptureAccess()`: 只 preflight 的话 App
#      永远不进系统设置那一页, 用户点「前往系统设置」看到的是"无项目"(2026-11-04 实测)。
#   ② 设置页**不许**再出现 `CGRequestListenEventAccess`: 辅助功能一给, 它恒 true ⇒ 调它不弹窗、
#      不写 TCC、列表里仍无条目, 挂在开关上只是让用户以为"申请过了"。那条路 2026-11-04 拆掉。
if ! has_code mangox/Models/ComputerPermission.swift 'CGRequestScreenCaptureAccess\(\)'; then
    echo "FAIL - ComputerPermission.request 没调 CGRequestScreenCaptureAccess (只 preflight 的话 App 永远不进那一页)" >&2
    exit 1
fi
if has_code mangox/Models/ComputerPermission.swift 'CGRequestListenEventAccess'; then
    echo "FAIL - ComputerPermission 里出现了 CGRequestListenEventAccess —— 这项在真机上恒真, 申请是空转" >&2
    exit 1
fi
if has_code mangox/Views/Settings/SettingsView.swift 'CGRequestListenEventAccess'; then
    echo "FAIL - 设置页又在申请输入监控了 (辅助功能涵盖它; 那句不弹窗也不登记, 只让人以为申请过)" >&2
    exit 1
fi

# ③n14 `confirm` 这一档(批 2k) —— 三条"写错了照样编译过、只在真机上静默变味"的事实。
#   ① 它必须发 `AXConfirm`: 实测(2026-11-04, 日历「创建快速日程」)同一个文本框上 `AXPress`
#      返回 0 却什么都不发生, 只有 `AXConfirm` 能把文本落库 ⇒ 换成 press 不会报错, 只会让
#      审批卡上写的「确认」变成假的。
#   ② `ComputerServer` 的 `.confirm` 分支必须真调 `AXAdapter.confirm`(而不是顺手用 press)。
#   ③ 判据里**角色白名单必须排在动作之前**: 一个"确认"落在按钮上, 实际发生的就是"按下那个
#      按钮", 而卡上写的是「确认 #12」—— 审批人签的字不是他以为的那件事。
CONFIRM_FUNC_LINE="$(awk '/static func confirm\(/ { print NR; exit }' mangox-compute/AXAdapter.swift)"
if [ -z "$CONFIRM_FUNC_LINE" ]; then
    echo "FAIL - AXAdapter 里找不到 confirm() (③n14 无法判定)" >&2
    exit 1
fi
confirm_func_body() {
    awk -v s="$CONFIRM_FUNC_LINE" 'NR < s { next } /^[ \t]*\/\// { next }
        NR > s && /^    \}$/ { print; exit } { print }' mangox-compute/AXAdapter.swift
}
if ! confirm_func_body | grep -cF 'kAXConfirmAction' >/dev/null; then
    echo "FAIL - AXAdapter.confirm 没发 kAXConfirmAction (换成 press 的话卡上写「确认」、实际只是聚焦)" >&2
    exit 1
fi
if confirm_func_body | grep -cF 'kAXPressAction' >/dev/null; then
    echo "FAIL - AXAdapter.confirm 里出现了 kAXPressAction —— confirm 不许退化成「按」" >&2
    exit 1
fi
CONFIRM_CASE_LINE="$(awk '/case \.confirm:/ { print NR; exit }' mangox-compute/ComputerServer.swift)"
if [ -z "$CONFIRM_CASE_LINE" ]; then
    echo "FAIL - ComputerServer 里找不到 case .confirm (③n14 无法判定)" >&2
    exit 1
fi
confirm_case_block() {
    awk -v s="$CONFIRM_CASE_LINE" 'NR < s { next } /^[ \t]*\/\// { next }
        NR > s && /^            case \./ { exit } { print }' mangox-compute/ComputerServer.swift
}
if ! confirm_case_block | grep -cF 'AXAdapter.confirm' >/dev/null; then
    echo "FAIL - ComputerServer 的 .confirm 分支没调 AXAdapter.confirm" >&2
    exit 1
fi
GUARD_CONFIRM_LINE="$(awk '/^        case \.confirm:$/ { print NR; exit }' mangox/Models/ComputerAct.swift)"
if [ -z "$GUARD_CONFIRM_LINE" ]; then
    echo "FAIL - ComputerActGuard 里找不到 case .confirm (③n14 无法判定)" >&2
    exit 1
fi
guard_confirm_block() {
    awk -v s="$GUARD_CONFIRM_LINE" 'NR < s { next } /^[ \t]*\/\// { next }
        NR > s && /^        case \./ { exit } { print }' mangox/Models/ComputerAct.swift
}
CONFIRM_ROLE_LINE="$(guard_confirm_block | awk '/isConfirmableRole\(target\.role\)/ { print NR; exit }')"
CONFIRM_ACT_LINE="$(guard_confirm_block | awk '/contains\("AXConfirm"\)/ { print NR; exit }')"
if [ -z "$CONFIRM_ROLE_LINE" ] || [ -z "$CONFIRM_ACT_LINE" ]; then
    echo "FAIL - confirm 的判据缺一条 (角色白名单 / AXConfirm 动作表), ③n14 无法判定" >&2
    exit 1
fi
if [ "$CONFIRM_ROLE_LINE" -ge "$CONFIRM_ACT_LINE" ]; then
    echo "FAIL - confirm 先判了动作表再判角色 —— 顺序反了: 按钮上的 AXConfirm 会被放行" >&2
    echo "       那一手实际发生的是「按下那个按钮」, 而卡上写的是「确认 #12」" >&2
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

# ③r 坐标点击(批 3a) **不许变成第二套寻址**。
#    三条恒拒(付款 / 永久删除 / 存盘)判的都是**元素**, 而坐标本身没有元素 ⇒ 若"按坐标直接点",
#    这三条一条都跑不了, 等于给"模型替我点确认付款"开了一条绕过全部判据的路。
#    修法是**翻译**: 坐标 → 元素(`AXUIElementCopyElementAtPosition`) → 快照里认回编号 → 走老路。
#    ⚠️ 这三处任何一处掉了, 现象都是"坐标点击能用", 零红灯 —— 只能扫源码事实。
if ! has_code mangox-compute/AXAdapter.swift 'AXUIElementCopyElementAtPosition'; then
    echo "FAIL - AXAdapter 不再把坐标翻译成元素 (坐标那条路就只剩盲点了)" >&2
    echo "       坐标必须有元素可落脚, 否则三条恒拒判不起来 (它们判的是元素不是点)" >&2
    exit 1
fi
# ⚠️ 2026-10-30 实测补的一条: 用 `AXUIElementCreateApplication(pid)` 当起点的话, 问的其实是
#    "这个 App 在 (x,y) 上占的是哪块" —— 屏幕外 (-400,-400) / (9999,9999) 也**照样回一个元素**,
#    于是"没有元素 ⇒ 直接拒"那条永远走不到, 回执还会凭空说"(9999,9999) 上有一个元素"。
#    起点必须问系统(`AXUIElementCreateSystemWide`)。
if ! has_code mangox-compute/AXAdapter.swift 'AXUIElementCreateSystemWide'; then
    echo "FAIL - 坐标命中不再问系统全域 (盲点那条判据会静默失效, 回执开始编造事实)" >&2
    exit 1
fi
if has_code mangox-compute/AXAdapter.swift 'AXUIElementCopyElementAtPosition\(AXUIElementCreateApplication'; then
    echo "FAIL - element(at:) 又拿 App 元素当起点了 (屏幕外也会回元素 ⇒ 盲点判据永远不触发)" >&2
    exit 1
fi
if ! has_code mangox-compute/ComputerServer.swift 'AXAdapter\.processID\(of:'; then
    echo "FAIL - 坐标分支不再核对『命中的元素属于哪个进程』(会替名单外的 App 点)" >&2
    exit 1
fi
for NEEDLE in 'ComputerPointRule\.refusal' 'rowIndex\(for:' 'ComputerPointRule\.missKind'; do
    if ! has_code mangox-compute/ComputerServer.swift "$NEEDLE"; then
        echo "FAIL - ComputerServer 的坐标分支少了 $NEEDLE" >&2
        echo "       ① 参数互斥(编号/坐标只能给一个) ② 翻译出的元素必须落回快照里真实的编号" >&2
        exit 1
    fi
done

# ③u 诊断脚本**不许发全局输入 / 不许走顶栏菜单** (2026-11-04 boss 定，原话：
#     「既然都用了ax方案，就应该是在应用的ui上进行操作，而不是在顶栏菜单」)。
#     这不是风格问题, 是**不可逆损失**:
#       · 顶栏菜单属于"此刻前台的那个 App" —— 要按它就得先把目标 App 弄到前台。一旦前台
#         不是它(人正停在 WorkBuddy 里敲字), 那一下"删除"落到谁身上说不准, 而删除 / 移到
#         废纸篓**没有撤销**。实测就是这么翻的车: 本来在测日历, 删的却不是日历里的东西。
#       · `CGEvent` 发的 ⌘⌫ / Esc / 鼠标点击更糟: 它发给**屏幕最上层**, 与我校验过的那棵
#         AX 树毫无关系 —— "我读过日历"根本不蕴含"此刻前台是日历"。
#     ✅ 正确形态: 一律 `AXUIElementPerformAction` 打在**目标元素**上(元素级、不用前台);
#        做不到就**如实失败**(退码 3 + 一句"这个 App 只能靠人删"), 不许退到全局输入。
#     ⚠️ 只能扫源码事实: 这几行编译得过、跑起来"还能用"、零红灯 —— 唯一症状是某天删错东西。
#     ⚠️ `AXMenuBar` 本身**不在禁列**: 清理器要靠它把"顶栏里的菜单项"**排除掉**(`inMenuBar`),
#        禁的是 `AXMenuBarItem` 这个"去顶栏取菜单"的入口。
#     ⚠️ 剥注释用 `/^[ \t]*(\/\/|#)/`（.swift 与 .py 两种注释都认）—— 文件头讲这条红线的那句
#        `**没有** CGEvent` 不能把它自己判红。
#     ⚠️ 报的位置用 `FNR`（**原文件行号**）：剥注释那一版是把行删掉的，拿它的 `grep -n`
#        报出来的行号会指到别处去（实测：真第 224 行被报成 165 行）—— 判据自己撒谎比不报更坏。
for DIAG_SRC in scripts/diag/*.swift scripts/diag/*.py; do
    [ -f "$DIAG_SRC" ] || continue
    if awk '/^[ \t]*(\/\/|#)/ { next }
            /CGEvent|\.post\(tap:|AXMenuBarItem|osascript|cliclick/ {
                printf "%s:%d: %s\n", FILENAME, FNR, $0 > "/dev/stderr"; bad = 1
            }
            END { exit bad ? 0 : 1 }' "$DIAG_SRC"; then
        echo "FAIL - $DIAG_SRC 里有全局输入 / 顶栏菜单的用法 (见上, 行号是原文件的)" >&2
        echo "       那一下按的是『此刻前台那个 App』, 不是我校验过的那个 ⇒ 可能删错东西且无撤销" >&2
        echo "       改成 AXUIElementPerformAction 打在目标元素上; 做不到就如实失败, 别退到全局输入" >&2
        exit 1
    fi
done
# 另一半同样要盯: 红线**真的落到了执行点**上 —— 清理器必须还在排顶栏(否则"禁用法"只是把
# 菜单项当普通项按下去, 一样依赖前台)。判据 = `inMenuBar` 这个过滤函数还在、且被 `usableItems` 用。
if ! has_code scripts/diag/scenario_cleanup.swift 'role\(c\) == "AXMenuBar"'; then
    echo "FAIL - scenario_cleanup 不再识别顶栏菜单 (那它就会把顶栏菜单项当普通菜单项按下去)" >&2
    exit 1
fi
if ! has_code scripts/diag/scenario_cleanup.swift '!inMenuBar\(\$0\)'; then
    echo "FAIL - scenario_cleanup 的 usableItems 不再排掉顶栏菜单项 (依赖前台的那条路又回来了)" >&2
    exit 1
fi

# ③v 电脑操作助手: **一个会话一份, 且会话收它就得收** (2026-11-12)。
#
#   现场(boss 报「一个会话 computer_read 过微信之后, 另一个会话就读不了了」):
#     每开一个会话 spawn 一个 `mangox-compute`(各握一条 socket、各执一份「辅助功能 + 屏幕录制」),
#     而 `shutdown()` 只 terminate pi, **从不 terminate helper** ⇒ 两个 helper 同时在跑
#     (其中一个已跑 1 小时 33 分), `~/.mangox/compute-*.sock` 越攒越多
#     (helper 的 SIGTERM 只 exit(0), 不 unlink)。
#
#   ⚠️ 中途试过"全局共享一份", **不行**(2026-11-12 当天否掉): `Scope` 里 `takeover` 取自
#      **每会话**的 `approvalMode` ⇒ 两个会话档位不同就互相把对方的 helper 重启掉, 而 socket
#      路径每次 spawn 换 UUID ⇒ 先起的那个会话永远连不上(`ECONNREFUSED`)。
#      boss 拍板: 每会话独立, 2~3 份可接受。⇒ 下面这几条**不许**再推回"共享一份"。
#
#   ⚠️ 这一段只能扫源码事实: T-HOST 测的是 `ComputerHost` 自己的行为,
#      而"transport 有没有在会话结束时收掉它"是**调用方**的错 —— 实测造反例
#      (把 `shutdown()` 里那句 `stop()` 删掉)时, **T-HOST 一条都不红**。
if has_code mangox/Agent/ComputerHost.swift 'static let shared = ComputerHost\(\)'; then
    echo "FAIL - ComputerHost 又变回全局单例 (Scope.takeover 每会话不同 ⇒ 两个会话互相踢, 后起的那个把先起的连不上)" >&2
    echo "       boss 2026-11-12 拍板: 每会话一份, 隔离优先" >&2
    exit 1
fi
if ! has_code mangox/Agent/PiRpcTransport.swift 'private let computerHost = ComputerHost\(\)'; then
    echo "FAIL - transport 不再各自持一份助手 (每会话一份是拍板结果, 见 ComputerHost 上那段)" >&2
    exit 1
fi
# 会话结束必须**真的收**: 只 terminate pi 不收助手, 就是那个跑了 1 小时 33 分的进程。
if ! awk '/func shutdown\(\)/,/^    }/' mangox/Agent/PiRpcTransport.swift | grep -c 'computerHost\.stop\(\)' >/dev/null; then
    echo "FAIL - shutdown() 不再收助手 (只 terminate pi ⇒ helper 留在后台, 每开一个会话多一个)" >&2
    exit 1
fi
if ! has_code mangox/Agent/PiRpcTransport.swift 'computerHost\.stop\(\)'; then
    echo "FAIL - transport 里没有真的 stop() (助手永远不会被收)" >&2
    exit 1
fi
# 收的时候要把 socket 文件也删掉: helper 自己只 exit(0), **不 unlink**。
if ! has_code mangox/Agent/ComputerHost.swift 'unlink\(path\)'; then
    echo "FAIL - 收助手时不再 unlink socket 文件 (helper 的 SIGTERM 只 exit, 不清就在 ~/.mangox 攒死 socket)" >&2
    exit 1
fi
# ⚠️ `unlink` 用的必须是**清字段之前**存下来的那份: 先 `socketPath = nil` 再 unlink
#    永远是空操作 —— 编译过、跑起来"看着有", 而 socket 一个都没清(实测踩过)。
if ! has_code mangox/Agent/ComputerHost.swift 'let dying = socketPath'; then
    echo "FAIL - unlink 又拿 socketPath 直接用了 (先清字段后读 = 那句 unlink 永不执行)" >&2
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

# ⚠️ `-swift-version 5` 是**钉住的**(2026-10-30 review): 不写它, 语言模式取的是工具链默认值 ——
#    Xcode 大版本一跳(或 CI 镜像一换), 同一份源码会从 Swift 5 模式变成别的默认,
#    于是"本地过、CI 挂", 而挂的原因和改的代码毫无关系。本项目按 Swift 5 模式开发, 写死它。
#
# ⚠️ **编译告警必须当场红**: 项目一直讲"0 warning", 但原来只是**让人去 grep 日志** ——
#    CI 上没人看日志 ⇒ 新告警静默通过。实证: `subrole` 那次读到却忘了传进去, 唯一信号就是
#    一条 `never used` warning, 而语义上它是**静默失效**(值恒空串, 整条遮蔽判据不生效)。
BUILD_LOG="$OUT/swiftc.log"
if ! DEVELOPER_DIR="$DEV" xcrun swiftc \
        -sdk "$SDK" \
        -target "$ARCH-apple-macos14.0" \
        -swift-version 5 \
        -D DEBUG \
        -D SMOKE \
        -o "$OUT/smoke" \
        $SMOKE_SRC \
        $SRC 2> "$BUILD_LOG"; then
    cat "$BUILD_LOG" >&2
    echo "FAIL - 全量编译失败 (见上)" >&2
    exit 1
fi
# 只认**带文件位置**的诊断行: swiftc 会把同一条告警再打一遍(汇总行), 直接 `grep -c 'warning:'`
# 会把 1 条数成 2 条 —— 计数一旦撒谎, 以后就没人信这个数了。
WARN_PATTERN='\.swift:[0-9]+:[0-9]+: warning:'
WARNINGS="$(grep -cE "$WARN_PATTERN" "$BUILD_LOG" 2>/dev/null || true)"
[ -n "$WARNINGS" ] || WARNINGS=0
if [ "$WARNINGS" != "0" ]; then
    grep -E "$WARN_PATTERN" "$BUILD_LOG" >&2
    echo "FAIL - swiftc 报了 $WARNINGS 条告警 (项目要求 0 warning; 告警常常是静默失效的唯一信号)" >&2
    exit 1
fi

"$OUT/smoke"
