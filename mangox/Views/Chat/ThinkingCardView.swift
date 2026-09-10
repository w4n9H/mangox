//
//  ThinkingCardView.swift
//  Collapsible thinking block. Auto-collapses when the reply finishes (Codex behavior).
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
        // 流式中默认展开, 历史思考块默认折叠
        _expanded = State(initialValue: isStreaming)
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
