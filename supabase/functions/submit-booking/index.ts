// submit-booking v12
// Creates the booking request and returns a short-lived, booking-scoped token
// for the optional private receipt upload. The browser never supplies a
// Storage path or URL and cannot write to booking-receipts directly.
// v11.7 (2026-07-02): FIX last-minute deposit. The site charges 100% when check-in is
//   within 48h (else 50%). The old sanity check only accepted ~50% and clamped the full
//   payment back to 50%, so last-minute bookings were recorded + emailed as 50%. Now accept
//   the client deposit if it matches EITHER the 50% reservation fee OR the full total.
// v11.6: share HMAC-signed approve/decline URLs with Telegram buttons AND host email.
// v11.5: email relay -> GAS action='ackEmail'. v11.4: approve/decline buttons.
// v11.2: calendar hold on submit. v11.1: plain-text finance summary. v11: receipt to Finance.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { issueReceiptUploadToken } from '../_shared/receipt-security.ts';
import { normalizeEmail, normalizePhilippinePhone } from '../_shared/guest-identity.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'apikey, authorization, content-type',
  'Content-Type': 'application/json',
};

const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';

const TIERS = [
  { min: 1,  max: 1,   rate: 1780 },
  { min: 2,  max: 4,   rate: 1691 },
  { min: 5,  max: 6,   rate: 1602 },
  { min: 7,  max: 13,  rate: 1513 },
  { min: 14, max: 27,  rate: 1424 },
  { min: 28, max: 999, rate: 1335 },
];
function calcExpected(nights: number): { total: number; deposit: number } {
  const tier = TIERS.find(t => nights >= t.min && nights <= t.max) ?? TIERS[0];
  const total   = tier.rate * nights;
  const deposit = Math.ceil(total * 0.5);
  return { total, deposit };
}
function near(a: number, b: number): boolean { return b > 0 && Math.abs(a - b) / b <= 0.10; }

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: CORS });
}
function manilaDatetime(): string {
  return new Date().toLocaleString('en-PH', { timeZone: 'Asia/Manila', hour12: false });
}
async function hmacHex(key: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, enc.encode(msg));
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
}
async function tgSendFile(token: string, chatId: string, fileUrl: string, caption: string): Promise<void> {
  const clean   = fileUrl.split('?')[0].toLowerCase();
  const isImage = /\.(jpe?g|png|webp|gif)$/.test(clean);
  const method  = isImage ? 'sendPhoto' : 'sendDocument';
  const field   = isImage ? 'photo' : 'document';
  const payload: Record<string, unknown> = { chat_id: chatId, caption: caption.slice(0, 1024) };
  payload[field] = fileUrl;
  await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(20_000),
  }).catch(() => {});
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const db = createClient(SUPABASE_URL, SERVICE_KEY);

  let body: Record<string, unknown>;
  try { body = await req.json(); }
  catch { return json({ error: 'invalid_json' }, 400); }

  const guestName    = String(body.guest_name   ?? '').trim();
  const guestPhone   = String(body.guest_phone  ?? '').trim();
  const guestEmail   = String(body.guest_email  ?? '').trim() || null;
  const checkinStr   = String(body.checkin_date ?? '').trim();
  const checkoutStr  = String(body.checkout_date ?? '').trim();
  const pax          = Math.max(1, Number(body.pax ?? 1));
  const notes        = String(body.notes ?? '').trim() || null;
  const contactType  = String(body.contact_type ?? 'phone').trim();

  const clientTotal   = Number(body.total_amount   ?? 0);
  const clientDeposit = Number(body.deposit_amount ?? 0);

  if (!guestName)   return json({ error: 'guest_name_required'   }, 400);
  if (!guestPhone)  return json({ error: 'guest_phone_required'  }, 400);
  if (!checkinStr)  return json({ error: 'checkin_date_required' }, 400);
  if (!checkoutStr) return json({ error: 'checkout_date_required'}, 400);

  const checkin  = new Date(checkinStr);
  const checkout = new Date(checkoutStr);
  const today    = new Date(new Date().toLocaleDateString('en-PH', { timeZone: 'Asia/Manila' }));

  if (isNaN(checkin.getTime()) || isNaN(checkout.getTime()))
    return json({ error: 'invalid_date_format' }, 400);
  if (checkin < today)
    return json({ error: 'checkin_in_past' }, 400);
  if (checkin >= checkout)
    return json({ error: 'checkin_must_be_before_checkout' }, 400);

  const nights = Math.round((checkout.getTime() - checkin.getTime()) / 86_400_000);

  const { data: settings } = await db
    .from('app_settings').select('key, value')
    .in('key', ['min_nights', 'max_nights', 'deposit_percent']);
  const setting = (k: string, fb: number) =>
    Number((settings ?? []).find(s => s.key === k)?.value ?? fb);
  const minNights  = setting('min_nights',  1);
  const maxNights  = setting('max_nights', 30);
  const depositPct = setting('deposit_percent', 50);

  if (nights < minNights)
    return json({ error: 'below_minimum_nights', min_nights: minNights }, 400);
  if (nights > maxNights)
    return json({ error: 'above_maximum_nights', max_nights: maxNights }, 400);

  const expected      = calcExpected(nights);
  const totalAmount   = (clientTotal > 0 && near(clientTotal, expected.total))
    ? clientTotal : expected.total;
  // Accept the frontend deposit if it is EITHER the 50% reservation fee OR the full total
  // (site rule: check-in within 48h => 100% full payment; otherwise 50%). Else fall back to 50%.
  const depositAmount = (clientDeposit > 0 && (near(clientDeposit, expected.deposit) || near(clientDeposit, totalAmount)))
    ? clientDeposit : Math.ceil(totalAmount * (depositPct / 100));

  const { data: avail, error: availErr } = await db
    .rpc('check_availability', { p_checkin: checkinStr, p_checkout: checkoutStr, p_property_id: PROPERTY_ID });
  if (availErr) return json({ error: 'availability_check_failed' }, 500);
  if (!avail.available)
    return json({ error: 'dates_unavailable', conflicts: avail.conflicts }, 409);

  const { data: inquiry, error: ie } = await db.from('booking_inquiries').insert({
    property_id:        PROPERTY_ID,
    guest_id:           null,
    guest_name:         guestName,
    guest_email:        guestEmail,
    guest_phone:        guestPhone,
    checkin_date:       checkinStr,
    checkout_date:      checkoutStr,
    pax,
    total_amount:       totalAmount,
    deposit_amount:     depositAmount,
    status:             'pending',
    source:             'direct',
    notes,
    receipt_image_path: null,
  }).select('id').single();
  if (ie || !inquiry) return json({ error: 'booking_failed', detail: ie?.message }, 500);

  const { error: identityError } = await db.rpc('upsert_guest_for_booking', {
    p_property_id: PROPERTY_ID,
    p_booking_id: inquiry.id,
    p_guest_name: guestName,
    p_phone_e164: normalizePhilippinePhone(guestPhone),
    p_email_normalized: normalizeEmail(guestEmail),
    p_source: 'direct',
  });
  if (identityError) console.error('[submit-booking] guest identity resolution failed:', identityError.code);

  const inquiryId = inquiry.id;
  const ref = inquiry.id.slice(0, 8).toUpperCase();
  const receiptUploadSecret = Deno.env.get('BOOKING_RECEIPT_UPLOAD_SECRET');
  const receiptUploadExpiresAt = Date.now() + 15 * 60 * 1000;
  const receiptUploadToken = receiptUploadSecret
    ? await issueReceiptUploadToken({ bookingId: inquiry.id, nonce: crypto.randomUUID(), expiresAt: receiptUploadExpiresAt }, receiptUploadSecret)
    : null;

  // ── Calendar hold (blocks dates immediately; pending until approved) ──
  {
    const { error: ce } = await db.from('calendar_events').insert({
      property_id:   PROPERTY_ID,
      uid:           'direct:' + inquiry.id,
      source:        'direct',
      status:        'blocked',
      recon_status:  'manual_entry',
      checkin_date:  checkinStr,
      checkout_date: checkoutStr,
      guest_name:    guestName,
      guest_phone:   guestPhone,
      raw_summary:   'Direct booking (pending review) - ' + guestName,
    });
    if (ce && ce.code !== '23505')
      console.error('[submit-booking] calendar hold failed:', ce.message);
  }

  // ── Write pending_review income transaction (non-blocking) ──
  db.from('transactions').insert({
    property_id:      PROPERTY_ID,
    txn_type:         'income',
    category:         'direct_booking',
    source:           'direct_booking',
    status:           'pending_review',
    transaction_date: checkinStr,
    gross_amount:     totalAmount,
    currency:         'PHP',
    payee_name:       guestName,
    booking_id:       inquiry.id,
    external_ref:     inquiry.id,
    notes:            `Direct booking — ${nights}n, ${pax} pax. Deposit ₱${depositAmount.toLocaleString()}.`,
    tax_treatment:    'vat_exempt',
    logged_by:        'submit-booking',
  }).then(({ error: te }) => {
    if (te && te.code !== '23505')
      console.error('[submit-booking] income write failed:', te.message);
  });

  // ── Background notifications (Telegram + email relay) ──
  const tgToken     = Deno.env.get('TELEGRAM_BOT_TOKEN');
  const tgFinanceId = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
  const relayUrl    = Deno.env.get('EMAIL_RELAY_URL');
  const relayToken  = Deno.env.get('EMAIL_RELAY_TOKEN');

  async function notifyTelegram(approveUrl: string, declineUrl: string, receiptSignedUrl: string | null): Promise<void> {
    if (!tgToken || !tgFinanceId) return;
    const depLabel = near(depositAmount, totalAmount) ? 'Full payment' : `Deposit (${depositPct}%)`;
    const msg = [
      `📬 New Direct Booking Inquiry`,
      `📍 Cascade Hideaway`,
      ``,
      `👤 ${guestName}`,
      `📞 ${guestPhone}`,
      ...(guestEmail  ? [`📧 ${guestEmail}`]  : []),
      ...(contactType === 'whatsapp' ? [`💬 WhatsApp preferred`] : []),
      ``,
      `📅 Check-in:  ${checkinStr}`,
      `📤 Check-out: ${checkoutStr}`,
      `🌙 Nights:    ${nights}`,
      `👥 Guests:    ${pax}`,
      ``,
      `💰 Total:    ₱${totalAmount.toLocaleString()}`,
      `💳 ${depLabel}:  ₱${depositAmount.toLocaleString()}`,
      `📎 Receipt upload: pending or not provided`,
      ...(notes      ? [``, `📝 ${notes}`] : []),
      ``,
      `🗓️ Dates held (pending your review)`,
      `📒 Ledger: pending review (confirms on approval)`,
      `⏰ ${manilaDatetime()}`,
      `🔖 Ref: ${ref}`,
    ].join('\n');

    const reply_markup = (approveUrl && declineUrl) ? { inline_keyboard: [[
      { text: '✅ Approve', url: approveUrl },
      { text: '❌ Decline', url: declineUrl },
    ]] } : undefined;

    await fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: tgFinanceId, text: msg, reply_markup }),
      signal: AbortSignal.timeout(15_000),
    }).catch(() => {});

    if (receiptSignedUrl) {
      await tgSendFile(tgToken, tgFinanceId, receiptSignedUrl, `📎 Deposit receipt — ${guestName} · Ref ${ref}`);
    }
  }

  async function sendEmailRelay(approveUrl: string, declineUrl: string, receiptSignedUrl: string | null): Promise<void> {
    if (!relayUrl || !relayToken) return;
    await fetch(relayUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action:       'ackEmail',
        token:        relayToken,
        ref,
        guest_name:   guestName,
        guest_email:  guestEmail ?? '',
        guest_phone:  guestPhone,
        checkin:      checkinStr,
        checkout:     checkoutStr,
        nights,
        pax,
        total:        totalAmount,
        deposit:      depositAmount,
        deposit_pct:  depositPct,
        // Bucket is private now — pass a short-lived signed URL (same one
        // used for Telegram) so GAS can still fetch/embed the image; a bare
        // object path would 404 for it.
        receipt_url:  receiptSignedUrl ?? '',
        notes:        notes ?? '',
        contact_type: contactType,
        approve_url:  approveUrl,
        decline_url:  declineUrl,
      }),
      signal: AbortSignal.timeout(20_000),
    }).catch((e) => { console.error('[submit-booking] email relay failed:', String(e)); });
  }

  async function background(): Promise<void> {
    const base = SUPABASE_URL + '/functions/v1/approve-booking';
    let approveUrl = '', declineUrl = '';
    try {
      const sc = await hmacHex(SERVICE_KEY, 'approve-booking:v1:' + inquiryId + ':confirm');
      const sd = await hmacHex(SERVICE_KEY, 'approve-booking:v1:' + inquiryId + ':decline');
      approveUrl = `${base}?id=${inquiryId}&action=confirm&sig=${sc}`;
      declineUrl = `${base}?id=${inquiryId}&action=decline&sig=${sd}`;
    } catch (_e) { /* links optional */ }

    // One signed URL, shared by both Telegram and the email relay, both of
    // which fire within seconds of each other here. 1 hour of validity is
    // generous headroom for either fetch, service role mints it (bypasses RLS).
    let receiptSignedUrl: string | null = null;
    await notifyTelegram(approveUrl, declineUrl, receiptSignedUrl);
    await sendEmailRelay(approveUrl, declineUrl, receiptSignedUrl);
  }

  const edge = (globalThis as unknown as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  if (edge?.waitUntil) edge.waitUntil(background());
  else await background();

  return json({
    ok:             true,
    inquiry_id:     inquiry.id,
    ref,
    nights,
    total_amount:   totalAmount,
    deposit_amount: depositAmount,
    currency:       'PHP',
    receipt_upload_token: receiptUploadToken,
    receipt_upload_expires_at: receiptUploadToken ? new Date(receiptUploadExpiresAt).toISOString() : null,
    message:        'Booking request received. We will confirm via Messenger or phone within 2 hours.',
  });
});
