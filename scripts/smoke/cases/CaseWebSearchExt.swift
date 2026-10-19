//
//  caseWebSearchExt —— webSearch 扩展: 源码形态 / 工具名表同源 / 面板联动
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家, 未改一行逻辑）。
//  原位替换为 `await caseWebSearchExt()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseWebSearchExt() async {
        let wsSrc = PiRpcTransport.webSearchExtensionSource

        // ① 工具名表与源码**同源**（同 dream 那条守: 改源码忘改表 ⇒ 红）。
        check(!PiRpcTransport.webSearchToolNames.isEmpty
              && PiRpcTransport.webSearchToolNames.allSatisfy {
                  wsSrc.contains("name: \"\($0)\"")
              },
              "P10.1b 同源: `webSearchToolNames` 每个名字都能在源码里找到 `name: \"…\"`"
              + "（实测 \(PiRpcTransport.webSearchToolNames))")

        // ② env 名是**契约 token**: 必须逐字出现在扩展源码里。两边分头改 ⇒ 扩展永远读不到 key,
        //    而它只会回一句 "not enabled"（看着像"没配置", 其实是常量漂了）—— **零红灯**。
        check(wsSrc.contains("const KEY_ENV = \"\(PiRpcTransport.webSearchKeyEnvKey)\""),
              "P10.1b 契约: 源码 `const KEY_ENV` 与 `webSearchKeyEnvKey` 逐字一致"
              + "（实测 \(PiRpcTransport.webSearchKeyEnvKey))")

        // ③ **零依赖** —— 这条就是路线判据本身。谁 import 了别的包, 等于把 82MB 那条路又接了
        //    回来, 而且伪装成"只是加了一行 import"。允许的只有: type-only 的 pi 包 / typebox / node 内建。
        let wsImports = wsSrc.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("import ") }
        check(wsImports.count == 5 && wsImports.allSatisfy {
                  $0.contains("@earendil-works/pi-coding-agent")
                  || $0.contains("\"typebox\"") || $0.contains("\"node:")
              },
              "P10.1b 零依赖: import 只有 type-only 的 pi 包 / typebox / node 内建"
              + "（实测 \(wsImports.count) 行: \(wsImports))")

        // ④ 端点**唯一**: 只用 `api.bochaai.com`（与 boss 手搓的 Python 客户端同源）。
        //    现成那个包用的是 `api.bocha.cn`, 是**另一个域** —— 混进来这里红。
        check(wsSrc.contains("const ENDPOINT = \"https://api.bochaai.com/v1/web-search\""),
              "P10.1b 端点: 与 `autocoder-nano/utils/http_utils.py` 同源"
              + "（api.bochaai.com/v1/web-search）")

        // ⑤ 原始字符串的缩进剥干净了（同 dream 那条: 定界符与内容行缩进不一致 ⇒ 写出去的扩展里
        //    import 不再顶格 —— 照样"看着没事"）。
        let wsFirst = wsSrc.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        check(wsFirst.hasPrefix("// Auto-deployed by MangoX (P10.1b)."),
              "P10.1b 常量: 多行字符串首行无前导空白（实测 [\(wsFirst.prefix(34))…])")

        // ⑥ `webSearchEnvironment` 四组合 —— **纯函数**, 这是本段最值钱的一格。
        check(PiRpcTransport.webSearchEnvironment(existing: nil, key: nil, inherited: [:]) == nil,
              "P10.1b env: 谁也不提这个变量 ⇒ **不碰**环境字典"
              + "（凭空造一份会把父环境整个复制进去, 含义就变了）")
        let envSet = PiRpcTransport.webSearchEnvironment(existing: nil, key: "k1",
                                                        inherited: ["A": "1"]) ?? [:]
        check(envSet[PiRpcTransport.webSearchKeyEnvKey] == "k1" && envSet["A"] == "1",
              "P10.1b env: 有 key ⇒ 设进去, 且以父环境为底（实测 \(envSet))")
        let envKeep = PiRpcTransport.webSearchEnvironment(existing: ["B": "2"], key: "k2",
                                                         inherited: ["A": "1"]) ?? [:]
        check(envKeep["B"] == "2" && envKeep["A"] == nil
              && envKeep[PiRpcTransport.webSearchKeyEnvKey] == "k2",
              "P10.1b env: 已有环境字典**优先**于父环境（把 inherited 整个并进来 ⇒ 含义就变了）")
        // 反例（这一格是本段的核心）: 父进程残留同名变量 + App 没配 key ⇒ **必须删掉它**。
        // 不删的话「面板说未配置」与「扩展拿到了 key」同时为真, 而且**零红灯**。
        let envLeak = PiRpcTransport.webSearchEnvironment(
            existing: nil, key: nil, inherited: [PiRpcTransport.webSearchKeyEnvKey: "leak"])
        check(envLeak.map { $0[PiRpcTransport.webSearchKeyEnvKey] == nil } == true,
              "P10.1b env 反例: 父残留 + 没配 key ⇒ 键被**删掉**（实测 \(String(describing: envLeak)))")

        // ⑦ 面板闸门 + 落地 + 下发: 全走**夹具目录**, 一个字节都不碰 ~/.mangox。
        let wsDir = fixtureDir("p10.1c")
        let wsBlockedMock = MockTransport()
        let wsA = ChatStore(transport: wsBlockedMock, dbPath: wsDir + "/a.db",
                            managedExtensionsDir: wsDir + "/ext-a",
                            modelKeyStore: InMemoryModelKeyStore())
        wsA.mailbox.stopScheduler()
        wsA.scanExtensions()
        let blockedRow = wsA.extensions.first { $0.name == "mangox-web-search" }
        check(blockedRow != nil,
              "P10.1b 面板: **没配 key 也有这一行**（扩展无条件落地, 与 approval 同判据）"
              + " —— 少了它, \"去设置里填 Key\"那条线索在界面上不存在")
        check(blockedRow.flatMap { $0.blockedReason } == .needsBochaKey,
              "P10.1b 闸门: 没 key ⇒ blockedReason 必须说得出原因")
        check(blockedRow?.enabled == false,
              "P10.1b 闸门: 没 key ⇒ enabled 被**压成 false**（漏压 ⇒ 面板说\"开着\"而它挂不上）")
        check(!(wsBlockedMock.lastDesiredExtensions ?? [])
                .contains(where: { $0.hasSuffix("mangox-web-search.ts") }),
              "P10.1b 闸门: 没 key ⇒ **不进** spawn 的 -e 列表"
              + "（实测 \(String(describing: wsBlockedMock.lastDesiredExtensions)))")

        // ⑧ 归属拆分 —— 这是加 web-search 时新拆出来的两个集合, 一个都不能合回去:
        //    `builtInNames` = 不可删除（删了下次重扫又写回来, 那是打地鼠）;
        //    `unswitchableNames` = 不可停用。web-search 是"前是后否"。
        check(ExtensionItem.builtInNames.contains("mangox-web-search"),
              "P10.1b 归属: web-search 算**自带** ⇒ 不可删除")
        check(!ExtensionItem.unswitchableNames.contains("mangox-web-search"),
              "P10.1b 归属 反例: web-search **必须能停用** —— 塞进 unswitchableNames 就是"
              + "\"标记比事实说得多\"（面板会说不许停, 而代码其实允许）")

        // ⑨ 配好 key: 胶囊消失、进 -e 列表、文件真在磁盘上、key 推到 transport。
        let wsLiveMock = MockTransport()
        let wsB = ChatStore(transport: wsLiveMock, dbPath: wsDir + "/b.db",
                            managedExtensionsDir: wsDir + "/ext-b",
                            modelKeyStore: InMemoryModelKeyStore())
        wsB.mailbox.stopScheduler()
        check(wsB.bochaKey == nil, "P10.1b 初始: 没配 key ⇒ bochaKey 为 nil（空串也算没配）")
        wsB.setBochaKey("sk-test-1")
        let liveRow = wsB.extensions.first { $0.name == "mangox-web-search" }
        check(liveRow != nil, "P10.1b 配按键: 保存之后那一行仍在")
        check(liveRow.flatMap { $0.blockedReason } == nil, "P10.1b 配按键: 配好 key ⇒ 挂不上胶囊消失")
        check(liveRow?.enabled == true, "P10.1b 配按键: 配好 key ⇒ 开关变成\"开着\"")
        check(liveRow.map { FileManager.default.fileExists(atPath: $0.path) } == true,
              "P10.1b 落地: `.ts` 真在磁盘上（路径 = 夹具, 不碰 ~/.mangox）"
              + "（实测 \(String(describing: liveRow?.path)))")
        check((wsLiveMock.lastDesiredExtensions ?? [])
                .contains(where: { $0.hasSuffix("mangox-web-search.ts") }),
              "P10.1b 下发: 配好 key ⇒ **进** -e 列表"
              + "（实测 \(String(describing: wsLiveMock.lastDesiredExtensions)))")
        check(wsLiveMock.lastWebSearchKey == "sk-test-1",
              "P10.1b 下发: key 作为**配置投影**推到了 transport"
              + "（实测 \(String(describing: wsLiveMock.lastWebSearchKey)))")

        // ⑩ 清 key: 必须**把 nil 推下去**（留旧值 ⇒ 面板说没配、子进程却还带着旧 key）;
        //    文件**留着**（我们从不删它）⇒ 那一行回到"挂不上 + 说得出原因"。
        wsB.setBochaKey("   ")          // 空白串 = 清除
        check(wsB.bochaKey == nil, "P10.1b 清除: 空白串按清除处理（trim 后为空 ⇒ 删 Keychain 条目）")
        check(wsLiveMock.lastWebSearchKey == nil && wsLiveMock.webSearchKeyUpdates >= 2,
              "P10.1b 清除: 下发的是 **nil**, 不是停在旧值上"
              + "（实测 last=\(String(describing: wsLiveMock.lastWebSearchKey))"
              + " n=\(wsLiveMock.webSearchKeyUpdates))")
        let clearedRow = wsB.extensions.first { $0.name == "mangox-web-search" }
        check(clearedRow != nil, "P10.1b 清除: 文件留着 ⇒ 那一行还在")
        check(clearedRow.flatMap { $0.blockedReason } == .needsBochaKey
              && clearedRow?.enabled == false,
              "P10.1b 清除: 回到\"挂不上 + 说得出原因\"（enabled 又被压回 false）")

        // ⑪ 删除守卫: 自带项删不掉（删了下次重扫又写回来 = 打地鼠; 这一条就是抓那个的）。
        if let row = clearedRow {
            let before = wsB.extensions.count
            wsB.deleteExtension(row)
            check(wsB.extensions.count == before
                  && wsB.extensions.contains(where: { $0.name == "mangox-web-search" }),
                  "P10.1b 守卫: 自带项**删不掉** —— 少了这道, 面板里点\"删除\"就是点一下又回来")
        } else {
            check(false, "P10.1b 守卫: 夹具里必须真的存在那一行（否则上面那条是空转的假绿）")
        }
    }
}
