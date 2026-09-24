// Concierge communication protocol, the part code can check (session 28, 2026-09-17).
// Source: docs/concierge-communication-protocol.md. Three moves in every reply, in this order:
//   1. ANSWER   - if the guest asked something, the first sentences answer it (never skipped by a flow)
//   2. ACKNOWLEDGE - the person before the fact: name, "po", what they told us
//   3. ADVANCE  - one ask at most, and the guest is never left without a next step
// lintReply() is run over every canned prompt in voice.test.ts (fails the build) and over every
// outgoing reply at runtime (warn-only log `voice_lint`, so live drift is visible without blocking).

import { CASSY_INTRO, greeting } from './booking.ts';
import { AIRBNB_URL, SITE_URL } from '../_shared/cascade-core/facts.ts';

export type Violation = 'no_answer' | 'form_speak' | 'two_asks' | 'too_long' | 'cold_opener' | 'robot_word' | 'shouting' | 'too_dense' | 'command_tone' | 'exclaim' | 'boilerplate';

const QUESTION_RE = /\?|\b(is it|are there|do you|does it|can we|can i|may i|pwede|meron|may (?:\w+ )?ba|magkano|how (much|far|many|long)|available|avail|bakante)\b/i;
const FORM_RE = /^\s*(your|enter|provide|input|type)\s+(mobile|number|phone|e-?mail|name|date)/i;
const ROBOT_RE = /\b(as an ai|language model|bot|automated|process(ing)? (your )?(booking|request)|ticket|form)\b/i;
const COLD_RE = /^\s*(what|which|when|how many|your)\b[^.!]*\?\s*$/i;
// Cassy persona (D-167): guide, never command; no exaggerated enthusiasm.
const COMMAND_RE = /(^|\n|[.!?]\s+)(send|reply|tap|enter|pay|scan|upload|click)\s+(me|us|the|your|a|an|₱|\d|it|here|now|deposit|full)\b/i;
const EXCLAIM_RE = /\b(wonderful|amazing|awesome|lovely|fantastic|great news|good news|napakagandang|lubos (po )?kaming nagagalak|ikinagagalak)\b|!{2,}/i;
// D-168 section 22: corporate / translated filler a real host would never type.
const BOILERPLATE_RE = /\b(rest assured|please be advised|kindly|absolutely|certainly|great question|happy to help|at your earliest convenience|do not hesitate|utmost (pleasure|satisfaction)|valued (customer|guest)|esteemed guest|highly value your patronage|any inconvenience this may have caused|nagagalak|ipabatid|pahingi|pakibigay|pasayloa kami sa dakong)\b/i;

// Session 29 (live, "is there parking?" at confirm): the model echoed the stay card from history and rephrased the site
// invite, so the card went out twice with an invite between. When the flow's own ask follows, only the answer is kept.
const FLOW_NOISE_RE = /^(here are your stay details|here's your stay|ito po ang details|mao ni ang details|📅|📞|💰|💳|to secure (your|the) stay|para ma-secure|👉)|https?:\/\/|\b(our|sa) site\b|\bdirect(ly)? book|\bdetails\b[^\n]{0,20}\bstay\b|\bstay details\b|· \d+ nights?\b|^\W{0,4}total ₱|ready whenever you are/i;
const CLOSER_RE = /\s*[^.!?\n]*\b(any (other|more|further) questions|(iba|uban|ubang|lain|laing)\b[^.!?\n]{0,25}(katanungan|questions?|tanong|pangutana)|mag-atubili)\b[^.!?\n]*[.!?]?/gi;
/** The model's answer without an echoed card, a site invite or an "any other questions" closer. Never returns ''. */
export function answerOnly(reply: string): string {
  const paras = reply.split(/\n\s*\n/);
  const cut = paras.findIndex((p) => FLOW_NOISE_RE.test(p.trim()));
  return (cut < 0 ? paras : paras.slice(0, cut)).join('\n\n').replace(CLOSER_RE, '').trim() || paras[0].trim();
}

/** Protocol 07 section 4: "po" is purposeful, one or two per message. The model's Taglish parking answer carried six
 *  (live, session 29). "po" is an enclitic, so dropping the extras leaves every sentence intact; "opo"/"pong" are untouched. */
export function thinPo(text: string, keep = 2): string {
  let n = 0;
  return text.replace(/ po\b/g, (m) => (++n > keep ? '' : m));
}

// Session 30 (live 2026-09-17 18:25, "hello, available Oct 20 to 22?"): the reply read "…directly on our site:" with no
// link under it, then two more nudges ("Direct bookings offer…", "No pressure at all…"), in stiff uncontracted English.
const SOFT_NUDGE_RE = /\b(no pressure|whenever you(?:'d| would) like to secure|here whenever you(?:'re| are) ready|walang pressure|kapag handa na (po )?kayo)\b/i;
const CONTRACTIONS: Array<[RegExp, string]> = [
  // Not after a preposition: "window for you would be" became "for you'd be", "how many of you will" became "of you'll" (golden run 2026-09-17).
  [/(?<!\b(?:for|to|of|with|from) )\b(We|we|You|you|I|They|they) would\b/g, "$1'd"], [/(?<!\b(?:for|to|of|with|from) )\b(We|we|You|you|They|they) are\b/g, "$1're"], [/(?<!\b(?:for|to|of|with|from) )\b(We|we|You|you|I|They|they) will\b/g, "$1'll"],
  [/\b(We|we|You|you|I|They|they) have\b(?= (?:been|already|prepared|arranged|noted|set|reserved))/g, "$1've"], [/\b(It|it|That|that|There|there) is\b/g, "$1's"],
  [/\b(D|d)o not\b/g, "$1on't"], [/\b(D|d)oes not\b/g, "$1oesn't"], [/\b(C|c)annot\b/g, "$1an't"], [/\b(I|i)s not\b/g, "$1sn't"],
];
/** Code-owned polish for a model reply (D-097: prompt rules alone fail). An invite sentence that ends in ":" always has
 *  its link under it; when the site is offered, the soft "no pressure" paragraphs go (one invitation per message,
 *  protocol rule 4); English replies use contractions (protocol 08). Pure, so it is tested. */
export function tidyReply(reply: string, siteUrl: string, english: boolean): string {
  let paras = reply.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  for (let i = 0; i < paras.length; i++) {
    if (!/:\s*$/.test(paras[i])) continue;
    const next = paras[i + 1] ?? '';
    if (/^(👉|https?:\/\/|🏡|⭐|📅|•|-)/.test(next)) continue;          // the colon is followed by what it promised
    if (/\b(site|website|link)\b/i.test(paras[i])) paras.splice(i + 1, 0, `👉 ${siteUrl}`);
    else paras[i] = paras[i].replace(/\s*:\s*$/, '.');
  }
  for (let i = 1; i < paras.length; i++) {
    if (/^(👉|https?:\/\/)/.test(paras[i]) && !/:\s*$/.test(paras[i - 1]) && /\b(site|website)\b/i.test(paras[i - 1])) paras[i - 1] = paras[i - 1].replace(/[\s.🌿💚😊]*$/u, ':');
  }
  if (paras.some((p) => p.includes(siteUrl))) paras = paras.filter((p, i) => i === 0 || !SOFT_NUDGE_RE.test(p) || p.includes(siteUrl));
  let out = paras.join('\n\n');
  if (english) for (const [re, to] of CONTRACTIONS) out = out.replace(re, to);
  return out;
}

// Session 30 (Lloyd: "it would always revert back to blunt transactional responses"): every rule so far REMOVED something,
// and nothing checked that care was present, so a reply could pass every lint and still be cold. This is the positive
// check: a substantive reply shows care somewhere - anticipation, reassurance, an offer of help or a warm close
// (protocol 08 sections 6, 12, 22; 07 and 09 equivalents).
const CARE_RE = /\b(personally|passed it along|expect a reply|glad|look(ing)? forward|welcom(e|ing)|ready for you|prepared|we'?ll (have|take care|keep|check|arrange|let you know)|we'?ve (set|prepared|arranged|included|noted)|take care of|settle in|peace of mind|at your own pace|take (all the|your) time|anytime|whenever you'?re ready|feel free|you'?re welcome to|enjoy|smooth (trip|arrival)|salamat|ihanda|handa|asikuhin|andam|atimanon|ayaw kabalaka|huwag (po )?mag-alala)\b|🌿|💚|😊|🙏|✨/i;
/** True when the reply is not in the register code settled for this turn (golden run 2026-09-17: an English question got
 *  the Taglish reference reply pasted whole; "Hm po per night?" got plain English). Narrow on purpose: two Tagalog markers
 *  in an English reply, any Tagalog-only word in a Bislish one, no Filipino word at all in a substantive Taglish one. */
const TL_MARK_RE = /\b(po|lang|dito|kayo|ninyo|namin|aming|puwede|pwede|salamat|kami|ang|sa|ng|mga)\b/gi;
export function offRegister(reply: string, lang: 'en' | 'tl' | 'bis'): boolean {
  const n = (reply.match(TL_MARK_RE) ?? []).length;
  if (lang === 'en') return n >= 3;
  if (lang === 'bis') return /\b(po|opo|kayo|namin|niyo|kasya|hindi|ngayon|dito|aming)\b/i.test(reply);
  return reply.length > 120 && n === 0;
}

/** True when a model reply is long enough to carry care and carries none. Complaint and safety turns are handed off
 *  before this runs, so it is only used on routine answers. */
export function isCold(reply: string): boolean {
  // The canned site invite and its tagline ("…enjoy our best rates…") are not the model's warmth: judge the rest.
  const own = reply.split(/\n\s*\n/).filter((p) => !/👉|https?:\/\/|best rates|on our site|sa site namin|sa among site/i.test(p)).join('\n\n');
  return own.trim().length > 140 && !CARE_RE.test(own);
}

// Lloyd 2026-09-17: an invitation offers BOTH routes - settle the booking here in the chat, or the site. The model copied
// its own older site-only wording from the history despite the rule and the examples (live 19:19), so code guarantees it.
type L3 = 'en' | 'tl' | 'bis';
const CHAT_MENTION_RE = /\b(in (the|this) chat|here in chat|dito (po )?sa chat|diri sa chat|sa chat|tell us here|let us know here|(share|send)\b[^.?!\n]{0,25}\b(here|dito|diri))\b/i;
const CHAT_ROUTE: Record<L3, string> = {
  en: `Or simply tell us here, and we'll arrange the booking for you in this chat.`,
  tl: `O sabihin lang dito, and we'll arrange the booking for you sa chat.`,
  bis: `O ingna lang mi diri, and we'll arrange the booking for you sa chat.`,
};
/** When the site is offered and the chat route is not, the chat route follows the link. */
export function addChatRoute(reply: string, siteUrl: string, lang: L3): string {
  if (!reply.includes(siteUrl) || CHAT_MENTION_RE.test(reply)) return reply;
  const paras = reply.split(/\n\s*\n/);
  const i = paras.findIndex((p) => p.includes(siteUrl));
  paras[i] = paras[i] + String.fromCharCode(10) + CHAT_ROUTE[lang]; // same paragraph as the link: a phone screen reads them as one offer, and the reply stays within four paragraphs
  return paras.join('\n\n');
}
/** A decision moment ("let me think about it"): one sentence with both routes and the link, never a bare link. */
export const decisionInvite = (lang: L3, siteUrl: string) => ({
  en: `When you've decided, just tell us here and we'll arrange the booking in this chat, or you may secure the dates on our site:`,
  tl: `Kapag nakapag-decide po kayo, sabihin lang dito and we'll arrange the booking sa chat, o maaari ninyong i-secure ang dates sa aming site:`,
  bis: `Kung naka-decide na mo, ingna lang mi diri and we'll arrange the booking sa chat, or pwede pud i-secure ang dates sa among site:`,
})[lang] + `\n\n👉 ${siteUrl}`;
/** First contact always carries the link (VOICE). When the model left it out, code used to append a bare "👉 link";
 *  protocol 10 section 2: a link always sits under a sentence that offers both routes. */
export const firstInvite = (lang: L3, siteUrl: string) => ({
  en: `We can arrange everything right here in the chat, or you may see the home and live availability on our site:`,
  tl: `We can arrange everything dito sa chat, o puwede ninyong i-check ang home at live availability sa aming site:`,
  bis: `We can arrange everything diri sa chat, or pwede pud i-check ang home ug live availability sa among site:`,
})[lang] + `\n\n👉 ${siteUrl}`;
/** SPEC-14 (D-184): first contact always opens with the approved greeting. The model thanked the guest in only
 *  12 of 33 first replies (golden run 9), so a first reply that carries no thank-you has its own salutation
 *  replaced by greeting() - the same line the book flow has used since session 28. */
const THANKED_RE = /thank you for (reaching out|messaging|checking|asking)|welcome to cascade|salamat sa pag-?message/i;
export function ensureGreeting(reply: string, name: string | null, lang: L3, intro = false): string {
  if (!reply.trim() || THANKED_RE.test(reply)) return reply;
  const first = name ? name.split(' ')[0] : '';
  // "there" too: "Hi there! I'm Cassy" left a stray "there!" after the greeting (golden run 2026-09-24).
  const who = `(?:${first ? first.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '|' : ''}there)?`;
  const salute = new RegExp(`^\\s*(?:hi|hello|hey|good (?:morning|afternoon|evening)|kumusta|kamusta|maayong \\p{L}+)(?: po)?[ ,]*${who}[,.!]?\\s*`, 'iu');
  const body = reply.replace(salute, '').trimStart();
  return greeting(name, lang, intro) + (body || reply.trimStart());
}
/** D-173 / SPEC-01: a prompt rule alone fails at least once (D-097), so the introduction is also
 *  guaranteed in code on the first exchange. It goes after the reply's first sentence, which is
 *  where the greeting ends; with no sentence end to find it becomes the opening paragraph. A reply
 *  that already says Cassy is left exactly as it is. */
export function withIntro(reply: string, lang: L3): string {
  if (/\bCassy\b/.test(reply)) return reply;
  const intro = CASSY_INTRO[lang];
  const m = reply.match(/^([^.!?\n]*[.!?])(\s*)/);
  if (!m) return `${intro.trimEnd()}\n\n${reply.trimStart()}`;
  const rest = reply.slice(m[0].length);
  if (!rest) return `${m[1]} ${intro.trimEnd()}`;
  // Keep a paragraph break that was there (it used to be swallowed); a one-paragraph reply gets one after the intro
  // (golden run 2026-09-24: "one block of text").
  const sep = /\n/.test(m[2]) ? m[2] : /\n\s*\n/.test(reply) ? ' ' : '\n\n';
  return `${m[1]} ${intro.trimEnd()}${sep}${rest}`;
}
/** Insert a block before a short warm close (so the close stays last), else append it. */
export function beforeClose(reply: string, block: string): string {
  const paras = reply.trim().split(/\n\s*\n/);
  const last = paras[paras.length - 1] ?? '';
  if (paras.length > 1 && last.length < 120 && !/👉|https?:\/\//.test(last)) { paras.splice(paras.length - 1, 0, block); return paras.join('\n\n'); }
  return `${reply.trim()}\n\n${block}`;
}

/** The chat already holds the guest count: a paragraph that only asks for it again is dropped (live 2026-09-17 18:34,
 *  the model asked despite the hint - D-097, code owns it). Never returns ''. */
const PAX_ASK_RE = /^[^\n]*\b(how many (guests|people|persons|of you)|number of guests|ilan po (kayo|ang)|pila (mo|ka tawo))\b[^\n]*\?\s*$/i;
export function dropPaxAsk(reply: string): string {
  const paras = reply.split(/\n\s*\n/);
  const kept = paras.filter((p) => !PAX_ASK_RE.test(p.trim()));
  if (!kept.length || kept.length === paras.length) return reply;
  // The canned site line opens with "Or…" because it used to follow that question.
  return kept.join('\n\n').replace(/(^|\n\n)Or you may\b/, '$1You may').replace(/(^|\n\n)O maaari rin po\b/, '$1Maaari rin po');
}

/** The chat already holds the guest's name: a sentence that asks for it is dropped (golden run 2, 2026-09-17). Never returns ''. */
const NAME_ASK_RE = /[^.?!\n]*\b(may we (know|have|ask)[^.?!\n]{0,20}\bname|what(?:'s| is) your name|ano(?:ng)? (?:po )?(?:ang )?pangalan|unsa(?:y)? (?:imong|inyong) ngalan)\b[^.?!\n]*\?/gi;
export function dropNameAsk(reply: string): string {
  const out = reply.replace(NAME_ASK_RE, '').split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean).join('\n\n');
  return out || reply;
}

// K18 fact guards (D-182). Availability and the early check-in fee reached the model as prompt text only, and the golden
// set caught both wrong: a booked range called open, PHP 400 for a 10 AM arrival. Code owns both facts; no wording added.
// Golden run 6: "Wi-Fi is available ... for your dates" was read as a date claim and the Wi-Fi answer was replaced. A claim
// needs the DATE to be what is open: "Oct 27 to 29 is open", "those dates are available", "available po ang Oct 20",
// "the unit is open from Oct 9".
const MD = String.raw`(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.? ?\d{1,2}\b|\b\d{1,2}[/-]\d{1,2}\b)`;
const OPEN_CLAIM_RE = new RegExp(String.raw`(?:${MD}|\b(?:those|these|your|the) (?:dates|nights)\b)[^.!?\n]{0,40}\b(?:is|are|remains?)\s+(?:still\s+)?(?:open|available|bakante)\b|\b(?:open|available|bakante)\s+(?:po\s+)?(?:ang|from|on|for|sa)\s+(?:the\s+)?(?:night\s+of\s+)?${MD}`, 'i');
const BOOKED_CLAIM_RE = new RegExp(String.raw`${MD}[^.!?\n]*\b(?:reserved|booked|taken)\b|\b(?:reserved|booked|taken)\b[^.!?\n]*${MD}`, 'i');
const NOT_OPEN_RE = /\b(not|isn't|aren't|no longer|hindi|dili)\s+(yet\s+)?(available|open|bakante)\b/gi;
const sentencesOf = (line: string): string[] => line.match(/[^.!?\n]+(?:[.!?]+|$)\s*/g) ?? [line];
const openClaim = (s: string) => OPEN_CLAIM_RE.test(s.replace(NOT_OPEN_RE, ''));
const availSentence = (s: string) => openClaim(s) || BOOKED_CLAIM_RE.test(s);
/** The reply tells the guest a date is open or available. */
export function claimsOpen(reply: string): boolean {
  return reply.split('\n').some((l) => sentencesOf(l).some(openClaim));
}
/** Every sentence that states availability for a date gives way to the code's line: the first is replaced, the rest are
 *  dropped (golden run 4: "Oct 7 is already reserved. However, Oct 8 and 9 are open" - Oct 8 was booked too). Never ''. */
export function setAvailability(reply: string, line: string): string {
  const code = /[.!?]$/.test(line) ? line : `${line}.`;
  if (reply.includes(code)) return reply; // golden run 8: the rewrite already carried the line, and a second swap doubled its last sentence
  let placed = false;
  const out = reply.split('\n').map((l) => {
    const ss = sentencesOf(l);
    if (!ss.some(availSentence)) return l;
    return ss.map((s) => (!availSentence(s) ? s : placed ? '' : ((placed = true), `${code} `))).join('').trim();
  }).join('\n').replace(/\n{3,}/g, '\n\n').trim();
  return out || reply;
}

const EARLY_ASK_RE = /\b(early|check[- ]?in|arriv\w*|dating|abot)\b/i;
const AM_RE = /\b(\d{1,2})(?::(\d{2}))?\s*a\.?m\b|\balas[- ]?(\d{1,2})(?::(\d{2}))?\s+(?:ng umaga|sa buntag)\b/i;
/** facts.ts: early check-in is PHP 100 per started hour before 12 noon. null = the guest named no morning arrival time. */
export function earlyFeeFor(guest: string): number | null {
  const m = EARLY_ASK_RE.test(guest) ? AM_RE.exec(guest) : null;
  if (!m) return null;
  const h = Number(m[1] ?? m[3]), min = Number(m[2] ?? m[4] ?? 0);
  if (h < 5 || h > 11 || min > 59) return null;
  return Math.ceil((720 - (h * 60 + min)) / 60) * 100;
}
const FEE_SENTENCE_RE = /\b(early|before (12 )?noon|check[- ]?in|arriv\w*)\b/i;
/** A peso figure in an early check-in sentence that contradicts the computed fee is corrected. The hourly rate itself
 *  ("PHP 100 per hour") and anything above PHP 700 (the deposit, the rates) are left alone. */
export function fixEarlyFee(reply: string, guest: string): string {
  const fee = earlyFeeFor(guest);
  if (fee === null) return reply;
  return reply.replace(/[^.!?\n]+[.!?]*/g, (s) => !FEE_SENTENCE_RE.test(s) ? s
    : s.replace(/(₱|\bPHP|\bPhp)(\s?)(\d{1,3}(?:,\d{3})+|\d+)(?![^.!?\n]{0,6}\b(?:per|an|a|\/)\s?hour)/g, (all, cur: string, sp: string, num: string) => {
      const v = Number(num.replace(/,/g, ''));
      return v % 100 === 0 && v <= 700 && v !== fee ? `${cur}${sp}${fee}` : all;
    }));
}

/** Rules a canned prompt or a live reply must satisfy. `guestText` enables the ANSWER check. */
export function lintReply(reply: string, guestText = '', opts: { firstTurn?: boolean; name?: string | null } = {}): Violation[] {
  const v: Violation[] = [];
  const asks = (reply.match(/\?/g) ?? []).length;
  if (asks > 2) v.push('two_asks');
  if (reply.length > 700) v.push('too_long');
  // Easy to consume (protocol rule 4): at most four paragraphs, none longer than ~320 characters.
  const paras = reply.split(/\n\s*\n/).filter((p) => p.trim());
  if (paras.length > 4 || paras.some((p) => p.length > 320)) v.push('too_dense');
  if (FORM_RE.test(reply)) v.push('form_speak');
  if (ROBOT_RE.test(reply)) v.push('robot_word');
  if (/\b[A-Z]{6,}\b/.test(reply.replace(/\b(GCASH|PHP|YES|QR|OK|DEPOSIT|FULL)\b/g, ''))) v.push('shouting');
  if (opts.firstTurn && COLD_RE.test(reply)) v.push('cold_opener');
  if (COMMAND_RE.test(reply)) v.push('command_tone');
  if (EXCLAIM_RE.test(reply)) v.push('exclaim');
  if (BOILERPLATE_RE.test(reply)) v.push('boilerplate');
  // ANSWER: a guest question must be met with an answer before the next ask - a reply that is only
  // a question back to them is the failure Lloyd saw live ("is Oct 3 to 4 available?" -> "Your mobile number po?").
  if (guestText && QUESTION_RE.test(guestText)) {
    const firstPara = reply.split(/\n\s*\n/)[0] ?? '';
    // D-173: a disclosure answers the bot question; without this every "are you a bot?" turn logged a false no_answer.
    const answers = /\b(yes|yes po|oo|opo|may|mayroon|meron|open|available|free|bakante|taken|booked|reserved|not open|na-?book|we have|meron|wala|it is|it's|we can|we're|we are|\bi'?m cassy\b|\bako(?: po)? si cassy\b|the (rate|nearest|nightly|unit|home)|₱|php)\b/i.test(firstPara) && !/\?\s*$/.test(firstPara.trim());
    if (!answers) v.push('no_answer');
  }
  return v;
}

// SPEC-13 / D-176: look before you book. A guest deciding on a home they have never seen wants two
// things the chat cannot give - pictures and other guests' words. The direct site has the first,
// the Airbnb listing has the second. The invitation to BOOK stays the direct site; Airbnb is offered
// to READ, which is why the label is "Guest reviews" and never "Book on Airbnb" (facts.ts: no
// steering). Review NUMBERS are never quoted in chat - they go stale.
// The Tagalog and Bisaya amenity words are the same loanwords as the English ones, so the noun list
// carries all three registers. The spec's `may .* ba` / `naa .* ba` catch-alls are deliberately NOT
// here: they matched "may available ba sa Oct 3", which is a dates question, not an amenity one.
export const AMENITY_RE = /\b(amenities|amenity|included|inclusions|photos?|pictures?|pics|wifi|wi-fi|internet|aircon|air-?con|\bac\b|kitchen|tv|netflix|washing|laundry|parking)\b|what'?s (it|the place|the unit|the home) like/i;
export const TRUST_RE = /\b(reviews?|feedback|legit|legitimate|scam|trust|trustworthy|tinuod)\b|\bsafe( po)? ba\b|\bluwas ba\b/i;

/** '' when nothing should be added. `has` says which link the thread has already shown. */
export function lookNudge(text: string, lang: L3, has: { site: boolean; reviews: boolean }): string {
  const amenity = AMENITY_RE.test(text), trust = TRUST_RE.test(text);
  if (!amenity && !trust) return '';
  const reviewsLine = `⭐ Guest reviews: ${AIRBNB_URL}`;
  if (amenity && !has.site && !has.reviews) {
    const sentence = { en: `You're welcome to look through the full amenities and photos on our site, and to read what past guests have shared on our Airbnb listing.`,
      tl: `You're welcome po to look through the full amenities and photos sa aming site, and to read what past guests have shared sa aming Airbnb listing.`,
      bis: `You're welcome to look through the full amenities and photos sa among site, and to read what past guests have shared sa among Airbnb listing.` }[lang];
    return `${sentence}\n\n🏡 Amenities and photos: ${SITE_URL}\n${reviewsLine}`;
  }
  if (has.reviews) return '';
  const sentence = { en: `If you'd like to read what past guests have shared, our reviews are on our Airbnb listing.`,
    tl: `If you'd like to read what past guests have shared, nasa aming Airbnb listing po ang reviews.`,
    bis: `If you'd like to read what past guests have shared, naa sa among Airbnb listing ang reviews.` }[lang];
  return `${sentence}\n\n${reviewsLine}`;
}

/** Golden run 2026-09-24 (5 of 9 failures): the look block offers the site, and the reply kept its own site invitation
 *  ("...or you may see the home and live availability on our site.") - two invitations, over 700 characters. With the
 *  block present the reply's site sentences go; a sentence that also carries the chat route keeps that half
 *  ("We can arrange everything right here in the chat."). Link lines are left to dropSoloLink. Never returns ''. */
const SITE_SENTENCE_RE = /\b(on|sa) (our|aming|among) (direct )?(site|website)\b|\bsite namin\b/i;
export function dropSiteInvite(reply: string): string {
  const out = reply.split(/\n\s*\n/).map((p) => {
    if (/^(👉|https?:\/\/|🏡|⭐)/.test(p.trim())) return p;
    return p.split('\n').map((line) => sentencesOf(line).map((s) => {
      if (!SITE_SENTENCE_RE.test(s)) return s;
      const chat = s.match(/^(.*?\b(?:chat|here|dito|diri)\b),?\s+(?:or|o)\s+[^.!?]*[.!?:]?\s*$/i);
      if (!chat || SITE_SENTENCE_RE.test(chat[1]) || CHAT_MENTION_RE.test(p.replace(s, ''))) return ''; // the chat route is already said
      return `${chat[1]}. `;
    }).join('').trim()).filter(Boolean).join('\n');
  }).map((p) => p.trim()).filter(Boolean).join('\n\n');
  return out || reply;
}

/** The look block joins the chat-route paragraph as ONE invitation (both routes, protocol rule 4): its sentence ends in
 *  ":" with the labelled 🏡 / ⭐ lines directly under it, and a short warm close stays last (golden run 2026-09-24:
 *  the block as its own paragraphs made two invitations and five paragraphs). */
export function appendLook(reply: string, look: string): string {
  const [sentence, ...rest] = look.split(/\n\s*\n/);
  const block = `${sentence.trim().replace(/[.\s]*$/, ':')}\n${rest.join('\n').trim()}`;
  const paras = reply.trim().split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  const last = paras[paras.length - 1] ?? '';
  const close = paras.length > 1 && last.length < 120 && !/👉|https?:\/\//.test(last) && !CHAT_MENTION_RE.test(last) ? paras.pop()! : '';
  const i = paras.length - 1;
  if (i >= 0 && CHAT_MENTION_RE.test(paras[i]) && !paras[i].includes('://')) paras[i] = `${paras[i]} ${block}`;
  else paras.push(block);
  if (close) paras.push(close);
  return paras.join('\n\n');
}

/** The look block carries its own labelled site link, so the solo 👉 link goes; the sentence that introduced it keeps
 *  its words but ends in a full stop instead of a colon pointing at nothing (live 2026-09-23: "...on our site:"). */
export function dropSoloLink(reply: string, url: string): string {
  const paras = reply.split(/\n\s*\n/);
  const out: string[] = [];
  for (const p of paras) {
    if (p.trim() === `👉 ${url}`) {
      if (out.length) out[out.length - 1] = out[out.length - 1].replace(/\s*:\s*$/, '.');
      continue;
    }
    out.push(p);
  }
  return out.join('\n\n');
}
