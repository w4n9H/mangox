//
//  ComputerProtocol.swift
//  mangox-compute (P18 批 1b): 与 `mangox-computer.ts` 之间的**一问一答**。
//
//  ⚠️ 形状必须是**自描述**的: 解析器只认字段名, 不认"第几个参数"。改字段名 = 两边一起改,
//     所以每个字段都写清楚它为什么存在 —— 这层协议是 TS 与 Swift 之间唯一的契约,
//     写歪了不会编译报错, 只会静默读到 nil(同 `MANGOX_BOCHA_KEY` 那条"契约 token"的纪律)。
//
import Foundation

/// 一条请求。⚠️ 只留**批 1 需要的**两个 op —— 工具面是"越小模型越不会选错"。
enum ComputerRequest: Decodable {
    /// 探活 + 报告辅助功能权限状态。App 侧用它判断"该不该在界面上提示去系统设置授权"。
    case ping
    /// 读某个 App 的前台窗口树, 返回已经整形好的文本。
    ///
    /// ⚠️ **参数是 `app` 不是 `pid`**: 模型只说得出 App 名字, 说不出此刻的 pid;
    ///    定位(pid)由本机做 —— 见 `ComputerTarget.pick`。空串 = 当前前台 App。
    case read(app: String, includeImage: Bool)

    private enum CodingKeys: String, CodingKey {
        case op, app, includeImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "ping": self = .ping
        case "read":
            self = .read(app: try c.decodeIfPresent(String.self, forKey: .app) ?? "",
                         includeImage: try c.decodeIfPresent(Bool.self, forKey: .includeImage) ?? false)
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
    /// `read` 成功时的快照文本; 失败时为 nil。
    let text: String?
    /// 失败原因(人话)。模型靠它决定"换条路"还是"报告给用户"。
    let error: String?
    /// `ping` 时回: 本机辅助功能权限是否已授予。
    let trusted: Bool?

    static func success(text: String) -> ComputerResponse {
        ComputerResponse(ok: true, text: text, error: nil, trusted: nil)
    }

    static func failure(_ message: String) -> ComputerResponse {
        ComputerResponse(ok: false, text: nil, error: message, trusted: nil)
    }

    static func pong(trusted: Bool) -> ComputerResponse {
        ComputerResponse(ok: true, text: nil, error: nil, trusted: trusted)
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
