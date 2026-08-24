import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
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

  return response({ ok: true });
});
