// Messenger book intent (booking PRD §A, session 27). Pure functions, no I/O: a code-driven
// slot-filling flow that index.ts runs BEFORE the model. The model never books; it only answers
// questions. State is one jsonb on concierge_threads.booking_flow.
import { cardOn, currentCard, quote, type Quote, type RateCard } from '../_shared/cascade-core/pricing.ts';

/** Register: en = Native English protocol, tl = Native Filipino (Taglish, purposeful po), bis = Native Bisaya (Bislish, no po). */
export type Lang = 'en' | 'tl' | 'bis';
export const pick = (lang: Lang | undefined, t: { en: string; tl: string; bis: string }): string => t[lang ?? 'en'];
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
};

export const BOOK_RE = /\b(book(ing)?|reserve|reservation|magpa-?book|pa-?book|i-?book|mag-?reserve|hold (the|my|our) dates|arrange (it|the booking)|(do|settle) it here|here in (the|this) chat|dito (po )?sa chat|diri sa chat)\b/i; // session 30: invitations now offer the chat route, so its natural answers start the flow
export const CANCEL_RE = /\b(cancel|stop|wag na|huwag|never ?mind|nevermind|not now|forget it|change of plans|di na tuloy|hindi na tuloy|dili na|wag na lang)\b/i;
const YES_RE = /^\s*(yes|yes po|oo|oo po|sige|sige po|go|confirm|confirmed|ok|okay|okay po|ok po|proceed|tama|correct|yup|yep|y)\s*[.!]*\s*$/i;
const SKIP_RE = /^\s*(skip|wala|none|no email|no)\s*[.!]*\s*$/i;
const FULL_RE = /\b(full|buo|buong|lahat|whole|everything|total|bayaran (ko )?lahat|in full)\b/i;
const DEPOSIT_RE = /\b(deposit|reservation fee|fee|50|half|kalahati|reserve|partial|down ?payment|dp)\b/i;
const AVAIL_RE = /\b(available|avail|vacant|bakante|open|free|may (?:vacancy|slot)|meron pa)\b/i;
/** SPEC-14 (D-184): the answers to "Shall we set the dates aside for you?" */
const OFFER_YES_RE = /^\W*(yes|yes please|yes po|sure|of course|ok(ay)?( po)?|sige( po)?|oo( po)?|opo|go|please do|proceed|set (it|them) aside)\b/i;
const OFFER_NO_RE = /^\W*(no|not (yet|now)|hindi( po)?|dili|wala( pa)?|later|maybe later)\b/i;
const ASK_RE = /\?|\b(magkano|how much|pwede|can (i|we)|is (it|there)|are there|meron)\b/i;
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
    ? pick(lang, {
        en: `For 1 night the direct rate is ${pr} with our ${name} (our standard is ${php(std)}).`,
        tl: `For 1 night po, ang direct rate ay ${pr} with our ${name} (standard namin ay ${php(std)}).`,
        bis: `For 1 night, ang direct rate kay ${pr} with our ${name} (ang standard namo kay ${php(std)}).` })
    : pick(lang, {
        en: `Your ${q.n} nights fall inside our ${name}, so booking directly brings them to ${pr} per night instead of the standard ${php(std)} — ${php(q.total)} for the stay.`,
        tl: `Pasok po ang ${q.n} nights ninyo sa ${name} namin, kaya sa direct booking ay ${pr} per night imbes na ang standard na ${php(std)} — ${php(q.total)} for the stay.`,
        bis: `Sulod sa among ${name} ang inyong ${q.n} nights, so sa direct booking kay ${pr} per night imbes sa standard nga ${php(std)} — ${php(q.total)} for the stay.` });
  const rest = q.n - q.promo_nights, rr = php(q.tier_rate);
  return pick(lang, {
    en: `Booking directly with us, your ${q.n} nights come to ${php(q.total)}: ${q.promo_nights} night${q.promo_nights === 1 ? '' : 's'} (${when}) at our ${name} rate of ${pr}, and ${rest} night${rest === 1 ? '' : 's'} at ${rr}, instead of the standard ${php(std)} a night.`,
    tl: `Kapag direct booking po sa amin, ang ${q.n} nights ninyo ay ${php(q.total)}: ${q.promo_nights} night${q.promo_nights === 1 ? '' : 's'} (${when}) sa ${name} rate na ${pr}, at ${rest} night${rest === 1 ? '' : 's'} sa ${rr}, imbes na ang standard na ${php(std)} per night.`,
    bis: `Kung direct booking sa amo, ang inyong ${q.n} nights kay ${php(q.total)}: ${q.promo_nights} night${q.promo_nights === 1 ? '' : 's'} (${when}) sa ${name} rate nga ${pr}, ug ${rest} night${rest === 1 ? '' : 's'} sa ${rr}, imbes sa standard nga ${php(std)} per night.` });
}
/** SPEC-14 (D-184): the direct-booking rate, said before the offer. Every figure comes from quoteTotal (the rate card). */
export function rateLine(flow: Flow, now = new Date(), card: RateCard = currentCard()): string {
  const q = quoteTotal(flow.checkin!, flow.checkout!, card), STD_RATE = cardOn(card, flow.checkin!).base; // the standard on the check-in date
  const body = q.q.promo_nights > 0 ? promoRateLine(flow.lang, q, STD_RATE) : q.nights >= 2
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
  return lastMinute(flow.checkin!, now)
    ? `${body} ${pick(flow.lang, {
        en: `As your check-in is less than five days away, the full amount secures the stay.`,
        tl: `As your check-in is less than five days away, the full amount secures the stay.`,
        bis: `As your check-in is less than five days away, the full amount secures the stay.` })}`
    : body;
}
/** SPEC-14 (D-184): the card's payment sentence - the fee-or-full choice, or the full-only sentence inside 48 h. */
export function payChoice(flow: Flow): string {
  const q = quoteTotal(flow.checkin!, flow.checkout!);
  return flow.pay_full === true
    ? pick(flow.lang, {
        en: `As your check-in is near, the full ${peso(q.total)} secures your stay, with the ₱1,000 refundable deposit due before you arrive. You may reply FULL to send your request through, or let us know if anything needs changing.`,
        tl: `Malapit na po ang check-in, kaya ang full ${peso(q.total)} ang magse-secure ng stay, and the ₱1,000 refundable deposit is due before you arrive. You may reply FULL to send the request through, or sabihin lang po if may kailangang baguhin.`,
        bis: `Duol na ang check-in, so ang full ${peso(q.total)} ang mag-secure sa stay, and the ₱1,000 refundable deposit is due before you arrive. Pwede mo mu-reply og FULL para ma-send ang request, or ingna lang mi if naa may changes.` })
    : pick(flow.lang, {
        en: `A reservation fee of ${peso(q.deposit)} holds the dates. The balance and the ₱1,000 refundable deposit are due at least a day before check-in; or you may settle the full ${peso(q.total)} now. Just tell us "fee" or "full", whichever suits you.`,
        tl: `Ang reservation fee na ${peso(q.deposit)} ang magho-hold ng dates. The balance and the ₱1,000 refundable deposit are due at least a day before check-in; o puwede rin pong bayaran ang full ${peso(q.total)} ngayon. Sabihin lang po "fee" o "full", kung alin ang mas okay sa inyo.`,
        bis: `Ang reservation fee nga ${peso(q.deposit)} ang mo-hold sa dates. The balance and the ₱1,000 refundable deposit are due at least a day before check-in; o pwede pud bayran ang full ${peso(q.total)} karon. Ingna lang mi og "fee" o "full", kung asa ang mas okay ninyo.` });
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
const firstName = (name: string | null | undefined) => (name ?? '').trim().split(/\s+/)[0] ?? '';
// D-258 (Lloyd 2026-09-26, "more english than this awkward tagalog"): the SPEC-31/33 payment-path lines are English in every
// register; Taglish keeps one courtesy "po". The Lloyd-authored flow lines (prompt, paymentReply: D-168/D-169) are unchanged.
/** SPEC-31 s1 (REVIEW F1): "cancel po" while the hold is open. Code says it and a host card does it - nothing is
 *  released from the chat. A date in the same message is a change, not a cancel. */
export function holdCancelReply(flow: Flow, name: string | null, lang: Lang, change: boolean): string {
  const n = firstName(name), c = n ? `, ${n}` : '';
  const dates = dmRange(flow.checkin!, flow.checkout!);
  // After a receipt, "nothing is charged" would be false: the 5-day rule decides, and the host says so.
  if (!change && flow.step === 'receipt_sent') return pick(lang, {
    en: `Understood${c}. We've let our host know and they'll release the hold on ${dates} for you; they'll go over your payment with you here. 🌿`,
    tl: `Noted po${c}. We've let our host know and they'll release the hold on ${dates} for you; they'll go over your payment with you here. 🌿`,
    bis: `Noted${c}. We've let our host know and they'll release the hold on ${dates} for you; they'll go over your payment with you here. 🌿` });
  return change
    ? pick(lang, {
        en: `Noted${c} - we can look at that. We've passed the change to our host, and they'll confirm the new dates and the hold here. 🌿`,
        tl: `Noted po${c} - we can look at that. We've passed the change to our host, and they'll confirm the new dates and the hold here. 🌿`,
        bis: `Noted${c} - we can look at that. We've passed the change to our host, and they'll confirm the new dates and the hold here. 🌿` })
    : pick(lang, {
        en: `Understood${c}. We've let our host know and they'll release the hold on ${dates} for you; nothing is charged. If your plans change again, your dates are one message away. 🌿`,
        tl: `Noted po${c}. We've let our host know and they'll release the hold on ${dates} for you; nothing is charged. If your plans change again, your dates are one message away. 🌿`,
        bis: `Noted${c}. We've let our host know and they'll release the hold on ${dates} for you; nothing is charged. If your plans change again, your dates are one message away. 🌿` });
}
/** SPEC-31 s2 (REVIEW F2): "paid na po?" once a booking exists. No timing promise: nothing measures the host. */
export function paidClaimReply(flow: Flow, name: string | null, lang: Lang): string {
  const n = firstName(name), c = n ? `, ${n}` : '';
  // SPEC-33 s2: after a decline the receipt is no longer "with us" - the await_receipt line asks for the screenshot again.
  return flow.step !== 'receipt_declined' && (flow.step === 'receipt_sent' || flow.photo_at)
    ? pick(lang, {
        en: `Yes${c}, your receipt is with us and our host is reviewing it now. You'll hear the confirmation here.`,
        tl: `Yes po${c}, your receipt is with us and our host is reviewing it now. You'll hear the confirmation here.`,
        bis: `Yes${c}, your receipt is with us and our host is reviewing it now. You'll hear the confirmation here.` })
    : pick(lang, {
        en: `Thank you${c}. We don't have the receipt yet on our side - a screenshot of the GCash confirmation sent here is all we need, and our host will match it to ${flow.ref}.`,
        tl: `Thank you po${c}. We don't have the receipt yet on our side - a screenshot of the GCash confirmation sent here is all we need, and our host will match it to ${flow.ref}.`,
        bis: `Thank you${c}. We don't have the receipt yet on our side - a screenshot of the GCash confirmation sent here is all we need, and our host will match it to ${flow.ref}.` });
}
/** D-258 (Lloyd 2026-09-26: "when they ask to pay, give them gcash qr"; live 00:56Z "How do I pay?" got a promise of a QR
 *  and the dates ask, the name twice). Code answers before the model: the QR goes with this line, the name once. With no
 *  amount yet it is the site's static QR; the flow sends the amount-set one after submit. */
export const PAY_HOW_RE = /\b(how (?:do|can|should|would) (?:i|we) pay|how to pay|paano (?:po )?(?:mag-?bayad|magbabayad|ang bayad)|pa-?unsa(?:on)? (?:pag-?)?bayad|(?:payment|pay) (?:method|options?)|mode of payment|where (?:do|can) (?:i|we) (?:pay|send (?:the )?payment)|can (?:i|we) pay (?:by|via|with|through|using)|(?:send|give)(?: me| us)? (?:the |your )?(?:gcash|qr))\b/i;
export function payHowReply(flow: Flow | null, name: string | null, lang: Lang, now = new Date()): string {
  const n = firstName(name), y = n ? `${n}, you` : 'You', po = lang === 'tl' ? ' po' : '';
  if (!flow?.checkin || !flow?.checkout) return `${y} may pay${po} by GCash with the QR below. Whenever you're ready, share your check-in and check-out dates and we'll send it again with the exact amount already set, so there's nothing to type; a screenshot of the payment here is all we need after.`;
  const next = prompt(flow, null, false, now).split('\n\n').pop() ?? '';
  return `${y} may pay${po} by GCash with the QR below. Whenever you're ready, we'll finish your booking details and send it again with the exact amount already set, so there's nothing to type.${next ? `\n\n${next}` : ''}`;
}
/** SPEC-31 s3 (REVIEW F3): a photo with no live upload - never promises the dates are still free. */
export function strayReceiptReply(name: string | null, lang: Lang): string {
  const n = firstName(name), c = n ? `, ${n}` : '';
  return pick(lang, {
    en: `Thank you${c}. We have your photo. Our host will match it to your booking and confirm here; if the hold had lapsed, they'll check the dates are still open and set them up again. 🌿`,
    tl: `Thank you po${c}. We have your photo. Our host will match it to your booking and confirm here; if the hold had lapsed, they'll check the dates are still open and set them up again. 🌿`,
    bis: `Thank you${c}. We have your photo. Our host will match it to your booking and confirm here; if the hold had lapsed, they'll check the dates are still open and set them up again. 🌿` });
}

/** The first reply of a flow: a host's welcome that acknowledges what the guest already told us
 * (session 28 - "Your mobile number po?" as an opener read as a form, not a host). */
/** D-173 / SPEC-01: the direct answer to "are you a bot?", approved wording, all three registers.
 *  The first name and its comma are added by the caller. */
export const BOT_REPLY: Record<Lang, string> = {
  en: `I'm Cassy, Cascade Hideaway's digital concierge, an AI assistant looked after by our team. I'm glad to help with rates, dates, directions and anything about your stay, and whenever you'd like a person, our host Marifel is one message away.`,
  tl: `ako po si Cassy, ang digital concierge ng Cascade Hideaway, isang AI assistant na inaalagaan ng aming team. I'm glad to help with rates, dates, directions at anything about your stay, and kapag gusto ninyong makausap ang isang person, si Marifel, ang host namin, ay one message away lang po.`,
  bis: `ako si Cassy, ang digital concierge sa Cascade Hideaway, usa ka AI assistant nga giatiman sa among team. Glad ko to help with rates, dates, directions ug anything about your stay, ug kung gusto mo makig-istorya og person, si Marifel, among host, one message away ra.`,
};
/** D-173 / SPEC-01: said once, in the first message only, directly after the greeting's
 *  "thank you for reaching out" sentence and before the answer. Approved wording - do not reword.
 *  No "po" in tl or bis on purpose: the canned first message already carries three (protocol 07
 *  section 4 asks for one or two) and Bisaya takes none (protocol 09 section 3). */
export const CASSY_INTRO: Record<Lang, string> = {
  // D-244 (Lloyd 2026-09-25, "shorten cassy introduction, minimal yet invokes trust"): name, the disclosure (digital),
  // and a named human with the team - nothing else. Was 91/96/96 characters.
  en: `I'm Cassy, the home's digital concierge, here with Marifel and our team. `,
  tl: `Ako si Cassy, ang digital concierge ng Cascade, kasama si Marifel at ang team. `,
  bis: `Ako si Cassy, ang digital concierge sa Cascade, kauban si Marifel ug ang team. `,
};
/** `intro` defaults to false, not true as SPEC-01 sketched: every caller that knows whether the
 *  guest has already met Cassy passes it explicitly, and a call site missed later should fall back
 *  to saying nothing rather than to repeating the introduction, which is the one thing D-173
 *  forbids. */
export const greeting = (name: string | null, lang: Lang = 'en', intro = false) => pick(lang, {
  en: `${name ? `Hi ${name.split(' ')[0]},` : 'Hello,'} thank you for reaching out to Cascade Hideaway. `,
  tl: `${name ? `Hi ${name.split(' ')[0]}!` : 'Hello po!'} Salamat sa pag-message sa Cascade Hideaway. `,
  bis: `${name ? `Hi ${name.split(' ')[0]}!` : 'Hello!'} Salamat sa pag-message sa Cascade Hideaway. `,
}) + (intro ? CASSY_INTRO[lang ?? 'en'] : '');
/** SPEC-28 section 3: with the Cassy sentence the greeting is long, so the answer goes on its own paragraph (golden
 *  first-avail-taken-en read as one block). Without it the greeting and the answer stay one paragraph: that is Lloyd's
 *  approved first reply (2026-09-18) and the lint wants the answer in the first paragraph. */
export const greetBlock = (name: string | null, lang: Lang = 'en', intro = false) => intro ? greeting(name, lang, true).trimEnd() + '\n\n' : greeting(name, lang, false);
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
/** `greet` false: the model's own reply already carries the greeting, and the flow's part follows it (SPEC-28 section 2:
 *  "Hi Ben, thank you for reaching out" came twice in one message when a first message asked a question too). */
export function opener(flow: Flow, name: string | null, answer = '', intro = false, greet = true): string {
  const who = party(flow);
  const welcome = pick(flow.lang, { en: `we'd be glad to welcome ${who}.`, tl: `we'd be glad to have ${who}.`, bis: `looking forward mi to have ${who}.` });
  if (answer) return `${greet ? greetBlock(name, flow.lang, intro) : ''}${answer}, and ${welcome}\n\n`;
  const dates = flow.checkin && flow.checkout
    ? pick(flow.lang, { en: `${dm(flow.checkin)} to ${dm(flow.checkout)} is noted, and we'll check those dates for you as we go. `, tl: `Noted po ang ${dm(flow.checkin)} to ${dm(flow.checkout)} — iche-check namin ang dates as we go. `, bis: `Noted ang ${dm(flow.checkin)} to ${dm(flow.checkout)} — amo i-check ang dates as we go. ` })
    // A check-in alone is acknowledged by the checkout ask that always follows (prompt 'checkout'); saying it here too
    // printed it twice in one message (live 2026-09-23, all three registers).
    : '';
  const w = welcome.charAt(0).toUpperCase() + welcome.slice(1);
  return `${greet ? greeting(name, flow.lang, intro) : ''}${dates}${w}\n\n`;
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
    case 'dates': { const ex = exampleDates(now); return pick(L, {
      en: `${n ? `${n}which` : 'Which'} dates would you like to stay with us? Your check-in and check-out will do (for example, "${ex}").`,
      tl: `${n}kailan po ninyo gustong mag-stay? Check-in and check-out lang po (halimbawa, "${ex}").`,
      bis: `${n}kanus-a mo gusto mag-stay? Check-in and check-out lang (pananglitan, "${ex}").`,
    }); }
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
      tl: `I-set na po ba namin ang dates para sa inyo?`,
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
      ...(q.q.promo_nights > 0 ? [`🏷️ ${q.q.promo_name}: ${q.q.promo_nights} night${q.q.promo_nights === 1 ? '' : 's'} at ${peso(q.q.promo_rate!)}`] : []),
      pick(L, { en: `🔐 ₱1,000 refundable security deposit, returned after check-out`, tl: `🔐 ₱1,000 refundable security deposit, ibabalik after check-out`, bis: `🔐 ₱1,000 refundable security deposit, i-uli after check-out` }),
      ``,
      payChoice(flow),
    ].join('\n'); }
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
      if (overCapacity(text, p)) return ask(pick(L, { en: `As much as we'd love to host everyone, the home is most comfortable for up to 3 adults, or 2 adults with 2 children. For a party of ${p}, a larger place would give you more room to rest. If your group fits, just let us know the count again.`, tl: `Comfortable po ang home for up to 3 adults, or 2 adults with 2 kids. For ${p}, mas maganda po ang mas malaking place para mas may space kayo. If kasya po ang group ninyo, sabihin lang po ulit kung ilan kayo.`, bis: `Comfortable ang home for up to 3 adults, or 2 adults with 2 kids. For ${p}, mas maayo ang mas dako nga place para mas naa moy space. If kasya ang group ninyo, ingna lang mi pila mo.` }));
      f.pax = p; f.step = 'offer'; return ask();
    }
    case 'offer': {
      if (OFFER_NO_RE.test(text)) return { flow: { ...f, step: 'cancelled' }, reply: cancelReply(L), action: 'cancelled' };
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
      if (!ph && !em && !nm) return retry('those details');
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
  if (diff === 0) return pick(lang, { en: 'today', tl: 'ngayong araw', bis: 'karon' });
  if (diff === 1) return pick(lang, { en: 'tomorrow', tl: 'bukas', bis: 'ugma' });
  return new Date(iso).toLocaleDateString('en-PH', { timeZone: 'Asia/Manila', weekday: 'long' });
}
/** SPEC-10 control 6, the payment promise. Lloyd approved these three sentences on 2026-09-20; the
 *  only addition is the registered-holder clause (see below). It is sent as its OWN message, straight
 *  after the QR image, and deliberately not folded into paymentReply: that reply already runs 618 /
 *  682 / 664 characters (en / tl / bis) against lintReply's 700-character too_long cap, so merging a
 *  163-to-173-character sentence in breaks too_long in every variant and too_dense in four. Placing it
 *  beside the QR also puts it exactly where the doubt happens - the guest is looking at the QR when
 *  they wonder whose account this is.
 *
 *  Both names on purpose. The QR's confirm screen shows `Cascades`; the booking site shows
 *  `Marifel Suzanne Boncales` in four places. Naming only the first, on a page that says the second,
 *  would manufacture the very doubt this sentence exists to settle. */
export function paymentPromise(lang: Lang | undefined): string {
  return pick(lang, {
    en:  `For your peace of mind: we only ever ask for payment here in this chat or on our site, through the GCash QR we send, and the account name you'll see is Cascades, registered to Marifel Suzanne Boncales.`,
    // D-258: English in every register, no "po" here: it rides under a line that already carries one (golden R6 caps it at 2).
    tl:  `For your peace of mind: we only ever ask for payment here in this chat or on our site, through the GCash QR we send, and the account name you'll see is Cascades, registered to Marifel Suzanne Boncales.`,
    bis: `For your peace of mind: we only ever ask for payment here in this chat or on our site, through the GCash QR we send, and the account name you'll see is Cascades, registered to Marifel Suzanne Boncales.`,
  });
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
    // SPEC-31 s6 (F16): a full payment far ahead opens no hold; "as your stay is near" was false 40 days out.
    : !lastMinute(flow.checkin!, now) ? pick(L, {
        en: `${n ? `${n}, we've` : `We've`} received your request for ${dates}, and it is yours as soon as your payment arrives. Your booking reference is ${flow.ref}.`,
        tl: `${n ? `${n}, received` : `Received`} na po namin ang request ninyo for ${dates}, at sa inyo na ito once dumating ang payment. Ang booking reference ninyo po ay ${flow.ref}.`,
        bis: `${n ? `${n}, na-receive` : `Na-receive`} na namo ang request ninyo for ${dates}, ug inyo na ni once muabot ang payment. Your booking reference is ${flow.ref}.` })
    : pick(L, {
        en: `${n ? `${n}, we've` : `We've`} received your request for ${dates}. Your booking reference is ${flow.ref}. As your stay is near, we'll confirm as soon as your payment arrives.`,
        tl: `${n ? `${n}, received` : `Received`} na po namin ang request ninyo for ${dates}. Ang booking reference ninyo po ay ${flow.ref}. Malapit na ang stay, kaya iko-confirm namin as soon as dumating ang payment.`,
        bis: `${n ? `${n}, na-receive` : `Na-receive`} na namo ang request ninyo for ${dates}. Your booking reference is ${flow.ref}. Duol na ang stay, so amo dayon i-confirm once muabot ang payment.` });
  // SPEC-31 s5 (F10): one receipt sentence, and the whole message inside 560 characters (voice.test.ts pins it).
  const pay = pick(L, {
    en: `To secure the stay, you may send the ${dep} ${what} through GCash (0956 011 5744) with the QR below - the exact amount is already set. Once done, a screenshot of the receipt here is all we need.`,
    tl: `Para ma-secure ang stay, you may send the ${dep} ${what} through GCash (0956 011 5744) gamit ang QR below - naka-set na ang exact amount. Once done, screenshot lang ng receipt dito ang kailangan namin.`,
    bis: `Para ma-secure ang stay, pwede na ma-send ang ${dep} ${what} through GCash (0956 011 5744) gamit ang QR below - naka-set na daan ang exact amount. Once done, screenshot ra sa receipt diri ang among kinahanglan.` });
  const later = full
    ? pick(L, { en: `Only the ₱1,000 refundable security deposit remains, and it is due before you arrive.`, tl: `Ang ₱1,000 refundable security deposit na lang po ang natitira, and it is due before you arrive.`, bis: `Ang ₱1,000 refundable security deposit na lang ang nabilin, and it is due before you arrive.` })
    : pick(L, { en: `The remaining ${bal} balance and the ₱1,000 refundable security deposit are due at least a day before check-in.`, tl: `Ang natitirang ${bal} balance at ang ₱1,000 refundable security deposit ay due at least a day before check-in.`, bis: `The remaining ${bal} balance and the ₱1,000 refundable security deposit are due at least a day before check-in.` });
  // SPEC-31 s5: the review-and-confirm sentence (Lloyd 2026-09-18) is gone - the pay sentence already asks for the
  // receipt, and "receipt" twice pushed the message to 618-682 characters (REVIEW F10).
  const close = pick(L, { en: `Thank you${nm}. We look forward to welcoming you to Cascade Hideaway. 🌿`, tl: `Salamat po${nm}. We look forward to welcoming you to Cascade Hideaway. 🌿`, bis: `Salamat${nm}. Looking forward mi sa inyong stay at Cascade Hideaway. 🌿` });
  return [head, '', pay, '', later, '', close].join('\n');
}
