// daily-digest report (phase 4, D-106 #4). Data in, Report out. Pure: no I/O, so digest.test.ts runs it.
// Shape is owned by cascade-core/format.ts: one decision, at most five lines, one action. Plain text.
import type { HeaderKind, Report } from '../_shared/cascade-core/format.ts';
import { problemSentence } from '../_shared/cascade-core/health-labels.ts';

export type CalRow = { guest_name?: string | null; raw_summary?: string | null; checkin_time?: string | null; checkout_time?: string | null; nights?: number | null };
export type ResRow = { guest_name: string | null; checkin_date: string | null; checkout_date: string | null };
export type Notice = { notice_type: string; title: string; effective_date: string; effective_time?: string | null; duration_hours?: number | null; feeder?: string | null };
export type StockItem = { name: string; qty_on_hand: number; unit?: string | null; runway: number };
export type Weather = {
  temp: number; apparent: number; rainProb: number; uvIndex: number; description: string; thunderProb: number;
  rainWindow?: { startHour: number; endHour: number; peakProb: number };
  tomorrow?: { description: string; high: number; low: number; rainProb: number; thunderProb: number };
};
export type MidStay = { guest: string; night: number; nights: number };
export type OpsInput = {
  today: string; tomorrow: string;
  arrivals: CalRow[]; departures: CalRow[]; tmrArrivals: CalRow[]; tmrDepartures: CalRow[];
  notices: Notice[]; stock: StockItem[]; weather: Weather | null; resRows: ResRow[];
  midStay?: MidStay[];
};
export type OpsReport = Report & { kind: HeaderKind };
export type Pending = { transaction_date: string | null; payee_name: string | null; category: string | null; gross_amount: number | string | null; source: string | null };
export type FinanceInput = { pending: Pending[]; firstOfMonth: boolean; lastExport?: string | null; consoleUrl: string };

export const peso = (n: unknown) => { const x = Number(n); return (isFinite(x) ? x : 0).toLocaleString('en-PH'); };
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;
export function formatTime12(t: string | null | undefined): string {
  if (!t) return '';
  const [hh, mm] = String(t).split(':');
  const h = parseInt(hh, 10);
  return `${h === 0 ? 12 : h > 12 ? h - 12 : h}:${mm} ${h >= 12 ? 'PM' : 'AM'}`;
}
const fmtHour = (h: number) => `${h === 0 ? 12 : h > 12 ? h - 12 : h}:00 ${h >= 12 ? 'PM' : 'AM'}`;
// Hand-built: toLocaleDateString differs between Deno builds ("Mon, Sep 14" vs "Mon 14 Sep").
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export const friendlyDate = (d: string) => { const x = new Date(d + 'T00:00:00Z'); return `${DOW[x.getUTCDay()]} ${x.getUTCDate()} ${MON[x.getUTCMonth()]}`; };
const uvLabel = (uv: number) => uv <= 2 ? 'Low' : uv <= 5 ? 'Moderate' : uv <= 7 ? 'High' : uv <= 10 ? 'Very High' : 'Extreme';

// v13 rule kept: row.guest_name wins; the fuzzy name only fills null-named Airbnb calendar rows.
function guestName(row: CalRow, resolved?: string): string {
  const name = String(row.guest_name ?? '').trim();
  if (name) return name;
  if (resolved) return resolved;
  const summary = String(row.raw_summary ?? '').trim();
  return summary && summary.toLowerCase() !== 'reserved' ? summary : 'Guest (name pending)';
}
function findGuestFuzzy(resRows: ResRow[], targetDate: string, field: 'checkin_date' | 'checkout_date'): string | undefined {
  const targetMs = new Date(targetDate + 'T00:00:00Z').getTime();
  let best: { name: string; diff: number } | undefined;
  for (const r of resRows) {
    if (!r.guest_name || !r[field]) continue;
    const diff = Math.abs(new Date(String(r[field]) + 'T00:00:00Z').getTime() - targetMs) / 86_400_000;
    if (diff <= 2 && (!best || diff < best.diff)) best = { name: r.guest_name, diff };
  }
  return best?.name;
}
function names(rows: CalRow[], resRows: ResRow[], date: string, kind: 'arrival' | 'departure'): string {
  return rows.map((r) => {
    const g = guestName(r, findGuestFuzzy(resRows, date, kind === 'arrival' ? 'checkin_date' : 'checkout_date'));
    const bits: string[] = [];
    if (kind === 'arrival' && r.nights) bits.push(plural(Number(r.nights), 'night'));
    const t = kind === 'arrival' ? r.checkin_time : r.checkout_time;
    if (t) bits.push(`${kind === 'arrival' ? 'from' : 'by'} ${formatTime12(t)}`);
    return bits.length ? `${g} (${bits.join(', ')})` : g;
  }).join(', ');
}
const NOTICE_ICON: Record<string, string> = { brownout: '⚡', holiday: '🏖', event: '📅', reminder: '🔔' };
function noticeText(n: Notice): string {
  const time = n.effective_time ? ` at ${formatTime12(n.effective_time)}` : '';
  const dur = n.duration_hours ? ` for ${n.duration_hours}h` : '';
  const feeder = n.feeder ? ` (${n.feeder})` : '';
  return `${NOTICE_ICON[n.notice_type] ?? '📌'} ${n.title}${time}${dur}${feeder}`;
}
export function weatherLine(w: Weather | null): string {
  if (!w) return '';
  const bits = [`${w.description}, ${w.temp}°C (feels ${w.apparent}°C)`, `UV ${w.uvIndex} ${uvLabel(w.uvIndex)}`];
  if (w.rainWindow) {
    const { startHour, endHour, peakProb } = w.rainWindow;
    bits.push(`rain ${startHour === endHour ? `around ${fmtHour(startHour)}` : `${fmtHour(startHour)}–${fmtHour(endHour)}`} peak ${peakProb}%`);
  } else if (w.rainProb >= 40) bits.push(`rain possible (${w.rainProb}%)`);
  if (w.thunderProb >= 40) bits.push(`thunder ${w.thunderProb}%${w.thunderProb >= 70 ? ', secure outdoor items' : ''}`);
  return `Weather: ${bits.join(', ')}`;
}

export function opsReport(i: OpsInput): OpsReport | null {
  const todayNotices = i.notices.filter((n) => n.effective_date === i.today);
  const tmrNotices = i.notices.filter((n) => n.effective_date === i.tomorrow);
  const brownout = i.notices.find((n) => n.notice_type === 'brownout');
  // Session 25 (Telegram plan §2): the digest speaks only when someone moves, a notice lands,
  // a stay reaches its second morning, or an item is actually OUT. Low-but-not-out stock and the
  // weather no longer make a quiet day "active" (one item at 0 had made this fire every day).
  const outOfStock = i.stock.filter((s) => s.qty_on_hand <= 0);
  const midStay = i.midStay ?? [];
  const a = i.arrivals.length, d = i.departures.length;
  const movement = a > 0 || d > 0 || i.tmrArrivals.length > 0 || i.tmrDepartures.length > 0;
  const empty = !movement && !todayNotices.length && !tmrNotices.length && !midStay.length && !outOfStock.length;
  if (empty && !brownout) return null;

  const head = a || d ? [a ? plural(a, 'arrival') : '', d ? plural(d, 'departure') : ''].filter(Boolean).join(', ') : 'no arrivals or departures';
  const decision = `${friendlyDate(i.today)}: ${head}${a && d ? ', same-day turnover' : ''}.`;

  const lines: string[] = [];
  const brk = () => { if (lines.length && lines[lines.length - 1] !== '') lines.push(''); }; // group break (session 28)
  if (todayNotices.length) lines.push(todayNotices.map(noticeText).join('; '));
  if (a) lines.push(`📥 Arriving: ${names(i.arrivals, i.resRows, i.today, 'arrival')}`);
  if (d) lines.push(`📤 Departing: ${names(i.departures, i.resRows, i.today, 'departure')}`);
  for (const m of midStay) lines.push(`🛎 Mid-stay: ${m.guest}, night ${m.night} of ${m.nights} — towels and water topped up? everything okay?`);
  if (outOfStock.length) { brk(); lines.push(`📦 Out of stock: ${outOfStock.map((s) => s.name).join(', ')}`); }
  const w = (a || d) ? weatherLine(i.weather) : '';
  if (w) { brk(); lines.push(`🌤 ${w}`); }
  const tmr: string[] = [];
  if (i.tmrArrivals.length) tmr.push(`arriving ${names(i.tmrArrivals, i.resRows, i.tomorrow, 'arrival')}`);
  if (i.tmrDepartures.length) tmr.push(`departing ${names(i.tmrDepartures, i.resRows, i.tomorrow, 'departure')}`);
  tmr.push(...tmrNotices.map(noticeText));
  const tw = (a || d || i.tmrArrivals.length || i.tmrDepartures.length) ? i.weather?.tomorrow : undefined;
  if (tw) tmr.push(`${tw.description} ${tw.low}–${tw.high}°C${tw.rainProb >= 40 ? `, ${tw.rainProb}% rain` : ''}${tw.thunderProb >= 40 ? ', thunder' : ''}`);
  if (tmr.length) { brk(); lines.push(`📆 Tomorrow: ${tmr.join('; ')}`); }

  const arr = a ? names(i.arrivals, i.resRows, i.today, 'arrival') : '';
  const dep = d ? names(i.departures, i.resRows, i.today, 'departure') : '';
  const action = brownout ? `Prepare for the ${noticeText(brownout).slice(2)}.`
    : outOfStock.length ? `Restock ${outOfStock.map((s) => s.name).join(', ')} today — out of stock.`
    : a && d ? `Coordinate the cleaning window between ${dep} and ${arr}.`
    : a ? `Have the unit ready before ${arr} arrives.`
    : d ? `Inspect the unit after ${dep} checks out.`
    : midStay.length ? `send ${midStay[0].guest} this (Show as text to long-press it, or Revise with Cassy):\n📨 Hi ${midStay[0].guest}, quick check from Cascade Hideaway - is everything okay with the unit? If you need fresh towels, drinking water or anything else, just say the word. 🌿`
    : i.tmrArrivals.length ? `Prepare the unit for ${names(i.tmrArrivals, i.resRows, i.tomorrow, 'arrival')} tomorrow.`
    : todayNotices.length ? `Note ${todayNotices[0].title}.`
    : '';
  const kind: HeaderKind = brownout || outOfStock.length ? 'attention' : 'daily';
  return { decision, lines, action, kind };
}

// ── Weekly roll-ups (Telegram plan §4): Monday, one message per group ────────────────
export type WeeklyOpsInput = {
  today: string;
  lowStock: StockItem[];
  workOrders: Array<{ title: string; priority?: string | null }>;
  handoffs: Array<{ guest: string | null; risk: string | null; days: number }>;
  arrivals: Array<{ guest: string; date: string; nights?: number | null }>;
};
export function weeklyOpsReport(i: WeeklyOpsInput): Report {
  const lines: string[] = [];
  const brk = () => { if (lines.length && lines[lines.length - 1] !== '') lines.push(''); };
  if (i.arrivals.length) lines.push(`📥 This week: ${i.arrivals.map((x) => `${x.guest} ${friendlyDate(x.date)}${x.nights ? ` (${plural(Number(x.nights), 'night')})` : ''}`).join(', ')}`);
  else lines.push('📥 This week: no arrivals booked yet');
  if (i.lowStock.length) { brk(); lines.push(`📦 Low stock: ${i.lowStock.map((s) => `${s.name} ${s.qty_on_hand}${s.unit ? ' ' + s.unit : ''}`).join(', ')}`); }
  if (i.workOrders.length) { brk(); lines.push(`🔧 Open work orders: ${i.workOrders.map((w) => w.title + (w.priority ? ` (${w.priority})` : '')).join('; ')}`); }
  if (i.handoffs.length) { brk(); lines.push(`💬 Guests still waiting on a reply: ${i.handoffs.map((h) => `${h.guest ?? 'guest'} (${h.risk ?? 'question'}, ${plural(h.days, 'day')})`).join(', ')}`); }
  const decision = `Week of ${friendlyDate(i.today)}: ${plural(i.arrivals.length, 'arrival')}, ${plural(i.lowStock.length, 'low-stock item')}, ${plural(i.workOrders.length, 'open work order')}, ${plural(i.handoffs.length, 'unanswered guest')}.`;
  const action = i.handoffs.length ? `Reply to ${i.handoffs[0].guest ?? 'the waiting guest'} first.`
    : i.lowStock.length ? `Restock ${i.lowStock.slice(0, 3).map((s) => s.name).join(', ')} this week.`
    : i.workOrders.length ? `Close out ${i.workOrders[0].title}.`
    : i.arrivals.length ? `Prepare for ${i.arrivals[0].guest} on ${friendlyDate(i.arrivals[0].date)}.` : '';
  return { decision, lines, action };
}

export type WeeklyFinanceInput = {
  today: string;
  pending: Pending[];
  overdueLines: string[];
  /** SPEC-18: `check` picks the problem sentence; `label` is the stored PASSING assertion and is never printed. */
  warns: Array<{ check?: string; label: string; n: number; status: string; d?: Record<string, any> }>;
  consoleUrl: string;
  /** SPEC-10 control 11: one row per reviewer from finance_decisions_week_v1. */
  decisions?: Array<{ reviewer: string; approved: number; rejected: number }>;
};

/** SPEC-10 control 11: who decided what this week. Empty when nobody decided anything — D-160,
 *  the roll-up posts on movement, and "0 confirmed · 0 declined" is not movement. */
export function decisionsLine(rows: WeeklyFinanceInput['decisions']): string {
  const d = rows ?? [];
  const ok = d.reduce((s, r) => s + r.approved, 0), no = d.reduce((s, r) => s + r.rejected, 0);
  if (ok + no === 0) return '';
  const who = d.filter((r) => r.approved > 0).map((r) => `${r.reviewer} ${r.approved}`).join(', ');
  return `🧑‍⚖️ Bookings decided this week: ${ok} confirmed${who ? ` (${who})` : ''} · ${no} declined`;
}
export function weeklyFinanceReport(i: WeeklyFinanceInput): Report {
  const total = i.pending.reduce((s, r) => s + Number(r.gross_amount ?? 0), 0);
  const lines: string[] = [];
  const brk = () => { if (lines.length && lines[lines.length - 1] !== '') lines.push(''); };
  if (i.pending.length) lines.push(`🧾 ${plural(i.pending.length, 'receipt')} awaiting review, ₱${peso(total)} in total`);
  const decided = decisionsLine(i.decisions);
  if (decided) { brk(); lines.push(decided); }
  if (i.overdueLines.length) brk();
  for (const l of i.overdueLines.slice(0, 2)) lines.push(`⏳ ${l}`);
  if (i.warns.length) brk();
  for (const w of i.warns.slice(0, 2)) lines.push(`${w.status === 'fail' ? '🔴' : '🟡'} ${problemSentence(w.check ?? '', w.n, w.d)}`);
  const decision = `Finance week of ${friendlyDate(i.today)}: ${plural(i.pending.length, 'receipt')} pending, ${plural(i.overdueLines.length, 'overdue payout')}, ${plural(i.warns.length, 'health warning')}.`;
  const action = i.overdueLines.length ? 'Chase the overdue payout first.'
    : i.pending.length ? `Confirm the receipts in the admin console: ${i.consoleUrl}`
    : i.warns.length ? 'Open Settings → System health and clear the warnings.' : '';
  return { decision, lines, action };
}

const sourceLabel = (src: string, category: string) => src === 'ocr' ? `receipt, ${category}` : src === 'telegram' ? category : `${category} (${src})`;

export function financeReport(i: FinanceInput): Report | null {
  const count = i.pending.length;
  if (!count && !i.firstOfMonth) return null;
  const total = i.pending.reduce((s, r) => s + Number(r.gross_amount ?? 0), 0);
  const decision = count ? `${plural(count, 'receipt')} awaiting review, ₱${peso(total)} in total.` : 'Books are clean: no receipts awaiting review.';
  const lines: string[] = [];
  if (i.firstOfMonth) lines.push(`Monthly CSV: download Airbnb Transaction History and send the .csv to this chat (last export covered ${i.lastExport ?? 'unknown'}).`);
  const room = 5 - lines.length;
  const shown = i.pending.slice(0, count > room ? room - 1 : room);
  for (const r of shown) {
    lines.push(`${r.transaction_date ? String(r.transaction_date).slice(5) : '—'} · ${r.payee_name ?? '—'} · ₱${peso(r.gross_amount)} · ${sourceLabel(String(r.source ?? ''), String(r.category ?? ''))}`);
  }
  if (count > shown.length) lines.push(`…and ${count - shown.length} more`);
  const action = count ? `Confirm them in the admin console: ${i.consoleUrl}` : i.firstOfMonth ? 'Send this month’s Airbnb CSV to this chat.' : '';
  return { decision, lines, action };
}
