// deno test --allow-env supabase/functions/release-expired-holds/payout-notices.test.ts - fakes only, synthetic data.
import { assertEquals } from 'jsr:@std/assert@1';
import { BATCH, drain, type Deps, type Notice, type Sub } from './payout-notices.ts';

const row = (i: number, over: Partial<Notice> = {}): Notice => ({ id: `0000000${i}-0000-4000-8000-000000000000`, user_id: `u${i}`, finance_text: `Ana's payout QR was changed by Lloyd ${i}.`, staff_text: 'Your payout QR was changed.', finance_sent_at: null, staff_sent_at: null, ...over });
const sub: Sub = { id: 's1', endpoint: 'https://push.example/x', p256dh: 'p', auth: 'a' };
const ok = { ok: true, status: 201, gone: false, transient: false };
function world(rows: Notice[], over: Partial<Deps> = {}) {
  const claims: string[] = [], releases: string[] = [], finance: string[] = [], logs: string[] = [], deleted: string[] = [];
  const deps: Deps = { now: () => 'T', unsent: async () => ({ rows }),
    claim: async (id, col) => { claims.push(`${id.slice(0, 8)}:${col}`); return true; },
    release: async (id, col) => { releases.push(`${id.slice(0, 8)}:${col}`); },
    sendFinance: async (t) => { finance.push(t); return 'sent'; }, subs: async () => [sub],
    push: async () => ok, deleteSub: async (id) => { deleted.push(id); }, touchSub: async () => {}, log: (m) => logs.push(m), ...over };
  return { deps, claims, releases, finance, logs, deleted };
}

Deno.test('both channels claimed then sent, nothing released', async () => {
  const w = world([row(1)]);
  assertEquals(await drain(w.deps), { rows: 1, finance: 1, staff: 1, failed: 0 });
  assertEquals(w.claims, ['00000001:finance_sent_at', '00000001:staff_sent_at']);
  assertEquals(w.releases, []);
});
Deno.test('table missing: nothing happens, nothing thrown', async () => {
  const w = world([], { unsent: async () => ({ rows: [], missing: true }) });
  assertEquals(await drain(w.deps), { rows: 0, finance: 0, staff: 0, failed: 0 });
});
Deno.test('at most once: a lost claim sends nothing', async () => {
  const w = world([row(1)], { claim: async () => false });
  assertEquals(await drain(w.deps), { rows: 1, finance: 0, staff: 0, failed: 0 });
  assertEquals(w.finance, []);
});
Deno.test('a Finance throw releases that claim, and does not block its push or the next row', async () => {
  let n = 0;
  const w = world([row(1), row(2)], { sendFinance: async () => { if (++n === 1) throw new Error('tg down'); return 'sent'; } });
  assertEquals(await drain(w.deps), { rows: 2, finance: 1, staff: 2, failed: 1 });
  assertEquals(w.releases, ['00000001:finance_sent_at']);
});
Deno.test('Finance: retry releases the claim; a permanent refusal is logged and stays closed', async () => {
  const retry = world([row(1)], { sendFinance: async () => 'retry' });
  await drain(retry.deps);
  assertEquals(retry.releases, ['00000001:finance_sent_at']);
  const perm = world([row(1)], { sendFinance: async () => 'permanent' });
  const r = await drain(perm.deps);
  assertEquals([perm.releases, r.failed, perm.logs.length], [[], 1, 1]);
});
Deno.test('already-stamped channel is not claimed or sent again', async () => {
  const w = world([row(1, { finance_sent_at: 'x' })]);
  await drain(w.deps);
  assertEquals(w.finance, []);
  assertEquals(w.claims, ['00000001:staff_sent_at']);
});
Deno.test('push: transient keeps the row open; permanent refusal closes it and logs; gone deletes the sub; none/unset behave', async () => {
  const transient = world([row(1)], { push: async () => ({ ok: false, status: 503, gone: false, transient: true }) });
  assertEquals((await drain(transient.deps)).staff, 0);
  assertEquals(transient.releases, ['00000001:staff_sent_at']);
  const perm = world([row(1)], { push: async () => ({ ok: false, status: 400, gone: false, transient: false }) });
  assertEquals([(await drain(perm.deps)).staff, perm.releases, perm.logs.length], [1, [], 1]);
  const gone = world([row(1)], { push: async () => ({ ok: false, status: 410, gone: true, transient: false }) });
  assertEquals([(await drain(gone.deps)).staff, gone.deleted], [1, ['s1']]);
  const none = world([row(1)], { subs: async () => [] });
  assertEquals((await drain(none.deps)).staff, 1);
  const off = world([row(1)], { push: null, sendFinance: null });
  assertEquals(await drain(off.deps), { rows: 1, finance: 0, staff: 0, failed: 0 });
  assertEquals(off.claims, []);
});
Deno.test('deadline: rows after the budget wait for the next run; a failed read never throws', async () => {
  let t = 0;
  const w = world([row(1), row(2), row(3)], { nowMs: () => (t += 30_000) });
  const r = await drain(w.deps);
  assertEquals(r.rows < 3, true);
  assertEquals(BATCH, 10);
  const bad = world([], { unsent: async () => { throw new Error('boom'); } });
  assertEquals((await drain(bad.deps)).rows, 0);
});
