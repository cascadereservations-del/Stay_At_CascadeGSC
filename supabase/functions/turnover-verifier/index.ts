// turnover-verifier v2
// Runs daily via pg_cron at 00:00 UTC (08:00 Manila).
// Pass 1 — yesterday's checkout: calls verify_turnover, creates/updates
//   turnover_verification row, fires Finance alert if issues found.
// Pass 2 — every still-open row from two-or-more days ago: fires OPS
//   escalation on first miss (T+48h), then re-fires once per day (this
//   function's own daily cadence rate-limits it) for as long as it stays
//   unresolved AND a confirmed guest is arriving today or tomorrow. A repeat
//   is stamped by reusing alert_36h_sent_at as "last escalation sent at".
// No notification fired when all checks pass.
// Routing: Finance = new issues (T+24h). OPS = unresolved escalation (T+48h,
//   repeating while unresolved and an arrival is imminent).
//
// v2 (2026-09-16): two fixes from Lloyd.
//   (a) Repeat escalation: previously a one-shot alert_36h_sent_at gate meant
//   OPS heard about an unresolved turnover exactly once, even if it stayed
//   unresolved for days with a new guest about to arrive into an unconfirmed
//   unit. Pass 2 now scans all open rows, not just exactly two-days-ago, and
//   re-escalates when an arrival is imminent.
//   (b) Readable issue codes: raw codes like `no_session_found` were sent
//   through Telegram legacy Markdown (parse_mode: 'Markdown'), which reads a
//   matched underscore pair as an italics delimiter — the underscores are
//   consumed and "no_session_found" renders as the single unbroken word
//   "nosessionfound". issueLabel() below maps known codes to plain, safe
//   text; the fallback still replaces underscores with spaces so no future
//   code can hit the same bug.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { turnoverWindow, addDays, manilaDate } from './manila-dates.ts';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { withObservability } from '../_shared/observability.ts';
// v3 (session 26, 2026-09-16, Telegram plan §5): Finance T+24h card is 🟡 ATTENTION, OPS escalation 🔴 ALERT.
import { withHeader } from '../_shared/cascade-core/format.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cascade-cron-secret',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

async function tgPost(token: string, method: string, body: Record<string, unknown>): Promise<void> {
  const resp = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify(body),
    signal:  AbortSignal.timeout(15_000),
  });
  if (!resp.ok) {
    const t = await resp.text().catch(() => '');
    console.warn(`tgPost ${method} ${resp.status}:`, t);
  }
}

const ISSUE_LABELS: Record<string, string> = {
  no_session_found: 'No cleaning session found for this checkout.',
  no_meter_reading: 'No meter reading recorded for this turnover.',
  meter_zero_kwh_per_night: 'Meter reading shows 0 kWh/night \u2014 worth a second look.',
  low_photo_count: 'Fewer than 5 turnover photos uploaded.',
  session_incomplete: 'Cleaning checklist left incomplete.',
};
function issueLabel(code: string): string {
  return ISSUE_LABELS[code] ?? code.replace(/_/g, ' ');
}
function fmtIssues(issues: string[]): string {
  return issues.map(i => `\u2022 ${issueLabel(i)}`).join('\n');
}

Deno.serve(withObservability({ functionName: 'turnover-verifier', route: 'ops' }, async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);
  // pg_cron job 8 posts without a secret header today, and
  // CASCADE_CRON_SHARED_SECRET is not configured on this project yet. Enforcing
  // the header unconditionally would 401 every real run — which is why this
  // hardened build could never be deployed. Enforce it only once the secret
  // exists, so configuring the secret is itself the switch that turns the check
  // on. Until then the posture is exactly what it is today: an open POST
  // endpoint that only reads and alerts, and never accepts caller data.
  const cronSecret = Deno.env.get('CASCADE_CRON_SHARED_SECRET');
  if (cronSecret && !cronSecretMatches(cronSecret, req.headers.get('x-cascade-cron-secret'))) {
    return json({ ok: false, error: 'unauthorized' }, 401);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) {
    console.warn('[turnover-verifier] missing Supabase env vars');
    return json({ ok: false, error: 'configuration_missing' }, 500);
  }
  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });
  const recordHeartbeat = async (phase: 'started' | 'succeeded' | 'failed', errorCode: string | null = null) => {
    const { error } = await supabase.rpc('record_job_heartbeat', {
      p_job_name: 'turnover-verifier-daily',
      p_phase: phase,
      p_error_code: errorCode,
    });
    if (error) console.warn('[turnover-verifier] heartbeat write failed:', error.message);
  };
  await recordHeartbeat('started');

  const TG_TOKEN      = Deno.env.get('TELEGRAM_BOT_TOKEN');
  const TG_FINANCE_ID = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
  const TG_OPS_ID     = Deno.env.get('TELEGRAM_CHAT_ID');

  if (!TG_TOKEN || !TG_FINANCE_ID || !TG_OPS_ID) {
    console.warn('[turnover-verifier] missing Telegram env vars');
    await recordHeartbeat('failed', 'CONFIGURATION_MISSING');
    return json({ ok: false, error: 'configuration_missing' }, 500);
  }

  // Manila calendar dates, computed without round-tripping a locale string
  // through Date — see manila-dates.ts for the v9 bug this replaces.
  const { today, yesterday, twoDaysAgo } = turnoverWindow();

  // ?dry=1 runs the read-only checks and reports what WOULD happen: no
  // Telegram message, no row written, no alert stamp. It exists so this
  // function can be verified by hand without messaging Finance or OPS.
  const dryRun = new URL(req.url).searchParams.get('dry') === '1';

  const results: Record<string, unknown> = { dry_run: dryRun };

  // PASS 1: yesterday -> Finance alert if issues
  try {
    const d1 = yesterday;
    const { data: v1, error: e1 } = await supabase.rpc('verify_turnover', { p_checkout_date: d1 });
    if (e1) throw new Error(`verify_turnover failed: ${e1.message}`);
    if (!v1) throw new Error('verify_turnover returned no result');
    const result1 = v1 as {
      check_passed: boolean;
      session_id: string | null;
      cleaner_name: string | null;
      total_photo_count: number;
      is_complete: boolean | null;
      incomplete_reasons: string[] | null;
      issues: string[];
    };

    results.yesterday = { date: d1, result: result1 };

    // Upsert turnover_verification row
    const { data: prop } = await supabase.from('properties').select('id').limit(1).maybeSingle();
    const propertyId = prop?.id;
    if (!propertyId) throw new Error('no property row found');
    if (propertyId && !dryRun) {
      await supabase
        .from('turnover_verification')
        .upsert({
          property_id:  propertyId,
          checkout_date: d1,
          session_id:   result1.session_id ?? null,
          check_passed: result1.check_passed,
          issues:       result1.issues,
        }, { onConflict: 'property_id,checkout_date', ignoreDuplicates: false });
    }

    // A day with no confirmed guest checkout is not a turnover, so there is
    // nothing to alert about. verify_turnover reports this as check_passed:true
    // with issues:['no_checkout_scheduled'] (migration 20260910070000); without
    // this guard the issues.length test below would still fire, which is how
    // 2026-09-08 and 2026-09-09 produced false alarms. Pass 2 already gates on
    // check_passed, so it needs no equivalent change.
    const noCheckoutScheduled = result1.issues.includes('no_checkout_scheduled');

    // Fire Finance alert only if issues found AND alert not already sent
    if (!noCheckoutScheduled && (!result1.check_passed || result1.issues.length > 0)) {
      const { data: existingRow } = await supabase
        .from('turnover_verification')
        .select('alert_24h_sent_at')
        .eq('property_id', propertyId)
        .eq('checkout_date', d1)
        .maybeSingle();

      if (dryRun) {
        results.yesterday_would_alert = true;
      } else if (!existingRow?.alert_24h_sent_at) {
        // no_session_found is dropped from the bullet list below: the
        // no-session branch of sessionLine already says it, in plain
        // language, so listing it again would just repeat the same fact.
        const displayIssues = result1.issues.filter((i) => i !== 'no_session_found');
        const issueText = fmtIssues(displayIssues);
        const sessionLine = result1.session_id
          ? `\uD83E\uDDF9 Cleaner: ${result1.cleaner_name ?? 'unknown'}  \u00b7  Photos: ${result1.total_photo_count}  \u00b7  Complete: ${result1.is_complete ? '\u2705' : '\u274C'}`
          : '\u274C No cleaning session found \u2014 the cleaner hasn\u2019t submitted a turnover report for this checkout yet.';

        const lines = [
          `\uD83D\uDD0D *Turnover Check \u2014 T+24h*`,
          `\uD83D\uDCCD Cascade Bria  \u00b7  Checkout: ${d1}`,
          ``,
          sessionLine,
        ];
        if (displayIssues.length) {
          lines.push(``, `\u26A0\uFE0F *Issues detected:*`, issueText);
        }
        lines.push(``, `_Resolve before next guest check-in. OPS will be alerted tomorrow if unresolved._`);

        await tgPost(TG_TOKEN, 'sendMessage', {
          chat_id:    TG_FINANCE_ID,
          text:       withHeader('attention', `turnover check ${d1}`, lines.join('\n')),
          parse_mode: 'Markdown',
        });

        // Stamp alert_24h_sent_at
        if (propertyId) {
          await supabase
            .from('turnover_verification')
            .update({ alert_24h_sent_at: new Date().toISOString() })
            .eq('property_id', propertyId)
            .eq('checkout_date', d1);
        }

        results.yesterday_alerted = true;
      } else {
        results.yesterday_already_alerted = true;
      }
    } else {
      results.yesterday_passed = true;
    }
  } catch (e) {
    console.error('[pass1] error:', e);
    results.pass1_error = String(e);
  }

  // PASS 2: every still-open turnover from two-or-more days ago -> OPS escalation,
  // repeating once per day while unresolved and a guest is arriving soon. See v2 note above.
  try {
    const { data: prop } = await supabase.from('properties').select('id').limit(1).maybeSingle();
    const propertyId = prop?.id;

    if (propertyId) {
      const { data: openRows } = await supabase
        .from('turnover_verification')
        .select('*')
        .eq('property_id', propertyId)
        .eq('check_passed', false)
        .not('alert_24h_sent_at', 'is', null)
        .is('resolved_at', null)
        .lte('checkout_date', twoDaysAgo)
        .order('checkout_date', { ascending: true });

      const tomorrow = addDays(today, 1);
      const { data: soonArrival } = await supabase
        .from('calendar_events')
        .select('checkin_date')
        .eq('property_id', propertyId).eq('status', 'confirmed')
        .gte('checkin_date', today).lte('checkin_date', tomorrow)
        .order('checkin_date', { ascending: true }).limit(1).maybeSingle();

      const escalated: string[] = [];
      for (const tvRow of openRows ?? []) {
        const firstEscalation = !tvRow.alert_36h_sent_at;
        const alreadyEscalatedToday = tvRow.alert_36h_sent_at
          ? manilaDate(new Date(tvRow.alert_36h_sent_at)) === today
          : false;
        const repeatDue = !firstEscalation && Boolean(soonArrival) && !alreadyEscalatedToday;
        if (!firstEscalation && !repeatDue) continue;

        if (dryRun) { escalated.push(tvRow.checkout_date); continue; }

        const issueText = fmtIssues(tvRow.issues ?? []);
        const openLine = firstEscalation
          ? `\u26A0\uFE0F Finance was notified 24h ago. Issues still open:`
          : `\u26A0\uFE0F Still open \u2014 a guest arrives ${soonArrival!.checkin_date === today ? 'today' : 'tomorrow'} and the unit isn\u2019t confirmed ready:`;
        const lines = [
          `\uD83D\uDEA8 *Turnover Unresolved \u2014 ESCALATION*`,
          `\uD83D\uDCCD Cascade Bria  \u00b7  Checkout: ${tvRow.checkout_date}`,
          ``,
          openLine,
          issueText,
          ``,
          `_Please verify the unit is ready for the next guest._`,
        ];

        await tgPost(TG_TOKEN, 'sendMessage', {
          chat_id:    TG_OPS_ID,
          text:       withHeader('alert', `turnover unresolved ${tvRow.checkout_date}`, lines.join('\n')),
          parse_mode: 'Markdown',
        });

        await supabase
          .from('turnover_verification')
          .update({ alert_36h_sent_at: new Date().toISOString() })
          .eq('id', tvRow.id);

        escalated.push(tvRow.checkout_date);
      }
      results[dryRun ? 'would_escalate' : 'escalation_sent'] = escalated;
      if (!escalated.length) results.no_escalation_needed = true;
    }
  } catch (e) {
    console.error('[pass2] error:', e);
    results.pass2_error = String(e);
  }

  if (results.pass1_error || results.pass2_error) {
    await recordHeartbeat('failed', 'TURNOVER_VERIFY_FAILED');
    return json({ ok: false, error: 'turnover_verify_failed', results }, 500);
  }
  await recordHeartbeat('succeeded');
  return json({ ok: true, results });
}));
