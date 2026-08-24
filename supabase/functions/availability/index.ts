// availability v20 (2026-08-24)
// Rewritten to read the canonical `calendar_events` table (source of truth for
// occupancy, populated by calendar-sync + submit-booking + approve-booking)
// instead of independently re-parsing the raw Airbnb iCal feed. The old
// iCal-parsing version never saw direct-booking holds at all (they only ever
// existed in calendar_events), so it was not safe to point the public site at
// it as-is. This version is deployed specifically so the frontend can stop
// reading calendar_events directly with the anon key (that table is being
// locked down to owner/admin + service_role only) while the booking
// calendar keeps working unchanged for guests.
//
// Response allowlist: ONLY { checkin_date, checkout_date } pairs for
// non-cancelled rows. No guest_name, guest_phone, uid, source, or any other
// column is ever selected or returned here.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'apikey, authorization, content-type',
  'Content-Type': 'application/json',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const { data, error } = await db
    .from('calendar_events')
    .select('checkin_date, checkout_date')
    .neq('status', 'cancelled')
    .order('checkin_date');

  if (error) {
    return new Response(JSON.stringify({ error: 'availability_lookup_failed' }), {
      status: 500,
      headers: { ...CORS, 'Cache-Control': 'no-store' },
    });
  }

  // Explicit allowlist projection — never forward extra columns even if a
  // future schema change adds one to the select above by accident.
  const safe = (data ?? []).map((row: { checkin_date: string; checkout_date: string }) => ({
    checkin_date: row.checkin_date,
    checkout_date: row.checkout_date,
  }));

  return new Response(JSON.stringify(safe), {
    status: 200,
    headers: { ...CORS, 'Cache-Control': 'no-store' },
  });
});

