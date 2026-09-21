#!/usr/bin/env python3
#!/usr/bin/env python3
"""暗色板算例 —— 面层级 / 文字对比度 / 不变量判定（纯标准库，零依赖）。

**为什么要第二份实现**：冒烟里的守卫用的是 `CodexTheme.WCAG`（Swift 那份）。只有那一份的话，
"守卫说绿"就无法证伪。这份把同样的公式独立重算一遍，两边数字必须**逐位吻合** ——
不吻合 = 其中一份有 bug（比"守卫绿了但数算错了"好抓得多）。2026-09-21 实测两边一致。

**色值不在这里硬编码** —— 直接解析 `mangox/Theme/CodexTheme.swift` 的 `enum Dark`。
否则本文件就成了**第三个真源**，主题改了、算例还在验旧色值，正是我们要防的那种漂移。
这里独立的只有"公式"，不是"数据"。

用法:
  python3 scripts/diag/palette_probe.py                  # 面层级 + 各面文字对比度 + 不变量判定
  python3 scripts/diag/palette_probe.py --hex 1E1E26     # 单个色的亮度 / 与页面底的比值
  python3 scripts/diag/palette_probe.py --contrast C8C8D0,2C2C35

退出码: 0 = 全部不变量成立；1 = 有越界（调参调到越界时立刻看得见，不用等跑整条冒烟）。
"""

import os
import re
import sys

THEME = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 '..', '..', 'mangox', 'Theme', 'CodexTheme.swift'))


# ---------------------------------------------------------------- WCAG 数学

def luminance(hexv):
    """WCAG 2.x 相对亮度。sRGB 线性化 + Rec.709 权重。"""
    def lin(v):
        c = (v & 0xFF) / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(hexv >> 16) + 0.7152 * lin(hexv >> 8) + 0.0722 * lin(hexv)


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


# ---------------------------------------------------------------- 解析真源

def load_dark(path=THEME):
    """从 CodexTheme.swift 的 `enum Dark` 里取 UInt32 色值 + 两个交互态 alpha。"""
    if not os.path.exists(path):
        sys.exit(f'找不到主题文件: {path}')
    with open(path, encoding='utf-8') as f:
        text = f.read()
    m = re.search(r'\benum Dark \{(.*?)\n    \}', text, re.S)
    if not m:
        sys.exit('在主题文件里定位不到 enum Dark（改了结构就要同步改本脚本）')
    body = m.group(1)
    colors = {k: int(v, 16) for k, v in
              re.findall(r'static let (\w+): UInt32\s*=\s*0x([0-9A-Fa-f]+)', body)}
    alphas = {k: float(v) for k, v in
              re.findall(r'static let (\w+): Double\s*=\s*([0-9.]+)', body)}
    return colors, alphas


# 面层级链 —— 顺序即语义（冒烟守同一条）。改顺序 = 改层次，必须有意为之。
CHAIN = ['bgBase', 'bgSidebar', 'bgChat', 'bgInput',
         'contentPanel', 'bgCard', 'bgElevated', 'bgPill']

# (标签, 文字 token, 底色 token, 下限, 上限或 None) —— 与 smokeMain 的 T-COLOR 段同源同界
BANDS = [
    ('正文    ', 'textPrimary',   'contentPanel', 9.0, 12.5),
    ('mono    ', 'textMono',      'contentPanel', 7.5, 10.0),
    ('次级    ', 'textSecondary', 'contentPanel', 6.0, 8.5),
    ('三级    ', 'textTertiary',  'contentPanel', 4.5, None),
    ('卡上正文', 'textPrimary',   'bgCard',       8.5, None),
    ('卡上mono', 'textMono',      'bgCard',       7.0, None),
]


def fmt_band(lo, hi):
    return f'{lo}~{hi}' if hi is not None else f'≥{lo}'


def main(argv):
    colors, alphas = load_dark()

    # --- 单色查询 ---
    if '--hex' in argv:
        h = argv[argv.index('--hex') + 1].lstrip('#')
        v = int(h, 16)
        print(f'#{v:06X}  L={luminance(v):.5f}')
        if 'bgChat' in colors:
            print(f'  相对页面底 (bgChat) = {luminance(v) / luminance(colors["bgChat"]):.2f}×')
        return 0

    if '--contrast' in argv:
        a, b = argv[argv.index('--contrast') + 1].split(',')
        ca, cb = int(a.lstrip('#'), 16), int(b.lstrip('#'), 16)
        print(f'#{ca:06X} vs #{cb:06X} → {contrast(ca, cb):.3f}:1')
        return 0

    bad = []

    print(f'主题真源: {os.path.relpath(THEME, os.getcwd())}\n')

    print('面层级（亮度必须严格单调递增）:')
    for name in CHAIN:
        if name not in colors:
            sys.exit(f'链上缺面: {name} —— CodexTheme.swift 与 CHAIN 不同步')
        print(f'  {name:14s} #{colors[name]:06X}   L={luminance(colors[name]):.5f}')
    for a, b in zip(CHAIN, CHAIN[1:]):
        if not luminance(colors[a]) < luminance(colors[b]):
            bad.append(f'面层级: {a} 不比 {b} 暗')
    print()

    print('文字对比度（基准 = 正文真正坐的那一层）:')
    for label, fg, bg, lo, hi in BANDS:
        c = contrast(colors[fg], colors[bg])
        ok = c >= lo and (hi is None or c <= hi)
        if not ok:
            bad.append(f'{label.strip()}: {c:.2f}:1 越界 [{fmt_band(lo, hi)}]')
        print(f'  {label} {fg:14s} ← {bg:13s} {c:6.2f}:1   [{fmt_band(lo, hi)}]  {"OK" if ok else "越界"}')
    print()

    lift = luminance(colors['contentPanel']) / luminance(colors['bgChat'])
    if lift < 1.5:
        bad.append(f'正文面抬离页面底不足: {lift:.2f}× < 1.5×')
    print(f"正文面抬升      contentPanel/bgChat = {lift:.2f}×   [≥1.5×]  {'OK' if lift >= 1.5 else '越界'}")

    floor = luminance(colors['bgBase'])
    if floor < 0.004:
        bad.append(f'地板触及纯黑: {floor:.5f} < 0.004')
    print(f"地板不碰纯黑    bgBase L = {floor:.5f}          [≥0.004]  {'OK' if floor >= 0.004 else '越界'}")

    ha, sa = alphas.get('hoverAlpha'), alphas.get('selectedAlpha')
    if ha is not None and sa is not None:
        if not sa > ha:
            bad.append(f'选中不比悬停实: selected={sa} <= hover={ha}')
        print(f"选中比悬停实    selected {sa} > hover {ha}      {'OK' if sa > ha else '越界'}")
    print()

    # 参照：boss 说舒服的 Settings 卡面（bgElevated）—— 用来判断"要再压多少"
    ref = contrast(colors['textPrimary'], colors['bgElevated'])
    print(f'参照 Settings 卡面 (bgElevated) 正文 = {ref:.2f}:1'
          f'  —— 想把正文再往下压，就抬 contentPanel 并连带抬 bgCard/bgElevated/bgPill')
    print()

    if bad:
        print('不变量破了:')
        for b in bad:
            print(f'  - {b}')
        return 1
    print('全部不变量成立')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
