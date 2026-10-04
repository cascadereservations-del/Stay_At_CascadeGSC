// API governor (D-294, session 69). Lloyd: "a system that checks and verifies all api token usage and demand and caps ... if
// there are necessary changes ie consistent outages or excessive headroom, notify immediately." He chose: say the EXACT value
// and WHERE to change it. The system never changes an external cap itself.
//
// PURE: no I/O, no clock, no Deno APIs. index.ts reads the two usage RPCs, app_settings 'api_caps', the latest key reads and
// the governor findings still open, calls governor(), and pushes what comes back into `found` ahead of apply_verifier_run_v1,
// exactly as V13 travels. That RPC resolves a finding of a check the scope ran and this run did not raise, so a rule that no
// longer fires closes its own card - and a rule that could not be computed must say so (`unknown`) and be carried forward.
//
//   V14 cap pressure   (red)    a cap is already at pressure_pct, or on course to pass it      hourly and daily
//   V15 provider outage(red)    a provider is failing most of its calls for one feature        hourly and daily
//   V16 cap headroom   (yellow) a cap is far above need (lower it) or close to normal need (raise it) - advisory, daily
//   V17 credit runway  (yellow; red under 7 days)                                              daily
//   V18 cost drift     (yellow) a feature costs more than drift_x its own norm                 daily
//
// ACK STABILITY (D-217.2). apply_verifier_run_v1 compares the WHOLE detail of an acknowledged finding, so any value in a detail
// that moves day to day re-opens the card and the [Known] button is a lie. A detail therefore carries only static config
// (label, unit, where) and coarse bands: a percent band, a days band, a direction, a cause, and a recommended value that is
// re-issued only when it moves by 25% or more (stick). No amounts, no counts, no averages - the cards print what is here.
import type { Finding } from './cards.ts';
import type { KeyRead } from './budget.ts';

export type UsageDay = {
  day: string; provider: string; title: string; tier: string | null; probe: boolean;
  calls: number; fails: number; input: number; output: number; cost_usd: number;
  /** The SERVED model id (api_usage_daily_v1 groups by it). A row whose model has no list price is an estimate (approx). */
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
  /** A key that is not configured is absent; a configured key whose read failed has a status other than 200. */
  latest: { primary?: KeyRead; backup?: KeyRead };
  caps: ApiCaps;
  /** Manila calendar date, YYYY-MM-DD. */
  today: string;
  /** Manila clock, 0-24 with minutes as a fraction. */
  nowHourManila: number;
  /** GET /credits when OpenRouter answered it (management key only). Preferred over the estimate. */
  credits?: { remaining: number | null } | null;
  /** The V14-V18 findings still open or acknowledged, so a recommended value holds until it moves 25% (stick). */
  open?: Finding[];
};
/** `unknown` names a rule this run could not compute: a check id ('V17') or one finding key ('V14:openrouter-primary'). */
export type GovResult = { found: Finding[]; unknown: string[] };

/** Which governor checks each verifier scope raises. apply_verifier_run_v1 carries the same lists (V14-V15 hourly). V16-V18
 *  are daily only: their inputs are whole days, and V17's remaining credit moves every hour. */
export const GOV_CHECKS: Record<'hourly' | 'daily', string[]> = { hourly: ['V14', 'V15'], daily: ['V14', 'V15', 'V16', 'V17', 'V18'] };

export const DEFAULT_RULES: Rules = {
  pressure_pct: 70, headroom_x: 20, target_x: 5, runway_days: 30, drift_x: 2, outage_fail_pct: 50, outage_min_calls: 5,
};
const NEURON_USD = 0.000011;

// ── small numeric helpers ────────────────────────────────────────────────────────────────────────────────────────────
const n0 = (v: unknown) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const fix = (x: number) => Number(x.toFixed(6));
const ceilTo = (x: number, step: number) => fix(Math.ceil(x / step - 1e-9) * step);

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

/** The two RPCs return numeric and bigint as strings: one place turns them into numbers (index.ts and daily-digest).
 *  A budget amount that is null stays null - a day with no successful snapshot pair is unknown, never 0. */
export const usageRows = (data: unknown): UsageDay[] => ((data ?? []) as any[]).map((r) => ({
  ...r, day: String(r.day).slice(0, 10), calls: Number(r.calls), fails: Number(r.fails), input: Number(r.input), output: Number(r.output), cost_usd: Number(r.cost_usd),
}));
const numOrNull = (v: unknown) => (v == null ? null : Number(v));
export const budgetRows = (data: unknown): BudgetDay[] => ((data ?? []) as any[]).map((r) => ({
  ...r, day: String(r.day).slice(0, 10), limit_usd: numOrNull(r.limit_usd), min_remaining_usd: numOrNull(r.min_remaining_usd), spent_usd: numOrNull(r.spent_usd),
}));

const PROVIDER: Record<string, string> = { openrouter: 'OpenRouter', gemini: 'Gemini', omniroute: 'OmniRoute' };
export const providerName = (p: string) => PROVIDER[p] ?? p;

// ── what each cap measures ──────────────────────────────────────────────────────────────────────────────────────────
const unitUsd = (cap: Cap, caps: ApiCaps) => (cap.kind === 'neurons_day' ? (caps.neuron_usd ?? NEURON_USD) : 1);
const stepOf = (cap: Cap) => (cap.kind === 'neurons_day' ? 1000 : 0.05);
const unitOf = (cap: Cap) => (cap.kind === 'neurons_day' ? 'neurons' : 'usd');
const keyRead = (cap: Cap, inp: GovInput) => (cap.key_name ? inp.latest[cap.key_name as 'primary' | 'backup'] : undefined);
/** The limit an OpenRouter key really enforces, when its read succeeded. api_caps.cap is the fallback, and the only source for
 *  OmniRoute and Cloudflare: nothing reads their live limit. */
const liveLimit = (cap: Cap, inp: GovInput) => { const k = keyRead(cap, inp); return k?.status === 200 && k.limit != null && k.limit > 0 ? k.limit : null; };
const prevDetail = (inp: GovInput, key: string) => ((inp.open ?? []).find((f) => f.key === key)?.detail ?? null) as Record<string, any> | null;

/** A recommended value is re-issued only when it moves 25% or more from the one already on the card: a slow drift in need must
 *  not re-open an acknowledged finding every morning. */
const stick = (prev: unknown, v: number) => (typeof prev === 'number' && prev > 0 && Math.abs(v - prev) / prev < 0.25 ? prev : v);

/** THE value for a cap (V14 and V16 both say it, so a cap never has two): target_x times the need, rounded up to the cap's step,
 *  never below its floor, and held while it moves under 25%. */
export function recommend(cap: Cap, need: number, rules: Rules, prev?: unknown): number {
  return stick(prev, Math.max(cap.floor ?? 0, ceilTo(rules.target_x * need, stepOf(cap))));
}

/** USD a row would cost at list price, and how much of that ran on Cloudflare (neurons are billed in Cloudflare's own unit).
 *  A row whose model has no list price (or none recorded) is estimated at the mean Cloudflare price, all of it counted as
 *  Cloudflare - an upper bound - and marked approx. Never silently 0. A row with no tokens and no cost (a failed call) costs
 *  nothing and is not an estimate. */
function notional(r: UsageDay, caps: ApiCaps): { usd: number; cf: number; approx: boolean } {
  const prices = caps.prices_usd_per_m ?? {};
  const tin = n0(r.input) / 1e6, tout = n0(r.output) / 1e6;
  const p = r.model ? prices[r.model] : undefined;
  if (p) {
    const usd = tin * n0(p[0]) + tout * n0(p[1]);
    return { usd, cf: r.model!.startsWith('@cf/') ? usd : 0, approx: false };
  }
  if (tin + tout === 0 && n0(r.cost_usd) === 0) return { usd: 0, cf: 0, approx: false };
  const cf = Object.entries(prices).filter(([m]) => m.startsWith('@cf/')).map(([, q]) => q);
  const avgIn = cf.length ? cf.reduce((s, q) => s + n0(q[0]), 0) / cf.length : 0;
  const avgOut = cf.length ? cf.reduce((s, q) => s + n0(q[1]), 0) / cf.length : 0;
  const usd = n0(r.cost_usd) > 0 ? n0(r.cost_usd) : tin * avgIn + tout * avgOut;
  return { usd, cf: usd, approx: true };
}

type Series = { byDay: Map<string, number>; seen: Set<string>; approx: boolean };
/** Daily spend of a cap in the cap's own unit (USD, or neurons). `seen` is every day the source has any row. A key's day whose
 *  spend is null is absent from byDay (unknown); a quiet usage day after the first row is a real zero. */
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

function p95(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? s[Math.max(0, Math.ceil(0.95 * s.length) - 1)] : 0;
}

/** A cap's busiest normal day (95th percentile of the last 30 whole days, today excluded: it is hours old). Null under 14 known
 *  days. Test runs are left out of usage-derived caps; an OpenRouter key's own spend cannot be split, so it includes them. A
 *  key day with no successful snapshot pair is left out, never counted as 0, and a missing yesterday makes the need unknown. */
function normalNeed(cap: Cap, inp: GovInput): { p95: number | null; unknown: boolean } {
  const s = seriesFor(cap, inp, false);
  const past = [...s.seen].filter((d) => d < inp.today).sort();
  const unknown = !!cap.key_name && past.length > 0 && s.byDay.get(addDays(inp.today, -1)) == null;
  if (!past.length) return { p95: null, unknown };
  const start = past[0] > addDays(inp.today, -30) ? past[0] : addDays(inp.today, -30);
  const vals: number[] = [];
  for (let d = start; d < inp.today; d = addDays(d, 1)) {
    const v = s.byDay.get(d);
    if (v != null) vals.push(v); else if (!cap.key_name) vals.push(0);
  }
  return { p95: vals.length >= 14 ? p95(vals) : null, unknown };
}

// ── V14 cap pressure ────────────────────────────────────────────────────────────────────────────────────────────────
/** Hours since the current OpenRouter period began. A key's limit resets at 00:00 UTC = 08:00 Manila, and the daily verifier
 *  runs at 07:45 Manila, 23.75 hours into a period. Projecting from Manila midnight instead would triple that period's spend. */
const periodHours = (hourManila: number) => (((hourManila - 8) % 24) + 24) % 24;

function pressure(inp: GovInput, rules: Rules, v16Active: Set<string>, unknown: Set<string>): Finding[] {
  const out: Finding[] = [];
  const yesterday = addDays(inp.today, -1);
  for (const cap of inp.caps.caps) {
    const key = `V14:${cap.id}`;
    let limit: number, spent: number, cur: number, hrs: number, approx = false;
    if (cap.key_name) {
      // An OpenRouter key: ONLY the live read. limit - remaining is the current OpenRouter period (00:00 UTC = 08:00 Manila)
      // against the limit the key enforces; summing Manila-day spend would straddle two periods.
      const k = keyRead(cap, inp);
      if (!k) continue; // not configured
      if (k.status !== 200) { unknown.add(key); continue; }
      if (k.limit == null || k.limit <= 0 || k.remaining == null) continue; // no limit on the key: nothing to press against
      limit = k.limit; spent = cur = Math.max(0, k.limit - k.remaining); hrs = periodHours(inp.nowHourManila);
    } else {
      // OmniRoute and Cloudflare: token totals at list price per Manila day, an estimate. Yesterday is the full day; today is
      // hours old and projected.
      const s = seriesFor(cap, inp, true);
      limit = cap.cap; cur = s.byDay.get(inp.today) ?? 0; spent = Math.max(cur, s.byDay.get(yesterday) ?? 0);
      hrs = inp.nowHourManila; approx = s.approx;
    }
    const proj = hrs >= 6 && cur * unitUsd(cap, inp.caps) >= 0.05 ? (cur * 24) / hrs : 0;
    const pct = (spent / limit) * 100;
    const byProjection = proj > limit && pct < rules.pressure_pct;
    if (pct < rules.pressure_pct && !byProjection) continue;
    // One value per cap: when V16 is advising on this cap, the value lives there and V14 only states the pressure.
    const defer = v16Active.has(cap.id);
    const need = Math.max(normalNeed(cap, inp).p95 ?? 0, spent, byProjection ? proj : 0);
    out.push({
      key, check_id: 'V14', severity: 'red', title: `${cap.label} is close to its daily limit`,
      detail: {
        cap_id: cap.id, label: cap.label, unit: unitOf(cap), cap: limit, reads_live: !!cap.key_name, where: cap.where,
        // A band, not a percent: 70 (70-89), 90 (90-99) or 100 (at or over). A projection carries no percent at all.
        projected: byProjection, ...(byProjection ? {} : { pct: pct >= 100 ? 100 : pct >= 90 ? 90 : rules.pressure_pct }),
        recommended: cap.fixed || defer ? null : recommend(cap, need, rules, prevDetail(inp, key)?.recommended),
        ...(cap.fixed ? { fixed: true } : defer ? { advice: 'V16' } : {}),
        ...(cap.key_name ? {} : { estimate: true }), ...(approx ? { approx: true } : {}),
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
    const pct = a.calls ? (a.fails / a.calls) * 100 : 0;
    if (a.calls < rules.outage_min_calls || pct < rules.outage_fail_pct) continue;
    // A free rung that fails and a paid rung that then answers still counts: it is the free provider's outage, and the
    // paid rung is quietly carrying the bill. Two bands and no call count, so the card holds while the outage lasts.
    out.push({
      key: `V15:${key}`, check_id: 'V15', severity: 'red', title: `${providerName(a.provider)} is failing for ${a.title}`,
      detail: { provider: a.provider, title: a.title, fail_band: pct >= 75 ? '75-100' : `${rules.outage_fail_pct}-74` },
    });
  }
  return out;
}

// ── V16 cap headroom ────────────────────────────────────────────────────────────────────────────────────────────────
function headroom(inp: GovInput, rules: Rules, unknown: Set<string>): Finding[] {
  const out: Finding[] = [];
  for (const cap of inp.caps.caps) {
    if (cap.fixed) continue;
    const key = `V16:${cap.id}`;
    const k = keyRead(cap, inp);
    const need = normalNeed(cap, inp);
    if ((k && k.status !== 200) || need.unknown) { unknown.add(key); continue; }
    if (need.p95 == null) continue;
    const current = liveLimit(cap, inp) ?? cap.cap, peak = need.p95;
    const direction = current >= rules.headroom_x * Math.max(peak, cap.kind === 'neurons_day' ? 100 : 0.01) ? 'lower'
      : peak >= 0.5 * current ? 'raise' : null;
    if (!direction) continue;
    const prev = prevDetail(inp, key);
    const rec = recommend(cap, peak, rules, prev?.direction === direction ? prev.recommended : null);
    // Once the limit already equals the advice (or is past it), the change is made: say nothing.
    if (direction === 'lower' ? rec >= current : rec <= current) continue;
    out.push({
      key, check_id: 'V16', severity: 'yellow',
      title: direction === 'lower' ? `${cap.label} limit is far above need` : `${cap.label} limit is close to normal need`,
      // cap id, direction and the value; label, unit, where and reads_live are static config the card needs to say where.
      detail: { cap_id: cap.id, direction, recommended: rec, label: cap.label, unit: unitOf(cap), where: cap.where, reads_live: !!cap.key_name },
    });
  }
  return out;
}

// ── V17 credit runway ───────────────────────────────────────────────────────────────────────────────────────────────
function runway(inp: GovInput, rules: Rules, unknown: Set<string>): Finding[] {
  const keys = [inp.latest.primary, inp.latest.backup].filter((k): k is KeyRead => !!k);
  // One key read failed: neither the estimate nor the spend behind it is whole. Carry the card, do not recompute it.
  if (keys.some((k) => k.status !== 200)) { unknown.add('V17'); return []; }
  let remaining: number | null = inp.credits?.remaining ?? null;
  const source = remaining != null ? 'openrouter' : 'estimate';
  if (remaining == null) {
    const total = inp.caps.credit?.openrouter_usd;
    if (typeof total !== 'number' || !keys.length) return [];
    if (keys.some((k) => typeof k.usage !== 'number')) { unknown.add('V17'); return []; }
    remaining = total - keys.reduce((s, k) => s + (k.usage as number), 0);
  }
  // Spend per day across the keys. A day where a key that already existed has no known spend is unknown and left out.
  const spend = new Map<string, number | null>(), first = new Map<string, string>();
  for (const b of inp.budget) {
    spend.set(`${b.key_name}|${b.day}`, b.spent_usd);
    if (!first.has(b.key_name) || b.day < first.get(b.key_name)!) first.set(b.key_name, b.day);
  }
  const perDay: number[] = [];
  for (let d = addDays(inp.today, -30); d < inp.today; d = addDays(d, 1)) {
    let sum = 0, known = false;
    for (const [name, from] of first) {
      if (from > d) continue;
      const v = spend.get(`${name}|${d}`);
      if (v == null) { known = false; break; }
      sum += v; known = true;
    }
    if (known) perDay.push(sum);
  }
  // Three known days before a mean means anything: the first hours of a new snapshot table would otherwise read as free.
  if (perDay.length < 3) return [];
  const avg = perDay.reduce((s, v) => s + v, 0) / perDay.length;
  if (avg < 0.005) return [];
  const days = Math.max(0, remaining) / avg;
  if (days >= rules.runway_days) return [];
  const band = days < 7 ? '<7' : days < 14 ? '7-13' : `14-${rules.runway_days - 1}`;
  return [{
    key: 'V17:openrouter-credit', check_id: 'V17', severity: band === '<7' ? 'red' : 'yellow',
    title: band === '<7' ? 'OpenRouter credit runs out within a week' : 'OpenRouter credit is running low',
    detail: {
      days: band, source,
      topup: stick(prevDetail(inp, 'V17:openrouter-credit')?.topup, Math.max(5, ceilTo(avg * 90 - Math.max(0, remaining), 5))),
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
        title: a.title, probe: a.probe, direction: 'up', x: rules.drift_x,
        // Reasoning-heavy image reads: the model bills hidden thinking tokens as output, so output swamps input.
        cause: a.vision && a.in7 > 0 && a.out7 / a.in7 > 3 ? 'reasoning'
          : all > 0 && spent7(a.title, true) / all >= 0.5 ? 'test_runs' : null,
      },
    });
  }
  return out;
}

export function governor(inp: GovInput): GovResult {
  const rules: Rules = { ...DEFAULT_RULES, ...(inp.caps.rules ?? {}) };
  const unknown = new Set<string>();
  const v16 = headroom(inp, rules, unknown);
  // V16 is advising on a cap when it fired now, or could not be computed and is carried forward with its value.
  const active = new Set([...v16, ...(inp.open ?? []).filter((f) => f.check_id === 'V16' && unknown.has(f.key))]
    .map((f) => String((f.detail as any)?.cap_id ?? '')));
  const found = [...pressure(inp, rules, active, unknown), ...outage(inp, rules), ...v16, ...runway(inp, rules, unknown), ...drift(inp, rules)];
  return { found, unknown: [...unknown] };
}
export const evaluate = (inp: GovInput): Finding[] => governor(inp).found;

/** The open findings index.ts re-raises unchanged for the rules this run could not compute (by check id or by key), within the
 *  scope's checks, unless this run raised that key afresh. Re-raised byte for byte, so an acknowledgement holds. */
export function carried(open: Finding[], fresh: Finding[], unknown: string[], scope: 'hourly' | 'daily'): Finding[] {
  const checks = GOV_CHECKS[scope], u = new Set(unknown), seen = new Set(fresh.map((f) => f.key));
  return open.filter((f) => checks.includes(f.check_id) && (u.has(f.check_id) || u.has(f.key)) && !seen.has(f.key));
}

// ── the Monday line ─────────────────────────────────────────────────────────────────────────────────────────────────
const usd2 = (v: number) => `USD ${v.toFixed(2)}`;
/** One plain sentence for the weekly Finance card: what the last seven days really cost, the two biggest features, what the test
 *  runs cost, and how far each cap is above its busiest day this week. daily-digest owns the call; nothing here reads a clock. */
export function usageWeekLine(usage: UsageDay[], budget: BudgetDay[], caps: ApiCaps, today: string): string {
  const recent = (d: string) => d > addDays(today, -7) && d <= today;
  // No rows at all is not a free week: say there is nothing to read yet rather than print USD 0.00.
  if (!usage.some((r) => recent(r.day))) return 'Model calls last 7 days: no usage data yet.';
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
