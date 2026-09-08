// Manila-date helpers for turnover-verifier.
//
// v9 computed "today in Manila" as:
//   new Date(new Date().toLocaleString('en-CA', { timeZone: 'Asia/Manila' }))
// en-CA renders "2026-09-08, 08:00:00" — with a comma — which V8 does not
// parse, so every run produced an Invalid Date and threw
// `RangeError: Invalid time value` at the first toISOString(). The function
// reached production, ran daily, and never wrote a single row.
//
// These helpers never round-trip a locale string through Date. The date is
// read as parts from Intl, and day arithmetic is done on a UTC midnight
// anchor, which cannot drift across a DST boundary (Manila has none, but the
// anchor makes that independent of the zone).

export const MANILA_TZ = 'Asia/Manila';

const YMD = /^\d{4}-\d{2}-\d{2}$/;

/** Today's calendar date in Manila, as YYYY-MM-DD. */
export function manilaDate(now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: MANILA_TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(now);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? '';
  const value = `${get('year')}-${get('month')}-${get('day')}`;
  if (!YMD.test(value)) throw new Error(`manila_date_unavailable: ${value}`);
  return value;
}

/** Shift a YYYY-MM-DD string by whole days. Returns YYYY-MM-DD. */
export function addDays(date: string, delta: number): string {
  if (!YMD.test(date)) throw new Error(`invalid_date: ${date}`);
  const [y, m, d] = date.split('-').map(Number);
  const anchor = new Date(Date.UTC(y, m - 1, d));
  anchor.setUTCDate(anchor.getUTCDate() + delta);
  return anchor.toISOString().slice(0, 10);
}

/** The two checkout dates each run inspects: T-1 (Finance) and T-2 (OPS). */
export function turnoverWindow(now: Date = new Date()): { today: string; yesterday: string; twoDaysAgo: string } {
  const today = manilaDate(now);
  return { today, yesterday: addDays(today, -1), twoDaysAgo: addDays(today, -2) };
}
