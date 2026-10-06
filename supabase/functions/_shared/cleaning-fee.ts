// D-301: the cleaning fee comes from cleaner_rate_schedule (the table the dashboard Pay rates page writes through
// admin_add_pay_rate_v1) and from nowhere else. No guessed default: a missing rate is "rate missing", never PHP 500.
// A failed read is a different state from a real gap: "could not be read, try again", never "rate missing".
// Pure, so a test can run it (deno test _shared/cleaning-fee.test.ts; telegram-expense and submit-cleaning bundle it).

export type RateRow = { regular_rate?: unknown; general_rate?: unknown } | null | undefined;
// fee null + error false = no rate on file for that day; fee null + error true = the read failed.
export type FeeResult = { fee: number | null; error: boolean };

const good = (v: unknown): number | null => { const n = Number(v); return v != null && Number.isFinite(n) && n > 0 ? n : null; };

// Same rule as staff_pay_rate_v1: a deep clean with no deep-clean rate on the row takes the regular rate.
export function cleaningFeeFromRow(row: RateRow, cleaningType: string | null | undefined): number | null {
  if (!row) return null;
  const regular = good(row.regular_rate);
  return cleaningType === 'deep_clean' ? (good(row.general_rate) ?? regular) : regular;
}

// The answer of a PostgREST read of the schedule row in force: an error is its own state.
export function feeResultOf(res: { data?: RateRow; error?: unknown } | null | undefined, cleaningType: string | null | undefined): FeeResult {
  if (!res || res.error) return { fee: null, error: true };
  return { fee: cleaningFeeFromRow(res.data, cleaningType), error: false };
}

// A clean at 07:30 Manila is 23:30Z the day before: the pay day is the Manila date (D-301 follow-up), never slice(0,10) of the UTC stamp.
export function manilaDate(ts: unknown, fallback: string): string {
  const d = ts ? new Date(String(ts)) : null;
  return d && !isNaN(d.getTime()) ? d.toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' }) : fallback;
}

// The day a clean is paid on, the same rule as staff_pay_candidates_v1: checkout, else check-in, else the Manila date of the clean.
export function payDay(s: { checkout_date?: unknown; checkin_date?: unknown; cleaned_at?: unknown }, fallback: string): string {
  return String(s.checkout_date || s.checkin_date || manilaDate(s.cleaned_at, fallback));
}

export const RATE_MISSING = (date: string) =>
  `⚠️ The pay rate for ${date} is missing, so there is no amount to suggest. Add it in the dashboard under Settings, Pay rates, or tap Edit amount and type what you paid.`;
export const RATE_UNREADABLE = (date: string) =>
  `⚠️ The pay rate for ${date} could not be read just now. Try again in a minute, or tap Edit amount and type what you paid.`;
export const rateNote = (r: FeeResult, date: string): string => r.error ? RATE_UNREADABLE(date) : RATE_MISSING(date);

// The Finance "cleaning complete" line (submit-cleaning). Plain text pieces; the caller adds the emoji and Markdown.
export const feeDueText = (r: FeeResult): string =>
  r.fee != null ? `₱${r.fee}` : r.error ? 'rate could not be read, try again' : 'rate missing, set it in Settings, Pay rates';
