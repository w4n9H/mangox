#!/usr/bin/env python3
"""IMAP 只读探针 —— 直接问真服务器, 别猜客户端发了什么。

何时用它 (三条, 全是 curl 通道"看不见"的场合):
  1. **接新服务商 / 换账号先体检**: 命令序列能不能过 (网易系要 `SELECT` 前发 `ID`, curl 做不到),
     垃圾箱目录真名是什么 (`LIST "" "*"`), 响应形态与 `MimeParser` 的假设是否一致。
  2. **取信异常分诊**: 一次分清"坐标系错位 / 邮件真的不在 / 服务器不收"。
  3. **网易系 `openssl s_client` 通道**落地时验证 —— curl 根本到不了 `SELECT`, 只有裸 IMAP 能证。
  反过来说: 只想知道"能不能登录"用 app 里的「测试连接」, 不用起探针。

已用它定过案的例子 (2026-09-20) —— 取信链路的坐标系错位:
  SELECT INBOX      → * 1 EXISTS · [UIDNEXT 97]      ← 信箱只 1 封, 其 UID 是 96
  SEARCH UNSEEN     → * SEARCH 1                     ← 裸 SEARCH 返回**消息序号**
  UID SEARCH UNSEEN → * SEARCH 96                    ← `UID SEARCH` 才返回 **UID**
于是 `UID FETCH 1 BODY[]` 必然取空 (UID 1 不存在) → 服务器回 NO → curl `(78)`。

用法:
    AUTH=$(security find-generic-password -s com.mangox.mailbox \
             -a "mailbox.acct.<账号 UUID>.auth" -w)
    IMAP_AUTH="$AUTH" python3 scripts/diag/imap_probe.py imap.qq.com:993 mango.z@qq.com
    unset AUTH IMAP_AUTH

安全纪律 (改这个脚本时别破):
  1. 凭据**只**从环境变量 `IMAP_AUTH` 读, 且**任何输出都过 redact()** —— 不进终端/日志/截图。
  2. 全程只读: 只用 `BODY.PEEK[]` (不置 \\Seen), **绝不**发 STORE / COPY / EXPUNGE / APPEND。
     唯一例外是 `--copy` 探针 (默认关), 仅用于确认垃圾箱目录名存在。
  3. 探针会连真服务器并 SELECT 收件箱 —— 别在哨兵正轮询时跑 (本身无副作用, 但可能读到中间态)。
"""
import os
import socket
import ssl
import sys

TARGET = sys.argv[1] if len(sys.argv) > 1 else "imap.qq.com:993"
USER = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("IMAP_USER", "")
AUTH = os.environ.get("IMAP_AUTH", "")
CAFILE = "/etc/ssl/cert.pem"
DO_COPY = "--copy" in sys.argv   # 仅在需要确认垃圾箱目录名时开

if not USER or not AUTH:
    sys.exit("需要 IMAP_AUTH 环境变量与 <user> 参数 (见文件头用法)")

HOST, _, PORT = TARGET.partition(":")
PORT = int(PORT or "993")


def redact(text: str) -> str:
    return text.replace(AUTH, "***") if AUTH else text


ctx = ssl.create_default_context(cafile=CAFILE)
sock = ctx.wrap_socket(
    socket.create_connection((HOST, PORT), timeout=20), server_hostname=HOST)
sock.settimeout(10)

counter = [0]


def drain(cap: int = 900) -> bytes:
    """读到安静为止 (0.5s 无数据)。字面量一并读进来, 只印前 cap 字节。"""
    buf = b""
    while True:
        try:
            chunk = sock.recv(65536)
        except (socket.timeout, ssl.SSLWantReadError):
            break
        if not chunk:
            break
        buf += chunk
        sock.settimeout(0.5)
    sock.settimeout(10)
    shown = redact(buf.decode("utf-8", "replace"))
    print("  S: " + shown[:cap].replace("\r\n", "\n     ").strip())
    if len(buf) > cap:
        print("  S: …(共 %d 字节)" % len(buf))
    return buf


def send(command: str, label: str) -> bytes:
    counter[0] += 1
    tag = "a%d" % counter[0]
    print("C: %s %s" % (tag, label))
    sock.sendall(("%s %s\r\n" % (tag, command)).encode("utf-8"))
    return drain()


print("=== %s:%d  as %s ===" % (HOST, PORT, USER))
print("S: " + redact(drain().decode("utf-8", "replace")).strip())

send('LOGIN "%s" "%s"' % (USER, AUTH), 'LOGIN "<user>" "<auth 已隐去>"')
send("SELECT INBOX", "SELECT INBOX")
send('LIST "" "*"', 'LIST "" "*"   ← 服务端命名空间 (垃圾箱真名在这里)')

# 成对发: "我们以为的命令" vs "正确命令" —— 差异自己跳出来
send("SEARCH UNSEEN", "SEARCH UNSEEN       ← 裸 SEARCH = 消息序号")
uid_out = send("UID SEARCH UNSEEN", "UID SEARCH UNSEEN    ← MangoX 实际用的 (返 UID)")
first_uid = None
for token in uid_out.split(b"* SEARCH")[-1].split():
    if token.isdigit():
        first_uid = token.decode()
        break

if first_uid:
    send("UID FETCH %s BODY.PEEK[]" % first_uid,
         "UID FETCH %s BODY.PEEK[]   ← 取信 (PEEK, 不置已读)" % first_uid)
else:
    print("(收件箱无未读信, 跳过 FETCH)")

if DO_COPY and first_uid:
    # 唯一允许的写操作, 默认关; 只为确认垃圾箱目录名存在 (会留下一个副本, 记得手动删)
    send('UID COPY %s "Deleted Messages"' % first_uid, 'UID COPY → "Deleted Messages" (写操作!)')

send("LOGOUT", "LOGOUT")
print("\n完成")
