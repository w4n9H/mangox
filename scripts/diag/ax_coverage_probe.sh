#!/bin/bash
# 量一批内置 App 的 AX 覆盖率 —— 编译**真源码**(AXAdapter + AXSnapshot + ComputerRedline +
# ComputerAct)后跑, 不是另写一遍近似实现。
#
# 用法:
#   bash scripts/diag/ax_coverage_probe.sh                       # 默认四个 App
#   bash scripts/diag/ax_coverage_probe.sh --apps com.apple.mail # 只量一个
#   bash scripts/diag/ax_coverage_probe.sh --wait 10             # 等窗口更久
#
# ⚠️ 辅助功能权限按**二进制(cdhash)**记 ⇒ 产物路径必须固定。换路径 = 权限没了,
#    症状是"上次好好的, 这次一行都读不到", 而报错只说没权限。所以固定 ~/.mangox/bin/axcov。
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ -n "${DEVELOPER_DIR:-}" ]]; then DEV="$DEVELOPER_DIR"
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then DEV="/Applications/Xcode.app/Contents/Developer"
else DEV="$(xcode-select -p 2>/dev/null || true)"; fi
[[ -n "$DEV" && -d "$DEV" ]] || { echo "错误: 找不到开发者目录" >&2; exit 1; }
SDK="$(DEVELOPER_DIR="$DEV" xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

BIN="$HOME/.mangox/bin/axcov"
mkdir -p "$(dirname "$BIN")"

# 顶层语句只能住 main.swift ⇒ 拷成 main.swift 再编(源码本身不改名, 它得能被人读到)。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp scripts/diag/ax_coverage_probe.swift "$TMP/main.swift"

DEVELOPER_DIR="$DEV" xcrun swiftc -O \
    -sdk "$SDK" -target "$ARCH-apple-macos14.0" -swift-version 5 \
    mangox/Models/AXSnapshot.swift \
    mangox/Models/ComputerAct.swift \
    mangox/Models/ComputerRedline.swift \
    mangox-compute/AXAdapter.swift \
    "$TMP/main.swift" \
    -o "$BIN"

exec "$BIN" "$@"
