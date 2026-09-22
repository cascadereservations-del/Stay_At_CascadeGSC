// system-verifier v1 (SPEC-11 session 2, 2026-09-21).
//
// Two schedules, one function. Hourly at :35 runs V1-V5, V11, V12; daily at
// 23:45 UTC (07:45 Manila, before the 08:00 digest) runs those plus V6 and V10.
// The checks themselves live in SQL, so adding one is a migration and never a
// deploy - that is the whole point of the shape.
//
// ?dry=1 runs the checks, prints them, and writes and sends NOTHING. That is a
// promise the code has to keep: run_system_verifier_v1 is `stable` and stores
// nothing, apply_verifier_run_v1 is the only writer, and the health-check
// refresh below is skipped on a dry run for exactly the same reason.
//
// THE DAILY REFRESH IS NOT OPTIONAL. V10 reads admin_health_check_runs rather
// than taking a reading itself, so if this call is ever dropped V10 reports
// whatever was true the last time somebody pressed the dashboard button - which
// on 2026-09-21 was seven days earlier. V10:stale is the check that catches
// that, and this call is what stops it from ever needing to.
//
// ponytail: no queue and no per-finding state here. verifier_findings already
// decides what is new, what is due a reminder and what has gone; this function
// only has to say it.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { autoKeyboard } from '../_shared/cascade-core/format.ts';
import { ackHash, buildCards, type Applied, type Card, type Finding } from './cards.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const FINANCE_CHAT = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';
const OPS_CHAT = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const JSON_H = { 'Content-Type': 'application/json' };
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, x-cascade-cron-secret' };

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...CORS, ...JSON_H } });

async function tgSend(chat: string, text: string, extra: Array<Array<{ text: string; callback_data: string }>>): Promise<boolean> {
  if (!TG_TOKEN || !chat) return false;
  const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST',
    headers: JSON_H,
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true, reply_markup: autoKeyboard(text, ...extra) }),
    signal: AbortSignal.timeout(15_000),
  }).catch((e) => { console.error('tgSend', String(e)); return null; });
  if (r && !r.ok) console.error('tgSend non-ok', r.status, (await r.text().catch(() => '')).slice(0, 200));
  return !!r?.ok;
}

const manilaToday = (now: Date) =>
  new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Manila', day: 'numeric', month: 'short' }).format(now);

Deno.serve(withObservability({ functionName: 'system-verifier', route: 'ops' }, async (req: Request) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  const cronSecret = Deno.env.get('CASCADE_CRON_SHARED_SECRET');
  if (cronSecret && !cronSecretMatches(cronSecret, req.headers.get('x-cascade-cron-secret'))) {
    return json({ ok: false, error: 'unauthorized' }, 401);
  }

  const url = new URL(req.url);
  const scope = url.searchParams.get('scope') ?? 'hourly';
  const dry = url.searchParams.get('dry') === '1';
  if (scope !== 'hourly' && scope !== 'daily') return json({ ok: false, error: 'scope must be hourly or daily' }, 400);

  const db = createClient(SUPABASE_URL, SERVICE_ROLE);
  const hb = heartbeat(db, `system-verifier-${scope}`);
  await hb('started');
  const now = new Date();

  try {
    // V10 reads a stored health run, so the daily scope takes a fresh one first.
    // A failure here warns and does not throw: the other checks are still worth
    // running, and V10:stale will say the numbers are old.
    let healthRefreshed = false;
    if (scope === 'daily' && !dry) {
      const { error } = await db.rpc('run_health_checks_service_v1', { p_property_id: PROPERTY_ID });
      if (error) console.warn('run_health_checks_service_v1:', error.message);
      else healthRefreshed = true;
    }

    const { data: run, error: runErr } = await db.rpc('run_system_verifier_v1', { p_property_id: PROPERTY_ID, p_scope: scope });
    if (runErr) throw new Error('run_system_verifier_v1: ' + runErr.message);
    const found = (run?.found ?? []) as Finding[];

    if (dry) {
      console.log(JSON.stringify({ event: 'system_verifier', scope, dry: true, found: found.length }));
      await hb('succeeded');
      return json({ ok: true, scope, dry: true, health_refreshed: false, found });
    }

    const { data: applied, error: applyErr } = await db.rpc('apply_verifier_run_v1', { p_scope: scope, p_found: found });
    if (applyErr) throw new Error('apply_verifier_run_v1: ' + applyErr.message);

    const cards: Card[] = buildCards((applied ?? {}) as Applied, now, manilaToday(now));
    let sent = 0;
    for (const c of cards) {
      const chat = c.to === 'ops' ? OPS_CHAT : FINANCE_CHAT;
      // The ack button only goes on a card that IS one finding. A card carrying
      // five of them has nothing sensible to acknowledge.
      const buttons = c.ackKey
        ? [[{ text: '🙈 Known, stop reminding', callback_data: `vf:ack:${await ackHash(c.ackKey)}` }]]
        : [];
      if (await tgSend(chat, c.text, buttons)) sent += 1;
    }

    const counts = {
      new: (applied?.new ?? []).length,
      remind: (applied?.remind ?? []).length,
      resolved: (applied?.resolved ?? []).length,
    };
    console.log(JSON.stringify({ event: 'system_verifier', scope, dry: false, health_refreshed: healthRefreshed, ...counts, cards: cards.length, sent }));
    // SPEC-17 (D-212): the findings are already marked announced by apply_verifier_run_v1; a card
    // Telegram refused would otherwise vanish until its reminder. Say so where the monitor looks.
    await (sent < cards.length ? hb('failed', `TELEGRAM_SEND_FAILED:${cards.length - sent}`) : hb('succeeded'));
    return json({ ok: true, scope, dry: false, health_refreshed: healthRefreshed, ...counts, cards: cards.length, sent });
  } catch (err) {
    console.error('system-verifier error:', String(err));
    await hb('failed', String(err).slice(0, 80));
    return json({ ok: false, scope, error: String(err) }, 500);
  }
}));
