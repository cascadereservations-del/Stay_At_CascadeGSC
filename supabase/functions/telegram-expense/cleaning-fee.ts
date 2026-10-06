// D-301: the cleaning fee comes from cleaner_rate_schedule (the table the dashboard Pay rates page writes through
// admin_add_pay_rate_v1) and from nowhere else. No guessed default: a missing rate is "rate missing", never PHP 500.
// Pure, so a test can run it (deno test telegram-expense/cleaning-fee.test.ts).

export type RateRow = { regular_rate?: unknown; general_rate?: unknown } | null | undefined;

const good = (v: unknown): number | null => { const n = Number(v); return v != null && Number.isFinite(n) && n > 0 ? n : null; };

// Same rule as staff_pay_rate_v1: a deep clean with no deep-clean rate on the row takes the regular rate.
export function cleaningFeeFromRow(row: RateRow, cleaningType: string | null | undefined): number | null {
  if (!row) return null;
  const regular = good(row.regular_rate);
  return cleaningType === 'deep_clean' ? (good(row.general_rate) ?? regular) : regular;
}

// A clean at 07:30 Manila is 23:30Z the day before: the pay day is the Manila date (D-301 follow-up), never slice(0,10) of the UTC stamp.
export function manilaDate(ts: unknown, fallback: string): string {
  const d = ts ? new Date(String(ts)) : null;
  return d && !isNaN(d.getTime()) ? d.toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' }) : fallback;
}

export const RATE_MISSING = (date: string) =>
  `⚠️ The pay rate for ${date} is missing, so there is no amount to suggest. Add it in the dashboard under Settings, Pay rates, or tap Edit amount and type what you paid.`;
