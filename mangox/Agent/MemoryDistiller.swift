//
//  MemoryDistiller.swift
//  P3.7 记忆自动提炼 (v1 人工触发): 一次性 pi 进程跑提炼轮。
//  与主 PiRpcTransport 并行不悖 (独立进程, 不碰 UI 流式状态);
//  拒绝所有工具调用 (审批扩展照挂, extension_ui 一律 Deny —— 提炼只许输出文本);
//  失败/超时静默放弃 (记忆是副产品, 不为主流程制造噪音)。
//

import Foundation

@MainActor
final class MemoryDistiller {
    static let shared = MemoryDistiller()

    struct Candidate {
        let title: String
        let content: String
        let scope: KnowledgeScope
        let reason: String
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lineBuffer: String = ""
    private var collected: String = ""
    private var finish: ((String?) -> Void)?
    private var watchdog: DispatchWorkItem?

    var isRunning: Bool { process != nil }

    /// 跑一轮提炼。completion 主线程回调: nil = 失败/超时; 非 nil = 原始输出全文。
    func run(prompt: String, model: String?, thinking: String?,
             completion: @escaping (String?) -> Void) {
        guard process == nil else { completion(nil); return }   // 同一时间只跑一轮
        guard let spec = PiRpcTransport.launchSpec() else {
            completion(nil); return
        }
        let extPath = PiRpcTransport.ensureExtensionFile()
        collected = ""
        lineBuffer = ""
        finish = completion
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executable)
        var args = spec.scriptArgs + ["--mode", "rpc", "--no-extensions",
                                      "--extension", extPath, "--no-session"]
        if let model { args += ["--model", model] }
        if let thinking { args += ["--thinking", thinking] }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            print("[MemoryDistiller] spawn 失败: \(error)")
            complete(nil); return
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(data) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.complete(nil, keepText: true) }
            }
        }
        send(["id": "req-1", "type": "prompt", "message": prompt])
        // 看门狗: 单轮总时长上限 (到点强杀, 静默放弃)
        let wd = DispatchWorkItem { [weak self] in
            print("[MemoryDistiller] 看门狗超时 (\(Int(Tune.distillTimeoutSeconds))s), 强杀放弃")
            self?.complete(nil)
        }
        watchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + Tune.distillTimeoutSeconds, execute: wd)
    }

    // MARK: - 输出解析 (static, 独立可冒烟)

    /// 从模型原始输出里抠 JSON (容忍 ```json 围栏/前后闲话), 解析候选列表。
    /// 纯函数, nonisolated (冒烟可独立跑, 不依赖主线程)。
    nonisolated static func parseOutput(_ raw: String) -> [Candidate] {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return [] }
        guard let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { d in
            guard let title = d["title"] as? String, !title.isEmpty,
                  let content = d["content"] as? String, !content.isEmpty else { return nil }
            let scope: KnowledgeScope = (d["scope"] as? String) == "project" ? .project : .global
            return Candidate(title: String(title.prefix(60)),
                             content: content,
                             scope: scope,
                             reason: (d["reason"] as? String) ?? "")
        }
    }

    // MARK: - 内部

    private func consume(_ data: Data) {
        guard process != nil else { return }
        lineBuffer += String(data: data, encoding: .utf8) ?? ""
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return }
        switch dict["type"] as? String {
        case "message_update":
            guard let ev = dict["assistantMessageEvent"] as? [String: Any],
                  ev["type"] as? String == "text_delta",
                  let delta = ev["delta"] as? String else { return }
            collected += delta
        case "extension_ui_request":
            // 一律拒绝: 提炼轮只许说话, 不许动手 (bash/edit/write 全 Deny)
            guard let reqId = dict["id"] as? String,
                  let method = dict["method"] as? String else { return }
            if method == "confirm" {
                send(["type": "extension_ui_response", "id": reqId, "confirmed": false])
            } else {
                send(["type": "extension_ui_response", "id": reqId, "value": "Deny"])
            }
        case "agent_end", "agent_settled":
            if collected.isEmpty { print("[MemoryDistiller] agent_end 但无文本产出 (检查 --model 参数与 LLM 配置)") }
            complete(collected.isEmpty ? nil : collected)
        default:
            break
        }
    }

    /// 收尾 (幂等): 取消看门狗 + 杀进程 + 回调。keepText=true 时进程退出兜底仍可交付已收集文本。
    private func complete(_ result: String?, keepText: Bool = false) {
        guard process != nil || finish != nil else { return }
        watchdog?.cancel()
        watchdog = nil
        if let p = process {
            outKill(p)
        }
        process = nil
        stdinHandle = nil
        let f = finish
        finish = nil
        let deliver: String?
        if let result {
            deliver = result
        } else if keepText, !collected.isEmpty {
            deliver = collected   // agent_end 未等到但已有产出 (进程意外退出) — 仍可解析
        } else {
            deliver = nil
        }
        f?(deliver)
    }

    private func outKill(_ p: Process) {
        p.terminate()
    }

    private func send(_ dict: [String: Any]) {
        guard let stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A)
        stdinHandle.write(data)
    }
}
