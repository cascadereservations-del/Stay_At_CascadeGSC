// weather-proxy place (s112 lane W): which location a request gets. Pure, no network: the staff check is passed in.
// No params (the guest guide, every older caller) = Cascade. lat/lon = "Here", only for a signed-in staff user; anyone else gets Cascade.
// Coordinates are rounded to 2 decimals (~1.1 km) and live only in the cache key; they are never logged or stored anywhere else.
// deno-lint-ignore-file no-explicit-any

export type Place = { label: string; lat: number; lon: number; kind: 'cascade' | 'here' };

export const CASCADE: Place = { label: 'Cascade, Bria Homes, General Santos', lat: 6.1545, lon: 125.1852, kind: 'cascade' };
export const CACHE_KEY = 'weather_proxy_cache'; // Cascade keeps the old key so nothing that reads it breaks
export const CELL_PREFIX = 'weather_proxy_cache:';
export const USAGE_KEY = 'weather_proxy_here_usage';
export const MAX_CELLS = 50;
export const HERE_DAILY_LIMIT = 60;
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

export const cacheKey = (p: Place) => (p.kind === 'cascade' ? CACHE_KEY : `${CELL_PREFIX}${p.lat.toFixed(2)},${p.lon.toFixed(2)}`);

/** Cell keys beyond the newest `max`, oldest first out. The Cascade key never matches the prefix, so it is never dropped. */
export function cellsToDrop(rows: { key: string; updated_at: string }[], max = MAX_CELLS): string[] {
  return rows
    .filter((r) => r.key.startsWith(CELL_PREFIX))
    .sort((x, y) => Date.parse(y.updated_at) - Date.parse(x.updated_at))
    .slice(max)
    .map((r) => r.key);
}

/** One more "Here" call for userId on Manila date `day`. The usage row resets when the day changes. */
export function countHere(usage: any, userId: string, day: string, limit = HERE_DAILY_LIMIT): { usage: { date: string; counts: Record<string, number> }; allowed: boolean } {
  const counts: Record<string, number> = usage?.date === day && usage?.counts && typeof usage.counts === 'object' ? { ...usage.counts } : {};
  const used = Number(counts[userId] ?? 0) || 0;
  if (used >= limit) return { usage: { date: day, counts }, allowed: false };
  counts[userId] = used + 1;
  return { usage: { date: day, counts }, allowed: true };
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
