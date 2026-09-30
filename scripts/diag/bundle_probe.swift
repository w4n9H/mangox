//
//  bundle_probe.swift
//  MangoX 资源可达性探针 (由 scripts/diag/resource-gate.sh 调用)。
//
//  为什么需要它: CLI 打包是**手工排资源**的 (Xcode 的 PBXFileSystemSynchronizedRootGroup
//  没有文件列表可抄), 而 App 运行期查资源全靠 Bundle.main 的三条查法。这三条查法都会
// 静默回落, 打包错了界面照样起来, 只是字形/语言/模型目录悄悄换掉了:
//
//    ModelCatalog  → Bundle.main.url(forResource:"model-catalog", withExtension:"json")
//                    miss → 退回裸默认模型表 (设置页列不出线上模型)
//    CodexFonts    → Bundle.main.url(forResource:"JetBrainsMono-Regular", withExtension:"ttf")
//                    miss → pick() 落到 SF Mono 档, 界面照跑只是字形变了 (最难归因的一类)
//    AppLanguage   → Bundle.main.path(forResource:"<lang>", ofType:"lproj")
//                    miss → L() 回落 key 本身 (= 中文原文), 英文界面出中英混排
//
//  尤其: Bundle.url(forResource:withExtension:) 在 macOS 上**不递归子目录** (2026-09
//  实测)。所以"字体放 Resources/Fonts/ 下"这种看起来没毛病的摆法, 查出来就是 nil。
//  本探针负责证明编出来的 bundle 里资源真的处在代码期待的那个摆法。
//
//  用法 (一般由 scripts/diag/resource-gate.sh 调用, 它负责现推期望清单):
//    swiftc -o /tmp/bundle_probe bundle_probe.swift
//    /tmp/bundle_probe <path/to/mangox.app> [<期望资源名>...]
//  期望资源名支持两种形态 (可以一个都不给 —— 那就只自检 Info.plist 读得到):
//    Foo.ttf / model-catalog.json / AppIcon.icns   → 按 basename 查 (url(forResource:))
//    en.lproj / zh-Hans.lproj                      → 按 lproj 目录查 (path(forResource:))
//
//  通过条件: 全部命中且退出码 0; 任何一条 miss 打印 MISS 行并退出码 1 (阻断打包)。
//  反例自证: ./bundle_probe <某个不是 bundle 的目录> foo.json → 必红, 判据确实会响。
//

import Foundation

/// 期望资源名 → 判据。返回 nil 表示命中。
func missReason(for expectation: String, in bundle: Bundle) -> String? {
    if expectation.hasSuffix(".lproj") {
        let lang = String(expectation.dropLast(".lproj".count))
        guard bundle.path(forResource: lang, ofType: "lproj") != nil else {
            return "\(lang).lproj 不在 Contents/Resources 根 —— Bundle.path(forResource:ofType:\"lproj\") 查不到, L() 会回落成 key 本身"
        }
        return nil
    }
    let ext = (expectation as NSString).pathExtension
    let name = (expectation as NSString).deletingPathExtension
    guard bundle.url(forResource: name, withExtension: ext.isEmpty ? nil : ext) != nil else {
        var hint = "\(expectation) 查不到 —— Bundle.url(forResource:) 在 macOS 上不递归子目录, 资源必须平铺在 Contents/Resources 根"
        if ext == "ttf" { hint += "; 字体 miss 会静默回落 SF Mono, 界面照跑" }
        return hint
    }
    return nil
}

let args = Array(CommandLine.arguments.dropFirst())
// 期望资源名是可选的: 资源数为 0 时调用方会只传 bundle 路径 (bash 3.2 下
// set -u 安全的空数组展开给不出参数), 这时退化成"只自检 Info.plist 读得到"
guard let bundlePath = args.first, let bundle = Bundle(path: bundlePath) else {
    FileHandle.standardError.write("用法: bundle_probe <bundle 路径> [期望资源名...]\n".data(using: .utf8)!)
    exit(2)
}
let expectations = Array(args.dropFirst())

// 两类失败分开记: Info.plist 自检失败不该混进"资源命中"的分母/分子, 否则期望数为 0 时
// 会打出 "-1/0 命中" 这种读不懂的行
var plistOK = true
var resourceMisses = 0

// 探针自检: Info.plist 必须读得到 (bundleIdentifier) —— 否则下面的资源判据全是空转
if let ident = bundle.bundleIdentifier {
    print("  bundle  : \(ident) \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
} else {
    print("  bundle  : <CFBundleIdentifier 读不到>")
    plistOK = false
}

for item in expectations {
    if let why = missReason(for: item, in: bundle) {
        print("  MISS    : \(item) — \(why)")
        resourceMisses += 1
    } else {
        print("  OK      : \(item)")
    }
}

let hit = expectations.count - resourceMisses
if resourceMisses == 0 {
    print("  资源可达: \(hit)/\(expectations.count) 命中")
} else {
    print("  资源可达: \(hit)/\(expectations.count) 命中 (\(resourceMisses) 条 miss)")
}
exit(plistOK && resourceMisses == 0 ? 0 : 1)
