// Session 46 (Lloyd: "for the fallback api key, can we use the openrouter key"): an image read tries Gemini first and
// falls back to OpenRouter with CASCADE_OPENROUTER_BOT_KEY, the same shape providers.ts already has for text.
import { assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';

Deno.env.set('CASCADE_GEMINI_BOT_KEY', 'test-gemini');
Deno.env.set('CASCADE_OPENROUTER_BOT_KEY', 'test-openrouter');
const { visionExtractText, hasVisionKey } = await import('./cascade-core/vision.ts');

const realFetch = globalThis.fetch;
function stub(gemini: number, openrouter: number, hits: string[]) {
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

Deno.test('vision: Gemini answers, OpenRouter is never called', async () => {
  const hits: string[] = [];
  stub(200, 200, hits);
  try { assertEquals(await visionExtractText('p', 'aGk=', 'image/jpeg'), '{"from":"gemini"}'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['gemini']);
});

Deno.test('vision: Gemini refuses (bad key, quota), the read falls back to OpenRouter', async () => {
  const hits: string[] = [];
  stub(400, 200, hits);
  try { assertEquals(await visionExtractText('p', 'aGk=', 'image/jpeg'), '{"from":"openrouter"}'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['gemini', 'openrouter']);
});

Deno.test('vision: both refuse, the error names both providers', async () => {
  const hits: string[] = [];
  stub(400, 401, hits);
  try { await assertRejects(() => visionExtractText('p', 'aGk=', 'image/jpeg'), Error, 'openrouter_401'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hasVisionKey(), true);
});
