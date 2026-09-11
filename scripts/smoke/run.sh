#!/bin/bash
# MangoX 冒烟门禁: 编译全量源码 (排除 @main 入口) + 运行 ChatStore 语义冒烟。
# 用法: scripts/smoke/run.sh
# 通过条件: 编译零错误 && 冒烟输出 "ALL PASS" (退出码 0)。
set -euo pipefail

cd "$(dirname "$0")/../.."

SMOKE_DIR="$(pwd)/scripts/smoke"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Xcode.app 里的工具链 (shell 默认 xcrun 指向 CommandLineTools, 无 SDK 完整性)
export DEVELOPER_DIR="/Applications/Xcode.app"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SRC=$(find mangox -name "*.swift" ! -name "mangoxApp.swift" | sort)

xcrun swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    -o "$OUT/smoke" \
    "$SMOKE_DIR/smokeStubs.swift" \
    "$SMOKE_DIR/smokeMain.swift" \
    $SRC

"$OUT/smoke"
