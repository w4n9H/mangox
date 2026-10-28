//
//  PeerCheck.swift
//  mangox-compute (P18 批 1b · §04 前置门 0): 这条 socket **只认自己人**。
//
//  为什么它排在"审批闸门倒置"前面(§03 改动一末段那张卡): 闸门挡的是模型的误用,
//  这条挡的是**别人替你的机器动手**。前者是"做错事", 后者是"被别人做"。
//
//  三条硬要求:
//   ① socket 放在 `0700` 目录、文件 `0600` —— 同用户以外的进程**连路径都摸不到**;
//   ② 接受连接时用 `LOCAL_PEERCRED` 验 uid、**不依赖对端自报**;
//   ③ pid 必须是**本轮 pi 或其子孙** —— 只验"是不是同一个 uid"不够: 同 uid 下任何进程
//      (浏览器里的一段脚本、一个 npm postinstall)都能连上来, 而那条路径正是 computer use
//      唯一可被外部利用的缝。
//
//  ⚠️ pid 校验的判据是**进程树**, 不是"记一个 pid 然后比相等": 记 pid 会撞上 pid 复用,
//  也会漏掉 pi 自己 spawn 出去的子工具进程(它们才是真正发起调用的一方)。
//

import Darwin
import Foundation

enum PeerCheck {

    /// 环境变量里交给我们的"合法祖先" —— App 侧 spawn 时写下本轮 pi 的 pid。
    ///
    /// ⚠️ 它是**契约 token**(同 `MANGOX_BOCHA_KEY`): 改名字要两边一起改, 而且
    /// **父环境残留必须显式删**(同 `webSearchEnvironment` 那套) —— 否则"没开"与
    /// "其实开了"会同时为真, 且不亮任何灯。
    static let peerPidEnvKey = "MANGOX_COMPUTE_PEER_PID"

    /// 完整判据: 同 uid **且** pid 落在允许的那棵子树里。
    ///
    /// `allowedAncestorPid` 为空 ⇒ **拒绝**, 不是放行: 没有基准的"允许"不是允许,
    /// 那只是"忘了传"。默认值取 fail-safe 方向(同 `BashRiskEvaluator` 那句
    /// "失败模式是烦, 不是出事")。
    static func accept(socket: Int32, allowedAncestorPid: pid_t?) -> Bool {
        guard let ancestor = allowedAncestorPid, ancestor > 0 else { return false }
        guard let uid = peerUid(of: socket), uid == getuid() else { return false }
        guard let pid = peerPid(of: socket) else { return false }
        return isSelfOrDescendant(pid: pid, of: ancestor)
    }

    /// `getsockopt(LOCAL_PEERCRED)` —— 内核在 accept 后给出的对端 uid。
    /// **不看对端说它是谁**, 这是整条判据的支点。
    static func peerUid(of socket: Int32) -> uid_t? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let r = getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len)
        guard r == 0, len >= MemoryLayout<xucred>.size else { return nil }
        return cred.cr_uid
    }

    /// `LOCAL_PEERPID` —— macOS 上拿对端 pid 的正规路子(`xucred` 在 macOS 上没有 `cr_pid`)。
    static func peerPid(of socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let r = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
        guard r == 0, len == MemoryLayout<pid_t>.size, pid > 0 else { return nil }
        return pid
    }

    /// 沿 ppid 往上走, 直到撞见 `ancestor` 或走到 init(1)。
    ///
    /// 上限 64 层: 正常进程树到不了那么深, 设上限是为了**不信任**内核给出的这条链 ——
    /// 环、pid 复用、取不到的中间层都会让它不可信 ⇒ 走到头就是拒。
    static func isSelfOrDescendant(pid: pid_t, of ancestor: pid_t) -> Bool {
        var cur = pid
        for _ in 0..<64 {
            if cur == ancestor { return true }
            guard let ppid = parent(of: cur), ppid > 0, ppid != cur else { return false }
            cur = ppid
        }
        return false
    }

    /// `sysctl(KERN_PROC_PID)` 取 ppid。取不到返回 nil —— 同样是**不放行**。
    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let r = mib.withUnsafeMutableBufferPointer { p -> Int32 in
            sysctl(p.baseAddress, 4, &info, &size, nil, 0)
        }
        guard r == 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
