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
//             {"type":"send_result","bot":"<id>","ok":false,"msg":"..","file":{"ok":false,"msg":"..","kind":"file"}}
//    ⚠️ 带附件的那一帧里 `file` 是**子对象**（`ok`/`msg` 仍描述整帧）—— 失败原因分三段:
//      读文件 / 上传素材（`code=99991672` 没开权限、`234006` 超 30MB）/ 发消息。
//             {"type":"error","msg":"..."}
//   App → 桥  {"type":"send","bot":"<id>","chat_id":"oc_..","text":"...","ref":"<uuid>"}
//             {"type":"send","bot":"<id>","chat_id":"oc_..","text":"..","file":{"path":"/Users/..","name":".."}}
//             {"type":"stop"}
//   ⚠️ 附件**只给本地绝对路径**，不给二进制: 桥自己读盘（同 TCC 归属），协议保持一行 JSON。
//   ⚠️ **`ref` 原样回传**（2026-11-23）: App 用它把"这一条发没发出去"对上**具体那一条**
//      （`agent_sent` 的主键）。不回传的话只能知道"最近有一次发送失败了" —— 而那种含糊
//      会让"已发消息"记忆里出现一条永远说不清状态的记录。没给 `ref` 的帧照旧回 null。
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

// ── 发附件（图片 `im/v1/images` / 文件 `im/v1/files` → 拿 key → 发消息）────
//
// 三段是飞书规定的，少一段都不行: 上传素材拿 key，再用 `msg_type=image|file` 发。
// ⚠️ 两个接口要的 `*_type` 是**两套词表**, 别混:
//   · 图片 `image_type`: 只有 `message` 能用。实测 `avatar` 也返回 200，但 key 前缀是
//     `v3_...` 而不是 `img_v3_...` —— 拿它发消息会失败。**选错不会在上传那一刻报错。**
//   · 文件 `file_type`: opus/mp4/pdf/doc/xls/ppt/stream。
//
// ⚠️ `file_type` 的映射实测过（2026-11-19）: `.docx` 配 `doc` 和 `stream` **都返回 200**。
//   所以"上传成功"证明不了选对了 —— 差别在接收端: 具体类型（doc/ppt/xls/pdf）飞书能直接
//   预览，`stream` 只是一坨附件。既然两条都通，就选具体类型。（这也推翻了原来那条猜测
//   "doc 只认老扩展名会失败"。）
const IMAGE_MSG_TYPE = 'message';

/** 扩展名 → file_type。认不出来的走 `stream`（飞书对它的接受面最宽）。 */
function fileTypeFor(name) {
  const ext = (String(name).split('.').pop() || '').toLowerCase();
  switch (ext) {
    case 'pdf': return 'pdf';
    case 'doc': case 'docx': return 'doc';
    case 'xls': case 'xlsx': case 'csv': return 'xls';
    case 'ppt': case 'pptx': return 'ppt';
    case 'mp4': return 'mp4';
    case 'opus': return 'opus';
    default: return 'stream';
  }
}

/** 图片扩展名（决定走哪个上传接口，不是决定 file_type）。 */
function isImageName(name) {
  return /\.(png|jpe?g|gif|bmp|webp|tiff?)$/i.test(String(name));
}

async function uploadImage(bot, bytes, name) {
  const t = await accessToken(bot);
  const fd = new FormData();
  fd.append('image_type', IMAGE_MSG_TYPE);
  fd.append('image', new Blob([bytes]), name);
  const r = await fetch(`${BASE}/open-apis/im/v1/images`, {
    method: 'POST', headers: { Authorization: `Bearer ${t}` }, body: fd,
  });
  const j = await r.json();
  return { ok: j.code === 0, code: j.code, msg: j.msg, image_key: j.data && j.data.image_key };
}

async function uploadFile(bot, bytes, name) {
  const t = await accessToken(bot);
  const fd = new FormData();
  fd.append('file_type', fileTypeFor(name));
  fd.append('file_name', name);
  fd.append('file', new Blob([bytes]), name);
  const r = await fetch(`${BASE}/open-apis/im/v1/files`, {
    method: 'POST', headers: { Authorization: `Bearer ${t}` }, body: fd,
  });
  const j = await r.json();
  return { ok: j.code === 0, code: j.code, msg: j.msg, file_key: j.data && j.data.file_key };
}

/**
 * 发一个附件。`spec` = `{ path, name? }`。
 *
 * ⚠️ **读文件放在这里、而不是在 App 侧先读好再传** —— 桥跟 App 是同一棵进程树的子进程，
 *    TCC 归属相同；但让 App 把整个文件读进内存再用 stdin 传，会把 NDJSON 协议变成
 *    一条"要拼大小"的二进制通道。桥自己读，协议保持一行 JSON。
 *
 * ⚠️ 读不到（不存在 / 没权限 / 是个目录）必须给**不同的话**：这三种在接收端都表现为
 *    "没收到文件"，而原因差得远 —— 用户能动手解决的只有前两种。
 */
async function sendAttachment(bot, chatId, spec) {
  const path = spec && spec.path;
  if (!path) return { ok: false, msg: 'no path' };
  let bytes;
  try {
    const st = fs.statSync(path);
    if (st.isDirectory()) return { ok: false, msg: `是个目录，不是文件: ${path}` };
    bytes = fs.readFileSync(path);
  } catch (e) {
    const code = (e && e.code) || '';
    const why = code === 'ENOENT' ? '文件不存在'
      : (code === 'EPERM' || code === 'EACCES') ? '没有权限读它（系统可能没给这个目录授权）'
      : `读不了（${code || e}）`;
    return { ok: false, msg: `${why}: ${path}` };
  }
  const name = spec.name || path.split('/').pop();
  const image = isImageName(name);
  const up = image ? await uploadImage(bot, bytes, name) : await uploadFile(bot, bytes, name);
  if (!up.ok) {
    // 99991672 = 应用没开"上传素材"权限。**这条要单独认出来**: 它是配置问题，
    // 换哪个文件都失败，而文案里带申请链接（飞书自己给的），照着点就能修。
    const hint = up.code === 99991672
      ? ' —— 这个机器人没开通「上传素材」权限，去开放平台加 im:resource:upload（或 im:resource）后发布版本'
      : (up.code === 234006 ? ' —— 文件超过 30 MB' : '');
    return { ok: false, code: up.code, msg: (up.msg || 'upload failed') + hint, kind: image ? 'image' : 'file' };
  }
  const t = await accessToken(bot);
  const content = image ? { image_key: up.image_key } : { file_key: up.file_key };
  const r = await fetch(`${BASE}/open-apis/im/v1/messages?receive_id_type=chat_id`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${t}` },
    body: JSON.stringify({
      receive_id: chatId,
      msg_type: image ? 'image' : 'file',
      content: JSON.stringify(content),
    }),
  });
  const j = await r.json();
  return {
    ok: j.code === 0, code: j.code, msg: j.msg,
    kind: image ? 'image' : 'file',
    message_id: j.data && j.data.message_id,
  };
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
      emit({ type: 'send_result', bot: cmd.bot || '', ok: false, ref: cmd.ref || null, msg: 'unknown bot' });
      return;
    }
    try {
      // 一帧可以同时带文本和附件（先文本后附件 —— 人读起来是"说明在上面、文件在下面"）。
      // ⚠️ 两段各自可能成/败，但只**回一帧** `send_result`: 协议面越窄越好排查，
      //    而附件那一段的细节放在 `file` 子对象里，不改变原有的 `ok`/`msg` 语义。
      let textRes = null;
      let fileRes = null;
      let ok = true;
      let msg = '';
      if (cmd.text) {
        textRes = await sendText(bot, cmd.chat_id, cmd.text);
        if (!textRes.ok) { ok = false; msg = textRes.msg || 'send failed'; }
      }
      // 文本没发出去就不再发附件: 附件没有上下文，收到一坨文件比没收到更让人困惑。
      if (ok && cmd.file) {
        fileRes = await sendAttachment(bot, cmd.chat_id, cmd.file);
        if (!fileRes.ok) { ok = false; msg = fileRes.msg || 'attachment failed'; }
      }
      emit({
        type: 'send_result',
        bot: bot.id,
        ok,
        ref: cmd.ref || null,
        msg,
        message_id: (textRes && textRes.message_id) || (fileRes && fileRes.message_id),
        file: fileRes ? { ok: fileRes.ok, msg: fileRes.msg || '', kind: fileRes.kind, message_id: fileRes.message_id } : null,
      });
    } catch (e) {
      emit({ type: 'send_result', bot: bot.id, ok: false, ref: cmd.ref || null, msg: String((e && e.message) || e) });
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
