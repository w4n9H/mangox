//
//  CaseMessageRevision.swift
//  流式滚动的轻量触发值（2026-11-04，B 批）。
//
//  病根：视图原来 `onChange(of: store.messages)` —— `ChatMessage` 是合成 `==`，
//    每个 chunk 都要把历史正文 / 工具输出 / 思考文本深比一遍，长会话下累积成平方级。
//
//  `messagesRevision` 必须覆盖**所有**写路径：整批替换、追加、就地改元素（相位 / 流式追加）。
//    `messages` 是 public `var`，外部（Capture / Scheduler / Mailbox）也会直接写，
//    所以记账只能挂在这个属性自己的 `didSet` 上 —— 漏一条路径 = 那次消息更新不跟随滚动，
//    而界面上只会表现为"偶尔没滚到底"，没有任何报错。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseMessageRevision() async {
        print("== T-MREV 消息 revision 覆盖所有写路径 ==")

        let dir = fixtureDir("msgrev")
        let store = ChatStore(transport: MockTransport(), dbPath: dir + "/r.db",
                              managedExtensionsDir: dir + "/ext")
        store.mailbox.stopScheduler()
        store.messages = []

        let r0 = store.messagesRevision

        store.messages.append(ChatMessage(role: .user, content: .text("第一句")))
        let r1 = store.messagesRevision
        check(r1 > r0,
              "T-MREV 追加消息必须推进 revision (实测 \(r0) → \(r1))")

        store.messages[0].isStreaming = true
        let r2 = store.messagesRevision
        check(r2 > r1,
              "T-MREV 就地改元素必须推进 revision (流式相位更新走这条路; 实测 \(r1) → \(r2))")

        store.messages[0].content = .text("第一句 + chunk")
        let r3 = store.messagesRevision
        check(r3 > r2,
              "T-MREV 就地改 content 必须推进 revision (实测 \(r2) → \(r3))")

        store.messages = []
        let r4 = store.messagesRevision
        check(r4 > r3,
              "T-MREV 整批替换必须推进 revision (切会话 / replay 走这条路; 实测 \(r3) → \(r4))")

        // 旧写法（视图比 `[ChatMessage]`）在 revision 不存在时也得被识别：这里只钉住
        // 触发值确实变了；视图侧由 run.sh 的源码门挡回深比较。
        check(r1 != r0 && r2 != r1 && r3 != r2 && r4 != r3,
              "T-MREV 四类写路径各自留下不同的版本值")
    }
}
