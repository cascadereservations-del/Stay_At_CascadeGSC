// deno test -A --no-check messenger-concierge/spec47.test.ts
// SPEC-47: notable topics from a Messenger turn. Fire-and-forget; a failure never reaches the reply.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { noteTopics } from './index.ts';

const BID = '0b9f2c1e-7a4d-4e1b-9c3a-5d6e7f8a9b01', GID = 'e2000000-0000-4000-8000-0000000000c1';
const flow = { booking_id: BID, ref: 'CH-1' } as any;
function fake(guest: string | null, rpcFails = false) {
  const calls: any[] = [];
  const db: any = {
    from: (t: string) => ({ select: () => ({ eq: (_c: string, id: string) => ({ maybeSingle: async () => ({ data: t === 'booking_inquiries' && id === BID ? { guest_id: guest } : null }) }) }) }),
    rpc: (fn: string, a: unknown) => { calls.push([fn, a]); if (rpcFails) throw new Error('down'); return Promise.resolve({ error: null }); },
  };
  return { db, calls };
}
const settle = () => new Promise((r) => setTimeout(r, 20));

Deno.test('a turn on a booked thread records the keys with the booking guest', async () => {
  const { db, calls } = fake(GID);
  noteTopics(db, '123', flow, 'May aso po kami. Saan ang location?', { intent: 'directions', confidence: 0.9 } as any);
  await settle();
  assertEquals(calls.map((c) => [c[1].p_topic, c[1].p_guest_id, c[1].p_booking_id, c[1].p_source]), [['directions', GID, BID, 'messenger'], ['pets', GID, BID, 'messenger']]);
});

Deno.test('no booking, probe thread, unlinked guest or no topic: nothing written', async () => {
  const a = fake(GID); noteTopics(a.db, '123', null, 'wifi?', null); noteTopics(a.db, 'probe:1', flow, 'wifi?', null);
  noteTopics(a.db, '123', { booking_id: 'probe' } as any, 'wifi?', null); noteTopics(a.db, '123', flow, 'thank you', null);
  const b = fake(null); noteTopics(b.db, '123', flow, 'wifi?', null);
  await settle(); assertEquals([a.calls.length, b.calls.length], [0, 0]);
});

Deno.test('a throwing database never throws out of noteTopics', async () => {
  noteTopics({ from: () => { throw new Error('x'); } } as any, '123', flow, 'wifi?', null);
  const { db } = fake(GID, true); noteTopics(db, '123', flow, 'wifi?', null);
  await settle();
});
