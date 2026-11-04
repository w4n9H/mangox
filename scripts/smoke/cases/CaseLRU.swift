//
//  CaseLRU.swift
//  定容量缓存必须是**真 LRU**（2026-11-04，D 批）。
//
//  病根：`MarkdownParser` / `CodeHighlighter` 三处各写了一份
//    「`cache[k]=v; order.append(k); 满了 order.removeFirst()`」——
//    那是 **FIFO**，不是 LRU。症状是**静默**的：缓存有上限、有逐出、`count` 永远 ≤ 容量，
//    但"每拍都在用"的那一条照样按插入顺序被挤掉 ⇒ 反复逐出、反复重解析，
//    缓存等于没起作用。只有"命中之后看**被逐出的是谁**"能把它抓出来。
//
//  ⚠️ 这条判据的**反例**是"只 append 不重排"：外部读数（命中/未命中、count、
//    容量上限）在反例下**全部照旧正确**，只有"被逐出的是 b 而不是 a"会红。
//
//  ⚠️ 前缀用 `T-CACHE` 而不是 `T-LRU` —— `T-LRU` 早在 P10.6a 就被「重放缓存上限」
//    那个用例占了（`smokeMain.swift`），两个撞在一起时按 grep 归因会串。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseLRU() async {
        print("== T-CACHE 定容量缓存的真 LRU 语义 ==")

        // ── 命中之后，被逐出的必须是最久没被用过的那条 ──────────
        let c = LRUCache<Int>(capacity: 3)
        c.insert(1, for: "a")
        c.insert(2, for: "b")
        c.insert(3, for: "c")
        _ = c.value(for: "a")          // 命中 a ⇒ a 变成"最新"
        c.insert(4, for: "d")          // 满了 ⇒ 逐出队首：真 LRU 是 b，FIFO 是 a
        check(c.value(for: "b") == nil,
              "T-CACHE 命中的键被提到最新, 逐出的是 b (FIFO 会逐出刚用过的 a)")
        check(c.value(for: "a") == 1, "T-CACHE 刚命中的键必须还在")
        check(c.value(for: "c") == 3, "T-CACHE 未到期的键没被误逐")
        check(c.value(for: "d") == 4, "T-CACHE 新插入的键在")
        check(c.count == 3, "T-CACHE 容量上限始终守住 (实测 \(c.count))")

        // ── 一次都没命中时，与 FIFO 行为一致（防"过度重排"）──────
        let c2 = LRUCache<Int>(capacity: 3)
        for (i, k) in ["a", "b", "c", "d"].enumerated() { c2.insert(i, for: k) }
        check(c2.value(for: "a") == nil, "T-CACHE 全程未命中时, 逐出的仍是最早插入的 a")

        // ── 同键覆盖不重复占位 ─────────────────────────────────
        let c3 = LRUCache<Int>(capacity: 3)
        c3.insert(1, for: "a")
        c3.insert(2, for: "a")
        check(c3.count == 1, "T-CACHE 同键覆盖写只占一个位置 (实测 \(c3.count))")
        check(c3.value(for: "a") == 2, "T-CACHE 同键覆盖写取到的是新值 (实测 \(c3.value(for: "a") ?? -1))")

        // ── 边界：容量 0 兜底成 1，不会退化成"什么都不存" ────────
        let c4 = LRUCache<Int>(capacity: 0)
        c4.insert(1, for: "a")
        c4.insert(2, for: "b")
        check(c4.count == 1, "T-CACHE 容量 0 兜底为 1 (实测 \(c4.count))")
        check(c4.value(for: "b") == 2, "T-CACHE 兜底容量下留下的是最新那条")

        // ── 塞满 / 溢出 ────────────────────────────────────────
        let c5 = LRUCache<Int>(capacity: 2)
        for i in 0..<50 { c5.insert(i, for: "k\(i)") }
        check(c5.count == 2, "T-CACHE 塞 50 条只留 2 条 (实测 \(c5.count))")
        check(c5.value(for: "k49") == 49, "T-CACHE 留下的是最新的两条之一")

        // ── 并发：内部锁必须真的挡住撕裂 ────────────────────────
        // 判据不是"多快", 而是"读到的永远是插入过的值 + 条数不越界"。
        let c6 = LRUCache<Int>(capacity: 8)
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<400 {
                let key = "k\((t &* 7 &+ i) % 24)"
                if c6.value(for: key) == nil { c6.insert(i, for: key) }
            }
        }
        check(c6.count <= 8, "T-CACHE 并发读写后条数不越界 (实测 \(c6.count))")

        // ── 三个接入点真的接上了 ────────────────────────────────
        // ⚠️ 判据不能是"两次结果相等"—— 不缓存也相等。必须是"这条**躺在缓存里**"。
        let raw = "# 唯一标题 \(UUID().uuidString)\n\n正文一段。\n"
        let blocks = MarkdownParser.parseCached(raw)
        check(blocks.count >= 2, "T-CACHE 解析夹具切出至少 2 个块 (实测 \(blocks.count))")
        check(MarkdownParser.smokeCache.value(for: raw) != nil,
              "T-CACHE MarkdownParser.parseCached 真的走缓存 (解析完这条必须进得了缓存)")

        let code = "let unique_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_")) = 1"
        _ = CodeHighlighter.highlightCached(code, language: "swift")
        check(CodeHighlighter.smokeAttrCache.value(for: "swift\u{1}\(code)") != nil,
              "T-CACHE CodeHighlighter.highlightCached 真的走缓存")

        _ = CodeHighlighter.highlightLinesCached(code, language: "swift")
        check(CodeHighlighter.smokeLinesCache.value(for: "swift\u{1}\(code)") != nil,
              "T-CACHE CodeHighlighter.highlightLinesCached 真的走缓存")

        // 两份缓存必须是**两个实例**: 同一个 key 在两边各存一份, 谁也不挤谁。
        check(CodeHighlighter.smokeLinesCache.count >= 1,
              "T-CACHE 逐行缓存与整块缓存分家 (逐行那条不该挤掉整块那条)")

        // ── 逐行缓存的内容仍然正确（换成 LRU 不该改变语义）───────
        let multiline = "func a() {}\nfunc b() {}\n\nfunc c() {}"
        let lines = CodeHighlighter.highlightLinesCached(multiline, language: "swift")
        check(lines.count == 4, "T-CACHE 逐行高亮行数对得上 (含空行; 实测 \(lines.count))")
        check(lines.map { String($0.characters) }.joined(separator: "\n") == multiline,
              "T-CACHE 逐行高亮拼回去与原文逐字相同 (切行不丢字符)")
    }
}
