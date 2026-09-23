// Session 46 (Lloyd: "for the fallback api key, can we use the openrouter key"), reordered by D-222 ("approve
// allocation"): an image read tries OpenRouter (CASCADE_OPENROUTER_BOT_KEY) first and falls back to Gemini, the same
// order providers.ts uses for text. VISION_PROVIDER names the primary; the default is openrouter.
import { assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';

Deno.env.set('CASCADE_GEMINI_BOT_KEY', 'test-gemini');
Deno.env.set('CASCADE_OPENROUTER_BOT_KEY', 'test-openrouter');
Deno.env.delete('VISION_PROVIDER');
const { visionExtractText, hasVisionKey, VISION_PROVIDER } = await import('./cascade-core/vision.ts');

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

Deno.test('vision: the default primary is OpenRouter', () => {
  assertEquals(VISION_PROVIDER, 'openrouter');
});

Deno.test('vision: OpenRouter answers, Gemini is never called', async () => {
  const hits: string[] = [];
  stub(200, 200, hits);
  try { assertEquals(await visionExtractText('p', 'aGk=', 'image/jpeg'), '{"from":"openrouter"}'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['openrouter']);
});

Deno.test('vision: OpenRouter refuses, the read falls back to Gemini', async () => {
  const hits: string[] = [];
  stub(200, 402, hits);
  try { assertEquals(await visionExtractText('p', 'aGk=', 'image/jpeg'), '{"from":"gemini"}'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['openrouter', 'gemini']);
});

Deno.test('vision: both refuse, the error is the fallback provider\'s', async () => {
  const hits: string[] = [];
  stub(402, 401, hits);
  try { await assertRejects(() => visionExtractText('p', 'aGk=', 'image/jpeg'), Error, 'gemini_402'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hasVisionKey(), true);
});
