//
//  ShareCardText.swift
//  分享用的卡片 —— 正文 + 底部一行出处。
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
    /// 这一轮的网页产物（2026-11-26）; nil = 不画那一块。
    var htmlPreview: ShareHtmlPreview? = nil

    /// 分享图里那块「网页预览」。
    ///
    /// 两种形态，由**高度预算**决定（判据在 `MessageImageShare.png`）：
    /// - 有图：标题行 + 首屏截图（`Tune.shareHtmlPreviewHeight`）
    /// - 没图：一行文件名条（`Tune.shareHtmlBarHeight`）—— 正文太长、放不下图时的降级。
    ///   降级**不是失败**：图上至少写清"这一轮带了个网页、叫什么名字"，比整张图不出强。
    struct ShareHtmlPreview {
        let name: String
        /// nil = 降级成条（快照失败 / 高度不够）。
        /// `var`：高度预算不够时 `MessageImageShare.png` 会把它置 nil 再排一次。
        var snapshot: NSImage?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownView(text: text, basePath: basePath)
                .padding(.horizontal, Tune.sharePadding)
                .padding(.top, Tune.sharePadding)
            // 位置与对话区一致：**正文之后、落款之前**（正文讲"做了什么"，这块就是那件事本身）。
            if let htmlPreview {
                htmlPreviewBlock(htmlPreview)
                    .padding(.horizontal, Tune.sharePadding)
                    .padding(.top, 16)
            }
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

    // MARK: - 网页预览块

    @ViewBuilder
    private func htmlPreviewBlock(_ p: ShareHtmlPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行两种形态共用 —— 降级时它就是**全部**内容。
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                Text(verbatim: p.name)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if p.snapshot == nil {
                    // 说明"为什么只有一条" —— 不然读者会以为是图裂了。
                    Text(L("正文太长 · 网页未出图"))
                        .font(.system(size: 10))
                        .foregroundStyle(CodexTheme.textMuted)
                }
            }
            if let img = p.snapshot {
                // ⚠️ 高度必须由**这块空色**决定，图只做 overlay —— `Image.resizable().aspectRatio(.fill)`
                //    参与高度计算时实测只报 626（该 640 的地方），差的那 14pt 会被 `clipped` 吃掉：
                //    分享图上表现为"首屏底部被切掉一条"，而没有任何报错。
                Color.clear
                    .frame(height: Tune.shareHtmlPreviewHeight)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CodexTheme.divider, lineWidth: 1)
                    )
            }
        }
        // 降级形态的高度必须**确定**（渲染前要拿它算预算，见 `MessageImageShare.png`）。
        .frame(height: p.snapshot == nil ? Tune.shareHtmlBarHeight : nil, alignment: .topLeading)
    }
}
