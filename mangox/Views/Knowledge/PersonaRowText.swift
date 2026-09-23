//
//  PersonaRowText.swift
//  P11.2 常驻栏一行的**两行文案**（标题 + 副标）。
//
//  为什么不从文件里推导标题 (2026-09-23 boss 拍板): 用户写什么**不可控** —— `summary` 没人会写、
//  正文里有没有 `#` 标题也不一定 ⇒ 任何"回落链"都只是在赌。固定表把这件事从**内容推导**
//  变成**产品决定**: 三份已知常驻文件各有一句出厂文案, 表外文件用文件名。
//
//  文案住在 View 层而不是 `PersonaPack` 里: 它是**用户可见文案** (要进词表、要中英各自正确),
//  而模型层只出数据 —— 同 `KnowledgeStore` / `KnowledgeBase` 的分工 (§4.2)。
//  整行文案(含副标)都收在这里而不是散在 `KnowledgeView` 的私有分支里: 后者冒烟够不着,
//  那两条规则("标题带文件名" / "字数取 content")就没人守。
//

import Foundation

enum PersonaRowText {

    /// 出厂固定表 —— **表里没有就是没有**, 不猜、不读文件。
    ///
    /// 大小写不敏感 (`soul.md` / `Soul.md` 都算同一份): 用户手打文件名时的字母大小写
    /// 不该决定他看不看得懂这一行, 而放宽的代价是零。
    ///
    /// ⚠️ **必须是计算属性 (`static var` + 花括号), 写成 `static let` 会冻结取词** (2026-09-23
    /// boss 实测: 英文模式下标题后半句仍是中文)。`static let` 是懒加载的**一次性求值** —— 首次
    /// 访问就把 `L()` 的结果冻住, 之后切语言不再跟随; 而同一行的副标在函数体里取词、每次重算,
    /// 于是呈现出"一行里一半跟随、一半不跟随"的怪相。**`CodexTheme` 里早就写过这条注释, 光靠
    /// 注释没拦住我** ⇒ 已把它做成门禁 (`scan_wiring.py` 的「冻结取词」段), 不再依赖自觉。
    ///
    /// 写成**表字面量**而不是 `switch` 里的 `return L(...)`: 后者会被接线门读成"裸 return 的
    /// 字面量"而报可疑 —— 那张豁免名单只收**真阳性**(契约 token), 不该为这里再加一条。
    static func builtin(for fileName: String) -> String? {
        titleTable[fileName.lowercased()]
    }

    private static var titleTable: [String: String] {
        [
            "soul.md":  L("我是谁"),
            "rules.md": L("我必须怎么做"),
            "user.md":  L("你是谁"),
        ]
    }

    /// 行标题 = **文件名 + 出厂文案** (`SOUL.md - 我是谁`); 表外文件就只有文件名。
    ///
    /// **文件名必须在标题里, 不能只放在副标** (2026-09-23 boss: "这样看太单薄了") ——
    /// 这一行的作用是"认出这三份是什么", 而"哪一份"与"是什么"是同一个句子的两半;
    /// 拆到两行去, 眼睛得上下拼一次才读得懂。出厂文案那半走 `L()`, 中英切换时只换它。
    ///
    /// 表外文件**不加破折号后缀** —— 没有后半句却留个 ` - ` 只会让人以为被截断了。
    static func title(for fileName: String) -> String {
        guard let builtin = builtin(for: fileName) else { return fileName }
        return fileName + " - " + builtin
    }

    /// 行副标: `persona · <字数> 字` (+ 破损 / 按需标记)。
    ///
    /// **字数取 `content`(进 prompt 的那部分), 不是整份文件的大小** —— 判据是"能不能加得上":
    /// 面板汇总那句"人格段 N 条 / M 字"就是各条 `content.count` 的和 (冒烟守着这条恒等),
    /// 若这里改用整份文件的字节数, 三行相加就对不上上面那个 M, 而**两个数说的都是字数** ——
    /// 对不上不是精度问题, 是它们在说两件事。frontmatter 那几行本来就该被排除在"人格有多少"之外。
    ///
    /// 破损/按需标记照旧: 它们是**状态**, 状态宁可重复也要看得见。
    /// **层标记只在"按需"(非缺省)时出现**: 常驻是这一区的常态, 每行都标一遍就是噪声。
    /// 破损时不标层 —— `layer` 在破损文件上是编造的缺省 (见 `packEditor` 里的说明)。
    static func subtitle(for entry: PersonaPackEntry) -> String {
        var parts = ["persona", String(format: L("%lld 字"), entry.content.count)]
        if entry.isBroken {
            parts.append(L("frontmatter 破损"))
        } else if entry.layer == .ondemand {
            parts.append(L(entry.layer.tag))
        }
        return parts.joined(separator: " · ")
    }
}
