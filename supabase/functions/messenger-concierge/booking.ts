// Messenger book intent (booking PRD §A, session 27). Pure functions, no I/O: a code-driven
// slot-filling flow that index.ts runs BEFORE the model. The model never books; it only answers
// questions. State is one jsonb on concierge_threads.booking_flow.
import { RATE_TIERS } from '../_shared/cascade-core/facts.ts';

/** Register: en = Native English protocol, tl = Native Filipino (Taglish, purposeful po), bis = Native Bisaya (Bislish, no po). */
export type Lang = 'en' | 'tl' | 'bis';
export const pick = (lang: Lang | undefined, t: { en: string; tl: string; bis: string }): string => t[lang ?? 'en'];
export type Flow = {
  step: 'dates' | 'checkout' | 'pax' | 'offer' | 'contact' | 'confirm' | 'await_receipt' | 'receipt_sent' | 'confirmed' | 'cancelled';
  checkin?: string; checkout?: string; pax?: number; phone?: string; email?: string | null;
  /** SPEC-14 (D-184): the name for the reservation, asked in the details step; it wins over the Facebook profile name. */
  name?: string;
  /** session 28: the guest's choice - reservation fee (50 %) or the full amount; forced full inside 48 h */
  pay_full?: boolean; asked?: 'availability' | 'question' | null;
  /** session 28: the guest's register, re-read on every turn - 'tl' = Taglish with "po" (Tagalog or Bisaya guests) */
  lang?: Lang;
  bis_turns?: number; // consecutive Bisaya guest turns (settleLang)
  booking_id?: string; ref?: string; deposit?: number; total?: number; hold?: boolean; hold_expires_at?: string | null;
  receipt_token?: string; receipt_expires_at?: string; started_at: string; updated_at: string;
};

export const BOOK_RE = /\b(book(ing)?|reserve|reservation|magpa-?book|pa-?book|i-?book|mag-?reserve|hold (the|my|our) dates|arrange (it|the booking)|(do|settle) it here|here in (the|this) chat|dito (po )?sa chat|diri sa chat)\b/i; // session 30: invitations now offer the chat route, so its natural answers start the flow
const CANCEL_RE = /\b(cancel|stop|wag na|huwag|never ?mind|nevermind|not now|forget it)\b/i;
const YES_RE = /^\s*(yes|yes po|oo|oo po|sige|sige po|go|confirm|confirmed|ok|okay|okay po|ok po|proceed|tama|correct|yup|yep|y)\s*[.!]*\s*$/i;
const SKIP_RE = /^\s*(skip|wala|none|no email|no)\s*[.!]*\s*$/i;
const FULL_RE = /\b(full|buo|buong|lahat|whole|everything|total|bayaran (ko )?lahat|in full)\b/i;
const DEPOSIT_RE = /\b(deposit|reservation fee|fee|50|half|kalahati|reserve|partial|down ?payment|dp)\b/i;
const AVAIL_RE = /\b(available|avail|vacant|bakante|open|free|may (?:vacancy|slot)|meron pa)\b/i;
/** SPEC-14 (D-184): the answers to "Shall we set the dates aside for you?" */
const OFFER_YES_RE = /^\W*(yes|yes please|yes po|sure|of course|ok(ay)?( po)?|sige( po)?|oo( po)?|opo|go|please do|proceed|set (it|them) aside)\b/i;
const OFFER_NO_RE = /^\W*(no|not (yet|now)|hindi( po)?|dili|wala( pa)?|later|maybe later)\b/i;
const ASK_RE = /\?|\b(magkano|how much|pwede|can (i|we)|is (it|there)|are there|meron)\b/i;
/** Same markers as index.ts guestLang(): Tagalog or Bisaya words, or two particles, mean Taglish; a lone courtesy "po" stays English. */
/** Lloyd 2026-09-17 14:40: English and Taglish come first; Bislish only once the guest KEEPS replying in Bisaya.
 *  A first Bisaya turn is answered in Taglish; the second consecutive one switches the register to Bislish. */
export function settleLang(prev: Lang | undefined, detected: Lang, bisTurns: number): { lang: Lang; bisTurns: number } {
  if (detected !== 'bis') return { lang: detected, bisTurns: 0 };
  const n = bisTurns + 1;
  return { lang: n >= 2 || prev === 'bis' ? 'bis' : 'tl', bisTurns: n };
}
export function detectLang(text: string): Lang {
  const t = ` ${text.toLowerCase()} `;
  if (/\b(naa|unsa|asa|kanus-a|pila|maayong|salamat kaayo|ba mo|mo ba|nimo|karon|kaayo|kini|namo|nako|unya|gani|diri|didto|wala'y|walay|palihog|tagpila|pwede ba|pila ka|usbon|usba|mi|kabuok|tawo|ug|og|dili|among|ugma|gahapon|muabot|moabot)\b/.test(t)) return 'bis';
  if (/\b(ang|ng|mga|kayo|ninyo|magkano|pwede|puwede|salamat|meron|kailan|saan|paano|bukas|ngayon|opo|hindi|kasi|namin|natin|sige|okay lang|ayos|kami|ako|niyo|nyo|gusto|bakante|kaming|muna)\b/.test(t)) return 'tl';
  return (t.match(/\b(po|ba|lang|naman|opo)\b/g) ?? []).length >= 2 ? 'tl' : 'en';
}
const MONTHS: Record<string, number> = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12 };
const FLOW_TTL_MS = 24 * 3_600_000;

const pad = (n: number) => String(n).padStart(2, '0');
const iso = (y: number, m: number, d: number) => `${y}-${pad(m)}-${pad(d)}`;
function valid(y: number, m: number, d: number): boolean {
  const t = new Date(Date.UTC(y, m - 1, d)); return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
}
/** Year for a month/day the guest typed: this year, or next year if that day is already past. */
function yearFor(m: number, d: number, now: Date): number {
  const y = now.getUTCFullYear();
  const today = iso(y, now.getUTCMonth() + 1, now.getUTCDate());
  return iso(y, m, d) < today ? y + 1 : y;
}

/** Parse up to two dates from free text. Handles "Sep 24-26", "Sept 24 to Oct 2", "24-26 Sep", "9/24-9/26", "2026-09-24". */
export function parseDates(text: string, now = new Date()): string[] {
  const out: string[] = [];
  const push = (y: number, m: number, d: number) => { if (valid(y, m, d) && out.length < 2) out.push(iso(y, m, d)); };
  const t = text.toLowerCase().replace(/(\d)(st|nd|rd|th)\b/g, '$1');
  for (const m of t.matchAll(/\b(20\d\d)-(\d{1,2})-(\d{1,2})\b/g)) push(+m[1], +m[2], +m[3]);
  if (out.length) return out;
  for (const m of t.matchAll(/\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?\s*(\d{1,2})(?:,?\s*(20\d\d))?(?:\s*(?:-|–|to|hanggang|until|till)\s*(?:(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?\s*)?(\d{1,2})(?:,?\s*(20\d\d))?)?/g)) {
    const m1 = MONTHS[m[1]], d1 = +m[2], y1 = m[3] ? +m[3] : yearFor(m1, d1, now);
    push(y1, m1, d1);
    if (m[5]) { const m2 = m[4] ? MONTHS[m[4]] : m1; const d2 = +m[5]; const y2 = m[6] ? +m[6] : (m2 < m1 ? y1 + 1 : y1); push(y2, m2, d2); }
  }
  if (out.length) return out;
  for (const m of t.matchAll(/\b(\d{1,2})(?:\s*(?:-|–|to|hanggang)\s*(\d{1,2}))?\s+(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\b/g)) {
    const mo = MONTHS[m[3]], d1 = +m[1], y = yearFor(mo, d1, now);
    push(y, mo, d1); if (m[2]) push(y, mo, +m[2]);
  }
  if (out.length) return out;
  // "9/24-9/26" (month/day, the booking site's convention)
  for (const m of t.matchAll(/\b(\d{1,2})[\/.](\d{1,2})(?:[\/.](20\d\d))?\b/g)) {
    const mo = +m[1], d = +m[2]; if (mo < 1 || mo > 12) continue; push(m[3] ? +m[3] : yearFor(mo, d, now), mo, d);
  }
  return out;
}

/** SPEC-14 (D-184): an availability question that carries a future check-in starts the flow, book word or not. */
export function availStart(text: string, now = new Date()): boolean {
  if (!AVAIL_RE.test(text)) return false;
  const d = parseDates(text, now);
  return !!d[0] && d[0] >= now.toISOString().slice(0, 10);
}
export function parsePax(text: string): number | null {
  const words: Record<string, number> = { one: 1, isa: 1, two: 2, dalawa: 2, duha: 2, three: 3, tatlo: 3, tulo: 3, four: 4, apat: 4, upat: 4 };
  // A count next to a guest word wins over any other number ("Sep 24 to 26 for 2 adults" -> 2).
  const m = /\b(\d{1,2}|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\s*(?:adults?|pax|persons?|people|guests?|tao|tawo|kami|mi|ka|kabuok)\b/i.exec(text)
    ?? /\b(?:for|para sa|kaming)\s+(\d{1,2}|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\b(?!\s*(?:nights?|days?|gabi|araw))/i.exec(text) // "book for 2" (live 2026-09-17 09:53)
    ?? /\b(\d{1,2}|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\b/i.exec(text);
  if (!m) return null;
  const n = /^\d+$/.test(m[1]) ? +m[1] : words[m[1].toLowerCase()];
  return n >= 1 ? n : null;
}
export function parsePhone(text: string): string | null {
  const digits = text.replace(/[^\d+]/g, '');
  const m = /(?:\+?63|0)(9\d{9})/.exec(digits);
  return m ? '0' + m[1] : null;
}
/** SPEC-14 (D-184): the name for the reservation - the message minus phone and e-mail, title-cased.
 *  Courtesy words and slot answers are not names, so "yes po" and "skip" never become one. */
const NAME_STOP = /^(yes|yeah|yep|sure|ok|okay|sige|oo|opo|po|salamat|thanks?|thank|you|hi|hello|hey|my|name|is|the|for|reservation|and|or|email|e-?mail|mobile|number|contact|address|no|none|skip|na|lang|ako|si|im|this|kay|ang|sa|ni|akong|nako|namo|tawag|jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec|nights?|days?|guests?|adults?|pax|kids?|children)$/i;
export function parseName(text: string): string | null {
  const rest = text
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, ' ')
    .replace(/[+\d][\d\s().-]{4,}\d/g, ' ');
  const toks = (rest.match(/[\p{L}][\p{L}'.-]*/gu) ?? [])
    .map((w) => w.replace(/[^\p{L}'-]/gu, ''))
    .filter((w) => w.length >= 2 && !NAME_STOP.test(w));
  if (!toks.length) return null;
  return toks.slice(0, 4).map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(' ');
}
export function parseEmail(text: string): string | null {
  const m = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.exec(text);
  return m ? m[0].toLowerCase() : null;
}

const dm = (d: string) => { const x = new Date(d + 'T00:00:00Z'); return `${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][x.getUTCMonth()]} ${x.getUTCDate()}`; };
/** SPEC-14 (D-184): "Nov 17 to 19" inside one month, "Nov 30 to Dec 2" across two. */
export const dmRange = (a: string, b: string) => { const A = dm(a), B = dm(b); return A.slice(0, 3) === B.slice(0, 3) ? `${A} to ${B.slice(4)}` : `${A} to ${B}`; };
export type Window = { start: string; end: string; nights: number; open_ended?: boolean };
export const windowText = (w: Window) => w.open_ended ? `${dm(w.start)} onwards` : dmRange(w.start, w.end);
/** Runs of open nights across a horizon, as check-in -> check-out windows (pure: the caller fetches the calendar). */
export function openWindows(bookedNights: Set<string>, today: string, horizonEnd: string): Window[] {
  const out: Window[] = [];
  const next = (d: string) => new Date(Date.parse(d + 'T00:00:00Z') + 86_400_000).toISOString().slice(0, 10);
  const span = (a: string, b: string) => Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86_400_000);
  let runStart: string | null = null;
  for (let d = today; d < horizonEnd; d = next(d)) {
    if (bookedNights.has(d)) { if (runStart) { out.push({ start: runStart, end: d, nights: span(runStart, d) }); runStart = null; } }
    else if (!runStart) runStart = d;
  }
  if (runStart) out.push({ start: runStart, end: horizonEnd, nights: span(runStart, horizonEnd), open_ended: true });
  return out;
}
const nights = (a: string, b: string) => Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86_400_000);
const peso = (v: number) => `₱${v.toLocaleString('en-PH')}`;
/** Site rate card: nightly tier by length of stay × nights (the site and submit-booking compute the same). */
export function quoteTotal(checkin: string, checkout: string): { nights: number; rate: number; total: number; deposit: number } {
  const n = Math.max(1, nights(checkin, checkout));
  const tier = RATE_TIERS.find((t) => n >= t.min && n <= t.max) ?? RATE_TIERS[RATE_TIERS.length - 1];
  const total = tier.rate * n;
  return { nights: n, rate: tier.rate, total, deposit: Math.ceil(total / 2) };
}
/** Check-in inside 48 h: the site asks the full amount, so the choice is not offered. */
export const within48h = (checkin: string, now = new Date()) => Date.parse(checkin + 'T14:00:00+08:00') - now.getTime() < 48 * 3_600_000;
const STD_RATE = RATE_TIERS[0].rate; // the one-night rate: the standard the direct discount is measured against
const php = (v: number) => `PHP ${v.toLocaleString('en-PH')}`;
/** SPEC-14 (D-184): the direct-booking rate, said before the offer. Every figure comes from quoteTotal / RATE_TIERS. */
export function rateLine(flow: Flow, now = new Date()): string {
  const q = quoteTotal(flow.checkin!, flow.checkout!);
  const body = q.nights >= 2
    ? pick(flow.lang, {
        en: `Booking directly with us brings your ${q.nights} nights to ${php(q.rate)} per night instead of the standard ${php(STD_RATE)} — ${php(q.total)} for the stay.`,
        tl: `Kapag direct booking po sa amin, ang ${q.nights} nights ninyo ay nasa ${php(q.rate)} per night imbes na ang standard na ${php(STD_RATE)} — ${php(q.total)} for the stay.`,
        bis: `Kung direct booking sa amo, ang inyong ${q.nights} nights kay ${php(q.rate)} per night imbes sa standard nga ${php(STD_RATE)} — ${php(q.total)} for the stay.`,
      })
    : pick(flow.lang, {
        en: `For 1 night the direct rate is ${php(q.rate)}.`,
        tl: `For 1 night po, ang direct rate ay ${php(q.rate)}.`,
        bis: `For 1 night, ang direct rate kay ${php(q.rate)}.`,
      });
  // The site's own rule (D-166): inside 48 hours the full amount secures the stay, so the choice is never offered.
  return within48h(flow.checkin!, now)
    ? `${body} ${pick(flow.lang, {
        en: `As your check-in is within 48 hours, the full amount secures the stay.`,
        tl: `Dahil within 48 hours na po ang check-in, ang full amount ang magse-secure ng stay.`,
        bis: `Kay within 48 hours na ang check-in, ang full amount ang mo-secure sa stay.` })}`
    : body;
}
/** SPEC-14 (D-184): the card's payment sentence - the fee-or-full choice, or the full-only sentence inside 48 h. */
export function payChoice(flow: Flow): string {
  const q = quoteTotal(flow.checkin!, flow.checkout!);
  return flow.pay_full === true
    ? pick(flow.lang, {
        en: `As your check-in is near, the full ${peso(q.total)} secures your stay. You may reply FULL to send your request through, or let us know if anything needs changing.`,
        tl: `Malapit na po ang check-in, kaya ang full ${peso(q.total)} ang magse-secure ng stay. You may reply FULL to send the request through, or sabihin lang po if may kailangang baguhin.`,
        bis: `Duol na ang check-in, so ang full ${peso(q.total)} ang mag-secure sa stay. Pwede mo mu-reply og FULL para ma-send ang request, or ingna lang mi if naa may changes.` })
    : pick(flow.lang, {
        en: `A reservation fee of ${peso(q.deposit)} holds the dates, with the balance settled at check-in; or you may settle the full ${peso(q.total)} now. Just tell us "fee" or "full", whichever suits you.`,
        tl: `Ang reservation fee na ${peso(q.deposit)} ang magho-hold ng dates, at ang balance ay babayaran at check-in; o puwede rin pong bayaran ang full ${peso(q.total)} ngayon. Sabihin lang po "fee" o "full", kung alin ang mas okay sa inyo.`,
        bis: `Ang reservation fee nga ${peso(q.deposit)} ang mo-hold sa dates, ug ang balance bayran sa check-in; o pwede pud bayran ang full ${peso(q.total)} karon. Ingna lang mi og "fee" o "full", kung asa ang mas okay ninyo.` });
}
/** SPEC-14 (D-184): the cancel / "not now" reply. Nothing is committed, and the dates alone reopen the flow. */
export const cancelReply = (lang: Lang | undefined) => pick(lang, {
  en: `Of course, and there's no rush at all. Nothing has been sent, so nothing is committed. Whenever you'd like to continue, just send your dates again and we'll pick up right where we left off. 🌿`,
  tl: `No problem po, take your time. Wala pong na-send, so nothing is committed. Whenever you're ready, i-send lang po ulit ang dates ninyo and we'll pick up right where we left off. 🌿`,
  bis: `Walay problema, take your time. Walay na-send, so nothing is committed. Whenever you're ready, i-send lang balik ang inyong dates and we'll pick up right where we left off. 🌿`,
});
/** A code answer to "is it available?" from the calendar rows that overlap the stay (pure: index.ts fetches). */
export function availabilityLine(flow: Flow, bookedNights: Set<string> | null, nearest?: Window | null): string {
  if (!flow.checkin || !flow.checkout) return '';
  const dates = dmRange(flow.checkin, flow.checkout);
  // null = the calendar could not be read: never claim the dates are open (session 30).
  if (!bookedNights) return pick(flow.lang, {
    en: `We're checking ${dates} on our calendar and will confirm shortly`,
    tl: `Iche-check po namin ang ${dates} sa calendar and we'll confirm shortly`,
    bis: `Amo i-check ang ${dates} sa calendar and we'll confirm shortly`,
  });
  for (let d = flow.checkin; d < flow.checkout; d = new Date(Date.parse(d + 'T00:00:00Z') + 86_400_000).toISOString().slice(0, 10)) {
    if (bookedNights.has(d)) return nearest ? pick(flow.lang, {
      en: `${dates} is already reserved. The nearest open dates are ${windowText(nearest)}, and we'd be glad to check any others for you — just share your check-in and check-out.`,
      tl: `Reserved na po ang ${dates}. Ang nearest open dates ay ${windowText(nearest)}, at gladly naming iche-check ang iba pang dates para sa inyo — share lang po ang check-in at check-out.`,
      bis: `Reserved na ang ${dates}. Ang nearest open dates kay ${windowText(nearest)}, ug amo dayon i-check ang uban dates para ninyo — share lang ang check-in ug check-out.`,
    }) : pick(flow.lang, {
      en: `${dates} is already reserved, as the home welcomes one party at a time. If other dates suit you, just share your check-in and check-out and we'll gladly check them for you.`,
      tl: `Reserved na po ang ${dates} — one party lang ang tinatanggap namin per stay. If may ibang dates kayong gusto, share lang po ang check-in and check-out and iche-check namin agad.`,
      bis: `Reserved na ang ${dates} — one party ra ang ma-accommodate namo per stay. If naa moy other dates, share lang ang check-in and check-out and amo dayon i-check.`,
    });
  }
  return pick(flow.lang, { en: `${dates} is available`, tl: `Available po ang ${dates}`, bis: `Available ang ${dates}` });
}

export function isActive(flow: Flow | null | undefined, now = new Date()): flow is Flow {
  return !!flow && !['confirmed', 'cancelled'].includes(flow.step) && now.getTime() - Date.parse(flow.updated_at) < FLOW_TTL_MS;
}

/** The first reply of a flow: a host's welcome that acknowledges what the guest already told us
 * (session 28 - "Your mobile number po?" as an opener read as a form, not a host). */
export const greeting = (name: string | null, lang: Lang = 'en') => pick(lang, {
  en: `${name ? `Hi ${name.split(' ')[0]},` : 'Hello,'} thank you for reaching out to Cascade Hideaway. `,
  tl: `${name ? `Hi ${name.split(' ')[0]}!` : 'Hello po!'} Salamat sa pag-message sa Cascade Hideaway. `,
  bis: `${name ? `Hi ${name.split(' ')[0]}!` : 'Hello!'} Salamat sa pag-message sa Cascade Hideaway. `,
});
/** "the two of you" / "kayong dalawa" - the party as a host names it. */
export function party(flow: Flow): string {
  const tl = flow.lang === 'tl';
  return !flow.pax || flow.pax === 1 ? 'you' : flow.pax === 2 ? 'the two of you' : `your ${tl ? 'group' : 'party'} of ${flow.pax}`;
}
/** Mid-flow: new dates were just given and are open - acknowledge before the next ask (protocol rule 1, live 2026-09-17 10:57). */
export function availabilityAck(flow: Flow, openLine: string): string {
  const who = party(flow);
  return `${openLine}, ${pick(flow.lang, { en: `and we'd be glad to welcome ${who}.`, tl: `and we'd be glad to have ${who}.`, bis: `and looking forward mi to have ${who}.` })}`;
}
export function opener(flow: Flow, name: string | null, answer = ''): string {
  const who = party(flow);
  const welcome = pick(flow.lang, { en: `we'd be glad to welcome ${who}.`, tl: `we'd be glad to have ${who}.`, bis: `looking forward mi to have ${who}.` });
  if (answer) return `${greeting(name, flow.lang)}${answer}, and ${welcome}\n\n`;
  const dates = flow.checkin && flow.checkout
    ? pick(flow.lang, { en: `${dm(flow.checkin)} to ${dm(flow.checkout)} is noted, and we'll check those dates for you as we go. `, tl: `Noted po ang ${dm(flow.checkin)} to ${dm(flow.checkout)} — iche-check namin ang dates as we go. `, bis: `Noted ang ${dm(flow.checkin)} to ${dm(flow.checkout)} — amo i-check ang dates as we go. ` })
    : flow.checkin ? pick(flow.lang, { en: `Check-in on ${dm(flow.checkin)} is noted. `, tl: `Noted po, check-in on ${dm(flow.checkin)}. `, bis: `Noted, check-in on ${dm(flow.checkin)}. ` }) : '';
  const w = welcome.charAt(0).toUpperCase() + welcome.slice(1);
  return `${greeting(name, flow.lang)}${dates}${w}\n\n`;
}

/** The question for the current slot, in the Cassy voice: calm, gracious, precise; guide rather than command. */
/** SPEC-14 (D-184): the details are taken progressively - only the first missing item is ever asked for. */
export function nextAsk(flow: Flow): string {
  const L = flow.lang, who = flow.name ?? '';
  if (!flow.name) return pick(L, { en: `Thank you. And the name for the reservation?`, tl: `Salamat po. At ang pangalan po para sa reservation?`, bis: `Salamat. Ug ang name for the reservation?` });
  if (!flow.phone) return pick(L, { en: `Thank you, ${who}. And a mobile number we can reach you on?`, tl: `Salamat po, ${who}. At ang mobile number po na matatawagan namin?`, bis: `Salamat, ${who}. Ug ang mobile number nga ma-contact namo?` });
  if (!flow.email) return pick(L, { en: `Thank you, ${who}. And an email address for your confirmation?`, tl: `Salamat po, ${who}. At ang email address po para sa confirmation?`, bis: `Salamat, ${who}. Ug ang email address for your confirmation?` });
  return '';
}
export function prompt(flow: Flow, name: string | null, resume = false, now = new Date()): string {
  const n = name ? `${name.split(' ')[0]}, ` : '';
  const L = flow.lang;
  switch (flow.step) {
    case 'dates': return pick(L, {
      en: `${n ? `${n}which` : 'Which'} dates would you like to stay with us? Your check-in and check-out will do (for example, "Sep 24 to 26").`,
      tl: `${n}kailan po ninyo gustong mag-stay? Check-in and check-out lang po (halimbawa, "Sep 24 to 26").`,
      bis: `${n}kanus-a mo gusto mag-stay? Check-in and check-out lang (pananglitan, "Sep 24 to 26").`,
    });
    case 'checkout': return pick(L, {
      en: `Thank you. Check-in on ${dm(flow.checkin!)} is noted. Until which date would you like to stay?`,
      tl: `Noted po, check-in on ${dm(flow.checkin!)}. Hanggang kailan po ang stay ninyo?`,
      bis: `Noted, check-in on ${dm(flow.checkin!)}. Hangtod kanus-a ang stay ninyo?`,
    });
    case 'pax': return pick(L, {
      en: `And how many guests will be staying? The home comfortably accommodates up to 3 adults, or 2 adults with 2 children.`,
      tl: `Ilan po kayo? Comfortable po ang home for up to 3 adults, or 2 adults with 2 kids.`,
      bis: `Pila mo ka tanan? Comfortable ang home for up to 3 adults, or 2 adults with 2 kids.`,
    });
    case 'offer': return `${rateLine(flow, now)}\n\n${pick(L, {
      en: `Shall we set the dates aside for you?`,
      tl: `I-set aside na po ba namin ang dates para sa inyo?`,
      bis: `Shall we set the dates aside for you?`,
    })}`;
    case 'contact': {
      if (flow.name || flow.phone || flow.email) return nextAsk(flow);
      const t = name ? `, ${name.split(' ')[0]}` : '';
      return pick(L, {
        en: `Thank you${t}. May we have the name for the reservation, a mobile number we can reach you on, and an email address for your confirmation?`,
        tl: `Salamat po${t}. Maaari po ba naming makuha ang pangalan para sa reservation, mobile number na matatawagan namin, at email address para sa confirmation ninyo?`,
        bis: `Salamat${t}. Pwede namo makuha ang name for the reservation, mobile number nga ma-contact namo, ug email address for your confirmation?`,
      });
    }
    case 'confirm': { const q = quoteTotal(flow.checkin!, flow.checkout!); const who = flow.name ?? name ?? null; return [
      resume // after a mid-flow question (Lloyd 2026-09-17: nudge subtly to complete the booking)
        ? pick(L, { en: `Here's your stay, ready whenever you are:`, tl: `Ito po ang stay ninyo, ready whenever you are:`, bis: `Mao ni ang inyong stay, ready whenever you are:` })
        : pick(L, { en: `Here are your stay details:`, tl: `Ito po ang details ng stay ninyo:`, bis: `Mao ni ang details sa stay ninyo:` }),
      ...(who ? [`👤 ${who}`] : []),
      `📅 ${dmRange(flow.checkin!, flow.checkout!)} · ${q.nights} night${q.nights === 1 ? '' : 's'} · ${flow.pax} guest${flow.pax === 1 ? '' : 's'}`,
      `📞 ${flow.phone}${flow.email ? ` · ${flow.email}` : ''}`,
      `💰 Total ${peso(q.total)}`,
      pick(L, { en: `🔐 ₱1,000 refundable security deposit at check-in, returned after check-out`, tl: `🔐 ₱1,000 refundable security deposit at check-in, ibabalik after check-out`, bis: `🔐 ₱1,000 refundable security deposit at check-in, i-uli after check-out` }),
      ``,
      payChoice(flow),
    ].join('\n'); }
    default: return '';
  }
}

export type Step = { flow: Flow; reply: string | null; action: 'ask' | 'submit' | 'cancelled' | 'passthrough' };

/** Start a flow from the first message; prefills dates and guests when they are in the text. */
export function start(text: string, now = new Date()): Flow {
  const at = now.toISOString();
  const first = settleLang(undefined, detectLang(text), 0);
  const flow: Flow = { step: 'dates', started_at: at, updated_at: at, lang: first.lang, bis_turns: first.bisTurns };
  const d = parseDates(text, now);
  const today = at.slice(0, 10);
  if (d[0] && d[0] >= today) { flow.checkin = d[0]; flow.step = 'checkout'; }
  if (flow.checkin && d[1] && d[1] > flow.checkin) { flow.checkout = d[1]; flow.step = 'pax'; }
  const p = /\b(\d|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\s*(adults?|pax|persons?|people|guests?|tao|tawo|kami|mi|ka|kabuok)\b/i.test(text) || /\b(?:for|para sa|kaming)\s+(\d|one|two|three|four|isa|dalawa|tatlo|apat)\b(?!\s*(?:nights?|days?|gabi|araw))/i.test(text) ? parsePax(text) : null;
  if (p && flow.step === 'pax') { flow.pax = p; flow.step = 'offer'; }
  // What did the guest actually ask? index.ts answers availability from the calendar (code) or hands
  // any other question to the model before the flow's own ask (protocol rule 1).
  flow.asked = AVAIL_RE.test(text) && flow.checkin ? 'availability' : ASK_RE.test(text) && !/\b(can|could|pwede|possible)\b[^?]*\b(book|reserve)\b/i.test(text) ? 'question' : null;
  return flow;
}

/** Apply the guest's answer to the current slot. A question ("?") passes through to the model. */
export function answer(flow: Flow, text: string, now = new Date()): Step {
  const f: Flow = { ...flow, updated_at: now.toISOString() };
  // Mirror the guest: a Tagalog/Bisaya turn switches the register to Taglish; a plain-English turn switches it back
  // (numbers, dates, "skip", "deposit" and the like carry no language and keep the current one).
  { const words = text.replace(/\S+@\S+|https?:\/\/\S+|\+?\d[\d\s-]{5,}\d/g, ' ').replace(/(skip|deposit|full|yes|ok|okay|cancel|stop|sige|opo|oo|po)/gi, ' ').match(/[a-z]{3,}/gi) ?? [];
    const d = detectLang(text);
    if (d !== 'en') { const s = settleLang(f.lang, d, f.bis_turns ?? 0); f.lang = s.lang; f.bis_turns = s.bisTurns; }
    else if (words.length >= 2) { f.lang = 'en'; f.bis_turns = 0; } }
  const L = f.lang;
  const today = f.updated_at.slice(0, 10);
  if (CANCEL_RE.test(text) && f.step !== 'await_receipt') return { flow: { ...f, step: 'cancelled' }, reply: cancelReply(L), action: 'cancelled' };
  const ask = (reply?: string): Step => ({ flow: f, reply: reply ?? null, action: 'ask' });
  const retry = (what: string): Step => text.includes('?') ? { flow: f, reply: null, action: 'passthrough' } : ask(pick(L, { en: `Sorry, I couldn't quite make out ${what}. ${prompt(f, null)}`, tl: `Sorry po, hindi ko nakuha ${what === 'the mobile number' ? 'ang mobile number' : what === 'the dates' ? 'ang dates' : what === 'the check-out date' ? 'ang check-out date' : what === 'the number of guests' ? 'kung ilan kayo' : 'iyon'}. ${prompt(f, null)}`, bis: `Sorry, wala nako nakuha ${what === 'the mobile number' ? 'ang mobile number' : what === 'the dates' ? 'ang dates' : what === 'the check-out date' ? 'ang check-out date' : what === 'the number of guests' ? 'pila mo' : 'to'}. ${prompt(f, null)}` }));
  switch (f.step) {
    case 'dates': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the dates');
      if (d[0] < today) return ask(pick(L, { en: `That date has already passed. Which upcoming dates would suit you?`, tl: `Lumipas na po ang date na iyon. Aling upcoming dates po ang gusto ninyo?`, bis: `Lapas na ang date nga na. Unsang upcoming dates ang gusto ninyo?` }));
      f.checkin = d[0]; f.step = 'checkout';
      if (d[1] && d[1] > d[0]) { f.checkout = d[1]; f.step = f.pax ? 'offer' : 'pax'; }
      return ask();
    }
    case 'checkout': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the check-out date');
      if (d[0] <= f.checkin!) return ask(pick(L, { en: `Check-out would need to fall after ${dm(f.checkin!)}. Until which date would you like to stay?`, tl: `Kailangan po after ${dm(f.checkin!)} ang check-out. Hanggang kailan po ang stay ninyo?`, bis: `Kinahanglan after ${dm(f.checkin!)} ang check-out. Hangtod kanus-a ang stay ninyo?` }));
      f.checkout = d[0]; f.step = f.pax ? 'offer' : 'pax'; return ask();
    }
    case 'pax': {
      const p = parsePax(text);
      if (!p) return retry('the number of guests');
      if (p > 4) return ask(pick(L, { en: `As much as we'd love to host everyone, the home is most comfortable for up to 3 adults, or 2 adults with 2 children. For a party of ${p}, a larger place would give you more room to rest. If your group fits, just let us know the count again.`, tl: `Comfortable po ang home for up to 3 adults, or 2 adults with 2 kids. For ${p}, mas maganda po ang mas malaking place para mas may space kayo. If kasya po ang group ninyo, sabihin lang po ulit kung ilan kayo.`, bis: `Comfortable ang home for up to 3 adults, or 2 adults with 2 kids. For ${p}, mas maayo ang mas dako nga place para mas naa moy space. If kasya ang group ninyo, ingna lang mi pila mo.` }));
      f.pax = p; f.step = 'offer'; return ask();
    }
    case 'offer': {
      if (OFFER_NO_RE.test(text)) return { flow: { ...f, step: 'cancelled' }, reply: cancelReply(L), action: 'cancelled' };
      if (OFFER_YES_RE.test(text)) { f.step = 'contact'; return ask(); }
      return { flow: f, reply: null, action: 'passthrough' }; // anything else: the model answers and the offer is asked again
    }
    case 'contact': {
      if (text.includes('?')) return { flow: f, reply: null, action: 'passthrough' };
      const ph = parsePhone(text), em = parseEmail(text), nm = parseName(text);
      if (ph) f.phone = ph;
      if (em) f.email = em;
      if (nm && !f.name) f.name = nm;
      if (!ph && !em && !nm) return retry('those details');
      if (!f.name || !f.phone || !f.email) return ask(nextAsk(f));
      f.pay_full = within48h(f.checkin!, now) ? true : undefined; f.step = 'confirm'; return ask();
    }
    case 'confirm': {
      // Corrections first, then the payment choice sends it (Lloyd 11:05: "deposit, my email is …" must keep
      // the e-mail; "full na lang, 3 guests" must keep the 3). A date change re-shows the card: the total moves.
      const d = parseDates(text, now), p = /\b(guest|pax|person|people|tao|tawo|adult|kami|kabuok|mi\b)/i.test(text) ? parsePax(text) : null, ph = parsePhone(text), e = parseEmail(text);
      let changed = false, datesChanged = false;
      if (d[0] && d[0] >= today) { f.checkin = d[0]; changed = datesChanged = true; if (d[1] && d[1] > d[0]) f.checkout = d[1]; else if (f.checkout! <= d[0]) { f.step = 'checkout'; return ask(); } }
      if (p && p <= 4) { f.pax = p; changed = true; }
      if (ph) { f.phone = ph; changed = true; }
      if (e) { f.email = e; changed = true; }
      if (datesChanged) { f.pay_full = within48h(f.checkin!, now) ? true : undefined; return ask(); }
      const wantsFull = FULL_RE.test(text), wantsDeposit = DEPOSIT_RE.test(text) || YES_RE.test(text);
      if (wantsFull) { f.pay_full = true; return { flow: f, reply: null, action: 'submit' }; }
      if (wantsDeposit && f.pay_full === true) return ask(payChoice(f)); // SPEC-14: inside 48 h the full amount secures the stay
      if (wantsDeposit) { f.pay_full = false; return { flow: f, reply: null, action: 'submit' }; }
      if (changed) return ask();
      return retry('that');
    }
    default: return { flow: f, reply: null, action: 'passthrough' };
  }
}

// ponytail: one QR (GCash) in Messenger; UnionBank/InstaPay stays on the site page linked below.
/** "bukas" / "tomorrow", "ngayong araw" / "today", else the weekday - Manila calendar days between now and the hold end. */
function relDay(iso: string, now: Date, lang: Lang | undefined): string {
  const day = (d: Date) => d.toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
  const diff = Math.round((Date.parse(day(new Date(iso))) - Date.parse(day(now))) / 86_400_000);
  if (diff === 0) return pick(lang, { en: 'today', tl: 'ngayong araw', bis: 'karon' });
  if (diff === 1) return pick(lang, { en: 'tomorrow', tl: 'bukas', bis: 'ugma' });
  return new Date(iso).toLocaleDateString('en-PH', { timeZone: 'Asia/Manila', weekday: 'long' });
}
export function paymentReply(flow: Flow, name: string | null, _siteUrl: string, now = new Date()): string {
  const n = name ? name.split(' ')[0] : '';
  const nm = n ? `, ${n}` : '';
  const until = flow.hold_expires_at ? new Date(flow.hold_expires_at).toLocaleString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }).replace(', ', ' at ') : null;
  const full = (flow.deposit ?? 0) >= (flow.total ?? 0);
  const dates = dmRange(flow.checkin!, flow.checkout!); // SPEC-14: "Oct 20 to 22", "Sep 30 to Oct 2"
  const rel = flow.hold_expires_at ? relDay(flow.hold_expires_at, now, flow.lang) : '';
  const dep = peso(flow.deposit!), bal = peso(flow.total! - flow.deposit!), what = full ? 'payment' : 'initial payment';
  // D-168/D-169: Lloyd's section-24 (Filipino), section-30 balanced Bislish (Bisaya) and section-6 (English) targets,
  // with the 24-hour hold and the relative day. Order: status -> next step -> convenience -> confirmation -> balance -> close.
  const L = flow.lang;
  const head = flow.hold && until
    ? pick(L, {
        en: `${n ? `${n}, we've` : `We've`} set aside ${dates} for you for 24 hours, until ${until} (${rel}). Your booking reference is ${flow.ref}.`,
        tl: `${n ? `${n}, na-hold` : `Na-hold`} na po namin ang ${dates} for you for 24 hours — until ${until} (${rel}). Ang booking reference ninyo po ay ${flow.ref}.`,
        bis: `${n ? `${n}, na-hold` : `Na-hold`} na namo ang ${dates} for you for 24 hours — until ${until} (${rel}). Your booking reference is ${flow.ref}.` })
    : pick(L, {
        en: `${n ? `${n}, we've` : `We've`} received your request for ${dates}. Your booking reference is ${flow.ref}. As your stay is near, we'll confirm as soon as your payment arrives.`,
        tl: `${n ? `${n}, received` : `Received`} na po namin ang request ninyo for ${dates}. Ang booking reference ninyo po ay ${flow.ref}. Malapit na ang stay, kaya iko-confirm namin as soon as dumating ang payment.`,
        bis: `${n ? `${n}, na-receive` : `Na-receive`} na namo ang request ninyo for ${dates}. Your booking reference is ${flow.ref}. Duol na ang stay, so amo dayon i-confirm once muabot ang payment.` });
  const pay = pick(L, {
    en: `To secure the stay, you may send the ${dep} ${what} through GCash (0956 011 5744) using the QR below. The exact amount is already set. Once you've sent the receipt here, we'll review and confirm your reservation.`,
    tl: `Para ma-secure ang stay, you may send the ${dep} ${what} through GCash (0956 011 5744) using the QR below. Naka-set na po ang exact amount for convenience. Kapag na-send na po ninyo ang receipt dito, ire-review at iko-confirm namin ang reservation ninyo.`,
    bis: `Para ma-secure ang stay, pwede na ma-send ang ${dep} ${what} through GCash (0956 011 5744) gamit ang QR below. Naka-set na daan ang exact amount para convenient. Kung ma-send na ninyo ang receipt diri, amo i-review ug i-confirm ang inyong reservation.` });
  const later = full
    ? pick(L, { en: `Only the ₱1,000 refundable security deposit remains, which may be settled at check-in.`, tl: `Ang ₱1,000 refundable security deposit na lang po ang natitira, which can be settled at check-in.`, bis: `Ang ₱1,000 refundable security deposit na lang ang nabilin, which can be settled at check-in.` })
    : pick(L, { en: `The remaining ${bal} balance and ₱1,000 refundable security deposit may be settled at check-in.`, tl: `The remaining ${bal} balance and ₱1,000 refundable security deposit ay puwede pong i-settle sa check-in.`, bis: `Ang remaining ${bal} balance and ₱1,000 refundable security deposit can be settled at check-in.` });
  const close = pick(L, { en: `Thank you${nm}. We look forward to welcoming you to Cascade Hideaway. 🌿`, tl: `Salamat po${nm}. We look forward to welcoming you to Cascade Hideaway. 🌿`, bis: `Salamat${nm}. Looking forward mi sa inyong stay at Cascade Hideaway. 🌿` });
  return [head, '', pay, '', later, '', close].join('\n');
}
