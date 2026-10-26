//
//  CaseNestedTool.swift
//  codemode 的**嵌套调用**必须挂到父卡上（2026-10-26 boss 截图）。
//
//  两个症状（同一个根）：
//    ① 一次 codemode 调用显示成 `bash` + `codemode` **两行**（子调用被当成顶层工具卡）;
//    ② 顺序颠倒 —— `bash` 在前、`codemode` 在后。
//  根因：pi 为嵌套调用发的 `tool_execution_*` 带 `parentToolCallId`（= `<父callId>/<n>`，
//  见 pi 的 `core/nested-tool-calls.js`），MangoX 原来**完全没读**这个字段。
//
//  ⚠️ ②只在**重放**时出现：落库只写终态，子调用先完成（22ms）父后完成（84ms）⇒ seq 子在前。
//     直播时父卡先建、顺序反而是对的 —— 所以这条必须靠"父卡 id 指对"来断言，
//     不能靠"谁先被 append"。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseNestedTool() async {
        print("== T-NESTED codemode 嵌套调用 (父卡归属 · 兜底 · 编解码往返) ==")

        final class Sink: AgentTransportDelegate {
            var events: [AgentEvent] = []
            func transport(_ t: any AgentTransport, didEmit event: AgentEvent) { events.append(event) }
            func transport(_ t: any AgentTransport, didFailEngineWithDiagnosis d: String) {}
        }
        func cards(_ s: Sink) -> [ToolCall] {
            s.events.compactMap {
                if case .toolUpdated(let c) = $0 { return c }
                return nil
            }
        }

        // ① 父先起、子后起：子卡必须指向**这张**父卡
        let p1 = PiRpcTransport()
        let s1 = Sink()
        p1.delegate = s1
        p1.handleRPCLine(#"{"type":"agent_start"}"#)
        p1.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"cm1","toolName":"codemode","args":{"code":"const r = await tools.bash({command: 'ls -la'})"}}"#)
        let parent = cards(s1).last
        p1.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"cm1/1","toolName":"bash","args":{"command":"ls -la"},"parentToolCallId":"cm1"}"#)
        let child = cards(s1).last

        check(parent != nil && parent?.parentId == nil, "T-NESTED 父卡 (codemode) 自己没有 parentId")
        check(child?.parentId != nil, "T-NESTED 内层 bash 必须挂上 parentId (否则它自己占一行)")
        check(child?.parentId == parent?.id, "T-NESTED 内层 bash 指向**这张** codemode 卡 (不是随便某个)")
        check(child?.kind == .bash, "T-NESTED 内层卡仍是 bash 档 (没被父的 codemode 盖掉)")
        check(child?.id != parent?.id, "T-NESTED 父子是两张卡 (合并成一张 = 审批与输出都会串)")

        // ② 父卡查不到 ⇒ 退化成顶层行。**宁可多一行，也不许错挂**
        //    （错挂 = 这一行从界面上凭空消失，用户根本看不到它跑过）
        p1.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"zz/1","toolName":"bash","args":{},"parentToolCallId":"nope"}"#)
        check(cards(s1).last?.parentId == nil, "T-NESTED 找不到父卡时退化成顶层行 (不去猜父)")

        // ③ 终态仍带 parentId —— 重放是靠这一列归位的，丢了就等于没修
        p1.handleRPCLine(#"{"type":"tool_execution_end","toolCallId":"cm1/1","toolName":"bash","result":{"content":[{"type":"text","text":"ok"}],"details":{}},"isError":false,"durationMs":22}"#)
        let settled = cards(s1).last
        check(settled?.parentId == parent?.id, "T-NESTED 落定后 parentId 仍在 (重放才归得回父卡)")
        check(settled?.phase == .done, "T-NESTED 落定后相位是 done")

        // ④ 编解码往返：落库再读回，父子关系不许丢
        let encoded = try? JSONEncoder().encode(settled)
        if let encoded, var dict = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            check(dict["parentId"] != nil, "T-NESTED 卡片编码里带上了 parentId")
            if let again = try? JSONDecoder().decode(ToolCall.self, from: encoded) {
                check(again.parentId == parent?.id, "T-NESTED 编解码往返后 parentId 不变")
            } else {
                check(false, "T-NESTED 卡片解码失败")
            }

            // ⑤ 旧数据（2026-10-26 之前落库的卡片没有这一列）⇒ 解成 nil = 顶层行。
            //    ⚠️ 这条是**兼容红线**：老会话重放时若解崩或抛出，整条会话的历史工具行会一起没。
            dict.removeValue(forKey: "parentId")
            if let legacy = try? JSONSerialization.data(withJSONObject: dict),
               let old = try? JSONDecoder().decode(ToolCall.self, from: legacy) {
                check(old.parentId == nil, "T-NESTED 老载荷 (无 parentId) 解成顶层行, 不抛不崩")
                check(old.id == settled?.id, "T-NESTED 老载荷的其余字段照旧")
            } else {
                check(false, "T-NESTED 老载荷 (无 parentId) 必须能解出来")
            }
        } else {
            check(false, "T-NESTED 卡片编码失败")
        }

        // ⑥ 投影层：子卡必须**找得到宿主**（2026-10-26 boss 截图 · 5 次内层调用一次都没画出来）
        //    根因是两种 id 混用：`parentId` 存的是父卡**工具** id，而聊天流按**消息** id 索引。
        //    键对不上 ⇒ 子卡既被摘掉顶层行、又没挂进父卡 ⇒ **凭空消失**，而且全绿。
        //    ⚠️ 断言必须自己造出"消息 id ≠ 工具 id"的局面 —— 用同一个 UUID 当两边，
        //       这条用例就会在真出 bug 时也是绿的（那就是它为什么必须这么写）。
        if let parent, let child {
            let parentMsg = ChatMessage(role: .assistant, content: .tool(parent))
            let childMsg = ChatMessage(role: .assistant, content: .tool(child))
            let msgs = [parentMsg, childMsg]
            check(parentMsg.id != parent.id && childMsg.id != child.id,
                  "T-NESTED 前提: 消息 id 与工具 id 本来就不同 (不是同一个 UUID)")

            let byHost = ToolNesting.childrenByHostMessage(in: msgs)
            check(byHost.count == 1, "T-NESTED 投影: children 表只有 1 个宿主 (实测 \(byHost.count))")
            check(byHost[parentMsg.id]?.count == 1,
                  "T-NESTED 投影: 键是父卡**消息** id —— 用工具 id 当键 ⇒ 父卡查不到子卡 (消失)")
            check(byHost[parent.id] == nil,
                  "T-NESTED 投影: 用工具 id 当键必须查不到 (查到就说明键还在混用)")

            let attached = ToolNesting.attachedToolIds(in: msgs)
            check(attached.contains(child.id), "T-NESTED 投影: 挂上了的子卡才允许摘掉顶层行")

            // 父卡那条消息不在（压缩截断 / 老会话半截）⇒ **不许静默丢**，退回顶层行
            let orphan = [ChatMessage(role: .assistant, content: .tool(child))]
            check(ToolNesting.childrenByHostMessage(in: orphan).isEmpty,
                  "T-NESTED 投影: 父不在时 children 表为空")
            check(!ToolNesting.attachedToolIds(in: orphan).contains(child.id),
                  "T-NESTED 投影: 宿主不在 ⇒ 不算挂上 (否则这一行会从界面上消失)")
        } else {
            check(false, "T-NESTED 投影用例缺夹具 (父子卡没造出来)")
        }
    }
}
