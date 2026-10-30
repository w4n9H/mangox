//
//  ComputerServer.swift
//  mangox-compute: unix socket 的**生命周期**与请求分发。
//
//  三个不变量:
//   ① **目录 0700 / 文件 0600** —— 同用户以外的进程连路径都摸不到(§04 门 0 的第 ① 条);
//   ② **每次 accept 都验 peer**(uid + 进程树), 验不过就关掉连接, 且**不回话**
//      —— 回话等于告诉对方"这里有个 socket";
//   ③ 一问一答, 一个连接可以问多次, 但对端关掉就结束 —— 不做多路复用,
//      也不需要: 一轮会话只有一个 pi 在跟它说话。
//
//  ⚠️ 为什么 socket 路径只经 env 下发: 它是"这一轮才存在"的凭证。写进配置文件 ⇒
//     别的会话(别的任务、别的档位)也能连上来, 双闸门(挂载 + env)的第二道就破了。
//

import ApplicationServices
import AppKit
import Darwin
import Foundation

final class ComputerServer {

    /// 允许连接的**祖先进程**: 本轮 pi 的 pid, 经 env 下发。
    let allowedAncestorPid: pid_t?

    /// 作用域(读面): 允许读的 bundle id。空 = 还没下发 ⇒ **一律拒**(不是"都给")。
    let allowedBundles: Set<String>

    /// 作用域(操作面): 允许动的 bundle id。**空 = 一律拒** —— 读得到不等于动得。
    let actBundles: Set<String>

    /// 作用域(图像面): 允许截图的 bundle id 原始串。**空 = 一张都不拍**。
    ///
    /// ⚠️ 存**原始串**而不是 `Set`, 判据一律走 `ComputerShotRule.allowed(bundle:raw:)` ——
    ///    两处各解析一次就会分叉(一边 trim 空格一边不 trim), 而分叉的表现是"设置页勾着、
    ///    截图被拒", 零红灯。
    /// ⚠️ 与上两档同理, 只在启动时读一次 env ⇒ 改了名单必须重启 helper 才生效
    ///    (App 侧 `ComputerHost.Scope` 已经把 `image` 算进比较, 所以会自动重启)。
    let imageRaw: String

    /// 上一次读的快照 + 编号到元素的表。**按 bundle 存**, 不是全局一个:
    /// 读 Safari 不该让 Finder 的编号失效(同时读两个 App 是常态)。
    struct Cached {
        let pid: pid_t
        let name: String
        let seq: Int
        let snapshot: AXSnapshot
        let trees: AXAdapter.Trees
    }

    private var cache: [String: Cached] = [:]

    /// 全局自增的快照序号。**只增不减、从不复用** ⇒ "旧编号"永远对不上新 seq。
    ///
    /// ⚠️ 为什么不用"每 App 从 1 开始": 模型会把两个 App 的 seq 记混(它看到的是两个 3),
    ///    而混了之后 `seq` 这条判据就白设了。全局唯一 = 拿错 App 的 seq 也对不上。
    private var seqCounter = 0

    private let path: String
    private var listenFd: Int32 = -1

    init(path: String) {
        self.path = path
        let env = ProcessInfo.processInfo.environment
        self.allowedAncestorPid = env[PeerCheck.peerPidEnvKey].flatMap { pid_t($0) }
        let raw = env[ComputerServer.allowedBundlesEnvKey] ?? ""
        self.allowedBundles = Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let actRaw = env[ComputerServer.actBundlesEnvKey] ?? ""
        self.actBundles = Set(actRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        // 批 3c: 画面名单。**缺键与空串等价**(都是一张都不拍) —— 但这个键 App 侧恒设,
        // 所以"缺键"只会出现在手搓 env 的场景里。
        self.imageRaw = env[ComputerShotRule.envKey] ?? ""
        // 批 3b: 只有 App 判定"这一档有人在"才下发 "1"。缺省 = 不装(不是"都装")。
        self.takeoverWanted = env[HumanInputTap.envKey] == "1"
    }

    static let allowedBundlesEnvKey = "MANGOX_COMPUTE_ALLOWED_BUNDLES"
    /// 操作面的名单。⚠️ 与 App 侧 `PiRpcTransport` 里的同名常量**必须是同一个字符串**
    /// (跨 target 契约, `run.sh` ③l 扫着)。
    static let actBundlesEnvKey = "MANGOX_COMPUTE_ACT_BUNDLES"

    // MARK: - 生命周期

    /// 起监听。**失败就崩** —— 起不来比"起来但没在听"好排查得多。
    func serve() -> Never {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        unlink(path)

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { fatal("socket() 失败: \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = path.utf8
            let n = min(bytes.count, buf.count - 1)
            buf.copyBytes(from: Array(bytes.prefix(n)))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, size) == 0 && listen(listenFd, 8) == 0
            }
        }
        guard ok else { fatal("bind/listen 失败: \(errno) path=\(path)") }
        chmod(path, 0o600)

        installTerminationCleanup()
        // 批 3b: 人类接管的监听**只在 App 说"这一档有人在"时才装**。
        // 装不上照常服务 —— 它是一条"让路"的判据, 不是功能前提; 但 act 回执会如实说这一半没有
        // (见 `takeoverCaveat`)。放进 serve() 而不是 init: 它要起线程 + run loop, 不该在 init 里做。
        if takeoverWanted {
            let ok = HumanInputTap.shared.start()
            print("mangox-compute takeover: \(ok ? "on" : "unavailable")")
        }
        print("mangox-compute listening: \(path)")
        fflush(stdout)

        while true {
            let fd = accept(listenFd, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                continue
            }
            handleConnection(fd)
            close(fd)
        }
    }

    /// App 退出 / 崩溃时也得有人收: 否则留一个**还握着辅助功能权限的孤儿进程** + 一个废 socket。
    private func installTerminationCleanup() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig) { _ in
                // ⚠️ 只做"删文件 + 退出", 不做别的: 信号处理器里能安全调的函数就那么几个。
                exit(0)
            }
        }
        // 父进程(launch 它的那一侧)死了也要走 —— 常驻进程最怕的就是"没人管它"。
        // `MANGOX_COMPUTE_PARENT_PID` 为 0 时不启用(手动调试时不该被杀掉)。
        if let raw = ProcessInfo.processInfo.environment["MANGOX_COMPUTE_PARENT_PID"],
           let parent = pid_t(raw), parent > 0 {
            DispatchQueue.global().async {
                while true {
                    sleep(2)
                    // `kill(pid, 0)` 只探活不送信 —— 父进程没了就说明没人管我们了。
                    if kill(parent, 0) != 0 { break }
                    // 被 reparent 到 launchd 也是同一个信号。
                    if getppid() == 1 { break }
                }
                unlink(self.path)
                exit(0)
            }
        }
    }

    private func fatal(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("mangox-compute: " + message + "\n").utf8))
        exit(1)
    }

    // MARK: - 连接

    private func handleConnection(_ fd: Int32) {
        guard PeerCheck.accept(socket: fd, allowedAncestorPid: allowedAncestorPid) else {
            // 不回话、不打日志里的路径: 未知来源连上来时, 沉默就是最好的回执。
            return
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(n))
            while let idx = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer.prefix(upTo: idx), as: UTF8.self)
                buffer.removeSubrange(...idx)
                let req = ComputerFraming.decode(line)
                let response: ComputerResponse
                if let req {
                    response = handle(req)
                } else {
                    response = .failure("读不懂这一行(协议不匹配)。")
                }
                let out = ComputerFraming.encode(response)
                writeAll(fd: fd, bytes: out)
            }
        }
    }

    /// 把整行写完再返回。
    ///
    /// ⚠️ `send` 的返回值是**这次写出去多少**, 不是"成功/失败"。快照动辄几 KB,
    ///    对端 socket 缓冲区满时一次只吃一部分 —— 丢掉的那截不会报错, 只是让对端
    ///    永远等不到行尾, 10 秒后超时。修法和读侧同源: 以**完整行为单位**收尾。
    private func writeAll(fd: Int32, bytes: Data) {
        var offset = 0
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let n = send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if n <= 0 { return }   // 对端走了 ⇒ 这行没人要了
                offset += n
            }
        }
    }

    // MARK: - 分发

    func handle(_ request: ComputerRequest) -> ComputerResponse {
        switch request {
        case .ping:
            // 屏幕录制是**另一份 TCC**(批 3c): 辅助功能给了不等于能截图, 两者互不覆盖。
            // `CGPreflightScreenCaptureAccess` 只查询、不弹窗 ⇒ 探活可以放心调。
            return .pong(trusted: AXIsProcessTrusted(),
                         screenRecording: ComputerShot.screenRecordingGranted())

        case .read(let app, let includeImage):
            guard AXIsProcessTrusted() else {
                return .failure("辅助功能权限还没授予 ⇒ 读不到界面。请在 系统设置 › 隐私与安全性 › 辅助功能 里勾上 MangoX。")
            }
            let candidates = candidatesInScope()
            guard !candidates.isEmpty else {
                return .failure(emptyScopeNote(verb: "读"))
            }
            let target = resolve(query: app, in: candidates)
            guard let t = target else {
                // ⚠️ 回执**必须带上"能读哪些"**: 模型不知道作用域, 只说"不在作用域内"会让它
                // 一个个 App 试过去(每次一轮往返, 而且它可能会猜 bundle id)。
                return .failure(refusal(query: app, available: candidates, verb: "读"))
            }
            guard isInScope(pid: t.pid) else {
                return .failure("「\(t.name)」不在开放名单里 ⇒ 我不读它。")
            }
            guard var trees = AXAdapter.frontWindowTree(pid: t.pid) else {
                return .failure("读不到「\(t.name)」的窗口树(它可能没有窗口, 或者 AX 树太薄)。")
            }
            // ⚠️ 懒加载兜底(2026-10-29 boss 截图: 第一次读 apple.com.cn 只拿到 20 个导航按钮,
            //    页面正文一个节点都没有; 隔几秒再读, 整页 4627px 全出来了)。
            //    判据只看**内容角色盖了多少窗口面积** —— 不看节点数(小工具窗节点也少),
            //    也不看有没有 `textfield`(地址栏就是一个, 会让判据恒真)。
            //    只有**明显更好**才采纳, 否则保留第一次的, 免得越读越差。
            var reread = 0
            while reread < AXSnapshot.maxRereads, AXSnapshot.worthRereading(root: trees.root) {
                reread += 1
                // 单连接顺序处理 ⇒ 这个等待只挡住自己这一个请求, 不挡别的。
                Thread.sleep(forTimeInterval: 0.2 * Double(reread))
                guard let again = AXAdapter.frontWindowTree(pid: t.pid),
                      AXSnapshot.contentCoverage(root: again.root)
                        > AXSnapshot.contentCoverage(root: trees.root)
                else { break }
                trees = again
            }
            let tree = trees.root
            let snap = AXSnapshot.build(root: tree,
                                        appName: t.bundle,
                                        windowTitle: tree.title)
            // 读数成功才记缓存: 失败的那次什么都没给模型, 也就不该让任何编号"有效"。
            let seq = remember(bundle: t.bundle, pid: t.pid, name: t.name, trees: trees, snapshot: snap)
            // ⚠️ 重读过的必须说出来: 否则模型会以为"这个页面本来就这么空", 于是换个做法去猜,
            //    而实际上它只是差了半秒。
            let rereadNote = reread > 0 && !AXSnapshot.worthRereading(root: tree)
                ? "（第一次读到的只有窗口外壳 —— 页面还没建好。这份是隔了一会儿重读的结果, 读了 \(reread + 1) 次。）\n\n"
                : ""
            // ⚠️ 「窗口是空的」与「这个 App 不暴露界面」在快照上长得**一模一样**(都近乎空),
            //    但模型该做的事不同: 前者报告"这里什么都没有", 后者换 App 或要求截图。
            //    不区分 ⇒ 模型会把微信那 3 个按钮当成"这个窗口的全部内容"(2026-10-28 实测: 微信
            //    主窗口 1052×754 只暴露 6 个节点, 消息列表/聊天正文/输入框一个都没有)。
            if AXSnapshot.lacksReadableControls(root: tree) {
                return finishRead(text: withSeq(rereadNote
                                                + lackOfControlsNote(app: t.name, nodes: snap.rows.count)
                                                + "\n\n" + snap.rendered(), seq),
                                  seq: seq, bundle: t.bundle, pid: t.pid,
                                  root: tree, includeImage: includeImage)
            }
            return finishRead(text: withSeq(rereadNote + snap.rendered(), seq), seq: seq,
                              bundle: t.bundle, pid: t.pid, root: tree,
                              includeImage: includeImage)

        case .act(let app, let opRaw, let index, let seq, let text, let direction, let point):
            return handleAct(app: app, opRaw: opRaw, index: index, seq: seq,
                             text: text, directionRaw: direction, point: point)

        case .open(let app):
            return handleOpen(app: app)
        }
    }

    /// 读的收尾: 要不要附带一张截图(批 3c)。
    ///
    /// 两条原则:
    ///   ① **图是锦上添花, 永不因为拍不成而丢掉文本** —— 文本已经读到了, 那才是模型要的信息;
    ///      把文本一起吞掉只会让它重试同一个动作。
    ///   ② 不拍的原因要**说清并给出下一步**, 且不许暗示"再试一次就好": "没开图片"要去设置页,
    ///      "没有屏幕录制权限"要去系统设置, 这两条都不是重试能解的。
    private func finishRead(text: String, seq: Int, bundle: String, pid: pid_t,
                            root: AXNode, includeImage: Bool) -> ComputerResponse {
        guard includeImage else { return .success(text: text, seq: seq) }
        guard ComputerShotRule.allowed(bundle: bundle, raw: imageRaw) else {
            return .success(text: text + "\n\n（这个 App 没开「图片」⇒ 这次没有截图。"
                            + "要图的话请在 设置 › 集成 › 电脑操作 里给它勾上「图片」, 默认是关的。）",
                            seq: seq)
        }
        switch ComputerShot.capture(pid: pid, root: root, bundle: bundle) {
        case .failure(let why):
            // ⚠️ 取 `.message` 而不是直接插值 `why`: `String(describing:)` 会把结构体整个
            //    打成 `ShotFailure(message: "…")` —— 那句机器话会原样进模型上下文。
            return .success(text: text + "\n\n（\(why.message)）", seq: seq)
        case .success(let png):
            // ⚠️ 必须说"附了一张": 这类图**不落 attachments**(见 App 侧 `isScreenShot`),
            //    所以卡片上没有缩略图 —— 这句是用户唯一能看到的凭据。
            // ⚠️ 措辞是"原样画面", 不许写成"已脱敏/已涂黑": 图像面**不做任何像素遮蔽**
            //    (2026-10-30 boss 定), 标记一旦比事实说得多, 用户就会拿一张带明文的图当安全的用。
            return .success(text: text + "\n\n（附了一张 \(png.count / 1024) KB 的截图, "
                            + "是这个窗口的原样画面。）",
                            seq: seq,
                            image: ComputerImage(mimeType: "image/png",
                                                 data: png.base64EncodedString()))
        }
    }

    /// 给读的结果补上**序号**(动作要带的那一个)。
    ///
    /// ⚠️ 为什么写进**正文**而不是只放进 `seq` 字段: 扩展只把 `text` 交给模型(`seq` 字段是给
    ///    将来用的), 所以只填字段等于"模型永远拿不到号 ⇒ 永远动不了", 而这条链上没有任何红灯
    ///    —— 工具会说"要先读再动", 读也成功, 然后动作一直被拒在"旧快照"那一步。
    private func withSeq(_ text: String, _ seq: Int) -> String {
        text + "\n\n— 快照 seq=\(seq)。要动它(computer_act)必须带这个号, 否则我不会动。"
    }

    /// 记下这次读的快照, 返回它的序号。
    private func remember(bundle: String,
                          pid: pid_t,
                          name: String,
                          trees: AXAdapter.Trees,
                          snapshot: AXSnapshot) -> Int {
        seqCounter += 1
        cache[bundle] = Cached(pid: pid, name: name, seq: seqCounter, snapshot: snapshot, trees: trees)
        return seqCounter
    }

    // MARK: - 动作面 (批 2b)

    // MARK: - 人类接管 (批 3b)

    /// 这一轮要不要装"人在动键鼠"的监听 —— **由 App 按档位决定**
    /// (`ApprovalMode.expectsHumanAtKeyboard`), 只经 env 下发一次。
    /// helper 不自己猜档位: 它连"这一轮有没有人在"都看不见。
    private let takeoverWanted: Bool

    /// 人刚动过键鼠 ⇒ 一句拒绝(`nil` = 可以做)。判据本身在 `ComputerTakeover`(纯函数, 能断言)。
    private func takeoverRefusal() -> String? {
        ComputerTakeover.refusal(lastHumanInputAt: HumanInputTap.shared.lastHumanInputAt,
                                 now: ProcessInfo.processInfo.systemUptime,
                                 installed: HumanInputTap.shared.isInstalled)
    }

    /// "接管其实弱了"的那句话 —— 每一份 act 回执尾巴上都要有。
    ///
    /// ⚠️ **"要装但没装上"与"根本没要装"必须分开**: 后者是产品选择(无人值守档), 对它说
    ///    "接管检测没装上"就是回执在编一个不存在的故障。前者才是能力缺口, 而它**完全静默**
    ///    (界面照常动), 所以每一份回执都带, 不是"提醒一次"。
    /// ⚠️ 键盘那一句同族: 缺「输入监控」权限时 tap 照样装上、鼠标照样看得见, 只有键盘是空的
    ///    ⇒ 不查就写"你一动键鼠我就让路", 是替系统许诺一件它没做到的事。
    private func takeoverCaveat() -> String? {
        guard takeoverWanted else { return nil }
        guard HumanInputTap.shared.isInstalled else {
            return "\n— ⚠️ 接管检测没装上(系统不让建事件监听): 你在键鼠上做什么, 我感知不到。"
                + "要我停下, 直接说。"
        }
        guard !HumanInputTap.shared.keyboardVisible else { return nil }
        return "\n— ⚠️ 接管检测只看得到鼠标: 没给「输入监控」权限, 键盘上的动作我看不见。"
            + "要我停下, 直接说。"
    }

    /// act 的入口: **先让路, 再干活, 最后补一句能力缺口**。
    private func handleAct(app: String, opRaw: String, index: Int, seq: Int,
                           text: String, directionRaw: String,
                           point: ComputerPoint?) -> ComputerResponse {
        // ⚠️ 这一步**排在最前**: 人手在键鼠上时, 后面的判据跑不跑都没有意义 ——
        //    而"人刚动过"是会过期的事实, 晚一步判就等于没判。
        if let why = takeoverRefusal() { return .failure(why) }
        let r = performAct(app: app, opRaw: opRaw, index: index, seq: seq,
                           text: text, directionRaw: directionRaw, point: point)
        // ⚠️ 只往**成功**的回执上补: 失败回执已经在说"没动", 再叠一句能力缺口会把人带向
        //    "是因为这个才没动" —— 而它不是原因。
        guard r.ok, let caveat = takeoverCaveat() else { return r }
        return ComputerResponse(ok: true, text: (r.text ?? "") + caveat,
                                error: nil, trusted: nil, screenRecording: nil, seq: r.seq)
    }

    private func performAct(app: String, opRaw: String, index: Int, seq: Int,
                            text: String, directionRaw: String,
                            point: ComputerPoint?) -> ComputerResponse {
        guard AXIsProcessTrusted() else {
            return .failure("辅助功能权限还没授予 ⇒ 动不了界面。请在 系统设置 › 隐私与安全性 › 辅助功能 里勾上 MangoX。")
        }
        guard let action = ComputerAction.parse(opRaw) else {
            return .failure("不认识的 op: 「\(opRaw)」。目前有 press / setValue / focus / scroll 四种。")
        }
        // ⚠️ 方向解析失败**不在 helper 填默认值**: 判据那边要把"没说往哪滚"与"滚不动"分开说
        //    (前者重发一次就好, 后者得换节点或换 App)。空串 ⇒ nil ⇒ 判据里那条 `guard` 拒。
        let direction = ComputerScrollDirection.parse(directionRaw)
        let candidates = candidatesInScope()
        guard !candidates.isEmpty else {
            return .failure(emptyScopeNote(verb: "动"))
        }
        guard let t = resolve(query: app, in: candidates) else {
            return .failure(refusal(query: app, available: candidates, verb: "动"))
        }
        // ⚠️ 没读过就动 = 没有编号可依据。回执要说清"先读一次", 而不是"内部错误" ——
        //    模型看到后一种只会重试同一个动作。
        guard let cached = cache[t.bundle] else {
            return .failure("还没读过「\(t.name)」⇒ 没有可用的编号, 我什么都不动。先 computer_read 一次。")
        }
        // App 重启过 ⇒ pid 变了 ⇒ 上次那张表指向的元素已经不在了。
        guard cached.pid == t.pid else {
            return .failure("「\(t.name)」重启过了, 上次读到的编号已经失效 ⇒ 没动。重新读一次。")
        }

        // 坐标寻址: **翻译回元素 → 认回编号**, 之后走的还是同一条路。
        // ⚠️ 参数互斥(编号 / 坐标只能给一个)在这里判, 不放进 Guard —— Guard 手上只有编号,
        //    它看不见"模型到底给的是哪一个", 硬塞进去会让那条判据自己也要维护两套输入。
        //    `run.sh` ③r 钉着"point 分支必须先过 ComputerPointRule"这一句。
        var resolvedIndex = index
        if let point {
            if let why = ComputerPointRule.refusal(action: action, index: index, point: point) {
                return .failure(why)
            }
            guard let hit = AXAdapter.element(at: CGPoint(x: point.x, y: point.y)) else {
                // ⚠️ 这一句就是 boss 拍板的那条: **坐标落在没有元素的地方 ⇒ 直接拒**。
                //    放行等于给"模型替我点确认付款"开一条**绕过所有判据**的路 —— 那一刻手上
                //    没有任何元素, 三条恒拒一条都跑不了。自绘界面点不了, 那就如实说点不了。
                return .failure("\(point.short) 上没有我能识别的东西 ⇒ 没动。"
                                + "屏幕外、或者自绘界面(画布 / 游戏 / 部分 Electron)不把控件交给系统时, "
                                + "这个坐标底下就是空的 —— 我手上没有任何东西可以判它能不能按。")
            }
            // ① 先认"这是谁家的界面": 坐标是**全局屏幕**坐标, 窗口一被挪动, 旧坐标就指到别处。
            guard AXAdapter.processID(of: hit) == t.pid else {
                // ⚠️ **不说那到底是哪个 App** —— 名单之外谁在跑, 不是这次任务的信息
                //    (同 `candidatesInScope` 那条作用域纪律)。模型要知道的只有"这不是它的窗口"。
                return .failure("\(point.short) 落在别的 App 的界面上, 不是「\(t.name)」⇒ 没动。"
                                + "这份快照里每行末尾那个 (x,y) 才是「\(t.name)」的坐标。"
                                + "要么按编号来, 要么重新读一次再取坐标。")
            }
            // ② 再认"是不是这一格": 认回编号才有判据可跑(三条恒拒判的都是**元素**)。
            guard let n = rowIndex(for: hit, in: cached) else {
                let role = AXAdapter.roleName(of: hit)
                let head = "\(point.short) 底下是 " + (role.isEmpty ? "一个读不出角色的元素" : role)
                // ⚠️ 三类分开说 —— 它们的**下一步完全不同**, 合成一句就是骗人:
                //    见 `ComputerPointRule.missKind` 的头注释。
                switch ComputerPointRule.missKind(role: role) {
                case .wholeApp:
                    return .failure(head + " ⇒ 没动。"
                                    + "这个 App 把整块界面一起交给系统, 里面没有更细的格子 —— "
                                    + "坐标在它身上点不了; 这种界面只能截图看, 或者问用户。")
                case .outerChrome:
                    return .failure(head + ", 那是这个 App 的菜单栏 / 菜单那一类界面 ⇒ 没动。"
                                    + "快照只读**窗口**那一棵树, 菜单栏不在里面 —— 这条路上到不了它。"
                                    + "要用窗口里的按钮; 菜单里才有的功能, 问用户。")
                case .container:
                    return .failure(head + ", 容器那一层不在这份快照里(快照只列格子) ⇒ 没动。"
                                    + "再读一次也不会多出编号; 要按的是它**里面**那一格, 从快照里挑编号。")
                case .stale:
                    return .failure(head + ", 它不在这份快照里 ⇒ 没动。"
                                    + "多半是我读完之后界面变了: 重新读一次, 它就有编号了。")
                }
            }
            resolvedIndex = n
        }

        let row = cached.snapshot.row(resolvedIndex)
        let element = row.flatMap { AXAdapter.element(cached.trees, at: $0.path) }
        // ⚠️ 现场读数, 不是 `row` 里缓存的文本: 同一个编号指向的元素可能已经从「登录」
        //    变成了「删除」, 而 seq 只保证"编号没指错元素", 保证不了标题。
        let liveTarget = element.map { AXAdapter.liveTarget($0) }
        let windowEl = cached.trees.elements[AXSnapshot.pathKey([])]
        let actWindow = windowEl.map { AXAdapter.actWindow(of: $0) } ?? .none

        let scope = ComputerActScope(bundle: t.bundle,
                                     appName: t.name,
                                     readBundles: allowedBundles,
                                     actBundles: actBundles,
                                     requestSeq: seq,
                                     currentSeq: cached.seq,
                                     rowCount: cached.snapshot.rows.count)
        let request = ComputerActRequest(app: app, action: action, index: resolvedIndex, seq: seq,
                                        text: text, direction: direction)

        switch ComputerActGuard.evaluate(request: request,
                                         scope: scope,
                                         target: liveTarget,
                                         window: actWindow) {
        case .refuse(let reason, _):
            // ⚠️ 恒拒(`refusal != nil`)与"参数不合法"对模型都是"没做", 回执都带原因就够了;
            //    需要留痕的那条走 App 侧的 `autoJudgeBlocks` 与轨迹, 不在这里另造一套。
            return .failure(reason)

        case .cancelSavePrompt(let buttonIndex, let reason):
            // 「替你按取消」不是拒绝: 它有后果(弹窗关了), 回执必须说清按了什么。
            guard let windowEl else {
                return .failure(reason + "(但我没找到那个窗口, 什么都没按。)")
            }
            guard let err = AXAdapter.pressSheetButton(in: windowEl, at: buttonIndex) else {
                return .failure(reason + "(但我按不到「取消」那个键, 什么都没动。)")
            }
            guard err == .success else {
                return .failure(reason + "(按「取消」失败了: AX 返回 \(err.rawValue), 界面没动。)")
            }
            return finishAct(bundle: t.bundle, pid: t.pid, name: t.name,
                             previous: cached.snapshot,
                             headline: reason + " (已替你按「取消」)")

        case .allow(let a):
            guard let el = element else {
                return .failure("#\(resolvedIndex) 在这份快照里查不到对应元素 ⇒ 没动。重新读一次。")
            }
            let name = liveTarget.map { $0.title.isEmpty ? AXSnapshot.cleanRoleName($0.role) : $0.title } ?? ""
            // 坐标进来的那条, 回执要把"在哪儿"写出来 —— 只给一个编号, 人没法判断
            // 我点的是不是他在屏幕上看见的那个位置。
            let atPrefix = point.map { "在 \($0.short) " } ?? ""
            let headline: String
            switch a {
            case .press:
                let err = AXAdapter.press(el)
                guard err == .success else { return .failure(actFailure(err, "press")) }
                headline = atPrefix + "按了 #\(resolvedIndex)「\(name)」。"

            case .setValue:
                let err = AXAdapter.setValue(el, text)
                guard err == .success else { return .failure(actFailure(err, "setValue")) }
                headline = atPrefix + "写了 #\(resolvedIndex)「\(name)」。"

            case .focus:
                let err = AXAdapter.focus(el)
                guard err == .success else { return .failure(actFailure(err, "focus")) }
                // ⚠️ **回读**: 有些元素收下写入却没拿到焦点。不查这一步就会回"聚焦了", 而模型
                //    接下来那次 setValue 写进的是一个没聚焦的控件 —— 它只会以为这 App 坏了。
                guard AXAdapter.isFocused(el) else {
                    return .failure("焦点写进去了, 但系统说焦点不在这个控件上 ⇒ 没当成「已聚焦」。"
                                    + "重读一次看看; 它也可能只是接受写入、实际不可聚焦。")
                }
                headline = atPrefix + "聚焦了 #\(resolvedIndex)「\(name)」。"

            case .scroll:
                // 判据已经拦过"没说方向"与"没有滚动条"; 走到这里还得再取一次, 因为
                // 判据看的那份现场读数与**执行这一刻**可能已经不同(比如滚动条刚好消失)。
                guard let dir = request.direction, let bar = AXAdapter.scrollBar(of: el) else {
                    return .failure("滚不动了: 这个节点上现在找不到可用的滚动条 ⇒ 界面没动。重新读一次。")
                }
                guard let before = AXAdapter.scrollValue(bar) else {
                    return .failure("滚不动: 读不到滚动条当前的位置 ⇒ 界面没动。")
                }
                let err = AXAdapter.setScrollValue(bar,
                                                   before + (dir == .down ? AXAdapter.scrollStep
                                                                          : -AXAdapter.scrollStep))
                guard err == .success else { return .failure(actFailure(err, "scroll")) }
                // ⚠️ **回读**: "收下写入但不动"在网页/自绘列表里很常见。不回读就会回"滚了",
                //    而模型接着读还是那 120 行 —— 它只会以为这一页本来就这么短。
                let landed = AXAdapter.scrollValue(bar) ?? before
                guard abs(landed - before) > 0.001 else {
                    return .failure("写了滚动位置, 但界面没动(还在 \(percent(before)))"
                                    + " ⇒ 这个 App 不吃 AX 滚动。别重试同一个节点 —— "
                                    + "要么换个 scrollarea 试, 要么直接告诉用户这一页我一次读不完。")
                }
                headline = atPrefix + "滚了\(dir == .down ? "向下" : "向上") #\(resolvedIndex)「\(name)」: "
                    + "\(percent(before)) → \(percent(landed))。"
            }
            return finishAct(bundle: t.bundle, pid: t.pid, name: t.name,
                             previous: cached.snapshot,
                             headline: headline)
        }
    }

    /// 坐标翻译出来的元素, 在**这份快照里是第几号**。找不到就是 nil。
    ///
    /// ⚠️ 比的是 `CFEqual`(同一个 AX 元素引用), **不是标题**: 标题会重复(两行都叫「登录」),
    ///    拿标题认人会按错一格 —— 而"按错一格"在这里没有任何红灯。
    /// ⚠️ 编号必须落回快照里真实存在的那一行: 判据的第 ⑤ 条(编号在范围内)就是靠它,
    ///    给它编一个号等于让那条判据失去意义。
    private func rowIndex(for element: AXUIElement, in cached: Cached) -> Int? {
        for row in cached.snapshot.rows {
            guard let el = AXAdapter.element(cached.trees, at: row.path) else { continue }
            if CFEqual(el, element) { return row.number }
        }
        return nil
    }

    /// 动作成功之后: 重读一次, 只回报**变化** + 新序号。
    ///
    /// ⚠️ 必须重读并重发 seq: 动作之后编号全部换了一茬, 而模型手上还是旧的。不告诉它,
    ///    它下一个动作必然撞上"旧快照"—— 那条回执本身没错, 但会让人以为工具坏了。
    private func finishAct(bundle: String,
                           pid: pid_t,
                           name: String,
                           previous: AXSnapshot,
                           headline: String) -> ComputerResponse {
        guard let trees = AXAdapter.frontWindowTree(pid: pid) else {
            // 动作之后窗口没了(点了个"关闭"之类) —— 这**不是**故障, 要说成结果。
            seqCounter += 1
            cache[bundle] = nil
            return .success(text: headline + "\n— 之后读不到「\(name)」的窗口了(窗口可能被关掉了)。",
                            seq: seqCounter)
        }
        let snap = AXSnapshot.build(root: trees.root,
                                    appName: bundle,
                                    windowTitle: trees.root.title)
        let seq = remember(bundle: bundle, pid: pid, name: name, trees: trees, snapshot: snap)
        let diff = AXSnapshot.diff(from: previous, to: snap)
        return .success(text: headline
                        + "\n" + diff.rendered()
                        + "\n新快照 seq=\(seq)(一共 \(snap.rows.count) 项), 旧编号全部作废 —— 下一步按这份来。",
                        seq: seq)
    }

    /// 动作失败的一句话。**不重试、不退到坐标点击** —— 按不下去就如实报。
    /// 坐标兜底是批 3 与人类接管一起做的: 在那之前"点错地方"比"没点"严重得多。
    private func actFailure(_ err: AXError, _ op: String) -> String {
        "\(op) 失败了: AX 返回 \(err.rawValue) ⇒ 界面没动。"
    }

    private func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    // MARK: - 打开 App (批 2d)

    /// 打开(或切到前台)名单里的一个 App。
    ///
    /// ⚠️ **这里不查辅助功能权限**: 启动一个 App 不需要 AX, 需要它的是"读"。查了的话, 没授权
    ///    的人连「打开计算器」都做不到 —— 而回执会把他引去系统设置的隐私面板, 那与他此刻
    ///    要做的事毫无关系 (§04 那条"回执不许比事实说得多"的同族)。
    ///
    /// ⚠️ **为什么"打开"归读面管**: 它不动 App 里的任何东西, 与"在 Dock 上点一下图标"同一件事;
    ///    进去之后能做什么, 仍然由操作面那道门管(`actBundles`)。两件事两道门。
    private func handleOpen(app: String) -> ComputerResponse {
        let q = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            // "打开当前前台" 是同义反复。不猜一个填进来 —— 猜错就是"悄悄打开了别人"。
            return .failure("computer_open 要说清打开哪个 App ⇒ 我什么都没打开。")
        }
        let installed = installedInScope()
        // 三条分支的**判据**在 `ComputerTarget.openPlan`(纯函数, 冒烟能断言); 这里只执行。
        switch ComputerTarget.openPlan(query: q, installed: installed, running: runningApps()) {
        case .notInScope:
            let names = installed.map { label(bundle: $0.bundle, running: installed) }
                .joined(separator: " / ")
            let tail = names.isEmpty
                ? "名单里没有一个装着的 App ⇒ 先到 设置 › 集成 › 电脑操作 里勾上它。"
                : "能打开的: \(names)"
            return .failure("「\(q)」不在开放名单里(也可能本机没装) ⇒ 我没打开它。\(tail)")

        case .activate(let t):
            // 已经在跑 ⇒ **只切前台**, 不再 launch 一次: 有些 App 被再 launch 会开新窗口
            // (用户眼里就是"它怎么又开了一个")。
            _ = NSRunningApplication(processIdentifier: t.pid)?.activate(options: [.activateAllWindows])
            return .success(text: "「\(t.name)」本来就在运行 ⇒ 已经切到前台(没有新开窗口)。"
                            + "接下来用 computer_read 读它。")

        case .launch(let t):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundle) else {
                return .failure("找不到「\(t.name)」的 App 包(\(t.bundle)) ⇒ 它可能已经被卸掉了。")
            }
            guard NSWorkspace.shared.open(url) else {
                return .failure("系统拒绝了这次启动「\(t.name)」的请求 ⇒ 什么都没打开。")
            }
            // ⚠️ **等它真的起来再回话**: `open` 只保证"启动请求发出去了", 而模型拿到 ok 之后
            //    下一个动作必然是 `computer_read` —— 差半秒就是"读不到窗口", 它只会把这次
            //    启动当成没发生, 于是重试。上限 4s: 再长就是在 socket 上干等(单连接顺序处理)。
            for _ in 0..<20 {
                if let live = runningApp(t.bundle), live.isFinishedLaunching {
                    return .success(text: "打开了「\(t.name)」。接下来用 computer_read 读它"
                                    + "(给 \(t.bundle) 或「\(t.name)」都行)。")
                }
                usleep(200_000)
            }
            // 慢 ≠ 失败: 大 App 起来要更久。把"请系统启动过"和"我还没看到它"分开说清楚。
            return .success(text: "已经请系统启动「\(t.name)」, 但 4 秒内还没看到它起来。"
                            + "过一会儿再 computer_read; 要是仍然不行, 让用户手动打开一次。")
        }
    }

    // MARK: - 指认 → 定位

    /// 作用域内**当前正在跑**的 App。
    ///
    /// ⚠️ 为什么先按作用域过滤再挑: 选不中的那一半**根本不该出现在候选里** ——
    ///    否则 `pick` 命中一个不在作用域的 App, 后面还要再挡一次(两处判就是两处会漂),
    ///    而且失败回执里会泄出"本机正跑着哪些 App"这类与本次任务无关的信息。
    ///
    /// ⚠️ 取"谁在跑"那一行不许换回 `NSWorkspace.shared.runningApplications` —— 见 `runningApp`。
    func candidatesInScope() -> [ComputerTarget.Candidate] {
        ComputerTarget.candidates(inScope: allowedBundles, running: runningApps())
    }

    /// 某个 bundle **此刻在跑的那个进程**(没有就 nil)。**每次现问系统。**
    ///
    /// ⚠️⚠️ **不要用 `NSWorkspace.shared.runningApplications`** —— 2026-10-29 实测(macOS 14.8.1):
    ///    在不抽 run loop 的进程里, 它返回的是**首次查询那一刻的快照**, 之后再起的 App
    ///    永远不出现。helper 正是"阻塞在 `accept()` 上一个 run loop 都不跑"的裸进程 ⇒
    ///    boss 那次 `computer_open` 一路回"4 秒内还没看到它起来"、`computer_read` 回
    ///    "它们现在都没在运行", 而 `pgrep` 明明看得见 —— **回执在撒谎, 零红灯**。
    ///    同一进程里抽 60ms run loop 就恢复正常(枚举 0→1), 说明它靠通知刷新;
    ///    而 `runningApplications(withBundleIdentifier:)` 是**每次真问系统**的同步查询
    ///    (同一实测: 起 App 后立刻 0→1), 所以这里按 bundle 逐个问, 不赌"什么时候抽过 loop"。
    func runningApp(_ bundle: String) -> NSRunningApplication? {
        // `processIdentifier` 在 App 已退出但还在列表里时是 -1 ⇒ 那个 pid 读不到任何东西。
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .first { $0.processIdentifier > 0 }
    }

    /// 名单里**在跑**的那一份(判据只认 bundle/name/pid 三样 ⇒ 交给 `mangox/Models` 的纯函数)。
    func runningApps() -> [ComputerTarget.Running] {
        allowedBundles.sorted().compactMap { bundle in
            guard let app = runningApp(bundle) else { return nil }
            return ComputerTarget.Running(bundle: bundle,
                                          name: app.localizedName
                                              ?? displayName(bundle: bundle, running: []),
                                          pid: app.processIdentifier)
        }
    }

    /// 当前前台的 App。**也不用 `NSWorkspace.frontmostApplication`** —— 同一个冻结坑
    /// (实测: 计算器的 `isActive` 已经是 true, 它还在报 Chrome, 而且此后一直报 Chrome)。
    ///
    /// ① 名单里 `isActive` 的那个最准 —— 那是系统标的"活动 App"(实测不冻结);
    /// ② 名单里一个都不 active ⇒ 前台是个**没开放**的 App, 这时候要的只是"它是谁",
    ///    从 WindowServer 最前面的普通窗口(layer 0)反查 owner 就够了(不需要屏幕录制权限)。
    private func frontmost() -> (bundle: String, name: String)? {
        for c in candidatesInScope() {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: c.bundle)
                .first(where: { $0.processIdentifier == c.pid && $0.isActive }) {
                return (c.bundle, app.localizedName ?? c.name)
            }
        }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // WindowServer 的列表是**前到后**排的 ⇒ 第一个 layer 0 的窗口就是最前面那个 App 的。
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            return (app.bundleIdentifier ?? "", app.localizedName ?? "那个 App")
        }
        return nil
    }

    /// 名单里**装了**的 App(**不管在不在跑**) —— `open` 的候选表, 也用来回答
    /// "他是不是勾了它、只是没打开"。
    ///
    /// ⚠️ 为什么不能复用 `candidatesInScope()`: 那个只列**正在跑**的, 而这两件事要解决的
    ///    正是"它没在跑"。名单是用户手勾的几个, 逐个问 LaunchServices 不贵。
    /// ⚠️ 勾了但已经卸掉的 bundle **不列进来**(列了也打不开, 只会让模型多试一次)。
    func installedInScope() -> [ComputerTarget.Candidate] {
        let running = candidatesInScope()
        return allowedBundles.sorted().compactMap { bundle in
            if let live = running.first(where: { $0.bundle == bundle }) { return live }
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else {
                return nil
            }
            return ComputerTarget.Candidate(bundle: bundle,
                                            name: displayName(bundle: bundle, running: running),
                                            pid: 0)
        }
    }

    /// 空 query = **当前前台**; 其余交给 `ComputerTarget.pick`(纯函数, 冒烟能断言)。
    private func resolve(query: String,
                         in candidates: [ComputerTarget.Candidate]) -> ComputerTarget.Candidate? {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let front = frontmost() else { return nil }
            return candidates.first { $0.bundle == front.bundle }
        }
        return ComputerTarget.pick(query: query, in: candidates)
    }

    /// 命中"没有可读控件层"时的说明。
    ///
    /// ⚠️ **两种可能都要写**("自绘不暴露" / "确实是空的"): 判据分不出它们, 而且分错了
    ///    的代价不对称 —— 说成"空的"会让模型以为读成功了, 然后基于"这个窗口只有三个按钮"
    ///    去推断用户想干什么。那是本轮最坏的一种错。
    private func lackOfControlsNote(app: String, nodes: Int) -> String {
        "⚠️「\(app)」的这个窗口里读不到可读的控件: 只拿到 \(nodes) 个节点, 没有任何文本/输入/列表。"
        + "两种可能: ① 这个 App 是自绘的、不向系统暴露界面(微信就是这样), 那样的 App 只能截图看;"
        + " ② 窗口确实是空的(例如刚新建的白页)。先换一个 App 试, 或者问用户这个界面上本来应该有什么。"
    }

    /// 作用域里**一个能用的 App 都没有**时的回执 —— 两种成因**必须分开说**。
    ///
    /// ⚠️ 2026-10-29 boss 拿着截图问「我都配置这个了, 权限已经足够了」: 他名单勾好了, 只是
    ///    那个 App 当时没在运行, 而回执说的是"没有开放任何 App。(在设置里勾选)" ——
    ///    他勾了。**同一条回执在"事实"和"下一步"两处都错**, 比不说更糟: 人照着它去设置页,
    ///    看到勾选明明是好的, 于是只剩下"这个功能坏了"。
    private func emptyScopeNote(verb: String) -> String {
        guard !allowedBundles.isEmpty else {
            return "没有开放任何 App ⇒ 我不\(verb)界面。(在 设置 › 集成 › 电脑操作 里勾选; 改完下一次对话生效)"
        }
        let names = allowedBundles.sorted().map { label(bundle: $0, running: []) }
            .joined(separator: " / ")
        return "你开放了「\(names)」, 但它们现在都没在运行 ⇒ 没有可\(verb)的窗口。"
            + "先把 App 打开(或者让我用 computer_open 打开), 再\(verb)。"
    }

    /// 选不中时的人话。⚠️ 三种原因要分开说, 它们的下一步完全不同:
    /// ① 名单空(没勾) / ② **勾了但它没在跑**(打开它就行) / ③ 压根不在名单里(只能换目标或问人)。
    private func refusal(query: String,
                         available: [ComputerTarget.Candidate],
                         verb: String) -> String {
        let names = available.map { label(bundle: $0.bundle, running: available) }
            .joined(separator: " / ")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty, let front = frontmost() {
            return "当前前台是「\(front.name)」, 它不在开放名单里 ⇒ 我不\(verb)它。能\(verb)的: \(names)"
        }
        // ⚠️ 这一段是给 boss 那次失败补的: "勾了但没在跑"是最常见的一种, 而且它有**唯一一个**
        //    明确的下一步(打开它)。笼统说成"没在跑, 或者不在名单里", 两个都不是 —— 模型只能
        //    换目标或者去问人, 而它本来只差一次启动。
        if let installed = ComputerTarget.pick(query: q, in: installedInScope()) {
            let who = displayName(bundle: installed.bundle, running: available)
            return "「\(who)」在你开放的名单里, 但它现在没在运行 ⇒ 没有可\(verb)的窗口。"
                + "先把它打开(或者让我用 computer_open 打开它), 再\(verb)。现在有窗口的: \(names)"
        }
        return "「\(q)」不在开放名单里 ⇒ 我不\(verb)它。现在有窗口的: \(names)"
    }

    /// 回执里怎么称呼一个 App: **名字 + bundle id**。
    ///
    /// ⚠️ 为什么非要带 bundle id: 没在跑的 App **拿不到本地化名**(实测 —— helper 是裸可执行
    ///    文件, `Bundle.preferredLocalizations` 恒 `["en"]` ⇒ `CFBundleDisplayName` /
    ///    `.localizedNameKey` / 已废弃的 `LSCopyDisplayNameForURL` 三条路全给英文名), 于是
    ///    中文机器上「计算器」在回执里写作 `Calculator`。带上 bundle id 就有了一个**语言无关**
    ///    的说法: 模型照着重试一定选得中(见 `ComputerTarget.pick` 的 bundle 全等那一档)。
    private func label(bundle: String, running: [ComputerTarget.Candidate]) -> String {
        "\(displayName(bundle: bundle, running: running))(\(bundle))"
    }

    /// 显示名: 在跑就用进程报的那个(系统 App 在中文机器上叫「计算器」), 没在跑退回包里那个。
    private func displayName(bundle: String, running: [ComputerTarget.Candidate]) -> String {
        if let live = running.first(where: { $0.bundle == bundle }) { return live.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !name.isEmpty {
            return name
        }
        return ComputerTarget.lastSegment(of: bundle)
    }

    /// 作用域判据的**这一层**: 只认 bundle id 名单。
    ///
    /// ⚠️ 名单为空 ⇒ 拒。理由同 `PeerCheck`: 空不是"全都行", 空是"没下发"。
    /// 真正的"动作面 / 恒拒判据"在 `mangox/Models` 上的纯函数里(能被冒烟断言)。
    func isInScope(pid: pid_t) -> Bool {
        guard !allowedBundles.isEmpty else { return false }
        return candidatesInScope().contains { $0.pid == pid }
    }
}
