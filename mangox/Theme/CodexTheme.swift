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

    // MARK: - Surfaces (light: white/gray · dark: near-black)
    static let bgBase     = adaptive(light: 0xFFFFFF, dark: 0x050507) // app background
    static let bgSidebar  = adaptive(light: 0xF6F6F7, dark: 0x0A0A0D) // nav/left column
    static let bgChat     = adaptive(light: 0xFFFFFF, dark: 0x0D0D10) // conversation
    static let bgRight    = adaptive(light: 0xF6F6F7, dark: 0x0A0A0D) // workspace
    static let bgCard     = adaptive(light: 0xF3F3F5, dark: 0x16161A) // tool call / message card
    static let bgElevated = adaptive(light: 0xEDEDEF, dark: 0x1D1D22) // hover / higher surface
    static let bgInput    = adaptive(light: 0xF1F1F3, dark: 0x131317) // composer background
    static let bgPill     = adaptive(light: 0xE7E7EA, dark: 0x26262B) // composer 上方的胶囊控件（明显浅灰）
    static let bgComposer = adaptive(light: 0xFFFFFF, dark: 0x131317) // 输入卡 (暗色下必须比 bgChat 亮, 否则是黑洞)

    // MARK: - Borders
    static let border     = adaptive(light: 0xE3E3E7, dark: 0x25252B)
    static let divider    = adaptive(light: 0xECECEF, dark: 0x1A1A1E)

    // MARK: - Accent
    static let accent       = adaptive(light: 0xDD5742, dark: 0xDD5742) // warm orange-red (brand primary)
    static let accentSoft   = accent.opacity(0.18)
    static let thinking     = adaptive(light: 0xB07A12, dark: 0xE0A030) // amber/orange left bar
    static let toolRunning  = adaptive(light: 0xB07A12, dark: 0xE0A030) // amber when running
    static let toolDone     = adaptive(light: 0x1A7F37, dark: 0x3FB950) // green when done
    static let toolError    = adaptive(light: 0xD1242F, dark: 0xE5484D) // red
    static let toolQueued   = adaptive(light: 0x6B6B78, dark: 0x6B6B78) // gray-blue for queued
    static let info         = adaptive(light: 0x0969DA, dark: 0x7DA3F0)

    // MARK: - Text
    static let textPrimary   = adaptive(light: 0x24292F, dark: 0xEDEDED) // 柔和近黑 (0x1F2328 太硬)
    static let textSecondary = adaptive(light: 0x57606A, dark: 0x9A9AA3)
    static let textTertiary  = adaptive(light: 0x6E7781, dark: 0x6B6B76)
    static let textMuted     = adaptive(light: 0x9CA3AB, dark: 0x4A4A52)
    static let textMono      = adaptive(light: 0x24292F, dark: 0xC9C9D0)

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
    static let sidebarRowIndent: CGFloat      = 30   // 项目下会话行缩进
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
    static let knowledgeEditorMaxWidth: CGFloat = 760  // 编辑区内容列宽 (与消息列同语言)
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
    static let welcomeQuestion = "今天做点什么？"

    // Composer
    static let composerPlaceholder = "给 MangoX 发消息…"
    static let chooseProjectFallback = "Choose project"   // 未选项目时 pill 的占位
    static let chooseProjectMenu = "Choose project…"      // pill 菜单里的"取消选择"

    // 附件与目录选择面板
    static let attachPanelMessage = "选择要附加的文件"
    static let newProjectPanelMessage = "选择项目文件夹 (将作为 Agent 工作目录)"
    static func pickProjectPanelMessage(_ project: String) -> String {
        "为「\(project)」选择工作目录"
    }
    static func attachment(_ path: String) -> String {
        " [附件: \(path)]"
    }

    // 流式状态
    static let streamingIndicator = "生成中…"
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
