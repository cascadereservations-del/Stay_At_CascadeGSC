import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';

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

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  try {
    const body = await req.json();
    const { fileData, fileName, mimeType = 'image/jpeg', sessionDate } = body;

    if (!fileData || !fileName) {
      return json({ ok: false, error: 'fileData and fileName are required' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } }
    );

    // Organise under YYYY-MM-DD subfolder so Drive mirrors the date structure
    const date = sessionDate || new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
    const path = `${date}/${fileName}`;

    const bytes = decodeBase64(fileData);

    const { data, error } = await supabase.storage
      .from('cleaning-photos')
      .upload(path, bytes, {
        contentType: mimeType,
        upsert: true,   // idempotent: re-upload same name is safe
      });

    if (error) throw error;

    // Build public URL
    const { data: { publicUrl } } = supabase.storage
      .from('cleaning-photos')
      .getPublicUrl(data.path);

    return json({ ok: true, path: data.path, publicUrl });

  } catch (err) {
    console.error('upload-photo error:', err);
    return json({ ok: false, error: String(err) }, 500);
  }
});
