// Session 59 (Lloyd 2026-09-28: "not so good at converting inquiry"): one-tap next steps under an info answer - Messenger
// quick replies. Wording and rules: [[DESIGN-quick-reply-next-steps-2026-09-28]] (Fable). Titles stay English in every
// register (labels, not sentences); the payload is the question the bot receives, like the Page menu's.
import type { Lang } from './booking.ts';

export type Chip = { title: string; payload: string };
const DATES_Q = 'How much is it, and are my dates available?';
export const CHIP = {
  checkDates: { title: 'Check my dates', payload: DATES_Q },
  datesRates: { title: 'Dates and rates', payload: DATES_Q },
  seeHome: { title: 'See the home', payload: 'Can I see photos of the home and the guest reviews?' },
  neighbourhood: { title: 'The neighbourhood', payload: 'Where exactly are you, and what is the area like? Is it safe?' },
  comforts: { title: 'Comforts of the home', payload: 'What comforts does the home have? Wi-Fi, Netflix, parking?' },
} satisfies Record<string, Chip>;

const HELLO_RE = /^\s*(hi+|hello|hey|good (morning|afternoon|evening|day)|maayong (buntag|hapon|gabii)|magandang (umaga|hapon|gabi)|kumusta|musta)\b[^?]{0,40}$/i;
export const isHello = (text: string) => HELLO_RE.test(text);

/** The chip set for a routine answer, or [] (the caller decides eligibility: no handoff, no host matter, no booking flow,
 *  no thanks/closer/bot ask, no dates-first reply). Order: greeting, place, comforts, anything else (trust included). */
export function chipsFor(s: { eligible: boolean; hello: boolean; place: boolean; amenity: boolean }): Chip[] {
  if (!s.eligible) return [];
  if (s.hello) return [CHIP.datesRates, CHIP.neighbourhood, CHIP.comforts];
  if (s.place) return [CHIP.checkDates, CHIP.seeHome, CHIP.comforts];
  if (s.amenity) return [CHIP.checkDates, CHIP.seeHome, CHIP.neighbourhood];
  return [CHIP.checkDates, CHIP.seeHome];
}

/** A tap sends the title as text and the payload beside it: the payload is the question (a CODE_PAYLOAD falls back). */
export function quickReplyText(msg: Record<string, any>): string {
  const p = String(msg?.quick_reply?.payload ?? '').trim();
  return p && !/^[A-Z0-9_]+$/.test(p) ? p : '';
}

// A model close that hands the next step back to the guest ("let us know your preferred dates") - the chips are the next step.
const PASSIVE_RE = /\b(preferred dates|dates in mind|share (your|ang|lang)[^.?!\n]{0,20}dates|which dates|petsa|let us know|feel free to|sabihin lang|share lang)\b/i;
const WARM_RE = /\b(glad|welcome|look(ing)? forward|enjoy|pleasure|salamat|thank)|🌿/i;
const FALLBACK: Record<Lang, string> = {
  en: `We'd be glad to have you here.`,
  tl: `Glad po kaming i-welcome kayo dito.`,
  bis: `Glad mi nga mo-welcome ninyo diri.`,
};
/** Drops a passive last sentence; if that leaves the reply on a bare fact, closes warmly instead. */
export function stripPassiveClose(reply: string, lang: Lang): string {
  const paras = reply.trim().split(/\n\s*\n/);
  const last = paras[paras.length - 1] ?? '';
  const sentences = last.match(/[^.?!]+[.?!]*[\s🌿]*/gu) ?? [last];
  const tail = sentences[sentences.length - 1] ?? '';
  if (!PASSIVE_RE.test(tail)) return reply;
  const kept = sentences.slice(0, -1).join('').trim();
  const body = [...paras.slice(0, -1), ...(kept ? [kept] : [])];
  const out = body.join('\n\n').trim();
  return WARM_RE.test(body[body.length - 1] ?? '') ? out : `${out}\n\n${FALLBACK[lang]}`;
}
