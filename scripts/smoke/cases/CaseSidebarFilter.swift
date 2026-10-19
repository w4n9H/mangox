//
//  caseSidebarFilter —— 侧栏过滤: 空查询恒等 / 项目命中留全貌 / 会话命中只留命中
//
//  2026-10-19 从 smokeMain.swift 的 run() 原样搬出（只搬家, 未改一行逻辑）。
//  原位替换为 `await caseSidebarFilter()`, 执行顺序不变。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSidebarFilter() async {
        // ① 恒等 / 过滤态判定
        let p16Chats = [
            ConversationItem(title: "hi"),
            ConversationItem(title: "DeepSeek 接入"),
            ConversationItem(title: "mangox"),
        ]
        let p16Groups = [
            ProjectGroup(title: "mangox", items: [
                ConversationItem(title: "alpha"),
                ConversationItem(title: "beta"),
            ]),
            ProjectGroup(title: "mangopi-cli", items: [
                ConversationItem(title: "重构计划"),
            ]),
        ]

        check(!SidebarFilter.isFiltering("") && !SidebarFilter.isFiltering("   \n\t"),
              "P14 过滤: 空/纯空白查询不算过滤态 (否则侧栏一打开就是空的)")
        check(SidebarFilter.isFiltering("hi"), "P14 过滤: 有内容才算过滤态")

        check(SidebarFilter.chats(p16Chats, query: "").map(\.title) == p16Chats.map(\.title),
              "P14 过滤: 空查询会话**原样返回** (含顺序 —— 调用方还要按 updatedAt 排)")
        check(SidebarFilter.projects(p16Groups, query: "   ").map(\.title) == p16Groups.map(\.title),
              "P14 过滤: 纯空白查询项目原样返回")

        // ② 大小写 / 变音不敏感
        check(SidebarFilter.matches("DeepSeek", query: "deep"),
              "P14 过滤: 大小写不敏感")
        check(SidebarFilter.matches("Café", query: "cafe"),
              "P14 过滤: 变音符号不敏感 (café 能被 cafe 搜到)")

        // ③ 会话过滤
        check(SidebarFilter.chats(p16Chats, query: "de").map(\.title) == ["DeepSeek 接入"],
              "P14 过滤: 会话按标题子串命中")
        check(SidebarFilter.chats(p16Chats, query: "zzz").isEmpty,
              "P14 过滤: 无命中返回空数组 (调用方据此落提示)")

        // ④ 项目名命中 → 整组保留 (这条是反例的靶子, 见下)
        let byGroupName = SidebarFilter.projects(p16Groups, query: "mangox")
        check(byGroupName.map(\.title) == ["mangox"],
              "P14 过滤: 只有项目名命中的那个组留下")
        check(byGroupName.first?.items.map(\.title) == ["alpha", "beta"],
              "P14 过滤 反例: 项目名命中 ⇒ **整组会话都在** (改成只留标题命中的会话 ⇒ 这里立刻红)")

        // ⑤ 仅会话名命中 → 保留项目, 但只留命中的会话
        let byItemName = SidebarFilter.projects(p16Groups, query: "重构")
        check(byItemName.map(\.title) == ["mangopi-cli"],
              "P14 过滤: 会话名命中的项目被保留 (项目名本身没中)")
        check(byItemName.first?.items.map(\.title) == ["重构计划"],
              "P14 过滤: 只留命中的会话, 不把同项目下无关会话一起拖出来")

        // ⑥ 谁都没中 → 整组消失
        check(SidebarFilter.projects(p16Groups, query: "zzz").isEmpty,
              "P14 过滤: 项目名与会话名都没中 ⇒ 整组不出现 (空区块头由视图侧一起收走)")

        // ⑦ 组的身份不被过滤改掉 —— 视图靠它查 expandedProjects, 换 id 会让展开态失联
        check(byItemName.first?.id == p16Groups[1].id,
              "P14 过滤: 过滤后组 id 不变 (否则展开态查不到, 搜索期强制展开也会错位)")
    }
}
