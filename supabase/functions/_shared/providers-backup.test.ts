// 2026-09-30 (Lloyd: "create 2nd openrouter key and set up omni route also for cascade"; never Alfred's OmniRoute): with the
// Gemini prepay empty, the text path tries the guests' OpenRouter key, then a second Cascade OpenRouter key, then Cascade's
// own OmniRoute gateway, then Gemini. Each rung is skipped while its secret is unset; probes never spend the backups.
import { assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';

Deno.env.set('CASCADE_GEMINI_BOT_KEY', 'test-gemini');
Deno.env.set('CASCADE_OPENROUTER_BOT_KEY', 'or-main');
const { chatJson, geminiBreaker, setProviderKey } = await import('./cascade-core/providers.ts');

const realFetch = globalThis.fetch;
type Hit = { to: string; auth: string; body: Record<string, unknown> };
/** status per endpoint: 'or-main' / 'or-backup' by Authorization, 'omni' by URL, 'gemini' by URL. */
function stub(status: Record<string, number>, hits: Hit[]) {
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    const auth = String((init?.headers as Record<string, string> | undefined)?.Authorization ?? '').replace('Bearer ', '');
    const to = url.includes('generativelanguage') ? 'gemini' : url.includes('omni.test') ? 'omni' : auth;
    hits.push({ to, auth, body: init?.body ? JSON.parse(String(init.body)) : {} });
    const s = status[to] ?? 500;
    const ok = to === 'gemini' ? { candidates: [{ content: { parts: [{ text: '{"from":"gemini"}' }] } }] } : { choices: [{ message: { content: `{"from":"${to}"}` } }] };
    return new Response(JSON.stringify(s === 200 ? ok : { error: 'x' }), { status: s });
  }) as typeof fetch;
}
const q = { system: 's', history: [], question: 'q' };
const withEnv = (on: boolean) => {
  if (on) { Deno.env.set('CASCADE_OPENROUTER_BACKUP_KEY', 'or-backup'); Deno.env.set('CASCADE_OMNIROUTE_URL', 'https://omni.test/v1'); Deno.env.set('CASCADE_OMNIROUTE_KEY', 'omni-key'); Deno.env.set('CASCADE_OMNIROUTE_MODEL', 'cascade-guest'); }
  else for (const k of ['CASCADE_OPENROUTER_BACKUP_KEY', 'CASCADE_OMNIROUTE_URL', 'CASCADE_OMNIROUTE_KEY', 'CASCADE_OMNIROUTE_MODEL']) Deno.env.delete(k);
};

Deno.test('the guests key hits its daily cap: the second OpenRouter key answers', async () => {
  withEnv(true); geminiBreaker.until = 0; const hits: Hit[] = []; stub({ 'or-main': 403, 'or-backup': 200 }, hits);
  try { assertEquals(await chatJson(q), '{"from":"or-backup"}'); } finally { globalThis.fetch = realFetch; withEnv(false); }
  assertEquals(hits.map((h) => h.to), ['or-main', 'or-backup']);
});

Deno.test('both OpenRouter keys fail: Cascade OmniRoute answers, on its own model name', async () => {
  withEnv(true); geminiBreaker.until = 0; const hits: Hit[] = []; stub({ 'or-main': 402, 'or-backup': 403, omni: 200 }, hits);
  try { assertEquals(await chatJson(q), '{"from":"omni"}'); } finally { globalThis.fetch = realFetch; withEnv(false); }
  assertEquals(hits.map((h) => h.to), ['or-main', 'or-backup', 'omni']);
  assertEquals([hits[2].auth, hits[2].body.model], ['omni-key', 'cascade-guest']);
});

Deno.test('everything before it fails: Gemini is still the last rung while its breaker is closed', async () => {
  withEnv(true); geminiBreaker.until = 0; const hits: Hit[] = []; stub({ gemini: 200 }, hits);
  try { assertEquals(await chatJson(q), '{"from":"gemini"}'); } finally { globalThis.fetch = realFetch; withEnv(false); }
  assertEquals(hits.map((h) => h.to), ['or-main', 'or-backup', 'omni', 'gemini']);
});

Deno.test('unset secrets are skipped: the old behaviour exactly (OpenRouter, then Gemini)', async () => {
  withEnv(false); geminiBreaker.until = 0; const hits: Hit[] = []; stub({ gemini: 200 }, hits);
  try { assertEquals(await chatJson(q), '{"from":"gemini"}'); } finally { globalThis.fetch = realFetch; }
  assertEquals(hits.map((h) => h.to), ['or-main', 'gemini']);
});

Deno.test('a probe or golden run never spends the backup key or OmniRoute', async () => {
  withEnv(true); geminiBreaker.until = Date.now() + 3_600_000; const hits: Hit[] = []; stub({}, hits);
  setProviderKey('probe-key');
  try { await assertRejects(() => chatJson(q), Error, 'openrouter_500'); } finally { setProviderKey(null); globalThis.fetch = realFetch; withEnv(false); geminiBreaker.until = 0; }
  assertEquals(hits.map((h) => h.to), ['probe-key']);
});

Deno.test('routine work tries the free combo first and stops there when it answers', async () => {
  withEnv(true); geminiBreaker.until = 0; const hits: Hit[] = []; stub({ omni: 200 }, hits);
  try { assertEquals(await chatJson({ ...q, tier: 'routine' }), '{"from":"omni"}'); } finally { globalThis.fetch = realFetch; withEnv(false); }
  assertEquals(hits.map((h) => [h.to, h.body.model]), [['omni', 'cascade-routine']]);
});

Deno.test('the free combo fails: routine work falls through to the paid chain on the lite model', async () => {
  withEnv(true); geminiBreaker.until = 0; const hits: Hit[] = []; let n = 0;
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input); const body = JSON.parse(String(init?.body ?? '{}'));
    const to = url.includes('omni.test') ? 'omni' : 'or-main'; hits.push({ to, auth: '', body });
    return n++ === 0 ? new Response('{"error":"x"}', { status: 429 }) : new Response(JSON.stringify({ choices: [{ message: { content: '{"from":"or-main"}' } }] }), { status: 200 });
  }) as typeof fetch;
  try { assertEquals(await chatJson({ ...q, tier: 'routine' }), '{"from":"or-main"}'); } finally { globalThis.fetch = realFetch; withEnv(false); }
  assertEquals(hits.map((h) => h.to), ['omni', 'or-main']);
  assertEquals((hits[1].body.models as string[])[0].includes('lite'), true, 'the paid fallback uses the lite model');
});

Deno.test('guest work never touches the free combo; a probe skips it even for routine work', async () => {
  withEnv(true); geminiBreaker.until = 0; const hits: Hit[] = []; stub({ 'or-main': 200, 'probe-key': 200 }, hits);
  try {
    assertEquals(await chatJson(q), '{"from":"or-main"}');
    setProviderKey('probe-key');
    assertEquals(await chatJson({ ...q, tier: 'routine' }), '{"from":"probe-key"}');
  } finally { setProviderKey(null); globalThis.fetch = realFetch; withEnv(false); }
  assertEquals(hits.map((h) => h.to), ['or-main', 'probe-key']);
});

Deno.test('an empty or unreadable free reply is a failure: the paid chain answers; the free try gets room to reason', async () => {
  for (const bad of ['', 'not json at all']) {
    withEnv(true); geminiBreaker.until = 0; const hits: Hit[] = [];
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input instanceof Request ? input.url : input); const body = JSON.parse(String(init?.body ?? '{}'));
      const to = url.includes('omni.test') ? 'omni' : 'or-main'; hits.push({ to, auth: '', body });
      const content = to === 'omni' ? bad : '{"from":"or-main"}';
      return new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
    }) as typeof fetch;
    try { assertEquals(await chatJson({ ...q, tier: 'routine', maxTokens: 20 }), '{"from":"or-main"}'); } finally { globalThis.fetch = realFetch; withEnv(false); }
    assertEquals(hits.map((h) => h.to), ['omni', 'or-main']);
    assertEquals([hits[0].body.max_tokens, hits[1].body.max_tokens], [1200, 20]);
  }
});
