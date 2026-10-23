//
//  FilePreviewView.swift
//  工作区「预览」tab: 读磁盘真实内容, 文本按行懒加载 / 图片直接渲染。
//
//  预览性能改造 —— 原来的实现是 `Text(整篇高亮结果).fixedSize(...)`, 一个 `Text` 承载
//  整块文本, SwiftUI 的文本布局是**平方级**的。实测 (同机、同字体、真 CodeHighlighter):
//
//      文件大小 / 行数        旧 (单 Text)   新 (逐行 Lazy + 预宽)
//        4 KB /   98 行           138 ms            11 ms
//       20 KB /  438 行          1227 ms             8 ms
//       50 KB / 1095 行          6429 ms             7 ms
//      115 KB / 2521 行        35053 ms             8 ms
//
//  代价说明 (有意的取舍, 不是疏漏):
//   · 逐行 `Text` ⇒ **跨行拖选不存在了** (每一行是独立的可选文本)。整篇复制的需求由头上
//     那个「复制全文」按钮承担 —— 比拖选更直接。
//   · 宽度必须**先按最长行定死**, 否则 LazyVStack 的懒加载会退化 (滚动范围每帧都在变)。
//

import AppKit
import SwiftUI

/// 能直接按图片渲染的扩展名 (预览分支与文案回落共用一份, 免得两处清单漂移)。
private let previewImageExts: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "icns",
]

/// 与 `CodexFonts.monoFont(Tune.workspacePreviewFontSize)` 对应的 AppKit 字体 —— **量宽度与
/// 画出来必须是同一个字体**。⚠️ 私有系统名 (`.SF Mono`) 建不出 `NSFont` ⇒ 必须回落到等宽
/// 系统字体, 否则量出来的宽度和画出来的对不上。
private let previewNSFont: NSFont =
    NSFont(name: CodexFonts.monoName, size: Tune.workspacePreviewFontSize)
    ?? NSFont.monospacedSystemFont(ofSize: Tune.workspacePreviewFontSize, weight: .regular)

struct FilePreviewView: View {
    let rootPath: String
    let relativePath: String

    @State private var model: PreviewModel? = nil
    @State private var image: NSImage? = nil
    @State private var meta: String? = nil
    @State private var copied: Bool = false

    private var absolutePath: String {
        URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath).path
    }

    private var fileName: String {
        relativePath.components(separatedBy: "/").last ?? relativePath
    }

    private var fileExt: String { (fileName as NSString).pathExtension.lowercased() }

    private var language: String? {
        switch fileExt {
        case "glsl", "frag", "vert": return "glsl"
        case "js", "mjs":            return "javascript"
        case "ts":                   return "typescript"
        case "json":                 return "json"
        case "py":                   return "python"
        case "sh":                   return "bash"
        case "swift":                return "swift"
        default:                     return nil
        }
    }

    // MARK: - 度量 (真字体; 数字只住 Tune)

    /// 单行行高: 定死它, 懒加载的高度估算才是准的 (空行也占一格)。
    private static let rowHeight: CGFloat = {
        let f = previewNSFont
        return ceil(f.ascender - f.descender + f.leading)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let image {
                imageBody(image)
            } else if let model {
                if let notice = model.notice {
                    noticeBody(notice)
                } else {
                    codeBody(model)
                }
            } else {
                // 载入中 (通常是几十毫秒): 留白而不是转圈, 免得大文件每次打开都闪一下
                Spacer().frame(maxHeight: .infinity)
            }
        }
        .task(id: absolutePath) { await load() }
    }

    // MARK: - Header (文件名 + 路径 + 复制 + 语言/元信息)

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(fileName)
                    .font(CodexTheme.fontMonoSm)
                    .foregroundStyle(CodexTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                copyButton
                Text(previewImageExts.contains(fileExt) ? fileExt : (language ?? "text"))
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textTertiary)
            }
            HStack(spacing: 6) {
                Text(absolutePath)
                    .font(CodexTheme.fontTiny)
                    .foregroundStyle(CodexTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if let meta {
                    Text(meta)
                        .font(.system(size: 9))
                        .foregroundStyle(CodexTheme.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .bottom
        )
    }

    /// 「复制全文」 —— 逐行渲染之后跨行拖选没了, 整篇拿走靠这个。
    @ViewBuilder
    private var copyButton: some View {
        if let m = model, m.notice == nil, !m.raw.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.raw, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copied ? CodexTheme.toolDone : CodexTheme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? L("已复制") : L("复制全文"))
        }
    }

    // MARK: - Body 三种形态

    private func noticeBody(_ notice: String) -> some View {
        Text(notice)
            .font(CodexTheme.fontMonoXs)
            .foregroundStyle(CodexTheme.textMuted)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func imageBody(_ image: NSImage) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Tune.workspacePreviewImageMaxSide,
                       maxHeight: Tune.workspacePreviewImageMaxSide)
                .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    private func codeBody(_ m: PreviewModel) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(m.lines.indices, id: \.self) { i in
                    Text(m.lines[i])
                        .font(CodexFonts.monoFont(Tune.workspacePreviewFontSize))
                        .foregroundStyle(CodexTheme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: Self.rowHeight, alignment: .topLeading)
                }
            }
            .frame(width: m.contentWidth, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 载入

    private func load() async {
        let path = absolutePath
        let ext = fileExt
        let lang = language
        model = nil
        let built = await Task.detached(priority: .userInitiated) {
            PreviewModel.make(absolutePath: path, ext: ext, language: lang)
        }.value
        // 快速连点文件时, 后到的旧结果不许盖掉新的
        guard absolutePath == path else { return }
        model = built
        image = Self.loadImage(absolutePath: path, ext: ext)
        meta = Self.fileMeta(absolutePath: path)
    }

    /// 能按图片渲染时给出 `NSImage`; 非图片 / 超过 40 MB / 读不出来 → nil, 回落文本占位。
    private static func loadImage(absolutePath: String, ext: String) -> NSImage? {
        guard previewImageExts.contains(ext) else { return nil }
        guard let attr = try? FileManager.default.attributesOfItem(atPath: absolutePath),
              let size = attr[.size] as? Int, size <= 40_000_000 else { return nil }
        return NSImage(contentsOfFile: absolutePath)
    }

    /// 文件元信息: 大小 + 修改时间。**一次算好存 `@State`** —— 原来是 computed, 每帧 stat 一次
    /// 外加新建一个 `DateFormatter`。
    private static func fileMeta(absolutePath: String) -> String? {
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
}

// MARK: - 预览内容 (一次载入, 之后只读)

private struct PreviewModel {
    var lines: [AttributedString] = []
    var raw: String = ""
    /// 可见内容宽度 (按最长行预量)。**不预量 ⇒ 懒加载退化** (见文件头实测表)。
    var contentWidth: CGFloat = 0
    /// 非 nil = 不按行渲染, 直接显示这句占位文案。
    var notice: String? = nil

    /// 在后台线程跑: 读盘 + 整篇高亮 (线性, 115 KB 约 21 ms) + 切行 + 量宽度。
    static func make(absolutePath: String, ext: String, language: String?) -> PreviewModel {
        let fm = FileManager.default
        guard let attr = try? fm.attributesOfItem(atPath: absolutePath),
              let size = attr[.size] as? Int else {
            return PreviewModel(notice: L("// 二进制文件或暂不支持的编码"))
        }
        guard size <= 1_000_000 else {
            return PreviewModel(notice: L("// 文件过大 (>1 MB), 暂不支持预览"))
        }
        if previewImageExts.contains(ext) {
            return PreviewModel(notice: String(format: L("// 图片 (%@) 读取失败或超过 40 MB"), ext))
        }
        if ext == "pdf" { return PreviewModel(notice: L("// PDF 暂不支持预览")) }
        guard let raw = try? String(contentsOfFile: absolutePath, encoding: .utf8) else {
            return PreviewModel(notice: L("// 二进制文件或暂不支持的编码"))
        }
        guard !raw.isEmpty else { return PreviewModel(notice: L("// 空文件")) }

        // 整篇高亮**一次**, 再切行 —— 逐行重新高亮会把跨行的块注释从中截断
        // (正则带 `.dotMatchesLineSeparators`, `/* … */` 是要跨行的)。
        let highlighted = CodeHighlighter.highlight(raw, language: language)
        return PreviewModel(lines: splitLines(highlighted, raw: raw),
                            raw: raw,
                            contentWidth: measureWidth(raw: raw),
                            notice: nil)
    }

    /// 按行切, **属性原样带过去**。走 `NSString.lineRange` (C 实现) 而不是逐字符走
    /// AttributedString 索引 —— 后者在 10 万字符上是能测出来的。
    private static func splitLines(_ attr: AttributedString, raw: String) -> [AttributedString] {
        let ns = raw as NSString
        var out: [AttributedString] = []
        out.reserveCapacity(ns.length / 32 + 8)
        var loc = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            var textRange = lineRange
            // 去掉行尾的 \n / \r\n: 每行就得是真的一行, 否则 Text 里会多出一个空行
            while textRange.length > 0 {
                let last = ns.character(at: NSMaxRange(textRange) - 1)
                if last == 10 || last == 13 { textRange.length -= 1 } else { break }
            }
            if let r = Range(textRange, in: attr) {
                out.append(AttributedString(attr[r]))
            } else {
                out.append(AttributedString())
            }
            loc = NSMaxRange(lineRange)
        }
        if out.isEmpty { out.append(AttributedString()) }
        return out
    }

    /// 逐行量真宽度取最大值 —— 不按"字数"猜: 一个汉字在等宽字体里占两格, 制表符更宽。
    /// 只跑一次 (载入时), 2500 行约 20~40 ms, 在后台线程。
    private static func measureWidth(raw: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: previewNSFont]
        var maxW: CGFloat = 0
        raw.enumerateLines { line, _ in
            guard !line.isEmpty else { return }
            let w = (line as NSString).size(withAttributes: attrs).width
            if w > maxW { maxW = w }
        }
        return maxW + 20
    }
}
