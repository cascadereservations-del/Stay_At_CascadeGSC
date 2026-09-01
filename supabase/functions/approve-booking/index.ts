// approve-booking v6 (local Module B release candidate)
//
// This function authenticates a Finance decision and renders its result. It
// never writes booking state directly: decide_direct_booking owns the complete
// database transaction and the automation outbox owns later provider delivery.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SIG_PREFIX = 'approve-booking:v1:';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

function esc(value: unknown): string {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

function page(inner: string, status = 200): Response {
  const document = '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>Cascade Hideaway</title></head>' +
    '<body style="margin:0;background:#F7F2E8;font-family:Arial,Helvetica,sans-serif;color:#1C1006;">' +
    '<div style="max-width:520px;margin:0 auto;padding:44px 20px;text-align:center;">' +
    '<div style="font-family:Georgia,serif;font-size:26px;">Cascade Hideaway</div>' +
    '<div style="font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#C9963A;margin:4px 0 24px;">Hotel Comfort. Home Warmth.</div>' +
    '<div style="background:#FBF7EE;border:1px solid #ecdcc0;border-radius:14px;padding:30px 24px;">' + inner + '</div>' +
    '</div></body></html>';
  return new Response(document, { status, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}

async function hmacHex(key: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey('raw', encoder.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(message));
  return Array.from(new Uint8Array(signature)).map(byte => byte.toString(16).padStart(2, '0')).join('');
}

function timingSafeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let result = 0;
  for (let index = 0; index < left.length; index += 1) result |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return result === 0;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const url = new URL(req.url);
  const isPost = req.method === 'POST';
  let id = '';
  let action = '';
  let sig = '';
  if (isPost) {
    try {
      const body = await req.json();
      id = String(body.id ?? '');
      action = String(body.action ?? '');
    } catch { /* handled below */ }
  } else {
    id = url.searchParams.get('id') ?? '';
    action = url.searchParams.get('action') ?? '';
    sig = url.searchParams.get('sig') ?? '';
  }

  const fail = (message: string, status: number) => isPost
    ? json({ ok: false, error: message }, status)
    : page('<p style="font-size:16px;">' + message + '</p>', status);
  if (!id || (action !== 'confirm' && action !== 'decline')) return fail('Invalid request.', 400);

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  let authorized = false;
  if (sig) {
    const expected = await hmacHex(serviceKey, SIG_PREFIX + id + ':' + action);
    authorized = timingSafeEqual(sig.toLowerCase(), expected);
  } else {
    const authHeader = req.headers.get('Authorization') ?? '';
    if (authHeader.startsWith('Bearer ')) {
      try {
        const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
          global: { headers: { Authorization: authHeader } },
        });
        const { data } = await client.auth.getUser();
        authorized = Boolean(data.user);
      } catch { authorized = false; }
    }
  }
  if (!authorized) return fail('This link is invalid or has expired.', 403);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);
  const { data: booking } = await db.from('booking_inquiries')
    .select('id, guest_name, checkin_date, checkout_date, status')
    .eq('id', id).maybeSingle();
  if (!booking) return fail('Booking not found.', 404);

  const who = esc(booking.guest_name) + '<br>' + esc(booking.checkin_date) + ' &rarr; ' + esc(booking.checkout_date);
  if (action === 'confirm' && booking.status === 'confirmed') {
    return isPost
      ? json({ ok: true, status: 'confirmed', already: true, checkin: booking.checkin_date, checkout: booking.checkout_date })
      : page('<p style="font-size:19px;color:#C9963A;">Already confirmed</p><p style="font-size:15px;">' + who + '</p>');
  }
  if (action === 'decline' && booking.status === 'cancelled') {
    return isPost
      ? json({ ok: true, status: 'cancelled', already: true })
      : page('<p style="font-size:19px;">Already declined</p><p style="font-size:15px;">' + who + '</p>');
  }

  const { data: decision, error } = await db.rpc('decide_direct_booking', {
    p_booking_id: id,
    p_action: action,
    p_idempotency_key: 'approve-booking:' + id + ':' + action,
  });
  if (error || !decision) return fail('Unable to process this booking at the moment.', 500);
  if (decision.outcome === 'conflict') return fail('These dates are no longer available. The booking was not confirmed.', 409);
  if (!decision.ok) return fail('This booking cannot be changed from its current state.', 409);

  if (decision.outcome === 'confirmed') {
    return isPost
      ? json({ ok: true, status: 'confirmed', already: decision.already_processed === true, checkin: booking.checkin_date, checkout: booking.checkout_date })
      : page(
        '<p style="font-size:21px;color:#C9963A;">&#10003; Booking confirmed</p>' +
        '<p style="font-size:15px;"><strong>' + who + '</strong></p>' +
        '<p style="color:#7d6f5c;font-size:13px;margin-top:14px;">The booking, calendar and ledger were confirmed together. Guest and staff delivery are queued through the approved automation path.</p>' +
        '<div style="margin-top:16px;padding:12px 14px;background:#FBEEDB;border:1px solid #C9963A;border-radius:10px;text-align:left;">' +
        '<div style="font-weight:700;color:#1C1006;font-size:13px;">&#9888; Keep Airbnb unavailable until projection is verified</div>' +
        '<div style="color:#5c5140;font-size:12px;margin-top:4px;">Direct booking calendar projection must be checked before relying on Airbnb availability.</div>' +
        '</div>'
      );
  }

  return isPost
    ? json({ ok: true, status: 'cancelled', already: decision.already_processed === true })
    : page(
      '<p style="font-size:21px;">Booking declined</p>' +
      '<p style="font-size:15px;"><strong>' + who + '</strong></p>' +
      '<p style="color:#7d6f5c;font-size:13px;margin-top:14px;">The booking hold was released and delivery was left to the approved automation path.</p>'
    );
});
