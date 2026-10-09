#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
工具面探针 —— 看**模型实际收到的工具声明**里有没有某个工具。

为什么需要它（P13 立项时的实测教训）：
  pi 对"不存在的工具名"**不吭声** —— `--tools read,bash,zzz_nope` 与 `--tools +codemode`
  在没加载扩展时都零 stderr、`get_state` 照样 success。⇒ stderr 通道分辨不出来。
  换可观测面：pi 1.0 起**系统提示会作为 session entry 落进 transcript**，
  而工具声明就在系统提示里。于是：发一条 prompt（PI_OFFLINE=1 让模型调用失败，
  但请求已经组装完毕）→ `get_entries` 读回来 → 在 JSON 里找工具名。

用法:
  scripts/diag/tool_surface_probe.py              # 跑内置的对照三组 (P13 场景)
  scripts/diag/tool_surface_probe.py --marker codemode
  scripts/diag/tool_surface_probe.py --args "--no-extensions" "--extension" "builtin:codemode" --tools +codemode

判读:
  ① 阳性对照 = 声明里的 `bash` / `read`（若连它都 0 命中，说明这条通道不可用）
  ② 关注**唯一短语**而不是工具名本身 —— 工具名可能作为"文档路径"等无关文字出现
     （实测：基线里 `codemode` 命中 2 次，两次都只是 `docs/codemode.md` 这句文档清单）
"""
import argparse
import json
import os
import subprocess
import threading
import time

PI_CANDIDATES = ["/opt/homebrew/bin/pi", "/usr/local/bin/pi"]

# 与工具声明同源的唯一短语：出现即证明"声明本体"在，而不是无关提及。
# ⚠️ 只放**会出现在声明里**的短语 —— `Script completed` 是脚本**结果**的格式，不在
# `codemode` 的工具描述中，放进来的话会永远显示 0，是误导性标记（实测确认后剔除）。
UNIQUE_PHRASES = {
    "codemode": ["searchTools", "ALL_TOOLS", "QuickJS",
                 "describeNamespace", "@options"],
}

POSITIVE_CONTROLS = ["bash", "read"]


def find_pi():
    for c in PI_CANDIDATES:
        if os.path.exists(c):
            return c
    raise SystemExit("找不到 pi，改 PI_CANDIDATES")


def probe(pi, extra_args, marker, wait=20.0, verbose=True):
    env = dict(os.environ)
    env.pop("NODE_OPTIONS", None)   # 剥掉宿主 fs shim（会伪造 EEXIST 告警）
    env["PI_OFFLINE"] = "1"         # 不发真模型请求（请求仍会被组装）

    out, err = [], []
    p = subprocess.Popen([pi] + extra_args + ["--no-session"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, cwd=os.path.expanduser("~"),
                         env=env, text=True, bufsize=1)

    def pump(stream, sink):
        for line in stream:
            sink.append(line.rstrip("\n"))

    for t in (threading.Thread(target=pump, args=(p.stdout, out), daemon=True),
              threading.Thread(target=pump, args=(p.stderr, err), daemon=True)):
        t.start()

    def send(obj):
        try:
            p.stdin.write(json.dumps(obj) + "\n")
            p.stdin.flush()
        except Exception:
            pass

    send({"id": "1", "type": "prompt", "message": "hi"})
    time.sleep(wait)
    send({"id": "2", "type": "get_entries"})

    raw, deadline = None, time.time() + 8
    while time.time() < deadline:
        for line in list(out):
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("id") == "2":
                raw = json.dumps(obj, ensure_ascii=False)
        if raw:
            break

    try:
        p.terminate(); p.wait(timeout=3)
    except Exception:
        p.kill()

    result = {"marker": marker, "raw_len": len(raw or ""), "hits": {}, "phrases": {},
              "stderr": err}
    if raw:
        result["hits"] = {k: raw.count(k) for k in POSITIVE_CONTROLS + [marker]}
        result["phrases"] = {ph: raw.count(ph) for ph in UNIQUE_PHRASES.get(marker, [])}
    if verbose:
        print("─" * 74)
        print("args     : %s" % " ".join(extra_args))
        if not raw:
            print("get_entries 无响应 ⇒ 这条通道不可用")
            for l in out[:4]:
                print("   out: %s" % l[:200])
            for l in err[:4]:
                print("   err: %s" % l[:200])
        else:
            print("transcript 长度 = %d 字符" % len(raw))
            print("命中      : %s" % result["hits"])
            if result["phrases"]:
                print("唯一短语  : %s" % result["phrases"])
            if err:
                print("stderr(%d): %s" % (len(err), err[0][:160]))
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--marker", default="codemode", help="要查的工具名")
    ap.add_argument("--args", nargs=argparse.REMAINDER,
                    help="自定义 spawn 参数（给全，含 --no-extensions 等）")
    ap.add_argument("--wait", type=float, default=20.0, help="prompt 后等多久读 entries")
    a = ap.parse_args()

    pi = find_pi()
    print("pi = %s" % pi)

    if a.args:
        probe(pi, a.args, a.marker, wait=a.wait)
        return

    # 内置对照三组（P13 场景；审批扩展可能不存在，缺了也不影响结论）
    approval = os.path.expanduser("~/.mangox/extensions/mangox-approval.ts")
    base = ["--mode", "rpc", "--no-extensions", "--extension", "builtin:llama.cpp"]
    if os.path.exists(approval):
        base += ["--extension", approval]
    else:
        print("! 提示: 审批扩展不在 %s（不影响本探针结论）" % approval)

    print("\n三组对照：B 基线 / C 只加 --tools / D 再加 -e builtin:codemode")
    print("判据: C 与 B 应当**完全相同**（+codemode 在扩展没加载时是空操作）；D 应当显著多出声明本体。\n")
    rb = probe(pi, base, a.marker, wait=a.wait)
    rc = probe(pi, base + ["--tools", "+" + a.marker], a.marker, wait=a.wait)
    rd = probe(pi, base + ["--extension", "builtin:" + a.marker, "--tools", "+" + a.marker],
               a.marker, wait=a.wait)

    print("═" * 74)
    print("汇总：")
    for tag, r in (("B 基线", rb), ("C 只加 --tools", rc), ("D 加 -e builtin:", rd)):
        pv = [v for v in r["phrases"].values()]
        print("  %-16s 命中 %s  唯一短语合计 %s" % (tag, r["hits"], sum(pv)))
    print("\n结论判据：C 命中数 == B 命中数 ⇒ `--tools +<name>` 单独用无效，必须显式 -e builtin:<name>")


if __name__ == "__main__":
    main()
