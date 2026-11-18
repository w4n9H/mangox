//
//  RemoteBot.swift
//  P19.2 S15b —— 飞书**机器人**（一个自建应用 = 一个身份 = 一个机器人）。
//
//  ── 为什么绑定从「单聊」搬到「机器人」 ─────────────────────────────────────────
//  `chat_id`（`oc_…`）是**运行时地址**: 同一对人和机器人之间永远只有一条单聊，
//  换个人说话就是另一个地址。把它当绑定的键，会得到两个说不通的东西:
//    ① 界面只能显示 `…9f3a2c` 这种尾号，人看不出"这是谁"；
//    ② 第二个助理选同一条时会被静默摘走（"我明明绑给它了，它不回"）。
//  `app_id`（`cli_…`）才是**身份**，而身份恰好是"一个机器人只归一个助理"这句话的主语。
//  改造之后 `chat_id` 降级成一个出口: 谁跟这个机器人说话，回复就回给谁。
//
//  ── 一条结构性的不变量 ──────────────────────────────────────────────────────
//  「一个机器人只归一个助理」**由列的形状保证**（`assistant_id` 是单值），不靠保存时
//  扫全表去摘别人的绑定。反过来也一样（2026-11-17 boss 定）：**一个助理只挂一个机器人**
//  —— 由 `ChatStore.assignRemoteBot` 顶掉旧的保证。要两个入口就再建一个助理。
//
//  ── 只有一个开关（2026-11-18 boss 定）─────────────────────────────────────────
//  「设置里的机器人开关」和「助理的开关」是同一个东西 ⇒ **只留助理那一个**。
//  连接的唯一判据: `机器人归给的助理存在、且开着`。
//    · 没归给任何助理 ⇒ 不连（没有助理就没有开关能管它 —— 留一个能连但没人管的机器人
//      等于多一个关不掉的长连接）；
//    · 助理关掉 ⇒ 断开。⚠️ 代价要说清: 飞书那边**输入框会变灰**（"暂时无法给该机器人发消息"），
//      不再有"先打开我"那句回复 —— 那句的前提本来是"连接照旧连着"，前提没了它就没了。
//
//  ⚠️ 由此产生一个必须说清的后果: 两个人分别跟同一个机器人说话，会进**同一场会话**
//  （助理只有一场日志会话）。这不是 bug，是"一个机器人 = 一个助理"的代价。
//  将来要分开，得在会话侧按 `open_id` 分会话 —— 那是另一件事，别在这儿偷偷做一半。
//

import Foundation

struct RemoteBot: Identifiable, Equatable {
    let id: UUID
    /// 人给的名字（"工作号"）。空串是合法状态（老库迁上来的），显示时走 `displayName`。
    var name: String
    /// 飞书自建应用的 `cli_…`。**不进钥匙串** —— 它是标识不是能力凭据，
    /// 而列在库里才能让"机器人列表"这一页不需要钥匙串授权就能画出来。
    var appId: String
    /// 归属的助理（`ScheduledTask.id`）。`nil` = 还没归给谁 ⇒ **不连**。
    /// 机器人没有自己的开关（见文件头）：连不连只看这个助理在不在、开没开。
    var assistantId: UUID?
    /// 最近一次跟它说话的会话（诊断用；绑定不再需要它，但结论主动推送要它当落点）。
    var lastChatId: String?
    var lastChatAt: Date?
    var createdAt: Date = Date()

    /// 界面上那一行显示的名字。空白名字回落成一句通用话，不留空行。
    var displayName: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? L("飞书机器人") : t
    }

    /// `cli_a1b2c3d4e5f6…9f3a` —— 前 10 后 4。全显示没必要（它不藏什么），
    /// 但一行里还要放归属和状态，30 位的串会把它们挤出去。
    var maskedAppId: String {
        guard !appId.isEmpty else { return L("缺 app_id") }
        guard appId.count > 16 else { return appId }
        return appId.prefix(10) + "…" + appId.suffix(4)
    }

    var hasAppId: Bool { !appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 凭据这一层配齐了没（app_id 在库、secret 在钥匙串 —— 后者这里问不到）。
    /// **不代表能连**：能不能连由服务层按"归属的助理开着没"判（那需要 `ChatStore`）。
    var isRunnableCandidate: Bool { hasAppId }
}
