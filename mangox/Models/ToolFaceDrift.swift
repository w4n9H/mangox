//
//  ToolFaceDrift.swift
//  P18: 会话的**工具面**漂移检测 —— "这个会话看不到本次该有的工具"。
//
//  ⚠️ 为什么需要它(2026-10-29 boss 实测): pi 把「本会话有哪些工具」写进**首轮那条
//     system message 的 `toolsAdded`**, 之后每次加载会话都用它**覆盖**当前工具集
//     (pi 的 `_restoreToolsFromTranscript` ⇒ `_setActiveTools(names)`, 是覆盖不是合并)。
//     于是**扩展新增的工具只对新会话生效**: 老会话里模型会说"我没被授予这个工具",
//     而那看起来和"功能没做"一模一样。
//     而且它会**自锁**: pi 本来有"当前工具集 ≠ 会话里那份 ⇒ 追加一条增量声明"的机制
//     (`getToolStateChanges` + `withToolChanges`), 但恢复那一步先把当前工具集压回旧清单,
//     变化检测永远看不到差异 ⇒ 那条增量永远不写。
//
//  ⇒ MangoX 能做的不是"改 pi 的会话文件"(那是内部格式, 写错就毁会话), 而是**说出来**:
//     检测到缺, 在输入框上方常驻一行, 并给"新建对话"的按钮。
//
//  ⚠️ 判据只覆盖 **MangoX 自己那几张工具表**(computer / web-search)。第三方扩展注册了
//     什么工具, MangoX 不知道 ⇒ 不猜(猜了就变成"每次装个扩展都误报")。
//

import Foundation

enum ToolFaceDrift {

    // MARK: - 会话侧

    /// 会话里**钉住**的工具名 —— 语义与 pi 的 `getCurrentTools` **逐条对齐**:
    /// 按行序, 每条 system 消息先 `toolsRemoved` 删、再 `toolsAdded` 加。
    ///
    /// ⚠️ **顺序有意义**: 只在末尾删掉的那一个必须先删后加判断 —— 反过来(先加后删)会让
    ///    同一批里的 `toolsAdded` 被 `toolsRemoved` 吃掉, 结果是"以为缺"的误报。
    ///
    /// 只认 `message.role == "system"`: jsonl 里还有 `thinking_level_change` /
    /// user / assistant 等行型, 它们不携带工具面 (`toolsAdded` 只出现在 system 上)。
    ///
    /// ⚠️ **快筛用字符串包含, 不是"先全量解析再挑"**: 长会话的 jsonl 是几 MB、
    ///    上千行, 逐行 `JSONSerialization` 会把"切个会话"变成可感知的卡顿。
    ///    含这两个键的行一条消息里最多两条(首轮 + 变化时追加), 所以真正解析的只有个位数。
    static func pinnedToolNames(jsonl: String) -> Set<String> {
        var tools = Set<String>()
        jsonl.enumerateLines { line, _ in
            guard line.contains("\"toolsAdded\"") || line.contains("\"toolsRemoved\"") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  msg["role"] as? String == "system" else { return }
            for t in (msg["toolsRemoved"] as? [[String: Any]] ?? []) {
                if let n = t["name"] as? String { tools.remove(n) }
            }
            for t in (msg["toolsAdded"] as? [[String: Any]] ?? []) {
                if let n = t["name"] as? String { tools.insert(n) }
            }
        }
        return tools
    }

    // MARK: - 本次侧

    /// 本次 spawn **真的会挂上**的、且 MangoX 知道其工具名的那些工具。
    ///
    /// 判据与 `PiRpcTransport.spawnProcess` 里那句
    /// `computerHost.start(allowedBundles: activeBundles) != nil` **同源**:
    /// `activeBundles` 空 ⇒ 不起 helper ⇒ 不挂扩展。
    ///
    /// ⚠️ **挂载不看档位 —— 这是定案, 不是没落实的偏差**（2026-10-29 boss 拍板"保持现状"）:
    ///    `extensionArguments(computerExtensionPath:)` 是**独立参数**, 不受
    ///    `mountsBusinessExtensions` 过滤 ⇒ 挂不挂只由**作用域开关**决定(设置页全局 + 对话框),
    ///    standard 档照样挂。**别往这里加"只挂 full"的判据** —— 加了就会对着一个真能用的
    ///    standard 会话报"缺工具"。
    ///
    /// ⚠️ 但**看得见**是另一件事, 由 `--tools` 决定（`AgentMode.toolListArguments`）:
    ///    minimal 传的是 allowlist 四件套 ⇒ 扩展注册的工具被**裁掉**; codemode 只剩 codemode
    ///    一个工具 ⇒ 也调不到。这两档的会话里 `toolsAdded` 天然没有 computer_* ——
    ///    若仍把它们算进 expected, **每一个 minimal 会话都会被报"缺两个工具"**,
    ///    而新建一个 minimal 会话照样没有 ⇒ 一条永远修不好的假警报。
    ///    ⇒ 判据必须是 `exposesExtensionTools`（`AgentMode` 已有这个属性, 且它自己的
    ///      注释就写着"判据是各档 `--tools` 的语义"）。
    ///
    /// ⚠️ **web-search 不在这里**: 它的挂载还要看"有没有配博查 Key + 用户有没有停用",
    ///    判据跨到两个模块去了; 猜错就是每装一个空 Key 的会话都报缺。宁可少报。
    /// ⚠️ **dream 也不算**: 它只在 fire 那一次挂, 会话里根本用不到 ⇒ 算进来等于
    ///    "每一个正常会话都缺 dream 工具", 一次误报就把这条提示变成噪音。
    static func expectedToolNames(computerMounted: Bool,
                                  exposesExtensionTools: Bool) -> Set<String> {
        var out = Set<String>()
        // 挂了扩展 ≠ 模型看得见: 档位把工具裁掉时, 那几行根本不存在于对方的世界里。
        if computerMounted && exposesExtensionTools {
            out.formUnion(PiRpcTransport.computerToolNames)
        }
        return out
    }

    // MARK: - 判据

    /// 钉住的清单里**缺**了哪些。排序后返回 —— 提示文案要稳定, 不能每次换个顺序。
    ///
    /// 空数组 = 不缺(或这个会话还没跑过第一轮, pinned 为空 ⇒ 那不算缺: 新会话首轮
    /// 会按当前工具集重新钉一遍, 不存在"从没钉过却缺"的状态)。
    static func missing(pinned: Set<String>, expected: Set<String>) -> [String] {
        // ⚠️ **pinned 为空必须单独挡掉**: 那时这个会话还没被任何一条 system 声明钉住
        //    (首轮没写进去 / 旧格式), spawn 会直接按当前工具集设置 ⇒ 全部可见。
        //    少了这一句, `expected.subtracting(空)` 就是"整个工具面都缺" —— 每新建一个
        //    会话都先弹一句假警报, 这条提示会立刻变成噪音。
        guard !pinned.isEmpty else { return [] }
        return expected.subtracting(pinned).sorted()
    }
}
