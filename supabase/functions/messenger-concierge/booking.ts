// Messenger book intent (booking PRD §A, session 27). Pure functions, no I/O: a code-driven
// slot-filling flow that index.ts runs BEFORE the model. The model never books; it only answers
// questions. State is one jsonb on concierge_threads.booking_flow.
import { RATE_TIERS } from '../_shared/cascade-core/facts.ts';

/** Register: en = Native English protocol, tl = Native Filipino (Taglish, purposeful po), bis = Native Bisaya (Bislish, no po). */
export type Lang = 'en' | 'tl' | 'bis';
export const pick = (lang: Lang | undefined, t: { en: string; tl: string; bis: string }): string => t[lang ?? 'en'];
export type Flow = {
  step: 'dates' | 'checkout' | 'pax' | 'contact' | 'confirm' | 'await_receipt' | 'receipt_sent' | 'confirmed' | 'cancelled';
  checkin?: string; checkout?: string; pax?: number; phone?: string; email?: string | null;
  /** session 28: the guest's choice - reservation fee (50 %) or the full amount; forced full inside 48 h */
  pay_full?: boolean; asked?: 'availability' | 'question' | null;
  /** session 28: the guest's register, re-read on every turn - 'tl' = Taglish with "po" (Tagalog or Bisaya guests) */
  lang?: Lang;
  booking_id?: string; ref?: string; deposit?: number; total?: number; hold?: boolean; hold_expires_at?: string | null;
  receipt_token?: string; receipt_expires_at?: string; started_at: string; updated_at: string;
};

export const BOOK_RE = /\b(book(ing)?|reserve|reservation|magpa-?book|pa-?book|i-?book|mag-?reserve|hold (the|my|our) dates)\b/i;
const CANCEL_RE = /\b(cancel|stop|wag na|huwag|never ?mind|nevermind|not now|forget it)\b/i;
const YES_RE = /^\s*(yes|yes po|oo|oo po|sige|sige po|go|confirm|confirmed|ok|okay|okay po|ok po|proceed|tama|correct|yup|yep|y)\s*[.!]*\s*$/i;
const SKIP_RE = /^\s*(skip|wala|none|no email|no)\s*[.!]*\s*$/i;
const FULL_RE = /\b(full|buo|buong|lahat|whole|everything|total|bayaran (ko )?lahat|in full)\b/i;
const DEPOSIT_RE = /\b(deposit|reservation fee|fee|50|half|kalahati|reserve|partial|down ?payment|dp)\b/i;
const AVAIL_RE = /\b(available|avail|vacant|bakante|open|free|may (?:vacancy|slot)|meron pa)\b/i;
const ASK_RE = /\?|\b(magkano|how much|pwede|can (i|we)|is (it|there)|are there|meron)\b/i;
/** Same markers as index.ts guestLang(): Tagalog or Bisaya words, or two particles, mean Taglish; a lone courtesy "po" stays English. */
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
export function parseEmail(text: string): string | null {
  const m = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.exec(text);
  return m ? m[0].toLowerCase() : null;
}

const dm = (d: string) => { const x = new Date(d + 'T00:00:00Z'); return `${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][x.getUTCMonth()]} ${x.getUTCDate()}`; };
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
/** A code answer to "is it available?" from the calendar rows that overlap the stay (pure: index.ts fetches). */
export function availabilityLine(flow: Flow, bookedNights: Set<string>): string {
  if (!flow.checkin || !flow.checkout) return '';
  const dates = `${dm(flow.checkin)} to ${dm(flow.checkout)}`;
  for (let d = flow.checkin; d < flow.checkout; d = new Date(Date.parse(d + 'T00:00:00Z') + 86_400_000).toISOString().slice(0, 10)) {
    if (bookedNights.has(d)) return pick(flow.lang, {
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
export function prompt(flow: Flow, name: string | null): string {
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
    case 'contact': return pick(L, {
      en: `May we have your mobile number, so we can reach you about your stay? You're welcome to add an e-mail address as well, if you'd like your confirmation there.`,
      tl: `Maaari po ba naming makuha ang inyong contact number, para ma-contact namin kayo about the stay? Puwede rin po kayong mag-add ng e-mail if gusto ninyong doon matanggap ang confirmation.`,
      bis: `Pwede namo makuha ang inyong contact number, para ma-contact namo mo about the stay? Pwede pud i-add ang e-mail if gusto ninyo didto ma-receive ang confirmation.`,
    });
    case 'confirm': { const q = quoteTotal(flow.checkin!, flow.checkout!); return [
      pick(L, { en: `Here are your stay details:`, tl: `Ito po ang details ng stay ninyo:`, bis: `Mao ni ang details sa stay ninyo:` }),
      `📅 ${dm(flow.checkin!)} to ${dm(flow.checkout!)} · ${q.nights} night${q.nights === 1 ? '' : 's'} · ${flow.pax} guest${flow.pax === 1 ? '' : 's'}`,
      `📞 ${flow.phone}${flow.email ? ` · ${flow.email}` : ''}`,
      `💰 Total ${peso(q.total)}`,
      ``,
      flow.pay_full === true
        ? pick(L, {
            en: `As your check-in is near, the full ${peso(q.total)} secures your stay. You may reply FULL to send your request through, or let us know if anything needs changing.`,
            tl: `Malapit na po ang check-in, kaya ang full ${peso(q.total)} ang magse-secure ng stay. You may reply FULL to send the request through, or sabihin lang po if may kailangang baguhin.`,
            bis: `Duol na ang check-in, so ang full ${peso(q.total)} ang mag-secure sa stay. Pwede mo mu-reply og FULL para ma-send ang request, or ingna lang mi if naa may changes.` })
        : pick(L, {
            en: `To secure your stay, you may reply DEPOSIT to reserve with ${peso(q.deposit)} now and settle the balance at check-in, or FULL to settle ${peso(q.total)} now. Either sends your request through. If anything needs changing, just let us know.`,
            tl: `Para ma-secure ang stay, you may reply DEPOSIT (${peso(q.deposit)} now, balance at check-in) or FULL (${peso(q.total)} now). Either one sends the request through. If may kailangang baguhin, sabihin lang po.`,
            bis: `Para ma-secure ang stay, pwede mo mu-reply og DEPOSIT (${peso(q.deposit)} now, balance at check-in) or FULL (${peso(q.total)} now). Bisan asa sa duha, ma-send na ang request. If naa may changes, ingna lang mi.` }),
    ].join('\n'); }
    default: return '';
  }
}

export type Step = { flow: Flow; reply: string | null; action: 'ask' | 'submit' | 'cancelled' | 'passthrough' };

/** Start a flow from the first message; prefills dates and guests when they are in the text. */
export function start(text: string, now = new Date()): Flow {
  const at = now.toISOString();
  const flow: Flow = { step: 'dates', started_at: at, updated_at: at, lang: detectLang(text) };
  const d = parseDates(text, now);
  const today = at.slice(0, 10);
  if (d[0] && d[0] >= today) { flow.checkin = d[0]; flow.step = 'checkout'; }
  if (flow.checkin && d[1] && d[1] > flow.checkin) { flow.checkout = d[1]; flow.step = 'pax'; }
  const p = /\b(\d|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\s*(adults?|pax|persons?|people|guests?|tao|tawo|kami|mi|ka|kabuok)\b/i.test(text) || /\b(?:for|para sa|kaming)\s+(\d|one|two|three|four|isa|dalawa|tatlo|apat)\b(?!\s*(?:nights?|days?|gabi|araw))/i.test(text) ? parsePax(text) : null;
  if (p && flow.step === 'pax') { flow.pax = p; flow.step = 'contact'; }
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
    const d = detectLang(text); if (d !== 'en') f.lang = d; else if (words.length >= 2) f.lang = 'en'; }
  const L = f.lang;
  const today = f.updated_at.slice(0, 10);
  if (CANCEL_RE.test(text) && f.step !== 'await_receipt') return { flow: { ...f, step: 'cancelled' }, reply: pick(L, { en: `Of course. Nothing has been sent, and you're welcome to come back to this whenever it suits you — just say "book" and we'll pick up from here.`, tl: `Sige po, no problem. Wala pong na-send. Message lang po "book" anytime and we'll pick up from here.`, bis: `Sige, walay problema. Wala pay na-send. Message lang "book" anytime and we'll pick up from here.` }), action: 'cancelled' };
  const ask = (reply?: string): Step => ({ flow: f, reply: reply ?? null, action: 'ask' });
  const retry = (what: string): Step => text.includes('?') ? { flow: f, reply: null, action: 'passthrough' } : ask(pick(L, { en: `Sorry, I couldn't quite make out ${what}. ${prompt(f, null)}`, tl: `Sorry po, hindi ko nakuha ${what === 'the mobile number' ? 'ang mobile number' : what === 'the dates' ? 'ang dates' : what === 'the check-out date' ? 'ang check-out date' : what === 'the number of guests' ? 'kung ilan kayo' : 'iyon'}. ${prompt(f, null)}`, bis: `Sorry, wala nako nakuha ${what === 'the mobile number' ? 'ang mobile number' : what === 'the dates' ? 'ang dates' : what === 'the check-out date' ? 'ang check-out date' : what === 'the number of guests' ? 'pila mo' : 'to'}. ${prompt(f, null)}` }));
  switch (f.step) {
    case 'dates': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the dates');
      if (d[0] < today) return ask(pick(L, { en: `That date has already passed. Which upcoming dates would suit you?`, tl: `Lumipas na po ang date na iyon. Aling upcoming dates po ang gusto ninyo?`, bis: `Lapas na ang date nga na. Unsang upcoming dates ang gusto ninyo?` }));
      f.checkin = d[0]; f.step = 'checkout';
      if (d[1] && d[1] > d[0]) { f.checkout = d[1]; f.step = f.pax ? 'contact' : 'pax'; }
      return ask();
    }
    case 'checkout': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the check-out date');
      if (d[0] <= f.checkin!) return ask(pick(L, { en: `Check-out would need to fall after ${dm(f.checkin!)}. Until which date would you like to stay?`, tl: `Kailangan po after ${dm(f.checkin!)} ang check-out. Hanggang kailan po ang stay ninyo?`, bis: `Kinahanglan after ${dm(f.checkin!)} ang check-out. Hangtod kanus-a ang stay ninyo?` }));
      f.checkout = d[0]; f.step = f.pax ? 'contact' : 'pax'; return ask();
    }
    case 'pax': {
      const p = parsePax(text);
      if (!p) return retry('the number of guests');
      if (p > 4) return ask(pick(L, { en: `As much as we'd love to host everyone, the home is most comfortable for up to 3 adults, or 2 adults with 2 children. For a party of ${p}, a larger place would give you more room to rest. If your group fits, just let us know the count again.`, tl: `Comfortable po ang home for up to 3 adults, or 2 adults with 2 kids. For ${p}, mas maganda po ang mas malaking place para mas may space kayo. If kasya po ang group ninyo, sabihin lang po ulit kung ilan kayo.`, bis: `Comfortable ang home for up to 3 adults, or 2 adults with 2 kids. For ${p}, mas maayo ang mas dako nga place para mas naa moy space. If kasya ang group ninyo, ingna lang mi pila mo.` }));
      f.pax = p; f.step = 'contact'; return ask();
    }
    case 'contact': {
      const ph = parsePhone(text);
      if (!ph) return retry('the mobile number');
      f.phone = ph; f.email = parseEmail(text) ?? null;
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
      if (wantsDeposit) { if (f.pay_full !== true) f.pay_full = false; return { flow: f, reply: null, action: 'submit' }; }
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
  const a = dm(flow.checkin!), z = dm(flow.checkout!);
  const dates = a.slice(0, 3) === z.slice(0, 3) ? `${a}–${z.slice(4)}` : `${a}–${z}`; // "Oct 20–22", "Sep 30–Oct 2"
  const rel = flow.hold_expires_at ? relDay(flow.hold_expires_at, now, flow.lang) : '';
  const dep = peso(flow.deposit!), bal = peso(flow.total! - flow.deposit!), what = full ? 'payment' : 'initial payment';
  // D-168/D-169: Lloyd's section-24 (Filipino), section-30 balanced Bislish (Bisaya) and section-6 (English) targets,
  // with the 24-hour hold and the relative day. Order: status -> next step -> convenience -> confirmation -> balance -> close.
  const L = flow.lang;
  const head = flow.hold && until
    ? pick(L, {
        en: `Hi ${n || 'there'}, 🌿\nWe've set aside ${dates} for you for 24 hours, until ${until} (${rel}). Your booking reference is ${flow.ref}.`,
        tl: `Hi ${n || 'po'}! 🌿\nNa-hold na po namin ang ${dates} for you for 24 hours — until ${until} (${rel}). Ang booking reference ninyo po ay ${flow.ref}.`,
        bis: `Hi ${n || 'diha'}! 🌿\nNa-hold na namo ang ${dates} for you for 24 hours — until ${until} (${rel}). Your booking reference is ${flow.ref}.` })
    : pick(L, {
        en: `Hi ${n || 'there'}, 🌿\nWe've received your request for ${dates}. Your booking reference is ${flow.ref}. As your stay is near, we'll confirm as soon as your payment arrives.`,
        tl: `Hi ${n || 'po'}! 🌿\nReceived na po namin ang request ninyo for ${dates}. Ang booking reference ninyo po ay ${flow.ref}. Malapit na ang stay, kaya iko-confirm namin as soon as dumating ang payment.`,
        bis: `Hi ${n || 'diha'}! 🌿\nNa-receive na namo ang request ninyo for ${dates}. Your booking reference is ${flow.ref}. Duol na ang stay, so amo dayon i-confirm once muabot ang payment.` });
  const pay = pick(L, {
    en: `To secure the stay, you may send the ${dep} ${what} through GCash (0956 011 5744) using the QR below. The exact amount is already set. Once done, simply send the receipt here and we'll confirm the reservation.`,
    tl: `Para ma-secure ang stay, you may send the ${dep} ${what} through GCash (0956 011 5744) using the QR below. Naka-set na po ang exact amount for convenience. Once done, send lang po the receipt screenshot here at iko-confirm na namin ang reservation.`,
    bis: `Para ma-secure ang stay, pwede na ma-send ang ${dep} ${what} through GCash (0956 011 5744) gamit ang QR below. Naka-set na daan ang exact amount para convenient. Once done, send lang ang screenshot sa receipt diri and we'll take care of the confirmation.` });
  const later = full
    ? pick(L, { en: `Only the ₱1,000 refundable security deposit remains, which may be settled at check-in.`, tl: `Ang ₱1,000 refundable security deposit na lang po ang natitira, which can be settled at check-in.`, bis: `Ang ₱1,000 refundable security deposit na lang ang nabilin, which can be settled at check-in.` })
    : pick(L, { en: `The remaining ${bal} balance and ₱1,000 refundable security deposit may be settled at check-in.`, tl: `The remaining ${bal} balance and ₱1,000 refundable security deposit ay puwede pong i-settle sa check-in.`, bis: `Ang remaining ${bal} balance and ₱1,000 refundable security deposit can be settled at check-in.` });
  const close = pick(L, { en: `Thank you${nm}. We look forward to welcoming you to Cascade Hideaway. 🌿`, tl: `Salamat po${nm}. We look forward to welcoming you to Cascade Hideaway. 🌿`, bis: `Salamat${nm}. Looking forward mi sa inyong stay at Cascade Hideaway. 🌿` });
  return [head, '', pay, '', later, '', close].join('\n');
}
