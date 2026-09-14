#!/usr/bin/env bash
# 从 icon_work/AppIcon.png (1024 源图) 生成全 10 档 icns 到 mangox/Resources/AppIcon.icns。
# 为什么不用 asset catalog appiconset: 本机 actool/Xcode 16.2 只给 icns 塞 ≤256 档
# (Dock 放大即糊), 单尺寸 universal 格式更是静默不产出 (2026-09-14 实证, 见记忆 51)。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="icon_work/AppIcon.png"
OUT="mangox/Resources/AppIcon.icns"
TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"
[ -f "$SRC" ] || { echo "missing $SRC (1024x1024)" >&2; exit 1; }

gen() { sips -z "$1" "$1" "$SRC" --out "$TMP/$2" >/dev/null; }
gen 16 icon_16x16.png        ; gen 32 icon_16x16@2x.png
gen 32 icon_32x32.png        ; gen 64 icon_32x32@2x.png
gen 128 icon_128x128.png     ; gen 256 icon_128x128@2x.png
gen 256 icon_256x256.png     ; gen 512 icon_256x256@2x.png
gen 512 icon_512x512.png     ; gen 1024 icon_512x512@2x.png

iconutil -c icns "$TMP" -o "$OUT"
echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"