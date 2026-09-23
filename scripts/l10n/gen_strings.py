#!/usr/bin/env python3
r"""
MangoX 本地化词表门禁 / 盘点 / 落盘

本项目**用中文原文当 key** (SwiftUI LocalizedStringKey 的 key 即字面量)。本脚本从源码抽取
所有会被查表的中文串, 与 Resources/en.lproj/Localizable.strings 对账。

用法:
  python3 scripts/l10n/gen_strings.py            # 盘点: 打印缺失/多余/总数
  python3 scripts/l10n/gen_strings.py --check    # 门禁: 有缺失则退出码 1 (漏译)
  python3 scripts/l10n/gen_strings.py --list     # 打印全部 key (排序, 供翻译)
  python3 scripts/l10n/gen_strings.py --write    # 从 en_values.VALUES 落盘 en.lproj

译文的**唯一真源** = `scripts/l10n/en_values.py` 里的 VALUES 字典 (人工翻译)。
`--write` 只负责转义 + 排序 + 落盘, 不碰译文内容。

为什么不从源码"智能推断类型": 插值 `\(expr)` 的格式说明符由 Swift 编译器定 (Int → %lld,
String → %@)。这里用启发式猜 (见 NUMISH), 猜错只会导致该条**不生效** (回落中文原文),
不会崩 —— 值里的说明符恒与 key 保持一致。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, 'mangox')
TABLE = os.path.join(APP, 'Resources/en.lproj/Localizable.strings')
ZH_TABLE = os.path.join(APP, 'Resources/zh-Hans.lproj/Localizable.strings')

CJK = re.compile(r'[\u4e00-\u9fff]')

# 查表调用的**前缀** (只允许空白): 字面量紧跟在 `L(` / `LK(` 之后即视为"作者声明它是文案"。
#
# 为什么是"前缀"而不是"把整个实参抠出来": 实参里可能嵌插值 (`L("删除会话「\(x ?? "未命名")」？")`),
# 朴素正则会切在那个内层引号上, 生成一条**永不命中的假 key**。改为复用 `scan_literals`
# (它本来就是插值深度感知的) + 用本正则判"这个字面量前面是不是查表调用", 一份扫描逻辑两处用。
#
# `\b` 是必需的: `URL(` / `foo_L(` 都不该命中 (`L` 前是词字符 ⇒ 无边界)。
LOOKUP_CALL = re.compile(r'\bLK?\($')


def strip_line_comment(code):
    """去行尾注释 —— **字符串字面量感知**。

    ⚠️ 这里曾长期是朴素的 `code.split('//')[0]`。它把**字面量里的** `//` 当成注释起点,
    于是以 `//` 开头的文案被切成个残句:
      `L("// 文件过大 (>1 MB), 暂不支持预览")` → 只留下 `… return L("`
    ⇒ 抽出来的是一个**未闭合的空字面量**, 这条串在词表门/接线门/指纹里**全都看不见**
    (实测 2026-09-22: 5 条文案的英文界面一直在静默回落中文, 而词表对账 564/564 全绿)。

    判据: **只在字符串外**才认 `//`; 串内照抄 (含 `\\"` 转义)。本函数是全脚本唯一的注释剥离器,
    `scan_wiring` / `wire_strings` 共用它 —— 两份实现迟早对同一行给出不同判定。
    """
    out = []
    in_str = False
    escaped = False
    i = 0
    while i < len(code):
        c = code[i]
        if in_str:
            out.append(c)
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == '/' and i + 1 < len(code) and code[i + 1] == '/':
            break
        out.append(c)
        i += 1
    return ''.join(out)


def scan_literals(line):
    """扫描一行里的字符串字面量 —— **插值深度感知**。

    朴素正则在 `"删除会话「\\(x ?? "未命名")」？"` 这种"插值里再嵌字符串"的写法上会切错,
    导致真正的 key 漏掉 (确认框文案几乎全是这个形态)。返回 [(内容, 起始下标)]。
    """
    out = []
    i = 0
    while i < len(line):
        if line[i] != '"':
            i += 1
            continue
        j = i + 1
        depth = 0
        buf = []
        while j < len(line):
            c = line[j]
            if c == '\\' and j + 1 < len(line):
                if line[j + 1] == '(':
                    depth += 1
                    buf.append('\\(')
                else:
                    buf.append(line[j:j + 2])
                j += 2
                continue
            if depth > 0:
                if c == '(':
                    depth += 1
                elif c == ')':
                    depth -= 1
                buf.append(c)
                j += 1
                continue
            if c == '"':
                break
            buf.append(c)
            j += 1
        out.append((''.join(buf), i))
        i = j + 1
    return out

# 协议面 / 落库面 / pi 注入面: 这些串**不进词表** (改了会动到邮件协议、持久化值或 prompt)
EXCLUDE_FILES = {
    'mangox/Persistence/PersistenceStore.swift',   # 落库日志标签
    'mangox/Models/MailboxReply.swift',            # 回执正文与主题 (邮件协议面)
    # ⚠️ 本文件**同时**拼注入面文本(必须恒中文)与载荷表数据。排除它的代价实测过 (2026-09-22):
    #    在这里写 `L()` 的 key **永远进不了词表** ⇒ 英文界面静默回落中文, 而且本文件被跳过、
    #    连"已废弃"都不报 —— **三道 l10n 门全都看不见**。所以告警/文案一律在 View 侧拼,
    #    本文件只出**数据** (`KnowledgeStore.KnowledgeWarning`)。
    'mangox/State/KnowledgeStore.swift',           # 注入 pi 的知识块 + 载荷表数据 (文案在 View 侧)
    # ⚠️ P11.4 (2026-09-22): 本文件**生成的就是 prompt 字节** —— 索引段的 token (`[知识库]`)、
    #    段头、`路径:`/`说明:`/`文件 (…)` 前缀全部逐字进 L0 注入块。三条理由排除它:
    #      ① 它们**不是 UI 文案**, 本地化 = 让用户的界面语言改掉注入进 prompt 的字节 (同
    #         `KnowledgeKind.tag` 的理由, 见 wiring_allow.txt F 组), 会破稳定段的逐字节稳定性;
    #      ② UI 侧的"索引预览"是**逐字预览** prompt 字节 —— 若在这里取词, 预览就与真实注入不同源,
    #         而"预览说 12 个文件、agent 看到 9 个"正是 P11.4 要防的那个病;
    #      ③ 本文件的中文**全部**在 `KnowledgeBaseScan` 里 (模型层只出数据, 无文案)。
    #    代价 (同上面那行, 实测过): 在此文件里写 `L()` 的 key 永远进不了词表, 三道门全都看不见。
    #    ⇒ **要加 UI 文案请写在 View 侧** (拒绝原因的人话就归 `KnowledgeView`)。
    'mangox/Models/KnowledgeBase.swift',           # 注入 pi 的索引段字节 (无 UI 文案)
    'mangox/State/SchedulerService.swift',         # 注入 pi 的指令文本
    'mangox/mangoxApp.swift',                      # 不参与冒烟编译, 无文案
    # 语言名自带 (中文 / English 必须原样), 故整体跳过。**但其 `AppLanguage.label` 里的 `L("跟随系统")`
    # 是靠 `Theme/AppAppearance.swift` 的同名字面量才活在词表里的** —— 改这句话要两边一起改,
    # 或把它从本名单里拿掉 (代价: 中文/English 两个必须原样的语言名会被拖进词表)。
    'mangox/Localization/AppLanguage.swift',       # 语言名自带, 不查表
}
EXCLUDE_PAT = re.compile(r'\[MGOX|\[DONE|\[FAILED|\[BLOCKED|\[RUNNING|BODY\[\]|已省略|已截断|邮件未被受理')

# 整行跳过: 正则字面量 —— 给 re.compile 用的串不是 UI 文案, 只是恰好含中文 (实测假阳性)
EXCLUDE_LINE = re.compile(r're\.compile|NSRegularExpression')

# key 级跳过: `[PkgTag] ...` 是日志前缀。真 UI 里的 `[附件: %@]` 后随汉字, 不受影响。
LOG_KEY = re.compile(r'^\[[A-Za-z][A-Za-z0-9]*\]')

# key 级跳过: 正则模式串 —— `\s`/`\d`/`\w`/`\[`/`(?:` 这些构造正常文案里不会出现,
# 但主题清洗的 `"^\\s*(re|fwd?|回复|转发)..."` 会因含汉字被误当文案 (实测假阳性)。
REGEX_KEY = re.compile(r'\\[sdwSDW]|\\\[|\\\]|\(\?:')


def is_regex_key(key):
    """key 里是否含正则专有构造 (比较前先把源码级双反斜杠折成单个)。"""
    return bool(REGEX_KEY.search(key.replace('\\\\', '\\')))

# 已知**待接线**: 域层里用户可见、但代码尚未用 L()/LK() 包裹的串。记着不计入门禁
# (门禁不该长红), 接线后从本名单移走。域层第一批接线已完成, 故当前为空。
#
# 注: `gateReplyBody` 的四条「邮件未被受理…」走 EXCLUDE_PAT —— 它们是**邮件回执正文**
# (协议面, 与 MailboxReply.swift 同待遇 → 恒中文, 不随 App 语言变)。
DEFERRED_PREFIX = ()

# 插值表达式里出现这些词 → 判定为数字 (SwiftUI 用 %lld)
#
# **这只是兜底** —— 权威判定走 EXPR_TYPES (阅源确认) 与 NUMISH 的高置信片段。
# 曾经靠"名字像数字"的宽判据 (runCount/turnCount/pollInterval 都不在白名单里) 导致 13 条
# key 悄悄判成 %@ → 运行时查表失配 → **静默回落中文**。宽判据已收窄为下列高置信片段。
NUMISH = re.compile(
    r'(\.count|\.added|\.deleted|\.tokens|\.dirtyCount|\.unreported|\.maxPerMessage'
    r'|\.whitelist\.count|Int\(|Int32\(|Int64\()')


# 类型 → 格式说明符。**权威映射**, 抄自 SwiftUICore 的
# `formatSpecifier<T>(_:)` 实现 (internal, 在 .swiftinterface 里可读到函数体):
#   Int/Int64 → int64Specifier   Int8/16/32 → int32Specifier
#   UInt/UInt64 → uint64Specifier  UInt8/16/32 → uint32Specifier
#   Float → floatSpecifier   Double/CGFloat → doubleSpecifier
#   default → "%@"
# 各常量取值见 swift-corelibs / Apple 惯例: lld / d / llu / u / f / lf。
TYPE_SPECIFIER = {
    'Int': '%lld', 'Int64': '%lld', 'UInt': '%llu', 'UInt64': '%llu',
    'Int8': '%d', 'Int16': '%d', 'Int32': '%d',
    'UInt8': '%u', 'UInt16': '%u', 'UInt32': '%u',
    'Double': '%lf', 'CGFloat': '%lf', 'Float': '%f',
}

# 表达式 → 类型。**逐条阅读源码声明确认** (不是猜形态), 只登记启发式会判错的那些。
# 命名规则: 键 = 插值表达式的原文 (与源码逐字一致)。
EXPR_TYPES = {
    'draft.pollInterval': 'Int',              # MailboxModels.swift var pollInterval: Int
    'agent.pollInterval': 'Int',
    'store.maxConcurrentTurns': 'Int',        # ChatStore.swift @Published var maxConcurrentTurns: Int
    'maxConcurrentTurns': 'Int',
    'task.runCount': 'Int',                   # ScheduledModels.swift var runCount: Int
    'store.mailboxQueuedTaskCount': 'Int',    # ChatStore.swift var mailboxQueuedTaskCount: Int
    'turnCount': 'Int',                       # BottomStatusBar.swift let turnCount: Int
    'total': 'Int',                           # WorkspaceView.swift let total = reduce(0){…count}
    'step': 'Int',                            # ScheduledModels.swift stepSize(…) -> Int?
    'uid': 'Int64',                           # MailTransport.swift var uid: Int64?
    'exitCode': 'Int32',                      # CurlMailCommand.failure(exitCode: Int32, …) → %d
    'ImagePipeline.maxPerMessage': 'Int',     # ImagePipeline.swift static let maxPerMessage = 4
    'a': 'Int',                               # StatusBarModels case retrying(attempt: Int, …)
    'm': 'Int',                               #   同上 (maxAttempts: Int)
    '(d + 999) / 1000': 'Int',                #   同上 (delayMs: Int)
    'd.unreported': 'Int',
    'turn.index': 'Int',
    'turns': 'Int',
    'side.turns': 'Int',
    'info.turns': 'Int',
    'existing.whitelist.count': 'Int',
    'store.runningTurns.count': 'Int',
    'git.dirtyCount': 'Int',
    'count': 'Int',
    'n': 'Int',
}


def specifier_for(expr):
    """插值表达式 → 格式说明符 + 是否已确认 (未确认的走 %@ 默认, 但会被 --audit 报出来)。"""
    key = expr.strip()
    if key in EXPR_TYPES:
        return TYPE_SPECIFIER.get(EXPR_TYPES[key], '%@'), True
    ctor = re.match(r'^(Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Double|Float|CGFloat)\(', key)
    if ctor:
        return TYPE_SPECIFIER[ctor.group(1)], True
    if NUMISH.search(key):
        return '%lld', True
    return '%@', False




def to_format_key(text):
    """把 `文字 \\(expr) 文字` 转成格式 key: 数字类插值 → %lld, 其余 → %@。

    必须做**平衡括号**匹配: 插值里常有嵌套调用 (`\\((e as? T)?.label ?? String(describing: e))`),
    非贪婪正则会切在第一个 `)` 上, 生成一条永不命中的假 key。
    """
    out = []
    i = 0
    while i < len(text):
        if text[i] == '\\' and i + 1 < len(text) and text[i + 1] == '(':
            depth = 1
            j = i + 2
            inner = []
            while j < len(text) and depth > 0:
                char = text[j]
                if char == '(':
                    depth += 1
                elif char == ')':
                    depth -= 1
                if depth > 0:
                    inner.append(char)
                j += 1
            out.append(specifier_for(''.join(inner))[0])
            i = j
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def interpolation_parts(text):
    """拆 `字面量 \\(expr) 字面量 …` → [('lit'|'var', 内容)] (平衡括号, 顺序保留)。"""
    parts = []
    buf = []
    i = 0
    while i < len(text):
        if text[i] == '\\' and i + 1 < len(text) and text[i + 1] == '(':
            if buf:
                parts.append(('lit', ''.join(buf)))
                buf = []
            depth = 1
            j = i + 2
            inner = []
            while j < len(text) and depth > 0:
                char = text[j]
                if char == '(':
                    depth += 1
                elif char == ')':
                    depth -= 1
                if depth > 0:
                    inner.append(char)
                j += 1
            parts.append(('var', ''.join(inner)))
            i = j
        else:
            buf.append(text[i])
            i += 1
    if buf:
        parts.append(('lit', ''.join(buf)))
    return parts


def source_keys():
    """源码里所有会被查表的串 → {key: [位置]}

    **两条收集路径, 缺一不可** (2026-09-22 补):

    ① **显式查表调用的实参** —— `L("…")` / `LK("…")`, **无条件收, 不看是否含汉字**。
       实现是"字面量开引号前的同前缀结尾是否匹配 `LOOKUP_CALL`", 不是把实参正则抠出来 ——
       见 `LOOKUP_CALL` 处的注释 (实参可嵌插值, 抠出来会得到假 key)。
    ② **含汉字的字面量** —— 原来的路径, 用来抓"该接线还没接线"的中文串。

    为什么必须加 ①: 那两道 CJK 门是为了避开 `"PASS"` / `"Chat"` / 正则串这类
    "恰好不含汉字、也不是文案"的字面量 —— 但 `L("priority %lld")` 这种**形如纯英文的 key**
    会被一并躲过去, 于是**三道门全都看不见它**: 词表门不收 (英文界面静默回落)、接线门只判
    含汉字字面量、指纹只遍历词表里的 key。判据改成 **"调用查表函数 = 作者声明它是文案"** ——
    这比"含不含汉字"可靠, 也正是它该有的判据。

    **剩余边界 (可接受, 但要知道)**: 一条**纯英文、又没裹 `L()`** 的 UI 文案仍然三道门全看不见。
    这是静态分析的本质不可判定 (任何英文字面量都可能是文案、也可能是标识符), 不打算用启发式去糊。
    真正的兜底是"UI 文案一律走 `L()`"这条写法纪律本身。

    另: 本函数依赖 `strip_line_comment` 而非裸 `split('//')` —— 后者会把 `L("// 空文件")`
    切成未闭合残句, 这条文案会在**本门里静默失踪** (实测踩过, 5 条)。
    """
    out = {}
    for dirpath, _, filenames in os.walk(APP):
        for name in sorted(filenames):
            if not name.endswith('.swift'):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT)
            if rel in EXCLUDE_FILES:
                continue
            for lineno, line in enumerate(open(full, encoding='utf-8'), 1):
                code = strip_line_comment(line)
                if EXCLUDE_PAT.search(code) or EXCLUDE_LINE.search(code):
                    continue
                texts = set()
                for text, start in scan_literals(code):
                    if LOOKUP_CALL.search(code[:start]):
                        texts.add(text)
                    elif CJK.search(text):
                        texts.add(text)
                for text in texts:
                    key = to_format_key(text)
                    if LOG_KEY.match(key) or is_regex_key(key):
                        continue
                    out.setdefault(key, []).append(f'{rel}:{lineno}')
    return out


def table_keys(path):
    """Localizable.strings 里的 key (解析 `"key" = "value";`)"""
    if not os.path.exists(path):
        return {}
    out = {}
    for lineno, line in enumerate(open(path, encoding='utf-8'), 1):
        stripped = line.strip()
        if stripped.startswith('/*') or stripped.startswith('*') or not stripped:
            continue
        match = re.match(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', stripped)
        if match:
            out[match.group(1)] = (match.group(2), lineno)
    return out


def escape(text):
    """落盘转义。

    **反斜杠不做倍增** —— key 的形态取自源码 (源码级 `\\n` 已是两字符), 而 .strings 的转义
    语法与 Swift 源码在 `\\n` / `\\t` / `\\\\` / `\\"` 上一致, 直接照写即可。倍增会让 `\\n`
    变成"字面反斜杠 + n" → 运行时查表失配、静默回落中文 (实测踩过)。

    只有两件事要做: ①真控制字符 (译文字典里误写的字面换行) 转成转义序列
    ②裸引号 → `\\"` (已是 `\\"` 的不再动)。
    """
    text = text.replace('\r\n', '\n').replace('\n', '\\n').replace('\t', '\\t')
    return re.sub(r'(?<!\\)"', r'\\"', text)


def write_table(values, path=TABLE):
    """把 VALUES 落盘成 .strings (排序输出)。"""
    keys = sorted(values)
    lines = [
        '/*',
        '   MangoX English localization.',
        '',
        '   中文原文即 key (见 scripts/l10n/gen_strings.py 的说明)。缺项会回落成中文原文,',
        '   所以漏译不会崩、也不会显示 key 名, 只会显示中文。',
        '',
        '   **本文件由 scripts/l10n/gen_strings.py --write 生成, 别手改** ——',
        '   译文改 scripts/l10n/en_values.py 的 VALUES, 再跑 --write。',
        '',
        f'   条数: {len(keys)}',
        '*/',
        '',
    ]
    for key in keys:
        lines.append(f'"{escape(key)}" = "{escape(values[key])}";')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write('\n'.join(lines) + '\n')
    return len(keys)


def main():
    args = set(sys.argv[1:])

    if '--write' in args:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import en_values
        count = write_table(en_values.VALUES)
        print(f'wrote {os.path.relpath(TABLE, ROOT)} ({count} entries)')
        return 0

    src = source_keys()
    table = table_keys(TABLE)
    deferred = {k for k in src if k.startswith(DEFERRED_PREFIX)}
    missing = sorted(set(src) - set(table) - deferred)
    stale = sorted(set(table) - set(src))

    if '--list' in args:
        for key in sorted(src):
            print(key)
        return 0

    print(f'源码 key: {len(src)}   词表条数: {len(table)}')
    print(f'未翻译 (源码有、词表无): {len(missing)}')
    for key in missing[:40]:
        print(f'  - {key}    [{src[key][0]}]')
    if len(missing) > 40:
        print(f'  ... 另 {len(missing) - 40} 条')
    if deferred:
        print(f'已知待接线 (域层, 尚未用 L() 包裹 → 不计门禁): {len(deferred)}')
        for key in sorted(deferred):
            print(f'  ~ {key[:48]}…    [{src[key][0]}]')
    print(f'已废弃 (词表有、源码无, 无害但该清): {len(stale)}')
    # 上限与 `missing` 对齐 (40 + 省略提示)。曾硬编码 `[:15]` 且**不告知截断** ——
    # 于是门说"17 条该清"却只列 15 条, 照单清理就会漏掉 2 条, 而漏掉不会有任何红灯。
    # 门的列表要么列全, 要么明说自己截了 (2026-09-22 实测踩到: 漏的正是 `身份键（可选）`
    # 与 `这条能发给模型吗？` 两条 —— 它们是 P11.2c 撤下的 UI 里最后两个残余)。
    for key in stale[:40]:
        print(f'  - {key}')
    if len(stale) > 40:
        print(f'  ... 另 {len(stale) - 40} 条')

    if '--check' in args and missing:
        print('\nFAIL - 存在未翻译条目', file=sys.stderr)
        return 1
    if '--check' in args:
        print('OK - 词表覆盖全部源码 key')
    return 0


if __name__ == '__main__':
    sys.exit(main())
