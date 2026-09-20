//
//  MailMessageBuilder.swift
//  P10.2c: 出站方向 —— OutgoingMail → 原始 RFC822 字节 (喂 curl --upload-file -)。
//  只做回执需要的最小形态: text/plain(base64) 单正文 + 可选 multipart/mixed 附件。
//

import Foundation

enum MailMessageBuilder {

    /// 组装整封邮件 (CRLF 行尾)。`boundary` 可注入以便断言 (生产走默认随机值)。
    static func rfc822(_ mail: OutgoingMail, from: String, date: Date = Date(),
                       boundary: String = "mangox-\(UUID().uuidString)") -> Data {
        var head = ["From: \(from)",
                    "To: \(mail.to)",
                    "Subject: \(encodedHeader(mail.subject))",
                    "Date: \(rfc2822Date(date))"]
        if let id = mail.messageId, !id.isEmpty {
            head.append("Message-ID: <\(MimeParser.normalizeMessageId(id))>")
        }
        if let inReplyTo = mail.inReplyTo, !inReplyTo.isEmpty {
            head.append("In-Reply-To: <\(MimeParser.normalizeMessageId(inReplyTo))>")
        }
        if !mail.references.isEmpty {
            head.append("References: \(mail.references.map { "<\(MimeParser.normalizeMessageId($0))>" }.joined(separator: " "))")
        }
        head.append("MIME-Version: 1.0")

        let textPart = ["Content-Type: text/plain; charset=utf-8",
                        "Content-Transfer-Encoding: base64",
                        "",
                        wrapBase64(Data(crlf(mail.body).utf8).base64EncodedString())]

        var lines: [String]
        if mail.attachments.isEmpty {
            lines = head + textPart
        } else {
            head.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines = head + [""] + ["--\(boundary)"] + textPart
            for attachment in mail.attachments {
                lines += ["--\(boundary)",
                          "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"",
                          "Content-Transfer-Encoding: base64",
                          "Content-Disposition: attachment; filename=\"\(attachment.filename)\"",
                          "",
                          wrapBase64(attachment.data.base64EncodedString())]
            }
            lines.append("--\(boundary)--")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// 非 ASCII → RFC2047 加密封装 (`=?UTF-8?B?...?=`); 纯 ASCII 原样 (可读性优先)。
    static func encodedHeader(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        if s.allSatisfy({ $0.isASCII && !$0.isNewline }) { return s }
        return encodedWords(s).joined(separator: "\r\n ")
    }

    /// 按 UTF-8 码点边界切, 每段 base64 后整体不超 78 列 (RFC2047 §2)。
    static func encodedWords(_ s: String, limit: Int = 45) -> [String] {
        var chunks: [String] = []
        var buffer: [UInt8] = []
        for scalar in s.unicodeScalars {
            let bytes = Array(String(scalar).utf8)   // 单码点不会被拆开
            if buffer.count + bytes.count > limit, !buffer.isEmpty {
                chunks.append(Data(buffer).base64EncodedString())
                buffer = []
            }
            buffer.append(contentsOf: bytes)
        }
        if !buffer.isEmpty { chunks.append(Data(buffer).base64EncodedString()) }
        return chunks.map { "=?UTF-8?B?\($0)?=" }
    }

    /// base64 正文按 76 列折行 (RFC2045 §6.8)。
    static func wrapBase64(_ s: String, columns: Int = 76) -> String {
        guard s.count > columns else { return s }
        var out: [String] = []
        var index = s.startIndex
        while index < s.endIndex {
            let end = s.index(index, offsetBy: columns, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[index..<end]))
            index = end
        }
        return out.joined(separator: "\r\n")
    }

    static func rfc2822Date(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return df.string(from: d)
    }

    /// `\n` → `\r\n` (SMTP 线协议要求; 已 CRLF 的不重复)。
    static func crlf(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }
}
