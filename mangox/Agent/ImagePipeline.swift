//
//  ImagePipeline.swift
//  P7-M6: 图片附件管线 — 识别/落盘/发送压缩/清理。
//  契约: images.autoResize 不覆盖 RPC base64 → 客户端必压 (长边 ≤1536, JPEG q0.8)。
//  磁盘存原图, 发送压副本 (base64 只活一次)。
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AppKit

enum ImagePipeline {
    static let maxSendSide: CGFloat = 1536
    static let jpegQuality = 0.8
    static let maxPerMessage = 4   // 防单条 RPC base64 撑爆 (4×1536px ≈ 2-4MB)

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    static func isImageExtension(_ ext: String) -> Bool {
        imageExtensions.contains(ext.lowercased())
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "tiff": "image/tiff"
        default: "application/octet-stream"
        }
    }

    // MARK: - 像素尺寸 (读元数据, 不解码全图)

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (w, h)
    }

    /// 剪贴板取图 (⌘V 拦截统一入口): png/tiff 直取; Finder 拷贝的图片文件走 fileURL。
    /// nil = 剪贴板无图片 (放行常规文本粘贴)。
    static func pasteboardImage() -> (data: Data, ext: String)? {
        let pb = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let d = pb.data(forType: type) {
                return (d, sniffExtension(d) ?? (type == .png ? "png" : "tiff"))
            }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first,
           isImageExtension(url.pathExtension),
           let d = try? Data(contentsOf: url) {
            return (d, url.pathExtension.lowercased())
        }
        return nil
    }

    /// 从图片数据嗅探扩展名 (剪贴板/拖拽没有文件名; nil = 非图片或未知格式)。
    static func sniffExtension(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(src) as String?,
              let t = UTType(uti) else { return nil }
        return t.preferredFilenameExtension
    }

    // MARK: - 发送压缩 (JPEG q0.8, 长边 ≤1536; 已小于上限的位图仍统一转 JPEG 压体积)

    static func compressForSend(_ data: Data,
                                maxSide: CGFloat = ImagePipeline.maxSendSide,
                                quality: Double = ImagePipeline.jpegQuality)
        -> (data: Data, width: Int, height: Int, mimeType: String)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        let scale = min(1, maxSide / CGFloat(max(w, h)))
        var out = image
        var ow = w, oh = h
        if scale < 1 {
            ow = max(1, Int((CGFloat(w) * scale).rounded()))
            oh = max(1, Int((CGFloat(h) * scale).rounded()))
            // noneSkipLast: JPEG 不带 alpha, 目标位图必须无 alpha 通道
            guard let ctx = CGContext(data: nil, width: ow, height: oh,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: ow, height: oh))
            guard let scaled = ctx.makeImage() else { return nil }
            out = scaled
        }
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buf, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (buf as Data, ow, oh, UTType.jpeg.preferredMIMEType ?? "image/jpeg")
    }

    /// 发送字节决策 (纯函数): png/gif/webp 且未超长边上限 → 原样透传 (保动图/透明通道);
    /// 其余 (jpg/heic/tiff/超限位图) → 压缩 JPEG 副本。nil = 无法产出可发送字节。
    static func outgoingPayload(data: Data, ext: String, pixelWidth: Int, pixelHeight: Int)
        -> (data: Data, mimeType: String)? {
        let passthrough = ["png", "gif", "webp"].contains(ext.lowercased())
            && CGFloat(max(pixelWidth, pixelHeight)) <= maxSendSide
        if passthrough {
            return (data, mimeType(forExtension: ext))
        }
        guard let c = compressForSend(data) else { return nil }
        return (c.data, c.mimeType)
    }

    // MARK: - 落盘 (原图留档; baseDirectory 冒烟注入用, 默认 ~/.mangox/attachments)

    /// 冒烟注入: **进程级**重定向附件根目录 (在 `run()` 起手设一次)。
    ///
    /// ⚠️ 为什么必须是进程级: `baseDirectory:` 是**函数级**参数, 只有显式传它的调用点才受控。
    /// 生产路径 (`ChatStore` 落用户贴的图 · `PiRpcTransport` 落工具产出的图) 都不传这个参数 ⇒
    /// 夹具会写进用户**真实**的 `~/.mangox/attachments/`, 而且**零红灯**。
    /// 同一类失效在本项目已经实锤过一次 (KnowledgeStore 的 L1 落盘), 故照抄「进程级 override +
    /// 守卫断言」这一套, 不再靠各处自觉。
    nonisolated(unsafe) static var attachmentsRootOverride: URL?

    /// 当前生效的附件根 (随 override 变化; 守卫断言读它 —— **政策与解析拆开**, 否则守卫变自证)。
    static var attachmentsRoot: URL {
        attachmentsRootOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".mangox/attachments", isDirectory: true)
    }

    static func attachmentsDirectory(sessionID: UUID, baseDirectory: URL? = nil) -> URL {
        (baseDirectory ?? attachmentsRoot)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    @discardableResult
    static func saveOriginal(_ data: Data, fileExtension ext: String, sessionID: UUID,
                             baseDirectory: URL? = nil) throws -> (path: String, byteSize: Int) {
        let dir = attachmentsDirectory(sessionID: sessionID, baseDirectory: baseDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext.lowercased())")
        try data.write(to: url, options: .atomic)
        return (url.path, data.count)
    }

    /// 删会话清附件目录 (调用方必须已从 messages 行读出路径 — 先读后删)。
    /// 返回失败原因 (discardable: 调用方通常不关心; 冒烟诊断用)。
    @discardableResult
    static func removeSessionAttachments(sessionID: UUID, baseDirectory: URL? = nil) -> Error? {
        do {
            try FileManager.default.removeItem(at: attachmentsDirectory(sessionID: sessionID, baseDirectory: baseDirectory))
            return nil
        } catch {
            return error
        }
    }

    // MARK: - P9-#12 缩略图缓存
    // NSImage(contentsOfFile:) 每次渲染全图解码 + 磁盘 IO; 历史消息滚动/流式重算反复付这笔钱。
    // NSCache 按路径缓存解码结果, 内存压力下自动逐出 (countLimit 100)。

    private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 100
        return c
    }()

    /// 解码并缓存图片; nil = 文件不存在/非图。命中后同一路径不再重复 IO。
    static func cachedImage(atPath path: String) -> NSImage? {
        if let hit = thumbCache.object(forKey: path as NSString) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        thumbCache.setObject(img, forKey: path as NSString)
        return img
    }
}
