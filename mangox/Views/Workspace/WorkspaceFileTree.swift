//
//  WorkspaceFileTree.swift
//  工作区「文件」tab: 递归文件树 + 行渲染 + diff 统计徽标。
//
//  从 `WorkspaceView.swift` 拆出 (那一个文件原本同时装了外壳/树/改动/预览四件事)。
//  拆分的判据不是行数, 是**刷新频率**: 树随展开折叠重画, 预览随文件切换重画,
//  混在一个 `View` 里 ⇒ 任何一处的 `@State` 变动都会把另外三处一起重算。
//

import SwiftUI

/// 单字母 git 状态 → 语义色。**树与改动列表必须同源**, 否则同一个 `M` 在两个 tab 里两种颜色。
func workspaceGitLetterColor(_ letter: String) -> Color {
    switch letter {
    case "D":      return CodexTheme.toolError
    case "A", "U": return CodexTheme.toolDone
    default:       return CodexTheme.toolRunning   // M
    }
}

/// 把一组文件路径摊成「它们经过的每一级目录」。
///
/// 这是**纯数据变换, 所以不挂在 `FileTreeView` 上** —— 挂在 `View` 类型上时, 静态成员查找
/// 会跟 SwiftUI 协议里那些 `static` 入口撞车 (实测: 在 `Task.detached` 里调用它会被判成
/// "expression is 'async' but is not marked with 'await'", 一个只有 WMO Release 不报、
/// 冒烟编译才报的告警)。
func workspaceFolderPrefixes(of paths: [String]) -> Set<String> {
    var out: Set<String> = []
    out.reserveCapacity(paths.count * 2)
    for p in paths {
        var comps = p.components(separatedBy: "/")
        guard comps.count > 1 else { continue }
        comps.removeLast()
        var acc = ""
        for c in comps {
            acc = acc.isEmpty ? c : acc + "/" + c
            out.insert(acc)
        }
    }
    return out
}

// MARK: - Diff stat display (+234 -98, 行数单位, 千位缩写)

struct DiffStatView: View {
    let stat: WorkspaceGit.DiffStat

    var body: some View {
        HStack(spacing: 3) {
            if stat.added > 0 {
                Text("+\(Self.short(stat.added))")
                    .font(CodexFonts.monoFont(9))
                    .foregroundStyle(CodexTheme.toolDone)
            }
            if stat.deleted > 0 {
                Text("-\(Self.short(stat.deleted))")
                    .font(CodexFonts.monoFont(9))
                    .foregroundStyle(CodexTheme.toolError)
            }
        }
        .help(String(format: L("+%lld / -%lld 行"), stat.added, stat.deleted))
    }

    static func short(_ n: Int) -> String {
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1000) }
        if n >= 1_000  { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

// MARK: - File tree (recursive, flattened render)

struct FileTreeView: View {
    let nodes: [FileNode]
    var changed: [String: String] = [:]
    var stats: [String: WorkspaceGit.DiffStat] = [:]
    var touched: Set<String> = []
    /// 「之下有改动 / 之下有 agent 触达」的目录集, **由外层一次算好**。
    /// 原先每个目录行自己去扫全部 `changed`/`touched` 判前缀 ⇒ O(目录数 × 改动数),
    /// 而这段在 body 里, 一次展开/折叠会重算全部可见行。
    var changedFolders: Set<String> = []
    var touchedFolders: Set<String> = []
    var onExpandFolder: (String) -> Void = { _ in }
    var onOpenFile: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(nodes) { node in
                FileTreeNodeView(node: node, path: node.name,
                                 changed: changed, stats: stats, touched: touched,
                                 changedFolders: changedFolders,
                                 touchedFolders: touchedFolders,
                                 onExpandFolder: onExpandFolder,
                                 onOpenFile: onOpenFile)
            }
        }
    }

}

struct FileTreeNodeView: View {
    let node: FileNode
    let path: String
    var changed: [String: String] = [:]
    var stats: [String: WorkspaceGit.DiffStat] = [:]
    var touched: Set<String> = []
    var changedFolders: Set<String> = []
    var touchedFolders: Set<String> = []
    var onExpandFolder: (String) -> Void = { _ in }
    var onOpenFile: (String) -> Void
    @State private var isExpanded: Bool = false

    private var hasChangedInside: Bool { node.isFolder && changedFolders.contains(path) }
    private var hasTouchedInside: Bool { node.isFolder && touchedFolders.contains(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if node.isFolder {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(CodexTheme.textTertiary)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: node.isFolder ? "folder" : "doc")
                    .font(.system(size: 10))
                    .foregroundStyle(node.isFolder ? CodexTheme.textSecondary : CodexTheme.textTertiary)
                Text(node.name)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(node.isFolder ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
                // agent 触达标记 (绿点)
                if !node.isFolder && touched.contains(path) {
                    Circle()
                        .fill(CodexTheme.toolDone)
                        .frame(width: 4, height: 4)
                }
                // git 状态徽标 (文件行) / 改动标点 (目录行)
                if !node.isFolder {
                    if let stat = stats[path] {
                        DiffStatView(stat: stat)
                    } else if let letter = changed[path] {
                        Text(letter)
                            .font(CodexFonts.monoFont(9))
                            .foregroundStyle(workspaceGitLetterColor(letter))
                    }
                } else if hasChangedInside || hasTouchedInside {
                    Circle()
                        .fill(hasChangedInside ? CodexTheme.toolRunning : CodexTheme.toolDone)
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.leading, CGFloat(8 + node.depth * 12))
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onAppear {
                if node.isFolder { isExpanded = node.isExpanded }
            }
            .onTapGesture {
                if node.isFolder {
                    withAnimation(CodexTheme.animFast) { isExpanded.toggle() }
                    // lazy: 首次展开触发按需加载 (后台扫描, 回来原位插入)
                    if isExpanded && !node.childrenLoaded {
                        onExpandFolder(path)
                    }
                } else {
                    onOpenFile(path)
                }
            }

            if isExpanded && !node.childrenLoaded {
                // 已展开但子级未到: 占位行 (后台扫描通常 <50ms)
                HStack(spacing: 4) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(CodexTheme.textMuted)
                    Text("加载中…")
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                }
                .padding(.leading, CGFloat(8 + (node.depth + 1) * 12))
                .padding(.vertical, 2)
            } else if isExpanded && !node.children.isEmpty {
                ForEach(node.children) { child in
                    FileTreeNodeView(node: child,
                                     path: path.isEmpty ? child.name : "\(path)/\(child.name)",
                                     changed: changed,
                                     stats: stats,
                                     touched: touched,
                                     changedFolders: changedFolders,
                                     touchedFolders: touchedFolders,
                                     onExpandFolder: onExpandFolder,
                                     onOpenFile: onOpenFile)
                }
            }
        }
    }
}
