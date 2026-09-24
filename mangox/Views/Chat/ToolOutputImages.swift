//
//  ToolOutputImages.swift
//  工具产出图片的缩略条 (pi 工具结果 `AgentToolResult.content[]` 里的 base64 image 块)。
//
//  呈现口径与正文图片块同源 (`ImagePresentation`): 同一套路径解析 / 说明行 / 大图上限。
//  只是排布不同 —— 工具可能一次产出多张, 故横排缩略、点开看大图。
//

import AppKit
import SwiftUI

struct ToolOutputImages: View {
    let paths: [String]

    @State private var fullPath: String?

    private static let thumbHeight: CGFloat = 84
    private static let thumbMaxWidth: CGFloat = 200

    var body: some View {
        // 横滚: 多图时不换行把卡片撑高。每张的上限是 `thumbMaxWidth × thumbHeight` +
        // `aspectRatio(.fit)` ⇒ 高图矮图都以 84 为高、按自身比例定宽 (不会被均分压扁)。
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(paths, id: \.self) { path in
                    thumb(path)
                }
            }
        }
        .sheet(item: Binding(
            get: { fullPath.map(ImageSheetItem.init(path:)) },
            set: { fullPath = $0?.path }
        )) { item in
            ImageFullSheet(path: item.path) { fullPath = nil }
        }
    }

    @ViewBuilder
    private func thumb(_ raw: String) -> some View {
        // 工具给的路径本来就是绝对路径 (ImagePipeline.saveOriginal 产出); 仍过一遍统一解析,
        // 让 `file://` / `~` 这类形态与正文图片块**同一套口径**。
        if let path = ImagePresentation.resolvedPath(raw, basePath: nil),
           let img = ImagePipeline.cachedImage(atPath: path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Self.thumbMaxWidth, maxHeight: Self.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))
                .overlay(
                    RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                        .stroke(CodexTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { fullPath = path }
                .help(LK("点击查看大图"))
        } else {
            // 读不到就照实说 —— 不静默留白 (留白会让人以为是渲染 bug)
            HStack(spacing: 5) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 10))
                Text(verbatim: (raw as NSString).lastPathComponent)
                    .font(CodexTheme.fontMonoXs)
                    .lineLimit(1)
            }
            .foregroundStyle(CodexTheme.textMuted)
            .padding(.horizontal, 8)
            .frame(height: Self.thumbHeight)
            .overlay(
                RoundedRectangle(cornerRadius: CodexTheme.radiusSm)
                    .stroke(CodexTheme.border, lineWidth: 1)
            )
        }
    }
}

/// `sheet(item:)` 需要 Identifiable; 直接用裸 String 包一层。
private struct ImageSheetItem: Identifiable {
    let path: String
    var id: String { path }
}
