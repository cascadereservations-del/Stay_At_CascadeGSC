// release-expired-holds v1 (session 26, 2026-09-16, hold-before-pay D-160 #1 / audit plan 5b step 5).
// Hourly via pg_cron. A direct booking request that is still `pending` with no receipt 24 h after
// it was submitted stops blocking the calendar: status -> expired, its calendar_events hold ->
// cancelled, its pending_review income row -> void, one 🟡 ATTENTION card to Finance with the
// guest's contact and a ready-to-send line. The guest e-mail goes through the GAS relay only when
// HOLD_EXPIRY_EMAIL_ACTION names an action the relay implements (it has ackEmail/confirmEmail
// today; the expiry template is Lloyd's to add) - until then the Finance card carries the message.
// ponytail: no per-guest state table; idempotent because the status flips to expired.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { withHeader } from '../_shared/cascade-core/format.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN     = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const FINANCE_CHAT = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';
const RELAY_URL    = Deno.env.get('EMAIL_RELAY_URL') ?? '';
const RELAY_TOKEN  = Deno.env.get('EMAIL_RELAY_TOKEN') ?? '';
const EMAIL_ACTION = Deno.env.get('HOLD_EXPIRY_EMAIL_ACTION') ?? '';
const PROPERTY_ID  = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const HOLD_HOURS   = Number(Deno.env.get('HOLD_EXPIRY_HOURS') ?? 24);
const JSON_H       = { 'Content-Type': 'application/json' };

async function tgSend(text: string): Promise<void> {
  if (!TG_TOKEN || !FINANCE_CHAT) return;
  const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_H, body: JSON.stringify({ chat_id: FINANCE_CHAT, text, disable_web_page_preview: true }), signal: AbortSignal.timeout(15_000),
  }).catch((e) => { console.error('tgSend', String(e)); return null; });
  if (r && !r.ok) console.error('tgSend non-ok', r.status, (await r.text().catch(() => '')).slice(0, 200));
}

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const dm = (d: string) => { const x = new Date(d.slice(0, 10) + 'T00:00:00Z'); return `${x.getUTCDate()} ${MON[x.getUTCMonth()]}`; };
const peso = (n: unknown) => Number(n ?? 0).toLocaleString('en-PH');

Deno.serve(withObservability({ functionName: 'release-expired-holds', route: 'finance' }, async (req: Request) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  const db = createClient(SUPABASE_URL, SERVICE_ROLE);
  const hb = heartbeat(db, 'release-expired-holds-hourly');
  await hb('started');
  const dry = new URL(req.url).searchParams.get('dry') === '1';
  try {
    // v2 (D-162): only rows that hold a booking_holds row can expire, and only the definer RPC can
    // touch that table. A pay-first request (within 5 days, no hold row) is never expired here,
    // whatever its receipt state. Before the RPC exists this function releases nothing.
    let rows: Array<Record<string, any>> = [];
    if (dry) {
      const { data, error } = await db.from('booking_inquiries')
        .select('id,guest_name,checkin_date,submitted_at').eq('property_id', PROPERTY_ID).eq('source', 'direct').eq('status', 'pending').is('receipt_image_path', null)
        .lt('submitted_at', new Date(Date.now() - HOLD_HOURS * 3_600_000).toISOString());
      if (error) throw new Error(error.message);
      rows = (data ?? []) as Array<Record<string, any>>;
    } else {
      const { data, error } = await db.rpc('expire_booking_holds_v1');
      if (error) throw new Error('expire_booking_holds_v1: ' + error.message);
      rows = (Array.isArray(data) ? data : []) as Array<Record<string, any>>;
    }
    const cutoff = 'booking_holds.expires_at < now()';
    const released: string[] = [];
    for (const b of rows) {
      const ref = 'DIR-' + String(b.id).slice(0, 8).toUpperCase();
      if (dry) { released.push(ref + ' (candidate by age; the RPC decides)'); continue; }
      const guestLine = `Hi ${String(b.guest_name).split(' ')[0]}, your hold for ${dm(b.checkin_date)}–${dm(b.checkout_date)} at Cascade Hideaway has been released because we did not receive the ₱${peso(b.deposit_amount)} reservation fee within ${HOLD_HOURS} hours. The dates are open again — if you still want them, book again at the site and send the receipt right after.`;
      await tgSend(withHeader('attention', `hold expired ${ref}`, [
        `Hold released: ${b.guest_name} · ${dm(b.checkin_date)} → ${dm(b.checkout_date)} · ₱${peso(b.deposit_amount)} of ₱${peso(b.total_amount)} never arrived.`,
        '',
        `• Submitted ${new Date(b.submitted_at).toLocaleString('en-PH', { timeZone: 'Asia/Manila', hour12: false })}`,
        `• Contact: ${b.guest_phone}${b.guest_email ? ` · ${b.guest_email}` : ''}`,
        `• Calendar hold cancelled, ledger row voided${EMAIL_ACTION ? ', guest e-mailed' : ''}`,
        '',
        `Do: if they paid by another route, restore it from the dashboard; otherwise send them: "${guestLine}"`,
      ].join('\n')));
      if (EMAIL_ACTION && RELAY_URL && RELAY_TOKEN && b.guest_email) {
        await fetch(RELAY_URL, { method: 'POST', headers: JSON_H, signal: AbortSignal.timeout(20_000),
          body: JSON.stringify({ action: EMAIL_ACTION, token: RELAY_TOKEN, ref: ref.slice(4), guest_name: b.guest_name, guest_email: b.guest_email, checkin: b.checkin_date, checkout: b.checkout_date, deposit: b.deposit_amount, hold_hours: HOLD_HOURS, message: guestLine }),
        }).then(async (r) => console.log('relay', r.status, (await r.text().catch(() => '')).slice(0, 200))).catch((e) => console.error('relay failed', String(e)));
      }
      released.push(ref);
    }
    console.log(JSON.stringify({ event: 'release_expired_holds', dry, cutoff, candidates: (rows ?? []).length, released }));
    await hb('succeeded');
    return new Response(JSON.stringify({ ok: true, dry, cutoff, released }), { status: 200, headers: JSON_H });
  } catch (err) {
    console.error('release-expired-holds error:', String(err));
    await hb('failed', String(err).slice(0, 80));
    return new Response(JSON.stringify({ ok: false, error: String(err) }), { status: 500, headers: JSON_H });
  }
}));
