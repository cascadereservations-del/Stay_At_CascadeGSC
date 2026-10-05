// SPEC-38 (session 70, D-297 item 2): decide a direct-booking request before payment, from Telegram.
// An INQUIRY is a booking_inquiries row with source 'direct', status 'pending' and no receipt yet: the guest submitted the
// request and has not sent a receipt. Finance (a mapped owner or admin) may hold the dates 24 h or decline with a reason;
// Finance and OPS may send a Cassy-drafted reply. OPS never sees guest money. Pure: no env, no I/O, tested in inquiry.test.ts.
// The cards are written for people: what happened and who acts first, plain sentences, ids last.
// Guest-facing lines are unsigned and pass lintReply + toneRules in all three registers (inquiry.test.ts).
// Pronouns: the card never guesses a gender ("the guest", "their"), the guest's own line uses the name.
import { dmRange } from '../../messenger-concierge/booking.ts';
import { CAPACITY } from '../../messenger-concierge/persona.ts'; // the D-222 disclosure stays one constant
import { autoKeyboard, BTN, DASH_URL, groups, type Btn } from './format.ts';
import { maskMoney } from '../ops-money.ts';

export type Lang = 'en' | 'tl' | 'bis';
export type Surface = 'finance' | 'ops';

/** The row telegram_inquiry_view_v1 returns (one element of its array). Money that is unknown is null, never 0. */
export type InquiryView = {
  id: string; ref: string; guest_name: string; guest_email: string | null; guest_phone: string | null;
  checkin_date: string; checkout_date: string; nights: number | null; pax: number | null;
  total_amount: number | null; deposit_amount: number | null; notes: string | null; submitted_at: string | null;
  status: string; has_receipt: boolean; hold_expires_at: string | null; held_by: string | null; held_at: string | null; conflict: boolean;
};

/** What a card adds to the view: the guest's words and the context lines the sender already has. */
export type CardExtra = {
  /** the guest's newest message(s) to answer, already cut (guestTextSince / siteNotes), or null */
  lastMessage?: string | null;
  /** Finance only: today's rate-card total for these dates when it differs from the stored one */
  rateToday?: number | null;
  /** Finance only: guestContextLines() */
  context?: string[];
  /** the hold timer to show when the view has none yet (submit-booking knows it before the row is read back) */
  holdExpiresAt?: string | null;
  /** 'Messenger' or 'the site' */
  via?: string;
  /** Finance only: extra lines for the money group (a promotion, a hold that could not open) and the guest group (WhatsApp preferred) */
  moneyNotes?: Array<string | false | null | undefined>;
  contactNotes?: Array<string | false | null | undefined>;
};

export const HOLD_HOURS = 24;
export const DECLINE_CODES = ['taken', 'guests', 'house', 'owner', 'dup', 'other'] as const;
export type DeclineCode = typeof DECLINE_CODES[number];
export const DECLINE_LABELS: Record<DeclineCode, string> = {
  taken: 'Dates taken', guests: 'Too many guests', house: 'House rules', owner: 'Not available those dates',
  dup: 'Duplicate or test (no message)', other: 'Other…',
};
export const isDeclineCode = (x: unknown): x is DeclineCode => (DECLINE_CODES as readonly string[]).includes(String(x));

// ---- small formatters (Manila time, the way the cards read) ----

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (x: unknown): x is string => typeof x === 'string' && UUID.test(x);
export const firstName = (name: string | null | undefined): string => String(name ?? '').trim().split(/\s+/)[0] ?? '';
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const peso = (n: number) => `₱${n.toLocaleString('en-PH')}`;
/** a peso figure, or null when the value is unknown (null, undefined, '', not a number) - never 0 */
export function pesoOrNull(v: unknown): string | null {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? peso(n) : null;
}

function manilaParts(iso: string | number | Date): Record<string, string> | null {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const out: Record<string, string> = {};
  for (const p of new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Manila', weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', hour12: true }).formatToParts(d)) out[p.type] = p.value;
  return out;
}
/** `Tue 6 Oct, 10:40 pm` (Manila). '' for an unreadable time. */
export function fmtUntil(iso: string | number | Date): string {
  const p = manilaParts(iso);
  return p ? `${p.weekday} ${p.day} ${p.month}, ${p.hour}:${p.minute} ${p.dayPeriod.toLowerCase()}` : '';
}
/** `9:15 am` (Manila). */
export function fmtClock(iso: string | number | Date): string {
  const p = manilaParts(iso);
  return p ? `${p.hour}:${p.minute} ${p.dayPeriod.toLowerCase()}` : '';
}
/** `Mon 30 Nov` from a yyyy-mm-dd stay date. */
export function fmtDay(ymd: string): string {
  const d = new Date(`${ymd}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return String(ymd);
  const p: Record<string, string> = {};
  for (const x of new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short', day: 'numeric', month: 'short' }).formatToParts(d)) p[x.type] = x.value;
  return `${p.weekday} ${p.day} ${p.month}`;
}
const stayLong = (v: InquiryView) => `${fmtDay(v.checkin_date)} to ${fmtDay(v.checkout_date)}`;
/** The persona date phrase: `Nov 30 to Dec 4`. */
export const stayShort = (v: Pick<InquiryView, 'checkin_date' | 'checkout_date'>) => dmRange(v.checkin_date, v.checkout_date);

/** `Messenger` for a request the book flow submitted, else `the site`. */
export const viaOf = (notes: string | null | undefined): string => /via Messenger/i.test(String(notes ?? '')) ? 'Messenger' : 'the site';

// ---- the guest's words ----

type Turn = { role?: string; text?: string; at?: string };
const cut = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s);
/** The guest's turns newer than the request (newest last), at most three, each cut to 160 characters. */
export function guestTextSince(history: Turn[] | null | undefined, submittedAt: string | null | undefined): string[] {
  const since = submittedAt ? Date.parse(submittedAt) : NaN;
  return (history ?? [])
    .filter((t) => t?.role === 'guest' && String(t.text ?? '').trim() && (Number.isNaN(since) || (Date.parse(String(t.at ?? '')) || 0) > since))
    .slice(-3).map((t) => cut(String(t.text).replace(/\s+/g, ' ').trim(), 160));
}
/** A site request's notes with the `via Messenger (psid …)` marker removed; null when nothing is left. */
export function siteNotes(notes: string | null | undefined): string | null {
  const s = String(notes ?? '').replace(/via Messenger\s*\(psid[^)]*\)/gi, '').replace(/\s+/g, ' ').trim();
  return s ? cut(s, 160) : null;
}
/** The one line the cards show: the guest's message(s) joined, or null. */
export const joinMessage = (parts: string[]): string | null => (parts.length ? parts.join(' / ') : null);
/** The newest guest turn's time, for channelPlan. */
export function lastGuestAt(history: Turn[] | null | undefined): string | null {
  const g = (history ?? []).filter((t) => t?.role === 'guest' && t.at);
  return g.length ? String(g[g.length - 1].at) : null;
}

// ---- cards ----

const dashLink = (id: string) => `${DASH_URL}bookings/direct/${id}`;
const askedFor = (v: InquiryView, via: string, who: string) =>
  `${who} asked for ${stayLong(v)}${v.nights || v.pax ? ` (${[v.nights ? `${v.nights} night${v.nights === 1 ? '' : 's'}` : '', v.pax ? `${v.pax} guest${v.pax === 1 ? '' : 's'}` : ''].filter(Boolean).join(', ')})` : ''} through ${via}.`;

/** The Finance card: guest money, phone and e-mail included. */
export function financeCard(v: InquiryView, x: CardExtra = {}): string {
  const via = x.via ?? viaOf(v.notes);
  const total = pesoOrNull(v.total_amount), due = pesoOrNull(v.deposit_amount);
  const full = v.total_amount !== null && v.deposit_amount !== null && Number(v.total_amount) === Number(v.deposit_amount);
  const until = v.hold_expires_at ?? x.holdExpiresAt ?? null;
  const money = total
    ? `💰 Total ${total}${due ? (full ? ` · full payment ${due} due now` : ` · reservation fee ${due} due now`) : ''}`
    : null;
  const rate = pesoOrNull(x.rateToday) && x.rateToday !== v.total_amount && total ? `Rate card today ${pesoOrNull(x.rateToday)}. The guest keeps the ${total} quoted.` : null;
  const timer = until
    ? `🗓️ Held until ${fmtUntil(until)}; released if no receipt arrives`
    : 'Dates blocked on our calendar with no timer: nothing releases them until you hold or decline';
  return groups(
    [`📬 BOOKING · Request from ${v.guest_name} · not paid yet`],
    [askedFor(v, via, v.guest_name), 'Finance decides: hold the dates for the guest, or decline.'],
    [money, timer, rate, ...(x.moneyNotes ?? [])],
    [x.lastMessage ? `💬 Guest wrote: "${x.lastMessage}"` : '💬 Nothing from the guest to answer yet.',
     `👤 ${[v.guest_phone, v.guest_email].filter(Boolean).join(' · ') || 'no contact on file'}`, ...(x.contactNotes ?? [])],
    x.context ?? [],
    [`🔖 Ref ${v.ref} · ${dashLink(v.id)}`],
  );
}

/** The OPS card: first name only, nothing about money, phone or e-mail. The whole text also goes through maskMoney. */
export function opsCard(v: InquiryView, x: CardExtra = {}): string {
  const via = x.via ?? viaOf(v.notes);
  const first = firstName(v.guest_name) || 'The guest';
  return maskMoney(groups(
    [`📬 GUEST · Request from ${first} · not confirmed yet`],
    [askedFor(v, via, first), x.lastMessage ? 'Finance decides on the booking. You may answer the message with a Cassy reply.' : 'Finance decides on the booking.'],
    x.lastMessage ? [`💬 Guest wrote: "${x.lastMessage}"`] : [],
    [`🔖 Ref ${v.ref}`],
  ));
}

/** Why a card whose request is no longer open cannot be acted on. null while it is still open. */
export function staleReason(v: InquiryView | null): string | null {
  if (!v) return 'That request no longer exists.';
  if (v.has_receipt && v.status === 'pending') return 'A receipt arrived for this request. Decide on the receipt card (🧾), not here.';
  if (v.status === 'pending') return null;
  const why: Record<string, string> = {
    cancelled: 'This request was cancelled, so there is nothing to decide.',
    expired: 'This request expired when its hold ran out, so there is nothing to decide.',
    confirmed: 'This booking is already confirmed.',
  };
  return why[v.status] ?? `This request is ${v.status}, so there is nothing to decide.`;
}

// ---- callbacks (≤ 64 bytes each) ----

export type IqTap =
  | { kind: 'hold' | 'holdok' | 'dec' | 'draft' | 'back'; id: string }
  | { kind: 'dr' | 'dx'; code: DeclineCode; id: string }
  | { kind: 'send' | 'drop'; id: string };

export const IQ = {
  hold: (id: string) => `iq:hold:${id}`, holdok: (id: string) => `iq:holdok:${id}`, dec: (id: string) => `iq:dec:${id}`,
  dr: (code: DeclineCode, id: string) => `iq:dr:${code}:${id}`, dx: (code: DeclineCode, id: string) => `iq:dx:${code}:${id}`,
  draft: (id: string) => `iq:draft:${id}`, send: (pid: string) => `iq:send:${pid}`, drop: (pid: string) => `iq:drop:${pid}`, back: (id: string) => `iq:back:${id}`,
};

/** Every callback_data above, read back. null for anything malformed or with a non-uuid id. */
export function parseIqTap(data: unknown): IqTap | null {
  const p = String(data ?? '').split(':');
  if (p[0] !== 'iq') return null;
  if (p.length === 3 && ['hold', 'holdok', 'dec', 'draft', 'back', 'send', 'drop'].includes(p[1]) && isUuid(p[2])) return { kind: p[1] as 'hold', id: p[2] };
  if (p.length === 4 && (p[1] === 'dr' || p[1] === 'dx') && isDeclineCode(p[2]) && isUuid(p[3])) return { kind: p[1], code: p[2] as DeclineCode, id: p[3] };
  return null;
}

type Rows = Btn[][];
/** The card's buttons. Finance: Hold / Decline (Hold drops once held) and Cassy reply when there is a message to answer.
 *  OPS: only the Cassy reply. */
export function inquiryKeyboard(v: Pick<InquiryView, 'id'>, surface: Surface, o: { hasMessage: boolean; state?: 'open' | 'held' }): Rows {
  const rows: Rows = [];
  if (surface === 'finance') rows.push(o.state === 'held' ? [{ text: '❌ Decline', callback_data: IQ.dec(v.id) }] : [{ text: `✅ Hold ${HOLD_HOURS} h`, callback_data: IQ.hold(v.id) }, { text: '❌ Decline', callback_data: IQ.dec(v.id) }]);
  if (o.hasMessage) rows.push([{ text: '✍️ Cassy reply', callback_data: IQ.draft(v.id) }]);
  return rows;
}
/** The whole inline keyboard a request card carries: the decision rows, then (Finance) the Log expense / Records row B82 keeps.
 *  Read back from the card text alone (a card with a guest message says "Guest wrote:"), so a stale tap can redraw it with no state. */
export function cardMarkup(v: Pick<InquiryView, 'id'>, surface: Surface, text: string, state?: 'open' | 'held'): { inline_keyboard: Btn[][] } | undefined {
  const rows = [...inquiryKeyboard(v, surface, { hasMessage: /Guest wrote:/.test(text), state }), ...(surface === 'finance' ? autoKeyboard(text, BTN.expense)?.inline_keyboard ?? [] : [])];
  return rows.length ? { inline_keyboard: rows } : undefined;
}
export const holdPreviewKeyboard = (id: string): Rows => [[{ text: '✅ Hold and send', callback_data: IQ.holdok(id) }, { text: '↩ Back', callback_data: IQ.back(id) }]];
export function declineKeyboard(id: string): Rows {
  const b = (c: DeclineCode): Btn => ({ text: DECLINE_LABELS[c], callback_data: IQ.dr(c, id) });
  return [[b('taken'), b('guests')], [b('house'), b('owner')], [b('dup')], [b('other')], [{ text: '↩ Back', callback_data: IQ.back(id) }]];
}
export const declinePreviewKeyboard = (code: DeclineCode, id: string): Rows =>
  [[{ text: code === 'dup' ? '❌ Decline' : '❌ Decline and send', callback_data: IQ.dx(code, id) }, { text: '↩ Back', callback_data: IQ.back(id) }]];
/** A Cassy draft card's buttons. `sendOk` false (the voice check failed) removes Send: only Draft again stays. */
export function draftKeyboard(o: { purpose: 'reply' | 'decline'; pid: string; bookingId: string; first: string; sendOk: boolean }): Rows {
  if (o.purpose === 'decline') {
    const again: Btn = { text: '🔄 Draft again', callback_data: IQ.dr('other', o.bookingId) };
    return o.sendOk ? [[{ text: '❌ Decline and send', callback_data: IQ.send(o.pid) }, { text: '🗑 Discard', callback_data: IQ.drop(o.pid) }]] : [[again]];
  }
  return o.sendOk
    ? [[{ text: `📤 Send to ${o.first || 'the guest'}`, callback_data: IQ.send(o.pid) }, { text: '🔄 Draft again', callback_data: IQ.draft(o.bookingId) }, { text: '🗑 Discard', callback_data: IQ.drop(o.pid) }]]
    : [[{ text: '🔄 Draft again', callback_data: IQ.draft(o.bookingId) }]];
}

// ---- tap texts (what the card says after each step) ----

export const channelName = (c: 'messenger' | 'email' | 'card_only') => (c === 'messenger' ? 'Messenger' : c === 'email' ? 'e-mail' : 'no channel');
/** Step 1 of Hold: the preview. Nothing is written until the second tap. */
export const holdPreview = (v: InquiryView, text: string, untilIso: string, via: string) =>
  `✅ Hold for ${firstName(v.guest_name) || 'the guest'} until ${fmtUntil(untilIso)}? ${firstName(v.guest_name) || 'The guest'} will receive, on ${via}:\n📨 ⤵\n${text}`;
export const declinePreview = (v: InquiryView, code: DeclineCode, text: string | null, via: string) =>
  text === null ? `❌ Decline ${firstName(v.guest_name) || 'the guest'}'s request without a message to the guest?`
    : `❌ Decline ${firstName(v.guest_name) || 'the guest'}'s request (${DECLINE_LABELS[code].toLowerCase()})? ${firstName(v.guest_name) || 'The guest'} will receive, on ${via}:\n📨 ⤵\n${text}`;
export const heldResult = (name: string, until: string, by: string, at: string, sent: string) =>
  `✅ Held for ${name} until ${until}, by ${by} at ${at}. ${sent}`;
export const declinedResult = (by: string, at: string, reason: string, sent: string) =>
  `❌ Declined by ${by} at ${at} (${reason}). Calendar freed, ledger row voided. ${sent}`;
export const opsHeldLine = (v: InquiryView, until: string, by: string) =>
  `${firstName(v.guest_name) || 'The guest'}'s dates, ${stayShort(v)}, are held until ${until} (${by}). Payment has not arrived yet.`;
export const opsDeclinedLine = (v: InquiryView, by: string) =>
  `${firstName(v.guest_name) || 'The guest'}'s request for ${stayShort(v)} was declined by ${by}. Nothing more to do.`;
export const sentLine = (first: string, channel: 'messenger' | 'email' | 'card_only', by: string, at: string) =>
  `📤 Sent to ${first || 'the guest'} on ${channelName(channel)} by ${by} at ${at}.`;
export const ALREADY_SENT = 'That reply was already sent or has expired. Nothing was sent twice.';
export const OPS_MONEY_REFUSED = 'This reply mentions amounts, so it is sent from Finance. Nothing was sent.';
export const NOT_ALLOWED_TO_DECIDE = 'Only a mapped owner or admin can hold or decline a request. Nothing changed.';
export const NO_REQUESTS = 'No booking requests are waiting for payment.';
export const REASON_PROMPT = 'In a few words, why? Only Cassy reads this; the guest never sees your words.';

// ---- guest lines (fixed; en / tl / bis) ----

const REG: Record<Lang, true> = { en: true, tl: true, bis: true };
export const asLang = (x: unknown): Lang => (typeof x === 'string' && x in REG ? x as Lang : 'en');
const lead = (first: string, rest: string) => (first ? `${first}, ${rest}` : cap(rest));

/** What the guest is asked to pay: `₱6,200 reservation fee`, `₱12,400 full payment`, or plain `payment` when the stored figure is unknown. */
export function dueWhat(v: InquiryView): string {
  const due = pesoOrNull(v.deposit_amount);
  if (!due) return 'payment';
  return `${due} ${v.total_amount !== null && Number(v.deposit_amount) === Number(v.total_amount) ? 'full payment' : 'reservation fee'}`;
}

/** The held line: the stored figure she was quoted, never a recomputed one. */
export function heldLine(v: InquiryView, lang: Lang, untilIso: string): string {
  const first = firstName(v.guest_name), dates = stayShort(v), until = fmtUntil(untilIso), pay = dueWhat(v);
  return {
    en: lead(first, `our host has set ${dates} aside for you until ${until}, Manila time. The ${pay} secures the stay, and a screenshot of the receipt sent here is all we need to confirm it.`),
    tl: lead(first, `naka-set aside na po ang ${dates} para sa inyo hanggang ${until}, Manila time. Ang ${pay} ang magse-secure ng stay, at screenshot lang ng receipt dito ang kailangan namin para ma-confirm ito.`),
    bis: lead(first, `gi-set aside na sa among host ang ${dates} para ninyo hangtod ${until}, Manila time. Ang ${pay} ang mo-secure sa stay, ug screenshot ra sa receipt diri ang among kinahanglan para ma-confirm.`),
  }[lang];
}

/** The decline line for a reason code; null for `dup` (no message) and `other` (Cassy drafts it). */
export function declineLine(code: DeclineCode, v: InquiryView, lang: Lang): string | null {
  const first = firstName(v.guest_name), dates = stayShort(v);
  switch (code) {
    case 'taken': return {
      en: lead(first, `thank you for choosing Cascade Hideaway. We're sorry that ${dates} is no longer open, as the home welcomes one party at a time. Should other dates suit you, we would be glad to check them for you.`),
      tl: lead(first, `salamat po sa pagpili sa Cascade Hideaway. Pasensya na, hindi na open ang ${dates}, dahil isang party lang ang tinatanggap ng home sa isang pagkakataon. Kung may ibang dates na swak sa inyo, iche-check namin agad.`),
      bis: lead(first, `salamat sa pagpili sa Cascade Hideaway. Pasensya, dili na open ang ${dates}, kay usa ra ka party ang among gina-welcome matag higayon. Kung naa moy laing dates, amo dayon i-check.`),
    }[lang];
    case 'guests': {
      const n = v.pax;
      return {
        en: lead(first, `thank you for your request for ${dates}. ${CAPACITY.en} We're sorry we can't welcome ${n ? `a party of ${n}` : 'this party'} this time; should a smaller group suit your plans, we would be glad to help.`),
        tl: lead(first, `salamat po sa request ninyo para sa ${dates}. ${CAPACITY.tl} Pasensya na at hindi namin ma-welcome ang ${n ? `grupo ng ${n}` : 'grupong ito'} this time; kung mas maliit na grupo ang swak sa plano ninyo, masaya kaming tumulong.`),
        bis: lead(first, `salamat sa inyong request para sa ${dates}. ${CAPACITY.bis} Pasensya kay dili namo ma-welcome ang ${n ? `grupo nga ${n}` : 'kini nga grupo'} this time; kung mas gamay nga grupo ang mohaum sa inyong plano, malipay mi motabang.`),
      }[lang];
    }
    case 'house': return {
      en: lead(first, `thank you for your request for ${dates}. We're unable to accept this stay, as it falls outside our house rules. Should your plans change, we would be glad to hear from you again.`),
      tl: lead(first, `salamat po sa request ninyo para sa ${dates}. Pasensya na, hindi namin ma-accept ang stay na ito dahil labas ito sa house rules namin. Kung magbago ang plano ninyo, masaya kaming makarinig ulit mula sa inyo.`),
      bis: lead(first, `salamat sa inyong request para sa ${dates}. Pasensya, dili namo ma-accept kini nga stay kay gawas kini sa among house rules. Kung mausab ang inyong plano, malipay mi nga makadungog balik ninyo.`),
    }[lang];
    case 'owner': return {
      en: lead(first, `thank you for your request for ${dates}. The home is not available on those dates, and we're sorry for the trouble. Should other dates suit you, we would be glad to check them for you.`),
      tl: lead(first, `salamat po sa request ninyo para sa ${dates}. Hindi available ang home sa mga petsang iyon, at pasensya na sa abala. Kung may ibang dates na swak sa inyo, iche-check namin agad.`),
      bis: lead(first, `salamat sa inyong request para sa ${dates}. Dili available ang home ana nga mga petsa, ug pasensya sa samok. Kung naa moy laing dates, amo dayon i-check.`),
    }[lang];
    default: return null;
  }
}

// ---- delivery plan ----

export type Plan = { channel: 'messenger' | 'email' | 'card_only'; humanAgent: boolean };
/** Mirrors guest-messages/templates.ts channelFor for a tapped message: under 23 h Messenger (plain), under 167 h Messenger with
 *  the HUMAN_AGENT tag, otherwise e-mail when there is one, otherwise the host sends it by hand (card_only). */
export function channelPlan(i: { hasThread: boolean; lastGuestAt: string | number | null; hasEmail: boolean; now?: number }): Plan {
  const last = i.lastGuestAt === null || i.lastGuestAt === undefined ? NaN : typeof i.lastGuestAt === 'number' ? i.lastGuestAt : Date.parse(i.lastGuestAt);
  const age = (i.now ?? Date.now()) - last, H = 3_600_000;
  if (i.hasThread && Number.isFinite(age)) {
    if (age < 23 * H) return { channel: 'messenger', humanAgent: false };
    if (age < 167 * H) return { channel: 'messenger', humanAgent: true };
  }
  return { channel: i.hasEmail ? 'email' : 'card_only', humanAgent: false };
}

// ---- the conversation behind a reply (Cassy, SPEC-38 s8) ----

/** The thread split for Cassy's reply: `latest` is the guest's newest words (the trailing run of guest turns newer than the
 *  request, at most 3; when the host already answered, the newest three since the request), `before` is everything ahead of them. */
export function replyContext(history: Turn[] | null | undefined, submittedAt: string | null | undefined): { before: Turn[]; latest: string[] } {
  const h = history ?? [], since = submittedAt ? Date.parse(submittedAt) : NaN;
  const fresh = (t: Turn) => t?.role === 'guest' && String(t.text ?? '').trim() !== '' && (Number.isNaN(since) || (Date.parse(String(t.at ?? '')) || 0) > since);
  let i = h.length; while (i > 0 && h[i - 1]?.role === 'guest') i--;
  let tail = h.slice(i).filter(fresh).slice(-3);
  if (!tail.length) tail = h.filter(fresh).slice(-3);
  if (!tail.length) return { before: h, latest: [] };
  const start = h.indexOf(tail[0]);
  return { before: start >= 0 ? h.slice(0, start) : h, latest: tail.map((t) => String(t.text).replace(/\s+/g, ' ').trim()) };
}

/** True when `text` repeats the host's private reason: five words in a row (the whole reason when it is shorter than five words
 *  but at least three). The model is told never to quote it; this catches the day it does anyway. */
export function quotesReason(text: string, reason: string): boolean {
  const words = (s: string) => String(s ?? '').toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter(Boolean);
  const r = words(reason), t = ` ${words(text).join(' ')} `;
  if (r.length < 3) return false;
  const n = Math.min(5, r.length);
  for (let i = 0; i + n <= r.length; i++) if (t.includes(` ${r.slice(i, i + n).join(' ')} `)) return true;
  return false;
}
