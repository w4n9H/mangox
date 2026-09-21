#!/usr/bin/env python3
r"""
MangoX 本地化「接线」自动改写器 —— 由 scan_wiring 驱动

`scan_wiring.py` 负责**判**（哪些字面量没落在本地化汇聚点上），本脚本负责**改**：
把那些字面量就地包成 `L(...)`；带 `\(插值)` 的改写成 `String(format: L("…格式 key…"), 参数…)`。

统一改法的依据 (2026-09-20 实测, 见 scan_wiring.py 注释):
  · 不接线 = 该字面量被求值成 `String` 后流进变量/返回值/实参 —— **只在产生点取词**才有用。
  · 所以 `return "甲"` → `return L("甲")`; `x = "甲"` → `x = L("甲")`;
    `f("甲")` → `f(L("甲"))`; `case .a: "甲"` → `case .a: L("甲")`;
    `.error("甲")` → `.error(L("甲"))`。形态各异, 改法同一个: **包住字面量本身**。
  · 带插值的必须换 `String(format:)`: `"UID \(uid) 未取到"` → `String(format: L("UID %lld 未取到"), uid)`。
    格式 key 由 gen_strings.to_format_key 生成 —— 与词表里的 key 同源同算法, 保证对得上。

**不动**三类:
  ① `wiring_allow.txt` 里的红线 (落库列 / 邮件协议面 / 兼作 id 的 rawValue / 与常量比较的模式串)
  ② `LOGIC` 类 (参与 `==` / `hasPrefix` / `replacingOccurrences` 判定 —— 包了会破坏逻辑)
  ③ 跨行字符串 / 格式串里再带插值等异常形态 → 打出来人工处理

用法:
  python3 scripts/l10n/wire_strings.py            # 预演 (只打印将要改什么)
  python3 scripts/l10n/wire_strings.py --apply    # 落盘
  python3 scripts/l10n/wire_strings.py --apply --max-passes 6
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_strings import ROOT, interpolation_parts, to_format_key  # noqa: E402
import scan_wiring  # noqa: E402

SPEC_RE = re.compile(r'%[@dulfsxeg]|%lld|%llu|%02d|%02lld')


def load_allow():
    return scan_wiring.load_allow()


def literal_span(code, start, text):
    """源码里字面量的完整片段 (含两侧引号); 未闭合 (跨行) 返回 None。"""
    end = start + len(text) + 1
    if end >= len(code) or code[end] != '"':
        return None
    return code[start:end + 1]


def unbalanced_percent(key):
    """格式 key 里是否有不属于说明符的裸 `%` —— 有则不能进 String(format:)。"""
    return '%' in SPEC_RE.sub('', key)


def build_replacement(code, start, text, key, kind):
    """→ (替换文本, 跳过原因)。返回 (None, reason) 表示不动。"""
    span = literal_span(code, start, text)
    if span is None:
        return None, '字面量跨行 (未闭合)'

    parts = interpolation_parts(text)
    args = [v.strip() for k, v in parts if k == 'var']
    if not args:
        return f'L({span})', None

    if kind == 'FORMAT_ARG':
        return None, 'String(format:) 的格式串里又带插值 —— 人工处理'
    if unbalanced_percent(key):
        return None, '格式 key 含裸 % (非说明符) —— 人工处理'
    return f'String(format: L("{key}"), {", ".join(args)})', None


def plan():
    """→ (edits{rel: [(lineno, start, old_text, replacement)]}, skipped[])"""
    allow = load_allow()
    edits = {}
    skipped = []
    for rel, lineno, kind, key, _tail in scan_wiring.suspects():
        if f'{rel}|{key}' in allow:
            continue
        if kind == 'LOGIC':
            skipped.append((rel, lineno, kind, key, '逻辑/协议判定串 —— 请登记进 wiring_allow.txt'))
            continue
        if kind == 'EMBEDDED':
            skipped.append((rel, lineno, kind, key, '多行字符串内的嵌入代码 —— 请登记进 wiring_allow.txt'))
            continue
        edits.setdefault(rel, []).append((lineno, kind, key))
    return edits, skipped


def inside_multiline_string(lines, lineno):
    """安全断言: 该行是否落在**多行字符串字面量** (`\"\"\"…\"\"\"`) 区间内。

    这是本脚本最贵一坑的精确防线 (2026-09-20 实测): 注入给 pi 的扩展 JS 源码整段塞在
    `let source = \"\"\"…\"\"\"` 里, codemod 把其中的 `rows.push("…");` 改成了
    `rows.push(L("…"));` —— 从**内层引号**看完全正确 (L( 确实在引号外), 但整段是**字符串内容**,
    于是变成非法 JS, 在扩展进程里 `L is not defined` 被 try/catch 静默吞掉 (零报错)。
    所以判据不能是"引号内外", 必须是"在不在多行字符串区间里"。
    """
    raw = '\n'.join(lines)
    start = sum(len(x) + 1 for x in lines[:lineno - 1])
    return any(a < start < b for a, b in scan_wiring.embedded_ranges(raw))


def apply_once(allow):
    """跑一趟: 返回 (改动条数, 跳过列表, 打印行列表)。"""
    changed = 0
    skipped = []
    log = []
    for rel, lineno, kind, key, _tail in scan_wiring.suspects():
        if f'{rel}|{key}' in allow:
            continue
        if kind == 'LOGIC':
            continue
        full = os.path.join(ROOT, rel)
        lines = open(full, encoding='utf-8').read().split('\n')
        if inside_multiline_string(lines, lineno):
            raise SystemExit(
                f'ABORT - 安全检查拦下: {rel}:{lineno} 位于多行字符串字面量内部\n'
                f'        那里是嵌入代码/文本 (如注入给 pi 的扩展 JS), 加 L() 会变成非法内容。\n'
                f'        该处应登记进 wiring_allow.txt, 而不是自动改写。')
        line = lines[lineno - 1]
        code = scan_wiring.strip_line_comment(line)

        # 从右往左替换, 避免前面的替换挪动后面的下标
        hits = []
        for text, start in scan_wiring.scan_literals(code):
            if to_format_key(text) != key:
                continue
            replacement, reason = build_replacement(code, start, text, key, kind)
            if replacement is None:
                skipped.append((rel, lineno, kind, key, reason))
                continue
            hits.append((start, text, replacement))
        if not hits:
            continue
        for start, text, replacement in sorted(hits, reverse=True):
            code = code[:start] + replacement + code[start + len(text) + 2:]
            changed += 1
            log.append(f'  {rel}:{lineno}  [{kind}]  {key[:44]}')
            log.append(f'      → {replacement[:96]}')
        lines[lineno - 1] = code
        with open(full, 'w', encoding='utf-8') as handle:
            handle.write('\n'.join(lines))
    return changed, skipped, log


def main():
    args = sys.argv[1:]
    do_apply = '--apply' in args
    max_passes = 6
    if '--max-passes' in args:
        max_passes = int(args[args.index('--max-passes') + 1])

    allow = load_allow()

    if do_apply:
        # 落盘前**前置检查**: 未被豁免的 EMBEDDED / LOGIC 站点一律先停下来要人拍板。
        # 为什么放前置而不是逐行拦截: 逐行拦截发生在循环中途, 会留下"改了一半"的工作区。
        blockers = [(rel, ln, kind, key) for rel, ln, kind, key, _t in scan_wiring.suspects()
                    if kind in ('EMBEDDED', 'LOGIC') and f'{rel}|{key}' not in allow]
        if blockers:
            print(f'拒绝落盘 - {len(blockers)} 处不可自动改写, 请先登记进 wiring_allow.txt:', file=sys.stderr)
            for rel, ln, kind, key in blockers:
                print(f'   {rel}:{ln}  [{kind}]  {key}', file=sys.stderr)
            return 2

    if not do_apply:
        edits, skipped = plan()
        total = sum(len(v) for v in edits.values())
        print(f'预演: 将改写 {total} 处, 覆盖 {len(edits)} 个文件')
        for rel in sorted(edits):
            print(f'\n{rel}  ({len(edits[rel])})')
            for lineno, kind, key in sorted(edits[rel]):
                print(f'   L{lineno:<5} [{kind}]  {key[:52]}')
        if skipped:
            print(f'\n跳过 (需人工处理) {len(skipped)} 处:')
            for rel, lineno, kind, key, reason in skipped:
                print(f'   {rel}:{lineno}  [{kind}]  {key[:40]}  —— {reason}')
        return 0

    total = 0
    seen_skip = set()
    for i in range(max_passes):
        changed, skipped, log = apply_once(allow)
        for entry in skipped:
            seen_skip.add(entry)
        if changed == 0:
            print(f'第 {i + 1} 趟: 无改动 —— 到达不动点')
            break
        print(f'\n第 {i + 1} 趟: 改写 {changed} 处')
        for line in log:
            print(line)
        total += changed
    print(f'\n合计改写 {total} 处')
    if seen_skip:
        print(f'\n跳过 (需人工处理) {len(seen_skip)} 处:')
        for rel, lineno, kind, key, reason in sorted(seen_skip):
            print(f'   {rel}:{lineno}  [{kind}]  {key[:40]}  —— {reason}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
