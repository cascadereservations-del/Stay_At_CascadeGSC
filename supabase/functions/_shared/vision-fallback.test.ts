// Session 46 (Lloyd: "for the fallback api key, can we use the openrouter key"), reordered by D-222 ("approve
// allocation"): an image read tries OpenRouter (CASCADE_OPENROUTER_BOT_KEY) first and falls back to Gemini only when VISION_GEMINI_FALLBACK=1 (s115), the same
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

Deno.test('vision: OpenRouter fails (500), default makes no Gemini call', async () => {
  const hits: string[] = [];
  stub(200, 500, hits);
  try { await assertRejects(() => visionExtractText('p', 'aGk=', 'image/jpeg'), Error, 'openrouter_500'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['openrouter']);
});

Deno.test('vision: VISION_GEMINI_FALLBACK=1 restores the Gemini fallback', async () => {
  const hits: string[] = [];
  stub(200, 500, hits);
  Deno.env.set('VISION_GEMINI_FALLBACK', '1');
  try { assertEquals(await visionExtractText('p', 'aGk=', 'image/jpeg'), '{"from":"gemini"}'); } finally { globalThis.fetch = realFetch; Deno.env.delete('VISION_GEMINI_FALLBACK'); }
  assertEquals(hits, ['openrouter', 'gemini']);
});

Deno.test('vision: a 402 throws credit_exhausted after exactly one call, even with the fallback on', async () => {
  for (const flag of [false, true]) {
    const hits: string[] = [];
    stub(200, 402, hits);
    if (flag) Deno.env.set('VISION_GEMINI_FALLBACK', '1');
    try { await assertRejects(() => visionExtractText('p', 'aGk=', 'image/jpeg'), Error, 'credit_exhausted:'); } finally { globalThis.fetch = realFetch; Deno.env.delete('VISION_GEMINI_FALLBACK'); }
    assertEquals(hits, ['openrouter']);
  }
});

Deno.test('vision: both refuse with the fallback on, the error is the last provider (gemini)', async () => {
  const hits: string[] = [];
  stub(500, 401, hits);
  Deno.env.set('VISION_GEMINI_FALLBACK', '1');
  try { await assertRejects(() => visionExtractText('p', 'aGk=', 'image/jpeg'), Error, 'gemini_500'); } finally { globalThis.fetch = realFetch; Deno.env.delete('VISION_GEMINI_FALLBACK'); }
  assertEquals(hits, ['openrouter', 'gemini']);
  assertEquals(hasVisionKey(), true);
});

// A Gemini-primary run needs its own module instance: VISION_PROVIDER is read at import. The query string makes a fresh one.
Deno.env.set('VISION_PROVIDER', 'gemini');
const g = await import('./cascade-core/vision.ts?gemini');
Deno.env.delete('VISION_PROVIDER');

Deno.test('vision: Gemini primary + Gemini 402 still falls through to OpenRouter', async () => {
  const hits: string[] = [];
  stub(402, 200, hits);
  try { assertEquals(await g.visionExtractText('p', 'aGk=', 'image/jpeg'), '{"from":"openrouter"}'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits, ['gemini', 'openrouter']);
});

Deno.test('vision: a 402 on the second call is labelled credit_exhausted too', async () => {
  const hits: string[] = [];
  stub(402, 500, hits);
  Deno.env.set('VISION_GEMINI_FALLBACK', '1');
  try { await assertRejects(() => visionExtractText('p', 'aGk=', 'image/jpeg'), Error, 'credit_exhausted:'); } finally { globalThis.fetch = realFetch; Deno.env.delete('VISION_GEMINI_FALLBACK'); }
  assertEquals(hits, ['openrouter', 'gemini']);
});
