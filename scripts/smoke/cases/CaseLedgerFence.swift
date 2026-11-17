//
//  CaseLedgerFence —— P19.2 S10: 账本写围栏（客户端纯函数 + 扩展侧免检口径）
//
//  ⚠️ 这一步**没有任何可见效果** —— 工具面一个字没改、权限一律没开。所以判据必须自己把
//  「它会在该红的地方红」证明出来，否则它只是一段没人走的代码。
//
//  三层，缺一层就有一整类静默失败：
//    ① **纯函数**（`LedgerFence.check`）：唯一那条判据是「标准化之后逐字符相等」。
//       分开测是因为最典型的两个错法都在这里：前缀比较（`<账本>/../x` 放行）、
//       对 `~` / 相对路径想当然地展开（写到哪取决于工具怎么解析，判不清就不许放）。
//    ② **env 双闸门**（`ledgerFenceEnvironment`）：返回 nil = 不用改；父进程有残留 ⇒ 返**删掉
//       那个键**的完整环境。少了后半句，一个普通会话会莫名带上账本围栏。
//    ③ **扩展真跑**（node 里 import 真源码 + 驱动 tool_call）：只跑语法检查是**假门** ——
//       0.2.11 那次 `node --check` 对 ESM 静默退 0，2382 条断言全绿而引擎起不来。
//       这里直接看「免检还是弹卡」，并且**同一份 harness 必须能产出 asked>0**
//       （否则所有 asked==0 都可能只是 harness 没跑起来）。
//
//  反例（2026-11-17 实测，三处一起下 ⇒ 红点见下方各格的说明）：
//    · `canonical(raw) == canonical(ledger)` 改成 `raw.hasPrefix(ledger)`（前缀 + 不做标准化）
//      ⇒ ① 的两格归一 + ② 的 `<账本>/../evil.md` 一起红；
//    · 扩展 `insideLedger` 的 `nodePath.resolve(raw) === LEDGER_RESOLVED` 改成
//      `raw.indexOf(LEDGER_RESOLVED) === 0`（拿**原串**做前缀）⇒ ④c 红；
//    · 免检条件去掉三元、一律走 `insideLedger` ⇒ ④g 红（Cron 的新建文件被当成要审批）。
//
//  ⚠️ 两条**归因**要记住:
//    · 前导 `~` 那支**不是安全边界**（`~` 不以 `/` 开头，「非绝对即拒」已经兜住它），
//      它只值一句更好的话。所以断言打在理由上 —— 否则这支可以整段删掉而全绿。
//    · 「否则」那一支（`!outsideExecFence`）只能靠 ④g **和** ④h 两格合起来守:
//      单独一格都可能只是 `outsideExecFence` 恒假/恒真的巧合。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseLedgerFence() async {
        let dir = fixtureDir("p19ledgerfence")
        let ledger = dir + "/proj/.mangox/assistant/ABC.md"
        let ledgerDir = dir + "/proj/.mangox/assistant"

        func desc(_ v: LedgerFence.Verdict) -> String {
            switch v {
            case .allow: return "allow"
            case .deny(let r): return "deny(\(r))"
            }
        }
        /// 围栏判定（默认拿 `ledger` 当本回合的账本）。
        func judge(_ tool: String, _ target: String, _ ledgerPath: String? = nil) -> LedgerFence.Verdict {
            LedgerFence.check(tool: tool, target: target,
                              ledgerPath: ledgerPath ?? ledger, cwd: dir)
        }

        // ══ ① 放行面：只有账本本身 ═══════════════════════════════════════
        for (tool, target, what) in [
            ("write", ledger, "write 写账本 ⇒ 放行"),
            ("edit", ledger, "edit 改账本 ⇒ 放行（同一份文件，换工具不该换结论）"),
            ("write", ledgerDir + "//ABC.md", "重复斜杠归一后是同一条路径 ⇒ 放行"),
            ("write", ledgerDir + "/./ABC.md", "`.` 归一后是同一条路径 ⇒ 放行"),
        ] {
            let v = judge(tool, target)
            check(v.isAllowed, "T-LEDGERFENCE ①\(what)（实际 \(desc(v))）")
        }

        // ══ ② 拒绝面 ═══════════════════════════════════════════════════
        for (tool, target, what) in [
            ("write", ledger + "/../evil.md",
             "`<账本>/../evil.md` ⇒ 拒（**前缀一样却不在账本上** —— 前缀比较在这格放行）"),
            ("write", dir + "/proj/.mangox/assistant-x/ABC.md", "同名前缀的兄弟目录 `assistant-x/` ⇒ 拒"),
            ("write", dir + "/proj/.mangox/assistant2/ABC.md", "兄弟目录 `assistant2/` ⇒ 拒"),
            ("write", "ABC.md", "相对路径 ⇒ 拒（基准目录不一定是以为的那个）"),
            ("write", dir + "/proj/other.md", "项目内别的文件 ⇒ 拒（围栏只管账本）"),
            ("write", "/tmp/elsewhere.md", "别的绝对路径 ⇒ 拒"),
            ("bash", "echo hi > " + ledger, "`bash` 不是写账本的工具 ⇒ 拒（它要写哪，围栏看不见）"),
            ("write", "  ", "目标为空 ⇒ 拒"),
        ] {
            let v = judge(tool, target)
            check(!v.isAllowed, "T-LEDGERFENCE ②\(what)（实际 \(desc(v))）")
        }
        // 前导 `~` ⇒ 拒。⚠️ **安全性不是这支给的** —— 它不以 `/` 开头，下面那条「非绝对即拒」
        // 本来就会拒。「以 ~ 开头」这一支的价值是**消息**: 模型看到「请写绝对路径」会自己改，
        // 看到「相对路径」还以为换个相对写法就行。所以断言打在**理由**上，不只打在「拒了」上 ——
        // 只判「拒了」的话，这支可以整段删掉而判据全绿（那就是一段没人守得住的代码）。
        let tilde = judge("write", "~/.mangox/assistant/ABC.md")
        check(!tilde.isAllowed && (tilde.reason ?? "").contains("以 ~ 开头"),
              "T-LEDGERFENCE ②前导 `~` ⇒ 拒，且理由说清是 `~` 的问题（\(tilde.reason ?? "")）")

        // 没有账本落点 ⇒ 全部拒。这一支是保险: 误接到一个没有账本的回合上时,
        // 后果必须是"什么都写不了", 而不是"什么都能写"。
        check(!judge("write", ledger, "").isAllowed,
              "T-LEDGERFENCE ③账本落点为空串 ⇒ 拒（\(desc(judge("write", ledger, "")))）")
        check(!judge("write", ledger, ".mangox/assistant/ABC.md").isAllowed,
              "T-LEDGERFENCE ③账本落点不是绝对路径（配置错误）⇒ 拒，而不是拿它去比")
        check(!LedgerFence.check(tool: "write", target: ledger, ledgerPath: nil, cwd: dir).isAllowed,
              "T-LEDGERFENCE ③ledgerPath = nil ⇒ 拒")

        // 理由串必须带前缀 —— 落痕按前缀分类，不去解析句子（同 `Redline` 的写法）
        let anyDeny = judge("write", "/tmp/x.md")
        check(anyDeny.reason?.hasPrefix(LedgerFence.denyPrefix) == true,
              "T-LEDGERFENCE ②拒绝理由以「\(LedgerFence.denyPrefix)」开头（落痕分类靠它）")
        // 相对路径那条要把「按工作目录会落到哪」说出来 —— 否则模型只能瞎猜为什么被拒
        let rel = judge("write", "ABC.md").reason ?? ""
        check(rel.contains(dir + "/ABC.md") && rel.contains(ledger),
              "T-LEDGERFENCE ②相对路径的拒绝理由说清**会落到哪**、以及该写什么（\(rel)）")

        // ══ ③ env 双闸门 ═══════════════════════════════════════════════
        let key = PiRpcTransport.ledgerFenceEnvKey
        check(key == "MANGOX_LEDGER_PATH",
              "T-LEDGERFENCE ③env 键名是契约 token（逐字进子进程，扩展那侧读的就是它）")
        check(PiRpcTransport.ledgerFenceEnvironment(existing: nil, ledgerPath: nil, inherited: [:]) == nil,
              "T-LEDGERFENCE ③没有账本 + 父进程无残留 ⇒ 返回 nil（= 什么都不用改）")
        let set = PiRpcTransport.ledgerFenceEnvironment(existing: nil, ledgerPath: ledger, inherited: [:])
        check(set?[key] == ledger, "T-LEDGERFENCE ③有账本 ⇒ env 里有它")
        let strip = PiRpcTransport.ledgerFenceEnvironment(existing: nil, ledgerPath: nil,
                                                          inherited: [key: "/stale/old.md"])
        check(strip != nil && strip?[key] == nil,
              "T-LEDGERFENCE ③父进程有残留 ⇒ 返回**删掉该键**的完整环境（不删 = 普通会话莫名带上围栏）")
        check(PiRpcTransport.ledgerFenceEnvironment(existing: nil, ledgerPath: "",
                                                   inherited: [key: "/stale/old.md"])?[key] == nil,
              "T-LEDGERFENCE ③空串等同 nil（不许把空串当落点下发）")
        let keep = PiRpcTransport.ledgerFenceEnvironment(existing: ["PATH": "/usr/bin"],
                                                         ledgerPath: ledger,
                                                         inherited: ["PATH": "/usr/bin", "HOME": "/h"])
        check(keep?["PATH"] == "/usr/bin" && keep?[key] == ledger && keep?["HOME"] == nil,
              "T-LEDGERFENCE ③existing 非 nil 时**优先用它**（不把父环境整份搬进来）")

        // ══ ④ 扩展真跑：免检还是弹卡 ═══════════════════════════════════
        // 把**真源码**写到 .mjs（真扩展是 .ts，由 pi 加载；这里只要 ESM 能 import）
        let extPath = dir + "/approval.mjs"
        try? PiRpcTransport.approvalExtensionSource()
            .write(toFile: extPath, atomically: true, encoding: .utf8)
        let syntax = runNodeSyntaxCheck(extPath)
        check(syntax.found, "T-LEDGERFENCE ④node 在（跑不起来的话下面每一格都是假绿）")
        check(syntax.ok, "T-LEDGERFENCE ④审批扩展源码真解析得过（\(syntax.detail)）")

        // harness: 装一个假 pi，驱动一次 write 的 tool_call，报告「有没有弹卡」
        let harness = dir + "/harness.mjs"
        let harnessSrc = """
        const ext = process.argv[2];
        const target = process.argv[3];
        const cwd = process.argv[4];
        process.chdir(cwd);
        let handler = null;
        const pi = { on: (name, fn) => { if (name === "tool_call") handler = fn; } };
        const mod = await import(ext);
        mod.default(pi);
        if (!handler) { console.log(JSON.stringify({ error: "no handler" })); process.exit(0); }
        let asked = 0;
        const ctx = { hasUI: true, ui: { select: async () => { asked += 1; return "Deny"; } } };
        const res = await handler(
          { toolName: "write", input: { path: target }, toolCallId: "t1" }, ctx);
        console.log(JSON.stringify({ asked, blocked: !!(res && res.block) }));
        """
        try? harnessSrc.write(toFile: harness, atomically: true, encoding: .utf8)

        /// 跑一次扩展。`ledgerEnv` = nil ⇒ 不设 `MANGOX_LEDGER_PATH`（模拟 Cron / 普通回合）。
        /// `execProject` 非 nil ⇒ 设 `MANGOX_EXEC_PROJECT`（回归 S6 那一半）。
        func run(_ target: String, ledgerEnv: String?, execProject: String? = nil) -> Int? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["node", harness, extPath, target, dir]
            var env = ProcessInfo.processInfo.environment
            if let ledgerEnv { env[key] = ledgerEnv } else { env.removeValue(forKey: key) }
            if let execProject { env["MANGOX_EXEC_PROJECT"] = execProject }
            else { env.removeValue(forKey: "MANGOX_EXEC_PROJECT") }
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let asked = obj["asked"] as? Int else { return nil }
            return asked
        }

        // 夹具: 账本目录与项目目录都真建出来（`fs.existsSync` 那一半要能判）
        try? FileManager.default.createDirectory(atPath: ledgerDir, withIntermediateDirectories: true)
        let cronProject = dir + "/cronproj"
        try? FileManager.default.createDirectory(atPath: cronProject, withIntermediateDirectories: true)

        // ④a 账本这一份 ⇒ **免检**（不弹卡）
        if let asked = run(ledger, ledgerEnv: ledger) {
            check(asked == 0, "T-LEDGERFENCE ④a 设了账本 env + 写账本 ⇒ 免检不弹卡（asked=\(asked)）")
        } else { check(false, "T-LEDGERFENCE ④a 跑不起来（harness 或 node 有问题）") }

        // ④b 同名前缀兄弟目录 ⇒ **弹卡**。这一格同时证明 ④a 不是「harness 从来没弹过卡」的假绿。
        if let asked = run(dir + "/proj/.mangox/assistant-x/ABC.md", ledgerEnv: ledger) {
            check(asked == 1, "T-LEDGERFENCE ④b 兄弟目录 `assistant-x/` ⇒ 弹卡（asked=\(asked)）")
        } else { check(false, "T-LEDGERFENCE ④b 跑不起来") }

        for (target, what) in [
            (ledger + "/../evil.md", "`<账本>/../evil.md` ⇒ 弹卡（扩展侧也不许做前缀比较）"),
            ("~/.mangox/assistant/ABC.md", "前导 `~` ⇒ 弹卡"),
            ("relative/ABC.md", "相对路径 ⇒ 弹卡"),
            (dir + "/proj/other.md", "项目内别的文件 ⇒ 弹卡（账本回合里项目也不是免检区）"),
        ] {
            if let asked = run(target, ledgerEnv: ledger) {
                check(asked == 1, "T-LEDGERFENCE ④c \(what)（asked=\(asked)）")
            } else { check(false, "T-LEDGERFENCE ④c 跑不起来: \(target)") }
        }

        // ④g **Cron 零漂移**：不设账本 env ⇒ 免检判断照旧只看 `outsideExecFence`。
        // 两格合起来才是旧的真值表: 项目内免检 / 项目外弹卡。少任何一格，另一格
        // 都可能只是「outsideExecFence 恒 false」的巧合。
        if let asked = run(cronProject + "/new.md", ledgerEnv: nil, execProject: cronProject) {
            check(asked == 0, "T-LEDGERFENCE ④g 不设账本 env + 项目内新建 ⇒ 照旧免检（Cron 行为不变，asked=\(asked)）")
        } else { check(false, "T-LEDGERFENCE ④g 跑不起来") }
        if let asked = run("/tmp/outside-ledger-check.md", ledgerEnv: nil, execProject: cronProject) {
            check(asked == 1, "T-LEDGERFENCE ④h 旧行为回归: 执行轮 + 围栏外 ⇒ 弹卡（S6 那半没被改坏）")
        } else { check(false, "T-LEDGERFENCE ④h 跑不起来") }

        // ══ ⑤ per-turn 下发：挂上 / 清回 ═══════════════════════════════
        // 防的是「漏清」—— 之后每一轮都只把那个过期账本当免检对象，
        // 而人看到的是"新建文件忽然都要审批了"，根本想不到是上一轮留下的路径。
        let mock = MockTransport()
        let store = ChatStore(transport: mock, dbPath: dir + "/p19lf.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()
        let sid = UUID()
        store.beginTurn(sid: sid, prompt: "巡检", ephemeral: false, cwd: dir,
                        unattended: true, ledgerPath: ledger)
        check(mock.lastLedgerFencePath == ledger,
              "T-LEDGERFENCE ⑤巡检轮把账本落点下发给 transport（实际 \(mock.lastLedgerFencePath ?? "nil")）")
        store.beginTurn(sid: sid, prompt: "闲聊", ephemeral: false, cwd: dir, unattended: false)
        check(mock.lastLedgerFencePath == nil,
              "T-LEDGERFENCE ⑤下一个普通回合**无条件清回 nil**（漏清 ⇒ write 只认过期账本，零红灯）")
        check(mock.ledgerFencePathUpdates == 2,
              "T-LEDGERFENCE ⑤两次都真的下发过（不是「值没变所以没调」—— 漏清正是这么藏起来的）")
    }
}
