//
//  WorkspaceModels.swift
//  Models for the workspace column: file tree, git status, language stats.
//

import Foundation
import SwiftUI

// MARK: - File tree

struct FileNode: Identifiable, Hashable {
    let id: UUID
    let name: String
    let isFolder: Bool
    let depth: Int
    var isExpanded: Bool
    /// lazy: 目录子级是否已扫描 (文件恒 true; 未扫描目录展开时触发按需加载)
    var childrenLoaded: Bool
    let children: [FileNode]   // flattened; only valid when isFolder

    init(id: UUID = UUID(),
         name: String,
         isFolder: Bool,
         depth: Int,
         isExpanded: Bool = false,
         childrenLoaded: Bool = true,
         children: [FileNode] = []) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.depth = depth
        self.isExpanded = isExpanded
        self.childrenLoaded = childrenLoaded
        self.children = children
    }
}

// MARK: - Workspace scanner (P3.4: 文件树接磁盘)

enum WorkspaceScanner {
    /// 排除目录名 (构建产物/依赖/版本库)。前端生态的重目录都在此列。
    private static let excludedDirs: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "Pods",
        "dist", "__pycache__", ".venv", "venv", "target", ".next", ".cache",
        "build", "out", "coverage", ".turbo", ".svelte-kit", ".output",
        "bower_components", "vendor", ".gradle", ".idea", ".vscode-test",
    ]
    private static let maxDepth = 6
    private static let maxEntriesPerDir = 200

    /// lazy 入口: 只扫 root 一层 (目录不递归, childrenLoaded=false)。
    /// 大仓库/前端项目毫秒级返回, 不会卡主线程。
    static func scanShallow(root: String) -> [FileNode] {
        entries(of: root, depth: 0)
    }

    /// lazy 展开: 扫描单个目录一层, 目录子项继续标记未加载 (展开时再扫)。
    static func scanDirectory(_ dir: String, depth: Int) -> [FileNode] {
        entries(of: dir, depth: depth)
    }

    /// 全量递归扫描 (仅语言构成条等统计用途, 须在后台线程调用)。
    static func scan(root: String) -> [FileNode] {
        build(directory: root, depth: 0)
    }

    private static func entries(of directory: String, depth: Int) -> [FileNode] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let visible = entries
            .filter { !$0.hasPrefix(".") && !excludedDirs.contains($0) }
            .prefix(maxEntriesPerDir)

        var dirs: [String] = []
        var files: [String] = []
        for name in visible {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: directory + "/" + name, isDirectory: &isDir)
            if isDir.boolValue { dirs.append(name) } else { files.append(name) }
        }
        dirs.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        files.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        var nodes: [FileNode] = []
        for name in dirs {
            nodes.append(FileNode(name: name, isFolder: true, depth: depth,
                                  isExpanded: false, childrenLoaded: false))
        }
        for name in files {
            nodes.append(FileNode(name: name, isFolder: false, depth: depth))
        }
        return nodes
    }

    private static func build(directory: String, depth: Int) -> [FileNode] {
        guard depth < maxDepth,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return [] }

        let visible = entries
            .filter { !$0.hasPrefix(".") && !excludedDirs.contains($0) }
            .prefix(maxEntriesPerDir)

        var dirs: [(String, Bool)] = []
        var files: [String] = []
        for name in visible {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: directory + "/" + name, isDirectory: &isDir)
            if isDir.boolValue { dirs.append((name, true)) } else { files.append(name) }
        }
        // 文件夹在前, 各自按名排序 (case-insensitive)
        dirs.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        files.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        var nodes: [FileNode] = []
        for (name, _) in dirs {
            let childDir = directory + "/" + name
            nodes.append(FileNode(name: name, isFolder: true, depth: depth,
                                  isExpanded: false,
                                  children: build(directory: childDir, depth: depth + 1)))
        }
        for name in files {
            nodes.append(FileNode(name: name, isFolder: false, depth: depth))
        }
        return nodes
    }
}

// MARK: - Git status (工作区列 git 集成: 分支 + 脏文件)

enum WorkspaceGit {

    /// 单文件 diff 统计 (numstat)。
    struct DiffStat: Equatable {
        let added: Int
        let deleted: Int
    }

    struct Status: Equatable {
        var branch: String?
        /// 相对路径 → 单字母状态 (M=改 A=增 D=删 U=未跟踪)
        var changes: [String: String] = [:]
        /// 相对路径 → +/- 行数 (numstat; untracked 按全量新增计)
        var stats: [String: DiffStat] = [:]
        var dirtyCount: Int { changes.count }

        /// 目录 relPath 之下是否有改动 (目录行标点用)。
        func hasChange(under relPath: String) -> Bool {
            let prefix = relPath + "/"
            return changes.keys.contains { $0.hasPrefix(prefix) }
        }
    }

    /// 一次性 `git status --porcelain -b`; 非 git 目录 / git 不可用返回 nil (调用方静默退化)。
    static func status(root: String) -> Status? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["--no-optional-locks", "-c", "core.quotepath=false",
                       "-C", root, "status", "--porcelain=v1", "-b", "-uall"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        var st = Status()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("## ") {
                let head = line.dropFirst(3)
                if head.hasPrefix("No commits yet on ") {
                    st.branch = String(head.dropFirst("No commits yet on ".count))
                } else {
                    st.branch = String(head.split(separator: "...").first ?? "")
                }
            } else if line.count > 3 {
                let code = line.prefix(2)
                var path = String(line.dropFirst(3))
                // rename 行: "R  old -> new" 只认新路径
                if let r = path.range(of: " -> ") { path = String(path[r.upperBound...]) }
                path = Self.unquoteGitPath(path)
                let letter: String
                if code == "??"                       { letter = "U" }
                else if code.contains("D")            { letter = "D" }
                else if code.contains("A")            { letter = "A" }
                else                                  { letter = "M" }
                st.changes[path] = letter
            }
        }
        st.stats = Self.diffStats(root: root, changes: st.changes)
        return st
    }

    // MARK: - Recent commits (最近提交列表)

    struct Commit: Equatable {
        let hash: String
        let author: String
        let timestamp: TimeInterval
        let subject: String
    }

    /// 最近 n 条提交 (当前分支 HEAD)。非 git 目录返回 []。
    static func recentCommits(root: String, limit: Int = 5) -> [Commit] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["--no-optional-locks", "-c", "core.quotepath=false",
                       "-C", root, "log", "-n", String(limit),
                       "--pretty=format:%h%x1f%an%x1f%at%x1f%s"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }

        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let f = raw.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard f.count >= 4,
                  let ts = TimeInterval(f[2]) else { return nil }
            // subject 理论上单行, 防御性去掉内嵌换行
            let subject = f[3...].joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return Commit(hash: String(f[0]), author: String(f[1]),
                          timestamp: ts, subject: subject)
        }
    }

    /// 相对时间 ("3小时前"), 跟随系统 locale。
    static func relativeTime(_ timestamp: TimeInterval) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: Date(timeIntervalSince1970: timestamp),
                                   relativeTo: Date())
    }

    // MARK: numstat (每文件 +/- 行数)

    /// 未暂存 + 已暂存 numstat 合并; untracked 文件读文件行数按全量新增计。
    private static func diffStats(root: String, changes: [String: String]) -> [String: DiffStat] {
        var out: [String: DiffStat] = [:]
        for args in [["diff", "--numstat", "-z"], ["diff", "--cached", "--numstat", "-z"]] {
            for (added, deleted, path) in runNumstat(root: root, args: args) {
                if let old = out[path] {
                    out[path] = DiffStat(added: old.added + added, deleted: old.deleted + deleted)
                } else {
                    out[path] = DiffStat(added: added, deleted: deleted)
                }
            }
        }
        // untracked: numstat 不覆盖, 读文件行数当全量新增 (二进制/大文件跳过)
        for (path, letter) in changes where letter == "U" && out[path] == nil {
            if let lines = countLines(root: root, relPath: path) {
                out[path] = DiffStat(added: lines, deleted: 0)
            }
        }
        return out
    }

    /// `git <args>` numstat 解析 (-z: NUL 分帧, 路径不做 C 引号转义; 二进制文件 a=d=-1 跳过)。
    private static func runNumstat(root: String, args: [String]) -> [(Int, Int, String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["--no-optional-locks", "-C", root] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }

        var result: [(Int, Int, String)] = []
        for entry in data.split(separator: 0) {
            let fields = String(decoding: entry, as: UTF8.self).split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let a = Int(fields[0]), let d = Int(fields[1]) else { continue }  // "-" = 二进制
            result.append((a, d, String(fields[2])))
        }
        return result
    }

    /// untracked 文件行数; >1MB 或读取失败 (二进制) 返回 nil。
    private static func countLines(root: String, relPath: String) -> Int? {
        let abs = root + "/" + relPath
        guard let attr = try? FileManager.default.attributesOfItem(atPath: abs),
              let size = attr[.size] as? Int, size > 0, size <= 1_000_000,
              let s = try? String(contentsOfFile: abs, encoding: .utf8) else { return nil }
        if s.isEmpty { return 0 }
        return s.split(separator: "\n", omittingEmptySubsequences: false).count - 1
    }

    /// 剥 git 的 C 风格路径引号 ("a b/x" → a b/x), 并展开 \nnn 八进制与常见转义。
    private static func unquoteGitPath(_ p: String) -> String {
        guard p.hasPrefix("\""), p.hasSuffix("\""), p.count >= 2 else { return p }
        let inner = String(p.dropFirst().dropLast())
        // 字节级展开 (UTF-8 安全), 再整体解码
        var bytes: [UInt8] = []
        let chars = Array(inner.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == 0x5C /* \ */ && i + 1 < chars.count {
                let nxt = chars[i + 1]
                switch nxt {
                case 0x6E:  bytes.append(0x0A); i += 2          // \n
                case 0x74:  bytes.append(0x09); i += 2          // \t
                case 0x72:  bytes.append(0x0D); i += 2          // \r
                case 0x22:  bytes.append(0x22); i += 2          // \"
                case 0x5C:  bytes.append(0x5C); i += 2          // \\
                case 0x61:  bytes.append(0x07); i += 2          // \a
                case 0x62:  bytes.append(0x08); i += 2          // \b
                case 0x66:  bytes.append(0x0C); i += 2          // \f
                case 0x76:  bytes.append(0x0B); i += 2          // \v
                default:
                    // \nnn 八进制 (1-3 位)
                    if (0x30...0x37).contains(nxt) {
                        var value: UInt8 = 0
                        var digits = 0
                        var j = i + 1
                        while j < chars.count, digits < 3, (0x30...0x37).contains(chars[j]) {
                            value = value * 8 + (chars[j] - 0x30)
                            digits += 1
                            j += 1
                        }
                        bytes.append(value)
                        i = j
                    } else {
                        bytes.append(chars[i])
                        i += 1
                    }
                }
            } else {
                bytes.append(chars[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Language stats (按扩展名聚合的构成条)

enum WorkspaceStats {

    struct Lang: Identifiable {
        let name: String
        let count: Int
        let color: Color
        var id: String { name }
    }

    /// GitHub 语言色 (亮色主题下调暗过的子集)。
    private static let colors: [String: UInt32] = [
        "swift": 0xE85D3D, "ts": 0x3178C6, "tsx": 0x3178C6, "js": 0xB8912F,
        "py": 0x3572A5, "go": 0x2B9EB3, "rs": 0xC97B4A, "java": 0xB07219,
        "c": 0x7A828A, "h": 0x7A828A, "cpp": 0xD2567E, "cs": 0x8A4BA8,
        "md": 0x8A949E, "json": 0xB8912F, "yaml": 0x6E996E, "yml": 0x6E996E,
        "toml": 0x9C6B4F, "sh": 0x4E9A3D, "html": 0xD95A2B, "css": 0x663AA0,
        "sql": 0xC98A3D, "glsl": 0x5A9AB5, "frag": 0x5A9AB5, "vert": 0x5A9AB5,
    ]
    private static let names: [String: String] = [
        "swift": "Swift", "ts": "TS", "tsx": "TSX", "js": "JS", "py": "Python",
        "go": "Go", "rs": "Rust", "java": "Java", "c": "C", "h": "C Header",
        "cpp": "C++", "cs": "C#", "md": "Markdown", "json": "JSON",
        "yaml": "YAML", "yml": "YAML", "toml": "TOML", "sh": "Shell",
        "html": "HTML", "css": "CSS", "sql": "SQL",
        "glsl": "GLSL", "frag": "GLSL", "vert": "GLSL",
    ]

    /// 资源类扩展不进语言统计 (字体/图片/工程配置是噪声)。
    private static let ignoredExts: Set<String> = [
        "ttf", "otf", "woff", "woff2", "png", "jpg", "jpeg", "gif", "webp",
        "icns", "pdf", "entitlements", "plist", "xcassets", "storyboard",
        "xib", "svg", "appiconset",
    ]

    /// top n 语言 (最多 4 种), 空目录返回 []。
    static func languages(_ nodes: [FileNode], top: Int = 4) -> [Lang] {
        var counts: [String: Int] = [:]
        count(nodes, into: &counts)
        return counts.sorted { $0.value > $1.value }.prefix(top).map { ext, n in
            Lang(name: names[ext] ?? ext.uppercased(),
                 count: n,
                 color: Color(hex: colors[ext] ?? 0x9CA3AB))
        }
    }

    private static func count(_ nodes: [FileNode], into counts: inout [String: Int]) {
        for node in nodes {
            if node.isFolder {
                count(node.children, into: &counts)
            } else {
                let ext = (node.name as NSString).pathExtension.lowercased()
                if !ext.isEmpty && !ignoredExts.contains(ext) { counts[ext, default: 0] += 1 }
            }
        }
    }

    /// 递归数文件 (全量树)。
    static func countFiles(_ nodes: [FileNode]) -> Int {
        nodes.reduce(0) { acc, node in
            node.isFolder ? acc + countFiles(node.children) : acc + 1
        }
    }
}
