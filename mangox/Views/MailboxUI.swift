//
//  MailboxUI.swift
//  P10.2e: 邮箱域共用 UI 小件 —— 账号池 (Settings) 与 sparse agent (Schedule) 两侧都用。
//  原先落在 MailboxSettings.swift 内且 file-private; 哨兵搬到计划任务页后需跨文件复用, 故提出来。
//

import SwiftUI

/// 小徽章 (预设来源 / 已绑定 / 审批档 / 免密钥…)。
func mboxBadge(_ text: String, color: Color) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.12))
        .cornerRadius(4)
}

private let mailboxRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

func relativeTime(_ date: Date) -> String {
    mailboxRelativeFormatter.localizedString(for: date, relativeTo: Date())
}

func shortTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: date)
}
