import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { withObservability } from '../_shared/observability.ts';
import { parseUploadRequest, safeFileName } from './parse-request.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-cascade-file-name, x-cascade-property-id, x-cascade-submission-id',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
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

    if (bytes.byteLength === 0 || bytes.byteLength > 5 * 1024 * 1024) {
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

    return json({ ok: true, path: data.path, signedUrl: signed.signedUrl });

  } catch (err) {
    const authResponse = staffAuthResponse(err, CORS);
    if (authResponse) return authResponse;
    console.error('upload-photo error:', err);
    return json({ ok: false, error: String(err) }, 500);
  }
}));
