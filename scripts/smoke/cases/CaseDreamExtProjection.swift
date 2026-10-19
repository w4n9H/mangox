//
//  caseDreamExtProjection —— dream 扩展文件投影: TS 多行字符串缩进 + 列表合成项
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家, 未改一行逻辑）。
//  原位替换为 `await caseDreamExtProjection()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseDreamExtProjection() async {
        // ① 源码常量: 那段 TS 从函数体提到了类型级 `static let`, 而 Swift 多行字符串的缩进是按
        //    **闭合定界符那一行**剥的。定界符与内容行缩进不一致 ⇒ 每行**留下前导空格** —— 写出去
        //    的扩展照样"看着没事", 只是 `import` 不再顶格。
        let extLines = PiRpcTransport.dreamExtensionSource.split(separator: "\n",
                                                                omittingEmptySubsequences: false)
        let extFirst = extLines.first.map(String.init) ?? ""
        check(extFirst == "// Auto-deployed by MangoX (P15.3). Records dream's note proposals into a spool file.",
              "P15.7 常量: 多行字符串的缩进**剥干净了** —— 首行无前导空白（实测 [\(extFirst.prefix(22))…])")
        check(PiRpcTransport.dreamExtensionSource.contains("\n    pi.registerTool({"),
              "P15.7 常量: 正文内部的 4 空格缩进**原样保留**（剥多了或剥少了 ⇒ 这里红）")

        // ② 工具名表与源码**同源** —— 两张表分头维护迟早对不上, 这正是 P15.6b 那条判据的同族。
        check(!PiRpcTransport.dreamToolNames.isEmpty
              && PiRpcTransport.dreamToolNames.allSatisfy {
                  PiRpcTransport.dreamExtensionSource.contains("name: \"\($0)\"")
              },
              "P15.7 同源: `dreamToolNames` 每个名字都能在源码里找到 `name: \"…\"`"
              + "（改了源码忘改表 ⇒ 红; 实测 \(PiRpcTransport.dreamToolNames))")

        // ②b P17 前置修复 (2026-10-15): 指纹由**扩展**算, 不问模型。
        //
        // 为什么这里只能断言"源码形态"而不是"真跑一次": 那段 TS 是**扩展**, 只在那次
        // fire 里由 pi 加载 —— 本段不起子进程（冒烟没有这个先例, 也不该为一条判据引入）。
        // 所以能抓的是**它确实这么写了**, 抓不到"pi 真的调用了它"。这一格的价值在于:
        // 谁把这三样删掉/换成别的算法, **立刻红**（而不是等到某天采纳被拒才发现）。
        let extSrc = PiRpcTransport.dreamExtensionSource
        check(extSrc.contains("createHash(\"sha256\")")
              && extSrc.contains("readFileSync(path)")
              && extSrc.contains(".digest(\"hex\")"),
              "P17 指纹: 扩展自己算 sha256 —— 三条缺一不可: 算法 createHash(\"sha256\") / "
              + "**输入是文件字节** readFileSync(path) / 输出小写 hex digest(\"hex\")")
        check(!extSrc.contains("params.base_hash || \"\""),
              "P17 指纹 反例: **不再**把模型给的值落进 spool（退回 `params.base_hash || \"\"` "
              + "⇒ 立刻红。那正是让 merge / replace 的采纳 100% 失败的写法）")
        check(!extSrc.contains("also need base_hash"),
              "P17 文案: 工具描述**不再**要求模型填 base_hash（这句会进模型 prompt 的字节）")
        check(SchedulerService.dreamPrompt.contains("不要填 base_hash"),
              "P17 文案同源: fire 指令那侧也改了 —— 两处是**同一件事的两种说法**,"
              + " 只改一处 ⇒ 另一半还在要模型算一个它算不出的值（这条就是抓那个的）")

        // ③ 磁盘上**没有**这个文件时, 列表里**要有**这一条（这就是"找得到")。
        let peDir = fixtureDir("ext-proj")
        let pe = ChatStore(transport: MockTransport(), dbPath: peDir + "/p.db",
                           managedExtensionsDir: peDir + "/ext")
        pe.mailbox.stopScheduler()
        pe.scanExtensions()
        let peDreams = pe.extensions.filter { $0.name == "mangox-dream" }
        check(peDreams.count == 1,
              "P15.7 投影: 磁盘上没有 mangox-dream.ts ⇒ 列表里**恰好一条**（实测 \(peDreams.count))")
        check(peDreams.first?.isSynthetic == true && peDreams.first?.isBuiltIn == true
              && peDreams.first?.isOnDemand == true
              && peDreams.first?.toolNames == PiRpcTransport.dreamToolNames,
              "P15.7 投影: 四个字段都要对 —— isSynthetic / isBuiltIn / isOnDemand / toolNames")

        // ④ 源码预览必须走常量: 磁盘上根本没这个文件, 真去读只会拿到"无法读取源码"。
        let peSrc = peDreams.first.map { pe.extensionSource($0) } ?? ""
        check(peSrc.contains("note_proposal") && !peSrc.contains("无法读取源码"),
              "P15.7 预览: 投影项的源码来自**常量**（去掉那个分支 ⇒ 这里拿到\"无法读取源码\")")

        // ⑥ P17: 第四类动作 `delete` 必须**真的在扩展源码里** —— 模型看不到的词, 它提不出来。
        let dmSrc = PiRpcTransport.dreamExtensionSource
        check(dmSrc.contains("Type.Literal(\"delete\")"),
              "P17 扩展: `delete` 进了 kind 的 enum —— 契约 token 是**两边一起改**的, 少一边模型就提不出删除")
        check(dmSrc.contains("Omit it for delete"),
              "P17 扩展: content 对 delete 变可选 —— 还是必填的话, 模型只能为一次删除编一段正文出来")

        // ⑤ 反例（本段最值钱的一格）: 磁盘上**有**真文件时**不许**重复投影。
        //    dream 刚跑过就是这个状态 —— 不去重的话面板会出现两条同名项, 一条能看源码一条不能。
        let prDir = fixtureDir("ext-real")
        let prExt = prDir + "/ext"
        try? FileManager.default.createDirectory(atPath: prExt, withIntermediateDirectories: true)
        try? PiRpcTransport.dreamExtensionSource.write(toFile: prExt + "/mangox-dream.ts",
                                                      atomically: true, encoding: .utf8)
        // approval 也要放进同一个夹具 —— 下面那条"approval 恒挂"若对着**空数组**断言会恒真(假绿)。
        try? "// stub".write(toFile: prExt + "/mangox-approval.ts",
                            atomically: true, encoding: .utf8)
        let pr = ChatStore(transport: MockTransport(), dbPath: prDir + "/r.db",
                           managedExtensionsDir: prExt)
        pr.mailbox.stopScheduler()
        pr.scanExtensions()
        let prDreams = pr.extensions.filter { $0.name == "mangox-dream" }
        check(prDreams.count == 1,
              "P15.7 判重 反例: 磁盘上**有**真文件时仍然只有一条（删掉那条判重 ⇒ 立刻变 2)")
        check(prDreams.first?.isSynthetic == false && prDreams.first?.isBuiltIn == true,
              "P15.7 判重: 此时留下的是**磁盘上那条**, 且它照样算内置（`builtInNames` 认得这个名字）")
        check(prDreams.first?.isOnDemand == true
              && prDreams.first?.toolNames == PiRpcTransport.dreamToolNames,
              "P15.7 判重: 磁盘那条**也要**带 isOnDemand 与工具名 —— 否则 dream 跑过一次之后,"
              + " 那一项会**从\"按需\"变回\"恒开开关\"**（同一个东西两种说法, 且换脸前后都是绿的）")
        let prApprovals = pr.extensions.filter { $0.name == "mangox-approval" }
        check(prApprovals.count == 1 && prApprovals.allSatisfy { $0.isBuiltIn && !$0.isOnDemand },
              "P15.7 分派: approval 是**恒挂**内置 ⇒ isOnDemand 必须为 false"
              + "（按 isBuiltIn 一刀切 ⇒ 这里红; 夹具里 approval 必须真在, 空数组的 allSatisfy 恒真)")

        // ⑥ 投影项不可停用、不可删除 —— 守卫在 ChatStore 域层, 逐条断言。
        if let pd = peDreams.first {
            let before = pe.extensions.count
            pe.toggleExtension(pd)
            pe.deleteExtension(pd)
            check(pe.extensions.contains(where: { $0.name == "mangox-dream" })
                  && pe.extensions.count == before,
                  "P15.7 守卫: 投影项**停不掉也删不掉**（内置名单挡住）—— 面板里它永远在")
        }
    }
}
