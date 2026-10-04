// deno test --no-check --allow-env supabase/functions/system-verifier/governor.test.ts
//
// The API governor (D-294): V14 cap pressure, V15 provider outage, V16 cap headroom, V17 credit runway, V18 cost drift.
// governor.ts is pure, so every rule is read here at its fire and no-fire edges, and the cards are read as text, because a
// finding that says the wrong thing at 07:45 is as useless as one that is never raised.
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { buildCards, redCard, yellowCard, type Finding } from './cards.ts';
import { readCredits, readKey } from './budget.ts';
import { addDays, carried, DEFAULT_RULES, evaluate, GOV_CHECKS, governor, manilaClock, parseCaps, recommend, usageWeekLine, type ApiCaps, type BudgetDay, type GovInput, type UsageDay } from './governor.ts';

// The seed lane A writes to app_settings 'api_caps'.
const CAPS = parseCaps({
  caps: [
    { id: 'openrouter-primary', label: 'OpenRouter key cascade-production', kind: 'usd_day', cap: 1, floor: 0.5, key_name: 'primary', where: 'openrouter.ai > Settings > Keys > cascade-production > Credit limit' },
    { id: 'openrouter-backup', label: 'OpenRouter backup key', kind: 'usd_day', cap: 3, floor: 0.5, key_name: 'backup', where: 'openrouter.ai > Settings > Keys > backup key > Credit limit' },
    { id: 'omniroute-key', label: "OmniRoute key 'cascade omniroute'", kind: 'usd_day_notional', cap: 0.5, floor: 0.1, provider: 'omniroute', where: 'OmniRoute dashboard > API Manager > cascade omniroute > Daily limit' },
    { id: 'cloudflare-free', label: 'Cloudflare Workers AI free allowance', kind: 'neurons_day', cap: 10000, fixed: true, provider: 'omniroute', where: "fixed by Cloudflare's free plan" },
  ],
  credit: { openrouter_usd: 10 },
  prices_usd_per_m: {
    '@cf/meta/llama-4-scout-17b-16e-instruct': [0.27, 0.85],
    '@cf/meta/llama-3.3-70b-instruct-fp8-fast': [0.293, 2.253],
    'openai/gpt-oss-120b': [0, 0], 'openai/gpt-oss-20b': [0, 0],
  },
  neuron_usd: 0.000011,
  rules: { pressure_pct: 70, headroom_x: 20, target_x: 5, runway_days: 30, drift_x: 2, outage_fail_pct: 50, outage_min_calls: 5 },
})!;

const TODAY = '2026-10-10';
const NOW = new Date('2026-10-10T02:00:00Z');
const day = (n: number) => addDays(TODAY, n);

const use = (over: Partial<UsageDay> = {}): UsageDay =>
  ({ day: TODAY, provider: 'openrouter', title: 'Concierge reply', tier: 'text', probe: false, calls: 10, fails: 0, input: 0, output: 0, cost_usd: 0, ...over });
const bud = (over: Partial<BudgetDay> = {}): BudgetDay =>
  ({ day: TODAY, key_name: 'primary', limit_usd: 1, min_remaining_usd: 1, spent_usd: 0, snapshots: 24, ...over });
const input = (over: Partial<GovInput> = {}): GovInput =>
  ({ usage: [], budget: [], latest: {}, caps: CAPS, today: TODAY, nowHourManila: 7.75, ...over });
/** One budget row a day for the n days before today, all at the same spend. */
const history = (key: string, n: number, spent: number): BudgetDay[] =>
  Array.from({ length: n }, (_, i) => bud({ day: day(-(i + 1)), key_name: key, spent_usd: spent }));
const keys = (fs: Finding[]) => fs.map((f) => f.key).sort();
const only = (fs: Finding[], id: string) => fs.filter((f) => f.check_id === id);

// ── readKey and readCredits ───────────────────────────────────────────────────────────────────────────────────────────
async function withFetch<T>(reply: Response | null, fn: () => Promise<T>): Promise<T> {
  const real = globalThis.fetch;
  globalThis.fetch = (() => Promise.resolve(reply as Response)) as typeof fetch;
  try { return await fn(); } finally { globalThis.fetch = real; }
}
const jsonRes = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

Deno.test('readKey returns the key lifetime usage, null-safe', async () => {
  const k = await withFetch(jsonRes({ data: { limit: 1, limit_remaining: 0.4, usage: 12.34 } }), () => readKey('k'));
  assertEquals(k, { status: 200, limit: 1, remaining: 0.4, usage: 12.34 });
  const none = await withFetch(jsonRes({ data: { limit: 1, limit_remaining: 0.4 } }), () => readKey('k'));
  assertEquals(none.usage, null, 'a missing usage field is null, not 0');
  const bad = await withFetch(jsonRes({ data: { usage: 'lots' } }), () => readKey('k'));
  assertEquals(bad.usage, null);
  const down = await withFetch(jsonRes({}, 503), () => readKey('k'));
  assertEquals(down, { status: 503, limit: null, remaining: null, usage: null });
});

Deno.test('readCredits is total minus used, and null for a refused key', async () => {
  assertEquals(await withFetch(jsonRes({ data: { total_credits: 25, total_usage: 7.5 } }), () => readCredits('k')), { status: 200, remaining: 17.5 });
  assertEquals(await withFetch(jsonRes({ error: 'management key required' }, 403), () => readCredits('k')), { status: 403, remaining: null });
  assertEquals((await withFetch(jsonRes({ data: { total_credits: 'x' } }), () => readCredits('k'))).remaining, null);
});

Deno.test('manilaClock and parseCaps', () => {
  assertEquals(manilaClock(new Date('2026-10-09T23:45:00Z')), { today: '2026-10-10', hour: 7.75 });
  assertEquals(manilaClock(new Date('2026-10-10T16:30:00Z')).today, '2026-10-11', 'Manila is already tomorrow at 16:30 UTC');
  assertEquals(parseCaps(null), null);
  assertEquals(parseCaps({ caps: 'nope' }), null);
  assertEquals(parseCaps({ caps: [{ id: 'x', label: 'X', kind: 'bogus', cap: 1 }, { id: 'y', label: 'Y', kind: 'usd_day', cap: 0 }] })!.caps.length, 0, 'a cap that cannot be measured is dropped');
});

// ── V14 cap pressure ───────────────────────────────────────────────────────────────────────────────────────────────────
Deno.test('V14 fires at 70% of a key cap, on the live read, and not at 60%', () => {
  const at = (remaining: number) => only(evaluate(input({ latest: { primary: { status: 200, limit: 1, remaining, usage: 5 } } })), 'V14');
  assertEquals(at(0.4).length, 0, '60% is under the line');
  const f = at(0.3);
  assertEquals(f.length, 1, 'exactly 70% fires');
  assertEquals(f[0].key, 'V14:openrouter-primary');
  assertEquals(f[0].severity, 'red');
  assertEquals((f[0].detail as any).pct, 70);
  assertEquals((f[0].detail as any).recommended, 3.5, 'recommend(): 5 x the 0.70 spent this period');
  assertEquals((f[0].detail as any).cap, 1, 'measured against the limit the key reported');
});

Deno.test('V14 and V16 measure an OpenRouter key against its LIVE limit; api_caps.cap is only the fallback', () => {
  // api_caps says 1, the key really allows 2: 1.5 used is 75% of the live limit.
  const f = only(evaluate(input({ latest: { primary: { status: 200, limit: 2, remaining: 0.5, usage: 5 } } })), 'V14');
  assertEquals((f[0].detail as any).cap, 2);
  assertEquals((f[0].detail as any).pct, 70);
  // V16: 20 quiet days. A live limit already at the advised 0.50 says nothing (the change is made, even with api_caps stale).
  const quiet = history('primary', 20, 0.02);
  assertEquals(only(evaluate(input({ budget: quiet, latest: { primary: { status: 200, limit: 0.5, remaining: 0.5, usage: 1 } } })), 'V16').length, 0);
  const v = only(evaluate(input({ budget: quiet, latest: { primary: { status: 200, limit: 4, remaining: 4, usage: 1 } } })), 'V16');
  assertEquals((v[0].detail as any).recommended, 0.5, 'the live 4.00 is far above need');
  // A raise that the live limit already equals is not repeated either.
  const busy = history('primary', 20, 0.6);
  assertEquals(only(evaluate(input({ budget: busy, latest: { primary: { status: 200, limit: 3, remaining: 3, usage: 1 } } })), 'V16').length, 0);
});

Deno.test('V14 for a key never sums Manila-day spend: only the live read of the current OpenRouter period', () => {
  const f = evaluate(input({ budget: [bud({ day: day(-1), spent_usd: 0.9 }), bud({ spent_usd: 0.9 })], latest: { primary: { status: 200, limit: 1, remaining: 0.9, usage: 1 } } }));
  assertEquals(only(f, 'V14').length, 0, 'yesterday and today in Manila straddle two periods; the key says 10% used');
});

Deno.test('V14 projects a key over the hours since 00:00 UTC (08:00 Manila), after 6 hours and from 0.05 USD', () => {
  const run = (hour: number, remaining: number) => only(evaluate(input({ nowHourManila: hour, latest: { primary: { status: 200, limit: 1, remaining, usage: 1 } } })), 'V14');
  assertEquals(run(13, 0.6).length, 0, '5 hours into the period: too early to project');
  assertEquals(run(14, 0.75).length, 0, '0.25 in 6 hours is 1.00 by the reset: not over');
  const f = run(14, 0.7); // 0.30 in 6 hours is 1.20 by the reset, while only 30% is used
  assertEquals(f.length, 1);
  assertEquals((f[0].detail as any).projected, true);
  assertEquals('pct' in (f[0].detail as any), false, 'a projection carries no percent that would move');
  assertStringIncludes(redCard(f[0], NOW).text, 'on course to pass its daily limit');
  // A provider cap projects over the Manila day instead, and says it is an estimate.
  const tiny: ApiCaps = { ...CAPS, caps: [{ ...CAPS.caps[2], cap: 0.1 }] };
  const omni = (hour: number) => only(evaluate(input({ caps: tiny, nowHourManila: hour, usage: [use({ provider: 'omniroute', model: '@cf/meta/llama-4-scout-17b-16e-instruct', input: 100_000, output: 40_000 })] })), 'V14');
  assertEquals(omni(5).length, 0, 'before 06:00 Manila the projection is skipped');
  const g = omni(12); // 0.061 by noon is 0.12 by midnight, over 0.10
  assertEquals([(g[0].detail as any).projected, (g[0].detail as any).estimate], [true, true]);
  assertStringIncludes(redCard(g[0], NOW).text, 'so it is an estimate');
});

Deno.test('V14 prices OmniRoute usage at list price and counts Cloudflare neurons from the @cf/ models only', () => {
  const rows = [
    use({ provider: 'omniroute', model: '@cf/meta/llama-3.3-70b-instruct-fp8-fast', input: 1_000_000, output: 100_000 }), // 0.293 + 0.2253 = 0.5183 USD
    use({ provider: 'omniroute', model: 'openai/gpt-oss-120b', input: 9_000_000, output: 9_000_000 }), // priced at 0
  ];
  const f = evaluate(input({ usage: rows }));
  const omni = only(f, 'V14').find((x) => x.key === 'V14:omniroute-key')!;
  assertEquals((omni.detail as any).pct, 100, '0.5183 of 0.50 is 103%, shown in 10% steps');
  const cf = only(f, 'V14').find((x) => x.key === 'V14:cloudflare-free')!;
  assertEquals((cf.detail as any).unit, 'neurons');
  assertEquals((cf.detail as any).pct, 100, '0.5183 / 0.000011 = 47,118 neurons against 10,000: the top band');
  assertEquals((cf.detail as any).recommended, null, 'a fixed allowance has nothing to raise');
  // a Groq-only day uses no Cloudflare neurons at all
  const groq = evaluate(input({ usage: [use({ provider: 'omniroute', model: 'openai/gpt-oss-120b', input: 9_000_000, output: 9_000_000 })] }));
  assertEquals(only(groq, 'V14').length, 0);
});

Deno.test('V14 prices a model it has no list price for at the mean Cloudflare price, approx, never as free', () => {
  const f = only(evaluate(input({ usage: [use({ provider: 'omniroute', cost_usd: 0.4 })] })), 'V14');
  assert(f.length >= 1 && f.every((x) => (x.detail as any).approx === true));
  assertStringIncludes(redCard(f[0], NOW).text, 'estimate');
  // A served model missing from prices_usd_per_m: 2M in + 0.2M out at the mean @cf price (0.2815, 1.5515) = 0.87 USD.
  const g = only(evaluate(input({ usage: [use({ provider: 'omniroute', model: '@cf/qwen/new-model', input: 2_000_000, output: 200_000 })] })), 'V14')
    .find((x) => x.key === 'V14:omniroute-key')!;
  assertEquals([(g.detail as any).approx, (g.detail as any).pct], [true, 100]);
  // A failed call with no tokens costs nothing and is not an estimate.
  const fail = only(evaluate(input({ usage: [use({ provider: 'omniroute', model: null, calls: 3, fails: 3 })] })), 'V14');
  assertEquals(fail.length, 0);
});

Deno.test('V14 detail is identical across small moves, so an acknowledgement holds', () => {
  const at = (remaining: number, open: Finding[] = []) => only(evaluate(input({ open, latest: { primary: { status: 200, limit: 1, remaining, usage: 1 } } })), 'V14')[0];
  const first = at(0.29);
  // 71% then 84%: the same 70-89 band, and the value 4.20 is within 25% of the 3.55 already on the card, so it holds.
  assertEquals(JSON.stringify(at(0.16, [first]).detail), JSON.stringify(first.detail), '71% and 84% are the same 70-89 band');
  assertEquals((at(0.16).detail as any).recommended, 4.2, 'without the open card the value is computed afresh');
  assert(JSON.stringify(at(0.09, [first]).detail) !== JSON.stringify(first.detail), 'crossing into 90-99 does reopen it');
  assertEquals((at(0.0, [first]).detail as any).recommended, 5, '5.00 is 41% above 3.55: re-issued');
});

// ── V15 provider outage ───────────────────────────────────────────────────────────────────────────────────────────────
Deno.test('V15 fires at 50% failing with at least 5 calls, per provider and feature', () => {
  const run = (calls: number, fails: number, over: Partial<UsageDay> = {}) =>
    only(evaluate(input({ usage: [use({ provider: 'omniroute', title: 'Cascade Power Watch', calls, fails, ...over })] })), 'V15');
  assertEquals(run(4, 4).length, 0, 'under 5 calls is noise');
  assertEquals(run(6, 2).length, 0, 'a third failing is not an outage');
  const f = run(6, 3);
  assertEquals(f.length, 1, 'exactly 50% fires');
  assertEquals(f[0].key, 'V15:omniroute:Cascade Power Watch');
  assertEquals(f[0].severity, 'red');
  assertEquals(f[0].detail, { provider: 'omniroute', title: 'Cascade Power Watch', fail_band: '50-74' }, 'a band and no call count');
  assertEquals((run(10, 8)[0].detail as any).fail_band, '75-100');
});

Deno.test('V15 ignores probe rows and rows older than yesterday, and sums today with yesterday', () => {
  assertEquals(only(evaluate(input({ usage: [use({ provider: 'omniroute', calls: 20, fails: 20, probe: true })] })), 'V15').length, 0, 'a failing probe is our test, not a guest');
  assertEquals(only(evaluate(input({ usage: [use({ day: day(-2), calls: 20, fails: 20 })] })), 'V15').length, 0, 'two days ago is history');
  const f = only(evaluate(input({ usage: [use({ calls: 3, fails: 2 }), use({ day: day(-1), calls: 3, fails: 2 })] })), 'V15');
  assertEquals(f.length, 1, '2 of 3 each day is 4 of 6 together');
});

Deno.test('V15 still counts a free provider that fails while a paid one answers', () => {
  // The same feature, two providers: the free rung fails every time, the paid rung succeeds every time.
  const f = evaluate(input({ usage: [
    use({ provider: 'omniroute', title: 'Concierge reply', calls: 8, fails: 8 }),
    use({ provider: 'openrouter', title: 'Concierge reply', calls: 8, fails: 0 }),
  ] }));
  assertEquals(keys(only(f, 'V15')), ['V15:omniroute:Concierge reply']);
});

// ── V16 cap headroom ───────────────────────────────────────────────────────────────────────────────────────────────────
Deno.test('V16 needs 14 days of data before it speaks', () => {
  const run = (n: number) => only(evaluate(input({ budget: [...history('primary', n, 0.02), bud({ spent_usd: 0.02 })] })), 'V16');
  assertEquals(run(13).length, 0, '13 days is not enough');
  assertEquals(run(14).length, 1, '14 days is');
});

Deno.test('V16 recommends a lower cap, never below the floor', () => {
  const f = only(evaluate(input({ budget: history('primary', 20, 0.02) })), 'V16');
  assertEquals(f.length, 1);
  assertEquals(f[0].key, 'V16:openrouter-primary');
  assertEquals(f[0].severity, 'yellow');
  const d = f[0].detail as any;
  assertEquals([d.direction, d.recommended], ['lower', 0.5], '5 x 0.02 = 0.10, but the floor is 0.50');
  assertEquals(d.reads_live, true, 'an OpenRouter key: its own spend, test runs included');
  assertEquals(Object.keys(d).sort(), ['cap_id', 'direction', 'label', 'reads_live', 'recommended', 'unit', 'where'], 'no p95, no days, no current');
  // with a quiet key and a high floor-free cap the 5 x p95 figure wins
  const open: ApiCaps = { ...CAPS, caps: [{ ...CAPS.caps[0], cap: 5, floor: 0.1 }] };
  const g = only(evaluate(input({ caps: open, budget: history('primary', 20, 0.1) })), 'V16')[0].detail as any;
  assertEquals(g.recommended, 0.5, '5 x 0.10 = 0.50 clears the floor');
});

Deno.test('V16 does not fire when the cap is under 20x the busiest day, and says raise when need is half the cap', () => {
  assertEquals(only(evaluate(input({ budget: history('primary', 20, 0.06) })), 'V16').length, 0, '1.00 is 16.7x 0.06');
  const f = only(evaluate(input({ budget: history('primary', 20, 0.6) })), 'V16');
  assertEquals(f.length, 1);
  const d = f[0].detail as any;
  assertEquals([d.direction, d.recommended], ['raise', 3], '5 x 0.60 = 3.00');
  assertEquals(f[0].severity, 'yellow', 'advice, not an alarm');
  assertEquals(f[0].key, 'V16:openrouter-primary', 'one key either way, so one acknowledgement covers both directions');
});

Deno.test('V16 leaves a fixed cap alone and measures usage caps without probe rows', () => {
  const quiet = Array.from({ length: 20 }, (_, i) => use({ day: day(-(i + 1)), provider: 'omniroute', model: 'openai/gpt-oss-20b', input: 1000, output: 1000 }));
  const probes = Array.from({ length: 20 }, (_, i) => use({ day: day(-(i + 1)), provider: 'omniroute', model: '@cf/meta/llama-3.3-70b-instruct-fp8-fast', input: 9_000_000, output: 9_000_000, probe: true }));
  const f = only(evaluate(input({ usage: [...quiet, ...probes] })), 'V16');
  assertEquals(keys(f), ['V16:omniroute-key'], 'the fixed Cloudflare allowance is never advised on');
  const d = f[0].detail as any;
  assertEquals([d.direction, d.recommended, d.reads_live], ['lower', 0.1, false], 'test runs did not inflate the percentile, and the floor held');
});

// ── V17 credit runway ──────────────────────────────────────────────────────────────────────────────────────────────────
Deno.test('V17 estimates credit from the stored total minus both keys lifetime usage', () => {
  const run = (used: number, per: number, extra: Partial<GovInput> = {}) => only(evaluate(input({
    latest: { primary: { status: 200, limit: 1, remaining: 1, usage: used }, backup: { status: 200, limit: 3, remaining: 3, usage: 0 } },
    budget: history('primary', 5, per), ...extra,
  })), 'V17');
  const f = run(8, 0.2); // 2 USD left at 0.2 a day = 10 days
  assertEquals(f.length, 1);
  assertEquals(f[0].severity, 'yellow');
  assertEquals(f[0].detail, { days: '7-13', source: 'estimate', topup: 20 }, 'a days band, no remaining and no average');
  assertEquals(run(2, 0.2).length, 0, '8 USD at 0.2 a day is 40 days: fine');
  assertEquals(run(9.5, 0.2)[0].severity, 'red', '0.5 USD at 0.2 a day is 2 days');
  assertEquals((run(6, 0.2)[0].detail as any).days, '14-29', '4 USD at 0.2 a day is 20 days');
  assertEquals(run(8, 0.2, { budget: history('primary', 2, 0.2) }).length, 0, 'two recorded days are not a mean');
  assertEquals(run(8, 0).length, 0, 'no spend means no runway problem');
});

Deno.test('V17 prefers the real credit when OpenRouter will say', () => {
  const f = only(evaluate(input({
    latest: { primary: { status: 200, limit: 1, remaining: 1, usage: 8 } }, budget: history('primary', 5, 0.2), credits: { remaining: 50 },
  })), 'V17');
  assertEquals(f.length, 0, 'the estimate said 10 days; the real figure says 250');
  const low = only(evaluate(input({ budget: history('primary', 5, 0.2), credits: { remaining: 1 } })), 'V17')[0];
  assertEquals((low.detail as any).source, 'openrouter');
  assertEquals(low.severity, 'red');
  assertEquals(only(evaluate(input({ budget: history('primary', 5, 0.2) })), 'V17').length, 0, 'no usage and no real credit: nothing to say');
});

// ── V18 cost drift ─────────────────────────────────────────────────────────────────────────────────────────────────────
const drifted = (over: Partial<UsageDay> = {}, calm = 0.01, hot = 0.2, n = 20) =>
  Array.from({ length: n }, (_, i) => use({ title: 'Receipt read', day: day(-(n - 1) + i), cost_usd: i >= n - 7 ? hot : calm, ...over }));

Deno.test('V18 fires when a feature costs twice its own norm, with a 0.10 USD floor and 14 days of history', () => {
  const f = only(evaluate(input({ usage: drifted() })), 'V18');
  assertEquals(f.length, 1);
  assertEquals(f[0].key, 'V18:Receipt read');
  assertEquals(f[0].severity, 'yellow');
  assertEquals(f[0].detail, { title: 'Receipt read', probe: false, direction: 'up', x: 2, cause: null }, 'no amounts');
  assertEquals(only(evaluate(input({ usage: drifted({}, 0.01, 0.2, 13) })), 'V18').length, 0, 'under 14 days every feature looks new');
  assertEquals(only(evaluate(input({ usage: drifted({}, 0.001, 0.01) })), 'V18').length, 0, '0.07 USD is under the 0.10 floor');
  assertEquals(only(evaluate(input({ usage: drifted({}, 0.05, 0.06) })), 'V18').length, 0, 'a steady feature is not drifting');
});

Deno.test('V18 keeps test runs apart and explains the likely cause', () => {
  const real = drifted({}, 0.01, 0.01); // steady
  const tests = drifted({ probe: true }, 0.01, 0.4);
  const f = only(evaluate(input({ usage: [...real, ...tests] })), 'V18');
  assertEquals(keys(f), ['V18:Receipt read:test'], 'only the test runs drifted');
  const d = f[0].detail as any;
  assertEquals([d.probe, d.cause], [true, 'test_runs']);
  assertStringIncludes(redCard({ ...f[0], severity: 'red' }, NOW).text, 'find the script or schedule that keeps running the test');
  const vision = only(evaluate(input({ usage: drifted({ tier: 'vision', input: 1000, output: 5000 }) })), 'V18')[0];
  assertEquals((vision.detail as any).cause, 'reasoning');
  assertStringIncludes(yellowCard([vision], [], 'finance', NOW, '10 Oct')!.text, 'hidden thinking tokens dominate the cost');
});

// ── cards ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
Deno.test('a V16 card leads with what is wrong, then says the exact change and where', () => {
  const f = only(evaluate(input({ budget: history('primary', 20, 0.02) })), 'V16')[0];
  const t = yellowCard([f], [], 'finance', NOW, '10 Oct')!.text;
  const lines = t.split('\n').filter((l) => l.trim());
  assertStringIncludes(lines[1], 'OpenRouter key cascade-production allows far more a day than its busiest normal day needs.');
  assertStringIncludes(t, 'Do: set the OpenRouter key cascade-production limit to USD 0.50 at openrouter.ai > Settings > Keys > cascade-production > Credit limit, then also set "cap" for openrouter-primary to 0.5 in Supabase app_settings, key api_caps, so the fallback matches.');
  assert(!/USD 0\.02|95th/.test(t), 'no evidence number: the card is built from the hashed detail');
  assertStringIncludes(t, 'Advice only');
  assertEquals(t.match(/^Do: /gm)?.length, 1);
});

Deno.test('a shared yellow card carries each governor change in its own bullet', () => {
  const fs = only(evaluate(input({ budget: [...history('primary', 20, 0.02), ...history('backup', 20, 0.02)] })), 'V16');
  assertEquals(fs.length, 2);
  const t = yellowCard(fs, [], 'finance', NOW, '10 Oct')!.text;
  assertStringIncludes(t, '2 things are worth a look.');
  assertStringIncludes(t, 'Set the OpenRouter key cascade-production limit to USD 0.50 at');
  assertStringIncludes(t, 'Set the OpenRouter backup key limit to USD 0.50 at');
  assertStringIncludes(t, 'Do: make each change named above, in the order listed.');
});

Deno.test('V14, V15 and V17 are red cards with one Do, the exact value, and no shouting', () => {
  const v14 = only(evaluate(input({ latest: { primary: { status: 200, limit: 1, remaining: 0.1, usage: 1 } } })), 'V14')[0];
  const v15 = only(evaluate(input({ usage: [use({ provider: 'omniroute', title: 'Cascade Power Watch', calls: 12, fails: 12 })] })), 'V15')[0];
  const v17 = only(evaluate(input({ budget: history('primary', 5, 0.2), credits: { remaining: 1 } })), 'V17')[0];
  const cards = buildCards({ new: [v14, v15, v17], remind: [], resolved: [] }, NOW, '10 Oct');
  assertEquals(cards.length, 3, 'three reds are three cards');
  const [c14, c15, c17] = cards.map((c) => c.text);
  assertStringIncludes(c14, 'has used at least 90% of its daily limit of USD 1.00');
  assertStringIncludes(c14, 'Do: set the OpenRouter key cascade-production limit from USD 1.00 to USD 4.50 at openrouter.ai > Settings > Keys > cascade-production > Credit limit (or find what is calling it so much), then also set "cap" for openrouter-primary to 4.5 in Supabase app_settings, key api_caps');
  assertStringIncludes(c15, 'OmniRoute failed 75-100% of its Cascade Power Watch calls over the last two days.');
  assertStringIncludes(c15, 'Do: check OmniRoute on the alfred host');
  assertStringIncludes(c17, 'Guest replies stop when it runs out.');
  assertStringIncludes(c17, 'Do: top up about USD 20.00 at openrouter.ai > Settings > Credits');
  for (const c of cards) {
    assertEquals(c.text.match(/^Do: /gm)?.length, 1, c.text);
    assert(!/[a-z]!/i.test(c.text) && !/\b(URGENT|ASAP|IMMEDIATELY)\b/.test(c.text), `a governor card shouted: ${c.text}`);
    assert(c.ackKey, 'every governor red can be acknowledged');
  }
});

Deno.test('a fixed allowance says it cannot be raised', () => {
  const f = only(evaluate(input({ usage: [use({ provider: 'omniroute', model: '@cf/meta/llama-3.3-70b-instruct-fp8-fast', input: 1_000_000, output: 100_000 })] })), 'V14')
    .find((x) => x.key === 'V14:cloudflare-free')!;
  const t = redCard(f, NOW).text;
  assertStringIncludes(t, 'Do: cut the calls behind it, because the limit cannot be raised');
  assertStringIncludes(t, 'neurons');
});

// ── the Monday line ────────────────────────────────────────────────────────────────────────────────────────────────────
Deno.test('usageWeekLine is one plain sentence: real spend, top two features, test runs, and headroom as Nx', () => {
  const usage = [
    use({ title: 'Concierge reply', cost_usd: 0.2 }), use({ title: 'Receipt read', cost_usd: 0.1 }), use({ title: 'Power Watch', cost_usd: 0.03 }),
    use({ title: 'Receipt read', cost_usd: 0.08, probe: true }),
    use({ day: day(-30), title: 'Concierge reply', cost_usd: 9 }), // far outside the week
  ];
  const line = usageWeekLine(usage, [bud({ spent_usd: 0.25 })], CAPS, TODAY);
  assertStringIncludes(line, 'USD 0.33 real spend, mostly Concierge reply (USD 0.20) and Receipt read (USD 0.10)');
  assertStringIncludes(line, 'test runs USD 0.08');
  assertStringIncludes(line, 'OpenRouter key cascade-production 4x');
  assert(!line.includes('\n'), 'one line');
  assertEquals(usageWeekLine([], [], CAPS, TODAY), 'Model calls last 7 days: no usage data yet.', 'no rows is not a free week');
  assertEquals(usageWeekLine([use({ day: day(-20), cost_usd: 1 })], [], CAPS, TODAY), 'Model calls last 7 days: no usage data yet.');
});

// ── audit 2026-10-04: ack stability across days, unknown inputs, one value per cap, scopes ─────────────────────────────
/** A world on Manila day `t` (an offset from TODAY) where every number drifts a little each day. */
function world(t: number, open: Finding[] = []): GovInput {
  const today = day(t);
  const budget: BudgetDay[] = [], usage: UsageDay[] = [];
  for (let i = -40; i <= t; i++) {
    const d = day(i), g = i + 40; // g grows by one a day
    budget.push(bud({ day: d, key_name: 'primary', spent_usd: 0.02 + 0.0002 * g }));
    budget.push(bud({ day: d, key_name: 'backup', spent_usd: 1.6 + 0.02 * g }));
    // OmniRoute on Cloudflare Llama 3.3 every day, a little more each day: V16 raise and V14 on the Cloudflare allowance.
    usage.push(use({ day: d, provider: 'omniroute', title: 'Cascade Power Watch', model: '@cf/meta/llama-3.3-70b-instruct-fp8-fast', input: 500_000 + 1000 * g, output: 50_000, calls: 20, fails: 0 }));
    // Receipt reads: calm, then hot from a week before TODAY onwards.
    usage.push(use({ day: d, title: 'Receipt read', cost_usd: i > -7 ? 0.2 + 0.002 * g : 0.01 }));
  }
  // The free rung failing for guests today and yesterday, a few more fails each day.
  for (const i of [t - 1, t]) usage.push(use({ day: day(i), provider: 'omniroute', title: 'Concierge reply', calls: 10, fails: 8 + (i > 0 ? 1 : 0) }));
  return {
    usage, budget, caps: CAPS, today, nowHourManila: 7.75, open,
    latest: {
      primary: { status: 200, limit: 1, remaining: 0.25 - 0.02 * t, usage: 3 + 0.03 * t },
      backup: { status: 200, limit: 3, remaining: 2, usage: 4 + 1.7 * t },
    },
    credits: { remaining: 40 - 2 * t },
  };
}
const canon = (fs: Finding[]) => JSON.stringify([...fs].sort((a, b) => a.key.localeCompare(b.key)));

Deno.test('two consecutive days of slowly changing data raise byte-identical findings, so every [Known] holds', () => {
  const d1 = evaluate(world(0));
  assertEquals(new Set(d1.map((f) => f.check_id)), new Set(['V14', 'V15', 'V16', 'V17', 'V18']), `every rule fires: ${keys(d1)}`);
  const d2 = evaluate(world(1, d1));
  assertEquals(canon(d2), canon(d1));
  assert(canon(evaluate(world(1))) !== canon(d1), 'without the open cards the drift WOULD move a value: the test bites');
  const d3 = evaluate(world(2, d2));
  assertEquals(canon(d3), canon(d1), 'and the day after');
});

Deno.test('a failed key read makes its rules unknown (carried forward), never resolved and never recomputed', () => {
  const g = governor(input({ budget: history('primary', 20, 0.02), latest: { primary: { status: 503, limit: null, remaining: null, usage: null } } }));
  assertEquals(g.found.filter((f) => f.key.endsWith('openrouter-primary')), []);
  assertEquals(g.unknown.sort(), ['V14:openrouter-primary', 'V16:openrouter-primary', 'V17']);
  // V17 with one of two keys failing does not compute a runway even when the real credit is known.
  const v17 = governor(input({ budget: history('primary', 5, 0.2), credits: { remaining: 1 }, latest: { primary: { status: 200, limit: 1, remaining: 1, usage: 1 }, backup: { status: 0, limit: null, remaining: null, usage: null } } }));
  assertEquals([only(v17.found, 'V17').length, v17.unknown.includes('V17')], [0, true]);
  // A key that is not configured at all is not unknown: there is nothing to measure.
  assertEquals(governor(input()).unknown, []);
});

Deno.test('a day with no successful snapshot is null: left out of p95, and a missing yesterday is unknown', () => {
  const nulls = Array.from({ length: 5 }, (_, i) => bud({ day: day(-(i + 14)), spent_usd: null }));
  const known13 = history('primary', 13, 0.02);
  assertEquals(only(evaluate(input({ budget: [...known13, ...nulls] })), 'V16').length, 0, '13 known days and 5 null ones are not 18 days of data');
  const gap = history('primary', 20, 0.02).map((b) => (b.day === day(-1) ? { ...b, spent_usd: null } : b));
  const g = governor(input({ budget: gap }));
  assertEquals([only(g.found, 'V16').length, g.unknown], [0, ['V16:openrouter-primary']]);
  // V17: a day where one existing key has no known spend is left out of the mean, never read as 0.
  const both = [...history('primary', 5, 0.2), ...history('backup', 5, 0.2).map((b, i) => (i < 2 ? { ...b, spent_usd: null } : b))];
  const r = only(evaluate(input({ budget: both, credits: { remaining: 5 } })), 'V17')[0];
  assertEquals((r.detail as any).days, '7-13', '5 USD at 0.40 a day is 12.5 days; counting the backup gaps as nothing (0.20 days) would stretch it to 15.6');
});

Deno.test('carried() re-raises open findings of unknown rules in the scope, unless raised afresh', () => {
  const f = (key: string): Finding => ({ key, check_id: key.split(':')[0], severity: 'red', title: key, detail: { k: key } });
  const open = [f('V14:openrouter-primary'), f('V14:omniroute-key'), f('V15:omniroute:Concierge reply'), f('V16:openrouter-primary'), f('V17:openrouter-credit')];
  assertEquals(carried(open, [], ['V14:openrouter-primary', 'V16:openrouter-primary', 'V17'], 'daily').map((x) => x.key),
    ['V14:openrouter-primary', 'V16:openrouter-primary', 'V17:openrouter-credit'], 'per rule: the omniroute V14 and V15 were computed');
  assertEquals(carried(open, [], ['V14:openrouter-primary', 'V16:openrouter-primary', 'V17'], 'hourly').map((x) => x.key), ['V14:openrouter-primary'], 'hourly carries only V14-V15');
  assertEquals(carried(open, [f('V17:openrouter-credit')], ['V17'], 'daily'), [], 'a fresh finding wins');
  assertEquals(carried(open, [], GOV_CHECKS.hourly, 'hourly').length, 3, 'the whole governor down: every hourly finding');
});

Deno.test('one value per cap: V14 defers to an active V16, and otherwise says recommend() for the same cap', () => {
  // Busy normal days (V16 says raise) and today at 80% of the live limit: V14 states pressure only.
  const both = evaluate(input({ budget: history('primary', 20, 0.6), latest: { primary: { status: 200, limit: 1, remaining: 0.2, usage: 1 } } }));
  const v14 = only(both, 'V14')[0].detail as any, v16 = only(both, 'V16')[0].detail as any;
  assertEquals([v14.recommended, v14.advice, v16.recommended], [null, 'V16', 3], 'one number on the cards, and it is V16 that says it');
  const c14 = redCard(only(both, 'V14')[0], NOW).text;
  assertStringIncludes(c14, 'the value to set is in the limit advice on the system check card');
  assertEquals(c14.match(/USD \d/g)?.length, 1, 'only the current limit is printed');
  const alone = only(evaluate(input({ latest: { primary: { status: 200, limit: 1, remaining: 0.2, usage: 1 } } })), 'V14')[0].detail as any;
  assertEquals(alone.recommended, recommend(CAPS.caps[0], 0.8, DEFAULT_RULES), 'no V16 advice: V14 names recommend() itself');
});

Deno.test('V16 re-issues its value only when it moves 25% or more', () => {
  const open: ApiCaps = { ...CAPS, caps: [{ ...CAPS.caps[0], cap: 10, floor: 0.1 }] };
  const run = (spent: number, prev: Finding[] = []) => only(evaluate(input({ caps: open, budget: history('primary', 20, spent), open: prev })), 'V16')[0];
  const a = run(0.1); // 5 x 0.10 = 0.50
  assertEquals((a.detail as any).recommended, 0.5);
  assertEquals((run(0.11, [a]).detail as any).recommended, 0.5, '0.55 is 10% away: the card holds');
  assertEquals((run(0.14, [a]).detail as any).recommended, 0.7, '0.70 is 40% away: re-issued');
});

Deno.test('V17 at 7-9 days is a yellow that says one to two weeks', () => {
  const f = only(evaluate(input({ budget: history('primary', 5, 0.2), credits: { remaining: 1.7 } })), 'V17')[0]; // 8.5 days
  assertEquals([f.severity, (f.detail as any).days], ['yellow', '7-13']);
  const t = yellowCard([f], [], 'finance', NOW, '10 Oct')!.text;
  assertStringIncludes(t, 'The OpenRouter credit lasts one to two weeks at the recent rate of spend.');
  assert(!/about \d+ days|Guest replies stop/.test(t), t);
});

Deno.test('the governor scopes: hourly V14-V15, daily V14-V18', () => {
  assertEquals(GOV_CHECKS, { hourly: ['V14', 'V15'], daily: ['V14', 'V15', 'V16', 'V17', 'V18'] });
});

Deno.test('index.ts runs the governor in both scopes, carries forward per rule for 2 days, and beats api-governor', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, "const checks = GOV_CHECKS[scope as 'hourly' | 'daily'];");
  assertStringIncludes(src, 'const fresh = (g?.found ?? []).filter((f) => checks.includes(f.check_id));');
  assertStringIncludes(src, "const keep = carried(open ?? [], fresh, g ? g.unknown : checks, scope as 'hourly' | 'daily');");
  assertStringIncludes(src, 'const CARRY_MS = 2 * 86_400_000;');
  assertStringIncludes(src, "if (scope === 'daily' && !dry && open && g && !g.unknown.length) await heartbeat(db, 'api-governor')('succeeded');");
});
