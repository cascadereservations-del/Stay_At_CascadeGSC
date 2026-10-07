// messenger-concierge v1 (2026-09-11)
// Facebook Messenger webhook -> deterministic risk gate -> Gemini reply grounded in
// facts.ts + live calendar_events -> Send API. Human takeover: any Page-inbox reply
// (echo) silences the bot on that thread for 24 h. Kill switch: app_settings.concierge_mode.
//
// Secrets (Edge Function secrets, never app_settings):
//   META_VERIFY_TOKEN, META_APP_SECRET, META_PAGE_TOKEN, META_APP_ID (optional),
//   CASCADE_GEMINI_BOT_KEY (falls back to GEMINI_BOT_KEY), CASCADE_OPENROUTER_BOT_KEY
//   (backup provider, optional), TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID.
// Deploy with verify_jwt=false: Meta cannot send a Supabase JWT.

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { draftFailureNote, gate, houseRuleKind, modeFrom, needsDatesFirst, statedName, stayLines, type RiskCode, type StayRow } from './policy.ts';
import { ACK_SUGGEST, ATTACHMENT_REPLY, HANDOFF, holdOffer, accessVerify, attachmentNoted, houseVerifyAsk, priorityAsk, priorityRetry, priorityUnmatched, priorityVerified, closers, handoffFollowUp, voiceNote, botReply as botLine, datesFirstLine, pastStayAsk, datesTaken, discountHostLine, DISCOUNT_HOST_PAST, houseRule, compose, receiptAlready, receiptLapsed, receiptRetry, receiptThanks, seeHomeLine, signFirst, submitFailed, haggleLine, haggleHold, promoFirst, turnoverNotice, warmClause, type PromoFacts } from './persona.ts';
import { JEV_INTENTS, jevRoute, primaryLang, routeRisk, type JevRoute } from './jev.ts'; // D-271
import { turnStats } from './stats.ts'; // D-285
import { needsCalendarCheck } from './booking.ts';
import { seedFlow } from './probe-seed.ts'; // SPEC-38 s8: Cassy's reply draft seeds the booking flow (probe path only)
// Messenger book intent (booking PRD §A, session 27): code-driven slot filling, no model in the loop.
import { AVAIL_WORD_RE, BOOK_RE, CANCEL_RE, datesOf, rolledPastStay, stayFromPhrase, PAY_HOW_RE, payHowReply, answer, isChatYes, PRICE_RE, availabilityAck, availabilityLine, bookingStart, dmRange, flowLead, greeting, guestLang, holdCancelReply, holdNote, lastMinute, lastRef, otherQuestions, isActive, opener, openWindows, paidClaimReply, parseDates, paymentPromise, prompt, quoteTotal, rateLine, replyLang, SEE_RE, start, stayPayMessage, strayReceiptReply, toneOf, trimWindow, TRUST_RE, type Flow, type Window } from './booking.ts';
import { addTurnoverNotice, dedupeAvailability, dropPassingRange, kusang, nameOnce, noPo, sentencesOf, dropBankUnlessAsked, payHoldReply, claimsOpen, contractions, dropNameAsk, dropPaxAsk, fixEarlyFee, gladNotHappy, isCold, parseDraftJson, offersEarlyCheckin, setTurnoverCheckin, turnoverCheckinLine, lintReply, offRegister, setAvailability, lookNudge, STAY_PAY_CAP } from './voice.ts';
import { loadContact } from '../_shared/cascade-core/contact.ts';
import { dropJunctionDays, fetchChains, stayContinues } from '../_shared/cascade-core/chains.ts'; // D-290
import { houseBlock, loadHouse, matchHouse } from '../_shared/cascade-core/house.ts'; // D-282
import { CONTACT_CHIP, contactHostChip, isStayingNow, postbackText, priorityAnswer, priorityEntry, stayIsCurrent, type PriorityEntry, type VerifyResult } from './priority.ts'; // session 59
import { GCASH_QRPH_BASE, qrphWithAmount, qrPng } from '../_shared/cascade-core/qrph.ts';
import { fbSendImage, fbSendImageBytes, HOST_HOLD_MS, laterOf } from '../_shared/cascade-core/messenger.ts';
import { AIRBNB_URL, MAYA_FACT, OUTPUT_ANSWER, SITE_URL, factsFor, voiceCompact, voiceFor } from '../_shared/cascade-core/facts.ts';
import { currentCard, livePromos, loadCard, tierRate } from '../_shared/cascade-core/pricing.ts';
import { chatJson, geminiBreaker, probeScope, probeTotals, setProviderKey } from '../_shared/cascade-core/providers.ts';
// Session 26 (2026-09-16, Telegram plan §5/§6): OPS cards open with 💬 GUEST; a complaint or safety
// handoff also raises a work order (guest_report) so the Today page sees it, not just this chat.
import { withHeader } from '../_shared/cascade-core/format.ts';
import { maskMoney } from '../_shared/ops-money.ts'; // OPS never shows guest money (Lloyd 2026-10-02); the guest text and the sent options stay whole
import { raiseWorkOrder } from '../_shared/cascade-core/workorders.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const GRAPH = 'https://graph.facebook.com/v21.0';
const PAGE_ID = '699640026568720'; // Cascades Hideaway; /me fails for some page-token types
// 2026-09-12: Google retired gemini-2.5-flash for new keys (404 names gemini-3.6-flash as the
// successor). Override without a redeploy via the CASCADE_GEMINI_MODEL secret.
// Cascade-scoped secret names (set 2026-09-12); the bare names are the pre-2026-09-12 fallback.
const HUMAN_HOLD_MS = 24 * 3_600_000;
// Sprint 0 (Lloyd, 2026-09-16): a host reply from the Page inbox used to mute the bot on that
// thread for 24 h, so a routine follow-up ("what's the Wi-Fi?") an hour later went unanswered.
// The echo hold is now 2 h; safety holds and the handoff dedupe window keep the 24 h constant.
// D-317 (Lloyd 2026-10-08, standing rule): once Marifel or Lloyd replies, Cassy sends nothing more on that thread - she only
// notifies the host (Telegram, admin Conversations). The hold is 30 days from the latest host reply and never shortens.
// Our own apps (admin host-reply, the Telegram card send, the inquiry send) set the same hold themselves: their echoes carry our app id.
const ECHO_HOLD_MS = HOST_HOLD_MS;
const HISTORY_KEEP = 16; // 32 stored entries; 12 dropped a guest's dates after a 30-turn chat (2026-09-13)

// Guest-facing handoff lines, the attachment reply, ACK_SUGGEST and the dates-first answer live in persona.ts (session 58).
// Early/late check-in-out before dates are known (see needsDatesFirst in policy.ts).
const LOCAL_RE = /\b(po|pwede|kailan|maaga|naa|moy|kami|namin|ba|ninyo|nyo)\b/i;
// D-311.8: a Bisaya guest gets the English line.
const datesFirstReply = (name: string | null, text: string, followUp: boolean) =>
  datesFirstLine(name, !LOCAL_RE.test(text) || guestLang(text) === 'bisaya' ? 'en' : 'tl', followUp);

// Two turns that need no model (live audit 2026-09-13: the model padded "salamat po" with a
// sales nudge and answered "are you a bot?" with "I ... just like a human host would").
// Closers: thanks, okay, noted, goodbye. Answered in code, warmly. D-300.2 (Lloyd 2026-10-05): no link under a thanks - a
// closer that ends on a link reads as a pitch.
// SPEC-39 3.8 (live 2026-10-04: "Thanks and God bless" got the dates nudge from the model): a blessing or a farewell may follow.
export const THANKS_RE = /^\s*(ok(ay)?|sige|noted|got it|great|nice)?( po)?[,.! ]*(thank(s| you)( so much| very much)?|salamat( po)?( ulit)?|maraming salamat( po)?|ty|tysm)[,.! ]*(po|talaga)?(?:,?\s*(?:and\s+)?(?:god bless|ingat|take care|good ?night)(?: po)?)?[,.! ]*$/i; // "sige po, salamat" went to the model (v57 check)
const CLOSER_ONLY_RE = /^\s*(?:(?:ok(?:ay)?|sige|noted|got it|alright|copy|bye|good ?bye|ingat|see you|talk (?:to you )?later|ttyl|good night|goodnight)(?: po)?(?: na)?[,.! ]*){1,3}$/i;
const BOT_RE = /\b(are you a (bot|robot|an? ai)|is this a bot|bot (ka|po|ba)|ai (po )?ba|robot (ka|po) ba|chatbot|real person|human ba|tao (po )?ba|automated)\b/i;
const pick = (xs: string[]) => xs[Math.floor(Math.random() * xs.length)];
// Voice close-out (protocol 10): three registers, no exclamation words, one or two "po", and the open door offers both
// routes. `lang` is the SETTLED register of the turn. D-311.8 (Lloyd 2026-10-07): a Bisaya or Bislish guest gets English.
type L3 = 'en' | 'tl' | 'bis';
const l3Of = (lang: string): L3 => (lang === 'taglish' ? 'tl' : 'en');
export function closingReply(name: string | null, lang: string, thanks: boolean, lastBotText: string): string {
  const l = l3Of(lang);
  const fresh = (xs: string[]) => { const ys = xs.filter((x) => !lastBotText.includes(x.replace(/^[^.]*\.\s*/, '').slice(0, 40))); return ys.length ? ys : xs; };
  return pick(fresh(closers(name, l, thanks)));
}
// D-173 / D-300.5: the short disclosure, the name inside it; the words are persona.ts's (persona.test.ts gates them).
const botReply = (name: string | null, lang: string) => botLine(name, l3Of(lang));
// Lloyd 2026-09-13: anchor the saving, not the percentage. When the guest names a stay length,
// the standard total, the discounted total and the added value are computed here so the
// numbers are never invented ("5 nights: PHP 8,900 becomes about PHP 8,010, with drinking water").
const peso = (n: number) => 'PHP ' + n.toLocaleString('en-US');
/** The stay length the guest's words name, in nights (a month is 30, a week 7), or null. SPEC-39 4.1 (live 2026-10-04:
 *  "two months" got the generic 28-night line and no total): number words count too. */
function stayNights(text: string): number | null {
  const m = /\b(\d{1,2})\s*(?:nights?|gabi|days?|araw)\b/i.exec(text);
  if (m) return Number(m[1]);
  // D-269 (live 2026-09-27: "If I book for a month, how much?" got a nightly rate and "the total will be shown on our site").
  const w = /\b(a|an|one|two|three|isang|dalawang|tatlong|usa ka|duha ka|tulo ka|\d{1,2})\s*(month|months|buwan|bulan|weeks?|linggo|semana)\b|\bmonth-?long\b/i.exec(text);
  if (!w) return null;
  const k = /^\d+$/.test(w[1] ?? '') ? Number(w[1]) : /^(two|dalawang|duha)/i.test(w[1] ?? '') ? 2 : /^(three|tatlong|tulo)/i.test(w[1] ?? '') ? 3 : 1;
  return (/week|linggo|semana/i.test(w[2] ?? '') ? 7 : 30) * k;
}
/** D-300.4: the stay TOTAL only, for the price objection - no per-night arithmetic, no saving ('' when no length is named). */
export function anchorTotal(text: string): string {
  const n = stayNights(text), card = currentCard();
  if (!n || n < 2 || n > 60) return '';
  return `[Their ${n} nights come to ${peso(n * tierRate(card, n))} at the direct rate - the one figure you may say.] `;
}
export function stayAnchor(text: string, lang = 'english'): string {
  const n = stayNights(text);
  if (!n) return '';
  // SPEC-34: the live card's tier for n nights and its base (the standard every saving is measured from).
  const card = currentCard(), std = card.base, tier = { rate: tierRate(card, n) };
  if (n < 2 || n > 60 || tier.rate >= std) return '';
  const extras = n >= 5 ? ', plus drinking water for the stay and a complimentary mid-stay refresh with fresh linens and towels' : ''; // D-249: the refresh starts at 5 nights, as the site says
  // Order and wording follow pricing research: anchor on the standard rate, adjust to the precise
  // direct rate (precise figures read as calculated and lower), then the per-stay total, then the
  // saving in pesos (rule of 100: absolute over percent when the base is large), then one value-add.
  // SPEC-28 section 1: the quoted wording was English whatever the guest wrote, so a Taglish rate question got an English
  // answer with one "po". A Taglish turn gets the same three facts, same order, in everyday Taglish.
  const q = lang === 'taglish'
    ? [`para sa ${n} nights po, bumababa ang direct rate namin sa ${peso(tier.rate)} per night mula sa standard ${peso(std)}`, `mga ${peso(n * tier.rate)} para sa buong stay imbes na ${peso(n * std)}`, `kaya makakatipid kayo ng mga ${peso(n * (std - tier.rate))}`, n >= 5 ? 'kasama na rin ang drinking water for the stay at complimentary mid-stay refresh with fresh linens and towels' : '']
    : [`for ${n} nights your direct rate comes down to ${peso(tier.rate)} per night from the standard ${peso(std)}`, `about ${peso(n * tier.rate)} for the stay instead of ${peso(n * std)}`, `so you keep about ${peso(n * (std - tier.rate))}`, extras.slice(2)];
  return `[Stay anchor for ${n} nights - say it in THIS order, in one warm paragraph: (1) "${q[0]}", (2) "${q[1]}", (3) "${q[2]}"${q[3] ? `, (4) "${q[3]}"` : ''}. Do not state the percentage; do not use the word "discount" more than once. If their dates are not known, put the question about which dates they are looking at in "ask".] `;
}
/** s73 F2/R2-3: a price asked in words - booking.ts PRICE_RE (how much, magkano, rate, cost, hm...) and the plurals, "total",
 *  "pricing", "presyo", "bayad" ("Hi, what would Oct 19 to 21 cost for 2?" got no figures). */
export const priceAsked = (text: string): boolean => PRICE_RE.test(text) || /\b(rates|prices|pricing|costs?|total|presyo|bayad)\b/i.test(text);
/** s73 F2 (golden first-two-months: "details regarding our booking good for two months" got no figures): a price asked, or a
 *  month-scale stay named, gets the stay figures. Only priceAsked closes on the hold question (R2-8). */
export const rateAsked = (text: string): boolean => priceAsked(text) || (stayNights(text) ?? 0) >= 28;
/** s73 R3-2: a date the guest takes back ("not Oct 19, Oct 20", "hindi Oct 19 to 21") - the negation directly before a date. */
const NEGATED_DATE_RE = /\b(?:not|hindi|dili|instead of)\s+(?:po\s+)?(?:on\s+|sa\s+|ang\s+)?(?=(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*\d|\d)[^,.;]+[,;]?/gi;
/** s73 R3-3: a past stay told about ("last time we stayed Sep 5 to 7") - parseDates would roll it into next year. "noon" is left
 *  out on purpose: "check in 12 noon on Oct 19" is a stay question. */
const NARROW_RE = /\b(just|only|lang|instead|actually|how about|what about)\b/i; // s73 R4-1: the guest narrows the stay to this date
const PAST_STAY_RE = /\b(last (time|year|month)|stayed|dati|niadtong|kaniadto)\b/i;
/** s73 R2-1 / R3: the stay being priced, from the guest's last three messages. The newest dated message wins: two dates are the
 *  stay whatever length word sits beside them ("Oct 19 to 21, 3 days 2 nights" is 2 nights). One date inside a range an older
 *  message gave ("we leave Oct 21 early") is that range; otherwise it takes the length named ("Oct 19, 3 nights"), else one
 *  night. A date taken back or a past stay does not count. null with no future date. */
export function pricedStay(guestTexts: string[], now: Date): { checkin: string; checkout: string } | null {
  const said = guestTexts.slice(-3), today = dayStr(new Date(now.getTime() + 8 * 3_600_000)); // Manila
  // R4-2: a past stay is skipped only when no price is asked ("same as last year po, Oct 19 to 21, how much?" is priced).
  // s74 G1: ...nor one parseDates rolled into next year ("last time we stayed Sep 5 to 7, how much now?"): no stay to price or hold.
  const dates = said.map((t) => PAST_STAY_RE.test(t) && !priceAsked(t) || rolledPastStay(t, now) ? [] : datesOf(t.replace(NEGATED_DATE_RE, ' '), now));
  for (let i = said.length - 1; i >= 0; i--) {
    const d = dates[i];
    if (!d[0] || d[0] < today) continue;
    if (d[1] && d[1] > d[0]) return { checkin: d[0], checkout: d[1] };
    // R4-1: only an incidental date joins the range - a narrowing ("how about just Oct 20?", "only Oct 24, 1 night", "not Oct 19,
    // Oct 20", a price asked for it) is the stay asked for.
    const t = said[i], narrows = priceAsked(t) || t.search(NEGATED_DATE_RE) >= 0 || !!stayNights(t) || NARROW_RE.test(t);
    const range = narrows ? null : dates.slice(0, i).reverse().find((r) => r[1] && r[0] <= d[0] && d[0] <= r[1] && r[0] >= today);
    if (range) return { checkin: range[0], checkout: range[1] };
    const n = stayNights(said[i]) ?? stayNights(said.join(' '));
    return { checkin: d[0], checkout: addDays(d[0], n && n >= 2 && n <= 60 ? n : 1) };
  }
  return null;
}
/** SPEC-34 (D-262) + s73 F1 (golden fu-chat-yes-en: "how much for Oct 19 to 21?" got no figures and the model said PHP 5,073,
 *  three nights, for two): a dated stay gets code's figures (rateLine), promo or not, so the model never does the arithmetic;
 *  with no date, a named length gets stayAnchor. `total` is the stay total said, for the D-270 "already given" check. */
export function priceAnchor(guestTexts: string[], now: Date, lang = 'english'): { text: string; total: number | null } {
  const said = guestTexts.slice(-3), stay = pricedStay(said, now), sq = stay ? quoteTotal(stay.checkin, stay.checkout) : null;
  // s73 R3-4: past 60 nights code quotes nothing (the tiers stop at 60) and neither may the model.
  const long = '[Over 60 nights: quote no total; the host prices long stays.] ';
  if (stay && sq && sq.nights > 60) return { text: long, total: null };
  if (stay && sq)
    return { text: `[Stay figures computed by code for ${dmRange(stay.checkin, stay.checkout)} - say exactly these figures in one warm paragraph: "${rateLine({ checkin: stay.checkin, checkout: stay.checkout, lang: l3Of(lang) } as Flow, now)}" Never mention any other "was" or "usual" price.] `, total: sq.total };
  const n = stayNights(said.join(' '));
  if (!stay && n && n > 60) return { text: long, total: null };
  const text = stayAnchor(said.join(' '), lang);
  return { text, total: text && n ? n * tierRate(currentCard(), n) : null };
}
/** s73 F7 (golden fu-checkout-steps: the steps came without the time): what to do before check-out starts with when. R2-8: only
 *  a question about leaving ("before check out", "check-out steps") - not "check out the steps to book", not a late check-out. */
export const checkoutHint = (text: string): string =>
  /\b(before|bago|prior to|upon)\s+(?:(?:i|we|kami|ako|mo)\s+)?(?:mag-?\s*)?check(?:ing)?[- ]?out\b|\bcheck(?:ing)?[- ]?out\s+(?:steps?|procedures?|process|instructions?|reminders?|rules?|checklist)\b/i.test(text) && !/\b(late|extend|extension|after)\b/i.test(text)
    ? '[Check-out is by 12:00 noon: say the time in your first sentence, then the steps from FACTS.] ' : '';
/** SPEC-39 3.3 (D-300.4): a discount ask or a price objection ("medyo mahal po", "a bit expensive") - the host gets the card.
 *  "hindi naman mahal" / "not expensive at all" says the opposite and is not one. */
export const priceObjection = (text: string): boolean =>
  /\b(discount|discounted|lower price|best price|cheaper|mas mura|promo|may promo)\b/i.test(text) // a discount ask counts whatever else is said
  || (/\b(mahal|expensive|pricey)\b/i.test(text) && !/\b(hindi|not|dili|wala)\b[^.?!]{0,12}\b(mahal|expensive|pricey)/i.test(text));
/** D-300.2 trigger 1: how to book, or the site itself, asked for. */
export const HOW_BOOK_RE = /\b(how (?:do|can|should) (?:i|we) (?:book|reserve)|how to book|paano (?:po )?(?:mag-?book|mag-?reserve|ma-?book)|unsaon (?:pag-?)?book|book(?:ing)? link|(?:your |the |ang |inyong )?(?:site|website|link|page)\b|where (?:do|can) (?:i|we) book|san (?:po )?(?:pwede|puwede) mag-?book)\b/i;
/** D-300.2 (Lloyd 2026-10-05): the site link only as applicable - how to book or the site itself, the home or its photos,
 *  reviews or trust (hesitation is the decision moment, rule 5). A price, parking or Wi-Fi question, a thanks or a dated
 *  message is not a reason for it. Jev's intent counts only when it is sure. */
export function linkTurn(text: string, jev: JevRoute | null, now = new Date()): boolean {
  const sure = (i: string) => !!jev && jev.intent === i && jev.confidence >= 0.8;
  if (HOW_BOOK_RE.test(text) || SEE_RE.test(text) || TRUST_RE.test(text) || sure('trust')) return true;
  return sure('booking') && !parseDates(text, now).length; // a dated "book Oct 20-22" starts the flow instead
}
/** SPEC-39 4.3: the router's intent, told to the model in one line (no new call). Unclear intent: answer what we can - code
 *  asks for the dates. '' when Jev is not sure either way. */
export function intentHint(jev: JevRoute | null): string {
  if (!jev) return '';
  if (jev.intent === 'other' || jev.confidence < 0.6) return `[The guest's intent is unclear. Answer what you can in ONE warm sentence; code asks for their dates.] `;
  return jev.confidence >= 0.8 ? `[Intent read by our router: ${jev.intent} (${JEV_INTENTS[jev.intent] ?? ''}). Answer that first.] ` : '';
}
// Dates the guest has already given, so a later early/late check-in question is answered against
// the calendar instead of "once your dates are set" (live audit 2026-09-13, Oct 10-12 given two turns earlier).
// Explicit dates only: "will decide tomorrow" was collected as a stay date (live 2026-09-13).
const DATES_RE = /\b(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? ?\d{1,2}(?:\s*(?:-|–|to|hanggang)\s*(?:[a-z]+ )?\d{1,2})?|\d{1,2}[\/-]\d{1,2}(?:\s*(?:-|to)\s*\d{1,2}[\/-]\d{1,2})?)\b/gi;
function guestDatesBlock(guestTexts: string[]): string {
  const found = [...new Set(guestTexts.join(' \n ').match(DATES_RE) ?? [])].slice(-3);
  return found.length ? `\n\nGUEST'S DATES SO FAR (from their own messages): ${found.join('; ')}. Treat these as their dates: answer early check-in / late check-out against the CHECKS OUT / CHECKS IN lists for these days, and do not ask for the dates again.` : '';
}
/** K18 (D-182): the stay the guest's own words name, newest message first; a single date is one night. */
function stayFrom(guestTexts: string[], now: Date): { checkin: string; checkout: string } | null {
  const today = dayStr(new Date(now.getTime() + 8 * 3_600_000)); // Manila
  for (const t of [...guestTexts].reverse()) {
    const d = parseDates(t, now);
    if (d[0] && d[0] >= today) return { checkin: d[0], checkout: d[1] && d[1] > d[0] ? d[1] : addDays(d[0], 1) };
  }
  return null;
}

type Turn = { role: 'guest' | 'bot'; text: string; at: string; route?: Record<string, unknown> }; // D-271: route = regex vs Jev, per guest turn (shadow log)
type Thread = { psid: string; guest_name: string | null; human_until: string | null; bot_turns: number; history: Turn[]; last_risk: string | null; booking_flow?: Flow | null; last_mid?: string | null; verified_until?: string | null };
// deno-lint-ignore no-explicit-any
type Db = SupabaseClient<any, 'public', any>;

async function hmacOk(secret: string, body: string, header: string | null): Promise<boolean> {
  if (!secret || !header?.startsWith('sha256=')) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body)));
  const hex = Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('');
  const want = header.slice(7);
  if (hex.length !== want.length) return false;
  let d = 0; for (let i = 0; i < hex.length; i++) d |= hex.charCodeAt(i) ^ want.charCodeAt(i);
  return d === 0;
}

// humanAgent: a host's own reply from a handoff card. Sent with the HUMAN_AGENT tag (Meta feature
// added 2026-09-13) so it still delivers up to 7 days after the guest's last message, not 24 h.
type Chip = { title: string; payload: string };
async function fbSend(psid: string, text: string, humanAgent = false, chips: Chip[] = []): Promise<boolean> {
  const token = env('META_PAGE_TOKEN');
  const post = (payload: unknown) => fetch(`${GRAPH}/${PAGE_ID}/messages?access_token=${token}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  await post({ recipient: { id: psid }, sender_action: 'typing_on' });
  const envelope = humanAgent ? { messaging_type: 'MESSAGE_TAG', tag: 'HUMAN_AGENT' } : { messaging_type: 'RESPONSE' };
  const quick = chips.length ? { quick_replies: chips.map((c) => ({ content_type: 'text', title: c.title, payload: c.payload })) } : {}; // D-281 contact-host button
  const r = await post({ recipient: { id: psid }, ...envelope, message: { text, ...quick } });
  if (r && !r.ok) console.error('fb_send_failed', r.status, (await r.text()).slice(0, 200));
  return !!r?.ok;
}

async function fbName(psid: string): Promise<string | null> {
  const r = await fetch(`${GRAPH}/${psid}?fields=first_name&access_token=${env('META_PAGE_TOKEN')}`, { signal: AbortSignal.timeout(5_000) }).catch(() => null);
  if (!r?.ok) { console.error('fb_name_failed', r?.status ?? 'no_response', r ? (await r.text()).slice(0, 300) : ''); return fbNameFromConversation(psid); }
  const body = await r.json().catch(() => ({})) as { first_name?: string };
  if (body.first_name) return body.first_name;
  console.error('fb_name_empty', JSON.stringify(body).slice(0, 300));
  return fbNameFromConversation(psid);
}

// Fallback (2026-09-13): the User Profile API returned 400 "missing permissions" for real
// guests. The Page's own conversation list carries the participant name under pages_messaging.
async function fbNameFromConversation(psid: string): Promise<string | null> {
  const r = await fetch(`${GRAPH}/${PAGE_ID}/conversations?platform=messenger&user_id=${psid}&fields=participants&access_token=${env('META_PAGE_TOKEN')}`, { signal: AbortSignal.timeout(5_000) }).catch(() => null);
  if (!r?.ok) { console.error('fb_conv_name_failed', r?.status ?? 'no_response', r ? (await r.text()).slice(0, 300) : ''); return null; }
  const j = await r.json().catch(() => ({})) as { data?: Array<{ participants?: { data?: Array<{ id?: string; name?: string }> } }> };
  const p = j.data?.[0]?.participants?.data?.find((x) => String(x.id) === String(psid));
  const first = (p?.name ?? '').trim().split(/\s+/)[0] || null;
  if (!first) console.error('fb_conv_name_empty', JSON.stringify(j).slice(0, 300));
  return first;
}

async function tgOps(text: string): Promise<void> {
  const token = env('TELEGRAM_BOT_TOKEN'), chat = env('TELEGRAM_CHAT_ID');
  if (!token || !chat) return;
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }), signal: AbortSignal.timeout(10_000),
  }).catch(() => {});
}

// Availability is computed here, night by night, and handed to the model as explicit open
// windows. Handing it raw booked ranges made it merge two separate one-night bookings into one
// block and miss the open night between them (live test, 2026-09-12).
const HORIZON_DAYS = 120;
const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; // the one Cascade unit (stay_chains_v1 takes it)
const dayStr = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (iso: string, n: number) => { const d = new Date(iso + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return dayStr(d); };
const pretty = (iso: string) => new Date(iso + 'T00:00:00Z').toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });

async function availabilityBlock(db: Db): Promise<string> {
  const today = dayStr(new Date(Date.now() + 8 * 3_600_000)); // Manila
  const horizonEnd = addDays(today, HORIZON_DAYS);
  const { data, error } = await db.from('calendar_events').select('checkin_date, checkout_date').neq('status', 'cancelled').gte('checkout_date', today).lte('checkin_date', horizonEnd).order('checkin_date').limit(200);
  // Session 30: supabase-js does not throw. A failed read used to look like an empty calendar, so the model was
  // told every night was open. Now it is told the calendar is unknown and must not state availability.
  if (error) {
    console.error('calendar_read_failed', 'availabilityBlock', String(error.message ?? error).slice(0, 200));
    return [
      `TODAY (Manila): ${today}.`,
      `AVAILABILITY: the calendar could not be read just now. Do NOT say that any date is open, available, booked or taken. Say warmly that we will check those dates and confirm shortly, then answer everything else as usual. Do not promise early check-in or late check-out.`,
    ].join('\n');
  }
  const bookedNights = new Set<string>();
  const checkins = new Set<string>(), checkouts = new Set<string>();
  for (const r of data ?? []) {
    checkins.add(r.checkin_date); checkouts.add(r.checkout_date);
    for (let d = r.checkin_date; d < r.checkout_date; d = addDays(d, 1)) bookedNights.add(d);
  }
  // D-290: a day one guest checks out and in again (a chained stay) is neither "another guest checks out" nor "checks in":
  // nobody turns the unit over. A missing stay_chains_v1 gives [] and the lists stay as they were.
  dropJunctionDays(await fetchChains(db, PROPERTY_ID, today, horizonEnd), checkins, checkouts);

  // Walk the horizon and collect runs of open nights as check-in -> check-out windows. SPEC-14: the walk itself
  // lives in booking.ts, so the model's block and the code's "nearest open dates" line can never disagree.
  const booked: string[] = [];
  for (let d = today; d < horizonEnd; d = addDays(d, 1)) if (bookedNights.has(d)) booked.push(pretty(d));
  const windows = openWindows(bookedNights, today, horizonEnd).map((w) => w.open_ended
    ? `${pretty(w.start)} onwards (open through at least ${pretty(w.end)})`
    : `${pretty(w.start)} to ${pretty(w.end)} (${w.nights} night${w.nights > 1 ? 's' : ''})`);

  return [
    `TODAY (Manila): ${today}. Dates below are ${new Date(today).getUTCFullYear()} unless stated.`,
    `A stay needs EVERY night from check-in through the night before check-out to be open. The check-out day itself can be a new guest's check-in day.`,
    `OPEN WINDOWS (check-in to check-out): ${windows.join('; ') || 'none in the next ' + HORIZON_DAYS + ' days'}`,
    `BOOKED NIGHTS: ${booked.join(', ') || 'none'}`,
    `If a requested range includes a booked night, say exactly which nights are taken and which are open, then offer the open part or the nearest window. For dates beyond ${pretty(horizonEnd)}, say the host will confirm.`,
    // Turnover safeguard (live test 2026-09-12: a free 1 PM check-out was promised with no dates known).
    `ANOTHER GUEST CHECKS OUT ON: ${[...checkouts].filter((d) => d >= today).sort().map(pretty).join(', ') || 'none'} - on these days never promise an early check-in time (D-311): say we'll be happy to accommodate 12:00 NN or 1:00 PM if the unit is already fully prepared and ready by then, that we'll do our best to have everything ready ahead of the standard 2:00 PM check-in, and that we'll keep them posted once we can confirm the earliest time. Never "complimentary", never a time confirmed.`,
    `ANOTHER GUEST CHECKS IN ON: ${[...checkins].filter((d) => d >= today).sort().map(pretty).join(', ') || 'none'} - late check-out is NOT possible on these days; check-out stays at 12 noon.`,
    `Offer early check-in or late check-out ONLY when the guest's dates are known and the day in question is on neither list. Otherwise say you will gladly arrange it once their dates are set and the calendar allows.`,
  ].join('\n');
}

/** D-286: `reply` is the model's ANSWER (compose() writes the rest); `ask` its one question back, or null. */
type Draft = { reply: string; ask?: string | null; uncertain: boolean; guest_name?: string | null };

// Landmarks come from the same tables that feed the guest guide's maps (pois, dining_spots), so a
// distance the bot quotes is one Lloyd has already published. Anything not listed -> host confirms.
let landmarksCache: { at: number; text: string } | null = null;
let dbForLandmarks: Db | null = null; // set per request in Deno.serve; draft() has no db parameter
async function landmarksBlock(db: Db): Promise<string> {
  if (landmarksCache && Date.now() - landmarksCache.at < 10 * 60_000) return landmarksCache.text;
  const [p, d] = await Promise.all([
    db.from('pois').select('name, category, distance_km, distance_text, note').eq('is_active', true).order('sort_order').limit(60),
    db.from('dining_spots').select('name, cuisine, distance_km, distance_text, must_try').eq('is_active', true).order('sort_order').limit(60),
  ]);
  // ponytail: travel time derived as km x 2..3 min (GenSan city traffic, matches the hand-written
  // 3.7 km ~10 min and 15 km ~25-35 min) unless the row's note already states minutes; set the note
  // per row to override.
  const mins = (r: any) => {
    const km = Number(r.distance_km);
    if (!(km > 0.5) || /\bmin\b/i.test(r.note ?? '')) return '';
    return `, about ${Math.max(2, Math.round(km * 2))}-${Math.round(km * 3)} min by car or Grab`;
  };
  const line = (r: any, kind: string) => `- ${r.name} (${kind}${r.cuisine ? ': ' + r.cuisine : ''}): ${r.distance_km != null ? r.distance_km + ' km' : ''}${r.distance_text ? ', ' + r.distance_text : ''}${mins(r)}${r.must_try ? '; must try ' + r.must_try : ''}${r.note ? '; ' + r.note : ''}`;
  const rows = [...(p.data ?? []).map((r) => line(r, r.category ?? 'place')), ...(d.data ?? []).map((r) => line(r, 'dining'))];
  const text = rows.length
    ? `Known places near the unit (distance from the unit; travel time depends on traffic and how the guest travels):\n${rows.join('\n')}\nIf a place the guest names is not in this list, do not estimate - say the host will confirm the distance personally.`
    : 'No landmark list is loaded; say the host will confirm distances personally.';
  landmarksCache = { at: Date.now(), text };
  return text;
}

// Follow-up turns get a compact prompt: the 13 reference replies (all English, all first-contact
// shaped) are dropped, which halves the tokens and removes the strongest pull toward English
// brochure answers. First contact keeps the full voice with exemplars.
// The OUTPUT contract sits after the exemplars, so it must be re-attached or the model stops
// returning {reply, uncertain} and every follow-up degrades to a handoff (live, 2026-09-13 10:42Z).
// Session 30 ROOT CAUSE of "it always reverts to blunt": this used VOICE.split('REFERENCE REPLIES')[0], and those
// words also occur in VOICE's FIRST paragraph ("The REFERENCE REPLIES below are Lloyd's approved wording"), so since
// 2026-09-13 every follow-up ran on 1,751 of ~30,000 characters: no Cassy persona, none of the three native protocols,
// no voice rules. The cut is now made at the HEADING line, in facts.ts, and voice.test.ts asserts what it keeps.
// SPEC-34: VOICE and FACTS are refilled from the rate card loaded for this turn (a promotion block when one is live).
// S74 cache: static blocks first (voice, FACTS, contract), per-turn ones last (name, landmarks, availability), so Gemini's implicit
// prefix cache hits across turns (OpenRouter docs: keep the start of the message array stable, push variation to the end).
const systemPrompt = (thread: Thread, availability: string, landmarks = '', compact = false, contract = OUTPUT_ANSWER) => {
  const card = currentCard(), voice = voiceFor(card);
  return `${compact ? voiceCompact(voice) : voice}\n\nFACTS\n${factsFor(card)}\n\n${contract}\n\nGUEST FIRST NAME: ${thread.guest_name ?? 'unknown'}\n\nLANDMARKS\n${landmarks}\n\nAVAILABILITY\n${availability}`;
};

// Language of the guest's message, decided in code so the instruction can ride on the user turn itself, where small
// models honour it: guestLang() in booking.ts, the one detector (SPEC-28 section 4).
const LANG_HINT = {
  taglish: '[Reply in natural conversational Taglish with "po" - everyday Tagalog mixed with English the way a GenSan host texts, not formal Tagalog.] ',
  // D-311.8 (Lloyd 2026-10-07): the s74 Bisaya replies mixed English price paragraphs with Bisaya, and one was full Bisaya.
  bisaya: '[The guest wrote Bisaya. Reply in warm, natural English with contractions - Bisaya and Bislish guests get English replies (D-311). No "po", no Tagalog or Bisaya sentences.] ',
  english_po: '[The guest wrote English with a courtesy "po". Reply in warm English; one "po" is welcome, no Tagalog sentences.] ',
  english: '',
};

// Address guard (Lloyd, 2026-09-13): the block and lot are shared by the host after confirmation,
// never by the bot. The fact sheet no longer carries them; this catches a model that recalls them.
const ADDRESS_RE = /\b(block|blk\.?)\s*47\b,?\s*|\blot\s*39\b,?\s*/gi;
function redactAddress(reply: string): string {
  if (!ADDRESS_RE.test(reply)) return reply;
  console.error('address_redacted', reply.slice(0, 160));
  return reply.replace(ADDRESS_RE, '').replace(/\s{2,}/g, ' ');
}
// Rule of thumb 1-2 (Lloyd, 2026-09-11): positive frame, no negative words. Checked in code; one
// retry with a hard instruction, then the retry is sent as is and logged (safety lines and the
// fixed handoff lines never pass through here).
const NEGATIVE_RE = /\b(unfortunately|sorry|cannot|can'?t|unable to|(don'?t|do not|doesn'?t|does not) (have|offer|allow|accept|provide)|not (available|allowed|possible|permitted)|no longer|hindi (po )?(pwede|puwede|available)|wala (po )?(kami|kaming)|bawal)\b/i;
// Messenger renders markdown literally ("*   Robinsons", "**2:00 PM**" seen live 2026-09-13).
/** D1 (audit 3bd0e1b): a model sentence that forwards the request or names the host - compose() adds the one host line. */
export const dropForward = (a: string): string => a.split('\n').map((l) => sentencesOf(l).filter((x) => !/\bour host\b|\bforward(?:ed|ing)?\s+(?:it|this|that|your|the)\b|\bpass(?:ed)? (?:it|this|your)\b|\bshared your (?:message|request)\b/i.test(x)).join('').trim()).join('\n').replace(/\n{3,}/g, '\n\n').trim();
const plainText = (s: string) => s.replace(/^[ \t]*[*•-][ \t]+/gm, '').replace(/\*\*([^*\n]+)\*\*/g, '$1');

function draftFrom(raw: string, who: string): Draft {
  const parsed = parseDraftJson(raw);
  const reply = String(parsed.answer ?? parsed.reply ?? '').trim().slice(0, 1800); // D-286: the answer; an old-shape reply is read as the answer
  const ask = typeof parsed.ask === 'string' && parsed.ask.trim() ? parsed.ask.trim().slice(0, 300) : null;
  if (!reply) throw new Error(`${who}_empty`);
  // Change 2 (D-097): the name the guest states in the conversation, when Graph gives us none.
  // One or two capitalised words, letters only, so "unknown", "Ma'am" or a sentence never sticks.
  const n = typeof parsed.guest_name === 'string' ? parsed.guest_name.trim() : '';
  const guest_name = /^\p{Lu}[\p{L}'-]{1,20}( \p{Lu}[\p{L}'-]{1,20})?$/u.test(n) && !/^(unknown|guest|sir|ma'?am|maam|none|null)$/i.test(n) ? n.split(' ')[0] : null;
  return { reply, ask, uncertain: parsed.uncertain === true, guest_name };
}

// The landmark list is ~1.2k tokens; send it only when the turn is about a place, a distance or
// getting around (2026-09-13 token audit). Anything else answers from FACTS.
const PLACE_RE = /\b(far|near|distance|km|minutes?|mall|airport|hospital|clinic|pharmacy|resort|pool|beach|cafe|coffee|restaurant|food|eat|kain|dining|market|atm|bank|gas|store|church|school|transpo|grab|taxi|tricycle|drive|route|direction|location|asa|saan|malapit|layo|duol|lugar|place|around|nearby|recommend)\b/i;
async function draft(thread: Thread, question: string, availability: string, tier: 'full' | 'lite' = 'full', compact = false, contract = OUTPUT_ANSWER): Promise<Draft> {
  const landmarks = PLACE_RE.test(question) ? await landmarksBlock(dbForLandmarks!).catch(() => '') : 'Not loaded for this turn; for a place or distance not in FACTS say the host will confirm.';
  const ask = (plain = false) => chatJson({
    system: systemPrompt(thread, availability, landmarks, compact, contract),
    history: thread.history.slice(-HISTORY_KEEP).map((h) => ({ role: h.role === 'bot' ? 'assistant' as const : 'user' as const, text: h.text })),
    question: plain ? `[Reply as plain text only, no JSON, no code fences.] ${question}` : question, title: 'Cascade Concierge', tier, plain,
  });
  return await draftOrPlain(ask, (raw) => draftFrom(raw, 'model'));
}
/** Live 2026-09-25: unreadable JSON handed three guests to the host in a minute - one fresh call before giving up.
 *  SPEC-32 s5 (F12): after the second, one plain-text call wrapped as the reply; a parse failure alone never hands off. */
export async function draftOrPlain(ask: (plain?: boolean) => Promise<string>, parse: (raw: string) => Draft): Promise<Draft> {
  const raw = await ask();
  try { return parse(raw); } catch (e) {
    if (!(e instanceof SyntaxError)) throw e;
    console.warn('draft_json_retry', String(e).slice(0, 120), raw.slice(0, 160));
    const again = await ask();
    try { return parse(again); } catch (e2) {
      if (!(e2 instanceof SyntaxError)) throw e2;
      const text = (await ask(true)).replace(/^```\w*\s*|\s*```$/g, '').trim();
      if (!text) throw e2;
      console.warn('draft_plain_fallback', text.slice(0, 160));
      return { reply: text.slice(0, 1800), uncertain: false };
    }
  }
}

// ---- Host handoff with one-tap replies (2026-09-12) --------------------------------------
// When the bot hands a guest to the host, ops gets a Telegram card: the guest's message, two
// suggested replies as buttons, and "Write my own". A tap (or a reply to the card) is sent to
// the guest on Messenger signed with the responder's name. Button clicks reach the Telegram
// webhook owned by telegram-expense, which forwards `ch:` callbacks and `#CH-` replies here.
const OPS_NAMES: Record<string, string> = Object.fromEntries(
  env('CASCADE_OPS_NAMES').split(',').map((p) => p.trim().split(':')).filter((p) => p.length === 2) as [string, string][],
); // e.g. "123456:Lloyd,234567:Marifel,345678:Honey"
const whoIs = (from: { id?: number | string; first_name?: string } | undefined) =>
  OPS_NAMES[String(from?.id ?? '')] ?? from?.first_name ?? 'Cascade host';

async function tgCall(method: string, body: Record<string, unknown>): Promise<any> {
  const token = env('TELEGRAM_BOT_TOKEN'); if (!token) return null;
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  return r ? await r.json().catch(() => null) : null;
}

// Two candidate replies for the host, in the concierge voice. Rides the normal draft() path so it
// inherits the provider fallback; the options come back joined by a separator line.
/** D-286: the host's two options stay whole messages the host edits before sending, so they keep the reply contract. */
const OPTIONS_CONTRACT = `OUTPUT: JSON only, {"reply": string, "uncertain": boolean, "guest_name": null}. Keep the blank lines between paragraphs inside the reply string.`;
async function suggestOptions(thread: Thread, text: string, availability: string): Promise<string[]> {
  const ask = `${stayAnchor(text)}The guest just wrote: "${text}". Our host will answer this personally. Draft exactly TWO alternative replies the host could send - one gently declining or holding the line, one accommodating if we can - each complete, in our voice, 40-90 words, no link. Name a rate, tier or promotion only in FACTS' own words and figures; never call it special, exclusive or a deal (a 5-night tier was called "a special rate", 2026-09-28). Return them in "reply" separated by a line containing only ---. Set uncertain to false.`;
  try {
    const out = await draft(thread, ask, availability, 'lite', true, OPTIONS_CONTRACT); // compact: 9.6k -> ~5.8k input tokens (llm_usage, 2026-09-13)
    const parts = out.reply.split(/\n\s*---\s*\n/).map((s) => s.trim()).filter(Boolean);
    for (const o of parts.slice(0, 2)) { const lint = lintReply(o, text); if (lint.length) console.warn('voice_lint', JSON.stringify({ source: 'host_option', psid: thread.psid, lint })); } // 2026-09-24
    return parts.slice(0, 2);
  } catch (e) { console.error('suggest_options_failed', String(e).slice(0, 200)); return []; }
}

// What this guest is already waiting on from the host, so the bot can answer other questions
// without re-opening the same request or pretending it never happened.
async function pendingBlock(db: Db, psid: string): Promise<string> {
  const { data } = await db.from('concierge_handoffs').select('risk, guest_text, created_at').eq('psid', psid).eq('status', 'open').order('created_at', { ascending: false }).limit(5);
  if (!data?.length) return '';
  const lines = data.map((h) => `- ${h.risk}: "${String(h.guest_text).slice(0, 160)}"`);
  return `\n\nPENDING WITH THE HOST (already passed along; the host will answer these personally):\n${lines.join('\n')}\nKeep answering everything else normally. If the guest asks about a pending item again, say warmly that the host is reviewing it and will reply personally - do not answer it yourself and do not promise an outcome.`;
}

/** Session 58 (live lockout 2026-09-28): the host-owned matters this guest has open from the last 24 h, newest first. */
const HOST_OWNED: RiskCode[] = ['access', 'safety', 'priority', 'complaint', 'payment', 'refund', 'cancellation'];
async function openHostRisks(db: Db, psid: string, now: Date): Promise<{ risk: RiskCode; at: number }[]> {
  const { data } = await db.from('concierge_handoffs').select('risk, created_at').eq('psid', psid).eq('status', 'open')
    .gte('created_at', new Date(now.getTime() - HUMAN_HOLD_MS).toISOString()).order('created_at', { ascending: false }).limit(10);
  return ((data ?? []) as { risk: RiskCode; created_at: string }[]).filter((h) => HOST_OWNED.includes(h.risk)).map((h) => ({ risk: h.risk, at: Date.parse(h.created_at) }));
}

async function openHandoff(db: Db, thread: Thread, text: string, risk: RiskCode, link: string, note = '', anyWording = false): Promise<void> {
  const chat = env('TELEGRAM_CHAT_ID'); if (!chat) return;
  // A repeat of the SAME ask within 24 h nudges nobody twice. It used to be one open card per
  // guest per risk with no age limit: two stale policy cards from the day before silently
  // swallowed a dog request and a price proposal (live audit 2026-09-13) - the host never saw them.
  // SPEC-31 s2: after the QR every payment claim is the same ask, whatever its wording - one card per 24 h.
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const { data: dup } = await db.from('concierge_handoffs').select('id, guest_text').eq('psid', thread.psid).eq('risk', risk).eq('status', 'open').gte('created_at', new Date(Date.now() - HUMAN_HOLD_MS).toISOString()).order('created_at', { ascending: true }).limit(10);
  if ((dup ?? []).some((d: any) => anyWording || norm(String(d.guest_text)) === norm(text))) return;
  // Session 58 (DESIGN-guest-case-catalogue section 4): a follow-up to an open matter says which card it belongs to and
  // skips the two model options (one model call per follow-up, and the host already has the first card).
  const firstOpen: string | null = (dup ?? [])[0]?.id ? String((dup as any[])[0].id).slice(0, 8) : null;
  const options = firstOpen ? [] : await suggestOptions(thread, text, await availabilityBlock(db));
  const { data: row } = await db.from('concierge_handoffs').insert({ psid: thread.psid, guest_name: thread.guest_name, guest_text: text, risk, options }).select('id').single();
  const id: string = row?.id ?? ''; if (!id) return;
  const short = id.slice(0, 8);
  // Something is wrong with the unit (or the guest is unsafe): make it a work order too. The
  // handoff card is the alert; the row is what Today and the readiness check read.
  let woLine = '';
  if (risk === 'complaint' || risk === 'safety') {
    const wo = await raiseWorkOrder(db, {
      sourceKind: 'guest_report', sourceRef: `concierge_handoff:${id}`, title: text.slice(0, 200),
      detail: `Messenger ${risk} from ${thread.guest_name ?? thread.psid} (#CH-${short})`, priority: risk === 'safety' ? 'urgent' : 'high',
    });
    if (wo?.id) woLine = `🔧 Work order #${wo.id.slice(0, 8)} ${wo.created ? 'raised' : 'already open'}${wo.blocks_arrival ? ' — blocks the next arrival until closed' : ''}`;
  }
  // Session 58: a lockout or a safety report is an alert, not a guest note - it must stand out in OPS at night.
  // G1 (live 2026-09-28: "Sean" was Allyssa, at the door of Joseph Ewing's Airbnb stay): for a host-owned matter the card
  // shows the Manila time, the stay on the calendar today, the name the guest gave, and their earlier turns, so the host
  // matches a person to a stay in one glance. The bot never verifies identity; the host does.
  const nowMs = Date.now();
  const hhmm = new Date(nowMs).toLocaleTimeString('en-PH', { timeZone: 'Asia/Manila', hour: 'numeric', minute: '2-digit' });
  let context: string[] = [];
  if (HOST_OWNED.includes(risk)) {
    const today = new Date(nowMs + 8 * 3_600_000).toISOString().slice(0, 10);
    const { data: stays } = await db.from('calendar_events').select('guest_name, raw_summary, checkin_date, checkout_date, source')
      .eq('status', 'confirmed').lte('checkin_date', today).gte('checkout_date', today).limit(6);
    const earlier = thread.history.filter((h) => h.role === 'guest').slice(-3).map((h) => h.text);
    const said = [text, ...earlier].map(statedName).find(Boolean);
    context = [...stayLines((stays ?? []) as StayRow[], today), ...(said ? [`Says their name is: ${said}`] : []),
      ...(earlier.length ? ['Earlier from them:', ...earlier.reverse().map((t) => `· ${t.slice(0, 160)}`)] : [])];
  }
  const body = withHeader(risk === 'access' || risk === 'safety' ? 'alert' : 'guest', `handoff · ${risk} · ${hhmm}`, [
    firstOpen ? `➕ Follow-up to #CH-${firstOpen} (${risk})` : `🛎 Guest needs the host (${risk})`,
    `Guest: ${thread.guest_name ?? thread.psid} (Messenger account)`,
    `> ${text.slice(0, 400)}`,
    ...context,
    ...(woLine ? [woLine] : []),
    ...(note ? [`⚠️ ${note}`] : []), // D-227: why the bot stepped aside, when it is something the host can fix
    '',
    ...options.map((o, i) => `Option ${i + 1}:\n${o}\n`),
    `Tap an option to send it to the guest, or reply to this message to write your own. #CH-${short}`,
    link,
  ].join('\n'));
  const keyboard = [
    options.map((_, i) => ({ text: `Send option ${i + 1}`, callback_data: `ch:${short}:${i + 1}` })),
    [{ text: '✍️ Write my own', callback_data: `ch:${short}:own` }],
  ].filter((r) => r.length);
  // Lloyd 2026-10-02: OPS (cleaners present) reads the card with amounts and the payment number hidden; the options stored in
  // concierge_handoffs, and so what a tap sends the guest, are whole. Finance gets the full card when anything was hidden.
  const opsBody = maskMoney(body);
  const sent = await tgCall('sendMessage', { chat_id: chat, text: opsBody, disable_web_page_preview: true, reply_markup: { inline_keyboard: keyboard } });
  const fin = env('TELEGRAM_FINANCE_CHAT_ID');
  if (fin && fin !== chat && opsBody !== body) await tgCall('sendMessage', { chat_id: fin, text: `${body}\n\n(Full text for Finance. The OPS card hides amounts and the payment number; answer from the OPS card.)`, disable_web_page_preview: true });
  if (sent?.result?.message_id) await db.from('concierge_handoffs').update({ tg_message_id: sent.result.message_id }).eq('id', id);
  // Session 58 (Lloyd 2026-09-28: "notification specially regarding urgent guest concerns ... both in email and telegram"):
  // the first card of an access or safety matter also reaches the Finance group and the host inbox, so a
  // lockout at night reaches whoever is awake. A follow-up (the same risk already open) stays on the OPS card.
  // Live test 2026-09-28 11:42Z: awaiting the relay (it answered after 20 s, the e-mail did arrive) held the webhook past
  // Meta's timeout, Meta re-delivered the message and the guest got the access line twice. The alert runs after the reply.
  if (URGENT_RISKS.includes(risk) && !(dup ?? []).length) {
    const work = urgentAlert(db, thread, text, risk, short, link).catch((e) => console.error('urgent_alert_failed', String(e).slice(0, 200)));
    const edge = (globalThis as unknown as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
    if (edge?.waitUntil) edge.waitUntil(work);
  }
}

// Lloyd 2026-09-28: urgent only - a lockout or a safety report. Complaints (towels, wifi, noise) stay on the OPS card, so the
// inbox is never flooded; one alert per matter, follow-ups never e-mail.
/** Session 59: one priority-help turn. Verified (verify_booking + the stay is on today) -> host card with the urgent alert;
 *  not matched -> ask once more, then forward as an ordinary card with the phone route. After an unmatched ask the next
 *  24 h skip verification, so the check cannot be guessed by restarting from the menu.
 *  ponytail: history scan for the 24 h cap; a counter column if someone is ever seen guessing. */
async function priorityTurn(db: Db, thread: Thread, text: string, entry: PriorityEntry | null, answer: { date: string | null; initial: string | null } | null, asked: number, link: string, fx: Effects, now: Date, mid?: string): Promise<void> {
  const prev = thread.history.filter((h) => h.role === 'guest').slice(-1)[0]?.text ?? '';
  const lang = l3Of(guestLang(entry ? prev : (text || prev))); // a tap's English label is not the guest's register
  const q = entry?.kind === 'verify' ? { date: entry.date, initial: entry.initial } : answer;
  const tries = entry?.kind === 'verify' ? 1 : asked;
  const blocked = unmatchedRecently(thread, now);
  let reply: string, route: Record<string, unknown> = {};
  if (!q) { reply = priorityAsk(lang); route = { priority: 1 }; }
  else {
    const v = !blocked ? await verifyStay(db, thread, q, now) : null;
    if (v) {
      await fx.handoff(db, thread, `Priority help: ${v!.full_name ?? 'guest'} (booking name matched), staying ${v!.checkin_date} to ${v!.checkout_date}. Their next message says what is wrong.`, 'priority', link, '', true);
      reply = priorityVerified(v!.first_name ?? null, lang); route = { priority: 'verified' };
    } else if (!blocked && tries < 2) { reply = priorityRetry(lang); route = { priority: tries + 1 }; }
    else {
      await fx.handoff(db, thread, `Priority help asked, stay not matched (check-in ${q.date ?? '?'}, initial ${q.initial ?? '?'})${text ? `: ${text}` : ''}`, 'uncertain', link, 'Could not match the stay - check who this is before sharing anything.', true);
      reply = priorityUnmatched(lang); route = { priority: 'unmatched' };
    }
  }
  await fx.send(thread.psid, reply);
  console.log('priority_turn', JSON.stringify({ psid: thread.psid.slice(-6), entry: entry?.kind ?? null, outcome: route.priority }));
  await saveSideTurn(db, thread, text || '[priority help]', text === CONTACT_CHIP.title ? 'chip' : entry ? 'menu' : 'typed', reply, route, now, mid);
}

/** A turn answered outside the main path (priority help, the house check): the guest's words, our reply, the thread. */
async function saveSideTurn(db: Db, thread: Thread, said: string, src: string, reply: string, route: Record<string, unknown>, now: Date, mid?: string): Promise<void> {
  const at = now.toISOString();
  await db.from('concierge_threads').upsert({
    psid: thread.psid, guest_name: thread.guest_name, human_until: thread.human_until, bot_turns: thread.bot_turns,
    history: [...thread.history, { role: 'guest', text: said, at, route: { src } }, { role: 'bot', text: reply, at, route }].slice(-HISTORY_KEEP * 2),
    last_risk: 'priority', updated_at: at, booking_flow: thread.booking_flow ?? null, last_mid: mid ?? thread.last_mid ?? null,
    ...(thread.verified_until !== undefined ? { verified_until: thread.verified_until } : {}),
  });
}

/** After an unmatched stay check, 24 h without another, so the check cannot be guessed by starting over. */
const unmatchedRecently = (thread: Thread, now: Date) =>
  thread.history.some((h) => h.role === 'bot' && h.route?.priority === 'unmatched' && now.getTime() - Date.parse(h.at) < 24 * 3_600_000);

/** D-282: the welcome guide's check, factored out of priorityTurn so the house path verifies WITHOUT the host card and
 *  urgent alert: verify_booking(check-in date, initial) AND the stay is on today. A match opens guest-tier house facts on
 *  this thread through check-out (concierge_threads.verified_until). */
async function verifyStay(db: Db, thread: Thread, q: { date: string | null; initial: string | null }, now: Date): Promise<VerifyResult | null> {
  if (!q.date || !q.initial) return null;
  const v = (await db.rpc('verify_booking', { p_checkin_date: q.date, p_initial: q.initial })).data as VerifyResult | null;
  if (!stayIsCurrent(v, now)) return null;
  thread.verified_until = v!.checkout_date!;
  return v;
}

/** D-282: the house ask was answered but the stay did not match - the priority retry once, then the unmatched path (host
 *  card, phone route). Never the urgent alert: this is a how-to question. */
async function houseUnmatched(db: Db, thread: Thread, text: string, tries: number, question: string, link: string, fx: Effects, now: Date, mid?: string): Promise<void> {
  const lang = l3Of(guestLang(question || text));
  let reply: string, route: Record<string, unknown>;
  if (tries < 2 && !unmatchedRecently(thread, now)) { reply = priorityRetry(lang); route = { house: tries + 1, q: question }; }
  else {
    await fx.handoff(db, thread, `Asked "${question.slice(0, 200)}" (a guests-only detail); the stay did not match: ${text}`, 'uncertain', link, 'Could not match the stay - check who this is before sharing anything.', true);
    reply = priorityUnmatched(lang); route = { priority: 'unmatched' };
  }
  await fx.send(thread.psid, reply);
  console.log('house_verify', JSON.stringify({ psid: thread.psid.slice(-6), outcome: route.house ?? route.priority }));
  await saveSideTurn(db, thread, text, 'typed', reply, route, now, mid);
}

const URGENT_RISKS: RiskCode[] = ['access', 'safety', 'priority'];
const URGENT_WHAT: Partial<Record<RiskCode, string>> = {
  access: 'cannot get into the unit (door, code or key)', safety: 'reported a safety problem',
  priority: 'is staying now and asked for priority help (stay verified)',
};
/** Telegram notices are written for people: what happened and who must act first, the ids last. */
async function urgentAlert(db: Db, thread: Thread, text: string, risk: RiskCode, short: string, link: string): Promise<void> {
  const who = thread.guest_name ?? 'A Messenger guest';
  const at = new Date().toLocaleString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  const lines = [
    `${who} ${URGENT_WHAT[risk]}. The host needs to act now.`,
    `They wrote: "${text.slice(0, 400)}"`,
    `Answer from the OPS card (tap an option or reply to it), or in the page inbox. ${link}`,
    `Sent by Cassy at ${at}, Manila time. Ref #CH-${short}`,
  ].join('\n\n');
  const tasks: Promise<unknown>[] = [];
  const fin = env('TELEGRAM_FINANCE_CHAT_ID');
  if (fin) tasks.push(tgCall('sendMessage', { chat_id: fin, text: withHeader('alert', `guest ${risk}`, lines), disable_web_page_preview: true }));
  const url = env('EMAIL_RELAY_URL'), token = env('EMAIL_RELAY_TOKEN');
  if (url && token) {
    const { data } = await db.from('app_settings').select('value').eq('key', 'email_recipients').maybeSingle();
    const to = String((data as { value?: unknown } | null)?.value ?? '').split(',')[0].trim() || 'cascadereservations@gmail.com';
    tasks.push(fetch(url, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(45_000),
      body: JSON.stringify({ action: 'guestMessage', token, guest_email: to, guest_name: 'Cascade host', subject: `URGENT: ${who} ${URGENT_WHAT[risk]}`, message: lines }),
    }).then(async (r) => { if (!r.ok) throw new Error(`relay ${r.status}`); return r.text(); }));
  }
  const res = await Promise.allSettled(tasks);
  console.log('urgent_alert', JSON.stringify({ risk, short, telegram: !!fin, email: !!(url && token), failed: res.filter((r) => r.status === 'rejected').map((r) => String((r as PromiseRejectedResult).reason).slice(0, 80)) }));
}

// `like` on a uuid column is a Postgres error (uuid ~~ text), so "Option not found" on every tap
// (live 2026-09-12). Open cards are few: fetch them and match the 8-char prefix here.
async function openHandoffByShort(db: Db, short: string): Promise<any | null> {
  const { data } = await db.from('concierge_handoffs').select('*').eq('status', 'open').order('created_at', { ascending: false }).limit(50);
  return (data ?? []).find((h: any) => String(h.id).startsWith(short)) ?? null;
}

export async function sendHostReply(db: Db, short: string, text: string, from: any, cbId?: string): Promise<void> {
  const h = await openHandoffByShort(db, short);
  if (!h) { if (cbId) await tgCall('answerCallbackQuery', { callback_query_id: cbId, text: 'Already handled.' }); return; }
  const name = whoIs(from);
  const final = `${text.trim()}\n\n— ${name}, Cascade Hideaway`;
  const now = new Date().toISOString();
  // s74 G1: claim BEFORE the send (host-reply's pattern): two taps, or a tap and a typed reply, read the same open row and both
  // sent. open -> sent is one atomic update; zero rows back means the other run got there first.
  const { data: won, error: claimErr } = await db.from('concierge_handoffs')
    .update({ status: 'sent', sent_text: final, resolved_by: name, resolved_at: now }).eq('id', h.id).eq('status', 'open').select('id');
  if (claimErr || (won?.length ?? 0) !== 1) { if (cbId) await tgCall('answerCallbackQuery', { callback_query_id: cbId, text: 'Already handled.' }); return; }
  // SPEC-17 (D-212): the handoff stays open and the card says so when Messenger did not accept the reply.
  // Before this the card showed a tick and the row closed while the guest had received nothing.
  if (!(await fbSend(h.psid, final, true))) {
    await db.from('concierge_handoffs').update({ status: 'open', sent_text: null, resolved_by: null, resolved_at: null }).eq('id', h.id).eq('sent_text', final); // only the row this call claimed
    if (cbId) await tgCall('answerCallbackQuery', { callback_query_id: cbId, text: 'Messenger refused the send. Nothing was sent.' });
    if (h.tg_message_id) await tgCall('editMessageText', { chat_id: env('TELEGRAM_CHAT_ID'), message_id: h.tg_message_id, text: maskMoney(`\u26a0\ufe0f Messenger refused the reply to ${h.guest_name ?? h.psid}, so nothing was sent and this is still open. Tap again in a minute.\n\nGuest wrote:\n> ${String(h.guest_text).slice(0, 300)}`) });
    return;
  }
  const { data: t } = await db.from('concierge_threads').select('history, human_until').eq('psid', h.psid).maybeSingle();
  // D-317: a person just replied from the Telegram card - Cassy stays quiet on this chat from now on.
  await db.from('concierge_threads').upsert({ psid: h.psid, history: [...(t?.history ?? []), { role: 'bot', text: final, at: now }].slice(-HISTORY_KEEP * 2), human_until: laterOf(t?.human_until, Date.parse(now) + HOST_HOLD_MS), updated_at: now });
  if (cbId) await tgCall('answerCallbackQuery', { callback_query_id: cbId, text: `Sent as ${name}` });
  if (h.tg_message_id) await tgCall('editMessageText', { chat_id: env('TELEGRAM_CHAT_ID'), message_id: h.tg_message_id, text: maskMoney(`✅ ${name} replied to ${h.guest_name ?? h.psid}:\n${text.trim().slice(0, 600)}\n\nGuest wrote:\n> ${String(h.guest_text).slice(0, 300)}`) });
}

// Telegram updates forwarded by telegram-expense: button taps and "write my own" replies.
async function handleOps(db: Db, update: any): Promise<void> {
  const cq = update?.callback_query;
  if (cq?.data?.startsWith('ch:')) {
    const [, short, choice] = String(cq.data).split(':');
    if (choice === 'own') {
      await tgCall('answerCallbackQuery', { callback_query_id: cq.id });
      await tgCall('sendMessage', { chat_id: cq.message?.chat?.id, text: `Reply to THIS message with what you want to send the guest. #CH-${short}`, reply_markup: { force_reply: true, selective: true } });
      return;
    }
    const h = await openHandoffByShort(db, short);
    const opt = h?.options?.[Number(choice) - 1];
    if (!opt) { await tgCall('answerCallbackQuery', { callback_query_id: cq.id, text: 'Option not found.' }); return; }
    await sendHostReply(db, short, opt, cq.from, cq.id);
    return;
  }
  const msg = update?.message;
  const m = /#CH-([0-9a-f]{8})/.exec(String(msg?.reply_to_message?.text ?? ''));
  if (m && msg?.text) await sendHostReply(db, m[1], String(msg.text), msg.from);
}

// ---- Book flow I/O (booking PRD §A). The pure parts live in booking.ts. ----
// SITE_URL is the tinyurl; the QR asset needs the Pages origin.
const QR_URL = 'https://cascadereservations-del.github.io/Stay_At_CascadeGSC/assets/images/qr-gcash.png';
/** The booking's notes: the Messenger marker, then the party split when children came (SPEC-39 4.4). */
export const submitNotes = (psid: string, flow: Flow): string => {
  const kids = flow.children ?? 0, adults = (flow.pax ?? 0) - kids;
  return `via Messenger (psid ${psid})${kids ? ` · ${adults} adult${adults === 1 ? '' : 's'}, ${kids} ${kids === 1 ? 'child' : 'children'}` : ''}`;
};
async function submitFlow(flow: Flow, thread: Thread, psid: string): Promise<{ flow: Flow; reply: string; image: string | null }> {
  const q = quoteTotal(flow.checkin!, flow.checkout!); // session 28: the guest chose fee or full; submit-booking accepts either
  const body = { guest_name: flow.name ?? thread.guest_name ?? 'Messenger guest', guest_phone: flow.phone, guest_email: flow.email ?? '', checkin_date: flow.checkin, checkout_date: flow.checkout,
    // SPEC-39 4.4: pax is the whole party; the split follows the marker, so the cards (siteNotes) show it.
    pax: flow.pax, notes: submitNotes(psid, flow), contact_type: 'phone', hold: true, channel: 'messenger', total_amount: q.total, deposit_amount: flow.pay_full ? q.total : q.deposit, pay_full: flow.pay_full === true };
  const r = await fetch(`${env('SUPABASE_URL')}/functions/v1/submit-booking`, { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: env('SUPABASE_ANON_KEY'), Authorization: `Bearer ${env('SUPABASE_ANON_KEY')}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) }).catch(() => null);
  const j = r ? await r.json().catch(() => null) : null;
  if (!r || !j) { console.error('submit_flow_failed', r?.status); return { flow, reply: submitFailed(flow.lang), image: null }; }
  if (r.status === 409 || j.error === 'dates_unavailable') return { flow: { ...flow, step: 'dates', updated_at: new Date().toISOString() }, reply: datesTaken(flow.lang), image: null };
  if (!j.ok) { console.error('submit_flow_rejected', JSON.stringify(j).slice(0, 200)); return { flow, reply: submitFailed(flow.lang), image: null }; }
  const f: Flow = { ...flow, step: 'await_receipt', booking_id: j.inquiry_id, ref: j.ref, deposit: Number(j.deposit_amount), total: Number(j.total_amount), hold: j.hold === true,
    hold_expires_at: j.hold_expires_at ?? null, receipt_token: j.receipt_upload_token, receipt_expires_at: j.receipt_upload_expires_at, updated_at: new Date().toISOString() };
  return { flow: f, reply: stayPayMessage(f, thread.guest_name), image: QR_URL }; // SPEC-39 3.6b: card + hold + payment, one message
}
async function forwardReceipt(flow: Flow, url: string, name: string | null): Promise<{ sent: boolean; reply: string }> {
  if (!flow.receipt_token || (flow.receipt_expires_at && Date.parse(flow.receipt_expires_at) < Date.now())) return { sent: false, reply: receiptLapsed('hold', flow.lang) };
  const img = await fetch(url, { signal: AbortSignal.timeout(20_000) }).catch(() => null);
  if (!img || !img.ok) return { sent: false, reply: receiptRetry(flow.lang) };
  const bytes = new Uint8Array(await img.arrayBuffer());
  const mime = (img.headers.get('content-type') ?? 'image/jpeg').split(';')[0].trim();
  // SPEC-39 3.6b: a guest who switched to "full" after the hold is checked against the stored total (SPEC-34's x-pay-full),
  // so the receipt reads right even if the deposit_amount update did not land.
  const r = await fetch(`${env('SUPABASE_URL')}/functions/v1/upload-booking-receipt`, { method: 'POST', headers: { Authorization: `Bearer ${flow.receipt_token}`, 'Content-Type': mime, 'X-Receipt-Filename': 'messenger.' + (mime.split('/')[1] || 'jpg'), apikey: env('SUPABASE_ANON_KEY'), ...(flow.pay_full ? { 'X-Pay-Full': 'true' } : {}) }, body: bytes, signal: AbortSignal.timeout(30_000) }).catch(() => null);
  const j = r ? await r.json().catch(() => ({})) : {};
  if (r?.ok) return { sent: true, reply: receiptThanks(name, flow.lang) };
  if (j?.error === 'receipt_already_uploaded') return { sent: true, reply: receiptAlready(flow.lang) };
  if (r?.status === 401) return { sent: false, reply: receiptLapsed('link', flow.lang) };
  console.error('forward_receipt_failed', r?.status, JSON.stringify(j).slice(0, 200));
  return { sent: false, reply: receiptRetry(flow.lang) };
}

/** availabilityLine's taken-dates line in any register ("I'm sorry, ... already reserved", "Pasensya na po, reserved na"). */
const RESERVED_RE = /already reserved|reserved na/i;
/** Booked nights overlapping the flow's stay (calendar_events, cancelled excluded). */
/** Booked nights that overlap the stay, or null when the calendar could not be read (session 30: a failed read
 *  used to return an empty set, and the guest was told the dates were available). */
async function bookedNightsFor(db: Db, flow: Flow): Promise<Set<string> | null> {
  const { data: rows, error } = await db.from('calendar_events').select('checkin_date, checkout_date').neq('status', 'cancelled').lt('checkin_date', flow.checkout!).gt('checkout_date', flow.checkin!).limit(50);
  if (error) { console.error('calendar_read_failed', 'bookedNightsFor', String(error.message ?? error).slice(0, 200)); return null; }
  const booked = new Set<string>();
  for (const r of rows ?? []) for (let d = r.checkin_date; d < r.checkout_date; d = addDays(d, 1)) booked.add(d);
  return booked;
}
/** Lloyd 2026-09-17, incident 2026-10-07: another guest checks out on `day` (cancelled excluded) and that stay is not chained on
 *  (D-290: a junction day has no turnover). A failed read is logged and reads as no turnover, so the caller's line is left out. */
async function turnoverOn(db: Db, day: string, where: string): Promise<boolean> {
  try {
    const { data, error } = await db.from('calendar_events').select('checkout_date').neq('status', 'cancelled').eq('checkout_date', day).limit(1);
    if (error) { console.error('calendar_read_failed', where, String(error.message ?? error).slice(0, 200)); return false; }
    return !!data?.length && !(await stayContinues(db, PROPERTY_ID, day));
  } catch (e) { console.error('calendar_read_failed', where, String(e).slice(0, 200)); return false; }
}
/** SPEC-14 (D-184): the open window nearest the guest's requested check-in that is long enough for their stay.
 *  null when the calendar cannot be read, or nothing inside the horizon fits - the reserved line then stands alone. */
async function nearestWindow(db: Db, flow: Flow): Promise<Window | null> {
  const today = dayStr(new Date(Date.now() + 8 * 3_600_000)); // Manila
  const horizonEnd = addDays(today, HORIZON_DAYS);
  const { data, error } = await db.from('calendar_events').select('checkin_date, checkout_date').neq('status', 'cancelled').gte('checkout_date', today).lte('checkin_date', horizonEnd).order('checkin_date').limit(200);
  if (error) { console.error('calendar_read_failed', 'nearestWindow', String(error.message ?? error).slice(0, 200)); return null; }
  const booked = new Set<string>();
  for (const r of data ?? []) for (let d = r.checkin_date; d < r.checkout_date; d = addDays(d, 1)) booked.add(d);
  const want = flow.checkin && flow.checkin >= today ? flow.checkin : today;
  const wanted = flow.checkin && flow.checkout ? Math.max(1, Math.round((Date.parse(flow.checkout) - Date.parse(flow.checkin)) / 86_400_000)) : 1;
  const fits = openWindows(booked, today, horizonEnd).filter((w) => w.nights >= wanted);
  if (!fits.length) return null;
  const best = fits.sort((a, b) => Math.abs(Date.parse(a.start) - Date.parse(want)) - Math.abs(Date.parse(b.start) - Date.parse(want)))[0];
  return trimWindow(best, wanted); // offer the stay they asked for, not the whole block up to the next booking
}
// ---- Effects seam and probe (voice close-out 2026-09-17, SPEC-06 sections 1-2) -------------------------------
// Everything handle() does to the outside world goes through `fx`. liveEffects wraps today's functions one to one
// (no behaviour change on the guest path); probeEffects records the calls and sends nothing, so scripted golden
// conversations run through the REAL handle() - real prompt, real model, real calendar - on a fresh probe: thread.
type Effects = {
  send(psid: string, text: string, chips?: Chip[]): Promise<void>;
  qr(psid: string, flow: Flow | null, fallbackUrl: string): Promise<void>;
  ops(text: string): Promise<void>;
  handoff(db: Db, thread: Thread, text: string, risk: RiskCode, link: string, note?: string, anyWording?: boolean): Promise<void>;
  submit(flow: Flow, thread: Thread, psid: string): Promise<{ flow: Flow; reply: string; image: string | null }>;
  receipt(flow: Flow, url: string, name: string | null): Promise<{ sent: boolean; reply: string }>;
  /** SPEC-39 3.6b: a change after the hold reaches the booking row ("full" -> deposit_amount; a corrected count or contact). */
  amend(db: Db, flow: Flow, fields: Record<string, unknown>): Promise<boolean>;
  name(psid: string): Promise<string | null>;
};
const liveEffects: Effects = {
  send: async (psid, text, chips) => { await fbSend(psid, text, false, chips ?? []); },
  // session 28: the QR carries the chosen amount (QR Ph tag 54); the static site QR is the fallback
  qr: async (psid, flow, fallbackUrl) => {
    let sent = false;
    try { const amt = Number(flow?.deposit ?? 0); if (amt > 0) sent = await fbSendImageBytes(psid, await qrPng(qrphWithAmount(GCASH_QRPH_BASE, amt)), `gcash-${amt}.png`); }
    catch (e) { console.error('qr_amount_failed', String(e).slice(0, 200)); }
    if (!sent) await fbSendImage(psid, fallbackUrl);
  },
  ops: tgOps, handoff: openHandoff, submit: submitFlow, receipt: forwardReceipt, name: fbName,
  // booking_inquiries is submit-booking's table; only a request still pending is touched.
  // No row updated (not pending any more, wrong id) is a failure too, so requote_full_failed / correction_after_hold_failed log.
  amend: async (db, flow, fields) => {
    if (!flow.booking_id) return false;
    const { data, error } = await db.from('booking_inquiries').update(fields).eq('id', flow.booking_id).eq('status', 'pending').select('id');
    return !error && (data?.length ?? 0) > 0;
  },
};
type ProbeCall = { fx: string; text?: string; detail?: unknown };
export function probeEffects(calls: ProbeCall[], guestName: string | null, now = new Date()): Effects {
  return {
    send: (_psid, text, chips) => { calls.push({ fx: 'send', text, ...(chips?.length ? { detail: { chips: chips.map((c) => c.title) } } : {}) }); return Promise.resolve(); },
    qr: (_psid, flow) => { calls.push({ fx: 'qr', detail: { amount: flow?.deposit ?? null } }); return Promise.resolve(); },
    ops: (text) => { calls.push({ fx: 'ops', text: text.slice(0, 300) }); return Promise.resolve(); },
    handoff: (_db, _thread, text, risk, _link, note) => { calls.push({ fx: 'handoff', text: text.slice(0, 200), detail: { risk, note: note ?? '' } }); return Promise.resolve(); },
    submit: (flow, thread) => {
      const q = quoteTotal(flow.checkin!, flow.checkout!), deposit = flow.pay_full ? q.total : q.deposit, at = now;
      calls.push({ fx: 'submit', detail: { checkin: flow.checkin, checkout: flow.checkout, pax: flow.pax, total: q.total, deposit } });
      // SPEC-31 s6: mirrors submit-booking - a hold only for the fee 5+ days out; the Messenger upload window is 24 h either way (D-255).
      const hold = !flow.pay_full && !lastMinute(flow.checkin!, at);
      const until = new Date(at.getTime() + 24 * 3_600_000).toISOString();
      const f: Flow = { ...flow, step: 'await_receipt', booking_id: 'probe', ref: 'DIR-PROBE', deposit, total: q.total, hold, hold_expires_at: hold ? until : null, receipt_token: 'probe', receipt_expires_at: until, updated_at: at.toISOString() };
      return Promise.resolve({ flow: f, reply: stayPayMessage(f, thread.guest_name, at), image: QR_URL });
    },
    amend: (_db, flow, fields) => { calls.push({ fx: 'amend', detail: { booking: flow.booking_id, ...fields } }); return Promise.resolve(true); },
    receipt: (flow, _url, name) => { calls.push({ fx: 'receipt' }); return Promise.resolve({ sent: true, reply: receiptThanks(name, flow.lang) }); },
    name: () => Promise.resolve(guestName),
  };
}

export async function handle(db: Db, ev: Record<string, any>, mode: string, fx: Effects = liveEffects, now = new Date()): Promise<void> {
  // Session 59: a priority-help postback or m.me referral has no message; it becomes an empty turn. Any other menu tap is the
  // guest's question in the button's words (the Page's "How much? Available?" menu items reached no one before: the webhook
  // had no postback field and this function dropped every event without a message).
  const entry = priorityEntry(ev);
  const pbText = postbackText(ev);
  const msg = ev.message ?? (entry ? { mid: ev.postback?.mid ?? `ref-${ev.timestamp ?? now.getTime()}`, text: '' } : pbText ? { mid: ev.postback?.mid, text: pbText } : null); if (!msg) return;
  await loadContact(db); // Lloyd 2026-09-28: the on-ground contact comes from the dashboard (app_settings), 60 s cache
  await loadCard(db); // SPEC-34: every quote this turn reads the stored rate card (60 s cache; seed card + log on failure)

  // Staff replied from the Page inbox: hold the bot on this thread.
  if (msg.is_echo) {
    if (env('META_APP_ID') && String(msg.app_id ?? '') === env('META_APP_ID')) return; // our own send
    // Session 28 (live 2026-09-17 08:54): Messenger renders our GCash number and QR into its own
    // "Transfer with GCash" / "QR transfer" cards and echoes them as Page messages with no app_id and
    // no text. They are not a staff reply: an attachment-only echo within 3 min of our last bot turn
    // is Meta's, and holding the bot on it silenced the guest's next two questions for 2 h.
    if (!msg.text && Array.isArray(msg.attachments)) {
      const { data: t } = await db.from('concierge_threads').select('history').eq('psid', ev.recipient.id).maybeSingle();
      const lastBot = [...((t?.history ?? []) as Turn[])].reverse().find((h) => h.role === 'bot');
      if (lastBot && now.getTime() - Date.parse(lastBot.at) < 3 * 60_000) { console.log('echo_ignored_meta_card', JSON.stringify({ psid: ev.recipient.id, types: msg.attachments.map((a: any) => a?.type) })); return; }
    }
    console.log('echo_hold', JSON.stringify({ psid: String(ev.recipient.id).slice(-6), app_id: msg.app_id ?? null, text: !!msg.text })); // D-317 review: a wrong echo source shows up here
    const { data: held } = await db.from('concierge_threads').select('human_until').eq('psid', ev.recipient.id).maybeSingle();
    await db.from('concierge_threads').upsert({ psid: ev.recipient.id, human_until: laterOf(held?.human_until, now.getTime() + ECHO_HOLD_MS), updated_at: now.toISOString() });
    // Session 58 (live 2026-09-28): the host answered the lockout from the page inbox, and the handoff stayed 'open' - only
    // a Telegram card send closed one. With D-274 an open access handoff turns the guest's next question into a follow-up,
    // so a typed staff reply now closes this guest's open handoffs.
    if (msg.text) await db.from('concierge_handoffs').update({ status: 'sent', resolved_by: 'page inbox', resolved_at: now.toISOString() }).eq('psid', ev.recipient.id).eq('status', 'open');
    return;
  }

  const psid: string = ev.sender.id;
  // D-271: Jev runs beside the thread read, so its ~350 ms costs almost no wall time. Probes spend the probe key (D-254).
  const jevKey = env(psid.startsWith('probe:') ? 'CASCADE_OPENROUTER_PROBE_KEY' : 'CASCADE_OPENROUTER_BOT_KEY');
  const jevP = jevRoute(String(msg.text ?? '').trim(), jevKey);
  // D-222: one retry, then stop. A failed read used to fall through as a brand-new thread, and the upsert at the end
  // would have overwritten the guest's history with this one turn. The caller alerts the host with the link.
  let { data: row, error: rowErr } = await db.from('concierge_threads').select('*').eq('psid', psid).maybeSingle();
  if (rowErr) ({ data: row, error: rowErr } = await db.from('concierge_threads').select('*').eq('psid', psid).maybeSingle());
  if (rowErr) throw new Error('thread_read_failed: ' + String(rowErr.message ?? rowErr).slice(0, 120));
  const thread: Thread = (row as Thread | null) ?? { psid, guest_name: null, human_until: null, bot_turns: 0, history: [], last_risk: null, booking_flow: null, last_mid: null };

  // Meta retries a webhook it considers slow, and this function answers synchronously BEFORE the 200 -
  // one model call can take 25 s, two with a fallback. Without this the guest is answered twice.
  // ponytail: last id only; a small recent-ids array if Meta is ever seen replaying out of order.
  if (msg.mid && msg.mid === thread.last_mid) {
    console.log('duplicate_mid_ignored', JSON.stringify({ psid, mid: msg.mid }));
    return;
  }

  if (!thread.guest_name) thread.guest_name = await fx.name(psid);

  const said: string = (msg.text ?? '').trim();
  const link = `https://www.facebook.com/messages/t/${psid}`;
  // Session 59: priority help. The tap, the guide's link, or the answer to the ask (a date in the reply within 30 min).
  // Mode off stays off (Lloyd's switch); a human hold does not stop it, like the door and safety (D-277).
  const lastAsk = [...thread.history].reverse().find((h) => h.role === 'bot');
  const asked = lastAsk?.route?.priority && now.getTime() - Date.parse(lastAsk.at) < 30 * 60_000 ? Number(lastAsk.route.priority) || 0 : 0;
  const priReply = asked && said ? priorityAnswer(said, now) : null;
  if (entry && mode === 'off') return; // the tap shows in the page inbox; nothing automatic
  const hostHeld = !!thread.human_until && Date.parse(thread.human_until) > now.getTime(); // D-317: a person is handling this chat
  if (mode !== 'off' && hostHeld && entry) return await fx.handoff(db, thread, 'The guest tapped Priority help (they want help now).', 'priority', link, '', true);
  if (mode !== 'off' && !hostHeld && (entry || priReply?.date)) return await priorityTurn(db, thread, said, entry, priReply, asked, link, fx, now, msg.mid);
  // D-282: the answer to the house ask (a guests-only detail asked before the stay was verified). A match opens the guest
  // tier and the ORIGINAL question is answered on this turn; a miss retries once, then the unmatched path.
  const houseAsked = !asked && lastAsk?.route?.house && now.getTime() - Date.parse(lastAsk.at) < 30 * 60_000 ? Number(lastAsk.route.house) || 0 : 0;
  let houseQuestion = '';
  if (mode !== 'off' && !hostHeld && houseAsked && said) {
    const q = priorityAnswer(said, now), question = String(lastAsk!.route!.q ?? '');
    if (q.date) {
      if (!unmatchedRecently(thread, now) && await verifyStay(db, thread, q, now)) houseQuestion = question;
      else return await houseUnmatched(db, thread, said, houseAsked, question, link, fx, now, msg.mid);
    }
  }
  const text = houseQuestion || said;
  // Conversation stage, computed here rather than guessed by the model: a greeting belongs to the
  // first exchange or after a long silence; every other turn continues the chat. The same gap
  // resets the 12-turn cap (2026-09-13: bot_turns only ever grew, so a chatty guest was handed to
  // the host on every message for the rest of the thread's life).
  const lastBot = [...thread.history].reverse().find((h) => h.role === 'bot');
  const gapMin = lastBot ? (now.getTime() - Date.parse(lastBot.at)) / 60_000 : Infinity;
  const followUp = gapMin < 6 * 60;
  const priorTurns = followUp ? thread.bot_turns : 0;
  // D-299.10 (Lloyd 2026-10-05): Cassy no longer introduces herself in the first message; it is signed instead (D-173's
  // "introduced" scan went with it). botReply still discloses on a direct question.
  // D-258 (live 2026-09-26 02:14Z): a second booking on a thread the bot answered minutes ago opened with "Hi Ben, thank you
  // for reaching out". A new flow greets only when the bot has not spoken for 12 h - and D-300.1 signs only then.
  const greetNow = !thread.history.some((h) => h.role === 'bot' && now.getTime() - Date.parse(h.at) < 12 * 3_600_000);
  const g0 = gate(text || 'attachment', { mode, humanUntil: thread.human_until, botTurns: priorTurns, now, hasBooking: !!thread.booking_flow?.ref }); // SPEC-32 s2
  // D-271 safety net: Jev may raise a routine turn to a handoff (smoke, a Bisaya complaint, a date change the regex missed);
  // it never lowers the regex, and a live booking flow keeps its own deterministic steps.
  const jev = text ? await (houseQuestion ? jevRoute(text, jevKey) : jevP) : null;
  // D-271 primary (eval 60/60 tuning, 17/20 held-out vs regex 45/60, 9/20): Jev decides the soft risks, raises what the regex
  // missed, and lowers a regex false alarm only when sure no one must act; money, danger, the door and data probes keep the
  // regex floor. A live booking flow keeps its deterministic steps.
  // SPEC-34 (D-262) + D-311.1/.7 (Lloyd 2026-10-07): "any promo?" has a factual answer - the live promotions and that booking
  // direct is itself the better price - so a PLAIN promo question is answered and never forwarded: Jev's "negotiation" read
  // turned golden promo-ask-en/-tl into the host line. Haggling inside it (the regex's own policy_exception) still goes to the host.
  // Not bare "sale": "May sale po ba sa SM?" is about the mall (second review 2026-09-26).
  const promoAsk = /\b(promos?|promotions?|anniversary (?:promo|rate|price|sale))\b/i.test(text) && !/\b(discount|discounted|lower price|cheaper|mas mura)\b/i.test(text);
  const plainPromo = promoAsk && g0.risk !== 'policy_exception';
  const jevRaw = g0.reply && !isActive(thread.booking_flow, now) ? routeRisk(g0.risk, jev) : g0.risk;
  const jevRisk = plainPromo && jevRaw === 'policy_exception' ? g0.risk : jevRaw;
  let g = jevRisk !== g0.risk ? { ...g0, risk: jevRisk, handoff: jevRisk !== 'routine' } : g0;
  if (jev) console.log('jev_route', JSON.stringify({ psid: psid.slice(-6), regex: g0.risk, jev: jev.intent, c: +jev.confidence.toFixed(2), host: +jev.needsHost.toFixed(2), lang: jev.lang, ms: jev.ms, raised: jevRisk !== g0.risk }));
  // SPEC-39 3.3 (D-300.4): "medyo mahal po" / "a bit expensive" is the same price objection as "any discount?"; it goes to the host.
  const discountAsk = !plainPromo && priceObjection(text);
  const siteShown = thread.history.filter((h) => h.role === 'bot').slice(-4).some((h) => h.text.includes(SITE_URL)); // D-269
  // D-269 answer-then-escalate: a price proposal or special request (policy_exception that is not a house rule) is answered
  // from FACTS like a discount ask, and the host still gets the card with two options. A bare "our host will consider it"
  // left the guest's question unanswered (live 2026-09-27). Safety, access, payment, refund, complaint and cancellation
  // stay pure handoffs: there the bot must not improvise.
  // The canned house-rule answer only when the rule IS the question: "Is Oct 20 to 22 available? Also is party allowed?"
  // lost its dates question to it (live Cassy test 2026-09-28) - a mixed message is answered whole by the model.
  const ruleKind = houseRuleKind(text);
  const houseAsk = !!ruleKind || (jev?.intent === 'house_rule' && jev.confidence >= 0.8); // D-271: a house rule with no keyword
  const ruleOnly = !!ruleKind && !parseDates(text, now).length && (text.match(/\?/g) ?? []).length <= 1;
  const negotiate = !!text && g.risk === 'policy_exception' && !ruleOnly;
  const hostAsk = discountAsk || negotiate;
  // Session 58 (live lockout 2026-09-28): after the access handoff the guest's callback number and name went to the model
  // as routine turns; it said "we've passed it along" without passing anything and closed on "let us know your preferred
  // dates". A routine follow-up within 12 h of an open access or safety handoff now joins it: a new host card carries the
  // message, and the guest gets handoffFollowUp. Any open host-owned matter also mutes the booking close and look block.
  const hostOpen = await openHostRisks(db, psid, now); // G5: an attachment reads it too
  // D-317 review: a safety report holds routine chat for 24 h without counting as a host takeover - a second emergency or the
  // door still gets its line, and nothing says "you are handling this chat".
  if (!hostHeld && g.reply && g.risk === 'routine' && hostOpen.some((h) => h.risk === 'safety' && now.getTime() - h.at < HUMAN_HOLD_MS)) g = { ...g, reply: false, handoff: false };
  // Lloyd 2026-09-28 ("skip the nudge for staying guests"): someone at the residence now, this turn or in the last 24 h, gets
  // no booking pitch from code - no dates nudge, no site invite, no "arrange it here in the chat".
  // D-282 live probe 2026-09-29: a stay verified by the guide's check is a staying guest too (the Wi-Fi answer got the
  // photos, reviews and "arrange the booking" block).
  const verified = !!thread.verified_until && thread.verified_until >= dayStr(new Date(now.getTime() + 8 * 3_600_000));
  const stayingNow = verified || isStayingNow(text) || thread.history.some((h) => h.role === 'guest' && now.getTime() - Date.parse(h.at) < 24 * 3_600_000 && isStayingNow(h.text));
  // Live test 2026-09-28 11:42-11:45Z: a repeat of the door ask ("nakalimutan ko ang code", "hindi ako makapasok") got the
  // full access line each time, "naiwan aking cellphone sa loob" got the complaint line, and "available tonight?" was
  // swallowed as a follow-up. The same matter (routine, access, complaint) joins the open card; a question Jev is sure
  // is answerable (availability, amenities, directions, policy, price, house rules) is answered, still with no sales close.
  const ANSWERABLE = ['availability', 'amenity', 'directions', 'policy_info', 'price', 'house_rule'];
  const answerable = g.risk === 'routine' && !!jev && ANSWERABLE.includes(jev.intent) && jev.confidence >= 0.8;
  const sameMatter = g.risk === 'routine' || g.risk === 'access' || g.risk === 'complaint';
  const urgentOpen = sameMatter && !answerable && !isActive(thread.booking_flow, now) && !THANKS_RE.test(text) && !CLOSER_ONLY_RE.test(text)
    ? hostOpen.find((h) => (h.risk === 'access' || h.risk === 'safety' || h.risk === 'priority') && now.getTime() - h.at < 12 * 3_600_000)?.risk ?? null : null;
  let risk: RiskCode = text ? (urgentOpen ?? g.risk) : 'uncertain';
  let handoff = (g.handoff && !negotiate) || !text || !!urgentOpen;   // the bot steps aside: handoff line to the guest, 24 h hold
  let flagOnly = false;               // the bot answered but wants a host to glance: alert, no hold
  let draftNote = '';                 // D-227: a spent model budget, named on the host's card
  let reply = '';
  let stayPayTurn = false;           // SPEC-39 3.6b: this reply is the stay card + payment message (its own length cap)
  let promiseAfterQr = true;          // the account-name line rides under the first QR only (SPEC-10 control 6)

  // Book flow: runs before every other branch. A receipt image on a thread that is waiting for one
  // is evidence, not an attachment handoff; a slot answer is code-parsed; a question mid-flow passes
  // through to the model with the flow kept where it is.
  let flow: Flow | null = isActive(thread.booking_flow, now) ? thread.booking_flow! : null;
  let flowReply: string | null = null, flowImage: string | null = null, flowFollowUp: string | null = null;
  let startText: string | null = null;
  let afterQr: ReturnType<typeof answer> | null = null; // SPEC-39 3.6b: the guest's reply after the card and QR
  const payHold = !!flow && ['await_receipt', 'receipt_sent'].includes(flow.step); // SPEC-31 s4: the QR is out; the model answers questions only
  /** Incident 2026-10-07: the stay this turn tells the guest is open (flow line, or a model reply K18 checked) - the turnover notice. */
  let openStay: { checkin: string; lang: Flow['lang'] } | null = null;
  let calendarDown = false; // session 30: the calendar read failed on this turn - the reply does not claim availability and a host is told
  const attachment = (msg.attachments ?? []).find((a: any) => a?.type === 'image' && a?.payload?.url);
  // SPEC-31 (REVIEW F1-F3): after the QR, code owns the cancel, the "paid na" claim and the stray photo. `booked` is the
  // thread's booking whatever its step, readable 8 days (lastRef); a card's risk and note are applied after flowReply.
  const booked = lastRef(thread.booking_flow, now);
  let card: { risk: RiskCode; note: string; anyWording: boolean } | null = null;
  const uploadOpen = flow?.step === 'await_receipt' && !(flow.receipt_expires_at && Date.parse(flow.receipt_expires_at) < now.getTime());
  const guestSaid = thread.history.filter((h) => h.role === 'guest').slice(-6).map((h) => h.text).join(' ');
  if (g.reply && uploadOpen && attachment) {
    const r = await fx.receipt(flow!, String(attachment.payload.url), thread.guest_name);
    flowReply = r.reply; if (r.sent) flow = { ...flow!, step: 'receipt_sent', updated_at: now.toISOString() };
  } else if (g.reply && attachment && (booked || /\b(gcash|bayad|paid|receipt|deposit|payment|sent)\b/i.test(`${guestSaid} ${text}`))) {
    // s3: a photo with no live upload (hold lapsed, second photo, never booked) is a receipt for the host to match.
    flowReply = strayReceiptReply(booked?.name ?? thread.guest_name, replyLang(text || guestSaid.slice(-200), booked?.lang));
    card = { risk: 'payment', note: booked ? holdNote(booked, now) : 'No booking on this thread; the guest mentioned payment.', anyWording: true };
    if (booked) { const seen: Flow = { ...booked, photo_at: now.toISOString() }; thread.booking_flow = seen; if (flow) flow = seen; } // updated_at untouched: a lapsed flow stays lapsed
  } else if (g.reply && text && flow && ['await_receipt', 'receipt_sent'].includes(flow.step) && CANCEL_RE.test(text) && ['routine', 'cancellation'].includes(g.risk)) {
    // s1: never "we'll cancel it" from the model - the host releases the hold (telegram-expense bk_no) from this card.
    const change = (parseDates(text, now)[0] ?? '') >= dayStr(new Date(now.getTime() + 8 * 3_600_000));
    flowReply = holdCancelReply(flow, flow.name ?? thread.guest_name, replyLang(text, flow.lang), change);
    card = { risk: 'cancellation', note: holdNote(flow, now, change ? 'change requested' : ''), anyWording: false };
    flow = { ...flow, step: 'cancel_requested', updated_at: now.toISOString() };
  } else if (g.reply && text && booked && ['await_receipt', 'receipt_sent', 'cancel_requested', 'receipt_declined'].includes(booked.step) && g.risk === 'payment') {
    // s2: "paid na po?" is answered from what we hold, and the host gets one payment card per 24 h.
    flowReply = paidClaimReply(booked, booked.name ?? thread.guest_name, replyLang(text, booked.lang));
    card = { risk: 'payment', note: holdNote(booked, now), anyWording: true };
  } else if (g.reply && text && !g.handoff && flow?.step === 'await_receipt' && (afterQr = answer(flow, text, now, thread.guest_name)).action !== 'passthrough') {
    // SPEC-39 3.6b (D-300.3): after the one-step card and QR - "full" swaps the QR, "fee"/"ok" needs nothing more, a
    // correction re-shows the card and reaches the booking, new dates go to the host. A question falls through to the model.
    const s = afterQr, L = replyLang(text, flow.lang);
    if (s.action === 'change') {
      flowReply = holdCancelReply(flow, flow.name ?? thread.guest_name, L, true);
      card = { risk: 'cancellation', note: holdNote(flow, now, 'change requested'), anyWording: false };
      flow = { ...flow, step: 'cancel_requested', updated_at: now.toISOString() };
    } else {
      flow = s.flow; flowReply = s.reply;
      if (s.action === 'requote_full') {
        if (!(await fx.amend(db, flow, { deposit_amount: flow.total }))) console.error('requote_full_failed', JSON.stringify({ booking: flow.booking_id, ref: flow.ref }));
        flowImage = QR_URL; promiseAfterQr = false; // the QR for the full amount; the account line already rode under the first
      }
      if (s.action === 'correct' && !(await fx.amend(db, flow, { pax: flow.pax, guest_phone: flow.phone, guest_email: flow.email ?? '' }))) console.error('correction_after_hold_failed', JSON.stringify({ booking: flow.booking_id, ref: flow.ref }));
    }
  } else if (g.reply && text && PAY_HOW_RE.test(text) && ['routine', 'payment'].includes(g.risk) && !(flow && ['await_receipt', 'receipt_sent'].includes(flow.step))
      && !(booked && ['await_receipt', 'receipt_sent', 'cancel_requested', 'receipt_declined', 'confirmed'].includes(booked.step))) {
    // D-258: "how do I pay?" before the QR is out - the GCash QR and one line, code-owned (the model promised a QR later).
    flowReply = payHowReply(flow, flow?.name ?? thread.guest_name, replyLang(text, flow?.lang), now);
    flowImage = QR_URL;
  } else if (g.reply && text && !g.handoff && flow && !['await_receipt', 'receipt_sent'].includes(flow.step)) {
    const before = flow;
    const s = answer(flow, text, now, thread.guest_name); flow = s.flow;
    // protocol: the model answers, then the flow's ask follows (resumed card: soft nudge). D-300.4: not under a price
    // objection - the host decides the price, so no rate is re-quoted and the model's one soft question closes the reply.
    if (s.action === 'passthrough') flowFollowUp = hostAsk ? null : prompt(flow, thread.guest_name, true);
    if (s.action === 'ask') flowReply = s.reply ?? prompt(flow, thread.guest_name);
    // Protocol rule 1 mid-flow (live 2026-09-17 10:57: "Oct 20 to 22 po, available pa po ba?" got the contact ask with no
    // answer): dates completed on this turn are checked against the calendar before the next ask.
    if (s.action === 'ask' && flow.checkin && flow.checkout && (flow.checkin !== before.checkin || flow.checkout !== before.checkout)) {
      const nights = await bookedNightsFor(db, flow); calendarDown = !nights;
      const alt = nights && nights.size ? await nearestWindow(db, flow) : null;
      const line = availabilityLine(flow, nights, alt, now, true);
      if (RESERVED_RE.test(line)) { flow = { ...flow, step: 'dates', checkin: undefined, checkout: undefined, alt: alt && !alt.open_ended ? alt : undefined }; flowReply = line; }
      else { flowReply = `${availabilityAck(flow, line)}\n\n${s.reply ?? prompt(flow, thread.guest_name)}`; if (nights) openStay = { checkin: flow.checkin, lang: flow.lang }; }
    }
    else if (s.action === 'cancelled') flowReply = s.reply;
    else if (s.action === 'submit') {
      // SPEC-39 3.6b: the tone of the payment nudge is read once, here, from the whole thread and its booking turns.
      const said = thread.history.filter((h) => h.role === 'guest');
      const sure = [...said.map((h) => h.route), jev ? { jev: jev.intent, c: jev.confidence } : null].filter((r) => r && Number(r.c) >= 0.8).map((r) => String(r!.jev));
      flow = { ...flow, tone: flow.tone ?? toneOf([...said.map((h) => h.text), text], [...said.filter((h) => h.at >= flow!.started_at).map((h) => h.text), text], sure, flow.lang) };
      const r = await fx.submit(flow, thread, psid); flow = r.flow; flowReply = r.reply; flowImage = r.image; stayPayTurn = !!r.image;
    }
  } else if (g.reply && text && !g.handoff && !flow && g.risk === 'routine' && (startText = bookingStart(text,
      thread.history.filter((h) => h.role === 'guest').map((h) => h.text), thread.history.filter((h) => h.role === 'bot').slice(-1)[0]?.text ?? '', now))) {
    flow = start(startText, now); // session 49: a dated "can I book" and a yes to our own chat offer both start here (bookingStart)
    // s73 F5: a yes to our offer started from an earlier message whose question was already answered - only the flow speaks.
    // R2-4 / R3-1: the stay is the one we quoted and offered to hold - pricedStay over the same messages, both dates, so an
    // incidental later date ("we leave Oct 21 early") or a corrected one never becomes the held night.
    if (startText !== text && isChatYes(text)) {
      const held = flow.checkin ? pricedStay(thread.history.filter((h) => h.role === 'guest').map((h) => h.text), now) : null;
      flow = { ...flow, asked: null, question: false, ...(held ? { checkin: held.checkin, checkout: held.checkout, step: flow.pax ? 'offer' as const : 'pax' as const } : {}) };
    }
    // Protocol rule 1 - answer what was asked before asking anything. Availability is answered from the
    // calendar here (exact, no model); any other question goes to the model with the flow's ask appended.
    // D-222: the calendar is read whenever both dates are known, not only on an "available" word - "book Oct 10 to 12
    // for 2" on a taken night used to be quoted and fail only at submit.
    if (needsCalendarCheck(flow)) {
      // Live 2026-09-26 13:01Z (Suzanne, "Available today?"): a single date asked about is that night, answered now. With
      // no check-out the calendar was queried with an undefined bound and the guest got only "until which date?".
      const probe: Flow = flow.checkout ? flow : { ...flow, checkout: addDays(flow.checkin!, 1) };
      const nights = await bookedNightsFor(db, probe); calendarDown = !nights;
      const alt = nights && nights.size ? await nearestWindow(db, probe) : null;
      const line = availabilityLine(probe, nights, alt, now, true);
      if (nights && !RESERVED_RE.test(line)) openStay = { checkin: probe.checkin!, lang: flow.lang };
      if (RESERVED_RE.test(line)) { flow = { ...flow, step: 'dates', checkin: undefined, checkout: undefined, alt: alt && !alt.open_ended ? alt : undefined }; flowReply = (greetNow ? greeting(thread.guest_name, flow.lang).trimEnd() + '\n\n' : '') + line; } // SPEC-28 section 3; SPEC-39 3.5 (s73 F3): the greeting is its own paragraph
      // SPEC-28 section 2: "is Oct 26 to 28 open? is there wifi?" - the model answers the wifi, then the dates line and the
      // flow's ask follow. The model's reply carries the one greeting (ensureGreeting), so the flow's part has none.
      else if (flow.asked === 'question' || flow.question) flowFollowUp = flowLead(flow, thread.guest_name, flow.question ? line : '', now);
      else flowReply = opener(flow, thread.guest_name, line, false, greetNow) + prompt(flow, thread.guest_name);
      // D-299.10: no introduction sentence on any first reply; the initial message is signed instead (greetNow, below).
    } else if (flow.asked === 'question') flowFollowUp = flowLead(flow, thread.guest_name, '', now);
    else flowReply = opener(flow, thread.guest_name, '', false, greetNow) + prompt(flow, thread.guest_name); // session 28: welcome first
  }
  if (flow) thread.booking_flow = flow;
  if (flowReply) { handoff = false; risk = 'routine'; }
  if (card) { handoff = true; risk = card.risk; draftNote = card.note; } // SPEC-31: the code line goes to the guest AND the host gets the card
  if (calendarDown) flagOnly = true; // OPS gets the glance card: the guest was told we will confirm the dates

  // D-311.8 (Lloyd 2026-10-07): a Bisaya or Bislish guest gets English - the register D-172 settled (Taglish on the first Bisaya
  // turn, Bislish from the second) is retired. Settled once per turn, so the code-owned lines follow the same register as the model.
  const prevGuest = thread.history.filter((h) => h.role === 'guest').slice(-1)[0]?.text ?? '';
  const thisLang = primaryLang(guestLang(text), jev); // D-271 hybrid: Jev overrides only an English reading, when sure
  const turnLang = thisLang === 'bisaya' ? 'english' : thisLang;
  // D-282: house how-tos for the model (HOUSE block). A verified current guest reads the guest tier; anyone else reads
  // public rows, and a question whose best answer is guest-tier gets the stay check instead (never mid-booking).
  const house = text && g.reply ? matchHouse(await loadHouse(db).catch((e) => { console.error('house_load_failed', String(e).slice(0, 200)); return []; }), text, verified ? 'guest' : 'public') : null;
  const houseLocked = !!house?.locked && !flow && !flowReply && !handoff;
  let houseAskSent = false;

  if (!g.reply) {
    // D-317: a person is handling this chat - nothing goes to the guest; the host hears about every message instead.
    if (mode !== 'off' && hostHeld) {
      // A receipt photo still reaches Finance (the Angel incident): stored and carded, no line to the guest. A sticker is not a receipt.
      if (uploadOpen && attachment && !attachment.payload?.sticker_id) { const r = await fx.receipt(flow!, String(attachment.payload.url), thread.guest_name); if (r.sent) { flow = { ...flow!, step: 'receipt_sent', updated_at: now.toISOString() }; thread.booking_flow = flow; } }
      const sticker = !text && !!attachment?.payload?.sticker_id; // a sticker or a like: nothing to tell the host
      if (g.handoff) await fx.handoff(db, thread, text || '[attachment]', g.risk, link); // an emergency or the door: card + urgent alert
      else if (!sticker) await fx.ops(withHeader('guest', 'host handling', `💬 ${thread.guest_name ?? 'A guest'} wrote on Messenger. You are handling this chat, so Cassy stays quiet.\n> ${maskMoney(text || (attachment ? '[photo]' : '[attachment]')).slice(0, 300)}${uploadOpen && attachment && !attachment.payload?.sticker_id ? '\nThe photo went to Finance as a receipt.' : ''}\n\nReply in Messenger: ${link}`));
    }
  }
  else if (flowReply) reply = flowReply;
  // D-269 (live 2026-09-27: "Is party allowed?" got only the handoff line): a house-rule question is answered from FACTS,
  // and the host still gets the card.
  else if (handoff) { const rule = risk === 'policy_exception' && ruleOnly ? houseRuleKind(text) : null; reply = !text ? (hostOpen.length || thread.booking_flow?.ref ? ((msg.attachments ?? []).some((a: any) => a?.type === 'audio') ? voiceNote(l3Of(guestLang(prevGuest))) : attachmentNoted(l3Of(guestLang(prevGuest)))) : ATTACHMENT_REPLY) : rule ? houseRule(rule, l3Of(turnLang)) : urgentOpen ? handoffFollowUp(l3Of(turnLang)) : risk === 'access' ? accessVerify(l3Of(turnLang)) : HANDOFF[risk]; }
  // Session 58 live probe: "salamat" alone reads as Taglish, so a settled Bisaya thread got "It's our pleasure po". A
  // Taglish-reading closer keeps Bislish when the last two guest turns were Bisaya (D-172's own two-turn rule).
  // D-311.8: a thanks from a Bisaya thread is closed in English ("salamat" alone reads as Taglish, so the thread decides).
  else if (THANKS_RE.test(text) || CLOSER_ONLY_RE.test(text)) reply = closingReply(thread.guest_name, thisLang === 'taglish' && thread.history.filter((h) => h.role === 'guest').slice(-2).some((h) => guestLang(h.text) === 'bisaya') ? 'english' : turnLang, THANKS_RE.test(text), thread.history.filter((h) => h.role === 'bot').slice(-2).map((h) => h.text).join('\n'));
  else if (BOT_RE.test(text)) reply = botReply(thread.guest_name, turnLang);
  else if (houseLocked) { reply = houseVerifyAsk(l3Of(turnLang)); houseAskSent = true; } // D-282: never says what the fact is
  // s74 G1: a past stay told about and a price asked ("last time we stayed Sep 5 to 7, how much now?") - no quote, no hold, ask the new dates.
  else if (rolledPastStay(text, now) && (priceAsked(text) || BOOK_RE.test(text) || AVAIL_WORD_RE.test(text))) reply = pastStayAsk(l3Of(turnLang));
  else if (needsDatesFirst(text, thread.history.filter((h) => h.role === 'guest').map((h) => h.text).join(' '))) reply = datesFirstReply(thread.guest_name, text, followUp);
  else {
    try {
      const everAnswered = thread.history.some((h) => h.role === 'bot'); // SPEC-21: a thread fact, not a clock fact
      const stateBlock = followUp
        ? `\n\nCONVERSATION STATE: this is a FOLLOW-UP in a live chat (your last reply was ${Math.round(gapMin)} min ago). Do NOT greet again - no "Hello", "Hi", "Hello po", "Good morning". Address the guest by name early in the first sentence instead ("Ben, yes po...", "Sige po, Sir Ben, ..."), the way a host continues a conversation, then the answer.`
        : everAnswered ? `\n\nCONVERSATION STATE: the guest is back after a long gap. A short warm salutation by first name is welcome, then the answer.`
        : `\n\nCONVERSATION STATE: this is the FIRST exchange. Code greets the guest, asks for their dates and signs the message, so your answer begins with the answer itself and carries no link.`;
      // First exchange gets the full model (voice, warmth, facts); follow-ups run on the lite tier.
      // Follow-ups: compact prompt (no exemplars) on the full model - cheaper than the old full
      // prompt AND better behaved than lite; the language hint rides on the guest's own turn.
      const lang = turnLang, l3 = l3Of(turnLang);
      // Live 2026-09-28 (Suzanne): "How much?" was answered for Oct 30 from a message two days old. Dates the model reads
      // come from the guest's last 24 hours only.
      const guestTexts = [...thread.history.filter((h) => h.role === 'guest' && now.getTime() - Date.parse(h.at) < 24 * 3_600_000).map((h) => h.text), text];
      const context = (await availabilityBlock(db)) + (await pendingBlock(db, psid)) + guestDatesBlock(guestTexts) + stateBlock + (house ? `\n\n${houseBlock(house.rows)}` : '');
      // The dates also ride on the guest turn: the system-side block alone was ignored for a
      // Bisaya late check-out question (live 2026-09-13) and the model asked for dates again.
      // SPEC-34 (D-262) + s73 F1: the stay being priced (pricedStay) gets code's figures, so the model never does the arithmetic.
      const stay = pricedStay(guestTexts, now), sq = stay ? quoteTotal(stay.checkin, stay.checkout) : null;
      const datesKnown = [...new Set(guestTexts.join(' \n ').match(DATES_RE) ?? [])].slice(-3);
      // s73 R2-6: a day-first date ("19 to 21 Oct") is outside DATES_RE but read by parseDates - the dates are known all the same.
      if (!datesKnown.length && stay) datesKnown.push(dmRange(stay.checkin, stay.checkout));
      // s74 G1: "5 days from Dec 25" is the whole stay, not just its first date (the model asked for the nights again).
      const phrased = stayFromPhrase(text, now);
      if (phrased) datesKnown.splice(0, datesKnown.length, dmRange(phrased.checkin, phrased.checkout));
      const datesHint = datesKnown.length ? `[Guest's dates already given: ${datesKnown.join('; ')} - answer for these days, do not ask for dates.] ` : '';
      // Capacity rides on the guest turn too: "pwede 5 adults?" got "we can accommodate 5 adults" (live 2026-09-13).
      const capHint = /\b([4-9]|1\d)\s*(adults?|pax|persons?|people|guests?|tao|matanda)\b/i.test(text) ? '[Capacity is a hard limit: 3 adults, or 3 adults + 1 child, or 2 adults + 2 children. This group does not fit - say so warmly and suggest a larger place; never say we can accommodate them.] ' : '';
      const priced = priceAnchor(guestTexts, now, lang);
      // D-270 (live probe 2026-09-28: "Can you do 1,500?" repeated the whole month quote given one turn earlier): figures or a
      // promotion already said in the last three replies are referred to, not said again (protocol rule 4, no repetition).
      const recentBot = thread.history.filter((h) => h.role === 'bot').slice(-3).map((h) => h.text).join('\n');
      // s73 R2-2: matched on the stay TOTAL - a shared per-night rate ("PHP 1,691" for Oct 19-21 and Oct 26-29) is not the same quote.
      const quotedTotal = priced.total, given = !!quotedTotal && (recentBot.includes(peso(quotedTotal)) || recentBot.includes(`₱${quotedTotal.toLocaleString('en-US')}`));
      const anchor = given ? '[The stay figures were already given in this chat: refer to them in a few words, do not repeat them.] ' : priced.text;
      const houseMixed = negotiate && houseAsk; // D-270/271: a house rule (keyword or Jev) the canned line does not cover - the rule, then everything else
      // D-311.6 (Lloyd 2026-10-07, replaces D-300.4's value line): a discount or haggle request gets code's answer - "We completely
      // understand, and we'll do our best to accommodate your request." - no rate explanation, then the host line and the hold
      // question. No model call - but only when the price ask is the WHOLE message (audit of 3bd0e1b, D1): "what is the best price
      // for 5 nights?", "is there a discount for 30 nights?" or "can you do 1,500? and is there parking?" also ask for figures or a
      // fact, so the model answers the rest and code opens with the understanding line and closes with the host line.
      const haggle = hostAsk && !houseMixed;
      // ponytail: a second ask with no "?" and no stay length ("discount please, parking available") still counts as pure and loses
      // the second ask; split such messages only if guests do it in practice.
      const pureHaggle = haggle &&!stayNights(text) && !parseDates(text, now).length && (text.match(/\?/g) ?? []).length <= 1;
      // D-311.1: the promotions this turn's card holds, as sealed facts for the promo answer.
      const promos: PromoFacts[] = livePromos(currentCard(), now).map((p) => ({ name: p.name, when: dmRange(p.first_night, p.last_night), rate: peso(p.nightly_rate), base: peso(currentCard().base) }));
      const discHint = houseMixed ? `[A house rule is asked (${ruleKind ?? 'pets, parties or guests'}): state it warmly from FACTS, then answer every other question in the message, dates from AVAILABILITY. The host decides exceptions; never grant one.] `
        : haggle && !pureHaggle ? `[The guest also asks for a lower price: code opens the reply with our understanding line and adds the host line. Answer only the rest - their stay figures from the STAY ANCHOR, any other question - never a percentage, a special price or a forward, and do not mention the host.] ${anchor}`
        : promoAsk ? `[Promo ask: your FIRST sentence names ${promos.length ? promos.map((p) => `our ${p.name}, which brings the nights of ${p.when} to ${p.rate} per night instead of the standard ${p.base}`).join('; ') : 'that booking direct is itself our best price'}; then say booking direct is itself the better price: our direct rates are lower than on Airbnb and the other booking apps, and the nightly rate goes lower the longer the stay. No host, no forwarding: this is answered here. Put the question about which dates they have in mind in "ask". Quote no other number and no other "was" price.] ${anchor}`
        : (rateAsked(text) ? anchor : '');
      // SPEC-39 Q2 (default): a nameless first contact with no dates gets the dates question alone - the details step takes the name.
      const nameHint = !thread.guest_name && !followUp && datesKnown.length ? '[Guest name unknown: put one warm question for their name in "ask".] ' : '';
      // Lloyd 2026-09-17 14:30: mid-flow answers read bland and transactional. The model is told where it is and what follows.
      const flowHint = flowFollowUp ? '[The guest is in the middle of booking with us, and their booking summary follows your answer. Reply in two or three warm, unhurried sentences: the answer first, then the one reassurance or offer of help that fits it. No stay details, no amounts, no link, no closing question.] ' : '';
      // SPEC-31 s4 (F4, F7): the hold is open and the QR is out - the booking is arranged; the model answers the question only.
      const payHint = payHold ? `[The guest holds ${dmRange(flow!.checkin!, flow!.checkout!)} under ${flow!.ref} and is paying the ${peso(flow!.deposit ?? 0)} ${(flow!.deposit ?? 0) >= (flow!.total ?? 0) ? 'full amount' : 'reservation fee'} by GCash QR. Answer only what they asked in two or three warm sentences. Payment facts you may state: GCash QR with the amount set; ${MAYA_FACT} A UnionBank transfer only if they ask for a bank (the host sends the account by hand). Never say the booking is confirmed, never promise a reminder or an e-mail, never invite them to the site or to arrange the booking - it is already arranged.] ` : '';
      // SPEC-28: with dates AND another question, the calendar line answers the dates, so the model sees only the other question.
      const asked = flow?.question && flowFollowUp ? otherQuestions(text) || text : text;
      // Session 30 (live): the chat already held "2 guests" from an earlier booking attempt and the model asked again.
      const knownPax = thread.booking_flow?.pax;
      const paxHint = knownPax && !flowFollowUp ? `[Already known from this chat: ${knownPax} guest${knownPax === 1 ? '' : 's'}. Do not ask how many guests again; ask something only if it is truly needed.] ` : '';
      // Golden AFTER 2026-09-30: the rewrites below carried only the pax and dates hints, so a cold-rewritten stay quote lost
      // the code's figures and said "the site will show the total". Every rewrite now carries the same hints as the first draft.
      const hints = nameHint + intentHint(jev) + discHint + capHint + datesHint + paxHint + flowHint + payHint + checkoutHint(text);
      const langHint = LANG_HINT[thisLang === 'bisaya' ? 'bisaya' : lang]; // D-311.8: "reply in English" for a Bisaya guest
      // D-311.6: the haggle hold question - the stay's dates when they are open, else the dates asked.
      let haggleDates: string | null = null;
      if (haggle && stay && sq && sq.nights <= 60) { const n = await bookedNightsFor(db, { ...stay } as Flow); if (n && !n.size) haggleDates = dmRange(stay.checkin, stay.checkout); }
      // "medyo mahal po" reads as English with a courtesy "po": the line keeps that one "po"; the hold question follows the turn's register.
      const haggleL: L3 = l3 === 'tl' || lang === 'english_po' ? 'tl' : 'en', holdL: L3 = l3;
      let out: Draft = pureHaggle ? { reply: haggleLine(haggleL), ask: haggleHold(haggleDates, holdL), uncertain: false } : await draft(thread, hints + langHint + asked, context, 'full', followUp);
      // A name the guest states ("Hi, this is Ben") wins over the Facebook profile name (live
      // 2026-09-13: profile said Löyd, guest said Ben).
      if (out.guest_name && out.guest_name !== thread.guest_name) { console.log('guest_name_from_conversation', out.guest_name, 'was', thread.guest_name); thread.guest_name = out.guest_name; }
      if (NEGATIVE_RE.test(out.reply)) {
        console.error('negative_frame_retry', out.reply.slice(0, 160));
        const fix = `[REWRITE REQUIRED. Your draft opened with a negative ("${out.reply.slice(0, 60).replace(/\n/g, ' ')}..."). The first sentence must name what we DO offer for this wish - e.g. "For swimming po, EM Jake Wave Pool is about 2 km away" instead of "Wala po kaming pool"; "The unit is best suited to 3 adults" instead of "Hindi po pwede ang 4". Do not use "wala", "hindi pwede", "sorry", "unfortunately", "cannot", "not available" anywhere in the reply.] `;
        out = await draft(thread, fix + hints + langHint + asked, context, 'full', followUp).catch(() => out);
      }
      // Session 30: a correct but cold answer is a defect (protocol 08 section 6: answer, context, next step, reassurance,
      // warm close). One rewrite, the same way a negative opener gets one; if it fails we keep the first draft.
      // Golden run 2026-09-17: "How much per night?" (English) got the Taglish reference reply pasted whole. The register
      // is decided in code, so it is checked in code: one rewrite, the same pattern as the negative opener.
      if (offRegister(out.reply, l3)) {
        console.warn('off_register_retry', l3, out.reply.slice(0, 160));
        const fix = l3 === 'en' ? `[REWRITE REQUIRED. ${thisLang === 'bisaya' ? 'Bisaya guests get English replies (D-311) and your draft was in Bisaya or Taglish' : 'The guest wrote in English and your draft was in Taglish'}. Write the whole reply in warm, natural English with contractions${lang === 'english_po' ? ' (one courtesy "po" is welcome)' : ', no "po"'}. Keep every fact. Do not copy a reference reply.] `
          : l3 === 'bis' ? `[REWRITE REQUIRED. The guest writes Bisaya and your draft used Tagalog words. Write it in natural Bislish: no "po", no "kayo", "namin", "dito", "hindi". Keep every fact.] `
          : `[REWRITE REQUIRED. The guest wrote in Tagalog / Taglish and your draft was plain English. Write it in natural Taglish with "po" once or twice, English for the hospitality and money terms. Keep every fact.] `;
        out = await draft(thread, fix + hints + langHint + asked, context, 'full', followUp).catch(() => out);
      }
      if (!flowFollowUp && isCold(out.reply)) {
        console.warn('cold_reply_retry', out.reply.slice(0, 160));
        const warm = `[REWRITE REQUIRED. Your draft was correct but read as blunt and transactional. Keep every fact. Write it the way a calm boutique-hotel concierge would type it in chat: the answer first; then one sentence that shows care or preparation done for the guest ("we'll have it ready", "so you can settle in without a second thought"). Natural contractions. No sales language, no "no pressure", no exclamation words, no second invitation.] `;
        out = await draft(thread, warm + hints + langHint + asked, context, 'full', followUp).catch(() => out);
        // D-311.8 (golden reg-bot-bis: a short rate answer stayed cold after the rewrite): one warm clause, from code.
        if (isCold(out.reply)) out.reply = `${out.reply.trimEnd()} ${warmClause(l3)}`;
      }
      // D1: a haggle inside a wider message - code's understanding line first, the model's answer, the hold question; the host line
      // is compose()'s alone, so any forward the model wrote anyway goes (said exactly once).
      if (haggle && !pureHaggle) out = { ...out, reply: `${haggleLine(haggleL)}\n\n${dropForward(out.reply)}`, ask: haggleHold(haggleDates, holdL) };
      // K18 (D-182): the early check-in fee is computed in code; a contradicting peso figure is corrected (mid-flow too:
      // this runs on the answer before the flow's card is added).
      const feeFixed = fixEarlyFee(out.reply, text);
      if (feeFixed !== out.reply) { console.warn('early_fee_guard', out.reply.slice(0, 160)); out.reply = feeFixed; }
      // SPEC-32 s1b (D-247, F15): UnionBank only when the guest asked for a bank or another way to pay.
      const bankless = dropBankUnlessAsked(out.reply, text);
      if (bankless !== out.reply) { console.warn('bank_unasked_dropped', out.reply.slice(0, 160)); out.reply = bankless; }
      // Lloyd 2026-09-17: a day another guest checks out never gets the 12 noon check-in (golden run 2026-09-25 offered it).
      if (offersEarlyCheckin(out.reply)) {
        const stay = stayFrom(guestTexts, now);
        // D-290: a chained stay's junction day has no turnover, so the 12 noon guard does not apply to it (turnoverOn).
        if (stay && await turnoverOn(db, stay.checkin, 'turnover_guard')) {
          console.warn('turnover_noon_guard', JSON.stringify({ day: stay.checkin, reply: out.reply.slice(0, 160) }));
          out.reply = setTurnoverCheckin(out.reply, turnoverCheckinLine(pretty(stay.checkin), l3));
        }
      }
      // K18 (D-182): outside the book flow, a draft that calls the guest's dates open is checked against the calendar in
      // code, before the post-processing below. A booked night gets ONE rewrite around the flow's approved line (golden
      // run 6: a bare sentence swap left a rate quote and "secure your dates" beside "already reserved"); an unreadable
      // calendar gets the "we're checking" line and the OPS glance card. The code's line wins either way.
      if (!flowFollowUp && claimsOpen(out.reply)) {
        const stay = stayFrom(guestTexts, now);
        if (stay) {
          const f: Flow = { step: 'dates', ...stay, lang: l3, started_at: now.toISOString(), updated_at: now.toISOString() };
          const nights = await bookedNightsFor(db, f);
          if (!nights || nights.size) {
            const line = availabilityLine(f, nights, nights && nights.size ? await nearestWindow(db, f) : null);
            console.warn('availability_guard', JSON.stringify({ stay, down: !nights, reply: out.reply.slice(0, 160) }));
            const swapped = setAvailability(out.reply, line);
            if (nights) {
              const fix = `[REWRITE REQUIRED. The calendar (checked in code) shows these dates are already reserved; your draft said they were open. Put this sentence, word for word, at the start of your answer: "${line}" Then answer anything else the guest asked. Then one sentence of care (for example, that we'd be glad to welcome them on dates that suit). Do not quote a rate or total for these dates and do not invite the guest to secure or book these dates. Keep every other fact.] `;
              const re = await draft(thread, fix + paxHint + LANG_HINT[lang] + asked, context, 'full', followUp).catch(() => null);
              out.reply = re && re.reply.includes(line) && !claimsOpen(re.reply.replace(line, '')) ? re.reply : swapped; // run 8: accept only the full line, never swap it in twice
            } else { out.reply = swapped; flagOnly = true; } // OPS gets the glance card, as on the flow path
          } else openStay = { checkin: stay.checkin, lang: l3 }; // the calendar agrees the stay is open: the turnover notice may follow
        }
      }
      // D-286 (DESIGN-model-answers-code-composes-2026-09-30): the model wrote only the answer. The fact guards above ran on
      // it; the content guards below still do; compose() writes the greeting, the ONE next step and the close around it.
      // The seventeen frame repairs that stood here (greeting, intro, link strips, nudges, the chat route, the look block
      // placement, the paragraph fit) are retired - the frame is written once, by code.
      // The content guards on the model's answer (the English fallback below goes through the same ones).
      const guard = (a: string, english: boolean) => {
        // A guest who calls US "Ma'am"/"Sir" does not become "Ma'am Löyd" (live 2026-09-13, twice
        // despite the prompt rule): drop a title the model put before their name in that case.
        if (thread.guest_name && /\b(ma'?am|sir|maam)\b/i.test(text)) a = a.replace(new RegExp(`\\b(ma'?am|sir)\\s+(?=${thread.guest_name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b)`, 'giu'), '');
        a = gladNotHappy(plainText(redactAddress(a)));
        if (english) a = noPo(contractions(a), lang === 'english_po' ? 1 : 0); // protocol 08: natural contractions; D-311.5: no "po" in English
        else if (l3 === 'tl') a = kusang(a); // D-311.7: "automated" is a robot word
        if (knownPax && !flowFollowUp) a = dropPaxAsk(a);
        if (thread.guest_name) a = dropNameAsk(a); // golden run 2: the model asked a guest we already know for their name
        if (payHold) { const held = payHoldReply(a, paidClaimReply(flow!, flow!.name ?? thread.guest_name, l3), SITE_URL); if (held !== a) console.warn('pay_hold_guard', a.slice(0, 160)); a = held; }
        return a;
      };
      let answer = guard(out.reply, lang === 'english' || lang === 'english_po');
      if (promoAsk) answer = promoFirst(answer, promos, l3); // D-311.1: the live promotions and the direct price, first paragraph
      if (flowFollowUp) { answer = dropPassingRange(answer, flowFollowUp); flowFollowUp = dedupeAvailability(answer, flowFollowUp); } // D-311.5: the dates said open once
      const reviewsShown = thread.history.filter((h) => h.role === 'bot').some((h) => h.text.includes(AIRBNB_URL));
      const quiet = payHold || stayingNow || hostOpen.length > 0;
      // D-269: the discount host line is said once per thread (in any register, any wording it has had), closing the answer.
      const hostSaid = thread.history.some((h) => h.role === 'bot' && (Object.values(DISCOUNT_HOST_PAST).some((x) => h.text.includes(x)) || h.text.includes(HANDOFF.policy_exception)));
      if (hostAsk) { handoff = true; risk = 'policy_exception'; }
      const frame = (l: typeof l3) => ({
        lang: l, name: thread.guest_name, greet: !everAnswered, greetNow, followUp, flowFollowUp, quiet,
        // D-300.2 trigger 2 mid-booking: the photos and the site once, then the flow's own ask.
        seeHome: flowFollowUp && !quiet && !siteShown && SEE_RE.test(text) ? seeHomeLine(thread.guest_name, l) : '',
        hostLine: hostAsk && !hostSaid ? discountHostLine(l) : '',
        // SPEC-13 / D-176 / D-300.2: look before you book - photos or reviews asked for, and not shown in this stretch.
        look: flowFollowUp || hostAsk || quiet || risk !== 'routine' ? '' : lookNudge(text, l, { site: siteShown, reviews: reviewsShown }),
        decision: followUp && /\b(think about|decide|consider|book|reserve|reservation|magpa-?book|paano (po )?mag)\b/i.test(text), // a decision moment leaves the door open with the link
        linkTurn: !hostAsk && linkTurn(text, jev, now), // D-300.2: the site only when the guest asks for what it answers
        siteShown, // D-269: never twice in one stretch of conversation
        datesKnown: datesKnown.length > 0, held: { dates: datesKnown.length > 0, pax: !!knownPax, name: !!thread.guest_name }, prevBot: lastBot?.text ?? '',
      });
      // s73 F5 (D-297.3; golden fu-chat-yes-en: a dated price answer closed on nothing, so "Yes please" had no offer to accept):
      // it closes on the flow's own hold question, which bookingStart's CHAT_OFFER_RE knows - only while the calendar shows
      // the stay open (never an offer to hold a taken night).
      let holdQ = stay && sq && sq.nights <= 60 && !capHint && !flow && !hostAsk && !promoAsk && !quiet && priceAsked(text) ? // R2-5, R2-8
         holdOffer(sq.nights === 1, l3, false) : null;
      if (holdQ) { const n = await bookedNightsFor(db, { ...stay } as Flow); if (!n || n.size) holdQ = null; }
      let composed = compose({ answer, ask: holdQ ?? out.ask ?? null }, frame(l3));
      // Lloyd 2026-09-30 ("if it's too long then use the english reply"; D-245: English passes for a Taglish guest): a Taglish
      // message over 700 characters (a first-reply stay quote is ~655 of code-owned text) is drafted again in English and sent
      // when shorter. The English draft goes through the same guards; one that claims dates open or offers an early check-in
      // is not used, as the calendar guards above ran on the Taglish draft only.
      if (l3 === 'tl' && composed.reply.length > 700) {
        const en = await draft(thread, `[Your Taglish answer made the message too long for chat. Write the whole answer in warm, natural English with contractions and no "po". Keep every fact and figure exactly.] ${hints}${asked}`, context, 'full', followUp).catch(() => null);
        const enAnswer = en ? guard(fixEarlyFee(dropBankUnlessAsked(en.reply, text), text), true) : '';
        if (en && enAnswer && !claimsOpen(enAnswer) && !offersEarlyCheckin(enAnswer)) {
          const c2 = compose({ answer: enAnswer, ask: holdQ ? holdOffer(sq!.nights === 1, 'en', false) : en.ask ?? null }, frame('en'));
          if (c2.reply.length < composed.reply.length) { console.warn('tl_too_long_english', JSON.stringify({ psid, tl: composed.reply.length, en: c2.reply.length })); composed = c2; }
        }
      }
      if (composed.stripped.length) console.log('frame_stripped', JSON.stringify({ psid, stripped: composed.stripped }).slice(0, 500)); // how often the model still writes a frame
      if (composed.fitted) console.warn('frame_fit', JSON.stringify({ psid, answer: answer.slice(0, 200) }));
      reply = composed.reply;
      // A model-flagged uncertainty used to silence the bot for 24 h right after it had answered
      // (live test 2026-09-12: a warm reply about a mother's recovery, then silence). Now it only
      // alerts the host; the conversation continues, and the host can still take over by replying.
      // s73 F6 (golden fu-objection-dated-en, fu-mahal-tl): a model unsure about a price proposal turned the host card's
      // policy_exception into "uncertain". A turn already going to the host keeps its own risk.
      if (out.uncertain && !handoff) { flagOnly = true; risk = 'uncertain'; }
    } catch (e) {
      console.error('draft_failed', String(e).slice(0, 400));
      handoff = true; risk = 'uncertain'; reply = HANDOFF.uncertain; draftNote = draftFailureNote(e);
    }
  }

  const sentToGuest = Boolean(reply) && mode === 'auto';
  // D-281: one "Reach my host" button, only when the guest seems to be staying now (named the in-house guest, asked for the
  // host, said they are staying, or speaks for the guest with an urgent matter). DESIGN-contact-host-button-2026-09-28.
  let hostChip: typeof CONTACT_CHIP | null = null;
  if (reply && text && !houseAskSent) {
    const today = new Date(now.getTime() + 8 * 3_600_000).toISOString().slice(0, 10);
    const { data: inHouse } = await db.from('calendar_events').select('guest_name, raw_summary').eq('status', 'confirmed').lte('checkin_date', today).gte('checkout_date', today).limit(4);
    hostChip = contactHostChip(text, {
      risk, profileName: thread.guest_name, inHouse: ((inHouse ?? []) as { guest_name: string | null; raw_summary: string | null }[]).map((r) => r.guest_name || r.raw_summary || ''),
      flowActive: isActive(thread.booking_flow, now) || !!flow, priorityOpen: hostOpen.some((h) => h.risk === 'priority'), history: thread.history, now,
    });
  }
  let lint: string[] = []; // D-285: hoisted for the turn's stats row
  if (reply) {
    // Mid-flow (session 28 T6): the guest is already booking here - no site invite after the answer, and the composite
    // (model answer + card) is not lint-scored as one message. D-300.2: the confirm card no longer carries the site.
    if (flowFollowUp) reply = reply.split(/\n\s*\n/).filter((p) => !/^(O maaari rin po kayong mag-check|Or you may check and secure|Kapag handa na po kayo, maaari|Kapag ready po kayo|We can arrange (the booking|everything)|Whenever you feel ready|👉 |Mas mababa po ang rate kapag direct|Direct bookings enjoy our best rates)/.test(p.trim())).join('\n\n');
    // D-299.10 / D-300.1: the initial message of a conversation (no bot reply in 12 h) is signed - the composed reply signs
    // itself; every other code-written initial message is signed here, on the same greetNow flag. Never a handoff, a card or a QR turn.
    // Incident 2026-10-07 (Angel: Oct 8 confirmed open "as soon as you arrive" on another guest's check-out day): the turnover
    // notice beside the availability, once. One calendar read; a failed one leaves the line out (turnoverOn).
    if (openStay && await turnoverOn(db, openStay.checkin, 'turnover_notice')) {
      // Fable audit 5d73694: a Taglish flow the model answered in English takes the English notice (no mixed register).
      const nl = openStay.lang === 'tl' && offRegister(reply, 'tl') ? 'en' : openStay.lang;
      const withNotice = addTurnoverNotice(reply, pretty(openStay.checkin), turnoverNotice(pretty(openStay.checkin), nl));
      if (withNotice !== reply) console.log('turnover_notice', JSON.stringify({ psid, day: openStay.checkin }));
      reply = withNotice;
    }
    reply = nameOnce(reply, thread.guest_name); // D-311.5: the greeting named the guest, so no paragraph opens on the name again
    if (greetNow && !handoff && !flowImage) reply = signFirst(reply, true);
    lint = flowFollowUp ? [] : lintReply(reply, text, { firstTurn: !thread.history.length, name: thread.guest_name, cap: stayPayTurn ? STAY_PAY_CAP : undefined });
    if (lint.length) console.warn('voice_lint', JSON.stringify({ psid, lint, reply: reply.slice(0, 160) }));
    // Lloyd 2026-09-28: an emergency or a lockout is never left to a draft - whatever the mode (a failed settings read
    // falls back to 'suggest', D-222), the guest gets the safety or access line and the host the card and the urgent alert.
    const urgentNow = handoff && (risk === 'safety' || risk === 'access');
    if (mode === 'auto' || urgentNow) {
      await fx.send(psid, reply, hostChip ? [hostChip] : []);
      if (flowImage) {
        await fx.qr(psid, flow, flowImage);
        // SPEC-10 control 6: the payment promise, as its own message under the QR. It rides with the
        // QR rather than with paymentReply because that reply is already near lintReply's 700-character
        // cap, and because this is the moment the guest is looking at the QR wondering whose account
        // it is. Sent only when a QR was sent, so it cannot leak into an ordinary answer.
        if (promiseAfterQr) await fx.send(psid, paymentPromise(flow?.lang));
      }
    }
    else { await fx.send(psid, ACK_SUGGEST, hostChip ? [hostChip] : []); await fx.ops(withHeader('guest', `draft · ${risk}`, `💬 Concierge draft (${risk})\nGuest: ${thread.guest_name ?? psid}\n> ${text.slice(0, 300)}\n\nSuggested reply:\n${reply}\n\n${link}`)); }
    if (handoff) {
      // A discount or pet request goes to the host, but it must not mute the bot for 24 h: a
      // prospect who then asks about Wi-Fi still gets an answer (live guest, 2026-09-13). The hold
      // stays for existing-booking matters (payment, refund, cancellation, complaint, safety, access).
      // 2026-09-13 (Lloyd): no automatic hold on a handoff. The bot keeps answering the guest's
      // other questions, remembers what is pending with the host (see pendingBlock), and pauses
      // only when a human actually replies from the inbox (echo) - or on a safety report.
      // D-317 review: a safety report no longer sets human_until (that now means a host is handling the chat); the open safety
      // handoff itself holds routine chat for 24 h (see hostOpen above).
      if (mode === 'auto' || urgentNow) {
        if (text || card) await fx.handoff(db, thread, text || '[photo: likely a payment receipt]', risk, link, draftNote, card?.anyWording);
        else await fx.ops(withHeader(hostOpen.some((h) => h.risk === 'access' || h.risk === 'safety') ? 'alert' : 'guest', 'handoff · attachment', `🛎 Concierge handoff (attachment)\nGuest: ${thread.guest_name ?? psid}\n> [attachment]\n\n${link}`)); // SPEC-31 s3: a photo, not an uncertainty
      }
    } else if (flagOnly && mode === 'auto') {
      await fx.ops(withHeader('guest', 'glance', `👀 ${calendarDown ? 'The calendar could not be read: the guest was told we will confirm the dates. Please check and reply.' : 'Concierge answered but wants a host to glance'}\nGuest: ${thread.guest_name ?? psid}\n> ${text.slice(0, 300)}\n\nBot replied:\n${reply.slice(0, 500)}\n\n${link}`));
    }
  }

  const turns: Turn[] = [{ role: 'guest', text: said || '[attachment]', at: now.toISOString(), ...(jev ? { route: { re: g0.risk, jev: jev.intent, c: +jev.confidence.toFixed(2), h: +jev.needsHost.toFixed(2), l: jev.lang, rl: guestLang(text), up: jevRisk !== g0.risk } } : {}) }];
  if (sentToGuest) turns.push({ role: 'bot', text: reply, at: now.toISOString(), ...(hostChip ? { route: { chip: hostChip.payload } } : houseAskSent ? { route: { house: 1, q: text } } : {}) });
  await db.from('concierge_threads').upsert({
    psid, guest_name: thread.guest_name, human_until: thread.human_until,
    bot_turns: priorTurns + (sentToGuest && !handoff && !flowReply ? 1 : 0),
    history: [...thread.history, ...turns].slice(-HISTORY_KEEP * 2), last_risk: risk, updated_at: now.toISOString(),
    booking_flow: thread.booking_flow ?? null,
    last_mid: msg.mid ?? thread.last_mid ?? null,
    ...(thread.verified_until !== undefined ? { verified_until: thread.verified_until } : {}),
  });
  // D-285: one stats row per guest turn for the Monday card. Advisory: a failed write never costs the reply or the history.
  try {
    const { error } = await db.from('concierge_turn_stats').insert(turnStats({ psid, text, replied: !!g.reply, lint: sentToGuest ? lint : [], jev, house, houseLocked, re: g0.risk, up: jevRisk !== g0.risk }));
    if (error) console.error('turn_stats_failed', String(error.message ?? error).slice(0, 160));
  } catch (e) { console.error('turn_stats_failed', String(e).slice(0, 160)); }
}

// Session 59 (Lloyd 2026-09-28, "we're over complicating things ... revert to previous without any menu"): ?profile=get reads
// the Page's Messenger profile and webhook fields; ?profile=set CLEARS the persistent menu and the Get Started button (the
// chat is a plain text box again) and keeps the app's webhook fields (postbacks and m.me referrals still reach the bot -
// the welcome guide's priority link and the contact-host button use them). Probe-secret gated.
const PAGE_FIELDS = ['messages', 'message_echoes', 'messaging_postbacks', 'messaging_referrals'];
async function messengerProfile(set: boolean): Promise<Response> {
  const tok = env('META_PAGE_TOKEN'), app = `${env('META_APP_ID')}|${env('META_APP_SECRET')}`;
  const get = async (u: string) => (await fetch(u, { signal: AbortSignal.timeout(10_000) })).json().catch(() => ({}));
  const post = async (u: string, b: unknown) => (await fetch(u, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(b), signal: AbortSignal.timeout(15_000) })).json().catch(() => ({}));
  const read = async () => ({
    profile: await get(`${GRAPH}/${PAGE_ID}/messenger_profile?fields=get_started,persistent_menu,ice_breakers,greeting&access_token=${tok}`),
    page_fields: await get(`${GRAPH}/${PAGE_ID}/subscribed_apps?access_token=${tok}`),
    app_fields: await get(`${GRAPH}/${env('META_APP_ID')}/subscriptions?access_token=${app}`),
  });
  const before = await read();
  if (!set) return new Response(JSON.stringify(before, null, 1), { headers: { 'Content-Type': 'application/json' } });
  const out: Record<string, unknown> = {};
  out.profile = await (await fetch(`${GRAPH}/${PAGE_ID}/messenger_profile?access_token=${tok}`, {
    method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ fields: ['persistent_menu', 'get_started'] }), signal: AbortSignal.timeout(15_000),
  })).json().catch(() => ({}));
  const sub = ((before.app_fields as any)?.data ?? []).find((x: any) => x.object === 'page');
  const appHave: string[] = (sub?.fields ?? []).map((f: any) => f.name);
  if (sub?.callback_url && !PAGE_FIELDS.every((f) => appHave.includes(f))) {
    out.app_fields = await post(`${GRAPH}/${env('META_APP_ID')}/subscriptions?access_token=${app}`, { object: 'page', callback_url: sub.callback_url, verify_token: env('META_VERIFY_TOKEN'), fields: [...new Set([...appHave, ...PAGE_FIELDS])].join(',') });
  }
  out.after = await read();
  return new Response(JSON.stringify(out, null, 1), { headers: { 'Content-Type': 'application/json' } });
}

/** Scripted turns through the real handle() on a fresh probe: thread; every outward effect is recorded, none is made.
 *  body: { psid: "probe:<uuid>", name?: string, now?: iso, turns: Array<string | { text?: string, image?: true, advance_minutes?: number }> } */
async function runProbe(body: string): Promise<Response> {
  const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } });
  let p: { psid?: string; name?: string; now?: string; golden?: boolean; turns?: Array<string | { text?: string; image?: boolean; advance_minutes?: number }>; history?: Array<{ role?: string; text?: string }>; flow?: unknown };
  try { p = JSON.parse(body); } catch { return json({ ok: false, error: 'bad_json' }, 400); }
  const psid = String(p.psid ?? '');
  if (!/^probe:[A-Za-z0-9-]{8,64}$/.test(psid) || !Array.isArray(p.turns) || !p.turns.length || p.turns.length > 12) return json({ ok: false, error: 'probe_psid_and_1_to_12_turns_required' }, 400);
  const db: Db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
  dbForLandmarks = db;
  let now = p.now && Date.parse(p.now) ? new Date(p.now) : new Date();
  const out: unknown[] = [];
  // D-254: probes never spend the guests' budget; golden runs have a key of their own (Lloyd 2026-09-26).
  setProviderKey((p.golden ? env('CASCADE_OPENROUTER_GOLDEN_RUN_KEY') : '') || env('CASCADE_OPENROUTER_PROBE_KEY') || null);
  const totals = probeTotals(); // S74: cost and cache hits of this probe's own model calls
  try {
    await db.from('concierge_threads').delete().eq('psid', psid); // a fresh thread, always
    // D-269: Cassy's reply helper seeds the conversation a host pasted (guest and host lines, oldest first), so the brain
    // answers the newest guest message with the thread behind it - two minutes apart, ending three minutes ago.
    const seed = (p.history ?? []).filter((h) => h?.text && (h.role === 'guest' || h.role === 'bot')).slice(-HISTORY_KEEP * 2);
    // SPEC-38 s8: a Cassy reply for a request already submitted seeds the booking flow too (validated; probe path only).
    const flowSeed = seedFlow(p.flow);
    if (seed.length || flowSeed) await db.from('concierge_threads').upsert({ psid, guest_name: p.name ?? null, bot_turns: seed.filter((h) => h.role === 'bot').length, updated_at: now.toISOString(),
      ...(flowSeed ? { booking_flow: { ...flowSeed, booking_id: 'probe', started_at: now.toISOString(), updated_at: now.toISOString() } } : {}),
      history: seed.map((h, i) => ({ role: h.role, text: String(h.text).slice(0, 1500), at: new Date(now.getTime() - (3 + 2 * (seed.length - 1 - i)) * 60_000).toISOString() })) });
    for (const [i, t] of p.turns.entries()) {
      const turn = typeof t === 'string' ? { text: t } : t;
      now = new Date(now.getTime() + (turn.advance_minutes ?? 1) * 60_000);
      const message: Record<string, unknown> = { mid: `probe-${i}`, text: turn.text ?? undefined };
      if (turn.image) message.attachments = [{ type: 'image', payload: { url: 'https://example.invalid/receipt.jpg' } }];
      const calls: ProbeCall[] = [], t0 = Date.now();
      // Session 59: "[PRIORITY]" probes the menu button (a postback, no message); "[PRIORITY:<yyyy-mm-dd>:<initial>]" the guide link.
      const pri = /^\[PRIORITY(?::([^\]]+))?\]$/.exec(turn.text ?? '');
      if (turn.text === `[CHIP:${CONTACT_CHIP.title}]`) { message.text = CONTACT_CHIP.title; message.quick_reply = { payload: CONTACT_CHIP.payload }; } // D-281 tap
      const ev = pri ? (pri[1] ? { sender: { id: psid }, recipient: { id: PAGE_ID }, referral: { ref: `priority:${pri[1]}` }, timestamp: now.getTime() } : { sender: { id: psid }, recipient: { id: PAGE_ID }, postback: { payload: 'PRIORITY', mid: `probe-${i}` } })
        : { sender: { id: psid }, recipient: { id: PAGE_ID }, message };
      await handle(db, ev, 'auto', probeEffects(calls, p.name ?? null, now), now);
      const { data: row } = await db.from('concierge_threads').select('booking_flow, last_risk, guest_name').eq('psid', psid).maybeSingle();
      const reply = calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n');
      out.push({ guest: turn.text ?? '[image]', reply, step: row?.booking_flow?.step ?? null, flow_lang: row?.booking_flow?.lang ?? null, risk: row?.last_risk ?? null,
        effects: calls.filter((c) => c.fx !== 'send'), chips: calls.filter((c) => c.fx === 'send').flatMap((c) => (c.detail as { chips?: string[] } | undefined)?.chips ?? []), lint: lintReply(reply, turn.text ?? '', { firstTurn: i === 0, name: row?.guest_name ?? null }), ms: Date.now() - t0 });
    }
    return json({ ok: true, voice_compact_chars: voiceCompact().length, cost_usd: totals.cost_usd, cached_tokens: totals.cached, input_tokens: totals.input, turns: out });
  } catch (e) {
    return json({ ok: false, error: String(e).slice(0, 300), turns: out }, 500);
  } finally {
    setProviderKey(null);
    await db.from('concierge_threads').delete().eq('psid', psid);
  }
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === 'GET') {
    const want = env('META_VERIFY_TOKEN');
    const ok = Boolean(want) && url.searchParams.get('hub.mode') === 'subscribe' && url.searchParams.get('hub.verify_token') === want;
    return ok ? new Response(url.searchParams.get('hub.challenge') ?? '', { status: 200 }) : new Response('forbidden', { status: 403 });
  }
  if (req.method !== 'POST') return new Response('method_not_allowed', { status: 405 });

  // Ops path: Telegram updates forwarded by telegram-expense, authenticated with the same
  // webhook secret Telegram uses for that function (Edge secrets are project-wide).
  if (url.searchParams.get('ops') === '1') {
    const want = env('TELEGRAM_WEBHOOK_SECRET');
    if (!want || req.headers.get('x-telegram-bot-api-secret-token') !== want) return new Response('unauthorized', { status: 401 });
    const db: Db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
    try { await handleOps(db, await req.json()); } catch (e) { console.error('ops_failed', String(e).slice(0, 300)); }
    return new Response('ok', { status: 200 });
  }

  const body = await req.text();
  // Probe: header-gated, probe: psids only, sends nothing. A missing or wrong header falls through to the HMAC check,
  // which rejects it, so the probe adds no unauthenticated surface.
  const probeSecret = env('CASCADE_PROBE_SECRET'), probeHeader = req.headers.get('x-cascade-probe');
  if (probeSecret.length >= 24 && probeHeader === probeSecret) return url.searchParams.get('profile') ? await messengerProfile(url.searchParams.get('profile') === 'set') : await probeScope(() => runProbe(body));
  if (!(await hmacOk(env('META_APP_SECRET'), body, req.headers.get('x-hub-signature-256')))) return new Response('bad signature', { status: 401 });

  const db: Db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
  dbForLandmarks = db;
  // D-222: one retry, and a failed read is 'suggest' (holding line + host draft), never a silent 'off' (live 2026-09-13).
  const readSettings = () => db.from('app_settings').select('key, value').in('key', ['concierge_mode', 'gemini_cooldown_until']);
  let { data: settings, error: settingsErr } = await readSettings();
  if (settingsErr || !settings?.length) ({ data: settings, error: settingsErr } = await readSettings());
  if (settingsErr || !settings?.length) console.error('settings_read_failed', String(settingsErr?.message ?? 'no rows').slice(0, 120));
  const mode = modeFrom(settingsErr ? null : settings);
  // Gemini circuit breaker state lives in app_settings so it survives cold isolates (D-103).
  const cooldown = (settings ?? []).find((s: any) => s.key === 'gemini_cooldown_until');
  geminiBreaker.until = typeof cooldown?.value === 'string' ? (Date.parse(cooldown.value) || 0) : 0;
  geminiBreaker.trip = async (until) => { await db.from('app_settings').upsert({ key: 'gemini_cooldown_until', value: new Date(until).toISOString() }); };

  let payload: { entry?: Array<{ messaging?: Array<Record<string, any>> }> };
  try { payload = JSON.parse(body); } catch { return new Response('ok', { status: 200 }); }

  for (const ev of payload.entry?.flatMap((e) => e.messaging ?? []) ?? []) {
    try { await handle(db, ev, mode); } catch (e) {
      console.error('concierge_event_failed', String(e).slice(0, 200));
      // D-222: a failed turn must reach a person - before this, an exception ended in silence for the guest.
      const who = ev?.sender?.id ? `https://www.facebook.com/messages/t/${ev.sender.id}` : '(no sender)';
      await liveEffects.ops(withHeader('guest', 'failed', `⚠️ A Messenger message could not be handled automatically. Please read it and reply by hand.\n\n${who}`)).catch(() => {});
    }
  }
  return new Response('EVENT_RECEIVED', { status: 200 });
});
