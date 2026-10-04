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
// V13 (D-227, session 49) is the one check raised here rather than in SQL: it needs a GET to OpenRouter.
// V14-V18 (D-294, session 69) are the API governor, raised here too: governor.ts is pure, this file reads the usage RPCs,
// api_caps and the open governor findings, snapshots the OpenRouter keys every run, and hands the findings to
// apply_verifier_run_v1. Hourly pushes V14-V15 only (urgent); daily pushes V14-V18.
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
import { budgetFinding, readCredits, readKey, type KeyRead } from './budget.ts';
import { budgetRows, carried, GOV_CHECKS, governor, manilaClock, parseCaps, usageRows, type GovResult } from './governor.ts';

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

const isMissingRpc = (e: { code?: string; message?: string }) => e.code === 'PGRST202' || e.code === '42883' || /could not find the function|does not exist/i.test(e.message ?? '');

const GOVERNOR_CHECKS = GOV_CHECKS.daily;
/** How long a governor finding may be carried forward without a complete daily evaluation. After that the findings resolve, and
 *  job-heartbeat-monitor has already said the governor stopped ('api-governor', expected every 2 days, alert at 1.5x). */
const CARRY_MS = 2 * 86_400_000;

/** The governor's result, or null when it could not run at all (usage RPCs not applied yet, api_caps unreadable): logged, not
 *  thrown. `open` is what verifier_findings still holds, so a recommended value holds until it moves 25%. */
async function governorFindings(db: any, now: Date, open: Finding[], kPrimary?: KeyRead, kBackup?: KeyRead, orKey?: string): Promise<GovResult | null> {
  const [u, b, c] = await Promise.all([
    db.rpc('api_usage_daily_v1', { p_days: 35 }),
    db.rpc('api_budget_daily_v1', { p_days: 35 }),
    db.from('app_settings').select('value').eq('key', 'api_caps').maybeSingle(),
  ]);
  for (const r of [u, b]) {
    if (r.error) {
      if (isMissingRpc(r.error)) { console.log(JSON.stringify({ event: 'governor_skipped', reason: 'usage RPCs not applied yet' })); return null; }
      throw new Error(r.error.message);
    }
  }
  const caps = parseCaps(c.data?.value);
  if (!caps) { console.log(JSON.stringify({ event: 'governor_skipped', reason: 'api_caps missing or unusable' })); return null; }
  // Real credit from OpenRouter when it will say (management key only), daily only: V17 is a daily rule. Status only is logged.
  let credits: { status: number; remaining: number | null } | null = null;
  if (orKey) {
    credits = await readCredits(orKey);
    console.log(JSON.stringify({ event: 'openrouter_credits', status: credits.status, remaining: credits.remaining }));
  }
  const { today, hour } = manilaClock(now);
  const g = governor({
    usage: usageRows(u.data), budget: budgetRows(b.data),
    latest: { primary: kPrimary, backup: kBackup }, caps, today, nowHourManila: hour, credits, open,
  });
  console.log(JSON.stringify({ event: 'governor', today, findings: g.found.map((f) => f.key), unknown: g.unknown }));
  return g;
}

/** Every V14-V18 finding still open or acknowledged, or null when the read failed. */
async function openGovernor(db: any): Promise<Finding[] | null> {
  const { data, error } = await db.from('verifier_findings').select('key, check_id, severity, title, detail')
    .in('check_id', GOVERNOR_CHECKS).in('status', ['open', 'acknowledged']);
  if (error) { console.warn('governor open findings:', error.message); return null; }
  return (data ?? []) as Finding[];
}

/** Carry-forward is allowed while the last complete daily evaluation ('api-governor' heartbeat) is under 2 days old.
 *  ponytail: an unreadable heartbeat row carries forward (a transient read error must not resolve and re-announce every card);
 *  a missing row does not. */
async function carryAllowed(db: any, now: Date): Promise<boolean> {
  const { data, error } = await db.from('job_heartbeats').select('last_succeeded_at').eq('job_name', 'api-governor').maybeSingle();
  if (error) { console.warn('api-governor heartbeat read:', error.message); return true; }
  const t = Date.parse(String(data?.last_succeeded_at ?? ''));
  return Number.isFinite(t) && now.getTime() - t < CARRY_MS;
}

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

    // V13 model budget, every run in both scopes. The log line is the live proof of the field names.
    const orKey = Deno.env.get('CASCADE_OPENROUTER_BOT_KEY');
    let kPrimary: KeyRead | undefined;
    if (orKey) {
      const k = kPrimary = await readKey(orKey);
      console.log(JSON.stringify({ event: 'openrouter_budget', scope, ...k }));
      const v13 = budgetFinding(k);
      if (v13) found.push(v13);
    }
    // 2026-09-30 (Lloyd): the second Cascade OpenRouter key behind the guests' key - its budget logged the same way, so the
    // key is proven live the hour it is set and watched after.
    const orBackup = Deno.env.get('CASCADE_OPENROUTER_BACKUP_KEY');
    let kBackup: KeyRead | undefined;
    if (orBackup) {
      kBackup = await readKey(orBackup);
      console.log(JSON.stringify({ event: 'openrouter_budget_backup', scope, ...kBackup }));
    }
    // D-294: one snapshot per key per run, hourly and daily, so api_budget_daily_v1 can say what a day cost (a key's remaining
    // limit alone cannot once the period resets). A refused or failed read is stored too, with status and null amounts.
    if (!dry) {
      const snaps = [['primary', kPrimary], ['backup', kBackup]].filter(([, k]) => k)
        .map(([name, k]) => ({ key_name: name, status: (k as KeyRead).status, limit_usd: (k as KeyRead).limit, remaining_usd: (k as KeyRead).remaining, usage_usd: (k as KeyRead).usage ?? null }));
      if (snaps.length) {
        const { error } = await db.from('api_budget_snapshots').insert(snaps);
        if (error) console.warn('api_budget_snapshots:', error.message);
      }
    }
    // D-287: Cascade's own OmniRoute (the third rung). Probes never reach it, so this hourly call is its live proof: a tiny
    // chat through the combo must come back with content. A listed combo is not proof - on 2026-09-30 /models listed
    // cascade-guest while both of its Groq steps could not serve a guest prompt. ~40 tokens, a few Cloudflare neurons an
    // hour. Advisory - a failure here never fails the verifier run.
    const omniUrl = (Deno.env.get('CASCADE_OMNIROUTE_URL') ?? '').replace(/\/+$/, ''), omniKey = Deno.env.get('CASCADE_OMNIROUTE_KEY');
    if (omniUrl && omniKey) {
      const model = Deno.env.get('CASCADE_OMNIROUTE_MODEL') || 'cascade-guest';
      const r = await fetch(`${omniUrl}/chat/completions`, { method: 'POST', headers: { Authorization: `Bearer ${omniKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model, max_tokens: 30, temperature: 0, messages: [{ role: 'user', content: 'Health check. Reply with exactly this JSON: {"answer":"ok, healthy"}' }] }),
        signal: AbortSignal.timeout(25_000) }).catch(() => null);
      const j = r?.ok ? await r.json().catch(() => null) : null;
      const answered = Boolean(String(j?.choices?.[0]?.message?.content ?? '').trim());
      console.log(JSON.stringify({ event: 'omniroute_health', scope, status: r?.status ?? 0, model, answered, served: j?.model ?? null }));
      // Session 68: the rung was dead 2.5 days (an unpriced model under a USD key cap) and only this log line knew. A real answer
      // is now a heartbeat (successes only, so one bad hour does not page); job-heartbeat-monitor sends one Finance alert when
      // 'omniroute-answer' has had no answer for 1.5 x its 2 h interval = 3 h.
      if (!dry && answered) await heartbeat(db, 'omniroute-answer')('succeeded');
    }

    // D-294 governor, both scopes. NEVER fails the run (like the OmniRoute probe above). Hourly pushes only V14-V15: they are
    // urgent and their inputs move within the hour; V16-V18 read whole days, and V17's remaining credit would move every hour.
    // The trap: apply_verifier_run_v1 resolves any finding of a check the scope ran that this run did not raise. So a rule that
    // could not be computed (a key read failed, a day of snapshots missing, the RPCs down) re-raises its open findings unchanged
    // - per rule, not all or nothing - for at most 2 days (carryAllowed). A complete daily evaluation is the 'api-governor'
    // heartbeat (successes only, like 'omniroute-answer').
    {
      const checks = GOV_CHECKS[scope as 'hourly' | 'daily'];
      const open = await openGovernor(db);
      let g: GovResult | null = null;
      try {
        g = await governorFindings(db, now, open ?? [], kPrimary, kBackup, scope === 'daily' ? orKey : undefined);
      } catch (e) {
        console.warn('governor failed:', String(e).slice(0, 200));
      }
      const fresh = (g?.found ?? []).filter((f) => checks.includes(f.check_id));
      found.push(...fresh);
      const keep = carried(open ?? [], fresh, g ? g.unknown : checks, scope as 'hourly' | 'daily');
      if (keep.length) {
        const ok = await carryAllowed(db, now);
        if (ok) found.push(...keep);
        console.log(JSON.stringify({ event: ok ? 'governor_carried' : 'governor_carry_expired', keys: keep.map((f) => f.key) }));
      }
      if (scope === 'daily' && !dry && open && g && !g.unknown.length) await heartbeat(db, 'api-governor')('succeeded');
    }
    if (scope === 'daily' && !dry) {
      const { error } = await db.rpc('prune_api_usage_v1', { p_keep_days: 120 });
      if (error && !isMissingRpc(error)) console.warn('prune_api_usage_v1:', error.message);
    }

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
