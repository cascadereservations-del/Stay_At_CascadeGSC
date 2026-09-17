// Messenger book intent (booking PRD §A, session 27). Pure functions, no I/O: a code-driven
// slot-filling flow that index.ts runs BEFORE the model. The model never books; it only answers
// questions. State is one jsonb on concierge_threads.booking_flow.
import { RATE_TIERS } from '../_shared/cascade-core/facts.ts';

export type Flow = {
  step: 'dates' | 'checkout' | 'pax' | 'contact' | 'confirm' | 'await_receipt' | 'receipt_sent' | 'confirmed' | 'cancelled';
  checkin?: string; checkout?: string; pax?: number; phone?: string; email?: string | null;
  /** session 28: the guest's choice - reservation fee (50 %) or the full amount; forced full inside 48 h */
  pay_full?: boolean; asked?: 'availability' | 'question' | null;
  /** session 28: the guest's register, re-read on every turn - 'tl' = Taglish with "po" (Tagalog or Bisaya guests) */
  lang?: 'en' | 'tl';
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
export function detectLang(text: string): 'en' | 'tl' {
  const t = ` ${text.toLowerCase()} `;
  if (/\b(naa|unsa|asa|kanus-a|pila|maayong|salamat kaayo|ba mo|mo ba|nimo|karon|kaayo|kini)\b/.test(t)) return 'tl';
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
  const m = /\b(\d{1,2}|one|two|three|four|isa|dalawa|tatlo|apat|duha|tulo|upat)\s*(?:adults?|pax|persons?|people|guests?|tao|kami|ka)\b/i.exec(text)
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
  const tl = flow.lang === 'tl', dates = `${dm(flow.checkin)} to ${dm(flow.checkout)}`;
  for (let d = flow.checkin; d < flow.checkout; d = new Date(Date.parse(d + 'T00:00:00Z') + 86_400_000).toISOString().slice(0, 10)) {
    if (bookedNights.has(d)) return tl
      ? `Reserved na po ang ${dates}, dahil isang party lang po ang tinatanggap namin sa bawat stay. Kung may ibang dates po kayong gusto, i-share lang po ang check-in at check-out at iche-check ko po agad.`
      : `${dates} is already reserved, as the home welcomes one party at a time. Should other dates suit you, kindly share your check-in and check-out and I will gladly check them for you.`;
  }
  return tl ? `Available po ang ${dates}` : `${dates} is available`;
}

export function isActive(flow: Flow | null | undefined, now = new Date()): flow is Flow {
  return !!flow && !['confirmed', 'cancelled'].includes(flow.step) && now.getTime() - Date.parse(flow.updated_at) < FLOW_TTL_MS;
}

/** The first reply of a flow: a host's welcome that acknowledges what the guest already told us
 * (session 28 - "Your mobile number po?" as an opener read as a form, not a host). */
export const greeting = (name: string | null, lang: 'en' | 'tl' = 'en') => lang === 'tl'
  ? `${name ? `Hi ${name.split(' ')[0]}.` : 'Hello po.'} Maraming salamat po sa pag-message sa Cascade Hideaway. `
  : `${name ? `Hi ${name.split(' ')[0]}.` : 'Hello.'} Thank you for reaching out to Cascade Hideaway. `;
/** Cassy persona (D-167): greeting, then the answer, then a calm welcome that names the party. No exclamations. */
export function opener(flow: Flow, name: string | null, answer = ''): string {
  const tl = flow.lang === 'tl';
  const who = tl
    ? (!flow.pax || flow.pax === 1 ? 'kayo' : flow.pax === 2 ? 'kayong dalawa' : `ang grupo ninyong ${flow.pax}`)
    : (!flow.pax || flow.pax === 1 ? 'you' : flow.pax === 2 ? 'the two of you' : `your party of ${flow.pax}`);
  const welcome = tl ? `masaya po kaming i-welcome ${who}.` : `we would be glad to welcome ${who}.`;
  if (answer) return `${greeting(name, flow.lang)}${answer}, ${tl ? 'at ' : 'and '}${welcome}\n\n`;
  const dates = flow.checkin && flow.checkout
    ? (tl ? `Noted na po ang ${dm(flow.checkin)} to ${dm(flow.checkout)}, at iche-check ko po ang dates habang nag-uusap tayo. ` : `${dm(flow.checkin)} to ${dm(flow.checkout)} is noted, and I will check those dates for you as we go. `)
    : flow.checkin ? (tl ? `Noted na po ang check-in ninyo sa ${dm(flow.checkin)}. ` : `Check-in on ${dm(flow.checkin)} is noted. `) : '';
  return `${greeting(name, flow.lang)}${dates}${tl ? 'Masaya' : 'We'} ${tl ? `po kaming i-welcome ${who}.` : `would be glad to welcome ${who}.`}\n\n`;
}

/** The question for the current slot, in the Cassy voice: calm, gracious, precise; guide rather than command. */
export function prompt(flow: Flow, name: string | null): string {
  const n = name ? `${name.split(' ')[0]}, ` : '';
  const tl = flow.lang === 'tl';
  switch (flow.step) {
    case 'dates': return tl
      ? `${n}kailan po ninyo gustong mag-stay? Check-in at check-out lang po (halimbawa, "Sep 24 to 26").`
      : `${n ? `${n}which` : 'Which'} dates would you like to stay with us? Your check-in and check-out will do (for example, "Sep 24 to 26").`;
    case 'checkout': return tl
      ? `Salamat po. Noted na ang check-in ninyo sa ${dm(flow.checkin!)}. Hanggang kailan po kayo mag-stay?`
      : `Thank you. Check-in on ${dm(flow.checkin!)} is noted. Until which date would you like to stay?`;
    case 'pax': return tl
      ? `Ilan po kayong mag-stay? Komportable po ang bahay para sa hanggang 3 adults, o 2 adults na may 2 bata.`
      : `And how many guests will be staying? The home comfortably accommodates up to 3 adults, or 2 adults with 2 children.`;
    case 'contact': return tl
      ? `Pahingi po ng mobile number ninyo, para ma-contact namin kayo tungkol sa stay. Pwede rin po kayong magdagdag ng e-mail kung doon ninyo gustong matanggap ang confirmation.`
      : `May we have your mobile number, so we can reach you about your stay? You are welcome to add an e-mail address as well, if you would like your confirmation there.`;
    case 'confirm': { const q = quoteTotal(flow.checkin!, flow.checkout!); return [
      tl ? `Ito po ang details ng stay ninyo:` : `Here are your stay details:`,
      `📅 ${dm(flow.checkin!)} to ${dm(flow.checkout!)} · ${q.nights} night${q.nights === 1 ? '' : 's'} · ${flow.pax} guest${flow.pax === 1 ? '' : 's'}`,
      `📞 ${flow.phone}${flow.email ? ` · ${flow.email}` : ''}`,
      `💰 Total ${peso(q.total)}`,
      ``,
      flow.pay_full === true
        ? (tl ? `Dahil malapit na po ang check-in, ang buong ${peso(q.total)} po ang magse-secure ng stay. Pwede po kayong mag-reply ng FULL para i-send ang request, o sabihin lang po kung may kailangang baguhin.`
              : `As your check-in is near, the full ${peso(q.total)} secures your stay. You may reply FULL to send your request through, or let me know if anything needs changing.`)
        : (tl ? `Para ma-secure ang stay, pwede po kayong mag-reply ng DEPOSIT para i-reserve sa ${peso(q.deposit)} ngayon at bayaran ang balance sa check-in, o FULL para bayaran ang ${peso(q.total)} ngayon. Alinman po ay magse-send ng request ninyo. Kung may kailangang baguhin, sabihin lang po.`
              : `To secure your stay, you may reply DEPOSIT to reserve with ${peso(q.deposit)} now and settle the balance at check-in, or FULL to settle ${peso(q.total)} now. Either sends your request through. If anything needs changing, simply let me know.`),
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
  const p = /\b(\d|one|two|three|four|isa|dalawa|tatlo|apat)\s*(adults?|pax|persons?|people|guests?|tao|kami)\b/i.test(text) || /\b(?:for|para sa|kaming)\s+(\d|one|two|three|four|isa|dalawa|tatlo|apat)\b(?!\s*(?:nights?|days?|gabi|araw))/i.test(text) ? parsePax(text) : null;
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
    if (detectLang(text) === 'tl') f.lang = 'tl'; else if (words.length >= 2) f.lang = 'en'; }
  const tl = f.lang === 'tl';
  const today = f.updated_at.slice(0, 10);
  if (CANCEL_RE.test(text) && f.step !== 'await_receipt') return { flow: { ...f, step: 'cancelled' }, reply: tl ? `Sige po. Wala pong na-send, at pwede po kayong bumalik dito kahit kailan — sabihin lang po ang "book" at ipagpapatuloy natin.` : `Of course. Nothing has been sent, and you are welcome to return to this whenever it suits you — simply say "book" and we will pick up from here.`, action: 'cancelled' };
  const ask = (reply?: string): Step => ({ flow: f, reply: reply ?? null, action: 'ask' });
  const retry = (what: string): Step => text.includes('?') ? { flow: f, reply: null, action: 'passthrough' } : ask(tl ? `Pasensya na po — hindi ko po nakuha nang maayos ${what === 'the mobile number' ? 'ang mobile number' : what === 'the dates' ? 'ang dates' : what === 'the check-out date' ? 'ang check-out date' : what === 'the number of guests' ? 'kung ilan kayo' : 'iyon'}. ${prompt(f, null)}` : `My apologies — I could not quite make out ${what}. ${prompt(f, null)}`);
  switch (f.step) {
    case 'dates': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the dates');
      if (d[0] < today) return ask(tl ? `Lumipas na po ang date na iyon. Aling paparating na dates po ang gusto ninyo?` : `That date has already passed. Which upcoming dates would suit you?`);
      f.checkin = d[0]; f.step = 'checkout';
      if (d[1] && d[1] > d[0]) { f.checkout = d[1]; f.step = f.pax ? 'contact' : 'pax'; }
      return ask();
    }
    case 'checkout': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the check-out date');
      if (d[0] <= f.checkin!) return ask(tl ? `Kailangan po na pagkatapos ng ${dm(f.checkin!)} ang check-out. Hanggang kailan po kayo mag-stay?` : `Check-out would need to fall after ${dm(f.checkin!)}. Until which date would you like to stay?`);
      f.checkout = d[0]; f.step = f.pax ? 'contact' : 'pax'; return ask();
    }
    case 'pax': {
      const p = parsePax(text);
      if (!p) return retry('the number of guests');
      if (p > 4) return ask(tl ? `Gustuhin man po naming i-host kayong lahat, pinaka-komportable po ang bahay para sa hanggang 3 adults, o 2 adults na may 2 bata. Para sa ${p}, mas magkakaroon po kayo ng espasyo sa mas malaking accommodation. Kung kasya po ang grupo ninyo, sabihin lang po ulit kung ilan kayo.` : `As much as we would love to host everyone, the home is most comfortable for up to 3 adults, or 2 adults with 2 children. For a party of ${p}, a larger accommodation would give you more room to rest. If your group fits, kindly let me know the count again.`);
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
      const d = parseDates(text, now), p = /\b(guest|pax|person|people|tao|adult|kami)/i.test(text) ? parsePax(text) : null, ph = parsePhone(text), e = parseEmail(text);
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
export function paymentReply(flow: Flow, name: string | null, siteUrl: string): string {
  const n = name ? name.split(' ')[0] : (flow.lang === 'tl' ? '' : 'there');
  const until = flow.hold_expires_at ? new Date(flow.hold_expires_at).toLocaleString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }).replace(', ', ' at ') : null;
  const full = (flow.deposit ?? 0) >= (flow.total ?? 0);
  const dates = `${dm(flow.checkin!)} to ${dm(flow.checkout!)}`;
  const tl = flow.lang === 'tl', nm = n ? `, ${n}` : '';
  // Cassy persona (D-167, Lloyd's own wording 2026-09-17 10:30): four calm paragraphs, "you may", the amount
  // already arranged, no exclamations, one 🌿 at the close. GCash only. Taglish register mirrors the guest.
  if (tl) {
    const head = flow.hold && until
      ? `Salamat po${nm}. Naka-reserve na po para sa inyo ang ${dates} hanggang ${until}. Ang booking reference ninyo ay ${flow.ref}.`
      : `Salamat po${nm}. Natanggap na po namin ang request ninyo, at ang booking reference ninyo ay ${flow.ref}. Dahil malapit na po ang stay, iko-confirm namin ito sa sandaling dumating ang bayad.`;
    const pay = `Para ma-secure ang stay, pwede na po ninyong i-send ang ${peso(flow.deposit!)} ${full ? 'payment' : 'initial payment'} via GCash gamit ang QR code sa ibaba. Naka-set na po ang amount para sa inyo. Kapag tapos na, i-send lang po dito ang screenshot ng receipt at iko-confirm namin ang reservation ninyo.`;
    const later = full
      ? `Ang ₱1,000 refundable security deposit na lang po ang natitira, na pwedeng bayaran sa check-in.`
      : `Ang natitirang ${peso(flow.total! - flow.deposit!)} balance, kasama ang ₱1,000 refundable security deposit, ay pwede pong bayaran sa check-in.`;
    const close = `Maraming salamat po ulit${nm}. Inaabangan po namin kayo sa Cascade Hideaway at ihahanda namin ang komportableng stay para sa inyo. 🌿`;
    return [head, '', pay, '', later, '', close].join('\n');
  }
  const head = flow.hold && until
    ? `Thank you, ${n}. We have reserved ${dates} for you until ${until}. Your booking reference is ${flow.ref}.`
    : `Thank you, ${n}. Your request has been received, and your booking reference is ${flow.ref}. As your stay is near, we will confirm as soon as your payment is received.`;
  const pay = `To secure your stay, you may send the ${peso(flow.deposit!)} ${full ? 'payment' : 'initial payment'} via GCash using the QR code below. The amount has already been set for you. Once completed, simply send us a screenshot of the receipt here and we will confirm your reservation.`;
  const later = full
    ? `Only the ₱1,000 refundable security deposit remains, which may be settled upon check-in.`
    : `The remaining ${peso(flow.total! - flow.deposit!)} balance, together with the ₱1,000 refundable security deposit, may be settled upon check-in.`;
  const close = `Thank you again, ${n}. We look forward to welcoming you to Cascade Hideaway and preparing a comfortable stay for you. 🌿`;
  return [head, '', pay, '', later, '', close].join('\n');
}
