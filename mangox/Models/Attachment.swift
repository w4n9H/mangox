//
//  Attachment.swift
//  P7-M6: 用户消息图片附件 (落盘路径 + 像素尺寸 + mime, 不存 BLOB)。
//  随 ChatMessage JSON 进 events 表持久化; 可选字段兼容旧 payload (缺 key → nil)。
//

import Foundation

struct Attachment: Hashable, Codable, Identifiable {
    let id: UUID
    /// ~/.mangox/attachments/<sessionId>/<uuid>.<ext> (原图留档)。
    let path: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// image/jpeg / image/png / image/gif / image/webp / image/heic。
    let mimeType: String
    let byteSize: Int

    /// 发送门控/气泡缩略共用的文件名。
    var fileName: String { (path as NSString).lastPathComponent }

    init(id: UUID = UUID(), path: String, pixelWidth: Int, pixelHeight: Int,
         mimeType: String, byteSize: Int) {
        self.id = id
        self.path = path
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mimeType = mimeType
        self.byteSize = byteSize
    }
}

/// P7-M6b: composer 暂存区条目 (内存原图, 发送时落盘 + 压缩 + 进 RPC images)。
struct PendingImage: Identifiable, Hashable {
    let id: UUID
    let data: Data
    let fileExtension: String
    let pixelWidth: Int
    let pixelHeight: Int

    var mimeType: String { ImagePipeline.mimeType(forExtension: fileExtension) }
}
