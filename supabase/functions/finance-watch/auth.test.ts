// s74 G8: the cron-secret gate on finance-watch. Stubs Deno.serve, imports the real index.ts and drives the captured handler.
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

const call = (headers: Record<string, string> = {}, secret: string | null = SECRET) => {
  if (secret === null) Deno.env.delete('CASCADE_CRON_SHARED_SECRET'); else Deno.env.set('CASCADE_CRON_SHARED_SECRET', secret);
  return Promise.resolve(handler(new Request('https://x.test/functions/v1/finance-watch', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: '{}' })));
};
function equal(a: unknown, b: unknown, m: string) { if (a !== b) throw new Error(`${m}: expected ${b}, got ${a}`); }

Deno.test('finance-watch: no header is 401', async () => { equal((await call()).status, 401, 'no header'); });
Deno.test('finance-watch: a wrong secret is 401', async () => { equal((await call({ 'x-cascade-cron-secret': 'nope' })).status, 401, 'wrong secret'); });
Deno.test('finance-watch: the public anon bearer is not a credential', async () => {
  equal((await call({ Authorization: 'Bearer eyJ.anon.public' })).status, 401, 'bearer only');
});
Deno.test('finance-watch: fails closed when CASCADE_CRON_SHARED_SECRET is unset, even with a header', async () => {
  equal((await call({ 'x-cascade-cron-secret': '' }, null)).status, 401, 'unset + empty header');
  equal((await call({ 'x-cascade-cron-secret': SECRET }, null)).status, 401, 'unset + header');
});
Deno.test('finance-watch: the right secret passes the gate (stops at the unset Finance chat, no network)', async () => {
  const r = await call({ 'x-cascade-cron-secret': SECRET });
  equal(r.status, 500, 'past the gate');
  equal((await r.json()).error, 'FINANCE_CHAT not configured', 'reached the chat check');
});
