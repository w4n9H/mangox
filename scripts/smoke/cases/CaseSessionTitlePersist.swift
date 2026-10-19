//
//  CaseSessionTitlePersist.swift
//  会话标题的**落库往返**: 项目区 + 平铺区两条路径, 重启后名字都必须还在。
//
//  这套断言存在的理由（2026-10-19, boss 报「每次重开 App, project 下的会话都变回 <New chat>,
//  输入 input 后又更新」）: 根因是 `renameConversation` 在**项目分支 `return` 出函数**,
//  把出口那行 `renameSession` 一起跳过了 —— 内存里改得对、库里永远停在默认标题,
//  重启回读自然是 `New chat`; 而"再输入一次又更新"是因为那时内存还是默认标题,
//  `autoTitleIfNeeded` 又拿最新那条消息重新命了一次名（标题于是每次都漂）。
//
//  ⚠️ **当时的门为什么全绿**: T20 只断言 `store.chats` —— 那恰好是**唯一**会落库的分支;
//  项目分支从来没被断言过, 而且所有断言都只读内存、不重建 store。**只读内存的断言对这个
//  缺陷恒绿**（内存那半从来没错过）。⇒ 这里必须是「真 db 文件 + 重建 store 再回读」。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSessionTitlePersist() async {
        print("== T-TITLEPERSIST 会话标题落库往返 ==")

        let tpDir = fixtureDir("titlepersist")
        let tpDb = tpDir + "/title.db"
        let tpProjPath = tpDir + "/proj"
        try? FileManager.default.createDirectory(atPath: tpProjPath,
                                                 withIntermediateDirectories: true)

        let store = ChatStore(transport: MockTransport(), dbPath: tpDb,
                              managedExtensionsDir: tpDir + "/ext")
        store.mailbox.stopScheduler()

        // ---- ① 项目会话: 自动命名 ⇒ 重建 ⇒ 名字必须还在 ----
        store.addProject(title: "TP 项目", path: tpProjPath)
        guard store.projects.count == 1,
              let pid = store.projects.first?.id,
              let projSid = store.projects.first?.items.first?.id else {
            check(false, "T-TITLEPERSIST ① 建项目即在其下建一个会话")
            return
        }
        check(store.projects[0].items[0].title == ChatStore.defaultConversationTitle,
              "T-TITLEPERSIST ① 项目会话初始是默认标题")

        store.autoTitleIfNeeded(sid: projSid, text: "项目里的第一条很长的消息")
        check(store.projects[0].items[0].title == "项目里的第一条很长的",
              "T-TITLEPERSIST ① 项目会话首条消息自动命名 (内存这一半)")

        // 空/纯空白不许把标题写没 (guard 在 `trimmed.isEmpty` 上)
        store.renameConversation(projSid, to: "   \n\t ")
        check(store.projects[0].items[0].title == "项目里的第一条很长的",
              "T-TITLEPERSIST ① 空白重命名被忽略 (不许把已有标题清成空)")

        // 重建 store = 走 loadProjects → loadItems, 与 App 启动完全同一条路
        let reborn = ChatStore(transport: MockTransport(), dbPath: tpDb,
                               managedExtensionsDir: tpDir + "/ext")
        reborn.mailbox.stopScheduler()
        check(reborn.projects.first?.id == pid,
              "T-TITLEPERSIST ① 重建后读到的是**同一个项目行** (否则下面的标题断言对错了靶)")
        let rebornTitle = reborn.projects.first?.items.first(where: { $0.id == projSid })?.title
        check(rebornTitle == "项目里的第一条很长的",
              "T-TITLEPERSIST ① **项目会话的标题重启后还在** —— 反例: 把项目分支的 `return` "
              + "加回去, 这里立刻回 `\(ChatStore.defaultConversationTitle)`"
              + " (实测 \(rebornTitle ?? "nil"))")

        // ---- ② 平铺区会话: 同一条往返 (原本就正确的那半, 钉住别被改坏) ----
        store.newConversation()
        guard let chatSid = store.selectedConversationId else {
            check(false, "T-TITLEPERSIST ② 建平铺会话")
            return
        }
        store.renameConversation(chatSid, to: "平铺区改名")
        let reborn2 = ChatStore(transport: MockTransport(), dbPath: tpDb,
                                managedExtensionsDir: tpDir + "/ext")
        reborn2.mailbox.stopScheduler()
        let rebornChatTitle = reborn2.chats.first(where: { $0.id == chatSid })?.title
        check(rebornChatTitle == "平铺区改名",
              "T-TITLEPERSIST ② 平铺会话的标题重启后还在 (实测 \(rebornChatTitle ?? "nil"))")

        // ---- ③ 落库的标题要能**反过来抑制**自动命名 (钉住"标题漂移") ----
        // 缺陷现场: 库里是 `New chat` ⇒ 每次重启后发一条消息就重新命名一次, 标题跟着最新消息漂。
        // 标题真落了库, 这里就必须一个字符都不动。
        reborn.autoTitleIfNeeded(sid: projSid, text: "重启之后另一条完全不同的消息")
        check(reborn.projects.first?.items.first(where: { $0.id == projSid })?.title
                == "项目里的第一条很长的",
              "T-TITLEPERSIST ③ 重启后不再被「首条消息」重命名 (标题不许跟着最新消息漂)")
    }
}
