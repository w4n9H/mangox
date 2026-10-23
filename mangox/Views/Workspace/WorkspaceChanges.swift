//
//  WorkspaceChanges.swift
//  工作区「改动」tab: 本会话 agent 触达的文件 + git 工作区改动 + 最近提交。
//
//  「本会话改动」从文件树上方的一个小节**升格成一级 tab**。
//  理由是它原来跟树抢同一块垂直空间 —— 会话跑起来之后它能长到二三十行, 把树挤到屏幕外,
//  而它恰恰是"这个会话动了什么"最该一眼看到的东西。git 改动同理: 原来只能靠树上的
//  `M`/`A` 徽标反推, 现在有一张自己的清单。
//

import AppKit
import SwiftUI

struct WorkspaceChangesList: View {
    /// 本会话 agent 触达 (edit/write), 新→旧去重, 相对项目根。
    let touched: [String]
    /// git 工作区改动, 已按路径排序。
    let changedRows: [String]
    let changes: [String: String]
    let stats: [String: WorkspaceGit.DiffStat]
    let commits: [WorkspaceGit.Commit]
    var onOpen: (String) -> Void = { _ in }

    @State private var showCommits: Bool = true

    /// 「本会话没碰过、但工作区是脏的」。
    ///
    /// ⚠️ 两段**必须是两笔不重叠的账**: 同一张 360pt 面板里把同一批路径列两遍
    /// (一次说我改的、一次说 git 脏的) 只是噪音; 拆成"我改的"+"其余"之后,
    /// 两段的计数加起来才能对上 header 上那个脏文件数。
    private var otherRows: [String] {
        guard !touched.isEmpty else { return changedRows }
        let mine = Set(touched)
        return changedRows.filter { !mine.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if touched.isEmpty && changedRows.isEmpty {
                emptyState
            }
            if !touched.isEmpty {
                SectionHeader(title: L("本会话改动"), count: touched.count)
                ForEach(touched, id: \.self) { rel in
                    row(path: rel, letter: changes[rel], stat: stats[rel], dot: CodexTheme.toolDone)
                }
            }
            if !otherRows.isEmpty {
                // 本会话什么都没碰时, "其余改动" 就是全部改动 —— 别让它读起来像剩饭
                SectionHeader(title: touched.isEmpty ? L("工作区改动") : L("其它改动"),
                              count: otherRows.count)
                ForEach(otherRows, id: \.self) { rel in
                    row(path: rel,
                        letter: changes[rel],
                        stat: stats[rel],
                        dot: nil)
                }
            }
            if !commits.isEmpty {
                commitsSection
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("本会话还没有改动")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textTertiary)
            Text("agent 每改一个文件, 这里就会多一行")
                .font(.system(size: 9.5))
                .foregroundStyle(CodexTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 28)
    }

    // MARK: - 文件行

    private func row(path: String, letter: String?, stat: WorkspaceGit.DiffStat?,
                     dot: Color?) -> some View {
        HStack(spacing: 5) {
            if let dot {
                Circle().fill(dot).frame(width: 4, height: 4)
            }
            Image(systemName: "doc")
                .font(.system(size: 9))
                .foregroundStyle(CodexTheme.textTertiary)
            Text(path)
                .font(CodexFonts.monoFont(10.5))
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let stat {
                DiffStatView(stat: stat)
            } else if let letter {
                Text(letter)
                    .font(CodexFonts.monoFont(9))
                    .foregroundStyle(workspaceGitLetterColor(letter))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(path) }
        .help(path)
    }

    // MARK: - 最近提交 (git log -5, 可折叠)

    private var commitsSection: some View {
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
                    Text("\(commits.count)")
                        .font(CodexFonts.monoFont(9))
                        .foregroundStyle(CodexTheme.textMuted)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            if showCommits {
                ForEach(commits, id: \.hash) { c in
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
                    .help(String(format: L("点击复制 hash: %@"), c.hash))
                }
            }
        }
    }
}

// MARK: - 小节标题 (标签 + 计数)

struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(CodexTheme.textTertiary)
            if let count {
                Text("\(count)")
                    .font(CodexFonts.monoFont(9))
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 1)
    }
}
