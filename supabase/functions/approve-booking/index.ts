// approve-booking v5 (2026-07-02)
// v5: Add a SECOND authorized caller so the admin DASHBOARD can confirm/decline direct
//     bookings through this same function (single source of truth -> no orphaned entries).
//     - GET  + ?sig=  : signed Telegram/email links (unchanged, returns an HTML page).
//     - POST + Bearer : authenticated owner session (supabase.functions.invoke), returns JSON.
//     Either a valid HMAC signature OR a valid Supabase auth session authorizes the action.
// v4: On CONFIRM, add an Airbnb block-dates reminder to the Telegram note AND the page.
// v3: HTML entities in the confirmation page so it never mojibakes.
// v2: On CONFIRM, send guest full Acknowledgement Receipt via GAS (action='confirmEmail').
// v1: Promote/cancel hold + inquiry + ledger. HMAC-SHA256 over (id,action) keyed by SERVICE key.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SIG_PREFIX = 'approve-booking:v1:';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

function esc(s: unknown): string {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

function page(inner: string, status = 200): Response {
  const doc = '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>Cascade Hideaway</title></head>' +
    '<body style="margin:0;background:#F7F2E8;font-family:Arial,Helvetica,sans-serif;color:#1C1006;">' +
    '<div style="max-width:520px;margin:0 auto;padding:44px 20px;text-align:center;">' +
    '<div style="font-family:Georgia,serif;font-size:26px;">Cascade Hideaway</div>' +
    '<div style="font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#C9963A;margin:4px 0 24px;">Hotel Comfort. Home Warmth.</div>' +
    '<div style="background:#FBF7EE;border:1px solid #ecdcc0;border-radius:14px;padding:30px 24px;">' + inner + '</div>' +
    '</div></body></html>';
  return new Response(doc, { status, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}

async function hmacHex(key: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, enc.encode(msg));
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
}
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
async function tgSend(token: string, chatId: string, text: string): Promise<void> {
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text }),
    signal: AbortSignal.timeout(15_000),
  }).catch(() => {});
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const url    = new URL(req.url);
  const isPost = req.method === 'POST';

  let id = '', action = '', sig = '';
  if (isPost) {
    try { const b = await req.json(); id = String(b.id ?? ''); action = String(b.action ?? ''); } catch { /* handled below */ }
  } else {
    id     = url.searchParams.get('id')     ?? '';
    action = url.searchParams.get('action') ?? '';
    sig    = url.searchParams.get('sig')    ?? '';
  }

  // Response helpers: JSON for dashboard (POST), HTML page for signed links (GET).
  const fail = (msg: string, code: number) => isPost ? json({ ok: false, error: msg }, code) : page('<p style="font-size:16px;">' + msg + '</p>', code);

  if (!id || (action !== 'confirm' && action !== 'decline'))
    return fail('Invalid request.', 400);

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

  // ── Authorization: valid HMAC signature (links) OR valid Supabase session (dashboard) ──
  let authorized = false;
  if (sig) {
    const expected = await hmacHex(serviceKey, SIG_PREFIX + id + ':' + action);
    authorized = timingSafeEqual(sig.toLowerCase(), expected);
  } else {
    const authHeader = req.headers.get('Authorization') ?? '';
    if (authHeader.startsWith('Bearer ')) {
      try {
        const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!,
          { global: { headers: { Authorization: authHeader } } });
        const { data: u } = await anon.auth.getUser();
        authorized = !!(u && u.user);
      } catch { authorized = false; }
    }
  }
  if (!authorized) return fail('This link is invalid or has expired.', 403);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);

  const { data: bk } = await db.from('booking_inquiries')
    .select('id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, total_amount, deposit_amount, receipt_image_path, status')
    .eq('id', id).maybeSingle();
  if (!bk) return fail('Booking not found.', 404);
  const booking = bk;

  const who   = esc(bk.guest_name) + '<br>' + esc(bk.checkin_date) + ' &rarr; ' + esc(bk.checkout_date);
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN');
  const chat  = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
  const ref   = String(id).slice(0, 8).toUpperCase();
  const relayUrl   = Deno.env.get('EMAIL_RELAY_URL');
  const relayToken = Deno.env.get('EMAIL_RELAY_TOKEN');

  async function sendConfirmEmail(): Promise<void> {
    if (!relayUrl || !relayToken || !booking.guest_email) return;
    const nights = Math.round(
      (new Date(booking.checkout_date).getTime() - new Date(booking.checkin_date).getTime()) / 86_400_000);
    await fetch(relayUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action:      'confirmEmail',
        token:       relayToken,
        ref,
        guest_name:  booking.guest_name,
        guest_email: booking.guest_email,
        guest_phone: booking.guest_phone ?? '',
        checkin:     booking.checkin_date,
        checkout:    booking.checkout_date,
        nights,
        pax:         booking.pax ?? 1,
        total:       booking.total_amount ?? 0,
        deposit:     booking.deposit_amount ?? 0,
        receipt_url: booking.receipt_image_path ?? '',
      }),
      signal: AbortSignal.timeout(20_000),
    }).catch((e) => { console.error('[approve-booking] confirm email failed:', String(e)); });
  }

  if (action === 'confirm') {
    if (bk.status === 'confirmed')
      return isPost
        ? json({ ok: true, status: 'confirmed', already: true, checkin: bk.checkin_date, checkout: bk.checkout_date })
        : page('<p style="font-size:19px;color:#C9963A;">Already confirmed</p><p style="font-size:15px;">' + who + '</p>');
    const { error: transitionError } = await db.rpc('apply_direct_booking_transition', { p_booking_id: id, p_action: 'confirm' });
    if (transitionError) return fail('Unable to confirm this booking at the moment.', 500);
    await db.from('calendar_events').update({ status: 'confirmed' }).eq('uid', 'direct:' + id);
    await db.from('transactions').update({ status: 'confirmed' }).eq('external_ref', id);
    await sendConfirmEmail();
    if (token && chat) await tgSend(token, chat, `Booking CONFIRMED by admin - ${bk.guest_name} (${bk.checkin_date} to ${bk.checkout_date}) - Ref ${ref}. Guest emailed their confirmation.\n\n⚠️ ACTION NEEDED: Block these dates on Airbnb now to prevent a double-booking (direct bookings do NOT sync to Airbnb):\n📅 ${bk.checkin_date} → ${bk.checkout_date}\nAirbnb app → Calendar → tap the date(s) → Block.`);
    return isPost
      ? json({ ok: true, status: 'confirmed', checkin: bk.checkin_date, checkout: bk.checkout_date,
               reminder: `Block ${bk.checkin_date} → ${bk.checkout_date} on Airbnb to prevent a double-booking.` })
      : page(
      '<p style="font-size:21px;color:#C9963A;">&#10003; Booking confirmed</p>' +
      '<p style="font-size:15px;"><strong>' + who + '</strong></p>' +
      '<p style="color:#7d6f5c;font-size:13px;margin-top:14px;">The dates now show as confirmed on the calendar and in the daily ops digest, the income is counted in the ledger, and the guest has been emailed their booking confirmation.</p>' +
      '<div style="margin-top:16px;padding:12px 14px;background:#FBEEDB;border:1px solid #C9963A;border-radius:10px;text-align:left;">' +
      '<div style="font-weight:700;color:#1C1006;font-size:13px;">&#9888; Block these dates on Airbnb</div>' +
      '<div style="color:#5c5140;font-size:12px;margin-top:4px;">Direct bookings do not sync to Airbnb. Open Airbnb &rarr; Calendar and block <strong>' + esc(bk.checkin_date) + ' &rarr; ' + esc(bk.checkout_date) + '</strong> to prevent a double-booking.</div>' +
      '</div>');
  } else {
    if (bk.status === 'cancelled')
      return isPost
        ? json({ ok: true, status: 'cancelled', already: true })
        : page('<p style="font-size:19px;">Already declined</p><p style="font-size:15px;">' + who + '</p>');
    const { error: transitionError } = await db.rpc('apply_direct_booking_transition', { p_booking_id: id, p_action: 'cancel' });
    if (transitionError) return fail('Unable to cancel this booking at the moment.', 500);
    await db.from('calendar_events').update({ status: 'cancelled' }).eq('uid', 'direct:' + id);
    await db.from('transactions').update({ status: 'void' }).eq('external_ref', id);
    if (token && chat) await tgSend(token, chat, `Booking DECLINED by admin - ${bk.guest_name} (${bk.checkin_date} to ${bk.checkout_date}) - Ref ${ref}. Dates released.`);
    return isPost
      ? json({ ok: true, status: 'cancelled' })
      : page(
      '<p style="font-size:21px;">Booking declined</p>' +
      '<p style="font-size:15px;"><strong>' + who + '</strong></p>' +
      '<p style="color:#7d6f5c;font-size:13px;margin-top:14px;">The dates have been released and the ledger entry voided. No email was sent to the guest.</p>');
  }
});
