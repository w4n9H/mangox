//
//  CaseRemoteBridgeLive —— P19.2 S15 的**真桥联调**（默认跳过）
//
//  这条不是常规门禁: 它要 spawn 一个 node 子进程、连真实的飞书租户。放进默认冒烟会让
//  CI 依赖网络与一个外部账号（红了也分不清是代码坏了还是网断了）。
//  但"子进程管路"恰恰是自动化**唯一验得到真东西**的地方 —— 桥脚本找不找得到、按行切
//  吃不吃得下真实帧、`stop()` 之后 node 会不会变成孤儿，这些都只有起一次才知道。
//
//  跑法（手工，联调时用一次）:
//    MX_BRIDGE_E2E=1 \
//    FS_APP_ID=cli_xxx FS_APP_SECRET=xxx \
//    MANGOX_FEISHU_BRIDGE=$PWD/mangox/Resources/feishu-bridge.cjs \
//    ./scripts/smoke/run.sh
//  （最后那个 env 是必须的: 冒烟二进制不在 .app 里，`Bundle.main` 找不到资源。）
//
//  可选 `FS_CHAT_ID=oc_xxx`：给了就顺手发一条，验 `send` 这条路。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseRemoteBridgeLive() async {
        let env = ProcessInfo.processInfo.environment
        guard env["MX_BRIDGE_E2E"] == "1" else {
            print("SKIP - T-REMOTELIVE 真桥联调（默认跳过: 要 spawn node 并连真实飞书租户；"
                  + "设 MX_BRIDGE_E2E=1 + FS_APP_ID/FS_APP_SECRET + MANGOX_FEISHU_BRIDGE 才跑）")
            return
        }
        guard let appId = env["FS_APP_ID"], let secret = env["FS_APP_SECRET"] else {
            check(false, "T-REMOTELIVE 前置: 缺 FS_APP_ID / FS_APP_SECRET"); return
        }
        check(FeishuBridgeLink.nodePath() != nil,
              "T-REMOTELIVE node 找得到（\(FeishuBridgeLink.nodePath() ?? "nil")）")
        check(FeishuBridgeLink.scriptURL() != nil,
              "T-REMOTELIVE 桥脚本找得到（冒烟二进制不在 .app 里 ⇒ 靠 MANGOX_FEISHU_BRIDGE 指定）")

        let link = FeishuBridgeLink()
        var frames: [RemoteFrame] = []
        var exitNote: String?
        link.onFrame = { frames.append($0) }
        link.onExit = { exitNote = $0 }
        let botId = UUID().uuidString
        do {
            try link.start(bots: [RemoteLinkBot(id: botId, appId: appId, secret: secret)])
        } catch {
            check(false, "T-REMOTELIVE 起桥失败: \(error.localizedDescription)"); return
        }
        // 状态帧现在**只在握手真的成功时**才算 connected（S15b 去掉了"2 秒乐观置 true"：
        // 凭证填错时它会说"通着"）。给 20 秒余量（冷启动 + token 换取 + 握手）。
        let up = await waitUntil({ frames.contains { if case .status = $0 { return true }; return false } },
                                 timeout: 20)
        check(up, "T-REMOTELIVE 收到 status 帧（子进程真的起来了，且 stdout 是干净的 NDJSON）")
        check(exitNote == nil, "T-REMOTELIVE 桥没有提前退出（\(exitNote ?? "还在跑")）")
        // **每帧都带 bot** 是多机器人契约的地基: 少了它，全部消息会归到同一个助理。
        let tagged = frames.contains {
            if case .status(let b, _, _) = $0 { return b == botId }
            return false
        }
        check(tagged, "T-REMOTELIVE status 帧带回了机器人 id（多机器人路由的唯一键）")

        if let chatId = env["FS_CHAT_ID"], !chatId.isEmpty {
            link.send(botId: botId, chatId: chatId,
                      text: "[MangoX 联调] 这条是 FeishuBridgeLink 的子进程管路自测。")
            let sent = await waitUntil({ frames.contains { if case .sendResult = $0 { return true }; return false } },
                                       timeout: 15)
            var ok = false
            for f in frames {
                if case .sendResult(_, let success, _, _, _) = f { ok = success }
            }
            check(sent && ok, "T-REMOTELIVE send 命令真的发出一条消息（send_result ok=\(ok)）")
        }

        // 停：`stop()` 关 stdin + `terminate()` ⇒ 桥自己退。
        //
        // ⚠️ 判据是**回操作系统问一次**（`kill(pid, 0)` 返回 ESRCH），不是看我们自己的
        // 终止回调 —— 回调只证明"通知到了"；而"stop() 之后留下一个孤儿 node，下次启动又起一个"
        // 正是这条通道最容易犯又最难发现的错（表现为"有时收不到消息"，因为集群随机投递）。
        let pid = link.childPid ?? 0
        check(pid > 0, "T-REMOTELIVE 拿到了子进程 pid（\(pid)）")
        link.stop()
        let gone = await waitUntil({ Darwin.kill(pid, 0) != 0 }, timeout: 10)
        check(gone, "T-REMOTELIVE stop 之后操作系统里**已经没有这个 pid**（没有孤儿 node）")
        _ = exitNote
    }
}
