// API governor (D-294, session 69). Lloyd: "a system that checks and verifies all api token usage and demand and caps ... if
// there are necessary changes ie consistent outages or excessive headroom, notify immediately." He chose: say the EXACT value
// and WHERE to change it. The system never changes an external cap itself.
//
// PURE: no I/O, no clock, no Deno APIs. index.ts reads the two usage RPCs, app_settings 'api_caps' and the latest key reads,
// calls evaluate(), and pushes what comes back into `found` ahead of apply_verifier_run_v1, exactly as V13 travels. That RPC
// resolves a V14-V18 finding the daily run stops raising, so a rule that no longer fires closes its own card.
//
//   V14 cap pressure   (red)    today is already at pressure_pct of a cap, or on course to pass it
//   V15 provider outage(red)    a provider is failing most of its calls for one feature
//   V16 cap headroom   (yellow) a cap is far above need (lower it) or close to normal need (raise it) - advisory
//   V17 credit runway  (yellow; red under 7 days)
//   V18 cost drift     (yellow) a feature costs more than twice its own norm
//
// ACK STABILITY (D-217.2). apply_verifier_run_v1 compares the WHOLE detail when a finding was acknowledged, so a detail that
// carries a number that moves every run re-opens the card every run and the [Known] button is a lie. Every amount below is
// therefore rounded to a step (percent to 10, USD to 0.05 or 0.01, counts to bands) before it goes into a detail.
import type { Finding } from './cards.ts';
import type { KeyRead } from './budget.ts';

export type UsageDay = {
  day: string; provider: string; title: string; tier: string | null; probe: boolean;
  calls: number; fails: number; input: number; output: number; cost_usd: number;
  /** Not in lane A's first contract. When api_usage_daily_v1 also groups by model, the notional price is exact and the
   *  Cloudflare neuron count is exact; without it both are estimates and the finding says so (approx). */
  model?: string | null;
};
export type BudgetDay = { day: string; key_name: string; limit_usd: number | null; min_remaining_usd: number | null; spent_usd: number | null; snapshots: number };
export type Cap = {
  id: string; label: string; kind: 'usd_day' | 'usd_day_notional' | 'neurons_day'; cap: number;
  floor?: number; key_name?: string; provider?: string; fixed?: boolean; where: string;
};
export type Rules = {
  pressure_pct: number; headroom_x: number; target_x: number; runway_days: number;
  drift_x: number; outage_fail_pct: number; outage_min_calls: number;
};
export type ApiCaps = {
  caps: Cap[]; credit?: { openrouter_usd?: number }; prices_usd_per_m?: Record<string, [number, number]>;
  neuron_usd?: number; rules?: Partial<Rules>;
};
export type GovInput = {
  usage: UsageDay[]; budget: BudgetDay[];
  latest: { primary?: KeyRead; backup?: KeyRead };
  caps: ApiCaps;
  /** Manila calendar date, YYYY-MM-DD. */
  today: string;
  /** Manila clock, 0-24 with minutes as a fraction. */
  nowHourManila: number;
  /** GET /credits when OpenRouter answered it (management key only). Preferred over the estimate. */
  credits?: { remaining: number | null } | null;
};

export const DEFAULT_RULES: Rules = {
  pressure_pct: 70, headroom_x: 20, target_x: 5, runway_days: 30, drift_x: 2, outage_fail_pct: 50, outage_min_calls: 5,
};
const NEURON_USD = 0.000011;

// ── small numeric helpers ────────────────────────────────────────────────────────────────────────────────────────────
const n0 = (v: unknown) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const fix = (x: number) => Number(x.toFixed(6));
const roundTo = (x: number, step: number) => fix(Math.round(x / step) * step);
const ceilTo = (x: number, step: number) => fix(Math.ceil(x / step - 1e-9) * step);
const floorTo = (x: number, step: number) => fix(Math.floor(x / step + 1e-9) * step);
const r2 = (x: number) => Math.round(x * 100) / 100;

/** 'YYYY-MM-DD' plus n days. */
export function addDays(day: string, n: number): string {
  const d = new Date(day + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
const daysBetween = (a: string, b: string) => Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86_400_000);

/** The Manila date and clock hour for an instant, so index.ts needs no date logic of its own. */
export function manilaClock(now: Date): { today: string; hour: number } {
  const p = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Manila', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(now);
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? '0';
  return { today: `${g('year')}-${g('month')}-${g('day')}`, hour: Number(g('hour')) + Number(g('minute')) / 60 };
}

/** Validates what app_settings.api_caps holds. null means unusable, and index.ts logs and skips the governor. */
export function parseCaps(v: unknown): ApiCaps | null {
  const j = v as any;
  if (!j || typeof j !== 'object' || !Array.isArray(j.caps)) return null;
  const caps = j.caps.filter((c: any) => c && typeof c.id === 'string' && typeof c.label === 'string' && Number(c.cap) > 0
    && ['usd_day', 'usd_day_notional', 'neurons_day'].includes(c.kind))
    .map((c: any) => ({ ...c, cap: Number(c.cap), where: String(c.where ?? '') }));
  return { ...j, caps };
}

const PROVIDER: Record<string, string> = { openrouter: 'OpenRouter', gemini: 'Gemini', omniroute: 'OmniRoute' };
export const providerName = (p: string) => PROVIDER[p] ?? p;

// ── what each cap measures ──────────────────────────────────────────────────────────────────────────────────────────
const unitUsd = (cap: Cap, caps: ApiCaps) => (cap.kind === 'neurons_day' ? (caps.neuron_usd ?? NEURON_USD) : 1);
const stepOf = (cap: Cap) => (cap.kind === 'neurons_day' ? 1000 : 0.05);
const unitOf = (cap: Cap) => (cap.kind === 'neurons_day' ? 'neurons' : 'usd');

/** USD a row would cost at list price, and how much of that ran on Cloudflare (neurons are billed in Cloudflare's own unit).
 *  ponytail: a row with no model is priced at its recorded cost_usd, or at the mean Cloudflare price when that is 0, and all
 *  of it is counted as Cloudflare - an upper bound. Add `model` to api_usage_daily_v1's grouping to make it exact. */
function notional(r: UsageDay, caps: ApiCaps): { usd: number; cf: number; approx: boolean } {
  const prices = caps.prices_usd_per_m ?? {};
  const tin = n0(r.input) / 1e6, tout = n0(r.output) / 1e6;
  if (r.model) {
    const p = prices[r.model];
    const usd = p ? tin * n0(p[0]) + tout * n0(p[1]) : n0(r.cost_usd);
    return { usd, cf: r.model.startsWith('@cf/') ? usd : 0, approx: false };
  }
  const cf = Object.entries(prices).filter(([m]) => m.startsWith('@cf/')).map(([, p]) => p);
  const avgIn = cf.length ? cf.reduce((s, p) => s + n0(p[0]), 0) / cf.length : 0;
  const avgOut = cf.length ? cf.reduce((s, p) => s + n0(p[1]), 0) / cf.length : 0;
  const usd = n0(r.cost_usd) > 0 ? n0(r.cost_usd) : tin * avgIn + tout * avgOut;
  return { usd, cf: usd, approx: true };
}

type Series = { byDay: Map<string, number>; seen: Set<string>; approx: boolean };
/** Daily spend of a cap in the cap's own unit (USD, or neurons). `seen` is every day the source has any row, so a quiet day is
 *  a real zero and a day before the system recorded anything is not. */
function seriesFor(cap: Cap, inp: GovInput, withProbe: boolean): Series {
  const byDay = new Map<string, number>(), seen = new Set<string>();
  let approx = false;
  const add = (day: string, v: number) => byDay.set(day, (byDay.get(day) ?? 0) + v);
  if (cap.key_name) {
    for (const b of inp.budget) {
      if (b.key_name !== cap.key_name) continue;
      seen.add(b.day);
      if (b.spent_usd != null) add(b.day, n0(b.spent_usd));
    }
  } else if (cap.provider) {
    const u = unitUsd(cap, inp.caps);
    for (const r of inp.usage) {
      if (r.provider !== cap.provider) continue;
      seen.add(r.day);
      if (r.probe && !withProbe) continue;
      if (cap.kind === 'usd_day') { add(r.day, n0(r.cost_usd)); continue; }
      const n = notional(r, inp.caps);
      if (n.approx) approx = true;
      add(r.day, (cap.kind === 'neurons_day' ? n.cf : n.usd) / u);
    }
  }
  return { byDay, seen, approx };
}

// ── V14 cap pressure ────────────────────────────────────────────────────────────────────────────────────────────────
/** Hours since the current OpenRouter period began. A key's limit resets at 00:00 UTC = 08:00 Manila, and the daily verifier
 *  runs at 07:45 Manila, 23.75 hours into a period. Projecting from Manila midnight instead would triple that period's spend. */
const periodHours = (hourManila: number) => (((hourManila - 8) % 24) + 24) % 24;

function pressure(inp: GovInput, rules: Rules): Finding[] {
  const out: Finding[] = [];
  const yesterday = addDays(inp.today, -1);
  for (const cap of inp.caps.caps) {
    const s = seriesFor(cap, inp, true);
    const u = unitUsd(cap, inp.caps);
    const k = cap.key_name ? inp.latest[cap.key_name as 'primary' | 'backup'] : undefined;
    // For a key, the live read (limit minus remaining) is the current period against its limit, exactly what the key enforces.
    const periodSpent = k && k.status === 200 && k.limit != null && k.remaining != null ? Math.max(0, k.limit - k.remaining) : null;
    const today = s.byDay.get(inp.today) ?? 0;
    // Today's row is only hours old at 07:45, so yesterday (a full day) is the one that shows real pressure.
    const spent = Math.max(today, s.byDay.get(yesterday) ?? 0, periodSpent ?? 0);
    const hrs = periodSpent != null ? periodHours(inp.nowHourManila) : inp.nowHourManila;
    const cur = periodSpent ?? today;
    const proj = hrs >= 6 && cur * u >= 0.05 ? (cur * 24) / hrs : 0;
    const pct = (spent / cap.cap) * 100;
    const byProjection = proj > cap.cap && pct < rules.pressure_pct;
    if (pct < rules.pressure_pct && !byProjection) continue;
    const peak = Math.max(spent, byProjection ? proj : 0, cap.cap);
    out.push({
      key: `V14:${cap.id}`, check_id: 'V14', severity: 'red', title: `${cap.label} is close to its daily limit`,
      detail: {
        // No raw `spent`: it moves inside a 10% step and would reopen an acknowledged card. The card derives it from pct.
        cap_id: cap.id, label: cap.label, unit: unitOf(cap), cap: cap.cap,
        pct: floorTo(pct, 10), projected: byProjection,
        recommended: cap.fixed ? null : ceilTo(peak * 1.5, stepOf(cap)), where: cap.where,
        ...(s.approx ? { approx: true } : {}),
      },
    });
  }
  return out;
}

// ── V15 provider outage ─────────────────────────────────────────────────────────────────────────────────────────────
function outage(inp: GovInput, rules: Rules): Finding[] {
  const yesterday = addDays(inp.today, -1);
  const agg = new Map<string, { provider: string; title: string; calls: number; fails: number }>();
  for (const r of inp.usage) {
    // Probe rows are our own health pings and tests: a probe failing is not a guest failing.
    if (r.probe || (r.day !== inp.today && r.day !== yesterday)) continue;
    const key = `${r.provider}:${r.title}`;
    const a = agg.get(key) ?? { provider: r.provider, title: r.title, calls: 0, fails: 0 };
    a.calls += n0(r.calls); a.fails += n0(r.fails);
    agg.set(key, a);
  }
  const out: Finding[] = [];
  for (const [key, a] of agg) {
    if (a.calls < rules.outage_min_calls || (a.fails / a.calls) * 100 < rules.outage_fail_pct) continue;
    // A free rung that fails and a paid rung that then answers still counts: it is the free provider's outage, and the
    // paid rung is quietly carrying the bill.
    out.push({
      key: `V15:${key}`, check_id: 'V15', severity: 'red', title: `${providerName(a.provider)} is failing for ${a.title}`,
      detail: {
        provider: a.provider, title: a.title, fail_pct: floorTo((a.fails / a.calls) * 100, 10),
        calls_min: a.calls < 10 ? 5 : floorTo(a.calls, 10),
      },
    });
  }
  return out;
}

// ── V16 cap headroom ────────────────────────────────────────────────────────────────────────────────────────────────
function p95(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? s[Math.max(0, Math.ceil(0.95 * s.length) - 1)] : 0;
}

function headroom(inp: GovInput, rules: Rules): Finding[] {
  const out: Finding[] = [];
  for (const cap of inp.caps.caps) {
    if (cap.fixed) continue;
    // Test runs are excluded from usage-derived caps. An OpenRouter key's own spend cannot be split, so its series includes them.
    const s = seriesFor(cap, inp, false);
    if (!s.seen.size) continue;
    const first = [...s.seen].sort()[0];
    const start = first > addDays(inp.today, -30) ? first : addDays(inp.today, -30);
    const days = daysBetween(start, inp.today); // start .. yesterday: today is hours old and would drag the percentile down
    if (days < 14) continue;
    const vals: number[] = [];
    for (let i = 0; i < days; i++) vals.push(s.byDay.get(addDays(start, i)) ?? 0);
    const step = stepOf(cap), unitsPeak = p95(vals);
    const detail = (direction: string, rec: number) => ({
      cap_id: cap.id, label: cap.label, unit: unitOf(cap), direction, current: cap.cap, recommended: rec,
      p95: cap.kind === 'neurons_day' ? roundTo(unitsPeak, 100) : r2(unitsPeak), days: floorTo(days, 7),
      includes_tests: !!cap.key_name, where: cap.where,
    });
    if (cap.cap >= rules.headroom_x * Math.max(unitsPeak, cap.kind === 'neurons_day' ? 100 : 0.01)) {
      const rec = Math.max(cap.floor ?? 0, ceilTo(rules.target_x * unitsPeak, step));
      if (rec < cap.cap) {
        out.push({ key: `V16:${cap.id}`, check_id: 'V16', severity: 'yellow', title: `${cap.label} limit is far above need`, detail: detail('lower', rec) });
      }
    } else if (unitsPeak >= 0.5 * cap.cap) {
      out.push({
        key: `V16:${cap.id}`, check_id: 'V16', severity: 'yellow', title: `${cap.label} limit is close to normal need`,
        detail: detail('raise', ceilTo(rules.target_x * unitsPeak, step)),
      });
    }
  }
  return out;
}

// ── V17 credit runway ───────────────────────────────────────────────────────────────────────────────────────────────
function runway(inp: GovInput, rules: Rules): Finding[] {
  let remaining: number | null = inp.credits?.remaining ?? null;
  const source = remaining != null ? 'openrouter' : 'estimate';
  if (remaining == null) {
    const total = inp.caps.credit?.openrouter_usd;
    const used = [inp.latest.primary?.usage, inp.latest.backup?.usage].filter((v): v is number => typeof v === 'number');
    if (typeof total !== 'number' || !used.length) return [];
    remaining = total - used.reduce((s, v) => s + v, 0);
  }
  const perDay = new Map<string, number>();
  for (const b of inp.budget) {
    if (b.spent_usd == null || b.day >= inp.today || b.day <= addDays(inp.today, -31)) continue;
    perDay.set(b.day, (perDay.get(b.day) ?? 0) + n0(b.spent_usd));
  }
  // Three recorded days before a mean means anything: the first hours of a new snapshot table would otherwise read as free.
  if (perDay.size < 3) return [];
  const avg = [...perDay.values()].reduce((s, v) => s + v, 0) / perDay.size;
  if (avg < 0.005) return [];
  const days = Math.max(0, remaining) / avg;
  if (days >= rules.runway_days) return [];
  const red = days < 7;
  return [{
    key: 'V17:openrouter-credit', check_id: 'V17', severity: red ? 'red' : 'yellow',
    title: red ? 'OpenRouter credit runs out within a week' : 'OpenRouter credit is running low',
    detail: {
      remaining: floorTo(Math.max(0, remaining), 0.5), avg_day: ceilTo(avg, 0.01),
      days: red ? Math.floor(days) : floorTo(days, 5),
      topup: Math.max(5, ceilTo(avg * 90 - Math.max(0, remaining), 5)), source,
    },
  }];
}

// ── V18 cost drift ──────────────────────────────────────────────────────────────────────────────────────────────────
function drift(inp: GovInput, rules: Rules): Finding[] {
  const rows = inp.usage.filter((r) => r.day > addDays(inp.today, -30) && r.day <= inp.today);
  if (!rows.length) return [];
  const first = rows.map((r) => r.day).sort()[0];
  const span = Math.min(30, daysBetween(first, inp.today) + 1);
  // Under two weeks of history a 7-day total is most of the whole record, and every feature looks like it is drifting.
  if (span < 14) return [];
  type G = { title: string; probe: boolean; d30: number; d7: number; in7: number; out7: number; vision: boolean };
  const g = new Map<string, G>();
  const recent = (day: string) => day > addDays(inp.today, -7);
  for (const r of rows) {
    const key = `${r.title}|${r.probe}`;
    const a = g.get(key) ?? { title: r.title, probe: r.probe, d30: 0, d7: 0, in7: 0, out7: 0, vision: false };
    a.d30 += n0(r.cost_usd);
    if (recent(r.day)) {
      a.d7 += n0(r.cost_usd); a.in7 += n0(r.input); a.out7 += n0(r.output);
      if (r.tier === 'vision') a.vision = true;
    }
    g.set(key, a);
  }
  const spent7 = (title: string, probe: boolean) => g.get(`${title}|${probe}`)?.d7 ?? 0;
  const out: Finding[] = [];
  for (const a of g.values()) {
    const base = (a.d30 / span) * 7;
    if (a.d7 < 0.1 || a.d7 <= rules.drift_x * base) continue;
    const all = spent7(a.title, true) + spent7(a.title, false);
    out.push({
      key: `V18:${a.title}${a.probe ? ':test' : ''}`, check_id: 'V18', severity: 'yellow',
      title: `${a.title}${a.probe ? ' test runs' : ''} cost more than usual`,
      detail: {
        title: a.title, probe: a.probe, d7: roundTo(a.d7, 0.1), baseline: roundTo(base, 0.1),
        probe_share: all > 0 ? floorTo((spent7(a.title, true) / all) * 100, 10) : 0,
        // Reasoning-heavy image reads: the model bills hidden thinking tokens as output, so output swamps input.
        reasoning: a.vision && a.in7 > 0 && a.out7 / a.in7 > 3,
      },
    });
  }
  return out;
}

export function evaluate(inp: GovInput): Finding[] {
  const rules: Rules = { ...DEFAULT_RULES, ...(inp.caps.rules ?? {}) };
  return [...pressure(inp, rules), ...outage(inp, rules), ...headroom(inp, rules), ...runway(inp, rules), ...drift(inp, rules)];
}

// ── the Monday line ─────────────────────────────────────────────────────────────────────────────────────────────────
const usd2 = (v: number) => `USD ${v.toFixed(2)}`;
/** One plain sentence for the weekly Finance card: what the last seven days really cost, the two biggest features, what the test
 *  runs cost, and how far each cap is above its busiest day this week. daily-digest owns the call; nothing here reads a clock. */
export function usageWeekLine(usage: UsageDay[], budget: BudgetDay[], caps: ApiCaps, today: string): string {
  const recent = (d: string) => d > addDays(today, -7) && d <= today;
  const real = new Map<string, number>();
  let test = 0, total = 0;
  for (const r of usage) {
    if (!recent(r.day)) continue;
    if (r.probe) { test += n0(r.cost_usd); continue; }
    real.set(r.title, (real.get(r.title) ?? 0) + n0(r.cost_usd));
    total += n0(r.cost_usd);
  }
  const top = [...real.entries()].sort((a, b) => b[1] - a[1]).slice(0, 2).filter(([, v]) => v > 0);
  const head = [`Model calls last 7 days: ${usd2(total)} real spend`];
  if (top.length) head[0] += `, mostly ${top.map(([t, v]) => `${t} (${usd2(v)})`).join(' and ')}`;
  head.push(`test runs ${usd2(test)}`);
  const room = caps.caps.map((cap) => {
    const s = seriesFor(cap, { usage, budget, latest: {}, caps, today, nowHourManila: 0 }, true);
    let peak = 0;
    for (const [d, v] of s.byDay) if (recent(d)) peak = Math.max(peak, v);
    const floorV = cap.kind === 'neurons_day' ? 100 : 0.01;
    return `${cap.label} ${Math.max(1, Math.round(cap.cap / Math.max(peak, floorV)))}x`;
  });
  return `${head.join('; ')}. Headroom to each daily limit: ${room.join(', ')}.`;
}
