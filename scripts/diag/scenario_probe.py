#!/usr/bin/env python3
"""
scenario_probe.py —— P19 **场景回归**执行器（2026-11-04，boss 定）

为什么要有它：最近几个版本一直在给 computer use 加 op（`open` / `confirm` …），
根因是**我们拿 op 当测试单位**，于是每撞一次墙就多一个动作。真正该当测试单位的是
**场景**——"人一天里会做的那些事"。这个文件就是那批场景的可执行版本。

它走的是**产品路径**，不是另写一套：
  真 `mangox-compute` 子进程 → 真 unix socket → 真 JSON 协议（`ComputerProtocol.swift`）
  ⇒ 断言到的东西就是模型看到的东西（回执原文、编号、截断提示），不是近似实现。

⚠️ 它**不进 CI**：要真人桌面、真 App、真辅助功能授权，而且会改用户数据（自带清理）。
   定位是诊断工具，与 `ax_coverage_probe.sh` 同类。

用法:
    bash scripts/diag/scenario_probe.sh                 # 跑全部场景
    bash scripts/diag/scenario_probe.sh 日历            # 只跑名字含「日历」的
    bash scripts/diag/scenario_probe.sh --dump 备忘录   # 只读一次，把行全打出来（写判据用）

退出码: 0 = 全过 · 1 = 有失败
"""

import datetime
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

HELPER = os.environ.get("SCENARIO_HELPER", "build/Debug/mangox-compute")
CLEANUP = os.environ.get("SCENARIO_CLEANUP", os.path.expanduser("~/.mangox/bin/scenario-cleanup"))
MARKER = "【场景测试】"

APPS = {
    "日历": "com.apple.iCal",
    "备忘录": "com.apple.Notes",
    "提醒事项": "com.apple.reminders",
    "访达": "com.apple.finder",
    "Safari": "com.apple.Safari",
}

#: 小月历格子标题里的中文月名 → 数字。`group "月历区域"` 用的是阿拉伯数字（`2026年11月`），
#: 两处不同源，比之前必须先归一（踩过一次：`"十一月" != "11月"` 恒真）。
CN_MONTH = {"一月": 1, "二月": 2, "三月": 3, "四月": 4, "五月": 5, "六月": 6,
            "七月": 7, "八月": 8, "九月": 9, "十月": 10, "十一月": 11, "十二月": 12}


# ── 协议 ────────────────────────────────────────────────────────────────────

class Session:
    """一个真 helper 子进程 + 一条真 socket。"""

    #: 一条请求最多等多久(秒)。
    #:
    #: ⚠️ **没有这个数, 这个工具会挂死**（2026-11-04 实测: 跑全套时整支脚本卡住, 只能手杀）。
    #:    helper 是单线程串行, 而 `AXUIElementCopyAttributeValue` 在目标 App 无响应时会**无限
    #:    挂住** —— `AXAdapter.readTimeout` 只是**协作式**(每节点查一次 deadline), 挡不住
    #:    "某一个属性调用本身不返回"。所以超时必须落在**这一侧**: 等不到就杀掉helper、报出来。
    #:    12 秒是 helper 内部的读取预算, 40 = 它 + 重读一次 + 余量。
    REQUEST_TIMEOUT = 40

    def __init__(self, bundles):
        self.dir = tempfile.mkdtemp(prefix="mx-scn-")
        path = os.path.join(self.dir, "c.sock")
        env = dict(os.environ)
        env["MANGOX_COMPUTE_PEER_PID"] = str(os.getpid())
        env["MANGOX_COMPUTE_PARENT_PID"] = str(os.getpid())
        env["MANGOX_COMPUTE_ALLOWED_BUNDLES"] = ",".join(bundles)
        env["MANGOX_COMPUTE_ACT_BUNDLES"] = ",".join(bundles)
        # 图像面**故意不给**：场景要验的是"文本读得够不够"，给了截图会把问题盖住。
        self.proc = subprocess.Popen([HELPER, path], env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(80):
            if os.path.exists(path):
                break
            if self.proc.poll() is not None:
                raise SystemExit("helper 起不来: " + self.proc.stderr.read().decode(errors="replace"))
            time.sleep(0.1)
        else:
            raise SystemExit("helper 没建出 socket")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.f = self.sock.makefile("rwb")
        pong = self.req({"op": "ping"})
        if not pong.get("trusted"):
            raise SystemExit("helper 没有辅助功能权限 —— 先在系统设置里给终端/WorkBuddy 授权")

    def req(self, obj):
        self.sock.settimeout(self.REQUEST_TIMEOUT)
        self.f.write((json.dumps(obj, ensure_ascii=False) + "\n").encode())
        self.f.flush()
        try:
            line = self.f.readline()
        except (socket.timeout, OSError) as e:
            # 这里**必须炸掉整支脚本**: helper 已经卡在某个 AX 调用上, 后面的场景全都会排队等它,
            # 硬撑下去只会得到一串"没反应", 而真正的原因(哪个 App / 哪一步)被埋掉。
            self.proc.kill()
            raise SystemExit(
                "helper 在 %d 秒内没有回应(%s %s) ⇒ 已杀掉。"
                " 多半是目标 App 把某一个 AX 调用挂住了(helper 是单线程, 一个卡住全卡)。"
                % (self.REQUEST_TIMEOUT, obj.get("op"), obj.get("app") or "")) from e
        if not line:
            raise SystemExit("helper 关掉了连接（崩了？）")
        return json.loads(line.decode())

    def close(self):
        try:
            self.f.close()
            self.sock.close()
        finally:
            self.proc.terminate()


# ── 渲染文本 → 行 ───────────────────────────────────────────────────────────

ROW = re.compile(
    r'^(?P<indent>\s*)\[(?P<n>\d+)\]\s+(?P<role>[a-z]+)'
    r'(?:\s+"(?P<title>[^"]*)")?'
    r'(?:\s+\(值:"(?P<value>[^"]*)"\))?'
    r'(?:\s+\((?P<x>-?\d+),(?P<y>-?\d+)\s+(?P<w>\d+)×(?P<h>\d+)\))?\s*$'
)


def parse_rows(text):
    out = []
    for line in text.split("\n"):
        m = ROW.match(line)
        if not m:
            continue
        out.append({
            "number": int(m.group("n")),
            "role": m.group("role"),
            "title": m.group("title") or "",
            "value": m.group("value") or "",
            "frame": (int(m.group("x")), int(m.group("y")), int(m.group("w")), int(m.group("h")))
            if m.group("x") is not None else None,
            "indent": len(m.group("indent")) // 2,
        })
    return out


class Fail(Exception):
    pass


class Skip(Exception):
    """场景的**前置条件不成立**（跳过，既不是红也不是绿）。

    ⚠️ 为什么必须有第三种：会造真数据的场景（访达新建文件夹）一旦在用户的真实目录里跑，
       造出来的就是他的东西。写成 `Fail` 的话全套永远挂一条红，人会学会无视红；写成
       PASS 更糟 —— 那是在说谎。跳过 + 说明原因，是唯一诚实的第三种。
    """

    pass


class Ctx:
    """一个场景手上的东西：read 出来的行 + 上一条回执 + 步数账。"""

    def __init__(self, session):
        self.s = session
        self.rows = []
        self.text = ""
        self.seq = None
        self.steps = []
        #: 这次场景里**有没有一次读是截断的**（撞节点/墙钟上限）。
        #:
        #: ⚠️ 必须有这个标记：备忘录冷启动的第一次读实测要 **30 秒上下**（撞 helper 内部
        #:    12 秒的读取上限），拿到的是**不完整**快照 —— 而断言常常照样过（它要的那几行
        #:    恰好排在前面）。不标出来，这就是一个永远不会被发现的假绿。
        self.partial = False

    def read(self, app):
        r = self.s.req({"op": "read", "app": app})
        self.steps.append(("read", app, r))
        if not r.get("ok"):
            raise Fail("read 失败: " + (r.get("error") or "?"))
        self.text = r.get("text") or ""
        self.rows = parse_rows(self.text)
        self.seq = r.get("seq")
        if "没读完" in self.text or "只读到" in self.text:
            self.partial = True
        return r

    def find(self, role=None, title=None, contains=None, value=None, why=""):
        for row in self.rows:
            if role and row["role"] != role:
                continue
            if title is not None and row["title"] != title:
                continue
            if value is not None and row["value"] != value:
                continue
            if contains and contains not in row["title"] and contains not in row["value"]:
                continue
            return row
        raise Fail("快照里找不到 role=%s title=%s contains=%s %s"
                   % (role, title, contains, ("(" + why + ")") if why else ""))

    def parent_of(self, row):
        """靠缩进找上一层的行 —— 快照里只有缩进表达层级（`role cell` 里面才是 `statictext`）。"""
        for prev in reversed(self.rows[:self.rows.index(row)]):
            if prev["indent"] == row["indent"] - 1:
                return prev
        raise Fail("找不到 #%d 的父行" % row["number"])

    def act(self, app, action, index, text="", direction=""):
        r = self.s.req({"op": "act", "app": app, "action": action, "index": index,
                        "seq": self.seq, "text": text, "direction": direction})
        self.steps.append((action + " #" + str(index), app, r))
        if not r.get("ok"):
            raise Fail("%s #%s 被拒: %s" % (action, index, r.get("error")))
        if r.get("seq") is not None:
            self.seq = r["seq"]          # 动作之后编号全换一茬，必须接住新 seq
        return r

    def open(self, app, index):
        """⚠️ **别用这个去"打开一个元素"** —— 它发的是 `{"op":"open","app":…}`，那是
        **启动 / 激活 App**（`ComputerServer.handleOpen`），根本不是 AXOpen。

        2026-11-04 踩过：两个场景拿它当"打开这个格子/这个文件夹"，回执说成功、界面一动不动，
        其中「跳到某一天」连断言都没有 ⇒ 一条**什么都没做却标 PASS** 的假绿。
        打开元素一律走 `act(app, "open", index)`。
        保留这个方法只因为"确保 App 起来了"仍然有用（`activate` 才是它该叫的名字）。
        """
        raise Fail("Ctx.open 是激活 App, 不是打开元素 —— 打开元素用 act(app, \"open\", index)")

    def activate(self, app):
        r = self.s.req({"op": "open", "app": app})
        self.steps.append(("activate " + app, app, r))
        if not r.get("ok"):
            raise Fail("激活 %s 被拒: %s" % (app, r.get("error") or "?"))
        return r


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def find_inside(ctx, container, **kw):
    """只在**某个容器行下面**找（按缩进判断范围）。

    ⚠️ 必须有它：访达的**路径栏**里也有一串同名 `statictext`（`…/mangox-scn/未命名文件夹`），
       `ctx.find` 会先命中它 —— 那是"找到了，但找的是别处"，比找不到更糟：
       后面按编号去动它，动的是面包屑。
    """
    i = ctx.rows.index(container)
    for row in ctx.rows[i + 1:]:
        if row["indent"] <= container["indent"]:
            break
        ok = True
        for key in ("role", "title", "value"):
            if key in kw and row[key] != kw[key]:
                ok = False
        for key in ("contains",):
            if key in kw and kw[key] not in row["title"] and kw[key] not in row["value"]:
                ok = False
        if ok:
            return row
    raise Fail("容器 #%d 下面找不到 %r" % (container["number"], kw))


def wait_find(ctx, app, tries=6, pause=0.4, **kw):
    """读一次、找一次；找不到就等一下再来。

    ⚠️ 必须有它：界面上"刚点完"的那几百毫秒里，读到的还是**旧的树**（访达新建文件夹之后
       要等改名格子出来、删完之后要等列表收缩）。第一版直接 `read` 一次就断言，红了之后
       人会以为是产品做不到 —— 而实际只是读早了。
    """
    last = None
    for _ in range(tries):
        ctx.read(app)
        try:
            return ctx.find(**kw)
        except Fail as e:
            last = e
            time.sleep(pause)
    raise last


# ── 清理 ────────────────────────────────────────────────────────────────────

def cleanup(bundle, menu_titles, dry=False):
    """把场景造出来的测试数据清掉。走产品之外的路 —— 见 `scenario_cleanup.swift` 头注释。

    ⚠️ 带 `timeout`：清理器自己也会按 AX 动作，卡住的话**这一侧必须能收手**（同 `Session.req`）。
    """
    if dry:
        return "跳过"
    args = [CLEANUP, bundle, MARKER] + menu_titles
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return "清理器超时(60 秒) —— 数据可能还在, 下次跑之前先手动看一眼"
    tail = (p.stdout or p.stderr).strip().split("\n")[-1]
    return tail


# ── 场景 ────────────────────────────────────────────────────────────────────
#
# 每个场景 = 一段"人会怎么说" + 一条先/再/最后的步骤链 + 一句"怎么算成了"。
# ⚠️ 断言只写**回执里能看见的东西**（编号 / 标题 / 值 / 文案），不写"我觉得应该"。

def scn_calendar_today(ctx):
    """今天有什么日程 —— 只读，不改任何东西。"""
    goto_today(ctx)          # 判据是「今天」那格，先保证视图就在今天所在的月份
    today = ctx.find(role="list", contains="今天", why="月视图里带「今天」的那一格")
    check("星期" in today["title"], "「今天」那一格的标题里应该有星期: " + today["title"])
    return "今天 = %s" % today["title"]


def scn_calendar_create(ctx):
    """新建一条日程（标题 + 时间一次说完）。"""
    ctx.read("日历")
    add = ctx.find(role="button", title="添加日程", why="月视图工具栏")
    ctx.act("日历", "press", add["number"])
    ctx.read("日历")
    box = ctx.find(role="textfield", contains="快速日程", why="浮层里的输入框")
    ctx.act("日历", "setValue", box["number"], text=MARKER + " 复盘 今天 15:00")
    r = ctx.act("日历", "confirm", box["number"])
    ctx.read("日历")
    ctx.find(contains="复盘", why="建完应该出现在快照里")
    return r.get("text", "").split("\n")[0]


def scn_calendar_view_switch(ctx):
    """换视图：月 → 周 → 月（周视图的日列标签是另一种格式，可判定）。"""
    goto_today(ctx)
    month_titles = [r["title"] for r in ctx.rows if r["role"] == "list"]
    # ⚠️ 判据**不许写死「11月」/「12月」**：下个月跑就假红（第一版就是这么写的）。
    #    要判的是形状 —— 月视图的列标题是「月+日（+星期）」，不是具体哪个月。
    check(any(re.match(r"(今天，)?\d+月\d+日", t) for t in month_titles),
          "月视图的 list 标题应该形如「11月1日 星期日」: %s" % month_titles[:3])
    week = ctx.find(role="radiobutton", title="周")
    ctx.act("日历", "press", week["number"])
    ctx.read("日历")
    week_titles = [r["title"] for r in ctx.rows if r["role"] == "list"]
    check(len(week_titles) == len(month_titles) // 6 or len(week_titles) <= 7,
          "周视图应该只剩 7 列，实际 %d（月视图 %d）" % (len(week_titles), len(month_titles)))
    check(any(t.startswith("星期") for t in week_titles),
          "周视图的日列标签应该以「星期」开头: %s" % week_titles[:2])
    back = ctx.find(role="radiobutton", title="月")
    ctx.act("日历", "press", back["number"])
    ctx.read("日历")
    return "月 %d 列 → 周 %d 列 → 月" % (len(month_titles), len(week_titles))


def _mini_month(ctx):
    """小月历**那一页**是哪个月（`上一月` 左边那个 statictext，形如「2026年10月」）。"""
    prev = ctx.find(role="button", title="上一月", why="小月历表头")
    head = ctx.rows[ctx.rows.index(prev) - 1]
    check(head["role"] == "statictext" and "年" in head["title"],
          "「上一月」左边应该是月份标题，实际 %r" % head)
    return int(re.search(r"(\d+)月", head["title"]).group(1))


def _day_cells(ctx, month):
    """小月历上某个月的日期格子（标题形如「12, 星期六, 十二月」，值是纯数字）。"""
    return [c for c in ctx.rows
            if c["role"] == "button" and c["value"].isdigit() and "月" in c["title"]
            and CN_MONTH.get(c["title"].split(", ")[-1]) == month]


def _area_month(ctx):
    """主视图那块（`group "月历区域"`）的月份 —— 值形如 `2026年11月`。"""
    return int(re.search(r"(\d+)月", ctx.find(role="group", title="月历区域")["value"]).group(1))


def goto_today(ctx):
    """把日历拉回**今天所在的那个月**，并选中今天。

    ⚠️ 为什么必须有这一步（2026-11-04 一次端到端跑出来的 3 条红）：前几次失败的导航把日历
       留在了 9月/10月，于是「今天有什么日程」找不到「今天」那格、「改时间」建的事件不在视野里、
       「换视图」去断言 11月/12月 也落空 —— **红的全是环境，不是产品**。而环境恰恰是场景自己
       搞坏的（`上一月` 只翻小日历页、`open` 一个格子才真跳）。
       ⇒ 判据不许依赖"我进来时 App 正好是什么样"。每个依赖月份的日历场景，先自己归位。
    做法 = 人手的做法：在小月历上往后翻页（最多一圈）直到本月，再 `open`「今天」那一格。
    """
    ctx.read("日历")
    want = datetime.date.today().month
    for _ in range(13):
        if _mini_month(ctx) == want:
            break
        nxt = ctx.find(role="button", title="下个月", why="小月历表头")
        ctx.act("日历", "press", nxt["number"])
        ctx.read("日历")
    check(_mini_month(ctx) == want, "翻了 13 次没停到 %d 月（小月历现在 %d 月）" % (want, _mini_month(ctx)))
    today = [c for c in ctx.rows
             if c["role"] == "button" and c["value"].isdigit() and c["title"].startswith("今天")]
    check(today, "%d 月这一页上找不到「今天，…」那格" % want)
    ctx.act("日历", "open", today[0]["number"])
    ctx.read("日历")


def scn_calendar_open_day(ctx):
    """跳到某一天：在小月历上 **open** 一个别的月份的日期格子，再退回来。

    ⚠️ 这一条曾经是**纯假绿**（2026-11-04 抓出来的）：它用的是 `ctx.open(...)`，而那个方法发的是
       `{"op":"open","app":…}` = **激活 App**，不是 AXOpen；而且它把 before/after 打出来、
       **什么都没断言**。两件事叠起来 = 什么都没发生，却记了一次 PASS。

    实测三条，都写进判据里了：
      ① 目标必须**跨月**：在本月里点一个格子，月视图看不出任何变化（11/1 → 11/1）。
      ② 小月历的格子标题用**中文月名**（`十二月`），主视图用**阿拉伯**（`11月`）⇒ 比之前要归一。
      ③ 小月历的**页**和主视图的**月份**是两件事：`上一月` 只翻页、主视图不动。两者会不同步
         （实测被前几次失败留成"页=10月、主视图=9月"）⇒ 先对齐，否则哪一步都判不准。
    """
    ctx.read("日历")
    # ① 先对齐：主视图不在小月历这一页上时，点一个**这页**的格子把它拉过来。
    page = _mini_month(ctx)
    if _area_month(ctx) != page:
        ctx.act("日历", "open", _day_cells(ctx, page)[0]["number"])
        ctx.read("日历")
        page = _mini_month(ctx)
    before = _area_month(ctx)
    check(before == page, "对齐之后主视图（%d月）和小月历（%d月）还是对不上" % (before, page))

    # ② 跳到一个**别的月份**：这一页上一定有邻月的格子（月初/月末那几个）。
    others = _day_cells(ctx, (page % 12) + 1) or [c for c in ctx.rows
                                                  if c["role"] == "button" and c["value"].isdigit()
                                                  and "月" in c["title"]
                                                  and CN_MONTH.get(c["title"].split(", ")[-1]) != page]
    check(others, "小月历这一页上没有邻月的格子 —— 这条场景没法判")
    target = others[0]
    ctx.act("日历", "open", target["number"])
    ctx.read("日历")
    after = _area_month(ctx)
    check(after != before, "open（值=%s，%s）之后主视图还是 %d月 —— 这一下没产生后果"
          % (target["value"], target["title"], after))

    # ③ 退回原月份：open 一个**原月份**的格子（新的一页上一定有邻月的格子）。
    back_cells = _day_cells(ctx, before)
    check(back_cells, "小月历上找不到「%d月」的格子 —— 退不回来了" % before)
    ctx.act("日历", "open", back_cells[0]["number"])
    ctx.read("日历")
    back = _area_month(ctx)
    check(back == before, "退回之后应该还是 %d月，实际 %d月" % (before, back))
    return "%d月 → open 值=%s（%s）→ %d月 → 退回 → %d月" % (
        before, target["value"], target["title"].split(", ")[-1], after, back)


def scn_calendar_list_events(ctx):
    """看某天有哪些日程（有人问「下午有空吗」，得先把那天的事件列出来）。"""
    ctx.read("日历")
    events = [r for r in ctx.rows if r["role"] == "statictext" and "." in r["title"]]
    check(events, "月视图里应该能读到事件行（statictext，标题形如「标题. 日期」）")
    return "读到 %d 条事件行，例: %s" % (len(events), events[0]["title"][:40])


def scn_calendar_edit_time(ctx):
    """改一条日程的时间：先建一条，再把它挪一个小时。

    实测路(2026-11-04，批 2m 把它打通)：
      单击事件行 → 右侧出现编辑器 → **按那行时间** → 展开成四个 `datetimearea`
      (起/止 × 日期/时间，名字只在 `AXIdentifier` 里) → 对 `start-timepicker` 写一个新时间。
    ⚠️ 日历会**保住时长**: 起点 +1 小时，终点自己跟着 +1 小时(18:00 → 19:00)。
    ⚠️ 建的是「今天 16:00」，所以**必须先归位到今天那个月** —— 否则事件落在别的月里，
       月视图那行判据永远看不到（2026-11-04 端到端跑就这么红了一次，红的是环境）。
    """
    goto_today(ctx)
    add = ctx.find(role="button", title="添加日程")
    ctx.act("日历", "press", add["number"])
    ctx.read("日历")
    box = ctx.find(role="textfield", contains="快速日程")
    ctx.act("日历", "setValue", box["number"], text=MARKER + " 改时间 今天 16:00")
    ctx.act("日历", "confirm", box["number"])

    ctx.read("日历")
    row = ctx.find(contains="改时间", why="刚建的那条")
    ctx.act("日历", "press", row["number"])
    ctx.read("日历")
    # 时间那一行是个按钮，值就是当前时间；**按开它**才会出现可写的格子。
    btn = ctx.find(role="button", contains="16:00", why="编辑器里的时间行(形如「日期  16:00 - 17:00」)")
    ctx.act("日历", "press", btn["number"])
    ctx.read("日历")
    picker = ctx.find(role="datetimearea", title="start-timepicker",
                      why="展开后四个格子里管开始时间的那一个")
    cur = picker["value"]
    check(len(cur) == 16 and cur[10] == " ", "时间格的值应该是「yyyy-MM-dd HH:mm」: %r" % cur)
    # 往后挪一小时 —— 目标时间**从读到的值算**，不写死，免得跟"今天 16:00"这条前置对着猜。
    new = "%s %02d:%s" % (cur[:10], (int(cur[11:13]) + 1) % 24, cur[14:])
    ctx.act("日历", "setValue", picker["number"], text=new)
    ctx.read("日历")
    # ⚠️ 判据**必须落在月视图那一行**上(形如「【场景测试】 改时间. 开始于2026年11月4日 17:00，
    #    结束于18:00。」)：编辑器里那四格本来就带着同一个时间，拿它们判等于自己证明自己。
    #    比的是**时间那一段**(`new[11:]`)，因为月视图用的是中文日期(`2026年11月4日`)，
    #    拿 `new` 整串去比永远比不上 —— 第一版就这么红了一次，红的是判据不是产品。
    hit = [r for r in ctx.rows
           if r["role"] == "statictext" and "改时间" in r["title"]
           and "开始于" in r["title"] and new[11:] in r["title"]]
    check(hit, "改完之后月视图那句话的「开始于」应该是 %s；实际事件行: %s"
          % (new, [r["title"] for r in ctx.rows if "开始于" in r["title"]][:4]))
    return "%s → %s（月视图已跟着变）" % (cur, new)


def scn_calendar_custom_delete(ctx):
    """删一条日程到底行不行 —— 这条场景的结论是**不行**，它钉的是"产品要如实说不行"。

    ⚠️ 实测（2026-11-05）：日历的事件行在快照里是 `statictext`，**一个自定义动作都没有**
       （`custom` 被拒："它一个自定义动作都没有"）；`enclosing_cell` 也爬不到带动作的父层。
       而菜单那条（`showmenu`）已经因为作用域判不了被撤掉 —— 删日程**不可逆**，
       不能建在一个猜出来的作用域上。
    ⚠️ 所以这条 PASS 的含义是：**这条路走不通，而且回执说得清**（不是静默什么都没发生）。
       写成"长期红"的话，人会学会无视红；把判据换成"它必须诚实地拒绝"，才是可持续的。
    """
    goto_today(ctx)
    add = ctx.find(role="button", title="添加日程")
    ctx.act("日历", "press", add["number"])
    ctx.read("日历")
    box = ctx.find(role="textfield", contains="快速日程")
    ctx.act("日历", "setValue", box["number"], text=MARKER + " 待删 今天 13:00")
    ctx.act("日历", "confirm", box["number"])
    ctx.read("日历")

    line = ctx.find(contains="待删", why="刚建的那条日程")
    for cand in [line] + ([enclosing_cell(ctx, line)] if _has_cell(ctx, line) else []):
        try:
            ctx.act("日历", "custom", cand["number"], text="删除")
        except Fail as e:
            msg = str(e)
            check("自定义动作" in msg or "没有含" in msg,
                  "被拒了，但没说清是「它没有这个动作」: " + msg)
            continue
        raise Fail("日程行上居然有「删除」—— 这条结论要重写（先确认它删的是不是那条）")
    return "日程行没有自定义动作，产品如实拒了（删日程仍需人来）"


def _has_cell(ctx, row):
    try:
        enclosing_cell(ctx, row)
        return True
    except Fail:
        return False


def scn_notes_create(ctx):
    """新建一条备忘录。"""
    ctx.read("备忘录")
    new = ctx.find(role="button", title="新建备忘录", why="顶部工具栏")
    ctx.act("备忘录", "press", new["number"])
    ctx.read("备忘录")
    # 正文一般是 textarea / textfield，值里有日期抬头。
    body = [r for r in ctx.rows if r["role"] in ("textarea", "textfield")]
    check(body, "新建之后应该有能写字的正文格")
    ctx.act("备忘录", "setValue", body[0]["number"], text=MARKER + " 今天要复盘的三件事")
    ctx.read("备忘录")
    ctx.find(contains="今天要复盘的三件事", why="写进去的内容要能在列表里看到")
    return "建好并写入了一行正文"


def scn_notes_append(ctx):
    """往一条已有笔记末尾追加一句（不是覆盖）。"""
    # 先造一条"已有"的笔记（场景自带前置，免得动用户真实数据）。
    scn_notes_create(ctx)
    ctx.read("备忘录")
    body = ctx.find(role="textarea", contains="今天要复盘的三件事", why="正文是 textarea（不是列表里那格 cell）")
    # ⚠️ 正文可能只在 `title` 里、`AXValue` 是空的（实测这一个 textarea 就是这样）：
    #    只认 `value` 的话 `merged` 会退化成"只有追加那一句" ⇒ **首行被换掉** ⇒ 备忘录列表行
    #    只显示首行 ⇒ 清理器按标记再也找不到它 ⇒ 打印"残留 0"。**判据撒谎**，2026-11-04 真发生过。
    base = body["value"] or body["title"]
    note = "追加：先把日历那条删了"
    merged = (base + "\n" + note) if base else (MARKER + " " + note)
    ctx.act("备忘录", "setValue", body["number"], text=merged)
    ctx.read("备忘录")
    ctx.find(contains=note, why="追加的那句要读得回来")
    return "追加成功（读回原文再整段写回：setValue 是整段替换）"


def scn_notes_find(ctx):
    """按关键词找一条旧笔记。"""
    scn_notes_create(ctx)       # 造一条已知内容的，才谈得上"找"
    ctx.read("备忘录")
    hit = ctx.find(contains=MARKER, why="列表里按标题/正文找")
    return "找到: [%d] %s" % (hit["number"], hit["title"][:40])


def enclosing_cell(ctx, row):
    """从这一行往上（按缩进）找到最近的那层 `cell`。

    ⚠️ 必须这么找，理由有两条实测：
       · 备忘录列表里那一格 `cell` 的 `AXTitle` / `AXValue` **都是空的**，文字全在子
         `statictext` 里 ⇒ `find(contains=…)` 直接找 `cell` 永远找不到；
       · 而「消失」那条判据若也写成「`cell`.title 里没有标记」，它会**恒真** ——
         改完之后那一格当然还在，只是标题一直是空的。假绿就是这么做出来的。
    """
    i = ctx.rows.index(row)
    want = row["indent"] - 1
    while want >= 0:
        above = [r for r in ctx.rows[:i] if r["indent"] == want]
        if not above:
            break
        cand = above[-1]
        if cand["role"] == "cell":
            return cand
        i = ctx.rows.index(cand)
        want -= 1
    raise Fail("找不到 #%d 外面那一层 cell" % row["number"])


def scn_notes_custom_delete(ctx):
    """删掉一条笔记 —— 走**元素自己声明的动作**（`custom`），不是上下文菜单。

    ⚠️ 这条场景换过两次结论，两次都是被真机数据推翻的：
       ① 最早的结论「备忘录删除做不到，只能人工删」是**错的** —— 那次只看了元素自己，而
          动作挂在外层 `cell` 上（快照里"一行"落在 `AXCell`，它身上就有 `Name:删除`）。
       ② 第二版改走 `showmenu` + `press 删除`，**删错了对象**：菜单项作用于**当前选中项**，
          而 `AXShowMenu` 不改变选中项 ⇒ 删掉的是编辑器里开着的那条，不是这一行。
          当天因此误删了两条真笔记（可从「最近删除」恢复）。
       ③ 现在这条：`custom` 执行行自己的 `Name:删除`。隔离实验证明它是**行作用域**
          （编辑器开着乙条、对甲条那一行执行 ⇒ 甲条没了、乙条不动）。
    ⚠️ 判据是**列表里那行真的没了**，不是回执说成功：这族动作的返回码两个方向都撒谎
       （实测 `Name:删除` 报 -25205 而条目真的没了；反过来也可能报 0 却空转）。
    """
    scn_notes_create(ctx)
    ctx.read("备忘录")
    line = ctx.find(role="statictext", contains=MARKER, why="列表里那条笔记的标题行")
    row = enclosing_cell(ctx, line)
    r = ctx.act("备忘录", "custom", row["number"], text="删除")
    check("删除" in (r.get("text") or ""),
          "回执要写清执行的是哪个动作: " + (r.get("text") or "")[:160])
    ctx.read("备忘录")
    left = [x for x in ctx.rows if x["role"] == "statictext" and MARKER in x["title"]]
    check(not left, "执行「删除」之后那行还在列表里 —— 这一下没产生后果")
    return "行上的「删除」删掉了 [%d]（列表里已消失）" % row["number"]


def new_reminder_field(ctx):
    """「…中的新提醒事项」那一行的输入框 —— **不是"第一个空的 textfield"**。

    ⚠️ 坑（2026-11-04 实测）：提醒事项窗口里同时有 **三个** 空 textfield —— 顶上的搜索框、
       侧栏的列表名、还有新建那行。随手取第一个会把文字写进**搜索框**，而文字确实"读得回来"
       （`find(contains=…)` 命中搜索框），于是这条场景假绿了一次：一条提醒都没建。
       判据 = 它前面几行里出现过「…中的新提醒事项」。
    """
    for i, row in enumerate(ctx.rows):
        if row["role"] != "textfield" or row["value"].strip():
            continue
        names = [p["title"] for p in ctx.rows[max(0, i - 4):i]]
        if any("新提醒事项" in t for t in names):
            return row
    raise Fail("找不到新建那一行的输入框（「…中的新提醒事项」下面那个）")


def committed_reminder(ctx, text):
    """**已经落库**的那条提醒行，标题形如「未完成、买咖啡豆」。

    ⚠️ 判据不能是 `find(contains=…)`：新建那个输入框里也带着同样的文字（`textfield` 那行），
       命中它只证明"我写进去了"，不证明"这条提醒存在" —— 第一版就是这么假绿的。
       区别在 **`未完成、` 这个前缀 + `cell/group` 这个角色**：只有真提交了才会有它。
    """
    for r in ctx.rows:
        if r["role"] in ("cell", "group") and r["title"].startswith("未完成") and text in r["title"]:
            return r
    raise Fail("列表里没有「未完成、%s」这一行 —— 文字在输入框里, 但没落成提醒" % text)


def scn_reminders_add(ctx):
    """加一条提醒事项（带内容）。

    ⚠️ 实测两件（2026-11-04）：
       ① 新建那个输入框只暴露 `["AXShowMenu", "AXConfirm"]`，**没有 `AXPress`** ⇒ 写完必须
          `confirm` 才真的落成一条（同日历「创建快速日程」那一族）；
       ② 窗口里有**三个空 textfield**（搜索框 / 侧栏列表名 / 新建那行），随手取第一个会把字
          写进搜索框 —— 见 `new_reminder_field`。
    """
    ctx.read("提醒事项")
    add = ctx.find(role="button", title="添加提醒事项", why="右上")
    ctx.act("提醒事项", "press", add["number"])
    ctx.read("提醒事项")
    field = new_reminder_field(ctx)
    ctx.act("提醒事项", "setValue", field["number"], text=MARKER + " 买咖啡豆")
    ctx.act("提醒事项", "confirm", field["number"])
    ctx.read("提醒事项")
    committed_reminder(ctx, "买咖啡豆")
    return "加好了一条（列表里出现「未完成、买咖啡豆」）"


def scn_reminders_check(ctx):
    """勾掉一条提醒事项。

    ⚠️ 判据是**「未完成、买咖啡豆」那一行消失**，不是"那个勾的值变成 1"：提醒事项把勾掉的
       条目从列表里藏进「完成」⇒ 勾本身跟着从快照里没了（第一版找 `checkbox value=1` 永远
       找不到，红的是判据不是产品）。勾的名字也**不是序号**，是 `标记为完成` —— 拿它认目标，
       别拿"离标题最近的 checkbox"去猜。
    """
    scn_reminders_add(ctx)
    ctx.read("提醒事项")
    row = committed_reminder(ctx, "买咖啡豆")
    boxes = [r for r in ctx.rows if r["role"] == "checkbox" and r["title"] == "标记为完成"]
    check(boxes, "提交后的提醒应该带一个「标记为完成」的勾")
    target = min(boxes, key=lambda b: abs(b["number"] - row["number"]))
    ctx.act("提醒事项", "press", target["number"])
    ctx.read("提醒事项")
    left = [r for r in ctx.rows
            if r["role"] == "cell" and r["title"].startswith("未完成") and "买咖啡豆" in r["title"]]
    check(not left, "勾完之后「未完成、买咖啡豆」还在列表里 —— 这一下没产生后果")
    return "勾掉了（「未完成、买咖啡豆」已从列表里消失，进「完成」了）"


def scn_finder_find_file(ctx):
    """在访达里找某个文件。"""
    ctx.read("访达")
    outline = ctx.find(role="outline", contains="列表视图", why="文件列表是个 outline")
    names = [r for r in ctx.rows if r["role"] == "textfield" and r["title"]]
    check(names, "列表视图里文件名的 role 应该是 textfield")
    return "「%s」下列出 %d 个文件名，例: %s" % (outline["title"], len(names), names[0]["title"][:30])


def scn_finder_open_folder(ctx):
    """在访达里打开一个文件夹（**open** 语义），再返回。

    ⚠️ 两条都是探针自己踩的坑，写在这儿免得下次再踩：
       ① 边栏那个 `cell` **只暴露 `AXOpen`**、没有 `AXPress` —— 第一版写的 `press` 被产品
          如实拒了（回执：「它能做的只有：AXOpen ⇒ 没动。…改用 open」）。场景问的是
          "能不能进去"，而"按一下"和"打开"在 AX 里本就是两个动作。
       ② **不能写死"下载"**：窗口本来就在下载时，"标题应该变"永远不成立（实测红在这儿，
          红的是前提不是产品）⇒ 目标从**当前目录**反着挑。
    """
    ctx.read("访达")
    head = ctx.text.split("\n")[0]
    here = head.split("窗口:")[-1].strip()
    target = None
    for name in ("文稿", "应用程序", "桌面", "下载", "最近使用"):
        if name == here:
            continue
        try:
            target = ctx.find(role="statictext", title=name, why="边栏入口")
            break
        except Fail:
            continue
    check(target is not None, "边栏里没有一个不是「%s」的入口" % here)
    cell = ctx.parent_of(target)
    # 落点试两个：cell 和它里面的 statictext。实测（2026-11-04）`cell` 只声明了 `AXOpen`，
    #   `AXOpen` 的返回码不可信（见 `ComputerAct` 头注释）⇒ 这里不是"碰运气"，而是问
    #   "这一族里到底哪个元素接管导航"。
    #   ⚠️ 第一次失败用的是 `Ctx.open`（激活 App），两次"落点"其实是同一个空转 —— 见那个方法。
    moved = None
    for candidate in (cell, target):
        # 第二次要**重新找**：`read` 之后编号整茬换掉，拿旧编号打的就是另一个元素。
        row = candidate if candidate is cell else ctx.find(role="statictext", title=target["title"])
        ctx.act("访达", "open", row["number"])
        ctx.read("访达")
        if ctx.text.split("\n")[0] != head:
            moved = row["role"]
            break
    check(moved is not None,
          "对「%s」按 open 打了两处（cell / statictext）窗口都没动，还是「%s」" % (target["title"], here))
    after = ctx.text.split("\n")[0]
    back = ctx.find(role="button", title="返回")
    ctx.act("访达", "press", back["number"])
    ctx.read("访达")
    return "标题 %s → %s → 返回（落点=%s）" % (here, after.split("窗口:")[-1].strip(), moved)


def scn_finder_new_folder(ctx):
    """新建一个文件夹 —— 走工具栏那个**齿轮按钮**（`menubutton "操作"`）弹出来的菜单。

    ⚠️ 三条路试过，只有这条能走：
       · 顶栏「文件 › 新建文件夹」= **红线禁**（顶栏菜单要前台，而前台是谁不算数）；
       · 窗口里**没有**「新建文件夹」按钮；
       · 上下文菜单要 `showmenu`，而它已因作用域判不了被撤掉（见 `ComputerAction.showmenu`）。

    ⚠️ 实测两个必须写下来的事实（2026-11-05）：
       ① 新建之后 Finder **立刻进改名模式**，整个窗口树那时只剩一个 `textfield`；
       ② 那个改名格子**一个 AX 动作都不提供** —— `confirm` / `press` 都会被如实拒掉。
          ⇒ 名字只能用 Finder 自己给的「未命名文件夹」；想退出改名模式只能**点别处**
            （这里按工具栏「返回」），靠回车键是全局输入，红线禁。
    ⚠️ 所以这条场景**只证明"新建得出来"**，而且**只在临时目录里跑**：访达不在
       `/tmp/mangox-scn` 时直接 Skip —— 它会造一个真文件夹，在用户自己的目录里造出来
       就是他的东西（造了不收，等于拿别人的家当测试场）。
    """
    ctx.read("访达")
    if "窗口:mangox-scn" not in ctx.text:
        raise Skip("访达不在临时目录 /tmp/mangox-scn ⇒ 不跑（这条会造真文件夹）")
    gear = ctx.find(role="menubutton", title="操作", why="工具栏齿轮")
    ctx.act("访达", "press", gear["number"])
    ctx.read("访达")
    item = ctx.find(role="menuitem", title="新建文件夹", why="齿轮菜单里的「新建文件夹」")
    ctx.act("访达", "press", item["number"])
    field = wait_find(ctx, "访达", role="textfield", contains="未命名文件夹",
                      why="新建后的改名格子")
    check("未命名文件夹" in (field["title"] + field["value"]),
          "改名格子里应该是「未命名文件夹」: " + repr(field))
    # 那个格子没有 AXConfirm（实测），所以这里**证明**它提交不了，而不是绕过去。
    try:
        ctx.act("访达", "confirm", field["number"])
        note = "改名格子吃了 confirm"
    except Fail:
        note = "改名格子没有 AX 动作(confirm/press 都拒)；退出改名靠切走前台"
    # ⚠️ 退出改名模式的**唯一** AX 路：切到别的 App（产品已有 `open`，不是按键 ——
    #    回车/Esc 是全局输入，红线禁）。实测切走之后 Finder 立刻提交改名并恢复可读，
    #    之前整棵树只剩改名那一行。
    ctx.activate("备忘录")
    # 判据要**只在文件列表里**找：访达的路径栏里也有一串同名的 statictext（面包屑），
    # 全表搜索会命中它 —— 那是"找到了但找的是别处"。
    for _ in range(8):
        ctx.read("访达")
        outline = ctx.find(role="outline", title="列表视图", why="文件列表")
        try:
            made = find_inside(ctx, outline, contains="未命名文件夹")
            return ("齿轮菜单建出了「未命名文件夹」（列表里那一行在），" + note
                    + "；这个文件夹留在当前目录，由外层脚本收")
        except Fail:
            time.sleep(0.4)
    raise Fail("建完之后列表里看不到「未命名文件夹」—— 这一下没产生后果")


def _safari_webarea(ctx, tries=4, pause=1.5):
    """等到网页树出来 —— Safari 是**页面加载完**才建 `AXWebArea` 的。

    ⚠️ 实测两次（2026-11-06）：刚 `open -a Safari <url>` 完立刻读，窗口标题还是「未命名」、
       工具栏上还是「停止载入此页面」，整棵树里**一个 webarea 都没有**。首版直接 `check`
       ⇒ 连红两次，看上去像红线没生效，实际只是读早了。
    ⚠️ 等不到就 **Skip**，不是 Fail：浏览器里没开页面是「前置条件不成立」，不是产品缺陷。
       判成红，人会学会无视红（同 `Skip` 的注释）。
    """
    loading = False
    for i in range(tries):
        ctx.read("Safari")
        for r in ctx.rows:
            if r["role"] == "webarea":
                return r
        loading = any(r["title"] == "停止载入此页面" for r in ctx.rows)
        if i + 1 < tries:
            time.sleep(pause)
    raise Skip("Safari 里没有可读的网页内容（%s）—— 先在浏览器里打开一个有链接的页面再跑这条"
               % ("页面还在加载" if loading else "快照里没有 webarea"))


def _window_title(ctx):
    """快照第一行里的窗口标题 —— 判"这一下到底有没有后果"最省事的一把尺。"""
    line = ctx.text.split("\n")[0]
    return line.split("窗口:")[-1] if "窗口:" in line else line


def scn_safari_web_operate(ctx):
    """网页里**真能点** —— 2026-11-09 撤掉 ⑤b 之后，这条从"必须被拒"翻成"必须真有后果"。

    历史: 11-06 立的是「网页内容一律不动」（`scn_safari_web_untouchable`），因为它能证明
    `AXAdapter.insideWebArea` 走真父链算对了。11-09 boss 定要**完全体可操作**，⑤b 与那个
    函数一起删了，于是这条场景的判据反过来：

      ① 网页里的 link 按下去，**窗口标题必须变**（真跳转），不是"回执说 ok"；
      ② 反例：`open(url:)` 对 `file://` 仍然拒（撤⑤b 不等于把所有闸拆掉）。

    ⚠️ `open(url: "baidu.com")` 的真导航**不放进来**：它每跑一次就多一个关不掉的标签页
       （关标签不可逆，我不替用户关）。导航那条由冒烟 `ComputerAddress` 的判据 + 手测覆盖。
    ⚠️ 页面用**国内站点**（`open -a Safari https://www.baidu.com`）：之前拿 GitHub 试，
       一次"服务器未响应"、一次载入慢到没有 webarea —— 那种红全是网络，不是产品。
    """
    _safari_webarea(ctx)

    # ⚠️ 样本要挑**像导航链接**的：页面上第一个 link 常常是 skip-link
    #    （百度那句「欢迎进入…盲人用户进入读屏幕模式…」），按下去本来就没有后果 ——
    #    拿它当样本，判据测的就成了"这个元素有没有副作用"，而不是"产品放没放行"。
    #    所以：跳过无障碍那一族、跳过标题过长的，最多试 3 个。
    skip_words = ("盲人", "无障碍", "跳到", "skip", "Skip")
    tried = []
    for _ in range(3):
        cands = [r for r in ctx.rows
                 if r["role"] == "link" and 0 < len(r["title"]) <= 24
                 and r["title"] not in tried
                 and not any(w in r["title"] for w in skip_words)]
        if not cands:
            break
        link = cands[0]
        tried.append(link["title"])
        before = _window_title(ctx)
        # 判效果不判回执 —— helper 这一层只说"动作送进去了"，说不了"页面跳没跳"。
        ctx.act("Safari", "press", link["number"])
        for _ in range(6):
            time.sleep(0.8)
            ctx.read("Safari")
            if _window_title(ctx) != before:
                after = _window_title(ctx)
                r = ctx.s.req({"op": "open", "app": "Safari", "url": "file:///etc/passwd"})
                check(not r.get("ok") and "scheme" in (r.get("error") or ""),
                      "file:// 没被拒 —— 撤⑤b 把导航那道闸也拆了: %s" % (r.get("error") or "ok"))
                return "网页 link %r 真跳转（%r → %r）；file:// 仍被拒" % (
                    link["title"][:18], before[:16], after[:16])
    check(False, "按了 %r 这些网页 link，窗口标题一个都没变 —— ⑤b 撤了却没真放行" % (tried,))


SCENARIOS = [
    # (标题, 函数, 清理菜单项)
    ("日历 · 今天有什么日程", scn_calendar_today, None),
    ("日历 · 新建一条日程", scn_calendar_create, ["删除"]),
    ("日历 · 换视图（月→周→月）", scn_calendar_view_switch, None),
    ("日历 · 跳到某一天", scn_calendar_open_day, None),
    ("日历 · 列出某天的事件", scn_calendar_list_events, None),
    ("日历 · 改一条日程的时间", scn_calendar_edit_time, ["删除"]),
    ("日历 · 用它的「删除」删掉一条", scn_calendar_custom_delete, ["删除"]),
    ("备忘录 · 新建一条", scn_notes_create, ["删除", "Delete"]),
    ("备忘录 · 按关键词找", scn_notes_find, ["删除", "Delete"]),
    ("备忘录 · 末尾追加一句", scn_notes_append, ["删除", "Delete"]),
    ("备忘录 · 用它的「删除」删掉一条", scn_notes_custom_delete, ["删除", "Delete"]),
    ("提醒事项 · 加一条", scn_reminders_add, ["删除", "Delete"]),
    ("提醒事项 · 勾掉一条", scn_reminders_check, ["删除", "Delete"]),
    ("访达 · 找某个文件", scn_finder_find_file, None),
    ("访达 · 打开一个文件夹再返回", scn_finder_open_folder, None),
    ("访达 · 新建文件夹", scn_finder_new_folder, None),
    ("Safari · 网页里真能点（导航除外）", scn_safari_web_operate, None),
]


# ── 跑 ──────────────────────────────────────────────────────────────────────

def dump(app):
    s = Session([APPS[app]])
    try:
        ctx = Ctx(s)
        r = ctx.read(app)
        print(r["text"])
        print("\n── 共 %d 行 ──" % len(ctx.rows))
    finally:
        s.close()


def main(argv):
    if len(argv) >= 2 and argv[0] == "--dump":
        dump(argv[1])
        return 0

    want = argv[0] if argv else ""
    todo = [x for x in SCENARIOS if want in x[0]]
    if not todo:
        print("没有匹配的场景: %r" % want)
        return 1

    s = Session(sorted(set(APPS[k] for k in APPS)))
    passed, failed = 0, []
    skipped = []
    try:
        for title, fn, menus in todo:
            ctx = Ctx(s)
            t0 = time.time()
            # ⚠️ **开跑前先打一行**：卡死的时候这一行就是"卡在哪一条"的唯一线索。
            #    只打 PASS/FAIL 的话，一次 hang 会留下零信息（2026-11-04 就这么白等了一场）。
            print("RUN   %-28s …" % title, flush=True)
            try:
                detail = fn(ctx)
                # 造过数据的场景，跑完立刻清
                if menus:
                    bundle = APPS[title.split(" · ")[0]]
                    detail += " · 清理: " + cleanup(bundle, menus)
                print("PASS  %-28s %5.1fs  %d 步  %s%s"
                      % (title, time.time() - t0, len(ctx.steps),
                         "⚠️ 这次读是**截断的**(快照不完整, 结论要打折) · " if ctx.partial else "",
                         detail))
                passed += 1
            except Skip as e:
                # ⚠️ 跳过**不算失败**, 也不算通过 —— 单独一行, 而且必须写明原因。
                print("SKIP  %-28s %5.1fs  %s" % (title, time.time() - t0, e))
                skipped.append((title, str(e)))
                continue
            except Fail as e:
                print("FAIL  %-28s %5.1fs  %d 步  %s"
                      % (title, time.time() - t0, len(ctx.steps), e))
                failed.append((title, str(e)))
                if menus:
                    cleanup(APPS[title.split(" · ")[0]], menus)
            except SystemExit:
                raise
            except Exception as e:                        # noqa: BLE001
                print("FAIL  %-28s 异常: %r" % (title, e))
                failed.append((title, repr(e)))
    finally:
        s.close()

    print("\n%d PASS / %d SKIP / %d FAIL" % (passed, len(skipped), len(failed)))
    for t, e in skipped:
        print(" ~ %s: %s" % (t, e))
    for t, e in failed:
        print(" - %s: %s" % (t, e))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
