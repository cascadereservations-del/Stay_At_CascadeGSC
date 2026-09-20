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
import { heartbeat } from '../_shared/heartbeat.ts';
import { renderReport, withHeader, autoKeyboard, BTN } from '../_shared/cascade-core/format.ts';
import { friendlyDate, opsReport, weeklyFinanceReport, weeklyOpsReport, type MidStay, type Weather } from './report.ts';
import { overdue } from '../finance-watch/watch.ts';

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
async function tgSend(chatId: string, text: string, reply_markup?: unknown): Promise<void> {
  if (!TG_TOKEN || !chatId) { console.warn('tgSend: missing token or chatId'); return; }
  const res = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_H,
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true, reply_markup }),
    signal: AbortSignal.timeout(15_000),
  }).catch(err => { console.error('tgSend fetch error:', String(err)); return null; });
  if (res && !res.ok) console.error('tgSend non-ok:', res.status, await res.text().catch(() => '').then(t => t.slice(0, 200)));
}

// ── Date helpers ──────────────────────────────────────────────
function getManilaDateStr(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}
const daysBetween = (from: string, to: string) => Math.round((new Date(to + 'T00:00:00Z').getTime() - new Date(from + 'T00:00:00Z').getTime()) / 86_400_000);
const isMonday = (d: string) => new Date(d + 'T00:00:00Z').getUTCDay() === 1;
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
    { data: inHouseData },
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
    db.from('calendar_events').select('guest_name,raw_summary,checkin_date,checkout_date,nights')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').lt('checkin_date', today).gt('checkout_date', today),
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

  // Telegram plan §2: a staff nudge on the second morning of any stay of three nights or more.
  const midStay: MidStay[] = ((inHouseData ?? []) as any[]).flatMap((s) => {
    const nights = Number(s.nights ?? daysBetween(String(s.checkin_date), String(s.checkout_date)));
    const night = daysBetween(String(s.checkin_date), today) + 1;
    if (nights < 3 || night !== 2) return [];
    const guest = String(s.guest_name ?? '').trim() || (String(s.raw_summary ?? '').toLowerCase() !== 'reserved' && s.raw_summary) || 'the guest';
    return [{ guest, night, nights }];
  });

  const report = opsReport({
    today, tomorrow,
    arrivals: arrivalsData ?? [], departures: departuresData ?? [],
    tmrArrivals: tmrArrivalsData ?? [], tmrDepartures: tmrDeparturesData ?? [],
    notices: noticesData ?? [], stock, weather, resRows: resData ?? [], midStay,
  });
  return report ? withHeader(report.kind, friendlyDate(today), renderReport(report)) : null;
}

// ── Weekly OPS roll-up (Mondays, Telegram plan §4): low stock, work orders, handoffs, the week ahead ──
async function buildWeeklyOpsMessage(db: any, today: string): Promise<string> {
  const weekEnd = addDays(today, 7);
  const [{ data: inv }, { data: wo }, { data: ho }, { data: arr }] = await Promise.all([
    db.from('inventory_items').select('name,qty_on_hand,reorder_below,unit')
      .eq('property_id', PROPERTY_ID).eq('is_active', true).not('reorder_below', 'is', null).order('name'),
    db.from('work_orders').select('title,priority').eq('property_id', PROPERTY_ID).not('status', 'in', '("resolved","cancelled")').order('created_at'),
    db.from('concierge_handoffs').select('guest_name,risk,created_at').eq('status', 'open').order('created_at'),
    db.from('calendar_events').select('guest_name,raw_summary,checkin_date,nights')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').gte('checkin_date', today).lt('checkin_date', weekEnd).order('checkin_date'),
  ]);
  const lowStock = ((inv ?? []) as any[]).filter((i) => Number(i.qty_on_hand) <= Number(i.reorder_below))
    .map((i) => ({ name: String(i.name), qty_on_hand: Number(i.qty_on_hand), unit: i.unit, runway: 0 }));
  const report = weeklyOpsReport({
    today, lowStock,
    workOrders: ((wo ?? []) as any[]).map((w) => ({ title: String(w.title), priority: w.priority })),
    handoffs: ((ho ?? []) as any[]).map((h) => ({ guest: h.guest_name, risk: h.risk, days: Math.max(0, daysBetween(String(h.created_at).slice(0, 10), today)) })),
    arrivals: ((arr ?? []) as any[]).map((s) => ({ guest: String(s.guest_name ?? '').trim() || String(s.raw_summary ?? 'Guest'), date: String(s.checkin_date), nights: s.nights })),
  });
  return withHeader('weekly', `week of ${friendlyDate(today)}`, renderReport(report));
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
  // Session 25: cron 4 runs on Mondays now, so the Finance digest is the weekly roll-up —
  // pending receipts, overdue payouts (finance-watch's own rule) and System-health warnings.
  const [{ data: airbnb }, { data: direct }, { data: hc }] = await Promise.all([
    db.from('airbnb_reservations').select('confirmation_code,guest_name,checkin_date,host_payout,payout_email_message_id,status')
      .eq('property_id', PROPERTY_ID).eq('status', 'confirmed').is('payout_email_message_id', null).lte('checkin_date', today),
    db.from('booking_inquiries').select('id,guest_name,checkin_date,deposit_amount,submitted_at,receipt_image_path,status')
      .eq('property_id', PROPERTY_ID).eq('status', 'pending').is('receipt_image_path', null).gte('checkin_date', today),
    db.from('admin_health_check_runs').select('label,status,count').eq('property_id', PROPERTY_ID).in('status', ['warn', 'fail']).order('check_key'),
  ]);
  const overdueLines = overdue(today, airbnb ?? [], direct ?? []).map((o) => o.line);
  const warns = ((hc ?? []) as any[]).map((h) => ({ label: String(h.label), n: Number(h.count ?? 0), status: String(h.status) }));
  // SPEC-10 control 11: who confirmed or declined a booking this week. Advisory, like the rest of
  // the roll-up: if the read fails the week's report still goes out, one line poorer.
  const since = new Date(new Date(`${today}T00:00:00Z`).getTime() - 7 * 86_400_000).toISOString();
  const { data: decided, error: decErr } = await db.rpc('finance_decisions_week_v1', { p_property_id: PROPERTY_ID, p_since: since });
  if (decErr) console.warn('[daily-digest] finance decisions', decErr.message);
  const weekly = weeklyFinanceReport({
    today, pending: pendingRows ?? [], overdueLines, warns, consoleUrl: CONSOLE_URL,
    decisions: (decided ?? []) as Array<{ reviewer: string; approved: number; rejected: number }>,
  });
  if (firstOfMonth) weekly.lines.unshift(`Monthly CSV: download Airbnb Transaction History and send the .csv to this chat (last export covered ${lastExport ?? 'unknown'}).`);
  return withHeader('weekly', `week of ${friendlyDate(today)}`, renderReport(weekly));
}

// ── Main handler ────────────────────────────────────────────────────────────
Deno.serve(withObservability({ functionName: 'daily-digest', route: 'ops' }, async (req: Request) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  let mode = 'ops';
  try { const b = await req.json(); mode = String(b?.mode ?? 'ops').toLowerCase(); } catch { /* default ops */ }
  const db    = createClient(SUPABASE_URL, SERVICE_ROLE);
  const hb    = heartbeat(db, mode === 'finance' ? 'weekly-finance-monday-0700' : 'daily-digest-ops-0700');
  await hb('started');
  const today = getManilaDateStr();
  const tmr   = addDays(today, 1);
  console.log(`daily-digest v15: mode=${mode} date=${today}`);
  try {
    if (mode === 'finance') {
      if (!FINANCE_CHAT) return new Response(JSON.stringify({ ok: false, error: 'FINANCE_CHAT not configured' }), { status: 500, headers: JSON_H });
      const msg = await buildFinanceMessage(db, today);
      if (msg === null) {
        console.log(`daily-digest v15: skipping Finance — no pending expenses, not 1st of month`);
        await hb('succeeded');
        return new Response(JSON.stringify({ ok: true, mode, date: today, skipped: true, reason: 'no_pending' }), { status: 200, headers: JSON_H });
      }
      await tgSend(FINANCE_CHAT, msg, autoKeyboard(msg, BTN.expense)); // session 28: money cards carry Log expense / Records
    } else {
      if (!OPS_CHAT) return new Response(JSON.stringify({ ok: false, error: 'OPS_CHAT not configured' }), { status: 500, headers: JSON_H });
      if (isMonday(today)) { const wk = await buildWeeklyOpsMessage(db, today); await tgSend(OPS_CHAT, wk, autoKeyboard(wk)); }
      const msg = await buildOpsMessage(db, today, tmr);
      if (msg === null) {
        console.log(`daily-digest v15: skipping OPS — nothing actionable (${today})`);
        await hb('succeeded');
        return new Response(JSON.stringify({ ok: true, mode, date: today, skipped: true, reason: 'no_activity' }), { status: 200, headers: JSON_H });
      }
      await tgSend(OPS_CHAT, msg, autoKeyboard(msg)); // session 28: 📨 -> Copy/Revise, 📦 -> Inventory
    }
    await hb('succeeded');
    return new Response(JSON.stringify({ ok: true, mode, date: today }), { status: 200, headers: JSON_H });
  } catch (err) {
    console.error('daily-digest v15 error:', String(err));
    await hb('failed', String(err).slice(0, 80));
    return new Response(JSON.stringify({ ok: false, error: String(err) }), { status: 500, headers: JSON_H });
  }
}));
