// Pins stay-order meter checks with the real October 2026 numbers from the unit's paper log (Lloyd, 2026-10-27).
// Honey's 17-19 Oct report (4273 kWh, 81.580 m³) was refused because 23-24 Oct (4326, 82.743) was already on file.
import { assertEquals } from 'jsr:@std/assert@1';
import { meterNeighbours, meterOrderMessage, repointNext, stayDays, stayKey, usableRows, usageSamples, METER_WRONG_NUMBER_FLAGS, type MeterRow } from './meter-order.ts';

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

Deno.test('flagged-wrong numbers never count; mid-stays count only on the server (deltas chain through them)', () => {
  const rows = [...onFile,
    row('typo', '2026-10-16', 9999, 99, { meter_flag: 'misread' }),
    row('mid', '2026-10-18', 4260, 81, { cleaning_sessions: { cleaning_type: 'mid_stay', checkout_date: '2026-10-20' } })];
  const page = meterNeighbours(rows, '2026-10-19');
  assertEquals([page.prevElec?.value, page.nextElec?.value], [4225, 4326]);
  const server = meterNeighbours(rows, '2026-10-19', true);
  assertEquals([server.prevElec?.value, server.prevElec?.row.id], [4260, 'mid'], 'mid-stay keyed by its reading day, not its future check-out');
});

Deno.test('a future check-out on a stored row does not make it a later stay', () => {
  const typo = row('typo-co', '2026-10-30', 4250, 80.9);
  typo.recorded_at = '2026-10-16T06:00:00Z';
  assertEquals(stayKey(typo), '2026-10-16');
  const n = meterNeighbours([...onFile, typo], '2026-10-19');
  assertEquals([n.prevElec?.value, n.nextElec?.value], [4250, 4326]);
  assertEquals(meterOrderMessage(4273, 81.58, n), null);
});

Deno.test('a reading with no session falls back to its Manila recording day', () => {
  assertEquals(stayKey({ electric_curr: 1, water_curr: 1, recorded_at: '2026-10-16T17:30:00Z' }), '2026-10-17');
});

Deno.test('the later stay is re-pointed to the late reading, per meter, with per-night usage', () => {
  const n = meterNeighbours(onFile, '2026-10-19');
  assertEquals(repointNext(n, 4273, 81.58), [{ id: 'frances',
    patch: { electric_prev: 4273, electric_delta: 53, kwh_per_night: 53, water_prev: 81.58, water_delta: 1.163, m3_per_night: 1.163 } }]);
  assertEquals(repointNext(n, 4273, null), [{ id: 'frances', patch: { electric_prev: 4273, electric_delta: 53, kwh_per_night: 53 } }], 'water untouched');
  const done = meterNeighbours([onFile[0], { ...onFile[1], electric_prev: 4273, water_prev: 81.58 }], '2026-10-19');
  assertEquals(repointNext(done, 4273, 81.58), [], 'already right');
  assertEquals(repointNext(n, 4400, null), [], 'never makes a negative delta');
  assertEquals(repointNext({ prevElec: null, nextElec: null, prevWater: null, nextWater: null }, 4273, 81.58), []);
});

Deno.test('each meter re-points the row that holds its next number', () => {
  const noElec = { ...row('w-only', '2026-10-20', 0, 81.7), electric_curr: null };
  const n = meterNeighbours([...onFile, noElec], '2026-10-19');
  assertEquals(repointNext(n, 4273, 81.58).map(x => x.id).sort(), ['frances', 'w-only']);
});

Deno.test('anomaly history leaves out a row still spanning a gap, and rows being re-pointed', () => {
  const r = (id: string, co: string, prev: number, curr: number, kpn: number) =>
    ({ ...row(id, co, curr, 80, { electric_prev: prev, water_prev: 80 }), kwh_per_night: kpn, m3_per_night: 0.2 });
  const rows = [r('a', '2026-10-13', 4190, 4209, 19), r('b', '2026-10-14', 4209, 4225, 16), r('c', '2026-10-17', 4225, 4240, 15),
    r('frances', '2026-10-24', 4240, 4326, 86)];   // 24 Oct measured from 17 Oct: three stays in one night
  const since = Date.parse('2026-10-01T00:00:00Z');
  assertEquals(usageSamples(rows, since).map(s => s.kwh_per_night), [19, 16], '24 Oct covers 7 days for 1 night, 17 Oct 3 days for 1 night: both left out');
  const filed = [...rows, r('d', '2026-10-19', 4240, 4273, 16.5)];   // 19 Oct filed late, 24 Oct not re-pointed yet
  assertEquals(usageSamples(filed, since).map(s => s.kwh_per_night), [19, 16, 16.5], '19 Oct (2 days, 1 night) counts; 24 Oct now spans a gap: left out');
  assertEquals(usageSamples([rows[0], rows[1]], since, ['b']).map(s => s.kwh_per_night), [19], 'a row being re-pointed: left out');
  assertEquals(usageSamples(rows, Date.parse('2026-10-14T00:00:00Z')).map(s => s.kwh_per_night), [16], 'only the window');
  const quiet = [r('x', '2026-10-13', 4190, 4209, 19), { ...r('y', '2026-10-15', 4209, 4225, 16), cleaning_sessions: { cleaning_type: 'turnover', checkout_date: '2026-10-15', nights_stayed: 1 } }];
  assertEquals(usageSamples(quiet, since).map(s => s.kwh_per_night), [19, 16], 'one quiet day between stays still counts');
  const flagged = [...rows, { ...r('typo', '2026-10-15', 4225, 9999, 999), meter_flag: 'misread' }];
  assertEquals(usageSamples(flagged, since).map(s => s.kwh_per_night), [19, 16], 'flagged-wrong rows never count');
});

Deno.test('mid-stays and the turnover after one stay out of the strict history; loose keeps every real row', () => {
  const r = (id: string, co: string, prev: number, curr: number, kpn: number, type = 'turnover', nights = 1) =>
    ({ ...row(id, co, curr, 80, { electric_prev: prev, water_prev: 80 }), kwh_per_night: kpn, m3_per_night: 0.2,
       cleaning_sessions: { cleaning_type: type, checkout_date: co, nights_stayed: nights } });
  const rows = [r('a', '2026-10-01', 4000, 4020, 20), r('m', '2026-10-02', 4020, 4030, 10, 'mid_stay', 3),
    r('t', '2026-10-04', 4030, 4040, 3.3, 'turnover', 3), r('b', '2026-10-05', 4040, 4060, 20)];
  const since = Date.parse('2026-09-01T00:00:00Z');
  assertEquals(usageSamples(rows, since).map(s => s.kwh_per_night), [20, 20]);
  assertEquals(usageSamples(rows, since, [], false).map(s => s.kwh_per_night), [20, 10, 3.3, 20]);
  assertEquals([stayDays('2026-10-17', '2026-10-24'), stayDays(null, '2026-10-24')], [7, null]);
});

Deno.test('D-352: an estimate_pending reading is never a neighbour and never a usage sample', () => {
  const rows = [
    row('abe', '2026-10-17', 4240, 80.699),
    row('shaneen', '2026-10-19', 4273, 81.58, { meter_flag: 'estimate_pending', electric_prev: 4240, kwh_per_night: 16.5 }),
    row('james', '2026-10-22', 4312, 82.5, { electric_prev: 4273, kwh_per_night: 13 }),
  ];
  const n = meterNeighbours(rows, '2026-10-21', true);
  assertEquals([n.prevElec?.value, n.nextElec?.value, n.prevWater?.value], [4240, 4312, 80.699], 'the pending 4273 is skipped');
  assertEquals(usableRows(rows).map(r => r.id), ['abe', 'james']);
  assertEquals(meterOrderMessage(4260, 81, n), null, 'lower than the pending 4273 but above the verified 4240');
  // james chains from the pending value, so he spans a gap and is left out of the history; a settled flag counts again
  assertEquals(usageSamples(rows, 0).length, 0);
  assertEquals(usableRows([{ ...rows[1], meter_flag: 'typed_accepted' }]).length, 1);
  assertEquals(usableRows([{ ...rows[1], meter_flag: 'estimated' }]).length, 1);
  assertEquals(METER_WRONG_NUMBER_FLAGS.includes('estimate_pending'), false, 'wrong-number list keeps its meaning');
});
