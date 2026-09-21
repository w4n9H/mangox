#!/usr/bin/env python3
r"""
MangoX 本地化「接线」扫描器 —— 词表覆盖 ≠ 接线正确

`gen_strings.py --check` 只保证**词表条数**对得上 (每条中文都有译文), 它**不看**这条中文
最终有没有被查表。两者是独立的两道门:

  ① 词表门 `gen_strings.py --check` —— 抽取器收「所有含汉字的字面量」(含日志/正则/未接线
     的域层串) → `491/491` 只意味着「491 条都有译文」, 不意味着「491 条都活」。
  ② 接线门 `scan_wiring.py` (本文件) —— 看每个字面量**落在什么位置**。
     `Text("中文")` / `Button("中文")` / `settingRow(title: "中文")` 会走查表;
     而 `return "中文"` / `x = "中文"` / `case .a: "中文"` / `String(format: "中文 %@")`
     这些形态**不吃自动本地化** → 切到英文后依然显示中文 (编译期零信号)。

判据: 取字面量**开引号之前同一行**的前缀, 看它结尾是否匹配本地化汇聚点 (SINK)。
行级启发式不可避免有误差 —— 所以本脚本把可疑项**分类**打出来, 由人分诊, 而不是自动改。

用法:
  python3 scripts/l10n/scan_wiring.py              # 打印可疑清单 (按文件分组)
  python3 scripts/l10n/scan_wiring.py --check      # 门禁: 有可疑项则退出码 1
  python3 scripts/l10n/scan_wiring.py --only FILE  # 只看某文件/目录前缀
  python3 scripts/l10n/scan_wiring.py --explain    # 打印各类别的含义

真源: 与 gen_strings.py 共用排除规则 (EXCLUDE_FILES / EXCLUDE_PAT / EXCLUDE_LINE /
LOG_KEY / is_regex_key), 保证两台门看的字面量集合一致。
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_strings import (  # noqa: E402
    APP, CJK, EXCLUDE_FILES, EXCLUDE_LINE, EXCLUDE_PAT, LOG_KEY, ROOT,
    is_regex_key, scan_literals, to_format_key,
)

ALLOW_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wiring_allow.txt')

# ── 本地化汇聚点 (SINK) ────────────────────────────────────────────────────
#
# 判定不看"紧挨着字面量的东西长得像什么", 而看**字面量所在表达式的最内层未闭合调用**。
# 名字集合在下面 `SINK_CALLS`; 唯一保留的正则是「显式不本地化」的作者意图标记。
SINK_VERBATIM = re.compile(r'\bverbatim\s*:\s*$')

# 跨行关键字实参 —— `settingRow(title: "外观",\n detail: "…")` 的续行只有一个 `detail: ` 前缀,
# 括号上下文在**上一行**, 单行扫描看不到。靠形参名兜住 (本项目这些形参一律声明为
# LocalizedStringKey, 是既有约定)。
SINK_KEYWORD = re.compile(
    r'\b(?:title|detail|subtitle|header|footer|placeholder|prompt|message|label|tooltip'
    r'|caption|hint|summary|emptyText|confirmText|cancelText|accessibilityLabel'
    r'|accessibilityHint|description|desc|note|reason|heading|sectionTitle)\s*:\s*$')

# ── 可疑项分类 (按前缀结尾形态) ─────────────────────────────────────────────
#
# 顺序即优先级: 越靠前越确定「必须加 L()」。
SUSPECT_KINDS = [
    ('RETURN', re.compile(r'\breturn\s+$'),
     '显式 return 字符串 —— 函数返回 String, 不吃本地化'),
    ('CASE_IMPLICIT', re.compile(r'\bcase\s+[^:]*:\s*$'),
     'switch 表达式隐式返回 (Swift 5.9 if/switch 表达式) —— 值类型是 String, 不吃本地化'),
    ('ASSIGN', re.compile(r'(?<![=!<>])=(?!=)\s*$'),
     '赋值给 String 变量/属性 —— 不吃本地化 (含 AppKit messageText/informativeText)'),
    ('FORMAT_ARG', re.compile(r'String\s*\(\s*format\s*:\s*$'),
     'String(format:) 的格式串 —— 必须写成 String(format: L("…"), …)'),
    ('LOGIC', re.compile(
        r'(?:==|!=|<=|>=)\s*$'
        r'|\.(?:hasPrefix|hasSuffix|contains|replacingOccurrences|appending|dropFirst|prefix)\s*\(\s*$'
        r'|\bof\s*:\s*$'),
     '逻辑比较 / 前后缀匹配 / 替换源 —— **绝不可**加 L() (会破坏协议判定或替换逻辑),'
     ' 应登记进 wiring_allow.txt'),
    ('EMBEDDED', re.compile(r'.'),
     '位于**多行字符串字面量**内 (注入给 pi 的扩展 JS 等) —— 包了 L() 会变成非法代码,'
     ' 应登记进 wiring_allow.txt'),
    ('INTERP', re.compile(r'^"'), '实际是插值片段 (前有引号未闭合)'),
    ('ARG', re.compile(r'[,(]\s*$'), '普通实参 —— 取决于形参类型, 需人工确认'),
    ('OTHER', re.compile(r'.'), '其它形态 —— 需人工确认'),
]

# ── 内联实参豁免 (实测依据) ─────────────────────────────────────────────────
#
# 2026-09-20 用 ImageRenderer 指纹实测 (scripts/l10n 之外的一次性探针, 结论已写进本注释):
#
#   Text("甲")                       → ✅ 本地化 (字面量直接实参)
#   Text(cond ? "甲" : "乙")          → ✅ 本地化 (**内联**三元, 整个表达式被推到 LocalizedStringKey)
#   let x = cond ? "甲" : "乙"; Text(x) → ❌ 不本地化 (x 已固化成 String)
#   Text(someString)                 → ❌ 不本地化
#   Text(LK(someString))             → ✅ 本地化
#
# 所以判据不是"看字面量长得像什么", 而是"这个字面量所在的**表达式**有没有落在 sink 实参位"。
# 这里用括号深度求出「最内层仍未闭合的调用名」来近似: 若它是 sink 且字面量到它之间没有
# `=` / `return` 打断, 则该字面量确实躺在那个调用的实参位 → 已接线。
INLINE_BREAK = re.compile(r'(?<![=!<>])=(?!=)|\breturn\b|\bcase\b')

EXPLICIT_LOCALIZERS = {'L', 'LK', 'NSLocalizedString', 'localizedString'}

# 系统自带的、有 `init(_ key: LocalizedStringKey, …)` 重载的 API。
SINK_SYSTEM = {
    'Text', 'Label', 'Button', 'Toggle', 'Picker', 'Section', 'Stepper', 'Link', 'Menu',
    'TextField', 'SecureField', 'NavigationLink', 'confirmationDialog', 'GroupBox',
    'DisclosureGroup', 'Tab', 'ContentUnavailableView',
    '.help', '.alert', '.navigationTitle', '.navigationSubtitle', '.confirmationDialog',
    '.accessibilityLabel', '.accessibilityHint', '.accessibilityValue', '.badge',
    '.fileExporter', '.fileImporter',
}
# 注: 刻意**不含 `String`** —— `String(format: "中文 %@")` 的格式串不吃本地化, 必须写成
# `String(format: L("中文 %@"), …)`。若把 String 当 sink, 这条最典型的漏接线会被豁免掉。

_READ_CACHE = {}


def _read(rel):
    if rel not in _READ_CACHE:
        with open(os.path.join(ROOT, rel), encoding='utf-8') as handle:
            _READ_CACHE[rel] = handle.read()
    return _READ_CACHE[rel]


def _balanced(text, open_at):
    """从 `text[open_at]` 的括号出发取配对内容 (不含两侧括号)。返回 (内容, 结束下标)。"""
    depth = 0
    i = open_at
    while i < len(text):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return text[open_at + 1:i], i
        i += 1
    return text[open_at + 1:], len(text)


def _skip_generic(text, i):
    if i < len(text) and text[i] == '<':
        depth = 0
        while i < len(text):
            if text[i] == '<':
                depth += 1
            elif text[i] == '>':
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
    return i


def declared_sink_names():
    """**从源码自动发现**本地化汇聚点, 而不是手工维护名字表 (手工名单必然漂移)。

    判据: 一个 `func` 的形参列表里出现 `LocalizedStringKey` → 它的名字就是汇聚点;
    一个 `struct`/`class` 的成员里有 `LocalizedStringKey` → 它的构造点同理
    (`CodexSegmented(options: ["全局", "项目"])` 这类数组实参靠它命中)。
    """
    names = set()
    decl = re.compile(r'\b(?:func|struct|class|enum)\s+([A-Za-z_][A-Za-z0-9_]*)')
    for rel in _all_swift_files():
        text = _read(rel)
        if 'LocalizedStringKey' not in text:
            continue
        for match in decl.finditer(text):
            name = match.group(1)
            i = _skip_generic(text, match.end())
            while i < len(text) and text[i] in ' \t\n':
                i += 1
            if match.group(0).startswith('func'):
                if i >= len(text) or text[i] != '(':
                    continue
                body, _ = _balanced(text, i)
            else:
                # struct/class/enum: 往后找第一个 `{`, 再配对到 `}` —— 成员声明区
                brace = text.find('{', i)
                if brace < 0 or (i < len(text) and text[i] != ':' and brace - i > 200):
                    continue
                depth = 0
                j = brace
                while j < len(text):
                    if text[j] == '{':
                        depth += 1
                    elif text[j] == '}':
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                body = text[brace:j]
                if name and name[0].islower():
                    continue
            if 'LocalizedStringKey' in body:
                names.add(name)
    return names


def _all_swift_files():
    for dirpath, _, filenames in os.walk(APP):
        for name in sorted(filenames):
            if name.endswith('.swift'):
                yield os.path.relpath(os.path.join(dirpath, name), ROOT)


def sink_calls():
    return SINK_SYSTEM | declared_sink_names()


def innermost_open_call(prefix):
    """prefix 里**仍未闭合**的最内层调用名 (含 `.help` 这种带点的修饰符)。

    为什么要它: 只看"紧挨着字面量的名字"会漏掉 `Text(LK(cond ? "甲" : "乙"))` 与
    `Text(cond ? "甲" : "乙")` 这两种**已接线**的形态 (实测都会本地化), 造成大量假阳性。
    """
    stack = []
    i = 0
    in_str = False
    escaped = False
    while i < len(prefix):
        c = prefix[i]
        if in_str:
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
        elif c in '([':
            j = i - 1
            while j >= 0 and prefix[j] == ' ':
                j -= 1
            end = j + 1
            while j >= 0 and (prefix[j].isalnum() or prefix[j] in '_.'):
                j -= 1
            name = prefix[j + 1:end]
            # 分组括号 `(…)` / 数组字面量 `[…]` 的"名字"是空 —— 它**不改变上下文**,
            # 沿用外层 (否则 `LK(a ? "x" : (b ? "y" : "z"))` 的最内层会被遮成空串而误判)。
            stack.append(name if name else (stack[-1] if stack else None))
        elif c in ')]':
            if stack:
                stack.pop()
        i += 1
    return stack[-1] if stack else None


def analyze(code, start, sinks):
    """→ (是否已接线, 类别)。`sinks` = sink_calls() 的结果 (由调用方算一次, 避免重复扫源)。"""
    prefix = code[:start]
    # `String(format: "…")` 先判 —— 它是"看起来像实参、其实不吃本地化"的典型, 不能被下面的
    # 内联实参豁免吞掉 (String 已刻意排除在 sink 之外, 双保险)。
    if re.search(r'String\s*\(\s*format\s*:\s*$', prefix):
        return False, 'FORMAT_ARG'
    if re.search(r'\blocalized\s*:\s*$', prefix):
        return True, 'OK/wired'          # String(localized: "…")
    ctx = innermost_open_call(prefix)
    if ctx in EXPLICIT_LOCALIZERS:
        return True, 'OK/wired'
    if SINK_VERBATIM.search(prefix):
        return True, 'OK/verbatim'
    if SINK_KEYWORD.search(prefix):
        return True, 'OK/keyword'
    # 内联实参: 最内层调用是 sink, 且字面量到它之间没有被 `=` / `return` / `case` 打断
    if ctx in sinks:
        open_at = prefix.rfind(ctx)
        gap = prefix[open_at:]
        if not INLINE_BREAK.search(gap):
            return True, 'OK/inline'
    for kind, pattern, _ in SUSPECT_KINDS:
        if pattern.search(prefix):
            return False, kind
    return False, 'OTHER'


def strip_line_comment(code):
    """去行尾注释 —— 但**不能**用 `split('//')` (会切坏 `"https://…"`)。"""
    out = []
    in_str = False
    escaped = False
    i = 0
    while i < len(code):
        c = code[i]
        if in_str:
            out.append(c)
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == '/' and i + 1 < len(code) and code[i + 1] == '/':
            break
        out.append(c)
        i += 1
    return ''.join(out)


def load_allow():
    """接线豁免名单: 每行 `相对路径|字面量` (不含注释/空行)。

    为什么用 `路径|字面量` 而不是行号: 行号会随无关改动漂移, 字面量不会。
    用在这里的都是**红线字面量** (恒中文, 永不进词表), 天然唯一。
    """
    out = set()
    if not os.path.exists(ALLOW_FILE):
        return out
    for line in open(ALLOW_FILE, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        out.add(line)
    return out


def embedded_ranges(text):
    """多行字符串字面量 (`\"\"\"…\"\"\"`) 的字符区间。

    **为什么必须单列一类**: 这类字面量里装的是**嵌入的代码/文本**(典型是注入给 pi 的扩展
    JS 源码), 不是 UI 文案。机械加 `L()` 会把它改成非法代码 —— 实测就是这么踩的:
    `rows.push("… 其余改动省略");` 被改成 `rows.push(L("… 其余改动省略"));`,
    运行时 `L is not defined` 被 try/catch 静默吞掉 (工具卡差异少一行, 无任何报错)。
    """
    ranges = []
    i = 0
    while True:
        start = text.find('"""', i)
        if start < 0:
            break
        end = text.find('"""', start + 3)
        end = len(text) if end < 0 else end + 3
        ranges.append((start, end))
        i = end
    return ranges


def suspects():
    """→ [(rel, lineno, kind, key, prefix_tail)]"""
    allow = load_allow()
    sinks = sink_calls()
    found = []
    for dirpath, _, filenames in os.walk(APP):
        for name in sorted(filenames):
            if not name.endswith('.swift'):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT)
            if rel in EXCLUDE_FILES:
                continue
            raw = open(full, encoding='utf-8').read()
            ranges = embedded_ranges(raw)
            offset = 0
            for lineno, line in enumerate(raw.split('\n'), 1):
                line_start, offset = offset, offset + len(line) + 1
                code = strip_line_comment(line)
                if not CJK.search(code) or EXCLUDE_PAT.search(code) or EXCLUDE_LINE.search(code):
                    continue
                inside = any(a < line_start < b for a, b in ranges)
                for text, start in scan_literals(code):
                    if not CJK.search(text):
                        continue
                    key = to_format_key(text)
                    if LOG_KEY.match(key) or is_regex_key(key):
                        continue
                    if f'{rel}|{key}' in allow:
                        continue
                    if inside:
                        found.append((rel, lineno, 'EMBEDDED', key, code[:start].strip()[-30:]))
                        continue
                    wired, kind = analyze(code, start, sinks)
                    if wired:
                        continue
                    found.append((rel, lineno, kind, key, code[:start].strip()[-30:]))
    return found


def main():
    args = sys.argv[1:]
    only = None
    if '--only' in args:
        only = args[args.index('--only') + 1]

    if '--explain' in args:
        print('判据 = 字面量开引号前同一行的前缀结尾是否匹配本地化汇聚点。')
        print('可疑类别 (越靠前越确定「必须加 L()」):')
        for kind, _, desc in SUSPECT_KINDS:
            print(f'  {kind:14s} {desc}')
        print('\n豁免名单: scripts/l10n/wiring_allow.txt (`相对路径|字面量`)')
        return 0

    found = suspects()
    if only:
        found = [f for f in found if f[0].startswith(only)]

    by_kind = {}
    for rel, lineno, kind, key, tail in found:
        by_kind.setdefault(kind, []).append((rel, lineno, key, tail))

    order = [k for k, _, _ in SUSPECT_KINDS]
    total = len(found)
    print(f'可疑未接线字面量: {total}')
    for kind in order:
        items = by_kind.get(kind)
        if not items:
            continue
        print(f'\n-- {kind} ({len(items)})  {dict((k, d) for k, _, d in SUSPECT_KINDS)[kind]}')
        for rel, lineno, key, tail in items:
            shown = key if len(key) <= 40 else key[:39] + '…'
            print(f'   {rel}:{lineno}  {shown}')
            print(f'        ↑ 前缀: …{tail}')
    if total == 0:
        print('OK - 全部含汉字字面量都落在本地化汇聚点上')

    if '--check' in args and total:
        print(f'\nFAIL - {total} 处疑似未接线', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
