// R_draft (s82 lane R): turns one guest message into 1-3 labelled options for the app: Warm (the usual draft), Short (a real
// two-sentence reply) and With details (only when the guest asked something with a factual answer). Reuses telegram-cassy/draft.ts as is.
//
// PRIVACY (hard rule): access 'limited' (every staff role except owner/admin, the cleaner above all) NEVER reads guest data. It skips
// draftGuestReply entirely (that reads guestContext = booking, balance, contact, and calls the concierge probe) and uses only
// modelDraft with ctx = [] in the Airbnb-safe register (no rates, no links, no payment details), then drops any option that carries
// a phone, e-mail or amount that was not in the text or screenshot she supplied.
import { airbnbFallback, airbnbFinish, airbnbTone, calmMoment, draftGuestReply, draftPlatform, draftSystem, guestReg, modelDraft, type Line, type Platform } from '../telegram-cassy/draft.ts';
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
  model(db: unknown, text: string, name: string | null, ctx: string[], airbnb: boolean, hint: string, calm: boolean, before: Line[]): Promise<string>;
  variants(db: unknown, main: string, guestText: string, airbnb: boolean, calm: boolean): Promise<Variants>;
}

export const REAL: Impl = {
  guestReply: (db, t, n, th) => draftGuestReply(db, t, n, th),
  model: (db, t, n, ctx, a, h, c, b) => modelDraft(db, t, n, ctx, a, h, c, b),
  async variants(db, main, guestText, airbnb, calm) {
    const card = await loadCard(db as never);
    const question = `The host will probably send this reply:\n"""${main.slice(0, 1500)}"""\nThe guest wrote:\n"""${guestText.slice(0, 1500)}"""\n` +
      `Write two alternatives in the same language and register, with the same facts and nothing new that is not in FACTS or in that reply. This answer format replaces the {"reply"} one: return ONLY JSON {"short": string, "details": string|null}. ` +
      `"short": a real two-sentence reply (the answer, then one warm closing sentence), not a cut-down copy.${airbnb ? ' Keep the greeting line and the two sign-off lines.' : ''} ` +
      `"details": only when the guest asked something that has a factual answer in FACTS worth spelling out (times, how something works, what is included): the same reply with that answer expanded, five sentences at most; otherwise null.`;
    const raw = await chatJson({ system: draftSystem(card, airbnb, calm), history: [], question, title: 'Cascade Cassy options', temperature: 0.6, maxTokens: 800, timeoutMs: 30_000 });
    return parseModelJson<Variants>(raw, {});
  },
};

const norm = (s: string) => s.toLowerCase().replace(/\s+/g, ' ').trim();
const EMAIL = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g;
const PHONE = /\+?\d(?:[\s().-]?\d){8,}/g;
const MONEY = /(?:PHP|₱|\bP)\s?\d[\d,]*(?:\.\d+)?|\d[\d,]*(?:\.\d+)?\s?(?:php\b|pesos?\b)/gi;
const digits = (s: string) => s.replace(/\D/g, '');

/** True when `text` carries an e-mail, phone number or peso amount that `input` (what the staff member supplied) does not. */
export function introducesData(text: string, input: string): boolean {
  const lowIn = input.toLowerCase(), digIn = digits(input);
  if ((text.match(EMAIL) ?? []).some((e) => !lowIn.includes(e.toLowerCase()))) return true;
  if ((text.match(PHONE) ?? []).some((p) => !digIn.includes(digits(p)))) return true;
  return (text.match(MONEY) ?? []).some((m) => !digIn.includes(digits(m)));
}

export async function draftOptions(db: unknown, a: { guestText: string; guestName: string | null; thread: Thread; access: Access }, impl: Impl = REAL): Promise<DraftOut> {
  const { guestText, guestName, thread, access } = a;
  const src = draftPlatform(guestText, thread.platform);
  const limited = access !== 'full'; // anything that is not positively 'full' is treated as limited
  const airbnb = limited || src.platform === 'airbnb';
  const calm = airbnb && calmMoment(src.text, classify(src.text, { hasBooking: true }));
  const lang = guestReg(src.text);
  let header: string, main: string, legacyShort = '';

  if (limited) {
    main = await impl.model(db, src.text, guestName, [], true, '', calm, thread.before ?? []);
    header = [`✍️ Guest reply${guestName ? ` · ${guestName}` : ''}`, 'These are drafted from what you shared only: dates, rates and bookings were not checked.', 'Nothing was sent.'].join('\n');
  } else {
    const out = await impl.guestReply(db, guestText, guestName, thread);
    header = String(out[0] ?? ''); main = String(out[1] ?? ''); legacyShort = String(out[2] ?? '');
    header = header.split('\n').filter((l) => !/^2️⃣/.test(l)).join('\n').replace(/^1️⃣ is /m, 'The Warm option is ');
  }
  if (!main.trim()) throw new Error('no_replies');

  // One call for Short and With details. A failure here costs the extra options, never the main reply.
  const v = await impl.variants(db, main, src.text, airbnb, calm).catch(() => ({} as Variants));
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
  const seen = new Set([norm(warm)]);
  const add = (label: string, raw: unknown, shorter: boolean) => {
    const t = pass(raw);
    if (!safe(t) || seen.has(norm(t)) || (shorter && t.length >= warm.length)) return;
    seen.add(norm(t)); options.push({ label, text: t });
  };
  add('Short', v.short, true);
  if (options.length < 2 && legacyShort) add('Short', legacyShort, true);
  add('With details', v.details, false);
  return { header, options };
}
