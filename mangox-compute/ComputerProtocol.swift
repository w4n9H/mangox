//
//  ComputerProtocol.swift
//  mangox-compute (P18 批 1b): 与 `mangox-computer.ts` 之间的**一问一答**。
//
//  ⚠️ 形状必须是**自描述**的: 解析器只认字段名, 不认"第几个参数"。改字段名 = 两边一起改,
//     所以每个字段都写清楚它为什么存在 —— 这层协议是 TS 与 Swift 之间唯一的契约,
//     写歪了不会编译报错, 只会静默读到 nil(同 `MANGOX_BOCHA_KEY` 那条"契约 token"的纪律)。
//
import Foundation

/// 一条请求。⚠️ 只留**真要用的 op** —— 工具面是"越小模型越不会选错"。
enum ComputerRequest: Decodable {
    /// 探活 + 报告辅助功能权限状态。App 侧用它判断"该不该在界面上提示去系统设置授权"。
    case ping
    /// 读某个 App 的前台窗口树, 返回已经整形好的文本。
    ///
    /// ⚠️ **参数是 `app` 不是 `pid`**: 模型只说得出 App 名字, 说不出此刻的 pid;
    ///    定位(pid)由本机做 —— 见 `ComputerTarget.pick`。空串 = 当前前台 App。
    case read(app: String, includeImage: Bool)
    /// 动一下界面(批 2b)。
    ///
    /// ⚠️ `op` 收的是**原始字符串**, 不是 `ComputerAction`: 认不出来的 op 要能带着原字
    ///    回一句"不认识", 而不是在解码阶段变成一句 `dataCorrupted` 的机器话。
    ///    ⚠️ `seq` **没有默认值**: 缺了就是"没读过就想动", 必须拒 —— 给它一个 0 当默认,
    ///    等于给"先读再动"开了一个静默的后门。
    ///    `direction` 只 `scroll` 用(`up` / `down`)。缺了**不在解码阶段填默认值**: "没说往哪滚"
    ///    与"往下滚"是两件事, 猜一个等于替模型做决定(判据那边会拒并说清)。
    case act(app: String, op: String, index: Int, seq: Int, text: String, direction: String)
    /// 打开(或切到前台)一个 App —— P18 批 2d。
    ///
    /// ⚠️ 为什么不复用 `act`: 打开一个 App **不动它里面的任何东西**, 与"在 Dock 上点一下图标"
    ///    同一件事; 而"进去之后能做什么"仍然由操作面那道门管(`actBundles`)。两件事两个 op,
    ///    授权也就落在两道不同的门上(读面 vs 操作面)。
    /// ⚠️ 没有它, 「用计算器算 100×5」在计算器没开时**结构上做不到**: 读不到 ⇒ 没有窗口树
    ///    ⇒ 也没有编号可动。
    case open(app: String)

    private enum CodingKeys: String, CodingKey {
        case op, app, includeImage, index, seq, text, direction
        /// 动作本身(`press` / `setValue` / `focus` / `scroll`)。⚠️ 不能复用 `op` ——
        /// 那个位置装的是信封类型(`act`), 两个语义塞进一个键, 读代码的人分不清哪个是哪个。
        case action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "ping": self = .ping
        case "read":
            self = .read(app: try c.decodeIfPresent(String.self, forKey: .app) ?? "",
                         includeImage: try c.decodeIfPresent(Bool.self, forKey: .includeImage) ?? false)
        case "act":
            self = .act(app: try c.decodeIfPresent(String.self, forKey: .app) ?? "",
                        op: try c.decodeIfPresent(String.self, forKey: .action) ?? "",
                        index: try c.decodeIfPresent(Int.self, forKey: .index) ?? 0,
                        seq: try c.decodeIfPresent(Int.self, forKey: .seq) ?? -1,
                        text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                        direction: try c.decodeIfPresent(String.self, forKey: .direction) ?? "")
        case "open":
            // 空 `app` 交给 server 拒(并说清"打开哪个"): 解码阶段回一句机器话,
            // 模型只会把 `dataCorrupted` 当成故障重试。
            self = .open(app: try c.decodeIfPresent(String.self, forKey: .app) ?? "")
        default:
            // 不认识的 op 要说清楚, 不能默默当成 ping —— 否则扩展侧改名之后会读到"一切正常"。
            throw DecodingError.dataCorruptedError(forKey: .op, in: c,
                                                   debugDescription: "未知 op: \(op)")
        }
    }
}

/// 一条应答。`ok == false` 时 `error` **必须**非空 —— 回执是给模型看的, 空错误会让它重试同一个动作。
struct ComputerResponse: Encodable {
    let ok: Bool
    /// `read` / `act` 成功时的文本; 失败时为 nil。
    let text: String?
    /// 失败原因(人话)。模型靠它决定"换条路"还是"报告给用户"。
    let error: String?
    /// `ping` 时回: 本机辅助功能权限是否已授予。
    let trusted: Bool?
    /// `read` / `act` 之后, 这个 App 的**最新快照序号**。模型下一次动作必须带它。
    ///
    /// ⚠️ 没有这个字段, "编号过期"这件事就只能靠模型自己记时间 —— 它记不住,
    ///    也没人会因此看到红灯, 只会看到"点了没反应"。
    let seq: Int?

    static func success(text: String) -> ComputerResponse {
        ComputerResponse(ok: true, text: text, error: nil, trusted: nil, seq: nil)
    }

    static func success(text: String, seq: Int) -> ComputerResponse {
        ComputerResponse(ok: true, text: text, error: nil, trusted: nil, seq: seq)
    }

    static func failure(_ message: String) -> ComputerResponse {
        ComputerResponse(ok: false, text: nil, error: message, trusted: nil, seq: nil)
    }

    static func pong(trusted: Bool) -> ComputerResponse {
        ComputerResponse(ok: true, text: nil, error: nil, trusted: trusted, seq: nil)
    }
}

/// 一行的读写。**帧 = 一行 JSON + \n** —— 不用长度前缀, 因为一次往返只有一条消息,
/// 而且换行分隔在 `nc`/日志里肉眼可读(排查 socket 问题时这点很值钱)。
enum ComputerFraming {
    static func encode(_ response: ComputerResponse) -> Data {
        var data = (try? JSONEncoder().encode(response)) ?? Data()
        data.append(0x0A)
        return data
    }

    static func decode(_ line: String) -> ComputerRequest? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ComputerRequest.self, from: d)
    }
}
