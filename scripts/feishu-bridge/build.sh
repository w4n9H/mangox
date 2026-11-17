#!/bin/bash
# 把桥打成**一个**文件放进 App 资源目录（P19.2 S15）。
#
# 为什么要打包：SDK 的 node_modules 是 41MB，用户机器上不该出现 node_modules，也不该
# 让人为了用一个功能去 `npm install` 一次。esbuild 打出 ~1.9MB 的单文件跟着 App 走，
# 运行时只要求机器上**有 node**（而 node 本来就是这个产品的前提：pi 本身就是 node 脚本，
# `PiRpcTransport.launchSpec()` 显式用 `/opt/homebrew/bin/node` 跑它）。
#
# ⚠️ 三个非显然的坑，都实测过：
#   ① **必须 `--format=cjs`**。打成 ESM 时 axios/form-data 那批 CJS 依赖会走
#      `__require` 动态 require，跑起来第一句就 `Dynamic require of "util" is not supported`。
#      产物因此叫 `.cjs`（扩展名必须与格式一致，否则 node 按 .mjs 当 ESM 跑 ⇒ 同样的错）。
#   ② `--external:bufferutil --external:utf-8-validate`：ws 的两个**可选**原生扩展，
#      打包时会去解析它们，不排除就报 Could not resolve。
#   ③ 产物要 `--minify`：不压 5.9MB，压完 1.9MB（进 git 的体积差三倍，功能完全一样）。
#
# 用法：改完 bridge.mjs 跑一次 ./build.sh，把 mangox/Resources/feishu-bridge.cjs 一起提交。
set -euo pipefail
cd "$(dirname "$0")"

OUT="../../mangox/Resources/feishu-bridge.cjs"

./node_modules/.bin/esbuild bridge.mjs \
  --bundle --platform=node --format=cjs --target=node18 --minify \
  --external:bufferutil --external:utf-8-validate \
  --outfile="$OUT"

# 自证：产物必须能被 node 解析（"打出来了"不等于"能跑"，见 MEMORY 里那条假门）。
node --check "$OUT"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
