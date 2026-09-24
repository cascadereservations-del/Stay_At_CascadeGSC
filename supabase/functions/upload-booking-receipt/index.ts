import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withHeader, groups, doSend, autoKeyboard } from '../_shared/cascade-core/format.ts';
import { CAPTION_MAX, guestFollowUp, hostDoLine, overpaymentLines, priorUseLines, verdictOf, type Lang, type PriorUse } from './followup.ts';
import { hasVisionKey, visionExtractText, parseModelJson } from '../_shared/cascade-core/vision.ts';
import {
  buildReceiptObjectPath,
  validateReceiptUpload,
  verifyReceiptUploadToken,
} from '../_shared/receipt-security.ts';

const BUCKET = 'booking-receipts';
const MAX_RECEIPT_BYTES = 10 * 1024 * 1024;
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-receipt-filename',
  'Content-Type': 'application/json',
};

function response(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}

function tokenFromRequest(request: Request): string {
  const authorization = request.headers.get('authorization') ?? '';
  return authorization.replace(/^Bearer\s+/i, '').trim();
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (request.method !== 'POST') return response({ error: 'method_not_allowed' }, 405);

  const uploadSecret = Deno.env.get('BOOKING_RECEIPT_UPLOAD_SECRET');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!uploadSecret || !supabaseUrl || !serviceKey) return response({ error: 'receipt_upload_unavailable' }, 503);

  const claim = await verifyReceiptUploadToken(tokenFromRequest(request), uploadSecret);
  if (!claim) return response({ error: 'invalid_upload_token' }, 401);

  const declaredLength = Number(request.headers.get('content-length') ?? 0);
  if (!Number.isFinite(declaredLength) || declaredLength < 1 || declaredLength > MAX_RECEIPT_BYTES) {
    return response({ error: 'file_too_large' }, 413);
  }

  const bytes = new Uint8Array(await request.arrayBuffer());
  const db = createClient(supabaseUrl, serviceKey);
  const { data: booking, error: bookingError } = await db
    .from('booking_inquiries')
    .select('id, receipt_image_path')
    .eq('id', claim.bookingId)
    .maybeSingle();
  if (bookingError || !booking) return response({ error: 'invalid_upload_token' }, 401);

  const validation = validateReceiptUpload({
    filename: request.headers.get('x-receipt-filename') ?? '',
    mimeType: request.headers.get('content-type') ?? '',
    bytes,
    contentLength: bytes.byteLength,
    existingReceiptPath: booking.receipt_image_path,
  });
  if (!validation.ok) return response({ error: validation.error }, validation.error === 'file_too_large' ? 413 : 400);

  const objectPath = buildReceiptObjectPath(claim.bookingId, claim.nonce, validation.extension);
  const { error: uploadError } = await db.storage.from(BUCKET).upload(objectPath, bytes, {
    contentType: request.headers.get('content-type') ?? undefined,
    upsert: false,
  });
  if (uploadError) return response({ error: 'receipt_upload_failed' }, 500);

  const { data: updated, error: updateError } = await db
    .from('booking_inquiries')
    .update({ receipt_image_path: objectPath })
    .eq('id', claim.bookingId)
    .is('receipt_image_path', null)
    .select('id')
    .maybeSingle();
  if (updateError || !updated) {
    await db.storage.from(BUCKET).remove([objectPath]);
    return response({ error: 'receipt_already_uploaded' }, 409);
  }

  // v2 (session 26, hold-before-pay D-160 #1): the receipt is Finance's cue to review, so it goes to
  // the Finance group as its own card the moment it lands (before v2 no receipt was ever forwarded:
  // submit-booking ran before the upload and always said "pending or not provided").
  const edge = (globalThis as unknown as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  // v3 (session 27, booking PRD task 3): the upload is also the evidence producer Module C waited for —
  // OCR the proof, record_payment_evidence_candidate -> compare_booking_payment_evidence, then the card
  // carries what was read plus [Confirm]/[Decline] taps (telegram-expense bk_ok/bk_no -> a definer RPC
  // that maps the tapper's Telegram id to a staff profile). The dashboard link stays beside them (C1).
  const notify = produceEvidence(db, claim.bookingId, claim.nonce, bytes, request.headers.get('content-type') ?? '', objectPath)
    .then((ev) => notifyFinance(db, claim.bookingId, objectPath, ev)).catch((e) => console.error('[upload-booking-receipt] finance card failed:', String(e)));
  if (edge?.waitUntil) edge.waitUntil(notify); else await notify;

  return response({ ok: true });
});

const PAYMENT_PROMPT = `You are reading a Philippine payment proof (GCash, Maya, bank transfer, InstaPay/PESONet screenshot or a deposit slip) that a guest sent to pay for a stay. Return ONLY a JSON object with exactly these keys:
{"amount": number|null, "currency": "PHP", "reference": string|null, "date": "YYYY-MM-DD"|null, "sender_name": string|null, "channel": string|null, "confidence": number}
Rules: amount = the amount sent, as a plain number without symbols. reference = the transaction or reference number exactly as printed, else null. channel e.g. "GCash", "Maya", "BPI", "BDO". confidence 0-1 that amount and reference are right. If the image is not a payment proof, set amount null and confidence below 0.2. Never invent a reference you cannot see.`;

type Read = { amount: number | null; reference: string | null; date: string | null; sender_name: string | null; channel: string | null; confidence: number };
type Evidence = { read: Read | null; candidateId: string | null; comparisonId: string | null; note: string | null };

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource)), (b) => b.toString(16).padStart(2, '0')).join('');
}

// deno-lint-ignore no-explicit-any
async function produceEvidence(db: any, bookingId: string, nonce: string, bytes: Uint8Array, mime: string, objectPath: string): Promise<Evidence> {
  let read: Read | null = null, note: string | null = null;
  const readable = /^image\/(jpeg|png|webp)$/i.test(mime) && hasVisionKey();
  if (readable) {
    try {
      const j = parseModelJson<Partial<Read>>(await visionExtractText(PAYMENT_PROMPT, bytes, mime, 'Cascade Guest Receipt'), {});
      const amt = Number(j.amount);
      const ref = String(j.reference ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
      read = { amount: Number.isFinite(amt) && amt > 0 ? amt : null, reference: ref.length >= 4 && ref.length <= 64 ? ref : null,
        date: /^\d{4}-\d{2}-\d{2}$/.test(String(j.date ?? '')) ? String(j.date) : null, sender_name: j.sender_name ? String(j.sender_name).slice(0, 80) : null,
        channel: j.channel ? String(j.channel).slice(0, 40) : null, confidence: Math.max(0, Math.min(1, Number(j.confidence) || 0)) };
    } catch (e) { note = 'OCR failed: ' + String(e).slice(0, 80); console.error('[upload-booking-receipt] ocr', String(e)); }
  } else note = mime.startsWith('application/pdf') ? 'PDF — not read automatically' : 'no vision key';
  const { data: candId, error: cErr } = await db.rpc('record_payment_evidence_candidate', {
    p_booking_id: bookingId, p_source_type: 'receipt_ocr', p_source_artifact_id: `receipt:${nonce}`, p_content_hash: await sha256Hex(bytes),
    p_idempotency_key: `receipt-ocr:${bookingId}:${nonce}`, p_parser_version: 'receipt-ocr-v1', p_observed_at: new Date().toISOString(),
    p_amount: read?.amount ?? null, p_currency: read ? 'PHP' : null, p_reference: read?.reference ?? null, p_confidence: read?.confidence ?? null,
    p_advisory_labels: read?.channel ? [read.channel.toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 40)].filter((l) => /^[a-z0-9_]{2,40}$/.test(l)) : [],
    p_failure_code: read ? null : 'unreadable',
  });
  if (cErr || !candId) { console.error('[upload-booking-receipt] candidate', cErr?.message); return { read, candidateId: null, comparisonId: null, note: note ?? 'evidence not recorded' }; }
  const { data: cmpId, error: mErr } = await db.rpc('compare_booking_payment_evidence', { p_booking_id: bookingId, p_candidate_ids: [candId] });
  if (mErr || !cmpId) { console.error('[upload-booking-receipt] compare', mErr?.message); return { read, candidateId: candId, comparisonId: null, note: note ?? 'comparison not recorded' }; }
  console.log(JSON.stringify({ event: 'payment_evidence_recorded', booking_id: bookingId, candidate_id: candId, comparison_id: cmpId, object: objectPath.length }));
  return { read, candidateId: candId, comparisonId: cmpId, note };
}

// deno-lint-ignore no-explicit-any
async function notifyFinance(db: any, bookingId: string, objectPath: string, ev: Evidence): Promise<void> {
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN'), chat = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
  if (!token || !chat) return;
  const { data: b } = await db.from('booking_inquiries').select('guest_name,checkin_date,checkout_date,deposit_amount,total_amount,status').eq('id', bookingId).maybeSingle() as { data: Record<string, unknown> | null };
  if (!b) return;
  const ref = bookingId.slice(0, 8).toUpperCase();
  const peso = (n: unknown) => Number(n ?? 0).toLocaleString('en-PH');
  const expected = Number(b.deposit_amount) > 0 ? Number(b.deposit_amount) : Number(b.total_amount);
  const r = ev.read;
  const readLine = r && r.amount !== null
    ? `🔍 Read: ₱${peso(r.amount)}${r.channel ? ` via ${r.channel}` : ''}${r.reference ? ` · ref ${r.reference}` : ' · no reference seen'}${r.date ? ` · ${r.date}` : ''} · ${Math.round(r.confidence * 100)} %`
    : r ? '🔍 Read: no completed payment on this image (no amount found) — it may be the screen before sending'
    : `🔍 Not read automatically${ev.note ? ` (${ev.note})` : ''} — check the image`;
  // Session 29: a sample reply for the guest when the image is not a payment proof or the amount is short, in the
  // register of their Messenger thread (site uploads have no thread: English).
  const v = verdictOf(r, expected);
  // SPEC-10 control 3: has this exact image, or this reference number, already been used on a
  // DIFFERENT booking here? record_payment_evidence_candidate only ever looked inside one booking,
  // so a screenshot resent under new dates was invisible. Advisory: if the read fails the card
  // still goes out, one warning poorer — it must never cost Finance the receipt itself.
  let priorUse: PriorUse[] = [];
  if (ev.candidateId) {
    const { data: prior, error: pErr } = await db.rpc('prior_receipt_use_v1', { p_candidate_id: ev.candidateId });
    if (pErr) console.error('[upload-booking-receipt] prior use', pErr.message);
    else priorUse = (prior ?? []) as PriorUse[];
  }
  const { data: th } = await db.from('concierge_threads').select('booking_flow').eq('booking_flow->>booking_id', bookingId).maybeSingle() as { data: { booking_flow?: { lang?: Lang } } | null };
  const sample = guestFollowUp(v, th?.booking_flow?.lang ?? 'en', String(b.guest_name ?? ''), expected, r?.amount ?? 0);
  const verdict = r && r.amount !== null
    ? (Math.abs(r.amount - expected) < 0.5 ? `⚖️ Amount matches the ₱${peso(expected)} expected` : `⚖️ ₱${peso(Math.abs(r.amount - expected))} ${r.amount < expected ? 'SHORT' : 'over'} — expected ₱${peso(expected)}`)
    : null;
  // SPEC-10 control 2: the old Do line said "Confirm only once the payment is real" without saying
  // how you would know. hostDoLine names the one check a forged screenshot cannot survive — the
  // money being in the wallet. It returns null for not_proof / unread, where there is no amount to
  // go looking for, and the two original lines still apply there.
  const doLine = ev.comparisonId
    ? (hostDoLine(v, r?.amount ?? null, r?.reference ?? null)
       ?? (sample ? 'Do: open the image. If no full payment shows, reply to the guest; Confirm only once the payment is real.'
                  : 'Do: open the image, then tap Confirm if the payment is real — Decline if not.'))
    : 'Do: review in the dashboard (evidence row was not recorded).';
  const caption = withHeader('finance', `receipt ${ref}`, groups(
    priorUseLines(priorUse),
    [`📎 Receipt uploaded — ${b.guest_name}`, `📅 ${b.checkin_date} → ${b.checkout_date} · status ${b.status}`],
    [`💳 Expected: ₱${peso(b.deposit_amount)} of ₱${peso(b.total_amount)}`, readLine, verdict],
    v === 'over' && r?.amount != null ? overpaymentLines(r.amount, expected) : [],
    [doLine, `🔗 https://cascadereservations-del.github.io/cascade-admin-dashboard/#/bookings/direct/${bookingId}`],
    sample ? doSend('the guest', sample) : [],
  ));
  const { data: signed } = await db.storage.from(BUCKET).createSignedUrl(objectPath, 3600);
  const url = signed?.signedUrl;
  const isImage = /\.(jpe?g|png|webp)$/i.test(objectPath);
  const reply_markup = autoKeyboard(caption, ev.comparisonId
    ? [{ text: '✅ Confirm booking', callback_data: `bk_ok:${ev.comparisonId}` }, { text: '❌ Decline', callback_data: `bk_no:${ev.comparisonId}` }]
    : []);
  const send = async (method: string, payload: Record<string, unknown>) => {
    const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), signal: AbortSignal.timeout(20_000) });
    if (!res.ok) console.error('[upload-booking-receipt] telegram non-ok', res.status, (await res.text().catch(() => '')).slice(0, 200));
  };
  const attach = isImage ? 'photo' : 'document';
  // SPEC-10: Telegram caps a photo CAPTION at 1024 characters. Before the fraud lines the card never
  // came near it; a card carrying the duplicate group, the overpayment group AND a sample reply is
  // about 1150, and the old `.slice(0, 1024)` would have cut exactly the tail — the 📨 line that the
  // Copy / Revise taps read back off the message. When the card is too long the image goes up bare
  // and the card follows as its own message, which is where the buttons go: the tap handler reads
  // whichever message it was tapped on, so they must travel with the text, not the picture.
  if (url && caption.length > CAPTION_MAX) {
    await send(isImage ? 'sendPhoto' : 'sendDocument', { chat_id: chat, [attach]: url });
    await send('sendMessage', { chat_id: chat, text: caption, reply_markup });
    return;
  }
  if (url) await send(isImage ? 'sendPhoto' : 'sendDocument', { chat_id: chat, [attach]: url, caption, reply_markup });
  else await send('sendMessage', { chat_id: chat, text: caption, reply_markup });
}
