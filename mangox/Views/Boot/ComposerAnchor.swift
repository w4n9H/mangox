//
//  ComposerAnchor.swift
//  转场 C「光标接管」的**落点** —— 主聊天输入框里那个真的插入点。
//
//  稿子的说法是"你在启动页看到的那个光标，就是你接下来要打字的那个"。要做到这句话，
//  落点就不能靠估：输入框的内边距、行高、字体、附件条有没有展开，任何一样变了，
//  "输入框左上角往下 6 点"这种算法都是错的。所以这里直接问那个 `NSTextView`
//  要 `firstRect(forCharacterRange:)` —— 它给的就是**真插入点**，与排版同源。
//
//  ⚠️ 只有一个订阅者（`ChatComposer` 里那份 `CompactTextEditor`），且是 `weak`：
//     输入框重建时旧的自己就掉了，不会留下一个指向已消失视图的强引用。
//     取不到就返回 nil，`BootView` 退化成"不飞光标"，其余转场照播。
//

import AppKit

@MainActor
enum ComposerAnchor {

    static weak var textView: NSTextView?

    /// 插入点在**窗口内容视图**里的位置（左上原点、y 向下 —— 与 SwiftUI 的 `.global` 同一套）。
    ///
    /// 返回值带上 `source`，只给日志用：这条路径**没法靠截图验**（转场只有 420ms，抓不到两帧），
    /// "飞了但落在错的地方"和"压根没飞"在图上长得一样。
    ///
    /// 两条路，缺一不可：
    /// - `firstRect`：有排版时最准（真插入点，管换行、管滚动、管内边距）；
    /// - `textContainerOrigin`：**空输入框走这条**。实测空串时 `firstRect` 给的是零矩形
    ///   （`CGRect.isEmpty` 为真），照直判就永远拿不到落点 —— 而这一屏出现的时机，
    ///   输入框**通常就是空的**。
    static func caretPoint() -> (point: CGPoint?, source: String) {
        guard let tv = textView, let win = tv.window, let content = win.contentView else {
            return (nil, textView == nil ? "no-textview" : "no-window")
        }
        let at = min(max(0, tv.selectedRange().location), tv.string.utf16.count)
        // 触发排版：视图刚建出来、或藏在启动页后面时，布局管理器可能还没排过。
        if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }

        var inWindow: NSPoint
        var source: String
        let screen = tv.firstRect(forCharacterRange: NSRange(location: at, length: 0),
                                  actualRange: nil)
        if screen.height > 0, screen.origin.x.isFinite, screen.origin.y.isFinite {
            inWindow = win.convertPoint(fromScreen: screen.origin)
            source = "firstRect"
        } else {
            // 退路：文本容器原点 = 第一行行首。它**已经含** `textContainerInset`，
            // 所以这里一点补偿都不加（加了就是双份内边距，光标会偏低两个点）。
            let o = tv.textContainerOrigin
            inWindow = tv.convert(NSPoint(x: o.x, y: o.y), to: nil)
            source = "container"
        }
        let inContent = content.convert(inWindow, from: nil)
        let y = content.isFlipped ? inContent.y : content.bounds.height - inContent.y
        return (CGPoint(x: inContent.x, y: y), source)
    }

    /// 转场落地之后**让输入框真的成为第一响应者**。
    ///
    /// 不这么做的话，C 方案最后那 20ms 是假的：光标飞到了插入点，然后连它一起被卸掉，
    /// 而输入框没有焦点 ⇒ 没有系统光标 ⇒ 稿子那句"就是你接下来要打字的那个"不成立。
    /// 代价是"启动完键盘焦点在输入框"—— 这是**产品选择**，不是实现细节（见交付说明）。
    static func focus() {
        guard let tv = textView, let win = tv.window else {
            Log.view("composer-focus", ["ok": "0", "why": "no-view"])
            return
        }
        if win.firstResponder === tv {
            Log.view("composer-focus", ["ok": "1", "why": "already"])
            return
        }
        let ok = win.makeFirstResponder(tv)
        Log.view("composer-focus", ["ok": ok ? "1" : "0", "why": "asked"])
    }
}
