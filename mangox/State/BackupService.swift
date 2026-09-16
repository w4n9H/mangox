//
//  BackupService.swift
//  P9.1d: 手动备份域自 ChatStore 抽离 (P8-T28: 目录 KV/同步+后台两版/摘要 KV)。
//  拆分不动行为: ChatStore 保留同名 facade 转发 (冒烟/视图零改动);
//  服务持有 store 弱引用, checkpoint/dbPath 经 store.persistence 回调。
//

import Foundation
import Combine

@MainActor
final class BackupService: ObservableObject {

    /// P8-T28: 备份目录 (settings KV backup_dir) 与上次备份摘要 (backup_last)。
    @Published var backupDirectory: String?
    @Published var lastBackupSummary: String?
    @Published var backupRunning = false
    /// 备份失败细节 (设置页弹窗; P9-#11)。
    @Published var backupFailureMessage: String?

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) { self.store = store }

    /// 记忆备份目录 (Settings 选择时调用)。
    func setBackupDirectory(_ path: String) {
        backupDirectory = path
        store?.persistence?.saveSettingText(key: "backup_dir", value: path)
    }

    /// 手动备份: checkpoint → db + attachments + sessions 直拷到
    /// <destRoot>/mangox-backup-<时间戳>/; 结果摘要落 KV 供重启后展示。
    /// 同步版 (冒烟 T28 直测; UI 走 performManualBackupInBackground)。
    @discardableResult
    func performManualBackup(destRoot: String, now: Date = .now) -> BackupOutcome {
        guard !backupRunning else {
            return BackupOutcome(errors: ["备份已在进行中"])
        }
        backupRunning = true
        defer { backupRunning = false }
        let outcome = BackupEngine.backup(
            dbPath: store?.persistence?.path ?? BackupEngine.defaultDBPath,
            attachmentsDir: BackupEngine.defaultAttachmentsDir,
            sessionsDir: BackupEngine.defaultSessionsDir,
            destRoot: destRoot,
            checkpoint: { [weak self] in self?.store?.persistence?.checkpoint() },
            now: now)
        applyBackupOutcome(outcome, now: now)
        return outcome
    }

    /// P9-#11: UI 入口 — checkpoint 后在后台线程拷贝, 大附件库不再冻结主线程。
    /// 完成回主线程刷摘要; 失败细节落 backupFailureMessage 供设置页弹窗。
    func performManualBackupInBackground(destRoot: String, now: Date = .now) {
        guard let store, !backupRunning else { return }
        backupRunning = true
        store.persistence?.checkpoint()   // WAL 落盘必须在拷贝前 (主线程串行完成)
        let dbPath = store.persistence?.path ?? BackupEngine.defaultDBPath
        Task.detached { [weak self] in
            let outcome = BackupEngine.backup(
                dbPath: dbPath,
                attachmentsDir: BackupEngine.defaultAttachmentsDir,
                sessionsDir: BackupEngine.defaultSessionsDir,
                destRoot: destRoot,
                checkpoint: nil,
                now: now)
            // guard let 提前定强引用: 嵌套 MainActor.run 再捕 weak var 'self' 会触发
            // "captured var 'self' in concurrently-executing code" (Swift 6 下是 error)
            guard let self else { return }
            await MainActor.run { self.applyBackupOutcome(outcome, now: now, clearRunning: true) }
        }
    }

    /// 摘要落 KV + 失败细节发布 (同步/后台两路共用)。
    private func applyBackupOutcome(_ outcome: BackupOutcome, now: Date, clearRunning: Bool = false) {
        let summary: String
        if outcome.ok {
            let size = ByteCountFormatter.string(fromByteCount: outcome.totalBytes, countStyle: .file)
            let f = DateFormatter()
            f.dateFormat = "M/d HH:mm"
            summary = "✓ \(f.string(from: now)) · \(size)"
        } else {
            summary = "✗ " + (outcome.errors.first ?? "未知失败")
        }
        lastBackupSummary = summary
        store?.persistence?.saveSettingText(key: "backup_last", value: summary)
        backupFailureMessage = outcome.ok ? nil : outcome.errors.joined(separator: "\n")
        if clearRunning { backupRunning = false }
    }
}
