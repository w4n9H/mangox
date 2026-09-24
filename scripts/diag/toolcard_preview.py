#!/usr/bin/env python3
r"""工具卡出图 —— 把"三拍改完长什么样"变成 PNG, 不靠想象。

用途: 动 `ToolCallCardView` / `ToolOutputImages` / `ImagePresentation` / `ToolCall` 之后
跑一次, 看 `/tmp/mangox-toolcard-preview/*.png`。

## 它专门验三件纸面推不出来的事

1. **"不谎报"到底改了观感没有** —— 旧版 `kindFor` 的 `default` 把任何未登记工具一律标成
   `read`: 装了 web-search 这类扩展后, 标签**和颜色一起错**。`kind-compare.png` 把旧落点
   (`.read`) 与新落点 (`.other` + 真名占 title + 首参退 command) **同一批数据各渲一遍**,
   是真渲染、不是示意图。
2. **输出区的三态会不会互相打架** —— 纯文本 (长/短) / 文本+图 / 纯图。判"纯图卡的
   `hasLongOutput` 不出现箭头"和"纯图卡不空转"只能看。
3. **内置工具没被 `.other` 误伤** —— 归类色带一横排看过去, read 组是不是还是 info 蓝、
   edit/write 是不是还是完成绿。

## ⚠️ 一条硬限制与它的绕法: 走 `NSHostingView`, 不走 `ImageRenderer`

`ImageRenderer` **画不出 `ScrollView` 的内容** (高度对、内容空) ⇒ 缩略条直接用真视图出图
会是空白 (第一版就白出了一张空条)。`md_preview.py` 当初的对策是给 `CodeBlockView` 留
`initialWrap` 出图缝; 这里**不留缝** —— 换成 `NSHostingView` + 离屏窗口 + `cacheDisplay`,
这条路径会跑**真实的 layout/display**, 横滚内容照画。
⇒ 判据: **要预览的东西画不出来, 先换渲染路径, 再考虑动产品代码。**

## ⚠️ 另一条: 动画件画不出来

`running` 相态的转圈 (`ProgressView`) 在离屏渲染里是空的。那不是 App 的病。

用法: `python3 scripts/diag/toolcard_preview.py`
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WORK = '/tmp/mangox-toolcard-preview-build'
OUT = '/tmp/mangox-toolcard-preview'

# 探针编译的**真源码** —— 不用副本, 画的就是 App 里跑的那一份。
SOURCES = [
    'mangox/Localization/AppLanguage.swift',
    'mangox/Theme/CodexTheme.swift',
    'mangox/Theme/CodexFonts.swift',
    'mangox/Theme/StatusPalette.swift',
    'mangox/Agent/ImagePipeline.swift',
    'mangox/Models/ToolCall.swift',
    'mangox/Views/Chat/ImagePresentation.swift',
    'mangox/Views/Chat/ToolOutputImages.swift',
    'mangox/Views/Chat/ToolCallCardView.swift',
]

MAIN = r'''
import AppKit
import Foundation
import SwiftUI

let OUT = "/tmp/mangox-toolcard-preview"

// MARK: - 造测试图

/// 柱状图 (像一张"渠道日活趋势")。
func makeChart(_ path: String, _ w: Int, _ h: Int, bars: Int) {
    let size = NSSize(width: w, height: h)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
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
    img.unlockFocus()
    save(img, path)
}

/// 截图感: 顶栏 + 若干内容条。
func makeShot(_ path: String, _ w: Int, _ h: Int) {
    let size = NSSize(width: w, height: h)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
    NSRect(x: 0, y: h - h / 8, width: w, height: h / 8).fill()
    for i in 0..<6 {
        let y = Double(h) * 0.72 - Double(i) * Double(h) * 0.10
        let r = NSRect(x: Double(w) * 0.07, y: y,
                       width: Double(w) * (0.30 + 0.09 * Double(i % 3)), height: Double(h) * 0.045)
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.54, alpha: 1).setFill()
        r.fill()
    }
    img.unlockFocus()
    save(img, path)
}

func save(_ img: NSImage, _ path: String) {
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

    // `NSHostingView` + 离屏窗口, **不用** `ImageRenderer` —— 后者画不出 `ScrollView` 的内容。
    let host = NSHostingView(rootView: root)
    let height = max(host.fittingSize.height, 1)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    // 离屏窗口 (不 orderFront, 不上屏): 有 window 才拿得到完整的 layout/display 通道。
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                       backing: .buffered, defer: false)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()

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

// MARK: - 标注件

func caption(_ main: String, _ sub: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: main)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CodexTheme.textSecondary)
        Text(verbatim: sub)
            .font(.system(size: 11))
            .foregroundStyle(CodexTheme.textMuted)
    }
}

func sample(_ label: String, _ tool: ToolCall) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(verbatim: label)
            .font(.system(size: 11))
            .foregroundStyle(CodexTheme.textMuted)
        ToolCallCardView(tool: tool)
    }
}

/// `TrajectoryView.swift:627-637` `kindChip` 的**忠实复制** (那边是 private, 探针够不着)。
/// 轨迹页的工具 chip **吃 `kind.defaultColor`** —— 卡片不这样, 见下面第一段的注。
func kindChip(_ label: String, _ color: Color) -> some View {
    Text(label)
        .font(.system(size: 9, weight: .bold))
        .tracking(0.5)
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .cornerRadius(4)
        .frame(minWidth: 30)
}

// MARK: - 样张数据 (真场景: 渠道日活)

let chart = "\(OUT)/chart.png"
let shot  = "\(OUT)/shot.png"

// bash 的一长段输出 —— 长到必须出展开箭头。
let bashOut = """
channel     dau        wow
华为        128,430    +5.4%
小米         96,214    -2.1%
OPPO         8,430    +1.2%
vivo        71,558    +0.4%
荣耀         44,912    +3.8%
realme      19,305    -0.7%
一加          6,118    +0.1%
"""

MainActor.assumeIsolated {
    try? FileManager.default.createDirectory(atPath: OUT, withIntermediateDirectories: true)
    makeChart(chart, 1440, 720, bars: 7)
    makeShot(shot, 1280, 800)

    // ── A. 不谎报: 同一批陌生工具, 旧落点 vs 新落点 ──────────────────────────
    let strangers: [(String, String)] = [
        ("web_search", "query=渠道日活 环比"),
        ("todo_write", "todos=4"),
        ("fetch_url",  "url=https://docs.example.com/pi"),
    ]

    render("kind-compare", VStack(alignment: .leading, spacing: 18) {
        caption("旧: `kindFor` 的 default 一律落 READ",
                "同一批陌生工具全读作 READ —— 谎报在**文字**上; 落库的 kind 也已失真, 事后分不出")
        ForEach(strangers, id: \.0) { name, _ in
            sample("\(name)  ·  旧渲染", ToolCall(kind: .read, title: name, command: nil, phase: .done))
        }

        caption("新: 中性 OTHER + 真名占 title + 首个标量参数退到 command",
                "command 走 `cmd ?? path ?? firstScalarArg`; 后者按 key 排序取首个 ⇒ 同一调用重放两次必得同一结果 (卡头不跳)")
        ForEach(strangers, id: \.0) { name, args in
            sample("\(name)  ·  新渲染", ToolCall(kind: .other, title: name, command: args, phase: .done))
        }

        caption("⚠️ 颜色错在**轨迹页**, 不在卡片",
                "卡片标签色 = `railColor` = f(相态) ⇒ 上面两组同为 done, 颜色本来就一样。轨迹页 chip 吃 `kind.defaultColor`, 那里才变色")
        HStack(spacing: 10) {
            kindChip("READ", ToolKind.read.defaultColor)
            kindChip("OTHER", ToolKind.other.defaultColor)
            Text(verbatim: "← 同一个陌生工具: 旧 chip / 新 chip")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
        }

        caption("留位: delegate",
                "pi 0.85.1 内置 8 个工具无 delegate, 当前零生产方 —— 保留只为让扩展的子代理工具有确定归处")
        sample("delegate  ·  新渲染",
               ToolCall(kind: .delegate, title: "code-reviewer", command: "task=审一遍传输层", phase: .done))
    }, width: 620)

    // ── B. 输出区三态 ────────────────────────────────────────────────────────
    render("output-three", VStack(alignment: .leading, spacing: 18) {
        caption("① 纯文本 · 长", "有展开箭头 (折叠态只露 2 行); 复制键复制全部, 不受折叠影响")
        sample("bash  ·  done 6.5s", ToolCall(
            kind: .bash, title: "mysql",
            command: "-h 10.251.72.10 -D basic_warehouse", details: [ToolDetail("输出", bashOut)],
            phase: .done, durationMs: 6533))

        caption("② 纯文本 · 短", "没有箭头 —— 一行放得下就不给假控件")
        sample("grep  ·  done 128ms", ToolCall(
            kind: .grep, title: "kindFor", command: "mangox/Agent/PiRpcTransport.swift",
            details: [ToolDetail("输出", "PiRpcTransport.swift:412:    private func kindFor(_ name: String)")],
            phase: .done, durationMs: 128))

        caption("③ 纯图 (典型: read 一张截图)", "无箭头、无文本行, 只出缩略条 —— 复制键把路径写进剪贴板, 不空转")
        sample("read  ·  done 214ms",
               ToolCall(kind: .read, title: "/tmp/mangox-toolcard-preview/shot.png",
                        details: [], phase: .done, durationMs: 214, imagePaths: [shot]))

        caption("④ 文本 + 图", "文本行在上、缩略条在下; 图与正文图片块共用同一套路径解析 / 大图上限")
        sample("bash  ·  done 4.1s", ToolCall(
            kind: .bash, title: "python3 plot.py", command: "--channel all",
            details: [ToolDetail("输出", "wrote /tmp/mangox-toolcard-preview/chart.png")],
            phase: .done, durationMs: 4120, imagePaths: [chart, shot]))

        caption("⑤ 读不到的文件", "照实显示文件名 —— 不静默留白 (留白会被当成渲染 bug)")
        sample("read  ·  done 12ms",
               ToolCall(kind: .read, title: "/tmp/mangox-toolcard-preview/nope.png",
                        details: [], phase: .done, durationMs: 12,
                        imagePaths: ["/tmp/mangox-toolcard-preview/nope.png"]))

        caption("⑥ 失败卡", "失败也是 `AgentToolResult` 同一形状 ⇒ details 里本来就有**真错误文本**")
        sample("bash  ·  error", ToolCall(
            kind: .bash, title: "mysql",
            command: "-h 10.251.72.10 -D basic_warehouse",
            details: [ToolDetail("输出", "ERROR 1045 (28000): Access denied for user 'readonly'@'10.251.207.244'")],
            phase: .error("exit 1")))
    }, width: 620)

    // ── C. 相态 + 内置归类色带 ──────────────────────────────────────────────
    render("phase-and-kind", VStack(alignment: .leading, spacing: 18) {
        caption("相态", "badge 在右; 完成态工具标签素色 (Codex 风格, 不上彩色)")
        sample("queued", ToolCall(kind: .bash, title: "mysql", command: "-e \"SELECT 1\"", phase: .queued))
        sample("running", ToolCall(kind: .bash, title: "mysql", command: "-e \"SELECT 1\"", phase: .running))
        sample("done · 6.5s", ToolCall(kind: .bash, title: "mysql", command: "-e \"SELECT 1\"",
                                      phase: .done, durationMs: 6533))
        sample("done · 420ms", ToolCall(kind: .bash, title: "mysql", command: "-e \"SELECT 1\"",
                                        phase: .done, durationMs: 420))
        sample("error", ToolCall(kind: .bash, title: "mysql", command: "-e \"SELECT 1\"",
                                 phase: .error("exit 137 (killed)")))

        caption("归类调色板 (`kind.defaultColor`)",
                "⚠️ 这是**轨迹页 chip** 的取色; 卡片上的标签色来自相态 (`railColor`), 不取这里")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach([ToolKind.bash, .read, .grep, .find, .ls, .edit, .write], id: \.self) { k in
                    Text(k.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(k.defaultColor)
                        .frame(minWidth: 52, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                ForEach([ToolKind.image, .search, .fetch, .delegate, .other], id: \.self) { k in
                    Text(k.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(k.defaultColor)
                        .frame(minWidth: 52, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
    }, width: 620)

    print("")
    print("判据:")
    print("  kind-compare   旧组三张读作 READ; 新组读作 OTHER 且标题是真名、command 是首参。")
    print("                 卡片标签色两组同为 done 的素色 (相态决定) —— 颜色差只在那排轨迹页 chip。")
    print("  output-three   ①⑥ 有箭头 ②③④⑤ 无箭头; ③ 只有缩略条没有文本行; ⑤ 显示文件名不空白")
    print("  phase-and-kind 色带里 bash=accent / read 组=info / edit·write=完成绿 / other=素色")
    print("")
    print("⚠️ 限制: `running` 的转圈 (`ProgressView` 这类动画件) 在离屏渲染里画不出来 ——")
    print("   那不是 App 的病。缩略条本身走 `NSHostingView`, 画得出来 (见文末)。")
}
'''


def main():
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(WORK, 'main.swift'), 'w', encoding='utf-8') as handle:
        handle.write(MAIN)

    binary = os.path.join(WORK, 'probe')
    cmd = ['xcrun', 'swiftc', '-O', 'main.swift']
    cmd += [os.path.join(ROOT, s) for s in SOURCES]
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
        print(line)
    if ran.returncode != 0:
        print((ran.stderr or '')[-2000:])
    return ran.returncode


if __name__ == '__main__':
    sys.exit(main())
