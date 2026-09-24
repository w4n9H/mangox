//
//  MarkdownImageView.swift
//  markdown 图片块 (整行 `![]()`): 本地文件就地渲染, 点击看大图。
//

import AppKit
import SwiftUI

/// 渲染一张 markdown 图片。
///
/// **只加载本地文件** —— 外链 (http/https) 不在这里抓取: 渲染是在滚动/流式里**反复发生**的动作,
/// 让它发网络请求等于把"滚动"变成"网络 IO"队列, 且模型给的 URL 未必可信。
/// 外链给一行照实说明的提示 (含原 URL, 可选中复制), 不静默吞掉。
///
/// 路径解析 / 像素上限 / 说明行 / 大图 sheet 全部来自 `ImagePresentation` —— **与工具产出图片
/// (ToolOutputImages) 同一份实现**, 不许在本文件里再抄一套。
struct MarkdownImageView: View {
    let alt: String
    let source: String
    /// 相对路径的解析基准 = 会话绑定的项目目录。不给 ⇒ 相对路径判为不可解析 (照实报错)。
    var basePath: String? = nil

    @State private var showFull: Bool = false

    var body: some View {
        content.sheet(isPresented: $showFull) { fullView }
    }

    @ViewBuilder
    private var content: some View {
        if ImagePresentation.isRemote(source) {
            notice("link", LK("外链图片不在应用内加载"), detail: source)
        } else if let path = resolvedPath {
            if let img = ImagePipeline.cachedImage(atPath: path) {
                card(img, path: path)
            } else {
                notice("photo.badge.exclamationmark", LK("无法读取图片文件"), detail: path)
            }
        } else {
            notice("photo.badge.exclamationmark", LK("无法读取图片文件"), detail: source)
        }
    }

    // MARK: - 加载态

    private func card(_ img: NSImage, path: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // `maxWidth` 只封顶**放大** (小图不被拉糊), 不阻止缩小 —— 父级提案更小时仍取提案,
                // 所以宽图会被缩到列宽而不是溢出去。`maxHeight` 管高图。
                .frame(maxWidth: ImagePresentation.naturalCap(img),
                       maxHeight: ImagePresentation.displayMaxHeight,
                       alignment: .leading)
                .accessibilityLabel(Text(verbatim: alt.isEmpty ? path : alt))
            Text(verbatim: ImagePresentation.caption(path, img))
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // 卡面撑满列宽 (图仍靠左)
        .padding(8)
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radius)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { showFull = true }
        .help("点击查看大图")
    }

    /// 失败 / 未加载: 与图片卡同款外形, 一行说明 + 原字符串 (可选中, 便于自己去找文件)。
    private func notice(_ symbol: String, _ title: LocalizedStringKey, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
            Text(title)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textSecondary)
                .fixedSize()
            Text(verbatim: detail)
                .font(CodexTheme.fontMonoXs)
                .foregroundStyle(CodexTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CodexTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 大图 sheet

    @ViewBuilder
    private var fullView: some View {
        if let path = resolvedPath {
            ImageFullSheet(path: path) { showFull = false }
        } else {
            Text("无法读取图片文件")
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textMuted)
                .padding(40)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(CodexTheme.bgBase)
                .onTapGesture { showFull = false }
        }
    }

    /// nil = 不是可解析的本地路径 (外链 / 相对路径且无基准)。
    private var resolvedPath: String? {
        ImagePresentation.resolvedPath(source, basePath: basePath)
    }
}
