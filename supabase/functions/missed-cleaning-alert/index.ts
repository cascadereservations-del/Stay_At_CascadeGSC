// missed-cleaning-alert v1
// Triggered daily by pg_cron at 00:00 UTC (= 08:00 Manila time).
// Finds reservations that checked out yesterday with no cleaning session recorded.
// Sends alert to OPS Telegram group only — guest name and dates only, zero financial data.
//
// DB dependency: public.get_missed_cleanings(p_property_id uuid) must exist.
// verify_jwt: false — internal cron-triggered function, no user auth needed.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

async function tgSend(token: string, chatId: string, text: string): Promise<void> {
  const resp = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ chat_id: chatId, text, parse_mode: 'Markdown' }),
    signal:  AbortSignal.timeout(15_000),
  });
  if (!resp.ok) {
    const t = await resp.text().catch(() => '');
    console.warn(`tgSend failed ${resp.status}:`, t);
  }
}

function fmtDate(dateStr: string): string {
  if (!dateStr) return '\u2014';
  const d = new Date(dateStr + 'T00:00:00');
  return d.toLocaleDateString('en-PH', { month: 'short', day: 'numeric', year: 'numeric' });
}

Deno.serve(withObservability({ functionName: 'missed-cleaning-alert', route: 'ops' }, async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } }
    );

    const TG_TOKEN   = Deno.env.get('TELEGRAM_BOT_TOKEN');
    const TG_CHAT_ID = Deno.env.get('TELEGRAM_CHAT_ID'); // OPS group ONLY

    if (!TG_TOKEN || !TG_CHAT_ID) {
      console.error('[missed-cleaning] Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID');
      return json({ ok: false, error: 'Missing env vars' }, 500);
    }

    // Fetch property ID
    const { data: prop } = await supabase
      .from('properties')
      .select('id')
      .limit(1)
      .maybeSingle();
    const propertyId: string | null = prop?.id ?? null;

    if (!propertyId) {
      console.error('[missed-cleaning] No property found');
      return json({ ok: false, error: 'No property' }, 500);
    }

    // Call DB function — returns reservations that checked out yesterday with no cleaning
    const { data: missed, error } = await supabase
      .rpc('get_missed_cleanings', { p_property_id: propertyId });

    if (error) {
      console.error('[missed-cleaning] RPC error:', error);
      return json({ ok: false, error: error.message }, 500);
    }

    const rows = (missed ?? []) as Array<{
      confirmation_code:  string;
      guest_name:         string;
      checkin_date:       string;
      checkout_date:      string;
      reservation_status: string;
    }>;

    console.log(`[missed-cleaning] ${rows.length} missed cleaning(s) for yesterday`);

    if (rows.length === 0) {
      return json({ ok: true, missed: 0 });
    }

    // One Telegram message per missed reservation (OPS group, no financial data)
    for (const r of rows) {
      const guest    = r.guest_name || r.confirmation_code || 'Unknown Guest';
      const checkin  = fmtDate(r.checkin_date);
      const checkout = fmtDate(r.checkout_date);

      const text = [
        `\u26A0\uFE0F *Missed Cleaning Alert*`,
        `\uD83C\uDFE0 Cascade Hideaway`,
        ``,
        `No cleaning session was recorded for yesterday\u2019s checkout.`,
        ``,
        `\uD83D\uDC64 Guest: ${guest}`,
        `\uD83D\uDCE5 Check-in:  ${checkin}`,
        `\uD83D\uDCE4 Check-out: ${checkout}`,
        ``,
        `_Please confirm the cleaning was done or log the session in the checklist app._`,
      ].join('\n');

      await tgSend(TG_TOKEN, TG_CHAT_ID, text);
    }

    return json({ ok: true, missed: rows.length });

  } catch (err) {
    console.error('[missed-cleaning] fatal:', err);
    return json({ ok: false, error: String(err) }, 500);
  }
}));
