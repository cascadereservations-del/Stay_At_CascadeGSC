import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { withObservability } from '../_shared/observability.ts';
import { MAX_INVENTORY_BYTES, MAX_UPLOAD_BYTES, parseUploadRequest, type ParsedUpload, safeFileName } from './parse-request.ts';
import { recordUploadHash, sha256Hex } from './hash.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-cascade-file-name, x-cascade-property-id, x-cascade-submission-id, x-cascade-purpose, x-cascade-item-id',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

const SEVEN_DAYS = 7 * 24 * 3600;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// s86 D-photo: item photos (private bucket inventory-photos). Any staff role with read_operations may add or sign. This never sets
// photo_path (the client calls inventory_item_photo_set_v1 after the person confirms). All storage access is service-role.
async function inventory(req: Request, v: ParsedUpload): Promise<Response> {
  const ext = v.mimeType === 'image/jpeg' ? 'jpg' : v.mimeType === 'image/webp' ? 'webp' : null;
  if (v.action !== 'sign') {
    if (!ext) return json({ ok: false, error: 'unsupported_image_type' }, 415);
    if (!UUID_RE.test(String(v.itemId))) return json({ ok: false, error: 'invalid_item_id' }, 400);
  }
  await requireStaffAccess(req, 'read_operations', v.propertyId);
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  if (v.action === 'sign') {
    const { data, error } = await supabase.storage.from('inventory-photos').createSignedUrls(v.paths as string[], SEVEN_DAYS);
    if (error) throw error;
    const urls: Record<string, string> = {};
    for (const r of data ?? []) if (!r.error && r.signedUrl && r.path) urls[r.path] = r.signedUrl;
    return json({ ok: true, urls });
  }

  if (v.bytes.byteLength === 0 || v.bytes.byteLength > MAX_INVENTORY_BYTES) return json({ ok: false, error: 'invalid_image_size' }, 413);
  const { data: rows, error: itemError } = await supabase.from('inventory_items').select('id')
    .eq('id', v.itemId!).eq('property_id', v.propertyId).eq('is_active', true).limit(1);
  if (itemError) throw itemError;
  if (!rows?.length) return json({ ok: false, error: 'item_not_found' }, 404);

  const path = `items/${v.itemId}/${crypto.randomUUID()}.${ext}`;
  const { data, error } = await supabase.storage.from('inventory-photos')
    .upload(path, v.bytes, { contentType: v.mimeType, upsert: false, cacheControl: '31536000' });
  if (error) throw error;
  const { data: signed, error: signedError } = await supabase.storage.from('inventory-photos').createSignedUrl(data.path, SEVEN_DAYS);
  if (signedError) throw signedError;
  return json({ ok: true, path: data.path, signedUrl: signed.signedUrl });
}

Deno.serve(withObservability({ functionName: 'upload-photo', route: 'ops' }, async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  try {
    // Accepts the original JSON shape (fileData as base64) and, since WP3,
    // a raw image body (Content-Type: image/*, metadata in x-cascade-*
    // headers) — see parse-request.ts. Both converge on the same
    // {bytes, fileName, mimeType, propertyId, submissionId} shape below, so
    // nothing past this point branches on which one arrived.
    const parsed = await parseUploadRequest(req);
    if (!parsed.ok) return json({ ok: false, error: parsed.error }, parsed.status);
    const { bytes, fileName, mimeType, propertyId, submissionId } = parsed.value;
    if (parsed.value.purpose === 'inventory') return await inventory(req, parsed.value);

    if (!['image/jpeg', 'image/png', 'image/webp'].includes(mimeType)) {
      return json({ ok: false, error: 'unsupported_image_type' }, 415);
    }
    if (!/^[0-9a-f-]{36}$/i.test(String(submissionId))) {
      return json({ ok: false, error: 'invalid_submission_id' }, 400);
    }
    const identity = await requireStaffAccess(req, 'submit_cleaning', String(propertyId));

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } }
    );

    if (bytes.byteLength === 0 || bytes.byteLength > MAX_UPLOAD_BYTES) {
      return json({ ok: false, error: 'invalid_image_size' }, 413);
    }
    const path = `${propertyId}/${identity.userId}/${submissionId}/${crypto.randomUUID()}-${safeFileName(fileName)}`;

    const { data, error } = await supabase.storage
      .from('cleaning-photos')
      .upload(path, bytes, {
        contentType: mimeType,
        upsert: false,
      });

    if (error) throw error;

    const { data: signed, error: signedError } = await supabase.storage
      .from('cleaning-photos')
      .createSignedUrl(data.path, 900);
    if (signedError) throw signedError;

    // Lane C (s81): the server's own sha256 of the bytes it stored, kept for the payment-proof rule and returned as an additive key.
    const sha256 = await sha256Hex(bytes);
    await recordUploadHash(supabase, { path: data.path, sha256, uploaded_by: identity.userId });

    return json({ ok: true, path: data.path, signedUrl: signed.signedUrl, sha256 });

  } catch (err) {
    const authResponse = staffAuthResponse(err, CORS);
    if (authResponse) return authResponse;
    console.error('upload-photo error:', err);
    return json({ ok: false, error: String(err) }, 500);
  }
}));
