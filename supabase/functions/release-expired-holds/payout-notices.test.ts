// deno test --allow-env supabase/functions/release-expired-holds/payout-notices.test.ts - fakes only, synthetic data.
import { assertEquals } from 'jsr:@std/assert@1';
import { drain, type Deps, type Notice, type Sub } from './payout-notices.ts';

const row = (i: number, over: Partial<Notice> = {}): Notice => ({ id: `0000000${i}-0000-4000-8000-000000000000`, user_id: `u${i}`, finance_text: `Ana's payout QR was changed by Lloyd ${i}.`, staff_text: 'Your payout QR was changed.', finance_sent_at: null, staff_sent_at: null, ...over });
const sub: Sub = { id: 's1', endpoint: 'https://push.example/x', p256dh: 'p', auth: 'a' };
function world(rows: Notice[], over: Partial<Deps> = {}) {
  const stamps: string[] = [], finance: string[] = [], pushed: string[] = [];
  const deps: Deps = { now: () => 'T', unsent: async () => ({ rows }), stamp: async (id, col) => { stamps.push(`${id.slice(0, 8)}:${col}`); },
    sendFinance: async (t) => { finance.push(t); return true; }, subs: async () => [sub],
    push: async (_s, m) => { pushed.push(m.body); return { ok: true, status: 201, gone: false, transient: false }; },
    deleteSub: async () => {}, touchSub: async () => {}, log: () => {}, ...over };
  return { deps, stamps, finance, pushed };
}

Deno.test('both channels sent and stamped independently', async () => {
  const w = world([row(1)]);
  assertEquals(await drain(w.deps), { rows: 1, finance: 1, staff: 1, failed: 0 });
  assertEquals(w.stamps, ['00000001:finance_sent_at', '00000001:staff_sent_at']);
});
Deno.test('table missing: nothing happens, nothing thrown', async () => {
  const w = world([], { unsent: async () => ({ rows: [], missing: true }) });
  assertEquals(await drain(w.deps), { rows: 0, finance: 0, staff: 0, failed: 0 });
});
Deno.test('a Finance failure on one row does not block its push or the next row', async () => {
  let n = 0;
  const w = world([row(1), row(2)], { sendFinance: async () => (++n === 1 ? (() => { throw new Error('tg down'); })() : true) });
  const r = await drain(w.deps);
  assertEquals(r, { rows: 2, finance: 1, staff: 2, failed: 1 });
  assertEquals(w.stamps.includes('00000001:finance_sent_at'), false);
  assertEquals(w.stamps.includes('00000001:staff_sent_at'), true);
});
Deno.test('already-stamped channel is not sent again', async () => {
  const w = world([row(1, { finance_sent_at: 'x' })]);
  await drain(w.deps);
  assertEquals(w.finance, []);
  assertEquals(w.stamps, ['00000001:staff_sent_at']);
});
Deno.test('transient push failure keeps the row open; no phone or gone phone closes it; VAPID/Finance unset waits', async () => {
  const transient = world([row(1)], { push: async () => ({ ok: false, status: 503, gone: false, transient: true }) });
  assertEquals((await drain(transient.deps)).staff, 0);
  const none = world([row(1)], { subs: async () => [] });
  assertEquals((await drain(none.deps)).staff, 1);
  const gone = world([row(1)], { push: async () => ({ ok: false, status: 410, gone: true, transient: false }) });
  assertEquals((await drain(gone.deps)).staff, 1);
  const off = world([row(1)], { push: null, sendFinance: null });
  assertEquals(await drain(off.deps), { rows: 1, finance: 0, staff: 0, failed: 0 });
  assertEquals(off.stamps, []);
});
Deno.test('a failed read never throws', async () => {
  const w = world([], { unsent: async () => { throw new Error('boom'); } });
  assertEquals((await drain(w.deps)).rows, 0);
});
