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
    /// 留位: pi 0.85.1 内置 8 个工具 (read/bash/edit/write/find/grep/ls/powershell) **无 delegate**,
    /// 全项目当前**零生产方** —— 保留是为了让"扩展给的子代理工具"有确定归处, 不落 `other`。
    case delegate
    /// 未知工具的中性归类。**存在的意义 = 不再谎报**: 旧版 `kindFor` 的 `default` 把任何
    /// 未登记的工具一律标成 `read` ⇒ 装了 web-search / subagents 这类扩展后, 标签与颜色
    /// **一起错**, 且落库的 `kind` 已失真、事后无法分辨。宁可是诚实的 `OTHER`。
    case other

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
        case .other: return CodexTheme.textSecondary
        }
    }
}

extension ToolKind {
    /// 未知 rawValue → `.other`。**不让一个陌生 kind 把整条事件载荷解码搞崩**,
    /// 口径与 `kindFor` 的 `default` 一致 (宁可中性, 不可谎报 / 不可丢整条)。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToolKind(rawValue: raw) ?? .other
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
    /// ⚠️ **只有 id 是 `let`, 其余一律 `var` + 就地改** —— 手写拷贝构造漏字段就是
    /// "某条路径上字段静默丢", 本文件已经踩过一次 (旧的 `withDetails` 漏掉 diffText)。
    /// 就地改没有这个失效模式; 值语义下每次改的都是副本, 不共享可变状态。
    let id: UUID
    var kind: ToolKind          // 唯一标识; 只有 `toolcall_end` 会用权威工具名升级 queued 卡
    var title: String           // path / target / file name
    var command: String?        // optional inline command shown in header
    /// Optional key/value rows rendered beneath the header (e.g. path / 输出).
    var details: [ToolDetail]
    var phase: ToolPhase
    var durationMs: Int?
    /// edit/write 审批时的 diff 预览文本 (行前缀 -/+；扩展侧生成, title 通道透传)。
    var diffText: String?
    /// 工具**产出**的图片在本机的路径 (pi 工具结果是 `AgentToolResult`, 其 `content[]` 里
    /// 可带 base64 `image` 块 —— 读图工具走的就是这条)。**存路径不存 base64**:
    /// 整个 `ToolCall` 会被 JSON 编进事件载荷落库, 内嵌 base64 会让 payload 膨胀到 MB 级。
    var imagePaths: [String]

    init(id: UUID = UUID(),
         kind: ToolKind,
         title: String,
         command: String? = nil,
         details: [ToolDetail] = [],
         phase: ToolPhase = .queued,
         durationMs: Int? = nil,
         diffText: String? = nil,
         imagePaths: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.command = command
        self.details = details
        self.phase = phase
        self.durationMs = durationMs
        self.diffText = diffText
        self.imagePaths = imagePaths
    }

    /// Copy with a new phase (used when the user approves / denies a request).
    func withPhase(_ newPhase: ToolPhase) -> ToolCall {
        var c = self; c.phase = newPhase; return c
    }

    /// Attach diff preview (edit/write 审批时由 transport 解析 title 通道后挂上)。
    func withDiffText(_ text: String?) -> ToolCall {
        var c = self; c.diffText = text; return c
    }

    func withDetails(_ newDetails: [ToolDetail]) -> ToolCall {
        var c = self; c.details = newDetails; return c
    }

    /// 完成态三件事一起落 (details + 图片 + 时长) —— 拆成三次拷贝会让中间态短暂丢字段。
    func finalized(details: [ToolDetail], imagePaths: [String], durationMs: Int?) -> ToolCall {
        var c = self
        c.details = details
        c.imagePaths = imagePaths
        c.durationMs = durationMs
        c.phase = .done
        return c
    }
}

extension ToolCall {
    /// 旧事件数据无 diffText / imagePaths 字段 → 宽松解码。
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
        imagePaths = try c.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
    }
}
