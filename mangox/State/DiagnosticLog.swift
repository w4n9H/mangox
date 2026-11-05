//
//  DiagnosticLog.swift
//  ~/.mangox/log/ 下的诊断日志（2026-11-05，boss: "后续复现了，你有现场"）。
//
//  存在的理由只有一条：白屏那个问题折腾了四轮，每轮都只能靠猜是**过冲**（视口落到内容
//  下方）还是**欠冲**。缺的从来不是复现，是白的那一帧视口到底落在哪 —— 那个数字只有 App
//  自己知道，事后问不出来。
//
//  三条硬约束（改这个文件时别破）：
//   1. **不许阻塞主线程**：主线程上只做「开关判断 + 组一行 + 入队」，开文件/写盘/轮转全在
//      串行队列。⚠️ 埋点本身绝不能成为掉帧原因 —— 滚动路径上的埋点只拼数字，不许做重活。
//   2. **不许抛错、不许递归**：写盘失败就静默（把 App 写崩比没有日志更糟）。
//   3. **目录必须可进程级重定向**（冒烟）：与 `PiRpcTransport.sessionDirectoryOverride` 同族 ——
//      生产调用点（`ChatStore` / `ChatView` / `PiRpcTransport`）都不带目录参数，函数级注入
//      管不到 ⇒ 漏一次就是把夹具写进用户真实的 `~/.mangox/log/`，而且零红灯。
//
//  ⚠️ 日志**不含对话正文**（那是 `bodyRecording` 这个二级开关的事，默认关）。结构日志只记
//     事件名 / 数字 / id 前 8 位 —— 它要能直接发给别人排查。
//

import Foundation

/// 日志分区。名字要能直接对着 `grep` 用，所以是固定的小写词表。
enum LogArea: String, CaseIterable {
    case send       // 回车 → sendDraft → beginTurn
    case scroll     // 滚动 / 视口 / 重排
    case event      // AgentEvent 回流
    case process    // pi 进程生命周期
    case store      // 消息面与落库
    case view       // 其它视图层
}

final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    // MARK: - 落盘位置与容量

    /// 冒烟/出图用的**进程级**重定向（在 `run()` 起手设一次，早于任何 `ChatStore`）。
    nonisolated(unsafe) static var directoryOverride: String?

    /// 日志目录。
    /// ⚠️ 用 `NSHomeDirectory()` 而不是 `HOME`：实测 `env HOME=/tmp/x` 不生效（同 pi-sessions 那条）。
    static var directory: String {
        directoryOverride ?? (NSHomeDirectory() + "/.mangox/log")
    }

    /// 单份上限。一次运行的量级：正常几百 KB，长流式会话 1~2 MB。
    static let segmentLimit = 4 * 1024 * 1024
    /// 一次运行最多切几份（超了停写，只补一行 `truncated`，不静默丢）。
    static let maxSegmentsPerRun = 4
    /// 目录里最多留几份（开第一份文件时按文件名里的时间戳清更老的）。
    static let keepFiles = 10

    // MARK: - 状态（全部在 lock 下读写）

    private let lock = NSLock()
    private var enabled = true
    private var bodyRecording = false
    private let queue = DispatchQueue(label: "app.mangox.diag-log", qos: .utility)
    /// 队列私有状态（只在 queue 上碰，故不加锁）。
    private var handle: FileHandle?
    private var runName = ""
    private var segment = 1
    private var written = 0
    private var pruned = false
    private var truncated = false

    private init() {}

    // MARK: - 开关（由 ChatStore 从 settings 表注入）

    func setEnabled(_ on: Bool) {
        lock.lock(); enabled = on; lock.unlock()
        if on { log(.view, "log-enabled") }   // 打开时留一行沿，方便核对时间点
    }

    func setBodyRecording(_ on: Bool) {
        lock.lock(); bodyRecording = on; lock.unlock()
    }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    // MARK: - 写

    /// 一条结构日志。`fields` 里的值会把空白压成 `_`（保持 `k=v` 可解析）；
    /// `body` 这个键例外（它是正文片段，允许空格）且恒排最后。
    func log(_ area: LogArea, _ event: String, _ fields: [String: String] = [:]) {
        lock.lock(); let on = enabled; lock.unlock()
        guard on else { return }
        var line = Self.stamp() + " " + area.rawValue + " " + event
        for k in Self.orderedKeys(fields) {
            let raw = fields[k] ?? ""
            line += " " + Self.fieldKey(k) + "=" + (k == "body" ? raw : Self.flat(raw))
        }
        emit(line)
    }

    /// 单字段便捷重载（埋点里绝大多数只有一两个数）。
    func log(_ area: LogArea, _ event: String, _ key: String, _ value: String) {
        log(area, event, [key: value])
    }

    /// 正文片段（**二级开关**，默认关）：把发送内容/回复开头截到 80 字。
    /// 换行折成 `⏎` —— 它是一行日志，不是一份对话记录。
    func body(_ area: LogArea, _ event: String, _ text: String) {
        lock.lock(); let on = enabled && bodyRecording; lock.unlock()
        guard on else { return }
        let flat = text.replacingOccurrences(of: "\r\n", with: "⏎")
            .replacingOccurrences(of: "\n", with: "⏎")
        let cut = flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
        log(area, event, ["chars": "\(text.count)", "body": cut])
    }

    /// 分区标题（排查时把一次操作圈出来，比时间戳好读）。
    func section(_ title: String) {
        log(.view, "==== " + Self.flat(title) + " ====")
    }

    /// 等到队列里已有的写入都落盘。App 退出前与冒烟断言用（**不许**放在热路径上）。
    func flush() { queue.sync {} }

    /// 冒烟专用：关掉当前文件、忘掉运行名，让下一行按当前 `directory` 重新开一份。
    ///
    /// 为什么需要它：单例一旦开过文件，`append` 就一直往那个 `FileHandle` 写 ——
    /// 用例里换 `directoryOverride` 之后断言"新目录是空的"会读到旧句柄写去别处，**假绿**。
    func resetForTesting() {
        queue.sync {
            try? handle?.close()
            handle = nil
            runName = ""
            segment = 1
            written = 0
            pruned = false
            truncated = false
        }
    }

    // MARK: - 入队 / 落盘

    private func emit(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        queue.async { self.append(data) }
    }

    /// 队列上执行：懒开文件 → 追加 → 超限轮转。
    private func append(_ data: Data) {
        if handle == nil, !truncated { openSegment() }
        guard let h = handle else { return }
        do {
            try h.write(contentsOf: data)
        } catch {
            // 写失败（磁盘满/权限）—— 静默关掉，本进程不再尝试；App 本身继续跑。
            handle = nil
            truncated = true
            return
        }
        written += data.count
        guard written >= Self.segmentLimit else { return }
        if segment < Self.maxSegmentsPerRun {
            rotate()
        } else {
            // 停写但不静默: 留一行说明"后面没有了", 免得看日志的人以为这一刻之后什么都没发生。
            truncated = true
            try? h.close()
            handle = nil
            Self.appendPlain("\(Self.stamp()) view log-truncated segments=\(segment)\n",
                             to: Self.path(runName, segment: segment))
        }
    }

    private func openSegment() {
        let dir = Self.directory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !pruned {
            pruned = true
            Self.pruneOldFiles(in: dir)
        }
        if runName.isEmpty { runName = "mangox-" + Self.fileStamp() }
        let path = Self.path(runName, segment: segment)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        // ⚠️ 用 `seekToEnd()` 而不是 `seekToEndOfFile()`：后者自 10.15.4 起 deprecated，
        //    而 `run.sh` 把 swiftc 告警当**硬门**（一条 deprecation 就能把门打红）。
        // `_ =` 不能省: `seekToEnd()` 返回新偏移，`try?` 丢掉它会被门禁当成"结果未使用"告警。
        _ = try? h.seekToEnd()
        handle = h
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        segment += 1
        written = 0
        openSegment()
    }

    private static func path(_ run: String, segment: Int) -> String {
        directory + "/" + run + (segment <= 1 ? "" : "-\(segment)") + ".log"
    }

    /// 目录里只留最近 `keepFiles` 份。文件名定宽（`mangox-yyyyMMdd-HHmmss[-n].log`）⇒ 字典序即时间序。
    private static func pruneOldFiles(in dir: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let logs = names.filter { $0.hasPrefix("mangox-") && $0.hasSuffix(".log") }.sorted()
        guard logs.count >= keepFiles else { return }
        // 留 keepFiles-1 份: 本次运行马上要新建一份。
        for name in logs.prefix(logs.count - (keepFiles - 1)) {
            try? fm.removeItem(atPath: dir + "/" + name)
        }
    }

    private static func appendPlain(_ text: String, to path: String) {
        guard let data = text.data(using: .utf8),
              let h = FileHandle(forWritingAtPath: path) else { return }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
        try? h.close()
    }

    // MARK: - 设置页要读的两个数

    /// 目录占用（字节）。设置页打开时算一次，不在热路径上。
    static func totalBytes() -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }
        var sum = 0
        for n in names where n.hasSuffix(".log") {
            let p = directory + "/" + n
            if let a = try? fm.attributesOfItem(atPath: p), let s = a[.size] as? Int { sum += s }
        }
        return sum
    }

    /// 最近一份的文件名（设置页那一行给用户看"现在写的是哪个"）。
    static func latestFileName() -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return names.filter { $0.hasPrefix("mangox-") && $0.hasSuffix(".log") }.max()
    }

    // MARK: - 格式化

    /// `HH:mm:ss.SSS`（本地时区）。用 `localtime_r` 而不是 `DateFormatter` ——
    /// 后者每次调用要建对象，而这条跑在每一个滚动拍上。
    static func stamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var sec = time_t(tv.tv_sec)
        var tm = tm()
        localtime_r(&sec, &tm)
        let ms = Int(tv.tv_usec) / 1000
        return String(format: "%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec, ms)
    }

    static func fileStamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var sec = time_t(tv.tv_sec)
        var tm = tm()
        localtime_r(&sec, &tm)
        return String(format: "%04d%02d%02d-%02d%02d%02d",
                      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                      tm.tm_hour, tm.tm_min, tm.tm_sec)
    }

    /// 值里的空白压成 `_`：日志是"一行一条"，值带空格会让 `k=v ... k2=v2` 断不开。
    static func flat(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            if ch == " " || ch == "\n" || ch == "\r" || ch == "\t" || ch == "\u{0}" {
                if !lastWasSpace { out.append("_"); lastWasSpace = true }
            } else {
                out.append(ch); lastWasSpace = false
            }
        }
        return out
    }

    /// 键名不许带 `=` / 空格（调用方写死，这里是最后一道）。
    static func fieldKey(_ k: String) -> String { flat(k) }

    /// 字段顺序：字典序，但 `body` 恒最后（它的值允许空格，放末尾不妨碍前面解析）。
    static func orderedKeys(_ fields: [String: String]) -> [String] {
        let sorted = fields.keys.sorted().filter { $0 != "body" }
        return fields["body"] == nil ? sorted : sorted + ["body"]
    }
}

// MARK: - 埋点语法的短别名

/// 埋点写得太多会把业务代码淹掉 —— 用区域名直接当函数名：
/// `Log.scroll("beat", ["i": "0", "y": "13245"])`。
enum Log {
    static func send(_ e: String, _ f: [String: String] = [:])    { DiagnosticLog.shared.log(.send, e, f) }
    static func scroll(_ e: String, _ f: [String: String] = [:])  { DiagnosticLog.shared.log(.scroll, e, f) }
    static func event(_ e: String, _ f: [String: String] = [:])   { DiagnosticLog.shared.log(.event, e, f) }
    static func process(_ e: String, _ f: [String: String] = [:]) { DiagnosticLog.shared.log(.process, e, f) }
    static func store(_ e: String, _ f: [String: String] = [:])   { DiagnosticLog.shared.log(.store, e, f) }
    static func view(_ e: String, _ f: [String: String] = [:])    { DiagnosticLog.shared.log(.view, e, f) }

    // 单字段重载。⚠️ 必须**写成独立重载**而不是给上面那个加默认值:
    //    `Log.send("blocked", ["reason": "x"])` 与 `Log.send("blocked", "reason", "x")` 两种写法
    //    都得成立 —— 只有字典版时第二种会编译失败 (而且错误信息是"extra argument")。
    static func send(_ e: String, _ k: String, _ v: String)    { DiagnosticLog.shared.log(.send, e, k, v) }
    static func scroll(_ e: String, _ k: String, _ v: String)  { DiagnosticLog.shared.log(.scroll, e, k, v) }
    static func event(_ e: String, _ k: String, _ v: String)   { DiagnosticLog.shared.log(.event, e, k, v) }
    static func process(_ e: String, _ k: String, _ v: String) { DiagnosticLog.shared.log(.process, e, k, v) }
    static func store(_ e: String, _ k: String, _ v: String)   { DiagnosticLog.shared.log(.store, e, k, v) }
    static func view(_ e: String, _ k: String, _ v: String)    { DiagnosticLog.shared.log(.view, e, k, v) }
}
