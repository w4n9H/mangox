// MangoX 飞书桥（P19.2 S15 / S15b）
//
// 它只做两件事：把飞书长连接的事件转成一行 JSON 写进 stdout；把 stdin 里的
// `{"type":"send"}` 变成一次发消息请求。**不含任何业务判断** —— 归哪个助理、要不要回、
// 回什么，全在 Swift 侧。桥是哑的，这是它能被单测的前提。
//
// 协议（NDJSON，一行一个对象，**每一帧都带 `bot`**）：
//   桥 → App  {"type":"status","bot":"<id>","connected":true|false,"note":"..."}
//             {"type":"message","bot":"<id>","chat_id":"oc_..","chat_type":"p2p",
//              "message_id":"om_..","create_time":"1794898655254","text":"Hi",
//              "msg_type":"text","sender_type":"user","open_id":"ou_.."}
//    ⚠️ 出去的 `msg_type` 是**归一化后的**: 飞书事件里的原字段叫 `message_type`
//      （`msg_type` 只是发消息接口那边的参数名）。两边名字不一样，对齐是桥的职责之一。
//             {"type":"send_result","bot":"<id>","ok":true,"message_id":"om_.."} / {"ok":false,"msg":"..."}
//             {"type":"error","msg":"..."}
//   App → 桥  {"type":"send","bot":"<id>","chat_id":"oc_..","text":"..."}
//             {"type":"stop"}
//
// 一个进程管 N 个机器人（`FS_BOTS` 是个 JSON 数组）。实测同一进程里两个 `WSClient`
// 都能 ready 并共存 ⇒ 不需要"一个机器人一个进程"（那会把单实例锁、孤儿回收、诊断行
// 全变成 N 份）。机器人清单变了由 App 侧**整条重启**，桥不做热加。
//
// ⚠️ 事件回调里**立刻 return {}**（3 秒约束），真正的处理放在 setImmediate 里 ——
//    在回调里 await 网络请求会被飞书判超时并重推，表现是"同一句话进去两次"。

// ⚠️ **stdout 只许有协议行**。实测 SDK 会直接 `console.log('[info]: ...')` 打一行
//    （`event-dispatch is ready`）—— 那是 stdout，会把 App 侧的 NDJSON 解析噎住。
//    在 start 之前把 console 的四个出口全改到 stderr，协议面就干净了。
for (const k of ['log', 'info', 'warn', 'debug']) {
  console[k] = (...a) => console.error(...a);
}

import * as Lark from '@larksuiteoapi/node-sdk';
import readline from 'node:readline';
import fs from 'node:fs';

const BASE = process.env.FS_BASE || 'https://open.feishu.cn';

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function parseBots() {
  try {
    const raw = JSON.parse(process.env.FS_BOTS || '[]');
    if (!Array.isArray(raw)) return [];
    return raw.filter((b) => b && b.id && b.app_id && b.app_secret);
  } catch {
    return [];
  }
}

const bots = parseBots();
if (bots.length === 0) {
  emit({ type: 'error', msg: 'FS_BOTS 是空的（没有可连的机器人）' });
  process.exit(2);
}

/** id → 运行态（token 缓存 / WSClient）。发消息时**必须**从这里取，不能借别的机器人发。 */
const byId = new Map();

// ── 单实例锁 ──────────────────────────────────────────────────────────
// 飞书长连接是**集群随机投递**（同一事件只给一个客户端），两个桥同时在线会表现为
// "有时候回、有时候不回"。所以只许一个。
// ⚠️ 判据要带**新鲜度**: 上一个桥崩了会留下一个 pid，而那个 pid 可能已被无关进程复用
//    ⇒ 只看"pid 活着"会把新桥永久挡在门外。超过 60 秒的锁按陈旧处理（正常桥每秒都在跑，
//    不需要长时间不重写；App 侧只负责给一个稳定路径）。
const LOCK = process.env.FS_LOCK;
let lockHeld = false;
function acquireLock() {
  if (!LOCK) return true;
  try {
    const stat = fs.statSync(LOCK);
    const pid = parseInt(fs.readFileSync(LOCK, 'utf8').trim(), 10);
    const fresh = Date.now() - stat.mtimeMs < 60_000;
    if (pid && pid !== process.pid && fresh) {
      let alive = false;
      try { process.kill(pid, 0); alive = true; } catch { alive = false; }
      if (alive) {
        emit({ type: 'error', msg: `另一个桥在跑（pid ${pid}），这个不再起` });
        return false;
      }
    }
  } catch {
    // 没有锁文件 = 更好
  }
  try {
    fs.mkdirSync(LOCK.replace(/\/[^/]+$/, ''), { recursive: true });
    fs.writeFileSync(LOCK, String(process.pid));
    lockHeld = true;
  } catch {
    // 写不了锁不该把通道拖死（只影响"多开"这个边缘场景）
  }
  return true;
}

function releaseLock() {
  if (!LOCK || !lockHeld) return;
  try {
    if (fs.readFileSync(LOCK, 'utf8').trim() === String(process.pid)) fs.unlinkSync(LOCK);
  } catch {
    // 已经没了
  }
}

if (!acquireLock()) process.exit(3);
process.on('exit', releaseLock);
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => process.exit(0));

// ── token（每个机器人一份，2 小时有效，提前 5 分钟刷新） ──────────────
async function accessToken(bot) {
  if (bot.token && Date.now() < bot.tokenExpireAt) return bot.token;
  const r = await fetch(`${BASE}/open-apis/auth/v3/tenant_access_token/internal`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ app_id: bot.appId, app_secret: bot.appSecret }),
  });
  const j = await r.json();
  if (j.code !== 0) throw new Error(`token failed: ${j.code} ${j.msg}`);
  bot.token = j.tenant_access_token;
  bot.tokenExpireAt = Date.now() + Math.max(60, (j.expire || 7200) - 300) * 1000;
  return bot.token;
}

// ── 发消息（用 fetch，不走 SDK 的 client：少一层依赖、错误形状自己控） ──
async function sendText(bot, chatId, text) {
  const t = await accessToken(bot);
  const r = await fetch(`${BASE}/open-apis/im/v1/messages?receive_id_type=chat_id`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${t}` },
    body: JSON.stringify({
      receive_id: chatId,
      msg_type: 'text',
      content: JSON.stringify({ text }),
    }),
  });
  const j = await r.json();
  return { ok: j.code === 0, code: j.code, msg: j.msg, message_id: j.data && j.data.message_id };
}

// ── 每帧都要说清是哪个机器人 ──────────────────────────────────────────
function status(bot, connected, note) {
  emit({ type: 'status', bot: bot.id, connected, note });
}

function handleEvent(bot, data) {
  try {
    const m = data.message || {};
    const s = data.sender || {};
    // content 的形状**不保证是字符串**：老实测拿到的是 `"{\"text\":\"Hi\"}"`（要二次解析），
    // 但 SDK 换个版本/换个事件源就可能把对象直接塞进来 —— 那时 `JSON.parse(对象)` 抛错，
    // text 恒 ''，表现是「人在飞书发了一句，App 一条都不理」，而 App 侧只留一行
    // `feishu-ignore why=not-direct-text`（四条判据合成一条，归因不了）。
    // ⚠️ 2026-11-18 真机踩到: 私聊发「你好」，桥收到帧、App 也收到帧，但 text 是空的。
    // 所以两条形状都认，取不出正文时把**形状**报到 stderr（App 会收进日志）——
    // 只报形状不报内容，正文里可能有别人的话。
    const raw = m.content;
    let c = {};
    if (typeof raw === 'string') {
      try { c = JSON.parse(raw); } catch { c = {}; }
    } else if (raw && typeof raw === 'object') {
      c = raw;
    }
    const text = typeof c.text === 'string' ? c.text : '';
    if (!text) {
      const shape = raw === null || raw === undefined ? String(raw)
        : typeof raw === 'object' ? `object(${Object.keys(raw).join(',')})` : typeof raw;
      process.stderr.write(`[content-shape] content=${shape} msg_type=${m.msg_type} ` +
        `chat_type=${m.chat_type} sender=${s.sender_type}\n`);
    }
    emit({
      type: 'message',
      bot: bot.id,
      chat_id: m.chat_id,
      chat_type: m.chat_type,
      message_id: m.message_id,
      create_time: m.create_time,   // 毫秒**字符串**，原样传，不在桥里转
      // ⚠️ 事件里的字段叫 **`message_type`**，不叫 `msg_type`（`msg_type` 是**发消息接口**那边的
      // 参数名）。2026-11-18 真机实测：只取 `m.msg_type` ⇒ 这一格恒 undefined ⇒ App 侧拿到
      // 空串 ⇒ `isDirectText` 里 `msgType == "text"` 永假 ⇒ **每条消息都被静默丢掉**，
      // 而日志只有一句 `why=not-direct-text`（四条判据合成一条，归因不了）。
      // 两个都认：事件走 `message_type`，万一上游换了实现也还在。
      msg_type: m.message_type || m.msg_type,
      text,
      sender_type: s.sender_type,
      open_id: (s.sender_id || {}).open_id,
    });
  } catch (e) {
    emit({ type: 'error', msg: `${bot.id}: ${String((e && e.message) || e)}` });
  }
}

// ── 每个机器人一个 WSClient ───────────────────────────────────────────
for (const spec of bots) {
  const bot = {
    id: spec.id,
    appId: spec.app_id,
    appSecret: spec.app_secret,
    token: '',
    tokenExpireAt: 0,
  };
  byId.set(bot.id, bot);

  const dispatcher = new Lark.EventDispatcher({}).register({
    'im.message.receive_v1': async (data) => {
      // 3 秒约束：ACK 在这里就返回，活儿挪走。
      setImmediate(() => handleEvent(bot, data));
      return {};
    },
  });

  const client = new Lark.WSClient({
    appId: bot.appId,
    appSecret: bot.appSecret,
    loggerLevel: Lark.LoggerLevel.warn,
    // ⚠️ 连接状态**只在握手真的成功时**才算通。早先那版是"启动后 2 秒乐观置 true"，
    //    凭证填错时它照样说"通着" —— 多机器人之后这种谎话会乘以 N。
    onReady: () => status(bot, true, 'ws handshake ok'),
    onError: (err) => status(bot, false, `ws failed: ${(err && err.message) || err}`),
    onReconnecting: () => status(bot, false, 'reconnecting'),
    onReconnected: () => status(bot, true, 'reconnected'),
  });
  bot.client = client;
  status(bot, false, 'starting');
  client.start({ eventDispatcher: dispatcher }).catch((err) => {
    status(bot, false, `start failed: ${(err && err.message) || err}`);
    emit({ type: 'error', msg: `${bot.id}: start failed: ${(err && err.message) || err}` });
  });
}

// ── stdin 命令 ────────────────────────────────────────────────────────
readline.createInterface({ input: process.stdin }).on('line', async (line) => {
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch {
    emit({ type: 'error', msg: 'bad json on stdin' });
    return;
  }
  if (cmd.type === 'send') {
    const bot = byId.get(cmd.bot);
    if (!bot) {
      // 回不了就是回不了：**别拿"某个别的机器人"去发** —— 那会用错身份说话。
      emit({ type: 'send_result', bot: cmd.bot || '', ok: false, msg: 'unknown bot' });
      return;
    }
    try {
      emit(Object.assign({ type: 'send_result', bot: bot.id }, await sendText(bot, cmd.chat_id, cmd.text || '')));
    } catch (e) {
      emit({ type: 'send_result', bot: bot.id, ok: false, msg: String((e && e.message) || e) });
    }
  } else if (cmd.type === 'stop') {
    process.exit(0);
  }
});

// App 退出 / 管道断开 ⇒ 桥跟着走（否则会留一堆孤儿 node 进程）。
process.stdin.on('end', () => process.exit(0));
process.stdin.on('close', () => process.exit(0));
process.on('uncaughtException', (e) => {
  emit({ type: 'error', msg: String((e && e.message) || e) });
  process.exit(1);
});
