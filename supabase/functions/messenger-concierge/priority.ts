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
  if (ref === 'priority' || String(ev?.postback?.payload ?? '') === PRIORITY_PAYLOAD || String(ev?.message?.quick_reply?.payload ?? '') === PRIORITY_PAYLOAD) return { kind: 'start' };
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

/** A menu tap that is not priority help is the guest's question in the button's words; Get Started (Meta requires the button
 *  for a persistent menu) is a hello, so a new chatter who taps it gets the greeting, not silence. */
export function postbackText(ev: Record<string, any>): string {
  if (!ev?.postback || priorityEntry(ev)) return '';
  const payload = String(ev.postback.payload ?? '').trim();
  if (payload === 'GET_STARTED') return 'Hi';
  // The menu's payload is the full question ("Dates and price" -> "How much is it, and are my dates available?"); a code-like
  // payload (CAPS_AND_UNDERSCORES) falls back to the button's label.
  return payload && !/^[A-Z0-9_]+$/.test(payload) ? payload : String(ev.postback.title ?? '').trim();
}

// Session 59 (D-281, Lloyd: "only show ... to contact immediately the host if the name is detected to be the current guest or
// the guest requested to contact the host or indicated ... she is currently staying or connected with the guest and have
// emergency"). One quick reply, rules from [[DESIGN-contact-host-button-2026-09-28]] (Fable). A tap is PRIORITY: the flow above.
export const CONTACT_CHIP = { title: 'Reach my host', payload: PRIORITY_PAYLOAD };
const HOST_ASK_RE = /\b(contact|call|reach|talk to|speak to|message|text|number of|kausap|makausap|tawag|tawagan|kontak|ma-?contact|istorya|number sa)\b[^.?!\n]{0,25}\b(host|owner|caretaker|manager|may-?ari|tag-?iya)\b|\bhost'?s? (number|contact|phone)\b/i;
const PROSPECT_RE = /\b(before|bago|if|kung|kapag)\b[^.?!\n]{0,20}\b(book|booking|mag-?book|reserve)|\b(planning to|interested)\b/i;
const STAYING_RE = /\b(staying|renting|rented|checked[- ]?in|nag[- ]?re?rent|nag[- ]?stay|nagsstay|nakacheck-?in|na-?check-?in)\b/i;
const NOW_RE = /\b(now|right now|rn|currently|tonight|ngayon|karon|na po|na kami|na mi|until|hanggang|hangtod|my stay (here )?is|stay (ko|namin|nako|namo))\b/i;
const HERE_NOW_RE = /\b(andito|nandito|naa (mi|ko|kami) diri|nia mi diri|dinhi mi|my stay (here )?is (until|till|hanggang))\b/i; // live 2026-09-28: "my stay here is until Sunday"
const PAST_RE = /\b(last (year|month|week|time)|dati|noon|kaniadto|niadto|sauna|stayed)\b/i;
const COMPANION_RE = /\b(friend|girlfriend|boyfriend|wife|husband|partner|sister|brother|mom|dad|kaibigan|asawa|kapatid|jowa|uyab|amiga|amigo|higala)\b[^.?!\n]{0,25}\b(book|booked|nag-?book|rent|renting|nag-?rent|guest|stay|staying)\b|\bi'?m with the guest\b|\bkasama ko (ang|si) guest\b|\bkauban nako ang guest\b/i;
const PLACEHOLDER = new Set(['', 'reserved', 'airbnb', 'not', 'guest']);
const first = (s: string | null | undefined) => (s ?? '').trim().split(/\s+/)[0]?.toLowerCase() ?? '';

/** The guest says they are at the residence now ("nag rerent ... now", "andito na po kami", "my stay here is until Sunday");
 *  "rented last year, how much now?" is a prospect. Also mutes the booking pitch for them (Lloyd 2026-09-28). */
export function isStayingNow(text: string): boolean {
  return text.split(/[.?!\n]+/).some((x) => HERE_NOW_RE.test(x) || (STAYING_RE.test(x) && NOW_RE.test(x) && !PAST_RE.test(x)));
}

/** The contact-host quick reply for this turn, or null. `inHouse`: guest_name / raw_summary of stays on today. */
export function contactHostChip(text: string, o: {
  risk: string; profileName: string | null; inHouse: string[]; flowActive: boolean; priorityOpen: boolean;
  history: { role: string; at: string; route?: Record<string, unknown> }[]; now: Date;
}): typeof CONTACT_CHIP | null {
  if (o.flowActive || o.priorityOpen || !text) return null;
  if (o.history.some((h) => h.role === 'bot' && h.route?.chip === PRIORITY_PAYLOAD && o.now.getTime() - Date.parse(h.at) < 12 * 3_600_000)) return null;
  const staying = isStayingNow(text);
  const hostAsk = HOST_ASK_RE.test(text) && !PROSPECT_RE.test(text);
  const companion = COMPANION_RE.test(text) && ['access', 'safety', 'complaint'].includes(o.risk);
  const names = [first(parseName(text)), first(o.profileName)].filter((n) => n.length >= 2);
  const stays = o.inHouse.map(first).filter((n) => !PLACEHOLDER.has(n));
  const named = names.some((n) => stays.includes(n));
  return staying || hostAsk || companion || named ? CONTACT_CHIP : null;
}

