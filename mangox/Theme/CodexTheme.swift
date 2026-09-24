//
//  CodexTheme.swift
//  Design tokens for MangoX.
//  All colors are adaptive light/dark pairs; default appearance is light.
//
//  ★ 调参总入口: 布局参数在文件尾部的 `Tune` 命名空间,
//    用户可见文案在 `Copy` 命名空间, 改一个数 Cmd+R 即见。
//

import SwiftUI

enum CodexTheme {

    // MARK: - Adaptive color helper

    /// Resolves a light/dark hex pair against the effective appearance.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// 半透明叠加层 —— **悬停 / 选中态专用**（不直接对外用，见下方 hover / selected）。
    ///
    /// 为什么不做成实色（2026-09-21 P10.8 修正）：固定实色只在"比它更暗的面"上成立。
    /// 同一个值落到卡片面或正文面上就会看不见、甚至反过来比底更暗 —— 这正是
    /// `bgElevated` 一个 token 同时兼"内容卡面"和"悬停态"时暴露出来的问题。
    /// 叠加层在任意面上都成立：暗色加白、亮色加黑，天然跟着底走。
    private static func overlay(dark: Double, light: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(white: 1, alpha: CGFloat(dark))
                          : NSColor(white: 0, alpha: CGFloat(light))
        })
    }

    // MARK: - Surfaces (light: white/gray · dark: 深灰地板 —— 见 Dark 节的"为什么不是纯黑")

    static let bgBase     = adaptive(light: 0xFFFFFF, dark: Dark.bgBase) // app background · 窗口底 (最外层)
    static let bgSidebar  = adaptive(light: 0xF6F6F7, dark: Dark.bgSidebar) // nav/left column
    static let bgRight    = adaptive(light: 0xF6F6F7, dark: Dark.bgSidebar) // workspace

    /// **页面底** —— 主区面板的"纸边": 顶栏 / 各面板最外圈。
    /// ⚠️ 大段正文**不坐这一层** —— 那正是 2026-09-21 boss「黑色主题看着眼睛很累」的根因,
    /// 正文请用 `contentPanel`。
    /// ⚠️ P10.8c: **聊天页内部不再用它**（输入区/状态栏已收回 `contentPanel`）——
    /// 面板内部只允许一种底色, 否则相邻两个面之间会出现"无边界元素的硬边"。
    static let bgChat     = adaptive(light: 0xFFFFFF, dark: Dark.bgChat)

    /// **内容面** (P10.8b 新增) —— 主区里 **正文真正坐着的那一层**: 消息列 / 轨迹列表 / 引用块。
    ///
    /// 为什么不直接抬 `bgChat`: 它还兼着"顶栏底 / 各面板最外圈", 抬它会把顶栏一起抬平,
    /// 层次反而糊掉 —— 内容面是**局部**的, 页面底是**全局**的。
    /// 亮色取值与 `bgChat` 同为纯白: 亮色模式本来就是"白纸 + 灰卡", 不需要第二层 (改它 = 无谓的亮色回归)。
    /// P10.8c: 底档 (输入区 + 状态栏) 也归这一层 —— **聊天页从顶到底只有一种底色**。
    static let contentPanel = adaptive(light: 0xFFFFFF, dark: Dark.contentPanel)

    /// 输入井 (搜索框/字段面) / 卡面 / 卡内次级面 / 胶囊。
    static let bgInput    = adaptive(light: 0xF1F1F3, dark: Dark.bgInput)
    static let bgCard     = adaptive(light: 0xF3F3F5, dark: Dark.bgCard) // tool card / code block / table
    static let bgElevated = adaptive(light: 0xEDEDEF, dark: Dark.bgElevated) // 卡内次级面 (表头·按钮·工具条) · 设置卡面
    static let bgPill     = adaptive(light: 0xE7E7EA, dark: Dark.bgPill) // composer 上方的胶囊控件（明显浅灰）
    /// 输入卡面 —— 暗色下比**它所在的两种面都暗一档**(正文面 contentPanel / 页面底 bgChat),
    /// 所以既能在聊天页当"凹槽", 又能当其他页面上的字段底 (旧注释说的"必须比 bgChat 亮"已过时)。
    static let bgComposer = adaptive(light: 0xFFFFFF, dark: Dark.bgInput)

    // MARK: - 交互态 (悬停 / 选中)
    //
    // 用**半透明叠加**而不是实色: 实色只在"比它更暗的面"上成立。侧栏选中行 (底=侧栏)、
    // 卡内悬停按钮 (底=卡面)、分段控件 hover (底=容器面) —— 三者底色差了三档, 同一个实色不可能都对。
    // 两个 token 而不是一个: **选中必须比悬停更实**, 否则"当前项在哪"读不出来。
    static let hover    = overlay(dark: Dark.hoverAlpha, light: 0.05)
    static let selected = overlay(dark: Dark.selectedAlpha, light: 0.08)

    // MARK: - Borders
    static let border     = adaptive(light: 0xE3E3E7, dark: Dark.border)
    static let divider    = adaptive(light: 0xECECEF, dark: Dark.divider)
    static let guide      = adaptive(light: 0xDCDCE2, dark: Dark.guide) // 侧栏层级引导线 (比 divider 实, 比 border 软)

    // MARK: - Accent
    static let accent       = adaptive(light: 0xDD5742, dark: 0xDD5742) // warm orange-red (brand primary)
    static let accentSoft   = accent.opacity(0.18)
    static let thinking     = adaptive(light: 0xB07A12, dark: 0xE0A030) // amber/orange left bar
    static let toolRunning  = adaptive(light: 0xB07A12, dark: 0xE0A030) // amber when running
    static let toolDone     = adaptive(light: 0x1A7F37, dark: 0x3FB950) // green when done
    static let toolError    = adaptive(light: 0xD1242F, dark: 0xE5484D) // red
    static let toolQueued   = adaptive(light: 0x6B6B78, dark: Dark.toolQueued) // gray-blue for queued
    static let info         = adaptive(light: 0x0969DA, dark: 0x7DA3F0)
    static let blocked      = adaptive(light: 0xB07A12, dark: 0xE0A030) // amber awaiting-approval (P8-T26)

    // MARK: - 思考强度轨 (2026-09-24 boss 拍板: 蓝→紫→洋红, **亮暗共用一套**)
    // 判据 = 这段色**从色相环的冷端跨到暖端** (227°→306°), 两种底色都托得住; 实测最紧 2.8:1
    //   (蓝端压暗色卡面 2.79 / 洋红端压亮色输入井 2.88 —— 轨道是 320×20 的大实色块,
    //    不是细边或小图标, 这一档够用; 想更保险就抬亮色端饱和度)。
    //   · 曾试过"亮暖(琥珀→玫红)/暗冷"两套色系, **已撤回** —— 同一个控件换底色就换性格, 反而像漂移。
    // ⚠️ 于是**全应用唯一一处"非品牌暖色"的彩色面** —— 这是**决定的**, 不是漂移:
    //    它只住在 `ModelPicker` 面板里 (滑轨 + 停靠点), 不与暖橙红 `accent` 同屏争主色。
    // ⚠️ 中段不许退化成两端的近似值 —— 三点渐变里 mid 恰在 50%, 取近似值 ⇒ 后半条轨是平的
    //    (踩过: `#E2679B`/`#DC5A8E` 只差 6/13/13, 结果"越高越X"有一半看不见)。
    /// 轨左端 (最低档)。
    static let railStart = adaptive(light: 0x4E62D2, dark: 0x4E62D2)
    /// 轨中段 (中档)。
    static let railMid   = adaptive(light: 0xA054E8, dark: 0xA054E8)
    /// 轨右端 (顶档)。
    static let railEnd   = adaptive(light: 0xE05CC0, dark: 0xE05CC0)

    // MARK: - Text
    static let textPrimary   = adaptive(light: 0x24292F, dark: Dark.textPrimary) // 柔和近黑 (0x1F2328 太硬)
    static let textSecondary = adaptive(light: 0x57606A, dark: Dark.textSecondary)
    static let textTertiary  = adaptive(light: 0x6E7781, dark: Dark.textTertiary)
    static let textMuted     = adaptive(light: 0x9CA3AB, dark: Dark.textMuted)
    static let textMono      = adaptive(light: 0x24292F, dark: Dark.textMono)

    // MARK: - Status
    static let statusRunning = toolRunning
    static let statusDone    = toolDone
    static let statusError   = toolError

    // MARK: - Layout
    static let radius: CGFloat         = 8
    static let radiusLg: CGFloat       = 12
    static let radiusSm: CGFloat       = 6

    // MARK: - Typography
    // 用语义化系统字体, 不走 Font.custom(私有字体名)——私有名 (.AppleSystemUIFont/.SF Mono)
    // 在 Font.custom 下走降级渲染路径, 字形发虚 (T3 验收发现的"字体丑"根因)。
    // mono 三级: mono 走 CodexFonts.monoFont (Berkeley 已装 → 内置 JetBrains Mono → SF fallback)。
    static let fontTitle    = Font.system(size: 13).weight(.semibold)
    static let fontBody     = Font.system(size: 13)   // 对话正文 (14→13 精致化)
    static let fontSmall    = Font.system(size: 12)
    static let fontTiny     = Font.system(size: 11)
    static let fontMono     = CodexFonts.monoFont(13)
    static let fontMonoSm   = CodexFonts.monoFont(12)
    static let fontMonoXs   = CodexFonts.monoFont(11)
    static let fontButton   = Font.system(size: 13).weight(.medium)
    static let fontLabel    = Font.system(size: 11).weight(.medium)

    // MARK: - Animation
    static let animFast: Animation   = .easeInOut(duration: 0.15)
    static let animMed:  Animation   = .easeInOut(duration: 0.25)
    /// New message / tool card insertion.
    static let animMessage: Animation = .spring(response: 0.28, dampingFraction: 0.85)

    // MARK: - ★ 暗色板原始值（P10.8「暗色不再累眼」）
    //
    // **为什么单独抽出来**：这些字面量既是渲染值、也是**冒烟里算对比度的输入** ——
    // 只有一个源头，才不会出现"改了色值但守卫还在验旧数字"的漂移。
    //
    // **第一刀 · 为什么不是纯黑**（2026-09-21 boss 反馈"黑色主题看着眼睛很累"，实测定位）：
    // 截图采样 + WCAG 计算显示，旧值 = 近纯黑底（`#0D0D10`，相对亮度 0.0041）
    // 压近纯白正文（`#EDEDED`）→ **对比度 16.6:1**。大段正文在超高对比度下会产生
    // **光晕（halation）**，长时间阅读明显累眼 —— 这是暗色模式最常见的反模式，
    // 因为"对比度越高越清晰"只对小字短文本成立，对整屏正文不成立。
    //
    // 现代暗色 OLED 规范（Material / Apple HIG）的共识是：**"暗"由黑变深灰承担，
    // 层次由面与面的亮度差承担，而不是把地板压到 0**。第一刀取舒适带：
    //   地板 0x111116（不再触及纯黑）· 正文对比度 16.6 → 10.5:1
    //   代码 mono 11.8 → 8.7:1（整屏代码块不再发白光）· 三级 3.7 → 5.1（达标）
    //
    // **第二刀 · 正文得有一层"面"**（P10.8b，boss 对比截图后："我感觉 settings 看着更舒服"）：
    // 第一刀之后 Chat 仍比 Settings 累眼，因为两者的差别不是颜色而是**结构** ——
    //   Settings：正文坐在**卡片面**上（`bgElevated` → 8.32:1）
    //   Chat    ：正文坐在**页面底**上（`bgChat`，与最外圈同一个面 → 10.51:1，且面本身近黑）
    // 于是给主区正文引入了独立一档 `contentPanel`（正文对比度 9.37:1），
    // 卡片（工具卡/代码块/表格）整体再往上让一档 `bgCard`。
    // 面链因此从 7 级变 8 级：bgBase < bgSidebar < bgChat < bgInput < **contentPanel** < bgCard < bgElevated < bgPill
    //
    // ⚠️ **为什么内容面不直接对齐 Settings 卡面（0x2C2C35）** —— 不是保守，是**结构不允许**：
    // 卡片必须严格亮于它所处的面。内容面一顶到 0x2C2C35，Chat 里的工具卡/代码块就再无档位可去
    // （再往上就撞 `bgElevated`，而 `bgElevated` 正是 Settings 卡面本身）。
    // 所以内容面**只能**落在卡面下一档 —— 这也解释了为什么"照 Settings 调"不能是复制它的数值，
    // 只能是复制它的**结构**：正文坐在独立面 / 卡面比正文面亮一档。
    // 要把正文再压低，就抬 `contentPanel` 且连带抬 bgCard/bgElevated/bgPill ——
    // 改完跑 `python3 scripts/diag/palette_probe.py`，它会直接说哪条不变量破了（不用等整条冒烟）。
    //
    // **第三刀 · 面板内部只允许一种底色**（P10.8c，boss 圈出"我画框那里有明显的割裂感"）：
    // 第二刀把正文抬起来之后，底部输入区那条色带（当时坐 `bgChat`）的顶边与正文面之间，
    // 出现了一道横贯全宽、**没有任何视觉元素承担它**的硬边 —— 两侧都是大面积纯色，
    // 眼睛就只能读成"两块板拼在一起"（左侧空白处最明显，那里连内容都没有）。
    // 判据：**一条"面"要么承载内容，要么自带可见的边界元素（线 / 圆角 / 阴影）**，
    // 否则它在邻面上就是一块补丁。输入区（143pt 高、无边界元素）与状态栏（与输入区同色，
    // 被读成同一块板的下半截）都不满足 → 一起收回 `contentPanel`，
    // 层级改由**卡自己**表达：项目条 `bgCard` 浮起 / 输入卡 `bgComposer` 凹下。
    // 于是聊天页从顶到底只有一种底色，一道缝都不剩（亮色本来就同色，这次是**暗色向亮色对齐**）。
    enum Dark {
        // 面：亮度严格单调递增
        // bgBase < bgSidebar < bgChat < bgInput < contentPanel < bgCard < bgElevated < bgPill
        // （冒烟守这条链 —— 抬了地板忘了抬卡片，卡片就变成"贴在地板上的补丁"）
        static let bgBase: UInt32     = 0x111116   // 窗口底
        static let bgSidebar: UInt32  = 0x16161B
        static let bgChat: UInt32     = 0x191920   // 页面底
        static let bgInput: UInt32    = 0x1F1F27   // 输入井/字段面（比 contentPanel 暗一档）
        /// ★ 内容面（P10.8b）：正文坐这一层。取值 = 旧 bgCard —— 即"把原来给卡片的那一档，
        /// 让给正文"，卡片整体再往上让一档（见 bgCard）。**正文对比度 9.36:1**。
        static let contentPanel: UInt32 = 0x23232C
        static let bgCard: UInt32     = 0x282830   // 卡面（工具卡 / 代码块 / 表格）
        static let bgElevated: UInt32 = 0x2C2C35   // 卡内次级面（表头/按钮/工具条）· 设置卡面
        static let bgPill: UInt32     = 0x343440
        // 描边（随地板一起抬，否则在新底上"消失"）
        static let border: UInt32     = 0x373742
        static let divider: UInt32    = 0x282832
        static let guide: UInt32      = 0x3E3E4A
        // 文字：按新底重新定档（地板抬高后，旧的次级色会偏暗、正文会偏亮）
        static let textPrimary: UInt32   = 0xC8C8D0
        static let textSecondary: UInt32 = 0xA8A8B2
        /// 三级从 0x8A8A95 抬到 0x8E8E99 —— 卡面抬一档后，旧值在卡上掉到 4.29:1（跌破 AA），
        /// 抬到 0x8E8E99 才让"卡上的三级小字"重回过线。这是抬面**必须配套**的一步，不是顺手美化。
        static let textTertiary: UInt32  = 0x8E8E99
        static let textMuted: UInt32     = 0x6C6C77
        static let textMono: UInt32      = 0xB6B6C0
        static let toolQueued: UInt32    = 0x8A8A95
        // 交互态叠加 alpha（暗色加白）。也放这里 —— 冒烟要断言"选中比悬停实"。
        static let hoverAlpha: Double    = 0.06
        static let selectedAlpha: Double = 0.10
    }

    /// WCAG 相对亮度 / 对比度 —— 让"配色舒不舒服"成为**可断言的数值**，而不是只能靠眼睛。
    /// 放主题文件而不是冒烟里：冒烟里那份会成为漂移源（主题改了、守卫还验旧数）。
    enum WCAG {

        static func luminance(_ hex: UInt32) -> Double {
            func f(_ v: UInt32) -> Double {
                let c = Double(v & 0xFF) / 255.0
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * f(hex >> 16) + 0.7152 * f(hex >> 8) + 0.0722 * f(hex)
        }

        /// 1.0 ~ 21.0；越大越"硬"。
        static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
            let la = luminance(a), lb = luminance(b)
            return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
        }
    }
}

// MARK: - ★ 调参区 (Tune)
// 全部可调布局参数集中于此。约定:
// - 值改动只影响视觉, 不改行为; 改完 Cmd+R 验证。
// - chatContentWidth 是消息列/输入卡宽度的唯一源头, 两个派生宽自动联动。
// - editorMinHeight 同时是输入框初始高 (改一个必须两个一致, 否则首帧跳变)。
enum Tune {

    // 窗口
    static let windowMinSize     = CGSize(width: 1280, height: 820)
    static let windowDefaultSize = CGSize(width: 1440, height: 900)

    // 迷你条 (P4.2, 主窗口变形为任务台)
    static let miniBarWidth: CGFloat      = 300   // mini 台窗口宽
    // 窗口高预算: 标题栏安全区 28 (fullSizeContentView, SwiftUI 自动下推内容) + 顶行 20
    // + 内边距 10×2 + 首行 spacing 8 —— 旧值 44 漏算安全区, 卡片被底缘裁掉一刀 (2026-09-15 实证)
    static let miniWindowChrome: CGFloat  = 76    // 安全区 + 顶行 + 内边距 + spacing
    static let miniCardRowHeight: CGFloat = 52    // 每张任务卡占高 (卡 44 + 间距)
    static let miniWindowEmptyHeight: CGFloat = 116  // 空态高 (安全区 + 顶行 + 一句轻提示)

    // 中间列 · 消息
    static let chatContentWidth: CGFloat   = 800   // 消息/输入卡内容宽 (唯一源头)
    static let chatHPadding: CGFloat       = 48    // 消息列左右内边距
    static let chatVPadding: CGFloat       = 18    // 消息列上下内边距 (24→18 紧凑)
    static let chatMessageSpacing: CGFloat = 10    // 消息块间距 (14→10 紧凑)
    static let welcomeTopPadding: CGFloat  = 160   // 空态欢迎页距顶
    /// 派生: 消息列 frame 宽 = 内容 + 2×水平内边距。
    static var chatColumnWidth: CGFloat { chatContentWidth + chatHPadding * 2 }

    // Composer (输入区)
    static let composerHPadding: CGFloat        = 24   // 输入区左右外边距
    static let composerTopPadding: CGFloat      = 8    // pill 行上方
    static let composerBottomPadding: CGFloat   = 14   // 输入卡下方
    static let composerStackSpacing: CGFloat    = 6    // pill 行与输入卡间距
    static let editorMinHeight: CGFloat         = 88   // 输入框最小高 (= 初始高)
    static let editorMaxHeight: CGFloat         = 200  // 输入框最大高
    static let cardHPadding: CGFloat            = 12   // 输入卡内边距·水平
    static let cardVPadding: CGFloat            = 8    // 输入卡内边距·垂直
    static let controlRowTopSpacing: CGFloat    = 6    // 编辑器与控件行间距
    static let pillHeight: CGFloat              = 24   // 胶囊控件高 (审批/模型 pill)
    static let projectPillHPadding: CGFloat     = 10
    static let projectPillVPadding: CGFloat     = 6
    static let sendButtonSize: CGFloat          = 26
    static let boltIconSize: CGFloat            = 10   // 模型 pill 闪电图标
    static let chevronIconSize: CGFloat         = 9    // 模型 pill 下箭头
    static let levelFontSize: CGFloat           = 12   // 模型 pill 思考级别字号
    static let mentionPopupOffset: CGFloat      = -110 // @引用浮层上移量
    /// 派生: Composer 外框宽 = 内容 + 2×外边距 (与消息列严格同内容宽)。
    static var composerMaxWidth: CGFloat { chatContentWidth + composerHPadding * 2 }

    // Markdown 正文 (13px 正文下的精致化参数)
    static let mdBlockSpacing: CGFloat  = 9      // 块间距 (12→9)
    static let mdLineSpacing: CGFloat   = 2      // 行间距 (13px 正文 ≈1.3 倍行高)
    static let mdHeadingSizes: [CGFloat] = [17, 15, 14, 13, 13, 12.5]  // h1-h6 (随正文 -1)
    static let mdListIndentStep: CGFloat = 16    // 每级列表缩进
    static let mdTableCellHPadding: CGFloat = 10
    static let mdTableHeaderVPadding: CGFloat = 6
    static let mdTableRowVPadding: CGFloat    = 5
    static let mdCodeLineSpacing: CGFloat     = 2.5   // 代码块行距 (12px mono ≈1.35 倍)

    // 侧栏
    static let sidebarWidth: CGFloat          = 256
    /// 项目下会话行缩进 (顶层会话行恒为 8, 见 ConversationRow 的 leading)。
    /// P10.7 修正: 该参数此前是死代码 —— 调用点硬编码 `indent: false`, 层级从未表达。
    static let sidebarRowIndent: CGFloat      = 34
    /// 层级引导线 x (相对子行容器左缘) = 项目行 folder 图标中心:
    /// 项目行 leading 4 + chevron 10 + spacing 6 + folder 半宽 7 = 27。
    /// 不变量: `sidebarGuideInset + 1 <= sidebarRowIndent` (线必须落在子会话图标左侧), 冒烟守住。
    static let sidebarGuideInset: CGFloat     = 27
    static let sidebarRowVPadding: CGFloat    = 5    // 会话行垂直内边距
    static let sidebarProjectRowVPadding: CGFloat = 8 // 项目行垂直内边距

    // 工作区
    static let workspaceWidth: CGFloat = 360

    // 顶栏
    // 顶栏
    static let modePillFontSize: CGFloat   = 11   // Chat/Work 字号
    static let modePillHPadding: CGFloat   = 14
    static let modePillVPadding: CGFloat   = 4    // 原版胶囊层次 (灰容器+白泡+阴影) 依赖此高度
    static let modePillMinWidth: CGFloat   = 50

    // 欢迎页
    static let welcomeMarkSize: CGFloat     = 36  // π 字号
    static let welcomeQuestionSize: CGFloat = 24  // 问句字号
    static let welcomeStackSpacing: CGFloat = 14

    // 状态栏 (未挂载, 保留)
    static let bottomBarHeight: CGFloat = 24

    // 知识库 (P3.7, 阈值留人工调整; 2026-09-10 用户拍板上调)
    static let knowledgeItemCharLimit: Int   = 16000   // 单条内容截断
    static let knowledgeTotalCharLimit: Int  = 64000   // 注入块总量预算
    static let distillMaterialCharLimit: Int = 12000   // 记忆提炼: 对话材料总量截断
    static let distillTimeoutSeconds: Double = 60      // 记忆提炼: 一次性 pi 轮超时
    static let knowledgeListWidth: CGFloat   = 240     // 面板左列宽 (与 sidebarWidth 同量级)
    // 编辑区内容列宽 —— **2026-09-24 拆成三个 token** (原先三页共用一个 `knowledgeEditorMaxWidth`)。
    // 拆的判据: 三处只是**当下取值相同**, 不是同一条约束 —— 知识条目是长文编辑器, 扩展是清单+源码
    // 预览, Schedule 是表单。共用会让"只想动其中一页"的人先要确认另外两页是否被牵连
    // (boss 原话: "尽量分开吧, 别共用, 计算都是 1080 也分开")。
    // ⇒ 改任何一页**只动它自己那一行**, 别为了"一致性"把三个数调回一致。
    // 值的来历: 760 → 1080 (boss 对着 Inbox 编辑区截图: "留白太多了, 其实可以往两边拉一下");
    // 1080 在 boss 当前窗口 (~943pt 可用) 下**不触发上限 ⇒ 直接填满**, 只有更宽的窗口才会收回来。
    // ⚠️ 这是**表单型**编辑区的列宽, 不是阅读栏宽 —— 阅读栏宽另开 token, 别拿这个去收窄正文面。
    static let scheduleEditorMaxWidth: CGFloat  = 1080   // Schedule 编辑区 (Cron / Watch / Inbox 三种编辑器共用同一 wrapper)
    static let extensionEditorMaxWidth: CGFloat = 1080   // 扩展编辑区
    static let knowledgeEditorMaxWidth: CGFloat = 1080   // 知识条目编辑器
    static let knowledgeTitleFontSize: CGFloat  = 17   // 编辑器标题字号

    // 定时任务 (P3.6/P3.9)
    static let scheduleHistoryCharLimit: Int = 4000    // 持续模式注入的近期摘录截取上限
    static let scheduleLogEditorMinHeight: CGFloat = 160 // 编辑器"工作日志"区块最小高
}

// MARK: - ★ 文案区 (Copy)
// 用户可见的默认文案集中于此 (欢迎语/占位符/面板提示等), 改完 Cmd+R 即见。
// 语义规则: 带 () 的是带插值参数的格式文案。
enum Copy {

    // 欢迎页
    static let welcomeMark = "π"
    // **UI 可见文案一律用 `static var`** —— `static let` 是懒加载的一次性求值,
    // 会把 L() 的结果冻结在首次访问, 之后切语言不再跟随。
    static var welcomeQuestion: String { L("今天做点什么？") }

    // Composer
    static var composerPlaceholder: String { L("给 MangoX 发消息…") }
    static let chooseProjectFallback = "Choose project"   // 未选项目时 pill 的占位 (恒英文)
    static let chooseProjectMenu = "Choose project…"      // pill 菜单里的"取消选择" (恒英文)

    // 附件与目录选择面板
    static var attachPanelMessage: String { L("选择要附加的文件") }
    static var newProjectPanelMessage: String { L("选择项目文件夹 (将作为 Agent 工作目录)") }
    static func pickProjectPanelMessage(_ project: String) -> String {
        String(format: L("为「%@」选择工作目录"), project)
    }
    static func attachment(_ path: String) -> String {
        String(format: L(" [附件: %@]"), path)
    }

    // 流式状态
    static var streamingIndicator: String { L("生成中…") }
}

// MARK: - Color hex helper
extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double(hex         & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double(hex         & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: opacity)
    }
}
