//
//  RailParticles.swift
//  思考强度轨上的颗粒层（2026-10-20 boss 拍板 ④：方圆混搭 + 竖线刻度）。
//
//  为什么是这几条（都是出图对比出来的，别凭直觉改回去）:
//    ① **形状按尺寸分派**（≥4pt 方 / ≤3pt 圆），不是随机混。大颗粒是视觉焦点, 用方形与
//       刻度打开形状差; 2–3pt 上方圆肉眼本就一样, 用圆的更柔 ⇒ 整体是"星尘"而非像素点阵。
//    ② **颗粒铺满整条、按已达成段裁切**（在调用侧 mask）。若按已达成段铺, 拖动档位时
//       整片颗粒会随 x 重排 ⇒ 手指在拖、背景在抖。铺满后拖动只是"逐步露出来"。
//    ③ **位置由固定种子确定性生成**。用 `Double.random` 的话每次 body 重算都会重排,
//       拖动档位时颗粒会乱跳（与"点 A 开 B"同族的不稳定 id 问题）。
//    ④ **动画交给 Core Animation**（`.repeatForever`）, 不用 TimelineView 逐帧 ——
//       见 `CodexControls.swift:340`: 逐帧驱动在流式期主线程拥堵时会掉帧。
//

import SwiftUI

struct RailParticles: View {
    /// 轨的全宽。颗粒铺在 `10 … width-10` 上。
    let width: CGFloat
    /// 轨道竖直中线（= 把手半径）。
    let midY: CGFloat
    /// 固定种子 —— 同一档位每次重绘必须是同一张图。
    var seed: UInt64 = 0x5EED_1CE

    private let count = 22
    private let sizes: [CGFloat] = [2, 3, 4, 6]
    /// 颗粒中心的横向留白（避开胶囊两端的圆角）。
    private let margin: CGFloat = 10
    /// 纵向散布半幅。轨道净高 20pt、最大颗粒 6pt ⇒ ±5.5 不会出界。
    private let spreadY: CGFloat = 11

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(items) { item in
                Grain(item: item)
            }
        }
        // 纯装饰: 不许截走拖拽手势（轨道整体的 DragGesture 在调用侧）。
        .allowsHitTesting(false)
    }

    private var items: [GrainItem] {
        var rng = LCG(seed: seed)
        let inner = max(width - margin * 2, 1)
        return (0..<count).map { i in
            let ux = rng.next(), uy = rng.next(), us = rng.next(), uo = rng.next()
            return GrainItem(
                index: i,
                size: sizes[Int(us * Double(sizes.count)) % sizes.count],
                x: margin + CGFloat(ux) * inner,
                y: midY + (CGFloat(uy) - 0.5) * spreadY,
                // 0.22…0.84: 低于 0.22 在亮色底上就看不见了, 高于 0.84 会抢把手。
                opacity: 0.22 + uo * 0.62,
                duration: 2.6 + ux * 2.4,
                delay: uy * 1.4,
                driftX: 1.5 + uo * 2.0,
                driftY: 0.8 + us * 1.2
            )
        }
    }
}

/// 一颗颗粒的全部参数（值类型, 每次重算得到的是**同一批数值**）。
private struct GrainItem: Identifiable {
    let index: Int
    let size: CGFloat
    let x: CGFloat
    let y: CGFloat
    let opacity: Double
    let duration: Double
    let delay: Double
    let driftX: CGFloat
    let driftY: CGFloat
    var id: Int { index }
    /// 方形/圆形分界: 4pt 起才看得出来, 3pt 以下画方画圆都一样。
    var isSquare: Bool { size >= 4 }
}

private struct Grain: View {
    let item: GrainItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var away = false

    var body: some View {
        Group {
            if item.isSquare {
                Rectangle().fill(Color.white.opacity(item.opacity))
                    .frame(width: item.size, height: item.size)
            } else {
                Circle().fill(Color.white.opacity(item.opacity))
                    .frame(width: item.size, height: item.size)
            }
        }
        .position(x: item.x, y: item.y)
        .offset(x: away ? item.driftX : -item.driftX,
                y: away ? item.driftY : -item.driftY)
        .opacity(away ? 1 : 0.55)
        // ⚠️ `.animation(value:)` 而非 TimelineView: 动画由渲染服务端跑, 主线程不再逐帧重算。
        .animation(reduceMotion ? nil : .easeInOut(duration: item.duration)
            .repeatForever(autoreverses: true)
            .delay(item.delay), value: away)
        .onAppear {
            // 「减少动态效果」下只画静态颗粒: 不启动就不需要 later 再停。
            if !reduceMotion { away = true }
        }
    }
}

/// 确定性伪随机（与出图 harness 同一个式子, 图上看到的就是源码跑出来的分布）。
private struct LCG {
    private var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double((s >> 33) % 100_000) / 100_000.0
    }
}
