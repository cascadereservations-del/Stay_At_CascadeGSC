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
