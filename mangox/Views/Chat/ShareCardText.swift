//
//  ShareCardText.swift
//  P19: 分享用的卡片 —— 正文 + 底部一行出处。
//
//  为什么不是"截当前气泡": 气泡在滚动视口里 (露一半)、宽度随窗口、还带 hover 出来的工具条;
//  卡片可控宽高与留白, 分享出去才像**一张图**。
//
//  ⚠️ 图上**不加任何按钮/边框**: 静态图里的控件是死控件 (代码块自带的「换行 / 复制」在
//     `CodeBlockView` 里, 这里没法关 —— 见该文件 `initialWrap` 那条待办)。
//

import SwiftUI

struct ShareCardText: View {
    let text: String
    /// 正文里相对路径图片的解析基准 (通常 = 会话绑定的项目目录)。
    var basePath: String? = nil
    /// 底部出处 (`MangoX · 2026/10/22 08:05`); nil = 不画那一行。
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownView(text: text, basePath: basePath)
                .padding(.horizontal, Tune.sharePadding)
                .padding(.top, Tune.sharePadding)
            if let caption {
                HStack(spacing: 5) {
                    // 品牌名: 任何语言下都写 MangoX ⇒ verbatim (不查表)
                    Text(verbatim: "MangoX")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CodexTheme.textTertiary)
                    Text(verbatim: "·")
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textMuted)
                    Text(verbatim: caption)
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textMuted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Tune.sharePadding)
                .padding(.top, 14)
            }
            // 底部呼吸: 有出处行时它自己带 14 的上间距, 这里只需要一点下沿留白
            Color.clear.frame(height: Tune.sharePadding * (caption == nil ? 1 : 0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
