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

    /// 这个路径上**真的有人在听吗**（不是"文件在不在"）。
    ///
    /// ⚠️ 为什么要这一条（2026-11-13 boss 实测）: `start()` 原来只等**文件出现**就返回路径,
    ///    而"文件在"有两种: ① helper 正听着 ② helper 绑过又没了(它的 SIGTERM 处理器当时
    ///    不 unlink, 见 `installTerminationCleanup`)。第 ② 种下 App 会把路径发下去、把扩展挂上,
    ///    然后这一整轮每一次 `computer_read` 都是 `ECONNREFUSED` ——
    ///    而模型看到的是"连不上", 人看到的是"设置页勾着"。
    ///    ⇒ 判据必须是**连一次**(connect 成功 = backlog 里有监听者), 不是 `fileExists`。
    ///
    /// connect 之后立刻 close: helper 会 accept 到一个空连接, `recv` 返回 0 就关掉,
    /// 不产生任何请求、不改任何状态(它的 accept 循环本来就是串行的, 多一个空连接零代价)。
    /// ⚠️ `nonisolated`: 它只做一次 `connect` 系统调用, 不碰任何状态 —— 而判据要能在
    ///    任意上下文里调(冒烟的等待循环、后台探测), 绑在 `@MainActor` 上只会逼调用方 await。
    nonisolated static func socketIsListening(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = path.utf8
            // 留一格给结尾的 NUL —— `sun_path` 是 C 串, 写满就没有终止符了。
            let n = min(bytes.count, buf.count - 1)
            buf.copyBytes(from: Array(bytes.prefix(n)))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size) == 0
            }
        }
        return ok
    }

    /// 扫掉 `<home>/.mangox/compute-*.sock` 里**没人在听**的那些。
    ///
    /// ⚠️ 为什么要有它（2026-11-13）: 死 socket 不会自己消失 —— 实测攒了 4 个
    ///    (11-10 / 11-11 / 14:37 / 15:38), 每个都指向一条**没人听的路径**。
    ///    危害不是占几字节, 是**排查时会把它当成"进程还没起"**, 于是往错的方向查半天。
    ///    App 的 `stop()` 和 helper 自己的信号处理器现在都会删各自那一个, 但**两边都漏掉的
    ///    情况永远存在**(比如上一个 MangoX 实例被强杀) ⇒ 这里兜底。
    ///
    /// ⚠️ 判据是**连一次**, 不是看文件: 文件在有两种意思, 而只有"有人在听"才该留。
    ///    连接成功 = accept backlog 里有监听者 ⇒ 那条是别人的(可能另一个 MangoX 实例的),
    ///    **一个字节都别动**。
    /// ⚠️ 只碰 `compute-<UUID>.sock` 这个名字形状, 目录里别的东西一概不看。
    nonisolated static func sweepDeadSockets(home: String) {
        let dir = home + "/.mangox"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasPrefix("compute-") && name.hasSuffix(".sock") {
            let path = dir + "/" + name
            if socketIsListening(path) { continue }
            unlink(path)
        }
    }

    // MARK: - 状态

    /// ⚠️ **一个会话一份**(2026-11-12 boss 拍板), 不是全局单例。
    ///
    ///    前情: 这里原来就长这样, 但**从来没有人停过它们** —— 每开一个会话 spawn 一个 helper
    ///    (每个都握着「辅助功能 + 屏幕录制」两份 TCC), `shutdown()` 只 terminate pi,
    ///    helper 一个都不收(实测: 两个 helper 同时在跑, 其中一个已运行 1 小时 33 分;
    ///    `~/.mangox/compute-*.sock` 越攒越多)。修过错法的那一版先试过"全局共享一份",
    ///    结论是**不行**:
    ///
    ///    `Scope` 里有一项是**每会话**的 —— `takeover` 取自 `approvalMode.expectsHumanAtKeyboard`。
    ///    两个会话档位不同(「每步确认」/「全自动」) ⇒ 作用域不同 ⇒ 共享的那一份被反复重启;
    ///    而 socket 路径每次 spawn 都换 UUID ⇒ 先起的那个会话的 pi 拿着旧路径**永远连不上**
    ///    (症状就是 `ECONNREFUSED`)。共享一份还逼着所有会话排队在同一个串行 `accept` 上。
    ///    ⇒ 隔离优先: 会话之间**不许**互相影响, 哪怕代价是 N 份进程。实测 2~3 份可接受
    ///      (而且 `start` 在名单为空时根本不起进程, 没开这一档的会话零成本)。
    ///
    ///    ⚠️ 所以本类的**唯一**生命周期责任是: 会话收 ⇒ `stop()` 必须真把进程和 socket 收掉。
    ///       `PiRpcTransport.shutdown()` 负责调它(见那边的注释), 门在 `T-HOST` + `run.sh` ③v。

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
        // ⚠️ 空名单 = 没开放 ⇒ 不起进程(也没开这一档的会话零成本: 不 spawn、不占 TCC)。
        if allowedBundles.isEmpty { return nil }
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

        // 起新的之前先把历代残留清掉（只清**没人在听**的, 见 `sweepDeadSockets`）。
        Self.sweepDeadSockets(home: home)

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

        // ⚠️ **退出原因必须留一条记录**（2026-11-13 现场）: 老板报"12 秒读完之后 compute 进程
        //    就没了、socket 文件还在", 事后**完全无法归因** —— 没有崩溃报告, helper 的 stderr
        //    又被 `errPipe` 收走没人看。而 `terminationReason` 正好把两种死法分开:
        //      `.exit`             = 它自己退了(包括被 SIGTERM 收掉 —— 我们的处理器里就是 exit(0))
        //      `.unhandledSignal`  = 被信号打死(SIGKILL / 崩在信号上), 那才是"无故消失"
        //    ⇒ 下次再发生, `~/.mangox/log` 里就有死因, 不用再猜。
        //    ⚠️ 必须在 `run()` **之前**装上: 装晚了, 死得早的那个一条都记不下来。
        func watch(_ proc: Process) {
            proc.terminationHandler = { done in
                Log.process("compute-exit", [
                    "status": "\(done.terminationStatus)",
                    "reason": done.terminationReason == .uncaughtSignal ? "signal" : "exit",
                ])
            }
        }
        watch(p)

        do {
            try p.run()
        } catch {
            Log.process("compute-spawn-failed",
                        ["err": String(describing: error).prefix(120).description])
            return nil
        }
        process = p

        // ⚠️ 等**真的有人在听**再返回, 不是"等文件出现"。两者的差别就是 2026-11-13 那个
        //    `ECONNREFUSED`: 文件在、人不在(绑过又没了), 而 App 照常把路径发下去。
        //    ⚠️ **这里是主线程**（本类整体 `@MainActor`）⇒ 等待必须短。600ms 一次是实测够用的
        //    （旧代码等 500ms 一直没出过"太慢"的问题, helper 起监听在毫秒级）。
        //    ⚠️ 重试**一次**才认输 —— 起不来多半是瞬时的(刚停机、目录刚建),
        //      但也不许无限重试: 上层靠 `nil` 决定"这一轮别挂扩展"。
        //      两个上限相乘 = 最坏阻塞 1.2 秒, 这是这一版愿意付的上界。
        var listening = false
        for attempt in 0..<2 where !listening {
            if attempt > 0 {
                p.terminate()
                unlink(sock)
                let again = Process()
                again.executableURL = p.executableURL
                again.arguments = p.arguments
                again.environment = p.environment
                watch(again)
                do { try again.run() } catch { break }
                process = again
            }
            for _ in 0..<6 {
                if Self.socketIsListening(sock) { listening = true; break }
                usleep(100_000)
            }
        }
        guard listening else {
            // 起不来就**如实说**: 给一条连不上的路径, 换来的是整轮每一次读都 `ECONNREFUSED`,
            // 而模型会把它读成"界面上什么都没有"。
            process?.terminate()
            process = nil
            unlink(sock)
            return nil
        }
        socketPath = sock
        runningScope = wanted
        return sock
    }

    /// 收: 结束进程 + 删 socket 文件。**会话结束必须调它**。
    ///
    /// App 侧 `terminate()` 之后 helper 自己也会因为探活失败退出(双保险, 不是靠一层)。
    /// 幂等 —— 没起过、已经收过, 都是空操作。
    ///
    /// ⚠️ 两步都**不能省**:
    ///    ① `terminate()` —— 原来 `shutdown()` 只拆 pi, helper 一个都不停, 于是每开一个会话
    ///       就多一个握着「辅助功能 + 屏幕录制」的子进程(实测有一个跑了 1 小时 33 分)。
    ///    ② `unlink(socket)` —— 2026-11-13 之前 helper 的 SIGTERM 处理器只 `exit(0)`、
    ///       **不删文件**, 全指望这里补刀; 现在它自己也删了(见 `installTerminationCleanup`),
    ///       但这一步**仍然不能省**: 谁来发信号不归我们管(系统 / `killall` / 调试时手敲),
    ///       而"App 收会话"是最确定会发生的那一次。
    ///       那些死文件不是"无害的空文件": 排查时 `ls ~/.mangox/*.sock` 会指向一个
    ///       **根本没人在听的路径**, 而这正是"读不到界面"最像的那种现场(2026-11-11 实测攒了两个,
    ///       2026-11-13 攒到四个)。
    func stop() {
        process?.terminate()
        process = nil
        // ⚠️ 顺序: 先记下路径再清字段 —— 清完再读 `socketPath` 永远是 nil,
        //    那一步 unlink 就成了**永远不执行**的代码(看着有, 实际没跑)。实测踩过。
        let dying = socketPath
        socketPath = nil
        // ⚠️ 作用域标记必须跟着清: 留着它, 下次 `start` 会以为"这个名单已经下发过了",
        //    而实际上进程已经没了 —— 那正好是这条判据要防的反面。
        runningScope = nil
        if let path = dying { unlink(path) }
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
