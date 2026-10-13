// Lane B (s81): pure weather helpers shared by weather-proxy and rain-alert. No network, no clock: callers pass nowMs.
// RAIN_THRESHOLD is the ONE place the "rain is likely" percentage lives (rain-alert alerts on it, weather-proxy's rain_watch uses it).
// deno-lint-ignore-file no-explicit-any

export const RAIN_THRESHOLD = 70; // % probability

// s82 lane W: `temp` (deg C) added to each hour row; every older key keeps its name and meaning.
export type B_HourRow = { time: string; rain_chance_pct: number; mm: number | null; code: number | null; temp: number | null };
/** Rows the weather screen shows. The 12-hour reading (rain_watch, rain-alert) keeps its own cap below. */
export const B_HOURS_SHOWN = 24, B_HOURS_RAIN_WATCH = 12;
export type B_RainWatch = { from: string; to: string; peak_pct: number };

const HOUR = 3_600_000;

/** Google Weather type (CLEAR, LIGHT_RAIN, SCATTERED_THUNDERSTORMS ...) to the nearest WMO weather code; null when unknown. */
export function B_googleTypeToCode(type: unknown): number | null {
  const t = String(type ?? '').toUpperCase();
  if (!t) return null;
  if (t.includes('THUNDER')) return 95;
  if (t.includes('DRIZZLE')) return 51;
  if (t.includes('HEAVY') && (t.includes('RAIN') || t.includes('SHOWER'))) return 65;
  if (t.includes('SHOWER')) return 80;
  if (t.includes('LIGHT_RAIN')) return 61;
  if (t.includes('RAIN')) return 63;
  if (t.includes('FOG') || t.includes('HAZE') || t.includes('MIST')) return 45;
  if (t === 'MOSTLY_CLEAR') return 1;
  if (t === 'CLEAR' || t === 'SUNNY') return 0;
  if (t === 'PARTLY_CLOUDY') return 2;
  if (t === 'MOSTLY_CLOUDY' || t === 'CLOUDY') return 3;
  return null;
}

/** PirateWeather icon name to the nearest WMO code; null when unknown. */
export function B_iconToCode(icon: unknown): number | null {
  switch (String(icon ?? '')) {
    case 'thunderstorm': return 95;
    case 'rain': return 63;
    case 'sleet': return 68;
    case 'snow': return 71;
    case 'fog': return 45;
    case 'cloudy': case 'wind': return 3;
    case 'partly-cloudy-day': case 'partly-cloudy-night': return 2;
    case 'clear-day': case 'clear-night': return 0;
    default: return null;
  }
}

/** True when `nowSec` (unix seconds) is between sunrise and sunset; null when either is missing. */
export function B_isDay(nowSec: unknown, sunriseSec: unknown, sunsetSec: unknown): boolean | null {
  const n = Number(nowSec), a = Number(sunriseSec), b = Number(sunsetSec);
  if (![n, a, b].every(Number.isFinite) || !sunriseSec || !sunsetSec) return null;
  return n >= a && n < b;
}

/** A condition sentence ("Partly cloudy", "Light rain") to a WMO code. Same reading as weather-proxy's descToEmoji. */
export function B_textToCode(desc: unknown): number | null {
  const d = String(desc ?? '').toLowerCase();
  if (!d) return null;
  if (d.includes('thunder') || d.includes('storm')) return 95;
  if (d.includes('drizzle')) return 51;
  if (d.includes('heavy rain')) return 65;
  if (d.includes('shower')) return 80;
  if (d.includes('light rain') || d.includes('slight rain')) return 61;
  if (d.includes('rain')) return 63;
  if (d.includes('fog') || d.includes('mist')) return 45;
  if (d.includes('mostly cloudy') || d.includes('overcast')) return 3;
  if (d.includes('partly cloudy')) return 2;
  if (d.includes('mainly clear') || d.includes('mostly clear') || d.includes('mostly sunny')) return 1;
  if (d.includes('cloudy')) return 3;
  if (d.includes('clear') || d.includes('sunny')) return 0;
  return null;
}

const round1 = (n: number) => Math.round(n * 10) / 10;
const B_tempC = (v: unknown) => (v != null && Number.isFinite(Number(v)) ? Math.round(Number(v)) : null);
const pct = (v: unknown) => Math.max(0, Math.min(100, Math.round(Number(v ?? 0)) || 0));

/** The next `n` hourly rows that have not fully passed at nowMs, soonest first. */
function nextHours(rows: B_HourRow[], nowMs: number, n: number): B_HourRow[] {
  return rows
    .filter((r) => Number.isFinite(Date.parse(r.time)) && Date.parse(r.time) + HOUR > nowMs)
    .sort((a, b) => Date.parse(a.time) - Date.parse(b.time))
    .slice(0, n);
}

/** Google Weather forecast/hours:lookup body -> rows. interval.startTime is UTC; displayDateTime (Manila wall clock) is the fallback. */
export function B_googleHours(data: any, nowMs: number, n = B_HOURS_SHOWN): B_HourRow[] {
  const out: B_HourRow[] = [];
  for (const h of (data?.forecastHours ?? []) as any[]) {
    let iso: string | null = null;
    const start = h?.interval?.startTime;
    if (typeof start === 'string' && Number.isFinite(Date.parse(start))) iso = new Date(start).toISOString();
    else if (h?.displayDateTime) {
      const d = h.displayDateTime, p = (x: unknown) => String(Number(x ?? 0)).padStart(2, '0');
      const t = Date.parse(`${d.year}-${p(d.month)}-${p(d.day)}T${p(d.hours)}:00:00+08:00`);
      if (Number.isFinite(t)) iso = new Date(t).toISOString();
    }
    if (!iso) continue;
    const q = h?.precipitation?.qpf?.quantity;
    out.push({
      time: iso,
      rain_chance_pct: pct(h?.precipitation?.probability?.percent),
      mm: q != null && Number.isFinite(Number(q)) ? round1(Number(q)) : null,
      code: B_googleTypeToCode(h?.weatherCondition?.type),
      temp: B_tempC(h?.temperature?.degrees),
    });
  }
  return nextHours(out, nowMs, n);
}

/** Open-Meteo forecast body requested with timezone=Asia/Manila and hourly=precipitation_probability,precipitation,weather_code. */
export function B_openMeteoHours(data: any, nowMs: number, n = B_HOURS_SHOWN): B_HourRow[] {
  const h = data?.hourly;
  const times: string[] = h?.time ?? [];
  const out: B_HourRow[] = [];
  times.forEach((t, i) => {
    const ms = Date.parse(/[zZ]|[+-]\d\d:\d\d$/.test(t) ? t : `${t}:00+08:00`);
    if (!Number.isFinite(ms)) return;
    const mm = h?.precipitation?.[i];
    const code = h?.weather_code?.[i];
    out.push({
      time: new Date(ms).toISOString(),
      rain_chance_pct: pct(h?.precipitation_probability?.[i]),
      mm: mm != null && Number.isFinite(Number(mm)) ? round1(Number(mm)) : null,
      code: code != null && Number.isFinite(Number(code)) ? Number(code) : null,
      temp: B_tempC(h?.temperature_2m?.[i]),
    });
  });
  return nextHours(out, nowMs, n);
}

/** First to last hour at or above the threshold (rain-alert's reading), end = the end of the last hour. Null when none. */
export function B_rainWatch(rows: B_HourRow[], threshold = RAIN_THRESHOLD): B_RainWatch | null {
  const hit = rows.filter((r) => r.rain_chance_pct >= threshold);
  if (!hit.length) return null;
  return {
    from: hit[0].time,
    to: new Date(Date.parse(hit[hit.length - 1].time) + HOUR).toISOString(),
    peak_pct: Math.max(...hit.map((r) => r.rain_chance_pct)),
  };
}

/** Open-Meteo air-quality body (current=us_aqi) -> integer or null. */
export function B_aqi(data: any): number | null {
  const v = data?.current?.us_aqi;
  return v != null && Number.isFinite(Number(v)) ? Math.round(Number(v)) : null;
}

/** The keys weather-proxy ADDS to its response. Existing keys are never touched.
 *  Open-Meteo hours are the source (free, no key); Google hours are used ONLY when Open-Meteo gave nothing (fallback, may cost). */
export type B_Extras = { hourly: B_HourRow[]; hourly_source: 'open_meteo' | 'google' | null; aqi: number | null; rain_watch: B_RainWatch | null; code: number | null };
export function B_extras(src: { google?: any; openMeteo?: any; aqi?: any }, nowMs: number, conditionText: unknown): B_Extras {
  let hourly = src.openMeteo ? B_openMeteoHours(src.openMeteo, nowMs) : [];
  let hourly_source: B_Extras['hourly_source'] = hourly.length ? 'open_meteo' : null;
  if (!hourly.length && src.google) {
    hourly = B_googleHours(src.google, nowMs);
    hourly_source = hourly.length ? 'google' : null;
  }
  return {
    hourly,
    hourly_source,
    aqi: B_aqi(src.aqi),
    rain_watch: B_rainWatch(hourly.slice(0, B_HOURS_RAIN_WATCH)), // 12 hours, as before 24 rows were shown
    code: hourly[0]?.code ?? B_textToCode(conditionText),
  };
}

export const B_LAT = 6.1164, B_LNG = 125.1716;
export const B_OM_HOURS_URL = (lat = B_LAT, lng = B_LNG) =>
  `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lng}&hourly=precipitation_probability,precipitation,weather_code,temperature_2m&timezone=Asia%2FManila&forecast_days=2`;
export const B_AQI_URL = (lat = B_LAT, lng = B_LNG) =>
  `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lat}&longitude=${lng}&current=us_aqi&timezone=Asia%2FManila`;
export const B_GOOGLE_HOURS_URL = (key: string, lat = B_LAT, lng = B_LNG) =>
  `https://weather.googleapis.com/v1/forecast/hours:lookup?key=${key}&location.latitude=${lat}&location.longitude=${lng}&hours=24`;

type FetchFn = (url: string, init?: { signal?: AbortSignal }) => Promise<{ ok: boolean; status: number; json(): Promise<any> }>;

/** GET JSON or null. Resolves at capMs even when the upstream hangs (and when fetch ignores the abort signal). Never throws. */
export async function B_getJson(url: string, label: string, capMs: number, fetchFn: FetchFn = fetch as unknown as FetchFn): Promise<any | null> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const cap = new Promise<null>((resolve) => { timer = setTimeout(() => resolve(null), capMs); });
    const call = (async () => {
      const res = await fetchFn(url, { signal: AbortSignal.timeout(capMs) });
      if (!res.ok) { console.warn(`weather-proxy: ${label} non-ok`, res.status); return null; }
      return await res.json();
    })().catch((err) => { console.warn(`weather-proxy: ${label} failed`, String(err)); return null; });
    return await Promise.race([call, cap]);
  } catch (err) {
    console.warn(`weather-proxy: ${label} failed`, String(err));
    return null;
  } finally { clearTimeout(timer); }
}

/**
 * Everything the response adds, in parallel, each call capped at capMs and the whole at totalMs, so the base response is never delayed
 * beyond totalMs. Open-Meteo hours + air quality start together; Google hours are called only if Open-Meteo gave no hours (and a key exists).
 * Never throws: a failed or slow extra leaves its keys empty and the caller's base payload intact.
 */
export async function B_fetchExtras(
  nowMs: number, conditionText: unknown,
  o: { googleKey?: string; fetchFn?: FetchFn; capMs?: number; totalMs?: number } = {},
): Promise<B_Extras> {
  const capMs = o.capMs ?? 3500, totalMs = o.totalMs ?? 4000;
  const got: { openMeteo?: any; google?: any; aqi?: any } = {};
  const run = async () => {
    const aqiP = B_getJson(B_AQI_URL(), 'air-quality', capMs, o.fetchFn).then((v) => { got.aqi = v; });
    got.openMeteo = await B_getJson(B_OM_HOURS_URL(), 'open-meteo hours', capMs, o.fetchFn);
    if (o.googleKey && !B_openMeteoHours(got.openMeteo, nowMs).length) got.google = await B_getJson(B_GOOGLE_HOURS_URL(o.googleKey), 'google hours', capMs, o.fetchFn);
    await aqiP;
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([run().catch(() => {}), new Promise<void>((resolve) => { timer = setTimeout(resolve, totalMs); })]);
  } finally { clearTimeout(timer); }
  return B_extras(got, nowMs, conditionText);
}
