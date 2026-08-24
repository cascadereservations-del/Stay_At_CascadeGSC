import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { hashGuestAccessToken } from '../_shared/guest-access-token.ts';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type', 'Content-Type': 'application/json' };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });
const invalid = () => json({ error: 'invalid_guest_access' }, 404);

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  let token = '';
  try { const body = await request.json(); token = typeof body?.token === 'string' ? body.token : ''; } catch { return invalid(); }
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) return invalid();
  const url = Deno.env.get('SUPABASE_URL'); const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'guest_access_unavailable' }, 503);
  const db = createClient(url, key);
  const tokenHash = await hashGuestAccessToken(token);
  const { data: access } = await db.from('guest_access_tokens').select('id,booking_type,booking_id,expires_at,revoked_at').eq('token_hash', tokenHash).maybeSingle();
  if (!access || access.revoked_at || new Date(access.expires_at).getTime() <= Date.now() || access.booking_type !== 'direct') return invalid();
  const { data: booking } = await db.from('booking_inquiries').select('id,status,checkin_date,checkout_date,pax,guest_id').eq('id', access.booking_id).maybeSingle();
  if (!booking || booking.status === 'cancelled') return invalid();
  await db.from('guest_access_tokens').update({ last_used_at: new Date().toISOString() }).eq('id', access.id);
  const { count } = booking.guest_id ? await db.from('booking_inquiries').select('id', { count: 'exact', head: true }).eq('guest_id', booking.guest_id).eq('status', 'confirmed').lt('checkout_date', booking.checkin_date) : { count: 0 };
  return json({ ok: true, guide: { booking_ref: booking.id.slice(0, 8).toUpperCase(), checkin_date: booking.checkin_date, checkout_date: booking.checkout_date, pax: booking.pax, is_returning: (count ?? 0) > 0, visit_ordinal: (count ?? 0) + 1 } });
});
