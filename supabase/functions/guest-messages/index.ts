// guest-messages v1 (session 54, SPEC-05 messages 1 and 2, D-174 / D-253 / D-257).
// Hourly via pg_cron (guest-messages-hourly, minute 5) and at once from the Telegram Confirm tap (telegram-expense,
// body {booking_id, tapped: true}). Asks due_guest_messages_v1 what is due, then for each message:
//   1. the log row goes in FIRST as 'failed' (the primary key is the once-only lock; a crash leaves evidence),
//   2. the channel rule (templates.ts channelFor): Messenger inside the window, else e-mail through the relay
//      (action guestMessage), else card only; a failed Messenger send falls back to e-mail,
//   3. the row becomes 'sent' (or 'skipped' when there was no channel), and ALWAYS a card to OPS with the text on a
//      📨 ⤵ block so the host can send it by hand (telegram-expense reads that block to the end on Show as text).
// Auth: x-cascade-cron-secret (the cron job reads it from Vault, telegram-expense from the Edge secret). ?dry=1 lists.
// ponytail: no retry queue - a failed send is a 'failed' row plus the ✋ card, the host sends by hand.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { withHeader, groups, autoKeyboard } from '../_shared/cascade-core/format.ts';
import { fbSendText, threadForBooking } from '../_shared/cascade-core/messenger.ts';
import { SUBJECT, channelFor, chunks, day, render, type Key } from './templates.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN     = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const OPS_CHAT     = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
const RELAY_URL    = Deno.env.get('EMAIL_RELAY_URL') ?? '';
const RELAY_TOKEN  = Deno.env.get('EMAIL_RELAY_TOKEN') ?? '';
const JSON_H       = { 'Content-Type': 'application/json' };
const LABEL: Record<Key, string> = { confirmation: 'Message 1 (confirmation)', pre_arrival: 'Message 2 (arrival and balance)' };

async function tgSend(text: string): Promise<void> {
  if (!TG_TOKEN || !OPS_CHAT) return;
  const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_H, body: JSON.stringify({ chat_id: OPS_CHAT, text, disable_web_page_preview: true, reply_markup: autoKeyboard(text) }), signal: AbortSignal.timeout(15_000),
  }).catch((e) => { console.error('tgSend', String(e)); return null; });
  if (r && !r.ok) console.error('tgSend non-ok', r.status, (await r.text().catch(() => '')).slice(0, 200));
}

/** null when the relay accepted it, else a short reason. The relay answers {result: 'success' | 'skipped' | 'error'}. */
// deno-lint-ignore no-explicit-any
async function relay(b: Record<string, any>, ref: string, key: Key, message: string): Promise<string | null> {
  if (!RELAY_URL || !RELAY_TOKEN) return 'relay not configured';
  const r = await fetch(RELAY_URL, { method: 'POST', headers: JSON_H, signal: AbortSignal.timeout(30_000),
    body: JSON.stringify({ action: 'guestMessage', token: RELAY_TOKEN, ref, guest_name: b.guest_name, guest_email: b.guest_email, subject: SUBJECT[key], message }),
  }).catch((e) => { console.error('relay', String(e)); return null; });
  if (!r) return 'relay unreachable';
  const j = await r.json().catch(() => null);
  return r.ok && j?.result === 'success' ? null : `relay ${r.status} ${String(j?.result ?? '')} ${String(j?.message ?? '')}`.trim().slice(0, 120);
}

Deno.serve(withObservability({ functionName: 'guest-messages', route: 'ops' }, async (req: Request) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  if (!cronSecretMatches(Deno.env.get('CASCADE_CRON_SHARED_SECRET'), req.headers.get('x-cascade-cron-secret'))) {
    return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: JSON_H });
  }
  const db = createClient(SUPABASE_URL, SERVICE_ROLE);
  const dry = new URL(req.url).searchParams.get('dry') === '1';
  const body = await req.json().catch(() => ({})) as { booking_id?: string; tapped?: boolean };
  const one = typeof body.booking_id === 'string' && body.booking_id ? body.booking_id : null;
  const hb = one ? null : heartbeat(db, 'guest-messages-hourly'); // a tap is not the hourly job
  await hb?.('started');
  try {
    const { data, error } = await db.rpc('due_guest_messages_v1');
    if (error) throw new Error('due_guest_messages_v1: ' + error.message);
    const due = ((data ?? []) as Array<{ booking_id: string; message_key: Key }>).filter((d) => !one || d.booking_id === one);
    const results: Array<Record<string, unknown>> = [];
    const now = Date.now();
    for (const d of due) {
      const ref = 'DIR-' + d.booking_id.slice(0, 8).toUpperCase();
      try {
        const { data: b, error: bErr } = await db.from('booking_inquiries')
          .select('id,guest_name,guest_email,guest_phone,checkin_date,checkout_date,pax,total_amount,deposit_amount,status').eq('id', d.booking_id).maybeSingle();
        if (bErr || !b || b.status !== 'confirmed') { results.push({ ref, key: d.message_key, status: 'not_confirmed' }); continue; }
        const t = await threadForBooking(db, d.booking_id);
        const lastGuestAt = Math.max(0, ...((t?.history ?? []) as Array<{ role?: string; at?: string }>).filter((h) => h?.role === 'guest').map((h) => Date.parse(String(h.at)) || 0));
        const plan = channelFor(d.message_key, lastGuestAt, !!t, !!b.guest_email, body.tapped === true, now);
        if (dry) { results.push({ ref, key: d.message_key, channel: plan.channel, human_agent: plan.humanAgent }); continue; }

        const { error: lockErr } = await db.from('guest_message_log').insert({ booking_id: d.booking_id, message_key: d.message_key, channel: plan.channel, status: 'failed', detail: 'started' });
        if (lockErr) { results.push({ ref, key: d.message_key, status: lockErr.code === '23505' ? 'already_taken' : 'lock_failed: ' + lockErr.message }); continue; }

        const fields = { ...b, onground_name: Deno.env.get('CASCADE_ONGROUND_NAME') ?? '', onground_phone: Deno.env.get('CASCADE_ONGROUND_PHONE') ?? '' };
        let channel = plan.channel, err: string | null = null;
        if (channel === 'messenger') {
          let sent = true;
          for (const part of chunks(render(d.message_key, fields, 'messenger'))) { if (!(sent = await fbSendText(t!.psid, part, plan.humanAgent))) break; }
          if (!sent) { err = 'messenger send failed'; if (b.guest_email) { channel = 'email'; err = null; } }
        }
        if (channel === 'email') err = await relay(b, ref, d.message_key, render(d.message_key, fields, 'email'));
        const text = render(d.message_key, fields, channel);
        const status = channel === 'card_only' ? 'skipped' : err ? 'failed' : 'sent';
        await db.from('guest_message_log').update({ channel, status, detail: err ?? (plan.humanAgent && channel === 'messenger' ? 'human_agent' : null) })
          .eq('booking_id', d.booking_id).eq('message_key', d.message_key);
        // The booking is confirmed whatever the channel: the Messenger flow leaves the payment steps (was notifyMessengerBookingConfirmed's job).
        if (d.message_key === 'confirmation' && t) await db.from('concierge_threads').update({ booking_flow: { ...(t.booking_flow ?? {}), step: 'confirmed', updated_at: new Date().toISOString() }, updated_at: new Date().toISOString() }).eq('psid', t.psid);

        const outcome = status === 'sent' ? (channel === 'messenger' ? '✅ sent on Messenger' : `✅ e-mailed to ${b.guest_email}`)
          : status === 'skipped' ? '✋ not sent: no open chat and no e-mail, please send it' : `✋ not sent (${err}), please send it`;
        await tgSend(withHeader('guest', `${d.message_key} ${ref}`, groups(
          [`${LABEL[d.message_key]} for ${b.guest_name} · ${day(b.checkin_date)} → ${day(b.checkout_date)}`, outcome],
          [`👤 ${b.guest_phone ?? ''}${b.guest_email ? ` · ${b.guest_email}` : ''}`, t ? `💬 https://www.facebook.com/messages/t/${t.psid}` : null],
          [status === 'sent' ? 'Do: nothing; the text is below for your record.' : 'Do: send it by hand (Show as text, then long-press to copy).'],
        )) + `\n\n📨 ⤵\n${text}`);
        results.push({ ref, key: d.message_key, channel, status });
      } catch (e) {
        console.error('guest-messages row', ref, d.message_key, String(e));
        results.push({ ref, key: d.message_key, status: 'error' });
      }
    }
    console.log(JSON.stringify({ event: 'guest_messages', dry, one: !!one, due: due.length, results }));
    await hb?.('succeeded');
    return new Response(JSON.stringify({ ok: true, dry, due: results }), { status: 200, headers: JSON_H });
  } catch (err) {
    console.error('guest-messages error:', String(err));
    await hb?.('failed', String(err).slice(0, 80));
    return new Response(JSON.stringify({ ok: false, error: String(err) }), { status: 500, headers: JSON_H });
  }
}));
