//
//  MimeParser.swift
//  P10.2c: 极简 RFC822/MIME 解析 — 只覆盖"任务邮件"形态 (本人从邮箱客户端发出)。
//  "来源可控"是收窄复杂度的前提 (拆解 §二): 标准 multipart 或 text/plain, 编码 UTF-8/QP/base64 三种。
//  输入约定: raw 必须是 **Latin1 无损解码**的字符串 (每字节 ↔ 一个字符) —— 正文靠自己按 charset 还原。
//

import Foundation

enum MimeParser {

    // MARK: - 入口

    /// 字节流入口 (curl 拉回来的就是字节; 内部按 Latin1 无损映射, 不吃 UTF-8 校验)。
    static func parse(data: Data, uid: Int64? = nil) throws -> RawMail {
        try parse(String(data: data, encoding: .isoLatin1) ?? "", uid: uid)
    }

    /// 解析一封原始邮件。缺 Message-ID / multipart 缺 boundary → 抛 `.parse` (上层回 FAILED, 不静默吞)。
    /// `uid` 由 transport 填 (IMAP UID 是标记已读/移动的凭据, 不在邮件本体里)。
    static func parse(_ raw: String, uid: Int64? = nil) throws -> RawMail {
        let (headerText, bodyText) = splitHeaderBody(raw)
        let fields = headerFields(unfold(headerText))
        func value(_ name: String) -> String? { fields.first { $0.0 == name }?.1 }

        guard let rawId = value("message-id"), !normalizeMessageId(rawId).isEmpty else {
            throw MailTransportError.parse(L("缺少 Message-ID"))
        }
        return RawMail(
            uid: uid,
            messageId: normalizeMessageId(rawId),
            inReplyTo: value("in-reply-to").map(normalizeMessageId).flatMap { $0.isEmpty ? nil : $0 },
            references: value("references").map(messageIds) ?? [],
            from: address(from: value("from") ?? ""),
            subject: decodeRFC2047(value("subject") ?? ""),
            body: try extractBody(fields: fields, rawBody: bodyText),
            date: value("date").flatMap(parseDate)
        )
    }

    // MARK: - 头/体切分

    /// 找第一个空行。换行统一成 `\n` (后续所有按行处理都不必再管 `\r`)。
    static func splitHeaderBody(_ raw: String) -> (header: String, body: String) {
        let s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let r = s.range(of: "\n\n") else { return (s, "") }   // 无空行: 容错当作全头
        return (String(s[s.startIndex..<r.lowerBound]), String(s[r.upperBound...]))
    }

    /// 展开头折叠 (RFC5322 §2.2.3): 续行的 CRLF 删除, 前导 WSP 保留。
    static func unfold(_ header: String) -> [String] {
        var out: [String] = []
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !out.isEmpty {
                out[out.count - 1] += line
            } else {
                out.append(String(line))
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// 头字段 → [(小写名, 值)]。无冒号或空名的行丢弃 (Received 之类照常收着, 不用即弃)。
    static func headerFields(_ lines: [String]) -> [(String, String)] {
        lines.compactMap { line in
            guard let i = line.firstIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<i]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
    }

    // MARK: - 正文

    /// 取第一个 text/plain part 并按声明解码。HTML-only / 无可用 part → 空串 (上层回执"请以纯文本发送")。
    static func extractBody(fields: [(String, String)], rawBody: String) throws -> String {
        let ct = contentType(fields.first { $0.0 == "content-type" }?.1)
        let cte = fields.first { $0.0 == "content-transfer-encoding" }?.1

        guard ct.mime.hasPrefix("multipart/") else {
            if ct.mime == "text/html" { return "" }
            return decodeBody(rawBody, ct: ct, encoding: cte)
        }
        guard let boundary = ct.params["boundary"], !boundary.isEmpty else {
            throw MailTransportError.parse(L("multipart 缺 boundary"))
        }
        for part in splitParts(rawBody, boundary: boundary) {
            let (partHeader, partBody) = splitHeaderBody(part)
            let partFields = headerFields(unfold(partHeader))
            let partCt = contentType(partFields.first { $0.0 == "content-type" }?.1)
            if partCt.mime == "text/plain" {
                let partCte = partFields.first { $0.0 == "content-transfer-encoding" }?.1
                return decodeBody(partBody, ct: partCt, encoding: partCte)
            }
            if partCt.mime.hasPrefix("multipart/"),
               let nested = try? extractBody(fields: partFields, rawBody: partBody) {
                return nested
            }
        }
        return ""
    }

    /// 按 boundary 切 part (preamble/postamble 丢弃; 尾界缺失也容错收下最后一段)。
    static func splitParts(_ body: String, boundary: String) -> [String] {
        let delim = "--" + boundary
        let close = delim + "--"
        var parts: [String] = []
        var current: [String] = []
        var inPart = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line == close {
                if inPart { parts.append(current.joined(separator: "\n")) }
                inPart = false
                current = []
            } else if isBoundaryLine(line, delim: delim) {
                if inPart { parts.append(current.joined(separator: "\n")) }
                inPart = true
                current = []
            } else if inPart {
                current.append(line)
            }
        }
        if inPart, !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    /// `--b` / `--b   ` 算界; `--bXYZ` 不算 (RFC2046 允许界行尾跟 LWSP)。
    static func isBoundaryLine(_ line: String, delim: String) -> Bool {
        guard line.hasPrefix(delim) else { return false }
        let rest = line.dropFirst(delim.count)
        return rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t")
    }

    /// `text/plain; charset="utf-8"` → ("text/plain", ["charset": "utf-8"])。缺省 text/plain (RFC2045 §5.2)。
    static func contentType(_ value: String?) -> (mime: String, params: [String: String]) {
        guard let value, !value.isEmpty else { return ("text/plain", [:]) }
        let segments = value.split(separator: ";")
        let mime = segments.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
        var params: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let key = segment[segment.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            params[key] = val
        }
        return (mime.isEmpty ? "text/plain" : mime, params)
    }

    /// Content-Transfer-Encoding 解出字节 → charset 解出字符串。
    static func decodeBody(_ raw: String, ct: (mime: String, params: [String: String]),
                           encoding: String?) -> String {
        let decoded: [UInt8]
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":          decoded = decodeBase64(raw)
        case "quoted-printable": decoded = decodeQuotedPrintable(raw, underscoreAsSpace: false)
        default:                decoded = bytes(fromLatin1: raw)   // 7bit/8bit/binary/未知 → 原样
        }
        return string(decoded, charset: ct.params["charset"])
    }

    // MARK: - 编码

    /// Latin1 字符串 → 原始字节 (每字符低 8 位; 上游用 `.isoLatin1` 解码即无损)。
    static func bytes(fromLatin1 s: String) -> [UInt8] {
        s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    static func decodeBase64(_ s: String) -> [UInt8] {
        var clean = s.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
        while clean.count % 4 != 0 { clean += "=" }   // 容忍丢掉的 padding
        return Array(Data(base64Encoded: clean, options: [.ignoreUnknownCharacters]) ?? Data())
    }

    /// QP 解码。`underscoreAsSpace` 供 RFC2047 的 Q 编码用 (那里 `_` = 空格)。
    static func decodeQuotedPrintable(_ s: String, underscoreAsSpace: Bool) -> [UInt8] {
        let chars = Array(s.unicodeScalars)
        var out: [UInt8] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "=" {
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 2; continue }        // 软换行
                if i + 1 < chars.count, chars[i + 1] == "\r" {
                    i += 2
                    if i < chars.count, chars[i] == "\n" { i += 1 }
                    continue
                }
                if i + 2 < chars.count, let v = hexByte(chars[i + 1], chars[i + 2]) {
                    out.append(v); i += 3; continue
                }
            }
            if underscoreAsSpace, c == "_" { out.append(0x20); i += 1; continue }
            out.append(UInt8(truncatingIfNeeded: c.value)); i += 1
        }
        return out
    }

    static func hexByte(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> UInt8? {
        func nib(_ c: Unicode.Scalar) -> UInt8? {
            switch c {
            case "0"..."9": return UInt8(c.value - 0x30)
            case "a"..."f": return UInt8(c.value - 0x61 + 10)
            case "A"..."F": return UInt8(c.value - 0x41 + 10)
            default: return nil
            }
        }
        guard let hi = nib(a), let lo = nib(b) else { return nil }
        return hi << 4 | lo
    }

    /// 字节 → 字符串。charset 说了算, 失败/未声明则 UTF-8, 再退 Latin1 (不丢字节)。
    static func string(_ bytes: [UInt8], charset: String?) -> String {
        let data = Data(bytes)
        if let charset = charset?.trimmingCharacters(in: .whitespaces).lowercased(), !charset.isEmpty,
           let enc = encoding(for: charset), let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func encoding(for charset: String) -> String.Encoding? {
        switch charset {
        case "utf-8", "utf8":                     return .utf8
        case "us-ascii", "ascii":                 return .ascii
        case "iso-8859-1", "iso8859-1", "latin1": return .isoLatin1
        case "gb18030", "gbk", "gb2312", "gb-2312", "cp936":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5", "big-5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)))
        default: return nil
        }
    }

    /// RFC2047 解码 (`=?charset?B|Q?...?=`)。相邻 encoded-word 之间的纯空白丢弃 (§6.2)。
    static func decodeRFC2047(_ s: String) -> String {
        guard let re = encodedWordRegex, !s.isEmpty else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }

        var out = ""
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                out += gap.trimmingCharacters(in: .whitespaces).isEmpty ? "" : gap
            }
            let charset = ns.substring(with: m.range(at: 1))
            let scheme = ns.substring(with: m.range(at: 2)).lowercased()
            let payload = ns.substring(with: m.range(at: 3))
            let bytes = scheme == "b" ? decodeBase64(payload)
                                      : decodeQuotedPrintable(payload, underscoreAsSpace: true)
            out += string(bytes, charset: charset)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return out
    }

    private static let encodedWordRegex = try? NSRegularExpression(
        pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=")

    // MARK: - 字段规整

    /// `"张三" <a@b.com>` → `a@b.com`; 裸地址原样 (拿最后一个 `<>`, 兼容显示名里带尖括号)。
    static func address(from value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        if let lt = v.lastIndex(of: "<"), let gt = v.lastIndex(of: ">"), lt < gt {
            return String(v[v.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        }
        return v
    }

    static func normalizeMessageId(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("<") { v.removeFirst() }
        if v.hasSuffix(">") { v.removeLast() }
        return v.trimmingCharacters(in: .whitespaces)
    }

    /// References / In-Reply-To 值 → id 列表 (优先尖括号; 退化按空白切)。
    static func messageIds(_ s: String) -> [String] {
        var out: [String] = []
        var cursor = s.startIndex
        while cursor < s.endIndex,
              let lt = s[cursor...].firstIndex(of: "<"),
              let gt = s[lt...].firstIndex(of: ">") {
            let id = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { out.append(id) }
            cursor = s.index(after: gt)
        }
        if out.isEmpty {
            out = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
                .map { normalizeMessageId(String($0)) }.filter { !$0.isEmpty }
        }
        return out
    }

    /// RFC2822 日期。解析不出返回 nil (邮件照收, 时间戳只是元数据)。
    static func parseDate(_ s: String) -> Date? {
        let formats = ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
                       "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz"]
        for format in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = format
            if let d = df.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}
