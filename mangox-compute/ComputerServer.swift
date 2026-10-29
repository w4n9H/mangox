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
            return .pong(trusted: AXIsProcessTrusted())

        case .read(let app, let includeImage):
            guard AXIsProcessTrusted() else {
                return .failure("辅助功能权限还没授予 ⇒ 读不到界面。请在 系统设置 › 隐私与安全性 › 辅助功能 里勾上 MangoX。")
            }
            let candidates = candidatesInScope()
            guard !candidates.isEmpty else {
                return .failure("没有开放任何 App ⇒ 我不读界面。(在 设置 › 集成 › 电脑操作 里勾选; 改完下一次对话生效)")
            }
            let target = resolve(query: app, in: candidates)
            guard let t = target else {
                // ⚠️ 回执**必须带上"能读哪些"**: 模型不知道作用域, 只说"不在作用域内"会让它
                // 一个个 App 试过去(每次一轮往返, 而且它可能会猜 bundle id)。
                return .failure(refusal(query: app, available: candidates))
            }
            guard isInScope(pid: t.pid) else {
                return .failure("「\(t.name)」不在开放名单里 ⇒ 我不读它。")
            }
            guard var trees = AXAdapter.frontWindowTree(pid: t.pid) else {
                return .failure("读不到「\(t.name)」的窗口树(它可能没有窗口, 或者 AX 树太薄)。")
            }
            if includeImage {
                return .failure("图像面还没做(批 3 才接)。这次先按文本读。")
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
                return .success(text: withSeq(rereadNote + lackOfControlsNote(app: t.name, nodes: snap.rows.count)
                                              + "\n\n" + snap.rendered(), seq),
                                seq: seq)
            }
            return .success(text: withSeq(rereadNote + snap.rendered(), seq), seq: seq)

        case .act(let app, let opRaw, let index, let seq, let text):
            return handleAct(app: app, opRaw: opRaw, index: index, seq: seq, text: text)
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

    /// 一条动作。**判据一行都不在这里** —— 全在 `ComputerActGuard`(那边能造反例)。
    /// 这里只做四件事: 找 App → 找缓存 → 拿现场读数 → 执行并回报。
    private func handleAct(app: String, opRaw: String, index: Int, seq: Int, text: String) -> ComputerResponse {
        guard AXIsProcessTrusted() else {
            return .failure("辅助功能权限还没授予 ⇒ 动不了界面。请在 系统设置 › 隐私与安全性 › 辅助功能 里勾上 MangoX。")
        }
        guard let action = ComputerAction.parse(opRaw) else {
            return .failure("不认识的 op: 「\(opRaw)」。目前只有 press / setValue 两种。")
        }
        let candidates = candidatesInScope()
        guard !candidates.isEmpty else {
            return .failure("没有开放任何 App ⇒ 我不动界面。(在 设置 › 集成 › 电脑操作 里勾选; 改完下一次对话生效)")
        }
        guard let t = resolve(query: app, in: candidates) else {
            return .failure(refusal(query: app, available: candidates))
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

        let row = cached.snapshot.row(index)
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
        let request = ComputerActRequest(app: app, action: action, index: index, seq: seq, text: text)

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
                return .failure("#\(index) 在这份快照里查不到对应元素 ⇒ 没动。重新读一次。")
            }
            let err: AXError = (a == .press)
                ? AXAdapter.press(el)
                : AXAdapter.setValue(el, text)
            guard err == .success else {
                // ⚠️ **不退到坐标点击**: 按不下去就如实报。坐标兜底是批 3 与人类接管一起做的,
                //    在那之前"点错地方"比"没点"严重得多。
                return .failure("按不下去: AX 返回 \(err.rawValue)"
                                + "(\(a == .press ? "press" : "setValue")) ⇒ 界面没动。")
            }
            let name = liveTarget.map { $0.title.isEmpty ? AXSnapshot.cleanRoleName($0.role) : $0.title } ?? ""
            return finishAct(bundle: t.bundle, pid: t.pid, name: t.name,
                             previous: cached.snapshot,
                             headline: "\(a == .press ? "按了" : "写了") #\(index)「\(name)」。")
        }
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

    // MARK: - 指认 → 定位

    /// 作用域内**当前正在跑**的 App。
    ///
    /// ⚠️ 为什么先按作用域过滤再挑: 选不中的那一半**根本不该出现在候选里** ——
    ///    否则 `pick` 命中一个不在作用域的 App, 后面还要再挡一次(两处判就是两处会漂),
    ///    而且失败回执里会泄出"本机正跑着哪些 App"这类与本次任务无关的信息。
    func candidatesInScope() -> [ComputerTarget.Candidate] {
        guard !allowedBundles.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundle = app.bundleIdentifier, allowedBundles.contains(bundle) else { return nil }
            // `processIdentifier` 在 App 已退出但还在列表里时是 -1 ⇒ 那个 pid 读不到任何东西。
            guard app.processIdentifier > 0 else { return nil }
            return ComputerTarget.Candidate(bundle: bundle,
                                            name: app.localizedName ?? bundle,
                                            pid: app.processIdentifier)
        }
    }

    /// 空 query = **当前前台**; 其余交给 `ComputerTarget.pick`(纯函数, 冒烟能断言)。
    private func resolve(query: String,
                         in candidates: [ComputerTarget.Candidate]) -> ComputerTarget.Candidate? {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let bundle = front.bundleIdentifier else { return nil }
            return candidates.first { $0.bundle == bundle }
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

    /// 选不中时的人话。⚠️ 两种原因要分开说: "没在跑"与"不在作用域"对模型是两条不同的路
    /// （前者可以等, 后者只能换目标或问用户）。
    private func refusal(query: String, available: [ComputerTarget.Candidate]) -> String {
        let names = available.map(\.name).joined(separator: " / ")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty, let front = NSWorkspace.shared.frontmostApplication {
            let who = front.localizedName ?? front.bundleIdentifier ?? "那个 App"
            return "当前前台是「\(who)」, 它不在开放名单里 ⇒ 我不读它。能读的: \(names)"
        }
        return "读不到「\(q)」—— 它现在没在跑, 或者不在开放名单里。能读的: \(names)"
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
