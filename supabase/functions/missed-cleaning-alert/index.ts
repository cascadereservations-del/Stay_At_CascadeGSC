// missed-cleaning-alert v1
// Triggered daily by pg_cron at 00:00 UTC (= 08:00 Manila time).
// Finds checkouts in the last fortnight with no cleaning report recorded.
// Sends alert to OPS Telegram group only — guest name and dates only, zero financial data.
//
// DB dependency: public.get_missed_cleanings(p_property_id uuid, p_lookback int).
// v2 (2026-09-12) reads calendar_events rather than airbnb_reservations, so a
// DIRECT booking's checkout finally raises an alert, and it looks back a window
// instead of only at yesterday -- a gap is chased until a report arrives.
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

    // Call DB function — checkouts in the lookback window with no report filed
    const { data: missed, error } = await supabase
      .rpc('get_missed_cleanings', { p_property_id: propertyId });

    if (error) {
      console.error('[missed-cleaning] RPC error:', error);
      return json({ ok: false, error: error.message }, 500);
    }

    const rows = (missed ?? []) as Array<{
      guest_name:    string | null;
      checkin_date:  string;
      checkout_date: string;
      source:        string | null;
      days_overdue:  number;
    }>;

    console.log(`[missed-cleaning] ${rows.length} checkout(s) still without a report`);


    // One Telegram message per missing report (OPS group, no financial data)
    for (const r of rows) {
      const guest    = r.guest_name || 'Guest name not on the calendar';
      const checkin  = fmtDate(r.checkin_date);
      const checkout = fmtDate(r.checkout_date);
      const days     = Number(r.days_overdue ?? 0);

      // The same gap is reported every morning until it is filled, so the
      // wording has to move -- an unchanging line stops being read.
      const urgency = days <= 1
        ? '\u26A0\uFE0F *Missed Cleaning Alert*'
        : days <= 3
          ? `\u26A0\uFE0F *Cleaning report still missing \u2014 ${days} days*`
          : `\uD83D\uDD34 *Cleaning report ${days} days overdue*`;

      const text = [
        urgency,
        `\uD83C\uDFE0 Cascade Hideaway`,
        ``,
        days <= 1
          ? `No cleaning report has been filed for this checkout.`
          : `No cleaning report has been filed for this checkout, ${days} days on.`,
        ``,
        `\uD83D\uDC64 Guest: ${guest}`,
        `\uD83D\uDCE5 Check-in:  ${checkin}`,
        `\uD83D\uDCE4 Check-out: ${checkout}`,
        ``,
        `_Please confirm the cleaning was done or log the session in the checklist app._`,
      ].join('\n');

      await tgSend(TG_TOKEN, TG_CHAT_ID, text);
    }

    // ── Meter photos needing a look (2026-09-13) ────────────────────────
    // Same morning message, same OPS group. A report that arrived but whose
    // meter photo was skipped, or which the vision check disagreed with, is
    // an unverifiable turnover exactly like a missing report — so it is
    // chased here rather than in a second alert nobody would subscribe to.
    //
    // Deliberately quiet about blame: 'unreadable' is usually a dark photo or
    // a dial caught mid-roll, not a dishonest one.
    const { data: followups, error: fErr } = await supabase
      .rpc('get_meter_photo_followups', { p_property_id: propertyId, p_lookback: 14 });

    if (fErr) {
      // A missing function means the 2026-09-13 migration is not applied.
      // Whatever went out above still went out; note it and carry on.
      console.warn('[missed-cleaning] meter follow-up RPC unavailable:', fErr.message);
    } else if ((followups ?? []).length > 0) {
      const lines = (followups as Array<Record<string, unknown>>).slice(0, 5).map((f) => {
        const when = fmtDate(String(f.cleaned_at ?? '').slice(0, 10));
        const who  = (f.cleaner_name as string) || 'unknown cleaner';
        const why  = (f.reason as string) || 'needs another look';
        const seen = f.vision_verdict === 'mismatch' && f.vision_electric != null
          ? ` \u2014 photo reads ${f.vision_electric}, report says ${f.typed_electric ?? '\u2014'}`
          : '';
        return `\u2022 ${when} \u00B7 ${who}: ${why}${seen}`;
      });

      await tgSend(TG_TOKEN, TG_CHAT_ID, [
        `\uD83D\uDC40 *Meter photos needing a look*`,
        `\uD83C\uDFE0 Cascade Hideaway`,
        ``,
        ...lines,
        ``,
        `_The cleaner is asked to re-upload at her next sign-in. Worth checking before the cleaning fee is paid._`,
      ].join('\n'));
    }

    return json({
      ok: true,
      missed: rows.length,
      meter_followups: (followups ?? []).length,
    });

  } catch (err) {
    console.error('[missed-cleaning] fatal:', err);
    return json({ ok: false, error: String(err) }, 500);
  }
}));
