#!/usr/bin/env python3
r"""
SwiftUI 渲染开销标定 —— 把"卡顿"变成毫秒数, 不靠感觉。

**为什么需要它** (2026-09-23 boss: 「查看本次注入」"点击后卡顿很严重, 严重到转圈圈了"):

卡顿的原始描述只有"卡", 而"卡"不是一个可以动手的信号 —— 它可能来自布局、来自解析、
来自磁盘, 也可能只是那一块文本太大。本脚本用 `ImageRenderer` 在**不启动 App** 的前提下
把候选写法各渲染若干次取最快值, 于是"卡"变成一张表, 该改哪一行自己就浮出来了。

## 本轮量出来的结论 (这张表就是那个 bug 的根因)

在 560pt 宽、**全高布局**(= ScrollView 里的真实情形)下:

| 行数 | `Text` 整块 | `MarkdownView` |
|---|---|---|
| 139  | 199 ms      | 26 ms   |
| 281  | 860 ms      | 53 ms   |
| 561  | 4 251 ms    | 105 ms  |
| 1 119| 8 512 ms    | 210 ms  |
| 3 341| **36 108 ms** | 646 ms |

**内容 ×24 ⇒ `Text` 耗时 ×181 (平方级), `MarkdownView` ×24.6 (线性)。**
机制: 一个 `Text` 承载整块文本时, 整篇是**一个**布局单位; `MarkdownView` 按块拆成多个
小 `Text`, 每个各自布局 ⇒ 总代价回到线性。注入块上限 64 000 字符 ⇒ 旧写法最长 36 秒。

⚠️ 一个曾经把我带偏的陷阱 —— **量渲染开销时必须给足高度**:

  · `frame(height: 420)` (窗口可见高度) 会让 Text 被裁剪 ⇒ 测出来是 **206 ms**
  · `frame(height: 20_000)` (内容真实高度) 才是 ScrollView 内发生的事 ⇒ **8 512 ms**

差了 **41 倍**。裁剪口径下这个 bug 看起来完全不存在 —— 第一版探针就报"两个写法差不多"。

用法: `python3 scripts/diag/render_probe.py`
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WORK = '/tmp/mangox-perf-probe'

# 探针要编译的**真源码** —— 不用副本, 量的就是 App 里跑的那一份。
SOURCES = [
    'mangox/Localization/AppLanguage.swift',
    'mangox/Theme/CodexTheme.swift',
    'mangox/Theme/CodexFonts.swift',
    'mangox/Views/Chat/Markdown/MarkdownParser.swift',
    'mangox/Views/Chat/Markdown/MarkdownView.swift',
    'mangox/Views/Chat/Markdown/CodeBlockView.swift',
    'mangox/Views/Chat/Markdown/CodeHighlighter.swift',
]

MAIN = r'''
import AppKit
import Foundation
import SwiftUI

/// 形态真实的注入块: 标题 / 段落 / 列表混排 (每种都要有 —— 块类型影响解析与块数)。
func makeBlock(chars: Int) -> String {
    let body = """
    [人格]
    ## SOUL.md
    我是星期五 —— 住在 MangoX 里的助手。语气克制、给结论先行, 不写客套话。
    边界: 不替用户做不可逆的决定; 涉及删除/覆盖前必须把现场摆出来。

    ## RULES.md
    - 结论先行, 配可视化
    - 代码改动附具体行号位置
    - 写完代码不自动 commit, 等明确同意

    """
    var out = ""
    var i = 0
    while out.count < chars { i += 1; out += body.replacingOccurrences(of: "SOUL.md", with: "SOUL-\(i).md") }
    return String(out.prefix(chars))
}

@MainActor
func best(_ content: some View, width: CGFloat, height: CGFloat, rounds: Int = 3) -> Double {
    var ms = Double.greatestFiniteMagnitude
    for _ in 0..<rounds {
        let view = content.frame(width: width, height: height, alignment: .topLeading).background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let t0 = Date()
        _ = renderer.nsImage
        ms = min(ms, Date().timeIntervalSince(t0) * 1000)
    }
    return ms
}

MainActor.assumeIsolated {
    print("宽度 560pt。**全高布局** = ScrollView 里真实发生的事 (别用可见高度, 会低估 40 倍)")
    print("")
    print("  字符数    行数    Text 整块     MarkdownView    倍数")
    for n in [2_500, 5_000, 10_000, 20_000, 60_000] {
        let block = makeBlock(chars: n)
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).count
        let a = best(Text(block).font(CodexTheme.fontMonoSm).textSelection(.enabled),
                     width: 560, height: 20_000)
        let b = best(MarkdownView(text: block), width: 560, height: 20_000)
        print(String(format: "%7d  %6d  %10.1f ms  %11.1f ms  %5.1fx", n, lines, a, b, a / max(b, 0.1)))
    }
    print("")
    print("判据: 两者都应当**随内容线性**增长。若 Text 那一列出现超线性跳变")
    print("      (内容翻倍而耗时×3 以上), 说明有人把多块内容塞回了单个 Text。")
}
'''


def main():
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    with open(os.path.join(WORK, 'main.swift'), 'w', encoding='utf-8') as handle:
        handle.write(MAIN)

    binary = os.path.join(WORK, 'probe')
    cmd = ['xcrun', 'swiftc', '-O', 'main.swift']
    cmd += [os.path.join(ROOT, s) for s in SOURCES]
    cmd += ['-o', binary]
    built = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL - 编译探针失败')
        print((built.stdout or built.stderr)[-3000:])
        return 1

    ran = subprocess.run([binary], capture_output=True, text=True)
    # CoreText 会对 `.SF Mono` 之类按名请求的字体发 note, 与结论无关, 滤掉
    for line in ran.stdout.splitlines():
        if 'CoreText note' in line or 'CTFontLogSystemFontNameRequest' in line:
            continue
        print(line)
    return ran.returncode


if __name__ == '__main__':
    sys.exit(main())
