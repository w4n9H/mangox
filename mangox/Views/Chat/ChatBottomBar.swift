//
//  ChatBottomBar.swift
//  P5.0.3: 底部输入区共享组件 (横幅 + ChatComposer)。
//  Chat 与轨迹两个底档共用 — 切轨迹模式后仍能继续输入 (用户反馈补齐)。
//

import SwiftUI

struct ChatBottomBar: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        if store.engineMissing || store.engineDiagnosis != nil {
            engineIssueBanner
        }
        if let outcome = store.distillOutcome {
            noticeBanner(outcome,
                         clear: { store.distillOutcome = nil },
                         actionTitle: outcome.isError ? nil : L("去审核"),
                         action: outcome.isError ? nil : { store.openKnowledgePanel() })
        }
        if let notice = store.turnLimitNotice {
            noticeBanner(notice, clear: { store.turnLimitNotice = nil })
        }
        if let notice = store.extensionNotice {
            noticeBanner(notice, clear: { store.extensionNotice = nil })
        }
        ChatComposer(store: store)
    }

    /// 引擎不可用 / 起不来的横幅: Release 不静默降级 Mock, 缺引擎必须可见。
    /// P12.1c: 从一句"请装 pi"升级为**自查报告** —— README 把装 pi 定为用户义务,
    /// 那 App 就得让用户能自己定位问题 (找过哪些路径 / 引擎 stderr 说了什么)。
    /// 常驻 (非 8s 自清): 两种情形都不会自己好, 消失只会让用户以为修好了。
    private var engineIssueBanner: some View {
        let title = store.engineMissing
            ? L("未找到 pi CLI, Agent 引擎不可用。请安装 pi 后重启 MangoX。")
            : L("Agent 引擎启动失败。")
        // engineDiagnosis 由 transport 拼好 (退出码 + stderr 尾部 + 路径清单);
        // 只有"根本没找到 pi"时才现算路径清单 (那时不会有 diagnosis)。
        let detail = store.engineDiagnosis ?? PiRpcTransport.binarySearchReport()
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.toolRunning)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.textPrimary)
                Text(detail)
                    .font(CodexTheme.fontMonoSm)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .textSelection(.enabled)   // 允许复制去搜索/贴 issue
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tune.chatHPadding)
        .padding(.vertical, 8)
        .background(CodexTheme.toolRunning.opacity(0.10))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .bottom
        )
    }

    /// 通知横幅 (8s 自清, 提炼结果/并发超限共用; 可带一个动作按钮)。
    private func noticeBanner(_ outcome: (text: String, isError: Bool),
                              clear: @escaping () -> Void,
                              actionTitle: String? = nil,
                              action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: outcome.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(outcome.isError ? CodexTheme.toolError : CodexTheme.toolDone)
            Text(outcome.text)
                .font(CodexTheme.fontSmall)
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle) { action() }
                    .buttonStyle(.plain)
                    .font(CodexTheme.fontSmall)
                    .foregroundStyle(CodexTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .help(LK(actionTitle == "去审核" ? "打开知识面板的待审核分组" : ""))
            }
            Button {
                clear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
        .padding(.horizontal, Tune.chatHPadding)
        .padding(.vertical, 7)
        .background((outcome.isError ? CodexTheme.toolError : CodexTheme.accent).opacity(0.10))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(CodexTheme.divider),
            alignment: .bottom
        )
    }
}
