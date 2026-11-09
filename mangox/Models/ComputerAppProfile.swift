import Foundation

/// 「这个 App 读起来跟别人不一样」的**唯一**落点。
///
/// 为什么要有它（2026-11-09，0.2.8 收口那一步）：加 Safari 那轮，它跟其余内置 App 的差异
/// 总共只有一件事 —— **渲染上限**（它的树里装着整个网页）。但那件事被写成了一句按 bundle
/// 字面量分叉的三元表达式，藏在 `AXSnapshot` 里。再加一个浏览器时，那行会变成
/// `bundle == A || bundle == B ? … : …` —— 这种写法**错一个字符就谁都不生效**：
/// 不报错、不告警，行为只是静默退回 120，而 120 行对网页来说等于"只能读到页头"。
/// ⇒ 差异集中到这张表；`run.sh` 再钉一条扫源（表外不许出现按 bundle 分叉的等值比较）。
///
/// ⚠️ **只放有消费者的字段。** 当初设想过 `addressBar` / `tabStrip` / `navButtons` /
///    `needsRendererAX`，一个都没建，理由是它们没有读者：
///      · 地址栏在 AX 层根本驱动不了 —— 导航走 `ComputerAddress` + `NSWorkspace`（实测过：
///        Safari 的 `confirm`、Chrome 的 `press` 都回 ok 而页面不动）；
///      · 标签栏与前进/后退只活在手册的**文案**里，代码从不按角色名去找它们；
///      · `needsRendererAX` 属于「Chrome 准入」，那件事没做，没有消费者
///        ⇒ 建了就是会烂的第二真源（表里写着 `true`，而没有一行代码读它）。
///    加字段的正确姿势：**先有读它的代码，再加**。
///
/// ⚠️ 手册正文与白名单**不归这张表**：前者住 `SopManual.text`（几百字文案，由
///    `SopInjection.parse` 切节），后者是 `ComputerSettings.supported` 从
///    「手册节 ∩ `builtins` ∪ `manualFree`」**算**出来的 —— 那边已经把"再抄一份 bundle
///    字面量"这件事消灭过一次（见 `supported` 的注释），别从这里引回来。
enum ComputerAppProfile {

    /// 没被点名的 App 一律这个数 —— 内置那四个的树只有几十到几百行
    /// （备忘录 71 / 日历 130 / 提醒事项 54 / 访达 291），120 绰绰有余；放开是纯亏，
    /// 因为这份渲染文本每一轮都会留在上下文里。
    static let defaultLineLimit = 120

    /// bundle → 一次 `read` 最多渲染多少行。**加一个 App 只加一行。**
    ///
    /// 现在是唯一的差异维度。将来真出现第二个维度，再把值从 `Int` 换成 struct ——
    /// 但要等**真的有**第二个维度，而不是先空着几个字段等它来。
    private static let lineLimits: [String: Int] = [
        // Safari 的树里装着整个网页。实测（2026-11-06，GitHub 仓库页）：2504 节点 /
        // **1598 行**，光前 120 行就 5717 字 ⇒ 全量约 7.6 万字；而 120 行只够看到页头导航
        // （`Products` / `Sign in` / `Code` / `Issues`），正文在 1000 行开外。
        // 3000 是 boss 在 1500 与 5000 之间折中的结果：最坏约 14 万字（≈8.6 万 token），
        // 还是"读一次用得起"的量级，对 1598 行这类常见页面仍留一倍余量。
        //
        // ⚠️ 这是**渲染**上限，与 `AXAdapter` 那两道读的预算（12 秒 / 3000 节点）不是一回事：
        //    前者省上下文，后者防挂死，两者不要混。
        "com.apple.Safari": 3000,
    ]

    /// 表里点过名的 App —— 门禁用它判「被描述的是不是一个**真在清单里**的 App」。
    static var profiledBundles: [String] { lineLimits.keys.sorted() }

    static func lineLimit(for bundle: String) -> Int {
        lineLimits[bundle] ?? defaultLineLimit
    }
}
