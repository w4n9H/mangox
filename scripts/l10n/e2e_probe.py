#!/usr/bin/env python3
r"""
本地化端到端验证 —— 不启动 App, 直接证明「文案真的会翻」。

**两条路径必须分开测** (这是本项目最容易搞混的地方):
  · `Text("中文")` → `LocalizedStringKey` → 查哪张表由 **`\.environment(\.locale)`** 决定
  · `L("中文")`   → `L10n.text`        → 查哪张表由 **`LanguageModel.shared.current`** (UserDefaults)
  两者共用同一批 .strings, 但入口不同, 任一环节错都只表现为「静默回落中文」。

三段:

  ① probeTable  编译进真 `mangox/Localization/AppLanguage.swift`, 用真 `L10n.bundle(for:)`
                逐条断言**全部 key**: en 命中词表值 / zh 回落 key 本身 (= 中文原文)。
                抓: .lproj 没进包 · key 形态不匹配 · 转义写错。

  ② probeForms  `Text(插值字面量)` 经 `ImageRenderer` 出图取 md5, 与
                `Text(verbatim: 期望串)` 比对 (en 与 zh 各一次)。抓 `%lld`/`%@` 判错 ——
                单看词表看不出, 判错只会静默回落中文。变量类型照抄源码声明。

  ③ probeL      `L()` 路径抽查 (切 `LanguageModel.shared.current`, 用完还原)。

用法: `python3 scripts/l10n/e2e_probe.py`  (退出码 0 = 全过)
"""

import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_strings as g

WORK = '/tmp/mangox-l10n-e2e'

# ── ② 形态渲染用例 ───────────────────────────────────────────────────────────
# (名字, Text 表达式, 期望英文, 期望中文)
# 变量类型刻意照抄源码声明 —— 说明符由**类型**定 (Int → %lld, Int32 → %d, String → %@)。
FORM_CASES = [
    ('纯字面量', 'Text("高级")', '"Advanced"', '"高级"'),
    ('Int → %lld', 'Text("\\(secs) 秒")', '"30s"', '"30 秒"'),
    ('Int32 → %d', 'Text("curl 退出码 \\(code)")', '"curl exit code 7"', '"curl 退出码 7"'),
    ('String → %@', 'Text("发送失败: \\(s)")', '"Send failed: boom"', '"发送失败: boom"'),
    ('换行 key', 'Text("暂无任务\\n点右上角 + 新建")',
     '"No tasks yet\\nUse + in the top right to create one"', '"暂无任务\\n点右上角 + 新建"'),
    ('三插值 Int', 'Text("重试 \\(a)/\\(m) · \\((d + 999) / 1000)s 后")',
     '"Retry 1/3 · in 5s"', '"重试 1/3 · 5s 后"'),
    ('引号 + 插值', 'Text("删除插件「\\(pname)」？")', '"Delete plugin \\"Foo\\"?"', '"删除插件「Foo」？"'),
    ('Int64 → %lld', 'Text("已跑 \\(runs) 次")', '"Ran 7 times"', '"已跑 7 次"'),
    ('Int 计数', 'Text("\\(totalItems) 项")', '"5 items"', '"5 项"'),
    ('空串插值', 'Text("认证失败, 检查授权码\\(detail)")',
     '"Authentication failed — check the app password"', '"认证失败, 检查授权码"'),
    ('两插值混合', 'Text("任务台 · \\(runningCount) 个在途")',
     '"Task bar · 4 in flight"', '"任务台 · 4 个在途"'),
    # 三元规则 (2026-09-20 实测): **内联**三元直接落在实参位会被推到 LocalizedStringKey → 本地化;
    # 但先赋给变量 (`let x = cond ? "甲" : "乙"`) 就固化成 String → 不本地化, 必须显式 LK()/L()。
    ('内联三元', 'Text(flag ? "预设" : "自定义")', '"Preset"', '"预设"'),
]

# 反例: **不该**被本地化的形态 (断言它原样保留中文)。
# 用途: 防止有人"顺手"把 String 变量包成 Text(x) 却以为能翻译 —— 这类静默失效只能靠反例守。
NOT_LOCALIZED = [
    ('String 变量', 'Text(premade)'),
]

# ── ③ L() 抽查 ──────────────────────────────────────────────────────────────
L_SPOT = [
    '高级', '未配置: %@', '上下文压缩完成：%lld → %lld tokens', '这里不在词表里',
]

SWIFT_HEAD = r'''
import SwiftUI
import AppKit
import CryptoKit

// ── ② 形态渲染用例的变量 ─────────────────────────────────────────────────────
// **必须在全局作用域** —— FORMS 里的闭包在全局求值。类型照抄源码声明。
let secs: Int = 30
let code: Int32 = 7
let s = "boom"
let a: Int = 1, m: Int = 3, d: Int = 4500
let pname = "Foo"
let runs: Int = 7
let totalItems: Int = 5
let detail = ""
let runningCount: Int = 4
let flag = true
let premade = "预设"      // 反例用: String 变量 (非字面量) 传给 Text → 不查表

@MainActor func fp(_ text: Text, _ locale: String) -> String {
    let view = text
        .environment(\.locale, Locale(identifier: locale))
        .font(.system(size: 13))
        .frame(width: 700, height: 72, alignment: .topLeading)
        .background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return "nil" }
    return SHA256.hash(data: tiff).map { String(format: "%02x", $0) }.joined()
}

var pass = 0, fail = 0
func report(_ ok: Bool, _ name: String) {
    if ok { pass += 1 } else { fail += 1; print("FAIL  \(name)") }
}

/// ① 全量 key: 真 bundle + 真 L10n.bundle(for:)
func probeTable() {
    guard let en = L10n.bundle(for: .en), let zh = L10n.bundle(for: .zhHans) else {
        fail += 1
        print("FAIL  解析 lproj 失败 (en 或 zh-Hans 缺失) —— 资源没进包?")
        return
    }
    var bad = 0
    for (key, value) in TABLE {
        let enHit = en.localizedString(forKey: key, value: nil, table: nil)
        let zhHit = zh.localizedString(forKey: key, value: nil, table: nil)
        if enHit != value { fail += 1; bad += 1; if bad < 8 { print("FAIL  en: \(key) → \(enHit)") } }
        else if zhHit != key { fail += 1; bad += 1; if bad < 8 { print("FAIL  zh 未回落原文: \(key) → \(zhHit)") } }
        else { pass += 1 }
    }
    print("① 词表 \(TABLE.count) 条 × (en 命中 + zh 回落原文)")
}

/// ② 形态渲染: LocalizedStringKey 路径 (由 \.environment(\.locale) 驱动)
@MainActor func probeForms() {
    var bad = 0
    for (name, live, en, zh) in FORMS {
        let okEn = fp(live(), "en") == fp(Text(verbatim: en), "en")
        let okZh = fp(live(), "zh-Hans") == fp(Text(verbatim: zh), "zh-Hans")
        if okEn && okZh { pass += 1 } else {
            fail += 1; bad += 1
            print("FAIL  \(name)  en=\(okEn ? "ok" : "≠期望")  zh=\(okZh ? "ok" : "≠期望")")
        }
    }
    print("② 形态 \(FORMS.count) 例 (en 命中 + zh 回落)")
}

/// 反例: 断言**不**本地化 —— 例如 `Text(String 变量)` 在 en 下仍是中文原文。
/// 为什么要有反例: "以为包了 Text() 就能翻译" 是静默失效, 正向用例永远抓不到它。
@MainActor func probeNotLocalized() {
    var bad = 0
    for (name, live) in NEGS {
        // 期望: en 环境下渲染结果 == 中文原文 (即**没有**被翻译)
        let ok = fp(live(), "en") == fp(Text(verbatim: "预设"), "en")
        if ok { pass += 1 } else {
            fail += 1; bad += 1
            print("FAIL  反例 \(name): 竟然被本地化了 (或指纹不符)")
        }
    }
    print("②b 反例 \(NEGS.count) 例 (断言保持原文)")
}

/// ③ L() 路径 (由 LanguageModel.shared.current / UserDefaults 驱动) —— 用完还原
@MainActor func probeL() {
    let saved = LanguageModel.shared.current
    defer { LanguageModel.shared.current = saved }

    LanguageModel.shared.current = .en
    for (key, expected) in LSPOT { report(L(key) == expected, "L() en: \(key)") }
    LanguageModel.shared.current = .zhHans
    for (key, _) in LSPOT { report(L(key) == key, "L() zh 回落: \(key)") }
    print("③ L() 抽查 \(LSPOT.count) 条 × 2 语言")
}

MainActor.assumeIsolated {
    probeTable()
    probeForms()
    probeNotLocalized()
    probeL()
    print("\n\(pass) PASS / \(fail) FAIL")
    exit(fail == 0 ? 0 : 1)
}
'''


def swift_literal(raw):
    """词表里的原始形态 (源码级转义) 可直接当 Swift 字面量内容 —— 两者转义规则一致。"""
    return '"' + raw + '"'


def build_source():
    table = g.table_keys(g.TABLE)
    lines = ['let TABLE: [(String, String)] = [']
    for key in sorted(table):
        lines.append(f'    ({swift_literal(key)}, {swift_literal(table[key][0])}),')
    lines.append(']')
    lines.append('let FORMS: [(String, () -> Text, String, String)] = [')
    for name, live, en, zh in FORM_CASES:
        lines.append(f'    ({swift_literal(name)}, {{ {live} }}, {en}, {zh}),')
    lines.append(']')
    lines.append('let NEGS: [(String, () -> Text)] = [')
    for name, live in NOT_LOCALIZED:
        lines.append(f'    ({swift_literal(name)}, {{ {live} }}),')
    lines.append(']')
    lines.append('let LSPOT: [(String, String)] = [')
    for key in L_SPOT:
        entry = table.get(key)
        lines.append(f'    ({swift_literal(key)}, {swift_literal(entry[0] if entry else key)}),')
    lines.append(']')
    return '\n'.join(lines) + '\n' + SWIFT_HEAD


def main():
    app_lang = os.path.join(g.ROOT, 'mangox/Localization/AppLanguage.swift')
    if not os.path.exists(app_lang):
        print(f'FAIL - 缺 {app_lang}')
        return 1

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    for name in ('en.lproj', 'zh-Hans.lproj'):
        shutil.copytree(os.path.join(g.APP, 'Resources', name), os.path.join(WORK, name))
    with open(os.path.join(WORK, 'main.swift'), 'w', encoding='utf-8') as handle:
        handle.write(build_source())

    binary = os.path.join(WORK, 'probe')
    built = subprocess.run(['xcrun', 'swiftc', '-O', 'main.swift', app_lang, '-o', binary],
                           cwd=WORK, capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL - 编译探针失败')
        print((built.stdout or built.stderr)[-3000:])
        return 1

    run = subprocess.run([binary], cwd=WORK, capture_output=True, text=True)
    print(run.stdout.rstrip())
    if run.stderr.strip():
        print(run.stderr.rstrip(), file=sys.stderr)
    return run.returncode


if __name__ == '__main__':
    sys.exit(main())
