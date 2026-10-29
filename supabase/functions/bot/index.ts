// Бот конференции УРСП и игры «Калейдоскоп вопросов» — Supabase Edge Function.
//
// Telegram присылает сюда каждое сообщение (вебхук). Ответ собирает SQL-функция kaleido.bot()
// и возвращается Telegram прямо в ответе на вебхук.
// Раз в минуту pg_cron вызывает ?tick=1: рассылки и напоминания (kaleido.bot_due) и самонастройка бота.
//
// Единственный секрет — TELEGRAM_BOT_TOKEN (Edge Functions → Secrets). Сменили токен в @BotFather —
// обновите секрет: через минуту бот перенастроится сам.
import postgres from 'npm:postgres@3.4.5';

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { prepare: false, max: 3, idle_timeout: 20 });
const TOKEN = (Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '').trim();
const SELF_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/$/, '') + '/functions/v1/bot';

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
const sha256 = async (s: string) => hex(await crypto.subtle.digest('SHA-256', enc.encode(s)));
async function hmac(key: string, msg: string) {
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', k, enc.encode(msg)));
}

// Производные от токена: ключ входа (как у Telegram Mini Apps) и секрет вебхука. Сам токен в базу не попадает.
let keys: Promise<{ webapp: string; secret: string }> | null = null;
const derived = () => (keys ??= (async () => {
  const webapp = await hmac('WebAppData', TOKEN);
  return { webapp, secret: await sha256('kaleido-webhook:' + webapp) };
})());

async function tg(method: string, body: unknown) {
  const r = await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  return await r.json() as { ok: boolean; description?: string; error_code?: number; result?: any };
}

const json = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), { status, headers: { 'content-type': 'application/json' } });

// Вебхук, команды, кнопка «Играть», описание. Повторяется, только если токен или адрес поменялись.
async function ensureSetup(log: string[]) {
  const { webapp, secret } = await derived();
  const mark = (await sha256(webapp + '|' + SELF_URL)).slice(0, 16);
  const [{ done }] = await sql`select kaleido.cfg('bot_setup_mark') as done`;
  if (done === mark) return;
  // сначала ключ входа: по нему kaleido.bot() узнаёт секрет вебхука
  await sql`insert into kaleido.config (key, value) values ('telegram_webapp_secret', ${webapp})
            on conflict (key) do update set value = excluded.value`;
  const [{ s }] = await sql`select kaleido.bot_setup() as s`;  // команды, описание, адрес игры
  const steps: [string, unknown][] = [
    ['setWebhook', { url: SELF_URL, secret_token: secret, max_connections: 40,
      allowed_updates: ['message', 'callback_query', 'my_chat_member'] }],
    ['setMyCommands', { commands: s.commands }],
    ['setChatMenuButton', { menu_button: { type: 'web_app', text: 'Играть', web_app: { url: s.webapp_url } } }],
    ['setMyDescription', { description: s.description }],
    ['setMyShortDescription', { short_description: s.short_description }],
  ];
  let ok = true;
  for (const [m, b] of steps) {
    const r = await tg(m, b);
    log.push(`${m}: ${r.ok ? 'ok' : r.description}`);
    ok &&= r.ok;
  }
  await sql`insert into kaleido.config (key, value) values ('bot_setup_mark', ${ok ? mark : ''})
            on conflict (key) do update set value = excluded.value`;
}

// callback_data в Telegram — не длиннее 64 байт; кириллица — 2 байта на букву.
function fit(topic: string) {
  let t = topic;
  while (enc.encode(`rate:${t}:5`).length > 64) t = t.slice(0, -1);
  return t;
}
const stars = (topic: string) => [[1, 2, 3, 4, 5].map((n) => ({ text: '★'.repeat(n), callback_data: `rate:${fit(topic)}:${n}` }))];

// Рассылки и напоминания: всё, что пора отправить. Не чаще 25 сообщений в секунду.
async function sendDue(log: string[]) {
  const rows = await sql`select r from kaleido.bot_due() as r`;
  let sent = 0, failed = 0;
  for (const { r } of rows) {
    const markup = r.kind === 'rating'
      ? { inline_keyboard: stars(r.topic) }
      : { inline_keyboard: [[{ text: r.button_text, web_app: { url: r.webapp_url } }]] };
    const res = await tg('sendMessage', { chat_id: r.chat_id, text: r.text, parse_mode: 'HTML', reply_markup: markup });
    if (res.ok) sent++;
    else {
      failed++;
      if (res.error_code === 403 || /blocked|deactivated|chat not found|kicked/i.test(res.description ?? '')) {
        await sql`select kaleido.bot_mark_blocked(${r.chat_id}::bigint)`;
      } else if (res.error_code === 429) {
        await new Promise((ok) => setTimeout(ok, 1000 * ((res as any).parameters?.retry_after ?? 3)));
      }
    }
    await new Promise((ok) => setTimeout(ok, 40));
  }
  if (rows.length) log.push(`sent ${sent}, failed ${failed}`);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (!TOKEN) return json({ error: 'TELEGRAM_BOT_TOKEN не задан: Edge Functions → Secrets' }, 503);

  // Раз в минуту из pg_cron (и вручную для проверки: открыть …/functions/v1/bot?tick=1).
  if (url.searchParams.has('tick')) {
    const log: string[] = [];
    try {
      await ensureSetup(log);
      await sendDue(log);
      return json({ ok: true, log });
    } catch (e) {
      console.error(e);
      return json({ ok: false, error: String(e), log }, 500);
    }
  }

  // Вебхук Telegram: без верного секретного заголовка — молча 200 и ничего.
  if (req.method !== 'POST') return json({ ok: true, bot: 'kaleido' });
  const { secret } = await derived();
  if (req.headers.get('x-telegram-bot-api-secret-token') !== secret) return json({});
  try {
    const update = await req.json();
    const [{ r }] = await sql`select kaleido.bot(${sql.json({ secret, update })}::jsonb) as r`;
    return json(r && r.method ? r : {});
  } catch (e) {
    console.error(e);
    return json({});  // Telegram повторяет запрос, если ответ не 200
  }
});
