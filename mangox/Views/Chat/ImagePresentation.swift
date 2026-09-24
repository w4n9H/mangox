//
//  ImagePresentation.swift
//  本机图片文件的**共用**呈现逻辑: 路径解析 / 像素上限 / 说明行 / 大图 sheet。
//
//  ⚠️ 单一来源。两个消费方 (`MarkdownImageView` 渲染正文里的图片块 · `ToolOutputImages`
//  渲染工具产出的图片) **必须**共用这一份 —— "如何解析一个本地图片路径"和"大图能放多大"
//  各写一份必然漂移, 症状是同一个路径在正文里能显示、在工具卡里报"无法读取"。
//

import AppKit
import SwiftUI

enum ImagePresentation {
    /// 行内/卡内展示的高度上限 (高图不把面板撑满); 宽度由列宽决定, 不另行限制。
    static let displayMaxHeight: CGFloat = 360
    static let fullMaxWidth: CGFloat = 900
    static let fullMaxHeight: CGFloat = 620

    /// 解析成**绝对**本地路径。nil = 不可解析 (外链 / 相对路径但没有基准)。
    /// 相对路径的基准 = 会话绑定的项目目录; 不给基准时**不猜** (交给调用方照实报错)。
    static func resolvedPath(_ source: String, basePath: String?) -> String? {
        if isRemote(source) { return nil }
        var s = source
        if s.lowercased().hasPrefix("file://") {
            guard let url = URL(string: s), url.isFileURL else { return nil }
            s = url.path
        }
        if s.hasPrefix("~") { s = NSHomeDirectory() + String(s.dropFirst()) }
        if s.hasPrefix("/") { return s }
        guard let base = basePath, !base.isEmpty else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent(s).standardized.path
    }

    /// 带 scheme 且 scheme 非 `file` = 外链 (应用内不抓取, 只照实说明)。
    static func isRemote(_ source: String) -> Bool {
        guard let scheme = URL(string: source)?.scheme, scheme.count > 1 else { return false }
        return scheme.lowercased() != "file"
    }

    /// 原图像素宽 (小图不放大); 拿不到像素尺寸时退回点尺寸, 再退回一个足够大的数。
    static func naturalCap(_ img: NSImage) -> CGFloat {
        if let rep = img.representations.first, rep.pixelsWide > 0 {
            return CGFloat(rep.pixelsWide)
        }
        return img.size.width > 0 ? img.size.width : 4000
    }

    /// `文件名 · 宽×高` —— 无汉字, 调用方用 `Text(verbatim:)` (不被当成 LocalizedStringKey)。
    static func caption(_ path: String, _ img: NSImage) -> String {
        let name = (path as NSString).lastPathComponent
        guard let rep = img.representations.first, rep.pixelsWide > 0 else { return name }
        return "\(name) · \(rep.pixelsWide)×\(rep.pixelsHigh)"
    }
}

/// 单张本机图片的大图 sheet。`path` 已是绝对路径 (调用方负责用
/// `ImagePresentation.resolvedPath` 解析并确认可读)。
struct ImageFullSheet: View {
    let path: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let img = ImagePipeline.cachedImage(atPath: path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: ImagePresentation.fullMaxWidth,
                           maxHeight: ImagePresentation.fullMaxHeight)
                Text(verbatim: ImagePresentation.caption(path, img))
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
            } else {
                Text("无法读取图片文件")
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textMuted)
                    .padding(40)
            }
            Button("关闭", action: onClose)
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(CodexTheme.bgBase)
        .contentShape(Rectangle())
        // 点空白处关闭 (Button 自己吃掉点按, 不会被这层抢走)
        .onTapGesture { onClose() }
    }
}
