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
