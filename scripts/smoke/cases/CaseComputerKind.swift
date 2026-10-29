//
//  CaseComputerKind.swift
//  P18: computer 的三个工具**归类** —— 它们原来落 `.other`(徽章写着 OTHER)。
//
//  ⚠️ 只改 `kindFor` 不改 `toolHead` 会**丢信息**, 而且是静默的:
//     `toolHead` 的通用式是 `title = path ?? cmd ?? name`, 而 computer 传的是 `app` ——
//     它既不是 path 也不是 command ⇒ title 退成工具名、command 恒 nil ⇒
//     卡头只剩 `computerAct` 一个词, **看不出动的是哪个 App**。审批时人得在屏幕上自己找。
//     这与 `.search` 那条(查询词必须占 title)是同一种错, 只是丢的是另一个字段。
//
//  ⚠️ 工具名一律取自 `PiRpcTransport` 的常量, **不手抄字面量** —— 同 `T-TOOL` 里
//     `webSearchToolNames` 那条:`kindFor` 的 `if` 比较一旦与常量漂开, 这里立刻红。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseComputerKind() async {
        print("== T-CKIND computer 工具归类 (读界面 / 动界面 是两个 kind) ==")

        final class Sink: AgentTransportDelegate {
            var events: [AgentEvent] = []
            func transport(_ t: any AgentTransport, didEmit event: AgentEvent) { events.append(event) }
            func transport(_ t: any AgentTransport, didFailEngineWithDiagnosis d: String) {}
        }
        let sink = Sink()
        let pi = PiRpcTransport()
        pi.delegate = sink
        func lastTool() -> ToolCall? {
            sink.events.compactMap { e -> ToolCall? in
                if case .toolUpdated(let t) = e { return t }
                return nil
            }.last
        }

        let crTool = PiRpcTransport.computerReadToolName
        let caTool = PiRpcTransport.computerActToolName

        // ① 读界面
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"cr1","toolName":"\#(crTool)","args":{"app":"计算器"}}"#)
        let crCard = lastTool()
        check(crCard?.kind == .computerRead,
              "T-CKIND \(crTool) 归到 .computerRead (不落 other, 实测 \(String(describing: crCard?.kind)))")
        check(crCard?.kind.label == "computerRead",
              "T-CKIND 徽章 = computerRead (原样, 不被 upper 化)")
        check(crCard?.title == "计算器",
              "T-CKIND 读界面: `app` 占 title (通用式认 path/command ⇒ 它会被丢掉, 实测 \(String(describing: crCard?.title)))")
        check(crCard?.command == nil, "T-CKIND 读界面没有动作列 (read 没有 op 参数)")
        check(crCard?.kind.defaultColor == ToolKind.read.defaultColor,
              "T-CKIND 读界面与 read 同族色 (看, 不是改)")

        // ② 动界面 —— 与读界面**不混成一个标签**: 它们是两档权限, 回看时问的是两个问题
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"ca1","toolName":"\#(caTool)","args":{"app":"计算器","op":"press","index":5,"seq":1}}"#)
        let caCard = lastTool()
        check(caCard?.kind == .computerAct,
              "T-CKIND \(caTool) 归到 .computerAct (与读界面分开)")
        check(caCard?.title == "计算器", "T-CKIND 动界面: `app` 占 title")
        check(caCard?.command == "press",
              "T-CKIND 动界面: 动作进 command 列 (审批时得看见要做什么, 实测 \(String(describing: caCard?.command)))")
        check(caCard?.kind.defaultColor == ToolKind.bash.defaultColor,
              "T-CKIND 动界面与 bash 同族色 (执行族, 与读界面不同色)")

        // ③ setValue 的**正文**必须看得见 —— 审批时"要往这个框里写什么"就是这个动作的全部内容
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"ca2","toolName":"\#(caTool)","args":{"app":"TextEdit","op":"setValue","text":"你好世界"}}"#)
        check(lastTool()?.command == "setValue \"你好世界\"",
              "T-CKIND setValue 正文进 command (只写 op 等于把要写的内容藏起来)")

        // ④ 省略 `app` = 读/动**前台**那个 App。卡头用真名占位, **不编一个"前台"上去**
        //    —— 那一刻前台是谁, 推导这一层并不知道 (编了就是替扩展猜)。
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"cr2","toolName":"\#(crTool)","args":{}}"#)
        check(lastTool()?.title == crTool,
              "T-CKIND 省略 app 时用真名占 title (不猜前台是谁)")

        // ⑤ 反身自证: 上面那些断言不是恒真 —— 换成一个没登记的名字必须**回到** other。
        //    没有这一条, ①② 在"kindFor 恒返回 computerRead"的世界里也会绿。
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"zz1","toolName":"computer_scroll","args":{"app":"计算器"}}"#)
        check(lastTool()?.kind == .other,
              "T-CKIND 未登记的 computer_scroll 仍落 other (归位是**按名**, 不是按前缀猜)")

        // ⑥ 编解码往返: 新 kind 必须能被落库与重放认回来 (旧版读新库会降级成 other —— 那是
        //    编码里写的兜底, 不崩就是全部要求)。
        if let card = caCard,
           let data = try? JSONEncoder().encode(card),
           let back = try? JSONDecoder().decode(ToolCall.self, from: data) {
            check(back.kind == .computerAct && back.title == "计算器" && back.command == "press",
                  "T-CKIND 新 kind 编解码往返不丢 (落库 → 重放)")
        } else {
            check(false, "T-CKIND 新 kind 编解码往返: 编码或解码失败")
        }
        let alien = #"{"id":"00000000-0000-0000-0000-000000000009","kind":"computerDrag","title":"x","details":[],"phase":{"done":{}}}"#
        check((try? JSONDecoder().decode(ToolCall.self, from: Data(alien.utf8)))?.kind == .other,
              "T-CKIND 陌生 computer* rawValue 降级 other (旧版 App 读新库不崩)")

        // ⑦ 打开 App (批 2d): 又是**另一个** kind —— 它归读面那道门, 与动界面不是一件事。
        let coTool = PiRpcTransport.computerOpenToolName
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"co1","toolName":"\#(coTool)","args":{"app":"Calculator"}}"#)
        let coCard = lastTool()
        check(coCard?.kind == .computerOpen,
              "T-CKIND \(coTool) 归到 .computerOpen (落 other 会让「只是打开了它」与「进去按了东西」分不开)")
        check(coCard?.kind.label == "computerOpen", "T-CKIND 徽章 = computerOpen (原样)")
        check(coCard?.title == "Calculator",
              "T-CKIND 打开 App: `app` 占 title (实测 \(String(describing: coCard?.title)))")
        check(coCard?.command == nil, "T-CKIND 打开 App 没有动作列 (它没有 op 参数)")
        check(coCard?.kind.defaultColor == ToolKind.computerAct.defaultColor,
              "T-CKIND 打开与动界面同族色 (都是「执行」, 与「看」分开)")
        if let card = coCard,
           let data = try? JSONEncoder().encode(card),
           let back = try? JSONDecoder().decode(ToolCall.self, from: data) {
            check(back.kind == .computerOpen && back.title == "Calculator",
                  "T-CKIND computerOpen 编解码往返不丢 (落库 → 重放)")
        } else {
            check(false, "T-CKIND computerOpen 编解码往返: 编码或解码失败")
        }
    }
}
