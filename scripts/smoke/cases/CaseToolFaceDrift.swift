//
//  CaseToolFaceDrift.swift
//  P18: 会话「工具面」漂移的**判据** —— 这个会话看不到本次该有的哪些工具。
//
//  为什么这条判据值得单独一组断言: 它读的是 **pi 的会话文件**(内部格式, 几 MB 的 jsonl),
//  写错了不会崩、只会**说错话**:
//    · 解析错 ⇒ 每条提示都是假的 ⇒ 用户学会无视它 ⇒ 真出事那天没人看;
//    · 少一层"空 pinned 视为不缺" ⇒ 每新建一个会话先弹一句假警报(实测这层就漏过,
//      见下面 ⑦ 反面自证)。
//  所以这里不测 UI, 只测"给一份 jsonl, 它会说缺什么"。
//
//  ⚠️ fixture 的形状**照抄真实文件**(行 3 的 system 消息, `message.toolsAdded[*].name`),
//     不自己发明一层结构 —— 手写的"合理结构"与 pi 实际写的东西差一个 key 就足够让本功能
//     在真机上永远不响, 而这里全绿。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseToolFaceDrift() async {
        print("== T-TFDRIFT 会话工具面漂移 (钉住的清单里缺哪些) ==")

        let names = PiRpcTransport.computerToolNames
        let readTool = PiRpcTransport.computerReadToolName
        let actTool = PiRpcTransport.computerActToolName
        let mounted = ToolFaceDrift.expectedToolNames(computerMounted: true)
        let unmounted = ToolFaceDrift.expectedToolNames(computerMounted: false)

        // 真实行型: {"type":"message","id":…,"message":{"role":"system","content":[…],"toolsAdded":[{…}]}}
        func systemLine(added: [String] = [], removed: [String] = [], role: String = "system") -> String {
            func arr(_ xs: [String]) -> String {
                "[" + xs.map { #"{"name":"\#($0)","description":"x"}"# }.joined(separator: ",") + "]"
            }
            var parts = [#""type":"message""#, #""id":"x""#, #""message":{"role":"\#(role)""#,
                         #""content":[{"type":"text","text":"hi"}]"#]
            if !added.isEmpty { parts.append(#""toolsAdded":\#(arr(added))"#) }
            if !removed.isEmpty { parts.append(#""toolsRemoved":\#(arr(removed))"#) }
            return "{" + parts.joined(separator: ",") + "}}"
        }

        // ① 真实那一幕的重演: 老会话钉住 9 个工具, 里面**没有** computer_act
        let oldSession = [
            systemLine(added: ["read", "bash", "grep", readTool]),
            #"{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"帮我点一下"}]}}"#,
        ].joined(separator: "\n")
        let oldPinned = ToolFaceDrift.pinnedToolNames(jsonl: oldSession)
        check(oldPinned == Set(["read", "bash", "grep", readTool]),
              "T-TFDRIFT 钉住的清单 = system 里 toolsAdded 的名字集 (实测 \(oldPinned.sorted()))")
        check(ToolFaceDrift.missing(pinned: oldPinned, expected: mounted) == [actTool],
              "T-TFDRIFT 老会话只报缺 \(actTool), 不连带 read (实测 \(ToolFaceDrift.missing(pinned: oldPinned, expected: mounted)))")

        // ② 新会话(工具面齐全) ⇒ 一句都不说
        let fresh = systemLine(added: ["read", readTool, actTool])
        check(ToolFaceDrift.missing(pinned: ToolFaceDrift.pinnedToolNames(jsonl: fresh),
                                    expected: mounted).isEmpty,
              "T-TFDRIFT 工具面齐全时恒为空 (提示不许在正常会话里出现)")

        // ③ 顺序语义: 同一条 system 里**先删后加** ⇒ 名字回来。
        //    反过来(先加后删)就会把同一批里刚加的被吃掉 ⇒ 本该"不缺"却报缺。
        let readd = systemLine(added: [actTool], removed: [actTool])
        check(ToolFaceDrift.pinnedToolNames(jsonl: readd).contains(actTool),
              "T-TFDRIFT 同一条里先删后加 ⇒ 名字仍在 (顺序反了会误报缺)")

        // ④ 跨行: 先加、后一条 system 删掉 ⇒ 真的不在
        let dropped = [systemLine(added: [readTool, actTool]),
                       systemLine(removed: [actTool])].joined(separator: "\n")
        let droppedPinned = ToolFaceDrift.pinnedToolNames(jsonl: dropped)
        check(!droppedPinned.contains(actTool) && droppedPinned.contains(readTool),
              "T-TFDRIFT 后一条 system 的 toolsRemoved 真的生效 (只删指定的那个, 实测 \(droppedPinned.sorted()))")

        // ⑤ 只认 role == system: user / assistant 行里出现 toolsAdded 不算 (否则用户把工具名
        //    贴进对话就会让提示闭嘴)
        let impostor = systemLine(added: [actTool], role: "user")
        check(ToolFaceDrift.pinnedToolNames(jsonl: impostor).isEmpty,
              "T-TFDRIFT 非 system 行的 toolsAdded 不认 (role 判据)")

        // ⑥ 坏行 / 半截行不崩, 也不污染结果
        let messy = ["{not json at all \"toolsAdded\"",
                     systemLine(added: [readTool]),
                     "{\"type\":\"message\",\"message\":{\"role\":\"system\",\"toolsAdded\":[{\"desc\":\"没有 name\"}]}}",
        ].joined(separator: "\n")
        check(ToolFaceDrift.pinnedToolNames(jsonl: messy) == Set([readTool]),
              "T-TFDRIFT 坏行跳过、缺 name 的条目跳过, 其余照收")

        // ⑦ **反面自证**: pinned 为空 ⇒ 不许报缺。
        //    空 pinned 的语义是"这个会话还没被钉住"(首轮没写 / 旧格式), 那时 spawn 按当前
        //    工具集设置 ⇒ 全部可见。少了这道闸, 每新建一个会话都先弹一句假警报
        //    —— 这条**实测漏过**, 故留断言钉住。
        check(ToolFaceDrift.missing(pinned: [], expected: mounted).isEmpty,
              "T-TFDRIFT 空 pinned 不报缺 (否则每个新会话开局就假警报)")

        // ⑧ 排序稳定: 文案要逐字稳定, 不许每次换个次序 (Set 的遍历序是随机的)
        let sortedMiss = ToolFaceDrift.missing(pinned: ["read"], expected: mounted)
        check(sortedMiss == [actTool, readTool],
              "T-TFDRIFT 缺失清单按字母序 (实测 \(sortedMiss))")

        // ⑨ 本次侧: 没挂 computer (作用域空) ⇒ 没有"该有"的工具 ⇒ 永不报缺
        check(unmounted.isEmpty,
              "T-TFDRIFT 没挂 computer 时 expected 为空 (实测 \(unmounted.sorted()))")
        check(ToolFaceDrift.missing(pinned: ["read"], expected: unmounted).isEmpty,
              "T-TFDRIFT 没挂 computer 时, 工具面缺什么都与我无关 (不猜第三方扩展)")
        check(mounted == Set(names),
              "T-TFDRIFT expected 与 PiRpcTransport 的名字常量同源 (不手抄字面量, 实测 \(mounted.sorted()))")
    }
}
