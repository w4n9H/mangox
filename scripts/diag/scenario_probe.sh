#!/bin/bash
# 场景回归执行器 —— 编真 helper + 编测试清理器, 然后跑 `scenario_probe.py`。
#
# 用法:
#   bash scripts/diag/scenario_probe.sh                    # 全部场景
#   bash scripts/diag/scenario_probe.sh 日历               # 只跑名字含「日历」的
#   bash scripts/diag/scenario_probe.sh --dump 备忘录      # 只读一次, 把行打出来(写判据用)
#
# ⚠️ **不进 CI**: 要真人桌面 + 真 App + 辅助功能授权, 还会改用户数据(自带清理)。
# ⚠️ helper 每次重编: 增量编译几秒, 而"拿着旧二进制测新代码"是最容易骗过自己的一种绿。
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ -n "${DEVELOPER_DIR:-}" ]]; then DEV="$DEVELOPER_DIR"
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then DEV="/Applications/Xcode.app/Contents/Developer"
else DEV="$(xcode-select -p 2>/dev/null || true)"; fi
[[ -n "$DEV" && -d "$DEV" ]] || { echo "错误: 找不到开发者目录" >&2; exit 1; }

echo "── 编 helper (mangox-compute) ──"
# ⚠️ 编译失败**必须 exit**: 旧写法是 `xcodebuild | grep … || true` + 只查文件在不在 ⇒
#    编红的那次会拿**上一次的二进制**去跑，绿得莫名其妙(同 scenario-cleanup 那条踩过的坑)。
#    判据只认 xcodebuild 自己的 `** BUILD SUCCEEDED **`，**不看 mtime** —— Xcode 增量按内容
#    哈希跳过 up-to-date，产物比源旧并不代表没编。
BUILD_LOG="$(mktemp)"
DEVELOPER_DIR="$DEV" xcodebuild -project mangox.xcodeproj -target mangox-compute \
    -configuration Debug build > "$BUILD_LOG" 2>&1 || true
grep -E "BUILD (SUCCEEDED|FAILED)|error:" "$BUILD_LOG" || true
grep -cE '^\*\* BUILD SUCCEEDED \*\*' "$BUILD_LOG" >/dev/null || {
    rm -f "$BUILD_LOG"; echo "错误: helper 编译失败（build/Debug/ 里那份是旧的，别拿它测）" >&2; exit 1; }
rm -f "$BUILD_LOG"
[[ -x build/Debug/mangox-compute ]] || { echo "错误: build/Debug/mangox-compute 不存在" >&2; exit 1; }

# 清理器编到固定路径: 辅助功能权限按二进制(cdhash)记 —— 换路径 = 每次都要重授。
BIN="$HOME/.mangox/bin/scenario-cleanup"
mkdir -p "$(dirname "$BIN")"
SDK="$(DEVELOPER_DIR="$DEV" xcrun --sdk macosx --show-sdk-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp scripts/diag/scenario_cleanup.swift "$TMP/main.swift"
echo "── 编测试清理器 (scenario-cleanup) ──"
DEVELOPER_DIR="$DEV" xcrun swiftc -O -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" \
    -swift-version 5 \
    mangox/Models/AXSnapshot.swift \
    mangox/Models/ComputerAct.swift \
    mangox/Models/ComputerRedline.swift \
    mangox-compute/AXAdapter.swift \
    "$TMP/main.swift" \
    -o "$BIN" || { echo "错误: 测试清理器编译失败（旧的二进制还留在 $BIN，别用它）" >&2; exit 1; }

# ⚠️ `-u` 不是洁癖: 输出重定向到文件时 python 默认**整块缓冲**, 一旦脚本卡死被中断,
#    文件里连"跑到哪一条"都看不到 —— 2026-11-04 就这么白等了一场，只能靠猜。
SCENARIO_HELPER="build/Debug/mangox-compute" SCENARIO_CLEANUP="$BIN" \
    python3 -u scripts/diag/scenario_probe.py "$@"
