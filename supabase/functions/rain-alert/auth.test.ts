// deno test --no-check --allow-all rain-alert/auth.test.ts
// s84 XS3: rain-alert answers 401 without the cron signature and runs with it. Frozen clock: the request is sent at the stubbed 03:00Z (Manila 11:00), no network is reached
// because the test stops at the operating-hours / dedup path with a fake client... here the 401 case never reaches anything; the 200 case only needs to get past the gate.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';

Deno.env.set('SUPABASE_URL', 'https://x.supabase.test');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'svc-key-test');
Deno.env.set('CASCADE_CRON_SHARED_SECRET', 'cron-secret-test');
let handler: (req: Request) => Promise<Response> = () => Promise.reject(new Error('not served'));
(Deno as unknown as { serve: unknown }).serve = (h: (req: Request) => Promise<Response>) => { handler = h; return { finished: Promise.resolve(), shutdown: () => Promise.resolve() }; };
await import('./index.ts');

const post = (h: Record<string, string> = {}) => new Request('https://x.test/rain-alert', { method: 'POST', headers: { 'Content-Type': 'application/json', ...h }, body: '{}' });

Deno.test('no header, the publishable key alone, or a wrong secret: 401 and nothing runs', async () => {
  for (const h of [{}, { Authorization: 'Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj' }, { 'x-cascade-cron-secret': 'wrong' }]) {
    const r = await handler(post(h));
    assertEquals(r.status, 401);
    assertEquals((await r.json()).error, 'unauthorized');
  }
});

Deno.test('a GET is still 405', async () => {
  assertEquals((await handler(new Request('https://x.test/rain-alert', { method: 'GET' }))).status, 405);
});

Deno.test('the cron secret, or the service-role bearer, gets past the gate (not a 401)', async () => {
  for (const h of [{ 'x-cascade-cron-secret': 'cron-secret-test' }, { Authorization: 'Bearer svc-key-test' }]) {
    const realFetch = globalThis.fetch;
    globalThis.fetch = (() => Promise.resolve(new Response('{}', { status: 500 }))) as typeof fetch;
    try {
      const r = await handler(post(h));
      await r.body?.cancel();
      assertEquals(r.status === 401, false);
    } finally { globalThis.fetch = realFetch; }
  }
});
