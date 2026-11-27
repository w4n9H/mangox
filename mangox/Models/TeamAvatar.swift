//
//  TeamAvatar.swift
//  团队头像 —— 内置 10 个 emoji。存的是 emoji 本身，不是序号。
//
//  为什么不是"名字首字"（2026-11-27 boss 反馈）: 助理全叫「助理 X」⇒ 首字恒是"助"，
//  三张卡长得一模一样，头像等于没有。
//

import Foundation

enum TeamAvatar {
    /// 内置的 10 个 —— **唯一定义处**。编辑页的选择器与团队页的圆都读这一份。
    /// ⚠️ 顺序即自动分配的起点，且 `all[i]` 的下标语义只活在本文件里（库里存的是 emoji 字符串）。
    static let all: [String] = ["🐱", "🦊", "🐼", "🦉", "🐝", "🐬", "🦁", "🐸", "🐙", "🐧"]

    /// 库里的值还认不认。脏值 / 以后删掉的图案 ⇒ 当作没设过（回落自动），不报错。
    static func isBuiltIn(_ s: String) -> Bool { all.contains(s) }

    /// 从 id 派生的**稳定**起点。
    ///
    /// ⚠️ 不许用 `hashValue`：Swift 的 Hashable 每个进程带随机种子，重启就换一张脸。
    /// ⚠️ 不许用"在这个组的数组里排第几"：那正是 2026-10-08 那条判据（键不许是容器里的位置）——
    ///    删掉一个同事，后面所有人的头像跟着换，而"位置固定"是这个页面敢让人靠位置认人的前提。
    ///    这里只读**任务自己的 id**，与别人增删无关。
    static func seed(for id: UUID) -> Int {
        let b = id.uuid
        return (Int(b.0) << 8 | Int(b.1)) % all.count
    }

    /// 一组人的头像表 —— 输入**同一组**任务，输出 id → emoji。
    ///
    /// 三条规则（都有冒烟）:
    ///   ① **显式优先且先占位** —— 自动的让路，不会把用户亲手选的抢走；
    ///   ② 自动的从 `seed(for:)` 起步，撞了就顺延 —— 所以**同组内不重复**（≤10 人时；
    ///      超了就绕回来重复，不崩、不留空）；
    ///   ③ 先后由 `createdAt` 定（同刻按 name），**不吃数组顺序** —— 团队页那份 `order(_:)`
    ///      是按状态排的，拿它分配的话"谁在跑"会改变"谁是猫"。
    static func assign(_ people: [ScheduledTask]) -> [UUID: String] {
        var used = Set<Int>()
        var out: [UUID: String] = [:]
        for t in people {
            guard let a = t.avatar, let i = all.firstIndex(of: a) else { continue }
            if out[t.id] == nil {
                out[t.id] = a
                used.insert(i)
            }
        }
        for t in people.sorted(by: { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }) {
            guard out[t.id] == nil else { continue }
            var i = seed(for: t.id)
            var tries = 0
            while used.contains(i) && tries < all.count {
                i = (i + 1) % all.count
                tries += 1
            }
            used.insert(i)
            out[t.id] = all[i]
        }
        return out
    }

    /// 单个任务的值 —— 不在任何组里时用（检查器、单卡预览）。
    /// 与 `assign` 的差别只在"没有别人要避让"，所以它读同一个 `seed`。
    static func of(_ t: ScheduledTask) -> String {
        if let a = t.avatar, isBuiltIn(a) { return a }
        return all[seed(for: t.id)]
    }
}
