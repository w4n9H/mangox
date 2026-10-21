#!/usr/bin/env python3
r"""markdown 渲染层出图 —— 把"改完长什么样"变成 PNG, 不靠想象。

用途: 动 `MarkdownParser` / `MarkdownView` / `CodeBlockView` / `MarkdownImageView` 之后
跑一次, 看 `/tmp/mangox-md-preview/*.png`。

## 为什么必须有它 (三条都是纸面推不出来的)

1. **`Grid` 在 `ScrollView(.horizontal)` 里的宽度语义** —— 单元格挂 `maxWidth: .infinity`
   时, 列宽到底会不会"均分余量"? `fixedSize(horizontal: true)` 能不能让各列按内容收?
   文档没写清, 猜错的症状是"数字列被撑成一整条空道" —— 只有眼睛能发现。
2. **图片的缩放边界** —— 小图会不会被拉到列宽 (糊)、高图会不会溢出 (撑破布局)。
3. **折行开关** —— 折行态若留在横滚容器里, 开关会"按了没反应"
   (无界宽度提案下永不折行)。折行态是 `@State`, 探针驱动不了它 ⇒
   `CodeBlockView` 留了一个 `initialWrap` 出图缝 (生产恒走默认值)。
4. **列宽到底分给谁** —— 2026-10-20 boss「第一列只放三个字却占了一半」: 铺满之后余量怎么分,
   Grid 默认是**均分**(短列空 80%、长列一直折行)。现在按内容比例 (`TableColumnSizing`);
   因为表格没有竖线、列边界在像素上量不出来, 那段的判据改成**直接断言纯函数读数**(SIZING 行)。

## ⚠️ 曾经的硬限制 (已绕开): `ImageRenderer` 画不出 `ScrollView` 的内容

当年表格块与代码正文出图恒为**空白** (高度对、内容空), 判据只好退成"比高度"。2026-09-24
换成 **`NSHostingView` + 离屏窗口 + `cacheDisplay`** —— 这条路径跑真实的 layout/display
⇒ 两块**都画得出来**, 判据随之升级:
- **窄表**: 量"表格占了多宽" (非背景像素的横向范围) ⇒ 应当**铺满消息列宽**。两列短内容不可能
  有 800 宽, 所以这个数本身就是"铺满了"的证据。⚠️ 容器宽取 `Tune.chatColumnWidth`、内边距取
  `Tune.chatHPadding`, 期望值**由探针自己打印给 python** —— 2026-09-24 之前这里手填 620 / 16,
  在**错误的列宽**下出了 PASS (620−32=588, 而 App 真值是 800 / 48): 判据把自己证明了。
  期望值也不在 python 里重抄一遍 —— 重抄 = 多一份会悄悄漂移的副本。
- **宽表**: `wide-table-420 / wide-900` 两档高度**必须不同**(窄档更高) ⇒ 内容放不下就**折行**,
  不是被裁掉。2026-10-20 之前这里断言的是"两档高度相同 ⇒ 说明内容按内容宽撑开、由外层横滚承担" ——
  boss 报「表格超出的部分看不到了」之后横滚整条拆掉, 这条判据跟着**反向**: 窄档若不更高, 就是又被裁了。

用法: `python3 scripts/diag/md_preview.py`              正常出图 + 机器判据 (退码 0/1)
      `python3 scripts/diag/md_preview.py --counterexample`  造反例: 判据**应当变红**, 见文末
"""

import os
import shutil
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import png_probe   # noqa: E402  同目录; 复用它那套纯标准库 PNG 解码

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WORK = '/tmp/mangox-md-preview-build'
OUT = '/tmp/mangox-md-preview'

# 探针编译的**真源码** —— 不用副本, 画的就是 App 里跑的那一份。
SOURCES = [
    'mangox/Localization/AppLanguage.swift',
    'mangox/Theme/CodexTheme.swift',
    'mangox/Theme/CodexFonts.swift',
    'mangox/Agent/ImagePipeline.swift',
    'mangox/Views/Chat/ImagePresentation.swift',   # 图片呈现单一来源 (正文图块与工具卡共用)
    'mangox/Views/Chat/Markdown/MarkdownParser.swift',
    'mangox/Views/Chat/Markdown/MarkdownView.swift',
    'mangox/Views/Chat/Markdown/MarkdownImageView.swift',
    'mangox/Views/Chat/Markdown/CodeBlockView.swift',
    'mangox/Views/Chat/Markdown/CodeHighlighter.swift',
]

MAIN = r'''
import AppKit
import Foundation
import SwiftUI

let OUT = "/tmp/mangox-md-preview"

// MARK: - 造测试图

/// 两张真图: 1440×720 (读作"要缩到列宽") 与 64×64 ("不许被放大")。
func makePNG(_ path: String, _ w: Int, _ h: Int, bars: Int) {
    let size = NSSize(width: w, height: h)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(srgbRed: 0.14, green: 0.14, blue: 0.17, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    if bars > 0 {
        let gap = CGFloat(w) / CGFloat(bars * 4)
        let bw = gap * 2
        for i in 0..<bars {
            let ratio = Double(i) / Double(max(bars - 1, 1))
            let bh = CGFloat(h) * CGFloat(0.25 + 0.62 * ratio)
            let r = NSRect(x: gap + CGFloat(i) * (bw + gap), y: CGFloat(h) * 0.08,
                           width: bw, height: bh)
            NSColor(srgbRed: 0.87, green: 0.34, blue: 0.26, alpha: 1).setFill()
            r.fill()
        }
    } else {
        NSColor(srgbRed: 0.87, green: 0.34, blue: 0.26, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2)).fill()
    }
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

// MARK: - 渲染

@MainActor
func render(_ label: String, _ content: some View, width: CGFloat) {
    let root = content
        .frame(width: width, alignment: .topLeading)
        .background(CodexTheme.bgChat)
        // 暗色板: `adaptive()` 是 NSColor 动态色, 但离屏渲染时按**环境**的 colorScheme 解析它
        // —— 必须走 environment (`NSAppearance` 那招实测不生效)。
        .environment(\.colorScheme, .dark)

    // ⚠️ 走 `NSHostingView` + 离屏窗口, **不用 `ImageRenderer`** —— 后者画不出 `ScrollView`
    // 的内容 (高度对、内容空, 当年就是这个现象引出的"高度对照"那招)。`NSHostingView` 会跑
    // 真实的 layout/display ⇒ 表格与代码正文**画得出来**, 布局判据可以从"比高度"升级成"量宽度"。
    let host = NSHostingView(rootView: root)
    var height = max(host.fittingSize.height, 1)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                       backing: .buffered, defer: false)   // 不上屏, 只要 layout/display 通道
    win.contentView = host
    // ⚠️ **必须抽 RunLoop, 不能只 layout 一趟**: `MarkdownTableView` 铺满列宽靠"量视口宽 →
    // 回灌 `@State` → 重排"这个过程, 是**两趟布局**; `onPreferenceChange` 要等一次 runloop
    // 才送达。只 layout 一趟的话量到的是第一趟结果 (窄表仍是内容宽), 让人误判成"铺满没生效"。
    // 这不是 App 的病 —— 屏幕上它照常重排, 只有离屏截图会看到第一趟。
    for _ in 0..<4 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
    // ⚠️ 落定之后**必须重新取一次高度**: 列宽回灌会改变折行行数 ⇒ 内容高度跟着变。位图仍按第一趟
    // 的高度建 (偏高) 的话, 空出来的那块是**未初始化的黑色**, `table_extent` 会把整幅图判成"非背景"
    // (2026-10-20 实测: table-shortlong 量出 776 而不是 680, 全是这块黑边闹的)。
    let settled = max(host.fittingSize.height, 1)
    if abs(settled - height) > 0.5 {
        height = settled
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        win.setContentSize(NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    let scale: CGFloat = 2
    let pxW = Int(width * scale)
    let pxH = Int(height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let png: Data = {
              rep.size = NSSize(width: width, height: height)
              host.cacheDisplay(in: host.bounds, to: rep)
              return rep.representation(using: .png, properties: [:])
          }() else {
        print("FAIL - 渲染失败: \(label)")
        return
    }
    withExtendedLifetime(win) {}

    try? png.write(to: URL(fileURLWithPath: "\(OUT)/\(label).png"))
    print(String(format: "wrote %@  %4d x %4d", label + ".png", pxW, pxH))
}

// MARK: - 样张

let chart = "\(OUT)/chart-1440x720.png"
let tiny  = "\(OUT)/icon-64x64.png"

let sample = """
## 渠道日活 (2026-09-18 ~ 09-24)

渠道日活这七天稳步上行, **华为**占比最高, 小米是唯一负增长。

![渠道日活趋势](\(chart))

| 渠道 | 昨日装机 | 7 日均值 | 次日留存 | 环比 |
|---|--:|--:|:-:|--:|
| 华为 | 128,430 | 121,905 | 42.3% | +5.4% |
| 小米 | 96,214 | 90,377 | 39.8% | -2.1% |
| OPPO | 8,430 | 9,905 | 37.5% | +1.2% |
| vivo | 71,558 | 68,120 | 35.2% | +0.4% |

> 结论: 华为 +5.4% 领先, 小米是唯一负增长, 需要看子渠道。

```bash
mysql -h 10.251.72.10 -P 9030 -u readonly -D basic_warehouse -e "SELECT channel, count(DISTINCT device_id) AS dau FROM unicom_user_install_package WHERE dt = '2026-09-23' GROUP BY channel ORDER BY dau DESC LIMIT 20;"
```

- 已排除测试包名
- 口径与昨日一致
"""

let wideTable = """
| 渠道 | 子渠道 | 昨日装机 | 7 日均值 | 环比 | 次日留存 | 7 日留存 | LTV |
|---|---|---|---|---|---|---|---|
| 华为 | 应用市场 | 128,430 | 121,905 | +5.4% | 42.3% | 31.7% | 12.40 |
| 小米 | 应用商店 | 96,214 | 90,377 | -2.1% | 39.8% | 29.4% | 11.05 |
"""

/// 两列短内容 —— 内容宽远小于消息列宽, 专门用来量"铺满" (内容宽不可能到 800)。
let tinyTable = """
| 渠道 | 日活 |
|---|--:|
| 华为 | 128,430 |
| 小米 | 96,214 |
"""

/// boss 那张表: 第一列只有"顶部/一～二/十一～十三"这种三五个字, 第二列是一整句 ——
/// "铺满 + 均分列宽"就是在这里失败的 (三五个字占一半列宽, 一整句被挤成两行)。
let shortLong = """
| 节 | 内容 |
|---|---|
| 顶部 | 一句话结论 + 6 个 KPI 卡 (170 tok/s、JSON 100%、延迟 P50/P90/max) |
| 三 | **13 轮实测全表** (你熟悉的那套字段, 异常行标红) |
| 五 | 延迟 P50/P90/max 分组柱状图 + 建议关 thinking 的对照表 |
"""

let edges = """
![小图不该被放大](\(tiny))

![文件不存在](/tmp/mangox-md-preview/nope-does-not-exist.png)

![外链](https://example.com/chart.png)

![相对路径](out/chart.png)
"""

let longCode = """
mysql -h 10.251.72.10 -P 9030 -u readonly -D basic_warehouse -e "SELECT channel, count(DISTINCT device_id) AS dau FROM unicom_user_install_package WHERE dt = '2026-09-23' GROUP BY channel ORDER BY dau DESC LIMIT 20;"
"""

MainActor.assumeIsolated {
    try? FileManager.default.createDirectory(atPath: OUT, withIntermediateDirectories: true)
    makePNG(chart, 1440, 720, bars: 7)
    makePNG(tiny, 64, 64, bars: 0)

    render("md-560", VStack(alignment: .leading, spacing: 0) {
        MarkdownView(text: sample).padding(16)
    }, width: 560)

    render("md-360", VStack(alignment: .leading, spacing: 0) {
        MarkdownView(text: sample).padding(16)
    }, width: 360)

    let widePad: CGFloat = 16
    render("wide-table-420", VStack(alignment: .leading, spacing: 0) {
        MarkdownView(text: wideTable).padding(widePad)
    }, width: 420)
    // 溢出的判据件: 真折行的话表格右缘 = 容器宽; 若又退回"列不折行", 这里量出来会**大于**期望。
    print("EXPECT wide-table-420 \(420 - 2 * widePad)")

    // 宽度对照 —— 判"放不下时是**折行**还是**被裁**":
    // 同一张宽表在 420 与 900 两档下, **窄档必须更高**(折行) 且两档都**铺满容器**(不溢出)。
    // ⚠️ 这条判据 2026-10-20 反过来了: 以前是"两档高度相同 ⇒ 由外层横滚承担",
    //    而横滚在聊天列里等于"右侧被裁"(boss 实机: 字被切一半) ⇒ 横滚拆掉, 判据随之反向。
    render("wide-900", VStack(alignment: .leading, spacing: 0) {
        MarkdownView(text: wideTable).padding(widePad)
    }, width: 900)
    print("EXPECT wide-900 \(900 - 2 * widePad)")

    // "铺满"的判据件: 两列短内容 —— 内容宽远小于列宽, 量出来是多少就是多少。
    // ⚠️ 容器宽/内边距**一律取 `Tune.*`, 不许手填**: 手填 620 + 自造 16 那版, PASS 是在**错误的
    // 列宽**下拿到的 (620−32=588), 而 App 的真值是 chatContentWidth=800 / chatHPadding=48 ⇒
    // 判据把自己证明了。这里复刻 ChatView 的嵌套顺序:
    //   `.padding(.horizontal, chatHPadding).frame(maxWidth: chatColumnWidth)`
    let colW = Tune.chatColumnWidth                 // 896 = 800 + 2×48
    let colPad = Tune.chatHPadding                  // 48

    render("table-appcol", VStack(alignment: .leading, spacing: 0) {
        MarkdownView(text: tinyTable).padding(.horizontal, colPad).padding(.vertical, 16)
    }, width: colW)
    // 期望值由探针自己报给 python —— 它编译的是真源码, 所以这个数就是 `Tune` 的真值,
    // 不需要在 python 里再抄一份 (抄的那份会悄悄漂移, 且漂移时判据照样绿)。
    print("EXPECT table-appcol \(Tune.chatContentWidth)")

    // 窄窗口档: `maxWidth` 是**上限**不是定值 —— 窗口被挤到 620 时可用宽 = 620 − 2×chatHPadding。
    // "铺满"必须在两档都成立, 否则它只是"在 896 这个特定宽度下碰巧对"。
    let narrowW: CGFloat = 620
    render("table-narrowcol-620", VStack(alignment: .leading, spacing: 0) {
        MarkdownView(text: tinyTable).padding(.horizontal, colPad).padding(.vertical, 16)
    }, width: narrowW)
    print("EXPECT table-narrowcol-620 \(narrowW - 2 * colPad)")

    // boss 2026-10-20 报的那张两列表: 第一列三五个字, 第二列一整句。列宽**按内容比例**之后,
    // 第一列该收到 ~110pt (均分时是 340, 一半空着), 第二列吃掉剩下的 —— 出图看的就是这个。
    render("table-shortlong", VStack(alignment: .leading, spacing: 0) {
        MarkdownView(text: shortLong).padding(.horizontal, colPad).padding(.vertical, 16)
    }, width: colW)
    print("EXPECT table-shortlong \(Tune.chatContentWidth)")

    // 列宽分配是**纯函数**, 像素看不见列边界(表格没有竖线) ⇒ 直接拿它当判据件, 用真实读数断言。
    // 参考: 改动前 Grid 的默认行为是"余量均分" ⇒ 80/400 的两列在 680 里各拿 340 (第一列空 80%)。
    let sizingCases: [([CGFloat], CGFloat)] = [
        ([80, 400], 680),      // 放得下: 按 need 比例放大 (110.4 / 569.6)
        ([40, 60, 80], 680),   // 三列: 比例不被列数整除也要保持
        ([40, 700, 300], 680), // 放不下: 短列保住 40, 只饿死超额的列
        ([300, 700, 300], 680) // 放不下且每列都超额: 全体按比例缩
    ]
    for (need, avail) in sizingCases {
        let widths = TableColumnSizing.widths(need: need, available: avail)
        print("SIZING "
              + need.map { String(format: "%.0f", $0) }.joined(separator: ",")
              + " @" + String(format: "%.0f", avail) + " -> "
              + widths.map { String(format: "%.1f", $0) }.joined(separator: ","))
    }

    render("code-wrap", VStack(alignment: .leading, spacing: 14) {
        Text(verbatim: "wrap OFF (default)").foregroundStyle(CodexTheme.textSecondary)
        CodeBlockView(language: "bash", code: longCode)
        Text(verbatim: "wrap ON").foregroundStyle(CodexTheme.textSecondary)
        CodeBlockView(language: "bash", code: longCode, initialWrap: true)
    }.padding(16), width: 560)

    render("image-edges", VStack(alignment: .leading, spacing: 14) {
        MarkdownView(text: edges, basePath: "/tmp/mangox-md-preview").padding(16)
    }, width: 560)

    print("")
    print("判据:")
    print("  md-560 / md-360   数字列右对齐 (末位对齐); 图不溢出列宽; 窄列里同内容自动收紧")
    print("  table-appcol      表格应**铺满消息列宽** (容器 Tune.chatColumnWidth, 期望 Tune.chatContentWidth)")
    print("  table-narrowcol   窗口被挤窄时同样铺满 (`maxWidth` 是上限, 不是定值)")
    print("  table-shortlong   第一列三五个字 / 第二列一整句 ⇒ 列宽按内容比例 (第一列 ~110pt, 不是均分的 340)")
    print("  SIZING            列宽算法本身: 和 = 可用宽 · 放得下倍率一致 · 放不下时不压缩短列")
    print("  wide-420 vs -900  窄档**必须更高**(折行) 且两档都铺满容器(不溢出) ⇒ 超宽不再被裁")
    print("  code-wrap         ON 必须真的折行 (与 OFF 一样 = 折行态还留在横滚容器里)")
    print("  image-edges       小图不被放大 / 缺文件·外链各有说明行 / 相对路径按 basePath 解析")
    print("")
    print("⚠️ 动画件 (ProgressView 这类) 在离屏渲染里画不出来, 那不是 App 的病。")
}
'''


def counterexample_source(work):
    """造反例: 把单元格改回「列不折行」(`fixedSize(horizontal: true)`) —— 那正是 boss 2026-10-20
    报的那个形态: 内容按自身宽度撑开、右侧被容器裁掉 (探针实测同一条表在 680 与 1000 两档下
    **总高完全相同**, 一个字都没折行)。

    判据若在这种情况下**不变红**, 它就是个摆设 —— "门的判据本身可以是错的, 只能靠造反例抓"。
    编译的是**副本**, 产品源码一个字节都不动。
    """
    src = os.path.join(ROOT, 'mangox/Views/Chat/Markdown/MarkdownView.swift')
    with open(src, encoding='utf-8') as handle:
        text = handle.read()
    needle = ('            .foregroundStyle(isHeader ? CodexTheme.textPrimary '
              ': CodexTheme.textSecondary)\n')
    assert text.count(needle) == 1, \
        '造反例失配: 表格单元格的修饰链改了形态, 请同步本函数'
    copy = os.path.join(work, 'MarkdownView.swift')
    with open(copy, 'w', encoding='utf-8') as handle:
        handle.write(text.replace(needle,
                                  needle + '            .fixedSize(horizontal: true, vertical: false)\n',
                                  1))
    return copy


def png_size(path):
    """只读 IHDR 里的宽高 —— 为量一张图的高度去解整张 PNG (纯 Python 逐像素) 不值。"""
    with open(path, 'rb') as handle:
        head = handle.read(24)
    return struct.unpack('>II', head[16:24])


def table_extent(path):
    """表格占了多宽: 非背景像素的横向范围 (px, 含左右边界各一个像素)。

    "非背景"是以**整张图最高频的那个颜色**为基准判的 —— 出图根挂着 `bgChat`, 它必然是
    最高频色; 表格自己带 `bgCard` 底色 + 边框, 所以每一行都会留下痕迹。
    """
    w, h, ch, px = png_probe.load_png(path)
    # 背景取**角上那一像素** —— 不能用"最高频色": 表格铺满时它自己的底色反而成了最高频,
    # 于是整张图被判成"非背景", 量出 620 而不是 588 (实测踩过)。角上必定是出图根挂的 `bgChat`。
    bg = tuple(px[0:3])

    def differs(c):
        return any(abs(c[i] - bg[i]) > 6 for i in range(3))

    best = None
    for y in range(h):
        lo = hi = None
        for x in range(w):
            o = (y * w + x) * ch
            if differs(tuple(px[o:o + 3])):
                if lo is None:
                    lo = x
                hi = x
        if lo is not None and (best is None or hi - lo > best[1] - best[0]):
            best = (lo, hi)
    return best


def main():
    # `--counterexample`: 造反例自证 —— 表格几何层换 `.background`, 复现 `viewport` 恒 0。
    counterexample = '--counterexample' in sys.argv
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(WORK, 'main.swift'), 'w', encoding='utf-8') as handle:
        handle.write(MAIN)

    sources = list(SOURCES)
    if counterexample:
        sources = [counterexample_source(WORK) if s.endswith('MarkdownView.swift') else s
                   for s in sources]
        print('⚠️ 造反例模式: 单元格改回"列不折行" (应复现右侧被裁)')

    binary = os.path.join(WORK, 'probe')
    cmd = ['xcrun', 'swiftc', '-O', 'main.swift']
    cmd += [os.path.join(ROOT, s) for s in sources]
    cmd += ['-o', binary]
    built = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL - 编译探针失败')
        print((built.stdout or built.stderr)[-4000:])
        return 1

    ran = subprocess.run([binary], capture_output=True, text=True)
    for line in ran.stdout.splitlines():
        if 'CoreText note' in line or 'CTFontLogSystemFontNameRequest' in line:
            continue
        if line.startswith('EXPECT '):    # 期望值由下面的量宽段消费, 不重复打印
            continue
        print(line)
    if ran.returncode != 0:
        print((ran.stderr or '')[-2000:])
        return ran.returncode

    # ---------- 机器判据 (退码体现: 以前恒 `return 0`, FAIL 只活在文本里) ----------
    failures = []

    # 期望值由探针打印 (`EXPECT <label> <pt>`) —— 它编译的是真源码, 所以这就是 `Tune.*` 的真值。
    expects = {}
    for line in (ran.stdout or '').splitlines():
        if line.startswith('EXPECT '):
            _, label, pt = line.split()
            expects[label] = float(pt)

    # ① 铺满: 表格非背景像素的横向范围 == 消息内容宽 (宽列 + 窄列两档都要成立)
    print('')
    for label, want in sorted(expects.items()):
        path = os.path.join(OUT, label + '.png')
        if not os.path.exists(path):
            print('FAIL - 量宽: %s 没有出图' % label)
            failures.append(label)
            continue
        lo, hi = table_extent(path)
        got = (hi - lo + 1) / 2.0
        bad = abs(got - want) > 2
        if bad:
            failures.append(label)
        print('%s - 量宽: %-22s 横向 %6.1f..%6.1f pt, 宽 %6.1f pt (期望 %.0f)'
              % ('FAIL' if bad else 'PASS', label, lo / 2.0, hi / 2.0, got, want))

    if not expects:
        # 判据件被删 / 改名 —— "静默通过"是最坏的结果, 必须响。
        print('FAIL - 量宽: 探针没打印任何 EXPECT 行 (判据件丢了?)')
        failures.append('no-expect')

    # ② 列宽分配 = 按内容比例 (`TableColumnSizing` 是纯函数, 直接断言它的读数)。
    #    像素判据看不见列边界 (表格没有竖线), 但这段算法是确定的 —— 用它自己的读数当判据件,
    #    "改动前 Grid 均分"这种情况会立刻变红 (80 与 400 各拿 340 ⇒ 放大倍率 4.25 vs 0.85)。
    print('')
    sizing = []
    for line in (ran.stdout or '').splitlines():
        if not line.startswith('SIZING '):
            continue
        head, tail = line[len('SIZING '):].split(' -> ')
        need_part, avail_part = head.split(' @')
        sizing.append(([float(v) for v in need_part.split(',')],
                       float(avail_part),
                       [float(v) for v in tail.split(',')]))
    if len(sizing) != 4:
        print('FAIL - 列宽: SIZING 判据件缺行 (拿到 %d 组, 期望 4)' % len(sizing))
        failures.append('sizing-missing')
    for need, avail, widths in sizing:
        fits = sum(need) <= avail
        share = avail / len(need)
        # ① 总和 = 可用宽 (否则表格铺不满 / 溢出); ② 放得下时各列放大倍率**一致** (这才叫按比例);
        # ③ 放不下时, 没超过均分额的列**不许被压缩** (短列被长列挤到折行就不算"按内容分").
        ok_sum = abs(sum(widths) - avail) <= 0.6
        ok_ratio = (not fits) or (max(w / n for w, n in zip(widths, need))
                                  - min(w / n for w, n in zip(widths, need)) <= 0.02)
        ok_floor = all(w >= n - 0.01 for w, n in zip(widths, need) if n <= share)
        bad = not (ok_sum and ok_ratio and ok_floor)
        if bad:
            failures.append('sizing')
        print('%s - 列宽: need[%s] @%.0f -> [%s] (和 %.1f%s)'
              % ('FAIL' if bad else 'PASS',
                 ','.join('%.0f' % n for n in need), avail,
                 ','.join('%.1f' % w for w in widths), sum(widths),
                 '' if fits else ', 放不下'))

    # ③ 宽表: **窄档必须更高** —— 放不下就该折行。
    #    2026-10-20 之前这里断言的是"两档高度相同 ⇒ 内容按内容宽撑开、由外层横滚承担";
    #    横滚整条拆掉之后这条**反向**: 窄档若不高出几十像素, 就是内容又被裁了(那正是 boss 报的病)。
    heights = {}
    for label in ('wide-table-420', 'wide-900'):
        path = os.path.join(OUT, label + '.png')
        if os.path.exists(path):
            heights[label] = png_size(path)[1]
    if len(heights) == 2:
        wrapped = (heights['wide-table-420'] - heights['wide-900']) > 2
        if not wrapped:
            failures.append('wide-wrap')
        print('%s - 宽表: 高度 %s (窄档必须更高 ⇒ 折行了; 一样高 = 又被裁)'
              % ('PASS' if wrapped else 'FAIL',
                 ', '.join('%s=%d' % kv for kv in sorted(heights.items()))))
    else:
        print('FAIL - 宽表: 缺图 %s' % sorted({'wide-table-420', 'wide-900'} - set(heights)))
        failures.append('wide-missing')

    print('')
    if counterexample:
        # 造反例下判据**必须变红** —— 变红才说明它真能抓到"没铺满"; 不变红 = 摆设。
        if failures:
            print('造反例: PASS - 判据成功变红 (%s) ⇒ 它确实能抓到"超宽被裁"' % ', '.join(failures))
            return 0
        print('造反例: FAIL - 判据没变红, 抓不到这个 bug ⇒ 判据形同摆设')
        return 1
    print('结论: %s' % ('ALL PASS' if not failures else 'FAILED -> ' + ', '.join(failures)))
    return 0 if not failures else 1


if __name__ == '__main__':
    sys.exit(main())
