// turnover-verifier v1
// Runs daily via pg_cron at 00:00 UTC (08:00 Manila).
// Pass 1 — yesterday's checkout: calls verify_turnover, creates/updates
//   turnover_verification row, fires Finance alert if issues found.
// Pass 2 — day-before-yesterday: if alert_24h already sent and not resolved,
//   fires OPS escalation and stamps alert_36h_sent_at.
// No notification fired when all checks pass.
// Routing: Finance = new issues (T+24h). OPS = unresolved escalation (T+48h).

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { withObservability } from '../_shared/observability.ts';

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

function fmtIssues(issues: string[]): string {
  return issues.map(i => `\u2022 ${i}`).join('\n');
}

Deno.serve(withObservability({ functionName: 'turnover-verifier', route: 'ops' }, async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);
  if (!cronSecretMatches(Deno.env.get('CASCADE_CRON_SHARED_SECRET'), req.headers.get('x-cascade-cron-secret'))) {
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

  // Today in Manila time
  const nowManila   = new Date(new Date().toLocaleString('en-CA', { timeZone: 'Asia/Manila' }));
  const yesterday   = new Date(nowManila); yesterday.setDate(yesterday.getDate() - 1);
  const twoDaysAgo  = new Date(nowManila); twoDaysAgo.setDate(twoDaysAgo.getDate() - 2);

  function toDateStr(d: Date): string {
    return d.toISOString().slice(0, 10);
  }

  const results: Record<string, unknown> = {};

  // PASS 1: yesterday -> Finance alert if issues
  try {
    const d1 = toDateStr(yesterday);
    const { data: v1 } = await supabase.rpc('verify_turnover', { p_checkout_date: d1 });
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
    if (propertyId) {
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

    // Fire Finance alert only if issues found AND alert not already sent
    if (!result1.check_passed || result1.issues.length > 0) {
      const { data: existingRow } = await supabase
        .from('turnover_verification')
        .select('alert_24h_sent_at')
        .eq('property_id', propertyId)
        .eq('checkout_date', d1)
        .maybeSingle();

      if (!existingRow?.alert_24h_sent_at) {
        const issueText = fmtIssues(result1.issues);
        const sessionLine = result1.session_id
          ? `\uD83E\uDDF9 Cleaner: ${result1.cleaner_name ?? 'unknown'}  \u00b7  Photos: ${result1.total_photo_count}  \u00b7  Complete: ${result1.is_complete ? '\u2705' : '\u274C'}`
          : '\u274C No cleaning session found for this checkout.';

        const lines = [
          `\uD83D\uDD0D *Turnover Check \u2014 T+24h*`,
          `\uD83D\uDCCD Cascade Bria  \u00b7  Checkout: ${d1}`,
          ``,
          sessionLine,
          ``,
          `\u26A0\uFE0F *Issues detected:*`,
          issueText,
          ``,
          `_Resolve before next guest check-in. OPS will be alerted tomorrow if unresolved._`,
        ];

        await tgPost(TG_TOKEN, 'sendMessage', {
          chat_id:    TG_FINANCE_ID,
          text:       lines.join('\n'),
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

  // PASS 2: two days ago -> OPS escalation if unresolved
  try {
    const d2 = toDateStr(twoDaysAgo);
    const { data: prop } = await supabase.from('properties').select('id').limit(1).maybeSingle();
    const propertyId = prop?.id;

    if (propertyId) {
      const { data: tvRow } = await supabase
        .from('turnover_verification')
        .select('*')
        .eq('property_id', propertyId)
        .eq('checkout_date', d2)
        .maybeSingle();

      if (
        tvRow &&
        !tvRow.check_passed &&
        tvRow.alert_24h_sent_at &&
        !tvRow.alert_36h_sent_at &&
        !tvRow.resolved_at
      ) {
        const issueText = fmtIssues(tvRow.issues ?? []);
        const lines = [
          `\uD83D\uDEA8 *Turnover Unresolved \u2014 ESCALATION*`,
          `\uD83D\uDCCD Cascade Bria  \u00b7  Checkout: ${d2}`,
          ``,
          `\u26A0\uFE0F Finance was notified 24h ago. Issues still open:`,
          issueText,
          ``,
          `_Please verify the unit is ready for the next guest._`,
        ];

        await tgPost(TG_TOKEN, 'sendMessage', {
          chat_id:    TG_OPS_ID,
          text:       lines.join('\n'),
          parse_mode: 'Markdown',
        });

        await supabase
          .from('turnover_verification')
          .update({ alert_36h_sent_at: new Date().toISOString() })
          .eq('id', tvRow.id);

        results.escalation_sent = d2;
      } else {
        results.no_escalation_needed = d2;
      }
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
