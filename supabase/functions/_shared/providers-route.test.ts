// D-222 (Lloyd 2026-09-24, "approve allocation"): OpenRouter is the primary for text; Gemini is the fallback and is
// skipped while its breaker is open. A 402 (prepay empty) opens the breaker for hours, a 429 for 15 minutes.
import { assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';

Deno.env.set('CASCADE_GEMINI_BOT_KEY', 'test-gemini');
Deno.env.set('CASCADE_OPENROUTER_BOT_KEY', 'test-openrouter');
const { chatJson, chatTools, geminiBreaker } = await import('./cascade-core/providers.ts');

const realFetch = globalThis.fetch;
function stub(openrouter: number, gemini: number, hits: string[]) {
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url.includes('generativelanguage')) {
      hits.push('gemini');
      return Promise.resolve(new Response(JSON.stringify(gemini === 200 ? { candidates: [{ content: { parts: [{ text: '{"from":"gemini"}' }] } }] } : { error: 'x' }), { status: gemini }));
    }
    hits.push('openrouter');
    return Promise.resolve(new Response(JSON.stringify(openrouter === 200 ? { choices: [{ message: { content: '{"from":"openrouter"}' } }] } : { error: 'y' }), { status: openrouter }));
  }) as typeof fetch;
}
const q = { system: 's', history: [], question: 'q' };
const tq = { ...q, tools: [], run: () => Promise.resolve(null) };

Deno.test('text: OpenRouter answers first, Gemini is never called', async () => {
  const hits: string[] = []; geminiBreaker.until = 0; stub(200, 200, hits);
  try { assertEquals(await chatJson(q), '{"from":"openrouter"}'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['openrouter']);
});

Deno.test('text: OpenRouter fails, Gemini answers', async () => {
  const hits: string[] = []; geminiBreaker.until = 0; stub(500, 200, hits);
  try { assertEquals(await chatJson(q), '{"from":"gemini"}'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['openrouter', 'gemini']);
});

Deno.test('text: a Gemini 402 opens the breaker for hours, and Gemini is then skipped', async () => {
  const hits: string[] = []; geminiBreaker.until = 0; stub(500, 402, hits);
  const before = Date.now();
  try { await assertRejects(() => chatJson(q)); } finally { globalThis.fetch = realFetch; }
  assertEquals(geminiBreaker.until - before >= 5 * 3600_000, true, 'a 402 means no credit: skip Gemini for hours');
  const again: string[] = []; stub(500, 200, again);
  try { await assertRejects(() => chatJson(q), Error, 'openrouter_500'); } finally { globalThis.fetch = realFetch; }
  assertEquals(again, ['openrouter'], 'breaker open: Gemini is not called');
  geminiBreaker.until = 0;
});

Deno.test('text: a Gemini 429 opens the breaker for about 15 minutes', async () => {
  const hits: string[] = []; geminiBreaker.until = 0; stub(500, 429, hits);
  const before = Date.now();
  try { await assertRejects(() => chatJson(q)); } finally { globalThis.fetch = realFetch; }
  const span = geminiBreaker.until - before;
  assertEquals(span > 10 * 60_000 && span < 20 * 60_000, true);
  geminiBreaker.until = 0;
});

Deno.test('tools: OpenRouter first too', async () => {
  const hits: string[] = []; geminiBreaker.until = 0; stub(200, 200, hits);
  try { assertEquals((await chatTools(tq)).provider, 'openrouter'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['openrouter']);
});

Deno.test('text: a reply cut by max_tokens is never returned (live 2026-09-24: "...dito sa Gen")', async () => {
  geminiBreaker.until = Date.now() + 3600_000; // Gemini unavailable, so the truncation must surface as an error
  globalThis.fetch = (() => Promise.resolve(new Response(JSON.stringify({ choices: [{ finish_reason: 'length', message: { content: '{"reply":"Ben, yes po, legit dito sa Gen' } }], usage: { completion_tokens: 696 } }), { status: 200 }))) as typeof fetch;
  try { await assertRejects(() => chatJson(q), Error, 'openrouter_truncated'); } finally { globalThis.fetch = realFetch; geminiBreaker.until = 0; }
});

Deno.test('text: a truncated reply is recorded ok:true with <name>_truncated and its tokens, and still throws (D-294)', async () => {
  geminiBreaker.until = Date.now() + 3600_000;
  const logs: string[] = [], warns: string[] = [], real = { log: console.log, warn: console.warn };
  console.log = (...a: unknown[]) => { logs.push(a.join(' ')); };
  console.warn = (...a: unknown[]) => { warns.push(a.join(' ')); };
  globalThis.fetch = (() => Promise.resolve(new Response(JSON.stringify({ model: 'google/gemini-2.5-flash', choices: [{ finish_reason: 'length', message: { content: '{"reply":"cut' } }], usage: { prompt_tokens: 50, completion_tokens: 700, completion_tokens_details: { reasoning_tokens: 650 }, cost: 0.002 } }), { status: 200 }))) as typeof fetch;
  try { await assertRejects(() => chatJson(q), Error, 'openrouter_truncated'); } finally { globalThis.fetch = realFetch; geminiBreaker.until = 0; console.log = real.log; console.warn = real.warn; }
  const line = logs.find((l) => l.startsWith('llm_usage '));
  assertEquals(JSON.parse(line!.slice('llm_usage '.length)), { provider: 'openrouter', model: 'google/gemini-2.5-flash', tier: 'full', input: 50, output: 700, cost_usd: 0.002, error: 'openrouter_truncated' });
  assertEquals(warns.some((w) => w.startsWith('llm_call_failed')), false, 'not an outage row');
  assertEquals(warns.some((w) => w.startsWith('llm_truncated') && w.includes('"reasoning":650')), true, 'the alarm names the hidden reasoning tokens');
});

Deno.test('tools: a round cut by max_tokens throws openrouter_truncated instead of returning an empty answer (SPEC-43)', async () => {
  geminiBreaker.until = Date.now() + 3600_000;
  const warn = console.warn; console.warn = () => {};
  globalThis.fetch = (() => Promise.resolve(new Response(JSON.stringify({ choices: [{ finish_reason: 'length', message: { content: '' } }], usage: { completion_tokens: 1000, completion_tokens_details: { reasoning_tokens: 990 } } }), { status: 200 }))) as typeof fetch;
  try { await assertRejects(() => chatTools(tq), Error, 'openrouter_truncated'); } finally { globalThis.fetch = realFetch; geminiBreaker.until = 0; console.warn = warn; }
});

// SPEC-43: OpenRouter retires gemini-2.5-* on 2026-10-20; Gemini 3 spends max_tokens on hidden reasoning (696/700 live, 2026-09-24).
const bodies: Array<Record<string, any>> = [];
function capture() {
  bodies.length = 0;
  globalThis.fetch = ((_u: string | URL | Request, init?: RequestInit) => {
    bodies.push(JSON.parse(String(init?.body)));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: '{"ok":1}' } }] }), { status: 200 }));
  }) as typeof fetch;
}

Deno.test('SPEC-43 chat: full and lite send the Gemini 3 id, reasoning minimal and +300 max_tokens', async () => {
  geminiBreaker.until = 0;
  try {
    capture(); await chatJson(q); const full = bodies[0];
    capture(); await chatJson({ ...q, tier: 'lite' }); const lite = bodies[0];
    capture(); await chatJson({ ...q, maxTokens: 500 }); const explicit = bodies[0];
    assertEquals(full.models[0], 'google/gemini-3.6-flash');
    assertEquals(lite.models[0], 'google/gemini-3.1-flash-lite');
    for (const b of [full, lite]) { assertEquals(b.reasoning, { effort: 'minimal' }); assertEquals(b.max_tokens, 1000); }
    assertEquals(explicit.max_tokens, 800, 'a caller-set maxTokens gets the headroom too');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('SPEC-43 tools: the full tier carries reasoning and headroom, the deep tier (Anthropic) neither', async () => {
  try {
    capture(); await chatTools(tq); const full = bodies[0];
    capture(); await chatTools({ ...tq, tier: 'deep', maxTokens: 500 }); const deep = bodies[0];
    assertEquals(full.model, 'google/gemini-3.6-flash');
    assertEquals(full.reasoning, { effort: 'minimal' });
    assertEquals(full.max_tokens, 1000);
    assertEquals(deep.model, 'anthropic/claude-sonnet-5');
    assertEquals('reasoning' in deep, false);
    assertEquals(deep.max_tokens, 500);
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('SPEC-43: providers.ts names no retired gemini-2.5 model', async () => {
  assertEquals((await Deno.readTextFile(new URL('./cascade-core/providers.ts', import.meta.url))).includes('gemini-2.5'), false);
});

// S74 cache: OpenRouter reports prompt tokens served from the provider's cache in usage.prompt_tokens_details.cached_tokens.
const usageStub = (usage: Record<string, unknown>) => { globalThis.fetch = (() => Promise.resolve(new Response(JSON.stringify({ model: 'google/gemini-3.6-flash', choices: [{ finish_reason: 'stop', message: { content: '{"ok":1}' } }], usage }), { status: 200 }))) as typeof fetch; };
const usageLines = async (run: () => Promise<unknown>) => {
  const logs: string[] = [], real = console.log;
  console.log = (...a: unknown[]) => { logs.push(a.join(' ')); };
  try { await run(); } finally { console.log = real; globalThis.fetch = realFetch; }
  return logs.filter((l) => l.startsWith('llm_usage ')).map((l) => JSON.parse(l.slice('llm_usage '.length)));
};

Deno.test('S74 cache: cached prompt tokens ride on the llm_usage line, chat and tools paths', async () => {
  geminiBreaker.until = 0;
  const u = { prompt_tokens: 6211, completion_tokens: 80, cost: 0.0012, prompt_tokens_details: { cached_tokens: 5120, cache_write_tokens: 0 } };
  usageStub(u); const chat = await usageLines(() => chatJson(q));
  usageStub(u); const tools = await usageLines(() => chatTools(tq));
  for (const l of [...chat, ...tools]) { assertEquals(l.input, 6211); assertEquals(l.cached, 5120); assertEquals(l.cost_usd, 0.0012); }
  assertEquals(chat.length + tools.length, 2);
  usageStub({ prompt_tokens: 100, completion_tokens: 5 }); // a provider that reports no cache detail: the field is absent, never 0
  assertEquals('cached' in (await usageLines(() => chatJson(q)))[0], false);
});

Deno.test('S74 cache: a probe sums cost, cached and prompt tokens of its own calls', async () => {
  geminiBreaker.until = 0;
  const { probeScope, probeTotals } = await import('./cascade-core/providers.ts');
  usageStub({ prompt_tokens: 1000, completion_tokens: 10, cost: 0.01, prompt_tokens_details: { cached_tokens: 800 } });
  const totals = await probeScope(async () => { await usageLines(async () => { await chatJson(q); await chatJson(q); }); return { ...probeTotals() }; });
  assertEquals(totals, { cost_usd: 0.02, cached: 1600, input: 2000 });
});

Deno.test('S74 probes: overlapping probe contexts - one ending first never takes the other key or its probe tag', async () => {
  geminiBreaker.until = 0;
  const { probeScope, setProviderKey } = await import('./cascade-core/providers.ts');
  Deno.env.set('SUPABASE_URL', 'https://usage.test'); Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'svc');
  const seen: string[] = [];
  globalThis.fetch = ((u: string | URL | Request, init?: RequestInit) => {
    const url = String(u);
    if (url.includes('/rest/v1/llm_usage')) seen.push(`probe:${JSON.parse(String(init?.body)).probe}`);
    else seen.push(String((init?.headers as Record<string, string>).Authorization));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: '{"ok":1}' } }] }), { status: 200 }));
  }) as typeof fetch;
  let release!: () => void; const gate = new Promise<void>((r) => { release = r; });
  const run = async (key: string, wait: Promise<void> | null) => {
    await probeScope(async () => { setProviderKey(key); await chatJson(q); await wait; seen.push(`${key}:second`); await chatJson(q); setProviderKey(null); });
  };
  try {
    const b = run('keyB', gate), a = run('keyA', null);
    await a; release(); await b;
    await chatJson(q); // a guest turn outside every probe context
  } finally { globalThis.fetch = realFetch; Deno.env.delete('SUPABASE_URL'); Deno.env.delete('SUPABASE_SERVICE_ROLE_KEY'); }
  const after = seen.slice(seen.indexOf('keyB:second') + 1);
  assertEquals(after.slice(0, 2).sort(), ['Bearer keyB', 'probe:true'], 'the later call of B still spends its probe key and is tagged probe');
  assertEquals(after.slice(2), ['Bearer test-openrouter', 'probe:false'], 'a guest turn spends the guest key and is not a probe');
});
