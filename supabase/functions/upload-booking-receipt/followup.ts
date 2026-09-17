// Session 29 (Lloyd, 2026-09-17): when the OCR says an uploaded "receipt" is not a completed payment (he sent the Maya
// screen before sending) or is short of the amount due, the Finance card carries a sample reply for the guest on a 📨 line
// (Copy / Revise taps, B82). One paragraph each (templateOf reads to the next blank line), in the guest's register
// (protocols 07/08/09): calm, guiding, no po in Bisaya. Nothing is sent to the guest by this function.
export type Lang = 'en' | 'tl' | 'bis';
export type Verdict = 'match' | 'short' | 'over' | 'not_proof' | 'unread';

const peso = (n: number) => '₱' + Number(n).toLocaleString('en-PH');

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
