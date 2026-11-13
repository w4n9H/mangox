//
//  CaseComputerHost.swift
//  电脑操作助手的**生命周期**(2026-11-11)。
//
//  为什么这条必须有: 助手是**每个会话一份**(`ComputerHost` 每个会话持有一个实例), 两边一旦
//  各拿各的, 后果不是报错, 是三种都零红灯的症状:
//    ① 每开一个会话多一个 helper —— 每个都握着「辅助功能 + 屏幕录制」, 而且从来没人停它们
//       (实测两个会话 = 两个 helper, 其中一个已跑 1 小时 33 分还活着);
//    ② 会话之间**互相看不见**: 新会话的 `start` 起一个新 helper, 而它要 500ms 才起监听,
//       这一轮第一次读就可能撞在"没有这个 socket"上 —— 表现是"换一个会话就读不到了";
//    ③ 每 spawn 一次在 `~/.mangox/` 留一个死 socket(helper 的 SIGTERM 只 exit(0), 不 unlink)。
//
//  ⚠️ **这里不起任何子进程、也不依赖宿主装了什么**(2026-11-13 CI 红之后定的)。
//    走过的两条路, 都别再走:
//      ① shell + `env python3` 当假 helper —— 要 PATH 里有 python3, 而 **GitHub runner 的
//         PATH 里没有** ⇒ 127 退出, 假 helper 静默起不来; 而"它真起了没"那条判据当时恰好
//         写成 `allSatisfy`(对空数组恒真) ⇒ **假绿**, 门禁红在别处, 查了半天。
//      ② 独立编一个小二进制当假 helper —— 门禁多一条构建路径、多一个 `@main`, 还要处理
//         代码签名(dyld 先接手, 里面的 `exit` 收掉的是 dyld —— 现象是"起了又立刻没了")。
//    ⇒ 判据改成**全在进程内**: 自己 `socket()`/`bind()`/`listen()` 造现场, 直接量
//      `socketIsListening` / `sweepDeadSockets` / `helperPath` / `socketPath`。
//      代价说清楚: 「`start` 真 spawn 出进程、`stop` 真 terminate」这两步**不再有判据**。
//      能兜住的只有分支 —— `start` 不 spawn 的那两支(空名单 / 没有 helper)在这里验;
//      `stop` 的 terminate + unlink 是顺序代码, 没有分支可判。
//

import Foundation

extension SmokeMain {

    @MainActor
    static func caseComputerHost() async {
        print("== T-HOST 电脑操作助手的生命周期 ==")

        let dir = fixtureDir("computer-host")
        // ⚠️ **socket 路径有 104 字节硬上限**(`AF_UNIX path too long`): 夹具目录在
        //    `.../T/mx-smoke-<36 位 UUID>/computer-host-<8 位>/` 里, 再拼 `.mangox/compute-<36 位>.sock`
        //    就超了 —— 绑不上, 而现象是"起不来"(踩过一次)。⇒ 现场改到短路径。
        let short = "/tmp/mxsh-" + String(UUID().uuidString.prefix(8))
        let sockDir = short + "/.mangox"
        try? FileManager.default.createDirectory(atPath: sockDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: short) }

        // ① helper 在包里的位置。拷错(`Contents/MacOS` 写成 `MacOS`)时 `Process.run()` 抛
        //    "No such file", 而用户看到的现象只是"读不到界面" —— 中间**没有任何红灯**。
        let exe = ComputerHost.helperPath(bundlePath: "/Applications/MangoX.app")
        check(exe == "/Applications/MangoX.app/Contents/MacOS/" + ComputerHost.helperExecutableName,
              "T-HOST helper 位置 = <bundle>/Contents/MacOS/<name> (实际 \(exe))")

        // ② 每个会话一条 socket。名字里带 id 而不是固定名: 两个 MangoX 实例(正式版 + 自编的
        //    debug 版)同时开着时, 固定名会让后起的那个 `bind` 失败, 而先起的那个还握着权限
        //    ⇒ 模型静默读到**老的那份**。
        let p1 = ComputerHost.socketPath(home: short, id: "AAA")
        let p2 = ComputerHost.socketPath(home: short, id: "BBB")
        check(p1 != p2 && p1 == short + "/.mangox/compute-AAA.sock",
              "T-HOST 每个会话一条独立 socket (同 id 才复用; 固定名 ⇒ 后起的实例绑不上, 静默读老的那份)")

        // ③ 名单为空 = 没开放 ⇒ 不起进程(也不占 TCC)。走真 `start`, 但它在 `isExecutableFile`
        //    之前就返回 —— 不会 spawn 任何东西。
        let none = ComputerHost().start(home: short, allowedBundles: [], bundlePath: dir + "/NoSuch.app")
        check(none == nil, "T-HOST 名单为空不起进程 (空不是「全都行」, 白占一条辅助功能授权)")

        // ④ helper 不在包里 ⇒ nil。给一条连不上的路径, 换来的是整轮每一次读都 `ECONNREFUSED`,
        //    而模型会把它读成"界面上什么都没有"。这条也是**不 spawn** 的那一支。
        let ghost = ComputerHost()
        check(ghost.start(home: short, allowedBundles: ["com.tencent.xinWeChat"],
                          bundlePath: dir + "/NoSuch.app") == nil,
              "T-HOST helper 不存在 ⇒ start 返回 nil (起不来就要如实说, 不许给一条连不上的路径)")
        ghost.stop()
        check(ghost.socketPath == nil, "T-HOST 没起过 / 起不来时 stop 是安全的空操作")

        // ⑤ `socketIsListening` 是"连一次", 不是"看文件在不在" —— 2026-11-13 那条
        //    `ECONNREFUSED` 的全部内容: helper 绑过 socket、然后没了(它的 SIGTERM 处理器当时
        //    不 unlink), 而 `start` 只等 `fileExists` ⇒ 把一条**没人听的路径**发下去。
        //    四档现场, 全在进程内造:
        check(!ComputerHost.socketIsListening(sockDir + "/compute-missing.sock"),
              "T-HOST 文件根本不在 ⇒ 没在听")

        let plain = sockDir + "/compute-plain.sock"
        try? "not a socket".write(toFile: plain, atomically: true, encoding: .utf8)
        check(!ComputerHost.socketIsListening(plain),
              "T-HOST 同名的普通文件不算「在听」(只看 `fileExists` 会把垃圾文件判成活 socket)")

        // 绑上又关掉: 文件留在盘上、没人 accept —— 这正是 helper 被 SIGTERM 之后的样子。
        let dead = sockDir + "/compute-dead.sock"
        bindThenDrop(path: dead)
        check(FileManager.default.fileExists(atPath: dead) && !ComputerHost.socketIsListening(dead),
              "T-HOST 死 socket(文件在、人不在)必须判成「没在听」(判成在听 ⇒ 整轮每次读都 ECONNREFUSED)")

        // 真在听: 绑 + listen(这里不 accept, 判据只关心"connect 会不会被内核收进队列")。
        let live = sockDir + "/compute-live.sock"
        let fd = bringUpListener(path: live)
        defer { if fd >= 0 { close(fd) } }
        check(fd >= 0 && ComputerHost.socketIsListening(live),
              "T-HOST 真在听的 socket 判成「在听」(判不出来的话, 下面「清扫」那条红是假红)")

        // ⑥ 残留清扫: 只扫**没人听**的 `compute-*.sock`。
        //    判据必须四方同时成立 —— 只验"死的那条没了"时, 一个"把目录清空"的实现也能全绿,
        //    而那会**当场踢掉另一个 MangoX 实例**的助手。
        let bystander = sockDir + "/keep-me.txt"
        try? "x".write(toFile: bystander, atomically: true, encoding: .utf8)
        // 名字不匹配的 socket 也不许碰: 别的程序可能在同一目录放自己的 socket。
        let foreign = sockDir + "/other-thing.sock"
        let foreignFd = bringUpListener(path: foreign)
        defer { if foreignFd >= 0 { close(foreignFd) } }

        ComputerHost.sweepDeadSockets(home: short)

        let deadGone = !FileManager.default.fileExists(atPath: dead)
        let liveKept = ComputerHost.socketIsListening(live)
        let trashKept = FileManager.default.fileExists(atPath: bystander)
        let foreignKept = ComputerHost.socketIsListening(foreign)
        check(deadGone && liveKept && trashKept && foreignKept,
              "T-HOST 清扫只删「没人听的 compute-*.sock」 (死:\(deadGone) 活:\(liveKept) 杂:\(trashKept) 别人的:\(foreignKept))")
    }

    // MARK: - 在进程内造 socket 现场 (不起子进程)

    /// 绑一条 unix socket 然后**只关 fd 不 unlink** —— 文件留在盘上, 但没人 accept。
    /// 这就是"helper 绑过又没了"的现场(它的 SIGTERM 处理器不删文件)。
    private static func bindThenDrop(path: String) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        fillSunPath(&addr, path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        close(fd)
    }

    /// 绑 + listen, 返回 fd(调用方负责 close)。**故意不 accept**。
    private static func bringUpListener(path: String) -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        fillSunPath(&addr, path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard rc == 0, listen(fd, 8) == 0 else { close(fd); return -1 }
        return fd
    }

    private static func fillSunPath(_ addr: inout sockaddr_un, _ path: String) {
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8)
            // 留一格给结尾的 NUL —— `sun_path` 是 C 串, 写满就没有终止符了。
            buf.copyBytes(from: bytes.prefix(buf.count - 1))
        }
    }
}
