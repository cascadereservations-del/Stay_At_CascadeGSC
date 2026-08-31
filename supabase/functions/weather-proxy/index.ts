// weather-proxy v4
// Sources: PirateWeather (primary) → Google Weather (secondary) → Open-Meteo (fallback)
// Cache: 15 minutes in app_settings

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';

const SUPABASE_URL   = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const PIRATE_KEY     = Deno.env.get('PIRATE_WEATHER_API_KEY') ?? '';
const GOOGLE_KEY     = Deno.env.get('GOOGLE_WEATHER_API_KEY') ?? '';
const GEN_SAN_LAT    = 6.1164;
const GEN_SAN_LNG    = 125.1716;
const LOCATION       = 'General Santos City, PH';
const CACHE_KEY      = 'weather_proxy_cache';
const CACHE_TTL_MS   = 15 * 60 * 1000; // 15 minutes

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};
const JSON_H = { 'Content-Type': 'application/json', ...CORS };

function getManilaDateStr(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}
function addDays(dateStr: string, n: number): string {
  const d = new Date(dateStr + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
function dayLabel(dateStr: string, today: string): string {
  if (dateStr === today)             return 'Today';
  if (dateStr === addDays(today, 1)) return 'Tomorrow';
  return new Date(dateStr + 'T00:00:00Z').toLocaleDateString('en-US', { timeZone: 'UTC', weekday: 'short' });
}
function uvLabel(uv: number): string {
  if (uv <= 2)  return 'Low';
  if (uv <= 5)  return 'Moderate';
  if (uv <= 7)  return 'High';
  if (uv <= 10) return 'Very High';
  return 'Extreme';
}
function unixToManilaTime(ts: number): string {
  return new Date(ts * 1000).toLocaleTimeString('en-US', {
    timeZone: 'Asia/Manila', hour: 'numeric', minute: '2-digit', hour12: true,
  }).replace(':00 ', ' ');
}
function unixToDateStr(ts: number): string {
  return new Date(ts * 1000).toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}

function iconToEmoji(icon: string): string {
  switch (icon) {
    case 'thunderstorm':         return '⛈️';
    case 'rain':                 return '🌧️';
    case 'sleet':                return '🌨️';
    case 'snow':                 return '❄️';
    case 'fog':                  return '🌫️';
    case 'wind':                 return '💨';
    case 'cloudy':               return '☁️';
    case 'partly-cloudy-day':
    case 'partly-cloudy-night':  return '⛅';
    case 'clear-day':            return '☀️';
    case 'clear-night':          return '🌙';
    default:                     return '🌤️';
  }
}

function descToEmoji(desc: string): string {
  const d = (desc ?? '').toLowerCase();
  if (d.includes('thunder') || d.includes('storm')) return '⛈️';
  if (d.includes('heavy rain'))                      return '🌧️';
  if (d.includes('rain') || d.includes('shower') || d.includes('drizzle')) return '🌦️';
  if (d.includes('fog') || d.includes('mist'))       return '🌫️';
  if (d.includes('mostly cloudy'))  return '🌥️';
  if (d.includes('partly cloudy'))  return '⛅';
  if (d.includes('cloudy') || d.includes('overcast')) return '☁️';
  if (d.includes('clear') || d.includes('sunny'))    return '☀️';
  return '🌤️';
}

// ── PirateWeather ──────────────────────────────────────────────────────────
async function fetchPirateWeather(today: string): Promise<any | null> {
  if (!PIRATE_KEY) { console.warn('weather-proxy: PIRATE_WEATHER_API_KEY not set'); return null; }
  try {
    const url = `https://api.pirateweather.net/forecast/${PIRATE_KEY}/${GEN_SAN_LAT},${GEN_SAN_LNG}?exclude=minutely,hourly,alerts&units=si`;
    const res = await fetch(url, { signal: AbortSignal.timeout(10_000) });
    if (!res.ok) { console.error('PirateWeather non-ok:', res.status); return null; }
    const d = await res.json();

    const cur    = d?.currently ?? {};
    const days   = (d?.daily?.data ?? []) as any[];
    const today0 = days[0] ?? {};

    const current = {
      temp:        Math.round(Number(cur.temperature ?? 0)),
      feels_like:  Math.round(Number(cur.apparentTemperature ?? 0)),
      description: String(cur.summary ?? ''),
      emoji:       iconToEmoji(String(cur.icon ?? '')),
      humidity:    Math.round(Number(cur.humidity ?? 0) * 100),
      dew_point:   Math.round(Number(cur.dewPoint ?? 0)),
      visibility:  cur.visibility != null ? Math.round(Number(cur.visibility) * 10) / 10 : null, // km
      uv_index:    Math.round(Number(cur.uvIndex ?? 0)),
      uv_label:    uvLabel(Math.round(Number(cur.uvIndex ?? 0))),
      cloud_cover: cur.cloudCover != null ? Math.round(Number(cur.cloudCover) * 100) : null,
      rain_prob:   Math.round(Number(cur.precipProbability ?? 0) * 100),
      wind_kph:    Math.round(Number(cur.windSpeed ?? 0) * 3.6),
      wind_gust_kph: cur.windGust != null ? Math.round(Number(cur.windGust) * 3.6) : null,
      wind_dir:    cur.windBearing != null ? Math.round(Number(cur.windBearing)) : null,
      pressure_mb: cur.pressure != null ? Math.round(Number(cur.pressure)) : null,
      sunrise:     today0.sunriseTime ? unixToManilaTime(today0.sunriseTime) : null,
      sunset:      today0.sunsetTime  ? unixToManilaTime(today0.sunsetTime)  : null,
      // Today's high/low from daily[0]
      today_high:  today0.temperatureHigh != null ? Math.round(Number(today0.temperatureHigh)) : null,
      today_low:   today0.temperatureLow  != null ? Math.round(Number(today0.temperatureLow))  : null,
    };

    const forecast = days.slice(0, 5).map((day: any, i: number) => {
      const date = day.time ? unixToDateStr(day.time) : addDays(today, i);
      return {
        date,
        label:          dayLabel(date, today),
        high:           Math.round(Number(day.temperatureHigh ?? 0)),
        low:            Math.round(Number(day.temperatureLow  ?? 0)),
        feels_like_high: day.apparentTemperatureHigh != null ? Math.round(Number(day.apparentTemperatureHigh)) : null,
        feels_like_low:  day.apparentTemperatureLow  != null ? Math.round(Number(day.apparentTemperatureLow))  : null,
        description:    String(day.summary ?? ''),
        emoji:          iconToEmoji(String(day.icon ?? '')),
        rain_prob:      Math.round(Number(day.precipProbability ?? 0) * 100),
        rain_mm:        day.precipAccumulation != null ? Math.round(Number(day.precipAccumulation) * 10) / 10 : null,
        humidity:       day.humidity != null ? Math.round(Number(day.humidity) * 100) : null,
        uv_index:       day.uvIndex != null ? Math.round(Number(day.uvIndex)) : null,
        uv_label:       day.uvIndex != null ? uvLabel(Math.round(Number(day.uvIndex))) : null,
        wind_kph:       day.windSpeed != null ? Math.round(Number(day.windSpeed) * 3.6) : null,
        wind_gust_kph:  day.windGust  != null ? Math.round(Number(day.windGust)  * 3.6) : null,
        thunder_prob:   String(day.icon ?? '') === 'thunderstorm' ? 80 : 0,
        sunrise:        day.sunriseTime ? unixToManilaTime(day.sunriseTime) : null,
        sunset:         day.sunsetTime  ? unixToManilaTime(day.sunsetTime)  : null,
      };
    });

    return { current, forecast, source: 'pirate_weather' };
  } catch (err) {
    console.error('fetchPirateWeather failed:', String(err));
    return null;
  }
}

// ── Google Weather ─────────────────────────────────────────────────────────
function utcToManilaTime(utcStr: string): string {
  try {
    return new Date(utcStr).toLocaleTimeString('en-US', {
      timeZone: 'Asia/Manila', hour: 'numeric', minute: '2-digit', hour12: true,
    }).replace(':00 ', ' ');
  } catch { return ''; }
}

async function fetchGoogleWeather(today: string): Promise<any | null> {
  if (!GOOGLE_KEY) { console.warn('weather-proxy: GOOGLE_WEATHER_API_KEY not set'); return null; }
  try {
    const base = 'https://weather.googleapis.com/v1';
    const loc  = `location.latitude=${GEN_SAN_LAT}&location.longitude=${GEN_SAN_LNG}`;
    const k    = `key=${GOOGLE_KEY}`;

    const [curRes, dayRes] = await Promise.all([
      fetch(`${base}/currentConditions:lookup?${k}&${loc}`, { signal: AbortSignal.timeout(8_000) }),
      fetch(`${base}/forecast/days:lookup?${k}&${loc}&days=5`, { signal: AbortSignal.timeout(8_000) }),
    ]);

    if (!curRes.ok) { console.error('Google Weather current error:', curRes.status); return null; }
    const cur = await curRes.json();
    const day = dayRes.ok ? await dayRes.json() : null;

    const today0  = (day?.forecastDays ?? [])[0];
    const sunrise = today0?.sunEvents?.sunriseTime ? utcToManilaTime(today0.sunEvents.sunriseTime) : null;
    const sunset  = today0?.sunEvents?.sunsetTime  ? utcToManilaTime(today0.sunEvents.sunsetTime)  : null;

    const current = {
      temp:          Math.round(Number(cur.temperature?.degrees ?? 0)),
      feels_like:    Math.round(Number(cur.feelsLikeTemperature?.degrees ?? 0)),
      description:   String(cur.weatherCondition?.description?.text ?? ''),
      emoji:         descToEmoji(String(cur.weatherCondition?.description?.text ?? '')),
      humidity:      Math.round(Number(cur.relativeHumidity ?? 0)),
      dew_point:     cur.dewPoint?.degrees != null ? Math.round(Number(cur.dewPoint.degrees)) : null,
      visibility:    cur.visibility?.distance != null ? Math.round(Number(cur.visibility.distance) / 100) / 10 : null,
      uv_index:      Math.round(Number(cur.uvIndex ?? 0)),
      uv_label:      uvLabel(Math.round(Number(cur.uvIndex ?? 0))),
      cloud_cover:   cur.cloudCover != null ? Math.round(Number(cur.cloudCover)) : null,
      rain_prob:     Math.round(Number(cur.precipitation?.probability?.percent ?? 0)),
      wind_kph:      Math.round(Number(cur.wind?.speed?.value ?? 0) * 3.6),
      wind_gust_kph: cur.wind?.gust?.value != null ? Math.round(Number(cur.wind.gust.value) * 3.6) : null,
      wind_dir:      cur.wind?.direction?.degrees != null ? Math.round(Number(cur.wind.direction.degrees)) : null,
      pressure_mb:   cur.pressureAtSeaLevel?.value != null ? Math.round(Number(cur.pressureAtSeaLevel.value)) : null,
      sunrise,
      sunset,
      today_high:    today0?.maxTemperature?.degrees != null ? Math.round(Number(today0.maxTemperature.degrees)) : null,
      today_low:     today0?.minTemperature?.degrees != null ? Math.round(Number(today0.minTemperature.degrees)) : null,
    };

    const forecast = (day?.forecastDays ?? []).slice(0, 5).map((fd: any, i: number) => {
      const date = addDays(today, i);
      const desc = String(fd.daytimeForecast?.weatherCondition?.description?.text ?? '');
      return {
        date,
        label:          dayLabel(date, today),
        high:           Math.round(Number(fd.maxTemperature?.degrees ?? 0)),
        low:            Math.round(Number(fd.minTemperature?.degrees ?? 0)),
        feels_like_high: fd.feelsLikeMaxTemperature?.degrees != null ? Math.round(Number(fd.feelsLikeMaxTemperature.degrees)) : null,
        feels_like_low:  fd.feelsLikeMinTemperature?.degrees != null ? Math.round(Number(fd.feelsLikeMinTemperature.degrees)) : null,
        description:    desc,
        emoji:          descToEmoji(desc),
        rain_prob:      Math.round(Number(fd.daytimeForecast?.precipitation?.probability?.percent ?? 0)),
        rain_mm:        fd.daytimeForecast?.precipitation?.qpf?.quantity != null ? Math.round(Number(fd.daytimeForecast.precipitation.qpf.quantity) * 10) / 10 : null,
        humidity:       fd.daytimeForecast?.relativeHumidity != null ? Math.round(Number(fd.daytimeForecast.relativeHumidity)) : null,
        uv_index:       fd.maxUvIndex != null ? Math.round(Number(fd.maxUvIndex)) : null,
        uv_label:       fd.maxUvIndex != null ? uvLabel(Math.round(Number(fd.maxUvIndex))) : null,
        wind_kph:       fd.daytimeForecast?.wind?.speed?.value != null ? Math.round(Number(fd.daytimeForecast.wind.speed.value) * 3.6) : null,
        wind_gust_kph:  null,
        thunder_prob:   Math.round(Number(fd.daytimeForecast?.thunderstormProbability ?? 0)),
        sunrise:        fd.sunEvents?.sunriseTime ? utcToManilaTime(fd.sunEvents.sunriseTime) : null,
        sunset:         fd.sunEvents?.sunsetTime  ? utcToManilaTime(fd.sunEvents.sunsetTime)  : null,
      };
    });

    return { current, forecast, source: 'google_weather' };
  } catch (err) {
    console.error('fetchGoogleWeather failed:', String(err));
    return null;
  }
}

// ── Open-Meteo fallback ────────────────────────────────────────────────────
function omCodeToEmoji(code: number): string {
  if ([95,96,99].includes(code)) return '⛈️';
  if ([65,82].includes(code))    return '🌧️';
  if ([61,63,80,81].includes(code)) return '🌦️';
  if ([51,53,55].includes(code)) return '🌦️';
  if ([45,48].includes(code))    return '🌫️';
  if (code === 3)                return '☁️';
  if (code === 2)                return '⛅';
  if (code === 1)                return '🌤️';
  if (code === 0)                return '☀️';
  return '🌤️';
}
function omCodeToDesc(code: number): string {
  const m: Record<number,string> = {
    0:'Clear sky',1:'Mainly clear',2:'Partly cloudy',3:'Overcast',
    45:'Fog',48:'Rime fog',51:'Light drizzle',53:'Drizzle',55:'Dense drizzle',
    61:'Slight rain',63:'Rain',65:'Heavy rain',80:'Rain showers',81:'Rain showers',82:'Violent showers',
    95:'Thunderstorm',96:'Thunderstorm',99:'Thunderstorm'
  };
  return m[code] ?? 'Cloudy';
}

async function fetchOpenMeteo(today: string): Promise<any | null> {
  try {
    const url = [
      'https://api.open-meteo.com/v1/forecast',
      `?latitude=${GEN_SAN_LAT}&longitude=${GEN_SAN_LNG}`,
      '&current=temperature_2m,apparent_temperature,weather_code,precipitation_probability,',
      'wind_speed_10m,wind_direction_10m,relative_humidity_2m,surface_pressure',
      '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,',
      'uv_index_max,wind_speed_10m_max,sunrise,sunset',
      '&timezone=Asia%2FManila&forecast_days=5',
    ].join('');
    const res = await fetch(url, { signal: AbortSignal.timeout(10_000) });
    if (!res.ok) { console.error('Open-Meteo non-ok:', res.status); return null; }
    const d = await res.json();
    const c = d.current ?? {};
    const dly = d.daily ?? {};

    const current = {
      temp:        Math.round(Number(c.temperature_2m ?? 0)),
      feels_like:  Math.round(Number(c.apparent_temperature ?? 0)),
      description: omCodeToDesc(c.weather_code ?? 0),
      emoji:       omCodeToEmoji(c.weather_code ?? 0),
      humidity:    Math.round(Number(c.relative_humidity_2m ?? 0)),
      dew_point:   null,
      visibility:  null,
      uv_index:    dly.uv_index_max?.[0] != null ? Math.round(Number(dly.uv_index_max[0])) : null,
      uv_label:    dly.uv_index_max?.[0] != null ? uvLabel(Math.round(Number(dly.uv_index_max[0]))) : null,
      cloud_cover: null,
      rain_prob:   Math.round(Number(c.precipitation_probability ?? 0)),
      wind_kph:    Math.round(Number(c.wind_speed_10m ?? 0)),
      wind_gust_kph: null,
      wind_dir:    c.wind_direction_10m != null ? Math.round(Number(c.wind_direction_10m)) : null,
      pressure_mb: c.surface_pressure != null ? Math.round(Number(c.surface_pressure)) : null,
      sunrise:     dly.sunrise?.[0] ? new Date(dly.sunrise[0]).toLocaleTimeString('en-US',{hour:'numeric',minute:'2-digit',hour12:true}).replace(':00 ',' ') : null,
      sunset:      dly.sunset?.[0]  ? new Date(dly.sunset[0]).toLocaleTimeString('en-US',{hour:'numeric',minute:'2-digit',hour12:true}).replace(':00 ',' ') : null,
      today_high:  dly.temperature_2m_max?.[0] != null ? Math.round(Number(dly.temperature_2m_max[0])) : null,
      today_low:   dly.temperature_2m_min?.[0] != null ? Math.round(Number(dly.temperature_2m_min[0])) : null,
    };

    const forecast = (dly.time ?? []).slice(0, 5).map((date: string, i: number) => ({
      date,
      label:          dayLabel(date, today),
      high:           dly.temperature_2m_max?.[i] != null ? Math.round(Number(dly.temperature_2m_max[i])) : 0,
      low:            dly.temperature_2m_min?.[i] != null ? Math.round(Number(dly.temperature_2m_min[i])) : 0,
      feels_like_high: null,
      feels_like_low:  null,
      description:    omCodeToDesc(dly.weather_code?.[i] ?? 0),
      emoji:          omCodeToEmoji(dly.weather_code?.[i] ?? 0),
      rain_prob:      dly.precipitation_probability_max?.[i] != null ? Math.round(Number(dly.precipitation_probability_max[i])) : 0,
      rain_mm:        null,
      humidity:       null,
      uv_index:       dly.uv_index_max?.[i] != null ? Math.round(Number(dly.uv_index_max[i])) : null,
      uv_label:       dly.uv_index_max?.[i] != null ? uvLabel(Math.round(Number(dly.uv_index_max[i]))) : null,
      wind_kph:       dly.wind_speed_10m_max?.[i] != null ? Math.round(Number(dly.wind_speed_10m_max[i])) : null,
      wind_gust_kph:  null,
      thunder_prob:   [95,96,99].includes(dly.weather_code?.[i]) ? 70 : 0,
      sunrise:        dly.sunrise?.[i] ? new Date(dly.sunrise[i]).toLocaleTimeString('en-US',{hour:'numeric',minute:'2-digit',hour12:true}).replace(':00 ',' ') : null,
      sunset:         dly.sunset?.[i]  ? new Date(dly.sunset[i]).toLocaleTimeString('en-US',{hour:'numeric',minute:'2-digit',hour12:true}).replace(':00 ',' ') : null,
    }));

    return { current, forecast, source: 'open_meteo' };
  } catch (err) {
    console.error('fetchOpenMeteo failed:', String(err));
    return null;
  }
}

// ── Main handler ───────────────────────────────────────────────────────────
Deno.serve(withObservability({ functionName: 'weather-proxy', route: 'guest' }, async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS });
  }
  if (req.method !== 'GET' && req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  }

  const db    = createClient(SUPABASE_URL, SERVICE_ROLE);
  const today = getManilaDateStr();
  const now   = Date.now();

  // Check server-side cache first
  const { data: cacheRow } = await db
    .from('app_settings')
    .select('value, updated_at')
    .eq('key', CACHE_KEY)
    .maybeSingle();

  if (cacheRow?.value && cacheRow.updated_at) {
    const age = now - new Date(cacheRow.updated_at).getTime();
    if (age < CACHE_TTL_MS) {
      const cached = cacheRow.value as any;
      console.log(`weather-proxy: cache hit — source=${cached.source}, age=${Math.round(age / 60000)}min`);
      return new Response(
        JSON.stringify({ ...cached, cached: true, location: LOCATION }),
        { status: 200, headers: JSON_H }
      );
    }
  }

  // Fetch fresh: PirateWeather → Google Weather → Open-Meteo
  console.log('weather-proxy: fetching fresh — PirateWeather first');
  let fresh = await fetchPirateWeather(today);

  if (!fresh) {
    console.warn('weather-proxy: PirateWeather failed → trying Google Weather');
    fresh = await fetchGoogleWeather(today);
  }

  if (!fresh) {
    console.warn('weather-proxy: Google Weather failed → falling back to Open-Meteo');
    fresh = await fetchOpenMeteo(today);
  }

  if (!fresh) {
    // All sources failed — return stale cache if available
    if (cacheRow?.value) {
      console.warn('weather-proxy: all sources failed, returning stale cache');
      return new Response(
        JSON.stringify({ ...(cacheRow.value as any), cached: true, stale: true, location: LOCATION }),
        { status: 200, headers: JSON_H }
      );
    }
    return new Response(
      JSON.stringify({ error: 'weather_unavailable' }),
      { status: 503, headers: JSON_H }
    );
  }

  const fetched_at = new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Manila' }).replace(' ', 'T') + '+08:00';
  const payload    = { ...fresh, fetched_at };

  await db.from('app_settings').upsert(
    { key: CACHE_KEY, value: payload, updated_at: new Date().toISOString() },
    { onConflict: 'key' }
  );

  console.log(`weather-proxy: cached fresh data, source=${fresh.source}`);
  return new Response(
    JSON.stringify({ ...payload, cached: false, location: LOCATION }),
    { status: 200, headers: JSON_H }
  );
}));
