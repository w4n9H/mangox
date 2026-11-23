//
//  AboutSection.swift
//  设置 → 关于（2026-11-23）。
//
//  版式取「身份卡 + 一行一件事」而不是一排小方卡：关于页要回答的是
//  「我装的到底是哪个版本、它依赖的东西齐不齐」，那是**一份清单**，不是仪表盘。
//  版本号全部走等宽字体并左对齐 —— 换行后仍能一眼对齐比较，这是列表最要紧的一条。
//
//  ⚠️ 这页**不吃 store**：它只读 Info.plist 和两个子进程的 `--version`。
//     保持独立是为了不让「设置页那个巨型 View 编不动」的问题传染到这里。
//

import AppKit
import SwiftUI

struct AboutSection: View {

    @State private var info: EnvironmentReport?
    @State private var copied = false

    private enum RowStatus { case ok, missing, none }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identityCard
            versionsCard
            actionRow
        }
        .task { await load() }
    }

    // MARK: - 探测

    /// ⚠️ `launchSpec()` 与 `binarySearchReport()` 都是 `@MainActor` 的（`PiRpcTransport`
    /// 整个类是），所以**主线程取值 → 后台跑子进程**。反过来做要么编不过，要么卡主线程。
    private func load() async {
        let spec = PiRpcTransport.launchSpec()
        // 找不到引擎时把"查过哪些路径"一起带上 —— 那是用户自救的唯一线索。
        let missing = spec == nil ? PiRpcTransport.binarySearchReport() : nil
        let exe = spec?.executable
        let script = spec?.scriptArgs.first
        let report = await Task.detached(priority: .utility) {
            EnvironmentProbe.make(executable: exe, piScript: script, engineReport: missing)
        }.value
        info = report
    }

    // MARK: - 身份

    private var identityCard: some View {
        HStack(spacing: 15) {
            appIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "MangoX")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                Text(info?.appVersion ?? AppVersion.display)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(CodexTheme.textSecondary)
                Text("你 Mac 上的 AI 同事")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .settingsCard()
    }

    @ViewBuilder
    private var appIcon: some View {
        // `NSApp` 在离屏预览 / 冒烟里可能没有 ⇒ 回落一个中性方块，不假装有图标。
        if let icon = NSApp?.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 56, height: 56)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(CodexTheme.bgCard)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: 22))
                        .foregroundStyle(CodexTheme.textMuted)
                )
        }
    }

    // MARK: - 清单

    private var versionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            group(L("引擎"), first: true)
            row(name: "pi", value: info?.piVersion ?? "—",
                status: info == nil ? .none : (info?.engineReady == true ? .ok : .missing))
            divider
            row(name: "Node", value: info?.nodeVersion ?? "—", status: .none)

            group(L("本机"), first: false)
            row(name: L("系统"),
                value: info.map { "macOS \($0.osVersion) · \($0.arch)" } ?? "—",
                status: .none)
            divider
            row(name: L("数据"), value: info?.dataRoot ?? "~/.mangox", status: .none)

            if let report = info?.engineReport {
                engineHint(report)
            }
        }
        .settingsCard()
    }

    /// 小节标题。**分组是为了让 `pi` / `Node` 保持英文原名** ——
    /// 把 pi 那行叫「引擎」、版本号却属于 pi，读的人对不上号。
    private func group(_ title: String, first: Bool) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(CodexTheme.textMuted)
            .padding(.top, first ? 0 : 14)
            .padding(.bottom, 3)
    }

    private var divider: some View {
        Divider().overlay(CodexTheme.divider)
    }

    /// 一行的样子：左名字（定宽）· 中值（等宽，可选中）· 右状态。
    /// 名字定宽 54 是为了**版本号左边全对齐** —— 那才是这份清单被扫读的地方。
    private func row(name: String, value: String, status: RowStatus) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11.5))
                .foregroundStyle(CodexTheme.textSecondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(status == .missing ? CodexTheme.toolRunning : CodexTheme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            statusBadge(status)
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func statusBadge(_ status: RowStatus) -> some View {
        switch status {
        case .ok:
            badge(L("可用"), color: CodexTheme.toolDone)
        case .missing:
            badge(L("未找到"), color: CodexTheme.toolRunning)
        case .none:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(color)
        }
        .fixedSize()
    }

    /// 「未找到 pi」不是错误弹窗，是一张**出路卡片**：说明它是用户自己的义务，
    /// 再把 App 查过的路径列出来（否则用户只能猜 Nix / 自定义 prefix 这些）。
    private func engineHint(_ report: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("pi 不随 App 发布 —— 需要你自己装好，App 才能发起对话。")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(report)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(CodexTheme.textMuted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(CodexTheme.bgCard)
        .cornerRadius(6)
        .padding(.top, 10)
    }

    // MARK: - 操作

    private var actionRow: some View {
        HStack(spacing: 10) {
            pill(copied ? L("已复制") : L("复制诊断信息"), filled: !copied) {
                copyDiagnostics()
            }
            pill(L("重新检测")) {
                Task { await load() }
            }
            Text("报问题时贴这段，比截图全。")
                .font(.system(size: 10.5))
                .foregroundStyle(CodexTheme.textMuted)
            Spacer(minLength: 0)
        }
    }

    private func pill(_ title: String, filled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(filled ? CodexTheme.accent : CodexTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(filled ? CodexTheme.accent.opacity(0.1) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(filled ? Color.clear : CodexTheme.border, lineWidth: 1)
                )
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copyDiagnostics() {
        guard let info else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(EnvironmentProbe.plainText(info), forType: .string)
        copied = true
        // 1.6 秒后复位。故意不用 Timer：Timer 要手动 invalidate，忘了就泄漏。
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}
