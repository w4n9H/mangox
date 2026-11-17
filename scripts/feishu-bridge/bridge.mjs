// MangoX 飞书桥（P19.2 S15）
//
// 它只做两件事：把飞书长连接的事件转成一行 JSON 写进 stdout；把 stdin 里的
// `{"type":"send"}` 变成一次发消息请求。**不含任何业务判断** —— 谁是白名单、投给
// 哪个助理、要不要回，全在 Swift 侧。桥是哑的，这是它能被单测的前提。
//
// 协议（NDJSON，一行一个对象）：
//   桥 → App  {"type":"status","connected":true|false,"note":"..."}
//             {"type":"message","chat_id":"oc_..","chat_type":"p2p","message_id":"om_..",
//              "create_time":"1794898655254","text":"Hi","msg_type":"text",
//              "sender_type":"user","open_id":"ou_.."}
//             {"type":"send_result","ok":true,"message_id":"om_.."} / {"ok":false,"msg":"..."}
//             {"type":"error","msg":"..."}
//   App → 桥  {"type":"send","chat_id":"oc_..","text":"..."}
//             {"type":"stop"}
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

const appId = process.env.FS_APP_ID;
const appSecret = process.env.FS_APP_SECRET;
const BASE = process.env.FS_BASE || 'https://open.feishu.cn';

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

if (!appId || !appSecret) {
  emit({ type: 'error', msg: 'missing FS_APP_ID / FS_APP_SECRET' });
  process.exit(2);
}

// ── token 缓存：2 小时有效，提前 5 分钟刷新 ─────────────────────────────
let token = '';
let tokenExpireAt = 0;
async function accessToken() {
  if (token && Date.now() < tokenExpireAt) return token;
  const r = await fetch(`${BASE}/open-apis/auth/v3/tenant_access_token/internal`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ app_id: appId, app_secret: appSecret }),
  });
  const j = await r.json();
  if (j.code !== 0) throw new Error(`token failed: ${j.code} ${j.msg}`);
  token = j.tenant_access_token;
  tokenExpireAt = Date.now() + Math.max(60, (j.expire || 7200) - 300) * 1000;
  return token;
}

// ── 发消息（用 fetch，不走 SDK 的 client：少一层依赖、错误形状自己控） ──
async function sendText(chatId, text) {
  const t = await accessToken();
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

// ── 收消息 ────────────────────────────────────────────────────────────
const wsClient = new Lark.WSClient({
  appId,
  appSecret,
  loggerLevel: Lark.LoggerLevel.warn,
});

const dispatcher = new Lark.EventDispatcher({}).register({
  'im.message.receive_v1': async (data) => {
    // 3 秒约束：ACK 在这里就返回，活儿挪走。
    setImmediate(() => {
      try {
        const m = data.message || {};
        const s = data.sender || {};
        let text = '';
        try {
          // content 是 **JSON 字符串**（实测："{\"text\":\"Hi\"}"）⇒ 必须二次解析
          const c = JSON.parse(m.content || '{}');
          text = typeof c.text === 'string' ? c.text : '';
        } catch {
          text = '';
        }
        emit({
          type: 'message',
          chat_id: m.chat_id,
          chat_type: m.chat_type,
          message_id: m.message_id,
          create_time: m.create_time,   // 毫秒**字符串**，原样传，不在桥里转
          msg_type: m.msg_type,
          text,
          sender_type: s.sender_type,
          open_id: (s.sender_id || {}).open_id,
        });
      } catch (e) {
        emit({ type: 'error', msg: String((e && e.message) || e) });
      }
    });
    return {};
  },
});

const startedAt = Date.now();
wsClient.start({ eventDispatcher: dispatcher });

// 连接状态：SDK 不给连接回调 ⇒ 用「启动后 2 秒乐观置 true」+ 发送失败时置 false。
// ⚠️ 这是近似值，界面文案不要写成"已连接"这种绝对话（见 Swift 侧 note）。
setTimeout(() => {
  emit({
    type: 'status',
    connected: true,
    note: `bridge up in ${Date.now() - startedAt}ms`,
  });
}, 2000);

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
    try {
      emit(Object.assign({ type: 'send_result' }, await sendText(cmd.chat_id, cmd.text || '')));
    } catch (e) {
      emit({ type: 'send_result', ok: false, msg: String((e && e.message) || e) });
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
