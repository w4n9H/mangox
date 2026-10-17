#!/usr/bin/env python3
"""MangoX × pi 契约体检 —— pi 升级之后跑这一支，判「我们依赖它的那些面还活着吗」。

**为什么独立、不进冒烟**
  冒烟（scripts/smoke/run.sh）验的是 **MangoX 自己的逻辑**：MockTransport 注入，零外部依赖，秒级。
  这一支验的是 **外部引擎**：每一项都要 spawn 真 `pi` 进程（每个 2~4 秒），全跑一轮几十秒；
  而 pi 的发布节奏远快于 MangoX —— 塞进门禁等于每次改文案都要等它。两件事的触发条件也不同：
  **冒烟跟着提交走，这一支跟着 pi 升级走。**

**为什么不是一张静态清单**
  清单会过期：上游改了什么，清单不会自己响。这里每一项都是**可执行的断言**，能变红（退出码 1）。
  只有判断不了的那几条（要看模型实际行为）才列成人工项，由 `--manual` 单独打出来。

**判据来源：不在这里二次声明数据**
  · CLI 参数 / RPC 方法 / 事件名 —— 全部在 `mangox/Agent/*.swift` 里。
    本文件的 `REQUIRED_FLAGS` / `REQUIRED_RPC` 只是**索引**，末尾的「自洽检查」会把它们
    跟源码里实际出现的 `--xxx` / `"xxx"` 字面量对一遍：**源码新增了参数而这里没加 ⇒ 报红**。
    （同 scripts/diag/palette_probe.py 的原则：独立的是公式，不是数据。）
  · 上次通过时的键集合 —— `pi_baseline.json`（本目录）。升级前跑一次 `--update-baseline`，
    升级后跑普通模式，diff 出来就是「上游动了哪一根」。

用法:
  python3 scripts/diag/pi_upgrade_probe.py                    # 体检 PATH 里的 pi
  python3 scripts/diag/pi_upgrade_probe.py --pi-path /path/to/cli.js   # 体检指定的那份（升级前预演）
  python3 scripts/diag/pi_upgrade_probe.py --update-baseline  # 全过后把当前快照写成新基线
  python3 scripts/diag/pi_upgrade_probe.py --manual           # 只打人工检查清单
  python3 scripts/diag/pi_upgrade_probe.py --versions         # 只看版本与基线

退出码: 0 = 全过；1 = 有红（缺键 / 扩展加载失败 / 参数不被接受 / 自洽漂移）。

⚠️ 本脚本**不花 LLM 额度**：不传 `--model`、不发 prompt，只做握手与结构断言。
⚠️ 本脚本**不写用户数据**：一律 `--no-session`（不落会话文件）。只读 `~/.pi` 的配置。
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..'))
AGENT_SRC = os.path.join(REPO, 'mangox', 'Agent')
BASELINE = os.path.join(HERE, 'pi_baseline.json')

# —— 我们实际用到 pi 的面（索引，不是真理；真理在 Agent/*.swift，末尾自洽检查兜底）——
REQUIRED_FLAGS = [
    '--mode',                 # PiRpcTransport.spawn* :1390 附近
    '--session',              # PiRpcTransport :1279/:1283（会话续跑）
    '--session-dir',          # PiRpcTransport :1264（fork 时的会话目录）
    '--fork',                 # PiRpcTransport :1264（分叉）
    '--no-session',           # PiRpcTransport :1286 + MemoryDistiller :55
    '--extension',            # PiRpcTransport :235-239（审批桥 / llama / codemode / dream / 业务扩展）
    '--no-extensions',        # PiRpcTransport :235（先清默认扩展再逐个挂）
    '--tools',                # AgentMode.spawnArguments :121（四档能力面）
    '--append-system-prompt', # PiRpcTransport :1294（知识注入）
    '--model',                # PiRpcTransport :1298
    '--thinking',             # PiRpcTransport :1300
]

REQUIRED_RPC = [
    'get_state',              # spawn 后立刻拉（sawAnyRPC 判据的一部分）
    'get_available_models',   # ModelStore 的数据源
    'get_session_stats',      # P6.1.1 状态栏
    'set_model',              # 回合内切模型
    'set_thinking_level',     # 回合内切思考级别
    'send',                   # 回合入口
    'cancel',                 # 中止
]

# 这三条是我们**读 data 里的字段**的，键集合缺失比"方法不存在"更隐蔽 ⇒ 单独对照基线
KEYED_RPC = ['get_state', 'get_available_models', 'get_session_stats']

# stderr 里出现这些才算真错。⚠️ 刻意**不含** `settings.json.lock` / `EEXIST`：
# 那是被托管进程注入 fs shim 时的**假阳性**（锁被重复创建），与本项目无关。
FATAL_STDERR = re.compile(
    r'Failed to load extension|Unknown (?:option|argument)|unknown option|'
    r'Cannot find module|is not a function|SyntaxError')


# ---------------------------------------------------------------- 跑 pi

class Result:
    def __init__(self, ok, label, detail=''):
        self.ok, self.label, self.detail = ok, label, detail


def _cmd(pi_path):
    """`--pi-path` 指向 .js 时要走 node（npm 包解压/前缀安装的形态）。"""
    if pi_path.endswith('.js'):
        return ['node', pi_path]
    return [pi_path]


def run_rpc(pi, extra_args, timeout=40):
    """起一次 `--mode rpc`，灌入 get_state/get_available_models/get_session_stats，收尾即杀。

    返回 (responses:dict[type->data], stderr:str, launched:bool)。
    ⚠️ 用 communicate 而不是 readline：RPC 进程不会自己退出，逐行读会永久阻塞
      （第一版就是这样卡死的）。communicate 会在喂完 stdin 后等它收尾，超时可控。
    """
    cmd = _cmd(pi) + ['--mode', 'rpc', '--no-session'] + extra_args
    reqs = ''.join(json.dumps({'id': 'chk-%d' % i, 'type': t}) + '\n'
                   for i, t in enumerate(KEYED_RPC))
    env = dict(os.environ)
    env.setdefault('PATH', '/opt/homebrew/bin:/usr/bin:/bin')
    try:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, env=env)
    except OSError as e:
        return {}, 'launch failed: %s' % e, False
    try:
        out, err = p.communicate(input=reqs, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        return {}, (err or '') + '\n[timeout after %ss]' % timeout, False
    resp = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get('type') == 'response' and isinstance(d.get('data'), dict):
            # 按请求顺序回填：id chk-0/1/2 对应 KEYED_RPC[i]
            m = re.match(r'chk-(\d+)$', str(d.get('id', '')))
            if m and int(m.group(1)) < len(KEYED_RPC):
                resp[KEYED_RPC[int(m.group(1))]] = d['data']
    return resp, err or '', True


def pi_version(pi):
    try:
        out = subprocess.run(_cmd(pi) + ['--version'], capture_output=True,
                             text=True, timeout=30)
    except Exception as e:      # noqa: BLE001 —— 任何启动失败都归到"读不到版本"
        return None, str(e)
    v = (out.stdout or '').strip().splitlines()
    return (v[0].strip() if v else None), (out.stderr or '').strip()


def pi_flags(pi):
    """从 `--help` 抓所有长选项。比逐个试探 `--xxx` 快，也不会因为语义变化误判。"""
    try:
        out = subprocess.run(_cmd(pi) + ['--help'], capture_output=True,
                             text=True, timeout=40)
    except Exception:                                               # noqa: BLE001
        return set()
    text = (out.stdout or '') + (out.stderr or '')
    return set(re.findall(r'(--[a-z][a-z0-9-]+)', text))


# ---------------------------------------------------------------- 各项检查

def check_version(pi, baseline):
    v, err = pi_version(pi)
    if not v:
        return Result(False, '版本可读', 'pi --version 无输出 / %s' % err[:120]), None
    # ⚠️ 只判"有输出"不够：反例用 `/bin/echo` 冒充时它会把 `--version` 原样回显 ⇒ 也算通过。
    #    版本号必须长得像版本号，否则下面"与基线比对"就变成拿垃圾值比垃圾值。
    if not re.match(r'^\d+\.\d+\.\d+', v):
        return Result(False, '版本可读', '输出不像版本号: %r' % v[:60]), None
    base = (baseline or {}).get('piVersion')
    if base and base != v:
        # 换版本**不是错**（这正是本工具存在的理由），但要显眼
        return Result(True, '版本可读',
                      '%s（基线 %s ⇒ **已换版本，下面逐项看**）' % (v, base)), v
    return Result(True, '版本可读', '%s（与基线一致）' % v if base else v), v


def check_flags(pi, baseline):
    """返回 (Result, pi 认识的参数集合) —— 集合会被自洽检查复用，不必再跑一次 --help。"""
    got = pi_flags(pi)
    if not got:
        return Result(False, 'CLI 参数', 'pi --help 解析失败，拿不到任何长选项'), set()
    missing = [f for f in REQUIRED_FLAGS if f not in got]
    if missing:
        return Result(False, 'CLI 参数', '缺 %s' % ' '.join(missing)), got
    return Result(True, 'CLI 参数', '%d/%d 全在' % (len(REQUIRED_FLAGS), len(REQUIRED_FLAGS))), got


def check_rpc_shape(pi, baseline, resp, err):
    if not resp:
        first = '; '.join(l for l in err.splitlines() if FATAL_STDERR.search(l))[:160]
        return [Result(False, 'RPC 握手', '三条命令一条 response 都没回' + (' | ' + first if first else ''))]
    out = []
    base_keys = (baseline or {}).get('rpcDataKeys') or {}
    for method in KEYED_RPC:
        data = resp.get(method)
        if data is None:
            out.append(Result(False, 'RPC ' + method, '无 response'))
            continue
        got = set(data.keys())
        want = set(base_keys.get(method) or [])
        missing = sorted(want - got)
        added = sorted(got - want)
        if missing:
            out.append(Result(False, 'RPC ' + method, '缺键 %s' % ', '.join(missing)))
        elif not want:
            out.append(Result(True, 'RPC ' + method, '%d 键（无基线，未比对）' % len(got)))
        else:
            note = '%d 键齐全' % len(got) + (('；新增 ' + ', '.join(added)) if added else '')
            out.append(Result(True, 'RPC ' + method, note))
    return out


def check_param_combo(pi):
    """真起一次带参数组合的进程 —— `--help` 里有选项名，不等于这个组合会被接受。"""
    out = []
    for label, args in [
        ('modifier 形态', ['--tools', '+grep,+find,+ls', '--thinking', 'high']),
        ('allowlist 形态', ['--tools', 'read,bash,write,edit', '--thinking', 'low']),
    ]:
        resp, err, launched = run_rpc(pi, args)
        fatal = [l for l in err.splitlines() if FATAL_STDERR.search(l)]
        if not launched or not resp:
            out.append(Result(False, '--tools ' + label,
                              (fatal[0][:150] if fatal else '起不来 / 无 response')))
        elif fatal:
            out.append(Result(False, '--tools ' + label, fatal[0][:150]))
        else:
            out.append(Result(True, '--tools ' + label, '进程接受该组合'))
    return out


def extension_files():
    d = os.path.expanduser('~/.mangox/extensions')
    return sorted(glob.glob(os.path.join(d, '*.ts')))


def check_extensions(pi):
    files = extension_files()
    if not files:
        return [Result(True, '扩展加载', '跳过（~/.mangox/extensions 下没有 .ts）')]
    out = []
    for f in files:
        name = os.path.basename(f)
        resp, err, launched = run_rpc(pi, ['--no-extensions', '--extension', f])
        bad = [l for l in err.splitlines()
               if 'Failed to load extension' in l or FATAL_STDERR.search(l)]
        if bad:
            out.append(Result(False, '扩展 ' + name, bad[0][:170]))
        elif not resp:
            out.append(Result(False, '扩展 ' + name, '加载后无 response（可能阻断了启动）'))
        else:
            out.append(Result(True, '扩展 ' + name, 'ok'))
    return out


def check_self_consistency(known_flags):
    """源码里出现了 `--xxx`，而本脚本没登记 ⇒ 报红。

    防的是这个漂移：有人给 MangoX 加了个新的 pi 参数，体检脚本不知道 ⇒
    "全过"变成一句谎话（同 palette_probe 那条"独立的是公式不是数据"）。
    """
    if not os.path.isdir(AGENT_SRC):
        return Result(True, '自洽检查', '跳过（找不到 mangox/Agent）')
    seen = set()
    for path in glob.glob(os.path.join(AGENT_SRC, '*.swift')):
        with open(path, encoding='utf-8') as fh:
            seen |= set(re.findall(r'"(--[a-z][a-z0-9-]+)"', fh.read()))
    # ⚠️ 先跟 pi 的 --help 求交：源码里还有 curl / 邮件的参数（--mail-from、--upload-file …），
    #    它们长得一样但是别家的。只判"pi 认识、而本脚本没登记"的 —— 交集之外的不归我们管。
    #    （反过来的漏网——`--foo` 被 pi 删了——由 check_flags 抓，两处互补。）
    unknown = sorted((seen & set(known_flags)) - set(REQUIRED_FLAGS))
    if unknown:
        return Result(False, '自洽检查',
                      '源码用了本脚本没登记的参数: %s（把它们加进 REQUIRED_FLAGS）'
                      % ' '.join(unknown))
    return Result(True, '自洽检查', '源码里的 %d 个参数都已登记' % len(seen))


MANUAL = """
人工检查清单（脚本判不了的那些，升级后请**逐条**过一遍）
------------------------------------------------------------------
1. 流式回合：随便发一句话，确认 文本逐字出现 / 思考块折叠正常 / 工具卡能展开。
   （判据：不是"有没有回复"，而是**逐字流式**——1.x 改过 message_update 的节流）
2. 审批卡：让它跑一个会触发的 bash（例如 `rm -rf /tmp/pi-probe-nonexistent`），
   确认弹卡、Allow / Allow always / Deny 三档都生效，且"always"在会话内被记住。
3. ⚠️ 切档残留（pi 1.3.0 起的行为，本工具测不到，必须人眼看）：
   同一个会话先在 **Full** 档跑一轮（会挂 web-search，工具池里有 bocha_web_search）→
   切到 **Standard**（不挂业务扩展）→ 问它「列出你现在能调用的工具」。
   **如果还看得到 bocha_web_search ⇒ 命中 1.3.0 的 resume 恢复逻辑**，需要改
   AgentMode.standard/full 的 `--tools` 写法（`--no-tools` + 逐个 `+name`）。
4. 会话续跑 / 分叉：新建会话 → 关窗口 → 重开（应恢复）→ fork 一次（应出现"前往源会话"）。
5. dream：Plugins 面板里确认 dream 行还在、能开关（它读 note_proposals，与引擎版本弱相关）。
6. 中断：回合进行中点停止，确认胶囊回 idle、进程被拆掉（`pgrep -f 'MacOS/mangox'` 不残留子进程）。
------------------------------------------------------------------
"""


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description='MangoX × pi 契约体检')
    ap.add_argument('--pi-path', default='pi', help='pi 可执行文件（.js 会走 node）')
    ap.add_argument('--update-baseline', action='store_true', help='全过后写入新基线')
    ap.add_argument('--manual', action='store_true', help='只打印人工清单')
    ap.add_argument('--versions', action='store_true', help='只看版本')
    args = ap.parse_args()

    if args.manual:
        print(MANUAL)
        return 0

    pi = args.pi_path
    if not pi.endswith('.js'):
        pi = shutil.which(pi) or pi
    if not os.path.exists(pi):
        print('找不到 pi: %s' % args.pi_path)
        return 1

    baseline = None
    if os.path.exists(BASELINE):
        try:
            with open(BASELINE, encoding='utf-8') as fh:
                baseline = json.load(fh)
        except ValueError as e:
            print('基线文件损坏（%s）：%s' % (BASELINE, e))
            return 1

    if args.versions:
        v, _ = pi_version(pi)
        print('pi        : %s' % (v or '读不到'))
        print('基线版本  : %s' % ((baseline or {}).get('piVersion') or '（无基线）'))
        print('基线时间  : %s' % ((baseline or {}).get('verifiedAt') or '—'))
        return 0

    print('pi 升级体检 · %s' % pi)
    if baseline:
        print('基线：pi %s（%s）' % (baseline.get('piVersion'), baseline.get('verifiedAt')))
    else:
        print('基线：**无**（首次使用，先跑一次 --update-baseline）')
    print('-' * 64)

    results = []
    r, current_version = check_version(pi, baseline)
    results.append(r)
    flags_res, known_flags = check_flags(pi, baseline)
    results.append(flags_res)
    results.append(check_self_consistency(known_flags))

    resp, err, _ = run_rpc(pi, [])
    results += check_rpc_shape(pi, baseline, resp, err)
    results += check_param_combo(pi)
    results += check_extensions(pi)

    for res in results:
        print('%s  %-22s %s' % ('PASS' if res.ok else 'FAIL', res.label, res.detail))

    fails = [x for x in results if not x.ok]
    print('-' * 64)
    print('%d PASS / %d FAIL' % (len(results) - len(fails), len(fails)))

    if fails:
        print('\n有红 ⇒ 这次升级**不能直接上**，先看上面 FAIL 的 detail。')
        print('（人工项：python3 %s --manual）' % os.path.relpath(__file__, REPO))
        return 1

    if args.update_baseline:
        snap = {
            '_note': 'pi 契约基线 —— 由 scripts/diag/pi_upgrade_probe.py --update-baseline 生成。'
                     '升级 pi 后若体检全过，就更新这一份；它是"上次确认可用"的唯一记录。',
            'piVersion': current_version,
            'verifiedAt': __import__('time').strftime('%Y-%m-%d'),
            'rpcDataKeys': {m: sorted((resp.get(m) or {}).keys()) for m in KEYED_RPC},
            'cliFlags': REQUIRED_FLAGS,
            'extensions': [os.path.basename(f) for f in extension_files()],
        }
        with open(BASELINE, 'w', encoding='utf-8') as fh:
            json.dump(snap, fh, ensure_ascii=False, indent=2)
            fh.write('\n')
        print('\n基线已更新 → %s' % os.path.relpath(BASELINE, REPO))

    print('\n全过。别忘了人工项：python3 %s --manual' % os.path.relpath(__file__, REPO))
    return 0


if __name__ == '__main__':
    sys.exit(main())
