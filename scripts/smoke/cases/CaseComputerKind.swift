//
//  CaseComputerKind.swift
//  工具**归类**: `kindFor` 把工具名归到哪个 kind, 以及 `toolHead` 从参数里挑什么上卡。
//
//  三个时间点: P18 的三个 (read/act/open) → 2026-11-23 补齐后三档 (tap/type/keys) 与
//  **自建扩展的三个工具** (follow_up / feishu_attach / note_proposal)。后六个原来全落 `.other`
//  (boss 实测截图: `other computer_type` / `other computer_keys`)。
//
//  ⚠️ 只改 `kindFor` 不改 `toolHead` 会**丢信息**, 而且是静默的:
//     `toolHead` 的通用式是 `title = path ?? cmd ?? name`, 而 computer 传的是 `app` ——
//     它既不是 path 也不是 command ⇒ title 退成工具名、command 恒 nil ⇒
//     卡头只剩 `computerAct` 一个词, **看不出动的是哪个 App**。审批时人得在屏幕上自己找。
//     这与 `.search` 那条(查询词必须占 title)是同一种错, 只是丢的是另一个字段。
//
//  ⚠️ 反过来也有一个坑(2026-11-23 才看见): `toolHead` 里**早就**为 tap/type/keys 写好了卡头,
//     但 `.other` 分支在它前面 return ⇒ 那三段**从来没执行过**。所以"归位"这一件事同时决定
//     "标签对不对"与"卡头那一段活不活" —— 判据必须两头都钉。
//
//  ⚠️ 工具名一律取自 `PiRpcTransport` 的常量, **不手抄字面量** —— 同 `T-TOOL` 里
//     `webSearchToolNames` 那条:`kindFor` 的 `if` 比较一旦与常量漂开, 这里立刻红。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseComputerKind() async {
        print("== T-CKIND 工具归类 (computer 六档各一个 kind + 自建扩展三件工具) ==")

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

        // ══ ⑧ 第四~六档 (2026-11-23): 它们原来全落 `other` ══════════════════════
        // boss 实测截图里那三行 `email other computer_type / computer_tap / computer_keys`。
        // ⚠️ 代价不止标签难看: `toolHead` 对 `.other` **先一步** return ⇒ 早就为这三档写好的
        //    卡头(`tap (x,y)` / `type: …` / `keys: …`)**从写下来那天起没执行过** —— 卡上只剩
        //    `app=com.tencent.xinWeChat` 这种"首个标量参数"，人看不出它点了哪儿、写了什么。
        let ctTool = PiRpcTransport.computerTapToolName
        let cyTool = PiRpcTransport.computerTypeToolName
        let ckTool = PiRpcTransport.computerKeysToolName

        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"ct1","toolName":"\#(ctTool)","args":{"app":"微信","x":12,"y":34}}"#)
        let ctCard = lastTool()
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"cy1","toolName":"\#(cyTool)","args":{"app":"微信","text":"你好","submit":true}}"#)
        let cyCard = lastTool()
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"ck1","toolName":"\#(ckTool)","args":{"app":"微信","strokes":["cmd+a","delete"]}}"#)
        let ckCard = lastTool()

        check(ctCard?.kind == .computerTap && cyCard?.kind == .computerType
              && ckCard?.kind == .computerKeys,
              "T-CKIND 后三档各归各位, **不落 other** (实测 \(String(describing: ctCard?.kind))"
              + " / \(String(describing: cyCard?.kind)) / \(String(describing: ckCard?.kind)))")
        check(ctCard?.command == "tap (12,34)"
              && cyCard?.command == "type + Enter (send): \"你好\""
              && ckCard?.command == "keys: cmd+a → delete",
              "T-CKIND 三档卡头说得出「点了哪儿 / 写了什么 / 按了哪几个键」"
              + " (实测 \(String(describing: ctCard?.command)) | \(String(describing: cyCard?.command))"
              + " | \(String(describing: ckCard?.command)))")
        check(ctCard?.title == "微信" && cyCard?.title == "微信" && ckCard?.title == "微信",
              "T-CKIND 三档的 `app` 仍占 title (动的是谁, 这一列不能丢)")
        check(ctCard?.kind.defaultColor == ToolKind.computerAct.defaultColor
              && cyCard?.kind.defaultColor == ToolKind.computerAct.defaultColor
              && ckCard?.kind.defaultColor == ToolKind.computerAct.defaultColor,
              "T-CKIND 三档与 act **同族色** (都进了操作面那道门; 分开的只是标签, 不是语义)")
        // ⚠️ 这三档**没有**编解码往返那一条 —— `case` 名与 rawValue 同源, ⑦ 已经证过
        //    "新 kind 落库 → 重放"这条路; 再抄三遍只是同一件事多三行。

        // ══ ⑨ 自建扩展的三个工具 (2026-11-23): 同样不该落 other ════════════════
        // 名字一律**取自常量**（`followUpToolNames` / `attachToolNames` / `dreamToolNames`）:
        // `kindFor` 一旦与常量漂开, 这里立刻红（同 `webSearchToolNames` 那条的做法）。
        let fuTool = PiRpcTransport.followUpToolNames[0]
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"fu1","toolName":"\#(fuTool)","args":{"after_minutes":45,"why":"构建还在跑，45 分钟后再看"}}"#)
        let fuCard = lastTool()
        check(fuCard?.kind == .followUp && fuCard?.title == "构建还在跑，45 分钟后再看"
              && fuCard?.command == "in 45 min",
              "T-CKIND follow_up: `why` 占 title (它约的是什么, 这是卡上唯一的信息), 时长进 command"
              + " (实测 \(String(describing: fuCard?.title)) | \(String(describing: fuCard?.command)))")

        let faTool = PiRpcTransport.attachToolNames[0]
        // ⚠️ 故意让 `name` 与磁盘上的文件名**不同** —— 断言"发出去的名字"与"哪个文件"两半都在:
        //    只取一个的话, 改名发出去的那种调用在回看时就认不出是哪个文件。
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"fa1","toolName":"\#(faTool)","args":{"path":"/Users/x/Documents/scan_001.pdf","name":"九十月报.pdf"}}"#)
        let faCard = lastTool()
        check(faCard?.kind == .feishuAttach && faCard?.title == "九十月报.pdf"
              && faCard?.command == "file: scan_001.pdf",
              "T-CKIND feishu_attach: 卡头是**用户收到的名字**, 磁盘文件名进 command"
              + " (整条绝对路径不上卡; 实测 \(String(describing: faCard?.title))"
              + " | \(String(describing: faCard?.command)))")

        // ⚠️ 这条同时是"通用式会撒谎"的反证: `note_proposal` 的 `base_hash` 按 key 排序是最靠前
        //    的标量参数, 走兜底的话卡头会读成 `base_hash=` —— 一个恒空、由 App 自己填的机器字段。
        let npTool = PiRpcTransport.dreamToolNames[0]
        pi.handleRPCLine(#"{"type":"tool_execution_start","toolCallId":"np1","toolName":"\#(npTool)","args":{"kind":"replace","target_path":"/Users/x/.mangox/note/周报.md","reason":"这条已经过期了","base_hash":"","sources":[{"kind":"session","id":"s1"}]}}"#)
        let npCard = lastTool()
        check(npCard?.kind == .noteProposal && npCard?.title == "周报.md"
              && npCard?.command == "replace",
              "T-CKIND note_proposal: 「改哪一篇 + 哪种改动」上卡, 且**不把 `base_hash` 搬上来**"
              + " (实测 \(String(describing: npCard?.title)) | \(String(describing: npCard?.command)))")
        check(ToolKind.noteProposal.defaultColor != ToolKind.write.defaultColor,
              "T-CKIND 提案**不许**用「已改了」那支色 (采纳之前笔记一个字节都没动)")
    }
}
