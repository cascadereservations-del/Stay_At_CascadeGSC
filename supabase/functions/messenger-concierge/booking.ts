// Messenger book intent (booking PRD §A, session 27). Pure functions, no I/O: a code-driven
// slot-filling flow that index.ts runs BEFORE the model. The model never books; it only answers
// questions. State is one jsonb on concierge_threads.booking_flow.
import { RATE_TIERS } from '../_shared/cascade-core/facts.ts';

export type Flow = {
  step: 'dates' | 'checkout' | 'pax' | 'phone' | 'email' | 'pay' | 'confirm' | 'await_receipt' | 'receipt_sent' | 'confirmed' | 'cancelled';
  checkin?: string; checkout?: string; pax?: number; phone?: string; email?: string | null;
  /** session 28: the guest's choice - reservation fee (50 %) or the full amount; forced full inside 48 h */
  pay_full?: boolean; asked?: 'availability' | 'question' | null;
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
  for (let d = flow.checkin; d < flow.checkout; d = new Date(Date.parse(d + 'T00:00:00Z') + 86_400_000).toISOString().slice(0, 10)) {
    if (bookedNights.has(d)) return `${dm(flow.checkin)} to ${dm(flow.checkout)} is already taken po — the home is one guest at a time, so it has to be fully yours. Would other dates work for you? Tell me the check-in and check-out and I'll check right away.`;
  }
  return `Good news po — ${dm(flow.checkin)} to ${dm(flow.checkout)} is open.`;
}

export function isActive(flow: Flow | null | undefined, now = new Date()): flow is Flow {
  return !!flow && !['confirmed', 'cancelled'].includes(flow.step) && now.getTime() - Date.parse(flow.updated_at) < FLOW_TTL_MS;
}

/** The first reply of a flow: a host's welcome that acknowledges what the guest already told us
 * (session 28 - "Your mobile number po?" as an opener read as a form, not a host). */
export const greeting = (name: string | null) => `${name ? `Hello ${name.split(' ')[0]}!` : 'Hello!'} Thank you for thinking of Cascade Hideaway 🌿 `;
/** Greeting, then the answer (if any), then the welcome that names the party (Lloyd 09:55: answer-before-hello read inside-out). */
export function opener(flow: Flow, name: string | null, answer = ''): string {
  const who = !flow.pax || flow.pax === 1 ? 'you' : flow.pax === 2 ? 'the two of you' : `your group of ${flow.pax}`;
  if (answer) return `${greeting(name)}${answer} We'd love to have ${who}.

`;
  const dates = flow.checkin && flow.checkout ? `${dm(flow.checkin)} to ${dm(flow.checkout)} — noted po, I'll check those dates as we go. ` : flow.checkin ? `Check-in ${dm(flow.checkin)} — noted po. ` : '';
  return `${greeting(name)}${dates}We'd love to have ${who}.

`;
}

/** The question for the current slot, in the Concierge voice: one warm line, one clear ask. */
export function prompt(flow: Flow, name: string | null): string {
  const n = name ? `${name.split(' ')[0]}, ` : '';
  switch (flow.step) {
    case 'dates': return `${n ? `${n}which` : 'Which'} dates are you thinking of po — your check-in and check-out? (e.g. "Sep 24 to 26")`;
    case 'checkout': return `Lovely — check-in ${dm(flow.checkin!)}. And until when would you be staying with us po?`;
    case 'pax': return `And how many of you will be staying po? The home is most comfortable for up to 3 adults, or 2 adults with 2 little ones.`;
    case 'phone': return `May we have your mobile number po, so we can reach you about your stay? (e.g. 0917 123 4567)`;
    case 'email': return `And an e-mail address for your confirmation, if you'd like one po — or just say "skip" and we'll keep everything here on Messenger.`;
    case 'pay': { const q = quoteTotal(flow.checkin!, flow.checkout!);
      return `Your stay comes to ${peso(q.total)} po (${q.nights} night${q.nights === 1 ? '' : 's'} at ${peso(q.rate)}). Would you like to reserve with the 50 % fee of ${peso(q.deposit)} and settle the rest at check-in, or pay the full ${peso(q.total)} now? Either is perfectly fine — just say "deposit" or "full".`; }
    case 'confirm': { const q = quoteTotal(flow.checkin!, flow.checkout!); return [
      `Here's what I have for you po — kindly have a look:`,
      `📅 ${dm(flow.checkin!)} → ${dm(flow.checkout!)} (${q.nights} night${q.nights === 1 ? '' : 's'})`,
      `👥 ${flow.pax} guest${flow.pax === 1 ? '' : 's'}`,
      `📞 ${flow.phone}${flow.email ? `\n📧 ${flow.email}` : ''}`,
      flow.pay_full ? `💳 Full payment ${peso(q.total)}` : `💳 Reservation fee ${peso(q.deposit)} now · balance ${peso(q.total - q.deposit)} + ₱1,000 refundable deposit at check-in`,
      ``,
      `If everything looks right, reply YES and I'll send it through. Anything to change, just tell me. 😊`,
    ].join('\n'); }
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
  // What did the guest actually ask? index.ts answers availability from the calendar (code) or hands
  // any other question to the model before the flow's own ask (protocol rule 1).
  flow.asked = AVAIL_RE.test(text) && flow.checkin ? 'availability' : ASK_RE.test(text) && !/\b(can|could|pwede|possible)\b[^?]*\b(book|reserve)\b/i.test(text) ? 'question' : null;
  return flow;
}

/** Apply the guest's answer to the current slot. A question ("?") passes through to the model. */
export function answer(flow: Flow, text: string, now = new Date()): Step {
  const f: Flow = { ...flow, updated_at: now.toISOString() };
  const today = f.updated_at.slice(0, 10);
  if (CANCEL_RE.test(text) && f.step !== 'await_receipt') return { flow: { ...f, step: 'cancelled' }, reply: `Of course po, no problem at all — nothing was sent. Whenever you're ready, just say "book" and we'll pick it up right where we left off. 😊`, action: 'cancelled' };
  const ask = (reply?: string): Step => ({ flow: f, reply: reply ?? null, action: 'ask' });
  const retry = (what: string): Step => text.includes('?') ? { flow: f, reply: null, action: 'passthrough' } : ask(`Pasensya po, I didn't quite catch ${what}. ${prompt(f, null)}`);
  switch (f.step) {
    case 'dates': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the dates');
      if (d[0] < today) return ask(`That date has already passed po — which upcoming dates would suit you?`);
      f.checkin = d[0]; f.step = 'checkout';
      if (d[1] && d[1] > d[0]) { f.checkout = d[1]; f.step = f.pax ? 'phone' : 'pax'; }
      return ask();
    }
    case 'checkout': {
      const d = parseDates(text, now);
      if (!d[0]) return retry('the check-out date');
      if (d[0] <= f.checkin!) return ask(`Check-out would need to be after ${dm(f.checkin!)} po — until what date would you like to stay?`);
      f.checkout = d[0]; f.step = f.pax ? 'phone' : 'pax'; return ask();
    }
    case 'pax': {
      const p = parsePax(text);
      if (!p) return retry('the number of guests');
      if (p > 4) return ask(`As much as we'd love to host everyone, the home is most comfortable for up to 3 adults, or 2 adults with 2 little ones po — for ${p} a larger place would give you more room to rest. If your group fits that, just tell me the count again.`);
      f.pax = p; f.step = 'phone'; return ask();
    }
    case 'phone': {
      const ph = parsePhone(text);
      if (!ph) return retry('the mobile number');
      f.phone = ph; f.step = 'email'; return ask();
    }
    case 'email': {
      const next = () => { if (within48h(f.checkin!, now)) { f.pay_full = true; f.step = 'confirm'; } else f.step = 'pay'; return ask(); };
      if (SKIP_RE.test(text)) { f.email = null; return next(); }
      const e = parseEmail(text);
      if (!e) return retry('the e-mail');
      f.email = e; return next();
    }
    case 'pay': {
      if (FULL_RE.test(text)) { f.pay_full = true; f.step = 'confirm'; return ask(); }
      if (DEPOSIT_RE.test(text)) { f.pay_full = false; f.step = 'confirm'; return ask(); }
      return retry('which you prefer');
    }
    case 'confirm': {
      if (YES_RE.test(text)) return { flow: f, reply: null, action: 'submit' };
      const d = parseDates(text, now), p = /\b(guest|pax|person|people|tao|adult|kami)/i.test(text) ? parsePax(text) : null, ph = parsePhone(text), e = parseEmail(text);
      let changed = false;
      if (d[0] && d[0] >= today) { f.checkin = d[0]; changed = true; if (d[1] && d[1] > d[0]) f.checkout = d[1]; else if (f.checkout! <= d[0]) { f.step = 'checkout'; return ask(); } }
      if (p && p <= 4) { f.pax = p; changed = true; }
      if (ph) { f.phone = ph; changed = true; }
      if (e) { f.email = e; changed = true; }
      if (FULL_RE.test(text)) { f.pay_full = true; changed = true; } else if (DEPOSIT_RE.test(text)) { f.pay_full = false; changed = true; }
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
    ? `Wonderful, ${n} — your dates are held for you until ${until} 🎉 Your reference is ${flow.ref}.`
    : `Thank you, ${n} — your request is in, reference ${flow.ref}. Since your stay is close, we confirm as soon as the payment lands.`;
  // Session 28 (policy check): inside 5 days the site still asks the 50 % fee and reserves on receipt; only
  // check-in within 48 h asks the full amount (submit-booking decides, we read flow.deposit).
  const full = (flow.deposit ?? 0) >= (flow.total ?? 0);
  const amount = flow.hold
    ? (full ? `To secure them, send the full ${peso(flow.total!)} — only the ₱1,000 refundable security deposit is left for check-in.`
            : `To secure them, send the ${peso(flow.deposit!)} reservation fee — the balance of ${peso(flow.total! - flow.deposit!)} and the ₱1,000 refundable security deposit are settled at check-in.`)
    : full ? `Check-in is close, so we reserve on receipt: please send the full ${peso(flow.total!)} now and we confirm within a couple of hours. The ₱1,000 refundable security deposit is settled at check-in.`
    : `Check-in is close, so we reserve on receipt: send the ${peso(flow.deposit!)} reservation fee now and we confirm within a couple of hours. The balance and the ₱1,000 refundable security deposit are settled at check-in.`;
  return [head, '', amount, '', `GCash or Maya: scan the QR below — the ${peso(flow.deposit!)} is already set, so there's nothing to type. (0956 011 5744, Marifel Suzanne Boncales)`, `Once sent, just drop the receipt screenshot here and we'll confirm personally. 🙏`, '', `Other ways to pay and the full terms are on our site: ${siteUrl}`, '', `We're looking forward to welcoming you. 🌿`].join('\n');
}
