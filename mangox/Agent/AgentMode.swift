//
//  AgentMode.swift
//  P7-M4: 模式选择器 — 极简/常规/完整三档 (能力预设, 与审批开关正交)。
//  P13: 加第四个档 codemode, 但它**不是第四个老档** —— 它换的是"模型怎么调工具"这个维度
//       (只留 codemode 一个工具, 其余全部经脚本内层调用), 三个老档的能力面逐字节不变。
//  ⚠️ 于是选择器是**两层**: codemode 独占上层, 三个老档在下层, 中间隔一条带小注的分割线
//     (裸线会被读成"两组的边界", 而这里要表达的是"两个维度的边界")。
//  档位差异 = --tools 取值 + 挂哪些扩展; 系统扩展 (mangox-approval) 四档恒挂。
//

import Foundation

// Codable: 哨兵配置要往 JSON blob / 表列里落 rawValue (P10.2a)。
enum AgentMode: String, Codable, CaseIterable, Identifiable {
    // ⚠️ 声明顺序 == 展示顺序 (三处选择器直接吃 allCases)。codemode 置于最前是**刻意的**:
    //    它是另一个维度, 不是"更强的老档"。
    // ⚠️ 声明顺序**不是**存储键 —— 存储一律走 rawValue (见 storageValue)。
    case codemode, minimal, standard, full
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codemode: "Codemode"
        case .minimal: "Minimal"
        case .standard: "Standard"
        case .full: "Full"
        }
    }

    var subtitle: String {
        switch self {
        case .codemode:
            L("模型只保留 codemode 一个工具，其余全部经脚本内层调用 — 换一种调用范式，且会占用更多上下文。")
        case .minimal:
            L("仅 read / bash / write / edit 四个内置工具, 不挂业务扩展 — 轻装跑定时任务与快速问答。")
        case .standard:
            L("功能完整的编码 Agent, 内置工具全量 (读/写/Shell/检索), 不挂业务扩展 — 日常默认档。")
        case .full:
            L("具备标准模式全部能力, 并挂载全部业务扩展, 扩展注册的工具一并进入工具池。")
        }
    }

    /// P13: 这一档是不是"另一个维度"那一层。选择器靠它决定要不要画分割线,
    /// 菜单也靠它把上层与老档分开 —— **不写死名单**, 免得将来加层时两处不一致。
    var isCodemodeLayer: Bool { self == .codemode }

    /// spawn 期 --tools 取值 (nil = 不传, pi 默认即内置全量)。
    /// ⚠️ 两种语法**不同源**: `a,b,c` = **只留**这些; `+x` = 在全量基础上**增补**。
    /// 名字从 allowlist 改掉正是因为装得下 modifier 了 —— 叫 allowlist 会读反。
    /// 极简含 read/edit 的理由: 盲写不可用 (看不到文件改什么)。
    var toolListArguments: [String]? {
        switch self {
        case .codemode: ["+codemode"]
        case .minimal: ["read", "bash", "write", "edit"]
        case .standard, .full: nil
        }
    }

    /// 业务扩展是否挂载 (§2.1: 档位差异用挂载扩展与否表达"含不含扩展",
    /// 不依赖 --tools 对扩展工具的过滤行为 — 两种证伪结果下都成立)。
    /// P13: codemode 层**不挂** —— 挂了它就退化成"全工具 + 只留 codemode", 这一层失去独立理由
    /// (见 docs/P13 §02)。所以"codemode 能调业务扩展吗"的答案在四档里是"调不到, 因为没注册"。
    var mountsBusinessExtensions: Bool { self == .full }

    /// P13: 是否挂**自建** codemode 扩展。三老档**连扩展都不挂** ⇒ 它们的扩展段逐字节不变,
    /// 这是"零影响"最强的证明形式 (不是"挂了但没生效")。
    /// ⚠️ 为什么要自建而不是 `builtin:codemode`: 只有自建版能传 `options.mode = "only"`
    ///    (见 PiRpcTransport.ensureCodemodeExtensionFile)。
    var mountsCodemodeExtension: Bool { self == .codemode }

    // settings KV 持久化 (value 列 TEXT)。
    // ⚠️ 存 **rawValue**, 不存 allCases 序号 —— 曾是"位置即存储键": 把 codemode 排到最前
    //    会让老库里的 0/1/2 **整体改义** (老用户的 full 静默变 standard, 且零红灯)。
    var storageValue: String { rawValue }

    /// P13 之前的**历史编码**: 那时存的是 `allCases` 序号。
    /// ⚠️ **已冻结 —— 不得随枚举演进**。它描述的是"当时那张表", 与本文件的声明顺序无关;
    ///    一旦改成跟着 `allCases` 走, 就等于把上面那个 bug 原样搬一遍 (老库的 "2" 会解成别的档)。
    static let legacyOrder = ["minimal", "standard", "full"]

    /// 从 settings KV 的字符串解档。三级回落:
    ///   ① 当前 rawValue 直解 → ② 是整数则按**冻结的旧顺序表**反解 (迁移老库) → ③ 回落 standard。
    /// ⚠️ 不需要一次性数据迁移: 老值 ("0"/"1"/"2") 与新值 ("minimal"/…) 形态不同、互不冲突,
    ///    读时逐条反解即可 (写回时自动变成新形态)。
    init(storageValue: String) {
        if let m = AgentMode(rawValue: storageValue) { self = m; return }
        if let idx = Int(storageValue), Self.legacyOrder.indices.contains(idx) {
            self = AgentMode(rawValue: Self.legacyOrder[idx]) ?? .standard
            return
        }
        self = .standard
    }

    /// spawn 参数矩阵 (纯函数, 冒烟直接断言): 档位 → --tools / --extension 组装。
    /// 系统扩展不在此列 (PiRpcTransport 固定首挂内置 llama.cpp + 托管审批桥)。
    static func spawnArguments(for mode: AgentMode, businessExtensions: [String]) -> [String] {
        var args: [String] = []
        if let tools = mode.toolListArguments {
            args += ["--tools", tools.joined(separator: ",")]
        }
        if mode.mountsBusinessExtensions {
            for path in businessExtensions { args += ["--extension", path] }
        }
        return args
    }
}
