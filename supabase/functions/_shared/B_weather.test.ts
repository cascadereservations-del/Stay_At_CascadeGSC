// deno test supabase/functions/_shared/B_weather.test.ts - lane B weather helpers. Frozen clock, synthetic bodies only.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { B_aqi, B_extras, B_fetchExtras, B_googleHours, B_googleTypeToCode, B_openMeteoHours, B_rainWatch, B_textToCode, RAIN_THRESHOLD } from './B_weather.ts';

const NOW = Date.parse('2026-10-13T04:20:00Z'); // 12:20 Manila
const gh = (iso: string, pctv: number, mm: number | null, type = 'RAIN') => ({
  interval: { startTime: iso }, precipitation: { probability: { percent: pctv }, ...(mm == null ? {} : { qpf: { quantity: mm } }) }, weatherCondition: { type },
});
const hours = (n: number, f: (i: number) => [number, number | null, string]) =>
  Array.from({ length: n }, (_, i) => { const [p, mm, t] = f(i); return gh(new Date(Date.parse('2026-10-13T03:00:00Z') + i * 3_600_000).toISOString(), p, mm, t); });

Deno.test('B: the rain threshold is the number rain-alert has always used', () => assertEquals(RAIN_THRESHOLD, 70));

Deno.test('B: google hours start with the hour in progress, cap at 12, carry pct / mm / code', () => {
  const rows = B_googleHours({ forecastHours: hours(24, (i) => [i * 4, i === 3 ? 1.24 : null, i === 3 ? 'LIGHT_RAIN' : 'CLEAR']) }, NOW);
  assertEquals(rows.length, 12);
  assertEquals(rows[0].time, '2026-10-13T04:00:00.000Z', 'the 12:00 hour is still running at 12:20');
  assertEquals(rows[0], { time: '2026-10-13T04:00:00.000Z', rain_chance_pct: 4, mm: null, code: 0 });
  assertEquals(rows[2], { time: '2026-10-13T06:00:00.000Z', rain_chance_pct: 12, mm: 1.2, code: 61 });
  assertEquals(Object.keys(rows[0]), ['time', 'rain_chance_pct', 'mm', 'code']);
});

Deno.test('B: google displayDateTime is read as Manila time when interval is missing', () => {
  const rows = B_googleHours({ forecastHours: [{ displayDateTime: { year: 2026, month: 10, day: 13, hours: 13 }, precipitation: { probability: { percent: 80 } } }] }, NOW);
  assertEquals(rows[0].time, '2026-10-13T05:00:00.000Z');
});

Deno.test('B: open-meteo hours are Manila wall clock, same row shape', () => {
  const t = ['2026-10-13T11:00', '2026-10-13T12:00', '2026-10-13T13:00'];
  const rows = B_openMeteoHours({ hourly: { time: t, precipitation_probability: [10, 75, 90], precipitation: [0, 0.4, 2.26], weather_code: [1, 61, 80] } }, NOW);
  assertEquals(rows.map((r) => r.time), ['2026-10-13T04:00:00.000Z', '2026-10-13T05:00:00.000Z']);
  assertEquals(rows[1], { time: '2026-10-13T05:00:00.000Z', rain_chance_pct: 90, mm: 2.3, code: 80 });
});

Deno.test('B: rain_watch uses the shared threshold (69 is not rain, 70 is), from first hit to the end of the last', () => {
  const r = (h: number, p: number) => ({ time: `2026-10-13T${String(h).padStart(2, '0')}:00:00.000Z`, rain_chance_pct: p, mm: null, code: null });
  assertEquals(B_rainWatch([r(4, 69), r(5, 69)]), null);
  assertEquals(B_rainWatch([r(4, 20), r(5, 70), r(6, 40), r(7, 85)]), { from: '2026-10-13T05:00:00.000Z', to: '2026-10-13T08:00:00.000Z', peak_pct: 85 });
});

Deno.test('B: aqi reads us_aqi, null when absent', () => { assertEquals(B_aqi({ current: { us_aqi: 41.6 } }), 42); assertEquals(B_aqi({}), null); });

Deno.test('B: extras prefer open-meteo hours (free), fall back to google only when open-meteo has none, and never throw on empty sources', () => {
  const g = { forecastHours: hours(14, () => [90, 1, 'RAIN']) };
  const om = { hourly: { time: ['2026-10-13T12:00'], precipitation_probability: [10], precipitation: [0], weather_code: [2] } };
  const a = B_extras({ google: g, openMeteo: om, aqi: { current: { us_aqi: 30 } } }, NOW, 'Partly cloudy');
  assertEquals([a.hourly_source, a.hourly.length, a.aqi, a.rain_watch, a.code], ['open_meteo', 1, 30, null, 2]);
  const b = B_extras({ google: g, openMeteo: { hourly: { time: [] } } }, NOW, 'Partly cloudy');
  assertEquals([b.hourly_source, b.hourly.length, b.rain_watch?.peak_pct, b.code], ['google', 12, 90, 63]);
  const c = B_extras({}, NOW, 'Light rain');
  assertEquals([c.hourly, c.hourly_source, c.code], [[], null, 61]);
});

Deno.test('B: condition mapping', () => {
  assertEquals([B_googleTypeToCode('MOSTLY_CLEAR'), B_googleTypeToCode('SCATTERED_THUNDERSTORMS'), B_googleTypeToCode('HEAVY_RAIN'), B_googleTypeToCode('LIGHT_RAIN_SHOWERS'), B_googleTypeToCode('')], [1, 95, 65, 80, null]);
  assertEquals([B_textToCode('Mostly cloudy'), B_textToCode('Thunderstorm'), B_textToCode('Clear sky'), B_textToCode('')], [3, 95, 0, null]);
  assert(B_textToCode('zzz') === null);
});

Deno.test('B: the added keys never collide with a key the guest guide already reads', () => {
  const added = Object.keys(B_extras({}, NOW, ''));
  for (const existing of ['current', 'forecast', 'source', 'fetched_at', 'cached', 'stale', 'location', 'error', 'daily']) assert(!added.includes(existing), existing);
  assertEquals(added.sort(), ['aqi', 'code', 'hourly', 'hourly_source', 'rain_watch']);
});

Deno.test('B: rain-alert and weather-proxy share the one threshold (no second copy of the number)', async () => {
  const rain = await Deno.readTextFile(new URL('../rain-alert/index.ts', import.meta.url));
  const proxy = await Deno.readTextFile(new URL('../weather-proxy/index.ts', import.meta.url));
  assert(/import \{ RAIN_THRESHOLD \} from '..\/_shared\/B_weather.ts'/.test(rain), 'rain-alert imports the shared constant');
  assert(!/const RAIN_THRESHOLD\s*=/.test(rain), 'rain-alert has no local copy');
  assert(/from '..\/_shared\/B_weather.ts'/.test(proxy), 'weather-proxy uses the shared helpers');
});

// ---- live-mock tests for the fetches (exact host, path and key params) and the caps ----
const OM_BODY = { hourly: { time: ['2026-10-13T12:00', '2026-10-13T13:00'], precipitation_probability: [20, 80], precipitation: [0, 1.5], weather_code: [2, 63] } };
const jsonRes = (b: unknown) => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(b) });
const mockFetch = (route: (u: URL) => Promise<any>) => {
  const urls: URL[] = [];
  return { urls, fn: (u: string) => { const url = new URL(u); urls.push(url); return route(url); } };
};

Deno.test('B fetch: happy path makes exactly two free calls (open-meteo hours, open-meteo air quality) and never Google', async () => {
  const m = mockFetch((u) => jsonRes(u.hostname === 'api.open-meteo.com' ? OM_BODY : { current: { us_aqi: 41 } }));
  const r = await B_fetchExtras(NOW, 'Partly cloudy', { googleKey: 'K', fetchFn: m.fn });
  assertEquals(m.urls.length, 2);
  const om = m.urls.find((u) => u.hostname === 'api.open-meteo.com')!, aq = m.urls.find((u) => u.hostname === 'air-quality-api.open-meteo.com')!;
  assertEquals([om.pathname, om.searchParams.get('latitude'), om.searchParams.get('longitude'), om.searchParams.get('hourly'), om.searchParams.get('timezone'), om.searchParams.get('forecast_days')],
    ['/v1/forecast', '6.1164', '125.1716', 'precipitation_probability,precipitation,weather_code', 'Asia/Manila', '2']);
  assertEquals([aq.pathname, aq.searchParams.get('current'), aq.searchParams.get('latitude'), aq.searchParams.get('longitude')], ['/v1/air-quality', 'us_aqi', '6.1164', '125.1716']);
  assert(!m.urls.some((u) => u.hostname.includes('googleapis')), 'no paid call on the happy path');
  assertEquals([r.hourly_source, r.hourly.length, r.aqi, r.rain_watch?.peak_pct], ['open_meteo', 2, 41, 80]);
});

Deno.test('B fetch: Google hours are called only when open-meteo gave nothing, with the exact URL', async () => {
  const m = mockFetch((u) => u.hostname === 'weather.googleapis.com' ? jsonRes({ forecastHours: hours(14, () => [75, 1, 'RAIN']) }) : jsonRes(u.hostname === 'api.open-meteo.com' ? { hourly: { time: [] } } : { current: { us_aqi: 5 } }));
  const r = await B_fetchExtras(NOW, '', { googleKey: 'KEY1', fetchFn: m.fn });
  const g = m.urls.find((u) => u.hostname === 'weather.googleapis.com')!;
  assertEquals([m.urls.length, g.pathname, g.searchParams.get('key'), g.searchParams.get('location.latitude'), g.searchParams.get('location.longitude'), g.searchParams.get('hours')],
    [3, '/v1/forecast/hours:lookup', 'KEY1', '6.1164', '125.1716', '24']);
  assertEquals([r.hourly_source, r.hourly.length], ['google', 12]);
  const none = mockFetch((u) => jsonRes(u.hostname === 'api.open-meteo.com' ? { hourly: { time: [] } } : {}));
  await B_fetchExtras(NOW, '', { fetchFn: none.fn });
  assertEquals(none.urls.length, 2, 'no key, no Google call');
});

Deno.test('B fetch: a hung upstream resolves at the cap, not at the upstream', async () => {
  const hang = mockFetch(() => new Promise(() => {}));
  const t0 = performance.now();
  const r = await B_fetchExtras(NOW, 'Light rain', { fetchFn: hang.fn, capMs: 40, totalMs: 400 });
  const took = performance.now() - t0;
  assert(took < 300, `took ${took} ms`);
  assertEquals([r.hourly, r.aqi, r.rain_watch, r.code], [[], null, null, 61]);
});

Deno.test('B fetch: the whole extras step is bounded by totalMs even when every call is slow', async () => {
  const slow = mockFetch(() => new Promise((res) => setTimeout(() => res({ ok: true, status: 200, json: () => Promise.resolve(OM_BODY) }), 150)));
  const t0 = performance.now();
  const r = await B_fetchExtras(NOW, '', { fetchFn: slow.fn, capMs: 1000, totalMs: 40 });
  assert(performance.now() - t0 < 140, 'returned at totalMs, not at the 150 ms upstream');
  assertEquals(r.hourly, []);
  await new Promise((res) => setTimeout(res, 200)); // let the slow mock settle before the test ends
});

Deno.test('B fetch: failed extras (throw, 500) leave the base payload intact', async () => {
  const base = { source: 'pirate_weather', current: { temp: 30, description: 'Partly cloudy' }, forecast: [{ date: 'd' }], fetched_at: 'x' };
  for (const fn of [() => Promise.reject(new Error('boom')), () => Promise.resolve({ ok: false, status: 500, json: () => Promise.resolve({}) })]) {
    const ex = await B_fetchExtras(NOW, base.current.description, { googleKey: 'K', fetchFn: fn as never, capMs: 40, totalMs: 200 });
    const payload = { ...base, ...ex };
    assertEquals([payload.source, payload.current, payload.forecast, payload.fetched_at], [base.source, base.current, base.forecast, base.fetched_at]);
    assertEquals([payload.hourly, payload.aqi, payload.rain_watch, payload.code], [[], null, null, 2]);
  }
});
