// power-watch, rate step (s110 D-358, s127): SOCOTECO II's residential rate (PHP per kWh) per month, for the KPI tab.
// Source: the plain HTML table on https://www.socoteco2.com/effective-rates/ (cells carry data-title="Month" / "Residential", values like "12.0508/kwh").
// Pure: no I/O, rates.test.ts covers it. index.ts fetches the page once a day and records every row with utility_rate_record_auto_v1.

export const RATE_MIN = 5, RATE_MAX = 30; // plausible residential PHP per kWh; anything else is ignored
export type RateRow = { php_per_kwh: number; effective_from: string };

const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
const cell = (tr: string, title: string) => new RegExp(String.raw`<td\b[^>]*data-title\s*=\s*["']${title}["'][^>]*>([\s\S]*?)</td>`, 'i').exec(tr)?.[1]?.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() ?? '';

/** One row per month with a plausible residential value; empty (future) and unparsable cells are skipped. First day of the month is the effective date. */
export function ratesFromTable(html: string): RateRow[] {
  const out: RateRow[] = [];
  for (const tr of String(html ?? '').match(/<tr\b[\s\S]*?<\/tr>/gi) ?? []) {
    const m = /^([a-z]+)\s*,?\s*(20\d{2})$/i.exec(cell(tr, 'Month')), v = /^(\d{1,2}(?:\.\d{1,4})?)\s*\/\s*kwh$/i.exec(cell(tr, 'Residential'));
    const mi = m ? MONTHS.indexOf(m[1].toLowerCase()) : -1, n = v ? Number(v[1]) : NaN;
    if (mi >= 0 && n >= RATE_MIN && n <= RATE_MAX) out.push({ php_per_kwh: n, effective_from: `${m![2]}-${String(mi + 1).padStart(2, '0')}-01` });
  }
  return out;
}
