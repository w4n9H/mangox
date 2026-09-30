#!/usr/bin/env bash
# MangoX Release 包本地安装 / 重签工具。
#
# 为什么需要它: CI (GitHub macOS runner) 没有、也不可能有你的 Apple 开发者证书,
# 所以 Release 上的 .app 是**未签名**的 (CI 用 xcodebuild 时显式 CODE_SIGNING_ALLOWED=NO)。
# 未签名的 bundle 从浏览器下载后带 com.apple.quarantine, Gatekeeper 会直接拒绝启动
# —— 表现是「无法打开, 因为无法验证开发者」, 而**不是**任何可归因的错误。
# 本脚本做的就是把这件事一次做完: 去隔离属性 → ad-hoc 签名 → 校验 → 启动。
#
# 签名为什么是 ad-hoc 就够: ad-hoc 签名不做身份认证, 只让系统认得"这个 bundle
# 被谁签过", 从而启动时不再触发 Gatekeeper 的发布者校验。它**不是**分发签名 ——
# 没有开发者身份、没有时间戳、不走公证。所以这个包适合自己和同事本机用,
# 不适合分发给陌生用户 (那需要 Apple Developer 证书 + notarization)。
#
# 用法:
#   scripts/install-from-release.sh MangoX.app                      # 就地处理并打开
#   scripts/install-from-release.sh MangoX-0.1.13-arm64.zip          # 解包后处理并打开
#   scripts/install-from-release.sh MangoX.zip -o ~/Applications     # 装到指定目录
#   scripts/install-from-release.sh MangoX.app --no-open             # 只装不启动
#   scripts/install-from-release.sh MangoX.app --no-launch-check    # 装完不验启动
#
# 通过条件: 隔离属性已清、ad-hoc 签名完成、codesign --verify --strict 通过 (退出码 0)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT=""
OUTPUT=""
DO_OPEN=1
LAUNCH_CHECK=1

usage() {
    cat <<'EOF'
用法: scripts/install-from-release.sh <MangoX.app | MangoX-*.zip> [选项]

  -o, --output DIR   安装目录 (默认: 与 .app 同级的 Applications, 不存在则创建)
      --no-open      处理完不启动
      --no-launch-check  处理完不验「起得来」, 只验签名
  -h, --help         本帮助

做了什么:
  1. zip → ditto 解包 (保执行位与符号链接; 不用 zip -r, 那会丢 Mach-O 的执行位)
  2. /usr/bin/xattr -cr 清掉全部扩展属性 (含 com.apple.quarantine)
  3. codesign --force --sign - ad-hoc 重签, 带 entitlements (当前为空 dict, 非沙箱)
  4. codesign --verify --strict 校验
  5. 检查 pi CLI / node 是否就位 (缺了 App 会显示引擎不可用横幅)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)    OUTPUT="$2"; shift 2 ;;
        --no-open)      DO_OPEN=0; shift ;;
        --no-launch-check) LAUNCH_CHECK=0; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*) echo "未知参数: $1 (--help 看用法)" >&2; exit 1 ;;
        *)  [[ -z "$INPUT" ]] || { echo "只能给一个输入" >&2; exit 1; }
            INPUT="$1"; shift ;;
    esac
done
[[ -n "$INPUT" ]] || { usage; exit 1; }
[[ -e "$INPUT" ]] || { echo "错误: 找不到 $INPUT" >&2; exit 1; }

log()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 解包 / 定址 ────────────────────────────────────────────
# zip 用 ditto 而不是 zip/unzip: ditto 保留执行位与符号链接, unzip 在跨卷时会打掉权限位,
# 症状是 App 双击没反应 (Mach-O 丢了 +x)。
step "解包"
case "$INPUT" in
    *.app)
        SRC_APP="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
        [[ -d "$SRC_APP" ]] || die "输入不是 .app 目录: $SRC_APP"
        [[ -n "$OUTPUT" ]] || OUTPUT="$(dirname "$SRC_APP")"
        mkdir -p "$OUTPUT"
        DST_APP="$OUTPUT/$(basename "$SRC_APP")"
        if [[ "$DST_APP" == "$SRC_APP" ]]; then
            log "  就地处理: $DST_APP"
        else
            rm -rf "$DST_APP"
            cp -pR "$SRC_APP" "$DST_APP"
            log "  已复制到: $DST_APP"
        fi
        ;;
    *.zip)
        [[ -n "$OUTPUT" ]] || OUTPUT="$(cd "$(dirname "$INPUT")" && pwd)/MangoX"
        mkdir -p "$OUTPUT"
        log "  解包到: $OUTPUT"
        ditto -x -k "$INPUT" "$OUTPUT" >/dev/null
        DST_APP="$(find "$OUTPUT" -maxdepth 1 -name '*.app' -type d | head -1)"
        [[ -n "$DST_APP" ]] || die "压缩包里没找到 .app"
        ;;
    *)
        die "只认 .app 或 .zip: $INPUT"
        ;;
esac
log "  bundle  : $DST_APP"

# ── 清隔离属性 ─────────────────────────────────────────────
# 用 /usr/bin/xattr 写死绝对路径: PATH 里的 xattr 可能被 pyenv shim / GNU coreutils 抢占,
# 那些实现不认 -r (Apple 的 xattr 把递归当成组合 flag 用), 一跑就 "option -r not recognized"。
# 用 -c -r 而不是 -d -r: 递归清**全部**扩展属性。浏览器下载还会打 com.apple.provenance,
# 只删 quarantine 留着 provenance, Gatekeeper 仍可能拦。
step "清扩展属性 (quarantine / provenance)"
/usr/bin/xattr -cr "$DST_APP" 2>/dev/null || true
if /usr/bin/xattr -p com.apple.quarantine "$DST_APP" >/dev/null 2>&1; then
    die "quarantine 没清掉 —— 这一步失败的话 Gatekeeper 一定会拦, 别往下走了"
fi
log "  已清 (quarantine 确认不存在)"

# ── ad-hoc 签名 ────────────────────────────────────────────
# 签名放在清属性**之后**: xattr 不影响签名有效性, 但反过来签名后再动文件属性没必要,
# 顺序固定下来, 将来加 notarize stapler 时不会出现"签完又改过 bundle"的中间态。
#
# --entitlements 必带: 当前 mangox.entitlements 是空 dict (非沙箱), 带不带都能跑,
# 但漏带的代价是将来开沙箱/钥匙串权限时**静默失效** —— 签名成功、能力没生效,
# 报错点远在运行期。本脚本在脚本旁 / 仓库内找这份文件, 找不到就明说而不是默默签。
step "ad-hoc 签名"
ENTITLEMENTS=""
for cand in "$SCRIPT_DIR/mangox.entitlements" \
            "$SCRIPT_DIR/../mangox/mangox.entitlements" \
            "$DST_APP/Contents/Resources/mangox.entitlements"; do
    if [[ -f "$cand" ]]; then ENTITLEMENTS="$cand"; break; fi
done
SIGN_ARGS=(--force --sign - --timestamp=none)
if [[ -n "$ENTITLEMENTS" ]]; then
    SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    log "  entitlements: $ENTITLEMENTS"
else
    warn "找不到 mangox.entitlements —— 按空权限签 (当前工程就是非沙箱, 等价; 但请确认"
    warn "  你拿到的确实是 release 里的那套, 不是别人改过的包)"
fi
codesign "${SIGN_ARGS[@]}" "$DST_APP" || die "签名失败"
codesign --verify --strict "$DST_APP" || die "签名校验失败 (--strict)"

EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DST_APP/Contents/Info.plist" 2>/dev/null || true)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DST_APP/Contents/Info.plist" 2>/dev/null || true)"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DST_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
log "  OK: $BUNDLE_ID $VER  (executable=$EXE_NAME, ad-hoc)"

# ── 运行时依赖 ─────────────────────────────────────────────
# App 自己按 /opt/homebrew/bin/pi → /usr/local/bin/pi → PATH 的顺序找 pi
# (PiRpcTransport.findBinary), 这里照抄那三档, 免得"依赖其实有, 脚本却报缺"。
step "运行时依赖 (pi CLI / node)"
MISSING=()
for tool in pi node; do
    FOUND=""
    for p in "/opt/homebrew/bin/$tool" "/usr/local/bin/$tool"; do
        [[ -x "$p" ]] && { FOUND="$p"; break; }
    done
    if [[ -z "$FOUND" ]] && command -v "$tool" >/dev/null 2>&1; then
        FOUND="$(command -v "$tool")"
    fi
    if [[ -n "$FOUND" ]]; then
        log "  ✓ $tool  $FOUND"
    else
        MISSING+=("$tool")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "缺: ${MISSING[*]}"
    warn "  MangoX 只是对话引擎的 GUI —— 推理靠 pi CLI (node 脚本), 没它 App 会显示"
    warn "  「引擎不可用」横幅, 不会假装在回复。装:  https://github.com/earendil-works/pi"
    warn "  App 本身仍可启动 (设置页、模型管理、知识库都不依赖 pi), 所以不阻断安装。"
fi

# ── 启动验证 ───────────────────────────────────────────────
# 签名过 ≠ 起得来: 资源错位、缺 dylib、Info.plist 的 CFBundleExecutable 被改错,
# 都不会让 codesign 报错, 只让双击没反应。所以真起一次, 看进程在不在。
if [[ "$LAUNCH_CHECK" == 1 && -n "$EXE_NAME" ]]; then
    step "启动验证 (起得来才算装好)"
    open "$DST_APP" || die "open 失败"
    UP=0
    for _ in $(seq 1 20); do
        sleep 1
        if pgrep -f "$DST_APP/Contents/MacOS/$EXE_NAME" >/dev/null 2>&1; then
            UP=1
            break
        fi
    done
    if [[ "$UP" == 1 ]]; then
        log "  OK: 进程已存活"
    else
        die "open 之后 20 秒内没看到进程 —— 包起不来。别急着发朋友, 先自己看一眼"
    fi
fi

if [[ "$DO_OPEN" == 1 && "$LAUNCH_CHECK" == 0 ]]; then
    step "启动"
    open "$DST_APP"
fi

step "完成"
log "  安装位置: $DST_APP"
if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "  ⚠ 缺 ${MISSING[*]} —— 启动前先装上 (见上)"
fi
log "  再开一次:  open \"$DST_APP\""
