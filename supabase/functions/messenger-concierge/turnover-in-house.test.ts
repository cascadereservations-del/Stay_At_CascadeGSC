// deno test --no-check --allow-env messenger-concierge/turnover-in-house.test.ts
// 2026-11-29: the host card named the arriving guest "In-house" from midnight on a turnover day. In-house now follows the house
// times (in 14:00, out 12:00), like SQL stay_phase_v1 (20261213). Synthetic names only.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { stayLines, type StayRow } from './policy.ts';

const rows: StayRow[] = [
  { guest_name: 'Synthetic Departing', raw_summary: null, checkin_date: '2030-01-01', checkout_date: '2030-01-03', source: 'airbnb' },
  { guest_name: 'Synthetic Arriving', raw_summary: null, checkin_date: '2030-01-03', checkout_date: '2030-01-04', source: 'airbnb' },
];
const inHouse = (hm?: string) => stayLines(rows, '2030-01-03', hm)[0];

Deno.test('turnover 00:41: the departing guest is in the house', () => {
  assertEquals(inHouse('00:41'), 'In-house: Synthetic Departing · 2030-01-01 to 2030-01-03 · airbnb');
});
Deno.test('turnover 11:59 still departing; 12:00 nobody; 13:59 nobody', () => {
  assertEquals(inHouse('11:59').includes('Synthetic Departing'), true);
  assertEquals(inHouse('12:00'), 'In-house: nobody');
  assertEquals(inHouse('13:59'), 'In-house: nobody');
});
Deno.test('turnover 14:00: the arriving guest is in the house', () => {
  assertEquals(inHouse('14:00'), 'In-house: Synthetic Arriving · 2030-01-03 to 2030-01-04 · airbnb');
});
Deno.test('arriving and departing lines are unchanged', () => {
  const l = stayLines(rows, '2030-01-03', '09:00');
  assertEquals(l.length, 3);
  assertEquals(l[1].startsWith('Arriving today: Synthetic Arriving'), true);
  assertEquals(l[2].startsWith('Departing today: Synthetic Departing'), true);
});
Deno.test('without a time the old date rule stays (other callers)', () => {
  assertEquals(inHouse(undefined).includes('Synthetic Arriving'), true);
});
Deno.test('the host card passes the Manila time', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertEquals(/stayLines\(\(stays \?\? \[\]\) as StayRow\[\], today, nowHm\)/.test(src), true);
});
