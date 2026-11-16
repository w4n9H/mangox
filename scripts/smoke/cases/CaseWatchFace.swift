//
//  CaseWatchFace —— P19 只读巡检/分析段的**工具面**：该给什么、不许给什么
//
//  为什么这一门必须先立（docs/P19 §02 前置门 0）：
//    「巡检」与「自动写」之间只隔着一行没人看的 `--tools`。而 pi 对**不存在的工具名不吭声**
//    （2026-10-16 实测），参数写错了不会有任何报错 —— 它只会安静地少给你一个工具，
//    或者安静地多给你一个。两种都不会红，直到某次巡检把文件改了。
//
//  判据都是**纯函数的输出**（`AnalysisFace` / `toolArguments` / `extensionArguments`），
//  与机器上装没装 pi 无关 —— 这一点很关键：`spawnProcess` 一进门就 `guard launchSpec()`，
//  没装 pi 的机器上整条路直接返回，把断言挂在那条路上的门是**恒绿**的。
//
//  反例（2026-11-16 实测）：
//    ① `readOnlyToolNames` 加一个 `bash` ⇒ ① ② 两条红；
//    ② 改成 `["+grep"]`（modifier 写法）⇒ ② ③ 两条红 —— modifier 是"在 pi 默认的
//       read/bash/edit/write 上增补"，用它做只读面等于把 bash/write/edit 全放进来；
//    ③ `shouldStartComputer` 的 nil 默认从 `true` 改成 `false` ⇒ 只有 ⑧ 一条红
//       （其余七条全绿 —— 所以 ⑧ 不是 ⑤ 的复述，它盯的是生产侧那个 ? : 默认值）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseWatchFace() async {
        let webPath = "/tmp/mangox/ext/mangox-web-search.ts"
        let face = PiRpcTransport.analysisFace(webSearchPath: webPath)

        // —— ① 工具名逐字对拍（多一个 / 少一个 / 换写法都必须红）——
        check(PiRpcTransport.toolArguments(for: face)
              == ["--tools", "read,grep,find,ls,bocha_web_search"],
              "T-WATCHFACE ①工具面逐字对拍（改写成 +grep 或加 bash 都红）"
              + " | 实际 \(PiRpcTransport.toolArguments(for: face))")

        // —— ② 三个"会写"的内置工具一个都不许在 ——
        // ① 是对拍整体, 这一条是**说出理由**: 将来有人为了"顺手"把 write 加回来,
        // 红的信息里得直接指出是哪个词。
        let forbidden = ["bash", "write", "edit"]
        let leaked = face.toolNames.filter { forbidden.contains($0) }
        check(leaked.isEmpty,
              "T-WATCHFACE ②只读面不含 bash/write/edit（漏一个 = 这一档能改盘）"
              + " | 漏了 \(leaked)")

        // —— ③ 不许用 modifier 写法 ——
        // `+x` 的语义是"在默认四件上增补", 默认四件里就有 bash/write/edit ⇒ 用它做只读面
        // 等于什么都没裁。这一条盯的是**写法**, 与 ① 的"名字集合"正交。
        check(!face.toolNames.contains { $0.hasPrefix("+") },
              "T-WATCHFACE ③工具名一律 allowlist 写法（带 + 就是增补，默认四件会一起进来）")

        // —— ④ 扩展面: 只挂联网搜索那一个 ——
        let extArgs = PiRpcTransport.extensionArguments(
            hostedExtensionPath: "/tmp/mangox/ext/mangox-approval.ts",
            codemodeExtensionPath: nil,
            dreamExtensionPath: nil,
            computerExtensionPath: nil,
            enabled: face.mountedExtensionPaths)
        let mounted = stride(from: 0, to: extArgs.count - 1, by: 1)
            .filter { extArgs[$0] == "--extension" }
            .map { extArgs[$0 + 1] }
        check(mounted == [PiRpcTransport.builtinLlamaExtension,
                          "/tmp/mangox/ext/mangox-approval.ts",
                          webPath],
              "T-WATCHFACE ④只挂内置 llama + 审批桥 + 联网搜索（computer/codemode/dream 一个都不许在）"
              + " | 实际 \(mounted)")

        // —— ⑤ 三个"恒假"的面 ——
        check(!face.startsComputer && !face.injectsKnowledge && !face.injectsSOP,
              "T-WATCHFACE ⑤分析段不起 helper / 不注知识块 / 不注 SOP（三个都是\"不存在\"，不是\"挂了没生效\"）")

        // —— ⑥ 没配联网搜索: 扩展空, 但**工具名不缩** ——
        // 若这一格写反（没配 key 就把 bocha 从允许列表里摘掉），那么"今天没配 key、明天配了"
        // 这两天走的是**两个不同的工具面**, 而配置改动只影响挂载、不该改只读面的定义。
        let bare = PiRpcTransport.analysisFace(webSearchPath: nil)
        check(bare.mountedExtensionPaths.isEmpty
              && bare.toolNames == face.toolNames,
              "T-WATCHFACE ⑥没配搜索 ⇒ 不挂扩展，但工具名清单不随之缩水（配置改的是挂载，不是定义）")

        // —— ⑦ 对照: 普通回合的档位面没被这段改动碰过 ——
        // 没有这一格, ①~⑥ 全绿也可能是因为"把只读面做成了全局默认"。
        check(AgentMode.spawnArguments(for: .full, businessExtensions: [])
              == ["--tools", "+grep,+find,+ls"]
              && AgentMode.spawnArguments(for: .minimal, businessExtensions: [])
              == ["--tools", "read,bash,write,edit"],
              "T-WATCHFACE ⑦对照: 完整档 / 极简档的 --tools 原样（只读面没有污染档位）")

        // —— ⑧ 起不起 computer helper 的唯一决策点 ——
        // ⑤ 断言的是**面里的字段**, 这一条断言的是**生产代码真正调用的那个函数**。
        // 两者会分叉: 面算对了, 但生产侧若写成 `?? false`, 普通回合就再也不起 helper
        // (用户视角: computer 整个功能静默失效, 而 ⑤ 一直是绿的)。
        // nil 分支 = 普通回合, 必须为 true —— 真机实测(2026-11-16)对照臂量到 1 次 start。
        check(PiRpcTransport.shouldStartComputer(face) == false
              && PiRpcTransport.shouldStartComputer(nil) == true,
              "T-WATCHFACE ⑧分析段不起 helper、普通回合照旧起（nil 走 true 是唯一默认）")
    }
}
