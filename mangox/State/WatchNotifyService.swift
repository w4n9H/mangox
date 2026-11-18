//
//  WatchNotifyService.swift
//  P19 S7: 独立触达通道 —— **只剩飞书私聊**（邮件那一路 2026-11-18 晚删除）。
//
//  三条纪律（写在这里是因为它们决定了这一层能做什么、不能做什么）:
//   ① **只发不收。** 这一层没有 poll，没有就绪检查，没有任何一条把外部数据带回来的路。
//      收是来源（`WatchSources`）的事，两者不同居 —— 合起来就成了"渠道"，
//      而渠道要处理鉴权、去重、线程映射，那是 P19.1 的事。
//   ② **外发只有标题 + 任务名。** 载荷由 `payload(finding:taskName:)` 一处构造 ——
//      **唯一**构造点；投递方不许自己拼 `body` / `evidence`。
//   ③ **凭据只经 Keychain。** 邮件的授权码在邮箱账号那套缝里；飞书这边**没有第二条凭据**
//      —— 2026-11-17 群 webhook 整条删掉之后，结论走的是助理已经绑好的那个机器人
//      （它的 app_secret 在 `RemoteSecretStore`），所以这里不再持有任何地址/URL。
//
//  ⚠️ 为什么 webhook 被删（2026-11-17 boss）: 群已经确定不做，而 webhook 唯一能去的落点
//     就是群。留着它就是"同一件事两条路"：两套凭据、两套失败模式、两套频控话术，
//     而用户在编辑器里看到两行都叫"飞书…"只会问"这俩啥区别"。结论要走飞书，就推私聊。
//

import Foundation

// MARK: - 纯函数（判据全打在这一层）

enum WatchNotifyService {

    /// 外发载荷。**唯一**构造点 —— 见文件头纪律 ②。
    static func payload(finding: AgentFinding, taskName: String) -> NotifyPayload {
        NotifyPayload(findingId: finding.id, taskName: taskName, title: finding.title,
                      actionable: !finding.plan.isEmpty)
    }

}
