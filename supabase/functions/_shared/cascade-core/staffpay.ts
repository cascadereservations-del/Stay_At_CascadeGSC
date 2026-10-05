// cascade-core staffpay (session 70, SPEC-37, D-296..D-298): the pure parts of the Staff Payment Request. The Finance photo card, the
// OPS posts, the keyboards, the screenshot read and its verdict. No I/O, no globals. notify-cleaner-payment posts the card;
// telegram-expense edits it and settles it. Tests live in telegram-expense/staffpay.test.ts (CI skips _shared/cascade-core).
// Captions and posts are PLAIN TEXT (no parse_mode): nothing here escapes anything, and the senders must not set a parse_mode.
// Card text follows Lloyd's notice rule (what happened and who acts first, plain sentences, ids last) and keeps the shape Honey
// already uses in the staff group: "Cleaning services / Sep 27 Sun (Joseph)= 650 / other exp. ... / Total : P1,340".

/** One line of the immutable snapshot staff_pay_request_create_v1 stores in staff_pay_requests.lines. */
export type PayLine =
  | { kind: 'clean'; session_id: string; date: string; type?: string; base: number | string; transport: number | string; amount: number | string; guest?: string }
  | { kind: 'claim'; claim_id: string; date: string; description: string; amount: number | string; receipt?: boolean };

/** The columns of staff_pay_requests the cards read. */
export type PayReq = {
  id: string;
  ref: string;
  status: 'requested' | 'paying' | 'paid' | 'cancelled';
  payee_name: string;
  lines: PayLine[];
  total_amount: number | string;
  finance_chat_id?: number | string | null;
  finance_message_id?: number | string | null;
  ops_chat_id?: number | string | null;
  ops_message_id?: number | string | null;
  paying_by_name?: string | null;
  paying_at?: string | null;
  sent_said_at?: string | null;
  proof_file_unique_id?: string | null;
  proof_amount?: number | string | null;
  proof_reference?: string | null;
  proof_verdict?: 'match' | 'override' | null;
  paid_at?: string | null;
  paid_by_name?: string | null;
  cancelled_at?: string | null;
  cancelled_by_name?: string | null;
};

/** The currency mark every card uses. One constant, so the whole surface flips together if the team prefers "PHP ". */
export const CUR = '₱';
export const CAPTION_MAX = 1024;
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const n2 = (n: unknown): number => { const x = Number(n); return Number.isFinite(x) ? x : 0; };
/** 1340 -> "1,340"; 1340.5 -> "1,340.50". */
export function num(n: unknown): string {
  const x = n2(n);
  return x.toLocaleString('en-US', { minimumFractionDigits: Number.isInteger(x) ? 0 : 2, maximumFractionDigits: 2 });
}
export const peso = (n: unknown): string => CUR + num(n);

/** "2026-10-02" -> "Oct 2 Fri" (the weekday in Manila, as Honey writes it). */
export function dayLabel(date: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(date ?? ''));
  if (!m) return String(date ?? '');
  const weekday = new Intl.DateTimeFormat('en-PH', { weekday: 'short', timeZone: 'Asia/Manila' }).format(new Date(`${m[1]}-${m[2]}-${m[3]}T12:00:00+08:00`));
  return `${MON[Number(m[2]) - 1] ?? m[2]} ${Number(m[3])} ${weekday}`;
}

function manilaParts(iso: string | null | undefined): Intl.DateTimeFormatPart[] | null {
  const t = iso ? new Date(iso) : null;
  if (!t || Number.isNaN(t.getTime())) return null;
  return new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }).formatToParts(t);
}
const part = (p: Intl.DateTimeFormatPart[], type: string) => p.find((x) => x.type === type)?.value ?? '';
/** "3:05 PM" in Manila; empty when the time is unknown. */
export function manilaTime(iso: string | null | undefined): string {
  const p = manilaParts(iso);
  return p ? `${part(p, 'hour')}:${part(p, 'minute')} ${part(p, 'dayPeriod').toUpperCase()}` : '';
}
/** "Oct 5" in Manila. */
export function manilaDay(iso: string | null | undefined): string {
  const p = manilaParts(iso);
  return p ? `${part(p, 'month')} ${part(p, 'day')}` : '';
}

/** deep_clean -> Deep clean, mid_stay -> Mid-stay clean, anything else Turnover. */
export function typeLabel(t: string | null | undefined): string {
  return t === 'deep_clean' ? 'Deep clean' : t === 'mid_stay' ? 'Mid-stay clean' : 'Turnover';
}

const one = (s: unknown) => String(s ?? '').replace(/\s+/g, ' ').trim();
const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s);
const isClean = (l: PayLine): l is Extract<PayLine, { kind: 'clean' }> => l.kind === 'clean';
const isClaim = (l: PayLine): l is Extract<PayLine, { kind: 'claim' }> => l.kind === 'claim';
const ref = (r: PayReq) => `Ref CASCADE-${r.ref}`;
export const payReference = (r: PayReq) => `CASCADE-${r.ref}`;

function cleanLine(l: Extract<PayLine, { kind: 'clean' }>): string {
  const guest = one(l.guest);
  const tr = n2(l.transport);
  const kind = l.type && l.type !== 'turnover' ? ` · ${typeLabel(l.type)}` : '';
  return `${dayLabel(l.date)}${guest ? ` (${guest})` : ''} = ${num(l.amount)}${tr > 0 ? ` (${num(l.base)} + ${num(tr)} transport)` : ''}${kind}`;
}
function expenseLine(l: Extract<PayLine, { kind: 'claim' }>, o: { receipts?: boolean; clip?: number }): string {
  const d = one(l.description);
  return `${o.clip ? clip(d, o.clip) : d} = ${num(l.amount)}${o.receipts ? (l.receipt ? ' · receipt below' : ' · no receipt') : ''}`;
}

/**
 * Honey's block, built once for both cards:
 *   Cleaning services / <Mon d> <Weekday> (<guest>) = <amount> / Other expenses / <description> = <amount> / Total: ₱<total>
 * A transport clean reads "= 650 (500 + 150 transport)". `receipts` adds the Finance-only "· receipt below / · no receipt".
 * `budget` keeps the block under a character limit: long descriptions are clipped, then detail lines are dropped from the tail
 * and "+N more" says so. The total line always stays.
 */
export function payBlock(r: PayReq, o: { receipts?: boolean; clip?: number; budget?: number } = {}): string {
  const cleans = r.lines.filter(isClean).map(cleanLine);
  const exps = r.lines.filter(isClaim).map((l) => expenseLine(l, o));
  const total = `Total: ${peso(r.total_amount)}`;
  const all = [...cleans.map((l) => ({ c: true, l })), ...exps.map((l) => ({ c: false, l }))];
  const render = (drop: number): string => {
    const keep = all.slice(0, all.length - drop);
    const c = keep.filter((x) => x.c).map((x) => x.l), e = keep.filter((x) => !x.c).map((x) => x.l);
    return [...(c.length ? ['Cleaning services', ...c] : []), ...(e.length ? ['Other expenses', ...e] : []), ...(drop ? [`+${drop} more`] : []), total].join('\n');
  };
  let drop = 0;
  while (o.budget && render(drop).length > o.budget && drop < all.length) drop++;
  return render(drop);
}

const money = (r: PayReq) => peso(r.total_amount);
const clean = (r: PayReq) => r.lines.some(isClean);
const claims = (r: PayReq) => r.lines.filter(isClaim).length;
function ledgerSentence(r: PayReq): string {
  const k = claims(r), c = clean(r);
  if (c && k) return `The cleans and the ${k === 1 ? 'expense' : 'expenses'} are marked paid in the ledger.`;
  if (c) return 'The cleans are marked paid in the ledger.';
  return `The ${k === 1 ? 'expense is' : 'expenses are'} marked paid in the ledger.`;
}

function qrParagraph(r: PayReq): string {
  return `The QR is ${r.payee_name}'s payout account with ${money(r)} already set. Save the photo, then in GCash, BPI or OwnBank choose Scan QR and upload it from your gallery. Paste the reference in the transfer note.`;
}

function headLine(r: PayReq, hasQr: boolean): string {
  const P = r.payee_name, amt = money(r);
  if (r.status === 'paying' && !r.sent_said_at) {
    const t = manilaTime(r.paying_at);
    return `${r.paying_by_name || 'Finance'} is paying ${P} ${amt} now${t ? ` (${t})` : ''}. Payment sent?`;
  }
  if (r.status === 'paying') {
    const t = manilaTime(r.sent_said_at);
    return `${r.paying_by_name || 'Finance'} sent ${P} ${amt}${t ? ` at ${t}` : ''}. Waiting for the transfer screenshot here.`;
  }
  if (r.status === 'paid') {
    const when = `${manilaDay(r.paid_at)}${manilaTime(r.paid_at) ? ` at ${manilaTime(r.paid_at)}` : ''}`.trim();
    const by = r.paid_by_name || 'Finance';
    const second = r.proof_verdict === 'override'
      ? `${by} confirmed the amount by hand; ${n2(r.proof_amount) > 0 ? `the screenshot read ${peso(r.proof_amount)}` : 'the screenshot could not be read'}.`
      : `${by} sent it${when ? ` on ${when}` : ''} and the screenshot matches${r.proof_reference ? ` (reference ${r.proof_reference})` : ''}.`;
    return `PAID. ${P} has been paid ${amt}. ${second} ${ledgerSentence(r)}`;
  }
  if (r.status === 'cancelled') {
    const t = manilaTime(r.cancelled_at);
    return `Cancelled by ${r.cancelled_by_name || 'Finance'}${t ? ` at ${t}` : ''}. Nothing was paid; ${P}'s cleans are free to request again.`;
  }
  return `${P} is asking to be paid ${amt}. Finance: pay ${P}${hasQr ? ' with the QR above' : ''}, then tap I'm paying this.`;
}

/** The Finance card (photo caption or text), by state. Never over 1,024 characters and always ends with the Ref line. */
export function financeCaption(r: PayReq, hasQr: boolean): string {
  const head = headLine(r, hasQr);
  const open = r.status === 'requested';
  const tail = open
    ? ['', hasQr ? qrParagraph(r) : `${r.payee_name}'s payout QR is not saved yet, so there is no QR here. Pay ${r.payee_name}'s usual account and send the screenshot here.`, ref(r)]
    : ['', ref(r)];
  const frame = (block: string) => [head, '', block, ...tail].join('\n');
  const budget = Math.max(40, CAPTION_MAX - frame('').length);
  return frame(payBlock(r, { receipts: true, clip: 48, budget }));
}

export type Btn = { text: string; callback_data?: string; url?: string; copy_text?: { text: string } };
export type Keyboard = { inline_keyboard: Btn[][] };

/** Only apps whose package ids are verified (SPEC-37 7.C) are listed; an empty list omits the row. */
export const BANK_APPS: ReadonlyArray<{ key: string; label: string }> = [];
export const BANK_PAGE = 'https://cascadereservations-del.github.io/Cascade-Staff/pay/bank.html';

const cb = (step: SprStep, id: string) => `spr:${step}:${id}`;
export type SprStep = 'pay' | 'no' | 'sent' | 'ovr' | 'cancel';

/** The Finance card's buttons by state. Every callback_data is at most 64 bytes ("spr:cancel:" + a uuid is 47). */
export function financeKeyboard(r: PayReq): Keyboard {
  const rows: Btn[][] = [];
  const total = n2(r.total_amount);
  const copyRows = (): void => {
    rows.push([
      { text: '📋 Copy amount', copy_text: { text: Number.isInteger(total) ? String(total) : total.toFixed(2) } },
      { text: '📋 Copy reference', copy_text: { text: payReference(r) } },
    ]);
    if (BANK_APPS.length) rows.push(BANK_APPS.map((a) => ({ text: `🏦 ${a.label}`, url: `${BANK_PAGE}?app=${a.key}` })));
  };
  if (r.status === 'requested') {
    copyRows();
    rows.push([{ text: "💸 I'm paying this", callback_data: cb('pay', r.id) }, { text: '✖ Cancel request', callback_data: cb('cancel', r.id) }]);
  } else if (r.status === 'paying' && !r.sent_said_at) {
    copyRows();
    rows.push([{ text: '✅ Yes, payment sent', callback_data: cb('sent', r.id) }, { text: '↩ No, not sent', callback_data: cb('no', r.id) }]);
  } else if (r.status === 'paying') {
    const row: Btn[] = [{ text: '📷 Send the screenshot', callback_data: cb('sent', r.id) }];
    if (!r.proof_file_unique_id) row.push({ text: '↩ No, not sent', callback_data: cb('no', r.id) });
    rows.push(row);
  }
  return { inline_keyboard: rows };
}

const closing = (r: PayReq) => (/^honey$/i.test(r.payee_name.trim()) ? ' Ty, Hon 🌷' : '');

/** OPS: the request, with the same block as the Finance card (no QR, no buttons, no receipt marker). */
export function opsRequestText(r: PayReq): string {
  return [`${r.payee_name} sent a payment request for ${money(r)}. Finance will pay it and post here when it is done.`, '', payBlock(r, { clip: 100 }), ref(r)].join('\n');
}
/** OPS: paid, as a reply to the request post. The block is not repeated. */
export function opsPaidText(r: PayReq): string {
  const tail = String(r.proof_reference ?? '').slice(-4);
  const when = `${manilaDay(r.paid_at)}${manilaTime(r.paid_at) ? ` at ${manilaTime(r.paid_at)}` : ''}`.trim();
  const sent = `${r.paid_by_name || 'Finance'} sent it${when ? ` on ${when}` : ''}${tail ? `, reference ending ${tail}` : ''}.`;
  return [`${r.payee_name} has been paid ${money(r)}. ${sent} ${r.payee_name}: tap Received once it shows in your account.${closing(r)}`, ref(r)].join('\n');
}
/** The Received button of the OPS paid post: the existing cleanerack: handler (sets fee_acked_at). Null when the name will not fit. */
export function opsPaidKeyboard(r: PayReq): Keyboard | null {
  const data = `cleanerack:${encodeURIComponent(r.payee_name)}`;
  return new TextEncoder().encode(data).length <= 64 ? { inline_keyboard: [[{ text: '✅ Received', callback_data: data }]] } : null;
}
/** OPS: cancelled, as a reply to the request post. */
export function opsCancelText(r: PayReq): string {
  return [`Finance cancelled ${r.payee_name}'s payment request for ${money(r)}; nothing was paid. ${r.payee_name}: send a new one from the Cascade Staff app if it is still owed.`, ref(r)].join('\n');
}

/** The question after "Yes, payment sent". */
export function proofPrompt(r: PayReq, actor: string): string {
  return `${actor}, send the transfer screenshot here as a photo. It is checked against ${money(r)} before ${r.payee_name}'s request is marked paid.`;
}
export const matchText = (r: PayReq) => `✅ This matches ${money(r)}. ${r.payee_name}'s request is marked PAID.`;

export type ProofVerdict = 'unread' | 'not_proof' | 'match' | 'mismatch';

/** What Finance reads when the screenshot did not settle the request, by verdict (SPEC-37 6.4). */
export function mismatchText(r: PayReq, read: { amount?: number | null } | null, verdict: ProofVerdict): string {
  if (verdict === 'not_proof') return 'This looks like the screen before sending, not a finished transfer, so nothing is marked paid. Send the screenshot taken after the transfer went through.';
  if (verdict === 'unread' || !read || !(n2(read.amount) > 0)) {
    return `The screenshot could not be read automatically, so it is not marked paid yet. Check it shows ${money(r)} sent to ${r.payee_name}, then tap Amount is right, or send a clearer one.`;
  }
  return `The screenshot shows ${peso(read.amount)}, but ${r.payee_name}'s request is ${money(r)}, so it is not marked paid yet. If the screenshot is right and the reading is wrong, tap Amount is right. Otherwise send the correct screenshot.`;
}
export const duplicateText = (otherRef: string) => `This screenshot was already used for request ${otherRef}, so nothing changed. Send the screenshot for this payment.`;
/** The buttons under a mismatch reply: settle by hand, or send another screenshot. */
export function mismatchKeyboard(id: string): Keyboard {
  return { inline_keyboard: [[{ text: '✅ Amount is right, mark paid', callback_data: cb('ovr', id) }, { text: '📷 Send another', callback_data: cb('sent', id) }]] };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
/** `spr:<step>:<uuid>`; anything else is null. */
export function parseSprTap(data: string): { step: SprStep; id: string } | null {
  const p = String(data ?? '').split(':');
  if (p.length !== 3 || p[0] !== 'spr' || !['pay', 'no', 'sent', 'ovr', 'cancel'].includes(p[1]) || !UUID.test(p[2])) return null;
  return { step: p[1] as SprStep, id: p[2].toLowerCase() };
}
/** Tap step -> telegram_staff_pay_step_v1 step. */
export const RPC_STEP: Record<SprStep, string> = { pay: 'pay', no: 'not_sent', sent: 'sent', ovr: 'override', cancel: 'cancel' };

/** The toast a refused tap shows (SPEC-37 6.4). */
export function tapRefusal(reason: string, o: { status?: string; date?: string; payee?: string } = {}): string {
  switch (reason) {
    case 'not_open': return o.status === 'paid' || o.status === 'cancelled' ? 'This request is already closed.' : 'Someone is already paying this one.';
    case 'not_paying': return 'That one is not being paid right now.';
    case 'proof_already_sent': return 'A screenshot is already in; use Amount is right or send another.';
    case 'money_may_be_sent': return 'Payment was marked as sent, so it cannot be cancelled here. Tap No, not sent first if it was not sent.';
    case 'no_screenshot': return 'Send the screenshot first, then tap Amount is right.';
    case 'not_waiting_for_proof': return 'That request is not waiting for a screenshot, so nothing was saved.';
    case 'already_paid': return `The clean on ${o.date ? dayLabel(o.date) : 'that day'} was already paid another way, so nothing was marked paid. Cancel this request and ask ${o.payee || 'the cleaner'} to send a new one.`;
    case 'not_found': return 'That request no longer exists.';
    default: return `Nothing changed (${reason}).`;
  }
}

export const PROOF_PROMPT = `You are reading a Philippine bank or e-wallet transfer confirmation (GCash, BPI, OwnBank, MariBank, Maya, InstaPay). Return ONLY a JSON object:
{"amount": number|null, "reference": string|null, "date": "YYYY-MM-DD"|null, "recipient_name": string|null, "status": "success"|"pending"|"failed"|null, "confidence": number}
Rules: amount = the amount transferred, not the fee or the balance. reference = the transaction or reference number exactly as printed. status = what the screen says. If this is not a finished transfer (a confirm screen before sending, a QR code, a balance screen), set amount null. Never invent a reference you cannot see.`;

export type ProofRead = { amount: number | null; reference: string | null; date: string | null; recipient_name: string | null; status: 'success' | 'pending' | 'failed' | null; confidence: number };

/** The model's JSON, made safe: reference upper-case A-Z0-9 of 4 to 64 characters (as upload-booking-receipt), amount above zero, confidence 0 to 1. */
export function normaliseProof(json: unknown): ProofRead | null {
  if (!json || typeof json !== 'object') return null;
  const o = json as Record<string, unknown>;
  const amt = Number(String(o.amount ?? '').replace(/[₱,\s]/g, ''));
  const refText = String(o.reference ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  const status = String(o.status ?? '').toLowerCase();
  const conf = Number(o.confidence);
  return {
    amount: Number.isFinite(amt) && amt > 0 ? Math.round(amt * 100) / 100 : null,
    reference: refText.length >= 4 && refText.length <= 64 ? refText : null,
    date: /^\d{4}-\d{2}-\d{2}$/.test(String(o.date ?? '')) ? String(o.date) : null,
    recipient_name: o.recipient_name ? String(o.recipient_name).replace(/\s+/g, ' ').slice(0, 80) : null,
    status: status === 'success' || status === 'pending' || status === 'failed' ? status : null,
    confidence: Number.isFinite(conf) ? Math.max(0, Math.min(1, conf)) : 0,
  };
}

/** unread (no read) | not_proof (no amount, or the screen says pending or failed) | match (within PHP 0.50, as upload-booking-receipt) | mismatch. */
export function proofVerdict(read: { amount?: number | null; status?: string | null } | null | undefined, total: number | string): ProofVerdict {
  if (!read) return 'unread';
  const a = Number(read.amount);
  if (!(a > 0) || read.status === 'pending' || read.status === 'failed') return 'not_proof';
  return Math.abs(a - n2(total)) < 0.5 ? 'match' : 'mismatch';
}
