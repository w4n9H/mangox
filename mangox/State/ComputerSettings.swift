//
//  ComputerSettings.swift
//  P18: computer use 的**开关与作用域** —— 批 1 只做"能真机手验"的那一小块。
//
//  ⚠️ 为什么批 1 就得有个开关: 链路全通但作用域恒空 ⇒ 谁也没法真用它一次。
//     一条从没被真机验证过的链路上去翻审批闸门(批 2a), 出问题分不清是闸门还是链路。
//
//  ⚠️ **归属是全局, 生效时机是 spawn** —— 这两件事 2026-10-29 被 boss 指出来过:
//     名单存在 settings 表里, **一份**, 每个 spawn 都读同一份（档位裁不裁它由 `--tools` 决定）
//     (所以"只有某个会话能读 Safari"是不成立的)。
//     但下发给 helper 的动作发生在 spawn 那一刻 ⇒ 改完要等下一次对话才生效。
//     原来这里写的是"作用域是这一轮才存在的凭证" —— 错, 把"何时生效"说成了"归谁所有"。
//
//  ⚠️ 落盘值**不许是容器里的位置**(本仓 10-08 那条纪律: 存序号 ⇒ 插/挪一项 ⇒ 老值
//     静默改义、零红灯) ⇒ 存 **bundle id 本身**, 反解时按字面认领。
//
//  ⚠️ **能勾哪些 App = 固定白名单**（2026-11-06 boss 拍板, 见 `supported`）。
//     原来那份"扫 `/Applications` 扫出几百个包"的清单已经删掉 —— 它把"装了什么"当成了
//     "能用什么", 而这两件事在 computer use 里差得很远: 能不能读、能点哪里, 取决于那个 App
//     的 AX 树有没有被真机量过（手册 + 探针）。
//

import AppKit
import Foundation

@MainActor
final class ComputerSettings: ObservableObject {

    static let shared = ComputerSettings()

    // MARK: 落盘键 (settings 表)

    static let enabledKey = "computer_enabled"   // "1" / "0"; 缺失 = 关
    /// 逗号分隔的 bundle id。**bundle id 不含逗号**, 所以这个分隔法不会歧义。
    static let bundlesKey = "computer_bundles"
    /// 操作面(批 2b)。**与读面分开一个键**: 合成一个 `"bundle:act"` 之类会让老库的值
    /// 静默改义(本仓 10-08 那条纪律), 而且读面与操作面是两档权限, 混着存就没法分别改。
    static let actBundlesKey = "computer_act_bundles"
    /// 图像面(批 3c)。第三档, **默认空** —— 截图会绕过文本遮蔽(像素里没有 `••••`),
    /// 所以它必须是**逐个 App 显式开**, 不许"跟着读面一起开"。
    /// ⚠️ 又一个独立的键: 与上面同一条纪律(合成一个键 ⇒ 老值静默改义), 而且
    ///    "能读文本"与"能拍像素"是两档不同代价的权限。
    static let imageBundlesKey = "computer_image_bundles"
    /// 接管检测(批 3b 的"人在键鼠旁时让路")。**默认关** —— 2026-11-02 改。
    ///
    /// ⚠️ 它要「输入监控」那把钥匙, 而钥匙只能由系统弹窗索要一次 ⇒ 原来在 `interactive` 档
    ///    (默认档)无条件下发, 等于"用户什么都还没要, 先弹一个「MangoX 想监听你的键盘输入」"。
    ///    boss 的原话是三个权限申请时机相隔很远、体验不好 —— 这一下是最刺眼的那一下,
    ///    因为另两把都发生在"你要了某个具体东西"之后, 只有它发生在 spawn 时。
    static let takeoverKey = "computer_takeover"   // "1" / 缺失 = 关

    // MARK: 状态

    /// 总开关。**默认关** —— 批 1 阶段没有作用域 UI 之前默认开 = 悄悄开一个面。
    @Published var enabled: Bool = false { didSet { persist() } }

    /// 勾上的 bundle id —— **读面**。
    @Published private(set) var selected: Set<String> = [] { didSet { persist() } }

    /// 勾上的 bundle id —— **操作面**。恒为 `selected` 的子集(不变量见 `decode`)。
    @Published private(set) var actSelected: Set<String> = [] { didSet { persist() } }

    /// 勾上的 bundle id —— **图像面**(批 3c)。同样恒为 `selected` 的子集。
    ///
    /// ⚠️ 与操作面不同, 它是"更贵的一档": 截图会带上**整个窗口的像素**, 包括文本层已经
    ///    遮掉的那些 ⇒ 用户必须**逐个 App 明确开**, 默认一个都不开(空 = 一张都不拍)。
    @Published private(set) var imageSelected: Set<String> = [] { didSet { persist() } }

    /// 接管检测的**意图**(不等于生效: 还要有「输入监控」权限, 见 `shouldInstallTakeover`)。
    ///
    /// ⚠️ 与设置页那盏灯是**两件事**(P11 判据④的同族): 开关说"我打算用", 灯说"系统给没给"。
    ///    权限没给时开关照样可以开着 —— 用户点完允许要重启才生效, 那时若把开关弹回去,
    ///    他只会以为"点了没反应"; 而 helper 侧有 `granted` 那道与门 ⇒ 没权限就不装监听、不弹窗。
    @Published var takeoverEnabled: Bool = false { didSet { persist() } }

    /// 候选表注入 —— **只给冒烟用**(真机上恒 nil)。
    ///
    /// ⚠️ 有它才能对"审批那一刻把 `app` 认成哪个 bundle"写真断言: 真机上哪些 App 在跑是
    ///    环境(CI 上没有 Safari), 而判据必须**在任何机器上复现**。这不是给生产留的开关,
    ///    冒烟用完就置回 nil。
    var candidateOverride: [ComputerTarget.Candidate]?

    /// 设置页里能勾的 App = **固定白名单**（`supported`），不是"扫出来的所有 App"。
    ///
    /// ⚠️ 演变史, 别退回上一版:
    ///    · 2026-10-28: 只列**正在运行**的 ⇒ boss 问「浏览器怎么都没有」（没打开的 App 勾不到）;
    ///    · 2026-10-28 当天: 改成"已安装的 ∪ 正在运行的" ⇒ 又变成**几百行**, 而且大半没量过;
    ///    · 2026-11-06: 改成固定列表（boss 原话见 `supported`）。
    /// 列表的职责是**让人挑得到**, 但"挑得到"的前提是"这个 App 真能用"。
    @Published private(set) var options: [Option] = []

    /// 落盘口子, 由 `ChatStore` 接上 persistence。**nil = 不落盘**(冒烟里就是 nil)。
    ///
    /// ⚠️ 为什么不直接持有 persistence: 本类要能被视图当单例直接观察
    ///    (`@ObservedObject private var computer = ComputerSettings.shared`),
    ///    而 persistence 是 ChatStore 的东西 —— 传一个闭包进来, 两边都不必互相持有。
    var onPersist: ((String, String) -> Void)?

    // MARK: 可勾选清单 (固定白名单 ≠ 装了什么)

    struct Option: Identifiable, Equatable {
        let bundle: String
        let name: String
        /// 此刻是否在运行。
        ///
        /// ⚠️ **必须显示出来**: 只有运行中的 App 现在就能读; 勾一个没在跑的, 读的时候会回
        ///    "它现在没在跑"。勾选本身仍然允许(那就是"先勾好"), 但用户得看得见这个差别。
        let running: Bool
        var id: String { bundle }
    }

    /// 设置页能勾的 App —— **固定白名单** = 手册覆盖的那几个 + `manualFree`（免手册的极简 App）。
    ///
    /// ⚠️ 为什么改（2026-11-06 boss 拍板, 原话「这个里面应用太多了, 而且很多都不确定能不能跑通」）:
    ///    扫 `/Applications` 会列出几百个包, 而其中**只有手册覆盖的那几个**在真机上量过 ——
    ///    界面节点长什么样、哪些事做不到, 都是逐条探针跑出来的（`scripts/diag/*.sh`）。
    ///    其余应用勾上之后大概率是"读得到一堆无名 group, 一步也动不了", 却要用户自己撞一遍才知道。
    ///    **列表就是承诺**: 出现在这里 ⇒ 手册里写了它怎么读、哪些事做不到（或者见 `manualFree`）。
    ///
    /// ⚠️ 这里**不再抄一份 bundle 字面量**: 白名单在两个地方漂过一次（`builtins` 上那条
    ///    "扩集合 = 两处一起改"就是为此写的）⇒ 顺序取**手册里的顺序**（写的人把常用的放前面）,
    ///    集合以 `builtins` + `manualFree` 为准。
    /// ⚠️ 白名单里有、手册里**缺那一节**的 App 要**照样出现**（排在最后）: 漏节是另一件事
    ///    （`SopInjection.block` 的 `missing` 会点名、冒烟「手册本体」会红）, 而悄悄少一行更坏 ——
    ///    用户只会以为"这个 App 不支持", 没人会想到是手册漏了一节。
    /// `nonisolated`: 纯解析, 而冒烟（顶层代码）要在任意上下文里调它。
    nonisolated static var supported: [String] {
        let doc = SopInjection.parse(SopManual.text)
        var seen = Set<String>()
        var out: [String] = []
        for sec in doc.sections
        where sec.bundle != "" && SopInjection.builtins.contains(sec.bundle)
              && seen.insert(sec.bundle).inserted {
            out.append(sec.bundle)
        }
        // 免手册的那几个排在手册 App 后面: 它们没有"常用程度"可排, 也不抢前四位。
        for b in manualFree where seen.insert(b).inserted {
            out.append(b)
        }
        for b in SopInjection.builtins.sorted() where seen.insert(b).inserted {
            out.append(b)
        }
        return out
    }

    /// **免手册**的应用 —— `supported` 里唯一不受"手册写没写它"约束的那几个。
    ///
    /// ⚠️ 判据不是"这个 App 简单"这种感觉, 而是**量一次能不能穷尽它的界面**:
    ///    ① 系统内置; ② **单窗口 + 平铺按钮**, 没有侧栏 / 列表 / 拖拽 / 只在菜单里才够得着的功能;
    ///    ③ 不在 `ComputerRedline.actBannedBundles` 里。
    ///    计算器满足这三条: 一个显示屏 + 二十来个带名字的 `AXButton`, 量一次就是全部;
    ///    给它写一节 SOP 只会每轮白占几百字预算。
    /// ⚠️ 反过来: 只要有"侧栏 / 列表行 / 右键菜单"这类**结构**, 就必须写手册 —— `custom` 动作
    ///    是行作用域的、菜单项的作用域判不了, 这两件事没法靠"看起来简单"推出来, 必须真机量。
    /// ⚠️ 改这个列表要连带看冒烟那两条: 与 `builtins` 不许重叠（重叠 = 两份声明会漂）、
    ///    与恒拒名单不许相交（捷径不是绕开红线的后门）。
    nonisolated static let manualFree: [String] = [
        "com.apple.calculator",   // 计算器: 单窗口平铺按钮, 2026-10-29 探针量过
    ]

    /// 手册里的节名（`备忘录` 这种）—— 只在系统给不出名字时用作回落。
    nonisolated static func manualTitles(_ raw: String = SopManual.text) -> [String: String] {
        var out: [String: String] = [:]
        for sec in SopInjection.parse(raw).sections where out[sec.bundle] == nil {
            out[sec.bundle] = sec.title
        }
        return out
    }

    /// 白名单里每个 App 的显示名 —— **跟着系统语言走**（`备忘录` / `Notes` 各按本机来）。
    ///
    /// 取不到（App 被删、LaunchServices 不认）就退手册里的节名, 再退 bundle 末段:
    /// 三种都必须有个名字, 因为这一行要能被人认出来点。
    /// `resolve` 可注入 ⇒ 冒烟不必连 LaunchServices 就能断言这三档回落。
    /// ⚠️ 默认值里写**类名**不写 `Self`: Swift 不许在默认实参表达式里引用协变的 `Self`。
    nonisolated static func displayNames(for bundles: [String],
                                         manualTitles: [String: String] = [:],
                                         resolve: (String) -> String? = { ComputerSettings.appDisplayName($0) })
    -> [String: String] {
        var out: [String: String] = [:]
        for b in bundles {
            if let n = resolve(b), !n.isEmpty { out[b] = n; continue }
            if let t = manualTitles[b], !t.isEmpty { out[b] = t; continue }
            out[b] = ComputerTarget.lastSegment(of: b)
        }
        return out
    }

    /// 系统给的 App 名（本地化过的那个）。取不到 ⇒ nil, **不猜**。
    ///
    /// ⚠️ 走 `object(forInfoDictionaryKey:)` 而不是 `infoDictionary` 直读: 前者会顺着
    ///    `.lproj` 取**本地化**过的名字, 后者拿到的是原始串（常常是英文名）。
    nonisolated static func appDisplayName(_ bundle: String) -> String? {
        guard let url = appURL(bundle) else { return nil }
        guard let b = Bundle(url: url) else { return nil }
        return (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    /// ⚠️ 单独一层是因为它**必须能在没有 AppKit 的上下文里被替换**: 冒烟用注入的
    ///    `resolve` 绕开它, 生产恒走 `NSWorkspace`。
    nonisolated static func appURL(_ bundle: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    }

    /// 固定白名单 → 可勾选行。**纯函数**: 输入只有「白名单顺序 / 名字 / 此刻在跑谁」。
    ///
    /// ⚠️ 行数**恒定等于白名单大小**: 装没装、跑没跑都**不决定**它在不在列表里, 只决定那一行
    ///    有没有「运行中」那个标记 —— 这正是"固定列表"的意思: 先勾好, 等下真的打开那个 App 就能用。
    nonisolated static func options(bundles: [String],
                                    names: [String: String],
                                    running: [ComputerTarget.Candidate]) -> [Option] {
        let live = Set(running.map(\.bundle))
        return bundles.map { b in
            Option(bundle: b,
                   name: names[b] ?? ComputerTarget.lastSegment(of: b),
                   running: live.contains(b))
        }
    }

    /// 正在运行的 App(只算 regular —— 菜单栏程序与后台 agent 没有窗口可读)。
    ///
    /// ⚠️ 这里可以用 `NSWorkspace.shared.runningApplications`: App 的主线程一直在抽 run loop,
    ///    它会随通知刷新。**helper 里不行** —— 那个进程阻塞在 `accept()` 上, 同一个 API 会
    ///    **定格在首次查询那一刻**(2026-10-29 实测; 见 `ComputerServer.runningApp`, run.sh ③p 扫着)。
    static func runningApps(excluding me: String?) -> [ComputerTarget.Candidate] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundle = app.bundleIdentifier, bundle != me,
                  app.activationPolicy == .regular, app.processIdentifier > 0 else { return nil }
            return ComputerTarget.Candidate(bundle: bundle,
                                            name: app.localizedName ?? bundle,
                                            pid: app.processIdentifier)
        }
    }

    // MARK: 判据 (纯函数)

    /// 真正下发的作用域 —— 全局配置在这一刻的投影（不是"本轮私有"，见文件头）。
    ///
    /// ⚠️ **这里不按白名单过滤, 是有意的**: 白名单（`supported`）管的是"设置页给不给你勾",
    ///    不是"能不能读"。库里的越界值由 `pruneUnsupported` 在**启动时**收敛一次;
    ///    若这一层再滤一遍, 等于把"产品目录"和"权限投影"合成一个东西 —— 而 `CaseActScope` ③d
    ///    证明的恰恰是"投影要挡的是硬禁区与未勾选, 不是目录外"（那道判据得能造出越界状态才验得到）。
    ///
    /// ⚠️ **排序后**返回: 下发顺序稳定 ⇒ 同样的勾选每次拼出同样的 env 串 ⇒ 可断言、可肉眼看 diff。
    ///    `Set` 的迭代顺序不稳定(且与插入顺序无关), 直接下发会让"改了什么"看不出来。
    var activeBundles: [String] {
        guard enabled else { return [] }
        return selected.sorted()
    }

    /// 真正下发的**操作面** —— 同上的投影。
    ///
    /// ⚠️ 这里再取一次 `selected` 的交集不是多余的: `actSelected ⊆ selected` 的不变量
    ///    在 `decode`/`setAct` 都守了, 但这一处是**发出去**的那一刻 —— 双闸门的老规矩,
    ///    出事的那个方向(多发一个 App 的操作权)不值得省这一行。
    var activeActBundles: [String] {
        guard enabled else { return [] }
        return actSelected.intersection(selected)
            .filter { !ComputerRedline.actBannedBundles.contains($0) }
            .sorted()
    }

    // MARK: 读健康 (2026-11-02)

    /// 某个 App **最近一次"读"**的结果。数据源是 helper 写的 `~/.mangox/computer/health/<bundle>.json`。
    ///
    /// ⚠️ 为什么这条观测不是"手写黑名单": 2026-11-02 实测邮件收件箱(799 封)一次 read
    ///    走了 **3000 节点 / 200 秒**, 而 helper 是单线程串行 —— 那 200 秒里整个 computer use
    ///    挂住。手写一个 `mail` 黑名单能挡住这一次, 但挡不住下一个"界面很大"的 App, 而且
    ///    **剪枝修好之后没人记得回来删它**。所以名单由**观测**长出来: 每次 read 覆盖写一行,
    ///    读成功就把之前的坏标记盖掉 ⇒ 它自己会退回去。
    struct ReadHealth: Equatable {
        // 三个取值 = helper 侧 `AXAdapter.StopReason` 的 rawValue。两侧各是一个 target,
        // **不能互相 import** ⇒ 这份契约只有字符串。改名要同时改两侧;
        // `scripts/smoke/cases/CaseComputerPure.swift` 的「读健康」那一组钉住了解析与三态。
        let stop: String        // complete / budget / timeout —— 后两个都是"没读完"
        let rows: Int
        let elapsedMs: Int
        let at: Date

        /// 上次没读完。
        var isPartial: Bool { stop != "complete" }
        /// 观测过期(7 天) ⇒ 不再据此劝退。**只影响提示, 不阻断能力** ——
        /// 过期不等于变好了, 只等于"这条观测已经不能代表现在"。
        var isStale: Bool { Date().timeIntervalSince(at) > 7 * 24 * 3600 }
        /// 该不该在设置页把它标成"读不动"。
        var isBlocking: Bool { isPartial && !isStale }
    }

    nonisolated static var readHealthDir: String {
        NSHomeDirectory() + "/.mangox/computer/health"
    }

    /// 全量读一遍健康目录 —— **设置页打开时调一次**, 别每行调(几百个 App 就是几百次文件 IO)。
    ///
    /// `dir` 可传 —— 冒烟要在临时目录里造样本, 而真机的路径是固定的。
    nonisolated static func loadReadHealth(dir: String = readHealthDir) -> [String: ReadHealth] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [:] }
        var out: [String: ReadHealth] = [:]
        for name in names where name.hasSuffix(".json") {
            let path = dir + "/" + name
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bundle = obj["bundle"] as? String,
                  let stop = obj["stop"] as? String,
                  let at = obj["at"] as? Double else { continue }
            out[bundle] = ReadHealth(stop: stop,
                                     rows: obj["rows"] as? Int ?? 0,
                                     elapsedMs: obj["elapsedMs"] as? Int ?? 0,
                                     at: Date(timeIntervalSince1970: at))
        }
        return out
    }

    /// 某个 App 能不能开"操作"—— 口令/系统类是硬禁区, 设置页据此把那一格禁用。
    nonisolated static func canAct(_ bundle: String) -> Bool {
        !ComputerRedline.actBannedBundles.contains(bundle)
    }

    /// 真正下发的**图像面** —— 同上的投影。
    ///
    /// ⚠️ 这里是 `activeImageBundles` **再取一次交集 + 再过一遍硬禁区**: 图像是唯一能绕过
    ///    遮蔽的通道(文本值被换成 `••••`, 像素里是原样) ⇒ 凭据 / 系统设置类 App **一个像素
    ///    都不许拍**。这条不是"顺手加个过滤", 它是图像面能存在的前提。
    var activeImageBundles: [String] {
        guard enabled else { return [] }
        return imageSelected.intersection(selected)
            .filter { Self.canImage($0) }
            .sorted()
    }

    /// 能不能拍这个 App 的像素。与 `canAct` 用同一批硬禁区, 但理由不同:
    /// 操作面怕"替人按了付款", 图像面怕"替人把密码拍成图"。
    nonisolated static func canImage(_ bundle: String) -> Bool {
        !ComputerRedline.actBannedBundles.contains(bundle)
    }

    // MARK: 接管检测 (批 3b, 2026-11-02 改成显式开关)

    /// 这一档 + 这个开关 + 系统有没有给权限 —— 三者都成立才装那条只看不注入的事件监听。
    ///
    /// ⚠️ 三个条件缺一不可, 而**缺 `granted` 那一支是有代价的**: 没权限还去 `CGEvent.tapCreate`,
    ///    系统会当场弹一次"要不要允许 MangoX 监听你的键盘输入"。这道与门的作用就是
    ///    "不许再偷偷把权限带出来"本身 —— 少写一个 `&&` 就退回老行为, 且**不会有任何红灯**
    ///    (`CaseComputerPure` 里有一条专门盯它)。
    ///
    /// ⚠️ `granted` **必须由调用方在 spawn 那一刻现场查**(`ComputerPermission.isGranted`),
    ///    不许复用设置页那盏灯: 灯是 `@Published` 快照, helper 是另一条进程, 两者分叉会出现
    ///    "灯是亮的、helper 没装" —— 那是所有失败里最难查的一种。
    nonisolated static func shouldInstallTakeover(expectsHuman: Bool,
                                                  persisted: Bool,
                                                  granted: Bool) -> Bool {
        expectsHuman && persisted && granted
    }

    /// 上面那条的实例版(真机上只走这个)。`granted` 现场读, 理由见纯函数注释。
    func shouldInstallTakeover(expectsHuman: Bool) -> Bool {
        Self.shouldInstallTakeover(expectsHuman: expectsHuman,
                                   persisted: takeoverEnabled,
                                   granted: ComputerPermission.inputMonitoring.isGranted)
    }

    /// 落盘串 → 状态。**乱值一律按"关/空"算**, 不猜。
    ///
    /// ⚠️ 单独抽出来是因为它既要被 `ChatStore` 在启动时调, 也要能被冒烟断言 ——
    ///    写进 `restore` 里就成了"只有真启动才验得到"的逻辑。
    ///
    /// ⚠️ **不变量 `act ⊆ read` 在这里落一次**: 老库(批 1)里根本没有 `act` 这个键;
    ///    手改过的库、或者"先勾操作再取消读"留下的组合, 都会让操作面里留着一个读不到的 App。
    ///    那种状态没有意义, 而且它会悄悄把 `MANGOX_COMPUTE_ACT_BUNDLES` 填上。
    static func decode(enabledRaw: String?,
                       bundlesRaw: String?,
                       actRaw: String? = nil,
                       imageRaw: String? = nil) -> (enabled: Bool,
                                                    bundles: Set<String>,
                                                    actBundles: Set<String>,
                                                    imageBundles: Set<String>) {
        let enabled = enabledRaw == "1"
        guard enabled else { return (false, [], [], []) }
        let bundles = Set((bundlesRaw ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let act = Set((actRaw ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let image = Set((imageRaw ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
        return (true, bundles, act.intersection(bundles), image.intersection(bundles))
    }

    /// 状态 → 落盘串。同样再取一次交集 —— `encode` 是另一条入口(测试、将来的导入导出)。
    static func encode(enabled: Bool,
                       bundles: Set<String>,
                       actBundles: Set<String> = [],
                       imageBundles: Set<String> = []) -> (enabled: String,
                                                            bundles: String,
                                                            actBundles: String,
                                                            imageBundles: String) {
        (enabled ? "1" : "0",
         bundles.sorted().joined(separator: ","),
         actBundles.intersection(bundles).sorted().joined(separator: ","),
         imageBundles.intersection(bundles).sorted().joined(separator: ","))
    }

    // MARK: 操作

    func restore(enabledRaw: String?, bundlesRaw: String?, actRaw: String? = nil,
                 imageRaw: String? = nil, takeoverRaw: String? = nil) {
        let d = Self.decode(enabledRaw: enabledRaw, bundlesRaw: bundlesRaw,
                            actRaw: actRaw, imageRaw: imageRaw)
        enabled = d.enabled
        // ⚠️ 顺序有意义: 先置两档子集再置 `selected` —— 反过来的话中间那一拍会出现
        //    "子集里有、读面里没有"的短暂状态, 而 `didSet` 会把它 persist 出去。
        actSelected = d.actBundles
        imageSelected = d.imageBundles
        selected = d.bundles
        // 接管检测**放最后**: 它的 `didSet` 会 persist 一次, 落在最后 ⇒ 那一次写出去的
        // 是已经全部就位的状态(放前面写的就是半截, 而半截也会被真落库)。
        // "不写 `?? true`" 是有意的: 老库没有这个键 ⇒ 关, 不是"沿用旧的偷偷开"。
        takeoverEnabled = takeoverRaw == "1"
    }

    /// 把模型给的 `app`(名字或 bundle id)落到 bundle 上 —— **认不出就 nil, 不猜**。
    ///
    /// 候选表的来源是"可勾选清单(已安装 ∪ 运行中)": 与 `ComputerTarget.pick` 的优先级
    /// 合起来, 精确 bundle / 精确名字都排在"名字包含"之前 ⇒ `Mail` 不会先撞上 `MailMate`。
    ///
    /// ⚠️ 2026-10-29 起这条是**审批桥里唯一的认 App 入口**: 桥里拿它的结果去查
    ///    `activeActBundles`。查的必须是**真正下发给 helper 的那一份投影**, 不是勾选框的
    ///    原始状态 —— 两者在"总开关关着"时就会分叉, 查原始状态等于放行一个 helper 必拒的动作。
    func resolveBundle(query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }   // 空 = 当前前台, 此刻答不了
        var candidates = candidateOverride ?? options.map {
            ComputerTarget.Candidate(bundle: $0.bundle, name: $0.name, pid: 0)
        }
        // `options` 可能还没被 `refresh()` 填过(用户没打开过设置) ⇒ 用**此刻正在跑的**兜底。
        if candidates.isEmpty {
            candidates = Self.runningApps(excluding: Bundle.main.bundleIdentifier)
        }
        return ComputerTarget.pick(query: trimmed, in: candidates)?.bundle
    }

    func setSelected(_ bundles: Set<String>) { selected = bundles }

    func toggle(_ bundle: String) {
        if selected.contains(bundle) {
            selected.remove(bundle)
            // ⚠️ 取消"可读"必须连带摘掉"可操作"与"图片": 否则留下"动得了但读不到"
            //    / "拍得了但读不到"两种组合, 而它们在 helper 侧一定是被拒的 ——
            //    设置页却还勾着, 人只会以为"这个功能时好时坏"。
            if actSelected.contains(bundle) { actSelected.remove(bundle) }
            if imageSelected.contains(bundle) { imageSelected.remove(bundle) }
        } else {
            selected.insert(bundle)
        }
    }

    /// 开/关某个 App 的**操作**权。带上读面(开操作必然要能读), 口令类恒不许开。
    func setAct(_ bundle: String, _ on: Bool) {
        guard Self.canAct(bundle) else { return }
        if on {
            selected.insert(bundle)
            actSelected.insert(bundle)
        } else {
            actSelected.remove(bundle)
        }
    }

    /// 开/关某个 App 的**图像**面(批 3c)。同样带上读面; 硬禁区恒不许开。
    ///
    /// ⚠️ 与 `setAct` 的差别: 这里**不动** `actSelected` —— "能看"和"能按"是两件事,
    ///    互相带上是上一批特意避开的错(会让人以为自己只开了一档)。
    func setImage(_ bundle: String, _ on: Bool) {
        guard Self.canImage(bundle) else { return }
        if on {
            selected.insert(bundle)
            imageSelected.insert(bundle)
        } else {
            imageSelected.remove(bundle)
        }
    }

    /// 刷新可勾选列表。
    ///
    /// ⚠️ 2026-11-06 起**不再扫 `/Applications`**: 列表是固定白名单（见 `supported`）, 这一趟只剩
    ///    4 次 LaunchServices 查询 + 一次"谁在跑"（毫秒级）⇒ 原来那个**两段式**（先取运行态立刻上屏、
    ///    再后台扫几百个包洗完换一版）没有存在的理由了。去掉之后 `installed` 那份缓存也一起删掉。
    func refresh() {
        let bundles = Self.supported
        let running = Self.runningApps(excluding: Bundle.main.bundleIdentifier)
        options = Self.options(bundles: bundles,
                               names: Self.displayNames(for: bundles,
                                                        manualTitles: Self.manualTitles()),
                               running: running)
    }

    /// 一次性收敛: 把**不在白名单里**的勾选摘掉（2026-11-06 boss 定: 只开放真机量过 SOP 的 App）。
    ///
    /// ⚠️ **不放进 `restore` / `decode`**: 那两个的契约是"库里有什么就如实还原", 越界值由**投影**
    ///    兜底（`activeActBundles` 再滤一遍硬禁区就是为这个; `CaseActScope` ③d 正是靠"手改过的库
    ///    仍能把口令类留在勾选集里"来证明桥必须查投影）。这里是**产品决定**（哪些 App 还能用）,
    ///    属于启动时装配 —— 两件事, 合起来两边都变糊。
    ///
    /// ⚠️ 必须**在 `onPersist` 接上之后**调: 否则摘掉的值只活在内存里, 库里躺的还是旧的 ⇒
    ///    下次启动再摘一遍, 而且"库 vs 界面"永远不一致。
    /// 返回值 = 被摘掉的 bundle（字母序）: 要留痕, 也要能断言。
    @discardableResult
    func pruneUnsupported() -> [String] {
        let ok = Set(Self.supported)
        let dropped = selected.subtracting(ok)
            .union(actSelected.subtracting(ok))
            .union(imageSelected.subtracting(ok))
            .sorted()
        guard !dropped.isEmpty else { return [] }
        // 顺序沿用 `restore`: 先收子集再收读面 —— 反过来的中间那一拍会出现"子集里有、读面里没有",
        // 而 `didSet` 会把那一拍 persist 出去。
        actSelected.formIntersection(ok)
        imageSelected.formIntersection(ok)
        selected.formIntersection(ok)
        Log.event("computer-prune", ["dropped": dropped.joined(separator: ","),
                                     "kept": selected.sorted().joined(separator: ",")])
        return dropped
    }

    private func persist() {
        guard let onPersist else { return }
        let e = Self.encode(enabled: enabled, bundles: selected,
                            actBundles: actSelected, imageBundles: imageSelected)
        onPersist(Self.enabledKey, e.enabled)
        onPersist(Self.bundlesKey, e.bundles)
        onPersist(Self.actBundlesKey, e.actBundles)
        onPersist(Self.imageBundlesKey, e.imageBundles)
        // ⚠️ 恒写 "1"/"0" 而不是"只在开的时候写": 关掉时必须留下一个明确的 "0",
        //    否则下次启动读不到键 ⇒ 走"缺失 = 关"那条, 结论一样但看不出"是谁关的"。
        onPersist(Self.takeoverKey, takeoverEnabled ? "1" : "0")
    }
}
