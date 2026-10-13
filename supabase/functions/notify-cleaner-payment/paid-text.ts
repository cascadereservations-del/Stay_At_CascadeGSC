// Lane C (s81): the sentences that tell a staff member she was paid. Pure; used by the Telegram post, the Web Push and (as a copy in
// pay/pay-lib.js with the same golden strings) the in-app notice. Calm, plain, no exclamation marks. The lock-screen push NEVER carries an amount.
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export type PaidNotice = {
  first_name: string;
  total: number | string;
  date_from?: string | null;
  date_to?: string | null;
  bank_reference?: string | null;
  bank_label?: string | null;
  ref?: string | null;
};

/** "2026-10-10" -> "Oct 10". Anything else comes back unchanged. */
export function dayShort(iso: string | null | undefined): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso ?? ''));
  return m ? `${MON[Number(m[2]) - 1] ?? m[2]} ${Number(m[3])}` : String(iso ?? '');
}
/** "Oct 10 to Oct 12", or "Oct 10" for a single day, or "" when no date is known. */
export function workRange(from?: string | null, to?: string | null): string {
  const a = dayShort(from), b = dayShort(to ?? from);
  if (!a) return '';
  return a === b || !b ? a : `${a} to ${b}`;
}
/** 1235 -> "PHP 1,235"; 1235.5 -> "PHP 1,235.50". */
export function php(n: number | string): string {
  const x = Math.round(Number(n) * 100) / 100;
  return 'PHP ' + x.toLocaleString('en-US', { minimumFractionDigits: Number.isInteger(x) ? 0 : 2, maximumFractionDigits: 2 });
}
/** The bank's own reference in groups of four ("12345678" -> "1234 5678"); the request ref when the bank gave none. */
export function referenceText(n: PaidNotice): string {
  const r = String(n.bank_reference ?? '').replace(/[^A-Za-z0-9]/g, '');
  if (r) return r.replace(/(.{4})(?=.)/g, '$1 ');
  return n.ref ? `CASCADE-${n.ref}` : '';
}
const account = (n: PaidNotice) => (n.bank_label && n.bank_label.trim() ? `your ${n.bank_label.trim()} account` : 'your account');

export const PUSH_TITLE = 'Your payment has been sent';

/** Lock-screen text: no amount, no reference. */
export function pushBody(n: PaidNotice): string {
  const r = workRange(n.date_from, n.date_to);
  return `Hi ${n.first_name}, your pay${r ? ` for ${r}` : ''} is on its way to ${account(n)}. Open Cascade Staff for the details. Thank you for your care with the house.`;
}

/** The notice in the app and on Telegram. */
export function noticeText(n: PaidNotice): string {
  const r = workRange(n.date_from, n.date_to), ref = referenceText(n);
  return `Hi ${n.first_name}, we have sent ${php(n.total)} to ${account(n)}${r ? ` for your work on ${r}` : ''}.${ref ? ` Reference: ${ref}.` : ''} Please let us know if anything looks different on your side. Thank you for your care with the house. Marifel & The Cascade Team`;
}
