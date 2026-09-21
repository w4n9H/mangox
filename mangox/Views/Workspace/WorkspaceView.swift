//
//  WorkspaceView.swift
//  Workspace column (hidden by default): file tree + git status + agent-touched
//  files + language bar + filter + file preview.
//

import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: ChatStore
    @State private var previewRelative: String? = nil
    @State private var gitStatus: WorkspaceGit.Status? = nil
    @State private var filterText: String = ""
    // 语言构成/文件总数走后台全量扫描 (懒加载树只含已展开部分, 不能作为统计源)
    @State private var langs: [WorkspaceStats.Lang] = []
    @State private var totalFiles: Int? = nil
    @State private var recentCommits: [WorkspaceGit.Commit] = []
    @State private var showCommits: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root = store.activeProjectPath {
                if let rel = previewRelative {
                    FilePreviewView(rootPath: root, relativePath: rel, onBack: {
                        withAnimation(CodexTheme.animFast) { previewRelative = nil }
                    })
                } else {
                    header
                    statsBar
                    filterField
                    ScrollView {
                        workspaceContent(root: root)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                emptyState
            }
        }
        .task(id: store.activeProjectPath) {
            reloadGit()
            reloadStats()
        }
    }
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
            .help("git 分支 · \(git.dirtyCount) 个改动")
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
            .help("文件类型构成 (共 \(total) 个已识别文件)")
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

    // MARK: - Content (过滤列表 / 改动区 + 文件树)

    @ViewBuilder
    private func workspaceContent(root: String) -> some View {
        if filterText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                commitsSection
                touchedSection(root: root)
                FileTreeView(nodes: store.fileTree,
                             changed: gitStatus?.changes ?? [:],
                             stats: gitStatus?.stats ?? [:],
                             touched: Set(agentTouchedPaths(root: root)),
                             onExpandFolder: { rel in
                                 store.loadDirectory(relPath: rel)
                             }) { path in
                    withAnimation(CodexTheme.animFast) { previewRelative = path }
                }
            }
        } else {
            filteredList
        }
    }

    // MARK: - 最近提交 (git log -5, 可折叠)

    @ViewBuilder
    private var commitsSection: some View {
        if !recentCommits.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Button {
                    withAnimation(CodexTheme.animFast) { showCommits.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showCommits ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(CodexTheme.textTertiary)
                            .frame(width: 10)
                        Text("最近提交")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(CodexTheme.textTertiary)
                        Text("\(recentCommits.count)")
                            .font(CodexFonts.monoFont(9))
                            .foregroundStyle(CodexTheme.textMuted)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showCommits {
                    ForEach(recentCommits, id: \.hash) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.subject)
                                .font(CodexTheme.fontTiny)
                                .foregroundStyle(CodexTheme.textSecondary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(c.hash)
                                    .font(CodexFonts.monoFont(9))
                                    .foregroundStyle(CodexTheme.info)
                                Text(c.author)
                                    .font(.system(size: 9))
                                    .foregroundStyle(CodexTheme.textTertiary)
                                    .lineLimit(1)
                                Text(WorkspaceGit.relativeTime(c.timestamp))
                                    .font(.system(size: 9))
                                    .foregroundStyle(CodexTheme.textMuted)
                                Spacer()
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(c.hash, forType: .string)
                        }
                        .help("点击复制 hash: \(c.hash)")
                    }
                    Divider()
                        .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Agent 改动区 (本会话 edit/write 触达的文件)

    private func touchedSection(root: String) -> some View {
        let paths = agentTouchedPaths(root: root)
        return Group {
            if !paths.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("本会话改动")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(CodexTheme.textTertiary)
                        Text("\(paths.count)")
                            .font(CodexFonts.monoFont(9))
                            .foregroundStyle(CodexTheme.textMuted)
                        Spacer()
                    }
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
                    ForEach(paths, id: \.self) { rel in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(CodexTheme.toolDone)
                                .frame(width: 4, height: 4)
                            Image(systemName: "doc")
                                .font(.system(size: 9))
                                .foregroundStyle(CodexTheme.textTertiary)
                            Text(rel)
                                .font(CodexFonts.monoFont(10.5))
                                .foregroundStyle(CodexTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                        }
                        .padding(.leading, 8)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(CodexTheme.animFast) { previewRelative = rel }
                        }
                    }
                    Divider()
                        .padding(.vertical, 4)
                }
            }
        }
    }

    /// 本会话 agent 触达的文件 (edit/write 工具, 新→旧去重), 相对项目根。
    private func agentTouchedPaths(root: String) -> [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for msg in store.messages.reversed() {
            guard case .tool(let t) = msg.content,
                  t.kind == .edit || t.kind == .write else { continue }
            let rel = Self.relativePath(t.title, root: root)
            guard !rel.isEmpty, seen.insert(rel).inserted else { continue }
            order.append(rel)
        }
        return order
    }

    /// 绝对路径剥 root 前缀; 相对路径原样返回。
    private static func relativePath(_ path: String, root: String) -> String {
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return path.hasPrefix("/") ? "" : path
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
                                    .foregroundStyle(gitColor(letter))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(CodexTheme.animFast) { previewRelative = rel }
                        }
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

    private func reloadGit() {
        guard let root = store.activeProjectPath else {
            gitStatus = nil
            recentCommits = []
            return
        }
        Task.detached {
            let st = WorkspaceGit.status(root: root)
            let log = WorkspaceGit.recentCommits(root: root)
            await MainActor.run {
                gitStatus = st
                recentCommits = log
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

    fileprivate func gitColor(_ letter: String) -> Color {
        switch letter {
        case "D":            return CodexTheme.toolError
        case "A", "U":       return CodexTheme.toolDone
        default:             return CodexTheme.toolRunning   // M
        }
    }
}

// MARK: - Diff stat display (+234 -98, 行数单位, 千位缩写)

fileprivate struct DiffStatView: View {
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
    var onExpandFolder: (String) -> Void = { _ in }
    var onOpenFile: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(nodes) { node in
                FileTreeNodeView(node: node, path: node.name,
                                 changed: changed, stats: stats, touched: touched,
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
    var onExpandFolder: (String) -> Void = { _ in }
    var onOpenFile: (String) -> Void
    @State private var isExpanded: Bool = false

    private var hasChangedInside: Bool {
        node.isFolder && changed.keys.contains { $0.hasPrefix(path + "/") }
    }
    private var hasTouchedInside: Bool {
        node.isFolder && touched.contains { $0.hasPrefix(path + "/") }
    }

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
                            .foregroundStyle(gitBadgeColor(letter))
                    }
                } else if node.isFolder && (hasChangedInside || hasTouchedInside) {
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
                                     onExpandFolder: onExpandFolder,
                                     onOpenFile: onOpenFile)
                }
            }
        }
    }

    private func gitBadgeColor(_ letter: String) -> Color {
        switch letter {
        case "D":      return CodexTheme.toolError
        case "A", "U": return CodexTheme.toolDone
        default:       return CodexTheme.toolRunning   // M
        }
    }
}

// MARK: - File preview (P3.4: 读磁盘真实内容)

struct FilePreviewView: View {
    let rootPath: String
    let relativePath: String
    let onBack: () -> Void

    private var absolutePath: String {
        URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath).path
    }

    private var fileName: String {
        relativePath.components(separatedBy: "/").last ?? relativePath
    }

    private var language: String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "glsl", "frag", "vert": return "glsl"
        case "js", "mjs": return "javascript"
        case "ts": return "typescript"
        case "json": return "json"
        case "py": return "python"
        case "sh": return "bash"
        case "swift": return "swift"
        default: return nil
        }
    }

    /// 文件元信息: 大小 + 修改时间 (预览头右侧弱化显示)。
    private var fileMeta: String? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: absolutePath) else { return nil }
        var parts: [String] = []
        if let size = attr[.size] as? Int {
            if size >= 1_048_576 {
                parts.append(String(format: "%.1f MB", Double(size) / 1_048_576))
            } else if size >= 1_024 {
                parts.append(String(format: "%.1f KB", Double(size) / 1_024))
            } else {
                parts.append("\(size) B")
            }
        }
        if let date = attr[.modificationDate] as? Date {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm"
            parts.append(fmt.string(from: date))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 真实文件内容; 二进制/超大文件给占位文案。
    private var fileContent: String {
        let fm = FileManager.default
        guard let attr = try? fm.attributesOfItem(atPath: absolutePath),
              let size = attr[.size] as? Int, size <= 1_000_000
        else { return L("// 文件过大 (>1 MB), 暂不支持预览") }
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "icns", "pdf"]
        let ext = (fileName as NSString).pathExtension.lowercased()
        if imageExts.contains(ext) { return String(format: L("// 二进制文件 (%@), 图片预览将在后续版本提供"), ext) }
        guard let s = try? String(contentsOfFile: absolutePath, encoding: .utf8) else {
            return L("// 二进制文件或暂不支持的编码")
        }
        if s.isEmpty { return L("// 空文件") }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Preview header: back + file identity
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CodexTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("返回文件树")

                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName)
                        .font(CodexTheme.fontMonoSm)
                        .foregroundStyle(CodexTheme.textPrimary)
                        .lineLimit(1)
                    Text(absolutePath)
                        .font(CodexTheme.fontTiny)
                        .foregroundStyle(CodexTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(language ?? "text")
                        .font(CodexTheme.fontMonoXs)
                        .foregroundStyle(CodexTheme.textTertiary)
                    if let meta = fileMeta {
                        Text(meta)
                            .font(.system(size: 9))
                            .foregroundStyle(CodexTheme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
                alignment: .bottom
            )

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(CodeHighlighter.highlight(fileContent, language: language))
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
