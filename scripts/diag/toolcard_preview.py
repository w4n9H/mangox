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
   `ToolOutputBox` 真的把长输出关进了 180pt"和"纯图卡不空转"只能看。
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
    # 「段收据」那一层（2026-10-26 加的）—— 判「段折叠 + codemode 折叠」是不是叠成三层，
    # 必须让**真的** `ToolRunBuilder` / `ToolRunReceiptRow` 参与编译，不能靠手搭。
    'mangox/Models/PlanQuestion.swift',
    'mangox/Models/Attachment.swift',
    'mangox/Models/MessageModels.swift',
    'mangox/Views/Chat/ToolRunReceipt.swift',
    'mangox/Views/Chat/ThinkingCardView.swift',
]

MAIN = r'''
import AppKit
import Foundation
import SwiftUI

let OUT = "/tmp/mangox-toolcard-preview"

// MARK: - 忠实复制: 卡片够得着的私有/重依赖类型

/// `AgentTransport.swift:10-13` 的**忠实复制**。
///
/// P16 给卡片加了 `decision: PermissionDecision?` ⇒ 探针必须能让这个类型解析。为什么不直接
/// 把 `AgentTransport.swift` 加进 SOURCES: 那个文件牵出 `AgentMode` / `ApprovalMode` /
/// `AutoJudgeBlock` / `ModelMaterializer.Output` 一整串协议类型, 拖进来要把半个 Agent 层
/// 都编一遍 —— 为了一个三 case 的 enum 不值当。**只复制形状, 不放行为**（它没有行为）。
enum PermissionDecision {
    case allow
    case deny
    case alwaysAllow
}

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
func render(_ label: String, _ content: some View, width: CGFloat,
            extraHeight: CGFloat = 0) {
    let root = content
        .frame(width: width, alignment: .topLeading)
        .background(CodexTheme.bgChat)
        // 暗色板: `adaptive()` 是 NSColor 动态色, 但离屏渲染时按**环境**的 colorScheme 解析它
        // —— 必须走 environment (`NSAppearance` 那招实测不生效)。
        .environment(\.colorScheme, .dark)

    // `NSHostingView` + 离屏窗口, **不用** `ImageRenderer` —— 后者画不出 `ScrollView` 的内容。
    let host = NSHostingView(rootView: root)
    // ⚠️ `fittingSize` 会**低估**含 `ScrollView` 的内容高度（输出区就是 ScrollView）⇒
    //    超出的部分被 `cacheDisplay(in: host.bounds)` 直接裁掉，看上去像"输出没画出来"。
    //    判据：尾巴上的输出盒子只露半行。`extraHeight` 是给这种图补的余量（0 = 老行为）。
    let height = max(host.fittingSize.height, 1) + extraHeight
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

extension ToolCall {
    /// 出图用: 把一张卡包成"嵌套调用"（决策与三个回调都空 —— 出图不点按钮）。
    func asNested() -> ToolCallCardView.Nested {
        .init(tool: self, decision: nil, onApprove: nil, onDeny: nil, onAlwaysAllow: nil)
    }
}

func sample(_ label: String, _ tool: ToolCall,
            children: [ToolCallCardView.Nested] = []) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(verbatim: label)
            .font(.system(size: 11))
            .foregroundStyle(CodexTheme.textMuted)
        ToolCallCardView(tool: tool, children: children)
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

// bash 的一长段输出 —— **40 行**，足以把 `ToolOutputBox` 顶到 180pt 上限。
// ⚠️ P16 之前这里是 8 行 + "必须出展开箭头"；那条断言连同 `hasLongOutput` 一起删了，
//    8 行封不了顶，留着会让"封顶 + 内部滚动"变成一句谎话。
let bashOut = (1...40).map { "row \($0)  channel=dau  value=\($0*137)" }.joined(separator: "\n")

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
        caption("旧: `kindFor` 的 default 一律落 read",
                "同一批陌生工具全读作 read —— 谎报在**文字**上; 落库的 kind 也已失真, 事后分不出")
        ForEach(strangers, id: \.0) { name, _ in
            sample("\(name)  ·  旧渲染", ToolCall(kind: .read, title: name, command: nil, phase: .done))
        }

        caption("新: 中性 other + 真名占 title + 首个标量参数退到 command",
                "command 走 `cmd ?? path ?? firstScalarArg`; 后者按 key 排序取首个 ⇒ 同一调用重放两次必得同一结果 (卡头不跳)")
        ForEach(strangers, id: \.0) { name, args in
            sample("\(name)  ·  新渲染", ToolCall(kind: .other, title: name, command: args, phase: .done))
        }

        caption("⚠️ 颜色错在**轨迹页**, 不在卡片",
                "P16 起卡片标签色**恒冷蓝**（`kindColor`, 与相态脱钩）⇒ 上面两组同色。轨迹页 chip 仍吃 `kind.defaultColor`, 那里才随类别变色")
        HStack(spacing: 10) {
            kindChip(ToolKind.read.label, ToolKind.read.defaultColor)
            kindChip(ToolKind.other.label, ToolKind.other.defaultColor)
            Text(verbatim: "← 同一个陌生工具: 旧 chip / 新 chip")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
        }

        caption("留位: delegate",
                "pi 0.85.1 内置 8 个工具无 delegate, 当前零生产方 —— 保留只为让扩展的子代理工具有确定归处")
        sample("delegate  ·  新渲染",
               ToolCall(kind: .delegate, title: "code-reviewer", command: "task=审一遍传输层", phase: .done))
    }, width: 620)

    // ── B. 输出区 ────────────────────────────────────────────────────────────
    // ⚠️ 六张**必须落在"会自动展开"的两个相态上**（待审批 / 出错）—— P16 起 `done` 不自动
    //    展开（常态 5 个工具只占 15% 高度, 那是另一件事）。样本若还用 `.done`, 输出区
    //    **根本不会出现**, 这一整张图就白出了。
    render("output-three", VStack(alignment: .leading, spacing: 18) {
        caption("① 长输出 · 40 行", "输出区**封顶 180pt 并内部滚动** —— 高度与内容长度脱钩（40 行与 400 行实测同高 233pt）")
        sample("bash  ·  待审批 · 40 行输出", ToolCall(
            kind: .bash, title: "mysql",
            command: "-h 10.251.72.10 -D basic_warehouse", details: [ToolDetail("输出", bashOut)],
            phase: .awaitingApproval))

        caption("② 短输出 · 1 行", "盒子只占一行高 —— `maxHeight` 是**上界**不是定高")
        sample("grep  ·  待审批 · 1 行输出", ToolCall(
            kind: .grep, title: "kindFor", command: "mangox/Agent/PiRpcTransport.swift",
            details: [ToolDetail("输出", "PiRpcTransport.swift:412:    private func kindFor(_ name: String)")],
            phase: .awaitingApproval))

        caption("③ 纯图 (典型: read 一张截图)", "无文本行, 只出缩略条 —— 复制键把路径写进剪贴板, 不空转")
        sample("read  ·  待审批 · 纯图",
               ToolCall(kind: .read, title: "/tmp/mangox-toolcard-preview/shot.png",
                        details: [], phase: .awaitingApproval, imagePaths: [shot]))

        caption("④ 文本 + 图", "文本行在上、缩略条在下; 图与正文图片块共用同一套路径解析 / 大图上限")
        sample("bash  ·  待审批 · 文本+图", ToolCall(
            kind: .bash, title: "python3 plot.py", command: "--channel all",
            details: [ToolDetail("输出", "wrote /tmp/mangox-toolcard-preview/chart.png")],
            phase: .awaitingApproval, imagePaths: [chart, shot]))

        caption("⑤ 读不到的文件", "照实显示文件名 —— 不静默留白 (留白会被当成渲染 bug)")
        sample("read  ·  待审批 · 图读不到",
               ToolCall(kind: .read, title: "/tmp/mangox-toolcard-preview/nope.png",
                        details: [], phase: .awaitingApproval,
                        imagePaths: ["/tmp/mangox-toolcard-preview/nope.png"]))

        caption("⑥ 失败行 · 自动展开", "失败**不许自己缩回**; 同一形状的 `AgentToolResult` ⇒ details 里本来就有真错误文本")
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
                ForEach([ToolKind.bash, .codemode, .read, .grep, .find, .ls, .edit, .write], id: \.self) { k in
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

    // ── D. codemode 的嵌套调用 (2026-10-26) ──────────────────────────────────
    // 判据: ① 一次调用**只有一行** (子调用不占顶层行);
    //      ② 收起态靠行里的「内层 N」说话;
    //      ③ 内层有一条待审批 ⇒ 父卡**自动展开** (否则审批入口藏在收起的卡里 = 没有入口)。
    let cmdScript = "const r = await tools.bash({command: `ls -la`})"
    let cmDone = ToolCall(kind: .codemode, title: cmdScript, command: nil,
                          phase: .done, durationMs: 84)
    let cmChild1 = ToolCall(kind: .bash, title: "ls -la", phase: .done, durationMs: 22)
    let cmChild2 = ToolCall(kind: .read, title: "/opt/homebrew/lib/node_modules",
                            phase: .done, durationMs: 1)
    let cmPending = ToolCall(kind: .bash, title: "rm -rf build", phase: .awaitingApproval)

    render("nested", VStack(alignment: .leading, spacing: 18) {
        caption("codemode · 收起态",
                "一次调用只有一行; 「内层 2」是唯一能看出里面跑过东西的地方")
        sample("done · 内层 2", cmDone,
               children: [cmChild1.asNested(), cmChild2.asNested()])

        caption("codemode · 内层一条待审批",
                "父卡自动展开 —— 子卡的审批入口藏在收起的父卡里 = 等于没有入口")
        sample("内层待审批", cmDone, children: [cmPending.asNested()])
    }, width: 620)

    // ── E. 「段收据 × codemode」叠成几层（2026-10-26 boss 问）──────────────────
    // 判据**全部由真的 `ToolRunBuilder` 算出来**，不靠眼睛。
    func makeRun(_ tools: [ToolCall]) -> ToolRun? {
        let msgs: [ChatMessage] = tools.map {
            ChatMessage(role: .assistant, content: .tool($0))
        }
        // `attached` 由调用方给（此处整批就是一个会话）—— 与 `ChatView` 同一个来源。
        return ToolRunBuilder.runs(in: msgs,
                                   attached: ToolNesting.attachedToolIds(in: msgs)).first
    }
    let cmFlow = ToolCall(kind: .codemode, title: cmdScript, command: nil,
                          phase: .done, durationMs: 84)
    let nGit = ToolCall(kind: .bash, title: "git status", command: nil,
                        details: [ToolDetail("输出", "On branch main\nnothing to commit")],
                        phase: .done, durationMs: 22, parentId: cmFlow.id)
    let nTest = ToolCall(kind: .read, title: "package.json", command: nil,
                         details: [ToolDetail("输出", "{\"name\": \"mangox\", \"version\": \"0.1.31\"}")],
                         phase: .done, durationMs: 1, parentId: cmFlow.id)
    let bLint = ToolCall(kind: .bash, title: "npm run lint", command: nil,
                         details: [ToolDetail("输出", "no problems found")],
                         phase: .done, durationMs: 31)
    let bTest = ToolCall(kind: .bash, title: "npm test", command: nil,
                         details: [ToolDetail("输出", "Tests: 1593 passed, 1593 total")],
                         phase: .done, durationMs: 4200)
    let bDiff = ToolCall(kind: .edit, title: "ChatView.swift", phase: .done, durationMs: 12)

    // ① 只有 codemode（内层 2 条）: 屏上**只有 1 行** ⇒ 不该折
    let runAlone = makeRun([cmFlow, nGit, nTest])
    // ② codemode + 3 条模型直接调的: 屏上 4 行 ⇒ 该折
    let runMixed = makeRun([cmFlow, nGit, nTest, bLint, bTest, bDiff])

    // ⚠️ 拆成两张图：离屏 `NSHostingView.fittingSize` 会**低估**含 `ScrollView` 的内容高度
    //    （输出区就是 ScrollView）⇒ 一张长图会把最后几格裁掉，看着像"输出没画出来"。
    render("nested-fold", VStack(alignment: .leading, spacing: 22) {
        caption("① 只有 codemode 的段 · 不该折",
                "内层不出行 ⇒ 屏上只有 1 行, 折起来省 0pt 却多一次点击 (折了才是错)")
        ToolCallCardView(tool: cmFlow, children: [nGit.asNested(), nTest.asNested()])

        caption("② codemode + 3 条直接调的 · 该折",
                "屏上 4 行 ⇒ 收据按【可见行数】算, 内层不计入 (旧口径会印「6 次工具调用」)")
        ToolRunReceiptRow(run: runMixed!, isExpanded: false, onToggle: {})
    }, width: 620)

    render("nested-fold-open", VStack(alignment: .leading, spacing: 22) {
        caption("③ 点开收据 —— 第 1 次点击",
                "收据留着当头, 下面放回 4 行; 内层行【不在这里】(它们画在父卡的展开区里)")
        VStack(alignment: .leading, spacing: 4) {
            ToolRunReceiptRow(run: runMixed!, isExpanded: true, onToggle: {})
            ToolCallCardView(tool: cmFlow, children: [nGit.asNested(), nTest.asNested()])
            ToolCallCardView(tool: bLint)
            ToolCallCardView(tool: bTest)
            ToolCallCardView(tool: bDiff)
        }

        caption("④ 再点 codemode —— 第 2 次点击, 内层默认收起",
                "每张子卡仍有自己的 chevron, 但默认收起 (`.done` 不自动展开): 看哪条点哪条, 不让一堆输出糊屏")
        ToolCallCardView(tool: cmFlow, children: [nGit.asNested(), nTest.asNested()],
                         initialExpanded: true)
    }, width: 620)

    // ── F. 思考卡的竖条：与工具卡同一条血线（2026-10-26）────────────────────────
    // 判据: 塞进**确定高度**的容器里，卡片只有自己那么高。
    // 改前是 `HStack { Rectangle(可伸缩); VStack{...} }` —— 形状没有内在高度 ⇒ 它把这一行
    // 撑成容器给的高度: 竖条一路画到底、文字顶在上面，下面一大片空白。
    // ⚠️ 底下那层 bgCard 只是**标注容器范围**（不是 App 的底色），好让"空白有多大"看得见。
    let thinkSample = "先把三条路径摊开：opencode 走 ACP、claude 走 stream-json、"
        + "自研走自己的 rpc。差别不在协议，而在谁持有会话状态。"
    render("thinking-rail", VStack(alignment: .leading, spacing: 22) {
        caption("思考卡 · 正常流",
                "折叠态一行 23pt；进行中右端挂一枚琥珀「思考中…」（颜色只给状态）")
        ThinkingCardView(text: thinkSample, id: UUID())
        ThinkingCardView(text: "", id: UUID(), isStreaming: true)

        caption("三张卡塞进【240pt 定高】容器",
                "只有自己那么高才叫对。若竖条一路画到底、行间成大段空白，就是形状在撑高（改前写法）")
        VStack(alignment: .leading, spacing: 0) {
            ThinkingCardView(text: thinkSample, id: UUID())
            ThinkingCardView(text: thinkSample, id: UUID())
            ThinkingCardView(text: thinkSample, id: UUID())
        }
        .frame(height: 240, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.bgCard)
    }, width: 620)

    print("")
    print("判据:")
    print("  kind-compare   旧组三张读作 read; 新组读作 other 且标题是真名、command 是首参。")
    print("                 卡片标签色两组同为**冷蓝** (P16: kindColor 恒 info, 与相态脱钩)。")
    print("  output-three   六张全在展开态 ⇒ 每张都该看到「输出」+ bgCard 输出区 (+ 三键 / 错误行)。")
    print("                 ① 40 行 ⇒ 封顶 180 且内部滚动; ② 1 行 ⇒ 盒子只有一行高;")
    print("                 ③ 只有缩略条没有文本行; ⑤ 显示文件名不空白。")
    print("  phase-and-kind 箭头随相态: queued/running/done 收起、error 自动展开;")
    print("                 竖条 queued/running/done 冷蓝、error 红; 右侧 badge 各自读得出来。")
    print("")
    print("  nested-fold    (全部由真的 ToolRunBuilder 算出来, 不是眼看的)")
    print("                 ① 只有 codemode + 2 内层 ⇒ 可见行 = 1 ⇒ foldable = \(runAlone?.foldable ?? false)")
    print("                    (旧口径按 span.count=3 会折; 折了省 0pt 还多一次点击)")
    print("                 ② + 3 条直接调的 ⇒ 可见行 = 4 ⇒ foldable = \(runMixed?.foldable ?? false)")
    print("                    收据印「\(runMixed?.count ?? -1) 次工具调用」(内层 2 条不算)")
    print("                    ⇒ 内层只要算进计数, 旧口径会印「6 次」—— 那是说谎")
    print("                 ④ 子卡默认收起: 每行仍带 chevron (`.done` 不自动展开), 看哪条点哪条")
    print("")
    print("  thinking-rail  竖条走 overlay ⇒ **不参与尺寸计算**。上面两张是正常流;")
    print("                 下面三张被塞进 240pt 定高容器 (底下那层浅色 = 容器范围)。")
    print("                 ✅ 对的样子: 三行各自 23pt 贴在容器顶部, 竖条只有行那么高。")
    print("                 ❌ 错的样子: 竖条一路画到底、每行之间大段空白 (形状在撑高)。")
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
