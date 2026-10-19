//
//  caseDreamPromptBuild —— dream 提示词组装: 有界摘要 + 出厂指令
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家 + dir→fixturesRoot 等价替换）。
//  原位替换为 `await caseDreamPromptBuild()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseDreamPromptBuild() async {
        let drDir = fixtureDir("p158")
        let dr = ChatStore(transport: MockTransport(), dbPath: drDir + "/p158.db",
                           managedExtensionsDir: drDir + "/ext")
        dr.mailbox.stopScheduler()
        // ⚠️ **实例级**重定向（优先级高于 `:184` 那个进程级）: 后面几节会往进程级的
        //    `<noteTmp>/global` 里写笔记, 不隔离的话"两个根都空"就随**节的执行顺序**飘。
        dr.knowledge.noteRootOverride = drDir + "/notes"
        let drProjPath = drDir + "/proj"
        try? FileManager.default.createDirectory(atPath: drProjPath,
                                                 withIntermediateDirectories: true)
        dr.addProject(title: "p158 项目", path: drProjPath)
        // 项目里放一条会话 —— 归属表读的就是 `ProjectGroup.items`（平铺 `chats` 天然不在其列）。
        let drConv = ConversationItem(title: "P158 会话")
        if let i = dr.projects.firstIndex(where: { $0.path == drProjPath }) {
            dr.projects[i].items.append(drConv)
        }
        // 根路径**走 `resolvedNoteDir`**（与生产同源）—— 手拼字符串就是往用户真实目录里写。
        let drProjRoot = dr.knowledge.resolvedNoteDir(projectPath: drProjPath)
        let drGlobalRoot = dr.knowledge.resolvedNoteDir(projectPath: nil)
        let drLabel = KnowledgeBase.noteRootLabel(projectTitle: "p158 项目")

        // —— ① 空根进段 ——
        let drSeg = dr.knowledge.knowledgeIndexSegment()
        check(drSeg != nil,
              "P15.8 ①: 根**全空**时索引段仍然存在 —— 这正是缺陷现场"
              + "（旧规则下它整个是 nil, dream 的 prompt 就只剩「写到全局」那一条支路）")
        let drText = drSeg?.text ?? ""
        check(drText.contains(drGlobalRoot) && drText.contains(drProjRoot),
              "P15.8 ①: 两个根的**路径都在段里**（空根只给坐标 —— 归属 = 位置, 没坐标就没落点）")
        let drEmptyLines = drText.components(separatedBy: KnowledgeBaseScan.emptyRootLine).count - 1
        check(drEmptyLines == 2,
              "P15.8 ①: 两个空根各一行「\(KnowledgeBaseScan.emptyRootLine)」(实测 \(drEmptyLines) 行)")
        check(drText.contains("[笔记] \(drLabel)\n路径: \(drProjRoot)\n"
                              + "说明: \(KnowledgeBase.noteProjectDescription)\n"
                              + KnowledgeBaseScan.emptyRootLine),
              "P15.8 ①: 空根的块形状与有文件的块**一致**（3 行头 + 1 行替身, 不是另一种结构）")
        check(drSeg?.bases.count == 2 && drSeg?.bases.allSatisfy { $0.chars > 0 } == true,
              "P15.8 ①: 空根**也算进 `bases`** —— 它真的占了那么多预算, 整段缺席时的点名就得算上它")

        // —— ② 摘要段头带归属, 且与段里那个根的名字**逐字同源** ——
        let drNow = Date()
        let drLabels = SchedulerService.sessionRootLabels(store: dr)
        check(drLabels[drConv.id] == drLabel,
              "P15.8 ②: 项目会话的归属根名 = 那个根的 displayName (实测 \(drLabels[drConv.id] ?? "nil"))")
        check(dr.knowledge.noteKnowledgeBases.contains {
                  $0.id.hasPrefix(KnowledgeBase.noteProjectPrefix) && $0.displayName == drLabel
              },
              "P15.8 ② 同源: 归属名与 `[笔记]` 段里根的第一行**逐字相同**"
              + "（这条打的是\"有人绕过 `noteRootLabel` 自己拼\" —— 只改那个函数的格式抓不到,"
              + " 两处同源**由构造保证**; 而名字对不上 ⇒ 模型找不到根 ⇒ 回落全局, 且零红灯）")
        let drDigest = SchedulerService.sessionDigest(
            [SchedulerService.DreamDigestInput(
                id: drConv.id, title: drConv.title, updatedAt: drNow,
                messages: [ChatMessage(role: .user, content: .text("随便说点什么"))],
                noteRootLabel: drLabels[drConv.id] ?? KnowledgeBase.noteGlobalLabel)],
            since: drNow.addingTimeInterval(-3600))
        check(drDigest.contains("· 归属 \(drLabel)"),
              "P15.8 ②: 段头印出归属 (实测 \(drDigest.prefix(72)))")

        // —— ③ 三种"没有项目根"的情形必须落空（调用点回落全局标签）——
        //    落空**不是错误**: 它们本来就没有可写的项目根。
        let drFlat = ConversationItem(title: "平铺会话")
        dr.chats.append(drFlat)
        let drNoPath = ConversationItem(title: "无 path 项目的会话")
        // `addProject` 的 `path` 是非可选 `String`（`ProjectGroup.path` 才是可选的）⇒ 用空串表示
        // "没有目录"。对 `noteKnowledgeBases` 而言两者等价: 它判的是 `!path.isEmpty`。
        dr.addProject(title: "p158 无目录", path: "")
        if let i = dr.projects.firstIndex(where: { $0.title == "p158 无目录" }) {
            dr.projects[i].items.append(drNoPath)
        }
        let drLabels2 = SchedulerService.sessionRootLabels(store: dr)
        check(drLabels2[drFlat.id] == nil && drLabels2[drNoPath.id] == nil,
              "P15.8 ③: **平铺会话**与**没有 path 的项目**都拿不到项目根")
        check(drLabels2[drConv.id] == drLabel,
              "P15.8 ③ 反向: 有 path 的那个项目仍然拿得到（否则上面那条是空转绿）")
        // 停用项目根 ⇒ 归属回落到全局: 被停用的根**不在段里**, 指向它就是指向一个不存在的落点。
        let drProjRootId = dr.knowledge.noteKnowledgeBases.first { $0.path == drProjRoot }?.id ?? ""
        dr.knowledge.fixedRootDisabled.insert(drProjRootId)
        check(SchedulerService.sessionRootLabels(store: dr)[drConv.id] == nil,
              "P15.8 ③: 项目根被**停用** ⇒ 归属落空（那个根已经不在 [笔记] 段里了）")
        dr.knowledge.fixedRootDisabled.remove(drProjRootId)

        // —— ④ 守卫 16 的本意仍在, 只是触发条件收窄了 ——
        let drAllIds = dr.knowledge.noteKnowledgeBases.map(\.id)
        dr.knowledge.fixedRootDisabled.formUnion(drAllIds)
        check(dr.knowledge.knowledgeIndexSegment() == nil,
              "P15.8 ④: **所有根都停用** ⇒ 索引段整段消失（这是 `nil` 现在唯一的含义,"
              + " 也正是 `dreamPrompt` 里「没有 [笔记] 段 ⇒ 直接结束」那一支的判据）")
        dr.knowledge.fixedRootDisabled.subtract(drAllIds)
        check(dr.knowledge.knowledgeIndexSegment() != nil, "P15.8 ④: 恢复启用 ⇒ 段回来（开关可逆）")

        // —— ⑤ 指令自身的回归门（与 P15.6 ⑨ 同形）——
        check(SchedulerService.dreamPrompt.contains("项目优先")
                && SchedulerService.dreamPrompt.contains("明确跨项目"),
              "P15.8 ⑤: 归属规则写在指令里（删掉那一块 ⇒ 立刻红）")
        check(!SchedulerService.dreamPrompt.contains("/.mangox/note"),
              "P15.8 ⑤: 指令里**不再有**任何硬编码笔记路径 —— 原来那处指的正是**全局根**,"
              + " 它曾是全文唯一出现具体路径的地方, 也就是最强的反向锚点")
    }
}
