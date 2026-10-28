//
//  ComputerHost.swift
//  P18 批 1: `mangox-compute` 这条**本机进程**的生命周期。
//
//  三个"为什么它必须是个独立可执行文件"的理由(决定了这层不能省):
//   ① **权限归属**: 辅助功能授权是**按可执行文件**记的。读 AX 树的代码住在 App 里 ⇒
//      MangoX 本体要被勾上"辅助功能"; 拆出去 ⇒ 只有 helper 需要它, 而且系统弹窗里
//      出现的名字是 `mangox-compute`(用户勾的是什么, 一眼看得出)。
//   ② **崩溃隔离**: AX 树是别人家的进程给的, 形状完全不受控(递归引用、超大子树、
//      `kAXErrorCannotComplete`)。解析崩在 App 里 = 整个 App 没了, 连聊天记录都来不及存。
//   ③ **作用域收缩**: helper 只听一条 unix socket, 而且只认**自己人**(见 `PeerCheck`)。
//      App 进程里跑着 Keychain、数据库、网络凭据 —— 让"读界面"这段代码住在同一个进程里,
//      等于把那些东西的可见范围也一起交出去了。
//
//  ⚠️ 本类**只管进程与环境**, 不判任何业务: "能不能读某个 App" 在 `ComputerScope`,
//     "读出来长什么样" 在 `AXSnapshot`, "哪些动作恒拒" 在 `ComputerRedline`。
//

import Foundation

@MainActor
final class ComputerHost {

    // MARK: - 契约 token

    /// ⚠️ 这四个串是**契约**: 逐字进子进程/helper 的 env, 改一个字母两边就得一起改,
    ///    而且**不会编译报错**(只会静默读到 nil)。`run.sh` 有门把它们钉在两侧。
    static let sockEnvKey = "MANGOX_COMPUTE_SOCK"
    static let allowedBundlesEnvKey = "MANGOX_COMPUTE_ALLOWED_BUNDLES"
    /// helper 用它做**进程树校验**: 只有 MangoX 自己(以及它的子孙, 也就是 pi)能连上来。
    ///
    /// ⚠️ 值是 **App 自己的 pid**, 不是 pi 的: helper 由 App 起, pi 也由 App 起 ⇒
    ///    pi 是 App 的子进程, "App 的子孙"这一个判据两个都覆盖了。**不必**先知道 pi 的 pid
    ///    (那是起 helper 时还不存在的信息 —— 顺序上 helper 得先于 pi 起)。
    static let peerPidEnvKey = "MANGOX_COMPUTE_PEER_PID"
    /// helper 探活用(父进程没了就自杀, 免得留一个握着辅助功能权限的孤儿)。
    static let parentPidEnvKey = "MANGOX_COMPUTE_PARENT_PID"

    static let helperExecutableName = "mangox-compute"

    // MARK: - 两条会**静默失效**的路径 (提成纯函数, 好让冒烟能断言)

    /// helper 在 App 包里的位置。
    ///
    /// ⚠️ 为什么值得一条判据: 拷错位置(`Contents/MacOS` 写成 `MacOS`)时 `Process.run()`
    ///    抛 "No such file", 而用户看到的现象只是"读不到界面" —— 中间**没有任何红灯**
    ///    (实测踩过一次: dstPath 写错, 文件确实被拷进包了, 只是不在能执行的地方)。
    static func helperPath(bundlePath: String) -> String {
        bundlePath + "/Contents/MacOS/" + helperExecutableName
    }

    /// socket 路径。`home` 与 `id` 都是参数 ⇒ 冒烟能指到夹具目录(同 `agentRootOverride` 的纪律:
    /// 落盘相关的判据必须能改根, 否则测试会写进真实 `~/.mangox`)。
    ///
    /// ⚠️ 名字里带 `id` 而不是固定名: 两个 MangoX 实例(正式版 + 自己编的 debug 版)同时开着时,
    ///    固定名会让后起的那个 `bind` 失败, 而先起的那个还握着权限 ⇒ 模型静默读到老的那份。
    static func socketPath(home: String, id: String) -> String {
        home + "/.mangox/compute-" + id + ".sock"
    }

    // MARK: - 状态

    private var process: Process?
    private(set) var socketPath: String?

    /// 起 helper, 返回 socket 路径。**`nil` = 没起来 ⇒ 调用方不要挂扩展、也不要给 env**
    /// （只挂不给 env ⇒ 工具每次都回"未启用"; 那还不如不挂, 免得模型白试）。
    ///
    /// ⚠️ **空作用域 ⇒ 连进程都不起**: 作用域是这一轮才存在的凭证, 空不是"全都行",
    ///    空是"没开放"。起了进程但名单为空 ⇒ helper 什么都会拒, 白占一条辅助功能授权。
    func start(home: String = NSHomeDirectory(),
               allowedBundles: [String],
               peerPid: pid_t = ProcessInfo.processInfo.processIdentifier,
               bundlePath: String = Bundle.main.bundlePath) -> String? {
        guard !allowedBundles.isEmpty else { return nil }
        if let socketPath, process?.isRunning == true { return socketPath }

        let sock = Self.socketPath(home: home, id: UUID().uuidString)
        let exe = Self.helperPath(bundlePath: bundlePath)
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = [sock]
        var env = ProcessInfo.processInfo.environment
        env[Self.allowedBundlesEnvKey] = allowedBundles.joined(separator: ",")
        env[Self.peerPidEnvKey] = String(peerPid)
        env[Self.parentPidEnvKey] = String(peerPid)
        p.environment = env

        do {
            try p.run()
        } catch {
            return nil
        }
        process = p

        // ⚠️ 等 socket 真的出现再返回: 否则这一轮第一次 read 会撞上"连不上", 而且是
        //    看不出原因的那种失败(模型只看到 ENOENT)。上限 500ms —— 再等就是在
        //    主线程上睡觉了, 而 helper 起监听通常在毫秒级; 超时也**照常返回路径**
        //    (慢不等于失败, 真失败会在 read 那一步说清楚)。
        for _ in 0..<5 where !FileManager.default.fileExists(atPath: sock) {
            usleep(100_000)
        }
        socketPath = sock
        return sock
    }

    /// 收。App 侧 `terminate()` 之后 helper 自己也会因为探活失败退出(双保险, 不是靠一层)。
    func stop() {
        process?.terminate()
        process = nil
        socketPath = nil
    }

    // MARK: - 环境 (纯函数)

    /// 与 `webSearchEnvironment` 同款: 返回 `nil` = **不要碰 `p.environment`**
    /// (谁也不提这几个变量时不该凭空造一份环境字典, 那会把父进程的整个环境复制进去)。
    ///
    /// ⚠️ 四个键必须**全部接管** —— 有值设进去, 没值**删掉**。只写"有值就设"是不够的:
    /// 用户在终端 `export MANGOX_COMPUTE_SOCK=…` 之后从这个 shell 起 App ⇒ 子进程继承它,
    /// 于是「面板显示未启用」与「扩展其实连上了一条 socket」**同时为真**, 而且零红灯。
    /// 标记不许比事实说得多 —— 所以这几个键由我们完全接管。
    static func environment(existing: [String: String]?,
                            socketPath: String?,
                            allowedBundles: [String],
                            peerPid: pid_t,
                            inherited: [String: String]) -> [String: String]? {
        let keys = [sockEnvKey, allowedBundlesEnvKey, peerPidEnvKey, parentPidEnvKey]
        if socketPath == nil, keys.allSatisfy({ inherited[$0] == nil }) { return nil }
        var env = existing ?? inherited
        env[sockEnvKey] = socketPath
        env[allowedBundlesEnvKey] = socketPath == nil ? nil : allowedBundles.joined(separator: ",")
        env[peerPidEnvKey] = socketPath == nil ? nil : String(peerPid)
        env[parentPidEnvKey] = env[peerPidEnvKey]
        return env
    }
}
