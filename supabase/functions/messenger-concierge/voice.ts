// Concierge communication protocol, the part code can check (session 28, 2026-09-17).
// Source: docs/concierge-communication-protocol.md. Three moves in every reply, in this order:
//   1. ANSWER   - if the guest asked something, the first sentences answer it (never skipped by a flow)
//   2. ACKNOWLEDGE - the person before the fact: name, "po", what they told us
//   3. ADVANCE  - one ask at most, and the guest is never left without a next step
// lintReply() is run over every canned prompt in voice.test.ts (fails the build) and over every
// outgoing reply at runtime (warn-only log `voice_lint`, so live drift is visible without blocking).

import { AMENITY_RE, SEE_RE, TRUST_RE } from './booking.ts';
import { SIGNATURE } from './persona.ts'; // read inside functions only (persona.ts imports this file)
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
export const CLOSER_RE = /\s*[^.!?\n]*\b(any (other|more|further) questions|(iba|uban|ubang|lain|laing)\b[^.!?\n]{0,25}(katanungan|questions?|tanong|pangutana)|mag-atubili)\b[^.!?\n]*[.!?]?/gi;
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

const CONTRACTIONS: Array<[RegExp, string]> = [
  // Not after a preposition: "window for you would be" became "for you'd be", "how many of you will" became "of you'll" (golden run 2026-09-17).
  [/(?<!\b(?:for|to|of|with|from) )\b(We|we|You|you|I|They|they) would\b/g, "$1'd"], [/(?<!\b(?:for|to|of|with|from) )\b(We|we|You|you|They|they) are\b/g, "$1're"], [/(?<!\b(?:for|to|of|with|from) )\b(We|we|You|you|I|They|they) will\b/g, "$1'll"],
  [/\b(We|we|You|you|I|They|they) have\b(?= (?:been|already|prepared|arranged|noted|set|reserved))/g, "$1've"], [/\b(It|it|That|that|There|there) is\b/g, "$1's"],
  [/\b(D|d)o not\b/g, "$1on't"], [/\b(D|d)oes not\b/g, "$1oesn't"], [/\b(C|c)annot\b/g, "$1an't"], [/\b(I|i)s not\b/g, "$1sn't"],
];
/** Protocol 08: an English answer uses natural contractions (session 30: stiff, uncontracted English read as cold). */
export function contractions(text: string): string {
  let out = text;
  for (const [re, to] of CONTRACTIONS) out = out.replace(re, to);
  return out;
}

// Session 30 (Lloyd: "it would always revert back to blunt transactional responses"): every rule so far REMOVED something,
// and nothing checked that care was present, so a reply could pass every lint and still be cold. This is the positive
// check: a substantive reply shows care somewhere - anticipation, reassurance, an offer of help or a warm close
// (protocol 08 sections 6, 12, 22; 07 and 09 equivalents).
const CARE_RE = /\b(personally|passed it along|expect a reply|glad|look(ing)? forward|welcom(e|ing)|ready for you|prepared|we'?ll (have|take care|keep|check|arrange|let you know)|we'?ve (set|prepared|arranged|included|noted)|take care of|settle in|relax|peace of mind|at your own pace|take (all the|your) time|anytime|whenever you'?re ready|feel free|you'?re welcome to|enjoy|smooth (trip|arrival)|salamat|ihanda|handa|asikuhin|andam|atimanon|ayaw kabalaka|huwag (po )?mag-alala|gladly|makakatipid|makatipid|ihahanda|iche-check|i-share lang|i-send lang|share lang|handa na|asikasuhin|aasikasuhin|amo dayon|i-check namo|excited|delighted)\b|🌿|💚|😊|🙏|✨/i; // SPEC-32 s4 (F11); SPEC-39 (D-297.3): "delighted"
/** True when the reply is not in the register code settled for this turn (golden run 2026-09-17: an English question got
 *  the Taglish reference reply pasted whole; "Hm po per night?" got plain English). Narrow on purpose: two Tagalog markers
 *  in an English reply, any Tagalog-only word in a Bislish one, no Filipino word at all in a substantive Taglish one. */
// SPEC-28: a substantive Taglish reply needs TWO marks. English with one "po" passed as Taglish (live 2026-09-24,
// "magkano po kung 3 nights?"), so nothing measured it; the function words added here are what real Taglish carries.
const TL_MARK_RE = /\b(po|lang|dito|kayo|ninyo|namin|aming|puwede|pwede|salamat|kami|ang|sa|ng|mga|para|kaya|ba)\b/gi;
export function offRegister(reply: string, lang: 'en' | 'tl' | 'bis'): boolean {
  const n = (reply.match(TL_MARK_RE) ?? []).length;
  if (lang === 'en') return n >= 3;
  if (lang === 'bis') return /\b(po|opo|kayo|namin|niyo|kasya|hindi|ngayon|dito|aming)\b/i.test(reply);
  return reply.length > 120 && n < 2;
}

/** True when a model reply is long enough to carry care and carries none. Complaint and safety turns are handed off
 *  before this runs, so it is only used on routine answers. */
export function isCold(reply: string): boolean {
  // The canned site invite and its tagline ("…enjoy our best rates…") are not the model's warmth: judge the rest.
  // Golden run 2026-09-25 (R3): appendLook joins the link lines to the paragraph that held the warmth ("feel free", 🌿),
  // and dropping whole paragraphs with a link dropped the warmth too. Only link lines and site sentences go now.
  // Golden run 2026-09-25 (first-greeting-tl): code's own greeting and Cassy sentence are not the model's warmth either;
  // counted, they pushed a one-line model reply over the length bar.
  const own = reply.split('\n').filter((l) => !/👉|https?:\/\//.test(l))
    .map((l) => sentencesOf(l).filter((s) => !/best rates|on our (direct )?site|sa site namin|sa (aming|among) site/i.test(s)
      && !THANKED_RE.test(s) && !/\bCassy\b/.test(s)).join('')).join('\n')
    // Golden run 2026-09-25 (reg-bot-bis): "...for you. 🌿 Nasa aming site ang photos..." - the care mark shared a sentence
    // with the site, so it went with it. A care emoji anywhere in the reply counts.
    + (reply.match(/🌿|💚|😊|🙏|✨/gu) ?? []).join('');
  return own.trim().length > 140 && !CARE_RE.test(own);
}
/** "Happy to help" is on the boilerplate list (R2); the approved first replies say "glad to help" (golden run 2026-09-25). */
export const gladNotHappy = (reply: string) => reply.replace(/\b(be|am|are|we'?re|we'?d be|i'?d be) happy to help\b/gi, (m) => m.replace(/happy/i, (h) => (h[0] === 'H' ? 'Glad' : 'glad')));

type L3 = 'en' | 'tl' | 'bis';
/** A decision moment ("let me think about it"): one sentence with both routes and the link, never a bare link. */
export const decisionInvite = (lang: L3, siteUrl: string) => ({
  en: `When you've decided, just tell us here and we'll arrange the booking in this chat, or you may secure the dates on our site:`,
  tl: `Kapag nakapag-decide po kayo, sabihin lang dito and we'll arrange the booking sa chat, o maaari ninyong i-secure ang dates sa aming site:`,
  bis: `Kung naka-decide na mo, ingna lang mi diri and we'll arrange the booking sa chat, or pwede pud i-secure ang dates sa among site:`,
})[lang] + `\n\n👉 ${siteUrl}`;
// Session 58 live probe: "Salamat po sa pag-reach out sa Cascade Hideaway." was missed, so the greeting went on top of it
// and the guest was thanked twice in one opening.
const THANKED_RE = /thank you for (reaching out|messaging|checking|asking)|welcome to cascade|salamat(?: po)? sa pag-?(?:message|mensahe|reach out|pag-?abot)/i;
/** D-269 (protocol: "one 🌿 at a close"; live 2026-09-27 the model put one mid-message and wrote on after it): a leaf
 *  that closes the message stays (the last one only); a leaf anywhere else goes. */
export function leafAtClose(reply: string): string {
  if (!reply.includes('🌿')) return reply;
  return reply.trimEnd().endsWith('🌿') ? reply.replace(/\s*🌿(?=[\s\S]*🌿)/gu, '') : reply.replace(/[ \t]*🌿/gu, '');
}
/** Golden run 2026-09-25 (first-rate-tl, R10 "5 paragraphs"): greeting, answer, dates ask, invitation and close each
 *  stood alone. Protocol rule 4 caps a reply at four paragraphs (a 👉 link line belongs to the paragraph above it), so
 *  the greeting paragraph joins the next one when the two fit in 320 characters. */
export function fitParagraphs(reply: string, max = 4): string {
  const isLink = (p: string) => /^(👉|https?:\/\/)/.test(p);
  let paras = reply.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  // Golden 2026-09-25 (turnover-day tl): greeting + answer was 385 characters, so the shortest adjacent text pair that
  // fits in 320 is joined instead - never across a link line, so a link stays directly under its sentence.
  while (paras.filter((p) => !isLink(p)).length > max) {
    let best = -1;
    for (let i = 0; i + 1 < paras.length; i++) {
      if (isLink(paras[i]) || isLink(paras[i + 1])) continue;
      const len = paras[i].length + 1 + paras[i + 1].length;
      if (len <= 320 && (best < 0 || len < paras[best].length + 1 + paras[best + 1].length)) best = i;
    }
    if (best < 0) break;
    paras = [...paras.slice(0, best), `${paras[best]} ${paras[best + 1]}`, ...paras.slice(best + 2)];
  }
  return paras.join('\n\n');
}
/** Golden run 2026-09-25 (reg-bot-bis, R7): "Hi Ben!", "Yes, Ben,", "Salamat, Ben." - the name at most twice. Extra
 *  vocatives go from the end ("Salamat, Ben." -> "Salamat."); the greeting's use is never touched. */
export function capName(reply: string, name: string | null, max = 2): string {
  const first = name?.split(' ')[0];
  if (!first) return reply;
  const esc = first.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  let out = reply;
  const count = () => (out.match(new RegExp(`\\b${esc}\\b`, 'g')) ?? []).length;
  const voc = new RegExp(`,\\s*(?:(?:sir|ma'?am)\\s+)?${esc}(?=\\s*[,.!?])`, 'gi');
  while (count() > max) {
    const all = [...out.matchAll(voc)];
    const last = all[all.length - 1];
    if (!last || last.index === undefined) break;
    out = out.slice(0, last.index) + out.slice(last.index + last[0].length);
  }
  return out;
}
/** Live 2026-09-25 14:47Z: three drafts in a minute came back as malformed JSON ("Expected property name", "Unterminated
 *  string") and each guest got the host-handoff line instead of an answer. Fences are stripped, then the "reply" field is
 *  read on its own (raw newlines allowed). Throws SyntaxError only when no reply can be found. */
// D-286: the concierge contract is {answer, ask, uncertain, guest_name}; an old-shape {reply} is read as the answer.
export function parseDraftJson(raw: string): { answer?: string; ask?: string | null; reply?: string; uncertain?: boolean; guest_name?: unknown } {
  const t = raw.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```\s*$/, '');
  try { return JSON.parse(t); } catch { /* read the fields on their own below */ }
  const field = (k: string) => {
    const m = t.match(new RegExp(`["']${k}["']\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"`, 's'));
    return m ? JSON.parse(`"${m[1].replace(/\r?\n/g, '\\n').replace(/\t/g, '\\t')}"`) as string : undefined;
  };
  try {
    const answer = field('answer'), reply = answer === undefined ? field('reply') : undefined;
    if (answer !== undefined || reply !== undefined) {
      const name = t.match(/["']guest_name["']\s*:\s*"([^"\\\n]{1,40})"/)?.[1];
      return { ...(answer !== undefined ? { answer, ask: field('ask') ?? null } : { reply }), uncertain: /["']uncertain["']\s*:\s*true/.test(t), guest_name: name ?? null };
    }
  } catch { /* fall through */ }
  throw new SyntaxError('draft_json_unreadable');
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
// Golden 2026-09-26 (first-rate-tl): "May we know your name po, and if you have dates in mind, share lang dito..." ends in
// "." so the whole-question rule above missed it. The leading name clause of a compound sentence goes; the rest stays.
const NAME_CLAUSE_RE = /\bmay we (?:know|have|ask for) (?:your|the) (?:first )?name(?: po)?,? and (?:also )?(\S)/giu;
export function dropNameAsk(reply: string): string {
  const out = reply.replace(NAME_ASK_RE, '').replace(NAME_CLAUSE_RE, (_m, c: string) => c.toUpperCase())
    .split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean).join('\n\n');
  return out || reply;
}

/** D-286: an invitation sentence (golden-score R4 counts the same) and a closing sentence - the frame compose() writes, so
 *  cleanAnswer takes them out of the model's answer. */
export const INVITE_RE = /\b(on|sa) (our|aming|among|the) site\b|\bsite namin\b|\barrange (the|your|a|everything|it)\b|\bsecure (your|the|ang) (dates?|stay)\b|\bbook(ing)? (directly|direct) (on|sa|through)\b/i;
export const ASKING_RE = /\b(you (may|can)|we can arrange|feel free|whenever you('re| are| feel)|when you('ve| have)|puwede|pwede|maaari|kapag|kung ready)\b/i;
/** A warm close - also the answer's one sentence of care, so it goes only when compose() closes the message itself. */
export const CLOSE_START_RE = /^\s*(we'?d be (happy|glad|so glad) to (welcome|have) you|we'?d love to (host|welcome|have) you|we look forward to|(we'?re )?looking forward|masaya (po )?naming|we'?ll have everything (ready|prepared)|hope to (see|welcome) you)/i;
/** Never kept: the "we're here" closer beside a next step, and a promise of preparation to a guest with no booking (live 2026-09-30). */
export const ALWAYS_CLOSE_RE = /^\s*(we'?re (always )?here (if|whenever|for)|we'?re one message away)|prepared (for|before) (you |your )?arriv/i;
/** D-286: the model's one question asks for a slot the chat already holds (dates, the count, the name). */
const DATES_ASK_RE = /\b(which|what) dates\b|\bdates (do|would) you\b|\bdates in mind\b|\bpreferred dates\b|\bkailan\b|\bkanus-?a\b|\bcheck-?in and check-?out\b|\bmay dates na\b|\bnaa na (mo|moy) dates\b/i;
/** The line asks the guest for their dates (the model's ask, or the code's next step). */
export const asksDates = (s: string) => DATES_ASK_RE.test(s);
/** A share-your-dates statement ("Kung may dates na kayo in mind, i-share lang dito...", "If you have dates in mind, share
 *  them here...", "Just let us know your preferred dates..."). Golden AFTER #3: the model wrote one beside its own dates ask. */
export const DATES_NUDGE_RE = /\b(share|i-share|sabihin|ingna|let us know|tell us|send)\b[^.?!\n]{0,40}\b(dates?|petsa)\b|\b(if|kung|kapag|when)\b[^.?!\n]{0,30}\bdates?\b[^.?!\n]{0,40}\b(share|i-share|sabihin|ingna|let us know|tell us)\b/i;
export const asksHeld = (ask: string, held: { dates: boolean; pax: boolean; name: boolean }) =>
  (held.dates && DATES_ASK_RE.test(ask)) || (held.pax && PAX_ASK_RE.test(ask.trim())) || (held.name && ask.search(NAME_ASK_RE) >= 0);

// K18 fact guards (D-182). Availability and the early check-in fee reached the model as prompt text only, and the golden
// set caught both wrong: a booked range called open, PHP 400 for a 10 AM arrival. Code owns both facts; no wording added.
// Golden run 6: "Wi-Fi is available ... for your dates" was read as a date claim and the Wi-Fi answer was replaced. A claim
// needs the DATE to be what is open: "Oct 27 to 29 is open", "those dates are available", "available po ang Oct 20",
// "the unit is open from Oct 9".
const MD = String.raw`(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.? ?\d{1,2}\b|\b\d{1,2}[/-]\d{1,2}\b)`;
const OPEN_CLAIM_RE = new RegExp(String.raw`(?:${MD}|\b(?:those|these|your|the) (?:dates|nights)\b)[^.!?\n]{0,40}\b(?:is|are|remains?)\s+(?:still\s+)?(?:open|available|bakante)\b|\b(?:open|available|bakante)\s+(?:po\s+)?(?:ang|from|on|for|sa)\s+(?:the\s+)?(?:night\s+of\s+)?${MD}`, 'i');
const BOOKED_CLAIM_RE = new RegExp(String.raw`${MD}[^.!?\n]*\b(?:reserved|booked|taken)\b|\b(?:reserved|booked|taken)\b[^.!?\n]*${MD}`, 'i');
const NOT_OPEN_RE = /\b(not|isn't|aren't|no longer|hindi|dili)\s+(yet\s+)?(available|open|bakante)\b/gi;
export const sentencesOf = (line: string): string[] => line.match(/[^.!?\n]+(?:[.!?]+|$)\s*/g) ?? [line];
/** SPEC-31 s4 (F4, F7): a question while the hold is open. The booking is already arranged, so no invitation, no link,
 *  and never "your booking is confirmed" or a promised reminder - that sentence becomes the code's own status line. */
const PAY_CLAIM_RE = /(is|ay) (now )?confirmed|na-confirm na|we'?ll (send|email) .{0,30}(reminder|receipt)/i;
const PAY_INVITE_RE = /(arrange (the|your) booking|arrange everything|secure (your|the) dates|on our site|sa (aming|among) site|preferred dates|share (your|ang|lang)[^.?!]{0,20}dates|whenever you('re| are| feel) ready|direct bookings (carry|enjoy))/i;
export function payHoldReply(reply: string, statusLine: string, siteUrl: string): string {
  let placed = false;
  const out = reply.split('\n').map((l) => {
    if (l.includes(siteUrl) || /^\s*👉/.test(l)) return '';
    return sentencesOf(l).map((s) => PAY_CLAIM_RE.test(s) ? (placed ? '' : ((placed = true), `${statusLine} `)) : PAY_INVITE_RE.test(s) ? '' : s).join('').trim();
  }).join('\n').replace(/\n{3,}/g, '\n\n').trim();
  return out || statusLine;
}
/** SPEC-32 s1b (D-247, F15): in the chat, payment is GCash; UnionBank / InstaPay only when the guest asked for a bank or
 *  another way to pay. The 26 Sep live reply volunteered it after "how do I pay?". Never returns ''. */
const BANK_RE = /(unionbank|bank transfer|instapay|pesonet)/i;
export function dropBankUnlessAsked(reply: string, guestText: string): string {
  if (!BANK_RE.test(reply) || /(bank|transfer|instapay|pesonet|maya|other (way|option|method)s?|iba pa|lain pa)/i.test(guestText)) return reply;
  const out = reply.split('\n').map((l) => sentencesOf(l).filter((s) => !BANK_RE.test(s)).join('').trim()).join('\n').replace(/\n{3,}/g, '\n\n').trim();
  return out || reply;
}
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

// Lloyd 2026-09-17: on a day another guest checks out, check-in stays at 2 PM and the 12 noon check-in is never offered.
// Golden run 2026-09-25 (Oct 2, a real Airbnb check-out): "You're welcome to check in from 12:00 noon that day at no extra
// cost." The prompt said "12 noon at the earliest" there, so code owns the fact now, as K18 does for the fee.
const NOON_OFFER_RE = /\b(12(:00)?\s*(noon|nn|pm)|noon|tanghali|complimentary|no extra (cost|charge)|free (early )?check[- ]?in|walang (dagdag|bayad))\b/i;
const CHECKIN_WORD_RE = /\b(check[- ]?in|arriv\w*|dating|abot)\b/i;
const noonOffer = (s: string) => CHECKIN_WORD_RE.test(s) && NOON_OFFER_RE.test(s) && !/\b2(:00)?\s*p\.?m\b/i.test(s) && !/\bcheck[- ]?out\b/i.test(s);
/** The reply offers a check-in at or before 12 noon, or a free early one. */
export function offersEarlyCheckin(reply: string): boolean {
  return reply.split('\n').some((l) => sentencesOf(l).some(noonOffer));
}
/** The code's sentence for a check-in on a turnover day. `day` is already formatted ("Oct 2"). */
export function turnoverCheckinLine(day: string, l3: 'en' | 'tl' | 'bis'): string {
  return l3 === 'tl' ? `Sa ${day} po, ang check-in ay from 2:00 PM, dahil ihahanda pa namin ang home after ng naunang guest; sasabihan namin kayo agad kung maaga itong maging ready.`
    : l3 === 'bis' ? `Sa ${day}, ang check-in kay from 2:00 PM, kay amo pang i-prepare ang home human sa nauna nga guest; amo dayon kamo ingnan kung ready na og sayo.`
    : `Check-in on ${day} is from 2:00 PM, as we'll be preparing the home after the guest before you; we'll let you know right away if it's ready earlier.`;
}
/** Every sentence offering an early check-in gives way to the code's line: the first is replaced, the rest dropped. */
export function setTurnoverCheckin(reply: string, line: string): string {
  if (reply.includes(line)) return reply;
  let placed = false;
  const out = reply.split('\n').map((l) => {
    const ss = sentencesOf(l);
    if (!ss.some(noonOffer)) return l;
    return ss.map((s) => (!noonOffer(s) ? s : placed ? '' : ((placed = true), `${line} `))).join('').trim();
  }).join('\n').replace(/\n{3,}/g, '\n\n').trim();
  return out || reply;
}

/** Paragraphs with a link line folded into the sentence it belongs to (linkSolo puts blank lines around the link).
 *  SPEC-39 (D-299.10): the closing signature folds into the paragraph above it the same way - it never costs a paragraph. */
export function paragraphs(reply: string): string[] {
  const out: string[] = [];
  for (const p of reply.split(/\n\s*\n/).map((x) => x.trim()).filter(Boolean)) {
    if ((/^(👉|https?:\/\/)/.test(p) || p === SIGNATURE) && out.length) out[out.length - 1] += '\n' + p; else out.push(p);
  }
  return out;
}
/** SPEC-39 3.6b: the stay card, the hold and the payment in one code-written message - the one named exception to 700. */
export const STAY_PAY_CAP = 960; // measured worst case 948 (tl gentle, a promo line, a long name and e-mail); the approved wording, not padding

/** persona.ts greeting(), alone in its paragraph, every register ("Hi Ben, thank you for reaching out to Cascade Hideaway."). */
const GREET_ONLY_RE = /^(?:hi|hello)\b[^\n]{0,40}?(?:thank you for reaching out to|salamat sa pag-message sa) cascade hideaway\.$/i;
/** Rules a canned prompt or a live reply must satisfy. `guestText` enables the ANSWER check. `cap`: STAY_PAY_CAP for the
 *  stay-and-payment message only. */
export function lintReply(reply: string, guestText = '', opts: { firstTurn?: boolean; name?: string | null; cap?: number } = {}): Violation[] {
  const v: Violation[] = [];
  const asks = (reply.match(/\?/g) ?? []).length;
  if (asks > 2) v.push('two_asks');
  if (reply.length > (opts.cap ?? 700)) v.push('too_long');
  // Easy to consume (protocol rule 4): at most four paragraphs, none longer than ~320 characters. D-286: a 👉 link line
  // belongs to the paragraph above it - the same count golden-score uses, so D-285 measures the protocol.
  const paras = paragraphs(reply);
  // SPEC-39 3.6b: a stay card's fact lines (👤 📅 📞 💰 🏷️ 🔐 ⏳) are scanned one per line, not read as prose - like a link line.
  if (paras.length > 4 || paras.some((p) => p.replace(/\n[^\n]*https?:\/\/[^\n]*/g, '').replace(/\n(?:👤|📅|📞|💰|🏷️|🔐|⏳)[^\n]*/gu, '').length > 320)) v.push('too_dense');
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
    // s73 F3: a first reply's greeting is its own paragraph (SPEC-39 3.1); the answer is the paragraph after it.
    const ps = reply.split(/\n\s*\n/).map((p) => p.trim());
    const firstPara = (ps.length > 1 && GREET_ONLY_RE.test(ps[0]) ? ps[1] : ps[0]) ?? '';
    // D-173: a disclosure answers the bot question; without this every "are you a bot?" turn logged a false no_answer.
    // Golden AFTER 2026-09-30: Bislish answers ("Naa, Ben.", "Ang Cascade kay hilom...") read as no answer.
    const answers = /\b(yes|yes po|oo|opo|naa|naay|kay|may|mayroon|meron|open|available|free|bakante|taken|booked|reserved|not open|na-?book|we have|meron|wala|it is|it's|we can|we're|we are|\bi'?m cassy\b|\bako(?: po)? si cassy\b|the (rate|nearest|nightly|unit|home)|₱|php)\b/i.test(firstPara) && !/\?\s*$/.test(firstPara.trim());
    if (!answers) v.push('no_answer');
  }
  return v;
}

/** Session 58, the persona gate: the rules beyond lintReply that every fixed guest line is held to (persona.test.ts, and
 *  guest-messages/templates.test.ts). `approved`: Lloyd's word-for-word lines keep their "!" greeting and their "po". */
const URGENCY_RE = /\b(hurry|limited|last chance|act fast|book now|don'?t miss|selling fast|while (it|they) last|only \d+ (left|nights? left))\b/i;
export function toneRules(m: string, lang: L3 = 'en', approved = false): string[] {
  const v: string[] = [];
  if (URGENCY_RE.test(m)) v.push('urgency');
  const leaves = (m.match(/🌿/gu) ?? []).length;
  if (leaves > 1 || (leaves === 1 && !m.trimEnd().endsWith('🌿'))) v.push('leaf_not_at_close');
  if (lang === 'bis' && /\b(po|opo)\b/i.test(m)) v.push('po_in_bislish');
  if (lang === 'tl' && /the two of you/i.test(m)) v.push('two_of_you_in_taglish');
  if (approved) return v;
  if (/!/.test(m.replace(/^(Hi [A-Z]\w*|Hello po|Hello)! /, ''))) v.push('exclamation'); // the approved greeting's "!" may lead
  if ((m.match(/\bpo\b/gi) ?? []).length > 2) v.push('po_over_two');
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
// AMENITY_RE, SEE_RE and TRUST_RE are defined in booking.ts (start() and toneOf use them; this file imports booking.ts).
export { AMENITY_RE, SEE_RE, TRUST_RE };

/** '' when nothing should be added. `has` says which link the thread has already shown. SPEC-39 (D-300.2): the site and
 *  reviews block answers a guest who asked to SEE the home (photos, "what is it like"); a Wi-Fi or parking question is a
 *  fact, answered from FACTS with no link. A reviews or trust question gets the reviews line. */
export function lookNudge(text: string, lang: L3, has: { site: boolean; reviews: boolean }): string {
  const see = SEE_RE.test(text), trust = TRUST_RE.test(text);
  if (!see && !trust) return '';
  const reviewsLine = `⭐ Guest reviews: ${AIRBNB_URL}`;
  if (see && !has.site && !has.reviews) {
    // Golden run 2026-09-25 (R10, 733 and 775 characters): code's own lines are most of a first amenity reply, so this
    // sentence was cut from 138 characters to under 100.
    const sentence = { en: `Photos and the full amenities are on our site, and past guests' reviews are on our Airbnb listing.`,
      tl: `Nasa aming site po ang photos at full amenities, at nasa Airbnb listing namin ang reviews ng past guests.`,
      bis: `Naa sa among site ang photos ug full amenities, ug naa sa among Airbnb listing ang reviews sa past guests.` }[lang];
    return `${sentence}\n\n🏡 Amenities and photos: ${SITE_URL}\n${reviewsLine}`;
  }
  if (has.reviews) return '';
  const sentence = { en: `If you'd like to read what past guests have shared, our reviews are on our Airbnb listing.`,
    tl: `If you'd like to read what past guests have shared, nasa aming Airbnb listing po ang reviews.`,
    bis: `If you'd like to read what past guests have shared, naa sa among Airbnb listing ang reviews.` }[lang];
  return `${sentence}\n\n${reviewsLine}`;
}
