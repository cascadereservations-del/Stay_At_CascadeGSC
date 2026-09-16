// Messenger book intent (booking PRD §A, session 27). Pure functions, no I/O: a code-driven
// slot-filling flow that index.ts runs BEFORE the model. The model never books; it only answers
// questions. State is one jsonb on concierge_threads.booking_flow.
export type Flow = {
  step: 'dates' | 'checkout' | 'pax' | 'phone' | 'email' | 'confirm' | 'await_receipt' | 'receipt_sent' | 'confirmed' | 'cancelled';
  checkin?: string; checkout?: string; pax?: number; phone?: string; email?: string | null;
  booking_id?: string; ref?: string; deposit?: number; total?: number; hold?: boolean; hold_expires_at?: string | null;
  receipt_token?: string; receipt_expires_at?: string; started_at: string; updated_at: string;
};

export const BOOK_RE = /\b(book(ing)?|reserve|reservation|magpa-?book|pa-?book|i-?book|mag-?reserve|hold (the|my|our) dates)\b/i;
const CANCEL_RE = /\b(cancel|stop|wag na|huwag|never ?mind|nevermind|not now|forget it)\b/i;
const YES_RE = /^\s*(yes|yes po|oo|oo po|sige|sige po|go|confirm|confirmed|ok|okay|okay po|ok po|proceed|tama|correct|yup|yep|y)\s*[.!]*\s*$/i;
const SKIP_RE = /^\s*(skip|wala|none|no email|no)\s*[.!]*\s*$/i;
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

export function isActive(flow: Flow | null | undefined, now = new Date()): flow is Flow {
  return !!flow && !['confirmed', 'cancelled'].includes(flow.step) && now.getTime() - Date.parse(flow.updated_at) < FLOW_TTL_MS;
}

/** The question for the current slot. */
export function prompt(flow: Flow, name: string | null): string {
  const n = name ? `${name.split(' ')[0]}, ` : '';
  switch (flow.step) {
    case 'dates': return `${n}happy to help you book! Which dates po — check-in and check-out? (e.g. "Sep 24 to 26")`;
    case 'checkout': return `Got it, check-in ${dm(flow.checkin!)}. Until what date po is your check-out?`;
    case 'pax': return `How many guests po? (up to 3 adults, or 2 adults + 2 kids)`;
    case 'phone': return `Your mobile number po, for the booking? (e.g. 0917 123 4567)`;
    case 'email': return `And your e-mail for the confirmation? (reply "skip" if none)`;
    case 'confirm': return [
      `Here's your request po:`,
      `📅 ${dm(flow.checkin!)} → ${dm(flow.checkout!)} (${nights(flow.checkin!, flow.checkout!)} night${nights(flow.checkin!, flow.checkout!) === 1 ? '' : 's'})`,
      `👥 ${flow.pax} guest${flow.pax === 1 ? '' : 's'}`,
      `📞 ${flow.phone}${flow.email ? `\n📧 ${flow.email}` : ''}`,
      ``,
      `Reply YES to send it, or tell me what to change.`,
    ].join('\n');
    default: return '';
  }
}

export type Step = { flow: Flow; reply: string | null; action: 'ask' | 'submit' | 'cancelled' | 'passthrough' };

/** Start a flow from the first message; prefills dates and guests when they are in the text. */
export function start(text: string, now = new Date()): Flow {
  const at = now.toISOString();
  const flow: Flow = { step: 'dates', started_at: at, updated_at: at };
  const d = parseDates(text, now);
  const today = at.slice(0, 10);
  if (d[0] && d[0] >= today) { flow.checkin = d[0]; flow.step = 'checkout'; }
  if (flow.checkin && d[1] && d[1] > flow.checkin) { flow.checkout = d[1]; flow.step = 'pax'; }
  const p = /\b(\d|one|two|three|four|isa|dalawa|tatlo|apat)\s*(adults?|pax|persons?|people|guests?|tao|kami)\b/i.test(text) ? parsePax(text) : null;
  if (p && flow.step === 'pax') { flow.pax = p; flow.step = 'phone'; }
  return flow;
}

/** Apply the guest's answer to the current slot. A question ("?") passes through to the model. */
export function answer(flow: Flow, text: string, now = new Date()): Step {
  const f: Flow = { ...flow, updated_at: now.toISOString() };
  const today = f.updated_at.slice(0, 10);
  if (CANCEL_RE.test(text) && f.step !== 'await_receipt') return { flow: { ...f, step: 'cancelled' }, reply: `No problem po — nothing was sent. Just say "book" anytime and we'll pick it up again. 😊`, action: 'cancelled' };
  const ask = (reply?: string): Step => ({ flow: f, reply: reply ?? null, action: 'ask' });
  const retry = (what: string): Step => text.includes('?') ? { flow: f, reply: null, action: 'passthrough' } : ask(`Sorry po, I didn't catch ${what}. ${prompt(f, null)}`);
  switch (f.step) {
    case 'dates': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the dates');
      if (d[0] < today) return ask(`That date has passed po. Which upcoming dates would you like?`);
      f.checkin = d[0]; f.step = 'checkout';
      if (d[1] && d[1] > d[0]) { f.checkout = d[1]; f.step = f.pax ? 'phone' : 'pax'; }
      return ask();
    }
    case 'checkout': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the check-out date');
      if (d[0] <= f.checkin!) return ask(`Check-out needs to be after ${dm(f.checkin!)} po. Until what date?`);
      f.checkout = d[0]; f.step = f.pax ? 'phone' : 'pax'; return ask();
    }
    case 'pax': {
      const p = parsePax(text);
      if (!p) return retry('the number of guests');
      if (p > 4) return ask(`The unit is best for up to 3 adults or 2 adults + 2 kids po — for ${p} we'd suggest a larger place. If your group fits, tell me the count again.`);
      f.pax = p; f.step = 'phone'; return ask();
    }
    case 'phone': {
      const ph = parsePhone(text);
      if (!ph) return retry('the mobile number');
      f.phone = ph; f.step = 'email'; return ask();
    }
    case 'email': {
      if (SKIP_RE.test(text)) { f.email = null; f.step = 'confirm'; return ask(); }
      const e = parseEmail(text);
      if (!e) return retry('the e-mail');
      f.email = e; f.step = 'confirm'; return ask();
    }
    case 'confirm': {
      if (YES_RE.test(text)) return { flow: f, reply: null, action: 'submit' };
      const d = parseDates(text, now), p = /\b(guest|pax|person|people|tao|adult|kami)/i.test(text) ? parsePax(text) : null, ph = parsePhone(text), e = parseEmail(text);
      let changed = false;
      if (d[0] && d[0] >= today) { f.checkin = d[0]; changed = true; if (d[1] && d[1] > d[0]) f.checkout = d[1]; else if (f.checkout! <= d[0]) { f.step = 'checkout'; return ask(); } }
      if (p && p <= 4) { f.pax = p; changed = true; }
      if (ph) { f.phone = ph; changed = true; }
      if (e) { f.email = e; changed = true; }
      if (changed) return ask();
      return retry('that');
    }
    default: return { flow: f, reply: null, action: 'passthrough' };
  }
}

// ponytail: one QR (GCash) in Messenger; UnionBank/InstaPay stays on the site page linked below.
export function paymentReply(flow: Flow, name: string | null, siteUrl: string): string {
  const n = name ? name.split(' ')[0] : 'there';
  const peso = (v: number) => `₱${v.toLocaleString('en-PH')}`;
  const until = flow.hold_expires_at ? new Date(flow.hold_expires_at).toLocaleString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }) : null;
  const head = flow.hold && until
    ? `${n}, your dates are held for you until ${until} 🎉 Reference: ${flow.ref}.`
    : `${n}, your request is in — reference ${flow.ref}. For stays within five days we confirm as soon as the payment lands.`;
  const amount = flow.hold ? `To secure them, send the ${peso(flow.deposit!)} reservation fee (50 %; the rest is paid at check-in) — or the full ${peso(flow.total!)} if you prefer.` : `Please send the full ${peso(flow.total!)} within 48 hours.`;
  return [head, '', amount, '', `GCash: 0956 011 5744 (Marifel Suzanne Boncales) — QR below.`, `Then send me a screenshot of the receipt here and our Finance team will confirm. 🙏`, '', `Other ways to pay and the full terms: ${siteUrl}`].join('\n');
}
