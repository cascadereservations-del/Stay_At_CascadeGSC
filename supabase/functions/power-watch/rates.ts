// power-watch, rate step (s110, D-358): the TOTAL residential rate (PHP per kWh) from SOCOTECO II's rate announcements, so the KPI tab can cost a kWh.
// Pure: no I/O, rates.test.ts covers it. index.ts feeds it the posts it already fetches, once a day, and calls utility_rate_record_auto_v1 with the answer.
// SHORTCUT: no real SOCOTECO II rate post was available when this was written, so the wording handled is the common distribution-utility one
// ("Residential ... P 12.3456/kWh", "Total Rate", "per kWh", "Month of November 2026"). Check it against the first real post (power-watch logs rate_step) and extend the patterns.

import { isPowerPost, posterUrls } from './poster.ts';

export const RATE_MIN = 5, RATE_MAX = 30; // plausible residential PHP per kWh; anything else is ignored

type Post = { id?: number; link?: string; date?: string; date_gmt?: string; title?: { rendered?: string }; content?: { rendered?: string } };
export type RateFound = { php_per_kwh: number; effective_from: string; source_url: string; via: 'text' | 'image' };

const strip = (html: string) => String(html ?? '').replace(/<[^>]+>/g, ' ').replace(/&#0?38;|&amp;/g, '&').replace(/&#8369;|&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
const NUM = String.raw`(?:₱|php|p)?\s*(\d{1,2}(?:\.\d{1,4})?)(?!\d)`;
// Strongest first. Each captures the rate; the number must follow the label closely, so a generation charge or a bill example is not picked up.
const PATTERNS = [
  new RegExp(String.raw`total\s+(?:residential\s+)?(?:electricity\s+)?rate[^0-9₱]{0,40}${NUM}`, 'i'),
  new RegExp(String.raw`(?:overall|all[-\s]?in|average)\s+(?:residential\s+)?rate[^0-9₱]{0,40}${NUM}`, 'i'),
  new RegExp(String.raw`residential[^0-9₱]{0,60}${NUM}\s*(?:/|per\s+)\s*kwh`, 'i'),
  new RegExp(String.raw`residential[^0-9₱]{0,25}rate[^0-9₱]{0,40}${NUM}`, 'i'),
];

export const isRatePost = (p: Post) => !isPowerPost(p) && /\b(rate|per\s*kwh|generation charge)/i.test(`${strip(p.title?.rendered ?? '')} ${strip(p.content?.rendered ?? '').slice(0, 600)}`);

const plausible = (n: number) => Number.isFinite(n) && n >= RATE_MIN && n <= RATE_MAX;

/** The residential total rate in a block of text, or null. */
export function rateFromText(text: string): number | null {
  for (const re of PATTERNS) {
    const m = re.exec(text);
    if (m && plausible(Number(m[1]))) return Math.round(Number(m[1]) * 10000) / 10000;
  }
  return null;
}

/** First day of the month the rate applies to: "month of November 2026", "November 2026 billing"; else the month the post was published (Manila). */
export function effectiveFrom(text: string, p: Post): string | null {
  const m = new RegExp(String.raw`\b(${MONTHS.join('|')})\s*,?\s*(20\d{2})\b`, 'i').exec(text);
  if (m) return `${m[2]}-${String(MONTHS.indexOf(m[1].toLowerCase()) + 1).padStart(2, '0')}-01`;
  const t = p.date_gmt ? Date.parse(`${p.date_gmt}Z`) : p.date ? Date.parse(`${p.date}+08:00`) : NaN;
  return Number.isNaN(t) ? null : new Date(t + 8 * 3_600_000).toISOString().slice(0, 7) + '-01';
}

/** The newest post (feed order) that states a plausible residential rate in its text. */
export function rateFromPosts(posts: Post[]): RateFound | null {
  for (const p of posts) {
    if (!isRatePost(p)) continue;
    const text = `${strip(p.title?.rendered ?? '')}. ${strip(p.content?.rendered ?? '')}`;
    const rate = rateFromText(text), from = effectiveFrom(text, p);
    if (rate !== null && from) return { php_per_kwh: rate, effective_from: from, source_url: p.link ?? '', via: 'text' };
  }
  return null;
}

/** The newest rate post with NO figure in its text but a poster image: the one image the vision read may be spent on. */
export function rateImageCandidate(posts: Post[]): { post: Post; url: string } | null {
  for (const p of posts) {
    if (!isRatePost(p) || rateFromText(strip(p.content?.rendered ?? ''))) continue;
    const url = posterUrls(p.content?.rendered ?? '')[0];
    if (url) return { post: p, url };
  }
  return null;
}

export const RATE_OCR_PROMPT = `This is a SOCOTECO II electricity rate announcement. Return ONLY a JSON object: {"residential_total_php_per_kwh": number | null, "month": "YYYY-MM" | null}. residential_total_php_per_kwh is the TOTAL residential rate in pesos per kWh (the all-in figure, not one charge such as generation). Use null when it is not printed.`;

/** The model's JSON for a rate image -> a RateFound, or null when the figure is missing or implausible. */
export function rateFromImageJson(o: { residential_total_php_per_kwh?: unknown; month?: unknown } | null, post: Post): RateFound | null {
  const n = Number(o?.residential_total_php_per_kwh);
  if (!plausible(n)) return null;
  const mm = /^(20\d{2})-(0[1-9]|1[0-2])$/.exec(String(o?.month ?? ''));
  const from = mm ? `${mm[1]}-${mm[2]}-01` : effectiveFrom('', post);
  return from ? { php_per_kwh: Math.round(n * 10000) / 10000, effective_from: from, source_url: post.link ?? '', via: 'image' } : null;
}
