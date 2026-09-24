// finance-watch rules (phase 5, D-106 #5). Pure: rows in, Report out; null when nothing is overdue.
// Two watches, both from existing data:
//   airbnb: confirmed, checked in two or more days ago, no payout email yet (Airbnb pays the day after check-in).
//   direct: pending inquiry, no receipt a day after submission, check-in still ahead (fee is 50 % on booking).
// ponytail: deposit-return watch skipped — only direct bookings pay the ₱1,000 deposit, one confirmed direct
// booking exists, and no table records the deposit taken or returned. Add when direct bookings are regular.
import type { Report } from '../_shared/cascade-core/format.ts';

export type AirbnbRow = { confirmation_code: string; guest_name: string | null; checkin_date: string; host_payout: number | string | null; payout_email_message_id: string | null; status: string };
export type DirectRow = { id: string; guest_name: string | null; checkin_date: string; deposit_amount: number | string | null; submitted_at: string; receipt_image_path: string | null; status: string };
export type Overdue = { kind: 'airbnb' | 'direct'; code: string; guest: string; amount: number; days: number; line: string };

const peso = (n: unknown) => { const x = Number(n); return (isFinite(x) ? x : 0).toLocaleString('en-PH'); };
const dayMs = 86_400_000;
const daysBetween = (from: string, to: string) => Math.floor((new Date(to.slice(0, 10) + 'T00:00:00Z').getTime() - new Date(from.slice(0, 10) + 'T00:00:00Z').getTime()) / dayMs);
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const dm = (d: string) => { const x = new Date(d.slice(0, 10) + 'T00:00:00Z'); return `${x.getUTCDate()} ${MON[x.getUTCMonth()]}`; };

export function overdue(today: string, airbnb: AirbnbRow[], direct: DirectRow[]): Overdue[] {
  const out: Overdue[] = [];
  for (const r of airbnb) {
    if (r.status !== 'confirmed' || r.payout_email_message_id) continue;
    const days = daysBetween(r.checkin_date, today);
    if (days < 2) continue;
    const guest = r.guest_name ?? 'guest';
    out.push({ kind: 'airbnb', code: r.confirmation_code, guest, amount: Number(r.host_payout ?? 0), days,
      line: `Airbnb ${r.confirmation_code} ${guest}: checked in ${dm(r.checkin_date)}, ₱${peso(r.host_payout)} payout not received (${days} days)` });
  }
  for (const r of direct) {
    if (r.status !== 'pending' || r.receipt_image_path) continue;
    const days = daysBetween(r.submitted_at, today);
    if (days < 1 || daysBetween(today, r.checkin_date) < 0) continue;
    const guest = r.guest_name ?? 'guest';
    const code = 'DIR-' + r.id.slice(0, 8).toUpperCase();
    out.push({ kind: 'direct', code, guest, amount: Number(r.deposit_amount ?? 0), days,
      line: `Direct ${code} ${guest}: check-in ${dm(r.checkin_date)}, ₱${peso(r.deposit_amount)} reservation fee unpaid (${days} days)` });
  }
  return out.sort((a, b) => b.days - a.days);
}

/** Cadence (session 26, Telegram plan §4): nudge on day 2, day 5, then every 7 days (12, 19, …). */
export const due = (days: number) => days === 2 || days === 5 || (days > 5 && (days - 5) % 7 === 0);

export function watchReport(today: string, airbnb: AirbnbRow[], direct: DirectRow[]): Report | null {
  const items = overdue(today, airbnb, direct);
  if (!items.length) return null;
  const sum = items.reduce((s, i) => s + i.amount, 0);
  const decision = `${items.length} payment${items.length === 1 ? '' : 's'} overdue, ₱${peso(sum)} in total.`;
  const first = items[0];
  const action = first.kind === 'airbnb'
    ? `Check Airbnb → Earnings for ${first.code} (${first.guest}); if it was paid, forward the payout email so the sync records it.`
    : `Message ${first.guest} for the ₱${peso(first.amount)} reservation fee, or cancel ${first.code} if the dates should be released.`;
  return { decision, lines: items.map((i) => i.line), action };
}

