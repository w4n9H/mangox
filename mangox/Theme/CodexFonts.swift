//
//  CodexFonts.swift
//  Runtime font resolution:
//  1. Berkeley Mono / Söhne — commercial, used when user has them installed
//  2. JetBrains Mono — bundled (SIL OFL 1.1, see Resources/Fonts/OFL.txt), registered at launch
//  3. SF system fallback — fully self-contained
//
//  注意: 只对真实字体名用 Font.custom (打包/已装字体), 私有名 (.SF Mono 等) 在
//  Font.custom 下走降级渲染路径字形发虚 (T3 验收结论), fallback 必须走系统语义字体。
//

import SwiftUI
import AppKit

enum CodexFonts {
    /// "Söhne" (commercial) → "Inter" / "SF Pro Text" (system) fallback
    static let uiName: String   = pick(["Söhne", "Sohne", "Inter", "SF Pro Text", ".AppleSystemUIFont"])
    /// "Berkeley Mono" (commercial) → bundled JetBrains Mono → SF Mono fallback
    static let monoName: String = pick(["Berkeley Mono", "JetBrains Mono", "SF Mono", ".SF Mono"])

    /// mono 字体是否可用 Font.custom (真实打包/已装字体; 私有系统名除外)
    static var monoIsCustom: Bool { monoName != ".AppleSystemUIFont" }

    /// 打包字体的进程级注册 (Xcode 16 同步组自动打包 ttf; Info.plist 免配置)
    private static let registerBundled: Void = {
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-Medium",
                     "JetBrainsMono-Italic", "JetBrainsMono-Bold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf"),
                  let data = try? Data(contentsOf: url),
                  let provider = CGDataProvider(data: data as CFData),
                  let cgFont = CGFont(provider) else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterGraphicsFont(cgFont, &error)
        }
    }()

    private static func pick(_ candidates: [String]) -> String {
        _ = registerBundled   // 先注册打包字体, pick 才能看到 JetBrains Mono
        for name in candidates {
            if NSFont(name: name, size: 13) != nil { return name }
        }
        return ".AppleSystemUIFont"
    }

    /// mono 语义字体: 真实字体走 custom, 私有系统名走 system monospaced (防降级渲染发虚)
    static func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        monoIsCustom ? Font.custom(monoName, size: size).weight(weight)
                     : Font.system(size: size, design: .monospaced).weight(weight)
    }
}
