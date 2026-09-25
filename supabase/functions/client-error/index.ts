// client-error (D-240, session 49): the free error monitor. The checklist and the booking site post their own
// errors here (verify_jwt false: the pages are public); report.ts makes them safe, record_client_error_v1 keeps one
// row per distinct error with a count, and a new error (or one still happening a day later) becomes one Telegram
// card - OPS for the checklist, Finance for the booking site. The page never has to handle this reply.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { alertable, card, fingerprint, parseReport } from './report.ts';

const ORIGINS = ['https://cascadereservations-del.github.io', 'http://localhost:8777', 'http://127.0.0.1:8777'];
const cors = (origin: string | null) => ({
  'Access-Control-Allow-Origin': origin && ORIGINS.includes(origin) ? origin : ORIGINS[0],
  'Access-Control-Allow-Headers': 'content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
});

Deno.serve(async (req: Request) => {
  const h = cors(req.headers.get('origin'));
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  const reply = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { ...h, 'Content-Type': 'application/json' } });
  if (req.method !== 'POST') return reply(405, { ok: false });
  const raw = await req.text();
  if (raw.length > 8_000) return reply(413, { ok: false });
  let body: unknown;
  try { body = JSON.parse(raw); } catch { return reply(400, { ok: false }); }
  const r = parseReport(body);
  if (!r) return reply(400, { ok: false });

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data, error } = await db.rpc('record_client_error_v1', {
    p_fingerprint: await fingerprint(r), p_app: r.app, p_kind: r.kind, p_message: r.message, p_detail: r.detail, p_alertable: alertable(r),
  });
  if (error) { console.error('record_client_error_v1', error.message); return reply(200, { ok: false }); }
  console.log(JSON.stringify({ event: 'client_error', app: r.app, kind: r.kind, message: r.message.slice(0, 120), ...data }));

  if (data?.alert) {
    const token = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
    const chat = r.app === 'checklist' ? Deno.env.get('TELEGRAM_CHAT_ID') : Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
    if (token && chat) {
      const t = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: chat, text: card(r, Number(data.count ?? 1), !!data.new), disable_web_page_preview: true }),
        signal: AbortSignal.timeout(10_000),
      }).catch((e) => { console.error('client_error telegram', String(e)); return null; });
      if (t && !t.ok) console.error('client_error telegram non-ok', t.status);
    }
  }
  return reply(200, { ok: true });
});
