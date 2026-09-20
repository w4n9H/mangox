//
//  CurlMailCommand.swift
//  P10.2c: curl 调用组装与输出解析 —— 全部纯函数, 冒烟可直接断言 argv 与语料。
//  立场: 零依赖 (系统 curl 8.7.1 支持 imaps/smtps), 代价 = 无 IDLE 只能轮询 + 每步一个进程。
//  纪律: **永不 EXPUNGE** (移 Trash = COPY + \Deleted, 留可逆余地, 拆解 §三 决定 14)。
//

import Foundation

enum CurlMailCommand {
    static let binary = "/usr/bin/curl"
    /// 只 poll INBOX —— 鉴权主防线的前提 (借力服务商 SPF/DKIM/DMARC), 拆解 §四。
    static let inbox = "INBOX"
    /// 一次 poll 最多处理几封, 防止 INBOX 积压时一网打尽。
    static let pollLimit = 20

    /// ⚠️ `--login-options AUTH=LOGIN` 是**必需项, 不是可选优化** —— 别删。
    ///
    /// curl 不给机制时**自选**, 实测它选 PLAIN; 而 **QQ 的 SMTP 只接受 `AUTH LOGIN`, 对 PLAIN 一律
    /// `535 Login denied`** (同一台服务器上 IMAP 反而接受 PLAIN)。后果极具误导性: **同一个授权码
    /// IMAP 能登、SMTP 登不上** → 看起来像"授权码没开 SMTP 权限", 实际是客户端挑错了机制。
    /// 实测 (2026-09-20, 真 QQ): 显式 LOGIN → `exit=0 / 250`; 显式 PLAIN → `exit=67`。
    /// 163/126/阿里同样支持 LOGIN (最基础的机制), 故两边统一钉死, 不留"靠 curl 默认值碰运气"的口子。
    static let loginOptions = ["--login-options", "AUTH=LOGIN"]

    // MARK: - IMAP

    /// `UID SEARCH UNSEEN` —— **`UID ` 前缀是硬要求, 不是风格**。
    ///
    /// RFC 3501: 裸 `SEARCH` 返回**消息序号 (sequence number)**, `UID SEARCH` 才返回 **UID**。
    /// 而下游全是 UID 命令 (`UID FETCH` / `UID STORE` / `UID COPY`) → 序号混进 UID 空间必然错位。
    /// 实测 QQ (2026-09-20): 信箱里只有 1 封而 `UIDNEXT 97` —— `SEARCH UNSEEN` 回 `1`、
    /// `UID SEARCH UNSEEN` 回 `96`; 拿 `1` 去 `UID FETCH 1 BODY[]` 被服务器回 NO,
    /// curl 报 `(78) Remote file not found`。**这条是"序号/UID 混用"的指纹症状**。
    static func listUnseen(host: String, user: String, auth: String, timeout: Int = 30) -> [String] {
        imap(host: host, user: user, auth: auth, timeout: timeout, command: "UID SEARCH UNSEEN")
    }

    /// 取整封邮件 (含头) —— 走 curl **内置**的 `;UID=` 路径, 而不是 `-X`。
    ///
    /// ⚠️ 实测 (curl 8.7.1, 2026-09-20 用假 IMAP 服务器逐字节比对):
    /// - `-X 'FETCH n BODY.PEEK[]'` 与 `-X 'UID FETCH n BODY.PEEK[]'` **都拿不到正文** ——
    ///   curl 对自定义请求只把**响应行** (`* n FETCH (UID n BODY[] {539}`) 打到 stdout (31 字节),
    ///   后面的字面量根本不读; 同时给 `;UID=` 也是 `-X` 赢。旧实现就栽在这里
    ///   (实机症状: `解析失败: UID 1 未取到邮件正文`)。
    /// - `--url 'imaps://host/INBOX;UID=n'` → curl 发 `UID FETCH n BODY[]`, stdout **就是裸邮件字节**
    ///   (539 字节, 与期望邮件 `cmp` 全等, 无 IMAP 前缀、无结尾的 `)`) —— 比抠字面量还干净。
    ///
    /// 代价: 内置路径硬编码 `BODY[]` (非 `.PEEK`), **取信即置 \Seen**, curl 没暴露 PEEK 开关。
    /// 语义后果已在 `CurlMailTransport.poll()` 与拆解文档中记录。
    static func fetchMessage(uid: Int64, host: String, user: String, auth: String, timeout: Int = 30) -> [String] {
        ["-sS", "-m", "\(timeout)",
         "--user", "\(user):\(auth)"]
            + loginOptions
            + ["--url", "imaps://\(host)/\(inbox);UID=\(uid)"]
    }

    static func markSeen(uid: Int64, host: String, user: String, auth: String, timeout: Int = 30) -> [String] {
        imap(host: host, user: user, auth: auth, timeout: timeout, command: "UID STORE \(uid) +FLAGS (\\Seen)")
    }

    /// 移 Trash 的第一步 (第二步 = markDeleted)。Trash 名各服务商不同, 故做成参数。
    static func copyToTrash(uid: Int64, mailbox: String = "Trash", host: String, user: String,
                            auth: String, timeout: Int = 30) -> [String] {
        imap(host: host, user: user, auth: auth, timeout: timeout, command: "UID COPY \(uid) \"\(mailbox)\"")
    }

    static func markDeleted(uid: Int64, host: String, user: String, auth: String, timeout: Int = 30) -> [String] {
        imap(host: host, user: user, auth: auth, timeout: timeout, command: "UID STORE \(uid) +FLAGS (\\Deleted)")
    }

    /// ⚠️ `command` 里的编号一律当作 **UID** (`UID SEARCH` 的产物) —— 传进来的命令必须自己带 `UID ` 前缀,
    /// 否则会拿序号去操作 UID, 静默错位到别的邮件上 (见 `listUnseen` 注释)。
    private static func imap(host: String, user: String, auth: String, timeout: Int, command: String) -> [String] {
        ["-sS", "-m", "\(timeout)",
         "--user", "\(user):\(auth)"]
            + loginOptions
            + ["--url", "imaps://\(host)/\(inbox)", "-X", command]
    }

    // MARK: - SMTP

    /// `--upload-file -` = 从 stdin 读整封 RFC822 (免临时文件落盘)。
    static func send(host: String, user: String, auth: String, from: String, to: String,
                     timeout: Int = 60) -> [String] {
        ["-sS", "-m", "\(timeout)",
         "--user", "\(user):\(auth)"]
            + loginOptions
            + ["--url", "smtps://\(host)",
               "--mail-from", from,
               "--mail-rcpt", to,
               "--upload-file", "-"]
    }

    /// SMTP 凭据探针 —— **只连 + 握手 + 认证, 不投递任何邮件** (故意不给 `--mail-rcpt`)。
    ///
    /// 判读方式 (2026-09-20 实测): 认证**通过**后 curl 会去发 `MAIL FROM` 而服务端以 `502` 拒掉
    /// → `exit 8`; 那是**预期**的, 恰好证明认证已过。**只有 67 才代表凭据/机制问题**。
    /// 用途: 「测试连接」原先只测 IMAP, 于是"IMAP 一直正常、SMTP 静默登不上"能一路藏到第一次
    /// 任务跑完没人收到回执才暴露 —— 这条探针就是补那个盲区 (发信方向真的被验过一次)。
    static func smtpAuthProbe(host: String, user: String, auth: String, timeout: Int = 30) -> [String] {
        ["-sS", "-m", "\(timeout)",
         "--user", "\(user):\(auth)"]
            + loginOptions
            + ["--url", "smtps://\(host)"]
    }

    // MARK: - 输出解析

    /// `* SEARCH 12 13 14` → [12, 13, 14] (含限流)。
    /// 注意: 必须先规范化 CRLF —— Swift 的 Character 是**字形簇**, CRLF 算 1 个字符,
    /// `split(separator: "\n")` 切不开它 (整行会粘成一条)。
    static func parseUids(_ output: String, limit: Int = pollLimit) -> [Int64] {
        var out: [Int64] = []
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.uppercased().hasPrefix("* SEARCH") else { continue }
            for token in trimmed.dropFirst("* SEARCH".count).split(separator: " ") {
                if let uid = Int64(token) {
                    out.append(uid)
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    /// 校验取信输出 —— 内置 `;UID=` 路径下 stdout **就是**整封邮件, 故这里只是薄闸。
    ///
    /// 为什么还挡 `* ` 前缀: 服务端没回字面量时 curl 会把 IMAP 响应行当输出 (正是旧 `-X` 路径的
    /// 形态, 31 字节就以 `* ` 开头), 那种东西喂给 MimeParser 只会得到一堆"缺头"告警; 直接判 nil,
    /// 上层就能报"未取到邮件正文", 排障时一眼区分**传输层**问题与**邮件内容**问题。
    static func fetchedBody(_ output: String) -> String? {
        guard !output.isEmpty, !output.hasPrefix("* ") else { return nil }
        return output
    }

    // MARK: - 失败归类

    /// exitCode 0 → nil。凭据串从 stderr 里抹掉 (错误信息会进 UI 与日志)。
    static func failure(exitCode: Int32, stderr: String, secrets: [String] = []) -> MailTransportError? {
        guard exitCode != 0 else { return nil }
        var detail = stderr.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last ?? ""
        for secret in secrets where !secret.isEmpty {
            detail = detail.replacingOccurrences(of: secret, with: "***")
        }
        switch exitCode {
        case 67:    return .connection("认证失败, 检查授权码\(detail.isEmpty ? "" : " (\(detail))")")
        case 6, 7:  return .connection(detail.isEmpty ? "无法连接主机" : detail)
        case 28:    return .connection("连接超时")
        case 78:    return .connection("服务端未返回该邮件 (UID 已不存在或被移走)")
        default:    return .connection(detail.isEmpty ? "curl 退出码 \(exitCode)" : detail)
        }
    }
}
