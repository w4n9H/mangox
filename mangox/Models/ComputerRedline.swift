//
//  ComputerRedline.swift
//  P18 批 1/2: 红线判据 —— 遮蔽 + 三条**恒拒**。全是纯函数, 喂字符串进、出决定。
//
//  两层结构里的第二层 (P18 §03 改动七; 2026-10-28 改版):
//    第一层是"结构上做不到"(系统授权窗不给 AX 根 / helper 只有 trashItem) —— 不在本文件;
//    本文件是第二层: **做之前就判**, 而且判完只给一个答案, 不许弹卡等人点。
//
//  ⚠️ 为什么这三条不能"弹卡让人点": 它们挡的是**模型替人做决定**这件事本身 ——
//     "要不要丢弃未保存的修改"、"要不要真的付钱"、"要不要永久删除"。人坐在那儿的时候
//     模型没有资格替他答; 人不在那儿的时候(定时任务/远程档)更没资格。⇒ 恒拒, 不是"问问"。
//
//  ⚠️ 判据一定是**认得出来的那种**: 靠控件标题与角色, 不靠"理解业务"。认字就够 ——
//     一旦要求"先理解这个按钮在这个 App 里意味着什么", 判据就变成了模型自觉, 也就没了。
//     代价是误伤(见 §05 代价表): 误伤了加豁免, 豁免也要能变红。
//

import Foundation

/// 三种恒拒。`rawValue` 是**留痕串**, 会进轨迹与回执, 改名要有数据迁移。
enum ComputerRefusal: String, Equatable, CaseIterable {
    /// 存盘确认弹窗 —— 恒选"取消", 交回给人。
    case savePrompt
    /// 付款 / 下单 / 确认支付 —— 恒拒。
    case payment
    /// 永久删除 / 清空 / 格式化 —— 恒拒(第一层已经把 API 拿掉了, 这条是坐标兜底的兜底)。
    case permanentDelete
}

/// 一次恒拒的结论: 拒谁 + 给模型的一句人话。
///
/// 回执文案必须写**为什么**, 不然模型会换个说法再试一次(实测过同类: 只说"被拒绝"时
/// 它会把同一件事拆成两步重来)。
struct ComputerRefusalDecision: Equatable {
    let refusal: ComputerRefusal
    let reason: String
}

/// 红线判据的唯一入口。
enum ComputerRedline {

    /// 遮蔽后的展示值 —— **序列化边界**上做的, 不是靠 prompt 提醒。
    static let mask = "••••"

    /// 序列化时必须长这样。`role` 命中密码框、或 AX 标了受保护内容 ⇒ 恒 `mask`。
    ///
    /// ⚠️ 判据放这里而不是放 helper 的拼串处: 那是"用到它的地方", 这里才是"能被断言的地方"
    ///    (同 `NoteProposal` 那套"判据全部留在纯函数里, 那里能造反例")。
    ///
    /// ⚠️ 为什么 `isProtected` 这条**不算"误遮"**: 它不是按名字猜, 是系统自己标的
    ///    `AXProtectedContent`(语义就是"这块内容不该被读出来"), 而 helper 只在
    ///    **有值**的元素上才置它(见 `AXAdapter.build`) ⇒ 唯一会被遮掉的就是"一个受保护元素里的值",
    ///    那正好是遮蔽要遮的东西。
    static func maskedValue(_ raw: String, role: String, isProtected: Bool,
                            subrole: String = "") -> String {
        if isProtected { return mask }
        if isPasswordRole(role, subrole: subrole) { return mask }
        return raw
    }

    /// 这个角色是不是密码框。**只认系统给的精确身份, 不做任何模糊匹配**。
    ///
    /// ⚠️ 2026-10-30 从 `contains("secure") || contains("password")` 收紧到这里(boss 定:
    ///    "只遮蔽 password, 防止误遮")。子串匹配会把名字里带这两个词的**任何**角色都算成
    ///    密码框, 而遮蔽是**单向**的 —— 多遮一格, 模型就少一条它该看见的信息, 而且
    ///    **看不出少了什么**(它只会以为自己读到的是全部)。少遮还能靠别的手段发现, 多遮发现不了。
    ///
    /// ⚠️ **必须把 `subrole` 一起看** (2026-10-30 实测 Safari): 网页里的密码框
    ///    `AXRole` 是 **`AXTextField`**(不含 secure)、`AXProtectedContent` 为 **nil**、
    ///    真正的身份在 **`AXSubrole = AXSecureTextField`**。只看 role 的话, 网页密码框
    ///    两条判据全落空。
    ///
    /// ⚠️ 为什么敢用 `==` 而不是"宽松一点": AppKit 的 `NSSecureTextField` 与 WebKit /
    ///    Chromium 的密码输入框**报的是同一个常量**(`AXTextField` + `AXSecureTextField`),
    ///    两边实测一致。真遇到报别的名字的 App, 结果是"没遮"而不是"遮错" —— 方向是对的。
    static func isPasswordRole(_ role: String, subrole: String = "") -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    // MARK: - 操作面的硬禁区 (批 2b)

    /// **永远不给操作权限**的 App。
    ///
    /// ⚠️ 这张名单必然漏 —— 但它不是唯一防线: 操作面是**主动勾**的第二档(默认不给),
    ///    所以漏掉一个 App 的后果是"用户自己给它开了操作", 不是"默认就能动"。
    ///    名单在这里是为了挡另外两件事: ① 手改过库/老数据里已经勾上的; ② 用户在设置页里
    ///    稀里糊涂把口令管理器勾成"可操作"。
    ///
    /// ⚠️ `系统设置` 为什么在名单里: 它能**关掉辅助功能授权本身** ⇒ 让模型操作它等于
    ///    把"谁能看界面"这个总开关交给模型, 而我们是靠那个授权活着的(自我提权)。
    static let actBannedBundles: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.SecurityAgent",
        "com.apple.systempreferences",
    ]

    /// `AXMenuItemCmdModifiers` 的位掩码 → 人认识的修饰键名。
    ///
    /// ⚠️ 这条看着像个翻译, 其实是**永久删除判据的一半**: `⌘⌫` 是"移到废纸篓"(允许),
    ///    `⇧⌘⌫` 是"立即删除"(恒拒), 两者只差 shift 一位。位掩码解错 ⇒ 该拦的放过去,
    ///    而且零信号(编译过、界面正常)。
    ///
    /// 位定义来自 AppKit: `Shift=1 · Option=2 · Control=4 · NoCommand=8`;
    /// **⌘ 是隐含的** —— 只有 `NoCommand` 那位置了才表示这个快捷键不带 ⌘。
    static func decodedModifiers(_ raw: Int) -> Set<String> {
        var m: Set<String> = []
        if raw & 1 != 0 { m.insert("shift") }
        if raw & 2 != 0 { m.insert("option") }
        if raw & 4 != 0 { m.insert("control") }
        if raw & 8 == 0 { m.insert("command") }
        return m
    }

    // MARK: - 三条恒拒

    /// 判一个**控件**(按钮 / 菜单项)。命中就返回决定, 没命中返回 nil(放行)。
    ///
    /// `keyEquivalent` 与 `modifiers` 只用来认 `⇧⌘⌫` 这条系统快捷键 —— 它是唯一一个
    /// "标题可能被本地化得认不出来、但快捷键恒定"的永久删除入口。
    static func refusal(forControl title: String,
                        role: String,
                        keyEquivalent: String? = nil,
                        modifiers: Set<String> = []) -> ComputerRefusalDecision? {
        let t = normalized(title)

        if isPermanentDelete(t, keyEquivalent: keyEquivalent, modifiers: modifiers) {
            return ComputerRefusalDecision(
                refusal: .permanentDelete,
                reason: "这一步是永久删除(不进废纸篓), 无法恢复 ⇒ 我不点。要删的话请你自己来, 或者告诉我改用「移到废纸篓」。"
            )
        }
        if containsAny(t, paymentWords) {
            return ComputerRefusalDecision(
                refusal: .payment,
                reason: "这一步涉及付款/下单 ⇒ 我不点。金额与对象要你自己确认过才行。"
            )
        }
        return nil
    }

    /// 这个弹窗是不是"要不要保存"那一类。
    ///
    /// 两条判据任一成立即可: ① 标题里有"保存更改 / 未保存 / save changes";
    /// ② 按钮里有"不保存 / Don't Save" —— 后者比标题更硬, 因为各 App 的标题措辞太散。
    static func isSavePrompt(title: String, buttons: [String]) -> Bool {
        let t = normalized(title)
        if containsAny(t, savePromptTitleWords) { return true }
        return buttons.contains { containsAny(normalized($0), dontSaveWords) }
    }

    /// 存盘确认弹窗里该按哪一个 —— **恒选"取消"**, 返回它的下标。
    ///
    /// 找不到"取消"就返回 nil ⇒ 调用方**必须恒拒**, 不许退而求其次去点"不保存"或"保存":
    /// 没有取消键的弹窗, 我们连"它到底在问什么"都没有把握。
    static func cancellationIndex(buttons: [String]) -> Int? {
        buttons.firstIndex { containsAny(normalized($0), cancelWords) }
    }

    /// 存盘弹窗的完整结论: 能被安全取消就取消, 否则恒拒。
    ///
    /// ⚠️ 返回 `.savePrompt` 的那一支**不是**"拒了就完事": 回执里必须带上"这里有未保存的修改",
    ///   因为对用户来说, 这条信息的价值恰恰是"我的文档还在, 只是它没敢动"。
    static func savePromptDecision(title: String, buttons: [String]) -> ComputerRefusalDecision? {
        guard isSavePrompt(title: title, buttons: buttons) else { return nil }
        if cancellationIndex(buttons: buttons) != nil {
            return ComputerRefusalDecision(
                refusal: .savePrompt,
                reason: "这里有未保存的修改, 我不能替你决定保存还是丢弃 ⇒ 我点了「取消」, 等你来处理。"
            )
        }
        return ComputerRefusalDecision(
            refusal: .savePrompt,
            reason: "这里有未保存的修改, 而且这个弹窗没有「取消」键 ⇒ 我什么都不点, 等你来处理。"
        )
    }

    // MARK: - 词表

    /// 付款/下单。中英各几条 —— 只收**动词性强**的写法, "价格/金额"这种名词不算。
    static let paymentWords = [
        "付款", "支付", "下单", "提交订单", "立即购买", "确认购买", "确认支付", "去结算",
        "pay now", "purchase", "place order", "buy now", "checkout", "confirm payment",
    ]

    /// 永久删除。⚠️ **"移到废纸篓"必须放行** —— 所以这里收的是"清空废纸篓", 不是"废纸篓"。
    static let permanentDeleteWords = [
        "立即删除", "永久删除", "彻底删除", "清空废纸篓", "格式化",
        "delete immediately", "delete permanently", "empty trash", "erase",
    ]

    static let savePromptTitleWords = [
        "保存更改", "未保存", "要保存", "save changes", "do you want to save", "unsaved",
    ]

    static let dontSaveWords = ["不保存", "don't save", "dont save", "delete"]

    static let cancelWords = ["取消", "cancel"]

    // MARK: - 小工具

    /// 归一化: 去首尾空白、转小写。中文不受影响, 英文靠 lowercased 兜住大小写。
    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        guard !haystack.isEmpty else { return false }
        return needles.contains { haystack.contains($0) }
    }

    /// 永久删除的三条入口: 标题词、`⇧⌘⌫` 快捷键、"清空"+"废纸篓" 这种拆开写的标题。
    private static func isPermanentDelete(_ title: String,
                                          keyEquivalent: String?,
                                          modifiers: Set<String>) -> Bool {
        if containsAny(title, permanentDeleteWords) { return true }
        // ⇧⌘⌫: macOS 的"立即删除"恒定绑在这个组合上, 标题被本地化成什么都认得出。
        if let k = keyEquivalent?.lowercased(), k == "\u{8}" || k == "delete" || k == "backspace" {
            let m = modifiers.map { $0.lowercased() }
            if m.contains("command") && m.contains("shift") { return true }
        }
        return false
    }
}
