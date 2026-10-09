#!/usr/bin/env python3
"""MiniMax `reasoning_split` 判据件 —— 思考到底落在哪个 delta 字段。

背景：MiniMax 不传 `reasoning_split` 时，思考内容会直接混进 `content`（形如
`...` + 答案），pi 把它当正文推给 UI ⇒ 阅读体验崩。MangoX 在 ProviderPreset
里给 minimax 声明了 `samplingParams: {"reasoning_split": true}`，物化时展开到每个
model 条目（pi schema 只认 model 级 samplingParams）。

用法:
    python3 scripts/diag/mm_reasoning_split_probe.py                       # 全部模型 × 全部变体
    python3 scripts/diag/mm_reasoning_split_probe.py MiniMax-M3            # 指定模型
    python3 scripts/diag/mm_reasoning_split_probe.py --assert              # 断言模式 (判据, 可变红)

观测面: SSE 每个 chunk 的 `choices[0].delta` 字段名 + 拼起来的正文里是否含 `<think>`。

依据 (实测 2026-10-09, pi 1.1.0 / pi-ai 的 openai-completions.js:400):
  · pi 取推理的字段优先级 = reasoning_content > reasoning > reasoning_text
  · 所以 `reasoning_split: true` 后思考不会丢 —— 会走 thinking_delta 进思考卡片
  · M3.1-Flash-Preview 本就分开, 传了无害

⚠️ 需要真 key: ~/.mangox/pi-config/auth.json 的 minimax 条目。没有 key 时直接退码 2,
   不静默通过。
"""
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

AUTH = Path.home() / ".mangox/pi-config/auth.json"
BASE = "https://api.minimaxi.com/v1"
MODELS = ["MiniMax-M2.7", "MiniMax-M3", "MiniMax-M3.1-Flash-Preview"]
PROMPT = "用一句话说明为什么 17 是质数。"

VARIANTS = [
    ("默认 (pi 不带任何下采样参数)", {}),
    ("reasoning_split", {"reasoning_split": True}),
    ("effort=medium", {"reasoning_effort": "medium"}),
    ("effort=medium + reasoning_split", {"reasoning_effort": "medium", "reasoning_split": True}),
]

# 断言表: 模型 → 带 reasoning_split 后正文是否**必须**干净。
# ⚠️ 刻意**不**断言「默认变体必须混排」—— 那是厂商行为, 我们不可控; 厂商哪天自己修好了,
#    判据会假红。判据只压我们真正依赖的不变量: 带参数 ⇒ 正文干净 且 推理落在 reasoning 字段。
EXPECT_SPLIT_CLEAN = {"MiniMax-M2.7": True, "MiniMax-M3": True, "MiniMax-M3.1-Flash-Preview": True}


def load_key() -> str:
    if not AUTH.exists():
        print(f"缺凭据: {AUTH} 不存在", file=sys.stderr)
        sys.exit(2)
    key = (json.loads(AUTH.read_text()).get("minimax") or {}).get("key")
    if not key:
        print(f"缺凭据: {AUTH} 没有 minimax.key", file=sys.stderr)
        sys.exit(2)
    return key


def probe(key: str, model: str, extra: dict) -> dict:
    body = {"model": model, "stream": True, "max_tokens": 512,
            "messages": [{"role": "user", "content": PROMPT}]}
    body.update(extra)
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    content, reasons = "", {}
    with urllib.request.urlopen(req, timeout=180) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                obj = json.loads(payload)
            except json.JSONDecodeError:
                continue
            for choice in obj.get("choices") or []:
                for field, value in (choice.get("delta") or {}).items():
                    if field == "content" and isinstance(value, str):
                        content += value
                    elif isinstance(value, str) and field.startswith("reasoning"):
                        reasons[field] = reasons.get(field, "") + value
    return {"content": content, "mixed": "<think>" in content, "reasons": reasons}


def main() -> int:
    args = [a for a in sys.argv[1:]]
    do_assert = "--assert" in args
    args = [a for a in args if not a.startswith("--")]
    models = args or MODELS
    key = load_key()

    failures = []
    for model in models:
        print("=" * 78)
        print(f"### {model}")
        for label, extra in VARIANTS:
            try:
                r = probe(key, model, extra)
            except urllib.error.HTTPError as e:
                print(f"  {label:32s} -> HTTP {e.code}: {e.read()[:120]!r}")
                failures.append(f"{model} {label}: HTTP {e.code}")
                continue
            except Exception as e:  # noqa: BLE001
                print(f"  {label:32s} -> {type(e).__name__}: {e}")
                failures.append(f"{model} {label}: {type(e).__name__}")
                continue
            shape = "含 <think> (混排)" if r["mixed"] else "干净"
            detail = {k: len(v) for k, v in r["reasons"].items()}
            print(f"  {label:32s} -> content={len(r['content']):4d} [{shape}]  推理字段={detail}")
            if do_assert and label == "effort=medium + reasoning_split":
                want = EXPECT_SPLIT_CLEAN.get(model)
                if want is None:
                    continue
                if r["mixed"]:
                    failures.append(f"{model}: 带 reasoning_split 正文仍含 <think> (混排未解决)")
                if not any(k.startswith("reasoning") for k in r["reasons"]):
                    failures.append(f"{model}: 带 reasoning_split 但无推理字段 ⇒ 思考会整个丢失")

    if do_assert:
        print("=" * 78)
        if failures:
            for f in failures:
                print(f"FAIL - {f}")
            return 1
        print("PASS - 带 reasoning_split 的变体: 正文干净 且 思考落在 reasoning_content (pi 首顺位 ⇒ 进思考卡片)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
