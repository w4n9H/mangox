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
        // 轻量行内样式: 左侧琥珀竖条 + 折叠行, 不再用整卡灰底 (Codex 风格)
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(CodexTheme.thinking.opacity(0.7))
                .frame(width: 2)
                .padding(.vertical, 3)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(CodexTheme.animFast) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CodexTheme.thinking)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                withAnimation(CodexTheme.animFast) { expanded = false }
            }
        }
    }
}
