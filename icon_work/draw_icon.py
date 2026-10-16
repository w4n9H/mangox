#!/usr/bin/env python3
"""MangoX 图标候选 —— 纯程序化绘制 (精确 macOS 网格, 不花生成模型额度)。

跑法:
    /Users/moofs/anaconda3/bin/python3 icon_work/draw_icon.py
  ⚠️ 需要 numpy + Pillow; 本机默认那个 python3 **没有 PIL**, anaconda 那个才有。

产物 (写到 icon_work/candidates/, 目录会自动建):
    A.png  暖橙渐变底 + 奶油芒果, 无 X        —— 缩到 16px 仍认得出 (最安全)
    B.png  米白底 + 品牌橙立体芒果 + 圆头 X    —— 最小改动版, 保留原来的语言
    C.png  深底 + 品牌橙芒果                  —— Dock 里最跳 (2026-10-16 boss 选的就是它)
    sheet.png  三者 × 256/128/64/32/16 接触表

选定之后上线:
    cp icon_work/candidates/C.png icon_work/AppIcon.png && bash scripts/gen-icon.sh
  ⚠️ `icon_work/` **不在 git 里** (gitignore) ⇒ 覆盖 AppIcon.png 没有 git 回退;
     唯一退路是 `AppIcon_thin.png` (旧图的逐字节副本), **别当冗余删掉**。
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048                      # 超采样画布 (出 1024 ⇒ 2x)
BOX = (200, 200, 1848, 1848)  # macOS 图标网格: 1024 画布留 100 边距 ⇒ squircle 824²
OUT = Path(__file__).resolve().parent / 'candidates'
YY, XX = np.mgrid[0:S, 0:S].astype(float)


def hexc(h):
    return np.array([(h >> 16) & 255, (h >> 8) & 255, h & 255], float)


def grad(c0, c1, ang=135.0):
    a = np.deg2rad(ang)
    d = XX * np.cos(a) + YY * np.sin(a)
    d = (d - d.min()) / (d.max() - d.min())
    return c0[None, None, :] * (1 - d[..., None]) + c1[None, None, :] * d[..., None]


def squircle(box, n=5.0):
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    a, b = (x1 - x0) / 2, (y1 - y0) / 2
    return ((np.abs((XX - cx) / a) ** n + np.abs((YY - cy) / b) ** n) <= 1.0).astype(np.uint8) * 255


def bez(p0, p1, p2, p3, n=140):
    t = np.linspace(0, 1, n)[:, None]
    p0, p1, p2, p3 = (np.array(p, float) for p in (p0, p1, p2, p3))
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3


def path(segs, box, rot=0.0):
    P = np.concatenate([bez(*s) for s in segs])
    x0, y0, x1, y1 = box
    P[:, 0] = x0 + P[:, 0] * (x1 - x0)
    P[:, 1] = y0 + P[:, 1] * (y1 - y0)
    if rot:
        c = np.array([(x0 + x1) / 2, (y0 + y1) / 2])
        a = np.deg2rad(rot)
        R = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
        P = (P - c) @ R.T + c
    return P


def pmask(pts):
    im = Image.new('L', (S, S), 0)
    ImageDraw.Draw(im).polygon([(float(x), float(y)) for x, y in pts], fill=255)
    return np.array(im, np.uint8)


def shadow(mask, dx, dy, blur, strength):
    m = Image.fromarray(mask).filter(ImageFilter.GaussianBlur(blur))
    out = Image.new('L', (S, S), 0)
    out.paste(m, (dx, dy))          # paste 会裁掉溢出, 不像 np.roll 那样环绕
    return np.array(out, float) / 255.0 * strength


def highlight(cx, cy, r, amt):
    return np.clip(1 - np.hypot(XX - cx, YY - cy) / r, 0, 1) ** 2 * amt


def compose(bg, sq, layers):
    out = bg.copy()
    for color, m in layers:
        col = color if (isinstance(color, np.ndarray) and color.ndim == 3) \
            else np.array(color, float)[None, None, :]
        out = out * (1 - m[..., None]) + col * m[..., None]
    rgba = np.dstack([out, sq.astype(float)]).clip(0, 255).astype(np.uint8)
    return Image.fromarray(rgba, 'RGBA')


# 果身: 右上肩宽、向左下收成一个软尖 —— 不对称, 才读得出"芒果"而不是"蛋"
FRUIT = [
    ((0.44, 0.06), (0.80, 0.02), (1.02, 0.24), (1.00, 0.50)),
    ((1.00, 0.50), (0.98, 0.78), (0.78, 1.00), (0.50, 1.00)),
    ((0.50, 1.00), (0.32, 1.02), (0.10, 0.96), (0.03, 0.82)),
    ((0.03, 0.82), (0.01, 0.64), (0.13, 0.36), (0.24, 0.17)),
    ((0.24, 0.17), (0.30, 0.07), (0.36, 0.02), (0.44, 0.06)),
]
# 叶片: 中间饱满的杏仁形 (上一版 0.6~0.72 的细月牙 = 一根头发)
LEAF = [
    ((0.00, 0.52), (0.20, 0.04), (0.62, -0.06), (1.00, 0.06)),
    ((1.00, 0.06), (0.74, 0.58), (0.34, 0.80), (0.00, 0.52)),
]

FB = {'A': (560, 450, 1420, 1570), 'B': (470, 430, 1250, 1440), 'C': (560, 450, 1420, 1570)}
LB = {'A': (860, 175, 1660, 480), 'B': (780, 215, 1520, 500), 'C': (860, 175, 1660, 480)}


def mark(k, frot=-6, lrot=-10):
    return pmask(path(FRUIT, FB[k], rot=frot)), pmask(path(LEAF, LB[k], rot=lrot))


def render_A():
    """暖橙渐变底 + 奶油芒果 (无 X) —— 缩到 16px 仍认得出。"""
    sq = squircle(BOX)
    bg = grad(hexc(0xFFB055), hexc(0xC93A22), 135)
    fm, lm = mark('A')
    sh = shadow(np.maximum(fm, lm), 10, 22, 36, 0.20)
    fa = fm.astype(float) / 255
    return compose(bg, sq, [
        (np.array([0, 0, 0], float), sh * (sq.astype(float) / 255)),
        (hexc(0x2F7D4B), lm.astype(float) / 255),
        (grad(hexc(0xFFFDF7), hexc(0xFFE0BE), 125), fa),
    ])


def render_B():
    """米白底 + 品牌橙立体芒果 + 圆头 X —— 最小改动版。"""
    sq = squircle(BOX)
    bg = np.ones((S, S, 3)) * hexc(0xF4EFE7)[None, None, :]
    fm, lm = mark('B')
    sh = shadow(np.maximum(fm, lm), 20, 32, 58, 0.16)
    fg = grad(hexc(0xF9A83F), hexc(0xDD5742), 120)
    fa = fm.astype(float) / 255
    xim = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(xim)
    w = 112
    for a, b in (((1290, 1290), (1560, 1560)), ((1560, 1290), (1290, 1560))):
        d.line([a, b], fill=255, width=w)
        for c in (a, b):
            d.ellipse([c[0] - w / 2, c[1] - w / 2, c[0] + w / 2, c[1] + w / 2], fill=255)
    return compose(bg, sq, [
        (np.array([90, 70, 50], float), sh * (sq.astype(float) / 255)),
        (hexc(0x4C8B4A), lm.astype(float) / 255),
        (fg, fa),
        (np.array([255, 255, 255], float), fa * highlight(760, 700, 500, 0.26)),
        (hexc(0x24292F), np.array(xim, np.uint8).astype(float) / 255),
    ])


def render_C():
    """深底 + 品牌橙芒果 —— 在 Dock 里最跳的那个。"""
    sq = squircle(BOX)
    bg = grad(hexc(0x33241C), hexc(0x1A1210), 145)
    fm, lm = mark('C')
    fg = grad(hexc(0xFFA83C), hexc(0xD8452C), 118)
    return compose(bg, sq, [
        (hexc(0x3F8F52), lm.astype(float) / 255),
        (fg, fm.astype(float) / 255),
        (np.array([255, 255, 255], float), fm.astype(float) / 255 * highlight(850, 780, 560, 0.18)),
    ])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn in (('A', render_A), ('B', render_B), ('C', render_C)):
        fn().resize((1024, 1024), Image.LANCZOS).save(str(OUT / f'{name}.png'))

    sizes = [256, 128, 64, 32, 16]
    pad, band = 26, 256
    sheet = Image.new('RGB', (sum(sizes) + pad * (len(sizes) + 1), band * 3 + pad * 4), (232, 232, 236))
    y = pad
    for name in 'ABC':
        ic = Image.open(str(OUT / f'{name}.png')).convert('RGBA')
        x = pad
        for s in sizes:
            th = ic.resize((s, s), Image.LANCZOS)
            sheet.paste(th, (x, y + (band - s) // 2), th)
            x += s + pad
        y += band + pad
    sheet.save(str(OUT / 'sheet.png'))
    print('OK ->', OUT)


if __name__ == '__main__':
    main()
