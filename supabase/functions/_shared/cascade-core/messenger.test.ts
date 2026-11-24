// threadForBooking picks the newest thread deterministically; setFlowStep ends a flow without losing its other keys.
// deno test --no-lock --node-modules-dir=auto --allow-env --allow-read _shared/cascade-core/messenger.test.ts   (run from supabase/functions)
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

/** A stateful concierge_threads stand-in: select/update honour the eq filters (psid, booking_flow->>booking_id) like the real table. */
// deno-lint-ignore no-explicit-any
function threadsDb(rows: any[]) {
  const log: string[] = [];
  const db = { from: (_t: string) => {
    // deno-lint-ignore no-explicit-any
    let patch: any = null; const f: Array<[string, string]> = [];
    // deno-lint-ignore no-explicit-any
    const match = () => rows.filter((r: any) => f.every(([k, v]) => (k === 'psid' ? r.psid : r.booking_flow?.booking_id) === v));
    // deno-lint-ignore no-explicit-any
    const b: any = {
      select: () => b, update: (p: unknown) => { patch = p; return b; },
      eq: (k: string, v: string) => { f.push([k === 'psid' ? 'psid' : 'bid', v]); return b; },
      maybeSingle: () => Promise.resolve({ data: match()[0] ?? null }),
      then: (res: (v: unknown) => void) => { if (patch) { log.push('write'); for (const r of match()) Object.assign(r, patch); } res({ error: null }); },
    };
    return b;
  } };
  return { db, log };
}

Deno.test('setFlowStep: keeps the flow keys, sets step and timestamps, only while the thread still points at this booking', async () => {
  // deno-lint-ignore no-explicit-any
  const rows: any[] = [{ psid: 'P2', updated_at: 'old', booking_flow: { booking_id: 'B1', lang: 'tl', step: 'await_receipt' } }];
  const { db } = threadsDb(rows);
  assertEquals(await setFlowStep(db, { psid: 'P2' }, 'B1', 'cancelled', '2026-11-24T00:00:00.000Z'), true);
  assertEquals(rows[0].booking_flow, { booking_id: 'B1', lang: 'tl', step: 'cancelled', updated_at: '2026-11-24T00:00:00.000Z' });
  assertEquals(rows[0].updated_at, '2026-11-24T00:00:00.000Z');
});

Deno.test('setFlowStep (ML-71): a thread that has moved on to another booking is not written', async () => {
  const flow = { booking_id: 'B2', lang: 'en', step: 'await_dates' };
  const rows = [{ psid: 'P2', updated_at: 'old', booking_flow: flow }];
  const { db, log } = threadsDb(rows);
  assertEquals(await setFlowStep(db, { psid: 'P2' }, 'B1', 'cancelled'), false);
  assertEquals(log, []);
  assertEquals(rows[0].booking_flow, flow);
  assertEquals(await setFlowStep(db, { psid: 'P2' }, '', 'cancelled'), false);
});

Deno.test('setFlowStep (ML-71): read and write both carry the booking_id filter; the write patches the freshly read flow', async () => {
  const { db, calls } = fakeDb({ data: { booking_flow: { booking_id: 'B1', step: 'x', fresh: true } } });
  await setFlowStep(db, { psid: 'P2' }, 'B1', 'confirmed', 'T');
  const eqs = calls.filter((c) => c[0] === 'eq').map((c) => c.slice(1).join('='));
  assertEquals(eqs, ['psid=P2', 'booking_flow->>booking_id=B1', 'psid=P2', 'booking_flow->>booking_id=B1']);
  assertEquals(calls.find((c) => c[0] === 'update')?.[1], { booking_flow: { booking_id: 'B1', step: 'confirmed', fresh: true, updated_at: 'T' }, updated_at: 'T' });
});
