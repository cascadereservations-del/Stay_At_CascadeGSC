// s89: the payout-notice drain is wired after the hold job and skipped on ?dry=1. Stubs Deno.serve and fetch; no network.
let handler: (r: Request) => Response | Promise<Response>;
const realServe = Deno.serve;
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (h: typeof handler) => { handler = h; return { finished: Promise.resolve(), shutdown: () => Promise.resolve() }; };
Deno.env.set('SUPABASE_URL', 'http://127.0.0.1:9');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'service-role-test');
Deno.env.set('CASCADE_CRON_SHARED_SECRET', 'cascade-test-cron-secret');
await import('./index.ts');
// deno-lint-ignore no-explicit-any
(Deno as any).serve = realServe;

async function urlsFor(query: string): Promise<string[]> {
  const seen: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = ((i: Request | URL | string) => { seen.push(String(i instanceof Request ? i.url : i)); return Promise.resolve(new Response('{}', { status: 500, headers: { 'Content-Type': 'application/json' } })); }) as typeof fetch;
  try {
    await handler(new Request(`https://x.test/functions/v1/release-expired-holds${query}`, { method: 'POST', headers: { 'x-cascade-cron-secret': 'cascade-test-cron-secret' }, body: '{}' }));
  } finally { globalThis.fetch = realFetch; }
  return seen;
}

Deno.test('drain wiring: a real run reads the payout notices even when the hold job fails; a dry run never does', async () => {
  const real = await urlsFor('');
  const dry = await urlsFor('?dry=1');
  if (!real.some((u) => u.includes('staff_payout_change_notices'))) throw new Error('real run did not drain: ' + real.join(' '));
  if (dry.some((u) => u.includes('staff_payout_change_notices'))) throw new Error('dry run drained');
});
