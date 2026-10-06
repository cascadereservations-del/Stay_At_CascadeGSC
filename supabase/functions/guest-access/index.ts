import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { hashGuestAccessToken } from '../_shared/guest-access-token.ts';
import { issueReceiptUploadToken } from '../_shared/receipt-security.ts';
import { statusView, type StatusFacts } from './status.ts';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type', 'Content-Type': 'application/json' };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });
const invalid = () => json({ error: 'invalid_guest_access' }, 404);

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  let token = ''; let view = '';
  try { const body = await request.json(); token = typeof body?.token === 'string' ? body.token : ''; view = typeof body?.view === 'string' ? body.view : ''; } catch { return invalid(); }
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) return invalid();
  const url = Deno.env.get('SUPABASE_URL'); const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'guest_access_unavailable' }, 503);
  const db = createClient(url, key);
  const tokenHash = await hashGuestAccessToken(token);
  // SPEC-42 s6: the booking status page. One definer RPC does the token check and the read (service_role cannot read booking_holds),
  // and every invalid, expired, revoked or unknown token gets the same neutral 404 as the guide. The token is never logged.
  if (view === 'status') {
    const { data: facts, error } = await db.rpc('guest_booking_status_v1', { p_token_hash: tokenHash });
    if (error) return json({ error: 'guest_access_unavailable' }, 503);
    if (!facts) return invalid();
    const now = Date.now();
    const status = statusView(facts as StatusFacts, now);
    if (!status) return invalid();
    // A guest who still owes the reservation payment gets a short-lived receipt-upload token for the existing receipt route.
    const secret = Deno.env.get('BOOKING_RECEIPT_UPLOAD_SECRET');
    const receiptExpires = now + 30 * 60_000;
    const receiptToken = status.can_upload_receipt && secret
      ? await issueReceiptUploadToken({ bookingId: String((facts as { booking_id: string }).booking_id), nonce: crypto.randomUUID(), expiresAt: receiptExpires }, secret)
      : null;
    return json({ ok: true, status: { ...status, receipt_upload_token: receiptToken, receipt_upload_expires_at: receiptToken ? new Date(receiptExpires).toISOString() : null, server_now: new Date(now).toISOString() } });
  }
  const { data: access } = await db.from('guest_access_tokens').select('id,booking_type,booking_id,expires_at,revoked_at').eq('token_hash', tokenHash).maybeSingle();
  if (!access || access.revoked_at || new Date(access.expires_at).getTime() <= Date.now() || access.booking_type !== 'direct') return invalid();
  const { data: booking } = await db.from('booking_inquiries').select('id,status,checkin_date,checkout_date,pax,guest_id').eq('id', access.booking_id).maybeSingle();
  if (!booking || booking.status === 'cancelled') return invalid();
  await db.from('guest_access_tokens').update({ last_used_at: new Date().toISOString() }).eq('id', access.id);
  const { count } = booking.guest_id ? await db.from('booking_inquiries').select('id', { count: 'exact', head: true }).eq('guest_id', booking.guest_id).eq('status', 'confirmed').lt('checkout_date', booking.checkin_date) : { count: 0 };
  return json({ ok: true, guide: { booking_ref: booking.id.slice(0, 8).toUpperCase(), checkin_date: booking.checkin_date, checkout_date: booking.checkout_date, pax: booking.pax, is_returning: (count ?? 0) > 0, visit_ordinal: (count ?? 0) + 1 } });
});
