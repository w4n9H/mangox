#!/usr/bin/env bash
# MangoX 资源可达性门禁: 用真 NSBundle 把每份资源按 App 自己的查法查一遍, 任一 miss 即红。
#
# 为什么需要它: 三条查法**都静默降级** —— 打包错位资源不会让 App 崩, 只会让它换个样子跑。
#
#   ModelCatalog → url(forResource:"model-catalog", withExtension:"json")
#                  miss → 退回裸默认模型表 (设置页列不出线上模型)
#   CodexFonts   → url(forResource:"JetBrainsMono-Regular", withExtension:"ttf")
#                  miss → pick() 落到 SF Mono 档, 界面照跑只是字形变了 (最难归因的一类)
#   AppLanguage  → path(forResource:"<lang>", ofType:"lproj")
#                  miss → L() 回落 key 本身 (= 中文原文), 英文界面出中英混排
#
# 尤其: Bundle.url(forResource:withExtension:) 在 macOS 上**不递归子目录** (2026-09 实测)。
# 所以"字体放 Resources/Fonts/ 下"这种看起来没毛病的摆法, 查出来就是 nil。工程用 Xcode 16
# 的 PBXFileSystemSynchronizedRootGroup, 资源靠同步组隐式纳入, 因此这个门禁的真正价值是
# **证明同步组那份隐式纳入的结果恰好是代码期待的那个摆法** —— 它不会因为工程文件换了排版
# 而失效, 也不需要回来改清单: 期望清单每次从源码树现推。
#
# 与构建器无关: 吃任意一个 .app 路径。xcodebuild 的产物、CI 里手动编的包都能验。
#
# 用法:
#   scripts/diag/resource-gate.sh <path/to/Some.app>   # 门禁, miss 即退出码 1
#   scripts/diag/resource-gate.sh --list               # 只打印期望清单 (调试用)
#   scripts/diag/resource-gate.sh --out <dir> <app>    # 探针二进制落到指定目录
#
# 通过条件: 全部命中 + Info.plist 读得到 (退出码 0)。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_ROOT="$ROOT/mangox"
PROBE_SRC="$ROOT/scripts/diag/bundle_probe.swift"

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

log()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

OUT_DIR=""
LIST_ONLY=0
APP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)   LIST_ONLY=1; shift ;;
        --out)    OUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "未知参数: $1" ;;
        *)  APP="$1"; shift ;;
    esac
done

# ── 期望清单: 从源码树现推 ────────────────────────────────
# 剥两层前缀 (mangox/ 与 mangox/Resources/) 后按 basename 拍平, 唯一保留目录形态的是
# *.lproj —— 本地化包必须是目录, 且中英两个 Localizable.strings 会撞名。
derive_expectations() {
    local rel dest
    while IFS= read -r f; do
        rel="${f#$SRC_ROOT/}"
        rel="${rel#Resources/}"
        case "$rel" in
            # *.xcassets 由 actool 编成 Assets.car, 不是以原名进 bundle;
            # *.entitlements / Info.plist 是签名与元数据, 不查; *.md 是设计稿, 运行期不读
            # (工程用同步组时它们确实会被打进 bundle, 但探针只查"在不在", 不查"该不该在")
            *.xcassets|*.xcassets/*|*.entitlements|*.md) continue ;;
            Info.plist|.DS_Store) continue ;;
        esac
        case "$rel" in
            *.lproj/*) echo "$(basename "$(dirname "$rel")")" ;;
            *)         echo "$(basename "$rel")" ;;
        esac
    done < <(find "$SRC_ROOT" -type f -not -name '*.swift' | sort)
}

EXPECT=()
while IFS= read -r item; do EXPECT+=("$item"); done < <(derive_expectations)

if [[ "$LIST_ONLY" == 1 ]]; then
    printf '%s\n' "${EXPECT[@]}"
    exit 0
fi

[[ -n "$APP" ]] || { usage; exit 1; }
[[ -d "$APP" ]] || die "不是目录: $APP"
[[ -f "$PROBE_SRC" ]] || die "缺 $PROBE_SRC"

# ── 工具链 ────────────────────────────────────────────────
# 显式 DEVELOPER_DIR > 完整 Xcode > xcode-select 当前指向。只装 CLT 的机器上 xcrun 也能给
# 出完整 macOS SDK + swiftc, 探针只要能编过, 不需要 actool。
DEV="${DEVELOPER_DIR:-}"
if [[ -z "$DEV" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    DEV="/Applications/Xcode.app/Contents/Developer"
fi
[[ -n "$DEV" ]] || DEV="$(xcode-select -p 2>/dev/null || true)"
[[ -n "$DEV" ]] || die "找不到开发者目录 (xcode-select --install)"
SDK="$(DEVELOPER_DIR="$DEV" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[[ -n "$SDK" ]] || die "拿不到 macOS SDK"

# ── 跑 ────────────────────────────────────────────────────
step "资源可达性门禁 (真 NSBundle 查一遍)"
log "  bundle  : $APP"
log "  工具链  : $DEV"
log "  期望资源: ${#EXPECT[@]} 项 (从源码树现推)"

[[ -n "$OUT_DIR" ]] || OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mangox-gate.XXXXXX")"
mkdir -p "$OUT_DIR"
PROBE_BIN="$OUT_DIR/bundle_probe"
LOG="$(mktemp -t mangox-gate)"
trap 'rm -f "$LOG"' EXIT

if [[ ! -x "$PROBE_BIN" || "$PROBE_SRC" -nt "$PROBE_BIN" ]]; then
    step "编译探针"
    if ! DEVELOPER_DIR="$DEV" xcrun swiftc -sdk "$SDK" -o "$PROBE_BIN" "$PROBE_SRC" >"$LOG" 2>&1; then
        cat "$LOG" >&2
        die "编译资源探针失败"
    fi
fi

if ! "$PROBE_BIN" "$APP" ${EXPECT[@]+"${EXPECT[@]}"}; then
    die "资源可达性门禁未过 —— 界面会静默降级 (字形 / 语言 / 模型目录), 不崩但不对"
fi

step "OK: ${#EXPECT[@]} 项资源全部可达"
