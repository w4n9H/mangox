//
//  CaseDiagnosticLog.swift
//  诊断日志的判据（2026-11-05）。
//
//  这条日志存在的唯一理由是「复现了要有现场」，所以判据也只围绕三件事：
//   ① **行能被解析**：区-事件-k=v 三段，时间戳定宽 —— 事后是拿它跟时间线对齐的，
//      格式一歪就等于没有。
//   ② **开关真的管用**：关掉之后一个字节都不许写（否则"我关了啊"这句话没法信）。
//   ③ **入队不许阻塞主线程**：埋点本身要是把帧拖慢了，那这套东西就是在制造它要查的 bug。
//
//  ⚠️ 结尾**不许**调 `report()`（它是收尾 + exit，只属于整个 run 的末尾）。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseDiagnosticLog() async {
        print("== T-LOG 诊断日志 ==")

        let dir = fixtureDir("diag-log")
        let oldRoot = DiagnosticLog.directoryOverride
        let wasEnabled = DiagnosticLog.shared.isEnabled
        DiagnosticLog.directoryOverride = dir
        DiagnosticLog.shared.resetForTesting()   // 别让之前用例开的句柄继续写旧路径
        defer {
            DiagnosticLog.shared.setBodyRecording(false)
            DiagnosticLog.shared.setEnabled(wasEnabled)
            DiagnosticLog.shared.resetForTesting()
            DiagnosticLog.directoryOverride = oldRoot
        }

        // ---- ① 行格式 ----
        DiagnosticLog.shared.setEnabled(true)
        Log.scroll("beat", ["i": "0", "gap": "-9018"])
        DiagnosticLog.shared.flush()

        let name = DiagnosticLog.latestFileName() ?? ""
        check(!name.isEmpty && name.hasPrefix("mangox-") && name.hasSuffix(".log"),
              "T-LOG 文件名带启动时间且可排序 (实测 \(name.isEmpty ? "无" : name))")

        let body = (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)) ?? ""
        let line = body.split(separator: "\n").last.map(String.init) ?? ""
        let parts = line.split(separator: " ").map(String.init)
        // 时间戳定宽 `HH:mm:ss.SSS` ⇒ 12 字符（宽度不定就没法按列对齐读）。
        check(parts.first?.count == 12 && parts.first?.contains(":") == true,
              "T-LOG 行首是定宽时间戳 HH:mm:ss.SSS (实测 \(parts.first ?? "空"))")
        check(parts.count >= 3 && parts[1] == "scroll" && parts[2] == "beat",
              "T-LOG 第 2/3 段是 区 + 事件 (实测 \(parts.prefix(3).joined(separator: "/")))")
        check(parts.contains("i=0") && parts.contains("gap=-9018"),
              "T-LOG 字段是 `k=v` 且原值保留 (实测 \(parts.dropFirst(3).joined(separator: " ")))")

        // ---- ② 正文片段受二级开关管 ----
        DiagnosticLog.shared.setBodyRecording(false)
        DiagnosticLog.shared.body(.send, "text", "这段正文不该出现")
        DiagnosticLog.shared.flush()
        let noBody = (try? String(contentsOfFile: dir + "/" + DiagnosticLog.latestFileName()!, encoding: .utf8)) ?? ""
        check(!noBody.contains("这段正文不该出现"),
              "T-LOG 二级开关关着时不写正文 (默认就是这个状态)")

        DiagnosticLog.shared.setBodyRecording(true)
        DiagnosticLog.shared.body(.send, "text", "这段正文该出现")
        DiagnosticLog.shared.flush()
        let withBody = (try? String(contentsOfFile: dir + "/" + DiagnosticLog.latestFileName()!, encoding: .utf8)) ?? ""
        check(withBody.contains("这段正文该出现") && withBody.contains("chars="),
              "T-LOG 二级开关打开后才写正文, 并且同时记字数")

        // ---- ③ 关掉 = 零写盘 ----
        DiagnosticLog.shared.setEnabled(false)
        DiagnosticLog.shared.flush()
        let before = DiagnosticLog.totalBytes()
        Log.send("enter", "chars", "5")
        Log.process("spawned", "pid", "1")
        DiagnosticLog.shared.flush()
        check(DiagnosticLog.totalBytes() == before,
              "T-LOG 关掉之后一个字节都不写 (前 \(before) / 后 \(DiagnosticLog.totalBytes()))")

        // ---- ④ 入队不许阻塞主线程 ----
        DiagnosticLog.shared.setEnabled(true)
        let t0 = Date()
        for i in 0..<200 { Log.scroll("beat", ["i": "\(i)", "gap": "0"]) }
        let ms = Date().timeIntervalSince(t0) * 1000
        // 阈值给得很松（实测 200 条个位数毫秒）：它要抓的是"有人在主线程 write 文件"
        // 那种结构性错误，不是抖动。
        check(ms < 120, "T-LOG 200 条埋点入队 < 120ms (实测 \(String(format: "%.1f", ms))ms)")
        DiagnosticLog.shared.flush()

        // ---- ⑤ 纯函数（格式的两条不变量）----
        check(DiagnosticLog.flat("a  b\tc\nd") == "a_b_c_d",
              "T-LOG 值里的空白压成单个下划线 (否则 k=v 断不开)")
        let keys = DiagnosticLog.orderedKeys(["chars": "1", "body": "x", "a": "2"])
        check(keys == ["a", "chars", "body"],
              "T-LOG body 恒排最后 (它允许空格, 放中间会把后面的 k=v 吃掉) 实测 \(keys)")

        // ---- ⑥ 容量上限（防止有人把它调成无界增长）----
        check(DiagnosticLog.segmentLimit >= 1 << 20 && DiagnosticLog.segmentLimit <= 16 << 20,
              "T-LOG 单份上限在 1~16MB (实测 \(DiagnosticLog.segmentLimit / 1024)KB)")
        check(DiagnosticLog.keepFiles >= 3 && DiagnosticLog.keepFiles <= 50,
              "T-LOG 目录保留份数 3~50 (实测 \(DiagnosticLog.keepFiles))")
    }
}
