//
//  BackupEngine.swift
//  P8-T28 手动备份: WAL checkpoint 后把 db 主文件 + attachments + sessions 目录
//  直拷到 <destRoot>/mangox-backup-<yyyyMMdd-HHmmss>/。立场: 目录直拷, 不压缩不增量;
//  失败逐项报告不半途抛错 (附件/会话目录缺失 = 容错跳过, 不算失败)。
//

import Foundation

struct BackupOutcome: Equatable {
    var destPath: String = ""
    var dbCopied = false
    /// false 含"源缺失跳过"与"拷贝失败"两种 (区分看 errors)
    var attachmentsCopied = false
    var sessionsCopied = false
    var totalBytes: Int64 = 0
    var errors: [String] = []

    /// 备份成立的最低标准: 主库到位且无硬错误
    var ok: Bool { dbCopied && errors.isEmpty }
}

enum BackupEngine {

    static var defaultDBPath: String { NSHomeDirectory() + "/.mangox/mangox.db" }
    static var defaultAttachmentsDir: String { NSHomeDirectory() + "/.mangox/attachments" }
    static var defaultSessionsDir: String { NSHomeDirectory() + "/.mangox/pi-sessions" }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// checkpoint 先行 (WAL 落主文件) → 拷 db → 递归拷两个目录 → 汇总大小。
    static func backup(dbPath: String,
                       attachmentsDir: String?,
                       sessionsDir: String?,
                       destRoot: String,
                       checkpoint: (() -> Void)? = nil,
                       now: Date = .now,
                       fileManager: FileManager = .default) -> BackupOutcome {
        var out = BackupOutcome()
        checkpoint?()

        let dest = URL(fileURLWithPath: destRoot)
            .appendingPathComponent("mangox-backup-\(stampFormatter.string(from: now))")
        out.destPath = dest.path
        do {
            try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            out.errors.append(String(format: L("创建备份目录失败: %@"), error.localizedDescription))
            return out
        }

        // 1. db 主文件 (checkpoint TRUNCATE 后 -wal 已清零, 不拷侧车文件)
        guard fileManager.fileExists(atPath: dbPath) else {
            out.errors.append(String(format: L("数据库文件缺失: %@"), dbPath))
            return out
        }
        do {
            try fileManager.copyItem(atPath: dbPath,
                                     toPath: dest.appendingPathComponent("mangox.db").path)
            out.dbCopied = true
        } catch {
            out.errors.append(String(format: L("数据库拷贝失败: %@"), error.localizedDescription))
            return out
        }

        // 2/3. attachments / sessions 递归直拷 (源缺失 = nil 容错跳过)
        out.attachmentsCopied = copyDir(attachmentsDir, name: "attachments",
                                        dest: dest, fileManager: fileManager, out: &out)
        out.sessionsCopied = copyDir(sessionsDir, name: "sessions",
                                     dest: dest, fileManager: fileManager, out: &out)

        out.totalBytes = directorySize(at: dest, fileManager: fileManager)
        return out
    }

    /// 单目录递归拷贝: 源缺失返回 false (容错), 拷贝失败记入 errors。
    private static func copyDir(_ src: String?, name: String,
                                dest: URL, fileManager: FileManager,
                                out: inout BackupOutcome) -> Bool {
        guard let src, fileManager.fileExists(atPath: src) else { return false }
        do {
            try fileManager.copyItem(atPath: src,
                                     toPath: dest.appendingPathComponent(name).path)
            return true
        } catch {
            out.errors.append(String(format: L("%@ 拷贝失败: %@"), name, error.localizedDescription))
            return false
        }
    }

    static func directorySize(at url: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        let en = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = en?.nextObject() as? URL {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
