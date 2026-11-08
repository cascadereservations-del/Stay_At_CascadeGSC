// deno test supabase/functions/weather-proxy - s112 lane W: Cascade by default, staff-only "Here", rounding, PH box, cache cells, daily limit.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { CACHE_KEY, CASCADE, CELL_PREFIX, HERE_DAILY_LIMIT, MAX_CELLS, cacheKey, cellsToDrop, countHere, parseHere, readCoords, resolvePlace } from './place.ts';

const U = (q = '') => new URL(`https://x.supabase.co/functions/v1/weather-proxy${q}`);
const req = (auth?: string) => new Request('https://x/', { headers: auth ? { authorization: auth } : {} });
const staffOk = () => Promise.resolve('user-1');
const staffNo = () => Promise.reject(new Error('staff_access_denied'));

Deno.test('W: no params = Cascade at Bria Homes, not the GenSan city centre, and the old cache key', async () => {
  const r = await resolvePlace(req(), U(), null, staffOk);
  assertEquals(r, { place: CASCADE });
  assertEquals([CASCADE.lat, CASCADE.lon, CASCADE.kind], [6.1545, 125.1852, 'cascade']);
  assertEquals(CASCADE.label, 'Cascade, Bria Homes, General Santos');
  assertEquals(cacheKey(CASCADE), 'weather_proxy_cache');
  assertEquals(CACHE_KEY, 'weather_proxy_cache');
});

Deno.test('W: anonymous lat/lon is ignored - Cascade, never an error, staff check not even called', async () => {
  let called = 0;
  const spy = () => { called++; return Promise.resolve('u'); };
  assertEquals(await resolvePlace(req(), U('?lat=6.12&lon=125.17'), null, spy), { place: CASCADE });
  assertEquals(await resolvePlace(req(), U(), { lat: 99, lon: 0 }, spy), { place: CASCADE }, 'out-of-area anonymous is still Cascade');
  assertEquals(called, 0);
});

Deno.test('W: lat/lon with a non-staff or expired token = Cascade', async () => {
  assertEquals(await resolvePlace(req('Bearer anon-key'), U('?lat=6.12&lon=125.17'), null, staffNo), { place: CASCADE });
  assertEquals(await resolvePlace(req('Bearer anon-key'), U('?lat=99&lon=0'), null, staffNo), { place: CASCADE });
});

Deno.test('W: staff lat/lon = Here, rounded to 2 decimals, from query or JSON body', async () => {
  const q = await resolvePlace(req('Bearer t'), U('?lat=6.154546&lon=125.185232'), null, staffOk);
  assertEquals(q, { place: { label: 'Near you', lat: 6.15, lon: 125.19, kind: 'here' }, userId: 'user-1' });
  const b = await resolvePlace(req('Bearer t'), U(), { lat: 7.0731, lon: 125.6128 }, staffOk);
  assertEquals('place' in b && b.place, { label: 'Near you', lat: 7.07, lon: 125.61, kind: 'here' });
});

Deno.test('W: rounding and the Philippines box (lat 4.5..21.5, lon 116..127)', () => {
  assertEquals(parseHere('6.155', '125.185'), { label: 'Near you', lat: 6.16, lon: 125.19, kind: 'here' });
  assertEquals(parseHere(4.5, 116), { label: 'Near you', lat: 4.5, lon: 116, kind: 'here' }, 'edges are inside');
  assertEquals(parseHere(21.5, 127), { label: 'Near you', lat: 21.5, lon: 127, kind: 'here' });
  assertEquals(parseHere(4.494, 120), 'out_of_area', '4.49 after rounding is outside');
  assertEquals(parseHere(4.496, 120), { label: 'Near you', lat: 4.5, lon: 120, kind: 'here' }, 'rounds into the box first');
  assertEquals(parseHere(1.35, 103.8), 'out_of_area', 'Singapore');
  assertEquals(parseHere(14.6, 127.01), 'out_of_area');
  assertEquals(parseHere('abc', 125), 'invalid_coords');
  assertEquals(parseHere('', 125), 'invalid_coords');
  assertEquals(parseHere(null, 125), 'invalid_coords');
  assertEquals(parseHere(6.1, Infinity), 'invalid_coords');
});

Deno.test('W: a verified staff user with bad coords gets a 400', async () => {
  assertEquals(await resolvePlace(req('Bearer t'), U('?lat=1.35&lon=103.8'), null, staffOk), { error: 'out_of_area', status: 400 });
  assertEquals(await resolvePlace(req('Bearer t'), U('?lat=6.1'), null, staffOk), { error: 'invalid_coords', status: 400 }, 'lon missing');
});

Deno.test('W: readCoords - query wins over body, nothing = null', () => {
  assertEquals(readCoords(U('?lat=1&lon=2'), { lat: 3, lon: 4 }), { lat: '1', lon: '2' });
  assertEquals(readCoords(U(), { lat: 3, lon: 4 }), { lat: 3, lon: 4 });
  assertEquals(readCoords(U(), {}), null);
  assertEquals(readCoords(U(), null), null);
});

Deno.test('W: one cache key per 2-decimal cell', () => {
  assertEquals(cacheKey({ label: 'Near you', lat: 6.1, lon: 125, kind: 'here' }), `${CELL_PREFIX}6.10,125.00`);
  const a = parseHere(6.1512, 125.1859), b = parseHere(6.1488, 125.1851);
  assert(typeof a !== 'string' && typeof b !== 'string');
  assertEquals(cacheKey(a), cacheKey(b), 'two phones in the same ~1 km cell share one cache row');
  assertEquals(cacheKey(a), 'weather_proxy_cache:6.15,125.19');
});

Deno.test('W: cell cap keeps the newest 50, drops the oldest, never the Cascade key', () => {
  const rows = Array.from({ length: 53 }, (_, i) => ({ key: `${CELL_PREFIX}6.${String(i).padStart(2, '0')},125.00`, updated_at: new Date(Date.UTC(2026, 10, 8, 0, i)).toISOString() }));
  rows.push({ key: CACHE_KEY, updated_at: '2020-01-01T00:00:00Z' });
  const drop = cellsToDrop(rows);
  assertEquals(MAX_CELLS, 50);
  assertEquals(drop.sort(), [`${CELL_PREFIX}6.00,125.00`, `${CELL_PREFIX}6.01,125.00`, `${CELL_PREFIX}6.02,125.00`]);
  assertEquals(cellsToDrop(rows.slice(0, 50)), []);
});

Deno.test('W: 60 Here calls per user per Manila day, reset on a new day, other users unaffected', () => {
  let usage: unknown = null;
  for (let i = 0; i < HERE_DAILY_LIMIT; i++) {
    const c = countHere(usage, 'u1', '2026-11-08');
    assert(c.allowed, `call ${i + 1} allowed`);
    usage = c.usage;
  }
  assertEquals(HERE_DAILY_LIMIT, 60);
  assertEquals(countHere(usage, 'u1', '2026-11-08').allowed, false, 'call 61 refused');
  assertEquals(countHere(usage, 'u2', '2026-11-08').allowed, true);
  const next = countHere(usage, 'u1', '2026-11-09');
  assertEquals(next, { usage: { date: '2026-11-09', counts: { u1: 1 } }, allowed: true });
});

Deno.test('W: index.ts wiring - staff check is read_operations, coords never in a log line, no GenSan centre left', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(src.includes("requireStaffAccess(r, 'read_operations', PROPERTY_ID)"));
  assert(!src.includes('GEN_SAN'), 'the city-centre constants are gone');
  assert(!/console\.\w+\([^)]*(place\.lat|place\.lon|p\.lat|p\.lon)/.test(src), 'no log line prints coordinates');
  assert(src.includes("lat: place.lat, lng: place.lon"), 'extras (hourly, aqi) follow the place');
  for (const k of ['cached: true, location: LOCATION, ...extra', 'cached: false, location: LOCATION, ...extra', 'stale: true, location: LOCATION, ...extra']) assert(src.includes(k), k);
});
