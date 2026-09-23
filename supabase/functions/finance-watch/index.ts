// finance-watch v1 (phase 5, D-106 #5, 2026-09-13). Daily payment watch for the Finance group.
// Posts only when something is overdue; the rules and wording live in watch.ts (tested), the shape in
// cascade-core/format.ts. Runs from pg_cron (see stay-site migration 20260913160000) or any POST.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { renderReport, withHeader } from '../_shared/cascade-core/format.ts';
import { budgetNotice, overdue, watchReport, due } from './watch.ts';
// v2 (session 26, 2026-09-16, Telegram plan §4/§5): 🟡 ATTENTION header; posts on day 2, day 5,
// then weekly per overdue item (due() in watch.ts) instead of every morning. The Monday Finance
// roll-up (daily-digest) still lists everything overdue, so nothing is ever silent for a week.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN     = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const FINANCE_CHAT = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';
const PROPERTY_ID  = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const JSON_H       = { 'Content-Type': 'application/json' };

let sendFailures = 0;
async function tgSend(chatId: string, text: string): Promise<void> {
  if (!TG_TOKEN || !chatId) { console.warn('tgSend: missing token or chatId'); return; }
  const res = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_H,
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
    signal: AbortSignal.timeout(15_000),
  }).catch(err => { console.error('tgSend fetch error:', String(err)); return null; });
  if (res && !res.ok) console.error('tgSend non-ok:', res.status, await res.text().catch(() => '').then(t => t.slice(0, 200)));
  // SPEC-17 (D-212): the caller decides whether a failed send is a failed run.
  if (!res?.ok) sendFailures += 1;
}

Deno.serve(withObservability({ functionName: 'finance-watch', route: 'finance' }, async (req: Request) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  if (!FINANCE_CHAT) return new Response(JSON.stringify({ ok: false, error: 'FINANCE_CHAT not configured' }), { status: 500, headers: JSON_H });
  const db = createClient(SUPABASE_URL, SERVICE_ROLE);
  const hb0 = heartbeat(db, 'finance-watch-daily');
  sendFailures = 0;
  const hb = (phase: 'started' | 'succeeded' | 'failed', code?: string) => phase === 'succeeded' && sendFailures > 0 ? hb0('failed', `TELEGRAM_SEND_FAILED:${sendFailures}`) : hb0(phase, code);
  await hb('started');
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
  try {
    const [{ data: airbnb, error: e1 }, { data: direct, error: e2 }] = await Promise.all([
      db.from('airbnb_reservations').select('confirmation_code,guest_name,checkin_date,host_payout,payout_email_message_id,status')
        .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').is('payout_email_message_id', null).lte('checkin_date', today),
      db.from('booking_inquiries').select('id,guest_name,checkin_date,deposit_amount,submitted_at,receipt_image_path,status')
        .eq('property_id', PROPERTY_ID).eq('status', 'pending').is('receipt_image_path', null).gte('checkin_date', today),
    ]);
    if (e1 || e2) throw new Error(String(e1?.message ?? e2?.message));
    const items = overdue(today, airbnb ?? [], direct ?? []);
    const report = watchReport(today, airbnb ?? [], direct ?? []);
    const force = new URL(req.url).searchParams.get('force') === '1'; // hand-run check, ignores cadence
    const send = !!report && (force || items.some((i) => due(i.days)));
    console.log(JSON.stringify({ event: 'finance_watch', date: today, overdue: items.length, codes: items.map((i) => i.code), send }));
    if (report && send) await tgSend(FINANCE_CHAT, withHeader('attention', `${items.length} payment${items.length === 1 ? '' : 's'} overdue`, renderReport(report)));
    // D-222: OpenRouter is the primary model route - read its balance once a day and warn Finance at 80% of the limit.
    const orKey = Deno.env.get('CASCADE_OPENROUTER_BOT_KEY');
    if (orKey) {
      const kr = await fetch('https://openrouter.ai/api/v1/key', { headers: { Authorization: `Bearer ${orKey}` }, signal: AbortSignal.timeout(10_000) }).catch(() => null);
      const kj = kr?.ok ? await kr.json().catch(() => null) : null;
      const usage = Number(kj?.data?.usage ?? 0), limit = typeof kj?.data?.limit === 'number' ? kj.data.limit : null;
      console.log(JSON.stringify({ event: 'openrouter_budget', status: kr?.status ?? 0, usage, limit }));
      const note = budgetNotice({ status: kr?.status ?? 0, usage, limit });
      if (note) await tgSend(FINANCE_CHAT, withHeader('attention', 'model budget', note));
    }
    await hb('succeeded');
    return new Response(JSON.stringify({ ok: true, date: today, overdue: items.length, sent: send }), { status: 200, headers: JSON_H });
  } catch (err) {
    console.error('finance-watch error:', String(err));
    await hb('failed', String(err).slice(0, 80));
    return new Response(JSON.stringify({ ok: false, error: String(err) }), { status: 500, headers: JSON_H });
  }
}));
