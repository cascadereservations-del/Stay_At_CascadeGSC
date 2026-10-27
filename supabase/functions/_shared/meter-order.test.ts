// Pins stay-order meter checks with the real October 2026 numbers from the unit's paper log (Lloyd, 2026-10-27).
// Honey's 17-19 Oct report (4273 kWh, 81.580 m³) was refused because 23-24 Oct (4326, 82.743) was already on file.
import { assertEquals } from 'jsr:@std/assert@1';
import { meterNeighbours, meterOrderMessage, repointNext, stayKey, type MeterRow } from './meter-order.ts';

const row = (id: string, co: string, e: number, w: number, extra: Partial<MeterRow> = {}): MeterRow => ({
  id, electric_curr: e, water_curr: w, recorded_at: `${co}T06:00:00Z`,
  cleaning_sessions: { cleaning_type: 'turnover', checkout_date: co, nights_stayed: 1 }, ...extra,
});
// On file when Honey tried: 14 Oct (Shasha) and, filed early, 24 Oct (Frances). Recorded order is not stay order.
const onFile = [
  row('shasha', '2026-10-14', 4225, 80.499),
  { ...row('frances', '2026-10-24', 4326, 82.743, { electric_prev: 4225, water_prev: 80.499 }), recorded_at: '2026-10-24T06:00:00Z' },
];

Deno.test('the 17-19 Oct report sits between its neighbours and is not refused', () => {
  const n = meterNeighbours(onFile, '2026-10-19');
  assertEquals([n.prevElec?.value, n.nextElec?.value, n.prevWater?.value, n.nextWater?.value], [4225, 4326, 80.499, 82.743]);
  assertEquals(meterOrderMessage(4273, 81.58, n), null);
});

Deno.test('below the stay before, or above the stay after, is refused with the date that conflicts', () => {
  const n = meterNeighbours(onFile, '2026-10-19');
  const low = meterOrderMessage(4200, 81.58, n)!;
  assertEquals(low.includes('electric 4200 kWh is lower than the reading for the stay that checked out Oct 14 (4225)'), true, low);
  const high = meterOrderMessage(4273, 83.161, n)!;
  assertEquals(high.includes('water 83.161 m³ is higher than the reading for the later stay that checked out Oct 24 (82.743)'), true, high);
  assertEquals(high.includes('message Lloyd'), true);
});

Deno.test('today\'s report still compares with the newest stay, as before', () => {
  const n = meterNeighbours(onFile, '2026-10-25');
  assertEquals([n.prevElec?.value, n.nextElec], [4326, null]);
  assertEquals(meterOrderMessage(4349, 83.161, n), null);
  assertEquals(meterOrderMessage(4273, 81.58, n)!.includes('lower than the reading for the stay that checked out Oct 24 (4326)'), true);
});

Deno.test('flagged-wrong numbers and mid-stays are never neighbours', () => {
  const rows = [...onFile,
    row('typo', '2026-10-16', 9999, 99, { meter_flag: 'misread' }),
    row('mid', '2026-10-18', 4300, 82, { cleaning_sessions: { cleaning_type: 'mid_stay', checkout_date: null } })];
  const n = meterNeighbours(rows, '2026-10-19');
  assertEquals([n.prevElec?.value, n.nextElec?.value], [4225, 4326]);
});

Deno.test('a reading with no session falls back to its Manila recording day', () => {
  assertEquals(stayKey({ electric_curr: 1, water_curr: 1, recorded_at: '2026-10-16T17:30:00Z' }), '2026-10-17');
});

Deno.test('the later stay is re-pointed to the late reading, per meter, with per-night usage', () => {
  const n = meterNeighbours(onFile, '2026-10-19');
  assertEquals(n.next?.id, 'frances');
  assertEquals(repointNext(n.next, 4273, 81.58),
    { electric_prev: 4273, electric_delta: 53, kwh_per_night: 53, water_prev: 81.58, water_delta: 1.163, m3_per_night: 1.163 });
  assertEquals(repointNext(n.next, 4273, null), { electric_prev: 4273, electric_delta: 53, kwh_per_night: 53 }, 'water untouched');
  assertEquals(repointNext({ ...n.next!, electric_prev: 4273, water_prev: 81.58 }, 4273, 81.58), null, 'already right');
  assertEquals(repointNext(n.next, 4400, null), null, 'never makes a negative delta');
  assertEquals(repointNext(null, 4273, 81.58), null);
});
