//
//  LedgerFence.swift
//  P19.2 S10 —— 助理「工作日志」的写围栏（客户端那一半）。
//
//  ⚠️ 这一层**只回答「能不能做」**（S11 起接在审批桥上并生效）。免检那一半在扩展侧:
//     两处但非两份真相 —— 扩展只答「这条写要不要弹卡」，这里只答「这条写准不准」。
//
//  为什么要有客户端这一半（而不是只靠扩展）:
//    扩展那侧只回答一个问题 —— **能不能免检**（新建文件不必弹卡）。它拦不住「弹了卡、
//    客户端放行」这条路，而巡检轮恰恰是 `unattended: true` ⇒ `askApproval = false` ⇒
//    审批桥对**任何**请求都回 Allow。于是「给巡检轮加 write」在只有扩展的情况下等于
//    一条能往任意路径写、零审批、无人在场的后台回路 —— 比现在糟得多。
//    ⇒ 两处但非两份真相：扩展只答「能不能免检」，这里只答「能不能做」。
//
//  判据只有一条，其余全是它的推论:
//    **标准化之后，目标必须与账本路径逐字符相等。**
//    不做前缀比较 —— `<账本>/../x` 以账本路径开头，却不在账本上；这就是
//    "字符串前缀比较"那个写法最典型的漏洞（反例 ①）。
//
//  为什么相对路径与 `~` 一律拒（而不是展开后比）:
//    写到哪**取决于工具怎么解析**，而 Node 侧不展开 `~`、相对路径的基准也可能不是我们
//    以为的那个目录。巡检轮**无人可问**（Deny 是唯一不会出事的选择），而代价只是
//    「模型得写绝对路径」—— 那句绝对路径本来就在 prompt 里。
//

import Foundation

/// 账本围栏：本回合的写动作**只能落在工作日志这一份上**。
///
/// 与 `ExecGate` 的分工：`ExecGate` 管**执行轮**（有人授权、有快照可回滚），
/// `LedgerFence` 管**巡检轮 / 对话轮**（无人授权、只许账本）。两者不共用判据 ——
/// 执行轮可以写项目、巡检轮不能，合在一起早晚有一边被放宽。
enum LedgerFence {

    enum Verdict: Equatable {
        case allow
        /// 理由串以「账本围栏外：」开头 —— 落痕按前缀分类，不去解析句子（同 `Redline` 的写法）。
        case deny(String)

        var isAllowed: Bool { self == .allow }
        var reason: String? {
            if case .deny(let r) = self { return r }
            return nil
        }
    }

    /// 围栏外碰到写请求时怎么办 —— 由「**这一轮有没有人在场按卡**」决定（P19.2 S12）。
    ///
    /// ⚠️ 判据不是「谁的权限更小」: 两种模式的**工具面完全相同**（都是 `patrolToolNames`，
    ///    都有一支笔、都只许写账本），唯一的差别是「围栏外」那一支的后果。
    ///    · 巡检轮**无人可问** ⇒ deny 是唯一不出事的选择（弹卡没人按 = 卡 32 秒再拒）；
    ///    · 对话轮**人在场** ⇒ 交给弹卡（deny 会把「帮我改这一行」变成「它说它改不了」）。
    ///
    /// 所以它不进 env、不进 spawn 参数、也不需要重启引擎 —— 它只在审批桥被问到时读一次。
    enum Mode: String, Equatable {
        case deny
        case ask
    }

    /// 「会写文件」的工具。**只认这四个**：不在里面的（含 `bash`）一律拒 ——
    /// `bash` 能写任何地方，而围栏看不到它要写哪；巡检轮的工具面里本来也没有它，
    /// 这里拒是给"以后有人顺手加回来"准备的。
    static let fileTools: Set<String> = ["write", "edit", "multiedit", "patch"]

    static let denyPrefix = "账本围栏外："

    /// 入参就是全部输入（纯函数，判据直接打在这里）。
    ///
    /// - Parameters:
    ///   - tool: 工具名（`write` / `edit` / …）。
    ///   - target: 目标 —— 写文件类工具是路径。
    ///   - ledgerPath: 本回合的账本落点（`nil` / 空 = 这一轮压根没有账本）。
    ///   - cwd: 本回合的工作目录。**只用于把拒绝理由说清楚**（「按工作目录会落到 X」），
    ///     不参与放行判断 —— 参与的话就等于承认了相对路径的解析规则，而那正是判不清的东西。
    static func check(tool: String, target: String,
                      ledgerPath: String?, cwd: String) -> Verdict {
        // ① 没有账本落点 ⇒ 全部拒。这一支是**保险**: 真被误接到一个没有账本的回合上时，
        //    后果是"什么都写不了"，而不是"什么都能写"。
        guard let ledger = ledgerPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ledger.isEmpty else {
            return .deny(denyPrefix + "这一轮没有账本落点，不该有写权限")
        }
        guard ledger.hasPrefix("/") else {
            return .deny(denyPrefix + "账本落点不是绝对路径（配置错误：\(ledger)）")
        }
        // ② 只有写文件的工具在讨论范围内
        guard fileTools.contains(tool) else {
            return .deny(denyPrefix + "\(tool) 不是写账本的工具")
        }
        // ③ 目标本身要判得清
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return .deny(denyPrefix + "目标为空")
        }
        if raw.hasPrefix("~") {
            return .deny(denyPrefix + "路径以 ~ 开头，判不清写到哪 —— 请写绝对路径 \(ledger)")
        }
        guard raw.hasPrefix("/") else {
            let guess = cwd.isEmpty ? raw : canonical(cwd + "/" + raw)
            return .deny(denyPrefix + "相对路径 \(raw)（按工作目录会落到 \(guess)）"
                         + " —— 请写绝对路径 \(ledger)")
        }
        // ④ 唯一那条判据: 标准化之后逐字符相等
        if canonical(raw) == canonical(ledger) { return .allow }
        return .deny(denyPrefix + "\(raw) 不是本轮的账本（只能写 \(ledger)）")
    }

    /// 路径标准化：消掉 `.` / `..` / 重复斜杠 / 结尾斜杠。**不做前缀比较**（见文件头）。
    ///
    /// `standardizingPath` 是纯字符串处理、不碰磁盘 —— 账本文件此刻**还不存在**（巡检轮
    /// 第一次写），任何"先查文件是否存在再规范化"的写法都会在第一步就判错。
    ///
    /// ⚠️ 它**不解析符号链接**。`<账本>` 本身被人做成软链时拦不住 —— 那需要人工构造，
    ///    且拦它得先 `resolvingSymlinksInPath`（会碰磁盘）。记在这里，不假装解决了。
    static func canonical(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
