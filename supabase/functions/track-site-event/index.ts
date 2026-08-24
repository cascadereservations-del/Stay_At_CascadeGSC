import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { validateSiteEvent } from '../_shared/site-event.ts';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type', 'Content-Type': 'application/json' };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const contentLength = Number(request.headers.get('content-length') ?? 0);
  if (Number.isFinite(contentLength) && contentLength > 4096) return json({ error: 'payload_too_large' }, 413);
  let payload: unknown;
  try { payload = await request.json(); } catch { return json({ error: 'invalid_payload' }, 400); }
  const validated = validateSiteEvent(payload);
  if (!validated.ok) return json({ error: validated.error }, validated.error === 'payload_too_large' ? 413 : 400);
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'analytics_unavailable' }, 503);
  const db = createClient(url, key);
  const windowStart = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count, error: countError } = await db.from('site_funnel_events').select('id', { count: 'exact', head: true }).eq('session_id', validated.value.session_id).gte('created_at', windowStart);
  if (countError) return json({ error: 'analytics_unavailable' }, 503);
  if ((count ?? 0) >= 60) return json({ error: 'rate_limited' }, 429);
  const { error } = await db.from('site_funnel_events').insert(validated.value);
  if (error) return json({ error: 'analytics_unavailable' }, 503);
  return json({ ok: true }, 202);
});
