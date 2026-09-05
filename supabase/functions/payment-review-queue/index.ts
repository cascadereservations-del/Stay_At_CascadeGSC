import { createClient } from 'jsr:@supabase/supabase-js@2';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { parseQueueRequest, queueErrorStatus } from './logic.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...CORS, 'Content-Type': 'application/json' },
});

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'GET') return json({ ok: false, error: 'method_not_allowed' }, 405);
  const parsed = parseQueueRequest(new URL(request.url));
  if (!parsed) return json({ ok: false, error: 'invalid_request' }, 400);

  try {
    const identity = await requireStaffAccess(request, 'read_finance', parsed.propertyId);
    const url = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    if (!url || !anonKey) return json({ ok: false, error: 'queue_unavailable' }, 503);
    const db = createClient(url, anonKey, {
      global: { headers: { Authorization: `Bearer ${identity.accessToken}` } },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const { data, error } = await db.rpc('get_payment_review_queue', {
      p_property_id: parsed.propertyId,
      p_limit: parsed.limit,
    });
    if (error) return json({ ok: false, error: 'queue_unavailable' }, queueErrorStatus(error.code));
    return json({ ok: true, queue: data });
  } catch (error) {
    return staffAuthResponse(error, CORS) ?? json({ ok: false, error: 'queue_unavailable' }, 503);
  }
});
