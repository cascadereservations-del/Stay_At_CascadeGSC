// Session 59 (Lloyd 2026-09-28): priority help for a guest staying now. A Messenger menu button / ice breaker (postback
// PRIORITY) or the welcome guide's m.me link (ref "priority" or "priority:<check-in>:<initial>") starts it. The check is
// the welcome guide's own: verify_booking(check-in date, first letter of the booking name), and the stay must be current
// (in-house, or arriving today). The number is public already (Facebook, confirmation e-mail); what verification guards is
// the urgent host alert, so strangers cannot page the host. Pure: index.ts does the calls.
import { parseDates, parseName } from './booking.ts';

export const PRIORITY_PAYLOAD = 'PRIORITY';
export type PriorityEntry = { kind: 'start' } | { kind: 'verify'; date: string; initial: string };

/** A menu tap, an ice breaker, or an m.me referral (new thread: inside the get-started postback; open thread: ev.referral). */
export function priorityEntry(ev: Record<string, any>): PriorityEntry | null {
  const ref = String(ev?.referral?.ref ?? ev?.postback?.referral?.ref ?? '');
  const m = /^priority:(\d{4}-\d{2}-\d{2}):(\p{L})$/u.exec(ref);
  if (m) return { kind: 'verify', date: m[1], initial: m[2] };
  if (ref === 'priority' || String(ev?.postback?.payload ?? '') === PRIORITY_PAYLOAD) return { kind: 'start' };
  return null;
}

const manilaToday = (now: Date) => new Date(now.getTime() + 8 * 3_600_000).toISOString().slice(0, 10);

/** The guest's answer to the ask: a check-in date (never in the future: "Sept 27" on the 28th is this year) and an initial. */
export function priorityAnswer(text: string, now = new Date()): { date: string | null; initial: string | null } {
  let date = parseDates(text, now)[0] ?? null;
  if (!date && /\b(yesterday|kahapon|gahapon|kagabi)\b/i.test(text)) date = manilaToday(new Date(now.getTime() - 86_400_000));
  // parseDates reads a past day as next year (it serves bookings); a check-in the guest is living is today or before.
  if (date && date > manilaToday(now)) date = `${+date.slice(0, 4) - 1}${date.slice(4)}`;
  const name = parseName(text.replace(/\b(today|tonight|ngayon|karon|kagabi|yesterday|kahapon|gahapon|check(ed|ing)?[- ]?in|arrived?|came|we|date|booking|under|staying|stayed|stay|last|night|from|since|on)\b/gi, ' '));
  const lone = /(?:^|[\s,.;:])(\p{L})(?=$|[\s,.;:])/u.exec(text.replace(/\b(i|a)\s+(?=\p{L}{2})/giu, ' ')); // "Sept 27, A"; not "I am" / "a stay"
  return { date, initial: name ? name[0] : lone ? lone[1].toUpperCase() : null };
}

export type VerifyResult = { found?: boolean; match?: boolean; expired?: boolean; first_name?: string; full_name?: string; checkin_date?: string; checkout_date?: string };

/** Verified = the name matches AND the stay is on today (check-in <= today <= check-out, Manila). */
export function stayIsCurrent(r: VerifyResult | null, now = new Date()): boolean {
  const today = manilaToday(now);
  return !!r?.match && !!r.checkin_date && !!r.checkout_date && r.checkin_date <= today && today <= r.checkout_date;
}
