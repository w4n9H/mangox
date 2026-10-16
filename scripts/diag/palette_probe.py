#!/usr/bin/env python3
"""亮 / 暗两块板的算例 —— 面层级 / 文字对比度 / 不变量判定（纯标准库，零依赖）。

**为什么要第二份实现**：冒烟里的守卫用的是 `CodexTheme.WCAG`（Swift 那份）。只有那一份的话，
"守卫说绿"就无法证伪。这份把同样的公式独立重算一遍，两边数字必须**逐位吻合** ——
不吻合 = 其中一份有 bug（比"守卫绿了但数算错了"好抓得多）。2026-09-21 实测两边一致。

**色值不在这里硬编码** —— 直接解析 `mangox/Theme/CodexTheme.swift`：
  · 暗色取 `enum Dark` 里的 `UInt32` 字面量
  · 亮色取 `adaptive(light: 0x……, dark: …)` 的 light 位
    （2026-10-14 P16 补 —— 在此之前 `load_dark()` 只认 `enum Dark`，**亮色一个 token 都不解析**，
     于是"亮色改了什么颜色都不会响"，P16 §2 把它立为前置门 1）
否则本文件就成了**第三个真源**，主题改了、算例还在验旧色值，正是我们要防的那种漂移。
这里独立的只有"公式"，不是"数据"。

用法:
  python3 scripts/diag/palette_probe.py                  # 双主题全量
  python3 scripts/diag/palette_probe.py --dark           # 只看暗色
  python3 scripts/diag/palette_probe.py --light          # 只看亮色
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

def _read_theme(path):
    if not os.path.exists(path):
        sys.exit(f'找不到主题文件: {path}')
    with open(path, encoding='utf-8') as f:
        return f.read()


def load_dark(path=THEME):
    """暗色值 —— **两个来源合并**（这一点曾经是个洞）。

      ① `enum Dark` 里的 `static let X: UInt32 = 0x…`
      ② `adaptive(light: …, dark: 0x…… | Dark.x)` 的 dark 位
         ⚠️ 板块色（info / thinking / toolError / …）在 2026-10-14 之前**只存在于 ②**，
            旧版这里只读 ① ⇒ **算例与冒烟一个板块色都没守**，而板块色正是工具行的主色。
            现在板块色两侧都住进 `enum Dark` 了，但 ② 仍然要解析 —— 否则下次有人
            在 `adaptive()` 里直接写字面量，又会**静默漏掉**（这次就是漏了才发现）。
    """
    text = _read_theme(path)
    m = re.search(r'\benum Dark \{(.*?)\n    \}', text, re.S)
    if not m:
        sys.exit('在主题文件里定位不到 enum Dark（改了结构就要同步改本脚本）')
    body = m.group(1)
    colors = {k: int(v, 16) for k, v in
              re.findall(r'static let (\w+): UInt32\s*=\s*0x([0-9A-Fa-f]+)', body)}
    alphas = {k: float(v) for k, v in
              re.findall(r'static let (\w+): Double\s*=\s*([0-9.]+)', body)}
    for mm in re.finditer(
            r'static let (\w+)\s*=\s*adaptive\(light:\s*0x[0-9A-Fa-f]+,\s*dark:\s*([^)]+)\)',
            text):
        key, spec = mm.group(1), mm.group(2).strip()
        if spec.startswith('Dark.'):
            ref = spec[len('Dark.'):]
            if ref not in colors:
                sys.exit(f'adaptive(dark: Dark.{ref}) 指向 enum Dark 里不存在的常量')
            continue          # ① 已经拿到了同一个值
        try:
            colors[key] = int(spec, 16)
        except ValueError:
            sys.exit(f'解析不了 adaptive(dark: {spec}) —— 改了写法就要同步改本脚本')
    return colors, alphas


def load_light(path=THEME):
    """从 `CodexTheme` 主体取 `adaptive(light: 0x……, dark: …)` 的 light 位。

    ⚠️ 只认**同一行里**写着的 light 字面量 —— `adaptive(light: A, dark: B)` 这种跨行写法
    会漏（当前文件全是单行，真出现跨行就补正则，别让它静默漏项）。
    """
    text = _read_theme(path)
    colors = {k: int(v, 16) for k, v in re.findall(
        r'static let (\w+)\s*=\s*adaptive\(light:\s*0x([0-9A-Fa-f]+)', text)}
    if not colors:
        sys.exit('解析不到任何 adaptive(light:) 字面量（改了写法就要同步改本脚本）')
    return colors


# 面层级链 —— 顺序即语义（冒烟守同一条）。改顺序 = 改层次，必须有意为之。
# ⚠️ **只对暗色成立**：亮色是"白纸 + 灰块"（卡片比纸**暗**），根本没有一条递增链。
#    别把这条链套到亮色上 —— 会得到"从第一天就是红的"假判据（P16 §3 实测过）。
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

# 亮色：**只有地板，没有上限**。上限来自 halation（亮字压暗底才有光晕），
# 深字压浅底没有这个问题 ⇒ 搬暗色的 BANDS 会得到假红（P16 §3）。
#
# ⚠️ 2026-10-14（P16 亮色批次落地：换纸 + 两条文字压深）：原来的第 5 个字段
#    「本轮已知破线」**已整条删除**。它当时是临时的 —— `卡上三级` 4.10 / `muted` 2.55
#    本来就是破的，而那一轮不动亮色板。现在两条都过了（4.57 / 3.21），名单为空。
#    为什么连机制一起删：豁免按**名字**记 ⇒ 谁把 #666E78 退回 #6E7781，门只会打
#    「已知破线」而**不变红**，等于门被悄悄卸掉。**判据必须能变红**，不留后门。
LIGHT_BANDS = [
    ('正文    ', 'textPrimary',   'contentPanel', 4.5),
    ('mono    ', 'textMono',      'contentPanel', 4.5),
    ('次级    ', 'textSecondary', 'contentPanel', 4.5),
    ('三级    ', 'textTertiary',  'contentPanel', 4.5),
    ('卡上正文', 'textPrimary',   'bgCard',       4.5),
    ('卡上mono', 'textMono',      'bgCard',       4.5),
    # 这两条曾是「已知破线」，P16 收掉了 —— 现在它们是**真断言**。
    ('卡上三级', 'textTertiary',  'bgCard',       4.5),
    ('muted   ', 'textMuted',     'contentPanel', 3.0),
    # 侧栏那行版本号小字 (2026-10-16): 它是**第一个**在 bgSidebar 上拿三级文字当正文用的地方
    # —— 上面所有档都算在 contentPanel / bgCard 上, 盖不到"侧栏底 + 三级文字"这个组合。
    ('侧栏三级', 'textTertiary',  'bgSidebar',    4.5),
]

# ---------------------------------------------------------------- P16 工具行

# **一个色可能同时承担两种角色，判据线不同**：
#   · 竖条 / 图标 = **图形元素** —— WCAG 1.4.11 非文字对比度，下限 3.0
#   · kind 标签   = **12pt semibold 文字** —— WCAG AA 正文，下限 4.5
# ⚠️ 所以"它值多少"与"拿它干什么"必须分开说：暗色 `toolError` 3.98 只够当图形，
#    亮色 `thinking` 3.72 反过来只够当图形 —— **两个主题的受害色不同**。
PLATE_TOKENS = ['info', 'thinking', 'toolRunning',
                'toolDone', 'toolError', 'toolQueued', 'blocked']
GRAPHIC_FLOOR = 3.0
TEXT_FLOOR = 4.5

# **政策**：kind 标签"当文字用"的色 —— 真源 = `ToolCallCardView.kindColor`（P16 起恒冷蓝）。
# 往这个名单里加色 = 声明"它要当文字读" ⇒ 它必须同时过 4.5。名单与数值必须一致：
# 名单里有谁、谁就必须过线；不在名单里的色**不许**被当作文字用（那就是本守卫要抓的事）。
KIND_TEXT_TOKENS = ['info']

# 聊天流内嵌面（输出区 / diff 预览）用的底色 —— 真源 = `ToolCallCardView` / `DiffPreviewView`。
# 铁律（P10.8b）：**内嵌面必须与它所在的正文面可分辨，且方向跟着该主题的模型走** ——
#   暗色 "面越高越亮" ⇒ 必须**严格亮于** contentPanel（否则在正文面上挖出近黑洞）
#   亮色 "纸 + 灰块" ⇒ 必须**严格暗于** contentPanel（否则灰块消失，与纸同色）
INLINE_FACE = 'bgCard'


def fmt_band(lo, hi):
    return f'{lo}~{hi}' if hi is not None else f'≥{lo}'


# ---------------------------------------------------------------- 单主题报告

def report_light(colors, argv):
    bad = []
    print('=== 亮色（基准 = contentPanel，只有地板、没有上限）===')
    print(f'  contentPanel #{colors["contentPanel"]:06X}   L={luminance(colors["contentPanel"]):.5f}\n')

    print('  亮色**不守面链单调性** —— 它是"白纸 + 灰块"（卡片比纸暗），没有递增链：')
    for name in CHAIN:
        if name in colors:
            print(f'    {name:14s} #{colors[name]:06X}   L={luminance(colors[name]):.5f}')
    print()

    print('  文字对比度（地板 4.5 / muted 3.0）:')
    for label, fg, bg, lo in LIGHT_BANDS:
        if fg not in colors or bg not in colors:
            continue
        c = contrast(colors[fg], colors[bg])
        ok = c >= lo
        if not ok:
            bad.append(f'亮色 {label.strip()}: {c:.2f}:1 跌破地板 {lo}')
        print(f'    {label} {fg:14s} ← {bg:13s} {c:6.2f}:1   [≥{lo}]  '
              f'{"OK" if ok else "跌破地板"}')
    print()
    return bad


def report_dark(colors, alphas, argv):
    bad = []
    print('=== 暗色（面链 + 文字舒适区，两面都守）===')
    print(f'  contentPanel #{colors["contentPanel"]:06X}   L={luminance(colors["contentPanel"]):.5f}\n')

    print('  面层级（亮度必须严格单调递增）:')
    for name in CHAIN:
        if name not in colors:
            sys.exit(f'链上缺面: {name} —— CodexTheme.swift 与 CHAIN 不同步')
        print(f'    {name:14s} #{colors[name]:06X}   L={luminance(colors[name]):.5f}')
    for a, b in zip(CHAIN, CHAIN[1:]):
        if not luminance(colors[a]) < luminance(colors[b]):
            bad.append(f'面层级: {a} 不比 {b} 暗')
    print()

    print('  文字对比度（基准 = 正文真正坐的那一层）:')
    for label, fg, bg, lo, hi in BANDS:
        c = contrast(colors[fg], colors[bg])
        ok = c >= lo and (hi is None or c <= hi)
        if not ok:
            bad.append(f'{label.strip()}: {c:.2f}:1 越界 [{fmt_band(lo, hi)}]')
        print(f'    {label} {fg:14s} ← {bg:13s} {c:6.2f}:1   [{fmt_band(lo, hi)}]  {"OK" if ok else "越界"}')
    print()

    lift = luminance(colors['contentPanel']) / luminance(colors['bgChat'])
    if lift < 1.5:
        bad.append(f'正文面抬离页面底不足: {lift:.2f}× < 1.5×')
    print(f"  正文面抬升      contentPanel/bgChat = {lift:.2f}×   [≥1.5×]  {'OK' if lift >= 1.5 else '越界'}")

    floor = luminance(colors['bgBase'])
    if floor < 0.004:
        bad.append(f'地板触及纯黑: {floor:.5f} < 0.004')
    print(f"  地板不碰纯黑    bgBase L = {floor:.5f}          [≥0.004]  {'OK' if floor >= 0.004 else '越界'}")

    ha, sa = alphas.get('hoverAlpha'), alphas.get('selectedAlpha')
    if ha is not None and sa is not None:
        if not sa > ha:
            bad.append(f'选中不比悬停实: selected={sa} <= hover={ha}')
        print(f"  选中比悬停实    selected {sa} > hover {ha}      {'OK' if sa > ha else '越界'}")

    ref = contrast(colors['textPrimary'], colors['bgElevated'])
    print(f'  参照 Settings 卡面 (bgElevated) 正文 = {ref:.2f}:1'
          f'  —— 想把正文再往下压，就抬 contentPanel 并连带抬 bgCard/bgElevated/bgPill')
    print()
    return bad, []


# ---------------------------------------------------------------- 板块色 / 内嵌面

def report_plate(theme_name, colors, bad):
    """板块色：同一个色，两种角色两条线。"""
    panel = colors['contentPanel']
    print(f'  板块色（{theme_name}）—— 竖条走图形线 3.0 / kind 标签走文字线 4.5:')
    for name in PLATE_TOKENS:
        if name not in colors:
            continue
        g = contrast(colors[name], panel)
        g_ok = g >= GRAPHIC_FLOOR
        if not g_ok:
            bad.append(f'{theme_name} 板块色 {name}: 图形对比度 {g:.2f}:1 < {GRAPHIC_FLOOR}')
        if name in KIND_TEXT_TOKENS:
            t = g  # 同一个色对同一个底
            t_ok = t >= TEXT_FLOOR
            if not t_ok:
                bad.append(f'{theme_name} 板块色 {name}: 当**文字**用只有 {t:.2f}:1 < {TEXT_FLOOR}')
            role = f'图形 {g:.2f} {"OK" if g_ok else "越界"} · 文字 {t:.2f} {"OK" if t_ok else "越界"}'
        else:
            role = f'图形 {g:.2f} {"OK" if g_ok else "越界"} · **不当文字用**'
        print(f'    {name:12s} #{colors[name]:06X}   {role}')
    print()


def report_inline_face(theme_name, colors, direction, bad):
    """内嵌面 vs 正文面 —— 方向按主题模型走（暗色亮于 / 亮色暗于）。"""
    if INLINE_FACE not in colors:
        return
    fl, pl = luminance(colors[INLINE_FACE]), luminance(colors['contentPanel'])
    ok = fl > pl if direction == 'above' else fl < pl
    word = '严格亮于' if direction == 'above' else '严格暗于'
    if not ok:
        bad.append(f'{theme_name} 内嵌面 {INLINE_FACE} 未{word}正文面 '
                   f'(L {fl:.5f} vs {pl:.5f}) —— 它会与正文面分不开')
    print(f'    {INLINE_FACE:12s} #{colors[INLINE_FACE]:06X} vs contentPanel = '
          f'{pl / fl if fl else 0:.2f}× 亮度比   [必须{word}正文面]  {"OK" if ok else "越界"}')
    print()


# ---------------------------------------------------------------- main

def main(argv):
    # --- 单色查询 ---
    if '--hex' in argv:
        h = argv[argv.index('--hex') + 1].lstrip('#')
        v = int(h, 16)
        print(f'#{v:06X}  L={luminance(v):.5f}')
        return 0

    if '--contrast' in argv:
        a, b = argv[argv.index('--contrast') + 1].split(',')
        ca, cb = int(a.lstrip('#'), 16), int(b.lstrip('#'), 16)
        print(f'#{ca:06X} vs #{cb:06X} → {contrast(ca, cb):.3f}:1')
        return 0

    light_colors = load_light()
    dark_colors, dark_alphas = load_dark()
    want_dark = '--light' not in argv
    want_light = '--dark' not in argv

    print(f'主题真源: {os.path.relpath(THEME, os.getcwd())}\n')

    bad = []

    if want_light:
        bad += report_light(light_colors, argv)
        print('  聊天流内嵌面 —— 亮色："纸 + 灰块" ⇒ 必须**严格暗于**正文面:')
        report_inline_face('亮色', light_colors, 'below', bad)
        report_plate('亮色', light_colors, bad)

    if want_dark:
        b, _ = report_dark(dark_colors, dark_alphas, argv)
        bad += b
        print('  聊天流内嵌面 —— 暗色："面越高越亮" ⇒ 必须**严格亮于**正文面:')
        report_inline_face('暗色', dark_colors, 'above', bad)
        report_plate('暗色', dark_colors, bad)

    if bad:
        print('不变量破了:')
        for b in bad:
            print(f'  - {b}')
        return 1
    print('全部不变量成立')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
