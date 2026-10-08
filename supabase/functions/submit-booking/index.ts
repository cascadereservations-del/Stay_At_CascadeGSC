// submit-booking v18 (s78: hourly cap per hashed caller; calendar hold written first, 23P01 answered as dates_unavailable)
// v17 (SPEC-34: the stored rate card is authoritative for the stored total and deposit)
// Creates the booking request and returns a short-lived, booking-scoped token
// for the optional private receipt upload. The browser never supplies a
// Storage path or URL and cannot write to booking-receipts directly.
// v11.7 (2026-07-02): FIX last-minute deposit. The site charges 100% when check-in is
//   under 5 days away (else 50%; was 48h until D-185, 2026-09-18; R4 2026-10-01 follows the site). The old sanity check only accepted ~50% and clamped the full
//   payment back to 50%, so last-minute bookings were recorded + emailed as 50%. Now accept
//   the client deposit if it matches EITHER the 50% reservation fee OR the full total.
// v12.1: remove service-signed decision URLs; Module C requires named AAL2 Finance review.
// v11.5: email relay -> GAS action='ackEmail'. v11.4: approve/decline buttons.
// v11.2: calendar hold on submit. v11.1: plain-text finance summary. v11: receipt to Finance.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { issueReceiptUploadToken } from '../_shared/receipt-security.ts';
import { normalizeEmail, normalizePhilippinePhone } from '../_shared/guest-identity.ts';
import { mintStatusToken } from '../_shared/guest-access-token.ts';
// v13 (session 26, 2026-09-16, Telegram plan §1/§5): Finance card opens with the shared header
// and carries guest_context_v1 lines for a returning direct guest (empty for a first-timer).
import { cardMarkup, financeCard, opsCard, siteNotes, viaOf, type InquiryView } from '../_shared/cascade-core/inquiry.ts'; // SPEC-38: the request card with its decision buttons
import { guestContext, guestContextLines } from '../_shared/cascade-core/tools.ts';
// v17 (session 55, SPEC-34, D-262): the stored rate card is authoritative. The client's total is ignored (it only
// chooses fee or full: pay_full); the server stores and returns its own total and deposit.
import { FULL_PAY_WITHIN_DAYS, loadCard, serverAmounts } from '../_shared/cascade-core/pricing.ts';
import { callerHash, clientIp } from './caller.ts'; // v18 (s78, TASKS #21): the hourly cap per caller

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'apikey, authorization, content-type',
  'Content-Type': 'application/json',
};

const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
// SPEC-42 s6: the status link keeps its token in the fragment, which a browser never sends to a server or a referrer.
const STATUS_PAGE = 'https://cascadereservations-del.github.io/Stay_At_CascadeGSC/stay.html#t=';

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: CORS });
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
    .in('key', ['min_nights', 'max_nights']);
  const setting = (k: string, fb: number) =>
    Number((settings ?? []).find(s => s.key === k)?.value ?? fb);
  const minNights  = setting('min_nights',  1);
  const maxNights  = setting('max_nights', 30);

  if (nights < minNights)
    return json({ error: 'below_minimum_nights', min_nights: minNights }, 400);
  if (nights > maxNights)
    return json({ error: 'above_maximum_nights', max_nights: maxNights }, 400);

  // v18 (s78, TASKS #21): at most 10 requests an hour from one caller, counted before anything is written. Only an HMAC
  // of the address is stored (booking_submit_attempts). Messenger requests all come from the Concierge's Edge Function,
  // so they share one address; at Cascade's volume 10 an hour is far above a real day. A failed count lets the request
  // through: the cap is against floods and must never cost a guest their booking.
  const callerIp = clientIp(req.headers);
  if (!callerIp) console.warn(JSON.stringify({ event: 'submit_cap_no_ip' }));
  else {
    const { data: allowed, error: capErr } = await db.rpc('booking_submit_allowed_v1', { p_ip_hash: await callerHash(SERVICE_KEY, callerIp) });
    if (capErr) console.warn('[submit-booking] booking_submit_allowed_v1 failed (request allowed):', capErr.message);
    else if (allowed === false) {
      console.log(JSON.stringify({ event: 'submit_capped' }));
      return json({ error: 'too_many_requests' }, 429);
    }
  }

  const card = await loadCard(db);
  const depositPct = card.deposit_pct;
  const amounts = serverAmounts(card, checkinStr, checkoutStr, { payFull: body.pay_full, total: clientTotal, deposit: clientDeposit });
  const { q, full: payFull } = amounts;
  const totalAmount   = amounts.total;
  const depositAmount = amounts.deposit;
  if (amounts.mismatch) console.log(JSON.stringify({ event: 'client_total_mismatch', client_total: clientTotal, client_deposit: clientDeposit, total: totalAmount, deposit: depositAmount }));

  // SPEC-30 (D-233, D-239): a guest who changed dates releases their OWN earlier unpaid request first (same phone
  // and e-mail, no receipt, last 24 h) - and only when the new dates are then free, so moving onto somebody else's
  // dates changes nothing and the 409 below answers as before. A failure here only means today's behaviour.
  const { data: sup, error: supErr } = await db.rpc('supersede_pending_direct_requests_v1', {
    p_property_id: PROPERTY_ID, p_email: guestEmail, p_phone: guestPhone, p_checkin: checkinStr, p_checkout: checkoutStr,
  });
  if (supErr) console.warn('[submit-booking] supersede_pending_direct_requests_v1 failed (non-fatal):', supErr.message);
  else if ((sup?.superseded ?? []).length) console.log(JSON.stringify({ event: 'hold_superseded', ids: sup.superseded }));

  const { data: avail, error: availErr } = await db
    .rpc('check_availability', { p_checkin: checkinStr, p_checkout: checkoutStr, p_property_id: PROPERTY_ID });
  if (availErr) return json({ error: 'availability_check_failed' }, 500);
  if (!avail.available)
    return json({ error: 'dates_unavailable', conflicts: avail.conflicts }, 409);

  // ── Calendar hold FIRST (blocks dates immediately; pending until approved) ──
  // v18 (s78, TASKS #20b): calendar_events_direct_no_overlap refuses a second live direct row on any night (23P01). Two
  // requests racing past check_availability both used to get a hold; now the loser is told the dates are gone before its
  // request exists, so no Finance card, e-mail or income row is made for it. The id is chosen here so the uid can
  // name the request before the request row is written.
  const bookingId = crypto.randomUUID();
  const { error: ce } = await db.from('calendar_events').insert({
    property_id:   PROPERTY_ID,
    uid:           'direct:' + bookingId,
    source:        'direct',
    status:        'blocked',
    recon_status:  'manual_entry',
    checkin_date:  checkinStr,
    checkout_date: checkoutStr,
    guest_name:    guestName,
    guest_phone:   guestPhone,
    raw_summary:   'Direct booking (pending review) - ' + guestName,
  });
  if (ce?.code === '23P01') return json({ error: 'dates_unavailable', conflicts: [] }, 409);
  if (ce && ce.code !== '23505')
    console.error('[submit-booking] calendar hold failed:', ce.message);

  const { data: inquiry, error: ie } = await db.from('booking_inquiries').insert({
    id:                 bookingId,
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
  if (ie || !inquiry) {
    // The hold above has no request behind it: release the nights rather than leave a ghost block (V3).
    if (!ce) await db.from('calendar_events').update({ status: 'cancelled' }).eq('property_id', PROPERTY_ID).eq('uid', 'direct:' + bookingId);
    return json({ error: 'booking_failed', detail: ie?.message }, 500);
  }

  const { data: identity, error: identityError } = await db.rpc('upsert_guest_for_booking', {
    p_property_id: PROPERTY_ID,
    p_booking_id: inquiry.id,
    p_guest_name: guestName,
    p_phone_e164: normalizePhilippinePhone(guestPhone),
    p_email_normalized: normalizeEmail(guestEmail),
    p_source: 'direct',
  });
  if (identityError) console.error('[submit-booking] guest identity resolution failed:', identityError.code);
  const resolvedGuestId: string | null = (Array.isArray(identity) ? identity[0]?.guest_id : (identity as any)?.guest_id) ?? null;

  // SPEC-42 s6: the capability link for the booking status page. Only its hash is stored; a failure only means no link.
  const statusToken = await mintStatusToken(db.from('guest_access_tokens'), { propertyId: PROPERTY_ID, bookingId: inquiry.id, checkoutDate: checkoutStr }).catch(() => null);

  const inquiryId = inquiry.id;
  const ref = inquiry.id.slice(0, 8).toUpperCase();
  const receiptUploadSecret = Deno.env.get('BOOKING_RECEIPT_UPLOAD_SECRET');
  // v14 (session 26, hold-before-pay, D-160 #1): an advance booking is a 24 h HOLD created before
  // the guest pays, so the receipt token lives as long as the hold. Last-minute (full payment) keeps 15 min.
  // D-162: a hold is offered only 5+ days out (the free-cancellation line), only when the site asked
  // for one, and never for a full payment. The hold itself is a booking_holds row (open_booking_hold_v1,
  // service_role cannot write the table) that the lifecycle guard and the hourly releaser read.
  const HOLD_HOURS = 24;
  const daysOut = Math.round((checkin.getTime() - today.getTime()) / 86_400_000);
  const isHold = body.hold === true && daysOut >= FULL_PAY_WITHIN_DAYS && !payFull;
  let holdExpiresAt: string | null = null;
  if (isHold) {
    const { data: hold, error: holdErr } = await db.rpc('open_booking_hold_v1', { p_booking_id: inquiry.id, p_hours: HOLD_HOURS });
    if (holdErr) console.warn('[submit-booking] open_booking_hold_v1 failed (non-fatal):', holdErr.message);
    else holdExpiresAt = (hold as { expires_at?: string } | null)?.expires_at ?? null;
  }
  // v16 (session 27): a Messenger guest pays inside the chat, so a pay-first request gets 2 h, not 15 min.
  // D-255 (2026-09-26): 24 h, the same window a hold gets - a guest paying in full 40 days out got 2 h and had to start over.
  const receiptUploadExpiresAt = Date.now() + (isHold ? HOLD_HOURS * 60 : body.channel === 'messenger' ? 24 * 60 : 15) * 60 * 1000;
  const receiptUploadToken = receiptUploadSecret
    ? await issueReceiptUploadToken({ bookingId: inquiry.id, nonce: crypto.randomUUID(), expiresAt: receiptUploadExpiresAt }, receiptUploadSecret)
    : null;

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
  const tgOpsId     = Deno.env.get('TELEGRAM_CHAT_ID');
  const relayUrl    = Deno.env.get('EMAIL_RELAY_URL');
  const relayToken  = Deno.env.get('EMAIL_RELAY_TOKEN');

  async function notifyTelegram(receiptSignedUrl: string | null): Promise<void> {
    if (!tgToken || !tgFinanceId) return;
    const ctxLines = guestContextLines(await guestContext(db, { guestId: resolvedGuestId, name: guestName }));
    // SPEC-38 (session 70): the request card now carries the decision buttons. The view is built here from the values already in
    // scope (no extra RPC on the submit path); telegram_inquiry_view_v1 gives the same shape to /requests and to a later tap.
    const view: InquiryView = {
      id: inquiryId, ref, guest_name: guestName, guest_email: guestEmail, guest_phone: guestPhone, checkin_date: checkinStr, checkout_date: checkoutStr,
      nights, pax, total_amount: totalAmount, deposit_amount: depositAmount, notes, submitted_at: new Date().toISOString(), status: 'pending', has_receipt: false,
      hold_expires_at: holdExpiresAt, held_by: null, held_at: null, conflict: false,
    };
    const extra = {
      lastMessage: siteNotes(notes), via: viaOf(notes), context: ctxLines,
      moneyNotes: [q.promo_nights > 0 && `🏷️ ${q.promo_name}: ${q.promo_nights} night${q.promo_nights === 1 ? '' : 's'} at ₱${Number(q.promo_rate).toLocaleString()}`,
        isHold && !holdExpiresAt && '⚠️ The 24 h hold could not be opened (hold row missing?). Nothing releases these dates until you hold or decline.'],
      contactNotes: [contactType === 'whatsapp' && '💬 WhatsApp preferred'],
    };
    const msg = financeCard(view, extra);
    const markup = cardMarkup(view, 'finance', msg);

    await fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: tgFinanceId, text: msg, disable_web_page_preview: true, reply_markup: markup }),
      signal: AbortSignal.timeout(15_000),
    }).catch(() => {});

    // OPS sees the same request with no money, phone or e-mail, and may answer the guest's message with a Cassy reply (D-297.2).
    if (tgOpsId) {
      const opsText = opsCard(view, extra);
      await fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: tgOpsId, text: opsText, disable_web_page_preview: true, reply_markup: cardMarkup(view, 'ops', opsText) }),
        signal: AbortSignal.timeout(15_000),
      }).catch(() => {});
    }

    if (receiptSignedUrl) {
      await tgSendFile(tgToken, tgFinanceId, receiptSignedUrl, `📎 Deposit receipt — ${guestName} · Ref ${ref}`);
    }
  }

  async function sendEmailRelay(receiptSignedUrl: string | null): Promise<void> {
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
      }),
      signal: AbortSignal.timeout(20_000),
    }).catch((e) => { console.error('[submit-booking] email relay failed:', String(e)); });
  }

  async function background(): Promise<void> {
    // Module C removes service-signed decision links. The future Admin queue
    // invokes approve-booking only from a named AAL2 Finance/Admin session.
    let receiptSignedUrl: string | null = null;
    await notifyTelegram(receiptSignedUrl);
    await sendEmailRelay(receiptSignedUrl);
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
    pay_full:       payFull,
    promo_nights:   q.promo_nights,
    currency:       'PHP',
    receipt_upload_token: receiptUploadToken,
    receipt_upload_expires_at: receiptUploadToken ? new Date(receiptUploadExpiresAt).toISOString() : null,
    hold: isHold,
    hold_expires_at: holdExpiresAt,
    status_url:     statusToken ? STATUS_PAGE + statusToken : null,
    message:        'Booking request received. We will confirm via Messenger or phone within 2 hours.',
  });
});
