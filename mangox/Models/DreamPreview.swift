//
//  DreamPreview.swift
//  P15.9 定向 dream（`由此 Dream`）—— 点击之后、fire 之前给用户看的那一屏。
//

import Foundation

/// 「由此 Dream」的二次确认数据。**只装事实**, 不做任何判断：
/// 字数 / 回合数 / 归属根 / 预算都是查出来的，弹窗只负责把它们摆出来。
///
/// 为什么要这一屏（boss 2026-10-21 拍板）: 这是 dream 里**最贵的一次调用**（256k 预算），
/// 而且它和每日那轮不同 —— 用户点的那一刻就该知道"要送多少、归到哪、会不会被裁"。
struct DreamPreview: Identifiable, Equatable {
    /// 目标会话
    let id: UUID
    let title: String
    /// 正文规模 = `sessionMaterial` 拼出来的长度（与真正喂进去的字数**同源**，见
    /// `PersistenceStore.dreamMaterialStats` 的口径说明）。
    let materialChars: Int
    /// 用户回合数（不是消息条数 —— 说"40 个回合"才像一场对话）
    let turns: Int
    /// 正文行数（含助手/系统消息）
    let lines: Int
    /// 这一场会归到哪个笔记根 —— dream 唯一的落点，点之前就该看见（P15.8 的归属判据）
    let rootLabel: String
    /// 定向预算（`Tune.dreamTargetedMaxChars`）
    let budget: Int

    /// 能不能提炼。空 = 只有工具输出（`sessionMaterial` 只认 text）
    var isEmpty: Bool { materialChars == 0 }

    /// 会不会被裁 —— 弹窗据此亮那行琥珀提示。
    /// ⚠️ 按**字符**估的；真裁法是"按回合整对丢"，所以**丢了几个回合**只有跑完之后
    /// 摘录段尾那句点名才是准的（这里不假称精确）。
    var willTruncate: Bool { materialChars > budget }

    /// 预算占用（0…1），给弹窗那条细进度条。
    var budgetRatio: Double {
        guard budget > 0 else { return 0 }
        return min(1, Double(materialChars) / Double(budget))
    }
}
