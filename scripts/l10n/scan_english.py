#!/usr/bin/env python3
r"""
MangoX 硬编码英文扫描器 —— 第三道本地化门

## 为什么需要它（2026-10-19，boss 报「部分显示文本切中英文不生效」）

前两道门都只扫**含汉字**的字面量：

  ① `gen_strings.py --check`  —— 「每条中文都有译文」
  ② `scan_wiring.py --check`  —— 「每条中文都落在本地化汇聚点上」

⇒ **硬编码英文两道门都看不见**。而它的失效形态恰好最隐蔽:
   · 中文模式下它是漏译（侧栏 `New chat` / 编辑器 `Ask for approval`）;
   · 英文模式下它**看起来完全正确**;
   · 编译期零信号、运行期零信号。
于是它能活到用户来报 —— 实测那次一次挖出三十余条（nav 5 + 全大写页眉 6 + Composer 2
+ 档位名 3 套枚举 + 顶栏/轨迹 8 + 计划卡 3 + 会话默认标题）。

## 判据（两条位置形态，都是"作者把它当界面文案用"的地方）

  A. **取词位置**: `Text(` / `Button(` / `Label(` / `title:` / `label:` / … 后面直接一个字面量。
     这是 UI 文案的正常落点, 必须是中文 key（或包在 `L()/LK()` 里）。
  B. **返回位置**: `case .x: "…"` / `return "…"`。
     枚举的 `displayName` / `subtitle` 都长这样 —— 缺陷里那三套档位名（`"Full"` /
     `"Auto allow"` / `"Extra High"`）就是这种形态, 判据 A 看不见它们。

## 什么不算（避免把门造成噪音源）

  - 已包在 `L(...)` / `LK(...)` 里 —— 那是**走了词表的英文 key**（如 `L("Codemode")`, 专名中英同形）;
  - `Text(verbatim: "…")` —— 作者显式声明"不要再查表"（拼接已本地化的片段时才这么写）;
  - 含汉字的字面量 —— 归前两道门管;
  - 不含拉丁字母（`"—"` / `"↑%@"` / 纯数字）;
  - 长得像标识符: `^[a-z][a-zA-Z0-9_]*$`（`error` / `image` / enum rawValue / 键名）;
  - 长得像符号名或路径: 含 `.` 且无空格（`square.and.pencil` / `text/plain`）;
  - **三引号块内** —— 那是嵌入的 TypeScript 扩展源码（pi 的工具契约, 给模型看的,
    不是界面语言; 见 `PiRpcTransport`）。按三引号逐文件翻转状态跳过。
  - 豁免清单 `english_allow.txt`（品牌名等, 每条都要写理由）。

用法:
  python3 scripts/l10n/scan_english.py            # 打印可疑清单
  python3 scripts/l10n/scan_english.py --check    # 门禁: 有可疑项则退码 1
  python3 scripts/l10n/scan_english.py --explain  # 打印判据说明
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_strings import ROOT, strip_line_comment  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOW_FILE = os.path.join(HERE, 'english_allow.txt')

CJK = re.compile(r'[\u3400-\u9fff\uf900-\ufaff]')
LATIN = re.compile(r'[A-Za-z]')
IDENT = re.compile(r'^[a-z][a-zA-Z0-9_]*$')
# 全小写 kebab-case = 标识符而不是文案（`new-task` / `new-sparse` / `openai-completions`）。
KEBAB = re.compile(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)+$')
# "符号名/路径/MIME/键" 的判据是**含分隔符**（`square.and.pencil` / `text/plain` / `new:`），
# **不是"没有空格"** —— 第一版写成"无空格即符号名", 于是把 `"Full"` / `"Chat"` / `"Turns"`
# 这些单字标题全放过（正好是 boss 截图里那批）。无空格 + 单个大写词 ≠ 符号名。
SYMBOLISH = re.compile(r'^(?=.*[./:@#_])[A-Za-z0-9_./@:#-]+$')
# 剥完插值后只剩运算符/分隔符尾巴 ⇒ 是拼接残片（`"task-"` / `"agent_mode."`），不是文案。
FRAGMENT_TAIL = set('-:._/|+')
LOCALIZED = re.compile(r'\b(L|LK)\s*\(\s*$')          # 已包在取词函数里
VERBATIM = re.compile(r'\bverbatim\s*:\s*$')

# A. 取词位置: 字面量**开引号之前同一行**的前缀必须以此结尾。
#    名单见 `build_sink_prefix`（内建汇聚点 + 自动发现的 helper）。
#    对 `title:` / `label:` 也成立（`navRow(icon: "x", title: ` 里 `title:` 在末尾）。
SINK_TAIL = re.compile(r'(?:[:,(]\s*)$')

# B. 返回位置: `case .x: "…"` / `return "…"`
RETURN_PREFIX = re.compile(r'(?:\bcase\b[^:]*:|\breturn)\s*$')

TRIPLE = '"' * 3
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

# ── 自定义"文案汇聚函数"的自动发现 ──────────────────────────────────────────
#
# ⚠️ 这个门第一版是**枚举位置**（`Text(` / `title:` / …），于是 `sectionHeader("Projects")`
#    这种"自己写的小 helper + 无标签首参"完全看不见 —— boss 2026-10-19 第二次报的
#    `Projects` / `Chats` 两处分组标题就是这么漏的。
# 判据: `func X(_ p: String, …) -> some View` 且函数体里出现 `Text(p)` ⇒ X 是文案落点,
#    凡是 `X("…")` 都在取词位置上。**不写死名单** —— 将来新加的 helper 自动纳入。
RENDER_HELPER_SIG = re.compile(r'func\s+(\w+)\s*\(\s*_\s+(\w+)\s*:\s*String')
NEXT_FUNC = re.compile(r'\n[ \t]*(?:@\w+\s+)*(?:private\s+|fileprivate\s+|static\s+)*func\s')


def render_helper_names():
    """扫全仓, 返回"首参 String 且被 Text() 直接渲染"的辅助函数名集合。"""
    names = set()
    for dirpath, _, files in os.walk(os.path.join(ROOT, 'mangox')):
        for fn in sorted(files):
            if not fn.endswith('.swift'):
                continue
            text = open(os.path.join(dirpath, fn), encoding='utf-8').read()
            for m in RENDER_HELPER_SIG.finditer(text):
                name, param = m.group(1), m.group(2)
                # 函数体窗口 = 到下一条 func 声明为止（别越界读进邻居的实现）
                rest = text[m.end():]
                nxt = NEXT_FUNC.search(rest)
                body = rest[:nxt.start()] if nxt else rest[:4000]
                if re.search(r'\bText\s*\(\s*' + re.escape(param) + r'\s*\)', body):
                    names.add(name)
    return names


def build_sink_prefix(helpers):
    """取词位置: 内建汇聚点 + 自动发现的 helper（`X("…")` 的无标签首参）。"""
    alts = [re.escape(h) for h in sorted(helpers)]
    helper_alt = ('|' + '|'.join(alts)) if alts else ''
    return re.compile(
        r'(?:\bText|\bButton|\bLabel|\bToggle|\bTextField|\bSecureField|\bMenu'
        r'|\bmodePillButton|\btitle|\blabel|\btext|\bmessage|\bplaceholder'
        r'|\bfallbackTitle|\bnavRow' + helper_alt + r')\s*(?:\([^()]*)?[:(]\s*$'
    )


def load_allow():
    """豁免清单: 每行一个**精确字面量**（不是行号 —— 行号会漂）。`#` 开头是注释。"""
    if not os.path.exists(ALLOW_FILE):
        return set()
    out = set()
    for raw in open(ALLOW_FILE, encoding='utf-8'):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        out.add(line)
    return out


def looks_like_ui_text(s):
    r"""字面量本身像不像"给用户看的一句话"。

    ⚠️ 先**剥掉插值段**再判: `"v\(v)"` / `"task-\(id)"` / `"agent_mode.\(pid)"` 剥完只剩
    `v` / `task-` / `agent_mode.` —— 那是标识符或键前缀, 不是文案; 而 `"Token ↑\(n)"`
    剥完仍是 `Token ↑`（首字母大写 + 有空格）⇒ 该报。
    """
    if not s or CJK.search(s):
        return False                    # 归前两道门
    if not LATIN.search(s):
        return False                    # 无拉丁字母
    # 插值括号不配对 ⇒ 这一条是**正则把嵌套引号切歪了**（Swift 允许 `"a\(d ?? "-")"`，
    # 行级正则只能在第一个内层引号处收手）。这种残片一律不判，免得把键编码当文案报。
    if s.count('\\(') > s.count(')'):
        return False
    body = re.sub(r'\\\([^()]*(?:\([^()]*\)[^()]*)*\)', '', s).strip()
    if not body or not body[0].isalpha():
        return False                    # 以符号/数字开头: 不是文案
    if IDENT.match(body):
        return False                    # error / image / 小写键名
    if KEBAB.match(body):
        return False                    # new-task / openai-completions（标识符）
    if body[-1] in FRAGMENT_TAIL:
        return False                    # task- / agent_mode. / new:  拼接残片
    if SYMBOLISH.match(body):
        return False                    # square.and.pencil / text/plain / https://…
    return True


def scan():
    """返回 [(file, lineno, literal, rule)]；rule ∈ {'取词位置', '返回位置'}。"""
    allow = load_allow()
    sink = build_sink_prefix(render_helper_names())
    hits = []
    for dirpath, _, files in os.walk(os.path.join(ROOT, 'mangox')):
        for fn in sorted(files):
            if not fn.endswith('.swift'):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, ROOT)
            in_multiline = False        # 三引号块状态（跨行）
            for lineno, raw in enumerate(open(path, encoding='utf-8'), 1):
                code = strip_line_comment(raw.rstrip('\n'))
                # 三引号翻转: 一行里可能出现偶数次（同一行开+闭）。
                # ⚠️ **必须先剥注释**: 解释"为什么用 `#\"\"\"` 原始字符串"的那行文档注释里
                #    也含三引号, 先翻状态会让紧随其后的整个 TS 块被当成普通代码扫一遍
                #    （实测漏了 5 条工具契约串）。同一个原因也让"注释里提到某个词"不能当判据。
                if TRIPLE in code:
                    if code.count(TRIPLE) % 2 == 1:
                        in_multiline = not in_multiline
                    continue            # 三引号那一行本身多半是字符串首/尾, 跳过
                if in_multiline:
                    continue
                for m in LITERAL.finditer(code):
                    lit = m.group(1)
                    if lit in allow:
                        continue
                    if not looks_like_ui_text(lit):
                        continue
                    prefix = code[:m.start()]
                    if LOCALIZED.search(prefix) or VERBATIM.search(prefix):
                        continue
                    rule = None
                    if sink.search(prefix) and SINK_TAIL.search(prefix):
                        rule = '取词位置'
                    elif RETURN_PREFIX.search(prefix):
                        rule = '返回位置'
                    if rule:
                        hits.append((rel, lineno, lit, rule))
    return hits


def main():
    if '--explain' in sys.argv:
        print(__doc__)
        return 0
    hits = scan()
    if '--check' in sys.argv:
        if not hits:
            print('硬编码英文取词点: 0')
            print('OK - 界面文案都走了本地化（或已进 english_allow.txt 豁免）')
            return 0
        print(f'FAIL - 发现 {len(hits)} 处硬编码英文界面文案'
              '（中文模式下是漏译, 英文模式下"看起来对" ⇒ 两道旧门都看不见）:')
        for rel, lineno, lit, rule in hits:
            print(f'  - {rel}:{lineno}  [{rule}]  "{lit}"')
        print('\n修法: 换成中文 key 走 `L()` / 直接 `Text("中文")`;'
              ' 若确实是品牌名或给模型的契约串, 加进 scripts/l10n/english_allow.txt 并写理由。')
        return 1
    print(f'可疑硬编码英文: {len(hits)}')
    for rel, lineno, lit, rule in hits:
        print(f'  - {rel}:{lineno}  [{rule}]  "{lit}"')
    return 0


if __name__ == '__main__':
    sys.exit(main())
