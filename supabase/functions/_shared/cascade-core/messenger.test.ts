// threadForBooking picks the newest thread deterministically; setFlowStep ends a flow without losing its other keys.
// deno test --no-lock --allow-env _shared/cascade-core/messenger.test.ts   (run from supabase/functions)
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { setFlowStep, threadForBooking } from './messenger.ts';

type Call = [string, ...unknown[]];
/** A recording query builder: every method logs its call and returns the builder; maybeSingle/await resolve `result`. */
// deno-lint-ignore no-explicit-any
function fakeDb(result: { data: any }) {
  const calls: Call[] = [];
  // deno-lint-ignore no-explicit-any
  const b: any = new Proxy({}, { get: (_t, name: string) => name === 'maybeSingle' ? (...a: unknown[]) => { calls.push([name, ...a]); return Promise.resolve(result); }
    : name === 'then' ? undefined : (...a: unknown[]) => { calls.push([name, ...a]); return b; } });
  return { db: { from: (t: string) => { calls.push(['from', t]); return b; } }, calls };
}

Deno.test('threadForBooking: newest thread wins (updated_at desc, psid as tie-break, limit 1)', async () => {
  const { db, calls } = fakeDb({ data: { psid: 'P2', guest_name: 'Ben', booking_flow: { booking_id: 'B1' }, history: [] } });
  const t = await threadForBooking(db, 'B1');
  assertEquals(t?.psid, 'P2');
  assertEquals(calls.map((c) => c.join(':')), [
    'from:concierge_threads', 'select:psid, guest_name, booking_flow, history, human_until', 'eq:booking_flow->>booking_id:B1',
    'order:updated_at:[object Object]', 'order:psid', 'limit:1', 'maybeSingle',
  ]);
  assertEquals(calls[3][2], { ascending: false });
});

Deno.test('threadForBooking: no row, or a row without psid, is null', async () => {
  assertEquals(await threadForBooking(fakeDb({ data: null }).db, 'B1'), null);
  assertEquals(await threadForBooking(fakeDb({ data: { guest_name: 'x' } }).db, 'B1'), null);
});

Deno.test('setFlowStep: keeps the flow keys, sets step and timestamps, targets the thread by psid', async () => {
  const { db, calls } = fakeDb({ data: null });
  await setFlowStep(db, { psid: 'P2', booking_flow: { booking_id: 'B1', lang: 'tl', step: 'await_receipt' } }, 'cancelled', '2026-11-24T00:00:00.000Z');
  assertEquals(calls[0], ['from', 'concierge_threads']);
  assertEquals(calls[1], ['update', { booking_flow: { booking_id: 'B1', lang: 'tl', step: 'cancelled', updated_at: '2026-11-24T00:00:00.000Z' }, updated_at: '2026-11-24T00:00:00.000Z' }]);
  assertEquals(calls[2], ['eq', 'psid', 'P2']);
});
