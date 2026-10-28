//
//  ComputerSettings.swift
//  P18: computer use 的**开关与作用域** —— 批 1 只做"能真机手验"的那一小块。
//
//  ⚠️ 为什么批 1 就得有个开关: 链路全通但作用域恒空 ⇒ 谁也没法真用它一次。
//     一条从没被真机验证过的链路上去翻审批闸门(批 2a), 出问题分不清是闸门还是链路。
//
//  ⚠️ **作用域是"这一轮才存在的凭证", 不是"本机偏好"**: 它每次 spawn 重新读,
//     关掉开关 ⇒ 下一轮 spawn 不再给 env ⇒ 扩展根本不挂。不存在"关了但还生效"的窗口。
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

    // MARK: 状态

    /// 总开关。**默认关** —— 批 1 阶段没有作用域 UI 之前默认开 = 悄悄开一个面。
    @Published var enabled: Bool = false { didSet { persist() } }

    /// 勾上的 bundle id。
    @Published private(set) var selected: Set<String> = [] { didSet { persist() } }

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

    /// 本轮真正下发的作用域。
    ///
    /// ⚠️ **排序后**返回: 下发顺序稳定 ⇒ 同样的勾选每次拼出同样的 env 串 ⇒ 可断言、可肉眼看 diff。
    ///    `Set` 的迭代顺序不稳定(且与插入顺序无关), 直接下发会让"改了什么"看不出来。
    var activeBundles: [String] {
        guard enabled else { return [] }
        return selected.sorted()
    }

    /// 落盘串 → 状态。**乱值一律按"关/空"算**, 不猜。
    ///
    /// ⚠️ 单独抽出来是因为它既要被 `ChatStore` 在启动时调, 也要能被冒烟断言 ——
    ///    写进 `restore` 里就成了"只有真启动才验得到"的逻辑。
    static func decode(enabledRaw: String?, bundlesRaw: String?) -> (enabled: Bool, bundles: Set<String>) {
        let enabled = enabledRaw == "1"
        guard enabled else { return (false, []) }
        let bundles = Set((bundlesRaw ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
        return (true, bundles)
    }

    /// 状态 → 落盘串。
    static func encode(enabled: Bool, bundles: Set<String>) -> (enabled: String, bundles: String) {
        (enabled ? "1" : "0", bundles.sorted().joined(separator: ","))
    }

    // MARK: 操作

    func restore(enabledRaw: String?, bundlesRaw: String?) {
        let d = Self.decode(enabledRaw: enabledRaw, bundlesRaw: bundlesRaw)
        enabled = d.enabled
        selected = d.bundles
    }

    func setSelected(_ bundles: Set<String>) { selected = bundles }

    func toggle(_ bundle: String) {
        if selected.contains(bundle) { selected.remove(bundle) } else { selected.insert(bundle) }
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
        let e = Self.encode(enabled: enabled, bundles: selected)
        onPersist(Self.enabledKey, e.enabled)
        onPersist(Self.bundlesKey, e.bundles)
    }
}
