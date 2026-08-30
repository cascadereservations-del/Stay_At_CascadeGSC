import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// Decode base64 string that may or may not carry a data-URI prefix
function decodeBase64(raw: string): Uint8Array {
  const clean = raw.includes(',') ? raw.split(',')[1] : raw;
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function safeFileName(raw: string): string {
  const clean = raw.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  if (!clean || clean.length > 120 || !/\.(jpe?g|png|webp)$/.test(clean)) {
    throw new Error('invalid_file_name');
  }
  return clean;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  try {
    const body = await req.json();
    const { fileData, fileName, mimeType = 'image/jpeg', propertyId, submissionId } = body;

    if (!fileData || !fileName || !propertyId || !submissionId) {
      return json({ ok: false, error: 'fileData, fileName, propertyId and submissionId are required' }, 400);
    }
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

    if (typeof fileData !== 'string' || fileData.length > 7_100_000) {
      return json({ ok: false, error: 'invalid_image_size' }, 413);
    }
    const bytes = decodeBase64(fileData);
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
});
