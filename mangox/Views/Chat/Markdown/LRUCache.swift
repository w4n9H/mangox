//
//  LRUCache.swift
//  定容量的**真 LRU**（命中把键提到最新）+ 线程安全。
//

import Foundation

/// 一个按"最近最少使用"逐出的定容量缓存。
///
/// 为什么要有它：解析缓存 / 高亮缓存 / 逐行高亮缓存原先**各写一份**
/// 「`cache[key] = v; order.append(key); 满了就 order.removeFirst()`」——
/// 那**不是 LRU，是 FIFO**：命中的键**不会**被提到最新，于是"每拍都在用"的那一条照样
/// 按**插入顺序**被挤出去。流式期最典型：历史块每 chunk 重新求值（命中一次、顺序不动）、
/// 流式那一条每 chunk 新插入（挤掉队首一次）⇒ 历史块被反复逐出、反复重解析，
/// **缓存等于没起作用**，而它看起来「有缓存、有上限、有逐出」，一切正常。
///
/// ⚠️ 判据是"**用过的排在最后**"：`value(for:)` 命中后必须把键移到队尾。只 append 不重排
///    就是 FIFO —— 这条肉眼看不出来，只能靠 `T-CACHE` 那种"命中后再插入，看被逐出的是谁"来钉。
///
/// ⚠️ 锁在**类内部**，调用方不用再包 lock。原实现是「先 `lock()` 再在锁里跑 `parse`」——
///    解析流式那条消息的全程都攥着全局锁，别的视图连读缓存都要排队。
///
/// `@unchecked Sendable`：全部状态都在 `lock` 之内，是"内部加锁"这一类，编译器看不出来。
final class LRUCache<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var store: [String: Value] = [:]
    /// 队首 = 最久没被用过。容量 64 量级的 `firstIndex` 线性查找不值得再搭一层链表。
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// 命中返回并**把键提到最新**；未命中返回 nil。
    func value(for key: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = store[key] else { return nil }
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
        return hit
    }

    /// 写入（已存在则覆盖并提到最新），超出容量时逐出队首。
    func insert(_ value: Value, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        order.append(key)
        store[key] = value
        while order.count > capacity, let evict = order.first {
            order.removeFirst()
            store.removeValue(forKey: evict)
        }
    }

    /// 当前条数 —— 只给冒烟断言用（生产没人该关心）。
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }
}
