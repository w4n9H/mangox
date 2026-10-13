//
//  ExtensionsView.swift
//  P3.11 插件 (pi 扩展) 管理面板 (主区切换视图)。
//  视觉语言对齐 KnowledgeView: 左列 = Sidebar 行语言, 编辑区 = 源码只读预览。
//  托管区 (~/.mangox/extensions) 完整管理: 导入/启停/删除, spawn 期按启用列表 --extension;
//  全局/项目区只读展示 (pi 自动发现在 MangoX 内不生效), 可导入到托管区。
//

import SwiftUI

struct ExtensionsView: View {
    @ObservedObject var store: ChatStore

    @State private var selectedPath: String?
    @State private var showingImporter = false
    @State private var confirmDelete: ExtensionItem?

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: Tune.knowledgeListWidth)
                .background(CodexTheme.bgSidebar)
            Divider().overlay(CodexTheme.divider)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CodexTheme.bgChat)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importExtension(at: url)
            }
        }
        .confirmationDialog("删除插件「\(confirmDelete?.name ?? "")」？",
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let item = confirmDelete { store.deleteExtension(item) }
                confirmDelete = nil
            }
            Button("取消", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("文件将从托管区移除, 此操作不可撤销。")
        }
    }

    // MARK: - 左列 (来源分组列表)

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PLUGINS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(CodexTheme.textMuted)
                Spacer()
                Button(action: { showingImporter = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("导入 .ts/.js 到托管区")
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    section("托管", source: .managed)
                    section("全局", source: .global)
                    section("项目", source: .project)
                    if store.extensions.isEmpty {
                        Text("未发现任何扩展\n点右上角 + 导入")
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, source: ExtensionSource) -> some View {
        let items = store.extensions.filter { $0.source == source }
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CodexTheme.textMuted)
                        .padding(.leading, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    ForEach(items) { row($0) }
                }
            }
        }
    }

    private func row(_ item: ExtensionItem) -> some View {
        let selected = selectedPath == item.path
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: item.isBuiltIn ? "puzzlepiece.fill" : "puzzlepiece")
                    .font(.system(size: 10))
                    .foregroundStyle(item.isBuiltIn ? CodexTheme.accent : CodexTheme.textMuted)
                    .frame(width: 14)
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(item.enabled
                                     ? (selected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                                     : CodexTheme.textMuted)
                Spacer(minLength: 2)
                trailingBadge(item)
            }
            // P15.7: 这个扩展注册出来的工具 —— 缩进一行摆在它下面。
            // 「按需挂载」的扩展**没有开关**, 所以"它到底提供什么"必须从别处读得到;
            // 否则只能点进详情去读源码 (boss: 建议 note_proposal 在 plugins 里能找到)。
            ForEach(item.toolNames, id: \.self) { name in
                toolRow(name, selected: selected)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(selected ? CodexTheme.selected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .contentShape(Rectangle())
        .onTapGesture { selectedPath = item.path }
    }

    /// 行右侧那一格: 托管区给启停开关, 只读区给来源胶囊。
    ///
    /// ⚠️ 分派判据是**挂载策略** (`isOnDemand`), **不能只看 `isBuiltIn`**:
    ///   · 恒挂内置 (approval) → 禁用开关 + "不可停用" (**与 P3.11 一模一样, 一个字没动**)
    ///   · 按需挂载 (dream)    → 不给开关, 挂一颗胶囊 —— 给它开关就是**说谎**
    ///   · 普通托管            → 常规开关
    @ViewBuilder
    private func trailingBadge(_ item: ExtensionItem) -> some View {
        if item.source == .managed {
            if item.isOnDemand {
                Text("按需加载")
                    .font(.system(size: 9))
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CodexTheme.bgPill)
                    .clipShape(Capsule())
                    .help("App 内置扩展：只在需要它的那次运行里挂载，不是常开")
            } else {
                CodexMiniToggle(isOn: Binding(
                    get: { item.enabled },
                    set: { _ in store.toggleExtension(item) }
                ),
                disabled: item.isBuiltIn)   // 内置审批扩展恒开
                .help(LK(item.isBuiltIn ? "内置审批扩展, 不可停用" : "启停 (重启引擎生效)"))
            }
        } else {
            Text(item.source.label)
                .font(.system(size: 9))
                .foregroundStyle(CodexTheme.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(CodexTheme.bgPill)
                .clipShape(Capsule())
        }
    }

    /// 扩展行下面那一行工具名 (P15.7)。**刻意不做成可点的行** —— 它只是个名字, 点了没有去处,
    /// 做了交互反而像"能打开/能配置"。"按需挂载"那颗胶囊在**主行**右侧, 这里不重复挂。
    private func toolRow(_ name: String, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 9))
                .foregroundStyle(CodexTheme.textMuted)
                .frame(width: 14)
            Text(name)
                .font(CodexFonts.monoFont(10))
                .lineLimit(1)
                .foregroundStyle(selected ? CodexTheme.textSecondary : CodexTheme.textTertiary)
            Spacer(minLength: 2)
        }
        .padding(.leading, 11)   // 比主行图标再缩进一档 ⇒ 层级一眼看得出
    }

    // MARK: - 右侧详情

    private var selectedItem: ExtensionItem? {
        store.extensions.first { $0.path == selectedPath } ?? store.extensions.first
    }

    private var detailPane: some View {
        Group {
            if let item = selectedItem {
                detail(item)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "puzzlepiece")
                        .font(.system(size: 22))
                        .foregroundStyle(CodexTheme.textMuted)
                    Text("选择或导入一个插件")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detail(_ item: ExtensionItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                controlsRow(item)
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: Tune.knowledgeTitleFontSize, weight: .semibold))
                        .foregroundStyle(CodexTheme.textPrimary)
                    sourcePill(item)
                    if item.source != .managed {
                        Button("导入到托管区") { store.importExtension(at: URL(fileURLWithPath: item.path)) }
                            .buttonStyle(.plain)
                            .font(CodexTheme.fontSmall)
                            .foregroundStyle(CodexTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(CodexTheme.bgPill)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
                            .help("拷贝到 ~/.mangox/extensions (默认停用)")
                    }
                }
                pathRow(item)
                sourcePreview(item)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: Tune.extensionEditorMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func controlsRow(_ item: ExtensionItem) -> some View {
        HStack(spacing: 8) {
            Text("pi 扩展经 spawn 期 --extension 加载, 启停后需重启引擎生效")
                .font(CodexTheme.fontTiny)
                .foregroundStyle(CodexTheme.textMuted)
            Spacer()
            if store.extensionsDirty {
                Button("重启引擎生效") { store.restartEngine() }
                    .buttonStyle(CodexActionButtonStyle(kind: .primary))
                    .help("重启 pi 进程以加载最新的启用列表")
            }
            if selectedItem?.source == .managed, !(selectedItem?.isBuiltIn ?? true) {
                Button {
                    confirmDelete = selectedItem
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("删除")
                    }
                }
                .buttonStyle(CodexActionButtonStyle(kind: .danger))
                .help("从托管区删除")
            }
        }
    }

    private func sourcePill(_ item: ExtensionItem) -> some View {
        Text(item.source.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(CodexTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(CodexTheme.bgPill)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(CodexTheme.border.opacity(0.4), lineWidth: 1))
    }

    private func pathRow(_ item: ExtensionItem) -> some View {
        Text(item.path)
            .font(CodexFonts.monoFont(10))
            .foregroundStyle(CodexTheme.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    /// 源码只读预览 (白卡细描边, monospaced)
    private func sourcePreview(_ item: ExtensionItem) -> some View {
        let source = store.extensionSource(item)
        return ZStack(alignment: .topLeading) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(CodexFonts.monoFont(11))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minWidth: 600, alignment: .leading)
            }
            .frame(minHeight: 320, maxHeight: .infinity)
            if source.isEmpty {
                Text("// 无法读取源码")
                    .font(CodexFonts.monoFont(11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(.leading, 12)
                    .padding(.top, 10)
            }
        }
        .background(CodexTheme.bgComposer)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusLg)
                .stroke(CodexTheme.border.opacity(0.45), lineWidth: 1)
        )
    }
}
