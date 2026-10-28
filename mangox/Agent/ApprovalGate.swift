//
//  ApprovalGate.swift
//  P18 批 2a: 工具层的「要不要审批」—— 从**黑名单**翻成**只读白名单**。
//
//  ⚠️ 这一条是 P18 的前置修复, 也是本仓最反直觉的一处改动: 翻面之后**新工具默认要审批**,
//     而翻面之前是**新工具默认放行**。方向反了, 同一份代码就从"漏 = 出事"变成"漏 = 拦下问一句"。
//
//  翻面前的形状(2026-10-28 之前, PiRpcTransport 内嵌扩展里):
//      const SENSITIVE = new Set(["bash", "write", "edit"]);
//      if (!SENSITIVE.has(event.toolName)) return undefined;   // 只读工具放行
//  ⇒ 但凡有一个工具不在这三个名字里(扩展工具、pi 内置的 `find`/`ls`/`powershell`、
//    以后加的 `computer_act`…), 它**根本不会走到审批桥**, 客户端的 BashRiskEvaluator /
//    三档裁决 / 恒拒判据对它全部失效。这不是"漏了一个名字", 是**结构性豁免**。
//
//  ⚠️ 为什么白名单能在这里成立(而黑名单不行): 只读工具是**少数且稳定**的一类 —— pi 内置
//    8 个里 4 个只读, MangoX 自己的扩展工具 2 个, 就这么点。而"会做事"的工具是**开集合**:
//    以后每加一个都要人记得回来登记, 忘了就是零红灯的缺口。
//
//  ⚠️ 判据放在 Swift 而不是 JS 里: 生成的扩展源码由 `PiRpcTransport.approvalExtensionSource()`
//    从本文件的两个集合**插值**出来 ⇒ 白名单只有一个真源, 而且冒烟能对"生成出来的那段字"
//    直接断言(不需要真跑 node)。反例: 把 `readOnlyTools` 改回 ["bash","write","edit"] ⇒ 红。
//

import Foundation

enum ApprovalGate {

    /// **只读白名单** —— 判据的唯一真源。不在这个集合里的工具一律要审批。
    ///
    /// 逐条都是"它只读, 不可能改任何东西":
    ///   · `read` / `grep` / `ls` / `find` —— pi 的四个内置只读工具(另外四个是
    ///     `bash` / `write` / `edit` / `powershell`, 都会改盘或执行命令);
    ///   · `bocha_web_search` —— MangoX 自带的搜索扩展(只发网络请求, 不落盘);
    ///   · `computer_read` —— P18 的读界面。**三档都放行**(见 §03 三档表: read 那一行
    ///     三档全是"静默放行") ⇒ 放行由这张表实现, 客户端桥不需要为它写分支。
    static let readOnlyTools: Set<String> = [
        "read", "grep", "ls", "find",
        "bocha_web_search",
        "computer_read",
    ]

    /// **容器工具** —— 它自己不做任何动作, 只是把别的工具调起来; 内层每一次调用都会
    /// **再走一遍同一个 tool_call 钩子**。
    ///
    /// 依据不是推测, 是 pi 自己的文档(`dist/extensions/codemode/tool.js` 头注释原文):
    ///   "Nested calls run through the agent loop's tool pipeline (`ctx.executeTool`), so
    ///    validation, `tool_call`/`tool_result` hooks, and permission checks apply exactly as
    ///    for direct calls."
    /// ⇒ 放行 `codemode` 本身**不等于**放行它写文件: 里面那次 `write` 会再进来问一次。
    /// ⚠️ 这条依据要是没了(pi 改了嵌套调用的路子), 这个集合必须清空 —— 否则 codemode
    ///   就成了一条绕过审批的通道, 而且是静默的。
    static let passthroughContainers: Set<String> = ["codemode"]

    /// computer 的工具名**前缀**。用前缀不用名单: 以后加 `computer_scroll` / `computer_drag`
    /// 自动落进"要审批"这一侧 —— 漏 = 出事的方向必须靠结构, 不能靠人记得回来补一行。
    static let computerToolPrefix = "computer_"

    static func isComputerTool(_ toolName: String) -> Bool {
        normalized(toolName).hasPrefix(computerToolPrefix)
    }

    /// 这个工具要不要人拍板。**默认要** —— 只有明确只读(或明确的容器)才放行。
    static func needsApproval(_ toolName: String) -> Bool {
        let name = normalized(toolName)
        if readOnlyTools.contains(name) { return false }
        if passthroughContainers.contains(name) { return false }
        return true
    }

    /// 塞进 JS 的字面量。排序 ⇒ 同样的集合生成同样的源码, 才会"内容没变就不重写文件"
    /// (`ensureExtensionFile` 靠这个判断), 否则每次启动都重写一遍扩展文件。
    static func jsSetLiteral(_ names: Set<String>) -> String {
        "[" + names.sorted().map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    /// 工具名是**契约 token**(pi 定的标识符), 去空白后可比较; 不做大小写猜测以外的事。
    private static func normalized(_ toolName: String) -> String {
        toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
