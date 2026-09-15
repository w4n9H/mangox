#!/usr/bin/env python3
"""P7-M3.5: 从 models.dev api.json 生成 MangoX 内置模型目录快照。
用法: python3 scripts/gen-model-catalog.py [modelsdev.json] [输出路径]
默认输入 /tmp/p7exp/modelsdev.json (curl https://models.dev/api.json), 输出 mangox/Resources/model-catalog.json。
裁剪: provider 收敛到已知面 (免 4.6MB 全量入库), 模型字段只留查找所需。
"""
import json, sys, os

CURATED = [
    "deepseek", "minimax", "openai", "anthropic", "moonshotai", "zai", "qwen",
    "ollama", "openrouter", "google", "xai", "mistral", "groq", "together",
    "deepinfra", "fireworks-ai", "venice", "chutes", "nanogpt", "bailian",
]

def prune_model(m):
    out = {}
    if m.get("name"): out["name"] = m["name"]
    out["reasoning"] = bool(m.get("reasoning"))
    limit = m.get("limit") or {}
    if limit.get("context"): out["contextWindow"] = limit["context"]
    if limit.get("output"): out["maxTokens"] = limit["output"]
    mod = (m.get("modalities") or {}).get("input")
    if mod: out["input"] = mod
    cost = m.get("cost")
    if isinstance(cost, dict) and "input" in cost:
        out["cost"] = {
            "input": cost.get("input", 0), "output": cost.get("output", 0),
            "cacheRead": cost.get("cache_read", 0), "cacheWrite": cost.get("cache_write", 0),
        }
    return out

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/p7exp/modelsdev.json"
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "mangox", "Resources", "model-catalog.json")
    raw = json.load(open(src))
    out = {}
    for key in CURATED:
        p = raw.get(key)
        if not p:
            print(f"WARN: provider '{key}' 不在 models.dev (跳过)")
            continue
        models = {mid: prune_model(m) for mid, m in (p.get("models") or {}).items()}
        if models:
            out[key] = {"models": models}
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    json.dump(out, open(dst, "w"), ensure_ascii=False, separators=(",", ":"))
    total = sum(len(v["models"]) for v in out.values())
    print(f"OK {dst} providers={len(out)} models={total} size={os.path.getsize(dst)}")

if __name__ == "__main__":
    main()
