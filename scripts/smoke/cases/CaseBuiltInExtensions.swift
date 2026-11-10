//
//  CaseBuiltInExtensions.swift
//  内置扩展的**归属账**: 谁不可删 / 谁不给开关 / 面板那一行说得对不对。
//
//  为什么值得单独一组断言（2026-11-10 boss 问"mangox-computer.ts 是内置在代码中吗"时查出来的）:
//    · `mangox-computer.ts` 一直是**每次 spawn 自动落盘**的, 却没登记进 `builtInNames`
//      ⇒ 面板给它一个**删除按钮**(点一下下次 spawn 又回来 = 打地鼠);
//    · 更坏的是它拿到了一个**按不动的启停开关** —— 它的挂载走
//      `extensionArguments(computerExtensionPath:)` 那条独立参数, **不看** `enabled` 列表
//      ⇒ 关掉开关扩展照挂。一条会撒谎的开关比没有开关更坏。
//  这两条都编译得过、跑起来也没有任何报错, 只有在面板上被人点一下才看得见。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseBuiltInExtensions() async {
        print("== T-EXT-BUILTIN 内置扩展的归属账 (不可删 / 不给开关 / 面板那一行) ==")

        // MARK: ① 名单本身
        //  判据不是"这几个名字看着对", 而是**谁会被 MangoX 自己写进托管目录**谁就必须在这里 ——
        //  源码级那条同源对账在 `run.sh` ③x（拿 `PiRpcTransport.swift` 里的 `mangox-*.ts` 字面量当输入）。
        let selfManaged = ["mangox-approval", "mangox-codemode", "mangox-dream",
                           "mangox-web-search", "mangox-computer"]
        for name in selfManaged {
            check(ExtensionItem.builtInNames.contains(name),
                  "T-EXT-BUILTIN \(name) 算自带 ⇒ 不可删除")
        }
        check(!ExtensionItem.builtInNames.contains("my-third-party-ext"),
              "T-EXT-BUILTIN 上面那几条不能恒真: 第三方扩展**不**算自带"
              + " (算进去就意味着用户永远删不掉自己导入的东西)")

        // MARK: ② 可删 / 可停用是**两件事**, 别合回去
        for name in ["mangox-approval", "mangox-codemode", "mangox-dream", "mangox-computer"] {
            check(ExtensionItem.unswitchableNames.contains(name),
                  "T-EXT-BUILTIN \(name) 不给启停开关 (它的挂载不由面板那个开关决定)")
        }
        check(!ExtensionItem.unswitchableNames.contains("mangox-web-search"),
              "T-EXT-BUILTIN 反例: web-search **必须能停用** —— 塞进 unswitchableNames 就是"
              + "\"标记比事实说得多\" (面板会说不许停, 而代码其实允许)")

        // MARK: ②b 挂载侧的同一条账: 自管的这些**不许混进业务列表**
        //  漏一个的后果不是"多挂一次也没事" —— 同一次 spawn 里 `--extension` 会**传两次**
        //  (一次来自 enabled 列表, 一次来自它自己那条轴参数) ⇒ 工具注册两遍。
        //  2026-11-10 实测就漏了 computer: 它在面板里是"开着"的, 于是一路混进了业务列表。
        //  ⚠️ 这一格把五个自管扩展**分成两类**, 别一刀切:
        //    · approval / codemode / dream / computer —— 由**轴**决定挂不挂(恒挂 / 档位 / fire /
        //      作用域), 必须从业务列表里**滤掉**, 否则同一次 spawn 传两遍;
        //    · web-search —— 反过来, 它**就该留在业务列表里**(它真的受面板开关控制、由 key 决定
        //      挂不挂), 把它也滤掉就等于让那颗开关又变成摆设。
        let axisDriven = ["mangox-approval", "mangox-codemode", "mangox-dream", "mangox-computer"]
        let mixed = axisDriven.map { "/x/" + $0 + ".ts" }
            + ["/x/mangox-web-search.ts", "/x/user-imported.ts"]
        let kept = PiRpcTransport.businessExtensionPaths(mixed)
        check(kept == ["/x/mangox-web-search.ts", "/x/user-imported.ts"],
              "T-EXT-BUILTIN 轴: 由轴决定的那四个必须从业务列表里滤掉, 而 web-search 与用户"
              + "导入的必须留着 (实测留下来的 \(kept)) —— 前者留着就是传两遍, 后者滤掉就是开关变摆设")

        // MARK: ③ 工具名表与内嵌源码**同源**
        //  面板靠这张表在那一行下面展开工具名; 名字漂了 → 展开的是不存在的工具(或什么都不展开),
        //  两种都零红灯。
        let computerTools = ExtensionItem.builtInToolNames["mangox-computer"] ?? []
        check(computerTools == PiRpcTransport.computerToolNames,
              "T-EXT-BUILTIN 面板的工具名表 == PiRpcTransport.computerToolNames"
              + " (实测 \(computerTools) vs \(PiRpcTransport.computerToolNames))")
        check(!computerTools.isEmpty
              && computerTools.allSatisfy { PiRpcTransport.computerExtensionSource.contains("name: \"\($0)\"") },
              "T-EXT-BUILTIN 同源: 每个名字都能在扩展源码里找到 `name: \"…\"`"
              + " (实测 \(computerTools))")

        // MARK: ④ 面板行为 —— 全走夹具目录, 一个字节都不碰 ~/.mangox
        //  ⚠️ 把 `mangox-computer.ts` 落到夹具里再扫: 这一行**只有 spawn 过才会出现在磁盘上**
        //     (它不像 web-search 那样在重扫时无条件落地), 所以不先写就不会有那一行。
        let dir = fixtureDir("ext-builtin")
        let mock = MockTransport()
        let store = ChatStore(transport: mock, dbPath: dir + "/a.db",
                              managedExtensionsDir: dir + "/ext",
                              modelKeyStore: InMemoryModelKeyStore())
        store.mailbox.stopScheduler()
        let computerPath = PiRpcTransport.ensureComputerExtensionFile(dir: dir + "/ext")
        store.scanExtensions()

        let row = store.extensions.first { $0.name == "mangox-computer" }
        check(row != nil,
              "T-EXT-BUILTIN 面板: 磁盘上有 `mangox-computer.ts` ⇒ 必须列出那一行"
              + " (实测 \(store.extensions.map(\.name)))")
        check(row?.isBuiltIn == true,
              "T-EXT-BUILTIN 面板: 那一行算**自带** (漏了 ⇒ 面板给删除按钮, 而它下次 spawn 又写回来)")
        check(row?.toolNames.count == computerTools.count,
              "T-EXT-BUILTIN 面板: 工具名跟着行下来 (实测 \(row?.toolNames ?? []))")
        check(row?.isOnDemand == false,
              "T-EXT-BUILTIN 面板: computer **不是**按需挂载 —— 挂它不给\"按需加载\"那颗胶囊"
              + " (它的挂载条件是作用域, 与 dream 的双闸门不是一回事)")

        // MARK: ⑤ 删除守卫: 删不掉, 而且文件还在
        if let row {
            let before = store.extensions.count
            store.deleteExtension(row)
            check(store.extensions.count == before,
                  "T-EXT-BUILTIN 守卫: 自带项**删不掉** —— 少了这道, 点删除就是点一下又回来")
            check(FileManager.default.fileExists(atPath: computerPath),
                  "T-EXT-BUILTIN 守卫: `.ts` 还在磁盘上 (实测 \(computerPath))")
        } else {
            check(false, "T-EXT-BUILTIN 守卫: 夹具里必须真的存在那一行 (否则上面几条是空转的假绿)")
        }

        // MARK: ⑥ 开关守卫 —— 本轮的核心, 也是"为什么它必须不可停用"的证据
        //  两半必须同时成立:
        //    ① `extensionArguments` 在 `enabled` **为空**时照样把 computer 那条路径拼进去 ——
        //       这是根因, 而且是**纯函数**可断言的(不必猜到面板点下去会怎样);
        //    ② 对它 toggle 之后那一行**还是开着** —— 开关按不动, 所以"不给开关"才是诚实的。
        //  ⚠️ 别拿"它的路径在不在 `-e` 列表里"当根因 —— 那取决于 `businessExtensionPaths` 有没有
        //     把它滤掉(见 ②b), 是**另一条**账。这里只认"挂载压根不看 enabled"这个根因。
        let soloArgs = PiRpcTransport.extensionArguments(
            hostedExtensionPath: "/tmp/hosted.ts",
            codemodeExtensionPath: nil,
            dreamExtensionPath: nil,
            computerExtensionPath: "/tmp/mangox-computer.ts",
            enabled: [])
        check(soloArgs.contains("/tmp/mangox-computer.ts"),
              "T-EXT-BUILTIN 开关 ①: `enabled` 为空时 computer 那条路径**照样**拼进 -e"
              + " (实测 \(soloArgs)) —— 所以面板那个开关管不到它")
        check(soloArgs.filter { $0 == "/tmp/mangox-computer.ts" }.count == 1,
              "T-EXT-BUILTIN 开关 ①: 传进来的那条只出现**一次** (重复挂载会让工具注册两遍)")
        if let row {
            store.toggleExtension(row)
            let after = store.extensions.first { $0.name == "mangox-computer" }
            check(after?.enabled == true,
                  "T-EXT-BUILTIN 开关 ②: 对它 toggle 之后仍是开着 —— 面板那个开关对它无效,"
                  + " 所以**不给**开关才是诚实的")
            // 反例方向: 同一个 toggle 对**可停用**的项必须真的生效, 否则上面那条是"toggle 坏了"的假绿。
            if let ws = store.extensions.first(where: { $0.name == "mangox-web-search" }) {
                store.toggleExtension(ws)
                check(store.extensions.first { $0.name == "mangox-web-search" }?.enabled == false,
                      "T-EXT-BUILTIN 开关 ③: 反例 —— 对 web-search toggle **真的关掉**"
                      + " (证明上面那条不是\"toggle 整个坏了\")")
            }
        }
    }
}
