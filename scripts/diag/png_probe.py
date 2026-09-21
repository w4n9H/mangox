#!/usr/bin/env python3
"""截图取色 + WCAG 对比度：把「看着累 / 看不清 / 层次糊」这类主观感受变成可判定的数字。

来源：2026-09-21 暗色主题反馈"看着眼睛很累"。肉眼只能说"黑"，量完才定位到
**近纯黑底 + 近纯白正文 = 16.6:1** 的超高对比（大段正文会光晕）。全程纯标准库，
不需要 Pillow（本机没装也能跑）。

用法:
  png_probe.py <screenshot.png>                 # 尺寸 / 全局主色 / 相对坐标采样 / 竖向扫描
  png_probe.py <screenshot.png> --scan 0.065    # 指定 x 做竖向扫描（找高亮带/分隔线）
  png_probe.py --contrast C8C8D0,191920         # 直接算两色的 WCAG 对比度
"""
import sys
import zlib
import struct
from collections import Counter


# ---------- 极简 PNG 解码（8-bit, 非隔行）----------

def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)


def load_png(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', '不是 PNG'
    i, idat, w, h, ctype = 8, b'', None, None, None
    while i < len(data):
        ln = struct.unpack('>I', data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + ln]
        if typ == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            assert depth == 8 and interlace == 0, f'不支持 depth={depth} interlace={interlace}'
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
        i += 12 + ln
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * ch
    out, prev, pos = bytearray(), bytearray(stride), 0
    for _ in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos + stride]); pos += stride
        if f == 1:
            for x in range(ch, stride):
                line[x] = (line[x] + line[x - ch]) & 0xFF
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif f == 3:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xFF
        elif f == 4:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0
                c = prev[x - ch] if x >= ch else 0
                line[x] = (line[x] + _paeth(a, prev[x], c)) & 0xFF
        out += line
        prev = line
    return w, h, ch, out


# ---------- WCAG ----------

def luminance(rgb):
    def f(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (f(v) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def hx(s):
    s = s.strip().lstrip('#')
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


# ---------- 采样 ----------

def probe(path, scan_x=None):
    w, h, ch, px = load_png(path)
    print(f'尺寸 {w}x{h} · 通道 {ch}')

    def at(x, y, box=4):
        c = Counter()
        for dy in range(-box, box + 1):
            for dx in range(-box, box + 1):
                xx, yy = x + dx, y + dy
                if 0 <= xx < w and 0 <= yy < h:
                    o = (yy * w + xx) * ch
                    c[tuple(px[o:o + 3])] += 1
        return c.most_common(1)[0][0]

    print('\n=== 全局高频色 (前 10) ===')
    c = Counter()
    for y in range(0, h, 3):
        for x in range(0, w, 3):
            o = (y * w + x) * ch
            c[tuple(px[o:o + 3])] += 1
    tot = sum(c.values())
    for rgb, n in c.most_common(10):
        print('  #%02X%02X%02X  %5.1f%%  亮度 %.4f' % (*rgb, 100.0 * n / tot, luminance(rgb)))

    if scan_x is not None:
        print(f'\n=== 竖向扫描 x={scan_x:.3f} (色带变化处) ===')
        prev = None
        for i in range(0, 101):
            y = int(i / 100 * (h - 1))
            cur = '#%02X%02X%02X' % at(int(scan_x * (w - 1)), y)
            if cur != prev:
                print(f'  y={i:>3}%  {cur}')
                prev = cur

    print('\n=== 相对坐标采样 ===')
    for name, fx, fy in [('左上', .05, .05), ('主区', .6, .15), ('正文', .5, .5),
                         ('底部', .5, .97), ('右下', .95, .95)]:
        rgb = at(int(fx * (w - 1)), int(fy * (h - 1)))
        print('  %-4s (%.2f,%.2f) → #%02X%02X%02X' % (name, fx, fy, *rgb))

    print('\n判读: 正文对比度落在 9~12.5 舒适；>15 大段正文会光晕（累眼）；'
          '背景相对亮度 <0.002 ≈ 纯黑，层次只能靠"更黑"表达 = 看不出层级。')


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__); return 2
    if args[0] == '--contrast':
        a, b = args[1].split(',')
        ca, cb = hx(a), hx(b)
        print('#%02X%02X%02X 对 #%02X%02X%02X → %.2f:1' % (*ca, *cb, contrast(ca, cb)))
        return 0
    scan_x = None
    if '--scan' in args:
        scan_x = float(args[args.index('--scan') + 1])
    probe(args[0], scan_x)
    return 0


if __name__ == '__main__':
    sys.exit(main())
