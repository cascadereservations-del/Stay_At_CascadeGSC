// D-294: recordUsage writes one llm_usage row per model call, keeps the console line the call sites always printed,
// and can never break or slow the call it describes.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { recordUsage } from './usage.ts';

type Call = { url: string; init: RequestInit };
function harness(env: { url?: string; key?: string }, fetchImpl?: () => Promise<Response>) {
  const calls: Call[] = [], logs: string[] = [], warns: string[] = [];
  const real = { fetch: globalThis.fetch, log: console.log, warn: console.warn };
  for (const [k, v] of [['SUPABASE_URL', env.url], ['SUPABASE_SERVICE_ROLE_KEY', env.key]] as const) v ? Deno.env.set(k, v) : Deno.env.delete(k);
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return fetchImpl ? fetchImpl() : Promise.resolve(new Response(null, { status: 201 }));
  }) as typeof fetch;
  console.log = (...a: unknown[]) => { logs.push(a.join(' ')); };
  console.warn = (...a: unknown[]) => { warns.push(a.join(' ')); };
  const restore = () => { globalThis.fetch = real.fetch; console.log = real.log; console.warn = real.warn; Deno.env.delete('SUPABASE_URL'); Deno.env.delete('SUPABASE_SERVICE_ROLE_KEY'); };
  return { calls, logs, warns, restore };
}
const ENV = { url: 'https://x.supabase.co', key: 'service-key' };

Deno.test('usage: an ok call inserts one row and prints the llm_usage line in the old key order', () => {
  const h = harness(ENV);
  try {
    recordUsage({ provider: 'openrouter', model: 'google/gemini-2.5-flash', title: 'Cascade Cassy', tier: 'full', round: 1, input: 100, output: 20, cost_usd: 0.002 });
  } finally { h.restore(); }
  assertEquals(h.logs, ['llm_usage {"provider":"openrouter","model":"google/gemini-2.5-flash","title":"Cascade Cassy","tier":"full","round":1,"input":100,"output":20,"cost_usd":0.002}']);
  assertEquals(h.warns, []);
  assertEquals(h.calls.length, 1);
  assertEquals(h.calls[0].url, 'https://x.supabase.co/rest/v1/llm_usage');
  const hd = h.calls[0].init.headers as Record<string, string>;
  assertEquals([hd.apikey, hd.Authorization, hd['Content-Type'], hd.Prefer], ['service-key', 'Bearer service-key', 'application/json', 'return=minimal']);
  assert(h.calls[0].init.signal);
  assertEquals(JSON.parse(String(h.calls[0].init.body)), { title: 'Cascade Cassy', provider: 'openrouter', model: 'google/gemini-2.5-flash', tier: 'full', input: 100, output: 20, cost_usd: 0.002, ok: true, error: null, probe: false });
});

Deno.test('usage: a failed call prints llm_call_failed and inserts ok:false with the error cut to 200 chars', () => {
  const h = harness(ENV);
  try { recordUsage({ provider: 'omniroute', model: 'm', title: 'T', tier: 'vision-free', ok: false, error: 'x'.repeat(500), probe: true }); } finally { h.restore(); }
  assertEquals(h.logs, []);
  assertEquals(h.warns.length, 1);
  assert(h.warns[0].startsWith('llm_call_failed '));
  const body = JSON.parse(String(h.calls[0].init.body));
  assertEquals([body.ok, body.error.length, body.probe, body.input, body.cost_usd], [false, 200, true, null, null]);
});

Deno.test('usage: missing env means no fetch and no throw, but the log line still prints', () => {
  const h = harness({});
  try { recordUsage({ provider: 'gemini', model: 'g', title: 'T', input: 1, output: 2 }); } finally { h.restore(); }
  assertEquals(h.calls.length, 0);
  assertEquals(h.logs.length, 1);
  const h2 = harness({ url: ENV.url });
  try { recordUsage({ provider: 'gemini', input: 1 }); } finally { h2.restore(); }
  assertEquals(h2.calls.length, 0);
});

Deno.test('usage: a rejecting fetch never throws or leaves an unhandled rejection', async () => {
  const h = harness(ENV, () => Promise.reject(new Error('network down')));
  try { recordUsage({ provider: 'openrouter', model: 'm' }); await new Promise((r) => setTimeout(r, 5)); } finally { h.restore(); }
  assertEquals(h.calls.length, 1);
});

Deno.test('usage: a fetch that throws synchronously never throws out of recordUsage', () => {
  const h = harness(ENV);
  globalThis.fetch = (() => { throw new Error('boom'); }) as typeof fetch;
  try { recordUsage({ provider: 'openrouter', model: 'm' }); } finally { h.restore(); }
});

Deno.test('usage: non-finite and missing numbers are null, never 0', () => {
  const h = harness(ENV);
  try { recordUsage({ provider: 'gemini', input: Number.NaN, output: Infinity, cost_usd: undefined }); recordUsage({ provider: 'gemini', input: 0, output: null, cost_usd: 0 }); } finally { h.restore(); }
  const [a, b] = h.calls.map((c) => JSON.parse(String(c.init.body)));
  assertEquals([a.input, a.output, a.cost_usd], [null, null, null]);
  assertEquals([b.input, b.output, b.cost_usd], [0, null, 0]);
  assertEquals(a.title, 'Cascade');
});
