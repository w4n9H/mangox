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

    // ⚠️ P16（2026-10-14）：亮色面族整批退一档 —— **页面底离开纯白**。
    //    判据是参考图实测：它的页面底是 #F8F8F8，我们原来给的是 #FFFFFF。
    //    ⚠️ 这不是配色偏好，是「卡片跳不跳」的问题：纸从纯白退到 #F8F8F8 之后，卡与纸的灰阶差
    //    由 Δ12 收到 Δ7 ⇒ 整页从「每一张卡都在跳」变成「靠形状分组」（参考图的口径）。
    //    ⚠️ 代价明写：纸一退，**所有文字对比度齐降 3~7%**（textTertiary 从页 4.55 / 卡 4.10 掉到
    //    4.28 / 4.03，双双跌破 AA 4.5）⇒ Text 节那两条压深是**配套**，不是顺手美化，两处必须一起动。
    //    ⚠️ `bgInput` / `bgComposer` **有意不动**：输入井在新纸上反而「凹」得出来，碰它等于把
    //    输入卡的层级也一起改了（那是另一件事，见 P16 §04）。
    //    ✔ 守卫：`scripts/diag/palette_probe.py` 的亮色算例（地板 4.5 / 3.0，**两条破线已收**）
    //      + 冒烟 T-COLOR 的暗色段（面链单调性 / 板块色图形地板）。
    static let bgBase     = adaptive(light: 0xF8F8F8, dark: Dark.bgBase) // app background · 窗口底 (最外层)
    static let bgSidebar  = adaptive(light: 0xF1F1F1, dark: Dark.bgSidebar) // nav/left column
    static let bgRight    = adaptive(light: 0xF1F1F1, dark: Dark.bgSidebar) // workspace

    /// **页面底** —— 主区面板的"纸边": 顶栏 / 各面板最外圈。
    /// ⚠️ 大段正文**不坐这一层** —— 那正是 2026-09-21 boss「黑色主题看着眼睛很累」的根因,
    /// 正文请用 `contentPanel`。
    /// ⚠️ P10.8c: **聊天页内部不再用它**（输入区/状态栏已收回 `contentPanel`）——
    /// 面板内部只允许一种底色, 否则相邻两个面之间会出现"无边界元素的硬边"。
    static let bgChat     = adaptive(light: 0xF8F8F8, dark: Dark.bgChat)

    /// **内容面** (P10.8b 新增) —— 主区里 **正文真正坐着的那一层**: 消息列 / 轨迹列表 / 引用块。
    ///
    /// 为什么不直接抬 `bgChat`: 它还兼着"顶栏底 / 各面板最外圈", 抬它会把顶栏一起抬平,
    /// 层次反而糊掉 —— 内容面是**局部**的, 页面底是**全局**的。
    /// ⚠️ P16: 亮色**不再是纯白**（0xFFFFFF→0xF8F8F8）。旧注的「与 bgChat 同为纯白 / 不需要第二层」
    /// 已作废 —— 「白纸 + 灰卡」里的**纸本来就是灰的**（参考图实测 #F8F8F8），纯白是我们自己的偏离。
    /// P10.8c: 底档 (输入区 + 状态栏) 也归这一层 —— **聊天页从顶到底只有一种底色**。
    static let contentPanel = adaptive(light: 0xF8F8F8, dark: Dark.contentPanel)

    /// 输入井 (搜索框/字段面) / 卡面 / 卡内次级面 / 胶囊。
    static let bgInput    = adaptive(light: 0xF1F1F3, dark: Dark.bgInput)
    static let bgCard     = adaptive(light: 0xF1F1F1, dark: Dark.bgCard) // tool card / code block / table
    static let bgElevated = adaptive(light: 0xE9E9E9, dark: Dark.bgElevated) // 卡内次级面 (表头·按钮·工具条) · 设置卡面
    static let bgPill     = adaptive(light: 0xE4E4E4, dark: Dark.bgPill) // composer 上方的胶囊控件（明显浅灰）
    /// 输入卡面 —— 暗色下比**它所在的两种面都暗一档**(正文面 contentPanel / 页面底 bgChat),
    /// 所以既能在聊天页当"凹槽", 又能当其他页面上的字段底 (旧注释说的"必须比 bgChat 亮"已过时)。
    static let bgComposer = adaptive(light: 0xFFFFFF, dark: Dark.bgInput)

    // MARK: - 交互态 (悬停 / 选中)
    //
    // 用**半透明叠加**而不是实色: 实色只在"比它更暗的面"上成立。侧栏选中行 (底=侧栏)、
    // 卡内悬停按钮 (底=卡面)、分段控件 hover (底=容器面) —— 三者底色差了三档, 同一个实色不可能都对。
    // 两个 token 而不是一个: **选中必须比悬停更实**, 否则"当前项在哪"读不出来。
    static let hover    = overlay(dark: Dark.hoverAlpha, light: 0.05)
    /// ⚠️ 亮色档 2026-10-10 由 **0.08 → 0.10**。
    /// 判据 (从参考图量的, 不是凭感觉): Music 式侧栏的选中胶囊实测 `#DCDCDC` 落在 `#F5F5F5` 底上
    /// ⇒ 等价于**黑 10.2% 叠加**; 0.08 合成出来是 `#E2E2E4`, 选中"看得见但不跳出来"。
    /// 这是**全局语义的加强** (分段控件 / 卡面选中一起跟着走), **不是侧栏专用值** ——
    /// 同一个"选中"不该有两套强度, 否则以后必然漂移。
    static let selected = overlay(dark: Dark.selectedAlpha, light: 0.10)

    // MARK: - Borders
    static let border     = adaptive(light: 0xE3E3E7, dark: Dark.border)
    /// ⚠️ P16: 旧值 #ECECEF 落在新的 #F8F8F8 纸上只剩 1.06:1（等于没有）。
    /// 这条是「**换纸必须连带换分隔线**」的实证：分隔线是靠**与纸的差**工作的，纸一动它就得动。
    static let divider    = adaptive(light: 0xE4E4E7, dark: Dark.divider)
    static let guide      = adaptive(light: 0xDCDCE2, dark: Dark.guide) // 侧栏层级引导线 (比 divider 实, 比 border 软)

    // MARK: - Accent
    static let accent       = adaptive(light: 0xDD5742, dark: 0xDD5742) // warm orange-red (brand primary)
    static let accentSoft   = accent.opacity(0.18)
    /// ⚠️ 2026-10-21 起**不再是思考竖条的色**（竖条改用 `railNeutral`）—— 它现在只用于
    /// 「思考中…」状态字与图片工具：**都还是"状态/相态"，符合"颜色只给状态"**。
    static let thinking     = adaptive(light: 0xB07A12, dark: Dark.thinking) // amber: 进行中 / 图片工具
    static let toolRunning  = adaptive(light: 0xB07A12, dark: Dark.toolRunning) // amber when running
    static let toolDone     = adaptive(light: 0x1A7F37, dark: Dark.toolDone) // green when done
    static let toolError    = adaptive(light: 0xD1242F, dark: Dark.toolError) // red
    static let toolQueued   = adaptive(light: 0x6B6B78, dark: Dark.toolQueued) // gray-blue for queued
    /// ⚠️ 2026-10-21 起**不再是工具行的类别色**（竖条 → `railNeutral`，`kind` 标签 → `textTertiary`）。
    /// 现在只剩代码高亮的关键字色。**别拿它去当"工具行"**：那会让代码块的关键字跟着变色。
    static let info         = adaptive(light: 0x0969DA, dark: Dark.info)
    static let blocked      = adaptive(light: 0xB07A12, dark: Dark.blocked) // amber awaiting-approval (P8-T26)

    // MARK: - 工具行 / 思考行的竖条（2026-10-21 boss：左侧配色太鲜艳）
    //
    // 判据：**颜色只给状态，不给类别**。
    //   · 类别（read / edit / bash、思考）**一律中性** —— 它是什么，`bash` 那两个字已经说了；
    //     再上一遍色是**同一信息说两次**，而"一屏 6 行彩色"正是"鲜艳"的来源。
    //   · 颜色留给真正的状态：出错红、待审批琥珀、运行中/思考中琥珀。
    //
    // ⚠️ 竖条与 chevron **不是同一个档**，别合并：
    //   竖条是**装饰**（不承载信息）⇒ 落在 1.15~2.2 的装饰带（亮 1.46 / 暗 1.60）。
    //   chevron 是**可点控件**（"这行能展开"）⇒ 归 WCAG 1.4.11 图形元素，必须 ≥3.0，
    //   所以它跟着 `textMuted`（亮 3.21）走，**不能**跟着竖条一起降到 1.5。
    //   ⚠️ 旧值：工具条 = `info`（亮 4.89）、思考条 = `thinking`@0.7（亮 2.31）—— 都太响。
    static let railNeutral  = adaptive(light: 0xCFCFD6, dark: Dark.railNeutral)

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
    /// ⚠️ P16 配套：换纸之后 textTertiary 从页 4.55 / 卡 4.10 掉到 **4.28 / 4.03**（双破 AA 4.5）
    /// ⇒ 压到 #666E78 修回 4.86 / 4.57。与 textMuted 一起构成「换纸的代价」，不是可选项。
    static let textTertiary  = adaptive(light: 0x666E78, dark: Dark.textTertiary)
    /// ⚠️ P16 配套：它虽然排在「装饰」那一档，实际是**图标**（信息载体）用的色 ——
    /// 旧值在卡上只有 2.30:1，连「UI 组件 3:1」都不到（**今天就已经破线**）。
    /// 压到 #848C94 后：卡上 3.02 / 页上 3.21。
    static let textMuted     = adaptive(light: 0x848C94, dark: Dark.textMuted)
    static let textMono      = adaptive(light: 0x24292F, dark: Dark.textMono)

    // MARK: - Status
    static let statusRunning = toolRunning
    static let statusDone    = toolDone
    static let statusError   = toolError

    // MARK: - Layout
    static let radius: CGFloat         = 8
    static let radiusLg: CGFloat       = 12
    static let radiusSm: CGFloat       = 6
    /// P14 第四批: composer 输入卡专用圆角 (对齐参考图的"大而软"卡形)。
    /// ⚠️ 不并进 `radiusLg` —— 后者是**全局**值 (聊天卡 / 面板 / 分段控件共用),
    ///    改它等于连带改一批与本批无关的面。
    static let radiusComposer: CGFloat = 22

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
    /// P16 §03 改动六: 回合作者小标 —— 比 `fontLabel` 再小一档。
    /// boss 2026-10-14：「回合小标字体不要太大了」⇒ 11pt 跟正文(13)贴得太近, 压到 10。
    static let fontAuthor   = Font.system(size: 10, weight: .medium)

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
        // 板块色（P16 收进来）—— 在此之前它们的暗色侧**直接写在 `adaptive(dark: 0x…)` 里**，
        // 于是 `enum Dark` 不是暗色的唯一真源，**算例与冒烟都看不见它们**
        // （`palette_probe.py` 旧版只解析这个 enum ⇒ 板块色一个都没进守卫）。
        // 收进来之后：暗色值只有一个地方可改，守卫也终于拿得到。
        // ⚠️ 三个名字同值是有意的 —— `thinking`/`toolRunning`/`blocked` 语义不同，
        //    将来谁想单独动其中一个，不该先拆别名。
        static let info: UInt32       = 0x7DA3F0
        static let thinking: UInt32   = 0xE0A030
        static let toolRunning: UInt32 = 0xE0A030
        static let toolDone: UInt32   = 0x3FB950
        static let toolError: UInt32  = 0xE5484D
        static let blocked: UInt32    = 0xE0A030
        /// 工具行 / 思考行的竖条（**装饰档**，2026-10-21 起）。判据是"看得见但不抢"：
        /// 亮 1.46 / 暗 1.60 —— 与 `guide` 同族偏实一档，远低于旧值（亮 `info` 4.89）。
        /// ⚠️ 别把它抬过 2.2：那正是 boss 说的"太鲜艳"的区间。
        static let railNeutral: UInt32 = 0x43434F
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
    /// 设置窗 (P14: 设置从主区整页覆盖升为**独立窗口**, 由 SettingsWindowController 承载)。
    /// 尺寸按 "8 个 section 里一眼能看见 3~4 段、其余滚动" 定; 2026-10-10 首版 760×640 实测偏挤 ⇒ 放大。
    static let settingsWindowSize    = CGSize(width: 920, height: 780)
    /// 设置窗的收缩下限 = 首版尺寸 (窗口可拖大; 再小就回到"挤"的状态, 没有意义)。
    /// ⚠️ 它是**首选下限**不是硬下限: 主窗口比它还小时, 下限跟着主窗口一起缩
    ///    （"不能超过主窗口"优先 —— 见 `SettingsWindowController.fit`）。
    static let settingsWindowMinSize = CGSize(width: 760, height: 640)
    /// 设置窗与主窗口之间**每边**至少留的空隙（2026-10-26 boss: 弹出页不能超过主窗口）。
    /// 24 是为了让底下的主窗口露出边框 —— 贴齐会读成"整窗替换", 分不出这是一个浮窗。
    static let settingsWindowMargin: CGFloat = 24
    /// 设置页左侧分类列宽的**地板**（2026-10-26 排版骨架 / 2026-10-27 改成只托底）。
    ///
    /// ⚠️ 这不是列宽本身 —— 列宽由**最宽那一行标签**撑开（`SettingsShell.categoryList`
    /// 末尾的 `fixedSize`）。定过两次定宽都翻车：168 是「左侧留白太大」，128 是英文
    /// `Integrations` 在词中断行。根因是 HStack 会把剩余空间在 `Text` 与 `Spacer` 之间
    /// 对半分，任何"刚好装下"的数字都会在某语言/某字号下不够。
    /// 120 只保证中文两字标签不窄成一条线；英文实际会撑到 ~121，中文留在 120。
    static let settingsSidebarMinWidth: CGFloat = 120
    /// 工作区图片预览的渲染上界 (超过就靠 ScrollView 滚; 不放大到糊)
    static let workspacePreviewImageMaxSide: CGFloat = 1600

    // 迷你条 (P4.2, 主窗口变形为任务台)
    static let miniBarWidth: CGFloat      = 300   // mini 台窗口宽
    // 窗口高预算: 标题栏安全区 28 (fullSizeContentView, SwiftUI 自动下推内容) + 顶行 20
    // + 内边距 10×2 + 首行 spacing 8 —— 旧值 44 漏算安全区, 卡片被底缘裁掉一刀 (2026-09-15 实证)
    static let miniWindowChrome: CGFloat  = 76    // 安全区 + 顶行 + 内边距 + spacing
    static let miniCardRowHeight: CGFloat = 52    // 每张任务卡占高 (卡 44 + 间距)
    static let miniWindowEmptyHeight: CGFloat = 116  // 空态高 (安全区 + 顶行 + 一句轻提示)

    // 中间列 · 消息
    // ⚠️ P16: 800 → 680。参考图的内容列只占可视宽 53.6%，我们原来占 67.6% ⇒ 正文行长过宽。
    //    取 680 而不是参考图换算出来的 634：给代码块与宽表留余量（取舍记在 P16 §04 待拍板 6）。
    //    ⚠️ 它是**唯一源头** —— composer 宽由 `composerMaxWidth` 派生，改这一处两列一起变。
    static let chatContentWidth: CGFloat   = 680   // 消息/输入卡内容宽 (唯一源头)
    static let chatHPadding: CGFloat       = 48    // 消息列左右内边距
    static let chatVPadding: CGFloat       = 18    // 消息列上下内边距 (24→18 紧凑)
    // ⚠️ P16 修正 (0.1.18 的回归): 这两件是**两件事**, 不能用一个数管 ——
    //    · 回合**之间**(用户 ↔ 助手) 该松: 一眼看出换了人说话
    //    · 回合**内部**(思考 / 工具行 / 正文, 各是一条**独立 message**) 该紧: 读起来是连续的一整段
    //    曾一律给 24 ⇒ 回合内那段连续输出被一起拉松。判据见下「排版节奏」。
    static let chatMessageSpacing: CGFloat = 24    // **回合之间**间距 (用户 ↔ 助手)
    static let chatBlockSpacing: CGFloat   = 10    // **回合内部**块距 (同 role 连续的块)

    /// P16 §03 改动六 · 2026-10-14 boss 拍板: 每**回合首行**一枚作者小标, 用来区分"谁说的"。
    /// ⚠️ 与 `chatBlockSpacing` 是**两件事** —— 小标只出现在回合首条（不是每条消息），
    ///    且**第一条消息也要有**；而补间距用的 `isTurnStart` 首条为 false（顶部已有 chatVPadding）。
    /// ⚠️ `You` / `MangoX` 是**角色标签, 原样保留英文**（与 Chat / Trace / USER / ASSISTANT 同族）。
    /// ⚠️ **字号不在这里** —— 它住字体段 `CodexTheme.fontAuthor`（字号属于字体系统, 不是布局参数）。
    static let authorLabelSpacing: CGFloat  = 5    // 小标与它下面那个块的间距
    /// 空态欢迎页距顶 (**只在侧问空态 `sideEmptyState` 用** —— 主空态已改成整块垂直居中)
    static let welcomeTopPadding: CGFloat  = 160
    /// 派生: 消息列 frame 宽 = 内容 + 2×水平内边距。
    static var chatColumnWidth: CGFloat { chatContentWidth + chatHPadding * 2 }

    // Composer (输入区)
    static let composerHPadding: CGFloat        = 24   // 输入区左右外边距
    static let composerTopPadding: CGFloat      = 8    // pill 行上方
    static let composerBottomPadding: CGFloat   = 14   // 输入卡下方
    static let composerStackSpacing: CGFloat    = 6    // pill 行与输入卡间距
    /// 输入框最小高 = **初始高**（空文本时 `CompactTextEditor` 报回来的就是它）。
    ///
    /// ⚠️ **88 → 44（2026-10-16 boss：`输入框太高了，严重积压了对话区域，我感觉至少可以减少一半`）**。
    ///    那 88 是 P14 第四批对齐参考图时定的，但**没有一条约束需要它** —— 一屏里它白占约 44pt，
    ///    而空输入框真正被用到的只有顶部那一行（14pt 字 ≈ 17pt 行高 + 上下 inset 4 ≈ 21pt）。
    ///    改完的账：输入卡 **143 → 99pt**，整块输入区 **195 → 151pt**。
    /// ⚠️ **它的下限由控件行顶出来，不是随便减**：卡高 = 8(上内边距) + 本值 + 6(行距) + 33(控件行，含 33pt 发送键) + 8(下内边距)。
    ///    要 1 行字放得下，本值不低于 ~40；再想矮就得动 `sendButtonSize` 或那两处内边距，别只往下砍这个数。
    /// ⚠️ 它**同时**是 `@State editorHeight` 的初值与 `CompactTextEditor(minHeight:)` —— 两处都读这个 token，
    ///    所以改它不会首帧跳变（**别在任何一处写死数字**）。
    static let editorMinHeight: CGFloat         = 44   // 输入框最小高 (= 初始高)
    static let editorMaxHeight: CGFloat         = 200  // 输入框最大高
    static let cardHPadding: CGFloat            = 12   // 输入卡内边距·水平
    static let cardVPadding: CGFloat            = 8    // 输入卡内边距·垂直
    static let controlRowTopSpacing: CGFloat    = 6    // 编辑器与控件行间距
    static let pillHeight: CGFloat              = 24   // 胶囊控件高 (审批/模型 pill)
    static let projectPillHPadding: CGFloat     = 10
    static let projectPillVPadding: CGFloat     = 6
    // P14 第四批: 26 → 33。占卡高比 17.4% → 23.6% (对齐参考图实测值 63px ÷ 1.889)。
    static let sendButtonSize: CGFloat          = 33
    static let boltIconSize: CGFloat            = 10   // 模型 pill 闪电图标
    static let chevronIconSize: CGFloat         = 9    // 模型 pill 下箭头
    static let levelFontSize: CGFloat           = 12   // 模型 pill 思考级别字号
    static let mentionPopupOffset: CGFloat      = -110 // @引用浮层上移量
    /// 派生: Composer 外框宽 = 内容 + 2×外边距 (与消息列严格同内容宽)。
    static var composerMaxWidth: CGFloat { chatContentWidth + composerHPadding * 2 }

    // Markdown 正文 (13px 正文下的精致化参数)
    //
    // ⚠️ P16：「排版节奏」不是一个参数，而是**两条各自单调的链**（各管一维，别硬拼成一条）：
    //        · markdown 内部：行间隙 mdLineSpacing < 段间隙 mdBlockSpacing         （6 < 16）
    //        · 消息层：     回合内块距 chatBlockSpacing < 回合之间 chatMessageSpacing（10 < 24）
    //        ⚠️ 跨层的那两个（段间距 16 / 回合内块距 10）**没有必然的大小关系** —— 一个是
    //           "同一条正文里的两段"，一个是"两件事之间"。硬排成一条链会写出一个假的顺序，
    //           而且以后调任何一头都会撞到它。
    //        ⚠️ 同一维里写反的后果：段间隙 > 消息间隙 ⇒ 消息之间比消息内部还紧，两条消息被
    //           读成一条；回合内块距 > 回合之间 ⇒ 换人说话看不出来。两边都只能靠出图看出来。
    //    ✔ 守卫 = 冒烟 T-COLOR 段的两条单调性断言（断**大小关系**，不断具体值）。
    static let mdBlockSpacing: CGFloat  = 16     // 段间距 (P16: 9→16)
    static let mdLineSpacing: CGFloat   = 6      // 行间距 (P16: 2→6; 13px 正文 ≈1.65 倍行高)
    static let mdHeadingSizes: [CGFloat] = [17, 15, 14, 13, 13, 12.5]  // h1-h6 (随正文 -1)
    static let mdListIndentStep: CGFloat = 16    // 每级列表缩进
    static let mdTableCellHPadding: CGFloat = 10
    static let mdTableHeaderVPadding: CGFloat = 6
    static let mdTableRowVPadding: CGFloat    = 5
    static let mdCodeLineSpacing: CGFloat     = 2.5   // 代码块行距 (12px mono ≈1.35 倍)
    /// 代码块超过**这么多行**就改成逐行渲染。
    ///
    /// ⚠️ 为什么要有这条(2026-10-29 boss「读 safari 的那个会话往上拉卡顿严重」): 整块
    ///    `Text(AttributedString)` 的排版代价对**又宽又长**的代码块是**平方级**的。实测那条
    ///    消息里是 1 个代码块 / 124 行 / 6592 字符 / 最长单行 522 字符 —— 而横滚态是
    ///    `.fixedSize(horizontal: true)`(不折行), 等于让 CoreText 排一块约 3600pt 宽、
    ///    124 行高的文本, 主线程直接卡住。逐行以后每行只算自己那一行, 总量回到线性。
    ///
    /// 阈值取 40: 一般贴的代码块都在 40 行以内(那一类**保持整块渲染, 视觉与原来逐字相同**),
    ///    而踩到这一条的都是"整段日志 / 整页快照"那种真的会卡的。
    static let codeBlockSplitLines: Int       = 40

    // 侧栏
    static let sidebarWidth: CGFloat          = 256
    /// 侧栏滚动内容的左右内缩 (原为硬编码的 8)。
    /// 2026-10-10 对齐 Music 式侧栏: 图标列 17.4 → 22.4pt (参考图 icon 左沿 26/219pt ≈ 11.9%,
    /// 按同比例落到 256pt 宽还要更靠右, 这里只取**半步** 8+5)。
    /// ⚠️ 它作用于**整块滚动内容** —— 一起走的还有项目行 / 层级引导线 / 会话胶囊 / 搜索框。
    ///    别只改某一行, 否则侧栏左沿会参差不齐。
    static let sidebarContentInset: CGFloat   = 13
    /// 侧栏搜索框 (P14)。高度对齐 macOS 标准 sidebar 搜索框; 填充复用 `bgPill`
    /// (`#E7E7EA` 正好等于参考图实测的"黑 6% 叠加", 无需新 token)。
    static let sidebarSearchHeight: CGFloat   = 28
    static let sidebarSearchRadius: CGFloat   = 7
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
    /// 工作区 tab 条的文字区高度 (不含下面那条 2px 选中线)。
    static let workspaceTabHeight: CGFloat = 30
    /// 文件预览正文字号。**与 `CodexTheme.fontMonoXs` 是同一个数, 留一份是因为要把这个数字
    /// 交给 `NSFont` 去预量最长行的宽度** —— 不预量的话 `LazyVStack` 会退化成全量布局
    /// (实测 4K→115K 文件从 8 ms 变回 35 s)。两处要一起改。
    static let workspacePreviewFontSize: CGFloat = 11

    // 顶栏
    // 顶栏
    static let modePillFontSize: CGFloat   = 11   // Chat/Work 字号
    static let modePillHPadding: CGFloat   = 14
    static let modePillVPadding: CGFloat   = 4    // 原版胶囊层次 (灰容器+白泡+阴影) 依赖此高度
    static let modePillMinWidth: CGFloat   = 50

    /// 左上会话名: 窗口左缘 → 标题**文字左沿**的距离 (2026-10-16 从 boss 截图量得, 135.5pt)。
    /// 组成 = 交通灯区 + 侧栏开关 + 最小化按钮 + 各自间距 —— 三者都钉在窗口左缘、宽度固定 ⇒ 常量。
    static let topBarTitleLeadingInset: CGFloat = 136
    /// 标题右缘与侧栏分隔线之间的留白 (不让文字贴线)。
    static let topBarTitleTrailingGap: CGFloat  = 8
    /// 左上会话名的**定宽** —— 判据 = "标题不许越过分隔线"。
    /// ⚠️ 必须给**定宽**, 不能只靠调用点那个 `lineLimit(1)`: 标题住在 toolbar 的 `.navigation` 区,
    ///    macOS 按内容的**理想宽**排版、并不按侧栏宽去约束它 ⇒ 没有定宽时 `lineLimit` 永远不触发,
    ///    10 字标题会直接压过分隔线约 11pt (实测: 分隔线在 256pt, 标题墨迹 135.5→266.9pt)。
    /// ⚠️ 侧栏收起时**仍用同一个宽**: 分隔线那时落在窗口左缘(无参考线), 但标题保持同列宽才不会
    ///    因为 toggle 侧栏而忽长忽短。
    static var topBarTitleWidth: CGFloat {
        sidebarWidth - topBarTitleLeadingInset - topBarTitleTrailingGap
    }

    // 欢迎页
    /// 字标字号。⚠️ 从 26 降到 18 是**换了东西**：26 是给单个大写 `X` 的 cap-height 对齐值，
    /// 现在这行是 `MangoX` **字标**（wordmark）—— 字标在标题上方就该小一号 + 加分字距，
    /// 否则两个 24pt 级别的词挤在一起，读起来像"两个标题"。
    static let welcomeMarkSize: CGFloat     = 18
    static let welcomeMarkTracking: CGFloat = 1.5  // 字标分字距 (全大写/品牌名才加; 中文会失真, 但字标是英文)
    static let welcomeQuestionSize: CGFloat = 24  // 问句字号
    static let welcomeStackSpacing: CGFloat = 14

    // 状态栏 (未挂载, 保留)
    static let bottomBarHeight: CGFloat = 24

    // 知识库 (P3.7, 阈值留人工调整; 2026-09-10 用户拍板上调)
    static let knowledgeItemCharLimit: Int   = 16000   // 单条内容截断
    static let knowledgeTotalCharLimit: Int  = 64000   // 注入块总量预算
    static let distillMaterialCharLimit: Int = 12000   // 记忆提炼: 对话材料总量截断
    static let distillTimeoutSeconds: Double = 60      // 记忆提炼: 一次性 pi 轮超时
    /// P12.1a: 引擎启动后"一句话都没说"的容忍时长。pi spawn 后正常会立刻回
    /// get_state / get_available_models / get_session_stats ⇒ 到这个点仍零上行就是启动失败。
    /// 取 8s 与 `settleStatsTask` 同量级: 冷启动 Node + 载扩展在慢盘上可能数秒,
    /// 定太短会对"只是慢"的机器误报 (宁可慢一拍, 不可误报)。
    static let engineSilenceSeconds: Double = 8
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

    // P15.6 立了"dream 的会话摘要预算"这组数（取代"让模型自己去 bash 读 pi-sessions"—— 那条路没有上界）。
    // **P17 按 256k 上下文重拼**，三处有意改动：
    //   ① 窗口 `21 天 → 36 小时`：dream 从周更改成日更（`dreamDefaultCron`）之后，"三周的量"与
    //      "一天的量"根本不是一回事了。取 36 而不是 24 是因为日更两次之间总有抖动，
    //      多出来的 12 小时造成的**重复读是可以接受的代价**（丢失不行）。
    //   ② **会话数上限整条取消**：范围改由窗口决定。原来那个 `MaxSessions` 是配套"三周窗口"的，
    //      窗口一收，它就从"保护"变成了"无谓地砍掉当天的会话"。
    //   ③ 两级字符上限按 256k 分账（见下），单会话的裁法也从 `suffix` 改成**按回合整对丢**。
    //
    // ⚠️ 单位是**字符**（判据 `content.length`），与 `knowledgeTotalCharLimit` 同一本账。
    //    中文约 1 字符 ≈ 0.5~1 token ⇒ 按字符算偏保守，而这份保守正好留给模型输出的位置。
    static let dreamDigestWindowHours: Int         = 36      // 只看最近 36 小时（还有水位兜底，见 dreamDigestSince）
    static let dreamDigestMaxCharsPerSession: Int  = 40000   // 单会话上限（超了按**回合整对丢**）
    static let dreamDigestTotalChars: Int          = 100000  // 整段上限（超了从最旧的会话开始丢）

    // 定向 dream（boss 2026-10-21 定：`由此 Dream`）—— 对**一场指定会话**做整场整理。
    // 与上面三个数**分账**：那些管"最近窗口里的每一场各给多少"，这个只管"单场最多喂多少"。
    //
    // 为什么是 256k 而不是"无穷大": 它必须比常规单会话预算（4 万）大一个量级才叫"整场"，而
    // **又不能超过模型上下文**。256k 与 P17 重拼上下文时用的那个量级同一个来源 ⇒ 不是新拍的数。
    // 超了仍然是 `trimMaterialByTurns` 那条**按回合整对丢 + 点名**，不静默截断。
    static let dreamTargetedMaxChars: Int          = 256000  // 定向单场上限（boss 指定 256k）

    // P17: dream 的**笔记侧**两个预算 —— 目录 + 正文两层。
    // 目录复用现有的 `indexBlock` 形状（一行一篇），正文是 P17 新开的（省掉模型自己 read 的往返）。
    // ⚠️ 这两段**只在 dream 的 fire 时拼进 prompt**，与常驻的 `[笔记]` 段
    //    （`knowledgeTotalCharLimit = 64000`）**完全分账** —— 把常驻段一起抬，多花钱的是
    //    每一轮普通对话，而 dream 一个月才跑 30 次。
    static let dreamNoteIndexChars: Int            = 20000   // 目录（兜底：2~3 个根实际远不到）
    static let dreamNoteBodyChars: Int             = 120000  // 正文（超了从最旧的丢 + 点名）

    // dream 的**提案粒度**上限（2026-10-22）。
    //
    // 起因是一份真实的坏结果: 一次定向 dream 对着一场会话出了 8 条提案, 而这 8 条其实是
    // 「27b 模型部署」这一个项目的一件事的 6 个侧面（服务暴露 / 模型事实卡 / 云平台 / 选型 /
    // 基准方法 / vLLM 版本）。boss 的原话是「人的审核成本太高」。
    //
    // ⚠️ 它是 prompt 里的**软约束**（指令正文原样引用这个数），**不是收口时的硬砍** ——
    //    硬砍砍掉的可能是那批里最值钱的一条, 而"少提了几条"这件事在日志里是看得见的
    //    （`dreamSummary` 会点名）。同源同改: `dreamPrompt` 与 `note_proposal` 的工具描述。
    static let dreamMaxProposals: Int              = 3

    // 时间线（App 侧自动记账, 不经过模型也不进审核队列）。
    // 落点 = `<笔记根>/timeline/YYYY-MM.md`（归属仍走「位置即归属」, 不新开一套目录概念）。
    //
    // ⚠️ 注入面这三个数**每一轮普通对话都要付**（它进常驻段）⇒ 刻意压得很小:
    //    真正的时间线是磁盘上那篇笔记（需要时 read），常驻段只给"最近几天发生了什么"的引子。
    static let timelineRecentDays: Int             = 7      // 注入最近几天
    static let timelineInjectChars: Int            = 1200   // 注入段字数上限
    static let timelineInjectRowsPerDay: Int       = 6      // 每天最多几行（多的折成「另 N 条」）

    // P17 · 运行可靠性: 漏跑清单的回溯上限。
    // 它兜的是「任务从没跑过 / 新建后一直没跑」这一档 —— 窗口不能从 `createdAt` 无限往前拉。
    // 7 天 = 10080 分钟 ⇒ 单任务最坏一万次 cron 匹配（微秒级, 且先在分钟位上筛一道）。
    static let missedFiresLookbackDays: Int        = 7

    // 工具行 (P16): 展开区的固定高 —— **两个数有意不同**。
    // 判据: 输出区是"跑完命令的结果", 看一眼就够; diff 是"块对照", 要看到足够多行才读得出改动。
    // ⚠️ 都是**上界**不是定高 —— 短内容按自身高度收, 只有超了才滚 ⇒ 高度与内容长度**脱钩**。
    // ⚠️ 输出区这个数**同时是行为开关**: 没有它, 工具输出会随内容无限长 (P16 立项的起因)。
    static let toolOutputMaxHeight: CGFloat = 180   // 工具输出区 (固定高滚动区)
    static let toolDiffMaxHeight: CGFloat   = 260   // 审批卡 diff 预览 (原硬编码在 DiffPreviewView)
    /// 工具行右侧徽标的**固定宽度** (2026-10-19) —— 治"连续快调 tool 时整行闪"。
    /// 徽标在三态之间宽度天然不同 (`等待` / 圈+`运行中` / 耗时+`完成`), 而左边命令是
    /// `lineLimit(1)` 自适应的 ⇒ 徽标一变宽, 命令就被挤窄、截断位置跳一次。快速连发把三次
    /// 跳变压进几十毫秒, 看着就是闪; 慢工具那三次隔了几秒, 感知不到。定宽 + 右对齐 ⇒
    /// 命令的可用宽度从头到尾不变。取 64 = `999ms 完成` (5 字符 mono 11pt + 6 间距 + 2 汉字)。
    static let toolPhaseBadgeWidth: CGFloat = 64

    // 轨迹页行布局 (2026-10-21 boss「左边的小框没对齐 / 右边的显示看上去挺混乱的」)。
    //
    // 病根是**没有列**：左标签框宽度随标签走 (实测 `ls` 19pt / `bash` 35pt / `codemode` 65pt /
    // 英文 `ASSISTANT` 70pt), 于是右侧正文的起点跟着漂 4 个位置; 展开区又各自写死 30pt,
    // **比任何一个正文列都靠左** ⇒ "框和内容各说各话"。同理右侧: 耗时是 `fixedSize()` 自然宽,
    // 相态徽章紧跟在后面 ⇒ 有耗时的行和没耗时的行, 圆点相差 30pt。
    //
    // 判据: **一行里所有"列"的位置只能由这几个常量决定, 不能由内容长度决定。**
    /// 左标签列定宽 —— 取 72 = 最宽标签 (英文 `ASSISTANT` 58.4 + 12 内边距) 且留 1.6 余量,
    /// 所以四个 kind 标签**一列同宽**, 不做缩放也不截断 (标签是 `rawValue`, 截一半就没法 grep 了)。
    static let traceRailWidth: CGFloat = 72
    /// 标签列与正文列之间的缝 (也是行内 `HStack` 的 spacing, 两处必须同一个数)。
    static let traceGutter: CGFloat = 10
    /// 正文列起点 = 标签列 + 缝。**展开区 (diff/输出/usage) 用它缩进** —— 展开内容是行的
    /// 续行, 续行对齐正文, 不对齐标签。
    static var traceBodyInset: CGFloat { traceRailWidth + traceGutter }
    /// 右侧耗时列。**永远占位** (没耗时就渲染空串) —— 否则"运行中"的行会顶到耗时列里,
    /// 圆点列当场断一截。右对齐: 数字的右边缘成列, 扫一眼就能比长短。
    static let traceDurationWidth: CGFloat = 40

    // 分享成图片（2026-10-22）。三个数就够了 —— 渲染宽、卡片内边距、长度上限。
    /// 出图宽度 (pt)。720 = 「知识库注入面板」同宽 (那里也是 markdown 预览, 窄了层级全挤一起)。
    static let shareWidth: CGFloat = 720
    /// 卡片内边距 (pt)。比正文栏的 `chatHPadding` 大: 图是要**单独看**的, 留白不足会显得挤。
    static let sharePadding: CGFloat = 26
    /// 长图上限 (pt): **3 屏封顶, 超了就不出图** (2026-10-22 boss 拍板)。
    ///
    /// ⚠️ **「一屏」= 聊天窗口正文的可见高度, 不是"一条回复的高度"** —— 初版把这两个混了,
    ///    按 250pt/屏 推出 750, 而 250 只是"一条普通回复占多高"(实测 252/328/453),
    ///    跟屏幕毫无关系 ⇒ 750 实际只有 **0.86 屏**, 把 boss 一条 1324pt 的正常长回复判成了"太长"。
    ///    实测口径 (同一台机): 屏幕 1920×1080@2x · 窗口 **1280×872pt** · 扣掉底栏输入区(~151)
    ///    与顶栏 ⇒ **正文可见 ≈ 700pt** ⇒ 3 屏 = 2100pt。
    /// ⚠️ 这是**唯一**的长度判据: 没有"降 1x 凑一张"的分支 —— 要么出 2x, 要么不出。
    /// ⚠️ 判据在**布局之后**用 (高度只有真排版才准; 按字符数预估会说谎)。
    /// ⚠️ 2100pt @2x = 1440×4200px, 远在 IM 长图上限之内 —— 再抬上去也不会被压, 但**可读性**会掉
    ///    (缩到屏宽后字变小), 所以别顺手往 3000+ 抬。
    static let shareMaxHeight: CGFloat = 2100

    // 回到最新 (2026-10-16 boss: "往上翻了记录, 还要再往下翻才能到最底部")。
    // 它是挂在消息列底缘的**浮层** —— 不占布局流, 所以整件事只有这两个数。
    // ⚠️ 只响应点击, **绝不自动滚** —— "上滑阅读不拽回"是 P9-#9 立的规矩 (判据 = ChatView.isNearBottom);
    //    让这个按钮顺手接管自动跟随 = 那个规矩当场作废。
    static let jumpToLatestSize: CGFloat  = 30   // 圆形按钮直径 (13pt 图标 + 上下呼吸)
    static let jumpToLatestInset: CGFloat = 12   // 距消息列底缘的留白
}

// MARK: - ★ 文案区 (Copy)
// 用户可见的默认文案集中于此 (欢迎语/占位符/面板提示等), 改完 Cmd+R 即见。
// 语义规则: 带 () 的是带插值参数的格式文案。
enum Copy {

    // 欢迎页
    /// 字标（2026-10-20 boss：「那个 x 改成 mangox 应该能好点」）。
    /// ⚠️ 原来是单个大写 `X` —— 在空态左上角读起来就是个**关闭按钮**（✕），
    ///    而且贴左时更像个跑偏的图标。换成品牌名后它自己就是"落款"，不会再被当成控件。
    static let welcomeMark = "MangoX"
    // **UI 可见文案一律用 `static var`** —— `static let` 是懒加载的一次性求值,
    // 会把 L() 的结果冻结在首次访问, 之后切语言不再跟随。
    static var welcomeQuestion: String { L("今天做点什么？") }

    // Composer
    static var composerPlaceholder: String { L("给 MangoX 发消息…") }
    // ⚠️ 必须是 `static var` + `L()`: 若写成 `static let`，取词只在**首次访问**时发生，
    //    之后切语言这两个 pill 就冻在旧语言里（本地化门 ②「冻结取词」要红的那一类）。
    static var chooseProjectFallback: String { L("选择项目") }   // 未选项目时 pill 的占位
    static var chooseProjectMenu: String { L("选择项目…") }      // pill 菜单里的"取消选择"

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

    // 回到最新按钮 (浮层 tooltip; 文案与图标语义一致 —— "最新"指流末尾, 不是"页面底部")
    static var jumpToLatest: String { L("回到最新") }

    // 上下文压缩 (A + D)
    //
    // ⚠️ A 的文案**必须在渲染期**取词: 消息里存的是 `.compaction(tokensBefore:tokensAfter:reason:)`
    //    结构化字段, 不是拼好的句子 —— 存句子就等于把当时的语言冻在库里 (切语言后永远不跟随)。
    /// 消息流里的常驻标记。与 8s 横幅同一件事, 措辞有意不同:
    /// 横幅是"刚发生了什么"的**播报**, 标记是"这里断过一次"的**档案** ⇒ 用"已压缩"。
    ///
    /// `reason` 是 pi 的原值 (`manual` / `threshold` / `overflow`), 判据**放在这里**而不是
    /// 落库成枚举: 第三方契约值随时可能多出第四种, 不认识的照实显示成"已压缩"即可,
    /// 而"用户自己压的"必须和"引擎自己压的"分得出来 —— 那是回看时唯一有意义的一维。
    static func compactedMarker(reason: String, before: Int, after: Int) -> String {
        switch reason {
        case "manual":
            return String(format: L("你手动压缩了上下文 · %lld → %lld tokens"), before, after)
        case "threshold":
            return String(format: L("上下文自动压缩（接近上限）· %lld → %lld tokens"), before, after)
        case "overflow":
            return String(format: L("上下文自动压缩（溢出恢复）· %lld → %lld tokens"), before, after)
        default:
            return String(format: L("上下文已压缩 · %lld → %lld tokens"), before, after)
        }
    }
    /// 标记的 tooltip —— 一句话说清"为什么该在意这一行"。
    static var compactedMarkerHelp: String {
        L("更早的消息仍在会话记录里，但模型不再看到原文 —— 它只看到一份摘要。")
    }

    /// 用户消息折叠 (2026-10-19): 「还有 N 行 · 展开」。
    /// ⚠️ 必须报**确切行数** —— "内容被折叠"和"内容被吞了"是两件事, 后者不可接受。
    /// `0` 行 = 行数没超, 是被字符上限截的 (单行超长那种), 换成"内容较长"。
    static func userMessageExpand(hiddenLines: Int) -> String {
        hiddenLines > 0
            ? String(format: L("还有 %lld 行 · 展开"), hiddenLines)
            : L("内容较长 · 展开")
    }

    static var userMessageCollapse: String { L("收起") }
    /// 压缩进行中胶囊。原来直接把 pi 的值拼成「压缩中（threshold）…」—— 中文界面里
    /// 冒出一个英文契约值, 看着像没做完; 而且 `threshold` 这个词对用户没有意义。
    /// ⚠️ 胶囊的判据与标记的判据**共用同一套 reason 语义**, 别在两处各写一份映射。
    static func compactingCapsule(reason: String) -> String {
        switch reason {
        case "manual":    return L("压缩中 · 手动…")
        case "threshold": return L("压缩中 · 接近上限…")
        case "overflow":  return L("压缩中 · 溢出恢复…")
        default:          return L("压缩中…")
        }
    }
    /// 底栏 (D): 「上下文 62.4% / 压缩线 91.8%」。
    /// 压缩线 = (窗口 - 预算) / 窗口, 取自 pi 的 `compaction.reserveTokens`
    /// (见 `PiCompactionBudget`) —— 到这条线 pi 才会压缩, 不是我们另立的阈值。
    static func contextWithLine(_ pct: String, _ line: String) -> String {
        String(format: L("上下文 %@ / 压缩线 %@"), pct, line)
    }
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
