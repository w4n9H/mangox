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

    /// 候选表注入 —— **只给冒烟用**(真机上恒 nil)。
    ///
    /// ⚠️ 有它才能对"审批那一刻把 `app` 认成哪个 bundle"写真断言: 真机上哪些 App 在跑是
    ///    环境(CI 上没有 Safari), 而判据必须**在任何机器上复现**。这不是给生产留的开关,
    ///    冒烟用完就置回 nil。
    var candidateOverride: [ComputerTarget.Candidate]?

    /// 设置页里能勾的 App = **已安装的 ∪ 正在运行的**。
    ///
    /// ⚠️ 2026-10-28 boss 拿着截图问「浏览器怎么都没有」—— 当时只列**正在运行**的
    ///    (`NSWorkspace.runningApplications`), 没打开的 App 一律看不见, 于是"先勾好、等会儿用"
    ///    这件事做不到。列表的职责是**让人挑得到**, 不是"只显示此刻能用的"。
    @Published private(set) var options: [Option] = []

    /// 扫出来的已安装 App。扫一次就缓存 —— 目录内容不会一分钟变一次。
    private var installed: [(bundle: String, name: String)] = []

    /// 落盘口子, 由 `ChatStore` 接上 persistence。**nil = 不落盘**(冒烟里就是 nil)。
    ///
    /// ⚠️ 为什么不直接持有 persistence: 本类要能被视图当单例直接观察
    ///    (`@ObservedObject private var computer = ComputerSettings.shared`),
    ///    而 persistence 是 ChatStore 的东西 —— 传一个闭包进来, 两边都不必互相持有。
    var onPersist: ((String, String) -> Void)?

    // MARK: 可勾选清单 (已安装 ∪ 运行中)

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

    /// App 可能落的目录。
    ///
    /// ⚠️ **两层都扫**: `/Applications/*.app` 之外还有厂商目录(`/Applications/*/*.app`,
    ///    Adobe / Office / 部分国产软件都往里放)。只扫一层的话那些 App 永远不出现在列表里 ——
    ///    而这正是 boss 这次截图里"看不到"的那一类。
    nonisolated static func appRoots(home: String) -> [String] {
        ["/Applications", "/System/Applications",
         "/Applications/Utilities", "/System/Applications/Utilities",
         home + "/Applications"]
    }

    /// 合并成一份可勾选清单 —— **纯函数**, 冒烟能断言。
    ///
    /// 三条规则:
    ///   ① 已安装为底;
    ///   ② 正在跑但没被扫到的(容器内 App、临时挂载的 dmg、`Contents/MacOS` 直接起的)也要进来 ——
    ///      "列表里看不到却明明在跑"是最费解的一种;
    ///   ③ **按名字排序**。按"运行中优先"排会让列表每隔几分钟就整块重排, 正在找某个 App 的
    ///      时候最烦。
    ///
    /// ⚠️ `keep` = 已经勾上的 bundle。它可能**不在**扫出来的清单里(那个 App 被删了、改名了) ——
    ///    不补进来的话会出现"勾着但看不见、也取消不掉"。
    nonisolated static func merge(installed: [(bundle: String, name: String)],
                      running: [ComputerTarget.Candidate],
                      keep: Set<String> = []) -> [Option] {
        var table: [String: (name: String, running: Bool)] = [:]
        for a in installed where !a.bundle.isEmpty {
            table[a.bundle] = (a.name, false)
        }
        for a in running where !a.bundle.isEmpty {
            // 名字优先用已安装那边的(Info.plist 里更规范); 只有没扫到时才用进程名。
            let name = table[a.bundle]?.name ?? a.name
            table[a.bundle] = (name, true)
        }
        for b in keep where table[b] == nil {
            table[b] = (b, false)
        }
        return table
            .map { Option(bundle: $0.key, name: $0.value.name, running: $0.value.running) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 扫已安装的 `.app`。**纯函数**(只读磁盘、无隐藏状态) ⇒ 冒烟能用夹具目录断言。
    nonisolated static func scanInstalled(roots: [String]) -> [(bundle: String, name: String)] {
        let fm = FileManager.default
        var out: [(bundle: String, name: String)] = []
        var seen = Set<String>()
        for root in roots {
            guard let top = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in top {
                let path = root + "/" + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if entry.hasSuffix(".app") {
                    addAPP(path, &out, &seen)
                    continue
                }
                // 厂商目录: 只往下探**一层**。递归整棵树会扫到 helper / framework 里那些
                // 同名的小 .app(它们也是 .app, 但不是用户能"读界面"的那个 App)。
                guard let inner = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for sub in inner where sub.hasSuffix(".app") {
                    addAPP(path + "/" + sub, &out, &seen)
                }
            }
        }
        return out
    }

    private nonisolated static func addAPP(_ path: String,
                               _ out: inout [(bundle: String, name: String)],
                               _ seen: inout Set<String>) {
        guard let b = Bundle(path: path), let id = b.bundleIdentifier, !id.isEmpty,
              !seen.contains(id) else { return }
        // ⚠️ 走 `object(forInfoDictionaryKey:)` 而不是 `infoDictionary` 直读: 前者会顺着
        //    `.lproj` 取**本地化**过的名字, 后者拿到的是原始串(常常是英文名)。
        let name = b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? b.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        seen.insert(id)
        out.append((id, name))
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
                 imageRaw: String? = nil) {
        let d = Self.decode(enabledRaw: enabledRaw, bundlesRaw: bundlesRaw,
                            actRaw: actRaw, imageRaw: imageRaw)
        enabled = d.enabled
        // ⚠️ 顺序有意义: 先置两档子集再置 `selected` —— 反过来的话中间那一拍会出现
        //    "子集里有、读面里没有"的短暂状态, 而 `didSet` 会把它 persist 出去。
        actSelected = d.actBundles
        imageSelected = d.imageBundles
        selected = d.bundles
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
    /// **两段式**是有意的: 先只取运行态(毫秒级, 立刻上屏), 再后台扫已安装的 App(几百个包,
    /// 几十到几百毫秒)洗完再换一版。否则点开设置要**卡一下**才出现任何东西 —— 而这一栏
    /// 的主入口就在输入框那一行, 会被点得很频繁。
    func refresh() {
        let me = Bundle.main.bundleIdentifier
        let running = Self.runningApps(excluding: me)
        options = Self.merge(installed: installed, running: running, keep: selected)

        let roots = Self.appRoots(home: NSHomeDirectory())
        // ⚠️ `[weak self]` 只挂在 `MainActor.run` 那一层: 挂到外层再在里层 `guard let self`
        //    会报 "reference to captured var 'self' in concurrently-executing code"
        //    (Swift 6 里是 error)。外层只捕获 `roots` / `running` 两个值, 不需要 self。
        Task.detached(priority: .utility) {
            let found = Self.scanInstalled(roots: roots)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.installed = found
                self.options = Self.merge(installed: found, running: running, keep: self.selected)
            }
        }
    }

    private func persist() {
        guard let onPersist else { return }
        let e = Self.encode(enabled: enabled, bundles: selected,
                            actBundles: actSelected, imageBundles: imageSelected)
        onPersist(Self.enabledKey, e.enabled)
        onPersist(Self.bundlesKey, e.bundles)
        onPersist(Self.actBundlesKey, e.actBundles)
        onPersist(Self.imageBundlesKey, e.imageBundles)
    }
}
