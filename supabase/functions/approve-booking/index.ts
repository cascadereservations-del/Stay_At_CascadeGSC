// approve-booking v7 (local Module C release candidate)
//
// This function requires a named AAL2 Finance/Admin user, creates an immutable
// Finance review, and delegates to the reviewed booking transaction. It never
// writes booking state directly; the outbox owns later provider delivery.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'Method not allowed.' }, 405);

  let id = '';
  let action = '';
  let comparisonId = '';
  let reason = '';
  try {
    const body = await req.json();
    id = String(body.id ?? '');
    action = String(body.action ?? '');
    comparisonId = String(body.comparison_id ?? '');
    reason = String(body.reason ?? '').trim();
  } catch { /* handled below */ }
  const fail = (message: string, status: number) => json({ ok: false, error: message }, status);
  if (!id || !comparisonId || reason.length < 3 || (action !== 'confirm' && action !== 'decline')) {
    return fail('Booking, comparison, action and review reason are required.', 400);
  }

  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return fail('Named Finance sign-in is required.', 403);
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return fail('Named Finance sign-in is required.', 403);
  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey);
  const { data: booking } = await db.from('booking_inquiries')
    .select('id, property_id, guest_name, checkin_date, checkout_date, status')
    .eq('id', id).maybeSingle();
  if (!booking) return fail('Booking not found.', 404);

  const { data: authorized } = await userClient.rpc('current_staff_authorized', {
    p_action: 'approve_payment',
    p_property_id: booking.property_id,
  });
  if (authorized !== true) return fail('A current AAL2 Finance/Admin session is required.', 403);

  if (action === 'confirm' && booking.status === 'confirmed') {
    return json({ ok: true, status: 'confirmed', already: true, checkin: booking.checkin_date, checkout: booking.checkout_date });
  }
  if (action === 'decline' && booking.status === 'cancelled') {
    return json({ ok: true, status: 'cancelled', already: true });
  }

  const { data: financeReviewId, error: reviewError } = await userClient.rpc('record_payment_finance_review', {
    p_comparison_id: comparisonId,
    p_outcome: action === 'confirm' ? 'approved' : 'rejected',
    p_reason: reason,
  });
  if (reviewError || !financeReviewId) return fail('Unable to record the Finance review.', 409);

  const { data: decision, error } = await db.rpc('decide_direct_booking', {
    p_booking_id: id,
    p_action: action,
    p_idempotency_key: 'approve-booking:' + id + ':' + action + ':' + financeReviewId,
    p_finance_review_id: financeReviewId,
  });
  if (error || !decision) return fail('Unable to process this booking at the moment.', 500);
  if (decision.outcome === 'conflict') return fail('These dates are no longer available. The booking was not confirmed.', 409);
  if (!decision.ok) return fail('This booking cannot be changed from its current state.', 409);

  if (decision.outcome === 'confirmed') {
    return json({ ok: true, status: 'confirmed', already: decision.already_processed === true, checkin: booking.checkin_date, checkout: booking.checkout_date });
  }

  return json({ ok: true, status: 'cancelled', already: decision.already_processed === true });
});
