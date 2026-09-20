// Session 29 (Lloyd, 2026-09-17): when the OCR says an uploaded "receipt" is not a completed payment (he sent the Maya
// screen before sending) or is short of the amount due, the Finance card carries a sample reply for the guest on a 📨 line
// (Copy / Revise taps, B82). One paragraph each (templateOf reads to the next blank line), in the guest's register
// (protocols 07/08/09): calm, guiding, no po in Bisaya. Nothing is sent to the guest by this function.
export type Lang = 'en' | 'tl' | 'bis';
export type Verdict = 'match' | 'short' | 'over' | 'not_proof' | 'unread';

const peso = (n: number) => '₱' + Number(n).toLocaleString('en-PH');

/** Telegram's hard cap on a photo/document CAPTION. A longer card is sent as its own message
 *  instead of being truncated — see notifyFinance. */
export const CAPTION_MAX = 1024;

/** What the OCR result means against the amount due. `unread` = the OCR itself did not run or failed. */
export function verdictOf(read: { amount: number | null } | null, expected: number): Verdict {
  if (!read) return 'unread';
  if (read.amount === null) return 'not_proof';
  if (Math.abs(read.amount - expected) < 0.5) return 'match';
  return read.amount < expected ? 'short' : 'over';
}

/** The sample reply for the 📨 line, or '' when the host has nothing to ask of the guest (match / over / unread). */
export function guestFollowUp(v: Verdict, lang: Lang, name: string, expected: number, received = 0): string {
  const n = name.trim().split(/\s+/)[0] || 'there';
  if (v === 'not_proof') return {
    en: `Hi ${n}, thank you for sending this. The image doesn't show a completed payment yet — it looks like the screen just before sending. Once the ${peso(expected)} transfer is done, simply send the confirmation screenshot here and we'll take care of the rest.`,
    tl: `Hi ${n}! Salamat sa pag-send. Hindi po nakikita sa image ang completed payment — it looks like the screen just before sending. Once done ang ${peso(expected)} transfer, send lang po the confirmation screenshot here at kami na ang bahala sa confirmation.`,
    bis: `Hi ${n}! Salamat sa pag-send. The image doesn't show a completed payment yet — murag ang screen before sending. Once done ang ${peso(expected)} transfer, send lang ang confirmation screenshot diri and we'll take care of the confirmation.`,
  }[lang];
  if (v === 'short') return {
    en: `Hi ${n}, thank you — we've received ${peso(received)}. The initial payment is ${peso(expected)}, so ${peso(expected - received)} remains. You may send the difference through the same GCash QR whenever convenient, and we'll confirm the reservation right after.`,
    tl: `Hi ${n}! Salamat, received po ang ${peso(received)}. The initial payment is ${peso(expected)}, so ${peso(expected - received)} ang remaining. Puwede po ninyong i-send ang difference through the same GCash QR once convenient, at iko-confirm namin ang reservation right after.`,
    bis: `Hi ${n}! Salamat, received na ang ${peso(received)}. The initial payment is ${peso(expected)}, so ${peso(expected - received)} ang remaining. Pwede i-send ang difference through the same GCash QR once convenient, and amo dayon i-confirm ang reservation.`,
  }[lang];
  return '';
}

// ---------------------------------------------------------------------------
// SPEC-10 (fraud design controls 2, 3, 4). Host-facing, English only, no voice gate — these are
// read by Lloyd in the Finance group, not by a guest. Every one of them is advisory: none hides
// the Confirm / Decline buttons or changes the callback data (Hard Rule 9).

/** One row of prior_receipt_use_v1: another candidate on a DIFFERENT booking at this property. */
export type PriorUse = { booking_id: string; guest_name: string | null; seen_at: string; match: 'image' | 'reference' };

/** Control 3. The first group on the card when this receipt was already used on another booking.
 *  Empty when it was not, so the card is unchanged in the ordinary case. */
export function priorUseLines(hits: PriorUse[]): string[] {
  const h = hits[0];
  if (!h) return [];
  const what = h.match === 'image' ? 'image' : 'reference number';
  const who = (h.guest_name ?? '').trim().split(/\s+/)[0] || 'another guest';
  const ref = 'DIR-' + h.booking_id.slice(0, 8).toUpperCase();
  const more = hits.length > 1 ? ` and ${hits.length - 1} other${hits.length > 2 ? 's' : ''}` : '';
  return [
    `⚠️ This receipt's ${what} was already used for ${ref} (${who}, ${h.seen_at.slice(0, 10)})${more}.`,
    'It may be an honest resend. Check before confirming.',
  ];
}

/** Control 2. What actually defeats a fake screenshot: find the money in the wallet first.
 *  null for not_proof / unread, where there is no amount to look for and the caller keeps its own
 *  wording (open the image / review in the dashboard). */
export function hostDoLine(v: Verdict, amount: number | null, reference: string | null): string | null {
  if (v === 'not_proof' || v === 'unread' || amount === null) return null;
  return `Do: open GCash / Maya and find ${peso(amount)} from the guest${reference ? `, ref ${reference}` : ''}, BEFORE confirming. A screenshot is not money.`;
}

/** Control 4. An overpayment is more often the opening move of a refund scam than a mistake. */
export function overpaymentLines(paid: number, asked: number): string[] {
  return [
    `⚠️ Paid MORE than asked (${peso(paid)} vs ${peso(asked)}).`,
    'A common scam is a fake overpayment followed by a refund request.',
    'Refund only to the sending account, only after the money is visibly in the wallet.',
  ];
}
