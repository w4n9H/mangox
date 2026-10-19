# scripts/smoke/cases —— 冒烟新用例的家

`smokeMain.swift` 已经太大（一个 `run()` 函数 7300+ 行），并且加了**体量棘轮门**：
那个文件的行数只能减不能增。所以**新用例一律放这里**，不要再往主文件里加。

## 一个用例长什么样

```swift
// CaseNoteProposals.swift
import Foundation

extension SmokeMain {
    /// P15 提案队列: 丢弃 / 采纳都必须删行
    @MainActor
    static func caseNoteProposals() async {
        print("== P15 提案队列: 拍过板就删行 ==")

        // ① 自带夹具 —— 必用 fixtureDir，不要碰 fixturesRoot，也不要依赖别人的目录
        let root = fixtureDir("note-prop")

        // ② 建你自己的 store / 磁盘状态（可以和用例一起活到函数结束）
        //    …

        // ③ 断言
        check(x == y, "P15 丢弃后队列里不留行")
    }
}
```

然后在同目录 `AllCases.swift` 的 `registeredCases` 数组里登记一行：

```swift
registeredCases: [@MainActor () async -> Void] {
    [
        caseNoteProposals,
    ]
}
```

`run()` 里只有一行 `await runRegisteredCases()`，**以后都不用再动主文件**。

## 三条硬约定

1. **自带夹具**：用 `fixtureDir("tag")` 建自己的目录。它在每次运行的共同根下面，
   `report()` 收尾时一起清掉。**不要**读写 `fixturesRoot`，更不要往 `NSHomeDirectory()` 里写。
2. **不共享状态**：不要引用 `run()` 里的任何局部变量 —— 那些不属于你，而且它们在另一个函数里。
   需要 store 就自己建（`ChatStore(transport:dbPath:…)`），用完就随函数结束。
3. **开头打一行 `print("== 标题 ==")`**：冒烟日志靠这行分节，缺了以后没人看得懂输出。

## 为什么不能"就加一行到 run() 里"

`scripts/smoke/size_budget` 记着主文件的行数上限，超了门禁直接红。这是有意的：
2026-10-19 试过把 `run()` 按注释锚点机械抽成 67 个函数，结果抽断了它几百个共享夹具的
作用域，Swift 约束求解器掉进 `salvage()` 指数爆炸，编译从 126 秒变成 19 分钟以上，
而且**没有任何红灯**（编译日志 0 字节）。所以改成"冻结 + 增量外移"：
新代码从外面长，老代码等有人真去改那一段时再顺手搬出去。
