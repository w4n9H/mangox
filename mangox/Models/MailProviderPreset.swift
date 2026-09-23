//
//  MailProviderPreset.swift
//  P10.2d: 服务商预设 (决定 15) —— 新建邮箱账号时的填充值与提示。
//  只是**填充值**: host 可手改 (服务商端口偶有调整), 失效靠"测试连接"与省下的 lastError 兜住。
//  范围: 只收普通个人邮箱。Outlook/Office365 (微软已弃 basic auth, 必须 OAuth2) 与 Gmail (需常开 VPN) 不列。
//

import Foundation

struct MailProviderPreset: Identifiable, Equatable {
    /// 稳定串 —— 会落进 `MailboxAccount.presetId` (仅 UI 回显), 改文案不改它。
    let id: String
    let label: String
    /// 展示用: 帮助用户判断该选哪个 (不参与校验 —— address 与域名不匹配也允许)。
    let domains: [String]
    /// 含端口 —— `CurlMailCommand` 直接拼进 `imaps://<host>/INBOX`, 故端口必须在这。
    let imapHost: String
    let smtpHost: String
    /// 「须用授权码, 不是登录密码」—— 最高频踩坑点, 缺了它用户会一直拿登录密码试。
    let authNote: String
    let helpURL: String?

    var isCustom: Bool { id == Self.customId }
    static let customId = "custom"

    // ⚠️ 下面全部写成**计算属性** (`static var` + 花括号), 不可用 `static let`:
    // `authNote` 是 `L()` 的结果, 而 `static let` 是**懒加载的一次性求值** —— 首次访问就把当时
    // 语言的译文冻住, 之后切界面语言不再跟随 (2026-09-23 与 `PersonaRowText` 同批修)。
    // `label` 不在此列: 它是**裸中文 key**, 由显示点 `LK()` 取词 (同 `DayBucket.rawValue` 的形态)。
    static var netease163: MailProviderPreset { MailProviderPreset(
        id: "163", label: "网易 163 邮箱", domains: ["163.com"],
        imapHost: "imap.163.com:993", smtpHost: "smtp.163.com:465",
        authNote: L("网页版邮箱「设置 → IMAP/SMTP」开启服务, 手机验证后得到授权码 —— 用它当密码, 不是登录密码"),
        helpURL: "https://help.mail.163.com/") }

    static var netease126: MailProviderPreset { MailProviderPreset(
        id: "126", label: "网易 126 邮箱", domains: ["126.com"],
        imapHost: "imap.126.com:993", smtpHost: "smtp.126.com:465",
        authNote: L("网页版邮箱「设置 → IMAP/SMTP」开启服务, 手机验证后得到授权码 —— 用它当密码, 不是登录密码"),
        helpURL: "https://help.mail.163.com/") }

    static var qq: MailProviderPreset { MailProviderPreset(
        id: "qq", label: "QQ 邮箱", domains: ["qq.com", "foxmail.com"],
        imapHost: "imap.qq.com:993", smtpHost: "smtp.qq.com:465",
        authNote: L("网页版邮箱「设置 → 账户」开启 IMAP/SMTP 服务, 短信验证后得到授权码 —— 用它当密码, 不是登录密码"),
        helpURL: "https://service.mail.qq.com/") }

    static var aliyun: MailProviderPreset { MailProviderPreset(
        id: "aliyun", label: "阿里云邮箱", domains: ["aliyun.com"],
        imapHost: "imap.mxhichina.com:993", smtpHost: "smtp.mxhichina.com:465",
        authNote: L("网页版邮箱「设置 → 客户端设置」开启 IMAP/SMTP, 生成客户端专用密码 —— 用它当密码, 不是登录密码"),
        helpURL: "https://mail.aliyun.com/") }

    /// 兜底: host 留空由用户手填 (其他服务商 / 自建)。
    static var custom: MailProviderPreset { MailProviderPreset(
        id: customId, label: "自定义", domains: [],
        imapHost: "", smtpHost: "",
        authNote: L("手动填写 IMAP / SMTP 主机 (含端口, 如 imap.example.com:993); 同样须用授权码或客户端专用密码"),
        helpURL: nil) }

    /// 也必须是计算属性 —— 写成 `static let` 会把**上面那几个实例**在首次访问时一起冻住。
    static var all: [MailProviderPreset] { [netease163, netease126, qq, aliyun] }
    /// UI 选择器顺序: 4 个预设 + 自定义兜底。
    static var allWithCustom: [MailProviderPreset] { all + [custom] }

    static func preset(id: String?) -> MailProviderPreset? {
        guard let id else { return nil }
        return allWithCustom.first { $0.id == id }
    }

    /// 按地址域名猜预设 (UI 辅助: 填完地址自动选好, 猜不到 = nil 保持用户选择)。
    static func matching(address: String) -> MailProviderPreset? {
        let lower = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard let at = lower.lastIndex(of: "@") else { return nil }
        let domain = String(lower[lower.index(after: at)...])
        guard !domain.isEmpty else { return nil }
        return all.first { $0.domains.contains(domain) }
    }

    /// 把预设填进账号草稿。**自定义不覆盖手填值** —— 只把来源标成 custom。
    static func apply(_ preset: MailProviderPreset, to draft: MailboxAccount) -> MailboxAccount {
        var out = draft
        out.presetId = preset.id
        if !preset.isCustom {
            out.imapHost = preset.imapHost
            out.smtpHost = preset.smtpHost
        }
        return out
    }

    /// 列表里那枚来源徽章的文字 (账号已删掉预设或选了自定义时回落"自定义")。
    static func label(forPresetId id: String?) -> String {
        preset(id: id)?.label ?? L("自定义")
    }
}
