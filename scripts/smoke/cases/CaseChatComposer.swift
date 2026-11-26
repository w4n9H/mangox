//
//  CaseChatComposer.swift
//  输入框高度测量的接线（2026-11-04 评审）。
//
//  病根：`updateNSView` 曾经从 coordinator 的 `attachedScrollView` 取滚动视图，
//    而那个字段全仓从未赋值 ⇒ guard 恒早退。键盘输入走 `textDidChange` 另有一条路，
//    所以日常无感；`@` 插入 / 附加文件这类**外部改 draft** 之后高度就停在旧值。
//
//  现在 `updateNSView` 直接使用 SwiftUI 递进来的参数，本用例钉住真正被它调用的测量函数：
//    短文本贴 min、长文本变高、超长文本夹在 max。把夹取顺序写反（先 min 后 max）会红。
//

import Foundation
import AppKit

extension SmokeMain {
    @MainActor
    static func caseChatComposer() async {
        print("== T-CCOMP 输入框高度测量 ==")

        let minH: CGFloat = 64
        let maxH: CGFloat = 180

        let short = makeComposerScroll("一行")
        let hShort = CompactTextEditor.measuredHeight(
            scrollView: short, minHeight: minH, maxHeight: maxH)
        check(hShort == minH,
              "T-CCOMP 短文本贴住下限 (实测 \(hShort.map(String.init(describing:)) ?? "nil"))")

        let many = makeComposerScroll(Array(repeating: "一行内容", count: 20).joined(separator: "\n"))
        let hMany = CompactTextEditor.measuredHeight(
            scrollView: many, minHeight: minH, maxHeight: maxH)
        check((hMany ?? 0) > minH,
              "T-CCOMP 多行内容必须长高 (实测 \(hMany.map(String.init(describing:)) ?? "nil"))")
        check((hMany ?? 0) <= maxH,
              "T-CCOMP 多行内容不超过上限 (实测 \(hMany.map(String.init(describing:)) ?? "nil"))")

        // 单行超长靠折行变高 —— 证明量的是**排版后**的高度，不是字符数。
        let wrapped = makeComposerScroll(String(repeating: "x", count: 4_000))
        let hWrapped = CompactTextEditor.measuredHeight(
            scrollView: wrapped, minHeight: minH, maxHeight: maxH)
        check(hWrapped == maxH,
              "T-CCOMP 单行超长折到上限 (实测 \(hWrapped.map(String.init(describing:)) ?? "nil"))")

        // 没有 documentView 时明确返回 nil，不许崩、也不许编一个高度。
        let empty = NSScrollView()
        check(CompactTextEditor.measuredHeight(
                scrollView: empty, minHeight: minH, maxHeight: maxH) == nil,
              "T-CCOMP 无文本容器时返回 nil（不再强制解包 textContainer）")

        // ② 项目 pill 的数据源（2026-11-26，boss 实拍：进了项目会话，pill 仍写「选择项目」）。
        //
        // 病根是**视图绕过了兜底**：pill 自己拼 `projects.first { $0.id == selectedProjectId }`，
        // 而 `selectedProjectId` 只在"从菜单里点过"才有值 ⇒ 从侧栏点进项目会话时它是 nil。
        // 兜底（跟随选中会话的归属）一直住在 `ChatStore.activeProject` 里，`activeProjectPath`
        // 也走它 ⇒ **pi 的 cwd 一直是对的，只有那行字是错的**。
        // 现在两处共用 `resolveActiveProject` 这一个纯函数，本节钉住它的四条语义。
        let convInBetty = ConversationItem(title: "在 B 里的会话")
        let projA = ProjectGroup(title: "A 项目", path: "/tmp/a", items: [])
        let projB = ProjectGroup(title: "B 项目", path: "/tmp/b", items: [convInBetty])
        let allProjects = [projA, projB]

        let followed = ChatStore.resolveActiveProject(projects: allProjects,
                                                      selectedProjectId: nil,
                                                      selectedConversationId: convInBetty.id)
        check(followed?.id == projB.id,
              "T-CCOMP 没从菜单选过项目时, pill 必须跟随会话归属 (实测 \(followed?.title ?? "nil"))")

        let explicit = ChatStore.resolveActiveProject(projects: allProjects,
                                                      selectedProjectId: projA.id,
                                                      selectedConversationId: convInBetty.id)
        check(explicit?.id == projA.id,
              "T-CCOMP 从菜单显式选过项目时, 显式选择优先于会话归属")

        let orphan = ChatStore.resolveActiveProject(projects: allProjects,
                                                    selectedProjectId: nil,
                                                    selectedConversationId: UUID())
        check(orphan == nil,
              "T-CCOMP 会话不属于任何项目时返回 nil (pill 才该显示「选择项目」占位)")

        let dangling = ChatStore.resolveActiveProject(projects: allProjects,
                                                      selectedProjectId: UUID(),
                                                      selectedConversationId: convInBetty.id)
        check(dangling == nil,
              "T-CCOMP 显式选择指向已删除的项目时返回 nil, 不许回落到会话归属 (语义不变)")
    }

    /// 与 `CompactTextEditor.makeNSView` 同结构的最小夹具。
    private static func makeComposerScroll(_ text: String) -> NSScrollView {
        let width: CGFloat = 300
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        scroll.documentView = tv
        tv.string = text
        return scroll
    }
}
