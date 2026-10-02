// D-290: the Messenger availability lists and Cassy's stay lists treat chained bookings as one stay. Synthetic data only.
// deno test _shared/cascade-core/chains.test.ts  (run from supabase/functions)
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { dropJunctionDays, type Chain } from './chains.ts';
import { mergeChained } from './tools.ts';

const row = (code: string, checkin: string, checkout: string, nights: number, total: number | null, over: Record<string, unknown> = {}) =>
  ({ stay_kind: 'airbnb', code, guest_id: 'g-1', guest_name: 'Test Guest', checkin, checkout, nights, status: 'confirmed', accommodation_total: total, ...over });

Deno.test('mergeChained: two back-to-back bookings of one guest become one stay with a note', () => {
  const out = mergeChained([row('HMB', '2026-10-02', '2026-10-04', 2, 2000), row('HMA', '2026-09-28', '2026-10-02', 4, 3500), row('HMC', '2026-10-09', '2026-10-10', 1, 900)]);
  assertEquals(out.length, 2);
  assertEquals([out[0].code, out[0].checkin, out[0].checkout, out[0].nights, out[0].accommodation_total, out[0].note], ['HMA + HMB', '2026-09-28', '2026-10-04', 6, 5500, '(2 bookings joined 2 Oct)']);
  assertEquals(out[1].note, undefined);
});

Deno.test('mergeChained: a different guest on the same day, a gap, or a missing total do not merge wrongly', () => {
  assertEquals(mergeChained([row('A', '2026-09-28', '2026-10-02', 4, 100), row('B', '2026-10-02', '2026-10-04', 2, 100, { guest_id: 'g-2' })]).length, 2);
  assertEquals(mergeChained([row('A', '2026-09-28', '2026-10-02', 4, 100), row('B', '2026-10-03', '2026-10-04', 1, 100)]).length, 2);
  const noTotal = mergeChained([row('A', '2026-09-28', '2026-10-02', 4, null), row('B', '2026-10-02', '2026-10-04', 2, 100)]);
  assertEquals([noTotal.length, noTotal[0].accommodation_total], [1, null]);
  // no ids: the same non-empty name chains, an empty name never does
  const named = (n: string | null) => [row('A', '2026-09-28', '2026-10-02', 4, 1, { guest_id: null, guest_name: n }), row('B', '2026-10-02', '2026-10-04', 2, 1, { guest_id: null, guest_name: n })];
  assertEquals(mergeChained(named('test guest')).length, 1);
  assertEquals(mergeChained(named(null)).length, 2);
});

Deno.test('mergeChained: three bookings and a mixed source read as one stay', () => {
  const out = mergeChained([row('A', '2026-09-28', '2026-09-30', 2, 1), row('B', '2026-09-30', '2026-10-02', 2, 1, { stay_kind: 'direct' }), row('C', '2026-10-02', '2026-10-05', 3, 1)]);
  assertEquals(out.length, 1);
  assertEquals([out[0].code, out[0].nights, out[0].stay_kind, out[0].note], ['A + B + C', 7, 'mixed', '(3 bookings joined 30 Sep, 2 Oct)']);
});

Deno.test('availability: a junction day leaves both the check-in and the check-out lists', () => {
  const chain = { junction_date: '2026-10-02' } as Chain;
  const checkins = new Set(['2026-10-02', '2026-10-09']), checkouts = new Set(['2026-10-02', '2026-10-04']);
  dropJunctionDays([chain], checkins, checkouts);
  assertEquals([...checkins], ['2026-10-09']);
  assertEquals([...checkouts], ['2026-10-04']);
});
