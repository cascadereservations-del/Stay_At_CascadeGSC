// deno test --no-check -A messenger-concierge/inbox-push.test.ts
// Lane XS (s82): the Inbox push call is fire-and-forget. It names the exact function and body keys, sends no guest text, returns before the network
// answers, and nothing it does can throw into the guest path. Frozen clock: none is read here.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { fireInboxPush, type InboxPushDeps } from './inbox-push.ts';

const H = '3f2a9c1e-7b6d-4e0a-8c55-0d1e2f3a4b5c';
function deps(o: Partial<InboxPushDeps> = {}) {
  const seen: Array<{ url: string; init: RequestInit }> = [], logs: string[] = [], waits: Array<Promise<unknown>> = [];
  const d: InboxPushDeps = {
    base: 'https://x.supabase.test', key: 'service-key',
    fetch: ((url: string, init: RequestInit) => { seen.push({ url, init }); return Promise.resolve(new Response('{}', { status: 200 })); }) as typeof fetch,
    waitUntil: (p) => { waits.push(p); }, log: (m) => logs.push(m), ...o,
  };
  return { d, seen, logs, waits };
}

Deno.test('a handover names the function, the caller and exactly kind, psid, handoff_id', async () => {
  const { d, seen, waits } = deps();
  fireInboxPush('handover', '1234567890', H, d);
  await Promise.all(waits);
  assertEquals(seen.length, 1);
  assertEquals(seen[0].url, 'https://x.supabase.test/functions/v1/notify-staff-inbox');
  assertEquals(seen[0].init.method, 'POST');
  assertEquals((seen[0].init.headers as Record<string, string>).Authorization, 'Bearer service-key');
  assertEquals(JSON.parse(String(seen[0].init.body)), { kind: 'handover', psid: '1234567890', handoff_id: H });
});

Deno.test('a guest-wrote call carries only kind and psid: no name, no message text', async () => {
  const { d, seen, waits } = deps();
  fireInboxPush('guest_wrote', '1234567890', null, d);
  await Promise.all(waits);
  assertEquals(Object.keys(JSON.parse(String(seen[0].init.body))), ['kind', 'psid']);
});

Deno.test('it returns before the network answers (the guest path never waits)', async () => {
  let release!: (r: Response) => void;
  const { d, waits } = deps({ fetch: (() => new Promise<Response>((res) => { release = res; })) as typeof fetch });
  const t = fireInboxPush('guest_wrote', '1', null, d);
  assertEquals(t, undefined);
  assertEquals(waits.length, 1);
  await new Promise((r) => setTimeout(r, 0));
  release(new Response('{}'));
});

Deno.test('every failure is swallowed: fetch rejects, fetch throws, non-200, a throwing logger, no waitUntil', async () => {
  const a = deps({ fetch: (() => Promise.reject(new Error('down'))) as typeof fetch });
  fireInboxPush('guest_wrote', '1', null, a.d);
  await Promise.all(a.waits);
  assert(a.logs[0].startsWith('inbox_push_failed'), a.logs[0]);
  const b = deps({ fetch: (() => { throw new Error('sync'); }) as typeof fetch });
  fireInboxPush('guest_wrote', '1', null, b.d);
  await Promise.all(b.waits);
  assert(b.logs[0].startsWith('inbox_push_failed'));
  const c = deps({ fetch: (() => Promise.resolve(new Response('no', { status: 502 }))) as typeof fetch });
  fireInboxPush('guest_wrote', '1', null, c.d);
  await Promise.all(c.waits);
  assertEquals(c.logs, ['inbox_push_502']);
  const e = deps({ log: () => { throw new Error('log'); }, fetch: (() => Promise.reject(new Error('x'))) as typeof fetch });
  fireInboxPush('guest_wrote', '1', null, e.d);
  await Promise.allSettled(e.waits);
  const f = deps({ waitUntil: undefined });
  fireInboxPush('guest_wrote', '1', null, f.d);
});

Deno.test('no URL or no key (a probe or a test): nothing is called', () => {
  for (const o of [{ base: '' }, { key: '' }]) {
    const { d, seen } = deps(o);
    fireInboxPush('guest_wrote', '1', null, d);
    assertEquals(seen.length, 0);
  }
  const { d, seen } = deps();
  fireInboxPush('guest_wrote', '', null, d);
  assertEquals(seen.length, 0);
});
