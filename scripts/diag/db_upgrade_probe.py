#!/usr/bin/env python3
r"""L2 真库升级 + 旧会话回放 —— 在**真库的副本**上跑, 全程不碰 `~/.mangox/mangox.db`。

跑法: `python3 scripts/diag/db_upgrade_probe.py`

## 它测什么 (四件机器能判的事)

1. **升级**: 把副本的 `mailbox_sentinels` 退回**升级前形态** (删掉 `provider` / `model_id` /
   `thinking_level` 三列), 再用 `PersistenceStore(path:)` 打开 ⇒ `migrate()` 应补回三列,
   且**三列写读闭环** (写完读出来还是那个值)。这是今天唯一动过的落库结构。
2. **旧会话回放**: 把真库里每个会话的事件流全重放一遍, 数工具卡数 —— 与**直接从 `payload`
   JSON 里数出来的工具块数**逐一对齐。不等就说明有毒载荷把整条消息吞了 (解码失败会
   `dropReplayCache` + 丢弃整条, 而不是报错)。
3. **陌生 kind 降级**: 往副本里插一条**被改过 `kind` 的老载荷** (`"kind":"web_search"`),
   重放后应出现 `kind == .other` 的卡 —— 且**同一条会话的其他消息一条不少** (不能把整条搞崩)。
4. **老载荷无 `imagePaths`**: 老卡必须全部解出空数组 (新加的字段不许把老数据读崩)。

## ⚠️ 为什么要副本 + 为什么要把三列退回去

真库今天已被 App 打开过 ⇒ 迁移**可能已经跑过了**, 直接测就成了"测一个已经升过级的库",
什么也证明不了。所以退回旧形态再升 —— 这样每次跑都是真的升级路径。
"""

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
HOME = os.path.expanduser('~')
SRC_DB = os.path.join(HOME, '.mangox', 'mangox.db')
WORK = '/tmp/mangox-l2'
DB = os.path.join(WORK, 'mangox.db')

NEW_COLUMNS = ['provider', 'model_id', 'thinking_level']


def copy_real_db():
    os.makedirs(WORK, exist_ok=True)
    for suffix in ['', '-wal', '-shm']:
        src = SRC_DB + suffix
        if os.path.exists(src):
            shutil.copy2(src, DB + suffix)
            print('  拷入 %s (%d 字节)' % (os.path.basename(src), os.path.getsize(src)))


def count_tool_blocks(obj):
    """递归数「含字符串 kind 的 dict」= ToolCall 块; 同时数缺 imagePaths 的。"""
    total = missing = 0
    if isinstance(obj, dict):
        if isinstance(obj.get('kind'), str):
            total += 1
            if 'imagePaths' not in obj:
                missing += 1
        for v in obj.values():
            a, b = count_tool_blocks(v)
            total += a
            missing += b
    elif isinstance(obj, list):
        for v in obj:
            a, b = count_tool_blocks(v)
            total += a
            missing += b
    return total, missing


def downgrade_schema(conn):
    """把 mailbox_sentinels 退回升级前形态 (不含三列); 已是旧形态则原样返回。"""
    cols = [r[1] for r in conn.execute('PRAGMA table_info(mailbox_sentinels)')]
    print('  mailbox_sentinels 升级前(拷贝现状) 列: %s' % ', '.join(cols))
    if not any(c in cols for c in NEW_COLUMNS):
        print('  → 本来就是旧形态, 直接拿它当"升级前"')
        return cols
    keep = [c for c in cols if c not in NEW_COLUMNS]
    conn.execute('PRAGMA foreign_keys=OFF')
    conn.execute('ALTER TABLE mailbox_sentinels RENAME TO mailbox_sentinels_old')
    # 复刻旧形态: 用原 DDL 里去掉三列
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='mailbox_sentinels_old'"
    ).fetchone()[0]
    old_ddl = ddl.replace('mailbox_sentinels_old', 'mailbox_sentinels')
    for c in NEW_COLUMNS:
        old_ddl = re.sub(r',\s*\n?\s*%s[^,)]*' % c, '', old_ddl)
    conn.execute(old_ddl)
    conn.execute('INSERT INTO mailbox_sentinels (%s) SELECT %s FROM mailbox_sentinels_old'
                 % (', '.join(keep), ', '.join(keep)))
    conn.execute('DROP TABLE mailbox_sentinels_old')
    conn.commit()
    print('  → 退回旧形态, 保留列: %s' % ', '.join(keep))
    return keep


def main():
    if not os.path.exists(SRC_DB):
        print('FAIL - 真库不存在: %s' % SRC_DB)
        return 1
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    print('① 拷贝真库到 %s (只读真库)' % WORK)
    copy_real_db()

    print('② 检查 / 退回升级前的 schema')
    conn = sqlite3.connect(DB)
    downgrade_schema(conn)

    print('③ 数一遍真库里的会话 / 事件 / 工具块')
    all_sessions = [r[0] for r in conn.execute('SELECT id FROM sessions')]
    # ⚠️ 口径必须与 `loadChats()` 对齐: 它只取 `project_id IS NULL` 的会话 (顶层会话);
    # 项目内的会话不在这条路上。不对齐就会得出"重放丢了一半消息"这种假警报。
    sessions = [r[0] for r in conn.execute('SELECT id FROM sessions WHERE project_id IS NULL')]
    sid_set = set(sessions)
    rows = list(conn.execute('SELECT session_id, seq, type, payload FROM events ORDER BY seq ASC'))
    tool_blocks = missing_imagepaths = message_events = all_tool_blocks = 0
    for sid, _seq, typ, payload in rows:
        if typ != 'message':
            continue
        try:
            obj = json.loads(payload)
        except Exception:
            continue
        a, b = count_tool_blocks(obj)
        all_tool_blocks += a
        if sid not in sid_set:
            continue          # 项目内会话: `loadChats()` 看不见, 不进对齐
        message_events += 1
        tool_blocks += a
        missing_imagepaths += b
    print('  会话 %d 条 (其中顶层 %d 条 = `loadChats()` 的口径) · 事件 %d · 全库工具块 %d'
          % (len(all_sessions), len(sessions), len(rows), all_tool_blocks))
    print('  顶层会话: message 事件 %d · 工具块 %d (其中缺 imagePaths %d)'
          % (message_events, tool_blocks, missing_imagepaths))
    if tool_blocks == 0:
        print('FAIL - 顶层会话里一个工具块都没有, 回放断言会空转 ⇒ 直接退出')
        conn.close()
        return 1

    print('④ 注入一条"改了 kind 的老载荷" (模拟扩展工具)')
    target_sid, target_seq, target_payload = None, None, None
    for sid, seq, typ, payload in rows:
        if typ != 'message' or sid not in sid_set:
            continue
        if re.search(r'"kind":"bash"', payload):
            target_sid, target_seq, target_payload = sid, seq, payload
            break
    if target_payload is None:
        print('FAIL - 没找到含 "kind":"bash" 的老载荷, 无法注入')
        conn.close()
        return 1
    patched = re.sub(r'"kind":"bash"', '"kind":"web_search"', target_payload, count=1)
    next_seq = conn.execute('SELECT COALESCE(MAX(seq),0)+1 FROM events WHERE session_id = ?',
                            (target_sid,)).fetchone()[0]
    conn.execute('INSERT INTO events (session_id, seq, type, payload, ts) VALUES (?,?,?,?,?)',
                 (target_sid, next_seq, 'message', patched, time.time()))
    conn.commit()
    # 注入后**重新数一遍** —— 别手算 +1: 还要看那条被改写的老载荷有没有 `imagePaths` 键
    tool_blocks = blocks_with_key = 0
    for sid, _seq, typ, payload in conn.execute(
            'SELECT session_id, seq, type, payload FROM events ORDER BY seq ASC'):
        if typ != 'message' or sid not in sid_set:
            continue
        try:
            obj = json.loads(payload)
        except Exception:
            continue
        a, b = count_tool_blocks(obj)
        tool_blocks += a
        blocks_with_key += a - b
    print('  已注入到会话 %s (seq %d) ⇒ 工具块 %d 个, 其中落库时就带 imagePaths 键 %d 个'
          % (target_sid[:8], next_seq, tool_blocks, blocks_with_key))

    print('⑤ 关掉连接, 交给 Swift 探针 (它一 open 就会 migrate)')
    conn.close()

    probe = os.path.join(WORK, 'main.swift')
    with open(probe, 'w', encoding='utf-8') as handle:
        handle.write(SWIFT_MAIN)

    sources = []
    for base, _dirs, files in os.walk(os.path.join(ROOT, 'mangox')):
        for f in files:
            if f.endswith('.swift') and f != 'mangoxApp.swift':
                sources.append(os.path.join(base, f))
    sources.sort()

    sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                         capture_output=True, text=True).stdout.strip()
    binary = os.path.join(WORK, 'probe')
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app')
    cmd = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64-apple-macos14.0', '-D', 'DEBUG',
           '-o', binary, probe] + sources
    built = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True, env=env)
    if built.returncode != 0:
        print('FAIL - 探针编译失败')
        print((built.stdout or built.stderr)[-4000:])
        return 1

    ran = subprocess.run([binary, DB, str(tool_blocks), target_sid, str(blocks_with_key)],
                         capture_output=True, text=True)
    for line in ran.stdout.splitlines():
        if 'CoreText note' in line or 'CTFontLogSystemFontNameRequest' in line:
            continue
        print('  ' + line)

    print('⑥ 复查副本: 迁移后三列是否补回')
    conn = sqlite3.connect(DB)
    cols = [r[1] for r in conn.execute('PRAGMA table_info(mailbox_sentinels)')]
    ok = all(c in cols for c in NEW_COLUMNS)
    conn.close()
    print('  %s 三列已补回: %s' % ('PASS -' if ok else 'FAIL -', ', '.join(cols)))

    if ran.returncode != 0:
        print((ran.stderr or '')[-2000:])
    return ran.returncode if ran.returncode != 0 else (0 if ok else 1)


SWIFT_MAIN = r'''
import Foundation

var fails = 0
func check(_ ok: Bool, _ msg: String) {
    print((ok ? "PASS - " : "FAIL - ") + msg)
    if !ok { fails += 1 }
}

    let args = CommandLine.arguments
    let dbPath = args[1]
    let expectTools = Int(args[2]) ?? -1
    let injectedSession = args[3]
    let expectWithKey = Int(args[4]) ?? -1

MainActor.assumeIsolated {
    let store: PersistenceStore
    do {
        store = try PersistenceStore(path: dbPath)
        // ⚠️ `init` **不调** `migrate()` —— 迁移是调用方显式做的 (App 里由启动路径做)。
        // 探针自己漏了这一步, 会得出"迁移没补列"这种假警报 (实测踩过)。
        try store.migrate()
    } catch {
        print("FAIL - 打不开/迁移副本失败: \(error)")
        exit(2)
    }

    // ① 升级: 三列写读闭环 (migrate 若没补列, 这里写就会抛)
    let sentinelId = UUID()
    var sentinel = MailboxSentinel(name: "L2 升级探针", accountId: UUID())
    sentinel.id = sentinelId
    sentinel.provider = "minimax"
    sentinel.modelId = "MiniMax-M3"
    sentinel.thinkingLevel = "high"
    do {
        try store.upsertMailboxSentinel(sentinel)
    } catch {
        check(false, "L2 升级: 写入哨兵失败 (\(error))")
    }
    let back = (try? store.loadMailboxSentinels())?.first { $0.id == sentinelId }
    check(back?.provider == "minimax" && back?.modelId == "MiniMax-M3"
          && back?.thinkingLevel == "high",
          "L2 升级: 三列写读闭环 provider/modelId/thinkingLevel (读到 "
          + "\(back?.provider ?? "nil")/\(back?.modelId ?? "nil")/\(back?.thinkingLevel ?? "nil"))")
    try? store.deleteMailboxSentinel(id: sentinelId)

    // ② 旧会话回放: 工具卡数必须与"从 payload 直接数出来的块数"逐一对齐
    let chats = (try? store.loadChats()) ?? []
    var messages = 0, tools = 0, withImages = 0
    var kinds: [String: Int] = [:]
    var injectedOthers = 0
    for chat in chats {
        let list = (try? store.loadMessages(sessionId: chat.id)) ?? []
        messages += list.count
        for m in list {
            guard case .tool(let t) = m.content else { continue }
            tools += 1
            kinds[t.kind.rawValue, default: 0] += 1
            if !t.imagePaths.isEmpty { withImages += 1 }
            if chat.id.uuidString.lowercased() == injectedSession.lowercased()
                && t.kind == .other { injectedOthers += 1 }
        }
    }
    check(!chats.isEmpty, "L2 回放: 真库会话 \(chats.count) 条 / 重放消息 \(messages) 条")
    check(tools == expectTools,
          "L2 回放: 工具卡 \(tools) 张 == payload 里的工具块 \(expectTools) 个"
          + (tools == expectTools ? "" : "  ← 不等说明有毒载荷把整条消息吞了"))
    // 带图卡只能来自"落库时就写了 imagePaths 的载荷" —— 老载荷 (无该键) 解出空数组,
    // 这条不变式把"新字段没把老数据读成别的东西"钉住。
    check(withImages <= expectWithKey,
          "L2 回放: 带图卡 \(withImages) 张 ≤ 载荷里本就带 imagePaths 的 \(expectWithKey) 张")
    check(injectedOthers >= 1,
          "L2 降级: 注入的陌生 kind 重放成 .other (命中 \(injectedOthers) 张卡)")

    // ③ 手写 JSON 直解: 陌生 kind + 缺 imagePaths 的老载荷形状
    let legacy = """
    {"id":"11111111-1111-1111-1111-111111111111","kind":"web_search",
     "title":"web_search","details":[{"key":"query","value":"渠道日活"}],
     "phase":{"queued":{}}}
    """
    let decoded = try? JSONDecoder().decode(ToolCall.self, from: Data(legacy.utf8))
    check(decoded?.kind == .other, "L2 解码: 陌生 kind 落 .other (实得 \(decoded?.kind.rawValue ?? "解码失败"))")
    check(decoded?.imagePaths.isEmpty == true, "L2 解码: 缺 imagePaths 的老载荷解出 []")
    check(decoded?.title == "web_search", "L2 解码: 真名仍在 title (不被降级吃掉)")

    // ④ 新载荷 round-trip: 带图片的卡落库再读出
    let sid = chats.first?.id ?? UUID()
    let imgTool = ToolCall(kind: .other, title: "web_search", command: "query=x",
                           details: [ToolDetail("输出", "ok")], phase: .done,
                           durationMs: 12, imagePaths: ["/tmp/l2-shot.png"])
    let msg = ChatMessage(role: .assistant, content: .tool(imgTool), isStreaming: false)
    do {
        try store.appendMessageEvent(sessionId: sid, msg)
        let replayed = (try? store.loadMessages(sessionId: sid)) ?? []
        let hit = replayed.first { if case .tool(let t) = $0.content { return t.id == imgTool.id } else { return false } }
        var gotImages: [String] = []
        if case .tool(let t)? = hit?.content { gotImages = t.imagePaths }
        check(gotImages == ["/tmp/l2-shot.png"],
              "L2 落库: imagePaths 经真库 round-trip 原样回来 (实得 \(gotImages))")
    } catch {
        check(false, "L2 落库: 写入失败 (\(error))")
    }

    print("  [报告] kind 分布: " + kinds.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    print(fails == 0 ? "ALL PASS" : "\(fails) 条 FAIL")
    exit(fails == 0 ? 0 : 1)
}
'''


if __name__ == '__main__':
    sys.exit(main())
