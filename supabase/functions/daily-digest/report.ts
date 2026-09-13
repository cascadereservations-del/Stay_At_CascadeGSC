// daily-digest report (phase 4, D-106 #4). Data in, Report out. Pure: no I/O, so digest.test.ts runs it.
// Shape is owned by cascade-core/format.ts: one decision, at most five lines, one action. Plain text.
import type { Report } from '../_shared/cascade-core/format.ts';

export type CalRow = { guest_name?: string | null; raw_summary?: string | null; checkin_time?: string | null; checkout_time?: string | null; nights?: number | null };
export type ResRow = { guest_name: string | null; checkin_date: string | null; checkout_date: string | null };
export type Notice = { notice_type: string; title: string; effective_date: string; effective_time?: string | null; duration_hours?: number | null; feeder?: string | null };
export type StockItem = { name: string; qty_on_hand: number; unit?: string | null; runway: number };
export type Weather = {
  temp: number; apparent: number; rainProb: number; uvIndex: number; description: string; thunderProb: number;
  rainWindow?: { startHour: number; endHour: number; peakProb: number };
  tomorrow?: { description: string; high: number; low: number; rainProb: number; thunderProb: number };
};
export type OpsInput = {
  today: string; tomorrow: string;
  arrivals: CalRow[]; departures: CalRow[]; tmrArrivals: CalRow[]; tmrDepartures: CalRow[];
  notices: Notice[]; stock: StockItem[]; weather: Weather | null; resRows: ResRow[];
};
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
const friendlyDate = (d: string) => { const x = new Date(d + 'T00:00:00Z'); return `${DOW[x.getUTCDay()]} ${x.getUTCDate()} ${MON[x.getUTCMonth()]}`; };
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

export function opsReport(i: OpsInput): Report | null {
  const todayNotices = i.notices.filter((n) => n.effective_date === i.today);
  const tmrNotices = i.notices.filter((n) => n.effective_date === i.tomorrow);
  const brownout = i.notices.find((n) => n.notice_type === 'brownout');
  const orderToday = i.stock.filter((s) => s.runway <= 1);
  const a = i.arrivals.length, d = i.departures.length;
  const empty = !a && !d && !todayNotices.length && !i.tmrArrivals.length && !i.tmrDepartures.length && !tmrNotices.length && !i.stock.length;
  if (empty && !brownout && !orderToday.length) return null;

  const head = a || d ? [a ? plural(a, 'arrival') : '', d ? plural(d, 'departure') : ''].filter(Boolean).join(', ') : 'no arrivals or departures';
  const decision = `${friendlyDate(i.today)}: ${head}${a && d ? ', same-day turnover' : ''}.`;

  const lines: string[] = [];
  if (todayNotices.length) lines.push(todayNotices.map(noticeText).join('; '));
  if (a) lines.push(`Arriving: ${names(i.arrivals, i.resRows, i.today, 'arrival')}`);
  if (d) lines.push(`Departing: ${names(i.departures, i.resRows, i.today, 'departure')}`);
  if (i.stock.length) {
    lines.push(`Low stock: ${i.stock.map((s) => `${s.name} ${s.qty_on_hand}${s.unit ? ' ' + s.unit : ''} (${s.runway <= 1 ? 'order today' : `~${plural(Math.round(s.runway), 'day')} left`})`).join(', ')}`);
  }
  const w = weatherLine(i.weather);
  if (w) lines.push(w);
  const tmr: string[] = [];
  if (i.tmrArrivals.length) tmr.push(`arriving ${names(i.tmrArrivals, i.resRows, i.tomorrow, 'arrival')}`);
  if (i.tmrDepartures.length) tmr.push(`departing ${names(i.tmrDepartures, i.resRows, i.tomorrow, 'departure')}`);
  tmr.push(...tmrNotices.map(noticeText));
  const tw = i.weather?.tomorrow;
  if (tw) tmr.push(`${tw.description} ${tw.low}–${tw.high}°C${tw.rainProb >= 40 ? `, ${tw.rainProb}% rain` : ''}${tw.thunderProb >= 40 ? ', thunder' : ''}`);
  if (tmr.length) lines.push(`Tomorrow: ${tmr.join('; ')}`);

  const arr = a ? names(i.arrivals, i.resRows, i.today, 'arrival') : '';
  const dep = d ? names(i.departures, i.resRows, i.today, 'departure') : '';
  const action = brownout ? `Prepare for the ${noticeText(brownout).slice(2)}.`
    : orderToday.length ? `Order ${orderToday.map((s) => s.name).join(', ')} today.`
    : a && d ? `Coordinate the cleaning window between ${dep} and ${arr}.`
    : a ? `Have the unit ready before ${arr} arrives.`
    : d ? `Inspect the unit after ${dep} checks out.`
    : todayNotices.length ? `Note ${todayNotices[0].title}.`
    : i.stock.length ? `Restock ${i.stock.map((s) => s.name).join(', ')} this week.`
    : '';
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
