// finance-watch v1 (phase 5, D-106 #5, 2026-09-13). Daily payment watch for the Finance group.
// Posts only when something is overdue; the rules and wording live in watch.ts (tested), the shape in
// cascade-core/format.ts. Runs from pg_cron (see stay-site migration 20260913160000) or any POST.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { renderReport } from '../_shared/cascade-core/format.ts';
import { overdue, watchReport } from './watch.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN     = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const FINANCE_CHAT = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';
const PROPERTY_ID  = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const JSON_H       = { 'Content-Type': 'application/json' };

async function tgSend(chatId: string, text: string): Promise<void> {
  if (!TG_TOKEN || !chatId) { console.warn('tgSend: missing token or chatId'); return; }
  const res = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_H,
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
    signal: AbortSignal.timeout(15_000),
  }).catch(err => { console.error('tgSend fetch error:', String(err)); return null; });
  if (res && !res.ok) console.error('tgSend non-ok:', res.status, await res.text().catch(() => '').then(t => t.slice(0, 200)));
}

Deno.serve(withObservability({ functionName: 'finance-watch', route: 'finance' }, async (req: Request) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  if (!FINANCE_CHAT) return new Response(JSON.stringify({ ok: false, error: 'FINANCE_CHAT not configured' }), { status: 500, headers: JSON_H });
  const db = createClient(SUPABASE_URL, SERVICE_ROLE);
  const hb = heartbeat(db, 'finance-watch-daily');
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
    console.log(JSON.stringify({ event: 'finance_watch', date: today, overdue: items.length, codes: items.map((i) => i.code) }));
    if (report) await tgSend(FINANCE_CHAT, renderReport(report));
    await hb('succeeded');
    return new Response(JSON.stringify({ ok: true, date: today, overdue: items.length, sent: !!report }), { status: 200, headers: JSON_H });
  } catch (err) {
    console.error('finance-watch error:', String(err));
    await hb('failed', String(err).slice(0, 80));
    return new Response(JSON.stringify({ ok: false, error: String(err) }), { status: 500, headers: JSON_H });
  }
}));
