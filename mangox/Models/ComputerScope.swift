//
//  ComputerScope.swift
//  P18 批 1: computer use 的**作用域**判据 —— 纯函数, 不 import ApplicationServices。
//
//  两层模型 (P18 §03 改动四; 2026-10-28 boss 拍板):
//    · **App 面** = 谁能进 —— **默认全给**, 用户逐个排除 (落库只存"改过的那些");
//    · **动作面** = 进去能做什么 —— read / act / none, 由 App 类别给默认值。
//
//  ⚠️ 为什么类别**不决定准入**: 拿 App 类别去代理"危险", 挡的是名字不是行为 ——
//     改个名的同类 App 照样过, 被挡住的却是"帮我把那个密码填进去"这种高频正事。
//     所以类别只影响**默认面**; "不能替你按付款"那条靠动作面, 不靠名单 (见 §03 改动七)。
//

import Foundation

/// 动作面。`none` = 连读都不碰; `read` = 只看不动; `act` = 可读可动。
///
/// `rawValue` 小写: 它是**落库串**(`computer_scope_overrides.face`), 改名要有数据迁移。
enum ComputerFace: String, Codable, CaseIterable {
    case none
    case read
    case act
}

/// App 的分类 —— **只用来给默认面**, 不做准入。
///
/// ⚠️ 判据是"这个 App 里的值一旦进上下文就不可挽回", 不是"这个 App 危不危险":
///   密码管理器/钥匙串的值、钱包/支付窗口的余额与卡号, 漏一次就是漏了;
///   至于"能不能在它里面点按钮", 那是动作面的事。
enum ComputerAppClass: String, Codable, CaseIterable {
    case normal
    case credential
}

// ⚠️ 本文件与 `AXSnapshot.swift` / `ComputerRedline.swift` **同时编进 App 与 helper 两个
//    target** ⇒ 只许 `import Foundation`, 不许出现 `L()` / SwiftUI / AppKit。
//    展示文案归展示层: `displayName` 这类属性要放在 UI 那一侧。
//    (实测: 这里写 `L()` 会让 helper target 直接编不过 —— 它不编译 `AppLanguage.swift`。)

/// 用户对某个 App 的面覆盖。
///
/// 落库**只存改过的行**(没出现的 App 走类别默认) ⇒ 以后新增 App 不需要迁移,
/// 也不会出现"库里躺着一堆去年生成、现在没人认的默认值"。
struct ComputerScopeOverride: Equatable, Codable {
    var bundleId: String
    var face: ComputerFace
    /// 把 `credential` 类的面**提到 act** 必须显式置真。
    ///
    /// 默认关的原因不是"不许", 是**默认值要说实话**: 设置页里那一栏长什么样,
    /// 用户没动过它, 它就该表现得像没动过 —— 而不是"你昨天点开过这个 App 就永久开了"。
    var explicitCredentialAct: Bool = false
}

/// 作用域的**唯一**判据入口。调用点不许再写一遍 `face == .act`。
enum ComputerScope {

    /// 类别默认面。`credential` ⇒ 只读; 其余 ⇒ 可动。
    static func defaultFace(for cls: ComputerAppClass) -> ComputerFace {
        switch cls {
        case .credential: return .read
        case .normal:     return .act
        }
    }

    /// 解析某个 App 最终的面。
    ///
    /// 顺序: 类别默认 → 同 `bundleId` 的**最后一条**覆盖(后写覆盖前写, 与"设置页改一次写一行"一致)。
    ///
    /// ⚠️ **这一行就是"act 面恒关"的全部实现**: `credential` 类即使写了 `face = .act`,
    ///   没带 `explicitCredentialAct` 也按默认面算。别在调用点再写一遍 —— 两处判就是两处会漂。
    static func resolvedFace(bundleId: String,
                             appClass: ComputerAppClass,
                             overrides: [ComputerScopeOverride]) -> ComputerFace {
        let base = defaultFace(for: appClass)
        guard let o = overrides.last(where: { $0.bundleId == bundleId }) else { return base }
        if appClass == .credential, o.face == .act, !o.explicitCredentialAct { return base }
        return o.face
    }

    /// 读得到吗(`read` 与 `act` 都能读)。
    static func allowsRead(_ face: ComputerFace) -> Bool { face != .none }

    /// 能动吗。
    static func allowsAct(_ face: ComputerFace) -> Bool { face == .act }
}

/// `computer_read(app: …)` 里那个"app"怎么落到**某个进程**上 —— 纯函数, 候选表由调用方给
/// (helper 侧传"作用域内正在跑的那些", 所以选不中的那一半根本不出现在表里)。
///
/// ⚠️ 为什么不让模型直接给 pid: 它给不出。pid 是本机此刻的事实, 模型只知道 App 名字,
///    让它先问一遍进程表再来 ⇒ 多一轮往返, 而且问到的答案**立刻过期**。
///    分工 = **指认归模型(它知道要读谁), 定位归本机(它知道谁在跑)**。
enum ComputerTarget {

    struct Candidate: Equatable {
        let bundle: String
        let name: String
        let pid: Int32
    }

    /// 从候选里挑出 `query` 指的那一个。
    ///
    /// ⚠️ **空 query ⇒ nil**(不是"随便挑一个")。空表示"当前前台", 而前台是谁
    /// **不是候选表能回答的问题** —— 它取决于此刻谁在最前面, 由调用方用
    /// `NSWorkspace.frontmostApplication` 解决。在这里猜 ⇒ 模型以为读到了它要的那个。
    ///
    /// 优先级: bundle 全等 › bundle 忽略大小写 › 名字全等(忽略大小写) › 名字包含。
    /// ⚠️ "包含"必须放最后: `Safari` 也命中 `Safari Technology Preview`, 只有没有精确
    ///    匹配时才退到它 —— 否则 `Mail` 会先撞上 `MailMate`, 读错还零报错。
    static func pick(query: String, in candidates: [Candidate]) -> Candidate? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        if let hit = candidates.first(where: { $0.bundle == q }) { return hit }
        if let hit = candidates.first(where: { $0.bundle.lowercased() == lower }) { return hit }
        if let hit = candidates.first(where: { $0.name.lowercased() == lower }) { return hit }
        return candidates.first(where: { $0.name.lowercased().contains(lower) })
    }
}
