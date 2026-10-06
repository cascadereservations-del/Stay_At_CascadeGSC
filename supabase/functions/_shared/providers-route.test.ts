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
