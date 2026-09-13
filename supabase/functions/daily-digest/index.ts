// daily-digest v15 — report shape (phase 4, D-106 #4, 2026-09-13)
// v15: both digests are built as a cascade-core Report (decision, at most five lines, one action)
//   by daily-digest/report.ts (pure, tested in digest.test.ts) and rendered by
//   cascade-core/format.ts renderReport(). Plain text, no Markdown, no phrase bank, no model call.
//   Fetching is unchanged from v14; the v13 guest-name rule and v14 pending rule are kept.
// v14: Finance digest counts EXPENSE rows only, itemised, console link.
// v13: guestDisplay — row.guest_name takes precedence over fuzzy-resolved name.
// v12: .eq('status','confirmed') on resData (excludes cancelled from name resolution).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { renderReport } from '../_shared/cascade-core/format.ts';
import { financeReport, opsReport, type Weather } from './report.ts';

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

// ── Telegram (plain text: the report is rendered by code, nothing needs escaping) ──
async function tgSend(chatId: string, text: string): Promise<void> {
  if (!TG_TOKEN || !chatId) { console.warn('tgSend: missing token or chatId'); return; }
  const res = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_H,
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
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

// ── Weather (Google Weather API, unchanged from v14) ─────────────
async function fetchWeather(): Promise<Weather | null> {
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
    const rainWindow = rainHrs.length > 0 ? {
      startHour: rainHrs[0].hour,
      endHour:   rainHrs[rainHrs.length - 1].hour,
      peakProb:  Math.max(...rainHrs.map(x => x.prob)),
    } : undefined;
    const thunderProb = todayHours.length
      ? Math.max(0, ...todayHours.map((h: any) => Number(h.thunderstormProbability ?? 0)))
      : Math.round(Number(cur.thunderstormProbability ?? 0));
    const tmrDay = (day?.forecastDays ?? [])[1];
    const tomorrow = tmrDay ? {
      description: String(tmrDay.daytimeForecast?.weatherCondition?.description?.text ?? ''),
      high:        Math.round(Number(tmrDay.maxTemperature?.degrees ?? 0)),
      low:         Math.round(Number(tmrDay.minTemperature?.degrees ?? 0)),
      rainProb:    Math.round(Number(tmrDay.daytimeForecast?.precipitation?.probability?.percent ?? 0)),
      thunderProb: Math.round(Number(tmrDay.daytimeForecast?.thunderstormProbability ?? 0)),
    } : undefined;
    return {
      temp:        Math.round(Number(cur.temperature?.degrees ?? 0)),
      apparent:    Math.round(Number(cur.feelsLikeTemperature?.degrees ?? 0)),
      rainProb:    Math.round(Number(cur.precipitation?.probability?.percent ?? 0)),
      uvIndex:     Math.round(Number(cur.uvIndex ?? 0)),
      description: String(cur.weatherCondition?.description?.text ?? ''),
      thunderProb,
      rainWindow,
      tomorrow,
    };
  } catch (err) {
    console.warn('fetchWeather failed:', String(err));
    return null;
  }
}

// ── OPS digest: fetch, then report.ts decides what is said ───────────────────
async function buildOpsMessage(db: any, today: string, tomorrow: string): Promise<string | null> {
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

  // Stock runway (unchanged): days of cover at the average stay; no per-booking rate means below-threshold = 0.
  const stock = ((inventoryData ?? []) as any[])
    .map(it => {
      const qty = Number(it.qty_on_hand);
      const cpb = Number(it.consumption_per_booking ?? 0);
      const runway = cpb > 0 ? (qty / cpb) * AVG_STAY_DAYS : (qty <= Number(it.reorder_below ?? 0) ? 0 : 999);
      return { name: String(it.name), qty_on_hand: qty, unit: it.unit, runway };
    })
    .filter(it => it.runway <= 5)
    .sort((a, b) => a.runway - b.runway)
    .slice(0, 5);

  const report = opsReport({
    today, tomorrow,
    arrivals: arrivalsData ?? [], departures: departuresData ?? [],
    tmrArrivals: tmrArrivalsData ?? [], tmrDepartures: tmrDeparturesData ?? [],
    notices: noticesData ?? [], stock, weather, resRows: resData ?? [],
  });
  return report ? renderReport(report) : null;
}

// ── Finance digest ──────────────────────────────────────────────────────────
async function buildFinanceMessage(db: any, today: string): Promise<string | null> {
  const firstOfMonth = new Date(today + 'T00:00:00Z').getUTCDate() === 1;
  const { data: pendingRows } = await db
    .from('transactions')
    .select('transaction_date,payee_name,category,gross_amount,source')
    .eq('property_id', PROPERTY_ID)
    .eq('status', 'pending_review')
    .eq('txn_type', 'expense')
    .order('transaction_date', { ascending: true });
  let lastExport: string | null = null;
  if (firstOfMonth) {
    const { data: lastTxn } = await db.from('airbnb_transactions').select('txn_date')
      .order('txn_date', { ascending: false }).limit(1).maybeSingle();
    lastExport = lastTxn?.txn_date ?? null;
  }
  const report = financeReport({ pending: pendingRows ?? [], firstOfMonth, lastExport, consoleUrl: CONSOLE_URL });
  return report ? renderReport(report) : null;
}

// ── Main handler ────────────────────────────────────────────────────────────
Deno.serve(withObservability({ functionName: 'daily-digest', route: 'ops' }, async (req: Request) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  let mode = 'ops';
  try { const b = await req.json(); mode = String(b?.mode ?? 'ops').toLowerCase(); } catch { /* default ops */ }
  const db    = createClient(SUPABASE_URL, SERVICE_ROLE);
  const today = getManilaDateStr();
  const tmr   = addDays(today, 1);
  console.log(`daily-digest v15: mode=${mode} date=${today}`);
  try {
    if (mode === 'finance') {
      if (!FINANCE_CHAT) return new Response(JSON.stringify({ ok: false, error: 'FINANCE_CHAT not configured' }), { status: 500, headers: JSON_H });
      const msg = await buildFinanceMessage(db, today);
      if (msg === null) {
        console.log(`daily-digest v15: skipping Finance — no pending expenses, not 1st of month`);
        return new Response(JSON.stringify({ ok: true, mode, date: today, skipped: true, reason: 'no_pending' }), { status: 200, headers: JSON_H });
      }
      await tgSend(FINANCE_CHAT, msg);
    } else {
      if (!OPS_CHAT) return new Response(JSON.stringify({ ok: false, error: 'OPS_CHAT not configured' }), { status: 500, headers: JSON_H });
      const msg = await buildOpsMessage(db, today, tmr);
      if (msg === null) {
        console.log(`daily-digest v15: skipping OPS — nothing actionable (${today})`);
        return new Response(JSON.stringify({ ok: true, mode, date: today, skipped: true, reason: 'no_activity' }), { status: 200, headers: JSON_H });
      }
      await tgSend(OPS_CHAT, msg);
    }
    return new Response(JSON.stringify({ ok: true, mode, date: today }), { status: 200, headers: JSON_H });
  } catch (err) {
    console.error('daily-digest v15 error:', String(err));
    return new Response(JSON.stringify({ ok: false, error: String(err) }), { status: 500, headers: JSON_H });
  }
}));
