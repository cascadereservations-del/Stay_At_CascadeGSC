// Voice close-out (2026-09-17): the rubric of docs/response-protocol-final.md §7, scored in code on every golden
// reply. Pure, no I/O, unit-tested (golden-score.test.ts). A check returns null when it passes, else a short reason.
// The checks are deliberately narrow: a scorer that cries wolf sends us back to tuning by ear.
import { RATE_TIERS } from '../_shared/cascade-core/facts.ts';
import { isCold, lintReply, type Violation } from './voice.ts';

export type Reg = 'en' | 'tl' | 'bis';
/** model = a free answer written by the model; code = a code-owned line in index.ts (closer, bot, dates-first, sticker);
 *  flow = Lloyd's approved booking-flow lines (frozen: only R2 and R9 apply); midflow = model answer + the flow's card;
 *  handoff = a fixed handoff line (no invitation, ever). */
export type Kind = 'model' | 'code' | 'flow' | 'midflow' | 'handoff';
export type Ctx = {
  guest: string; reply: string; prevReply: string | null; kind: Kind; lang: Reg; firstTurn: boolean; siteUrl: string;
  name?: string | null; held?: { dates?: boolean; pax?: boolean; name?: boolean }; noInvite?: boolean; guestUsedPo?: boolean;
  must?: RegExp[]; mustNot?: RegExp[];
};
export const RUBRIC = ['R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'R9', 'R10', 'X'] as const;
export type Rule = typeof RUBRIC[number];
export type Score = Record<Rule, string | null>;

/** Paragraphs with a link line folded into the sentence it belongs to (linkSolo puts blank lines around the link). */
export function paragraphs(reply: string): string[] {
  const out: string[] = [];
  for (const p of reply.split(/\n\s*\n/).map((x) => x.trim()).filter(Boolean)) {
    if (/^(👉|https?:\/\/)/.test(p) && out.length) out[out.length - 1] += '\n' + p; else out.push(p);
  }
  return out;
}

const QUESTION_RE = /\?|\b(is it|is there|are there|do you|does it|can we|can i|may i|pwede|meron|naa ba|magkano|pila|tagpila|how (much|far|many|long)|available|avail|bakante)\b/i;
const ANSWER_RE = /\b(yes|opo|oo|naa|wala|may|mayroon|meron|open|available|free|bakante|taken|booked|reserved|we have|we can|we're|we are|we'd|it's|it is|there's|you're welcome|you may|our|the (rate|home|unit|nearest|nightly)|check-?in|check-?out|for \d+ nights?)\b|₱|php|\d/i;
const BANNED_EXTRA_RE = /\b(no pressure|walang pressure|completely understand|as an ai|language model)\b/i;
const R2_RULES: Violation[] = ['form_speak', 'robot_word', 'shouting', 'command_tone', 'exclaim', 'boilerplate', 'cold_opener'];
const INVITE_RE = /\b(on|sa) (our|aming|among|the) site\b|\bsite namin\b|\barrange (the|your|a|everything|it)\b|\bsecure (your|the|ang) (dates?|stay)\b|\bbook(ing)? (directly|direct) (on|sa|through)\b/i;
const ASKING_RE = /\b(you (may|can)|we can arrange|feel free|whenever you('re| are| feel)|when you('ve| have)|puwede|pwede|maaari|kapag|kung ready)\b/i;
const CHAT_RE = /\b(chat|tell us here|sabihin lang (po )?dito|ingna lang mi diri|share [^.?!\n]{0,20}(here|dito|diri))\b/i;
const DATES_ASK_RE = /\b(which|what) dates\b|\b(share|send|let us know|tell us)\b[^.?!\n]{0,30}\b(your|ang|inyong) (preferred |target )?dates\b|\bkailan po\b|\bwhen (would|will|are) you\b|\bunsa(ng)? (nga )?dates?\b|\bano(ng)? (po )?(mga )?(dates?|petsa)\b/i;
const PAX_ASK_RE = /\bhow many (guests|people|persons|of you|adults)\b|\bnumber of guests\b|\bilan (po )?(kayo|ang)\b|\bpila (mo|ka tawo|kabuok)\b/i;
const NAME_ASK_RE = /\bmay we (know|have|ask)[^.?!\n]{0,15}\bname\b|\byour name\s*\?|\bpangalan\b|\bngalan\b/i;
const GREET_RE = /^\s*(hello|hi|hey|good (morning|afternoon|evening)|maayong \p{L}+|magandang \p{L}+|kumusta|kamusta)\b/iu;
const TAGALOG_ONLY_RE = /\b(po|opo|pong|kayo|namin|niyo|kasya|hindi|ngayon|dito|iyong|aming)\b/i;
const UNCONTRACTED_RE = /(?<!\b(?:for|to|of|with|from) )\b(we|you|they) (will|are|would)\b|\b(it|that|there) is\b|\bdo not\b|\bdoes not\b|\bcannot\b/i;
const CAPACITY_RE = /\b(accommodate|welcome|fit|host|take)s?\b[^.?!\n]{0,25}\b(4|four|5|five|6|six) adults\b|\b(4|four|5|five|6|six) adults (is|are) (fine|okay|ok|welcome|possible)\b/i;
const ADDRESS_RE = /\b(block|blk\.?)\s*\d+|\blot\s*\d+/i;

/** Every peso figure a reply may state: the rate card, stay totals, savings, the reservation fee and balance,
 *  the deposit, hourly early check-in fees and the listed fares. Anything else was invented. */
export function allowedPesos(): Set<number> {
  const ok = new Set<number>([1780, 1000, 120, 180, 10, 50]);
  for (let h = 1; h <= 6; h++) ok.add(100 * h);
  for (const t of RATE_TIERS) { ok.add(t.rate); ok.add(1780 - t.rate); }
  for (let n = 1; n <= 60; n++) {
    const t = RATE_TIERS.find((x) => n >= x.min && n <= x.max)!;
    const total = n * t.rate, fee = Math.ceil(total / 2);
    for (const v of [total, n * 1780, n * (1780 - t.rate), fee, total - fee]) ok.add(v);
  }
  return ok;
}
const PESOS = allowedPesos();
export const pesosIn = (reply: string): number[] =>
  [...reply.matchAll(/(?:₱|\bPHP|\bPhp)\s?(\d{1,3}(?:,\d{3})+|\d+)/g)].map((m) => Number(m[1].replace(/,/g, '')));

const norm = (s: string) => s.toLowerCase().replace(/[^\p{L}\p{N} ]/gu, '').replace(/\s+/g, ' ').trim();
/** The last sentence a guest reads as "the close": link lines and the code's chat-route line are not it. */
export function closingSentence(reply: string): string {
  const lines = reply.split('\n').map((l) => l.trim()).filter((l) => l && !/^(👉|https?:\/\/)/.test(l) && !/^(Or simply tell us here|O sabihin lang po dito|O ingna lang mi diri)/.test(l));
  const last = lines[lines.length - 1] ?? '';
  const sentences = last.split(/(?<=[.!?])\s+/).filter(Boolean);
  return norm(sentences[sentences.length - 1] ?? '');
}

/** What the conversation already holds, from the guest's own turns (the current one included). */
export function heldFrom(guestTexts: string[], name: string | null): NonNullable<Ctx['held']> {
  const all = guestTexts.join(' \n ');
  return {
    dates: /\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? ?\d{1,2}\b|\b\d{1,2}[\/-]\d{1,2}\b/i.test(all),
    pax: /\b(\d{1,2}|one|two|three|four|isa|dalawa|tatlo|duha|tulo)\s*(adults?|pax|persons?|people|guests?|tao|tawo|kami|mi|of us)\b/i.test(all),
    name: Boolean(name),
  };
}

export function scoreReply(c: Ctx): Score {
  const s = Object.fromEntries(RUBRIC.map((r) => [r, null])) as Score;
  const r = c.reply, paras = paragraphs(r), voiced = c.kind === 'model' || c.kind === 'code';
  if (!r.trim()) { for (const k of RUBRIC) s[k] = 'empty reply'; return s; }
  const lint = lintReply(r, c.guest, { firstTurn: c.firstTurn, name: c.name });

  // R1 answers first (flow lines answer availability in code; a handoff line is the answer)
  if ((c.kind === 'model' || c.kind === 'midflow') && QUESTION_RE.test(c.guest)) {
    // a first-contact greeting paragraph ("Hi Ben, thank you for reaching out to Cascade Hideaway.") is not where the answer lives
    const first = c.firstTurn && GREET_RE.test(paras[0]) && paras[0].length < 110 && !/\d|₱/.test(paras[0]) ? (paras[1] ?? '') : paras[0];
    const opening = first.trim().split(/(?<=[.!?])\s+/).find((x) => !(GREET_RE.test(x) && x.length < 40)) ?? '';
    if (/\?\s*$/.test(opening)) s.R1 = 'the first sentence asks back';
    else if (lint.includes('no_answer') && !ANSWER_RE.test(first)) s.R1 = 'no answer in the first paragraph';
  }
  // R2 nothing banned (the midflow composite carries the approved card: its own lines were linted at build time)
  const banned = c.kind === 'midflow' ? [] : lint.filter((v) => R2_RULES.includes(v));
  const extra = BANNED_EXTRA_RE.exec(r)?.[0];
  if (banned.length || extra) s.R2 = [...banned, ...(extra ? [`"${extra}"`] : [])].join(', ');
  // R3 warmth present
  if (voiced && isCold(r)) s.R3 = 'substantive reply with no marker of care';
  // R4 one invitation, both routes, the link under its sentence
  if (c.kind !== 'flow' && c.kind !== 'midflow') {
    const invites = paras.filter((p) => p.includes(c.siteUrl) || (INVITE_RE.test(p) && ASKING_RE.test(p)));
    const dangling = paras.find((p) => /:\s*$/.test(p));
    const bare = paras.find((p, i) => p.includes(c.siteUrl) && (/^(👉|https?:\/\/)/.test(p) || (i === 0 && paras.length === 1)));
    const linked = paras.find((p) => p.includes(c.siteUrl));
    if (c.noInvite || c.kind === 'handoff') { if (invites.length) s.R4 = 'an invitation on a no-invitation turn'; }
    else if (invites.length > 1) s.R4 = `${invites.length} invitation paragraphs`;
    else if (dangling) s.R4 = 'a sentence ends in ":" with nothing under it';
    else if (bare) s.R4 = 'a bare link with no sentence above it';
    else if (linked && !/:\s*\n\s*(👉|https?:\/\/)/.test(linked)) s.R4 = 'the link is not directly under its sentence';
    else if (linked && !CHAT_RE.test(r)) s.R4 = 'the site is offered without the chat route';
  }
  // R5 never re-asks a held slot
  if (c.kind !== 'flow' && c.held) {
    const again = [c.held.dates && DATES_ASK_RE.test(r) && 'dates', c.held.pax && PAX_ASK_RE.test(r) && 'guests', c.held.name && NAME_ASK_RE.test(r) && 'name'].filter(Boolean);
    if (again.length) s.R5 = `re-asks ${again.join(', ')}`;
  }
  // R6 register
  const po = (r.match(/\bpo\b/gi) ?? []).length;
  if (c.lang === 'bis') { const t = TAGALOG_ONLY_RE.exec(r)?.[0]; if (t) s.R6 = `Tagalog "${t}" in a Bislish reply`; }
  else if (c.lang === 'tl') { if (po > 2 && c.kind !== 'flow') s.R6 = `${po} "po"`; else if (voiced && r.length > 120 && po === 0) s.R6 = 'Taglish reply without "po"'; }
  else if (voiced || c.kind === 'handoff') {
    if (po > (c.guestUsedPo ? 1 : 0)) s.R6 = `${po} "po" in an English reply`;
    else { const u = UNCONTRACTED_RE.exec(r)?.[0]; if (u && voiced) s.R6 = `uncontracted "${u}"`; }
  }
  // R7 no greeting on a follow-up; the name at most twice
  if (!c.firstTurn && voiced && GREET_RE.test(r)) s.R7 = 'greets again on a follow-up';
  else if (c.name) { const n = (r.match(new RegExp(`\\b${c.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'g')) ?? []).length; if (n > 2) s.R7 = `the name ${n} times`; }
  // R8 the close differs from the previous reply's
  if (voiced && c.prevReply) { const a = closingSentence(r); if (a.length > 12 && a === closingSentence(c.prevReply)) s.R8 = `same close twice: "${a}"`; }
  // R9 facts
  const strange = pesosIn(r).filter((v) => !PESOS.has(v));
  if (strange.length) s.R9 = `peso figure not on the rate card: ${strange.join(', ')}`;
  else if (CAPACITY_RE.test(r)) s.R9 = 'capacity exceeded';
  else if (ADDRESS_RE.test(r)) s.R9 = 'block or lot number';
  // R10 length
  if (voiced || c.kind === 'handoff') {
    if (r.length > 700) s.R10 = `${r.length} characters`;
    else if (paras.length > 4) s.R10 = `${paras.length} paragraphs`;
    else if (paras.some((p) => p.replace(/\n.*$/s, '').length > 320)) s.R10 = 'a paragraph over 320 characters';
    else if ((r.match(/\?/g) ?? []).length > 2) s.R10 = 'more than two questions';
    else if (c.kind === 'model' && r.length > 260 && paras.length < 2) s.R10 = 'one block of text';
  }
  // X the case's own expectations
  const miss = (c.must ?? []).find((re) => !re.test(r)), hit = (c.mustNot ?? []).find((re) => re.test(r));
  if (miss) s.X = `expected ${miss}`; else if (hit) s.X = `must not match ${hit}`;
  return s;
}
export const failures = (s: Score): string[] => RUBRIC.filter((k) => s[k]).map((k) => `${k}: ${s[k]}`);
