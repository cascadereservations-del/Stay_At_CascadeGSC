// rate-card v1 (session 55, SPEC-34, D-262): the booking site's one price source. Public GET, verify_jwt false.
//   GET /rate-card                              -> { card }            (get_rate_card_v1: prices only)
//   GET /rate-card?checkin=YYYY-MM-DD&checkout=  -> { card, quote }    (the same quote() submit-booking stores)
// The site never computes a price itself, so there is no third copy of the math.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { loadCard, quote } from '../_shared/cascade-core/pricing.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'apikey, authorization, content-type',
  'Content-Type': 'application/json',
};
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const json = (data: unknown, status = 200, cache = 'public, max-age=60') =>
  new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Cache-Control': cache } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'GET') return json({ error: 'method_not_allowed' }, 405, 'no-store');

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const card = await loadCard(db);
  const u = new URL(req.url);
  const checkin = u.searchParams.get('checkin'), checkout = u.searchParams.get('checkout');
  if (!checkin && !checkout) return json({ card });

  if (!checkin || !checkout || !DATE.test(checkin) || !DATE.test(checkout) || isNaN(Date.parse(checkin)) || isNaN(Date.parse(checkout)))
    return json({ error: 'invalid_dates' }, 400, 'no-store');
  const n = Math.round((Date.parse(checkout) - Date.parse(checkin)) / 86_400_000);
  if (n < 1 || n > 60) return json({ error: 'invalid_stay_length' }, 400, 'no-store');
  return json({ card, quote: quote(card, checkin, checkout) });
});
