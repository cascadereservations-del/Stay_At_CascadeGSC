// R_draft (s82 lane R): turns one guest message into 1-3 labelled options for the app: Warm (the usual draft), Short (a real
// two-sentence reply) and With details (only when the guest asked something with a factual answer). Reuses telegram-cassy/draft.ts as is.
//
// PRIVACY (hard rule): access 'limited' (every staff role except owner/admin, the cleaner above all) NEVER reads guest data. It skips
// draftGuestReply entirely (that reads guestContext = booking, balance, contact, and calls the concierge probe) and uses only
// modelDraft with ctx = [] in the Airbnb-safe register (no rates, no links, no payment details), then drops any option that carries
// a phone, e-mail or amount that was not in the text or screenshot she supplied.
import { airbnbFallback, airbnbFinish, airbnbGuard, airbnbTone, calmMoment, draftGuestReply, draftPlatform, draftSystem, guestReg, HEADER_HANDOFF, HEADER_RISK, historyBlock, type Line, type Platform } from '../telegram-cassy/draft.ts';
import { guestContext, guestContextLines } from '../_shared/cascade-core/tools.ts';
import { loadContact } from '../_shared/cascade-core/contact.ts';
import { classify } from '../messenger-concierge/policy.ts';
import { leafAtClose, lintReply, toneRules } from '../messenger-concierge/voice.ts';
import { loadCard } from '../_shared/cascade-core/pricing.ts';
import { chatJson } from '../_shared/cascade-core/providers.ts';
import { parseModelJson } from '../_shared/cascade-core/vision.ts';

export type Access = 'full' | 'limited';
export type Option = { label: string; text: string };
export type DraftOut = { header: string; options: Option[] };
export type Thread = { before?: Line[]; platform?: Platform };
type Variants = { short?: unknown; details?: unknown };

export interface Impl {
  guestReply(db: unknown, text: string, name: string | null, thread: Thread): Promise<string[]>;
  /** Limited path: Warm, Short and With details in ONE model call (no guest context; Airbnb-safe register). */
  modelAll(db: unknown, text: string, name: string | null, calm: boolean, before: Line[], lang: string): Promise<{ main: string; variants: Variants }>;
  variants(db: unknown, a: { text: string; name: string | null; airbnb: boolean; calm: boolean; before: Line[]; full: boolean }): Promise<Variants>;
}

/** Mirrors modelDraft's date guard (telegram-cassy/draft.ts): the limited path cannot see the calendar or any reservation. */
const DATES_ASKED = /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s*\d{1,2}|\d{1,2}[/-]\d{1,2}|\b(?:available|avail|vacant|bakante|free)\b|\bcheck-?\s?(?:in|out)\b|\b(?:today|tomorrow|tonight|extend|another night)\b/i;
const DATES_HINT = "[The guest mentions dates, availability or their stay. You cannot see the calendar or this guest's reservation: never say dates are available or taken, and never state or confirm which day or date their own stay starts or ends; say you will check the booking and confirm here. The house check-in and check-out times in FACTS may be stated.] ";
const STRICT = '[AIRBNB RULE - the last draft broke it: no link or URL, no phone, no e-mail, no GCash or QR, no peso, PHP or percentage figure, and never "book directly", "direct rate" or "our site". For a price or discount question, say you will check and confirm here on the listing, with no number. If dates are asked, say you will check and confirm.] ';
const ALL_FORMAT = `\nThis answer format replaces the {"reply"} one: return ONLY JSON {"reply": string, "short": string, "details": string|null}. "reply": the warm reply. "short": a real two-sentence reply (the answer, then one warm closing sentence), not a cut-down copy; keep the greeting line and the two sign-off lines. "details": only when the guest asked something that has a factual answer in FACTS worth spelling out (times, how something works, what is included): the same reply with that answer expanded, five sentences at most; otherwise null. Same language and register in all three; nothing new that is not in FACTS.`;

export const REAL: Impl = {
  guestReply: (db, t, n, th) => draftGuestReply(db, t, n, th, { skipShort: true }), // Short comes from the parallel variants call
  async modelAll(db, text, name, calm, before, lang) {
    const [card] = await Promise.all([loadCard(db as never), loadContact(db as never)]); // house facts side by side, not one after the other
    const system = draftSystem(card, true, calm);
    const q = `${DATES_ASKED.test(text) ? DATES_HINT : ''}${historyBlock(before)}${name ? `Guest name: ${name}\n` : ''}Guest wrote:\n"""${text.slice(0, 1500)}"""`;
    let v: Variants = {};
    const gen = async (strict: boolean) => {
      const raw = await chatJson({ system, history: [], question: (strict ? STRICT : '') + q + (strict ? '' : ALL_FORMAT), title: 'Cascade Cassy draft', temperature: 0.5, maxTokens: strict ? 500 : 1100, timeoutMs: 30_000 });
      const j = parseModelJson<{ reply?: string } & Variants>(raw, {});
      v = strict ? {} : { short: j.short, details: j.details }; // a regenerated Warm discards the batch that came with the leaking one
      return leafAtClose(String(j.reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'));
    };
    // Same gate as modelDraft: a leaking Warm draft is regenerated once (reply only), then replaced by the code-written fallback.
    const main = await airbnbGuard(gen, (m) => airbnbFinish(m, lang as 'en' | 'tl' | 'bis', calm), airbnbFallback(name, calm));
    return { main, variants: v };
  },
  /** Short and With details written from the guest's own message (not as rewrites of Warm), so this runs in PARALLEL with the Warm draft.
   *  Same register, house facts and date guard as Warm; on the full path also the guest context that owner/admin may see. */
  async variants(db, a) {
    const [card, ctx] = await Promise.all([
      loadCard(db as never),
      a.full && a.name ? guestContext(db, { name: a.name }).then(guestContextLines).catch(() => [] as string[]) : Promise.resolve([] as string[]),
      loadContact(db as never),
    ]);
    const question = `${DATES_ASKED.test(a.text) ? DATES_HINT : ''}${a.airbnb ? historyBlock(a.before) : ''}${a.name ? `Guest name: ${a.name}\n` : ''}${ctx.length ? `What we know about this guest:\n${ctx.join('\n')}\n` : ''}Guest wrote:\n"""${a.text.slice(0, 1500)}"""\n` +
      `Write two alternative replies the host could send, in the guest's language and register, using only what is in FACTS (and the guest context above): never contradict FACTS, never invent a time, amount or date. This answer format replaces the {"reply"} one: return ONLY JSON {"short": string, "details": string|null}. ` +
      `"short": a real two-sentence reply (the answer, then one warm closing sentence).${a.airbnb ? ' Keep the greeting line and the two sign-off lines.' : ''} ` +
      `"details": only when the guest asked something that has a factual answer in FACTS worth spelling out (times, how something works, what is included): a warm reply with that answer spelled out, five sentences at most; otherwise null.`;
    const raw = await chatJson({ system: draftSystem(card, a.airbnb, a.calm), history: [], question, title: 'Cascade Cassy options', temperature: 0.6, maxTokens: 800, timeoutMs: 30_000 });
    return parseModelJson<Variants>(raw, {});
  },
};

const EMAIL = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g;
const PHONE = /\+?\d(?:[\s().-]?\d){8,}/g;
const NUM = /\d+(?:,\d{3})*(?:\.\d+)?\s?k?\b/gi;
const AMOUNT = /(?:PHP|₱|\bP)\s?(\d+(?:,\d{3})*(?:\.\d+)?)|(\d+(?:,\d{3})*(?:\.\d+)?)\s?(?:php\b|pesos?\b)|\b(\d+(?:\.\d+)?)\s?k\b/gi;
const WORDS = /\b(?:hundred|thousand|million)\b/gi;
const digits = (s: string) => s.replace(/\D/g, '');
const val = (s: string) => { const k = /k\s*$/i.test(s); const n = parseFloat(s.replace(/[,k\s]/gi, '')); return k ? n * 1000 : n; };

/** True when `text` carries an e-mail, phone number or amount (digits, 3.5k, or "three thousand") that `input` (what the staff member
 *  supplied) does not. ponytail: a spelled amount is caught by its magnitude word only, and a bare number without a currency is left to airbnbTone. */
export function introducesData(text: string, input: string): boolean {
  const lowIn = input.toLowerCase();
  if ((text.match(EMAIL) ?? []).some((e) => !lowIn.includes(e.toLowerCase()))) return true;
  const phonesIn = new Set((input.match(PHONE) ?? []).map((p) => digits(p).slice(-10)));
  if ((text.match(PHONE) ?? []).some((p) => !phonesIn.has(digits(p).slice(-10)))) return true;
  const nums = new Set((input.match(NUM) ?? []).map(val));
  for (const m of text.matchAll(AMOUNT)) if (!nums.has(val(m[1] ?? m[2] ?? m[3] + 'k'))) return true;
  return (text.match(WORDS) ?? []).some((w) => !lowIn.includes(w.toLowerCase()));
}
const TIME = /\b(\d{1,2})(?::(\d{2}))?\s?([ap])\.?m\b/gi;
const DATE = /\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*(\d{1,2})\b/gi;
/** The checkable facts in a text: clock times, peso amounts and month-day dates, normalised. */
function facts(t: string): Record<'times' | 'amounts' | 'dates', Set<string>> {
  return {
    times: new Set([...t.matchAll(TIME)].map((m) => `${+m[1]}:${m[2] ?? '00'}${m[3].toLowerCase()}`)),
    amounts: new Set([...t.matchAll(AMOUNT)].map((m) => String(val(m[1] ?? m[2] ?? m[3] + 'k')))),
    dates: new Set([...t.matchAll(DATE)].map((m) => `${m[1].toLowerCase()}${+m[2]}`)),
  };
}
/** An option written independently of Warm may repeat a time, amount or date but never introduce one: every such token in it must
 *  also appear in Warm or in the guest's own message. (Warm is the only text the concierge's fact guards have checked.) */
export function contradicts(opt: string, warm: string, guestText = ''): boolean {
  const a = facts(opt), w = facts(`${warm}\n${guestText}`);
  return (['times', 'amounts', 'dates'] as const).some((k) => [...a[k]].some((x) => !w[k].has(x)));
}
const jaccard = (a: string, b: string) => {
  const A = new Set(a.toLowerCase().match(/[a-z0-9']+/g) ?? []), Bs = new Set(b.toLowerCase().match(/[a-z0-9']+/g) ?? []);
  let n = 0; for (const w of A) if (Bs.has(w)) n++;
  return A.size + Bs.size - n ? n / (A.size + Bs.size - n) : 1;
};

/** The user never waits longer than this for Short / With details: after it the response goes out with what is ready (Warm). */
export const VARIANTS_BUDGET_MS = 8000;
async function withBudget(p: Promise<Variants>, ms: number, onTimeout: () => void): Promise<Variants> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<Variants>((res) => { timer = setTimeout(() => { onTimeout(); res({}); }, ms); });
  try { return await Promise.race([p, late]); } finally { clearTimeout(timer); }
}

export async function draftOptions(db: unknown, a: { guestText: string; guestName: string | null; thread: Thread; access: Access }, impl: Impl = REAL, opts: { budgetMs?: number; log?: (line: string) => void } = {}): Promise<DraftOut> {
  const { guestText, guestName, thread, access } = a;
  const src = draftPlatform(guestText, thread.platform);
  const limited = access !== 'full'; // anything that is not positively 'full' is treated as limited
  const airbnb = limited || src.platform === 'airbnb';
  const calm = airbnb && calmMoment(src.text, classify(src.text, { hasBooking: true }));
  const lang = guestReg(src.text);
  let header: string, main: string;
  let vp: Promise<Variants> | undefined; // Short / With details: from the single limited call, or (full) started NOW, in parallel with the Warm draft

  if (limited) {
    const r = await impl.modelAll(db, src.text, guestName, calm, thread.before ?? [], lang);
    main = r.main; vp = Promise.resolve(r.variants);
    header = [`✍️ Guest reply${guestName ? ` · ${guestName}` : ''}`, 'These are drafted from what you shared only: dates, rates and bookings were not checked.', 'Nothing was sent.'].join('\n');
  } else {
    vp = impl.variants(db, { text: src.text, name: guestName, airbnb, calm, before: thread.before ?? [], full: true });
    vp.catch(() => {}); // a failure is handled where it is awaited; never an unhandled rejection if Warm fails first
    const out = await impl.guestReply(db, guestText, guestName, thread);
    header = String(out[0] ?? ''); main = String(out[1] ?? '');
    header = header.split('\n').filter((l) => !/^2️⃣/.test(l)).join('\n').replace(/^1️⃣ is /m, 'The Warm option is ');
  }
  if (!main.trim()) throw new Error('no_replies');

  // A failure or a slow variants call costs the extra options, never the main reply.
  // A hand-off or risk line in the header means Warm is the concierge's hand-over (or a flagged matter): Short / With details, written
  // without its fact guards, are not offered. The variants call may still be in flight; its result is ignored.
  const flagged = !limited && header.split('\n').some((l) => l.startsWith(HEADER_HANDOFF) || l.startsWith(HEADER_RISK));
  const v = flagged ? ({} as Variants) : await withBudget(vp!.catch(() => ({} as Variants)), opts.budgetMs ?? VARIANTS_BUDGET_MS, () => opts.log?.(JSON.stringify({ fn: 'guest_reply_draft', event: 'variants_budget_exceeded', ms: opts.budgetMs ?? VARIANTS_BUDGET_MS })));
  const pass = (m: unknown): string => {
    const t = typeof m === 'string' ? m.trim() : '';
    if (!t) return '';
    if (airbnb) { const f = airbnbFinish(t, lang, calm); return airbnbTone(f, calm).length ? '' : f; }
    const f = leafAtClose(t);
    return lintReply(f, src.text).length || toneRules(f, lang).length ? '' : f;
  };
  const input = [src.text, guestName ?? '', ...(thread.before ?? []).map((l) => l.text)].join('\n');
  const safe = (t: string) => !!t && (!limited || !introducesData(t, input));

  const mainOk = limited ? (safe(main) ? main : '') : main; // the full-access main reply is kept as today (lint only warns)
  const warm = mainOk || airbnbFinish(airbnbFallback(guestName, calm), lang, calm);
  const options: Option[] = [{ label: 'Warm', text: warm }];
    const add = (label: string, raw: unknown, shorter: boolean) => {
    const t = pass(raw);
    if (!safe(t) || contradicts(t, warm, src.text) || options.some((o) => jaccard(o.text, t) > 0.9) || (shorter && t.length >= warm.length)) return;
    options.push({ label, text: t });
  };
  add('Short', v.short, true);
  add('With details', v.details, false);
  return { header, options };
}
