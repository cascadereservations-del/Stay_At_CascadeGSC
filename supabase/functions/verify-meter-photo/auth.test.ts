// s74 G8: the cron-secret gate on verify-meter-photo. Stubs Deno.serve, imports the real index.ts and drives the captured handler.
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
  return Promise.resolve(handler(new Request('https://x.test/functions/v1/verify-meter-photo', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: '{}' })));
};
function equal(a: unknown, b: unknown, m: string) { if (a !== b) throw new Error(`${m}: expected ${b}, got ${a}`); }

Deno.test('verify-meter-photo: no header is 401', async () => { equal((await call()).status, 401, 'no header'); });
Deno.test('verify-meter-photo: a wrong secret is 401', async () => { equal((await call({ 'x-cascade-cron-secret': 'nope' })).status, 401, 'wrong secret'); });
Deno.test('verify-meter-photo: the public anon bearer is not a credential', async () => {
  equal((await call({ Authorization: 'Bearer eyJ.anon.public' })).status, 401, 'bearer only');
});
Deno.test('verify-meter-photo: fails closed when CASCADE_CRON_SHARED_SECRET is unset, even with a header', async () => {
  equal((await call({ 'x-cascade-cron-secret': '' }, null)).status, 401, 'unset + empty header');
  equal((await call({ 'x-cascade-cron-secret': SECRET }, null)).status, 401, 'unset + header');
});
Deno.test('verify-meter-photo: the right secret passes the gate (the run then fails on the unreachable database, not 401)', async () => {
  const r = await call({ 'x-cascade-cron-secret': SECRET });
  equal(r.status === 401, false, 'not denied');
});
Deno.test('verify-meter-photo: a caller-chosen submission_id or property_id is refused without the secret', async () => {
  Deno.env.set('CASCADE_CRON_SHARED_SECRET', SECRET);
  const r = await handler(new Request('https://x.test/f', { method: 'POST', headers: { Authorization: 'Bearer eyJ.anon.public' }, body: JSON.stringify({ submission_id: 'x', property_id: 'y', notify: false }) }));
  equal(r.status, 401, 'refused before any lookup');
});

// s94: mode:'precheck' skips the cron secret but must carry a staff bearer; with none (or an unusable one) it is refused, never run.
Deno.test('verify-meter-photo: precheck without a bearer is 401 and never reaches the model', async () => {
  Deno.env.set('CASCADE_CRON_SHARED_SECRET', SECRET);
  Deno.env.set('SUPABASE_ANON_KEY', 'anon-test');
  const r = await handler(new Request('https://x.test/f', { method: 'POST', body: JSON.stringify({ mode: 'precheck', path: 'p', meter: 'electric' }) }));
  equal(r.status, 401, 'no bearer');
});
Deno.test('verify-meter-photo: precheck rejects a bad meter before auth work', async () => {
  const r = await handler(new Request('https://x.test/f', { method: 'POST', headers: { Authorization: 'Bearer x.y.z' }, body: JSON.stringify({ mode: 'precheck', path: 'p', meter: 'gas' }) }));
  equal(r.status, 400, 'invalid meter');
});
Deno.test('verify-meter-photo: the cron secret does not unlock a precheck, and a non-precheck body still needs it', async () => {
  const r = await handler(new Request('https://x.test/f', { method: 'POST', headers: { 'x-cascade-cron-secret': SECRET }, body: JSON.stringify({ mode: 'precheck', path: 'p', meter: 'water' }) }));
  equal(r.status, 401, 'secret alone is not a staff session');
});
