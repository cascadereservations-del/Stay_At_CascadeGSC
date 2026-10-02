// daily-digest stay cards (D-290 chains, guest-details reminder). Pure: data in, card text out, so digest.test.ts runs it.
// Both cards go to OPS and never show guest money. The tap handlers (stc:done, crm:done) live in telegram-expense.
import { DASH_URL, groups, withHeader, type Btn } from '../_shared/cascade-core/format.ts';
import { chainSpan, type Chain } from '../_shared/cascade-core/chains.ts';
import { friendlyDate, type MidStay } from './report.ts';

export type Card = { text: string; buttons: Btn[]; kind: string; ref: string; title: string; detail: string };
const first = (n: string | null | undefined) => String(n ?? '').trim().split(/\s+/)[0] || 'The guest';
const daysBetween = (a: string, b: string) => Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86_400_000);
const bytes = (s: string) => new TextEncoder().encode(s).length;
/** A booking is direct when its calendar uid says so (`direct:<id>`); anything else came through Airbnb. */
const isDirect = (uid: string, source?: string | null) => uid.startsWith('direct:') || source === 'direct';

/** Junctions that fall on `date`, for the "stays on" line. */
export const stayOnFor = (chains: Chain[], date: string, day: 'today' | 'tomorrow') =>
  chains.filter((c) => c.junction_date === date).map((c) => ({ guest: first(c.guest_name), junction: c.junction_date, day }));

/** Mid-stay nudge for an in-house booking, counted from the start of the whole chained stay (D-290). */
export function midStayFor(row: { uid?: string | null; guest: string; checkin_date: string; checkout_date: string; nights?: number | null }, today: string, chains: Chain[]): MidStay | null {
  const span = row.uid ? chainSpan(row.uid, row.checkin_date, row.checkout_date, chains) : null;
  const start = span?.start ?? row.checkin_date;
  const nights = span ? daysBetween(span.start, span.end) : Number(row.nights ?? daysBetween(row.checkin_date, row.checkout_date));
  const night = daysBetween(start, today) + 1;
  return nights < 3 || night !== 2 ? null : { guest: row.guest, night, nights };
}

/** One OPS card per chain junction: what happened, then Marifel's steps in Airbnb. Done button when the callback fits 64 bytes. */
export function chainCard(c: Chain): Card {
  const j = friendlyDate(c.junction_date), g = String(c.guest_name ?? '').trim() || 'The guest';
  const aFirst = !isDirect(c.first_uid, c.first_source), aNext = !isDirect(c.next_uid);
  const what = aFirst && aNext ? 'two Airbnb bookings' : !aFirst && !aNext ? 'two direct bookings' : 'two bookings (one Airbnb, one direct)';
  const happened = `${g} stays ${friendlyDate(c.first_checkin)} to ${friendlyDate(c.next_checkout)} on ${what}, joined ${j}. No turnover and no cleaning on ${j}.`;
  const a = c.first_code ?? 'the first booking', b = c.next_code ?? 'the second booking';
  const steps: string[] = [];
  if (aFirst) steps.push(`On ${a} (ends ${j}) skip "Checkout Reminder w/ Next Guest" and "5.2 After Departure".`);
  else steps.push(`${a} is a direct booking: our messages already adjust.`);
  if (aNext) steps.push(`On ${b} (starts ${j}) skip "2. Pre-Arrival Welcome" and send a short note instead of re-asking IDs (the booking confirmation went out automatically).`);
  else steps.push(`${b} is a direct booking: our messages already adjust.`);
  if (aFirst || aNext) steps.push('Keep the same door code for the whole stay.');
  if (aFirst && aNext) steps.push("Next time use Airbnb's Change reservation to extend instead of a second booking.");
  const todo = aFirst || aNext
    ? ['Marifel, in Airbnb:', ...steps.map((s, i) => `${i + 1}. ${s}`)]
    : ['Our messages already adjust, no Airbnb action.', 'Keep the same door code for the whole stay.'];
  const cb = c.first_code ? `stc:done:${c.junction_date}:${c.first_code}` : '';
  return {
    text: withHeader('attention', `${first(g)} stays on`, groups([happened], todo)),
    buttons: cb && bytes(cb) <= 64 ? [{ text: '✅ Done', callback_data: cb }] : [],
    kind: 'stay_continues', ref: `${c.junction_date}:${c.first_code ?? c.first_uid}`.slice(0, 100),
    title: `${first(g)} stays on across ${j} (two bookings): no turnover`.slice(0, 200), detail: happened,
  };
}

export type DetailsStay = { guestId: string; guest: string; checkin: string; code?: string | null; source?: string | null };

/** The guest-details reminder: one OPS card per stay, with an Open guest link and a Saved button. */
export function detailsCard(s: DetailsStay, today: string): Card {
  const chat = s.source === 'direct' ? 'Messenger' : 'Airbnb';
  const line = `Guest details not saved yet: ${s.guest} ${s.checkin >= today ? 'arrives' : 'arrived'} ${friendlyDate(s.checkin)}${s.code ? ` (${s.code})` : ''}. Save the names, mobile number and ID photos they sent in the ${chat} chat to the dashboard.`;
  return {
    text: withHeader('attention', 'guest details', groups([line])),
    buttons: [{ text: 'Open guest', url: `${DASH_URL}guests/${s.guestId}` }, { text: '✅ Saved', callback_data: `crm:done:${s.checkin}:${s.guestId}` }],
    kind: 'guest_details', ref: `${s.checkin}:${s.guestId}`,
    title: `Save guest details: ${s.guest}, ${friendlyDate(s.checkin)}`.slice(0, 200), detail: line,
  };
}
