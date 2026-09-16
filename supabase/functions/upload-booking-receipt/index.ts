import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withHeader } from '../_shared/cascade-core/format.ts';
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
  const notify = notifyFinance(db, claim.bookingId, objectPath).catch((e) => console.error('[upload-booking-receipt] finance card failed:', String(e)));
  if (edge?.waitUntil) edge.waitUntil(notify); else await notify;

  return response({ ok: true });
});

// deno-lint-ignore no-explicit-any
async function notifyFinance(db: any, bookingId: string, objectPath: string): Promise<void> {
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN'), chat = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
  if (!token || !chat) return;
  const { data: b } = await db.from('booking_inquiries').select('guest_name,checkin_date,checkout_date,deposit_amount,total_amount,status').eq('id', bookingId).maybeSingle() as { data: Record<string, unknown> | null };
  if (!b) return;
  const ref = bookingId.slice(0, 8).toUpperCase();
  const peso = (n: unknown) => Number(n ?? 0).toLocaleString('en-PH');
  const caption = withHeader('finance', `receipt ${ref}`, [
    `📎 Receipt uploaded — ${b.guest_name} · ${b.checkin_date} → ${b.checkout_date}`,
    `💳 Expected: ₱${peso(b.deposit_amount)} of ₱${peso(b.total_amount)} · status ${b.status}`,
    `🔗 Review: https://cascadereservations-del.github.io/cascade-admin-dashboard/#/bookings/direct/${bookingId}`,
  ].join('\n'));
  const { data: signed } = await db.storage.from(BUCKET).createSignedUrl(objectPath, 3600);
  const url = signed?.signedUrl;
  const isImage = /\.(jpe?g|png|webp)$/i.test(objectPath);
  const body = url
    ? { chat_id: chat, [isImage ? 'photo' : 'document']: url, caption: caption.slice(0, 1024) }
    : { chat_id: chat, text: caption };
  const method = url ? (isImage ? 'sendPhoto' : 'sendDocument') : 'sendMessage';
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
  if (!r.ok) console.error('[upload-booking-receipt] telegram non-ok', r.status, (await r.text().catch(() => '')).slice(0, 200));
}
