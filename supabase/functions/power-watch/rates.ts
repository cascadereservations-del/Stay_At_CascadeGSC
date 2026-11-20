// power-watch, rate step (s110 D-358, s127): SOCOTECO II's residential rate (PHP per kWh) per month, for the KPI tab.
// Source: the plain HTML table on https://www.socoteco2.com/effective-rates/ (cells carry data-title="Month" / "Residential", values like "12.0508/kwh").
// Pure: no I/O, rates.test.ts covers it. index.ts fetches the page once a day and records every row with utility_rate_record_auto_v1.

export const RATE_MIN = 5, RATE_MAX = 30; // plausible residential PHP per kWh; anything else is ignored
export type RateRow = { php_per_kwh: number; effective_from: string };

const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
const cell = (tr: string, title: string) => new RegExp(String.raw`<td\b[^>]*data-title\s*=\s*["']${title}["'][^>]*>([\s\S]*?)</td>`, 'i').exec(tr)?.[1]?.replace(/<[^>]+>/g, ' ').replace(/&nbsp;|&#160;/gi, ' ').replace(/\s+/g, ' ').trim() ?? '';

/** rows: one per month with a plausible residential value (first day of the month is the effective date). seen: non-empty Residential cells, so the caller can tell when cells were skipped; empty (future) cells are not counted. Only the first <table> is read. */
export function ratesFromTable(html: string): { rows: RateRow[]; seen: number } {
  const out: RateRow[] = [];
  let seen = 0;
  const table = /<table\b[^]*?<\/table>/i.exec(String(html ?? ''))?.[0] ?? '';
  for (const tr of table.match(/<tr\b[^]*?<\/tr>/gi) ?? []) {
    if (cell(tr, 'Residential')) seen++;
    const m = /^([a-z]+)\s*,?\s*(20\d{2})$/i.exec(cell(tr, 'Month')), v = /^(\d{1,2}(?:\.\d{1,4})?)\s*\/\s*kwh$/i.exec(cell(tr, 'Residential'));
    const mi = m ? MONTHS.indexOf(m[1].toLowerCase()) : -1, n = v ? Number(v[1]) : NaN;
    if (mi >= 0 && n >= RATE_MIN && n <= RATE_MAX) out.push({ php_per_kwh: n, effective_from: `${m![2]}-${String(mi + 1).padStart(2, '0')}-01` });
  }
  return { rows: out, seen };
}
