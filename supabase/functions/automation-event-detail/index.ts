import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type', 'Content-Type': 'application/json' };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
// A workflow can only read an event type it is designed to process. Keep this
// allow-list here (rather than trusting a caller-supplied workflow ID) because
// this endpoint may return booking data to n8n.
const ALLOWED: Record<string, string[]> = {
  'booking.requested': ['CH-W01'],
  'booking.receipt_uploaded': ['CH-W02'],
  'booking.confirmed': ['CH-W03'],
  'booking.cancelled': ['CH-W03'],
  'calendar.projection_requested': ['CH-W09'],
  'guest.returning_detected': ['CH-W10'],
  'guest.identity_conflict': ['CH-W11'],
};
const BOOKING_EVENTS = new Set(['booking.requested', 'booking.receipt_uploaded', 'booking.confirmed', 'booking.cancelled']);
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });
async function hash(value: string): Promise<string> { return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))), (b) => b.toString(16).padStart(2, '0')).join(''); }
function fixedLengthEqual(left: string, right: string): boolean { if (left.length !== right.length) return false; let difference = 0; for (let i = 0; i < left.length; i += 1) difference |= left.charCodeAt(i) ^ right.charCodeAt(i); return difference === 0; }

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const secret = Deno.env.get('N8N_EVENT_DETAIL_SECRET');
  const token = (request.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!secret || !fixedLengthEqual(token, secret)) return json({ error: 'unauthorized' }, 401);
  let body: { event_id?: string; workflow_id?: string };
  try { body = await request.json(); } catch { return json({ error: 'invalid_payload' }, 400); }
  if (!body || Object.keys(body).some((key) => key !== 'event_id' && key !== 'workflow_id') || !body.event_id || !UUID.test(body.event_id) || !body.workflow_id) return json({ error: 'invalid_payload' }, 400);
  const url = Deno.env.get('SUPABASE_URL'); const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'detail_unavailable' }, 503);
  const db = createClient(url, key);
  const { data: event } = await db.from('automation_outbox').select('id,event_type,aggregate_id,status,payload').eq('id', body.event_id).maybeSingle();
  if (!event || !ALLOWED[event.event_type]?.includes(body.workflow_id)) return json({ error: 'not_found' }, 404);
  const payload = (event.payload && typeof event.payload === 'object' ? event.payload : {}) as Record<string, unknown>;
  const bookingId = BOOKING_EVENTS.has(event.event_type)
    ? event.aggregate_id
    : typeof payload.booking_id === 'string' && UUID.test(payload.booking_id)
      ? payload.booking_id
      : null;
  const { data: booking } = bookingId
    ? await db.from('booking_inquiries').select('id,status,checkin_date,checkout_date,pax,total_amount,deposit_amount,guest_name,guest_email,guest_phone').eq('id', bookingId).maybeSingle()
    : { data: null };
  if (!booking) return json({ error: 'not_found' }, 404);
  const credentialHash = await hash(token);
  const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();
  await db.from('automation_event_access_log').upsert({ outbox_id: event.id, workflow_id: body.workflow_id, credential_hash: credentialHash, expires_at: expiresAt }, { onConflict: 'outbox_id,workflow_id,credential_hash' });
  const detail: Record<string, unknown> = { event_id: event.id, event_type: event.event_type, booking_ref: booking.id.slice(0, 8).toUpperCase(), status: booking.status, checkin_date: booking.checkin_date, checkout_date: booking.checkout_date, pax: booking.pax, total_amount: booking.total_amount, deposit_amount: booking.deposit_amount, expires_at: expiresAt };
  if (event.event_type === 'calendar.projection_requested') {
    detail.calendar_event_id = event.aggregate_id;
    detail.operation = payload.operation;
    detail.sync_hash = payload.sync_hash;
  }
  if (event.event_type === 'guest.returning_detected') {
    detail.guest_id = payload.guest_id;
    detail.previous_completed_stays = payload.previous_completed_stays;
    detail.total_completed_nights = payload.total_completed_nights;
  }
  if (body.workflow_id === 'CH-W01') { detail.guest_name = booking.guest_name; detail.guest_email = booking.guest_email; detail.guest_phone = booking.guest_phone; }
  return json({ ok: true, detail });
});
