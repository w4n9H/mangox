//
//  WelcomeView.swift
//  Empty-conversation state: single mark + one question (Codex minimalism).
//

import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: Tune.welcomeStackSpacing) {
            Text(Copy.welcomeMark)
                .font(.system(size: Tune.welcomeMarkSize, weight: .medium))
                .tracking(Tune.welcomeMarkTracking)
                .foregroundStyle(CodexTheme.textTertiary)
            Text(Copy.welcomeQuestion)
                .font(.system(size: Tune.welcomeQuestionSize, weight: .medium))
                .foregroundStyle(CodexTheme.textPrimary)
        }
        // ⚠️ 2026-10-20 **这条 frame 是承重的**: ChatView 的滚动列走
        //    `VStack → GeometryReader → ScrollViewReader → ScrollView`, 在这条链里 ScrollView
        //    只拿到**内容固有宽度**(问句那点宽), 于是整块贴着内容区最左缘 —— 而下方输入卡是
        //    居中的 ⇒ 空会话页出现两条错开大半屏的轴线 (boss 报「新建会话的 ui 混乱」)。
        //    实测(真 ChatView 离屏渲染, 1023pt 宽): 少了它 = 块中心 78pt, 补上 = 511pt(正中)。
        //    ⚠️ 别拿"最小复现"验这条: 单纯的 `ScrollView { VStack { … } }` 会自己居中,
        //    只有 App 那条带 GeometryReader/ScrollViewReader 的链才暴露 ⇒ 判据必须是**真 ChatView**。
        //    姊妹视图 `ChatView.sideEmptyState` 一直带着同一条 frame, 只有这里漏了。
        .frame(maxWidth: .infinity)
    }
}
