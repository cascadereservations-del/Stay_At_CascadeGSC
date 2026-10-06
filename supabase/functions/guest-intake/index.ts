// guest-intake v1 (session 74, SPEC-42 s4b): the "Before you arrive" form on the booking status page. verify_jwt false: the guest holds
// only a capability link (guest_access_tokens), so the token is the credential. Every check lives in the definer RPCs (intake_*_v1):
// a token that opens nothing (unknown, revoked, expired, cancelled booking, past check-out, not a direct booking) gets the same neutral
// 404 as guest-access. The token is never logged. ID photos go to the private guest-id-photos bucket with the service key
// (SPEC-40 / D-292: bucket and policies untouched), at <companion id>/<uuid>.<ext>, after a magic-byte check.
//   POST application/json      {token, action:'context'}                 -> {ok, intake:{ref, dates, pax, guest_name, people[], uploads_today, ...}}
//   POST multipart/form-data   token, people (JSON), photo_<i>            -> {ok, results:[{name, ok, photo, reason?}]}
// One OPS line per submission that saved anything ("<name> sent 2 IDs before arrival. No action needed."). It never carries a phone,
// money, ID detail or link, because cleaners read OPS.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { hashGuestAccessToken } from '../_shared/guest-access-token.ts';
import { withObservability } from '../_shared/observability.ts';
import { opsCard, savePeople, type Context } from './intake.ts';
import { MAX_BODY_BYTES, parseSubmission, TOKEN_RE } from './validate.ts';

const BUCKET = 'guest-id-photos';
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type', 'Content-Type': 'application/json' };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });
const invalid = () => json({ error: 'invalid_guest_access' }, 404);

async function tgOps(text: string): Promise<void> {
  const bot = Deno.env.get('TELEGRAM_BOT_TOKEN'), chat = Deno.env.get('TELEGRAM_CHAT_ID');
  if (!bot || !chat) return;
  await fetch(`https://api.telegram.org/bot${bot}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }), signal: AbortSignal.timeout(10_000),
  }).catch(() => null); // a missed OPS line never undoes a saved ID
}

Deno.serve(withObservability({ functionName: 'guest-intake', route: 'guest' }, async (request: Request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const url = Deno.env.get('SUPABASE_URL'), key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'guest_intake_unavailable' }, 503);
  const db = createClient(url, key, { auth: { persistSession: false } });
  const type = request.headers.get('content-type') ?? '';

  let token = '';
  let form: FormData | null = null;
  if (type.startsWith('multipart/form-data')) {
    const declared = Number(request.headers.get('content-length') ?? 0);
    if (!Number.isFinite(declared) || declared < 1 || declared > MAX_BODY_BYTES) return json({ error: 'file_too_large' }, 413);
    try { form = await request.formData(); } catch { return json({ error: 'bad_request' }, 400); }
    const parsed = form.get('token');
    token = typeof parsed === 'string' ? parsed : '';
  } else if (type.startsWith('application/json')) {
    try { const body = await request.json(); token = typeof body?.token === 'string' && body?.action === 'context' ? body.token : ''; } catch { return invalid(); }
  } else return json({ error: 'unsupported_media_type' }, 415);
  if (!TOKEN_RE.test(token)) return invalid();

  const tokenHash = await hashGuestAccessToken(token);
  const { data: ctx, error } = await db.rpc('intake_guest_context_v1', { p_token_hash: tokenHash });
  if (error) return json({ error: 'guest_intake_unavailable' }, 503);
  if (!ctx) return invalid();
  if (!form) return json({ ok: true, intake: ctx });

  if (!ctx.can_save) return json({ error: 'cannot_save' }, 409);
  const parsed = await parseSubmission(form);
  if (!parsed.ok) return json({ error: parsed.error }, parsed.error === 'photo_too_large' ? 413 : 400);
  const results = await savePeople({
    rpc: (fn, args) => db.rpc(fn, args),
    upload: async (path, bytes, mime) => (await db.storage.from(BUCKET).upload(path, bytes, { contentType: mime, upsert: false })).error?.message ?? null,
    remove: async (path) => { await db.storage.from(BUCKET).remove([path]); },
    uuid: () => crypto.randomUUID(),
  }, tokenHash, ctx as Context, parsed.people);
  const card = opsCard(ctx as Context, results);
  if (card) await tgOps(card);
  return json({ ok: true, results });
}));
