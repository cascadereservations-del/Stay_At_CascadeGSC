// daily-digest v14 — Finance digest overhaul (2026-07-12)
// v14: buildFinanceMessage — (1) pending trigger now counts EXPENSE rows only
//   (txn_type='expense'); income-estimate rows (airbnb_email, income_stage='estimated')
//   self-resolve on payout email and are NOT actionable — they no longer trigger
//   false 'please confirm' prompts. (2) Pending items are itemized (date · payee ·
//   amount · category), capped at 5 lines. (3) Admin console link appended to every
//   Finance digest for quick review access.
// v13: guestDisplay — row.guest_name takes precedence over fuzzy-resolved name.
// v12: .eq('status','confirmed') on resData (excludes cancelled from name resolution).
// v11 and earlier: see version history.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN      = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const OPS_CHAT      = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
const FINANCE_CHAT  = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';
const WEATHER_KEY   = Deno.env.get('GOOGLE_WEATHER_API_KEY') ?? '';
const PROPERTY_ID   = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const GEN_SAN_LAT   = 6.1164;
const GEN_SAN_LNG   = 125.1716;
const JSON_H        = { 'Content-Type': 'application/json' };
const AVG_STAY_DAYS = 2;
const CONSOLE_URL   = 'https://cascadereservations-del.github.io/cascade-admin-dashboard/';

// ── Telegram ────────────────────────────────────────────────
async function tgSend(chatId: string, text: string): Promise<void> {
  if (!TG_TOKEN || !chatId) { console.warn('tgSend: missing token or chatId'); return; }
  const res = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_H,
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'Markdown' }),
    signal: AbortSignal.timeout(15_000),
  }).catch(err => { console.error('tgSend fetch error:', String(err)); return null; });
  if (res && !res.ok) console.error('tgSend non-ok:', res.status, await res.text().catch(() => '').then(t => t.slice(0, 200)));
}

// ── Date helpers ──────────────────────────────────────────────
function getManilaDateStr(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}
function addDays(dateStr: string, n: number): string {
  const d = new Date(dateStr + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
function getDayOfYear(dateStr: string): number {
  const d = new Date(dateStr + 'T00:00:00Z');
  const start = new Date(d.getUTCFullYear() + '-01-01T00:00:00Z');
  return Math.floor((d.getTime() - start.getTime()) / 86_400_000);
}
function formatFriendlyDate(dateStr: string): string {
  return new Date(dateStr + 'T00:00:00Z').toLocaleDateString('en-PH', {
    timeZone: 'UTC', weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  });
}
function formatTime12(t: string | null | undefined): string {
  if (!t) return '';
  const [hh, mm] = String(t).split(':');
  const h = parseInt(hh, 10);
  return `${h === 0 ? 12 : h > 12 ? h - 12 : h}:${mm} ${h >= 12 ? 'PM' : 'AM'}`;
}
function fmtHour(h: number): string {
  return `${h === 0 ? 12 : h > 12 ? h - 12 : h}:00 ${h >= 12 ? 'PM' : 'AM'}`;
}
function utcToManilaTime(utcStr: string): string {
  if (!utcStr) return '';
  try {
    const s = new Date(utcStr).toLocaleTimeString('en-US', {
      timeZone: 'Asia/Manila', hour: 'numeric', minute: '2-digit', hour12: true,
    });
    return s.replace(':00 ', ' ');
  } catch { return ''; }
}

// ── Helpers ─────────────────────────────────────────────────────
function esc(s: unknown): string { return String(s ?? '').replace(/[_*`[]/g, '\\$&'); }
function peso(n: unknown): string { const x = Number(n); return (isFinite(x) ? x : 0).toLocaleString('en-PH'); }

// ── Phrase bank ─────────────────────────────────────────────────
const GREETINGS = [
  '🌿 Good morning, Cascade','🌸 A gentle good morning','✨ The Hideaway wakes with grace',
  '🌤 Morning light at Cascade','🍃 A new day unfolds at the Hideaway','☀️ Rise and shine, Cascade team',
  '🌊 Good morning — may today flow beautifully','🕊 The morning belongs to us',
  '🌺 Cascade Hideaway greets you warmly','🌼 A graceful morning begins',
  '🏡 Welcome to a new day at Cascade','💫 Good morning — the Hideaway is ready',
];
const SIGNOFFS = [
  'Wishing you a graceful and productive day.\n_— The Cascade Team_ 🌿',
  'May today bring smooth stays and happy guests.\n_— Cascade HQ_',
  '_Hotel Comfort. Home Warmth._ ✨',
  'Here for a beautiful day at the Hideaway.\n_— Cascade_',
  'Onwards to a lovely day.\n_— The Cascade Team_ 🌸',
  'Wishing you ease and elegance today.\n_— Cascade_',
  'May every detail fall perfectly into place.\n_— Cascade Team_',
  'A warm day ahead for all of us.\n_— Cascade Hideaway_ 🏡',
  'Stay graceful, stay Cascade. ✨',
  'Until this evening — may it be wonderful.\n_— The Cascade Team_',
];
function getPhrases(today: string) {
  const d = getDayOfYear(today);
  return { greeting: GREETINGS[d % GREETINGS.length], signoff: SIGNOFFS[d % SIGNOFFS.length] };
}

// ── Weather types ───────────────────────────────────────────────
interface RainWindow  { startHour: number; endHour: number; peakProb: number; }
interface TomorrowWx  {
  description: string; high: number; low: number;
  feelsLikeHigh: number; rainProb: number; thunderProb: number;
}
interface WeatherData {
  temp: number; apparent: number; rainProb: number; uvIndex: number;
  description: string; humidity: number; thunderProb: number;
  rainWindow?: RainWindow; tomorrow?: TomorrowWx;
  sunrise?: string; sunset?: string;
}

function descToEmoji(desc: string): string {
  const d = (desc ?? '').toLowerCase();
  if (d.includes('heavy thunder') || d.includes('strong thunder')) return '⛈️';
  if (d.includes('thunder') || d.includes('storm')) return '⛈️';
  if (d.includes('heavy rain')) return '🌧️';
  if (d.includes('rain') || d.includes('shower') || d.includes('drizzle')) return '🌦️';
  if (d.includes('fog') || d.includes('mist') || d.includes('haze')) return '🌫️';
  if (d.includes('mostly cloudy')) return '🌥️';
  if (d.includes('partly cloudy')) return '⛅';
  if (d.includes('cloudy') || d.includes('overcast')) return '☁️';
  if (d.includes('clear') || d.includes('sunny')) return '☀️';
  return '🌤️';
}
function uvLabel(uv: number): string {
  if (uv <= 2)  return 'Low';
  if (uv <= 5)  return 'Moderate';
  if (uv <= 7)  return 'High';
  if (uv <= 10) return 'Very High';
  return 'Extreme';
}

async function fetchWeather(): Promise<WeatherData | null> {
  if (!WEATHER_KEY) { console.warn('GOOGLE_WEATHER_API_KEY not set'); return null; }
  try {
    const base = 'https://weather.googleapis.com/v1';
    const loc  = `location.latitude=${GEN_SAN_LAT}&location.longitude=${GEN_SAN_LNG}`;
    const k    = `key=${WEATHER_KEY}`;
    const today = getManilaDateStr();
    const [todayY, todayM, todayD] = today.split('-').map(Number);
    const [curRes, hrRes, dayRes] = await Promise.all([
      fetch(`${base}/currentConditions:lookup?${k}&${loc}`, { signal: AbortSignal.timeout(8_000) }),
      fetch(`${base}/forecast/hours:lookup?${k}&${loc}&hours=24`, { signal: AbortSignal.timeout(8_000) }),
      fetch(`${base}/forecast/days:lookup?${k}&${loc}&days=2`, { signal: AbortSignal.timeout(8_000) }),
    ]);
    if (!curRes.ok) { console.error('Google Weather current:', curRes.status); return null; }
    const cur = await curRes.json();
    const hr  = hrRes.ok  ? await hrRes.json()  : null;
    const day = dayRes.ok ? await dayRes.json() : null;
    const allHours   = (hr?.forecastHours ?? []) as any[];
    const todayHours = allHours.filter((h: any) =>
      h.displayDateTime?.year  === todayY &&
      h.displayDateTime?.month === todayM &&
      h.displayDateTime?.day   === todayD
    );
    const rainHrs = todayHours
      .map((h: any) => ({ hour: Number(h.displayDateTime?.hours ?? 0), prob: Number(h.precipitation?.probability?.percent ?? 0) }))
      .filter(x => x.prob >= 50);
    const rainWindow: RainWindow | undefined = rainHrs.length > 0 ? {
      startHour: rainHrs[0].hour,
      endHour:   rainHrs[rainHrs.length - 1].hour,
      peakProb:  Math.max(...rainHrs.map(x => x.prob)),
    } : undefined;
    const thunderProb = todayHours.length
      ? Math.max(0, ...todayHours.map((h: any) => Number(h.thunderstormProbability ?? 0)))
      : Math.round(Number(cur.thunderstormProbability ?? 0));
    const todayDay = (day?.forecastDays ?? [])[0];
    const sunrise  = todayDay?.sunEvents?.sunriseTime ? utcToManilaTime(todayDay.sunEvents.sunriseTime) : undefined;
    const sunset   = todayDay?.sunEvents?.sunsetTime  ? utcToManilaTime(todayDay.sunEvents.sunsetTime)  : undefined;
    const tmrDay = (day?.forecastDays ?? [])[1];
    const tomorrow: TomorrowWx | undefined = tmrDay ? {
      description:   String(tmrDay.daytimeForecast?.weatherCondition?.description?.text ?? ''),
      high:          Math.round(Number(tmrDay.maxTemperature?.degrees ?? 0)),
      low:           Math.round(Number(tmrDay.minTemperature?.degrees ?? 0)),
      feelsLikeHigh: Math.round(Number(tmrDay.feelsLikeMaxTemperature?.degrees ?? 0)),
      rainProb:      Math.round(Number(tmrDay.daytimeForecast?.precipitation?.probability?.percent ?? 0)),
      thunderProb:   Math.round(Number(tmrDay.daytimeForecast?.thunderstormProbability ?? 0)),
    } : undefined;
    return {
      temp:        Math.round(Number(cur.temperature?.degrees ?? 0)),
      apparent:    Math.round(Number(cur.feelsLikeTemperature?.degrees ?? 0)),
      rainProb:    Math.round(Number(cur.precipitation?.probability?.percent ?? 0)),
      uvIndex:     Math.round(Number(cur.uvIndex ?? 0)),
      description: String(cur.weatherCondition?.description?.text ?? ''),
      humidity:    Math.round(Number(cur.relativeHumidity ?? 0)),
      thunderProb,
      rainWindow,
      tomorrow,
      sunrise,
      sunset,
    };
  } catch (err) {
    console.warn('fetchWeather failed:', String(err));
    return null;
  }
}

function buildWeatherLine(w: WeatherData | null): string {
  if (!w) return '';
  const emoji = descToEmoji(w.description);
  const lines: string[] = [];
  lines.push(`${emoji} *Weather at Cascade Hideaway*`);
  const heatTag = w.apparent >= 38 ? ' · Extreme heat'
                : w.apparent >= 35 ? ' · Very hot'
                : w.apparent >= 32 ? ' · Hot and humid' : '';
  lines.push(`${w.description} · ${w.temp}°C (feels ${w.apparent}°C)${heatTag}`);
  lines.push(`UV ${w.uvIndex} ${uvLabel(w.uvIndex)} · Humidity ${w.humidity}%`);
  if (w.sunrise && w.sunset) {
    lines.push(`🌅 ${w.sunrise} · 🌇 ${w.sunset}`);
  }
  if (w.thunderProb >= 40) {
    const severity = w.thunderProb >= 70 ? ' · secure outdoor items' : '';
    lines.push(`⚡ Thunderstorm ${w.thunderProb}%${severity}`);
  }
  if (w.rainWindow) {
    const { startHour, endHour, peakProb } = w.rainWindow;
    const dur   = Math.max(1, endHour - startHour + 1);
    const range = startHour === endHour
      ? `around ${fmtHour(startHour)}`
      : `${fmtHour(startHour)}–${fmtHour(endHour)}`;
    lines.push(`🌧 Rain ${range} · ~${dur}h · peak ${peakProb}%`);
  } else if (w.rainProb >= 40) {
    lines.push(`🌧 Rain possible (${w.rainProb}%)`);
  }
  if (w.tomorrow) {
    const tw     = w.tomorrow;
    const tEmoji = descToEmoji(tw.description);
    const tRain  = tw.rainProb   >= 40 ? ` · ${tw.rainProb}% rain`  : '';
    const tThund = tw.thunderProb >= 40 ? ' ⚡' : '';
    lines.push(`— Tomorrow: ${tEmoji} ${tw.description} · ${tw.low}–${tw.high}°C${tRain}${tThund}`);
  }
  return lines.join('\n');
}

// ── Guest display ─────────────────────────────────────────────────
// v13: row.guest_name takes precedence. Fuzzy-resolved name is a fallback for
// null-named Airbnb calendar rows only — never overrides a real name (e.g. direct bookings).
function guestDisplay(row: any, resolvedName?: string): string {
  const name = String(row.guest_name ?? '').trim();
  if (name) return esc(name);
  if (resolvedName) return esc(resolvedName);
  const summary = String(row.raw_summary ?? '').trim();
  if (summary && summary.toLowerCase() !== 'reserved') return esc(summary);
  return 'Guest (name pending)';
}

function findGuestFuzzy(
  resRows: any[],
  targetDate: string,
  dateField: 'checkin_date' | 'checkout_date',
): string | undefined {
  const targetMs = new Date(targetDate + 'T00:00:00Z').getTime();
  let best: { name: string; diff: number } | undefined;
  for (const r of resRows) {
    if (!r.guest_name || !r[dateField]) continue;
    const diff = Math.abs(new Date(String(r[dateField]) + 'T00:00:00Z').getTime() - targetMs) / 86_400_000;
    if (diff <= 2 && (!best || diff < best.diff)) best = { name: r.guest_name, diff };
  }
  return best?.name;
}

const NOTICE_ICON: Record<string, string> = { brownout: '⚡', holiday: '🏖', event: '📅', reminder: '🔔' };

// ── OPS digest ─────────────────────────────────────────────────────────────
async function buildOpsMessage(db: any, today: string, tomorrow: string): Promise<string | null> {
  const { greeting, signoff } = getPhrases(today);

  const wStart = addDays(today, -2);
  const wEnd   = addDays(tomorrow, 2);

  const [
    { data: arrivalsData },
    { data: departuresData },
    { data: tmrArrivalsData },
    { data: tmrDeparturesData },
    { data: inventoryData },
    { data: noticesData },
    { data: resData },
    weather,
  ] = await Promise.all([
    db.from('calendar_events').select('guest_name,raw_summary,checkin_time,nights,source')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').eq('checkin_date', today),
    db.from('calendar_events').select('guest_name,raw_summary,checkout_time,nights,source')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').eq('checkout_date', today),
    db.from('calendar_events').select('guest_name,raw_summary,checkin_time,nights,source')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').eq('checkin_date', tomorrow),
    db.from('calendar_events').select('guest_name,raw_summary,checkout_time,source')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').eq('checkout_date', tomorrow),
    db.from('inventory_items')
      .select('name,qty_on_hand,reorder_below,unit,consumption_per_booking')
      .eq('property_id', PROPERTY_ID).eq('is_active', true).not('reorder_below', 'is', null).order('name'),
    db.from('ops_notices')
      .select('notice_type,title,effective_date,effective_time,duration_hours,feeder')
      .eq('property_id', PROPERTY_ID).eq('is_active', true)
      .in('effective_date', [today, tomorrow])
      .order('effective_date').order('effective_time', { nullsFirst: true }),
    db.from('airbnb_reservations')
      .select('guest_name,checkin_date,checkout_date')
      .not('guest_name', 'is', null)
      .eq('status', 'confirmed')
      .or(`checkin_date.gte.${wStart},checkout_date.gte.${wStart}`)
      .or(`checkin_date.lte.${wEnd},checkout_date.lte.${wEnd}`),
    fetchWeather(),
  ]);

  const arrivals      = (arrivalsData      ?? []) as any[];
  const departures    = (departuresData    ?? []) as any[];
  const tmrArrivals   = (tmrArrivalsData   ?? []) as any[];
  const tmrDepartures = (tmrDeparturesData ?? []) as any[];
  const notices       = (noticesData       ?? []) as any[];
  const todayNotices  = notices.filter(n => n.effective_date === today);
  const tmrNotices    = notices.filter(n => n.effective_date === tomorrow);
  const resRows       = (resData ?? []) as any[];

  // Stock runway
  const criticalStock = ((inventoryData ?? []) as any[])
    .map(it => {
      const qty = Number(it.qty_on_hand);
      const cpb = Number(it.consumption_per_booking ?? 0);
      const runway = cpb > 0 ? (qty / cpb) * AVG_STAY_DAYS : (qty <= Number(it.reorder_below ?? 0) ? 0 : 999);
      return { ...it, runway };
    })
    .filter(it => it.runway <= 5)
    .sort((a, b) => a.runway - b.runway)
    .slice(0, 5);

  const hasBrownoutOverride  = notices.some((n: any) => n.notice_type === 'brownout');
  const hasOrderTodayUrgency = criticalStock.some((it: any) => it.runway <= 1);
  const isEmpty =
    arrivals.length === 0 && departures.length === 0 &&
    todayNotices.length === 0 && tmrArrivals.length === 0 &&
    tmrDepartures.length === 0 && tmrNotices.length === 0 &&
    criticalStock.length === 0;
  if (isEmpty && !hasBrownoutOverride && !hasOrderTodayUrgency) return null;

  const parts: string[] = [];

  parts.push(`${greeting}\n*${formatFriendlyDate(today)}*`);

  const weatherLine = buildWeatherLine(weather);
  if (weatherLine) parts.push(weatherLine);

  if (todayNotices.length > 0) {
    const lines = todayNotices.map(n => {
      const icon    = NOTICE_ICON[n.notice_type] ?? '📌';
      const timeStr = n.effective_time ? ` at ${formatTime12(n.effective_time)}` : '';
      const durStr  = n.duration_hours  ? ` for ${n.duration_hours}h` : '';
      const feeder  = n.feeder          ? `  _(${esc(n.feeder)})_` : '';
      return `${icon} *${esc(n.title)}*${timeStr}${durStr}${feeder}`;
    });
    parts.push(lines.join('\n'));
  }

  if (arrivals.length > 0) {
    const lines = arrivals.map(r => {
      const g = guestDisplay(r, findGuestFuzzy(resRows, today, 'checkin_date'));
      const n = r.nights ? `  ·  ${r.nights} night${r.nights !== 1 ? 's' : ''}` : '';
      const t = r.checkin_time ? `  ·  from ${formatTime12(r.checkin_time)}` : '';
      return `   *${g}*${n}${t}`;
    });
    parts.push(`✈️ *Arriving today*\n${lines.join('\n')}`);
  } else {
    parts.push(`✈️ *Arriving today*\n   _No arrivals today_`);
  }

  if (departures.length > 0) {
    const lines = departures.map(r => {
      const g = guestDisplay(r, findGuestFuzzy(resRows, today, 'checkout_date'));
      const t = r.checkout_time ? `  ·  by ${formatTime12(r.checkout_time)}` : '';
      return `   *${g}*${t}`;
    });
    parts.push(`📤 *Departing today*\n${lines.join('\n')}`);
  } else {
    parts.push(`📤 *Departing today*\n   _No departures today_`);
  }

  if (arrivals.length > 0 && departures.length > 0) {
    parts.push(`⚡ *Same-day turnover* — coordinate the cleaning window`);
  }

  const tmrLines: string[] = [];
  for (const r of tmrArrivals) {
    const g = guestDisplay(r, findGuestFuzzy(resRows, tomorrow, 'checkin_date'));
    const n = r.nights ? `  ·  ${r.nights} night${r.nights !== 1 ? 's' : ''}` : '';
    const t = r.checkin_time ? `  ·  from ${formatTime12(r.checkin_time)}` : '';
    tmrLines.push(`   • Arrival: *${g}*${n}${t}`);
  }
  for (const r of tmrDepartures) {
    const g = guestDisplay(r, findGuestFuzzy(resRows, tomorrow, 'checkout_date'));
    const t = r.checkout_time ? `  ·  by ${formatTime12(r.checkout_time)}` : '';
    tmrLines.push(`   • Departure: *${g}*${t}`);
  }
  for (const n of tmrNotices) {
    const icon    = NOTICE_ICON[n.notice_type] ?? '📌';
    const timeStr = n.effective_time ? ` at ${formatTime12(n.effective_time)}` : '';
    const durStr  = n.duration_hours ? ` for ${n.duration_hours}h` : '';
    tmrLines.push(`   • ${icon} ${esc(n.title)}${timeStr}${durStr}`);
  }
  const tw = weather?.tomorrow;
  if (tw) {
    const tEmoji = descToEmoji(tw.description);
    const tRain  = tw.rainProb   >= 40 ? `  ·  ${tw.rainProb}% rain`  : '';
    const tThund = tw.thunderProb >= 40 ? ' ⚡' : '';
    tmrLines.push(`   • ${tEmoji} ${tw.description}  ·  ${tw.low}–${tw.high}°C (feels ${tw.feelsLikeHigh}°C)${tRain}${tThund}`);
  }
  if (tmrLines.length > 0) {
    parts.push(`📅 *Tomorrow*\n${tmrLines.join('\n')}`);
  }

  if (criticalStock.length > 0) {
    const lines = criticalStock.map(it => {
      const qty    = Number(it.qty_on_hand);
      const unit   = it.unit ? ` ${it.unit}` : '';
      const status = it.runway <= 1
        ? '_order today_'
        : `~${Math.round(it.runway)} day${Math.round(it.runway) !== 1 ? 's' : ''} left`;
      return `   🔴 ${esc(it.name)}  —  ${qty}${unit}  ·  ${status}`;
    });
    parts.push(`📦 *Supplies running low*\n${lines.join('\n')}`);
  }

  parts.push(signoff);
  return parts.join('\n\n');
}

// ── Finance digest ──────────────────────────────────────────────────────────
// v14: pending trigger counts actionable EXPENSE rows only. Income estimates
// (airbnb_email) self-resolve via payout emails and never require manual review.
// Pending expenses are itemized (max 5 lines) and the admin console link is
// appended to every Finance digest.
function sourceLabel(src: string, category: string): string {
  if (src === 'ocr') return 'receipt — ' + category;
  if (src === 'telegram') return category;
  return category + ' (' + src + ')';
}
async function buildFinanceMessage(db: any, today: string): Promise<string | null> {
  const isFirstOfMonth = new Date(today + 'T00:00:00Z').getUTCDate() === 1;

  const { data: pendingRows } = await db
    .from('transactions')
    .select('transaction_date,payee_name,category,gross_amount,source')
    .eq('property_id', PROPERTY_ID)
    .eq('status', 'pending_review')
    .eq('txn_type', 'expense')
    .order('transaction_date', { ascending: true });
  const pending = (pendingRows ?? []) as any[];
  const count = pending.length;

  if (count === 0 && !isFirstOfMonth) return null;

  const total = pending.reduce((s: number, r: any) => s + Number(r.gross_amount ?? 0), 0);

  const lines: string[] = [
    `🏦 *Cascade Finance*`,
    `_${formatFriendlyDate(today)}_`,
    ``,
  ];

  if (count > 0) {
    lines.push(`📋 *${count} item${count !== 1 ? 's' : ''} awaiting review*`);
    const shown = pending.slice(0, 5);
    for (const r of shown) {
      const d = r.transaction_date ? String(r.transaction_date).slice(5) : '—';
      const who = r.payee_name ? ` · ${esc(r.payee_name)}` : '';
      lines.push(`   • ${d}${who} · ₱${peso(r.gross_amount)} · ${esc(sourceLabel(String(r.source ?? ''), String(r.category ?? '')))}`);
    }
    if (count > 5) lines.push(`   _…and ${count - 5} more_`);
    lines.push(
      `   Total pending: *₱${peso(total)}*`,
      `   _Please confirm before the week closes._`,
    );
  } else {
    lines.push(`✅ All receipts confirmed — the books are clean.`);
  }

  if (isFirstOfMonth) {
    const { data: lastTxn } = await db
      .from('airbnb_transactions')
      .select('txn_date')
      .order('txn_date', { ascending: false })
      .limit(1)
      .maybeSingle();
    const lastExport = lastTxn?.txn_date ?? 'unknown';

    lines.push(
      ``,
      `📂 *Monthly CSV Reminder*`,
      `Sync your Airbnb earnings for this month.`,
      ``,
      `1. Airbnb → Finance → Transaction History`,
      `2. Download (All time or since last export)`,
      `3. Send the .csv file to this Finance chat`,
      `4. Bot imports new rows and reconciles automatically.`,
      ``,
      `_Last export covered: ${lastExport}_`,
      `_Catches extensions, adjustments, and split payouts that email parsing may miss._`,
    );
  }

  lines.push(``, `🔗 Review in the admin console:`, CONSOLE_URL);
  lines.push(``, `_Hotel Comfort. Home Warmth. — Cascade_`);
  return lines.join('\n');
}

// ── Main handler ────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  let mode = 'ops';
  try { const b = await req.json(); mode = String(b?.mode ?? 'ops').toLowerCase(); } catch { /* default ops */ }
  const db    = createClient(SUPABASE_URL, SERVICE_ROLE);
  const today = getManilaDateStr();
  const tmr   = addDays(today, 1);
  console.log(`daily-digest v14: mode=${mode} date=${today}`);
  try {
    if (mode === 'finance') {
      if (!FINANCE_CHAT) return new Response(JSON.stringify({ ok: false, error: 'FINANCE_CHAT not configured' }), { status: 500, headers: JSON_H });
      const msg = await buildFinanceMessage(db, today);
      if (msg === null) {
        console.log(`daily-digest v14: skipping Finance — no pending expenses, not 1st of month`);
        return new Response(JSON.stringify({ ok: true, mode, date: today, skipped: true, reason: 'no_pending' }), { status: 200, headers: JSON_H });
      }
      await tgSend(FINANCE_CHAT, msg);
    } else {
      if (!OPS_CHAT) return new Response(JSON.stringify({ ok: false, error: 'OPS_CHAT not configured' }), { status: 500, headers: JSON_H });
      const msg = await buildOpsMessage(db, today, tmr);
      if (msg === null) {
        console.log(`daily-digest v14: skipping OPS — nothing actionable (${today})`);
        return new Response(JSON.stringify({ ok: true, mode, date: today, skipped: true, reason: 'no_activity' }), { status: 200, headers: JSON_H });
      }
      await tgSend(OPS_CHAT, msg);
    }
    return new Response(JSON.stringify({ ok: true, mode, date: today }), { status: 200, headers: JSON_H });
  } catch (err) {
    console.error('daily-digest v14 error:', String(err));
    return new Response(JSON.stringify({ ok: false, error: String(err) }), { status: 500, headers: JSON_H });
  }
});
