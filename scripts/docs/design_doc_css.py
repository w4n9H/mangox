#!/usr/bin/env python3
"""把 docs/assets/design-doc.css 同步进各对齐文档的 <style> 块。

    python3 scripts/docs/design_doc_css.py --apply     # 写入
    python3 scripts/docs/design_doc_css.py --check     # 不同步就退码 1
    python3 scripts/docs/design_doc_css.py --apply docs/P13-functional-design.html

为什么是内联而不是 <link>：预览面板只服务单个文件（同级路径返回 403），
外链样式在面板里会静默失效。所以「单一来源」由本脚本保证，而不是由链接保证。
⚠️ 改完 design-doc.css 必须重跑 --apply，否则文档里的副本是旧的。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSS = ROOT / "docs" / "assets" / "design-doc.css"
DOCS = ROOT / "docs"

BEGIN = "<!-- @style:begin · generated from docs/assets/design-doc.css — 请勿手改 -->"
END = "<!-- @style:end -->"
BLOCK = re.compile(
    re.escape(BEGIN) + r"(.*?)" + re.escape(END),
    re.DOTALL,
)


def load_css() -> str:
    if not CSS.exists():
        sys.exit(f"[FAIL] 样式源不存在：{CSS.relative_to(ROOT)}")
    css = CSS.read_text(encoding="utf-8")
    if not css.strip():
        sys.exit("[FAIL] 样式源是空的")
    # 断言：样式源必须是完整文件（挡住"只复制了半截"的写入事故）
    for must in (":root{", "@media (prefers-color-scheme:dark)", "@media (max-width:760px)"):
        if must not in css:
            sys.exit(f"[FAIL] 样式源缺少关键片段 {must!r} —— 疑似被截断")
    return css.rstrip("\n")


def target_files(argv: list[str]) -> list[Path]:
    if argv:
        return [Path(a) if Path(a).is_absolute() else ROOT / a for a in argv]
    return sorted(p for p in DOCS.glob("*.html") if p.is_file())


def render(html: str, css: str) -> str:
    span = BLOCK.search(html)
    if not span:
        raise ValueError("找不到 @style:begin / @style:end 标记")
    return html[: span.start()] + BEGIN + "\n<style>\n" + css + "\n</style>\n" + END + html[span.end():]


def lint(files: list[Path], css: str) -> list[str]:
    """样式契约的三条红线（样式抽出去之后新出现的故障模式）。"""
    declared = set(re.findall(r"\.([a-zA-Z][\w-]*)", css))
    problems = []
    for f in files:
        if not f.exists():
            continue
        rel = f.relative_to(ROOT)
        html = f.read_text(encoding="utf-8")
        body = BLOCK.sub("", html)  # 生成的样式块不参与检查

        # ① 类名闭包：HTML 用到的 class 必须在共享 CSS 里有定义（漏一个 = 静默变裸样式）
        used = {c for m in re.finditer(r'class="([^"]*)"', body) for c in m.group(1).split()}
        unknown = sorted(used - declared)
        if unknown:
            problems.append(f"{rel} 用了共享 CSS 里没有的类名：{', '.join(unknown)}")

        # ② 不许外链样式（预览面板只服务单文件，外链会静默失效）
        if "<link" in body:
            problems.append(f"{rel} 有 <link> —— 外部样式在预览面板里会静默失效")

        # ③ 内联 style 只允许承载"数据"（条宽），其余一律进共享 CSS
        for m in re.finditer(r'style="([^"]*)"', body):
            if not re.fullmatch(r"width:\d+(\.\d+)?%", m.group(1).strip()):
                problems.append(f"{rel} 有非数据的内联 style：{m.group(1)!r}")

    return problems


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    check = "--check" in sys.argv
    apply_ = "--apply" in sys.argv
    if check == apply_:
        sys.exit(__doc__)

    css = load_css()
    files = target_files(args)
    if not files:
        sys.exit("[FAIL] 没有找到任何 docs/*.html")

    stale, bad = [], []
    for f in files:
        rel = f.relative_to(ROOT)
        if not f.exists():
            bad.append(f"{rel} 不存在")
            continue
        html = f.read_text(encoding="utf-8")
        try:
            out = render(html, css)
        except ValueError as e:
            bad.append(f"{rel}：{e}")
            continue
        if out == html:
            print(f"  ✓ {rel} 已同步（{len(html)} 字符）")
            continue
        stale.append(rel)
        if apply_:
            f.write_text(out, encoding="utf-8")
            print(f"  → {rel} 已更新（{len(html)} → {len(out)} 字符，样式 {len(css)} 字符）")
        else:
            print(f"  ✗ {rel} 样式副本与 design-doc.css 不一致")

    problems = lint(files, css)
    for p in problems:
        print(f"  ! {p}")
    for b in bad:
        print(f"  ! {b}")

    failed = bool(bad or problems or (check and stale))
    if failed:
        if stale and check:
            print("\n[FAIL] 有文档的样式副本过期 —— 跑 python3 scripts/docs/design_doc_css.py --apply")
        if problems:
            print("\n[FAIL] 违反了样式契约（见 docs/must_read.txt §D）")
        if bad:
            print("\n[FAIL] 有文档缺少 @style 标记或文件不存在")
        return 1

    print(f"\n[OK] {len(files)} 个文档 · 样式源 {len(css)} 字符 · 类名闭包 ✓ · 无外链 · 内联 style 仅承载数据")
    return 0


if __name__ == "__main__":
    sys.exit(main())
