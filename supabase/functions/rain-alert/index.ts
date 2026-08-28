// rain-alert v2
// Migrated from Open-Meteo to Google Weather API (same key as daily-digest).
// Runs every 2h via pg_cron. Sends a warning to OPS group if:
//   1. Hourly precip probability >= 70% in the 3-4 hour window ahead (Manila time)
//   2. There are arrivals OR departures today
//   3. No alert has already been sent today (dedup via app_settings)
// Only fires during Manila operational hours (6:00–20:00).
// Routing: OPS group only. Zero financial data.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN      = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const OPS_CHAT      = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
const WEATHER_KEY   = Deno.env.get('GOOGLE_WEATHER_API_KEY') ?? '';
const PROPERTY_ID   = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const GEN_SAN_LAT   = 6.1164;
const GEN_SAN_LNG   = 125.1716;
const JSON_H        = { 'Content-Type': 'application/json' };
const RAIN_THRESHOLD = 70;   // % probability
const DEDUP_KEY      = 'rain_alert_sent_date';

// ── Helpers ───────────────────────────────────────────────────────
function getManilaDateStr(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}
function getManilaHour(): number {
  const s = new Date().toLocaleString('en-US', { timeZone: 'Asia/Manila', hour: 'numeric', hour12: false });
  return parseInt(s, 10) % 24;
}
function fmtHour(h: number): string {
  const s = h >= 12 ? 'PM' : 'AM';
  const h12 = h === 0 ? 12 : h > 12 ? h - 12 : h;
  return `${h12}:00 ${s}`;
}
function formatFriendlyDate(dateStr: string): string {
  return new Date(dateStr + 'T00:00:00Z').toLocaleDateString('en-PH', {
    timeZone: 'UTC', weekday: 'long', month: 'long', day: 'numeric', year: 'numeric',
  });
}
function formatTime12(t: string | null | undefined): string {
  if (!t) return '';
  const [hh, mm] = String(t).split(':');
  const h = parseInt(hh, 10);
  return `${h === 0 ? 12 : h > 12 ? h - 12 : h}:${mm} ${h >= 12 ? 'PM' : 'AM'}`;
}
function esc(s: unknown): string {
  return String(s ?? '').replace(/[_*`[]/g, '\\$&');
}
function guestDisplay(row: any): string {
  const name = String(row.guest_name ?? '').trim();
  if (name) return esc(name);
  const summary = String(row.raw_summary ?? '').trim();
  if (summary && summary.toLowerCase() !== 'reserved') return esc(summary);
  return 'Airbnb Guest';
}

// ── Telegram ──────────────────────────────────────────────────────
async function tgSend(chatId: string, text: string): Promise<void> {
  if (!TG_TOKEN || !chatId) return;
  const res = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_H,
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'Markdown' }),
    signal: AbortSignal.timeout(15_000),
  }).catch(err => { console.error('tgSend error:', String(err)); return null; });
  if (res && !res.ok) console.error('tgSend non-ok:', res.status, await res.text().catch(() => ''));
}

// ── Rain window detection via Google Weather API ──────────────────
interface RainWindow { startHour: number; endHour: number; peakProb: number; }

async function checkRainAhead(manilaHour: number, today: string): Promise<RainWindow | null> {
  if (!WEATHER_KEY) {
    console.warn('rain-alert: GOOGLE_WEATHER_API_KEY not set');
    return null;
  }
  try {
    const [todayY, todayM, todayD] = today.split('-').map(Number);
    const lookStart = manilaHour + 3;
    const lookEnd   = Math.min(manilaHour + 4, 23); // cap at 23:00 (op hours gate prevents late runs)

    const url = [
      `https://weather.googleapis.com/v1/forecast/hours:lookup`,
      `?key=${WEATHER_KEY}`,
      `&location.latitude=${GEN_SAN_LAT}`,
      `&location.longitude=${GEN_SAN_LNG}`,
      `&hours=24`,
    ].join('');

    const res = await fetch(url, { signal: AbortSignal.timeout(8_000) });
    if (!res.ok) {
      console.error('Google Weather hourly non-ok:', res.status, await res.text().catch(() => '').then(t => t.slice(0, 200)));
      return null;
    }
    const data = await res.json();

    const allHours = (data?.forecastHours ?? []) as any[];

    // displayDateTime is in the location's local time (Manila).
    // Filter to today's hours within the look-ahead window.
    const windowHours = allHours
      .filter((h: any) => {
        const dt = h.displayDateTime;
        if (!dt) return false;
        if (dt.year !== todayY || dt.month !== todayM || dt.day !== todayD) return false;
        const hr = Number(dt.hours ?? 0);
        return hr >= lookStart && hr <= lookEnd;
      })
      .map((h: any) => ({
        hour: Number(h.displayDateTime.hours ?? 0),
        prob: Number(h.precipitation?.probability?.percent ?? 0),
      }))
      .filter(x => x.prob >= RAIN_THRESHOLD);

    if (windowHours.length === 0) return null;
    return {
      startHour: windowHours[0].hour,
      endHour:   windowHours[windowHours.length - 1].hour,
      peakProb:  Math.max(...windowHours.map(x => x.prob)),
    };
  } catch (err) {
    console.warn('checkRainAhead failed:', String(err));
    return null;
  }
}

// ── Main handler ──────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  }

  const manilaHour = getManilaHour();
  const today      = getManilaDateStr();

  // Only run during operational hours (6:00–20:00 Manila)
  if (manilaHour < 6 || manilaHour > 20) {
    console.log(`rain-alert: outside operational hours (Manila hour=${manilaHour})`);
    return new Response(JSON.stringify({ ok: true, skipped: 'outside_hours' }), { status: 200, headers: JSON_H });
  }

  const db = createClient(SUPABASE_URL, SERVICE_ROLE);

  // ① Dedup — already sent today?
  const { data: settingRow } = await db
    .from('app_settings')
    .select('value')
    .eq('key', DEDUP_KEY)
    .maybeSingle();
  const lastSentDate = (settingRow?.value as any)?.date ?? '';
  if (lastSentDate === today) {
    console.log(`rain-alert: already sent today (${today})`);
    return new Response(JSON.stringify({ ok: true, skipped: 'already_sent_today' }), { status: 200, headers: JSON_H });
  }

  // ② Check arrivals/departures today
  const [{ data: arrivals }, { data: departures }] = await Promise.all([
    db.from('calendar_events')
      .select('guest_name,raw_summary,checkin_time')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').eq('checkin_date', today),
    db.from('calendar_events')
      .select('guest_name,raw_summary,checkout_time')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').eq('checkout_date', today),
  ]);
  const hasActivity = (arrivals?.length ?? 0) > 0 || (departures?.length ?? 0) > 0;
  if (!hasActivity) {
    console.log('rain-alert: no arrivals/departures today, skipping');
    return new Response(JSON.stringify({ ok: true, skipped: 'no_activity' }), { status: 200, headers: JSON_H });
  }

  // ③ Check rain in 3–4 hours ahead (Google Weather API)
  const rainWindow = await checkRainAhead(manilaHour, today);
  if (!rainWindow) {
    console.log(`rain-alert: no strong rain in +3/+4h window, skipping`);
    return new Response(JSON.stringify({ ok: true, skipped: 'no_rain' }), { status: 200, headers: JSON_H });
  }

  // ④ Build and send OPS alert
  const arrivalLines = (arrivals ?? []).map((r: any) => {
    const time = r.checkin_time ? ` · check-in from ${formatTime12(r.checkin_time)}` : '';
    return `   🛬 Arrival: *${guestDisplay(r)}*${time}`;
  });
  const departureLines = (departures ?? []).map((r: any) => {
    const time = r.checkout_time ? ` · checks out by ${formatTime12(r.checkout_time)}` : '';
    return `   🛫 Departure: *${guestDisplay(r)}*${time}`;
  });

  const timeRange = rainWindow.startHour === rainWindow.endHour
    ? `around ${fmtHour(rainWindow.startHour)}`
    : `${fmtHour(rainWindow.startHour)} – ${fmtHour(rainWindow.endHour)}`;

  const msg = [
    `⛈ *Rain Warning — Cascade Hideaway*`,
    `_${formatFriendlyDate(today)}_`,
    ``,
    `Strong rain expected *${timeRange}* _(${rainWindow.peakProb}% chance)_`,
    ``,
    `*Today\'s activity:*`,
    [...arrivalLines, ...departureLines].join('\n'),
    ``,
    `_Please prepare:_`,
    `• Umbrella or towel near entrance`,
    `• Notify arriving guest of rain if check-in is close`,
    `• Confirm cleaner is aware if same-day turnover`,
    ``,
    `_\— Cascade Bot_`,
  ].join('\n');

  await tgSend(OPS_CHAT, msg);

  // ⑤ Mark sent today
  await db.from('app_settings').upsert(
    { key: DEDUP_KEY, value: { date: today, sent_at_hour: manilaHour, source: 'google_weather' }, updated_at: new Date().toISOString() },
    { onConflict: 'key' }
  );

  console.log(`rain-alert v2: sent for ${today}, rain window ${rainWindow.startHour}-${rainWindow.endHour}h, peak ${rainWindow.peakProb}%`);
  return new Response(JSON.stringify({ ok: true, sent: true, rainWindow, date: today }), { status: 200, headers: JSON_H });
});
