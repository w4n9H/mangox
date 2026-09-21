//
//  CurlMailTransport.swift
//  P10.2c: MailTransport 的生产实现 —— 封装系统 curl (imaps 收 / smtps 发)。
//  每个 IMAP 动作 = 一个 curl 进程 (curl 的 `-X` 不支持复合命令, 拆不开就只能多跑一次)。
//  ⚠️ 例外: **取信必须走内置 `;UID=` 路径** —— `-X` 形态下 curl 不读字面量, 拿不到邮件正文
//  (实测见 CurlMailCommand.fetchMessage 注释, 2026-09-20)。
//  进程执行通过 CurlRunner 注入: 冒烟可断言完整 argv 序列而不连真网。
//

import Foundation

/// curl 进程执行缝 (生产 = ProcessCurlRunner; 测试 = 脚本化 runner)。
protocol CurlRunner: AnyObject {
    /// stdout 必须由实现方按 **Latin1 无损解码** (IMAP 字面量的 `{n}` 是字节数)。
    func run(_ arguments: [String], stdin: Data?) async throws -> (exitCode: Int32, stdout: String, stderr: String)
}

final class ProcessCurlRunner: CurlRunner {
    func run(_ arguments: [String], stdin: Data?) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await Task.detached(priority: .utility) { () -> (Int32, String, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CurlMailCommand.binary)
            process.arguments = arguments
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe

            try process.run()
            if let stdin {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            }
            try? inPipe.fileHandleForWriting.close()
            // 先读到 EOF 再 wait (否则子进程写满管道缓冲会僵住)
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(data: outData, encoding: .isoLatin1) ?? "",
                    String(data: errData, encoding: .utf8) ?? "")
        }.value
    }
}

@MainActor
final class CurlMailTransport: MailTransport {
    let accountId: UUID
    /// 移入的垃圾箱名**候选** —— 服务端文件夹名是语言/实现相关的, 硬编码单个名字不可靠:
    /// QQ 实测是 `Deleted Messages` (2026-09-20 `LIST "" "*"` 探到; 且 **QQ 不返回 `\Trash` 特殊用途标志**,
    /// 无法运行时判定), 163/126 习惯用中文 `已删除`。逐个试, 第一个成功的即止 (失败的 COPY 无副作用)。
    var trashCandidates = ["Deleted Messages", "Trash", "已删除"]

    private let account: MailboxAccount
    private let auth: String?
    private let runner: CurlRunner

    init(account: MailboxAccount, auth: String?, runner: CurlRunner = ProcessCurlRunner()) {
        self.accountId = account.id
        self.account = account
        self.auth = auth
        self.runner = runner
    }

    // MARK: - MailTransport

    /// 取一轮未读邮件。**取信由 curl 内置 `;UID=` 路径完成 → 服务端在 FETCH 时即置 `\Seen`**
    /// (curl 不暴露 `BODY.PEEK[]`, 见 `CurlMailCommand.fetchMessage`)。两个直接后果:
    /// ① 闸门判失败的信也只出现一轮 —— 不再需要"解析失败就补 STORE"那两步兜底, 也不会每 15s
    ///    把同一条拒收理由重复写进日志;
    /// ② 崩溃窗口 = fetch 返回到入队之间: 那封会成"已读但未处理", 仍在 INBOX 里可人工找回。
    func poll() async throws -> [RawMail] {
        let (host, secret) = try context()
        var mails: [RawMail] = []
        for uid in try await unseenUids(host: host, secret: secret) {
            let raw = try await execute(CurlMailCommand.fetchMessage(
                uid: uid, host: host, user: account.address, auth: secret))
            guard let text = CurlMailCommand.fetchedBody(raw) else {
                throw MailTransportError.parse(String(format: L("UID %lld 未取到邮件正文"), uid))
            }
            do {
                mails.append(try MimeParser.parse(text, uid: uid))
            } catch {
                throw MailTransportError.parse("UID \(uid): \(error)")
            }
        }
        return mails
    }

    func markRead(_ mail: RawMail) async throws {
        guard let uid = mail.uid else { throw MailTransportError.notConfigured(L("该邮件缺 IMAP UID")) }
        let (host, secret) = try context()
        try await store(uid: uid, deleted: false, host: host, secret: secret)
    }

    /// COPY 到 Trash 是**尽力而为** (部分服务商无该文件夹或只读), 失败仍要打 `\Deleted`。
    /// 文件夹名逐个候选试: 服务端的垃圾箱名随服务商与界面语言变, 猜错只是多一次进程。
    func moveToTrash(_ mail: RawMail) async throws {
        guard let uid = mail.uid else { throw MailTransportError.notConfigured(L("该邮件缺 IMAP UID")) }
        let (host, secret) = try context()
        for mailbox in trashCandidates {
            let copied = (try? await execute(CurlMailCommand.copyToTrash(
                uid: uid, mailbox: mailbox, host: host, user: account.address, auth: secret))) != nil
            if copied { break }   // 已在 Trash 留了可逆的一份
        }
        try await store(uid: uid, deleted: true, host: host, secret: secret)   // 永不 EXPUNGE
    }

    func send(_ mail: OutgoingMail) async throws {
        guard let smtpHost = nonEmpty(account.smtpHost) else {
            throw MailTransportError.notConfigured(L("缺 SMTP 主机"))
        }
        guard let secret = nonEmpty(auth) else { throw MailTransportError.notConfigured(L("账号缺授权码")) }
        let body = MailMessageBuilder.rfc822(mail, from: account.address)
        let arguments = CurlMailCommand.send(host: smtpHost, user: account.address,
                                             auth: secret, from: account.address, to: mail.to)
        let result = try await runner.run(arguments, stdin: body)
        if let error = CurlMailCommand.failure(exitCode: result.exitCode, stderr: result.stderr,
                                               secrets: [secret]) {
            throw MailTransportError.send(error.label)
        }
    }

    /// 收 + 发**两个方向都验** —— 只测 IMAP 会漏掉发信侧的静默失败: 实测 2026-09-20, IMAP 全程
    /// 正常而 SMTP 因 curl 自选 AUTH PLAIN 被 QQ 拒 (`535 Login denied`), 直到第一次任务跑完
    /// 没人收到回执才暴露。SMTP 侧故意不发信 (见 `CurlMailCommand.smtpAuthProbe`)。
    func testConnection() async -> String? {
        do {
            _ = try await unseenUids()
        } catch {
            return (error as? MailTransportError)?.label ?? "\(error)"
        }
        guard let smtpHost = nonEmpty(account.smtpHost) else { return L("IMAP 正常, 但账号缺 SMTP 主机") }
        guard let secret = nonEmpty(auth) else { return L("IMAP 正常, 但账号缺授权码") }
        let probe = CurlMailCommand.smtpAuthProbe(host: smtpHost, user: account.address, auth: secret)
        guard let result = try? await runner.run(probe, stdin: nil) else { return L("IMAP 正常, 但 SMTP 连接失败") }
        // 认证过后 curl 卡在 MAIL FROM / RCPT (没给收件人) → 那些非零码**恰好证明认证已过**。
        if [0, 8, 55, 56, 65].contains(Int(result.exitCode)) { return nil }
        let label = CurlMailCommand.failure(exitCode: result.exitCode, stderr: result.stderr,
                                            secrets: [secret])?.label ?? String(format: L("curl 退出码 %lld"), result.exitCode)
        return String(format: L("IMAP 正常, 但 SMTP 未通过: %@"), label)
    }

    // MARK: - 内部

    /// (IMAP 主机, 授权码) —— 缺一即 `notConfigured`, 不带着半截配置去连。
    private func context() throws -> (host: String, secret: String) {
        guard let host = nonEmpty(account.imapHost) else {
            throw MailTransportError.notConfigured(L("缺 IMAP 主机"))
        }
        guard let secret = nonEmpty(auth) else { throw MailTransportError.notConfigured(L("账号缺授权码")) }
        return (host, secret)
    }

    private func unseenUids() async throws -> [Int64] {
        let (host, secret) = try context()
        return try await unseenUids(host: host, secret: secret)
    }

    private func unseenUids(host: String, secret: String) async throws -> [Int64] {
        let output = try await execute(CurlMailCommand.listUnseen(
            host: host, user: account.address, auth: secret))
        return CurlMailCommand.parseUids(output)
    }

    private func store(uid: Int64, deleted: Bool, host: String, secret: String) async throws {
        let command = deleted
            ? CurlMailCommand.markDeleted(uid: uid, host: host, user: account.address, auth: secret)
            : CurlMailCommand.markSeen(uid: uid, host: host, user: account.address, auth: secret)
        _ = try await execute(command)
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    private func execute(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(arguments, stdin: nil)
        if let error = CurlMailCommand.failure(exitCode: result.exitCode, stderr: result.stderr,
                                               secrets: [auth ?? ""]) {
            throw error
        }
        return result.stdout
    }
}
