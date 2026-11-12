//
//  CaseComputerHost.swift
//  电脑操作助手的**生命周期**(2026-11-11)。
//
//  为什么这条必须有: 助手是**整个 App 一份**(全局唯一)、而 transport 是**每个会话一份**。
//  两边一旦各拿各的, 后果不是报错, 是三种都零红灯的症状:
//    ① 每开一个会话多一个 helper —— 每个都握着「辅助功能 + 屏幕录制」, 而且从来没人停它们
//       (实测两个会话 = 两个 helper, 其中一个已跑 1 小时 33 分还活着);
//    ② 会话之间**互相看不见**: 新会话的 `start` 起一个新 helper, 而它要 500ms 才起监听,
//       这一轮第一次读就可能撞在"没有这个 socket"上 —— 表现是"换一个会话就读不到了";
//    ③ 每 spawn 一次在 `~/.mangox/` 留一个死 socket(helper 的 SIGTERM 只 exit(0), 不 unlink)。
//
//  ⚠️ 这里的断言全部走**真实现**(真 `ComputerHost` + 夹具目录里的假 helper), 不是只测一个
//    纯函数: "每会话一份"这个错法在纯函数上完全看不出来, 它长在字段怎么被持有上。
//

import Foundation

extension SmokeMain {

    /// 一个"能起监听"的假 helper —— 复刻真 helper 的两件事: 收到路径就 `bind` 一条 socket、
    /// 被 SIGTERM 就退出**且不 unlink**(真的就是这样, 这才验得出 App 侧有没有补那一步)。
    // ⚠️ 必须 `@MainActor`: 下面要读 `ComputerHost.helperExecutableName`, 而那个类整体是
    //    `@MainActor` —— 从 nonisolated 读会报 Swift 6 告警, 而 swiftc 告警在这里是硬门。
    @MainActor
    private static func fakeHelper(at dir: String) -> String {
        let path = dir + "/fake-compute"
        // ⚠️ 三步必须分开写: ① 先另存 python 脚本(它里面**没有** shell 引号地狱)
        //    ② shell 只做 `exec python3 <脚本> "$1"` ③ `$1`(socket 路径)经 argv 传进去。
        //    早先写成 `exec /usr/bin/env python3 -c "…"` 嵌在 Swift 多行字符串里, `\"` 会
        //    原样落盘 ⇒ python 收到 `\"` 直接语法错 ⇒ 假 helper **静默起不来**,
        //    而断言 `a != nil && a == b` 仍是绿色的(两边都 nil)。这正是 run.sh 里
        //    「shell-out 的判据必须喂坏输入自证会红」那条要防的东西。
        let py = dir + "/fake-compute.py"
        // ⚠️ python 侧**必须先建父目录**: `home` 是夹具目录, 而 socket 落在 `home/.mangox/`
        //    下 —— 不建就直接 bind 抛 ENOENT, 进程当场退出, 而 App 侧只看到"等 500ms 没出现",
        //    照常返回路径 ⇒ 断言全变成 nil 的假绿(实测一次)。
        // ⚠️ 这段 python 缩进在**第一列**: Swift 多行字符串按结尾 `"""` 的缩进剥离,
        //    python 那侧缩进错一格就是 `IndentationError`。
        let body = """
        import os, signal, socket, sys
        p = sys.argv[1]
        os.makedirs(os.path.dirname(p), exist_ok=True)
        try:
            os.unlink(p)
        except OSError:
            pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(p)
        s.listen(1)
        # 标记从 socket 路径派生 —— 不给生产代码的 `start` 加测试专用参数。
        marker = p + ".term"
        def on_term(*a):
            # ⚠️ 先落标记再退出: 判据要能回答"App 到底有没有真的 terminate 它",
            #    而不是只看 socket 文件在不在(那只证明了 unlink)。
            if marker:
                open(marker, "w").close()
            os._exit(0)
        signal.signal(signal.SIGTERM, on_term)
        print("listening " + p, flush=True)
        while True:
            try:
                s.accept()
            except OSError:
                pass
        """
        let sh = """
        #!/bin/sh
        # 假 helper: $1 = socket 路径。绑一条 socket, 然后等死。
        exec /usr/bin/env python3 "$(dirname "$0")/fake-compute.py" "$1"
        """
        try? body.write(toFile: py, atomically: true, encoding: .utf8)
        try? sh.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: path)
        // ⚠️ 必须摆成 **bundle 的形状**: `start` 找的是
        //    `<bundlePath>/Contents/MacOS/mangox-compute`(见 `ComputerHost.helperPath`)。
        //    只把脚本放在 `dir/` 下, `start` 一律返回 nil, 断言就成了 nil == nil 的假绿。
        let bundle = dir + "/Fake.app"
        let macos = bundle + "/Contents/MacOS"
        try? FileManager.default.createDirectory(atPath: macos, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: macos + "/mangox-compute")
        // 拷一份(不软链): `isExecutableFile` 走的是 stat, 软链也行, 但拷过去更像真装好的样子。
        try? FileManager.default.copyItem(atPath: path,
                                          toPath: macos + "/" + ComputerHost.helperExecutableName)
        // python 脚本要跟过去 —— shell 里那句 `dirname "$0"` 找的是**同一个目录**。
        try? FileManager.default.copyItem(atPath: py, toPath: macos + "/fake-compute.py")
        return bundle
    }

    @MainActor
    static func caseComputerHost() async {
        print("== T-HOST 电脑操作助手的生命周期 ==")

        // 判据的骨架: **一个会话一份**, 而且会话收了就必须真收。
        //    ① 两个实例拿到**不同**的 socket —— 这是"互不干扰"的定义, 也是 boss 2026-11-12
        //       拍板的结果(共享一份时 `Scope.takeover` 取自每会话的 approvalMode ⇒ 互相踢)。
        //    ② 一个收掉, 另一个还在跑 —— 少这条, "共享一份"也能全绿, 而那正是被否掉的方案。
        //    ③ 收的时候 socket 文件一起清 —— helper 的 SIGTERM 只 exit(0), 不 unlink。
        let dir = fixtureDir("computer-host")
        // ⚠️ **socket 路径有 104 字节硬上限**(`AF_UNIX path too long`): 夹具目录在
        //    `.../T/mx-smoke-<36 位 UUID>/computer-host-<8 位>/` 里, 再拼 `.mangox/compute-<36 位>.sock`
        //    就超了, 假 helper 启动即死, 而 `start` 照常返回路径(超时也返回)—— 看着像"慢"。
        //    实测撞过一次。⇒ home 换成短路径。
        let short = "/tmp/mxsh-" + String(UUID().uuidString.prefix(8))
        try? FileManager.default.createDirectory(atPath: short, withIntermediateDirectories: true)
        let bundle = fakeHelper(at: dir)
        let bundles = ["com.tencent.xinWeChat"]

        // ⓪ 起不来(路径是假的) ⇒ nil, 且 `stop()` 是安全的空操作。
        let ghost = ComputerHost()
        let none = ghost.start(home: short, allowedBundles: bundles,
                               bundlePath: dir + "/NoSuch.app")
        check(none == nil && ghost.socketPath == nil,
              "T-HOST helper 不存在 ⇒ start 返回 nil (起不来就要如实说, 不许给一条连不上的路径)")
        ghost.stop()
        check(ghost.socketPath == nil, "T-HOST 没起过 / 起不来时 stop 是安全的空操作")

        // ① 两个"会话"各起一份, 两条 socket **必须不同**。
        let a = ComputerHost()
        let b = ComputerHost()
        let sa = a.start(home: short, allowedBundles: bundles, bundlePath: bundle)
        let sb = b.start(home: short, allowedBundles: bundles, bundlePath: bundle)
        // 假 helper 收到 SIGTERM 会在 `<socket>.term` 落一个标记(见 `fakeHelper`)。
        let termMark = (sa ?? "") + ".term"
        let termMarkB = (sb ?? "") + ".term"
        check(sa != nil && sb != nil && sa != sb,
              "T-HOST 两个会话各拿一条 socket (共享一份 = Scope.takeover 互相踢; 实际 \(sa ?? "nil") / \(sb ?? "nil"))")
        // 假 helper 真起来了没 —— 上一条在两边都 nil 时也"不等"(nil != nil 为 false, 但还是单独立一条)。
        check([sa, sb].compactMap { $0 }.allSatisfy { FileManager.default.fileExists(atPath: $0) },
              "T-HOST 两份假 helper 都真起了监听 (否则上面几条是 nil 的假绿)")

        // ② 同一份连借两次拿到同一条 socket —— 会话内复用, 不许反复重启。
        let again = a.start(home: short, allowedBundles: bundles, bundlePath: bundle)
        check(again == sa && sa != nil, "T-HOST 同一会话内连借两次拿到同一条 socket")

        // ③ **核心**: 收掉 a, b 必须照旧活着。收早/收错对象 = 另一个会话当场断。
        a.stop()
        let bAlive = FileManager.default.fileExists(atPath: sb ?? "/nonexistent")
        let bStill = b.start(home: short, allowedBundles: bundles, bundlePath: bundle)
        check(bAlive && bStill == sb && b.socketPath == sb,
              "T-HOST 收掉一个会话不许影响另一个 (互不干扰是这次拍板的全部理由)")
        check(sa.map { !FileManager.default.fileExists(atPath: $0) } ?? false,
              "T-HOST 收掉的那个 socket 文件也清掉 (留着 = ~/.mangox 里越攒越多的死 socket)")
        // ⚠️ 只 unlink 不 terminate 也能让上面那条变绿 —— 而 helper 还活着, 继续握着
        //    「辅助功能 + 屏幕录制」直到它自己的父进程探活(2 秒)才退。两步都要验。
        //    判据 = 假 helper 收到 SIGTERM 时落的标记(见 `fakeHelper`)。
        // ⚠️ 必须等: SIGTERM 送达 → python 处理 → 落标记, 是几毫秒的异步过程, 同步立刻查必红。
        let terminated = await waitUntil(
            { FileManager.default.fileExists(atPath: termMark) }, timeout: 3)
        check(terminated,
              "T-HOST 收的时候真的 terminate 了进程, 不只是删了文件 (否则它握着 TCC 多活 2 秒)")
        check(!FileManager.default.fileExists(atPath: termMarkB),
              "T-HOST 只收自己那一个 (误杀别人的 helper = 另一个会话当场断)")

        // ④ 空名单 = 没开放 ⇒ 不起进程(也没 socket)。
        let empty = ComputerHost().start(home: short, allowedBundles: [], bundlePath: bundle)
        check(empty == nil, "T-HOST 名单为空不起进程 (空不是「全都行」, 白占一条辅助功能授权)")

        b.stop()
        try? FileManager.default.removeItem(atPath: short)
    }
}
