//
//  WorkspaceView.swift
//  Workspace column (hidden by default).
//
//  工作区重设计 —— 结构从「一个滚动区塞四件事」改成**三个固定 tab**:
//
//      [项目名 · 分支 · 项数 · ⟳]      ← 恒在 (与 tab 无关)
//      [文件 | 改动 3 | 预览]          ← 一级导航, 文字 + 2px 底线
//      ─────────────────────────────
//      tab 内容
//
//  三条判据 (不是审美):
//   ① 「本会话改动」原来挂在文件树上方, 会话跑起来能长到二三十行, 把树挤到屏幕外 ——
//      而它恰恰是"这个会话动了什么"最该一眼看到的东西 ⇒ 升格成一级 tab。
//   ② 点文件原来是**替换整块面板** (树消失 + 出现「←」返回箭头), 现在是把内容送进
//      第三个 tab 并激活它 ⇒ 一步操作, 没有回程路要走。
//   ③ git 改动原来只能靠树上的 `M`/`A` 徽标反推 ⇒ 改动 tab 里有一张自己的清单。
//
//  本文件只留外壳: header / tab 条 / 过滤框 / 语言条 / 分发。
//  树 → `WorkspaceFileTree.swift` · 改动 → `WorkspaceChanges.swift` · 预览 → `FilePreviewView.swift`。
//

import AppKit
import SwiftUI

/// 工作区的一级导航。**顺序即渲染顺序**, 文件在最左 (默认)。
private enum WorkspaceTab: Hashable, CaseIterable, Identifiable {
    case files, changes, preview

    var id: Self { self }

    /// ⚠️ 每次现取词。**不许落进 `static let`** —— 那会冻结成启动时那门语言的词 (本地化坑 ⑨)。
    var title: String {
        switch self {
        case .files:   return L("文件")
        case .changes: return L("改动")
        case .preview: return L("预览")
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: ChatStore

    @State private var tab: WorkspaceTab = .files
    @State private var previewRelative: String? = nil
    @State private var gitStatus: WorkspaceGit.Status? = nil
    /// 「之下有 git 改动」的目录集 —— 一次算好, 树里直接查。见 `hasChangedInside`。
    @State private var changedFolders: Set<String> = []
    @State private var filterText: String = ""
    // 语言构成/文件总数走后台全量扫描 (懒加载树只含已展开部分, 不能作为统计源)
    @State private var langs: [WorkspaceStats.Lang] = []
    @State private var totalFiles: Int? = nil
    @State private var recentCommits: [WorkspaceGit.Commit] = []
    /// agent 触达集 (新→旧, 相对项目根) 及其派生集 —— 三者同源, 一次算好。
    /// 原先这三个值都是 computed: 每个 body 遍历全部 messages, 而打开工作区时 body 会被调
    /// 三次 (header / 树 / 改动区各一次) ⇒ 三遍。缓存键 = `root#messages.count`。
    @State private var touched: [String] = []
    @State private var touchedSet: Set<String> = []
    @State private var touchedFolders: Set<String> = []
    @State private var touchedKey: String = ""
    /// P14 ⌘F: 文件过滤框的焦点。菜单命令够不到视图 @State ⇒ 由 store 的 tick 转成事件驱动它。
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root = store.activeProjectPath {
                header
                tabBar
                content(root: root)
            } else {
                emptyState
            }
        }
        .task(id: store.activeProjectPath) {
            // 换项目 ⇒ 上一个项目的预览没有意义
            previewRelative = nil
            if tab == .preview { tab = .files }
            refreshTouched(root: store.activeProjectPath ?? "")
            reloadGit()
            reloadStats()
        }
        // P14 自动刷新: agent 每新触达一个文件就重扫一次 ——
        // 走合并式刷新, 所以展开的目录**保持展开** (整体替换会把用户的树收起来)。
        // ⚠️ 判据仍是「触达集真的变了」: 用户消息也会让 count 变, 但那不该触发重扫。
        .onChange(of: store.messages.count) { _, _ in
            let before = touched
            refreshTouched(root: store.activeProjectPath ?? "")
            guard touched != before else { return }
            store.refreshFileTree()
            reloadGit()
        }
        // P14 ⌘R: git 与统计是视图 @State, 命令层够不到 ⇒ 由 store 的序号转成这里能观察的事件。
        .onChange(of: store.workspaceRefreshTick) { _, _ in
            reloadGit()
            reloadStats()
        }
        // P14 ⌘F: 把焦点送进过滤框 (它住在「文件」tab 里)。
        .onChange(of: store.workspaceFilterFocusTick) { _, _ in
            tab = .files
            filterFocused = true
        }
        // 轮末账单的小弹窗里那个「在工作区打开」—— 落点是**改动 tab**,
        // 因为账单列表的就是改动。只切 tab 不动过滤框: 用户自己敲的过滤词不该被这一跳清掉。
        .onChange(of: store.workspaceChangesTick) { _, _ in
            tab = .changes
            reloadGit()   // 账单是刚跑完那一刻算的, git 状态可能已经又变了
        }
    }

    // MARK: - Tab 内容分发

    @ViewBuilder
    private func content(root: String) -> some View {
        switch tab {
        case .files:
            statsBar
            filterField
            ScrollView {
                Group {
                    if filterText.isEmpty {
                        FileTreeView(nodes: store.fileTree,
                                     changed: gitStatus?.changes ?? [:],
                                     stats: gitStatus?.stats ?? [:],
                                     touched: touchedSet,
                                     changedFolders: changedFolders,
                                     touchedFolders: touchedFolders,
                                     onExpandFolder: { rel in
                                         store.loadDirectory(relPath: rel)
                                     },
                                     onOpenFile: { open($0) })
                    } else {
                        filteredList
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity, alignment: .top)

        case .changes:
            ScrollView {
                WorkspaceChangesList(touched: touched,
                                     changedRows: (gitStatus?.changes ?? [:]).keys.sorted(),
                                     changes: gitStatus?.changes ?? [:],
                                     stats: gitStatus?.stats ?? [:],
                                     commits: recentCommits,
                                     onOpen: { open($0) })
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity, alignment: .top)

        case .preview:
            if let rel = previewRelative {
                FilePreviewView(rootPath: root, relativePath: rel)
            } else {
                previewEmptyState
            }
        }
    }

    /// 打开一个文件 = 送进预览 tab 并激活。**没有「返回」这一步**。
    private func open(_ rel: String) {
        previewRelative = rel
        tab = .preview
    }

    // MARK: - Tab 条 (文字 + 底部 2px 线; 不用胶囊)

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceTab.allCases) { t in
                tabItem(t)
            }
            Spacer(minLength: 0)
        }
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .bottom
        )
    }

    private func tabItem(_ t: WorkspaceTab) -> some View {
        let active = tab == t
        return Button {
            tab = t
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(t.title)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? CodexTheme.textPrimary : CodexTheme.textTertiary)
                    if let n = badge(t), n > 0 {
                        // 琥珀只给"有事在发生"; 完成的东西是绿的, 所以在别处
                        Text("\(n)")
                            .font(CodexFonts.monoFont(9))
                            .foregroundStyle(CodexTheme.toolRunning)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: Tune.workspaceTabHeight)
                Rectangle()
                    .fill(active ? CodexTheme.textPrimary : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// tab 上的计数。**只给「改动」**: 本会话 agent 触达了几个文件。
    /// 工作区脏数不在这里重复 —— 它在 header 的分支 chip 上, 两个数字各管一件事。
    private func badge(_ t: WorkspaceTab) -> Int? {
        t == .changes ? touched.count : nil
    }

    // MARK: - Empty states

    // P3.4: 无目录 (Work 理论上进不来, 兜底)
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(CodexTheme.textMuted)
            Text("当前会话未绑定项目目录")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(CodexTheme.textMuted)
            Text("还没有打开文件")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textTertiary)
            Text("在「文件」或「改动」里点一行")
                .font(.system(size: 9.5))
                .foregroundStyle(CodexTheme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header (项目名 + git 分支 + 刷新)

    private var projectName: String {
        (store.activeProjectPath as NSString?)?.lastPathComponent ?? ""
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(CodexTheme.textTertiary)
            Text(projectName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CodexTheme.textPrimary)
                .lineLimit(1)
            gitChip
            Spacer()
            Text(totalFiles.map { String(format: L("%lld 项"), $0) } ?? "")
                .font(CodexFonts.monoFont(10))
                .foregroundStyle(CodexTheme.textMuted)
            Button {
                store.refreshFileTree()
                reloadGit()
                reloadStats()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("刷新文件树与 git 状态")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .bottom
        )
        .help(store.activeProjectPath ?? "")
    }

    /// 分支 chip: 分支名 + 脏文件数; 非 git 目录不渲染。
    @ViewBuilder
    private var gitChip: some View {
        if let git = gitStatus, let branch = git.branch {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .semibold))
                Text(branch)
                    .font(CodexFonts.monoFont(10))
                    .lineLimit(1)
                if git.dirtyCount > 0 {
                    Text("\(git.dirtyCount)")
                        .font(CodexFonts.monoFont(9))
                        .foregroundStyle(CodexTheme.toolRunning)
                }
            }
            .foregroundStyle(git.dirtyCount > 0 ? CodexTheme.textSecondary : CodexTheme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(CodexTheme.bgPill.opacity(0.6)))
            .help(String(format: L("git 分支 · %lld 个改动"), git.dirtyCount))
        }
    }

    // MARK: - Language bar (构成条 + 图例; 后台全量扫描)

    @ViewBuilder
    private var statsBar: some View {
        if !langs.isEmpty {
            let total = langs.reduce(0) { $0 + $1.count }
            VStack(alignment: .leading, spacing: 4) {
                // 分段色条
                HStack(spacing: 1.5) {
                    ForEach(langs) { lang in
                        Capsule()
                            .fill(lang.color.opacity(0.75))
                            .frame(height: 3)
                            .frame(maxWidth: .infinity)
                    }
                }
                // 图例
                HStack(spacing: 10) {
                    ForEach(langs) { lang in
                        HStack(spacing: 3) {
                            Circle().fill(lang.color).frame(width: 5, height: 5)
                            Text(lang.name)
                                .font(.system(size: 9.5))
                                .foregroundStyle(CodexTheme.textTertiary)
                            Text("\(lang.count)")
                                .font(CodexFonts.monoFont(9))
                                .foregroundStyle(CodexTheme.textMuted)
                        }
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .help(String(format: L("文件类型构成 (共 %lld 个已识别文件)"), total))
        }
    }

    // MARK: - Filter

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(CodexTheme.textMuted)
            TextField("过滤文件…", text: $filterText)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textPrimary)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                .fill(CodexTheme.bgInput)
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                        .strokeBorder(CodexTheme.border, lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Filtered flat list

    private var filteredList: some View {
        let query = filterText.lowercased()
        let matches = flatten(store.fileTree, prefix: "")
            .filter { $0.lowercased().contains(query) }
        return Group {
            if matches.isEmpty {
                Text("无匹配文件")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(matches.prefix(80).enumerated()), id: \.offset) { _, rel in
                        HStack(spacing: 5) {
                            Image(systemName: "doc")
                                .font(.system(size: 9))
                                .foregroundStyle(CodexTheme.textTertiary)
                            Text(rel)
                                .font(CodexFonts.monoFont(10.5))
                                .foregroundStyle(CodexTheme.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            if let stat = gitStatus?.stats[rel] {
                                DiffStatView(stat: stat)
                            } else if let letter = gitStatus?.changes[rel] {
                                Text(letter)
                                    .font(CodexFonts.monoFont(9))
                                    .foregroundStyle(workspaceGitLetterColor(letter))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .contentShape(Rectangle())
                        .onTapGesture { open(rel) }
                    }
                    if matches.count > 80 {
                        Text("仅显示前 80 条, 继续输入缩小范围")
                            .font(.system(size: 9.5))
                            .foregroundStyle(CodexTheme.textMuted)
                            .padding(.leading, 8)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func flatten(_ nodes: [FileNode], prefix: String) -> [String] {
        var out: [String] = []
        for node in nodes {
            let rel = prefix.isEmpty ? node.name : "\(prefix)/\(node.name)"
            if node.isFolder {
                out.append(contentsOf: flatten(node.children, prefix: rel))
            } else {
                out.append(rel)
            }
        }
        return out
    }

    // MARK: - 数据

    /// agent 触达集: 只在 `root#messages.count` 变了才重算 (见 `touched` 的注释)。
    private func refreshTouched(root: String) {
        let key = "\(root)#\(store.messages.count)"
        guard key != touchedKey else { return }
        touchedKey = key
        touched = agentTouchedPaths(root: root)
        touchedSet = Set(touched)
        touchedFolders = workspaceFolderPrefixes(of: touched)
    }

    /// 本会话 agent 触达的文件 (edit/write 工具, 新→旧去重), 相对项目根。
    ///
    /// ⚠️ 实现搬到 `TurnBill.swift` 的 `AgentTouched.paths(in:root:)` 了 —— **两处共用一份**：
    ///    这里数的是"本会话", 轮末账单数的是"本轮", 范围不同但**成员判据必须同源**。
    private func agentTouchedPaths(root: String) -> [String] {
        AgentTouched.paths(in: store.messages, root: root)
    }

    private func reloadGit() {
        guard let root = store.activeProjectPath else {
            gitStatus = nil
            changedFolders = []
            recentCommits = []
            return
        }
        Task.detached {
            let st = WorkspaceGit.status(root: root)
            let log = WorkspaceGit.recentCommits(root: root)
            let folders = workspaceFolderPrefixes(of: Array((st?.changes ?? [:]).keys))
            await MainActor.run {
                gitStatus = st
                recentCommits = log
                changedFolders = folders
            }
        }
    }

    /// 语言构成 + 文件总数: 后台全量扫描 (懒加载树不含未展开部分)。
    private func reloadStats() {
        guard let root = store.activeProjectPath else {
            langs = []
            totalFiles = nil
            return
        }
        Task.detached {
            let tree = WorkspaceScanner.scan(root: root)
            let l = WorkspaceStats.languages(tree)
            let n = WorkspaceStats.countFiles(tree)
            await MainActor.run {
                langs = l
                totalFiles = n
            }
        }
    }
}
