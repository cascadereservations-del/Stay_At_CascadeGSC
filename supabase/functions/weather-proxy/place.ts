// weather-proxy place (s112 lane W): which location a request gets. Pure except the db calls passed in: the staff check is passed in too.
// No params (the guest guide, every older caller) = Cascade. lat/lon = "Here", only for a signed-in staff user; anyone else gets Cascade.
// Coordinates are rounded to 2 decimals (~1.1 km). s112 fix round 3 (H1): a "Here" answer is never cached or stored anywhere
// (app_settings is anon-readable); the daily limit lives in the locked table behind public.weather_here_take_v1 (service role only).
// deno-lint-ignore-file no-explicit-any

export type Place = { label: string; lat: number; lon: number; kind: 'cascade' | 'here' };

export const CASCADE: Place = { label: 'Cascade, Bria Homes, General Santos', lat: 6.1545, lon: 125.1852, kind: 'cascade' };
export const CACHE_KEY = 'weather_proxy_cache'; // Cascade keeps the old key so nothing that reads it breaks
export const HERE_DAILY_LIMIT = 60;
export const HERE_TAKE_RPC = 'weather_here_take_v1';
const PH_BOX = { latMin: 4.5, latMax: 21.5, lonMin: 116, lonMax: 127 };

const round2 = (n: number) => Math.round(n * 100) / 100;

/** lat/lon from the query string, else the JSON body; null when neither carries either. */
export function readCoords(url: URL, body: any): { lat: unknown; lon: unknown } | null {
  const q = url.searchParams;
  if (q.has('lat') || q.has('lon')) return { lat: q.get('lat'), lon: q.get('lon') };
  if (body && typeof body === 'object' && (body.lat != null || body.lon != null)) return { lat: body.lat, lon: body.lon };
  return null;
}

/** Validated, rounded "Here" place, or why not. Rounding happens before the Philippines box check. */
export function parseHere(lat: unknown, lon: unknown): Place | 'invalid_coords' | 'out_of_area' {
  const toNum = (v: unknown) => (typeof v === 'number' || (typeof v === 'string' && v.trim() !== '') ? Number(v) : NaN);
  const a = toNum(lat), b = toNum(lon);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return 'invalid_coords';
  const la = round2(a), lo = round2(b);
  if (la < PH_BOX.latMin || la > PH_BOX.latMax || lo < PH_BOX.lonMin || lo > PH_BOX.lonMax) return 'out_of_area';
  return { label: 'Near you', lat: la, lon: lo, kind: 'here' };
}

export type Resolved = { place: Place; userId?: string } | { error: 'invalid_coords' | 'out_of_area'; status: 400 };

/**
 * The place for this request. verifyStaff resolves the staff user id or throws; it is called only when lat/lon were sent with an
 * Authorization header. Every failure of the staff path (no header, anon key, expired session, not staff) gives Cascade, never an error,
 * so the guest guide cannot break. Only a verified staff user with bad coordinates gets a 400.
 */
export async function resolvePlace(req: Request, url: URL, body: any, verifyStaff: (req: Request) => Promise<string>): Promise<Resolved> {
  const c = readCoords(url, body);
  if (!c || !req.headers.get('authorization')) return { place: CASCADE };
  let userId: string;
  try { userId = await verifyStaff(req); } catch { return { place: CASCADE }; }
  const here = parseHere(c.lat, c.lon);
  if (typeof here === 'string') return { error: here, status: 400 };
  return { place: here, userId };
}

/**
 * One "Here" call against the daily limit (60 per staff user per Manila day, counted by the RPC). true -> the Here place;
 * false -> Cascade + note 'here_limit'; an RPC error or throw fails closed to Cascade with no note, never an error to the user.
 */
export async function gateHere(db: any, place: Place, userId: string | undefined): Promise<{ place: Place; note?: string }> {
  if (place.kind !== 'here') return { place };
  if (!userId) return { place: CASCADE };
  try {
    const { data, error } = await db.rpc(HERE_TAKE_RPC, { p_user_id: userId, p_limit: HERE_DAILY_LIMIT });
    if (error) { console.error('weather-proxy: here limit rpc failed'); return { place: CASCADE }; }
    return data === true ? { place } : { place: CASCADE, note: 'here_limit' };
  } catch {
    console.error('weather-proxy: here limit rpc threw');
    return { place: CASCADE };
  }
}

/** Cascade's cached row (value, updated_at) or null. A "Here" place never reads app_settings. */
export async function readCache(db: any, place: Place): Promise<{ value: any; updated_at: string } | null> {
  if (place.kind !== 'cascade') return null;
  const { data } = await db.from('app_settings').select('value, updated_at').eq('key', CACHE_KEY).maybeSingle();
  return data ?? null;
}

/** Store Cascade's fresh payload. A "Here" payload is never written. */
export async function writeCache(db: any, place: Place, payload: any): Promise<void> {
  if (place.kind !== 'cascade') return;
  await db.from('app_settings').upsert({ key: CACHE_KEY, value: payload, updated_at: new Date().toISOString() }, { onConflict: 'key' });
}
