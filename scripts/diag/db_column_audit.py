#!/usr/bin/env python3
r"""
数据库列体检 —— 哪些列现在是「死重量」。

**为什么需要它** (2026-09-23 boss 问"数据库里面的字段需不需要清理"):

"哪一列可以删"听上去是肉眼可答的, 其实不是 —— 它要求同时知道**代码引用**与**设计承诺**,
而前者靠 `grep 列名` 会被三样东西冒充:
  ① **建表语句本身** (列名当然出现在 DDL 里, 不排除的话每一列都"有引用" —— 第一版就栽在这);
  ② **注释** (本项目给已弃列写了很长的墓碑注释, 那也算"命中" —— 第二版栽在这);
  ③ **命名转换** (库里是 `origin_session_id`, 代码里是 `originSessionId`)。

三者都排除之后, 再补一条**自检**: 已知 `sensitivity` 必须落在零引用集合里、
已知 `layer` 必须不在。**自检不过就退出 1** —— 本脚本自己会骗人的时候必须喊出来,
不能像前两版那样安静地吐一张空表 (那张"0 个死列"的表差点让我下错结论)。

判据的边界 (诚实记): "零引用"是**硬事实**, 只能说明"没人碰它"; 反过来"有引用"**不等于**
"有消费者" —— `trigger` / `counterfactual` / `hit_count` / `last_hit_at` /
`origin_session_id` 这五列的引用几乎全在**持久化往返**里 (读出来、写回去, 没人用),
剩下那点落在**建立接口的参数透传**上 (存进去了, 但没有任何读取方消费)。
脚本把每列的引用**按文件列出来**, 那种形态一眼可辨。

⚠️ **它只排序嫌疑, 不定论**: `events.seq` / `sessions.fork_*` 这类"单文件、100% 落在
`PersistenceStore.swift`"的列很可能不是往返, 而是**同文件内的读取消费** (如 fork 用
`fork_source_file` 重建会话)。要看懂一列的真正去向只能人读代码 —— 本脚本负责**把嫌疑名单
按嫌疑度排好**, 不负责下判决。

用法:
  python3 scripts/diag/db_column_audit.py            # 全表体检
  python3 scripts/diag/db_column_audit.py --db PATH  # 指定库 (默认 ~/.mangox/mangox.db)
"""

import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'mangox'

# 自检锚点 —— 体检结论变了就该改这里, 而不是让脚本闭嘴
MUST_BE_DEAD = {'sensitivity'}
MUST_BE_ALIVE = {'layer', 'kind', 'priority', 'key'}


def strip_comment(line):
    """引号感知地切掉 `//` 注释 —— 朴素 `split('//')` 会吃掉字符串里的 `//` (本项目踩过)。"""
    out, i, quote = [], 0, None
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == quote and line[i - 1] != '\\':
                quote = None
        elif ch in '"\'':
            quote = ch
            out.append(ch)
        elif ch == '/' and i + 1 < len(line) and line[i + 1] == '/':
            break
        else:
            out.append(ch)
        i += 1
    return ''.join(out)


def code_lines_without_ddl():
    """全部 Swift 行, 去掉注释与**建表语句** (DDL 里出现列名不算引用)。"""
    kept = []
    for path in sorted(APP.rglob('*.swift')):
        in_ddl = False
        for raw in path.read_text(encoding='utf-8').split('\n'):
            if 'CREATE TABLE' in raw or 'CREATE UNIQUE INDEX' in raw:
                in_ddl = True
            line = strip_comment(raw)
            if in_ddl:
                # DDL 块在 `""")` 或裸 `)` 收尾
                if '"""' in line or re.match(r'^\s*\)\s*$', line.strip()):
                    in_ddl = False
                continue
            if 'addColumnIfMissing(' in line or not line.strip():
                continue
            kept.append((str(path.relative_to(ROOT)), line))
    return kept


def camel(snake):
    head, *rest = snake.split('_')
    return head + ''.join(w.capitalize() for w in rest)


def main():
    args = sys.argv[1:]
    db = os.path.expanduser(args[args.index('--db') + 1]) if '--db' in args \
        else os.path.expanduser('~/.mangox/mangox.db')
    if not os.path.exists(db):
        print(f'库不存在: {db}')
        return 1

    lines = code_lines_without_ddl()

    def refs(column):
        """→ {相对路径: 命中数}"""
        pat = re.compile(r'\b(?:%s|%s)\b' % (re.escape(column), re.escape(camel(column))))
        hits = defaultdict(int)
        for rel, line in lines:
            n = len(pat.findall(line))
            if n:
                hits[rel] += n
        return dict(hits)

    tables = subprocess.run(
        ['sqlite3', f'file:{db}?mode=ro',
         "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite%' ORDER BY name;"],
        capture_output=True, text=True).stdout.split()

    dead, alive = [], 0
    detail = []
    for table in tables:
        out = subprocess.run(['sqlite3', f'file:{db}?mode=ro', f'PRAGMA table_info("{table}");'],
                             capture_output=True, text=True).stdout.strip()
        for raw in out.split('\n'):
            fields = raw.split('|')
            if len(fields) < 2:
                continue
            column = fields[1]
            hits = refs(column)
            if hits:
                alive += 1
                detail.append((table, column, hits))
            else:
                dead.append((table, column))

    print(f'库: {db}')
    print(f'列总数 {alive + len(dead)}  →  有引用 {alive}  ·  零引用 {len(dead)}\n')
    if dead:
        print('零引用列:')
        for table, column in dead:
            print(f'  {table}.{column}')
    else:
        print('零引用列: (无)')

    # 诚实记: "有引用"不等于"有消费者"。判据用**引用落在哪**近似 —— 一列的引用若绝大部分落在
    # `PersistenceStore.swift` (读出来/写回去), 那它很可能只是存取往返。用比例排, 顺序即嫌疑度。
    #

    print('\n疑似"只有存取往返"的列 (引用集中度排序; `--all` 看全部):')
    scored = []
    for table, column, hits in detail:
        total = sum(hits.values())
        ps = sum(v for k, v in hits.items() if k.endswith('PersistenceStore.swift'))
        scored.append((ps / total, total, len(hits), table, column, hits))
    scored.sort(key=lambda x: (-x[0], x[2]))
    shown = 0
    for ratio, total, files, table, column, hits in scored:
        # 展示门槛: 一半以上引用在持久化层, 或总共就两三处引用 —— 两种都值得人看一眼
        if '--all' not in args and not (ratio >= 0.5 or total <= 3):
            continue
        top = ', '.join(f'{Path(k).name}×{v}' for k, v in sorted(hits.items(), key=lambda kv: -kv[1])[:3])
        more = f' …+{files - 3}' if files > 3 else ''
        print(f'  {table + "." + column:34s} 引用{total:4d} 文件{files:3d} 持久化{ratio:4.0%}  {top}{more}')
        shown += 1
    if not shown:
        print('  (无)')

    names = {c for _, c in dead}
    problems = []
    for c in MUST_BE_DEAD:
        if c not in names:
            problems.append(f'{c} 应当零引用, 但脚本认为它有引用 —— 排除规则失效了')
    for c in MUST_BE_ALIVE:
        if c in names:
            problems.append(f'{c} 不该被判成零引用 —— 扫描器有多余的排除')
    if problems:
        print('\nFAIL - 自检不过, 上面的结论不可信:')
        for p in problems:
            print(f'  · {p}')
        return 1
    print(f'\nOK - 自检通过 (已知死列 {sorted(MUST_BE_DEAD)} 命中, 已知活列 {sorted(MUST_BE_ALIVE)} 未被误判)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
