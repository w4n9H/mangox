//
//  CaseImageShare.swift
//  分享图片的剪贴板双格式（2026-11-04 评审）。
//
//  病根：`declareTypes([.png, .tiff])` 之后用 `pngOK || tiffOK` 合并结果。
//    PNG 一旦成功，右侧短路不执行 ⇒ 声明了 TIFF 却没有数据，
//    只认 TIFF 的老 IM 拿到空图，而这里**一个错误都不会报**。
//
//  ⚠️ 端到端读 `.tiff` **抓不到它**：NSPasteboard 会按需把 PNG 合成 TIFF。
//    所以真正的判据是策略级 —— 两个 writer 都必须被调用；把 `||` 改回去第二条立刻红。
//

import Foundation
import AppKit
import CoreGraphics

extension SmokeMain {
    @MainActor
    static func caseImageShare() async {
        print("== T-ISHARE 分享图片的剪贴板双格式 ==")

        guard let ctx = CGContext(data: nil, width: 2, height: 2,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else {
            check(false, "T-ISHARE 夹具: 生成 2×2 PNG 失败")
            return
        }

        // ① 策略级：两个 writer 都必须被调用。
        //    ⚠️ 不能用 `pb.data(forType: .tiff)` 判 —— 剪贴板会按需把 PNG 合成 TIFF，
        //    旧 `||` 写法下那条端到端断言**是绿的**（2026-11-04 反例实测）。
        var pngWrites = 0
        var tiffWrites = 0
        let wrote = MessageImageShare.writeBothFormats(
            png: png,
            writePNG: { _ in pngWrites += 1; return true },
            writeTIFF: { _ in tiffWrites += 1; return true })
        check(wrote && pngWrites == 1,
              "T-ISHARE PNG writer 被调用一次 (实测 \(pngWrites))")
        check(tiffWrites == 1,
              "T-ISHARE 即使 PNG 已成功, TIFF writer 也必须被调用 (实测 \(tiffWrites); `||` 短路会让它变 0)")

        // ② 反例：PNG 写失败时仍要尝试 TIFF，且整体以 TIFF 成功为准。
        var fallbackTIFF = 0
        let fallback = MessageImageShare.writeBothFormats(
            png: png,
            writePNG: { _ in false },
            writeTIFF: { _ in fallbackTIFF += 1; return true })
        check(fallback && fallbackTIFF == 1,
              "T-ISHARE PNG 失败时仍写 TIFF 并以它为准 (实测 writer \(fallbackTIFF))")

        // ③ 集成：真正走一遍剪贴板，两种类型都读得出来。
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        var copied = false
        do {
            try MessageImageShare.copyToPasteboard(png, to: pb)
            copied = true
        } catch {
            check(false, "T-ISHARE 写剪贴板抛错: \(error)")
        }
        guard copied else { return }

        check(pb.data(forType: .png)?.isEmpty == false,
              "T-ISHARE PNG 必须真的写进剪贴板")
        check(pb.data(forType: .tiff)?.isEmpty == false,
              "T-ISHARE 集成: 从剪贴板能读出 TIFF（⚠️ 自动转换也会绿, 真写入由上面的 writer 计数钉住）")
        check(pb.types?.contains(.png) == true && pb.types?.contains(.tiff) == true,
              "T-ISHARE 声明的两种类型都与实际数据一致 (实测 \(pb.types ?? []))")
    }
}
