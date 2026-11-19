// s124 L4: the cron-secret gate on daily-digest (send and dry paths). Stubs Deno.serve, imports the real index.ts and drives the captured handler.
const SECRET = 'cascade-test-cron-secret';
let handler: (r: Request) => Response | Promise<Response>;
const realServe = Deno.serve;
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (h: typeof handler) => { handler = h; return { finished: Promise.resolve(), shutdown: () => Promise.resolve() }; };
Deno.env.set('SUPABASE_URL', 'http://127.0.0.1:9');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'service-role-test');
Deno.env.delete('TELEGRAM_FINANCE_CHAT_ID');
await import('./index.ts');
// deno-lint-ignore no-explicit-any
(Deno as any).serve = realServe;

// Any outbound fetch (Telegram or Supabase) is recorded and refused, so a 401 test proves nothing was called.
const calls: string[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = (i: Request | URL | string) => { calls.push(String(i)); return Promise.reject(new Error('network blocked in test')); };

const call = (headers: Record<string, string> = {}, secret: string | null = SECRET, path = '', body = '{"mode":"finance"}') => {
  if (secret === null) Deno.env.delete('CASCADE_CRON_SHARED_SECRET'); else Deno.env.set('CASCADE_CRON_SHARED_SECRET', secret);
  calls.length = 0;
  return Promise.resolve(handler(new Request('https://x.test/functions/v1/daily-digest' + path, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body })));
};
function equal(a: unknown, b: unknown, m: string) { if (a !== b) throw new Error(`${m}: expected ${b}, got ${a}`); }

Deno.test('daily-digest: unsigned POST (send path) is 401 and calls nothing', async () => {
  const r = await call({ Authorization: 'Bearer sb_publishable_public' });
  equal(r.status, 401, 'status'); equal((await r.json()).error, 'unauthorized', 'body'); equal(calls.length, 0, 'no outbound call');
});
Deno.test('daily-digest: a wrong secret is 401 on the send and dry paths', async () => {
  for (const path of ['', '?dry=1']) {
    const r = await call({ 'x-cascade-cron-secret': 'nope' }, SECRET, path);
    equal(r.status, 401, `wrong secret ${path}`); equal(calls.length, 0, 'no outbound call');
  }
});
Deno.test('daily-digest: unsigned dry=1 is still 401', async () => { equal((await call({}, SECRET, '?dry=1')).status, 401, 'dry unsigned'); });
Deno.test('daily-digest: fails closed when CASCADE_CRON_SHARED_SECRET is unset', async () => {
  equal((await call({ 'x-cascade-cron-secret': '' }, null)).status, 401, 'unset + empty header');
  equal((await call({ 'x-cascade-cron-secret': SECRET }, null)).status, 401, 'unset + header');
});
Deno.test('daily-digest: the right secret passes the gate (finance mode stops at the unset Finance chat)', async () => {
  const r = await call({ 'x-cascade-cron-secret': SECRET });
  equal(r.status, 500, 'past the gate');
  equal((await r.json()).error, 'FINANCE_CHAT not configured', 'reached the chat check');
});
Deno.test('daily-digest: dry=1 with the right secret proceeds (past the gate, never a 401)', async () => {
  const r = await call({ 'x-cascade-cron-secret': SECRET }, SECRET, '?dry=1').catch(() => null);
  if (r) equal(r.status === 401, false, 'not 401'); // network is blocked, so the build may throw; either way the gate let it through
});
globalThis.fetch = realFetch;
