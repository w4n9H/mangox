//
//  UserMessageFold.swift
//  用户消息折叠的**判据与切分** —— 纯函数, 不读时钟 / 环境 / 磁盘 (冒烟 T-UI 守着它)。
//
//  为什么需要它: 用户贴一段日志 (上千行) 会原样铺满整个对话区; 而且 `Text(整段)` 的布局
//  是**平方级**的 —— 本仓 `scripts/diag/render_probe.py` 实测 3 341 行要 36 秒, 按块渲染
//  646 毫秒。所以这是两件事: 占屏 (观感) + 主线程 (贴完卡几秒)。
//
//  ⚠️ 判据是**两个门槛取先到**: 日志是"行多", 长散文是"字多", 只看一个会漏掉另一种。
//  ⚠️ 折叠**只影响渲染**。复制 / 保存为记忆 / 重新生成 一律走原文 (`MessageBlockView.rawText`)
//     —— 用户说的话不能被 App 藏掉半句, 所以提示必须报出**确切还剩多少行**。
//  ⚠️ 已知边界: 展开态按 `\n` 切行, **单行超长** (一整段几万字符不换行) 仍是一个大 `Text`,
//     那一行的布局还是平方级。极端场景, 暂不处理; 要处理得按字符再切块。

import Foundation
import CoreGraphics

enum UserMessageFold {
    /// 折叠时显示几行。**6 行** —— 2026-10-19 首版取 8, 实测长日志行会折成两个显示行,
    /// 8 个逻辑行 = 16 个显示行 = 333pt, 占掉三分之一屏, 与"折叠"的意图相反。
    /// 6 行落在 ~250pt。⚠️ 单位是**原文的 `\n` 行数**, 不是显示行数 —— 所以同一档行数在
    /// 短消息和长日志下高度不同, 这是按行计数的已知代价 (换按字符截会让两套阈值不同单位)。
    static let collapsedLineLimit = 6
    /// 行数门槛: 超过它就折叠。
    static let foldLineThreshold = 12
    /// 字数门槛: 行数不多但很长 (一段没换行的日志) 也要折叠。
    static let foldCharThreshold = 1200
    /// 折叠预览的**字符上限** —— 防"一行十万字符", 那种情况按行切等于没切。
    static let previewCharCap = 1200
    /// 展开后滚动区的高度上界 (**上界不是定高**: 短内容按自身高度收, 只有超了才滚)。
    /// 与工具输出区 (`Tune.toolOutputMaxHeight = 180`) **有意不同** —— 那是"跑完看一眼结果",
    /// 这是"用户自己写的东西", 多给 80pt 的视野。相同的部分是那条判据:
    /// **高度与内容长度脱钩** (P16 立项的起因)。
    static let expandedMaxHeight: CGFloat = 260

    static func shouldFold(_ text: String) -> Bool {
        lineCount(text) > foldLineThreshold || text.count > foldCharThreshold
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }

    /// 折叠态要渲染的那段: 按行取前 `collapsedLineLimit` 行, 并受 `previewCharCap` 约束。
    static func preview(_ text: String) -> String {
        var lines: [String] = []
        var used = 0
        for line in text.components(separatedBy: "\n").prefix(collapsedLineLimit) {
            let room = previewCharCap - used
            if room <= 0 { break }
            if line.count <= room {
                lines.append(line)
                used += line.count + 1          // +1 = 换行符
            } else {
                lines.append(String(line.prefix(room)))   // 单行超长: 截在这一行
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 折叠态**没显示**的行数。`0` = 行数没超 (只可能是被字符上限截的, 即单行超长)。
    static func hiddenLineCount(_ text: String) -> Int {
        max(0, lineCount(text) - collapsedLineLimit)
    }
}
