//
//  AgentMode.swift
//  P7-M4: 模式选择器 — 极简/常规/完整三档 (能力预设, 与审批开关正交)。
//  档位差异 = --tools 白名单 + 业务扩展挂载与否; 系统扩展 (mangox-approval) 三档恒挂。
//

import Foundation

// Codable: 哨兵配置要往 JSON blob / 表列里落 rawValue (P10.2a)。
enum AgentMode: String, Codable, CaseIterable, Identifiable {
    case minimal, standard, full
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: "Minimal"
        case .standard: "Standard"
        case .full: "Full"
        }
    }

    var subtitle: String {
        switch self {
        case .minimal:
            "仅 read / bash / write / edit 四个内置工具, 不挂业务扩展 — 轻装跑定时任务与快速问答。"
        case .standard:
            "功能完整的编码 Agent, 内置工具全量 (读/写/Shell/检索), 不挂业务扩展 — 日常默认档。"
        case .full:
            "具备标准模式全部能力, 并挂载全部业务扩展, 扩展注册的工具一并进入工具池。"
        }
    }

    /// spawn 期 --tools 白名单 (nil = 不传, pi 默认即内置全量)。
    /// 极简含 read/edit 的理由: 盲写不可用 (看不到文件改什么)。
    var toolAllowlist: [String]? {
        switch self {
        case .minimal: ["read", "bash", "write", "edit"]
        case .standard, .full: nil
        }
    }

    /// 业务扩展是否挂载 (§2.1: 档位差异用挂载扩展与否表达"含不含扩展",
    /// 不依赖 --tools 对扩展工具的过滤行为 — 两种证伪结果下都成立)。
    var mountsBusinessExtensions: Bool { self == .full }

    // settings KV 持久化 (value 列 TEXT, 存 allCases 序号的整数字符串)
    var storageIndex: Int { Self.allCases.firstIndex(of: self) ?? 1 }

    init(storageIndex: Int) {
        self = Self.allCases.indices.contains(storageIndex) ? Self.allCases[storageIndex] : .standard
    }

    /// spawn 参数矩阵 (纯函数, 冒烟直接断言): 三档 → --tools / --extension 组装。
    /// 系统扩展不在此列 (PiRpcTransport 固定首个 --extension 内置)。
    static func spawnArguments(for mode: AgentMode, businessExtensions: [String]) -> [String] {
        var args: [String] = []
        if let tools = mode.toolAllowlist {
            args += ["--tools", tools.joined(separator: ",")]
        }
        if mode.mountsBusinessExtensions {
            for path in businessExtensions { args += ["--extension", path] }
        }
        return args
    }
}
