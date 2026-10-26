//
//  ThinkingCardView.swift
//  Collapsible thinking block. **恒默认折叠** —— 进行中只在行右侧挂一枚「思考中…」;
//  展开与否完全归用户。回复结束时把展开态收回 (Codex behavior)。
//

import SwiftUI

struct ThinkingCardView: View {
    let text: String
    let id: UUID
    var isStreaming: Bool = false
    @State private var expanded: Bool

    init(text: String, id: UUID, isStreaming: Bool = false) {
        self.text = text
        self.id = id
        self.isStreaming = isStreaming
        // ⚠️ 2026-10-16 boss: "思考过程会展开, 并且流式输出, 如果高强度思考时, 体验不好"
        //    —— 思考时正文每秒都在长, 自动展开 = **强制把整段推理铺在眼前**, 真正的回答
        //    被一路顶到屏幕外。⇒ **恒默认折叠**;"它还在想"改由右侧那枚「思考中…」承担,
        //    要看内容自己点开 (展开态完全归用户, 不再被 isStreaming 抢)。
        _expanded = State(initialValue: false)
    }

    var body: some View {
        // 轻量行内样式: 左侧**中性**竖条 + 折叠行, 不用整卡灰底 (Codex 风格)。
        // 竖条曾是琥珀 @0.7（亮色 2.31:1, 太响）—— 2026-10-21 起与工具行同色: 颜色只给状态,
        // 类别一律中性（见 `CodexTheme.railNeutral`）。这里"在思考"由右端那枚琥珀字承担。
        //
        // ⚠️ 竖条走 `overlay`、**不参与尺寸计算** —— 与 `ToolCallCardView` 同一个理由：
        //    形状高度没有内在值 ⇒ 只要外层递来一个**确定高度**，它就把这一行撑成那个高度，
        //    文字顶在上面、下面一大片空白（2026-10-26 工具卡实测踩过，这里是同一个写法，
        //    只是思考卡没有嵌套、还没被暴露）。
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(CodexTheme.animFast) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        // 可点控件 ⇒ 守图形元素 3:1（亮 3.21），所以**不跟竖条**降到 1.46
                        .foregroundStyle(CodexTheme.textMuted)
                        .frame(width: 12)
                    Text("思考过程")
                        .font(CodexTheme.fontSmall)
                        .foregroundStyle(CodexTheme.textTertiary)
                    Spacer()
                    // 进行中: 右侧一枚状态字 (复用既有词条 `思考中…` —— 迷你条 L2 摘要同款)。
                    // 用琥珀而不是中性灰: P16 定的分工是"工具行冷蓝, **琥珀垄断给思考**",
                    // 这里正是"思考", 就该用它。
                    if isStreaming {
                        Text("思考中…")
                            .font(CodexTheme.fontTiny)
                            .foregroundStyle(CodexTheme.thinking)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textTertiary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)   // 给竖条留出 2pt 的位置（原来由 HStack 自然占位）
        .overlay(alignment: .topLeading) {
            // 与 `ToolCallCardView` 同色同透明度：两边都是中性装饰，再分就是无缘无故的差别。
            Rectangle()
                .fill(CodexTheme.railNeutral)
                .frame(width: 2)
                .padding(.vertical, 3)
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                withAnimation(CodexTheme.animFast) { expanded = false }
            }
        }
    }
}
