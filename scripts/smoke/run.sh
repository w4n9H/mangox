#!/bin/bash
# MangoX 冒烟门禁: 编译全量源码 (排除 @main 入口) + 运行 ChatStore 语义冒烟。
# 用法: scripts/smoke/run.sh
# 通过条件: 编译零错误 && 冒烟输出 "ALL PASS" (退出码 0)。
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

SRC=$(find mangox -name "*.swift" ! -name "mangoxApp.swift" | sort)

DEVELOPER_DIR="$DEV" xcrun swiftc \
    -sdk "$SDK" \
    -target "$ARCH-apple-macos14.0" \
    -D DEBUG \
    -o "$OUT/smoke" \
    "$SMOKE_DIR/smokeMain.swift" \
    $SRC

"$OUT/smoke"
