//
//  ComputerHost.swift
//  P18 批 1: `mangox-compute` 这条**本机进程**的生命周期。
//
//  两个"为什么它必须是个独立可执行文件"的理由(决定了这层不能省):
//   ① **崩溃隔离**: AX 树是别人家的进程给的, 形状完全不受控(递归引用、超大子树、
//      `kAXErrorCannotComplete`)。解析崩在 App 里 = 整个 App 没了, 连聊天记录都来不及存。
//      ⚠️ 2026-10-29 实测更正: 原来这里写的是"权限归属 —— 系统弹窗里出现的名字是
//      mangox-compute, 用户勾的是什么一眼看得出"。**这条不成立**: helper 是 MangoX 的子进程,
//      TCC 按 responsible process 记账 ⇒ 列表里**只有 MangoX**, mangox-compute 从不出现。
//      (证据: 列表里从来没有它, 而批 1/2b 的读一直都能成功。)
//   ② **作用域收缩**: helper 只听一条 unix socket, 而且只认**自己人**(见 `PeerCheck`)。
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
    /// 操作面(批 2b): 允许**动**的 bundle id。⚠️ 与读面分开一档, 空 = 一律不许动。
    /// 与 `ComputerServer.actBundlesEnvKey` 是同一个串(`run.sh` ③l 钉着)。
    static let actBundlesEnvKey = "MANGOX_COMPUTE_ACT_BUNDLES"
    /// helper 用它做**进程树校验**: 只有 MangoX 自己(以及它的子孙, 也就是 pi)能连上来。
    ///
    /// ⚠️ 值是 **App 自己的 pid**, 不是 pi 的: helper 由 App 起, pi 也由 App 起 ⇒
    ///    pi 是 App 的子进程, "App 的子孙"这一个判据两个都覆盖了。**不必**先知道 pi 的 pid
    ///    (那是起 helper 时还不存在的信息 —— 顺序上 helper 得先于 pi 起)。
    static let peerPidEnvKey = "MANGOX_COMPUTE_PEER_PID"
    /// helper 探活用(父进程没了就自杀, 免得留一个握着辅助功能权限的孤儿)。
    static let parentPidEnvKey = "MANGOX_COMPUTE_PARENT_PID"
    /// 人类接管(批 3b): "这一档有人在键鼠旁边" ⇒ helper 装那条只看不注入的事件监听。
    /// 值只写 `"1"` 或删掉 —— 缺省 = **不装**(无人值守档要有这个缺省, 不是反过来)。
    /// ⚠️ 与 helper 侧 `HumanInputTap.envKey` 是同一个串(`run.sh` ③j 钉着)。
    static let takeoverEnvKey = "MANGOX_COMPUTE_TAKEOVER"
    /// 图像面(批 3c): 允许**截图**的 bundle id。空 = 一张都不拍(不是"都能拍")。
    /// ⚠️ 第三档权限, 与读面/操作面各占一个键 —— 它多一个代价(像素绕过文本遮蔽),
    ///    所以必须能被人**单独关掉**, 而不是"跟着读面一起开"。
    static let imageBundlesEnvKey = "MANGOX_COMPUTE_IMAGE_BUNDLES"

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
    /// 起 socket 那次**实际下发**的作用域。复用前拿它跟这次要的比 —— 见 `Scope` 的注释。
    private var runningScope: Scope?

    /// 一次下发给 helper 的作用域。**排序后比较** —— 勾选顺序变了不算"变了"。
    ///
    /// ⚠️ 为什么需要一个类型来做这件事（2026-10-29 boss「我明明加了」）：
    ///    helper 的作用域是**启动那一刻读 env 定死的**，进程一起就再也不看 env 了。
    ///    而 `start` 原来只问"进程还在跑吗"，不问"名单是不是还是那一批" ⇒ 改了设置之后
    ///    助手照旧按旧名单拒，而**拒绝信息里列的也是旧那批 App**。
    ///    症状只有一句"我明明勾了"，值对、日志对、零红灯。
    struct Scope: Equatable {
        var read: [String]
        var act: [String]
        /// 批 3c: 允许截图的 App。**也算作用域** —— 同 `read/act`, 只在启动时读一次 env。
        var image: [String]
        /// 批 3b: 这一档要不要"人在动键鼠就让路"。**也算作用域的一部分** ——
        /// 它同样只在 helper 启动时读一次 env ⇒ 换了档位不重启就等于没换(同 `read/act` 那条教训)。
        var takeover: Bool
        /// 第四档(2026-11-10): 允许"认不出元素时按坐标点"。同族 —— 只在启动时读一次 env。
        ///
        /// ⚠️ 少了这一项, 用户打开那个开关之后**下一次会话才生效**, 而设置页已经是开着的;
        ///    症状是"我明明开了, 它还是说没开"(与 `read/act` 那次踩过的坑同形)。
        var tap: Bool
        /// 第五档(2026-11-10): 允许"往当前焦点里写一段字"。同族 —— 只在启动时读一次 env。
        ///
        /// ⚠️ 与 `tap` **分开两个字段**: 它们各自一个 env 键、各自一个开关。少一个字段的后果
        ///    与 `tap` 那次一模一样 —— 用户开了开关、设置页是开着的, 助手还按旧的办。
        var type: Bool

        init(read: [String], act: [String], image: [String] = [], takeover: Bool = false,
             tap: Bool = false, type: Bool = false) {
            self.read = read.sorted()
            self.act = act.sorted()
            self.image = image.sorted()
            self.takeover = takeover
            self.tap = tap
            self.type = type
        }
    }

    /// 起 helper, 返回 socket 路径。**`nil` = 没起来 ⇒ 调用方不要挂扩展、也不要给 env**
    /// （只挂不给 env ⇒ 工具每次都回"未启用"; 那还不如不挂, 免得模型白试）。
    ///
    /// ⚠️ **空作用域 ⇒ 连进程都不起**: 空不是"全都行", 空是"没开放"。
    ///    起了进程但名单为空 ⇒ helper 什么都会拒, 白占一条辅助功能授权。
    func start(home: String = NSHomeDirectory(),
               allowedBundles: [String],
               actBundles: [String] = [],
               imageBundles: [String] = [],
               takeover: Bool = false,
               tap: Bool = false,
               type: Bool = false,
               peerPid: pid_t = ProcessInfo.processInfo.processIdentifier,
               bundlePath: String = Bundle.main.bundlePath) -> String? {
        guard !allowedBundles.isEmpty else { return nil }
        // ⚠️ **复用之前先比名单**：helper 只在启动时读一次 env，进程活着不等于名单还是那一批。
        //    见 `Scope` 上那段（boss 报「我明明加了」就是这个）。
        let wanted = Self.Scope(read: allowedBundles, act: actBundles,
                                image: imageBundles, takeover: takeover, tap: tap, type: type)
        if let socketPath, process?.isRunning == true, runningScope == wanted {
            return socketPath
        }
        // 名单变了（或进程不在）⇒ 旧的必须收掉：留着一个按旧名单办的助手，
        // 模型会一直拿到"不在范围内"，而人看到的设置页是勾着的。
        if process?.isRunning == true { stop() }

        let sock = Self.socketPath(home: home, id: UUID().uuidString)
        let exe = Self.helperPath(bundlePath: bundlePath)
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = [sock]
        var env = ProcessInfo.processInfo.environment
        env[Self.allowedBundlesEnvKey] = allowedBundles.joined(separator: ",")
        // ⚠️ 操作面**恒设**, 空串也设: helper 把空当"不许动"。不设的话它读到 nil,
        //    虽然结论一样(都拒), 但"这次 spawn 到底有没有下发操作面"就看不出来了。
        env[Self.actBundlesEnvKey] = actBundles.joined(separator: ",")
        // ⚠️ 图像面同款: **恒设**, 空串也设 —— "空"对 helper 是"一张都不拍"。
        env[Self.imageBundlesEnvKey] = imageBundles.joined(separator: ",")
        env[Self.peerPidEnvKey] = String(peerPid)
        env[Self.parentPidEnvKey] = String(peerPid)
        // ⚠️ 批 3b: **要就写 "1", 不要就删掉** —— 不能只写"要"的那支:
        //    用户在终端 export 过它再从那个 shell 起 App, 就变成"档位是无人值守, 却在装监听",
        //    而界面上没有任何地方说得清这件事。
        env[Self.takeoverEnvKey] = takeover ? "1" : nil
        // 第四档同款: **要就写 "1", 不要就删掉**。键名取自判据文件(两个 target 共用一个常量)。
        env[ComputerTapRule.envKey] = tap ? "1" : nil
        // 第五档同款, 但**另一个键**: 两档两件事(点错看得见 / 打进去的字可能被回车发出去)。
        env[ComputerTypeRule.envKey] = type ? "1" : nil
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
        runningScope = wanted
        return sock
    }

    /// 收。App 侧 `terminate()` 之后 helper 自己也会因为探活失败退出(双保险, 不是靠一层)。
    func stop() {
        process?.terminate()
        process = nil
        socketPath = nil
        // ⚠️ 作用域标记必须跟着清: 留着它, 下次 `start` 会以为"这个名单已经下发过了",
        //    而实际上进程已经没了 —— 那正好是这条判据要防的反面。
        runningScope = nil
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
                            actBundles: [String] = [],
                            imageBundles: [String] = [],
                            takeover: Bool = false,
                            tap: Bool = false,
                            type: Bool = false,
                            peerPid: pid_t,
                            inherited: [String: String]) -> [String: String]? {
        let keys = [sockEnvKey, allowedBundlesEnvKey, actBundlesEnvKey, imageBundlesEnvKey,
                    peerPidEnvKey, parentPidEnvKey, takeoverEnvKey, ComputerTapRule.envKey,
                    ComputerTypeRule.envKey]
        if socketPath == nil, keys.allSatisfy({ inherited[$0] == nil }) { return nil }
        var env = existing ?? inherited
        env[sockEnvKey] = socketPath
        env[allowedBundlesEnvKey] = socketPath == nil ? nil : allowedBundles.joined(separator: ",")
        env[actBundlesEnvKey] = socketPath == nil ? nil : actBundles.joined(separator: ",")
        env[imageBundlesEnvKey] = socketPath == nil ? nil : imageBundles.joined(separator: ",")
        env[peerPidEnvKey] = socketPath == nil ? nil : String(peerPid)
        env[parentPidEnvKey] = env[peerPidEnvKey]
        // 批 3b: 没 socket(不挂扩展) ⇒ 连这个键一起清掉。"没人用的 env 留着"就是下次
        // 排查时的一条假线索(它会看起来像"这一档装了监听")。
        env[takeoverEnvKey] = (socketPath != nil && takeover) ? "1" : nil
        // 第四档同款: 没 socket 就一起清掉(同一理由: 留着的 env 会变成排查时的假线索)。
        env[ComputerTapRule.envKey] = (socketPath != nil && tap) ? "1" : nil
        // 第五档同款, 同样的清理口径(没 socket 就一起清掉)。
        env[ComputerTypeRule.envKey] = (socketPath != nil && type) ? "1" : nil
        return env
    }
}
