//
//  CaptureService.swift
//  P9.1d: 快速捕获域自 ChatStore 抽离 (P8-T27: 目标/热键/记忆 KV/即发即跑投递)。
//  拆分不动行为: ChatStore 保留同名 facade 转发 (冒烟/视图零改动);
//  服务持有 store 弱引用, 经 store 的会话/落库/回合接口回调 (selectConversation/beginTurn 等)。
//

import Foundation
import Combine

@MainActor
final class CaptureService: ObservableObject {

    /// P8-T27: 捕获目标 —— 新会话(归项目) 或 追加到既有会话。
    enum CaptureTarget: Equatable {
        case newSession(projectId: UUID?)
        case append(sessionId: UUID)

        /// KV 记忆编码 ("new:<pid|->" / "session:<sid>")
        var memoRaw: String {
            switch self {
            case .newSession(let p): "new:\(p?.uuidString ?? "-")"
            case .append(let s):     "session:\(s.uuidString)"
            }
        }

        static func from(memoRaw raw: String?) -> CaptureTarget {
            guard let raw else { return .newSession(projectId: nil) }
            if raw.hasPrefix("session:"), let sid = UUID(uuidString: String(raw.dropFirst(8))) {
                return .append(sessionId: sid)
            }
            if raw.hasPrefix("new:") {
                let part = String(raw.dropFirst(4))
                return .newSession(projectId: part == "-" ? nil : UUID(uuidString: part))
            }
            return .newSession(projectId: nil)
        }
    }

    /// P8-T27: 捕获热键配置 (settings KV; 默认 ⌃⌥X)。
    @Published private(set) var captureHotkey: CaptureHotkey = .fallback

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) { self.store = store }

    /// init 恢复路径 (KV 载入热键; facade 只读, 仅供 ChatStore 启动期回填)。
    func restore(_ hk: CaptureHotkey) { captureHotkey = hk }

    /// P8-T27: 改键 (Settings 录制后调用; 重注册由 Settings 层调 Controller)。
    func setCaptureHotkey(_ hk: CaptureHotkey) {
        captureHotkey = hk
        hk.save(persistence: store?.persistence)
    }

    /// P8-T27: 上次捕获目标 (pill 记忆; KV 文本)。
    var captureMemo: String? {
        store?.persistence?.loadSettingText(key: "capture_target")
    }

    func setCaptureMemo(_ raw: String?) {
        store?.persistence?.saveSettingText(key: "capture_target", value: raw ?? "")
    }

    /// 捕获条发送: 即发即跑 (无人值守关审批)。新会话 = Minimal 档强制 (全新上下文收窄风险面);
    /// 追加 = 档位跟随该会话实例 (既有上下文不强改)。主窗口跟随选中目标会话。
    /// 返回目标会话 id; nil = 拒绝 (空文本/引擎缺失/并发满/目标无效, 原因走横幅)。
    @discardableResult
    func submitCapture(text: String, target: CaptureTarget) -> UUID? {
        guard let store else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !store.engineMissing else {
            store.setExtensionNotice(L("未找到 pi CLI, 捕获未发送"), isError: true)
            return nil
        }
        guard !store.atTurnLimit else {
            store.setExtensionNotice(String(format: L("并发已达上限 (%lld), 捕获未发送"), store.maxConcurrentTurns), isError: true)
            return nil
        }
        switch target {
        case .newSession(let projectId):
            // 建会话 (ensureConversationForSend 同构, 归属捕获时选定的项目)
            let item = ConversationItem(title: ChatStore.defaultConversationTitle)
            if let pid = projectId, let g = store.projects.firstIndex(where: { $0.id == pid }) {
                store.projects[g].items.insert(item, at: 0)
                try? store.persistence?.insertChatSession(item, projectId: pid)
            } else {
                store.chats.insert(item, at: 0)
                try? store.persistence?.insertChatSession(item)
            }
            let sid = item.id
            let msg = ChatMessage(role: .user, content: .text(trimmed))
            store.persistOrNotify(L("捕获消息落库")) { try store.persistence?.appendMessageEvent(sessionId: sid, msg) }   
            store.selectConversation(sid)
            store.messages = [msg]
            store.autoTitleIfNeeded(sid: sid, text: trimmed)
            let cwd = projectId.flatMap { pid in store.projects.first(where: { $0.id == pid })?.path }
            store.beginTurn(sid: sid, prompt: trimmed, ephemeral: false,
                            cwd: cwd, unattended: true, modeOverride: .minimal)
            return sid

        case .append(let sid):
            guard store.allConversations.contains(where: { $0.id == sid }) else {
                store.setExtensionNotice(L("目标会话已不存在, 捕获未发送"), isError: true)
                return nil
            }
            guard !store.runningTurns.contains(sid) else {
                store.setExtensionNotice(L("该会话回合在途, 捕获未发送"), isError: true)
                return nil
            }
            let msg = ChatMessage(role: .user, content: .text(trimmed))
            store.persistOrNotify(L("捕获追加落库")) { try store.persistence?.appendMessageEvent(sessionId: sid, msg) }
            store.selectConversation(sid)   // replay 带全量历史 + 新消息
            store.autoTitleIfNeeded(sid: sid, text: trimmed)   // 空标题会话首次追加即命名
            let cwd = store.projects.first(where: { $0.items.contains { $0.id == sid } })?.path
            store.beginTurn(sid: sid, prompt: trimmed, ephemeral: false,
                            cwd: cwd, unattended: true)   // 档位跟随会话实例, 不强改
            return sid
        }
    }
}
