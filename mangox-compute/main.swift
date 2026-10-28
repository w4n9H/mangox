//
//  main.swift
//  mangox-compute —— P18 的 Swift 辅助进程(批 1b)。
//
//  它为什么必须存在: AX / CGEvent 是**原生 API**, node 里拿不到; 但更重要的理由是
//  第二条 —— **让判据落回能被断言的那一侧**(§05「一条会撞碎的不变量」)。扩展是哑的,
//  判断全在这里与 `mangox/Models` 上, 于是判据进得了冒烟。
//
//  启动参数只有一个: socket 路径。其余全走 env(路径、peer pid、作用域名单)
//  —— 因为它们是**这一轮才存在**的凭证, 写进配置就会让别的会话也连得上来。
//

import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard let socketPath = args.dropFirst().first, !socketPath.isEmpty else {
    FileHandle.standardError.write(
        Data("用法: mangox-compute <socket 路径>\n".utf8))
    exit(2)
}

// ⚠️ 不主动弹授权窗。辅助功能权限只能由用户去系统设置给 —— 一个后台辅助进程
// 自己弹窗索要, 既打扰人, 也拿不到(它不在前台)。这里只负责**如实上报状态**。
_ = AXIsProcessTrustedWithOptions(nil)

ComputerServer(path: socketPath).serve()
