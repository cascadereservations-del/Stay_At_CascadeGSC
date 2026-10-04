// deno test --no-check --allow-env supabase/functions/system-verifier/governor.test.ts
//
// The API governor (D-294): V14 cap pressure, V15 provider outage, V16 cap headroom, V17 credit runway, V18 cost drift.
// governor.ts is pure, so every rule is read here at its fire and no-fire edges, and the cards are read as text, because a
// finding that says the wrong thing at 07:45 is as useless as one that is never raised.
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { buildCards, redCard, yellowCard, type Finding } from './cards.ts';
import { readCredits, readKey } from './budget.ts';
import { addDays, evaluate, manilaClock, parseCaps, usageWeekLine, type ApiCaps, type BudgetDay, type GovInput, type UsageDay } from './governor.ts';

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
  assertEquals((f[0].detail as any).recommended, 1.5, 'a raise to 1.5 x the larger of spend and cap');
});

Deno.test('V14 reads yesterday too: at 07:45 today is only hours old', () => {
  const f = evaluate(input({ budget: [bud({ day: day(-1), spent_usd: 0.9 }), bud({ spent_usd: 0.02 })] }));
  assertEquals(keys(only(f, 'V14')), ['V14:openrouter-primary']);
});

Deno.test('V14 projects today to the end of the period, but only after 06:00 and from 0.05 USD', () => {
  const tiny: ApiCaps = { ...CAPS, caps: [{ ...CAPS.caps[0], cap: 0.1 }] };
  const run = (hour: number, spent: number) => only(evaluate(input({ caps: tiny, nowHourManila: hour, budget: [bud({ spent_usd: spent })] })), 'V14');
  assertEquals(run(5, 0.06).length, 0, 'before 06:00 the projection is skipped');
  assertEquals(run(12, 0.04).length, 0, 'under 0.05 USD there is nothing to project from');
  const f = run(12, 0.06); // 0.06 by noon is 0.12 by midnight, over a 0.10 cap, while only 60% used today
  assertEquals(f.length, 1);
  assertEquals((f[0].detail as any).projected, true);
  assertStringIncludes(redCard(f[0], NOW).text, 'on course to pass its daily limit');
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
  assertEquals((cf.detail as any).pct, 470, '0.5183 / 0.000011 = 47,118 neurons against 10,000');
  assertEquals((cf.detail as any).recommended, null, 'a fixed allowance has nothing to raise');
  // a Groq-only day uses no Cloudflare neurons at all
  const groq = evaluate(input({ usage: [use({ provider: 'omniroute', model: 'openai/gpt-oss-120b', input: 9_000_000, output: 9_000_000 })] }));
  assertEquals(only(groq, 'V14').length, 0);
});

Deno.test('V14 without a model column is an estimate and says so', () => {
  const f = only(evaluate(input({ usage: [use({ provider: 'omniroute', cost_usd: 0.4 })] })), 'V14');
  assert(f.length >= 1 && f.every((x) => (x.detail as any).approx === true));
  assertStringIncludes(redCard(f[0], NOW).text, 'estimate');
});

Deno.test('V14 detail is identical across small moves, so an acknowledgement holds', () => {
  const at = (remaining: number) => only(evaluate(input({ latest: { primary: { status: 200, limit: 1, remaining, usage: 1 } } })), 'V14')[0];
  assertEquals(JSON.stringify(at(0.19).detail), JSON.stringify(at(0.16).detail), '81% and 84% are the same 80% step');
  assert(JSON.stringify(at(0.19).detail) !== JSON.stringify(at(0.09).detail), 'a real change does reopen it');
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
  assertEquals((f[0].detail as any).fail_pct, 50);
  assertEquals((f[0].detail as any).calls_min, 5);
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
  assertEquals([d.direction, d.current, d.recommended, d.p95], ['lower', 1, 0.5, 0.02], '5 x 0.02 = 0.10, but the floor is 0.50');
  assertEquals(d.includes_tests, true, 'an OpenRouter key cannot split test runs out of its own spend');
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
  assertEquals([d.direction, d.current, d.recommended], ['raise', 1, 3], '5 x 0.60 = 3.00');
  assertEquals(f[0].severity, 'yellow', 'advice, not an alarm');
  assertEquals(f[0].key, 'V16:openrouter-primary', 'one key either way, so one acknowledgement covers both directions');
});

Deno.test('V16 leaves a fixed cap alone and measures usage caps without probe rows', () => {
  const quiet = Array.from({ length: 20 }, (_, i) => use({ day: day(-(i + 1)), provider: 'omniroute', model: 'openai/gpt-oss-20b', input: 1000, output: 1000 }));
  const probes = Array.from({ length: 20 }, (_, i) => use({ day: day(-(i + 1)), provider: 'omniroute', model: '@cf/meta/llama-3.3-70b-instruct-fp8-fast', input: 9_000_000, output: 9_000_000, probe: true }));
  const f = only(evaluate(input({ usage: [...quiet, ...probes] })), 'V16');
  assertEquals(keys(f), ['V16:omniroute-key'], 'the fixed Cloudflare allowance is never advised on');
  const d = f[0].detail as any;
  assertEquals([d.direction, d.recommended, d.includes_tests], ['lower', 0.1, false], 'test runs did not inflate the percentile, and the floor held');
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
  const d = f[0].detail as any;
  assertEquals([d.remaining, d.avg_day, d.days, d.source], [2, 0.2, 10, 'estimate']);
  assertEquals(run(2, 0.2).length, 0, '8 USD at 0.2 a day is 40 days: fine');
  assertEquals(run(9.5, 0.2)[0].severity, 'red', '0.5 USD at 0.2 a day is 2 days');
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
  assertEquals((f[0].detail as any).d7, 1.4);
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
  assertEquals(d.probe, true);
  assert(d.probe_share >= 80, `most of the title's spend is test runs: ${d.probe_share}`);
  assertStringIncludes(redCard({ ...f[0], severity: 'red' }, NOW).text, 'find the script or schedule that keeps running the test');
  const vision = only(evaluate(input({ usage: drifted({ tier: 'vision', input: 1000, output: 5000 }) })), 'V18')[0];
  assertEquals((vision.detail as any).reasoning, true);
  assertStringIncludes(yellowCard([vision], [], 'finance', NOW, '10 Oct')!.text, 'hidden thinking tokens dominate the cost');
});

// ── cards ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
Deno.test('a V16 card leads with what is wrong, then says the exact change and where', () => {
  const f = only(evaluate(input({ budget: history('primary', 20, 0.02) })), 'V16')[0];
  const t = yellowCard([f], [], 'finance', NOW, '10 Oct')!.text;
  const lines = t.split('\n').filter((l) => l.trim());
  assertStringIncludes(lines[1], 'OpenRouter key cascade-production allows USD 1.00 a day');
  assertStringIncludes(t, 'Do: set the OpenRouter key cascade-production limit from USD 1.00 to USD 0.50 at openrouter.ai > Settings > Keys > cascade-production > Credit limit.');
  assertStringIncludes(t, 'Busiest normal day (95th percentile over 14+ days): USD 0.02.');
  assertStringIncludes(t, 'Advice only');
  assertEquals(t.match(/^Do: /gm)?.length, 1);
});

Deno.test('a shared yellow card carries each governor change in its own bullet', () => {
  const fs = only(evaluate(input({ budget: [...history('primary', 20, 0.02), ...history('backup', 20, 0.02)] })), 'V16');
  assertEquals(fs.length, 2);
  const t = yellowCard(fs, [], 'finance', NOW, '10 Oct')!.text;
  assertStringIncludes(t, '2 things are worth a look.');
  assertStringIncludes(t, 'Set the OpenRouter key cascade-production limit from USD 1.00 to USD 0.50 at');
  assertStringIncludes(t, 'Set the OpenRouter backup key limit from USD 3.00 to USD 0.50 at');
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
  assertStringIncludes(c14, 'Do: set the OpenRouter key cascade-production limit from USD 1.00 to USD 1.50 at openrouter.ai > Settings > Keys > cascade-production > Credit limit');
  assertStringIncludes(c15, 'OmniRoute failed at least 100% of its Cascade Power Watch calls over the last two days (10+ calls).');
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
  assertStringIncludes(usageWeekLine([], [], CAPS, TODAY), 'USD 0.00 real spend');
});
