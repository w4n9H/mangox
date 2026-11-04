//
//  CaseImageDecode.swift
//  图片两条通路（原图 / 缩略）与分享图的提前拒（2026-11-04，D 批）。
//
//  病根 A：88×66 的缩略槽位也走 `cachedImage`（原图）⇒ 一张整屏截图每次重绘都从全尺寸位图
//    重采样。判据不能是"看起来清不清楚"（都清楚），只能是**解出来的像素尺寸**：
//    缩略通路长边必须真的被压到目标，原图通路必须真的是原图像素。
//
//  ⚠️ 原图通路**不能**跟着降采样：正文图按原图像素定宽（`naturalCap`），而说明行
//    `文件名 · 宽×高` 读的就是 `rep.pixelsWide` —— 降了就**说谎**。这条在本文件用
//    "400 宽的原图，缩略 50 之后原图通路仍是 400"钉住。
//
//  病根 B：分享出图前那趟排版（4 拍 RunLoop + 两趟布局，实测 180~460ms，超长正文能到秒级）
//    无论多长都先跑完，才判"太长不出图"。判据只能是**下界性质**：算出的高度下界若已超过上限，
//    真排版只会更高 ⇒ 提前拒不可能误拒。
//

import AppKit
import CoreGraphics
import Foundation

extension SmokeMain {
    @MainActor
    static func caseImageDecode() async {
        print("== T-IMG 图片两条通路 / 分享提前拒 ==")

        // ── 夹具：一张 400×200 的真 PNG ─────────────────────────
        let dir = fixtureDir("timg")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/big.png"
        guard let ctx = CGContext(data: nil, width: 400, height: 200,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else {
            check(false, "T-IMG 夹具: 生成 400×200 PNG 失败")
            return
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            check(false, "T-IMG 夹具写盘失败: \(error)")
            return
        }

        // ── 原图通路：像素必须是原图像素 ────────────────────────
        // ⚠️ 尺寸一律读 `ImagePresentation.pixelSize`（走 `cgImage(forProposedRect:)`），
        //    **不许读 `rep.pixelsWide`** —— `NSImage(cgImage:size:)` 造出来的快照 rep 会把屏幕
        //    缩放算进去：同一张 50×25 的位图在 2x 屏上报 100×50（2026-11-04 实测，这条判据
        //    第一版就是因为读它才红的）。
        guard let full = ImagePipeline.cachedImage(atPath: path) else {
            check(false, "T-IMG 原图通路读不出刚写的 PNG")
            return
        }
        let fullPx = ImagePresentation.pixelSize(of: full)
        check(fullPx.w == 400 && fullPx.h == 200,
              "T-IMG 原图通路拿到 400×200 (实测 \(fullPx.w)×\(fullPx.h))")

        // ── 缩略通路：长边真的被压到目标 ────────────────────────
        guard let thumb = ImagePipeline.cachedThumbnail(atPath: path, maxPixels: 50) else {
            check(false, "T-IMG 缩略通路读不出同一张 PNG")
            return
        }
        let tPx = ImagePresentation.pixelSize(of: thumb)
        check(max(tPx.w, tPx.h) == 50,
              "T-IMG 缩略长边压到 50px, 比例不变 (实测 \(tPx.w)×\(tPx.h))")
        check(tPx.w == 50 && tPx.h == 25,
              "T-IMG 缩略保持 2:1 比例 (实测 \(tPx.w)×\(tPx.h))")

        // ── 两条通路互不覆盖 ───────────────────────────────────
        // ⚠️ 这条是本批的核心回归门：一旦有人图省事把原图通路也改成缩略，
        //    "说明行里的宽高"就会变成缩略图的宽高，而画面看着**完全正常**。
        let fullAgain = ImagePipeline.cachedImage(atPath: path)
        check(ImagePresentation.pixelSize(of: fullAgain ?? NSImage()).w == 400,
              "T-IMG 缩略写入后原图通路仍是 400 (缩略不许顶掉原图)")

        // ── 缓存命中：同一路径同一目标尺寸 = 同一个对象 ──────────
        let thumbAgain = ImagePipeline.cachedThumbnail(atPath: path, maxPixels: 50)
        check(thumbAgain === thumb, "T-IMG 第二次取缩略走缓存 (返回同一实例)")

        // 不同目标尺寸各有自己一份 ⇒ 88pt 与 84pt 两处不会互相顶掉。
        let thumb400 = ImagePipeline.cachedThumbnail(atPath: path, maxPixels: 400)
        check(thumb400 !== thumb && ImagePresentation.pixelSize(of: thumb400 ?? NSImage()).w == 400,
              "T-IMG 目标像素是缓存键的一部分 (50 与 400 各存一份)")
        // 目标大于原图时**不放大**，返回原尺寸。
        let thumb999 = ImagePipeline.cachedThumbnail(atPath: path, maxPixels: 999)
        check(ImagePresentation.pixelSize(of: thumb999 ?? NSImage()).w == 400,
              "T-IMG 目标大于原图时不放大, 仍是 400 (实测 \(ImagePresentation.pixelSize(of: thumb999 ?? NSImage()).w))")

        // ── 说明行的口径：点 ≠ 像素时也必须报**像素** ───────────
        // ⚠️ 上面那轮红就是这条的现场版：`rep.pixelsWide` 在 2x 屏上翻倍。
        //    这里用"声明 24pt、位图 50px"的图把口径钉死（点与像素**故意不等**）。
        if let cgThumb = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let declaredPoints = NSImage(cgImage: cgThumb, size: NSSize(width: 24, height: 12))
            let px = ImagePresentation.pixelSize(of: declaredPoints)
            check(px.w == 50 && px.h == 25,
                  "T-IMG 说明行读真像素, 不随声明点数/屏幕缩放变 (实测 \(px.w)×\(px.h))")
            check(ImagePresentation.caption("/x/thumb.png", declaredPoints) == "thumb.png · 50×25",
                  "T-IMG 说明行 = 文件名 · 真像素 (实测 \(ImagePresentation.caption("/x/thumb.png", declaredPoints)))")
        } else {
            check(false, "T-IMG 夹具: 从缩略图取不回 CGImage")
        }

        // ── 坏输入 ─────────────────────────────────────────────
        check(ImagePipeline.cachedThumbnail(atPath: path, maxPixels: 0) == nil,
              "T-IMG maxPixels = 0 直接返回 nil (不拿原图凑数)")
        check(ImagePipeline.downsampled(atPath: dir + "/nope.png", maxPixels: 50) == nil,
              "T-IMG 不存在的路径返回 nil, 不抛不崩")
        let notImage = dir + "/plain.txt"
        try? "not an image".write(toFile: notImage, atomically: true, encoding: .utf8)
        check(ImagePipeline.downsampled(atPath: notImage, maxPixels: 50) == nil,
              "T-IMG 非图片文件返回 nil (不是空图)")

        // ── 分享：高度下界的算术 ───────────────────────────────
        // 下界 = ceil(字符数 / 每行字符上界) × 行高下界。720pt 宽 / 2.8pt 每字 = 257.14 字符每行。
        check(MessageImageShare.lowerBoundHeight("") == 0, "T-IMG 空文本高度下界 = 0")
        check(MessageImageShare.lowerBoundHeight(String(repeating: "x", count: 257)) == 11,
              "T-IMG 257 字符 = 1 行 (实测 \(MessageImageShare.lowerBoundHeight(String(repeating: "x", count: 257))))")
        check(MessageImageShare.lowerBoundHeight(String(repeating: "x", count: 258)) == 22,
              "T-IMG 258 字符 = 2 行 (每行字符上界 720/2.8)")

        // ── 分享：提前拒的两侧 ─────────────────────────────────
        // 上限 2100pt / 行高下界 11 = 190.9 行 ⇒ 191 行才越线 ⇒ 190×257+1 = 48,831 字符起步。
        let justUnder = String(repeating: "x", count: 48_800)   // 190 行 ⇒ 2090pt
        let justOver = String(repeating: "x", count: 49_100)    // 191 行 ⇒ 2101pt
        check(MessageImageShare.certainlyTooLong(justUnder) == false,
              "T-IMG 下界 2090pt 不提前拒 (还留 10pt, 真高度由排版说话)")
        check(MessageImageShare.certainlyTooLong(justOver),
              "T-IMG 下界 2101pt 提前拒 (超过上限 \(Int(Tune.shareMaxHeight))pt)")
        check(MessageImageShare.certainlyTooLong("一屏装得下的正文") == false,
              "T-IMG 普通长度不会被误拒")
        check(MessageImageShare.lowerBoundHeight(justOver)
                > MessageImageShare.lowerBoundHeight(justUnder),
              "T-IMG 下界随字符数单调增")

        // ⚠️ 这里**不**做"调 png() 看它多快抛"的端到端断言：
        //    提前拒被删掉时，它会变成"跑很久但最终照样抛 tooLong" —— 那不是红灯，是挂住。
        //    接线由 `run.sh` 的源码门守（`certainlyTooLong` 必须在 `png` 排版之前被调用）。
    }
}
