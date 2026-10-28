//
//  CaseApprovalGate.swift
//  P18 批 2a: 工具层「要不要审批」的翻转 + 远程驱动档显式拒 computer。
//
//  ⚠️ 这一批的**工作量在造门, 不在改实现**: 翻面本身只是把三个名字换成一个集合,
//    真正缺的是"把 SENSITIVE 改回黑名单时必须变红"的断言(§04 前置门 1 的原话)。
//
//  ⚠️ 这里断言的是**生成出来的那段 JS 源码字符串**(`approvalExtensionSource()`,
//    纯函数不落盘), 不是 grep 源文件 —— 那种门只认字, 认不出"生成逻辑把集合漏掉了"。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseApprovalGate() async {
        print("== T-APPROVAL 工具层默认敏感 (P18 批 2a) ==")

        // MARK: ① 翻面: 不在只读白名单 ⇒ 要审批

        check(ApprovalGate.needsApproval("bash"),
              "T-APPROVAL bash 要审批 (它本来就在, 翻面不该把它漏出去)")
        check(ApprovalGate.needsApproval("write"), "T-APPROVAL write 要审批")
        check(ApprovalGate.needsApproval("edit"), "T-APPROVAL edit 要审批")
        check(ApprovalGate.needsApproval("powershell"),
              "T-APPROVAL pi 的内置写工具一律要审批 (它不在只读那一半里)")
        // 这一条就是本次翻面的全部意义: 名字没在任何名单里的**新工具**, 默认要审批
        check(ApprovalGate.needsApproval("whatever_tool_ships_next_month"),
              "T-APPROVAL 没登记过的工具默认**要审批** (翻面前它自带豁免 —— 漏 = 出事的方向)")
        check(ApprovalGate.needsApproval("computer_act"),
              "T-APPROVAL 动界面要人拍板 (三档表: interactive 弹卡)")
        check(ApprovalGate.needsApproval("computer_scroll"),
              "T-APPROVAL 以后加的 computer_* 自动落入要审批 (判据是前缀, 不是名单)")

        // MARK: ② 只读白名单: 只有这几种能绕开

        for name in ["read", "grep", "ls", "find"] {
            check(!ApprovalGate.needsApproval(name),
                  "T-APPROVAL pi 内置只读工具 \(name) 静默放行 (不列 ⇒ 每次读文件都弹卡, 没法用)")
        }
        check(!ApprovalGate.needsApproval("bocha_web_search"),
              "T-APPROVAL MangoX 自己的搜索扩展放行 (只发网络请求, 不落盘)")
        check(!ApprovalGate.needsApproval("computer_read"),
              "T-APPROVAL 读界面三档都放行 (§03 三档表 read 那一行) ⇒ 放行由白名单实现")
        check(!ApprovalGate.needsApproval("codemode"),
              "T-APPROVAL 容器工具放行, 内层逐个再进钩子 (pi 官方: nested calls 走同一条 tool pipeline)")
        check(!ApprovalGate.readOnlyTools.contains("bash")
                && !ApprovalGate.readOnlyTools.contains("write")
                && !ApprovalGate.readOnlyTools.contains("edit"),
              "T-APPROVAL 会改盘的三个不许进只读白名单 (写错一个 = 永久豁免, 零红灯)")

        // MARK: ③ 生成的扩展源码: 翻面真的落到了纸上

        let src = PiRpcTransport.approvalExtensionSource()
        check(src.contains("READ_ONLY.has(event.toolName)"),
              "T-APPROVAL 生成的扩展必须先判只读白名单 (否则源码和判据分家了)")
        check(!src.contains("const SENSITIVE") && !src.contains("SENSITIVE.has("),
              "T-APPROVAL 旧的 SENSITIVE 黑名单必须消失 (注释里提它没问题, 但代码里不许有) "
              + "—— 它一回来, 新工具又自带豁免")
        check(!src.contains("\"computer_act\""),
              "T-APPROVAL computer_act 不许出现在只读白名单里")
        for name in ApprovalGate.readOnlyTools {
            check(src.contains("\"\(name)\""),
                  "T-APPROVAL 只读白名单里的 \(name) 要真的被注进源码 "
                  + "(集合改了源码没改 = 静默失效)")
        }

        // MARK: ④ 远程驱动档真链路: computer 被拒 + 留痕 + 回 Deny

        let t = PiRpcTransport()
        t.updateApprovalMode(.autoJudge)
        t.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c_a1","toolName":"computer_act","args":{}}"#)
        t.handleRPCLine(#"{"type":"extension_ui_request","id":"u_a1","method":"select","title":"MANGOX|APPROVE|c_a1|computer_act|press #12"}"#)
        check(t.autoJudgeBlocks.count == 1,
              "T-APPROVAL 远程驱动档发起界面动作 ⇒ 必须留一条拦截记录 "
              + "(任务回执要能写「卡在 X」)")
        check(t.autoJudgeBlocks.first?.command == "press #12",
              "T-APPROVAL 留痕要带上它想干什么 实际:\(t.autoJudgeBlocks.first?.command ?? "nil")")
        check(t.sentCommands.contains { ($0["type"] as? String) == "extension_ui_response"
                                        && ($0["value"] as? String) == "Deny" },
              "T-APPROVAL 必须真的回 Deny —— 只记录不回 = 界面照样被动了")

        // 对照: 同一档下 write 仍然放行 (决定 8 不变) —— 只加 computer 这一条, 别顺手改别的
        let t2 = PiRpcTransport()
        t2.updateApprovalMode(.autoJudge)
        t2.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"c_a2","toolName":"write","args":{"path":"/tmp/x"}}"#)
        t2.handleRPCLine(#"{"type":"extension_ui_request","id":"u_a2","method":"select","title":"MANGOX|APPROVE|c_a2|write|/tmp/x"}"#)
        check(t2.autoJudgeBlocks.isEmpty,
              "T-APPROVAL 远程驱动档对 write 仍放行 (决定 8 那条不变量没被这次改坏)")
        check(t2.sentCommands.contains { ($0["value"] as? String) == "Allow" },
              "T-APPROVAL 对照组的应答是 Allow (要是 Deny 说明判据比 computer 宽)")
    }
}
