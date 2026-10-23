//
//  caseWorkspaceRescan —— 工作区重扫: FileNode 身份合并 (展开态/选中态不丢)
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家, 未改一行逻辑）。
//  原位替换为 `await caseWorkspaceRescan()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseWorkspaceRescan() async {
        let ws15Root = fixtureDir("p15ws")
        let fm15 = FileManager.default
        try? fm15.createDirectory(atPath: ws15Root + "/A", withIntermediateDirectories: true)
        try? fm15.createDirectory(atPath: ws15Root + "/B", withIntermediateDirectories: true)
        try? fm15.createDirectory(atPath: ws15Root + "/C", withIntermediateDirectories: true)
        try? "a".write(toFile: ws15Root + "/A/shared.txt", atomically: true, encoding: .utf8)
        try? "b".write(toFile: ws15Root + "/B/shared.txt", atomically: true, encoding: .utf8)
        try? "c".write(toFile: ws15Root + "/C/only.txt", atomically: true, encoding: .utf8)
        try? "t".write(toFile: ws15Root + "/top.txt", atomically: true, encoding: .utf8)

        // 首扫 (旧树为空, 等价于"刚打开项目"): 无旧树可借, 全用新身份
        let first15 = ChatStore.mergeRescan(root: ws15Root, old: [])
        check(Set(first15.map(\.name)) == ["A", "B", "C", "top.txt"],
              "P14 合并: 首扫按磁盘产出 A/B/C/top.txt")

        // 模拟用户: 展开了 A / B 并把子级加载出来; C 从没展开过 (childrenLoaded=false)
        let loaded15: [FileNode] = first15.map { node in
            guard node.isFolder, node.name != "C" else { return node }
            let kids = WorkspaceScanner.scanDirectory(ws15Root + "/" + node.name, depth: node.depth + 1)
            return FileNode(id: node.id, name: node.name, isFolder: true, depth: node.depth,
                            isExpanded: true, childrenLoaded: true, children: kids)
        }
        let oldA15 = loaded15.first { $0.name == "A" }
        let oldB15 = loaded15.first { $0.name == "B" }
        let oldSharedA15 = oldA15?.children.first { $0.name == "shared.txt" }?.id
        let oldSharedB15 = oldB15?.children.first { $0.name == "shared.txt" }?.id
        check(oldSharedA15 != nil && oldSharedB15 != nil && oldSharedA15 != oldSharedB15,
              "P14 合并 前置: A/B 各有一份同名 shared.txt 且身份本就不同")

        // 磁盘变动: A 里新增一个文件 / 删掉 top.txt
        try? "n".write(toFile: ws15Root + "/A/added.txt", atomically: true, encoding: .utf8)
        try? fm15.removeItem(atPath: ws15Root + "/top.txt")

        let second15 = ChatStore.mergeRescan(root: ws15Root, old: loaded15)
        let newA15 = second15.first { $0.name == "A" }
        let newB15 = second15.first { $0.name == "B" }
        let newC15 = second15.first { $0.name == "C" }

        check(newA15?.id == oldA15?.id && newB15?.id == oldB15?.id,
              "P14 合并: 目录身份跨重扫保持 (id 复用 ⇒ 展开态不跳)")
        check(newA15?.isExpanded == true && newB15?.isExpanded == true,
              "P14 合并: 展开态被搬过来 (这条才是「不收起用户目录」的判据)")
        check(newC15?.isExpanded == false,
              "P14 合并: 原本没展开的 C 不会被顺手展开")
        check(newA15?.children.contains { $0.name == "added.txt" } == true,
              "P14 合并: A (旧树已加载) 里的新增文件出现 —— 重扫真的递归进了已加载目录")
        check(newC15?.childrenLoaded == false && newC15?.children.isEmpty == true,
              "P14 合并: 未加载过的目录保持未加载 (否则每次重扫退化成全量递归)")
        check(second15.contains { $0.name == "top.txt" } == false,
              "P14 合并: 磁盘上已删的 top.txt 从树里消失")
        check(newA15?.children.first { $0.name == "shared.txt" }?.id == oldSharedA15
              && newB15?.children.first { $0.name == "shared.txt" }?.id == oldSharedB15,
              "P14 合并: 同名文件各归各的父目录, 身份不串 (判据含父路径)")

        // 反例: 同级「同名的文件」与「同名的目录」不许互借身份。
        // 磁盘上造不出这种局面 (同名只能存在一个), 所以直接喂一棵手搓的旧树:
        // 那个同名"文件"是**展开着的**, 于是匹配键一旦漏掉 `isFolder`,
        // 目录 A 会连它的展开态一起继承 —— 两条断言同时红 (真实症状: 张冠李戴)。
        let decoyID15 = UUID()
        let decoy15 = [FileNode(id: decoyID15, name: "A", isFolder: false, depth: 0,
                                isExpanded: true)]
        let typeKeyed15 = ChatStore.mergeRescan(root: ws15Root, old: decoy15)
        check(typeKeyed15.first { $0.name == "A" }?.id != decoyID15,
              "P14 合并 反例: 旧树里的同名**文件**不被同名**目录**借身份 (匹配键含 isFolder)")
        check(typeKeyed15.first { $0.name == "A" }?.isExpanded == false,
              "P14 合并 反例: 借错身份会连带借走展开态 —— 来自文件节点的 true 不许落到目录上")

        // ---- P14: 命令 → 视图的一次性信号 (序号自增; 视图只观察, 不回写清零) ----
        let ws15Dir = fixtureDir("p15cmd")
        let ws15Store = ChatStore(transport: MockTransport(), dbPath: ws15Dir + "/p15.db",
                                  managedExtensionsDir: ws15Dir + "/ext")
        check(!ws15Store.canUseWorkspace, "P14 信号 前置: 无项目会话时工作区不可用")

        let focusTick0 = ws15Store.workspaceFilterFocusTick
        ws15Store.focusWorkspaceFilter()
        check(ws15Store.workspaceFilterFocusTick == focusTick0 && !ws15Store.workspaceVisible,
              "P14 信号 反例: 没有工作目录时 ⌘F 不发聚焦信号 (否则焦点被送进不存在的视图)")

        let refreshTick0 = ws15Store.workspaceRefreshTick
        ws15Store.refreshWorkspace()
        check(ws15Store.workspaceRefreshTick == refreshTick0 + 1,
              "P14 信号: ⌘R 每次自增 (不是置真 —— 否则连按两次只生效一次)")
        check(ws15Store.fileTree.isEmpty,
              "P14 信号: 无项目时 ⌘R 不动文件树 (guard 住, 不为空说明在扫空路径)")

        // 挂上一个带 path 的项目 ⇒ 工作区可用
        let ws15ProjectID = UUID()
        ws15Store.projects = [ProjectGroup(id: ws15ProjectID, title: "T15", path: ws15Root,
                                           items: [ConversationItem(title: "c15")])]
        ws15Store.selectedProjectId = ws15ProjectID
        check(ws15Store.canUseWorkspace && !ws15Store.fileTree.isEmpty,
              "P14 信号: 挂上带 path 的项目后工作区可用且文件树已扫出")

        ws15Store.workspaceVisible = false
        let focusTick1 = ws15Store.workspaceFilterFocusTick
        ws15Store.focusWorkspaceFilter()
        check(ws15Store.workspaceVisible && ws15Store.workspaceFilterFocusTick == focusTick1 + 1,
              "P14 信号: 有工作目录时 ⌘F 既打开工作区、又发一次聚焦信号")

        // 最后这条是"合并 vs 整体替换"的喉咙: 重扫后顶层身份必须一模一样。
        let idsBefore15 = ws15Store.fileTree.map(\.id)
        check(!idsBefore15.isEmpty, "P14 信号 前置: 顶层身份快照非空")
        ws15Store.refreshWorkspace()
        check(ws15Store.fileTree.map(\.id) == idsBefore15,
              "P14 信号: ⌘R 重扫后顶层节点身份不变 (走合并; 回退成整体替换 ⇒ 这里立刻红)")

        // ---- 树上的"目录有改动"标点由**预计算**的目录集驱动 ----
        // 原先每个目录行自己去扫全部 changed 判前缀 (O(目录 × 改动)); 现在一次算好。
        // 这笔账的语义要害是**每一级祖先**: `a/b/c.swift` 变动时 a 和 a/b 都得亮点,
        // 只点亮直接父级 ⇒ 折叠着的 a 看起来干净, 展开才发现在下层 (安静的错误)。
        check(workspaceFolderPrefixes(of: ["a/b/c.swift"]) == ["a", "a/b"],
              "目录改动集: 每个文件的**每一级祖先**都进集合, 不只直接父级")
        check(workspaceFolderPrefixes(of: ["top.txt"]).isEmpty,
              "目录改动集: 根下的文件不产生任何目录 (顶层没有可以点的目录行)")
        check(workspaceFolderPrefixes(of: ["a/b/c.swift", "a/b/d.swift", "a/x"]) == ["a", "a/b"],
              "目录改动集: 同一目录的多个文件不重复计 (Set 去重, 计数不会虚高)")
    }
}
