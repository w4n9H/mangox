//
//  CaseSessionToolsStale —— 旧版「只读分析面」留下的 transcript 不能被复用
//
//  为什么这条非有不可（2026-11-18，boss 真机撞到的那个 bug 的下半截）：
//    pi 把「这一场能用哪些工具」写进会话**首条** system message 的 `toolsAdded`，之后每次恢复
//    都拿它当权威（`_restoreToolsFromTranscript`：记录集 + `--tools +x` 增补，内置工具**不补回**）。
//    所以只删掉那张面还不够 —— 老会话文件里已经写着「read/grep/find/ls/bocha_web_search/write」，
//    恢复时照样把面盖回去，于是"改了配置、改了代码，它还是半残"。
//
//  判据是「缺 `bash` 或 `edit`」: 四档都有这两个内置工具，缺了只能是旧声明或坏数据。
//  处置是**隔离**（改名留档），不是手改 pi 的落盘格式 —— 那个耦合的代价比"忘掉一段对话"大。
//
//  反例（2026-11-18 实测，见 smokeMain 该段注释）：判据写成"总是隔离" ⇒ ② 红（好会话被丢掉）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSessionToolsStale() async {
        let dir = fixtureDir("p19staletools")

        // 造一份 jsonl: 头三行与真文件同形（session / model_change / thinking_level_change），
        // 第四行是带声明的 system message。
        func writeSession(_ name: String, declared: [String]) -> String {
            let path = dir + "/" + name + ".jsonl"
            let tools = declared.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
            let body = """
            {"type":"session","version":3,"id":"11111111-1111-1111-1111-111111111111","cwd":"/tmp"}
            {"type":"message","id":"a","parentId":null,"message":{"role":"system","content":"","toolsAdded":[\(tools)]}}
            {"type":"message","id":"b","parentId":"a","message":{"role":"user","content":"你好"}}
            """
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }

        // —— ① 旧声明（缺 bash / edit）⇒ 隔离 ——
        let stale = writeSession("stale", declared: ["read", "grep", "find", "ls",
                                                     "bocha_web_search", "write"])
        let before = (try? String(contentsOfFile: stale, encoding: .utf8)) ?? ""
        let moved = PiRpcTransport.quarantineStaleSessionFile(stale)
        check(moved != nil, "T-STALETOOLS ①旧声明（缺 bash/edit）⇒ 隔离")
        check(!FileManager.default.fileExists(atPath: stale),
              "T-STALETOOLS ①原路径必须**空出来**（不空出来 pi 还读那份旧声明，隔离等于没做）")
        let kept = moved.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        check(kept == before,
              "T-STALETOOLS ①隔离是**改名不是删**：内容逐字节不变（用户的数据不能被我们悄悄丢掉）")
        check(moved?.contains(".stale-") == true,
              "T-STALETOOLS ①后缀带 `.stale-<时间>`（下次人工排查时能一眼认出是哪一份）")
        check(PiRpcTransport.quarantineStaleSessionFile(stale) == nil,
              "T-STALETOOLS ①幂等：文件已经挪走 ⇒ 再调什么都不做（不生成一串 .stale 副本）")

        // —— ② 正常声明 ⇒ 一个字节都不动 ——
        let healthy = writeSession("healthy", declared: ["read", "bash", "edit", "write",
                                                         "grep", "find", "ls"])
        check(PiRpcTransport.quarantineStaleSessionFile(healthy) == nil,
              "T-STALETOOLS ②正常声明（含 bash/edit）⇒ **不隔离**"
              + "（这一格是反例的方向盘：写成「总是隔离」就红，代价是每轮都把好会话丢掉）")
        check(FileManager.default.fileExists(atPath: healthy),
              "T-STALETOOLS ②且文件原位不动")

        // —— ③ 读不出来 ⇒ 不误伤 ——
        check(PiRpcTransport.quarantineStaleSessionFile(dir + "/nope.jsonl") == nil,
              "T-STALETOOLS ③文件不存在 ⇒ nil（新会话本来就没有文件）")
        let broken = dir + "/broken.jsonl"
        try? "这不是 JSON\n第二行也不是\n".write(toFile: broken, atomically: true, encoding: .utf8)
        check(PiRpcTransport.quarantineStaleSessionFile(broken) == nil,
              "T-STALETOOLS ③坏 JSON ⇒ nil（**不知道**不等于**脏**；判成脏就是把用户的会话删了）")
        check(FileManager.default.fileExists(atPath: broken),
              "T-STALETOOLS ③坏文件也不许挪走（挪走 = 我们替它做了决定）")
        let noDecl = dir + "/nodecl.jsonl"
        try? "{\"type\":\"session\",\"version\":3}\n".write(toFile: noDecl, atomically: true,
                                                          encoding: .utf8)
        check(PiRpcTransport.quarantineStaleSessionFile(noDecl) == nil,
              "T-STALETOOLS ③没有声明 ⇒ nil（那次没记工具面 = 没有可覆盖的东西）")

        // —— ④ 只缺一个也必须隔离 ——
        let onlyEdit = writeSession("onlyedit", declared: ["read", "bash", "write"])
        check(PiRpcTransport.quarantineStaleSessionFile(onlyEdit) != nil,
              "T-STALETOOLS ④缺 `edit` 也算旧声明（`||` 写成 `&&` 的话这一格红）")
    }
}
