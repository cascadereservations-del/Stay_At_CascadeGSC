// deno test supabase/functions/weather-proxy - s112 lane W: Cascade by default, staff-only "Here", rounding, PH box, cache cells, daily limit.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { CACHE_KEY, CASCADE, HERE_DAILY_LIMIT, gateHere, parseHere, readCache, readCoords, resolvePlace, writeCache, type Place } from './place.ts';

// Fake supabase client: records every table and rpc touched; rpc answers from `rpcResult` (a value, or a function that throws).
function fakeDb(rpcResult: any = { data: true, error: null }) {
  const log = { tables: [] as string[], ops: [] as string[], rpc: [] as { fn: string; args: any }[] };
  const chain: any = {
    select: () => { log.ops.push('select'); return chain; },
    eq: () => chain,
    maybeSingle: () => Promise.resolve({ data: { value: { source: 'x' }, updated_at: '2026-11-08T00:00:00Z' }, error: null }),
    upsert: (row: any) => { log.ops.push(`upsert:${row.key}`); return Promise.resolve({ error: null }); },
  };
  const db = {
    from: (t: string) => { log.tables.push(t); return chain; },
    rpc: (fn: string, args: any) => { log.rpc.push({ fn, args }); return typeof rpcResult === 'function' ? rpcResult() : Promise.resolve(rpcResult); },
  };
  return { db, log };
}
const HERE: Place = { label: 'Near you', lat: 6.15, lon: 125.19, kind: 'here' };

const U = (q = '') => new URL(`https://x.supabase.co/functions/v1/weather-proxy${q}`);
const req = (auth?: string) => new Request('https://x/', { headers: auth ? { authorization: auth } : {} });
const staffOk = () => Promise.resolve('user-1');
const staffNo = () => Promise.reject(new Error('staff_access_denied'));

Deno.test('W: no params = Cascade at Bria Homes, not the GenSan city centre, and the old cache key', async () => {
  const r = await resolvePlace(req(), U(), null, staffOk);
  assertEquals(r, { place: CASCADE });
  assertEquals([CASCADE.lat, CASCADE.lon, CASCADE.kind], [6.1545, 125.1852, 'cascade']);
  assertEquals(CASCADE.label, 'Cascade, Bria Homes, General Santos');
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

Deno.test('W r3: RPC true = Here; called once with the verified user id and limit 60; app_settings never touched', async () => {
  const { db, log } = fakeDb({ data: true, error: null });
  assertEquals(await gateHere(db, HERE, 'user-1'), { place: HERE });
  assertEquals(log.rpc, [{ fn: 'weather_here_take_v1', args: { p_user_id: 'user-1', p_limit: 60 } }]);
  assertEquals(HERE_DAILY_LIMIT, 60);
  assertEquals(log.tables, [], 'no app_settings read or write for the limit');
});

Deno.test('W r3: RPC false = Cascade + note here_limit', async () => {
  const { db, log } = fakeDb({ data: false, error: null });
  assertEquals(await gateHere(db, HERE, 'user-1'), { place: CASCADE, note: 'here_limit' });
  assertEquals(log.tables, []);
});

Deno.test('W r3: RPC error, throw, or a non-boolean answer fails closed to Cascade, never an error', async () => {
  assertEquals(await gateHere(fakeDb({ data: null, error: { message: 'permission denied' } }).db, HERE, 'user-1'), { place: CASCADE });
  assertEquals(await gateHere(fakeDb(() => Promise.reject(new Error('network'))).db, HERE, 'user-1'), { place: CASCADE });
  assertEquals(await gateHere(fakeDb(() => { throw new Error('sync'); }).db, HERE, 'user-1'), { place: CASCADE });
  assertEquals((await gateHere(fakeDb({ data: 'true', error: null }).db, HERE, 'user-1')).place, CASCADE, 'only boolean true lets Here through');
  assertEquals(await gateHere(fakeDb().db, HERE, undefined), { place: CASCADE }, 'no verified user id = Cascade, no RPC');
});

Deno.test('W r3: anonymous/Cascade path unchanged - no RPC, reads and writes only weather_proxy_cache', async () => {
  const { db, log } = fakeDb();
  assertEquals(await gateHere(db, CASCADE, undefined), { place: CASCADE });
  assertEquals(log.rpc, []);
  const row = await readCache(db, CASCADE);
  assertEquals(row?.value, { source: 'x' });
  await writeCache(db, CASCADE, { source: 'y' });
  assertEquals(log.tables, ['app_settings', 'app_settings']);
  assertEquals(log.ops, ['select', 'upsert:weather_proxy_cache']);
});

Deno.test('W r3: a Here answer is never read from or written to app_settings', async () => {
  const { db, log } = fakeDb();
  assertEquals(await readCache(db, HERE), null);
  await writeCache(db, HERE, { source: 'y' });
  assertEquals(log.tables, []);
  assertEquals(log.ops, []);
});

Deno.test('W: index.ts wiring - staff check is read_operations, coords never in a log line, no GenSan centre left', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(src.includes("requireStaffAccess(r, 'read_operations', PROPERTY_ID)"));
  assert(!src.includes('GEN_SAN'), 'the city-centre constants are gone');
  assert(!/console\.\w+\([^)]*(place\.lat|place\.lon|p\.lat|p\.lon)/.test(src), 'no log line prints coordinates');
  assert(src.includes("lat: place.lat, lng: place.lon"), 'extras (hourly, aqi) follow the place');
  for (const k of ['cached: true, location: LOCATION, ...extra', 'cached: false, location: LOCATION, ...extra', 'stale: true, location: LOCATION, ...extra']) assert(src.includes(k), k);
  // r3 H1: the handler goes through the gated helpers only; no direct app_settings call or old Here key is left.
  assert(src.includes('gateHere(db, resolved.place, resolved.userId)') && src.includes('readCache(db, place)') && src.includes('writeCache(db, place, payload)'));
  for (const gone of ["from('app_settings')", 'weather_proxy_here_usage', 'weather_proxy_cache:']) assert(!src.includes(gone), gone);
  const place = await Deno.readTextFile(new URL('./place.ts', import.meta.url));
  for (const gone of ['weather_proxy_here_usage', 'weather_proxy_cache:']) assert(!place.includes(gone), `place.ts: ${gone}`);
});
