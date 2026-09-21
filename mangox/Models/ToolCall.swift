//
//  ToolCall.swift
//

import Foundation
import SwiftUI

enum ToolKind: String, Hashable, Codable {
    case bash
    case read
    case grep
    case find
    case ls
    case edit
    case write
    case fetch
    case image
    case search
    case delegate

    /// 展示用名 —— **全大写英文**，与轨迹页的 `USER` / `ASSISTANT` 标签同一种写法
    /// (2026-09-21 boss: "trace 那里, 统一全大写英文")。四个消费点都吃这个属性:
    /// 轨迹工具名 chip / "BASH × 5" 折叠行 / 工具卡片的 kind tag (Chat + 轨迹同源)。
    ///
    /// ⚠️ **只动展示, 不动 `rawValue`** —— 小写的 rawValue 既作 `Codable` 编解码键,
    /// 又是 pi 上报的工具名 (比对/派发都用它), 跟着大写会把落库数据和工具识别一起打坏。
    var label: String { rawValue.uppercased() }

    /// Default phase color (overridable per card via `phase`).
    var defaultColor: Color {
        switch self {
        case .bash, .delegate: return CodexTheme.accent
        case .read, .grep, .find, .ls, .fetch, .search: return CodexTheme.info
        case .edit, .write: return CodexTheme.toolDone
        case .image: return CodexTheme.thinking
        }
    }
}

struct ToolDetail: Hashable, Codable {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

struct ToolCall: Identifiable, Hashable, Codable {
    let id: UUID
    let kind: ToolKind
    let title: String          // path / target / file name
    let command: String?       // optional inline command shown in header
    /// Optional key/value rows rendered beneath the header (e.g. path / 输出).
    let details: [ToolDetail]
    let phase: ToolPhase
    let durationMs: Int?
    /// edit/write 审批时的 diff 预览文本 (行前缀 -/+；扩展侧生成, title 通道透传)。
    var diffText: String?

    init(id: UUID = UUID(),
         kind: ToolKind,
         title: String,
         command: String? = nil,
         details: [ToolDetail] = [],
         phase: ToolPhase = .queued,
         durationMs: Int? = nil,
         diffText: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.command = command
        self.details = details
        self.phase = phase
        self.durationMs = durationMs
        self.diffText = diffText
    }

    /// Copy with a new phase (used when the user approves / denies a request).
    func withPhase(_ newPhase: ToolPhase) -> ToolCall {
        ToolCall(id: id,
                 kind: kind,
                 title: title,
                 command: command,
                 details: details,
                 phase: newPhase,
                 durationMs: durationMs,
                 diffText: diffText)
    }

    /// Attach diff preview (edit/write 审批时由 transport 解析 title 通道后挂上)。
    func withDiffText(_ text: String?) -> ToolCall {
        ToolCall(id: id,
                 kind: kind,
                 title: title,
                 command: command,
                 details: details,
                 phase: phase,
                 durationMs: durationMs,
                 diffText: text)
    }
}

extension ToolCall {
    /// 旧事件数据无 diffText 字段 → 宽松解码。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ToolKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        details = try c.decode([ToolDetail].self, forKey: .details)
        phase = try c.decode(ToolPhase.self, forKey: .phase)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        diffText = try c.decodeIfPresent(String.self, forKey: .diffText)
    }
}
