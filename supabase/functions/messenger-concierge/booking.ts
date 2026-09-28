// Messenger book intent (booking PRD §A, session 27). Pure functions, no I/O: a code-driven
// slot-filling flow that index.ts runs BEFORE the model. The model never books; it only answers
// questions. State is one jsonb on concierge_threads.booking_flow.
import { cardOn, currentCard, quote, type Quote, type RateCard } from '../_shared/cascade-core/pricing.ts';
// D-268 / D-269: every guest-facing word lives in persona.ts; this file decides the move and seals the facts.
import * as P from './persona.ts';
export { BOT_REPLY, CASSY_INTRO, cancelReply, greetBlock, greeting, paymentPromise, pick } from './persona.ts';

/** Register: en = Native English protocol, tl = Native Filipino (Taglish, purposeful po), bis = Native Bisaya (Bislish, no po). */
export type Lang = 'en' | 'tl' | 'bis';
export type Flow = {
  /** SPEC-31 s1: 'cancel_requested' = the guest asked to cancel or change while the hold was open; the host decides.
   *  SPEC-33 s2: 'receipt_declined' = the host tapped Decline on the receipt; the host follows up by hand. */
  step: 'dates' | 'checkout' | 'pax' | 'offer' | 'contact' | 'confirm' | 'await_receipt' | 'receipt_sent' | 'confirmed' | 'cancelled' | 'cancel_requested' | 'receipt_declined';
  checkin?: string; checkout?: string; pax?: number; phone?: string; email?: string | null;
  /** SPEC-14 (D-184): the name for the reservation, asked in the details step; it wins over the Facebook profile name. */
  name?: string;
  /** session 28: the guest's choice - reservation fee (50 %) or the full amount; forced full inside 48 h */
  pay_full?: boolean; asked?: 'availability' | 'question' | null;
  /** SPEC-28 section 2: the first message also asked something besides availability ("is Oct 26 to 28 open? is there wifi?") */
  question?: boolean;
  /** session 28: the guest's register, re-read on every turn - 'tl' = Taglish with "po" (Tagalog or Bisaya guests) */
  lang?: Lang;
  bis_turns?: number; // consecutive Bisaya guest turns (settleLang)
  booking_id?: string; ref?: string; deposit?: number; total?: number; hold?: boolean; hold_expires_at?: string | null;
  receipt_token?: string; receipt_expires_at?: string; started_at: string; updated_at: string;
  /** SPEC-31 s3: a photo reached us outside the upload (lapsed hold, second photo); the host matches it by hand. */
  photo_at?: string;
  /** Live 2026-09-26 (Suzanne): the nearest open window we offered after a reserved line; a plain yes takes it. */
  alt?: Window;
  /** Live 2026-09-28 (Suzanne, Lloyd: "convert the guest in the optimal number of responses"): the guest already said yes
   *  to the offered window, so after the guest count the flow goes straight to the details - no second "set it aside?". */
  agreed?: boolean;
  /** The offered window's price was already given (a price question at the dates step): it is not repeated. */
  quoted?: boolean;
};

export const BOOK_RE = /\b(book(ing)?|reserve|reservation|magpa-?book|pa-?book|i-?book|mag-?reserve|hold (the|my|our) dates|arrange (it|the booking)|(do|settle) it here|here in (the|this) chat|dito (po )?sa chat|diri sa chat)\b/i; // session 30: invitations now offer the chat route, so its natural answers start the flow
export const CANCEL_RE = /\b(cancel|stop|wag na|huwag|never ?mind|nevermind|not now|forget it|change of plans|di na tuloy|hindi na tuloy|dili na|wag na lang)\b/i;
const YES_RE = /^\s*(yes|yes po|oo|oo po|sige|sige po|go|confirm|confirmed|ok|okay|okay po|ok po|proceed|tama|correct|yup|yep|y)\s*[.!]*\s*$/i;
const SKIP_RE = /^\s*(skip|wala|none|no email|no)\s*[.!]*\s*$/i;
const FULL_RE = /\b(full|buo|buong|lahat|whole|everything|total|bayaran (ko )?lahat|in full)\b/i;
const DEPOSIT_RE = /\b(deposit|reservation fee|fee|50|half|kalahati|reserve|partial|down ?payment|dp)\b/i;
const AVAIL_RE = /\b(available|avail|vacant|bakante|open|free|may (?:vacancy|slot)|meron pa)\b/i;
/** SPEC-14 (D-184): the answers to the hold offer ("Shall we hold those dates for you?") */
const OFFER_YES_RE = /^\W*(yes|yes please|yes po|sure|of course|ok(ay)?( po)?|sige( po)?|oo( po)?|opo|go|please do|proceed|set (it|them) aside)\b/i;
const OFFER_NO_RE = /^\W*(no|not (yet|now)|hindi( po)?|dili|wala( pa)?|later|maybe later)\b/i;
const ASK_RE = /\?|\b(magkano|how much|pwede|can (i|we)|is (it|there)|are there|meron)\b/i;
const PRICE_RE = /\b(how much|magkano|tagpila|pila|price|rate|cost|hm)\b/i;
const QUESTION_WORD_RE = /\b(magkano|how|what|where|when|which|why|do you|does|can|could|pwede|puwede|is (it|there)|are there|meron|ano|saan|paano|asa|unsa)\b/i;
/** Moved here from voice.ts (which imports this file) so start() can use it without an import cycle. */
export const AMENITY_RE = /\b(amenities|amenity|included|inclusions|photos?|pictures?|pics|wifi|wi-fi|internet|aircon|air-?con|\bac\b|kitchen|tv|netflix|washing|laundry|parking)\b|what'?s (it|the place|the unit|the home) like/i;
/** Lloyd 2026-09-17 14:40: English and Taglish come first; Bislish only once the guest KEEPS replying in Bisaya.
 *  A first Bisaya turn is answered in Taglish; the second consecutive one switches the register to Bislish. */
export function settleLang(prev: Lang | undefined, detected: Lang, bisTurns: number): { lang: Lang; bisTurns: number } {
  if (detected !== 'bis') return { lang: detected, bisTurns: 0 };
  const n = bisTurns + 1;
  return { lang: n >= 2 || prev === 'bis' ? 'bis' : 'tl', bisTurns: n };
}
/** The ONE language detector (SPEC-28 section 4). index.ts used its own copy, which disagreed with this file's: "pwede ba"
 *  was Bisaya here and Taglish there. Lloyd 2026-09-13: "how far from SM po" is an English sentence with a courtesy
 *  particle, not Taglish - it gets English back (one "po" welcome). Taglish needs a Tagalog content word. */
export function guestLang(text: string): 'taglish' | 'bisaya' | 'english_po' | 'english' {
  const t = ` ${text.toLowerCase()} `;
  if (/\b(naa|unsa|asa|kanus-a|pila|maayong|salamat kaayo|ba mo|mo ba|nimo|karon|kaayo|kini|namo|nako|unya|gani|diri|didto|wala'y|walay|palihog|tagpila|pila ka|usbon|usba|mi|kabuok|tawo|ug|og|dili|among|ugma|gahapon|muabot|moabot)\b/.test(t)) return 'bisaya';
  if (/\b(ang|ng|mga|kayo|ninyo|magkano|pwede|puwede|salamat|meron|kailan|saan|paano|bukas|ngayon|opo|hindi|kasi|namin|natin|sige|okay lang|ayos|kami|ako|niyo|nyo|gusto|bakante|kaming|muna)\b/.test(t)) return 'taglish';
  const particles = (t.match(/\b(po|ba|lang|naman|opo)\b/g) ?? []).length;
  if (particles >= 2 || /\bhm po\b|\bhm\b[^.?!]{0,20}\b(night|gabi|rate)\b/.test(t)) return 'taglish';      // "may parking po ba?"; "hm po per night?" is Filipino text-speak (golden run 2026-09-17: it got plain English)
  if (particles === 1) return 'english_po';  // "how far from SM po"
  return 'english';
}
export const detectLang = (text: string): Lang => ({ taglish: 'tl', bisaya: 'bis', english_po: 'en', english: 'en' } as const)[guestLang(text)];
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
  for (const m of t.matchAll(/\b(\d{1,2})(?:\s*(?:-|–|to|hanggang)\s*(\d{1,2}))?\s+(?:of\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\b/g)) {
    const mo = MONTHS[m[3]], d1 = +m[1], y = yearFor(mo, d1, now);
    push(y, mo, d1); if (m[2]) push(y, mo, +m[2]);
  }
  if (out.length) return out;
  // "9/24-9/26" (month/day, the booking site's convention)
  for (const m of t.matchAll(/\b(\d{1,2})[\/.](\d{1,2})(?:[\/.](20\d\d))?\b/g)) {
    const mo = +m[1], d = +m[2]; if (mo < 1 || mo > 12) continue; push(m[3] ? +m[3] : yearFor(mo, d, now), mo, d);
  }
  if (out.length) return out;
  // Session 49: "Available today?", "available tonight?", "bukas po?" (live wordings). Manila's date, since the guest
  // means their own today; "tonight then tomorrow" gives a one-night pair.
  const manila = new Date(now.getTime() + 8 * 3_600_000);
  const rel = (n: number) => { const x = new Date(manila.getTime() + n * 86_400_000); push(x.getUTCFullYear(), x.getUTCMonth() + 1, x.getUTCDate()); };
  const rels = [...t.matchAll(/\b(today|tonight|ngayon(?:g gabi)?|karon(?:g gabii)?|tomorrow|tmrw|bukas|ugma)\b/g)]
    .map((m) => (/^(tomorrow|tmrw|bukas|ugma)$/.test(m[1]) ? 1 : 0));
  for (const n of [...new Set(rels)].sort()) rel(n);
  return out;
}

// Live 2026-09-24 14:13-14:15Z (Suzanne): "Can i book Oct. 30" was kept from the flow by the "can i" guard, the bot
// offered to arrange it "right here in the chat", the guest said "Yes please", and nothing started - the model promised
// payment details that no code sends. The bot's own chat-route offer (voice.ts CHAT_ROUTE, decisionInvite, facts.ts).
// A whole-message yes, by words rather than one regex, so "Yes pls", "okay sige", "go na po" and "dito na lang po"
// all count (live wordings in concierge_threads, 2026-09-24). Not OFFER_YES_RE: that is a prefix match for the
// flow's own offer step, and after a chat offer "ok po salamat" or "ok let me think about it" must never start a
// booking. Every word must be a yes-word or filler, and at least one must be a real yes; a bare "ok" or "g" is not.
const YES_STRONG = new Set(['yes', 'yess', 'yup', 'yep', 'yeah', 'sure', 'course', 'sige', 'sge', 'opo', 'oo', 'go', 'proceed', 'book', 'arrange', 'reserve', 'here', 'dito', 'diri', 'chat', 'please']);
const YES_FILLER = new Set(['ok', 'okay', 'okie', 'k', 'na', 'po', 'pls', 'plz', 'pls.', 'of', 'let', 'lets', 's', 'do', 'it', 'ahead', 'lang', 'nalang', 'nlng', 'man', 'sir', 'maam', 'ma', 'am', 'the', 'in', 'sa', 'kay', 'ta', 'mi', 'us', 'that', 'this', 'one', 'now', 'naman', 'nga', 'thank', 'you']);
export function isChatYes(text: string): boolean {
  const words = text.toLowerCase().replace(/[^a-z' ]+/g, ' ').replace(/'/g, '').split(/\s+/).filter(Boolean);
  if (!words.length || words.length > 8) return false;
  if (words.some((w) => /^(no|not|dont|wag|huwag|ayaw|dili|think|isip|later|muna|wait|salamat|thanks|how|magkano|pila|much)$/.test(w))) return false;
  return words.every((w) => YES_STRONG.has(w) || YES_FILLER.has(w)) && words.some((w) => YES_STRONG.has(w) && w !== 'please' && w !== 'chat');
}
const PAY_ASK_RE = /\b(payment (link|details?|options?|methods?|instructions?)|pay(ment)? (via|thru|through|using)|how (do|can|will|should) (i|we) pay|where (do|can|should) (i|we) (pay|send)|gcash (number|no|details?|account|qr)|(send|give)( me| us)?( the)? (qr|account|bank|gcash|payment)|qr ?code|account (details?|number|name)|bank details?|paano (po )?(mag ?bayad|magbayad|mag-bayad)|saan (po )?(mag ?bayad|magbabayad)|asa (mi )?(mo ?bayad|magbayad))\b/i;
const CHAT_OFFER_RE = /\b(arrange\b[^.\n]{0,60}\b(in (the|this) chat|here in (the )?chat|sa chat)|(right )?here in (the|this) chat|dito (po )?sa chat|diri sa chat)\b/i;

/**
 * Should this message start the in-chat booking flow, and from which guest text? Null means no.
 * 1. A booking word or availability question starts it, unless it asks HOW to book; a hedge ("can I", "pwede ba",
 *    "possible") keeps it out only when the message carries no date - "can I book Oct 30" is a request.
 * 2. A plain yes to the bot's own "we can arrange it here in the chat" starts it from the guest's latest dated message.
 */
export function bookingStart(text: string, priorGuestTexts: string[], lastBotText: string, now = new Date()): string | null {
  const how = /\b(how (do|can) (i|we)|paano)\b/i.test(text);
  const hedged = /\b(can i|pwede( po)? ba|possible)\b/i.test(text);
  // The dated-hedge exception needs a booking WORD: "available po ba Oct 5? pwede po ba check in 12 noon?" is two
  // questions for the model, and starting the flow there would drop the second one (golden first-noon-checkin).
  if (BOOK_RE.test(text) && !how && (!hedged || parseDates(text, now).length > 0)) return text;
  if (availStart(text, now) && !how && !hedged) return text;
  const dated = [text, ...[...priorGuestTexts].reverse()].find((t) => parseDates(t, now).length > 0) ?? null;
  if (isChatYes(text) && CHAT_OFFER_RE.test(lastBotText)) return dated ?? text;
  // 3. Asking HOW TO PAY once the guest has given dates, with no flow running (live 14:22Z "Payment link"): the model
  //    invented a total, an account and "we'll send the details in a moment". Payment options and the QR exist only in
  //    the flow, so start it. With no dates yet, "what payment methods?" is a question for the model.
  if (PAY_ASK_RE.test(text) && dated) return dated;
  return null;
}

/** SPEC-14 (D-184): an availability question that carries a future check-in starts the flow, book word or not. */
export function availStart(text: string, now = new Date()): boolean {
  if (!AVAIL_RE.test(text)) return false;
  const d = parseDates(text, now);
  return !!d[0] && d[0] >= now.toISOString().slice(0, 10);
}
/** "2 nights", "one night", "isang gabi", "duha ka gabii" -> the count; null when the message names no nights. */
export function nightsIn(text: string): number | null {
  const w: Record<string, number> = { one: 1, a: 1, isa: 1, isang: 1, usa: 1, two: 2, dalawa: 2, dalawang: 2, duha: 2, three: 3, tatlo: 3, tatlong: 3, tulo: 3, four: 4, apat: 4, upat: 4, five: 5, lima: 5, limang: 5 };
  const m = /\b(\d{1,2}|one|a|isa|isang|usa|two|dalawa|dalawang|duha|three|tatlo|tatlong|tulo|four|apat|upat|five|lima|limang)\s*(?:ka\s*)?(?:po\s*)?(?:nights?|gabi|gabii)\b/i.exec(text);
  if (!m) return null;
  const n = /^\d+$/.test(m[1]) ? +m[1] : w[m[1].toLowerCase()];
  return n >= 1 && n <= 60 ? n : null;
}
export function parsePax(text: string): number | null {
  const words: Record<string, number> = { one: 1, isa: 1, two: 2, dalawa: 2, duha: 2, three: 3, tatlo: 3, tulo: 3, four: 4, apat: 4, upat: 4 };
  // A count next to a guest word wins over any other number ("Sep 24 to 26 for 2 adults" -> 2).
  // Lloyd 2026-09-18: a courtesy particle may sit between the count and the guest word - "2 po kami" is two guests.
  const m = /\b(\d{1,2}|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\s*(?:po|pa|ba|po\s+ba)?\s*(?:adults?|pax|persons?|people|guests?|tao|tawo|kami|mi|ka|kabuok)\b/i.exec(text)
    ?? /\b(?:for|para sa|kaming)\s+(\d{1,2}|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\b(?!\s*(?:nights?|days?|gabi|araw))/i.exec(text) // "book for 2" (live 2026-09-17 09:53)
    ?? /\b(\d{1,2}|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\b/i.exec(text);
  if (!m) return null;
  const n = /^\d+$/.test(m[1]) ? +m[1] : words[m[1].toLowerCase()];
  return n >= 1 ? n : null;
}
/** D-222: the stated capacity (facts: up to 3 adults, or 3 adults + 1 child, or 2 adults + 2 children) - more than 4
 *  people, or 4+ adults said outright. One rule for flow start, the guest step and the offer. */
export function overCapacity(text: string, p: number): boolean {
  const a = /\b(\d{1,2}|four|five|six|apat|lima|anim|upat)\s*(?:po\s*)?adults?\b/i.exec(text);
  const words: Record<string, number> = { four: 4, five: 5, six: 6, apat: 4, lima: 5, anim: 6, upat: 4 };
  const adults = a ? (/^\d+$/.test(a[1]) ? +a[1] : words[a[1].toLowerCase()]) : 0;
  return p > 4 || adults >= 4;
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
/** SPEC-28 section 4: the example stay in the dates ask was a hard-coded "Sep 24 to 26", in the past by session 50.
 *  Now 7 to 9 days from today, formatted like every other range. */
export const exampleDates = (now = new Date()) => dmRange(new Date(now.getTime() + 7 * 86_400_000).toISOString().slice(0, 10), new Date(now.getTime() + 9 * 86_400_000).toISOString().slice(0, 10));
export type Window = { start: string; end: string; nights: number; open_ended?: boolean };
export const windowText = (w: Window) => w.open_ended ? `${dm(w.start)} onwards` : dmRange(w.start, w.end);
/** Lloyd 2026-09-18: a window that runs to the next booking oversells - a guest asking for 2 nights was offered
 *  "Oct 9 to 28". The offer is trimmed to the stay they asked for; a shorter window is left as it is. */
export function trimWindow(w: Window, nights: number): Window {
  if (nights < 1 || w.nights <= nights) return w;
  const end = new Date(Date.parse(w.start + 'T00:00:00Z') + nights * 86_400_000).toISOString().slice(0, 10);
  return { start: w.start, end, nights };
}
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
/** SPEC-34: the stored rate card's quote (pricing.ts) - the same one submit-booking stores and the site shows.
 *  `card` defaults to the card index.ts loaded for this turn; tests get the seed card. */
export function quoteTotal(checkin: string, checkout: string, card: RateCard = currentCard()): { nights: number; rate: number; total: number; deposit: number; q: Quote } {
  const q = quote(card, checkin, checkout);
  return { nights: q.n, rate: q.tier_rate, total: q.total, deposit: q.deposit, q };
}
/** Lloyd 2026-09-18: a booking made inside 5 days of check-in - same day through 4 days out - pays in full up
 *  front, so the fee-or-full choice is not offered. `submit-booking` already uses this boundary for holds
 *  (`daysOut >= 5`); the old 48-hour rule disagreed with it. Manila calendar days, not hours. */
export const lastMinute = (checkin: string, now = new Date()) =>
  Math.round((Date.parse(checkin) - Date.parse(now.toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' }))) / 86_400_000) <= 4;
const php = (v: number) => `PHP ${v.toLocaleString('en-PH')}`;
/** D-262: promo nights anchored on the standard rate (never a "was" price); a mixed stay names both parts. */
function promoRateLine(lang: Lang | undefined, x: ReturnType<typeof quoteTotal>, std: number): string {
  const { q } = x, pn = q.nights.filter((n) => n.source === 'promo'), name = q.promo_name!, pr = php(q.promo_rate!);
  const when = pn.length === 1 ? dm(pn[0].date) : dmRange(pn[0].date, pn[pn.length - 1].date);
  if (q.promo_nights === q.n) return q.n === 1
    ? P.promoOneNight(pr, name, php(std), lang)
    : P.promoAllNights(q.n, name, pr, php(std), php(q.total), lang);
  return P.promoMixed({ n: q.n, total: php(q.total), promoNights: q.promo_nights, when, name, promoRate: pr, rest: q.n - q.promo_nights, restRate: php(q.tier_rate), std: php(std) }, lang);
}
/** SPEC-14 (D-184): the direct-booking rate, said before the offer. Every figure comes from quoteTotal (the rate card). */
export function rateLine(flow: Flow, now = new Date(), card: RateCard = currentCard()): string {
  const q = quoteTotal(flow.checkin!, flow.checkout!, card), STD_RATE = cardOn(card, flow.checkin!).base; // the standard on the check-in date
  const body = q.q.promo_nights > 0 ? promoRateLine(flow.lang, q, STD_RATE) : q.nights >= 2
    ? P.nightsPrice(q.nights, php(q.rate), php(STD_RATE), php(q.total), flow.lang)
    : P.oneNight(php(q.rate), flow.lang);
  // The site's own rule (D-166): inside five days the full amount secures the stay, so the choice is never offered.
  return lastMinute(flow.checkin!, now) ? `${body} ${P.LAST_MINUTE}` : body;
}
/** SPEC-14 (D-184): the card's payment sentence - the fee-or-full choice, or the full-only sentence inside five days. */
export function payChoice(flow: Flow): string {
  const q = quoteTotal(flow.checkin!, flow.checkout!);
  return P.payChoiceLine(flow.pay_full === true, peso(q.total), peso(q.deposit), flow.lang);
}
const manilaToday = (now: Date) => new Date(now.getTime() + 8 * 3_600_000).toISOString().slice(0, 10);
export const addDay = (d: string, n = 1) => new Date(Date.parse(d + 'T00:00:00Z') + n * 86_400_000).toISOString().slice(0, 10);
/** Live 2026-09-26 (Suzanne, "Available today?" was answered "Sep 26 to 27 is already reserved"): one night is named the way
 *  a host says it - "tonight (Sep 26)", "the night of Oct 5" - in English; Taglish and Bislish keep the range. */
function stayLabel(checkin: string, checkout: string, lang: Lang | undefined, now: Date): string {
  if ((lang && lang !== 'en') || nights(checkin, checkout) !== 1) return dmRange(checkin, checkout); // "Oct 3 to 4" is how Filipino guests write one night
  return checkin === manilaToday(now) ? `tonight (${dm(checkin)})` : `the night of ${dm(checkin)}`;
}
/** A code answer to "is it available?" from the calendar rows that overlap the stay (pure: index.ts fetches).
 *  `offer` (flow paths only, where index.ts keeps the window as flow.alt): the nearest window is offered as a yes/no
 *  question, so a guest whose night is taken is one "yes" from the next step (Lloyd 2026-09-26: conversion, same warmth). */
export function availabilityLine(flow: Flow, bookedNights: Set<string> | null, nearest?: Window | null, now = new Date(), offer = false): string {
  if (!flow.checkin || !flow.checkout) return '';
  const dates = stayLabel(flow.checkin, flow.checkout, flow.lang, now);
  // null = the calendar could not be read: never claim the dates are open (session 30).
  if (!bookedNights) return P.datesChecking(dates, flow.lang);
  for (let d = flow.checkin; d < flow.checkout; d = new Date(Date.parse(d + 'T00:00:00Z') + 86_400_000).toISOString().slice(0, 10)) {
    if (bookedNights.has(d)) {
      if (!nearest) return P.datesReserved(dates, flow.lang);
      const one = nearest.nights === 1 && !nearest.open_ended;
      return P.datesReservedNearest(dates, one ? dm(nearest.start) : windowText(nearest), one, offer && !nearest.open_ended, flow.lang);
    }
  }
  return P.datesOpen(dates, flow.lang);
}

export function isActive(flow: Flow | null | undefined, now = new Date()): flow is Flow {
  return !!flow && !['confirmed', 'cancelled', 'cancel_requested', 'receipt_declined'].includes(flow.step) && now.getTime() - Date.parse(flow.updated_at) < FLOW_TTL_MS;
}
/** SPEC-31 s3: the booking this thread made, whatever its step, while it is under 8 days old - isActive drops it after
 *  24 h, and a receipt photo or a "paid na" after the hold lapsed still belongs to it. A new flow overwrites it. */
export function lastRef(flow: Flow | null | undefined, now = new Date()): Flow | null {
  return flow?.ref && now.getTime() - Date.parse(flow.updated_at) < 8 * 86_400_000 ? flow : null;
}
/** SPEC-31: the register of a code line after the QR - the guest's own words when they carry a language, else the flow's.
 *  Bislish only when the flow already settled on it (D-172). */
export function replyLang(text: string, fallback: Lang | undefined): Lang {
  const d = detectLang(text);
  if (d === 'bis') return fallback === 'bis' ? 'bis' : 'tl';
  if (d === 'tl') return 'tl';
  return (text.match(/[a-z]{3,}/gi) ?? []).length >= 3 ? 'en' : fallback ?? 'en';
}
const manilaAt = (iso: string) => new Date(iso).toLocaleString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true });
/** SPEC-31: the host card's note - which booking, and whether its hold still stands. */
export function holdNote(flow: Flow, now = new Date(), extra = ''): string {
  const hold = !flow.hold_expires_at ? 'no hold (full payment)'
    : Date.parse(flow.hold_expires_at) < now.getTime() ? `hold lapsed ${manilaAt(flow.hold_expires_at)}` : `hold until ${manilaAt(flow.hold_expires_at)}`;
  return [`Ref ${flow.ref}`, extra, hold].filter(Boolean).join(' · ');
}
// D-258 (Lloyd 2026-09-26, "more english than this awkward tagalog"): the SPEC-31/33 payment-path lines are English in every
// register; Taglish keeps one courtesy "po". Their words are persona.ts's (APPROVED, unchanged).
/** SPEC-31 s1 (REVIEW F1): "cancel po" while the hold is open. Code says it and a host card does it - nothing is
 *  released from the chat. A date in the same message is a change, not a cancel. */
export function holdCancelReply(flow: Flow, name: string | null, lang: Lang, change: boolean): string {
  // After a receipt, "nothing is charged" would be false: the 5-day rule decides, and the host says so.
  const kind = change ? 'change' : flow.step === 'receipt_sent' ? 'receipt' : 'cancel';
  return P.holdCancelLine(kind, name, dmRange(flow.checkin!, flow.checkout!), lang);
}
/** SPEC-31 s2 (REVIEW F2): "paid na po?" once a booking exists. No timing promise: nothing measures the host. */
export function paidClaimReply(flow: Flow, name: string | null, lang: Lang): string {
  // SPEC-33 s2: after a decline the receipt is no longer "with us" - the await_receipt line asks for the screenshot again.
  return P.paidClaimLine(flow.step !== 'receipt_declined' && (flow.step === 'receipt_sent' || !!flow.photo_at), name, flow.ref, lang);
}
/** D-258 (Lloyd 2026-09-26: "when they ask to pay, give them gcash qr"; live 00:56Z "How do I pay?" got a promise of a QR
 *  and the dates ask, the name twice). Code answers before the model: the QR goes with this line, the name once. With no
 *  amount yet it is the site's static QR; the flow sends the amount-set one after submit. */
export const PAY_HOW_RE = /\b(how (?:do|can|should|would) (?:i|we) pay|how to pay|paano (?:po )?(?:mag-?bayad|magbabayad|ang bayad)|pa-?unsa(?:on)? (?:pag-?)?bayad|(?:payment|pay) (?:method|options?)|mode of payment|where (?:do|can) (?:i|we) (?:pay|send (?:the )?payment)|can (?:i|we) pay (?:by|via|with|through|using)|(?:send|give)(?: me| us)? (?:the |your )?(?:gcash|qr))\b/i;
export function payHowReply(flow: Flow | null, name: string | null, lang: Lang, now = new Date()): string {
  if (!flow?.checkin || !flow?.checkout) return P.payHow(name, lang, false);
  const next = prompt(flow, null, false, now).split('\n\n').pop() ?? '';
  return `${P.payHow(name, lang, true)}${next ? `\n\n${next}` : ''}`;
}
/** SPEC-31 s3 (REVIEW F3): a photo with no live upload - never promises the dates are still free. */
export const strayReceiptReply = (name: string | null, lang: Lang) => P.strayReceiptLine(name, lang);

/** Mid-flow: new dates were just given and are open - acknowledge before the next ask (protocol rule 1, live 2026-09-17 10:57). */
export function availabilityAck(flow: Flow, openLine: string): string {
  // D-268: the guest chose these dates from our offer - acknowledge the choice, not announce it as news.
  if (flow.agreed && flow.checkin && flow.checkout) return P.choiceAck(nights(flow.checkin, flow.checkout) === 1 ? dm(flow.checkin) : dmRange(flow.checkin, flow.checkout), flow.lang);
  return P.openAck(openLine, flow.pax, flow.lang);
}
/** The first reply of a flow: a host's welcome that acknowledges what the guest already told us.
 *  `greet` false: the model's own reply already carries the greeting, and the flow's part follows it (SPEC-28 section 2:
 *  "Hi Ben, thank you for reaching out" came twice in one message when a first message asked a question too).
 *  A check-in alone is acknowledged by the checkout ask that always follows (prompt 'checkout'); saying it here too
 *  printed it twice in one message (live 2026-09-23, all three registers). */
export function opener(flow: Flow, name: string | null, answer = '', intro = false, greet = true): string {
  const g = !greet ? '' : answer ? P.greetBlock(name, flow.lang, intro) : P.greeting(name, flow.lang, intro);
  const dates: [string, string] | null = !answer && flow.checkin && flow.checkout ? [dm(flow.checkin), dm(flow.checkout)] : null;
  return P.openerText(g, answer, dates, flow.pax, flow.lang);
}

/** SPEC-14 (D-184): the details are taken progressively - only the first missing item is ever asked for. */
export function nextAsk(flow: Flow): string {
  const missing = !flow.name ? 'name' : !flow.phone ? 'phone' : !flow.email ? 'email' : null;
  return missing ? P.nextDetail(missing, flow.name ?? '', flow.lang) : '';
}
/** The question for the current slot, in the Cassy voice: calm, gracious, precise; guide rather than command. */
export function prompt(flow: Flow, name: string | null, resume = false, now = new Date()): string {
  const first = name ? name.split(' ')[0] : '';
  const L = flow.lang;
  switch (flow.step) {
    case 'dates': return P.datesAsk(first, exampleDates(now), L);
    case 'checkout': return P.nightsAsk(dm(flow.checkin!), flow.checkin === manilaToday(now), L);
    case 'pax': return P.partyAsk(L);
    // The same one-yes question as the price path and the reserved line; the welcome sits above it in the first reply.
    case 'offer': return `${rateLine(flow, now)}\n\n${P.holdOffer(nights(flow.checkin!, flow.checkout!) === 1, L, false)}`;
    case 'contact': {
      if (flow.name || flow.phone || flow.email) return nextAsk(flow);
      return P.detailsAsk(first, L);
    }
    case 'confirm': {
      const q = quoteTotal(flow.checkin!, flow.checkout!);
      return `${P.stayCard({
        resume, who: flow.name ?? name ?? null, range: dmRange(flow.checkin!, flow.checkout!), nights: q.nights, pax: flow.pax,
        phone: flow.phone, email: flow.email, total: peso(q.total),
        promo: q.q.promo_nights > 0 ? { name: q.q.promo_name!, nights: q.q.promo_nights, rate: peso(q.q.promo_rate!) } : null,
      }, L)}\n\n${payChoice(flow)}`;
    }
    default: return '';
  }
}

export type Step = { flow: Flow; reply: string | null; action: 'ask' | 'submit' | 'cancelled' | 'passthrough' };

/** D-222: a new flow reads the calendar when the guest asked about availability OR gave both dates. Before, "book Oct
 *  10 to 12 for 2" was quoted, took name, phone and e-mail, and failed only at submit ("reserved just moments ago"). */
export function needsCalendarCheck(flow: Flow): boolean {
  return flow.asked === 'availability' || Boolean(flow.checkin && flow.checkout);
}

/** Start a flow from the first message; prefills dates and guests when they are in the text. */
/** SPEC-28 section 2: the sentences of a first message that ask something other than availability ("is there wifi?"),
 *  joined; '' when there are none. A bare "?" does not count ("Oct 26 open? Oct 27?"). index.ts hands only these to
 *  the model, because the calendar has already answered the dates (golden 2026-09-25: told not to, the model still
 *  said "yes, those dates are open" above the calendar's own line). */
export function otherQuestions(text: string): string {
  return (text.match(/[^?.!\n]+[?.!]?/g) ?? []).filter((s) => !AVAIL_RE.test(s) && (QUESTION_WORD_RE.test(s) || AMENITY_RE.test(s))).map((s) => s.trim()).join(' ');
}
export function start(text: string, now = new Date()): Flow {
  const at = now.toISOString();
  const first = settleLang(undefined, detectLang(text), 0);
  const flow: Flow = { step: 'dates', started_at: at, updated_at: at, lang: first.lang, bis_turns: first.bisTurns };
  const d = parseDates(text, now);
  const today = at.slice(0, 10);
  if (d[0] && d[0] >= today) { flow.checkin = d[0]; flow.step = 'checkout'; }
  if (flow.checkin && d[1] && d[1] > flow.checkin) { flow.checkout = d[1]; flow.step = 'pax'; }
  const p = /\b(\d|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\s*(?:po|pa|ba|po\s+ba)?\s*(adults?|pax|persons?|people|guests?|tao|tawo|kami|mi|ka|kabuok)\b/i.test(text) || /\b(?:for|para sa|kaming)\s+(\d|one|two|three|four|isa|dalawa|tatlo|apat)\b(?!\s*(?:nights?|days?|gabi|araw))/i.test(text) ? parsePax(text) : null;
  if (p && flow.step === 'pax' && !overCapacity(text, p)) { flow.pax = p; flow.step = 'offer'; } // D-222: over capacity stays at the guest ask, which states the limit
  // What did the guest actually ask? index.ts answers availability from the calendar (code) or hands
  // any other question to the model before the flow's own ask (protocol rule 1).
  flow.asked = AVAIL_RE.test(text) && flow.checkin ? 'availability' : ASK_RE.test(text) && !/\b(can|could|pwede|possible)\b[^?]*\b(book|reserve)\b/i.test(text) ? 'question' : null;
  // SPEC-28 section 2: a sentence other than the availability one that asks something ("is Oct 26 to 28 open? is there
  // wifi?"). Judged per sentence, because the availability question's own "?" would otherwise count.
  if (flow.asked === 'availability') flow.question = otherQuestions(text) !== '';
  return flow;
}

/** Apply the guest's answer to the current slot. A question ("?") passes through to the model. */
export function answer(flow: Flow, text: string, now = new Date()): Step {
  const f: Flow = { ...flow, updated_at: now.toISOString() };
  // Mirror the guest: a Tagalog/Bisaya turn switches the register to Taglish; a plain-English turn switches it back
  // (numbers, dates, "skip", "deposit" and the like carry no language and keep the current one).
  { const words = text.replace(/\S+@\S+|https?:\/\/\S+|\+?\d[\d\s-]{5,}\d/g, ' ').replace(/\b(skip|deposit|full|yes|ok|okay|cancel|stop|sige|opo|oo|po)\b/gi, ' ').match(/[a-z]{3,}/gi) ?? [];
    const d = detectLang(text);
    // SPEC-14 (live read 2026-09-18): at the details step a name is data, not language. "ben munez" read as two
    // English words and flipped a Taglish chat to English for the rest of the booking, card included.
    const nm = f.step === 'contact' ? parseName(text) : null;
    const nameOnly = !!nm && words.length <= nm.split(' ').length;
    if (d !== 'en') { const s = settleLang(f.lang, d, f.bis_turns ?? 0); f.lang = s.lang; f.bis_turns = s.bisTurns; }
    else if (words.length >= 2 && !nameOnly) { f.lang = 'en'; f.bis_turns = 0; } }
  const L = f.lang;
  const today = f.updated_at.slice(0, 10);
  if (CANCEL_RE.test(text) && f.step !== 'await_receipt') return { flow: { ...f, step: 'cancelled' }, reply: P.cancelReply(L), action: 'cancelled' };
  const ask = (reply?: string): Step => ({ flow: f, reply: reply ?? null, action: 'ask' });
  const retry = (what: P.RetryWhat): Step => text.includes('?') ? { flow: f, reply: null, action: 'passthrough' } : ask(P.retryLine(what, prompt(f, null), L));
  switch (f.step) {
    case 'dates': {
      const d = parseDates(text, now);
      // The nearest window was offered as a question: a whole-message yes takes it, a no closes gently (isChatYes, not
      // OFFER_YES_RE - "ok let me think" must not book). index.ts re-reads the calendar because the dates changed.
      if (!d[0] && f.alt && isChatYes(text)) { f.checkin = f.alt.start; f.checkout = f.alt.end; f.alt = undefined; f.agreed = true; f.step = f.pax ? 'offer' : 'pax'; return ask(); }
      // Live 2026-09-28 (Suzanne, "How much?" after the Oct 2 offer got the model quoting Oct 30 from a two-day-old
      // message): a price question about the offered window is answered by code, then the offer is made again.
      if (!d[0] && f.alt && PRICE_RE.test(text)) {
        const one = f.alt.nights === 1 && !f.alt.open_ended;
        f.quoted = true;
        return ask(`${rateLine({ ...f, checkin: f.alt.start, checkout: f.alt.end }, now)}\n\n${P.holdOffer(one, L)}`);
      }
      if (!d[0] && f.alt && OFFER_NO_RE.test(text)) return { flow: { ...f, step: 'cancelled', alt: undefined }, reply: P.cancelReply(L), action: 'cancelled' };
      f.alt = undefined;
      if (!d[0]) return retry('dates');
      if (d[0] < today) return ask(P.pastDate(L));
      f.checkin = d[0]; f.step = 'checkout';
      if (d[1] && d[1] > d[0]) { f.checkout = d[1]; f.step = f.pax ? 'offer' : 'pax'; }
      return ask();
    }
    case 'checkout': {
      const d = parseDates(text, now);
      const n = d[0] ? null : nightsIn(text);
      if (n) { f.checkout = addDay(f.checkin!, n); f.step = f.pax ? 'offer' : 'pax'; return ask(); }
      if (!d[0]) return retry('checkout');
      // Live 2026-09-26 (Suzanne): "So is it available today?" at this step got "Check-out would need to fall after Sep 26".
      // The check-in date again, asked about or "only", is one night; index.ts then answers it from the calendar.
      if (d[0] === f.checkin && (AVAIL_RE.test(text) || /\b(only|just|lang|ra)\b/i.test(text))) { f.checkout = addDay(f.checkin!); f.step = f.pax ? 'offer' : 'pax'; return ask(); }
      if (d[0] <= f.checkin!) return ask(P.earliestCheckout(dm(f.checkin!), dm(addDay(f.checkin!)), L));
      f.checkout = d[0]; f.step = f.pax ? 'offer' : 'pax'; return ask();
    }
    case 'pax': {
      const p = parsePax(text);
      if (!p) return retry('guests');
      if (overCapacity(text, p)) return ask(P.overCapacityLine(p, L));
      f.pax = p;
      // The guest already agreed to these dates (flow.agreed): the price and the details ask in one message.
      if (f.agreed) {
        f.step = 'contact';
        const lead = f.quoted // the price was just given: welcome them instead of quoting it twice (live probe 2026-09-28)
          ? P.partyWelcome(f.pax, L)
          : rateLine(f, now);
        return ask(`${lead}\n\n${P.detailsAsk('', L, false)}`);
      }
      f.step = 'offer'; return ask();
    }
    case 'offer': {
      if (OFFER_NO_RE.test(text)) return { flow: { ...f, step: 'cancelled' }, reply: P.cancelReply(L), action: 'cancelled' };
      if (OFFER_YES_RE.test(text)) { f.step = 'contact'; return ask(); }
      return { flow: f, reply: null, action: 'passthrough' }; // anything else: the model answers and the offer is asked again
    }
    case 'contact': {
      if (text.includes('?')) return { flow: f, reply: null, action: 'passthrough' };
      // A correction arriving here is a correction, not a name. "actually make it <dates>" was read as
      // the guest's NAME ("Actually Make It To") and the flow carried on with the OLD dates - a booking
      // error, not a wording one (probe-matrix confirm-correction, 2026-09-18). Same rule the confirm
      // step below already applies: at this step dates win over parseName.
      const dc = parseDates(text, now);
      if (dc[0] && dc[0] >= today) {
        f.checkin = dc[0];
        if (dc[1] && dc[1] > dc[0]) f.checkout = dc[1];
        else if (f.checkout! <= dc[0]) { f.step = 'checkout'; return ask(); }
        f.pay_full = lastMinute(f.checkin!, now) ? true : undefined;
        return ask(nextAsk(f));
      }
      const ph = parsePhone(text), em = parseEmail(text), nm = parseName(text);
      if (ph) f.phone = ph;
      if (em) f.email = em;
      if (nm && !f.name) f.name = nm;
      if (!ph && !em && !nm) return retry('details');
      if (!f.name || !f.phone || !f.email) return ask(nextAsk(f));
      f.pay_full = lastMinute(f.checkin!, now) ? true : undefined; f.step = 'confirm'; return ask();
    }
    case 'confirm': {
      // Corrections first, then the payment choice sends it (Lloyd 11:05: "deposit, my email is …" must keep
      // the e-mail; "full na lang, 3 guests" must keep the 3). A date change re-shows the card: the total moves.
      const d = parseDates(text, now), p = /\b(guest|pax|person|people|tao|tawo|adult|kami|kabuok|mi\b)/i.test(text) ? parsePax(text) : null, ph = parsePhone(text), e = parseEmail(text);
      let changed = false, datesChanged = false;
      if (d[0] && d[0] >= today) { f.checkin = d[0]; changed = datesChanged = true; if (d[1] && d[1] > d[0]) f.checkout = d[1]; else if (f.checkout! <= d[0]) { f.step = 'checkout'; return ask(); } }
      if (p && !overCapacity(text, p)) { f.pax = p; changed = true; }
      if (ph) { f.phone = ph; changed = true; }
      if (e) { f.email = e; changed = true; }
      if (datesChanged) { f.pay_full = lastMinute(f.checkin!, now) ? true : undefined; return ask(); }
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
  if (diff === 0 || diff === 1) return P.relDayWord(diff, lang);
  return new Date(iso).toLocaleDateString('en-PH', { timeZone: 'Asia/Manila', weekday: 'long' });
}
/** SPEC-10 control 6 and D-168/D-169: the payment message's facts, sealed here; its words are persona.ts's (APPROVED). */
export function paymentReply(flow: Flow, name: string | null, _siteUrl: string, now = new Date()): string {
  const until = flow.hold_expires_at ? new Date(flow.hold_expires_at).toLocaleString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }).replace(', ', ' at ') : null;
  return P.paymentMessage({
    name: name ? name.split(' ')[0] : '',
    dates: dmRange(flow.checkin!, flow.checkout!), // SPEC-14: "Oct 20 to 22", "Sep 30 to Oct 2"
    ref: flow.ref, until, rel: flow.hold_expires_at ? relDay(flow.hold_expires_at, now, flow.lang) : '',
    hold: !!flow.hold, near: lastMinute(flow.checkin!, now),
    deposit: peso(flow.deposit!), balance: peso(flow.total! - flow.deposit!), full: (flow.deposit ?? 0) >= (flow.total ?? 0),
  }, flow.lang);
}
